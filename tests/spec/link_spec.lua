-- bridge/link.lua (#428, docs/offline-design.md §3, §6, §8.1): the bridge's
-- link to the Hue Bridge, up, in trouble or offline after OFFLINE_AFTER_S of
-- continuous trouble; HUE_BRIDGE_LINK to every Hue device; the stored outage
-- and the first evaluation of a run (D12); the Attention item (§6.4).
-- Stand-ins for the driver's callbacks; the fake C4 (fake.install_c4) for its
-- clock, timers and store. The last block runs it with bridge/away.lua, as
-- the driver wires the two (§6.6).

local fake = require("helpers.fake_c4")
local log = require("common.log")

local S, MIN = 1000, 60000
local T0 = 1761000000000          -- ms since the epoch
local IP = "10.0.2.143"
local OTHER_ID = "001788fffe456def"

describe("bridge/link.lua (#428)", function()
	local link, c4, l, state, sent, refreshes, devices, is_paired, refusal, lines, ctx

	local function hhmm(ms)
		return os.date("%H:%M", math.floor(ms / 1000))
	end

	local function new_link()
		ctx = {
			state = state,
			paired = function() return is_paired end,
			keyed_refusal = function() return refusal end,
			now_ms = function() return c4.now_ms end,
			device_ids = function() return devices end,
			send = function(id, command, params)
				sent[#sent + 1] = { id = id, command = command, params = params }
			end,
			refresh = function() refreshes = refreshes + 1 end,
			log = log,
			clock = hhmm,
		}
		return link.new(ctx)
	end

	-- Loaded and past the first look, with what that told cleared.
	local function started()
		l:load()
		l:first_look()
		sent, refreshes = {}, 0
	end

	-- What every device was told, in order: { id, state, reason, since }.
	local function told()
		local out = {}
		for _, m in ipairs(sent) do
			assert.equal("HUE_BRIDGE_LINK", m.command)
			out[#out + 1] = { m.id, m.params.state, m.params.reason, m.params.since }
		end
		return out
	end

	local function to_all(what, reason, since_ms)
		local since = since_ms and tostring(math.floor(since_ms / 1000)) or nil
		return { { 101, what, reason, since }, { 205, what, reason, since }, { 330, what, reason, since } }
	end

	local function logged(text)
		for _, line in ipairs(lines) do
			if line:find(text, 1, true) then
				return true
			end
		end
		return false
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
		c4.now_ms = T0
		package.loaded["bridge.link"] = nil
		link = require("bridge.link")
		state = { identity_ok = true }
		sent, refreshes = {}, 0
		devices = { [330] = true, [101] = true, [205] = true }
		is_paired, refusal = true, nil
		l = new_link()
	end)

	after_each(function()
		log.sink = print
		log.set_debug(false)
	end)

	it("has the contract's constants", function()
		assert.equal(300, link.OFFLINE_AFTER_S)
		assert.equal(60, link.FIRST_LOOK_S)
		assert.equal("hue_bridge_link", link.KEY)
		assert.equal("HUE_BRIDGE_LINK", link.COMMAND)
	end)

	describe("trouble, offline and contact", function()
		it("goes offline after 300 s of continuous trouble: one message per device, the outage stored", function()
			started()
			assert.equal("up", l:status())
			l:trouble()
			assert.equal("trouble", l:status())
			c4.advance(100 * S)
			l:trouble() -- more trouble keeps the start
			c4.advance(199 * S)
			assert.same({}, sent, "nothing during the trouble")
			assert.is_false(l:offline())
			assert.is_nil(c4.persist.hue_bridge_link)
			assert.equal(0, refreshes)
			c4.advance(S)
			assert.equal("offline", l:status())
			assert.is_true(l:offline())
			assert.same(to_all("offline", "not_answering", T0), told())
			assert.same({ since = T0, reason = "not_answering" }, c4.persist.hue_bridge_link)
			assert.equal(1, refreshes, "Attention at once")
			assert.is_true(logged("[INFO] Hue devices offline: the bridge has not answered since " .. hhmm(T0)
				.. " (not_answering); 3 devices told"))
			sent = {}
			l:trouble()
			c4.advance(30 * MIN)
			assert.same({}, sent, "told once")
			assert.equal(1, #c4.calls_to("PersistSetValue"), "stored once")
		end)

		it("is silent at contact before 300 s, and the count stops", function()
			started()
			l:trouble()
			c4.advance(299 * S)
			l:contact()
			assert.equal("up", l:status())
			c4.advance(30 * MIN)
			assert.same({}, sent)
			assert.equal(0, refreshes)
			assert.same({}, c4.active_timers(), "no count, no first-look fallback")
			assert.equal(0, #c4.calls_to("PersistSetValue"))
			assert.equal(0, #c4.calls_to("PersistDeleteValue"), "nothing was stored")
		end)

		it("tells every device online at contact while offline, deletes the outage and refreshes", function()
			started()
			l:trouble()
			c4.advance(7 * MIN)
			sent, refreshes = {}, 0
			l:contact()
			assert.equal("up", l:status())
			assert.same(to_all("online"), told())
			for _, m in ipairs(sent) do
				assert.same({ state = "online" }, m.params)
			end
			assert.is_nil(c4.persist.hue_bridge_link)
			assert.equal(1, refreshes)
			assert.is_true(logged("[INFO] Hue devices online: the bridge answers again after 7 min; 3 devices told"))
			assert.same({}, l:attention_items())
			sent = {}
			l:contact()
			assert.same({}, sent, "contact while up tells nothing")
		end)

		it("starts the count again after contact (flapping): at most one offline per 300 s of trouble", function()
			started()
			l:trouble()
			c4.advance(200 * S)
			l:contact()
			c4.advance(S)
			l:trouble()
			c4.advance(299 * S)
			assert.same({}, sent)
			c4.advance(S)
			assert.same(to_all("offline", "not_answering", T0 + 201 * S), told())
		end)

		it("counts trouble seen before the first look from its start, and arms the count at the first look", function()
			l:load()
			l:trouble()
			c4.advance(59 * S)
			assert.same({}, sent, "nothing before the first look")
			assert.is_false(l:tell(101))
			assert.equal("trouble", l:status())
			c4.advance(S) -- FIRST_LOOK_S
			assert.same(to_all("online"), told())
			sent = {}
			c4.advance(239 * S)
			assert.same({}, sent)
			c4.advance(S)
			assert.same(to_all("offline", "not_answering", T0), told())
		end)
	end)

	describe("the reason (D3)", function()
		it("goes not_paired, key_rejected, blocked, other_bridge, else not_answering", function()
			assert.equal("not_answering", l:reason())
			state.identity_ok, state.unreachable_ms = false, T0
			assert.equal("not_answering", l:reason(), "nothing answers at the address")
			state.away_other = OTHER_ID
			assert.equal("other_bridge", l:reason())
			state.tls_verdict, refusal = "not_pinned", "TLS check failed"
			assert.equal("blocked", l:reason())
			state.key_rejected = 403
			assert.equal("key_rejected", l:reason())
			is_paired, refusal = false, "not paired"
			assert.equal("not_paired", l:reason())
		end)

		it("reads blocked for an unsupported model, a TLS check that stays inconclusive, or no address", function()
			state.identity_ok = false -- neither nothing answering nor another bridge
			assert.equal("blocked", l:reason())
			state.identity_ok, refusal = true, "not paired" -- paired, but Bridge IP Address is empty
			assert.equal("blocked", l:reason())
			refusal = "key rejected"
			assert.equal("key_rejected", l:reason())
		end)

		it("tells a changed reason again while offline, with the same since; the store keeps the first", function()
			started()
			l:trouble()
			c4.advance(300 * S)
			sent, refreshes = {}, 0
			l:trouble()
			l:evaluate()
			assert.same({}, sent, "the same reason is not told again")
			c4.advance(MIN)
			state.away_other = OTHER_ID
			l:trouble()
			assert.same(to_all("offline", "other_bridge", T0), told())
			assert.equal(1, refreshes)
			sent = {}
			state.key_rejected, refusal = 403, "key rejected"
			l:evaluate()
			assert.same(to_all("offline", "key_rejected", T0), told())
			assert.same({ since = T0, reason = "not_answering" }, c4.persist.hue_bridge_link)
			assert.equal(1, #c4.calls_to("PersistSetValue"))
		end)
	end)

	describe("evaluate (D2 d)", function()
		it("starts trouble while the bridge cannot be used, and never clears it", function()
			local conditions = {
				function() is_paired, refusal = false, "not paired" end,
				function() state.key_rejected, refusal = 403, "key rejected" end,
				function() state.tls_verdict, refusal = "not_pinned", "TLS check failed" end,
				function() state.identity_ok = false end,
			}
			for i, set in ipairs(conditions) do
				state = { identity_ok = true }
				is_paired, refusal = true, nil
				l = new_link()
				started()
				set()
				l:evaluate()
				assert.equal("trouble", l:status(), "condition " .. i)
				state = { identity_ok = true }
				ctx.state = state
				is_paired, refusal = true, nil
				l:evaluate()
				assert.equal("trouble", l:status(), "evaluate never ends it (" .. i .. ")")
			end
		end)

		it("is no trouble while the bridge can be used or its identity is being checked", function()
			started()
			l:evaluate()
			state.identity_ok = nil
			l:evaluate()
			assert.equal("up", l:status())
		end)
	end)

	describe("the first evaluation of a run (D12)", function()
		it("broadcasts once, at the first look, whatever the state", function()
			l:load()
			assert.same({}, sent)
			l:first_look()
			assert.same(to_all("online"), told())
			sent = {}
			l:first_look()
			c4.advance(MIN)
			assert.same({}, sent, "once")
		end)

		it("falls back to FIRST_LOOK_S without an identity answer or contact", function()
			l:load()
			c4.advance(59 * S)
			assert.same({}, sent)
			c4.advance(S)
			assert.same(to_all("online"), told())
		end)

		it("evaluates D2 (d) at the first look: an unsupported model seen only by the identity check", function()
			l:load()
			state.identity_ok = false -- bridge/identity.lua, with no refresh_status() and no away call
			c4.advance(60 * S)
			assert.equal("trouble", l:status())
			assert.same(to_all("online"), told())
			sent = {}
			c4.advance(300 * S)
			assert.same(to_all("offline", "blocked", T0 + 60 * S), told())
		end)

		it("runs at the first contact, which deletes a stored outage: a bridge back during a restart", function()
			c4.persist.hue_bridge_link = { since = T0 - 20 * MIN, reason = "not_answering" }
			l:load()
			l:contact()
			assert.same(to_all("online"), told())
			assert.is_nil(c4.persist.hue_bridge_link)
			assert.equal("up", l:status())
			assert.equal(0, refreshes)
			sent = {}
			c4.advance(MIN)
			assert.same({}, sent, "the fallback went")
		end)

		it("goes offline at once at a failed first check after a stored outage over 300 s old", function()
			local since = T0 - 20 * MIN
			c4.persist.hue_bridge_link = { since = since, reason = "not_answering" }
			l:load()
			l:trouble()
			assert.same({}, sent)
			l:first_look()
			assert.equal("offline", l:status())
			assert.same(to_all("offline", "not_answering", since), told())
			assert.equal(0, #c4.calls_to("PersistSetValue"), "stored already")
			assert.equal(1, refreshes)
			assert.same({ "Hue devices offline since " .. hhmm(since + 300 * S) .. ": the bridge has not answered since "
				.. hhmm(since) .. "; they come back by themselves when it answers" }, l:attention_items())
		end)

		it("counts on from a stored outage under 300 s old", function()
			c4.persist.hue_bridge_link = { since = T0 - 200 * S, reason = "not_answering" }
			l:load()
			l:trouble()
			l:first_look()
			assert.same(to_all("online"), told())
			sent = {}
			c4.advance(99 * S)
			assert.same({}, sent)
			c4.advance(S)
			assert.same(to_all("offline", "not_answering", T0 - 200 * S), told())
		end)

		it("keeps a stored outage's start after the fallback, until contact", function()
			local since = T0 - 20 * MIN
			c4.persist.hue_bridge_link = { since = since, reason = "not_answering" }
			l:load()
			c4.advance(60 * S)
			assert.same(to_all("online"), told(), "no trouble seen yet")
			sent = {}
			c4.advance(30 * S)
			l:trouble() -- the identity check failed late
			assert.same(to_all("offline", "not_answering", since), told())
		end)

		it("counts trouble seen before load() from a stored outage's start", function()
			local since = T0 - 20 * MIN
			l:trouble()
			c4.persist.hue_bridge_link = { since = since, reason = "key_rejected" }
			l:load()
			l:first_look()
			assert.same(to_all("offline", "not_answering", since), told(), "the reason is derived now")
		end)

		it("deletes a malformed stored outage, and keeps a well-formed one", function()
			local bad = { "x", 7, true, {}, { since = "abc", reason = "not_answering" }, { since = T0 },
				{ reason = "not_answering" }, { since = -5, reason = "not_answering" },
				{ since = T0 + MIN, reason = "not_answering" }, { since = T0 - MIN, reason = 4 },
				-- #487: no time os.date cannot take.
				{ since = "nan", reason = "not_answering" }, { since = "-inf", reason = "not_answering" } }
			for i, value in ipairs(bad) do
				c4.persist.hue_bridge_link = value
				l = new_link()
				l:load()
				assert.is_nil(c4.persist.hue_bridge_link, "value " .. i)
				l:cancel()
			end
			c4.persist.hue_bridge_link = { since = T0 - MIN, reason = "not_answering" }
			l = new_link()
			l:load()
			assert.same({ since = T0 - MIN, reason = "not_answering" }, c4.persist.hue_bridge_link)
		end)
	end)

	describe("tell (D4: first in every hello's answer)", function()
		it("sends nothing before the first look, then the state to the one device", function()
			l:load()
			assert.is_false(l:tell(205))
			assert.same({}, sent)
			l:first_look()
			sent = {}
			assert.is_true(l:tell(205))
			assert.same({ { 205, "online" } }, told())
			assert.is_false(l:tell(nil), "a hello without a device id")
			sent = {}
			c4.now_ms = T0 + 1234
			l:trouble()
			c4.advance(300 * S)
			sent = {}
			assert.is_true(l:tell(205))
			assert.same({ { 205, "offline", "not_answering", "1761000001" } }, told(), "since in whole seconds")
		end)

		it("gives each device its own params", function()
			started()
			l:trouble()
			c4.advance(300 * S)
			sent[1].params.state = "changed by a receiver"
			assert.equal("offline", sent[2].params.state)
			assert.equal("offline", l:params().state)
		end)

		it("goes on to the other devices when one send raises", function()
			started()
			ctx.send = function(id, command, params)
				if id == 205 then error("no such device") end
				sent[#sent + 1] = { id = id, command = command, params = params }
			end
			l:trouble()
			c4.advance(300 * S)
			assert.same({ { 101, "offline", "not_answering", tostring(T0 / 1000) },
				{ 330, "offline", "not_answering", tostring(T0 / 1000) } }, told())
			assert.is_true(logged("[WARN] bridge link: HUE_BRIDGE_LINK to device 205 failed"))
		end)

		it("tells no one when the devices cannot be listed, and says so", function()
			l:load()
			ctx.device_ids = function() error("modules not created") end
			l:first_look()
			assert.same({}, sent)
			assert.is_true(logged("[WARN] bridge link: the devices could not be listed"))
		end)
	end)

	describe("the Attention item (§6.4)", function()
		local function offline_with(set)
			started()
			set()
			l:trouble()
			c4.advance(300 * S)
			return l:attention_items()
		end

		local function item(phrase, tail)
			return { "Hue devices offline since " .. hhmm(T0 + 300 * S) .. ": the bridge " .. phrase .. " since "
				.. hhmm(T0) .. "; " .. tail }
		end

		it("is there only while offline", function()
			started()
			assert.same({}, l:attention_items())
			l:trouble()
			c4.advance(299 * S)
			assert.same({}, l:attention_items(), "not during the trouble")
		end)

		it("says the bridge has not answered", function()
			assert.same(item("has not answered", "they come back by themselves when it answers"),
				offline_with(function() end))
		end)

		it("says the bridge is not at its address", function()
			assert.same(item("is not at its address", "they come back by themselves when it answers"),
				offline_with(function() state.identity_ok, state.away_other = false, OTHER_ID end))
		end)

		it("says the bridge refuses the pairing", function()
			assert.same(item("refuses the pairing",
				"they come back once it accepts it (re-pair with Pair Bridge if it stays)"),
				offline_with(function() state.key_rejected, refusal = 403, "key rejected" end))
		end)

		it("says the bridge cannot be used", function()
			assert.same(item("cannot be used", "see Status"),
				offline_with(function() state.tls_verdict, refusal = "not_pinned", "TLS check failed" end))
		end)

		it("says the bridge is not paired", function()
			assert.same(item("is not paired", "run Pair Bridge"),
				offline_with(function() is_paired, refusal = false, "not paired" end))
		end)

		it("shows another day's times with the date (away:clock's rule when no clock is given)", function()
			ctx.clock = nil
			started()
			l:trouble()
			c4.advance(48 * 60 * MIN)
			local text = l:attention_items()[1]
			assert.is_truthy(text:find("since " .. os.date("%m-%d %H:%M", math.floor((T0 + 300 * S) / 1000)) .. ":", 1,
				true), text)
		end)

		it("lists nothing when there are no Hue devices to be offline", function()
			devices = {}
			assert.same({}, offline_with(function() end))
			assert.is_true(l:offline())
		end)
	end)

	describe("timers", function()
		it("cancel() ends the count and the first-look fallback", function()
			l:load()
			l:cancel()
			c4.advance(MIN)
			assert.same({}, sent)
			l:first_look()
			sent = {}
			l:trouble()
			l:cancel()
			c4.advance(30 * MIN)
			assert.same({}, sent)
			assert.is_false(l:offline())
		end)

		it("start nothing once the driver is destroyed", function()
			l:load()
			state.destroyed = true
			c4.advance(MIN)
			assert.same({}, sent)
			state.destroyed = false
			l:first_look()
			sent = {}
			l:trouble()
			state.destroyed = true
			c4.advance(300 * S)
			assert.same({}, sent)
			assert.is_false(l:offline())
		end)

		it("log a callback that raises instead of passing it on", function()
			started()
			ctx.refresh = function() error("rows broke") end
			l:trouble()
			assert.has_no.errors(function() c4.advance(300 * S) end)
			assert.is_true(l:offline())
			assert.is_true(logged("[ERROR] bridge link: timer failed:"))
		end)

		it("follow a shorter OFFLINE_AFTER_S at retime (Link_Offline_After, D15), and a longer one by themselves",
			function()
				started()
				l:trouble()
				c4.advance(20 * S)
				link.OFFLINE_AFTER_S = 30
				l:retime()
				c4.advance(9 * S)
				assert.same({}, sent)
				c4.advance(S)
				assert.is_true(l:offline())
				l:contact()
				l:trouble()
				c4.advance(40 * S)
				l:contact()
				-- Shorter than the trouble already lasted: offline at the retime.
				l:trouble()
				link.OFFLINE_AFTER_S = 300
				c4.advance(60 * S)
				link.OFFLINE_AFTER_S = 30
				sent = {}
				l:retime()
				assert.is_true(l:offline())
				assert.equal(3, #sent)
				l:contact()
				-- Longer, without a retime: the count re-arms when it falls due.
				l:trouble()
				link.OFFLINE_AFTER_S = 600
				c4.advance(300 * S)
				assert.is_false(l:offline())
				c4.advance(300 * S)
				assert.is_true(l:offline())
			end)

		it("retime changes nothing while up, offline or before the first look", function()
			l:load()
			l:trouble()
			link.OFFLINE_AFTER_S = 10
			l:retime()
			assert.is_false(l:offline(), "before the first look")
			l:cancel()
			l = new_link()
			started()
			l:retime()
			assert.equal("up", l:status())
		end)
	end)

	-- With bridge/away.lua, wired as the driver does (§6.6, the examples of §3).
	describe("with bridge/away.lua", function()
		local away, a, verifies, running

		before_each(function()
			package.loaded["bridge.away"] = nil
			away = require("bridge.away")
			verifies, running = {}, true
			state.ip = IP
			state.creds = { bridge_id = "001788fffe123abc", key = "<key>" }
			state.address_gen = 1
			state.stream = { running = function() return running end, start = function() end }
			a = away.new({
				state = state,
				paired = function() return is_paired end,
				keyed_refusal = function() return refusal end,
				use_netstream = function() return true end,
				heard_elsewhere = function() return nil end,
				offer = function() end,
				refresh = function() end,
				refresh_status = function() end,
				verify_identity = function(purpose, callback)
					verifies[#verifies + 1] = { purpose = purpose, callback = callback }
				end,
				log = log,
				now_ms = function() return c4.now_ms end,
			})
			a.ctx.link = l -- set after away.new, as the driver may
			ctx.clock = function(ms) return a:clock(ms) end
			l:load()
		end)

		-- The identity check's failure, as bridge/identity.lua reports it.
		local function check_fails()
			state.identity_ok = false
			a:unreachable()
		end

		it("never shows a 3-minute bridge restart: trouble, then contact", function()
			state.identity_ok = true
			a:answered(IP)
			a:stream_status("Connected since 14:02")
			assert.same(to_all("online"), told(), "the first look")
			sent = {}
			a:stream_status("Disconnected: connection refused") -- t0: the stream drops
			assert.equal("trouble", l:status())
			c4.advance(60 * S)
			assert.equal(1, #verifies, "the outage check")
			for _ = 1, 4 do
				c4.advance(10 * S)
				check_fails()
				c4.advance(20 * S)
			end
			state.identity_ok = true
			a:answered(IP)
			assert.equal("up", l:status())
			a:stream_status("Connecting")
			a:stream_status("Connected since 14:05")
			c4.advance(30 * MIN)
			assert.same({}, sent)
		end)

		it("shows a 20-minute power cut: offline at 5 minutes, online at the first contact", function()
			state.identity_ok = true
			a:answered(IP)
			a:stream_status("Connected since 14:02")
			sent = {}
			local t0 = c4.now_ms
			a:stream_status("Disconnected: connection refused")
			c4.advance(60 * S)
			while c4.now_ms < t0 + 20 * MIN do
				c4.advance(10 * S)
				check_fails()
				c4.advance(20 * S)
			end
			assert.same(to_all("offline", "not_answering", t0), told())
			assert.same({ since = t0, reason = "not_answering" }, c4.persist.hue_bridge_link)
			assert.equal("Hue devices offline since " .. a:clock(t0 + 300 * S) .. ": the bridge has not answered since "
				.. a:clock(t0) .. "; they come back by themselves when it answers", l:attention_items()[1])
			sent = {}
			state.identity_ok = true
			a:answered(IP)
			assert.same(to_all("online"), told())
			assert.is_nil(c4.persist.hue_bridge_link)
		end)

		it("goes offline at the first failed check after a restart during a long outage", function()
			c4.persist.hue_bridge_link = { since = T0 - 20 * MIN, reason = "not_answering" }
			l:cancel()
			l = new_link()
			ctx.clock = function(ms) return a:clock(ms) end
			a.ctx.link = l
			l:load()
			check_fails()
			assert.same(to_all("offline", "not_answering", T0 - 20 * MIN), told())
		end)

		it("reads another bridge at the address as other_bridge", function()
			state.identity_ok = false
			a:other_bridge(OTHER_ID)
			assert.same(to_all("online"), told(), "the first look, in trouble since now")
			sent = {}
			c4.advance(300 * S)
			assert.same(to_all("offline", "other_bridge", T0), told())
		end)

		it("is not contact when the identity passes with the key rejected", function()
			state.key_rejected, refusal = 403, "key rejected"
			l:evaluate()
			state.identity_ok = true
			a:answered(IP)
			assert.equal("trouble", l:status())
			assert.same(to_all("online"), told(), "the first look")
			sent = {}
			c4.advance(300 * S)
			assert.same(to_all("offline", "key_rejected", T0), told())
		end)
	end)
end)
