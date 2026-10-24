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
-- OnDone), so keep answering until no unanswered resource GET is left.
local function answer_resource_gets(bridge, from_index)
	local c4 = bridge.C4
	local bodies = { light = F.light, device = F.device, zigbee_connectivity = F.zigbee_connectivity,
		room = F.room, zone = F.zone, bridge_home = F.bridge_home }
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
		bridge = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		fake.add_room(GARAGE_ROOM, "Garage")
		bridge.C4.persist.hue_app_key = "abc123"
		bridge.C4.persist.hue_bridge_id = "001788fffe25b8f8"
		bridge.OnDriverLateInit("DIT_STARTUP")
	end)

	it("runs the whole loop", function()
		local bc4 = bridge.C4
		assert.equal("0 imported", bridge.Properties["Lights"])
		assert.equal("None; use Map Rooms By Name", bridge.Properties["Room Mappings"])

		-- Self-check, then the stream connects and the deferred resync runs
		-- against an empty registry: six GETs, nothing to send, and the one-time
		-- Map Rooms By Name pairs the Hue rooms with the Control4 rooms.
		assert.equal(CHECK_URL, bc4.last_transfer().url)
		bc4.last_transfer():respond(200, '{"data":[{"bridge_id":"001788fffe25b8f8"}]}')
		local stream_t = bc4.last_transfer()
		assert.equal(STREAM_URL, stream_t.url)
		stream_t:respond_headers(200, {})
		assert.equal(1, fire_fast_timers(bridge, 1), "on_connected deferral")
		assert.equal(6, answer_resource_gets(bridge, 1))
		assert.equal(0, #bc4.sent, "nothing registered yet")
		assert.equal("4 on bridge, 0 imported, 4 new, 0 missing, 0 unbound, 0 deleted", bridge.Properties["Lights"])
		-- Room Mappings is a drop-down: the row shows the summary, the list
		-- one mapping per line, and a pick in Composer snaps back.
		local summary = "4 Hue rooms and zones; 2 unmapped (open the list to read)"
		assert.equal(summary, bridge.Properties["Room Mappings"])
		assert.equal(summary .. ",Garage → Garage,Living Room → Living Room,Attic (zone) → (unmapped),"
			.. "Downstairs (zone) → (unmapped)", bc4.property_lists["Room Mappings"])
		bridge.Properties["Room Mappings"] = "Garage → Garage"
		bridge.OnPropertyChanged("Room Mappings")
		assert.equal(summary, bridge.Properties["Room Mappings"])
		assert.equal("Room Mappings is for reading; the row shows the summary again", bridge.Properties["Last Action"])
		assert.equal("done", bc4.persist.hue_rooms_automapped)
		assert.truthy(bridge.Properties["Attention"]:find("^4 new lights on the bridge: "))

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
		assert.equal("4 on bridge, 3 imported, 1 new, 0 missing, 0 unbound, 0 deleted", bridge.Properties["Lights"])
		assert.equal("Added 3 new lights: Garage White #4 to Garage (device 2001), Hallway Ambiance #3 to Living Room "
			.. "(device 2002), Living Room Lamp #1 to Living Room (device 2003); skipped 1 with no mapped room "
			.. "(Set Room Mapping or Add Light): Kitchen Strip #2 (no Hue room)", bridge.Properties["Last Action"])
		assert.equal("1 new light on the bridge: Kitchen Strip #2 (Add Light or Import All New Lights)",
			bridge.Properties["Attention"])
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
		assert.truthy(bridge.Properties["Attention"]:find("Lamp is Living Room Lamp in Hue", 1, true),
			bridge.Properties["Attention"])
		for _, rec in ipairs(lamp_records) do rec.name = "Living Room Lamp" end
		bridge.OnSystemEvent('<c4soap name="OnItemNameChanged"><param name="iditem">2003</param></c4soap>')
		assert.is_nil(bridge.Properties["Attention"]:find("differ", 1, true), bridge.Properties["Attention"])

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
		assert.equal("1 of 2 are not in the room their Hue room maps to: Living Room Lamp is in Living Room; Hue says "
			.. "Garage → drag it to Garage in Composer if you want it there", bridge.Properties["Last Action"])

		-- Composer deletes the lamp: HUE_GOODBYE tombstones the entry, the
		-- binding goes, and Import All New Lights would skip it; Add Light
		-- re-creates it in its mapped room and clears the tombstone.
		fake.delete_device(LIVING_ID)
		assert.is_nil(bc4.persist.hue_lights[F.rids.living])
		assert.equal("Living Room Lamp", bc4.persist.hue_tombstones[F.rids.living].name)
		assert.equal("4 on bridge, 2 imported, 1 new, 0 missing, 0 unbound, 1 deleted", bridge.Properties["Lights"])
		local list = fake.custom_select(bridge, "HueLightList")
		assert.equal(2, #list)
		assert.equal(F.rids.kitchen, list[1].value)
		assert.truthy(list[2].text:find("^Living Room Lamp %[Garage%] #1 %(deleted from Composer "))
		assert.equal(F.rids.living, list[2].value)
		assert.equal("(mapped room)", fake.custom_select(bridge, "RoomList")[1].text)

		bridge.ExecuteCommand("LUA_ACTION", { ACTION = "Add Light", Light = F.rids.living, Room = "" })
		assert.equal("Added Living Room Lamp #1 to Garage (device 2004)", bridge.Properties["Last Action"])
		assert.equal(GARAGE_ROOM, bc4.added[4].room, "the mapped room of its new Hue room")
		assert.is_nil(bc4.persist.hue_tombstones[F.rids.living])
		assert.equal(2004, bc4.persist.hue_lights[F.rids.living].device_id)
		assert.equal("4 on bridge, 3 imported, 1 new, 0 missing, 0 unbound, 0 deleted", bridge.Properties["Lights"])
	end)
end)
