-- The Hue Sync Box devices bound on the bridge's "Hue Sync Boxes" connection
-- (id 2, class HUE_SYNCBOX), and what the bridge tells them (2.0 beta stage
-- 2, #534): docs/hdmi-sync-stage2-design.md §6, contracts C5 and C6 of
-- docs/hdmi-sync-contracts.md, research docs/syncbox-architecture-research.md
-- §1.5, §3.1 and §4.2. The box's side is src/hue_syncbox/syncbox/link.lua.
--
--   box → bridge   HUE_SYNCBOX_HELLO     { device_id, box_id, bridge_id, area_id }
--                  HUE_SYNCBOX_GOODBYE   { device_id, box_id }
--   bridge → box   HUE_SYNCBOX_CONFIGURE { bridge_id, match, areas }   the answer to a
--                                          hello, and to every box after each resync
--                  HUE_SYNCBOX_AREA      { id, status, streamer }      a stream starts or
--                                          stops on any area
--
-- Every parameter is a string (contracts C5). `areas` is a JSON list, written
-- here as a real array (C4:JsonEncode writes Lua arrays as objects with string
-- keys [verified: docs/design.md, "C4:url transfer scheduling on OS 3.4.2"]),
-- of { id, name, type, status, lamps, rooms }: `type` the area's
-- configuration type, `lamps` the number of its lamps, `rooms` the Control4
-- rooms its lamps are mapped to (design §6.1: derived, shown, never stored).
--
-- The trust rules (#483; SECURITY.md "Trust boundaries"; research §3.1):
-- Control4 tells a driver nothing about who sent a message, so a box names
-- its own device id, and the bridge answers only a device Director reports
-- bound on connection 2: the device's OnBindingChanged (Director's own
-- word, [verified: API 9/_12]) or the bound devices' lookup
-- (C4:GetBoundConsumerDevices [verified: API 32/_3]). A hello from any other
-- device waits, unanswered, until one of them shows it bound. Every value is
-- checked; a malformed message is dropped with one debug line. What a box is
-- told is only what it could read from its own box anyway (area names, lamp
-- counts, status), never the bridge's key. A box's hello only names the box
-- that streams to an area in the lamps' Status, which a forged one could
-- make wrong until the next hello of the real box: it never writes to Hue.
--
-- Interface (contract §6):
--   s = syncboxes.new(deps)
--   s:hello(params)            HUE_SYNCBOX_HELLO: record the box and answer CONFIGURE;
--                              true when answered
--   s:goodbye(params)          HUE_SYNCBOX_GOODBYE: forget the box; true when forgotten
--   s:binding_changed(binding, class, bound, other_id)
--                              OnBindingChanged; true when it was connection 2 (the
--                              caller then has nothing else to do with it)
--   s:configure_all()          after each resync: CONFIGURE to every bound box (and a
--                              waiting hello answered once its device shows bound);
--                              returns the number told
--   s:on_stream(area, started) an area started or stopped streaming (the entertainment
--                              module's on_stream): AREA to every bound box; returns
--                              the number told
--   s:label_for(area_id)       the Composer name of the one bound box whose area is that
--                              area (and whose bridge is this one), else nil
--   s:boxes(), s:count(), s:areas_json()   for the specs and Diagnostics
--
-- deps (send required; the rest optional):
--   send(device_id, command, params)   one message to a device (the driver's device_send)
--   bridge_id()                this bridge's id, or nil while unpaired
--   areas()                    the entertainment areas (bridge/entertainment.lua areas():
--                              { id, name, kind, status, lamps = { rid... }, streaming })
--   lights                     the bridge.lights instance, or a function returning it, for
--                              the rooms: its models, hue_room_of, room_mapping, project
--   rooms_for(lamps)           instead of `lights`: the Control4 room names of these lamps
--   bound()                    the devices bound on connection 2, as
--                              C4:GetBoundConsumerDevices answers ({ [id] = name }, or nil)
--   display_name(device_id)    the box device's Composer name
--   on_labels_changed(rids)    who streams to these lamps changed (a box said hello, left
--                              or moved to another area while the area streams): their
--                              devices' stream label and the Entertainment Areas row
--   log                        common.log look-alike
--
-- No timer, no transfer: every call sends SendToDevice messages only, which
-- is safe inside a C4:url callback (driver.lua's on_container), so on_stream
-- runs straight from the event stream.

local hue_model = require("bridge.hue_model")
local util = require("bridge.util")
local num = require("common.num")
local log = require("common.log")

local syncboxes = {}
syncboxes.__index = syncboxes

-- The bridge's provider connection (contracts C6; design §4.2).
syncboxes.BINDING = 2
syncboxes.CLASS = "HUE_SYNCBOX"

syncboxes.HELLO = "HUE_SYNCBOX_HELLO"
syncboxes.GOODBYE = "HUE_SYNCBOX_GOODBYE"
syncboxes.CONFIGURE = "HUE_SYNCBOX_CONFIGURE"
syncboxes.AREA = "HUE_SYNCBOX_AREA"

-- Bounds: boxes kept (a house has a few; a hello beyond is refused with a
-- warning), hellos waiting for their binding, areas and rooms per area told
-- (research §3.2), the box id's length, a Control4 device id's range.
syncboxes.MAX_BOXES = 16
syncboxes.MAX_PENDING = 8
syncboxes.MAX_AREAS = 64
syncboxes.MAX_ROOMS = 32
syncboxes.BOX_ID_LEN = 12
syncboxes.ID_MAX = 64
syncboxes.DEVICE_ID_MAX = 2147483647

-- A box whose Composer name cannot be read (the proxy's default name, C1.1).
syncboxes.FALLBACK_NAME = "Hue Sync Box"

-- Checks ------------------------------------------------------------------------------

-- A Control4 device id: a whole number within 1..DEVICE_ID_MAX, else nil.
function syncboxes.device_id(v)
	local n = num.within(v, 1, syncboxes.DEVICE_ID_MAX)
	if n == nil or n ~= math.floor(n) then
		return nil
	end
	return n
end

-- The box id upper-cased when `v` is 12 hex digits (research §3.2), else nil.
function syncboxes.box_id(v)
	if type(v) == "string" and #v == syncboxes.BOX_ID_LEN and v:find("^%x+$") then
		return v:upper()
	end
	return nil
end

-- A Hue bridge id lower-cased when `v` is hex digits only (the box's
-- hue.bridgeUniqueId and the bridge's id compare in lower case,
-- docs/syncbox-api-research.md §6 item 10), at most ID_MAX, else nil.
function syncboxes.bridge_id(v)
	if type(v) == "string" and #v <= syncboxes.ID_MAX and v:find("^%x+$") then
		return v:lower()
	end
	return nil
end

-- An entertainment area id lower-cased when `v` is hex digits and "-" only (a
-- CLIP v2 entertainment_configuration id is a UUID, and the box's hueTarget
-- names one with a CLIP v2 bridge, docs/syncbox-api-research.md §2.6), at
-- most ID_MAX, else nil.
function syncboxes.area_id(v)
	if type(v) == "string" and #v <= syncboxes.ID_MAX and v:find("^[%x%-]+$") then
		return v:lower()
	end
	return nil
end

-- JSON ---------------------------------------------------------------------------------

-- A JSON string: `"` and `\` escaped, every control character as \u00XX;
-- UTF-8 passes as it is.
local function json_string(s)
	local escaped = s:gsub('[%c"\\]', function(c)
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		end
		return string.format("\\u%04x", c:byte())
	end)
	return '"' .. escaped .. '"'
end

local function json_list(items)
	return "[" .. table.concat(items, ",") .. "]"
end

-- One area of CONFIGURE's list, its fields in a fixed order.
local function json_area(area)
	local rooms = {}
	for i, room in ipairs(area.rooms) do
		rooms[i] = json_string(room)
	end
	return string.format('{"id":%s,"name":%s,"type":%s,"status":%s,"lamps":%d,"rooms":%s}',
		json_string(area.id), json_string(area.name), json_string(area.type), json_string(area.status),
		area.lamps, json_list(rooms))
end

-- The module ---------------------------------------------------------------------------

function syncboxes.new(deps)
	deps = deps or {}
	assert(type(deps.send) == "function", "syncboxes.new: deps.send is required")
	return setmetatable({
		deps = deps,
		log = deps.log or log,
		by_device = {},   -- device id -> { device_id, box_id, bridge_id, area_id, name }
		pending = {},     -- device id -> a checked hello waiting for its binding
		bound_ids = {},   -- device id -> true (bound) / false (unbound), as OnBindingChanged said
		owners = {},      -- area id -> device id (or false: several), the labels last seen
	}, syncboxes)
end

-- deps[name](...) under pcall: the value, or nil after a warning.
function syncboxes:call(name, ...)
	local fn = self.deps[name]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, value = pcall(fn, ...)
	if not ok then
		self.log.warn("syncboxes: %s failed: %s", name, util.echo(value, util.LOG_MAX))
		return nil
	end
	return value
end

local function sorted_ids(map)
	local out = {}
	for id in pairs(map) do
		out[#out + 1] = id
	end
	table.sort(out)
	return out
end

-- How a box reads in log lines: "#3ABC (device 1234)", the last 4 digits of its id.
local function tag(box)
	return string.format("%s (device %d)", box.box_id and ("#" .. box.box_id:sub(-4)) or "unpaired box",
		box.device_id)
end

-- This bridge's id, lower-cased, or nil.
function syncboxes:own_bridge_id()
	return syncboxes.bridge_id(self:call("bridge_id"))
end

-- True when the box's own bridge is this one.
function syncboxes:matches(box, own)
	own = own or self:own_bridge_id()
	return own ~= nil and box.bridge_id == own
end

-- The devices bound on connection 2 as a set, or nil when unknown (the
-- lookup answered nil, which OS 3.4.2 does with nothing bound [verified:
-- bridge/project.lua], or raised).
function syncboxes:bound_set()
	local raw = self:call("bound")
	if type(raw) ~= "table" then
		return nil
	end
	local out = {}
	for id in pairs(raw) do
		local n = syncboxes.device_id(id)
		if n then
			out[n] = true
		end
	end
	return out
end

-- true, false, or nil (unknown): OnBindingChanged's word first, then the lookup.
function syncboxes:is_bound(device_id, set)
	local flag = self.bound_ids[device_id]
	if flag ~= nil then
		return flag
	end
	set = set or self:bound_set()
	if set == nil then
		return nil
	end
	return set[device_id] == true
end

-- The Composer name of a box device: deps.display_name (the driver reads its
-- proxy's name), else the name kept at its hello, else FALLBACK_NAME;
-- through util.display_name.
function syncboxes:name_of(box)
	local name = util.display_name(self:call("display_name", box.device_id))
	if name ~= "" then
		box.name = name
		return name
	end
	return box.name or syncboxes.FALLBACK_NAME
end

-- Rooms -------------------------------------------------------------------------------

function syncboxes:lights_module()
	local lights = self.deps.lights
	if type(lights) == "function" then
		local ok, value = pcall(lights)
		lights = ok and value or nil
	end
	return type(lights) == "table" and lights or nil
end

-- The Control4 room of one lamp through its Hue room's mapping (the lights'
-- registry): the room's current name from `c4_rooms`; the mapping's kept name
-- while the project's rooms are unknown; nil when the lamp is in no mapped
-- room or its Control4 room is gone.
local function room_of_lamp(lights, rid, c4_rooms)
	local model = type(lights.models) == "table" and lights.models[rid] or nil
	if type(model) ~= "table" then
		return nil
	end
	local group = lights:hue_room_of(model)
	local mapping = group and lights:room_mapping(group) or nil
	local room_id = type(mapping) == "table" and mapping.c4_room_id or nil
	if room_id == nil then
		return nil
	end
	if next(c4_rooms) == nil then
		return mapping.c4_room_name
	end
	return c4_rooms[room_id]
end

-- The Control4 rooms of `lamps`, by name, each once, at most MAX_ROOMS.
function syncboxes:rooms_of(lamps)
	local raw
	if type(self.deps.rooms_for) == "function" then
		raw = self:call("rooms_for", lamps)
	else
		local lights = self:lights_module()
		if lights then
			local ok, value = pcall(function()
				local c4_rooms = type(lights.project) == "table" and lights.project:rooms() or {}
				local out = {}
				for _, rid in ipairs(lamps) do
					out[#out + 1] = room_of_lamp(lights, rid, c4_rooms)
				end
				return out
			end)
			if ok then
				raw = value
			else
				self.log.warn("syncboxes: the rooms of an area: %s", util.echo(value, util.LOG_MAX))
			end
		end
	end
	local seen, out = {}, {}
	for _, room in pairs(type(raw) == "table" and raw or {}) do
		local name = util.display_name(room)
		if name ~= "" and not seen[name] then
			seen[name] = true
			out[#out + 1] = name
		end
	end
	table.sort(out, function(a, b)
		local ka, kb = util.norm(a), util.norm(b)
		if ka ~= kb then
			return ka < kb
		end
		return a < b
	end)
	while #out > syncboxes.MAX_ROOMS do
		out[#out] = nil
	end
	return out
end

-- The areas ------------------------------------------------------------------------------

-- The entertainment areas, as the bridge has them (sorted by name), each
-- checked: its id a resource id, a name.
function syncboxes:area_list()
	local raw = self:call("areas")
	local out = {}
	for _, area in ipairs(type(raw) == "table" and raw or {}) do
		if type(area) == "table" and hue_model.resource_id(area.id) and type(area.name) == "string" then
			out[#out + 1] = area
		end
	end
	return out
end

-- CONFIGURE's `areas`: the JSON list of { id, name, type, status, lamps, rooms }.
function syncboxes:areas_json()
	local items = {}
	for _, area in ipairs(self:area_list()) do
		if #items >= syncboxes.MAX_AREAS then
			break
		end
		local lamps = type(area.lamps) == "table" and area.lamps or {}
		items[#items + 1] = json_area({
			id = area.id,
			name = util.display_name(area.name),
			type = type(area.kind) == "string" and area.kind or "other",
			status = area.status == "active" and "active" or "inactive",
			lamps = #lamps,
			rooms = self:rooms_of(lamps),
		})
	end
	return json_list(items)
end

-- Labels -----------------------------------------------------------------------------------

-- Area id -> the device id of the one box of this bridge whose area it is,
-- or false when several boxes name it.
function syncboxes:label_owners()
	local own, out = self:own_bridge_id(), {}
	for _, id in ipairs(sorted_ids(self.by_device)) do
		local box = self.by_device[id]
		if box.area_id and self:matches(box, own) then
			out[box.area_id] = out[box.area_id] == nil and id or false
		end
	end
	return out
end

function syncboxes:label_for(area_id)
	local id = syncboxes.area_id(area_id)
	local owner = id and self:label_owners()[id]
	if not owner then
		return nil
	end
	return self:name_of(self.by_device[owner])
end

-- After any change: the areas whose box changed and that stream now hand
-- their lamps to on_labels_changed once (sorted, each once).
function syncboxes:check_labels()
	local before, after = self.owners, self:label_owners()
	self.owners = after
	local changed = {}
	for id, owner in pairs(before) do
		if after[id] ~= owner then
			changed[id] = true
		end
	end
	for id, owner in pairs(after) do
		if before[id] ~= owner then
			changed[id] = true
		end
	end
	if next(changed) == nil or type(self.deps.on_labels_changed) ~= "function" then
		return
	end
	local seen, rids = {}, {}
	for _, area in ipairs(self:area_list()) do
		if changed[area.id] and area.status == "active" then
			for _, rid in ipairs(type(area.lamps) == "table" and area.lamps or {}) do
				if not seen[rid] then
					seen[rid] = true
					rids[#rids + 1] = rid
				end
			end
		end
	end
	if #rids > 0 then
		table.sort(rids)
		self:call("on_labels_changed", rids)
	end
end

-- Messages to the boxes -----------------------------------------------------------------------

function syncboxes:send(device_id, command, params)
	local ok, err = pcall(self.deps.send, device_id, command, params)
	if not ok then
		self.log.warn("syncboxes: %s to device %d failed: %s", command, device_id, util.echo(err, util.LOG_MAX))
	end
	return ok
end

-- CONFIGURE to one box; `areas` is the list's JSON when the caller built it already.
function syncboxes:configure(box, areas)
	local own = self:own_bridge_id()
	return self:send(box.device_id, syncboxes.CONFIGURE, {
		bridge_id = own,
		match = self:matches(box, own) and "true" or "false",
		areas = areas or self:areas_json(),
	})
end

-- Hello and goodbye ------------------------------------------------------------------------------

-- nil and one debug line naming why a box's message was dropped.
function syncboxes:drop(command, params, why)
	self.log.debug("syncboxes: %s from device %s dropped: %s", command, util.echo(params.device_id, 40), why)
	return nil
end

-- A hello's values, checked: { device_id, box_id, bridge_id, area_id }, or
-- nil (malformed). An id left out is nil; an id given that is not one makes
-- the hello malformed.
function syncboxes:checked_hello(params)
	local device_id = syncboxes.device_id(params.device_id)
	if not device_id then
		return self:drop(syncboxes.HELLO, params, "no device id")
	end
	local out = { device_id = device_id }
	for _, field in ipairs({ { "box_id", syncboxes.box_id }, { "bridge_id", syncboxes.bridge_id },
		{ "area_id", syncboxes.area_id } }) do
		local name, check = field[1], field[2]
		local value = params[name]
		if value ~= nil and value ~= "" then
			out[name] = check(value)
			if out[name] == nil then
				return self:drop(syncboxes.HELLO, params, "its " .. name .. " is not one")
			end
		end
	end
	return out
end

function syncboxes:count()
	return #sorted_ids(self.by_device)
end

-- Record a checked hello of a bound device and answer it (unless `later`:
-- configure_all answers every box in one go).
function syncboxes:accept(hello, later)
	local id = hello.device_id
	self.pending[id] = nil
	if not self.by_device[id] and self:count() >= syncboxes.MAX_BOXES then
		self.log.warn("syncboxes: device %d said hello, but %d sync boxes are bound already; not answered", id,
			syncboxes.MAX_BOXES)
		return false
	end
	local old = self.by_device[id]
	local box = { device_id = id, box_id = hello.box_id, bridge_id = hello.bridge_id, area_id = hello.area_id,
		name = old and old.name or nil }
	self.by_device[id] = box
	local name = self:name_of(box)
	self.log.debug("syncboxes: hello from %s %s: bridge %s%s, area %s", util.echo(name, 80), tag(box),
		tostring(box.bridge_id or "none"), self:matches(box) and " (this one)" or "", tostring(box.area_id or "none"))
	if not old then
		self.log.info("syncboxes: %s %s is linked", util.echo(name, 80), tag(box))
	end
	if not later then
		self:configure(box)
		self:check_labels()
	end
	return true
end

function syncboxes:hello(params)
	params = type(params) == "table" and params or {}
	local hello = self:checked_hello(params)
	if not hello then
		return false
	end
	local id = hello.device_id
	if self:is_bound(id) == true then
		return self:accept(hello)
	end
	if self.pending[id] or #sorted_ids(self.pending) < syncboxes.MAX_PENDING then
		self.pending[id] = hello
	end
	self.log.debug("syncboxes: %s from device %d not answered: not bound on Hue Sync Boxes (yet)", syncboxes.HELLO, id)
	return false
end

-- Forget a box; `why` for the log line.
function syncboxes:forget(device_id, why)
	local box = self.by_device[device_id]
	self.pending[device_id] = nil
	if not box then
		return false
	end
	self.by_device[device_id] = nil
	self.log.info("syncboxes: %s forgotten (%s)", tag(box), why)
	self:check_labels()
	return true
end

function syncboxes:goodbye(params)
	params = type(params) == "table" and params or {}
	local id = syncboxes.device_id(params.device_id)
	if not id then
		return self:drop(syncboxes.GOODBYE, params, "no device id") or false
	end
	local box = self.by_device[id]
	if not box then
		self.pending[id] = nil
		self.log.debug("syncboxes: %s from device %d: no such box", syncboxes.GOODBYE, id)
		return false
	end
	local said = params.box_id
	if said ~= nil and said ~= "" and syncboxes.box_id(said) ~= box.box_id then
		return self:drop(syncboxes.GOODBYE, params, "it names another box than the device's hello") or false
	end
	return self:forget(id, "goodbye")
end

-- Bindings ---------------------------------------------------------------------------------------

function syncboxes:binding_changed(binding, class, bound, other_id)
	if tonumber(binding) ~= syncboxes.BINDING then
		return false
	end
	if class ~= nil and class ~= syncboxes.CLASS then
		return false
	end
	local id = syncboxes.device_id(other_id)
	if not id then
		return true
	end
	if bound == true or bound == "true" then
		self.bound_ids[id] = true
		self.log.debug("syncboxes: device %d bound on Hue Sync Boxes", id)
		local hello = self.pending[id]
		if hello then
			self:accept(hello)
		end
	elseif bound == false or bound == "false" then
		self.bound_ids[id] = false
		self:forget(id, "unbound")
	end
	return true
end

-- After a resync ----------------------------------------------------------------------------------

function syncboxes:configure_all()
	local set = self:bound_set()
	for _, id in ipairs(sorted_ids(self.pending)) do
		local is = self:is_bound(id, set)
		if is == true then
			self:accept(self.pending[id], true)
		elseif is == false then
			self.pending[id] = nil  -- Director says it is not bound: a forged or stale hello
		end
	end
	if set then
		for _, id in ipairs(sorted_ids(self.by_device)) do
			if not set[id] and self.bound_ids[id] ~= true then
				self:forget(id, "no longer bound")
			end
		end
	end
	local ids = sorted_ids(self.by_device)
	local areas = #ids > 0 and self:areas_json() or nil
	local told = 0
	for _, id in ipairs(ids) do
		if self:configure(self.by_device[id], areas) then
			told = told + 1
		end
	end
	self:check_labels()
	return told
end

-- Streams ----------------------------------------------------------------------------------------

function syncboxes:on_stream(area, started)
	local area_id = type(area) == "table" and hue_model.resource_id(area.id) or nil
	if not area_id then
		return 0
	end
	local mine = area_id:lower()
	local told = 0
	for _, id in ipairs(sorted_ids(self.by_device)) do
		local box = self.by_device[id]
		local streamer = "none"
		if started then
			streamer = box.area_id == mine and "this_box" or "other"
		end
		if self:send(id, syncboxes.AREA, { id = area_id, status = started and "active" or "inactive",
			streamer = streamer }) then
			told = told + 1
		end
	end
	return told
end

-- For the specs and Diagnostics -------------------------------------------------------------------

-- The bound boxes, by device id, as copies.
function syncboxes:boxes()
	local out = {}
	for _, id in ipairs(sorted_ids(self.by_device)) do
		local box = self.by_device[id]
		out[#out + 1] = { device_id = id, box_id = box.box_id, bridge_id = box.bridge_id, area_id = box.area_id,
			name = box.name }
	end
	return out
end

return syncboxes
