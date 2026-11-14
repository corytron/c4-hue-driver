-- mDNS for Hue devices (#334, docs/simplify-actions-design.md §3.4, D5):
-- the legacy unicast query for one DNS-SD service and the parser of the
-- answers. Moved from bridge/mdns.lua (#514, docs/hdmi-sync-stage1-design.md
-- §3): the bridge configures an instance for _hue._tcp.local there, the Hue
-- Sync Box (stage 2) will configure one for _huesync._tcp.local. Pure Lua,
-- no C4 call, no bridge.* module: the driver sends the query and hands every
-- datagram it receives to read (or to a window's take, below).
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
-- (docs/design.md: the Bridge Pro writes its id upper case). That a sync
-- box answers the same legacy unicast query for _huesync._tcp.local, with
-- TXT name, devicetype, uniqueid and path, is [assumed] until its first dev
-- build (docs/syncbox-api-research.md, docs/syncbox-architecture-research.md
-- 2.6).
--
-- read never raises: a malformed, truncated or hostile packet gives nil and
-- a reason. Bounds: MAX_PACKET bytes (RFC 6762 §17), MAX_RECORDS records,
-- names of at most 255 bytes, compression pointers only backwards and at
-- most MAX_JUMPS of them per name. AAAA records are counted and ignored: the
-- drivers talk IPv4 (bridge/config.lua parse_ipv4).
--
-- mdns.new(opts) returns an instance (functions called with a dot):
--   opts.service       required: the service, "_hue._tcp" or
--                      "_huesync._tcp", ".local" added when missing (SERVICE)
--   opts.config        required: a table whose parse_ipv4(text) gives the
--                      dotted address or nil (bridge/config.lua's rules)
--   opts.sweep         optional: a table whose searchable(ip) is true for an
--                      address the driver may sweep (bridge/sweep.lua); it
--                      can only narrow the addresses a candidate may have,
--                      never widen them (see usable_address)
--   opts.txt           required: the TXT keys the candidates read, { id =
--                      "bridgeid", model = "modelid" } for the bridge, { id =
--                      "uniqueid", model = "devicetype", name = "name" } for
--                      the box (keys compared in lower case)
--   opts.normalise_id  required: the TXT id into the device id, or nil when
--                      it is not one (config.normalise_bridge_id)
-- and its fields and functions:
--   GROUP, PORT, SERVICE, MAX_PACKET, MAX_RECORDS, MAX_JUMPS, MAX_NAME
--   query(id)        the question, a string (NUL bytes included)
--   parse(data)      msg | nil, err: { id, flags, response, opcode, rcode,
--                    truncated, qd, an, ns, ar, records = { { section, name,
--                    lname, rtype, class, ttl, target, port, priority,
--                    weight, txt, ip } }, aaaa, ignored }
--   candidates(msg)  the service's instances in one message: { { instance,
--                    id (normalised or nil), raw_id, model, name (when
--                    opts.txt.name is set), host, port, ip (IPv4 of host or
--                    nil), ips } }; every text is the peer's own, to be
--                    passed through peer_text before a row or a log line
--   read(data)       candidates, msg | nil, err (a query, not an answer, is
--                    refused too)
--   usable_address(ip)  true for an address a candidate may have
--   window(query_id, opts)  the answers to one query, see below

local mdns = {}

mdns.GROUP = "224.0.0.251"
mdns.PORT = 5353
mdns.MAX_PACKET = 9000
mdns.MAX_RECORDS = 64
mdns.MAX_JUMPS = 16
mdns.MAX_NAME = 255
-- Datagrams a window parses (and as many again that name a wanted id); the
-- bridge's discovery.MAX_ANSWERS (security review 2026-11-13, N-3, #490).
mdns.MAX_ANSWERS = 32

local TYPE_A, TYPE_PTR, TYPE_TXT, TYPE_AAAA, TYPE_SRV = 1, 12, 16, 28, 33
local CLASS_IN = 1

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
-- where it is written (after its first pointer, if any). `pub`: the
-- instance, for its MAX_JUMPS and MAX_NAME.
local function read_name(pub, s, i)
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
			if jumps > pub.MAX_JUMPS then
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
			if length > pub.MAX_NAME then
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

-- The PTR question for the service, class IN, unicast-response bit clear:
-- from an ephemeral port the answer comes back by unicast anyway (RFC 6762
-- §6.7). `id` (1 to 65535) comes back in the answer.
local function query_id(id)
	return math.floor(tonumber(id) or 0) % 65536
end

local function query(pub, id)
	local n = query_id(id)
	return string.char(math.floor(n / 256), n % 256, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)
		.. encode_name(pub.SERVICE) .. string.char(0, TYPE_PTR, 0, CLASS_IN)
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

-- One record's data into `rec` (PTR, SRV, TXT, A), or counted in `msg`
-- (AAAA, another class or type). `at` is its first byte, `stop` the first
-- after it.
local function read_record(pub, s, msg, rec, at, stop)
	local rtype, rlen = rec.rtype, stop - at
	if rec.class ~= CLASS_IN then
		msg.ignored = msg.ignored + 1
	elseif rtype == TYPE_PTR then
		local target, after = read_name(pub, s, at)
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
		local target, after = read_name(pub, s, at + 6)
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
end

local function parse(pub, s)
	if type(s) ~= "string" then
		fail("not a string")
	end
	if #s < 12 then
		fail("shorter than a DNS header")
	end
	if #s > pub.MAX_PACKET then
		fail("longer than " .. pub.MAX_PACKET .. " bytes")
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
	if msg.qd > 16 or msg.an + msg.ns + msg.ar > pub.MAX_RECORDS then
		fail("implausible record counts")
	end
	local i = 13
	for _ = 1, msg.qd do
		local _, next_i = read_name(pub, s, i)
		u16(s, next_i + 2) -- type and class must be there
		i = next_i + 4
	end
	local sections = {}
	for _ = 1, msg.an do sections[#sections + 1] = "an" end
	for _ = 1, msg.ns do sections[#sections + 1] = "ns" end
	for _ = 1, msg.ar do sections[#sections + 1] = "ar" end
	for _, section in ipairs(sections) do
		local name, next_i = read_name(pub, s, i)
		local rtype, class = u16(s, next_i), u16(s, next_i + 2)
		local ttl, rlen = u32(s, next_i + 4), u16(s, next_i + 8)
		local at = next_i + 10
		local stop = at + rlen -- the first byte after the record's data
		if stop - 1 > #s then
			fail("a record runs past the packet")
		end
		local rec = { section = section, name = name, lname = name:lower(), rtype = rtype, class = class % 32768,
			ttl = ttl }
		read_record(pub, s, msg, rec, at, stop)
		i = stop
	end
	return msg
end

-- The networks a Hue device on the controller's network can have, whatever
-- the driver: a private network (RFC 1918: 10/8, 172.16/12, 192.168/16),
-- link-local (169.254/16, RFC 3927), or one of the documentation networks
-- (RFC 5737: 192.0.2/24, 198.51.100/24, 203.0.113/24), which no host on the
-- internet has and which the bridge's sweep searches too. `o`: the four
-- octets.
local function private_or_local(o)
	local a, b, c = o[1], o[2], o[3]
	return a == 10
		or (a == 172 and b >= 16 and b <= 31)
		or (a == 192 and b == 168)
		or (a == 169 and b == 254)
		or (a == 192 and b == 0 and c == 2)
		or (a == 198 and b == 51 and c == 100)
		or (a == 203 and b == 0 and c == 113)
end

-- An IPv4 address a candidate may have: one config.parse_ipv4 takes, on one
-- of the networks above, and, when the instance has a sweep, one the sweep
-- may search or a link-local one (the bridge's rule since #490). Any other
-- address, the internet's included, is never a candidate: the identity check
-- would connect there (security review 2026-11-13, N-3, #490).
local function usable_address(self, ip)
	if type(ip) ~= "string" then
		return false
	end
	local text = self.config.parse_ipv4(ip)
	if type(text) ~= "string" then
		return false
	end
	local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a or not private_or_local({ tonumber(a), tonumber(b), tonumber(c), tonumber(d) }) then
		return false
	end
	if not self.sweep then
		return true
	end
	if self.sweep.searchable(ip) then
		return true
	end
	local p, q = ip:match("^(%d+)%.(%d+)%.")
	return p == "169" and q == "254"
end

-- The first non-empty string a TXT record gives under `key`, for a field
-- still unset.
local function txt_text(txt, key)
	local value = key and txt[key] or nil
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

-- The service's instances of one message, linked PTR -> SRV/TXT -> A.
local function candidates(self, msg)
	local pub, keys = self.pub, self.txt
	local service = pub.SERVICE
	local suffix = "." .. service
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
	local function of_service(lname)
		return #lname > #suffix and lname:sub(-#suffix) == suffix
	end
	for _, rec in ipairs(msg.records or {}) do
		if rec.rtype == TYPE_PTR and rec.lname == service and of_service(rec.target:lower()) then
			instance(rec.target)
		elseif rec.rtype == TYPE_SRV and of_service(rec.lname) then
			local inst = instance(rec.name)
			if inst.host == nil then
				inst.host, inst.port = rec.target, rec.port
			end
		elseif rec.rtype == TYPE_TXT and of_service(rec.lname) then
			local inst = instance(rec.name)
			local raw = rec.txt[keys.id]
			if inst.raw_id == nil and type(raw) == "string" then
				inst.raw_id = raw
				inst.id = self.normalise_id(raw)
			end
			inst.model = inst.model or txt_text(rec.txt, keys.model)
			if keys.name then
				inst.name = inst.name or txt_text(rec.txt, keys.name)
			end
		elseif rec.rtype == TYPE_A and pub.usable_address(rec.ip) then
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
local function read(pub, data)
	local msg, err = pub.parse(data)
	if not msg then
		return nil, err
	end
	if not msg.response then
		return nil, "a query, not an answer"
	end
	if msg.opcode ~= 0 then
		return nil, "opcode " .. msg.opcode
	end
	local ok, list = pcall(pub.candidates, msg)
	if not ok then
		return nil, "not linked: " .. tostring(list)
	end
	return list, msg
end

-- The window: the answers to one query (security review 2026-11-13, N-3,
-- #490; the rules of bridge/discovery.lua's search window, for a driver
-- that has none of its own yet). pub.window(query_id, opts) returns w:
--   w.query_id       the id in 16 bits, as query() writes it
--   w:query()        the question to send
--   w:want(id)       a normalised id a job waits for: answers whose bytes
--                    name it (in any case) have a budget of their own, so a
--                    flood of other answers cannot keep that device's out
--   w:take(data, from)  one datagram, `from` the sender's address when the
--                    controller names it (OS 4.x): the rows it added (a list,
--                    maybe empty), or nil and why it was not used
--   w.cands          every row so far: { id, raw_id, model, name, instance,
--                    ip, port, via = "a" (an A record) | "from" (the sender) },
--                    one per id (or instance) and address
--   counters         answers (every datagram given), parsed, parsed_wanted,
--                    rejected (not an answer to this query), dropped (over
--                    the cap), senders_refused
-- What counts: an answer to this query, its id repeated (a legacy unicast
-- answer repeats it, RFC 6762 §6.7); every address it names, and the
-- sender's, usable (usable_address), never the internet. At most
-- opts.max_answers (default MAX_ANSWERS) datagrams are parsed, and as many
-- again that name a wanted id; the rest are counted and dropped unread.
local Window = {}
Window.__index = Window

function Window:query()
	return self.pub.query(self.query_id)
end

function Window:want(id)
	if type(id) == "string" and id ~= "" then
		self.wanted[id:lower()] = true
	end
end

-- True when the datagram's bytes hold, in any case, a wanted id. A plain
-- search, before any parsing; a datagram longer than MAX_PACKET is refused
-- by the parser anyway and is not searched.
local function names_wanted(w, data)
	if next(w.wanted) == nil or #data > w.pub.MAX_PACKET then
		return false
	end
	local lower = data:lower()
	for id in pairs(w.wanted) do
		if lower:find(id, 1, true) then
			return true
		end
	end
	return false
end

local function contains(list, value)
	for _, v in ipairs(list) do
		if v == value then
			return true
		end
	end
	return false
end

function Window:take(data, from)
	local pub = self.pub
	if type(data) ~= "string" then
		return nil, "not a datagram"
	end
	self.answers = self.answers + 1
	if names_wanted(self, data) then
		if self.parsed_wanted >= self.max_answers then
			self.dropped = self.dropped + 1
			return nil, "over the window's cap"
		end
		self.parsed_wanted = self.parsed_wanted + 1
	else
		if self.parsed >= self.max_answers then
			self.dropped = self.dropped + 1
			return nil, "over the window's cap"
		end
		self.parsed = self.parsed + 1
	end
	local cands, msg = pub.read(data)
	if not cands then
		self.rejected = self.rejected + 1
		return nil, msg
	end
	if msg.id ~= self.query_id then
		self.rejected = self.rejected + 1
		return nil, string.format("an answer with id 0x%04x to query 0x%04x", msg.id, self.query_id)
	end
	local sender = type(from) == "string" and self.config.parse_ipv4(from) or nil
	if sender and not pub.usable_address(sender) then
		self.senders_refused = self.senders_refused + 1
		sender = nil
	end
	local added = {}
	for _, c in ipairs(cands) do
		local ips = {}
		for _, ip in ipairs(c.ips) do
			ips[#ips + 1] = ip
		end
		if sender and not contains(ips, sender) then
			ips[#ips + 1] = sender
		end
		for _, ip in ipairs(ips) do
			local key = (c.id or ("?" .. c.instance:lower())) .. "@" .. ip
			if not self.keys[key] then
				self.keys[key] = true
				local row = { id = c.id, raw_id = c.raw_id, model = c.model, name = c.name, instance = c.instance,
					ip = ip, port = c.port, via = contains(c.ips, ip) and "a" or "from" }
				self.cands[#self.cands + 1] = row
				added[#added + 1] = row
			end
		end
	end
	return added
end

local function window(self, id, opts)
	opts = opts or {}
	return setmetatable({
		pub = self.pub,
		config = self.config,
		query_id = query_id(id),
		max_answers = tonumber(opts.max_answers) or self.pub.MAX_ANSWERS,
		wanted = {}, keys = {}, cands = {},
		answers = 0, parsed = 0, parsed_wanted = 0, rejected = 0, dropped = 0, senders_refused = 0,
	}, Window)
end

local function required(opts, name, kind)
	if type(opts[name]) ~= kind then
		error("mdns.new: " .. name .. " must be a " .. kind, 3)
	end
	return opts[name]
end

-- A new instance (see the header).
function mdns.new(opts)
	opts = opts or {}
	local service = required(opts, "service", "string"):lower()
	if service:sub(-6) ~= ".local" then
		service = service .. ".local"
	end
	local config = required(opts, "config", "table")
	local txt = required(opts, "txt", "table")
	if type(txt.id) ~= "string" then
		error("mdns.new: txt.id must name the TXT key of the device id", 2)
	end
	local pub = {
		GROUP = mdns.GROUP,
		PORT = mdns.PORT,
		SERVICE = service,
		MAX_PACKET = mdns.MAX_PACKET,
		MAX_RECORDS = mdns.MAX_RECORDS,
		MAX_JUMPS = mdns.MAX_JUMPS,
		MAX_NAME = mdns.MAX_NAME,
		MAX_ANSWERS = mdns.MAX_ANSWERS,
	}
	local self = {
		pub = pub,
		config = config,
		sweep = opts.sweep,
		txt = { id = txt.id:lower(), model = txt.model and txt.model:lower(), name = txt.name and txt.name:lower() },
		normalise_id = required(opts, "normalise_id", "function"),
	}

	function pub.query(id)
		return query(pub, id)
	end
	-- The message, or nil and why; never raises.
	function pub.parse(data)
		local ok, result = pcall(parse, pub, data)
		if ok then
			return result
		end
		if type(result) == "table" and result.mdns then
			return nil, result.mdns
		end
		return nil, "not parsed: " .. tostring(result)
	end
	function pub.usable_address(ip)
		return usable_address(self, ip)
	end
	function pub.candidates(msg)
		return candidates(self, msg)
	end
	function pub.read(data)
		return read(pub, data)
	end
	function pub.window(id, window_opts)
		return window(self, id, window_opts)
	end
	return pub
end

return mdns
