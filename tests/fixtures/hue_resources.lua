-- luacheck: no max line length (JSON lines)
--
-- Recorded-style Hue CLIP v2 responses for one small bridge, as JSON text so
-- specs exercise the same decode path as the driver (http.request → result.json).
--
-- Four lights on four devices, plus the bridge's own device entry (which has
-- no light service, as on a real bridge):
--   Living Room Lamp   LCA001  colour + CCT, currently in CCT mode (mirek 366)
--   Kitchen Strip      LST002  colour + CCT, currently in xy mode (mirek null)
--   Hallway Ambiance   LTA001  CCT only
--   Garage White       LWA001  dimmable only, off, zigbee connectivity_issue
-- The light list is deliberately not in name order. Ids are made up but
-- UUID-shaped; the bridge id is the documentation example 001788fffe25b8f8.
--
-- Groups (F.room, F.zone, F.bridge_home); the key sets, child and service
-- rtypes follow the bodies recorded from the house bridge [verified:
-- hardware 2026-10-21, GET /room, /zone, /bridge_home], the data is this
-- small bridge's own:
--   Living Room   room   /groups/2  devices: Living Room Lamp, Hallway Ambiance
--   Garage        room   /groups/1  devices: Garage White
--   Downstairs    zone   /groups/3  lights: Living Room Lamp, Garage White
--   Attic         zone   /groups/4  empty: no children, no services
--   bridge_home          /groups/0  both rooms, plus the room-less devices:
--                                   Kitchen Strip and the bridge itself
-- Kitchen Strip is deliberately in no room and no zone.
--
-- Scenes (F.scene, F.smart_scene, F.scene_rids; the scene events are at the
-- end). Item keys and nesting follow the one scene recorded from the house
-- bridge [verified: hardware 2026-10-21, GET /scene/<rid> of a static zone
-- scene]; the data is this small bridge's own:
--   Relax           Living Room (room)  inactive, never recalled
--   Savanna sunset  Living Room (room)  inactive, auto_dynamic (a dynamic palette)
--   Nightlight      Downstairs (zone)   static, recalled (the recorded scene's shape and values)
--   Bright          Downstairs (zone)   inactive, recalled earlier (keeps a last_recall)
--   Concentrate     Garage (room)       inactive
--   Golden hours    Downstairs (zone)   the one smart scene
-- Attic, the empty zone, has no scenes.

local F = {}

F.rids = {
	living = "0b216218-d811-4c95-8c55-bbcda50f9d50",
	kitchen = "7f3c9a2b-5e14-4d8f-b1a6-93c0e2d4f815",
	hallway = "c48d1e6f-2a9b-4f3e-9c7d-8e5f1a2b3c03",
	garage = "9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c04",
}

-- Rooms, the zone and the bridge_home. The Garage's rids are the ones
-- F.events.off already names as the owner of its grouped_light item.
F.group_rids = {
	living_room = "7d6c5b4a-0000-4000-8000-00000000r002",
	garage = "7d6c5b4a-0000-4000-8000-00000000r001",
	downstairs = "7d6c5b4a-0000-4000-8000-00000000z001",
	attic = "7d6c5b4a-0000-4000-8000-00000000z003",
	home = "7d6c5b4a-0000-4000-8000-00000000h000",
}

-- One grouped_light per group, same keys as F.group_rids; the empty zone
-- has none [verified: hardware, an empty zone's services array is empty].
F.grouped_light_rids = {
	living_room = "8e7d6c5b-0000-4000-8000-00000000g002",
	garage = "8e7d6c5b-0000-4000-8000-00000000g001",
	downstairs = "8e7d6c5b-0000-4000-8000-00000000g003",
	home = "8e7d6c5b-0000-4000-8000-00000000g000",
}

F.group_names = {
	living_room = "Living Room",
	garage = "Garage",
	downstairs = "Downstairs",
	attic = "Attic",
}

F.device_rids = {
	living = "1d5a6a4e-7b7c-4c0e-9a6d-2f3f7c3b4e01",
	kitchen = "a3e8c2d1-4f6b-4a9e-8d7c-5b1e9f2a3c02",
	hallway = "e1f2a3b4-c5d6-4e7f-8a9b-0c1d2e3f4a03",
	garage = "5c4d3e2f-1a0b-4c9d-8e7f-6a5b4c3d2e04",
	bridge = "b0e1d2c3-f4a5-4b6c-8d7e-9f0a1b2c3d05",
}

F.zigbee_rids = {
	living = "3a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c11",
	kitchen = "4b2c3d4e-5f6a-4b7c-8d8e-0f1a2b3c4d12",
	hallway = "5c3d4e5f-6a7b-4c8d-8e9f-1a2b3c4d5e13",
	garage = "6d4e5f6a-7b8c-4d9e-8fa0-2b3c4d5e6f14",
}

F.names = {
	living = "Living Room Lamp",
	kitchen = "Kitchen Strip",
	hallway = "Hallway Ambiance",
	garage = "Garage White",
}

-- Name order, which is the order the import creates devices in.
F.by_name = { "garage", "hallway", "kitchen", "living" }

local GAMUT_C = '"gamut":{"red":{"x":0.6915,"y":0.3083},"green":{"x":0.17,"y":0.7},"blue":{"x":0.1532,"y":0.0475}},'
	.. '"gamut_type":"C"'

F.light = [[{"errors":[],"data":[
{"id":"]] .. F.rids.living .. [[","id_v1":"/lights/1",
 "owner":{"rid":"]] .. F.device_rids.living .. [[","rtype":"device"},"service_id":0,
 "metadata":{"name":"Living Room Lamp","archetype":"sultan_bulb","function":"mixed"},
 "identify":{},
 "on":{"on":true},
 "dimming":{"brightness":73.52,"min_dim_level":0.2},
 "dimming_delta":{},
 "color_temperature":{"mirek":366,"mirek_valid":true,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":500}},
 "color_temperature_delta":{},
 "color":{"xy":{"x":0.4575,"y":0.4101},]] .. GAMUT_C .. [[},
 "dynamics":{"status":"none","status_values":["none","dynamic_palette"],"speed":0,"speed_valid":false},
 "alert":{"action_values":["breathe"]},
 "signaling":{"signal_values":["no_signal","on_off","on_off_color","alternating"]},
 "mode":"normal",
 "effects":{"status_values":["no_effect","candle","fire","prism"],"status":"no_effect","effect_values":["no_effect","candle","fire","prism"]},
 "powerup":{"preset":"safety","configured":true,"on":{"mode":"on","on":{"on":true}},"dimming":{"mode":"dimming","dimming":{"brightness":100}},"color":{"mode":"color_temperature","color_temperature":{"mirek":366}}},
 "type":"light"},
{"id":"]] .. F.rids.garage .. [[","id_v1":"/lights/4",
 "owner":{"rid":"]] .. F.device_rids.garage .. [[","rtype":"device"},"service_id":0,
 "metadata":{"name":"Garage White","archetype":"classic_bulb","function":"functional"},
 "identify":{},
 "on":{"on":false},
 "dimming":{"brightness":100.0,"min_dim_level":5.0},
 "dimming_delta":{},
 "dynamics":{"status":"none","status_values":["none"],"speed":0,"speed_valid":false},
 "alert":{"action_values":["breathe"]},
 "signaling":{"signal_values":["no_signal","on_off"]},
 "mode":"normal",
 "effects":{"status_values":["no_effect"],"status":"no_effect","effect_values":["no_effect"]},
 "powerup":{"preset":"safety","configured":true,"on":{"mode":"on","on":{"on":true}},"dimming":{"mode":"dimming","dimming":{"brightness":100}}},
 "type":"light"},
{"id":"]] .. F.rids.kitchen .. [[","id_v1":"/lights/2",
 "owner":{"rid":"]] .. F.device_rids.kitchen .. [[","rtype":"device"},"service_id":0,
 "metadata":{"name":"Kitchen Strip","archetype":"hue_lightstrip","function":"decorative"},
 "identify":{},
 "on":{"on":true},
 "dimming":{"brightness":100.0,"min_dim_level":0.39},
 "dimming_delta":{},
 "color_temperature":{"mirek":null,"mirek_valid":false,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":500}},
 "color_temperature_delta":{},
 "color":{"xy":{"x":0.2731,"y":0.1192},]] .. GAMUT_C .. [[},
 "dynamics":{"status":"none","status_values":["none","dynamic_palette"],"speed":0,"speed_valid":false},
 "alert":{"action_values":["breathe"]},
 "signaling":{"signal_values":["no_signal","on_off","on_off_color","alternating"]},
 "mode":"normal",
 "effects":{"status_values":["no_effect","candle","fire","prism"],"status":"no_effect","effect_values":["no_effect","candle","fire","prism"]},
 "powerup":{"preset":"last_on_state","configured":true,"on":{"mode":"on","on":{"on":true}},"dimming":{"mode":"previous"},"color":{"mode":"previous"}},
 "type":"light"},
{"id":"]] .. F.rids.hallway .. [[","id_v1":"/lights/3",
 "owner":{"rid":"]] .. F.device_rids.hallway .. [[","rtype":"device"},"service_id":0,
 "metadata":{"name":"Hallway Ambiance","archetype":"ceiling_round","function":"functional"},
 "identify":{},
 "on":{"on":true},
 "dimming":{"brightness":40.16,"min_dim_level":0.2},
 "dimming_delta":{},
 "color_temperature":{"mirek":250,"mirek_valid":true,"mirek_schema":{"mirek_minimum":153,"mirek_maximum":454}},
 "color_temperature_delta":{},
 "dynamics":{"status":"none","status_values":["none"],"speed":0,"speed_valid":false},
 "alert":{"action_values":["breathe"]},
 "signaling":{"signal_values":["no_signal","on_off"]},
 "mode":"normal",
 "effects":{"status_values":["no_effect","candle"],"status":"no_effect","effect_values":["no_effect","candle"]},
 "powerup":{"preset":"safety","configured":true,"on":{"mode":"on","on":{"on":true}},"dimming":{"mode":"dimming","dimming":{"brightness":100}},"color":{"mode":"color_temperature","color_temperature":{"mirek":366}}},
 "type":"light"}
]}]]

local function device(key, model_id, product_name, archetype, sw, hw)
	return '{"id":"' .. F.device_rids[key] .. '","id_v1":"/lights/' .. ({ living = 1, kitchen = 2, hallway = 3, garage = 4 })[key]
		.. '","product_data":{"model_id":"' .. model_id .. '","manufacturer_name":"Signify Netherlands B.V.",'
		.. '"product_name":"' .. product_name .. '","product_archetype":"' .. archetype .. '","certified":true,'
		.. '"software_version":"' .. sw .. '","hardware_platform_type":"' .. hw .. '"},'
		.. '"metadata":{"name":"' .. F.names[key] .. '","archetype":"' .. archetype .. '"},'
		.. '"identify":{},'
		.. '"services":[{"rid":"' .. F.zigbee_rids[key] .. '","rtype":"zigbee_connectivity"},'
		.. '{"rid":"' .. F.rids[key] .. '","rtype":"light"},'
		.. '{"rid":"' .. F.rids[key]:sub(1, 8) .. '-ent0-4000-8000-000000000000","rtype":"entertainment"},'
		.. '{"rid":"' .. F.rids[key]:sub(1, 8) .. '-tap0-4000-8000-000000000000","rtype":"taurus_7455"},'
		.. '{"rid":"' .. F.rids[key]:sub(1, 8) .. '-dev0-4000-8000-000000000000","rtype":"device_software_update"}],'
		.. '"type":"device"}'
end

F.device = '{"errors":[],"data":['
	.. '{"id":"' .. F.device_rids.bridge .. '","id_v1":"",'
	.. '"product_data":{"model_id":"BSB002","manufacturer_name":"Signify Netherlands B.V.",'
	.. '"product_name":"Philips hue","product_archetype":"bridge_v2","certified":true,"software_version":"1.68.1968096020"},'
	.. '"metadata":{"name":"Philips hue","archetype":"bridge_v2"},"identify":{},'
	.. '"services":[{"rid":"4f2b1c3d-0000-4000-8000-00000000b001","rtype":"bridge"},'
	.. '{"rid":"4f2b1c3d-0000-4000-8000-00000000b002","rtype":"zigbee_connectivity"},'
	.. '{"rid":"4f2b1c3d-0000-4000-8000-00000000b003","rtype":"zigbee_device_discovery"}],'
	.. '"type":"device"},'
	.. device("living", "LCA001", "Hue color lamp", "sultan_bulb", "1.122.2", "100b-11a") .. ','
	.. device("garage", "LWA001", "Hue white lamp", "classic_bulb", "1.122.2", "100b-110") .. ','
	.. device("kitchen", "LST002", "Hue lightstrip plus", "hue_lightstrip", "1.122.2", "100b-11a") .. ','
	.. device("hallway", "LTA001", "Hue ambiance lamp", "ceiling_round", "1.122.2", "100b-113")
	.. ']}'

local function zigbee(key, status, mac)
	return '{"id":"' .. F.zigbee_rids[key] .. '","id_v1":"/lights/' .. ({ living = 1, kitchen = 2, hallway = 3, garage = 4 })[key]
		.. '","owner":{"rid":"' .. F.device_rids[key] .. '","rtype":"device"},'
		.. '"status":"' .. status .. '","mac_address":"' .. mac .. '","channel":{"value":"channel_25","status":"set"},'
		.. '"type":"zigbee_connectivity"}'
end

F.zigbee_connectivity = '{"errors":[],"data":['
	.. zigbee("living", "connected", "00:17:88:01:0b:12:34:01-0b") .. ','
	.. zigbee("kitchen", "connected", "00:17:88:01:0b:12:34:02-0b") .. ','
	.. zigbee("hallway", "connected", "00:17:88:01:0b:12:34:03-0b") .. ','
	.. zigbee("garage", "connectivity_issue", "00:17:88:01:0b:12:34:04-0b")
	.. ']}'

-- Groups [verified: hardware 2026-10-21 for every key and rtype below]. A
-- room item has id, id_v1, children (rtype device), services (one
-- grouped_light), metadata {name, archetype} and a geometry block the
-- driver ignores; a zone is the same without geometry and with light
-- children; bridge_home has no metadata, its children mix the devices in no
-- room (listed first, including the bridge's own device on this dataset
-- [assumed: which room-less devices the house bridge lists was not
-- resolved]) and the rooms; id_v1 /groups/0. An empty zone has `children`
-- and `services` both []. The room list is not in name order and children
-- are not sorted.

local function child(rid, rtype)
	return '{"rid":"' .. rid .. '","rtype":"' .. rtype .. '"}'
end

-- The per-device placement block rooms carry (all zeros on the house
-- bridge); one object per child.
local function geometry(children)
	local objects = {}
	for i, ref in ipairs(children) do
		objects[i] = '{"reference":' .. ref .. ',"transform":{"position":{"x":0.0,"y":0.0,"z":0.0},'
			.. '"rotation":{"x":0.0,"y":0.0,"z":0.0,"w":1.0}}}'
	end
	return '"geometry":{"objects":[' .. table.concat(objects, ",") .. ']},'
end

local function group(key, gtype, id_v1, archetype, children)
	local text = '{"id":"' .. F.group_rids[key] .. '","id_v1":"' .. id_v1 .. '",'
		.. '"children":[' .. table.concat(children, ",") .. '],'
	if F.grouped_light_rids[key] then
		text = text .. '"services":[' .. child(F.grouped_light_rids[key], "grouped_light") .. '],'
	else
		text = text .. '"services":[],'
	end
	if archetype then
		text = text .. '"metadata":{"name":"' .. F.group_names[key] .. '","archetype":"' .. archetype .. '"},'
	end
	if gtype == "room" then
		text = text .. geometry(children)
	end
	return text .. '"type":"' .. gtype .. '"}'
end

F.room = '{"errors":[],"data":['
	.. group("living_room", "room", "/groups/2", "living_room",
		{ child(F.device_rids.hallway, "device"), child(F.device_rids.living, "device") }) .. ','
	.. group("garage", "room", "/groups/1", "garage", { child(F.device_rids.garage, "device") })
	.. ']}'

F.zone = '{"errors":[],"data":['
	.. group("downstairs", "zone", "/groups/3", "downstairs",
		{ child(F.rids.garage, "light"), child(F.rids.living, "light") }) .. ','
	.. group("attic", "zone", "/groups/4", "attic", {})
	.. ']}'

F.bridge_home = '{"errors":[],"data":['
	.. group("home", "bridge_home", "/groups/0", nil, {
		child(F.device_rids.kitchen, "device"),
		child(F.device_rids.bridge, "device"),
		child(F.group_rids.living_room, "room"),
		child(F.group_rids.garage, "room"),
	})
	.. ']}'

-- Scenes. One scene was recorded whole from the house bridge [verified:
-- hardware 2026-10-21, GET /scene/<rid>, a static zone scene recalled through
-- the API a few seconds earlier]: id, id_v1 "/scenes/<16 chars>", actions[]
-- (one per target light, rtype light, each with on / dimming / color or
-- color_temperature), palette {color[], dimming[], color_temperature[],
-- effects[], effects_v2[]}, recall {} (empty on a GET), metadata {name,
-- image{rid, rtype public_image}}, group {rid, rtype zone}, speed,
-- auto_dynamic, status {active, last_recall}, mapping {algorithm classic},
-- last_actions_update {source autogrow}, type. Nightlight below reproduces
-- that scene's values on this bridge's lights. Everything the recording did
-- not show is [assumed]: a never-recalled scene has no last_recall; an
-- inactive scene that was recalled earlier keeps its last_recall; a dynamic
-- scene has auto_dynamic true and several palette colours; a room scene has
-- group rtype "room"; the probe's 125 scenes (all inactive, speeds 0.603 /
-- 0.6269841 / 0.6031746 …, a few "dynamic") are the source of the names and
-- speeds. The list is not in name order, as the bridge's is not.

F.scene_rids = {
	relax = "5e4d3c2b-0000-4000-8000-00000000s001",
	savanna = "5e4d3c2b-0000-4000-8000-00000000s002",
	nightlight = "5e4d3c2b-0000-4000-8000-00000000s003",
	bright = "5e4d3c2b-0000-4000-8000-00000000s004",
	concentrate = "5e4d3c2b-0000-4000-8000-00000000s005",
}

F.scene_names = {
	relax = "Relax",
	savanna = "Savanna sunset",
	nightlight = "Nightlight",
	bright = "Bright",
	concentrate = "Concentrate",
}

F.scene_id_v1 = {
	relax = "/scenes/Ab3dEf7hIj9kLm1n",
	savanna = "/scenes/Cd5fGh9jKl3mNo7p",
	nightlight = "/scenes/Ef7hIj1kLm5nOp9q",
	bright = "/scenes/Gh9jKl3mNo7pQr1s",
	concentrate = "/scenes/Ij1kLm5nOp9qRs3t",
}

-- The group each scene belongs to (keys of F.group_rids) and its rtype.
F.scene_groups = {
	relax = { key = "living_room", rtype = "room" },
	savanna = { key = "living_room", rtype = "room" },
	nightlight = { key = "downstairs", rtype = "zone" },
	bright = { key = "downstairs", rtype = "zone" },
	concentrate = { key = "garage", rtype = "room" },
}

local function scene_action(light_key, body)
	return '{"target":{"rid":"' .. F.rids[light_key] .. '","rtype":"light"},"action":{' .. body .. '}}'
end

local EMPTY_PALETTE = { color = "[]", dimming = "[]", color_temperature = "[]", effects = "[]", effects_v2 = "[]" }

-- opts: actions (list of scene_action strings), palette (partial table of
-- JSON arrays by palette key), speed, auto_dynamic, active, last_recall
-- (optional), autogrow (adds last_actions_update, as the recorded scene had).
local function scene(key, opts)
	local palette = {}
	for _, name in ipairs({ "color", "dimming", "color_temperature", "effects", "effects_v2" }) do
		palette[#palette + 1] = '"' .. name .. '":' .. ((opts.palette or {})[name] or EMPTY_PALETTE[name])
	end
	local owner = F.scene_groups[key]
	local status = '"active":"' .. (opts.active or "inactive") .. '"'
	if opts.last_recall then
		status = status .. ',"last_recall":"' .. opts.last_recall .. '"'
	end
	return '{"id":"' .. F.scene_rids[key] .. '","id_v1":"' .. F.scene_id_v1[key] .. '",'
		.. '"actions":[' .. table.concat(opts.actions, ",") .. '],'
		.. '"palette":{' .. table.concat(palette, ",") .. '},'
		.. '"recall":{},'
		.. '"metadata":{"name":"' .. F.scene_names[key] .. '","image":{"rid":"' .. F.scene_rids[key]:sub(1, 8)
		.. '-img0-4000-8000-000000000000","rtype":"public_image"}},'
		.. '"group":{"rid":"' .. F.group_rids[owner.key] .. '","rtype":"' .. owner.rtype .. '"},'
		.. '"speed":' .. tostring(opts.speed) .. ',"auto_dynamic":' .. tostring(opts.auto_dynamic == true) .. ','
		.. '"status":{' .. status .. '},'
		.. '"mapping":{"algorithm":"classic"},'
		.. (opts.autogrow and '"last_actions_update":{"source":"autogrow"},' or "")
		.. '"type":"scene"}'
end

-- The recorded scene's last_recall [verified: hardware], reused for Nightlight.
F.scene_last_recall = "2026-10-21T20:21:46.398Z"

F.scene = '{"errors":[],"data":['
	.. scene("nightlight", {
		actions = {
			scene_action("living", '"on":{"on":true},"dimming":{"brightness":0.0},"color":{"xy":{"x":0.5609999,"y":0.4042}}'),
			scene_action("garage", '"on":{"on":true},"dimming":{"brightness":0.0}'),
		},
		palette = { color = '[{"color":{"xy":{"x":0.5609999,"y":0.4042}},"dimming":{"brightness":0.0}}]' },
		speed = 0.603, active = "static", last_recall = F.scene_last_recall, autogrow = true,
	}) .. ','
	.. scene("relax", {
		actions = {
			scene_action("living", '"on":{"on":true},"dimming":{"brightness":56.69},"color_temperature":{"mirek":447}'),
			scene_action("hallway", '"on":{"on":true},"dimming":{"brightness":56.69},"color_temperature":{"mirek":447}'),
		},
		palette = { color_temperature = '[{"color_temperature":{"mirek":447},"dimming":{"brightness":56.69}}]' },
		speed = 0.603,
	}) .. ','
	.. scene("concentrate", {
		actions = { scene_action("garage", '"on":{"on":true},"dimming":{"brightness":100.0}') },
		palette = { dimming = '[{"brightness":100.0}]' },
		speed = 0.603,
	}) .. ','
	.. scene("savanna", {
		actions = {
			scene_action("living", '"on":{"on":true},"dimming":{"brightness":80.0},"color":{"xy":{"x":0.5451,"y":0.4046}}'),
			scene_action("hallway", '"on":{"on":true},"dimming":{"brightness":80.0},"color_temperature":{"mirek":443}'),
		},
		palette = { color = '[{"color":{"xy":{"x":0.5451,"y":0.4046}},"dimming":{"brightness":80.0}},'
			.. '{"color":{"xy":{"x":0.6023,"y":0.3792}},"dimming":{"brightness":80.0}},'
			.. '{"color":{"xy":{"x":0.4893,"y":0.4463}},"dimming":{"brightness":80.0}},'
			.. '{"color":{"xy":{"x":0.5676,"y":0.3769}},"dimming":{"brightness":80.0}},'
			.. '{"color":{"xy":{"x":0.4432,"y":0.4653}},"dimming":{"brightness":80.0}}]' },
		speed = 0.6031746, auto_dynamic = true,
	}) .. ','
	.. scene("bright", {
		actions = {
			scene_action("living", '"on":{"on":true},"dimming":{"brightness":100.0},"color_temperature":{"mirek":233}'),
			scene_action("garage", '"on":{"on":true},"dimming":{"brightness":100.0}'),
		},
		palette = { color_temperature = '[{"color_temperature":{"mirek":233},"dimming":{"brightness":100.0}}]' },
		speed = 0.6269841, last_recall = "2026-10-20T07:12:03.110Z",
	})
	.. ']}'

-- One smart scene, "Golden hours" over the Downstairs zone: two time slots
-- targeting Bright and Nightlight, every day. Shape [community: aiohue,
-- openhue; assumed]; the house bridge's 15 smart scenes did answer the
-- probe with `state` and `active_timeslot.timeslot_id` [verified: hardware
-- 2026-10-21]. The driver only counts these (docs/scenes-design.md §1).
F.smart_scene_rid = "6f5e4d3c-0000-4000-8000-0000000ss001"
F.smart_scene = '{"errors":[],"data":['
	.. '{"id":"' .. F.smart_scene_rid .. '",'
	.. '"metadata":{"name":"Golden hours","image":{"rid":"6f5e4d3c-img0-4000-8000-000000000000","rtype":"public_image"}},'
	.. '"group":{"rid":"' .. F.group_rids.downstairs .. '","rtype":"zone"},'
	.. '"week_timeslots":[{"timeslots":['
	.. '{"start_time":{"kind":"time","time":{"hour":7,"minute":0,"second":0}},"target":{"rid":"' .. F.scene_rids.bright .. '","rtype":"scene"}},'
	.. '{"start_time":{"kind":"sunset"},"target":{"rid":"' .. F.scene_rids.nightlight .. '","rtype":"scene"}}],'
	.. '"recurrence":["monday","tuesday","wednesday","thursday","friday","saturday","sunday"]}],'
	.. '"transition_duration":60000,'
	.. '"active_timeslot":{"timeslot_id":1,"weekday":"tuesday"},'
	.. '"state":"inactive",'
	.. '"type":"smart_scene"}'
	.. ']}'

-- A failed authenticated GET, as the bridge answers a revoked key.
F.unauthorized = '{"errors":[{"description":"unauthorized user"}],"data":[]}'

-- Event-stream containers (the JSON array one SSE `data:` line carries),
-- each as the bridge sends it: only the fields that changed.
F.events = {}

-- Living Room Lamp dimmed to 50 %.
F.events.brightness = '[{"creationtime":"2026-10-21T18:04:55Z","id":"9de116fc-0001-4a2b-8c3d-000000000001","type":"update",'
	.. '"data":[{"id":"' .. F.rids.living .. '","id_v1":"/lights/1","owner":{"rid":"' .. F.device_rids.living
	.. '","rtype":"device"},"dimming":{"brightness":50.0},"type":"light"}]}]'

-- Living Room Lamp set to a colour: the bridge reports xy and an invalid mirek.
F.events.color = '[{"creationtime":"2026-10-21T18:05:01Z","id":"9de116fc-0002-4a2b-8c3d-000000000002","type":"update",'
	.. '"data":[{"id":"' .. F.rids.living .. '","id_v1":"/lights/1","owner":{"rid":"' .. F.device_rids.living
	.. '","rtype":"device"},"color":{"xy":{"x":0.1532,"y":0.0475}},'
	.. '"color_temperature":{"mirek":null,"mirek_valid":false},"type":"light"}]}]'

-- Kitchen Strip back to a white point.
F.events.ct = '[{"creationtime":"2026-10-21T18:05:30Z","id":"9de116fc-0003-4a2b-8c3d-000000000003","type":"update",'
	.. '"data":[{"id":"' .. F.rids.kitchen .. '","id_v1":"/lights/2","owner":{"rid":"' .. F.device_rids.kitchen
	.. '","rtype":"device"},"color":{"xy":{"x":0.3127,"y":0.329}},'
	.. '"color_temperature":{"mirek":153,"mirek_valid":true},"type":"light"}]}]'

-- Garage White switched off from the Hue app; one container, two items
-- (the bridge batches the light and its grouped_light).
F.events.off = '[{"creationtime":"2026-10-21T18:06:00Z","id":"9de116fc-0004-4a2b-8c3d-000000000004","type":"update",'
	.. '"data":[{"id":"' .. F.rids.garage .. '","id_v1":"/lights/4","owner":{"rid":"' .. F.device_rids.garage
	.. '","rtype":"device"},"on":{"on":false},"type":"light"},'
	.. '{"id":"8e7d6c5b-0000-4000-8000-00000000g001","id_v1":"/groups/1","owner":{"rid":"7d6c5b4a-0000-4000-8000-00000000r001",'
	.. '"rtype":"room"},"on":{"on":false},"type":"grouped_light"}]}]'

-- Garage White comes back on the Zigbee network.
F.events.connectivity = '[{"creationtime":"2026-10-21T18:07:12Z","id":"9de116fc-0005-4a2b-8c3d-000000000005","type":"update",'
	.. '"data":[{"id":"' .. F.zigbee_rids.garage .. '","id_v1":"/lights/4","owner":{"rid":"' .. F.device_rids.garage
	.. '","rtype":"device"},"status":"connected","type":"zigbee_connectivity"}]}]'

-- An event that touches nothing the driver reports (a dynamics status).
F.events.noop = '[{"creationtime":"2026-10-21T18:08:00Z","id":"9de116fc-0006-4a2b-8c3d-000000000006","type":"update",'
	.. '"data":[{"id":"' .. F.rids.living .. '","id_v1":"/lights/1","owner":{"rid":"' .. F.device_rids.living
	.. '","rtype":"device"},"dynamics":{"status":"none","speed":0,"speed_valid":false},"type":"light"}]}]'

-- A light the registry does not know (someone added a bulb in the Hue app).
F.events.add = '[{"creationtime":"2026-10-21T18:09:00Z","id":"9de116fc-0007-4a2b-8c3d-000000000007","type":"add",'
	.. '"data":[{"id":"ffffffff-0000-4000-8000-00000000new1","id_v1":"/lights/5","owner":{"rid":"ffffffff-0000-4000-8000-00000000dev5",'
	.. '"rtype":"device"},"metadata":{"name":"New Bulb","archetype":"classic_bulb"},"on":{"on":true},'
	.. '"dimming":{"brightness":100.0,"min_dim_level":2.0},"type":"light"}]}]'

-- Group events [assumed: an update carries the whole children array, both
-- rooms of a move share one container, items carry id_v1; delete items are
-- bare id + type (docs/edge-cases-hue.md §2, §5)].

-- Hallway Ambiance's device moved from Living Room to Garage in the Hue app.
F.events.room_move = '[{"creationtime":"2026-10-21T18:10:00Z","id":"9de116fc-0008-4a2b-8c3d-000000000008","type":"update",'
	.. '"data":[{"id":"' .. F.group_rids.living_room .. '","id_v1":"/groups/2","children":['
	.. child(F.device_rids.living, "device") .. '],"type":"room"},'
	.. '{"id":"' .. F.group_rids.garage .. '","id_v1":"/groups/1","children":['
	.. child(F.device_rids.garage, "device") .. ',' .. child(F.device_rids.hallway, "device") .. '],"type":"room"}]}]'

-- Living Room renamed to Lounge.
F.events.room_rename = '[{"creationtime":"2026-10-21T18:11:00Z","id":"9de116fc-0009-4a2b-8c3d-000000000009","type":"update",'
	.. '"data":[{"id":"' .. F.group_rids.living_room .. '","id_v1":"/groups/2","metadata":{"name":"Lounge"},"type":"room"}]}]'

-- A new zone "Upstairs" holding Hallway Ambiance, with its grouped_light,
-- in one add container.
F.new_zone_rid = "7d6c5b4a-0000-4000-8000-00000000z002"
F.new_zone_grouped_light_rid = "8e7d6c5b-0000-4000-8000-00000000g005"
F.events.zone_add = '[{"creationtime":"2026-10-21T18:12:00Z","id":"9de116fc-000a-4a2b-8c3d-00000000000a","type":"add",'
	.. '"data":[{"id":"' .. F.new_zone_grouped_light_rid .. '","id_v1":"/groups/5","owner":{"rid":"' .. F.new_zone_rid
	.. '","rtype":"zone"},"on":{"on":true},"dimming":{"brightness":40.16},"alert":{"action_values":["breathe"]},'
	.. '"signaling":{"signal_values":["no_signal","on_off"]},"type":"grouped_light"},'
	.. '{"id":"' .. F.new_zone_rid .. '","id_v1":"/groups/5","children":[' .. child(F.rids.hallway, "light") .. '],'
	.. '"services":[' .. child(F.new_zone_grouped_light_rid, "grouped_light") .. '],'
	.. '"metadata":{"name":"Upstairs","archetype":"upstairs"},"type":"zone"}]}]'

-- The same zone deleted again: bare identifiers only.
F.events.zone_delete = '[{"creationtime":"2026-10-21T18:13:00Z","id":"9de116fc-000b-4a2b-8c3d-00000000000b","type":"delete",'
	.. '"data":[{"id":"' .. F.new_zone_grouped_light_rid .. '","type":"grouped_light"},'
	.. '{"id":"' .. F.new_zone_rid .. '","type":"zone"}]}]'

-- Scene events. Container composition [verified: hardware 2026-10-21, type
-- lists in the dev log]: a recall through the API was answered 9 ms later by
-- a container holding the `scene` item alone, and the lights and
-- grouped_lights followed in the next second; a scene recalled elsewhere
-- arrived as `grouped_light × 4, scene` in one container; one member light
-- switched off by hand gave a `light` item, then `grouped_light × 3, scene`
-- a second later. The item bodies were not logged, so their fields are
-- [assumed], modelled on the light items the bridge does send (id, id_v1
-- and only the changed block): a status change carries `status` with the
-- leaves that changed (`active` plus `last_recall` on a recall, `active`
-- alone when a scene goes inactive); a rename carries `metadata.name`; an
-- add carries the whole resource; a delete is id + type only (as a zone's).

local function scene_item(key, body)
	return '{"id":"' .. F.scene_rids[key] .. '","id_v1":"' .. F.scene_id_v1[key] .. '",' .. body .. ',"type":"scene"}'
end

local function grouped_light_item(key, owner_key, owner_rtype, id_v1, body)
	return '{"id":"' .. F.grouped_light_rids[key] .. '","id_v1":"' .. id_v1 .. '","owner":{"rid":"' .. F.group_rids[owner_key]
		.. '","rtype":"' .. owner_rtype .. '"},' .. body .. ',"type":"grouped_light"}'
end

-- Relax recalled from the Hue app: the Living Room's, Downstairs' and the
-- home's grouped_lights change, and the scene goes static in the same
-- container.
F.scene_recall_time = "2026-10-21T18:14:00.004Z"
F.events.scene_recalled = '[{"creationtime":"2026-10-21T18:14:00Z","id":"9de116fc-000c-4a2b-8c3d-00000000000c","type":"update",'
	.. '"data":['
	.. grouped_light_item("living_room", "living_room", "room", "/groups/2", '"on":{"on":true},"dimming":{"brightness":56.69}') .. ','
	.. grouped_light_item("downstairs", "downstairs", "zone", "/groups/3", '"dimming":{"brightness":56.69}') .. ','
	.. grouped_light_item("home", "home", "bridge_home", "/groups/0", '"dimming":{"brightness":64.6}') .. ','
	.. scene_item("relax", '"status":{"active":"static","last_recall":"' .. F.scene_recall_time .. '"}')
	.. ']}]'

-- Hallway Ambiance dimmed by hand a minute later: Relax is no longer what
-- the room shows, so its status goes inactive together with the
-- grouped_light updates (the light's own item came in the container before).
F.events.scene_inactive = '[{"creationtime":"2026-10-21T18:15:01Z","id":"9de116fc-000d-4a2b-8c3d-00000000000d","type":"update",'
	.. '"data":['
	.. grouped_light_item("living_room", "living_room", "room", "/groups/2", '"dimming":{"brightness":48.35}') .. ','
	.. grouped_light_item("home", "home", "bridge_home", "/groups/0", '"dimming":{"brightness":61.82}') .. ','
	.. scene_item("relax", '"status":{"active":"inactive"}')
	.. ']}]'

-- Relax renamed to Chill in the Hue app.
F.events.scene_renamed = '[{"creationtime":"2026-10-21T18:16:00Z","id":"9de116fc-000e-4a2b-8c3d-00000000000e","type":"update",'
	.. '"data":[' .. scene_item("relax", '"metadata":{"name":"Chill"}') .. ']}]'

-- Savanna sunset recalled with action "active": auto_dynamic starts the
-- palette, so the status is dynamic_palette; alone in its container, as the
-- API recall on hardware was.
F.events.scene_dynamic = '[{"creationtime":"2026-10-21T18:17:00Z","id":"9de116fc-000f-4a2b-8c3d-00000000000f","type":"update",'
	.. '"data":[' .. scene_item("savanna", '"status":{"active":"dynamic_palette","last_recall":"2026-10-21T18:17:00.219Z"}') .. ']}]'

-- A new scene "Read" created in the Living Room: the whole resource in one
-- add container.
F.new_scene_rid = "5e4d3c2b-0000-4000-8000-00000000s006"
F.new_scene_id_v1 = "/scenes/Kl3mNo7pQr1sTu5v"
F.events.scene_added = '[{"creationtime":"2026-10-21T18:18:00Z","id":"9de116fc-0010-4a2b-8c3d-000000000010","type":"add",'
	.. '"data":[{"id":"' .. F.new_scene_rid .. '","id_v1":"' .. F.new_scene_id_v1 .. '",'
	.. '"actions":[' .. scene_action("living", '"on":{"on":true},"dimming":{"brightness":100.0},"color_temperature":{"mirek":346}') .. ','
	.. scene_action("hallway", '"on":{"on":true},"dimming":{"brightness":100.0},"color_temperature":{"mirek":346}') .. '],'
	.. '"palette":{"color":[],"dimming":[],"color_temperature":[{"color_temperature":{"mirek":346},"dimming":{"brightness":100.0}}],"effects":[],"effects_v2":[]},'
	.. '"recall":{},'
	.. '"metadata":{"name":"Read","image":{"rid":"5e4d3c2b-img6-4000-8000-000000000000","rtype":"public_image"}},'
	.. '"group":{"rid":"' .. F.group_rids.living_room .. '","rtype":"room"},'
	.. '"speed":0.6269841,"auto_dynamic":false,"status":{"active":"inactive"},"mapping":{"algorithm":"classic"},'
	.. '"type":"scene"}]}]'

-- Relax deleted in the Hue app: bare identifier only (the scene an owner
-- is most likely to have imported, so specs can walk a linked scene to
-- "gone").
F.events.scene_deleted = '[{"creationtime":"2026-10-21T18:19:00Z","id":"9de116fc-0011-4a2b-8c3d-000000000011","type":"delete",'
	.. '"data":[{"id":"' .. F.scene_rids.relax .. '","type":"scene"}]}]'

-- Time-of-day ("smart") scenes as the house bridge shows them
-- [verified: hardware 2026-10-24, docs/smart-scenes-research.md §7]: the app
-- numbers repeats ("Golden hours 4"), app-made ones carry a 60 s
-- transition, `active_timeslot` is present even while inactive, and there is
-- no id_v1. Three: two in the Downstairs zone, one in the Living Room.
F.smart_scene_rids = {
	golden = F.smart_scene_rid,                     -- "Golden hours", Downstairs (zone)
	natural = "6f5e4d3c-0000-4000-8000-0000000ss002", -- "Natural light 6", Downstairs (zone)
	living = "6f5e4d3c-0000-4000-8000-0000000ss003",  -- "Golden hours 4", Living Room
}

local function slot(kind, hour, minute, target)
	local start = kind == "sunset" and '{"kind":"sunset","time":{"hour":0,"minute":0,"second":0}}'
		or string.format('{"kind":"time","time":{"hour":%d,"minute":%d,"second":0}}', hour, minute)
	return '{"start_time":' .. start .. ',"target":{"rid":"' .. target .. '","rtype":"scene"}}'
end

local EVERY_DAY = '["sunday","monday","tuesday","wednesday","thursday","friday","saturday"]'

local function smart_item(rid, name, group_rid, group_type, slots, state, slot_id)
	return '{"id":"' .. rid .. '","type":"smart_scene",'
		.. '"metadata":{"name":"' .. name .. '","image":{"rid":"6f5e4d3c-img0-4000-8000-000000000000","rtype":"public_image"}},'
		.. '"group":{"rid":"' .. group_rid .. '","rtype":"' .. group_type .. '"},'
		.. '"week_timeslots":[{"timeslots":[' .. table.concat(slots, ",") .. '],"recurrence":' .. EVERY_DAY .. '}],'
		.. '"transition_duration":60000,'
		.. '"active_timeslot":{"timeslot_id":' .. slot_id .. ',"weekday":"saturday"},'
		.. '"state":"' .. state .. '"}'
end

F.smart_scene_items = {
	golden = smart_item(F.smart_scene_rids.golden, "Golden hours", F.group_rids.downstairs, "zone",
		{ slot("time", 7, 0, F.scene_rids.bright), slot("sunset", 0, 0, F.scene_rids.nightlight) }, "inactive", 0),
	natural = smart_item(F.smart_scene_rids.natural, "Natural light 6", F.group_rids.downstairs, "zone",
		{ slot("time", 6, 30, F.scene_rids.bright), slot("time", 21, 0, F.scene_rids.nightlight) }, "inactive", 1),
	living = smart_item(F.smart_scene_rids.living, "Golden hours 4", F.group_rids.living_room, "room",
		{ slot("time", 7, 0, F.scene_rids.savanna), slot("time", 16, 0, F.scene_rids.relax) }, "inactive", 0),
}

F.smart_scenes = '{"errors":[],"data":[' .. F.smart_scene_items.golden .. ',' .. F.smart_scene_items.natural
	.. ',' .. F.smart_scene_items.living .. ']}'

local function container(seq, kind, items)
	return string.format('[{"creationtime":"2026-10-24T15:19:%02dZ","id":"9de116fc-00%02d-4a2b-8c3d-0000000000%02d",'
		.. '"type":"%s","data":[%s]}]', seq, 40 + seq, 40 + seq, kind, table.concat(items, ","))
end

-- "Golden hours 4" activated (V4 on hardware): the smart scene's state first,
-- then the slot scene (Savanna sunset, slot 0) static and the group on.
F.events.smart_activated = container(1, "update", {
	'{"id":"' .. F.smart_scene_rids.living .. '","type":"smart_scene","state":"active",'
		.. '"active_timeslot":{"timeslot_id":0,"weekday":"saturday"}}',
})
F.events.smart_slot_scene = container(2, "update", {
	'{"id":"' .. F.scene_rids.savanna .. '","type":"scene","status":{"active":"static","last_recall":"2026-10-24T15:19:12.321Z"}}',
	'{"id":"' .. F.grouped_light_rids.living_room .. '","type":"grouped_light","on":{"on":true},"dimming":{"brightness":100},'
		.. '"owner":{"rid":"' .. F.group_rids.living_room .. '","rtype":"room"}}',
})
-- The next time slot (16:00 → Relax) while it runs.
F.events.smart_next_slot = container(3, "update", {
	'{"id":"' .. F.smart_scene_rids.living .. '","type":"smart_scene","active_timeslot":{"timeslot_id":1,"weekday":"saturday"}}',
	'{"id":"' .. F.scene_rids.relax .. '","type":"scene","status":{"active":"static","last_recall":"2026-10-24T20:00:01.000Z"}}',
})
-- Deactivated, or ended by the group going off or another scene (V7, V9, V10).
F.events.smart_inactive = container(4, "update", {
	'{"id":"' .. F.smart_scene_rids.living .. '","type":"smart_scene","state":"inactive"}',
})
-- Created in the app: the add arrives already active (V12).
F.smart_scene_rids.added = "6f5e4d3c-0000-4000-8000-0000000ss004"
F.events.smart_added = container(5, "add", {
	smart_item(F.smart_scene_rids.added, "Natural light 7", F.group_rids.living_room, "room",
		{ slot("time", 7, 0, F.scene_rids.bright), slot("time", 22, 0, F.scene_rids.relax) }, "active", 0),
})
-- Renamed and re-timed in one update (V13).
F.events.smart_renamed = container(6, "update", {
	'{"id":"' .. F.smart_scene_rids.living .. '","type":"smart_scene","metadata":{"name":"Evening glow"}}',
})
-- Deleted, also what the bridge does by itself when a slot's scene is deleted (V14).
F.events.smart_deleted = container(7, "delete", {
	'{"id":"' .. F.smart_scene_rids.living .. '","type":"smart_scene"}',
})

return F
