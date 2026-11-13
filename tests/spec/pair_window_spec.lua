-- bridge/pair_window.lua (#373; contract §1.2, action 1; #236): Pair
-- Bridge's pairing window, moved out of hue_bridge/driver.lua.
-- bridge/pairing.lua is a stand-in that records each attempt and answers
-- through the handlers when the spec says; the fake C4 (fake.install_c4)
-- for the clock and the 3 s retry.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local S = 1000
local PAIRED_ID = "001788fffe123abc"
local OTHER_ID = "001788fffe456def"
local IP = "10.0.2.143"

describe("bridge/pair_window.lua (#373)", function()
	local pair_window, c4, w, state, attempts, statuses, infos, paired_with, lines

	local function last_status() return statuses[#statuses] end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
		attempts = {}
		package.loaded["bridge.pairing"] = {
			pair = function(ip, handlers, paired_id, picked)
				attempts[#attempts + 1] = { ip = ip, handlers = handlers, paired_id = paired_id, picked = picked }
			end,
		}
		package.loaded["bridge.pair_window"] = nil
		pair_window = require("bridge.pair_window")
		statuses, infos, paired_with = {}, {}, {}
		state = { ip = IP, address_gen = 1 }
		w = pair_window.new({
			state = state,
			prop = function(name, value)
				assert.equal("Status", name)
				statuses[#statuses + 1] = value
			end,
			show_bridge_info = function(info) infos[#infos + 1] = info end,
			on_paired = function(creds)
				assert.is_nil(state.pair_until, "the window is closed first")
				paired_with[#paired_with + 1] = creds
			end,
			log = log,
		})
	end)

	after_each(function()
		for _, m in ipairs({ "bridge.pairing", "bridge.pair_window" }) do package.loaded[m] = nil end
		log.set_debug(false)
		log.sink = print
	end)

	it("asks for an address first", function()
		state.ip = nil
		w:open()
		assert.same({ "Enter the bridge IP address first" }, statuses)
		assert.same({}, attempts)
	end)

	it("opens a two-minute window and reports the bridge it found", function()
		w:open()
		assert.equal(c4.now_ms + 120 * S, state.pair_until)
		assert.is_true(state.pairing_active)
		assert.same({ "Pairing: contacting bridge" }, statuses)
		assert.equal(IP, attempts[1].ip)
		attempts[1].handlers.on_probed({ model = "BSB003", bridge_id = PAIRED_ID })
		assert.same({ { model = "BSB003", bridge_id = PAIRED_ID } }, infos)
		assert.equal("Pairing: found Hue Bridge Pro (BSB003) " .. PAIRED_ID .. ", requesting key", last_status())
	end)

	it("counts down while the link button is not pressed, asking again every 3 s, then closes", function()
		w:open()
		attempts[1].handlers.on_link_button()
		assert.equal("Press the link button on the Hue bridge (waiting 2:00)", last_status())
		c4.advance(3 * S - 1)
		assert.equal(1, #attempts)
		c4.advance(1)
		assert.equal(2, #attempts)
		attempts[2].handlers.on_probed({ model = "BSB003", bridge_id = PAIRED_ID })
		assert.equal("Press the link button on the Hue bridge (waiting 2:00)", last_status(),
			"a retry does not repeat the probe's text")
		attempts[2].handlers.on_link_button()
		assert.equal("Press the link button on the Hue bridge (waiting 1:57)", last_status())
		c4.advance(117 * S)
		attempts[#attempts].handlers.on_link_button()
		assert.equal("Pairing window closed: press the link button on the Hue bridge, then run Pair Bridge again",
			last_status())
		assert.is_nil(state.pair_until)
		assert.is_false(state.pairing_active)
		assert.equal(0, #c4.active_timers())
	end)

	it("closes the window, then hands the key over", function()
		w:open()
		local creds = { key = "<key>", bridge_id = PAIRED_ID, ip = IP, model = "BSB003" }
		attempts[1].handlers.on_paired(creds)
		assert.same({ creds }, paired_with)
		assert.is_false(state.pairing_active)
	end)

	it("stores the key encrypted, once its window has checked out", function()
		w:open()
		attempts[1].handlers.on_paired({ key = "abc123", bridge_id = PAIRED_ID, ip = IP, model = "BSB003" })
		local saw_key
		for _, args in ipairs(c4.calls_to("PersistSetValue")) do
			if args[1] == "hue_app_key" then
				saw_key = true
				assert.equal("abc123", args[2])
				assert.is_true(args[3], "key must be stored encrypted")
			end
		end
		assert.is_true(saw_key)
		local creds = require("bridge.credentials").load()
		assert.same({ key = "abc123", bridge_id = PAIRED_ID, ip = IP }, creds)
		assert.equal(1, #paired_with)
	end)

	-- Security review 2026-11-13, N-9 (#490): pairing.lua stored the key
	-- before the window's checks, so a key request in flight at Forget
	-- Pairing re-paired the driver, and one in flight at an address change
	-- left a discarded pairing in the store for the next start.
	describe("a result after the window closed (N-9)", function()
		local KEY = { key = "abc123", bridge_id = PAIRED_ID, ip = IP, model = "BSB003" }

		local function nothing_stored()
			assert.same({}, c4.calls_to("PersistSetValue"))
			assert.same({}, paired_with)
		end

		it("drops a key that arrives after Forget Pairing closed the window", function()
			w:open()
			w:close() -- Forget Pairing
			statuses = {}
			attempts[1].handlers.on_paired(KEY)
			nothing_stored()
			assert.same({}, statuses, "Status keeps what Forget Pairing wrote")
			assert.truthy(table.concat(lines, "\n"):find("a key after the pairing window closed; dropped", 1, true))
		end)

		it("drops a key for an earlier address, storing nothing", function()
			w:open()
			state.address_gen = state.address_gen + 1
			attempts[1].handlers.on_paired(KEY)
			nothing_stored()
		end)

		it("drops a key of a window that another open() replaced, and keeps the new window", function()
			w:open()
			w:open()
			attempts[1].handlers.on_paired(KEY)
			nothing_stored()
			assert.is_not_nil(state.pair_until, "the new window stays open")
			attempts[2].handlers.on_paired(KEY)
			assert.equal(1, #paired_with)
		end)

		it("drops a late error, link button answer or probe without a word in Status", function()
			for _, handler in ipairs({ "on_error", "on_link_button", "on_probed" }) do
				w:open()
				w:close()
				statuses, infos = {}, {}
				attempts[#attempts].handlers[handler](handler == "on_error" and "late" or { model = "BSB003",
					bridge_id = PAIRED_ID })
				assert.same({}, statuses, handler)
				assert.same({}, infos, handler)
				assert.equal(0, #c4.active_timers(), handler)
			end
		end)
	end)

	-- The same with the real bridge/pairing.lua over the fake C4 (N-9): the
	-- probe and the key request answered by the "bridge" after the change.
	describe("with the real pairing module (N-9)", function()
		local CONFIG = '{"name":"Hue","swversion":"1968096020","apiversion":"1.68.0","bridgeid":"001788FFFE123ABC",'
			.. '"modelid":"BSB003"}'
		local KEY_ANSWER = '[{"success":{"username":"abc123","clientkey":"DEADBEEF"}}]'

		before_each(function()
			for _, m in ipairs({ "bridge.pairing", "bridge.pair_window", "bridge.http" }) do package.loaded[m] = nil end
			pair_window = require("bridge.pair_window")
			w = pair_window.new(w.ctx)
		end)

		local function key_stored()
			for _, args in ipairs(c4.calls_to("PersistSetValue")) do
				if args[1] == "hue_app_key" then return true end
			end
			return false
		end

		for _, change in ipairs({
			{ "Forget Pairing", function() w:close() end },
			{ "an address change", function() state.address_gen = state.address_gen + 1 end },
		}) do
			it("stores no key that arrives after " .. change[1], function()
				w:open()
				c4.transfers[1]:respond(200, CONFIG)
				assert.equal("https://" .. IP .. "/api", c4.transfers[2].url)
				change[2]()
				c4.transfers[2]:respond(200, KEY_ANSWER)
				assert.is_false(key_stored())
				assert.same({}, paired_with)
			end)
		end

		it("stores the key that arrives while the window is open", function()
			w:open()
			c4.transfers[1]:respond(200, CONFIG)
			c4.transfers[2]:respond(200, KEY_ANSWER)
			assert.is_true(key_stored())
			assert.equal(1, #paired_with)
		end)
	end)

	it("cuts the error's text for Status (#489)", function()
		w:open()
		attempts[1].handlers.on_error(string.rep("x", 100000))
		assert.is_true(#last_status() <= 256, #last_status() .. " bytes")
		assert.equal("Pairing failed: xxx", last_status():sub(1, 19))
	end)

	it("says why pairing failed, and closes the window", function()
		w:open()
		attempts[1].handlers.on_error("the bridge did not answer")
		assert.equal("Pairing failed: the bridge did not answer", last_status())
		assert.is_nil(state.pair_until)
	end)

	it("ignores a result for an earlier address, closing the window", function()
		for _, handler in ipairs({ "on_probed", "on_link_button", "on_paired", "on_error" }) do
			w:open()
			state.address_gen = state.address_gen + 1
			attempts[#attempts].handlers[handler]({ model = "BSB003", bridge_id = PAIRED_ID })
			assert.is_nil(state.pair_until, handler)
		end
		assert.same({}, infos)
		assert.same({}, paired_with)
		for _, status in ipairs(statuses) do
			assert.equal("Pairing: contacting bridge", status)
		end
		assert.is_truthy(table.concat(lines, "\n"):find("pairing result for an earlier bridge address ignored", 1, true))
	end)

	it("expects the stored bridge, else the one picked in Bridges Found", function()
		w:open()
		assert.is_nil(attempts[1].paired_id)
		assert.is_false(attempts[1].picked)
		state.pick_id = OTHER_ID
		w:open()
		assert.equal(OTHER_ID, attempts[2].paired_id)
		assert.is_true(attempts[2].picked)
		assert.equal(OTHER_ID, state.pair_expected_id)
		state.creds = { bridge_id = PAIRED_ID }
		w:open()
		assert.equal(PAIRED_ID, attempts[3].paired_id, "a stored id wins: another bridge is refused")
		assert.is_false(attempts[3].picked)
	end)

	it("cancels the retry on close, and a reopened window starts afresh", function()
		w:open()
		attempts[1].handlers.on_link_button()
		w:close()
		assert.is_nil(state.pair_expected_id)
		c4.advance(10 * S)
		assert.equal(1, #attempts)
		w:open()
		assert.equal(2, #attempts)
		assert.equal("Pairing: contacting bridge", last_status())
	end)
end)
