-- Registry v2: the bridge's persisted bookkeeping for the lights it represents
-- as Control4 devices, their lifecycle states, the tombstones of devices the
-- owner deleted in Composer, and the Hue room/zone → Control4 room mappings.
-- docs/import-design.md §3 (fields and states), §5 (reconciliation), §13 (this
-- interface). lights.lua owns the flows (import, resync, events); this module
-- owns only the records.
--
-- Pure Lua: persistence goes through the injected persist_get/persist_set and
-- time through `now`, so specs run it on plain functions and nothing here
-- touches the C4 global.
--
-- Three persisted keys, one in-memory table each:
--   "hue_lights"      rid → entry. The Control4 device is the identity and the
--                     rid is re-pointable (§1 rule 3): relink() moves an entry
--                     under a new rid and keeps everything else.
--   "hue_rooms"       Hue room/zone rid → { c4_room_id, c4_room_name, hue_name, type }
--   "hue_tombstones"  rid → { name, device_name, deleted_at }: devices deleted
--                     in Composer; bulk import skips them, Add Light clears them.
--
-- Persistence rules: mutators change memory only and callers save() after a
-- batch (one click, one resync), as the contract says. load() refills the
-- three tables without replacing them, so a reference taken from entries()
-- stays valid across a reload. The module never re-reads after writing: on
-- the controller a PersistGetValue right after PersistSetValue may still
-- return the old value [assumed; lights.lua has worked that way since the
-- spike]. load() on a missing key starts empty.
--
-- Entry fields (§3): device_id, proxy_id, name, device_name, model, caps,
-- device_rid, mac_address, service_id, id_v1, hue_room_rid, state, gone_since,
-- unbound_since, created_room_id, created_at, name_dismissed. add() and
-- update() copy every key they are given, known or not, so a field a later
-- build adds survives a round trip through an older one. Device ids and
-- timestamps are numbers, rids strings. A persisted entry without `state` is
-- v1 and is upgraded to "linked" at load; the other v2 fields stay nil until
-- the next resync fills them. `state` is "linked" | "gone" | "unbound";
-- tombstoned entries leave the table (the §3 "tombstone" state is the
-- hue_tombstones table). gone_since / unbound_since exist exactly while the
-- entry is in that state.
--
-- Invariants add() enforces (anything else is a bug upstream, and a duplicate
-- would make by_device() ambiguous): a non-empty string rid, a positive
-- numeric device_id, and no other entry holding that device.

local default_log = require("common.log")

local registry = {}
registry.__index = registry

registry.LIGHTS_KEY = "hue_lights"
registry.ROOMS_KEY = "hue_rooms"
registry.TOMBSTONES_KEY = "hue_tombstones"

registry.STATES = { linked = true, gone = true, unbound = true }

-- The timestamp a state stamps on entry and clears on exit.
local STAMP = { gone = "gone_since", unbound = "unbound_since" }

-- Pass as a field value to update() to remove that field: a nil in a table
-- literal is invisible to pairs(), so it cannot mean "clear".
registry.CLEAR = setmetatable({}, { __tostring = function() return "registry.CLEAR" end })

-- opts: persist_get(name), persist_set(name, value) required; now() defaults
-- to os.time; log to common.log.
function registry.new(opts)
	opts = opts or {}
	assert(type(opts.persist_get) == "function", "registry.new: persist_get is required")
	assert(type(opts.persist_set) == "function", "registry.new: persist_set is required")
	return setmetatable({
		persist_get = opts.persist_get,
		persist_set = opts.persist_set,
		now = opts.now or os.time,
		log = opts.log or default_log,
		lights = {},
		rooms = {},
		tombs = {},
	}, registry)
end

-- Helpers ------------------------------------------------------------------

local function positive(value)
	local n = tonumber(value)
	if n and n > 0 then
		return n
	end
	return nil
end

local function shallow_copy(t)
	local out = {}
	if type(t) == "table" then
		for k, v in pairs(t) do
			out[k] = v
		end
	end
	return out
end

-- Empty a table in place (assigning nil to existing keys during pairs() is
-- allowed in Lua 5.1).
local function clear(t)
	for k in pairs(t) do
		t[k] = nil
	end
end

local function valid_rid(rid)
	return type(rid) == "string" and rid ~= ""
end

-- Membership in a { [device_id] = true } set. The sets come from C4 calls
-- whose ids may arrive as strings, so both spellings count.
local function in_set(set, id)
	if type(set) ~= "table" or id == nil then
		return false
	end
	if set[id] then
		return true
	end
	return set[tostring(id)] and true or false
end

local function label(rid, entry)
	return string.format("%s (device %s, %s)", tostring(entry and entry.name), tostring(entry and entry.device_id),
		tostring(rid))
end

-- Name order, case-insensitive; ties on the exact name, then the rid, so the
-- order is stable for lists the owner reads.
local function by_name(a, b)
	if a.key ~= b.key then
		return a.key < b.key
	end
	if a.name ~= b.name then
		return a.name < b.name
	end
	return a.rid < b.rid
end

-- Load / save ----------------------------------------------------------------

-- A persisted value as a table, or an empty one (missing, or something an
-- older build or a bug wrote).
function registry:read(key)
	local value = self.persist_get(key)
	if value == nil then
		return {}
	end
	if type(value) ~= "table" then
		self.log.warn("registry: %s is a %s, not a table; starting empty", key, type(value))
		return {}
	end
	return value
end

-- One persisted entry, normalised: numeric ids and timestamps, a valid state
-- (v1 entries have none and become "linked"), timestamps only for the state
-- they belong to. nil for an entry without a usable device id: it represents
-- nothing the driver could address, and lights.lua has always dropped those.
function registry:normalise_entry(rid, raw)
	if type(raw) ~= "table" then
		return nil
	end
	local entry = shallow_copy(raw)
	entry.device_id = positive(raw.device_id)
	if not entry.device_id then
		return nil
	end
	entry.proxy_id = positive(raw.proxy_id)
	if raw.name ~= nil then
		entry.name = tostring(raw.name)
	end
	if raw.state == nil then
		self.log.debug("registry: upgraded v1 entry %s", label(rid, entry))
		entry.state = "linked"
	elseif not registry.STATES[raw.state] then
		self.log.warn("registry: %s had state %s; treating it as linked", label(rid, entry), tostring(raw.state))
		entry.state = "linked"
	end
	for _, field in ipairs({ "gone_since", "unbound_since", "created_at", "created_room_id" }) do
		entry[field] = tonumber(raw[field])
	end
	for state, field in pairs(STAMP) do
		if entry.state ~= state then
			entry[field] = nil
		end
	end
	return entry
end

local function normalise_mapping(raw)
	local m = shallow_copy(raw)
	m.c4_room_id = tonumber(m.c4_room_id)
	m.type = m.type == "zone" and "zone" or "room"
	return m
end

-- Read the three keys into the (same) three tables. Returns counts().
function registry:load()
	clear(self.lights)
	clear(self.rooms)
	clear(self.tombs)

	for rid, raw in pairs(self:read(registry.LIGHTS_KEY)) do
		local entry = valid_rid(rid) and self:normalise_entry(rid, raw) or nil
		if entry then
			self.lights[rid] = entry
		else
			self.log.warn("registry: dropped a malformed %s entry for %s", registry.LIGHTS_KEY, tostring(rid))
		end
	end
	for group_rid, raw in pairs(self:read(registry.ROOMS_KEY)) do
		if valid_rid(group_rid) and type(raw) == "table" then
			self.rooms[group_rid] = normalise_mapping(raw)
		end
	end
	for rid, raw in pairs(self:read(registry.TOMBSTONES_KEY)) do
		if valid_rid(rid) and type(raw) == "table" then
			local tomb = shallow_copy(raw)
			tomb.deleted_at = tonumber(raw.deleted_at)
			self.tombs[rid] = tomb
		end
	end

	local counts = self:counts()
	self.log.debug("registry: loaded %d linked, %d gone, %d unbound, %d tombstones, %d room mappings",
		counts.linked, counts.gone, counts.unbound, counts.tombstones, counts.rooms)
	return counts
end

-- Write the three keys. The live tables go out as they are; the persistence
-- layer serialises them [verified on hardware: lights.lua stores its registry
-- table the same way].
function registry:save()
	self.persist_set(registry.LIGHTS_KEY, self.lights)
	self.persist_set(registry.ROOMS_KEY, self.rooms)
	self.persist_set(registry.TOMBSTONES_KEY, self.tombs)
end

-- Lookup ---------------------------------------------------------------------

-- The live entry (change it through update()/set_state(), not in place).
function registry:get(rid)
	if rid == nil then
		return nil
	end
	return self.lights[rid]
end

function registry:by_device(device_id)
	device_id = tonumber(device_id)
	if not device_id then
		return nil
	end
	for rid, entry in pairs(self.lights) do
		if entry.device_id == device_id then
			return rid, entry
		end
	end
	return nil
end

-- rid → entry; read-only use. The table identity survives load().
function registry:entries()
	return self.lights
end

-- Rids in name order (case-insensitive; ties and missing names by rid), all
-- states or one.
function registry:rids(state)
	local list = {}
	for rid, entry in pairs(self.lights) do
		if state == nil or entry.state == state then
			local name = entry.name ~= nil and tostring(entry.name) or ""
			list[#list + 1] = { rid = rid, name = name, key = name:lower() }
		end
	end
	table.sort(list, by_name)
	for i, item in ipairs(list) do
		list[i] = item.rid
	end
	return list
end

-- { linked, gone, unbound, tombstones } plus rooms (the mapping count, handy
-- for the Room Mappings property).
function registry:counts()
	local c = { linked = 0, gone = 0, unbound = 0, tombstones = 0, rooms = 0 }
	for _, entry in pairs(self.lights) do
		c[entry.state] = (c[entry.state] or 0) + 1
	end
	for _ in pairs(self.tombs) do
		c.tombstones = c.tombstones + 1
	end
	for _ in pairs(self.rooms) do
		c.rooms = c.rooms + 1
	end
	return c
end

-- Entries --------------------------------------------------------------------

-- A new "linked" entry from fields (any keys; device_id required). Clears a
-- tombstone for the rid: a deliberate add re-creates what was deleted (§3).
-- nil, "exists" when the rid has an entry; nil, "bad rid" / "no device_id" /
-- "device exists" for the invariants in the header.
function registry:add(rid, fields)
	if not valid_rid(rid) then
		return nil, "bad rid"
	end
	if self.lights[rid] then
		return nil, "exists"
	end
	fields = fields or {}
	local device_id = positive(fields.device_id)
	if not device_id then
		return nil, "no device_id"
	end
	local holder = self:by_device(device_id)
	if holder then
		return nil, "device exists"
	end

	local entry = shallow_copy(fields)
	entry.device_id = device_id
	entry.proxy_id = positive(fields.proxy_id)
	entry.state = "linked"
	entry.gone_since, entry.unbound_since = nil, nil
	entry.created_at = tonumber(fields.created_at) or self.now()
	self.lights[rid] = entry

	if self:clear_tombstone(rid) then
		self.log.info("registry: %s re-created; tombstone cleared", label(rid, entry))
	end
	return entry
end

-- Shallow merge of fields into the entry; nil for an unknown rid. `state`
-- goes through set_state() so the timestamps stay right; registry.CLEAR as a
-- value removes the field; ids are coerced to positive numbers (an invalid
-- device_id leaves the old one).
function registry:update(rid, fields)
	local entry = self:get(rid)
	if not entry then
		return nil
	end
	for k, v in pairs(fields or {}) do
		if k == "state" then
			self:set_state(rid, v)
		elseif v == registry.CLEAR then
			entry[k] = nil
		elseif k == "device_id" then
			entry.device_id = positive(v) or entry.device_id
		elseif k == "proxy_id" then
			entry.proxy_id = positive(v)
		else
			entry[k] = v
		end
	end
	return entry
end

-- Move to state, stamping gone_since / unbound_since on entry and clearing
-- the stamp of the state left. False when nothing changed, for an unknown
-- rid, or for a state that is not one of registry.STATES.
function registry:set_state(rid, state)
	local entry = self:get(rid)
	if not entry then
		return false
	end
	if not registry.STATES[state] then
		self.log.warn("registry: unknown state %s for %s", tostring(state), label(rid, entry))
		return false
	end
	local old = entry.state
	if old == state then
		return false
	end
	if STAMP[old] then
		entry[STAMP[old]] = nil
	end
	if STAMP[state] then
		entry[STAMP[state]] = self.now()
	end
	entry.state = state
	self.log.info("registry: %s: %s -> %s", label(rid, entry), tostring(old), state)
	return true
end

-- Re-point the entry at new_rid: the same table (device, proxy, programming
-- untouched) under the new key, state "linked". `fields` (optional) is merged
-- as update() would, for the new light's name, caps, model and so on.
-- nil, "unknown" / "bad rid" / "exists" (new_rid already has an entry, which
-- includes new_rid == old_rid). Clears a tombstone for new_rid.
function registry:relink(old_rid, new_rid, fields)
	local entry = self:get(old_rid)
	if not entry then
		return nil, "unknown"
	end
	if not valid_rid(new_rid) then
		return nil, "bad rid"
	end
	if self.lights[new_rid] then
		return nil, "exists"
	end
	self.lights[old_rid] = nil
	self.lights[new_rid] = entry
	if STAMP[entry.state] then
		entry[STAMP[entry.state]] = nil
	end
	entry.state = "linked"
	if fields then
		self:update(new_rid, fields)
	end
	self:clear_tombstone(new_rid)
	self.log.info("registry: %s re-linked from %s", label(new_rid, entry), tostring(old_rid))
	return entry
end

-- Remove the entry and return it; the rid is free for Add Light again.
function registry:forget(rid)
	local entry = self:get(rid)
	if not entry then
		return nil
	end
	self.lights[rid] = nil
	self.log.info("registry: forgot %s", label(rid, entry))
	return entry
end

-- Remove the entry and remember that its device was deleted in Composer.
function registry:tombstone(rid)
	local entry = self:get(rid)
	if not entry then
		return nil
	end
	self.lights[rid] = nil
	local tomb = { name = entry.name, device_name = entry.device_name, deleted_at = self.now() }
	self.tombs[rid] = tomb
	self.log.info("registry: tombstoned %s", label(rid, entry))
	return tomb
end

-- rid → { name, device_name, deleted_at }; read-only use.
function registry:tombstones()
	return self.tombs
end

-- True when there was one.
function registry:clear_tombstone(rid)
	if rid == nil or self.tombs[rid] == nil then
		return false
	end
	self.tombs[rid] = nil
	return true
end

-- Reconciliation ---------------------------------------------------------------

-- Project-side reconcile (§5 step 1) against two device-id sets: `bound`,
-- the devices bound to the bridge now, and `present`, the hue_light devices
-- in the project, nil when unknown. Per entry, by device id only:
--   bound                                → "unbound" entries become "linked" (relinked)
--   not bound, present known, not in it  → tombstoned, whatever the state
--   not bound otherwise                  → "linked" entries become "unbound"
-- "gone" entries keep their state (gone is about the Hue side); "unbound"
-- ones stay until bound again. An empty `present` is treated as unknown: an
-- empty or failed GetDevices must never read as "everything was deleted"
-- (§5), and a wrong tombstone costs the owner far more than a missed one.
-- Returns { unbound, relinked, tombstoned } as rid arrays in name order.
function registry:reconcile(sets)
	sets = sets or {}
	local bound = sets.bound or {}
	local present = sets.present
	if type(present) ~= "table" or next(present) == nil then
		if present ~= nil then
			self.log.debug("registry: reconcile: empty present set treated as unknown")
		end
		present = nil
	end
	local out = { unbound = {}, relinked = {}, tombstoned = {} }
	for _, rid in ipairs(self:rids()) do
		local entry = self.lights[rid]
		if in_set(bound, entry.device_id) then
			if entry.state == "unbound" and self:set_state(rid, "linked") then
				out.relinked[#out.relinked + 1] = rid
			end
		elseif present and not in_set(present, entry.device_id) then
			self:tombstone(rid)
			out.tombstoned[#out.tombstoned + 1] = rid
		elseif entry.state == "linked" and self:set_state(rid, "unbound") then
			out.unbound[#out.unbound + 1] = rid
		end
	end
	return out
end

-- Room mappings ------------------------------------------------------------------

function registry:room_mapping(group_rid)
	if group_rid == nil then
		return nil
	end
	return self.rooms[group_rid]
end

-- Store { c4_room_id, c4_room_name, hue_name, type } for a Hue room/zone rid;
-- c4_room_id becomes a number, type is "zone" or (default) "room". Returns
-- the stored copy, or nil, "bad rid".
function registry:set_room_mapping(group_rid, mapping)
	if not valid_rid(group_rid) then
		return nil, "bad rid"
	end
	local m = normalise_mapping(mapping)
	self.rooms[group_rid] = m
	return m
end

-- Returns the removed mapping, or nil.
function registry:remove_room_mapping(group_rid)
	if group_rid == nil then
		return nil
	end
	local m = self.rooms[group_rid]
	self.rooms[group_rid] = nil
	return m
end

-- group_rid → mapping; read-only use. The table identity survives load().
function registry:room_mappings()
	return self.rooms
end

return registry
