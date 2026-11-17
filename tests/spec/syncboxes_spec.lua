-- bridge/syncboxes.lua (2.0 beta stage 2, #534): the Hue Sync Box devices
-- bound on the bridge's "Hue Sync Boxes" connection, and the messages of
-- contracts C5 the bridge sends them (docs/hdmi-sync-stage2-design.md §6).
-- Placeholders only: bridge 001788fffe123abc, box 0A1B2C3D4E5F.

local json = require("dkjson")
local log = require("common.log")

local BRIDGE = "001788fffe123abc"
local OTHER_BRIDGE = "001788fffe999999"
local BOX = "0A1B2C3D4E5F"
local BOX2 = "0A1B2C3D4E60"
local TV = "6a7b8c9d-0000-4000-8000-0000000ea001"
local OFFICE = "6a7b8c9d-0000-4000-8000-0000000ea002"
local DEVICE, DEVICE2, DEVICE3 = 2001, 2003, 2005

local function lamp(n)
	return string.format("4e5d6c7b-0000-4000-8000-0000000la%03d", n)
end

describe("bridge.syncboxes", function()
	local syncboxes, s, sent, lines, own, bound, names, areas, label_changes, rooms

	local function new_s(extra)
		local deps = {
			send = function(id, command, params)
				sent[#sent + 1] = { id = id, command = command, params = params }
			end,
			bridge_id = function() return own end,
			areas = function() return areas end,
			bound = function() return bound end,
			display_name = function(id) return names[id] end,
			rooms_for = function(lamps)
				local out = {}
				for _, rid in ipairs(lamps) do
					out[#out + 1] = rooms[rid]
				end
				return out
			end,
			on_labels_changed = function(rids) label_changes[#label_changes + 1] = rids end,
			log = log,
		}
		for k, v in pairs(extra or {}) do
			deps[k] = v
		end
		return syncboxes.new(deps)
	end

	local function hello(device_id, box_id, bridge_id, area_id)
		return s:hello({ device_id = device_id and tostring(device_id) or nil, box_id = box_id, bridge_id = bridge_id,
			area_id = area_id })
	end

	local function of(command)
		local out = {}
		for _, m in ipairs(sent) do
			if m.command == command then
				out[#out + 1] = m
			end
		end
		return out
	end

	local function decoded(text)
		local value, _, err = json.decode(text)
		assert(err == nil, err)
		return value
	end

	local function saw(text)
		for _, line in ipairs(lines) do
			if line:find(text, 1, true) then
				return true
			end
		end
		return false
	end

	-- Bound through OnBindingChanged, as Director reports a new binding.
	local function bind(id)
		assert.is_true(s:binding_changed(2, "HUE_SYNCBOX", true, id))
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		package.loaded["bridge.syncboxes"] = nil
		syncboxes = require("bridge.syncboxes")
		sent, label_changes = {}, {}
		own = BRIDGE
		bound = nil
		names = { [DEVICE] = "Living Room Sync Box", [DEVICE2] = "Den Sync Box", [DEVICE3] = "Office Sync Box" }
		rooms = { [lamp(1)] = "Living Room", [lamp(2)] = "Living Room", [lamp(3)] = "Kitchen", [lamp(4)] = "Office" }
		areas = {
			{ id = TV, name = "Living Room TV", kind = "screen", status = "inactive",
				lamps = { lamp(1), lamp(2), lamp(3) }, streaming = false },
			{ id = OFFICE, name = "Office", kind = "music", status = "inactive", lamps = { lamp(4) }, streaming = false },
		}
		s = new_s()
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("module", function()
		it("has the contract's connection and message names", function()
			assert.equal(2, syncboxes.BINDING)
			assert.equal("HUE_SYNCBOX", syncboxes.CLASS)
			assert.equal("HUE_SYNCBOX_HELLO", syncboxes.HELLO)
			assert.equal("HUE_SYNCBOX_GOODBYE", syncboxes.GOODBYE)
			assert.equal("HUE_SYNCBOX_CONFIGURE", syncboxes.CONFIGURE)
			assert.equal("HUE_SYNCBOX_AREA", syncboxes.AREA)
			assert.equal(64, syncboxes.MAX_AREAS)
		end)

		it("needs send, and takes the rest from defaults", function()
			assert.has_error(function() syncboxes.new({}) end)
			local bare = syncboxes.new({ send = function(id, command, params)
				sent[#sent + 1] = { id = id, command = command, params = params }
			end })
			assert.is_true(bare:binding_changed(2, "HUE_SYNCBOX", true, DEVICE))
			assert.is_true(bare:hello({ device_id = tostring(DEVICE), box_id = BOX }))
			assert.same({ match = "false", areas = "[]" }, sent[1].params, "no bridge id, no areas")
			assert.is_nil(bare:label_for(TV))
			assert.equal(1, bare:configure_all())
		end)
	end)

	describe("hello()", function()
		it("answers a bound box with CONFIGURE: this bridge's id, match, and the areas as a JSON list", function()
			bind(DEVICE)
			assert.is_true(hello(DEVICE, BOX, BRIDGE, TV))
			assert.equal(1, #sent)
			local m = sent[1]
			assert.equal(DEVICE, m.id)
			assert.equal("HUE_SYNCBOX_CONFIGURE", m.command)
			assert.equal(BRIDGE, m.params.bridge_id)
			assert.equal("true", m.params.match)
			assert.same({
				{ id = TV, name = "Living Room TV", type = "screen", status = "inactive", lamps = 3,
					rooms = { "Kitchen", "Living Room" } },
				{ id = OFFICE, name = "Office", type = "music", status = "inactive", lamps = 1, rooms = { "Office" } },
			}, decoded(m.params.areas))
			assert.equal("[", m.params.areas:sub(1, 1), "a real JSON array, not an object")
			for k, v in pairs(m.params) do
				assert.equal("string", type(v), k)
			end
			assert.same({ { device_id = DEVICE, box_id = BOX, bridge_id = BRIDGE, area_id = TV,
				name = "Living Room Sync Box" } }, s:boxes())
			assert.is_true(saw("Living Room Sync Box #4E5F (device 2001) is linked"))
		end)

		it("says match false for a box of another bridge, of none, and while this bridge is unpaired", function()
			bind(DEVICE)
			hello(DEVICE, BOX, OTHER_BRIDGE, TV)
			assert.equal("false", sent[1].params.match)
			hello(DEVICE, BOX, nil, nil)
			assert.equal("false", sent[2].params.match)
			own = nil
			hello(DEVICE, BOX, BRIDGE, TV)
			assert.equal("false", sent[3].params.match)
			assert.is_nil(sent[3].params.bridge_id, "no bridge id while unpaired")
		end)

		it("compares bridge ids in lower case and keeps box ids in upper case, area ids in lower", function()
			bind(DEVICE)
			hello(DEVICE, BOX:lower(), BRIDGE:upper(), TV:upper())
			assert.equal("true", sent[1].params.match)
			assert.same({ device_id = DEVICE, box_id = BOX, bridge_id = BRIDGE, area_id = TV,
				name = "Living Room Sync Box" }, s:boxes()[1])
		end)

		it("takes an unpaired box's hello without a box id, a bridge or an area", function()
			bind(DEVICE)
			assert.is_true(s:hello({ device_id = tostring(DEVICE) }))
			assert.equal("false", sent[1].params.match)
			assert.is_nil(s:boxes()[1].box_id)
			assert.is_true(saw("unpaired box (device 2001)"))
		end)

		it("drops a hello without a device id, or with a value that is no id, with one debug line", function()
			bind(DEVICE)
			local bad = {
				{ device_id = nil, box_id = BOX },
				{ device_id = "abc", box_id = BOX },
				{ device_id = "0", box_id = BOX },
				{ device_id = "-1", box_id = BOX },
				{ device_id = "1.5", box_id = BOX },
				{ device_id = "1e999", box_id = BOX },
				{ device_id = "2001", box_id = "0A1B2C3D4E5" },
				{ device_id = "2001", box_id = "0A1B2C3D4E5G" },
				{ device_id = "2001", box_id = BOX, bridge_id = "001788fffe12/abc" },
				{ device_id = "2001", box_id = BOX, bridge_id = ("a"):rep(65) },
				{ device_id = "2001", box_id = BOX, area_id = "../../light" },
				{ device_id = "2001", box_id = BOX, area_id = "groups/3" },
				{ device_id = "2001", box_id = BOX, area_id = ("a"):rep(65) },
				{ device_id = "2001", box_id = { "table" } },
			}
			for i, params in ipairs(bad) do
				local before = #lines
				assert.is_false(s:hello(params), tostring(i))
				assert.equal(before + 1, #lines, tostring(i))
				assert.truthy(lines[#lines]:find("dropped", 1, true), lines[#lines])
			end
			assert.is_false(s:hello(nil))
			assert.same({}, sent)
			assert.same({}, s:boxes())
		end)

		it("keeps a hello from a device not shown bound unanswered until OnBindingChanged says it is", function()
			bound = {}
			assert.is_false(hello(DEVICE, BOX, BRIDGE, TV))
			assert.same({}, sent)
			assert.is_true(saw("not bound on Hue Sync Boxes"))
			bind(DEVICE)
			assert.equal(1, #sent)
			assert.equal("HUE_SYNCBOX_CONFIGURE", sent[1].command)
			assert.equal(1, s:count())
		end)

		it("answers at once when the lookup shows the device bound", function()
			bound = { [DEVICE] = "Hue Sync Box" }
			assert.is_true(hello(DEVICE, BOX, BRIDGE, TV))
			assert.equal(1, #sent)
			bound = { [tostring(DEVICE)] = "Hue Sync Box" }
			assert.is_true(hello(DEVICE, BOX, BRIDGE, TV), "an id given as text")
		end)

		it("trusts OnBindingChanged over the lookup, which Director settles after the callback", function()
			bound = {}
			bind(DEVICE)
			assert.is_true(hello(DEVICE, BOX, BRIDGE, TV))
			s:binding_changed(2, "HUE_SYNCBOX", false, DEVICE)
			bound = { [DEVICE] = "Hue Sync Box" }
			assert.is_false(hello(DEVICE, BOX, BRIDGE, TV), "unbound by the callback, whatever the lookup says")
		end)

		it("keeps at most MAX_PENDING hellos waiting", function()
			for i = 1, syncboxes.MAX_PENDING + 3 do
				hello(3000 + 2 * i, BOX, BRIDGE, TV)
			end
			for i = 1, syncboxes.MAX_PENDING + 3 do
				s:binding_changed(2, "HUE_SYNCBOX", true, 3000 + 2 * i)
			end
			assert.equal(syncboxes.MAX_PENDING, #of("HUE_SYNCBOX_CONFIGURE"))
		end)

		it("refuses a box beyond MAX_BOXES with a warning", function()
			for i = 1, syncboxes.MAX_BOXES + 1 do
				bind(4000 + i)
				hello(4000 + i, nil, BRIDGE, nil)
			end
			assert.equal(syncboxes.MAX_BOXES, s:count())
			assert.is_true(saw("sync boxes are bound already"))
			assert.is_true(hello(4001, BOX, BRIDGE, TV), "a known box may say hello again")
		end)

		it("replaces the box's record at its next hello: another area, another bridge", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			hello(DEVICE, BOX, BRIDGE, OFFICE)
			assert.equal(OFFICE, s:boxes()[1].area_id)
			assert.equal(1, s:count())
			assert.is_nil(s:label_for(TV))
			assert.equal("Living Room Sync Box", s:label_for(OFFICE))
		end)
	end)

	describe("goodbye()", function()
		before_each(function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
		end)

		it("forgets the box", function()
			assert.is_true(s:goodbye({ device_id = tostring(DEVICE), box_id = BOX }))
			assert.same({}, s:boxes())
			assert.is_nil(s:label_for(TV))
			assert.is_true(saw("#4E5F (device 2001) forgotten (goodbye)"))
		end)

		it("takes the box id in either case, or none", function()
			assert.is_true(s:goodbye({ device_id = tostring(DEVICE), box_id = BOX:lower() }))
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			assert.is_true(s:goodbye({ device_id = tostring(DEVICE) }))
		end)

		it("ignores one from a device without a box, without a device id, or naming another box", function()
			assert.is_false(s:goodbye({ device_id = tostring(DEVICE2), box_id = BOX }))
			assert.is_false(s:goodbye({ box_id = BOX }))
			assert.is_false(s:goodbye(nil))
			assert.is_false(s:goodbye({ device_id = tostring(DEVICE), box_id = BOX2 }))
			assert.is_false(s:goodbye({ device_id = tostring(DEVICE), box_id = "nonsense" }))
			assert.equal(1, s:count())
		end)
	end)

	describe("binding_changed()", function()
		it("is connection 2's alone: false for the Hue Lights connection and other classes", function()
			assert.is_false(s:binding_changed(1, "HUE_BRIDGE", true, DEVICE))
			assert.is_false(s:binding_changed(2, "HUE_BRIDGE", true, DEVICE))
			assert.is_false(s:binding_changed("1", nil, true, DEVICE))
			assert.is_true(s:binding_changed("2", nil, true, DEVICE), "the class may be left out")
			assert.is_true(s:binding_changed(2, "HUE_SYNCBOX", true, "junk"), "a device id that is none: handled, nothing done")
		end)

		it("forgets a box unbound, and its waiting hello", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			bound = {}
			hello(DEVICE2, BOX2, BRIDGE, OFFICE)
			assert.is_true(s:binding_changed(2, "HUE_SYNCBOX", "false", DEVICE))
			assert.is_true(s:binding_changed(2, "HUE_SYNCBOX", false, DEVICE2))
			assert.same({}, s:boxes())
			assert.is_true(saw("forgotten (unbound)"))
			bound = { [DEVICE2] = "Hue Sync Box" }
			s:binding_changed(2, "HUE_SYNCBOX", "true", DEVICE2)
			assert.equal(0, s:count(), "the waiting hello went with the unbind")
		end)
	end)

	describe("configure_all()", function()
		it("sends CONFIGURE to every bound box, with the same areas, and returns how many", function()
			bind(DEVICE)
			bind(DEVICE2)
			hello(DEVICE, BOX, BRIDGE, TV)
			hello(DEVICE2, BOX2, OTHER_BRIDGE, OFFICE)
			sent = {}
			areas[1].name = "Cinema"
			assert.equal(2, s:configure_all())
			assert.same({ DEVICE, DEVICE2 }, { sent[1].id, sent[2].id })
			assert.same({ "true", "false" }, { sent[1].params.match, sent[2].params.match })
			assert.equal(sent[1].params.areas, sent[2].params.areas)
			assert.equal("Cinema", decoded(sent[1].params.areas)[1].name)
		end)

		it("answers the hellos that waited once the lookup shows them bound, and drops the rest", function()
			bound = nil
			hello(DEVICE, BOX, BRIDGE, TV)
			hello(DEVICE2, BOX2, BRIDGE, OFFICE)
			assert.equal(0, s:configure_all(), "the lookup still unknown: they wait")
			bound = { [DEVICE] = "Hue Sync Box" }
			assert.equal(1, s:configure_all())
			assert.equal(1, #sent, "one CONFIGURE for the box that waited, not two")
			assert.equal(DEVICE, sent[1].id)
			bound = { [DEVICE] = "Hue Sync Box", [DEVICE2] = "Hue Sync Box" }
			assert.equal(1, s:configure_all(), "the second hello was dropped when the lookup said no")
		end)

		it("forgets a box the lookup no longer shows, unless OnBindingChanged said it is bound", function()
			bound = { [DEVICE] = "Hue Sync Box", [DEVICE2] = "Hue Sync Box" }
			hello(DEVICE, BOX, BRIDGE, TV)
			hello(DEVICE2, BOX2, BRIDGE, OFFICE)
			bind(DEVICE3)
			hello(DEVICE3, nil, BRIDGE, nil)
			bound = { [DEVICE] = "Hue Sync Box" }
			assert.equal(2, s:configure_all())
			assert.same({ DEVICE, DEVICE3 }, { s:boxes()[1].device_id, s:boxes()[2].device_id })
			assert.is_true(saw("forgotten (no longer bound)"))
			bound = nil
			assert.equal(2, s:configure_all(), "an unknown lookup forgets nothing")
		end)

		it("says match again after the bridge was paired anew", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			own = OTHER_BRIDGE
			sent = {}
			s:configure_all()
			assert.equal("false", sent[1].params.match)
			assert.equal(OTHER_BRIDGE, sent[1].params.bridge_id)
		end)

		it("sends nothing without boxes", function()
			assert.equal(0, s:configure_all())
			assert.same({}, sent)
		end)
	end)

	describe("on_stream()", function()
		before_each(function()
			bind(DEVICE)
			bind(DEVICE2)
			bind(DEVICE3)
			hello(DEVICE, BOX, BRIDGE, TV)
			hello(DEVICE2, BOX2, BRIDGE, OFFICE)
			hello(DEVICE3, nil, nil, nil)
			sent = {}
		end)

		it("sends AREA to every bound box: this_box for the box of the area, other for the rest", function()
			assert.equal(3, s:on_stream(areas[1], true))
			assert.same({
				{ id = DEVICE, command = "HUE_SYNCBOX_AREA", params = { id = TV, status = "active", streamer = "this_box" } },
				{ id = DEVICE2, command = "HUE_SYNCBOX_AREA", params = { id = TV, status = "active", streamer = "other" } },
				{ id = DEVICE3, command = "HUE_SYNCBOX_AREA", params = { id = TV, status = "active", streamer = "other" } },
			}, sent)
		end)

		it("says none when it stopped", function()
			sent = {}
			assert.equal(3, s:on_stream(areas[2], false))
			for _, m in ipairs(sent) do
				assert.same({ id = OFFICE, status = "inactive", streamer = "none" }, m.params)
			end
		end)

		it("sends nothing for an area without an id", function()
			assert.equal(0, s:on_stream({ name = "?" }, true))
			assert.equal(0, s:on_stream({ id = "x/y" }, true))
			assert.equal(0, s:on_stream(nil, true))
			assert.same({}, sent)
		end)

		it("goes on to the other boxes when one send raises, with a warning", function()
			s = new_s({ send = function(id, command, params)
				if id == DEVICE then error("gone") end
				sent[#sent + 1] = { id = id, command = command, params = params }
			end })
			bind(DEVICE)
			bind(DEVICE2)
			hello(DEVICE, BOX, BRIDGE, TV)
			hello(DEVICE2, BOX2, BRIDGE, OFFICE)
			sent = {}
			assert.equal(1, s:on_stream(areas[1], true))
			assert.equal(DEVICE2, sent[1].id)
			assert.is_true(saw("HUE_SYNCBOX_AREA to device 2001 failed"))
		end)
	end)

	describe("label_for()", function()
		it("is the Composer name of the one box of this bridge whose area it is", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			assert.equal("Living Room Sync Box", s:label_for(TV))
			assert.equal("Living Room Sync Box", s:label_for(TV:upper()))
			assert.is_nil(s:label_for(OFFICE))
			assert.is_nil(s:label_for(nil))
			assert.is_nil(s:label_for("x/y"))
		end)

		it("follows a rename in Composer, and cleans the name", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			names[DEVICE] = "  Cinema\nBox  "
			assert.equal("CinemaBox", s:label_for(TV))
		end)

		it("falls back on the name read at the hello, then on Hue Sync Box", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			names[DEVICE] = nil
			assert.equal("Living Room Sync Box", s:label_for(TV))
			s = new_s({ display_name = function() error("no project") end })
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			assert.equal("Hue Sync Box", s:label_for(TV))
			assert.is_true(saw("display_name failed"))
		end)

		it("is nil for a box of another bridge, or of none, and while this bridge is unpaired", function()
			bind(DEVICE)
			hello(DEVICE, BOX, OTHER_BRIDGE, TV)
			assert.is_nil(s:label_for(TV))
			hello(DEVICE, BOX, nil, TV)
			assert.is_nil(s:label_for(TV))
			hello(DEVICE, BOX, BRIDGE, TV)
			own = nil
			assert.is_nil(s:label_for(TV))
		end)

		it("is nil when two boxes name the same area: neither is the one", function()
			bind(DEVICE)
			bind(DEVICE2)
			hello(DEVICE, BOX, BRIDGE, TV)
			hello(DEVICE2, BOX2, BRIDGE, TV)
			assert.is_nil(s:label_for(TV))
			s:goodbye({ device_id = tostring(DEVICE2), box_id = BOX2 })
			assert.equal("Living Room Sync Box", s:label_for(TV))
		end)
	end)

	describe("on_labels_changed()", function()
		it("hands on the lamps of a streaming area whose box changed, once each, sorted", function()
			areas[1].status = "active"
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			assert.same({ { lamp(1), lamp(2), lamp(3) } }, label_changes)
			hello(DEVICE, BOX, BRIDGE, TV)
			assert.equal(1, #label_changes, "the same hello again changes nothing")
			s:goodbye({ device_id = tostring(DEVICE) })
			assert.same({ lamp(1), lamp(2), lamp(3) }, label_changes[2])
		end)

		it("says nothing for an area that does not stream", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, OFFICE)
			s:binding_changed(2, "HUE_SYNCBOX", false, DEVICE)
			assert.same({}, label_changes)
		end)

		it("follows a box moving from one streaming area to another", function()
			areas[1].status, areas[2].status = "active", "active"
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			label_changes = {}
			hello(DEVICE, BOX, BRIDGE, OFFICE)
			assert.same({ { lamp(1), lamp(2), lamp(3), lamp(4) } }, label_changes)
		end)

		it("follows this bridge's pairing at the next configure_all", function()
			areas[1].status = "active"
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			label_changes = {}
			own = OTHER_BRIDGE
			s:configure_all()
			assert.same({ { lamp(1), lamp(2), lamp(3) } }, label_changes)
		end)
	end)

	describe("the areas' JSON", function()
		it("is [] without areas, and when areas() raises (with a warning)", function()
			areas = {}
			assert.equal("[]", s:areas_json())
			s = new_s({ areas = function() error("not yet") end })
			assert.equal("[]", s:areas_json())
			assert.is_true(saw("areas failed"))
		end)

		it("escapes quotes and backslashes, and keeps UTF-8 as it is", function()
			areas = { { id = TV, name = 'Tom\'s "Cinema" \\ Ü→', kind = "screen", status = "active", lamps = {} } }
			rooms = {}
			local list = decoded(s:areas_json())
			assert.equal('Tom\'s "Cinema" \\ Ü→', list[1].name)
			assert.same({}, list[1].rooms)
		end)

		it("takes the names through util.display_name, and an unknown type as other", function()
			areas = { { id = TV, name = "Living\nRoom TV  ", kind = nil, status = "streaming", lamps = "junk" } }
			assert.same({ { id = TV, name = "LivingRoom TV", type = "other", status = "inactive", lamps = 0, rooms = {} } },
				decoded(s:areas_json()))
		end)

		it("leaves out an area without a resource id or a name", function()
			areas = { { id = "x/y", name = "Bad" }, { id = TV }, "junk", { id = OFFICE, name = "Office", lamps = {} } }
			local list = decoded(s:areas_json())
			assert.equal(1, #list)
			assert.equal(OFFICE, list[1].id)
		end)

		it("holds at most MAX_AREAS areas", function()
			areas = {}
			for i = 1, 70 do
				areas[i] = { id = string.format("ea-%02d", i), name = string.format("Area %02d", i), lamps = {} }
			end
			assert.equal(64, #decoded(s:areas_json()))
		end)
	end)

	describe("the rooms", function()
		it("are sorted by name, each once, cleaned, at most MAX_ROOMS", function()
			local many = {}
			for i = 1, 40 do
				many[i] = string.format("Room %02d", 41 - i)
			end
			s = new_s({ rooms_for = function() return many end })
			local list = s:rooms_of({ lamp(1) })
			assert.equal(32, #list)
			assert.equal("Room 01", list[1])
			s = new_s({ rooms_for = function() return { "b", "A", "a", "B\n", "", 7, {} } end })
			assert.same({ "7", "A", "a", "B", "b" }, s:rooms_of({}), "by name whatever the case, then as written")
		end)

		it("come from the lights' room mappings without rooms_for", function()
			local lights = {
				models = { [lamp(1)] = { rid = lamp(1) }, [lamp(2)] = { rid = lamp(2) }, [lamp(3)] = { rid = lamp(3) },
					[lamp(4)] = { rid = lamp(4) } },
				rooms_by_lamp = { [lamp(1)] = "hr-living", [lamp(2)] = "hr-living", [lamp(3)] = "hr-gone",
					[lamp(4)] = "hr-unmapped" },
				mappings = { ["hr-living"] = { c4_room_id = 12, c4_room_name = "Lounge (old)" },
					["hr-gone"] = { c4_room_id = 99, c4_room_name = "Gone" } },
				project = { c4_rooms = { [12] = "Living Room", [13] = "Kitchen" } },
			}
			function lights.hue_room_of(self, model)
				return self.rooms_by_lamp[model.rid], "label"
			end
			function lights.room_mapping(self, group)
				return self.mappings[group]
			end
			function lights.project.rooms(self)
				return self.c4_rooms
			end
			s = new_s({ rooms_for = false, lights = function() return lights end })
			assert.same({ "Living Room" }, s:rooms_of({ lamp(1), lamp(2), lamp(3), lamp(4), "not-a-lamp" }),
				"a room gone from the project and an unmapped lamp are left out")
			lights.project.c4_rooms = {}
			assert.same({ "Gone", "Lounge (old)" }, s:rooms_of({ lamp(1), lamp(3) }),
				"the project's rooms unknown: the names kept with the mappings")
			lights.hue_room_of = function() error("broken") end
			assert.same({}, s:rooms_of({ lamp(1) }))
			assert.is_true(saw("the rooms of an area"))
			s = new_s({ rooms_for = false })
			assert.same({}, s:rooms_of({ lamp(1) }), "no lights, no rooms")
		end)
	end)
end)
