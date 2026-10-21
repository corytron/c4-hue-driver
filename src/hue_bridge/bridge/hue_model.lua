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
--   smart_scene         { id, metadata{name, image}, group{rid, rtype}, week_timeslots[],
--                         transition_duration, active_timeslot{timeslot_id, weekday}, state }
--                                                        -- only counted
-- Event-stream items have the same shapes with only the changed fields.
-- A JSON null (mirek while mirek_valid is false) is treated like an absent
-- field, whatever the decoder turns it into: only numbers count as numbers.

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

-- One /clip/v2/resource/light item → the normalised light of the contract.
-- `online` is not part of the resource; the registry owner sets it from
-- zigbee_connectivity (nil until known). `id_v1` ("/lights/12") and
-- `service_id` (0 for the only light of a device, 0/1/… on a multi-light
-- device) are display and disambiguation data only; update() does not touch
-- them, so an event never reports them as changed.
function hue_model.light(item)
	local light = {
		rid = item.id,
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
-- itself, sensors) are kept with an empty light_rids.
function hue_model.devices(items)
	local out = {}
	for _, item in ipairs(items or {}) do
		if type(item) == "table" and item.id ~= nil then
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

-- HUE_CONFIGURE params from a live normalised light and (optionally) its
-- device record from devices(); `extra` as above.
function hue_model.configure_params(light, device, extra)
	return hue_model.registry_configure_params(light.rid, {
		name = light.name,
		model = device and device.model or nil,
		caps = hue_model.caps(light),
	}, extra)
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
			if type(service) == "table" and service.rtype == "grouped_light" and service.rid ~= nil then
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
-- nil for an item of any other type. A room or zone without a name gets a
-- fallback like light(); bridge_home has no name (nil). `grouped_light_rid`
-- is nil for an empty zone, whose services array is empty [verified:
-- hardware 2026-10-21].
function hue_model.group(item)
	if type(item) ~= "table" or item.id == nil or GROUP_CHILD_RTYPE[item.type] == nil then
		return nil
	end
	local group = {
		rid = item.id,
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
-- a smart_scene, a bare item without id or type). A nameless scene gets a
-- fallback name like light(); `id_v1` ("/scenes/<16 chars>") is display data
-- read once here, as for lights, so update_scene() never reports it.
function hue_model.scene(item)
	if type(item) ~= "table" or item.id == nil or item.type ~= "scene" then
		return nil
	end
	local scene = {
		rid = item.id,
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
-- skipped) merged as configure_params() does. Every value is a string.
function hue_model.scene_configure_params(scene, extra)
	local params = {
		rid = tostring(scene.rid),
		name = scene.name ~= nil and tostring(scene.name) or nil,
		id_v1 = text(scene.id_v1),
		auto_dynamic = tostring(scene.auto_dynamic == true),
	}
	return merge_extra(params, extra)
end

-- The number of smart_scene items in a list (a GET /smart_scene body's data,
-- or any mixed list); v1 only counts them (docs/scenes-design.md §1).
function hue_model.smart_scene_count(items)
	local count = 0
	for _, item in ipairs(type(items) == "table" and items or {}) do
		if type(item) == "table" and item.type == "smart_scene" then
			count = count + 1
		end
	end
	return count
end

return hue_model
