-- The box's programming surface (#568, docs/hdmi-sync-stage4-design.md §3,
-- contracts C1.6 to C1.9 in docs/hdmi-sync-contracts.md, design
-- docs/hdmi-sync-design.md §5.3 and §5.5): the twelve commands as writes for
-- syncbox/queue.lua, the nine variables, the twelve events from the box's
-- state, the seven conditionals, and the manual hold the periods keep.
--
--   local p = programming.new{ queue, model_now, periods, period, areas,
--                              last_action, on_busy, changed, log,
--                              set_variable, fire_event, add_variable,
--                              persist_get, persist_set }
--   p:init()         OnDriverInit: the nine variables (C1.9) added in their
--                    fixed order, read-only, each at its persisted value
--   p:command(name, params)  a programming command (ExecuteCommand; the
--                    names of C1.6, spaces or "_" alike, any case) -> true
--                    when queued, else false and why; every outcome ends
--                    in Last Action once the queue answers
--   p:button(name)   a UI Button's press (C1.1: "Hue Sync", "Sync Brighter",
--                    "Sync Dimmer", "Sync Intensity") as its command
--   p:observe(model, prev, cause)  every good read (syncbox/state.lua's
--                    model): the variables whose value changed are set,
--                    then their events fire; `cause` "takeover" adds Sync
--                    Taken Over (stage 4 §1 item 6); `prev` is not used:
--                    the variables themselves are the baseline, kept
--                    across a restart
--   p:online(flag[, cause])  ONLINE: false fires Offline, true Online
--   p:test(name, params)  TestCondition for the conditionals of C1.8
--   p:manual(field)  "intensity" or "brightness" changed by hand: the
--                    periods hold it (design 5.3)
--   p:param_list(command, param)  GetCommandParamList (the DYNAMIC_LIST
--                    Area parameters)
--   p:value(name)    a variable's text now; p:values() all of them
--   p:icon_state(button)  "on"/"off" (Hue Sync) or the intensity (Sync
--                    Intensity), for the buttons' icons; nil for the others
--
-- deps (every one but queue and model_now optional; queue, periods and
-- areas may be the object or a function returning it, so the module can
-- be made in OnDriverInit and its parts built at late init):
--   queue        syncbox/queue.lua's: q:set(fields, tag, cb) with
--                cb(tag, ok, model, why, detail); q:target() the pending
--                fields, when it has one
--   model_now()  the last good read's model (poller:last_model())
--   periods      syncbox/periods.lua's: p:hold(field) on a manual change,
--                p:release(reason) when sync stops or the input changes
--                (seen in a read, any cause), p:held(field) when it has
--                one; and, without `period`, p:current() and
--                p:settings_for(period, mode) -> { intensity, brightness }
--   period(mode) optional: the period's { intensity, brightness } for a
--                sync start in `mode` (the driver's own, shared with
--                av.lua's period), held fields left out
--   areas        optional, syncbox/areas.lua's: a:resolve(value) -> id, name
--                | nil, Last Action's text for an Area value the box's list
--                does not name ("area:<id>" from its CUSTOM_SELECT list,
--                or a re-pointed id); a:names() the DYNAMIC_LIST, when it
--                has one (else the model's area names)
--   last_action(text)  Last Action
--   on_busy(fields, tag)  optional: a write that starts a sync ended busy
--                (code 16, another app streams): true when the driver's
--                take-over handles it (stage 4 §1 item 6); else Last
--                Action says the box is busy
--   changed(names, values)  optional: after an observe that changed any
--                variable (names a list in C1.9's order), for the icons
--   set_variable(name, value), fire_event(id), add_variable(name, value,
--                type, read_only, hidden), persist_get(key),
--                persist_set(key, value): default C4:SetVariable,
--                C4:FireEventByID, C4:AddVariable, C4:PersistGetValue,
--                C4:PersistSetValue
--
-- DriverWorks facts:
--   - C4:AddVariable(identifier, strValue, strVarType, bReadOnly, bHidden)
--     in OnDriverInit; a BOOL takes "1" and "0" as text; by name, ids are
--     1001, 1002, ... in the order added, and programming refers to the ids,
--     so the order never changes [verified: SDK docs-driverworks-api
--     36_variable/_1-AddVariable.md]. A variable that exists already (an
--     update in place) answers false and keeps going [assumed, as the
--     motion driver: the doc says a name that is not unique fails].
--   - C4:SetVariable(identifier, strValue), never in OnDriverInit
--     [verified: 36_variable/_7-SetVariable.md].
--   - C4:FireEventByID(id), never in OnDriverInit, from OS 2.8.0 [verified:
--     7_event/_4-FireEventByID.md].
--   - TestCondition(name, tParams): name is the conditional's <name>;
--     NUMBER and LIST carry VALUE and LOGIC (EQUAL, NOT_EQUAL, LESS_THAN,
--     LESS_THAN_OR_EQUAL, GREATER_THAN, GREATER_THAN_OR_EQUAL; LIST
--     EQUAL and NOT_EQUAL); it returns a boolean [verified:
--     docs-driverworks-fundamentals 10_conditionals/_4-
--     USINGTHETESTCONDITIONFUNCTION.md]. A BOOL's table is documented as
--     empty while the same page's sample reads its VALUE as the true or
--     false text; the motion driver reads VALUE as that text, and so does
--     this [assumed: VALUE is the <true_text> or <false_text> picked; with
--     none, the question is "is it true"]. A LIST's description may offer
--     the ordering operators (10_conditionals/_5-XMLINALISTTYPECONDITIONAL.md):
--     Intensity and HDMI Input answer them by their order.
--   - Programming commands arrive at ExecuteCommand under their <name>,
--     spaces and all, their parameters keyed by the <param> <name>, as text
--     [verified: fundamentals 9_commands/_1-COMMANDS.md; the light driver's
--     Raise Level By]. A DYNAMIC_LIST parameter's items come from
--     GetCommandParamList(commandName, paramName), OS 3.3.0 and later
--     [verified: 9_commands/_1-COMMANDS.md].
--   - C4:PersistSetValue takes a table [verified: 26.5_persistence/
--     _4-PersistSetValue.md].
--
-- Rules (design 5.3, 5.5; C1.9):
--   - Every variable is set before the event that reports its change; no
--     event fires for a value that did not change, and none for a value
--     never known before (the first read after an install or after an
--     update from a build without programming is a baseline): a Director
--     restart during a film never runs "Sync Started" programming again.
--   - The commands write only `execution` through the queue, one q:set per
--     command, so Apply Sync Settings is one PUT, the mode before the
--     intensity (queue.body_of puts the intensity inside the mode's object,
--     the box's order SB55). Toggles, cycles and steps are worked out here
--     from the pending write (q:target) or the last read, never sent as the
--     box's toggles: a resend must change nothing more (SB57), and a burst
--     of Sync Brighter presses steps from the last value asked for.
--   - A command that starts a sync (or changes the sync mode) carries the
--     period's intensity and brightness, the fields the periods hold for a
--     manual change left out (design 5.3); a mode change while the
--     intensity is held carries the held intensity to the new mode (the
--     box keeps one intensity per mode, SB47).
--   - Set Intensity, Next Intensity, Set Brightness, Adjust Brightness and
--     Apply Sync Settings's own intensity and brightness are manual: the
--     periods hold them until the source changes or sync stops, both seen
--     here in the reads (any cause).

local num = require("common.num")

local programming = {}

programming.PERSIST_KEY = "syncbox_programming"
programming.STEP = 10       -- Sync Brighter and Sync Dimmer (design 5.6)
programming.LEAVE = "Leave" -- Apply Sync Settings: a field left as it is
programming.NAME_MAX = 64   -- bytes of a name kept in a variable
programming.PARAM_MAX = 40  -- bytes of a parameter quoted in Last Action

-- C1.9, in this order for good (ids 1001 to 1009 when none existed).
programming.VARIABLES = {
	{ name = "SYNC_ACTIVE", type = "BOOL", default = "0" },
	{ name = "SYNC_MODE", type = "STRING", default = "off" },
	{ name = "INTENSITY", type = "STRING", default = "" },
	{ name = "BRIGHTNESS", type = "NUMBER", default = "100" },
	{ name = "HDMI_INPUT", type = "INT", default = "1" },
	{ name = "HDMI_INPUT_NAME", type = "STRING", default = "" },
	{ name = "ENTERTAINMENT_AREA", type = "STRING", default = "" },
	{ name = "POWER", type = "STRING", default = "powersave" },
	{ name = "ONLINE", type = "BOOL", default = "0" },
}

-- C1.7: ids fixed, never renumbered.
programming.EVENTS = {
	SYNC_STARTED = 1, SYNC_STOPPED = 2, SYNC_MODE_CHANGED = 3, INTENSITY_CHANGED = 4,
	BRIGHTNESS_CHANGED = 5, HDMI_INPUT_CHANGED = 6, ENTERTAINMENT_AREA_CHANGED = 7,
	SYNC_TAKEN_OVER = 8, POWERED_ON = 9, POWER_SAVE = 10, ONLINE = 11, OFFLINE = 12,
}
programming.EVENT_NAMES = { "Sync Started", "Sync Stopped", "Sync Mode Changed", "Intensity Changed",
	"Brightness Changed", "HDMI Input Changed", "Entertainment Area Changed", "Sync Taken Over", "Powered On",
	"Power Save", "Online", "Offline" }

-- C1.6, in its order.
programming.COMMANDS = { "Start Sync", "Stop Sync", "Toggle Sync", "Set Sync Mode", "Set Intensity",
	"Next Intensity", "Set Brightness", "Adjust Brightness", "Set Entertainment Area", "Apply Sync Settings",
	"Power Save", "Wake", "Select HDMI Input" }

-- C1.8: `name` is the <name> driver.xml gives each (TestCondition's first
-- argument), `label` the contract's; both are taken.
programming.CONDITIONALS = {
	{ name = "BOOL_SYNC_ACTIVE", label = "Sync Active", kind = "BOOL", var = "SYNC_ACTIVE" },
	{ name = "LIST_SYNC_MODE", label = "Sync Mode", kind = "LIST", var = "SYNC_MODE",
		items = { "Video", "Music", "Game", "Off" } },
	{ name = "LIST_INTENSITY", label = "Intensity", kind = "LIST", var = "INTENSITY",
		items = { "Subtle", "Moderate", "High", "Intense" } },
	{ name = "LIST_HDMI_INPUT", label = "HDMI Input", kind = "LIST", var = "HDMI_INPUT",
		items = { "HDMI 1", "HDMI 2", "HDMI 3", "HDMI 4" } },
	{ name = "NUMBER_BRIGHTNESS", label = "Brightness", kind = "NUMBER", var = "BRIGHTNESS", min = 0, max = 200 },
	{ name = "BOOL_POWERED_ON", label = "Powered On", kind = "BOOL", var = "POWER" },
	{ name = "BOOL_ONLINE", label = "Online", kind = "BOOL", var = "ONLINE" },
}

-- C1.1 and design 5.6: the UI Buttons as commands.
programming.BUTTONS = {
	["Hue Sync"] = { command = "Toggle Sync" },
	["Sync Brighter"] = { command = "Adjust Brightness", params = { Step = tostring(programming.STEP) } },
	["Sync Dimmer"] = { command = "Adjust Brightness", params = { Step = tostring(-programming.STEP) } },
	["Sync Intensity"] = { command = "Next Intensity" },
}

-- The queue's answers (syncbox/queue.lua; the same words, not required
-- here so a spec can stand in for the queue).
programming.SUPERSEDED, programming.CANCELLED = "superseded", "cancelled"
programming.BUSY, programming.NOT_LANDED = "busy", "not landed"
programming.REFUSED, programming.NOT_SENT = "refused", "not sent"

-- Last Action, per kind of write: `ok` once a read shows it, `no` and
-- `landed` (the words for "not landed") when it failed.
programming.TEXT = {
	start = { ok = "Syncing", no = "Not syncing", landed = "the box did not start syncing" },
	stop = { ok = "Sync stopped", no = "Not stopped", landed = "the box did not stop syncing" },
	mode = { ok = "Syncing %s", no = "Sync mode not changed", landed = "the box did not change the sync mode" },
	intensity = { ok = "Intensity %s", no = "Intensity not changed", landed = "the box did not change the intensity" },
	brightness = { ok = "Brightness %d %%", no = "Brightness not changed",
		landed = "the box did not change the brightness" },
	area = { ok = "Entertainment area %s", no = "Entertainment area not changed",
		landed = "the box did not change the entertainment area" },
	apply = { ok = "Sync settings applied: %s", no = "Sync settings not applied",
		landed = "the box did not show them" },
	power_save = { ok = "Power save", no = "Not turned off", landed = "the box did not go to power save" },
	wake = { ok = "Awake", no = "Not turned on", landed = "the box did not wake from power save" },
	input = { ok = "HDMI %d%s selected: the Control4 room does not follow it", no = "Not switched",
		landed = "the box did not change input" },
	BUSY = "another app streams to the Hue Bridge's entertainment area, so the box is busy",
	REFUSED = "the box refused it (%s)",
	NOT_PAIRED = "the box is not paired; run Pair Sync Box",
	NOT_READY = "the driver is still starting",
	NO_INPUT = "Not switched: this box has %d HDMI input%s",
	PARAM = "%s not done: %s must be %s, not %s",
	NOTHING = "Apply Sync Settings not done: every field is Leave",
	NO_AREA = "%s not done: the box has no entertainment area named %s",
	TWO_AREAS = "%s not done: %d entertainment areas are named %s; rename one in the Hue app",
	NO_AREAS = "%s not done: the box lists no entertainment areas yet",
	MODE_IGNORED = "the mode is left (Stop leaves the box not syncing)",
}

local SYNC = { video = true, music = true, game = true }
local INTENSITIES = { "subtle", "moderate", "high", "intense" }
local RANK = { subtle = 1, moderate = 2, high = 3, intense = 4 }
local MODE_WORDS = { video = "video", music = "music", game = "game" }
local POWER = { on = true, powersave = true }

-- Text helpers ---------------------------------------------------------------------------

-- "Set Sync Mode", "SET_SYNC_MODE", "set sync mode" -> "set sync mode".
local function key(name)
	if type(name) ~= "string" then
		return ""
	end
	return (name:gsub("[%s_]+", " "):gsub("^ ", ""):gsub(" $", ""):lower())
end

-- A parameter as Last Action quotes it: printable, capped.
local function shown(v)
	local s = tostring(v):gsub("[^ -~]", "?")
	if #s > programming.PARAM_MAX then
		s = s:sub(1, programming.PARAM_MAX) .. "..."
	end
	return s
end

-- A parameter that leaves its field as it is: absent, empty or "Leave".
local function leave(v)
	if v == nil then
		return true
	end
	if type(v) ~= "string" then
		return false
	end
	return v:match("^%s*$") ~= nil or key(v) == "leave"
end

-- A name for a variable: text, printable, capped.
local function name_text(v)
	if type(v) ~= "string" then
		return ""
	end
	local s = v:gsub("[%c]", "")
	return s:sub(1, programming.NAME_MAX)
end

-- What a stored variable may hold (#486: persisted values are checked).
local VALID = {
	SYNC_ACTIVE = function(v) return v == "0" or v == "1" end,
	SYNC_MODE = function(v) return v == "off" or SYNC[v] == true end,
	INTENSITY = function(v) return v == "" or RANK[v] ~= nil end,
	BRIGHTNESS = function(v) local n = num.int(v, 0, 200); return n ~= nil and tostring(n) == v end,
	HDMI_INPUT = function(v) local n = num.int(v, 1, 4); return n ~= nil and tostring(n) == v end,
	HDMI_INPUT_NAME = function(v) return #v <= programming.NAME_MAX end,
	ENTERTAINMENT_AREA = function(v) return #v <= programming.NAME_MAX end,
	POWER = function(v) return POWER[v] == true end,
	ONLINE = function(v) return v == "0" or v == "1" end,
}

-- The object ------------------------------------------------------------------------------

local P = {}
P.__index = P

local function resolve(v)
	if type(v) == "function" then
		local ok, out = pcall(v)
		return ok and out or nil
	end
	return v
end

function programming.new(deps)
	deps = deps or {}
	local p = setmetatable({}, P)
	p.deps = deps
	p.log = deps.log or require("common.log")
	p.set_variable = deps.set_variable or function(name, value) C4:SetVariable(name, value) end
	p.fire_event = deps.fire_event or function(id) C4:FireEventByID(id) end
	p.add_variable = deps.add_variable or function(name, value, var_type, read_only, hidden)
		return C4:AddVariable(name, value, var_type, read_only, hidden)
	end
	p.persist_get = deps.persist_get or function(k) return C4:PersistGetValue(k) end
	p.persist_set = deps.persist_set or function(k, v) C4:PersistSetValue(k, v) end
	p.vars = {}       -- name -> the text the variable holds
	p.known = {}      -- name -> true once a read (or the store) gave it
	p.area = nil      -- the area id ENTERTAINMENT_AREA names ("" none), nil never known
	for _, v in ipairs(programming.VARIABLES) do
		p.vars[v.name] = v.default
	end
	return p
end

function P:_queue()
	local q = resolve(self.deps.queue)
	return type(q) == "table" and type(q.set) == "function" and q or nil
end

function P:_periods()
	local p = resolve(self.deps.periods)
	return type(p) == "table" and p or nil
end

function P:_model()
	local f = self.deps.model_now
	if type(f) == "function" then
		local ok, m = pcall(f)
		if ok and type(m) == "table" then
			return m
		end
	end
	return nil
end

function P:_say(text)
	self.log.info("programming: %s", text)
	local f = self.deps.last_action
	if type(f) == "function" then
		local ok, err = pcall(f, text)
		if not ok then
			self.log.warn("programming: Last Action failed: %s", tostring(err))
		end
	end
end

-- Variables -------------------------------------------------------------------------------

function P:init()
	local stored = self.persist_get(programming.PERSIST_KEY)
	local values = type(stored) == "table" and type(stored.v) == "table" and stored.v or {}
	for _, v in ipairs(programming.VARIABLES) do
		local s = values[v.name]
		if type(s) == "string" and VALID[v.name](s) then
			self.vars[v.name], self.known[v.name] = s, true
		end
	end
	if type(stored) == "table" and type(stored.area) == "string" and #stored.area <= 64 then
		self.area = stored.area
	end
	local out = {}
	for _, v in ipairs(programming.VARIABLES) do
		local ok, a, b = pcall(self.add_variable, v.name, self.vars[v.name], v.type, true, false)
		if not ok then
			self.log.error("programming: AddVariable %s failed: %s", v.name, tostring(a))
		else
			self.log.debug("programming: variable %s %s (%s)", v.name,
				a and ("added (" .. tostring(b or a) .. ")") or "already there", self.vars[v.name])
		end
		out[#out + 1] = v.name
	end
	return out
end

function P:value(name)
	return self.vars[name]
end

function P:values()
	local out = {}
	for k, v in pairs(self.vars) do
		out[k] = v
	end
	return out
end

function P:_save()
	local v = {}
	for name in pairs(self.known) do
		v[name] = self.vars[name]
	end
	local ok, err = pcall(self.persist_set, programming.PERSIST_KEY, { v = v, area = self.area })
	if not ok then
		self.log.warn("programming: the variables could not be stored: %s", tostring(err))
	end
end

-- The variables' texts a model gives; nil keeps a variable as it is (a
-- field the read lacks, or a value the box sent that none of ours names).
local function values_of(model)
	local out = {}
	if model.syncing ~= nil then
		out.SYNC_ACTIVE = model.syncing and "1" or "0"
	end
	if SYNC[model.mode] then
		out.SYNC_MODE = model.mode
	elseif model.mode == "passthrough" or model.mode == "powersave" or model.syncing == false then
		out.SYNC_MODE = "off"
	end
	if RANK[model.intensity] then
		out.INTENSITY = model.intensity
	end
	local b = num.int(model.brightness, 0, 200)
	if b then
		out.BRIGHTNESS = tostring(b)
	end
	local n = num.int(model.input, 1, 4)
	if n then
		out.HDMI_INPUT = tostring(n)
		if type(model.inputs) == "table" then
			local name = ""
			for _, i in ipairs(model.inputs) do
				if i.n == n then
					name = name_text(i.name)
				end
			end
			out.HDMI_INPUT_NAME = name
		end
	end
	if model.area ~= nil or model.areas ~= nil then
		out.ENTERTAINMENT_AREA = model.area and name_text(model.area_name) or ""
	end
	if model.power == "powersave" or model.mode == "powersave" then
		out.POWER = "powersave"
	elseif model.power == "on" then
		out.POWER = "on"
	end
	out.ONLINE = "1"
	return out
end

-- Set the variables whose text `new` changes, in C1.9's order. Returns the
-- changes by name, { from, to, known (the old value was known) }, plus a
-- `same` entry for a value known for the first time without changing, and
-- the names set, in order.
function P:_set(new)
	local changes, names = {}, {}
	for _, v in ipairs(programming.VARIABLES) do
		local to, from = new[v.name], self.vars[v.name]
		if to ~= nil then
			local was_known = self.known[v.name] == true
			if to ~= from then
				self.vars[v.name] = to
				local ok, err = pcall(self.set_variable, v.name, to)
				if not ok then
					self.log.warn("programming: SetVariable %s failed: %s", v.name, tostring(err))
				end
				changes[v.name] = { from = from, to = to, known = was_known }
				names[#names + 1] = v.name
			elseif not was_known then
				changes[v.name] = { from = from, to = to, known = false, same = true }
			end
			self.known[v.name] = true
		end
	end
	return changes, names
end

-- Events ------------------------------------------------------------------------------------

local E = programming.EVENTS

-- The events of a set of changes, in the order they fire.
local function events_of(changes, area_changed, takeover, syncing)
	local list = {}
	local function was(name)
		local c = changes[name]
		return c and c.known and not c.same and c or nil
	end
	local online, power, sync = was("ONLINE"), was("POWER"), was("SYNC_ACTIVE")
	if online and online.to == "1" then
		list[#list + 1] = E.ONLINE
	end
	if power and power.to == "on" then
		list[#list + 1] = E.POWERED_ON
	end
	if sync then
		list[#list + 1] = sync.to == "1" and E.SYNC_STARTED or E.SYNC_STOPPED
	end
	if was("SYNC_MODE") then
		list[#list + 1] = E.SYNC_MODE_CHANGED
	end
	if was("INTENSITY") then
		list[#list + 1] = E.INTENSITY_CHANGED
	end
	if was("BRIGHTNESS") then
		list[#list + 1] = E.BRIGHTNESS_CHANGED
	end
	if was("HDMI_INPUT") then
		list[#list + 1] = E.HDMI_INPUT_CHANGED
	end
	if area_changed then
		list[#list + 1] = E.ENTERTAINMENT_AREA_CHANGED
	end
	if takeover and syncing then
		list[#list + 1] = E.SYNC_TAKEN_OVER
	end
	if power and power.to == "powersave" then
		list[#list + 1] = E.POWER_SAVE
	end
	if online and online.to == "0" then
		list[#list + 1] = E.OFFLINE
	end
	return list
end

function P:_fire(list, cause)
	for _, id in ipairs(list) do
		self.log.info("programming: event %d %s (%s)", id, programming.EVENT_NAMES[id], tostring(cause or "read"))
		local ok, err = pcall(self.fire_event, id)
		if not ok then
			self.log.warn("programming: FireEventByID %d failed: %s", id, tostring(err))
		end
	end
end

function P:_release(reason)
	local periods = self:_periods()
	if periods and type(periods.release) == "function" then
		local ok, err = pcall(periods.release, periods, reason)
		if not ok then
			self.log.warn("programming: the periods' release failed: %s", tostring(err))
		end
	end
end

function P:_changed(names)
	local f = self.deps.changed
	if #names > 0 and type(f) == "function" then
		local ok, err = pcall(f, names, self:values())
		if not ok then
			self.log.warn("programming: the change callback failed: %s", tostring(err))
		end
	end
end

-- After the variables of one observe or online call: the store, the holds
-- released, the events, the callback.
function P:_after(changes, names, area_changed, cause)
	local stored = #names > 0 or area_changed
	for _, c in pairs(changes) do
		if not c.known then
			stored = true -- a value known for the first time
		end
	end
	if stored then
		self:_save()
	end
	local sync, input = changes.SYNC_ACTIVE, changes.HDMI_INPUT
	if sync and sync.known and not sync.same and sync.to == "0" then
		self:_release("stop")
	elseif input and input.known and not input.same then
		self:_release("source")
	end
	self:_fire(events_of(changes, area_changed, cause == "takeover", self.vars.SYNC_ACTIVE == "1"), cause)
	self:_changed(names)
end

function P:observe(model, _prev, cause)
	if type(model) ~= "table" then
		return false
	end
	local changes, names = self:_set(values_of(model))
	local area_changed = false
	-- The area id: "" for none when the read lists areas, nil (unknown) when
	-- it has no hue object at all.
	local area = model.area or (model.areas ~= nil and "" or nil)
	if area ~= nil and area ~= self.area then
		area_changed = self.area ~= nil
		self.area = area
		if not area_changed then
			changes.AREA_ID = { known = false } -- first known: stored, no event
		end
	end
	self:_after(changes, names, area_changed, cause)
	return true
end

function P:online(flag, cause)
	local changes, names = self:_set({ ONLINE = flag and "1" or "0" })
	self:_after(changes, names, false, cause or (flag and "online" or "offline"))
end

-- Conditionals ---------------------------------------------------------------------------

local COMPARE = {
	EQUAL = function(a, b) return a == b end,
	NOT_EQUAL = function(a, b) return a ~= b end,
	LESS_THAN = function(a, b) return a < b end,
	LESS_THAN_OR_EQUAL = function(a, b) return a <= b end,
	GREATER_THAN = function(a, b) return a > b end,
	GREATER_THAN_OR_EQUAL = function(a, b) return a >= b end,
}

local CONDITIONAL_BY = {}
for _, c in ipairs(programming.CONDITIONALS) do
	CONDITIONAL_BY[key(c.name)] = c
	CONDITIONAL_BY[key(c.label)] = c
end

local TRUE_WORDS = { ["true"] = true, ["1"] = true, yes = true, on = true, active = true, online = true,
	["powered on"] = true }
local FALSE_WORDS = { ["false"] = true, ["0"] = true, no = true, off = true, inactive = true, offline = true,
	["power save"] = true, powersave = true, ["powered off"] = true }

-- A LIST's item and the value now, as two comparable values (nil when the
-- item is not one of the list's or the value is not known).
local function list_pair(c, item, value)
	if c.var == "SYNC_MODE" then
		return MODE_WORDS[item] or (item == "off" and "off") or nil, value ~= "" and value or nil
	elseif c.var == "INTENSITY" then
		return RANK[item], RANK[value]
	end
	return num.int(item:match("(%d+)%s*$"), 1, 4), num.int(value, 1, 4)
end

function P:test(name, params)
	local c = CONDITIONAL_BY[key(name)]
	if not c then
		self.log.debug("programming: TestCondition %s: not one of this driver's", tostring(name))
		return false
	end
	params = type(params) == "table" and params or {}
	local logic = type(params.LOGIC) == "string" and params.LOGIC:upper() or "EQUAL"
	local value = self.vars[c.var]
	local result = false
	if c.kind == "BOOL" then
		local now
		if c.var == "POWER" then
			now = value == "on"
		else
			now = value == "1"
		end
		local word = params.VALUE ~= nil and key(tostring(params.VALUE)) or "true"
		local want
		if TRUE_WORDS[word] then
			want = true
		elseif FALSE_WORDS[word] then
			want = false
		end
		if want ~= nil then
			result = (now == want)
			if logic == "NOT_EQUAL" then
				result = not result
			end
		end
	elseif c.kind == "NUMBER" then
		local compare, target, current = COMPARE[logic], num.finite(params.VALUE), num.finite(value)
		result = compare ~= nil and target ~= nil and current ~= nil and compare(current, target) or false
	else
		local item = key(tostring(params.VALUE or ""))
		local want, current = list_pair(c, item, value)
		local compare = COMPARE[logic]
		if logic ~= "EQUAL" and logic ~= "NOT_EQUAL" and c.var == "SYNC_MODE" then
			compare = nil -- the modes have no order
		end
		if compare and want ~= nil then
			if current == nil then
				result = logic == "NOT_EQUAL"
			else
				result = compare(current, want)
			end
		end
	end
	self.log.debug("programming: TestCondition %s %s %s: %s", c.name, logic, tostring(params.VALUE), tostring(result))
	return result == true
end

-- Commands: what the box will be ------------------------------------------------------------

-- The box as it will be once the pending writes land (SB55's order over
-- the last read): what a toggle, a cycle or a step starts from.
local function effective(model, target)
	local m = model or {}
	local e = { syncing = m.syncing, mode = m.mode, power = m.power, intensity = m.intensity,
		brightness = m.brightness, input = m.input, last_sync_mode = m.last_sync_mode }
	if m.mode == "powersave" then
		e.power = "powersave"
	end
	local t = target or {}
	if t.hdmiActive == true and e.power == "powersave" then
		e.power, e.mode, e.syncing = "on", "passthrough", false
	elseif t.hdmiActive == false then
		e.power, e.mode, e.syncing = "powersave", "powersave", false
	end
	if t.hdmiSource ~= nil then
		e.input = num.int(tostring(t.hdmiSource):match("%d"), 1, 4) or e.input
	end
	if SYNC[t.mode] then
		e.mode, e.syncing, e.power = t.mode, true, "on"
	elseif t.mode == "passthrough" then
		e.mode, e.syncing, e.power = "passthrough", false, "on"
	elseif t.mode == "powersave" then
		e.mode, e.syncing, e.power = "powersave", false, "powersave"
	end
	if t.syncActive == true then
		e.syncing, e.power = true, "on"
	elseif t.syncActive == false then
		if e.syncing then
			e.mode = "passthrough"
		end
		e.syncing = false
	end
	e.intensity = t.intensity or e.intensity
	e.brightness = t.brightness or e.brightness
	return e
end

function P:_effective()
	local target
	local q = self:_queue()
	if q and type(q.target) == "function" then
		local ok, t = pcall(q.target, q)
		target = ok and type(t) == "table" and t or nil
	end
	return effective(self:_model(), target), self:_model()
end

function P:_held(field)
	local periods = self:_periods()
	if periods and type(periods.held) == "function" then
		local ok, held = pcall(periods.held, periods, field)
		return ok and held == true
	end
	return false
end

-- The period's intensity and brightness for a sync in `mode`, each nil
-- when held or not known.
function P:_period_settings(mode)
	local ok, s
	if type(self.deps.period) == "function" then
		ok, s = pcall(self.deps.period, mode)
	else
		local periods = self:_periods()
		if periods and type(periods.settings_for) == "function" then
			local current
			if type(periods.current) == "function" then
				local fine, cur = pcall(periods.current, periods)
				current = fine and cur or nil
			end
			ok, s = pcall(periods.settings_for, periods, current, mode)
		end
	end
	if not ok or type(s) ~= "table" then
		if ok == false then
			self.log.warn("programming: the period's settings could not be read: %s", tostring(s))
		end
		return nil, nil
	end
	local intensity = type(s.intensity) == "string" and s.intensity:lower() or nil
	intensity = RANK[intensity] and intensity or nil
	local brightness = num.int(s.brightness, 0, 200)
	if self:_held("intensity") then
		intensity = nil
	end
	if self:_held("brightness") then
		brightness = nil
	end
	return intensity, brightness
end

-- A write that starts a sync or changes its mode carries the period's
-- settings (design 5.3), or a held intensity over to the new mode.
function P:_fill(fields, e)
	local starting = e.syncing ~= true
	if not starting and not SYNC[fields.mode] then
		return
	end
	local mode = SYNC[fields.mode] and fields.mode or (SYNC[e.mode] and e.mode) or e.last_sync_mode or "video"
	local intensity, brightness = self:_period_settings(mode)
	if fields.intensity == nil then
		if self:_held("intensity") then
			if SYNC[fields.mode] and fields.mode ~= e.mode and RANK[e.intensity] then
				fields.intensity = e.intensity
			end
		else
			fields.intensity = intensity
		end
	end
	if starting and fields.brightness == nil then
		fields.brightness = brightness
	end
end

-- Commands: the writes ---------------------------------------------------------------------

local function starts_sync(fields)
	return fields.syncActive == true or SYNC[fields.mode] == true
end

function P:_failed(kind, why, detail, fields, tag)
	if why == nil or why == programming.SUPERSEDED or why == programming.CANCELLED then
		self.log.debug("programming: a %s write ended: %s", kind, tostring(why))
		return
	end
	if why == programming.BUSY and starts_sync(fields) and type(self.deps.on_busy) == "function" then
		local ok, handled = pcall(self.deps.on_busy, fields, tag)
		if ok and handled then
			self.log.info("programming: the box is busy; the take-over handles the %s", kind)
			return
		elseif not ok then
			self.log.warn("programming: the take-over failed: %s", tostring(handled))
		end
	end
	local t = programming.TEXT[kind]
	local words
	if why == programming.NOT_LANDED then
		words = t.landed
	elseif why == programming.BUSY then
		words = programming.TEXT.BUSY
	elseif why == programming.REFUSED then
		words = string.format(programming.TEXT.REFUSED, tostring(detail or "no reason given"))
	elseif why == programming.NOT_SENT then
		words = (detail == "not paired" or detail == "no box address") and programming.TEXT.NOT_PAIRED
			or tostring(detail)
	else
		words = tostring(why)
	end
	self:_say(t.no .. ": " .. words)
end

-- One q:set for a command: `holds` the fields the periods now hold, `ok`
-- Last Action's text once a read shows the write.
function P:_write(kind, command, fields, ok_text, holds)
	local q = self:_queue()
	if not q then
		self:_say(programming.TEXT[kind].no .. ": " .. programming.TEXT.NOT_READY)
		return false, "not ready"
	end
	local tag = { kind = "programming", command = command, write = kind }
	local fine, set_ok, why = pcall(q.set, q, fields, tag, function(_, ok, _, why2, detail)
		if ok then
			self:_say(ok_text)
		else
			self:_failed(kind, why2, detail, fields, tag)
		end
	end)
	if not fine or not set_ok then
		local reason
		if fine then
			reason = why or "the queue refused it"
		else
			reason = "the queue failed: " .. tostring(set_ok)
		end
		self:_say(programming.TEXT[kind].no .. ": " .. tostring(reason))
		return false, reason
	end
	for _, field in ipairs(holds or {}) do
		self:manual(field)
	end
	return true
end

function P:manual(field)
	if field ~= "intensity" and field ~= "brightness" then
		return false
	end
	local periods = self:_periods()
	if not periods or type(periods.hold) ~= "function" then
		return false
	end
	local ok, err = pcall(periods.hold, periods, field)
	if not ok then
		self.log.warn("programming: the periods' hold failed: %s", tostring(err))
		return false
	end
	self.log.debug("programming: %s held until the source changes or sync stops", field)
	return true
end

-- Parameters ----------------------------------------------------------------------------

local function bad(command, what, range, value)
	return string.format(programming.TEXT.PARAM, command, what, range, shown(value))
end

local function mode_param(v)
	return MODE_WORDS[key(tostring(v))]
end

local function intensity_param(v)
	local k = key(tostring(v))
	return RANK[k] and k or nil
end

-- A brightness or a step: a whole number in lo..hi ("70", "70 %").
local function number_param(v, lo, hi)
	if type(v) == "string" then
		v = v:gsub("%s*%%%s*$", "")
	end
	local n = num.finite(v)
	if n == nil or n ~= math.floor(n) then
		return nil
	end
	return num.int(n, lo, hi)
end

local function input_param(v)
	return num.int(tostring(v):match("(%d+)%s*$"), 1, 4)
end

-- The model's inputs: a count and a set, or nil when no read said.
local function inputs_of(model)
	if type(model) ~= "table" then
		return nil
	end
	if type(model.inputs) == "table" and #model.inputs > 0 then
		local has = {}
		for _, i in ipairs(model.inputs) do
			has[i.n] = true
		end
		return #model.inputs, has
	end
	if model.model == "HSB3" then
		return 1, { true }
	end
	return nil
end

-- The Area list: the areas module's, else the model's names (each once).
function P:_area_names()
	local a = resolve(self.deps.areas)
	if type(a) == "table" and type(a.names) == "function" then
		local ok, list = pcall(a.names, a)
		if ok and type(list) == "table" then
			return list
		end
	end
	local out, seen = {}, {}
	local m = self:_model()
	for _, area in ipairs(m and type(m.areas) == "table" and m.areas or {}) do
		if area.name and not seen[area.name] then
			seen[area.name] = true
			out[#out + 1] = area.name
		end
	end
	return out
end

-- An Area parameter -> id, name; or nil and Last Action's text. A name
-- (C1.6's DYNAMIC_LIST) or an id is looked up in the box's list first;
-- then the areas module's resolve takes it (syncbox/areas.lua: "area:<id>"
-- from its CUSTOM_SELECT list, or an id, a re-pointed one followed), and
-- its text says why not.
function P:_area(command, value)
	local text = tostring(value)
	local m = self:_model()
	local list = m and type(m.areas) == "table" and m.areas or {}
	local found = {}
	for _, area in ipairs(list) do
		if area.id == text or area.name == text then
			found[#found + 1] = area
		end
	end
	if #found == 0 then
		for _, area in ipairs(list) do
			if area.name and area.name:lower() == text:lower() then
				found[#found + 1] = area
			end
		end
	end
	if #found == 1 then
		return found[1].id, found[1].name or found[1].id
	elseif #found > 1 then
		return nil, string.format(programming.TEXT.TWO_AREAS, command, #found, shown(value))
	end
	local a = resolve(self.deps.areas)
	if type(a) == "table" and type(a.resolve) == "function" then
		local ok, id, name = pcall(a.resolve, a, text)
		if ok and type(id) == "string" then
			return id, name or id
		elseif ok and type(name) == "string" and text:find(":", 1, true) then
			return nil, name -- "area:<id>": the module's own words
		elseif not ok then
			self.log.warn("programming: the areas module failed: %s", tostring(id))
		end
	end
	if #list == 0 then
		return nil, string.format(programming.TEXT.NO_AREAS, command)
	end
	return nil, string.format(programming.TEXT.NO_AREA, command, shown(value))
end

-- The commands ---------------------------------------------------------------------------

local C = {}

function C.start_sync(self, command)
	local e = self:_effective()
	local fields = { syncActive = true }
	self:_fill(fields, e)
	return self:_write("start", command, fields, programming.TEXT.start.ok)
end

function C.stop_sync(self, command)
	-- A sync stopped by command ends the manual holds at once, not at the next
	-- read, so a Start Sync right after takes the period's values (#568).
	self:_release("stop")
	return self:_write("stop", command, { syncActive = false }, programming.TEXT.stop.ok)
end

function C.toggle_sync(self, command)
	local e = self:_effective()
	if e.syncing then
		return C.stop_sync(self, command)
	end
	return C.start_sync(self, command)
end

function C.set_sync_mode(self, command, params)
	local mode = mode_param(params.Mode)
	if not mode then
		self:_say(bad(command, "Mode", "Video, Music or Game", params.Mode))
		return false, "bad mode"
	end
	local fields = { mode = mode }
	self:_fill(fields, (self:_effective()))
	return self:_write("mode", command, fields, string.format(programming.TEXT.mode.ok, mode))
end

function C.set_intensity(self, command, params)
	local intensity = intensity_param(params.Intensity)
	if not intensity then
		self:_say(bad(command, "Intensity", "Subtle, Moderate, High or Intense", params.Intensity))
		return false, "bad intensity"
	end
	return self:_write("intensity", command, { intensity = intensity },
		string.format(programming.TEXT.intensity.ok, intensity), { "intensity" })
end

function C.next_intensity(self, command)
	local e = self:_effective()
	local intensity = INTENSITIES[(RANK[e.intensity] or 0) % #INTENSITIES + 1]
	return self:_write("intensity", command, { intensity = intensity },
		string.format(programming.TEXT.intensity.ok, intensity), { "intensity" })
end

function C.set_brightness(self, command, params)
	local n = number_param(params.Brightness, 0, 200)
	if not n then
		self:_say(bad(command, "Brightness", "0 to 200 %", params.Brightness))
		return false, "bad brightness"
	end
	return self:_write("brightness", command, { brightness = n },
		string.format(programming.TEXT.brightness.ok, n), { "brightness" })
end

function C.adjust_brightness(self, command, params)
	local step = number_param(params.Step, -200, 200)
	if not step then
		self:_say(bad(command, "Step", "-200 to 200", params.Step))
		return false, "bad step"
	end
	local e = self:_effective()
	local base = num.int(e.brightness, 0, 200) or 100
	local n = math.max(0, math.min(200, base + step))
	return self:_write("brightness", command, { brightness = n },
		string.format(programming.TEXT.brightness.ok, n), { "brightness" })
end

function C.set_entertainment_area(self, command, params)
	if leave(params.Area) then
		self:_say(bad(command, "Area", "one of the box's entertainment areas", params.Area or ""))
		return false, "no area"
	end
	local id, name = self:_area(command, params.Area)
	if not id then
		self:_say(name)
		return false, "unknown area"
	end
	return self:_write("area", command, { hueTarget = id }, string.format(programming.TEXT.area.ok, name))
end

function C.power_save(self, command)
	self:_release("stop")
	return self:_write("power_save", command, { mode = "powersave" }, programming.TEXT.power_save.ok)
end

function C.wake(self, command)
	return self:_write("wake", command, { hdmiActive = true }, programming.TEXT.wake.ok)
end

function C.select_hdmi_input(self, command, params)
	local n = input_param(params.Input)
	if not n then
		self:_say(bad(command, "Input", "HDMI 1 to HDMI 4", params.Input))
		return false, "bad input"
	end
	local model = self:_model()
	local count, has = inputs_of(model)
	if count and not has[n] then
		self:_say(string.format(programming.TEXT.NO_INPUT, count, count == 1 and "" or "s"))
		return false, "no such input"
	end
	local label = ""
	for _, i in ipairs(model and type(model.inputs) == "table" and model.inputs or {}) do
		if i.n == n and i.name then
			label = " (" .. name_text(i.name) .. ")"
		end
	end
	return self:_write("input", command, { hdmiSource = "input" .. n },
		string.format(programming.TEXT.input.ok, n, label))
end

-- Apply Sync Settings: the given fields as one write (C1.6).
local function apply_fields(self, command, params)
	local fields, holds, parts = {}, {}, {}
	if not leave(params.Mode) then
		fields.mode = mode_param(params.Mode)
		if not fields.mode then
			return nil, bad(command, "Mode", "Leave, Video, Music or Game", params.Mode)
		end
	end
	if not leave(params.Intensity) then
		fields.intensity = intensity_param(params.Intensity)
		if not fields.intensity then
			return nil, bad(command, "Intensity", "Leave, Subtle, Moderate, High or Intense", params.Intensity)
		end
		holds[#holds + 1] = "intensity"
	end
	-- Brightness: Leave, or a negative number (a RANGED_INTEGER from -1
	-- has no word for Leave), or 0 to 200.
	local b = params.Brightness
	local n = number_param(b, -200, 200)
	if not leave(b) and not (n and n < 0) then
		if not n or n > 200 then
			return nil, bad(command, "Brightness", "Leave or 0 to 200 %", b)
		end
		fields.brightness = n
		holds[#holds + 1] = "brightness"
	end
	local area_name
	if not leave(params.Area) then
		local id, name = self:_area(command, params.Area)
		if not id then
			return nil, name
		end
		fields.hueTarget, area_name = id, name
	end
	local start = key(tostring(params.Start or ""))
	if start == "start" then
		fields.syncActive = fields.mode == nil and true or nil
	elseif start == "stop" then
		if fields.mode then
			parts[#parts + 1] = programming.TEXT.MODE_IGNORED
			fields.mode = nil
		end
		fields.syncActive = false
	elseif not leave(params.Start) then
		return nil, bad(command, "Start", "Leave, Start or Stop", params.Start)
	end
	return fields, holds, parts, area_name
end

function C.apply_sync_settings(self, command, params)
	local fields, holds, notes, area_name = apply_fields(self, command, params)
	if not fields then
		self:_say(holds)
		return false, "bad parameter"
	end
	if next(fields) == nil then
		self:_say(programming.TEXT.NOTHING)
		return false, "nothing to apply"
	end
	if starts_sync(fields) then
		self:_fill(fields, (self:_effective()))
	end
	local parts = {}
	if fields.syncActive == false then
		parts[#parts + 1] = "sync stopped"
	elseif fields.mode then
		parts[#parts + 1] = fields.mode
	elseif fields.syncActive then
		parts[#parts + 1] = "syncing"
	end
	if fields.intensity then
		parts[#parts + 1] = fields.intensity
	end
	if fields.brightness then
		parts[#parts + 1] = "brightness " .. fields.brightness .. " %"
	end
	if area_name then
		parts[#parts + 1] = "on " .. area_name
	end
	for _, n in ipairs(notes) do
		parts[#parts + 1] = n
	end
	return self:_write("apply", command, fields,
		string.format(programming.TEXT.apply.ok, table.concat(parts, ", ")), holds)
end

-- The handler of each command by its key.
local HANDLERS = {}
for _, name in ipairs(programming.COMMANDS) do
	HANDLERS[key(name)] = C[key(name):gsub(" ", "_")]
end

function P:command(name, params)
	local k = key(name)
	local handler = HANDLERS[k]
	if not handler then
		self.log.debug("programming: %s is not one of the box's commands", tostring(name))
		return false, "unknown command"
	end
	params = type(params) == "table" and params or {}
	local label = programming.COMMANDS[1]
	for _, c in ipairs(programming.COMMANDS) do
		if key(c) == k then
			label = c
		end
	end
	self.log.debug("programming: %s", label)
	local ok, done, why = pcall(handler, self, label, params)
	if not ok then
		self.log.error("programming: %s failed: %s", label, tostring(done))
		return false, "failed"
	end
	return done, why
end

function P:button(name)
	local b = programming.BUTTONS[name]
	if not b then
		return false, "unknown button"
	end
	local params = {}
	for k, v in pairs(b.params or {}) do
		params[k] = v
	end
	return self:command(b.command, params)
end

function P:icon_state(button)
	if button == "Hue Sync" then
		return self.vars.SYNC_ACTIVE == "1" and "on" or "off"
	elseif button == "Sync Intensity" then
		return RANK[self.vars.INTENSITY] and self.vars.INTENSITY or nil
	end
	return nil
end

function P:param_list(command, param)
	local c, p = key(command), key(param)
	if p ~= "area" then
		return {}
	end
	if c == "set entertainment area" then
		return self:_area_names()
	elseif c == "apply sync settings" then
		local out = { programming.LEAVE }
		for _, n in ipairs(self:_area_names()) do
			out[#out + 1] = n
		end
		return out
	end
	return {}
end

-- For the spec and the driver.
programming.key = key
programming.effective = effective

return programming
