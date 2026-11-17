-- Stops every probe of tools/probes/ that runs in this driver's Lua state
-- (docs/syncbox-probes.md): each takes its hooks out of the chain (or leaves
-- them as pass-throughs when another hook sits above), cancels its timers and
-- unregisters what it registered, as its header says. Run it where the probes
-- run: the bridge (Run Lua), or a device's Lua command window in Composer.
-- Each probe also stops by itself after its Minutes, and a dev loop reload of
-- a device drops a device's hooks anyway.
--
-- Parameters (PROBE_PARAMS, strings): List ("yes": only list what runs).
--
-- What to look for in tools/devctl.py log:
--   probe stop_all: <n> running: <key> (<probe>, <s> s) ...
--   probe P8 stop room <id>: stop_all; ...     each probe's own stop line
--   probe stop_all: stopped <n>
--
-- Lua 5.1. Never in a release build: tools/probes/ is not packaged.

local params = rawget(_G, "PROBE_PARAMS")
rawset(_G, "PROBE_PARAMS", nil)
if type(params) ~= "table" then
	params = {}
end

-- Milliseconds since the epoch [verified: API 34_timer/_2-GetTime.md, OS 3.2.3].
local function now_ms()
	local ok, t = pcall(C4.GetTime, C4)
	if ok and type(t) == "number" then
		return t
	end
	return os.time() * 1000
end

-- The same log path as the probes: print on the bridge (the dev loop ships
-- it), the driver's common.log on a device (forwarded to the bridge as
-- HUE_LOG) [verified: API 22_miscellaneous/_13.5-GetDriverFileName.md].
local ok_file, file = pcall(C4.GetDriverFileName, C4)
local emit = function(line)
	print(line)
end
if not (ok_file and file == "hue_bridge.c4z") then
	local ok, log = pcall(require, "common.log")
	if ok and type(log) == "table" and type(log.always) == "function" then
		emit = function(line)
			log.always("%s", line)
		end
	end
end

local function say(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	emit("probe stop_all: " .. (ok and msg or tostring(fmt)))
end

local REG = rawget(_G, "__HUE_PROBES")
local keys = {}
if type(REG) == "table" then
	for k in pairs(REG) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
end

local parts = {}
for _, k in ipairs(keys) do
	local entry = REG[k]
	local since = type(entry) == "table" and tonumber(entry.started)
	parts[#parts + 1] = string.format("%s (%s, %s s)", tostring(k), tostring(type(entry) == "table" and entry.probe),
		since and tostring(math.floor((now_ms() - since) / 1000)) or "?")
end
say("%d running: %s", #keys, #parts > 0 and table.concat(parts, " ") or "none")

if tostring(params.List or ""):lower() == "yes" then
	return
end

local stopped = 0
for _, k in ipairs(keys) do
	local entry = REG[k]
	if type(entry) == "table" and type(entry.stop) == "function" then
		local ok, err = pcall(entry.stop, "stop_all")
		if ok then
			stopped = stopped + 1
		else
			say("%s: stop failed: %s", tostring(k), (tostring(err):gsub("%c", " ")))
		end
	end
	REG[k] = nil
end
say("stopped %d", stopped)
