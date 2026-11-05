-- The 1.2 probe (#334, docs/simplify-actions-design.md §2.2), dev builds
-- only: tools/build.sh leaves this file out of release builds together with
-- bridge/devtools.lua, which registers its commands. It answers on the house
-- controller, in about two minutes and without a Composer click, the open
-- questions the 1.2 design depends on; the Windows Composer session only
-- installs the dev build in place. Signed dev loop commands
-- (tools/devctl.py run, docs/dev-loop.md "Signed commands"):
--
--   Probe Discovery [Mode=all|udp|env|ssdp|mdns|mdns5353|multicast|sweep]
--                   [Subnet=a.b.c] [InFlight=1..4]
--     docs/simplify-research-discovery.md §3, probes P0 to P6: the
--     environment, the SSDP control, three mDNS queries for _hue._tcp.local,
--     each on a UDP network connection of its own, and a timed sweep of port
--     443 over one /24 followed by the unkeyed identity probe of pairing on
--     every host that accepted. About 15 s without the sweep, under two
--     minutes with it; never more than DISCOVERY_CAP_MS.
--   Probe Names [Light=<light rid>] [Scene=<scene rid>] [Sensor=<device rid>]
--               [Area=<motion_area_configuration rid>]   (each also "skip")
--     docs/simplify-research-names-sync.md §8, tests T1 to T3: one light's
--     Hue device (with a single light by default) and that light's own name,
--     each read back with the other to see whether it followed (T1, E10,
--     N31), one scene, one motion sensor's device and one MotionAware area
--     renamed to a marked test name and back, a 33-character name, a
--     duplicate scene name in one group and 32 "é", each with Hue's answer.
--     Every original name is restored and read back, after an error and
--     after a timeout too. Refused while unpaired, while the key is
--     rejected, after a failed TLS check and before the identity check.
--   Probe Names Restore
--     only the restore, from what an interrupted run persisted (STORE).
--   Probe Picker [Folder=<value>]
--     the picker's list for one folder, logged (no Composer needed).
--   Probe Picker Folders [What=...] [Room=...]
--     the handler of the DEV-ONLY test action whose CUSTOM_SELECT pickers
--     are the globals Probe12PickerList and Probe12RoomList (install):
--     about 220 entries in folders laid out like the planned Add From Hue
--     (docs/simplify-research-composer.md §A). It logs exactly what Composer
--     sends, byte for byte.
--
-- Every log line starts "probe12 <part>:" (env, ssdp, mdns, mdns5353,
-- multicast, sweep, names, picker), so `tools/devctl.py log -n 500 | grep
-- probe12` reads a run; each probe ends with one summary in Last Action. No
-- line carries the application key: requests go through the driver's own
-- bridge_request, and pairing.probe sends none.
--
-- DriverWorks calls, with the SDK file that documents each (API/ is
-- ~/c4-tools/reference/docs-driverworks-api/source/includes/):
--   C4:GetControllerNetworkAddress()                API/32_serial_network_device/_5
--   C4:PortInUse(port), OS 3.3.1+                   API/9_helper/_13.5-Portinuse.md
--   C4:GetVersionInfo()                             API/5_director_command/_2-GetVersionInfo.md
--   C4:GetBindingAddress(id)                        API/32_serial_network_device/_2
--   C4:CreateNetworkConnection(id, address)         API/32_serial_network_device/_1
--   C4:NetPortOptions(id, port, "UDP", options)     API/32_serial_network_device/_25 (MIRROR_UDP_PORT)
--   C4:NetConnect(id, port, "UDP"|"MULTICAST")      API/32_serial_network_device/_23
--   C4:SendToNetwork(id, port, data)                API/32_serial_network_device/_20 (NUL bytes allowed)
--   C4:NetDisconnect(id, port)                      API/32_serial_network_device/_24
--   OnConnectionStatusChanged, ReceivedFromNetwork  API/32_serial_network_device/_27, _15 ("from" since 4.0)
--   C4:CreateTCPClient(), :OnConnect, :OnError, :Connect(host, port), :Close(flush)
--                                                   API/14_lua_tcp_client/ (Close cancels a pending
--                                                   connect, which then calls OnError)
--   C4:SetTimer, C4:GetTime; C4:PersistSetValue / PersistGetValue / PersistDeleteValue (API/26.5_persistence)
-- The UDP pattern (create the connection, NetConnect "UDP", send on
-- "ONLINE") is the one Snap One's SSDP module uses
-- (~/c4-tools/drivers-common-public/module/ssdp.lua), read, not copied.
--
-- Network binding ids: 6004 to 6009, reserved for discovery
-- (docs/simplify-research-discovery.md §2.1 and O8): 6001 is the event
-- stream's (bridge/netstream.lua), 6002 and 6003 belong to earlier builds,
-- 6100 to 6999 are the TLS check's fresh ids from its persisted counter
-- (bridge/netcheck.lua). mDNS takes 6004, SSDP 6005, mDNS from port 5353
-- 6006, the MULTICAST type 6007; 6008 and 6009 stay free. Each is created
-- once per run of the driver's Lua and never cleared (no SetBindingAddress
-- with ''), as 6001 is: on OS 3.4.3 an id that was cleared and then reused
-- inherited an old connection or did nothing (netcheck.lua's header). A
-- second probe in the same run only connects again; a run after a dev loop
-- reload creates it again, which is probe P6. The TCP sweep uses no binding.
--
-- Routing: while a discovery run lasts, the module wraps the driver's two
-- network globals (OnConnectionStatusChanged, ReceivedFromNetwork): calls
-- for 6004 to 6009 come here with every argument Director passes, a
-- fourth "from" included, everything else goes on to the driver's own
-- function unchanged; at the end the driver's functions are put back
-- (unless a reload replaced them meanwhile). probe12.on_status_changed and
-- probe12.on_data are the same entry points for a driver that routes
-- explicitly; each returns true for a probe binding, false otherwise.

local log = require("common.log")
local pairing = require("bridge.pairing")

local probe12 = {}

-- Bindings (see the header).
probe12.BINDING_FIRST = 6004
probe12.BINDING_LAST = 6007 -- 6008 is bridge/discovery.lua's mDNS binding, 6009 its spare
probe12.BINDINGS = { mdns = 6004, ssdp = 6005, mdns5353 = 6006, multicast = 6007 }

probe12.MDNS_GROUP, probe12.MDNS_PORT = "224.0.0.251", 5353
probe12.SSDP_GROUP, probe12.SSDP_PORT = "239.255.255.250", 1900
probe12.SERVICE = "_hue._tcp.local"

-- Bounds of Probe Discovery.
probe12.ONLINE_WAIT_MS = 1500        -- a UDP query goes out after this even without "ONLINE"
probe12.SSDP_WINDOW_MS = 5000        -- answers counted after the query (MX is 2)
probe12.MDNS_WINDOW_MS = 3000
probe12.MAX_PACKETS = 10             -- answers parsed and logged per query; the rest are counted
probe12.HEX_MAX = 1600               -- bytes of one answer logged as hex
probe12.SWEEP_IN_FLIGHT = 4          -- TCP connects at once, never more
probe12.SWEEP_CONNECT_MS = 1500      -- a connect still pending then is closed: no answer
probe12.SWEEP_GAP_MS = 125           -- between two connects started: at most 8 a second
probe12.SWEEP_CAP_MS = 110000        -- the TCP stage, whatever is left
probe12.IDENTITY_MAX = 16            -- hosts given the identity probe
probe12.IDENTITY_WAIT_MS = 20000     -- per host (bridge/http.lua's own timeout is 15 s)
probe12.IDENTITY_CAP_MS = 45000      -- the identity stage
probe12.DISCOVERY_CAP_MS = 180000    -- the whole run

-- Bounds of Probe Names.
probe12.NAMES_TEST_CAP_MS = 90000    -- reading and testing; then straight to the restore
probe12.NAMES_RESTORE_CAP_MS = 60000 -- the restore and its read-back
probe12.NAMES_REQUEST_MS = 20000     -- one request (the transfer's own timeout is 10 s)
probe12.NAMES_REQUEST_TIMEOUT_S = 10
probe12.NAMES_SETTLE_MS = 1500       -- after a rename that took, before reading it back
probe12.NAMES_RESTORE_ROUNDS = 3     -- read-back rounds, each restoring what still differs
probe12.MARK = "C4 PROBE"            -- every test name starts with it, but the duplicate and the 32 "é"
probe12.STORE = "probe12_names_restore"

local MDNS_TYPES = { [1] = "A", [12] = "PTR", [16] = "TXT", [28] = "AAAA", [33] = "SRV", [47] = "NSEC" }

local ctx            -- the devtools context (devtools.install): state, prop, last_action?, connection, bridge_request
-- The table that holds the driver's globals the network wrap replaces: _G
-- on the controller (driver.lua runs in it); a spec sets its fake driver's.
probe12.globals = nil
local disco          -- the discovery run in progress, or nil
local names_run      -- the names run in progress, or nil
local hooks          -- the wrapped network globals while a discovery run lasts
local created = {}   -- binding id -> true once created in this run of the driver's Lua

-- Helpers ------------------------------------------------------------------

local function now_ms()
	return C4:GetTime()
end

local function cancel(timer)
	if timer then
		pcall(function() timer:Cancel() end)
	end
end

-- `fn` from a timer after `ms`, under pcall; a raise is logged and handed
-- to `on_error` (a run's end), so no run stays "running" for ever.
local function after(ms, fn, on_error)
	return C4:SetTimer(math.max(1, math.floor(ms)), function()
		local ok, err = pcall(fn)
		if not ok then
			log.always("probe12: a step failed: %s", tostring(err))
			if on_error then
				pcall(on_error, tostring(err))
			end
		end
	end)
end

-- One Last Action line (the driver's wrapping writer when devtools has it,
-- which also logs it), else the row and the log.
local function say(text)
	if ctx and type(ctx.last_action) == "function" then
		ctx.last_action(text)
		return
	end
	log.always("%s", text)
	if ctx and type(ctx.prop) == "function" then
		ctx.prop("Last Action", text)
	end
end

-- A value as one log line: control characters and "\" as \ddd.
local function printable(value)
	return (tostring(value):gsub("[%c\\]", function(c) return string.format("\\%03d", c:byte()) end))
end

local function hex(data, max)
	local out = {}
	for i = 1, math.min(#data, max or #data) do
		out[#out + 1] = string.format("%02x", data:byte(i))
	end
	return table.concat(out)
end

local function octets(ip)
	if type(ip) ~= "string" then
		return nil
	end
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then
		return nil
	end
	local list = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
	for _, n in ipairs(list) do
		if n > 255 then
			return nil
		end
	end
	return list
end

local function prefix24(ip)
	local o = octets(ip)
	return o and string.format("%d.%d.%d", o[1], o[2], o[3]) or nil
end

-- A C4 method by name under pcall: value, or nil and why.
local function call_c4(name, ...)
	if type(C4[name]) ~= "function" then
		return nil, "no C4:" .. name
	end
	local ok, value = pcall(C4[name], C4, ...)
	if not ok then
		return nil, tostring(value)
	end
	return value
end

local function paired_id()
	local creds = ctx and ctx.state and ctx.state.creds
	return type(creds) == "table" and type(creds.bridge_id) == "string" and creds.bridge_id:lower() or nil
end

-- UTF-8 characters of a string (its bytes that start one).
local function utf8_chars(s)
	local n = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 128 or b >= 192 then
			n = n + 1
		end
	end
	return n
end

-- DNS (RFC 1035 §4, the mDNS message format of RFC 6762 §18) -----------------

local function u16(s, i)
	local a, b = s:byte(i, i + 1)
	if not b then
		error("the packet ends early", 0)
	end
	return a * 256 + b
end

-- The name at byte i, compression pointers followed (at most 16), and the
-- index just after it where it was written.
local function read_name(s, i)
	local labels, jumps, resume = {}, 0, nil
	local pos = i
	while true do
		local len = s:byte(pos)
		if not len then
			error("a name runs past the packet", 0)
		end
		if len == 0 then
			pos = pos + 1
			break
		elseif len >= 192 then
			local low = s:byte(pos + 1)
			if not low then
				error("a pointer runs past the packet", 0)
			end
			resume = resume or pos + 2
			jumps = jumps + 1
			if jumps > 16 then
				error("a pointer loop", 0)
			end
			pos = (len - 192) * 256 + low + 1
		elseif len >= 64 then
			error("a label length of " .. len, 0)
		else
			labels[#labels + 1] = s:sub(pos + 1, pos + len)
			if #labels > 64 then
				error("too many labels", 0)
			end
			pos = pos + 1 + len
		end
	end
	return table.concat(labels, "."), resume or pos
end

local function dns_name(name)
	local parts = {}
	for label in name:gmatch("[^%.]+") do
		parts[#parts + 1] = string.char(#label) .. label
	end
	return table.concat(parts) .. "\0"
end

-- A PTR question for _hue._tcp.local (class IN), id `id`; `unicast` sets the
-- QU bit (RFC 6762 §5.4).
function probe12.mdns_query(id, unicast)
	local class = unicast and 0x8001 or 1
	return string.char(math.floor(id / 256), id % 256, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0)
		.. dns_name(probe12.SERVICE) .. string.char(0, 12, math.floor(class / 256), class % 256)
end

-- One DNS message: { id, flags, qd, an, ns, ar, records = n, ptr = {{name,
-- target}}, srv = {{name, target, port}}, txt = {{name, kv}}, a = {{name, ip}},
-- aaaa = n, types = {"PTR", ...} }. Raises on a malformed message.
function probe12.parse_dns(s)
	local p = { id = u16(s, 1), flags = u16(s, 3), qd = u16(s, 5), an = u16(s, 7), ns = u16(s, 9), ar = u16(s, 11),
		records = 0, ptr = {}, srv = {}, txt = {}, a = {}, aaaa = 0, types = {} }
	if p.qd > 16 or p.an + p.ns + p.ar > 200 then
		error("implausible record counts", 0)
	end
	local i = 13
	for _ = 1, p.qd do
		local _, next_i = read_name(s, i)
		i = next_i + 4
	end
	for _ = 1, p.an + p.ns + p.ar do
		local name, next_i = read_name(s, i)
		local rtype, rlen = u16(s, next_i), u16(s, next_i + 8)
		local at = next_i + 10
		if at + rlen - 1 > #s then
			error("a record runs past the packet", 0)
		end
		p.types[#p.types + 1] = MDNS_TYPES[rtype] or tostring(rtype)
		if rtype == 12 then
			p.ptr[#p.ptr + 1] = { name = name, target = (read_name(s, at)) }
		elseif rtype == 33 then
			p.srv[#p.srv + 1] = { name = name, port = u16(s, at + 4), target = (read_name(s, at + 6)) }
		elseif rtype == 16 then
			local kv, j, stop = {}, at, at + rlen
			while j < stop do
				local len = s:byte(j)
				local item = s:sub(j + 1, math.min(j + len, stop - 1))
				local k, v = item:match("^([^=]+)=(.*)$")
				if k then
					kv[k:lower()] = v
				end
				j = j + 1 + len
			end
			p.txt[#p.txt + 1] = { name = name, kv = kv }
		elseif rtype == 1 and rlen == 4 then
			p.a[#p.a + 1] = { name = name, ip = string.format("%d.%d.%d.%d", s:byte(at, at + 3)) }
		elseif rtype == 28 then
			p.aaaa = p.aaaa + 1
		end
		p.records = p.records + 1
		i = at + rlen
	end
	return p
end

-- SSDP (the control of P1) ----------------------------------------------------

probe12.SSDP_QUERY = table.concat({ "M-SEARCH * HTTP/1.1", "HOST: 239.255.255.250:1900", 'MAN: "ssdp:discover"',
	"MX: 2", "ST: ssdp:all", "", "" }, "\r\n")

-- One SSDP answer: { status, headers (lower-case names), bridgeid, host (of LOCATION), server }.
function probe12.parse_ssdp(data)
	local out = { status = data:match("^([^\r\n]*)"), headers = {} }
	for line in data:gmatch("[^\r\n]+") do
		local k, v = line:match("^([%w%-]+):%s*(.-)%s*$")
		if k then
			out.headers[k:lower()] = v
		end
	end
	out.bridgeid = out.headers["hue-bridgeid"]
	out.host = out.headers.location and out.headers.location:match("^%a+://%[?([^/%]:]+)")
	out.server = out.headers.server
	return out
end

-- Probe Discovery ---------------------------------------------------------------

local UDP = {
	ssdp = { binding = probe12.BINDINGS.ssdp, address = probe12.SSDP_GROUP, port = probe12.SSDP_PORT,
		ip_type = "UDP", window = "SSDP_WINDOW_MS", query = function() return probe12.SSDP_QUERY end },
	mdns = { binding = probe12.BINDINGS.mdns, address = probe12.MDNS_GROUP, port = probe12.MDNS_PORT,
		ip_type = "UDP", window = "MDNS_WINDOW_MS", query = function() return probe12.mdns_query(0x4c7e, false) end },
	-- From port 5353 itself (MIRROR_UDP_PORT) with the QU bit, for a
	-- responder without legacy unicast (RFC 6762 §6.7); only when 5353 is free.
	mdns5353 = { binding = probe12.BINDINGS.mdns5353, address = probe12.MDNS_GROUP, port = probe12.MDNS_PORT,
		ip_type = "UDP", window = "MDNS_WINDOW_MS", options = { MIRROR_UDP_PORT = true }, needs_free_port = true,
		query = function() return probe12.mdns_query(0, true) end },
	-- The undocumented "MULTICAST" type of NetConnect, with the legacy query.
	multicast = { binding = probe12.BINDINGS.multicast, address = probe12.MDNS_GROUP, port = probe12.MDNS_PORT,
		ip_type = "MULTICAST", window = "MDNS_WINDOW_MS", query = function() return probe12.mdns_query(0x4c7f, false) end },
}

local MODES = {
	all = { "env", "ssdp", "mdns", "mdns5353", "multicast", "sweep" },
	udp = { "env", "ssdp", "mdns", "mdns5353", "multicast" },
	env = { "env" },
	ssdp = { "env", "ssdp" },
	mdns = { "env", "mdns" },
	mdns5353 = { "env", "mdns5353" },
	multicast = { "env", "multicast" },
	sweep = { "env", "sweep" },
}

function probe12.owns(binding)
	binding = tonumber(binding)
	return binding ~= nil and binding >= probe12.BINDING_FIRST and binding <= probe12.BINDING_LAST
end

local function wrap_globals()
	if hooks then
		return
	end
	local G = probe12.globals or _G
	local inner_status, inner_data = rawget(G, "OnConnectionStatusChanged"), rawget(G, "ReceivedFromNetwork")
	local h = { G = G, inner_status = inner_status, inner_data = inner_data }
	h.status = function(binding, port, status, ...)
		if probe12.on_status_changed(binding, port, status) then
			return
		end
		if type(inner_status) == "function" then
			return inner_status(binding, port, status, ...)
		end
	end
	h.data = function(binding, port, data, ...)
		if probe12.on_data(binding, port, data, ...) then
			return
		end
		if type(inner_data) == "function" then
			return inner_data(binding, port, data, ...)
		end
	end
	rawset(G, "OnConnectionStatusChanged", h.status)
	rawset(G, "ReceivedFromNetwork", h.data)
	hooks = h
end

local function unwrap_globals()
	local h = hooks
	hooks = nil
	if not h then
		return
	end
	if rawget(h.G, "OnConnectionStatusChanged") == h.status then
		rawset(h.G, "OnConnectionStatusChanged", h.inner_status)
	end
	if rawget(h.G, "ReceivedFromNetwork") == h.data then
		rawset(h.G, "ReceivedFromNetwork", h.inner_data)
	end
end

local discovery_step -- forward

local function next_step(run)
	if not run.finished then
		after(1, function() discovery_step(run) end, run.fail)
	end
end

local function step_env(run)
	local env = run.env
	env.controller = call_c4("GetControllerNetworkAddress")
	local in_use, why = call_c4("PortInUse", probe12.MDNS_PORT)
	if in_use == true or in_use == false then
		env.port_in_use = in_use
	else
		env.port_why = why or "no answer"
	end
	local info = call_c4("GetVersionInfo")
	env.director = type(info) == "table" and info.version or nil
	env.bridge_ip = ctx.state and ctx.state.ip
	env.tcp = type(C4.CreateTCPClient) == "function"
	local before = {}
	for b = probe12.BINDING_FIRST, probe12.BINDING_LAST do
		local address = call_c4("GetBindingAddress", b)
		before[#before + 1] = string.format("%d=%s", b, address == nil and "nil" or ("'" .. printable(address) .. "'"))
	end
	local same = "unknown"
	if prefix24(env.controller) and prefix24(env.bridge_ip) then
		same = prefix24(env.controller) == prefix24(env.bridge_ip) and "yes" or "no"
	end
	log.always("probe12 env: controller %s, bridge %s (same /24: %s), paired id %s, PortInUse(5353) %s, Director %s, "
		.. "C4:CreateTCPClient %s, created in this run: %s; binding addresses: %s",
		tostring(env.controller), tostring(env.bridge_ip), same, tostring(paired_id()),
		env.port_in_use == nil and ("unknown (" .. tostring(env.port_why) .. ")") or tostring(env.port_in_use),
		tostring(env.director), env.tcp and "yes" or "no", next(created) and "some" or "none", table.concat(before, " "))
	next_step(run)
end

local function close_window(w)
	if not w.open then
		return
	end
	w.open = false
	cancel(w.online_timer)
	cancel(w.window_timer)
	local ok, err = pcall(function() C4:NetDisconnect(w.spec.binding, w.spec.port) end)
	if not ok then
		log.always("probe12 %s: NetDisconnect raised: %s", w.name, tostring(err))
	end
	local r = w.res
	log.always("probe12 %s: window closed: %d answer(s)%s, statuses %s, most arguments %s, from %s",
		w.name, r.answers, r.hue > 0 and string.format(" (%d for Hue)", r.hue) or "",
		#r.statuses > 0 and table.concat(r.statuses, ",") or "none", tostring(r.args or "-"),
		r.from and printable(r.from) or "never given")
end

local function send_query(run, w, why)
	if w.sent or not w.open then
		return
	end
	w.sent = true
	cancel(w.online_timer)
	local payload = w.spec.query()
	local ok, err = pcall(function() C4:SendToNetwork(w.spec.binding, w.spec.port, payload) end)
	w.sent_at = now_ms()
	log.always("probe12 %s: query sent, %d bytes, %d ms after NetConnect%s%s", w.name, #payload, w.sent_at - w.t0,
		why and ("; " .. why) or "", ok and "" or ("; SendToNetwork raised: " .. tostring(err)))
	if not ok then
		w.res.error = "SendToNetwork raised"
		close_window(w)
		return next_step(run)
	end
	w.window_timer = after(probe12[w.spec.window], function()
		close_window(w)
		next_step(run)
	end, run.fail)
end

local function udp_step(run, name)
	local spec = UDP[name]
	local res = { answers = 0, late = 0, parsed = 0, hue = 0, statuses = {}, ids = {}, a = {} }
	run.results[name] = res
	if spec.needs_free_port and run.env.port_in_use ~= false then
		res.skipped = run.env.port_in_use and "5353 is in use on the controller" or "PortInUse(5353) gave no answer"
		log.always("probe12 %s: skipped: %s", name, res.skipped)
		return next_step(run)
	end
	wrap_globals()
	local w = { name = name, spec = spec, res = res, t0 = now_ms(), open = true }
	run.windows[spec.binding] = w
	local ok, err = pcall(function()
		if not created[spec.binding] then
			C4:CreateNetworkConnection(spec.binding, spec.address)
			created[spec.binding] = true
			res.created = true
		end
		if spec.options then
			C4:NetPortOptions(spec.binding, spec.port, "UDP", spec.options)
		end
		-- As Snap One's SSDP module connects, and netstream's first connect.
		pcall(function() C4:NetDisconnect(spec.binding, spec.port) end)
		C4:NetConnect(spec.binding, spec.port, spec.ip_type)
	end)
	log.always("probe12 %s: binding %d %s %s:%d as %s%s%s", name, spec.binding,
		res.created and "created for" or "connected again to", spec.address, spec.port, spec.ip_type,
		spec.options and " with MIRROR_UDP_PORT" or "", ok and "" or ("; raised: " .. tostring(err)))
	if not ok then
		res.error = "could not open: " .. tostring(err)
		close_window(w)
		return next_step(run)
	end
	if w.open and not w.sent then
		w.online_timer = after(probe12.ONLINE_WAIT_MS, function()
			send_query(run, w, string.format("no ONLINE within %d ms, sent anyway", probe12.ONLINE_WAIT_MS))
		end, run.fail)
	end
end

-- One mDNS answer into its window's result.
local function take_mdns(w, data, ms, nargs, from)
	local r = w.res
	local ok, p = pcall(probe12.parse_dns, data)
	if not ok then
		log.always("probe12 %s: answer %d after %d ms, %d bytes, %d arguments, from %s: not parsed (%s); "
			.. "bridgeid=%s", w.name, r.answers, ms, #data, nargs, printable(from or "-"), tostring(p),
			tostring(data:match("bridgeid=(%x+)")))
	else
		local hue, ids, addresses, instances, srv = false, {}, {}, {}, {}
		for _, rec in ipairs(p.ptr) do
			instances[#instances + 1] = printable(rec.target)
			hue = hue or rec.name:lower() == probe12.SERVICE
		end
		for _, rec in ipairs(p.txt) do
			if rec.kv.bridgeid then
				local id = rec.kv.bridgeid:lower()
				ids[#ids + 1] = id .. "/" .. tostring(rec.kv.modelid)
				r.ids[id] = true
				hue = true
			end
		end
		for _, rec in ipairs(p.srv) do
			srv[#srv + 1] = printable(rec.target) .. ":" .. rec.port
		end
		for _, rec in ipairs(p.a) do
			addresses[#addresses + 1] = rec.ip
			r.a[rec.ip] = true
		end
		if hue then
			r.hue = r.hue + 1
		end
		log.always("probe12 %s: answer %d after %d ms, %d bytes, %d arguments, from %s: id 0x%04x flags 0x%04x, "
			.. "%d/%d/%d/%d records (%s); PTR %s; SRV %s; TXT bridgeid/modelid %s; A %s; AAAA %d",
			w.name, r.answers, ms, #data, nargs, printable(from or "-"), p.id, p.flags, p.qd, p.an, p.ns, p.ar,
			table.concat(p.types, ","), #instances > 0 and table.concat(instances, " | ") or "-",
			#srv > 0 and table.concat(srv, " ") or "-", #ids > 0 and table.concat(ids, " ") or "-",
			#addresses > 0 and table.concat(addresses, " ") or "-", p.aaaa)
	end
	-- The packet itself, for the specs of the mDNS module to come (with placeholders).
	local text = hex(data, probe12.HEX_MAX)
	local pieces = math.ceil(#text / 800)
	for i = 1, #text, 800 do
		log.always("probe12 %s: answer %d hex %d/%d: %s", w.name, r.answers, math.ceil(i / 800), pieces,
			text:sub(i, i + 799))
	end
end

local function take_ssdp(w, data, ms, nargs, from)
	local r = w.res
	local a = probe12.parse_ssdp(data)
	if a.bridgeid then
		r.hue = r.hue + 1
		r.ids[a.bridgeid:lower()] = true
	end
	if a.host then
		r.a[a.host] = true
	end
	log.always("probe12 %s: answer %d after %d ms, %d bytes, %d arguments, from %s: %s; LOCATION host %s; "
		.. "hue-bridgeid %s; SERVER %s; ST %s", w.name, r.answers, ms, #data, nargs, printable(from or "-"),
		printable(a.status or ""), tostring(a.host), tostring(a.bridgeid), printable(a.server or "-"),
		printable(a.headers.st or "-"))
end

function probe12.on_status_changed(binding, port, status)
	if not probe12.owns(binding) then
		return false
	end
	local run = disco
	local w = run and run.windows[tonumber(binding)]
	if not w then
		log.always("probe12: binding %s port %s reports %s outside a probe window", tostring(binding), tostring(port),
			printable(status))
		return true
	end
	local text = tostring(status)
	local ms = now_ms() - w.t0
	w.res.statuses[#w.res.statuses + 1] = string.format("%s@%dms", printable(text), ms)
	log.always("probe12 %s: %s after %d ms%s", w.name, printable(text), ms, w.open and "" or " (window closed)")
	if text:upper() == "ONLINE" then
		w.res.online = true
		local ok, err = pcall(send_query, run, w, nil)
		if not ok then
			log.always("probe12 %s: sending the query failed: %s", w.name, tostring(err))
		end
	end
	return true
end

function probe12.on_data(binding, port, data, ...)
	if not probe12.owns(binding) then
		return false
	end
	local nargs = 3 + select("#", ...)
	local from = (...)
	local run = disco
	local w = run and run.windows[tonumber(binding)]
	if not w or type(data) ~= "string" then
		log.always("probe12: binding %s port %s: %s bytes outside a probe window", tostring(binding), tostring(port),
			type(data) == "string" and #data or "no")
		return true
	end
	local r = w.res
	if not w.open then
		r.late = r.late + 1
		if r.late == 1 then
			log.always("probe12 %s: an answer after the window closed (counted, not parsed)", w.name)
		end
		return true
	end
	r.answers = r.answers + 1
	r.args = math.max(r.args or 0, nargs)
	if type(from) == "string" and from ~= "" then
		r.from = from
	end
	if r.parsed >= probe12.MAX_PACKETS then
		if r.answers == probe12.MAX_PACKETS + 1 then
			log.always("probe12 %s: more than %d answers; the rest are only counted", w.name, probe12.MAX_PACKETS)
		end
		return true
	end
	r.parsed = r.parsed + 1
	local ms = now_ms() - (w.sent_at or w.t0)
	local ok, err = pcall(w.spec == UDP.ssdp and take_ssdp or take_mdns, w, data, ms, nargs, from)
	if not ok then
		log.always("probe12 %s: answer %d not logged: %s", w.name, r.answers, tostring(err))
	end
	return true
end

-- The sweep: stage A, TCP connects to port 443 ------------------------------

-- The /24 to sweep ("a.b.c"), its addresses in order (alternating outward
-- from `centre`: the controller's own, which is skipped, else the bridge's
-- address when it is in that /24, else .1), or nil and why.
local function sweep_plan(run)
	local subnet = run.params.Subnet
	local controller = octets(run.env.controller)
	if subnet and subnet ~= "" then
		local a, b, c = tostring(subnet):match("^(%d+)%.(%d+)%.(%d+)$")
		if not a or tonumber(a) > 255 or tonumber(b) > 255 or tonumber(c) > 255 then
			return nil, "Subnet " .. printable(subnet) .. " is not a.b.c"
		end
		subnet = string.format("%d.%d.%d", tonumber(a), tonumber(b), tonumber(c))
	elseif controller then
		subnet = prefix24(run.env.controller)
	else
		return nil, "no controller address (C4:GetControllerNetworkAddress)"
	end
	local first = tonumber(subnet:match("^(%d+)"))
	if first == 0 or first == 127 or first >= 224 then
		return nil, "Subnet " .. subnet .. " is not a host network"
	end
	local skip, centre
	if controller and prefix24(run.env.controller) == subnet then
		skip, centre = controller[4], controller[4]
	else
		local bridge = octets(run.env.bridge_ip)
		centre = (bridge and prefix24(run.env.bridge_ip) == subnet) and bridge[4] or 1
	end
	local hosts = {}
	local function add(n)
		if n >= 1 and n <= 254 and n ~= skip then
			hosts[#hosts + 1] = subnet .. "." .. n
		end
	end
	add(centre)
	for d = 1, 254 do
		add(centre + d)
		add(centre - d)
	end
	return subnet, hosts, centre
end

local sweep_identity -- forward

local function sweep_done(run, sw)
	if sw.done then
		return
	end
	sw.done = true
	cancel(sw.cap_timer)
	cancel(sw.pump_timer)
	local res = sw.res
	res.ms = now_ms() - sw.t0
	local codes = {}
	for code, n in pairs(res.codes) do
		codes[#codes + 1] = string.format("%s x%d", code, n)
	end
	table.sort(codes)
	log.always("probe12 sweep: %s.x: %d of %d addresses in %.1f s%s, at most %d in flight: %d open on 443, %d "
		.. "with no answer within %d ms, %d errors (%s), %d could not start, %d closed unanswered at the stop",
		res.subnet, res.tried, res.total, res.ms / 1000, res.stopped and (", stopped (" .. res.stopped .. ")") or "",
		res.max_in_flight, #res.open, res.timeouts, probe12.SWEEP_CONNECT_MS, res.errors,
		#codes > 0 and table.concat(codes, ", ") or "none", res.failed, res.aborted)
	if run.finished then
		return
	end
	sw.b_t0 = now_ms()
	sweep_identity(run, sw)
end

local pump -- forward

local function schedule_pump(run, sw, ms)
	if sw.pump_timer or sw.done or run.finished then
		return
	end
	sw.pump_timer = after(ms, function()
		sw.pump_timer = nil
		pump(run, sw)
	end, run.fail)
end

-- The end of one connect, once: "open", "timeout", "error" (with Director's
-- code and text), "failed" (the call raised) or "aborted".
local function sweep_result(run, sw, h, outcome, code, msg)
	if h.done then
		return
	end
	h.done = true
	cancel(h.timer)
	sw.live[h] = nil
	sw.in_flight = sw.in_flight - 1
	local res = sw.res
	local ms = now_ms() - h.t0
	if outcome == "aborted" then
		res.aborted = res.aborted + 1
	elseif outcome == "open" then
		res.open[#res.open + 1] = { ip = h.ip, ms = ms }
		log.always("probe12 sweep: %s accepts port 443 (%d ms)", h.ip, ms)
	elseif outcome == "timeout" then
		res.timeouts = res.timeouts + 1
	elseif outcome == "error" then
		res.errors = res.errors + 1
		local key = tostring(code) .. " " .. printable(msg or "")
		res.codes[key] = (res.codes[key] or 0) + 1
	elseif outcome == "failed" then
		res.failed = res.failed + 1
		if res.failed <= 3 then
			log.always("probe12 sweep: %s: the connect could not start: %s", h.ip, printable(msg))
		end
	end
	if outcome ~= "aborted" then
		schedule_pump(run, sw, 1)
	end
end

local function sweep_connect(run, sw, ip)
	local h = { ip = ip, t0 = now_ms() }
	local res = sw.res
	sw.in_flight = sw.in_flight + 1
	res.max_in_flight = math.max(res.max_in_flight, sw.in_flight)
	sw.last_start = h.t0
	sw.live[h] = true
	res.tried = res.tried + 1
	h.timer = after(probe12.SWEEP_CONNECT_MS, function()
		if not h.done then
			sweep_result(run, sw, h, "timeout")
			if h.client then
				pcall(function() h.client:Close(false) end)
			end
		end
	end, run.fail)
	local ok, err = pcall(function()
		local client = C4:CreateTCPClient()
		h.client = client
		client:OnConnect(function(c)
			sweep_result(run, sw, h, "open")
			pcall(function() c:Close(false) end)
		end)
		client:OnError(function(_, code, msg)
			sweep_result(run, sw, h, "error", code, msg)
		end)
		if client:Connect(ip, 443) == nil then
			error("Connect answered nil", 0)
		end
	end)
	if not ok then
		sweep_result(run, sw, h, "failed", nil, tostring(err))
	end
end

pump = function(run, sw)
	if sw.done or run.finished then
		return
	end
	while sw.in_flight < sw.limit and sw.index < #sw.hosts do
		local wait = sw.last_start and (sw.last_start + probe12.SWEEP_GAP_MS - now_ms()) or 0
		if wait > 0 then
			return schedule_pump(run, sw, wait)
		end
		sw.index = sw.index + 1
		sweep_connect(run, sw, sw.hosts[sw.index])
	end
	if sw.index >= #sw.hosts and sw.in_flight == 0 then
		sweep_done(run, sw)
	end
end

-- Stop the TCP stage: every connect still pending is closed.
local function sweep_stop(run, sw, why)
	if sw.done then
		return
	end
	sw.res.stopped = why
	sw.index = #sw.hosts
	for h in pairs(sw.live) do
		sweep_result(run, sw, h, "aborted")
		if h.client then
			pcall(function() h.client:Close(false) end)
		end
	end
	sweep_done(run, sw)
end

local function step_sweep(run)
	local res = { open = {}, timeouts = 0, errors = 0, failed = 0, aborted = 0, codes = {}, tried = 0, total = 0,
		max_in_flight = 0, identities = {}, checked = 0 }
	run.results.sweep = res
	if type(C4.CreateTCPClient) ~= "function" then
		res.skipped = "no C4:CreateTCPClient"
		log.always("probe12 sweep: skipped: %s", res.skipped)
		return next_step(run)
	end
	local subnet, hosts, centre = sweep_plan(run)
	if not subnet then
		res.skipped = hosts
		log.always("probe12 sweep: skipped: %s", res.skipped)
		return next_step(run)
	end
	local limit = math.floor(tonumber(run.params.InFlight) or probe12.SWEEP_IN_FLIGHT)
	limit = math.max(1, math.min(limit, probe12.SWEEP_IN_FLIGHT))
	res.subnet, res.total = subnet, #hosts
	local sw = { res = res, hosts = hosts, index = 0, in_flight = 0, limit = limit, live = {}, t0 = now_ms() }
	run.sweep = sw
	log.always("probe12 sweep: %s.1-254 port 443: %d addresses from .%d outward, %d in flight, %d ms per connect, "
		.. "%d ms between starts, %d s cap", subnet, #hosts, centre, limit, probe12.SWEEP_CONNECT_MS,
		probe12.SWEEP_GAP_MS, math.floor(probe12.SWEEP_CAP_MS / 1000))
	sw.cap_timer = after(probe12.SWEEP_CAP_MS, function() sweep_stop(run, sw, "the cap") end, run.fail)
	pump(run, sw)
end

-- Stage B: pairing's unkeyed identity probe on the hosts that accepted, one
-- at a time (a chain that is not Signify's ends at the handshake).
sweep_identity = function(run, sw)
	if run.finished then
		return
	end
	local res = sw.res
	local i = res.checked + 1
	local host = res.open[i]
	if not host or i > probe12.IDENTITY_MAX or now_ms() - sw.b_t0 >= probe12.IDENTITY_CAP_MS then
		log.always("probe12 sweep: identity checked on %d of %d host(s) in %.1f s%s", res.checked, #res.open,
			(now_ms() - sw.b_t0) / 1000, res.found and (", paired bridge at " .. res.found) or ", paired bridge not found")
		return next_step(run)
	end
	res.checked = i
	local t0, finished, timer = now_ms(), false, nil
	local function finish(info, err)
		if finished then
			return
		end
		finished = true
		cancel(timer)
		sw.transfer = nil
		if run.finished then
			return
		end
		local ms = now_ms() - t0
		if info then
			local paired = paired_id() ~= nil and info.bridge_id == paired_id()
			if paired and not res.found then
				res.found = host.ip
				res.found_after = i
			end
			res.identities[#res.identities + 1] = host.ip .. "=" .. tostring(info.bridge_id)
			log.always("probe12 sweep: identity of %s: Hue bridge %s, %s, %s, API %s%s (%d ms)", host.ip,
				tostring(info.bridge_id), tostring(info.model), printable(info.name or "-"), tostring(info.api_version),
				paired and ", the paired bridge" or "", ms)
		else
			log.always("probe12 sweep: identity of %s: not a Hue bridge: %s (%d ms)", host.ip, printable(err), ms)
		end
		after(1, function() sweep_identity(run, sw) end, run.fail)
	end
	timer = after(probe12.IDENTITY_WAIT_MS, function()
		local t = sw.transfer
		finish(nil, string.format("no answer within %d ms", probe12.IDENTITY_WAIT_MS))
		if t then
			pcall(function() t:Cancel() end)
		end
	end, run.fail)
	local ok, err = pcall(function()
		sw.transfer = pairing.probe(host.ip, function(info, why) finish(info, why) end)
	end)
	if not ok then
		finish(nil, "pairing.probe raised: " .. tostring(err))
	end
end

-- The run --------------------------------------------------------------------

local function udp_summary(name, r)
	if not r then
		return nil
	end
	if r.skipped then
		return name .. " skipped (" .. r.skipped .. ")"
	end
	if r.error then
		return name .. " failed (" .. r.error .. ")"
	end
	local text = string.format("%s %d answer%s", name, r.answers, r.answers == 1 and "" or "s")
	local notes = {}
	if r.hue > 0 then
		notes[#notes + 1] = r.hue .. " Hue"
	end
	local id = paired_id()
	if id and r.ids[id] then
		notes[#notes + 1] = "the paired id"
	elseif next(r.ids) then
		notes[#notes + 1] = "other bridge ids"
	end
	if name ~= "ssdp" and next(r.a) then
		notes[#notes + 1] = "A record"
	end
	if r.answers > 0 then
		notes[#notes + 1] = (r.args or 3) >= 4 and "from given" or "no from"
	end
	if r.late > 0 then
		notes[#notes + 1] = r.late .. " late"
	end
	if not r.online then
		notes[#notes + 1] = "no ONLINE"
	end
	return text .. (#notes > 0 and (" (" .. table.concat(notes, ", ") .. ")") or "")
end

local function discovery_summary(run)
	local parts = {}
	local env = run.env
	parts[#parts + 1] = string.format("controller %s, 5353 %s", tostring(env.controller),
		env.port_in_use == nil and "unknown" or (env.port_in_use and "in use" or "free"))
	for _, name in ipairs({ "ssdp", "mdns", "mdns5353", "multicast" }) do
		parts[#parts + 1] = udp_summary(name, run.results[name])
	end
	local s = run.results.sweep
	if s then
		if s.skipped then
			parts[#parts + 1] = "sweep skipped (" .. s.skipped .. ")"
		else
			parts[#parts + 1] = string.format("sweep %s.x %d/%d in %d s, 443 open on %d, %s", tostring(s.subnet), s.tried,
				s.total, math.floor((s.ms or 0) / 1000 + 0.5), #s.open,
				s.found and ("paired bridge at " .. s.found) or "paired bridge not found")
		end
	end
	return string.format("Probe Discovery (%s) in %d s%s: %s", run.mode,
		math.floor((now_ms() - run.t0) / 1000 + 0.5), run.stopped and (", " .. run.stopped) or "",
		table.concat(parts, "; "))
end

local function finish_discovery(run, why)
	if run.finished then
		return
	end
	run.finished = true
	run.stopped = why
	cancel(run.cap_timer)
	for _, w in pairs(run.windows) do
		close_window(w)
	end
	if run.sweep then
		local sw = run.sweep
		if not sw.done then
			sweep_stop(run, sw, why or "the end of the run")
		end
		if sw.transfer then
			local t = sw.transfer
			sw.transfer = nil
			pcall(function() t:Cancel() end)
		end
	end
	unwrap_globals()
	if disco == run then
		disco = nil
	end
	say(discovery_summary(run))
end

discovery_step = function(run)
	if run.finished then
		return
	end
	run.index = run.index + 1
	local name = run.steps[run.index]
	if not name then
		return finish_discovery(run, nil)
	end
	say(string.format("Probe Discovery running: %s (%d of %d)", name, run.index, #run.steps))
	if name == "env" then
		step_env(run)
	elseif name == "sweep" then
		step_sweep(run)
	else
		udp_step(run, name)
	end
end

function probe12.discovery(params)
	params = params or {}
	if disco then
		return say("Probe Discovery: already running; wait for its summary")
	end
	local mode = tostring(params.Mode or "all"):lower()
	if not MODES[mode] then
		local names = {}
		for m in pairs(MODES) do
			names[#names + 1] = m
		end
		table.sort(names)
		return say("Probe Discovery: unknown Mode " .. printable(mode) .. " (" .. table.concat(names, ", ") .. ")")
	end
	local run = { mode = mode, params = params, steps = MODES[mode], index = 0, env = {}, results = {}, windows = {},
		t0 = now_ms() }
	run.fail = function(err) finish_discovery(run, "stopped by an error: " .. tostring(err)) end
	disco = run
	log.always("probe12: Probe Discovery %s: %s", mode, table.concat(run.steps, ", "))
	run.cap_timer = after(probe12.DISCOVERY_CAP_MS, function()
		finish_discovery(run, string.format("stopped at the %d s cap", math.floor(probe12.DISCOVERY_CAP_MS / 1000)))
	end)
	discovery_step(run)
end

-- Probe Names ---------------------------------------------------------------

local KINDS = {
	device = { type = "device" },
	light = { type = "light" },
	scene = { type = "scene" },
	area = { type = "motion_area_configuration", plain = true },
}

local function body_for(kind, name)
	if KINDS[kind].plain then
		return { name = name }
	end
	return { metadata = { name = name } }
end

local function name_of(kind, item)
	if type(item) ~= "table" then
		return nil
	end
	if KINDS[kind].plain then
		return type(item.name) == "string" and item.name or nil
	end
	return type(item.metadata) == "table" and type(item.metadata.name) == "string" and item.metadata.name or nil
end

local function valid_rid(rid)
	return type(rid) == "string" and #rid <= 64 and rid:match("^[%w%-]+$") ~= nil
end

local function target(kind, rid, original, label)
	return { kind = kind, rid = rid, original = original, label = label,
		path = "/clip/v2/resource/" .. KINDS[kind].type .. "/" .. rid }
end

-- How a name reads in the log: quoted, with its length in characters and bytes.
local function shown(name)
	if type(name) ~= "string" then
		return "(none)"
	end
	return string.format('"%s" (%d characters, %d bytes)', printable(name), utf8_chars(name), #name)
end

local function items_of(r)
	return type(r.json) == "table" and type(r.json.data) == "table" and r.json.data or {}
end

local function hue_errors(r)
	local errs = type(r.json) == "table" and r.json.errors
	local out = {}
	if type(errs) == "table" then
		for _, e in ipairs(errs) do
			if type(e) == "table" and e.description ~= nil then
				out[#out + 1] = printable(e.description)
			end
		end
	end
	return table.concat(out, "; ")
end

local function answer_text(r)
	if r.timed_out then
		return "no answer (" .. tostring(r.err) .. ")"
	end
	local errs = hue_errors(r)
	if r.code then
		return "HTTP " .. tostring(r.code) .. (errs ~= "" and (" '" .. errs:sub(1, 200) .. "'") or "")
	end
	return "failed: " .. printable(r.err)
end

local function names_refusal()
	if not ctx or not ctx.connection or not ctx.connection() then
		return "not paired"
	end
	local state = ctx.state or {}
	if state.key_rejected then
		return string.format("the bridge rejected the key (HTTP %s)", tostring(state.key_rejected))
	end
	if state.tls_verdict == "not_pinned" then
		return "the TLS check failed"
	end
	if state.identity_ok ~= true then
		return "the bridge identity is not verified yet"
	end
	return nil
end

-- The persisted restore list: { v = 1, at, targets = {{kind, rid, name, label}} }.
local function save_pending(run)
	local list = {}
	for _, t in ipairs(run.targets) do
		list[#list + 1] = { kind = t.kind, rid = t.rid, name = t.original, label = t.label }
	end
	local ok, err = pcall(function()
		C4:PersistSetValue(probe12.STORE, C4:JsonEncode({ v = 1, at = os.time(), targets = list }))
	end)
	if not ok then
		log.always("probe12 names: could not persist the restore list: %s", tostring(err))
	end
	run.saved = ok
	return ok
end

local function clear_pending()
	pcall(function() C4:PersistDeleteValue(probe12.STORE) end)
end

local function load_pending()
	local ok, text = pcall(function() return C4:PersistGetValue(probe12.STORE) end)
	if not ok or type(text) ~= "string" or text == "" then
		return nil
	end
	local decoded_ok, record = pcall(function() return C4:JsonDecode(text) end)
	if not decoded_ok or type(record) ~= "table" or type(record.targets) ~= "table" then
		return nil
	end
	local targets = {}
	for _, t in ipairs(record.targets) do
		if type(t) == "table" and KINDS[t.kind] and valid_rid(t.rid) and type(t.name) == "string" then
			targets[#targets + 1] = target(t.kind, t.rid, t.name, tostring(t.label or t.kind))
		end
	end
	return #targets > 0 and targets or nil
end

-- One bridge request with a watchdog; cb(r) once, nothing after the run
-- moved on (a new chain) or ended. r.timed_out when the watchdog answered.
local function names_request(run, method, path, body, cb)
	local chain = run.chain
	local finished, timer = false, nil
	local function finish(r)
		if finished then
			return
		end
		finished = true
		cancel(timer)
		if run.finished or run.chain ~= chain then
			return
		end
		local ok, err = pcall(cb, type(r) == "table" and r or { ok = false, err = "no result" })
		if not ok then
			run.fail(err)
		end
	end
	timer = after(probe12.NAMES_REQUEST_MS, function()
		finish({ ok = false, timed_out = true, err = string.format("no answer within %d ms", probe12.NAMES_REQUEST_MS) })
	end, run.fail)
	local ok, err = pcall(ctx.bridge_request, { method = method, path = path, body = body,
		timeout = probe12.NAMES_REQUEST_TIMEOUT_S }, finish)
	if not ok then
		finish({ ok = false, err = "bridge_request raised: " .. tostring(err) })
	end
end

local function read_back(run, t, cb)
	names_request(run, "GET", t.path, nil, function(r)
		if not r.ok then
			return cb(nil, answer_text(r))
		end
		cb(name_of(t.kind, items_of(r)[1]))
	end)
end

local names_next, enter_restore -- forward

local function names_summary(run)
	local parts = {}
	for _, rec in ipairs(run.results) do
		local text = rec.label .. " " .. (rec.timed_out and "no answer" or (rec.code and tostring(rec.code)
			or ("failed: " .. printable(rec.err or "?"))))
		if rec.followed ~= nil then
			text = text .. string.format(" (%s %s)", rec.peer, rec.followed and "followed" or "did not follow")
		end
		parts[#parts + 1] = text
	end
	return parts
end

local function finish_names(run, outcome)
	if run.finished then
		return
	end
	run.finished = true
	cancel(run.test_timer)
	cancel(run.restore_timer)
	if names_run == run then
		names_run = nil
	end
	local parts = names_summary(run)
	local text
	if outcome.restored then
		clear_pending()
		text = string.format("Probe Names%s: %s; %s", run.restore_only and " Restore" or "",
			#parts > 0 and table.concat(parts, ", ") or "nothing tested", outcome.text)
	else
		text = string.format("Probe Names%s: %s; NOT RESTORED: %s; run Probe Names Restore", run.restore_only
			and " Restore" or "", #parts > 0 and table.concat(parts, ", ") or "nothing tested", outcome.text)
	end
	if run.then_text then
		text = text .. "; " .. run.then_text
	end
	say(text)
end

-- Whether the restore reads `t` back: a target a test wrote (or may have:
-- a PUT that timed out), the light whose device a test renamed and the
-- device whose light a test renamed, every target of a restore-only run.
local function to_restore(run, t)
	if t.touched or run.restore_only then
		return true
	end
	-- One name may have followed the other's rename.
	return (t == run.light and run.device ~= nil and run.device.touched == true)
		or (t == run.device and run.light ~= nil and run.light.touched == true)
end

-- The restore: read every target back; put back each that differs; again,
-- up to NAMES_RESTORE_ROUNDS reads; within NAMES_RESTORE_CAP_MS.
local function restore_round(run, round)
	if run.finished then
		return
	end
	local list = {}
	for _, t in ipairs(run.targets) do
		if to_restore(run, t) then
			list[#list + 1] = t
		end
	end
	if #list == 0 then
		return finish_names(run, { restored = true, text = "no name was changed" })
	end
	local wrong, i = {}, 0
	local function put_back(j)
		local t = wrong[j]
		if not t then
			return after(1, function() restore_round(run, round + 1) end, run.fail)
		end
		names_request(run, "PUT", t.path, body_for(t.kind, t.original), function(r)
			log.always("probe12 names: restore %s %s to %s: %s", t.label, t.rid, shown(t.original), answer_text(r))
			after(1, function() put_back(j + 1) end, run.fail)
		end)
	end
	local function check()
		i = i + 1
		local t = list[i]
		if not t then
			if #wrong == 0 then
				return finish_names(run, { restored = true,
					text = string.format("all %d name(s) restored and read back", #list) })
			end
			if round >= probe12.NAMES_RESTORE_ROUNDS then
				local labels = {}
				for _, w in ipairs(wrong) do
					labels[#labels + 1] = string.format("%s %s should be %s", w.label, w.rid, shown(w.original))
				end
				return finish_names(run, { restored = false, text = table.concat(labels, "; ") })
			end
			return put_back(1)
		end
		read_back(run, t, function(name, err)
			if name == t.original then
				log.always("probe12 names: read back %s: %s, as it was", t.label, shown(name))
			else
				log.always("probe12 names: read back %s: %s, not %s%s", t.label, shown(name), shown(t.original),
					err and (" (" .. err .. ")") or "")
				wrong[#wrong + 1] = t
			end
			after(1, check, run.fail)
		end)
	end
	check()
end

enter_restore = function(run, why)
	if run.finished or run.phase == "restore" then
		return
	end
	run.phase = "restore"
	run.chain = run.chain + 1 -- whatever test was still in flight is dropped
	cancel(run.test_timer)
	if why then
		log.always("probe12 names: %s; restoring", why)
	end
	run.restore_timer = after(probe12.NAMES_RESTORE_CAP_MS, function()
		local labels = {}
		for _, t in ipairs(run.targets) do
			if to_restore(run, t) then
				labels[#labels + 1] = string.format("%s %s should be %s", t.label, t.rid, shown(t.original))
			end
		end
		finish_names(run, { restored = false, text = string.format("the restore did not finish within %d s (%s)",
			math.floor(probe12.NAMES_RESTORE_CAP_MS / 1000), table.concat(labels, "; ")) })
	end, run.fail)
	after(1, function() restore_round(run, 1) end, run.fail)
end

-- One test: PUT the name, note Hue's answer; when it took, read it back
-- after NAMES_SETTLE_MS, and `peer` too when given (the light after its
-- device's rename, the device after the light's): whether it followed.
local function test_task(run, t, name, label, peer)
	return function(done)
		t.touched = true -- before the PUT: one that times out may still apply
		names_request(run, "PUT", t.path, body_for(t.kind, name), function(r)
			local rec = { label = label, code = r.code, ok = r.ok, err = r.err, timed_out = r.timed_out }
			run.results[#run.results + 1] = rec
			log.always("probe12 names: %s: PUT %s %s: %s", label, t.rid, shown(name), answer_text(r))
			if not r.ok then
				return done()
			end
			local chain = run.chain
			after(probe12.NAMES_SETTLE_MS, function()
				if run.chain ~= chain then
					return
				end
				read_back(run, t, function(held, err)
					rec.held = held
					log.always("probe12 names: %s: Hue holds %s%s", label, shown(held), err and (" (" .. err .. ")") or "")
					if not peer then
						return done()
					end
					read_back(run, peer, function(other, err2)
						rec.followed = other == name
						rec.peer = peer.kind == "light" and "light name" or "device name"
						log.always("probe12 names: %s: the %s is %s%s", label, peer.label, shown(other),
							err2 and (" (" .. err2 .. ")") or "")
						done()
					end)
				end)
			end, run.fail)
		end)
	end
end

local function put_task(run, t)
	return function(done)
		names_request(run, "PUT", t.path, body_for(t.kind, t.original), function(r)
			log.always("probe12 names: %s back to %s: %s", t.label, shown(t.original), answer_text(r))
			done()
		end)
	end
end

names_next = function(run)
	if run.finished or run.phase ~= "test" then
		return
	end
	local task = table.remove(run.tasks, 1)
	if not task then
		return enter_restore(run, nil)
	end
	local chain = run.chain
	task(function()
		if run.chain == chain then
			after(1, function() names_next(run) end, run.fail)
		end
	end)
end

local function sorted_by_name(list, name_fn)
	table.sort(list, function(x, y)
		local a, b = name_fn(x) or "", name_fn(y) or ""
		if a ~= b then
			return a < b
		end
		return tostring(x.id) < tostring(y.id)
	end)
	return list
end

local function skip(value)
	return type(value) == "string" and value:lower() == "skip"
end

-- Pick the targets from what the bridge answered (run.data) and the params;
-- returns nil and why when nothing can be tested.
local function choose_targets(run)
	local params, data = run.params, run.data
	local by_id = {}
	for _, kind in ipairs({ "light", "device", "scene", "motion", "area" }) do
		by_id[kind] = {}
		for _, item in ipairs(data[kind] or {}) do
			if type(item) == "table" and valid_rid(item.id) then
				by_id[kind][item.id] = item
			end
		end
	end
	local function device_name(item)
		return name_of("device", item)
	end
	local function lights_of(device)
		local n = 0
		for _, s in ipairs(type(device.services) == "table" and device.services or {}) do
			if type(s) == "table" and s.rtype == "light" then
				n = n + 1
			end
		end
		return n
	end
	-- The light: its Hue device is renamed (T1); a lamp with one light first.
	if not skip(params.Light) then
		local light
		if params.Light and params.Light ~= "" then
			light = by_id.light[params.Light]
			if not light then
				return nil, "no light " .. printable(params.Light)
			end
		else
			local single, any = {}, {}
			for _, item in pairs(by_id.light) do
				local owner = type(item.owner) == "table" and by_id.device[item.owner.rid]
				if owner then
					any[#any + 1] = item
					if lights_of(owner) == 1 then
						single[#single + 1] = item
					end
				end
			end
			local function owner_name(item)
				return device_name(by_id.device[item.owner.rid])
			end
			light = sorted_by_name(#single > 0 and single or any, owner_name)[1]
		end
		local device = light and type(light.owner) == "table" and by_id.device[light.owner.rid]
		if light and device and device_name(device) then
			-- The light first: each restore round then ends with its device,
			-- whose name the Hue app shows, should the two names be coupled.
			if name_of("light", light) then
				run.light = target("light", light.id, name_of("light", light), "light's own name")
				run.targets[#run.targets + 1] = run.light
			end
			run.device = target("device", device.id, device_name(device), "light device")
			run.targets[#run.targets + 1] = run.device
		end
	end
	-- The scene (T2), with another scene of its group for the duplicate.
	if not skip(params.Scene) then
		local scene
		local function group_of(item)
			return type(item.group) == "table" and item.group.rid or nil
		end
		local function sibling_of(item)
			for _, other in pairs(by_id.scene) do
				if other.id ~= item.id and group_of(other) and group_of(other) == group_of(item)
					and name_of("scene", other) and name_of("scene", other) ~= name_of("scene", item) then
					return other
				end
			end
			return nil
		end
		if params.Scene and params.Scene ~= "" then
			scene = by_id.scene[params.Scene]
			if not scene then
				return nil, "no scene " .. printable(params.Scene)
			end
		else
			local with, any = {}, {}
			for _, item in pairs(by_id.scene) do
				if name_of("scene", item) then
					any[#any + 1] = item
					if sibling_of(item) then
						with[#with + 1] = item
					end
				end
			end
			local function scene_name(item)
				return name_of("scene", item)
			end
			scene = sorted_by_name(#with > 0 and with or any, scene_name)[1]
		end
		if scene and name_of("scene", scene) then
			run.scene = target("scene", scene.id, name_of("scene", scene), "scene")
			run.targets[#run.targets + 1] = run.scene
			local sibling = sibling_of(scene)
			run.sibling_name = sibling and name_of("scene", sibling) or nil
		end
	end
	-- The motion sensor's device (its name is the device's).
	if not skip(params.Sensor) then
		local device
		if params.Sensor and params.Sensor ~= "" then
			device = by_id.device[params.Sensor]
			local service = by_id.motion[params.Sensor]
			if not device and service and type(service.owner) == "table" then
				device = by_id.device[service.owner.rid]
			end
			if not device then
				return nil, "no sensor device " .. printable(params.Sensor)
			end
		else
			local owners, seen = {}, {}
			for _, item in pairs(by_id.motion) do
				local owner = type(item.owner) == "table" and by_id.device[item.owner.rid]
				if owner and not seen[owner.id] and (not run.device or owner.id ~= run.device.rid) then
					seen[owner.id] = true
					owners[#owners + 1] = owner
				end
			end
			device = sorted_by_name(owners, device_name)[1]
		end
		if device and device_name(device) then
			run.sensor = target("device", device.id, device_name(device), "sensor device")
			run.targets[#run.targets + 1] = run.sensor
		end
	end
	-- The MotionAware area (T3).
	if not skip(params.Area) then
		local area
		if params.Area and params.Area ~= "" then
			area = by_id.area[params.Area]
			if not area then
				return nil, "no MotionAware area " .. printable(params.Area)
			end
		else
			local list = {}
			for _, item in pairs(by_id.area) do
				list[#list + 1] = item
			end
			local function area_name(item)
				return name_of("area", item)
			end
			area = sorted_by_name(list, area_name)[1]
		end
		if area and name_of("area", area) then
			run.area = target("area", area.id, name_of("area", area), "MotionAware area")
			run.targets[#run.targets + 1] = run.area
		end
	end
	if #run.targets == 0 then
		return nil, "nothing to test on this bridge"
	end
	for _, t in ipairs(run.targets) do
		if t.original:sub(1, #probe12.MARK) == probe12.MARK then
			return nil, string.format('%s %s is already called "%s": an earlier run was interrupted; give it its name '
				.. "back by hand or with Probe Names Restore", t.label, t.rid, printable(t.original))
		end
	end
	return true
end

local NAME_33 = (probe12.MARK .. " 33 characters " .. string.rep("x", 33)):sub(1, 33)
local E_32 = string.rep("\195\169", 32)

local function plan_tests(run)
	local tasks = {}
	if run.device then
		-- T1: the device's name, which the Hue app shows; then the light's own
		-- (deprecated) name, which N31 would write for a multi-light device.
		tasks[#tasks + 1] = test_task(run, run.device, probe12.MARK .. " light", "light device", run.light)
		tasks[#tasks + 1] = test_task(run, run.device, NAME_33, "light device 33 characters", nil)
		if run.light then
			tasks[#tasks + 1] = test_task(run, run.light, probe12.MARK .. " light name", "light's own name", run.device)
			tasks[#tasks + 1] = put_task(run, run.light)
		end
		tasks[#tasks + 1] = put_task(run, run.device)
	end
	if run.scene then
		tasks[#tasks + 1] = test_task(run, run.scene, probe12.MARK .. " scene", "scene", nil)
		if run.sibling_name then
			tasks[#tasks + 1] = test_task(run, run.scene, run.sibling_name, "scene duplicate in its group", nil)
		end
		tasks[#tasks + 1] = test_task(run, run.scene, NAME_33, "scene 33 characters", nil)
		tasks[#tasks + 1] = test_task(run, run.scene, E_32, "scene 32 \195\169", nil)
		tasks[#tasks + 1] = put_task(run, run.scene)
	end
	if run.sensor then
		tasks[#tasks + 1] = test_task(run, run.sensor, probe12.MARK .. " sensor", "sensor device", nil)
		tasks[#tasks + 1] = put_task(run, run.sensor)
	end
	if run.area then
		tasks[#tasks + 1] = test_task(run, run.area, probe12.MARK .. " area", "MotionAware area", nil)
		tasks[#tasks + 1] = put_task(run, run.area)
	end
	return tasks
end

local READS = {
	{ kind = "light", path = "/clip/v2/resource/light" },
	{ kind = "device", path = "/clip/v2/resource/device" },
	{ kind = "scene", path = "/clip/v2/resource/scene" },
	{ kind = "motion", path = "/clip/v2/resource/motion" },
	{ kind = "area", path = "/clip/v2/resource/motion_area_configuration", optional = true },
}

local function names_discover(run, i)
	if run.finished then
		return
	end
	local read = READS[i]
	if not read then
		local ok, why = choose_targets(run)
		if not ok then
			return finish_names(run, { restored = true, text = "nothing sent: " .. why })
		end
		for _, t in ipairs(run.targets) do
			log.always("probe12 names: target %s %s, now %s", t.label, t.rid, shown(t.original))
		end
		if run.sibling_name then
			log.always("probe12 names: duplicate test with the name of another scene of the group: %s",
				shown(run.sibling_name))
		end
		if not save_pending(run) then
			return finish_names(run, { restored = true, text = "nothing sent: the restore list could not be persisted" })
		end
		run.phase = "test"
		run.tasks = plan_tests(run)
		return names_next(run)
	end
	names_request(run, "GET", read.path, nil, function(r)
		if not r.ok and not read.optional then
			return finish_names(run, { restored = true, text = "nothing sent: GET " .. read.path .. " " .. answer_text(r) })
		end
		run.data[read.kind] = items_of(r)
		log.always("probe12 names: GET %s: %s, %d item(s)", read.path, answer_text(r), #run.data[read.kind])
		after(1, function() names_discover(run, i + 1) end, run.fail)
	end)
end

local function new_names_run(params)
	local run = { params = params or {}, phase = "discover", chain = 1, data = {}, targets = {}, results = {},
		tasks = {}, t0 = now_ms() }
	run.fail = function(err)
		if run.finished then
			return
		end
		log.always("probe12 names: error %s", tostring(err))
		if run.phase == "restore" then
			finish_names(run, { restored = false, text = "an error in the restore: " .. tostring(err) })
		else
			enter_restore(run, "an error")
		end
	end
	return run
end

local function start_restore_only(targets, then_text)
	local run = new_names_run({})
	run.restore_only = true
	run.targets = targets
	run.then_text = then_text
	names_run = run
	log.always("probe12 names: restoring %d name(s) an earlier run persisted", #targets)
	enter_restore(run, nil)
end

function probe12.names(params)
	if names_run then
		return say("Probe Names: already running; wait for its summary")
	end
	local why = names_refusal()
	if why then
		return say("Probe Names refused: " .. why .. "; nothing was sent")
	end
	local pending = load_pending()
	if pending then
		return start_restore_only(pending, "an earlier run had left names to restore: run Probe Names again")
	end
	local run = new_names_run(params)
	names_run = run
	log.always("probe12 names: started (test cap %d s, restore cap %d s)", math.floor(probe12.NAMES_TEST_CAP_MS / 1000),
		math.floor(probe12.NAMES_RESTORE_CAP_MS / 1000))
	run.test_timer = after(probe12.NAMES_TEST_CAP_MS, function()
		if run.phase == "test" then
			enter_restore(run, string.format("the %d s test cap", math.floor(probe12.NAMES_TEST_CAP_MS / 1000)))
		elseif run.phase == "discover" then
			finish_names(run, { restored = true, text = "nothing sent: the bridge did not answer the reads in time" })
		end
	end, run.fail)
	names_discover(run, 1)
end

function probe12.names_restore()
	if names_run then
		return say("Probe Names Restore: Probe Names is running; it restores by itself")
	end
	local why = names_refusal()
	if why then
		return say("Probe Names Restore refused: " .. why .. "; nothing was sent")
	end
	local pending = load_pending()
	if not pending then
		return say("Probe Names Restore: nothing to restore")
	end
	start_restore_only(pending, nil)
end

-- The picker test (Add From Hue's folders, docs/simplify-actions-design.md §1.2 and D9)

probe12.PICKER_LIST = "Probe12PickerList"
probe12.PICKER_ROOMS = "Probe12RoomList"
probe12.ASYNC_MS = 300

local function two(n)
	return string.format("%02d", n)
end

local ROOM_NAMES = { "Living room", "Kitchen", "Dining room", "Hallway", "Bedroom", "Bathroom", "Office", "Garage",
	"Garden", "Guest room", "Stairs", "Porch" }

-- The tree, built once: folder value -> { list, back }.
local tree
local function picker_tree()
	if tree then
		return tree
	end
	tree = {}
	local lights, groups, scenes, sensors, areas = {}, {}, {}, {}, {}
	for i = 1, 48 do
		lights[#lights + 1] = { text = string.format("Light %s - %s", two(i), ROOM_NAMES[(i - 1) % 12 + 1]),
			value = "light:" .. two(i) }
	end
	for i = 1, 12 do
		groups[#groups + 1] = { text = string.format("%s (room %s)", ROOM_NAMES[i], two(i)), value = "room:" .. two(i) }
	end
	for i = 1, 8 do
		groups[#groups + 1] = { text = string.format("Zone %s", two(i)), value = "zone:" .. two(i) }
	end
	for r = 1, 10 do
		local folder = "f:scenes:" .. two(r)
		scenes[#scenes + 1] = { text = string.format("%s (10 scenes)", ROOM_NAMES[r]), value = folder, folder = true,
			selectable = true }
		local list = { { text = string.format("All 10 scenes of %s", ROOM_NAMES[r]), value = "scenes-of:" .. two(r) } }
		for s = 1, 10 do
			list[#list + 1] = { text = string.format("Scene %s of %s", two(s), ROOM_NAMES[r]),
				value = string.format("scene:%s:%s", two(r), two(s)) }
		end
		tree[folder] = { list = list, back = "f:scenes" }
	end
	for i = 1, 12 do
		sensors[#sensors + 1] = { text = string.format("Motion sensor %s - %s", two(i), ROOM_NAMES[i]),
			value = "sensor:" .. two(i) }
	end
	for i = 1, 8 do
		areas[#areas + 1] = { text = string.format("MotionAware area %s", two(i)), value = "area:" .. two(i) }
	end
	local edge = {
		{ text = "Comma, in the name", value = "edge:comma,inside" },
		{ text = "Quote \" and apostrophe '", value = "edge:quote\"'" },
		{ text = "Ampersand & <angle> brackets", value = "edge:amp&<x>" },
		{ text = "Accents: Pi\195\168ce \195\169clair\195\169e", value = "edge:utf8-\195\169" },
		{ text = "Emoji \240\159\146\161 lamp", value = "edge:emoji-\240\159\146\161" },
		{ text = "A long name: " .. string.rep("abcdefghij", 8), value = "edge:long" },
	}
	tree["f:lights"] = { list = lights, back = "" }
	tree["f:groups"] = { list = groups, back = "" }
	tree["f:scenes"] = { list = scenes, back = "" }
	tree["f:sensors"] = { list = sensors, back = "" }
	tree["f:areas"] = { list = areas, back = "" }
	tree["f:edge"] = { list = edge, back = "" }
	tree["f:async"] = { back = "", async = true, list = {
		{ text = "Async 01", value = "async:01" }, { text = "Async 02", value = "async:02" },
		{ text = "Async 03", value = "async:03" }, { text = "Async 04", value = "async:04" },
		{ text = "Async 05", value = "async:05" } } }
	tree[""] = { list = {
		{ text = "Import all new (a plain entry)", value = "import:all" },
		{ text = "Lights (48)", value = "f:lights", folder = true },
		{ text = "Zones and rooms (20)", value = "f:groups", folder = true },
		{ text = "Scenes (110 in 10 rooms)", value = "f:scenes", folder = true },
		{ text = "Motion sensors (12)", value = "f:sensors", folder = true },
		{ text = "MotionAware areas (8)", value = "f:areas", folder = true },
		{ text = "Edge cases (6)", value = "f:edge", folder = true },
		{ text = "Filled later through done (5)", value = "f:async", folder = true },
	} }
	return tree
end

local function args_text(...)
	local out = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		out[#out + 1] = type(v) == "string" and ('"' .. printable(v) .. '"') or type(v)
	end
	return table.concat(out, ", ")
end

-- The CUSTOM_SELECT list function (global Probe12PickerList): the folder
-- value Composer passes (empty at the root), and, when Composer passes one,
-- the function to answer later with (FUND 15_composerpro_interface_into_the_sdk/_4).
function probe12.picker_list(...)
	local folder, done = ...
	log.always("probe12 picker: %s called with %d argument(s): %s", probe12.PICKER_LIST, select("#", ...),
		args_text(...))
	local key = type(folder) == "string" and folder or ""
	local node = picker_tree()[key]
	if not node then
		log.always("probe12 picker: no folder %q; the root instead", printable(key))
		node = picker_tree()[""]
	end
	local back = key ~= "" and node.back or nil
	if node.async then
		if type(done) == "function" then
			after(probe12.ASYNC_MS, function()
				log.always("probe12 picker: answering folder %s through done after %d ms", key, probe12.ASYNC_MS)
				done(node.list, back)
			end)
			return
		end
		local list = { { text = "(no done function was passed: filled at once)", value = "async:none" } }
		for _, entry in ipairs(node.list) do
			list[#list + 1] = entry
		end
		return list, back
	end
	return node.list, back
end

local ROOMS = { { text = "Room A (probe)", value = "c4room:a" }, { text = "Room B (probe)", value = "c4room:b" },
	{ text = "Room C (probe)", value = "c4room:c" } }

-- The second picker (global Probe12RoomList): what it is given shows whether
-- a picker sees the other parameter's choice.
function probe12.room_list(...)
	log.always("probe12 picker: %s called with %d argument(s): %s", probe12.PICKER_ROOMS, select("#", ...),
		args_text(...))
	return ROOMS
end

-- What a value of the pickers stands for.
function probe12.describe(value)
	local v = tostring(value)
	local r, s = v:match("^scene:(%d+):(%d+)$")
	if r then
		return string.format("scene %s of room %s", s, r)
	end
	local patterns = {
		{ "^import:all$", function() return "Import all new" end },
		{ "^light:(%d+)$", function(n) return "light " .. n end },
		{ "^room:(%d+)$", function(n) return "Hue room " .. n end },
		{ "^zone:(%d+)$", function(n) return "Hue zone " .. n end },
		{ "^f:scenes:(%d+)$", function(n) return "the folder of room " .. n .. " (a selectable folder: all its scenes)" end },
		{ "^f:(.+)$", function(n) return "the folder " .. n .. " (not selectable)" end },
		{ "^scenes%-of:(%d+)$", function(n) return "all scenes of room " .. n end },
		{ "^sensor:(%d+)$", function(n) return "motion sensor " .. n end },
		{ "^area:(%d+)$", function(n) return "MotionAware area " .. n end },
		{ "^async:(.+)$", function(n) return "async entry " .. n end },
		{ "^c4room:(%a)$", function(n) return "Room " .. n:upper() end },
		{ "^edge:(.+)$", function(n) return "edge case " .. printable(n) end },
	}
	for _, p in ipairs(patterns) do
		local m = v:match(p[1])
		if m then
			return p[2](m)
		end
	end
	return "not a value these pickers offered"
end

-- The DEV-ONLY test action (Probe Picker Folders): every parameter Composer
-- sent, exactly (escaped, and as hex when not plain ASCII), and what each
-- value stands for; a value with commas that no entry has is also read as a
-- list (multi-pick).
function probe12.picker_action(params)
	params = type(params) == "table" and params or {}
	local keys = {}
	for k in pairs(params) do
		keys[#keys + 1] = tostring(k)
	end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		local v = params[k]
		local text = tostring(v)
		log.always("probe12 picker: param \"%s\" (%s, %d bytes) = \"%s\"%s", printable(k), type(v), #text,
			printable(text), text:find("[^\32-\126]") and (" hex " .. hex(text, 400)) or "")
		local meaning = probe12.describe(text)
		if meaning == "not a value these pickers offered" and text:find(",", 1, true) then
			local pieces = {}
			for piece in text:gmatch("[^,]+") do
				pieces[#pieces + 1] = probe12.describe(piece)
			end
			meaning = string.format("%d values? %s", #pieces, table.concat(pieces, " | "))
		end
		parts[#parts + 1] = string.format('%s = "%s" (%s)', printable(k), printable(text), meaning)
	end
	if #parts == 0 then
		return say("Picker test: Composer sent no parameters")
	end
	say("Picker test: " .. table.concat(parts, "; "))
end

-- Probe Picker (signed): one folder's list, as Composer would get it.
function probe12.picker_dump(params)
	params = params or {}
	local folder = params.Folder or ""
	local function show(l, back)
		local count = type(l) == "table" and #l or 0
		local texts = {}
		for i = 1, math.min(count, 12) do
			local e = l[i]
			texts[#texts + 1] = string.format("%s=%s%s", printable(e.value), printable(e.text),
				e.folder and (e.selectable and " [folder, selectable]" or " [folder]") or "")
		end
		log.always("probe12 picker: folder \"%s\": %d entries, back %s: %s%s", printable(folder), count,
			back == nil and "none" or ('"' .. printable(back) .. '"'), table.concat(texts, "; "), count > 12 and "; ..." or "")
		say(string.format('Probe Picker: folder "%s" has %d entries', printable(folder), count))
	end
	local l, b = probe12.picker_list(folder, function(dl, db) show(dl, db) end)
	if l ~= nil then
		show(l, b)
	end
end

-- Install --------------------------------------------------------------------

-- `given`: the devtools context (bridge/devtools.lua). Defines the pickers'
-- two global list functions, which Director calls by name.
function probe12.install(given)
	ctx = given
	rawset(_G, probe12.PICKER_LIST, probe12.picker_list)
	rawset(_G, probe12.PICKER_ROOMS, probe12.room_list)
end

-- For the specs: whether a run is in progress, and the wrapped globals.
function probe12.running()
	return { discovery = disco ~= nil, names = names_run ~= nil, wrapped = hooks ~= nil }
end

return probe12
