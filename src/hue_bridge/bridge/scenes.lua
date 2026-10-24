-- The Hue scenes a bridge represents as Control4 switches (hue_scene.c4z, one
-- light_v2 switch per scene): the catalogue of the bridge's scenes, the scene
-- registry (bridge.registry under its own keys), the flows that keep the scene
-- drivers current (resync, stream items, hello), the recall and off commands,
-- and the owner-facing actions, texts and pickers of docs/scenes-design.md §4.
-- It mirrors bridge/lights.lua shape for shape (docs/import-design.md §1 rules,
-- §3 states, §5 reconciliation) with "scene" in place of "light".
--
-- Every C4 call goes through ctx so the module runs on plain tables in specs;
-- each ctx field defaults to the real call, as lights.lua does, so the driver
-- only has to supply `http`, `lights` and `group_off`. The project calls
-- (ctx.project.*) are pcall-wrapped: a failed lookup reads as "unknown".
--
-- What this module never does (§1 of the contract): create a device from an
-- event, an import or a resync (Hue keeps about seven default scenes per
-- room), remove or move a device, rename one without a click. A scene deleted
-- in Hue keeps its device as "gone"; Re-link Scene and Forget Scene are the
-- exits, exactly as for lights.
--
-- The catalogue is compact: hue_model.scene() drops `actions` and `palette`
-- at decode time, so 125 scenes are 125 small tables [assumed: the 351 KB
-- decode is fine on the controller; docs/design.md measured about a second].
--
-- Callback rules inherited from lights.lua: the GETs run serially, chained
-- from http.request callbacks; on_container runs inside OnBodyChunk and only
-- sends messages; every callback body is pcall-wrapped.
--
-- Persistence: the registry's mutators change memory only; this module marks
-- itself dirty and saves once per batch, except during device creation, where
-- it saves after every AddDevice.

local log = require("common.log")
local hue_model = require("bridge.hue_model")
local registry = require("bridge.registry")
local groups = require("bridge.groups")
local lights = require("bridge.lights")   -- ids_from / dump only: the AddDevice callback shapes

local scenes = {}
scenes.__index = scenes

scenes.SCENES_KEY = "hue_scenes"
scenes.TOMBSTONES_KEY = "hue_scene_tombstones"
scenes.SCENE_DRIVER = "hue_scene.c4z"
scenes.BINDING = 1
scenes.BINDING_CLASS = "HUE_BRIDGE"
scenes.MAX_NAMED = 3
scenes.SCENE_PATH = "/clip/v2/resource/scene"
scenes.SMART_SCENE_PATH = "/clip/v2/resource/smart_scene"
scenes.GROUPED_LIGHT_PATH = "/clip/v2/resource/grouped_light"
-- HUE_SCENE_DIM duration bounds (ms) and the default when none is given (the
-- scene device's default hold rate).
scenes.DIM_MAX_DURATION = 6000000
scenes.DIM_DEFAULT_DURATION = 5000

-- recall.action values [community: openhue/aiohue; `active` verified on hardware].
scenes.ACTIONS = { active = true, static = true, dynamic_palette = true }
-- status.active values [verified: hardware 2026-10-21].
scenes.ACTIVE = { inactive = true, static = true, dynamic_palette = true }

-- ctx fields (all but http optional; lights and group_off should be given):
--   http(req, cb)            req = { path, method, body }; the driver adds ip and key; cb(result)
--   send(id, cmd, params)    C4:SendToDevice(id, cmd, params)
--   add_device(driver, room_id, name, cb)   C4:AddDevice; cb(device_id, info)
--   bind(bridge_id, device_id)              C4:Bind(bridge_id, 1, device_id, 1, "HUE_BRIDGE")
--   persist_get / persist_set               C4:PersistGetValue / SetValue
--   bridge_id                number; default C4:GetDeviceID()
--   now, log                 os.time / common.log look-alikes
--   project                  the project calls of docs/import-design.md §13 (defaults as lights.lua)
--   lights                   the bridge.lights instance: its live `groups` cache, `reg:room_mapping()`,
--                            `groups_loaded`
--   group_off(grouped_light_rid)   the coalesced grouped_light off of driver.lua (§5)
--   group_dim(grouped_light_rid, body)   the coalesced grouped_light dimming_delta PUT of driver.lua
--                            (docs/keypad-design.md "Scene hold-to-dim"); true when queued
function scenes.new(ctx)
	ctx = ctx or {}
	assert(type(ctx.http) == "function", "scenes.new: ctx.http is required")
	ctx.send = ctx.send or function(id, command, params)
		C4:SendToDevice(id, command, params)
	end
	ctx.add_device = ctx.add_device or function(driver, room_id, name, cb)
		C4:AddDevice(driver, room_id, name, cb)
	end
	ctx.bind = ctx.bind or function(bridge_id, device_id)
		C4:Bind(bridge_id, scenes.BINDING, device_id, scenes.BINDING, scenes.BINDING_CLASS)
	end
	ctx.persist_get = ctx.persist_get or function(name)
		return C4:PersistGetValue(name)
	end
	ctx.persist_set = ctx.persist_set or function(name, value)
		C4:PersistSetValue(name, value)
	end
	ctx.log = ctx.log or log
	ctx.now = ctx.now or os.time
	ctx.group_off = ctx.group_off or function(grouped_light_rid)
		ctx.log.warn("scenes: no group_off in ctx; grouped_light %s not turned off", tostring(grouped_light_rid))
		return false
	end
	ctx.group_dim = ctx.group_dim or function(grouped_light_rid)
		ctx.log.warn("scenes: no group_dim in ctx; grouped_light %s not dimmed", tostring(grouped_light_rid))
		return false
	end
	ctx.project = ctx.project or {}
	local project = ctx.project
	-- [verified: hardware, docs/design.md "Project APIs"] for every shape below.
	project.rooms = project.rooms or function()
		return C4:GetDevicesByC4iName("roomdevice.c4i")
	end
	project.hierarchy = project.hierarchy or function()
		return C4:GetProjectHierarchy()
	end
	project.devices = project.devices or function(filter)
		return C4:GetDevices(filter)
	end
	project.bound = project.bound or function()
		return C4:GetBoundConsumerDevices(C4:GetDeviceID(), scenes.BINDING)
	end
	project.unbind = project.unbind or function(device_id)
		C4:Unbind(device_id, scenes.BINDING)
	end
	project.rename = project.rename or function(id, name)
		C4:RenameDevice(id, name)
	end
	project.display_name = project.display_name or function(id)
		return C4:GetDeviceDisplayName(id)
	end

	local reg = registry.new({
		persist_get = ctx.persist_get, persist_set = ctx.persist_set, now = ctx.now, log = ctx.log,
		keys = { lights = scenes.SCENES_KEY, tombstones = scenes.TOMBSTONES_KEY, rooms = false },
	})
	return setmetatable({
		ctx = ctx,
		reg = reg,
		registry = reg:entries(),  -- rid → entry, the live table (identity kept across load())
		catalogue = {},            -- rid → hue_model.scene() record, from the last GET and the stream (memory only)
		smart_scenes = nil,        -- smart scene count from the last GET, nil until known (log only, v1)
		group_on = {},             -- grouped_light rid → on (boolean) from the last GET and the stream; absent = unknown
		group_level = {},          -- grouped_light rid → dimming.brightness (average of the lights on), when reported
		last_configure = {},       -- rid → signature of the last HUE_SCENE_CONFIGURE sent
		announced = {},            -- device_id → { rid, name } from HUE_SCENE_HELLO, for Link Devices
		conflicts = {},            -- rid → { holder = device_id, claimant = device_id }
		early_hellos = {},         -- hellos received before load(), answered after configure_all()
		loaded = false,
		synced = false,            -- a full GET /scene has succeeded (missing means something)
		dirty = false,
		configured_once = false,
		adding = false,            -- Add Scene / Add All Scenes Of Room running
		resyncing = false,
		resync_pending = nil,
		device_info_logged = false,
	}, scenes)
end

-- Helpers ------------------------------------------------------------------

function scenes:bridge_id()
	return self.ctx.bridge_id or C4:GetDeviceID()
end

function scenes:protect(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		self.ctx.log.error("scenes: %s failed: %s", what, tostring(err))
	end
	return ok, err
end

local function positive(value)
	local n = tonumber(value)
	if n and n > 0 then
		return n
	end
	return nil
end

-- Name order, case-insensitive, ties by rid.
local function by_name(a, b)
	local an, bn = string.lower(tostring(a.name or "")), string.lower(tostring(b.name or ""))
	if an ~= bn then
		return an < bn
	end
	return tostring(a.rid) < tostring(b.rid)
end

local function norm(name)
	return (tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")):lower()
end

-- CUSTOM_SELECT lists are comma-delimited [verified: FUND 12.3].
local function sanitise(text)
	return (tostring(text):gsub(",", " "))
end

local function date_of(ts)
	if not ts then
		return "?"
	end
	return os.date("%Y-%m-%d", ts)
end

local function short_date_of(ts)
	if not ts then
		return "?"
	end
	return os.date("%m-%d", ts)
end

local function plural(n, word)
	return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

local function some(names)
	if #names <= scenes.MAX_NAMED then
		return table.concat(names, ", ")
	end
	local head = {}
	for i = 1, scenes.MAX_NAMED do
		head[i] = names[i]
	end
	return table.concat(head, ", ") .. string.format(" +%d more", #names - scenes.MAX_NAMED)
end

local function signature(params)
	local keys = {}
	for k in pairs(params) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = k .. "=" .. tostring(params[k])
	end
	return table.concat(parts, "\n")
end

local function has_field(fields, name)
	for _, field in ipairs(fields or {}) do
		if field == name then
			return true
		end
	end
	return false
end

-- Display label of a group from its raw name and type: "Kitchen",
-- "Downstairs (zone)", "(all lights)", "(no room)" (same wording as groups:label).
local function label_of(name, gtype)
	if gtype == "bridge_home" then
		return "(all lights)"
	elseif name == nil then
		return "(no room)"
	elseif gtype == "zone" then
		return tostring(name) .. " (zone)"
	end
	return tostring(name)
end

-- Registry access ---------------------------------------------------------------

function scenes:load()
	self.reg:load()
	for rid, entry in pairs(self.registry) do
		entry.auto_dynamic = entry.auto_dynamic == true or entry.auto_dynamic == "true"
		self.ctx.log.debug("scenes: loaded %s (device %s, %s)", tostring(entry.name), tostring(entry.device_id),
			tostring(rid))
	end
	self.loaded = true
	self.dirty = false
	return self.registry
end

function scenes:mark()
	self.dirty = true
end

function scenes:flush()
	if self.dirty then
		self.dirty = false
		self.reg:save()
	end
end

function scenes:save()
	self.dirty = false
	self.reg:save()
end

function scenes:device_for(rid)
	local entry = rid ~= nil and self.registry[rid] or nil
	return entry and entry.device_id or nil
end

function scenes:proxy_for(rid)
	local entry = rid ~= nil and self.registry[rid] or nil
	return entry and entry.proxy_id or nil
end

-- A copy of the registry entry, or nil.
function scenes:entry(rid)
	local entry = rid ~= nil and self.registry[rid] or nil
	if not entry then
		return nil
	end
	local out = {}
	for k, v in pairs(entry) do
		out[k] = v
	end
	return out
end

function scenes:rid_for(device_id)
	return (self.reg:by_device(device_id))
end

function scenes:count()
	local n = 0
	for _ in pairs(self.registry) do
		n = n + 1
	end
	return n
end

-- Scenes seen on the bridge (the catalogue).
function scenes:bridge_count()
	local n = 0
	for _ in pairs(self.catalogue) do
		n = n + 1
	end
	return n
end

function scenes:registered_rids()
	return self.reg:rids()
end

-- The catalogue record for a rid, or nil.
function scenes:scene(rid)
	if rid == nil then
		return nil
	end
	return self.catalogue[rid]
end

-- Project access ----------------------------------------------------------------

function scenes:project_call(name, ...)
	local ok, result = pcall(self.ctx.project[name], ...)
	if not ok then
		self.ctx.log.warn("scenes: project.%s failed: %s", name, tostring(result))
		return false, nil
	end
	return true, result
end

-- { [room_id] = name } with numeric ids; empty when unknown.
function scenes:project_rooms()
	local _, raw = self:project_call("rooms")
	local out = {}
	if type(raw) == "table" then
		for id, name in pairs(raw) do
			local n = tonumber(id)
			if n and name ~= nil then
				out[n] = tostring(name)
			end
		end
	end
	return out
end

-- { [device_id] = true } of everything bound to the bridge's binding 1 (lights
-- and scenes alike); nil when the lookup failed.
function scenes:project_bound_set()
	local ok, raw = self:project_call("bound")
	if not ok then
		return nil
	end
	local out = {}
	if type(raw) == "table" then
		for id in pairs(raw) do
			out[tonumber(id) or id] = true
		end
	end
	return out
end

-- The hue_scene devices in the project as { [device_id] = info }, or nil when
-- the call failed or returned nothing: unknown, never "deleted" (§5).
function scenes:project_scenes()
	local ok, raw = self:project_call("devices", { C4iNames = scenes.SCENE_DRIVER })
	if not ok or type(raw) ~= "table" or next(raw) == nil then
		return nil
	end
	local out = {}
	for id, info in pairs(raw) do
		out[tonumber(id) or id] = info
	end
	return out
end

function scenes:display_name(id)
	if not id then
		return nil
	end
	local ok, name = self:project_call("display_name", id)
	if ok and name ~= nil and name ~= "" then
		return tostring(name)
	end
	return nil
end

-- Groups (through the lights' live cache) -------------------------------------------

-- The lights' group cache, read live: lights.lua replaces it at every resync.
function scenes:groups()
	local l = self.ctx.lights
	if l and l.groups then
		return l.groups
	end
	self.empty_groups = self.empty_groups or groups.new()
	return self.empty_groups
end

function scenes:groups_loaded()
	local l = self.ctx.lights
	return (l and l.groups_loaded) == true
end

function scenes:room_mapping(group_rid)
	local l = self.ctx.lights
	if group_rid and l and l.reg then
		return l.reg:room_mapping(group_rid)
	end
	return nil
end

-- Raw name and type of a group: the cache first, else what `fallback` (an
-- entry or a catalogue record) remembers. The third value says whether the
-- cache had it.
function scenes:group_info(group_rid, fallback)
	local group = self:groups():group(group_rid)
	if group then
		return group.name, group.type, true
	end
	if fallback then
		return fallback.group_name, fallback.group_type, false
	end
	return nil, nil, false
end

-- The group's plain name ("Kitchen", "Downstairs"): what HUE_SCENE_CONFIGURE
-- carries as group_name next to group_type; the scene device adds the
-- "(zone)" itself [verified: a label here showed as "… (zone) (zone)"].
function scenes:group_name(group_rid, fallback)
	local name = self:group_info(group_rid, fallback)
	return name
end

-- The label for owner-facing texts: marked "(deleted in Hue)" once this run
-- has fetched the groups and the cache lacks it (lights.lua's rule).
function scenes:group_label(group_rid, fallback)
	local name, gtype, cached = self:group_info(group_rid, fallback)
	local label = label_of(name, gtype)
	if not cached and name ~= nil and self:groups_loaded() then
		label = label .. " (deleted in Hue)"
	end
	return label
end

-- Labels ---------------------------------------------------------------------

-- "Kitchen: Relax" for a catalogue record; " (dynamic)" when asked.
function scenes:scene_label(scene, with_dynamic)
	local text = sanitise(self:group_label(scene.group_rid, scene)) .. ": " .. sanitise(scene.name or "?")
	if with_dynamic and scene.auto_dynamic then
		text = text .. " (dynamic)"
	end
	return text
end

-- The bare scene name of an entry: what the contract's texts use.
function scenes.entry_label(_self, _rid, entry)
	return sanitise(entry.name or "?")
end

-- Composer name at creation (§1): "<Scene>" for a room scene, "<Zone> <Scene>"
-- for a zone scene. `record` is a catalogue record or an entry.
function scenes:creation_name(record)
	local name, gtype = self:group_info(record.group_rid, record)
	if gtype == "zone" and name ~= nil and name ~= "" then
		return tostring(name) .. " " .. tostring(record.name or "?")
	end
	return tostring(record.name or "?")
end

-- The registry fields a catalogue record supplies.
function scenes:fields_from_scene(scene)
	if not scene then
		return {}
	end
	local name, gtype = self:group_info(scene.group_rid, scene)
	return {
		name = scene.name,
		group_rid = scene.group_rid,
		group_type = gtype or scene.group_type,
		group_name = name,
		id_v1 = scene.id_v1,
		auto_dynamic = scene.auto_dynamic == true,
	}
end

-- Catalogue views -----------------------------------------------------------------

-- Catalogue records without a registry entry, sorted by group label then name.
function scenes:unimported_scenes()
	local list = {}
	for rid, scene in pairs(self.catalogue) do
		if not self.registry[rid] then
			list[#list + 1] = scene
		end
	end
	table.sort(list, function(a, b)
		local ag, bg = self:group_label(a.group_rid, a):lower(), self:group_label(b.group_rid, b):lower()
		if ag ~= bg then
			return ag < bg
		end
		return by_name(a, b)
	end)
	return list
end

function scenes:is_tombstoned(rid)
	return self.reg:tombstones()[rid] ~= nil
end

-- The catalogue records of one group, name order.
function scenes:scenes_of_group(group_rid)
	local list = {}
	for _, scene in pairs(self.catalogue) do
		if scene.group_rid == group_rid then
			list[#list + 1] = scene
		end
	end
	table.sort(list, by_name)
	return list
end

-- The Control4 room a scene goes to when the owner names none: its group's
-- mapping. Returns room_id, room_name or nil, reason.
function scenes:default_room(scene, rooms)
	local group_rid = scene.group_rid
	local _, gtype = self:group_info(group_rid, scene)
	if not group_rid or gtype == "bridge_home" then
		return nil, "not in a Hue room"
	end
	local label = self:group_label(group_rid, scene)
	local mapping = self:room_mapping(group_rid)
	if not mapping or not mapping.c4_room_id then
		return nil, "Hue room " .. label .. " not mapped"
	end
	local name = rooms[mapping.c4_room_id]
	if not name then
		if next(rooms) == nil then
			return mapping.c4_room_id, mapping.c4_room_name or ("room " .. tostring(mapping.c4_room_id))
		end
		return nil, "Hue room " .. label .. " mapped to a Control4 room that no longer exists"
	end
	return mapping.c4_room_id, name
end

-- Fetching and absorbing -------------------------------------------------------------

-- GET /scene, then /smart_scene for its count, then /grouped_light for the
-- groups' on/off (HUE_SCENE_GROUP). done({ scene = items, smart = n | nil,
-- grouped_light = items | nil }) or done(nil, err) when the scene GET failed;
-- a failed smart scene GET only costs the count (v1 lists nothing from it), a
-- failed grouped_light GET only leaves the groups' on/off unknown.
function scenes:fetch_all(done)
	self.ctx.http({ path = scenes.SCENE_PATH, method = "GET" }, function(r)
		self:protect("fetch scene", function()
			if not r.ok then
				return done(nil, string.format("GET %s: %s", scenes.SCENE_PATH, tostring(r.err)))
			end
			local items = type(r.json) == "table" and r.json.data or nil
			if type(items) ~= "table" then
				return done(nil, string.format("GET %s: malformed response", scenes.SCENE_PATH))
			end
			self.ctx.http({ path = scenes.SMART_SCENE_PATH, method = "GET" }, function(r2)
				self:protect("fetch smart_scene", function()
					local smart = nil
					local list = r2.ok and type(r2.json) == "table" and r2.json.data or nil
					if type(list) == "table" then
						if type(hue_model.smart_scene_count) == "function" then
							smart = hue_model.smart_scene_count(list)
						else
							smart = #list
						end
					else
						self.ctx.log.warn("scenes: GET %s: %s; smart scenes not counted", scenes.SMART_SCENE_PATH,
							tostring(r2.err or "malformed response"))
					end
					self.ctx.http({ path = scenes.GROUPED_LIGHT_PATH, method = "GET" }, function(r3)
						self:protect("fetch grouped_light", function()
							local gl = r3.ok and type(r3.json) == "table" and r3.json.data or nil
							if type(gl) ~= "table" then
								gl = nil
								self.ctx.log.warn("scenes: GET %s: %s; group on/off unknown", scenes.GROUPED_LIGHT_PATH,
									tostring(r3.err or "malformed response"))
							end
							done({ scene = items, smart = smart, grouped_light = gl })
						end)
					end)
				end)
			end)
		end)
	end)
end

-- Replace the catalogue with a fetch result and refresh the registry's
-- cached identity fields. The GET is authoritative for status too.
function scenes:absorb(res)
	local catalogue = {}
	for _, item in ipairs(res.scene or {}) do
		if type(item) == "table" and item.id ~= nil then
			local scene = hue_model.scene(item)
			if scene then
				catalogue[scene.rid] = scene
			end
		end
	end
	self.catalogue = catalogue
	if res.smart ~= nil then
		self.smart_scenes = res.smart
	end
	local group_on, group_level = {}, {}
	for _, item in ipairs(res.grouped_light or {}) do
		if type(item) == "table" and item.id ~= nil and type(item.on) == "table" and type(item.on.on) == "boolean" then
			group_on[item.id] = item.on.on
		end
		if type(item) == "table" and item.id ~= nil and type(item.dimming) == "table"
			and type(item.dimming.brightness) == "number" then
			group_level[item.id] = item.dimming.brightness
		end
	end
	self.group_on = group_on
	self.group_level = group_level
	self.ctx.log.debug("scenes: %d scenes cached, %s smart scenes (not listed in v1)", self:bridge_count(),
		tostring(self.smart_scenes or "?"))
	self:refresh_registry()
end

-- The entry's cached name follows Hue's; the Composer device keeps its own.
function scenes:take_name(entry, scene)
	if entry.name == scene.name then
		return false
	end
	self.ctx.log.info("scenes: %s was renamed to %s in Hue (Composer name unchanged)", tostring(entry.name),
		tostring(scene.name))
	entry.name = scene.name
	return true
end

-- The identity fields of one entry from its catalogue record. True when
-- something changed (the caller marks).
function scenes:refresh_entry(rid)
	local entry, scene = self.registry[rid], self.catalogue[rid]
	if not entry or not scene then
		return false
	end
	local changed = self:take_name(entry, scene)
	local fields = self:fields_from_scene(scene)
	fields.name = nil
	local delta = {}
	for k, v in pairs(fields) do
		if entry[k] ~= v then
			delta[k] = v
		end
	end
	if next(delta) then
		self.reg:update(rid, delta)
		changed = true
	end
	return changed
end

function scenes:refresh_registry()
	for _, rid in ipairs(self.reg:rids()) do
		if self:refresh_entry(rid) then
			self:mark()
		end
	end
end

-- The group names cached on the entries follow the lights' group cache (a
-- room renamed in Hue). Returns the rids whose name changed; with `tell`,
-- those devices hear a new HUE_SCENE_CONFIGURE and the count is returned too.
function scenes:refresh_group_names(tell)
	local changed, told = {}, 0
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		local group = self:groups():group(entry.group_rid)
		if group and (entry.group_name ~= group.name or entry.group_type ~= group.type) then
			self.reg:update(rid, { group_name = group.name, group_type = group.type })
			self:mark()
			changed[#changed + 1] = rid
			if tell and entry.state ~= "unbound" and self:send_configure(rid) then
				told = told + 1
			end
		end
	end
	return changed, told
end

-- Messages -----------------------------------------------------------------

-- HUE_SCENE_CONFIGURE params (§2): rid, name, group_name, group_type, id_v1?,
-- auto_dynamic, state, gone_since?. Every value a non-empty string
-- (hue_model drops nil and "", as C4:SendToDevice would).
function scenes:configure_params(rid, entry)
	local extra = {
		group_name = self:group_name(entry.group_rid, entry),
		group_type = entry.group_type,
		state = entry.state == "gone" and "gone" or "linked",
	}
	if entry.state == "gone" then
		extra.gone_since = entry.gone_since
	end
	return hue_model.scene_configure_params({
		rid = rid, name = entry.name, id_v1 = entry.id_v1, auto_dynamic = entry.auto_dynamic == true,
	}, extra)
end

-- HUE_SCENE_STATE params (§2). The bridge always names a status: a scene
-- whose status it does not know (not on the bridge) reads as inactive.
function scenes.state_params(_self, rid, active, reason)
	return hue_model.scene_state_params({ rid = rid, active = scenes.ACTIVE[active] and active or "inactive" }, reason)
end

-- The status the bridge last reported for a registered scene: the catalogue's,
-- "inactive" for a scene that is not on the bridge.
function scenes:current_active(rid)
	local scene = self.catalogue[rid]
	return scene and scene.active or "inactive"
end

function scenes:send_configure(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	local params = self:configure_params(rid, entry)
	self.last_configure[rid] = signature(params)
	self.ctx.send(entry.device_id, "HUE_SCENE_CONFIGURE", params)
	return true
end

function scenes:configure_changed(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	return self.last_configure[rid] ~= signature(self:configure_params(rid, entry))
end

-- HUE_SCENE_STATE with the given status (default: the current one).
function scenes:send_state(rid, reason, active)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	self.ctx.send(entry.device_id, "HUE_SCENE_STATE", self:state_params(rid, active or self:current_active(rid), reason))
	return true
end

-- Group on/off and other scenes (docs/keypad-design.md "Scene hold-to-dim") -----

-- The group a registered scene belongs to: the catalogue's, else the entry's.
function scenes:group_rid_of(rid)
	local scene, entry = self.catalogue[rid], self.registry[rid]
	return (scene and scene.group_rid) or (entry and entry.group_rid) or nil
end

-- The grouped_light rid of a group, from the lights' live group cache; nil
-- for an unknown group or one without a grouped_light (an empty zone).
function scenes:grouped_light_of(group_rid)
	if group_rid == nil then
		return nil
	end
	local group = self:groups():group(group_rid)
	return group and group.grouped_light_rid or nil
end

-- HUE_SCENE_GROUP { rid, on } to one registered scene's device.
function scenes:send_group_on(rid, on)
	local entry = self.registry[rid]
	if not entry or entry.state ~= "linked" then
		return false
	end
	self.ctx.send(entry.device_id, "HUE_SCENE_GROUP", { rid = rid, on = on and "true" or "false" })
	return true
end

-- Every linked scene whose group owns grouped_light `grouped_rid` hears its
-- on/off. Returns the number of messages sent.
function scenes:send_group_on_for(grouped_rid)
	local on = self.group_on[grouped_rid]
	if on == nil then
		return 0
	end
	local sent = 0
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		if entry.state == "linked" and self:grouped_light_of(self:group_rid_of(rid)) == grouped_rid
			and self:send_group_on(rid, on) then
			sent = sent + 1
		end
	end
	return sent
end

-- After a resync: every linked scene whose group's on/off is known hears it.
function scenes:send_group_on_all()
	local sent = 0
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		if entry.state == "linked" then
			local grouped = self:grouped_light_of(self:group_rid_of(rid))
			local on = grouped and self.group_on[grouped]
			if on ~= nil and self:send_group_on(rid, on) then
				sent = sent + 1
			end
		end
	end
	return sent
end

-- A grouped_light's on/off from the stream: the scenes of its group hear a
-- change only. Returns the number of messages sent.
function scenes:set_group_on(grouped_rid, on)
	if self.group_on[grouped_rid] == on then
		return 0
	end
	self.group_on[grouped_rid] = on
	return self:send_group_on_for(grouped_rid)
end

-- Scene `rid` became active (static / dynamic_palette): every other linked
-- scene of its group hears HUE_SCENE_GROUP other_active. `rid` need not be
-- imported (a scene recalled from the Hue app). Returns the number sent.
function scenes:send_other_active(rid)
	local group_rid = self:group_rid_of(rid)
	if group_rid == nil then
		return 0
	end
	local sent = 0
	for _, other in ipairs(self.reg:rids()) do
		local entry = self.registry[other]
		if other ~= rid and entry.state == "linked" and self:group_rid_of(other) == group_rid then
			self.ctx.send(entry.device_id, "HUE_SCENE_GROUP", { rid = other, other_active = "true" })
			sent = sent + 1
		end
	end
	return sent
end

-- CONFIGURE (when asked for, or when it changed) then STATE. The state is
-- sent only once a GET has told us something (or the catalogue has the
-- scene): before that a guessed "inactive" would flip a lit scene's switch.
function scenes:push(rid, reason, with_configure)
	if not self.registry[rid] then
		return false
	end
	if with_configure or self:configure_changed(rid) then
		self:send_configure(rid)
	end
	if not (self.synced or self.catalogue[rid]) then
		return false
	end
	return self:send_state(rid, reason)
end

-- A scene that left the bridge: CONFIGURE with state "gone", STATE inactive.
function scenes:announce_gone(rid, reason)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	self:send_configure(rid)
	self:send_state(rid, reason or "event", "inactive")
	return true
end

-- Bridge startup, before any GET: CONFIGURE to every registered, bound scene
-- from the persisted entry, then the hellos that waited for load().
function scenes:configure_all()
	local n = 0
	for _, rid in ipairs(self.reg:rids()) do
		if self.registry[rid].state ~= "unbound" and self:send_configure(rid) then
			n = n + 1
		end
	end
	self.configured_once = true
	local queued = self.early_hellos
	self.early_hellos = {}
	for _, h in ipairs(queued) do
		self:protect("early hello", self.hello, self, h.rid, h.params)
	end
	return n
end

function scenes:clear_conflicts_for(device_id)
	for rid, c in pairs(self.conflicts) do
		if c.holder == device_id or c.claimant == device_id then
			self.conflicts[rid] = nil
		end
	end
end

-- Configuration and (once something is known) the status.
function scenes:answer_hello(rid)
	if self.synced or self.catalogue[rid] then
		return self:push(rid, "hello", true)
	end
	return self:send_configure(rid)
end

-- Register a bound device for a rid the registry lacks (auto-adopt, Link
-- Devices). Returns the entry or nil.
function scenes:adopt(device_id, rid, hello, how)
	local scene = self.catalogue[rid]
	local fields = self:fields_from_scene(scene)
	fields.device_id = device_id
	fields.name = fields.name or hello.name
	local entry, err = self.reg:add(rid, fields)
	if not entry then
		self.ctx.log.warn("scenes: could not adopt device %d for %s: %s", device_id, tostring(rid), tostring(err))
		return nil
	end
	self:mark()
	if not scene and self.synced then
		self.reg:set_state(rid, "gone")
	end
	self.ctx.log.always("scenes: adopted %s (device %d) %s", tostring(entry.name or rid), device_id, how)
	return entry
end

-- HUE_SCENE_HELLO { rid?, device_id, name? }: the same rules as lights:hello
-- (§4 of import-design). Returns true when answered.
function scenes:hello(rid, params)
	params = params or {}
	if type(rid) ~= "string" or rid == "" then
		rid = nil
	end
	local device_id = positive(params.device_id)
	if not (self.loaded or self.synced) then
		if rid or device_id then
			self.early_hellos[#self.early_hellos + 1] = { rid = rid, params = params }
		end
		return false
	end
	if device_id then
		self.announced[device_id] = { rid = rid, name = params.name }
	end

	local entry = rid and self.registry[rid] or nil
	if entry then
		if device_id and entry.device_id ~= device_id then
			self.conflicts[rid] = { holder = entry.device_id, claimant = device_id }
			self.ctx.log.warn("scenes: device %d claims %s, which device %d holds; nothing changed (see Attention)",
				device_id, self:entry_label(rid, entry), entry.device_id)
			return false
		end
		return self:answer_hello(rid)
	end
	if not device_id then
		return false
	end
	local held_rid = self.reg:by_device(device_id)
	if held_rid then
		self.ctx.log.info("scenes: device %d said hello with %s; its registered scene is %s", device_id, tostring(rid),
			held_rid)
		return self:answer_hello(held_rid)
	end
	if not rid then
		return false  -- a bare device: Link Devices matches it by name
	end

	local bound = self:project_bound_set()
	if not bound or not bound[device_id] then
		self.ctx.log.info("scenes: device %d announced %s but is not bound; not adopted", device_id, rid)
		return false
	end
	for other_id, h in pairs(self.announced) do
		if other_id ~= device_id and h.rid == rid then
			self.conflicts[rid] = { holder = other_id, claimant = device_id }
			self.ctx.log.warn("scenes: devices %d and %d both announce %s; neither adopted (see Attention)", other_id,
				device_id, rid)
			return false
		end
	end
	if not self:adopt(device_id, rid, params, "from its own persisted rid") then
		return false
	end
	self:flush()
	return self:answer_hello(rid)
end

-- HUE_SCENE_GOODBYE { rid?, device_id }: the device is being deleted in
-- Composer; the entry becomes a tombstone. Returns the tombstone or nil.
function scenes:goodbye(params)
	params = params or {}
	local device_id = positive(params.device_id)
	local rid = device_id and self.reg:by_device(device_id) or nil
	if not rid and type(params.rid) == "string" and self.registry[params.rid] then
		local entry = self.registry[params.rid]
		if not device_id or entry.device_id == device_id then
			rid = params.rid
		end
	end
	if device_id then
		self.announced[device_id] = nil
	end
	if not rid then
		self.ctx.log.debug("scenes: HUE_SCENE_GOODBYE from an unregistered device (%s, %s)", tostring(params.device_id),
			tostring(params.rid))
		return nil
	end
	local entry = self.registry[rid]
	local label = self:entry_label(rid, entry)
	local tomb = self.reg:tombstone(rid)
	self.last_configure[rid] = nil
	self.conflicts[rid] = nil
	self:clear_conflicts_for(entry.device_id)
	self:mark()
	self:flush()
	self.ctx.log.always("scenes: %s (device %d) was deleted in Composer; Add Scene lists it as deleted, "
		.. "Add All Scenes Of Room skips it", label, entry.device_id)
	return tomb
end

-- OnBindingChanged for the bridge's binding 1, as lights:on_binding_changed.
function scenes:on_binding_changed(binding, class, bound, other_id)
	if tonumber(binding) ~= scenes.BINDING then
		return false
	end
	if class ~= nil and class ~= scenes.BINDING_CLASS then
		return false
	end
	local device_id = positive(other_id)
	if not device_id then
		return false
	end
	local rid, entry = self.reg:by_device(device_id)
	if not rid then
		return false  -- a light, or a scene device its hello or Link Devices adopts
	end
	local changed = false
	if bound == false or bound == "false" then
		if entry.state == "linked" and self.reg:set_state(rid, "unbound") then
			changed = true
			self.ctx.log.warn("scenes: %s (device %d) was unbound from the bridge", self:entry_label(rid, entry), device_id)
		end
	elseif bound == true or bound == "true" then
		if entry.state == "unbound" and self.reg:set_state(rid, "linked") then
			changed = true
			self.ctx.log.info("scenes: %s (device %d) is bound again", self:entry_label(rid, entry), device_id)
			self:answer_hello(rid)
		end
	end
	if changed then
		self:mark()
		self:flush()
	end
	return changed
end

-- Reconciliation (§5) ------------------------------------------------------------

-- Step 1, the project side: the bound set and the hue_scene devices in the
-- project. Saves unless `no_save`.
function scenes:reconcile(no_save)
	local bound = self:project_bound_set()
	if not bound then
		self.ctx.log.warn("scenes: reconcile skipped: the bound-device lookup failed")
		return { unbound = {}, relinked = {}, tombstoned = {} }
	end
	local infos = self:project_scenes()
	local present = nil
	if infos then
		present = {}
		for id in pairs(infos) do
			present[id] = true
		end
	end
	local r = self.reg:reconcile({ bound = bound, present = present })
	if #r.unbound + #r.relinked + #r.tombstoned > 0 then
		self:mark()
	end
	for _, rid in ipairs(r.tombstoned) do
		local tomb = self.reg:tombstones()[rid] or {}
		self.last_configure[rid] = nil
		self.conflicts[rid] = nil
		self.ctx.log.warn("scenes: %s was deleted in Composer while the bridge was not watching; Add Scene lists it "
			.. "as deleted", tostring(tomb.name or rid))
	end
	for _, rid in ipairs(r.unbound) do
		local entry = self.registry[rid]
		self.ctx.log.warn("scenes: %s (device %d) is not bound to this bridge", self:entry_label(rid, entry),
			entry.device_id)
	end
	for _, rid in ipairs(r.relinked) do
		self:answer_hello(rid)
	end
	if not no_save then
		self:flush()
	end
	return r
end

-- Step 2, the scenes: a registered rid absent from /scene is "gone" (the
-- device hears state gone and STATE inactive); back again is "linked". New
-- unimported scenes are counted at debug only: nothing is ever created from
-- a resync and Hue's default scenes would make a nag meaningless.
function scenes:reconcile_scenes()
	for _, rid in ipairs(self.reg:rids()) do
		local entry, scene = self.registry[rid], self.catalogue[rid]
		if scene then
			if entry.state == "gone" and self.reg:set_state(rid, "linked") then
				self:mark()
				self.ctx.log.always("scenes: %s (device %d) is back on the bridge", self:entry_label(rid, entry),
					entry.device_id)
			end
		elseif entry.state == "linked" and self.reg:set_state(rid, "gone") then
			self:mark()
			self.ctx.log.warn("scenes: %s (device %d) is no longer on the bridge; marked gone (Re-link Scene or Forget Scene)",
				self:entry_label(rid, entry), entry.device_id)
			self:announce_gone(rid, "resync")
		end
	end
	self.ctx.log.debug("scenes: %d scenes on the bridge not imported", #self:unimported_scenes())
end

-- Step 5, the fan-out: STATE (and CONFIGURE first when asked or changed) to
-- every linked entry (§4: "STATE for every linked scene"); a gone one hears
-- only a changed CONFIGURE, its inactive went out when it became gone (and
-- goes out again on its hello).
function scenes:fanout(reason, with_configure)
	local sent = 0
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		if entry.state == "linked" then
			if self:push(rid, reason, with_configure) then
				sent = sent + 1
			end
		elseif entry.state == "gone" and (with_configure or self:configure_changed(rid)) then
			self:send_configure(rid)
		end
	end
	self.configured_once = true
	return sent
end

-- After a fetch has been absorbed: steps 1, 2 and 5, one save.
function scenes:settle(reason, with_configure)
	self.synced = true
	self:reconcile(true)
	self:reconcile_scenes()
	self:refresh_group_names(false)
	local sent = self:fanout(reason, with_configure)
	self:send_group_on_all()
	self:flush()
	return sent
end

-- Resync ---------------------------------------------------------------------

-- After every stream connect (the coordinator runs it after lights:resync so
-- the group cache is fresh) and from Refresh Scenes. done(ok, err, sent).
function scenes:resync(done)
	done = done or function() end
	self:expire_stale_busy()
	if self.resyncing or self.adding then
		self.resync_pending = done
		return
	end
	self.resyncing, self.resyncing_since = true, os.time()
	self:fetch_all(function(res, err)
		local sent = 0
		local ok, e = true, nil
		if res then
			ok, e = pcall(function()
				self:absorb(res)
				sent = self:settle("resync", not self.configured_once)
			end)
			if not ok then
				self.ctx.log.error("scenes: resync failed: %s", tostring(e))
			end
		end
		self.resyncing = false
		if not res then
			self:protect("resync done", done, false, err)
		elseif not ok then
			self:protect("resync done", done, false, tostring(e))
		else
			self:protect("resync done", done, true, nil, sent)
		end
		self:run_pending_resync()
	end)
end

function scenes:run_pending_resync()
	local pending = self.resync_pending
	self.resync_pending = nil
	if pending then
		self:resync(pending)
	end
end

-- Event fan-out --------------------------------------------------------------

-- A scene item of an event container. Returns the number of messages sent.
function scenes:on_scene_item(item, kind)
	local rid = item.id
	local entry, scene = self.registry[rid], self.catalogue[rid]
	if kind == "add" then
		local fresh = hue_model.scene(item)
		if not fresh then
			return 0
		end
		self.catalogue[rid] = fresh
		if entry then
			if entry.state == "gone" and self.reg:set_state(rid, "linked") then
				self:mark()
				self.ctx.log.always("scenes: %s (device %d) is back on the bridge", self:entry_label(rid, entry),
					entry.device_id)
			end
			if self:refresh_entry(rid) then
				self:mark()
			end
			if entry.state == "unbound" then
				return 0
			end
			return self:push(rid, "event", true) and 1 or 0
		end
		self.ctx.log.debug("scenes: new scene %s on the bridge; Add Scene lists it", self:scene_label(fresh))
		return 0
	elseif kind == "delete" then
		self.catalogue[rid] = nil
		if entry and entry.state == "linked" then
			if self.reg:set_state(rid, "gone") then
				self:mark()
			end
			self.ctx.log.warn("scenes: %s (device %d) was deleted on the bridge; marked gone (Re-link Scene or Forget Scene)",
				self:entry_label(rid, entry), entry.device_id)
			return self:announce_gone(rid, "event") and 1 or 0
		end
		if not entry then
			self.ctx.log.debug("scenes: unimported scene %s was deleted on the bridge", tostring(rid))
		end
		return 0
	end
	if not scene then
		return 0  -- an update for a scene the resync has not brought yet
	end
	local changed = hue_model.update_scene(scene, item)
	local sent = 0
	if has_field(changed, "active") and (scene.active == "static" or scene.active == "dynamic_palette") then
		sent = sent + self:send_other_active(rid)
	end
	if not entry then
		return sent
	end
	if has_field(changed, "name") or has_field(changed, "group_rid") or has_field(changed, "auto_dynamic") then
		if self:refresh_entry(rid) then
			self:mark()
		end
	end
	if entry.state == "unbound" then
		return sent
	end
	if self:configure_changed(rid) and self:send_configure(rid) then
		sent = sent + 1
	end
	if has_field(changed, "active") and self:send_state(rid, "event") then
		sent = sent + 1
	end
	return sent
end

-- One event-stream container. Scene items are handled; a grouped_light item
-- carrying on.on updates the group's on/off (HUE_SCENE_GROUP on a change); a
-- room/zone item means the lights' group cache may have changed
-- (lights:on_container runs first), so the entries' group names are
-- refreshed. Runs inside OnBodyChunk: no transfers are started here.
function scenes:on_container(container)
	if type(container) ~= "table" or type(container.data) ~= "table" then
		return 0
	end
	local sent, groups_changed = 0, false
	local kind = container.type
	for _, item in ipairs(container.data) do
		if type(item) == "table" and item.id ~= nil then
			if item.type == "scene" then
				sent = sent + self:on_scene_item(item, kind)
			elseif item.type == "grouped_light" then
				if kind == "delete" then
					self.group_on[item.id] = nil
					self.group_level[item.id] = nil
				else
					if type(item.dimming) == "table" and type(item.dimming.brightness) == "number" then
						self.group_level[item.id] = item.dimming.brightness
					end
					if type(item.on) == "table" and type(item.on.on) == "boolean" then
						sent = sent + self:set_group_on(item.id, item.on.on)
					end
				end
			elseif item.type == "room" or item.type == "zone" or item.type == "bridge_home" then
				groups_changed = true
			end
		end
	end
	if groups_changed then
		local _, told = self:refresh_group_names(true)
		sent = sent + told
	end
	self:flush()
	return sent
end

-- Commands from the scene devices -------------------------------------------------

-- The entry a device's command names, by rid. nil, reason when unknown.
function scenes:entry_for_command(params, what)
	params = params or {}
	local rid = params.rid
	if type(rid) ~= "string" or rid == "" then
		self.ctx.log.warn("scenes: %s without a rid ignored", what)
		return nil
	end
	local entry = self.registry[rid]
	if not entry then
		self.ctx.log.warn("scenes: %s for unregistered scene %s ignored", what, rid)
		return nil
	end
	return rid, entry
end

-- HUE_SCENE_RECALL { rid, action?, duration?, brightness? }: PUT the recall
-- (a brightness 1-100 overrides the scene's as recall.dimming); on success
-- STATE with the state the action produces (reason "recall") so the switch
-- settles even if the stream item is missed; on failure a warning and STATE
-- with the cached status. Returns true when a PUT was started.
function scenes:recall(params)
	params = params or {}
	local rid, entry = self:entry_for_command(params, "HUE_SCENE_RECALL")
	if not rid then
		return false
	end
	if entry.state == "gone" then
		self.ctx.log.warn("scenes: recall of %s (device %d) ignored: scene deleted in Hue since %s (Re-link Scene or "
			.. "Forget Scene)", self:entry_label(rid, entry), entry.device_id, date_of(entry.gone_since))
		self:send_state(rid, "recall", "inactive")
		return false
	end
	local action = params.action
	if not scenes.ACTIONS[action] then
		if action ~= nil and action ~= "" then
			self.ctx.log.warn("scenes: unknown recall action %s for %s; using active", tostring(action),
				self:entry_label(rid, entry))
		end
		action = "active"
	end
	local body = { recall = { action = action } }
	local duration = positive(params.duration)
	if duration then
		body.recall.duration = math.floor(duration)   -- [assumed: recall.duration in ms; confirm once on hardware]
	end
	local brightness = tonumber(params.brightness)
	if brightness and brightness >= 1 and brightness <= 100 then
		body.recall.dimming = { brightness = brightness }
	elseif params.brightness ~= nil and params.brightness ~= "" then
		self.ctx.log.warn("scenes: recall brightness %s for %s out of range (1-100); ignored", tostring(params.brightness),
			self:entry_label(rid, entry))
	end
	local scene = self.catalogue[rid]
	-- A later recall or OFF of the same scene supersedes this one: its
	-- callback must not report a state the owner has since changed [code
	-- analysis 2026-10-22, F3].
	local gen = self:next_recall_gen(rid)
	self.ctx.log.info("scenes: recall %s as %s%s (device %d)", self:entry_label(rid, entry), action,
		body.recall.dimming and (" at " .. tostring(body.recall.dimming.brightness) .. "%") or "", entry.device_id)
	self.ctx.http({ path = scenes.SCENE_PATH .. "/" .. rid, method = "PUT", body = body }, function(r)
		self:protect("recall done", function()
			local current = self.registry[rid]
			if not current or current.device_id ~= entry.device_id or current.state ~= "linked" then
				return  -- re-linked, forgotten or gone while the PUT was in flight
			end
			if self.recall_gen[rid] ~= gen then
				return  -- superseded; the later command reports the state
			end
			if r.ok then
				local resulting = action
				if action == "active" then
					resulting = (scene and scene.auto_dynamic) and "dynamic_palette" or "static"
				end
				if scene then
					scene.active = resulting
				end
				self:send_state(rid, "recall", resulting)
				return
			end
			local why
			if r.code == 404 then
				why = "HTTP 404 (scene gone?)"
			elseif r.code then
				why = "HTTP " .. tostring(r.code)
			else
				why = tostring(r.err)
			end
			self.ctx.log.warn("scenes: %s (device %d): Recall failed: %s", self:entry_label(rid, entry), entry.device_id, why)
			self:send_state(rid, "recall")
		end)
	end)
	return true
end

-- HUE_SCENE_OFF { rid }: the scene's group grouped_light off through
-- ctx.group_off (coalesced per group by the driver), then STATE inactive. A
-- group without a grouped_light (an empty zone), an unknown group or a gone
-- scene report inactive without a call. Returns true when group_off was called.
function scenes:off(params)
	params = params or {}
	local rid, entry = self:entry_for_command(params, "HUE_SCENE_OFF")
	if not rid then
		return false
	end
	self:next_recall_gen(rid)
	local scene = self.catalogue[rid]
	local called = false
	if entry.state == "gone" or not scene then
		self.ctx.log.info("scenes: off for %s (device %d): scene not on the bridge; reporting inactive",
			self:entry_label(rid, entry), entry.device_id)
	else
		local group = self:groups():group(scene.group_rid)
		local grouped = group and group.grouped_light_rid or nil
		if grouped then
			self.ctx.log.info("scenes: off for %s (device %d): grouped_light %s off", self:entry_label(rid, entry),
				entry.device_id, tostring(grouped):sub(1, 8))
			if not self.ctx.group_off(grouped) then
				-- Nothing queued (not paired): the scene stays as it is and the
				-- device hears the truth [code analysis 2026-10-22, F4].
				self.ctx.log.warn("scenes: off for %s (device %d): nothing queued; state unchanged",
					self:entry_label(rid, entry), entry.device_id)
				self:send_state(rid, "recall")
				return false
			end
			called = true
		else
			self.ctx.log.info("scenes: off for %s (device %d): its group has no grouped_light; reporting inactive",
				self:entry_label(rid, entry), entry.device_id)
		end
		scene.active = "inactive"
	end
	self:send_state(rid, "recall", "inactive")
	return called
end

-- HUE_SCENE_DIM { rid, device_id, direction = up | down | stop, duration? }:
-- one relative dimming_delta on the scene's group grouped_light through
-- ctx.group_dim (coalesced per group by the driver), so the scene's colours
-- and per-light differences are kept. up/down run 0 -> 100 % over `duration`
-- ms (clamped to 0..DIM_MAX_DURATION, default DIM_DEFAULT_DURATION), stop
-- ends it [assumed: `stop` and `dynamics` on grouped_light; verify on the
-- first hardware test]. No STATE is sent. Returns true when queued.
function scenes:dim(params)
	params = params or {}
	local rid, entry = self:entry_for_command(params, "HUE_SCENE_DIM")
	if not rid then
		return false
	end
	local direction = params.direction
	if direction ~= "up" and direction ~= "down" and direction ~= "stop" then
		self.ctx.log.warn("scenes: dim of %s (device %d) ignored: unknown direction %s", self:entry_label(rid, entry),
			entry.device_id, tostring(direction))
		return false
	end
	local scene = self.catalogue[rid]
	if entry.state == "gone" or not scene then
		self.ctx.log.warn("scenes: dim of %s (device %d) ignored: scene not on the bridge", self:entry_label(rid, entry),
			entry.device_id)
		return false
	end
	local grouped = self:grouped_light_of(scene.group_rid)
	if not grouped then
		self.ctx.log.warn("scenes: dim of %s (device %d) ignored: its group has no grouped_light",
			self:entry_label(rid, entry), entry.device_id)
		return false
	end
	local body
	if direction == "stop" then
		body = { dimming_delta = { action = "stop" } }
	else
		local duration = tonumber(params.duration)
		if not duration or duration ~= duration then
			duration = scenes.DIM_DEFAULT_DURATION
		end
		duration = math.floor(math.max(0, math.min(scenes.DIM_MAX_DURATION, duration)))
		body = { dimming_delta = { action = direction, brightness_delta = 100 }, dynamics = { duration = duration } }
	end
	self.ctx.log.info("scenes: dim %s %s (device %d): grouped_light %s", self:entry_label(rid, entry), direction,
		entry.device_id, tostring(grouped):sub(1, 8))
	if self.ctx.group_dim(grouped, body) ~= true then
		self.ctx.log.warn("scenes: dim of %s (device %d): nothing queued", self:entry_label(rid, entry), entry.device_id)
		return false
	end
	return true
end

-- Device creation ---------------------------------------------------------------

-- A guard whose callback never came back would read Busy for ever and park
-- every resync [code analysis 2026-10-22, F1]: it expires instead.
local BUSY_MAX = 90

function scenes:expire_stale_busy()
	for _, flag in ipairs({ "adding", "resyncing" }) do
		local since = self[flag .. "_since"]
		if self[flag] and since and os.time() - since > BUSY_MAX then
			self.ctx.log.warn("scenes: %s stuck for %d s; cleared", flag, os.time() - since)
			self[flag] = false
		end
	end
end

-- Per-rid generation of the latest recall or off; a callback compares.
function scenes:next_recall_gen(rid)
	self.recall_gen = self.recall_gen or {}
	self.recall_gen[rid] = (self.recall_gen[rid] or 0) + 1
	return self.recall_gen[rid]
end

function scenes:busy_text()
	self:expire_stale_busy()
	if self.adding then
		return "Busy: adding scenes; try again in a moment"
	elseif self.resyncing then
		return "Busy: resyncing scenes; try again in a moment"
	end
	return nil
end

-- One AddDevice per job, one at a time, each bound, registered (saved at
-- once) and told its configuration and state. jobs = { { scene, room_id,
-- room_name } ... }; finish(created, failed, err) as lights:create_lights.
function scenes:create_scenes(jobs, finish)
	local total, i, created, failed = #jobs, 0, {}, {}
	local add_next

	local function on_added(job, device_id, info)
		local scene = job.scene
		if not self.device_info_logged then
			self.device_info_logged = true
			self.ctx.log.always("AddDevice callback for scene %s: deviceId=%s info=%s", tostring(scene.name),
				tostring(device_id), lights.dump(info))
		end
		device_id = tonumber(device_id)
		if not device_id or device_id <= 0 then
			self.ctx.log.error("scenes: AddDevice failed for %s (deviceId %s); skipped", tostring(scene.name),
				tostring(device_id))
			failed[#failed + 1] = scene
			return
		end
		local ids = lights.ids_from(info)
		if ids.protocol and ids.protocol ~= device_id then
			self.ctx.log.always("AddDevice for %s: binding protocol id %d rather than deviceId %d", tostring(scene.name),
				ids.protocol, device_id)
			device_id = ids.protocol
		end
		self.ctx.bind(self:bridge_id(), device_id)
		local fields = self:fields_from_scene(scene)
		fields.device_id = device_id
		fields.proxy_id = ids.proxy
		fields.created_room_id = job.room_id
		local entry, err = self.reg:add(scene.rid, fields)
		if not entry then
			self.ctx.log.error("scenes: AddDevice created device %d for %s but the registry refused it: %s", device_id,
				tostring(scene.name), tostring(err))
			failed[#failed + 1] = scene
			return
		end
		self:save()
		created[#created + 1] = { scene = scene, device_id = device_id, room_name = job.room_name }
		self.ctx.log.info("scenes: added %s to %s (device %d, %d of %d)", tostring(scene.name), tostring(job.room_name),
			device_id, i, total)
		self:push(scene.rid, "resync", true)
	end

	local function step()
		local ok, err = pcall(add_next)
		if not ok then
			self.ctx.log.error("scenes: adding scenes failed: %s", tostring(err))
			finish(created, failed, tostring(err))
		end
	end

	add_next = function()
		i = i + 1
		local job = jobs[i]
		if not job then
			return finish(created, failed)
		end
		local name = self:creation_name(job.scene)
		self.ctx.log.info("scenes: adding %s to %s (%d of %d)", tostring(name), tostring(job.room_name), i, total)
		self.ctx.add_device(scenes.SCENE_DRIVER, job.room_id, name, function(device_id, info)
			self:protect("register " .. tostring(name), on_added, job, device_id, info)
			step()
		end)
	end

	step()
end

-- Actions (§4) -------------------------------------------------------------------

-- Resolve the room an add goes to. Returns room_id, room_name or nil, text.
function scenes:room_for_add(scene, room_id, rooms)
	room_id = positive(room_id)
	if room_id then
		local room_name = rooms[room_id]
		if room_name then
			return room_id, room_name
		end
		if next(rooms) ~= nil then
			return nil, string.format("Not added: Control4 room %d no longer exists", room_id)
		end
		return room_id, "room " .. tostring(room_id)
	end
	local id, why = self:default_room(scene, rooms)
	if not id then
		return nil, string.format("Not added: %s: %s; pick a room, or Set Room Mapping first", sanitise(scene.name or "?"),
			why)
	end
	return id, why
end

-- Add Scene: one AddDevice into room_id, or into the mapped room of the
-- scene's group when nil; refuses when neither exists. A tombstone for the
-- rid is cleared by the registry. done(ok, text).
function scenes:add_scene(rid, room_id, done)
	done = done or function() end
	local busy = self:busy_text()
	if busy then
		done(false, busy)
		return false
	end
	if type(rid) ~= "string" or rid == "" then
		done(false, "Not added: pick a scene first")
		return false
	end
	local entry = self.registry[rid]
	if entry then
		done(false, string.format("Not added: %s is already imported (device %d)", self:entry_label(rid, entry),
			entry.device_id))
		return false
	end
	local scene = self.catalogue[rid]
	if not scene then
		done(false, string.format("Not added: scene %s is not on the bridge (Refresh Scenes and try again)", tostring(rid)))
		return false
	end
	local room_name
	room_id, room_name = self:room_for_add(scene, room_id, self:project_rooms())
	if not room_id then
		done(false, room_name)
		return false
	end

	self.adding, self.adding_since = true, os.time()
	local label = sanitise(scene.name or "?")
	self:create_scenes({ { scene = scene, room_id = room_id, room_name = room_name } }, function(created, _, err)
		self.adding = false
		self:reconcile(true)
		self:flush()
		local text
		if created[1] then
			text = string.format("Added %s to %s (device %d)", label, room_name, created[1].device_id)
		elseif err then
			text = "Not added: " .. err
		else
			text = string.format("Not added: AddDevice failed for %s (see the Lua output)", label)
		end
		self.ctx.log.always("scenes: %s", text)
		self:protect("add_scene done", done, created[1] ~= nil, text)
		self:run_pending_resync()
	end)
	return true
end

-- Add All Scenes Of Room: every unimported, non-tombstoned scene of the
-- group into its mapped room, one AddDevice at a time; tombstoned ones are
-- listed. No GET first: the catalogue follows the stream (Refresh Scenes
-- exists for doubt). done(ok, text) once, at the end.
function scenes:add_all_of_group(group_rid, done)
	done = done or function() end
	local busy = self:busy_text()
	if busy then
		done(false, busy)
		return false
	end
	if type(group_rid) ~= "string" or group_rid == "" then
		done(false, "Not added: pick a Hue room first")
		return false
	end
	local group = self:groups():group(group_rid)
	if not group then
		done(false, string.format("Not added: Hue room %s is not on the bridge (connect the event stream and try again)",
			tostring(group_rid)))
		return false
	end
	local label = sanitise(self:group_label(group_rid))
	local all = self:scenes_of_group(group_rid)
	if #all == 0 then
		done(false, string.format("Not added: %s has no scenes", label))
		return false
	end
	local rooms = self:project_rooms()
	local room_id, why = self:default_room(all[1], rooms)
	if not room_id then
		done(false, string.format("Not added: %s; Set Room Mapping first", why))
		return false
	end
	local room_name = why
	local jobs, deleted, imported = {}, {}, 0
	for _, scene in ipairs(all) do
		if self.registry[scene.rid] then
			imported = imported + 1
		elseif self:is_tombstoned(scene.rid) then
			local tomb = self.reg:tombstones()[scene.rid]
			deleted[#deleted + 1] = string.format("%s (deleted %s)", sanitise(scene.name or "?"), date_of(tomb.deleted_at))
		else
			jobs[#jobs + 1] = { scene = scene, room_id = room_id, room_name = room_name }
		end
	end

	local function summary(created, failed, err)
		local parts = {}
		if #created > 0 then
			local names = {}
			for _, c in ipairs(created) do
				names[#names + 1] = string.format("%s (device %d)", sanitise(c.scene.name or "?"), c.device_id)
			end
			parts[#parts + 1] = string.format("Added %s of %s to %s: %s", plural(#created, "scene"), label, room_name,
				table.concat(names, ", "))
		elseif #jobs == 0 and #deleted == 0 then
			parts[#parts + 1] = string.format("No new scenes in %s (%d on bridge, %d imported)", label, #all, imported)
		else
			parts[#parts + 1] = "Added no scenes"
		end
		if #failed > 0 then
			local names = {}
			for _, scene in ipairs(failed) do
				names[#names + 1] = sanitise(scene.name or "?")
			end
			parts[#parts + 1] = string.format("AddDevice failed for %d: %s", #failed, table.concat(names, ", "))
		end
		if err then
			parts[#parts + 1] = "stopped early: " .. err
		end
		if #deleted > 0 then
			parts[#parts + 1] = string.format("skipped %d deleted in Composer (Add Scene re-creates one): %s", #deleted,
				table.concat(deleted, ", "))
		end
		return table.concat(parts, "; ")
	end

	self.adding, self.adding_since = true, os.time()
	self:create_scenes(jobs, function(created, failed, err)
		self.adding = false
		self:reconcile(true)
		self:flush()
		local text = summary(created, failed, err)
		self.ctx.log.always("scenes: %s", text)
		self:protect("add_all_of_group done", done, err == nil and #failed == 0, text)
		self:run_pending_resync()
	end)
	return true
end

-- Re-link Scene: the entry keeps its device, proxy, programming and name and
-- swaps the rid; the device hears its new configuration and state. ok, text.
function scenes:relink(device_id, new_rid)
	local busy = self:busy_text()
	if busy then
		return false, busy
	end
	device_id = positive(device_id)
	if not device_id or type(new_rid) ~= "string" or new_rid == "" then
		return false, "Not re-linked: pick a device and a scene"
	end
	local old_rid, entry = self.reg:by_device(device_id)
	if not old_rid then
		return false, string.format("Not re-linked: device %d is not a registered scene", device_id)
	end
	local holder = self.registry[new_rid]
	if holder then
		if holder.device_id == device_id then
			return false, string.format("Not re-linked: device %d is already linked to %s", device_id,
				self:entry_label(new_rid, holder))
		end
		return false, string.format("Not re-linked: %s is already linked to device %d", self:entry_label(new_rid, holder),
			holder.device_id)
	end
	local scene = self.catalogue[new_rid]
	if not scene then
		return false, string.format("Not re-linked: scene %s is not on the bridge (Refresh Scenes and try again)",
			tostring(new_rid))
	end
	local old_label = self:entry_label(old_rid, entry)
	local fields = self:fields_from_scene(scene)
	fields.name_dismissed = registry.CLEAR
	local relinked, err = self.reg:relink(old_rid, new_rid, fields)
	if not relinked then
		return false, "Not re-linked: " .. tostring(err)
	end
	self:mark()
	self.last_configure[old_rid] = nil
	self.conflicts[old_rid], self.conflicts[new_rid] = nil, nil
	self:clear_conflicts_for(device_id)
	self:push(new_rid, "resync", true)
	self:flush()
	local text = string.format("Re-linked device %d (was %s) to %s", device_id, old_label, self:scene_label(scene))
	self.ctx.log.always("scenes: %s", text)
	return true, text
end

-- The unimported scenes whose Hue name or creation name matches one of `names`.
function scenes:match_unimported_by_name(names)
	local wanted = {}
	for _, name in ipairs(names) do
		if name ~= nil and norm(name) ~= "" then
			wanted[norm(name)] = true
		end
	end
	local out = {}
	for _, scene in ipairs(self:unimported_scenes()) do
		if wanted[norm(scene.name)] or wanted[norm(self:creation_name(scene))] then
			out[#out + 1] = scene
		end
	end
	return out
end

-- Link Devices (scenes): every bound hue_scene device the registry lacks is
-- adopted by the rid it announced, else by an exact, unique name match
-- (Composer name or announced name) against the unimported scenes. Only
-- hue_scene devices count: the bound set also holds the lights, so it is cut
-- down to the project's hue_scene devices, or to the devices that said
-- HUE_SCENE_HELLO when the project lookup is unavailable. Returns the text.
function scenes:link_devices()
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local bound = self:project_bound_set()
	if not bound then
		return "Not linked: the bound-device lookup failed (see the Lua output)"
	end
	local present = self:project_scenes()
	local ids, total = {}, 0
	for id in pairs(bound) do
		local n = positive(id)
		local mine = n and ((present and present[n] ~= nil) or (not present and self.announced[n] ~= nil))
		if mine then
			total = total + 1
			if not self.reg:by_device(n) then
				ids[#ids + 1] = n
			end
		end
	end
	table.sort(ids)
	if #ids == 0 then
		if total == 0 then
			return "No scene devices are bound to this bridge"
		end
		return string.format("All %d bound scene devices are registered", total)
	end

	local names, shared = {}, {}
	for _, id in ipairs(ids) do
		names[id] = self:display_name(id)
		if names[id] then
			shared[norm(names[id])] = (shared[norm(names[id])] or 0) + 1
		end
	end

	local linked, problems = {}, {}
	for _, id in ipairs(ids) do
		local hello = self.announced[id] or {}
		local composer = names[id] or ("device " .. tostring(id))
		local rid = hello.rid
		local who = string.format("%s (device %d)", composer, id)
		if rid and self.registry[rid] then
			local holder = self.registry[rid]
			self.conflicts[rid] = { holder = holder.device_id, claimant = id }
			problems[#problems + 1] = string.format("%s announces %s, which device %d holds (Forget Scene on one of them)",
				who, self:entry_label(rid, holder), holder.device_id)
		elseif rid then
			local entry = self:adopt(id, rid, hello, "from its own persisted rid (Link Devices)")
			if entry then
				linked[#linked + 1] = string.format("%s to %s by its rid%s", who,
					self.catalogue[rid] and self:scene_label(self.catalogue[rid]) or self:entry_label(rid, entry),
					self.catalogue[rid] and "" or " (not on the bridge: marked gone)")
				self:answer_hello(rid)
			else
				problems[#problems + 1] = string.format("%s: could not register %s (see the Lua output)", who, rid)
			end
		elseif names[id] and shared[norm(names[id])] > 1 then
			problems[#problems + 1] = string.format("%s: %d bound devices share that name; rename one in Composer and run "
				.. "Link Devices again", who, shared[norm(names[id])])
		else
			local matches = self:match_unimported_by_name({ composer, hello.name })
			if #matches == 1 then
				local scene = matches[1]
				local entry = self:adopt(id, scene.rid, hello, "by its name (Link Devices)")
				if entry then
					linked[#linked + 1] = string.format("%s to %s by name", who, self:scene_label(scene))
					self:answer_hello(scene.rid)
				else
					problems[#problems + 1] = string.format("%s: could not register %s (see the Lua output)", who, scene.rid)
				end
			elseif #matches > 1 then
				problems[#problems + 1] = string.format("%s: %d unimported Hue scenes have that name; rename the device in "
					.. "Composer to one Hue scene's exact name and run Link Devices again", who, #matches)
			else
				problems[#problems + 1] = string.format("%s: no unimported Hue scene has that name; rename the device in "
					.. "Composer to the Hue scene's exact name and run Link Devices again", who)
			end
		end
	end
	self:flush()
	local parts = {}
	if #linked > 0 then
		parts[#parts + 1] = string.format("Linked %s: %s", plural(#linked, "scene device"), table.concat(linked, ", "))
	end
	if #problems > 0 then
		parts[#parts + 1] = string.format("not linked %d: %s", #problems, table.concat(problems, "; "))
	end
	local text = table.concat(parts, "; ")
	self.ctx.log.always("scenes: %s", text)
	return text
end

-- Forget Scene: the entry goes, the device is unbound and told
-- HUE_SCENE_FORGOTTEN, and stays in the project for the owner to delete; the
-- scene is listed under Add Scene again. Returns ok, text.
function scenes:forget(device_id)
	local busy = self:busy_text()
	if busy then
		return false, busy
	end
	device_id = positive(device_id)
	if not device_id then
		return false, "Not forgotten: pick a device first"
	end
	local rid, entry = self.reg:by_device(device_id)
	if not rid then
		return false, string.format("Not forgotten: device %d is not a registered scene", device_id)
	end
	local label = self:entry_label(rid, entry)
	self.reg:forget(rid)
	self:mark()
	self.last_configure[rid] = nil
	self.conflicts[rid] = nil
	self:clear_conflicts_for(device_id)
	self.announced[device_id] = nil
	self.ctx.send(device_id, "HUE_SCENE_FORGOTTEN", { rid = rid, name = entry.name })
	local ok, err = self:project_call("unbind", device_id)
	if not ok then
		self.ctx.log.warn("scenes: unbind of device %d failed: %s", device_id, tostring(err))
	end
	self:flush()
	local text = string.format("Forgot %s (device %d): unbound and left in the project for you to delete; "
		.. "the Hue scene is listed under Add Scene again", label, device_id)
	self.ctx.log.always("scenes: %s", text)
	return true, text
end

-- HUE_SCENE_FORGET { rid?, device_id } from a scene device's Forget This
-- Scene action. Returns ok, text.
function scenes:forget_request(params)
	params = params or {}
	local device_id = positive(params.device_id)
	if not device_id and type(params.rid) == "string" and self.registry[params.rid] then
		device_id = self.registry[params.rid].device_id
	end
	if not device_id then
		return false, "Not forgotten: the scene device named no device"
	end
	if not self.reg:by_device(device_id) then
		self.ctx.send(device_id, "HUE_SCENE_FORGOTTEN", { rid = params.rid, name = params.name })
		self.announced[device_id] = nil
		return false, string.format("Not forgotten: device %d is not a registered scene (told it so)", device_id)
	end
	return self:forget(device_id)
end

-- The Composer name a linked scene device should carry: the creation name
-- ("<Zone> <Scene>" for a zone scene), from the live group cache.
function scenes:expected_name(_rid, entry)
	return self:creation_name(entry)
end

-- Linked entries whose Composer name differs from the expected name and
-- whose difference the owner has not accepted: { rid, entry, current, expected }...
function scenes:name_differences()
	local out = {}
	for _, rid in ipairs(self.reg:rids("linked")) do
		local entry = self.registry[rid]
		local expected = self:expected_name(rid, entry)
		if entry.name and entry.name ~= "" and entry.name_dismissed ~= expected then
			local current = self:display_name(entry.proxy_id or entry.device_id)
			if current and current ~= expected then
				out[#out + 1] = { rid = rid, entry = entry, current = current, expected = expected }
			end
		end
	end
	return out
end

-- Adopt Hue Names (scenes): RenameDevice(proxy_id, expected name) for every
-- linked scene device whose Composer name differs. Returns the text.
function scenes:adopt_hue_names()
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local renamed, skipped = {}, {}
	for _, rid in ipairs(self.reg:rids("linked")) do
		local entry = self.registry[rid]
		if entry.name and entry.name ~= "" then
			local expected = self:expected_name(rid, entry)
			local current = self:display_name(entry.proxy_id or entry.device_id)
			if current and current ~= expected then
				if not entry.proxy_id then
					skipped[#skipped + 1] = string.format("%s (device %d): no proxy id known", current, entry.device_id)
				else
					local ok, err = self:project_call("rename", entry.proxy_id, expected)
					if ok then
						renamed[#renamed + 1] = string.format("%s → %s (device %d)", current, expected, entry.device_id)
						if entry.name_dismissed ~= nil then
							self.reg:update(rid, { name_dismissed = registry.CLEAR })
							self:mark()
						end
					else
						skipped[#skipped + 1] = string.format("%s (device %d): rename failed: %s", current, entry.device_id,
							tostring(err))
					end
				end
			end
		end
	end
	self:flush()
	local text
	if #renamed == 0 and #skipped == 0 then
		text = "No Composer names differ from the Hue scene names"
	else
		local parts = {}
		if #renamed > 0 then
			parts[#parts + 1] = string.format("Renamed %s: %s", plural(#renamed, "scene device"), table.concat(renamed, ", "))
		end
		if #skipped > 0 then
			parts[#parts + 1] = string.format("not renamed %d: %s", #skipped, table.concat(skipped, ", "))
		end
		text = table.concat(parts, "; ")
	end
	self.ctx.log.always("scenes: %s", text)
	return text
end

-- Accept Names As They Are (scenes): every current difference is recorded.
function scenes:accept_names()
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local accepted = {}
	for _, d in ipairs(self:name_differences()) do
		self.reg:update(d.rid, { name_dismissed = d.expected })
		self:mark()
		accepted[#accepted + 1] = string.format("%s (Hue: %s)", d.current, d.expected)
	end
	self:flush()
	local text
	if #accepted == 0 then
		text = "No Composer names differ from the Hue scene names"
	else
		text = string.format("Accepted %s: %s", plural(#accepted, "scene name difference"), table.concat(accepted, ", "))
	end
	self.ctx.log.always("scenes: %s", text)
	return text
end

-- Texts ---------------------------------------------------------------------------

-- The Scenes property: "125 on bridge, 3 imported, 0 missing, 0 unbound, 0
-- deleted"; "<n> imported" before the first GET.
function scenes:summary()
	if not self.synced then
		return string.format("%d imported", self:count())
	end
	local c = self.reg:counts()
	return string.format("%d on bridge, %d imported, %d missing, %d unbound, %d deleted", self:bridge_count(),
		self:count(), c.gone, c.unbound, c.tombstones)
end

-- The Attention items (driver.lua joins them after the lights'): missing
-- scenes, unbound scene devices, two devices claiming one scene, name
-- differences (name_differences() is public so the driver can count them
-- together with the lights' instead).
function scenes:attention_items()
	local items = {}

	local gone = self.reg:rids("gone")
	if #gone > 0 then
		local names = {}
		for _, rid in ipairs(gone) do
			local entry = self.registry[rid]
			names[#names + 1] = string.format("%s (device %d, since %s)", self:entry_label(rid, entry), entry.device_id,
				date_of(entry.gone_since))
		end
		items[#items + 1] = string.format("%s missing from the bridge: %s (Re-link Scene or Forget Scene)",
			plural(#gone, "scene"), some(names))
	end

	local unbound = self.reg:rids("unbound")
	if #unbound > 0 then
		local names = {}
		for _, rid in ipairs(unbound) do
			local entry = self.registry[rid]
			names[#names + 1] = string.format("%s (device %d)", self:entry_label(rid, entry), entry.device_id)
		end
		items[#items + 1] = string.format("%s: %s (bind it to this bridge in Composer, or Forget Scene)",
			plural(#unbound, "unbound scene device"), some(names))
	end

	local conflict_rids = {}
	for rid in pairs(self.conflicts) do
		conflict_rids[#conflict_rids + 1] = rid
	end
	table.sort(conflict_rids)
	for _, rid in ipairs(conflict_rids) do
		local c = self.conflicts[rid]
		local entry = self.registry[rid]
		local label = tostring(rid)
		if entry then
			label = self:entry_label(rid, entry)
		elseif self.catalogue[rid] then
			label = self:scene_label(self.catalogue[rid])
		end
		items[#items + 1] = string.format("2 devices claim Hue scene %s: %d and %d (Forget Scene on one of them)", label,
			c.holder, c.claimant)
	end

	local diffs = self:name_differences()
	if #diffs > 0 then
		local names = {}
		for _, d in ipairs(diffs) do
			names[#names + 1] = string.format("%s is %s in Hue", d.current, d.expected)
		end
		items[#items + 1] = string.format("%d Hue scene name%s differ%s from the Composer names: %s "
			.. "(Adopt Hue Names or Accept Names As They Are)", #diffs, #diffs == 1 and "" or "s",
			#diffs == 1 and "s" or "", some(names))
	end

	return items
end

-- The items joined, or "None".
function scenes:attention()
	local items = self:attention_items()
	if #items == 0 then
		return "None"
	end
	return table.concat(items, "; ")
end

-- Pickers (§4): { text, value } arrays, value a string; one explanatory
-- entry with value "" when there is nothing to pick -------------------------------

local function empty_list(text)
	return { { text = text, value = "" } }
end

-- Add Scene / Re-link's Scene: the unimported scenes as "Kitchen: Relax",
-- grouped by group label then name, dynamic ones suffixed, tombstoned last.
function scenes:picker_scenes()
	if not self.synced then
		return empty_list("(no scenes fetched yet; connect the event stream)")
	end
	local plain, deleted = {}, {}
	for _, scene in ipairs(self:unimported_scenes()) do
		local tomb = self.reg:tombstones()[scene.rid]
		if tomb then
			deleted[#deleted + 1] = { text = string.format("%s (deleted from Composer %s)", self:scene_label(scene, true),
				date_of(tomb.deleted_at)), value = scene.rid }
		else
			plain[#plain + 1] = { text = self:scene_label(scene, true), value = scene.rid }
		end
	end
	for _, item in ipairs(deleted) do
		plain[#plain + 1] = item
	end
	if #plain == 0 then
		return empty_list("(every scene on the bridge is imported)")
	end
	return plain
end

-- Add All Scenes Of Room's Hue Room: the groups that have scenes, with their
-- mapping and counts: "Kitchen → Kitchen (7 scenes)", "Attic (zone) →
-- (unmapped) (2 scenes, 1 imported)".
function scenes:picker_groups()
	if not self.synced then
		return empty_list("(no scenes fetched yet; connect the event stream)")
	end
	local rooms = self:project_rooms()
	local counts, imported = {}, {}
	for rid, scene in pairs(self.catalogue) do
		local g = scene.group_rid
		if g then
			counts[g] = (counts[g] or 0) + 1
			if self.registry[rid] then
				imported[g] = (imported[g] or 0) + 1
			end
		end
	end
	local list = {}
	for group_rid, n in pairs(counts) do
		local scene = self:scenes_of_group(group_rid)[1]
		local label = self:group_label(group_rid, scene)
		local mapping = self:room_mapping(group_rid)
		local target
		if not mapping or not mapping.c4_room_id then
			target = "(unmapped)"
		elseif rooms[mapping.c4_room_id] then
			target = rooms[mapping.c4_room_id]
		elseif next(rooms) == nil then
			target = mapping.c4_room_name or ("room " .. tostring(mapping.c4_room_id))
		else
			target = "(Control4 room gone)"
		end
		local tally = plural(n, "scene")
		if (imported[group_rid] or 0) > 0 then
			tally = tally .. string.format(", %d imported", imported[group_rid])
		end
		list[#list + 1] = { text = string.format("%s → %s (%s)", sanitise(label), sanitise(target), tally), value = group_rid,
			key = label:lower() }
	end
	table.sort(list, function(a, b)
		if a.key ~= b.key then
			return a.key < b.key
		end
		return a.value < b.value
	end)
	for _, item in ipairs(list) do
		item.key = nil
	end
	if #list == 0 then
		return empty_list("(no scenes on the bridge)")
	end
	return list
end

-- Re-link's Device: the gone and unbound entries.
function scenes:picker_relink_devices()
	local list = {}
	for _, state in ipairs({ "gone", "unbound" }) do
		for _, rid in ipairs(self.reg:rids(state)) do
			local entry = self.registry[rid]
			-- Labelled like Forget Scene's picker, group first, so the two read alike.
			list[#list + 1] = { text = string.format("%s: %s (device %d, %s since %s)",
				sanitise(self:group_label(entry.group_rid, entry)), self:entry_label(rid, entry),
				entry.device_id, state, short_date_of(entry[state .. "_since"])), value = tostring(entry.device_id) }
		end
	end
	if #list == 0 then
		return empty_list("(no gone or unbound scene devices)")
	end
	return list
end

-- Forget Scene's Device: every entry, as "Kitchen: Relax (device 2061)".
function scenes:picker_forget_devices()
	local list = {}
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		local text = string.format("%s: %s (device %d)", sanitise(self:group_label(entry.group_rid, entry)),
			self:entry_label(rid, entry), entry.device_id)
		if entry.state ~= "linked" then
			text = text .. " " .. entry.state
		end
		list[#list + 1] = { text = text, value = tostring(entry.device_id) }
	end
	if #list == 0 then
		return empty_list("(no registered scenes)")
	end
	return list
end

return scenes
