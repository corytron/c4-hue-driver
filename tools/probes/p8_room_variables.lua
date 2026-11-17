-- Probe P8 of #557 (docs/syncbox-probes.md; research docs/syncbox-wirings-research.md
-- sec. 1, sec. 2, sec. 6): a room's variables, as a driver sees them.
--
-- What it settles (research Q1, Q2): the names GetDeviceVariables gives the
-- room's variables against the ids 1000 + position of the SDK's list; the
-- value formats of 1000 to 1010 (device ids as text? 0 for none? the paths'
-- XML; the power state); whether the ids in them are proxy or protocol ids;
-- how a Watch, a Listen and Room Off show; the order and spacing of the
-- changes of one selection; that the first callback comes at once when a
-- listener is set (the baseline, W15); that a selection made by programming
-- shows as one made on a Navigator (W12); for P9 to P11, whether a video
-- path (1008) names the box or the receiver; for P12, what a listener on a
-- deleted room does.
--
-- Where it runs: the bridge, preferably (nothing else there listens to room
-- variables, so stopping unregisters cleanly): the signed dev loop command
-- Run Lua (docs/syncbox-probes.md, "Running a probe"), or the bridge's Lua
-- command window in Composer (dev builds only: dp3 --allowexecute). It also
-- runs in a device, but a Hue Sync Box device's own syncbox/room.lua calls
-- UnregisterAllVariableListeners once per run and may hold the same
-- listeners, so there it leaves its listeners registered when it stops.
--
-- Parameters (PROBE_PARAMS, strings): Room (a room's device id) or RoomName
-- (a room's name, any case); default: on a Hue Sync Box device its own
-- room, elsewhere the room of the first Hue Sync Box device. Minutes (1 to
-- 120, default 30): it stops by itself after that. Events ("off" skips
-- them): also RegisterDeviceEvent(room, 1 to 40) and log every OnDeviceEvent
-- of the room. Running it again for the same room restarts it;
-- tools/probes/stop_all.lua stops every probe of this driver.
--
-- Read-only towards the project: it only reads, and registers listeners for
-- this driver (Director-side, gone at the next Director restart at the
-- latest).
--
-- What to look for in tools/devctl.py log (every line starts "probe P8"):
--   start room <id> "<name>" (<how>) in <driver file> device <id> ...
--   dump <room>/<variable id>: {name="...", value="...", ...}   one per variable
--   name <SDK name>: id <n> as expected | id <m> in the dump, not <n> | not in the dump
--   read <room>/<id> <name>: "<value>"                      GetDeviceVariable before listening
--   listen <room>/<id>: registered in <ms> ms | error <text>
--   change <room>/<id> <name> t=<ms> +<ms since the previous change> first|change[ (during register)]: "<value>"
--   device <id> (<why>): display "<name>"; GetDevices {...}  once per device id seen
--   event <room>/<event id> t=<ms>
--   stop room <id>: <why>; ...
-- Values are shown with control characters and "\" as \ddd escapes.
--
-- Lua 5.1; DriverWorks calls only, each cited at its use. Never in a release
-- build: tools/probes/ is not packaged (tools/build.sh packs src/ only).

local PROBE = "P8"

-- Parameters ---------------------------------------------------------------------

-- Run Lua sets PROBE_PARAMS from its own params while the chunk runs; in a
-- Lua command window a line `PROBE_PARAMS = { RoomName = "..." }` above the
-- chunk does the same. Read once and cleared, so no later chunk inherits it.
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

-- The room ----------------------------------------------------------------------------

-- Every room: { [id] = name } [verified: API 25_proxy/_4-GetDevicesByC4iName.md;
-- the room form, roomdevice.c4i, house-verified on OS 3.4.2, docs/design.md
-- "Project APIs"].
local function rooms()
	local ok, list = pcall(C4.GetDevicesByC4iName, C4, "roomdevice.c4i")
	return ok and type(list) == "table" and list or {}
end

local function room_name(id)
	for rid, name in pairs(rooms()) do
		if tonumber(rid) == id then
			return tostring(name)
		end
	end
	return "?"
end

-- The room to watch and how it was found, or nil and why.
local function resolve_room()
	local id = tonumber(params.Room)
	if id then
		return id, "Room"
	end
	local wanted = params.RoomName and tostring(params.RoomName):lower() or ""
	if wanted ~= "" then
		for rid, name in pairs(rooms()) do
			if tostring(name):lower() == wanted then
				return tonumber(rid), "RoomName"
			end
		end
		return nil, "no room is named " .. show(params.RoomName)
	end
	if driver_file() == "hue_syncbox.c4z" then
		-- [verified: API 22_miscellaneous/_33-RoomGetID.md]
		local ok, rid = pcall(C4.RoomGetId, C4)
		if ok and tonumber(rid) then
			return tonumber(rid), "this device's room"
		end
	end
	-- [verified: API 22_miscellaneous/_9-GetDevices.md: C4iNames takes .c4z names]
	local ok, boxes = pcall(C4.GetDevices, C4, { C4iNames = "hue_syncbox.c4z" })
	local first, info
	if ok and type(boxes) == "table" then
		for did, entry in pairs(boxes) do
			if tonumber(did) and (not first or tonumber(did) < first) then
				first, info = tonumber(did), entry
			end
		end
	end
	if first and type(info) == "table" and tonumber(info.roomId) then
		return tonumber(info.roomId), "the room of Hue Sync Box device " .. first
	end
	return nil, "give Room or RoomName: no Hue Sync Box device to take the room from"
end

local room, how = resolve_room()
if not room then
	say("not started: %s", how)
	return
end

-- A run already watching this room stops first, so its hooks leave the chain
-- before this run puts its own in.
local stop -- defined below
local key = "P8:" .. room
if type(REG[key]) == "table" and type(REG[key].stop) == "function" then
	pcall(REG[key].stop, "restarted")
end

-- The variables ------------------------------------------------------------------------

-- The room's variables are 1000 + their position in the SDK's list [verified:
-- API 36_variable/_12-ListofRoomVariables.md]; Snap One's helper library names
-- the same ids [verified: CL global/lib.lua ROOM_VARS]. Where the two spell a
-- name differently, both are here.
local WATCH = {
	{ id = 1000, names = { "Current_Selected_Device" } },
	{ id = 1001, names = { "Current_Audio_Device" } },
	{ id = 1002, names = { "Current_Video_Device" } },
	{ id = 1005, names = { "Current_Media" } },
	{ id = 1006, names = { "Current_Media_Type" } },
	{ id = 1007, names = { "Current_Audio_Path" } },
	{ id = 1008, names = { "Current_Video_Path" } },
	{ id = 1009, names = { "Current_Video_Audio_Path" } },
	{ id = 1010, names = { "Power_State" } },
	{ id = 1024, names = { "Linked_Room_List" } },
	{ id = 1026, names = { "RoomOff_Linked", "ROOMOFF_IS_LINKED" } },
	{ id = 1027, names = { "Selections_Linked" } },
}
-- Ids whose value names a device, and ids whose value is a path of <id> elements
-- [verified: CL global/msp.lua OWVC.ParseRoomIdSource, OWVC.ParseRoomIdRoute].
local DEVICE_IDS = { [1000] = true, [1001] = true, [1002] = true }
local PATH_IDS = { [1007] = true, [1008] = true, [1009] = true }

-- "Variable_Current_Selected_Device", "CURRENT_SELECTED_DEVICE" -> CURRENTSELECTEDDEVICE
local function normalize(name)
	local text = tostring(name):upper():gsub("[^%w]", "")
	return (text:gsub("^VARIABLE", ""))
end

-- A field of an entry whose key, any case, is one of `keys`.
local function field(entry, keys)
	if type(entry) ~= "table" then
		return nil
	end
	for k, v in pairs(entry) do
		if type(k) == "string" and keys[k:lower()] and type(v) ~= "table" then
			return v
		end
	end
	return nil
end
local NAME_KEYS = { name = true, variablename = true, varname = true }
local ID_KEYS = { id = true, varid = true, variableid = true, variable_id = true }

local names_by_id = {}  -- variable id -> the name the dump gives it
local watching = {}     -- variable id -> true

local started = now_ms()
-- [verified: API 22_miscellaneous/_11-GetDeviceID.md]
say("start room %d %s (%s) in %s device %s; Minutes %s; Events %s", room, show(room_name(room)), how,
	driver_file(), tostring(select(2, pcall(C4.GetDeviceID, C4))), tostring(params.Minutes or 30),
	tostring(params.Events or "on"))

-- The dump [verified: API 22_miscellaneous/_12-GetDeviceVariables.md, OS 2.8.0:
-- every variable of a device "with all of the information" for each; Snap One
-- reads it keyed by the variable id as text, each entry with a name, CL
-- global/handlers.lua].
do
	local ok, vars = pcall(C4.GetDeviceVariables, C4, room)
	if not ok then
		say("dump %d: error %s", room, clean(vars))
	elseif type(vars) ~= "table" then
		say("dump %d: answered %s %s", room, type(vars), show(vars))
	else
		local keys, by_name = {}, {}
		for k in pairs(vars) do
			keys[#keys + 1] = k
		end
		table.sort(keys, key_order)
		say("dump %d: %d entries", room, #keys)
		for _, k in ipairs(keys) do
			local entry = vars[k]
			say_long(string.format("dump %d/%s: ", room, clean(k)), show(entry))
			local id = tonumber(field(entry, ID_KEYS)) or tonumber(k)
			local name = field(entry, NAME_KEYS)
			if id and name then
				names_by_id[id] = tostring(name)
				by_name[normalize(name)] = id
			end
		end
		for _, w in ipairs(WATCH) do
			local found
			for _, n in ipairs(w.names) do
				found = found or by_name[normalize(n)]
			end
			if found == w.id then
				say("name %s: id %d as expected", w.names[1], w.id)
			elseif found then
				say("name %s: id %d in the dump, not %d; watching both", w.names[1], found, w.id)
				watching[found] = true
			else
				say("name %s: not in the dump (expected id %d)", w.names[1], w.id)
			end
		end
	end
end
for _, w in ipairs(WATCH) do
	watching[w.id] = true
end

-- The values before listening [verified: API 36_variable/_5-GetDeviceVariable.md:
-- nil when not found].
do
	local ids = {}
	for id in pairs(watching) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local ok, value = pcall(C4.GetDeviceVariable, C4, room, id)
		say_long(string.format("read %d/%d %s: ", room, id, names_by_id[id] or "?"),
			ok and show(value) or ("error " .. clean(value)))
	end
end

-- The listeners -------------------------------------------------------------------------

local active = true
local last_change        -- ms of the previous change logged
local seen = {}          -- variable id -> a callback came
local registering        -- the variable whose RegisterVariableListener runs now

local function on_change(id, value)
	local t = now_ms()
	local delta = last_change and (t - last_change) or 0
	last_change = t
	local kind = seen[id] and "change" or "first"
	if registering == id then
		kind = kind .. " (during register)"
	end
	seen[id] = true
	say_long(string.format("change %d/%d %s t=%d +%dms %s: ", room, id, names_by_id[id] or "?", t, delta, kind),
		show(value))
	if DEVICE_IDS[id] then
		describe(value, "variable " .. id)
	end
	if PATH_IDS[id] then
		for did in tostring(value):gmatch("<id>%s*(%d+)%s*</id>") do
			describe(did, "path " .. id)
		end
	end
end

-- [verified: API 36_variable/_9-OnWatchedVariableChanged.md: (idDevice,
-- idVariable, strValue), a global Director calls by name]. Whatever was
-- there before is called after, so a driver's own handler keeps working; once
-- stopped this one only passes calls on.
local inner_watch = rawget(_G, "OnWatchedVariableChanged")
local function watch_handler(device, variable, value, ...)
	if active and tonumber(device) == room and watching[tonumber(variable)] then
		local ok, err = pcall(on_change, tonumber(variable), value)
		if not ok then
			say("change handler failed: %s", clean(err))
		end
	end
	if type(inner_watch) == "function" then
		return inner_watch(device, variable, value, ...)
	end
end

-- The hook first: the first callback may come during the register call.
rawset(_G, "OnWatchedVariableChanged", watch_handler)
local registered = {}
do
	local ids = {}
	for id in pairs(watching) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	for _, id in ipairs(ids) do
		-- [verified: API 36_variable/_10-RegisterVariableListener.md: fails if the
		-- variable does not exist; the callback runs once at once after]
		local t0 = now_ms()
		registering = id
		local ok, err = pcall(C4.RegisterVariableListener, C4, room, id)
		registering = nil
		if ok then
			registered[id] = true
			say("listen %d/%d %s: registered in %d ms", room, id, names_by_id[id] or "?", now_ms() - t0)
		else
			say("listen %d/%d %s: error %s", room, id, names_by_id[id] or "?", clean(err))
		end
	end
end

-- The room's own events (research sec. 1.1: their ids are not documented; a
-- fallback at most) [verified: API 7_event/_5-RegisterDeviceEvent.md,
-- _4.1-OnDeviceEvent.md (firingDeviceId, eventId), _7-UnRegisterDeviceEvent.md].
local inner_event = rawget(_G, "OnDeviceEvent")
local events_on = tostring(params.Events or ""):lower() ~= "off"
local function event_handler(device, event, ...)
	if active and events_on and tonumber(device) == room then
		say("event %d/%s t=%d", room, clean(event), now_ms())
	end
	if type(inner_event) == "function" then
		return inner_event(device, event, ...)
	end
end
local events = {}
if events_on then
	rawset(_G, "OnDeviceEvent", event_handler)
	local fails = 0
	for id = 1, 40 do
		if pcall(C4.RegisterDeviceEvent, C4, room, id) then
			events[#events + 1] = id
		else
			fails = fails + 1
		end
	end
	say("events %d: registered %d of 40 ids, %d failed", room, #events, fails)
end

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
	-- Our handlers leave the chain only when on top; otherwise they stay as
	-- pass-throughs, so a probe started later keeps its own.
	if rawget(_G, "OnWatchedVariableChanged") == watch_handler then
		rawset(_G, "OnWatchedVariableChanged", inner_watch)
	end
	if rawget(_G, "OnDeviceEvent") == event_handler then
		rawset(_G, "OnDeviceEvent", inner_event)
	end
	local gone, kept = 0, 0
	for id in pairs(registered) do
		-- [verified: API 36_variable/_11-UnregisterVariableListener.md]. Only on the
		-- bridge: a device's own code may hold the same listeners.
		if ON_BRIDGE and pcall(C4.UnregisterVariableListener, C4, room, id) then
			gone = gone + 1
		else
			kept = kept + 1
		end
	end
	for _, id in ipairs(events) do
		pcall(C4.UnregisterDeviceEvent, C4, room, id)
	end
	if REG[key] and REG[key].stop == stop then
		REG[key] = nil
	end
	say("stop room %d: %s; after %d s; %d listener(s) unregistered, %d left registered%s", room, tostring(why),
		math.floor((now_ms() - started) / 1000), gone, kept,
		(kept > 0 and not ON_BRIDGE) and " (a device's own code may hold them)" or "")
end

REG[key] = { stop = stop, probe = PROBE, room = room, started = started }

-- [verified: API 34_timer/_1-SetTimer.md: delay in ms, callback(timer)]
local minutes = math.max(1, math.min(120, math.floor(tonumber(params.Minutes) or 30)))
timer = C4:SetTimer(minutes * 60000, function()
	stop("time is up")
end)
local listened = 0
for _ in pairs(registered) do
	listened = listened + 1
end
say("running: room %d, %d variable(s) listened to, stops in %d min (or tools/probes/stop_all.lua)", room,
	listened, minutes)
