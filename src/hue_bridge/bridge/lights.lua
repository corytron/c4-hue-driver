-- The Hue lights a bridge represents as Control4 devices: the flows that keep
-- the registry (bridge.registry), the group cache (bridge.groups) and the light
-- drivers current, and the owner-facing actions, texts and pickers of
-- docs/import-design.md (§4 messages, §5 resync and reconciliation, §6
-- actions, §8 pickers, §13 this module's interface). docs/lights-design.md
-- stays the contract for the messages and the coalescer. The lifecycle the
-- lights share with the scenes and the zone lights (configuration and state
-- plumbing, hello, goodbye, bindings, the project reconcile, the busy flags
-- and resyncs, room resolution, creation, names, Attention, pickers,
-- re-link, forget, Link Devices) is bridge/owner.lua's since issue #56; this
-- module gives it its words, options and hooks.
--
-- Every C4 call goes through ctx so the module runs on plain tables in specs.
-- Each ctx field defaults to the real call when the driver leaves it out, so
-- the driver only has to supply `http`. The project calls (ctx.project.*) are
-- pcall-wrapped: a failed lookup reads as "unknown", never as "empty" (§5).
--
-- Three rules from the contract shape everything here (§1): the project is
-- the owner's (devices are created, renamed, bound or unbound only from an
-- action he clicked; a hello auto-adopt changes nothing in the project);
-- nothing is lost by waiting (every change is cached, counted and logged);
-- the Control4 device is the identity and the rid is re-pointable.
--
-- Two rules inherited from the spike (docs/design.md): the GETs run one after
-- another (one C4:url queue per host spelling), chained from http.request
-- callbacks, which are OnDone callbacks and may start a transfer;
-- on_container runs inside OnBodyChunk and must not start one, so it only
-- sends messages. Every callback body is pcall-wrapped: an error raised into
-- Director's callback machinery would leave an import or resync half done
-- with its guard flag still set.
--
-- Persistence: the registry's mutators change memory only; this module marks
-- itself dirty and saves once per batch (one click, one resync, one event
-- container), except during device creation, where it saves after every
-- AddDevice so a failure half-way never leaves a created device unregistered
-- (which the next import would double).

local hue_model = require("bridge.hue_model")
local registry = require("bridge.registry")
local groups = require("bridge.groups")
local util = require("bridge.util")
local project = require("bridge.project")
local owner = require("bridge.owner")

-- The pure helpers every bridge module shares (bridge.util; sanitise keeps
-- the comma rule of CUSTOM_SELECT lists). util.some takes lights.MAX_NAMED.
local positive, norm, sanitise = util.positive, util.norm, util.sanitise
local date_of, plural = util.date_of, util.plural
local has_field, empty_list = util.has_field, util.empty_list
local copy_caps, same_caps = util.copy_caps, util.same_caps

local lights = {}
lights.__index = lights
setmetatable(lights, { __index = owner })  -- the shared lifecycle (bridge/owner.lua)

lights.REGISTRY_KEY = registry.LIGHTS_KEY
lights.AUTOMAP_KEY = "hue_rooms_automapped"  -- set once the one-time Map Rooms By Name has run [Q 5]
lights.LIGHT_DRIVER = "hue_light.c4z"
lights.BINDING = 1
lights.BINDING_CLASS = "HUE_BRIDGE"
lights.OFFLINE_NAG_S = 24 * 3600              -- Attention nags about lights offline this long [Q 8]
lights.MAX_NAMED = 3                          -- names listed per Attention item before "+n more"
lights.EARLY_HELLOS_MAX = 200                 -- hellos kept before load(), as the driver's early queue

-- What bridge/owner.lua reads for this module: the log tag and the words its
-- shared texts take here.
lights.TAG = "lights"
lights.WORDS = {
	held = "light",                       -- "its registered light is <rid>"
	stranger = "an unregistered device",  -- a HUE_GOODBYE the module does not hold
	goodbye_tail = "Add Light lists it as deleted, Import All New Lights skips it",
	add_action = "Add Light",
	busy_job = "importing",
	busy_resync = "resyncing",
	kind = "light",
	unbound_kind = "unbound device",
	relink_or_forget = "Re-link Device To Light or Forget Light",
	forget_action = "Forget Light",
	name_kind = "Hue name",
	hue_names = "Hue names",
	device_noun = "device",
	name_difference = "name difference",
	no_relink = "(no gone or unbound devices)",
	no_forget = "(no registered lights)",
	callback_kind = "",
	created_noun = "lights",
	registered = "light",                 -- "device 1036 is not a registered light"
	relink_target = "a light",            -- "pick a device and a light"
	requester = "light",                  -- "the light named no device"
	forget_tail = "; the Hue light is listed under Add Light again",
	link_noun = "devices",                -- "No devices are bound to this bridge"
	link_many = "Hue lights",
	link_one = "Hue light's",
	link_none = "Hue light",
}
lights.DEVICE_DRIVER = lights.LIGHT_DRIVER
lights.BUSY_FLAGS = { "importing", "resyncing" }  -- the import's flag first
lights.MESSAGES = { configure = "HUE_CONFIGURE", hello = "HUE_HELLO", goodbye = "HUE_GOODBYE",
	forgotten = "HUE_FORGOTTEN" }
-- bridge/owner.lua's options (its header lists the divergences they keep).
lights.OPTIONS = {
	push_needs_state = true,         -- a light without a model hears nothing, not even its CONFIGURE
	hello_tells_unknown = true,      -- a hello's "bound-device list is unknown" is logged as such
	gone_at_hello = true,            -- R6: a linked light a synced run lacks is marked gone at its hello
	gone_after_add = true,           -- R6: a light deleted while its AddDevice was pending is marked gone
	announced_follows_entry = true,  -- R5: a deleted or re-linked entry's device is no longer "announced"
	log_unregistered_bind = true,    -- a bound device the registry lacks is logged
}
-- The fields a refresh after a full GET clears when the light's model, its
-- device record or its radio no longer supply them (owner:refresh_fields,
-- analysis R9; #56): a stale MAC would otherwise feed relink_hint for ever.
-- Only after a full GET: an event's refresh may run before the device
-- record of a re-added light has arrived.
lights.REFRESH_CLEARS = { "device_name", "model", "device_rid", "mac_address", "service_id", "id_v1" }

-- The registry entry fields this module persists besides the registry's own
-- (registry.OWN_FIELDS): docs/import-design.md §3. Any other persisted field
-- is dropped at load (code analysis 2026-10-22 R9, issue #48).
lights.ENTRY_FIELDS = { "name", "device_name", "model", "caps", "device_rid", "mac_address", "service_id", "id_v1",
	"hue_room_rid", "hue_room", "name_dismissed" }

-- The six serial GETs of a resync (§5). Small on the house bridge: rooms,
-- zones and bridge_home are 18 KB together [verified: hardware 2026-10-21];
-- /scene (351 KB) is the scenes feature's and nothing fetches the whole
-- resource at once.
lights.RESOURCES = {
	{ kind = "light", path = "/clip/v2/resource/light" },
	{ kind = "device", path = "/clip/v2/resource/device" },
	{ kind = "zigbee", path = "/clip/v2/resource/zigbee_connectivity" },
	{ kind = "room", path = "/clip/v2/resource/room" },
	{ kind = "zone", path = "/clip/v2/resource/zone" },
	{ kind = "bridge_home", path = "/clip/v2/resource/bridge_home" },
}

-- ctx fields (all but http optional):
--   http(req, cb)            req = { path, method }; the driver adds ip and key
--                            and calls bridge.http.request; cb(result)
--   send(id, cmd, params)    C4:SendToDevice(id, cmd, params)
--   add_device(driver, room_id, name, cb)   C4:AddDevice; cb(device_id, info)
--   bind(bridge_id, light_id)               C4:Bind(bridge_id, 1, light_id, 1, "HUE_BRIDGE")
--   persist_get(name) / persist_set(name, value)   C4:PersistGetValue / SetValue
--   bridge_id, room_id       numbers; default C4:GetDeviceID() / C4:RoomGetId()
--   now                      os.time look-alike
--   log                      a common.log look-alike
--   project                  the project calls of docs/import-design.md §13:
--                            rooms(), hierarchy(), devices(filter), bound(),
--                            unbind(device_id), rename(id, name), display_name(id)
--   skip_devices             the device ids another module owns, as a set
--                            { [device_id] = true } (or a list of ids), or a
--                            function returning one, consulted at each use
--                            (once per event container, see foreign()).
--                            Zone-light devices run hue_light.c4z too
--                            (docs/zone-light-design.md §4): this module never
--                            adopts, lists as a candidate, re-links or messages
--                            one of them; Forget Light on one only drops the
--                            stale entry. Optional; link_devices(skip_ids) adds
--                            to it for one call.
function lights.new(ctx)
	ctx = ctx or {}
	assert(type(ctx.http) == "function", "lights.new: ctx.http is required")
	owner.defaults(ctx, lights)  -- send, add_device, bind, persistence, log, now, the project calls

	local reg = registry.new({
		persist_get = ctx.persist_get, persist_set = ctx.persist_set, now = ctx.now, log = ctx.log,
		fields = lights.ENTRY_FIELDS,
	})
	return setmetatable({
		ctx = ctx,
		reg = reg,
		project = project.new(ctx, "lights"),  -- the pcall-wrapped project calls (bridge.project)
		registry = reg:entries(),  -- rid → entry, the live table (identity kept across load())
		groups = groups.new(),     -- rooms, zones, bridge_home from the last GET (memory only)
		models = {},               -- rid → normalised light, from the last GET (memory only)
		devices = {},              -- device rid → hue_model.devices() record (memory only)
		macs = {},                 -- device rid → zigbee mac_address (memory only)
		last_configure = {},       -- rid → signature of the last HUE_CONFIGURE sent, to send it again only on change
		offline_since = {},        -- rid → ctx.now() when the light was first seen offline (memory only)
		announced = {},            -- device_id → { rid, name, model } from HUE_HELLO, for Link Devices (strings or nil)
		announced_new = {},        -- rid → true once a new light was logged
		conflicts = {},            -- rid → { holder = device_id, claimant = device_id } (two devices, one rid)
		early_hellos = {},         -- HUE_HELLOs received before load() (EARLY_HELLOS_MAX), answered after configure_all()
		foreign_logged = {},       -- rid → true once an entry held by another module's device was logged
		loaded = false,
		synced = false,            -- a full GET has succeeded (new/missing counts mean something)
		groups_loaded = false,     -- /room, /zone, /bridge_home fetched in this run (a missing group means deleted)
		dirty = false,
		configured_once = false,
		importing = false,
		resyncing = false,
		resync_pending = nil,      -- the done callbacks of the resync to run once the current job ends (a list)
		device_info_logged = false,
		automapped = false,        -- the one-time Map Rooms By Name has run, or its persisted flag was seen
		skip_cache = nil,          -- inside on_container(): false, then the skip set at its first use; nil outside
	}, lights)
end

-- Helpers (bridge_id, protect and the rest of the plumbing are bridge/owner.lua's) ------

function lights:room_id()
	return self.ctx.room_id or C4:RoomGetId()
end

-- The AddDevice callback's shapes (bridge/owner.lua since the lifecycle
-- moved there; the names stay for the specs and the dev tools).
lights.dump = owner.dump
lights.ids_from = owner.ids_from

-- Add the device ids of `ids` (a set { [id] = true } or a list of ids) to
-- the set `out`, as numbers. Anything else in the table is ignored.
local function add_ids(out, ids)
	if type(ids) ~= "table" then
		return out
	end
	for k, v in pairs(ids) do
		local id
		if type(v) == "number" then
			id = v
		elseif v == true then
			id = tonumber(k)
		end
		if id and id > 0 then
			out[id] = true
		end
	end
	return out
end

-- The device ids this module must leave alone: ctx.skip_devices (a set, a
-- list or a function returning one; a failing function reads as empty) plus
-- `extra` in the same shapes. Always a fresh set.
function lights:skip_set(extra)
	local out = {}
	local given = self.ctx.skip_devices
	if type(given) == "function" then
		local ok, result = pcall(given)
		if ok then
			given = result
		else
			self.ctx.log.warn("lights: skip_devices failed: %s", tostring(result))
			given = nil
		end
	end
	add_ids(out, given)
	add_ids(out, extra)
	return out
end

-- True when the device belongs to another module (see ctx.skip_devices).
-- Inside on_container() the set is built once per container, at its first
-- use (skip_cache is false until then, the set after); everywhere else
-- skip_cache is nil and the set is fresh at each use.
function lights:foreign(device_id)
	if self.ctx.skip_devices == nil then
		return false
	end
	local id = positive(device_id)
	if id == nil then
		return false
	end
	local skip = self.skip_cache or self:skip_set()
	if self.skip_cache == false then
		self.skip_cache = skip
	end
	return skip[id] == true
end

-- Every message to a device goes through here: one owned by another module
-- is never told anything by this one, whatever a stale entry says.
function lights:tell(device_id, command, params)
	if self:foreign(device_id) then
		self.ctx.log.debug("lights: %s to device %s not sent: the device belongs to another module", tostring(command),
			tostring(device_id))
		return false
	end
	self.ctx.send(device_id, command, params)
	return true
end

-- Name order, case-insensitive, ties by rid: the order every list is in.
local function by_name(a, b)
	local an, bn = string.lower(tostring(a.name or "")), string.lower(tostring(b.name or ""))
	if an ~= bn then
		return an < bn
	end
	return tostring(a.rid) < tostring(b.rid)
end

-- by_name's order over rows whose keys were computed once ({ key = the
-- lower-cased name, rid = the rid as text }): one :lower() per row instead
-- of two per comparison (docs/reviews/efficiency-2026-10-24.md R6).
local function by_row_key(a, b)
	if a.key ~= b.key then
		return a.key < b.key
	end
	return a.rid < b.rid
end

-- "#12" from Hue's v1 id ("/lights/12"), else the first 8 hex of the rid:
-- the stable number the owner also sees in the Hue app and the dev log.
local function v1_tag(id_v1, rid)
	local n = id_v1 and tostring(id_v1):match("(%d+)%s*$")
	if n then
		return "#" .. n
	end
	return "#" .. tostring(rid):sub(1, 8)
end

-- Registry access ---------------------------------------------------------------

-- Read the persisted registry (v1 entries upgrade in place, fields outside
-- lights.ENTRY_FIELDS dropped, see bridge.registry) and normalise the caps as
-- before. Returns the entries table.
function lights:load()
	self.reg:load()
	for rid, entry in pairs(self.registry) do
		entry.caps = copy_caps(entry.caps)
		self.ctx.log.debug("lights: loaded %s (device %s, %s)", tostring(entry.name), tostring(entry.device_id),
			tostring(rid))
	end
	self.loaded = true
	self.dirty = false
	return self.registry
end

-- mark, flush and save are bridge/owner.lua's (save also serves driver.lua's
-- dev actions, which poke entries directly).

function lights:device_for(rid)
	local entry = rid ~= nil and self.registry[rid] or nil
	return entry and entry.device_id or nil
end

-- The proxy device id AddDevice reported for the light, or nil (not every
-- OS reports one, and entries imported before it was kept have none).
function lights:proxy_for(rid)
	local entry = rid ~= nil and self.registry[rid] or nil
	return entry and entry.proxy_id or nil
end

-- (owner hook) entry(rid), the copy the specs and the dev tools read,
-- normalises the caps this way.
function lights.entry_caps(_self, caps)
	return copy_caps(caps)
end

function lights:rid_for(device_id)
	return (self.reg:by_device(device_id))
end

-- Lights seen on the bridge in the last GET.
function lights:bridge_count()
	local n = 0
	for _ in pairs(self.models) do
		n = n + 1
	end
	return n
end

-- Limits for the command queue: from the live model when there is one, else
-- from the persisted caps (so they are available at startup). nil for an
-- unknown rid.
function lights:limits(rid)
	local model = rid ~= nil and self.models[rid] or nil
	if model then
		return { min_dim = model.min_dim, mirek_min = model.mirek_min, mirek_max = model.mirek_max }
	end
	local entry = rid ~= nil and self.registry[rid] or nil
	if entry and entry.caps then
		return { min_dim = entry.caps.min_dim, mirek_min = entry.caps.mirek_min, mirek_max = entry.caps.mirek_max }
	end
	return nil
end

-- Project access ----------------------------------------------------------------

-- The project reads go through self.project (bridge.project, shared with the
-- scenes and the zone lights since 2026-10-25): call(name, ...) for one
-- pcall-wrapped call, rooms(), bound_set() (nil, "unknown" for a lookup that
-- answered no table: issue #48 item 14), devices_of(driver_file) and
-- display_name(id). Only the floors are the lights' own.

-- room_id → floor name from the project hierarchy: nested nodes keyed by
-- location id, numeric types 4 floor and 8 room [verified: hardware OS 3.4.2].
function lights:room_floors()
	local _, tree = self.project:call("hierarchy")
	local out = {}
	local function walk(node, floor, depth)
		if type(node) ~= "table" or depth > 8 then
			return
		end
		if tonumber(node.type) == 4 and node.name ~= nil then
			floor = tostring(node.name)
		end
		for key, child in pairs(node) do
			local id = tonumber(key)
			if id and type(child) == "table" then
				if tonumber(child.type) == 8 and floor then
					out[id] = floor
				end
				walk(child, floor, depth + 1)
			end
		end
	end
	walk(tree, nil, 0)
	return out
end

-- The hue_light devices in the project as { [device_id] = GetDevices info },
-- or nil when the call failed or returned nothing: unknown, never "deleted"
-- (§5). Zone-light devices are among them (same driver); callers that choose
-- candidates cut them out with skip_set(), callers that ask whether a device
-- still exists do not (it does).
function lights:project_lights()
	return self.project:devices_of(lights.LIGHT_DRIVER)
end

-- Model-derived views -----------------------------------------------------------

-- Lights on the bridge without a registry entry, in name order (tombstoned
-- ones included; see new_models()).
function lights:unimported_models()
	local rows = {}
	for rid, model in pairs(self.models) do
		if not self.registry[rid] then
			rows[#rows + 1] = { key = string.lower(tostring(model.name or "")), rid = tostring(model.rid), model = model }
		end
	end
	table.sort(rows, by_row_key)
	local list = {}
	for i, row in ipairs(rows) do
		list[i] = row.model
	end
	return list
end

function lights:is_tombstoned(rid)
	return self.reg:tombstones()[rid] ~= nil
end

-- Unimported and not deleted in Composer: what Import All New Lights adds
-- and what the Lights property counts as new.
function lights:new_models()
	local list = {}
	for _, model in ipairs(self:unimported_models()) do
		if not self:is_tombstoned(model.rid) then
			list[#list + 1] = model
		end
	end
	return list
end

-- #new_models() without building or sorting the list: the Lights row and
-- Attention count at every refresh (docs/reviews/efficiency-2026-10-24.md R6).
function lights:new_count()
	local tombs, n = self.reg:tombstones(), 0
	for rid in pairs(self.models) do
		if not self.registry[rid] and tombs[rid] == nil then
			n = n + 1
		end
	end
	return n
end

-- The gone entry a new light may be the replacement of: the same
-- mac_address (a re-added bulb keeps its radio) or the same name. Returns
-- rid, entry or nil.
function lights:relink_hint(model)
	local mac = self.macs[model.device_rid]
	local by_mac, by_name_rid
	for _, rid in ipairs(self.reg:rids("gone")) do
		local entry = self.registry[rid]
		if mac and entry.mac_address == mac then
			by_mac = by_mac or rid
		elseif entry.name == model.name then
			by_name_rid = by_name_rid or rid
		end
	end
	local rid = by_mac or by_name_rid
	if rid then
		return rid, self.registry[rid]
	end
	return nil
end

-- " (looks like Desk Lamp #12, device 1036; re-link?)" when a new light has
-- a re-link hint, nil when not: the Attention item and the Add Light picker.
function lights:hint_text(model)
	local hint_rid, hint = self:relink_hint(model)
	if not hint then
		return nil
	end
	return string.format(" (looks like %s, device %d; re-link?)", self:entry_label(hint_rid, hint), hint.device_id)
end

-- Log a new light once per run, with its re-link hint when there is one.
function lights:announce_new(model)
	if self.announced_new[model.rid] then
		return
	end
	self.announced_new[model.rid] = true
	local hint_rid, hint = self:relink_hint(model)
	self.ctx.log.always("lights: new light %s on the bridge; use Add Light or Import All New Lights%s",
		self:light_label(model), hint and string.format("; it looks like %s (device %d): re-link?",
			self:entry_label(hint_rid, hint), hint.device_id) or "")
end

-- The Hue room of a light's owner device: group rid, label; nil, nil for none.
function lights:hue_room_of(model)
	local room_rid = self.groups:room_of_device(model.device_rid)
	if not room_rid then
		return nil, nil
	end
	return room_rid, self.groups:label(room_rid)
end

-- The registry fields a model (and its device record) supplies.
function lights:fields_from_model(model)
	if not model then
		return {}
	end
	local device = self.devices[model.device_rid]
	local room_rid, room_label = self:hue_room_of(model)
	return {
		name = model.name,
		device_name = device and device.name or nil,
		model = device and device.model or nil,
		caps = hue_model.caps(model),
		device_rid = model.device_rid,
		mac_address = self.macs[model.device_rid],
		service_id = model.service_id,
		id_v1 = model.id_v1,
		hue_room_rid = room_rid,
		hue_room = room_label,
	}
end

-- The room an add goes to (owner: default_room, room_for_add): the mapping
-- of the light's Hue room (its owner device's), from the lights' own
-- registry, and the light's label in the refusal.
function lights:room_group_of(model)
	local room_rid, label = self:hue_room_of(model)
	if not room_rid then
		return nil, "no Hue room"
	end
	return room_rid, label
end

function lights:room_mapping(group_rid)
	return self.reg:room_mapping(group_rid)
end

function lights:add_label(model)
	return self:light_label(model, false)
end

-- "Porch [Outdoor] #53": Hue name, the room label when the owner device is
-- in a room, the v1 number (or the first 8 hex of the rid).
function lights:light_label(model, with_room)
	local parts = { sanitise(model.name or "?") }
	if with_room ~= false then
		local _, label = self:hue_room_of(model)
		if label then
			parts[#parts + 1] = "[" .. sanitise(label) .. "]"
		end
	end
	parts[#parts + 1] = v1_tag(model.id_v1, model.rid)
	return table.concat(parts, " ")
end

-- "Desk Lamp #12" for a registry entry.
function lights.entry_label(_self, rid, entry)
	return sanitise(entry.name or "?") .. " " .. v1_tag(entry.id_v1, rid)
end

-- The label of a registered light: with its room when it is on the bridge.
function lights:registered_label(rid, entry)
	local model = self.models[rid]
	if model then
		return self:light_label(model)
	end
	return self:entry_label(rid, entry)
end

-- The mapping's Control4 side: the room's current name, "(Control4 room
-- gone)" when the project lacks it, the cached name when the project is unknown.
function lights.mapping_target(_self, mapping, rooms)
	if not mapping or not mapping.c4_room_id then
		return "(unmapped)"
	end
	local name = rooms[mapping.c4_room_id]
	if name then
		return name
	end
	if next(rooms) == nil then
		return mapping.c4_room_name or ("room " .. tostring(mapping.c4_room_id))
	end
	return "(Control4 room gone)"
end

-- Fetching and absorbing bridge state ---------------------------------------

-- GET the resource lists one after another. done({ light, device, zigbee,
-- room, zone, bridge_home }) with the decoded `data` arrays, or done(nil,
-- err) after the first failure. Chaining from the http callback is fine: it
-- is an OnDone callback.
function lights:fetch_all(done)
	local out = {}
	local function step(i)
		local res = lights.RESOURCES[i]
		if not res then
			return done(out)
		end
		self.ctx.http({ path = res.path, method = "GET" }, function(r)
			self:protect("fetch " .. res.kind, function()
				if not r.ok then
					return done(nil, string.format("GET %s: %s", res.path, tostring(r.err)))
				end
				local items = type(r.json) == "table" and r.json.data or nil
				if type(items) ~= "table" then
					return done(nil, string.format("GET %s: malformed response", res.path))
				end
				out[res.kind] = items
				step(i + 1)
			end)
		end)
	end
	step(1)
end

-- Offline bookkeeping for the Attention nag: first seen offline → stamped;
-- back online → cleared.
function lights:track_offline(rid, model)
	if model.online == false then
		self.offline_since[rid] = self.offline_since[rid] or self.ctx.now()
	elseif model.online == true then
		self.offline_since[rid] = nil
	end
end

-- Replace the in-memory models, devices, MACs and groups with a fetch result,
-- apply the connectivity to the models, and refresh the registry's cached
-- identity fields (name, model, caps, device_rid, mac_address, service_id,
-- id_v1, device_name). No state changes here: those are the reconciliation
-- steps the caller runs next.
function lights:absorb(res)
	local models = {}
	for _, item in ipairs(res.light or {}) do
		local model = hue_model.light(item)  -- nil for junk, an id that is not a resource id included
		if model then
			local old = self.models[model.rid]
			if old then
				model.online = old.online
			end
			models[model.rid] = model
		end
	end
	self.models = models
	if res.device then
		self.devices = hue_model.devices(res.device)
	end
	for _, item in ipairs(res.zigbee or {}) do
		if type(item) == "table" then
			local conn = hue_model.connectivity(item)
			if conn.device_rid and conn.mac_address then
				self.macs[conn.device_rid] = conn.mac_address
			end
			local device = self.devices[conn.device_rid]
			for _, rid in ipairs(device and device.light_rids or {}) do
				if models[rid] then
					models[rid].online = conn.online
				end
			end
		end
	end
	for rid, model in pairs(models) do
		self:track_offline(rid, model)
	end
	if res.room or res.zone or res.bridge_home then
		-- A full GET is authoritative, so start a fresh cache: absorb() alone
		-- keeps a type whose list came back empty (the last zone deleted).
		local items = {}
		for _, kind in ipairs(groups.TYPES) do
			for _, item in ipairs(res[kind] or {}) do
				items[#items + 1] = item
			end
		end
		self.groups = groups.new()
		local counts = self.groups:absorb(items)
		self.groups_loaded = true
		self.ctx.log.debug("lights: %d rooms, %d zones, %d bridge_home cached", counts.room, counts.zone, counts.bridge_home)
	end
	self:refresh_registry(true)
end

-- Bring the registry entry's cached name up to the model's. True when it
-- changed (the caller saves). The Composer device keeps its own name.
function lights:take_name(entry, model)
	if entry.name == model.name then
		return false
	end
	self.ctx.log.info("lights: %s was renamed to %s in Hue (Composer name unchanged)",
		tostring(entry.name), tostring(model.name))
	entry.name = model.name
	return true
end

-- The identity fields of every entry that has a model, from the last GET.
-- `authoritative` (a full GET was absorbed) also clears REFRESH_CLEARS
-- fields the model no longer supplies.
function lights:refresh_registry(authoritative)
	for _, rid in ipairs(self.reg:rids()) do
		local entry, model = self.registry[rid], self.models[rid]
		if model then
			if self:take_name(entry, model) then
				self:mark()
			end
			local fields = self:fields_from_model(model)
			fields.name, fields.hue_room_rid, fields.hue_room = nil, nil, nil  -- name above, rooms in step 3
			local caps = fields.caps
			fields.caps = nil
			if not same_caps(caps, entry.caps) then
				fields.caps = caps
			end
			if self:refresh_fields(rid, fields, authoritative and lights.REFRESH_CLEARS or nil) then
				self:mark()
			end
		end
	end
end

-- Messages -----------------------------------------------------------------

-- HUE_CONFIGURE params from a registry entry: the lights-design fields plus
-- hue_room (the group label, absent for no room), id_v1, and state "gone"
-- with gone_since while the light is missing (absent means linked) (§4).
-- The name, the room label and the model are display names
-- (util.display_name): the light shows them in its Hue Name, Hue Room and
-- Model rows, and its own Adopt Hue Name renames to the name (security
-- review 2026-10-25 finding 8). The registry keeps the bridge's own.
function lights.configure_params(_self, rid, entry)
	local extra = { hue_room = util.display_name(entry.hue_room), id_v1 = entry.id_v1 }
	if entry.state == "gone" then
		extra.state = "gone"
		extra.gone_since = entry.gone_since
	end
	local params = hue_model.registry_configure_params(rid, entry, extra)
	params.name, params.model = owner.shown(params.name), owner.shown(params.model)
	return params
end

-- send_configure and configure_changed are bridge/owner.lua's (through tell()).

-- Full HUE_STATE to a registered light that has a model.
function lights:send_state(rid, reason)
	local entry, model = self.registry[rid], self.models[rid]
	if not entry or not model then
		return false
	end
	self:tell(entry.device_id, "HUE_STATE", hue_model.state_params(model, nil, reason))
	return true
end

-- push is bridge/owner.lua's: HUE_CONFIGURE (when asked for, or when it
-- changed) then full HUE_STATE, nothing at all while the light has no model
-- (OPTIONS.push_needs_state). The state is known once the light is modelled.
function lights:state_known(rid)
	return self.models[rid] ~= nil
end

-- A light that left the bridge: HUE_CONFIGURE with state "gone" and
-- ONLINE false through HUE_STATE (§3). The device keeps everything else.
function lights:announce_gone(rid, reason)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	self:send_configure(rid)
	self:tell(entry.device_id, "HUE_STATE", { rid = rid, online = "false", reason = reason or "event" })
	return true
end

-- configure_all (HUE_CONFIGURE to every registered, bound light from the
-- persisted entry at startup, then the hellos that waited for load(), §4),
-- clear_conflicts_for, answer_hello (configuration and full state once the
-- light is modelled), mark_missing, answer_device (R6: a linked light a
-- synced run lacks is marked gone at its hello) and adopt are
-- bridge/owner.lua's; these are the hooks they take.

-- A hello's `name` or `model` as the light sent it: a non-empty string, else
-- nil (code analysis 2026-10-22 R11).
local hello_text = owner.hello_text

-- The model of a rid on the bridge, and the registry fields it supplies.
function lights:record_of(rid)
	return self.models[rid]
end

function lights:fields_of(model)
	return self:fields_from_model(model)
end

-- What a light's hello adds to an adoption: its name and model when the
-- bridge has no model for the rid (strings only, R11).
function lights.hello_fields(_self, fields, hello)
	fields.name = fields.name or hello_text(hello.name)
	fields.model = fields.model or hello_text(hello.model)
end

-- The "gone" rule: a full GET has succeeded in this run.
function lights:fetched()
	return self.synced
end

function lights.adopted_label(_self, rid, entry)
	return tostring(entry.name or rid)
end

-- What a hello leaves in `announced`, for Link Devices.
function lights.announcement(_self, rid, params)
	return { rid = rid, name = hello_text(params.name), model = hello_text(params.model) }
end

-- hello (HUE_HELLO { rid?, device_id?, name?, model? }: §4 auto-adopt, at
-- most EARLY_HELLOS_MAX waiting for load()), goodbye (HUE_GOODBYE: the entry
-- becomes a tombstone, §3) and on_binding_changed are bridge/owner.lua's.

-- Reconciliation (§5) ------------------------------------------------------------

-- Step 1, the project side (the bound set and the hue_light devices in the
-- project; called by driver.lua at late init and here after every resync
-- and import) is bridge/owner.lua's reconcile. Right after the registry's
-- step it warns, once per run, about an entry whose device another module
-- owns (a zone light a build without kinds adopted as a light,
-- docs/zone-light-design.md §7 Q11): the device exists, so it is not
-- tombstoned, and it is never messaged (tell()); Forget Light drops the entry.
function lights:reconciled()
	local skip = self:skip_set()
	if next(skip) ~= nil then
		for _, rid in ipairs(self.reg:rids()) do
			local entry = self.registry[rid]
			if skip[entry.device_id] and not self.foreign_logged[rid] then
				self.foreign_logged[rid] = true
				self.ctx.log.warn("lights: %s (device %d) is registered as a light, but the device is a zone light; "
					.. "Forget Light drops the stale entry (the device stays bound)", self:entry_label(rid, entry),
					entry.device_id)
			end
		end
	end
end

-- Step 2, the lights: a registered rid absent from /light is "gone" (the
-- light hears state gone and ONLINE false); back again is "linked"; a rid
-- with neither entry nor tombstone is new, logged once with a re-link hint.
function lights:reconcile_lights()
	for _, rid in ipairs(self.reg:rids()) do
		local entry, model = self.registry[rid], self.models[rid]
		if model then
			if entry.state == "gone" and self.reg:set_state(rid, "linked") then
				self:mark()
				self.ctx.log.always("lights: %s (device %d) is back on the bridge", self:entry_label(rid, entry),
					entry.device_id)
			end
		elseif entry.state == "linked" and self.reg:set_state(rid, "gone") then
			self:mark()
			self.ctx.log.warn("lights: %s (device %d) is no longer on the bridge; marked gone "
				.. "(Re-link Device To Light or Forget Light)", self:entry_label(rid, entry), entry.device_id)
			self:announce_gone(rid, "resync")
		end
	end
	for _, model in ipairs(self:new_models()) do
		self:announce_new(model)
	end
end

-- Step 3, the rooms: every modelled entry's hue_room_rid and label from the
-- group cache, and every mapping's hue_name. Returns the rids whose label
-- changed (their HUE_CONFIGURE changes with it). Nothing is judged from a
-- cache the run has not filled yet (an event before the first resync).
function lights:reconcile_rooms()
	local changed = {}
	if not self.groups_loaded then
		return changed
	end
	for _, rid in ipairs(self.reg:rids()) do
		local entry, model = self.registry[rid], self.models[rid]
		if model then
			local room_rid, label = self:hue_room_of(model)
			if entry.hue_room_rid ~= room_rid or entry.hue_room ~= label then
				self.reg:update(rid, { hue_room_rid = room_rid or registry.CLEAR, hue_room = label or registry.CLEAR })
				self:mark()
				changed[#changed + 1] = rid
				self.ctx.log.info("lights: %s is in Hue room %s", self:entry_label(rid, entry), label or "(no room)")
			end
		end
	end
	for group_rid, mapping in pairs(self.reg:room_mappings()) do
		local group = self.groups:group(group_rid)
		if group and group.name and mapping.hue_name ~= group.name then
			mapping.hue_name = group.name
			self:mark()
		end
	end
	return changed
end

-- Step 5, the fan-out: HUE_STATE (and HUE_CONFIGURE first when asked or
-- changed) to every linked light with a model. Returns the number of lights told.
function lights:fanout(reason, with_configure)
	local sent = 0
	for _, rid in ipairs(self.reg:rids()) do
		if self.registry[rid].state ~= "unbound" and self:push(rid, reason, with_configure) then
			sent = sent + 1
		end
	end
	self.configured_once = true
	return sent
end

-- The one-time Map Rooms By Name at the first resync of this build [Q 5]:
-- exact matches only, affects only future adds, guarded by a persisted flag.
-- Waits for a resync in which both the groups and the project are known.
function lights:automap_once()
	if not self.automapped and self.ctx.persist_get(lights.AUTOMAP_KEY) then
		self.automapped = true  -- read once per run, not once per resync
	end
	if self.automapped then
		return false
	end
	if #self.groups:groups() == 0 or next(self.project:rooms()) == nil then
		return false
	end
	local text = self:map_rooms_by_name(true)
	self.ctx.persist_set(lights.AUTOMAP_KEY, "done")
	self.automapped = true
	self.ctx.log.always("lights: one-time Map Rooms By Name at the first resync of this build: %s", text)
	return true
end

-- After a full fetch has been absorbed: steps 1, 2, 3 and 5 in order, one
-- save. Returns the number of HUE_STATE messages the fan-out sent.
function lights:settle(reason, with_configure)
	self.synced = true
	self:reconcile(true)
	self:reconcile_lights()
	self:reconcile_rooms()
	self:automap_once()
	local sent = self:fanout(reason, with_configure)
	self:flush()
	return sent
end

-- Resync ---------------------------------------------------------------------

-- resync is bridge/owner.lua's: after every stream connect the six GETs,
-- the reconciliation (settle), then full HUE_STATE (reason "resync") to every
-- registered light, with HUE_CONFIGURE first the first time or when it
-- changed; done(ok, err, sent); every caller that waited is answered once
-- (code analysis 2026-10-22 F2, issue #47).

-- Event fan-out --------------------------------------------------------------

-- A light item of an event container. Returns the number of messages sent.
function lights:on_light_item(item, kind)
	local rid = item.id
	local entry, model = self.registry[rid], self.models[rid]
	if kind == "add" then
		local fresh = hue_model.light(item)
		if not fresh then
			return 0  -- an id that is not a resource id (hue_model logged it)
		end
		if model then
			fresh.online = model.online
		end
		self.models[rid] = fresh
		self:track_offline(rid, fresh)
		if entry then
			-- A gone light is back (re-added in the Hue app with the same rid).
			if entry.state == "gone" and self.reg:set_state(rid, "linked") then
				self:mark()
				self.ctx.log.always("lights: %s (device %d) is back on the bridge", self:entry_label(rid, entry),
					entry.device_id)
			end
			self:refresh_registry()
			local told = 0
			for _, other in ipairs(self:reconcile_rooms()) do
				if other ~= rid and self.registry[other].state ~= "unbound" and self:send_configure(other) then
					told = told + 1
				end
			end
			return told + (self:push(rid, "event", true) and 1 or 0)
		end
		if not self:is_tombstoned(rid) then
			self:announce_new(fresh)
		end
		return 0
	elseif kind == "delete" then
		self.models[rid] = nil
		self.offline_since[rid] = nil
		if entry and entry.state == "linked" then
			-- [Q 11] gone at once, not at the next full GET.
			if self.reg:set_state(rid, "gone") then
				self:mark()
			end
			self.ctx.log.warn("lights: %s (device %d) was deleted on the bridge; marked gone "
				.. "(Re-link Device To Light or Forget Light)", self:entry_label(rid, entry), entry.device_id)
			return self:announce_gone(rid, "event") and 1 or 0
		end
		if not entry then
			self.ctx.log.info("lights: unimported light %s was deleted on the bridge", tostring(rid))
		end
		return 0
	end
	if not model then
		return 0
	end
	local changed = hue_model.update(model, item)
	if entry and has_field(changed, "name") and self:take_name(entry, model) then
		self:mark()
	end
	if not entry or entry.state == "unbound" then
		return 0
	end
	local params = hue_model.state_params(model, changed, "event")
	if hue_model.has_state(params) then
		self:tell(entry.device_id, "HUE_STATE", params)
		return 1
	end
	return 0
end

-- A zigbee_connectivity item: online for the device's lights (and its MAC,
-- when the item carries it). Returns the number of messages sent.
function lights:on_connectivity_item(item)
	local conn = hue_model.connectivity(item)
	if conn.device_rid and conn.mac_address then
		self.macs[conn.device_rid] = conn.mac_address
	end
	if item.status == nil then
		return 0
	end
	local sent = 0
	local device = self.devices[conn.device_rid]
	for _, rid in ipairs(device and device.light_rids or {}) do
		local entry, model = self.registry[rid], self.models[rid]
		if model then
			model.online = conn.online
			self:track_offline(rid, model)
		end
		if entry and model and entry.state ~= "unbound" then
			self:tell(entry.device_id, "HUE_STATE", hue_model.state_params(model, { "online" }, "event"))
			sent = sent + 1
		end
	end
	return sent
end

-- A device item: a new device record, a renamed device, or a deleted one.
function lights:on_device_item(item, kind)
	if kind == "add" then
		local parsed = hue_model.devices({ item })
		if parsed[item.id] then  -- nil for an id that is not a resource id
			self.devices[item.id] = parsed[item.id]
		end
	elseif kind == "delete" then
		self.devices[item.id] = nil
		self.macs[item.id] = nil
	elseif kind == "update" then
		local device = self.devices[item.id]
		if device and type(item.metadata) == "table" and item.metadata.name ~= nil then
			device.name = tostring(item.metadata.name)
			for _, rid in ipairs(device.light_rids) do
				local entry = self.registry[rid]
				if entry and entry.device_name ~= device.name then
					self.reg:update(rid, { device_name = device.name })
					self:mark()
				end
			end
		end
	end
end

-- The group cache changed: refresh the rooms (step 3) and tell the lights
-- whose room label changed. Returns the number of HUE_CONFIGUREs sent.
function lights:on_groups_changed()
	local sent = 0
	for _, rid in ipairs(self:reconcile_rooms()) do
		if self.registry[rid].state ~= "unbound" and self:send_configure(rid) then
			sent = sent + 1
		end
	end
	return sent
end

-- One event-stream container. Returns the number of lights told something
-- (a gone light hears HUE_CONFIGURE and HUE_STATE and counts once). Runs
-- inside OnBodyChunk: no transfers are started here. Every handler is
-- idempotent and resolves owners through the cache, since `delete` items
-- carry only id and type and item order within a container is undocumented.
local function on_container_body(self, container)
	if type(container) ~= "table" or type(container.data) ~= "table" then
		return 0
	end
	-- The zone-light skip set once per container (foreign() builds it at its
	-- first use) rather than once per message; dropped before returning, and
	-- reset here so an error that escaped the last container leaves no stale one.
	self.skip_cache = false
	local sent, groups_changed = 0, false
	local kind = container.type
	for _, item in ipairs(container.data) do
		if type(item) == "table" and item.id ~= nil then
			if item.type == "light" then
				sent = sent + self:on_light_item(item, kind)
			elseif item.type == "zigbee_connectivity" then
				sent = sent + self:on_connectivity_item(item)
			elseif item.type == "device" then
				self:on_device_item(item, kind)
			elseif item.type == "room" or item.type == "zone" or item.type == "bridge_home" then
				if self.groups:apply(item, kind) then
					groups_changed = true
				end
			end
		end
	end
	if groups_changed then
		sent = sent + self:on_groups_changed()
	end
	self:flush()
	self.skip_cache = nil
	return sent
end

-- The body under pcall so that an error escaping a container (nothing up
-- the chain catches it) cannot leave the skip-set cache set for the hellos
-- and forgets that follow (docs/reviews/diff-review-2026-10-24.md).
function lights:on_container(container)
	local ok, result = pcall(on_container_body, self, container)
	self.skip_cache = nil
	if not ok then
		error(result, 0)
	end
	return result
end

-- Device creation ---------------------------------------------------------------

-- The busy flags (expire_stale_busy, busy_text: the text an action gets
-- while another is running, §6) are bridge/owner.lua's.

-- Composer name at creation (§7): the Hue device name for a single-light
-- device (what the Hue app shows), the light's own name on a multi-light device
-- or when the device name has nothing to show (a JSON null decodes as a
-- table). Raw: owner:new_device_name makes it a display name for AddDevice.
function lights:creation_name(model)
	local device = self.devices[model.device_rid]
	if device and util.display_name(device.name) ~= "" and #device.light_rids <= 1 then
		return device.name
	end
	return model.name
end

-- The AddDevice chain (create: one at a time, each bound, registered and
-- saved at once, then told; a light deleted on the bridge while its
-- AddDevice was pending is registered gone, R6) is bridge/owner.lua's.

-- Actions (§6) -------------------------------------------------------------------

-- Add Light: one AddDevice into room_id, or into the mapped room of the
-- light's Hue room when nil; refuses when neither exists [Q 9]. A tombstone
-- for the rid is cleared by the registry. done(ok, text).
function lights:add_light(rid, room_id, done)
	done = done or function() end
	local busy = self:busy_text()
	if busy then
		done(false, busy)
		return false
	end
	if type(rid) ~= "string" or rid == "" then
		done(false, "Not added: pick a light first")
		return false
	end
	local entry = self.registry[rid]
	if entry then
		done(false, string.format("Not added: %s is already imported (device %d)", self:entry_label(rid, entry),
			entry.device_id))
		return false
	end
	local model = self.models[rid]
	if not model then
		done(false, string.format("Not added: light %s is not on the bridge (connect the event stream and try again)",
			tostring(rid)))
		return false
	end
	local room_name
	room_id, room_name = self:room_for_add(model, room_id, self.project:rooms())
	if not room_id then
		done(false, room_name)
		return false
	end

	self.importing, self.importing_since = true, os.time()
	local label = self:light_label(model, false)
	self:create({ { record = model, room_id = room_id, room_name = room_name } }, function(created, _, err)
		self.importing = false
		self:reconcile(true, owner.created_set(created))
		self:flush()
		local text
		if created[1] then
			text = string.format("Added %s to %s (device %d)", label, room_name, created[1].device_id)
		elseif err then
			text = "Not added: " .. err
		else
			text = string.format("Not added: AddDevice failed for %s (see the Lua output)", label)
		end
		self.ctx.log.always("lights: %s", text)
		self:protect("add_light done", done, created[1] ~= nil, text)
		self:run_pending_resync()
	end)
	return true
end

-- Import All New Lights: the six GETs, the reconciliation, then one
-- AddDevice per unimported, non-tombstoned light with a mapped Hue room,
-- into that room; lights in an unmapped room, in no room, or deleted in
-- Composer are skipped and listed [Q 1, Q 4]. Idempotent by rid; never
-- renames, moves or rebinds. done(ok, text) once, at the end.
function lights:import_new(done)
	done = done or function() end
	local busy = self:busy_text()
	if busy then
		done(false, busy)
		return false
	end
	self.importing, self.importing_since = true, os.time()
	self.ctx.log.info("lights: import: fetching the bridge's resources")

	local function finish(ok, text)
		self.importing = false
		self.ctx.log.always("lights: %s", text)
		self:protect("import done", done, ok, text)
		self:run_pending_resync()
	end

	self:fetch_all(function(res, err)
		if not res then
			return finish(false, "Import failed: " .. tostring(err))
		end
		local ok, e = pcall(self.import_fetched, self, res, finish)
		if not ok then
			self.ctx.log.error("lights: import failed: %s", tostring(e))
			finish(false, "Import failed: " .. tostring(e))
		end
	end)
	return true
end

-- The part of the import that runs once the GETs are in.
function lights:import_fetched(res, finish)
	self:absorb(res)
	self:settle("resync", not self.configured_once)

	local rooms = self.project:rooms()
	local jobs, unmapped, deleted = {}, {}, {}
	for _, model in ipairs(self:unimported_models()) do
		if self:is_tombstoned(model.rid) then
			local tomb = self.reg:tombstones()[model.rid]
			deleted[#deleted + 1] = string.format("%s (deleted %s)", self:light_label(model, false),
				date_of(tomb.deleted_at))
		else
			local room_id, why = self:default_room(model, rooms)
			if room_id then
				jobs[#jobs + 1] = { record = model, room_id = room_id, room_name = why }
			else
				unmapped[#unmapped + 1] = string.format("%s (%s)", self:light_label(model, false), why)
			end
		end
	end

	local function summary(created, failed, err)
		local parts = {}
		if #created > 0 then
			local names = {}
			for _, c in ipairs(created) do
				names[#names + 1] = string.format("%s to %s (device %d)", self:light_label(c.record, false),
					tostring(c.room_name), c.device_id)
			end
			parts[#parts + 1] = string.format("Added %s: %s", plural(#created, "new light"), table.concat(names, ", "))
		elseif #jobs == 0 and #unmapped == 0 and #deleted == 0 then
			parts[#parts + 1] = string.format("No new lights on the bridge (%d on bridge, %d imported)",
				self:bridge_count(), self:count())
		else
			parts[#parts + 1] = "Added no lights"
		end
		if #failed > 0 then
			local names = {}
			for _, model in ipairs(failed) do
				names[#names + 1] = self:light_label(model, false)
			end
			parts[#parts + 1] = string.format("AddDevice failed for %d: %s", #failed, table.concat(names, ", "))
		end
		if err then
			parts[#parts + 1] = "stopped early: " .. err
		end
		if #unmapped > 0 then
			parts[#parts + 1] = string.format("skipped %d with no mapped room (Set Room Mapping or Add Light): %s",
				#unmapped, table.concat(unmapped, ", "))
		end
		if #deleted > 0 then
			parts[#parts + 1] = string.format("skipped %d deleted in Composer (Add Light re-creates one): %s",
				#deleted, table.concat(deleted, ", "))
		end
		return table.concat(parts, "; ")
	end

	self:create(jobs, function(created, failed, err)
		self:reconcile(true, owner.created_set(created))
		self:flush()
		finish(err == nil and #failed == 0, summary(created, failed, err))
	end)
end

-- Re-link Device To Light, Forget Light, HUE_FORGET and Link Devices are
-- bridge/owner.lua's (relink, forget, forget_request, link_devices); these
-- are the hooks they take. A device another module owns (a zone light) is
-- never re-linked, and Forget Light on one only drops the stale entry.
function lights.relink_refusal(_self, _device_id, new_rid)
	return string.format("Not re-linked: light %s is not on the bridge (connect the event stream and try again)",
		tostring(new_rid))
end

-- "Porch [Outdoor] #53": how Link Devices and Re-link name a light on the bridge.
function lights:record_label(model)
	return self:light_label(model)
end

-- A forgotten entry's foreign-entry warning may come again.
function lights:forgot(rid)
	self.foreign_logged[rid] = nil
end

-- Link Devices' candidates: scene devices share binding 1
-- (docs/scenes-design.md) and zone-light devices share the driver, so only
-- hue_light devices outside the skip set (ctx.skip_devices plus `skip_ids`,
-- a set or a list: the zone lights' devices, docs/zone-light-design.md §4)
-- are candidates. Without the project lookup every bound device outside the
-- skip set is considered, as before scene devices existed. Returns the ids
-- the registry lacks and how many candidates there are.
function lights:link_candidates(bound, skip_ids)
	local in_project = self:project_lights()
	local skip = self:skip_set(skip_ids)
	local ids, total = {}, 0
	for id in pairs(bound) do
		local n = positive(id)
		if n and not skip[n] and (not in_project or in_project[n]) then
			total = total + 1
			if not self.reg:by_device(n) then
				ids[#ids + 1] = n
			end
		end
	end
	return ids, total
end

function lights:linked_label(rid, entry)
	return self:registered_label(rid, entry), self.models[rid] and "" or " (not on the bridge: marked gone)"
end

-- The unimported lights whose Hue name (or device name) is wanted (keys of
-- util.name_key, as owner:match_unimported_by_name builds them).
function lights:unimported_named(wanted)
	local out = {}
	for _, model in ipairs(self:unimported_models()) do
		local device = self.devices[model.device_rid]
		if wanted[util.name_key(model.name)] or (device and wanted[util.name_key(device.name)]) then
			out[#out + 1] = model
		end
	end
	return out
end

-- The names trio is bridge/owner.lua's (name_differences, adopt_hue_names,
-- accept_names). The name a linked light's device should carry is its
-- creation name (owner:expected_name, creation_name above: the Hue device's
-- name for the only light of its device, else the light's own name), and
-- Adopt Hue Names renames to it [Q 10]. Until #236 it was the light's own
-- name, so a light imported under its device's other name was listed as a
-- difference at once. These names agree as well, so the change reports no
-- rename that did not happen in Hue:
--   - the light's own name: what earlier builds compared with, what their
--     Adopt Hue Names renamed to and Accept Names As They Are recorded, and
--     what the light device's own Adopt Hue Name renames to (its Hue Name
--     row);
--   - the device name the registry cached, while this run has not read the
--     bridge's devices: right after a start the creation name falls back to
--     the light's own name, not knowing whether the device has other lights.
function lights:agreeing_names(_rid, entry)
	if self.devices[entry.device_rid] then
		return { entry.name }
	end
	return { entry.name, entry.device_name }
end

-- The label of a Hue group for mapping texts: the cached group's, or the
-- mapping's remembered name, marked deleted in Hue only once this run has
-- fetched the groups (right after a reload the cache is simply empty
-- [verified: hardware 2026-10-21, every mapping read "(deleted in Hue)"]).
function lights:group_label(group_rid, mapping)
	if self.groups:group(group_rid) then
		return self.groups:label(group_rid)
	end
	if mapping then
		local label = tostring(mapping.hue_name or group_rid) .. (mapping.type == "zone" and " (zone)" or "")
		if self.groups_loaded then
			label = label .. " (deleted in Hue)"
		end
		return label
	end
	return tostring(group_rid)
end

-- Set Room Mapping: Hue room or zone → Control4 room; room_id nil removes
-- the mapping. Affects only future adds. Returns ok, text.
function lights:set_room_mapping(group_rid, room_id)
	local busy = self:busy_text()
	if busy then
		return false, busy
	end
	if type(group_rid) ~= "string" or group_rid == "" then
		return false, "Not mapped: pick a Hue room first"
	end
	local group = self.groups:group(group_rid)
	local existing = self.reg:room_mapping(group_rid)
	if group and group.type == "bridge_home" then
		return false, "Not mapped: the whole bridge cannot be mapped to one room"
	end
	if not group and not existing then
		return false, string.format("Not mapped: Hue room %s is not on the bridge (connect the event stream and try again)",
			tostring(group_rid))
	end
	local label = self:group_label(group_rid, existing)
	if room_id == nil then
		if not existing then
			return true, string.format("No mapping for %s to remove", label)
		end
		self.reg:remove_room_mapping(group_rid)
		self:mark()
		self:flush()
		local text = string.format("Removed the mapping for %s", label)
		self.ctx.log.always("lights: %s", text)
		return true, text
	end
	room_id = positive(room_id)
	if not room_id then
		return false, "Not mapped: pick a Control4 room or (no mapping)"
	end
	local rooms = self.project:rooms()
	local name = rooms[room_id]
	if not name then
		if next(rooms) ~= nil then
			return false, string.format("Not mapped: Control4 room %d does not exist", room_id)
		end
		name = "room " .. tostring(room_id)
	end
	self.reg:set_room_mapping(group_rid, {
		c4_room_id = room_id,
		c4_room_name = name,
		hue_name = group and group.name or existing.hue_name,
		type = group and group.type or existing.type,
	})
	self:mark()
	self:flush()
	local text = string.format("Mapped %s → %s", label, name)
	self.ctx.log.always("lights: %s", text)
	return true, text
end

-- Map Rooms By Name: exact, case-insensitive, trimmed matches between Hue
-- rooms/zones and Control4 rooms; never overrides a mapping; a name two
-- Control4 rooms share is left alone. Returns the report text. `internal`
-- skips the busy check (the one-time run inside a resync).
function lights:map_rooms_by_name(internal)
	if not internal then
		local busy = self:busy_text()
		if busy then
			return busy
		end
	end
	local all = self.groups:groups()
	if #all == 0 then
		return "Nothing mapped: no Hue rooms fetched yet (connect the event stream and try again)"
	end
	local rooms = self.project:rooms()
	if next(rooms) == nil then
		return "Nothing mapped: no Control4 rooms found in the project"
	end
	local by_key = {}
	for id, name in pairs(rooms) do
		local key = norm(name)
		local hit = by_key[key]
		if hit then
			hit.count = hit.count + 1
		else
			by_key[key] = { id = id, name = name, count = 1 }
		end
	end

	local mapped, kept, unmatched, ambiguous = {}, 0, {}, {}
	for _, group in ipairs(all) do
		local label = self.groups:label(group.rid)
		if self.reg:room_mapping(group.rid) then
			kept = kept + 1
		else
			local hit = by_key[norm(group.name)]
			if not hit then
				unmatched[#unmatched + 1] = label
			elseif hit.count > 1 then
				ambiguous[#ambiguous + 1] = string.format("%s (%d Control4 rooms are named %s)", label, hit.count, hit.name)
			else
				self.reg:set_room_mapping(group.rid, { c4_room_id = hit.id, c4_room_name = hit.name, hue_name = group.name,
					type = group.type })
				self:mark()
				mapped[#mapped + 1] = string.format("%s → %s", label, hit.name)
			end
		end
	end
	if not internal then
		self:flush()
	end
	local parts = {}
	if #mapped > 0 then
		parts[#parts + 1] = string.format("Mapped %d: %s", #mapped, table.concat(mapped, ", "))
	else
		parts[#parts + 1] = "Nothing new to map"
	end
	if kept > 0 then
		parts[#parts + 1] = string.format("%d already mapped (kept)", kept)
	end
	if #unmatched > 0 then
		parts[#parts + 1] = string.format("no Control4 room named: %s", table.concat(unmatched, ", "))
	end
	if #ambiguous > 0 then
		parts[#parts + 1] = string.format("ambiguous: %s", table.concat(ambiguous, ", "))
	end
	local text = table.concat(parts, "; ")
	if not internal then
		self.ctx.log.always("lights: %s", text)
	end
	return text
end

-- Room Audit: every linked device whose Control4 room (GetDevices → roomId)
-- differs from the room its Hue room maps to, as a drag list [Q 12]. Reads
-- only; nothing is moved (no API exists). `extra` audits another module's
-- devices in the same list (the zone lights, docs/zone-light-design.md §4):
-- a list of { device_id, name, group_rid }, each checked after the lights
-- against the mapping of `group_rid` (the zone or room the device stands
-- for), with the lights' texts; `name` is the fallback when the project has
-- no name for the device. An entry whose group has no mapping, whose id is
-- not positive or whose device a light already holds is left out, as a light
-- in an unmapped room is. Returns the text.
function lights:room_audit(extra)
	if next(self.reg:room_mappings()) == nil then
		return "No room mappings; use Map Rooms By Name or Set Room Mapping first"
	end
	local checks, ids, seen = {}, {}, {}
	local function check(device_id, name, group_rid)
		local mapping = self.reg:room_mapping(group_rid)
		if mapping and mapping.c4_room_id and not seen[device_id] then
			seen[device_id] = true
			checks[#checks + 1] = { device_id = device_id, name = name, group_rid = group_rid, mapping = mapping }
			ids[#ids + 1] = tostring(device_id)
		end
	end
	for _, rid in ipairs(self.reg:rids("linked")) do
		local entry = self.registry[rid]
		check(entry.device_id, entry.name, entry.hue_room_rid)
	end
	for _, x in ipairs(type(extra) == "table" and extra or {}) do
		local device_id = type(x) == "table" and positive(x.device_id) or nil
		if device_id and type(x.group_rid) == "string" and x.group_rid ~= "" then
			check(device_id, x.name, x.group_rid)
		end
	end
	if #checks == 0 then
		return "Nothing to audit: no linked light is in a mapped Hue room"
	end
	local ok, raw = self.project:call("devices", { DeviceIds = table.concat(ids, ",") })
	if not ok or type(raw) ~= "table" or next(raw) == nil then
		return "Room Audit unavailable: the project lookup returned nothing (see the Lua output)"
	end
	local infos = {}
	for id, info in pairs(raw) do
		infos[tonumber(id) or id] = info
	end
	local rooms = self.project:rooms()
	local lines, unknown = {}, 0
	for _, c in ipairs(checks) do
		local info = infos[c.device_id]
		if type(info) ~= "table" then
			unknown = unknown + 1
		elseif tonumber(info.roomId) ~= c.mapping.c4_room_id then
			local name = tostring(info.deviceName or c.name or ("device " .. tostring(c.device_id)))
			local hue_room = self:group_label(c.group_rid, c.mapping)
			local target = rooms[c.mapping.c4_room_id]
			if target then
				lines[#lines + 1] = string.format("%s is in %s; Hue says %s → drag it to %s in Composer if you want it there",
					name, tostring(info.roomName or info.roomId), hue_room, target)
			else
				lines[#lines + 1] = string.format("%s is in %s; Hue says %s, mapped to a Control4 room that no longer exists "
					.. "(Set Room Mapping)", name, tostring(info.roomName or info.roomId), hue_room)
			end
		end
	end
	local text
	if #lines == 0 then
		if #checks == 1 then
			text = "All 1 linked light in a mapped Hue room is in the room its Hue room maps to"
		else
			text = string.format("All %d linked lights in mapped Hue rooms are in the rooms their Hue rooms map to", #checks)
		end
	else
		text = string.format("%d of %d are not in the room their Hue room maps to: %s", #lines, #checks,
			table.concat(lines, "; "))
	end
	if unknown > 0 then
		text = text .. string.format("; %d not found in the project", unknown)
	end
	self.ctx.log.always("lights: Room Audit: %s", text)
	return text
end

-- Texts (§6) -----------------------------------------------------------------------

-- The Lights row (owner:row_summary, docs/list-rows-design.md): "47 lights
-- on bridge, 45 imported, 2 new, 1 missing, 1 deleted" (missing, unbound and
-- deleted only when not 0), new as new_count() counts it; "<n> imported"
-- before the first full GET.
function lights:summary()
	if not self.synced then
		return self:row_summary()
	end
	return self:row_summary(plural(self:bridge_count(), "light"), self:new_count())
end

-- How Attention names a claimed rid: "light Desk Lamp #12" (its entry),
-- "light Porch #53" (on the bridge, not imported) or its rid.
function lights:conflict_label(rid)
	local entry = self.registry[rid]
	local label = tostring(rid)
	if entry then
		label = self:entry_label(rid, entry)
	elseif self.models[rid] then
		label = self:light_label(self.models[rid], false)
	end
	return "light " .. label
end

-- The Attention property: one item per kind of thing waiting for the owner,
-- joined with "; ", or "None".
function lights:attention()
	local items = {}

	-- Sorted (for the names) only when there is something new to name.
	local new = self:new_count() > 0 and self:new_models() or {}
	if #new > 0 then
		local names = {}
		for _, model in ipairs(new) do
			names[#names + 1] = self:light_label(model) .. (self:hint_text(model) or "")
		end
		items[#items + 1] = string.format("%s on the bridge: %s (Add Light or Import All New Lights)",
			plural(#new, "new light"), util.some(names, lights.MAX_NAMED))
	end

	-- Missing lights, unbound devices, two devices claiming one light, name
	-- differences: bridge/owner.lua's items, with the lights' words.
	self:attention_items(items)

	local rooms = self.project:rooms()
	if next(rooms) ~= nil then
		local broken = {}
		for group_rid, mapping in pairs(self.reg:room_mappings()) do
			if mapping.c4_room_id and not rooms[mapping.c4_room_id] then
				broken[#broken + 1] = self:group_label(group_rid, mapping)
			end
		end
		table.sort(broken)
		if #broken > 0 then
			items[#items + 1] = string.format("%d room mapping%s point%s at a Control4 room that no longer exists: %s "
				.. "(Set Room Mapping)", #broken, #broken == 1 and "" or "s", #broken == 1 and "s" or "",
				util.some(broken, lights.MAX_NAMED))
		end
	end

	local now = self.ctx.now()
	local offline = {}
	for _, rid in ipairs(self.reg:rids("linked")) do
		local since = self.offline_since[rid]
		if since and now - since >= lights.OFFLINE_NAG_S then
			offline[#offline + 1] = self:entry_label(rid, self.registry[rid])
		end
	end
	if #offline > 0 then
		items[#items + 1] = string.format("%s offline for more than 24 h: %s", plural(#offline, "light"),
			util.some(offline, lights.MAX_NAMED))
	end

	if #items == 0 then
		return "None"
	end
	return table.concat(items, "; ")
end

-- Every cached room and zone (rooms first, each sorted by name), then every
-- mapping whose Hue group is gone, in the order the Room Mappings list and
-- Set Room Mapping's Hue Room picker show them: fn(group_rid, label, mapping)
-- per row, the mapping nil for an unmapped group. Returns how many cached
-- groups have no mapping.
function lights:each_mapping_row(fn)
	local mappings = self.reg:room_mappings()
	local seen, unmapped = {}, 0
	for _, group in ipairs(self.groups:groups()) do
		seen[group.rid] = true
		if not mappings[group.rid] then
			unmapped = unmapped + 1
		end
		fn(group.rid, self.groups:label(group.rid), mappings[group.rid])
	end
	local stale = {}
	for group_rid, mapping in pairs(mappings) do
		if not seen[group_rid] then
			stale[#stale + 1] = { rid = group_rid, name = mapping.hue_name or group_rid, mapping = mapping }
		end
	end
	table.sort(stale, by_name)
	for _, s in ipairs(stale) do
		fn(s.rid, self:group_label(s.rid, s.mapping), s.mapping)
	end
	return unmapped
end

-- The Room Mappings property: one "Hue room → Control4 room" line per Hue
-- room and zone ("(unmapped)" or "(Control4 room gone)" when so), then the
-- mappings whose group is gone from Hue, plus how many groups have no
-- mapping; an empty list while no mapping exists at all. The bridge shows
-- them as the `Room Mappings` drop-down.
function lights:room_mapping_items()
	if next(self.reg:room_mappings()) == nil then
		return {}, 0
	end
	local rooms = self.project:rooms()
	local parts = {}
	local unmapped = self:each_mapping_row(function(_, label, mapping)
		parts[#parts + 1] = string.format("%s → %s", label, self:mapping_target(mapping, rooms))
	end)
	return parts, unmapped
end

-- The same mappings as one "; "-joined line.
function lights:room_mappings_text()
	local parts = self:room_mapping_items()
	if #parts == 0 then
		return "None; use Map Rooms By Name"
	end
	return table.concat(parts, "; ")
end

-- Pickers (§8): { text, value } arrays, value a string; one explanatory
-- entry with value "" when there is nothing to pick ------------------------------

-- Add Light / Re-link's Light: the unimported lights, re-link suggestions
-- first, tombstoned ones marked with their Composer deletion date.
function lights:picker_lights()
	if not self.synced then
		return empty_list("(no lights fetched yet; connect the event stream)")
	end
	local hinted, plain, deleted = {}, {}, {}
	for _, model in ipairs(self:unimported_models()) do
		local tomb = self.reg:tombstones()[model.rid]
		if tomb then
			deleted[#deleted + 1] = { text = string.format("%s (deleted from Composer %s)", self:light_label(model),
				date_of(tomb.deleted_at)), value = model.rid }
		else
			local hint = self:hint_text(model)
			if hint then
				hinted[#hinted + 1] = { text = self:light_label(model) .. hint, value = model.rid }
			else
				plain[#plain + 1] = { text = self:light_label(model), value = model.rid }
			end
		end
	end
	local list = {}
	for _, part in ipairs({ hinted, plain, deleted }) do
		for _, item in ipairs(part) do
			list[#list + 1] = item
		end
	end
	if #list == 0 then
		return empty_list("(every light on the bridge is imported)")
	end
	return list
end

-- Control4 rooms as "Floor / Room" (the id appended when two rooms share a
-- name), sorted; mode "add" starts with "(mapped room)" (value "mapped": an
-- empty value leaves Composer's Select dialog with OK disabled [hardware
-- 2026-10-22]; tonumber() makes it nil, the mapping, like an empty Room), mode
-- "mapping" with "(no mapping)" (value "none").
function lights:picker_rooms(mode)
	local rooms = self.project:rooms()
	local floors = self:room_floors()
	local counts = {}
	for _, name in pairs(rooms) do
		counts[name] = (counts[name] or 0) + 1
	end
	local list = {}
	for id, name in pairs(rooms) do
		local text = floors[id] and (floors[id] .. " / " .. name) or name
		if counts[name] > 1 then
			text = text .. " (" .. tostring(id) .. ")"
		end
		list[#list + 1] = { text = sanitise(text), value = tostring(id), key = text:lower() }
	end
	table.sort(list, function(a, b)
		if a.key ~= b.key then
			return a.key < b.key
		end
		return tonumber(a.value) < tonumber(b.value)
	end)
	for _, item in ipairs(list) do
		item.key = nil
	end
	if #list == 0 then
		list = empty_list("(no rooms found in the project)")
	end
	if mode == "add" then
		table.insert(list, 1, { text = "(mapped room)", value = "mapped" })
	elseif mode == "mapping" then
		table.insert(list, 1, { text = "(no mapping)", value = "none" })
	end
	return list
end

-- (owner hook) How the device pickers (owner: picker_relink_devices, the
-- gone and unbound entries; picker_forget_devices, every entry) name an
-- entry: its Hue name in Re-link's ("Desk Lamp (device 1036, gone since
-- 10-24)"), its label in Forget's ("Desk Lamp #12 (device 1036)").
function lights:device_text(rid, entry, rest, relink)
	local name = relink and sanitise(entry.name or rid) or self:entry_label(rid, entry)
	return string.format("%s (device %d%s)", name, entry.device_id, rest or "")
end

-- Set Room Mapping's Hue Room: rooms then zones, each with its mapping, then
-- mappings whose Hue group was deleted (so they can be removed).
function lights:picker_hue_rooms()
	local rooms = self.project:rooms()
	local list = {}
	self:each_mapping_row(function(rid, label, mapping)
		local target = self:mapping_target(mapping, rooms)
		list[#list + 1] = { text = string.format("%s → %s", sanitise(label), sanitise(target)), value = rid }
	end)
	if #list == 0 then
		return empty_list("(no Hue rooms fetched yet; connect the event stream)")
	end
	return list
end

-- Lists (the drop-down properties) ----------------------------------------------

-- The state a list line ends in for a registry entry: " → device N" linked,
-- " (missing; device N)" gone, " (unbound; device N)" unbound.
local function entry_suffix(entry)
	if entry.state == "gone" then
		return string.format(" (missing; device %d)", entry.device_id)
	elseif entry.state == "unbound" then
		return string.format(" (unbound; device %d)", entry.device_id)
	end
	return string.format(" → device %d", entry.device_id)
end

-- The Lights drop-down (the row shows summary()): one line per light on the
-- bridge, "<Hue room>: <light>" with its state, " (new)" when not imported,
-- " (deleted from Composer <date>)" for a tombstone; the registered lights
-- the bridge lacks ("(missing; device N)") under the room they were last
-- seen in. Sorted by room label then name; a light in no room reads "(no
-- room)". Commas become "‚" (U+201A): the list is comma-delimited
-- (driver.lua's refresh_room_mappings). Before the first GET, the registry
-- alone: what is known. Empty when nothing is.
function lights:list_items()
	local tombs = self.reg:tombstones()
	local rows = {}
	-- The sort keys are lower-cased once per row, not twice per comparison
	-- (docs/reviews/efficiency-2026-10-24.md R6).
	local function row(room, name, suffix, rid)
		room, name = tostring(room or "(no room)"), tostring(name or "?")
		rows[#rows + 1] = { room = room, name = name, room_key = room:lower(), name_key = name:lower(), suffix = suffix,
			rid = tostring(rid) }
	end
	for rid, model in pairs(self.models) do
		local _, label = self:hue_room_of(model)
		local entry, tomb = self.registry[rid], tombs[rid]
		local suffix = " (new)"
		if entry then
			suffix = entry_suffix(entry)
		elseif tomb then
			suffix = string.format(" (deleted from Composer %s)", date_of(tomb.deleted_at))
		end
		row(label, model.name, suffix, rid)
	end
	for rid, entry in pairs(self.registry) do
		if not self.models[rid] then
			row(entry.hue_room, entry.name, entry_suffix(entry), rid)
		end
	end
	table.sort(rows, function(a, b)
		if a.room_key ~= b.room_key then
			return a.room_key < b.room_key
		end
		if a.name_key ~= b.name_key then
			return a.name_key < b.name_key
		end
		return a.rid < b.rid
	end)
	local out = {}
	for i, r in ipairs(rows) do
		out[i] = (string.format("%s: %s%s", r.room, r.name, r.suffix):gsub(",", "‚"))
	end
	return out
end

return lights
