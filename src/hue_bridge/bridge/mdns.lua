-- mDNS for Hue bridges (#334, docs/simplify-actions-design.md §3.4, D5):
-- the legacy unicast query for _hue._tcp.local and the parser of the
-- answers. Pure Lua, no C4 call: bridge/discovery.lua sends the query and
-- hands every datagram it receives to mdns.read.
--
-- The message format is DNS's (RFC 1035 §4.1, names compressed by pointers,
-- §4.1.4) as mDNS uses it (RFC 6762 §18); service instances are DNS-SD's
-- (RFC 6763: PTR service -> instance, SRV instance -> host and port, TXT
-- instance -> key=value pairs, keys case-insensitive, the first of a
-- repeated key counts, §6.4). A query sent from a port other than 5353 is a
-- legacy unicast query (RFC 6762 §6.7): the responder answers to that port
-- and repeats the query id.
--
-- What the house showed (dev build 447, OS 3.4.2, Hue Bridge Pro, the
-- query of mdns.query from the driver's own port) [verified: hardware,
-- 2026-11-05, #334]: one answer within milliseconds, flags 0x8400 (an
-- authoritative response), the query id repeated, one PTR answer
-- (_hue._tcp.local -> "Hue Bridge - <last 6 hex digits of the id>"), and
-- in the additional section SRV (port 443, target "<12 hex digits>.local"),
-- TXT (bridgeid, modelid), A and two AAAA records, every name after the
-- first compressed. The bridge id in TXT may be upper case
-- (docs/design.md: the Bridge Pro writes its id upper case).
--
-- mdns.read never raises: a malformed, truncated or hostile packet gives
-- nil and a reason. Bounds: MAX_PACKET bytes (RFC 6762 §17), MAX_RECORDS
-- records, names of at most 255 bytes, compression pointers only backwards
-- and at most MAX_JUMPS of them per name. AAAA records are counted and
-- ignored: the driver talks IPv4 (bridge/config.lua parse_ipv4).
--
--   mdns.query(id)        the question, a string (NUL bytes included)
--   mdns.parse(data)      msg | nil, err: { id, flags, response, opcode,
--                         rcode, truncated, qd, an, ns, ar, records = { {
--                         section, name, lname, rtype, class, ttl, target,
--                         port, priority, weight, txt, ip } }, aaaa, ignored }
--   mdns.candidates(msg)  the Hue instances of one message: { { instance,
--                         id (normalised bridge id or nil), raw_id, model,
--                         host, port, ip (IPv4 of host or nil), ips } }
--   mdns.read(data)       candidates, msg | nil, err (a query, not an
--                         answer, is refused too)

local config = require("bridge.config")

local mdns = {}

mdns.GROUP = "224.0.0.251"
mdns.PORT = 5353
mdns.SERVICE = "_hue._tcp.local"
mdns.MAX_PACKET = 9000
mdns.MAX_RECORDS = 64
mdns.MAX_JUMPS = 16
mdns.MAX_NAME = 255

local TYPE_A, TYPE_PTR, TYPE_TXT, TYPE_AAAA, TYPE_SRV = 1, 12, 16, 28, 33
local CLASS_IN = 1
local SUFFIX = "." .. mdns.SERVICE

local function fail(text)
	error({ mdns = text }, 0)
end

local function u16(s, i)
	local a, b = s:byte(i, i + 1)
	if not b then
		fail("the packet ends early")
	end
	return a * 256 + b
end

local function u32(s, i)
	return u16(s, i) * 65536 + u16(s, i + 2)
end

-- A label in presentation form: "." and "\" escaped (RFC 6763 §4.3), so a
-- dot inside a label never reads as a separator.
local function escape(label)
	return (label:gsub("[%.\\]", "\\%0"))
end

-- The name at byte i (1-based), pointers followed, and the index just after
-- where it is written (after its first pointer, if any).
local function read_name(s, i)
	local labels, jumps, resume, length = {}, 0, nil, 0
	local pos = i
	while true do
		local len = s:byte(pos)
		if not len then
			fail("a name runs past the packet")
		end
		if len == 0 then
			pos = pos + 1
			break
		elseif len >= 192 then
			local low = s:byte(pos + 1)
			if not low then
				fail("a pointer runs past the packet")
			end
			local target = (len - 192) * 256 + low + 1
			-- Only backwards: a pointer to itself or ahead could loop.
			if target >= pos then
				fail("a pointer that does not point back")
			end
			jumps = jumps + 1
			if jumps > mdns.MAX_JUMPS then
				fail("too many pointers in one name")
			end
			resume = resume or pos + 2
			pos = target
		elseif len >= 64 then
			fail("a label length of " .. len)
		else
			if pos + len > #s then
				fail("a label runs past the packet")
			end
			length = length + len + 1
			if length > mdns.MAX_NAME then
				fail("a name longer than 255 bytes")
			end
			labels[#labels + 1] = escape(s:sub(pos + 1, pos + len))
			pos = pos + 1 + len
		end
	end
	return table.concat(labels, "."), resume or pos
end

local function encode_name(name)
	local parts = {}
	for label in name:gmatch("[^%.]+") do
		parts[#parts + 1] = string.char(#label) .. label
	end
	return table.concat(parts) .. "\0"
end

-- The PTR question for _hue._tcp.local, class IN, unicast-response bit
-- clear: from an ephemeral port the answer comes back by unicast anyway
-- (RFC 6762 §6.7). `id` (1 to 65535) comes back in the answer.
function mdns.query(id)
	local n = math.floor(tonumber(id) or 0) % 65536
	return string.char(math.floor(n / 256), n % 256, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)
		.. encode_name(mdns.SERVICE) .. string.char(0, TYPE_PTR, 0, CLASS_IN)
end

-- TXT strings: <length><bytes> until the end of the data; keys lower case,
-- the first of a repeated key kept, a key without "=" is true.
local function read_txt(s, at, stop)
	local kv, j = {}, at
	while j < stop do
		local len = s:byte(j)
		-- The string is bytes j+1 to j+len, inside the record's data.
		if j + len >= stop then
			break -- a string that runs past the record: the rest is dropped
		end
		local item = s:sub(j + 1, j + len)
		local key, value = item:match("^([^=]+)=(.*)$")
		if key then
			key = key:lower()
			if kv[key] == nil then
				kv[key] = value
			end
		elseif item ~= "" and not item:find("=", 1, true) then
			local flag = item:lower()
			if kv[flag] == nil then
				kv[flag] = true
			end
		end
		j = j + 1 + len
	end
	return kv
end

local function parse(s)
	if type(s) ~= "string" then
		fail("not a string")
	end
	if #s < 12 then
		fail("shorter than a DNS header")
	end
	if #s > mdns.MAX_PACKET then
		fail("longer than " .. mdns.MAX_PACKET .. " bytes")
	end
	local flags = u16(s, 3)
	local msg = {
		id = u16(s, 1), flags = flags,
		response = flags >= 32768,
		opcode = math.floor(flags / 2048) % 16,
		truncated = math.floor(flags / 512) % 2 == 1,
		rcode = flags % 16,
		qd = u16(s, 5), an = u16(s, 7), ns = u16(s, 9), ar = u16(s, 11),
		records = {}, aaaa = 0, ignored = 0,
	}
	if msg.qd > 16 or msg.an + msg.ns + msg.ar > mdns.MAX_RECORDS then
		fail("implausible record counts")
	end
	local i = 13
	for _ = 1, msg.qd do
		local _, next_i = read_name(s, i)
		u16(s, next_i + 2) -- type and class must be there
		i = next_i + 4
	end
	local sections = {}
	for _ = 1, msg.an do sections[#sections + 1] = "an" end
	for _ = 1, msg.ns do sections[#sections + 1] = "ns" end
	for _ = 1, msg.ar do sections[#sections + 1] = "ar" end
	for _, section in ipairs(sections) do
		local name, next_i = read_name(s, i)
		local rtype, class = u16(s, next_i), u16(s, next_i + 2)
		local ttl, rlen = u32(s, next_i + 4), u16(s, next_i + 8)
		local at = next_i + 10
		local stop = at + rlen -- the first byte after the record's data
		if stop - 1 > #s then
			fail("a record runs past the packet")
		end
		local rec = { section = section, name = name, lname = name:lower(), rtype = rtype, class = class % 32768,
			ttl = ttl }
		if rec.class ~= CLASS_IN then
			msg.ignored = msg.ignored + 1
		elseif rtype == TYPE_PTR then
			local target, after = read_name(s, at)
			if after > stop then
				fail("a PTR name runs past its record")
			end
			rec.target = target
			msg.records[#msg.records + 1] = rec
		elseif rtype == TYPE_SRV then
			if rlen < 7 then
				fail("an SRV record too short")
			end
			rec.priority, rec.weight, rec.port = u16(s, at), u16(s, at + 2), u16(s, at + 4)
			local target, after = read_name(s, at + 6)
			if after > stop then
				fail("an SRV target runs past its record")
			end
			rec.target = target
			msg.records[#msg.records + 1] = rec
		elseif rtype == TYPE_TXT then
			rec.txt = read_txt(s, at, stop)
			msg.records[#msg.records + 1] = rec
		elseif rtype == TYPE_A then
			if rlen == 4 then
				rec.ip = string.format("%d.%d.%d.%d", s:byte(at, at + 3))
				msg.records[#msg.records + 1] = rec
			else
				msg.ignored = msg.ignored + 1
			end
		elseif rtype == TYPE_AAAA then
			msg.aaaa = msg.aaaa + 1
		else
			msg.ignored = msg.ignored + 1
		end
		i = stop
	end
	return msg
end

-- The message, or nil and why; never raises.
function mdns.parse(data)
	local ok, result = pcall(parse, data)
	if ok then
		return result
	end
	if type(result) == "table" and result.mdns then
		return nil, result.mdns
	end
	return nil, "not parsed: " .. tostring(result)
end

-- An IPv4 address a bridge can have: not 0/8, loopback, multicast or reserved.
local function host_address(ip)
	local first = tonumber(ip:match("^(%d+)"))
	return first ~= nil and first ~= 0 and first ~= 127 and first < 224
end

-- The Hue service instances of one message, linked PTR -> SRV/TXT -> A.
function mdns.candidates(msg)
	local by_name, order, hosts, all_ips, distinct, first_ip = {}, {}, {}, {}, 0, nil
	local function instance(name)
		local lname = name:lower()
		local inst = by_name[lname]
		if not inst then
			inst = { instance = name }
			by_name[lname] = inst
			order[#order + 1] = lname
		end
		return inst
	end
	local function hue_instance(lname)
		return #lname > #SUFFIX and lname:sub(-#SUFFIX) == SUFFIX
	end
	for _, rec in ipairs(msg.records or {}) do
		if rec.rtype == TYPE_PTR and rec.lname == mdns.SERVICE and hue_instance(rec.target:lower()) then
			instance(rec.target)
		elseif rec.rtype == TYPE_SRV and hue_instance(rec.lname) then
			local inst = instance(rec.name)
			if inst.host == nil then
				inst.host, inst.port = rec.target, rec.port
			end
		elseif rec.rtype == TYPE_TXT and hue_instance(rec.lname) then
			local inst = instance(rec.name)
			local raw = rec.txt.bridgeid
			if inst.raw_id == nil and type(raw) == "string" then
				inst.raw_id = raw
				inst.id = config.normalise_bridge_id(raw)
			end
			if inst.model == nil and type(rec.txt.modelid) == "string" and rec.txt.modelid ~= "" then
				inst.model = rec.txt.modelid
			end
		elseif rec.rtype == TYPE_A and host_address(rec.ip) then
			local list = hosts[rec.lname]
			if not list then
				list = {}
				hosts[rec.lname] = list
			end
			local seen = false
			for _, ip in ipairs(list) do
				seen = seen or ip == rec.ip
			end
			if not seen then
				list[#list + 1] = rec.ip
			end
			if not all_ips[rec.ip] then
				all_ips[rec.ip] = true
				distinct = distinct + 1
				first_ip = first_ip or rec.ip
			end
		end
	end
	local out = {}
	for _, lname in ipairs(order) do
		local inst = by_name[lname]
		local ips = inst.host and hosts[inst.host:lower()] or nil
		-- An answer whose SRV target has no A record of its own, with one
		-- address in the whole message: that one (a single responder).
		if (not ips or #ips == 0) and distinct == 1 then
			ips = { first_ip }
		end
		inst.ips = ips or {}
		inst.ip = inst.ips[1]
		out[#out + 1] = inst
	end
	return out
end

-- The candidates of one datagram, and its message; nil and why for a
-- packet that is not a parseable mDNS answer. Never raises.
function mdns.read(data)
	local msg, err = mdns.parse(data)
	if not msg then
		return nil, err
	end
	if not msg.response then
		return nil, "a query, not an answer"
	end
	if msg.opcode ~= 0 then
		return nil, "opcode " .. msg.opcode
	end
	local ok, list = pcall(mdns.candidates, msg)
	if not ok then
		return nil, "not linked: " .. tostring(list)
	end
	return list, msg
end

return mdns
