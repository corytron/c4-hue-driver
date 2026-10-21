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

local F = {}

F.rids = {
	living = "0b216218-d811-4c95-8c55-bbcda50f9d50",
	kitchen = "7f3c9a2b-5e14-4d8f-b1a6-93c0e2d4f815",
	hallway = "c48d1e6f-2a9b-4f3e-9c7d-8e5f1a2b3c03",
	garage = "9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c04",
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
 "owner":{"rid":"]] .. F.device_rids.living .. [[","rtype":"device"},
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
 "owner":{"rid":"]] .. F.device_rids.garage .. [[","rtype":"device"},
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
 "owner":{"rid":"]] .. F.device_rids.kitchen .. [[","rtype":"device"},
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
 "owner":{"rid":"]] .. F.device_rids.hallway .. [[","rtype":"device"},
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

return F
