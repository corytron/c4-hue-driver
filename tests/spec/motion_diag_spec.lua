-- Log Motion Diagnostics (src/hue_bridge/bridge/motion_diag.lua,
-- docs/motion-design.md §4.3): the run (an answer at once, the pass 20 s
-- later on the ctx timer, a second run starting over), the pass's GETs one
-- at a time, the 10-minute capture and its 200-line limit, and above all the
-- redaction: nothing logged or answered holds a Hue name, a full resource id,
-- a MAC address, a bridge id, an IP address or the application key. The
-- fixtures rebuild docs/motion-hue-research.md §5 (HR) with invented ids and
-- names, plus hostile values HR's never have.

local fake = require("helpers.fake_c4")
local log = require("common.log")

-- Invented ids, one per fixture object: UUIDs whose first 4 hex digits differ
-- for every n (an odd multiplier permutes the values modulo 2^16), so every
-- id's alias is its first 4 characters and "…".
local function invent(n)
	local a = (n * 0x79B1) % 0x10000
	local b = (n * 0x2F65 + 0x1234) % 0x10000
	local c = (n * 0x6B43 + 0x0BEE) % 0x10000
	return string.format("%04x%04x-%04x-4%03x-a%03x-%04x%04x%04x", a, b, c, (n * 37) % 0x1000, (n * 91) % 0x1000,
		b, c, a)
end

local OBJECTS = {
	-- the indoor SML003, the outdoor SML004 (in no room) and an SML001 paired during the capture
	"dev1", "motion1", "light1", "temp1", "power1", "zig1", "swu1",
	"dev2", "motion2", "light2", "temp2", "power2", "zig2", "swu2",
	"dev3", "motion3", "light3", "temp3", "power3", "zig3", "swu3",
	-- other devices: a kitchen lamp, the hallway lamp, the bridge, a dimmer switch, a contact sensor
	"dev11", "lamp11", "zig11", "swu11", "dev21", "lamp21", "devb", "bridge", "zigb", "dev31", "button31", "power31",
	"zig31", "dev41", "contact1",
	-- groups: the hallway (room1), the kitchen (room2), a zone, the home, a sensor group
	"room1", "room2", "zone1", "home", "gl1", "gl2", "glz", "glhome", "gm1", "gmhome", "gll1", "gllhome",
	"sg1", "gmsg", "gllsg",
	-- the kitchen's MotionAware area, its services, and its lamps as candidates
	"area1", "conv1", "sec1", "cand11", "cand12", "cand13", "cand14", "dev12", "dev13", "dev14",
	-- the clip resource, event containers, and the hostile fixtures' objects
	"clip", "e1", "e2", "e3", "e4", "e5", "e6", "e7", "e8", "e9", "e10", "e11", "e12", "e13", "e14",
	"dev9", "motion9", "zig9", "script9",
	-- the Hue automations (#280): four scripts, three instances, what they point at, and a hostile instance
	"script1", "script2", "script3", "script4", "inst1", "inst2", "inst3", "inst4", "inst9", "recipe1", "scene1",
	"geo1", "e15", "e16", "e17", "e18",
}

local V = {}
for i, key in ipairs(OBJECTS) do
	V[key] = invent(i)
end

-- Invented names, each with a word (Vexa, Quorn, Zubb) that no logged text
-- has otherwise; dev3 keeps the name the Hue app gives a new SML001.
local NAMES = {
	name_dev1 = "Vexa hall sensor", name_dev2 = "Quorn porch sensor", name_dev3 = "Hue motion sensor 1",
	name_dev11 = "Quorn lamp 1", name_dev21 = "Vexa lamp", name_devb = "Zubb bridge", name_dev31 = "Quorn dimmer",
	name_dev41 = "Quorn back door", name_room1 = "Vexa Hallway", name_room2 = "Quorn Kitchen",
	name_zone1 = "Quorn Downstairs", name_area1 = "Quorn kitchen motion area", name_sg1 = "Zubb sensor group",
	name_inst1 = "Vexa tea timer", name_inst2 = "Quorn kitchen MotionAware", name_inst3 = "Zubb welcome home",
	name_inst4 = "Quorn after the film",
}
local MACS = {
	mac1 = "00:17:88:01:0c:00:00:01-02", mac2 = "00:17:88:01:0c:00:00:02-02", mac3 = "00:17:88:01:0c:00:00:03-02",
	mac11 = "00:17:88:01:0b:00:00:11-0b", macb = "00:17:88:ff:fe:12:3a:bc", mac31 = "00:17:88:01:0d:00:00:31-01",
	mac9 = "00:17:88:01:0c:00:00:09-02",
}
-- The documented placeholders (CONTRIBUTING.md) and a stand-in application key.
local BRIDGE_ID = "001788fffe123abc"
local BRIDGE_IP = "10.0.2.143"
local APP_SECRET = "zzzz0000zzzz0000zzzz0000zzzz00"

-- JSON text with $<object>, $name_<object> and $mac<n> filled in (a JSON
-- schema's "$ref" key stays).
local function fill(text)
	return (text:gsub("%$([%w_]+)", function(k)
		if k == "ref" then
			return nil
		end
		local v = V[k] or NAMES[k] or MACS[k]
		assert(v, "fixture: no value for $" .. k)
		return v
	end):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- An alias as the module writes it.
local function A(key)
	return V[key]:sub(1, 4) .. "…"
end

-- The pass starts at 07:15:00Z on 2026-10-26 (HR §5's day); the action was
-- clicked 20 s before.
local PASS_MS = 1792998900000
local RUN_MS = PASS_MS - 20000

local BODY = {}

BODY.clip = fill([[
{"errors":[],"data":[{"id":"$clip","type":"clip","resources":["behavior_instance","bridge","bridge_home","button",
"behavior_script","camera_motion","contact","convenience_area_motion","device","device_power","device_software_update",
"grouped_light",
"grouped_light_level","grouped_motion","light","light_level","motion","motion_area_configuration","room","scene",
"security_area_motion","service_group","tamper","temperature","zigbee_connectivity","zone"]}]}
]])

-- HR §5.1, with four devices that are not sensors.
BODY.device = fill([[
{"errors":[],"data":[
{"id":"$dev1","id_v1":"/sensors/12",
 "product_data":{"model_id":"SML003","manufacturer_name":"Signify Netherlands B.V.","product_name":"Hue motion sensor",
  "product_archetype":"unknown_archetype","certified":true,"software_version":"2.85.1",
  "hardware_platform_type":"100b-11b"},
 "metadata":{"name":"$name_dev1","archetype":"unknown_archetype"},
 "identify":{},
 "usertest":{"status":"set","usertest":false},
 "services":[{"rid":"$zig1","rtype":"zigbee_connectivity"},{"rid":"$motion1","rtype":"motion"},
  {"rid":"$power1","rtype":"device_power"},{"rid":"$light1","rtype":"light_level"},
  {"rid":"$temp1","rtype":"temperature"},{"rid":"$swu1","rtype":"device_software_update"}],
 "type":"device"},
{"id":"$dev2","id_v1":"/sensors/20",
 "product_data":{"model_id":"SML004","manufacturer_name":"Signify Netherlands B.V.",
  "product_name":"Hue outdoor motion sensor","product_archetype":"unknown_archetype","certified":true,
  "software_version":"2.85.1","hardware_platform_type":"100b-11b"},
 "metadata":{"name":"$name_dev2","archetype":"unknown_archetype"},
 "identify":{},
 "usertest":{"status":"set","usertest":false},
 "services":[{"rid":"$motion2","rtype":"motion"},{"rid":"$power2","rtype":"device_power"},
  {"rid":"$zig2","rtype":"zigbee_connectivity"},{"rid":"$light2","rtype":"light_level"},
  {"rid":"$temp2","rtype":"temperature"},{"rid":"$swu2","rtype":"device_software_update"}],
 "type":"device"},
{"id":"$dev11","id_v1":"/lights/11",
 "product_data":{"model_id":"LCA001","manufacturer_name":"Signify Netherlands B.V.","product_name":"Hue color lamp",
  "product_archetype":"sultan_bulb","certified":true,"software_version":"1.122.8"},
 "metadata":{"name":"$name_dev11","archetype":"sultan_bulb"},
 "identify":{},
 "services":[{"rid":"$zig11","rtype":"zigbee_connectivity"},{"rid":"$lamp11","rtype":"light"},
  {"rid":"$swu11","rtype":"device_software_update"}],
 "type":"device"},
{"id":"$dev21","id_v1":"/lights/21",
 "product_data":{"model_id":"LTA001","manufacturer_name":"Signify Netherlands B.V.",
  "product_name":"Hue white ambiance lamp","product_archetype":"classic_bulb","certified":true,
  "software_version":"1.122.8"},
 "metadata":{"name":"$name_dev21","archetype":"classic_bulb"},
 "identify":{},
 "services":[{"rid":"$lamp21","rtype":"light"}],
 "type":"device"},
{"id":"$devb",
 "product_data":{"model_id":"BSB003","manufacturer_name":"Signify Netherlands B.V.","product_name":"Hue Bridge Pro",
  "product_archetype":"bridge_v3","certified":true,"software_version":"1.77.2071353020"},
 "metadata":{"name":"$name_devb","archetype":"bridge_v3"},
 "identify":{},
 "services":[{"rid":"$bridge","rtype":"bridge"},{"rid":"$zigb","rtype":"zigbee_connectivity"}],
 "type":"device"},
{"id":"$dev31","id_v1":"/sensors/40",
 "product_data":{"model_id":"RWL022","manufacturer_name":"Signify Netherlands B.V.","product_name":"Hue dimmer switch",
  "product_archetype":"unknown_archetype","certified":true,"software_version":"2.59.25"},
 "metadata":{"name":"$name_dev31","archetype":"unknown_archetype"},
 "identify":{},
 "services":[{"rid":"$button31","rtype":"button"},{"rid":"$power31","rtype":"device_power"},
  {"rid":"$zig31","rtype":"zigbee_connectivity"}],
 "type":"device"}
]}
]])

BODY.motion = fill([[
{"errors":[],"data":[
{"id":"$motion1","id_v1":"/sensors/12",
 "owner":{"rid":"$dev1","rtype":"device"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":true,
  "motion_report":{"changed":"2026-10-26T07:02:41.318Z","motion":false}},
 "sensitivity":{"status":"set","sensitivity":2,"sensitivity_max":4},
 "type":"motion"},
{"id":"$motion2","id_v1":"/sensors/20",
 "owner":{"rid":"$dev2","rtype":"device"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":true,
  "motion_report":{"changed":"2026-10-26T06:48:09.770Z","motion":false}},
 "sensitivity":{"status":"set","sensitivity":2,"sensitivity_max":4},
 "type":"motion"}
]}
]])

BODY.light_level = fill([[
{"errors":[],"data":[
{"id":"$light1","id_v1":"/sensors/13",
 "owner":{"rid":"$dev1","rtype":"device"},
 "enabled":true,
 "light":{"light_level":18027,"light_level_valid":true,
  "light_level_report":{"changed":"2026-10-26T07:11:58.002Z","light_level":18027}},
 "type":"light_level"},
{"id":"$light2","id_v1":"/sensors/21",
 "owner":{"rid":"$dev2","rtype":"device"},
 "enabled":true,
 "light":{"light_level":32480,"light_level_valid":true,
  "light_level_report":{"changed":"2026-10-26T07:09:31.415Z","light_level":32480}},
 "type":"light_level"}
]}
]])

BODY.temperature = fill([[
{"errors":[],"data":[
{"id":"$temp1","id_v1":"/sensors/14",
 "owner":{"rid":"$dev1","rtype":"device"},
 "enabled":true,
 "temperature":{"temperature":21.37,"temperature_valid":true,
  "temperature_report":{"changed":"2026-10-26T07:08:20.551Z","temperature":21.37}},
 "type":"temperature"},
{"id":"$temp2","id_v1":"/sensors/22",
 "owner":{"rid":"$dev2","rtype":"device"},
 "enabled":true,
 "temperature":{"temperature":14.62,"temperature_valid":true,
  "temperature_report":{"changed":"2026-10-26T07:13:02.919Z","temperature":14.62}},
 "type":"temperature"}
]}
]])

BODY.device_power = fill([[
{"errors":[],"data":[
{"id":"$power1","id_v1":"/sensors/12","owner":{"rid":"$dev1","rtype":"device"},
 "power_state":{"battery_state":"normal","battery_level":87},"type":"device_power"},
{"id":"$power2","id_v1":"/sensors/20","owner":{"rid":"$dev2","rtype":"device"},
 "power_state":{"battery_state":"normal","battery_level":64},"type":"device_power"},
{"id":"$power31","id_v1":"/sensors/40","owner":{"rid":"$dev31","rtype":"device"},
 "power_state":{"battery_state":"normal","battery_level":55},"type":"device_power"}
]}
]])

-- The first sensor's item also carries the radio fields a bridge's own has.
BODY.zigbee_connectivity = fill([[
{"errors":[],"data":[
{"id":"$zig1","id_v1":"/sensors/12","owner":{"rid":"$dev1","rtype":"device"},
 "status":"connected","mac_address":"$mac1","channel":{"status":"set","value":"channel_25"},
 "extended_pan_id":"001788fffe123abc","type":"zigbee_connectivity"},
{"id":"$zig2","id_v1":"/sensors/20","owner":{"rid":"$dev2","rtype":"device"},
 "status":"connected","mac_address":"$mac2","type":"zigbee_connectivity"},
{"id":"$zig11","id_v1":"/lights/11","owner":{"rid":"$dev11","rtype":"device"},
 "status":"connected","mac_address":"$mac11","type":"zigbee_connectivity"},
{"id":"$zigb","owner":{"rid":"$devb","rtype":"device"},
 "status":"connected","mac_address":"$macb","type":"zigbee_connectivity"},
{"id":"$zig31","id_v1":"/sensors/40","owner":{"rid":"$dev31","rtype":"device"},
 "status":"connected","mac_address":"$mac31","type":"zigbee_connectivity"}
]}
]])

BODY.device_software_update = fill([[
{"errors":[],"data":[
{"id":"$swu1","owner":{"rid":"$dev1","rtype":"device"},"state":"no_update","problems":[],
 "type":"device_software_update"},
{"id":"$swu2","owner":{"rid":"$dev2","rtype":"device"},"state":"no_update","problems":[],
 "type":"device_software_update"},
{"id":"$swu11","owner":{"rid":"$dev11","rtype":"device"},"state":"update_available","problems":[],
 "type":"device_software_update"}
]}
]])

-- HR §5.2, with the sensor group's.
BODY.grouped_motion = fill([[
{"errors":[],"data":[
{"id":"$gm1","owner":{"rid":"$room1","rtype":"room"},"enabled":true,
 "motion":{"motion_report":{"changed":"2026-10-26T07:02:41.402Z","motion":false}},"type":"grouped_motion"},
{"id":"$gmhome","owner":{"rid":"$home","rtype":"bridge_home"},"enabled":true,
 "motion":{"motion_report":{"changed":"2026-10-26T07:02:41.402Z","motion":false}},"type":"grouped_motion"},
{"id":"$gmsg","owner":{"rid":"$sg1","rtype":"service_group"},"enabled":true,
 "motion":{"motion_report":{"changed":"2026-10-26T07:02:41.402Z","motion":false}},"type":"grouped_motion"}
]}
]])

BODY.grouped_light_level = fill([[
{"errors":[],"data":[
{"id":"$gll1","owner":{"rid":"$room1","rtype":"room"},"enabled":true,
 "light":{"light_level_report":{"changed":"2026-10-26T07:11:58.090Z","light_level":18027}},
 "type":"grouped_light_level"},
{"id":"$gllhome","owner":{"rid":"$home","rtype":"bridge_home"},"enabled":true,
 "light":{"light_level_report":{"changed":"2026-10-26T07:11:58.090Z","light_level":25254}},
 "type":"grouped_light_level"},
{"id":"$gllsg","owner":{"rid":"$sg1","rtype":"service_group"},"enabled":true,
 "light":{"light_level_report":{"changed":"2026-10-26T07:11:58.090Z","light_level":0}},
 "type":"grouped_light_level"}
]}
]])

BODY.service_group = fill([[
{"errors":[],"data":[
{"id":"$sg1",
 "children":[{"rid":"$motion1","rtype":"motion"},{"rid":"$light1","rtype":"light_level"},
  {"rid":"$motion2","rtype":"motion"},{"rid":"$light2","rtype":"light_level"}],
 "services":[{"rid":"$gmsg","rtype":"grouped_motion"},{"rid":"$gllsg","rtype":"grouped_light_level"}],
 "metadata":{"name":"$name_sg1"},
 "type":"service_group"}
]}
]])

-- HR §5.3: the kitchen's area, bound to lights.
BODY.motion_area_configuration = fill([[
{"errors":[],"data":[
{"id":"$area1",
 "name":"$name_area1",
 "group":{"rid":"$room2","rtype":"room"},
 "participants":[
  {"resource":{"rid":"$cand11","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},
  {"resource":{"rid":"$cand12","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},
  {"resource":{"rid":"$cand13","rtype":"motion_area_candidate"},"status":{"health":"healthy"}}],
 "services":[{"rid":"$conv1","rtype":"convenience_area_motion"},{"rid":"$sec1","rtype":"security_area_motion"}],
 "health":"healthy",
 "enabled":true,
 "type":"motion_area_configuration"}
]}
]])

BODY.convenience_area_motion = fill([[
{"errors":[],"data":[
{"id":"$conv1",
 "owner":{"rid":"$area1","rtype":"motion_area_configuration"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":true,
  "motion_report":{"changed":"2026-10-26T07:05:12.640Z","motion":false}},
 "sensitivity":{"sensitivity":2,"sensitivity_max":4},
 "type":"convenience_area_motion"}
]}
]])

BODY.security_area_motion = fill([[
{"errors":[],"data":[
{"id":"$sec1",
 "owner":{"rid":"$area1","rtype":"motion_area_configuration"},
 "enabled":true,
 "motion":{"motion":false,"motion_valid":false,
  "motion_report":{"changed":"2026-10-19T18:22:03.115Z","motion":false}},
 "sensitivity":{"sensitivity":2,"sensitivity_max":4},
 "type":"security_area_motion"}
]}
]])

BODY.motion_area_candidate = fill([[
{"errors":[],"data":[
{"id":"$cand11","owner":{"rid":"$dev11","rtype":"device"},"capabilities":["sensor","collector","sync"],
 "type":"motion_area_candidate"},
{"id":"$cand12","owner":{"rid":"$dev12","rtype":"device"},"capabilities":["sensor","collector","sync"],
 "type":"motion_area_candidate"},
{"id":"$cand13","owner":{"rid":"$dev13","rtype":"device"},"capabilities":["sensor","collector","sync"],
 "type":"motion_area_candidate"},
{"id":"$cand14","owner":{"rid":"$dev14","rtype":"device"},"capabilities":["sensor","collector","sync"],
 "type":"motion_area_candidate"}
]}
]])

BODY.camera_motion = '{"errors":[],"data":[]}'
BODY.tamper = '{"errors":[],"data":[]}'
BODY.contact = fill([[
{"errors":[],"data":[
{"id":"$contact1","owner":{"rid":"$dev41","rtype":"device"},"enabled":true,
 "contact_report":{"changed":"2026-10-26T06:30:00.000Z","state":"contact"},"type":"contact"}
]}
]])

BODY.room = fill([[
{"errors":[],"data":[
{"id":"$room1","id_v1":"/groups/7",
 "children":[{"rid":"$dev21","rtype":"device"},{"rid":"$dev1","rtype":"device"}],
 "services":[{"rid":"$gl1","rtype":"grouped_light"},{"rid":"$gm1","rtype":"grouped_motion"},
  {"rid":"$gll1","rtype":"grouped_light_level"}],
 "metadata":{"name":"$name_room1","archetype":"hallway"},
 "type":"room"},
{"id":"$room2","id_v1":"/groups/8",
 "children":[{"rid":"$dev11","rtype":"device"},{"rid":"$dev12","rtype":"device"},{"rid":"$dev13","rtype":"device"},
  {"rid":"$dev14","rtype":"device"}],
 "services":[{"rid":"$gl2","rtype":"grouped_light"}],
 "metadata":{"name":"$name_room2","archetype":"kitchen"},
 "type":"room"}
]}
]])

BODY.zone = fill([[
{"errors":[],"data":[
{"id":"$zone1","id_v1":"/groups/9",
 "children":[{"rid":"$lamp11","rtype":"light"},{"rid":"$lamp21","rtype":"light"}],
 "services":[{"rid":"$glz","rtype":"grouped_light"}],
 "metadata":{"name":"$name_zone1","archetype":"downstairs"},
 "type":"zone"}
]}
]])

BODY.bridge_home = fill([[
{"errors":[],"data":[
{"id":"$home","id_v1":"/groups/0",
 "children":[{"rid":"$dev2","rtype":"device"},{"rid":"$devb","rtype":"device"},{"rid":"$dev31","rtype":"device"},
  {"rid":"$room1","rtype":"room"},{"rid":"$room2","rtype":"room"}],
 "services":[{"rid":"$glhome","rtype":"grouped_light"},{"rid":"$gmhome","rtype":"grouped_motion"},
  {"rid":"$gllhome","rtype":"grouped_light_level"}],
 "type":"bridge_home"}
]}
]])

-- The Hue automations (#280). The shapes follow aiohue's models and the one
-- instance and eight scripts recorded in Home Assistant's fixture (a Timers
-- instance: duration, what with a recipe, where, dependees, state.timer_state).
-- The MotionAware script's name and its instance's configuration are
-- invented: no public source shows the automation the Hue app adds to an
-- area; the tester's bridge and the house will.
BODY.behavior_script = fill([[
{"errors":[],"data":[
{"id":"$script1","type":"behavior_script","version":"0.0.1","description":"Countdown timer",
 "metadata":{"name":"Timers","category":"automation"},"configuration_schema":{"$ref":"timer_config.json#"},
 "trigger_schema":{"$ref":"trigger.json#"},"state_schema":{"$ref":"timer_state.json#"}},
{"id":"$script2","type":"behavior_script","version":"0.0.1","description":"Lights on when someone comes home",
 "metadata":{"name":"Coming home"},"configuration_schema":{"$ref":"coming_home_config.json#"},
 "trigger_schema":{"$ref":"trigger.json#"},"state_schema":{}},
{"id":"$script3","type":"behavior_script","version":"0.0.1","description":"Lights follow motion in an area",
 "metadata":{"name":"MotionAware","category":"automation"},
 "configuration_schema":{"$ref":"motion_aware_config.json#"},"trigger_schema":{},"state_schema":{}},
{"id":"$script4","type":"behavior_script","version":"0.0.1","description":"Light state after streaming",
 "metadata":{"name":"Light state after streaming","category":"entertainment"},
 "configuration_schema":{"$ref":"lights_state_after_streaming_config.json#"},"trigger_schema":{},
 "state_schema":{}}
]}
]])

BODY.behavior_instance = fill([[
{"errors":[],"data":[
{"id":"$inst1","type":"behavior_instance","script_id":"$script1","enabled":true,
 "state":{"timer_state":"stopped"},
 "configuration":{"duration":{"seconds":60},
  "what":[{"group":{"rid":"$room1","rtype":"room"},"recall":{"rid":"$recipe1","rtype":"recipe"}}],
  "where":[{"group":{"rid":"$room1","rtype":"room"}}]},
 "dependees":[{"target":{"rid":"$room1","rtype":"room"},"level":"critical","type":"ResourceDependee"}],
 "status":"running","last_error":"","metadata":{"name":"$name_inst1"}},
{"id":"$inst2","type":"behavior_instance","script_id":"$script3","enabled":true,
 "configuration":{"source":{"rid":"$area1","rtype":"motion_area_configuration"},
  "settings":{"daylight_sensitivity":{"dark_threshold":16000,"offset":7000}},
  "when":{"timeslots":[{"start_time":{"kind":"time","time":{"hour":7,"minute":0,"second":0}},
   "on":{"recall":{"rid":"$scene1","rtype":"scene"}},"off_after":{"seconds":300}}]},
  "where":[{"group":{"rid":"$room2","rtype":"room"}}]},
 "dependees":[{"target":{"rid":"$area1","rtype":"motion_area_configuration"},"level":"critical",
  "type":"ResourceDependee"},{"target":{"rid":"$room2","rtype":"room"},"level":"non_critical",
  "type":"ResourceDependee"}],
 "status":"running","last_error":"","metadata":{"name":"$name_inst2"}},
{"id":"$inst3","type":"behavior_instance","script_id":"$script2","enabled":false,
 "migrated_from":"/resourcelinks/12345",
 "configuration":{"who":[{"rid":"$geo1","rtype":"geofence_client"}],
  "when":{"time_point":{"type":"time","time":{"hour":18,"minute":30}},"recurrence_days":["monday","friday"]},
  "where":[{"group":{"rid":"$room1","rtype":"room"}}]},
 "dependees":[],"status":"disabled","last_error":"","metadata":{"name":"$name_inst3"}}
]}
]])

-- HR §5.4, one SSE data line (an array of containers) each; E13 is the
-- traffic of the other resources.
local E = {}
E[1] = fill([[
[{"creationtime":"2026-10-26T07:15:02Z","data":[{"id":"$motion1","id_v1":"/sensors/12","motion":{"motion":true,
"motion_report":{"changed":"2026-10-26T07:15:02.087Z","motion":true},"motion_valid":true},"owner":{"rid":"$dev1",
"rtype":"device"},"type":"motion"},{"id":"$gm1","motion":{"motion_report":{"changed":"2026-10-26T07:15:02.140Z",
"motion":true}},"owner":{"rid":"$room1","rtype":"room"},"type":"grouped_motion"},{"id":"$gmhome","motion":{
"motion_report":{"changed":"2026-10-26T07:15:02.141Z","motion":true}},"owner":{"rid":"$home","rtype":"bridge_home"},
"type":"grouped_motion"}],"id":"$e1","type":"update"}]
]])
E[2] = fill([[
[{"creationtime":"2026-10-26T07:15:16Z","data":[{"id":"$motion1","id_v1":"/sensors/12","motion":{"motion":false,
"motion_report":{"changed":"2026-10-26T07:15:16.502Z","motion":false},"motion_valid":true},"owner":{"rid":"$dev1",
"rtype":"device"},"type":"motion"},{"id":"$gm1","motion":{"motion_report":{"changed":"2026-10-26T07:15:16.560Z",
"motion":false}},"owner":{"rid":"$room1","rtype":"room"},"type":"grouped_motion"},{"id":"$gmhome","motion":{
"motion_report":{"changed":"2026-10-26T07:15:16.561Z","motion":false}},"owner":{"rid":"$home","rtype":"bridge_home"},
"type":"grouped_motion"}],"id":"$e2","type":"update"}]
]])
E[3] = fill([[
[{"creationtime":"2026-10-26T07:16:40Z","data":[{"id":"$light1","id_v1":"/sensors/13","light":{"light_level":21000,
"light_level_report":{"changed":"2026-10-26T07:16:39.877Z","light_level":21000},"light_level_valid":true},
"owner":{"rid":"$dev1","rtype":"device"},"type":"light_level"},{"id":"$gll1","light":{"light_level_report":{
"changed":"2026-10-26T07:16:39.950Z","light_level":21000}},"owner":{"rid":"$room1","rtype":"room"},
"type":"grouped_light_level"}],"id":"$e3","type":"update"}]
]])
E[4] = fill([[
[{"creationtime":"2026-10-26T07:18:05Z","data":[{"id":"$temp2","id_v1":"/sensors/22","owner":{"rid":"$dev2",
"rtype":"device"},"temperature":{"temperature":14.88,"temperature_report":{"changed":"2026-10-26T07:18:04.610Z",
"temperature":14.88},"temperature_valid":true},"type":"temperature"}],"id":"$e4","type":"update"}]
]])
E[5] = fill([[
[{"creationtime":"2026-10-26T07:20:31Z","data":[{"id":"$zig2","id_v1":"/sensors/20","owner":{"rid":"$dev2",
"rtype":"device"},"status":"connectivity_issue","type":"zigbee_connectivity"}],"id":"$e5","type":"update"}]
]])
E[6] = fill([[
[{"creationtime":"2026-10-26T07:24:10Z","data":[{"enabled":false,"id":"$motion1","id_v1":"/sensors/12",
"owner":{"rid":"$dev1","rtype":"device"},"type":"motion"}],"id":"$e6","type":"update"}]
]])
E[7] = fill([[
[{"creationtime":"2026-10-26T07:25:00Z","data":[{"id":"$motion1","id_v1":"/sensors/12","owner":{"rid":"$dev1",
"rtype":"device"},"sensitivity":{"sensitivity":3,"status":"changing"},"type":"motion"}],"id":"$e7","type":"update"},
{"creationtime":"2026-10-26T07:25:12Z","data":[{"id":"$motion1","id_v1":"/sensors/12","owner":{"rid":"$dev1",
"rtype":"device"},"sensitivity":{"status":"set"},"type":"motion"}],"id":"$e8","type":"update"}]
]])
E[8] = fill([[
[{"creationtime":"2026-10-26T07:30:44Z","data":[{"id":"$conv1","motion":{"motion":true,"motion_report":{
"changed":"2026-10-26T07:30:43.902Z","motion":true},"motion_valid":true},"owner":{"rid":"$area1",
"rtype":"motion_area_configuration"},"type":"convenience_area_motion"}],"id":"$e9","type":"update"},
{"creationtime":"2026-10-26T07:31:20Z","data":[{"id":"$conv1","motion":{"motion":false,"motion_report":{
"changed":"2026-10-26T07:31:19.655Z","motion":false},"motion_valid":true},"owner":{"rid":"$area1",
"rtype":"motion_area_configuration"},"type":"convenience_area_motion"}],"id":"$e10","type":"update"}]
]])
E[9] = fill([[
[{"creationtime":"2026-10-26T07:40:00Z","data":[{"enabled":false,"id":"$area1","type":"motion_area_configuration"}],
"id":"$e11","type":"update"},
{"creationtime":"2026-10-26T07:41:30Z","data":[{"health":"degraded","id":"$area1","participants":[{"resource":{
"rid":"$cand11","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},{"resource":{"rid":"$cand12",
"rtype":"motion_area_candidate"},"status":{"health":"unhealthy"}},{"resource":{"rid":"$cand13",
"rtype":"motion_area_candidate"},"status":{"health":"healthy"}}],"type":"motion_area_configuration"}],"id":"$e12",
"type":"update"}]
]])
E[10] = fill([[
[{"creationtime":"2026-10-26T08:05:00Z","data":[{"id":"$dev3","id_v1":"/sensors/30","identify":{},"metadata":{
"archetype":"unknown_archetype","name":"$name_dev3"},"product_data":{"certified":true,
"hardware_platform_type":"100b-10d","manufacturer_name":"Signify Netherlands B.V.","model_id":"SML001",
"product_archetype":"unknown_archetype","product_name":"Hue motion sensor","software_version":"2.85.1"},
"services":[{"rid":"$motion3","rtype":"motion"},{"rid":"$power3","rtype":"device_power"},{"rid":"$zig3",
"rtype":"zigbee_connectivity"},{"rid":"$light3","rtype":"light_level"},{"rid":"$temp3","rtype":"temperature"},
{"rid":"$swu3","rtype":"device_software_update"}],"type":"device"},{"enabled":true,"id":"$motion3",
"id_v1":"/sensors/30","motion":{"motion":false,"motion_report":{"changed":"2026-10-26T08:04:58.310Z",
"motion":false},"motion_valid":true},"owner":{"rid":"$dev3","rtype":"device"},"sensitivity":{"sensitivity":2,
"sensitivity_max":2,"status":"set"},"type":"motion"},{"id":"$power3","id_v1":"/sensors/30","owner":{"rid":"$dev3",
"rtype":"device"},"power_state":{"battery_level":100,"battery_state":"normal"},"type":"device_power"},{"id":"$zig3",
"id_v1":"/sensors/30","mac_address":"$mac3","owner":{"rid":"$dev3","rtype":"device"},"status":"connected",
"type":"zigbee_connectivity"},{"enabled":true,"id":"$light3","id_v1":"/sensors/31","light":{"light_level":9141,
"light_level_report":{"changed":"2026-10-26T08:04:58.402Z","light_level":9141},"light_level_valid":true},
"owner":{"rid":"$dev3","rtype":"device"},"type":"light_level"},{"enabled":true,"id":"$temp3","id_v1":"/sensors/32",
"owner":{"rid":"$dev3","rtype":"device"},"temperature":{"temperature":20.56,"temperature_report":{
"changed":"2026-10-26T08:04:58.455Z","temperature":20.56},"temperature_valid":true},"type":"temperature"},{
"id":"$swu3","owner":{"rid":"$dev3","rtype":"device"},"problems":[],"state":"no_update",
"type":"device_software_update"}],"id":"$e13","type":"add"}]
]])
E[11] = fill([[
[{"creationtime":"2026-10-26T08:20:00Z","data":[{"id":"$motion3","type":"motion"},{"id":"$light3",
"type":"light_level"},{"id":"$temp3","type":"temperature"},{"id":"$power3","type":"device_power"},{"id":"$zig3",
"type":"zigbee_connectivity"},{"id":"$swu3","type":"device_software_update"},{"id":"$dev3","type":"device"}],
"id":"$e14","type":"delete"}]
]])
E[12] = fill([[
[{"creationtime":"2026-12-14T03:12:40Z","data":[{"id":"$power1","id_v1":"/sensors/12","owner":{"rid":"$dev1",
"rtype":"device"},"power_state":{"battery_level":9,"battery_state":"low"},"type":"device_power"}],"id":"$e1",
"type":"update"}]
]])
E[13] = fill([[
[{"creationtime":"2026-10-26T07:19:00Z","data":[{"id":"$lamp11","on":{"on":true},"owner":{"rid":"$dev11",
"rtype":"device"},"type":"light"},{"id":"$zig11","owner":{"rid":"$dev11","rtype":"device"},
"status":"connectivity_issue","type":"zigbee_connectivity"},{"id":"$gl2","on":{"on":true},"owner":{"rid":"$room2",
"rtype":"room"},"type":"grouped_light"},{"id":"$contact1","contact_report":{"changed":"2026-10-26T07:19:00.100Z",
"state":"no_contact"},"owner":{"rid":"$dev41","rtype":"device"},"type":"contact"}],"id":"$e2","type":"update"}]
]])

-- An automation switched off, its timer started, a new one added, the first deleted.
E[14] = fill([[
[{"creationtime":"2026-10-26T07:16:00Z","data":[{"enabled":false,"id":"$inst1","type":"behavior_instance"}],
"id":"$e15","type":"update"}]
]])
E[15] = fill([[
[{"creationtime":"2026-10-26T07:16:10Z","data":[{"id":"$inst1","state":{"timer_state":"running"},
"status":"running","type":"behavior_instance"}],"id":"$e16","type":"update"}]
]])
E[16] = fill([[
[{"creationtime":"2026-10-26T07:16:20Z","data":[{"configuration":{"where":[{"group":{"rid":"$room2",
"rtype":"room"}}]},"dependees":[],"enabled":true,"id":"$inst4","last_error":"","metadata":{"name":"$name_inst4"},
"script_id":"$script4","status":"running","type":"behavior_instance"}],"id":"$e17","type":"add"}]
]])
E[17] = fill([[
[{"creationtime":"2026-10-26T07:16:30Z","data":[{"id":"$inst1","type":"behavior_instance"}],"id":"$e18",
"type":"delete"}]
]])

-- Hostile values (no bridge sends these): names holding ids and MACs, names
-- nested in unknown objects and arrays, unknown fields holding names, ids,
-- URLs, addresses and the key, keys that are names or ids, odd id_v1 paths,
-- product fields holding a URL, a MAC and the bridge id.
local HOSTILE_MOTION = fill([[
{"id":"$motion9","id_v1":"/sensors/$dev1",
 "owner":{"rid":"$dev9","rtype":"device"},
 "enabled":true,
 "motion":{"motion_report":{"changed":"yesterday in $name_room1","motion":false},"note":"$name_dev1 near $dev1"},
 "extra":{"deeper":{"name":"$name_room1","label":"$name_room2",
   "href":"https://10.0.2.143/clip/v2/resource/device/$dev1",
   "list":["$name_dev2","$dev2","$mac2"],"$name_room1":true,"$dev3":1,
   "owner_id":"$dev11","display_name":"$name_zone1","bridge_id":"001788fffe123abc"}},
 "description":"$name_room2 sensor near 10.0.2.143",
 "names":["$name_dev2","$name_area1"],
 "auth":"zzzz0000zzzz0000zzzz0000zzzz00",
 "bridge":{"id":"001788fffe123abc","mac":"$macb"},
 "ip_address":"10.0.2.143",
 "url":"/clip/v2/resource/device/$dev2",
 "sensitivity":{"status":"$name_dev2","sensitivity":2,"sensitivity_max":4},
 "type":"motion"}
]])
local HOSTILE_DEVICE = fill([[
{"id":"$dev9","id_v1":"/sensors/$name_room1",
 "product_data":{"model_id":"SML003","product_name":"/clip/v2/resource/device/$dev9",
  "manufacturer_name":"Bridge 001788fffe123abc","software_version":"$mac1","hardware_platform_type":"$dev1"},
 "metadata":{"name":"$dev1 $name_dev1 $mac1","archetype":"$name_room1"},
 "services":[{"rid":"$motion9","rtype":"motion"},{"rid":"$zig9","rtype":"zigbee_connectivity"}],
 "usertest":{"status":"set","usertest":false,"comment":"$name_dev2"},
 "type":"device"}
]])
-- An automation whose configuration holds names, ids inside strings, times
-- and location data, and a script with an id in its name.
local HOSTILE_INSTANCE = fill([[
{"id":"$inst9","script_id":"$script9","enabled":true,
 "metadata":{"name":"Wake $name_room1 at 06:45 $dev1"},
 "state":{"timer_state":"$name_dev2","last_run":"2026-10-26T06:45:00Z","nested":{"name":"$name_room2"}},
 "migrated_from":"/resourcelinks/$name_room1",
 "configuration":{
  "when":{"time_point":{"type":"time","time":{"hour":6,"minute":45,"second":0}},"start_at":"2026-10-27T06:45:00",
   "recurrence_days":["monday","friday"],"changed":"2026-10-26T06:45:00.000Z"},
  "where":[{"group":{"rid":"$room1","rtype":"room"},"label":{"name":"$name_room1"},"note":"near $dev1"},
   {"items":[{"rid":"$lamp21","rtype":"light"}]}],
  "who":[{"rid":"$geo1","rtype":"geofence_client"}],
  "geofence":{"radius":120,"center":{"latitude":-27.4705,"longitude":153.0260}},
  "home_location":{"lat":-27.4705,"lon":153.0260},
  "coordinates":[-27.4705,153.0260],
  "time_zone":"Australia/Brisbane",
  "position":{"x":0.25,"y":-27.4705},
  "address":"12 Vexa Street",
  "target":"/clip/v2/resource/light/$lamp21",
  "resource_id":"$lamp11",
  "names":["$name_dev1"],
  "mac":"$mac1"},
 "dependees":[{"target":{"rid":"$room1","rtype":"room"},"level":"critical","type":"ResourceDependee"}],
 "status":"running","last_error":"Group $name_room1 ($room1) not reachable",
 "type":"behavior_instance"}
]])
local HOSTILE_SCRIPT = fill([[
{"id":"$script9","type":"behavior_script","metadata":{"name":"Wake up $dev1","category":"$name_room1"},
 "description":"$name_room2"}
]])

local HOSTILE_ZIGBEE = fill([[
{"id":"$zig9","id_v1":"/sensors/99","owner":{"rid":"$dev9","rtype":"device"},
 "status":"connected","mac_address":"$mac9","type":"zigbee_connectivity"}
]])

-- `body` (a GET body) with `item` added to its data.
local function with_item(body, item)
	return (body:gsub("%]}$", "," .. item .. "]}"))
end

local function deep_copy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[k] = deep_copy(x)
	end
	return out
end

local START_TEXT = "Motion diagnostics start in 20 seconds: open this bridge's Lua tab now. The pass and 10 "
	.. "minutes of events follow; copy them into the Beta feedback issue."

describe("bridge.motion_diag", function()
	local motion_diag, c4, M, logged, pending, answers, dones
	local original_sink = log.sink

	-- A GET the module started: answered by the spec, one at a time.
	local function http(req, cb)
		pending[#pending + 1] = { req = req, cb = cb }
	end

	local function new_diag(extra)
		local ctx = {
			http = http,
			on_done = function(text) dones[#dones + 1] = text end,
			secrets = function() return { key = APP_SECRET, ip = BRIDGE_IP, bridge_id = BRIDGE_ID } end,
		}
		for k, v in pairs(extra or {}) do
			ctx[k] = v
		end
		return motion_diag.new(ctx)
	end

	local function answered(ok, text)
		answers[#answers + 1] = { ok = ok, text = text }
	end

	-- Answer the one GET in flight: `overrides[type]` is a body (a 200) or a
	-- whole result; a type without a body answers 404 as a bridge without it.
	local function answer_next(overrides)
		assert.equal(1, #pending, "exactly one GET in flight")
		local p = table.remove(pending, 1)
		assert.equal("GET", p.req.method)
		assert.is_true(p.req.quiet)
		local typ = p.req.path:match("^/clip/v2/resource/([%w_]+)$")
		assert.truthy(typ, p.req.path)
		local o = overrides and overrides[typ]
		local result
		if type(o) == "table" then
			result = o
		else
			local body = o or BODY[typ]
			if body then
				result = { ok = true, code = 200, body = body, json = C4:JsonDecode(body) }
			else
				result = { ok = false, code = 404, err = "HTTP 404",
					json = { errors = { { description = "Not Found" } }, data = {} } }
			end
		end
		p.cb(result)
		return typ
	end

	local function answer_all(overrides)
		local types = {}
		while #pending > 0 do
			types[#types + 1] = answer_next(overrides)
		end
		return types
	end

	-- Click, wait the 20 s, answer every GET.
	local function run_pass(overrides)
		M:run(answered)
		c4.now_ms = c4.now_ms + motion_diag.WAIT_MS
		assert.equal(1, c4.fire_timers(), "the wait's timer")
		return answer_all(overrides)
	end

	-- One SSE data line through the capture, received `after_ms` after the pass began.
	local function feed(text, after_ms)
		if after_ms then
			c4.now_ms = PASS_MS + after_ms
		end
		local n = 0
		for _, container in ipairs(C4:JsonDecode(text)) do
			n = n + M:on_container(container)
		end
		return n
	end

	local function output()
		return table.concat(logged, "\n")
	end

	local function saw(text)
		return output():find(text, 1, true) ~= nil
	end

	-- The logged lines holding every text given.
	local function lines_with(...)
		local texts, out = { ... }, {}
		for _, l in ipairs(logged) do
			local all = true
			for _, text in ipairs(texts) do
				all = all and l:find(text, 1, true) ~= nil
			end
			if all then
				out[#out + 1] = l
			end
		end
		return out
	end

	-- The one logged line that starts with `start` (after "diag: ").
	local function line(start)
		local found = {}
		for _, l in ipairs(logged) do
			if l:sub(1, #start + 6) == "diag: " .. start then
				found[#found + 1] = l
			end
		end
		assert.equal(1, #found, "lines starting with " .. start .. ":\n" .. table.concat(found, "\n"))
		return found[1]
	end

	-- The whole of the one logical line that starts with `start`: its first
	-- piece and its continuation lines, joined as a reader would.
	local function whole(start)
		local first = line(start)
		local parts
		for _, l in ipairs(logged) do
			if parts and l:match("^diag: %+%d+ ") then
				parts[#parts + 1] = l:gsub("^diag: %+%d+ ", "", 1)
			elseif parts then
				break
			elseif l == first then
				parts = { first }
			end
		end
		return table.concat(parts, " ")
	end

	local function count_from(first)
		return #logged - first + 1
	end

	-- Nothing of `secret` in `text`, in any case.
	local function absent(text, secret, what)
		assert.is_nil(text:lower():find(secret:lower(), 1, true), (what or secret) .. " leaked:\n" .. text)
	end

	-- The sweep's checks over everything logged and answered; `forbidden`
	-- lists more texts that must not appear.
	local function assert_redacted(extra_text, forbidden)
		local text = output() .. "\n" .. table.concat(dones, "\n") .. "\n" .. (extra_text or "")
		for _, a in ipairs(answers) do
			text = text .. "\n" .. a.text
		end
		for key, name in pairs(NAMES) do
			absent(text, name, key)
		end
		for _, word in ipairs({ "vexa", "quorn", "zubb" }) do
			absent(text, word)
		end
		for key, id in pairs(V) do
			absent(text, id, key)
			absent(text, id:sub(1, 8), key .. "'s first 8")
			absent(text, id:sub(25), key .. "'s last 12")
		end
		for key, mac in pairs(MACS) do
			absent(text, mac, key)
		end
		absent(text, "00:17:88")
		absent(text, BRIDGE_ID)
		absent(text, "fffe123abc")
		absent(text, BRIDGE_IP)
		absent(text, APP_SECRET)
		for _, f in ipairs(forbidden or {}) do
			absent(text, f)
		end
		for _, l in ipairs(logged) do
			assert.is_nil(l:find("%c"), "a control character in: " .. l)
			assert.is_nil(l:find("%d%d:%d%d"), "a clock time in: " .. l)
			assert.equal("diag: ", l:sub(1, 6))
			assert.is_true(#l <= #motion_diag.CONTINUED + 2 + motion_diag.LINE_MAX, "too long: " .. l)
		end
	end

	before_each(function()
		logged = {}
		log.sink = function(l) logged[#logged + 1] = l end
		log.set_prefix(nil)
		log.set_debug(false)
		c4 = fake.install_c4({ ["Bridge Model"] = "Hue Bridge Pro (BSB003)",
			["Bridge Firmware"] = "1.77.2071353020 (API 1.77.0)", ["Driver Version"] = "271",
			["Bridge Name"] = "Zubb house bridge" })
		c4.now_ms = RUN_MS
		package.loaded["bridge.motion_diag"] = nil
		motion_diag = require("bridge.motion_diag")
		pending, answers, dones = {}, {}, {}
		M = new_diag()
	end)

	after_each(function()
		log.sink = original_sink
	end)

	describe("new", function()
		it("requires http, and neither captures nor logs before a run", function()
			assert.has_error(function() motion_diag.new({}) end)
			assert.is_false(M:capturing())
			assert.equal(0, M:on_container(C4:JsonDecode(E[1])[1]))
			assert.equal(0, #logged)
		end)
	end)

	describe("run", function()
		it("answers at once with the start time and waits 20 s on the ctx timer before the first GET", function()
			M:run(answered)
			assert.same({ { ok = true, text = START_TEXT } }, answers)
			assert.equal(0, #pending, "nothing fetched during the wait")
			assert.equal(0, #logged)
			local timers = c4.active_timers()
			assert.equal(1, #timers)
			assert.equal(20000, timers[1].delay)
			assert.is_false(M:capturing())
			assert.equal(0, M:on_container(C4:JsonDecode(E[1])[1]), "no capture during the wait")

			c4.now_ms = PASS_MS
			c4.fire_timers()
			assert.equal(1, #pending)
			assert.same({ path = "/clip/v2/resource/clip", method = "GET", quiet = true }, pending[1].req)
			assert.equal("diag: motion diagnostics, run 1: one GET per type, then 600 s of events in at most 200 lines",
				logged[1])
		end)

		it("fetches every type one GET at a time, in the order of HR §6.1", function()
			local types = run_pass()
			assert.same({ "clip", "motion", "light_level", "temperature", "device", "device_power", "zigbee_connectivity",
				"device_software_update", "grouped_motion", "grouped_light_level", "service_group",
				"motion_area_configuration", "convenience_area_motion", "security_area_motion", "motion_area_candidate",
				"camera_motion", "contact", "tamper", "room", "zone", "bridge_home", "behavior_script",
				"behavior_instance" }, types)
			for i, step in ipairs(motion_diag.STEPS) do
				assert.equal(step.type, types[i])
			end
		end)

		it("ends the pass with the counts and the pass-done line, then captures for 10 minutes", function()
			run_pass()
			assert.equal("diag: Motion diagnostics: pass done (2 sensors, 1 area, 3 automations); capturing events "
				.. "for 10 minutes.", logged[#logged])
			assert.equal("diag: counts: clip 26 types, motion 2, light_level 2, temperature 2, device 6 (2 sensors), "
				.. "device_power 3 (2 owned by sensors), zigbee_connectivity 5 (2 owned by sensors), "
				.. "device_software_update 3 (2 owned by sensors), grouped_motion 3, grouped_light_level 3, "
				.. "service_group 1, motion_area_configuration 1, convenience_area_motion 1, security_area_motion 1, "
				.. "motion_area_candidate 4, camera_motion 0, contact 1, tamper 0, room 2 (1 with sensors), zone 1 (0 "
				.. "with sensors), bridge_home 1 (1 with sensors), behavior_script 4, behavior_instance 3", whole("counts:"))
			assert.is_true(M:capturing())
			local timers = c4.active_timers()
			assert.equal(1, #timers)
			assert.equal(600000, timers[1].delay)
			assert.equal(1, #answers, "the action answered once, at the click")
			assert.equal(0, #dones)
		end)

		it("restarts the wait when run again while it waits", function()
			M:run(answered)
			local first = c4.active_timers()[1]
			c4.now_ms = RUN_MS + 5000
			M:run(answered)
			assert.is_false(first.active, "the first wait is cancelled")
			assert.equal(1, #c4.active_timers())
			assert.equal(2, #answers)
			assert.equal(START_TEXT, answers[2].text)
			assert.equal("diag: restarted: the pass starts again in 20 s", logged[1])
			c4.now_ms = PASS_MS + 5000
			assert.equal(1, c4.fire_timers())
			assert.equal(1, #pending, "one pass")
			assert.equal(#motion_diag.STEPS, #answer_all())
			assert.is_true(M:capturing())
		end)

		it("drops a pass that is under way when run again, and fetches everything again after the new wait", function()
			M:run(answered)
			c4.now_ms = PASS_MS
			c4.fire_timers()
			for _ = 1, 4 do
				answer_next()
			end
			local stale = table.remove(pending, 1)  -- the device GET of the first pass, still in flight
			M:run(answered)
			assert.truthy(saw("diag: pass cut short: restarted"))
			local before = #logged
			stale.cb({ ok = true, code = 200, json = C4:JsonDecode(BODY.device) })
			assert.equal(before, #logged, "the dropped pass's answer is ignored")
			assert.equal(0, #pending, "and starts no GET")
			c4.now_ms = PASS_MS + 20000
			assert.equal(1, c4.fire_timers())
			local types = answer_all()
			assert.equal(#motion_diag.STEPS, #types)
			assert.equal("clip", types[1])
			assert.truthy(saw("diag: motion diagnostics, run 2:"))
			assert.truthy(saw("metadata.name=name#1 "), "the new run counts names from 1 again")
		end)

		it("ends the capture and starts the window over when run again while capturing", function()
			run_pass()
			local capture_timer = c4.active_timers()[1]
			assert.equal(1, feed(E[6], 30000))
			M:run(answered)
			assert.is_false(M:capturing())
			assert.is_false(capture_timer.active)
			assert.equal(1, #lines_with("capture end (restarted) at +30.00s: 1 item logged"))
			assert.equal(1, #dones)
			assert.equal(0, feed(E[6], 31000), "no capture between the runs")
			c4.now_ms = PASS_MS + 50000
			assert.equal(1, c4.fire_timers())
			answer_all()
			assert.is_true(M:capturing())
			local timers = c4.active_timers()
			assert.equal(1, #timers)
			assert.equal(600000, timers[1].delay)
			assert.equal("diag: Motion diagnostics: pass done (2 sensors, 1 area, 3 automations); capturing events "
				.. "for 10 minutes.", logged[#logged])
			c4.now_ms = PASS_MS + 50000 + 599000
			assert.is_true(M:capturing(), "the new window runs from the new pass")
			assert.equal(1, feed(E[6]))
		end)

		it("stops after three GETs without an answer and captures nothing", function()
			local failure = { ok = false, err = "not paired" }
			M:run(answered)
			c4.now_ms = PASS_MS
			c4.fire_timers()
			local types = answer_all({ clip = failure, motion = failure, light_level = failure })
			assert.same({ "clip", "motion", "light_level" }, types)
			assert.truthy(saw("diag: GET clip: no answer (not paired)"))
			assert.truthy(saw("diag: pass stopped: 3 GETs in a row without an answer"))
			assert.truthy(saw("clip no answer, motion no answer, light_level no answer, temperature not fetched"))
			assert.equal("diag: Motion diagnostics: pass failed, the bridge did not answer (not paired); no capture.",
				logged[#logged])
			assert.is_false(M:capturing())
			assert.equal(0, #c4.active_timers())
			assert.same({ "Motion diagnostics stopped: the bridge did not answer (not paired). See the Lua output." },
				dones)
		end)

		it("moves on once when a GET raises or calls back twice", function()
			local calls = 0
			M = new_diag({ http = function(req, cb)
				calls = calls + 1
				if req.path:find("light_level", 1, true) then
					error("transfer refused")
				elseif req.path:find("/motion$") then
					cb({ ok = true, code = 200, json = C4:JsonDecode(BODY.motion) })
					cb({ ok = true, code = 200, json = C4:JsonDecode(BODY.motion) })
					return
				end
				http(req, cb)
			end })
			M:run(answered)
			c4.now_ms = PASS_MS
			c4.fire_timers()
			answer_next()  -- clip, then motion answers twice and light_level raises
			assert.equal(1, #lines_with("GET motion: HTTP 200"))
			assert.equal(1, #lines_with("GET light_level: no answer (request failed: "))
			assert.equal("/clip/v2/resource/temperature", pending[1].req.path)
			assert.equal(4, calls)
			answer_all()
			assert.is_true(M:capturing())
		end)

		it("runs the pass at once when no timer can be made", function()
			M = new_diag({ set_timer = function() error("no timers here") end })
			M:run(answered)
			assert.equal(START_TEXT:gsub("start in 20 seconds", "start now"), answers[1].text)
			assert.equal(1, #pending)
			answer_all()
			assert.is_true(M:capturing(), "the clock still ends it")
			c4.now_ms = RUN_MS + 600000
			assert.is_false(M:capturing())
			assert.equal(1, #lines_with("capture end (time) at +600.00s"))
		end)
	end)

	describe("the pass", function()
		it("logs the bridge, the served types, and which sensor and MotionAware types are missing", function()
			run_pass()
			assert.equal("diag: bridge: model \"Hue Bridge Pro (BSB003)\", firmware \"1.77.2071353020 (API 1.77.0)\"; "
				.. "controller OS \"3.4.2 build 746094\"; driver version \"271\"", line("bridge:"))
			assert.equal("diag: GET clip: HTTP 200, errors 0, 26 types: behavior_instance behavior_script bridge "
				.. "bridge_home button "
				.. "camera_motion contact convenience_area_motion device device_power device_software_update "
				.. "grouped_light grouped_light_level grouped_motion light light_level motion motion_area_configuration "
				.. "room scene security_area_motion service_group tamper temperature zigbee_connectivity zone",
				line("GET clip:"))
			assert.equal("diag: clip: sensor types served: motion light_level temperature device_power "
				.. "zigbee_connectivity device_software_update grouped_motion grouped_light_level service_group "
				.. "camera_motion contact tamper; not served: none. MotionAware types served: motion_area_configuration "
				.. "convenience_area_motion security_area_motion; not served: motion_area_candidate", line("clip:"))
		end)

		it("logs each sensor resource's key paths, types and values (HR §6.2)", function()
			run_pass()
			assert.equal("diag: GET motion: HTTP 200, errors 0, 2 items", line("GET motion:"))
			assert.equal("diag: motion " .. A("motion1") .. " enabled=true id_v1=\"/sensors/12\" motion.motion=false "
				.. "motion.motion_report.changed=-738.68s motion.motion_report.motion=false motion.motion_valid=true "
				.. "owner=device:" .. A("dev1") .. " sensitivity.sensitivity=2 sensitivity.sensitivity_max=4 "
				.. "sensitivity.status=\"set\"", line("motion " .. A("motion1")))
			assert.equal("diag: light_level " .. A("light2") .. " enabled=true id_v1=\"/sensors/21\" "
				.. "light.light_level=32480(1770lx) light.light_level_report.changed=-328.59s "
				.. "light.light_level_report.light_level=32480(1770lx) light.light_level_valid=true owner=device:"
				.. A("dev2"), line("light_level " .. A("light2")))
			assert.truthy(line("light_level " .. A("light1")):find("light.light_level=18027(63.5lx)", 1, true))
			assert.equal("diag: temperature " .. A("temp1") .. " enabled=true id_v1=\"/sensors/14\" owner=device:"
				.. A("dev1") .. " temperature.temperature=21.37 temperature.temperature_report.changed=-399.45s "
				.. "temperature.temperature_report.temperature=21.37 temperature.temperature_valid=true",
				line("temperature " .. A("temp1")))
			assert.equal("diag: device_power " .. A("power1") .. " id_v1=\"/sensors/12\" owner=device:" .. A("dev1")
				.. " power_state.battery_level=87 power_state.battery_state=\"normal\"", line("device_power " .. A("power1")))
			assert.equal("diag: zigbee_connectivity " .. A("zig1") .. " channel.status=\"set\" channel.value=<str:10> "
				.. "extended_pan_id=<pan> id_v1=\"/sensors/12\" mac_address=<mac> owner=device:" .. A("dev1")
				.. " status=\"connected\"", line("zigbee_connectivity " .. A("zig1")))
			assert.equal("diag: device_software_update " .. A("swu2") .. " owner=device:" .. A("dev2")
				.. " problems=[] state=\"no_update\"", line("device_software_update " .. A("swu2")))
			assert.equal("diag: grouped_light_level " .. A("gllsg") .. " enabled=true "
				.. "light.light_level_report.changed=-181.91s light.light_level_report.light_level=0(dark) "
				.. "owner=service_group:" .. A("sg1"), line("grouped_light_level " .. A("gllsg")))
		end)

		it("logs a sensor device whole, its long line continued on the next", function()
			run_pass()
			local first = line("device " .. A("dev1"))
			local i
			for n, l in ipairs(logged) do
				if l == first then
					i = n
				end
			end
			assert.equal("diag: +2 ", logged[i + 1]:sub(1, 9))
			if logged[i + 2] and logged[i + 2]:match("^diag: %+%d+ ") then
				assert.equal("diag: +3 ", logged[i + 2]:sub(1, 9), "numbered in order")
			end
			assert.equal("diag: device " .. A("dev1") .. " id_v1=\"/sensors/12\" identify={} "
				.. "metadata.archetype=\"unknown_archetype\" metadata.name=name#1 product_data.certified=true "
				.. "product_data.hardware_platform_type=\"100b-11b\" product_data.manufacturer_name=\"Signify "
				.. "Netherlands B.V.\" product_data.model_id=\"SML003\" product_data.product_archetype="
				.. "\"unknown_archetype\" product_data.product_name=\"Hue motion sensor\" "
				.. "product_data.software_version=\"2.85.1\" services=[zigbee_connectivity:" .. A("zig1") .. ",motion:"
				.. A("motion1") .. ",device_power:" .. A("power1") .. ",light_level:" .. A("light1") .. ",temperature:"
				.. A("temp1") .. ",device_software_update:" .. A("swu1") .. "] usertest.status=\"set\" "
				.. "usertest.usertest=false", first .. " " .. logged[i + 1]:sub(10))
			assert.is_true(#first <= 6 + motion_diag.LINE_MAX)
			assert.truthy(line("device " .. A("dev2")):find("metadata.name=name#2 ", 1, true))
		end)

		it("logs only the sensors among the devices, and only the sensors' items of the shared types", function()
			run_pass()
			assert.equal("diag: GET device: HTTP 200, errors 0, 6 items, 2 sensors", line("GET device:"))
			assert.equal("diag: GET device_power: HTTP 200, errors 0, 3 items, 2 owned by sensors", line("GET device_power:"))
			assert.equal("diag: GET zigbee_connectivity: HTTP 200, errors 0, 5 items, 2 owned by sensors",
				line("GET zigbee_connectivity:"))
			for _, key in ipairs({ "dev11", "dev21", "devb", "dev31", "power31", "zig11", "zigb", "zig31", "swu11" }) do
				assert.equal(0, #lines_with(" " .. A(key) .. " "), key .. " is not a sensor's")
			end
		end)

		it("links resources through aliases that stay the same for the whole run", function()
			run_pass()
			assert.equal("diag: room " .. A("room1") .. " services=[grouped_light:" .. A("gl1") .. ",grouped_motion:"
				.. A("gm1") .. ",grouped_light_level:" .. A("gll1") .. "] children=2 sensors=[device:" .. A("dev1") .. "]",
				line("room "))
			assert.equal("diag: GET room: HTTP 200, errors 0, 2 items, 1 with motion services or sensors", line("GET room:"))
			assert.equal("diag: GET zone: HTTP 200, errors 0, 1 item, 0 with motion services or sensors", line("GET zone:"))
			assert.equal("diag: bridge_home " .. A("home") .. " services=[grouped_light:" .. A("glhome")
				.. ",grouped_motion:" .. A("gmhome") .. ",grouped_light_level:" .. A("gllhome") .. "] children=5 "
				.. "sensors=[device:" .. A("dev2") .. "]", line("bridge_home "))
			assert.equal("diag: grouped_motion " .. A("gm1") .. " enabled=true motion.motion_report.changed=-738.60s "
				.. "motion.motion_report.motion=false owner=room:" .. A("room1"), line("grouped_motion " .. A("gm1")))
			assert.equal("diag: service_group " .. A("sg1") .. " children=[motion:" .. A("motion1") .. ",light_level:"
				.. A("light1") .. ",motion:" .. A("motion2") .. ",light_level:" .. A("light2") .. "] metadata.name=name#3 "
				.. "services=[grouped_motion:" .. A("gmsg") .. ",grouped_light_level:" .. A("gllsg") .. "]",
				line("service_group " .. A("sg1")))
			assert.equal("diag: motion_area_configuration " .. A("area1") .. " enabled=true group=room:" .. A("room2")
				.. " health=\"healthy\" name=name#4 participants=[{resource=motion_area_candidate:" .. A("cand11")
				.. " status.health=\"healthy\"},{resource=motion_area_candidate:" .. A("cand12")
				.. " status.health=\"healthy\"},{resource=motion_area_candidate:" .. A("cand13")
				.. " status.health=\"healthy\"}] services=[convenience_area_motion:" .. A("conv1")
				.. ",security_area_motion:" .. A("sec1") .. "]", line("motion_area_configuration " .. A("area1")))
			assert.equal("diag: security_area_motion " .. A("sec1") .. " enabled=true motion.motion=false "
				.. "motion.motion_report.changed=-564776.88s motion.motion_report.motion=false motion.motion_valid=false "
				.. "owner=motion_area_configuration:" .. A("area1") .. " sensitivity.sensitivity=2 "
				.. "sensitivity.sensitivity_max=4", line("security_area_motion " .. A("sec1")))
			assert.equal("diag: motion_area_candidate " .. A("cand14") .. " capabilities=[\"sensor\",\"collector\","
				.. "\"sync\"] owner=device:" .. A("dev14"), line("motion_area_candidate " .. A("cand14")))
		end)

		it("counts cameras, contact sensors and tampers without logging their items", function()
			run_pass()
			assert.equal("diag: GET contact: HTTP 200, errors 0, 1 item (counted only)", line("GET contact:"))
			assert.equal("diag: GET camera_motion: HTTP 200, errors 0, 0 items (counted only)", line("GET camera_motion:"))
			assert.equal(0, #lines_with(A("contact1")))
		end)

		it("gives one alias to one name, wherever it appears", function()
			local twin = BODY.device:gsub(NAMES.name_dev2, NAMES.name_dev1)
			run_pass({ device = twin, room = BODY.room:gsub(NAMES.name_room1, NAMES.name_dev1) })
			assert.truthy(line("device " .. A("dev1")):find("metadata.name=name#1 ", 1, true))
			assert.truthy(line("device " .. A("dev2")):find("metadata.name=name#1 ", 1, true))
			assert.truthy(saw("metadata.name=name#2 "), "the sensor group's name comes next")
			assert_redacted()
		end)

		it("logs the bridge's rows as unknown when they are missing", function()
			M = new_diag({ bridge_info = function() return {} end })
			run_pass()
			assert.equal("diag: bridge: model unknown, firmware unknown; controller OS unknown; driver version unknown",
				line("bridge:"))
			c4.fire_timers()  -- the first capture ends
			logged = {}
			M = new_diag({ bridge_info = function() error("no rows") end })
			run_pass()
			assert.equal("diag: bridge: model unknown, firmware unknown; controller OS unknown; driver version unknown",
				line("bridge:"))
		end)

		it("gives two ids with the same first 4 characters two aliases (HR §5's coded ids)", function()
			local function coded(prefix, n)
				return string.format("%s000000-0000-4000-8000-%012d", prefix, n)
			end
			local motion = string.format('{"errors":[],"data":[{"id":"%s","owner":{"rid":"%s","rtype":"device"},'
				.. '"type":"motion"},{"id":"%s","owner":{"rid":"%s","rtype":"device"},"type":"motion"}]}',
				coded("a0", 1), coded("de", 1), coded("a0", 2), coded("de", 2))
			local device = string.format('{"errors":[],"data":[{"id":"%s","services":[{"rid":"%s","rtype":"motion"}],'
				.. '"type":"device"},{"id":"%s","services":[{"rid":"%s","rtype":"motion"}],"type":"device"}]}',
				coded("de", 2), coded("a0", 2), coded("de", 1), coded("a0", 1))
			run_pass({ motion = motion, device = device })
			assert.equal("diag: motion a000… owner=device:de00…", line("motion a000… "))
			assert.equal("diag: motion a000…2 owner=device:de00…2", line("motion a000…2 "))
			assert.equal("diag: device de00…2 services=[motion:a000…2]", line("device de00…2 "))
			assert.equal("diag: device de00… services=[motion:a000…]", line("device de00… "))
		end)

		it("shows a bridge without MotionAware: the area types' HTTP status and a plain error description", function()
			local not_found = { ok = false, code = 404, err = "HTTP 404",
				json = { errors = { { description = "Not Found" } }, data = {} } }
			run_pass({ motion_area_configuration = not_found, convenience_area_motion = not_found,
				security_area_motion = not_found, motion_area_candidate = not_found })
			assert.equal("diag: GET motion_area_configuration: HTTP 404, errors 1: \"Not Found\", 0 items",
				line("GET motion_area_configuration:"))
			assert.truthy(saw("motion_area_configuration HTTP 404, convenience_area_motion HTTP 404"))
			assert.equal("diag: Motion diagnostics: pass done (2 sensors, 0 areas, 3 automations); capturing events "
				.. "for 10 minutes.", logged[#logged])
		end)

		it("shows an error description only when it holds nothing but error words", function()
			local function errors(...)
				local list = {}
				for i, d in ipairs({ ... }) do
					list[i] = { description = d }
				end
				return { ok = false, code = 503, json = { errors = list } }
			end
			run_pass({
				clip = errors("Internal error, 503"),
				motion = errors("Quorn Kitchen not found", "resource, /device/" .. V.dev1 .. ", not available",
					"too many requests"),
				contact = errors(("x"):rep(300)),
				tamper = { ok = false, code = 404, json = { errors = "Not Found" } },
				camera_motion = { ok = false, code = 500, body = "<html>Vexa</html>" },
			})
			assert.equal("diag: GET clip: HTTP 503, errors 1: \"Internal error, 503\", no data array", line("GET clip:"))
			assert.equal("diag: GET motion: HTTP 503, errors 3: <text:23>, <text:" .. #("resource, /device/" .. V.dev1
				.. ", not available") .. ">, …, no data array", line("GET motion:"))
			assert.equal("diag: GET contact: HTTP 503, errors 1: <text:300>, no data array", line("GET contact:"))
			assert.equal("diag: GET tamper: HTTP 404, no errors array, no data array", line("GET tamper:"))
			assert.equal("diag: GET camera_motion: HTTP 500, no JSON body", line("GET camera_motion:"))
			assert.truthy(saw("clip HTTP 503, motion HTTP 503,"))
		end)

		it("lists the scripts, and logs every automation with its script, state and configuration (#280)", function()
			run_pass()
			assert.equal("diag: GET behavior_script: HTTP 200, errors 0, 4 items: " .. A("script1") .. " \"Timers\" "
				.. "(automation), " .. A("script2") .. " \"Coming home\" (no category), " .. A("script3")
				.. " \"MotionAware\" (automation), " .. A("script4") .. " \"Light state after streaming\" "
				.. "(entertainment)", line("GET behavior_script:"))
			assert.equal("diag: GET behavior_instance: HTTP 200, errors 0, 3 items", line("GET behavior_instance:"))
			assert.equal("diag: behavior_instance " .. A("inst1") .. " for \"Timers\" (automation) "
				.. "configuration.duration.seconds=60 configuration.what=[{group=room:" .. A("room1")
				.. " recall=recipe:" .. A("recipe1") .. "}] configuration.where=[{group=room:" .. A("room1") .. "}] "
				.. "dependees=[{level=\"critical\" target=room:" .. A("room1") .. " type=<str:16>}] enabled=true "
				.. "last_error=<str:0> metadata.name=name#5 script_id=" .. A("script1")
				.. " state.timer_state=\"stopped\" status=\"running\"", whole("behavior_instance " .. A("inst1")))
			assert.equal("diag: behavior_instance " .. A("inst2") .. " for \"MotionAware\" (automation) "
				.. "configuration.settings.daylight_sensitivity.dark_threshold=16000 "
				.. "configuration.settings.daylight_sensitivity.offset=7000 configuration.source="
				.. "motion_area_configuration:" .. A("area1") .. " configuration.when.timeslots=[{off_after.seconds=300 "
				.. "on.recall=scene:" .. A("scene1") .. " start_time.kind=<str:4> start_time.time.hour=<clock> "
				.. "start_time.time.minute=<clock> start_time.time.second=<clock>}] configuration.where=[{group=room:"
				.. A("room2") .. "}] dependees=[{level=\"critical\" target=motion_area_configuration:" .. A("area1")
				.. " type=<str:16>},{level=\"non_critical\" target=room:" .. A("room2") .. " type=<str:16>}] "
				.. "enabled=true last_error=<str:0> metadata.name=name#6 script_id=" .. A("script3")
				.. " status=\"running\"", whole("behavior_instance " .. A("inst2")))
			assert.equal("diag: behavior_instance " .. A("inst3") .. " for \"Coming home\" (no category) "
				.. "configuration.when.recurrence_days=[<str:6>,<str:6>] configuration.when.time_point.time.hour=<clock> "
				.. "configuration.when.time_point.time.minute=<clock> configuration.when.time_point.type=\"time\" "
				.. "configuration.where=[{group=room:" .. A("room1") .. "}] configuration.who=[geofence_client:"
				.. A("geo1") .. "] dependees=[] enabled=false last_error=<str:0> metadata.name=name#7 "
				.. "migrated_from=\"/resourcelinks/12345\" script_id=" .. A("script2") .. " status=\"disabled\"",
				whole("behavior_instance " .. A("inst3")))
			assert_redacted()
		end)

		it("logs at most 40 automations and counts the rest", function()
			local items = {}
			for i = 1, 45 do
				items[i] = string.format('{"id":"%s","script_id":"%s","enabled":true,"type":"behavior_instance"}',
					invent(3000 + i), V.script1)
			end
			run_pass({ behavior_instance = '{"errors":[],"data":[' .. table.concat(items, ",") .. "]}" })
			assert.equal(40, #lines_with("diag: behavior_instance ", " for \"Timers\" (automation) enabled=true"))
			assert.equal("diag: behavior_instance: 5 more not shown", line("behavior_instance: 5 more"))
			assert.truthy(saw("pass done (2 sensors, 1 area, 45 automations)"))
		end)

		it("names an automation's script as unknown when the scripts are not to be had", function()
			run_pass({ behavior_script = { ok = false, code = 404, json = { errors = {}, data = {} } } })
			assert.truthy(line("behavior_instance " .. A("inst1")):find(A("inst1") .. " for an unknown script "
				.. "configuration.duration.seconds=60", 1, true))
			assert.truthy(saw("behavior_script HTTP 404, behavior_instance 3"))
		end)

		it("logs at most 20 items of a type and counts the rest", function()
			local items = {}
			for i = 1, 25 do
				items[i] = string.format('{"id":"%s","owner":{"rid":"%s","rtype":"device"},"enabled":true,"type":"motion"}',
					invent(1000 + i), V.dev1)
			end
			run_pass({ motion = '{"errors":[],"data":[' .. table.concat(items, ",") .. "]}" })
			assert.equal("diag: GET motion: HTTP 200, errors 0, 25 items", line("GET motion:"))
			local item_lines = 0
			for _, l in ipairs(logged) do
				if l:match("^diag: motion %x%x%x%x…") then
					item_lines = item_lines + 1
				end
			end
			assert.equal(20, item_lines)
			assert.equal("diag: motion: 5 more not shown", line("motion: 5 more"))
			assert.truthy(saw("counts: clip 26 types, motion 25, "))
		end)
	end)

	describe("the capture", function()
		it("logs the sensors' events with their times, the container and the time since the same resource's last",
			function()
				run_pass()
				local first = #logged + 1
				assert.equal(3, feed(E[1], 2500))
				assert.same({
					"diag: +2.50s c#1 update motion " .. A("motion1") .. " (first) created=+2.00s id_v1=\"/sensors/12\" "
						.. "motion.motion=true motion.motion_report.changed=+2.09s motion.motion_report.motion=true "
						.. "motion.motion_valid=true owner=device:" .. A("dev1"),
					"diag: +2.50s c#1 update grouped_motion " .. A("gm1") .. " (first) motion.motion_report.changed=+2.14s "
						.. "motion.motion_report.motion=true owner=room:" .. A("room1"),
					"diag: +2.50s c#1 update grouped_motion " .. A("gmhome") .. " (first) "
						.. "motion.motion_report.changed=+2.14s motion.motion_report.motion=true owner=bridge_home:"
						.. A("home"),
				}, { logged[first], logged[first + 1], logged[first + 2] })
				assert.equal(3, feed(E[2], 16500))
				assert.equal("diag: +16.50s c#2 update motion " .. A("motion1") .. " (14.00s after its last) "
					.. "created=+16.00s id_v1=\"/sensors/12\" motion.motion=false motion.motion_report.changed=+16.50s "
					.. "motion.motion_report.motion=false motion.motion_valid=true owner=device:" .. A("dev1"),
					logged[first + 3])
			end)

		it("logs light level, temperature, connectivity, switching, sensitivity, area and battery events", function()
			run_pass()
			feed(E[3], 100500)
			feed(E[4], 185500)
			feed(E[5], 331500)
			feed(E[6], 550000)
			feed(E[7], 560000)
			feed(E[8], 570000)
			feed(E[9], 580000)
			feed(E[12], 590000)
			assert.truthy(line("+100.50s c#1 update light_level " .. A("light1")):find(
				"light.light_level=21000(126lx) light.light_level_report.changed=+99.88s", 1, true))
			assert.truthy(line("+185.50s c#2 update temperature " .. A("temp2")):find(
				"temperature.temperature=14.88 temperature.temperature_report.changed=+184.61s", 1, true))
			assert.equal("diag: +331.50s c#3 update zigbee_connectivity " .. A("zig2") .. " (first) created=+331.00s "
				.. "id_v1=\"/sensors/20\" owner=device:" .. A("dev2") .. " status=\"connectivity_issue\"",
				line("+331.50s"))
			assert.equal("diag: +550.00s c#4 update motion " .. A("motion1") .. " (first) created=+550.00s enabled=false "
				.. "id_v1=\"/sensors/12\" owner=device:" .. A("dev1"), line("+550.00s"))
			assert.truthy(line("+560.00s c#5 update motion"):find("sensitivity.sensitivity=3 "
				.. "sensitivity.status=\"changing\"", 1, true))
			assert.truthy(line("+560.00s c#6 update motion"):find("(0.00s after its last) created=+612.00s "
				.. "id_v1=\"/sensors/12\" owner=device:" .. A("dev1") .. " sensitivity.status=\"set\"", 1, true))
			assert.truthy(line("+570.00s c#7 update convenience_area_motion " .. A("conv1")):find(
				"motion.motion_report.motion=true", 1, true))
			assert.equal("diag: +580.00s c#9 update motion_area_configuration " .. A("area1") .. " (first) "
				.. "created=+1500.00s enabled=false", line("+580.00s c#9"))
			assert.equal("diag: +580.00s c#10 update motion_area_configuration " .. A("area1") .. " (0.00s after its "
				.. "last) created=+1590.00s health=\"degraded\" participants=[{resource=motion_area_candidate:"
				.. A("cand11") .. " status.health=\"healthy\"},{resource=motion_area_candidate:" .. A("cand12")
				.. " status.health=\"unhealthy\"},{resource=motion_area_candidate:" .. A("cand13")
				.. " status.health=\"healthy\"}]", line("+580.00s c#10"))
			assert.equal("diag: +590.00s c#11 update device_power " .. A("power1") .. " (first) created=+4219060.00s "
				.. "id_v1=\"/sensors/12\" owner=device:" .. A("dev1") .. " power_state.battery_level=9 "
				.. "power_state.battery_state=\"low\"", line("+590.00s"))
		end)

		it("follows a sensor paired and deleted during the capture", function()
			run_pass()
			assert.equal(7, feed(E[10], 60000))
			assert.equal("diag: +60.00s c#1 add device " .. A("dev3") .. " (first) created=+3000.00s id_v1=\"/sensors/30\" "
				.. "identify={} metadata.archetype=\"unknown_archetype\" metadata.name=name#8 product_data.certified=true "
				.. "product_data.hardware_platform_type=\"100b-10d\" product_data.manufacturer_name=\"Signify "
				.. "Netherlands B.V.\" product_data.model_id=\"SML001\" product_data.product_archetype="
				.. "\"unknown_archetype\" product_data.product_name=\"Hue motion sensor\" "
				.. "product_data.software_version=\"2.85.1\" services=[motion:" .. A("motion3") .. ",device_power:"
				.. A("power3") .. ",zigbee_connectivity:" .. A("zig3") .. ",light_level:" .. A("light3")
				.. ",temperature:" .. A("temp3") .. ",device_software_update:" .. A("swu3") .. "]",
				whole("+60.00s c#1 add device "))
			assert.equal("diag: +60.00s c#1 add zigbee_connectivity " .. A("zig3") .. " (first) id_v1=\"/sensors/30\" "
				.. "mac_address=<mac> owner=device:" .. A("dev3") .. " status=\"connected\"",
				line("+60.00s c#1 add zigbee_connectivity"))
			assert.truthy(line("+60.00s c#1 add device_power "):find("power_state.battery_level=100", 1, true))
			assert.truthy(line("+60.00s c#1 add motion "):find("sensitivity.sensitivity_max=2", 1, true))
			assert.equal(7, feed(E[11], 61000))
			assert.equal(7, #lines_with(" c#2 delete "))
			for _, key in ipairs({ "motion3", "light3", "temp3", "power3", "zig3", "swu3", "dev3" }) do
				assert.equal(1, #lines_with(" c#2 delete ", A(key) .. " (1.00s after its last)"), key)
			end
			assert.equal("diag: +61.00s c#2 delete motion " .. A("motion3") .. " (1.00s after its last) "
				.. "created=+3900.00s (no fields)", line("+61.00s c#2 delete motion "))
			assert.equal("diag: +61.00s c#2 delete device " .. A("dev3") .. " (1.00s after its last) (no fields)",
				line("+61.00s c#2 delete device "))
		end)

		it("leaves the other resources out, counts the counted-only types, and sums up at the end", function()
			run_pass()
			assert.equal(0, feed(E[13], 5000))
			assert.equal(3, feed(E[1], 6000))
			c4.now_ms = PASS_MS + 600000
			assert.equal(1, c4.fire_timers())
			assert.equal("diag: capture end (time) at +600.00s: 3 items logged (0 more after the line limit) from 1 of 2 "
				.. "containers; per resource: grouped_motion " .. A("gm1") .. " 1, grouped_motion " .. A("gmhome")
				.. " 1, motion " .. A("motion1") .. " 1; counted only: camera_motion 0, contact 1, tamper 0; "
				.. "other items: 3", logged[#logged])
			assert.is_false(M:capturing())
			assert.same({ "Motion diagnostics done: 3 items of events logged. Copy the Lua output into the Beta "
				.. "feedback issue." }, dones)
			assert.equal(0, feed(E[1], 601000), "nothing after the end")
		end)

		it("follows the automations: switched off, a timer started, one added with its script, one deleted", function()
			run_pass()
			assert.equal(1, feed(E[14], 60000))
			assert.equal("diag: +60.00s c#1 update behavior_instance " .. A("inst1") .. " for \"Timers\" (automation) "
				.. "(first) created=+60.00s enabled=false", line("+60.00s"))
			assert.equal(1, feed(E[15], 70000))
			assert.equal("diag: +70.00s c#2 update behavior_instance " .. A("inst1") .. " for \"Timers\" (automation) "
				.. "(10.00s after its last) created=+70.00s state.timer_state=\"running\" status=\"running\"",
				line("+70.00s"))
			assert.equal(1, feed(E[16], 80000))
			assert.equal("diag: +80.00s c#3 add behavior_instance " .. A("inst4") .. " for \"Light state after "
				.. "streaming\" (entertainment) (first) created=+80.00s configuration.where=[{group=room:" .. A("room2")
				.. "}] dependees=[] enabled=true last_error=<str:0> metadata.name=name#8 script_id=" .. A("script4")
				.. " status=\"running\"", whole("+80.00s"))
			assert.equal(1, feed(E[17], 90000))
			assert.equal("diag: +90.00s c#4 delete behavior_instance " .. A("inst1") .. " for \"Timers\" (automation) "
				.. "(20.00s after its last) created=+90.00s (no fields)", line("+90.00s"))
			local script = '[{"creationtime":"2026-10-26T07:16:40Z","data":[' .. BODY.behavior_script:match(
				'({"id":"' .. V.script4:gsub("%-", "%%-") .. '".-"state_schema":{}})') .. '],"type":"update"}]'
			assert.equal(1, feed(script, 100000))
			assert.equal("diag: +100.00s c#5 update behavior_script " .. A("script4") .. " (first) created=+100.00s "
				.. "\"Light state after streaming\" (entertainment)", line("+100.00s"))
			assert_redacted()
		end)

		it("logs an item of any other type that a sensor owns", function()
			run_pass()
			local button = invent(2001)
			assert.equal(1, feed('[{"creationtime":"2026-10-26T07:15:40Z","data":[{"id":"' .. button .. '","owner":{'
				.. '"rid":"' .. V.dev2 .. '","rtype":"device"},"button":{"button_report":{"event":"initial_press",'
				.. '"updated":"2026-10-26T07:15:39.500Z"}},"type":"button"},{"id":"' .. invent(2002) .. '","owner":{'
				.. '"rid":"' .. V.dev31 .. '","rtype":"device"},"button":{"button_report":{"event":"short_release"}},'
				.. '"type":"button"}],"type":"update"}]', 40000))
			assert.equal("diag: +40.00s c#1 update button " .. button:sub(1, 4) .. "… (first) created=+40.00s "
				.. "button.button_report.event=<str:13> button.button_report.updated=+39.50s owner=device:" .. A("dev2"),
				line("+40.00s"))
			assert.equal(1, feed('[{"data":[{"id":"' .. button .. '","type":"button"}],"type":"delete"}]', 41000),
				"its delete too")
			c4.fire_timers()
			assert.equal(1, #lines_with("other items: 1"), "the dimmer's button is not a sensor's")
		end)

		it("logs at most 200 lines, then counts until the end", function()
			run_pass()
			local first = #logged + 1
			for i = 1, 300 do
				local container = string.format('[{"creationtime":"2026-10-26T07:15:02Z","data":[{"id":"%s",'
					.. '"motion":{"motion_report":{"changed":"2026-10-26T07:15:02.087Z","motion":%s}},"owner":{'
					.. '"rid":"%s","rtype":"device"},"type":"motion"}],"id":"%s","type":"update"}]', V.motion1,
					tostring(i % 2 == 1), V.dev1, V.e1)
				feed(container, i * 1000)
			end
			assert.equal(198, count_from(first), "197 item lines and the limit line")
			assert.equal("diag: capture: line limit (200) reached at +198.00s; counting until the capture ends",
				logged[#logged])
			c4.fire_timers()
			assert.is_true(count_from(first) <= motion_diag.CAPTURE_LINES)
			assert.equal(1, #lines_with("capture end (time) at +300.00s: 197 items logged (103 more after the line "
				.. "limit) from 197 of 300 containers; per resource: motion " .. A("motion1") .. " 300;"))
		end)

		it("counts continuation lines against the limit", function()
			run_pass()
			local first = #logged + 1
			local item = BODY.device:match('({"id":"' .. V.dev1:gsub("%-", "%%-") .. '".-"type":"device"})')
			assert.truthy(item)
			for i = 1, 120 do
				feed('[{"creationtime":"2026-10-26T07:16:00Z","data":[' .. item .. '],"type":"update"}]', i * 1000)
			end
			assert.equal(2, #lines_with("+1.00s c#1 update device ") + #lines_with("diag: +2 product_data.software"),
				"one item, two lines")
			assert.equal(197, count_from(first), "98 items of two lines and the limit line")
			assert.equal("diag: capture: line limit (200) reached at +99.00s; counting until the capture ends",
				logged[#logged])
			c4.fire_timers()
			assert.is_true(count_from(first) <= motion_diag.CAPTURE_LINES)
			assert.equal(1, #lines_with("98 items logged (22 more after the line limit) from 98 of 120 containers"))
		end)

		it("leaves the containers it is handed as they were, and survives malformed ones", function()
			run_pass()
			for i = 1, 13 do
				for _, container in ipairs(C4:JsonDecode(E[i])) do
					local before = deep_copy(container)
					M:on_container(container)
					assert.same(before, container)
				end
			end
			assert.equal(0, M:on_container(nil))
			assert.equal(0, M:on_container("[]"))
			assert.equal(0, M:on_container({ type = "update", data = "x" }))
			assert.equal(0, M:on_container({ type = "update", data = { 1, "x", false, { type = 7 }, { id = {} } } }))
			assert.equal(1, M:on_container({ type = { "odd" }, data = { { id = V.motion1, type = "motion",
				motion = { motion = "yes" } } } }))
			assert.truthy(saw("<type?> motion " .. A("motion1") .. " (")
				and saw("motion.motion=<str:3>"))
			assert.is_true(M:capturing())
		end)

		it("ends by the clock when its timer is late, once", function()
			run_pass()
			feed(E[1], 1000)
			c4.now_ms = PASS_MS + 600000
			assert.equal(0, M:on_container(C4:JsonDecode(E[2])[1]))
			assert.is_false(M:capturing())
			assert.equal(1, #lines_with("capture end (time) at +600.00s: 3 items logged"))
			assert.equal(1, #dones)
			c4.fire_timers()
			assert.equal(1, #lines_with("capture end"), "the timer finds it ended")
			assert.equal(1, #dones)
		end)
	end)

	describe("redaction", function()
		it("the HR §5 sweep: no name, full id, MAC, bridge id, address or key in anything logged or answered",
			function()
				run_pass()
				for i = 1, #E do
					feed(E[i], i * 10000)
				end
				c4.fire_timers()
				assert.is_false(M:capturing())
				assert.truthy(saw("name#1") and saw("<mac>") and saw("<pan>"))
				assert_redacted()
			end)

		it("hostile values: names holding ids and MACs, nested and listed names, unknown fields, ids in URLs and "
			.. "paths, keys that are names or ids", function()
			run_pass({
				motion = with_item(BODY.motion, HOSTILE_MOTION),
				device = with_item(BODY.device, HOSTILE_DEVICE),
				zigbee_connectivity = with_item(BODY.zigbee_connectivity, HOSTILE_ZIGBEE),
			})
			assert.equal("diag: GET device: HTTP 200, errors 0, 7 items, 3 sensors", line("GET device:"))
			local motion = whole("motion " .. A("motion9"))
			local device = whole("device " .. A("dev9"))
			for _, part in ipairs({ "id_v1=<v1:", "motion.motion_report.changed=<time?>", "motion.note=<str:",
				"extra.deeper.<key>=true", "extra.deeper.<key>=1", "extra.deeper.list=[<str:18>,<str:36>,<str:26>]",
				"extra.deeper.name=name#",
				"extra.deeper.label=<str:", "extra.deeper.href=<addr>", "extra.deeper.owner_id=" .. A("dev11"),
				"extra.deeper.display_name=name#", "extra.deeper.bridge_id=<bridge>", "description=<str:",
				"names=[name#", "auth=<str:30>", "bridge.id=id?", "bridge.mac=<mac>", "ip_address=<addr>", "url=<addr>",
				"sensitivity.status=<str:18>" }) do
				assert.truthy(motion:find(part, 1, true), part .. " in " .. motion)
			end
			for _, part in ipairs({ "id_v1=<v1:21>", "metadata.archetype=<str:12>", "metadata.name=name#",
				"product_data.product_name=\"/clip/v2/resource/device/" .. A("dev9") .. "\"",
				"product_data.manufacturer_name=\"Bridge <bridge>\"", "product_data.software_version=<str:26>",
				"product_data.hardware_platform_type=<str:36>" }) do
				assert.truthy(device:find(part, 1, true), part .. " in " .. device)
			end
			assert.truthy(device:find("usertest.comment=<str:18>", 1, true))
			assert.truthy(saw("zigbee_connectivity " .. A("zig9") .. " id_v1=\"/sensors/99\" mac_address=<mac>"))
			assert_redacted()
		end)

		it("an automation's names, ids in strings, times and location data are redacted (#280)", function()
			run_pass({
				behavior_script = with_item(BODY.behavior_script, HOSTILE_SCRIPT),
				behavior_instance = with_item(BODY.behavior_instance, HOSTILE_INSTANCE),
			})
			assert.truthy(line("GET behavior_script:"):find(A("script9") .. " \"Wake up " .. A("dev1")
				.. "\" (<str:12>)", 1, true))
			local inst = whole("behavior_instance " .. A("inst9"))
			assert.truthy(inst:find("behavior_instance " .. A("inst9") .. " for \"Wake up " .. A("dev1")
				.. "\" (<str:12>) ", 1, true))
			for _, part in ipairs({ "configuration.when.time_point.time.hour=<clock>",
				"configuration.when.time_point.time.minute=<clock>", "configuration.when.time_point.time.second=<clock>",
				"configuration.when.start_at=<str:19>", "configuration.when.recurrence_days=[<str:6>,<str:6>]",
				"configuration.when.changed=-1800.00s", "configuration.where=[{group=room:" .. A("room1") .. " label.name=name#",
				" note=<str:", "{items=[light:" .. A("lamp21") .. "]}", "configuration.who=[geofence_client:" .. A("geo1"),
				"configuration.geofence=<geo>", "configuration.home_location=<geo>", "configuration.coordinates=<geo>",
				"configuration.time_zone=<geo>", "configuration.position=<geo>", "configuration.address=<addr>",
				"configuration.target=<str:", "configuration.resource_id=" .. A("lamp11"), "configuration.names=[name#",
				"configuration.mac=<mac>", "last_error=<str:", "metadata.name=name#", "migrated_from=<v1:",
				"state.last_run=<str:20>", "state.nested.name=name#", "state.timer_state=<str:18>" }) do
				assert.truthy(inst:find(part, 1, true), part .. " in " .. inst)
			end
			assert_redacted(nil, { "27.47", "153.02", "Brisbane", "Australia", "06:45", "12 Vexa" })
		end)

		it("hostile values in the capture are redacted the same way", function()
			run_pass()
			local container = '[{"creationtime":"2026-10-26T07:15:30Z","data":[' .. HOSTILE_MOTION .. '],"id":"'
				.. V.e3 .. '","type":"add"},{"creationtime":"' .. NAMES.name_room1 .. '","data":[' .. HOSTILE_DEVICE
				.. '],"id":"' .. V.e4 .. '","type":"' .. NAMES.name_room2 .. '"}]'
			assert.equal(2, feed(container, 30000))
			assert.truthy(saw("+30.00s c#1 add motion " .. A("motion9")))
			assert.truthy(saw("+30.00s c#2 <type?> device " .. A("dev9") .. " (first) created=<time?> id_v1=<v1:21>"))
			assert.equal(1, feed('[{"data":[' .. HOSTILE_DEVICE .. '],"type":"update"}]', 31000))
			assert.truthy(saw("+31.00s c#3 update device " .. A("dev9") .. " (1.00s after its last) id_v1=<v1:21>"))
			assert.equal(2, feed('[{"data":[' .. HOSTILE_SCRIPT .. "," .. HOSTILE_INSTANCE .. '],"type":"add"}]', 32000))
			assert.truthy(saw("+32.00s c#4 add behavior_instance " .. A("inst9") .. " for \"Wake up " .. A("dev1")
				.. "\" (<str:12>) (first) configuration.address=<addr>"))
			assert_redacted(nil, { "27.47", "153.02", "Brisbane", "Australia", "06:45", "12 Vexa" })
		end)

		it("replaces the strings ctx.secrets() names in every line, a transfer's failure text included", function()
			local refusal = { ok = false, err = "transfer failed (7): Failed to connect to " .. BRIDGE_IP
				.. " port 443 with " .. APP_SECRET .. " for " .. BRIDGE_ID:upper() }
			run_pass({ temperature = refusal })
			assert.equal("diag: GET temperature: no answer (transfer failed (7): Failed to connect to <ip> port 443 with "
				.. "<key> for <bridge>)", line("GET temperature:"))
			assert_redacted()
		end)

		it("the scrubber's patterns hold without ctx.secrets()", function()
			M = new_diag({ secrets = false })
			local id = V.dev1
			assert.equal("a " .. A("dev1") .. " b", M:scrub("a " .. id .. " b"))
			assert.equal("mac <mac> and <mac>", M:scrub("mac 00:17:88:01:0c:00:00:01-02 and 00-17-88-01-0c-00"))
			assert.equal("v6 <addr> and <addr>", M:scrub("v6 fe80::1:2:3 and 2001:db8:0:1::5"))
			assert.equal("at <ip>, not 3.4.2.746094 or 1.77.0", M:scrub("at 10.0.2.143, not 3.4.2.746094 or 1.77.0"))
			assert.equal("id <hex> and <hex>, not 2071353020",
				M:scrub("id 001788fffe123abc and 001788FFFE123ABC, not 2071353020"))
			assert.equal("key <token> and <token>", M:scrub("key zzzz0000zzzz0000zzzz0000zzzz00 and Ab1Cd2Ef3Gh4Ij5Kl6Mn7"))
			assert.equal("motion_area_configuration device_software_update auth_v1:12ab… kept",
				M:scrub("motion_area_configuration device_software_update auth_v1:12ab… kept"))
			assert.equal("at <clock>, <clock> and <clock>:", M:scrub("at 07:15, 7:05:16.502 and 14:12:30:"))
			assert.equal("at 07:15", M:scrub("at 07:15", true), "the Last Action answer keeps its clock")
			assert.equal("one line", M:scrub("one\nline"))
		end)

		it("never lets a control character start a line of its own", function()
			local body = BODY.device:gsub("Hue motion sensor", "Hue\\nmotion sensor")
			Properties["Bridge Model"] = "BSB003\nINJECTED line"
			run_pass({ device = body })
			assert.truthy(saw("product_data.product_name=<str:17>"))
			assert.equal("diag: bridge: model \"BSB003 INJECTED line\", firmware \"1.77.2071353020 (API 1.77.0)\"; "
				.. "controller OS \"3.4.2 build 746094\"; driver version \"271\"", line("bridge:"))
			assert_redacted()
		end)
	end)

	describe("clock times", function()
		it("no logged line holds one: a restart, the pass, a clock in an error, the line limit, the end", function()
			M:run(answered)
			M:run(answered)
			c4.now_ms = PASS_MS
			assert.equal(1, c4.fire_timers())
			answer_all({ zone = { ok = false, code = 503, json = { errors = { { description = "Timeout at 07:15" } } } } })
			assert.equal("diag: GET zone: HTTP 503, errors 1: \"Timeout at <clock>\", no data array", line("GET zone:"))
			for i = 1, 210 do
				feed(string.format('[{"creationtime":"2026-10-26T07:15:02Z","data":[{"id":"%s","enabled":true,'
					.. '"type":"motion"}],"type":"update"}]', V.motion1), i * 1000)
			end
			M:run(answered)  -- the capture ends (restarted), and the new run's pass fails
			c4.now_ms = PASS_MS + 300000
			c4.fire_timers()
			answer_all({ clip = { ok = false, err = "timed out at 07:20:01" }, motion = { ok = false, err = "x" },
				light_level = { ok = false, err = "x" } })
			assert.truthy(saw("restarted: the pass starts again in 20 s"))
			assert.truthy(saw("pass done (2 sensors, 1 area, 3 automations); capturing events for 10 minutes."))
			assert.truthy(saw("counting until the capture ends"))
			assert.truthy(saw("capture end (restarted) at +210.00s"))
			assert.truthy(saw("GET clip: no answer (timed out at <clock>)"))
			assert.truthy(#logged > 200)
			for _, l in ipairs(logged) do
				assert.is_nil(l:find("%d%d:%d%d"), "a clock time in: " .. l)
				assert.is_nil(l:find("%d:%d%d"), "a clock time in: " .. l)
			end
			assert.is_nil(answers[1].text:find("%d:%d%d"), "no clock time in the Last Action answer either")
		end)
	end)

	describe("through bridge.http", function()
		it("sends quiet keyed GETs, and only this module's scrubbed line reports a failed transfer", function()
			package.loaded["bridge.http"] = nil
			local http_mod = require("bridge.http")
			M = new_diag({ http = function(req, cb)
				req.ip = BRIDGE_IP
				req.key = APP_SECRET
				return http_mod.request(req, cb)
			end })
			M:run(answered)
			c4.now_ms = PASS_MS
			c4.fire_timers()
			local t = c4.last_transfer()
			assert.equal("https://" .. BRIDGE_IP .. "/clip/v2/resource/clip", t.url)
			assert.equal(APP_SECRET, t.headers["hue-application-key"])
			t:respond(200, BODY.clip)
			c4.last_transfer():done(7, "Failed to connect to " .. BRIDGE_IP .. " port 443: Connection refused")
			assert.equal("diag: GET motion: no answer (transfer failed (7): Failed to connect to <ip> port 443: "
				.. "Connection refused)", line("GET motion:"))
			for _ = 3, #motion_diag.STEPS do
				local tr = c4.last_transfer()
				local typ = tr.url:match("([%w_]+)$")
				tr:respond(BODY[typ] and 200 or 404, BODY[typ] or '{"errors":[{"description":"Not Found"}],"data":[]}')
			end
			assert.is_true(M:capturing())
			assert.equal(#motion_diag.STEPS, #c4.transfers)
			assert_redacted()
		end)
	end)
end)
