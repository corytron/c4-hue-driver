-- The Hue zones and rooms a bridge represents as Control4 light devices
-- (hue_light.c4z with kind "group"; docs/zone-light-design.md): the zone-light
-- registry (bridge.registry under its own keys), the flows that keep those
-- devices current (the grouped_light GET of a resync, stream items, hello),
-- the HUE_SET / HUE_DIM commands routed to the grouped_light queue, and the
-- owner-facing actions, texts and pickers of the contract's §4, §5 and §8.
-- It mirrors bridge/scenes.lua shape for shape, with the lights' texts where
-- the contract says to follow them.
--
-- A group device is a light_v2 dimmer whose on state and level are the
-- grouped_light's `on.on` and `dimming.brightness` (Decision 3), whose
-- capabilities are the union of its member lights' (Decision 7) and whose
-- colour is derived from the member lights the lights module already caches
-- (Decision 8): `lights.models` is kept current by the stream for every light
-- the last GET brought, imported or not, and the coordinator runs this
-- module's on_container after lights:on_container, so the models are fresh
-- when the derivation runs. The registry key is the zone/room rid; the
-- grouped_light rid is resolved live (the lights' group cache first, then the
-- owners seen in GET /grouped_light and `add` items, minus the ones a `delete`
-- item removed), so an emptied-and-refilled zone needs no re-link
-- (Decision 11), even when the zone's event does not carry its services.
--
-- Every C4 call goes through ctx so the module runs on plain tables in specs;
-- each ctx field defaults to the real call, as lights.lua does, so the driver
-- only has to supply `http`, `lights`, `group_set` and `group_dim`. The project
-- calls (ctx.project.*) are pcall-wrapped: a failed lookup reads as "unknown".
--
-- What this module never does (§4 of the contract): create a device from an
-- event, an import or a resync; remove, move or rename one without a click.
-- A zone deleted in Hue keeps its device as "gone"; Re-link Zone Light
-- and Forget Light are the exits, exactly as for lights.
--
-- Callback rules inherited from lights.lua: the GET runs from an http
-- callback; on_container runs inside OnBodyChunk and only sends messages;
-- every callback body is pcall-wrapped.
--
-- Persistence: the registry's mutators change memory only; this module marks
-- itself dirty and saves once per batch, except during device creation, where
-- it saves right after the AddDevice.

local log = require("common.log")
local hue_model = require("bridge.hue_model")
local registry = require("bridge.registry")
local groups = require("bridge.groups")
local lights = require("bridge.lights")   -- ids_from / dump only: the AddDevice callback shapes
local util = require("bridge.util")
local project = require("bridge.project")

local zone_lights = {}
zone_lights.__index = zone_lights

zone_lights.REGISTRY_KEY = "hue_zone_lights"
zone_lights.TOMBSTONES_KEY = "hue_zone_light_tombstones"
zone_lights.LIGHT_DRIVER = "hue_light.c4z"
zone_lights.BINDING = 1
zone_lights.BINDING_CLASS = "HUE_BRIDGE"
zone_lights.MAX_NAMED = 3
zone_lights.GROUPED_LIGHT_PATH = "/clip/v2/resource/grouped_light"
-- What HUE_CONFIGURE and HUE_HELLO carry for a group device.
zone_lights.KIND = "group"
-- HUE_DIM duration bounds (ms) and the default when none is given.
zone_lights.DIM_MAX_DURATION = 6000000
zone_lights.DIM_DEFAULT_DURATION = 5000
-- The group types a device can stand for (Decision 1: never the bridge_home).
zone_lights.GROUP_TYPES = { zone = true, room = true }

-- ctx fields (all but http optional; lights, group_set and group_dim should be given):
--   http(req, cb)            req = { path, method, body }; the driver adds ip and key; cb(result)
--   send(id, cmd, params)    C4:SendToDevice(id, cmd, params)
--   add_device(driver, room_id, name, cb)   C4:AddDevice; cb(device_id, info)
--   bind(bridge_id, device_id)              C4:Bind(bridge_id, 1, device_id, 1, "HUE_BRIDGE")
--   persist_get / persist_set               C4:PersistGetValue / SetValue
--   bridge_id                number; default C4:GetDeviceID()
--   now, log                 os.time / common.log look-alikes
--   project                  the project calls of docs/import-design.md §13 (defaults as lights.lua)
--   lights                   the bridge.lights instance: its live `groups` cache, `models`, `devices`,
--                            `groups_loaded`, `reg:room_mapping()`
--   groups                   a bridge.groups cache, read only when no lights instance is given (specs)
--   group_set(grouped_light_rid, fields)   the coalesced absolute grouped_light PUT of driver.lua,
--                            fields { on, brightness, x, y, mirek, rate } as HUE_SET maps them; true when queued
--   group_dim(grouped_light_rid, body, level)   the coalesced grouped_light dimming_delta PUT of driver.lua
--                            (docs/keypad-design.md); `level` (number or nil) is the device's estimate sent
--                            with a stop, for the queue's fallback should the bridge refuse it; true when queued
function zone_lights.new(ctx)
	ctx = ctx or {}
	assert(type(ctx.http) == "function", "zone_lights.new: ctx.http is required")
	ctx.send = ctx.send or function(id, command, params)
		C4:SendToDevice(id, command, params)
	end
	ctx.add_device = ctx.add_device or function(driver, room_id, name, cb)
		C4:AddDevice(driver, room_id, name, cb)
	end
	ctx.bind = ctx.bind or function(bridge_id, device_id)
		C4:Bind(bridge_id, zone_lights.BINDING, device_id, zone_lights.BINDING, zone_lights.BINDING_CLASS)
	end
	ctx.persist_get = ctx.persist_get or function(name)
		return C4:PersistGetValue(name)
	end
	ctx.persist_set = ctx.persist_set or function(name, value)
		C4:PersistSetValue(name, value)
	end
	ctx.log = ctx.log or log
	ctx.now = ctx.now or os.time
	ctx.group_set = ctx.group_set or function(grouped_light_rid)
		ctx.log.warn("zone_lights: no group_set in ctx; grouped_light %s not set", tostring(grouped_light_rid))
		return false
	end
	ctx.group_dim = ctx.group_dim or function(grouped_light_rid)
		ctx.log.warn("zone_lights: no group_dim in ctx; grouped_light %s not dimmed", tostring(grouped_light_rid))
		return false
	end
	project.defaults(ctx, zone_lights.BINDING)

	local reg = registry.new({
		persist_get = ctx.persist_get, persist_set = ctx.persist_set, now = ctx.now, log = ctx.log,
		keys = { lights = zone_lights.REGISTRY_KEY, tombstones = zone_lights.TOMBSTONES_KEY, rooms = false },
	})
	return setmetatable({
		ctx = ctx,
		reg = reg,
		project = project.new(ctx, "zone_lights"),  -- the pcall-wrapped project calls
		registry = reg:entries(),  -- group rid → entry, the live table (identity kept across load())
		group_state = {},          -- grouped_light rid → hue_model.grouped_light() record, from the GET and the stream
		owners = {},               -- group rid → grouped_light rid, from the GET and `add` items (memory only)
		gone_grouped = {},         -- grouped_light rid → true after a `delete` item, until it is seen again
		last_configure = {},       -- rid → signature of the last HUE_CONFIGURE sent
		color_sent = {},           -- rid → signature of the colour last sent in HUE_STATE ("" for none)
		online_sent = {},          -- rid → the `online` text last sent
		announced = {},            -- device_id → { rid, name, kind } from HUE_HELLO, for Link Devices
		conflicts = {},            -- rid → { holder = device_id, claimant = device_id }
		early_hellos = {},         -- hellos received before load(), answered after configure_all()
		loaded = false,
		synced = false,            -- a GET /grouped_light has succeeded (the groups' on/off and level are known)
		dirty = false,
		configured_once = false,
		adding = false,            -- Add Zone Light running
		resyncing = false,
		resync_pending = nil,
		device_info_logged = false,
	}, zone_lights)
end

-- Helpers ------------------------------------------------------------------

function zone_lights:bridge_id()
	return self.ctx.bridge_id or C4:GetDeviceID()
end

function zone_lights:protect(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		self.ctx.log.error("zone_lights: %s failed: %s", what, tostring(err))
	end
	return ok, err
end

local function copy_caps(caps)
	if type(caps) ~= "table" then
		return nil
	end
	return {
		has_color = caps.has_color == true or caps.has_color == "true",
		has_cct = caps.has_cct == true or caps.has_cct == "true",
		mirek_min = tonumber(caps.mirek_min),
		mirek_max = tonumber(caps.mirek_max),
		min_dim = tonumber(caps.min_dim) or 1,
	}
end

local function same_caps(a, b)
	if a == nil or b == nil then
		return a == b
	end
	return a.has_color == b.has_color and a.has_cct == b.has_cct and a.mirek_min == b.mirek_min
		and a.mirek_max == b.mirek_max and a.min_dim == b.min_dim
end

-- "zone" / "room" for a known group type, nil otherwise.
local function type_word(gtype)
	if zone_lights.GROUP_TYPES[gtype] then
		return gtype
	end
	return nil
end

-- "Bedside Lights (zone)" / "Master Bedroom (room)": how every owner-facing
-- text names a group or an entry; the bare name when the type is unknown.
local function label_of(name, gtype)
	local text = util.sanitise(name or "?")
	local word = type_word(gtype)
	if word then
		return text .. " (" .. word .. ")"
	end
	return text
end

-- Registry access ---------------------------------------------------------------

function zone_lights:load()
	self.reg:load()
	for rid, entry in pairs(self.registry) do
		entry.caps = copy_caps(entry.caps)
		entry.light_count = tonumber(entry.light_count)
		entry.no_lights = entry.no_lights == true or entry.no_lights == "true"
		self.ctx.log.debug("zone_lights: loaded %s (device %s, %s)", label_of(entry.name, entry.group_type),
			tostring(entry.device_id), tostring(rid))
	end
	self.loaded = true
	self.dirty = false
	return self.registry
end

function zone_lights:mark()
	self.dirty = true
end

function zone_lights:flush()
	if self.dirty then
		self.dirty = false
		self.reg:save()
	end
end

function zone_lights:save()
	self.dirty = false
	self.reg:save()
end

-- A copy of the registry entry, or nil.
function zone_lights:entry(rid)
	local entry = rid ~= nil and self.registry[rid] or nil
	if not entry then
		return nil
	end
	local out = {}
	for k, v in pairs(entry) do
		out[k] = v
	end
	out.caps = copy_caps(entry.caps)
	return out
end

function zone_lights:count()
	local n = 0
	for _ in pairs(self.registry) do
		n = n + 1
	end
	return n
end

function zone_lights:registered_rids()
	return self.reg:rids()
end

-- The registered devices as a set { [device_id] = true }: the skip set the
-- lights' Link Devices takes so it leaves the group devices alone.
function zone_lights:device_ids()
	local out = {}
	for _, entry in pairs(self.registry) do
		out[entry.device_id] = true
	end
	return out
end

-- Whether a rid names a zone or room (on the bridge, or registered here):
-- the coordinator refuses re-linking a light device to one.
function zone_lights:is_group(rid)
	return self:group_of(rid) ~= nil or (rid ~= nil and self.registry[rid] ~= nil)
end

-- The lights' caches, read live -------------------------------------------------------

-- The group cache: the lights' (replaced at every resync, so read each time),
-- else the one given to ctx (specs), else an empty one.
function zone_lights:groups()
	local l = self.ctx.lights
	if l and l.groups then
		return l.groups
	end
	if self.ctx.groups then
		return self.ctx.groups
	end
	self.empty_groups = self.empty_groups or groups.new()
	return self.empty_groups
end

-- Whether a missing group means "deleted in Hue": the lights have fetched the
-- groups in this run (a cache handed to ctx counts as fetched).
function zone_lights:groups_loaded()
	local l = self.ctx.lights
	if l then
		return l.groups_loaded == true
	end
	return self.ctx.groups ~= nil
end

-- rid → normalised light, the lights' live models (kept current by the
-- stream for every light of the last GET, imported or not).
function zone_lights:models()
	local l = self.ctx.lights
	return (l and l.models) or self.ctx.models or {}
end

-- device rid → hue_model.devices() record (a room's children are devices).
function zone_lights:devices()
	local l = self.ctx.lights
	return (l and l.devices) or self.ctx.devices or {}
end

function zone_lights:room_mapping(group_rid)
	local l = self.ctx.lights
	if group_rid and l and l.reg then
		return l.reg:room_mapping(group_rid)
	end
	return nil
end

-- The cached zone or room for a rid, or nil (unknown, or the bridge_home).
function zone_lights:group_of(rid)
	local group = self:groups():group(rid)
	if group and zone_lights.GROUP_TYPES[group.type] then
		return group
	end
	return nil
end

-- The member light rids of a cached group in the group's own order: a
-- zone's children are lights; a room's children are devices, each with its
-- light services (through the lights' device records).
function zone_lights:member_lights(group)
	local out, seen = {}, {}
	if type(group) ~= "table" then
		return out
	end
	if group.type == "zone" then
		for _, rid in ipairs(group.children or {}) do
			if (group.child_rtypes or {})[rid] == "light" and not seen[rid] then
				seen[rid] = true
				out[#out + 1] = rid
			end
		end
	elseif group.type == "room" then
		local devices = self:devices()
		for _, device_rid in ipairs(group.children or {}) do
			if (group.child_rtypes or {})[device_rid] == "device" then
				local device = devices[device_rid]
				for _, rid in ipairs(device and device.light_rids or {}) do
					if not seen[rid] then
						seen[rid] = true
						out[#out + 1] = rid
					end
				end
			end
		end
	end
	return out
end

-- The models of member rids that have one, in order.
function zone_lights:member_models(rids)
	local models, out = self:models(), {}
	for _, rid in ipairs(rids or {}) do
		if models[rid] then
			out[#out + 1] = models[rid]
		end
	end
	return out
end

-- The grouped_light rid of a group, resolved live: the cache's, unless a
-- `delete` item removed that grouped_light since; else the owner seen in
-- the last GET /grouped_light or an `add` item. nil for an unknown group or
-- one without lights (an empty zone's services array is empty [verified]).
function zone_lights:grouped_light_of(group_rid)
	if group_rid == nil then
		return nil
	end
	local group = self:groups():group(group_rid)
	local grouped = group and group.grouped_light_rid or nil
	if grouped and self.gone_grouped[grouped] then
		grouped = nil
	end
	if not grouped then
		local owned = self.owners[group_rid]
		if owned and not self.gone_grouped[owned] then
			grouped = owned
		end
	end
	return grouped
end

-- Labels ---------------------------------------------------------------------

function zone_lights.entry_label(_self, _rid, entry)
	return label_of(entry.name, entry.group_type)
end

function zone_lights.group_label(_self, group)
	return label_of(group.name, group.type)
end

-- Composer name at creation (§5 Naming): a zone's name verbatim, "<Room>
-- Lights" for a room. `record` is a cached group or an entry.
function zone_lights.creation_name(_self, record)
	local name = tostring(record.name or "?")
	local gtype = record.type or record.group_type
	if gtype == "room" then
		return name .. " Lights"
	end
	return name
end

-- The registry fields a cached group supplies.
function zone_lights:fields_from_group(group)
	if not group then
		return {}
	end
	local members = self:member_lights(group)
	return {
		name = group.name,
		group_type = group.type,
		light_count = #members,
		no_lights = self:grouped_light_of(group.rid) == nil,
		caps = hue_model.group_caps(self:member_models(members)),
		id_v1 = group.id_v1,
	}
end

-- The entry's cached name follows Hue's; the Composer device keeps its own.
function zone_lights:take_name(entry, group)
	if entry.name == group.name then
		return false
	end
	self.ctx.log.info("zone_lights: %s was renamed to %s in Hue (Composer name unchanged)", tostring(entry.name),
		tostring(group.name))
	entry.name = group.name
	return true
end

-- The identity fields of one entry from its cached group: name, type, light
-- count, no_lights, caps, id_v1. True when something changed (the caller marks).
function zone_lights:refresh_entry(rid)
	local entry, group = self.registry[rid], self:group_of(rid)
	if not entry or not group then
		return false
	end
	local changed = self:take_name(entry, group)
	local fields = self:fields_from_group(group)
	fields.name = nil
	local caps = fields.caps
	fields.caps = nil
	if not same_caps(caps, entry.caps) then
		fields.caps = caps
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

function zone_lights:refresh_registry()
	for _, rid in ipairs(self.reg:rids()) do
		if self:refresh_entry(rid) then
			self:mark()
		end
	end
end

-- Messages -----------------------------------------------------------------

-- HUE_CONFIGURE params (§5 Messages): the light fields plus kind "group",
-- group_type, light_count, no_lights, model, hue_room, id_v1, min_dim "1",
-- and state "gone" + gone_since while gone (absent while linked, as the
-- lights' are). Every value a string.
function zone_lights.configure_params(_self, rid, entry)
	local extra = {}
	if entry.state == "gone" then
		extra.state = "gone"
		extra.gone_since = entry.gone_since
	end
	return hue_model.group_configure_params(rid, entry, extra)
end

function zone_lights:send_configure(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	local params = self:configure_params(rid, entry)
	self.last_configure[rid] = util.signature(params)
	self.ctx.send(entry.device_id, "HUE_CONFIGURE", params)
	return true
end

function zone_lights:configure_changed(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	return self.last_configure[rid] ~= util.signature(self:configure_params(rid, entry))
end

-- The colour a registered group shows (Decision 8) and its signature for
-- change detection ("" when none).
function zone_lights:color_of(rid)
	local group = self:group_of(rid)
	if not group then
		return nil, ""
	end
	local color = hue_model.group_color(self:member_models(self:member_lights(group)))
	if not color then
		return nil, ""
	end
	if color.color_mode == "xy" then
		return color, "xy:" .. tostring(color.x) .. "," .. tostring(color.y)
	end
	return color, "ct:" .. tostring(color.mirek)
end

-- "true" / "false" as HUE_STATE's `online`: false while gone or while the
-- group has no grouped_light; nil while the groups are not fetched yet.
function zone_lights:online_of(rid)
	local entry = self.registry[rid]
	if not entry then
		return nil
	end
	if entry.state == "gone" then
		return "false"
	end
	if self:grouped_light_of(rid) then
		return "true"
	end
	if self:groups_loaded() then
		return "false"
	end
	return nil
end

-- Full HUE_STATE params (§5): rid, on, brightness (the group's average as
-- Hue reports it; the device rounds), x+y or mirek with color_mode, online,
-- reason. A gone group: online false alone; a group without lights: online
-- false and on false (Decision 11: the tile goes off). The second value is
-- the signature of the colour sent ("" for none), for the change detection.
function zone_lights:state_params(rid, reason)
	local entry = self.registry[rid]
	local params = { rid = rid, reason = reason or "event" }
	if entry.state == "gone" then
		params.online = "false"
		return params, ""
	end
	local grouped = self:grouped_light_of(rid)
	if not grouped then
		params.online = "false"
		params.on = "false"
		return params, ""
	end
	params.online = "true"
	local st = self.group_state[grouped]
	if st then
		if st.on ~= nil then
			params.on = tostring(st.on)
		end
		if st.brightness ~= nil then
			params.brightness = tostring(st.brightness)
		end
	end
	local color, sig = self:color_of(rid)
	if color then
		for k, v in pairs(color) do
			params[k] = tostring(v)
		end
	end
	return params, sig
end

-- Whether the bridge knows enough to tell a registered group its state: gone
-- (online false), the groups fetched and this one without lights (online
-- false), or its grouped_light's on/off known from the GET or the stream.
-- Before that a guessed state would turn a lit tile off.
function zone_lights:state_known(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	if entry.state == "gone" then
		return true
	end
	if not self:groups_loaded() then
		return false
	end
	local grouped = self:grouped_light_of(rid)
	if not grouped then
		return true
	end
	return self.synced or self.group_state[grouped] ~= nil
end

-- HUE_STATE: the full state when `fields` is nil, else rid + reason + the
-- given fields. Records what was sent for the change detection of events.
function zone_lights:send_state(rid, reason, fields)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	local params
	if fields then
		params = { rid = rid, reason = reason or "event" }
		for k, v in pairs(fields) do
			params[k] = v
		end
	else
		local sig
		params, sig = self:state_params(rid, reason)
		self.color_sent[rid] = sig
	end
	if params.online then
		self.online_sent[rid] = params.online
	end
	self.ctx.send(entry.device_id, "HUE_STATE", params)
	return true
end

-- CONFIGURE (when asked for, or when it changed) then the full STATE once
-- something is known (state_known).
function zone_lights:push(rid, reason, with_configure)
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

-- A group that left the bridge: CONFIGURE with state "gone", STATE online false.
function zone_lights:announce_gone(rid, reason)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	self:send_configure(rid)
	self.color_sent[rid] = ""
	return self:send_state(rid, reason or "event", { online = "false" })
end

-- Bridge startup, before any GET: CONFIGURE to every registered, bound group
-- device from the persisted entry, then the hellos that waited for load().
function zone_lights:configure_all()
	local n = 0
	for _, rid in ipairs(self.reg:rids()) do
		if self.registry[rid].state ~= "unbound" and self:send_configure(rid) then
			n = n + 1
		end
	end
	self.configured_once = true
	local queued = self.early_hellos
	self.early_hellos = {}
	for _, params in ipairs(queued) do
		self:protect("early hello", self.hello, self, params)
	end
	return n
end

function zone_lights:clear_conflicts_for(device_id)
	for rid, c in pairs(self.conflicts) do
		if c.holder == device_id or c.claimant == device_id then
			self.conflicts[rid] = nil
		end
	end
end

-- Configuration and (once something is known) the full state.
function zone_lights:answer_hello(rid)
	if self:state_known(rid) then
		return self:push(rid, "hello", true)
	end
	return self:send_configure(rid)
end

-- Register a bound device for a group rid the registry lacks (auto-adopt,
-- Link Devices): fields from the cached group when there is one, else what
-- the device announced; gone when the groups are fetched and lack it.
function zone_lights:adopt(device_id, rid, hello, how)
	local group = self:group_of(rid)
	local fields = self:fields_from_group(group)
	fields.device_id = device_id
	fields.name = fields.name or hello.name
	local entry, err = self.reg:add(rid, fields)
	if not entry then
		self.ctx.log.warn("zone_lights: could not adopt device %d for %s: %s", device_id, tostring(rid), tostring(err))
		return nil
	end
	self:mark()
	if not group and self:groups_loaded() then
		self.reg:set_state(rid, "gone")
	end
	self.ctx.log.always("zone_lights: adopted %s (device %d) %s", label_of(entry.name or rid, entry.group_type), device_id,
		how)
	return entry
end

-- HUE_HELLO { rid?, device_id, name?, kind? } from a group device (the
-- coordinator routes kind "group" here). The lights' rules: a known rid is
-- answered; a device registered under another rid is answered with that one;
-- a rid the registry lacks from exactly one bound device announcing kind
-- "group" is adopted; two devices claiming one rid change nothing and go to
-- Attention. Before load() the hello waits for configure_all(). Also accepts
-- hello(rid, params) as lights:hello does. Returns true when answered.
function zone_lights:hello(a, b)
	local params
	if type(a) == "table" then
		params = a
	else
		params = b or {}
		if params.rid == nil then
			params.rid = a
		end
	end
	local rid = params.rid
	if type(rid) ~= "string" or rid == "" then
		rid = nil
	end
	local device_id = util.positive(params.device_id)
	if not (self.loaded or self.synced) then
		if rid or device_id then
			self.early_hellos[#self.early_hellos + 1] = params
		end
		return false
	end
	if device_id then
		-- `model` marks a light's hello: Link Devices leaves such a device to the lights' module.
		self.announced[device_id] = { rid = rid, name = params.name, kind = params.kind, model = params.model }
	end

	local entry = rid and self.registry[rid] or nil
	if entry then
		if device_id and entry.device_id ~= device_id then
			self.conflicts[rid] = { holder = entry.device_id, claimant = device_id }
			self.ctx.log.warn("zone_lights: device %d claims %s, which device %d holds; nothing changed (see Attention)",
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
		self.ctx.log.info("zone_lights: device %d said hello with %s; its registered group is %s", device_id,
			tostring(rid), held_rid)
		return self:answer_hello(held_rid)
	end
	if not rid or params.kind ~= zone_lights.KIND then
		return false  -- a bare device, or not a group device: Link Devices or the lights' module
	end

	local bound = self.project:bound_set()
	if not bound or not bound[device_id] then
		self.ctx.log.info("zone_lights: device %d announced %s but is not bound; not adopted", device_id, rid)
		return false
	end
	for other_id, h in pairs(self.announced) do
		if other_id ~= device_id and h.rid == rid then
			self.conflicts[rid] = { holder = other_id, claimant = device_id }
			self.ctx.log.warn("zone_lights: devices %d and %d both announce %s; neither adopted (see Attention)", other_id,
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

-- HUE_GOODBYE { rid?, device_id }: the device is being deleted in Composer;
-- the entry becomes a tombstone. Returns the tombstone, or nil when the
-- device is not one of ours (the coordinator then asks the lights' module).
function zone_lights:goodbye(params)
	params = params or {}
	local device_id = util.positive(params.device_id)
	local rid = device_id and self.reg:by_device(device_id) or nil
	if not rid and type(params.rid) == "string" and self.registry[params.rid] then
		local entry = self.registry[params.rid]
		if not device_id or entry.device_id == device_id then
			rid = params.rid
		end
	end
	if not rid then
		self.ctx.log.debug("zone_lights: HUE_GOODBYE from a device that is not a zone light (%s, %s)",
			tostring(params.device_id), tostring(params.rid))
		return nil
	end
	if device_id then
		self.announced[device_id] = nil
	end
	local entry = self.registry[rid]
	local label = self:entry_label(rid, entry)
	local tomb = self.reg:tombstone(rid)
	self.last_configure[rid] = nil
	self.color_sent[rid], self.online_sent[rid] = nil, nil
	self.conflicts[rid] = nil
	self:clear_conflicts_for(entry.device_id)
	self:mark()
	self:flush()
	self.ctx.log.always("zone_lights: %s (device %d) was deleted in Composer; Add Zone Light lists it as deleted", label,
		entry.device_id)
	return tomb
end

-- OnBindingChanged for the bridge's binding 1, as lights:on_binding_changed.
function zone_lights:on_binding_changed(binding, class, bound, other_id)
	if tonumber(binding) ~= zone_lights.BINDING then
		return false
	end
	if class ~= nil and class ~= zone_lights.BINDING_CLASS then
		return false
	end
	local device_id = util.positive(other_id)
	if not device_id then
		return false
	end
	local rid, entry = self.reg:by_device(device_id)
	if not rid then
		return false  -- a light or a scene device, or one its hello or Link Devices adopts
	end
	local changed = false
	if bound == false or bound == "false" then
		if entry.state == "linked" and self.reg:set_state(rid, "unbound") then
			changed = true
			self.ctx.log.warn("zone_lights: %s (device %d) was unbound from the bridge", self:entry_label(rid, entry),
				device_id)
		end
	elseif bound == true or bound == "true" then
		if entry.state == "unbound" and self.reg:set_state(rid, "linked") then
			changed = true
			self.ctx.log.info("zone_lights: %s (device %d) is bound again", self:entry_label(rid, entry), device_id)
			self:answer_hello(rid)
		end
	end
	if changed then
		self:mark()
		self:flush()
	end
	return changed
end

-- Reconciliation ---------------------------------------------------------------

-- Step 1, the project side: the bound set and the hue_light devices in the
-- project. Saves unless `no_save`.
function zone_lights:reconcile(no_save)
	local bound = self.project:bound_set()
	if not bound then
		self.ctx.log.warn("zone_lights: reconcile skipped: the bound-device lookup failed")
		return { unbound = {}, relinked = {}, tombstoned = {} }
	end
	local infos = self.project:devices_of(zone_lights.LIGHT_DRIVER)
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
		self.ctx.log.warn("zone_lights: %s was deleted in Composer while the bridge was not watching; Add Zone Light "
			.. "lists it as deleted", tostring(tomb.name or rid))
	end
	for _, rid in ipairs(r.unbound) do
		local entry = self.registry[rid]
		self.ctx.log.warn("zone_lights: %s (device %d) is not bound to this bridge", self:entry_label(rid, entry),
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

-- Step 2, the groups: a registered rid the (fetched) group cache lacks is
-- "gone" (the device hears state gone and online false); back again is
-- "linked". Nothing is judged from a cache this run has not filled.
function zone_lights:reconcile_groups()
	for _, rid in ipairs(self.reg:rids()) do
		local entry, group = self.registry[rid], self:group_of(rid)
		if group then
			if entry.state == "gone" and self.reg:set_state(rid, "linked") then
				self:mark()
				self.ctx.log.always("zone_lights: %s (device %d) is back on the bridge", self:entry_label(rid, entry),
					entry.device_id)
			end
		elseif self:groups_loaded() and entry.state == "linked" and self.reg:set_state(rid, "gone") then
			self:mark()
			self.ctx.log.warn("zone_lights: %s (device %d) is no longer on the bridge; marked gone "
				.. "(Re-link Zone Light or Forget Light)", self:entry_label(rid, entry), entry.device_id)
			self:announce_gone(rid, "resync")
		end
	end
end

-- Step 5, the fan-out: STATE (and CONFIGURE first when asked or changed) to
-- every linked entry; a gone one hears only a changed CONFIGURE.
function zone_lights:fanout(reason, with_configure)
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

-- After a resync's GET (or its failure): steps 1, 2 and 5, one save.
function zone_lights:settle(reason, with_configure)
	self:reconcile(true)
	self:reconcile_groups()
	self:refresh_registry()
	local sent = self:fanout(reason, with_configure)
	self:flush()
	return sent
end

-- Replace the groups' on/off and level and the owner map with a GET
-- /grouped_light body's data. The GET is authoritative: a grouped_light a
-- `delete` item removed and the GET still lists is back.
function zone_lights:absorb(items)
	local group_state, owners = {}, {}
	for _, item in ipairs(items or {}) do
		local model = hue_model.grouped_light(item)
		if model then
			group_state[model.rid] = model
			if model.owner_rid then
				owners[model.owner_rid] = model.rid
			end
		end
	end
	self.group_state = group_state
	self.owners = owners
	self.gone_grouped = {}
	self.synced = true
	local n = 0
	for _ in pairs(group_state) do
		n = n + 1
	end
	self.ctx.log.debug("zone_lights: %d grouped_lights cached", n)
end

-- Resync ---------------------------------------------------------------------

-- After every stream connect, once the lights' resync has refreshed the group
-- cache (the coordinator chains it after the lights' and the scenes'), and
-- from a refresh action: GET /grouped_light, then the reconciliation and the
-- fan-out. done(ok, err, sent). Given `items` (the data array of a
-- /grouped_light body fetched moments ago: the scenes' resync hands its own
-- to its done callback) the GET is skipped and the same work runs at once.
-- A failed GET keeps the groups' on/off and level as they were but still
-- reconciles against the group cache (a zone deleted in Hue is marked gone
-- either way) and reports ok false.
function zone_lights:resync(done, items)
	done = done or function() end
	self:expire_stale_busy()
	if self.resyncing or self.adding then
		self.resync_pending = done
		return
	end
	self.resyncing, self.resyncing_since = true, os.time()
	local function finish(data, err)
		local sent = 0
		local ok, e = pcall(function()
			if data then
				self:absorb(data)
			end
			sent = self:settle("resync", not self.configured_once)
		end)
		if not ok then
			self.ctx.log.error("zone_lights: resync failed: %s", tostring(e))
		end
		self.resyncing = false
		if not ok then
			self:protect("resync done", done, false, tostring(e))
		elseif err then
			self:protect("resync done", done, false, err, sent)
		else
			self:protect("resync done", done, true, nil, sent)
		end
		self:run_pending_resync()
	end
	if type(items) == "table" then
		return finish(items)
	end
	self.ctx.http({ path = zone_lights.GROUPED_LIGHT_PATH, method = "GET" }, function(r)
		local data = r.ok and type(r.json) == "table" and r.json.data or nil
		local err
		if type(data) ~= "table" then
			data = nil
			err = string.format("GET %s: %s", zone_lights.GROUPED_LIGHT_PATH, tostring(r.err or "malformed response"))
			self.ctx.log.warn("zone_lights: %s; the groups' on/off and level stay as they were", err)
		end
		finish(data, err)
	end)
end

function zone_lights:run_pending_resync()
	local pending = self.resync_pending
	self.resync_pending = nil
	if pending then
		self:resync(pending)
	end
end

-- Event fan-out --------------------------------------------------------------

-- A grouped_light item of an event container: the cached on/off and level
-- follow it (an `add` is complete, with its owner; a `delete` forgets it and
-- remembers that it is gone until it is seen again). `carried[grouped_rid]`
-- collects the field names an update or add carried, for the STATE.
function zone_lights:on_grouped_light_item(item, kind, carried)
	local grouped = item.id
	if kind == "delete" then
		local st = self.group_state[grouped]
		self.group_state[grouped] = nil
		self.gone_grouped[grouped] = true
		for owner, g in pairs(self.owners) do
			if g == grouped then
				self.owners[owner] = nil
			end
		end
		if st and st.owner_rid then
			self.ctx.log.debug("zone_lights: grouped_light %s of group %s deleted", tostring(grouped):sub(1, 8),
				tostring(st.owner_rid):sub(1, 8))
		end
		return
	end
	self.gone_grouped[grouped] = nil
	local st = self.group_state[grouped]
	local changed
	if st then
		changed = hue_model.update_grouped_light(st, item)
	else
		st = hue_model.grouped_light(item)
		if not st then
			return
		end
		self.group_state[grouped] = st
		changed = {}
		if st.on ~= nil then
			changed[#changed + 1] = "on"
		end
		if st.brightness ~= nil then
			changed[#changed + 1] = "brightness"
		end
	end
	if st.owner_rid then
		self.owners[st.owner_rid] = grouped
	end
	local fields = carried[grouped] or {}
	for _, name in ipairs(changed) do
		fields[name] = true
	end
	carried[grouped] = fields
end

-- After a container touched something a group device shows: every
-- registered, bound entry named in `touched` (a set of group rids; nil for
-- all of them) is checked against the (already updated) group cache and
-- models. Deleted in Hue → gone and told; back → linked and told in full;
-- else a changed CONFIGURE (name, members, caps, no_lights) and one STATE
-- with what changed: the on/off and level a grouped_light item carried, the
-- derived colour when it differs from the last sent, online when it
-- flipped. Returns the number of messages sent.
function zone_lights:refresh_all(carried, touched)
	local sent = 0
	if touched and next(touched) == nil then
		return sent
	end
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		if entry.state ~= "unbound" and (touched == nil or touched[rid]) then
			local group = self:group_of(rid)
			if not group then
				if entry.state == "linked" and self:groups_loaded() and self.reg:set_state(rid, "gone") then
					self:mark()
					self.ctx.log.warn("zone_lights: %s (device %d) was deleted on the bridge; marked gone "
						.. "(Re-link Zone Light or Forget Light)", self:entry_label(rid, entry), entry.device_id)
					if self:announce_gone(rid, "event") then
						sent = sent + 1
					end
				end
			else
				local was_gone = entry.state == "gone"
				if was_gone and self.reg:set_state(rid, "linked") then
					self:mark()
					self.ctx.log.always("zone_lights: %s (device %d) is back on the bridge", self:entry_label(rid, entry),
						entry.device_id)
				end
				if self:refresh_entry(rid) then
					self:mark()
				end
				if was_gone then
					if self:push(rid, "event", true) then
						sent = sent + 1
					end
				else
					if self:configure_changed(rid) and self:send_configure(rid) then
						sent = sent + 1
					end
					local fields = {}
					local grouped = self:grouped_light_of(rid)
					local c = grouped and carried[grouped] or nil
					local st = grouped and self.group_state[grouped] or nil
					if c and st then
						if c.on and st.on ~= nil then
							fields.on = tostring(st.on)
						end
						if c.brightness and st.brightness ~= nil then
							fields.brightness = tostring(st.brightness)
						end
					end
					local color, sig = self:color_of(rid)
					if not grouped then
						color, sig = nil, ""
					end
					if sig ~= (self.color_sent[rid] or "") then
						self.color_sent[rid] = sig
						if color then
							for k, v in pairs(color) do
								fields[k] = tostring(v)
							end
						end
					end
					local online = self:online_of(rid)
					if online and online ~= self.online_sent[rid] then
						fields.online = online
						if online == "false" then
							fields.on = "false"
						end
					end
					if next(fields) and self:state_known(rid) and self:send_state(rid, "event", fields) then
						sent = sent + 1
					end
				end
			end
		end
	end
	return sent
end

-- Mark in `touched` the registered group whose grouped_light is `grouped`:
-- called before a grouped_light item is applied (a delete item forgets the
-- link) and after (an add item brings a new owner).
function zone_lights:touch_owner(touched, grouped)
	for rid in pairs(self.registry) do
		if self:grouped_light_of(rid) == grouped then
			touched[rid] = true
		end
	end
	local st = self.group_state[grouped]
	if st and st.owner_rid and self.registry[st.owner_rid] then
		touched[st.owner_rid] = true
	end
end

local NONE = {}

-- Mark in `touched` the registered groups whose members a light or device
-- item can change (the members decide the count, the caps and the colour,
-- Decisions 7 and 8): the zones listing light `light_rid` or one of
-- `light_rids` (a device's lights), the room listing device `device_rid`.
-- Membership is read from the cached groups' children, as member_lights does.
function zone_lights:touch_members(touched, light_rid, light_rids, device_rid)
	for rid, entry in pairs(self.registry) do
		if entry.state ~= "unbound" and not touched[rid] then
			local group = self:group_of(rid)
			local rtypes = group and group.child_rtypes or NONE
			if group and group.type == "room" then
				if device_rid ~= nil and rtypes[device_rid] == "device" then
					touched[rid] = true
				end
			elseif light_rid ~= nil and rtypes[light_rid] == "light" then
				touched[rid] = true
			else
				for _, l in ipairs(light_rids or NONE) do
					if rtypes[l] == "light" then
						touched[rid] = true
						break
					end
				end
			end
		end
	end
end

-- One event-stream container, run after lights:on_container (the group cache
-- and the models are current) and scenes:on_container. grouped_light items
-- update the groups' on/off and level and name the group that owns them;
-- light and device items name the registered groups holding them (the
-- members decide what a group device shows); room and zone items name
-- themselves. Only the entries named are checked (refresh_all); an item the
-- lights' cache has no record for (a deleted light or device, or one never
-- fetched) has every entry checked, as every container did before
-- 2026-10-24. Runs inside OnBodyChunk: no transfers are started here.
function zone_lights:on_container(container)
	if type(container) ~= "table" or type(container.data) ~= "table" then
		return 0
	end
	local kind = container.type
	local touched, carried, all = {}, {}, false
	for _, item in ipairs(container.data) do
		if type(item) == "table" and item.id ~= nil then
			local t = item.type
			if t == "grouped_light" then
				self:touch_owner(touched, item.id)
				self:on_grouped_light_item(item, kind, carried)
				self:touch_owner(touched, item.id)
			elseif t == "room" or t == "zone" then
				if self.registry[item.id] then
					touched[item.id] = true
				elseif kind == "add" and self:group_of(item.id) then
					self.ctx.log.debug("zone_lights: new %s %s on the bridge; Add Zone Light lists it", t,
						self:group_label(self:group_of(item.id)))
				end
			elseif t == "light" then
				local model = self:models()[item.id]
				if model then
					self:touch_members(touched, item.id, nil, model.device_rid)
				else
					all = true
				end
			elseif t == "device" then
				local device = self:devices()[item.id]
				if device then
					self:touch_members(touched, nil, device.light_rids, item.id)
				else
					all = true
				end
			end
		end
	end
	if not all and next(touched) == nil then
		return 0
	end
	local sent = self:refresh_all(carried, not all and touched or nil)
	self:flush()
	return sent
end

-- Commands from the group devices ---------------------------------------------------

-- The entry a device's command names, by rid, when it can be acted on. nil
-- with the reason logged for an unknown rid, a gone group or one without
-- lights (the device drops those itself; the bridge checks again).
function zone_lights:entry_for_command(params, what)
	params = params or {}
	local rid = params.rid
	if type(rid) ~= "string" or rid == "" then
		self.ctx.log.warn("zone_lights: %s without a rid ignored", what)
		return nil
	end
	local entry = self.registry[rid]
	if not entry then
		self.ctx.log.warn("zone_lights: %s for unregistered group %s ignored", what, rid)
		return nil
	end
	if entry.state == "gone" then
		self.ctx.log.warn("zone_lights: %s for %s (device %d) ignored: %s deleted in Hue since %s (Re-link Zone Light "
			.. "or Forget Light)", what, self:entry_label(rid, entry), entry.device_id, type_word(entry.group_type) or "group",
			util.date_of(entry.gone_since))
		return nil
	end
	local grouped = self:grouped_light_of(rid)
	if not grouped then
		self.ctx.log.warn("zone_lights: %s for %s (device %d) ignored: it has no lights; nothing to control", what,
			self:entry_label(rid, entry), entry.device_id)
		return nil
	end
	return rid, entry, grouped
end

-- HUE_SET { rid, on?, brightness?, x?, y?, mirek?, rate? } (strings): the
-- absolute body of Decision 5 on the group's grouped_light through
-- ctx.group_set (coalesced per group by the driver's group queue, which
-- builds the PUT: on, dimming.brightness, color.xy or
-- color_temperature.mirek, dynamics). ON from the device arrives as on=true
-- brightness=100 (Decision 4); a colour while off is kept by the device for
-- the next turn-on (Decision 7), so nothing is held here. Returns true when queued.
function zone_lights:set(params)
	params = params or {}
	local rid, entry, grouped = self:entry_for_command(params, "HUE_SET")
	if not rid then
		return false
	end
	local fields = {
		brightness = tonumber(params.brightness),
		x = tonumber(params.x),
		y = tonumber(params.y),
		mirek = tonumber(params.mirek),
		rate = tonumber(params.rate),
	}
	if params.on == "true" or params.on == true then
		fields.on = true
	elseif params.on == "false" or params.on == false then
		fields.on = false
	end
	if fields.on == nil and fields.brightness == nil and fields.mirek == nil and not (fields.x and fields.y) then
		self.ctx.log.warn("zone_lights: HUE_SET for %s (device %d) carries nothing to set", self:entry_label(rid, entry),
			entry.device_id)
		return false
	end
	if self.ctx.log.enabled("info") then   -- a slider drag sends several of these a second
		self.ctx.log.info("zone_lights: HUE_SET %s (device %d): grouped_light %s on=%s brightness=%s x=%s y=%s mirek=%s "
			.. "rate=%s", self:entry_label(rid, entry), entry.device_id, tostring(grouped):sub(1, 8), tostring(fields.on),
			tostring(fields.brightness), tostring(fields.x), tostring(fields.y), tostring(fields.mirek),
			tostring(fields.rate))
	end
	if self.ctx.group_set(grouped, fields) ~= true then
		self.ctx.log.warn("zone_lights: HUE_SET for %s (device %d): nothing queued", self:entry_label(rid, entry),
			entry.device_id)
		return false
	end
	return true
end

-- HUE_DIM { rid, direction = up | down | stop, duration?, level? }: a keypad
-- hold as Hue's relative dim on the grouped_light through ctx.group_dim
-- (Decision 6; verified on a grouped_light 2026-10-23): up/down run the
-- whole range over `duration` ms (clamped to 0..DIM_MAX_DURATION, default
-- DIM_DEFAULT_DURATION), stop ends it; the device's level estimate goes with
-- a stop, for the queue's fallback. No STATE is sent. Returns true when queued.
function zone_lights:dim(params)
	params = params or {}
	local rid, entry, grouped = self:entry_for_command(params, "HUE_DIM")
	if not rid then
		return false
	end
	local direction = params.direction
	if direction ~= "up" and direction ~= "down" and direction ~= "stop" then
		self.ctx.log.warn("zone_lights: HUE_DIM for %s (device %d) ignored: unknown direction %s",
			self:entry_label(rid, entry), entry.device_id, tostring(direction))
		return false
	end
	local body, level
	if direction == "stop" then
		body = { dimming_delta = { action = "stop" } }
		level = tonumber(params.level)
	else
		local duration = tonumber(params.duration)
		if not duration or duration ~= duration then
			duration = zone_lights.DIM_DEFAULT_DURATION
		end
		duration = math.floor(math.max(0, math.min(zone_lights.DIM_MAX_DURATION, duration)))
		body = { dimming_delta = { action = direction, brightness_delta = 100 }, dynamics = { duration = duration } }
	end
	self.ctx.log.info("zone_lights: HUE_DIM %s %s (device %d): grouped_light %s", self:entry_label(rid, entry), direction,
		entry.device_id, tostring(grouped):sub(1, 8))
	if self.ctx.group_dim(grouped, body, level) ~= true then
		self.ctx.log.warn("zone_lights: HUE_DIM for %s (device %d): nothing queued", self:entry_label(rid, entry),
			entry.device_id)
		return false
	end
	return true
end

-- Device creation ---------------------------------------------------------------

-- A guard whose callback never came back would read Busy for ever and park
-- every resync: it expires instead (lights.lua's rule).
local BUSY_MAX = 90

function zone_lights:expire_stale_busy()
	for _, flag in ipairs({ "adding", "resyncing" }) do
		local since = self[flag .. "_since"]
		if self[flag] and since and os.time() - since > BUSY_MAX then
			self.ctx.log.warn("zone_lights: %s stuck for %d s; cleared", flag, os.time() - since)
			self[flag] = false
		end
	end
end

function zone_lights:busy_text()
	self:expire_stale_busy()
	if self.adding then
		return "Busy: adding a zone light; try again in a moment"
	elseif self.resyncing then
		return "Busy: resyncing zone lights; try again in a moment"
	end
	return nil
end

-- One AddDevice for `job` = { group, room_id, room_name }: hue_light.c4z into
-- the room under the creation name, bound, registered (saved at once) and
-- told its configuration and state. finish(created, failed, err) as
-- lights:create_lights, with created = { { group, device_id, room_name } }.
function zone_lights:create_device(job, finish)
	local group = job.group
	local created, failed = {}, {}

	local function on_added(device_id, info)
		if not self.device_info_logged then
			self.device_info_logged = true
			self.ctx.log.always("AddDevice callback for zone light %s: deviceId=%s info=%s", tostring(group.name),
				tostring(device_id), lights.dump(info))
		end
		device_id = tonumber(device_id)
		if not device_id or device_id <= 0 then
			self.ctx.log.error("zone_lights: AddDevice failed for %s (deviceId %s); skipped", tostring(group.name),
				tostring(device_id))
			failed[#failed + 1] = group
			return
		end
		local ids = lights.ids_from(info)
		if ids.protocol and ids.protocol ~= device_id then
			self.ctx.log.always("AddDevice for %s: binding protocol id %d rather than deviceId %d", tostring(group.name),
				ids.protocol, device_id)
			device_id = ids.protocol
		end
		self.ctx.bind(self:bridge_id(), device_id)
		local fields = self:fields_from_group(group)
		fields.device_id = device_id
		fields.proxy_id = ids.proxy
		fields.created_room_id = job.room_id
		local entry, err = self.reg:add(group.rid, fields)
		if not entry then
			self.ctx.log.error("zone_lights: AddDevice created device %d for %s but the registry refused it: %s", device_id,
				tostring(group.name), tostring(err))
			failed[#failed + 1] = group
			return
		end
		self:save()
		created[#created + 1] = { group = group, device_id = device_id, room_name = job.room_name }
		self.ctx.log.info("zone_lights: added %s to %s (device %d)", self:group_label(group), tostring(job.room_name),
			device_id)
		self:push(group.rid, "resync", true)
	end

	local name = self:creation_name(group)
	self.ctx.log.info("zone_lights: adding %s to %s as %s", self:group_label(group), tostring(job.room_name), name)
	local ok, err = pcall(self.ctx.add_device, zone_lights.LIGHT_DRIVER, job.room_id, name, function(device_id, info)
		self:protect("register " .. tostring(name), on_added, device_id, info)
		finish(created, failed)
	end)
	if not ok then
		self.ctx.log.error("zone_lights: adding %s failed: %s", tostring(name), tostring(err))
		finish(created, failed, tostring(err))
	end
end

-- Actions ----------------------------------------------------------------------------

-- The Control4 room a group device goes to when the owner names none: the
-- group's own mapping (Set Room Mapping lists zones too). Returns room_id,
-- room_name or nil, reason.
function zone_lights:default_room(group, rooms)
	local label = self:group_label(group)
	local mapping = self:room_mapping(group.rid)
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

-- Resolve the room an add goes to. Returns room_id, room_name or nil, text.
function zone_lights:room_for_add(group, room_id, rooms)
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
	local id, why = self:default_room(group, rooms)
	if not id then
		return nil, string.format("Not added: %s: %s; pick a room, or Set Room Mapping first", self:group_label(group), why)
	end
	return id, why
end

-- Add Zone Light: one AddDevice for the zone or room `rid` into `room_id`
-- (a number, or nil / "" / "mapped" for the group's mapped room); refuses a
-- group already imported, one with no lights, the bridge_home, an unknown
-- rid and a missing room. A tombstone for the rid is cleared by the
-- registry. Also callable as add({ Group = rid, Room = room }, done), the
-- action's own params. done(ok, text) exactly once; returns true when the
-- AddDevice was started.
function zone_lights:add(a, b, c)
	local rid, room_id, done
	if type(a) == "table" then
		rid = a.Group or a.group or a.rid
		room_id = a.Room or a.room or a.room_id
		done = b
	else
		rid, room_id, done = a, b, c
	end
	done = done or function() end
	if room_id == "mapped" or room_id == "" then
		room_id = nil
	end
	local busy = self:busy_text()
	if busy then
		done(false, busy)
		return false
	end
	if type(rid) ~= "string" or rid == "" then
		done(false, "Not added: pick a zone or room first")
		return false
	end
	local entry = self.registry[rid]
	if entry then
		done(false, string.format("Not added: %s is already imported (device %d)", self:entry_label(rid, entry),
			entry.device_id))
		return false
	end
	local group = self:group_of(rid)
	if not group then
		local any = self:groups():group(rid)
		if any and any.type == "bridge_home" then
			done(false, "Not added: the whole bridge cannot be a zone light")
		else
			done(false, string.format("Not added: zone or room %s is not on the bridge (connect the event stream and try again)",
				tostring(rid)))
		end
		return false
	end
	if not self:grouped_light_of(rid) then
		done(false, string.format("Not added: %s has no lights", self:group_label(group)))
		return false
	end
	local room_name
	room_id, room_name = self:room_for_add(group, room_id, self.project:rooms())
	if not room_id then
		done(false, room_name)
		return false
	end

	self.adding, self.adding_since = true, os.time()
	local label = self:group_label(group)
	self:create_device({ group = group, room_id = room_id, room_name = room_name }, function(created, _, err)
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
		self.ctx.log.always("zone_lights: %s", text)
		self:protect("add done", done, created[1] ~= nil, text)
		self:run_pending_resync()
	end)
	return true
end

-- Re-link Zone Light for a group device: the entry keeps its device,
-- proxy, programming and name and swaps the rid for another zone or room;
-- the device hears its new configuration and state. A light rid is refused
-- (Decision 8.1: no re-link across kinds). Returns ok, text.
function zone_lights:relink(device_id, new_rid)
	local busy = self:busy_text()
	if busy then
		return false, busy
	end
	device_id = util.positive(device_id)
	if not device_id or type(new_rid) ~= "string" or new_rid == "" then
		return false, "Not re-linked: pick a device and a zone or room"
	end
	local old_rid, entry = self.reg:by_device(device_id)
	if not old_rid then
		return false, string.format("Not re-linked: device %d is not a registered zone light", device_id)
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
	local group = self:group_of(new_rid)
	if not group then
		if self:models()[new_rid] then
			return false, string.format("Not re-linked: device %d is a zone light; pick a zone or room", device_id)
		end
		return false, string.format("Not re-linked: zone or room %s is not on the bridge (connect the event stream and "
			.. "try again)", tostring(new_rid))
	end
	local old_name = util.sanitise(entry.name or old_rid)
	local fields = self:fields_from_group(group)
	fields.name_dismissed = registry.CLEAR
	local relinked, err = self.reg:relink(old_rid, new_rid, fields)
	if not relinked then
		return false, "Not re-linked: " .. tostring(err)
	end
	self:mark()
	self.last_configure[old_rid] = nil
	self.color_sent[old_rid], self.online_sent[old_rid] = nil, nil
	self.color_sent[new_rid], self.online_sent[new_rid] = nil, nil
	self.conflicts[old_rid], self.conflicts[new_rid] = nil, nil
	self:clear_conflicts_for(device_id)
	self:push(new_rid, "resync", true)
	self:flush()
	local text = string.format("Re-linked device %d (was %s) to %s %s", device_id, old_name, group.type,
		util.sanitise(group.name))
	self.ctx.log.always("zone_lights: %s", text)
	return true, text
end

-- Forget Light for a group device: the entry goes, the device is unbound and
-- told HUE_FORGOTTEN, and stays in the project for the owner to delete; the
-- group is listed under Add Zone Light again. Returns ok, text.
function zone_lights:forget(device_id)
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
		return false, string.format("Not forgotten: device %d is not a registered zone light", device_id)
	end
	local word = type_word(entry.group_type)
	local label = string.format("%s (%sdevice %d)", util.sanitise(entry.name or rid), word and (word .. ", ") or "",
		device_id)
	self.reg:forget(rid)
	self:mark()
	self.last_configure[rid] = nil
	self.color_sent[rid], self.online_sent[rid] = nil, nil
	self.conflicts[rid] = nil
	self:clear_conflicts_for(device_id)
	self.announced[device_id] = nil
	self.ctx.send(device_id, "HUE_FORGOTTEN", { rid = rid, name = entry.name })
	local ok, err = self.project:call("unbind", device_id)
	if not ok then
		self.ctx.log.warn("zone_lights: unbind of device %d failed: %s", device_id, tostring(err))
	end
	self:flush()
	local text = string.format("Forgot %s: unbound and left in the project for you to delete", label)
	self.ctx.log.always("zone_lights: %s", text)
	return true, text
end

-- HUE_FORGET { rid?, device_id } from a group device's Forget This Light
-- action. Returns ok, text, or nil when the device is not a zone light (the
-- coordinator then asks the lights' module, which also answers strangers).
function zone_lights:forget_request(params)
	params = params or {}
	local device_id = util.positive(params.device_id)
	if not device_id and type(params.rid) == "string" and self.registry[params.rid] then
		device_id = self.registry[params.rid].device_id
	end
	if not device_id or not self.reg:by_device(device_id) then
		return nil
	end
	return self:forget(device_id)
end

-- The unimported zones and rooms whose creation name (a zone's name, "<Room>
-- Lights") matches one of `names`, zones first.
function zone_lights:match_unimported_by_name(names)
	local wanted = {}
	for _, name in ipairs(names) do
		if name ~= nil and util.norm(name) ~= "" then
			wanted[util.norm(name)] = true
		end
	end
	local out = {}
	for _, gtype in ipairs({ "zone", "room" }) do
		for _, group in ipairs(self:groups():groups(gtype)) do
			if not self.registry[group.rid] and wanted[util.norm(self:creation_name(group))] then
				out[#out + 1] = group
			end
		end
	end
	return out
end

-- Link Devices (zone lights): every bound hue_light device the registry
-- lacks that announced kind "group" is adopted by the rid it announced, else
-- by an exact, unique match of its Composer or announced name against the
-- unimported zones' names and rooms' creation names; a bound hue_light
-- device that never said hello is matched by name too. `skip_ids` (a set or
-- list of device ids, the lights' registered devices) are left alone, as a
-- device whose hello carried a light's model or another kind. The project's
-- hue_light devices bound the candidates; without that lookup the devices
-- that said hello do. Returns the text.
function zone_lights:link_devices(skip_ids)
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local skip = {}
	for k, v in pairs(skip_ids or {}) do
		if type(k) == "number" and v ~= true and tonumber(v) then
			skip[tonumber(v)] = true   -- a list
		elseif v then
			skip[tonumber(k) or k] = true
		end
	end
	local bound = self.project:bound_set()
	if not bound then
		return "Not linked: the bound-device lookup failed (see the Lua output)"
	end
	local present = self.project:devices_of(zone_lights.LIGHT_DRIVER)
	local ids, total = {}, 0
	for id in pairs(bound) do
		local n = util.positive(id)
		if n and not skip[n] then
			local hello = self.announced[n]
			local candidate = (present and present[n] ~= nil) or (not present and hello ~= nil)
			if candidate and hello and hello.kind ~= zone_lights.KIND and (hello.kind ~= nil or hello.model ~= nil) then
				candidate = false  -- a light, or another kind
			end
			if self.reg:by_device(n) then
				total = total + 1
			elseif candidate then
				total = total + 1
				ids[#ids + 1] = n
			end
		end
	end
	table.sort(ids)
	if #ids == 0 then
		if total == 0 then
			return "No zone light devices are bound to this bridge"
		end
		return string.format("All %d bound zone light devices are registered", total)
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
		local hello = self.announced[id] or {}
		local composer = names[id] or ("device " .. tostring(id))
		local rid = hello.kind == zone_lights.KIND and hello.rid or nil
		local who = string.format("%s (device %d)", composer, id)
		if rid and self.registry[rid] then
			local holder = self.registry[rid]
			self.conflicts[rid] = { holder = holder.device_id, claimant = id }
			problems[#problems + 1] = string.format("%s announces %s, which device %d holds (Forget Light on one of them)",
				who, self:entry_label(rid, holder), holder.device_id)
		elseif rid then
			-- A device that announced no name is registered under its Composer name.
			local entry = self:adopt(id, rid, { name = hello.name or names[id] }, "from its own persisted rid (Link Devices)")
			if entry then
				linked[#linked + 1] = string.format("%s to %s by its rid%s", who, self:entry_label(rid, entry),
					self:group_of(rid) and "" or (entry.state == "gone" and " (not on the bridge: marked gone)" or ""))
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
				local group = matches[1]
				local entry = self:adopt(id, group.rid, hello, "by its name (Link Devices)")
				if entry then
					linked[#linked + 1] = string.format("%s to %s by name", who, self:group_label(group))
					self:answer_hello(group.rid)
				else
					problems[#problems + 1] = string.format("%s: could not register %s (see the Lua output)", who, group.rid)
				end
			elseif #matches > 1 then
				problems[#problems + 1] = string.format("%s: %d unimported Hue zones or rooms have that name; rename the "
					.. "device in Composer to one zone's exact name and run Link Devices again", who, #matches)
			else
				problems[#problems + 1] = string.format("%s: no unimported Hue zone or room has that name; rename the device "
					.. "in Composer to the zone's exact name (a room's as \"<Room> Lights\") and run Link Devices again", who)
			end
		end
	end
	self:flush()
	local parts = {}
	if #linked > 0 then
		parts[#parts + 1] = string.format("Linked %s: %s", util.plural(#linked, "zone light device"),
			table.concat(linked, ", "))
	end
	if #problems > 0 then
		parts[#parts + 1] = string.format("not linked %d: %s", #problems, table.concat(problems, "; "))
	end
	local text = table.concat(parts, "; ")
	self.ctx.log.always("zone_lights: %s", text)
	return text
end

-- The Composer name a linked group device should carry (§5 Naming): the
-- creation name, so a room device called "Master Bedroom Lights" is not
-- reported as differing.
function zone_lights:expected_name(_rid, entry)
	return self:creation_name(entry)
end

-- Linked entries whose Composer name differs from the expected name and
-- whose difference the owner has not accepted: { rid, entry, current, expected }...
function zone_lights:name_differences()
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

-- Adopt Hue Names (zone lights): RenameDevice(proxy_id, expected name) for
-- every linked group device whose Composer name differs. Returns the text.
function zone_lights:adopt_hue_names()
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
		text = "No Composer names differ from the Hue zone and room names"
	else
		local parts = {}
		if #renamed > 0 then
			parts[#parts + 1] = string.format("Renamed %s: %s", util.plural(#renamed, "zone light device"),
				table.concat(renamed, ", "))
		end
		if #skipped > 0 then
			parts[#parts + 1] = string.format("not renamed %d: %s", #skipped, table.concat(skipped, ", "))
		end
		text = table.concat(parts, "; ")
	end
	self.ctx.log.always("zone_lights: %s", text)
	return text
end

-- Accept Names As They Are (zone lights): every current difference is recorded.
function zone_lights:accept_names()
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
		text = "No Composer names differ from the Hue zone and room names"
	else
		text = string.format("Accepted %s: %s", util.plural(#accepted, "zone light name difference"),
			table.concat(accepted, ", "))
	end
	self.ctx.log.always("zone_lights: %s", text)
	return text
end

-- Texts ---------------------------------------------------------------------------

-- The Zone Lights property: "7 zones, 16 rooms on bridge; 1 imported" with
-- ", n missing" / ", n unbound" / ", n deleted" appended only when not zero
-- (under 60 characters for the usual counts); "<n> imported" before the
-- groups are fetched.
function zone_lights:summary()
	if not self:groups_loaded() then
		return string.format("%d imported", self:count())
	end
	local cache = self:groups()
	local c = self.reg:counts()
	local text = string.format("%s, %s on bridge; %d imported", util.plural(#cache:groups("zone"), "zone"),
		util.plural(#cache:groups("room"), "room"), self:count())
	if c.gone > 0 then
		text = text .. string.format(", %d missing", c.gone)
	end
	if c.unbound > 0 then
		text = text .. string.format(", %d unbound", c.unbound)
	end
	if c.tombstones > 0 then
		text = text .. string.format(", %d deleted", c.tombstones)
	end
	return text
end

-- The Attention items (driver.lua joins them after the lights' and the
-- scenes'): missing groups, unbound group devices, two devices claiming one
-- group, name differences.
function zone_lights:attention_items()
	local items = {}

	local gone = self.reg:rids("gone")
	if #gone > 0 then
		local names = {}
		for _, rid in ipairs(gone) do
			local entry = self.registry[rid]
			names[#names + 1] = string.format("%s (device %d, since %s)", util.sanitise(entry.name or rid), entry.device_id,
				util.date_of(entry.gone_since))
		end
		items[#items + 1] = string.format("%s missing from the bridge: %s (Re-link Zone Light or Forget Light)",
			util.plural(#gone, "zone light"), util.some(names, zone_lights.MAX_NAMED))
	end

	local unbound = self.reg:rids("unbound")
	if #unbound > 0 then
		local names = {}
		for _, rid in ipairs(unbound) do
			local entry = self.registry[rid]
			names[#names + 1] = string.format("%s (device %d)", util.sanitise(entry.name or rid), entry.device_id)
		end
		items[#items + 1] = string.format("%s: %s (bind it to this bridge in Composer, or Forget Light)",
			util.plural(#unbound, "unbound zone light device"), util.some(names, zone_lights.MAX_NAMED))
	end

	local conflict_rids = {}
	for rid in pairs(self.conflicts) do
		conflict_rids[#conflict_rids + 1] = rid
	end
	table.sort(conflict_rids)
	for _, rid in ipairs(conflict_rids) do
		local c = self.conflicts[rid]
		local entry, group = self.registry[rid], self:group_of(rid)
		local word, name = "group", tostring(rid)
		if entry then
			word, name = type_word(entry.group_type) or word, util.sanitise(entry.name or rid)
		elseif group then
			word, name = group.type, util.sanitise(group.name)
		end
		items[#items + 1] = string.format("2 devices claim Hue %s %s: %d and %d (Forget Light on one of them)", word, name,
			c.holder, c.claimant)
	end

	local diffs = self:name_differences()
	if #diffs > 0 then
		local names = {}
		for _, d in ipairs(diffs) do
			names[#names + 1] = string.format("%s is %s in Hue", d.current, d.expected)
		end
		items[#items + 1] = string.format("%d zone light name%s differ%s from the Composer names: %s "
			.. "(Adopt Hue Names or Accept Names As They Are)", #diffs, #diffs == 1 and "" or "s",
			#diffs == 1 and "s" or "", util.some(names, zone_lights.MAX_NAMED))
	end

	return items
end

-- The items joined, or "None".
function zone_lights:attention()
	local items = self:attention_items()
	if #items == 0 then
		return "None"
	end
	return table.concat(items, "; ")
end

-- Pickers (§8.2): { text, value } arrays, value a string -----------------------------------

-- Add Zone Light's Group: the unimported zones (name order) then the
-- unimported rooms, "Bedside Lights (zone, 2 lights)" / "Master Bedroom
-- (room, 9 lights)", a group without lights "Attic (zone, no lights)",
-- tombstoned ones last "… (deleted from Composer <date>)"; one entry with
-- value "" when there is nothing.
function zone_lights:picker_groups()
	local cache = self:groups()
	local plain, deleted, any = {}, {}, false
	for _, gtype in ipairs({ "zone", "room" }) do
		for _, group in ipairs(cache:groups(gtype)) do
			any = true
			if not self.registry[group.rid] then
				local members = self:member_lights(group)
				local count
				if self:grouped_light_of(group.rid) == nil then
					count = "no lights"
				else
					count = util.plural(#members, "light")
				end
				local text = string.format("%s (%s, %s)", util.sanitise(group.name), gtype, count)
				local tomb = self.reg:tombstones()[group.rid]
				if tomb then
					deleted[#deleted + 1] = { text = string.format("%s (deleted from Composer %s)", text,
						util.date_of(tomb.deleted_at)), value = group.rid }
				else
					plain[#plain + 1] = { text = text, value = group.rid }
				end
			end
		end
	end
	for _, item in ipairs(deleted) do
		plain[#plain + 1] = item
	end
	if #plain == 0 then
		if not any then
			return util.empty_list("(no zones or rooms on the bridge)")
		end
		return util.empty_list("(every zone and room on the bridge is imported)")
	end
	return plain
end

-- "Bedside Lights (zone light, device 1180" and so on: the device pickers'
-- name of an entry, the lights' shape with the kind in front of the device.
local function device_text(entry, device_id, rest)
	local word = type_word(entry.group_type) or "zone"
	return string.format("%s (%s light, device %d%s)", util.sanitise(entry.name or "?"), word, device_id, rest or "")
end

-- Re-link Zone Light's Device (after the lights' entries): the gone and
-- unbound group devices. An empty array when there are none, so the
-- coordinator's join keeps the lights' placeholder (driver.lua's join_pickers).
function zone_lights:picker_relink_devices()
	local list = {}
	for _, state in ipairs({ "gone", "unbound" }) do
		for _, rid in ipairs(self.reg:rids(state)) do
			local entry = self.registry[rid]
			list[#list + 1] = { text = device_text(entry, entry.device_id, string.format(", %s since %s", state,
				util.short_date_of(entry[state .. "_since"]))), value = tostring(entry.device_id) }
		end
	end
	return list
end

-- Forget Light's Device (after the lights' entries): every group device,
-- its state appended when not linked. An empty array when there are none.
function zone_lights:picker_forget_devices()
	local list = {}
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		local text = device_text(entry, entry.device_id)
		if entry.state ~= "linked" then
			text = text .. " " .. entry.state
		end
		list[#list + 1] = { text = text, value = tostring(entry.device_id) }
	end
	return list
end

-- Lists (the drop-down properties) ----------------------------------------------

-- The state a list line ends in for a registry entry: " → device N" linked,
-- " (deleted in Hue; device N)" gone, " (unbound; device N)" unbound.
local function entry_suffix(entry)
	if entry.state == "gone" then
		return string.format(" (deleted in Hue; device %d)", entry.device_id)
	elseif entry.state == "unbound" then
		return string.format(" (unbound; device %d)", entry.device_id)
	end
	return string.format(" → device %d", entry.device_id)
end

-- "Bedside Lights (zone; 2 lights)", "Attic (zone; no lights)": the Add Zone
-- Light picker's label with ";" inside the parentheses, so that a list line
-- holds no comma. `word` and `count` are left out when unknown.
local function list_label(name, word, count)
	local inner = {}
	if word then
		inner[#inner + 1] = word
	end
	if count then
		inner[#inner + 1] = count
	end
	local text = tostring(name or "?")
	if #inner > 0 then
		text = text .. " (" .. table.concat(inner, "; ") .. ")"
	end
	return text
end

-- The Zone Lights drop-down (the row shows summary()): every zone then every
-- room on the bridge in the Add Zone Light picker's order and labels
-- ("Bedside Lights (zone; 2 lights)", "Attic (zone; no lights)"), with
-- " → device N" when imported, " (deleted from Composer <date>)" for a
-- tombstone, " (unbound; device N)"; then the registered groups the cache
-- lacks, in name order, with the type and light count the entry remembers
-- and " (deleted in Hue; device N)" when gone. Commas become "‚" (U+201A):
-- the list is comma-delimited (driver.lua's refresh_room_mappings). Before
-- the groups are fetched, the registry alone: what is known. Empty when
-- nothing is.
function zone_lights:list_items()
	local cache = self:groups()
	local tombs = self.reg:tombstones()
	local out, listed = {}, {}
	for _, gtype in ipairs({ "zone", "room" }) do
		for _, group in ipairs(cache:groups(gtype)) do
			listed[group.rid] = true
			local count
			if self:grouped_light_of(group.rid) == nil then
				count = "no lights"
			else
				count = util.plural(#self:member_lights(group), "light")
			end
			local text = list_label(group.name, gtype, count)
			local entry, tomb = self.registry[group.rid], tombs[group.rid]
			if entry then
				text = text .. entry_suffix(entry)
			elseif tomb then
				text = text .. string.format(" (deleted from Composer %s)", util.date_of(tomb.deleted_at))
			end
			out[#out + 1] = text
		end
	end
	for _, rid in ipairs(self.reg:rids()) do
		if not listed[rid] then
			local entry = self.registry[rid]
			local count
			if entry.no_lights then
				count = "no lights"
			elseif entry.light_count then
				count = util.plural(entry.light_count, "light")
			end
			out[#out + 1] = list_label(entry.name, type_word(entry.group_type), count) .. entry_suffix(entry)
		end
	end
	for i, text in ipairs(out) do
		out[i] = (text:gsub(",", "‚"))
	end
	return out
end

return zone_lights
