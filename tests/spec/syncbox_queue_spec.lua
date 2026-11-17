-- syncbox/queue.lua (#557, docs/hdmi-sync-stage3-design.md §3, contracts C3
-- and C4): one queue of execution writes to the Hue Play HDMI Sync Box; a
-- burst merged to its latest values, one PUT at a time with the fields the
-- box applies in its own order (docs/syncbox-behaviour.md SB55), a write
-- answered only when a read after its PUT shows it, 4 tries 2 s apart, code
-- 16 reported busy and not retried. The first part drives the queue with a
-- stand-in client and poller on the fake clock (tests/helpers/fake_c4.lua,
-- c4.advance); the last part runs it with the real client and poller
-- against the Lua fake box (tests/helpers/fake_syncbox.lua). Placeholders
-- only: box 10.0.2.150, id 0A1B2C3D4E5F, token TEST-TOKEN-NOT-REAL.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_syncbox")

local BUSY_ANSWER = { false, 400, { code = 16, message = "Invalid State" }, "HTTP 400, box error 16: Invalid State" }
local TIMEOUT = "transfer failed (28): timeout"

-- A model as syncbox/state.lua makes it (contracts C2), only the fields the
-- queue reads.
local function model(over)
	local m = { power = "on", mode = "passthrough", syncing = false, input = 1, brightness = 100,
		intensity = "high", area = F.AREA.tv }
	for k, v in pairs(over or {}) do m[k] = v end
	return m
end

describe("syncbox/queue.lua (#557)", function()
	local queue, c4, client, poller, q, done, lines

	-- The stand-in client: put records the call and answers when the spec
	-- says (client.auto(call) answers at once with its list).
	local function new_client()
		local cl = { puts = {} }
		function cl:put(path, body, cb)
			local call = { path = path, body = body, cb = cb, at = c4.now_ms }
			self.puts[#self.puts + 1] = call
			if self.auto then
				local a = self.auto(call)
				if a then
					call.answered = true
					cb(a[1], a[2], a[3], a[4])
				end
			end
			return { Cancel = function() call.cancelled = true end }
		end
		function cl:open()
			for _, call in ipairs(self.puts) do
				if not call.answered and not call.cancelled then return call end
			end
		end
		function cl:answer(ok, status, decoded, err)
			local call = assert(self:open(), "no PUT is open")
			call.answered = true
			call.cb(ok, status, decoded, err)
			return call
		end
		function cl:ok() return self:answer(true, 200, {}) end
		function cl:last() return self.puts[#self.puts] end
		return cl
	end

	local function new_queue(extra)
		local deps = {
			client = client,
			poller = poller,
			log = log,
			timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end,
			now = function() return c4:GetTime() end,
			on_done = function(tag, ok, m, why, detail)
				done[#done + 1] = { tag = tag, ok = ok, model = m, why = why, detail = detail, at = c4.now_ms }
			end,
		}
		for k, v in pairs(extra or {}) do deps[k] = v end
		return queue.new(deps)
	end

	-- What ended, as "tag:ok" or "tag:why", in order.
	local function ended()
		local out = {}
		for _, d in ipairs(done) do out[#out + 1] = tostring(d.tag) .. ":" .. (d.ok and "ok" or tostring(d.why)) end
		return out
	end

	local function gaps()
		local out = {}
		for i = 2, #client.puts do out[#out + 1] = client.puts[i].at - client.puts[i - 1].at end
		return out
	end

	local function logged(text)
		for _, line in ipairs(lines) do
			if line:find(text, 1, true) then return true end
		end
		return false
	end

	before_each(function()
		lines, done = {}, {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
		package.loaded["syncbox.queue"] = nil
		queue = require("syncbox.queue")
		client = new_client()
		poller = { soons = {} }
		function poller:soon(reason) self.soons[#self.soons + 1] = { reason = reason, at = c4.now_ms } end
		q = new_queue()
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("the fields", function()
		it("takes the execution fields of stage 3 by the box's names and refuses anything else whole", function()
			assert.is_false((q:set({ incrementBrightness = 10 }, "inc")))
			assert.is_false((q:set({ toggleSyncActive = true }, "toggle")))
			assert.is_false((q:set({ brightness = 201 }, "b")))
			assert.is_false((q:set({ brightness = 50.5 }, "b")))
			assert.is_false((q:set({ mode = "ambient" }, "m")))
			assert.is_false((q:set({ hdmiSource = "input5" }, "s")))
			assert.is_false((q:set({ hdmiActive = "true" }, "a")))
			assert.is_false((q:set({ intensity = "loud" }, "i")))
			assert.is_false((q:set({ hueTarget = "../x" }, "t")))
			assert.is_false((q:set({ brightness = 50, colour = 1 }, "mixed")), "nothing of a refused set is kept")
			assert.is_false((q:set({}, "empty")))
			assert.equal(0, q:pending())
			c4.advance(1000)
			assert.equal(0, #client.puts)
			assert.is_true(q:set({ hdmiSource = 3, hueTarget = "groups/2", brightness = "80" }, "fine"))
			c4.advance(queue.COALESCE_MS)
			assert.same({ hdmiSource = "input3", hueTarget = "groups/2", brightness = 80 }, client.puts[1].body)
			assert.equal("/execution", client.puts[1].path)
		end)
	end)

	describe("one PUT in the box's order (SB55)", function()
		it("puts the intensity in the mode's object and lists the fields as the box applies them", function()
			local body, parts = queue.body_of({ brightness = 120, syncActive = true, mode = "game",
				intensity = "subtle", hdmiSource = "input2", hdmiActive = true, hueTarget = F.AREA.office })
			assert.same({ "hdmiActive=true", "hdmiSource=input2", "hueTarget=" .. F.AREA.office, "mode=game",
				"syncActive=true", "game.intensity=subtle", "brightness=120" }, parts)
			assert.same({ intensity = "subtle" }, body.game)
			assert.is_nil(body.intensity, "the mode's own object, so the intensity lands on the new mode")
			local index = {}
			for i, k in ipairs(queue.ORDER) do index[k] = i end
			for _, pair in ipairs({ { "hdmiActive", "hdmiSource" }, { "hdmiSource", "hueTarget" },
				{ "hueTarget", "mode" }, { "mode", "syncActive" }, { "syncActive", "video" }, { "music", "intensity" },
				{ "intensity", "brightness" } }) do
				assert.is_true(index[pair[1]] < index[pair[2]], pair[1] .. " before " .. pair[2])
			end
		end)

		it("sends an intensity without a sync mode on its own (the current or last sync mode's, SB44)", function()
			local body, parts = queue.body_of({ intensity = "subtle", mode = "powersave" })
			assert.same({ mode = "powersave", intensity = "subtle" }, body)
			assert.same({ "mode=powersave", "intensity=subtle" }, parts)
			assert.same({ intensity = "moderate" }, (queue.body_of({ intensity = "moderate" })))
		end)

		it("logs each PUT with its fields in that order", function()
			q:set({ syncActive = true, mode = "video" }, "sync")
			q:set({ hdmiSource = "input2", hdmiActive = true }, "input")
			c4.advance(queue.COALESCE_MS)
			assert.is_true(logged("PUT /execution hdmiActive=true, hdmiSource=input2, mode=video, syncActive=true"))
		end)
	end)

	describe("coalescing", function()
		it("sends a burst within 100 ms as one PUT: Director's ON, then SET_INPUT for video and audio", function()
			q:set({ hdmiActive = true }, "on")
			q:set({ hdmiActive = true, hdmiSource = "input2" }, "video")
			q:set({ mode = "video", syncActive = true }, "sync")
			c4.advance(60)
			q:set({ hdmiActive = true, hdmiSource = "input2" }, "audio")
			c4.advance(39)
			assert.equal(0, #client.puts)
			c4.advance(1)
			assert.equal(1, #client.puts)
			assert.same({ hdmiActive = true, hdmiSource = "input2", mode = "video", syncActive = true },
				client.puts[1].body)
			client:ok()
			q:observe(model({ input = 2, mode = "video", syncing = true }))
			assert.same({ "on:ok", "video:ok", "sync:ok", "audio:ok" }, ended())
		end)

		it("merges a slider's burst into one more PUT with the latest value; the ones overtaken are superseded", function()
			q:set({ brightness = 100 }, 100)
			c4.advance(queue.COALESCE_MS)
			assert.equal(1, #client.puts)
			for v = 110, 190, 10 do
				q:set({ brightness = v }, v)
				c4.advance(50)
			end
			assert.equal(1, #client.puts, "one PUT at a time")
			assert.equal(9, #done)
			for i = 1, 9 do
				assert.equal(queue.SUPERSEDED, done[i].why)
				assert.equal(90 + i * 10, done[i].tag)
			end
			client:ok()
			c4.advance(queue.COALESCE_MS)
			assert.equal(2, #client.puts)
			assert.same({ brightness = 190 }, client.puts[2].body)
			client:ok()
			q:observe(model({ brightness = 190 }))
			assert.same({ tag = 190, ok = true }, { tag = done[10].tag, ok = done[10].ok })
			c4.advance(10000)
			assert.equal(2, #client.puts)
		end)

		it("sends at once on flush, and after the answer when a PUT is out", function()
			q:set({ brightness = 80 }, "a")
			assert.is_true(q:flush())
			assert.equal(1, #client.puts)
			q:set({ intensity = "subtle" }, "b")
			assert.is_false(q:flush())
			assert.equal(1, #client.puts)
			client:ok()
			c4.advance(queue.COALESCE_MS)
			assert.equal(2, #client.puts)
			assert.same({ brightness = 80, intensity = "subtle" }, client.puts[2].body,
				"every write not shown yet goes again with the new one")
		end)
	end)

	describe("latest wins, in the box's terms", function()
		it("makes Room Off after a sync start power save only, so SB55's order cannot wake the box again", function()
			q:set({ hdmiActive = true, hdmiSource = "input2" }, "input")
			q:set({ mode = "video", syncActive = true }, "sync")
			q:set({ mode = "powersave" }, "off")
			assert.same({ "input:superseded", "sync:superseded" }, ended())
			c4.advance(queue.COALESCE_MS)
			assert.same({ mode = "powersave" }, client.puts[1].body)
		end)

		it("drops a power save for a later wake, and a wake or sync for a later hdmiActive false", function()
			q:set({ mode = "powersave" }, "off")
			q:set({ hdmiActive = true }, "on")
			assert.same({ "off:superseded" }, ended())
			q:set({ syncActive = true }, "sync")
			q:set({ hdmiActive = false }, "sleep")
			assert.same({ "off:superseded", "on:superseded", "sync:superseded" }, ended())
			c4.advance(queue.COALESCE_MS)
			assert.same({ hdmiActive = false }, client.puts[1].body)
		end)

		it("keeps stop-syncing and power save together (SB33): DISCONNECT_OUTPUT next to OFF", function()
			q:set({ syncActive = false }, "leave")
			q:set({ mode = "powersave" }, "off")
			assert.same({}, ended())
			c4.advance(queue.COALESCE_MS)
			assert.same({ mode = "powersave", syncActive = false }, client.puts[1].body)
			client:ok()
			q:observe(model({ power = "powersave", mode = "powersave", syncing = false }))
			assert.same({ "leave:ok", "off:ok" }, ended())
		end)

		it("lets Do not sync overtake a sync start, and a new sync overtake passthrough and Do not sync", function()
			q:set({ mode = "video", syncActive = true }, "s1")
			q:set({ syncActive = false }, "n1")
			assert.same({ "s1:superseded" }, ended())
			q:set({ mode = "passthrough" }, "p1")
			assert.same({ "s1:superseded" }, ended(), "passthrough and syncActive false agree")
			q:set({ mode = "game" }, "s2")
			assert.same({ "s1:superseded", "n1:superseded", "p1:superseded" }, ended())
			q:set({ syncActive = true }, "s3")
			assert.equal(3, #done, "the same sync stands with it")
			c4.advance(queue.COALESCE_MS)
			assert.same({ mode = "game", syncActive = true }, client.puts[1].body)
		end)

		it("keeps writes of the same value side by side, and a new value overtakes them all", function()
			q:set({ hdmiSource = "input2" }, "video")
			q:set({ hdmiSource = "input2" }, "audio")
			assert.equal(0, #done)
			q:set({ hdmiSource = "input3" }, "next")
			assert.same({ "video:superseded", "audio:superseded" }, ended())
		end)
	end)

	describe("confirmation (contracts C4)", function()
		it("answers a write only when a read after its PUT's answer shows every field", function()
			q:set({ hdmiActive = true, hdmiSource = "input2" }, "input")
			c4.advance(queue.COALESCE_MS)
			q:observe(model({ input = 2 }))
			assert.equal(0, #done, "a read before the answer says nothing about the PUT")
			client:ok()
			assert.same({ { reason = "command", at = c4.now_ms } }, poller.soons)
			q:observe(model({ input = 1 }))
			q:observe(model({ input = 2, power = "powersave", mode = "powersave" }))
			assert.equal(0, #done)
			local shown = model({ input = 2 })
			q:observe(shown)
			assert.same({ "input:ok" }, ended())
			assert.equal(shown, done[1].model)
			c4.advance(10000)
			assert.equal(1, #client.puts, "nothing left to try")
		end)

		it("tries 4 times 2 s apart, then ends 'not landed'", function()
			client.auto = function() return { true, 200, {} } end
			q:set({ hdmiSource = "input3" }, "input")
			c4.advance(queue.COALESCE_MS)
			for try = 1, 4 do
				assert.equal(try, #client.puts)
				c4.advance(1000)
				q:observe(model({ input = 1 }))
				c4.advance(1000)
			end
			assert.equal(4, #client.puts)
			assert.same({ 2000, 2000, 2000 }, gaps())
			assert.same({ "input:not landed" }, ended())
			assert.is_nil(done[1].detail, "the box answered every PUT")
			c4.advance(10000)
			assert.equal(4, #client.puts)
		end)

		it("ends ok when the third try lands, and tries no more", function()
			client.auto = function() return { true, 200, {} } end
			q:set({ mode = "game", syncActive = true }, "sync")
			c4.advance(queue.COALESCE_MS)
			for _ = 1, 2 do
				c4.advance(1000)
				q:observe(model())
				c4.advance(1000)
			end
			assert.equal(3, #client.puts)
			c4.advance(1000)
			q:observe(model({ mode = "game", syncing = true }))
			assert.same({ "sync:ok" }, ended())
			c4.advance(10000)
			assert.equal(3, #client.puts)
		end)

		it("waits for the read it asked for, at most 3 s, before it counts a try", function()
			client.auto = function() return { true, 200, {} } end
			q:set({ hdmiSource = "input2" }, "input")
			c4.advance(queue.COALESCE_MS)
			c4.advance(2000)
			assert.equal(1, #client.puts, "no read yet: not a miss")
			c4.advance(500)
			q:observe(model({ input = 1 }))
			assert.equal(2, #client.puts, "the read came and did not show it: the next try at once")
			c4.advance(2000 + 2999)
			assert.equal(2, #client.puts)
			c4.advance(1)
			assert.equal(3, #client.puts, "no read at all: counted after 3 s more")
		end)

		it("tries a PUT with no answer, or a 5xx, again 2 s later, and ends with that failure after 4", function()
			client.auto = function()
				if #client.puts % 2 == 1 then return { false, nil, nil, TIMEOUT } end
				return { false, 503, nil, "HTTP 503" }
			end
			q:set({ hdmiActive = true }, "on")
			c4.advance(queue.COALESCE_MS)
			c4.advance(3 * 2000)
			assert.equal(4, #client.puts)
			assert.same({ 2000, 2000, 2000 }, gaps())
			assert.equal(0, #poller.soons, "no read is asked for a PUT that failed")
			c4.advance(2000)
			assert.same({ "on:not landed" }, ended())
			assert.equal("HTTP 503", done[1].detail)
		end)

		it("still takes a read that shows a write whose PUT got no answer (the box did it, the answer was lost)",
			function()
				client.auto = function() return { false, nil, nil, TIMEOUT } end
				q:set({ hdmiSource = "input4" }, "input")
				c4.advance(queue.COALESCE_MS)
				q:observe(model({ input = 4 }))
				assert.same({ "input:ok" }, ended())
			end)

		it("gives up a PUT whose answer never comes after 20 s, and tries again 2 s later", function()
			q:set({ brightness = 60 }, "b")
			c4.advance(queue.COALESCE_MS)
			c4.advance(queue.PUT_GUARD_MS - 1)
			assert.is_nil(client.puts[1].cancelled)
			c4.advance(1)
			assert.is_true(client.puts[1].cancelled)
			c4.advance(2000)
			assert.equal(2, #client.puts)
		end)

		it("counts a read seen twice once", function()
			client.auto = function() return { true, 200, {} } end
			q:set({ hdmiSource = "input2" }, "input")
			c4.advance(queue.COALESCE_MS + 1000)
			local wrong = model({ input = 1 })
			q:observe(wrong)
			c4.advance(1000)
			assert.equal(2, #client.puts)
			q:observe(wrong)
			c4.advance(2000)
			assert.equal(2, #client.puts, "the same read again is no new read")
		end)
	end)

	describe("refusals", function()
		it("reports code 16 busy for the sync and never retries it; the wake and input go again at once", function()
			q:set({ hdmiActive = true, hdmiSource = "input2" }, "input")
			q:set({ mode = "video", syncActive = true }, "sync")
			c4.advance(queue.COALESCE_MS)
			client:answer(BUSY_ANSWER[1], BUSY_ANSWER[2], BUSY_ANSWER[3], BUSY_ANSWER[4])
			assert.same({ "sync:busy" }, ended())
			assert.equal(BUSY_ANSWER[4], done[1].detail)
			c4.advance(queue.COALESCE_MS)
			assert.equal(2, #client.puts)
			assert.same({ hdmiActive = true, hdmiSource = "input2" }, client.puts[2].body)
			client:ok()
			c4.advance(1000)
			q:observe(model({ input = 2 }))
			assert.same({ "sync:busy", "input:ok" }, ended())
			c4.advance(20000)
			assert.equal(2, #client.puts)
		end)

		it("ends a PUT that starts no sync busy too on code 16, without a loop", function()
			client.auto = function() return BUSY_ANSWER end
			q:set({ brightness = 50 }, "b")
			c4.advance(queue.COALESCE_MS)
			assert.same({ "b:busy" }, ended())
			c4.advance(20000)
			assert.equal(1, #client.puts)
		end)

		it("ends the writes of a PUT the box refused (codes 13, 15, a token it no longer knows), not retried", function()
			for _, a in ipairs({
				{ false, 400, { code = 15, message = "Invalid Value" }, "HTTP 400, box error 15: Invalid Value" },
				{ false, 400, { code = 13, message = "Invalid Key" }, "HTTP 400, box error 13: Invalid Key" },
				{ false, 401, { code = 2, message = "Unauthorized" }, "HTTP 401, box error 2: Unauthorized" },
			}) do
				done = {}
				local before = #client.puts
				q:set({ hdmiSource = "input2" }, "input")
				q:set({ mode = "music", syncActive = true }, "sync")
				c4.advance(queue.COALESCE_MS)
				client:answer(a[1], a[2], a[3], a[4])
				assert.same({ "input:refused", "sync:refused" }, ended())
				assert.equal(a[4], done[1].detail)
				c4.advance(10000)
				assert.equal(before + 1, #client.puts)
			end
		end)

		it("ends at once what the client would not send (not paired, no address), and retries its full queue",
			function()
				client.auto = function() return { false, nil, nil, "not paired" } end
				q:set({ hdmiActive = true }, "on")
				c4.advance(queue.COALESCE_MS)
				assert.same({ "on:not sent" }, ended())
				assert.equal("not paired", done[1].detail)
				client.auto = function() return { false, nil, nil, "busy" } end
				q:set({ hdmiActive = true }, "on2")
				c4.advance(queue.COALESCE_MS + 2000)
				assert.equal(3, #client.puts)
				assert.equal(1, #done)
			end)
	end)

	describe("callbacks, clear and stop", function()
		it("calls a set's own callback instead of on_done, and survives one that raises", function()
			local own = {}
			q:set({ hdmiSource = "input2" }, "mine", function(tag, ok) own[#own + 1] = { tag, ok } end)
			q:set({ brightness = 90 }, "raises", function() error("boom") end)
			c4.advance(queue.COALESCE_MS)
			client:ok()
			q:observe(model({ input = 2, brightness = 90 }))
			assert.same({ { "mine", true } }, own)
			assert.equal(0, #done)
			assert.is_true(logged("callback failed"))
		end)

		it("lets a callback set again (a chained write)", function()
			q:set({ hdmiActive = true }, "on", function()
				q:set({ hdmiSource = "input3" }, "next")
			end)
			c4.advance(queue.COALESCE_MS)
			client:ok()
			q:observe(model())
			c4.advance(queue.COALESCE_MS)
			assert.equal(2, #client.puts)
			assert.same({ hdmiSource = "input3" }, client.puts[2].body)
		end)

		it("clear ends every write 'cancelled' and sends nothing more", function()
			q:set({ hdmiSource = "input2" }, "a")
			q:set({ brightness = 70 }, "b")
			q:clear()
			assert.same({ "a:cancelled", "b:cancelled" }, ended())
			c4.advance(10000)
			assert.equal(0, #client.puts)
			assert.is_true(q:idle())
		end)

		it("stop drops everything without a callback, ignores a late answer, and refuses sets until start", function()
			q:set({ hdmiSource = "input2" }, "a")
			c4.advance(queue.COALESCE_MS)
			q:stop()
			assert.is_true(client.puts[1].cancelled)
			client.puts[1].cb(true, 200, {})
			q:observe(model({ input = 2 }))
			assert.is_false((q:set({ brightness = 10 }, "b")))
			c4.advance(30000)
			assert.equal(0, #done)
			assert.equal(1, #client.puts)
			assert.equal(0, #c4.active_timers())
			q:start()
			assert.is_true(q:set({ brightness = 10 }, "c"))
		end)
	end)

	describe("against the Lua fake box (the real client and poller)", function()
		local clientmod, pollermod, h, c, p

		local function rig(state)
			for _, m in ipairs({ "common.https", "syncbox.client", "syncbox.poller", "syncbox.state" }) do
				package.loaded[m] = nil
			end
			clientmod, pollermod = require("syncbox.client"), require("syncbox.poller")
			h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN }, state = state })
			local timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end
			local now = function() return c4:GetTime() end
			c = clientmod.new({ address = F.ADDRESS, token = F.TOKEN, log = log, timer = timer, now = now })
			c:set_trusted(true)
			p = pollermod.new({ client = c, timer = timer, now = now, log = log,
				on_state = function(m) q:observe(m) end })
			q = new_queue({ client = c, poller = p })
			p:start()
		end

		local function to_powersave()
			local status = h:request("PUT", "/execution", { Authorization = "Bearer " .. F.TOKEN },
				{ mode = "powersave" })
			assert.equal(200, status)
			p:soon("hint")
			c4.advance(2000)
			assert.equal("powersave", p:last_model().mode)
		end

		it("wakes, switches and syncs from power save with one PUT (SB31, SB39, SB55), confirmed by a read 1 s on",
			function()
				rig()
				to_powersave()
				q:set({ hdmiActive = true }, "on")
				q:set({ hdmiActive = true, hdmiSource = "input2" }, "input")
				q:set({ mode = "game", syncActive = true }, "sync")
				c4.advance(queue.COALESCE_MS)
				local puts = h:requests_of("PUT", "/api/v1/execution")
				assert.equal(2, #puts, "the set-up's, then one")
				assert.same({ hdmiActive = true, hdmiSource = "input2", mode = "game", syncActive = true }, puts[2].json)
				assert.equal("game", h:value("execution.mode"))
				assert.equal("input2", h:value("execution.hdmiSource"))
				assert.equal(0, #done, "not before a read shows it")
				c4.advance(999)
				assert.equal(0, #done)
				c4.advance(1)
				assert.same({ "on:ok", "input:ok", "sync:ok" }, ended())
			end)

		it("puts a new mode's intensity on that mode (SB55) and confirms it", function()
			rig()
			q:set({ mode = "music", syncActive = true, intensity = "intense", brightness = 150 }, "sync")
			c4.advance(queue.COALESCE_MS + 1000)
			assert.same({ "sync:ok" }, ended())
			assert.equal("intense", h:value("execution.music.intensity"))
			assert.equal("high", h:value("execution.video.intensity"), "the old mode's untouched")
			assert.equal(150, h:value("execution.brightness"))
		end)

		it("leaves the box in power save when Room Off follows a sync start in the same burst", function()
			rig()
			q:set({ hdmiActive = true, hdmiSource = "input2" }, "input")
			q:set({ mode = "game", syncActive = true }, "sync")
			q:set({ mode = "powersave" }, "off")
			c4.advance(queue.COALESCE_MS + 1000)
			assert.equal("powersave", h:value("execution.mode"))
			assert.same({ "input:superseded", "sync:superseded", "off:ok" }, ended())
		end)

		it("switches the input while another app streams, and reports the sync busy (SB91, code 16)", function()
			rig()
			assert.equal(200, (h:request("PUT", "/execution", { Authorization = "Bearer " .. F.TOKEN },
				{ syncActive = false })))
			h:event("bridge", { state = "busy" })
			q:set({ hdmiActive = true, hdmiSource = "input2" }, "input")
			q:set({ mode = "game", syncActive = true }, "sync")
			c4.advance(queue.COALESCE_MS)
			assert.same({ "sync:busy" }, ended())
			c4.advance(queue.COALESCE_MS + 1000)
			assert.same({ "sync:busy", "input:ok" }, ended())
			assert.equal("input2", h:value("execution.hdmiSource"))
			assert.equal("passthrough", h:value("execution.mode"))
			local puts = h:requests_of("PUT", "/api/v1/execution")
			assert.equal(3, #puts, "the SB33 set-up, the refused PUT, the one without the sync")
			assert.equal(400, puts[2].status)
			assert.same({ hdmiActive = true, hdmiSource = "input2" }, puts[3].json)
			c4.advance(20000)
			assert.equal(3, #h:requests_of("PUT", "/api/v1/execution"))
		end)

		it("tries a PUT lost on the way again, and it lands", function()
			rig()
			h:fault("silence", { method = "PUT", count = 1 })
			q:set({ hdmiSource = "input3" }, "input")
			c4.advance(queue.COALESCE_MS)
			c4.advance(6000)   -- the client's timeout (contracts C2): curl 28
			assert.equal(0, #done)
			c4.advance(2000)   -- the next try
			c4.advance(1000)   -- its read
			assert.same({ "input:ok" }, ended())
			assert.equal(2, #h:requests_of("PUT", "/api/v1/execution"))
			assert.equal("input3", h:value("execution.hdmiSource"))
		end)
	end)
end)
