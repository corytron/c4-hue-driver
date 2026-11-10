-- Control4 load groups on the real Hue Bridge driver (#435,
-- docs/load-groups-design.md §6.9): the wiring of bridge/load_groups.lua into
-- src/hue_bridge/driver.lua, driven through the fake runtime as
-- roundtrip_spec.lua drives it. The bridge pairs, reads the fixture bridge
-- (plus a Hue room "Hall" of eleven white lamps, for the pacing past the
-- tenth), imports every light with a mapped room, and then hears what the
-- light devices would send: HUE_LOAD_GROUPS after a hello, and HUE_SET and
-- HUE_DIM tagged with `group` for a load group's command. What reaches Hue is
-- read off the PUTs.
--
-- The fixture's groups: Living Room (room) = Hallway Ambiance + Living Room
-- Lamp; Garage (room) = Garage White alone; Downstairs (zone) = Garage White +
-- Living Room Lamp; Hall (room) = the eleven Hall Lamps.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local json = require("dkjson")
local F = require("fixtures.hue_resources")

local GARAGE_ROOM, HALL_ROOM = 8, 9
local HALL_LAMPS = 11
local LIGHT_URL = "https://192.0.2.10/clip/v2/resource/light/"
local GROUPED_URL = "https://192.0.2.10/clip/v2/resource/grouped_light/"
local EMPTY = '{"errors":[],"data":[]}'

-- The Hall room and its lamps (placeholder rids, hex only).
local HALL_RID = "4a110000-0000-4000-8000-000000000400"
local HALL_GROUPED = "4a110000-0000-4000-8000-000000000500"

local function hall_name(i) return string.format("Hall Lamp %02d", i) end
local function hall_rid(i) return string.format("4a11%04d-0000-4000-8000-000000000001", i) end
local function hall_device(i) return string.format("4d11%04d-0000-4000-8000-000000000002", i) end
local function hall_zigbee(i) return string.format("4c11%04d-0000-4000-8000-000000000003", i) end

local function hall_items()
	local lights, devices, zigbees, children = {}, {}, {}, {}
	for i = 1, HALL_LAMPS do
		lights[i] = string.format('{"id":"%s","id_v1":"/lights/%d","owner":{"rid":"%s","rtype":"device"},'
			.. '"service_id":0,"metadata":{"name":"%s","archetype":"classic_bulb","function":"functional"},'
			.. '"identify":{},"on":{"on":true},"dimming":{"brightness":50.0,"min_dim_level":5.0},"dimming_delta":{},'
			.. '"dynamics":{"status":"none","status_values":["none"],"speed":0,"speed_valid":false},"mode":"normal",'
			.. '"type":"light"}', hall_rid(i), 100 + i, hall_device(i), hall_name(i))
		devices[i] = string.format('{"id":"%s","id_v1":"/lights/%d","product_data":{"model_id":"LWA001",'
			.. '"manufacturer_name":"Signify Netherlands B.V.","product_name":"Hue white lamp",'
			.. '"product_archetype":"classic_bulb","certified":true,"software_version":"1.122.2",'
			.. '"hardware_platform_type":"100b-110"},"metadata":{"name":"%s","archetype":"classic_bulb"},'
			.. '"identify":{},"services":[{"rid":"%s","rtype":"zigbee_connectivity"},{"rid":"%s","rtype":"light"}],'
			.. '"type":"device"}', hall_device(i), 100 + i, hall_name(i), hall_zigbee(i), hall_rid(i))
		zigbees[i] = string.format('{"id":"%s","id_v1":"/lights/%d","owner":{"rid":"%s","rtype":"device"},'
			.. '"status":"connected","mac_address":"00:17:88:01:0b:12:35:%02x-0b",'
			.. '"channel":{"value":"channel_25","status":"set"},"type":"zigbee_connectivity"}',
			hall_zigbee(i), 100 + i, hall_device(i), i)
		children[i] = string.format('{"rid":"%s","rtype":"device"}', hall_device(i))
	end
	local room = '{"id":"' .. HALL_RID .. '","id_v1":"/groups/5","children":[' .. table.concat(children, ",")
		.. '],"services":[{"rid":"' .. HALL_GROUPED .. '","rtype":"grouped_light"}],'
		.. '"metadata":{"name":"Hall","archetype":"hallway"},"type":"room"}'
	return lights, devices, zigbees, { room }
end

-- A fixture catalogue with more items before its closing "]}".
local function with_items(text, items)
	return (text:gsub("%]%s*}%s*$", function() return "," .. table.concat(items, ",") .. "]}" end))
end

local BODIES
do
	local lights, devices, zigbees, rooms = hall_items()
	BODIES = { light = with_items(F.light, lights), device = with_items(F.device, devices),
		zigbee_connectivity = with_items(F.zigbee_connectivity, zigbees), room = with_items(F.room, rooms),
		zone = F.zone, bridge_home = F.bridge_home, scene = EMPTY, smart_scene = EMPTY,
		grouped_light = F.grouped_light }
end

describe("load groups on the bridge driver (#435)", function()
	local bridge, bc4, ids, lines

	-- Answer every resource GET until none is left (each starts from the
	-- previous one's OnDone), as roundtrip_spec does.
	local function answer_resource_gets()
		local answered, progress = 0, true
		while progress do
			progress = false
			for _, t in ipairs(bc4.transfers) do
				local kind = t.url:match("/clip/v2/resource/([%w_]+)$")
				if kind and BODIES[kind] and not t.answered then
					t.answered = true
					fake.as(bridge, function() t:respond(200, BODIES[kind]) end)
					answered = answered + 1
					progress = true
				end
			end
		end
		return answered
	end

	-- Paired, read and imported. `early` runs before the bridge's late init,
	-- for what the light devices send before it.
	local function start(early)
		bridge = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
			["Bridge IP Address"] = "192.0.2.10" })
		bc4 = bridge.C4
		fake.add_room(GARAGE_ROOM, "Garage")
		fake.add_room(HALL_ROOM, "Hall")
		bc4.persist.hue_app_key = "abc123"
		bc4.persist.hue_bridge_id = "001788fffe123abc"
		if early then early() end
		bridge.OnDriverLateInit("DIT_STARTUP")
		-- The identity (no key), the self-check, the stream, the first resync.
		assert.equal("https://192.0.2.10/api/0/config", bc4.last_transfer().url)
		bc4.last_transfer():respond(200, '{"bridgeid":"001788FFFE123ABC"}')
		bc4.last_transfer():respond(200, '{"data":[{"bridge_id":"001788fffe123abc"}]}')
		bc4.last_transfer():respond_headers(200, {})
		bc4.advance(2500)
		answer_resource_gets()
		bridge.ExecuteCommand("LUA_ACTION", { ACTION = "Import All New" })
		answer_resource_gets()
		ids = {}
		for _, added in ipairs(bc4.added) do
			ids[added.name] = added.id
		end
		-- Name order (Kitchen Strip has no Hue room and stays out); `early`
		-- relies on these ids.
		assert.equal(3 + HALL_LAMPS, #bc4.added)
		assert.same({ 2001, 2002, 2012, 2013, 2014 }, { ids["Garage White"], ids[hall_name(1)],
			ids[hall_name(HALL_LAMPS)], ids["Hallway Ambiance"], ids["Living Room Lamp"] })
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
	end

	-- What a light device sends after its hello (§6.3).
	local function member(name, rid, groups, kind)
		bridge.ExecuteCommand("HUE_LOAD_GROUPS", { device_id = tostring(ids[name]), rid = rid, kind = kind,
			groups = groups })
	end

	-- A group command's HUE_SET as the device sends it (strings, as Director hands them over).
	local function group_set(rid, brightness, group)
		bridge.ExecuteCommand("HUE_SET", { rid = rid, on = "true", brightness = tostring(brightness), rate = "0",
			group = group })
	end

	-- The command PUTs to lights and grouped_lights since `mark` (a transfer
	-- index): { kind, rid, body, t }. Name PUTs are left out.
	local function puts_since(mark)
		local out = {}
		for i = mark + 1, #bc4.transfers do
			local t = bc4.transfers[i]
			local kind = t.method == "PUT" and ((t.url:find(LIGHT_URL, 1, true) == 1 and "light")
				or (t.url:find(GROUPED_URL, 1, true) == 1 and "grouped_light")) or nil
			local body = kind and json.decode(t.data) or nil
			if body and body.metadata == nil then
				out[#out + 1] = { kind = kind, rid = t.url:match("([^/]+)$"), body = body, t = t }
			end
		end
		return out
	end

	local function rids_of(puts)
		local out = {}
		for _, put in ipairs(puts) do
			out[#out + 1] = put.kind .. " " .. put.rid
		end
		return out
	end

	local function answer(puts)
		for _, put in ipairs(puts) do
			if not put.t.answered then
				put.t.answered = true
				put.t:respond(200, '{"data":[],"errors":[]}')
			end
		end
	end

	local function logged(text)
		for _, line in ipairs(lines or {}) do
			if line:find(text, 1, true) then
				return line
			end
		end
		return nil
	end

	local saved_sink

	before_each(function()
		saved_sink = log.sink
		log.sink = function() end
	end)

	after_each(function()
		log.set_debug(false) -- the default: warnings and errors
		log.sink = saved_sink
	end)

	it("sends the lamps of a whole Hue room as one grouped_light PUT, as soon as every member has sent", function()
		start()
		member("Hallway Ambiance", F.rids.hallway, "4001:0")
		member("Living Room Lamp", F.rids.living, "4001:0,4002:1")
		local mark = #bc4.transfers
		group_set(F.rids.hallway, 40, "4001")
		group_set(F.rids.living, 40, "4001")
		-- Closed at the second arrival (both members known), then the group
		-- queue's 80 ms debounce: no BATCH_MS wait.
		bc4.advance(100)
		local puts = puts_since(mark)
		assert.same({ "grouped_light " .. F.grouped_light_rids.living_room }, rids_of(puts))
		assert.is_true(puts[1].body.on.on)
		assert.equal(40, puts[1].body.dimming.brightness)
		bc4.advance(1000)
		assert.equal(1, #puts_since(mark), "no lamp is sent on its own as well")
		assert.truthy(logged("HUE_SET " .. F.rids.hallway:sub(1, 8) .. ": on=true brightness=40")
			:find(" group 4001$"), "the HUE_SET line names the group")
		assert.truthy(logged("load group 4001: 2 lights in 0 ms: Living Room (room) as 1 request"))
	end)

	it("sends lamps that make up no whole Hue room one by one, in arrival order", function()
		start()
		-- Hallway Ambiance and Garage White: the Living Room lacks the Living
		-- Room Lamp, the Garage has one light only, Downstairs lacks the lamp too.
		member("Hallway Ambiance", F.rids.hallway, "4002:0")
		member("Garage White", F.rids.garage, "4002:0")
		local mark = #bc4.transfers
		group_set(F.rids.hallway, 60, "4002")
		group_set(F.rids.garage, 60, "4002")
		bc4.advance(100)
		local puts = puts_since(mark)
		assert.same({ "light " .. F.rids.hallway, "light " .. F.rids.garage }, rids_of(puts))
		assert.equal(60, puts[1].body.dimming.brightness)
		assert.equal(60, puts[2].body.dimming.brightness)
		bc4.advance(1000)
		assert.equal(2, #puts_since(mark))
		assert.truthy(logged("load group 4002: 2 lights in 0 ms: 2 lights alone"))
	end)

	it("folds a zone light member's own lamps into its one grouped_light request", function()
		start()
		bridge.ExecuteCommand("LUA_ACTION", { ACTION = "Add From Hue", What = "group:" .. F.group_rids.downstairs,
			Room = tostring(GARAGE_ROOM) })
		local zone_id = bc4.added[#bc4.added].id
		assert.equal("Downstairs", bc4.added[#bc4.added].name)
		ids.Downstairs = zone_id
		member("Downstairs", F.group_rids.downstairs, "4005:0", "group")
		member("Garage White", F.rids.garage, "4005:0")
		member("Living Room Lamp", F.rids.living, "4005:0")
		local mark = #bc4.transfers
		group_set(F.rids.garage, 30, "4005")
		group_set(F.group_rids.downstairs, 30, "4005")
		group_set(F.rids.living, 30, "4005")
		bc4.advance(100)
		local puts = puts_since(mark)
		assert.same({ "grouped_light " .. F.grouped_light_rids.downstairs }, rids_of(puts))
		assert.equal(30, puts[1].body.dimming.brightness)
		bc4.advance(1000)
		assert.equal(1, #puts_since(mark))
		assert.truthy(logged("load group 4005: 3 lights in 0 ms: Downstairs (zone) zone light as 1 request "
			.. "(2 lights folded in)"))
	end)

	it("paces a load group's hold past the tenth lamp, its stops in the order of its starts", function()
		start()
		for i = 1, HALL_LAMPS do
			member(hall_name(i), hall_rid(i), "4003:0")
		end
		-- Empty the light bucket first: ten slider moves of the lamps' own
		-- (untagged, so not urgent), sent and answered.
		local mark = #bc4.transfers
		for i = 1, 10 do
			bridge.ExecuteCommand("HUE_SET", { rid = hall_rid(i), brightness = "20" })
		end
		bc4.advance(80)
		local drained = puts_since(mark)
		assert.equal(10, #drained)
		answer(drained)

		-- The hold starts: the first ten lamps are urgent and leave at the
		-- debounce, the eleventh waits for a token.
		mark = #bc4.transfers
		for i = 1, HALL_LAMPS do
			bridge.ExecuteCommand("HUE_DIM", { rid = hall_rid(i), direction = "up", duration = "5000", group = "4003" })
		end
		bc4.advance(80)
		local starts = puts_since(mark)
		assert.equal(10, #starts)
		for _, put in ipairs(starts) do
			assert.equal("up", put.body.dimming_delta.action)
			assert.are_not.equal(hall_rid(HALL_LAMPS), put.rid)
		end
		bc4.advance(100)
		starts = puts_since(mark)
		assert.equal(HALL_LAMPS, #starts)
		assert.equal(hall_rid(HALL_LAMPS), starts[HALL_LAMPS].rid, "the eleventh after a token")
		answer(starts)
		assert.truthy(logged("load group 4003: 11 lights in 0 ms: 11 lights dim up one by one, 1 paced"))

		-- The bucket refills while the button is held; empty it again so the
		-- stops show their pacing too.
		bc4.advance(1000)
		mark = #bc4.transfers
		for i = 1, 10 do
			bridge.ExecuteCommand("HUE_SET", { rid = hall_rid(i), brightness = "30" })
		end
		bc4.advance(80)
		drained = puts_since(mark)
		assert.equal(10, #drained)
		answer(drained)

		-- The stops arrive in the reverse order and still go out in the
		-- starts' order (D9): the eleventh lamp of the start waits again, so
		-- every lamp ramps for about as long as the button was held.
		mark = #bc4.transfers
		for i = HALL_LAMPS, 1, -1 do
			bridge.ExecuteCommand("HUE_DIM", { rid = hall_rid(i), direction = "stop", level = "60", group = "4003" })
		end
		bc4.advance(80)
		local stops = puts_since(mark)
		assert.equal(10, #stops)
		for _, put in ipairs(stops) do
			assert.equal("stop", put.body.dimming_delta.action)
			assert.are_not.equal(hall_rid(HALL_LAMPS), put.rid)
		end
		bc4.advance(100)
		stops = puts_since(mark)
		assert.equal(HALL_LAMPS, #stops)
		assert.equal(hall_rid(HALL_LAMPS), stops[HALL_LAMPS].rid)
		assert.truthy(logged("load group 4003: 11 lights in 0 ms: 11 lights stop one by one, 1 paced"))
	end)

	it("sends a member's batched request alone, ahead of a command of its own, and never after it", function()
		start()
		member("Hallway Ambiance", F.rids.hallway, "4001:0")
		member("Living Room Lamp", F.rids.living, "4001:0")
		local mark = #bc4.transfers
		group_set(F.rids.hallway, 40, "4001") -- the batch waits for the Living Room Lamp
		-- The lamp's own keypad: untagged, so its batched 40 % goes now and the
		-- 70 % follows it into the queue (latest wins).
		bridge.ExecuteCommand("HUE_SET", { rid = F.rids.hallway, on = "true", brightness = "70" })
		group_set(F.rids.living, 40, "4001") -- every member heard from: the batch closes
		bc4.advance(100)
		local puts = puts_since(mark)
		assert.same({ "light " .. F.rids.hallway, "light " .. F.rids.living }, rids_of(puts))
		assert.equal(70, puts[1].body.dimming.brightness)
		assert.equal(40, puts[2].body.dimming.brightness)
		answer(puts)
		bc4.advance(1000)
		assert.equal(2, #puts_since(mark), "the group's 40 % never lands after the lamp's own 70 %")
	end)

	it("forgets a deleted member: its unsent request goes, and the batch no longer waits for it", function()
		start()
		member("Hallway Ambiance", F.rids.hallway, "4001:0")
		member("Living Room Lamp", F.rids.living, "4001:0")
		local mark = #bc4.transfers
		group_set(F.rids.living, 40, "4001") -- the batch waits for the Hallway Ambiance
		bridge.ExecuteCommand("HUE_GOODBYE", { rid = F.rids.living, device_id = tostring(ids["Living Room Lamp"]) })
		group_set(F.rids.hallway, 40, "4001") -- the one member left: the batch closes at once
		bc4.advance(100)
		assert.same({ "light " .. F.rids.hallway }, rids_of(puts_since(mark)),
			"no Living Room request, and no whole-room request moving the deleted lamp")
		bc4.advance(1000)
		assert.equal(1, #puts_since(mark))
	end)

	it("keeps memberships sent before its late init; one naming no group is dropped quietly", function()
		local early_lines = {}
		start(function()
			log.sink = function(line) early_lines[#early_lines + 1] = line end
			log.set_debug(true)
			bridge.ExecuteCommand("HUE_LOAD_GROUPS", { device_id = "2013", rid = F.rids.hallway, groups = "4001:0" })
			bridge.ExecuteCommand("HUE_LOAD_GROUPS", { device_id = "2014", rid = F.rids.living, groups = "4001:1" })
			bridge.ExecuteCommand("HUE_LOAD_GROUPS", { device_id = "2001", rid = F.rids.garage, groups = "none" })
			log.set_debug(false)
			log.sink = function() end
		end)
		local early = table.concat(early_lines, "\n")
		assert.equal(2, select(2, early:gsub("HUE_LOAD_GROUPS before late init: queued", "")), early)
		assert.is_nil(early:find("HUE_LOAD_GROUPS before late init: dropped", 1, true), early)
		local mark = #bc4.transfers
		group_set(F.rids.hallway, 40, "4001")
		group_set(F.rids.living, 40, "4001")
		-- Without the replayed memberships the batch would wait BATCH_MS.
		bc4.advance(100)
		assert.same({ "grouped_light " .. F.grouped_light_rids.living_room }, rids_of(puts_since(mark)))
	end)
end)
