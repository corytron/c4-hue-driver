-- The 1.2 probe (#334, docs/simplify-actions-design.md §2.2;
-- src/hue_bridge/bridge/probe12.lua): the dev-build commands that answer on
-- the house controller what the 1.2 design still assumes. Probe Discovery
-- (docs/simplify-research-discovery.md §3): the environment, the SSDP
-- control, three mDNS queries on network bindings 6004 to 6007, and a TCP
-- sweep of port 443 over one /24 with never more than four connects at once,
-- then pairing's unkeyed identity probe. Probe Names
-- (docs/simplify-research-names-sync.md §8): renames on the bridge and back,
-- every original restored and read back whatever happened. The picker test:
-- folders in a CUSTOM_SELECT list and what Composer sends back.
--
-- The module runs against fake.install_c4 with a clock of this spec's own
-- (C4:SetTimer replaced: timers fire in time order as `advance` moves the
-- clock), a fake C4:CreateTCPClient (the fake runtime has none), a fake
-- bridge behind ctx.bridge_request, and the fake's C4:url transfers for the
-- identity probe.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local CONTROLLER = "192.0.2.7"
local BRIDGE_IP = "10.0.2.143"
local SWEEP_BRIDGE = "192.0.2.50" -- the paired bridge, in the controller's /24, for the sweep
local NAS = "192.0.2.20"          -- accepts port 443, not a Signify chain
local PRINTER = "192.0.2.30"      -- refuses port 443
local BRIDGE_ID = "001788fffe123abc"
local KEY = "probe12-spec-key"    -- a placeholder; no log line may carry it
local CONFIG = '{"name":"Hue Bridge","bridgeid":"001788FFFE123ABC","modelid":"BSB003","swversion":"1968096020",'
	.. '"apiversion":"1.68.0"}'

local probe12, c4, env, lines, actions, timers, tcp, bridge, ctx, driver_calls

-- Clock and timers ------------------------------------------------------------

local function install_clock()
	local seq = 0
	timers = {}
	c4.SetTimer = function(_, delay, callback, repeating)
		assert(type(delay) == "number" and delay > 0, "timer delay must be > 0")
		seq = seq + 1
		local t = { due = c4.now_ms + delay, delay = delay, callback = callback, repeating = repeating, active = true,
			seq = seq }
		function t:Cancel() self.active = false end
		timers[#timers + 1] = t
		return t
	end
end

-- The identity probe's C4:url transfers: the paired bridge answers its
-- config, any other host fails the pinned chain (curl 60) unless told to hang.
local hang_hosts = {}
local function answer_transfers()
	for _, t in ipairs(c4.transfers) do
		if not t.answered then
			t.answered = true
			local host = t.url:match("^https://([^/]+)/")
			if hang_hosts[host] then
				t.hanging = true
			elseif host == SWEEP_BRIDGE then
				t:respond(200, CONFIG)
			else
				t:done(60, "SSL peer certificate or SSH remote key was not OK")
			end
		end
	end
end

-- Move the clock by `ms`, firing every timer that comes due, in order.
local function advance(ms)
	local target = c4.now_ms + ms
	local fired = 0
	while true do
		answer_transfers()
		local live, nxt = {}, nil
		for _, t in ipairs(timers) do
			if t.active then
				live[#live + 1] = t
				if t.due <= target and (not nxt or t.due < nxt.due or (t.due == nxt.due and t.seq < nxt.seq)) then
					nxt = t
				end
			end
		end
		timers = live
		if not nxt then break end
		if nxt.due > c4.now_ms then c4.now_ms = nxt.due end
		if nxt.repeating then nxt.due = nxt.due + nxt.delay else nxt.active = false end
		fired = fired + 1
		assert(fired < 200000, "runaway timers")
		nxt.callback(nxt, 0)
	end
	c4.now_ms = target
	answer_transfers()
end

local function active_timers()
	local n = 0
	for _, t in ipairs(timers) do
		if t.active then n = n + 1 end
	end
	return n
end

-- The fake TCP client (API 14_lua_tcp_client) --------------------------------

local function install_tcp()
	tcp = { hosts = {}, connects = {}, live = 0, max_live = 0, closed = 0, last_start = nil, min_gap = nil }
	c4.CreateTCPClient = function()
		local cl = { cb = {}, state = "new" }
		function cl:OnConnect(fn) self.cb.connect = fn; return self end
		function cl:OnError(fn) self.cb.error = fn; return self end
		function cl:Connect(host, port)
			assert(self.state == "new", "Connect twice on one client")
			self.host, self.port, self.state = host, port, "pending"
			tcp.connects[#tcp.connects + 1] = { host = host, port = port, at = c4.now_ms }
			if tcp.last_start then
				local gap = c4.now_ms - tcp.last_start
				tcp.min_gap = math.min(tcp.min_gap or gap, gap)
			end
			tcp.last_start = c4.now_ms
			tcp.live = tcp.live + 1
			tcp.max_live = math.max(tcp.max_live, tcp.live)
			local kind = tcp.hosts[host]
			if kind == "open" then
				c4:SetTimer(5, function()
					if self.state == "pending" then
						self.state = "open"
						self.cb.connect(self)
					end
				end)
			elseif kind == "refuse" then
				c4:SetTimer(3, function()
					if self.state == "pending" then
						self.state = "closed"
						tcp.live = tcp.live - 1
						self.cb.error(self, 111, "Connection refused")
					end
				end)
			end
			return self
		end
		-- Close cancels a pending connect, which then calls OnError (API 14/_2).
		function cl:Close()
			if self.state == "pending" then
				self.state = "closed"
				tcp.live = tcp.live - 1
				tcp.closed = tcp.closed + 1
				c4:SetTimer(1, function() self.cb.error(self, 125, "Operation canceled") end)
			elseif self.state == "open" then
				self.state = "closed"
				tcp.live = tcp.live - 1
				tcp.closed = tcp.closed + 1
			end
			return self
		end
		return cl
	end
end

-- The fake bridge behind ctx.bridge_request ------------------------------------

local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in pairs(value) do out[k] = copy(v) end
	return out
end

local function chars(s)
	local n = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 128 or b >= 192 then n = n + 1 end
	end
	return n
end

local function new_bridge()
	local b = {
		data = {
			light = {
				{ id = "l1", type = "light", owner = { rid = "d1", rtype = "device" }, metadata = { name = "Desk lamp" } },
				{ id = "l2", type = "light", owner = { rid = "d2", rtype = "device" }, metadata = { name = "Strip left" } },
				{ id = "l3", type = "light", owner = { rid = "d2", rtype = "device" }, metadata = { name = "Strip right" } },
			},
			device = {
				{ id = "d0", type = "device", metadata = { name = "Hue Bridge" }, services = {} },
				{ id = "d1", type = "device", metadata = { name = "Desk lamp" },
					services = { { rid = "l1", rtype = "light" }, { rid = "z1", rtype = "zigbee_connectivity" } } },
				{ id = "d2", type = "device", metadata = { name = "Accent strip" },
					services = { { rid = "l2", rtype = "light" }, { rid = "l3", rtype = "light" } } },
				{ id = "d3", type = "device", metadata = { name = "Hall sensor" },
					services = { { rid = "m1", rtype = "motion" } } },
			},
			scene = {
				{ id = "s1", type = "scene", metadata = { name = "Relax" }, group = { rid = "r1", rtype = "room" } },
				{ id = "s2", type = "scene", metadata = { name = "Read" }, group = { rid = "r1", rtype = "room" } },
				{ id = "s3", type = "scene", metadata = { name = "Bright" }, group = { rid = "r2", rtype = "room" } },
			},
			motion = { { id = "m1", type = "motion", owner = { rid = "d3", rtype = "device" } } },
			motion_area_configuration = { { id = "a1", type = "motion_area_configuration", name = "Hallway",
				group = { rid = "r1", rtype = "room" } } },
		},
		rules = { max_chars = 32, duplicate_scene = "accept", area_names = true, light_follows = true,
			device_follows = false },
		requests = {},
		puts = {},
		delay = 50,
		-- on_put(type, id, name, n) -> nil | "hang" | "apply_hang" | "apply_503" | "503"
		on_put = nil,
		-- down: every request hangs
		down = false,
	}
	function b:find(rtype, id)
		for _, item in ipairs(self.data[rtype] or {}) do
			if item.id == id then return item end
		end
		return nil
	end
	function b:name(rtype, id)
		local item = self:find(rtype, id)
		if not item then return nil end
		if rtype == "motion_area_configuration" then return item.name end
		return item.metadata and item.metadata.name
	end
	function b:set_name(rtype, id, name)
		local item = self:find(rtype, id)
		if rtype == "motion_area_configuration" then
			item.name = name
		else
			item.metadata.name = name
		end
		-- A single-light lamp's light takes its device's name [assumed: T1 settles it].
		if rtype == "device" and self.rules.light_follows then
			local owned = {}
			for _, light in ipairs(self.data.light) do
				if light.owner.rid == id then owned[#owned + 1] = light end
			end
			if #owned == 1 then owned[1].metadata.name = name end
		end
		-- Whether a light's own name carries over to its device [unknown: E10].
		if rtype == "light" and self.rules.device_follows then
			self:find("device", item.owner.rid).metadata.name = name
		end
	end
	local function errors(text)
		return { ok = false, code = 400, err = "HTTP 400", json = { errors = { { description = text } }, data = {} } }
	end
	function b:answer(req)
		local rtype, id = req.path:match("^/clip/v2/resource/([%w_]+)/?([%w%-]*)$")
		if not rtype or not self.data[rtype] then
			return { ok = false, code = 404, err = "HTTP 404", json = { errors = { { description = "not found" } } } }
		end
		if req.method == "GET" then
			if id == "" then
				return { ok = true, code = 200, json = { errors = {}, data = copy(self.data[rtype]) } }
			end
			local item = self:find(rtype, id)
			if not item then return { ok = false, code = 404, err = "HTTP 404", json = { errors = {} } } end
			return { ok = true, code = 200, json = { errors = {}, data = { copy(item) } } }
		end
		assert(req.method == "PUT", "unexpected method " .. tostring(req.method))
		local item = self:find(rtype, id)
		if not item then return { ok = false, code = 404, err = "HTTP 404", json = { errors = {} } } end
		local name = rtype == "motion_area_configuration" and req.body.name or (req.body.metadata and req.body.metadata.name)
		self.puts[#self.puts + 1] = { rtype = rtype, id = id, name = name }
		local scripted = self.on_put and self.on_put(rtype, id, name, #self.puts)
		if scripted == "hang" then return nil end
		if scripted == "503" then return { ok = false, code = 503, err = "HTTP 503", json = { errors = {} } } end
		if scripted == "apply_hang" then self:set_name(rtype, id, name); return nil end
		if scripted == "apply_503" then
			self:set_name(rtype, id, name)
			return { ok = false, code = 503, err = "HTTP 503", json = { errors = {} } }
		end
		if type(name) ~= "string" or chars(name) > self.rules.max_chars then
			return errors("invalid value for metadata.name: at most 32 characters")
		end
		if rtype == "motion_area_configuration" and not self.rules.area_names then
			return errors("body contains invalid properties")
		end
		if rtype == "scene" and self.rules.duplicate_scene == "reject" then
			for _, other in ipairs(self.data.scene) do
				if other.id ~= id and other.group.rid == item.group.rid and other.metadata.name == name then
					return errors("duplicate scene name in group")
				end
			end
		end
		self:set_name(rtype, id, name)
		return { ok = true, code = 200, json = { errors = {}, data = { { rid = id, rtype = rtype } } } }
	end
	function b:request(req, callback)
		assert(req.ip == nil and req.key == nil, "the probe hands bridge_request no address or key")
		self.requests[#self.requests + 1] = { method = req.method, path = req.path, body = req.body, timeout = req.timeout }
		if self.down then return end
		local response = self:answer(req)
		if response == nil then return end
		c4:SetTimer(self.delay, function() callback(response) end)
	end
	return b
end

-- Setup -------------------------------------------------------------------------

local function make_ctx(opts)
	opts = opts or {}
	local state = { ip = opts.ip or BRIDGE_IP, creds = { key = KEY, bridge_id = BRIDGE_ID }, identity_ok = true }
	if opts.unpaired then state.creds = nil end
	ctx = {
		state = state,
		prop = function(name, value) c4:UpdateProperty(name, tostring(value)) end,
		last_action = function(text)
			actions[#actions + 1] = text
			c4:UpdateProperty("Last Action", text)
		end,
		connection = function()
			if state.ip and state.creds then return { ip = state.ip, key = state.creds.key } end
			return nil
		end,
		bridge_request = function(req, callback) return bridge:request(req, callback) end,
	}
	probe12.install(ctx)
	return ctx
end

local function load_probe()
	package.loaded["bridge.probe12"] = nil
	probe12 = require("bridge.probe12")
	probe12.globals = env
	return probe12
end

local function last_action()
	return actions[#actions] or ""
end

local function logged(pattern)
	for _, line in ipairs(lines) do
		if line:find(pattern, 1, true) then return line end
	end
	return nil
end

local function calls_on(name, binding)
	local out = {}
	for _, args in ipairs(c4.calls_to(name)) do
		if binding == nil or args[1] == binding then out[#out + 1] = args end
	end
	return out
end

local real_sink
local saved_constants = {}
local CONSTANTS = { "ONLINE_WAIT_MS", "SSDP_WINDOW_MS", "MDNS_WINDOW_MS", "SWEEP_IN_FLIGHT", "SWEEP_CONNECT_MS",
	"SWEEP_GAP_MS", "SWEEP_CAP_MS", "IDENTITY_WAIT_MS", "IDENTITY_CAP_MS", "DISCOVERY_CAP_MS", "NAMES_TEST_CAP_MS",
	"NAMES_RESTORE_CAP_MS", "NAMES_REQUEST_MS", "NAMES_SETTLE_MS", "NAMES_RESTORE_ROUNDS" }

local function setup(opts)
	opts = opts or {}
	lines, actions, driver_calls, hang_hosts = {}, {}, {}, {}
	real_sink = log.sink
	log.sink = function(line) lines[#lines + 1] = line end
	c4, env = fake.install_c4({})
	install_clock()
	install_tcp()
	c4.GetControllerNetworkAddress = function() return opts.controller or CONTROLLER end
	if opts.port_in_use ~= "absent" then
		c4.PortInUse = function(_, port)
			assert(port == 5353)
			return opts.port_in_use == true
		end
	end
	-- The driver's own network globals, which the probe must pass everything else to.
	env.OnConnectionStatusChanged = function(...) driver_calls[#driver_calls + 1] = { "status", ... } end
	env.ReceivedFromNetwork = function(...) driver_calls[#driver_calls + 1] = { "data", ... } end
	bridge = new_bridge()
	load_probe()
	for _, name in ipairs(CONSTANTS) do saved_constants[name] = probe12[name] end
	make_ctx(opts)
end

local function teardown()
	log.sink = real_sink
	rawset(_G, "Probe12PickerList", nil)
	rawset(_G, "Probe12RoomList", nil)
end

-- The mDNS answer of a Hue bridge to the legacy unicast query: the question
-- echoed, a PTR answer and SRV, TXT and A records, every name after the
-- first written as a compression pointer (RFC 1035 §4.1.4).
local function u16(n) return string.char(math.floor(n / 256), n % 256) end
local function labels(name)
	local out = {}
	for label in name:gmatch("[^%.]+") do out[#out + 1] = string.char(#label) .. label end
	return table.concat(out)
end
local function pointer(offset) return string.char(192 + math.floor(offset / 256), offset % 256) end
local TTL = "\0\0\17\148"
local function ip_bytes(ip)
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	return string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d))
end

local function mdns_answer(opts)
	opts = opts or {}
	local msg = u16(opts.id or 0x4c7e) .. u16(0x8400) .. u16(1) .. u16(1) .. u16(0) .. u16(3)
	local q_at = #msg -- 12: the question's name
	msg = msg .. labels("_hue._tcp.local") .. "\0" .. u16(12) .. u16(1)
	local instance = "Philips Hue - 123ABC"
	local rdata = string.char(#instance) .. instance .. pointer(q_at)
	msg = msg .. pointer(q_at) .. u16(12) .. u16(1) .. TTL .. u16(#rdata)
	local instance_at = #msg
	msg = msg .. rdata
	local srv = u16(0) .. u16(0) .. u16(443) .. labels("Philips-hue") .. pointer(q_at + 10) -- "local"
	msg = msg .. pointer(instance_at) .. u16(33) .. u16(0x8001) .. TTL .. u16(#srv)
	local host_at = #msg + 6
	msg = msg .. srv
	local id_item = "bridgeid=" .. (opts.bridge_id or BRIDGE_ID)
	local txt = string.char(#id_item) .. id_item .. string.char(#"modelid=BSB003") .. "modelid=BSB003"
	msg = msg .. pointer(instance_at) .. u16(16) .. u16(0x8001) .. TTL .. u16(#txt) .. txt
	msg = msg .. pointer(host_at) .. u16(1) .. u16(0x8001) .. TTL .. u16(4) .. ip_bytes(opts.ip or BRIDGE_IP)
	return msg
end

local SSDP_ANSWER = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=100\r\nEXT:\r\nLOCATION: http://" .. BRIDGE_IP
	.. ":80/description.xml\r\nSERVER: Hue/1.0 UPnP/1.0 IpBridge/1.68.0\r\nhue-bridgeid: 001788FFFE123ABC\r\n"
	.. "ST: upnp:rootdevice\r\nUSN: uuid:2f402f80-da50-11e1-9b23-001788fffe123abc::upnp:rootdevice\r\n\r\n"

-- The specs -------------------------------------------------------------------------

describe("bridge/probe12.lua (#334, the 1.2 probe)", function()
	after_each(function()
		if probe12 then
			for name, value in pairs(saved_constants) do probe12[name] = value end
		end
		teardown()
	end)

	describe("binding ids", function()
		before_each(function() setup() end)

		it("takes 6004 to 6009 only: never the stream's 6001, never netcheck's 6100 to 6999", function()
			local netstream = require("bridge.netstream")
			local netcheck = require("bridge.netcheck")
			local seen = {}
			for name, id in pairs(probe12.BINDINGS) do
				assert.is_nil(seen[id], name .. " shares binding " .. id)
				seen[id] = name
				assert.is_true(id >= probe12.BINDING_FIRST and id <= probe12.BINDING_LAST, name)
				assert.is_true(probe12.owns(id))
			end
			assert.equal(6004, probe12.BINDING_FIRST)
			assert.equal(6009, probe12.BINDING_LAST)
			assert.is_true(probe12.BINDING_FIRST > netstream.BINDING)
			assert.is_true(probe12.BINDING_LAST < netcheck.FIRST_ID)
			assert.is_false(probe12.owns(netstream.BINDING))
			assert.is_false(probe12.owns(netcheck.FIRST_ID))
			assert.is_false(probe12.owns(6003))
			assert.is_false(probe12.owns(6010))
		end)

		it("creates each once per run of the driver's Lua, never clears one, and creates again after a reload", function()
			probe12.discovery({ Mode = "udp" })
			advance(30000)
			local first = {}
			for _, args in ipairs(calls_on("CreateNetworkConnection")) do
				first[#first + 1] = args[1]
				assert.is_true(args[1] >= 6004 and args[1] <= 6009, "binding " .. tostring(args[1]))
			end
			table.sort(first)
			assert.same({ 6004, 6005, 6006, 6007 }, first)
			assert.same({}, calls_on("SetBindingAddress"), "never cleared, never moved")
			for _, args in ipairs(calls_on("NetConnect")) do
				assert.is_true(args[1] >= 6004 and args[1] <= 6009)
			end

			-- Again in the same run: connected again, not created again.
			local connects = #calls_on("NetConnect", 6004)
			probe12.discovery({ Mode = "mdns" })
			advance(10000)
			assert.equal(4, #calls_on("CreateNetworkConnection"))
			assert.equal(connects + 1, #calls_on("NetConnect", 6004))
			assert.truthy(logged("probe12 mdns: binding 6004 connected again to 224.0.0.251:5353 as UDP"))

			-- After a dev loop reload (a new module): created again (probe P6).
			load_probe()
			make_ctx()
			probe12.discovery({ Mode = "mdns" })
			advance(10000)
			assert.equal(2, #calls_on("CreateNetworkConnection", 6004))
			assert.same({}, calls_on("SetBindingAddress"))
		end)
	end)

	describe("Probe Discovery", function()
		it("logs the environment: the controller, port 5353, Director, the TCP client, the binding addresses", function()
			setup()
			probe12.discovery({ Mode = "env" })
			advance(100)
			local line = logged("probe12 env:")
			assert.truthy(line)
			assert.truthy(line:find("controller " .. CONTROLLER, 1, true))
			assert.truthy(line:find("bridge " .. BRIDGE_IP .. " (same /24: no)", 1, true))
			assert.truthy(line:find("PortInUse(5353) false", 1, true))
			assert.truthy(line:find("Director 3.4.2.746094", 1, true))
			assert.truthy(line:find("C4:CreateTCPClient yes", 1, true))
			assert.truthy(line:find("6004=nil", 1, true))
			assert.truthy(line:find("paired id " .. BRIDGE_ID, 1, true))
			assert.same({}, calls_on("CreateNetworkConnection"))
			assert.truthy(last_action():find("^Probe Discovery %(env%) in 0 s: controller 192%.0%.2%.7, 5353 free"))
			assert.is_false(probe12.running().discovery)
		end)

		it("mDNS: the legacy query on 6004 at ONLINE, the answer parsed with every argument, then disconnected", function()
			setup()
			probe12.discovery({ Mode = "mdns" })
			advance(5)
			assert.same({ { 6004, "224.0.0.251" } }, calls_on("CreateNetworkConnection"))
			local connect = calls_on("NetConnect", 6004)
			assert.equal(1, #connect)
			assert.same({ 6004, 5353, "UDP" }, { connect[1][1], connect[1][2], connect[1][3] })
			assert.same({}, calls_on("SendToNetwork"), "nothing before ONLINE")
			assert.is_true(probe12.running().wrapped)

			c4.net_status(6004, 5353, "ONLINE")
			local sent = calls_on("SendToNetwork", 6004)
			assert.equal(1, #sent)
			assert.equal(5353, sent[1][2])
			local query = string.char(0x4c, 0x7e, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0) .. "\4_hue\4_tcp\5local\0"
				.. string.char(0, 12, 0, 1)
			assert.equal(query, sent[1][3])
			assert.equal(query, probe12.mdns_query(0x4c7e, false))

			-- Director 4.x passes the sender as a fourth argument.
			advance(40)
			env.ReceivedFromNetwork(6004, 5353, mdns_answer(), BRIDGE_IP)
			local line = logged("probe12 mdns: answer 1 after 40 ms")
			assert.truthy(line, table.concat(lines, "\n"))
			assert.truthy(line:find("4 arguments, from " .. BRIDGE_IP, 1, true))
			assert.truthy(line:find("PTR Philips Hue - 123ABC._hue._tcp.local", 1, true))
			assert.truthy(line:find("SRV Philips-hue.local:443", 1, true))
			assert.truthy(line:find("TXT bridgeid/modelid " .. BRIDGE_ID .. "/BSB003", 1, true))
			assert.truthy(line:find("A " .. BRIDGE_IP, 1, true))
			assert.truthy(logged("probe12 mdns: answer 1 hex 1/1: 4c7e8400"))
			assert.same({}, driver_calls, "the probe's own binding never reaches the driver")

			advance(3000)
			assert.equal(1, #calls_on("NetDisconnect", 6004) - 1, "disconnected at the end of the window")
			assert.truthy(last_action():find("mdns 1 answer (1 Hue, the paired id, A record, from given)", 1, true),
				last_action())
			assert.is_false(probe12.running().discovery)
			assert.is_false(probe12.running().wrapped)
		end)

		it("passes every other binding to the driver's own functions, all arguments, and restores them after", function()
			setup()
			local driver_status, driver_data = env.OnConnectionStatusChanged, env.ReceivedFromNetwork
			probe12.discovery({ Mode = "mdns" })
			advance(5)
			assert.are_not.equal(driver_status, env.OnConnectionStatusChanged)
			c4.net_status(6001, 443, "ONLINE")
			env.ReceivedFromNetwork(6001, 443, "HTTP/1.1 200 OK", BRIDGE_IP)
			env.ReceivedFromNetwork(6100, 443, "x")
			assert.same({ { "status", 6001, 443, "ONLINE" }, { "data", 6001, 443, "HTTP/1.1 200 OK", BRIDGE_IP },
				{ "data", 6100, 443, "x" } }, driver_calls)
			advance(10000)
			assert.equal(driver_status, env.OnConnectionStatusChanged)
			assert.equal(driver_data, env.ReceivedFromNetwork)
		end)

		it("leaves a global alone that a reload replaced meanwhile", function()
			setup()
			probe12.discovery({ Mode = "mdns" })
			advance(5)
			local reloaded = function() end
			env.ReceivedFromNetwork = reloaded
			advance(10000)
			assert.equal(reloaded, env.ReceivedFromNetwork)
		end)

		it("SSDP: sent without ONLINE after the wait, an answer of three arguments counted with its bridge id", function()
			setup()
			probe12.discovery({ Mode = "ssdp" })
			advance(5)
			assert.same({ { 6005, "239.255.255.250" } }, calls_on("CreateNetworkConnection"))
			advance(1490) -- the connection opened at 1 ms
			assert.same({}, calls_on("SendToNetwork"))
			advance(10)
			local sent = calls_on("SendToNetwork", 6005)
			assert.equal(1, #sent)
			assert.equal(1900, sent[1][2])
			assert.truthy(sent[1][3]:find("^M%-SEARCH %* HTTP/1%.1\r\n"))
			assert.truthy(sent[1][3]:find("ST: ssdp:all\r\n\r\n$"))
			assert.truthy(logged("no ONLINE within 1500 ms, sent anyway"))
			c4.net_receive(6005, 1900, SSDP_ANSWER)
			local line = logged("probe12 ssdp: answer 1")
			assert.truthy(line)
			assert.truthy(line:find("3 arguments, from -", 1, true))
			assert.truthy(line:find("LOCATION host " .. BRIDGE_IP, 1, true))
			assert.truthy(line:find("hue-bridgeid 001788FFFE123ABC", 1, true))
			advance(5000)
			assert.truthy(last_action():find("ssdp 1 answer (1 Hue, the paired id, no from, no ONLINE)", 1, true),
				last_action())
		end)

		it("counts answers past the cap without parsing them, and late ones after the window", function()
			setup()
			probe12.discovery({ Mode = "mdns" })
			advance(5)
			c4.net_status(6004, 5353, "ONLINE")
			for _ = 1, probe12.MAX_PACKETS + 5 do
				c4.net_receive(6004, 5353, mdns_answer())
			end
			advance(3000)
			c4.net_receive(6004, 5353, mdns_answer())
			local parsed = 0
			for _, line in ipairs(lines) do
				if line:find("^probe12 mdns: answer %d+ after") then parsed = parsed + 1 end
			end
			assert.equal(probe12.MAX_PACKETS, parsed)
			assert.truthy(logged("more than 10 answers; the rest are only counted"))
			assert.truthy(logged("window closed: 15 answer(s) (10 for Hue)"), "Hue among the parsed")
			assert.truthy(logged("probe12 mdns: an answer after the window closed (counted, not parsed)"))
		end)

		it("mdns5353: from port 5353 with MIRROR_UDP_PORT and the QU bit when 5353 is free", function()
			setup({ port_in_use = false })
			probe12.discovery({ Mode = "mdns5353" })
			advance(5)
			assert.same({ { 6006, "224.0.0.251" } }, calls_on("CreateNetworkConnection"))
			local options = calls_on("NetPortOptions", 6006)
			assert.equal(1, #options)
			assert.same({ 6006, 5353, "UDP", { MIRROR_UDP_PORT = true } }, options[1])
			c4.net_status(6006, 5353, "ONLINE")
			local query = calls_on("SendToNetwork", 6006)[1][3]
			assert.equal(string.char(0, 0), query:sub(1, 2), "id 0 from port 5353")
			assert.equal(string.char(0, 12, 0x80, 1), query:sub(-4), "PTR, class IN with the QU bit")
		end)

		it("mdns5353: skipped when 5353 is in use, and when PortInUse is not there", function()
			setup({ port_in_use = true })
			probe12.discovery({ Mode = "mdns5353" })
			advance(100)
			assert.same({}, calls_on("CreateNetworkConnection"))
			assert.truthy(last_action():find("mdns5353 skipped (5353 is in use on the controller)", 1, true))
			teardown()

			setup({ port_in_use = "absent" })
			probe12.discovery({ Mode = "mdns5353" })
			advance(100)
			assert.same({}, calls_on("CreateNetworkConnection"))
			assert.truthy(last_action():find("mdns5353 skipped (PortInUse(5353) gave no answer)", 1, true))
		end)

		it("multicast: the undocumented MULTICAST type on 6007", function()
			setup()
			probe12.discovery({ Mode = "multicast" })
			advance(5)
			assert.same({ 6007, 5353, "MULTICAST" }, { unpack(calls_on("NetConnect", 6007)[1], 1, 3) })
			advance(4600)
			assert.truthy(last_action():find("multicast 0 answers (no ONLINE)", 1, true), last_action())
		end)

		it("all the UDP probes in about 15 s, one after the other (20 s when no ONLINE comes)", function()
			setup()
			probe12.discovery({ Mode = "udp" })
			advance(30000)
			assert.truthy(last_action():find("^Probe Discovery %(udp%) in 20 s: "), last_action())
			for _, name in ipairs({ "ssdp 0 answers", "mdns 0 answers", "mdns5353 0 answers", "multicast 0 answers" }) do
				assert.truthy(last_action():find(name, 1, true), name)
			end
			assert.equal(0, active_timers())
		end)

		it("refuses a second run, and an unknown Mode", function()
			setup()
			probe12.discovery({ Mode = "mdns" })
			probe12.discovery({ Mode = "mdns" })
			assert.equal("Probe Discovery: already running; wait for its summary", last_action())
			advance(10000)
			probe12.discovery({ Mode = "everything" })
			assert.truthy(last_action():find("^Probe Discovery: unknown Mode everything"))
		end)

		it("stops at its overall cap: windows closed, globals restored, nothing left running", function()
			setup()
			probe12.DISCOVERY_CAP_MS = 4000
			probe12.discovery({ Mode = "all" })
			advance(4000)
			assert.truthy(last_action():find("stopped at the 4 s cap", 1, true), last_action())
			assert.is_false(probe12.running().discovery)
			assert.is_false(probe12.running().wrapped)
			assert.equal(#calls_on("NetConnect", 6005), #calls_on("NetDisconnect", 6005) - 1)
			local creates, connects = #calls_on("CreateNetworkConnection"), #tcp.connects
			advance(200000)
			assert.equal(creates, #calls_on("CreateNetworkConnection"))
			assert.equal(connects, #tcp.connects)
			assert.equal(0, active_timers())
		end)
	end)

	describe("Probe Discovery: the sweep", function()
		local function sweep_setup(opts)
			setup(opts)
			ctx.state.ip = SWEEP_BRIDGE
			tcp.hosts[SWEEP_BRIDGE] = "open"
			tcp.hosts[NAS] = "open"
			tcp.hosts[PRINTER] = "refuse"
		end

		it("sweeps the controller's /24 outward from it, four at most, then checks identity on hosts that accept", function()
			sweep_setup()
			probe12.discovery({ Mode = "sweep" })
			advance(200000)
			assert.equal(253, #tcp.connects)
			local seen = {}
			for _, connect in ipairs(tcp.connects) do
				assert.equal(443, connect.port)
				local last = tonumber(connect.host:match("^192%.0%.2%.(%d+)$"))
				assert.truthy(last and last >= 1 and last <= 254, connect.host)
				assert.is_nil(seen[connect.host], connect.host .. " twice")
				seen[connect.host] = true
			end
			assert.is_nil(seen[CONTROLLER], "never the controller itself")
			assert.same({ "192.0.2.8", "192.0.2.6", "192.0.2.9", "192.0.2.5" },
				{ tcp.connects[1].host, tcp.connects[2].host, tcp.connects[3].host, tcp.connects[4].host })
			assert.is_true(tcp.max_live <= 4, "at most four at once, saw " .. tcp.max_live)
			assert.equal(4, tcp.max_live)
			assert.is_true(tcp.min_gap >= probe12.SWEEP_GAP_MS, "starts at least 125 ms apart")
			assert.equal(0, tcp.live, "every connection closed")

			-- Stage B: pairing's unkeyed probe, only on the two that accepted.
			local urls = {}
			for _, t in ipairs(c4.transfers) do
				urls[#urls + 1] = t.url
				assert.is_nil(t.headers["hue-application-key"], "no key to any host")
			end
			table.sort(urls)
			assert.same({ "https://" .. NAS .. "/api/0/config", "https://" .. SWEEP_BRIDGE .. "/api/0/config" }, urls)
			assert.truthy(logged("probe12 sweep: identity of " .. SWEEP_BRIDGE .. ": Hue bridge " .. BRIDGE_ID
				.. ", BSB003"))
			assert.truthy(logged("probe12 sweep: identity of " .. NAS .. ": not a Hue bridge"))
			local summary = logged("probe12 sweep: 192.0.2.x: 253 of 253 addresses")
			assert.truthy(summary)
			assert.truthy(summary:find("2 open on 443", 1, true))
			assert.truthy(summary:find("1 errors (111 Connection refused x1)", 1, true), summary)
			assert.truthy(summary:find("250 with no answer within 1500 ms", 1, true))
			local seconds = tonumber(last_action():match("sweep 192%.0%.2%.x 253/253 in (%d+) s"))
			assert.truthy(seconds, last_action())
			assert.is_true(seconds <= probe12.SWEEP_CAP_MS / 1000, "within its cap")
			assert.truthy(last_action():find("443 open on 2, paired bridge at " .. SWEEP_BRIDGE, 1, true))
			assert.equal(0, active_timers())
		end)

		it("never more connects than InFlight, and never more than four whatever it asks", function()
			sweep_setup()
			probe12.discovery({ Mode = "sweep", InFlight = "2" })
			advance(300000)
			assert.equal(2, tcp.max_live)
			teardown()

			sweep_setup()
			probe12.discovery({ Mode = "sweep", InFlight = "9" })
			advance(200000)
			assert.equal(4, tcp.max_live)
		end)

		it("stops the TCP stage at its cap, closing every pending connect, and still checks what accepted", function()
			sweep_setup()
			probe12.SWEEP_CAP_MS = 10000
			probe12.discovery({ Mode = "sweep" })
			advance(200000)
			assert.is_true(#tcp.connects < 253)
			assert.equal(0, tcp.live)
			assert.truthy(logged("stopped (the cap)"))
			assert.truthy(last_action():find("sweep 192.0.2.x " .. #tcp.connects .. "/253", 1, true), last_action())
			assert.is_false(probe12.running().discovery)
			assert.equal(0, active_timers())
		end)

		it("bounds the identity stage per host and in all", function()
			sweep_setup()
			hang_hosts[NAS] = true
			tcp.hosts[SWEEP_BRIDGE] = nil
			probe12.discovery({ Mode = "sweep" })
			advance(200000)
			assert.truthy(logged("probe12 sweep: identity of " .. NAS .. ": not a Hue bridge: no answer within 20000 ms"))
			assert.truthy(last_action():find("443 open on 1, paired bridge not found", 1, true), last_action())
			for _, t in ipairs(c4.transfers) do
				if t.hanging then assert.is_true(t.cancelled, "the hung transfer cancelled") end
			end
		end)

		it("takes a Subnet param, skips a bad one, and needs C4:CreateTCPClient", function()
			sweep_setup()
			probe12.discovery({ Mode = "sweep", Subnet = "198.51.100" })
			advance(200000)
			assert.equal(254, #tcp.connects, "nothing to skip outside the controller's /24")
			assert.equal("198.51.100.1", tcp.connects[1].host)
			assert.equal("198.51.100.2", tcp.connects[2].host)
			teardown()

			for _, bad in ipairs({ "300.1.1", "127.0.0", "192.0.2.0.1", "x" }) do
				sweep_setup()
				probe12.discovery({ Mode = "sweep", Subnet = bad })
				advance(1000)
				assert.equal(0, #tcp.connects, bad)
				assert.truthy(last_action():find("sweep skipped", 1, true), bad)
				teardown()
			end

			sweep_setup()
			c4.CreateTCPClient = nil
			probe12.discovery({ Mode = "sweep" })
			advance(1000)
			assert.truthy(last_action():find("sweep skipped (no C4:CreateTCPClient)", 1, true))
		end)
	end)

	describe("the DNS parser", function()
		before_each(function() setup() end)

		it("follows compression pointers and reads PTR, SRV, TXT and A", function()
			local p = probe12.parse_dns(mdns_answer({ ip = "192.0.2.61", bridge_id = "001788fffe456def" }))
			assert.equal(0x4c7e, p.id)
			assert.equal(4, p.records)
			assert.same({ "PTR", "SRV", "TXT", "A" }, p.types)
			assert.equal("Philips Hue - 123ABC._hue._tcp.local", p.ptr[1].target)
			assert.same({ name = "Philips Hue - 123ABC._hue._tcp.local", port = 443, target = "Philips-hue.local" },
				p.srv[1])
			assert.equal("001788fffe456def", p.txt[1].kv.bridgeid)
			assert.equal("BSB003", p.txt[1].kv.modelid)
			assert.same({ name = "Philips-hue.local", ip = "192.0.2.61" }, p.a[1])
		end)

		it("raises on a truncated packet and on a pointer loop", function()
			local packet = mdns_answer()
			assert.has_error(function() probe12.parse_dns(packet:sub(1, 40)) end)
			local loop = u16(1) .. u16(0) .. u16(0) .. u16(1) .. u16(0) .. u16(0) .. pointer(12) .. u16(1) .. u16(1)
				.. TTL .. u16(0)
			assert.has_error(function() probe12.parse_dns(loop) end, "a pointer loop")
		end)

		it("logs an answer it cannot parse, with what a pattern finds", function()
			probe12.discovery({ Mode = "mdns" })
			advance(5)
			c4.net_status(6004, 5353, "ONLINE")
			c4.net_receive(6004, 5353, "junk bridgeid=001788fffe123abc")
			assert.truthy(logged("not parsed"))
			assert.truthy(logged("bridgeid=001788fffe123abc"))
		end)
	end)

	describe("Probe Names", function()
		before_each(function() setup() end)

		local function names_of_everything()
			return {
				d1 = bridge:name("device", "d1"), l1 = bridge:name("light", "l1"), s2 = bridge:name("scene", "s2"),
				d3 = bridge:name("device", "d3"), a1 = bridge:name("motion_area_configuration", "a1"),
				d2 = bridge:name("device", "d2"), s1 = bridge:name("scene", "s1"),
			}
		end
		local ORIGINAL = { d1 = "Desk lamp", l1 = "Desk lamp", s2 = "Read", d3 = "Hall sensor", a1 = "Hallway",
			d2 = "Accent strip", s1 = "Relax" }

		local function puts()
			local out = {}
			for _, p in ipairs(bridge.puts) do out[#out + 1] = p.rtype .. "/" .. p.id .. "=" .. tostring(p.name) end
			return out
		end

		local NAME_33 = "C4 PROBE 33 characters xxxxxxxxxx"
		local E_32 = string.rep("\195\169", 32)

		it("renames a light's device, a scene, a sensor and an area and back, with Hue's answer to each", function()
			assert.equal(33, #NAME_33)
			probe12.names({})
			advance(120000)
			assert.same({
				"device/d1=C4 PROBE light", "device/d1=" .. NAME_33,
				"light/l1=C4 PROBE light name", "light/l1=Desk lamp", "device/d1=Desk lamp",
				"scene/s2=C4 PROBE scene", "scene/s2=Relax", "scene/s2=" .. NAME_33, "scene/s2=" .. E_32, "scene/s2=Read",
				"device/d3=C4 PROBE sensor", "device/d3=Hall sensor",
				"motion_area_configuration/a1=C4 PROBE area", "motion_area_configuration/a1=Hallway",
			}, puts())
			assert.same(ORIGINAL, names_of_everything())
			local text = last_action()
			for _, part in ipairs({ "light device 200 (light name followed)", "light device 33 characters 400",
				"light's own name 200 (device name did not follow)",
				"scene 200", "scene duplicate in its group 200", "scene 33 characters 400", "scene 32 \195\169 200",
				"sensor device 200", "MotionAware area 200", "all 5 name(s) restored and read back" }) do
				assert.truthy(text:find(part, 1, true), part .. " in " .. text)
			end
			assert.truthy(logged("probe12 names: light device 33 characters: PUT d1 \"" .. NAME_33
				.. "\" (33 characters, 33 bytes): HTTP 400 'invalid value for metadata.name: at most 32 characters'"))
			assert.truthy(logged("probe12 names: scene 32 \195\169: Hue holds \"" .. E_32 .. "\" (32 characters, 64 bytes)"))
			assert.is_nil(c4.persist[probe12.STORE], "the restore list is gone once all is read back")
			for _, line in ipairs(lines) do
				assert.is_nil(line:find(KEY, 1, true), "no line carries the key")
				assert.is_nil(line:find("\n", 1, true), "one line per log line")
			end
			for _, req in ipairs(bridge.requests) do
				assert.equal(probe12.NAMES_REQUEST_TIMEOUT_S, req.timeout)
				assert.truthy(req.path:find("^/clip/v2/resource/"))
			end
			assert.is_false(probe12.running().names)
			assert.equal(0, active_timers())
		end)

		it("reports Hue's refusals: a duplicate scene name, an area name", function()
			bridge.rules.duplicate_scene = "reject"
			bridge.rules.area_names = false
			bridge.rules.light_follows = false
			probe12.names({})
			advance(120000)
			local text = last_action()
			assert.truthy(text:find("scene duplicate in its group 400", 1, true), text)
			assert.truthy(text:find("MotionAware area 400", 1, true), text)
			assert.truthy(text:find("light device 200 (light name did not follow)", 1, true), text)
			assert.truthy(logged("HTTP 400 'duplicate scene name in group'"))
			assert.truthy(logged("HTTP 400 'body contains invalid properties'"))
			assert.same(ORIGINAL, names_of_everything())
		end)

		it("reads both back when a light's own name carries over to its device and the other way round", function()
			bridge.rules.device_follows = true
			probe12.names({ Scene = "skip", Sensor = "skip", Area = "skip" })
			advance(120000)
			local text = last_action()
			assert.truthy(text:find("light device 200 (light name followed)", 1, true), text)
			assert.truthy(text:find("light's own name 200 (device name followed)", 1, true), text)
			assert.truthy(text:find("all 2 name(s) restored and read back", 1, true), text)
			assert.equal("Desk lamp", bridge:name("device", "d1"))
			assert.equal("Desk lamp", bridge:name("light", "l1"))
		end)

		it("restores after a failing PUT: a test that applied and answered 503, a put-back that failed", function()
			local failed_back = false
			bridge.on_put = function(rtype, id, name)
				if rtype == "scene" and id == "s2" and name == "Relax" then return "apply_503" end
				if rtype == "scene" and id == "s2" and name == "Read" and not failed_back then
					failed_back = true
					return "503"
				end
				return nil
			end
			probe12.names({})
			advance(120000)
			assert.same(ORIGINAL, names_of_everything())
			assert.truthy(last_action():find("scene duplicate in its group 503", 1, true), last_action())
			assert.truthy(last_action():find("restored and read back", 1, true), last_action())
			assert.truthy(logged("probe12 names: read back scene: \"" .. E_32))
			assert.truthy(logged("probe12 names: restore scene s2 to \"Read\""))
			assert.is_nil(c4.persist[probe12.STORE])
		end)

		it("restores after a timeout: a rename that applied and never answered", function()
			bridge.on_put = function(rtype, id, name)
				if rtype == "device" and id == "d3" and name == "C4 PROBE sensor" then return "apply_hang" end
				return nil
			end
			probe12.names({})
			advance(120000)
			assert.same(ORIGINAL, names_of_everything())
			assert.truthy(last_action():find("sensor device no answer", 1, true), last_action())
			assert.truthy(last_action():find("all 5 name(s) restored and read back", 1, true), last_action())
		end)

		it("goes straight to the restore at the test cap, dropping the request in flight", function()
			probe12.NAMES_TEST_CAP_MS = 4000
			bridge.on_put = function(rtype, _, name)
				if rtype == "scene" and name == "C4 PROBE scene" then return "apply_hang" end
				return nil
			end
			probe12.names({})
			advance(120000)
			assert.truthy(logged("probe12 names: the 4 s test cap; restoring"))
			assert.same(ORIGINAL, names_of_everything())
			assert.truthy(last_action():find("restored and read back", 1, true), last_action())
			local after_scene = false
			for _, p in ipairs(puts()) do
				if p == "scene/s2=Relax" or p == "device/d3=C4 PROBE sensor" then after_scene = true end
			end
			assert.is_false(after_scene, "no test after the cap")
		end)

		it("says NOT RESTORED when the bridge will not take the name back, keeps the list, and restores at the next run",
			function()
			bridge.on_put = function(rtype, id, name)
				if rtype == "scene" and id == "s2" and name == "Read" then return "503" end
				return nil
			end
			probe12.names({ Light = "skip", Sensor = "skip", Area = "skip" })
			advance(120000)
			assert.equal(E_32, bridge:name("scene", "s2"), "the last test name stuck")
			local text = last_action()
			assert.truthy(text:find("NOT RESTORED: scene s2 should be \"Read\"", 1, true), text)
			assert.truthy(text:find("run Probe Names Restore", 1, true), text)
			assert.truthy(c4.persist[probe12.STORE], "the restore list stays")
			assert.is_false(probe12.running().names)

			-- The next Probe Names restores first and tests nothing.
			bridge.on_put = nil
			local before = #bridge.puts
			probe12.names({})
			advance(120000)
			assert.equal("Read", bridge:name("scene", "s2"))
			assert.same({ "scene/s2=Read" }, { unpack(puts(), before + 1) })
			assert.truthy(last_action():find("an earlier run had left names to restore: run Probe Names again", 1, true))
			assert.is_nil(c4.persist[probe12.STORE])
			probe12.names_restore()
			assert.equal("Probe Names Restore: nothing to restore", last_action())
		end)

		it("Probe Names Restore puts back what an interrupted run persisted, after a Director restart", function()
			bridge.on_put = function(rtype, _, name)
				if rtype == "device" and name == "C4 PROBE light" then return "apply_hang" end
				return nil
			end
			probe12.names({})
			advance(3000)
			assert.equal("C4 PROBE light", bridge:name("device", "d1"))
			-- Director restarts: every timer gone, the persisted list kept, the module loaded anew.
			for _, t in ipairs(timers) do t.active = false end
			load_probe()
			make_ctx()
			bridge.on_put = nil
			probe12.names_restore()
			advance(120000)
			assert.same(ORIGINAL, names_of_everything())
			assert.truthy(last_action():find("^Probe Names Restore: nothing tested; all %d name%(s%) restored and read back"),
				last_action())
			assert.is_nil(c4.persist[probe12.STORE])
		end)

		it("says NOT RESTORED at the restore cap when the bridge stops answering", function()
			probe12.NAMES_RESTORE_CAP_MS = 30000
			bridge.on_put = function(rtype, _, name)
				if rtype == "scene" and name == "C4 PROBE scene" then
					bridge.down = true
					return "apply_hang"
				end
				return nil
			end
			probe12.names({ Light = "skip" })
			advance(200000)
			local text = last_action()
			assert.truthy(text:find("NOT RESTORED: the restore did not finish within 30 s", 1, true), text)
			assert.truthy(text:find("scene s2 should be \"Read\"", 1, true), text)
			assert.truthy(c4.persist[probe12.STORE])
			assert.equal(0, active_timers())
		end)

		it("takes its targets as parameters, a sensor by its motion service too, and skips what it is told", function()
			probe12.names({ Light = "l2", Scene = "s3", Sensor = "m1", Area = "skip" })
			advance(120000)
			local got = puts()
			assert.same({ "device/d2=C4 PROBE light", "device/d2=" .. NAME_33,
				"light/l2=C4 PROBE light name", "light/l2=Strip left", "device/d2=Accent strip",
				"scene/s3=C4 PROBE scene", "scene/s3=" .. NAME_33, "scene/s3=" .. E_32, "scene/s3=Bright",
				"device/d3=C4 PROBE sensor", "device/d3=Hall sensor" }, got)
			assert.truthy(logged("probe12 names: target light device d2"))
			assert.equal("Accent strip", bridge:name("device", "d2"))
			assert.equal("Strip left", bridge:name("light", "l2"))
			assert.truthy(last_action():find("restored and read back", 1, true))
		end)

		it("refuses an unknown target, and sends nothing", function()
			probe12.names({ Scene = "nope" })
			advance(10000)
			assert.truthy(last_action():find("nothing sent: no scene nope", 1, true), last_action())
			assert.same({}, bridge.puts)
		end)

		it("refuses a target whose name already carries the probe's mark", function()
			bridge:set_name("device", "d3", "C4 PROBE sensor")
			probe12.names({})
			advance(10000)
			assert.truthy(last_action():find('sensor device d3 is already called "C4 PROBE sensor"', 1, true),
				last_action())
			assert.same({}, bridge.puts)
		end)

		it("refuses while unpaired, while the key is rejected, after a failed TLS check, before the identity check",
			function()
			local cases = {
				{ function() ctx.state.creds = nil end, "not paired" },
				{ function() ctx.state.key_rejected = 403 end, "the bridge rejected the key (HTTP 403)" },
				{ function() ctx.state.tls_verdict = "not_pinned" end, "the TLS check failed" },
				{ function() ctx.state.identity_ok = nil end, "the bridge identity is not verified yet" },
			}
			for _, case in ipairs(cases) do
				make_ctx()
				case[1]()
				probe12.names({})
				assert.equal("Probe Names refused: " .. case[2] .. "; nothing was sent", last_action())
				probe12.names_restore()
				assert.equal("Probe Names Restore refused: " .. case[2] .. "; nothing was sent", last_action())
			end
			advance(10000)
			assert.same({}, bridge.requests)
		end)

		it("refuses a second run while one is in progress", function()
			probe12.names({})
			probe12.names({})
			assert.equal("Probe Names: already running; wait for its summary", last_action())
			advance(120000)
			assert.truthy(last_action():find("restored and read back", 1, true))
		end)

		it("stops before any write when the bridge does not answer the reads", function()
			bridge.down = true
			probe12.names({})
			advance(200000)
			assert.truthy(last_action():find("nothing sent", 1, true), last_action())
			assert.same({}, bridge.puts)
			assert.is_nil(c4.persist[probe12.STORE])
		end)
	end)

	describe("the picker test", function()
		before_each(function() setup() end)

		it("defines the two global list functions Composer calls by name", function()
			assert.equal(probe12.picker_list, rawget(_G, "Probe12PickerList"))
			assert.equal(probe12.room_list, rawget(_G, "Probe12RoomList"))
		end)

		it("answers about 220 entries in folders, every value unique, with Back values", function()
			local root, back = probe12.picker_list()
			assert.is_nil(back)
			assert.equal(8, #root)
			local values, leaves, folders = {}, 0, 0
			local function walk(list, depth)
				for _, entry in ipairs(list) do
					assert.is_string(entry.text)
					assert.is_string(entry.value)
					assert.is_nil(values[entry.value], entry.value .. " twice")
					values[entry.value] = true
					if entry.folder then
						folders = folders + 1
						local sub, sub_back = probe12.picker_list(entry.value, nil)
						assert.equal(depth == 1 and "" or "f:scenes", sub_back, entry.value)
						walk(sub, depth + 1)
					else
						leaves = leaves + 1
					end
				end
			end
			walk(root, 1)
			-- 210 entries and 10 selectable room folders: 220 picks, plus the
			-- note of the async folder filled at once.
			assert.equal(17, folders)
			assert.equal(211, leaves)
			local scenes = probe12.picker_list("f:scenes")
			assert.is_true(scenes[1].folder and scenes[1].selectable)
			local room = probe12.picker_list("f:scenes:01")
			assert.equal("scenes-of:01", room[1].value)
			assert.equal(11, #room)
		end)

		it("fills the async folder through done after a while, or at once without done", function()
			local got
			local list = probe12.picker_list("f:async", function(l, b) got = { l, b } end)
			assert.is_nil(list)
			assert.is_nil(got)
			advance(probe12.ASYNC_MS)
			assert.equal(5, #got[1])
			assert.equal("", got[2])
			local now = probe12.picker_list("f:async", nil)
			assert.equal(6, #now)
			assert.equal("async:none", now[1].value)
			assert.truthy(logged("Probe12PickerList called with 2 argument(s): \"f:async\", function"))
		end)

		it("logs what Composer sends, byte for byte, and what each value stands for", function()
			probe12.picker_action({ What = "scene:03:05", Room = "c4room:b" })
			assert.equal('Picker test: Room = "c4room:b" (Room B); What = "scene:03:05" (scene 05 of room 03)', last_action())
			assert.truthy(logged('probe12 picker: param "What" (string, 11 bytes) = "scene:03:05"'))

			probe12.picker_action({ What = "f:scenes:04" })
			assert.truthy(last_action():find("the folder of room 04 (a selectable folder: all its scenes)", 1, true))

			probe12.picker_action({ What = "light:01,light:02" })
			assert.truthy(last_action():find("2 values? light 01 | light 02", 1, true), last_action())

			probe12.picker_action({ What = "edge:utf8-\195\169" })
			assert.truthy(logged("hex 656467653a757466382dc3a9"))

			probe12.picker_action({ What = "light:01\nforged line" })
			assert.truthy(last_action():find("light:01\\010forged line", 1, true), last_action())
			for _, line in ipairs(lines) do
				assert.is_nil(line:find("\n", 1, true))
			end

			probe12.picker_action({ What = "zzz" })
			assert.truthy(last_action():find("not a value these pickers offered", 1, true))

			probe12.picker_action({})
			assert.equal("Picker test: Composer sent no parameters", last_action())
		end)

		it("logs a folder's list for the dev loop (Probe Picker)", function()
			probe12.picker_dump({ Folder = "f:lights" })
			assert.equal('Probe Picker: folder "f:lights" has 48 entries', last_action())
			probe12.picker_dump({ Folder = "f:async" })
			advance(probe12.ASYNC_MS)
			assert.equal('Probe Picker: folder "f:async" has 5 entries', last_action())
			probe12.picker_dump({})
			assert.equal('Probe Picker: folder "" has 8 entries', last_action())
		end)

		it("logs every call of the second picker with its arguments", function()
			local rooms = probe12.room_list("", "x")
			assert.equal(3, #rooms)
			assert.truthy(logged('Probe12RoomList called with 2 argument(s): "", "x"'))
		end)
	end)
end)

describe("bridge/probe12.lua through bridge/devtools.lua (a dev build of the bridge)", function()
	local saved_sink

	before_each(function()
		saved_sink = log.sink
		log.sink = function() end
	end)

	after_each(function()
		log.sink = saved_sink
		local loop = package.loaded["common.devloop"]
		if type(loop) == "table" and loop.set_signed_commands then
			loop.set_signed_commands(nil)
			loop.set_redactor(nil)
		end
		rawset(_G, "Probe12PickerList", nil)
		rawset(_G, "Probe12RoomList", nil)
	end)

	it("registers the signed commands and the pickers' globals; Probe Names refuses an unpaired bridge", function()
		local driver_env = fake.load_driver("hue_bridge", {})
		driver_env.OnDriverLateInit("DIT_ADDING")
		assert.is_function(driver_env.Probe12PickerList)
		assert.is_table(fake.custom_select(driver_env, "Probe12PickerList"))
		local devloop = require("common.devloop")
		assert.is_nil(devloop.execute("Probe Names", {}))
		assert.equal("Probe Names refused: not paired; nothing was sent", driver_env.Properties["Last Action"])
		assert.is_nil(devloop.execute("Probe Picker", { Folder = "f:areas" }))
		assert.equal('Probe Picker: folder "f:areas" has 8 entries', driver_env.Properties["Last Action"])
		assert.is_nil(devloop.execute("Probe Picker Folders", { What = "area:02" }))
		assert.equal('Picker test: What = "area:02" (MotionAware area 02)', driver_env.Properties["Last Action"])
		assert.is_nil(devloop.execute("Probe Names Restore", {}))
		assert.equal("Probe Names Restore refused: not paired; nothing was sent", driver_env.Properties["Last Action"])
	end)

	it("keeps the probe's commands out of what any driver can send", function()
		local driver_env = fake.load_driver("hue_bridge", {})
		driver_env.OnDriverLateInit("DIT_ADDING")
		local dispatch = require("common.dispatch")
		for _, name in ipairs({ "Probe_Discovery", "Probe_Names", "Probe_Names_Restore", "Probe_Picker" }) do
			assert.is_nil(dispatch.commands[name], name)
		end
	end)
end)
