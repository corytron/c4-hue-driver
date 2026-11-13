-- Development handlers of the Hue Bridge driver, dev builds only. tools/build.sh
-- ships this module with common/devloop.lua, bridge/conntest.lua,
-- bridge/pinning.lua and bridge/probe12.lua in `--dev` builds and leaves all
-- five out of release builds (with the DEV-ONLY blocks of driver.xml), so a
-- release driver carries none of this code. Here live the dev loop's `Dev
-- Server` property, the arbitrary request and the project probes reached
-- through `tools/devctl.py run`, the light path's Proxy Command and Lights
-- Report, the device drivers' forwarded log lines (HUE_LOG), the Reload
-- Credentials, Check CA Pinning and Connection Test diagnostics, Test
-- Connection's Host override, the registration of the 1.2 probe's
-- commands (bridge/probe12.lua: Probe Discovery, Probe Names, Probe Names
-- Restore, Probe Picker, Probe Picker Folders), Link Offline After, the
-- short outage time of a house check (#428 D15), and Watch Events, which
-- logs the light_v2 events a device's proxy fires (#432 D17). See
-- docs/dev-loop.md.
--
-- driver.lua loads this module only when common/devloop.lua is present and
-- hands over what the handlers need in devtools.install(ctx); nothing here
-- reaches into the driver's locals.
--
-- ExecuteCommand has no sender parameter
-- [verified: API 5_director_command/_1-ExecuteCommand], so whatever sits in
-- dispatch.commands any driver in the project can run with C4:SendToDevice.
-- Only the Dev Server property and the devices' HUE_LOG go there. The
-- requests, probes, proxy commands and the four former DEV-ONLY actions
-- (Connection Test, Reload Credentials, Check CA Pinning, Probe Picker
-- Folders) run only for commands the dev loop verified
-- (devloop.set_signed_commands); the first three also run from
-- Diagnostics' (dev) entries, through devtools.diagnostics, which only the
-- driver's Diagnostics action reads. The loop's redactor keeps the
-- application key out of every shipped line [security review 2026-10-25,
-- finding 9; security review 2026-11-13 C-2, #484].

local log = require("common.log")
local num = require("common.num")
local dispatch = require("common.dispatch")
local http = require("bridge.http")
local credentials = require("bridge.credentials")
local lights_mod = require("bridge.lights")
local devloop = require("common.devloop")
local conntest = require("bridge.conntest")
local pinning = require("bridge.pinning")
local probe12 = require("bridge.probe12")
local link_mod = require("bridge.link")

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
--   last_action(text)        Last Action, word-wrapped, and the log
local ctx

local function trimmed(value)
	return (value or ""):match("^%s*(.-)%s*$")
end

-- The most bytes of one forwarded HUE_LOG line that are printed, and so
-- kept by the dev loop and shipped (#484 C-2).
devtools.LOG_LINE_MAX = 2000

-- `text` as one line of at most `max` bytes: control characters made
-- spaces, the rest cut with "..." in its place. Only the head is scanned.
local function one_line(text, max)
	local s = tostring(text)
	if #s > max then
		s = s:sub(1, max - 3) .. "..."
	end
	return (s:gsub("%c", " "))
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
-- the whole body). It sends through http.request itself, and is refused
-- (nothing queued, nothing sent) until the bridge identity check has passed,
-- as bridge_request in driver.lua refuses. Logs the status,
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
-- lines of the shipped log, and a line is cut at LOG_LINE_MAX bytes, so a
-- driver cannot fill the loop's buffer with lines of any size (#484 C-2).
local function hue_log(params)
	params = params or {}
	local who = "light"
	if type(params.rid) == "string" and params.rid ~= "" then
		local registry = ctx.state.lights and ctx.state.lights.registry
		local entry = type(registry) == "table" and registry[params.rid] or nil
		who = (type(entry) == "table" and entry.name) or params.rid:sub(1, 8)
	end
	log.always("[%s] %s", one_line(who, 100), one_line(params.line, devtools.LOG_LINE_MAX))
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

-- The light_v2 proxy of the light, zone light or scene device `key` names
-- (rid, Hue or Composer name, protocol device id), for Proxy Command and
-- Watch Events: the proxy's device id and the device's name, or nil and
-- why (a text that follows the caller's own label).
local function find_proxy(key)
	local lights = ctx.state.lights
	local rid, entry = find_light(key or "")
	if not rid then
		-- A zone light or a scene device: its light_v2 proxy is the consumer
		-- of its binding 5001, as for a light.
		local group = find_group_device(key or "")
		if not group then
			return nil, string.format("no registered light, zone light or scene matches %q", tostring(key))
		end
		local consumers = C4:GetBoundConsumerDevices(tonumber(group.device_id), 5001)
		local gproxy = type(consumers) == "table" and next(consumers) or nil
		if not gproxy then
			return nil, string.format("no proxy found for %s (device %s)", group.name, tostring(group.device_id))
		end
		return gproxy, group.name
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
		return nil, string.format("no proxy found for %s (device %s)", entry.name, tostring(entry.device_id))
	end
	return proxy, entry.name
end

-- Not in driver.xml, reachable only through signed dev loop commands: a
-- light_v2 proxy command to one light, zone light or scene device, the way
-- a Navigator or programming would send it, so the whole command path can
-- be exercised from the dev loop. Params: Light (rid, Hue name or protocol
-- device id), Command (e.g. SET_BRIGHTNESS_TARGET), and the command's own
-- params (e.g. LIGHT_BRIGHTNESS_TARGET=50 RATE=0).
local function proxy_command(params)
	params = params or {}
	local proxy, name = find_proxy(params.Light)
	if not proxy then
		return log.always("Proxy Command: %s", name)
	end
	local command = params.Command or "SET_BRIGHTNESS_TARGET"
	local forwarded = {}
	for k, v in pairs(params) do
		if k ~= "Light" and k ~= "Command" then forwarded[k] = v end
	end
	C4:SendToDevice(proxy, command, forwarded)
	log.always("Proxy Command: %s -> %s (proxy %s): %s", command, name, tostring(proxy), C4:JsonEncode(forwarded))
end

-- Watch Events (signed dev loop commands only; #432 D17,
-- docs/light-events-design.md §6.6 and house check P3): which of a light_v2
-- proxy's events fire, logged with the controller's clock, so the house can
-- see whether the drivers' button notifications (#432 D4 to D7) become the
-- proxy's Press, Release and tap events. Params: Light (as Proxy Command:
-- rid, Hue or Composer name, protocol device id), Events (default
-- 5001-5015; a range, a comma list or both, e.g. "5003,5004" or
-- "4001,5001-5005"; "none" unregisters every event this driver registered).
-- A second call adds ids, on the same device or another one.
--
-- [verified: API 7_event/_5-RegisterDeviceEvent.md] C4:RegisterDeviceEvent
-- (firing device id, event id), OS 2.9.0; [verified: API
-- 7_event/_4.1-OnDeviceEvent.md] Director then calls the global
-- OnDeviceEvent(firing device id, event id); [verified: API
-- 7_event/_6-UnRegisterAllDeviceEvents.md] C4:UnregisterAllDeviceEvents()
-- drops them all. That page's file name spells it UnRegister, its
-- signature Unregister, the spelling of the other calls of this family
-- (UnregisterDeviceEvent, UnregisterSystemEvent), so that spelling is
-- called; on a controller without it, the documented per-event
-- C4:UnregisterDeviceEvent [verified: API 7_event/_7-UnRegisterDeviceEvent.md]
-- for each one registered here. That the proxy's own events reach
-- OnDeviceEvent with the proxy as the firing device is [assumed]
-- (light-events F12), so every call is logged while the hook is in,
-- whichever device it names.

-- The light_v2 proxy's events [verified: LV2 25_light_v2_events/_0-HEADER.md]:
-- the keypad events, 5001 + action + 5 x button (button 0 Top, 1 Bottom,
-- 2 Toggle; action 0 release, 1 push, 2 single, 3 double, 4 triple click;
-- light-events F3), and the proxy's own.
local EVENT_NAMES = {
	[4000] = "Brightness Changing", [4001] = "Brightness Changed", [4002] = "Color Changing",
	[4003] = "Color Changed", [5000] = "Old Light Level Changed", [5100] = "Light On", [5101] = "Light Off",
}
do
	local buttons = { "Top", "Bottom", "Toggle" }
	local actions = { "Release", "Push", "Single", "Double", "Triple" }
	for b = 0, 2 do
		for a = 0, 4 do
			EVENT_NAMES[5001 + a + 5 * b] = buttons[b + 1] .. " " .. actions[a + 1]
		end
	end
end
devtools.EVENT_NAMES = EVENT_NAMES

local WATCH_DEFAULT = "5001-5015"
-- Ids one call may list: a slip such as "1-50000" registers nothing.
local WATCH_MAX = 64

-- Watch Events' state, kept across a dev loop reload (devloop.keep in
-- devtools.install), since Director keeps the registrations and the global
-- OnDeviceEvent through one: the reloaded code takes the hook over instead
-- of chaining the old code's, which would log every event twice.
--   watched  proxy id -> { [event id] = true }: what was registered here
--   handler  the OnDeviceEvent installed here, while the hook is in
--   inner    the OnDeviceEvent found before it, called after each line
local watch = { watched = {} }

-- The ids `text` lists, in order and once each, or nil and why.
local function event_ids(text)
	local ids, seen = {}, {}
	for item in (text .. ","):gmatch("([^,]*),") do
		item = trimmed(item)
		local first, last = item:match("^(%d+)%s*%-%s*(%d+)$")
		if not first then
			first = item:match("^%d+$")
			last = first
		end
		if not first then
			return nil, string.format("%q is not an event id or a range of them", item)
		end
		first, last = tonumber(first), tonumber(last)
		if first > last then
			return nil, string.format("%q runs backwards", item)
		end
		if last - first >= WATCH_MAX then
			return nil, string.format("%q lists more than %d ids", item, WATCH_MAX)
		end
		for id = first, last do
			if not seen[id] then
				seen[id] = true
				ids[#ids + 1] = id
			end
		end
		if #ids > WATCH_MAX then
			return nil, string.format("more than %d ids", WATCH_MAX)
		end
	end
	return ids
end

-- The ids of `set` ({ [id] = true }) as ranges: "5001-5015,5100".
local function ranges(set)
	local ids = {}
	for id in pairs(set) do ids[#ids + 1] = id end
	table.sort(ids)
	local parts, i = {}, 1
	while i <= #ids do
		local j = i
		while ids[j + 1] == ids[j] + 1 do j = j + 1 end
		parts[#parts + 1] = (j > i) and (ids[i] .. "-" .. ids[j]) or tostring(ids[i])
		i = j + 1
	end
	return table.concat(parts, ",")
end

-- How many events on how many devices are watched: "15 events on 1 device".
local function watch_counts()
	local events, devices = 0, 0
	for _, ids in pairs(watch.watched) do
		devices = devices + 1
		for _ in pairs(ids) do events = events + 1 end
	end
	return string.format("%d event%s on %d device%s", events, events == 1 and "" or "s", devices,
		devices == 1 and "" or "s")
end

-- Put this code's OnDeviceEvent in: one line per call, then the
-- OnDeviceEvent that was there before (an earlier one of ours, from before
-- a reload, is replaced, not chained). The global goes into _G, the
-- driver's environment on the controller, as bridge/probe12.lua's do.
local function hook()
	local current = rawget(_G, "OnDeviceEvent")
	if watch.handler == nil or current ~= watch.handler then
		watch.inner = current
	end
	watch.handler = function(device, event, ...)
		log.always("event %s (%s) from device %s at %s", tostring(event), EVENT_NAMES[tonumber(event)] or "?",
			tostring(device), tostring(C4:GetTime()))
		if type(watch.inner) == "function" then
			return watch.inner(device, event, ...)
		end
	end
	rawset(_G, "OnDeviceEvent", watch.handler)
end

-- Put back the OnDeviceEvent found before hook(), unless something else
-- replaced ours meanwhile.
local function unhook()
	if watch.handler ~= nil and rawget(_G, "OnDeviceEvent") == watch.handler then
		rawset(_G, "OnDeviceEvent", watch.inner)
	end
	watch.handler, watch.inner = nil, nil
end

local function watch_events(params)
	params = params or {}
	local events = trimmed(tostring(params.Events or ""))
	if events:lower() == "none" then
		local counts = watch_counts()
		if type(C4.UnregisterAllDeviceEvents) == "function" then
			C4:UnregisterAllDeviceEvents()
		else
			for device, ids in pairs(watch.watched) do
				for id in pairs(ids) do C4:UnregisterDeviceEvent(device, id) end
			end
		end
		watch.watched = {}
		unhook()
		return log.always("Watch Events: stopped; %s unregistered", counts)
	end
	local ids, why = event_ids(events ~= "" and events or WATCH_DEFAULT)
	if not ids then
		return log.always("Watch Events: Events %s; nothing registered", why)
	end
	local proxy, name = find_proxy(params.Light)
	if not proxy then
		return log.always("Watch Events: %s; nothing registered", name)
	end
	proxy = tonumber(proxy) or proxy
	-- The hook first, so an event that fires at once is seen.
	hook()
	local mine = watch.watched[proxy] or {}
	watch.watched[proxy] = mine
	local added = {}
	for _, id in ipairs(ids) do
		-- Once per event and device: whether a second registration doubles
		-- the calls is not documented, and a doubled line would read as an
		-- event fired twice.
		if not mine[id] then
			C4:RegisterDeviceEvent(proxy, id)
			mine[id] = true
			added[id] = true
		end
	end
	log.always("Watch Events: %s (proxy %s): registered %s; watching %s", name, tostring(proxy),
		next(added) and ranges(added) or "nothing new", watch_counts())
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
			num.date("%Y-%m-%d %H:%M", tomb.deleted_at or -1)) -- #487: a stored time os.date cannot take
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
	pinning.check(http.ca, function(verdict, detail)
		ctx.prop("Status", pinning.status(verdict, detail))
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
-- With a Host it is refused until the bridge identity check has passed, like
-- Hue Request, since that check proves the dotted address the spelling
-- stands for; without one, ctx.test_connection (driver.lua) runs the check
-- itself and waits for it.
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

-- Link Offline After (signed dev loop commands only; #428 D15,
-- docs/offline-design.md §8.2): Seconds, clamped to LINK_MIN_S..LINK_MAX_S,
-- becomes bridge/link.lua's OFFLINE_AFTER_S for this run, so a house check
-- sees the devices go offline within a minute instead of 5. A count already
-- running follows at once (link:retime). Release builds ship neither this
-- nor any other way to change it; a new run of the code brings the 300 s back.
local LINK_MIN_S, LINK_MAX_S = 10, 3600

local function link_offline_after(params)
	params = params or {}
	local seconds = tonumber(params.Seconds)
	local function say(text)
		if type(ctx.last_action) == "function" then
			return ctx.last_action(text)
		end
		log.always("%s", text)
		ctx.prop("Last Action", text)
	end
	if not seconds or seconds ~= seconds then -- nil, or NaN (Lua 5.1's tonumber reads "nan")
		return say(string.format("Link Offline After: Seconds %q is not a number (%d to %d); unchanged at %d s",
			tostring(params.Seconds), LINK_MIN_S, LINK_MAX_S, link_mod.OFFLINE_AFTER_S))
	end
	seconds = math.max(LINK_MIN_S, math.min(LINK_MAX_S, math.floor(seconds)))
	link_mod.OFFLINE_AFTER_S = seconds
	local l = ctx.state and ctx.state.link
	if type(l) == "table" and type(l.retime) == "function" then
		l:retime()
	end
	say(string.format("Link Offline After: Hue devices go offline after %d s of bridge trouble, for this run",
		seconds))
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

-- Diagnostics' (dev) entries (driver.lua's dev_command), by dispatch name:
-- the driver's Diagnostics action runs them, and nothing else does but a
-- signed dev loop command (#484 C-2). Filled by install.
devtools.diagnostics = {}

-- Register the handlers; `given` is the context described above. The
-- dispatch tables get the Dev Server property and HUE_LOG (what the devices
-- send); everything else, Test Connection's Host variant and the four
-- former DEV-ONLY actions included, runs only for signed dev loop commands
-- (devloop.execute), the first three of those also from Diagnostics
-- (devtools.diagnostics), and the redactor goes to the loop. See the top of
-- this file.
function devtools.install(given)
	ctx = given
	-- The event stream's abandoned transfers outlive a dev loop reload (#247):
	-- Cancel() does not end them (bridge/stream.lua, rule 2), and Director
	-- runs at most four C4:url transfers at once. The list the driver hands
	-- every stream it builds (state.stream_abandoned, until now one per load
	-- of driver.lua) becomes the one the loop keeps, so the reloaded code
	-- counts the old code's open transfers against the stream's cap and waits
	-- as after any restart. Here, before late init builds the first stream. A
	-- running common/devloop.lua without keep (a dev install from before it)
	-- leaves the list per load, as before.
	if type(devloop.keep) == "function" and type(given.state) == "table"
		and type(given.state.stream_abandoned) == "table" then
		given.state.stream_abandoned = devloop.keep("stream_abandoned", given.state.stream_abandoned)
	end
	-- Watch Events' registrations and hook outlive a reload the same way
	-- (#432 D17): the code a reload brings up takes over the state and,
	-- when the hook is in, puts its own OnDeviceEvent in place of the old
	-- code's, so each event is still logged once.
	if type(devloop.keep) == "function" then
		watch = devloop.keep("watch_events", watch)
		if watch.handler ~= nil and rawget(_G, "OnDeviceEvent") == watch.handler then
			hook()
		end
	end
	-- The 1.2 probe gets the same context; it defines the global list
	-- functions of its picker test (Probe12PickerList, Probe12RoomList).
	probe12.install(given)
	dispatch.properties["Dev_Server"] = dev_server_changed
	dispatch.commands["HUE_LOG"] = hue_log
	-- Not in dispatch.commands, where any driver in the project could run
	-- them unsigned (one opens a TLS connection to an internet host): none
	-- is a Composer action since 1.2 (#484 C-2).
	devtools.diagnostics = {
		Connection_Test = connection_test,
		Reload_Credentials = reload_credentials,
		Check_CA_Pinning = check_ca_pinning,
	}
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
		-- The short outage time of a house check (#428 D15).
		Link_Offline_After = link_offline_after,
		-- Which light_v2 proxy events fire, for house check P3 (#432 D17).
		Watch_Events = watch_events,
		-- The 1.2 probe (bridge/probe12.lua, docs/simplify-actions-design.md §2.2).
		Probe_Discovery = probe12.discovery,
		Probe_Names = probe12.names,
		Probe_Names_Restore = probe12.names_restore,
		Probe_Picker = probe12.picker_dump,
		Probe_Picker_Folders = probe12.picker_action,
		-- Diagnostics' (dev) entries, signed (#484 C-2).
		Connection_Test = connection_test,
		Reload_Credentials = reload_credentials,
		Check_CA_Pinning = check_ca_pinning,
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
