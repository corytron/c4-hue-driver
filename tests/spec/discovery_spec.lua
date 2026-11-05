-- #334, D5 and D12 (docs/simplify-actions-design.md §3.4):
-- bridge/discovery.lua, local discovery of Hue bridges. find_all (mDNS, a
-- few seconds), find_subnet (the offered sweep) and find_paired (mDNS, then
-- the hourly sweep of at most two /24 networks; the paired id only).
--
-- The module runs on the fake runtime (tests/helpers/fake_c4.lua): its
-- network bindings, timers on the fake clock (c4.advance) and persistence,
-- with the module's own default adapters. This spec adds the LAN: an mDNS
-- responder per bridge that answers each query on binding 6008 the way the
-- house's Bridge Pro answered the dev probe (build 447), "ONLINE" 4 ms after
-- NetConnect, a fake C4:CreateTCPClient (the fake runtime has none) and a
-- fake identity check (ctx.identify; one spec uses pairing.probe itself).
-- Placeholders only: bridge 10.0.2.143, controller 192.0.2.7, other hosts
-- 192.0.2.x and 198.51.100.x, ids 001788fffe123abc and 001788fffe456def.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BRIDGE_ID = "001788fffe123abc"
local OTHER_ID = "001788fffe456def"
local CONTROLLER = "192.0.2.7"
local BRIDGE_IP = "10.0.2.143"
local MOVED_IP = "192.0.2.57" -- the new address, in the controller's /24
local BINDING, GROUP, PORT = 6008, "224.0.0.251", 5353

local discovery, mdns, c4, env, d, lan, lines

-- DNS answers (RFC 1035 §4.1.4 compression), as the house's bridge sends them --

local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function u32(n) return u16(math.floor(n / 65536)) .. u16(n % 65536) end
local function ip_bytes(ip)
	local a, b, c, e = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(e))
end

local function packet(id, an, ar)
	local pieces, len, known = {}, 0, {}
	local function put(s) pieces[#pieces + 1] = s; len = len + #s end
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
	put(u16(id) .. u16(0x8400) .. u16(1) .. u16(#an) .. u16(0) .. u16(#ar))
	name("_hue._tcp.local")
	put(u16(12) .. u16(1))
	local types = { A = 1, PTR = 12, TXT = 16, AAAA = 28, SRV = 33 }
	for _, rec in ipairs(an) do rec.section = "an" end
	local all = {}
	for _, rec in ipairs(an) do all[#all + 1] = rec end
	for _, rec in ipairs(ar) do all[#all + 1] = rec end
	for _, rec in ipairs(all) do
		name(rec.name)
		put(u16(types[rec.type]) .. u16(rec.section == "an" and 1 or 0x8001) .. u32(120))
		local slot = #pieces + 1
		put("\0\0")
		local start = len
		if rec.type == "PTR" then name(rec.target)
		elseif rec.type == "SRV" then put(u16(0) .. u16(0) .. u16(443)); name(rec.target)
		elseif rec.type == "TXT" then for _, item in ipairs(rec.txt) do put(string.char(#item) .. item) end
		elseif rec.type == "A" then put(ip_bytes(rec.ip))
		elseif rec.type == "AAAA" then put(string.rep("\0", 15) .. "\1") end
		pieces[slot] = u16(len - start)
	end
	return table.concat(pieces)
end

-- r: { id (the TXT bridge id), model, ips = { A records } }
local function answer(r, query_id)
	local short = r.id:sub(-6):upper()
	local instance = "Hue Bridge - " .. short .. "._hue._tcp.local"
	local host = "001788" .. short .. ".local"
	local ar = {
		{ name = instance, type = "SRV", target = host },
		{ name = instance, type = "TXT", txt = { "bridgeid=" .. r.id:upper(), "modelid=" .. (r.model or "BSB003") } },
		{ name = host, type = "AAAA" },
	}
	for _, ip in ipairs(r.ips or {}) do ar[#ar + 1] = { name = host, type = "A", ip = ip } end
	return packet(query_id, { { name = "_hue._tcp.local", type = "PTR", target = instance } }, ar)
end

-- The LAN -----------------------------------------------------------------------------

-- lan.mdns: responders { id, model, ips, from (the sender, OS 4.x), garbage }
-- lan.hue[ip]: what the identity check finds there { id, model, name }
-- lan.tls[ip]: accepts 443, not a Signify chain; lan.hang[ip]: never answers
-- lan.refuse[ip]: refuses 443; anything else is silent on 443
local function new_lan()
	return { mdns = {}, hue = {}, tls = {}, hang = {}, refuse = {}, online = true, controller = CONTROLLER,
		identifies = {}, cancels = 0, queries = {}, tcp = { connects = {}, times = {}, live = 0, max_live = 0 } }
end

local function install_network()
	local real_connect, real_send = c4.NetConnect, c4.SendToNetwork
	c4.NetConnect = function(self, binding, port, kind, suppress)
		real_connect(self, binding, port, kind, suppress)
		if lan.connect_raises then error("NetConnect refused", 0) end
		if lan.online then
			c4:SetTimer(4, function() c4.net_status(binding, port, "ONLINE") end)
		end
	end
	c4.SendToNetwork = function(self, binding, port, data)
		if lan.send_raises then error("no route", 0) end
		real_send(self, binding, port, data)
		lan.queries[#lan.queries + 1] = { at = c4.now_ms, data = data }
		local qid = data:byte(1) * 256 + data:byte(2)
		for _, r in ipairs(lan.mdns) do
			c4:SetTimer(1, function()
				local bytes = r.garbage and "\0\1garbage" or answer(r, qid)
				env.ReceivedFromNetwork(binding, port, bytes, r.from)
			end)
		end
	end
end

local function install_tcp()
	local t = lan.tcp
	c4.CreateTCPClient = function()
		local cl = { cb = {}, state = "new" }
		function cl:OnConnect(fn) self.cb.connect = fn; return self end
		function cl:OnError(fn) self.cb.error = fn; return self end
		function cl:Connect(host, port)
			self.host, self.state = host, "pending"
			t.connects[#t.connects + 1] = host
			t.times[#t.times + 1] = c4.now_ms
			t.live = t.live + 1
			t.max_live = math.max(t.max_live, t.live)
			local open = lan.hue[host] or lan.tls[host] or lan.hang[host]
			if open or lan.refuse[host] then
				c4:SetTimer(open and 5 or 3, function()
					if self.state ~= "pending" then return end
					if open then
						self.state = "open"
						self.cb.connect(self)
					else
						self.state = "closed"
						t.live = t.live - 1
						self.cb.error(self, 111, "Connection refused")
					end
				end)
			end
			assert(port == 443)
			return self
		end
		function cl:Close()
			if self.state == "pending" or self.state == "open" then
				local pending = self.state == "pending"
				self.state = "closed"
				t.live = t.live - 1
				if pending then c4:SetTimer(1, function() self.cb.error(self, 125, "Operation canceled") end) end
			end
			return self
		end
		return cl
	end
end

local function fake_identify(ip, done)
	lan.identifies[#lan.identifies + 1] = { ip = ip, at = c4.now_ms }
	local handle = { Cancel = function() lan.cancels = lan.cancels + 1 end }
	local hue = lan.hue[ip]
	if lan.hang[ip] then
		return handle
	elseif hue then
		c4:SetTimer(50, function()
			done({ bridge_id = hue.id:upper(), model = hue.model or "BSB003", name = hue.name or "Hue Bridge",
				sw_version = "1968096020", api_version = "1.78.0" })
		end)
	else
		c4:SetTimer(60, function()
			done(nil, "transfer failed (60): Error 60: SSL peer certificate or SSH remote key was not OK")
		end)
	end
	return handle
end

local saved = {}
local CONSTANTS = { "JOB_CAP_MS", "IDENTITY_WAIT_MS", "IDENTITY_MAX", "IDENTITY_CAP_MS", "SWEEP_INTERVAL_MS" }

local function load(opts)
	opts = opts or {}
	for _, m in ipairs({ "bridge.discovery", "bridge.mdns", "bridge.sweep" }) do package.loaded[m] = nil end
	discovery = require("bridge.discovery")
	mdns = require("bridge.mdns")
	for _, name in ipairs(CONSTANTS) do saved[name] = discovery[name] end
	local ctx = { log = log, controller_ip = function() return lan.controller end }
	if not opts.real_identify then ctx.identify = fake_identify end
	d = discovery.new(ctx)
	env.OnConnectionStatusChanged = function(binding, port, status)
		if not d:status_changed(binding, port, status) then lan.other_status = (lan.other_status or 0) + 1 end
	end
	env.ReceivedFromNetwork = function(binding, port, data, from)
		if not d:received(binding, port, data, from) then lan.other_data = (lan.other_data or 0) + 1 end
	end
	return d
end

local function setup(opts)
	lines = {}
	log.sink = function(line) lines[#lines + 1] = line end
	log.set_debug(true)
	c4, env = fake.install_c4()
	lan = new_lan()
	install_network()
	install_tcp()
	load(opts)
end

local function calls(name)
	local out = {}
	for _, args in ipairs(c4.calls_to(name)) do
		if args[1] == BINDING then out[#out + 1] = args end
	end
	return out
end

local function bridge(id, ip, extra)
	local b = { id = id, model = "BSB003", name = "Upstairs" }
	for k, v in pairs(extra or {}) do b[k] = v end
	lan.hue[ip] = b
	return b
end

local function responder(id, ips, extra)
	local r = { id = id, ips = ips, model = "BSB003" }
	for k, v in pairs(extra or {}) do r[k] = v end
	lan.mdns[#lan.mdns + 1] = r
	return r
end

-- Calls `fn(done)`, runs the clock, returns every answer (each a list of values).
local function run(fn, ms)
	local answers = {}
	fn(function(...) answers[#answers + 1] = { ... } end)
	c4.advance(ms or 400000)
	return answers
end

-- Nothing left behind: the binding disconnected after its last connect,
-- every TCP client closed, no timer armed.
local function assert_clean()
	local connects, disconnects = calls("NetConnect"), c4.calls_to("NetDisconnect")
	if #connects > 0 then
		local last_connect, last_disconnect = 0, 0
		for i, call in ipairs(c4.calls) do
			if call.name == "NetConnect" and call.args[1] == BINDING then last_connect = i end
			if call.name == "NetDisconnect" and call.args[1] == BINDING then last_disconnect = i end
		end
		assert.is_true(last_disconnect > last_connect, "disconnected after the last connect")
		assert.is_true(#disconnects >= #connects)
	end
	assert.same({}, calls("SetBindingAddress"), "never cleared, never moved")
	assert.equal(0, lan.tcp.live, "every TCP client closed")
	assert.equal(0, #c4.active_timers(), "no timer left")
	assert.is_false(d:busy())
end

local function logged(pattern)
	for _, line in ipairs(lines) do
		if line:find(pattern, 1, true) then return line end
	end
	return nil
end

describe("bridge/discovery.lua (#334, D5 and D12)", function()
	after_each(function()
		for name, value in pairs(saved) do discovery[name] = value end
		log.set_debug(false)
	end)

	describe("find_all", function()
		before_each(function() setup() end)

		it("finds the bridge by mDNS in a few seconds on binding 6008, and leaves nothing open", function()
			bridge(BRIDGE_ID, BRIDGE_IP, { name = "Upstairs" })
			responder(BRIDGE_ID, { BRIDGE_IP })
			local t0 = c4.now_ms
			local answers = run(function(done) d:find_all(done) end)
			assert.equal(1, #answers)
			local list, detail = answers[1][1], answers[1][2]
			assert.same({ { id = BRIDGE_ID, name = "Upstairs", model = "BSB003", ip = BRIDGE_IP, how = "mdns",
				sw_version = "1968096020", api_version = "1.78.0", supported = true } }, list)
			assert.equal("1 Hue bridge found by mDNS", detail.text)
			assert.is_true(detail.ms < 4000, "a few seconds: " .. detail.ms)
			assert.same({ { BINDING, GROUP } }, calls("CreateNetworkConnection"))
			assert.same({ { BINDING, PORT, "UDP" } }, calls("NetConnect"))
			local sent = calls("SendToNetwork")
			assert.equal(2, #sent, "the query and its repeat")
			assert.equal(sent[1][3], sent[2][3])
			assert.equal(mdns.query(sent[1][3]:byte(1) * 256 + sent[1][3]:byte(2)), sent[1][3])
			assert.equal(t0 + 4, lan.queries[1].at, "sent on ONLINE")
			assert.equal(1000, lan.queries[2].at - lan.queries[1].at)
			assert.same({ BRIDGE_IP }, { lan.identifies[1].ip })
			assert.equal(1, #lan.identifies, "one identity check for the two answers")
			assert_clean()
		end)

		it("lists every bridge once, sorted by name, and drops an answer that fails the identity check", function()
			bridge(BRIDGE_ID, BRIDGE_IP, { name = "Upstairs" })
			bridge(OTHER_ID, "192.0.2.61", { name = "Garage", model = "BSB002" })
			responder(BRIDGE_ID, { BRIDGE_IP, "192.0.2.44" }) -- two addresses: the second answers as the same bridge
			lan.hue["192.0.2.44"] = lan.hue[BRIDGE_IP]
			responder(OTHER_ID, { "192.0.2.61" }, { model = "BSB002" })
			responder("001788fffe000000", { "192.0.2.62" }) -- an emulator: no Signify chain
			local answers = run(function(done) d:find_all(done) end)
			local list, detail = answers[1][1], answers[1][2]
			assert.equal(2, #list)
			assert.same({ "Garage", OTHER_ID, "192.0.2.61", "BSB002" }, { list[1].name, list[1].id, list[1].ip, list[1].model })
			assert.same({ "Upstairs", BRIDGE_ID, BRIDGE_IP }, { list[2].name, list[2].id, list[2].ip })
			assert.equal(1, #detail.dropped)
			assert.equal("192.0.2.62", detail.dropped[1].ip)
			assert.truthy(detail.dropped[1].why:find("60", 1, true))
			assert.equal("2 Hue bridges found by mDNS", detail.text)
			assert_clean()
		end)

		it("lists the bridge that answers at an address, not the one a stale record names", function()
			bridge(OTHER_ID, BRIDGE_IP, { name = "Garage" })
			responder(BRIDGE_ID, { BRIDGE_IP }) -- the paired bridge's old record, now someone else's address
			local list = run(function(done) d:find_all(done) end)[1][1]
			assert.equal(1, #list)
			assert.equal(OTHER_ID, list[1].id)
			assert.truthy(logged("but bridge " .. OTHER_ID .. " answers there"))
		end)

		it("answers an empty list after about 3 s when nothing answers", function()
			local answers = run(function(done) d:find_all(done) end)
			assert.same({}, answers[1][1])
			assert.equal("no Hue bridge answered", answers[1][2].text)
			assert.same({}, lan.identifies)
			assert_clean()
		end)

		it("sends the query after 1.5 s when Director reports no ONLINE", function()
			lan.online = false
			bridge(BRIDGE_ID, BRIDGE_IP)
			responder(BRIDGE_ID, { BRIDGE_IP })
			local t0 = c4.now_ms
			local list = run(function(done) d:find_all(done) end)[1][1]
			assert.equal(discovery.ONLINE_WAIT_MS, lan.queries[1].at - t0)
			assert.equal(1, #list)
			assert_clean()
		end)

		it("takes a second call while one runs into the same search", function()
			bridge(BRIDGE_ID, BRIDGE_IP)
			responder(BRIDGE_ID, { BRIDGE_IP })
			local a, b = {}, {}
			d:find_all(function(list) a[#a + 1] = list end)
			c4.advance(2000)
			d:find_all(function(list) b[#b + 1] = list end)
			c4.advance(60000)
			assert.equal(1, #a)
			assert.equal(1, #b)
			assert.same(a[1], b[1])
			assert.equal(1, #calls("NetConnect"))
			assert_clean()
		end)

		it("creates the binding once per run of the Lua, connects it again per search, creates it after a reload", function()
			bridge(BRIDGE_ID, BRIDGE_IP)
			responder(BRIDGE_ID, { BRIDGE_IP })
			run(function(done) d:find_all(done) end)
			run(function(done) d:find_all(done) end)
			assert.equal(1, #calls("CreateNetworkConnection"))
			assert.equal(2, #calls("NetConnect"))
			load() -- a dev-loop reload or a Director restart: the module's Lua runs again
			assert.equal(1, #run(function(done) d:find_all(done) end)[1][1])
			assert.equal(2, #calls("CreateNetworkConnection"))
			assert_clean()
		end)

		it("ignores answers outside a search, and passes other bindings on", function()
			assert.is_true(d:received(BINDING, PORT, answer({ id = BRIDGE_ID, ips = { BRIDGE_IP } }, 1)))
			assert.is_true(d:status_changed(BINDING, PORT, "OFFLINE"))
			assert.is_true(d:received(BINDING, PORT, nil))
			assert.is_false(d:received(6001, 443, "HTTP/1.1 200 OK\r\n"))
			assert.is_false(d:status_changed(6001, 443, "ONLINE"))
			assert.is_false(d:received(6100, 443, ""))
			assert.is_false(d:status_changed("6009", PORT, "ONLINE"))
			assert.is_true(d:owns("6008"))
			assert.equal(0, #c4.active_timers())
		end)

		it("counts a malformed answer, never raises, and keeps the good ones", function()
			bridge(BRIDGE_ID, BRIDGE_IP)
			responder(BRIDGE_ID, { BRIDGE_IP }, { garbage = true })
			responder(BRIDGE_ID, { BRIDGE_IP })
			local answers = run(function(done) d:find_all(done) end)
			assert.equal(1, #answers[1][1])
			assert.equal(2, answers[1][2].mdns.rejected, "the garbage, once per query")
			assert_clean()
		end)

		it("on OS 4.x also checks the sender's address: a record with no A, or a stale A", function()
			bridge(BRIDGE_ID, MOVED_IP)
			responder(BRIDGE_ID, {}, { from = MOVED_IP })
			local list = run(function(done) d:find_all(done) end)[1][1]
			assert.equal(MOVED_IP, list[1].ip)
			lan.mdns = {}
			responder(BRIDGE_ID, { BRIDGE_IP }, { from = MOVED_IP }) -- the A record is the old address
			list = run(function(done) d:find_all(done) end)[1][1]
			assert.equal(1, #list)
			assert.equal(MOVED_IP, list[1].ip)
			assert_clean()
		end)

		it("ends with an error, and nothing open, when the connection cannot be opened or the query sent", function()
			lan.connect_raises = true
			local answers = run(function(done) d:find_all(done) end)
			assert.same({}, answers[1][1])
			assert.truthy(answers[1][2].error:find("NetConnect refused", 1, true))
			lan.connect_raises, lan.send_raises = nil, true
			answers = run(function(done) d:find_all(done) end)
			assert.truthy(answers[1][2].error:find("could not send the mDNS query", 1, true))
			assert_clean()
		end)

		it("lists a first-generation bridge as not supported", function()
			bridge(OTHER_ID, "192.0.2.62", { model = "BSB001", name = "Old" })
			responder(OTHER_ID, { "192.0.2.62" }, { model = "BSB001" })
			local list = run(function(done) d:find_all(done) end)[1][1]
			assert.is_false(list[1].supported)
			assert.equal("Hue Bridge v1 - Old - 192.0.2.62 - not supported (no CLIP v2)", discovery.item_label(list[1]))
		end)
	end)

	describe("find_subnet", function()
		before_each(function() setup() end)

		it("sweeps the controller's /24, checks every address that accepted and lists every Hue bridge", function()
			bridge(BRIDGE_ID, "192.0.2.50")
			bridge(OTHER_ID, "192.0.2.61", { name = "Garage", model = "BSB002" })
			lan.tls["192.0.2.20"] = true -- a NAS
			lan.refuse["192.0.2.30"] = true -- a printer
			local answers = run(function(done) d:find_subnet(done) end)
			local list, detail = answers[1][1], answers[1][2]
			assert.equal(2, #list)
			assert.same({ "Garage", "sweep" }, { list[1].name, list[1].how })
			assert.same({ BRIDGE_ID, "192.0.2.50", "sweep" }, { list[2].id, list[2].ip, list[2].how })
			assert.equal(253, #lan.tcp.connects)
			for _, ip in ipairs(lan.tcp.connects) do assert.are_not.equal(CONTROLLER, ip) end
			assert.equal("192.0.2.8", lan.tcp.connects[1], "from the controller outward")
			assert.is_true(lan.tcp.max_live <= 4)
			local checked = {}
			for _, i in ipairs(lan.identifies) do checked[#checked + 1] = i.ip end
			table.sort(checked)
			assert.same({ "192.0.2.20", "192.0.2.50", "192.0.2.61" }, checked, "only what accepted port 443")
			assert.equal("searched 192.0.2.x: 2 Hue bridges (of 3 address(es) that accept port 443)", detail.text)
			assert.same({}, calls("NetConnect"), "no mDNS")
			assert_clean()
		end)

		it("covers the given address's /24 first, then the controller's", function()
			bridge(BRIDGE_ID, "198.51.100.20")
			local list = run(function(done) d:find_subnet(done, "198.51.100.75") end)[1][1]
			assert.equal("198.51.100.75", lan.tcp.connects[1])
			assert.equal(254 + 253, #lan.tcp.connects)
			assert.equal("198.51.100.20", list[1].ip)
			assert_clean()
		end)

		it("is not held back by the hourly limit, and records when it ran", function()
			local t0 = c4.now_ms
			run(function(done) d:find_subnet(done) end)
			assert.equal(t0, c4.persist[discovery.STORE_LAST_SWEEP])
			local before = #lan.tcp.connects
			run(function(done) d:find_subnet(done) end)
			assert.equal(2 * before, #lan.tcp.connects)
		end)

		it("takes the controller's address from C4:GetControllerNetworkAddress by default", function()
			d = discovery.new({ log = log, identify = fake_identify })
			c4.GetControllerNetworkAddress = function() return "198.51.100.7" end
			run(function(done) d:find_subnet(done) end)
			assert.equal("198.51.100.8", lan.tcp.connects[1])
			for _, ip in ipairs(lan.tcp.connects) do assert.are_not.equal("198.51.100.7", ip) end
			c4.GetControllerNetworkAddress = function() error("not here") end
			local answers = run(function(done) d:find_subnet(done) end)
			assert.equal("no network to search: no controller address", answers[1][2].error)
			c4.GetControllerNetworkAddress = nil
			answers = run(function(done) d:find_subnet(done) end)
			assert.equal("no network to search: no controller address", answers[1][2].error)
			assert_clean()
		end)

		-- Bridges Found's item names what this searches, in its order (#334
		-- §4 finding 12): the given address's /24 first, then the controller's.
		it("names its networks in subnet_nets and subnet_label, in the order it searches them", function()
			assert.same({ "198.51.100", "192.0.2" }, d:subnet_nets("198.51.100.75"))
			assert.equal("Search every address of 198.51.100.x and 192.0.2.x (about 4 minutes)",
				discovery.subnet_label(d:subnet_nets("198.51.100.75")))
			local answers = run(function(done) d:find_subnet(done, "198.51.100.75") end)
			assert.same(d:subnet_nets("198.51.100.75"), answers[1][2].sweep.nets, "the label's networks are the sweep's")
			assert.same({ "192.0.2" }, d:subnet_nets("192.0.2.61"), "one network when both are the same")
			assert.same({ "192.0.2" }, d:subnet_nets(nil))
			assert.same({ "192.0.2" }, d:subnet_nets("1.2.3.4"), "a public address is never searched, nor named")
			assert.equal("Search every address of 192.0.2.x (about 2 minutes)", discovery.subnet_label({ "192.0.2" }))
			lan.controller = nil
			assert.same({}, d:subnet_nets(nil))
			assert.is_nil(discovery.subnet_label(d:subnet_nets(nil)))
			assert.is_nil(discovery.subnet_label(nil))
		end)

		it("refuses to search a network that could be on the internet", function()
			lan.controller = nil
			local answers = run(function(done) d:find_subnet(done, "1.2.3.4") end)
			assert.same({}, answers[1][1])
			assert.equal("no network to search: 1.2.3.4 is not a private network; no controller address",
				answers[1][2].error)
			assert.same({}, lan.tcp.connects)
			assert_clean()
		end)
	end)

	describe("find_paired", function()
		before_each(function() setup() end)

		it("finds the paired bridge at its new address by mDNS, without a single TCP connect", function()
			bridge(BRIDGE_ID, MOVED_IP)
			responder(BRIDGE_ID, { MOVED_IP })
			local answers = run(function(done) d:find_paired(BRIDGE_ID:upper(), BRIDGE_IP, done) end)
			assert.same({ MOVED_IP, "mdns" }, { answers[1][1], answers[1][2] })
			assert.equal("found by mDNS", answers[1][3].text)
			assert.same({}, lan.tcp.connects)
			assert.is_nil(c4.persist[discovery.STORE_LAST_SWEEP])
			assert_clean()
		end)

		it("never checks, nor returns, another bridge's answer", function()
			bridge(OTHER_ID, "192.0.2.61")
			responder(OTHER_ID, { "192.0.2.61" })
			local answers = run(function(done) d:find_paired(BRIDGE_ID, BRIDGE_IP, done) end)
			assert.same({ nil, "not_found" }, { answers[1][1], answers[1][2] })
			assert.equal(1, #lan.identifies, "checked once, by the sweep")
			assert.is_true(lan.identifies[1].at > lan.tcp.times[1], "not in the mDNS stage")
			assert_clean()
		end)

		it("never takes another bridge that answers where a record of the paired id points", function()
			bridge(OTHER_ID, "192.0.2.61")
			responder(BRIDGE_ID, { "192.0.2.61" }) -- the paired id's stale record: DHCP gave that address away
			local answers = run(function(done) d:find_paired(BRIDGE_ID, BRIDGE_IP, done) end)
			assert.same({ nil, "not_found" }, { answers[1][1], answers[1][2] })
			assert.equal("192.0.2.61", lan.identifies[1].ip, "the record was checked")
			assert.truthy(answers[1][3].text:find("mDNS: its answer did not check out", 1, true))
			assert_clean()
		end)

		it("sweeps when the mDNS record of the paired id is stale, and finds it", function()
			bridge(BRIDGE_ID, MOVED_IP)
			responder(BRIDGE_ID, { BRIDGE_IP }) -- the old address, where nothing answers now
			local answers = run(function(done) d:find_paired(BRIDGE_ID, BRIDGE_IP, done) end)
			assert.same({ MOVED_IP, "sweep" }, { answers[1][1], answers[1][2] })
			assert.equal(BRIDGE_IP, lan.identifies[1].ip, "the record was checked first")
			assert.equal("found by a search of 10.0.2.x and 192.0.2.x", answers[1][3].text)
			assert_clean()
		end)

		it("sweeps last_ip's /24 from last_ip outward, then the controller's, and stops at the paired id", function()
			bridge(OTHER_ID, "198.51.100.37") -- another bridge on the way: checked, passed over
			bridge(BRIDGE_ID, "192.0.2.60")
			local answers = run(function(done) d:find_paired(BRIDGE_ID, "198.51.100.40", done) end)
			assert.same({ "192.0.2.60", "sweep" }, { answers[1][1], answers[1][2] })
			local tried = lan.tcp.connects
			assert.same({ "198.51.100.40", "198.51.100.41", "198.51.100.39" }, { tried[1], tried[2], tried[3] })
			local seen = {}
			for _, ip in ipairs(tried) do seen[ip] = true end
			assert.is_nil(seen[CONTROLLER])
			assert.is_true(seen["192.0.2.60"])
			assert.is_nil(seen["192.0.2.200"], "stopped at the match")
			assert.truthy(logged("not the paired 123ABC"))
			assert_clean()
		end)

		it("sweeps at most once an hour, says so, and remembers it across a restart", function()
			local answers = run(function(done) d:find_paired(BRIDGE_ID, BRIDGE_IP, done) end)
			assert.equal("not_found", answers[1][2])
			assert.equal("not found on the network (mDNS: no answer for it; searched 10.0.2.x and 192.0.2.x)",
				answers[1][3].text)
			local swept = #lan.tcp.connects
			assert.equal(254 + 253, swept)
			c4.advance(10 * 60000)
			answers = run(function(done) d:find_paired(BRIDGE_ID, BRIDGE_IP, done) end, 30000)
			assert.same({ nil, "limited" }, { answers[1][1], answers[1][2] })
			assert.truthy(answers[1][3].text:find("at most once an hour (next in", 1, true))
			assert.is_true(answers[1][3].next_sweep_ms > c4.now_ms)
			assert.equal(swept, #lan.tcp.connects, "no sweep")
			assert.equal(2, #calls("NetConnect"), "mDNS still runs")
			load() -- a restart: the limit is persisted
			answers = run(function(done) d:find_paired(BRIDGE_ID, BRIDGE_IP, done) end, 30000)
			assert.equal("limited", answers[1][2])
			c4.advance(discovery.SWEEP_INTERVAL_MS)
			bridge(BRIDGE_ID, "192.0.2.150")
			answers = run(function(done) d:find_paired(BRIDGE_ID, BRIDGE_IP, done) end)
			assert.same({ "192.0.2.150", "sweep" }, { answers[1][1], answers[1][2] })
			assert_clean()
		end)

		it("sweeps only the controller's /24 when the last address is unknown or public", function()
			bridge(BRIDGE_ID, "192.0.2.60")
			for _, last in ipairs({ false, "1.2.3.4" }) do
				lan.tcp.connects = {}
				c4.persist[discovery.STORE_LAST_SWEEP] = nil
				d.last_sweep = nil
				local answers = run(function(done) d:find_paired(BRIDGE_ID, last or nil, done) end)
				assert.equal("192.0.2.60", answers[1][1])
				for _, ip in ipairs(lan.tcp.connects) do
					assert.equal("192.0.2.", ip:sub(1, 8))
				end
			end
			assert_clean()
		end)

		it("refuses a bridge id that is not one, sending nothing", function()
			local answers = run(function(done) d:find_paired("not-an-id", BRIDGE_IP, done) end)
			assert.same({ nil, "error" }, { answers[1][1], answers[1][2] })
			assert.same({}, calls("NetConnect"))
			assert_clean()
		end)

		it("takes a second call for the same id into the running search; another id cancels it", function()
			bridge(BRIDGE_ID, MOVED_IP)
			responder(BRIDGE_ID, { MOVED_IP })
			local a, b, c = {}, {}, {}
			d:find_paired(BRIDGE_ID, BRIDGE_IP, function(...) a[#a + 1] = { ... } end)
			d:find_paired(BRIDGE_ID, BRIDGE_IP, function(...) b[#b + 1] = { ... } end)
			c4.advance(60000)
			assert.same({ MOVED_IP, "mdns" }, { a[1][1], a[1][2] })
			assert.same({ MOVED_IP, "mdns" }, { b[1][1], b[1][2] })
			d:find_paired(BRIDGE_ID, BRIDGE_IP, function(...) a[#a + 1] = { ... } end)
			d:find_paired(OTHER_ID, BRIDGE_IP, function(...) c[#c + 1] = { ... } end)
			c4.advance(400000)
			assert.same({ nil, "cancelled" }, { a[2][1], a[2][2] })
			assert.equal(1, #c)
			assert_clean()
		end)

		it("gives up on an identity check after 20 s, cancels it, and goes on with the next address", function()
			lan.hang[BRIDGE_IP] = true
			bridge(BRIDGE_ID, MOVED_IP)
			responder(BRIDGE_ID, { BRIDGE_IP, MOVED_IP })
			local answers = run(function(done) d:find_paired(BRIDGE_ID, BRIDGE_IP, done) end)
			assert.same({ MOVED_IP, "mdns" }, { answers[1][1], answers[1][2] })
			assert.equal(1, lan.cancels)
			local gap = lan.identifies[2].at - lan.identifies[1].at
			assert.is_true(gap >= discovery.IDENTITY_WAIT_MS and gap <= discovery.IDENTITY_WAIT_MS + 10, "gap " .. gap)
			assert_clean()
		end)

		it("checks identity exactly as pairing does: pairing.probe's unkeyed GET of /api/0/config", function()
			setup({ real_identify = true })
			responder(BRIDGE_ID, { MOVED_IP })
			local answers = {}
			d:find_paired(BRIDGE_ID, BRIDGE_IP, function(...) answers[#answers + 1] = { ... } end)
			c4.advance(5000)
			local t = c4.last_transfer()
			assert.equal("https://" .. MOVED_IP .. "/api/0/config", t.url)
			assert.is_nil(t.headers and t.headers["hue-application-key"])
			t:respond(200, '{"name":"Upstairs","bridgeid":"001788FFFE123ABC","modelid":"BSB003",'
				.. '"swversion":"1968096020","apiversion":"1.78.0"}')
			c4.advance(100)
			assert.same({ MOVED_IP, "mdns" }, { answers[1][1], answers[1][2] })
		end)

		it("does not take a Signify-less answer from pairing.probe (error 60), and answers nothing after stop()", function()
			setup({ real_identify = true })
			responder(BRIDGE_ID, { MOVED_IP })
			local answers = {}
			d:find_paired(BRIDGE_ID, BRIDGE_IP, function(...) answers[#answers + 1] = { ... } end)
			c4.advance(5000)
			c4.last_transfer():done(60, "SSL peer certificate or SSH remote key was not OK")
			c4.advance(1000)
			d:stop()
			c4.advance(400000)
			assert.same({}, answers, "no answer after stop()")
		end)
	end)

	describe("errors and the end of a run", function()
		before_each(function() setup() end)

		it("ends a job whose step raises, with the error, and closes everything", function()
			bridge(BRIDGE_ID, "192.0.2.50")
			lan.hue["192.0.2.50"].model = setmetatable({}, { __tostring = function() error("boom") end })
			local answers = run(function(done) d:find_subnet(done) end)
			assert.equal(1, #answers)
			assert.truthy(answers[1][2].error:find("boom", 1, true))
			assert_clean()
		end)

		it("ends a job at its safety cap", function()
			discovery.JOB_CAP_MS = 5000
			discovery.IDENTITY_WAIT_MS = 60000
			lan.hang[BRIDGE_IP] = true
			responder(BRIDGE_ID, { BRIDGE_IP })
			local answers = run(function(done) d:find_paired(BRIDGE_ID, BRIDGE_IP, done) end, 70000)
			assert.same({ nil, "error" }, { answers[1][1], answers[1][2] })
			assert.equal("the search stopped: stopped at the 5 s cap", answers[1][3].text)
			assert_clean()
		end)

		it("checks at most IDENTITY_MAX addresses per job", function()
			discovery.IDENTITY_MAX = 2
			for i = 20, 25 do lan.tls["192.0.2." .. i] = true end
			local answers = run(function(done) d:find_subnet(done) end)
			assert.equal(2, #lan.identifies)
			assert.equal(4, answers[1][2].sweep.unchecked)
			assert_clean()
		end)

		it("counts a clicked sweep against the hourly limit of the automatic one", function()
			local first, second = {}, {}
			d:find_subnet(function(...) first[#first + 1] = { ... } end)
			c4.advance(1000)
			d:find_paired(BRIDGE_ID, BRIDGE_IP, function(...) second[#second + 1] = { ... } end)
			c4.advance(400000)
			assert.equal(1, #first)
			assert.equal("limited", second[1][2])
			assert_clean()
		end)

		it("never runs two sweeps at once: the second waits for the first", function()
			discovery.SWEEP_INTERVAL_MS = 1
			bridge(BRIDGE_ID, "192.0.2.60")
			local first, second = {}, {}
			d:find_subnet(function(...) first[#first + 1] = { at = c4.now_ms, ... } end)
			c4.advance(1000)
			d:find_paired(BRIDGE_ID, BRIDGE_IP, function(...) second[#second + 1] = { ... } end)
			c4.advance(800000)
			assert.equal(1, #first)
			assert.same({ "192.0.2.60", "sweep" }, { second[1][1], second[1][2] })
			assert.is_true(lan.tcp.max_live <= 4)
			local paired_start
			for i, ip in ipairs(lan.tcp.connects) do
				if ip == BRIDGE_IP and not paired_start then paired_start = lan.tcp.times[i] end
			end
			assert.is_true(paired_start >= first[1].at, "the second sweep started after the first had answered")
			assert_clean()
		end)

		it("stop() inside the mDNS window: no answer afterwards, the binding disconnected, no timer left", function()
			bridge(BRIDGE_ID, BRIDGE_IP)
			responder(BRIDGE_ID, { BRIDGE_IP })
			local answers = {}
			d:find_paired(BRIDGE_ID, BRIDGE_IP, function(...) answers[#answers + 1] = { ... } end)
			d:find_all(function(...) answers[#answers + 1] = { ... } end)
			c4.advance(2000)
			d:stop()
			c4.advance(400000)
			assert.same({}, answers)
			assert_clean()
		end)

		it("stop() inside a sweep: every client closed, no answer, and the instance does nothing more", function()
			local answers = {}
			d:find_paired(BRIDGE_ID, BRIDGE_IP, function(...) answers[#answers + 1] = { ... } end)
			c4.advance(8000)
			assert.is_true(lan.tcp.live > 0, "the sweep is running")
			d:stop()
			c4.advance(400000)
			assert.same({}, answers)
			assert_clean()
			local before = #calls("NetConnect")
			d:find_all(function(...) answers[#answers + 1] = { ... } end)
			d:find_subnet(function(...) answers[#answers + 1] = { ... } end)
			d:find_paired(BRIDGE_ID, BRIDGE_IP, function(...) answers[#answers + 1] = { ... } end)
			c4.advance(10000)
			assert.same({}, answers)
			assert.equal(before, #calls("NetConnect"))
		end)
	end)

	describe("item_label (Bridges Found)", function()
		before_each(function() setup() end)

		local item = { id = BRIDGE_ID, name = "Upstairs", model = "BSB003", ip = BRIDGE_IP, supported = true }

		it("reads model, name, address and the id's last six digits", function()
			assert.equal("Hue Bridge Pro - Upstairs - 10.0.2.143 - 123ABC", discovery.item_label(item))
			assert.equal("(paired) Hue Bridge Pro - Upstairs - 10.0.2.143 - 123ABC",
				discovery.item_label(item, BRIDGE_ID:upper()))
			assert.equal("Hue Bridge v2 - Garage - 192.0.2.61 - 456DEF", discovery.item_label({ id = OTHER_ID,
				name = "Garage", model = "BSB002", ip = "192.0.2.61" }, BRIDGE_ID))
			assert.equal("Hue bridge BSB009 - X - 192.0.2.63 - 456DEF", discovery.item_label({ id = OTHER_ID, name = "X",
				model = "BSB009", ip = "192.0.2.63" }))
		end)

		it("marks a replacement of the paired bridge", function()
			assert.equal("Hue Bridge Pro - New - 192.0.2.64 - replaces the paired bridge", discovery.item_label({
				id = OTHER_ID, name = "New", model = "BSB003", ip = "192.0.2.64", replaces = BRIDGE_ID }, BRIDGE_ID))
		end)

		it("cuts the name to 20 characters, whole UTF-8 characters, and stays within 72", function()
			local long = { id = BRIDGE_ID, name = string.rep("é", 30), model = "BSB003", ip = "192.168.100.200" }
			local text = discovery.item_label(long, BRIDGE_ID)
			local chars = 0
			for i = 1, #text do
				local b = text:byte(i)
				if b < 128 or b >= 192 then chars = chars + 1 end
			end
			assert.is_true(chars <= discovery.ITEM_MAX, chars .. " characters")
			assert.truthy(text:find(string.rep("é", 18), 1, true))
			assert.is_nil(text:find("\195 ", 1, true), "never half a character")
			assert.equal("Hue Bridge Pro - Kitchen and dining r - 10.0.2.143 - 123ABC", discovery.item_label({
				id = BRIDGE_ID, name = "Kitchen and dining room bridge", model = "BSB003", ip = BRIDGE_IP }))
		end)

		it("strips control characters and survives missing fields", function()
			assert.equal("Hue Bridge Pro - Up - 10.0.2.143 - 123ABC", discovery.item_label({ id = BRIDGE_ID,
				name = "Up\r\n", model = "BSB003", ip = BRIDGE_IP }))
			assert.equal("Hue bridge -  - ", discovery.item_label({}))
		end)
	end)
end)
