-- Normalisation of Hue CLIP v2 resources into the flat per-light tables the
-- bridge driver keeps, and the string-valued parameter tables it sends to the
-- light drivers (docs/lights-design.md, "Bridge: model, registry, import").
-- Pure Lua, no C4 calls.
--
-- Shapes consumed (from Signify's CLIP v2 reference):
--   light               { id, id_v1, owner{rid}, service_id, metadata{name, archetype}, on{on},
--                         dimming{brightness, min_dim_level},
--                         color{xy{x,y}, gamut{red,green,blue}} (optional),
--                         color_temperature{mirek, mirek_valid,
--                           mirek_schema{mirek_minimum, mirek_maximum}} (optional) }
--   device              { id, product_data{model_id, product_name}, metadata{name},
--                         services[{rid, rtype}] }
--   zigbee_connectivity { id, owner{rid}, status, mac_address }
--   room / zone         { id, id_v1, metadata{name, archetype}, children[{rid, rtype}],
--                         services[{rid, rtype}] }   -- room children are devices, zone
--                                                    -- children are lights; rooms also carry
--                                                    -- a geometry block (ignored); an empty
--                                                    -- zone has [] children and [] services
--                                                    -- [verified: hardware 2026-10-21]
--   bridge_home         { id, id_v1, children[{rid, rtype}], services[{rid, rtype}] }
--                         -- children mix room-less devices and rooms; no metadata
--                         -- at all [verified: hardware 2026-10-21]
--   scene               { id, id_v1, actions[{target{rid, rtype}, action{on, dimming, color,
--                         color_temperature}}], palette{color[], dimming[], color_temperature[],
--                         effects[], effects_v2[]}, recall{}, metadata{name, image{rid, rtype}},
--                         group{rid, rtype}, speed, auto_dynamic,
--                         status{active, last_recall}, mapping{algorithm},
--                         last_actions_update{source} }   -- [verified: hardware 2026-10-21,
--                                                        -- GET /scene/<rid>]; actions, palette
--                                                        -- and image are dropped at decode time
--   smart_scene         { id, metadata{name, image}, group{rid, rtype}, week_timeslots[{timeslots[
--                         {start_time{kind, time{hour, minute, second}}, target{rid, rtype}}],
--                         recurrence[weekday]}], transition_duration,
--                         active_timeslot{timeslot_id, weekday}, state }
--                                                        -- [verified: hardware 2026-10-24,
--                                                        -- docs/smart-scenes-research.md §7];
--                                                        -- no id_v1; image dropped at decode
-- Event-stream items have the same shapes with only the changed fields.
-- A JSON null (mirek while mirek_valid is false) is treated like an absent
-- field, whatever the decoder turns it into: only numbers count as numbers.
--
-- Every constructor keeps an item only when its `id` is a resource id
-- (resource_id below); anything else is dropped with one debug line, since
-- the rids the registries keep end up in request paths (recall, activate,
-- the PUT queues) [security review 2026-10-24 finding 5, issue #45].

local log = require("common.log")

local hue_model = {}

-- Normalised-light fields that HUE_STATE may carry, in emission order.
hue_model.STATE_FIELDS = { "on", "brightness", "x", "y", "mirek", "color_mode", "online" }

-- Every field update() can report as changed, in a stable order.
local FIELD_ORDER = { "on", "brightness", "x", "y", "mirek", "color_mode", "online",
	"name", "archetype", "min_dim", "mirek_min", "mirek_max", "gamut" }

local STATE_SET = {}
for _, name in ipairs(hue_model.STATE_FIELDS) do
	STATE_SET[name] = true
end

local function number(value)
	if type(value) == "number" then
		return value
	end
	return nil
end

local function point(value)
	if type(value) == "table" and number(value.x) and number(value.y) then
		return { x = value.x, y = value.y }
	end
	return nil
end

-- A non-empty string, else nil (the bridge's own device carries id_v1 "").
local function text(value)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

-- A CLIP v2 resource id: letters, digits and "-" only, so nothing else can
-- reach a request path ("?", "/", spaces, a table from a decoded JSON null);
-- else nil. The bridge's ids are UUIDs [assumed: Signify's CLIP v2
-- reference, which gives every id as one].
local function resource_id(value)
	if type(value) == "string" and value:find("^[%w%-]+$") then
		return value
	end
	return nil
end
hue_model.resource_id = resource_id

-- How a rejected id reads in the debug line: short, on one line.
local function shown(value)
	if type(value) == "string" then
		return string.format("id \"%s\"", (value:sub(1, 40):gsub("%c", "?")))
	elseif value == nil then
		return "no id"
	end
	return "a " .. type(value) .. " id"
end

-- The item's id when it is a resource id, else nil after one debug line
-- naming the kind of item dropped.
local function item_id(item, what)
	local id = resource_id(item.id)
	if id == nil then
		log.debug("hue_model: dropped a %s item with %s: not a resource id", what, shown(item.id))
	end
	return id
end

-- [assumed] Hue has no explicit "colour mode" field. color_temperature
-- .mirek_valid is documented as "whether the mirek value is valid for the
-- current colour"; observed behaviour is that it is true while the light sits
-- at a white point set through mirek, and false (with mirek null) once an xy
-- colour is set. So: mirek_valid → "ct"; otherwise "xy" when the light has a
-- colour; a CCT-only light whose mirek is invalid has no mode. To be
-- confirmed on hardware through the dev loop.
function hue_model.color_mode(light)
	if light.has_cct and light.mirek_valid then
		return "ct"
	elseif light.has_color and light.x ~= nil then
		return "xy"
	end
	return nil
end

-- Merge a (possibly partial) light item into `light` in place. Returns the
-- list of field names the item carried, in FIELD_ORDER; "color_mode" is
-- included whenever a colour field was touched or the derived mode changed,
-- so a receiver always gets the mode together with x/y or mirek. Fields the
-- item carries count as changed even when the value is the same, since the
-- bridge only sends what changed and a receiver may be waiting for the echo.
function hue_model.update(light, item)
	local touched = {}
	if type(item) ~= "table" then
		return {}
	end

	if type(item.metadata) == "table" then
		if item.metadata.name ~= nil then
			light.name = tostring(item.metadata.name)
			touched.name = true
		end
		if item.metadata.archetype ~= nil then
			light.archetype = tostring(item.metadata.archetype)
			touched.archetype = true
		end
	end

	if type(item.on) == "table" and item.on.on ~= nil then
		light.on = item.on.on == true
		touched.on = true
	end

	if type(item.dimming) == "table" then
		if number(item.dimming.brightness) then
			light.brightness = item.dimming.brightness
			touched.brightness = true
		end
		if number(item.dimming.min_dim_level) then
			light.min_dim = item.dimming.min_dim_level
			touched.min_dim = true
		end
	end

	local color_touched = false
	if type(item.color) == "table" then
		local xy = point(item.color.xy)
		if xy then
			light.x, light.y = xy.x, xy.y
			touched.x, touched.y = true, true
			color_touched = true
		end
		local gamut = item.color.gamut
		if type(gamut) == "table" then
			light.gamut = { r = point(gamut.red), g = point(gamut.green), b = point(gamut.blue) }
			touched.gamut = true
		end
	end

	if type(item.color_temperature) == "table" then
		local ct = item.color_temperature
		local mirek = number(ct.mirek)
		if ct.mirek_valid ~= nil then
			light.mirek_valid = ct.mirek_valid == true
			light.mirek = light.mirek_valid and mirek or nil
			touched.mirek = true
			color_touched = true
		elseif mirek then
			-- [assumed] an item with a numeric mirek and no mirek_valid means
			-- the value is valid.
			light.mirek_valid = true
			light.mirek = mirek
			touched.mirek = true
			color_touched = true
		end
		local schema = ct.mirek_schema
		if type(schema) == "table" then
			if number(schema.mirek_minimum) then
				light.mirek_min = schema.mirek_minimum
				touched.mirek_min = true
			end
			if number(schema.mirek_maximum) then
				light.mirek_max = schema.mirek_maximum
				touched.mirek_max = true
			end
		end
	end

	local mode = hue_model.color_mode(light)
	if color_touched or mode ~= light.color_mode then
		light.color_mode = mode
		touched.color_mode = true
	end

	local changed = {}
	for _, name in ipairs(FIELD_ORDER) do
		if touched[name] then
			changed[#changed + 1] = name
		end
	end
	return changed
end

-- One /clip/v2/resource/light item → the normalised light of the contract,
-- or nil for an item that is not a table or whose id is not a resource id.
-- `online` is not part of the resource; the registry owner sets it from
-- zigbee_connectivity (nil until known). `id_v1` ("/lights/12") and
-- `service_id` (0 for the only light of a device, 0/1/… on a multi-light
-- device) are display and disambiguation data only; update() does not touch
-- them, so an event never reports them as changed.
function hue_model.light(item)
	if type(item) ~= "table" then
		return nil
	end
	local rid = item_id(item, "light")
	if rid == nil then
		return nil
	end
	local light = {
		rid = rid,
		id_v1 = text(item.id_v1),
		device_rid = type(item.owner) == "table" and item.owner.rid or nil,
		service_id = number(item.service_id),
		name = nil,
		archetype = nil,
		on = nil,
		brightness = nil,
		min_dim = nil,
		has_color = type(item.color) == "table",
		x = nil,
		y = nil,
		gamut = nil,
		has_cct = type(item.color_temperature) == "table",
		mirek = nil,
		mirek_valid = false,
		mirek_min = nil,
		mirek_max = nil,
		color_mode = nil,
	}
	hue_model.update(light, item)
	if light.name == nil then
		light.name = "Hue light " .. tostring(item.id_v1 or item.id)
	end
	return light
end

-- The model string shown for a device: product_name, else model_id.
function hue_model.model_string(product_data)
	if type(product_data) ~= "table" then
		return nil
	end
	local name = product_data.product_name
	if name ~= nil and name ~= "" then
		return tostring(name)
	end
	if product_data.model_id ~= nil then
		return tostring(product_data.model_id)
	end
	return nil
end

-- /clip/v2/resource/device items → device rid → { name, model, model_id,
-- light_rids, zigbee_rid }. Devices without a light service (the bridge
-- itself, sensors) are kept with an empty light_rids; an item whose id is
-- not a resource id is left out.
function hue_model.devices(items)
	local out = {}
	for _, item in ipairs(items or {}) do
		if type(item) == "table" and item_id(item, "device") ~= nil then
			local product = type(item.product_data) == "table" and item.product_data or {}
			local device = {
				name = type(item.metadata) == "table" and item.metadata.name or nil,
				model = hue_model.model_string(product),
				model_id = product.model_id,
				light_rids = {},
				zigbee_rid = nil,
			}
			for _, service in ipairs(type(item.services) == "table" and item.services or {}) do
				if type(service) == "table" then
					if service.rtype == "light" then
						device.light_rids[#device.light_rids + 1] = service.rid
					elseif service.rtype == "zigbee_connectivity" then
						device.zigbee_rid = service.rid
					end
				end
			end
			out[item.id] = device
		end
	end
	return out
end

-- One zigbee_connectivity item (full or event) → { rid, device_rid, status,
-- online, mac_address }. Only "connected" counts as online;
-- "connectivity_issue", "disconnected" and "unidirectional_incoming" all mean
-- commands may not reach the light. `mac_address` is the radio's IEEE
-- address, the registry's recovery key for a bulb deleted and re-added
-- (docs/import-design.md §3); events carry it only when it is in the item.
function hue_model.connectivity(item)
	return {
		rid = item.id,
		device_rid = type(item.owner) == "table" and item.owner.rid or nil,
		status = item.status,
		online = item.status == "connected",
		mac_address = text(item.mac_address),
	}
end

-- What HUE_CONFIGURE and the command queue need from a light, as numbers and
-- booleans: the registry persists this so both work before the first GET.
function hue_model.caps(light)
	return {
		has_color = light.has_color == true,
		has_cct = light.has_cct == true,
		mirek_min = light.mirek_min,
		mirek_max = light.mirek_max,
		min_dim = light.min_dim,
	}
end

-- HUE_STATE params: rid, reason, and the listed fields (all of STATE_FIELDS
-- when `fields` is nil) that have a value. Every value is a string. Names
-- outside STATE_FIELDS (as update() may return) are ignored.
function hue_model.state_params(light, fields, reason)
	local params = { rid = tostring(light.rid), reason = reason or "event" }
	for _, name in ipairs(fields or hue_model.STATE_FIELDS) do
		if STATE_SET[name] and light[name] ~= nil then
			params[name] = tostring(light[name])
		end
	end
	return params
end

-- True when a HUE_STATE params table carries something beyond rid and reason.
function hue_model.has_state(params)
	for _, name in ipairs(hue_model.STATE_FIELDS) do
		if params[name] ~= nil then
			return true
		end
	end
	return false
end

-- Merge the scalar fields of `extra` (expected: hue_room, id_v1, state; any
-- string-keyed string, number or boolean is taken) into `params` as strings,
-- after the existing fields. nil and "" are skipped for the same reason the
-- functions below leave valueless fields out; tables are never a param.
local function merge_extra(params, extra)
	if type(extra) ~= "table" then
		return params
	end
	for key, value in pairs(extra) do
		local kind = type(value)
		if type(key) == "string" and ((kind == "string" and value ~= "") or kind == "number" or kind == "boolean") then
			params[key] = tostring(value)
		end
	end
	return params
end

-- HUE_CONFIGURE params from a registry-shaped record { rid, name, model,
-- caps }. Every value is a string; fields without a value are left out
-- (C4:SendToDevice drops empty strings anyway, so this keeps the fake and
-- the controller identical). `extra` (optional) adds the import-ui fields
-- `hue_room`, `id_v1`, `state` (docs/import-design.md §4).
function hue_model.registry_configure_params(rid, entry, extra)
	local caps = type(entry.caps) == "table" and entry.caps or {}
	local params = {
		rid = tostring(rid),
		name = entry.name ~= nil and tostring(entry.name) or nil,
		model = entry.model ~= nil and tostring(entry.model) or nil,
		has_color = tostring(caps.has_color == true),
		has_cct = tostring(caps.has_cct == true),
	}
	for _, name in ipairs({ "mirek_min", "mirek_max", "min_dim" }) do
		if caps[name] ~= nil then
			params[name] = tostring(caps[name])
		end
	end
	return merge_extra(params, extra)
end

-- Groups ---------------------------------------------------------------------

-- The rtype a group's children nominally have [verified: Core Concepts, and
-- hardware 2026-10-21: 46 room children all "device", 80 zone children all
-- "light"]. bridge_home mixes devices and rooms; "room" is only its nominal
-- value and `child_rtypes` is the truth per child.
local GROUP_CHILD_RTYPE = { room = "device", zone = "light", bridge_home = "room" }

-- Every field update_group() can report as changed, in a stable order.
local GROUP_FIELD_ORDER = { "name", "children", "grouped_light_rid", "id_v1" }

-- Merge a (possibly partial) room / zone / bridge_home item into `group` in
-- place and return the field names the item carried, in GROUP_FIELD_ORDER
-- (carried counts as changed, as update() does). A `children` array
-- replaces the whole list [assumed: the bridge sends the array whole,
-- docs/edge-cases-hue.md §2]; `child_rtype` follows the children when they
-- all share one rtype and falls back to the group type's nominal rtype
-- otherwise, while `child_rtypes` always records each child's own rtype.
function hue_model.update_group(group, item)
	local touched = {}
	if type(item) ~= "table" then
		return {}
	end

	if type(item.metadata) == "table" and item.metadata.name ~= nil then
		group.name = tostring(item.metadata.name)
		touched.name = true
	end

	if type(item.children) == "table" then
		local children, rtypes, shared = {}, {}, nil
		for _, ref in ipairs(item.children) do
			if type(ref) == "table" and ref.rid ~= nil then
				local rtype = text(ref.rtype) or "unknown"
				children[#children + 1] = ref.rid
				rtypes[ref.rid] = rtype
				if shared == nil then
					shared = rtype
				elseif shared ~= rtype then
					shared = false
				end
			end
		end
		group.children = children
		group.child_rtypes = rtypes
		group.child_rtype = (shared and shared ~= "unknown") and shared or GROUP_CHILD_RTYPE[group.type]
		touched.children = true
	end

	if type(item.services) == "table" then
		for _, service in ipairs(item.services) do
			-- The grouped_light rid ends up in the group queue's PUT path.
			if type(service) == "table" and service.rtype == "grouped_light" and resource_id(service.rid) then
				group.grouped_light_rid = service.rid
				touched.grouped_light_rid = true
			end
		end
	end

	if text(item.id_v1) then
		group.id_v1 = item.id_v1
		touched.id_v1 = true
	end

	local changed = {}
	for _, name in ipairs(GROUP_FIELD_ORDER) do
		if touched[name] then
			changed[#changed + 1] = name
		end
	end
	return changed
end

-- One /clip/v2/resource/room, /zone or /bridge_home item → the group of the
-- contract (docs/import-design.md §13):
--   { rid, type, name, children = { rid... }, child_rtype, child_rtypes = { [rid] = rtype },
--     grouped_light_rid, id_v1 }
-- nil for an item of any other type, or whose id is not a resource id. A
-- room or zone without a name gets a fallback like light(); bridge_home has
-- no name (nil). `grouped_light_rid` is nil for an empty zone, whose
-- services array is empty [verified: hardware 2026-10-21].
function hue_model.group(item)
	if type(item) ~= "table" or GROUP_CHILD_RTYPE[item.type] == nil then
		return nil
	end
	local rid = item_id(item, item.type)
	if rid == nil then
		return nil
	end
	local group = {
		rid = rid,
		type = item.type,
		name = nil,
		children = {},
		child_rtype = GROUP_CHILD_RTYPE[item.type],
		child_rtypes = {},
		grouped_light_rid = nil,
		id_v1 = nil,
	}
	hue_model.update_group(group, item)
	if group.name == nil and item.type ~= "bridge_home" then
		group.name = "Hue " .. item.type .. " " .. tostring(group.id_v1 or item.id)
	end
	return group
end

-- Scenes ---------------------------------------------------------------------
-- docs/scenes-design.md §1 "Catalogue" and §8: the catalogue keeps one compact
-- table per scene (125 scenes × ~3 KB on the house bridge, so `actions`,
-- `palette` and `metadata.image` are dropped as the item is decoded).

-- The group rtypes the contract names; a scene under any other rtype
-- (aiohue also knows service_group and private_group, docs/edge-cases-hue.md
-- §3) keeps its group_rid with a nil group_type.
local SCENE_GROUP_TYPES = { room = true, zone = true, bridge_home = true }

-- Every field update_scene() can report as changed, in a stable order.
local SCENE_FIELD_ORDER = { "name", "active", "auto_dynamic", "speed", "group_rid" }

-- Merge a (possibly partial) scene item into `scene` in place and return the
-- field names the item carried, in SCENE_FIELD_ORDER (carried counts as
-- changed, as update() does). A stream item carries only what changed: a
-- status update `status{active, last_recall?}`, a rename `metadata{name}`,
-- a group change `group{rid, rtype}` [assumed: modelled on the light items,
-- docs/edge-cases-hue.md §3]. `last_recall` rides along with `active` and is
-- never reported on its own; `status.active` is stored as sent (the bridge's
-- values are inactive / static / dynamic_palette). `id_v1`, `actions`,
-- `palette` and `metadata.image` are ignored. The controller decodes a JSON
-- null as an empty table, so every field is type-checked.
function hue_model.update_scene(scene, item)
	local touched = {}
	if type(item) ~= "table" then
		return {}
	end

	if type(item.metadata) == "table" and text(item.metadata.name) then
		scene.name = item.metadata.name
		touched.name = true
	end

	if type(item.status) == "table" then
		if text(item.status.active) then
			scene.active = item.status.active
			touched.active = true
		end
		if text(item.status.last_recall) then
			scene.last_recall = item.status.last_recall
		end
	end

	if type(item.auto_dynamic) == "boolean" then
		scene.auto_dynamic = item.auto_dynamic
		touched.auto_dynamic = true
	end

	if number(item.speed) then
		scene.speed = item.speed
		touched.speed = true
	end

	if type(item.group) == "table" and text(item.group.rid) then
		scene.group_rid = item.group.rid
		scene.group_type = SCENE_GROUP_TYPES[item.group.rtype] and item.group.rtype or nil
		touched.group_rid = true
	end

	local changed = {}
	for _, name in ipairs(SCENE_FIELD_ORDER) do
		if touched[name] then
			changed[#changed + 1] = name
		end
	end
	return changed
end

-- One /clip/v2/resource/scene item (or a complete `add` stream item) → the
-- compact scene of the contract (docs/scenes-design.md §8):
--   { rid, name, group_rid, group_type ("room"|"zone"|"bridge_home"|nil), id_v1,
--     active ("inactive"|"static"|"dynamic_palette"|nil), last_recall, auto_dynamic (boolean),
--     speed (number|nil) }
-- nil for an item of any other type (a grouped_light sharing the container,
-- a smart_scene, a bare item without type) or whose id is not a resource id.
-- A nameless scene gets a fallback name like light(); `id_v1`
-- ("/scenes/<16 chars>") is display data read once here, as for lights, so
-- update_scene() never reports it.
function hue_model.scene(item)
	if type(item) ~= "table" or item.type ~= "scene" then
		return nil
	end
	local rid = item_id(item, "scene")
	if rid == nil then
		return nil
	end
	local scene = {
		rid = rid,
		name = nil,
		group_rid = nil,
		group_type = nil,
		id_v1 = text(item.id_v1),
		active = nil,
		last_recall = nil,
		auto_dynamic = false,
		speed = nil,
	}
	hue_model.update_scene(scene, item)
	if scene.name == nil then
		scene.name = "Hue scene " .. tostring(scene.id_v1 or item.id)
	end
	return scene
end

-- HUE_SCENE_STATE params (docs/scenes-design.md §2): { rid, active, reason },
-- every value a string. `active` is left out while the scene's status is
-- unknown (nil), as state_params() leaves valueless fields out; every scene
-- the house bridge serves carries one [verified: hardware 2026-10-21].
function hue_model.scene_state_params(scene, reason)
	local params = { rid = tostring(scene.rid), reason = reason or "event" }
	if scene.active ~= nil then
		params.active = tostring(scene.active)
	end
	return params
end

-- HUE_SCENE_CONFIGURE params from a scene-shaped record { rid, name, id_v1,
-- auto_dynamic } (a catalogue scene, or a registry entry given its rid):
-- { rid, name, id_v1?, auto_dynamic ("true"/"false") }, plus the string
-- fields of `extra` (group_name, group_type, state, gone_since; nil and ""
-- skipped) merged as registry_configure_params() does. Every value is a string.
function hue_model.scene_configure_params(scene, extra)
	local params = {
		rid = tostring(scene.rid),
		name = scene.name ~= nil and tostring(scene.name) or nil,
		id_v1 = text(scene.id_v1),
		auto_dynamic = tostring(scene.auto_dynamic == true),
	}
	return merge_extra(params, extra)
end

-- Smart scenes ---------------------------------------------------------------
-- docs/smart-scenes-design.md, "Interfaces": Hue's time-based scenes ("Golden
-- hours", "Natural light"; CLIP v2 `smart_scene`), each a weekly schedule of
-- ordinary scenes for one room or zone, kept as one compact table. As the
-- house bridge sends them [verified: hardware 2026-10-24,
-- docs/smart-scenes-research.md §7]: `start_time.kind` "time" or "sunset" (a
-- sunset start carries a zero time block too), `active_timeslot` present even
-- while the scene is inactive, `transition_duration` 60000 on app-made ones,
-- no id_v1; feed updates carry only what changed ({state, active_timeslot},
-- {active_timeslot}, {metadata{name}}, {week_timeslots}).

-- The states the contract knows; any other string leaves `state` nil.
local SMART_SCENE_STATES = { active = true, inactive = true }

-- Every field update_smart_scene() can report as changed, in a stable order.
local SMART_SCENE_FIELD_ORDER = { "name", "base_name", "state", "slot_id", "slot_weekday", "slots",
	"transition_duration", "group_rid", "group_type" }

-- A whole number from 0 up (a timeslot_id, an hour, a minute), else nil.
local function whole(value)
	if type(value) == "number" and value >= 0 and value == math.floor(value) then
		return value
	end
	return nil
end

-- A timeslot's start as the devices show it: "07:00" (HH:MM, zero-padded,
-- seconds dropped) for kind "time"; the kind itself for any other kind
-- ("sunset", "sunrise" [community: aiohue]), whose time block is ignored; nil
-- without a kind, or for a "time" without a whole hour and minute in range.
local function slot_start(start_time)
	if type(start_time) ~= "table" then
		return nil
	end
	local kind = text(start_time.kind)
	if kind ~= "time" then
		return kind
	end
	local time = type(start_time.time) == "table" and start_time.time or {}
	local hour, minute = whole(time.hour), whole(time.minute)
	if hour and minute and hour < 24 and minute < 60 then
		return string.format("%02d:%02d", hour, minute)
	end
	return nil
end

-- A week entry's `recurrence` → its weekday names as sent (strings only).
local function weekdays(recurrence)
	local days = {}
	for _, day in ipairs(type(recurrence) == "table" and recurrence or {}) do
		if text(day) then
			days[#days + 1] = day
		end
	end
	return days
end

-- `week_timeslots` → the contract's flat slot list: entry by entry, each
-- entry's timeslots in order, every slot with its own copy of the entry's
-- days. A malformed timeslot keeps its place with `start` / `target_rid` nil,
-- so that a timeslot_id still names the right slot; an entry that is not a
-- table holds none.
local function week_slots(week_timeslots)
	local slots = {}
	for _, week in ipairs(week_timeslots) do
		if type(week) == "table" then
			for _, timeslot in ipairs(type(week.timeslots) == "table" and week.timeslots or {}) do
				local slot = { days = weekdays(week.recurrence), start = nil, target_rid = nil }
				if type(timeslot) == "table" then
					slot.start = slot_start(timeslot.start_time)
					slot.target_rid = type(timeslot.target) == "table" and text(timeslot.target.rid) or nil
				end
				slots[#slots + 1] = slot
			end
		end
	end
	return slots
end

local function contains(list, value)
	for _, entry in ipairs(type(list) == "table" and list or {}) do
		if entry == value then
			return true
		end
	end
	return false
end

local function same_list(a, b)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

-- True when two slot lists hold the same slots (the same table, or nil and
-- nil, counts as the same).
local function same_slots(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return false
	end
	for i = 1, #a do
		local x, y = a[i], b[i]
		if type(x) ~= "table" or type(y) ~= "table" or x.start ~= y.start or x.target_rid ~= y.target_rid
			or not same_list(x.days, y.days) then
			return false
		end
	end
	return true
end

-- A name without the number the Hue app gives repeats (owner's answer 4,
-- docs/smart-scenes-design.md Decision 7): one trailing " <digits>" goes,
-- "Golden hours 4" → "Golden hours", "Scene 2 3" → "Scene 2". A name without
-- one, or one that would be left blank (" 4"), comes back unchanged; nil for
-- anything that is not a string.
function hue_model.base_name(name)
	if type(name) ~= "string" then
		return nil
	end
	local base = name:match("^(.*) %d+$")
	if base ~= nil and base:find("%S") then
		return base
	end
	return name
end

-- Merge a (possibly partial) smart_scene item into `model` in place:
-- `metadata.name` (base_name follows it), `state`, each leaf of
-- `active_timeslot` on its own (timeslot_id → slot_id, weekday →
-- slot_weekday), `week_timeslots` (replaces the whole slot list),
-- `transition_duration` and `group`. Unlike update_scene(), values are
-- compared: the result lists the fields whose value changed, in
-- SMART_SCENE_FIELD_ORDER, and holds the same names as keys
-- (`changed.state == true`); it is nil when nothing changed (a state or slot
-- sent again, a renumbering that leaves base_name as it was, a delete item's
-- bare id). A `state` string other than "active" / "inactive" makes state
-- nil; any other value of the wrong type (the controller decodes a JSON null
-- as an empty table) is ignored like an absent field. Never raises.
function hue_model.update_smart_scene(model, item)
	if type(model) ~= "table" or type(item) ~= "table" then
		return nil
	end
	local before = {}
	for _, name in ipairs(SMART_SCENE_FIELD_ORDER) do
		before[name] = model[name]
	end

	if type(item.metadata) == "table" and text(item.metadata.name) then
		model.name = item.metadata.name
		model.base_name = hue_model.base_name(model.name)
	end

	if type(item.state) == "string" then
		model.state = SMART_SCENE_STATES[item.state] and item.state or nil
	end

	local active = item.active_timeslot
	if type(active) == "table" then
		if whole(active.timeslot_id) then
			model.slot_id = active.timeslot_id
		end
		if text(active.weekday) then
			model.slot_weekday = active.weekday
		end
	end

	if type(item.week_timeslots) == "table" then
		model.slots = week_slots(item.week_timeslots)
	end

	if number(item.transition_duration) then
		model.transition_duration = item.transition_duration
	end

	if type(item.group) == "table" and text(item.group.rid) then
		model.group_rid = item.group.rid
		model.group_type = SCENE_GROUP_TYPES[item.group.rtype] and item.group.rtype or nil
	end

	local changed = {}
	for _, name in ipairs(SMART_SCENE_FIELD_ORDER) do
		local same
		if name == "slots" then
			same = same_slots(before.slots, model.slots)
		else
			same = before[name] == model[name]
		end
		if not same then
			changed[#changed + 1] = name
			changed[name] = true
		end
	end
	if #changed == 0 then
		return nil
	end
	return changed
end

-- One /clip/v2/resource/smart_scene item (a GET's, or a complete `add` stream
-- item, which arrives already active) → the compact smart scene of the
-- contract:
--   { rid, name, base_name, group_rid, group_type ("room"|"zone"|"bridge_home"|nil),
--     state ("active"|"inactive"|nil), slot_id (from 0), slot_weekday,
--     slots = { { days = { weekday... }, start ("07:00"|"sunset"|...|nil), target_rid }... },
--     transition_duration (ms) }
-- nil for an item of any other type (a scene or grouped_light sharing the
-- container), whose id is not a resource id, or not a table. `slots` is
-- always a list (empty without week_timeslots), `metadata.image` is dropped,
-- and a nameless smart scene gets a fallback name like scene(); base_name is
-- always base_name(name).
function hue_model.smart_scene(item)
	if type(item) ~= "table" or item.type ~= "smart_scene" then
		return nil
	end
	local rid = item_id(item, "smart_scene")
	if rid == nil then
		return nil
	end
	local model = {
		rid = rid,
		name = nil,
		base_name = nil,
		group_rid = nil,
		group_type = nil,
		state = nil,
		slot_id = nil,
		slot_weekday = nil,
		slots = {},
		transition_duration = nil,
	}
	hue_model.update_smart_scene(model, item)
	if model.name == nil then
		model.name = "Hue time-based scene " .. rid
		model.base_name = hue_model.base_name(model.name)
	end
	return model
end

-- The slot the bridge reports as current (one of `model.slots` itself), or
-- nil. timeslot_id counts from 0 within the week entry that holds the weekday
-- [verified: hardware 2026-10-24, V3: slot 0 at 11:19 on a Saturday was the
-- 07:00 slot], so this is the (slot_id + 1)-th slot whose days include
-- slot_weekday (Hue keeps each weekday in one entry). The bridge reports a
-- slot while the scene is inactive too. nil when the slot or the weekday is
-- unknown, no entry holds the weekday, or slot_id is past that entry's end.
function hue_model.current_slot(model)
	if type(model) ~= "table" or type(model.slots) ~= "table" then
		return nil
	end
	local slot_id, weekday = whole(model.slot_id), text(model.slot_weekday)
	if slot_id == nil or weekday == nil then
		return nil
	end
	local position = 0
	for _, slot in ipairs(model.slots) do
		if type(slot) == "table" and contains(slot.days, weekday) then
			if position == slot_id then
				return slot
			end
			position = position + 1
		end
	end
	return nil
end

-- Grouped lights and zone lights -----------------------------------------------
-- docs/zone-light-design.md: a Hue zone or room as a light_v2 light. A
-- grouped_light item (GET or stream) carries `on.on` (true while any member
-- is lit) and `dimming.brightness` (the average of the lit members), plus
-- `owner {rid, rtype}`, `id_v1` and blocks the driver ignores (alert,
-- signaling, dimming_delta, dynamics) [verified: hardware, docs/smart-scenes-
-- research.md §7 V4, V12]. No colour has ever appeared in one, so a group's
-- colour is derived from its member lights (group_color) and its
-- capabilities are the union of theirs (group_caps), Decisions 7 and 8.

-- Every field update_grouped_light() can report as changed, in a stable order.
local GROUPED_LIGHT_FIELD_ORDER = { "on", "brightness" }

-- The `model` HUE_CONFIGURE carries for a group device, by group type.
local GROUP_MODEL = { zone = "Hue zone", room = "Hue room" }

-- Merge a (possibly partial) grouped_light item into `model` in place and
-- return the field names the item carried, in GROUPED_LIGHT_FIELD_ORDER
-- (carried counts as changed, as update() does: a device may be waiting for
-- the echo of what it set). An `owner` is taken when carried but never
-- reported: a grouped_light never changes hands. Only booleans and numbers
-- count (the controller decodes a JSON null as an empty table).
function hue_model.update_grouped_light(model, item)
	local touched = {}
	if type(model) ~= "table" or type(item) ~= "table" then
		return {}
	end
	if type(item.owner) == "table" and text(item.owner.rid) then
		model.owner_rid = item.owner.rid
		model.owner_type = text(item.owner.rtype)
	end
	if type(item.on) == "table" and type(item.on.on) == "boolean" then
		model.on = item.on.on
		touched.on = true
	end
	if type(item.dimming) == "table" and number(item.dimming.brightness) then
		model.brightness = item.dimming.brightness
		touched.brightness = true
	end
	local changed = {}
	for _, name in ipairs(GROUPED_LIGHT_FIELD_ORDER) do
		if touched[name] then
			changed[#changed + 1] = name
		end
	end
	return changed
end

-- One /clip/v2/resource/grouped_light item (a GET's, or a stream item) →
--   { rid, owner_rid, owner_type ("room"|"zone"|"bridge_home"|nil), on (boolean|nil), brightness (number|nil) }
-- nil for an item whose id is not a resource id, or of another type when it
-- names one (a light sharing the container). A bare update item (no owner
-- block) has nil owner fields: the caller resolves the owner through the
-- group cache.
function hue_model.grouped_light(item)
	if type(item) ~= "table" or (item.type ~= nil and item.type ~= "grouped_light") then
		return nil
	end
	local rid = item_id(item, "grouped_light")
	if rid == nil then
		return nil
	end
	local model = { rid = rid, owner_rid = nil, owner_type = nil, on = nil, brightness = nil }
	hue_model.update_grouped_light(model, item)
	return model
end

-- The capabilities of a group from its member lights (a list of light()
-- tables, members without a model left out by the caller), Decision 7: the
-- union of the flags (`has_color` if any member has colour, `has_cct` if any
-- has colour temperature); the mirek range is the intersection of the
-- CT-capable members' ranges (the largest minimum, the smallest maximum),
-- or the first ranged member's own range when the intersection is empty;
-- nil bounds when no member has a range. `min_dim` is 1: Hue clamps per
-- lamp. The shape is caps()'s, so registry_configure_params() takes it.
function hue_model.group_caps(lights)
	local caps = { has_color = false, has_cct = false, mirek_min = nil, mirek_max = nil, min_dim = 1 }
	local lo, hi, first_lo, first_hi
	for _, light in ipairs(type(lights) == "table" and lights or {}) do
		if type(light) == "table" then
			if light.has_color == true then
				caps.has_color = true
			end
			if light.has_cct == true then
				caps.has_cct = true
				if number(light.mirek_min) and number(light.mirek_max) then
					if first_lo == nil then
						first_lo, first_hi = light.mirek_min, light.mirek_max
					end
					lo = lo and math.max(lo, light.mirek_min) or light.mirek_min
					hi = hi and math.min(hi, light.mirek_max) or light.mirek_max
				end
			end
		end
	end
	if lo and hi then
		if lo > hi then
			lo, hi = first_lo, first_hi
		end
		caps.mirek_min, caps.mirek_max = lo, hi
	end
	return caps
end

-- The colour a group device shows, Decision 8, from its member lights in
-- group order: `{ x, y, color_mode = "xy" }` of the first lit colour-capable
-- member sitting in xy mode; else `{ mirek, color_mode = "ct" }` of the
-- first lit member with a valid mirek; nil while no member is lit (or none
-- shows a colour). Never "last commanded": it would lie after a Hue-app change.
function hue_model.group_color(lights)
	local ct
	for _, light in ipairs(type(lights) == "table" and lights or {}) do
		if type(light) == "table" and light.on == true then
			if light.has_color == true and light.color_mode == "xy" and number(light.x) and number(light.y) then
				return { x = light.x, y = light.y, color_mode = "xy" }
			end
			if ct == nil and light.mirek_valid == true and number(light.mirek) then
				ct = { mirek = light.mirek, color_mode = "ct" }
			end
		end
	end
	return ct
end

-- A group's owner-facing label from its raw name and type: "Bedside Lights
-- (zone)", "Master Bedroom", "(all lights)" for the bridge_home, "(no room)"
-- without a name (the wording of groups:label and scenes.lua).
function hue_model.group_label(name, gtype)
	if gtype == "bridge_home" then
		return "(all lights)"
	elseif name == nil or name == "" then
		return "(no room)"
	elseif gtype == "zone" then
		return tostring(name) .. " (zone)"
	end
	return tostring(name)
end

-- HUE_CONFIGURE params for a group device (docs/zone-light-design.md §5,
-- Messages) from a zone-light registry entry { name, group_type, light_count,
-- no_lights, caps, id_v1 } and its rid: the light fields (rid, name, model,
-- has_color, has_cct, mirek_min?, mirek_max?, min_dim "1") plus kind
-- "group", group_type?, light_count?, no_lights ("true" only while the group
-- has no grouped_light, else "false"), hue_room (the group's own label),
-- id_v1?, and the string fields of `extra` (state, gone_since; nil and ""
-- skipped) merged as registry_configure_params() does. Every value is a string; the
-- model is "Hue zone" / "Hue room" and absent for an unknown type.
function hue_model.group_configure_params(rid, entry, extra)
	entry = type(entry) == "table" and entry or {}
	local caps = type(entry.caps) == "table" and entry.caps or {}
	local params = hue_model.registry_configure_params(rid, {
		name = entry.name,
		model = GROUP_MODEL[entry.group_type],
		caps = { has_color = caps.has_color == true or caps.has_color == "true",
			has_cct = caps.has_cct == true or caps.has_cct == "true",
			mirek_min = tonumber(caps.mirek_min), mirek_max = tonumber(caps.mirek_max), min_dim = 1 },
	})
	params.kind = "group"
	params.group_type = text(entry.group_type)
	if entry.light_count ~= nil and tonumber(entry.light_count) then
		params.light_count = string.format("%d", tonumber(entry.light_count))
	end
	params.no_lights = (entry.no_lights == true or entry.no_lights == "true") and "true" or "false"
	if entry.name ~= nil and entry.name ~= "" then
		params.hue_room = hue_model.group_label(entry.name, entry.group_type)
	end
	params.id_v1 = text(entry.id_v1)
	return merge_extra(params, extra)
end

return hue_model
