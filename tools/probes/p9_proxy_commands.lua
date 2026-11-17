-- Probe P9 (and P10, P11, P11b) of #557 (docs/syncbox-probes.md; research
-- docs/syncbox-wirings-research.md sec. 3, sec. 4, sec. 6; docs/syncbox-control4-research.md
-- sec. 1.3 to sec. 1.5, probes P1 to P5): what Director sends a Hue Sync Box device.
--
-- What it settles: the exact proxy commands and every parameter as it comes
-- (PREV_DEV_LIST included, raw and its ids described), their order and
-- spacing for: a source picked, another source, a source that bypasses the
-- box, a Listen source, Room Off; whether audio and video come in one
-- SET_INPUT or two; OFF or DISCONNECT_OUTPUT; in the second-output wiring,
-- that nothing comes but BINDING_CHANGE_ACTION and GET_AUDIO_INPUTS. At the
-- start it also lists what the box's AV connections are bound to, and walks
-- one step upstream of each input (research sec. 3.2: the candidates behind a
-- receiver).
--
-- Where it runs: only in a Hue Sync Box device (hue_syncbox.c4z), through
-- that device's Lua command window in Composer (dev builds only: dp3
-- --allowexecute). Nothing can push code into a device otherwise: the dev
-- loop forwards only the signed sync box tree to it (docs/dev-loop.md).
-- A dev loop reload of the device re-runs its driver.lua, which defines
-- ReceivedFromProxy again and drops this hook: pin the sync box tree
-- (tools/devctl.py pin --tree syncbox) while it runs, and run it again after
-- any reload.
--
-- Parameters (PROBE_PARAMS, strings): Minutes (1 to 120, default 30); Walk
-- ("off" skips the upstream walk). Running it again restarts it;
-- tools/probes/stop_all.lua stops every probe of this driver.
--
-- Read-only: it logs each command, then hands it to the driver's own
-- ReceivedFromProxy unchanged.
--
-- What to look for in tools/devctl.py log (every line "probe P9", forwarded
-- by the bridge as HUE_LOG, so behind the box's "[<8 hex>] Hue Sync Box: "):
--   start device <id> "<name>" room <id>; proxies <GetProxyDevices>; AV proxy <id>
--   bound <proxy>/<binding> <label>: <id> | none          the box's AV connections
--   upstream <id>/<binding>: <id>                           one step behind each input
--   device <id> (<why>): display "<name>"; GetDevices {...} once per device id seen
--   cmd t=<ms> +<ms> on <binding> <COMMAND>: K=V K=V ...    every command, all parameters
--   cmd PREV_DEV_LIST: "<raw>" / ids <id> <id> ...          when it comes
--   stop: <why>; <n> command(s) in <s> s
--
-- Lua 5.1; DriverWorks calls only, each cited at its use. Never in a release
-- build: tools/probes/ is not packaged (tools/build.sh packs src/ only).

local PROBE = "P9"

-- Parameters ---------------------------------------------------------------------

-- Run Lua sets PROBE_PARAMS while the chunk runs; in a Lua command window a
-- line `PROBE_PARAMS = { Minutes = "60" }` above the chunk does the same.
-- Read once and cleared.
local params = rawget(_G, "PROBE_PARAMS")
rawset(_G, "PROBE_PARAMS", nil)
if type(params) ~= "table" then
	params = {}
end

-- Helpers (the same in every probe; each chunk stands alone) ----------------------

-- Milliseconds since the epoch [verified: API 34_timer/_2-GetTime.md, OS 3.2.3].
local function now_ms()
	local ok, t = pcall(C4.GetTime, C4)
	if ok and type(t) == "number" then
		return t
	end
	return os.time() * 1000
end

-- [verified: API 22_miscellaneous/_13.5-GetDriverFileName.md, OS 3.3.0]
local function driver_file()
	local ok, file = pcall(C4.GetDriverFileName, C4)
	return ok and type(file) == "string" and file or "?"
end

local ON_BRIDGE = driver_file() == "hue_bridge.c4z"

-- The log path. On the bridge, print: the dev loop wraps the global print and
-- ships every line (docs/dev-loop.md, "Log capture"). On a device, its own
-- common.log: a dev build's device forwards every line but debug to the bridge
-- as HUE_LOG (common/devloop.lua, forward_logs), which prints it, so it ships
-- too, and it shows in the device's Lua output.
local emit = function(line)
	print(line)
end
if not ON_BRIDGE then
	local ok, log = pcall(require, "common.log")
	if ok and type(log) == "table" and type(log.always) == "function" then
		emit = function(line)
			log.always("%s", line)
		end
	end
end

local PIECE = 700

local function say(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	emit("probe " .. PROBE .. " " .. (ok and msg or tostring(fmt)))
end

-- `head` and `text`, in numbered pieces of PIECE bytes when it is long.
local function say_long(head, text)
	text = tostring(text)
	if #text <= PIECE then
		return say("%s%s", head, text)
	end
	local n = math.ceil(#text / PIECE)
	for i = 1, n do
		say("%s[%d/%d] %s", head, i, n, text:sub((i - 1) * PIECE + 1, i * PIECE))
	end
end

-- Another driver's text is data: control characters and "\" become \ddd, so
-- the exact bytes can be read back and no value can forge a log line.
local function clean(value)
	return (tostring(value):gsub("[%c\\]", function(c)
		return string.format("\\%03d", c:byte())
	end))
end

-- Numbers first (by value), then the rest by text: a total order.
local function key_order(a, b)
	local na, nb = tonumber(a), tonumber(b)
	if na and nb then
		return na < nb
	elseif na or nb then
		return na ~= nil
	end
	return tostring(a) < tostring(b)
end

-- Any value as one line: tables sorted, nested four levels at most.
local function show(value, depth)
	if type(value) == "string" then
		return '"' .. clean(value) .. '"'
	elseif type(value) ~= "table" then
		return clean(value)
	end
	depth = depth or 0
	if depth >= 4 then
		return "{...}"
	end
	local keys = {}
	for k in pairs(value) do
		keys[#keys + 1] = k
	end
	table.sort(keys, key_order)
	local parts = {}
	for i, k in ipairs(keys) do
		if i > 80 then
			parts[#parts + 1] = "..."
			break
		end
		parts[#parts + 1] = clean(k) .. "=" .. show(value[k], depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- A device id met in a value, described once: [verified: API
-- 22_miscellaneous/_9-GetDevices.md: DeviceIds is a comma list as text, the
-- answer is keyed by id with deviceName, driverFileName, roomId, roomName and
-- a protocol table (for a proxy id) or a proxies table (for a protocol id)];
-- [verified: API 32_serial_network_device/_6-GetDeviceDisplayName.md].
local described = {}
local function describe(id, why)
	id = tonumber(id)
	if not id or id <= 0 or described[id] then
		return
	end
	described[id] = true
	local ok, devices = pcall(C4.GetDevices, C4, { DeviceIds = tostring(id) })
	local okn, name = pcall(C4.GetDeviceDisplayName, C4, id)
	local head = string.format("device %d (%s): display %s; GetDevices ", id, why,
		okn and show(name) or ("error " .. clean(name)))
	say_long(head, ok and show(devices) or ("error " .. clean(devices)))
end

-- The probes this Lua state runs, by key, each with its stop(why).
local REG = rawget(_G, "__HUE_PROBES")
if type(REG) ~= "table" then
	REG = {}
	rawset(_G, "__HUE_PROBES", REG)
end

-- Only in a sync box device ----------------------------------------------------------

if driver_file() ~= "hue_syncbox.c4z" then
	say("not started: runs only in a Hue Sync Box device (this is %s)", driver_file())
	return
end

-- A run already going stops first, so its hook leaves the chain before this
-- run's goes in.
local stop -- defined below
local key = "P9"
if type(REG[key]) == "table" and type(REG[key].stop) == "function" then
	pcall(REG[key].stop, "restarted")
end
local inner = rawget(_G, "ReceivedFromProxy")
if type(inner) ~= "function" then
	say("not started: this driver has no ReceivedFromProxy")
	return
end

local started = now_ms()

-- Who and where [verified: API 22_miscellaneous/_11-GetDeviceID.md;
-- 22_miscellaneous/_33-RoomGetID.md; 25_proxy/_1-GetProxyDevices.md].
local _, me = pcall(C4.GetDeviceID, C4)
local _, my_room = pcall(C4.RoomGetId, C4)
local _, proxies = pcall(C4.GetProxyDevices, C4)

-- The AV switch proxy: the consumer of the protocol's binding 5001 (driver.xml:
-- the AV switch, consumer False; the same as bridge/devtools.lua finds a
-- light's proxy) [verified: API 32_serial_network_device/_3-GetBoundConsumerDevices.md:
-- device 0 is this device; a table of id = name, or nil].
local av_proxy
do
	local ok, consumers = pcall(C4.GetBoundConsumerDevices, C4, 0, 5001)
	if ok and type(consumers) == "table" then
		for id in pairs(consumers) do
			av_proxy = av_proxy or tonumber(id)
		end
	end
end
say("start device %s %s room %s; proxies %s; AV proxy %s; in %s", tostring(me),
	show((select(2, pcall(C4.GetDeviceDisplayName, C4, tonumber(me) or 0)))), tostring(my_room), show(proxies),
	tostring(av_proxy), driver_file())
describe(me, "this device")
describe(av_proxy, "its AV switch proxy")

-- What a binding is bound to: a device id (0 for none on OS 3.4.2, house) or a
-- table of id = name (the SDK's wording), as a list of ids.
local function ids_of(answer)
	local ids = {}
	if type(answer) == "table" then
		for id in pairs(answer) do
			if tonumber(id) and tonumber(id) > 0 then
				ids[#ids + 1] = tonumber(id)
			end
		end
		table.sort(ids)
	elseif tonumber(answer) and tonumber(answer) > 0 then
		ids[1] = tonumber(answer)
	end
	return ids
end

-- The box's AV connections (driver.xml; contracts C1.2) and, for each input,
-- one step upstream [verified: API 32_serial_network_device/_4-GetBoundProviderDevice.md:
-- with a proxy, ask on the proxy's id; its example reads a receiver's input
-- 1011; 32_serial_network_device/_3-GetBoundConsumerDevices.md for outputs].
local INPUTS = {
	{ 1000, "HDMI 1 video" }, { 1001, "HDMI 2 video" }, { 1002, "HDMI 3 video" }, { 1003, "HDMI 4 video" },
	{ 3000, "HDMI 1 audio" }, { 3001, "HDMI 2 audio" }, { 3002, "HDMI 3 audio" }, { 3003, "HDMI 4 audio" },
}
local OUTPUTS = { { 2000, "HDMI Out video" }, { 4000, "HDMI Out audio" } }
local walk = tostring(params.Walk or ""):lower() ~= "off"

local function walk_upstream(device)
	-- Input ids of other drivers are theirs to choose; the common ranges are
	-- 1000+ (video) and 3000+ (audio) [assumed]; 32 of each are read.
	local found = 0
	for _, base in ipairs({ 1000, 3000 }) do
		for binding = base, base + 31 do
			local ok, answer = pcall(C4.GetBoundProviderDevice, C4, device, binding)
			for _, id in ipairs(ok and ids_of(answer) or {}) do
				found = found + 1
				say("upstream %d/%d: %d", device, binding, id)
				describe(id, "upstream of " .. device)
			end
		end
	end
	if found == 0 then
		say("upstream %d: nothing bound to inputs 1000-1031, 3000-3031", device)
	end
end

-- Asked on the proxy, as the SDK says, and on the protocol device (0) too:
-- which of the two holds an AV switch's bindings is itself worth seeing.
local walked = {}
for _, target in ipairs(av_proxy and { av_proxy, 0 } or { 0 }) do
	for _, input in ipairs(INPUTS) do
		local ok, answer = pcall(C4.GetBoundProviderDevice, C4, target, input[1])
		local ids = ok and ids_of(answer) or {}
		say("bound %d/%d %s: %s", target, input[1], input[2],
			ok and (#ids > 0 and table.concat(ids, ",") or "none") or ("error " .. clean(answer)))
		for _, id in ipairs(ids) do
			describe(id, input[2])
			if walk and not walked[id] then
				walked[id] = true
				walk_upstream(id)
			end
		end
	end
	for _, output in ipairs(OUTPUTS) do
		local ok, answer = pcall(C4.GetBoundConsumerDevices, C4, target, output[1])
		local ids = ok and ids_of(answer) or {}
		say("bound %d/%d %s: %s", target, output[1], output[2],
			ok and (#ids > 0 and table.concat(ids, ",") or "none") or ("error " .. clean(answer)))
		for _, id in ipairs(ids) do
			describe(id, output[2])
		end
	end
end

-- The commands -------------------------------------------------------------------------

local active = true
local count = 0
local last_cmd

local function log_command(binding, command, cmd_params)
	local t = now_ms()
	local delta = last_cmd and (t - last_cmd) or 0
	last_cmd = t
	count = count + 1
	local parts, prev = {}, nil
	if type(cmd_params) == "table" then
		local keys = {}
		for k in pairs(cmd_params) do
			keys[#keys + 1] = k
		end
		table.sort(keys, key_order)
		for _, k in ipairs(keys) do
			if tostring(k) == "PREV_DEV_LIST" then
				prev = cmd_params[k]
				parts[#parts + 1] = "PREV_DEV_LIST=(below)"
			else
				parts[#parts + 1] = clean(k) .. "=" .. show(cmd_params[k])
			end
		end
	elseif cmd_params ~= nil then
		parts[1] = "(params " .. type(cmd_params) .. ") " .. show(cmd_params)
	end
	say_long(string.format("cmd t=%d +%dms on %s %s: ", t, delta, clean(binding), clean(command)),
		#parts > 0 and table.concat(parts, " ") or "(no parameters)")
	if prev ~= nil then
		say_long("cmd PREV_DEV_LIST: ", show(prev))
		-- Its format is not documented (PP 3_whats_new/_7-WHATSNEWIN342.md;
		-- PP 8_audio_video_switch_proxy_commands/_46-SETINPUT.md): every number
		-- of three digits or more is tried as a device id.
		local ids, seen = {}, {}
		for id in tostring(prev):gmatch("%d%d%d+") do
			if not seen[id] then
				seen[id] = true
				ids[#ids + 1] = id
			end
		end
		say("cmd PREV_DEV_LIST ids: %s", #ids > 0 and table.concat(ids, " ") or "none")
		for _, id in ipairs(ids) do
			describe(id, "in PREV_DEV_LIST")
		end
	end
end

-- [verified: API 25_proxy/_5-ReceivedFromProxy.md: (idBinding, strCommand,
-- tParams), a global Director calls by name]. The driver's own handler runs
-- after, unchanged; once stopped this one only passes calls on.
local function handler(binding, command, cmd_params, ...)
	if active then
		local ok, err = pcall(log_command, binding, command, cmd_params)
		if not ok then
			say("logging failed: %s", clean(err))
		end
	end
	return inner(binding, command, cmd_params, ...)
end

rawset(_G, "ReceivedFromProxy", handler)

-- Stopping ------------------------------------------------------------------------------

local timer
stop = function(why)
	if not active then
		return
	end
	active = false
	if timer then
		pcall(function() timer:Cancel() end)
	end
	if rawget(_G, "ReceivedFromProxy") == handler then
		rawset(_G, "ReceivedFromProxy", inner)
	end
	if REG[key] and REG[key].stop == stop then
		REG[key] = nil
	end
	say("stop: %s; %d command(s) in %d s", tostring(why), count, math.floor((now_ms() - started) / 1000))
end

REG[key] = { stop = stop, probe = PROBE, started = started }

-- [verified: API 34_timer/_1-SetTimer.md: delay in ms, callback(timer)]
local minutes = math.max(1, math.min(120, math.floor(tonumber(params.Minutes) or 30)))
timer = C4:SetTimer(minutes * 60000, function()
	stop("time is up")
end)
say("running: every proxy command of device %s is logged; stops in %d min (or tools/probes/stop_all.lua)",
	tostring(me), minutes)
