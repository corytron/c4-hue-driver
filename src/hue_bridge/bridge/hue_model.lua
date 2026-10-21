-- Normalisation of Hue CLIP v2 resources into the flat per-light tables the
-- bridge driver keeps, and the string-valued parameter tables it sends to the
-- light drivers (docs/lights-design.md, "Bridge: model, registry, import").
-- Pure Lua, no C4 calls.
--
-- Shapes consumed (from Signify's CLIP v2 reference):
--   light               { id, owner{rid}, metadata{name, archetype}, on{on},
--                         dimming{brightness, min_dim_level},
--                         color{xy{x,y}, gamut{red,green,blue}} (optional),
--                         color_temperature{mirek, mirek_valid,
--                           mirek_schema{mirek_minimum, mirek_maximum}} (optional) }
--   device              { id, product_data{model_id, product_name}, metadata{name},
--                         services[{rid, rtype}] }
--   zigbee_connectivity { id, owner{rid}, status }
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
-- zigbee_connectivity (nil until known).
function hue_model.light(item)
	local light = {
		rid = item.id,
		device_rid = type(item.owner) == "table" and item.owner.rid or nil,
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
-- online }. Only "connected" counts as online; "connectivity_issue",
-- "disconnected" and "unidirectional_incoming" all mean commands may not
-- reach the light.
function hue_model.connectivity(item)
	return {
		rid = item.id,
		device_rid = type(item.owner) == "table" and item.owner.rid or nil,
		status = item.status,
		online = item.status == "connected",
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

-- HUE_CONFIGURE params from a registry-shaped record { rid, name, model,
-- caps }. Every value is a string; fields without a value are left out
-- (C4:SendToDevice drops empty strings anyway, so this keeps the fake and
-- the controller identical).
function hue_model.registry_configure_params(rid, entry)
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
	return params
end

-- HUE_CONFIGURE params from a live normalised light and (optionally) its
-- device record from devices().
function hue_model.configure_params(light, device)
	return hue_model.registry_configure_params(light.rid, {
		name = light.name,
		model = device and device.model or nil,
		caps = hue_model.caps(light),
	})
end

return hue_model
