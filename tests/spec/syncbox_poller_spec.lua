-- syncbox/poller.lua (#534, docs/hdmi-sync-stage2-design.md §3.6, contracts
-- C2): the box's state read again and again, one read at a time; 5 s while
-- the box is on, 30 s in power save, 60 s after 3 failures in a row; a read
-- 1 s after a command and at once on a hint (at most one per 2 s); offline
-- after 5 minutes without an answer (#428), online at the next good read;
-- polling stops on a 401 or 403. The client is a stand-in that records each
-- GET and answers when the spec says; timers run on the fake clock
-- (tests/helpers/fake_c4.lua, c4.advance). States are written by hand from
-- docs/syncbox-api-research.md §2's field names. Placeholders only: box
-- 0A1B2C3D4E5F.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")

local function box_state(over)
	local raw = {
		device = { name = "Living Room Box", deviceType = "HSB2", uniqueId = "0A1B2C3D4E5F", apiLevel = 14,
			firmwareVersion = "2.5.4" },
		execution = { mode = "video", syncActive = true, hdmiActive = true, hdmiSource = "input1", brightness = 100,
			lastSyncMode = "video", video = { intensity = "high" } },
		hdmi = { input1 = { name = "Apple TV", type = "appletv", status = "linked" } },
		behavior = { arcBypassMode = 0, soloMode = 0 },
		hue = { bridgeUniqueId = "001788FFFE123ABC", connectionState = "connected", groups = {} },
	}
	for k, v in pairs(over or {}) do raw.execution[k] = v end
	return raw
end

local function powersave()
	return box_state({ mode = "powersave", syncActive = false, hdmiActive = false })
end

describe("syncbox/poller.lua (#534)", function()
	local poller, c4, client, p, seen, lines

	-- The stand-in client: get records the call; the spec answers the oldest
	-- one still open. opts.handles: get returns a handle with Cancel.
	local function new_client(opts)
		opts = opts or {}
		local cl = { calls = {}, cancelled = 0 }
		function cl:get(path, cb)
			if self.raise then error("transfer refused", 0) end
			local call = { path = path, cb = cb, at = c4.now_ms }
			self.calls[#self.calls + 1] = call
			if self.sync then
				local answer = self.sync
				cb(answer[1], answer[2], answer[3], answer[4])
				call.answered = true
			end
			if opts.handles then
				return { Cancel = function() call.cancelled = true; cl.cancelled = cl.cancelled + 1 end }
			end
		end
		function cl:open()
			local n = 0
			for _, call in ipairs(self.calls) do
				if not call.answered and not call.cancelled then n = n + 1 end
			end
			return n
		end
		function cl:answer(ok, status, decoded, err)
			for _, call in ipairs(self.calls) do
				if not call.answered and not call.cancelled then
					call.answered = true
					call.cb(ok, status, decoded, err)
					return call
				end
			end
			error("no read is open")
		end
		function cl:good(raw) return self:answer(true, 200, raw or box_state()) end
		function cl:silent() return self:answer(false, nil, nil, "transfer failed (28): timeout") end
		return cl
	end

	local function new_poller(extra)
		local deps = {
			client = client,
			log = log,
			timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end,
			now = function() return c4:GetTime() end,
			on_state = function(model, changes) seen[#seen + 1] = { "state", model, changes, at = c4.now_ms } end,
			on_offline = function(since) seen[#seen + 1] = { "offline", since, at = c4.now_ms } end,
			on_online = function() seen[#seen + 1] = { "online", at = c4.now_ms } end,
			on_refused = function(status) seen[#seen + 1] = { "refused", status, at = c4.now_ms } end,
		}
		for k, v in pairs(extra or {}) do deps[k] = v end
		return poller.new(deps)
	end

	-- Runs the clock for `ms` in 100 ms steps, answering every read as soon
	-- as it is open with answer() (a list: ok, status, decoded, err).
	local function respond(ms, answer)
		local stop = c4.now_ms + ms
		while c4.now_ms < stop do
			while client:open() > 0 do
				local a = answer()
				client:answer(a[1], a[2], a[3], a[4])
			end
			c4.advance(100)
		end
	end

	local function kinds()
		local out = {}
		for _, s in ipairs(seen) do out[#out + 1] = s[1] end
		return out
	end

	local function count(kind)
		local n = 0
		for _, s in ipairs(seen) do
			if s[1] == kind then n = n + 1 end
		end
		return n
	end

	-- The times between consecutive reads from call `from` on.
	local function gaps(from)
		local out = {}
		for i = (from or 1) + 1, #client.calls do
			out[#out + 1] = client.calls[i].at - client.calls[i - 1].at
		end
		return out
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
		package.loaded["syncbox.poller"] = nil
		package.loaded["syncbox.state"] = nil
		poller = require("syncbox.poller")
		client = new_client()
		seen = {}
		p = new_poller()
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("the cadence", function()
		it("reads at once on start, the whole state (GET /api/v1), then 5 s after each answer", function()
			p:start()
			assert.equal(1, #client.calls)
			assert.equal("", client.calls[1].path)
			assert.is_true(p:is_running())
			c4.advance(200)
			client:good()
			assert.equal(1, count("state"))
			local model, changes = seen[1][2], seen[1][3]
			assert.equal("0A1B2C3D4E5F", model.id)
			assert.truthy(#changes > 5) -- the first read reports every field
			assert.equal(model, p:last_model())
			c4.advance(4999)
			assert.equal(1, #client.calls)
			c4.advance(1)
			assert.equal(2, #client.calls)
			client:good()
			assert.same({}, seen[2][3])
		end)

		it("reads every 30 s in power save, and every 5 s once the box is on again", function()
			p:start()
			client:good(powersave())
			c4.advance(29999)
			assert.equal(1, #client.calls)
			c4.advance(1)
			assert.equal(2, #client.calls)
			client:good(box_state())
			assert.same({ "power", "mode", "syncing" }, seen[2][3])
			c4.advance(5000)
			assert.equal(3, #client.calls)
		end)

		it("slows to 60 s after 3 failed reads in a row, and back to 5 s after a good one", function()
			p:start()
			client:silent()
			c4.advance(5000)
			client:silent()
			c4.advance(5000)
			client:silent()
			c4.advance(59999)
			assert.equal(3, #client.calls)
			c4.advance(1)
			assert.equal(4, #client.calls)
			client:good()
			c4.advance(5000)
			assert.equal(5, #client.calls)
			assert.same({ 5000, 5000, 60000, 5000 }, gaps())
		end)

		it("never starts two reads at once", function()
			p:start()
			for _ = 1, 15 do
				p:soon("hint")
				p:soon("command")
				c4.advance(1000)
			end
			assert.equal(1, #client.calls)
			assert.equal(1, client:open())
		end)

		it("never leaves the client two reads, even when it gives one up", function()
			client = new_client({ handles = true })
			p = new_poller()
			p:start()
			for _ = 1, 300 do
				p:soon("hint")
				c4.advance(1000)
				assert.is_true(client:open() <= 1)
			end
			assert.is_true(#client.calls > 5)
			assert.is_true(client.cancelled >= #client.calls - 1) -- every one given up was dropped
		end)

		it("keeps polling when a callback raises", function()
			p = new_poller({ on_state = function() error("driver bug") end })
			p:start()
			client:good()
			c4.advance(5000)
			assert.equal(2, #client.calls)
			local text = table.concat(lines, "\n")
			assert.truthy(text:find("on_state failed: ", 1, true))
			assert.truthy(text:find("driver bug", 1, true))
		end)

		it("counts a client that raises as a failed read and goes on", function()
			client.raise = true
			p:start()
			assert.equal(0, #client.calls)
			client.raise = false
			c4.advance(5000)
			assert.equal(1, #client.calls)
		end)

		it("copes with a client that answers inside get", function()
			client.sync = { true, 200, box_state() }
			p:start()
			assert.equal(1, count("state"))
			c4.advance(5000)
			assert.equal(2, #client.calls)
			assert.equal(2, count("state"))
		end)
	end)

	describe("soon", function()
		it("reads 1 s after a command", function()
			p:start()
			client:good()
			c4.advance(1000)
			p:soon("command")
			c4.advance(999)
			assert.equal(1, #client.calls)
			c4.advance(1)
			assert.equal(2, #client.calls)
		end)

		it("reads at once on a hint, at most one read start per 2 s", function()
			p:start()
			client:good()
			c4.advance(500)
			p:soon("hint") -- 0.5 s after the last start: waits until 2 s
			assert.equal(1, #client.calls)
			c4.advance(1499)
			assert.equal(1, #client.calls)
			c4.advance(1)
			assert.equal(2, #client.calls)
			client:good()
			c4.advance(3000)
			p:soon("hint") -- 3 s after the last start: at once
			assert.equal(3, #client.calls)
		end)

		it("follows a read in flight with the asked read", function()
			p:start()
			c4.advance(3000)
			p:soon("hint")
			p:soon("command")
			assert.equal(1, #client.calls)
			client:good() -- 3 s after the read started: the hint's read may go now
			assert.equal(1, #client.calls)
			c4.advance(1)
			assert.equal(2, #client.calls)
			client:good()
			c4.advance(4999)
			assert.equal(2, #client.calls) -- the cadence again, nothing pending
		end)

		it("keeps a read on_state asked for when it is due before the cadence's", function()
			local asked = false
			p = new_poller({ on_state = function()
				if not asked then
					asked = true
					p:soon("command")
				end
			end })
			p:start()
			client:good()
			c4.advance(1000)
			assert.equal(2, #client.calls)
		end)

		it("does nothing while stopped", function()
			p:soon("hint")
			c4.advance(60000)
			assert.equal(0, #client.calls)
		end)
	end)

	describe("offline and online (#428)", function()
		it("goes offline once after 5 minutes without an answer, online at the next good read", function()
			p:start()
			client:good()
			c4.advance(5000)
			local t0 = c4.now_ms
			client:silent()
			for _ = 1, 10 do
				c4.advance(60000)
				if client:open() > 0 then client:silent() end
				if c4.now_ms - t0 < 300000 then
					assert.equal(0, count("offline"))
				end
			end
			assert.equal(1, count("offline"))
			local off = seen[#seen]
			for _, s in ipairs(seen) do
				if s[1] == "offline" then off = s end
			end
			assert.equal(t0, off[2])
			assert.equal(t0 + 300000, off.at)
			assert.is_true(p:is_offline())
			c4.advance(60000)
			client:good()
			assert.same({ "state", "offline", "online", "state" }, kinds())
			assert.is_false(p:is_offline())
			c4.advance(5000)
			client:good()
			assert.equal(1, count("online"))
		end)

		it("does not go offline when the box comes back within 5 minutes", function()
			p:start()
			-- Silent for 200 s; the next read (at most 60 s on) is answered.
			respond(200000, function() return { false, nil, nil, "timeout" } end)
			respond(400000, function() return { true, 200, box_state() } end)
			assert.equal(0, count("offline"))
			assert.equal(0, count("online"))
			assert.is_true(count("state") > 50)
		end)

		it("counts the outage from the read that went unanswered, not from its timeout", function()
			p:start()
			client:good()
			c4.advance(5000)
			local t0 = c4.now_ms
			c4.advance(6000)
			client:silent()
			c4.advance(300000)
			for _, s in ipairs(seen) do
				if s[1] == "offline" then
					assert.equal(t0, s[2])
					assert.equal(t0 + 300000, s.at)
				end
			end
			assert.equal(1, count("offline"))
		end)

		it("is never offline while the box answers, even with errors", function()
			p:start()
			respond(720000, function() return { false, 500, { code = 500, message = "internal" }, "HTTP 500" } end)
			assert.equal(0, count("offline"))
			assert.same({ 5000, 5000, 60000, 60000 }, { gaps()[1], gaps()[2], gaps()[3], gaps()[4] })
		end)

		it("counts a body that is not the state as a failed read, not as silence", function()
			p:start()
			respond(600000, function() return { true, 200, { unexpected = true } } end)
			assert.equal(0, count("state"))
			assert.equal(0, count("offline"))
			assert.truthy(table.concat(lines, "\n"):find("not the box's state", 1, true))
		end)

		for _, err in ipairs({ "busy", "not paired", "no box address", "invalid request path" }) do
			it("does not count the client's own refusal '" .. err .. "' as silence", function()
				p:start()
				respond(600000, function() return { false, nil, nil, err } end)
				assert.equal(0, count("offline"))
				assert.equal(60000, gaps()[#gaps()])
			end)
		end

		it("gives up a read whose answer never comes, counting it unanswered", function()
			p:start()
			c4.advance(poller.READ_GUARD_MS)
			assert.equal(1, #client.calls)
			c4.advance(5000)
			assert.equal(2, #client.calls) -- the next read, though the first never answered
			client:good() -- the first one's late answer: ignored
			assert.equal(0, count("state"))
			client:good()
			assert.equal(1, count("state"))
			assert.truthy(table.concat(lines, "\n"):find("no answer within 20 s", 1, true))
		end)

		it("starts offline when the driver says so, and comes back once", function()
			p:start({ offline_since = 1234 })
			assert.is_true(p:is_offline())
			for _ = 1, 8 do
				client:silent()
				c4.advance(60000)
			end
			assert.equal(0, count("offline"))
			client:good()
			assert.same({ "online", "state" }, kinds())
		end)
	end)

	describe("refusals and stopping", function()
		for _, status in ipairs({ 401, 403 }) do
			it("stops on a " .. status .. " and says so", function()
				p:start()
				client:good()
				c4.advance(5000)
				client:answer(false, status, { code = 2, message = "Invalid Token" }, "HTTP " .. status)
				assert.same({ "state", "refused" }, kinds())
				assert.equal(status, seen[2][2])
				assert.is_false(p:is_running())
				c4.advance(600000)
				assert.equal(2, #client.calls)
				assert.equal(0, count("offline"))
			end)
		end

		it("may be started again from on_refused", function()
			p = new_poller({ on_refused = function() p:start() end })
			p:start()
			client:answer(false, 401, nil, "HTTP 401")
			assert.equal(2, #client.calls)
			assert.is_true(p:is_running())
			assert.equal(1, client:open())
		end)

		it("stops: no read, no callback, a late answer ignored", function()
			p:start()
			client:good()
			c4.advance(5000)
			p:stop()
			assert.is_false(p:is_running())
			client:good()
			assert.equal(1, count("state"))
			c4.advance(600000)
			assert.equal(2, #client.calls)
		end)

		it("does not go offline while stopped", function()
			p:start()
			client:silent()
			p:stop()
			c4.advance(600000)
			assert.equal(0, count("offline"))
		end)

		it("waits for the read of a stopped run before the first read of the next", function()
			p:start()
			p:stop()
			p:start()
			assert.equal(1, #client.calls)
			client:good() -- the stopped run's answer
			assert.equal(0, count("state"))
			assert.equal(2, #client.calls)
			client:good()
			assert.equal(1, count("state"))
		end)

		it("drops the read in flight from the client when it can, and reads at once after a start", function()
			client = new_client({ handles = true })
			p = new_poller()
			p:start()
			p:stop()
			assert.equal(1, client.cancelled)
			p:start()
			assert.equal(2, #client.calls)
			client:good()
			assert.equal(1, count("state"))
		end)

		it("reports every field again on the first read after a start", function()
			p:start()
			client:good()
			p:stop()
			p:start()
			client:good()
			assert.equal(2, count("state"))
			assert.same(seen[1][3], seen[2][3])
		end)

		it("needs a client", function()
			assert.has_error(function() poller.new({}) end)
		end)
	end)
end)
