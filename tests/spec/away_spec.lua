-- bridge/away.lua (#373; contract §1.3, owner's answers D5 and D12,
-- discovery research §2.5): the paired bridge away and the event stream
-- down, moved out of hue_bridge/driver.lua. The measures, the Attention
-- items they bring after an hour, the identity check after an outage, the
-- follow-up search and the resync a connect needs. Stand-ins for the
-- driver's callbacks; the fake C4 (fake.install_c4) for its clock, timers
-- and store.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local S, MIN, HOUR = 1000, 60000, 3600000
local T0 = 1761000000000          -- ms since the epoch
local PAIRED_ID = "001788fffe123abc"
local OTHER_ID = "001788fffe456def"
local IP = "10.0.2.143"

describe("bridge/away.lua (#373)", function()
	local away, c4, a, state, refusal, netstream_on, heard, offers, refreshes, statuses, verifies, pokes, starts
	local running

	local function clock(ms)
		return os.date("%H:%M", math.floor(ms / 1000))
	end

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		c4.now_ms = T0
		package.loaded["bridge.away"] = nil
		away = require("bridge.away")
		refusal, netstream_on, heard, offers, refreshes, statuses, verifies, pokes, starts = nil, true, nil, 0, 0, 0, {},
			{}, 0
		running = true
		state = {
			ip = IP, creds = { bridge_id = PAIRED_ID, key = "<key>" }, address_gen = 1,
			stream = {
				running = function() return running end,
				start = function() starts = starts + 1 end,
			},
			hk = { poke = function(_, name, why) pokes[#pokes + 1] = name .. " " .. why end },
		}
		a = away.new({
			state = state,
			paired = function() return state.creds ~= nil and state.creds.key ~= nil end,
			keyed_refusal = function() return refusal end,
			use_netstream = function() return netstream_on end,
			heard_elsewhere = function() return heard end,
			offer = function() offers = offers + 1 end,
			refresh = function() refreshes = refreshes + 1 end,
			refresh_status = function() statuses = statuses + 1 end,
			verify_identity = function(purpose, callback)
				verifies[#verifies + 1] = { purpose = purpose, callback = callback }
			end,
			log = log,
			now_ms = function() return c4.now_ms end,
		})
	end)

	after_each(function()
		log.sink = print
	end)

	describe("the Attention items", function()
		it("lists nothing while not paired or without an address", function()
			a:unreachable()
			c4.advance(2 * HOUR)
			state.creds = nil
			assert.same({}, a:attention_items())
			state.creds, state.ip = { bridge_id = PAIRED_ID, key = "<key>" }, nil
			assert.same({}, a:attention_items())
		end)

		it("says the bridge is not answering once it has been away an hour", function()
			a:unreachable()
			c4.advance(HOUR - 1)
			assert.same({}, a:attention_items())
			c4.advance(1)
			assert.same({ "Bridge 123ABC not answering at " .. IP .. " since " .. clock(T0) .. ": check its power, or "
				.. "type its address in Bridge IP Address" }, a:attention_items())
		end)

		it("says another bridge answers there", function()
			a:other_bridge(OTHER_ID)
			c4.advance(HOUR)
			assert.same({ "Bridge 123ABC not found at " .. IP .. " since " .. clock(T0) .. ": another bridge answers "
				.. "there; check its power, or type its address in Bridge IP Address" }, a:attention_items())
		end)

		it("says missing once the follow-up found it nowhere, at the address where it last answered", function()
			state.last_good_ip = IP
			a:unreachable()
			c4.advance(30 * MIN)
			a:find_missed()
			c4.advance(30 * MIN)
			assert.same({ "Bridge 123ABC missing since " .. clock(T0) .. ": not found on the network (searched "
				.. clock(T0 + 30 * MIN) .. "); check its power, or type its address in Bridge IP Address" },
				a:attention_items())
		end)

		it("offers where Bridges Found heard it, for an address typed by hand, at once", function()
			state.last_good_ip, heard = "192.0.2.140", "192.0.2.150"
			assert.same({ "Bridge 123ABC answers at 192.0.2.150, not at the typed " .. IP .. ": pick it in Bridges Found" },
				a:attention_items())
			state.identity_ok = true
			assert.same({}, a:attention_items(), "not once the typed address verified")
		end)

		it("says the stream is down an hour while the bridge answers, with the other transport as remedy", function()
			-- Down from the start (no drop of a connected stream, so no outage check either).
			state.identity_ok = true
			a:stream_status("Disconnected: no data for 120 s (watchdog)")
			c4.advance(HOUR)
			local text = "Event stream down since " .. clock(T0) .. " while the bridge answers (lists read every 10 "
				.. "minutes): "
			assert.same({ text .. "set Event Stream Transport to Web transfer if it stays" }, a:attention_items())
			netstream_on = false
			assert.same({ text .. "set Event Stream Transport to Network connection if it stays" }, a:attention_items())
			state.net_check = "not_pinned"
			assert.same({ text .. "restart the bridge if it stays" }, a:attention_items())
			refusal = "key rejected"
			assert.same({}, a:attention_items(), "not while nothing keyed goes out")
			refusal, running = nil, false
			assert.same({}, a:attention_items(), "not for a stream stopped on purpose")
		end)

		it("keeps the text of a move the follow-up made for a day, at that address", function()
			a:moved("192.0.2.140", IP, "The bridge moved from 192.0.2.140 to " .. IP)
			assert.same({ "The bridge moved from 192.0.2.140 to " .. IP }, a:attention_items())
			state.ip = "192.0.2.144"
			assert.same({}, a:attention_items())
			state.ip = IP
			c4.advance(24 * HOUR)
			assert.same({}, a:attention_items())
		end)

		it("shows another day's times with the date", function()
			a:unreachable()
			c4.advance(48 * HOUR)
			local item = a:attention_items()[1]
			assert.is_truthy(item:find("since " .. os.date("%m-%d %H:%M", math.floor(T0 / 1000)), 1, true), item)
		end)
	end)

	describe("the identity check's answers", function()
		it("ends the away measures when the bridge answers, and keeps the address it answered at", function()
			a:unreachable()
			a:find_missed()
			a:answered(IP)
			assert.is_nil(state.away_ms)
			assert.is_nil(state.unreachable_ms)
			assert.is_nil(state.find_missed_ms)
			assert.equal(IP, state.last_good_ip)
			assert.equal(IP, c4.persist.hue_bridge_last_good_ip)
			assert.equal(1, refreshes, "Attention's away item goes at once")
			a:answered(IP)
			assert.equal(1, #c4.calls_to("PersistSetValue"), "stored once")
			assert.equal(1, refreshes, "nothing was away")
		end)

		it("measures another bridge from its first answer, refreshing once per id", function()
			a:other_bridge(OTHER_ID)
			c4.advance(MIN)
			a:other_bridge(OTHER_ID)
			assert.equal(T0, state.away_ms)
			assert.equal(OTHER_ID, state.away_other)
			assert.equal(1, refreshes)
			assert.equal(2, offers, "Bridges Found's offer every time")
			assert.same({}, pokes, "no follow-up at an address the bridge never answered at")
			state.last_good_ip = IP
			a:other_bridge(OTHER_ID)
			assert.same({ "find_bridge error" }, pokes, "at once, where it last answered")
		end)

		it("measures an unreachable bridge, and asks for the follow-up after 300 s", function()
			state.last_good_ip = IP
			a:other_bridge(OTHER_ID)
			pokes = {}
			c4.advance(MIN)
			a:unreachable()
			assert.is_nil(state.away_other, "nothing answers now")
			assert.equal(2, refreshes)
			assert.equal(T0, state.away_ms, "away since the first failure")
			assert.equal(T0 + MIN, state.unreachable_ms)
			assert.same({}, pokes)
			c4.advance(300 * S - 1)
			a:unreachable()
			assert.same({}, pokes)
			c4.advance(1)
			a:unreachable()
			assert.same({ "find_bridge error" }, pokes)
			assert.equal(4, offers)
		end)

		it("asks for the follow-up only paired, at the last good address, with the tasks running", function()
			state.last_good_ip = IP
			state.hk = nil
			a:want_find()
			state.hk = { poke = function(_, name) pokes[#pokes + 1] = name end }
			state.creds = nil
			a:want_find()
			state.creds = { bridge_id = PAIRED_ID, key = "<key>" }
			state.ip = "192.0.2.144"
			a:want_find()
			assert.same({}, pokes)
			state.ip = IP
			a:want_find()
			assert.same({ "find_bridge" }, pokes)
		end)
	end)

	describe("the stream's status and the identity check after an outage", function()
		before_each(function()
			state.identity_ok = true
			a:stream_status("Connected since 14:02")
		end)

		it("measures an outage from its first status, with the first Disconnected reason", function()
			assert.is_true(state.stream_connected)
			c4.advance(S)
			a:stream_status("Connecting")
			c4.advance(S)
			a:stream_status("Disconnected: no data for 120 s (watchdog)")
			a:stream_status("Disconnected: connection refused")
			assert.is_false(state.stream_connected)
			assert.equal(T0 + S, state.stream_down_ms)
			assert.equal("Disconnected: no data for 120 s (watchdog)", state.stream_down_reason)
		end)

		it("checks the bridge's identity again 60 s into an outage, then starts the stream", function()
			a:stream_status("Disconnected: no data for 120 s (watchdog)")
			c4.advance(60 * S - 1)
			assert.same({}, verifies)
			c4.advance(1)
			assert.equal(1, #verifies)
			assert.equal("stream", verifies[1].purpose)
			assert.is_nil(state.identity_ok, "keyed requests wait for it")
			assert.equal(1, state.outage_restart)
			assert.equal(1, statuses)
			verifies[1].callback(true)
			assert.equal(1, starts)
			assert.is_nil(state.outage_restart)
		end)

		it("does not start the stream after a failed check, a disconnect or an address change", function()
			a:stream_status("Disconnected")
			c4.advance(60 * S)
			verifies[1].callback(false)
			state.identity_ok = true
			a:stream_status("Connected since 14:10")
			a:stream_status("Disconnected")
			c4.advance(60 * S)
			state.outage_restart = nil -- Disconnect Event Stream
			verifies[2].callback(true)
			state.identity_ok = true
			a:stream_status("Connected since 14:20")
			a:stream_status("Disconnected")
			c4.advance(60 * S)
			state.address_gen = 2
			verifies[3].callback(true)
			assert.equal(0, starts)
		end)

		it("checks nothing when the stream comes back in time, was stopped, or nothing keyed goes out", function()
			a:stream_status("Disconnected")
			c4.advance(30 * S)
			a:stream_status("Connected since 14:03")
			c4.advance(60 * S)
			running = false
			a:stream_status("Stopped")
			c4.advance(60 * S)
			running = true
			a:stream_status("Connected since 14:05")
			a:stream_status("Disconnected")
			refusal = "key rejected"
			c4.advance(60 * S)
			assert.same({}, verifies)
		end)

		it("asks for the follow-up after 300 s of outage only while the bridge itself does not answer", function()
			state.last_good_ip = IP
			a:stream_status("Disconnected")
			c4.advance(300 * S)
			assert.equal(1, #verifies, "the outage check ran at 60 s")
			state.identity_ok = true -- and passed: the bridge answers, the stream fails on its own
			a:stream_status("Connecting")
			assert.same({}, pokes)
			state.identity_ok = false
			a:stream_status("Connecting")
			assert.same({ "find_bridge error" }, pokes)
		end)

		it("cancels the check on reset, forget and cancel_outage_check", function()
			for _, stop in ipairs({ "reset", "forget", "cancel_outage_check" }) do
				state.identity_ok = true
				a:stream_status("Connected since 14:02")
				a:stream_status("Disconnected")
				a[stop](a)
				c4.advance(60 * S)
			end
			assert.same({}, verifies)
		end)
	end)

	-- The bridge link's inputs (bridge/link.lua; #428 D2, D12, docs/offline-design.md §6.6).
	describe("the link (#428)", function()
		local calls, seen

		before_each(function()
			calls, seen = {}, {}
			local function note(name)
				return function()
					calls[#calls + 1] = name
					-- What the link reads when it derives its reason (D3).
					seen[#seen + 1] = { name, state.unreachable_ms, state.away_ms, state.away_other }
				end
			end
			-- Set after away.new, as the driver may: looked up at every call.
			a.ctx.link = { trouble = note("trouble"), contact = note("contact"), first_look = note("first_look") }
		end)

		it("is trouble at a drop of a running, connected stream; not at a stop or an attempt that never connected",
			function()
				state.identity_ok = true
				a:stream_status("Connecting")
				a:stream_status("Disconnected: connection refused")
				assert.same({}, calls, "never connected")
				a:stream_status("Connected since 14:02")
				running = false
				a:stream_status("Stopped")
				assert.same({ "contact" }, calls, "a stop (Diagnostics, a rejected key) is not trouble")
				running = true
				a:stream_status("Connected since 14:03")
				a:stream_status("Disconnected: no data for 600 s (watchdog)")
				a:stream_status("Connecting")
				a:stream_status("Disconnected: connection refused")
				assert.same({ "contact", "contact", "trouble" }, calls, "one trouble per drop")
			end)

		it("is contact at every \"Connected since\"", function()
			a:stream_status("Connected since 14:02")
			a:stream_status("Connected since 14:02")
			assert.same({ "contact", "contact" }, calls)
		end)

		it("is trouble, then the first look, when nothing or another bridge answers, with the measures set", function()
			a:unreachable()
			assert.same({ "trouble", "first_look" }, calls)
			assert.same({ "trouble", T0, T0, nil }, seen[1])
			a:other_bridge(OTHER_ID)
			assert.same({ "trouble", "first_look", "trouble", "first_look" }, calls)
			assert.same({ "trouble", T0, T0, OTHER_ID }, seen[3])
			c4.advance(MIN)
			a:unreachable()
			assert.same({ "trouble", T0, T0, nil }, seen[5], "nothing answers now: no other bridge")
		end)

		it("is contact when the identity passes without a keyed refusal, and the first look always", function()
			a:unreachable()
			calls, seen = {}, {}
			a:answered(IP)
			assert.same({ "contact", "first_look" }, calls)
			assert.same({ "contact", nil, nil, nil }, seen[1], "the away measures went first")
			calls = {}
			refusal = "key rejected"
			a:answered(IP)
			assert.same({ "first_look" }, calls, "a rejected key: no contact")
		end)

		it("changes nothing without a link, or with a link that lacks a method", function()
			for _, given in ipairs({ false, {} }) do
				a.ctx.link = given or nil
				state.identity_ok = true
				a:stream_status("Connected since 14:02")
				a:stream_status("Disconnected")
				a:unreachable()
				a:other_bridge(OTHER_ID)
				a:answered(IP)
				c4.advance(60 * S)
			end
			assert.equal(2, #verifies, "the outage check still runs")
			assert.equal(IP, state.last_good_ip)
		end)

		it("logs a link that raises and goes on", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local function boom() error("link broke") end
			a.ctx.link = { trouble = boom, contact = boom, first_look = boom }
			state.identity_ok = true
			a:stream_status("Connected since 14:02")
			a:stream_status("Disconnected")
			a:unreachable()
			a:answered(IP)
			c4.advance(60 * S)
			assert.equal(1, #verifies, "the outage check was armed after the trouble call")
			assert.equal(IP, state.last_good_ip)
			assert.is_nil(state.away_ms)
			assert.equal(1, refreshes, "the away item went at once")
			assert.equal(6, #lines)
			assert.is_truthy(lines[1]:find("[ERROR] bridge link: contact failed: ", 1, true), lines[1])
			assert.is_truthy(lines[2]:find("[ERROR] bridge link: trouble failed: ", 1, true), lines[2])
		end)
	end)

	describe("the resync a connect needs", function()
		it("is full at the first connect, quick after a short silence, full after a long outage or an error", function()
			assert.equal("full", a:connect_tier(), "the first connect of the run")
			a:stream_status("Disconnected: no data for 120 s (watchdog)")
			c4.advance(599 * S)
			assert.equal("quick", a:connect_tier())
			assert.is_nil(state.stream_down_ms)
			assert.is_nil(state.stream_down_reason)
			a:stream_status("Disconnected: no data for 120 s (watchdog)")
			c4.advance(600 * S)
			assert.equal("full", a:connect_tier(), "an outage of 10 minutes or more")
			a:stream_status("Disconnected: HTTP 503")
			c4.advance(S)
			assert.equal("full", a:connect_tier(), "not a silence")
			assert.equal("full", a:connect_tier(), "no outage measured")
		end)
	end)

	describe("the store", function()
		it("loads the last good address and a well-formed move", function()
			c4.persist.hue_bridge_last_good_ip = IP
			c4.persist.hue_bridge_moved = { from = "192.0.2.140", to = IP, text = "moved", at = T0 }
			a:load()
			assert.equal(IP, state.last_good_ip)
			assert.same({ from = "192.0.2.140", to = IP, text = "moved", at = T0 }, state.moved)
		end)

		it("ignores a move that is not well formed", function()
			for _, bad in ipairs({ "moved", { to = IP, text = "moved" }, { to = 7, text = "moved", at = T0 },
				{ to = IP, at = T0 } }) do
				state.moved = nil
				c4.persist.hue_bridge_moved = bad
				a:load()
				assert.is_nil(state.moved)
			end
		end)

		it("stores a move, and Forget Pairing deletes it with every measure", function()
			a:moved("192.0.2.140", IP, "moved")
			assert.same({ from = "192.0.2.140", to = IP, text = "moved", at = T0 }, c4.persist.hue_bridge_moved)
			a:unreachable()
			a:other_bridge(OTHER_ID)
			a:find_missed()
			state.offer_gen, state.outage_restart = 1, 1
			a:forget()
			for _, k in ipairs({ "moved", "away_ms", "unreachable_ms", "find_missed_ms", "away_other", "offer_gen",
				"outage_restart" }) do
				assert.is_nil(state[k], k)
			end
			assert.is_nil(c4.persist.hue_bridge_moved)
		end)

		it("keeps the move and the offer at an address change, dropping what was measured there", function()
			a:moved("192.0.2.140", IP, "moved")
			a:unreachable()
			a:other_bridge(OTHER_ID)
			state.offer_gen, state.outage_restart = 1, 1
			a:reset()
			for _, k in ipairs({ "away_ms", "unreachable_ms", "find_missed_ms", "away_other", "outage_restart" }) do
				assert.is_nil(state[k], k)
			end
			assert.equal(1, state.offer_gen)
			assert.is_table(state.moved)
		end)
	end)
end)
