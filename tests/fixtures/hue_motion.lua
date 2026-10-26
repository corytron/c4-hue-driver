-- luacheck: no max line length (JSON lines)
--
-- Hue motion sensors and a MotionAware area for the motion specs
-- (docs/motion-design.md §5): the fixtures of docs/motion-hue-research.md
-- §5 (HR below) as JSON text, so specs decode them as the driver does. The
-- ids are invented and coded by type as HR §5 lists them (de device, a0
-- motion, 11 light_level, 7e temperature, ba device_power, 2b
-- zigbee_connectivity, 50 device_software_update, 40 room or home, 8e
-- grouped_light, 9a grouped_motion, 91 grouped_light_level, ac
-- motion_area_configuration, ca convenience_area_motion, 5a
-- security_area_motion, cd motion_area_candidate, e0 event container, and
-- 1b for the lights, which HR leaves out). MAC addresses are invented; no
-- bridge id appears. Times are UTC on 2026-10-26.
--
-- The bridge:
--   Hallway sensor  SML003, /sensors/12, in the Hue room Hallway (beside the hallway lamp)
--   Porch sensor    SML002 (the contract's outdoor model; HR §5.1 has an SML004), /sensors/20,
--                   in no room: the bridge_home lists it
--   Kitchen motion area   MotionAware, room Kitchen, three of the four kitchen lights;
--                   bound to lights, so its convenience service is live and the
--                   security one frozen since 2026-10-19 (HR §2.5)
--   Hue motion sensor 1   SML001, /sensors/30: paired later (E10), then deleted (E11)
-- Rooms: Hallway (/groups/7: the hallway lamp and the hallway sensor; it lists
-- grouped_motion and grouped_light_level beside its grouped_light) and Kitchen
-- (/groups/8: the four kitchen lights); no zones.
--
-- Events: HR §5.4 E1 to E12, one key per SSE message (E7, E8 and E9 are two
-- each), plus the cases HR describes but does not show (marked [assumed]
-- there): back online, switched on again, the area used for security,
-- resumed, not running, deleted.

local M = {}

local function id(prefix, n)
	return prefix .. "000000-0000-4000-8000-0000000000" .. n
end

M.devices = {
	hallway = id("de", "01"), porch = id("de", "02"), new = id("de", "03"), lamp = id("de", "21"),
	kitchen1 = id("de", "11"), kitchen2 = id("de", "12"), kitchen3 = id("de", "13"), kitchen4 = id("de", "14"),
}
M.motion = { hallway = id("a0", "01"), porch = id("a0", "02"), new = id("a0", "03") }
M.light_level = { hallway = id("11", "01"), porch = id("11", "02"), new = id("11", "03") }
M.temperature = { hallway = id("7e", "01"), porch = id("7e", "02"), new = id("7e", "03") }
M.device_power = { hallway = id("ba", "01"), porch = id("ba", "02"), new = id("ba", "03") }
M.zigbee = { hallway = id("2b", "01"), porch = id("2b", "02"), new = id("2b", "03"), lamp = id("2b", "21") }
M.software_update = { hallway = id("50", "01"), porch = id("50", "02"), new = id("50", "03") }
M.lights = { lamp = id("1b", "21"), kitchen1 = id("1b", "11"), kitchen2 = id("1b", "12"), kitchen3 = id("1b", "13"),
	kitchen4 = id("1b", "14") }
M.rooms = { hallway = id("40", "01"), kitchen = id("40", "02"), home = id("40", "f0") }
M.grouped_lights = { hallway = id("8e", "01"), kitchen = id("8e", "02"), home = id("8e", "f0") }
M.grouped_motions = { hallway = id("9a", "01"), home = id("9a", "f0") }
M.grouped_light_levels = { hallway = id("91", "01"), home = id("91", "f0") }
M.area = id("ac", "01")
M.convenience = id("ca", "01")
M.security = id("5a", "01")
M.candidates = { id("cd", "11"), id("cd", "12"), id("cd", "13"), id("cd", "14") }
M.names = { hallway = "Hallway sensor", porch = "Porch sensor", new = "Hue motion sensor 1", area = "Kitchen motion area" }
M.macs = { hallway = "00:17:88:01:0c:00:00:01-02", porch = "00:17:88:01:0c:00:00:02-02",
	new = "00:17:88:01:0c:00:00:03-02" }

-- The bodies' `changed` times, for assertions.
M.changed = {
	hallway_motion = "2026-10-26T07:02:41.318Z",
	porch_motion = "2026-10-26T06:48:09.770Z",
	convenience = "2026-10-26T07:05:12.640Z",
	security = "2026-10-19T18:22:03.115Z",
	e1 = "2026-10-26T07:15:02.087Z",
	e2 = "2026-10-26T07:15:16.502Z",
	e8_motion = "2026-10-26T07:30:43.902Z",
	e8_clear = "2026-10-26T07:31:19.655Z",
}

M.empty = '{"errors":[],"data":[]}'
-- What a bridge without the MotionAware types answers for them [assumed: HR §2.7].
M.not_found = '{"errors":[{"description":"Not Found"}],"data":[]}'

-- GET /device: the two sensors of HR §5.1, then the lights' devices.
M.device = [[{"errors":[],"data":[
{"id":"]] .. M.devices.hallway .. [[","id_v1":"/sensors/12",
 "product_data":{"model_id":"SML003","manufacturer_name":"Signify Netherlands B.V.","product_name":"Hue motion sensor",
  "product_archetype":"unknown_archetype","certified":true,"software_version":"2.85.1","hardware_platform_type":"100b-11b"},
 "metadata":{"name":"Hallway sensor","archetype":"unknown_archetype"},
 "identify":{},
 "usertest":{"status":"set","usertest":false},
 "services":[{"rid":"]] .. M.zigbee.hallway .. [[","rtype":"zigbee_connectivity"},
  {"rid":"]] .. M.motion.hallway .. [[","rtype":"motion"},
  {"rid":"]] .. M.device_power.hallway .. [[","rtype":"device_power"},
  {"rid":"]] .. M.light_level.hallway .. [[","rtype":"light_level"},
  {"rid":"]] .. M.temperature.hallway .. [[","rtype":"temperature"},
  {"rid":"]] .. M.software_update.hallway .. [[","rtype":"device_software_update"}],
 "type":"device"},
{"id":"]] .. M.devices.porch .. [[","id_v1":"/sensors/20",
 "product_data":{"model_id":"SML002","manufacturer_name":"Signify Netherlands B.V.","product_name":"Hue outdoor motion sensor",
  "product_archetype":"unknown_archetype","certified":true,"software_version":"2.85.1"},
 "metadata":{"name":"Porch sensor","archetype":"unknown_archetype"},
 "identify":{},
 "usertest":{"status":"set","usertest":false},
 "services":[{"rid":"]] .. M.motion.porch .. [[","rtype":"motion"},
  {"rid":"]] .. M.device_power.porch .. [[","rtype":"device_power"},
  {"rid":"]] .. M.zigbee.porch .. [[","rtype":"zigbee_connectivity"},
  {"rid":"]] .. M.light_level.porch .. [[","rtype":"light_level"},
  {"rid":"]] .. M.temperature.porch .. [[","rtype":"temperature"},
  {"rid":"]] .. M.software_update.porch .. [[","rtype":"device_software_update"}],
 "type":"device"},
{"id":"]] .. M.devices.lamp .. [[","id_v1":"/lights/21",
 "product_data":{"model_id":"LCA001","manufacturer_name":"Signify Netherlands B.V.","product_name":"Hue color lamp",
  "product_archetype":"sultan_bulb","certified":true,"software_version":"1.122.2"},
 "metadata":{"name":"Hallway lamp","archetype":"sultan_bulb"},
 "identify":{},
 "services":[{"rid":"]] .. M.zigbee.lamp .. [[","rtype":"zigbee_connectivity"},{"rid":"]] .. M.lights.lamp .. [[","rtype":"light"}],
 "type":"device"},
{"id":"]] .. M.devices.kitchen1 .. [[","id_v1":"/lights/11","product_data":{"model_id":"LCA001","product_name":"Hue color lamp"},"metadata":{"name":"Kitchen 1","archetype":"sultan_bulb"},"services":[{"rid":"]] .. M.lights.kitchen1 .. [[","rtype":"light"}],"type":"device"},
{"id":"]] .. M.devices.kitchen2 .. [[","id_v1":"/lights/12","product_data":{"model_id":"LCA001","product_name":"Hue color lamp"},"metadata":{"name":"Kitchen 2","archetype":"sultan_bulb"},"services":[{"rid":"]] .. M.lights.kitchen2 .. [[","rtype":"light"}],"type":"device"},
{"id":"]] .. M.devices.kitchen3 .. [[","id_v1":"/lights/13","product_data":{"model_id":"LCA001","product_name":"Hue color lamp"},"metadata":{"name":"Kitchen 3","archetype":"sultan_bulb"},"services":[{"rid":"]] .. M.lights.kitchen3 .. [[","rtype":"light"}],"type":"device"},
{"id":"]] .. M.devices.kitchen4 .. [[","id_v1":"/lights/14","product_data":{"model_id":"LCA001","product_name":"Hue color lamp"},"metadata":{"name":"Kitchen 4","archetype":"sultan_bulb"},"services":[{"rid":"]] .. M.lights.kitchen4 .. [[","rtype":"light"}],"type":"device"}
]}]]

-- GET /light: none needed by the motion specs (the lights' module takes an empty list).
M.light = M.empty

M.motion_body = [[{"errors":[],"data":[
{"id":"]] .. M.motion.hallway .. [[","id_v1":"/sensors/12",
 "owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":true,"motion_report":{"changed":"2026-10-26T07:02:41.318Z","motion":false}},
 "sensitivity":{"status":"set","sensitivity":2,"sensitivity_max":4},
 "type":"motion"},
{"id":"]] .. M.motion.porch .. [[","id_v1":"/sensors/20",
 "owner":{"rid":"]] .. M.devices.porch .. [[","rtype":"device"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":true,"motion_report":{"changed":"2026-10-26T06:48:09.770Z","motion":false}},
 "sensitivity":{"status":"set","sensitivity":2,"sensitivity_max":4},
 "type":"motion"}
]}]]

-- 63.5 lux indoors (63 whole), 1770 lux on the porch.
M.light_level_body = [[{"errors":[],"data":[
{"id":"]] .. M.light_level.hallway .. [[","id_v1":"/sensors/13",
 "owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},
 "enabled":true,
 "light":{"light_level":18027,"light_level_valid":true,"light_level_report":{"changed":"2026-10-26T07:11:58.002Z","light_level":18027}},
 "type":"light_level"},
{"id":"]] .. M.light_level.porch .. [[","id_v1":"/sensors/21",
 "owner":{"rid":"]] .. M.devices.porch .. [[","rtype":"device"},
 "enabled":true,
 "light":{"light_level":32480,"light_level_valid":true,"light_level_report":{"changed":"2026-10-26T07:09:31.415Z","light_level":32480}},
 "type":"light_level"}
]}]]

M.temperature_body = [[{"errors":[],"data":[
{"id":"]] .. M.temperature.hallway .. [[","id_v1":"/sensors/14",
 "owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},
 "enabled":true,
 "temperature":{"temperature":21.37,"temperature_valid":true,"temperature_report":{"changed":"2026-10-26T07:08:20.551Z","temperature":21.37}},
 "type":"temperature"},
{"id":"]] .. M.temperature.porch .. [[","id_v1":"/sensors/22",
 "owner":{"rid":"]] .. M.devices.porch .. [[","rtype":"device"},
 "enabled":true,
 "temperature":{"temperature":14.62,"temperature_valid":true,"temperature_report":{"changed":"2026-10-26T07:13:02.919Z","temperature":14.62}},
 "type":"temperature"}
]}]]

M.device_power_body = [[{"errors":[],"data":[
{"id":"]] .. M.device_power.hallway .. [[","id_v1":"/sensors/12",
 "owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},
 "power_state":{"battery_state":"normal","battery_level":87},
 "type":"device_power"},
{"id":"]] .. M.device_power.porch .. [[","id_v1":"/sensors/20",
 "owner":{"rid":"]] .. M.devices.porch .. [[","rtype":"device"},
 "power_state":{"battery_state":"normal","battery_level":64},
 "type":"device_power"}
]}]]

-- The sensors' items and the hallway lamp's: a real GET lists every device's.
M.zigbee_connectivity = [[{"errors":[],"data":[
{"id":"]] .. M.zigbee.hallway .. [[","id_v1":"/sensors/12",
 "owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},
 "status":"connected","mac_address":"00:17:88:01:0c:00:00:01-02",
 "type":"zigbee_connectivity"},
{"id":"]] .. M.zigbee.porch .. [[","id_v1":"/sensors/20",
 "owner":{"rid":"]] .. M.devices.porch .. [[","rtype":"device"},
 "status":"connected","mac_address":"00:17:88:01:0c:00:00:02-02",
 "type":"zigbee_connectivity"},
{"id":"]] .. M.zigbee.lamp .. [[","id_v1":"/lights/21",
 "owner":{"rid":"]] .. M.devices.lamp .. [[","rtype":"device"},
 "status":"connected","mac_address":"00:17:88:01:0c:00:00:21-0b",
 "type":"zigbee_connectivity"}
]}]]

M.device_software_update = [[{"errors":[],"data":[
{"id":"]] .. M.software_update.hallway .. [[",
 "owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},
 "state":"no_update","problems":[],"type":"device_software_update"},
{"id":"]] .. M.software_update.porch .. [[",
 "owner":{"rid":"]] .. M.devices.porch .. [[","rtype":"device"},
 "state":"no_update","problems":[],"type":"device_software_update"}
]}]]

-- HR §5.2, with the Kitchen added (its lights take part in the area).
M.room = [[{"errors":[],"data":[
{"id":"]] .. M.rooms.hallway .. [[","id_v1":"/groups/7",
 "children":[{"rid":"]] .. M.devices.lamp .. [[","rtype":"device"},
  {"rid":"]] .. M.devices.hallway .. [[","rtype":"device"}],
 "services":[{"rid":"]] .. M.grouped_lights.hallway .. [[","rtype":"grouped_light"},
  {"rid":"]] .. M.grouped_motions.hallway .. [[","rtype":"grouped_motion"},
  {"rid":"]] .. M.grouped_light_levels.hallway .. [[","rtype":"grouped_light_level"}],
 "metadata":{"name":"Hallway","archetype":"hallway"},
 "type":"room"},
{"id":"]] .. M.rooms.kitchen .. [[","id_v1":"/groups/8",
 "children":[{"rid":"]] .. M.devices.kitchen1 .. [[","rtype":"device"},{"rid":"]] .. M.devices.kitchen2 .. [[","rtype":"device"},
  {"rid":"]] .. M.devices.kitchen3 .. [[","rtype":"device"},{"rid":"]] .. M.devices.kitchen4 .. [[","rtype":"device"}],
 "services":[{"rid":"]] .. M.grouped_lights.kitchen .. [[","rtype":"grouped_light"}],
 "metadata":{"name":"Kitchen","archetype":"kitchen"},
 "type":"room"}
]}]]

M.zone = M.empty

M.bridge_home = [[{"errors":[],"data":[
{"id":"]] .. M.rooms.home .. [[","id_v1":"/groups/0",
 "children":[{"rid":"]] .. M.devices.porch .. [[","rtype":"device"},
  {"rid":"]] .. M.rooms.hallway .. [[","rtype":"room"},{"rid":"]] .. M.rooms.kitchen .. [[","rtype":"room"}],
 "services":[{"rid":"]] .. M.grouped_lights.home .. [[","rtype":"grouped_light"},
  {"rid":"]] .. M.grouped_motions.home .. [[","rtype":"grouped_motion"},
  {"rid":"]] .. M.grouped_light_levels.home .. [[","rtype":"grouped_light_level"}],
 "type":"bridge_home"}
]}]]

M.grouped_motion = [[{"errors":[],"data":[
{"id":"]] .. M.grouped_motions.hallway .. [[",
 "owner":{"rid":"]] .. M.rooms.hallway .. [[","rtype":"room"},
 "enabled":true,
 "motion":{"motion_report":{"changed":"2026-10-26T07:02:41.402Z","motion":false}},
 "type":"grouped_motion"},
{"id":"]] .. M.grouped_motions.home .. [[",
 "owner":{"rid":"]] .. M.rooms.home .. [[","rtype":"bridge_home"},
 "enabled":true,
 "motion":{"motion_report":{"changed":"2026-10-26T07:02:41.402Z","motion":false}},
 "type":"grouped_motion"}
]}]]

M.grouped_light_level = [[{"errors":[],"data":[
{"id":"]] .. M.grouped_light_levels.hallway .. [[",
 "owner":{"rid":"]] .. M.rooms.hallway .. [[","rtype":"room"},
 "enabled":true,
 "light":{"light_level_report":{"changed":"2026-10-26T07:11:58.090Z","light_level":18027}},
 "type":"grouped_light_level"},
{"id":"]] .. M.grouped_light_levels.home .. [[",
 "owner":{"rid":"]] .. M.rooms.home .. [[","rtype":"bridge_home"},
 "enabled":true,
 "light":{"light_level_report":{"changed":"2026-10-26T07:11:58.090Z","light_level":25254}},
 "type":"grouped_light_level"}
]}]]

-- HR §5.3: the kitchen's area.
M.motion_area_configuration = [[{"errors":[],"data":[
{"id":"]] .. M.area .. [[",
 "name":"Kitchen motion area",
 "group":{"rid":"]] .. M.rooms.kitchen .. [[","rtype":"room"},
 "participants":[
  {"resource":{"rid":"]] .. M.candidates[1] .. [[","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},
  {"resource":{"rid":"]] .. M.candidates[2] .. [[","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},
  {"resource":{"rid":"]] .. M.candidates[3] .. [[","rtype":"motion_area_candidate"},"status":{"health":"healthy"}}],
 "services":[{"rid":"]] .. M.convenience .. [[","rtype":"convenience_area_motion"},
  {"rid":"]] .. M.security .. [[","rtype":"security_area_motion"}],
 "health":"healthy",
 "enabled":true,
 "type":"motion_area_configuration"}
]}]]

-- One Bridge Pro answered only these four fields before a firmware update
-- (EC A16, HR §2.3).
M.motion_area_configuration_partial = [[{"errors":[],"data":[
{"id":"]] .. M.area .. [[","owner":{"rid":"]] .. M.rooms.kitchen .. [[","rtype":"room"},"enabled":true,"type":"motion_area_configuration"}
]}]]

M.convenience_area_motion = [[{"errors":[],"data":[
{"id":"]] .. M.convenience .. [[",
 "owner":{"rid":"]] .. M.area .. [[","rtype":"motion_area_configuration"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":true,"motion_report":{"changed":"2026-10-26T07:05:12.640Z","motion":false}},
 "sensitivity":{"sensitivity":2,"sensitivity_max":4},
 "type":"convenience_area_motion"}
]}]]

M.security_area_motion = [[{"errors":[],"data":[
{"id":"]] .. M.security .. [[",
 "owner":{"rid":"]] .. M.area .. [[","rtype":"motion_area_configuration"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":false,"motion_report":{"changed":"2026-10-19T18:22:03.115Z","motion":false}},
 "sensitivity":{"sensitivity":2,"sensitivity_max":4},
 "type":"security_area_motion"}
]}]]

-- If the bridge serves it (HR §2.6): the fourth kitchen light is compatible
-- but not in the area.
M.motion_area_candidate = [[{"errors":[],"data":[
{"id":"]] .. M.candidates[1] .. [[","owner":{"rid":"]] .. M.devices.kitchen1 .. [[","rtype":"device"},"capabilities":["sensor","collector","sync"],"type":"motion_area_candidate"},
{"id":"]] .. M.candidates[2] .. [[","owner":{"rid":"]] .. M.devices.kitchen2 .. [[","rtype":"device"},"capabilities":["sensor","collector","sync"],"type":"motion_area_candidate"},
{"id":"]] .. M.candidates[3] .. [[","owner":{"rid":"]] .. M.devices.kitchen3 .. [[","rtype":"device"},"capabilities":["sensor","collector","sync"],"type":"motion_area_candidate"},
{"id":"]] .. M.candidates[4] .. [[","owner":{"rid":"]] .. M.devices.kitchen4 .. [[","rtype":"device"},"capabilities":["sensor","collector","sync"],"type":"motion_area_candidate"}
]}]]

-- The bodies a motion resync GETs, by resource type (docs/motion-design.md §4.2).
M.get = {
	motion = M.motion_body,
	light_level = M.light_level_body,
	temperature = M.temperature_body,
	device_power = M.device_power_body,
	zigbee_connectivity = M.zigbee_connectivity,
	motion_area_configuration = M.motion_area_configuration,
	convenience_area_motion = M.convenience_area_motion,
	security_area_motion = M.security_area_motion,
	grouped_motion = M.grouped_motion,
	grouped_light_level = M.grouped_light_level,
	motion_area_candidate = M.motion_area_candidate,
	device_software_update = M.device_software_update,
}

-- Events (HR §5.4): one SSE message each, as the container array its data
-- line holds. M.sse_ids keeps each message's id line (the Unix second and a
-- counter, as the bridge sends them).
M.events = {}
M.sse_ids = {}

local function event(key, sse_id, json)
	M.events[key] = json
	M.sse_ids[key] = sse_id
end

-- E1: someone walks into the hallway; the room's and the home's grouped motion follow in the same container.
event("e1", "1792998902:0", [=[[{"creationtime":"2026-10-26T07:15:02Z","data":[{"id":"]=] .. M.motion.hallway .. [[","id_v1":"/sensors/12","motion":{"motion":true,"motion_report":{"changed":"2026-10-26T07:15:02.087Z","motion":true},"motion_valid":true},"owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},"type":"motion"},{"id":"]] .. M.grouped_motions.hallway .. [[","motion":{"motion_report":{"changed":"2026-10-26T07:15:02.140Z","motion":true}},"owner":{"rid":"]] .. M.rooms.hallway .. [[","rtype":"room"},"type":"grouped_motion"},{"id":"]] .. M.grouped_motions.home .. [[","motion":{"motion_report":{"changed":"2026-10-26T07:15:02.141Z","motion":true}},"owner":{"rid":"]] .. M.rooms.home .. [[","rtype":"bridge_home"},"type":"grouped_motion"}],"id":"]] .. id("e0", "01") .. [=[","type":"update"}]]=])

-- E2: 14 s later, no motion.
event("e2", "1792998916:0", [=[[{"creationtime":"2026-10-26T07:15:16Z","data":[{"id":"]=] .. M.motion.hallway .. [[","id_v1":"/sensors/12","motion":{"motion":false,"motion_report":{"changed":"2026-10-26T07:15:16.502Z","motion":false},"motion_valid":true},"owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},"type":"motion"},{"id":"]] .. M.grouped_motions.hallway .. [[","motion":{"motion_report":{"changed":"2026-10-26T07:15:16.560Z","motion":false}},"owner":{"rid":"]] .. M.rooms.hallway .. [[","rtype":"room"},"type":"grouped_motion"},{"id":"]] .. M.grouped_motions.home .. [[","motion":{"motion_report":{"changed":"2026-10-26T07:15:16.561Z","motion":false}},"owner":{"rid":"]] .. M.rooms.home .. [[","rtype":"bridge_home"},"type":"grouped_motion"}],"id":"]] .. id("e0", "02") .. [=[","type":"update"}]]=])

-- E3: the hallway gets brighter (126 lux), with the room's grouped level.
event("e3", "1792999000:0", [=[[{"creationtime":"2026-10-26T07:16:40Z","data":[{"id":"]=] .. M.light_level.hallway .. [[","id_v1":"/sensors/13","light":{"light_level":21000,"light_level_report":{"changed":"2026-10-26T07:16:39.877Z","light_level":21000},"light_level_valid":true},"owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},"type":"light_level"},{"id":"]] .. M.grouped_light_levels.hallway .. [[","light":{"light_level_report":{"changed":"2026-10-26T07:16:39.950Z","light_level":21000}},"owner":{"rid":"]] .. M.rooms.hallway .. [[","rtype":"room"},"type":"grouped_light_level"}],"id":"]] .. id("e0", "03") .. [=[","type":"update"}]]=])

-- E4: the porch warms to 14.88 °C.
event("e4", "1792999085:0", [=[[{"creationtime":"2026-10-26T07:18:05Z","data":[{"id":"]=] .. M.temperature.porch .. [[","id_v1":"/sensors/22","owner":{"rid":"]] .. M.devices.porch .. [[","rtype":"device"},"temperature":{"temperature":14.88,"temperature_report":{"changed":"2026-10-26T07:18:04.610Z","temperature":14.88},"temperature_valid":true},"type":"temperature"}],"id":"]] .. id("e0", "04") .. [=[","type":"update"}]]=])

-- E5: the porch sensor loses its link.
event("e5", "1792999231:0", [=[[{"creationtime":"2026-10-26T07:20:31Z","data":[{"id":"]=] .. M.zigbee.porch .. [[","id_v1":"/sensors/20","owner":{"rid":"]] .. M.devices.porch .. [[","rtype":"device"},"status":"connectivity_issue","type":"zigbee_connectivity"}],"id":"]] .. id("e0", "05") .. [=[","type":"update"}]]=])

-- E6: the hallway sensor is switched off in the Hue app.
event("e6", "1792999450:0", [=[[{"creationtime":"2026-10-26T07:24:10Z","data":[{"enabled":false,"id":"]=] .. M.motion.hallway .. [[","id_v1":"/sensors/12","owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},"type":"motion"}],"id":"]] .. id("e0", "06") .. [=[","type":"update"}]]=])

-- E7: switched on again (not shown), its sensitivity is raised in the app; the sensor takes it 12 s later.
event("e7_raised", "1792999500:0", [=[[{"creationtime":"2026-10-26T07:25:00Z","data":[{"id":"]=] .. M.motion.hallway .. [[","id_v1":"/sensors/12","owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},"sensitivity":{"sensitivity":3,"status":"changing"},"type":"motion"}],"id":"]] .. id("e0", "07") .. [=[","type":"update"}]]=])
event("e7_set", "1792999512:0", [=[[{"creationtime":"2026-10-26T07:25:12Z","data":[{"id":"]=] .. M.motion.hallway .. [[","id_v1":"/sensors/12","owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},"sensitivity":{"status":"set"},"type":"motion"}],"id":"]] .. id("e0", "08") .. [=[","type":"update"}]]=])

-- E8: motion in the kitchen area, then none 36 s later (the convenience service only).
event("e8_motion", "1792999844:0", [=[[{"creationtime":"2026-10-26T07:30:44Z","data":[{"id":"]=] .. M.convenience .. [[","motion":{"motion":true,"motion_report":{"changed":"2026-10-26T07:30:43.902Z","motion":true},"motion_valid":true},"owner":{"rid":"]] .. M.area .. [[","rtype":"motion_area_configuration"},"type":"convenience_area_motion"}],"id":"]] .. id("e0", "09") .. [=[","type":"update"}]]=])
event("e8_clear", "1792999880:0", [=[[{"creationtime":"2026-10-26T07:31:20Z","data":[{"id":"]=] .. M.convenience .. [[","motion":{"motion":false,"motion_report":{"changed":"2026-10-26T07:31:19.655Z","motion":false},"motion_valid":true},"owner":{"rid":"]] .. M.area .. [[","rtype":"motion_area_configuration"},"type":"convenience_area_motion"}],"id":"]] .. id("e0", "0a") .. [=[","type":"update"}]]=])

-- E9: two separate moments: the area is switched off in the app; later, back on (area_resumed below), one of its lights loses power.
event("e9_paused", "1793000400:0", [=[[{"creationtime":"2026-10-26T07:40:00Z","data":[{"enabled":false,"id":"]=] .. M.area .. [[","type":"motion_area_configuration"}],"id":"]] .. id("e0", "0b") .. [=[","type":"update"}]]=])
event("e9_degraded", "1793000490:0", [=[[{"creationtime":"2026-10-26T07:41:30Z","data":[{"health":"degraded","id":"]=] .. M.area .. [[","participants":[{"resource":{"rid":"]] .. M.candidates[1] .. [[","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},{"resource":{"rid":"]] .. M.candidates[2] .. [[","rtype":"motion_area_candidate"},"status":{"health":"unhealthy"}},{"resource":{"rid":"]] .. M.candidates[3] .. [[","rtype":"motion_area_candidate"},"status":{"health":"healthy"}}],"type":"motion_area_configuration"}],"id":"]] .. id("e0", "0c") .. [=[","type":"update"}]]=])

-- E10: a first-generation indoor sensor (SML001) is paired: complete resources in one `add` container.
event("e10", "1793001900:0", [=[[{"creationtime":"2026-10-26T08:05:00Z","data":[{"id":"]=] .. M.devices.new .. [[","id_v1":"/sensors/30","identify":{},"metadata":{"archetype":"unknown_archetype","name":"Hue motion sensor 1"},"product_data":{"certified":true,"hardware_platform_type":"100b-10d","manufacturer_name":"Signify Netherlands B.V.","model_id":"SML001","product_archetype":"unknown_archetype","product_name":"Hue motion sensor","software_version":"2.85.1"},"services":[{"rid":"]] .. M.motion.new .. [[","rtype":"motion"},{"rid":"]] .. M.device_power.new .. [[","rtype":"device_power"},{"rid":"]] .. M.zigbee.new .. [[","rtype":"zigbee_connectivity"},{"rid":"]] .. M.light_level.new .. [[","rtype":"light_level"},{"rid":"]] .. M.temperature.new .. [[","rtype":"temperature"},{"rid":"]] .. M.software_update.new .. [[","rtype":"device_software_update"}],"type":"device"},{"enabled":true,"id":"]] .. M.motion.new .. [[","id_v1":"/sensors/30","motion":{"motion":false,"motion_report":{"changed":"2026-10-26T08:04:58.310Z","motion":false},"motion_valid":true},"owner":{"rid":"]] .. M.devices.new .. [[","rtype":"device"},"sensitivity":{"sensitivity":2,"sensitivity_max":2,"status":"set"},"type":"motion"},{"id":"]] .. M.device_power.new .. [[","id_v1":"/sensors/30","owner":{"rid":"]] .. M.devices.new .. [[","rtype":"device"},"power_state":{"battery_level":100,"battery_state":"normal"},"type":"device_power"},{"id":"]] .. M.zigbee.new .. [[","id_v1":"/sensors/30","mac_address":"00:17:88:01:0c:00:00:03-02","owner":{"rid":"]] .. M.devices.new .. [[","rtype":"device"},"status":"connected","type":"zigbee_connectivity"},{"enabled":true,"id":"]] .. M.light_level.new .. [[","id_v1":"/sensors/31","light":{"light_level":9141,"light_level_report":{"changed":"2026-10-26T08:04:58.402Z","light_level":9141},"light_level_valid":true},"owner":{"rid":"]] .. M.devices.new .. [[","rtype":"device"},"type":"light_level"},{"enabled":true,"id":"]] .. M.temperature.new .. [[","id_v1":"/sensors/32","owner":{"rid":"]] .. M.devices.new .. [[","rtype":"device"},"temperature":{"temperature":20.56,"temperature_report":{"changed":"2026-10-26T08:04:58.455Z","temperature":20.56},"temperature_valid":true},"type":"temperature"},{"id":"]] .. M.software_update.new .. [[","owner":{"rid":"]] .. M.devices.new .. [[","rtype":"device"},"problems":[],"state":"no_update","type":"device_software_update"}],"id":"]] .. id("e0", "0d") .. [=[","type":"add"}]]=])

-- E11: the same sensor is deleted in the app: bare identifiers.
event("e11", "1793002800:0", [=[[{"creationtime":"2026-10-26T08:20:00Z","data":[{"id":"]=] .. M.motion.new .. [[","type":"motion"},{"id":"]] .. M.light_level.new .. [[","type":"light_level"},{"id":"]] .. M.temperature.new .. [[","type":"temperature"},{"id":"]] .. M.device_power.new .. [[","type":"device_power"},{"id":"]] .. M.zigbee.new .. [[","type":"zigbee_connectivity"},{"id":"]] .. M.software_update.new .. [[","type":"device_software_update"},{"id":"]] .. M.devices.new .. [[","type":"device"}],"id":"]] .. id("e0", "0e") .. [=[","type":"delete"}]]=])

-- E12: seven weeks later the hallway sensor's battery runs low.
event("e12", "1797217960:0", [=[[{"creationtime":"2026-12-14T03:12:40Z","data":[{"id":"]=] .. M.device_power.hallway .. [[","id_v1":"/sensors/12","owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},"power_state":{"battery_level":9,"battery_state":"low"},"type":"device_power"}],"id":"]] .. id("e0", "0f") .. [=[","type":"update"}]]=])

-- Shown by no source, shaped after the ones above [assumed: HR §3.5].
-- The porch sensor answers again after E5.
event("e5_back", "1792999600:0", [=[[{"creationtime":"2026-10-26T07:26:40Z","data":[{"id":"]=] .. M.zigbee.porch .. [[","id_v1":"/sensors/20","owner":{"rid":"]] .. M.devices.porch .. [[","rtype":"device"},"status":"connected","type":"zigbee_connectivity"}],"id":"]] .. id("e0", "10") .. [=[","type":"update"}]]=])
-- The hallway sensor switched on again after E6.
event("e6_on", "1792999480:0", [=[[{"creationtime":"2026-10-26T07:24:40Z","data":[{"enabled":true,"id":"]=] .. M.motion.hallway .. [[","id_v1":"/sensors/12","owner":{"rid":"]] .. M.devices.hallway .. [[","rtype":"device"},"type":"motion"}],"id":"]] .. id("e0", "11") .. [=[","type":"update"}]]=])
-- The area, used for security in the Hue app, reports through its other service (EC A9).
event("area_security", "1793000100:0", [=[[{"creationtime":"2026-10-26T07:35:00Z","data":[{"id":"]=] .. M.security .. [[","motion":{"motion":true,"motion_report":{"changed":"2026-10-26T07:34:59.120Z","motion":true},"motion_valid":true},"owner":{"rid":"]] .. M.area .. [[","rtype":"motion_area_configuration"},"type":"security_area_motion"}],"id":"]] .. id("e0", "12") .. [=[","type":"update"}]]=])
-- The area resumed after E9's pause, healthy again.
event("area_resumed", "1793000700:0", [=[[{"creationtime":"2026-10-26T07:45:00Z","data":[{"enabled":true,"health":"healthy","id":"]=] .. M.area .. [[","participants":[{"resource":{"rid":"]] .. M.candidates[1] .. [[","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},{"resource":{"rid":"]] .. M.candidates[2] .. [[","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},{"resource":{"rid":"]] .. M.candidates[3] .. [[","rtype":"motion_area_candidate"},"status":{"health":"healthy"}}],"type":"motion_area_configuration"}],"id":"]] .. id("e0", "13") .. [=[","type":"update"}]]=])
-- The area stopped sensing (EC A7).
event("area_not_running", "1793000800:0", [=[[{"creationtime":"2026-10-26T07:46:40Z","data":[{"health":"not_running","id":"]=] .. M.area .. [[","type":"motion_area_configuration"}],"id":"]] .. id("e0", "14") .. [=[","type":"update"}]]=])
-- The area deleted in the Hue app (EC A3).
event("area_deleted", "1793000900:0", [=[[{"creationtime":"2026-10-26T07:48:20Z","data":[{"id":"]=] .. M.convenience .. [[","type":"convenience_area_motion"},{"id":"]] .. M.security .. [[","type":"security_area_motion"},{"id":"]] .. M.area .. [[","type":"motion_area_configuration"}],"id":"]] .. id("e0", "15") .. [=[","type":"delete"}]]=])

-- One event as the bridge sends it: the id line, the data line, a blank line.
function M.sse(key)
	return "id: " .. M.sse_ids[key] .. "\ndata: " .. M.events[key] .. "\n\n"
end

return M
