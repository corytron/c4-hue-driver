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

-- The stream rotates over a family of spellings so that a fresh stream
-- transfer never lands on the queue its abandoned predecessor still holds.
altaddr.FAMILY_MAX = 8

-- Every spelling the stream may use, in rotation order. Each octet below 8
-- is written 3, 2 or 1 digits wide (1 digit meaning "left as is"), and the
-- family is every combination of those widths over the paddable octets
-- except two reserved ones: all-1-digit is the dotted spelling commands use,
-- and all-2-digit is the self-check's (`for_check`). The first entry is the
-- all-3-digit spelling (`for_stream`); after that the widths count down
-- like an odometer, the last paddable octet turning fastest.
--
-- With four paddable octets there would be 79 spellings; the list is cut at
-- FAMILY_MAX because a handful of queues is all a rotation needs, and the
-- first few are the mixed widths measured on hardware. One paddable octet
-- gives a one-entry family, no rotation. Returns nil, like `padded`, when
-- `ip` is not a dotted quad or has no octet below 8.
function altaddr.stream_family(ip)
	if type(ip) ~= "string" then
		return nil
	end
	local octets, paddable = {}, {}
	for octet in ip:gmatch("%d+") do
		octets[#octets + 1] = octet
		if tonumber(octet) < 8 then
			paddable[#paddable + 1] = #octets
		end
	end
	if #octets ~= 4 or #paddable == 0 then
		return nil
	end

	local widths = {}
	for i = 1, #paddable do
		widths[i] = 3
	end

	local family = {}
	while widths and #family < altaddr.FAMILY_MAX do
		local all_same = true
		for i = 2, #widths do
			if widths[i] ~= widths[1] then
				all_same = false
				break
			end
		end
		if not (all_same and widths[1] < 3) then
			local spelled = {}
			for i, octet in ipairs(octets) do
				spelled[i] = octet
			end
			for i, index in ipairs(paddable) do
				local octet = octets[index]
				spelled[index] = string.rep("0", widths[i] - #octet) .. octet
			end
			family[#family + 1] = table.concat(spelled, ".")
		end
		-- Count down: decrement the last width, borrowing leftwards when a
		-- width would drop below 1; running out of octets to borrow from
		-- means every combination has been visited.
		local i = #widths
		while i >= 1 and widths[i] == 1 do
			widths[i] = 3
			i = i - 1
		end
		if i < 1 then
			widths = nil
		else
			widths[i] = widths[i] - 1
		end
	end
	return family
end

return altaddr
