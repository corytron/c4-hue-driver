-- End to end on the two-driver harness: the bridge's first resync maps the
-- Hue rooms to the Control4 rooms by name, Import All New Lights creates the
-- fixture lights in their mapped rooms, one of them is a loaded Hue Light
-- driver, a slider move from the proxy becomes one coalesced PUT whose stream
-- event closes the loop, and deleting the light in Composer leaves a
-- tombstone that Add Light clears.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local json = require("dkjson")
local F = require("fixtures.hue_resources")

local CHECK_URL = "https://192.00.02.10/clip/v2/resource/bridge"
local STREAM_URL = "https://192.000.002.10/eventstream/clip/v2"
local GARAGE_ROOM, LIVING_ROOM = 8, 7

-- Import All New Lights creates the lights with a mapped Hue room in name
-- order: Garage White (2001), Hallway Ambiance (2002), Living Room Lamp (2003).
local LIVING_ID = 2003

-- Fire the env's active timers whose delay is at most max_delay ms, with the
-- env's globals in place (the stream's watchdog stays armed).
local function fire_fast_timers(env, max_delay)
	return fake.as(env, function()
		local n = 0
		for _, t in ipairs(env.C4.active_timers()) do
			if t.delay <= max_delay then
				if not t.repeating then t.active = false end
				t.callback(t, 0)
				n = n + 1
			end
		end
		return n
	end)
end

-- The registry fetches light, device, zigbee_connectivity, room, zone and
-- bridge_home one after the other (each GET starts from the previous one's
-- OnDone), so keep answering until no unanswered resource GET is left. After
-- a connect the scenes (scene, smart_scene, grouped_light) and the zone
-- lights (grouped_light) follow the lights; they get empty catalogues here,
-- since this is the lights' loop (scene_roundtrip_spec and
-- zone_light_roundtrip_spec have theirs).
local EMPTY = '{"errors":[],"data":[]}'
local function answer_resource_gets(bridge, from_index)
	local c4 = bridge.C4
	local bodies = { light = F.light, device = F.device, zigbee_connectivity = F.zigbee_connectivity,
		room = F.room, zone = F.zone, bridge_home = F.bridge_home,
		scene = EMPTY, smart_scene = EMPTY, grouped_light = EMPTY }
	local answered, progress = 0, true
	while progress do
		progress = false
		for i = from_index, #c4.transfers do
			local t = c4.transfers[i]
			local kind = t.url:match("/clip/v2/resource/([%w_]+)$")
			if kind and bodies[kind] and not t.answered then
				t.answered = true
				fake.as(bridge, function() t:respond(200, bodies[kind]) end)
				answered = answered + 1
				progress = true
			end
		end
	end
	return answered
end

local function proxy_calls(light, command)
	local out = {}
	for _, args in ipairs(light.C4.calls_to("SendToProxy")) do
		if args[2] == command then out[#out + 1] = args[3] end
	end
	return out
end

local function messages_to(c4, id)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.id == id then out[#out + 1] = m.command end
	end
	return out
end

describe("round trip: map, import, state, command, event, delete, re-add", function()
	local bridge, light, living

	before_each(function()
		log.sink = function() end
		local data = json.decode(F.light).data
		for _, item in ipairs(data) do
			if item.id == F.rids.living then living = item end
		end
		assert(living, "living room lamp fixture")

		-- The light first, so the bridge's globals are the ones left in place;
		-- the project (a Garage next to the default Living Room) after both.
		light = fake.load_driver("hue_light", {}, { device_id = LIVING_ID })
		bridge = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
			["Bridge IP Address"] = "192.0.2.10" })
		fake.add_room(GARAGE_ROOM, "Garage")
		bridge.C4.persist.hue_app_key = "abc123"
		bridge.C4.persist.hue_bridge_id = "001788fffe25b8f8"
		bridge.OnDriverLateInit("DIT_STARTUP")
	end)

	it("runs the whole loop", function()
		local bc4 = bridge.C4
		assert.equal("0 imported", bridge.Properties["Lights"])
		assert.equal("None yet (Set Room Mapping makes one)", bridge.Properties["Room Mappings"])

		-- Self-check, then the stream connects and the deferred resync runs
		-- against an empty registry: the lights' six GETs, the scenes' three
		-- and the zone lights' one, nothing to send, and the one-time Map
		-- Rooms By Name pairs the Hue rooms with the Control4 rooms. The rows
		-- are refreshed once, after the last of the three resyncs.
		-- The bridge's identity first (no key), then the self-check.
		assert.equal("https://192.0.2.10/api/0/config", bc4.last_transfer().url)
		bc4.last_transfer():respond(200, '{"bridgeid":"001788FFFE25B8F8"}')
		assert.equal(CHECK_URL, bc4.last_transfer().url)
		bc4.last_transfer():respond(200, '{"data":[{"bridge_id":"001788fffe25b8f8"}]}')
		local stream_t = bc4.last_transfer()
		assert.equal(STREAM_URL, stream_t.url)
		stream_t:respond_headers(200, {})
		-- The on_connected deferral, then the background resync after its 2 s
		-- debounce (bridge/housekeeping.lua, contract §3.1).
		bc4.advance(2500)
		-- 6 for the lights, scene + smart_scene + grouped_light for the scenes;
		-- the zone lights take the scenes' grouped_light items instead of a GET.
		assert.equal(9, answer_resource_gets(bridge, 1))
		assert.equal(0, #bc4.sent, "nothing registered yet")
		-- List rows carry "‚" for "," (Composer splits a list at commas).
		assert.equal("4 lights on bridge‚ 0 imported‚ 4 new", bridge.Properties["Lights"])
		-- Room Mappings is a drop-down: the row shows the summary, the list
		-- one mapping per line, and a pick in Composer snaps back.
		local summary = "4 Hue rooms and zones; 2 unmapped (open the list to read)"
		assert.equal(summary, bridge.Properties["Room Mappings"])
		assert.equal(summary .. ",Garage → Garage (by name),Living Room → Living Room (by name),Attic (zone) → (unmapped),"
			.. "Downstairs (zone) → (unmapped)", bc4.property_lists["Room Mappings"])
		bridge.Properties["Room Mappings"] = "Garage → Garage"
		bridge.OnPropertyChanged("Room Mappings")
		assert.equal(summary, bridge.Properties["Room Mappings"])
		-- (read-only lists: a pick leaves no Last Action note)
		assert.equal("done", bc4.persist.hue_rooms_automapped)
		assert.truthy(fake.attention(bridge):find("^4 new lights on the bridge: "))

		-- Import All New Lights: six GETs, three AddDevice calls in name order
		-- into the mapped rooms, each bound and told its configuration and
		-- state; Kitchen Strip (no Hue room) is skipped and listed.
		bridge.ExecuteCommand("LUA_ACTION", { ACTION = "Import All New Lights" })
		assert.equal(6, answer_resource_gets(bridge, 1))
		assert.equal(3, #bc4.added)
		assert.equal("Garage White", bc4.added[1].name)
		assert.equal(GARAGE_ROOM, bc4.added[1].room)
		assert.equal("Living Room Lamp", bc4.added[3].name)
		assert.equal(LIVING_ROOM, bc4.added[3].room)
		assert.equal(LIVING_ID, bc4.added[3].id)
		assert.equal(3, #bc4.bindings)
		assert.equal("4 lights on bridge‚ 3 imported‚ 1 new", bridge.Properties["Lights"])
		-- A long Last Action is word-wrapped onto the continuation rows,
		-- which are shown only while used; fake.last_action joins them.
		local added = "Added 3 new lights: Garage White #4 to Garage (device 2001), Hallway Ambiance #3 to Living Room "
			.. "(device 2002), Living Room Lamp #1 to Living Room (device 2003)"
		local skipped = "skipped 1 with no mapped room (Set Room Mapping or Add From Hue): Kitchen Strip #2 (no Hue room)"
		assert.equal(added .. "; " .. skipped, fake.last_action(bridge))
		assert.is_true(#bridge.Properties["Last Action"] <= 72, "the row itself fits the column")
		fire_fast_timers(bridge, 400) -- the rows' visibility batch
		assert.equal(0, bc4.property_attribs["Last Action (2)"], "a continuation row shown")
		assert.equal(1, bc4.property_attribs["Last Action (6)"], "an unused row hidden")
		assert.equal("1 new light on the bridge: Kitchen Strip #2 (Import All New or Add From Hue)",
			fake.attention(bridge))
		assert.same({ "HUE_CONFIGURE", "HUE_STATE" }, messages_to(bc4, LIVING_ID))
		assert.equal(LIVING_ROOM, fake.project.devices[LIVING_ID].room_id)

		-- A rename in Composer reaches the bridge as the OnItemNameChanged
		-- system event and Attention follows at once (it stayed stale until the
		-- next action on hardware, 2026-10-22). The fake's AddDevice reports no
		-- proxy id, so both project records are renamed here; Adopt Hue Names
		-- itself is covered in lights_spec.
		local lamp_records = { fake.project.devices[LIVING_ID] }
		for _, rec in pairs(fake.project.devices) do
			if rec.protocol_id == LIVING_ID then lamp_records[#lamp_records + 1] = rec end
		end
		for _, rec in ipairs(lamp_records) do rec.name = "Lamp" end
		bridge.OnSystemEvent('<c4soap name="OnItemNameChanged"><param name="iditem">2003</param></c4soap>')
		-- Since 1.2 the rename goes to Hue (names N1, #334): the lamp's device
		-- name and its light's own name, paced, never listed as a difference.
		assert.is_nil(fake.attention(bridge):find("Lamp is Living Room Lamp in Hue", 1, true),
			fake.attention(bridge))
		bc4.advance(3000)
		local puts = {}
		for _, t in ipairs(bc4.transfers) do
			if t.method == "PUT" and tostring(t.data):find('"name":"Lamp"', 1, true) then
				puts[#puts + 1] = t.url:match("/clip/v2/resource/(%w+)/")
				if not t.answered then
					t.answered = true
					t:respond(200, '{"errors":[],"data":[]}')
					bc4.advance(1100)
				end
			end
		end
		assert.truthy(#puts >= 1, "the Composer name went to Hue")
		assert.equal("device", puts[1], "the lamp's device name first")

		-- Now the Living Room Lamp is a real driver bound to this bridge.
		fake.pair(bridge, light, { light_id = LIVING_ID, bind = false })
		assert.equal(15, light.C4:GetBoundProviderDevice(LIVING_ID, 1))
		fake.as(light, light.OnDriverLateInit, "DIT_STARTUP")
		fake.pump()

		local caps = proxy_calls(light, "DYNAMIC_CAPABILITIES_CHANGED")
		assert.is_true(#caps >= 1)
		assert.equal("true", tostring(caps[1].supports_color))
		assert.equal("true", tostring(caps[1].supports_color_correlated_temperature))
		assert.equal("Living Room Lamp", light.Properties["Hue Name"])
		assert.equal("#1 (0b216218…)", light.Properties["Hue Light ID"])
		assert.equal("Living Room", light.Properties["Hue Room"])
		assert.equal("Living Room Lamp (Hue color lamp)", light.Properties["Status"])
		local br = proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED")
		assert.is_true(#br >= 1)
		-- The fixture's 73.52 reaches the proxy as a whole percent.
		assert.equal(living.on.on and math.floor(living.dimming.brightness + 0.5) or 0, br[#br].LIGHT_BRIGHTNESS_CURRENT)
		local col = proxy_calls(light, "LIGHT_COLOR_CHANGED")
		assert.is_true(#col >= 1)
		assert.equal(1, col[#col].LIGHT_COLOR_CURRENT_COLOR_MODE, "mirek_valid -> CCT mode")

		-- A slider move and a colour pick arrive back to back from the proxy.
		light.C4.calls = {}
		fake.as(light, light.ReceivedFromProxy, 5001, "SET_BRIGHTNESS_TARGET",
			{ LIGHT_BRIGHTNESS_TARGET = "50", RATE = "400" })
		fake.as(light, light.ReceivedFromProxy, 5001, "SET_COLOR_TARGET",
			{ LIGHT_COLOR_TARGET_X = "0.3", LIGHT_COLOR_TARGET_Y = "0.3",
			  LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "400" })
		assert.equal(1, #proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGING"))
		assert.equal(1, #proxy_calls(light, "LIGHT_COLOR_CHANGING"))
		assert.equal(2, fake.pump(), "two HUE_SET messages reached the bridge")

		-- One coalesced PUT after the debounce.
		local before = #bc4.transfers
		assert.is_true(fire_fast_timers(bridge, 80) >= 1, "debounce timer")
		assert.equal(before + 1, #bc4.transfers, "exactly one PUT for both commands")
		local put = bc4.last_transfer()
		assert.equal("PUT", put.method)
		assert.equal("https://192.0.2.10/clip/v2/resource/light/" .. F.rids.living, put.url)
		local body = json.decode(put.data)
		assert.is_true(body.on.on)
		assert.equal(50, body.dimming.brightness)
		assert.equal(0.3, body.color.xy.x)
		assert.is_nil(body.color_temperature, "xy beats mirek")
		assert.equal(400, body.dynamics.duration)
		fake.as(bridge, function()
			put:respond(200, '{"data":[{"rid":"' .. F.rids.living .. '","rtype":"light"}],"errors":[]}')
		end)

		-- The bridge's event for that change fans out and closes the loop:
		-- CHANGED notifies, and the light's fallback timers are cancelled.
		local event = json.encode({ {
			creationtime = "2026-10-21T18:10:00Z", id = "evt-1", type = "update",
			-- As the bridge reports it: a move to xy also marks the CCT invalid.
			data = { { id = F.rids.living, type = "light", on = { on = true },
				dimming = { brightness = 50 }, color = { xy = { x = 0.3, y = 0.3 } },
				color_temperature = { mirek_valid = false } } },
		} })
		fake.as(bridge, function() stream_t:chunk("id: 10:0\ndata: " .. event .. "\n\n") end)
		assert.equal(1, fake.pump(), "one HUE_STATE to the living room lamp")
		br = proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED")
		assert.equal(50, br[#br].LIGHT_BRIGHTNESS_CURRENT)
		col = proxy_calls(light, "LIGHT_COLOR_CHANGED")
		assert.equal(0, col[#col].LIGHT_COLOR_CURRENT_COLOR_MODE)
		for _, t in ipairs(light.C4.active_timers()) do
			assert.are_not.equal(1400, t.delay, "fallback timer still armed")
		end

		-- A Hue room event moves the lamp's device to the Garage (the fixture
		-- moves Hallway Ambiance's; swap the device rid, plain text since rids
		-- hold "-"): the light hears its new room, nothing in the project moves.
		local moved = (F.events.room_move:gsub((F.device_rids.hallway:gsub("%W", "%%%0")), F.device_rids.living))
		fake.as(bridge, function() stream_t:chunk("id: 11:0\ndata: " .. moved .. "\n\n") end)
		assert.equal(1, fake.pump(), "one HUE_CONFIGURE to the living room lamp")
		assert.equal("Garage", light.Properties["Hue Room"])
		assert.equal(LIVING_ROOM, fake.project.devices[LIVING_ID].room_id, "the Control4 room is the owner's")
		-- (The swapped event also left Hallway Ambiance's device in no room, so
		-- two lights have a mapped Hue room to audit.)
		bridge.ExecuteCommand("LUA_ACTION", { ACTION = "Room Audit" })
		assert.equal("1 of 2 are not in the room their Hue room maps to: Lamp is in Living Room; Hue says "
			.. "Garage → drag it to Garage in Composer if you want it there", fake.last_action(bridge))

		-- #308, as seen on the house: the lamp goes off (Hue keeps its 50 %),
		-- a turn-on at 30 % follows, and the bridge's first event after it
		-- carries the on alone, so the light's cache still says 50 %; the 30
		-- comes in the next event. The proxy goes from 0 to 30, never via 50.
		local function light_event(id, fields)
			fields.id, fields.type = F.rids.living, "light"
			local ev = json.encode({ { creationtime = "2026-10-21T18:12:00Z", id = "evt-" .. id, type = "update",
				data = { fields } } })
			fake.as(bridge, function() stream_t:chunk("id: " .. id .. ":0\ndata: " .. ev .. "\n\n") end)
			return fake.pump()
		end
		assert.equal(1, light_event(12, { on = { on = false } }))
		light.C4.calls = {}
		fake.as(light, light.ReceivedFromProxy, 5001, "SET_BRIGHTNESS_TARGET",
			{ LIGHT_BRIGHTNESS_TARGET = "30", RATE = "1000" })
		assert.equal(1, fake.pump(), "the HUE_SET")
		assert.is_true(fire_fast_timers(bridge, 80) >= 1, "debounce timer")
		put = bc4.last_transfer()
		body = json.decode(put.data)
		assert.same({ true, 30 }, { body.on.on, body.dimming.brightness })
		fake.as(bridge, function()
			put:respond(200, '{"data":[{"rid":"' .. F.rids.living .. '","rtype":"light"}],"errors":[]}')
		end)
		assert.equal(1, light_event(13, { on = { on = true } }), "a HUE_STATE with the on alone")
		assert.same({}, proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED"))
		assert.equal(1, light_event(14, { dimming = { brightness = 30.04 } }))
		assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 30 } }, proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED"))

		-- #233: with Default On Brightness 60, a TOGGLE from off is one PUT
		-- at 60, at once, and the same wait for its level as above.
		fake.as(light, light.ReceivedFromProxy, 5001, "SET_PRESET_LEVEL", { LEVEL = "60" })
		assert.equal(1, light_event(15, { on = { on = false } }))
		light.C4.calls = {}
		fake.as(light, light.ReceivedFromProxy, 5001, "TOGGLE", {})
		assert.equal(1, fake.pump(), "the HUE_SET")
		assert.is_true(fire_fast_timers(bridge, 80) >= 1, "debounce timer")
		put = bc4.last_transfer()
		body = json.decode(put.data)
		assert.same({ true, 60 }, { body.on.on, body.dimming.brightness })
		assert.is_nil(body.dynamics, "at once, as before")
		fake.as(bridge, function()
			put:respond(200, '{"data":[{"rid":"' .. F.rids.living .. '","rtype":"light"}],"errors":[]}')
		end)
		assert.equal(1, light_event(16, { on = { on = true } }))
		assert.same({}, proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED"), "not the 30 % the lamp had")
		assert.equal(1, light_event(17, { dimming = { brightness = 60.24 } }))
		assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 60 } }, proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED"))

		-- Composer deletes the lamp: HUE_GOODBYE tombstones the entry, the
		-- binding goes, and Import All New Lights would skip it; Add Light
		-- re-creates it in its mapped room and clears the tombstone.
		fake.delete_device(LIVING_ID)
		assert.is_nil(bc4.persist.hue_lights[F.rids.living])
		assert.equal("Living Room Lamp", bc4.persist.hue_tombstones[F.rids.living].name)
		assert.equal("4 lights on bridge‚ 2 imported‚ 1 new‚ 1 deleted", bridge.Properties["Lights"])
		local list = fake.custom_select(bridge, "HueLightList")
		assert.equal(2, #list)
		assert.equal(F.rids.kitchen, list[1].value)
		assert.truthy(list[2].text:find("^Living Room Lamp %[Garage%] #1 %(deleted from Composer "))
		assert.equal(F.rids.living, list[2].value)
		assert.equal("(mapped room)", fake.custom_select(bridge, "RoomList")[1].text)

		bridge.ExecuteCommand("LUA_ACTION", { ACTION = "Add Light", Light = F.rids.living, Room = "" })
		assert.equal("Added Living Room Lamp #1 to Garage (device 2004)", fake.last_action(bridge))
		assert.equal(GARAGE_ROOM, bc4.added[4].room, "the mapped room of its new Hue room")
		assert.is_nil(bc4.persist.hue_tombstones[F.rids.living])
		assert.equal(2004, bc4.persist.hue_lights[F.rids.living].device_id)
		assert.equal("4 lights on bridge‚ 3 imported‚ 1 new", bridge.Properties["Lights"])
	end)

	-- 1.2 (#334, docs/simplify-actions-design.md §1.3): what Room Audit listed
	-- on a click is a mark on the device's line of the Lights drop-down; the
	-- rows are refreshed every five minutes, so a move in Composer shows up
	-- within that, and nothing is ever moved back.
	it("marks a light moved to another Control4 room on its Lights line; Room Audit still lists it", function()
		local bc4 = bridge.C4
		bc4.last_transfer():respond(200, '{"bridgeid":"001788FFFE25B8F8"}')
		bc4.last_transfer():respond(200, '{"data":[{"bridge_id":"001788fffe25b8f8"}]}')
		bc4.last_transfer():respond_headers(200, {})
		bc4.advance(2500)
		answer_resource_gets(bridge, 1)
		assert.equal("Mapped 2 Hue rooms and zones by name: Garage → Garage, Living Room → Living Room",
			fake.last_action(bridge), "the first read maps the rooms by name and says so")
		bridge.ExecuteCommand("LUA_ACTION", { ACTION = "Import All New" })
		answer_resource_gets(bridge, 1)
		assert.equal(3, #bc4.added)
		assert.truthy(bc4.property_lists["Lights"]:find(",Garage: Garage White → device 2001,", 1, true))

		fake.move_device(2001, LIVING_ROOM)
		bc4.advance(300000)
		assert.truthy(bc4.property_lists["Lights"]:find(",Garage: Garage White → device 2001 (in Living Room instead of "
			.. "Garage),", 1, true), bc4.property_lists["Lights"])
		assert.equal(LIVING_ROOM, fake.project.devices[2001].room_id, "nothing moved back")
		bridge.ExecuteCommand("LUA_ACTION", { ACTION = "Room Audit" })
		assert.equal("1 of 3 are not in the room their Hue room maps to: Garage White is in Living Room; Hue says Garage → "
			.. "drag it to Garage in Composer if you want it there", fake.last_action(bridge))
	end)
end)
