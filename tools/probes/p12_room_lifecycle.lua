-- Probe P12 of #557 (docs/syncbox-probes.md; research
-- docs/syncbox-wirings-research.md sec. 5 W3 to W6 and W16, sec. 6): what a driver
-- sees when rooms are renamed, deleted and a device moves between rooms.
--
-- What it settles: the OnSystemEvent payloads for a room (OnItemNameChanged,
-- OnItemRemoved, OnItemMoved, OnItemAdded; research sec. 5 W3: only device
-- payloads are known, docs/design.md "Composer Pro 3.4.2 UI"); whether this device's
-- RoomGetId() follows a move at once, or only Director's GetDevices does;
-- the room list before and after (a deleted room's id gone); what
-- RegisterVariableListener does for a room that does not exist and for a
-- variable a room lacks (W16: an error, or silence). With P8 watching a
-- second scratch room on the bridge, what its listener does when that room
-- is deleted (W4).
--
-- Where it runs: the Hue Sync Box device that is moved (RoomGetId is only
-- meaningful in the device itself), through its Lua command window in
-- Composer (dev builds only: dp3 --allowexecute). It also runs on the bridge
-- (Run Lua), which then reports the bridge's own room and, since the bridge
-- registers these system events itself at late init (src/hue_bridge/driver.lua,
-- PROBE_EVENTS), registers none. A dev loop reload of the device drops its
-- hooks: pin the sync box tree while it runs.
--
-- Parameters (PROBE_PARAMS, strings): Minutes (1 to 120, default 30);
-- PollMs (1000 to 60000, default 5000): how often RoomGetId, GetDevices and
-- the room list are read; BogusRoom (default 987654): a device id that is no
-- room. Running it again restarts it; tools/probes/stop_all.lua stops it.
--
-- Read-only towards the project. It registers system events in a device,
-- and two listeners that it unregisters after 5 s; when it stops it
-- unregisters the system events again, unless the driver has an OnSystemEvent
-- of its own (which may rely on the same registrations).
--
-- What to look for in tools/devctl.py log (every line "probe P12"):
--   start device <id> in <file>: RoomGetId <id>; Director's room <id> "<name>"; <n> rooms
--   rooms: <id>="<name>" ...                                  the room list at the start
--   system events: registered OnItemAdded=<id> ... | none (the bridge registers its own)
--   bogus listener <room>/1000: no error | error <text>       W16, a room that does not exist
--   bogus variable <room>/1999: no error | error <text>       W16, a variable the room lacks
--   bogus callback <device>/<variable> t=<ms>: "<value>"       if Director calls back for them
--   bogus unregister ...: no error | error <text>
--   system event t=<ms>: "<payload>"                          every OnSystemEvent, whole
--   RoomGetId <old> -> <new> t=<ms> (Director's room <id> "<name>")
--   Director's room <old> -> <new> "<name>" t=<ms> (RoomGetId <id>)
--   room added <id>="<name>" | room removed <id>="<name>" | room renamed <id>: "<old>" -> "<new>"
--   stop: <why>; ...
--
-- Lua 5.1; DriverWorks calls only, each cited at its use. Never in a release
-- build: tools/probes/ is not packaged (tools/build.sh packs src/ only).

local PROBE = "P12"

-- Parameters ---------------------------------------------------------------------

-- Run Lua sets PROBE_PARAMS while the chunk runs; in a Lua command window a
-- line `PROBE_PARAMS = { PollMs = "2000" }` above the chunk does the same.
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

-- The probes this Lua state runs, by key, each with its stop(why).
local REG = rawget(_G, "__HUE_PROBES")
if type(REG) ~= "table" then
	REG = {}
	rawset(_G, "__HUE_PROBES", REG)
end

-- What the driver can read about rooms --------------------------------------------------

-- Every room: { [id] = name } [verified: API 25_proxy/_4-GetDevicesByC4iName.md;
-- the room form, roomdevice.c4i, house-verified on OS 3.4.2, docs/design.md
-- "Project APIs"], with ids as numbers and names as text.
local function rooms()
	local ok, list = pcall(C4.GetDevicesByC4iName, C4, "roomdevice.c4i")
	local out = {}
	if ok and type(list) == "table" then
		for id, name in pairs(list) do
			if tonumber(id) then
				out[tonumber(id)] = tostring(name)
			end
		end
	end
	return out
end

local _, me = pcall(C4.GetDeviceID, C4) -- [verified: API 22_miscellaneous/_11-GetDeviceID.md]
me = tonumber(me)

-- This device's room as the driver asks for it [verified: API
-- 22_miscellaneous/_33-RoomGetID.md], and as Director lists it [verified: API
-- 22_miscellaneous/_9-GetDevices.md: roomId, roomName].
local function own_room()
	local ok, id = pcall(C4.RoomGetId, C4)
	return ok and tonumber(id) or nil
end

local function director_room()
	if not me then
		return nil, "?"
	end
	local ok, devices = pcall(C4.GetDevices, C4, { DeviceIds = tostring(me) })
	if not ok or type(devices) ~= "table" then
		return nil, "?"
	end
	local info = devices[me] or devices[tostring(me)]
	if type(info) ~= "table" then
		return nil, "?"
	end
	return tonumber(info.roomId), tostring(info.roomName)
end

local started = now_ms()
local known_rooms = rooms()
local last_own = own_room()
local last_dir, last_dir_name = director_room()
do
	local ids = {}
	for id in pairs(known_rooms) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	say("start device %s in %s: RoomGetId %s; Director's room %s %s; %d rooms", tostring(me), driver_file(),
		tostring(last_own), tostring(last_dir), show(last_dir_name), #ids)
	local parts = {}
	for _, id in ipairs(ids) do
		parts[#parts + 1] = id .. "=" .. show(known_rooms[id])
	end
	say_long("rooms: ", table.concat(parts, " "))
end

local active = true
local stop
local key = "P12"
if type(REG[key]) == "table" and type(REG[key].stop) == "function" then
	pcall(REG[key].stop, "restarted")
end

-- W16: listeners that cannot work ------------------------------------------------------

local BOGUS_ROOM = math.floor(tonumber(params.BogusRoom) or 987654)
local BOGUS_VARIABLE = 1999
local real_room = last_own or last_dir
if known_rooms[BOGUS_ROOM] then
	say("BogusRoom %d is a room (%s): the bogus listener test is skipped", BOGUS_ROOM, show(known_rooms[BOGUS_ROOM]))
	BOGUS_ROOM = nil
end

local function is_bogus(device, variable)
	device, variable = tonumber(device), tonumber(variable)
	return (BOGUS_ROOM ~= nil and device == BOGUS_ROOM)
		or (real_room ~= nil and device == real_room and variable == BOGUS_VARIABLE)
end

-- [verified: API 36_variable/_9-OnWatchedVariableChanged.md]. A callback for
-- the bogus pairs is ours alone and goes no further; any other goes on to
-- whatever handler was there, unchanged.
local inner_watch = rawget(_G, "OnWatchedVariableChanged")
local function watch_handler(device, variable, value, ...)
	if is_bogus(device, variable) then
		if active then
			say_long(string.format("bogus callback %s/%s t=%d: ", clean(device), clean(variable), now_ms()), show(value))
		end
		return
	end
	if type(inner_watch) == "function" then
		return inner_watch(device, variable, value, ...)
	end
end
rawset(_G, "OnWatchedVariableChanged", watch_handler)

-- [verified: API 36_variable/_10-RegisterVariableListener.md: "will fail if the
-- variable does not exist"; how it fails is not said]
local bogus_pairs = {}
if BOGUS_ROOM then
	bogus_pairs[#bogus_pairs + 1] = { BOGUS_ROOM, 1000, "bogus listener" }
end
if real_room then
	bogus_pairs[#bogus_pairs + 1] = { real_room, BOGUS_VARIABLE, "bogus variable" }
end
for _, pair in ipairs(bogus_pairs) do
	local ok, err = pcall(C4.RegisterVariableListener, C4, pair[1], pair[2])
	say("%s %d/%d: %s", pair[3], pair[1], pair[2], ok and "no error" or ("error " .. clean(err)))
end

-- System events --------------------------------------------------------------------------

-- The names come from Control4's own handler list, as the bridge's do
-- (src/hue_bridge/driver.lua PROBE_EVENTS) [verified: API
-- 7_event/_1-RegisteringforSystemEvents.md: C4SystemEvents maps names to ids;
-- device id 0 for every device; OnItemAdded, OnItemRemoved, OnItemNameChanged
-- named there; OnItemMoved is not, research sec. 5 W6; _5.5-RegisterSystemEvent.md;
-- _6.1-UnRegisterSystemEvent.md; _4.2-OnSystemEvent.md: OnSystemEvent(data)].
local EVENT_NAMES = { "OnItemAdded", "OnItemRemoved", "OnItemNameChanged", "OnItemMoved",
	"OnDeviceUserInitiatedRemove" }
local inner_system = rawget(_G, "OnSystemEvent")
local function system_handler(data, ...)
	if active then
		say_long(string.format("system event t=%d: ", now_ms()), show(data))
	end
	if type(inner_system) == "function" then
		return inner_system(data, ...)
	end
end
rawset(_G, "OnSystemEvent", system_handler)

local registered_events = {}
if ON_BRIDGE then
	say("system events: none registered here (the bridge registers its own at late init)")
elseif type(C4SystemEvents) ~= "table" then
	say("system events: C4SystemEvents is %s; none registered", type(C4SystemEvents))
else
	local parts = {}
	for _, name in ipairs(EVENT_NAMES) do
		local id = C4SystemEvents[name]
		if id == nil then
			parts[#parts + 1] = name .. "=(no such event)"
		else
			local ok, err = pcall(C4.RegisterSystemEvent, C4, id, 0)
			if ok then
				registered_events[#registered_events + 1] = id
				parts[#parts + 1] = name .. "=" .. clean(id)
			else
				parts[#parts + 1] = name .. "=" .. clean(id) .. " error " .. clean(err)
			end
		end
	end
	say("system events: registered %s", table.concat(parts, " "))
end

-- Polling -------------------------------------------------------------------------------

local function poll()
	if not active then
		return
	end
	local t = now_ms()
	local now_own = own_room()
	local now_dir, now_dir_name = director_room()
	if now_own ~= last_own then
		say("RoomGetId %s -> %s t=%d (Director's room %s %s)", tostring(last_own), tostring(now_own), t,
			tostring(now_dir), show(now_dir_name))
		last_own = now_own
	end
	if now_dir ~= last_dir or now_dir_name ~= last_dir_name then
		say("Director's room %s -> %s %s t=%d (RoomGetId %s)", tostring(last_dir), tostring(now_dir),
			show(now_dir_name), t, tostring(now_own))
		last_dir, last_dir_name = now_dir, now_dir_name
	end
	local now_rooms = rooms()
	for id, name in pairs(now_rooms) do
		if known_rooms[id] == nil then
			say("room added %d=%s t=%d", id, show(name), t)
		elseif known_rooms[id] ~= name then
			say("room renamed %d: %s -> %s t=%d", id, show(known_rooms[id]), show(name), t)
		end
	end
	for id, name in pairs(known_rooms) do
		if now_rooms[id] == nil then
			say("room removed %d=%s t=%d", id, show(name), t)
		end
	end
	known_rooms = now_rooms
end

-- [verified: API 34_timer/_1-SetTimer.md: delay in ms, callback(timer), a
-- repeating timer with true; Cancel()]
local poll_ms = math.max(1000, math.min(60000, math.floor(tonumber(params.PollMs) or 5000)))
local poll_timer = C4:SetTimer(poll_ms, function()
	local ok, err = pcall(poll)
	if not ok then
		say("poll failed: %s", clean(err))
	end
end, true)

-- The bogus listeners go again after 5 s, whatever they did [verified: API
-- 36_variable/_11-UnregisterVariableListener.md: "will not work if a variable
-- has not been registered"].
local cleanup_timer = C4:SetTimer(5000, function()
	for _, pair in ipairs(bogus_pairs) do
		local ok, err = pcall(C4.UnregisterVariableListener, C4, pair[1], pair[2])
		say("%s unregister %d/%d: %s", pair[3], pair[1], pair[2], ok and "no error" or ("error " .. clean(err)))
	end
end)

-- Stopping ------------------------------------------------------------------------------

local stop_timer
stop = function(why)
	if not active then
		return
	end
	active = false
	local timers = { poll_timer, cleanup_timer, stop_timer }
	for i = 1, 3 do
		if timers[i] then
			pcall(function() timers[i]:Cancel() end)
		end
	end
	if rawget(_G, "OnWatchedVariableChanged") == watch_handler then
		rawset(_G, "OnWatchedVariableChanged", inner_watch)
	end
	if rawget(_G, "OnSystemEvent") == system_handler then
		rawset(_G, "OnSystemEvent", inner_system)
	end
	-- A driver with an OnSystemEvent of its own may rely on the same
	-- registrations: they stay then (a later OnSystemEvent call is its own).
	local dropped = 0
	if type(inner_system) ~= "function" then
		for _, id in ipairs(registered_events) do
			if pcall(C4.UnregisterSystemEvent, C4, id, 0) then
				dropped = dropped + 1
			end
		end
	end
	if REG[key] and REG[key].stop == stop then
		REG[key] = nil
	end
	say("stop: %s; after %d s; %d of %d system event registration(s) dropped", tostring(why),
		math.floor((now_ms() - started) / 1000), dropped, #registered_events)
end

REG[key] = { stop = stop, probe = PROBE, started = started }

local minutes = math.max(1, math.min(120, math.floor(tonumber(params.Minutes) or 30)))
stop_timer = C4:SetTimer(minutes * 60000, function()
	stop("time is up")
end)
say("running: polling every %d ms; stops in %d min (or tools/probes/stop_all.lua)", poll_ms, minutes)
