-- The Control4 room the Hue Sync Box driver follows (2.0 beta stage 3,
-- #557): docs/hdmi-sync-stage3-design.md §4, research
-- docs/syncbox-wirings-research.md §1 (the room's variables and the APIs),
-- §5 (the lifecycle cases W1 to W24) and §7.4 (this module's sketch).
--
-- Three parts.
--
-- 1. The watcher: one room's variables through listeners.
--
--   local r = room.new{ register, unregister, unregister_all, get_variable,
--                       get_variables, timer, now, log,
--                       on_baseline, on_change, on_trouble }
--   r:follow(room_id, name)  → true | false, reason. Looks the variables up
--                     by name (GetDeviceVariables), else takes the numbers of
--                     research §1.2; registers a listener on each (the
--                     SDK's example unregisters first, so this does too);
--                     reads each value once as well; after BASELINE_MS the
--                     values make the baseline: on_baseline(state), once.
--                     Following another room first stops the old one.
--   r:stop()          every listener of the followed room unregistered,
--                     every timer cancelled, nothing followed
--   r:retry()         follow the same room again (the ids looked up by name
--                     again): for OnPIP and the hourly retry (W16); true
--                     when it tried
--   r:on_variable(device, variable, value)  the global
--                     OnWatchedVariableChanged goes here; true when the
--                     value was one of ours. After the baseline every
--                     change re-arms a SETTLE_MS settle (never longer than
--                     SETTLE_MAX_MS from the first change), then
--                     on_change(state, prev) if the state differs from the
--                     last one reported (W11, W12, W19)
--   r:state()         the last state reported (baseline or change), a copy,
--                     or nil
--   r:following()     the room id and its name, or nil
--   r:ids()           the variable ids in use, { selected = 1000, ... }
--
-- The state:
--   { room_id, selected, audio, video, video_path = { ids }, audio_path =
--     { ids }, power = "on" | "off" | nil, kind = "watch" | "listen" | "off"
--     | "unknown" }
--   kind: "off" when the selected device is 0 (Room Off; research §2.2),
--   "watch" when the selected device is the current video device, "listen"
--   when it is the current audio device only, else by the paths (a picture
--   path is a Watch, a sound path alone a Listen), else "watch". "unknown"
--   when the selected device never answered or is not a number: nothing is
--   done on it. POWER_STATE's format is not documented [assumed: P8], so
--   it is reported but never decides "off" on its own: a misread power
--   would otherwise power-save the box in a room that is on.
--
-- Callbacks (each optional, each under pcall):
--   on_baseline(state)        once per follow, after BASELINE_MS: the first
--                             values after start or after a new room is
--                             followed. Never a command (W15; contracts C1.9,
--                             edge case C14).
--   on_change(state, prev)    a settled change
--   on_trouble(text, room_id, reason)  the room cannot be followed (W16):
--                             reason "register" (the listener raised: the
--                             variable does not exist) or "no answer" (no
--                             value for the selected device). A retry runs
--                             after RETRY_MS, and r:retry() runs one at once.
--
-- Every value comes from another driver, so it is input like a peer's text
-- (research §7.4): device ids through common/num.lua (whole, 0 to ID_MAX),
-- paths read from at most PATH_READ_MAX bytes and at most PATH_IDS_MAX ids,
-- power from at most 16 bytes, names through https.peer_text capped at
-- NAME_MAX. Nothing of a value is copied into a row or a log line raw.
--
-- The SDK facts used [verified: ~/c4-tools/reference/docs-driverworks-api/
-- source/includes/]: C4:RegisterVariableListener(idDevice, idVariable) calls
-- OnWatchedVariableChanged once at once after it is set and fails for a
-- variable that does not exist (36_variable/_10); UnregisterVariableListener
-- (36_variable/_11) and UnregisterAllVariableListeners (36_variable/_10.5,
-- from 3.3.0); GetDeviceVariable answers a string or nil, not in
-- OnDriverInit (36_variable/_5); GetDeviceVariables(id), from 2.8.0, not in
-- OnDriverInit (22_miscellaneous/_12); the room's variables in order, 1000
-- plus the position (36_variable/_12). The shape of GetDeviceVariables'
-- table (keyed by the variable id as text, each entry with a `name`) is
-- Snap One's own helper library's reading [verified: drivers-common-public
-- global/handlers.lua, OnWatchedVariableChanged]; the names it reports for a
-- room are [assumed: P8], so they are compared without case, underscores,
-- spaces or a "Variable_" prefix, and the numbers stand in for any not
-- found. Whether the first callback arrives inside RegisterVariableListener
-- or a moment later is not documented: both fold into the baseline.
--
-- 2. The choice: the Follow Room property (research §7.2, W1 to W7, W24).
--
--   local c = room.choice{ rooms, own_room, persist_get, persist_set, log }
--   c:items()         → labels, value: the DYNAMIC_LIST's items, in order
--                     (LABEL_OWN with the device's room, LABEL_NONE, then
--                     every room by name, commas made "‚" as the bridge's
--                     lists do), and the label of the current choice
--   c:choose(text)    the dealer picked `text` → true | false, reason;
--                     stored as { mode, id, name } (PersistSetValue), never
--                     as a name alone
--   c:resolve()       → { room_id, name, how, status, trouble, last_action,
--                     offer }: which room to follow now.
--                       how "own" (W1, W5, W6): the device's room; a move is
--                         said once in last_action
--                       how "chosen" (W7): the room picked; renamed while
--                         running, the label follows (W3); status notes it
--                         when the device sits elsewhere (W6)
--                       how "none" (W2): no room
--                       how "gone" (W4): the room was deleted; room_id nil,
--                         trouble set, never another room by itself; a
--                         single room with the old name is the offer
--                       how "mismatch" (W24): the stored name is not the
--                         id's name at the first check of a run (a restored
--                         project); as "gone" until a click
--                       how "unknown": the room list or the device's room
--                         did not answer; the last known room stays
--   c:accept_offer()  the offer taken (one click): true when there was one
--   c:record()        a copy of the stored choice
--   room.DEFAULT_FOLLOW  "own" (provisional owner answer 1 of #536,
--                     contract §2): "none" makes nothing followed until the
--                     dealer picks a room. One line.
--
-- `rooms()` answers { [id] = name } (default
-- C4:GetDevicesByC4iName("roomdevice.c4i") [house: verified on OS 3.4.2,
-- docs/design.md "Project APIs"]); `own_room()` the device's room (default
-- C4:RoomGetId() [verified: API 22_miscellaneous/_33]).
--
-- 3. room.path_offer{ box_ids, rooms, read, followed } (W20): the one room
-- whose current picture path runs through the box while the followed room's
-- does not → { id, name, text }, else nil. Offered, never set by itself.

local num = require("common.num")
local https = require("common.https")

local room = {}

room.SETTLE_MS = 1000         -- research §7.4: changes act after a 1 s settle
room.SETTLE_MAX_MS = 4000     -- a stream of changes acts at most this long after its first
room.BASELINE_MS = 1000       -- the first values after follow() fold into the baseline
room.RETRY_MS = 3600000       -- W16: hourly
room.PATH_READ_MAX = 8192     -- bytes of a path value read
room.PATH_IDS_MAX = 32        -- ids of a path kept
room.NAME_MAX = 64            -- bytes of a room name kept
room.ID_MAX = 2147483647
room.VARIABLES_READ = 256     -- entries of GetDeviceVariables looked at
room.ROOMS_MAX = 128          -- rooms of the project looked at
room.VIDEO_PATH_ID = 1008

-- The variables watched, with the ids of research §1.2 [verified: API
-- 36_variable/_12; drivers-common-public global/lib.lua ROOM_VARS agrees].
room.VARIABLES = {
	{ key = "selected", name = "CURRENT_SELECTED_DEVICE", id = 1000, kind = "id", required = true },
	{ key = "audio", name = "CURRENT_AUDIO_DEVICE", id = 1001, kind = "id" },
	{ key = "video", name = "CURRENT_VIDEO_DEVICE", id = 1002, kind = "id" },
	{ key = "audio_path", name = "CURRENT_AUDIO_PATH", id = 1007, kind = "path" },
	{ key = "video_path", name = "CURRENT_VIDEO_PATH", id = 1008, kind = "path" },
	{ key = "power", name = "POWER_STATE", id = 1010, kind = "power" },
}

-- The Follow Room property (research §7.2).
room.LABEL_OWN = "This device's room"
room.LABEL_NONE = "None (the box decides)"
room.DEFAULT_FOLLOW = "own"   -- provisional answer (#536, contract §2): "own" or "none"
room.FOLLOW_KEY = "syncbox_follow_room"

local function cap(text, max)
	if text == nil then
		return nil
	end
	return https.peer_text(text, max or room.NAME_MAX)
end

-- Values ----------------------------------------------------------------------

local function parse_id(v)
	if v == nil then
		return nil
	end
	if type(v) == "string" then
		v = v:sub(1, 32)
	end
	return num.int(v, 0, room.ID_MAX)
end

-- "<id>12</id><id>34</id>" (Snap One's library reads the audio path so
-- [verified: drivers-common-public global/msp.lua OWVC.ParseRoomIdRoute]),
-- or a plain list of numbers [assumed: in case 1008 differs; P8].
local function parse_path(v)
	local out = {}
	if type(v) ~= "string" and type(v) ~= "number" then
		return out
	end
	local text = tostring(v):sub(1, room.PATH_READ_MAX)
	for id in text:gmatch("<id>%s*(%d+)%s*</id>") do
		local n = num.int(id:sub(1, 12), 1, room.ID_MAX)
		if n then
			out[#out + 1] = n
			if #out >= room.PATH_IDS_MAX then
				return out
			end
		end
	end
	if #out == 0 and text:match("^[%d%s,]+$") then
		for id in text:gmatch("%d+") do
			local n = num.int(id:sub(1, 12), 1, room.ID_MAX)
			if n then
				out[#out + 1] = n
				if #out >= room.PATH_IDS_MAX then
					break
				end
			end
		end
	end
	return out
end
room.parse_path = parse_path

local POWER_WORDS = { ["1"] = "on", on = "on", ["true"] = "on", ["0"] = "off", off = "off", ["false"] = "off" }

local function parse_power(v)
	if v == nil then
		return nil
	end
	local text = tostring(v):sub(1, 16):lower():match("^%s*(.-)%s*$")
	return POWER_WORDS[text]
end

local PARSE = { id = parse_id, path = parse_path, power = parse_power }

local function contains(list, id)
	for _, x in ipairs(list or {}) do
		if x == id then
			return true
		end
	end
	return false
end

-- The kind of the selection (see the header).
function room.kind_of(s)
	if s.selected == nil then
		return "unknown"
	end
	if s.selected == 0 then
		return "off"
	end
	if s.video == s.selected then
		return "watch"
	end
	if s.audio == s.selected then
		return "listen"
	end
	if #s.video_path > 0 then
		return "watch"
	end
	if #s.audio_path > 0 then
		return "listen"
	end
	return "watch"
end

local function copy_list(list)
	local out = {}
	for i, v in ipairs(list or {}) do
		out[i] = v
	end
	return out
end

local function copy_state(s)
	if s == nil then
		return nil
	end
	return { room_id = s.room_id, selected = s.selected, audio = s.audio, video = s.video,
		video_path = copy_list(s.video_path), audio_path = copy_list(s.audio_path), power = s.power, kind = s.kind }
end

local function same_list(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function same_state(a, b)
	if a == nil or b == nil then
		return a == b
	end
	return a.kind == b.kind and a.selected == b.selected and a.audio == b.audio and a.video == b.video
		and a.power == b.power and same_list(a.video_path, b.video_path) and same_list(a.audio_path, b.audio_path)
end
room.same_state = same_state

-- "Variable_Current_Selected_Device", "CURRENT_SELECTED_DEVICE" and
-- "Current Selected Device" all read CURRENTSELECTEDDEVICE.
local function normalize(name)
	local text = tostring(name):upper():gsub("[^%w]", "")
	return (text:gsub("^VARIABLE", ""))
end

-- The watcher ---------------------------------------------------------------------

local R = {}
R.__index = R

local function have_c4(name)
	return type(C4) == "table" and type(C4[name]) == "function"
end

function room.new(deps)
	deps = deps or {}
	local r = setmetatable({}, R)
	r.register = deps.register or function(device, variable)
		return C4:RegisterVariableListener(device, variable)
	end
	r.unregister = deps.unregister or function(device, variable)
		return C4:UnregisterVariableListener(device, variable)
	end
	r.unregister_all = deps.unregister_all or function()
		return C4:UnregisterAllVariableListeners()
	end
	r.get_variable = deps.get_variable or function(device, variable)
		return C4:GetDeviceVariable(device, variable)
	end
	r.get_variables = deps.get_variables or function(device)
		return C4:GetDeviceVariables(device)
	end
	r.timer = deps.timer or function(ms, fn)
		return C4:SetTimer(ms, function() fn() end)
	end
	r.now = deps.now or function()
		if have_c4("GetTime") then
			return C4:GetTime()
		end
		return os.time() * 1000
	end
	r.log = deps.log or require("common.log")
	r.on = { baseline = deps.on_baseline, change = deps.on_change, trouble = deps.on_trouble }
	r.gen = 0
	r.cleared = false   -- UnregisterAllVariableListeners once per run, before the first follow
	r.registered = {}   -- { { device, variable } } of the followed room
	r.phase = "idle"    -- "idle" | "starting" | "following" | "trouble"
	r.raw, r.got = {}, {}
	r.ids_in_use = {}
	r.by_id = {}
	return r
end

local function call(self, name, ...)
	local fn = self.on[name]
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		self.log.warn("Sync box: the room's %s callback failed: %s", name, cap(err, https.TEXT_LOG))
	end
end

local function cancel(handle)
	if handle then
		pcall(function() handle:Cancel() end)
	end
end

local function arm(self, ms, fn)
	local gen = self.gen
	local ok, handle = pcall(self.timer, math.max(1, math.floor(ms)), function()
		if self.gen == gen then
			fn()
		end
	end)
	if ok then
		return handle
	end
	self.log.warn("Sync box: could not set a room timer")
	return nil
end

local function cancel_timers(self)
	cancel(self.baseline_timer)
	cancel(self.settle_timer)
	cancel(self.retry_timer)
	self.baseline_timer, self.settle_timer, self.retry_timer = nil, nil, nil
	self.pending_since = nil
end

local function drop_listeners(self)
	for _, pair in ipairs(self.registered) do
		pcall(self.unregister, pair[1], pair[2])
	end
	self.registered = {}
end

-- The variable ids by name, else the numbers (research §1.2's recommendation).
function R:resolve_ids(room_id)
	local ids = {}
	for _, v in ipairs(room.VARIABLES) do
		ids[v.key] = v.id
	end
	local ok, t = pcall(self.get_variables, room_id)
	if not ok or type(t) ~= "table" then
		self.log.debug("Sync box: room %d's variables not listed; using the numbers 1000 to 1010", room_id)
		return ids, false
	end
	local wanted = {}
	for _, v in ipairs(room.VARIABLES) do
		wanted[normalize(v.name)] = v.key
	end
	local found, n = {}, 0
	for k, e in pairs(t) do
		n = n + 1
		if n > room.VARIABLES_READ then
			break
		end
		if type(e) == "table" then
			local id = num.int(k, 1, room.ID_MAX) or num.int(e.id, 1, room.ID_MAX)
				or num.int(e.variableId, 1, room.ID_MAX)
			local name = e.name or e.variableName
			if id and type(name) == "string" and #name <= 128 then
				local key = wanted[normalize(name)]
				if key and (found[key] == nil or id < found[key]) then
					found[key] = id
				end
			end
		end
	end
	local missing = {}
	for _, v in ipairs(room.VARIABLES) do
		if found[v.key] then
			ids[v.key] = found[v.key]
		else
			missing[#missing + 1] = v.name
		end
	end
	if #missing > 0 then
		self.log.debug("Sync box: room %d lists no %s; using the numbers", room_id, table.concat(missing, ", "))
	end
	return ids, true
end

function R:take(key, value)
	local spec
	for _, v in ipairs(room.VARIABLES) do
		if v.key == key then
			spec = v
		end
	end
	self.raw[key] = PARSE[spec.kind](value)
	self.got[key] = true
end

function R:build()
	local s = {
		room_id = self.room_id,
		selected = self.raw.selected, audio = self.raw.audio, video = self.raw.video,
		video_path = copy_list(self.raw.video_path), audio_path = copy_list(self.raw.audio_path),
		power = self.raw.power,
	}
	s.kind = room.kind_of(s)
	return s
end

local function room_label(self)
	return self.name or string.format("room %d", self.room_id or 0)
end

function R:trouble(reason, detail)
	self.phase = "trouble"
	self.trouble_reason = reason
	cancel_timers(self)
	local text = string.format("Cannot follow %s: its variables do not answer", room_label(self))
	self.log.warn("Sync box: %s (%s%s)", text, reason, detail and (": " .. cap(detail, 200)) or "")
	call(self, "trouble", text, self.room_id, reason)
	self.retry_timer = arm(self, room.RETRY_MS, function()
		self.retry_timer = nil
		self:retry()
	end)
end

local function baseline_due(self)
	self.baseline_timer = nil
	if not self.got.selected or self.raw.selected == nil then
		self:trouble("no answer")
		return
	end
	local s = self:build()
	self.last = s
	self.phase = "following"
	self.log.debug("Sync box: following %s; baseline %s (selected %s)", room_label(self), s.kind,
		tostring(s.selected))
	call(self, "baseline", copy_state(s))
end

function R:follow(room_id, name)
	room_id = num.int(room_id, 1, room.ID_MAX)
	if not room_id then
		self:stop()
		return false, "no room"
	end
	drop_listeners(self)
	cancel_timers(self)
	self.gen = self.gen + 1
	self.room_id, self.name = room_id, cap(name)
	self.raw, self.got, self.last = {}, {}, nil
	self.phase, self.trouble_reason = "starting", nil
	if not self.cleared then
		-- Whatever a previous run of the driver left [assumed: whether Director
		-- keeps a listener across Update Driver is not documented].
		self.cleared = true
		pcall(self.unregister_all)
	end
	local ids = self:resolve_ids(room_id)
	self.ids_in_use = ids
	self.by_id = {}
	for _, v in ipairs(room.VARIABLES) do
		self.by_id[ids[v.key]] = v.key
	end
	local gen = self.gen
	for _, v in ipairs(room.VARIABLES) do
		local id = ids[v.key]
		pcall(self.unregister, room_id, id)   -- as the SDK's example does
		local ok, err = pcall(self.register, room_id, id)
		if self.gen ~= gen then
			return false, "superseded"   -- a callback followed another room meanwhile
		end
		if ok then
			self.registered[#self.registered + 1] = { room_id, id }
		elseif v.required then
			self:trouble("register", err)
			return false, "register"
		else
			self.log.debug("Sync box: no listener on %s's %s (%d)", room_label(self), v.name, id)
		end
	end
	-- Read each value once too: the first callbacks may come later, or not.
	for _, pair in ipairs(self.registered) do
		local key = self.by_id[pair[2]]
		if not self.got[key] then
			local ok, value = pcall(self.get_variable, room_id, pair[2])
			if ok and value ~= nil then
				self:take(key, value)
			end
		end
	end
	self.baseline_timer = arm(self, room.BASELINE_MS, function() baseline_due(self) end)
	return true
end

function R:stop()
	drop_listeners(self)
	cancel_timers(self)
	self.gen = self.gen + 1
	self.room_id, self.name, self.last = nil, nil, nil
	self.raw, self.got = {}, {}
	self.phase = "idle"
end

function R:retry()
	if not self.room_id then
		return false
	end
	if self.phase ~= "trouble" then
		return false
	end
	self:follow(self.room_id, self.name)
	return true
end

local function settled(self)
	self.settle_timer, self.pending_since = nil, nil
	local s = self:build()
	if same_state(s, self.last) then
		return
	end
	local prev = self.last
	self.last = s
	self.log.debug("Sync box: %s now %s (selected %s)", room_label(self), s.kind, tostring(s.selected))
	call(self, "change", copy_state(s), copy_state(prev))
end

function R:on_variable(device, variable, value)
	if not self.room_id or num.int(device, 1, room.ID_MAX) ~= self.room_id then
		return false
	end
	local key = self.by_id[num.int(variable, 1, room.ID_MAX)]
	if not key then
		return false
	end
	self:take(key, value)
	if self.phase == "trouble" and self.trouble_reason == "no answer" and key == "selected"
		and self.raw.selected ~= nil then
		-- A first callback later than BASELINE_MS: the baseline after all.
		cancel_timers(self)
		baseline_due(self)
		return true
	end
	if self.phase ~= "following" then
		return true   -- the baseline takes it (starting), or nothing does (trouble)
	end
	local now = self.now()
	self.pending_since = self.pending_since or now
	cancel(self.settle_timer)
	local wait = room.SETTLE_MS
	local left = room.SETTLE_MAX_MS - (now - self.pending_since)
	if left < wait then
		wait = left
	end
	self.settle_timer = arm(self, math.max(1, wait), function() settled(self) end)
	return true
end

function R:state()
	return copy_state(self.last)
end

function R:following()
	return self.room_id, self.name
end

function R:ids()
	local out = {}
	for k, v in pairs(self.ids_in_use) do
		out[k] = v
	end
	return out
end

function R:phase_now()
	return self.phase
end

-- The choice (Follow Room) ----------------------------------------------------------

local C = {}
C.__index = C

function room.choice(deps)
	deps = deps or {}
	return setmetatable({
		rooms_fn = deps.rooms or function()
			return C4:GetDevicesByC4iName("roomdevice.c4i")
		end,
		own_fn = deps.own_room or function()
			return C4:RoomGetId()
		end,
		get = deps.persist_get or function(name)
			return C4:PersistGetValue(name)
		end,
		set = deps.persist_set or function(name, value)
			return C4:PersistSetValue(name, value)
		end,
		log = deps.log or require("common.log"),
		rec = nil,
		checked = false,    -- the first resolve of this run has run (W24 against W3)
		mismatch = false,   -- W24 found, until a click
		offer = nil,
		by_label = nil,
	}, C)
end

-- { [id] = name } of the project's rooms, or nil when the list did not answer.
function C:rooms()
	local ok, t = pcall(self.rooms_fn)
	if not ok or type(t) ~= "table" then
		return nil
	end
	local out, n = {}, 0
	for id, name in pairs(t) do
		n = n + 1
		if n > room.ROOMS_MAX then
			break
		end
		id = num.int(id, 1, room.ID_MAX)
		if id then
			out[id] = cap(name) or ""
		end
	end
	return out
end

function C:own()
	local ok, id = pcall(self.own_fn)
	if not ok then
		return nil
	end
	return num.int(id, 1, room.ID_MAX)
end

local function check_record(v)
	if type(v) ~= "table" then
		return nil
	end
	local name = type(v.name) == "string" and cap(v.name) or nil
	if v.mode == "own" or v.mode == "none" then
		return { mode = v.mode, id = num.int(v.id, 1, room.ID_MAX), name = name }
	end
	if v.mode == "room" then
		local id = num.int(v.id, 1, room.ID_MAX)
		if id then
			return { mode = "room", id = id, name = name }
		end
	end
	return nil
end

function C:load()
	if self.rec then
		return self.rec
	end
	local ok, value = pcall(self.get, room.FOLLOW_KEY)
	local rec = ok and check_record(value) or nil
	if ok and value ~= nil and rec == nil then
		self.log.warn("Sync box: the stored Follow Room is not usable; %s is used", room.DEFAULT_FOLLOW == "none"
			and room.LABEL_NONE or room.LABEL_OWN)
	end
	self.rec = rec or { mode = room.DEFAULT_FOLLOW }
	return self.rec
end

function C:save()
	local rec = self.rec
	local ok = pcall(self.set, room.FOLLOW_KEY, { mode = rec.mode, id = rec.id, name = rec.name })
	if not ok then
		self.log.warn("Sync box: could not store Follow Room; it is kept for this run")
	end
end

function C:record()
	local rec = self:load()
	return { mode = rec.mode, id = rec.id, name = rec.name }
end

-- Rooms sorted by name, then id.
local function sorted_ids(rooms)
	local ids = {}
	for id in pairs(rooms) do
		ids[#ids + 1] = id
	end
	table.sort(ids, function(a, b)
		local na, nb = rooms[a]:lower(), rooms[b]:lower()
		if na ~= nb then
			return na < nb
		end
		return a < b
	end)
	return ids
end

local function list_text(text)
	return (tostring(text):gsub("%c", ""):gsub(",", "\226\128\154"))
end

function C:own_label(rooms)
	local own = self:own()
	local name = own and rooms and rooms[own]
	if name and name ~= "" then
		return list_text(string.format("%s (%s)", room.LABEL_OWN, name))
	end
	return room.LABEL_OWN
end

function C:items()
	local rooms = self:rooms() or {}
	local own_label = self:own_label(rooms)
	local list = { own_label, room.LABEL_NONE }
	local count = {}
	for _, name in pairs(rooms) do
		count[name] = (count[name] or 0) + 1
	end
	local by_label, label_of = {}, {}
	for _, id in ipairs(sorted_ids(rooms)) do
		local label = list_text(rooms[id] ~= "" and rooms[id] or string.format("room %d", id))
		if count[rooms[id]] > 1 or label == own_label or label == room.LABEL_NONE then
			label = string.format("%s (room %d)", label, id)
		end
		list[#list + 1] = label
		by_label[label] = id
		label_of[id] = label
	end
	self.by_label = by_label
	local rec = self:load()
	local value
	if rec.mode == "own" then
		value = own_label
	elseif rec.mode == "none" then
		value = room.LABEL_NONE
	else
		value = label_of[rec.id]
			or list_text(string.format("%s (deleted room %d)", rec.name or "a room", rec.id))
	end
	return list, value
end

function C:choose(text)
	text = type(text) == "string" and text or ""
	self:load()
	local rooms = self:rooms()
	if not self.by_label or self.by_label[text] == nil then
		self:items()
	end
	local id = self.by_label[text]
	local rec
	if id then
		rec = { mode = "room", id = id, name = rooms and rooms[id] or nil }
	elseif text == room.LABEL_NONE then
		rec = { mode = "none" }
	elseif text:sub(1, #room.LABEL_OWN) == room.LABEL_OWN then
		local own = self:own()
		rec = { mode = "own", id = own, name = own and rooms and rooms[own] or nil }
	else
		return false, "not a room of this project"
	end
	self.rec = rec
	self.mismatch, self.offer, self.checked = false, nil, true
	self:save()
	return true
end

-- The single room named `name`, other than `except`, as an offer.
local function same_name_offer(rooms, name, except, why)
	if not rooms or not name then
		return nil
	end
	local found
	for id, n in pairs(rooms) do
		if id ~= except and n == name then
			if found then
				return nil
			end
			found = id
		end
	end
	if not found then
		return nil
	end
	return { id = found, name = name,
		text = string.format("%s (room %d) %s: pick it in Follow Room", name, found, why) }
end

function C:resolve()
	local rec = self:load()
	local rooms = self:rooms()
	self.offer = nil
	if rec.mode == "none" then
		self.checked = true
		return { how = "none", status = "Follows no room" }
	end
	if rec.mode == "own" then
		local own = self:own()
		if not own then
			return { room_id = rec.id, name = rec.name, how = "unknown", status = rec.id
				and string.format("Follows %s", rec.name or ("room " .. rec.id)) or "Follows this device's room" }
		end
		local name = rooms and rooms[own] or (own == rec.id and rec.name) or nil
		local said
		if rec.id and rec.id ~= own then
			said = string.format("Follows %s now: this device moved there from %s", name or ("room " .. own),
				rec.name or ("room " .. rec.id))
		end
		if rec.id ~= own or (name and rec.name ~= name) then
			rec.id, rec.name = own, name or rec.name
			self:save()
		end
		self.checked = true
		return { room_id = own, name = name, how = "own", last_action = said,
			status = string.format("Follows %s (this device's room)", name or ("room " .. own)) }
	end
	-- An explicit room.
	local label = rec.name or ("room " .. rec.id)
	if not rooms then
		return { room_id = rec.id, name = rec.name, how = "unknown", status = string.format("Follows %s", label) }
	end
	local current = rooms[rec.id]
	if current == nil then
		self.checked = true
		self.offer = same_name_offer(rooms, rec.name, rec.id, "has its name")
		return { how = "gone", offer = self.offer,
			status = string.format("Follows a deleted room (%s, room %d)", label, rec.id),
			trouble = string.format("Follows a deleted room (%s, room %d): pick another in Follow Room", label, rec.id) }
	end
	if rec.name and current ~= rec.name then
		if not self.checked then
			self.mismatch = true
		end
		if self.mismatch then
			self.checked = true
			self.offer = same_name_offer(rooms, rec.name, rec.id, "has the name it had")
			return { how = "mismatch", offer = self.offer,
				status = string.format("Not following: room %d was %s and is now %s", rec.id, rec.name, current),
				trouble = string.format("Follow Room names %s (room %d), which is now %s: pick the room again in "
					.. "Follow Room", rec.name, rec.id, current) }
		end
		-- W3: renamed while the driver runs; the id stands, the label follows.
		self.log.debug("Sync box: followed room %d renamed", rec.id)
		rec.name = current
		self:save()
	elseif not rec.name then
		rec.name = current
		self:save()
	end
	self.checked = true
	local status = string.format("Follows %s", current)
	local own = self:own()
	if own and own ~= rec.id then
		status = string.format("Follows %s (chosen; this device is in %s)", current, rooms[own] or ("room " .. own))
	end
	return { room_id = rec.id, name = current, how = "chosen", status = status }
end

function C:accept_offer()
	local offer = self.offer
	if not offer then
		return false
	end
	self.rec = { mode = "room", id = offer.id, name = offer.name }
	self.mismatch, self.offer, self.checked = false, nil, true
	self:save()
	return true
end

-- W20: the room whose picture runs through the box -----------------------------------

function room.path_offer(o)
	o = o or {}
	local box_ids = o.box_ids or {}
	local read = o.read or function(id)
		return C4:GetDeviceVariable(id, room.VIDEO_PATH_ID)
	end
	local function through(id)
		local ok, text = pcall(read, id)
		if not ok then
			return false
		end
		for _, x in ipairs(parse_path(text)) do
			if box_ids[x] then
				return true
			end
		end
		return false
	end
	local followed = num.int(o.followed, 1, room.ID_MAX)
	if followed and through(followed) then
		return nil
	end
	local rooms, n = {}, 0
	for id, name in pairs(o.rooms or {}) do
		n = n + 1
		if n > room.ROOMS_MAX then
			break
		end
		id = num.int(id, 1, room.ID_MAX)
		if id then
			rooms[id] = cap(name) or ""
		end
	end
	local found
	for _, id in ipairs(sorted_ids(rooms)) do
		if id ~= followed and through(id) then
			if found then
				return nil   -- more than one: nothing to offer
			end
			found = id
		end
	end
	if not found then
		return nil
	end
	local name = rooms[found] ~= "" and rooms[found] or ("room " .. found)
	return { id = found, name = name,
		text = string.format("%s's picture runs through this box (Follow Room)", name) }
end

room.contains = contains

return room
