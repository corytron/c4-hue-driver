-- The bridge's cache of Hue rooms, zones and the bridge_home, with the
-- membership indexes the import UI needs: which room a device is in, which
-- zones a light is in, which devices are in no room, and display labels
-- (docs/import-design.md §5 step 3 and §13). Pure Lua, no C4 calls; the
-- parsing lives in bridge.hue_model (group / update_group).
--
-- Membership facts [verified: Core Concepts, and hardware 2026-10-21 on the
-- house bridge: 16 rooms with device children only, no device in two rooms;
-- 7 zones with light children only; one bridge_home whose children are two
-- devices and the 16 rooms, with no metadata]: a room's children are
-- devices and a device is in at most one room; a zone's children are light
-- services and a light can be in any number of zones; bridge_home's children
-- are the devices in no room plus the rooms. Rooms are the authority for
-- device → room; bridge_home is only consulted for the room-less list and
-- never contradicts a room.
--
-- Indexes are rebuilt whole after every change (a handful of groups, tens of
-- children: microseconds) so lookups are plain table reads on the event path.

local hue_model = require("bridge.hue_model")

local groups = {}
groups.__index = groups

groups.TYPES = { "room", "zone", "bridge_home" }

function groups.new()
	local self = setmetatable({
		by_rid = {},            -- group rid → group (hue_model.group shape)
		sorted = {},            -- type → array of groups, sorted by name
		room_by_device = {},    -- device rid → room rid
		zones_by_light = {},    -- light rid → array of zone rids, sorted by zone name
		roomless = {},          -- device rids that are direct children of bridge_home and in no room
	}, groups)
	self:rebuild()
	return self
end

-- Case-insensitive by name, ties by rid, so pickers are stable between
-- resyncs and two rooms called "Office" keep one order.
local function compare(a, b)
	local an, bn = string.lower(a.name or ""), string.lower(b.name or "")
	if an ~= bn then
		return an < bn
	end
	return tostring(a.rid) < tostring(b.rid)
end

local function copy(list)
	local out = {}
	for i, value in ipairs(list or {}) do
		out[i] = value
	end
	return out
end

function groups:rebuild()
	local sorted = {}
	for _, gtype in ipairs(groups.TYPES) do
		sorted[gtype] = {}
	end
	for _, group in pairs(self.by_rid) do
		local list = sorted[group.type]
		if list then
			list[#list + 1] = group
		end
	end
	for _, list in pairs(sorted) do
		table.sort(list, compare)
	end

	-- First room in sort order wins should the bridge ever list a device in
	-- two rooms (it should not): deterministic, and visible in the audit.
	local room_by_device = {}
	for _, room in ipairs(sorted.room) do
		for _, rid in ipairs(room.children) do
			if room.child_rtypes[rid] == "device" and room_by_device[rid] == nil then
				room_by_device[rid] = room.rid
			end
		end
	end

	local zones_by_light = {}
	for _, zone in ipairs(sorted.zone) do
		local seen = {}
		for _, rid in ipairs(zone.children) do
			if zone.child_rtypes[rid] == "light" and not seen[rid] then
				seen[rid] = true
				local list = zones_by_light[rid] or {}
				list[#list + 1] = zone.rid
				zones_by_light[rid] = list
			end
		end
	end

	local roomless, seen = {}, {}
	for _, home in ipairs(sorted.bridge_home) do
		for _, rid in ipairs(home.children) do
			if home.child_rtypes[rid] == "device" and room_by_device[rid] == nil and not seen[rid] then
				seen[rid] = true
				roomless[#roomless + 1] = rid
			end
		end
	end
	table.sort(roomless)

	self.sorted = sorted
	self.room_by_device = room_by_device
	self.zones_by_light = zones_by_light
	self.roomless = roomless
end

-- Replace the cache from full GETs: `items` is an array of raw CLIP items
-- (one resource type or the whole /clip/v2/resource). Every cached group of
-- a type that appears in `items` is dropped first, so a type absent from
-- `items` keeps its cache; items of other types are ignored. Returns the
-- number of groups now cached per type, for the log.
function groups:absorb(items)
	local seen, parsed = {}, {}
	for _, item in ipairs(items or {}) do
		local group = hue_model.group(item)
		if group then
			seen[group.type] = true
			parsed[#parsed + 1] = group
		end
	end
	for rid, group in pairs(self.by_rid) do
		if seen[group.type] then
			self.by_rid[rid] = nil
		end
	end
	for _, group in ipairs(parsed) do
		self.by_rid[group.rid] = group
	end
	self:rebuild()
	return self:counts()
end

-- One event-stream item of kind "update" | "add" | "delete". True when the
-- cache changed. An update for an unknown rid is ignored (the resync after
-- the next reconnect brings the group); a delete item carries only id and
-- type [community: aiohue]; an add is a complete resource [assumed].
function groups:apply(item, kind)
	if type(item) ~= "table" or item.id == nil then
		return false
	end
	if kind == "add" then
		local group = hue_model.group(item)
		if not group then
			return false
		end
		self.by_rid[group.rid] = group
		self:rebuild()
		return true
	end

	local group = self.by_rid[item.id]
	if not group or (item.type ~= nil and item.type ~= group.type) then
		return false
	end
	if kind == "delete" then
		self.by_rid[item.id] = nil
		self:rebuild()
		return true
	elseif kind == "update" then
		local changed = hue_model.update_group(group, item)
		if #changed == 0 then
			return false
		end
		for _, name in ipairs(changed) do
			if name == "name" or name == "children" then
				self:rebuild()
				break
			end
		end
		return true
	end
	return false
end

-- The cached group for a rid (read-only use), or nil.
function groups:group(rid)
	if rid == nil then
		return nil
	end
	return self.by_rid[rid]
end

-- Groups of one type sorted by name; nil = rooms then zones (bridge_home
-- is never in a picker). A fresh array each call.
function groups:groups(gtype)
	if gtype ~= nil then
		return copy(self.sorted[gtype])
	end
	local out = copy(self.sorted.room)
	for _, zone in ipairs(self.sorted.zone) do
		out[#out + 1] = zone
	end
	return out
end

-- The room whose children hold the device, or nil (no room, or unknown).
function groups:room_of_device(device_rid)
	if device_rid == nil then
		return nil
	end
	return self.room_by_device[device_rid]
end

-- Zone rids holding the light, sorted by zone name; empty when none.
function groups:zones_of_light(light_rid)
	if light_rid == nil then
		return {}
	end
	return copy(self.zones_by_light[light_rid])
end

-- Device rids bridge_home lists directly (in no room), sorted by rid. The
-- house bridge lists two such devices [verified: hardware 2026-10-21; which
-- ones, e.g. the bridge itself, was not resolved]; callers filter by the
-- devices they care about.
function groups:roomless_devices()
	return copy(self.roomless)
end

-- Display label: "Kitchen" for a room, "Downstairs (zone)" for a zone,
-- "(all lights)" for the bridge_home, "(no room)" for nil or an unknown rid.
function groups:label(rid)
	local group = self:group(rid)
	if not group then
		return "(no room)"
	elseif group.type == "zone" then
		return tostring(group.name) .. " (zone)"
	elseif group.type == "bridge_home" then
		return "(all lights)"
	end
	return tostring(group.name)
end

-- { room = n, zone = n, bridge_home = n }
function groups:counts()
	local out = {}
	for _, gtype in ipairs(groups.TYPES) do
		out[gtype] = #self.sorted[gtype]
	end
	return out
end

return groups
