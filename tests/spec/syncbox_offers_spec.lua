-- syncbox/offers.lua (2.0 beta stage 4, #568; docs/hdmi-sync-stage4-design.md
-- §1.4 and §5, design §5.4 and §5.8, contracts C1.4, C1.5 and C2, owner's
-- answers O4 and O18; edge cases B24, I1): the box's own input switching and
-- CEC power save, shown, on Attention while Control4 routes through the box,
-- and turned off or put back only by a click that records what it changed.
-- The writes go through the real client to the Lua fake box
-- (tests/helpers/fake_syncbox.lua), whose PUT /behavior applies them
-- (docs/syncbox-behaviour.md SB60 to SB63). Placeholders only: box
-- 10.0.2.150, id 0A1B2C3D4E5F, token TEST-TOKEN-NOT-REAL.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_syncbox")

local AUTH = { Authorization = "Bearer " .. F.TOKEN }

describe("syncbox/offers.lua (#568)", function()
	local offers, state, c4, h, c, o, soons, answers, lines

	local function model()
		return assert(state.from_api(h:view()))
	end

	-- A read: the box's state now, as the poller hands it over.
	local function read()
		o:observe(model())
	end

	local function new_offers(extra)
		local deps = {
			client = c,
			poller = { soon = function(_, reason) soons[#soons + 1] = reason end },
			log = log,
			now = function() return c4:GetTime() end,
		}
		for k, v in pairs(extra or {}) do deps[k] = v end
		return offers.new(deps)
	end

	local function rig(fixture)
		for _, name in ipairs({ "common.https", "syncbox.client", "syncbox.state", "syncbox.offers" }) do
			package.loaded[name] = nil
		end
		state, offers = require("syncbox.state"), require("syncbox.offers")
		local clientmod = require("syncbox.client")
		h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN }, state = F.copy(F.state[fixture or "HSB2"]) })
		local timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end
		c = clientmod.new({ address = F.ADDRESS, token = F.TOKEN, log = log, timer = timer,
			now = function() return c4:GetTime() end })
		c:set_trusted(true)
		o = new_offers()
		read()
	end

	local function click(value)
		local before = #answers
		local handled = o:choose(value, function(ok, text) answers[#answers + 1] = { ok = ok, text = text } end)
		assert.is_true(handled)
		return answers[before + 1]
	end

	local function puts()
		return h:requests_of("PUT", "/api/v1/behavior")
	end

	local function behavior()
		return h:value("behavior")
	end

	local function stored_sets()
		local out = {}
		for _, args in ipairs(c4.calls_to("PersistSetValue")) do
			if args[1] == offers.KEY then out[#out + 1] = args end
		end
		return out
	end

	before_each(function()
		soons, answers, lines = {}, {}, {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
	end)

	after_each(function()
		for _, line in ipairs(lines) do
			assert.is_nil(line:find(F.TOKEN, 1, true), "a log line holds the token: " .. line)
		end
		log.set_debug(false)
		log.sink = print
	end)

	describe("what the box does by itself (contracts C1.4, B24)", function()
		it("names each setting that is on in the Input Switching row, by input", function()
			rig("HSB2")
			assert.equal("By the box: HDMI CEC switching on HDMI 1, 2; auto-sync on HDMI 1; power save when the TV "
				.. "turns off", o:row())
			rig("HSB1")
			assert.equal("By the box: HDMI CEC switching on HDMI 1, 2; hot-plug switching; power save when the TV "
				.. "turns off", o:row(), "usbPowersave is no CEC behaviour and is not named")
			rig("HSB3")
			assert.equal("By the box: HDMI CEC switching on HDMI 1; hot-plug switching on HDMI 1; auto-sync on HDMI 1; "
				.. "power save when the TV turns off", o:row())
		end)

		it("shows a dash before any read, and None when nothing is on", function()
			rig("HSB2")
			o = new_offers()
			assert.equal(offers.UNKNOWN, o:row())
			assert.equal(offers.LABEL_LET .. " (once the box has been read)", o:choices()[1].text)
			local s = F.copy(F.state.HSB2)
			s.behavior.cecPowersave = 0
			for n = 1, 4 do
				s.behavior["input" .. n] = { cecInputSwitch = 0, linkAutoSync = 0, hpdInputPortSwitch = 0 }
			end
			o:observe(assert(state.from_api(s)))
			assert.equal("None: the box neither switches inputs nor starts syncing by itself", o:row())
			assert.equal(offers.LABEL_LET .. " (nothing to turn off)", o:choices()[1].text)
		end)

		it("I1: Attention while the box switches inputs and Control4 routes through it; never otherwise", function()
			rig("HSB2")
			assert.equal("The box switches inputs by itself (HDMI CEC switching on HDMI 1, 2) while Control4 routes "
				.. "through it: Control4 may show the wrong source (Sync Box Settings: Let Control4 choose inputs)",
				o:attention(true))
			assert.is_nil(o:attention(false), "the box is in no path Control4 routes")
			-- B24: auto-sync and power save alone stay on the row.
			h.state.behavior.input1.cecInputSwitch = 0
			h.state.behavior.input2.cecInputSwitch = 0
			read()
			assert.is_nil(o:attention(true))
			assert.truthy(o:row():find("auto-sync on HDMI 1", 1, true))
			-- Hot-plug counts as switching too, box-wide or per input.
			h.state.behavior.input3.hpdInputPortSwitch = 1
			read()
			assert.truthy(o:attention(true):find("hot-plug switching on HDMI 3", 1, true))
		end)

		it("lists the input pair always, then the wirings the box is not in, each saying what it would change",
			function()
				rig("HSB2")
				assert.same({
					{ text = "Let Control4 choose inputs (turns off HDMI CEC switching on HDMI 1, 2; auto-sync on HDMI 1; "
						.. "power save when the TV turns off)", value = offers.OFFER_LET },
					{ text = "Restore the box's input switching (nothing recorded to put back)", value = offers.OFFER_RESTORE },
					{ text = "Set the box to Behind a receiver (ARC bypass on, solo mode off)",
						value = "wiring:behind_receiver" },
					{ text = "Set the box to From a receiver's second output (solo mode on, ARC bypass off)",
						value = "wiring:second_output" },
				}, o:choices())
			end)

		it("never writes by itself: reads, rows, choices and Attention send nothing", function()
			rig("HSB2")
			for i = 1, 6 do
				-- The Hue Sync app moves the wiring around meanwhile (W22).
				h.state.behavior.arcBypassMode = i % 2
				h.state.behavior.soloMode = i % 3 == 0 and 1 or 0
				read()
				o:row()
				o:choices()
				o:attention(true)
			end
			assert.equal(0, #puts())
			assert.equal(0, #stored_sets())
			assert.is_false(o:choose("something else", function() error("not ours") end))
		end)
	end)

	describe("Let Control4 choose inputs (O4, O18)", function()
		it("turns off exactly what is on, in one PUT, and records the values first", function()
			rig("HSB2")
			local a = click(offers.OFFER_LET)
			assert.is_true(a.ok)
			assert.equal("Sent: the box no longer does HDMI CEC switching on HDMI 1, 2; auto-sync on HDMI 1; power "
				.. "save when the TV turns off by itself; Control4 chooses its inputs (Sync Box Settings: Restore the "
				.. "box's input switching puts it back)", a.text)
			assert.equal(1, #puts())
			assert.same({ cecPowersave = 0, input1 = { cecInputSwitch = 0, linkAutoSync = 0 },
				input2 = { cecInputSwitch = 0 } }, puts()[1].json)
			local b = behavior()
			assert.equal(0, b.cecPowersave)
			assert.same({ cecInputSwitch = 0, linkAutoSync = 0, hpdInputPortSwitch = 0 }, b.input1)
			assert.equal(20, b.inactivePowersave, "left alone")
			assert.same({ "command" }, soons, "a read follows")
			local sets = stored_sets()
			assert.equal(1, #sets)
			assert.is_false(sets[1][3], "plain: no encrypted flag")
			assert.same({ cecPowersave = 1, ["input1.cecInputSwitch"] = 1, ["input1.linkAutoSync"] = 1,
				["input2.cecInputSwitch"] = 1 }, sets[1][2].values)
			assert.equal(F.BOX_ID, sets[1][2].box_id)
			read()
			assert.equal("None: turned off from Control4 (Sync Box Settings can restore the box's own)", o:row())
			assert.is_nil(o:attention(true))
			assert.equal("Restore the box's input switching (puts back HDMI CEC switching on HDMI 1, 2; auto-sync on "
				.. "HDMI 1; power save when the TV turns off)", o:choices()[2].text)
		end)

		it("HSB1: turns off the box-wide hot-plug switch and leaves usbPowersave; sends no level-10 key", function()
			rig("HSB1")
			assert.is_true(click(offers.OFFER_LET).ok)
			assert.same({ cecPowersave = 0, hpdInputSwitch = 0, input1 = { cecInputSwitch = 0 },
				input2 = { cecInputSwitch = 0 } }, puts()[1].json)
			assert.equal(1, behavior().usbPowersave)
		end)

		it("HSB3: one input with its hot-plug port switch; no box-wide hot-plug key", function()
			rig("HSB3")
			assert.is_true(click(offers.OFFER_LET).ok)
			assert.same({ cecPowersave = 0, input1 = { cecInputSwitch = 0, hpdInputPortSwitch = 0, linkAutoSync = 0 } },
				puts()[1].json)
			assert.is_nil(behavior().hpdInputSwitch)
		end)

		it("with nothing on, sends nothing and keeps any record", function()
			rig("HSB2")
			click(offers.OFFER_LET)
			read()
			local a = click(offers.OFFER_LET)
			assert.is_true(a.ok)
			assert.truthy(a.text:find("^Nothing to change"))
			assert.equal(1, #puts())
			assert.same({ cecPowersave = 1, ["input1.cecInputSwitch"] = 1, ["input1.linkAutoSync"] = 1,
				["input2.cecInputSwitch"] = 1 }, o:record().values)
		end)

		it("a second click adds only what is on again and keeps the values recorded first", function()
			rig("HSB2")
			click(offers.OFFER_LET)
			-- The Hue Sync app turns CEC on HDMI 2 on again.
			h.state.behavior.input2.cecInputSwitch = 1
			read()
			assert.truthy(o:attention(true))
			assert.is_true(click(offers.OFFER_LET).ok)
			assert.same({ input2 = { cecInputSwitch = 0 } }, puts()[2].json)
			assert.same({ cecPowersave = 1, ["input1.cecInputSwitch"] = 1, ["input1.linkAutoSync"] = 1,
				["input2.cecInputSwitch"] = 1 }, o:record().values)
		end)

		it("refuses a click before the box was read", function()
			rig("HSB2")
			o = new_offers()
			local a = click(offers.OFFER_LET)
			assert.is_false(a.ok)
			assert.truthy(a.text:find("not been read yet", 1, true))
			assert.equal(0, #puts())
		end)

		it("a refused PUT changed nothing (SB20): the record is rolled back", function()
			rig("HSB2")
			h:fault("5xx", { status = 400, body = { code = 15, message = "Invalid Value" }, method = "PUT",
				path = "/behavior", count = 1 })
			local a = click(offers.OFFER_LET)
			assert.is_false(a.ok)
			assert.equal("Not changed: the box refused the change (Invalid Value)", a.text)
			assert.is_nil(o:record())
			assert.equal(1, behavior().cecPowersave)
			assert.same({ offers.KEY }, c4.calls_to("PersistDeleteValue")[1])
		end)

		it("a PUT with no answer may have landed: the record stays, Restore stays offered", function()
			rig("HSB2")
			h:silence(true)
			local a
			o:choose(offers.OFFER_LET, function(ok, text) a = { ok = ok, text = text } end)
			assert.is_nil(a)
			c4.advance(20000)
			assert.is_false(a.ok)
			assert.truthy(a.text:find("^Not confirmed: the box did not answer"))
			assert.is_not_nil(o:record())
			-- It did not land here: nothing differs, and Restore says so.
			h:silence(false)
			read()
			assert.equal(offers.LABEL_RESTORE .. " (the box has its own settings back)", o:choices()[2].text)
			assert.equal(1, behavior().cecPowersave)
		end)

		it("answers a click while its PUT is out without sending a second", function()
			rig("HSB2")
			h:defer(true)
			local first
			o:choose(offers.OFFER_LET, function(ok, text) first = { ok = ok, text = text } end)
			local a = click(offers.OFFER_RESTORE)
			assert.is_false(a.ok)
			assert.equal("Not changed: the last Sync Box Settings change is still on its way to the box", a.text)
			h:answer()
			assert.is_true(first.ok)
			assert.equal(1, #puts())
		end)

		it("stop() forgets a PUT still out: its late answer changes nothing", function()
			rig("HSB2")
			h:defer(true)
			local called = false
			o:choose(offers.OFFER_LET, function() called = true end)
			o:stop()
			h:answer()
			assert.is_false(called)
		end)
	end)

	describe("Restore the box's input switching", function()
		it("puts back exactly the recorded values and drops the record", function()
			rig("HSB2")
			local original = F.copy(behavior())
			click(offers.OFFER_LET)
			read()
			local a = click(offers.OFFER_RESTORE)
			assert.is_true(a.ok)
			assert.equal("Restored the box's own HDMI CEC switching on HDMI 1, 2; auto-sync on HDMI 1; power save "
				.. "when the TV turns off", a.text)
			assert.same({ cecPowersave = 1, input1 = { cecInputSwitch = 1, linkAutoSync = 1 },
				input2 = { cecInputSwitch = 1 } }, puts()[2].json)
			assert.same(original, behavior())
			assert.is_nil(o:record())
			read()
			assert.equal(offers.LABEL_RESTORE .. " (nothing recorded to put back)", o:choices()[2].text)
		end)

		it("puts back only what differs; nothing differing sends nothing", function()
			rig("HSB2")
			click(offers.OFFER_LET)
			h.state.behavior.cecPowersave = 1  -- turned on again in the Hue Sync app
			read()
			assert.is_true(click(offers.OFFER_RESTORE).ok)
			assert.same({ input1 = { cecInputSwitch = 1, linkAutoSync = 1 }, input2 = { cecInputSwitch = 1 } },
				puts()[2].json)
			-- Everything back by hand: nothing to send, the record goes.
			rig("HSB2")
			click(offers.OFFER_LET)
			for k, v in pairs(F.state.HSB2.behavior) do h.state.behavior[k] = F.copy(v) end
			read()
			local a = click(offers.OFFER_RESTORE)
			assert.is_true(a.ok)
			assert.equal("Nothing to put back: the box already has its own input switching", a.text)
			assert.equal(1, #puts())
			assert.is_nil(o:record())
		end)

		it("skips a recorded setting the box no longer has, and says so", function()
			rig("HSB2")
			click(offers.OFFER_LET)
			h.state.behavior.input1.linkAutoSync = nil   -- a firmware that dropped it
			read()
			local a = click(offers.OFFER_RESTORE)
			assert.is_true(a.ok)
			assert.equal("Restored the box's own HDMI CEC switching on HDMI 1, 2; power save when the TV turns off "
				.. "(not on the box any more: auto-sync on HDMI 1)", a.text)
			assert.same({ cecPowersave = 1, input1 = { cecInputSwitch = 1 }, input2 = { cecInputSwitch = 1 } },
				puts()[2].json)
		end)

		it("with nothing recorded, says so and sends nothing", function()
			rig("HSB2")
			local a = click(offers.OFFER_RESTORE)
			assert.is_false(a.ok)
			assert.equal("Nothing to restore: Let Control4 choose inputs has not changed this box", a.text)
			assert.equal(0, #puts())
		end)

		it("B7: never puts another box's values on this one", function()
			rig("HSB2")
			c4.persist[offers.KEY] = { v = 1, box_id = "0A1B2C3D4E60", at = 1,
				values = { cecPowersave = 1, ["input3.cecInputSwitch"] = 1 } }
			o = new_offers()
			read()
			assert.equal(offers.LABEL_RESTORE .. " (nothing recorded to put back)", o:choices()[2].text)
			assert.is_false(click(offers.OFFER_RESTORE).ok)
			assert.equal(0, #puts())
			-- A click here starts this box's own record.
			assert.is_true(click(offers.OFFER_LET).ok)
			assert.equal(F.BOX_ID, o:record().box_id)
			assert.is_nil(o:record().values["input3.cecInputSwitch"])
		end)

		it("a refused Restore keeps the record for another try", function()
			rig("HSB2")
			click(offers.OFFER_LET)
			read()
			h:fault("5xx", { status = 400, body = { code = 13, message = "Invalid Key" }, method = "PUT",
				path = "/behavior", count = 1 })
			local a = click(offers.OFFER_RESTORE)
			assert.is_false(a.ok)
			assert.equal("Not restored: the box refused the change (Invalid Key)", a.text)
			assert.is_not_nil(o:record())
			assert.is_true(click(offers.OFFER_RESTORE).ok)
			assert.is_nil(o:record())
		end)
	end)

	describe("the wiring (design 5.8, O17)", function()
		local function wiring_puts()
			local out = {}
			for _, r in ipairs(puts()) do
				if r.json.arcBypassMode ~= nil or r.json.soloMode ~= nil then out[#out + 1] = r end
			end
			return out
		end

		local function values_of(list)
			local out = {}
			for _, item in ipairs(list) do out[#out + 1] = item.value end
			return out
		end

		it("offers only the wirings the box is not in and has the key for", function()
			rig("HSB2_behind_receiver")
			local items = o:choices()
			assert.same({ text = "Set the box to In line (ARC bypass and solo mode off)", value = "wiring:in_line" }, items[3])
			assert.same({ offers.OFFER_LET, offers.OFFER_RESTORE, "wiring:in_line", "wiring:second_output" },
				values_of(items))
			-- HSB1 (API level 9) has no solo mode: never offered there.
			rig("HSB1")
			assert.same({ offers.OFFER_LET, offers.OFFER_RESTORE, "wiring:behind_receiver" }, values_of(o:choices()))
			assert.equal("Set the box to Behind a receiver (ARC bypass on)", o:choices()[3].text)
			h.state.behavior.arcBypassMode = 1
			read()
			assert.same({ text = "Set the box to In line (ARC bypass off)", value = "wiring:in_line" }, o:choices()[3])
			-- Not read yet: nothing to offer.
			o = new_offers()
			assert.same({ offers.OFFER_LET, offers.OFFER_RESTORE }, values_of(o:choices()))
		end)

		it("sets a wiring with the keys that differ, records them first, and says how to connect", function()
			rig("HSB2")
			local a = click("wiring:behind_receiver")
			assert.is_true(a.ok)
			assert.equal("Sent: the box is now Behind a receiver (ARC bypass on, solo mode off): every source reaches it "
				.. "from the receiver on HDMI 1. Control4's connections must match the cables: connect the receiver's HDMI "
				.. "output to the box's HDMI 1 and the box's HDMI Out to the TV (Sync Box Settings: Restore the box's "
				.. "wiring puts it back)", a.text)
			assert.same({ arcBypassMode = 1 }, puts()[1].json)
			assert.equal(1, behavior().arcBypassMode)
			assert.same({ arcBypassMode = 0 }, o:record("wiring").values)
			assert.equal(F.BOX_ID, o:record("wiring").box_id)
			assert.is_nil(o:record(), "the input switching's record is apart")
			assert.same({ "command" }, soons)
			read()
			assert.same({ offers.OFFER_LET, offers.OFFER_RESTORE, "wiring:in_line", "wiring:second_output",
				offers.OFFER_WIRING_RESTORE }, values_of(o:choices()))
			assert.equal("Restore the box's wiring (back to In line)", o:choices()[5].text)
		end)

		it("each wiring's Last Action fits Last Action's rows whole", function()
			for _, from in ipairs({ "HSB2", "HSB2_behind_receiver", "HSB2_second_output" }) do
				rig(from)
				for _, item in ipairs(o:choices()) do
					if item.value:find("^wiring:") then
						rig(from)
						local a = click(item.value)
						assert.is_true(a.ok)
						assert.is_nil(a.text:find("...", 1, true), a.text)
						assert.truthy(a.text:find("Control4's connections must match the cables", 1, true))
					end
				end
			end
			rig("HSB2")
			local a = click("wiring:second_output")
			assert.equal("Sent: the box is now From a receiver's second output (solo mode on, ARC bypass off): it "
				.. "follows a room (Follow Room) and Director routes nothing through it. Control4's connections must "
				.. "match the cables: connect the receiver's second HDMI output to the box's HDMI 1 if its driver offers "
				.. "one, and never connect the box's HDMI Out (Sync Box Settings: Restore the box's wiring puts it back)",
				a.text)
		end)

		it("a second change keeps the values recorded first; Restore goes back to the wiring before", function()
			rig("HSB2")
			click("wiring:behind_receiver")
			read()
			click("wiring:second_output")
			assert.same({ soloMode = 1, arcBypassMode = 0 }, wiring_puts()[2].json)
			assert.same({ arcBypassMode = 0, soloMode = 0 }, o:record("wiring").values)
			read()
			assert.equal("Restore the box's wiring (back to In line)", o:choices()[#o:choices()].text)
			local a = click(offers.OFFER_WIRING_RESTORE)
			assert.is_true(a.ok)
			assert.equal("Restored the box's wiring: the box is now In line (ARC bypass and solo mode off): Director "
				.. "switches it to each source's HDMI input. Control4's connections must match the cables: connect each "
				.. "source to its HDMI input on the box and the box's HDMI Out to the TV or receiver", a.text)
			assert.same({ soloMode = 0 }, wiring_puts()[3].json, "only what differs")
			assert.equal(0, behavior().soloMode)
			assert.equal(0, behavior().arcBypassMode)
			assert.is_nil(o:record("wiring"))
			read()
			assert.same({ offers.OFFER_LET, offers.OFFER_RESTORE, "wiring:behind_receiver", "wiring:second_output" },
				values_of(o:choices()))
		end)

		it("the two Restores are apart: neither moves what the other changed", function()
			rig("HSB2")
			click(offers.OFFER_LET)
			read()
			click("wiring:behind_receiver")
			read()
			assert.is_true(click(offers.OFFER_RESTORE).ok)
			assert.is_nil(puts()[3].json.arcBypassMode)
			assert.equal(1, behavior().arcBypassMode)
			assert.equal(1, behavior().cecPowersave)
			read()
			click("wiring:in_line")
			read()
			-- The wiring is back by hand: its Restore has nothing to put back.
			assert.is_nil(o:choices()[5])
			local a = click(offers.OFFER_WIRING_RESTORE)
			assert.equal("Nothing to put back: the box already has its own wiring (In line)", a.text)
			assert.is_nil(o:record("wiring"))
			assert.equal(4, #puts())
		end)

		it("refuses a wiring the box has no key for, and one it is in, sending nothing", function()
			rig("HSB1")
			local a = click("wiring:second_output")
			assert.is_false(a.ok)
			assert.equal("Not changed: this box has no solo mode setting, so it cannot be set to From a receiver's "
				.. "second output", a.text)
			a = click("wiring:in_line")
			assert.is_true(a.ok)
			assert.equal("Nothing to change: the box is already In line", a.text)
			assert.equal(0, #puts())
			assert.is_nil(o:record("wiring"))
			o = new_offers()
			a = click("wiring:behind_receiver")
			assert.is_false(a.ok)
			assert.truthy(a.text:find("not been read yet", 1, true))
		end)

		it("a refused wiring PUT is rolled back; another box's record is never offered", function()
			rig("HSB2")
			h:fault("5xx", { status = 400, body = { code = 13, message = "Invalid Key" }, method = "PUT",
				path = "/behavior", count = 1 })
			local a = click("wiring:second_output")
			assert.equal("Not changed: the box refused the change (Invalid Key)", a.text)
			assert.is_nil(o:record("wiring"))
			assert.equal(0, behavior().soloMode)
			c4.persist[offers.WIRING_KEY] = { v = 1, box_id = "0A1B2C3D4E60", values = { arcBypassMode = 1 } }
			o = new_offers()
			read()
			for _, item in ipairs(o:choices()) do
				assert.are_not.equal(offers.OFFER_WIRING_RESTORE, item.value)
			end
			assert.equal("Nothing to restore: Sync Box Settings has not changed this box's wiring",
				click(offers.OFFER_WIRING_RESTORE).text)
		end)
	end)

	describe("the record", function()
		it("survives a restart: read from the storage once, then kept in memory", function()
			rig("HSB2")
			click(offers.OFFER_LET)
			local function reads()
				local n = 0
				for _, args in ipairs(c4.calls_to("PersistGetValue")) do
					if args[1] == offers.KEY then n = n + 1 end
				end
				return n
			end
			local before = reads()
			o = new_offers()
			read()
			o:choices()
			o:row()
			assert.is_true(click(offers.OFFER_RESTORE).ok)
			assert.equal(1, behavior().cecPowersave)
			assert.equal(before + 1, reads())
		end)

		it("drops a stored record it cannot use, keeping only known keys and flags", function()
			rig("HSB2")
			c4.persist[offers.KEY] = { v = 1, box_id = F.BOX_ID, values = { cecPowersave = 7, ["input9.x"] = 1 } }
			o = new_offers()
			read()
			assert.is_nil(o:record())
			assert.truthy(lines[#lines]:find("not usable", 1, true))
			c4.persist[offers.KEY] = { v = 1, box_id = F.BOX_ID:lower(),
				values = { cecPowersave = 1, bogus = 1, ["input2.cecInputSwitch"] = 0 } }
			o = new_offers()
			read()
			assert.same({ cecPowersave = 1, ["input2.cecInputSwitch"] = 0 }, o:record().values)
			assert.equal(F.BOX_ID, o:record().box_id)
		end)

		it("is never written with an encrypted flag: the controller raises on an explicit nil", function()
			rig("HSB2")
			local seen = {}
			o = new_offers({ persist_set = function(...) seen[#seen + 1] = select("#", ...) end })
			read()
			click(offers.OFFER_LET)
			assert.same({ 2 }, seen)
		end)
	end)

	it("the box's own words in a refusal are capped and cleaned", function()
		rig("HSB2")
		h:fault("5xx", { status = 400, body = { code = 15, message = "bad\nvalue " .. string.rep("x", 400) },
			method = "PUT", path = "/behavior", count = 1 })
		local a = click(offers.OFFER_LET)
		assert.is_nil(a.text:find("\n", 1, true))
		assert.truthy(#a.text <= offers.TEXT_MAX)
		assert.equal(F.TOKEN, h.registrations[F.REGISTRATION_ID].token, "the fake kept its token")
		assert.equal(200, (h:request("GET", "", AUTH)))
	end)
end)
