-- bridge/syncboxes.lua (2.0 beta stage 2, #534): the Hue Sync Box devices
-- bound on the bridge's "Hue Sync Boxes" connection, and the messages of
-- contracts C5 the bridge sends them (docs/hdmi-sync-stage2-design.md §6);
-- stage 4 (#568, docs/hdmi-sync-stage4-design.md §6): each box's sync state,
-- the label it gives, and the take-over (STOP_AREA, O12) with research W10's
-- guard. Placeholders only: bridge 001788fffe123abc, box 0A1B2C3D4E5F.

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

	local function hello(device_id, box_id, bridge_id, area_id, syncing)
		return s:hello({ device_id = device_id and tostring(device_id) or nil, box_id = box_id, bridge_id = bridge_id,
			area_id = area_id, syncing = syncing })
	end

	local function state(device_id, box_id, bridge_id, area_id, syncing)
		return s:state({ device_id = device_id and tostring(device_id) or nil, box_id = box_id, bridge_id = bridge_id,
			area_id = area_id, syncing = syncing })
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

	-- Bound through OnBindingChanged, as Director reports a new binding. A
	-- device without a hello is asked for one (the cases of "asking for
	-- hellos" below): at most that one ASK_HELLO, set aside here.
	local function bind(id)
		local before = #sent
		assert.is_true(s:binding_changed(2, "HUE_SYNCBOX", true, id))
		if #sent > before and sent[#sent].command == "HUE_SYNCBOX_ASK_HELLO" then
			assert.equal(before + 1, #sent)
			assert.same({ id = id, command = "HUE_SYNCBOX_ASK_HELLO", params = {} }, sent[#sent])
			sent[#sent] = nil
		end
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
			assert.equal("HUE_SYNCBOX_STATE", syncboxes.STATE)
			assert.equal("HUE_SYNCBOX_STOP_AREA", syncboxes.STOP_AREA)
			assert.equal("HUE_SYNCBOX_STOPPED", syncboxes.STOPPED)
			assert.equal(64, syncboxes.MAX_AREAS)
			assert.equal(3, syncboxes.TAKE_OVER_GRACE_S)
		end)

		it("needs send, and takes the rest from defaults", function()
			assert.has_error(function() syncboxes.new({}) end)
			local bare = syncboxes.new({ send = function(id, command, params)
				sent[#sent + 1] = { id = id, command = command, params = params }
			end })
			assert.is_true(bare:binding_changed(2, "HUE_SYNCBOX", true, DEVICE))
			assert.is_true(bare:hello({ device_id = tostring(DEVICE), box_id = BOX }))
			assert.same({ match = "false", areas = "[]" }, of("HUE_SYNCBOX_CONFIGURE")[1].params, "no bridge id, no areas")
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

	describe("the sync state (stage 4)", function()
		it("keeps a hello's sync state: true, false, or unknown when left out", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV, "true")
			assert.is_true(s:boxes()[1].syncing)
			hello(DEVICE, BOX, BRIDGE, TV, "false")
			assert.is_false(s:boxes()[1].syncing)
			hello(DEVICE, BOX, BRIDGE, TV, "")
			assert.is_nil(s:boxes()[1].syncing)
			assert.is_true(saw("area " .. TV .. ", sync state unknown"))
		end)

		it("drops a hello whose sync state is neither true nor false", function()
			bind(DEVICE)
			assert.is_false(hello(DEVICE, BOX, BRIDGE, TV, "yes"))
			assert.is_true(saw("its sync state is neither true nor false"))
			assert.same({}, sent)
		end)

		it("takes a STATE of a known box quietly: its area and state, no CONFIGURE", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV, "false")
			sent = {}
			assert.is_true(state(DEVICE, BOX, BRIDGE, OFFICE, "true"))
			assert.same({}, sent)
			assert.same({ device_id = DEVICE, box_id = BOX, bridge_id = BRIDGE, area_id = OFFICE, syncing = true,
				name = "Living Room Sync Box" }, s:boxes()[1])
			assert.is_true(saw("Living Room Sync Box #4E5F (device 2001) syncs, area " .. OFFICE))
		end)

		it("greets a STATE from a bound box it has no hello from as a hello (a bridge restart)", function()
			bind(DEVICE)
			assert.is_true(state(DEVICE, BOX, BRIDGE, TV, "true"))
			local configure = of("HUE_SYNCBOX_CONFIGURE")
			assert.equal(1, #configure)
			assert.equal("true", configure[1].params.match)
			assert.is_true(s:boxes()[1].syncing)
		end)

		it("greets a STATE that names another bridge or box than the hello as a hello", function()
			bind(DEVICE)
			hello(DEVICE, BOX, OTHER_BRIDGE, TV, "false")
			sent = {}
			assert.is_true(state(DEVICE, BOX, BRIDGE, TV, "true"))
			assert.same({ "true" }, { of("HUE_SYNCBOX_CONFIGURE")[1].params.match })
			assert.is_true(state(DEVICE, BOX2, BRIDGE, TV, "true"))
			assert.equal(2, #of("HUE_SYNCBOX_CONFIGURE"))
			assert.equal(BOX2, s:boxes()[1].box_id)
		end)

		it("keeps a STATE from a device not shown bound waiting, as a hello", function()
			bound = {}
			assert.is_false(state(DEVICE, BOX, BRIDGE, TV, "true"))
			assert.same({}, sent)
			assert.is_true(saw("HUE_SYNCBOX_STATE from device 2001 not answered"))
			bind(DEVICE)
			assert.equal(1, #of("HUE_SYNCBOX_CONFIGURE"))
			assert.is_true(s:boxes()[1].syncing)
		end)

		it("drops a STATE without a sync state, or with a value that is none, with one debug line", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV, "true")
			sent = {}
			local bad = {
				{ device_id = "2001", box_id = BOX, bridge_id = BRIDGE, area_id = TV },
				{ device_id = "2001", box_id = BOX, bridge_id = BRIDGE, area_id = TV, syncing = "maybe" },
				{ box_id = BOX, bridge_id = BRIDGE, area_id = TV, syncing = "false" },
				{ device_id = "2001", box_id = BOX, bridge_id = BRIDGE, area_id = "../light", syncing = "false" },
			}
			for i, params in ipairs(bad) do
				local before = #lines
				assert.is_false(s:state(params), tostring(i))
				assert.equal(before + 1, #lines, tostring(i))
				assert.truthy(lines[#lines]:find("HUE_SYNCBOX_STATE from device", 1, true), lines[#lines])
				assert.truthy(lines[#lines]:find("dropped", 1, true), lines[#lines])
			end
			assert.is_false(s:state(nil))
			assert.same({}, sent)
			assert.is_true(s:boxes()[1].syncing)
		end)
	end)

	describe("the label with the sync state (stage 4)", function()
		it("names the box that says it syncs when two boxes name the area (W10)", function()
			bind(DEVICE)
			bind(DEVICE2)
			hello(DEVICE, BOX, BRIDGE, TV, "false")
			hello(DEVICE2, BOX2, BRIDGE, TV, "false")
			assert.is_nil(s:label_for(TV), "neither syncs")
			state(DEVICE2, BOX2, BRIDGE, TV, "true")
			assert.equal("Den Sync Box", s:label_for(TV))
			state(DEVICE, BOX, BRIDGE, TV, "true")
			assert.is_nil(s:label_for(TV), "two say so: neither is the one")
		end)

		it("never names a box that says it does not sync, and names a lone one whose state is unknown", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV)
			assert.equal("Living Room Sync Box", s:label_for(TV))
			state(DEVICE, BOX, BRIDGE, TV, "false")
			assert.is_nil(s:label_for(TV))
		end)

		it("prefers the box that syncs over one whose state is unknown", function()
			bind(DEVICE)
			bind(DEVICE2)
			hello(DEVICE, BOX, BRIDGE, TV)
			hello(DEVICE2, BOX2, BRIDGE, TV, "true")
			assert.equal("Den Sync Box", s:label_for(TV))
		end)

		it("hands on the lamps when a STATE changes who streams to a streaming area", function()
			areas[1].status = "active"
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV, "true")
			assert.equal(1, #label_changes)
			state(DEVICE, BOX, BRIDGE, TV, "true")
			assert.equal(1, #label_changes, "the same word again changes nothing")
			state(DEVICE, BOX, BRIDGE, TV, "false")
			assert.same({ lamp(1), lamp(2), lamp(3) }, label_changes[2])
		end)

		it("forgets a box's 'not syncing' when a stream starts on its area, until its next word", function()
			bind(DEVICE)
			bind(DEVICE2)
			hello(DEVICE, BOX, BRIDGE, TV, "false")
			hello(DEVICE2, BOX2, BRIDGE, OFFICE, "false")
			assert.is_nil(s:label_for(TV))
			areas[1].status = "active"
			s:on_stream(areas[1], true)
			assert.equal("Living Room Sync Box", s:label_for(TV))
			assert.is_nil(s:boxes()[1].syncing)
			assert.is_false(s:boxes()[2].syncing, "a box on another area keeps its word")
			assert.same({ { lamp(1), lamp(2), lamp(3) } }, label_changes)
			state(DEVICE, BOX, BRIDGE, TV, "false")
			assert.is_nil(s:label_for(TV), "its next word: another app streams")
			s:on_stream(areas[1], false)
			assert.is_false(s:boxes()[1].syncing, "a stream that stops changes no word")
		end)
	end)

	describe("stop_area() (stage 4: O12, W10)", function()
		local timers, puts, http_answer, stopped_texts

		local function new_take_over(extra)
			local deps = {
				http = function(req, cb)
					puts[#puts + 1] = { req = req, cb = cb }
					if http_answer then
						cb(http_answer)
					end
				end,
				set_timer = function(delay, fn)
					local t = { delay = delay, fn = fn }
					function t.Cancel(self)
						self.cancelled = true
					end
					timers[#timers + 1] = t
					return t
				end,
				on_stopped = function(text) stopped_texts[#stopped_texts + 1] = text end,
			}
			for k, v in pairs(extra or {}) do
				deps[k] = v
			end
			s = new_s(deps)
		end

		-- A STOP_AREA from `device_id`; the box's bridge is BRIDGE unless given ("" leaves it out).
		local function stop(device_id, area_id, bridge_id)
			return s:stop_area({ device_id = device_id and tostring(device_id) or nil, box_id = BOX,
				bridge_id = bridge_id or BRIDGE, area_id = area_id })
		end

		-- The STOPPED messages sent, as { device id, params }.
		local function answers()
			local out = {}
			for _, m in ipairs(of("HUE_SYNCBOX_STOPPED")) do
				out[#out + 1] = { m.id, m.params }
			end
			return out
		end

		local function puts_of()
			local out = {}
			for i, p in ipairs(puts) do
				out[i] = p.req
			end
			return out
		end

		local STOP_PUT = { method = "PUT", path = "/clip/v2/resource/entertainment_configuration/" .. TV,
			body = { action = "stop" } }

		-- Two boxes of this bridge on the TV area, neither syncing: a stop waits the grace.
		local function two_on_tv()
			bind(DEVICE)
			bind(DEVICE2)
			hello(DEVICE, BOX, BRIDGE, TV, "false")
			hello(DEVICE2, BOX2, BRIDGE, TV, "false")
			sent = {}
		end

		before_each(function()
			timers, puts, stopped_texts = {}, {}, {}
			http_answer = { ok = true, code = 200 }
			areas[1].status = "active"
			new_take_over()
		end)

		it("stops a lone box's area at once through the bridge's request path, and answers stopped", function()
			bind(DEVICE)
			hello(DEVICE, BOX, BRIDGE, TV, "false")
			sent = {}
			assert.is_true(stop(DEVICE, TV:upper()))
			assert.same({ STOP_PUT }, puts_of())
			assert.same({}, timers)
			assert.same({ { DEVICE, { area_id = TV, ok = "true", reason = "stopped" } } }, answers())
			for k, v in pairs(answers()[1][2]) do
				assert.equal("string", type(v), k)
			end
			assert.same({ "Sync stopped for Living Room Sync Box: Living Room TV" }, stopped_texts)
			assert.is_true(saw("Living Room Sync Box #4E5F (device 2001) asks to stop the stream on area " .. TV))
			assert.is_true(saw("the stream on Living Room TV is stopped for Living Room Sync Box"))
			assert.equal(1, #sent, "STOPPED and nothing else")
		end)

		it("takes a box it has no hello from when Director shows it bound and it names this bridge", function()
			bound = { [DEVICE] = "Hue Sync Box" }
			assert.is_true(stop(DEVICE, TV))
			assert.same({ STOP_PUT }, puts_of())
			assert.equal("true", answers()[1][2].ok)
		end)

		it("ignores a device not shown bound, unanswered, with a warning naming it", function()
			bound = {}
			assert.is_false(stop(DEVICE, TV))
			bound = nil
			assert.is_false(stop(DEVICE, TV), "the lookup unknown")
			assert.same({}, sent)
			assert.same({}, puts)
			assert.is_true(saw("HUE_SYNCBOX_STOP_AREA from device 2001 for area " .. TV
				.. " ignored: not bound on Hue Sync Boxes"))
		end)

		it("drops a malformed request with one debug line", function()
			bind(DEVICE)
			local bad = {
				{ area_id = TV },
				{ device_id = "abc", area_id = TV },
				{ device_id = "2001" },
				{ device_id = "2001", area_id = "" },
				{ device_id = "2001", area_id = "../light" },
				{ device_id = "2001", area_id = ("a"):rep(65) },
				{ device_id = "2001", area_id = TV, bridge_id = "001788fffe12/abc" },
				{ device_id = "2001", area_id = TV, box_id = "0A1B2C3D4E5" },
			}
			for i, params in ipairs(bad) do
				local before = #lines
				assert.is_false(s:stop_area(params), tostring(i))
				assert.equal(before + 1, #lines, tostring(i))
				assert.truthy(lines[#lines]:find("HUE_SYNCBOX_STOP_AREA from device", 1, true), lines[#lines])
				assert.truthy(lines[#lines]:find("dropped", 1, true), lines[#lines])
			end
			assert.is_false(s:stop_area(nil))
			assert.same({}, sent)
			assert.same({}, puts)
		end)

		it("refuses a box whose bridge is another or unknown, and while this bridge is unpaired: not_linked", function()
			bind(DEVICE)
			assert.is_false(stop(DEVICE, TV, OTHER_BRIDGE))
			assert.same({ { DEVICE, { area_id = TV, ok = "false", reason = "not_linked" } } }, answers())
			assert.is_true(saw("the stream on area " .. TV .. " is not stopped: its box is not linked to this bridge"))
			assert.is_false(stop(DEVICE, TV, ""), "no bridge in the message, and no hello")
			hello(DEVICE, BOX, BRIDGE, TV)
			assert.is_true(stop(DEVICE, TV, ""), "the bridge of its hello")
			own = nil
			assert.is_false(stop(DEVICE, TV))
			assert.same({ "not_linked", "not_linked", "stopped", "not_linked" }, {
				answers()[1][2].reason, answers()[2][2].reason, answers()[3][2].reason, answers()[4][2].reason })
			assert.equal(1, #puts)
		end)

		it("refuses an area this bridge does not have: no_area", function()
			bind(DEVICE)
			local gone = "6a7b8c9d-0000-4000-8000-0000000ea0ff"
			assert.is_false(stop(DEVICE, gone))
			assert.same({ { DEVICE, { area_id = gone, ok = "false", reason = "no_area" } } }, answers())
			assert.same({}, puts)
			assert.is_true(saw("is not stopped: this bridge has no such area"))
		end)

		it("refuses at once when another box of this bridge says it syncs to the area: another_box (W10)", function()
			bind(DEVICE)
			bind(DEVICE2)
			hello(DEVICE2, BOX2, BRIDGE, TV, "true")
			hello(DEVICE, BOX, BRIDGE, TV, "false")
			sent = {}
			assert.is_false(stop(DEVICE, TV))
			assert.same({ { DEVICE, { area_id = TV, ok = "false", reason = "another_box", by = "Den Sync Box" } } },
				answers())
			assert.same({}, puts)
			assert.same({}, timers)
			assert.is_true(saw("a sync box of this project syncs to it (W10) (Den Sync Box)"))
		end)

		it("counts neither the asking box's own word, nor a box of another bridge, nor one on another area", function()
			bind(DEVICE)
			bind(DEVICE2)
			bind(DEVICE3)
			hello(DEVICE, BOX, BRIDGE, TV, "true")
			hello(DEVICE2, BOX2, OTHER_BRIDGE, TV, "true")
			hello(DEVICE3, "0A1B2C3D4E61", BRIDGE, OFFICE, "true")
			assert.is_true(stop(DEVICE, TV))
			assert.same({}, timers, "nobody to wait for")
			assert.same({ STOP_PUT }, puts_of())
			assert.equal("stopped", answers()[1][2].reason)
		end)

		it("counts a box of this bridge that says it syncs without naming an area", function()
			bind(DEVICE)
			bind(DEVICE2)
			hello(DEVICE2, BOX2, BRIDGE, nil, "true")
			hello(DEVICE, BOX, BRIDGE, TV)
			assert.is_false(stop(DEVICE, TV))
			assert.equal("another_box", answers()[1][2].reason)
		end)

		it("waits the grace while another box naming the area has not said it syncs, then stops", function()
			two_on_tv()
			assert.is_true(stop(DEVICE, TV))
			assert.equal(1, #timers)
			assert.equal(3000, timers[1].delay)
			assert.same({}, puts)
			assert.same({}, answers())
			assert.is_true(saw("Living Room TV: waiting 3 s for the other sync boxes on it to say whether they sync (W10)"))
			timers[1].fn()
			assert.same({ STOP_PUT }, puts_of())
			assert.same({ { DEVICE, { area_id = TV, ok = "true", reason = "stopped" } } }, answers())
		end)

		it("refuses after the grace when the other box said it syncs meanwhile (both started at once)", function()
			two_on_tv()
			stop(DEVICE, TV)
			state(DEVICE2, BOX2, BRIDGE, TV, "true")
			timers[1].fn()
			assert.same({}, puts)
			assert.same({ { DEVICE, { area_id = TV, ok = "false", reason = "another_box", by = "Den Sync Box" } } },
				answers())
		end)

		it("waits for a box whose sync state is unknown too", function()
			bind(DEVICE)
			bind(DEVICE2)
			hello(DEVICE2, BOX2, BRIDGE, TV)
			assert.is_true(stop(DEVICE, TV))
			assert.equal(1, #timers)
		end)

		it("answers every box that asked for the area with one PUT", function()
			two_on_tv()
			bind(DEVICE3)
			hello(DEVICE3, "0A1B2C3D4E61", BRIDGE, TV, "false")
			sent = {}
			assert.is_true(stop(DEVICE, TV))
			assert.is_true(stop(DEVICE2, TV))
			assert.equal(1, #timers)
			timers[1].fn()
			assert.equal(1, #puts)
			assert.same({ { DEVICE, { area_id = TV, ok = "true", reason = "stopped" } },
				{ DEVICE2, { area_id = TV, ok = "true", reason = "stopped" } } }, answers())
			assert.same({ "Sync stopped for Living Room Sync Box, Den Sync Box: Living Room TV" }, stopped_texts)
		end)

		it("answers a box that asks while the PUT is out with the same answer", function()
			http_answer = nil
			bind(DEVICE)
			bind(DEVICE2)
			assert.is_true(stop(DEVICE, TV))
			assert.is_true(stop(DEVICE2, TV))
			assert.equal(1, #puts)
			assert.same({}, answers())
			puts[1].cb({ ok = true, code = 200 })
			assert.equal(2, #answers())
			puts[1].cb({ ok = true, code = 200 })
			assert.equal(2, #answers(), "a second callback answers nothing")
		end)

		it("answers failed with the bridge's error, when the request raises, and without a request path", function()
			bind(DEVICE)
			http_answer = { ok = false, code = 503, err = "HTTP 503" }
			assert.is_true(stop(DEVICE, TV))
			assert.same({ { DEVICE, { area_id = TV, ok = "false", reason = "failed", detail = "HTTP 503" } } }, answers())
			assert.is_true(saw("stopping the stream on Living Room TV failed: HTTP 503"))
			http_answer = { ok = false, code = 404 }
			stop(DEVICE, TV)
			assert.equal("HTTP 404", answers()[2][2].detail)
			http_answer = { ok = false }
			stop(DEVICE, TV)
			assert.equal("no answer", answers()[3][2].detail)
			assert.same({}, stopped_texts)
			new_take_over({ http = function() error("boom") end })
			bind(DEVICE)
			stop(DEVICE, TV)
			assert.equal("failed", answers()[4][2].reason)
			assert.truthy(answers()[4][2].detail:find("boom", 1, true))
			new_take_over({ http = false })
			bind(DEVICE)
			stop(DEVICE, TV)
			assert.same({ area_id = TV, ok = "false", reason = "failed", detail = "no request path" }, answers()[5][2])
		end)

		it("cuts the detail and another box's name to 120 bytes", function()
			bind(DEVICE)
			http_answer = { ok = false, err = ("x"):rep(300) }
			stop(DEVICE, TV)
			assert.equal(("x"):rep(117) .. "...", answers()[1][2].detail)
		end)

		it("refuses while MAX_STOPS areas wait already: busy", function()
			http_answer = nil
			areas = {}
			for i = 1, syncboxes.MAX_STOPS + 1 do
				areas[i] = { id = string.format("ea-%02d", i), name = string.format("Area %02d", i), status = "active",
					lamps = {} }
			end
			bind(DEVICE)
			for i = 1, syncboxes.MAX_STOPS do
				assert.is_true(stop(DEVICE, areas[i].id), tostring(i))
			end
			assert.is_false(stop(DEVICE, areas[syncboxes.MAX_STOPS + 1].id))
			assert.same({ { DEVICE, { area_id = "ea-05", ok = "false", reason = "busy" } } }, answers())
			assert.is_true(saw("too many stops wait already"))
		end)

		it("drops a stop whose boxes were all unbound during the grace, unanswered", function()
			two_on_tv()
			stop(DEVICE, TV)
			s:binding_changed(2, "HUE_SYNCBOX", false, DEVICE)
			timers[1].fn()
			assert.same({}, puts)
			assert.same({}, answers())
			assert.is_true(saw("dropped: no box that asked is bound now"))
		end)

		it("answers no_area when the area went during the grace", function()
			two_on_tv()
			stop(DEVICE, TV)
			table.remove(areas, 1)
			timers[1].fn()
			assert.same({}, puts)
			assert.same({ { DEVICE, { area_id = TV, ok = "false", reason = "no_area" } } }, answers())
		end)

		it("stop() cancels the waiting take-overs unanswered; a late timer or answer does nothing", function()
			two_on_tv()
			stop(DEVICE, TV)
			http_answer = nil
			assert.is_true(stop(DEVICE, OFFICE), "nobody on that area: the PUT goes out at once")
			assert.equal(1, #puts)
			s:stop()
			assert.is_true(timers[1].cancelled)
			timers[1].fn()
			puts[1].cb({ ok = true })
			assert.equal(1, #puts)
			assert.same({}, answers())
		end)

		it("answers failed when no timer can be set for the grace", function()
			new_take_over({ set_timer = function() error("no timers") end })
			two_on_tv()
			assert.is_false(stop(DEVICE, TV))
			assert.same({ { DEVICE, { area_id = TV, ok = "false", reason = "failed",
				detail = "the bridge could not wait for the other sync boxes" } } }, answers())
			assert.is_true(saw("no timer for the take-over"))
			assert.same({}, puts)
		end)

		it("sets its grace timer with C4:SetTimer by default", function()
			local saved, armed = _G.C4, {}
			_G.C4 = { SetTimer = function(_, delay, fn)
				armed[#armed + 1] = { delay = delay, fn = fn }
				return { Cancel = function() end }
			end }
			local ok, err = pcall(function()
				new_take_over({ set_timer = false })
				two_on_tv()
				stop(DEVICE, TV)
				armed[1].fn()
			end)
			_G.C4 = saved
			assert(ok, err)
			assert.equal(3000, armed[1].delay)
			assert.same({ STOP_PUT }, puts_of())
		end)

		it("logs a raise in the grace's run and in the answer, and goes on", function()
			two_on_tv()
			stop(DEVICE, TV)
			s.deps.areas = function() error("areas gone") end
			timers[1].fn()
			assert.is_true(saw("areas failed"))
			assert.equal("no_area", answers()[1][2].reason)
			new_take_over({ on_stopped = function() error("no property") end })
			bind(DEVICE)
			areas[1].status = "active"
			assert.is_true(stop(DEVICE, OFFICE))
			assert.is_true(saw("on_stopped failed"))
			assert.equal("stopped", answers()[2][2].reason)
		end)
	end)

	describe("asking for hellos (ASK_HELLO, #568)", function()
		local ASK = "HUE_SYNCBOX_ASK_HELLO"

		local function asked()
			local out = {}
			for _, m in ipairs(of(ASK)) do
				out[#out + 1] = m.id
			end
			return out
		end

		it("asks a device bound without a hello at its binding, once, with nothing in the message", function()
			assert.equal("HUE_SYNCBOX_ASK_HELLO", syncboxes.ASK_HELLO)
			assert.is_true(s:binding_changed(2, "HUE_SYNCBOX", true, DEVICE))
			assert.same({ { id = DEVICE, command = ASK, params = {} } }, sent)
			assert.is_true(saw("device 2001 is bound on Hue Sync Boxes without a hello: asking for one"))
			s:binding_changed(2, "HUE_SYNCBOX", true, DEVICE)
			bound = { [DEVICE] = "Hue Sync Box" }
			s:configure_all()
			assert.same({ DEVICE }, asked(), "once in a run")
		end)

		it("does not ask a device whose hello waits (it answers it) or is known", function()
			bound = {}
			hello(DEVICE, BOX, BRIDGE, TV)
			assert.is_true(s:binding_changed(2, "HUE_SYNCBOX", true, DEVICE))
			assert.same({ "HUE_SYNCBOX_CONFIGURE" }, { sent[1].command })
			assert.is_true(s:binding_changed(2, "HUE_SYNCBOX", true, DEVICE))
			bound = { [DEVICE] = "Hue Sync Box" }
			s:configure_all()
			assert.same({}, asked())
		end)

		it("asks every device the lookup shows bound without a hello at each resync, once each", function()
			bound = { [DEVICE] = "Hue Sync Box", [DEVICE2] = "Hue Sync Box", [DEVICE3] = "Hue Sync Box" }
			hello(DEVICE, BOX, BRIDGE, TV)
			sent = {}
			assert.equal(1, s:configure_all(), "the number told CONFIGURE")
			assert.same({ "HUE_SYNCBOX_CONFIGURE", ASK, ASK }, { sent[1].command, sent[2].command, sent[3].command })
			assert.same({ DEVICE2, DEVICE3 }, asked())
			s:configure_all()
			assert.same({ DEVICE2, DEVICE3 }, asked(), "not again")
			sent = {}
			assert.is_true(hello(DEVICE2, BOX2, BRIDGE, OFFICE, "true"))
			assert.same({ { id = DEVICE2, command = "HUE_SYNCBOX_CONFIGURE" } },
				{ { id = sent[1].id, command = sent[1].command } })
		end)

		it("asks nothing while the lookup is unknown, nor a device OnBindingChanged says is unbound", function()
			bound = nil
			assert.equal(0, s:configure_all())
			assert.same({}, sent)
			s:binding_changed(2, "HUE_SYNCBOX", false, DEVICE)
			bound = { [DEVICE] = "Hue Sync Box" }
			s:configure_all()
			assert.same({}, asked())
		end)

		it("asks a device OnBindingChanged said is bound that the lookup misses (its first ask failed)", function()
			local fail = true
			s = new_s({ send = function(id, command, params)
				if fail and command == ASK then error("gone") end
				sent[#sent + 1] = { id = id, command = command, params = params }
			end })
			bound = {}
			s:binding_changed(2, "HUE_SYNCBOX", true, DEVICE)
			fail = false
			s:configure_all()
			assert.same({ DEVICE }, asked())
		end)

		it("asks again after an unbind and a new binding", function()
			s:binding_changed(2, "HUE_SYNCBOX", true, DEVICE)
			s:binding_changed(2, "HUE_SYNCBOX", false, DEVICE)
			s:binding_changed(2, "HUE_SYNCBOX", true, DEVICE)
			assert.same({ DEVICE, DEVICE }, asked())
		end)

		it("asks again at the next resync after a send that raised", function()
			local fail = true
			s = new_s({ send = function(id, command, params)
				if fail and command == ASK then error("gone") end
				sent[#sent + 1] = { id = id, command = command, params = params }
			end })
			s:binding_changed(2, "HUE_SYNCBOX", true, DEVICE)
			assert.is_true(saw("HUE_SYNCBOX_ASK_HELLO to device 2001 failed"))
			fail = false
			bound = { [DEVICE] = "Hue Sync Box" }
			s:configure_all()
			assert.same({ DEVICE }, asked())
		end)

		it("asks at most MAX_BOXES devices at a resync, the rest at the next", function()
			bound = {}
			for i = 1, syncboxes.MAX_BOXES + 4 do
				bound[5000 + i] = "Hue Sync Box"
			end
			s:configure_all()
			assert.equal(syncboxes.MAX_BOXES, #asked())
			s:configure_all()
			assert.equal(syncboxes.MAX_BOXES + 4, #asked())
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
