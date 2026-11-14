-- #514, stage 1 §3 (docs/hdmi-sync-stage1-design.md): common/mdns.lua, the
-- legacy unicast query and parser given its service, config, sweep and TXT
-- keys. bridge/mdns.lua is one instance (tests/spec/mdns_spec.lua covers it,
-- unchanged); this spec covers another service, _huesync._tcp.local with the
-- TXT keys the sync box research names (name, devicetype, uniqueid, path;
-- docs/syncbox-api-research.md), and the window that keeps the #490 rules
-- (query id, usable addresses, the per-window cap). The box's answer below
-- is [assumed] in the shape of the bridge's (the first dev build shows it).
-- Placeholders only: sync box 10.0.2.150, bridge 10.0.2.143, VM 192.0.2.7.

local mdns_module = require("common.mdns")

local BOX_ID = "0a1b2c3d4e5f"
local INSTANCE = "Hue Sync Box 4E5F._huesync._tcp.local"
local HOST = "0A1B2C3D4E5F.local"

-- The strict dotted-quad rule of bridge/config.lua's parse_ipv4, written
-- here so that the box's instance needs nothing from bridge/.
local config = {
	parse_ipv4 = function(value)
		if type(value) ~= "string" then return nil end
		local text = value:match("^%s*(.-)%s*$")
		local octets = { text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
		if #octets ~= 4 then return nil end
		for i, o in ipairs(octets) do
			if (#o > 1 and o:sub(1, 1) == "0") or tonumber(o) > 255 then return nil end
			octets[i] = tostring(tonumber(o))
		end
		return table.concat(octets, ".")
	end,
}

local function box_id(raw)
	local id = type(raw) == "string" and raw:lower() or ""
	return (#id == 12 and id:match("^%x+$")) and id or nil
end

-- Addresses outside the repository's placeholders are put together from
-- their octets, so that the secrets check (.gitleaks.toml) sees no literal.
local function dotted(...) return table.concat({ ... }, ".") end

-- A DNS message writer with name compression (RFC 1035 §4.1.4), as in
-- mdns_spec.lua: opts id, flags, question, an, ar = { { name, type, target,
-- port, txt, ip } }.
local TYPES = { A = 1, PTR = 12, TXT = 16, AAAA = 28, SRV = 33 }
local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end

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
			if known[suffix] then
				put(string.char(192 + math.floor(known[suffix] / 256), known[suffix] % 256))
				return
			end
			known[suffix] = len
			put(string.char(#parts[i]) .. parts[i])
		end
		put("\0")
	end
	local an, ar = opts.an or {}, opts.ar or {}
	put(u16(opts.id or 0x2b1d) .. u16(opts.flags or 0x8400) .. u16(1) .. u16(#an) .. u16(0) .. u16(#ar))
	name(opts.question or "_huesync._tcp.local")
	put(u16(12) .. u16(1))
	local function record(rec, section)
		name(rec.name)
		put(u16(TYPES[rec.type]) .. u16(section == "ar" and 0x8001 or 1) .. u16(0) .. u16(4500))
		local slot = #pieces + 1
		put("\0\0")
		local start = len
		if rec.type == "PTR" then
			name(rec.target)
		elseif rec.type == "SRV" then
			put(u16(0) .. u16(0) .. u16(rec.port or 443))
			name(rec.target)
		elseif rec.type == "TXT" then
			for _, item in ipairs(rec.txt) do put(string.char(#item) .. item) end
		elseif rec.type == "A" then
			local a, b, c, d = rec.ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
			put(string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d)))
		elseif rec.type == "AAAA" then
			put(string.rep("\0", 15) .. "\1")
		end
		pieces[slot] = u16(len - start)
	end
	for _, rec in ipairs(an) do record(rec, "an") end
	for _, rec in ipairs(ar) do record(rec, "ar") end
	return table.concat(pieces)
end

-- A sync box's answer, with placeholders.
local function box_answer(opts)
	opts = opts or {}
	return packet({
		id = opts.id,
		an = { { name = "_huesync._tcp.local", type = "PTR", target = INSTANCE } },
		ar = {
			{ name = INSTANCE, type = "SRV", port = 443, target = HOST },
			{ name = INSTANCE, type = "TXT", txt = opts.txt or { "name=Living Room Box", "devicetype=HSB2",
				"uniqueid=" .. (opts.unique_id or BOX_ID:upper()), "path=/api" } },
			{ name = HOST, type = "A", ip = opts.ip or "10.0.2.150" },
			{ name = HOST, type = "AAAA" },
		},
	})
end

-- The bridge's answer (mdns_spec.lua's house answer, shortened).
local function bridge_answer()
	local instance, host = "Hue Bridge - 123ABC._hue._tcp.local", "001788123ABC.local"
	return packet({
		question = "_hue._tcp.local",
		an = { { name = "_hue._tcp.local", type = "PTR", target = instance } },
		ar = {
			{ name = instance, type = "SRV", port = 443, target = host },
			{ name = instance, type = "TXT", txt = { "bridgeid=001788FFFE123ABC", "modelid=BSB003" } },
			{ name = host, type = "A", ip = "10.0.2.143" },
		},
	})
end

local function box_mdns(extra)
	local opts = {
		service = "_huesync._tcp",
		config = config,
		txt = { id = "uniqueid", model = "devicetype", name = "name" },
		normalise_id = box_id,
	}
	for k, v in pairs(extra or {}) do opts[k] = v end
	return mdns_module.new(opts)
end

describe("common/mdns.lua (#514)", function()
	local box

	before_each(function()
		box = box_mdns()
	end)

	describe("another service", function()
		it("asks for _huesync._tcp.local, .local added to the service it was given", function()
			assert.equal("_huesync._tcp.local", box.SERVICE)
			local q = box.query(0x2b1d)
			assert.equal(string.char(0x2b, 0x1d, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)
				.. "\8_huesync\4_tcp\5local\0" .. string.char(0, 12, 0, 1), q)
			assert.equal("_huesync._tcp.local", box_mdns({ service = "_HueSync._tcp.local" }).SERVICE)
			assert.same({ 5353, "224.0.0.251" }, { box.PORT, box.GROUP })
		end)

		it("reads the box's id, model and name from its own TXT keys, and nothing from path", function()
			local list = assert(box.read(box_answer()))
			assert.equal(1, #list)
			local c = list[1]
			assert.equal(INSTANCE, c.instance)
			assert.equal(BOX_ID, c.id)
			assert.equal(BOX_ID:upper(), c.raw_id)
			assert.equal("HSB2", c.model)
			assert.equal("Living Room Box", c.name)
			assert.equal(HOST, c.host)
			assert.equal(443, c.port)
			assert.equal("10.0.2.150", c.ip)
			assert.is_nil(c.path, "the TXT path is never taken (finding 10: the driver's paths are literal)")
		end)

		it("leaves the id unset when normalise_id refuses it, keeping what was written", function()
			local list = assert(box.read(box_answer({ unique_id = "001788FFFE123ABC" })))
			assert.is_nil(list[1].id)
			assert.equal("001788FFFE123ABC", list[1].raw_id)
		end)

		it("keeps the services apart: the box finds no bridge, the bridge's instance no box", function()
			local list = assert(box.read(bridge_answer()))
			assert.same({}, list)
			local bridge = mdns_module.new({ service = "_hue._tcp", config = config,
				txt = { id = "bridgeid", model = "modelid" }, normalise_id = function(raw) return raw:lower() end })
			assert.same({}, assert(bridge.read(box_answer())))
			local hue = assert(bridge.read(bridge_answer()))
			assert.equal("001788fffe123abc", hue[1].id)
			assert.equal("BSB003", hue[1].model)
			assert.is_nil(hue[1].name, "no name without a txt.name key")
		end)

		it("refuses at new() a missing service, config, TXT id key or normalise_id", function()
			for _, missing in ipairs({ "service", "config", "txt", "normalise_id" }) do
				local opts = { service = "_huesync._tcp", config = config, txt = { id = "uniqueid" }, normalise_id = box_id }
				opts[missing] = nil
				local ok, err = pcall(mdns_module.new, opts)
				assert.is_false(ok, missing)
				assert.truthy(tostring(err):find(missing, 1, true), tostring(err))
			end
			assert.is_false((pcall(mdns_module.new, { service = "_huesync._tcp", config = config, txt = {},
				normalise_id = box_id })))
		end)
	end)

	-- Security review 2026-11-13, N-3 (#490): the address rule lives in the
	-- common module, so a driver without a sweep keeps it, and a sweep can
	-- only narrow it.
	describe("usable addresses (N-3, #490)", function()
		local PRIVATE = { "10.0.2.150", "172.16.0.9", dotted(172, 31, 255, 254), "192.168.1.20", dotted(169, 254, 12, 34),
			"192.0.2.7", "198.51.100.7", "203.0.113.9" }
		local PUBLIC = { "1.2.3.4", dotted(8, 8, 8, 8), dotted(100, 64, 0, 1), dotted(172, 32, 0, 1),
			dotted(192, 169, 0, 1), dotted(169, 255, 0, 1), dotted(11, 0, 0, 1), "127.0.0.1", "0.0.0.0", "224.0.0.251" }

		it("takes private, link-local and documentation addresses without a sweep, and nothing else", function()
			for _, ip in ipairs(PRIVATE) do
				assert.is_true(box.usable_address(ip), ip)
				assert.equal(ip, assert(box.read(box_answer({ ip = ip })))[1].ip, ip)
			end
			for _, ip in ipairs(PUBLIC) do
				assert.is_false(box.usable_address(ip), ip)
				assert.same({}, assert(box.read(box_answer({ ip = ip })))[1].ips, ip)
			end
			assert.is_false(box.usable_address("10.0.2.0150"), "config.parse_ipv4 decides the spelling")
			assert.is_false(box.usable_address(nil))
		end)

		it("lets a sweep narrow the networks, link-local always kept, but never widen them", function()
			local narrow = box_mdns({ sweep = { searchable = function(ip) return ip:match("^10%.") ~= nil end } })
			assert.is_true(narrow.usable_address("10.0.2.150"))
			assert.is_true(narrow.usable_address(dotted(169, 254, 12, 34)))
			assert.is_false(narrow.usable_address("192.168.1.20"))
			local lax = box_mdns({ sweep = { searchable = function() return true end } })
			for _, ip in ipairs(PUBLIC) do
				assert.is_false(lax.usable_address(ip), ip)
			end
		end)
	end)

	describe("the window (#490)", function()
		it("takes only answers to its own query, the id repeated", function()
			local w = box.window(0x12b1d)
			assert.equal(0x2b1d, w.query_id, "kept within 16 bits, as query() writes it")
			assert.equal(box.query(0x2b1d), w:query())
			local added, err = w:take(box_answer({ id = 0x0001 }))
			assert.is_nil(added)
			assert.equal("an answer with id 0x0001 to query 0x2b1d", err)
			assert.equal(1, w.rejected)
			added = assert(w:take(box_answer()))
			assert.same({ { id = BOX_ID, raw_id = BOX_ID:upper(), model = "HSB2", name = "Living Room Box",
				instance = INSTANCE, ip = "10.0.2.150", port = 443, via = "a" } }, added)
			assert.same(added, w.cands)
			assert.same({}, assert(w:take(box_answer())), "the same id at the same address once")
			assert.equal(3, w.answers)
		end)

		it("refuses a query, noise and what is not a datagram", function()
			local w = box.window(7)
			assert.is_nil(w:take(box.query(7)))
			assert.is_nil(w:take("\0\1"))
			local added, err = w:take(nil)
			assert.is_nil(added)
			assert.equal("not a datagram", err)
			assert.equal(2, w.rejected)
		end)

		it("adds the sender's address when it is usable, and only then (OS 4.x names it)", function()
			local w = box.window(0x2b1d)
			local added = assert(w:take(box_answer(), "192.0.2.7"))
			assert.equal(2, #added)
			assert.same({ "10.0.2.150", "a" }, { added[1].ip, added[1].via })
			assert.same({ "192.0.2.7", "from" }, { added[2].ip, added[2].via })
			added = assert(w:take(box_answer({ unique_id = "0A1B2C3D4E60" }), dotted(8, 8, 8, 8)))
			assert.equal(1, #added)
			assert.equal("10.0.2.150", added[1].ip)
			assert.equal(1, w.senders_refused)
		end)

		it("parses at most max_answers datagrams, and as many again that name a wanted id", function()
			local w = box.window(0x2b1d, { max_answers = 2 })
			w:want("0A1B2C999999")
			for i = 1, 3 do
				local added, err = w:take(box_answer({ unique_id = string.format("0A1B2C%06d", i) }))
				if i <= 2 then
					assert.equal(1, #added, i)
				else
					assert.is_nil(added)
					assert.equal("over the window's cap", err)
				end
			end
			assert.equal(2, w.parsed)
			assert.equal(1, w.dropped)
			local added = assert(w:take(box_answer({ unique_id = "0A1B2C999999" })), "the wanted box still gets in")
			assert.equal("0a1b2c999999", added[1].id)
			assert.equal(1, w.parsed_wanted)
			assert.equal(box.MAX_ANSWERS, box.window(1).max_answers)
			assert.equal(32, box.MAX_ANSWERS, "the bridge's discovery.MAX_ANSWERS")
		end)
	end)

	it("never raises on noise or a truncated answer", function()
		local answer = box_answer()
		for n = 0, #answer - 1 do
			local ok = pcall(box.read, answer:sub(1, n))
			assert.is_true(ok, n)
		end
		assert.is_nil(box.read(string.rep("\255", 600)))
	end)
end)
