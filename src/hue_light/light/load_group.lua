-- A Hue Light device's side of Control4 Load Groups (#435,
-- docs/load-groups-design.md): the memberships the device keeps (D6), and
-- the translation of each group command into the paths the light already
-- uses for its own commands (D3, D4, D11, D12). A pure module: everything
-- it does to the light, the bridge, persistence or Composer goes through
-- callbacks the light driver passes to new(), so the driver's main chunk
-- gains one local (§2.3, tools/lua_limits.py) and the specs need no driver.
--
-- The contract's interface (§6.5), exactly as it names it:
--
--   local load_group = require("light.load_group")
--   load_group.KEY = "hue_load_groups"
--   load_group.COMMANDS = {             -- proxy command -> op
--   	JOIN_GROUP = "join", LEAVE_GROUP = "leave", SET_GROUP_SYNC = "sync",
--   	GROUP_SET_LEVEL = "set", SET_GROUP_LEVEL = "set", GROUP_RAMP_TO_LEVEL = "ramp",
--   	GROUP_START_RAMP = "start", GROUP_STOP_RAMP = "stop",
--   }
--   -- §6.2 spellings; numbers clamped (level 0..100, time and rate >= 0).
--   load_group.parse(command, params)
--   	--> { op, group = "1234", sync = bool|nil, level = n|nil, time = ms|nil, up = bool|nil, rate = ms|nil }
--   	--> or nil, why    ("no group id", "unknown command")
--   local m = load_group.new({
--   	persist_get = function(key) end, persist_set = function(key, value) end,
--   	display_name = function(device_id) end,   -- C4:GetDeviceDisplayName [verified: API 32/_6]; nil or "" when unknown
--   	log = log,
--   })
--   m:load()                     -- the persisted list; bad values dropped
--   m:join(id, sync)  --> changed   m:leave(id) --> changed
--   m:set_sync(id, sync) --> changed   m:learn(id) --> changed (false when known)
--   m:has(id) --> bool           m:ids() --> sorted list of id strings
--   m:wire() --> "1234:1,5678:0" or "none"
--   m:text() --> the Load Groups row (§6.1)
--   -- The whole-range hold arithmetic start_ramp uses, as a pure function.
--   load_group.hold_plan(from, up, rate_ms, max_ms) --> { to, duration, full, step }
--
-- Added here for the translation, which the coordinator asked this module
-- to own so the driver only wires it (each one cites the decision it
-- carries out):
--
--   m:handle(command, params)  --> the parsed command and what was done, or nil, why
--   	The seven proxy handlers of §6.2 in one (eight names with the alias):
--   	register it for every name in load_group.COMMANDS, wrapped by
--   	after_late_init. Logs a command name's first arrival in full (D16);
--   	learns an unknown id from any group command (D6), announcing the new
--   	list before the command's own request goes out; then joins, leaves,
--   	records sync, or acts through the hooks below.
--   m:announce()               the list to the bridge (send_groups) and to the
--   	Load Groups row (show): after every hello, and at late init (E5)
--   m:holding() --> rec|nil    the running group hold (D3): { group, up, rate,
--   	active, ramping, level, to, step, timer, full, wait, expiry }
--   m:stop_hold(why) --> bool  a member's own stop (keypad press while it
--   	runs, SET_BRIGHTNESS_STOP, STOP_SCENE_RAMP; D12): the hold's stop goes
--   	to the bridge untagged (D11); false when no group hold runs
--   m:end_hold(why) --> bool   the group hold ends without a stop: another
--   	brightness command or a keypad hold replaces the dim at Hue (D11,
--   	#421 D11), the bridge was unbound, the driver is destroyed
--
-- Callbacks for the translation (all optional for the membership part;
-- a missing one is skipped, with one warning per name for the required):
--
--   send_groups(wire)          HUE_LOAD_GROUPS { device_id, rid, kind, groups = wire } (§6.3)
--   show(text)                 the read-only Load Groups property (§6.1)
--   ready(command) --> bool    the driver's ready(): false drops a hold start (it logs and writes Status)
--   is_on() --> true|false|nil dev.is_on(), the on state a keypad hold starts from
--   level() --> n|nil          the level the light shows, proxy percent: a running ramp's
--   	estimate, else the cache (the "from" of the keypad's dev.on_hold)
--   set_brightness(level, rate, group) --> bool
--   	the driver's set_brightness with the group tag (§6.6); it checks ready() itself
--   default_rate() --> ms      #430's brightness default rate (dev.rate_default) where the
--   	turn-on design (docs/turn-on-design.md §4) gives one; 0 without the hook (D4)
--   hold_rate(up) --> ms       the device's Hold Rate Up or Down, for a start without RATE
--   ramp() --> r|nil           the driver's running timed ramp record (#421 D6), r.group its tag
--   stop_ramp(why, group) --> bool
--   	the driver's stop_ramp, its HUE_SET (or HUE_DIM) tagged with `group` (D12)
--   report()                   CHANGED with the cache; the light driver leaves a brightness
--   	target still waiting for the bridge to close its own CHANGING instead (the cache
--   	would show the level before it)
--   start_dim(rec, up, from, rate)
--   	the driver's start_ramp for a group record: rec.active is its liveness test
--   	(instead of dev.holding); `rate` is the whole-range time, already capped (hold_plan's
--   	`full`); the HUE_DIM up or down carries group = rec.group; it sets rec.ramping
--   	(false when the dim did not reach the bridge), rec.level, rec.to, rec.step,
--   	rec.timer as it does for a keypad record. Returning true or false also works.
--   finish_dim(rec, group)     the driver's on_finish for a group record: HUE_DIM stop with
--   	level = rec.level rounded, group = `group` (nil for a member's own stop), and the
--   	fallback armed
--   set_timer(ms, fn) --> timer  a one-shot timer with :Cancel() (default C4:SetTimer)
--
-- What the coordinator wires around it in src/hue_light/driver.lua (§6.6):
-- m:load() at late init before the hello, then m:announce() after every
-- hello; m:end_hold() in set_brightness before its send (a group's own
-- set and ramp end it here already) and when the keypad's own hold starts;
-- m:stop_hold() where stop_ramp runs for a tap, SET_BRIGHTNESS_STOP and
-- STOP_SCENE_RAMP, and m:holding() in dev.ramp_active(); m:end_hold() when
-- the bridge is unbound and in OnDriverDestroyed. Not in settle() or
-- start_ramp() generically: the group record's own start runs through them.
--
-- Every choice that rests on an assumption of §2.2 is in load_group.ASSUME,
-- so a correction after the house round (H0 to H8) is a Lua-only edit there.

local log = require("common.log")
local device = require("common.device")

local load_group = {}

load_group.KEY = "hue_load_groups"

load_group.COMMANDS = {             -- proxy command -> op
	JOIN_GROUP = "join", LEAVE_GROUP = "leave", SET_GROUP_SYNC = "sync",
	GROUP_SET_LEVEL = "set", SET_GROUP_LEVEL = "set", GROUP_RAMP_TO_LEVEL = "ramp",
	GROUP_START_RAMP = "start", GROUP_STOP_RAMP = "stop",
}

-- The assumptions (docs/load-groups-design.md §2.2), in one place. Each
-- entry says what the house check would change.
load_group.ASSUME = {
	-- §6.2: parameter keys, tried in order; values are strings. The light_v2
	-- reference prints the names with spaces [verified: LV2 cmds _14 to
	-- _20]; for SET_COLOR_TARGET the house's proxy sent underscores
	-- [verified: hardware 2026-10-22], so underscores come first [assumed for
	-- these commands until H2 logs the first arrival, D16]. A spelling seen
	-- at H2 goes into these lists.
	keys = {
		group = { "GROUP_ID", "GROUP ID" },
		sync = { "KEEP_SYNC", "KEEP SYNC" },
		level = { "LEVEL" },
		time = { "TIME" },
		up = { "RAMP_UP", "RAMP UP" },
		rate = { "RATE" },
	},
	-- A5: GROUP_START_RAMP's RATE is the time of the whole range, as a hold
	-- rate is (L14), so a hold moves at 100 % per RATE from any level
	-- [assumed]. false: RATE is the time from where the light is to the end
	-- of the range, and the whole-range time is worked out from it.
	rate_whole_range = true,
	-- A5: GROUP_RAMP_TO_LEVEL's TIME is in ms [assumed: the reference gives
	-- no unit; RATE of GROUP_START_RAMP is ms, verified: LV2 cmds _19]. 1000
	-- if H4 shows seconds.
	time_scale = 1,
	-- A6, D6: JOIN_GROUP may come only once, so a group command whose id the
	-- list lacks is proof of membership and adds it. false: such a command
	-- still acts (D5) but is not remembered.
	learn = true,
}

-- Mirrors of the light driver's and common/device.lua's constants, which
-- the group hold must match (§6.2 GROUP_START_RAMP); the cap is read where
-- it is kept:
load_group.HOLD_TICK_MS = 100      -- driver.lua HOLD_TICK_MS: the estimate's tick
-- driver.lua HOLD_MAX_MS, which is device.RATE_MAX since #430 D20: the cap
-- on a hold's whole-range time.
load_group.HOLD_MAX_MS = device.RATE_MAX
load_group.DIM_AFTER_ON_MS = 600   -- device.lua DIM_AFTER_ON_MS: the dim after a hold's 1 % turn-on
load_group.FALLBACK_MS = 1000      -- driver.lua FALLBACK_MS: E10's grace after the whole range
-- A start without RATE and without the hold_rate hook: the Hold Rate
-- default (5000 ms, #421 D3 "hold rates stay at 5000 ms").
load_group.DEFAULT_HOLD_MS = 5000
-- The Load Groups row fits Composer's column (L73, §6.1): at most this many
-- characters, or the summary "3 load groups: Kitchen Group, …".
load_group.TEXT_MAX = 75

-- Helpers -------------------------------------------------------------------

-- A finite number, or nil (tonumber accepts "inf" and "nan" through strtod).
local function number(v)
	local n = tonumber(v)
	if n == nil or n ~= n or n == math.huge or n == -math.huge then
		return nil
	end
	return n
end

-- A device id as the list keys it: a positive whole number, as a string of
-- digits without leading zeros; nil for anything else. Strings must be
-- digits only (§6.4: a key that is not a positive integer string is
-- dropped); a whole number is taken too, in case the controller's table
-- store hands numeric-looking keys back as numbers [assumed].
local function id_of(v)
	local n
	if type(v) == "number" then
		n = v
	elseif type(v) == "string" and #v <= 15 and v:match("^%d+$") then
		n = tonumber(v)
	end
	if not (number(n) and n >= 1 and n == math.floor(n) and n < 1e15) then
		return nil
	end
	return string.format("%d", n)
end

-- The first key of `keys` with a value in `params`; "" counts as none
-- (SendToDevice and the proxy drop or blank empty values).
local function pick(params, keys)
	for _, key in ipairs(keys) do
		local v = params[key]
		if v ~= nil and v ~= "" then
			return v
		end
	end
	return nil
end

-- "1" is true, anything else false (§6.2: KEEP SYNC and RAMP UP are 1 or
-- 0 [verified: LV2 cmds _14, _16, _19]).
local function one(v)
	return number(v) == 1
end

-- Characters of a UTF-8 text: every byte that is not a continuation byte
-- (0x80-0xBF) starts one.
local function chars(s)
	local n = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 128 or b > 191 then
			n = n + 1
		end
	end
	return n
end

-- The longest prefix of `s` with at most `n` characters, ending before a
-- character, without trailing spaces or commas.
local function cut(s, n)
	local count = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 128 or b > 191 then
			count = count + 1
			if count > n then
				return (s:sub(1, i - 1):gsub("[%s,]+$", ""))
			end
		end
	end
	return s
end

-- The params of a command, sorted, for D16's first-arrival line:
-- GROUP_ID="1234", LEVEL="40". Quoted, so a key with a space reads as one.
local function describe(params)
	local out = {}
	for k, v in pairs(params) do
		out[#out + 1] = string.format("%s=%q", tostring(k), tostring(v))
	end
	table.sort(out)
	return #out > 0 and table.concat(out, ", ") or "no parameters"
end

-- True when `l` would print a line at `level`; a log without enabled()
-- (a spec's capture) prints everything.
local function enabled(l, level)
	return type(l.enabled) ~= "function" or l.enabled(level) == true
end

local function default_set_timer(ms, fn)
	return C4:SetTimer(ms, fn) -- [verified: API 34_timer, as every driver timer here]
end

-- Parsing and arithmetic ----------------------------------------------------

-- §6.2: a proxy command's op and parameters. The GROUP ID is required for
-- every command (each page lists it [verified: LV2 cmds _14 to _20]); the
-- rest is read when present, whatever the op, and the handler uses what
-- its op needs. RAMP UP absent is not up.
function load_group.parse(command, params)
	local op = load_group.COMMANDS[command]
	if not op then
		return nil, "unknown command"
	end
	params = type(params) == "table" and params or {}
	local keys = load_group.ASSUME.keys
	local group = id_of(pick(params, keys.group))
	if not group then
		return nil, "no group id"
	end
	local out = { op = op, group = group }
	local sync = pick(params, keys.sync)
	if sync ~= nil then
		out.sync = one(sync)
	end
	local level = number(pick(params, keys.level))
	if level then
		out.level = math.max(0, math.min(100, level))
	end
	local time = number(pick(params, keys.time))
	if time then
		out.time = math.max(0, time * load_group.ASSUME.time_scale)
	end
	local up = pick(params, keys.up)
	if up ~= nil then
		out.up = one(up)
	end
	local rate = number(pick(params, keys.rate))
	if rate then
		out.rate = math.max(0, rate)
	end
	return out
end

-- The light driver's start_ramp arithmetic (#232, #249), for its keypad
-- record and the group record alike: a hold heads for the end of the range
-- (100 up, 1 down) and asks Hue for the whole range over `full` ms (the
-- rate, capped at max_ms, whole ms); the tile gets the share of it the
-- distance takes (`duration`), and the estimate moves `step` points every
-- HOLD_TICK_MS.
function load_group.hold_plan(from, up, rate_ms, max_ms)
	local to = up and 100 or 1
	local full = math.floor(math.min(math.max(0, number(rate_ms) or 0), max_ms or load_group.HOLD_MAX_MS))
	local duration = math.floor(full * math.abs(to - from) / 100)
	return {
		to = to,
		duration = duration,
		full = full,
		step = (to - from) / math.max(1, duration / load_group.HOLD_TICK_MS),
	}
end

-- The device's list ------------------------------------------------------------

local methods = {}
methods.__index = methods

-- Translation callbacks whose absence is a wiring fault, warned once.
local REQUIRED = {
	set_brightness = true, start_dim = true, finish_dim = true, stop_ramp = true, report = true,
	send_groups = true, show = true,
}

function load_group.new(opts)
	opts = opts or {}
	return setmetatable({
		opts = opts,
		log = opts.log or log,
		groups = {},   -- id string -> { sync = bool }
		seen = {},     -- command -> true once its first arrival was logged this run (D16)
		warned = {},   -- callback name -> true once its absence was warned
		hold = nil,    -- the running group hold (m:holding()), nil while none
	}, methods)
end

-- A callback's answer; nil when it is not given.
function methods:call(name, ...)
	local fn = self.opts[name]
	if type(fn) ~= "function" then
		if REQUIRED[name] and not self.warned[name] then
			self.warned[name] = true
			self.log.warn("load groups: no %s callback; skipped", name)
		end
		return nil
	end
	return fn(...)
end

-- A one-shot timer whose body runs pcall-wrapped (a raise is logged).
function methods:timer(ms, fn)
	local set = self.opts.set_timer or default_set_timer
	return set(math.max(1, math.floor(ms + 0.5)), function()
		local ok, err = pcall(fn)
		if not ok then
			self.log.error("load group timer failed: %s", tostring(err))
		end
	end)
end

-- The Composer name of a Load Group device, nil when none is found (E3:
-- the id stays; only the text says so).
function methods:name_of(id)
	local ok, name = pcall(self.opts.display_name or function() return nil end, tonumber(id))
	if not ok or type(name) ~= "string" then
		return nil
	end
	name = name:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
	return name ~= "" and name or nil
end

-- "1234 (Kitchen Group)" for the log, "1234" without a name.
function methods:label(id)
	local name = self:name_of(id)
	return name and string.format("%s (%s)", id, name) or id
end

-- §6.4: a fresh copy each time; the store keeps what was written, not a
-- live reference (as the saved level, driver.lua save()).
function methods:save()
	local copy = {}
	for id, g in pairs(self.groups) do
		copy[id] = { sync = g.sync }
	end
	self:call("persist_set", load_group.KEY, copy)
end

-- §6.4, L83: the persisted list. A value that is not a table, an entry
-- whose key is not a positive integer string, or whose value is not a
-- table, is dropped with a warning, and the cleaned list is stored again.
-- Returns how many groups were loaded.
function methods:load()
	self.groups = {}
	local value = self:call("persist_get", load_group.KEY)
	if value == nil then
		return 0
	end
	local dirty = false
	if type(value) ~= "table" then
		self.log.warn("stored %s is not a list of load groups (%s); dropped", load_group.KEY, tostring(value))
		dirty = true
	else
		for k, v in pairs(value) do
			local id = id_of(k)
			if id and type(v) == "table" then
				local had = self.groups[id]
				self.groups[id] = { sync = (had and had.sync) or v.sync == true }
				dirty = dirty or id ~= k
			else
				self.log.warn("stored load group %s = %s dropped: not a device id with its settings",
					tostring(k), tostring(v))
				dirty = true
			end
		end
	end
	if dirty then
		self:save()
	end
	return #self:ids()
end

-- E1, D16: JOIN_GROUP's flag is the group's word (1 true, else false).
function methods:join(id, sync)
	id = id_of(id)
	if not id then
		return false
	end
	sync = sync == true
	local had = self.groups[id]
	if had and had.sync == sync then
		return false
	end
	self.groups[id] = { sync = sync }
	self:save()
	if had then
		self.log.info("load group %s: keep loads in sync %s", self:label(id), sync and "on" or "off")
	else
		self.log.info("joined load group %s, keep loads in sync %s", self:label(id), sync and "on" or "off")
	end
	return true
end

-- E2: an id the list lacks changes nothing (§6.2).
function methods:leave(id)
	id = id_of(id)
	if not (id and self.groups[id]) then
		return false
	end
	self.groups[id] = nil
	self:save()
	self.log.info("left load group %s", self:label(id))
	return true
end

-- E4, D13: the flag is recorded and shown, never acted on. An id the list
-- lacks is learnt with it.
function methods:set_sync(id, sync)
	id = id_of(id)
	if not id then
		return false
	end
	sync = sync == true
	local had = self.groups[id]
	if had and had.sync == sync then
		return false
	end
	self.groups[id] = { sync = sync }
	self:save()
	self.log.info("load group %s: keep loads in sync %s%s", self:label(id), sync and "on" or "off",
		had and "" or " (learnt)")
	return true
end

-- D6: a group command is proof of membership; false when the id is known.
function methods:learn(id)
	id = id_of(id)
	if not id or self.groups[id] then
		return false
	end
	self.groups[id] = { sync = false }
	self:save()
	self.log.info("load group %s learnt from a group command", self:label(id))
	return true
end

function methods:has(id)
	id = id_of(id)
	return id ~= nil and self.groups[id] ~= nil
end

-- In numeric order, so the wire, the row and the logs agree.
function methods:ids()
	local out = {}
	for id in pairs(self.groups) do
		out[#out + 1] = id
	end
	table.sort(out, function(a, b) return tonumber(a) < tonumber(b) end)
	return out
end

-- §6.3: "1234:1,5678:0" (id and sync flag), or "none" for an empty list
-- (SendToDevice drops empty values).
function methods:wire()
	local out = {}
	for i, id in ipairs(self:ids()) do
		out[i] = id .. ":" .. (self.groups[id].sync and "1" or "0")
	end
	return #out > 0 and table.concat(out, ",") or "none"
end

-- §6.1, L73: "None"; "Kitchen Group"; "Kitchen Group (in sync), Hallway
-- Group"; an id without a name "device 1234 (not found)"; past TEXT_MAX
-- characters "3 load groups: Kitchen Group, …" with as many names as fit.
-- Names are read each time the row is written (E5).
function methods:text()
	local ids = self:ids()
	if #ids == 0 then
		return "None"
	end
	local parts = {}
	for i, id in ipairs(ids) do
		local name = self:name_of(id) or string.format("device %s (not found)", id)
		parts[i] = name .. (self.groups[id].sync and " (in sync)" or "")
	end
	local max = load_group.TEXT_MAX
	local full = table.concat(parts, ", ")
	if chars(full) <= max then
		return full
	end
	if #parts == 1 then
		return cut(full, max - 1) .. "…"
	end
	local head = string.format("%d load groups: ", #parts)
	local taken = {}
	for _, part in ipairs(parts) do
		taken[#taken + 1] = part
		if chars(head .. table.concat(taken, ", ") .. ", …") > max then
			taken[#taken] = nil
			break
		end
	end
	if #taken == 0 then
		return head .. cut(parts[1], max - chars(head) - 1) .. "…"
	end
	return head .. table.concat(taken, ", ") .. ", …"
end

-- D6, E5, E19: the list to the bridge and the row.
function methods:announce()
	self:call("send_groups", self:wire())
	self:call("show", self:text())
end

-- The group hold (D3, §6.2 GROUP_START_RAMP) --------------------------------
-- A hold that no keypad button owns: the record lives here, the dim and its
-- stop run through the driver's own start_ramp and on_finish (start_dim,
-- finish_dim). One at a time; a new start ends the running one first.

function methods:holding()
	return self.hold
end

-- The record ends; its timers stop, nothing goes to the bridge.
function methods:end_hold(why)
	local rec = self.hold
	if not rec then
		return false
	end
	self.hold = nil
	rec.active = false
	if rec.wait then
		rec.wait:Cancel()
		rec.wait = nil
	end
	if rec.expiry then
		rec.expiry:Cancel()
		rec.expiry = nil
	end
	if rec.timer then
		rec.timer:Cancel() -- start_ramp's tick; it also tests rec.active first
	end
	self.log.debug("group hold of load group %s ended: %s", rec.group, tostring(why or "ended"))
	return true
end

-- The release: the record ends, and when the dim had gone out its stop
-- follows, tagged `group` (D12 for the group's own stop; nil for the
-- member's own, D11). A hold still waiting for its 1 % turn-on sends
-- nothing: the turn-on stands, as a keypad release in that wait leaves it.
function methods:finish(rec, group, why)
	local ramping = rec.ramping
	self:end_hold(why)
	if ramping then
		self:call("finish_dim", rec, group)
	end
end

-- D12: a member's own stop stops a group hold too.
function methods:stop_hold(why)
	local rec = self.hold
	if not rec then
		return false
	end
	self:finish(rec, nil, why or "the light's own stop")
	return true
end

-- The dim of a group hold from `from`: the whole-range time from RATE (or
-- the Hold Rate), capped (hold_plan), through start_ramp; then E10's end:
-- a hold whose GROUP_STOP_RAMP never comes ends itself after the whole
-- range plus FALLBACK_MS, when Hue has reached the end of the range (a
-- hold asks for no more than the range at its rate, L47), and the proxy
-- hears the cache.
function methods:dim(rec, from)
	from = math.max(1, number(from) or 1)
	local rate = rec.rate
	if rate == nil then
		rate = number(self:call("hold_rate", rec.up)) or load_group.DEFAULT_HOLD_MS
	end
	if not load_group.ASSUME.rate_whole_range then
		rate = rate * 100 / math.max(1, math.abs((rec.up and 100 or 1) - from))
	end
	local plan = load_group.hold_plan(from, rec.up, rate, load_group.HOLD_MAX_MS)
	rec.full = plan.full
	local sent = self:call("start_dim", rec, rec.up, from, plan.full)
	if sent ~= nil then
		rec.ramping = sent and true or false
	end
	if self.hold ~= rec then
		return -- the callback ended it
	end
	if not rec.ramping then
		self:end_hold("the dim did not reach the bridge")
		return
	end
	rec.expiry = self:timer(plan.full + load_group.FALLBACK_MS, function()
		rec.expiry = nil
		if self.hold == rec then
			self.log.info("group hold of load group %s ended by itself after %d ms: no GROUP_STOP_RAMP came",
				rec.group, plan.full + load_group.FALLBACK_MS)
			self:end_hold("its time ran out")
			self:call("report")
		end
	end)
end

-- §6.2 GROUP_START_RAMP (D3, L42, L43, L14): dropped when the light cannot
-- be driven; down while off does nothing; up while off turns on at 1 %
-- (tagged, so the members' turn-ons batch) and dims up DIM_AFTER_ON_MS
-- later; on, the dim starts from the level shown, or from where a group
-- hold it replaces had got to.
function methods:start(p, command)
	if self.opts.ready and not self:call("ready", command) then
		return "dropped"
	end
	local prev = self.hold
	local from_prev = prev and prev.ramping and prev.level or nil
	self:end_hold("a new group start")
	local up = p.up == true
	if not up and self:call("is_on") ~= true then
		self.log.debug("%s from load group %s: dimming down a light that is off does nothing", command, p.group)
		return "nothing"
	end
	local rec = { group = p.group, up = up, rate = p.rate, active = true }
	if self:call("is_on") == true then
		self.hold = rec
		self:dim(rec, from_prev or self:call("level") or 1)
		return "hold"
	end
	if not self:call("set_brightness", 1, 0, p.group) then
		return "failed" -- the turn-on never reached the bridge (logged): nothing to dim up from
	end
	self.hold = rec
	rec.wait = self:timer(load_group.DIM_AFTER_ON_MS, function()
		rec.wait = nil
		if self.hold == rec then
			self:dim(rec, self:call("is_on") == true and self:call("level") or 1)
		end
	end)
	return "hold"
end

-- §6.2 GROUP_STOP_RAMP (D12): the hold of that group; else a timed ramp
-- that group started (its stop tagged, so it batches with the siblings');
-- else, with nothing of the light's running, CHANGED with the cache, as
-- SET_BRIGHTNESS_STOP with nothing running does. A hold or ramp of
-- someone else (another group, the light's own keypad, programming) is
-- left running and its CHANGING stands: a CHANGED with the cache in the
-- middle of it would show a level the light is not at.
function methods:stop(p, command)
	local rec = self.hold
	if rec and rec.group == p.group then
		self:finish(rec, p.group, command)
		return "hold stopped"
	end
	local r = self:call("ramp")
	if r and r.group == p.group and self:call("stop_ramp", command, p.group) then
		return "ramp stopped"
	end
	if rec or r then
		self.log.debug("%s from load group %s: the running %s is not this group's; left running", command,
			p.group, rec and "group hold" or "ramp")
		return "left running"
	end
	self:call("report")
	return "report"
end

-- §6.2 GROUP_SET_LEVEL and GROUP_RAMP_TO_LEVEL (D3, D4): a target through
-- set_brightness with the group tag. A set has no rate and a ramp may come
-- without TIME: both take #430's default rate where the driver has one
-- (as SET_BRIGHTNESS_TARGET without RATE, docs/turn-on-design.md §4), else
-- 0. A ramp's time above 0 makes it a ramp the light's own stops can stop
-- (#421 D6). A running group hold ends first (#421 D11).
function methods:level_command(p, command)
	if p.level == nil then
		self.log.warn("%s from load group %s without a level; ignored", command, p.group)
		return "ignored"
	end
	local rate = p.op == "ramp" and p.time or nil
	if rate == nil then
		rate = number(self:call("default_rate")) or 0
	end
	self:end_hold(command)
	self.log.debug("%s from load group %s: %s %% over %d ms", command, p.group, tostring(p.level), math.floor(rate))
	self:call("set_brightness", p.level, rate, p.group)
	return p.op
end

-- §6.2: every group command. Returns the parsed command and what was done
-- (the op for "join", "leave", "sync", "set", "ramp"; a start's "hold",
-- "nothing", "dropped" or "failed"; a stop's "hold stopped", "ramp
-- stopped", "left running" or "report"; "ignored" for a level command
-- without a level), or nil and why.
function methods:handle(command, params)
	params = type(params) == "table" and params or {}
	-- As common/device.lua's first_arrival: one that arrives while the log
	-- would not show it is not marked, so the first one after Debug Mode is
	-- turned on is logged instead (H2 reads the spellings off it).
	if load_group.COMMANDS[command] and not self.seen[command] and enabled(self.log, "info") then
		self.seen[command] = true
		self.log.info("first %s this run: %s", command, describe(params))
	end
	local p, why = load_group.parse(command, params)
	if not p then
		self.log.warn("%s ignored: %s", tostring(command), why)
		return nil, why
	end
	local changed, done = false, p.op
	if p.op == "join" then
		changed = self:join(p.group, p.sync)
	elseif p.op == "leave" then
		changed = self:leave(p.group)
		if not changed then
			self.log.debug("%s: not in load group %s; nothing to do", command, p.group)
		end
	elseif p.op == "sync" then
		changed = self:set_sync(p.group, p.sync)
	elseif load_group.ASSUME.learn then
		changed = self:learn(p.group)
	end
	if changed then
		self:announce()
	end
	if p.op == "set" or p.op == "ramp" then
		done = self:level_command(p, command)
	elseif p.op == "start" then
		done = self:start(p, command)
	elseif p.op == "stop" then
		done = self:stop(p, command)
	end
	return p, done
end

return load_group
