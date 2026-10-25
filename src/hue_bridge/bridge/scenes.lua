-- The Hue scenes a bridge represents as Control4 devices (hue_scene.c4z, one
-- light_v2 dimmer per scene since build 160, a switch before): the catalogue of the bridge's scenes, the scene
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
-- Time-based ("smart") scenes (docs/smart-scenes-design.md): Hue's
-- `smart_scene` resources ("Golden hours", "Natural light") are scene devices
-- of the same driver with a kind. They have their own catalogue
-- (`smart_catalogue`, hue_model.smart_scene() records tagged kind
-- "smart_scene") filled from the resync's /smart_scene GET and the stream;
-- their registry entries carry `kind = "smart_scene"` (absent = an ordinary
-- scene) in the same registry, so every lifecycle rule, text and picker is
-- shared. What differs: ON activates and OFF deactivates then turns the
-- group off (both on /smart_scene/<rid>); the state reported is Hue's
-- `state` ("active" / "inactive") with the current time slot; names drop the
-- app's trailing number (hue_model.base_name). A failed /smart_scene GET
-- keeps the previous catalogue and changes nothing.
--
-- Callback rules inherited from lights.lua: the GETs run serially, chained
-- from http.request callbacks; on_container runs inside OnBodyChunk and only
-- sends messages; every callback body is pcall-wrapped. The one timer is a
-- recall's coalescing window (RECALL_WINDOW_MS, ctx.set_timer); its callback
-- is pcall-wrapped too.
--
-- Persistence: the registry's mutators change memory only; this module marks
-- itself dirty and saves once per batch, except during device creation, where
-- it saves after every AddDevice. Beside the registry's two keys it persists
-- the devices Forget Scene let go (FORGOTTEN_KEY), written first and only
-- when they changed.

local log = require("common.log")
local hue_model = require("bridge.hue_model")
local registry = require("bridge.registry")
local groups = require("bridge.groups")
local lights = require("bridge.lights")   -- ids_from / dump only: the AddDevice callback shapes
local util = require("bridge.util")
local project = require("bridge.project")

local scenes = {}
scenes.__index = scenes

scenes.SCENES_KEY = "hue_scenes"
scenes.TOMBSTONES_KEY = "hue_scene_tombstones"
-- The devices Forget Scene let go: { ["<device id>"] = { rid, name, kind, at } }.
scenes.FORGOTTEN_KEY = "hue_scene_forgotten"
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
-- HUE_SCENE_LEVEL: a smaller move than this (in %) queues nothing
-- (docs/scene-dimmer-design.md).
scenes.LEVEL_MIN_DELTA = 0.5
-- HUE_SCENE_RECALL: a recall of a scene within this many ms of its last
-- recall PUT waits for the window to end, and the ones that waited leave as
-- one PUT carrying the latest parameters (docs/review-leftovers-design.md,
-- #47 F9). The first recall of a quiet scene goes at once: no tap is slowed,
-- and a keypad hold's recall at 1 % keeps its lead over the dim that follows.
scenes.RECALL_WINDOW_MS = 300

-- recall.action values [community: openhue/aiohue; `active` verified on hardware].
scenes.ACTIONS = { active = true, static = true, dynamic_palette = true }
-- status.active values [verified: hardware 2026-10-21].
scenes.ACTIVE = { inactive = true, static = true, dynamic_palette = true }

-- The registry entry's `kind` of a time-based scene (absent = an ordinary
-- scene), also what HUE_SCENE_CONFIGURE and HUE_SCENE_HELLO carry.
scenes.SMART_KIND = "smart_scene"
scenes.PLAIN_KIND = "scene"
-- smart_scene `state` values, which HUE_SCENE_STATE carries as `active` for a
-- time-based scene [verified: hardware 2026-10-24, docs/smart-scenes-research.md §7].
scenes.SMART_STATES = { active = true, inactive = true }
-- The recall bodies of a time-based scene: start and stop its schedule
-- [verified: hardware 2026-10-24, V4 and V7].
scenes.SMART_ACTIVATE = "activate"
scenes.SMART_DEACTIVATE = "deactivate"

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
--   group_set(grouped_light_rid, fields)  the coalesced absolute grouped_light PUT of driver.lua,
--                            fields { brightness, rate } (docs/scene-dimmer-design.md); true when queued
--   set_timer(delay_ms, fn)  C4:SetTimer(delay_ms, fn), an object with Cancel() [verified: API 34/_1]
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
	ctx.set_timer = ctx.set_timer or function(delay_ms, fn)
		return C4:SetTimer(delay_ms, fn)
	end
	ctx.group_off = ctx.group_off or function(grouped_light_rid)
		ctx.log.warn("scenes: no group_off in ctx; grouped_light %s not turned off", tostring(grouped_light_rid))
		return false
	end
	ctx.group_dim = ctx.group_dim or function(grouped_light_rid)
		ctx.log.warn("scenes: no group_dim in ctx; grouped_light %s not dimmed", tostring(grouped_light_rid))
		return false
	end
	ctx.group_set = ctx.group_set or function(grouped_light_rid)
		ctx.log.warn("scenes: no group_set in ctx; grouped_light %s not set", tostring(grouped_light_rid))
		return false
	end
	project.defaults(ctx, scenes.BINDING)

	local reg = registry.new({
		persist_get = ctx.persist_get, persist_set = ctx.persist_set, now = ctx.now, log = ctx.log,
		keys = { lights = scenes.SCENES_KEY, tombstones = scenes.TOMBSTONES_KEY, rooms = false },
	})
	return setmetatable({
		ctx = ctx,
		reg = reg,
		project = project.new(ctx, "scenes"),  -- the pcall-wrapped project calls
		registry = reg:entries(),  -- rid → entry, the live table (identity kept across load())
		catalogue = {},            -- rid → hue_model.scene() record, from the last GET and the stream (memory only)
		smart_catalogue = {},      -- rid → hue_model.smart_scene() record tagged kind "smart_scene", the same way;
		                           -- kept as it was when a /smart_scene GET fails
		smart_synced = false,      -- a /smart_scene GET has succeeded (missing means something)
		smart_fresh = false,       -- the last resync's /smart_scene GET succeeded (its states are current)
		group_on = {},             -- grouped_light rid → on (boolean) from the last GET and the stream; absent = unknown
		group_level = {},          -- grouped_light rid → dimming.brightness (average of the lights on), when reported
		level_sent = {},           -- grouped_light rid → the HUE_SCENE_GROUP level text last sent to its scenes
		last_configure = {},       -- rid → signature of the last HUE_SCENE_CONFIGURE sent
		recall_gen = {},           -- rid → generation of the latest recall or off (still_current)
		recall_windows = {},       -- rid → { timer, params?, device_id? } for RECALL_WINDOW_MS after a recall PUT;
		                           -- params is the recall waiting for the window to end (the latest)
		announced = {},            -- device_id → { rid, name, kind } from HUE_SCENE_HELLO, for Link Devices
		conflicts = {},            -- rid → { holder = device_id, claimant = device_id }
		forgotten = {},            -- device_id → { rid, name, kind, at }: devices Forget Scene let go (persisted
		                           -- under FORGOTTEN_KEY); a hello from one is answered HUE_SCENE_FORGOTTEN
		forgotten_dirty = false,
		early_hellos = {},         -- hellos received before load(), answered after configure_all()
		loaded = false,
		synced = false,            -- a full GET /scene has succeeded (missing means something)
		dirty = false,
		configured_once = false,
		adding = false,            -- Add Scene / Add All Scenes Of Room running
		resyncing = false,
		resync_pending = {},       -- the done callbacks waiting for the next resync, each called once by it
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

local function round2(n)
	return math.floor(n * 100 + 0.5) / 100
end

-- A group level as HUE_SCENE_GROUP carries it (docs/scene-dimmer-design.md):
-- an integer when whole, else up to two decimals ("57", "56.5", "56.69").
local function level_text(n)
	local r = round2(n)
	if r == math.floor(r) then
		return string.format("%d", r)
	end
	return (string.format("%.2f", r):gsub("0+$", ""))
end

-- A registry entry or a catalogue record of a time-based scene (both carry
-- the kind: entries in the registry, records tagged when cached).
local function is_smart(x)
	return type(x) == "table" and x.kind == scenes.SMART_KIND
end

-- The owner-facing Hue name of an entry or a record: a time-based scene's
-- base name ("Golden hours 4" → "Golden hours", docs/smart-scenes-design.md
-- Decision 7), else the scene's own name.
local function name_of(x)
	local name = type(x) == "table" and x.name or nil
	if name == nil then
		return "?"
	end
	if is_smart(x) then
		return hue_model.base_name(tostring(name))
	end
	return tostring(name)
end

-- Name order (the owner-facing name), case-insensitive, ties by rid.
local function by_name(a, b)
	local an, bn = string.lower(name_of(a)), string.lower(name_of(b))
	if an ~= bn then
		return an < bn
	end
	return tostring(a.rid) < tostring(b.rid)
end

-- The registry's own order, the one reg:rids() gives (bridge/registry.lua's
-- by_name over { rid, name, key }): the cached Hue name lower-cased, then the
-- exact name, then the rid. A subset sorted by it keeps the order rids()
-- gave the whole (rids_where).
local function registry_order(a, b)
	if a.key ~= b.key then
		return a.key < b.key
	end
	if a.name ~= b.name then
		return a.name < b.name
	end
	return a.rid < b.rid
end

-- Membership in a { [device_id] = true } set from a project call, whose ids
-- may arrive as numbers or strings.
local function in_set(set, id)
	if type(set) ~= "table" or id == nil then
		return false
	end
	return set[id] ~= nil or set[tostring(id)] ~= nil
end

-- Registry access ---------------------------------------------------------------

function scenes:load()
	self.reg:load()
	for rid, entry in pairs(self.registry) do
		entry.auto_dynamic = entry.auto_dynamic == true or entry.auto_dynamic == "true"
		self.ctx.log.debug("scenes: loaded %s%s (device %s, %s)", tostring(entry.name),
			is_smart(entry) and " (time-based)" or "", tostring(entry.device_id), tostring(rid))
	end
	self:load_forgotten()
	self.loaded = true
	self.dirty = false
	return self.registry
end

-- The forgotten devices from FORGOTTEN_KEY: keyed by the device id as a
-- string there (a persisted table keeps names as keys whatever its
-- serialiser does with sparse numbers), by number in memory. A record that
-- is not a table, or a key that is not a device id, is dropped.
function scenes:load_forgotten()
	local forgotten = self.forgotten
	for id in pairs(forgotten) do
		forgotten[id] = nil
	end
	self.forgotten_dirty = false
	local raw = self.ctx.persist_get(scenes.FORGOTTEN_KEY)
	if type(raw) ~= "table" then
		return
	end
	for key, record in pairs(raw) do
		local id = util.positive(key)
		if id and type(record) == "table" then
			forgotten[id] = {
				rid = (type(record.rid) == "string" and record.rid ~= "") and record.rid or nil,
				name = type(record.name) == "string" and record.name or nil,
				kind = record.kind == scenes.SMART_KIND and scenes.SMART_KIND or nil,
				at = tonumber(record.at),
			}
		end
	end
end

-- Write FORGOTTEN_KEY when it changed. It goes before the registry (flush,
-- save): a crash between the two writes then leaves a forgotten device
-- marked and still registered, which its hello heals, rather than gone from
-- the registry and unmarked, which a late hello would re-adopt (the order
-- registry:save keeps for its tombstones).
function scenes:save_forgotten()
	if not self.forgotten_dirty then
		return
	end
	self.forgotten_dirty = false
	local out = {}
	for id, record in pairs(self.forgotten) do
		out[tostring(id)] = { rid = record.rid, name = record.name, kind = record.kind, at = record.at }
	end
	self.ctx.persist_set(scenes.FORGOTTEN_KEY, out)
end

function scenes:mark()
	self.dirty = true
end

function scenes:flush()
	self:save_forgotten()
	if self.dirty then
		self.dirty = false
		self.reg:save()
	end
end

function scenes:save()
	self:save_forgotten()
	self.dirty = false
	self.reg:save()
end

-- Forget Scene let device `device_id` go (docs/review-leftovers-design.md,
-- #47 F8): remembered, persisted at the next flush, so its hello is answered
-- HUE_SCENE_FORGOTTEN instead of adopting it again. `told` is the name its
-- HUE_SCENE_FORGOTTEN carried.
function scenes:remember_forgotten(device_id, rid, told, entry)
	self.forgotten[device_id] = { rid = rid, name = told ~= nil and tostring(told) or nil,
		kind = is_smart(entry) and scenes.SMART_KIND or nil, at = self.ctx.now() }
	self.forgotten_dirty = true
end

-- The device is registered again (Link Devices, an adoption) or left the
-- project: its mark goes. True when there was one.
function scenes:clear_forgotten(device_id)
	if device_id == nil or self.forgotten[device_id] == nil then
		return false
	end
	self.forgotten[device_id] = nil
	self.forgotten_dirty = true
	return true
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

-- Time-based scenes seen on the bridge (the smart catalogue).
function scenes:smart_count()
	local n = 0
	for _ in pairs(self.smart_catalogue) do
		n = n + 1
	end
	return n
end

-- The catalogue record for a rid, or nil.
function scenes:scene(rid)
	if rid == nil then
		return nil
	end
	return self.catalogue[rid]
end

-- The smart catalogue record for a rid, or nil.
function scenes:smart_scene(rid)
	if rid == nil then
		return nil
	end
	return self.smart_catalogue[rid]
end

-- The record of a rid in whichever catalogue has it (rids are unique across
-- resource types), or nil.
function scenes:record_of(rid)
	if rid == nil then
		return nil
	end
	return self.catalogue[rid] or self.smart_catalogue[rid]
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

-- The label for owner-facing texts: marked "(deleted in Hue)" once this run
-- has fetched the groups and the cache lacks it (lights.lua's rule).
function scenes:group_label(group_rid, fallback)
	local name, gtype, cached = self:group_info(group_rid, fallback)
	local label = hue_model.group_label(name, gtype)
	if not cached and name ~= nil and self:groups_loaded() then
		label = label .. " (deleted in Hue)"
	end
	return label
end

-- Labels ---------------------------------------------------------------------

-- "Kitchen: Relax" for a catalogue record; " (dynamic)" when asked. A
-- time-based scene is always "Kitchen: Golden hours (time-based)", its base
-- name with the kind (docs/smart-scenes-design.md Decision 8).
function scenes:scene_label(scene, with_dynamic)
	local text = util.sanitise(self:group_label(scene.group_rid, scene)) .. ": " .. util.sanitise(name_of(scene))
	if is_smart(scene) then
		text = text .. " (time-based)"
	elseif with_dynamic and scene.auto_dynamic then
		text = text .. " (dynamic)"
	end
	return text
end

-- The bare scene name of an entry (a time-based scene's base name): what the
-- contract's texts use.
function scenes.entry_label(_self, _rid, entry)
	return util.sanitise(name_of(entry))
end

-- Composer name at creation (§1): "<Scene>" for a room scene, "<Zone> <Scene>"
-- for a zone scene, a time-based scene's base name in place of <Scene>
-- (docs/smart-scenes-design.md Decision 7). `record` is a catalogue record or
-- an entry.
function scenes:creation_name(record)
	local name, gtype = self:group_info(record.group_rid, record)
	if gtype == "zone" and name ~= nil and name ~= "" then
		return tostring(name) .. " " .. name_of(record)
	end
	return name_of(record)
end

-- The registry fields a catalogue record supplies; `kind` only for a
-- time-based scene (an ordinary entry has none).
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
		kind = is_smart(scene) and scenes.SMART_KIND or nil,
	}
end

-- Catalogue views -----------------------------------------------------------------

-- Catalogue records of both kinds without a registry entry, sorted by group
-- label, then the time-based ones before the ordinary ones of the same group
-- (docs/smart-scenes-design.md Decision 8), then name.
function scenes:unimported_scenes()
	local list = {}
	for _, catalogue in ipairs({ self.catalogue, self.smart_catalogue }) do
		for rid, record in pairs(catalogue) do
			if not self.registry[rid] then
				list[#list + 1] = record
			end
		end
	end
	table.sort(list, function(a, b)
		local ag, bg = self:group_label(a.group_rid, a):lower(), self:group_label(b.group_rid, b):lower()
		if ag ~= bg then
			return ag < bg
		end
		if is_smart(a) ~= is_smart(b) then
			return is_smart(a)
		end
		return by_name(a, b)
	end)
	return list
end

-- The catalogue records of one group, name order: its ordinary scenes, or
-- with `smart` its time-based ones.
function scenes:scenes_of_group(group_rid, smart)
	local list = {}
	for _, record in pairs(smart and self.smart_catalogue or self.catalogue) do
		if record.group_rid == group_rid then
			list[#list + 1] = record
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

-- GET /scene, then /smart_scene, then /grouped_light for the groups' on/off
-- and level (HUE_SCENE_GROUP). done({ scene = items, smart_scene = items |
-- nil, grouped_light = items | nil }) or done(nil, err) when the scene GET
-- failed; a failed smart scene GET keeps the previous time-based catalogue
-- (absorb), a failed grouped_light GET only leaves the groups' on/off and
-- level unknown.
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
					local smart = r2.ok and type(r2.json) == "table" and r2.json.data or nil
					if type(smart) ~= "table" then
						smart = nil
						self.ctx.log.warn("scenes: GET %s: %s; kept the %d time-based scenes known before, none marked "
							.. "gone and none told a state", scenes.SMART_SCENE_PATH, tostring(r2.err or "malformed response"),
							self:smart_count())
					end
					self.ctx.http({ path = scenes.GROUPED_LIGHT_PATH, method = "GET" }, function(r3)
						self:protect("fetch grouped_light", function()
							local gl = r3.ok and type(r3.json) == "table" and r3.json.data or nil
							if type(gl) ~= "table" then
								gl = nil
								self.ctx.log.warn("scenes: GET %s: %s; group on/off and level unknown", scenes.GROUPED_LIGHT_PATH,
									tostring(r3.err or "malformed response"))
							end
							done({ scene = items, smart_scene = smart, grouped_light = gl })
						end)
					end)
				end)
			end)
		end)
	end)
end

-- The smart catalogue from a /smart_scene GET body's data: records tagged
-- with the kind, malformed items dropped.
function scenes.smart_records(items)
	local out = {}
	for _, item in ipairs(items) do
		if type(item) == "table" and item.id ~= nil then
			local record = hue_model.smart_scene(item)
			if record then
				record.kind = scenes.SMART_KIND
				out[record.rid] = record
			end
		end
	end
	return out
end

-- Replace the catalogues with a fetch result and refresh the registry's
-- cached identity fields. The GETs are authoritative for status too. Without
-- a /smart_scene body (its GET failed) the time-based catalogue stays as it
-- was and `smart_fresh` says its states are not current
-- (docs/smart-scenes-design.md Decision 11).
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
	if type(res.smart_scene) == "table" then
		self.smart_catalogue = scenes.smart_records(res.smart_scene)
		self.smart_synced, self.smart_fresh = true, true
	else
		self.smart_fresh = false
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
	self.ctx.log.debug("scenes: %d scenes and %d time-based scenes cached%s", self:bridge_count(), self:smart_count(),
		self.smart_fresh and "" or " (time-based ones from before)")
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

-- The identity fields of one entry from its catalogue record (of either
-- kind). True when something changed (the caller marks).
function scenes:refresh_entry(rid)
	local entry, scene = self.registry[rid], self:record_of(rid)
	if not entry or not scene then
		return false
	end
	local changed = self:take_name(entry, scene)
	local fields = self:fields_from_scene(scene)
	fields.name = nil
	-- The entry follows the kind of the record its rid names (rids are unique
	-- across resource types): an entry adopted without one heals here.
	if is_smart(entry) and not is_smart(scene) then
		fields.kind = registry.CLEAR
	end
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

-- The current time slot of a time-based record as HUE_SCENE_CONFIGURE and
-- HUE_SCENE_STATE carry it: the slot scene's name and the slot's start
-- ("07:00", "sunset"), each nil when unknown (no slot, or a slot scene the
-- scene catalogue lacks). nil, nil for anything else.
function scenes:slot_info(record)
	if not is_smart(record) then
		return nil, nil
	end
	local slot = hue_model.current_slot(record)
	if type(slot) ~= "table" then
		return nil, nil
	end
	local target = slot.target_rid ~= nil and self.catalogue[slot.target_rid] or nil
	local start = slot.start
	if type(start) ~= "string" or start == "" then
		start = nil
	end
	return target and target.name or nil, start
end

-- HUE_SCENE_CONFIGURE params (§2): rid, name, group_name, group_type, id_v1?,
-- auto_dynamic, state, gone_since?, kind ("scene" / "smart_scene"); for a
-- time-based scene the name is its base name, auto_dynamic "false", plus
-- slot_name? and slot_start? (docs/smart-scenes-design.md, Messages). Every
-- value a non-empty string (hue_model drops nil and "", as C4:SendToDevice
-- would).
function scenes:configure_params(rid, entry)
	local smart = is_smart(entry)
	local extra = {
		-- The plain name ("Kitchen", "Downstairs"): the device adds "(zone)"
		-- itself [verified: a label here showed as "… (zone) (zone)"].
		group_name = (self:group_info(entry.group_rid, entry)),
		group_type = entry.group_type,
		state = entry.state == "gone" and "gone" or "linked",
		kind = smart and scenes.SMART_KIND or scenes.PLAIN_KIND,
	}
	if entry.state == "gone" then
		extra.gone_since = entry.gone_since
	end
	if smart then
		extra.slot_name, extra.slot_start = self:slot_info(self.smart_catalogue[rid])
	end
	return hue_model.scene_configure_params({
		rid = rid, name = (smart and entry.name ~= nil) and name_of(entry) or entry.name, id_v1 = entry.id_v1,
		auto_dynamic = not smart and entry.auto_dynamic == true,
	}, extra)
end

-- HUE_SCENE_STATE params (§2). The bridge always names a status: a scene
-- whose status it does not know (not on the bridge) reads as inactive. A
-- time-based scene's `active` is its state, "active" or "inactive", with its
-- current slot_name? and slot_start? (docs/smart-scenes-design.md, Messages).
function scenes:state_params(rid, active, reason)
	if is_smart(self.registry[rid]) then
		local params = { rid = rid, active = scenes.SMART_STATES[active] and active or "inactive",
			reason = reason or "event" }
		params.slot_name, params.slot_start = self:slot_info(self.smart_catalogue[rid])
		return params
	end
	return hue_model.scene_state_params({ rid = rid, active = scenes.ACTIVE[active] and active or "inactive" }, reason)
end

-- The status the bridge last reported for a registered scene: the
-- catalogue's (a time-based scene's state), "inactive" for a scene that is
-- not on the bridge.
function scenes:current_active(rid)
	local record = self:record_of(rid)
	if not record then
		return "inactive"
	end
	if is_smart(record) then
		return record.state or "inactive"
	end
	return record.active or "inactive"
end

-- Whether the bridge knows a registered scene's status well enough to tell
-- it: a GET of its kind has succeeded, or the catalogue has the scene. Before
-- that a guessed "inactive" would turn a lit scene's tile off.
function scenes:state_known(rid)
	if is_smart(self.registry[rid]) then
		return self.smart_synced or self.smart_catalogue[rid] ~= nil
	end
	return self.synced or self.catalogue[rid] ~= nil
end

function scenes:send_configure(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	local params = self:configure_params(rid, entry)
	self.last_configure[rid] = util.signature(params)
	self.ctx.send(entry.device_id, "HUE_SCENE_CONFIGURE", params)
	return true
end

function scenes:configure_changed(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	return self.last_configure[rid] ~= util.signature(self:configure_params(rid, entry))
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

-- The group a scene of either kind belongs to: the catalogue's, else the entry's.
function scenes:group_rid_of(rid)
	local scene, entry = self:record_of(rid), self.registry[rid]
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

-- HUE_SCENE_GROUP { rid, on?, level? } to one registered scene's device;
-- `fields` holds the strings sent besides the rid.
function scenes:send_group(rid, fields)
	local entry = self.registry[rid]
	if not entry or entry.state ~= "linked" then
		return false
	end
	local params = { rid = rid }
	for k, v in pairs(fields) do
		params[k] = v
	end
	self.ctx.send(entry.device_id, "HUE_SCENE_GROUP", params)
	return true
end

-- The registered rids `keep(rid, entry)` accepts, in the registry's order
-- (registry_order): the registry is filtered first and only the matches are
-- sorted, so a per-event lookup costs a sort of the few scenes it concerns
-- rather than of every scene imported (docs/reviews/efficiency-2026-10-24.md,
-- R8). Pure: `keep` only reads.
function scenes:rids_where(keep)
	local list = {}
	for rid, entry in pairs(self.registry) do
		if keep(rid, entry) then
			local name = entry.name ~= nil and tostring(entry.name) or ""
			list[#list + 1] = { rid = rid, name = name, key = name:lower() }
		end
	end
	if #list > 1 then
		table.sort(list, registry_order)
	end
	for i, item in ipairs(list) do
		list[i] = item.rid
	end
	return list
end

-- The linked scenes whose group owns grouped_light `grouped_rid`, in the
-- registry's order.
function scenes:linked_scenes_on(grouped_rid)
	return self:rids_where(function(rid, entry)
		return entry.state == "linked" and self:grouped_light_of(self:group_rid_of(rid)) == grouped_rid
	end)
end

-- Every linked scene whose group owns grouped_light `grouped_rid` hears
-- `fields`; `rids` (optional) are those scenes when the caller has them
-- already. Returns the number of messages sent.
function scenes:send_group_for(grouped_rid, fields, rids)
	local sent = 0
	for _, rid in ipairs(rids or self:linked_scenes_on(grouped_rid)) do
		if self:send_group(rid, fields) then
			sent = sent + 1
		end
	end
	return sent
end

-- What a resync tells the scenes of grouped_light `grouped_rid`: its on/off
-- and its level, each when known; nil when neither is.
function scenes:group_fields(grouped_rid)
	local on, level = self.group_on[grouped_rid], self.group_level[grouped_rid]
	if on == nil and level == nil then
		return nil
	end
	local fields = {}
	if on ~= nil then
		fields.on = on and "true" or "false"
	end
	if level ~= nil then
		fields.level = level_text(level)
	end
	return fields
end

-- After a resync: every linked scene whose group's on/off or level is known
-- hears them, changed or not; the levels sent become the groups' last sent.
function scenes:send_group_all()
	local sent, level_sent = 0, {}
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		if entry.state == "linked" then
			local grouped = self:grouped_light_of(self:group_rid_of(rid))
			local fields = grouped and self:group_fields(grouped)
			if fields and self:send_group(rid, fields) then
				sent = sent + 1
				level_sent[grouped] = fields.level
			end
		end
	end
	self.level_sent = level_sent
	return sent
end

-- A grouped_light item from the stream: the scenes of its group hear what
-- changed, in one HUE_SCENE_GROUP each: `on` when the on/off changed,
-- `level` when it differs from the last level sent to the group. The group's
-- on/off and level are kept whatever the group; a group no linked scene is
-- on (most of a house's) costs no level text and no sort (R8). Returns the
-- number of messages sent.
function scenes:on_grouped_light(item)
	local grouped = item.id
	local level = type(item.dimming) == "table" and item.dimming.brightness or nil
	if type(level) ~= "number" then
		level = nil
	end
	if level ~= nil then
		self.group_level[grouped] = level
	end
	local fields = {}
	if type(item.on) == "table" and type(item.on.on) == "boolean" and self.group_on[grouped] ~= item.on.on then
		self.group_on[grouped] = item.on.on
		fields.on = item.on.on and "true" or "false"
	end
	if level == nil and fields.on == nil then
		return 0
	end
	local rids = self:linked_scenes_on(grouped)
	if #rids == 0 then
		return 0
	end
	if level ~= nil then
		local text = level_text(level)
		if self.level_sent[grouped] ~= text then
			fields.level = text
		end
	end
	if next(fields) == nil then
		return 0
	end
	local sent = self:send_group_for(grouped, fields, rids)
	if sent > 0 and fields.level then
		self.level_sent[grouped] = fields.level
	end
	return sent
end

-- Whether registered scene `rid` is a time-based one whose current slot
-- targets scene `target_rid`.
function scenes:slot_targets(rid, target_rid)
	if not is_smart(self.registry[rid]) then
		return false
	end
	local record = self.smart_catalogue[rid]
	local slot = record and hue_model.current_slot(record)
	return type(slot) == "table" and slot.target_rid == target_rid
end

-- Scene `rid` became active (static / dynamic_palette), or time-based scene
-- `rid` became active: every other linked scene device of its group hears
-- HUE_SCENE_GROUP other_active. For an ordinary scene a time-based device
-- whose current slot targets it is left out: that scene starting is its
-- schedule running (docs/smart-scenes-design.md Decision 10). `rid` need not
-- be imported (a scene recalled from the Hue app). Returns the number sent.
function scenes:send_other_active(rid)
	local group_rid = self:group_rid_of(rid)
	if group_rid == nil then
		return 0
	end
	local from_smart = is_smart(self:record_of(rid)) or is_smart(self.registry[rid])
	local others = self:rids_where(function(other, entry)
		return other ~= rid and entry.state == "linked" and self:group_rid_of(other) == group_rid
			and (from_smart or not self:slot_targets(other, rid))
	end)
	for _, other in ipairs(others) do
		self.ctx.send(self.registry[other].device_id, "HUE_SCENE_GROUP", { rid = other, other_active = "true" })
	end
	return #others
end

-- CONFIGURE (when asked for, or when it changed) then STATE. The state is
-- sent only once a GET has told us something (or the catalogue has the
-- scene): before that a guessed "inactive" would turn a lit scene's tile off
-- (state_known).
function scenes:push(rid, reason, with_configure)
	if not self.registry[rid] then
		return false
	end
	if with_configure or self:configure_changed(rid) then
		self:send_configure(rid)
	end
	if not self:state_known(rid) then
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
	if self:state_known(rid) then
		local answered = self:push(rid, "hello", true)
		self:send_group_known(rid)
		return answered
	end
	return self:send_configure(rid)
end

-- A device that says hello between resyncs (added, re-linked, restarted)
-- hears its group's on/off and level at once instead of at the next change.
function scenes:send_group_known(rid)
	local entry = self.registry[rid]
	if not entry or entry.state ~= "linked" then
		return false
	end
	local grouped = self:grouped_light_of(self:group_rid_of(rid))
	local fields = grouped and self:group_fields(grouped)
	return fields ~= nil and self:send_group(rid, fields) or false
end

-- Register a bound device for a rid the registry lacks (auto-adopt, Link
-- Devices). The kind is the catalogue's; for a rid neither catalogue has,
-- the one the device announced (HUE_SCENE_HELLO `kind`), and the entry is
-- gone once a GET of that kind has succeeded. Returns the entry or nil.
function scenes:adopt(device_id, rid, hello, how)
	local scene = self:record_of(rid)
	local fields = self:fields_from_scene(scene)
	fields.device_id = device_id
	fields.name = fields.name or hello.name
	if not scene and hello.kind == scenes.SMART_KIND then
		fields.kind = scenes.SMART_KIND
	end
	local entry, err = self.reg:add(rid, fields)
	if not entry then
		self.ctx.log.warn("scenes: could not adopt device %d for %s: %s", device_id, tostring(rid), tostring(err))
		return nil
	end
	self:clear_forgotten(device_id)  -- Link Devices brought a forgotten device back
	self:mark()
	if not scene and (is_smart(entry) and self.smart_synced or not is_smart(entry) and self.synced) then
		self.reg:set_state(rid, "gone")
	end
	self.ctx.log.always("scenes: adopted %s%s (device %d) %s", tostring(entry.name or rid),
		is_smart(entry) and " (time-based)" or "", device_id, how)
	return entry
end

-- HUE_SCENE_HELLO { rid?, device_id, name?, kind? }: the same rules as
-- lights:hello (§4 of import-design). `kind` ("scene" / "smart_scene", what
-- the device persisted beside its rid) only matters when the device is
-- adopted for a rid neither catalogue has; otherwise the registry's kind is
-- the truth and the answer's CONFIGURE carries it. Returns true when answered.
function scenes:hello(rid, params)
	params = params or {}
	if type(rid) ~= "string" or rid == "" then
		rid = nil
	end
	local device_id = util.positive(params.device_id)
	if not (self.loaded or self.synced) then
		if rid or device_id then
			self.early_hellos[#self.early_hellos + 1] = { rid = rid, params = params }
		end
		return false
	end
	local remembered = device_id and self.forgotten[device_id] or nil
	if remembered then
		if not self.reg:by_device(device_id) then
			return self:refuse_forgotten(device_id, rid, remembered)
		end
		-- Registered again after all (a crash between the two writes of a
		-- forget): the registry is the truth and the mark is stale.
		self:clear_forgotten(device_id)
		self:flush()
	end
	if device_id then
		self.announced[device_id] = { rid = rid, name = params.name, kind = params.kind }
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

	local bound = self.project:bound_set()
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

-- The hello of a device Forget Scene let go (#47 F8): told
-- HUE_SCENE_FORGOTTEN again, never adopted, never counted as a claimant or
-- remembered as announced; Link Devices, an owner's click, is the way back.
-- Returns false (not answered with a configuration).
function scenes:refuse_forgotten(device_id, rid, remembered)
	rid = rid or remembered.rid
	self.ctx.send(device_id, "HUE_SCENE_FORGOTTEN", { rid = rid, name = remembered.name })
	self.ctx.log.info("scenes: device %d said hello for %s, but Forget Scene let it go on %s; told so, not adopted "
		.. "(Link Devices links it again)", device_id, tostring(rid), util.date_of(remembered.at))
	return false
end

-- HUE_SCENE_GOODBYE { rid?, device_id }: the device is being deleted in
-- Composer; the entry becomes a tombstone. Returns the tombstone or nil.
function scenes:goodbye(params)
	params = params or {}
	local device_id = util.positive(params.device_id)
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
		if self:clear_forgotten(device_id) then
			self:flush()  -- a forgotten device leaving the project takes its mark along
		end
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
	local device_id = util.positive(other_id)
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
-- project. `created` (optional, rids) are the entries the caller's batch
-- has just made: they are left as they are, since Director may not list a
-- device AddDevice has just created, or its new binding, yet, and this must
-- not mislabel what it just made (code analysis 2026-10-22 item 13, #48).
-- Conflicts and forgotten marks whose devices left the project go too.
-- Saves unless `no_save`.
function scenes:reconcile(no_save, created)
	local bound, why = self.project:bound_set()
	if not bound then
		-- A failed lookup, or an answer that is no list (bridge/project.lua:
		-- unknown, #48 item 14), which is expected while nothing is imported.
		local note = (why == "unknown" and self:count() == 0) and self.ctx.log.debug or self.ctx.log.warn
		note("scenes: reconcile skipped: the bound-device lookup %s", why == "unknown" and "answered no list" or "failed")
		return { unbound = {}, relinked = {}, tombstoned = {} }
	end
	local infos = self.project:devices_of(scenes.SCENE_DRIVER)
	local present = nil
	if infos then
		present = {}
		for id in pairs(infos) do
			present[id] = true
		end
	end
	local skip = nil
	for _, rid in ipairs(created or {}) do
		skip = skip or {}
		skip[rid] = true
	end
	local r = self.reg:reconcile({ bound = bound, present = present, skip = skip })
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
	self:prune_conflicts(present)
	self:prune_forgotten(present)
	if not no_save then
		self:flush()
	end
	return r
end

-- A claim (two devices on one scene, `conflicts`) ends once fewer than two
-- of its devices are still in the project: a claimant deleted in Composer
-- while the bridge was not watching sends no goodbye (code analysis
-- 2026-10-22, F10). Nothing is pruned while the project's hue_scene devices
-- are unknown (`present` nil).
function scenes:prune_conflicts(present)
	if not present then
		return
	end
	for rid, c in pairs(self.conflicts) do
		if not (in_set(present, c.holder) and in_set(present, c.claimant)) then
			self.conflicts[rid] = nil
			self.ctx.log.info("scenes: devices %s and %s no longer both claim %s: one left the project",
				tostring(c.holder), tostring(c.claimant), tostring(rid))
		end
	end
end

-- A forgotten device deleted in Composer (after Forget its goodbye may not
-- reach the bridge) needs no mark any more. Unknown project: nothing goes.
function scenes:prune_forgotten(present)
	if not present then
		return
	end
	for id in pairs(self.forgotten) do
		if not in_set(present, id) then
			self:clear_forgotten(id)
			self.ctx.log.debug("scenes: forgotten device %d is no longer in the project", id)
		end
	end
end

-- Step 2, the scenes: a registered rid absent from /scene (a time-based one:
-- from /smart_scene) is "gone" (the device hears state gone and STATE
-- inactive); back again is "linked". After a failed /smart_scene GET the
-- time-based entries are left as they are: a kept catalogue proves nothing
-- missing (docs/smart-scenes-design.md Decision 11). New unimported scenes
-- are counted at debug only: nothing is ever created from a resync and Hue's
-- default scenes would make a nag meaningless.
function scenes:reconcile_scenes()
	for _, rid in ipairs(self.reg:rids()) do
		local entry, scene = self.registry[rid], self:record_of(rid)
		if scene then
			if entry.state == "gone" and self.reg:set_state(rid, "linked") then
				self:mark()
				self.ctx.log.always("scenes: %s (device %d) is back on the bridge", self:entry_label(rid, entry),
					entry.device_id)
			end
		elseif is_smart(entry) and not self.smart_fresh then
			self.ctx.log.debug("scenes: %s (device %d) not checked: the time-based scenes were not fetched",
				self:entry_label(rid, entry), entry.device_id)
		elseif entry.state == "linked" and self.reg:set_state(rid, "gone") then
			self:mark()
			self.ctx.log.warn("scenes: %s (device %d) is no longer on the bridge; marked gone (Re-link Scene or Forget Scene)",
				self:entry_label(rid, entry), entry.device_id)
			self:announce_gone(rid, "resync")
		end
	end
	if self.ctx.log.enabled("debug") then   -- the count sorts the whole catalogue: only when it is shown
		self.ctx.log.debug("scenes: %d scenes on the bridge not imported (time-based ones included)",
			#self:unimported_scenes())
	end
end

-- Step 5, the fan-out: STATE (and CONFIGURE first when asked or changed) to
-- every linked entry (§4: "STATE for every linked scene"); a gone one hears
-- only a changed CONFIGURE, its inactive went out when it became gone (and
-- goes out again on its hello). A time-based entry hears no STATE after a
-- failed /smart_scene GET: its state is not known to be current.
function scenes:fanout(reason, with_configure)
	local sent = 0
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		if entry.state == "linked" and is_smart(entry) and not self.smart_fresh then
			if with_configure or self:configure_changed(rid) then
				self:send_configure(rid)
			end
		elseif entry.state == "linked" then
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
	self:send_group_all()
	self:flush()
	return sent
end

-- Resync ---------------------------------------------------------------------

-- After every stream connect (the coordinator runs it after lights:resync so
-- the group cache is fresh) and from Refresh Scenes. done(ok, err, sent,
-- grouped_light): the fourth value is the /grouped_light body's data array
-- when that GET succeeded (nil otherwise), for the zone lights' resync to
-- take instead of fetching the same records again. A resync asked for while
-- one (or an add) runs waits for it, and one more resync then answers every
-- caller that waited, each once: a connect's chain (the zone lights' resync
-- and the rows' refresh) is not lost to a Refresh Scenes click that came
-- after it (code analysis 2026-10-22, F2; #47).
function scenes:resync(done)
	done = done or function() end
	self:expire_stale_busy()
	if self.resyncing or self.adding then
		self.resync_pending[#self.resync_pending + 1] = done
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
			self:protect("resync done", done, true, nil, sent, res.grouped_light)
		end
		self:run_pending_resync()
	end)
end

-- The resync the waiting callers asked for: one, whose done answers each of
-- them in the order they asked (each pcall-wrapped on its own).
function scenes:run_pending_resync()
	local pending = self.resync_pending
	if #pending == 0 then
		return
	end
	self.resync_pending = {}
	self:resync(function(...)
		for _, done in ipairs(pending) do
			self:protect("resync done", done, ...)
		end
	end)
end

-- Event fan-out --------------------------------------------------------------

-- A registered scene of either kind is on the bridge again (an add item; its
-- catalogue has the record): linked again, refreshed (logged under the name
-- the owner knows) and told. Returns the number of messages sent.
function scenes:scene_back(rid, entry)
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

-- A scene of either kind left the bridge (a delete item; its catalogue has
-- forgotten it): a linked entry is gone and told. Returns the number sent.
function scenes:scene_deleted(rid, entry)
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

-- Scene `target_rid` was renamed: the linked time-based scenes whose current
-- slot it is hear their new slot name (CONFIGURE). Returns the number sent.
function scenes:tell_slot_scene(target_rid)
	local sent = 0
	local slots = self:rids_where(function(rid, entry)
		return entry.state == "linked" and self:slot_targets(rid, target_rid)
	end)
	for _, rid in ipairs(slots) do
		if self:configure_changed(rid) and self:send_configure(rid) then
			sent = sent + 1
		end
	end
	return sent
end

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
			return self:scene_back(rid, entry)
		end
		self.ctx.log.debug("scenes: new scene %s on the bridge; Add Scene lists it", self:scene_label(fresh))
		return 0
	elseif kind == "delete" then
		self.catalogue[rid] = nil
		return self:scene_deleted(rid, entry)
	end
	if not scene then
		return 0  -- an update for a scene the resync has not brought yet
	end
	local changed = hue_model.update_scene(scene, item)
	local sent = 0
	if util.has_field(changed, "active") and (scene.active == "static" or scene.active == "dynamic_palette") then
		sent = sent + self:send_other_active(rid)
	end
	local renamed = util.has_field(changed, "name")
	if renamed then
		sent = sent + self:tell_slot_scene(rid)
	end
	if not entry then
		return sent
	end
	-- The scene's own CONFIGURE inputs a scene item can carry: its name, its
	-- group and auto_dynamic. A status (every recall, every member light
	-- changed by hand) or a speed cannot change it, so its signature is not
	-- even computed; group renames reach CONFIGURE through
	-- refresh_group_names, slot renames through tell_slot_scene
	-- (docs/reviews/efficiency-2026-10-24.md, R3).
	local identity = renamed or util.has_field(changed, "group_rid") or util.has_field(changed, "auto_dynamic")
	if identity and self:refresh_entry(rid) then
		self:mark()
	end
	if entry.state == "unbound" then
		return sent
	end
	if identity and self:configure_changed(rid) and self:send_configure(rid) then
		sent = sent + 1
	end
	if util.has_field(changed, "active") and self:send_state(rid, "event") then
		sent = sent + 1
	end
	return sent
end

-- What a time-based record shows its device, to tell what an update changed
-- (the model may change the record's tables in place).
function scenes.smart_snapshot(_self, record)
	local slot = hue_model.current_slot(record)
	slot = type(slot) == "table" and slot or {}
	return { state = record.state, name = record.name, group_rid = record.group_rid, slot_target = slot.target_rid,
		slot_start = slot.start }
end

-- A smart_scene item of an event container (docs/smart-scenes-design.md
-- Decisions 2, 10, 11). add: cached (created in the app it arrives running,
-- V12, so its group hears other_active), and a registered entry is back;
-- delete: a linked entry is gone; update: becoming active tells the other
-- scene devices of its group (other_active), a rename refreshes the entry,
-- and its device hears a changed CONFIGURE and, when the item carried a
-- state or the current slot moved, STATE. Returns the number of messages
-- sent.
function scenes:on_smart_item(item, kind)
	local rid = item.id
	local entry, record = self.registry[rid], self.smart_catalogue[rid]
	if kind == "add" then
		local fresh = hue_model.smart_scene(item)
		if not fresh then
			return 0
		end
		fresh.kind = scenes.SMART_KIND
		self.smart_catalogue[rid] = fresh
		local sent = fresh.state == "active" and self:send_other_active(rid) or 0
		if entry then
			return sent + self:scene_back(rid, entry)
		end
		self.ctx.log.debug("scenes: new scene %s on the bridge; Add Scene lists it", self:scene_label(fresh))
		return sent
	elseif kind == "delete" then
		self.smart_catalogue[rid] = nil
		return self:scene_deleted(rid, entry)
	end
	if not record then
		return 0  -- an update for a time-based scene the resync has not brought yet
	end
	local before = self:smart_snapshot(record)
	hue_model.update_smart_scene(record, item)
	local after = self:smart_snapshot(record)
	-- A state the item carried is told to the device even when unchanged, as
	-- a scene's status is; other_active only goes out when it becomes active
	-- (scenes:activate covers an answer that lands before the event).
	local state_told = type(item.state) == "string" and record.state == item.state
	local sent = 0
	if before.state ~= "active" and after.state == "active" then
		sent = sent + self:send_other_active(rid)
	end
	if not entry then
		return sent
	end
	if before.name ~= after.name or before.group_rid ~= after.group_rid then
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
	local slot_moved = before.slot_target ~= after.slot_target or before.slot_start ~= after.slot_start
	if (state_told or before.state ~= after.state or slot_moved) and self:send_state(rid, "event") then
		sent = sent + 1
	end
	return sent
end

-- One event-stream container. Scene and smart_scene items are handled, the
-- smart_scene ones first (a pass of their own): a time slot starting and its
-- slot scene's status may share a container, and other_active reads the
-- current slot (docs/smart-scenes-design.md Decision 10). A grouped_light
-- item updates the group's on/off and level (HUE_SCENE_GROUP with what
-- changed); a room/zone item means the lights' group cache may have changed
-- (lights:on_container runs first), so the entries' group names are
-- refreshed. Runs inside OnBodyChunk: no transfers are started here.
function scenes:on_container(container)
	if type(container) ~= "table" or type(container.data) ~= "table" then
		return 0
	end
	local sent, groups_changed = 0, false
	local kind, items = container.type, container.data
	for _, item in ipairs(items) do
		if type(item) == "table" and item.id ~= nil and item.type == "smart_scene" then
			sent = sent + self:on_smart_item(item, kind)
		end
	end
	for _, item in ipairs(items) do
		if type(item) == "table" and item.id ~= nil then
			if item.type == "scene" then
				sent = sent + self:on_scene_item(item, kind)
			elseif item.type == "grouped_light" then
				if kind == "delete" then
					self.group_on[item.id] = nil
					self.group_level[item.id] = nil
					self.level_sent[item.id] = nil
				else
					sent = sent + self:on_grouped_light(item)
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

-- Whether the answer to a recall or off PUT of `rid` (generation `gen`, for
-- `entry`'s device) may still report: not when the scene was re-linked,
-- forgotten or gone while the PUT was in flight, nor when a later recall or
-- OFF of the same scene superseded it [code analysis 2026-10-22, F3].
function scenes:still_current(rid, entry, gen)
	local current = self.registry[rid]
	if not current or current.device_id ~= entry.device_id or current.state ~= "linked" then
		return false
	end
	return self.recall_gen[rid] == gen
end

-- Why a PUT failed, for a warning: "HTTP 404 (<hint>)", "HTTP <code>", or
-- the transfer error.
local function failure_text(r, hint)
	if r.code == 404 then
		return "HTTP 404 (" .. hint .. ")"
	elseif r.code then
		return "HTTP " .. tostring(r.code)
	end
	return tostring(r.err)
end

-- HUE_SCENE_RECALL for a time-based scene (docs/smart-scenes-design.md
-- Decision 3): PUT {"recall":{"action":"activate"}} on /smart_scene/<rid>
-- whatever the action, without duration or brightness (a smart recall has
-- neither; a debug line names what was ignored); on success STATE active
-- (reason "recall"), on failure a warning and STATE with the cached state.
-- Returns true (a PUT was started).
function scenes:activate(rid, entry, params)
	local ignored = {}
	for _, key in ipairs({ "action", "duration", "brightness" }) do
		local value = params[key]
		if value ~= nil and value ~= "" and not (key == "action" and value == scenes.SMART_ACTIVATE) then
			ignored[#ignored + 1] = key .. " " .. tostring(value)
		end
	end
	if #ignored > 0 then
		self.ctx.log.debug("scenes: recall of time-based %s (device %d) activates it; ignored %s",
			self:entry_label(rid, entry), entry.device_id, table.concat(ignored, ", "))
	end
	local gen = self:next_recall_gen(rid)
	self.ctx.log.info("scenes: activate %s (device %d)", self:entry_label(rid, entry), entry.device_id)
	local body = { recall = { action = scenes.SMART_ACTIVATE } }
	self.ctx.http({ path = scenes.SMART_SCENE_PATH .. "/" .. rid, method = "PUT", body = body }, function(r)
		self:protect("activate done", function()
			if not self:still_current(rid, entry, gen) then
				return
			end
			if r.ok then
				-- The bridge's event usually comes first [verified: hardware
				-- 2026-10-24, V4: about 50 ms before the answer]; when it has
				-- not, this is where the scene becomes active (Decision 10).
				local record = self.smart_catalogue[rid]
				if record and record.state ~= "active" then
					record.state = "active"
					self:send_other_active(rid)
				end
				self:send_state(rid, "recall", "active")
				return
			end
			self.ctx.log.warn("scenes: %s (device %d): Recall failed: %s", self:entry_label(rid, entry), entry.device_id,
				failure_text(r, "time-based scene gone?"))
			self:send_state(rid, "recall")
		end)
	end)
	return true
end

-- Recall coalescing (docs/review-leftovers-design.md, #47 F9) -------------------
-- A recall PUT opens a window of RECALL_WINDOW_MS for its scene. A recall of
-- the same scene inside it waits, replacing any that waits already (the
-- latest parameters win), and supersedes the answer of the PUT before it
-- (still_current); when the window ends the one that waited goes as one PUT,
-- which opens the next window. So a double tap, a programming loop or a
-- slider dragged from off makes one PUT per window instead of one each, and
-- the first recall of a quiet scene is not delayed at all. What came after a
-- waiting recall must not overtake it: an OFF of the scene drops it (the OFF
-- is the latest word), and any other command of the scenes (a dim, a level,
-- another scene's recall or off) sends it first. So at most one recall waits
-- at a time.

function scenes:open_recall_window(rid)
	local window = {}
	window.timer = self.ctx.set_timer(scenes.RECALL_WINDOW_MS, function()
		self:protect("recall window", function()
			if self.recall_windows[rid] ~= window then
				return  -- released early, or replaced
			end
			self.recall_windows[rid] = nil
			self:send_waiting(rid, window)
		end)
	end)
	self.recall_windows[rid] = window
end

-- The recall that waited in `window` (closed already) goes now, unless its
-- scene left the registry or changed devices meanwhile (forgotten,
-- re-linked, deleted): that device's own command is over then.
function scenes:send_waiting(rid, window)
	local params = window.params
	if not params then
		return false
	end
	window.params = nil
	local current = self.registry[rid]
	if not current or current.device_id ~= window.device_id then
		self.ctx.log.debug("scenes: a waiting recall of %s dropped: its device %s is not the scene's any more", rid,
			tostring(window.device_id))
		return false
	end
	if current.state == "gone" then
		-- Deleted in Hue meanwhile: the device heard STATE inactive with it.
		self.ctx.log.debug("scenes: a waiting recall of %s dropped: the scene left the bridge", rid)
		return false
	end
	return self:send_recall(rid, current, params)
end

-- The waiting recall, unless it is `keep`'s, goes at once; its window
-- closes and the PUT opens the next. The windows are collected first: the
-- PUT adds one to the table, which a traversal must not see happen.
function scenes:release_recalls(keep)
	if next(self.recall_windows) == nil then
		return
	end
	local waiting = {}
	for rid, window in pairs(self.recall_windows) do
		if rid ~= keep and window.params then
			waiting[#waiting + 1] = rid
		end
	end
	for _, rid in ipairs(waiting) do
		local window = self.recall_windows[rid]
		if window.timer then
			window.timer:Cancel()
		end
		self.recall_windows[rid] = nil
		self:send_waiting(rid, window)
	end
end

-- An OFF of scene `rid`: the recall waiting in its window is dropped (the
-- window stays, so recalls after the OFF are still paced).
function scenes:drop_waiting_recall(rid)
	local window = self.recall_windows[rid]
	if window and window.params then
		window.params = nil
		self.ctx.log.debug("scenes: a waiting recall of %s dropped: an off came after it", rid)
	end
end

-- HUE_SCENE_RECALL { rid, action?, duration?, brightness? }: PUT the recall
-- (a brightness 1-100 overrides the scene's as recall.dimming, a duration
-- in ms is clamped to 0..DIM_MAX_DURATION); on success STATE with the state
-- the action produces (reason "recall") so the device settles even if the
-- stream item is missed; on failure a warning and STATE with the cached
-- status. A recall within RECALL_WINDOW_MS of the scene's last recall PUT
-- waits for the window to end (open_recall_window). A time-based scene is
-- activated instead (scenes:activate). Returns true when a PUT was started
-- or waits to be.
function scenes:recall(params)
	params = params or {}
	local rid, entry = self:entry_for_command(params, "HUE_SCENE_RECALL")
	if not rid then
		return false
	end
	if entry.state == "gone" then
		self.ctx.log.warn("scenes: recall of %s (device %d) ignored: scene deleted in Hue since %s (Re-link Scene or "
			.. "Forget Scene)", self:entry_label(rid, entry), entry.device_id, util.date_of(entry.gone_since))
		self:send_state(rid, "recall", "inactive")
		return false
	end
	self:release_recalls(rid)
	local window = self.recall_windows[rid]
	if window then
		window.params, window.device_id = params, entry.device_id
		self:next_recall_gen(rid)  -- the answer of the PUT before it no longer reports
		self.ctx.log.debug("scenes: recall of %s (device %d) waits for the %d ms after the last one", self:entry_label(rid,
			entry), entry.device_id, scenes.RECALL_WINDOW_MS)
		return true
	end
	return self:send_recall(rid, entry, params)
end

-- The recall PUT of a registered, present scene (a time-based one's
-- activate), opening its window. Returns true (a PUT was started).
function scenes:send_recall(rid, entry, params)
	self:open_recall_window(rid)
	if is_smart(entry) then
		return self:activate(rid, entry, params)
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
	local duration = util.positive(params.duration)
	if duration then
		-- [assumed: recall.duration in ms; confirm once on hardware] Clamped as
		-- the dim and level durations are: "1e400" is inf, which no JSON body
		-- can carry (code analysis 2026-10-22, F12).
		body.recall.duration = math.floor(math.min(scenes.DIM_MAX_DURATION, duration))
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
			if not self:still_current(rid, entry, gen) then
				return  -- re-linked, forgotten, gone or superseded while the PUT was in flight
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
			self.ctx.log.warn("scenes: %s (device %d): Recall failed: %s", self:entry_label(rid, entry), entry.device_id,
				failure_text(r, "scene gone?"))
			self:send_state(rid, "recall")
		end)
	end)
	return true
end

-- HUE_SCENE_OFF for a time-based scene (docs/smart-scenes-design.md
-- Decision 5): PUT {"recall":{"action":"deactivate"}} first, so a time slot
-- starting cannot light the room again, then, on its answer, the group off
-- through ctx.group_off (deactivate alone leaves the lights on, V7), then
-- STATE: inactive when either took (the group going off ends the schedule as
-- well, V9), else the cached state. The group goes off even when the
-- deactivate failed: OFF means the lights. A later recall or OFF supersedes
-- the answer (no group off then). A gone scene reports inactive without a
-- call. Returns true when the PUT was started.
function scenes:deactivate(rid, entry)
	local gen = self:next_recall_gen(rid)
	local label = self:entry_label(rid, entry)
	if entry.state == "gone" then
		self.ctx.log.info("scenes: off for %s (device %d): scene not on the bridge; reporting inactive", label,
			entry.device_id)
		self:send_state(rid, "recall", "inactive")
		return false
	end
	self.ctx.log.info("scenes: off for %s (device %d): deactivate, then its group off", label, entry.device_id)
	local body = { recall = { action = scenes.SMART_DEACTIVATE } }
	self.ctx.http({ path = scenes.SMART_SCENE_PATH .. "/" .. rid, method = "PUT", body = body }, function(r)
		self:protect("deactivate done", function()
			if not self:still_current(rid, entry, gen) then
				return
			end
			local ended = r.ok == true
			if not ended then
				self.ctx.log.warn("scenes: %s (device %d): deactivate failed: %s; turning its group off anyway", label,
					entry.device_id, failure_text(r, "time-based scene gone?"))
			end
			local grouped = self:grouped_light_of(self:group_rid_of(rid))
			if not grouped then
				self.ctx.log.info("scenes: off for %s (device %d): its group has no grouped_light", label, entry.device_id)
			elseif self.ctx.group_off(grouped) then
				self.ctx.log.info("scenes: off for %s (device %d): grouped_light %s off", label, entry.device_id,
					tostring(grouped):sub(1, 8))
				ended = true
			else
				self.ctx.log.warn("scenes: off for %s (device %d): group off: nothing queued", label, entry.device_id)
			end
			local record = self.smart_catalogue[rid]
			if ended and record then
				record.state = "inactive"
			end
			self:send_state(rid, "recall", ended and "inactive" or nil)
		end)
	end)
	return true
end

-- HUE_SCENE_OFF { rid }: the scene's group grouped_light off through
-- ctx.group_off (coalesced per group by the driver), then STATE inactive. A
-- group without a grouped_light (an empty zone), an unknown group or a gone
-- scene report inactive without a call. A time-based scene is deactivated
-- first (scenes:deactivate). Returns true when group_off was called (for a
-- time-based scene: when the deactivate PUT was started).
function scenes:off(params)
	params = params or {}
	local rid, entry = self:entry_for_command(params, "HUE_SCENE_OFF")
	if not rid then
		return false
	end
	self:drop_waiting_recall(rid)
	self:release_recalls(rid)
	if is_smart(entry) then
		return self:deactivate(rid, entry)
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
-- ends it [verified on hardware 2026-10-23: Hue accepts `dimming_delta` with
-- `dynamics` and the `stop` action on a grouped_light]. No STATE is sent. The
-- same for a time-based scene: a whole-room dim leaves it running (V11,
-- docs/smart-scenes-design.md Decision 6). Returns true when queued.
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
	local scene = self:record_of(rid)
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
	self:release_recalls()  -- a recall still waiting goes before the dim
	if self.ctx.group_dim(grouped, body) ~= true then
		self.ctx.log.warn("scenes: dim of %s (device %d): nothing queued", self:entry_label(rid, entry), entry.device_id)
		return false
	end
	return true
end

-- HUE_SCENE_LEVEL { rid, device_id, level, rate }: the scene's slider while
-- it is on (docs/scene-dimmer-design.md). Moves the scene's group to `level`
-- (clamped to 1..100) over `rate` ms (clamped to 0..DIM_MAX_DURATION,
-- default 0) keeping its lights' differences: a relative dimming_delta up or
-- down by |level - current| (2 decimals) through ctx.group_dim, where
-- current is the bridge's last known group level (group_level); nothing when
-- the difference is under LEVEL_MIN_DELTA. With no level known, an absolute
-- brightness through ctx.group_set instead. No STATE is sent (the level
-- reports follow from the stream). The same for a time-based scene (the next
-- time slot's look replaces the level when it starts; Decisions 4 and 6 of
-- docs/smart-scenes-design.md). Returns true when queued.
function scenes:level(params)
	params = params or {}
	local rid, entry = self:entry_for_command(params, "HUE_SCENE_LEVEL")
	if not rid then
		return false
	end
	local level = tonumber(params.level)
	if not level or level ~= level then
		self.ctx.log.warn("scenes: level of %s (device %d) ignored: bad level %s", self:entry_label(rid, entry),
			entry.device_id, tostring(params.level))
		return false
	end
	level = math.max(1, math.min(100, level))
	local scene = self:record_of(rid)
	if entry.state == "gone" or not scene then
		self.ctx.log.warn("scenes: level of %s (device %d) ignored: scene not on the bridge", self:entry_label(rid, entry),
			entry.device_id)
		return false
	end
	local grouped = self:grouped_light_of(scene.group_rid)
	if not grouped then
		self.ctx.log.warn("scenes: level of %s (device %d) ignored: its group has no grouped_light",
			self:entry_label(rid, entry), entry.device_id)
		return false
	end
	local rate = tonumber(params.rate)
	if not rate or rate ~= rate then
		rate = 0
	end
	rate = math.floor(math.max(0, math.min(scenes.DIM_MAX_DURATION, rate)))
	local current = self.group_level[grouped]
	local queued
	if type(current) == "number" then
		local difference = level - current
		if math.abs(difference) < scenes.LEVEL_MIN_DELTA then
			self.ctx.log.debug("scenes: level %s for %s (device %d): the group is at %s; nothing to do", level_text(level),
				self:entry_label(rid, entry), entry.device_id, level_text(current))
			return false
		end
		self:release_recalls()  -- a recall still waiting goes before the move
		local action = difference > 0 and "up" or "down"
		local delta = round2(math.abs(difference))
		if self.ctx.log.enabled("info") then   -- a slider drag sends several of these a second
			self.ctx.log.info("scenes: level %s for %s (device %d): grouped_light %s %s by %s over %d ms",
				level_text(level), self:entry_label(rid, entry), entry.device_id, tostring(grouped):sub(1, 8), action,
				level_text(delta), rate)
		end
		queued = self.ctx.group_dim(grouped, { dimming_delta = { action = action, brightness_delta = delta },
			dynamics = { duration = rate } })
	else
		if self.ctx.log.enabled("info") then
			self.ctx.log.info("scenes: level %s for %s (device %d): group level unknown; grouped_light %s brightness "
				.. "over %d ms", level_text(level), self:entry_label(rid, entry), entry.device_id,
				tostring(grouped):sub(1, 8), rate)
		end
		self:release_recalls()
		queued = self.ctx.group_set(grouped, { brightness = level, rate = rate })
	end
	if queued ~= true then
		self.ctx.log.warn("scenes: level of %s (device %d): nothing queued", self:entry_label(rid, entry), entry.device_id)
		return false
	end
	-- Assume the target until Hue reports, so a second slider move made
	-- before that report is measured from where the first one goes.
	self.group_level[grouped] = level
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
		self:clear_forgotten(device_id)  -- a registered device is never a forgotten one
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

-- The rids a create_scenes batch registered (its `created` list), for the
-- reconcile that follows it to leave alone.
function scenes.created_rids(created)
	local rids = {}
	for _, c in ipairs(created or {}) do
		rids[#rids + 1] = c.scene.rid
	end
	return rids
end

-- Actions (§4) -------------------------------------------------------------------

-- Resolve the room an add goes to. Returns room_id, room_name or nil, text.
function scenes:room_for_add(scene, room_id, rooms)
	room_id = util.positive(room_id)
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
		return nil, string.format("Not added: %s: %s; pick a room, or Set Room Mapping first", util.sanitise(name_of(scene)),
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
	local scene = self:record_of(rid)
	if not scene then
		done(false, string.format("Not added: scene %s is not on the bridge (Refresh Scenes and try again)", tostring(rid)))
		return false
	end
	local room_name
	room_id, room_name = self:room_for_add(scene, room_id, self.project:rooms())
	if not room_id then
		done(false, room_name)
		return false
	end

	self.adding, self.adding_since = true, os.time()
	local label = util.sanitise(name_of(scene))
	self:create_scenes({ { scene = scene, room_id = room_id, room_name = room_name } }, function(created, _, err)
		self.adding = false
		self:reconcile(true, scenes.created_rids(created))
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
-- group into its mapped room, one AddDevice at a time, the time-based ones
-- after the ordinary ones, each with its kind (docs/smart-scenes-design.md
-- Decision 9); tombstoned ones are listed. No GET first: the catalogues
-- follow the stream (Refresh Scenes exists for doubt). done(ok, text) once,
-- at the end.
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
	local label = util.sanitise(self:group_label(group_rid))
	local all = self:scenes_of_group(group_rid)
	local plain_count = #all
	for _, record in ipairs(self:scenes_of_group(group_rid, true)) do
		all[#all + 1] = record
	end
	if #all == 0 then
		done(false, string.format("Not added: %s has no scenes", label))
		return false
	end
	local rooms = self.project:rooms()
	local room_id, why = self:default_room(all[1], rooms)
	if not room_id then
		done(false, string.format("Not added: %s; Set Room Mapping first", why))
		return false
	end
	local room_name = why
	local jobs, deleted, imported, tombs = {}, {}, 0, self.reg:tombstones()
	for _, scene in ipairs(all) do
		local tomb = tombs[scene.rid]
		if self.registry[scene.rid] then
			imported = imported + 1
		elseif tomb then
			deleted[#deleted + 1] = string.format("%s (deleted %s)", util.sanitise(name_of(scene)),
				util.date_of(tomb.deleted_at))
		else
			jobs[#jobs + 1] = { scene = scene, room_id = room_id, room_name = room_name }
		end
	end

	local function summary(created, failed, err)
		local parts = {}
		if #created > 0 then
			local names = {}
			for _, c in ipairs(created) do
				names[#names + 1] = string.format("%s (device %d)", util.sanitise(name_of(c.scene)), c.device_id)
			end
			parts[#parts + 1] = string.format("Added %s of %s to %s: %s", util.plural(#created, "scene"), label, room_name,
				table.concat(names, ", "))
		elseif #jobs == 0 and #deleted == 0 and plain_count == #all then
			parts[#parts + 1] = string.format("No new scenes in %s (%d on bridge, %d imported)", label, #all, imported)
		elseif #jobs == 0 and #deleted == 0 then
			parts[#parts + 1] = string.format("No new scenes in %s (%d scenes and %d time-based on bridge, %d imported)",
				label, plain_count, #all - plain_count, imported)
		else
			parts[#parts + 1] = "Added no scenes"
		end
		if #failed > 0 then
			local names = {}
			for _, scene in ipairs(failed) do
				names[#names + 1] = util.sanitise(name_of(scene))
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
		self:reconcile(true, scenes.created_rids(created))
		self:flush()
		local text = summary(created, failed, err)
		self.ctx.log.always("scenes: %s", text)
		self:protect("add_all_of_group done", done, err == nil and #failed == 0, text)
		self:run_pending_resync()
	end)
	return true
end

-- Re-link Scene: the entry keeps its device, proxy, programming and name and
-- swaps the rid; the device hears its new configuration and state. Either
-- kind to either kind: the entry takes the new scene's kind and CONFIGURE
-- carries it (docs/smart-scenes-design.md Decision 12). ok, text.
function scenes:relink(device_id, new_rid)
	local busy = self:busy_text()
	if busy then
		return false, busy
	end
	device_id = util.positive(device_id)
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
	local scene = self:record_of(new_rid)
	if not scene then
		return false, string.format("Not re-linked: scene %s is not on the bridge (Refresh Scenes and try again)",
			tostring(new_rid))
	end
	local old_label = self:entry_label(old_rid, entry)
	local fields = self:fields_from_scene(scene)
	fields.name_dismissed = registry.CLEAR
	fields.kind = fields.kind or registry.CLEAR
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

-- The unimported scenes of either kind whose Hue name, base name (a
-- time-based one's) or creation name matches one of `names`.
function scenes:match_unimported_by_name(names)
	local wanted = {}
	for _, name in ipairs(names) do
		if name ~= nil and util.norm(name) ~= "" then
			wanted[util.norm(name)] = true
		end
	end
	local out = {}
	for _, scene in ipairs(self:unimported_scenes()) do
		if wanted[util.norm(scene.name)] or wanted[util.norm(name_of(scene))]
			or wanted[util.norm(self:creation_name(scene))] then
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
-- HUE_SCENE_HELLO when the project lookup is unavailable. A device Forget
-- Scene let go is a candidate like any other (the owner's click is the way
-- back, #47 F8), by the rid it had. Returns the text.
function scenes:link_devices()
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local bound, why = self.project:bound_set()
	if not bound and why == "unknown" then
		-- Director answers nil when nothing is bound [verified: API 32/_3]; an
		-- action that only adds may read it so (bridge/project.lua).
		bound = {}
	end
	if not bound then
		return "Not linked: the bound-device lookup failed (see the Lua output)"
	end
	local present = self.project:devices_of(scenes.SCENE_DRIVER)
	local ids, total = {}, 0
	for id in pairs(bound) do
		local n = util.positive(id)
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
		names[id] = self.project:display_name(id)
		if names[id] then
			shared[util.norm(names[id])] = (shared[util.norm(names[id])] or 0) + 1
		end
	end

	local linked, problems = {}, {}
	for _, id in ipairs(ids) do
		local hello = self.announced[id] or self.forgotten[id] or {}
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
				local record = self:record_of(rid)
				linked[#linked + 1] = string.format("%s to %s by its rid%s", who,
					record and self:scene_label(record) or self:entry_label(rid, entry),
					record and "" or (entry.state == "gone" and " (not on the bridge: marked gone)" or ""))
				self:answer_hello(rid)
			else
				problems[#problems + 1] = string.format("%s: could not register %s (see the Lua output)", who, rid)
			end
		elseif names[id] and shared[util.norm(names[id])] > 1 then
			problems[#problems + 1] = string.format("%s: %d bound devices share that name; rename one in Composer and run "
				.. "Link Devices again", who, shared[util.norm(names[id])])
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
		parts[#parts + 1] = string.format("Linked %s: %s", util.plural(#linked, "scene device"), table.concat(linked, ", "))
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
-- scene is listed under Add Scene again. The device is remembered
-- (FORGOTTEN_KEY): a later hello from it, whether its unbind failed or it was
-- bound again, is answered HUE_SCENE_FORGOTTEN and never adopted; Link
-- Devices brings it back (#47 F8). Returns ok, text.
function scenes:forget(device_id)
	local busy = self:busy_text()
	if busy then
		return false, busy
	end
	device_id = util.positive(device_id)
	if not device_id then
		return false, "Not forgotten: pick a device first"
	end
	local rid, entry = self.reg:by_device(device_id)
	if not rid then
		return false, string.format("Not forgotten: device %d is not a registered scene", device_id)
	end
	local label = self:entry_label(rid, entry)
	local told = is_smart(entry) and name_of(entry) or entry.name
	self.reg:forget(rid)
	self:mark()
	self:remember_forgotten(device_id, rid, told, entry)
	self.last_configure[rid] = nil
	self.conflicts[rid] = nil
	self:clear_conflicts_for(device_id)
	self.announced[device_id] = nil
	self.ctx.send(device_id, "HUE_SCENE_FORGOTTEN", { rid = rid, name = told })
	local ok, err = self.project:call("unbind", device_id)
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
	local device_id = util.positive(params.device_id)
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
			local current = self.project:display_name(entry.proxy_id or entry.device_id)
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
			local current = self.project:display_name(entry.proxy_id or entry.device_id)
			if current and current ~= expected then
				if not entry.proxy_id then
					skipped[#skipped + 1] = string.format("%s (device %d): no proxy id known", current, entry.device_id)
				else
					local ok, err = self.project:call("rename", entry.proxy_id, expected)
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
			parts[#parts + 1] = string.format("Renamed %s: %s", util.plural(#renamed, "scene device"),
				table.concat(renamed, ", "))
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
		text = string.format("Accepted %s: %s", util.plural(#accepted, "scene name difference"), table.concat(accepted, ", "))
	end
	self.ctx.log.always("scenes: %s", text)
	return text
end

-- Texts ---------------------------------------------------------------------------

-- The Scenes property: "125 scenes and 15 time-based on bridge, 3 imported,
-- 0 missing, 0 unbound, 0 deleted", the devices of both kinds counted
-- together (docs/smart-scenes-design.md Decision 14); "?" time-based until a
-- /smart_scene GET has succeeded; "<n> imported" before the first GET.
function scenes:summary()
	if not self.synced then
		return string.format("%d imported", self:count())
	end
	local c = self.reg:counts()
	-- Short enough for Composer's value column (about 75 characters, no
	-- wrapping): missing and unbound appear only when not zero; Attention
	-- lists them then.
	local parts = {
		string.format("%d + %s time-based on bridge", self:bridge_count(),
			self.smart_synced and tostring(self:smart_count()) or "?"),
		string.format("%d imported", self:count()),
	}
	if c.gone > 0 then
		parts[#parts + 1] = string.format("%d missing", c.gone)
	end
	if c.unbound > 0 then
		parts[#parts + 1] = string.format("%d unbound", c.unbound)
	end
	parts[#parts + 1] = string.format("%d deleted", c.tombstones)
	return table.concat(parts, ", ")
end

-- The Attention items (driver.lua joins them after the lights'): missing
-- scenes, unbound scene devices, two devices claiming one scene, name
-- differences.
function scenes:attention_items()
	local items = {}

	local gone = self.reg:rids("gone")
	if #gone > 0 then
		local names = {}
		for _, rid in ipairs(gone) do
			local entry = self.registry[rid]
			names[#names + 1] = string.format("%s (device %d, since %s)", self:entry_label(rid, entry), entry.device_id,
				util.date_of(entry.gone_since))
		end
		items[#items + 1] = string.format("%s missing from the bridge: %s (Re-link Scene or Forget Scene)",
			util.plural(#gone, "scene"), util.some(names, scenes.MAX_NAMED))
	end

	local unbound = self.reg:rids("unbound")
	if #unbound > 0 then
		local names = {}
		for _, rid in ipairs(unbound) do
			local entry = self.registry[rid]
			names[#names + 1] = string.format("%s (device %d)", self:entry_label(rid, entry), entry.device_id)
		end
		items[#items + 1] = string.format("%s: %s (bind it to this bridge in Composer, or Forget Scene)",
			util.plural(#unbound, "unbound scene device"), util.some(names, scenes.MAX_NAMED))
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
		elseif self:record_of(rid) then
			label = self:scene_label(self:record_of(rid))
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
			#diffs == 1 and "s" or "", util.some(names, scenes.MAX_NAMED))
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

-- The base names of the time-based scenes whose time slots target each
-- scene: { [scene rid] = "Golden hours, Natural light" } (distinct, name
-- order), for the picker's "(in …)" mark (docs/smart-scenes-design.md
-- Decision 8).
function scenes:slot_owners()
	local sets = {}
	for _, record in pairs(self.smart_catalogue) do
		for _, slot in ipairs(type(record.slots) == "table" and record.slots or {}) do
			if type(slot) == "table" and slot.target_rid ~= nil then
				sets[slot.target_rid] = sets[slot.target_rid] or {}
				sets[slot.target_rid][util.sanitise(name_of(record))] = true
			end
		end
	end
	local out = {}
	for target, set in pairs(sets) do
		local names = {}
		for name in pairs(set) do
			names[#names + 1] = name
		end
		table.sort(names, function(a, b)
			if a:lower() ~= b:lower() then
				return a:lower() < b:lower()
			end
			return a < b
		end)
		out[target] = table.concat(names, ", ")
	end
	return out
end

-- Add Scene / Re-link's Scene: the unimported scenes of both kinds as
-- "Kitchen: Relax", grouped by group label, the time-based ones first
-- ("Kitchen: Golden hours (time-based)"), then name; dynamic ones suffixed,
-- the slot scenes of time-based ones marked "(in Golden hours)"; tombstoned
-- last.
function scenes:picker_scenes()
	if not self.synced then
		return util.empty_list("(no scenes fetched yet; connect the event stream)")
	end
	local owners = self:slot_owners()
	local plain, deleted = {}, {}
	for _, scene in ipairs(self:unimported_scenes()) do
		local text = self:scene_label(scene, true)
		if not is_smart(scene) and owners[scene.rid] then
			text = text .. " (in " .. owners[scene.rid] .. ")"
		end
		local tomb = self.reg:tombstones()[scene.rid]
		if tomb then
			deleted[#deleted + 1] = { text = string.format("%s (deleted from Composer %s)", text, util.date_of(tomb.deleted_at)),
				value = scene.rid }
		else
			plain[#plain + 1] = { text = text, value = scene.rid }
		end
	end
	for _, item in ipairs(deleted) do
		plain[#plain + 1] = item
	end
	if #plain == 0 then
		return util.empty_list("(every scene on the bridge is imported)")
	end
	return plain
end

-- Add All Scenes Of Room's Hue Room: the groups that have scenes of either
-- kind, with their mapping and counts: "Kitchen → Kitchen (7 scenes)",
-- "Attic (zone) → (unmapped) (2 scenes, 1 imported)", "Downstairs (zone) →
-- (unmapped) (16 scenes, 2 time-based)" (docs/smart-scenes-design.md
-- Decision 8; imported counts both kinds).
function scenes:picker_groups()
	if not self.synced then
		return util.empty_list("(no scenes fetched yet; connect the event stream)")
	end
	local rooms = self.project:rooms()
	local counts, smart, imported, records = {}, {}, {}, {}
	local function tally(catalogue, into)
		for rid, scene in pairs(catalogue) do
			local g = scene.group_rid
			if g then
				into[g] = (into[g] or 0) + 1
				records[g] = records[g] or scene  -- any record of the group: the label's fallback (its type)
				if self.registry[rid] then
					imported[g] = (imported[g] or 0) + 1
				end
			end
		end
	end
	tally(self.catalogue, counts)
	tally(self.smart_catalogue, smart)
	for group_rid in pairs(smart) do
		counts[group_rid] = counts[group_rid] or 0
	end
	local list = {}
	for group_rid, n in pairs(counts) do
		local label = self:group_label(group_rid, records[group_rid])
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
		local text = util.plural(n, "scene")
		if (smart[group_rid] or 0) > 0 then
			text = text .. string.format(", %d time-based", smart[group_rid])
		end
		if (imported[group_rid] or 0) > 0 then
			text = text .. string.format(", %d imported", imported[group_rid])
		end
		list[#list + 1] = { text = string.format("%s → %s (%s)", util.sanitise(label), util.sanitise(target), text),
			value = group_rid, key = label:lower() }
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
		return util.empty_list("(no scenes on the bridge)")
	end
	return list
end

-- "Kitchen: Relax" for an entry, "Kitchen: Golden hours (time-based)" for a
-- time-based one: how the device pickers name a registered scene.
function scenes:entry_picker_label(rid, entry)
	return util.sanitise(self:group_label(entry.group_rid, entry)) .. ": " .. self:entry_label(rid, entry)
		.. (is_smart(entry) and " (time-based)" or "")
end

-- Re-link's Device: the gone and unbound entries.
function scenes:picker_relink_devices()
	local list = {}
	for _, state in ipairs({ "gone", "unbound" }) do
		for _, rid in ipairs(self.reg:rids(state)) do
			local entry = self.registry[rid]
			-- Labelled like Forget Scene's picker, group first, so the two read alike.
			list[#list + 1] = { text = string.format("%s (device %d, %s since %s)", self:entry_picker_label(rid, entry),
				entry.device_id, state, util.short_date_of(entry[state .. "_since"])), value = tostring(entry.device_id) }
		end
	end
	if #list == 0 then
		return util.empty_list("(no gone or unbound scene devices)")
	end
	return list
end

-- Forget Scene's Device: every entry, as "Kitchen: Relax (device 2061)".
function scenes:picker_forget_devices()
	local list = {}
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		local text = string.format("%s (device %d)", self:entry_picker_label(rid, entry), entry.device_id)
		if entry.state ~= "linked" then
			text = text .. " " .. entry.state
		end
		list[#list + 1] = { text = text, value = tostring(entry.device_id) }
	end
	if #list == 0 then
		return util.empty_list("(no registered scenes)")
	end
	return list
end

-- Lists (the drop-down properties) ----------------------------------------------

-- The state a list line ends in for a registry entry (the lights' wording):
-- " → device N" linked, " (missing; device N)" gone, " (unbound; device N)".
local function entry_suffix(entry)
	if entry.state == "gone" then
		return string.format(" (missing; device %d)", entry.device_id)
	elseif entry.state == "unbound" then
		return string.format(" (unbound; device %d)", entry.device_id)
	end
	return string.format(" → device %d", entry.device_id)
end

-- The Scenes drop-down (the row shows summary()): one line per scene on the
-- bridge of either kind, "<Hue room>: <scene>" labelled and ordered as the
-- Add Scene picker does (by group label, the time-based ones first in their
-- group, then name), " (time-based)" for a time-based scene, " (in
-- <schedule>)" for a scene a time-based one's slot targets, then the state:
-- " → device N" imported, " (deleted from Composer <date>)" a tombstone,
-- " (unbound; device N)"; an unimported scene carries no mark (Hue keeps
-- about seven per room). The registered scenes the bridge lacks follow
-- under the group they remember as "(missing; device N)". Commas become "‚"
-- (U+201A): the list is comma-delimited (driver.lua's
-- refresh_room_mappings). Before the first GET, the registry alone: what is
-- known. Empty when nothing is.
function scenes:list_items()
	local owners = self:slot_owners()
	local tombs = self.reg:tombstones()
	local rows = {}
	local function row(x, rid, suffix)
		local label, name, smart = self:group_label(x.group_rid, x), name_of(x), is_smart(x)
		local text = label .. ": " .. name
		if smart then
			text = text .. " (time-based)"
		elseif owners[rid] then
			text = text .. " (in " .. owners[rid] .. ")"
		end
		rows[#rows + 1] = { group = label:lower(), smart = smart, name = name:lower(), rid = tostring(rid),
			text = text .. suffix }
	end
	for _, catalogue in ipairs({ self.catalogue, self.smart_catalogue }) do
		for rid, record in pairs(catalogue) do
			local entry, tomb = self.registry[rid], tombs[rid]
			local suffix = ""
			if entry then
				suffix = entry_suffix(entry)
			elseif tomb then
				suffix = string.format(" (deleted from Composer %s)", util.date_of(tomb.deleted_at))
			end
			row(record, rid, suffix)
		end
	end
	for rid, entry in pairs(self.registry) do
		if not self:record_of(rid) then
			row(entry, rid, entry_suffix(entry))
		end
	end
	table.sort(rows, function(a, b)
		if a.group ~= b.group then
			return a.group < b.group
		end
		if a.smart ~= b.smart then
			return a.smart
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.rid < b.rid
	end)
	local out = {}
	for i, r in ipairs(rows) do
		out[i] = (r.text:gsub(",", "‚"))
	end
	return out
end

return scenes
