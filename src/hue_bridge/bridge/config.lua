-- Validation of user-entered bridge settings. Pure Lua, no C4 calls.

local config = {}

-- Accepts a dotted-quad IPv4 address, trimming surrounding whitespace.
-- Returns the normalised address, or nil and a reason.
function config.parse_ipv4(value)
	if type(value) ~= "string" then
		return nil, "not a string"
	end
	local trimmed = value:match("^%s*(.-)%s*$")
	if trimmed == "" then
		return nil, "empty"
	end
	local a, b, c, d = trimmed:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then
		return nil, "not an IPv4 address"
	end
	local octets = { a, b, c, d }
	for i, octet in ipairs(octets) do
		-- Leading zeros are ambiguous (octal in some parsers); reject them.
		if #octet > 1 and octet:sub(1, 1) == "0" then
			return nil, "octet has a leading zero"
		end
		local n = tonumber(octet)
		if n > 255 then
			return nil, "octet out of range"
		end
		octets[i] = tostring(n)
	end
	return table.concat(octets, ".")
end

-- A Hue bridge ID is 16 hex digits. The square bridge reports it lower-case
-- and the Bridge Pro upper-case in its certificate, so compare lower-case.
function config.normalise_bridge_id(value)
	if type(value) ~= "string" then
		return nil
	end
	local id = value:lower()
	if not id:match("^%x+$") or #id ~= 16 then
		return nil
	end
	return id
end

-- Bridge generations (docs/bridge-compat-design.md). The round
-- first-generation bridge never had the CLIP v2 API; a model id this table
-- does not know but that starts with BSB is a newer Hue bridge and is let
-- through; anything else is not a Hue bridge.
config.MODELS = {
	BSB001 = { label = "Hue Bridge v1, round", supported = false },
	BSB002 = { label = "Hue Bridge v2, square", supported = true },
	BSB003 = { label = "Hue Bridge Pro", supported = true },
}

-- The first bridge software with the CLIP v2 API [assumed: Signify's
-- developer notes give 1948086000].
config.MIN_FIRMWARE = 1948086000

function config.model_label(modelid)
	if modelid == nil or modelid == "" then
		return ""
	end
	local id = tostring(modelid)
	local known = config.MODELS[id]
	if known then
		return string.format("%s (%s)", known.label, id)
	elseif id:match("^BSB") then
		return string.format("Hue bridge %s (untested model)", id)
	end
	return string.format("%s (not a Hue bridge)", id)
end

function config.model_supported(modelid)
	local id = tostring(modelid or "")
	local known = config.MODELS[id]
	if known then
		return known.supported
	end
	return id:match("^BSB") ~= nil
end

-- "ok", "old" or "unknown" (not a number).
function config.firmware_check(swversion)
	local n = tonumber(swversion)
	if not n then
		return "unknown"
	end
	return n >= config.MIN_FIRMWARE and "ok" or "old"
end

function config.firmware_label(swversion, apiversion)
	if swversion == nil or swversion == "" then
		return ""
	end
	local text = tostring(swversion)
	if apiversion and apiversion ~= "" then
		text = text .. " (API " .. tostring(apiversion) .. ")"
	end
	if config.firmware_check(swversion) == "old" then
		text = text .. string.format("; older than %d, update the bridge in the Hue app", config.MIN_FIRMWARE)
	end
	return text
end

return config
