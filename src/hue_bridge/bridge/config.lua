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

return config
