-- syncbox/room.lua (#557, docs/hdmi-sync-stage3-design.md §4; research
-- docs/syncbox-wirings-research.md §1, §5 and §7.4): the room the Hue Sync
-- Box driver follows. Its variables through listeners on the fake runtime
-- (tests/helpers/fake_c4.lua: RegisterVariableListener calls
-- OnWatchedVariableChanged at once, fails for a variable that does not
-- exist; fake.room_variable changes one), the baseline, the 1 s settle; the
-- Follow Room choice; the room whose picture runs through the box. The
-- lifecycle cases of research §5 carry their number (W3 ...). Room and
-- device ids are made up; no LAN address appears.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")

local LIVING, BEDROOM, DEN, GUEST = 7, 38, 41, 44
local OWN_DEVICE = 15           -- the box device (the fake runtime's own id)
local APPLE, PS5, RADIO = 120, 130, 140   -- source proxy ids
local RECEIVER, TV, BOX = 210, 220, 300

local function path(...)
	local parts = {}
	for i, id in ipairs({ ... }) do parts[i] = string.format("<id>%d</id>", id) end
	return table.concat(parts)
end

-- A Navigator's Watch, in the order Director may change the variables.
local function watch(room_id, id)
	fake.room_variable(room_id, 1002, id)
	fake.room_variable(room_id, 1001, id)
	fake.room_variable(room_id, 1008, path(id, RECEIVER, TV))
	fake.room_variable(room_id, 1007, "")
	fake.room_variable(room_id, 1000, id)
	fake.room_variable(room_id, 1010, "1")
end

local function listen(room_id, id)
	fake.room_variable(room_id, 1001, id)
	fake.room_variable(room_id, 1007, path(id, RECEIVER))
	fake.room_variable(room_id, 1008, "")
	fake.room_variable(room_id, 1000, id)
end

local function room_off(room_id)
	fake.room_variable(room_id, 1000, 0)
	fake.room_variable(room_id, 1010, "0")
end

describe("syncbox/room.lua (#557)", function()
	local room, c4, env, r, seen, lines

	local function new_room(deps)
		deps = deps or {}
		deps.on_baseline = deps.on_baseline or function(s) seen.baselines[#seen.baselines + 1] = s end
		deps.on_change = deps.on_change or function(s, p) seen.changes[#seen.changes + 1] = { state = s, prev = p } end
		deps.on_trouble = deps.on_trouble or function(text, id, reason)
			seen.troubles[#seen.troubles + 1] = { text = text, id = id, reason = reason }
		end
		r = room.new(deps)
		env.OnWatchedVariableChanged = function(device, variable, value)
			r:on_variable(device, variable, value)
		end
		return r
	end

	before_each(function()
		lines = {}
		log.set_debug(true)
		log.sink = function(line) lines[#lines + 1] = line end
		c4, env = fake.install_c4()
		package.loaded["syncbox.room"] = nil
		room = require("syncbox.room")
		fake.add_room(BEDROOM, "Bedroom")
		fake.add_room(DEN, "Den")
		seen = { baselines = {}, changes = {}, troubles = {} }
		new_room()
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("the watcher", function()
		it("listens to the room's variables 1000, 1001, 1002, 1007, 1008 and 1010, found by name", function()
			assert.is_true(r:follow(BEDROOM, "Bedroom"))
			for _, id in ipairs({ 1000, 1001, 1002, 1007, 1008, 1010 }) do
				assert.is_true(c4.listens(BEDROOM, id), "listens to " .. id)
			end
			assert.is_false(c4.listens(BEDROOM, 1009))
			assert.equal(1, #c4.calls_to("GetDeviceVariables"))
			assert.same({ selected = 1000, audio = 1001, video = 1002, audio_path = 1007, video_path = 1008,
				power = 1010 }, r:ids())
		end)

		it("unregisters each variable before registering it, as the SDK's example does", function()
			r:follow(BEDROOM, "Bedroom")
			local order = {}
			for _, call in ipairs(c4.calls) do
				if call.name == "UnregisterVariableListener" or call.name == "RegisterVariableListener" then
					order[#order + 1] = call.name:sub(1, 1) .. call.args[2]
				end
			end
			assert.same({ "U1000", "R1000", "U1001", "R1001", "U1002", "R1002", "U1007", "R1007", "U1008", "R1008",
				"U1010", "R1010" }, order)
		end)

		it("clears whatever listeners a previous run left, once per run, before the first follow", function()
			r:follow(BEDROOM, "Bedroom")
			r:follow(DEN, "Den")
			assert.equal(1, #c4.calls_to("UnregisterAllVariableListeners"))
			assert.is_true(c4.listens(DEN, 1000))
		end)

		it("W15: the first values after start are a baseline, reported once, never a change", function()
			fake.add_device(110, { name = "Apple TV", proxy_id = APPLE, room_id = BEDROOM })
			fake.room_variable(BEDROOM, 1000, APPLE)
			fake.room_variable(BEDROOM, 1002, APPLE)
			fake.room_variable(BEDROOM, 1008, path(APPLE, RECEIVER, TV))
			r:follow(BEDROOM, "Bedroom")
			assert.same({}, seen.baselines, "nothing before BASELINE_MS")
			c4.advance(room.BASELINE_MS)
			assert.equal(1, #seen.baselines)
			local b = seen.baselines[1]
			assert.equal("watch", b.kind)
			assert.equal(APPLE, b.selected)
			assert.same({ APPLE, RECEIVER, TV }, b.video_path)
			assert.equal(BEDROOM, b.room_id)
			c4.advance(10000)
			assert.same({}, seen.changes)
			assert.same(b, r:state())
		end)

		it("W15: a driver restart (a new watcher) takes the room as it is: one baseline, no change", function()
			fake.room_variable(BEDROOM, 1000, APPLE)
			fake.room_variable(BEDROOM, 1002, APPLE)
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			seen.baselines = {}
			new_room()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(5000)
			assert.equal(1, #seen.baselines)
			assert.equal("watch", seen.baselines[1].kind)
			assert.same({}, seen.changes)
		end)

		it("folds first callbacks that come after RegisterVariableListener returns into the baseline", function()
			local later = {}
			new_room({
				register = function(device, variable) later[#later + 1] = { device, variable } end,
				get_variable = function() return nil end,
			})
			r:follow(BEDROOM, "Bedroom")
			fake.room_variable(BEDROOM, 1000, APPLE)   -- nobody listens in the fake: delivered by hand
			for _, pair in ipairs(later) do
				r:on_variable(pair[1], pair[2], C4:GetDeviceVariable(pair[1], pair[2]))
			end
			c4.advance(room.BASELINE_MS)
			assert.equal(1, #seen.baselines)
			assert.equal(APPLE, seen.baselines[1].selected)
			assert.same({}, seen.changes)
		end)

		it("W11: a source picked on a Navigator acts once, after the 1 s settle", function()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			assert.equal("off", seen.baselines[1].kind)
			watch(BEDROOM, APPLE)
			assert.same({}, seen.changes, "nothing before the settle")
			c4.advance(room.SETTLE_MS - 1)
			assert.same({}, seen.changes)
			c4.advance(1)
			assert.equal(1, #seen.changes)
			assert.equal("watch", seen.changes[1].state.kind)
			assert.equal(APPLE, seen.changes[1].state.selected)
			assert.equal("off", seen.changes[1].prev.kind)
			assert.equal("on", seen.changes[1].state.power)
		end)

		it("W12: a source picked by programming changes the same variables and acts the same way", function()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			-- A room command from programming: Director sets the same variables (assumed, P8 step f).
			fake.room_variable(BEDROOM, 1000, PS5)
			fake.room_variable(BEDROOM, 1002, PS5)
			fake.room_variable(BEDROOM, 1008, path(PS5, RECEIVER, TV))
			c4.advance(room.SETTLE_MS)
			assert.equal(1, #seen.changes)
			assert.equal("watch", seen.changes[1].state.kind)
			assert.equal(PS5, seen.changes[1].state.selected)
		end)

		it("W19: zapping through sources within a second acts once, on the last", function()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			watch(BEDROOM, APPLE)
			c4.advance(300)
			watch(BEDROOM, PS5)
			c4.advance(300)
			watch(BEDROOM, APPLE)
			c4.advance(300)
			watch(BEDROOM, PS5)
			c4.advance(room.SETTLE_MS)
			assert.equal(1, #seen.changes)
			assert.equal(PS5, seen.changes[1].state.selected)
		end)

		it("acts at most SETTLE_MAX_MS after the first of a stream of changes", function()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			local start = c4.now_ms
			for i = 1, 12 do
				fake.room_variable(BEDROOM, 1000, i % 2 == 0 and APPLE or PS5)
				c4.advance(500)
				if #seen.changes > 0 then break end
			end
			assert.equal(1, #seen.changes)
			assert.is_true(c4.now_ms - start <= room.SETTLE_MAX_MS + 500)
		end)

		it("a change and its undoing within the settle report nothing", function()
			fake.room_variable(BEDROOM, 1000, APPLE)
			fake.room_variable(BEDROOM, 1002, APPLE)
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			fake.room_variable(BEDROOM, 1000, PS5)
			fake.room_variable(BEDROOM, 1000, APPLE)
			c4.advance(room.SETTLE_MS)
			assert.same({}, seen.changes)
		end)

		it("reads a Listen selection: the audio device and path, the video device unchanged", function()
			fake.room_variable(BEDROOM, 1000, APPLE)
			fake.room_variable(BEDROOM, 1002, APPLE)
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			listen(BEDROOM, RADIO)
			c4.advance(room.SETTLE_MS)
			local s = seen.changes[1].state
			assert.equal("listen", s.kind)
			assert.equal(RADIO, s.selected)
			assert.equal(APPLE, s.video, "1002 unchanged")
			assert.same({ RADIO, RECEIVER }, s.audio_path)
		end)

		it("reads Room Off from the selected device going to 0, whatever POWER_STATE says", function()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			watch(BEDROOM, APPLE)
			c4.advance(room.SETTLE_MS)
			room_off(BEDROOM)
			c4.advance(room.SETTLE_MS)
			assert.equal("off", seen.changes[2].state.kind)
			-- An unknown POWER_STATE text with a source selected stays a Watch (its format is assumed).
			watch(BEDROOM, APPLE)
			fake.room_variable(BEDROOM, 1010, "STANDBY")
			c4.advance(room.SETTLE_MS)
			assert.equal("watch", seen.changes[3].state.kind)
			assert.is_nil(seen.changes[3].state.power)
		end)

		it("takes the paths from <id> elements or a plain list, at most PATH_IDS_MAX ids", function()
			assert.same({ 12, 34 }, room.parse_path("<devices><id>12</id><id> 34 </id></devices>"))
			assert.same({ 12, 34 }, room.parse_path("12, 34"))
			assert.same({}, room.parse_path("<id>abc</id>"))
			assert.same({}, room.parse_path(nil))
			local long = string.rep("<id>5</id>", 100)
			assert.equal(room.PATH_IDS_MAX, #room.parse_path(long))
		end)

		it("checks every value from the room: ids are whole numbers in range, nothing else", function()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			fake.room_variable(BEDROOM, 1000, "nan")
			c4.advance(room.SETTLE_MS)
			assert.equal("unknown", seen.changes[1].state.kind, "a selection that is no number is not acted on")
			fake.room_variable(BEDROOM, 1000, "1e400")
			fake.room_variable(BEDROOM, 1002, "-5")
			fake.room_variable(BEDROOM, 1008, string.rep("x", 100000) .. "<id>9</id>")
			c4.advance(room.SETTLE_MS)
			assert.same({}, r:state().video_path, "only the first PATH_READ_MAX bytes are read")
			assert.is_nil(r:state().video)
			fake.room_variable(BEDROOM, 1000, APPLE)
			c4.advance(room.SETTLE_MS)
			assert.equal(APPLE, r:state().selected)
			for _, line in ipairs(lines) do
				assert.is_true(#line < 2500, "no value is logged whole")
			end
		end)

		it("W8: linked rooms: only the followed room's own variables are watched", function()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			for id = 1000, 1035 do
				assert.is_false(c4.listens(DEN, id))
			end
			assert.is_false(c4.listens(BEDROOM, 1026))
			assert.is_false(c4.listens(BEDROOM, 1027))
			-- A selection linked from Den shows in Bedroom's own variables (assumed, P8): that acts.
			watch(BEDROOM, APPLE)
			c4.advance(room.SETTLE_MS)
			assert.equal(1, #seen.changes)
		end)

		it("W9: another room on the same receiver changes nothing here", function()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			assert.is_false(r:on_variable(DEN, 1000, tostring(APPLE)))
			assert.equal(0, fake.room_variable(DEN, 1000, APPLE), "nobody listens to Den")
			c4.advance(room.SETTLE_MS)
			assert.same({}, seen.changes)
		end)

		it("stop() unregisters every listener; a later change reaches nobody", function()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			r:stop()
			assert.is_false(c4.listens(BEDROOM, 1000))
			assert.equal(0, fake.room_variable(BEDROOM, 1000, APPLE))
			c4.advance(5000)
			assert.same({}, seen.changes)
			assert.is_nil(r:following())
		end)

		it("following another room lets the old one go and starts a new baseline", function()
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			watch(BEDROOM, APPLE)   -- pending settle when the room changes
			r:follow(DEN, "Den")
			assert.is_false(c4.listens(BEDROOM, 1000))
			c4.advance(room.SETTLE_MS)
			assert.same({}, seen.changes, "the old room's pending change is dropped")
			assert.equal(2, #seen.baselines)
			assert.equal(DEN, seen.baselines[2].room_id)
			assert.same({ DEN, "Den" }, { r:following() })
		end)

		it("W16: another OS numbering: the ids come from the names", function()
			local vars = fake.room_variables(BEDROOM)
			local renumbered = {}
			for id, v in pairs(vars) do renumbered[id + 100] = v end
			for id in pairs(vars) do vars[id] = nil end
			for id, v in pairs(renumbered) do vars[id] = v end
			assert.is_true(r:follow(BEDROOM, "Bedroom"))
			assert.equal(1100, r:ids().selected)
			assert.is_true(c4.listens(BEDROOM, 1110))
			c4.advance(room.BASELINE_MS)
			fake.room_variable(BEDROOM, 1100, APPLE)
			c4.advance(room.SETTLE_MS)
			assert.equal(APPLE, seen.changes[1].state.selected)
			assert.same({}, seen.troubles)
		end)

		it("matches the names whatever their spelling, and uses the numbers when the list does not answer", function()
			fake.room_variable(BEDROOM, 2000, 0, "Variable_Current_Selected_Device")
			fake.room_variable(BEDROOM, 2008, "", "Current Video Path")
			c4.GetDeviceVariables = function()
				return { ["2000"] = { name = "Variable_Current_Selected_Device" }, ["2008"] = { name = "Current Video Path" } }
			end
			r:follow(BEDROOM, "Bedroom")
			assert.equal(2000, r:ids().selected)
			assert.equal(2008, r:ids().video_path)
			assert.equal(1001, r:ids().audio, "missing names fall back to the numbers")
			c4.GetDeviceVariables = function() error("not on this OS") end
			new_room()
			assert.is_true(r:follow(BEDROOM, "Bedroom"))
			assert.equal(1000, r:ids().selected)
			assert.same({}, seen.troubles)
		end)

		it("W16: registration fails: Cannot follow, a retry every hour and at OnPIP, the ids looked up again", function()
			fake.room_variables(BEDROOM)[1000] = nil
			local ok, reason = r:follow(BEDROOM, "Bedroom")
			assert.is_false(ok)
			assert.equal("register", reason)
			assert.same({ { text = "Cannot follow Bedroom: its variables do not answer", id = BEDROOM,
				reason = "register" } }, seen.troubles)
			c4.advance(room.BASELINE_MS)
			assert.same({}, seen.baselines)
			-- OnPIP: the variable is there again; the retry looks the ids up by name again.
			fake.room_variable(BEDROOM, 1000, APPLE, "CURRENT_SELECTED_DEVICE")
			local lookups = #c4.calls_to("GetDeviceVariables")
			assert.is_true(r:retry())
			assert.equal(lookups + 1, #c4.calls_to("GetDeviceVariables"))
			c4.advance(room.BASELINE_MS)
			assert.equal(1, #seen.baselines, "a retry's first values are a baseline too")
			assert.is_false(r:retry(), "nothing to retry while following")
		end)

		it("W16: the hourly retry", function()
			fake.room_variables(BEDROOM)[1000] = nil
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.RETRY_MS - 1)
			assert.equal(1, #seen.troubles)
			c4.advance(1)
			assert.equal(2, #seen.troubles, "tried again, still failing")
			fake.room_variable(BEDROOM, 1000, 0, "CURRENT_SELECTED_DEVICE")
			c4.advance(room.RETRY_MS + room.BASELINE_MS)
			assert.equal(1, #seen.baselines)
		end)

		it("W16: no first callback and no value: Cannot follow; a late first callback is the baseline", function()
			new_room({ register = function() end, get_variable = function() return nil end })
			r:follow(BEDROOM, "Bedroom")
			c4.advance(room.BASELINE_MS)
			assert.equal("no answer", seen.troubles[1].reason)
			assert.same({}, seen.baselines)
			r:on_variable(BEDROOM, 1000, tostring(APPLE))
			assert.equal(1, #seen.baselines)
			assert.equal(APPLE, seen.baselines[1].selected)
			assert.same({}, seen.changes)
		end)

		it("survives a callback that raises", function()
			new_room({ on_baseline = function() error("boom") end })
			r:follow(BEDROOM, "Bedroom")
			assert.has_no.errors(function() c4.advance(room.BASELINE_MS) end)
		end)
	end)

	describe("the choice (Follow Room)", function()
		local choice

		local function new_choice()
			choice = room.choice()
			return choice
		end

		before_each(function()
			fake.move_device(OWN_DEVICE, BEDROOM)
			new_choice()
		end)

		it("W1: at its default, follows this device's room and says so", function()
			assert.equal("own", room.DEFAULT_FOLLOW, "provisional owner answer 1 (#536)")
			local res = choice:resolve()
			assert.equal(BEDROOM, res.room_id)
			assert.equal("Bedroom", res.name)
			assert.equal("own", res.how)
			assert.equal("Follows Bedroom (this device's room)", res.status)
			assert.is_nil(res.trouble)
			local items, value = choice:items()
			assert.same({ "This device's room (Bedroom)", "None (the box decides)", "Bedroom", "Den", "Living Room" },
				items)
			assert.equal("This device's room (Bedroom)", value)
		end)

		it("the default is one constant: \"none\" follows nothing until the dealer picks", function()
			room.DEFAULT_FOLLOW = "none"
			local res = new_choice():resolve()
			room.DEFAULT_FOLLOW = "own"
			assert.equal("none", res.how)
			assert.is_nil(res.room_id)
		end)

		it("W2: None: no room, stored as such", function()
			assert.is_true(choice:choose("None (the box decides)"))
			local res = choice:resolve()
			assert.equal("none", res.how)
			assert.is_nil(res.room_id)
			assert.equal("Follows no room", res.status)
			assert.same({ mode = "none" }, c4.persist[room.FOLLOW_KEY])
			assert.equal("None (the box decides)", select(2, choice:items()))
		end)

		it("W7: a room other than the device's, stored by id with its name, never a name alone", function()
			assert.is_true(choice:choose("Den"))
			assert.same({ mode = "room", id = DEN, name = "Den" }, c4.persist[room.FOLLOW_KEY])
			local res = choice:resolve()
			assert.equal(DEN, res.room_id)
			assert.equal("chosen", res.how)
			assert.equal("Follows Den (chosen; this device is in Bedroom)", res.status)
			assert.equal("Den", select(2, choice:items()))
		end)

		it("refuses a text that names no room", function()
			assert.same({ false, "not a room of this project" }, { choice:choose("Attic") })
			assert.is_nil(c4.persist[room.FOLLOW_KEY])
		end)

		it("W3: the followed room renamed while the driver runs: the id stands, the label follows", function()
			choice:choose("Den")
			choice:resolve()
			fake.rename_room(DEN, "Media Room")
			local res = choice:resolve()
			assert.equal(DEN, res.room_id)
			assert.equal("Media Room", res.name)
			assert.equal("chosen", res.how)
			assert.is_nil(res.trouble)
			assert.same({ mode = "room", id = DEN, name = "Media Room" }, c4.persist[room.FOLLOW_KEY])
		end)

		it("W4: the followed room deleted: stops, never another room by itself, the same name offered", function()
			choice:choose("Den")
			choice:resolve()
			fake.delete_room(DEN)
			fake.add_room(GUEST, "Den")   -- a single room now has the old name
			local res = choice:resolve()
			assert.equal("gone", res.how)
			assert.is_nil(res.room_id)
			assert.equal("Follows a deleted room (Den, room 41): pick another in Follow Room", res.trouble)
			assert.same({ id = GUEST, name = "Den", text = "Den (room 44) has its name: pick it in Follow Room" },
				res.offer)
			assert.same({ mode = "room", id = DEN, name = "Den" }, c4.persist[room.FOLLOW_KEY], "nothing rewritten")
			assert.equal("Den (deleted room 41)", select(2, choice:items()))
			-- One click accepts.
			assert.is_true(choice:accept_offer())
			assert.equal(GUEST, choice:resolve().room_id)
		end)

		it("W4: no offer when no room, or more than one, has the old name", function()
			choice:choose("Den")
			choice:resolve()
			fake.delete_room(DEN)
			assert.is_nil(choice:resolve().offer)
			fake.add_room(GUEST, "Den")
			fake.add_room(GUEST + 1, "Den")
			assert.is_nil(choice:resolve().offer)
			assert.is_false(choice:accept_offer())
		end)

		it("W4: a deleted room's listener goes silent", function()
			new_room()
			r:follow(DEN, "Den")
			c4.advance(room.BASELINE_MS)
			fake.delete_room(DEN)
			assert.has_error(function() fake.room_variable(DEN, 1000, APPLE) end)
			c4.advance(5000)
			assert.same({}, seen.changes)
		end)

		it("W5: the device's own room deleted: whichever room the device ends up in is followed, said once", function()
			assert.equal(BEDROOM, choice:resolve().room_id)
			fake.move_device(OWN_DEVICE, DEN)   -- Composer moves the device out of the room it deletes
			fake.delete_room(BEDROOM)
			local res = choice:resolve()
			assert.equal(DEN, res.room_id)
			assert.equal("Follows Den now: this device moved there from Bedroom", res.last_action)
			assert.is_nil(choice:resolve().last_action, "said once")
		end)

		it("W6: the device moved: the default follows it, said once, also across a restart", function()
			assert.equal(BEDROOM, choice:resolve().room_id)
			fake.move_device(OWN_DEVICE, DEN)
			new_choice()   -- a restart: the last room followed was stored
			local res = choice:resolve()
			assert.equal(DEN, res.room_id)
			assert.equal("Follows Den now: this device moved there from Bedroom", res.last_action)
			assert.is_nil(choice:resolve().last_action)
		end)

		it("W6: the device moved: an explicit room stays, with a note on Status", function()
			choice:choose("Bedroom")
			fake.move_device(OWN_DEVICE, DEN)
			local res = choice:resolve()
			assert.equal(BEDROOM, res.room_id)
			assert.equal("chosen", res.how)
			assert.equal("Follows Bedroom (chosen; this device is in Den)", res.status)
			assert.same({ mode = "room", id = BEDROOM, name = "Bedroom" }, c4.persist[room.FOLLOW_KEY])
		end)

		it("W24: a restored project whose stored room id names another room: not followed until a click", function()
			c4.persist[room.FOLLOW_KEY] = { mode = "room", id = DEN, name = "Bedroom 2" }
			fake.add_room(GUEST, "Bedroom 2")
			local res = new_choice():resolve()
			assert.equal("mismatch", res.how)
			assert.is_nil(res.room_id)
			assert.equal("Follow Room names Bedroom 2 (room 41), which is now Den: pick the room again in Follow Room",
				res.trouble)
			assert.equal(GUEST, res.offer.id)
			assert.equal("mismatch", choice:resolve().how, "until a click")
			assert.is_true(choice:choose("Den"))
			assert.equal(DEN, choice:resolve().room_id)
		end)

		it("W24: a restored project whose stored id and name still agree is followed", function()
			c4.persist[room.FOLLOW_KEY] = { mode = "room", id = DEN, name = "Den" }
			local res = new_choice():resolve()
			assert.equal("chosen", res.how)
			assert.equal(DEN, res.room_id)
		end)

		it("keeps the last room while the room list does not answer", function()
			choice:choose("Den")
			choice.rooms_fn = function() error("busy") end
			local res = choice:resolve()
			assert.equal("unknown", res.how)
			assert.equal(DEN, res.room_id)
		end)

		it("a stored choice that is not usable falls back to the default, with a warning", function()
			c4.persist[room.FOLLOW_KEY] = { mode = "room", id = "lots" }
			assert.equal("own", new_choice():resolve().how)
			assert.truthy(table.concat(lines, "\n"):find("not usable", 1, true))
		end)

		it("lists rooms with commas made safe, duplicates told apart, reserved labels never taken", function()
			fake.add_room(GUEST, "Den")
			fake.add_room(50, "Kids, Play")
			fake.add_room(51, "None (the box decides)")
			local items = choice:items()
			assert.same({ "This device's room (Bedroom)", "None (the box decides)", "Bedroom", "Den (room 41)",
				"Den (room 44)", "Kids\226\128\154 Play", "Living Room", "None (the box decides) (room 51)" }, items)
			assert.is_true(choice:choose("Den (room 44)"))
			assert.equal(GUEST, choice:resolve().room_id)
			assert.is_true(choice:choose("None (the box decides) (room 51)"))
			assert.equal(51, choice:resolve().room_id)
			assert.is_true(choice:choose("This device's room"), "the driver.xml default text")
			assert.equal("own", choice:resolve().how)
		end)

		it("persists with no encrypted flag (Director raises on an explicit nil)", function()
			choice:choose("Den")
			for _, args in ipairs(c4.calls_to("PersistSetValue")) do
				assert.is_false(args[3])
			end
			for _, args in ipairs(c4.calls_to("PersistGetValue")) do
				assert.is_false(args[2])
			end
		end)
	end)

	describe("W20: the room whose picture runs through the box", function()
		local rooms

		before_each(function()
			rooms = { [LIVING] = "Living Room", [BEDROOM] = "Bedroom", [DEN] = "Den" }
		end)

		it("offers the one room whose picture path holds the box while the followed one's does not", function()
			fake.room_variable(LIVING, 1008, path(APPLE, BOX, TV))
			fake.room_variable(BEDROOM, 1008, path(PS5, RECEIVER, TV))
			local offer = room.path_offer({ box_ids = { [BOX] = true }, rooms = rooms, followed = BEDROOM })
			assert.same({ id = LIVING, name = "Living Room",
				text = "Living Room's picture runs through this box (Follow Room)" }, offer)
		end)

		it("offers nothing when the followed room's path holds the box, or two rooms' do", function()
			fake.room_variable(BEDROOM, 1008, path(PS5, BOX, TV))
			fake.room_variable(LIVING, 1008, path(APPLE, BOX, TV))
			assert.is_nil(room.path_offer({ box_ids = { [BOX] = true }, rooms = rooms, followed = BEDROOM }))
			fake.room_variable(BEDROOM, 1008, "")
			fake.room_variable(DEN, 1008, path(RADIO, BOX))
			assert.is_nil(room.path_offer({ box_ids = { [BOX] = true }, rooms = rooms, followed = BEDROOM }))
		end)

		it("only offers: the stored choice is not touched", function()
			fake.move_device(OWN_DEVICE, BEDROOM)
			local choice = room.choice()
			choice:choose("Bedroom")
			fake.room_variable(LIVING, 1008, path(APPLE, BOX, TV))
			assert.truthy(room.path_offer({ box_ids = { [BOX] = true }, rooms = rooms, followed = BEDROOM }))
			assert.same({ mode = "room", id = BEDROOM, name = "Bedroom" }, c4.persist[room.FOLLOW_KEY])
			assert.equal(BEDROOM, choice:resolve().room_id)
		end)

		it("survives a read that raises", function()
			local offer = room.path_offer({ box_ids = { [BOX] = true }, rooms = rooms, followed = BEDROOM,
				read = function(id)
					if id == DEN then error("gone") end
					return id == LIVING and path(BOX) or ""
				end })
			assert.equal(LIVING, offer.id)
		end)
	end)
end)
