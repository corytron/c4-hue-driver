-- luacheck: no max line length (JSON lines)
--
-- Hand-written Hue CLIP v2 bodies for entertainment areas (2.0, #514), as
-- JSON text so specs exercise the same decode path as the driver. Written
-- from the public field names of docs/entertainment-areas-research.md §2.1,
-- §2.2 and §4.1, never copied from Signify's examples; the event shapes are
-- [assumed, T1] until check T1 records a real stream's containers. Ids are
-- made up but UUID-shaped, as in tests/fixtures/hue_resources.lua; names are
-- generic.
--
-- Seven colour lamps on seven devices, and the bridge's own device:
--   tv_strip   TV Strip     on, 80, xy (0.3127, 0.329)   a gradient strip: two segments, two channels
--   tv_left    TV Left      on, 60, ct 370
--   tv_right   TV Right     off, 100, ct 250
--   tv_bar     TV Bar       on, 30, xy (0.6, 0.35)
--   floor      Floor Lamp   on, 45.5, ct 300             in both areas
--   desk       Desk Lamp    off, 20, xy (0.2, 0.2)
--   shelf      Shelf Lamp   on, 100, ct 200              its entertainment service has no
--                                                       renderer_reference: found through its device
-- Areas (E.configuration), both inactive:
--   Living Room TV   screen   /groups/200   5 lamps, listed in light_services
--   Office           music    /groups/201   3 lamps, no light_services: through the channels
-- E.desk_area is a third area for an `add` event: Desk, monitor, one lamp.

local E = {}

local function rid(prefix, n)
	return string.format("%s-0000-4000-8000-0000000%s", prefix, n)
end

E.keys = { "tv_strip", "tv_left", "tv_right", "tv_bar", "floor", "desk", "shelf" }

E.rids = {
	tv_strip = rid("4e5d6c7b", "la001"),
	tv_left = rid("4e5d6c7b", "la002"),
	tv_right = rid("4e5d6c7b", "la003"),
	tv_bar = rid("4e5d6c7b", "la004"),
	floor = rid("4e5d6c7b", "la005"),
	desk = rid("4e5d6c7b", "la006"),
	shelf = rid("4e5d6c7b", "la007"),
}

E.device_rids = {
	tv_strip = rid("3d4c5b6a", "dv001"),
	tv_left = rid("3d4c5b6a", "dv002"),
	tv_right = rid("3d4c5b6a", "dv003"),
	tv_bar = rid("3d4c5b6a", "dv004"),
	floor = rid("3d4c5b6a", "dv005"),
	desk = rid("3d4c5b6a", "dv006"),
	shelf = rid("3d4c5b6a", "dv007"),
	bridge = rid("3d4c5b6a", "dv000"),
}

-- One entertainment service per lamp device, and the bridge's (a proxy).
E.service_rids = {
	tv_strip = rid("5f6e7d8c", "es001"),
	tv_left = rid("5f6e7d8c", "es002"),
	tv_right = rid("5f6e7d8c", "es003"),
	tv_bar = rid("5f6e7d8c", "es004"),
	floor = rid("5f6e7d8c", "es005"),
	desk = rid("5f6e7d8c", "es006"),
	shelf = rid("5f6e7d8c", "es007"),
	bridge = rid("5f6e7d8c", "es000"),
}

E.area_rids = {
	tv = rid("6a7b8c9d", "ea001"),
	office = rid("6a7b8c9d", "ea002"),
	desk = rid("6a7b8c9d", "ea003"),
}

E.area_names = { tv = "Living Room TV", office = "Office", desk = "Desk" }

-- The application key that streams (an auth_v1 rid).
E.streamer = rid("7b8c9d0e", "au001")

E.names = {
	tv_strip = "TV Strip", tv_left = "TV Left", tv_right = "TV Right", tv_bar = "TV Bar",
	floor = "Floor Lamp", desk = "Desk Lamp", shelf = "Shelf Lamp",
}

-- Each area's lamps, sorted by rid (the order hue_model keeps them in).
E.tv_lamps = { "tv_strip", "tv_left", "tv_right", "tv_bar", "floor" }
E.office_lamps = { "floor", "desk", "shelf" }

local GAMUT_C = '"gamut":{"red":{"x":0.6915,"y":0.3083},"green":{"x":0.17,"y":0.7},"blue":{"x":0.1532,"y":0.0475}},"gamut_type":"C"'
local SCHEMA = '"mirek_schema":{"mirek_minimum":153,"mirek_maximum":500}'

-- A colour lamp: `state` = { on, brightness, x, y } (xy mode) or { on, brightness, mirek } (ct mode).
local function light(key, n, state)
	local xy, ct
	if state.mirek then
		xy = '{"x":0.4,"y":0.4}'
		ct = '{"mirek":' .. state.mirek .. ',"mirek_valid":true,' .. SCHEMA .. '}'
	else
		xy = '{"x":' .. state.x .. ',"y":' .. state.y .. '}'
		ct = '{"mirek":null,"mirek_valid":false,' .. SCHEMA .. '}'
	end
	return '{"id":"' .. E.rids[key] .. '","id_v1":"/lights/' .. (40 + n) .. '",'
		.. '"owner":{"rid":"' .. E.device_rids[key] .. '","rtype":"device"},"service_id":0,'
		.. '"metadata":{"name":"' .. E.names[key] .. '","archetype":"hue_lightstrip"},'
		.. '"on":{"on":' .. tostring(state.on) .. '},'
		.. '"dimming":{"brightness":' .. state.brightness .. ',"min_dim_level":0.2},'
		.. '"color_temperature":' .. ct .. ','
		.. '"color":{"xy":' .. xy .. ',' .. GAMUT_C .. '},'
		.. '"mode":"normal","type":"light"}'
end

E.light = '{"errors":[],"data":['
	.. light("tv_strip", 1, { on = true, brightness = "80.0", x = 0.3127, y = 0.329 }) .. ','
	.. light("tv_left", 2, { on = true, brightness = "60.0", mirek = 370 }) .. ','
	.. light("tv_right", 3, { on = false, brightness = "100.0", mirek = 250 }) .. ','
	.. light("tv_bar", 4, { on = true, brightness = "30.0", x = 0.6, y = 0.35 }) .. ','
	.. light("floor", 5, { on = true, brightness = "45.5", mirek = 300 }) .. ','
	.. light("desk", 6, { on = false, brightness = "20.0", x = 0.2, y = 0.2 }) .. ','
	.. light("shelf", 7, { on = true, brightness = "100.0", mirek = 200 })
	.. ']}'

local function device(key, n)
	return '{"id":"' .. E.device_rids[key] .. '","id_v1":"/lights/' .. (40 + n) .. '",'
		.. '"product_data":{"model_id":"LCX004","product_name":"Hue gradient lightstrip"},'
		.. '"metadata":{"name":"' .. E.names[key] .. '","archetype":"hue_lightstrip"},'
		.. '"services":[{"rid":"' .. E.rids[key] .. '","rtype":"light"},'
		.. '{"rid":"' .. E.service_rids[key] .. '","rtype":"entertainment"}],"type":"device"}'
end

E.device = '{"errors":[],"data":['
	.. device("tv_strip", 1) .. ',' .. device("tv_left", 2) .. ',' .. device("tv_right", 3) .. ','
	.. device("tv_bar", 4) .. ',' .. device("floor", 5) .. ',' .. device("desk", 6) .. ',' .. device("shelf", 7) .. ','
	.. '{"id":"' .. E.device_rids.bridge .. '","id_v1":"",'
	.. '"product_data":{"model_id":"BSB003","product_name":"Hue Bridge Pro"},"metadata":{"name":"Hue Bridge Pro","archetype":"bridge_v3"},'
	.. '"services":[{"rid":"' .. E.service_rids.bridge .. '","rtype":"entertainment"}],"type":"device"}'
	.. ']}'

-- A lamp's entertainment service: a renderer naming its light, or (`bare`)
-- one that leaves renderer_reference out.
local function service(key, segments, bare)
	local ref = bare and '' or ('"renderer_reference":{"rid":"' .. E.rids[key] .. '","rtype":"light"},')
	local list = {}
	for i = 1, segments do
		list[i] = '{"start":' .. (i - 1) .. ',"length":1}'
	end
	return '{"id":"' .. E.service_rids[key] .. '","owner":{"rid":"' .. E.device_rids[key] .. '","rtype":"device"},'
		.. '"renderer":true,' .. ref .. '"proxy":true,"equalizer":true,"max_streams":1,'
		.. '"segments":{"configurable":false,"max_segments":' .. segments .. ',"segments":[' .. table.concat(list, ",") .. ']},'
		.. '"type":"entertainment"}'
end

E.entertainment = '{"errors":[],"data":['
	.. service("tv_strip", 2) .. ',' .. service("tv_left", 1) .. ',' .. service("tv_right", 1) .. ','
	.. service("tv_bar", 1) .. ',' .. service("floor", 1) .. ',' .. service("desk", 1) .. ','
	.. service("shelf", 1, true) .. ','
	.. '{"id":"' .. E.service_rids.bridge .. '","owner":{"rid":"' .. E.device_rids.bridge .. '","rtype":"device"},'
	.. '"renderer":false,"proxy":true,"equalizer":false,"max_streams":1,"type":"entertainment"}'
	.. ']}'

-- A channel per member list: { { key, index }, ... } → one channel each.
local function channels(members)
	local out = {}
	for i, m in ipairs(members) do
		out[i] = '{"channel_id":' .. (i - 1) .. ',"position":{"x":' .. (i / 10) .. ',"y":0.5,"z":0},'
			.. '"members":[{"service":{"rid":"' .. E.service_rids[m[1]] .. '","rtype":"entertainment"},"index":' .. m[2] .. '}]}'
	end
	return '[' .. table.concat(out, ",") .. ']'
end

local function light_services(keys)
	local out = {}
	for i, key in ipairs(keys) do
		out[i] = '{"rid":"' .. E.rids[key] .. '","rtype":"light"}'
	end
	return '[' .. table.concat(out, ",") .. ']'
end

local function area(key, id_v1, kind, members, listed)
	return '{"id":"' .. E.area_rids[key] .. '","id_v1":"' .. id_v1 .. '","type":"entertainment_configuration",'
		.. '"metadata":{"name":"' .. E.area_names[key] .. '"},"configuration_type":"' .. kind .. '","status":"inactive",'
		.. '"stream_proxy":{"mode":"auto","node":{"rid":"' .. E.service_rids.bridge .. '","rtype":"entertainment"}},'
		.. '"channels":' .. channels(members)
		.. (listed and (',"light_services":' .. light_services(listed)) or '') .. '}'
end

E.tv_area = area("tv", "/groups/200", "screen",
	{ { "tv_strip", 0 }, { "tv_strip", 1 }, { "tv_left", 0 }, { "tv_right", 0 }, { "tv_bar", 0 }, { "floor", 0 } },
	{ "floor", "tv_left", "tv_strip", "tv_bar", "tv_right" })
E.office_area = area("office", "/groups/201", "music", { { "floor", 0 }, { "desk", 0 }, { "shelf", 0 } }, nil)
E.desk_area = area("desk", "/groups/202", "monitor", { { "desk", 0 } }, { "desk" })

E.configuration = '{"errors":[],"data":[' .. E.tv_area .. ',' .. E.office_area .. ']}'
E.no_areas = '{"errors":[],"data":[]}'

-- Event-stream containers (the JSON array one SSE `data:` line carries),
-- each with only what changed [assumed, T1].
E.events = {}

local event_n = 0
local function container(kind, items)
	event_n = event_n + 1
	return '[{"creationtime":"2026-11-14T20:00:00Z","id":"9de116fc-0e' .. string.format("%02x", event_n)
		.. '-4a2b-8c3d-0000000000e0","type":"' .. kind .. '","data":[' .. table.concat(items, ",") .. ']}]'
end

-- An area's status update: "active" carries the streamer, "inactive" none.
function E.events.area_status(key, status)
	local streamer = status == "active" and (',"active_streamer":{"rid":"' .. E.streamer .. '","rtype":"auth_v1"}') or ''
	return container("update", { '{"id":"' .. E.area_rids[key] .. '","id_v1":"' .. ({ tv = "/groups/200",
		office = "/groups/201", desk = "/groups/202" })[key] .. '","status":"' .. status .. '"' .. streamer
		.. ',"type":"entertainment_configuration"}' })
end

-- The lamps `keys` report `mode` ("streaming" or "normal"), in one container.
function E.events.lamp_mode(keys, mode)
	local items = {}
	for i, key in ipairs(keys) do
		items[i] = '{"id":"' .. E.rids[key] .. '","owner":{"rid":"' .. E.device_rids[key] .. '","rtype":"device"},'
			.. '"mode":"' .. mode .. '","type":"light"}'
	end
	return container("update", items)
end

-- Lamps' states as Hue reports them: { key = { on, brightness, x, y } or { on, brightness, mirek } }
-- (each field optional), in one container: Hue's own end state after a
-- stream (T7), or a change from the Hue app.
function E.events.lamp_state(states)
	local items = {}
	for _, key in ipairs(E.keys) do
		local s = states[key]
		if s then
			local parts = { '"id":"' .. E.rids[key] .. '"' }
			if s.on ~= nil then parts[#parts + 1] = '"on":{"on":' .. tostring(s.on) .. '}' end
			if s.brightness then parts[#parts + 1] = '"dimming":{"brightness":' .. s.brightness .. '}' end
			if s.x then
				parts[#parts + 1] = '"color":{"xy":{"x":' .. s.x .. ',"y":' .. s.y .. '}}'
				parts[#parts + 1] = '"color_temperature":{"mirek":null,"mirek_valid":false}'
			elseif s.mirek then
				parts[#parts + 1] = '"color_temperature":{"mirek":' .. s.mirek .. ',"mirek_valid":true}'
			end
			parts[#parts + 1] = '"type":"light"'
			items[#items + 1] = '{' .. table.concat(parts, ",") .. '}'
		end
	end
	return container("update", items)
end

-- The Office area renamed in the Hue app.
E.events.office_rename = container("update", { '{"id":"' .. E.area_rids.office
	.. '","metadata":{"name":"Study"},"type":"entertainment_configuration"}' })

-- The Desk area created in the Hue app.
E.events.desk_add = container("add", { E.desk_area })

-- The Office area deleted in the Hue app: a bare id and type, as other deletes.
E.events.office_delete = container("delete", { '{"id":"' .. E.area_rids.office .. '","type":"entertainment_configuration"}' })

return E
