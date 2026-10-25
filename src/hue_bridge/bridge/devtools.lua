-- Development handlers of the Hue Bridge driver, dev builds only. tools/build.sh
-- ships this module with common/devloop.lua, bridge/conntest.lua and
-- bridge/pinning.lua in `--dev` builds and leaves all four out of release
-- builds (with the DEV-ONLY blocks of driver.xml), so a release driver
-- carries none of this code. Here live the dev loop's `Dev Server` property,
-- the arbitrary request and the project probes reached through
-- `tools/devctl.py run`, the light path's Proxy Command and Lights Report,
-- the device drivers' forwarded log lines (HUE_LOG), the Reload Credentials,
-- Check CA Pinning and Connection Test actions, and Test Connection's Host
-- override. See docs/dev-loop.md.
--
-- driver.lua loads this module only when common/devloop.lua is present and
-- hands over what the handlers need in devtools.install(ctx); nothing here
-- reaches into the driver's locals.
--
-- ExecuteCommand has no sender parameter
-- [verified: API 5_director_command/_1-ExecuteCommand], so whatever sits in
-- dispatch.commands any driver in the project can run with C4:SendToDevice.
-- Only what Composer itself sends (the DEV-ONLY actions of driver.xml) and
-- the devices' HUE_LOG go there; the requests, probes and proxy commands
-- run only for commands the dev loop verified (devloop.set_signed_commands),
-- and the loop's redactor keeps the application key out of every shipped
-- line [security review 2026-10-25, finding 9].

local log = require("common.log")
local dispatch = require("common.dispatch")
local http = require("bridge.http")
local credentials = require("bridge.credentials")
local lights_mod = require("bridge.lights")
local devloop = require("common.devloop")
local conntest = require("bridge.conntest")
local pinning = require("bridge.pinning")

local devtools = {}

-- Set by devtools.install:
--   state                    the driver's state table: ip, creds, identity_ok,
--                            lights, scenes, zone_lights, queue, stream,
--                            late_init_done
--   prop(name, value)        write a property
--   connection()             { ip, key } when paired with an address, else nil
--   paired()                 whether credentials are held
--   bridge_request(req, cb)  an authenticated request on the dotted address
--   restart_stream(force)    rebuild the event stream and start it again
--   test_connection(host)    the Test Connection action against `host`
local ctx

local function trimmed(value)
	return (value or ""):match("^%s*(.-)%s*$")
end

-- Whether `host` spells the bridge's address `ip` (the dotted form the Bridge
-- IP Address property holds) the way bridge/altaddr.lua writes it: an octet
-- below 8 with up to two leading zeros (curl reads a leading zero as octal,
-- which changes nothing below 8), every other octet as it is. Hue Request
-- and Test Connection take no other Host, so the application key goes only
-- to the bridge's address [security review 2026-10-24, finding 15].
function devtools.spells_bridge_address(host, ip)
	if type(host) ~= "string" or type(ip) ~= "string" then
		return false
	end
	local want = { ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
	local got = { host:match("^(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)%.(%d%d?%d?)$") }
	if #want ~= 4 or #got ~= 4 then
		return false
	end
	for i = 1, 4 do
		local octet = tonumber(want[i])
		if got[i] ~= want[i] and not (octet < 8 and tonumber(got[i]) == octet) then
			return false
		end
	end
	return true
end

-- The Host a development request may use: the dotted address when `given`
-- is empty, `given` when it spells the bridge's address, else nil and the
-- refusal to show.
local function request_host(given)
	local host = trimmed(given)
	if host == "" then
		return ctx.state.ip
	end
	if devtools.spells_bridge_address(host, ctx.state.ip) then
		return host
	end
	return nil, string.format("Host %q refused: not a spelling of the bridge address %s", host,
		tostring(ctx.state.ip))
end

-- Why Hue Request must not use `path`, or nil. bridge/http.lua builds
-- "https://" .. host .. path, so a Path that does not start with "/" moves
-- the request, key and all, to another host or port ("@203.0.113.9/...",
-- ".example.net/...", ":8443/..."); "@", "\", "#", white space and other
-- control characters are refused as well, since URL parsers disagree on
-- them [security review 2026-10-25, finding 10].
local function path_refusal(path)
	if type(path) ~= "string" or path:sub(1, 1) ~= "/" then
		return 'it must start with "/"'
	end
	if path:find("[@\\#%s%c]") then
		return 'it must hold no "@", "\\", "#", white space or control characters'
	end
	return nil
end

-- host:port of tools/devserver.py; empty disables the loop.
local function dev_server_changed(value)
	local host = trimmed(value)
	if host == "" then
		devloop.stop()
	elseif ctx.state.late_init_done then
		log.always("dev loop: starting against %s", host)
		devloop.start(host)
	end
end

-- Not in driver.xml, reachable only through signed dev loop commands: an
-- arbitrary authenticated request to the bridge. Params: Method
-- (GET/PUT/POST/DELETE; any other, PATCH for one, fails in bridge/http.lua
-- with "could not start transfer: ... unsupported method PATCH", logged as
-- the result), Path (/clip/v2/...; optional, default the bridge resource;
-- see path_refusal), Body (JSON text, optional), Host (a spelling of the
-- bridge's address, see spells_bridge_address; optional, default the dotted
-- address; any other host is refused and nothing is sent), Raw ("true" logs
-- the whole body). Like every keyed request of the driver it waits for the
-- bridge identity check (driver.lua, bridge_request). Logs the status,
-- elapsed time and a summary of the response: ids and names for resource
-- lists, otherwise the first 300 characters of the body.
local function hue_request(params)
	params = params or {}
	if not ctx.connection() then
		return log.always("Hue Request: not paired")
	end
	if ctx.state.identity_ok ~= true then
		return log.always("Hue Request: bridge identity not verified yet; see Status")
	end
	local method = (params.Method or "GET"):upper()
	local path = params.Path
	if path == nil or path == "" then
		path = "/clip/v2/resource/bridge"
	end
	local bad = path_refusal(path)
	if bad then
		return log.always("Hue Request: Path %q refused: %s; nothing is sent", (tostring(path):gsub("%c", "?")), bad)
	end
	local host, refusal = request_host(params.Host)
	if not host then
		return log.always("Hue Request: %s", refusal)
	end
	local body
	if params.Body and params.Body ~= "" then
		body = C4:JsonDecode(params.Body)
		if body == nil then
			return log.always("Hue Request: Body is not valid JSON")
		end
	end
	local t0 = os.time()
	http.request({ ip = host, key = ctx.state.creds.key, method = method, path = path, body = body }, function(r)
		local summary
		local items = r.json and type(r.json.data) == "table" and r.json.data or nil
		if items and #items == 1 and items[1].type == "light" then
			-- A single light: show the fields that matter for state tests.
			local it = items[1]
			summary = string.format("%s on=%s brightness=%s mirek=%s valid=%s xy=%s,%s",
				it.metadata and it.metadata.name or it.id, tostring(it.on and it.on.on),
				tostring(it.dimming and it.dimming.brightness),
				tostring(it.color_temperature and it.color_temperature.mirek),
				tostring(it.color_temperature and it.color_temperature.mirek_valid),
				tostring(it.color and it.color.xy and it.color.xy.x), tostring(it.color and it.color.xy and it.color.xy.y))
		elseif items and #items > 0 and items[1].id then
			local parts = {}
			for i = 1, math.min(#items, 15) do
				local item = items[i]
				local name = item.metadata and item.metadata.name or item.type or "?"
				parts[#parts + 1] = string.format("%s=%s", item.id, tostring(name))
			end
			summary = string.format("%d items: %s", #items, table.concat(parts, "; "))
		else
			summary = tostring(r.body or ""):sub(1, 300)
		end
		log.always("Hue Request %s %s via %s: %s in %d s, %d bytes: %s", method, path, host,
			r.ok and ("HTTP " .. tostring(r.code)) or tostring(r.err), os.time() - t0, #tostring(r.body or ""), summary)
		if params.Raw == "true" and r.body then
			-- The whole body, in pieces a log line can carry: for recording
			-- fixtures of resources the driver does not summarise.
			local text = tostring(r.body)
			local pieces = math.ceil(#text / 800)
			for i = 1, #text, 800 do
				log.always("Hue Request body %d/%d: %s", math.ceil(i / 800), pieces, text:sub(i, i + 799))
			end
		end
	end)
end

-- Probes for docs/import-design.md §11: what the project APIs return on this
-- controller, and whether misuse errors or stays silent.
local function log_dump(label, value)
	local text = lights_mod.dump(value)
	local pieces = math.ceil(#text / 800)
	for i = 1, #text, 800 do
		log.always("%s %d/%d: %s", label, math.ceil(i / 800), pieces, text:sub(i, i + 799))
	end
end

local function probe(label, fn)
	local ok, result = pcall(fn)
	if ok then
		log_dump(label, result)
	else
		log.always("%s: error %s", label, tostring(result))
	end
end

local function probe_project()
	probe("GetProjectHierarchy", function() return C4:GetProjectHierarchy() end)
	probe("GetDevicesByC4iName roomdevice.c4i", function() return C4:GetDevicesByC4iName("roomdevice.c4i") end)
	probe("GetDevices hue_light.c4z", function()
		local devices = C4:GetDevices({ C4iNames = "hue_light.c4z" })
		local count, first = 0, nil
		for id, info in pairs(devices or {}) do
			count = count + 1
			if not first or tostring(id) < tostring(first.id) then
				first = { id = id, info = info }
			end
		end
		return { count = count, first = first }
	end)
	probe("GetBoundConsumerDevices binding 1", function() return C4:GetBoundConsumerDevices(C4:GetDeviceID(), 1) end)
end

local function probe_errors()
	probe("UpdateProperty Nonexistent", function() return C4:UpdateProperty("Nonexistent", "x") end)
	probe("SendToDevice 99999", function() return C4:SendToDevice(99999, "HUE_STATE", { rid = "probe" }) end)
end

-- Probe Scenes (groundwork for the scenes feature): every scene and smart
-- scene on the bridge with its group, status and dynamics.
local function probe_scenes()
	if not ctx.connection() then
		return log.always("Probe Scenes: not paired")
	end
	local groups = ctx.state.lights and ctx.state.lights.groups
	local function str(v)
		if v == nil or type(v) == "table" then return "-" end -- JSON null decodes to {}
		return tostring(v)
	end
	local function label(ref)
		local rid = type(ref) == "table" and ref.rid or nil
		local text = (groups and groups.label) and groups:label(rid) or "?"
		return text .. " " .. tostring(rid or ""):sub(1, 8)
	end
	ctx.bridge_request({ method = "GET", path = "/clip/v2/resource/scene" }, function(r)
		local items = r.json and type(r.json.data) == "table" and r.json.data or {}
		log.always("Probe Scenes: %s, %d scenes, %d bytes", r.ok and ("HTTP " .. tostring(r.code)) or tostring(r.err),
			#items, #tostring(r.body or ""))
		local per_group, lines = {}, {}
		for _, s in ipairs(items) do
			local g = label(s.group)
			per_group[g] = (per_group[g] or 0) + 1
			lines[#lines + 1] = string.format("%s %q [%s] %s%s%s", tostring(s.id):sub(1, 8),
				str(s.metadata and s.metadata.name), g, str(type(s.status) == "table" and s.status.active),
				s.auto_dynamic == true and " dynamic" or "", type(s.speed) == "number" and (" speed " .. s.speed) or "")
		end
		table.sort(lines)
		for i = 1, #lines, 3 do
			log.always("  %s", table.concat(lines, " | ", i, math.min(i + 2, #lines)))
		end
		local summary = {}
		for g, n in pairs(per_group) do summary[#summary + 1] = g .. "=" .. n end
		table.sort(summary)
		log.always("  scenes per group: %s", table.concat(summary, "; "))
		ctx.bridge_request({ method = "GET", path = "/clip/v2/resource/smart_scene" }, function(r2)
			local smart = r2.json and type(r2.json.data) == "table" and r2.json.data or {}
			log.always("Probe Scenes: %d smart scenes, %d bytes", #smart, #tostring(r2.body or ""))
			for _, s in ipairs(smart) do
				log.always("  %s %q [%s] state=%s slot=%s", tostring(s.id):sub(1, 8), str(s.metadata and s.metadata.name),
					label(s.group), str(s.state), str(type(s.active_timeslot) == "table" and s.active_timeslot.timeslot_id))
			end
		end)
	end)
end

-- The credential store's names, taken from bridge/credentials.lua, which
-- keeps them to itself: its load() runs once against a stand-in C4 that
-- notes the name each call asks for and answers nil, and the real C4 is
-- back before this returns. nil when that yields no name (a credentials.lua
-- that stopped looking C4 up as a global, say, whose load() then read the
-- real store into a table nobody keeps): the caller then refuses every
-- Persist call. The names are never logged.
local function credential_store_names()
	local names = {}
	local stand_in = setmetatable({}, {
		__index = function()
			return function(_, name)
				if type(name) == "string" then names[#names + 1] = name end
				return nil
			end
		end,
	})
	local real = rawget(_G, "C4")
	rawset(_G, "C4", stand_in)
	local ok = pcall(credentials.load)
	rawset(_G, "C4", real)
	if not ok or #names == 0 then
		return nil
	end
	return names
end

-- How a store name compares. How Director matches names (case, padding, a
-- NUL that ends a C string) is not documented, so the comparison is loose
-- and refuses more than it must.
local function store_key(name)
	return (name:match("^[^%z]*"):match("^%s*(.-)%s*$"):lower())
end

-- Why Probe Call must not run C4[fn] with `args`, or nil. The persistent
-- store holds the application key (bridge/credentials.lua), so a Persist
-- call [verified: API 26.5_persistence] must name one entry, and not one of
-- the credential store's; one that names none, PersistDeleteAll, would
-- delete them with everything else [security review 2026-10-25, finding 9].
local function persist_refusal(fn, args)
	if not fn:lower():find("^%s*persist") then
		return nil
	end
	if type(args[1]) ~= "string" then
		return "a Persist call must name one store entry as its first argument"
	end
	local names = credential_store_names()
	if not names then
		return "the credential store's names could not be read"
	end
	local wanted = store_key(args[1])
	for _, name in ipairs(names) do
		if store_key(name) == wanted then
			return "its first argument names a credential store entry"
		end
	end
	return nil
end

-- Probe Call (signed dev loop commands only): any C4 method by name,
-- arguments as a JSON array, result dumped; Persist calls on the credential
-- store are refused (persist_refusal).
-- e.g. Fn=GetDevices Args=[{"DeviceIds":[1080]}]; Fn=GetDeviceDisplayName Args=[1081]
local function probe_call(params)
	params = params or {}
	local fn = tostring(params.Fn or "")
	local args = {}
	if params.Args and params.Args ~= "" then
		args = C4:JsonDecode(params.Args)
		if type(args) ~= "table" then
			return log.always("Probe Call: Args is not a JSON array")
		end
	end
	if type(C4[fn]) ~= "function" then
		return log.always("Probe Call: C4.%s is not a function", fn)
	end
	local refusal = persist_refusal(fn, args)
	if refusal then
		-- Neither the arguments nor the store's names go into the line.
		return log.always("Probe Call: C4.%s refused: %s; nothing was called", fn, refusal)
	end
	probe("C4:" .. fn .. "(" .. tostring(params.Args or "") .. ")", function()
		return C4[fn](C4, unpack(args))
	end)
end

-- A light or scene driver's own log line (dev builds forward info and
-- above), so it shows up in this driver's output and in the dev loop's
-- shipped log. The devices send it with C4:SendToDevice (common/devloop.lua,
-- forward_logs), which arrives through ExecuteCommand, so this is the one
-- development handler that stays in dispatch.commands, where any driver in
-- the project reaches it. All it does is print one line under the sender's
-- name; control characters become spaces, so a message cannot forge further
-- lines of the shipped log.
local function hue_log(params)
	params = params or {}
	local who = "light"
	if params.rid and params.rid ~= "" then
		local entry = ctx.state.lights and ctx.state.lights.registry and ctx.state.lights.registry[params.rid]
		who = (entry and entry.name) or tostring(params.rid):sub(1, 8)
	end
	log.always("[%s] %s", (tostring(who):gsub("%c", " ")), (tostring(params.line):gsub("%c", " ")))
end

-- Find a registered light by rid, Hue name or protocol device id.
local function find_light(key)
	local registry = ctx.state.lights and ctx.state.lights.registry or {}
	if registry[key] then return key, registry[key] end
	local wanted = tostring(key):lower()
	for rid, entry in pairs(registry) do
		if tostring(entry.device_id) == wanted or (entry.name or ""):lower() == wanted then
			return rid, entry
		end
	end
	return nil
end

-- A zone light or scene device by its device id or its Composer or Hue
-- name (dev builds only): { device_id, name } or nil.
local function find_group_device(key)
	local wanted = tostring(key):lower()
	for _, module in ipairs({ ctx.state.zone_lights, ctx.state.scenes }) do
		local registry = module and module.registry or {}
		for rid, entry in pairs(registry) do
			if type(entry) == "table" and entry.device_id then
				local display = C4:GetDeviceDisplayName(tonumber(entry.device_id) or 0)
				if rid == key or tostring(entry.device_id) == wanted or (entry.name or ""):lower() == wanted
					or (display and tostring(display):lower() == wanted) then
					return { device_id = entry.device_id, name = entry.name or display or rid }
				end
			end
		end
	end
	return nil
end

-- Not in driver.xml, reachable only through signed dev loop commands: a
-- light_v2 proxy command to one light, zone light or scene device, the way
-- a Navigator or programming would send it, so the whole command path can
-- be exercised from the dev loop. Params: Light (rid, Hue name or protocol
-- device id), Command (e.g. SET_BRIGHTNESS_TARGET), and the command's own
-- params (e.g. LIGHT_BRIGHTNESS_TARGET=50 RATE=0).
local function proxy_command(params)
	params = params or {}
	local lights = ctx.state.lights
	local rid, entry = find_light(params.Light or "")
	if not rid then
		-- A zone light or a scene device: its light_v2 proxy is the consumer
		-- of its binding 5001, as for a light.
		local group = find_group_device(params.Light or "")
		if not group then
			return log.always("Proxy Command: no registered light, zone light or scene matches %q",
				tostring(params.Light))
		end
		local consumers = C4:GetBoundConsumerDevices(tonumber(group.device_id), 5001)
		local gproxy = type(consumers) == "table" and next(consumers) or nil
		if not gproxy then
			return log.always("Proxy Command: no proxy found for %s (device %s)", group.name, tostring(group.device_id))
		end
		local command = params.Command or "SET_BRIGHTNESS_TARGET"
		local forwarded = {}
		for k, v in pairs(params) do
			if k ~= "Light" and k ~= "Command" then forwarded[k] = v end
		end
		C4:SendToDevice(gproxy, command, forwarded)
		return log.always("Proxy Command: %s -> %s (proxy %s): %s", command, group.name, tostring(gproxy),
			C4:JsonEncode(forwarded))
	end
	local proxy = lights:proxy_for(rid)
	if not proxy then
		-- The protocol driver provides binding 5001 (driver.xml: consumer
		-- False) and its light_v2 proxy consumes it, so the proxy is a bound
		-- consumer of that binding. Seen on hardware: proxy id = protocol id + 1.
		local consumers = C4:GetBoundConsumerDevices(entry.device_id, 5001)
		if type(consumers) == "table" then proxy = next(consumers) end
		if proxy and lights.registry[rid] then
			lights.registry[rid].proxy_id = proxy
			lights:save()
		end
	end
	if not proxy then
		return log.always("Proxy Command: no proxy found for %s (device %s)", entry.name, tostring(entry.device_id))
	end
	local command = params.Command or "SET_BRIGHTNESS_TARGET"
	local forwarded = {}
	for k, v in pairs(params) do
		if k ~= "Light" and k ~= "Command" then forwarded[k] = v end
	end
	C4:SendToDevice(proxy, command, forwarded)
	log.always("Proxy Command: %s -> %s (proxy %s): %s", command, entry.name, tostring(proxy),
		C4:JsonEncode(forwarded))
end

-- A summary of the light registry (signed dev loop commands only: it lists
-- the radios' MAC addresses). Param Limit (default 5).
local function lights_report(params)
	params = params or {}
	local state = ctx.state
	local limit = tonumber(params.Limit) or 5
	local registry = state.lights and state.lights.registry or {}
	local names = {}
	for rid, entry in pairs(registry) do names[#names + 1] = { rid = rid, entry = entry } end
	table.sort(names, function(a, b) return (a.entry.name or "") < (b.entry.name or "") end)
	local tombstones = state.lights.reg and state.lights.reg:tombstones() or {}
	local deleted = 0
	for _ in pairs(tombstones) do deleted = deleted + 1 end
	log.always("Lights Report: %d registered, %d deleted in Composer, queue %s", #names, deleted,
		C4:JsonEncode(state.queue:stats()))
	-- The owner-facing texts, for dev builds whose installed driver.xml
	-- predates the properties.
	log.always("  Lights: %s", state.lights:summary())
	log.always("  Attention: %s", state.lights:attention())
	log.always("  Room Mappings: %s", state.lights:room_mappings_text())
	log.always("  Scenes: %s", state.scenes:summary())
	log.always("  Zone Lights: %s", state.zone_lights:summary())
	for i = 1, math.min(limit, #names) do
		local e = names[i].entry
		local caps = e.caps or {}
		log.always("  %s: device %s proxy %s rid %s %s id_v1=%s room=%s mac=%s color=%s cct=%s mirek %s-%s",
			tostring(e.name), tostring(e.device_id), tostring(e.proxy_id), names[i].rid, tostring(e.state),
			tostring(e.id_v1), tostring(e.hue_room), tostring(e.mac_address),
			tostring(caps.has_color), tostring(caps.has_cct), tostring(caps.mirek_min), tostring(caps.mirek_max))
	end
	for rid, tomb in pairs(tombstones) do
		log.always("  deleted in Composer: %s rid %s at %s", tostring(tomb.name), rid,
			os.date("%Y-%m-%d %H:%M", tomb.deleted_at))
	end
end

-- Shows whether the persisted credentials can be read back, without
-- exposing the key. Compares against what the driver holds in memory.
local function reload_credentials()
	local state = ctx.state
	local stored = credentials.load()
	log.always("stored credentials: %s", credentials.summary(stored))
	log.always("in-memory credentials: %s", credentials.summary(state.creds))
	if credentials.paired(stored) then
		local same = state.creds and stored.key == state.creds.key and stored.bridge_id == state.creds.bridge_id
		ctx.prop("Status", same and "Stored credentials readable and match memory"
			or "Stored credentials readable but differ from memory; see Lua output")
	elseif ctx.paired() then
		ctx.prop("Status", "Stored credentials NOT readable although paired in memory; see Lua output")
	else
		ctx.prop("Status", "No stored credentials")
	end
end

local function check_ca_pinning()
	ctx.prop("Status", "Checking CA pinning against " .. pinning.PUBLIC_HOST)
	pinning.check(http.ca, function(verdict)
		local text = {
			pinned = "Pinning check passed: only Signify-signed certificates are trusted",
			not_pinned = "Pinning check FAILED: public CAs are trusted too; see Lua output",
			inconclusive = "Pinning check inconclusive: " .. pinning.PUBLIC_HOST .. " unreachable",
		}
		ctx.prop("Status", text[verdict] or verdict)
	end)
end

-- The connection experiment, see bridge/conntest.lua. The driver's own
-- stream is stopped for the duration so it cannot confound the result. The
-- diagnostic server's certificate is self-signed, hence unverified.
local function connection_test(params)
	params = params or {}
	local state = ctx.state
	local target
	if params.Target == "Diagnostic Server" then
		local host = trimmed(Properties["Diagnostic Server"])
		if host == "" then
			ctx.prop("Status", "Set the Diagnostic Server property first (host:port)")
			return
		end
		target = { name = "diagnostic server", ip = host, stream_path = "/stream", ping_path = "/ping",
			tls = conntest.TLS_INSECURE }
	else
		if not ctx.connection() then
			ctx.prop("Status", "Not paired")
			return
		end
		-- The key goes out only once the bridge at the address has shown the
		-- paired id, as for Hue Request [security review 2026-10-25, finding
		-- 10]. Status keeps what the identity check said.
		if state.identity_ok ~= true then
			return log.always("Connection Test: bridge identity not verified yet; nothing is sent (see Status)")
		end
		target = { name = "bridge", ip = state.ip, key = state.creds.key,
			stream_path = "/eventstream/clip/v2", ping_path = "/clip/v2/resource/bridge",
			headers = { Accept = "text/event-stream" } }
	end

	local was_running = state.stream:running()
	state.stream:stop()
	ctx.prop("Status", "Connection test against " .. target.name .. " running; see Lua output")
	conntest.run(target, nil, function(summary)
		ctx.prop("Status", string.format(
			"Connection test (%s): stream %s, GET with stream open %s, concurrent %s/2, control %s",
			target.name,
			summary.stream_ok and "OK" or "FAIL",
			summary.ping_ok and "OK" or "FAIL",
			tostring(summary.concurrent_ok or 0),
			summary.control_ok and "OK" or "FAIL"))
		if was_running then
			ctx.restart_stream(true)
		end
	end)
end

-- Test Connection with an optional param Host (signed dev loop commands
-- only; Composer's Test Connection, which has no params, stays the
-- driver's own handler): an alternative spelling of the bridge address (a
-- padded one, see spells_bridge_address) to probe whether Director's
-- per-host transfer queue keys on the host string. The TLS check ignores
-- the host name for the bridge anyway. A Host that is not a spelling of the
-- bridge's address is refused: nothing is sent, Status and the log say why.
-- With a Host it waits for the bridge identity check like Hue Request, since
-- that check proves the dotted address the spelling stands for; without
-- one, ctx.test_connection (driver.lua) runs the check itself.
local function test_connection(params)
	params = params or {}
	local host = ctx.state.ip
	if trimmed(params.Host) ~= "" and ctx.connection() then
		local refusal
		host, refusal = request_host(params.Host)
		if not host then
			log.always("Test Connection: %s", refusal)
			ctx.prop("Status", "Test Connection refused: Host is not a spelling of the bridge address")
			return
		end
		if ctx.state.identity_ok ~= true then
			return log.always("Test Connection: bridge identity not verified yet; see Status")
		end
		log.always("Test Connection via host %s instead of %s", host, ctx.state.ip)
	end
	ctx.test_connection(host)
end

-- The dev loop's redactor (devloop.set_redactor): every line the loop
-- ships, and every error text it reports, has the application key the
-- driver holds now replaced by "<key>" [security review 2026-10-25, finding
-- 9]. A plain search: the key is data, not a pattern.
local function redact_key(line)
	local creds = ctx and ctx.state and ctx.state.creds
	local key = type(creds) == "table" and creds.key or nil
	if type(key) ~= "string" or key == "" or type(line) ~= "string" then
		return line
	end
	local parts, from = {}, 1
	while true do
		local first, last = line:find(key, from, true)
		if not first then break end
		parts[#parts + 1] = line:sub(from, first - 1)
		parts[#parts + 1] = "<key>"
		from = last + 1
	end
	if from == 1 then
		return line
	end
	parts[#parts + 1] = line:sub(from)
	return table.concat(parts)
end

-- Register the handlers; `given` is the context described above. The
-- dispatch tables get the Dev Server property, the three DEV-ONLY actions
-- of driver.xml (what Composer can send) and HUE_LOG (what the devices
-- send); the rest, Test Connection's Host variant included, runs only for
-- signed dev loop commands (devloop.execute), and the redactor goes to the
-- loop. See the top of this file.
function devtools.install(given)
	ctx = given
	dispatch.properties["Dev_Server"] = dev_server_changed
	dispatch.commands["Connection_Test"] = connection_test
	dispatch.commands["Reload_Credentials"] = reload_credentials
	dispatch.commands["Check_CA_Pinning"] = check_ca_pinning
	dispatch.commands["HUE_LOG"] = hue_log
	-- common/devloop.lua is the one module a reload never replaces: code
	-- pushed to a bridge whose loop predates signed commands leaves these
	-- out rather than fail to load.
	if type(devloop.set_signed_commands) ~= "function" or type(devloop.set_redactor) ~= "function" then
		log.warn("dev loop: the running common/devloop.lua predates signed commands; the development "
			.. "commands stay unavailable until a dev .c4z install or a Director restart")
		return
	end
	devloop.set_signed_commands({
		Hue_Request = hue_request,
		Probe_Project = probe_project,
		Probe_Errors = probe_errors,
		Probe_Scenes = probe_scenes,
		Probe_Call = probe_call,
		Proxy_Command = proxy_command,
		Lights_Report = lights_report,
		Test_Connection = test_connection,
	})
	devloop.set_redactor(redact_key)
end

-- The end of the driver's late init: the dev loop starts last, so a reload
-- pushed through it sees a fully initialised driver (the property handler
-- above only arms it after this).
function devtools.late_init()
	local host = trimmed(Properties["Dev Server"])
	if host ~= "" then
		devloop.start(host)
	end
end

return devtools
