-- Hue behaviour scripts and instances as plain records
-- (docs/hue-automation-audit-design.md §6.1): the parsing and classifying
-- half of the automation audit, as motion_model.lua is the motion
-- feature's. Pure Lua: no C4 calls, no I/O, no state. bridge/automations.lua
-- keeps the caches, works out Control4's lights and decides what to show
-- and what a click may write.
--
-- Shapes consumed (docs/hue-automations-research.md, HAR below; contract
-- findings F1 to F11, H3, H4):
--   behavior_script   { id, metadata{name, category}, description, version,
--                       max_number_instances?, *_schema (file names only) }          HAR §1.2
--   behavior_instance { id, script_id, metadata{name}, enabled, status, last_error,
--                       state?{pm_state | timer_state | ...}, configuration (per script,
--                       no public schema), dependees[{type, level, target{rid, rtype}}],
--                       migrated_from? }                                              HAR §1.3
-- Nothing here knows a script's schema: references are every {rid, rtype}
-- object anywhere in `configuration` plus every dependee's target (D4), and
-- actions are every value under a key named `action` (D5).
--
-- Interface (functions of the module table; nothing keeps state):
--   script(item)        { rid, name, category ("automation" | "accessory" | "entertainment"
--                       | "other" | ""), version, max_instances }; nil without a resource id.
--                       A category the bridge leaves out (older firmware) reads ""; any other
--                       value than the four reads "other" (as aiohue does).
--   instance(item)      { rid, script_rid, name, enabled, status, last_error, pm_state,
--                       timer_state, migrated, refs, actions, sig, configuration, dependees,
--                       raw_name };
--                       nil without a resource id. refs = { {rid, rtype, where =
--                       "configuration" | "dependee", level (dependees only)}, ... }, each
--                       (rid, rtype, where) once, in a stable order; actions = the distinct
--                       action words in order of appearance: a string value as it is, a
--                       table holding `recall` as "recall", another table as its first key.
--                       configuration, dependees and raw_name (metadata.name as sent) are
--                       kept so a later update can work refs and the signature out again.
--   update(inst, item)  fold a stream update (only the changed fields) into inst; returns
--                       changed, fields: changed is true when refs, actions, enabled,
--                       pm_state or the script changed (what decides a conflict); fields
--                       names every field that changed ({ enabled = true, name = true,
--                       sig = true, ... }). A `configuration` or `dependees` in an update
--                       replaces the whole block [assumed: the stream sends blocks whole,
--                       as for every other resource; the next full read corrects it].
--   inert(inst)         D5: at least one action and every one "do_nothing"
--   fires(inst, script) D7: "own" | "person" | "safety" | "none" (script may be nil: not read)
--   remedy(inst, script) D6: "disable" | "steps" (before the refusal marks of D12)
--   kind(inst, script)  the word for texts (§6.1); shape first, then the script's name,
--                       then the public script ids, then the script's name as it is,
--                       else "automation"
--   signature(item)     a stable short string of `configuration` and `metadata.name`
--                       (sorted keys; two independent 32-bit hashes and the length)
--   trigger_rtypes, target_rtypes, ignored_rtypes   the sets of D4 (rtype → true);
--                       "device" is a target only when it owns a light service, which the
--                       caller's expand decides
--   SCRIPT_IDS          the public script ids of HAR §2, by key
--   is_ref(value)       rid, rtype of a well-formed {rid, rtype} object, else nil
--
-- Robustness: every field is type-checked; a malformed reference or
-- dependee is skipped; walks stop at MAX_DEPTH levels and MAX_NODES tables,
-- so a hostile or broken body cannot make them run away.

local hue_model = require("bridge.hue_model")
local util = require("bridge.util")

local model = {}

local resource_id = hue_model.resource_id

local MAX_DEPTH = 24
local MAX_NODES = 20000

-- D4. Triggers are never targets; `device` is a target only through its
-- light services (the caller's expand); entertainment_configuration and
-- recipe are neither.
model.trigger_rtypes = {
	button = true, relative_rotary = true, motion = true, convenience_area_motion = true,
	security_area_motion = true, motion_area_configuration = true, contact = true, camera_motion = true,
	light_level = true, geofence_client = true, behavior_instance = true,
}
model.target_rtypes = {
	light = true, device = true, room = true, zone = true, grouped_light = true, scene = true,
	smart_scene = true, bridge_home = true,
}
model.ignored_rtypes = { entertainment_configuration = true, recipe = true }

-- HAR §2: the same id names the same script on every bridge. A hint, never
-- the only key (H21).
model.SCRIPT_IDS = {
	wake_up = "ff8957e3-2eb9-4699-a0c8-ad2cb3ede704",
	go_to_sleep = "7e571ac6-f363-42e1-809a-4cbf6523ed72",
	schedule = "7238c707-8693-4f19-9095-ccdc1444d228",
	timers = "e73bc72d-96b1-46f8-aa57-729861f80c78",
	coming_home = "fd60fcd1-4809-4813-b510-4a18856a595c",
	leaving_home = "0194752a-2d53-4f92-8209-dfdc52745af3",
	mimic = "db06cabc-c752-4904-9e8f-4ebe98feaa1a",
	natural_light = "a4260b49-0c69-4926-a29c-417f4a38a352",
	streaming = "7719b841-6b3d-448d-a0e7-601ae9edb6a2",
	tap_switch = "f306f634-acdb-4dd6-bdf5-48dd626d667e",
	hue_accessories = "67d9395b-4403-42cc-b5f0-740b699d67c6",
}

local IDS = model.SCRIPT_IDS

-- Script id → kind word. Hue Accessories (67d9…) runs dimmer switches and,
-- on the house, a MotionAware area (H2), so it names no kind: shape decides.
-- Light state after streaming has no kind word either (its script's name).
local ID_KINDS = {
	[IDS.wake_up] = "wake up",
	[IDS.go_to_sleep] = "go to sleep",
	[IDS.schedule] = "schedule",
	[IDS.timers] = "timer",
	[IDS.coming_home] = "coming home",
	[IDS.leaving_home] = "leaving home",
	[IDS.mimic] = "mimic presence",
	[IDS.natural_light] = "natural light",
	[IDS.tap_switch] = "Hue switch",
}

-- Served script name (lower case, plain find) → kind word, in order: the
-- first match wins. "PM" is matched whole, below.
local NAME_KINDS = {
	{ "wake", "wake up" },
	{ "sleep", "go to sleep" },
	{ "schedule", "schedule" },
	{ "timer", "timer" },
	{ "coming home", "coming home" },
	{ "leaving home", "leaving home" },
	{ "mimic", "mimic presence" },
	{ "presence", "mimic presence" },
	{ "natural light", "natural light" },
	{ "motion sensor", "motion sensor" },
	{ "contact", "contact sensor" },
	{ "switch", "Hue switch" },
	{ "dimmer", "Hue switch" },
}

-- The smoke-alarm script's id is anonymised in every dump: by name only.
local SAFETY_WORDS = { "smoke", "alarm" }

local CATEGORIES = { automation = true, accessory = true, entertainment = true, other = true }

local SWITCH_KEYS = { "buttons", "button1", "button2", "button3", "button4", "rotary" }

local function text(value)
	return type(value) == "string" and value or nil
end

-- A word the bridge sends (status, pm_state, rtype, action): letters,
-- digits and "_" only, else nil.
local function word(value)
	if type(value) == "string" and value:find("^[%w_]+$") then
		return value
	end
	return nil
end

local function name_of(item)
	local metadata = type(item.metadata) == "table" and item.metadata or {}
	return util.display_name(metadata.name)
end

-- Keys in a stable order: numbers first (the array part, ascending), then
-- strings, then anything else by its text.
local function sorted_keys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		if ta == "number" or ta == "string" then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

function model.is_ref(value)
	if type(value) ~= "table" then
		return nil
	end
	local rid, rtype = resource_id(value.rid), word(value.rtype)
	if rid and rtype then
		return rid, rtype
	end
	return nil
end

-- Refs and actions of a configuration, and refs of dependees, into `out`.
local function add_ref(out, seen, rid, rtype, where, level)
	local key = rid .. "|" .. rtype .. "|" .. where
	if not seen[key] then
		seen[key] = true
		out[#out + 1] = { rid = rid, rtype = rtype, where = where, level = level }
	end
end

local function action_word(value)
	if type(value) == "string" then
		return word(value) or "unknown"
	elseif type(value) == "table" then
		if value.recall ~= nil then
			return "recall"
		end
		local first = sorted_keys(value)[1]
		return word(first) or "unknown"
	end
	return "unknown"
end

local function walk_configuration(configuration, refs, seen, actions)
	local action_seen = {}
	local budget = { n = 0 }
	local function walk(node, depth)
		budget.n = budget.n + 1
		if depth > MAX_DEPTH or budget.n > MAX_NODES then
			return
		end
		if node.rid ~= nil or node.rtype ~= nil then
			-- A reference (or a malformed one): nothing further inside.
			local rid, rtype = model.is_ref(node)
			if rid then
				add_ref(refs, seen, rid, rtype, "configuration")
			end
			return
		end
		for _, k in ipairs(sorted_keys(node)) do
			local v = node[k]
			if k == "action" then
				local a = action_word(v)
				if not action_seen[a] then
					action_seen[a] = true
					actions[#actions + 1] = a
				end
			end
			if type(v) == "table" then
				walk(v, depth + 1)
			end
		end
	end
	if type(configuration) == "table" then
		walk(configuration, 1)
	end
end

local function dependee_refs(dependees, refs, seen)
	if type(dependees) ~= "table" then
		return
	end
	for _, entry in ipairs(dependees) do
		if type(entry) == "table" then
			-- The dumps wrap the target; openhue models a bare identifier.
			local rid, rtype = model.is_ref(entry.target)
			if not rid then
				rid, rtype = model.is_ref(entry)
			end
			if rid then
				add_ref(refs, seen, rid, rtype, "dependee", word(entry.level))
			end
		end
	end
end

-- refs, actions of an instance's configuration and dependees.
local function work_out(configuration, dependees)
	local refs, seen, actions = {}, {}, {}
	walk_configuration(configuration, refs, seen, actions)
	dependee_refs(dependees, refs, seen)
	return refs, actions
end

-- Signature ---------------------------------------------------------------

-- A canonical text of a decoded JSON value: sorted keys, typed scalars.
local function serialise(value, parts, depth, budget)
	budget.n = budget.n + 1
	local t = type(value)
	if t == "string" then
		parts[#parts + 1] = string.format("%q", value)
	elseif t == "number" then
		parts[#parts + 1] = string.format("%.14g", value)
	elseif t == "boolean" then
		parts[#parts + 1] = tostring(value)
	elseif t == "table" then
		if depth > MAX_DEPTH or budget.n > MAX_NODES then
			parts[#parts + 1] = "..."
			return
		end
		parts[#parts + 1] = "{"
		for _, k in ipairs(sorted_keys(value)) do
			serialise(k, parts, depth + 1, budget)
			parts[#parts + 1] = "="
			serialise(value[k], parts, depth + 1, budget)
			parts[#parts + 1] = ","
		end
		parts[#parts + 1] = "}"
	else
		parts[#parts + 1] = "null"
	end
end

local TWO32 = 4294967296

-- Two independent 32-bit string hashes (djb2 and sdbm), exact in doubles:
-- h * 65599 + 255 stays below 2^53.
local function hashes(s)
	local h1, h2 = 5381, 0
	for i = 1, #s do
		local b = s:byte(i)
		h1 = (h1 * 33 + b) % TWO32
		h2 = (h2 * 65599 + b) % TWO32
	end
	return h1, h2
end

local function hex32(h)
	return string.format("%04x%04x", math.floor(h / 65536), h % 65536)
end

local function signature_of(name, configuration)
	local parts = { "name=", string.format("%q", name or ""), ";configuration=" }
	serialise(configuration, parts, 1, { n = 0 })
	local s = table.concat(parts)
	local h1, h2 = hashes(s)
	return hex32(h1) .. hex32(h2) .. ":" .. #s
end

function model.signature(item)
	if type(item) ~= "table" then
		return signature_of("", nil)
	end
	local metadata = type(item.metadata) == "table" and item.metadata or {}
	return signature_of(text(metadata.name), item.configuration)
end

-- Records -----------------------------------------------------------------

function model.script(item)
	if type(item) ~= "table" then
		return nil
	end
	local rid = resource_id(item.id)
	if not rid then
		return nil
	end
	local metadata = type(item.metadata) == "table" and item.metadata or {}
	local category = metadata.category
	if category == nil or category == "" or type(category) ~= "string" then
		category = ""
	elseif not CATEGORIES[category] then
		category = "other"
	end
	return {
		rid = rid,
		name = name_of(item),
		category = category,
		version = text(item.version),
		max_instances = tonumber(item.max_number_instances),
	}
end

local function state_word(state, key)
	if type(state) == "table" then
		return word(state[key])
	end
	return nil
end

function model.instance(item)
	if type(item) ~= "table" then
		return nil
	end
	local rid = resource_id(item.id)
	if not rid then
		return nil
	end
	local configuration = type(item.configuration) == "table" and item.configuration or nil
	local dependees = type(item.dependees) == "table" and item.dependees or nil
	local refs, actions = work_out(configuration, dependees)
	local migrated = text(item.migrated_from)
	local metadata = type(item.metadata) == "table" and item.metadata or {}
	return {
		rid = rid,
		script_rid = resource_id(item.script_id),
		name = name_of(item),
		enabled = item.enabled == true,
		status = word(item.status),
		last_error = util.display_name(item.last_error),
		pm_state = state_word(item.state, "pm_state"),
		timer_state = state_word(item.state, "timer_state"),
		migrated = migrated ~= nil and migrated ~= "",
		refs = refs,
		actions = actions,
		sig = model.signature(item),
		configuration = configuration,
		dependees = dependees,
		raw_name = text(metadata.name),
	}
end

local function refs_text(refs)
	local keys = {}
	for i, r in ipairs(refs or {}) do
		keys[i] = r.rid .. "|" .. r.rtype .. "|" .. r.where .. "|" .. tostring(r.level)
	end
	table.sort(keys)
	return table.concat(keys, "\n")
end

function model.update(inst, item)
	local fields = {}
	if type(inst) ~= "table" or type(item) ~= "table" then
		return false, fields
	end
	if type(item.enabled) == "boolean" and item.enabled ~= inst.enabled then
		inst.enabled = item.enabled
		fields.enabled = true
	end
	local status = word(item.status)
	if status and status ~= inst.status then
		inst.status = status
		fields.status = true
	end
	if item.last_error ~= nil then
		local last_error = util.display_name(item.last_error)
		if last_error ~= inst.last_error then
			inst.last_error = last_error
			fields.last_error = true
		end
	end
	if type(item.state) == "table" then
		local pm_state, timer_state = state_word(item.state, "pm_state"), state_word(item.state, "timer_state")
		if pm_state ~= inst.pm_state then
			inst.pm_state = pm_state
			fields.pm_state = true
		end
		if timer_state ~= inst.timer_state then
			inst.timer_state = timer_state
			fields.timer_state = true
		end
	end
	local script_rid = resource_id(item.script_id)
	if script_rid and script_rid ~= inst.script_rid then
		inst.script_rid = script_rid
		fields.script = true
	end
	local renamed = false
	if type(item.metadata) == "table" and type(item.metadata.name) == "string" then
		renamed = true
		inst.raw_name = item.metadata.name
		local name = util.display_name(inst.raw_name)
		if name ~= inst.name then
			inst.name = name
			fields.name = true
		end
	end
	local reshaped = false
	if type(item.configuration) == "table" then
		inst.configuration = item.configuration
		reshaped = true
	end
	if type(item.dependees) == "table" then
		inst.dependees = item.dependees
		reshaped = true
	end
	if reshaped then
		local refs, actions = work_out(inst.configuration, inst.dependees)
		if refs_text(refs) ~= refs_text(inst.refs) then
			fields.refs = true
		end
		if table.concat(actions, ",") ~= table.concat(inst.actions or {}, ",") then
			fields.actions = true
		end
		inst.refs, inst.actions = refs, actions
	end
	if renamed or type(item.configuration) == "table" then
		local sig = signature_of(inst.raw_name, inst.configuration)
		if sig ~= inst.sig then
			inst.sig = sig
			fields.sig = true
		end
	end
	local changed = fields.refs or fields.actions or fields.enabled or fields.pm_state or fields.script
	return changed == true, fields
end

-- Classification ------------------------------------------------------------

function model.inert(inst)
	local actions = type(inst) == "table" and inst.actions or nil
	if type(actions) ~= "table" or #actions == 0 then
		return false
	end
	for _, a in ipairs(actions) do
		if a ~= "do_nothing" then
			return false
		end
	end
	return true
end

local function lower_name(script)
	return type(script) == "table" and type(script.name) == "string" and script.name:lower() or ""
end

local function has_any(s, words)
	for _, w in ipairs(words) do
		if s:find(w, 1, true) then
			return true
		end
	end
	return false
end

local function is_safety(script)
	return has_any(lower_name(script), SAFETY_WORDS)
end

-- What the configuration's shape says: area, motion, contact, camera,
-- switch (booleans), and whether `source` is a reference.
local function shape(inst)
	local configuration = type(inst.configuration) == "table" and inst.configuration or {}
	local s = {}
	local _, source_rtype = model.is_ref(configuration.source)
	s.source = source_rtype ~= nil
	if source_rtype == "motion_area_configuration" then
		s.area = true
	end
	if type(configuration.motion) == "table" then
		s.motion = true
	end
	if configuration.contact ~= nil then
		s.contact = true
	end
	for _, key in ipairs(SWITCH_KEYS) do
		if type(configuration[key]) == "table" then
			s.switch = true
		end
	end
	for _, r in ipairs(inst.refs or {}) do
		local rtype = r.rtype
		if rtype == "motion_area_configuration" or rtype == "convenience_area_motion"
			or rtype == "security_area_motion" then
			s.area = true
		elseif rtype == "motion" then
			s.motion = true
		elseif rtype == "contact" then
			s.contact = true
		elseif rtype == "camera_motion" then
			s.camera = true
		elseif rtype == "button" or rtype == "relative_rotary" then
			s.switch = true
		elseif rtype == "geofence_client" then
			s.presence = true
		end
	end
	s.timed = type(configuration.when) == "table" or type(configuration.when_extended) == "table"
	return s
end

-- The kind word from the script's served name, then from its id.
local function named_kind(inst, script)
	local name = lower_name(script)
	if name == "pm" then
		return "mimic presence"
	end
	for _, pair in ipairs(NAME_KINDS) do
		if name:find(pair[1], 1, true) then
			return pair[2]
		end
	end
	local script_rid = type(script) == "table" and script.rid or inst.script_rid
	return ID_KINDS[script_rid or ""] or ID_KINDS[inst.script_rid or ""]
end

function model.kind(inst, script)
	if type(inst) ~= "table" then
		return "automation"
	end
	if is_safety(script) then
		return "safety lighting"
	end
	local s = shape(inst)
	if s.area then
		return "MotionAware"
	elseif s.motion then
		return "motion sensor"
	elseif s.contact then
		return "contact sensor"
	elseif s.switch then
		return "Hue switch"
	end
	local kind = named_kind(inst, script)
	if kind then
		return kind
	end
	if type(script) == "table" and type(script.name) == "string" and script.name ~= "" then
		return script.name
	end
	return "automation"
end

local function is_entertainment(inst, script)
	if type(script) == "table" and script.category == "entertainment" then
		return true
	end
	if inst.script_rid == IDS.streaming or (type(script) == "table" and script.rid == IDS.streaming) then
		return true
	end
	return lower_name(script):find("streaming", 1, true) ~= nil
end

-- D7.
function model.fires(inst, script)
	if type(inst) ~= "table" then
		return "own"
	end
	if is_entertainment(inst, script) then
		return "none"
	end
	if is_safety(script) then
		return "safety"
	end
	local named = named_kind(inst, script)
	if inst.pm_state ~= nil or named == "mimic presence" then
		return inst.pm_state == "started" and "own" or "person"
	end
	local s = shape(inst)
	if s.area or s.motion or s.contact or s.camera or (s.source and not s.switch) then
		return "own"
	end
	if s.timed then
		return "own"
	end
	if s.presence or named == "coming home" or named == "leaving home" then
		return "own"
	end
	if s.switch then
		return "person"
	end
	if inst.timer_state ~= nil or named == "timer" then
		return "person"
	end
	if named == "go to sleep" then
		-- Without `when` (a time would have answered above): started by a person.
		return "person"
	end
	-- Unknown scripts, and known ones in a shape not seen: the riskier case.
	return "own"
end

-- D6. Play/stop automations (Mimic presence; Timers, F7) and safety
-- lighting get the Hue app steps: their `enabled` is not the app's switch.
function model.remedy(inst, script)
	if type(inst) ~= "table" or type(script) ~= "table" or script.category ~= "automation" then
		return "steps"
	end
	if inst.pm_state ~= nil or inst.timer_state ~= nil or is_safety(script) then
		return "steps"
	end
	local named = named_kind(inst, script)
	if named == "mimic presence" or named == "timer" then
		return "steps"
	end
	return "disable"
end

return model
