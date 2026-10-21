-- Alternative spellings of the bridge's IPv4 address.
--
-- On OS 3.4.2 Director runs one C4:url transfer per host at a time, keyed
-- on the host text as parsed from the URL (docs/design.md, "C4:url transfer
-- scheduling"). A second spelling of the same address therefore gets its
-- own queue, which is how the event stream and light commands stay out of
-- each other's way.
--
-- curl's resolver reads a zero-padded octet as octal, so only octets whose
-- value is below 8 can be padded without changing the address ("001" is 1,
-- but "010" would be 8). Decimal, hex, short and IPv6-mapped forms are
-- rejected by Director's curl, and userinfo or an explicit :443 share the
-- dotted spelling's queue; all measured on hardware.

local altaddr = {}

-- Zero-pad every octet below 8 to `width` digits (2 or 3). Returns the new
-- spelling, or nil when no octet can be padded. Different widths give
-- different strings, so callers can keep more than one queue apart.
function altaddr.padded(ip, width)
	width = width or 3
	if type(ip) ~= "string" then
		return nil
	end
	local octets = {}
	for octet in ip:gmatch("%d+") do
		octets[#octets + 1] = octet
	end
	if #octets ~= 4 then
		return nil
	end
	local changed = false
	for i, octet in ipairs(octets) do
		local n = tonumber(octet)
		if n < 8 then
			octets[i] = string.rep("0", width - #octet) .. octet
			changed = true
		end
	end
	if not changed then
		return nil
	end
	return table.concat(octets, ".")
end

-- The spelling the stream uses, and the one the startup self-check uses.
function altaddr.for_stream(ip)
	return altaddr.padded(ip, 3)
end

function altaddr.for_check(ip)
	return altaddr.padded(ip, 2)
end

return altaddr
