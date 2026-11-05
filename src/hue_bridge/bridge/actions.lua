-- The pickers and runners of the bridge's merged actions (#334,
-- docs/simplify-actions-design.md §3.3 and §3.4): Add From Hue, Link Device,
-- Forget Device, Resolve Names and Diagnostics. Built only from the modules'
-- public methods: this module edits no module and keeps no state of its own,
-- so every text, refusal and guard stays the module's, and a module method
-- that is missing (an older module, a part not wired yet) only leaves its
-- part of a list out.
--
--   local actions = require("bridge.actions")
--   local a = actions.new(ctx)
--   ctx = { lights, scenes, zone_lights, motion, names,  -- read at every call
--           last_action = fn(text),                         -- every runner ends here
--           can = fn() -> bool,       -- false with the reason in Last Action
--           diagnostics = { [value] = { text, run = fn(params, say), order?, dev?, shows? } }
--                         (or a list of such entries with a value field, or a function returning either),
--           dev = bool, log?,
--           before_names = fn()? }   -- without bridge/names.lua, run before beta 8's renames
--                                       (driver.lua's fill_proxy_ids: renames need the proxy ids)
--
--   a:add_list(folder)          -> list, back   What of Add From Hue
--   a:room_list()               -> list         Room of Add From Hue (lights:picker_rooms("add"))
--   a:link_list(folder)         -> list, back   Device of Link Device
--   a:link_target_list(folder)  -> list, back   To of Link Device
--   a:forget_list(folder)       -> list, back   Device of Forget Device
--   a:names_list()              -> list         Names of Resolve Names (names:resolve_rows())
--   a:diagnostics_list()        -> list         What of Diagnostics
--   a:run_add(params)  a:run_link(params)  a:run_forget(params)
--   a:run_names(params)  a:run_diagnostics(params)
--   a:run_alias(old_command, params)   a removed command (actions.ALIASES), true when known
--
-- The list functions are CUSTOM_SELECT functions: Composer calls them with
-- the folder value it is in ("" at the top) and takes `list, back`; an entry
-- is { text, value } with string values, `folder = true` opens it and
-- `selectable = true` lets a folder itself be picked; a `back` makes Composer
-- show a Back entry to that folder [verified: FUND
-- 15_composerpro_interface_into_the_sdk/_4-CUSTOMSELECTPROPERTY.md, and on
-- the house with OS 3.4.2, build 447, docs/simplify-actions-design.md §2.3].
-- One pick per picker, and the two pickers of an action are independent (the
-- second never sees the first's value, §2.3), so every runner checks the pair
-- and refuses a mismatch in Last Action.
--
-- Values (stable, logged, never shown):
--   folders  f:lights, f:groups, f:scenes, f:scenes:<group_rid> (in Add From
--            Hue a selectable folder: every scene of that room or zone), f:motion
--   leaves   light:<rid>, group:<rid>, scene:<rid>, sensor:<rid>, area:<rid>,
--            all:lights, all:motion (Import All New's two halves)
--   devices  dev:<device_id>, dev:suggested (every device with a suggested
--            match, and today's Link Devices for bound devices the bridge
--            does not know yet)
--   To       to:suggested: the suggested match of the device picked (the
--            pickers cannot see each other, so this row stands for it)
--   Names    names.lua's values; without names.lua the two bulk rows of
--            actions.NAMES
--   What     the keys of ctx.diagnostics (actions.DIAGNOSTICS names the ones
--            the aliases use)
-- A folder whose list would be empty is left out; a picker with nothing to
-- pick shows one explanatory row with value "" (Composer keeps OK disabled on
-- it [hardware 2026-10-22, bridge/lights.lua picker_rooms]).

local util = require("bridge.util")

local actions = {}
actions.__index = actions

actions.CONFIRM_YES = "Yes, forget"
actions.CONFIRM_ITEMS = { "No", "Yes, forget" }
actions.NOT_CONFIRMED = "Not forgotten: choose Yes, forget"

-- The bulk rows of Resolve Names that the aliases send (names.lua answers
-- them; without names.lua this module answers the first and the third with
-- the modules' adopt_hue_names and accept_names).
actions.NAMES = {
	HUE_TO_COMPOSER = "names:hue_to_composer",
	COMPOSER_TO_HUE = "names:composer_to_hue",
	KEEP_COMPOSER = "names:keep_composer",
}

-- The Diagnostics values the aliases send; driver.lua keys ctx.diagnostics
-- by them (the dev ones only in dev builds).
actions.DIAGNOSTICS = {
	TEST = "diag:test",
	REFRESH = "diag:refresh",
	CONNECT = "diag:connect",
	DISCONNECT = "diag:disconnect",
	MOTION_LOG = "diag:motion_log",
	CONNECTION_TEST_BRIDGE = "diag:connection_test:bridge",
	CONNECTION_TEST_SERVER = "diag:connection_test:server",
	RELOAD_CREDENTIALS = "diag:reload_credentials",
	CHECK_PINNING = "diag:check_pinning",
}

-- The actions this module runs, as driver.xml declares them: the command,
-- the runner, and each parameter's CUSTOM_SELECT function or LIST items.
actions.ACTIONS = {
	{ command = "Add From Hue", runner = "run_add",
		params = { { name = "What", list = "AddFromHueList" }, { name = "Room", list = "RoomList" } } },
	{ command = "Link Device", runner = "run_link",
		params = { { name = "Device", list = "LinkDeviceList" }, { name = "To", list = "LinkTargetList" } } },
	{ command = "Forget Device", runner = "run_forget",
		params = { { name = "Device", list = "ForgetDeviceList" }, { name = "Confirm", items = actions.CONFIRM_ITEMS } } },
	{ command = "Resolve Names", runner = "run_names", params = { { name = "Names", list = "ResolveNamesList" } } },
	{ command = "Diagnostics", runner = "run_diagnostics", params = { { name = "What", list = "DiagnosticsList" } } },
}

-- The global CUSTOM_SELECT functions driver.lua defines, and the method each calls.
actions.LISTS = {
	AddFromHueList = "add_list",
	RoomList = "room_list",
	LinkDeviceList = "link_list",
	LinkTargetList = "link_target_list",
	ForgetDeviceList = "forget_list",
	ResolveNamesList = "names_list",
	DiagnosticsList = "diagnostics_list",
}

local KINDS = {
	lights = { folder = "f:lights", add = "Lights", devices = "Lights", noun = "light",
		pick = "a light (the Lights folder)", none = "(no light device is gone or unbound)" },
	zone_lights = { folder = "f:groups", add = "Zones and rooms", devices = "Zone lights", noun = "zone light",
		pick = "a zone or room (the Zones and rooms folder)", none = "(no zone light device is gone or unbound)" },
	scenes = { folder = "f:scenes", add = "Scenes", devices = "Scenes", noun = "scene",
		pick = "a scene (the Scenes folder)", none = "(no scene device is gone or unbound)" },
	motion = { folder = "f:motion", add = "Motion sensors and areas", devices = "Motion sensors and areas",
		noun = "motion device", pick = "a motion sensor or area (the Motion folder)",
		none = "(no motion device is gone or unbound)" },
}
-- How the pickers list the kinds, and the order a device is looked up in:
-- a zone light's device runs the light driver and may still have a stale
-- light entry (driver.lua's Forget Light rule), so the zone lights go first.
local SHOWN = { "lights", "zone_lights", "scenes", "motion" }
local OWNERS = { "zone_lights", "lights", "scenes", "motion" }
local FOLDER_KIND = { ["f:lights"] = "lights", ["f:groups"] = "zone_lights", ["f:scenes"] = "scenes",
	["f:motion"] = "motion" }
local LEAF_KIND = { light = "lights", group = "zone_lights", scene = "scenes", sensor = "motion", area = "motion" }
local NO_GROUP = "?"   -- the scene folder of scenes whose group is not known

local function str(value)
	if value == nil then
		return nil
	end
	value = tostring(value)
	if value == "" then
		return nil
	end
	return value
end

local function selection(params, name)
	return str(type(params) == "table" and params[name] or nil)
end

local function row(text, value)
	return { text = text, value = value or "" }
end

local function folder(text, value, selectable)
	return { text = text, value = value, folder = true, selectable = selectable or nil }
end

local function append(list, more)
	for _, entry in ipairs(more) do
		list[#list + 1] = entry
	end
	return list
end

-- ok, text from a module call that answers (ok, text), (text) or nothing.
local function outcome(a, b, fallback)
	if type(b) == "string" then
		return a ~= false, b
	end
	if type(a) == "string" then
		return true, a
	end
	return a ~= false, fallback
end

function actions.new(ctx)
	assert(type(ctx) == "table", "actions.new needs a ctx table")
	return setmetatable({ ctx = ctx, log = ctx.log or require("common.log"), problems = nil }, actions)
end

function actions:mod(key)
	local m = self.ctx[key]
	return type(m) == "table" and m or nil
end

function actions:has(key, method)
	local m = self:mod(key)
	return m ~= nil and type(m[method]) == "function"
end

-- A module method's answer, or nil when it is missing or raised (logged,
-- and in a list a row says so).
function actions:call(key, method, ...)
	local m = self:mod(key)
	if not m or type(m[method]) ~= "function" then
		return nil
	end
	local ok, value = pcall(m[method], m, ...)
	if not ok then
		self.log.warn("actions: %s:%s failed: %s", key, method, tostring(value))
		if self.problems then
			self.problems[key] = true
		end
		return nil
	end
	return value
end

function actions:say(say)
	if say then
		return say
	end
	local fn = self.ctx.last_action
	return function(text)
		if type(fn) == "function" then
			fn(text)
		end
	end
end

function actions:can()
	local fn = self.ctx.can
	if type(fn) ~= "function" then
		return true
	end
	return fn() ~= false
end

function actions:dev()
	local dev = self.ctx.dev
	if type(dev) == "function" then
		local ok, value = pcall(dev)
		return ok and value == true
	end
	return dev == true
end

-- Lists ------------------------------------------------------------------------

-- The real entries of a module picker (a copy of each whose value is a
-- non-empty string) and the module's own placeholder text, if it gave one.
function actions:entries(key, method, ...)
	local list = self:call(key, method, ...)
	local out, placeholder = {}, nil
	if type(list) ~= "table" then
		return out, nil
	end
	for _, e in ipairs(list) do
		if type(e) == "table" then
			local value = str(e.value)
			if value then
				out[#out + 1] = { text = tostring(e.text or value), value = value }
			elseif placeholder == nil and e.text ~= nil then
				placeholder = tostring(e.text)
			end
		end
	end
	return out, placeholder
end

function actions:leaves(key, method, prefix, ...)
	local list = self:entries(key, method, ...)
	for _, e in ipairs(list) do
		e.value = prefix .. e.value
	end
	return list
end

function actions:motion_leaves()
	return self:leaves("motion", "picker_sensors", "sensor:"), self:leaves("motion", "picker_areas", "area:")
end

local function motion_label(sensors, areas)
	if sensors > 0 and areas > 0 then
		return string.format("Motion sensors and areas (%d)", sensors + areas)
	elseif areas > 0 then
		return string.format("MotionAware areas (%d)", areas)
	end
	return string.format("Motion sensors (%d)", sensors)
end

-- The unimported scenes by room or zone: { rid, label, items } sorted by
-- label, and how many scenes there are. Texts are the scenes' picker texts,
-- without the room's name in front (the folder says it).
function actions:scene_groups()
	local items = self:entries("scenes", "picker_scenes")
	local groups, by_rid = {}, {}
	for _, e in ipairs(items) do
		local record = self:call("scenes", "record_of", e.value)
		local g = type(record) == "table" and str(record.group_rid) or NO_GROUP
		local group = by_rid[g]
		if not group then
			local label = g ~= NO_GROUP and str(self:call("scenes", "group_label", g, record)) or nil
			group = { rid = g, label = util.sanitise(label or "(no room or zone)"), items = {} }
			by_rid[g] = group
			groups[#groups + 1] = group
		end
		local text, head = e.text, group.label .. ": "
		if #text > #head and text:sub(1, #head) == head then
			text = text:sub(#head + 1)
		end
		group.items[#group.items + 1] = { text = text, value = "scene:" .. e.value }
	end
	table.sort(groups, function(a, b)
		local la, lb = a.label:lower(), b.label:lower()
		if la ~= lb then
			return la < lb
		end
		return a.rid < b.rid
	end)
	return groups, #items, by_rid
end

-- The scene folder rows: "Kitchen: 5 scenes", selectable in Add From Hue.
local function scene_folders(groups, selectable)
	local list = {}
	for _, g in ipairs(groups) do
		list[#list + 1] = folder(string.format("%s: %s", g.label, util.plural(#g.items, "scene")), "f:scenes:" .. g.rid,
			selectable and g.rid ~= NO_GROUP)
	end
	return list
end

local function scenes_text(count, groups)
	return string.format("Scenes (%d in %s)", count, util.plural(#groups, "room"))
end

-- Runs a list builder with module failures noted; a failure of the whole
-- builder answers one row instead of raising into Composer.
function actions:build(what, fn, ...)
	self.problems = {}
	local ok, list, back = pcall(fn, self, ...)
	local problems = self.problems
	self.problems = nil
	if not ok then
		self.log.warn("actions: %s: %s", what, tostring(list))
		return { row("(error building the list; see the Lua output)") }, back
	end
	for _, key in ipairs(SHOWN) do
		if problems[key] then
			list[#list + 1] = row(string.format("(the %s could not be listed; see the Lua output)",
				KINDS[key].add:lower()))
		end
	end
	return list, back
end

local function key_of(folder_value)
	return type(folder_value) == "string" and folder_value or ""
end

-- Add From Hue's What.

function actions:nothing_to_add()
	local seen = tonumber(self:call("lights", "bridge_count"))
	if seen and seen > 0 then
		return row("(everything on the bridge is in Control4 already)")
	end
	local _, placeholder = self:entries("lights", "picker_lights")
	return row(placeholder or "(nothing read from the bridge yet; it shows here once the event stream connects)")
end

function actions:add_root()
	local list = {}
	local lights = self:leaves("lights", "picker_lights", "light:")
	if #lights > 0 then
		list[#list + 1] = folder(string.format("Lights (%d)", #lights), "f:lights")
	end
	local groups = self:leaves("zone_lights", "picker_groups", "group:")
	if #groups > 0 then
		list[#list + 1] = folder(string.format("Zones and rooms (%d)", #groups), "f:groups")
	end
	local scene_groups, scenes = self:scene_groups()
	if scenes > 0 then
		list[#list + 1] = folder(scenes_text(scenes, scene_groups), "f:scenes")
	end
	local sensors, areas = self:motion_leaves()
	if #sensors + #areas > 0 then
		list[#list + 1] = folder(motion_label(#sensors, #areas), "f:motion")
	end
	if #list == 0 then
		list[1] = self:nothing_to_add()
	end
	return list
end

function actions:add_folder(key)
	if key == "f:lights" then
		local lights = self:leaves("lights", "picker_lights", "light:")
		local list = {}
		local n = tonumber(self:call("lights", "new_count"))
		if n == nil and not self:has("lights", "new_count") then
			n = #lights
		end
		if n and n > 0 and self:has("lights", "import_new") then
			list[1] = row(string.format("All %s, each into its mapped room", util.plural(n, "new light")), "all:lights")
		end
		append(list, lights)
		return #list > 0 and list or { row("(no light is left to add)") }, ""
	elseif key == "f:groups" then
		local groups = self:leaves("zone_lights", "picker_groups", "group:")
		return #groups > 0 and groups or { row("(no zone or room is left to add)") }, ""
	elseif key == "f:scenes" then
		local groups = self:scene_groups()
		return #groups > 0 and scene_folders(groups, true) or { row("(no scene is left to add)") }, ""
	elseif key == "f:motion" then
		local sensors, areas = self:motion_leaves()
		local list = {}
		local new = self:call("motion", "new_records", "sensor")
		local n = type(new) == "table" and #new or (not self:has("motion", "new_records") and #sensors or 0)
		if n > 0 and self:has("motion", "import_new") then
			list[1] = row(string.format("All %s, each into its mapped room", util.plural(n, "new motion sensor")),
				"all:motion")
		end
		append(append(list, sensors), areas)
		return #list > 0 and list or { row("(no motion sensor or area is left to add)") }, ""
	end
	local g = key:match("^f:scenes:(.+)$")
	if g then
		local _, _, by_rid = self:scene_groups()
		local group = by_rid[g]
		if not group then
			return { row("(no scene of this room or zone is left to add)") }, "f:scenes"
		end
		local list = {}
		if g ~= NO_GROUP then
			list[1] = row(string.format("All scenes of %s not in Control4 yet", group.label), key)
		end
		return append(list, group.items), "f:scenes"
	end
	return nil
end

function actions:add_list(folder_value)
	return self:build("Add From Hue", function(s)
		local key = key_of(folder_value)
		if key ~= "" then
			local list, back = s:add_folder(key)
			if list then
				return list, back
			end
			s.log.debug("actions: Add From Hue has no folder %q; the top instead", key)
		end
		return s:add_root()
	end)
end

function actions:room_list()
	return self:build("Room", function(s)
		-- The lights' list as it is, its explanatory rows included.
		local list, out = s:call("lights", "picker_rooms", "add"), {}
		for _, e in ipairs(type(list) == "table" and list or {}) do
			if type(e) == "table" then
				out[#out + 1] = row(tostring(e.text or e.value or ""), str(e.value) or "")
			end
		end
		if #out == 0 then
			out[1] = row("(not ready yet; open the list again)")
		end
		return out
	end)
end

-- Suggestions (bridge/lights.lua and bridge/motion.lua suggested(), §3.2 and
-- §3.4; any module may have one): a list of { device_id, rid, text? } or a
-- map device_id -> rid or -> { rid, text }. Returns them sorted by device,
-- and by device id.
function actions:suggestions()
	local out, by_device = {}, {}
	for _, key in ipairs(OWNERS) do
		local list = self:call(key, "suggested")
		if type(list) == "table" then
			local function take(device_id, item)
				local id, rid, text = tonumber(device_id), nil, nil
				if type(item) == "string" then
					rid = item
				elseif type(item) == "table" then
					id = id or tonumber(item.device_id or item.device)
					rid = item.rid or item.to or item.new_rid
					text = str(item.text or item.label)
				end
				rid = str(rid)
				if id and rid and not by_device[id] then
					local s = { device_id = id, rid = rid, text = text, kind = key }
					out[#out + 1] = s
					by_device[id] = s
				end
			end
			if #list > 0 then
				for _, item in ipairs(list) do take(nil, item) end
			else
				for k, item in pairs(list) do take(k, item) end
			end
		end
	end
	table.sort(out, function(a, b) return a.device_id < b.device_id end)
	return out, by_device
end

local function suggestion_suffix(s)
	if not s then
		return ""
	end
	return s.text and (" → " .. util.sanitise(s.text) .. " (suggested)") or " (has a suggested match)"
end

-- A module's device rows: picker values (device ids) as dev:<id>.
function actions:devices(key, method)
	local out = {}
	for _, e in ipairs(self:entries(key, method)) do
		local id = util.positive(e.value)
		if id then
			out[#out + 1] = { text = e.text, value = "dev:" .. tostring(id) }
		end
	end
	return out
end

local function id_of(value)
	return util.positive(type(value) == "string" and value:match("^dev:(%d+)$") or nil)
end

-- Link Device's devices of one kind: the gone and unbound ones, each with its
-- suggestion, then suggested devices the list lacks.
function actions:relink_devices(key, by_device)
	local list, seen = {}, {}
	for _, e in ipairs(self:devices(key, "picker_relink_devices")) do
		local id = id_of(e.value)
		seen[id] = true
		list[#list + 1] = { text = e.text .. suggestion_suffix(by_device[id]), value = e.value }
	end
	local extra = {}
	for id, s in pairs(by_device) do
		if s.kind == key and not seen[id] then
			extra[#extra + 1] = s
		end
	end
	table.sort(extra, function(a, b) return a.device_id < b.device_id end)
	if #extra > 0 then
		local names = {}
		for _, e in ipairs(self:devices(key, "picker_forget_devices")) do
			names[id_of(e.value)] = e.text
		end
		for _, s in ipairs(extra) do
			list[#list + 1] = { text = (names[s.device_id] or ("Device " .. s.device_id)) .. suggestion_suffix(s),
				value = "dev:" .. s.device_id }
		end
	end
	return list
end

-- The top of a device picker: `rows` first, then one folder per kind with
-- entries; a lone kind is shown in place of its folder.
local function by_kind(rows, kinds, empty)
	local filled = {}
	for _, k in ipairs(kinds) do
		if #k.list > 0 then
			filled[#filled + 1] = k
		end
	end
	if #filled == 1 then
		return append(rows, filled[1].list)
	end
	for _, k in ipairs(filled) do
		rows[#rows + 1] = folder(k.text or string.format("%s (%d)", KINDS[k.key].devices, #k.list), KINDS[k.key].folder)
	end
	if #rows == 0 and empty then
		rows[1] = row(empty)
	end
	return rows
end

function actions:link_rows()
	local suggestions, by_device = self:suggestions()
	local top = #suggestions > 0
		and row(string.format("Every device with a suggested match (%d)", #suggestions), "dev:suggested")
		or row("Every bound device the bridge does not know yet, by its own id or name", "dev:suggested")
	local kinds = {}
	for _, key in ipairs(SHOWN) do
		kinds[#kinds + 1] = { key = key, list = self:relink_devices(key, by_device) }
	end
	return top, kinds
end

function actions:link_list(folder_value)
	return self:build("Link Device", function(s)
		local key = key_of(folder_value)
		local top, kinds = s:link_rows()
		local kind = FOLDER_KIND[key]
		if kind then
			for _, k in ipairs(kinds) do
				if k.key == kind then
					return #k.list > 0 and k.list or { row(KINDS[kind].none) }, ""
				end
			end
		end
		return by_kind({ top }, kinds)
	end)
end

-- Link Device's To: the Hue things with no device, by kind; the scenes by
-- room or zone (those folders are not selectable here).
function actions:target_kinds()
	local scene_groups, scenes = self:scene_groups()
	local sensors, areas = self:motion_leaves()
	local motion_text = motion_label(#sensors, #areas)
	return {
		{ key = "lights", list = self:leaves("lights", "picker_lights", "light:") },
		{ key = "zone_lights", list = self:leaves("zone_lights", "picker_groups", "group:"),
			text_fn = function(n) return string.format("Zones and rooms (%d)", n) end },
		{ key = "scenes", list = scene_folders(scene_groups, false), text = scenes > 0 and scenes_text(scenes, scene_groups)
			or nil, groups = scene_groups },
		{ key = "motion", list = append(sensors, areas), text = motion_text },
	}
end

function actions:link_target_list(folder_value)
	return self:build("Link Device To", function(s)
		local key = key_of(folder_value)
		local kinds = s:target_kinds()
		local filled = 0
		for _, k in ipairs(kinds) do
			if k.text_fn then
				k.text = k.text_fn(#k.list)
			end
			if #k.list > 0 then
				filled = filled + 1
			end
		end
		local kind = FOLDER_KIND[key]
		if kind then
			for _, k in ipairs(kinds) do
				if k.key == kind then
					return #k.list > 0 and k.list or { row("(nothing of this kind is free on the bridge)") }, ""
				end
			end
		end
		local g = key:match("^f:scenes:(.+)$")
		if g then
			-- Back to the Scenes folder, or to the top when the scenes are its only kind.
			local back = filled == 1 and "" or "f:scenes"
			for _, group in ipairs(kinds[3].groups) do
				if group.rid == g then
					return group.items, back
				end
			end
			return { row("(no scene of this room or zone is free on the bridge)") }, back
		end
		return by_kind({ row("(its suggested match)", "to:suggested") }, kinds)
	end)
end

function actions:forget_list(folder_value)
	return self:build("Forget Device", function(s)
		local key = key_of(folder_value)
		local kinds = {}
		for _, k in ipairs(SHOWN) do
			kinds[#kinds + 1] = { key = k, list = s:devices(k, "picker_forget_devices") }
		end
		local kind = FOLDER_KIND[key]
		if kind then
			for _, k in ipairs(kinds) do
				if k.key == kind then
					return #k.list > 0 and k.list or { row("(no device of this kind is linked to the bridge)") }, ""
				end
			end
		end
		return by_kind({}, kinds, "(no device is linked to this bridge)")
	end)
end

-- Resolve Names: names.lua's rows, or without it the two bulk rows of the
-- modules' names pair (beta 8's Adopt Hue Names and Accept Names As They Are).
function actions:names_fallback()
	for _, key in ipairs(SHOWN) do
		if self:has(key, "adopt_hue_names") then
			return true
		end
	end
	return false
end

function actions:names_list()
	return self:build("Resolve Names", function(s)
		if s:has("names", "resolve_rows") then
			local list = s:entries("names", "resolve_rows")
			if #list == 0 then
				return { row("(every name agrees between Composer and Hue)") }
			end
			return list
		end
		if s:names_fallback() then
			return {
				row("Hue names to Composer: rename every device whose name differs", actions.NAMES.HUE_TO_COMPOSER),
				row("Keep every Composer name as it is", actions.NAMES.KEEP_COMPOSER),
			}
		end
		return { row("(names are not ready yet; open the list again)") }
	end)
end

-- Diagnostics: ctx.diagnostics, by `order` then value; dev entries only in dev builds.
function actions:diagnostic_entries()
	local d = self.ctx.diagnostics
	if type(d) == "function" then
		local ok, value = pcall(d)
		d = ok and value or nil
	end
	local out = {}
	if type(d) ~= "table" then
		return out
	end
	local dev = self:dev()
	local function take(value, e, i)
		value = str(value)
		if value and type(e) == "table" and type(e.run) == "function" and (not e.dev or dev) then
			out[#out + 1] = { value = value, text = tostring(e.text or value), run = e.run, shows = str(e.shows),
				order = tonumber(e.order) or i or math.huge }
		end
	end
	if #d > 0 then
		for i, e in ipairs(d) do take(type(e) == "table" and e.value, e, i) end
	else
		for value, e in pairs(d) do take(value, e, nil) end
	end
	table.sort(out, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.value < b.value
	end)
	return out
end

function actions:diagnostics_list()
	return self:build("Diagnostics", function(s)
		local list = {}
		for _, e in ipairs(s:diagnostic_entries()) do
			list[#list + 1] = row(e.text, e.value)
		end
		if #list == 0 then
			list[1] = row("(no diagnostics in this build)")
		end
		return list
	end)
end

-- Runners ------------------------------------------------------------------------

-- fn(say) with a raise turned into a Last Action line (and an [ERROR] log).
function actions:guard(what, say, fn)
	local ok, err = pcall(fn, say)
	if not ok then
		self.log.error("actions: %s failed: %s", what, tostring(err))
		say(string.format("%s failed: %s (see the Lua output)", what, tostring(err)))
	end
end

local function done_to(say, fallback)
	return function(a, b)
		local _, text = outcome(a, b, fallback)
		say(text)
	end
end

-- nil for "(mapped room)" (the value "mapped") or no room, a room id, or
-- false and the refusal.
local function room_of(value)
	if value == nil or value == "mapped" then
		return nil
	end
	local id = util.positive(value)
	if id and math.floor(id) == id then
		return id
	end
	return false, "Not added: pick a room under Room, or (mapped room)"
end

local ADD = {
	light = { "lights", "add_light" },
	group = { "zone_lights", "add" },
	scene = { "scenes", "add_scene" },
	sensor = { "motion", "add" },
	area = { "motion", "add" },
}

local function not_ready(verb, key, say)
	say(string.format("Not %s: the %s are not ready yet; try again in a minute", verb, KINDS[key].add:lower()))
end

function actions:run_add(params, say)
	say = self:say(say)
	self:guard("Add From Hue", say, function()
		if not self:can() then
			return
		end
		local what = selection(params, "What")
		self.log.info("actions: Add From Hue What=%s Room=%s", tostring(what), tostring(selection(params, "Room")))
		if not what then
			return say("Not added: pick a light, zone, scene or motion sensor under What first")
		end
		local room_id, refusal = room_of(selection(params, "Room"))
		if room_id == false then
			return say(refusal)
		end
		local bulk = what == "all:lights" and { "lights", "import_new", "lights" }
			or what == "all:motion" and { "motion", "import_new", "motion sensors" } or nil
		local group = what:match("^f:scenes:(.+)$")
		if (bulk or group) and room_id then
			return say(string.format("Not added: all new %s go each into the room its Hue room maps to; set Room to "
				.. "(mapped room), or pick one", bulk and bulk[3] or "scenes of a room or zone"))
		end
		if bulk then
			if not self:has(bulk[1], bulk[2]) then
				return not_ready("added", bulk[1], say)
			end
			return self:mod(bulk[1]):import_new(done_to(say, "Import finished"))
		end
		if group then
			if group == NO_GROUP or not self:has("scenes", "add_all_of_group") then
				return say("Not added: open this folder and pick one scene")
			end
			return self:mod("scenes"):add_all_of_group(group, done_to(say, "Scenes added"))
		end
		local kind = FOLDER_KIND[what]
		if kind then
			return say(string.format("Not added: %s is a folder; open it and pick one inside", KINDS[kind].add))
		end
		local prefix, rid = what:match("^(%a+):(.+)$")
		local route = prefix and ADD[prefix]
		if not route then
			return say(string.format("Not added: %q is not something Add From Hue offers; open What again", what))
		end
		if not self:has(route[1], route[2]) then
			return not_ready("added", route[1], say)
		end
		local m = self:mod(route[1])
		m[route[2]](m, rid, room_id, done_to(say, "Added"))
	end)
end

-- The kind whose `method` picker offers device `id`, in lookup order; the
-- set of every kind that offers it as the second value.
function actions:device_kind(id, method)
	local first, all = nil, {}
	for _, key in ipairs(OWNERS) do
		for _, e in ipairs(self:devices(key, method)) do
			if id_of(e.value) == id then
				all[key] = true
				first = first or key
				break
			end
		end
	end
	return first, all
end

function actions:relink(key, id, rid)
	if not self:has(key, "relink") then
		return false, string.format("Not linked: the %s are not ready yet; try again in a minute", KINDS[key].add:lower())
	end
	local m = self:mod(key)
	return outcome(m:relink(id, rid))
end

-- Today's Link Devices: every module adopts its bound devices the registry
-- lacks, by the rid they announce or by an exact unique name; each skips
-- the other's devices (driver.lua's rule before 1.2). The joined report.
function actions:link_bound_text()
	local function ids(key)
		local set = {}
		for _, e in ipairs(self:devices(key, "picker_forget_devices")) do
			set[id_of(e.value)] = true
		end
		return set
	end
	local zone_ids = self:call("zone_lights", "device_ids")
	local texts = {
		lights = self:call("lights", "link_devices", type(zone_ids) == "table" and zone_ids or {}),
		scenes = self:call("scenes", "link_devices"),
		zone_lights = self:call("zone_lights", "link_devices", ids("lights")),
		motion = self:call("motion", "link_devices"),
	}
	local text = str(texts.lights) or "Lights: not ready"
	for _, part in ipairs({ { "scenes", "Scenes" }, { "zone_lights", "Zone lights" }, { "motion", "Motion" } }) do
		local t = str(texts[part[1]])
		if t then
			text = text .. " | " .. part[2] .. ": " .. t
		end
	end
	return text
end

function actions:link_all(to, say)
	if to and to ~= "to:suggested" then
		return say("Not linked: every device with a suggested match goes to its own match; set To to "
			.. "(its suggested match)")
	end
	local suggestions = self:suggestions()
	local parts = {}
	for _, s in ipairs(suggestions) do
		local _, text = self:relink(s.kind, s.device_id, s.rid)
		parts[#parts + 1] = tostring(text)
	end
	local bound = self:link_bound_text()
	if #parts == 0 then
		return say(bound)
	end
	say(string.format("Suggested matches: %s | %s", table.concat(parts, "; "), bound))
end

function actions:run_link(params, say)
	say = self:say(say)
	self:guard("Link Device", say, function()
		if not self:can() then
			return
		end
		local device, to = selection(params, "Device"), selection(params, "To")
		self.log.info("actions: Link Device Device=%s To=%s", tostring(device), tostring(to))
		if not device then
			return say("Not linked: pick a device under Device first")
		end
		if device == "dev:suggested" then
			return self:link_all(to, say)
		end
		local id = id_of(device)
		if not id then
			return say(string.format("Not linked: %q is not a device Link Device offers; open Device again", device))
		end
		local _, by_device = self:suggestions()
		local suggestion = by_device[id]
		local kind = self:device_kind(id, "picker_relink_devices") or (suggestion and suggestion.kind)
			or self:device_kind(id, "picker_forget_devices")
		if not kind then
			return say(string.format("Not linked: device %d is not a device of this bridge any more; open Device again",
				id))
		end
		local rid
		if not to or to == "to:suggested" then
			if not suggestion then
				return say(string.format("Not linked: device %d has no suggested match; under To pick %s", id,
					KINDS[kind].pick))
			end
			kind, rid = suggestion.kind, suggestion.rid
		else
			local folder_kind = FOLDER_KIND[to] or (to:match("^f:scenes:") and "scenes")
			if folder_kind then
				return say(string.format("Not linked: %s under To is a folder; open it and pick one inside",
					KINDS[folder_kind].add))
			end
			local prefix
			prefix, rid = to:match("^(%a+):(.*)$")
			local want = prefix and LEAF_KIND[prefix]
			if not want then
				return say(string.format("Not linked: %q is not something Link Device offers; open To again", to))
			end
			if rid == "" then
				return say(string.format("Not linked: pick %s under To", KINDS[want].pick))
			end
			if want ~= kind then
				return say(string.format("Not linked: device %d is a %s; under To pick %s", id, KINDS[kind].noun,
					KINDS[kind].pick))
			end
		end
		local _, text = self:relink(kind, id, rid)
		say(text or "Linked")
	end)
end

-- Today's Link Devices alone (the alias of "Link Devices"): no suggestion
-- is applied, as before 1.2.
function actions:run_link_bound(_params, say)
	say = self:say(say)
	self:guard("Link Device", say, function()
		if self:can() then
			say(self:link_bound_text())
		end
	end)
end

function actions:run_forget(params, say)
	say = self:say(say)
	self:guard("Forget Device", say, function()
		if not self:can() then
			return
		end
		local device = selection(params, "Device")
		self.log.info("actions: Forget Device Device=%s Confirm=%s", tostring(device), tostring(selection(params,
			"Confirm")))
		if not device then
			return say("Not forgotten: pick a device under Device first")
		end
		if selection(params, "Confirm") ~= actions.CONFIRM_YES then
			return say(actions.NOT_CONFIRMED)
		end
		local id = id_of(device)
		if not id then
			return say(string.format("Not forgotten: %q is not a device Forget Device offers; open Device again", device))
		end
		local kind, all = self:device_kind(id, "picker_forget_devices")
		if not kind then
			return say(string.format("Not forgotten: device %d is not linked to this bridge any more", id))
		end
		if not self:has(kind, "forget") then
			return not_ready("forgotten", kind, say)
		end
		local _, text = outcome(self:mod(kind):forget(id))
		-- A zone light's device with a stale light entry (an older bridge
		-- adopted its hello as a light): that entry goes too, as before 1.2.
		if kind == "zone_lights" and all.lights and self:has("lights", "forget") then
			local _, stale = outcome(self:mod("lights"):forget(id))
			text = tostring(text) .. " | " .. tostring(stale)
		end
		say(text or "Forgotten")
	end)
end

function actions:names_join(method)
	local texts = {}
	for _, key in ipairs(SHOWN) do
		texts[key] = str(self:call(key, method))
	end
	local text = texts.lights or "Lights: not ready"
	for _, part in ipairs({ { "scenes", "Scenes" }, { "zone_lights", "Zone lights" }, { "motion", "Motion" } }) do
		if texts[part[1]] then
			text = text .. " | " .. part[2] .. ": " .. texts[part[1]]
		end
	end
	return text
end

function actions:run_names(params, say)
	say = self:say(say)
	self:guard("Resolve Names", say, function()
		local value = selection(params, "Names")
		self.log.info("actions: Resolve Names Names=%s", tostring(value))
		if not value then
			return say("Nothing renamed: pick a row under Names first")
		end
		if self:has("names", "resolve") then
			local n = self:mod("names")
			return n:resolve(value, done_to(say, "Names resolved"))
		end
		-- Without bridge/names.lua: beta 8's pair, which needs the pairing.
		if value == actions.NAMES.HUE_TO_COMPOSER or value == actions.NAMES.KEEP_COMPOSER then
			if not self:can() then
				return
			end
			if value == actions.NAMES.HUE_TO_COMPOSER and type(self.ctx.before_names) == "function" then
				self.ctx.before_names()
			end
			return say(self:names_join(value == actions.NAMES.HUE_TO_COMPOSER and "adopt_hue_names" or "accept_names"))
		end
		say("Nothing renamed: that row is not offered any more; open Names again")
	end)
end

-- The alias of "Accept Names As They Are": with names that follow each other
-- both ways there is nothing to accept (docs/simplify-research-names-sync.md,
-- Accept: its alias writes nothing); without bridge/names.lua, beta 8's accept.
function actions:run_accept_names(_params, say)
	say = self:say(say)
	self:guard("Resolve Names", say, function()
		if self:has("names", "resolve") then
			local rows = self:entries("names", "resolve_rows")
			return say(string.format("Nothing to accept: names follow each other between Composer and Hue by "
				.. "themselves; %s", #rows > 0 and "the ones that cannot are in Resolve Names" or "every name agrees"))
		end
		if self:can() then
			say(self:names_join("accept_names"))
		end
	end)
end

function actions:run_diagnostics(params, say)
	say = self:say(say)
	self:guard("Diagnostics", say, function()
		local value = selection(params, "What")
		self.log.info("actions: Diagnostics What=%s", tostring(value))
		if not value then
			return say("Nothing run: pick what to run under What first")
		end
		local entry
		for _, e in ipairs(self:diagnostic_entries()) do
			if e.value == value then
				entry = e
			end
		end
		if not entry then
			return say(string.format("Nothing run: %q is not a diagnostic of this build", value))
		end
		-- First, so that whatever the entry writes itself (Last Action, now
		-- or later) is what stays.
		say(entry.shows and string.format("%s: started (the result shows in %s)", entry.text, entry.shows)
			or string.format("%s: started", entry.text))
		local result = entry.run(params, say)
		if type(result) == "string" and result ~= "" then
			say(result)
		end
	end)
end

-- Aliases ------------------------------------------------------------------------

-- Every command a beta 8 driver.xml had and 1.2 merged into these runners
-- answers until 2.0 (docs/simplify-research-compat.md §5.3 R2): the dev
-- loop, tools/regress.sh, older briefs and any C4:SendToDevice caller send
-- them by name, with their old parameters. A missing pick gets beta 8's
-- refusal (`needs`, `missing`); otherwise the Last Action is the new
-- runner's, which is the module's own text as before; the pointer to the
-- new action goes to the log only (as the child drivers' aliases do).
-- Kept as beta 8 had them, in driver.lua: Map Rooms By Name, Room Audit,
-- Refresh Scenes (the scene list alone, at once), and in dev builds
-- Connection Test, Reload Credentials, Check CA Pinning and Probe Picker
-- Folders.

local function pre(prefix, value)
	value = str(value)
	return value and (prefix .. value) or nil
end

-- A motion re-link target: a sensor or an area, as the motion pickers list it.
local function motion_target(self, rid)
	rid = str(rid)
	if not rid then
		return nil
	end
	for _, e in ipairs(self:entries("motion", "picker_areas")) do
		if e.value == rid then
			return "area:" .. rid
		end
	end
	return "sensor:" .. rid
end

actions.ALIASES = {
	["Add Light"] = { target = "Add From Hue", runner = "run_add", needs = { "Light" },
		missing = "Not added: pick a light first",
		params = function(p) return { What = pre("light:", p.Light), Room = p.Room } end },
	["Import All New Lights"] = { target = "Import All New", runner = "run_add",
		params = function() return { What = "all:lights" } end },
	["Add Zone Light"] = { target = "Add From Hue", runner = "run_add", needs = { "Group" },
		missing = "Not added: pick a zone or room first",
		params = function(p) return { What = pre("group:", p.Group), Room = p.Room } end },
	["Re-link Device To Light"] = { target = "Link Device", runner = "run_link", needs = { "Device", "Light" },
		missing = "Not re-linked: pick a device and a light",
		params = function(p) return { Device = pre("dev:", p.Device), To = pre("light:", p.Light) } end },
	["Re-link Zone Light"] = { target = "Link Device", runner = "run_link", needs = { "Device", "Group" },
		missing = "Not re-linked: pick a device and a zone or room",
		params = function(p) return { Device = pre("dev:", p.Device), To = pre("group:", p.Group) } end },
	["Link Devices"] = { target = "Link Device", runner = "run_link_bound" },
	["Forget Light"] = { target = "Forget Device", runner = "run_forget", needs = { "Device" },
		missing = "Not forgotten: pick a device first",
		params = function(p) return { Device = pre("dev:", p.Device), Confirm = actions.CONFIRM_YES } end },
	["Adopt Hue Names"] = { target = "Resolve Names", runner = "run_names",
		params = function() return { Names = actions.NAMES.HUE_TO_COMPOSER } end },
	["Accept Names As They Are"] = { target = "Resolve Names", runner = "run_accept_names" },
	["Add Scene"] = { target = "Add From Hue", runner = "run_add", needs = { "Scene" },
		missing = "Not added: pick a scene first",
		params = function(p) return { What = pre("scene:", p.Scene), Room = p.Room } end },
	["Add All Scenes Of Room"] = { target = "Add From Hue", runner = "run_add", needs = { "Hue Room" },
		missing = "Not added: pick a Hue room first",
		params = function(p) return { What = pre("f:scenes:", p["Hue Room"]) } end },
	["Re-link Scene"] = { target = "Link Device", runner = "run_link", needs = { "Device", "Scene" },
		missing = "Not re-linked: pick a device and a scene",
		params = function(p) return { Device = pre("dev:", p.Device), To = pre("scene:", p.Scene) } end },
	["Forget Scene"] = { target = "Forget Device", runner = "run_forget", needs = { "Device" },
		missing = "Not forgotten: pick a device first",
		params = function(p) return { Device = pre("dev:", p.Device), Confirm = actions.CONFIRM_YES } end },
	["Add Motion Sensor"] = { target = "Add From Hue", runner = "run_add", needs = { "Sensor" },
		missing = "Not added: pick a motion sensor first",
		params = function(p) return { What = pre("sensor:", p.Sensor), Room = p.Room } end },
	["Import All New Motion Sensors"] = { target = "Import All New", runner = "run_add",
		params = function() return { What = "all:motion" } end },
	["Add Motion Area"] = { target = "Add From Hue", runner = "run_add", needs = { "Area" },
		missing = "Not added: pick a MotionAware area first",
		params = function(p) return { What = pre("area:", p.Area), Room = p.Room } end },
	["Re-link Motion Device"] = { target = "Link Device", runner = "run_link", needs = { "Device", "Target" },
		missing = "Not re-linked: pick a device and a sensor or area",
		params = function(p, self) return { Device = pre("dev:", p.Device), To = motion_target(self, p.Target) } end },
	["Forget Motion Device"] = { target = "Forget Device", runner = "run_forget", needs = { "Device" },
		missing = "Not forgotten: pick a device first",
		params = function(p) return { Device = pre("dev:", p.Device), Confirm = actions.CONFIRM_YES } end },
	["Test Connection"] = { target = "Diagnostics", runner = "run_diagnostics",
		params = function() return { What = actions.DIAGNOSTICS.TEST } end },
	["Refresh All"] = { target = "Diagnostics", runner = "run_diagnostics",
		params = function() return { What = actions.DIAGNOSTICS.REFRESH } end },
	["Connect Event Stream"] = { target = "Diagnostics", runner = "run_diagnostics",
		params = function() return { What = actions.DIAGNOSTICS.CONNECT } end },
	["Disconnect Event Stream"] = { target = "Diagnostics", runner = "run_diagnostics",
		params = function() return { What = actions.DIAGNOSTICS.DISCONNECT } end },
	["Log Motion Diagnostics"] = { target = "Diagnostics", runner = "run_diagnostics",
		params = function() return { What = actions.DIAGNOSTICS.MOTION_LOG } end },
}

function actions:run_alias(old, params, say)
	local alias = actions.ALIASES[old]
	if not alias then
		return false
	end
	self.log.always("actions: %s is now %s (an alias until 2.0)", old, alias.target)
	local p = type(params) == "table" and params or {}
	for _, name in ipairs(alias.needs or {}) do
		if not selection(p, name) then
			if self:can() then
				self:say(say)(alias.missing)
			end
			return true
		end
	end
	self[alias.runner](self, alias.params and alias.params(p, self) or {}, say)
	return true
end

return actions
