-- #334, D5 (docs/simplify-actions-design.md §3.4): bridge/mdns.lua, the
-- legacy unicast query for _hue._tcp.local and the parser of the answers.
-- The answers are built here record by record, with name compression, in
-- the shape the house's Hue Bridge Pro sent to the dev probe (build 447):
-- one PTR answer, then SRV, TXT, AAAA, A and AAAA in the additional
-- section. Placeholders only: bridge 10.0.2.143, id 001788fffe123abc.

local mdns = require("bridge.mdns")

local BRIDGE_ID = "001788fffe123abc"
local INSTANCE = "Hue Bridge - 123ABC._hue._tcp.local"
local HOST = "001788123ABC.local"

-- A DNS message writer with name compression (RFC 1035 §4.1.4) ---------------

local TYPES = { A = 1, PTR = 12, TXT = 16, AAAA = 28, SRV = 33, NSEC = 47 }

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function u32(n) return u16(math.floor(n / 65536)) .. u16(n % 65536) end
local function ip_bytes(ip)
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

-- opts: id, flags, questions = { name }, an, ns, ar = { record }; a record:
-- { name, type ("PTR", ..., or a number), class (default 0x8001 in ar, 1
-- else), ttl, target, port, txt = { "k=v" }, ip, rdata (raw) }. Names are
-- compressed against every earlier name unless opts.compress == false.
local function packet(opts)
	local pieces, len, known = {}, 0, {}
	local function put(s)
		pieces[#pieces + 1] = s
		len = len + #s
	end
	local function name(n)
		local parts = {}
		for label in n:gmatch("[^%.]+") do parts[#parts + 1] = label end
		for i = 1, #parts do
			local suffix = table.concat(parts, ".", i):lower()
			if opts.compress ~= false and known[suffix] then
				put(string.char(192 + math.floor(known[suffix] / 256), known[suffix] % 256))
				return
			end
			known[suffix] = known[suffix] or len
			put(string.char(#parts[i]) .. parts[i])
		end
		put("\0")
	end
	local an, ns, ar = opts.an or {}, opts.ns or {}, opts.ar or {}
	local questions = opts.questions or { "_hue._tcp.local" }
	put(u16(opts.id or 0x4c7e) .. u16(opts.flags or 0x8400) .. u16(#questions) .. u16(#an) .. u16(#ns) .. u16(#ar))
	for _, q in ipairs(questions) do
		name(q)
		put(u16(12) .. u16(1))
	end
	local function record(rec, section)
		name(rec.name)
		local rtype = type(rec.type) == "number" and rec.type or TYPES[rec.type]
		put(u16(rtype) .. u16(rec.class or (section == "ar" and 0x8001 or 1)) .. u32(rec.ttl or 4500))
		local slot = #pieces + 1
		put("\0\0")
		local start = len
		if rec.rdata then
			put(rec.rdata)
		elseif rec.type == "PTR" then
			name(rec.target)
		elseif rec.type == "SRV" then
			put(u16(0) .. u16(0) .. u16(rec.port or 443))
			name(rec.target)
		elseif rec.type == "TXT" then
			for _, item in ipairs(rec.txt) do put(string.char(#item) .. item) end
		elseif rec.type == "A" then
			put(ip_bytes(rec.ip))
		elseif rec.type == "AAAA" then
			put(string.rep("\0", 15) .. "\1")
		end
		pieces[slot] = u16(len - start)
	end
	for _, rec in ipairs(an) do record(rec, "an") end
	for _, rec in ipairs(ns) do record(rec, "ns") end
	for _, rec in ipairs(ar) do record(rec, "ar") end
	return table.concat(pieces)
end

-- The house's answer, with placeholders.
local function house_answer(opts)
	opts = opts or {}
	local instance = opts.instance or INSTANCE
	local host = opts.host or HOST
	return packet({
		id = opts.id,
		compress = opts.compress,
		an = { { name = "_hue._tcp.local", type = "PTR", target = instance } },
		ar = {
			{ name = instance, type = "SRV", port = 443, target = host },
			{ name = instance, type = "TXT", txt = opts.txt or { "bridgeid=" .. (opts.bridge_id or BRIDGE_ID),
				"modelid=" .. (opts.model or "BSB003") } },
			{ name = host, type = "AAAA" },
			{ name = host, type = "A", ip = opts.ip or "10.0.2.143" },
			{ name = host, type = "AAAA" },
		},
	})
end

describe("bridge/mdns.lua (#334, D5)", function()
	describe("the query", function()
		it("is one PTR question for _hue._tcp.local, class IN, the unicast-response bit clear", function()
			local q = mdns.query(0x4c7e)
			assert.equal(string.char(0x4c, 0x7e, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)
				.. "\4_hue\4_tcp\5local\0" .. string.char(0, 12, 0, 1), q)
			assert.equal(33, #q)
			local msg = assert(mdns.parse(q))
			assert.is_false(msg.response)
			assert.equal(1, msg.qd)
			assert.equal(0x4c7e, msg.id)
		end)

		it("keeps the id within 16 bits", function()
			assert.equal(string.char(0, 1), mdns.query(65537):sub(1, 2))
			assert.equal(string.char(0, 0), mdns.query(nil):sub(1, 2))
		end)

		it("is refused as an answer when it comes back", function()
			local list, err = mdns.read(mdns.query(7))
			assert.is_nil(list)
			assert.equal("a query, not an answer", err)
		end)
	end)

	describe("the house's answer", function()
		it("parses every record, the compressed names followed", function()
			local msg = assert(mdns.parse(house_answer()))
			assert.is_true(msg.response)
			assert.equal(0x8400, msg.flags)
			assert.equal(0x4c7e, msg.id)
			assert.same({ 1, 1, 0, 5 }, { msg.qd, msg.an, msg.ns, msg.ar })
			assert.equal(2, msg.aaaa)
			local by_type = {}
			for _, rec in ipairs(msg.records) do by_type[rec.rtype] = rec end
			assert.equal(INSTANCE, by_type[12].target)
			assert.equal("an", by_type[12].section)
			assert.equal(443, by_type[33].port)
			assert.equal(HOST, by_type[33].target)
			assert.equal(1, by_type[33].class, "the cache-flush bit is not part of the class")
			assert.equal(BRIDGE_ID, by_type[16].txt.bridgeid)
			assert.equal("BSB003", by_type[16].txt.modelid)
			assert.equal("10.0.2.143", by_type[1].ip)
		end)

		it("gives one candidate: the bridge id, model, host, port and IPv4 address", function()
			local list = assert(mdns.read(house_answer()))
			assert.equal(1, #list)
			local c = list[1]
			assert.equal(INSTANCE, c.instance)
			assert.equal(BRIDGE_ID, c.id)
			assert.equal("BSB003", c.model)
			assert.equal(HOST, c.host)
			assert.equal(443, c.port)
			assert.equal("10.0.2.143", c.ip)
			assert.same({ "10.0.2.143" }, c.ips)
		end)

		it("reads the same without compression", function()
			local plain = house_answer({ compress = false })
			assert.is_true(#plain > #house_answer())
			assert.same(mdns.read(house_answer()), (mdns.read(plain)))
		end)

		it("lower-cases a bridge id written in upper case, and the keys of TXT", function()
			local list = assert(mdns.read(house_answer({ txt = { "BridgeID=001788FFFE123ABC", "MODELID=BSB002" } })))
			assert.equal(BRIDGE_ID, list[1].id)
			assert.equal("001788FFFE123ABC", list[1].raw_id)
			assert.equal("BSB002", list[1].model)
		end)

		it("matches names whatever their case", function()
			local list = assert(mdns.read(packet({
				an = { { name = "_HUE._TCP.LOCAL", type = "PTR", target = "Hue Bridge - 123ABC._HUE._tcp.local" } },
				ar = {
					{ name = "hue bridge - 123abc._hue._TCP.local", type = "SRV", target = "HOST.local" },
					{ name = "Hue Bridge - 123ABC._hue._tcp.LOCAL", type = "TXT", txt = { "bridgeid=" .. BRIDGE_ID } },
					{ name = "host.LOCAL", type = "A", ip = "10.0.2.143" },
				},
			})))
			assert.equal(1, #list)
			assert.equal(BRIDGE_ID, list[1].id)
			assert.equal("10.0.2.143", list[1].ip)
		end)
	end)

	describe("TXT", function()
		local function txt_of(items)
			local list = assert(mdns.read(house_answer({ txt = items })))
			return list[1]
		end

		it("keeps the first of a repeated key (RFC 6763 §6.4)", function()
			local c = txt_of({ "bridgeid=" .. BRIDGE_ID, "bridgeid=001788fffe000000" })
			assert.equal(BRIDGE_ID, c.id)
		end)

		it("leaves the id unset when it is not 16 hex digits, keeping what was written", function()
			local c = txt_of({ "bridgeid=not-an-id", "modelid=BSB003" })
			assert.is_nil(c.id)
			assert.equal("not-an-id", c.raw_id)
			assert.equal("BSB003", c.model)
		end)

		it("takes a key without '=' as a flag and skips empty strings", function()
			local list = assert(mdns.read(house_answer({ txt = { "", "flag", "bridgeid=" .. BRIDGE_ID } })))
			assert.equal(BRIDGE_ID, list[1].id)
			local msg = assert(mdns.parse(house_answer({ txt = { "", "flag" } })))
			for _, rec in ipairs(msg.records) do
				if rec.rtype == 16 then assert.is_true(rec.txt.flag) end
			end
		end)

		it("drops a string that runs past its record, keeping the ones before", function()
			-- The second string says 40 bytes; 14 are left in the record, and
			-- the A record follows: none of its bytes may become the model.
			local rdata = string.char(#("bridgeid=" .. BRIDGE_ID)) .. "bridgeid=" .. BRIDGE_ID .. string.char(40)
				.. "modelid=BSB003"
			local list = assert(mdns.read(packet({
				an = { { name = "_hue._tcp.local", type = "PTR", target = INSTANCE } },
				ar = { { name = INSTANCE, type = "TXT", rdata = rdata }, { name = HOST, type = "A", ip = "10.0.2.143" } },
			})))
			assert.equal(BRIDGE_ID, list[1].id)
			assert.is_nil(list[1].model)
			assert.equal("10.0.2.143", list[1].ip, "the packet's only address")
		end)
	end)

	describe("linking records", function()
		it("keeps two bridges in one message apart, each at its own address", function()
			local other = "Hue Bridge - 456DEF._hue._tcp.local"
			local list = assert(mdns.read(packet({
				an = {
					{ name = "_hue._tcp.local", type = "PTR", target = INSTANCE },
					{ name = "_hue._tcp.local", type = "PTR", target = other },
				},
				ar = {
					{ name = INSTANCE, type = "SRV", target = HOST },
					{ name = other, type = "SRV", target = "001788456DEF.local" },
					{ name = other, type = "TXT", txt = { "bridgeid=001788fffe456def", "modelid=BSB002" } },
					{ name = INSTANCE, type = "TXT", txt = { "bridgeid=" .. BRIDGE_ID, "modelid=BSB003" } },
					{ name = "001788456DEF.local", type = "A", ip = "192.0.2.61" },
					{ name = HOST, type = "A", ip = "10.0.2.143" },
				},
			})))
			assert.equal(2, #list)
			assert.same({ BRIDGE_ID, "10.0.2.143", "BSB003" }, { list[1].id, list[1].ip, list[1].model })
			assert.same({ "001788fffe456def", "192.0.2.61", "BSB002" }, { list[2].id, list[2].ip, list[2].model })
		end)

		it("takes the message's one address when the SRV target has no A record of its own", function()
			local list = assert(mdns.read(packet({
				an = { { name = "_hue._tcp.local", type = "PTR", target = INSTANCE } },
				ar = {
					{ name = INSTANCE, type = "SRV", target = HOST },
					{ name = INSTANCE, type = "TXT", txt = { "bridgeid=" .. BRIDGE_ID } },
					{ name = "elsewhere.local", type = "A", ip = "10.0.2.143" },
				},
			})))
			assert.equal("10.0.2.143", list[1].ip)
		end)

		it("gives no address rather than a guess between several", function()
			local list = assert(mdns.read(packet({
				an = { { name = "_hue._tcp.local", type = "PTR", target = INSTANCE } },
				ar = {
					{ name = INSTANCE, type = "SRV", target = HOST },
					{ name = "a.local", type = "A", ip = "192.0.2.20" },
					{ name = "b.local", type = "A", ip = "192.0.2.30" },
				},
			})))
			assert.is_nil(list[1].ip)
			assert.same({}, list[1].ips)
		end)

		it("ignores AAAA: an IPv6-only answer has no address", function()
			local list = assert(mdns.read(packet({
				an = { { name = "_hue._tcp.local", type = "PTR", target = INSTANCE } },
				ar = { { name = INSTANCE, type = "SRV", target = HOST }, { name = HOST, type = "AAAA" } },
			})))
			assert.equal(1, #list)
			assert.is_nil(list[1].ip)
		end)

		it("keeps several A records of the host, in order, once each", function()
			local list = assert(mdns.read(packet({
				an = { { name = "_hue._tcp.local", type = "PTR", target = INSTANCE } },
				ar = {
					{ name = INSTANCE, type = "SRV", target = HOST },
					{ name = HOST, type = "A", ip = "10.0.2.143" },
					{ name = HOST, type = "A", ip = "192.0.2.44" },
					{ name = HOST, type = "A", ip = "10.0.2.143" },
				},
			})))
			assert.same({ "10.0.2.143", "192.0.2.44" }, list[1].ips)
		end)

		it("never takes a loopback, zero or multicast address for a bridge", function()
			for _, ip in ipairs({ "127.0.0.1", "0.0.0.0", "224.0.0.251", "239.255.255.250" }) do
				local list = assert(mdns.read(house_answer({ ip = ip })))
				assert.is_nil(list[1].ip, ip)
			end
		end)

		-- Security review 2026-11-13, N-3 (#490): any address but 0/8, 127/8
		-- and 224/3 was a candidate, so a spoofed answer could steer the
		-- identity check's TLS connects to hosts of its choosing, on the
		-- internet too.
		-- Addresses outside the repository's placeholders are put together from
		-- their octets, so that the secrets check (.gitleaks.toml) sees no literal.
		local function dotted(...) return table.concat({ ... }, ".") end

		it("takes only private, link-local and documentation addresses (N-3)", function()
			for _, ip in ipairs({ "1.2.3.4", dotted(8, 8, 8, 8), dotted(100, 64, 0, 1), dotted(172, 32, 0, 1),
				dotted(192, 169, 0, 1), dotted(169, 255, 0, 1), dotted(203, 0, 114, 1), dotted(11, 0, 0, 1) }) do
				local list = assert(mdns.read(house_answer({ ip = ip })))
				assert.is_nil(list[1].ip, ip)
				assert.same({}, list[1].ips, ip)
			end
			for _, ip in ipairs({ "10.0.2.143", "172.16.0.9", dotted(172, 31, 255, 254), "192.168.1.20",
				dotted(169, 254, 12, 34), "192.0.2.44", "198.51.100.7", "203.0.113.9" }) do
				local list = assert(mdns.read(house_answer({ ip = ip })))
				assert.equal(ip, list[1].ip, ip)
			end
			assert.is_false(mdns.usable_address("not an address"))
			assert.is_false(mdns.usable_address(nil))
		end)

		it("ignores a public address beside the bridge's own, so the one-address rule still holds (N-3)", function()
			local list = assert(mdns.read(packet({
				an = { { name = "_hue._tcp.local", type = "PTR", target = INSTANCE } },
				ar = {
					{ name = INSTANCE, type = "SRV", target = HOST },
					{ name = "elsewhere.local", type = "A", ip = "10.0.2.143" },
					{ name = "evil.local", type = "A", ip = dotted(8, 8, 8, 8) },
				},
			})))
			assert.equal("10.0.2.143", list[1].ip)
		end)

		it("finds no candidate in another service's answer", function()
			local list = assert(mdns.read(packet({
				questions = { "_http._tcp.local" },
				an = { { name = "_http._tcp.local", type = "PTR", target = "Printer._http._tcp.local" } },
				ar = {
					{ name = "Printer._http._tcp.local", type = "SRV", port = 80, target = "printer.local" },
					{ name = "printer.local", type = "A", ip = "192.0.2.30" },
				},
			})))
			assert.same({}, list)
		end)

		it("does not take a PTR of _hue._tcp to another service's instance, nor the bare service name", function()
			local list = assert(mdns.read(packet({
				an = {
					{ name = "_hue._tcp.local", type = "PTR", target = "Printer._http._tcp.local" },
					{ name = "_hue._tcp.local", type = "PTR", target = "_hue._tcp.local" },
				},
			})))
			assert.same({}, list)
		end)

		it("escapes a dot inside a label, so it cannot fake the service suffix", function()
			local rdata = string.char(17) .. "x._hue._tcp.local" .. "\0"
			local msg = assert(mdns.parse(packet({
				an = { { name = "_hue._tcp.local", type = "PTR", rdata = rdata } },
			})))
			assert.equal("x\\._hue\\._tcp\\.local", msg.records[1].target)
			assert.same({}, (mdns.read(packet({ an = { { name = "_hue._tcp.local", type = "PTR", rdata = rdata } } }))))
		end)

		it("skips records of another class and of types it does not use", function()
			local msg = assert(mdns.parse(packet({
				an = { { name = "_hue._tcp.local", type = "PTR", target = INSTANCE, class = 3 } },
				ar = { { name = INSTANCE, type = "NSEC", rdata = "\0\0" }, { name = HOST, type = "A", rdata = "\1\2\3" } },
			})))
			assert.same({}, msg.records)
			assert.equal(3, msg.ignored)
		end)
	end)

	describe("malformed and truncated packets", function()
		it("never raise: every prefix of a real answer gives nil and a reason, or a message", function()
			local data = house_answer()
			for n = 0, #data - 1 do
				local ok, msg, err = pcall(mdns.parse, data:sub(1, n))
				assert.is_true(ok, "parse raised at " .. n)
				assert.is_nil(msg, "a truncated packet of " .. n .. " bytes parsed")
				assert.equal("string", type(err))
				local ok2, list = pcall(mdns.read, data:sub(1, n))
				assert.is_true(ok2)
				assert.is_nil(list)
			end
		end)

		it("never raise on noise", function()
			local seed = 12345
			local function byte()
				seed = (seed * 1103515245 + 12345) % 2147483648
				return math.floor(seed / 65536) % 256
			end
			local base = house_answer()
			for round = 1, 300 do
				local bytes = {}
				for i = 1, #base do bytes[i] = base:byte(i) end
				-- A few bytes changed anywhere, or a packet of pure noise.
				if round % 10 == 0 then
					for i = 1, #bytes do bytes[i] = byte() end
				else
					for _ = 1, 1 + round % 5 do
						local at = 1 + byte() % #bytes
						bytes[at] = byte()
					end
				end
				local chars = {}
				for i, b in ipairs(bytes) do chars[i] = string.char(b) end
				local ok, err = pcall(mdns.read, table.concat(chars))
				assert.is_true(ok, "read raised: " .. tostring(err))
			end
		end)

		it("refuse a pointer to itself or ahead", function()
			local header = u16(1) .. u16(0x8400) .. u16(1) .. u16(0) .. u16(0) .. u16(0)
			local msg, err = mdns.parse(header .. string.char(192, 12) .. u16(12) .. u16(1))
			assert.is_nil(msg)
			assert.equal("a pointer that does not point back", err)
			msg, err = mdns.parse(header .. string.char(192, 40) .. u16(12) .. u16(1) .. string.rep("\0", 40))
			assert.is_nil(msg)
			assert.equal("a pointer that does not point back", err)
		end)

		it("refuse a chain of more pointers than a name may have", function()
			-- A first record (an unused type) at offset 12, named by the root,
			-- whose data is 20 pointers, each to the one before it (legal
			-- steps, too many of them); the second record is named by the last.
			local header = u16(1) .. u16(0x8400) .. u16(0) .. u16(2) .. u16(0) .. u16(0)
			local rdata_at = 12 + 1 + 10
			local chain, offsets = "", { 12 }
			for i = 1, 20 do
				offsets[i + 1] = rdata_at + #chain
				chain = chain .. string.char(192, offsets[i])
			end
			local first = "\0" .. u16(99) .. u16(1) .. u32(1) .. u16(#chain) .. chain
			local second = string.char(192, offsets[#offsets]) .. u16(1) .. u16(1) .. u32(1) .. u16(4) .. "\1\2\3\4"
			local msg, err = mdns.parse(header .. first .. second)
			assert.is_nil(msg)
			assert.equal("too many pointers in one name", err)
		end)

		it("refuse reserved label lengths, names over 255 bytes and implausible counts", function()
			local header = u16(1) .. u16(0x8400) .. u16(1) .. u16(0) .. u16(0) .. u16(0)
			local _, err = mdns.parse(header .. string.char(64) .. string.rep("a", 64) .. "\0" .. u16(12) .. u16(1))
			assert.equal("a label length of 64", err)
			local long = string.rep(string.char(63) .. string.rep("a", 63), 4) .. "\0"
			_, err = mdns.parse(header .. long .. u16(12) .. u16(1))
			assert.equal("a name longer than 255 bytes", err)
			_, err = mdns.parse(u16(1) .. u16(0x8400) .. u16(0) .. u16(60) .. u16(0) .. u16(60))
			assert.equal("implausible record counts", err)
		end)

		it("refuse a record whose data runs past the packet, and an SRV record too short", function()
			local _, err
			local header = u16(1) .. u16(0x8400) .. u16(0) .. u16(1) .. u16(0) .. u16(0)
			_, err = mdns.parse(header .. "\0" .. u16(1) .. u16(1) .. u32(1) .. u16(200) .. "\1\2\3\4")
			assert.equal("a record runs past the packet", err)
			_, err = mdns.parse(header .. "\0" .. u16(33) .. u16(1) .. u32(1) .. u16(4) .. "\0\0\1\187")
			assert.equal("an SRV record too short", err)
		end)

		it("refuse a name in PTR data that runs past its record", function()
			local header = u16(1) .. u16(0x8400) .. u16(0) .. u16(2) .. u16(0) .. u16(0)
			-- rdlength 2, but the name inside is 5 bytes; a second record follows.
			local data = header .. "\0" .. u16(12) .. u16(1) .. u32(1) .. u16(2) .. "\3abc\0"
				.. "\0" .. u16(1) .. u16(1) .. u32(1) .. u16(4) .. "\1\2\3\4"
			local msg, err = mdns.parse(data)
			assert.is_nil(msg)
			assert.equal("a PTR name runs past its record", err)
		end)

		it("refuse what is not a string, too short or too long", function()
			assert.same({ nil, "not a string" }, { mdns.parse(nil) })
			assert.same({ nil, "not a string" }, { mdns.parse({}) })
			assert.same({ nil, "shorter than a DNS header" }, { mdns.parse("\0\1") })
			assert.same({ nil, "longer than 9000 bytes" }, { mdns.parse(string.rep("\0", 9001)) })
		end)

		it("refuse an answer with another opcode", function()
			local list, err = mdns.read(packet({ flags = 0x8400 + 4 * 2048, an = {} }))
			assert.is_nil(list)
			assert.equal("opcode 4", err)
		end)
	end)
end)
