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
--
-- The beta 8 commands these actions merged answered as hidden aliases until
-- 2.0 and are gone since (docs/hdmi-sync-design.md §9.3 and §10 O15, #514):
-- an old name such as Add Light is an unknown command, as any other is.
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
--            Hue a selectable folder: every scene of that room or zone, into
--            the room it maps to; not selectable when it maps to none, #469), f:motion;
--            f:top, the labelled "Back to all folders" row: the top itself
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
--            driver.lua defines)
-- A folder whose list would be empty is left out; a picker with nothing to
-- pick shows one explanatory row with value "" (Composer keeps OK disabled on
-- it [hardware 2026-10-22, bridge/lights.lua picker_rooms]).

local util = require("bridge.util")

local actions = {}

-- A picked value quoted in Last Action (`"%s"`), or in a log line: control
-- characters made spaces and the length capped (util.echo), never `%q`,
-- which lets ESC and BEL through and quotes any length (security review
-- 2026-11-13 C-4, #489).
local echo = util.echo
local function logged(value)
	return util.echo(value, util.LOG_MAX)
end
actions.__index = actions

actions.CONFIRM_YES = "Yes, forget"
actions.CONFIRM_ITEMS = { "No", "Yes, forget" }
actions.NOT_CONFIRMED = "Not forgotten: choose Yes, forget"

-- The bulk rows of Resolve Names (names.lua offers and answers the first two
-- itself; without names.lua this module offers the first and the third and
-- answers them with the modules' adopt_hue_names and accept_names).
actions.NAMES = {
	HUE_TO_COMPOSER = "names:hue_to_composer",
	COMPOSER_TO_HUE = "names:composer_to_hue",
	KEEP_COMPOSER = "names:keep_composer",
}

-- The Diagnostics values; driver.lua keys ctx.diagnostics by them (the dev
-- ones only in dev builds).
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
local WHOLE_HOME = "(whole home)"  -- the bridge_home's scene folder (#469 S1; Set Room Mapping's own row, P6)
local NO_ROOM_KEY = "~"            -- scenes:group_target's sort key of a group with no room: after every room

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

-- Where the scenes of a Hue room or zone go (scenes:group_target, #469 S1):
-- { text, room_id, sort_key }, text a Control4 room name, "(unmapped)", "(no
-- mapping)" or "(Control4 room gone)", room_id nil when there is no room,
-- sort_key the room's name lowercased or "~". nil when the scenes module has
-- no group_target (an older module) or it failed: the folder then reads as
-- before 1.6. Takes the answer as a table or as three values. `rooms` (the
-- project's rooms, optional) spares group_target one lookup per group.
function actions:group_target(g, rooms)
	local m = self:mod("scenes")
	if g == NO_GROUP or not m or type(m.group_target) ~= "function" then
		return nil
	end
	local ok, a, b, c = pcall(m.group_target, m, g, rooms)
	if not ok then
		self.log.warn("actions: scenes:group_target failed: %s", tostring(a))
		return nil
	end
	if type(a) == "table" then
		a, b, c = a.text, a.room_id, a.sort_key
	end
	local text = str(a)
	if not text then
		return nil
	end
	local room_id = util.positive(b)
	return { text = util.sanitise(text), room_id = room_id,
		sort_key = str(c) or (room_id and text:lower()) or NO_ROOM_KEY }
end

-- The project's rooms read once for a whole list (the scenes module's project
-- calls, bridge/project.lua), or nil when they cannot be read.
function actions:project_rooms()
	local m = self:mod("scenes")
	local p = m and m.project
	if type(p) ~= "table" or type(p.rooms) ~= "function" then
		return nil
	end
	local ok, rooms = pcall(p.rooms, p)
	return ok and type(rooms) == "table" and rooms or nil
end

-- The unimported scenes by room or zone: { rid, label, items, target } sorted
-- by the Control4 room their scenes go to (group_target's sort key; groups
-- with no room last), then by label (#469 S1), and how many scenes there
-- are. Texts are the scenes' picker texts, without the room's name in front
-- (the folder says it). The whole home (bridge_home) is "(whole home)", and
-- "the whole home" in a sentence (`noun`).
function actions:scene_groups()
	local items = self:entries("scenes", "picker_scenes")
	local groups, by_rid, rooms = {}, {}, nil
	for _, e in ipairs(items) do
		local record = self:call("scenes", "record_of", e.value)
		local g = type(record) == "table" and str(record.group_rid) or NO_GROUP
		local group = by_rid[g]
		if not group then
			local label = g ~= NO_GROUP and str(self:call("scenes", "group_label", g, record)) or nil
			label = util.sanitise(label or "(no room or zone)")
			local home = type(record) == "table" and record.group_type == "bridge_home"
			local shown = home and WHOLE_HOME or label
			if rooms == nil and self:has("scenes", "group_target") then
				rooms = self:project_rooms() or false
			end
			local target = self:group_target(g, rooms or nil)
			group = { rid = g, label = shown, noun = home and "the whole home" or shown, heads = { label .. ": ",
				shown .. ": " }, items = {}, target = target, key = target and target.sort_key or NO_ROOM_KEY,
				label_key = shown:lower(), rank = target and target.room_id and 0 or 1 }
			by_rid[g] = group
			groups[#groups + 1] = group
		end
		local text = e.text
		for _, head in ipairs(group.heads) do
			if #text > #head and text:sub(1, #head) == head then
				text = text:sub(#head + 1)
				break
			end
		end
		group.items[#group.items + 1] = { text = text, value = "scene:" .. e.value }
	end
	-- The groups with a room first whatever their names' bytes ("~" sorts
	-- before a UTF-8 "Ö"), then by the sort key and the label.
	table.sort(groups, function(a, b)
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		if a.key ~= b.key then
			return a.key < b.key
		end
		if a.label_key ~= b.label_key then
			return a.label_key < b.label_key
		end
		return a.rid < b.rid
	end)
	return groups, #items, by_rid
end

-- What a scene folder says after its arrow: the target, with the way out
-- for an unmapped group (#469 S1).
local function target_text(target)
	if target.text == "(unmapped)" then
		return "(unmapped; Set Room Mapping first)"
	end
	return target.text
end

-- The scene folder rows: "Kitchen → Kitchen: 5 scenes" (#469 S1; "Kitchen:
-- 5 scenes" without group_target), selectable in Add From Hue only when the
-- group has a room to go to: picking an unmapped one would be refused (P1).
local function scene_folders(groups, selectable)
	local list = {}
	for _, g in ipairs(groups) do
		local count = util.plural(#g.items, "scene")
		local text = g.target and string.format("%s → %s: %s", g.label, target_text(g.target), count)
			or string.format("%s: %s", g.label, count)
		list[#list + 1] = folder(text, "f:scenes:" .. g.rid,
			selectable and g.rid ~= NO_GROUP and (g.target == nil or g.target.room_id ~= nil))
	end
	return list
end

local function scenes_text(count, groups)
	return string.format("Scenes (%d in %s)", count, util.plural(#groups, "room"))
end

-- The folder value of the labelled row back to the top (actions.TOP): the
-- list functions read it as the top itself (key_of).
actions.TOP = "f:top"

-- The labelled Back row a folder's list starts with (§4 finding 14):
-- Composer's own "Back" link is a short word that only a double-click on its
-- text opens, so the row says where it goes and is a folder of that value
-- (folders open on a double-click, §2.3). "Back to Scenes" from a room's
-- scenes, "Back to all folders" from a top folder.
local function back_row(back)
	local kind = FOLDER_KIND[back]
	if kind then
		return folder("Back to " .. KINDS[kind].add, back)
	end
	return folder("Back to all folders", actions.TOP)
end

-- Runs a list builder with module failures noted; a failure of the whole
-- builder answers one row instead of raising into Composer. A list inside a
-- folder (a `back`) starts with its labelled Back row, and `back` still goes
-- to Composer for its own Back link.
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
	if type(back) == "string" then
		table.insert(list, 1, back_row(back))
	end
	return list, back
end

local function key_of(folder_value)
	if type(folder_value) ~= "string" or folder_value == actions.TOP then
		return ""
	end
	return folder_value
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
		-- The All row names where they go (#469 S1); an unmapped folder has
		-- none and only lists its scenes (picking one is refused with P1).
		local list, target = {}, group.target
		if g ~= NO_GROUP and not target then
			list[1] = row(string.format("All scenes of %s not in Control4 yet", group.label), key)
		elseif g ~= NO_GROUP and target.room_id then
			list[1] = row(string.format("All %s of %s into %s", util.plural(#group.items, "scene"), group.noun,
				target.text), key)
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
			s.log.debug("actions: Add From Hue has no folder %s; the top instead", logged(key))
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

-- Suggestions (bridge/owner.lua's suggested(), §3.2 and §3.4; any module
-- may have one): a list of { device_id, rid, text?, why? } (`text` the Hue
-- thing, `why` the reason) or a map device_id -> rid or -> { rid, text, why }.
-- Returns the list sorted by device id, and the same items by device id.
function actions:suggestions()
	local out, by_device = {}, {}
	for _, key in ipairs(OWNERS) do
		local list = self:call(key, "suggested")
		if type(list) == "table" then
			local function take(device_id, item)
				local id, rid, text, why = tonumber(device_id), nil, nil, nil
				if type(item) == "string" then
					rid = item
				elseif type(item) == "table" then
					id = id or tonumber(item.device_id or item.device)
					rid = item.rid or item.to or item.new_rid
					text = str(item.text or item.label)
					why = str(item.why)
				end
				rid = str(rid)
				if id and rid and not by_device[id] then
					local s = { device_id = id, rid = rid, text = text, why = why, kind = key }
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

-- What a device's row in Link Device adds for its suggestion: the Hue thing
-- and the reason, never the device again (the row names it; §4 finding 5):
-- " → Lamp 5 [Bedroom] #9 (suggested: same name in the same Hue room)".
local function suggestion_suffix(s)
	if not s then
		return ""
	end
	if not s.text then
		return " (has a suggested match)"
	end
	local why = s.why and (": " .. util.sanitise(s.why)) or ""
	return " → " .. util.sanitise(s.text) .. " (suggested" .. why .. ")"
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

-- The Control4 room each device sits in, { [device_id] = room name }: one
-- GetDevices lookup, by scenes:device_rooms ({ [id] = { id, name } }), else
-- through the scenes module's project calls (bridge/project.lua,
-- pcall-wrapped there). Empty when the lookup fails or answers nothing:
-- unknown names no room (#469 S2).
function actions:device_rooms(ids)
	local out = {}
	if #ids == 0 then
		return out
	end
	local m = self:mod("scenes")
	if m and type(m.device_rooms) == "function" then
		-- Not self:call: a failed lookup only names no room, it is no listing problem.
		local ok, rooms = pcall(m.device_rooms, m, ids)
		if not ok then
			self.log.warn("actions: scenes:device_rooms failed: %s", tostring(rooms))
		end
		for id, room in pairs(ok and type(rooms) == "table" and rooms or {}) do
			local name = type(room) == "table" and room.name or room
			if tonumber(id) and type(name) == "string" and name ~= "" then
				out[tonumber(id)] = util.sanitise(name)
			end
		end
		return out
	end
	local p = m and m.project
	if type(p) ~= "table" or type(p.call) ~= "function" then
		return out
	end
	local ok, answered, raw = pcall(p.call, p, "devices", { DeviceIds = table.concat(ids, ",") })
	if not ok or not answered or type(raw) ~= "table" then
		return out
	end
	local rooms
	for id, info in pairs(raw) do
		local device_id = tonumber(id)
		if device_id and type(info) == "table" then
			local name = util.display_name(info.roomName)
			local room_id = tonumber(info.roomId)
			if name == "" and room_id then
				if rooms == nil then
					local got_rooms, list = pcall(p.rooms, p)
					rooms = got_rooms and type(list) == "table" and list or {}
				end
				name = rooms[room_id] and tostring(rooms[room_id]) or ""
			end
			if name ~= "" then
				out[device_id] = util.sanitise(name)
			end
		end
	end
	return out
end

-- " in Den" after the device's number in a row ("Kitchen: Concentrate
-- (device 1241 in Den, gone since 10-21)"); the row as it is when it names
-- no such device.
local function with_room(text, id, room)
	local key = "(device " .. tostring(id)
	local s, e = text:find(key, 1, true)
	while s do
		if not text:sub(e + 1, e + 1):match("%d") then
			return text:sub(1, e) .. " in " .. room .. text:sub(e + 1)
		end
		s, e = text:find(key, e + 1, true)
	end
	return text
end

-- Link Device's scene device rows name the device's Control4 room, so the
-- dealer can pick a folder under To that goes there (#469 S2): one lookup
-- for the whole list, when it is shown.
function actions:scene_rooms(list)
	local ids = {}
	for _, e in ipairs(list) do
		local id = id_of(e.value)
		if id then
			ids[#ids + 1] = tostring(id)
		end
	end
	local rooms = self:device_rooms(ids)
	for _, e in ipairs(list) do
		local id = id_of(e.value)
		if id and rooms[id] then
			e.text = with_room(e.text, id, rooms[id])
		end
	end
	return list
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
		-- The scene rows are shown in their folder, or at the top when they
		-- are the only kind: only then are their rooms looked up.
		local filled, scenes = 0, nil
		for _, k in ipairs(kinds) do
			if #k.list > 0 then
				filled = filled + 1
			end
			if k.key == "scenes" then
				scenes = k
			end
		end
		if scenes and #scenes.list > 0 and (kind == "scenes" or (key == "" and filled == 1)) then
			s:scene_rooms(scenes.list)
		end
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

-- "All scenes of <group>" (its selectable folder or its All row): every new
-- scene of the group into the room it maps to, by add_all_of_group, which
-- judges an explicit Room itself (scenes:placement, #469 F2, P1 to P4): the
-- mapped room is accepted, another is refused naming both, a group with no
-- room of its own is refused naming Set Room Mapping. Without group_target
-- (an older scenes module) an explicit Room is refused as before.
function actions:add_group(group, room_id, say)
	if group == NO_GROUP or not self:has("scenes", "add_all_of_group") then
		return say("Not added: open this folder and pick one scene")
	end
	if room_id and not self:group_target(group) then
		return say("Not added: the scenes of a room or zone go into the room it maps to; set Room to (mapped room)")
	end
	return self:mod("scenes"):add_all_of_group(group, room_id, done_to(say, "Scenes added"))
end

function actions:run_add(params, say)
	say = self:say(say)
	self:guard("Add From Hue", say, function()
		if not self:can() then
			return
		end
		local what = selection(params, "What")
		self.log.info("actions: Add From Hue What=%s Room=%s", logged(what), logged(selection(params, "Room")))
		if not what then
			return say("Not added: pick a light, zone, scene or motion sensor under What first")
		end
		local room_id, refusal = room_of(selection(params, "Room"))
		if room_id == false then
			return say(refusal)
		end
		local bulk = what == "all:lights" and { "lights", "import_new", "lights" }
			or what == "all:motion" and { "motion", "import_new", "motion sensors" } or nil
		if bulk and room_id then
			return say(string.format("Not added: all new %s go each into the room its Hue room maps to; set Room to "
				.. "(mapped room), or pick one", bulk[3]))
		end
		if bulk then
			if not self:has(bulk[1], bulk[2]) then
				return not_ready("added", bulk[1], say)
			end
			return self:mod(bulk[1]):import_new(done_to(say, "Import finished"))
		end
		local group = what:match("^f:scenes:(.+)$")
		if group then
			return self:add_group(group, room_id, say)
		end
		local kind = FOLDER_KIND[what]
		if kind then
			return say(string.format("Not added: %s is a folder; open it and pick one inside", KINDS[kind].add))
		end
		local prefix, rid = what:match("^(%a+):(.+)$")
		local route = prefix and ADD[prefix]
		if not route then
			return say(string.format('Not added: "%s" is not something Add From Hue offers; open What again', echo(what)))
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
		self.log.info("actions: Link Device Device=%s To=%s", logged(device), logged(to))
		if not device then
			return say("Not linked: pick a device under Device first")
		end
		if device == "dev:suggested" then
			return self:link_all(to, say)
		end
		local id = id_of(device)
		if not id then
			return say(string.format('Not linked: "%s" is not a device Link Device offers; open Device again', echo(device)))
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
				return say(string.format('Not linked: "%s" is not something Link Device offers; open To again', echo(to)))
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

function actions:run_forget(params, say)
	say = self:say(say)
	self:guard("Forget Device", say, function()
		if not self:can() then
			return
		end
		local device = selection(params, "Device")
		self.log.info("actions: Forget Device Device=%s Confirm=%s", logged(device), logged(selection(params,
			"Confirm")))
		if not device then
			return say("Not forgotten: pick a device under Device first")
		end
		if selection(params, "Confirm") ~= actions.CONFIRM_YES then
			return say(actions.NOT_CONFIRMED)
		end
		local id = id_of(device)
		if not id then
			return say(string.format('Not forgotten: "%s" is not a device Forget Device offers; open Device again',
				echo(device)))
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
		self.log.info("actions: Resolve Names Names=%s", logged(value))
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

function actions:run_diagnostics(params, say)
	say = self:say(say)
	self:guard("Diagnostics", say, function()
		local value = selection(params, "What")
		self.log.info("actions: Diagnostics What=%s", logged(value))
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
			return say(string.format('Nothing run: "%s" is not a diagnostic of this build', echo(value)))
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

return actions
