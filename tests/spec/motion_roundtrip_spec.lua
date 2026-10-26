-- End to end for motion (docs/motion-design.md, issue #268) on the real
-- drivers: the bridge is src/hue_bridge/driver.lua as Director runs it (late
-- init, the identity and TLS checks, the event stream, the resync chain
-- lights → scenes → zone lights → motion), the devices are
-- src/hue_motion/driver.lua, one for a Hue motion sensor and one for a
-- MotionAware area, with SendToDevice and the bindings routed by the fake
-- runtime. What this pins is driver.lua's wiring of bridge/motion.lua and
-- bridge/motion_diag.lua, for which their own specs stand in: the actions
-- with the pickers' values, the HUE_MOTION_* dispatch, the stream fan-out,
-- the rows and Attention, the shared actions and the diagnostics' secrets.
--
-- The bridge is tests/fixtures/hue_motion.lua (docs/motion-hue-research.md
-- §5) on a Hue Bridge Pro: the Hallway sensor (SML003, Hue room Hallway),
-- the Porch sensor (SML002, in no room) and the Kitchen motion area. Its
-- Hue rooms Hallway and Kitchen meet Control4 rooms of the same names, so
-- the first resync's Map Rooms By Name maps them. Addresses, ids and the
-- key are the documented placeholders.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local M = require("fixtures.hue_motion")

local BRIDGE_ID = 15                   -- the bridge driver's own device id in the fake
local SENSOR_ID, AREA_ID = 2001, 2002  -- the ids the fake's AddDevice hands out, in that order
local HALLWAY, KITCHEN = 8, 10         -- Control4 rooms named after the Hue rooms
local BRIDGE_IP = "192.0.2.10"
local BRIDGE_HUE_ID = "001788fffe25b8f8"
-- Short and plain on purpose: no pattern of the diagnostics' scrubber takes
-- it, so only the secrets driver.lua hands to bridge/motion_diag.lua can.
local APP_KEY = "zzzz0000zzzz0000"
-- The controller's clock (C4:GetTime, ms) at the start: 07:10:00Z on 2026-10-26.
local START_MS = 1792998600000
local HOLD_TIME = "Occupancy Hold Time (s)"

-- The GETs of a resync after the stream connects, in order: the lights' six,
-- the scenes' three (the zone lights take the scenes' grouped_light items),
-- then the motion module's eight (docs/motion-design.md §4.2).
local CHAIN = { "light", "device", "zigbee_connectivity", "room", "zone", "bridge_home", "scene", "smart_scene",
	"grouped_light", "motion", "light_level", "temperature", "device_power", "zigbee_connectivity",
	"motion_area_configuration", "convenience_area_motion", "security_area_motion" }

local BODIES = {
	light = M.light, device = M.device, zigbee_connectivity = M.zigbee_connectivity, room = M.room, zone = M.zone,
	bridge_home = M.bridge_home, scene = M.empty, smart_scene = M.empty, grouped_light = M.empty,
	motion = M.motion_body, light_level = M.light_level_body, temperature = M.temperature_body,
	device_power = M.device_power_body, motion_area_configuration = M.motion_area_configuration,
	convenience_area_motion = M.convenience_area_motion, security_area_motion = M.security_area_motion,
}

-- Log Motion Diagnostics' pass: one GET per type of docs/motion-hue-research.md
-- §6.1, in this order (the module may ask for more types between and after them).
local PASS = { "clip", "motion", "light_level", "temperature", "device", "device_power", "zigbee_connectivity",
	"device_software_update", "grouped_motion", "grouped_light_level", "service_group", "motion_area_configuration",
	"convenience_area_motion", "security_area_motion", "motion_area_candidate", "camera_motion", "contact", "tamper",
	"room", "zone", "bridge_home" }

-- Plain-text replacement: ids and JSON contain pattern characters.
local function replace(text, from, to)
	local escaped = from:gsub("%W", "%%%0")
	local out, n = text:gsub(escaped, (to:gsub("%%", "%%%%")))
	assert(n > 0, "fixture text not found: " .. from)
	return out
end

-- One update container holding one motion item of the Hallway sensor,
-- reported by the bridge at `changed`.
local function hallway_motion(motion, changed)
	return string.format('[{"creationtime":"%sZ","data":[{"id":"%s","id_v1":"/sensors/12","motion":{"motion":%s,'
		.. '"motion_report":{"changed":"%s","motion":%s},"motion_valid":true},"owner":{"rid":"%s","rtype":"device"},'
		.. '"type":"motion"}],"id":"e0000000-0000-4000-8000-0000000000a1","type":"update"}]', changed:sub(1, 19),
		M.motion.hallway, tostring(motion), changed, tostring(motion), M.devices.hallway)
end

-- The Hallway sensor deleted in the Hue app: bare identifiers, the device
-- last, as E11 of the fixtures deletes the sensor paired later.
local function hallway_deleted()
	local items = {}
	for _, item in ipairs({ { M.motion.hallway, "motion" }, { M.light_level.hallway, "light_level" },
		{ M.temperature.hallway, "temperature" }, { M.device_power.hallway, "device_power" },
		{ M.zigbee.hallway, "zigbee_connectivity" }, { M.software_update.hallway, "device_software_update" },
		{ M.devices.hallway, "device" } }) do
		items[#items + 1] = string.format('{"id":"%s","type":"%s"}', item[1], item[2])
	end
	return '[{"creationtime":"2026-10-26T08:20:00Z","data":[' .. table.concat(items, ",")
		.. '],"id":"e0000000-0000-4000-8000-0000000000d1","type":"delete"}]'
end

-- The commands a motion device sent its contact proxy (binding 5001), in order.
local function contact(env)
	local out = {}
	for _, args in ipairs(env.C4.calls_to("SendToProxy")) do
		if args[1] == 5001 then out[#out + 1] = args[2] end
	end
	return out
end

-- The active timers of `env` with exactly that delay (ms).
local function timers_with(env, delay)
	local out = {}
	for _, t in ipairs(env.C4.active_timers()) do
		if t.delay == delay then out[#out + 1] = t end
	end
	return out
end

-- Fire them once, with the globals of `env` in place; returns the count.
local function fire(env, delay)
	return fake.as(env, function()
		local due = timers_with(env, delay)
		for _, t in ipairs(due) do
			if t.active then
				t.active = false
				t.callback(t, 0)
			end
		end
		return #due
	end)
end

describe("motion round trip", function()
	local bridge, bc4, sensor, area, stream_t, logged, sse_n

	-- The pending resource GET of the bridge, answered from `bodies`: its
	-- type, or nil when none is pending. Every module waits for one answer
	-- before its next GET, so the pending one is the last transfer. Also an
	-- iterator: `for kind in answer_next, bodies do`.
	local function answer_next(bodies)
		local t = bc4.last_transfer()
		local kind = t and not t.answered and t.method == "GET" and t.url:match("/clip/v2/resource/([%w_]+)$")
		if not kind then
			return nil
		end
		assert(bodies[kind], "no body for GET " .. kind)
		t.answered = true
		fake.as(bridge, function() t:respond(200, bodies[kind]) end)
		return kind
	end

	-- Every GET as it comes; the types answered, in order.
	local function answer_gets(bodies)
		local order = {}
		for kind in answer_next, bodies do
			order[#order + 1] = kind
		end
		return order
	end

	-- One SSE message of `containers` (JSON text) on the event stream, then
	-- the messages it caused delivered; returns their count.
	local function stream(containers)
		sse_n = sse_n + 1
		fake.as(bridge, function()
			stream_t:chunk(string.format("id: %d:0\ndata: %s\n\n", 1792999000 + sse_n, containers))
		end)
		return fake.pump()
	end

	-- A bridge action as Composer sends it; the Last Action it leaves.
	local function action(name, params)
		params = params or {}
		params.ACTION = name
		fake.as(bridge, bridge.ExecuteCommand, "LUA_ACTION", params)
		return fake.last_action(bridge)
	end

	-- The commands the bridge sent device `id` since bc4.sent was last cleared.
	local function messages_to(id)
		local out = {}
		for _, m in ipairs(bc4.sent) do
			if m.id == id then out[#out + 1] = m.command end
		end
		return out
	end

	local function last_sent(id, command)
		for i = #bc4.sent, 1, -1 do
			local m = bc4.sent[i]
			if m.id == id and m.command == command then return m.params end
		end
	end

	-- The entry of a bridge picker (CUSTOM_SELECT list function) whose text starts with `prefix`.
	local function pick(list_fn, prefix)
		for _, entry in ipairs(fake.custom_select(bridge, list_fn)) do
			if entry.text:sub(1, #prefix) == prefix then return entry end
		end
		error("no entry starting with " .. prefix .. " in " .. list_fn)
	end

	-- RoomList's value for a Control4 room.
	local function room_value(id)
		for _, entry in ipairs(fake.custom_select(bridge, "RoomList")) do
			if entry.value == tostring(id) then return entry.value end
		end
		error("room " .. id .. " not in RoomList")
	end

	-- The device of `env` goes live: the fake routes it to the bridge, its
	-- late init (DIT_ADDING, as after AddDevice) says hello, and every queued
	-- message is delivered.
	local function go_live(env, id)
		fake.pair(bridge, env, { light_id = id, bind = false })
		fake.as(env, env.OnDriverLateInit, "DIT_ADDING")
		return fake.pump()
	end

	-- Add Motion Sensor for the Hallway sensor into its mapped room, and the
	-- device live, with the recordings cleared.
	local function add_sensor()
		local text = action("Add Motion Sensor", { Sensor = pick("MotionSensorList", "Hallway sensor").value,
			Room = pick("RoomList", "(mapped room)").value })
		assert.equal("Added Hallway sensor to Hallway (device 2001)", text)
		go_live(sensor, SENSOR_ID)
		sensor.C4.calls = {}
		bc4.sent = {}
	end

	-- The drivers, the devices first so that the bridge's globals stay in
	-- place, then the project's rooms and the bridge's pairing. `identity`:
	-- what the sensor's device persisted in an earlier life.
	local function load(identity)
		logged, sse_n = {}, 0
		log.sink = function(line) logged[#logged + 1] = line end
		sensor = fake.load_driver("hue_motion", {}, { device_id = SENSOR_ID })
		for k, v in pairs(identity or {}) do
			sensor.C4.persist[k] = v
		end
		fake.as(sensor, sensor.OnDriverInit, identity and "DIT_STARTUP" or "DIT_ADDING")
		area = fake.load_driver("hue_motion", {}, { device_id = AREA_ID })
		fake.as(area, area.OnDriverInit, "DIT_ADDING")
		bridge = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = BRIDGE_IP })
		bc4 = bridge.C4
		bc4.now_ms = START_MS
		fake.add_room(HALLWAY, "Hallway")
		fake.add_room(KITCHEN, "Kitchen")
		bc4.persist.hue_app_key = APP_KEY
		bc4.persist.hue_bridge_id = BRIDGE_HUE_ID
	end

	-- The bridge starts: its late init, its identity (asked without the key),
	-- the TLS self-check (the fake fails its decoy at once), the stream's own
	-- address checked, the stream, and the first resync.
	local function start()
		fake.as(bridge, bridge.OnDriverLateInit, "DIT_STARTUP")
		local t = bc4.last_transfer()
		assert.equal("https://" .. BRIDGE_IP .. "/api/0/config", t.url)
		fake.as(bridge, function() t:respond(200, '{"bridgeid":"' .. BRIDGE_HUE_ID:upper() .. '","modelid":"BSB003"}') end)
		t = bc4.last_transfer()
		assert.truthy(t.url:find("/clip/v2/resource/bridge$"), t.url)
		fake.as(bridge, function() t:respond(200, '{"errors":[],"data":[{"bridge_id":"' .. BRIDGE_HUE_ID .. '"}]}') end)
		stream_t = bc4.last_transfer()
		assert.truthy(stream_t.url:find("/eventstream/clip/v2$"), stream_t.url)
		fake.as(bridge, function() stream_t:respond_headers(200, {}) end)
		assert.equal(1, fire(bridge, 1), "the on_connected deferral")
		assert.same(CHAIN, answer_gets(BODIES))
		-- The motion module's bridge-away grace, armed while the stream was
		-- down, ended with the connect.
		assert.same({}, timers_with(bridge, 60000))
	end

	-- common.dispatch and the modules' protect() turn a handler's error into
	-- an [ERROR] line instead of raising it: none may have been logged.
	after_each(function()
		log.set_debug(false)
		for _, line in ipairs(logged) do
			assert.is_nil(line:find("[ERROR]", 1, true), line)
		end
	end)

	describe("with the bridge running", function()
		before_each(function()
			load()
			start()
		end)

		it("adds a sensor and an area with the pickers' values; each hello is answered; motion opens and closes "
			.. "them", function()
			assert.equal("2 sensors and 1 area on the bridge; 0 added", bridge.Properties["Motion Sensors"])

			-- Add Motion Sensor: one AddDevice of hue_motion.c4z into the room
			-- the Hue room Hallway maps to, bound to the bridge's binding 1,
			-- then told its configuration and state.
			local text = action("Add Motion Sensor", { Sensor = pick("MotionSensorList", "Hallway sensor").value,
				Room = pick("RoomList", "(mapped room)").value })
			assert.equal("Added Hallway sensor to Hallway (device 2001)", text)
			assert.same({ { id = SENSOR_ID, driver = "hue_motion.c4z", room = HALLWAY, name = "Hallway sensor" } },
				bc4.added)
			assert.same({ { provider = BRIDGE_ID, provider_binding = 1, consumer = SENSOR_ID, consumer_binding = 1,
				class = "HUE_BRIDGE" } }, bc4.bindings)
			assert.same({ "HUE_MOTION_CONFIGURE", "HUE_MOTION_STATE" }, messages_to(SENSOR_ID))
			assert.same({ rid = M.devices.hallway, kind = "sensor", name = "Hallway sensor",
				model = "Hue motion sensor (SML003)", hue_room = "Hallway", id_v1 = "/sensors/12", gone = "false",
				has_light_level = "true", has_temperature = "true", has_battery = "true" },
				last_sent(SENSOR_ID, "HUE_MOTION_CONFIGURE"))
			assert.equal("2 sensors and 1 area on the bridge; 1 added", bridge.Properties["Motion Sensors"])

			-- The device comes up: its hello (no rid yet) is answered from its
			-- device id with the configuration and the full state.
			bc4.sent = {}
			go_live(sensor, SENSOR_ID)
			assert.same({ { id = BRIDGE_ID, command = "HUE_MOTION_HELLO", params = { rid = "", device_id = "2001" } } },
				sensor.C4.sent)
			assert.same({ "HUE_MOTION_CONFIGURE", "HUE_MOTION_STATE" }, messages_to(SENSOR_ID))
			assert.same({ rid = M.devices.hallway, reason = "hello", online = "true", enabled = "true", lux = "63",
				temperature = "21.37", battery_level = "87", battery_state = "normal", motion = "false",
				motion_changed = M.changed.hallway_motion }, last_sent(SENSOR_ID, "HUE_MOTION_STATE"))
			assert.same({ "STATE_CLOSED" }, contact(sensor), "the first state after the start, as a state")
			assert.equal("Hue motion sensor Hallway sensor in Hallway", sensor.Properties["Status"])
			assert.equal("Motion sensor", sensor.Properties["Kind"])
			assert.equal("Yes", sensor.Properties["Online"])
			assert.equal("63 lux", sensor.Properties["Light Level"])
			assert.equal("87 % (normal)", sensor.Properties["Battery"])
			assert.equal(M.devices.hallway, sensor.C4.persist.hue_rid)

			-- Someone walks into the hallway (E1), and 14 s later the bridge
			-- reports no motion (E2): the device opens, then closes.
			sensor.C4.calls = {}
			bc4.sent = {}
			assert.equal(1, stream(M.events.e1))
			assert.same({ rid = M.devices.hallway, reason = "event", motion = "true", motion_changed = M.changed.e1 },
				last_sent(SENSOR_ID, "HUE_MOTION_STATE"))
			assert.same({ "OPENED" }, contact(sensor))
			assert.equal(1, stream(M.events.e2))
			assert.same({ "OPENED", "CLOSED" }, contact(sensor))

			-- Add Motion Area with the Kitchen room picked: the second device.
			bc4.sent = {}
			text = action("Add Motion Area", { Area = pick("MotionAreaList", "Kitchen motion area").value,
				Room = room_value(KITCHEN) })
			assert.equal("Added Kitchen motion area to Kitchen (device 2002)", text)
			assert.same({ id = AREA_ID, driver = "hue_motion.c4z", room = KITCHEN, name = "Kitchen motion area" },
				bc4.added[2])
			assert.equal(2, #bc4.bindings)
			assert.same({ "HUE_MOTION_CONFIGURE", "HUE_MOTION_STATE" }, messages_to(AREA_ID))
			assert.same({ rid = M.area, kind = "area", name = "Kitchen motion area", model = "MotionAware area",
				hue_room = "Kitchen", gone = "false", has_light_level = "false", has_temperature = "false",
				has_battery = "false" }, last_sent(AREA_ID, "HUE_MOTION_CONFIGURE"))
			bc4.sent = {}
			go_live(area, AREA_ID)
			assert.same({ "HUE_MOTION_CONFIGURE", "HUE_MOTION_STATE" }, messages_to(AREA_ID))
			assert.same({ rid = M.area, reason = "hello", online = "true", enabled = "true", motion = "false",
				motion_changed = M.changed.convenience }, last_sent(AREA_ID, "HUE_MOTION_STATE"))
			assert.same({ "STATE_CLOSED" }, contact(area))
			assert.equal("MotionAware area Kitchen motion area in Kitchen", area.Properties["Status"])
			assert.equal("MotionAware area", area.Properties["Kind"])
			assert.equal(1, area.C4.property_attribs["Battery"], "an area's device hides the sensor rows")

			-- Motion in the kitchen through the area's convenience service
			-- (E8), then none 36 s later: the area's device opens, then closes;
			-- the sensor's hears nothing.
			area.C4.calls = {}
			sensor.C4.calls = {}
			bc4.sent = {}
			assert.equal(1, stream(M.events.e8_motion))
			assert.same({ rid = M.area, reason = "event", motion = "true", motion_changed = M.changed.e8_motion },
				last_sent(AREA_ID, "HUE_MOTION_STATE"))
			assert.same({ "OPENED" }, contact(area))
			assert.equal(1, stream(M.events.e8_clear))
			assert.same({ "OPENED", "CLOSED" }, contact(area))
			assert.same({}, contact(sensor))
			assert.same({}, messages_to(SENSOR_ID))
			assert.equal("2 sensors and 1 area on the bridge; 2 added", bridge.Properties["Motion Sensors"])
		end)

		it("holds Hue's no motion for the device's Occupancy Hold Time before it closes (D10)", function()
			add_sensor()
			sensor.Properties[HOLD_TIME] = "30"
			fake.as(sensor, sensor.OnPropertyChanged, HOLD_TIME)

			stream(hallway_motion(true, "2026-10-26T07:40:00.000Z"))
			assert.same({ "OPENED" }, contact(sensor))
			stream(hallway_motion(false, "2026-10-26T07:40:20.000Z"))
			assert.same({ "OPENED" }, contact(sensor), "Hue's no motion is held")
			assert.truthy(sensor.Properties["Hue Motion"]:find("^No motion"), sensor.Properties["Hue Motion"])
			-- New motion within the hold cancels it; the next no motion holds again.
			stream(hallway_motion(true, "2026-10-26T07:40:25.000Z"))
			assert.equal(0, fire(sensor, 30000), "the hold was cancelled")
			stream(hallway_motion(false, "2026-10-26T07:40:50.000Z"))
			assert.same({ "OPENED" }, contact(sensor), "still open, and never opened twice")
			assert.equal(1, fire(sensor, 30000), "the hold ends")
			assert.same({ "OPENED", "CLOSED" }, contact(sensor))
		end)

		it("closes a device that shows motion once, at once, when its sensor is deleted in Hue (EC §6: a deliberate "
			.. "end)", function()
			add_sensor()
			sensor.Properties[HOLD_TIME] = "600"
			fake.as(sensor, sensor.OnPropertyChanged, HOLD_TIME)
			stream(M.events.e1)
			stream(M.events.e2)
			assert.same({ "OPENED" }, contact(sensor), "Hue's no motion held for 10 minutes")
			assert.equal(1, #timers_with(sensor, 600000))

			bc4.sent = {}
			stream(hallway_deleted())
			local since = "Sensor deleted in Hue since " .. os.date("%m-%d") .. "; re-link or Forget"
			assert.same({ "HUE_MOTION_CONFIGURE", "HUE_MOTION_STATE" }, messages_to(SENSOR_ID))
			assert.equal("true", last_sent(SENSOR_ID, "HUE_MOTION_CONFIGURE").gone)
			assert.same({ rid = M.devices.hallway, reason = "event", online = "false", ended = "deleted", status = since },
				last_sent(SENSOR_ID, "HUE_MOTION_STATE"))
			assert.same({ "OPENED", "CLOSED" }, contact(sensor), "closed at once: a hold never applies to a deliberate end")
			assert.same({}, timers_with(sensor, 600000), "the hold is over")
			assert.equal(since, sensor.Properties["Status"])
			assert.equal("No", sensor.Properties["Online"])
			-- (A list row: Composer splits the drop-down at commas, so "‚" stands for ",".)
			assert.equal("1 sensor and 1 area on the bridge; 1 added‚ 1 missing", bridge.Properties["Motion Sensors"])
			assert.truthy(bridge.Properties["Attention"]:find("1 motion sensor missing from the bridge: Hallway sensor "
				.. "(device 2001, since " .. os.date("%Y-%m-%d") .. ") (Re-link Motion Device or Forget Motion Device)", 1,
				true), bridge.Properties["Attention"])

			-- Once: the device asking again (Refresh From Bridge) hears the
			-- same end, and its proxy hears nothing more.
			bc4.sent = {}
			fake.as(sensor, sensor.ExecuteCommand, "LUA_ACTION", { ACTION = "Refresh From Bridge" })
			fake.pump()
			assert.same({ "HUE_MOTION_CONFIGURE", "HUE_MOTION_STATE" }, messages_to(SENSOR_ID))
			assert.equal("deleted", last_sent(SENSOR_ID, "HUE_MOTION_STATE").ended)
			assert.same({ "OPENED", "CLOSED" }, contact(sensor))
		end)

		it("closes a device that shows motion once when it is unbound in Composer, and tells it its state when bound "
			.. "again", function()
			add_sensor()
			stream(M.events.e1)
			assert.same({ "OPENED" }, contact(sensor))

			-- Unbound: both drivers hear it; the device closes once and says
			-- why, the bridge lists it (EC §6: a deliberate end).
			fake.as(bridge, function() bc4:Unbind(SENSOR_ID, 1) end)
			assert.same({ "OPENED", "CLOSED" }, contact(sensor))
			assert.equal("Not bound to a Hue Bridge", sensor.Properties["Status"])
			assert.equal("No", sensor.Properties["Online"])
			assert.equal("2 sensors and 1 area on the bridge; 1 added‚ 1 unbound", bridge.Properties["Motion Sensors"])
			assert.truthy(bridge.Properties["Attention"]:find("1 unbound motion device: Hallway sensor (device 2001) "
				.. "(bind it to this bridge in Composer, or Forget Motion Device)", 1, true), bridge.Properties["Attention"])
			bc4.sent = {}
			stream(M.events.e2)
			assert.same({}, messages_to(SENSOR_ID), "nothing goes to an unbound device")

			-- Bound again: the bridge tells it its configuration and state at
			-- once, and the state is Hue's latest (no motion, E2).
			fake.as(bridge, function() bc4:Bind(BRIDGE_ID, 1, SENSOR_ID, 1, "HUE_BRIDGE") end)
			assert.same({ "HUE_MOTION_CONFIGURE", "HUE_MOTION_STATE" }, messages_to(SENSOR_ID))
			fake.pump()
			assert.equal("false", last_sent(SENSOR_ID, "HUE_MOTION_STATE").motion)
			assert.same({ "OPENED", "CLOSED" }, contact(sensor), "no motion, as it shows")
			assert.equal("Hue motion sensor Hallway sensor in Hallway", sensor.Properties["Status"])
			assert.equal("2 sensors and 1 area on the bridge; 1 added", bridge.Properties["Motion Sensors"])
		end)

		it("shows the sensors and areas in the Motion Sensors row, and a low battery in Attention", function()
			assert.equal("2 sensors and 1 area on the bridge; 0 added", bridge.Properties["Motion Sensors"])
			assert.equal("2 sensors and 1 area on the bridge; 0 added,Hallway sensor [Hallway] #12,Porch sensor #20,"
				.. "Kitchen motion area (MotionAware) [Kitchen] #ac00", bc4.property_lists["Motion Sensors"])
			local attention = bridge.Properties["Attention"]
			assert.truthy(attention:find("2 new motion sensors on the bridge: Hallway sensor [Hallway] #12, Porch sensor "
				.. "#20 (Add Motion Sensor)", 1, true), attention)
			assert.truthy(attention:find("1 new motion area on the bridge: Kitchen motion area (MotionAware) [Kitchen] "
				.. "#ac00 (Add Motion Area)", 1, true), attention)

			add_sensor()
			assert.equal("2 sensors and 1 area on the bridge; 1 added", bridge.Properties["Motion Sensors"])
			assert.equal("2 sensors and 1 area on the bridge; 1 added,Hallway sensor [Hallway] #12 → device 2001,"
				.. "Porch sensor #20,Kitchen motion area (MotionAware) [Kitchen] #ac00", bc4.property_lists["Motion Sensors"])
			assert.is_nil(bridge.Properties["Attention"]:find("Hallway sensor", 1, true), "no longer new")

			-- Seven weeks later the sensor's battery runs low (E12): the device
			-- shows it and fires Battery Low; the bridge's Attention lists it
			-- once the rows are refreshed (any action refreshes them; the next
			-- test asks for it at once).
			sensor.C4.events_fired = {}
			stream(M.events.e12)
			assert.same({ rid = M.devices.hallway, reason = "event", battery_level = "9", battery_state = "low" },
				last_sent(SENSOR_ID, "HUE_MOTION_STATE"))
			assert.equal("9 % (low)", sensor.Properties["Battery"])
			assert.same({ 3 }, sensor.C4.events_fired, "Battery Low")
			assert.equal("1", sensor.C4.variables["Battery Low"].value)
			action("Accept Names As They Are")
			assert.truthy(bridge.Properties["Attention"]:find("1 motion sensor battery low: Hallway sensor 9 %", 1, true),
				bridge.Properties["Attention"])
		end)

		it("lists a low battery in Attention as soon as its event arrives (D5: listed at once)", function()
			add_sensor()
			stream(M.events.e12)
			assert.truthy(bridge.Properties["Attention"]:find("1 motion sensor battery low: Hallway sensor 9 %", 1, true),
				"Attention reads: " .. bridge.Properties["Attention"])
		end)

		it("puts the Motion Sensors row back to its summary after a pick in Composer, as the other list rows", function()
			local zone_summary = bridge.Properties["Zone Lights"]
			bridge.Properties["Zone Lights"] = "a pick"
			fake.as(bridge, bridge.OnPropertyChanged, "Zone Lights")
			assert.equal(zone_summary, bridge.Properties["Zone Lights"], "the Zone Lights row snaps back")

			local summary = bridge.Properties["Motion Sensors"]
			bridge.Properties["Motion Sensors"] = "Porch sensor #20"
			fake.as(bridge, bridge.OnPropertyChanged, "Motion Sensors")
			assert.equal(summary, bridge.Properties["Motion Sensors"])
		end)

		it("re-links a gone sensor's device to a sensor only (D4); Forget Motion Device lets it go", function()
			add_sensor()
			stream(hallway_deleted())

			-- Re-link's pickers: the gone device, and every sensor and area as the target.
			local device = pick("RelinkMotionDeviceList", "Hallway sensor (motion sensor, device 2001, gone since ")
			assert.equal("2001", device.value)
			local text = action("Re-link Motion Device", { Device = device.value,
				Target = pick("MotionTargetList", "Kitchen motion area").value })
			assert.equal("Not re-linked: device 2001 is a motion sensor; pick a sensor", text)
			assert.equal(SENSOR_ID, bc4.persist.hue_motion[M.devices.hallway].device_id, "nothing changed")

			-- To another sensor it works: the device keeps its id, its binding
			-- and its Composer name, and hears the new sensor.
			bc4.sent = {}
			sensor.C4.calls = {}
			text = action("Re-link Motion Device", { Device = device.value,
				Target = pick("MotionTargetList", "Porch sensor").value })
			assert.equal("Re-linked device 2001 (was Hallway sensor) to Porch sensor #20", text)
			fake.pump()
			assert.equal(M.devices.porch, last_sent(SENSOR_ID, "HUE_MOTION_CONFIGURE").rid)
			assert.equal("Porch sensor", last_sent(SENSOR_ID, "HUE_MOTION_CONFIGURE").name)
			assert.equal(M.devices.porch, sensor.C4.persist.hue_rid)
			assert.equal("Porch sensor", sensor.Properties["Hue Name"])
			assert.equal("Yes", sensor.Properties["Online"])
			assert.same({}, contact(sensor), "it showed no motion, and the porch shows none")
			assert.equal("Hallway sensor", fake.project.devices[SENSOR_ID].name, "the Composer name is the owner's")
			assert.equal(1, #bc4.bindings)

			-- Forget Motion Device: the device is unbound and told; it stays in
			-- the project, and the sensor is listed under Add Motion Sensor again.
			local forget = pick("ForgetMotionDeviceList", "Porch sensor (motion sensor, device 2001)")
			text = action("Forget Motion Device", { Device = forget.value })
			assert.equal("Forgot Porch sensor (device 2001): unbound and left in the project for you to delete; the Hue "
				.. "motion sensor is listed under Add Motion Sensor again", text)
			fake.pump()
			assert.same({}, bc4.bindings)
			assert.is_nil(bc4.persist.hue_motion[M.devices.porch])
			assert.equal("Forgotten by the bridge (was Hue motion sensor Porch sensor)", sensor.Properties["Status"])
			assert.equal("Delete this device in Composer, or bind it again and use Link Devices",
				sensor.Properties["Last Action"])
			assert.equal("No", sensor.Properties["Online"])
			assert.same({}, contact(sensor))
			assert.equal("1 sensor and 1 area on the bridge; 0 added", bridge.Properties["Motion Sensors"])
			assert.equal(M.devices.porch, pick("MotionSensorList", "Porch sensor").value)
			assert.equal("(no motion device is gone or unbound)",
				fake.custom_select(bridge, "RelinkMotionDeviceList")[1].text)
		end)

		it("tells a re-linked device its new sensor's Hue room: none for the Porch sensor", function()
			add_sensor()
			stream(hallway_deleted())
			bc4.sent = {}
			assert.equal("Re-linked device 2001 (was Hallway sensor) to Porch sensor #20",
				action("Re-link Motion Device", { Device = "2001", Target = M.devices.porch }))
			fake.pump()
			assert.is_nil(last_sent(SENSOR_ID, "HUE_MOTION_CONFIGURE").hue_room, "the Porch sensor is in no Hue room")
			assert.equal("", sensor.Properties["Hue Room"])
			assert.equal("Hue motion sensor Porch sensor", sensor.Properties["Status"])
		end)

		it("renames a re-linked device's proxy with Adopt Hue Names: driver.lua finds a motion device's proxy id",
			function()
			add_sensor()
			stream(hallway_deleted())
			action("Re-link Motion Device", { Device = "2001", Target = M.devices.porch })
			assert.truthy(bridge.Properties["Attention"]:find("1 motion device name differs from the Composer names: "
				.. "Hallway sensor is Porch sensor in Hue (Adopt Hue Names or Accept Names As They Are)", 1, true),
				bridge.Properties["Attention"])

			-- The entry has no proxy id (the fake's AddDevice reports none); the
			-- contact proxy is the consumer of the device's binding 5001.
			local text = action("Adopt Hue Names")
			assert.truthy(text:find("Motion: Renamed 1 motion device: Hallway sensor → Porch sensor (device 2001)", 1,
				true), text)
			assert.same({ { id = fake.project.devices[SENSOR_ID].proxy_id, name = "Porch sensor" } }, bc4.renamed)
			assert.is_nil(bridge.Properties["Attention"]:find("differ", 1, true), bridge.Properties["Attention"])
		end)

		it("links a device bound by hand to the Hue sensor of its Composer name with Link Devices", function()
			-- A Hue Motion Sensor the dealer added from Composer's driver
			-- search, named Porch sensor and bound to the bridge: its hello has
			-- no rid, so nothing adopts it.
			fake.pair(bridge, area, { light_id = AREA_ID, bind = false })
			fake.project.devices[AREA_ID].name = "Porch sensor"
			fake.as(area, area.OnDriverLateInit, "DIT_ADDING")
			fake.as(bridge, function() bc4:Bind(BRIDGE_ID, 1, AREA_ID, 1, "HUE_BRIDGE") end)
			assert.equal(1, fake.pump(), "its hello")
			assert.equal("Bound; waiting for the bridge", area.Properties["Status"])
			assert.is_nil((bc4.persist.hue_motion or {})[M.devices.porch])

			bc4.sent = {}
			local text = action("Link Devices")
			assert.truthy(text:find("Motion: Linked 1 motion device: Porch sensor (device 2002) to Porch sensor #20 by "
				.. "name", 1, true), text)
			fake.pump()
			assert.same({ "HUE_MOTION_CONFIGURE", "HUE_MOTION_STATE" }, messages_to(AREA_ID))
			assert.equal(AREA_ID, bc4.persist.hue_motion[M.devices.porch].device_id)
			assert.equal("Hue motion sensor Porch sensor", area.Properties["Status"])
			assert.same({ "STATE_CLOSED" }, contact(area))
		end)

		it("tombstones a device deleted in Composer (HUE_MOTION_GOODBYE); Add Motion Sensor lists it last and adds "
			.. "it again", function()
			add_sensor()
			fake.delete_device(SENSOR_ID)
			assert.is_nil(bc4.persist.hue_motion[M.devices.hallway])
			assert.equal("Hallway sensor", bc4.persist.hue_motion_tombstones[M.devices.hallway].name)
			assert.same({}, bc4.bindings)
			assert.equal("2 sensors and 1 area on the bridge; 0 added‚ 1 deleted", bridge.Properties["Motion Sensors"])

			local list = fake.custom_select(bridge, "MotionSensorList")
			assert.same({ text = "Hallway sensor [Hallway] #12 (deleted from Composer " .. os.date("%Y-%m-%d") .. ")",
				value = M.devices.hallway }, list[#list])
			assert.equal("Added Hallway sensor to Hallway (device 2002)", action("Add Motion Sensor",
				{ Sensor = list[#list].value, Room = "mapped" }))
			assert.is_nil(bc4.persist.hue_motion_tombstones[M.devices.hallway])
			assert.equal(2002, bc4.persist.hue_motion[M.devices.hallway].device_id)
		end)

		it("runs Log Motion Diagnostics 20 s after the click, then captures events, and logs nothing that "
			.. "identifies the house", function()
			-- The bridge's answers for the pass. The Hallway sensor's product
			-- data echoes the application key, the bridge's address and its id,
			-- as a broken or hostile firmware might: the key is caught only by
			-- the secrets driver.lua hands the module, and the id is told apart
			-- from any 12-hex-digit run by its own placeholder.
			local hostile = replace(M.device, '"model_id":"SML003","manufacturer_name":"Signify Netherlands B.V."',
				'"model_id":"SML003","manufacturer_name":"Signify ' .. BRIDGE_HUE_ID .. '"')
			hostile = replace(hostile, '"software_version":"2.85.1","hardware_platform_type":"100b-11b"',
				'"software_version":"' .. APP_KEY .. '","hardware_platform_type":"' .. BRIDGE_IP .. '"')
			local bodies = setmetatable({
				clip = '{"errors":[],"data":[{"id":"c1000000-0000-4000-8000-0000000000c1","type":"clip","resources":['
					.. '"bridge","bridge_home","convenience_area_motion","device","device_power","device_software_update",'
					.. '"grouped_light","grouped_light_level","grouped_motion","light","light_level","motion",'
					.. '"motion_area_candidate","motion_area_configuration","room","scene","security_area_motion",'
					.. '"temperature","zigbee_connectivity","zone"]}]}',
				device = hostile, device_software_update = M.device_software_update, grouped_motion = M.grouped_motion,
				grouped_light_level = M.grouped_light_level, service_group = M.empty,
				motion_area_candidate = M.motion_area_candidate, camera_motion = M.empty, contact = M.empty,
				tamper = M.empty,
			}, { __index = function(_, kind) return BODIES[kind] or M.empty end })

			-- The click answers at once; nothing is fetched for 20 s (time to
			-- open the bridge's Lua tab).
			local first, transfers = #logged + 1, #bc4.transfers
			assert.equal("Motion diagnostics start in 20 seconds: open this bridge's Lua tab now. The pass and 10 "
				.. "minutes of events follow; copy them into the Beta feedback issue.", action("Log Motion Diagnostics"))
			assert.equal(transfers, #bc4.transfers, "nothing fetched before the 20 s are up")

			-- 20 s later the pass: one GET at a time (each answered before the
			-- next starts), the types of the list in their order.
			bc4.now_ms = START_MS + 20000
			assert.equal(1, fire(bridge, 20000))
			local timers = #bc4.timers
			local order = answer_gets(bodies)
			for i = transfers + 1, #bc4.transfers do
				assert.is_true(bc4.transfers[i].answered, "a GET left waiting: " .. bc4.transfers[i].url)
			end
			assert.equal("clip", order[1])
			local at = 1
			for _, kind in ipairs(order) do
				if kind == PASS[at] then at = at + 1 end
			end
			assert.equal(#PASS + 1, at, "the pass reached " .. tostring(PASS[at]) .. " of its list: "
				.. table.concat(order, " "))
			local function line_with(text)
				for i = first, #logged do
					if logged[i]:find(text, 1, true) then return logged[i] end
				end
			end
			local done = line_with("diag: Motion diagnostics: pass done (2 sensors, 1 area")
			assert.truthy(done and done:find("; capturing events for 10 minutes.", 1, true), done)
			assert.truthy(line_with("diag: counts: clip 20 types, motion 2,"))

			-- During the capture the stream's items are logged as they come
			-- (E1: the hallway motion and two grouped motions).
			stream(M.events.e1)
			assert.truthy(line_with(" c#1 update motion a000…"), "the hallway motion item")

			-- After 10 minutes the capture ends, and Last Action says so.
			local capture
			for i = timers + 1, #bc4.timers do
				if bc4.timers[i].delay == 600000 and bc4.timers[i].active then capture = bc4.timers[i] end
			end
			assert.truthy(capture, "the capture's timer")
			bc4.now_ms = START_MS + 20000 + 600000
			fake.as(bridge, function()
				capture.active = false
				capture.callback(capture, 0)
			end)
			assert.equal("Motion diagnostics done: 3 items of events logged. Copy the Lua output into the Beta "
				.. "feedback issue.", fake.last_action(bridge))

			-- Every line the run logged, and both Last Action texts: no key,
			-- address, bridge id, full resource id, MAC or Hue name.
			local lines = {}
			for i = first, #logged do
				if logged[i]:find("diag: ", 1, true) or logged[i]:find("Motion diagnostics", 1, true) then
					lines[#lines + 1] = logged[i]
				end
			end
			assert.is_true(#lines > 40, "the run logged " .. #lines .. " lines")
			local function seen(text)
				for _, line in ipairs(lines) do
					if line:find(text, 1, true) then return true end
				end
				return false
			end
			assert.is_true(seen('software_version="<key>"'), "the key, by driver.lua's secrets")
			assert.is_true(seen('hardware_platform_type="<ip>"'), "the bridge's address")
			assert.is_true(seen('manufacturer_name="Signify <bridge>"'), "the bridge id, by driver.lua's secrets")
			assert.is_true(seen("owner=device:de00…"), "ids are logged as their first 4 characters")
			assert.is_true(seen("metadata.name=name#1"), "names are logged as aliases")
			local forbidden = { APP_KEY, BRIDGE_IP, BRIDGE_HUE_ID, BRIDGE_HUE_ID:upper(), "00:17:88", M.devices.hallway,
				M.motion.hallway, M.area, M.convenience, M.rooms.kitchen, M.names.hallway, M.names.porch, M.names.area,
				"Hallway lamp", "Kitchen 1", "Hallway", "Kitchen" }
			local uuid = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"
			for _, line in ipairs(lines) do
				for _, text in ipairs(forbidden) do
					assert.is_nil(line:find(text, 1, true), "'" .. text .. "' in: " .. line)
				end
				assert.is_nil(line:find(uuid), "a full id in: " .. line)
			end
		end)

		it("resyncs the motion devices last when the stream connects again, after the zone lights, and tells them "
			.. "their state", function()
			add_sensor()

			-- The stream goes down: after the minute's grace the device says its
			-- motion is not current, and its contact stays as it is (EC §6, D3).
			action("Disconnect Event Stream")
			assert.equal(1, fire(bridge, 60000), "the bridge-away grace")
			fake.pump()
			assert.truthy(sensor.Properties["Status"]:find("^Bridge not answering since %d%d:%d%d; motion not current$"),
				sensor.Properties["Status"])
			assert.same({}, contact(sensor))

			-- It connects again: the chain runs lights → scenes → zone lights →
			-- motion; the device hears nothing before the motion resync's last
			-- GET has its answer, then its full state.
			bridge.Properties["Debug Mode"] = "On"
			fake.as(bridge, bridge.OnPropertyChanged, "Debug Mode")
			action("Connect Event Stream")
			stream_t = bc4.last_transfer()
			assert.truthy(stream_t.url:find("/eventstream/clip/v2$"), stream_t.url)
			fake.as(bridge, function() stream_t:respond_headers(200, {}) end)
			bc4.sent = {}
			local first = #logged + 1
			assert.equal(1, fire(bridge, 1), "the on_connected deferral")
			local order = {}
			for kind in answer_next, BODIES do
				order[#order + 1] = kind
				if #order < #CHAIN then
					assert.same({}, messages_to(SENSOR_ID), "a message to the device after GET " .. kind)
				end
			end
			assert.same(CHAIN, order)
			assert.same({ "HUE_MOTION_STATE" }, messages_to(SENSOR_ID))
			assert.same({ rid = M.devices.hallway, reason = "resync", online = "true", enabled = "true", lux = "63",
				temperature = "21.37", battery_level = "87", battery_state = "normal", motion = "false",
				motion_changed = M.changed.hallway_motion }, last_sent(SENSOR_ID, "HUE_MOTION_STATE"))
			assert.equal(1, fake.pump())
			assert.equal("Hue motion sensor Hallway sensor in Hallway", sensor.Properties["Status"], "current again")
			assert.same({}, contact(sensor))
			assert.same({}, timers_with(bridge, 60000), "no bridge-away grace left running")

			-- The order, from the driver's own lines (Debug Mode).
			local function index_of(text)
				for i = first, #logged do
					if logged[i]:find(text, 1, true) then return i end
				end
			end
			local zone_done, motion_get = index_of("zone light resync done"), index_of("/clip/v2/resource/motion")
			local motion_done = index_of("motion resync done: 1 state messages")
			assert.truthy(zone_done and motion_get and motion_done, "the chain's log lines")
			assert.is_true(zone_done < motion_get and motion_get < motion_done)
		end)
	end)

	describe("with a device that starts before the bridge", function()
		it("answers its hello once the bridge has initialised, as a light's and a scene's are", function()
			-- A device that knows its sensor from an earlier life, bound to a
			-- bridge whose registry lacks it (its store lost, say): its hello is
			-- how the bridge adopts it (docs/import-design.md §4).
			load({ hue_rid = M.devices.hallway, hue_kind = "sensor", hue_name = "Hallway sensor" })
			fake.pair(bridge, sensor, { light_id = SENSOR_ID })  -- bound before the start: no OnBindingChanged

			-- Director late-inits the device first: its hello reaches a bridge
			-- that is still initialising.
			fake.as(sensor, sensor.OnDriverLateInit, "DIT_STARTUP")
			assert.equal(1, fake.pump(), "the hello reached the bridge")
			start()
			fake.pump()

			assert.equal(SENSOR_ID, ((bc4.persist.hue_motion or {})[M.devices.hallway] or {}).device_id,
				"adopted from its hello")
			assert.equal("Hue motion sensor Hallway sensor in Hallway", sensor.Properties["Status"])
		end)
	end)
end)
