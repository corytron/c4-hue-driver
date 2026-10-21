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

return F
