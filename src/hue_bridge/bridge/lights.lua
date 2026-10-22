-- The Hue lights a bridge represents as Control4 devices: the flows that keep
-- the registry (bridge.registry), the group cache (bridge.groups) and the light
-- drivers current, and the owner-facing actions, texts and pickers of
-- docs/import-design.md (§4 messages, §5 resync and reconciliation, §6
-- actions, §8 pickers, §13 this module's interface). docs/lights-design.md
-- stays the contract for the messages and the coalescer.
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

local log = require("common.log")
local hue_model = require("bridge.hue_model")
local registry = require("bridge.registry")
local groups = require("bridge.groups")

local lights = {}
lights.__index = lights

lights.REGISTRY_KEY = registry.LIGHTS_KEY
lights.AUTOMAP_KEY = "hue_rooms_automapped"  -- set once the one-time Map Rooms By Name has run [Q 5]
lights.LIGHT_DRIVER = "hue_light.c4z"
lights.BINDING = 1
lights.BINDING_CLASS = "HUE_BRIDGE"
lights.OFFLINE_NAG_S = 24 * 3600              -- Attention nags about lights offline this long [Q 8]
lights.MAX_NAMED = 3                          -- names listed per Attention item before "+n more"

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
function lights.new(ctx)
	ctx = ctx or {}
	assert(type(ctx.http) == "function", "lights.new: ctx.http is required")
	ctx.send = ctx.send or function(id, command, params)
		C4:SendToDevice(id, command, params)
	end
	ctx.add_device = ctx.add_device or function(driver, room_id, name, cb)
		C4:AddDevice(driver, room_id, name, cb)
	end
	ctx.bind = ctx.bind or function(bridge_id, light_id)
		C4:Bind(bridge_id, lights.BINDING, light_id, lights.BINDING, lights.BINDING_CLASS)
	end
	ctx.persist_get = ctx.persist_get or function(name)
		return C4:PersistGetValue(name)
	end
	ctx.persist_set = ctx.persist_set or function(name, value)
		C4:PersistSetValue(name, value)
	end
	ctx.log = ctx.log or log
	ctx.now = ctx.now or os.time
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
		return C4:GetBoundConsumerDevices(C4:GetDeviceID(), lights.BINDING)
	end
	project.unbind = project.unbind or function(device_id)
		C4:Unbind(device_id, lights.BINDING)
	end
	project.rename = project.rename or function(id, name)
		C4:RenameDevice(id, name)
	end
	project.display_name = project.display_name or function(id)
		return C4:GetDeviceDisplayName(id)
	end

	local reg = registry.new({
		persist_get = ctx.persist_get, persist_set = ctx.persist_set, now = ctx.now, log = ctx.log,
	})
	return setmetatable({
		ctx = ctx,
		reg = reg,
		registry = reg:entries(),  -- rid → entry, the live table (identity kept across load())
		groups = groups.new(),     -- rooms, zones, bridge_home from the last GET (memory only)
		models = {},               -- rid → normalised light, from the last GET (memory only)
		devices = {},              -- device rid → hue_model.devices() record (memory only)
		macs = {},                 -- device rid → zigbee mac_address (memory only)
		last_configure = {},       -- rid → signature of the last HUE_CONFIGURE sent, to send it again only on change
		offline_since = {},        -- rid → ctx.now() when the light was first seen offline (memory only)
		announced = {},            -- device_id → { rid, name, model } from HUE_HELLO, for Link Devices
		announced_new = {},        -- rid → true once a new light was logged
		conflicts = {},            -- rid → { holder = device_id, claimant = device_id } (two devices, one rid)
		early_hellos = {},         -- HUE_HELLOs received before load(), answered after configure_all()
		loaded = false,
		synced = false,            -- a full GET has succeeded (new/missing counts mean something)
		groups_loaded = false,     -- /room, /zone, /bridge_home fetched in this run (a missing group means deleted)
		dirty = false,
		configured_once = false,
		importing = false,
		resyncing = false,
		resync_pending = nil,      -- a done callback to run a second resync for
		device_info_logged = false,
	}, lights)
end

-- Helpers ------------------------------------------------------------------

function lights:bridge_id()
	return self.ctx.bridge_id or C4:GetDeviceID()
end

function lights:room_id()
	return self.ctx.room_id or C4:RoomGetId()
end

-- pcall wrapper for callback bodies; failures are logged, not raised.
function lights:protect(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		self.ctx.log.error("lights: %s failed: %s", what, tostring(err))
	end
	return ok, err
end

-- One-line recursive dump of a Lua value, keys sorted, for log.always.
function lights.dump(value, depth)
	depth = depth or 0
	if type(value) ~= "table" then
		if type(value) == "string" then
			-- Lua 5.1's %q writes a newline as backslash-newline; keep one line.
			return (string.format("%q", value):gsub("\\\n", "\\n"))
		end
		return tostring(value)
	end
	if depth > 6 then
		return "{...}"
	end
	local keys = {}
	for k in pairs(value) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = tostring(k) .. "=" .. lights.dump(value[k], depth + 1)
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

-- The AddDevice callback's second argument carries "the IDs of the Proxy
-- devices and the Protocol Driver's ID" for a proxy driver. [verified on OS
-- 3.4.2] It is the parsed-XML table C4:ParseXml produces: a node { Name,
-- Value, Attributes, ChildNodes } whose children named "protocol" and "proxy"
-- carry the ids as string Values, and deviceId equals the protocol id.
local ID_ROLES = { "protocol", "proxy" }

local function positive(value)
	local n = tonumber(value)
	if n and n > 0 then
		return n
	end
	return nil
end

-- "protocol" or "proxy" when name is one of them (exact) or contains one.
local function role_of(name, exact)
	if type(name) ~= "string" then
		return nil
	end
	name = name:lower()
	for _, role in ipairs(ID_ROLES) do
		if (exact and name == role) or (not exact and name:find(role, 1, true)) then
			return role
		end
	end
	return nil
end

-- { protocol = number|nil, proxy = number|nil } from the callback info: the
-- node tree first (ChildNodes recursively, names case-insensitive), then for
-- other shapes any key whose name contains "protocol" or "proxy" with a
-- positive numeric value (the pre-3.4.2 guess). Empty for nil or a non-table.
function lights.ids_from(info)
	local ids = {}
	if type(info) ~= "table" then
		return ids
	end

	local function walk_nodes(node, depth)
		if type(node) ~= "table" or depth > 8 then
			return
		end
		local role = role_of(node.Name, true)
		if role and ids[role] == nil then
			ids[role] = positive(node.Value)
		end
		if type(node.ChildNodes) == "table" then
			for _, child in ipairs(node.ChildNodes) do
				walk_nodes(child, depth + 1)
			end
		end
	end

	local function walk_keys(t, depth)
		if type(t) ~= "table" or depth > 4 then
			return
		end
		for k, v in pairs(t) do
			local role = role_of(k, false)
			if role and ids[role] == nil then
				ids[role] = positive(v)
			end
		end
		for _, v in pairs(t) do
			if ids.protocol and ids.proxy then
				return
			end
			walk_keys(v, depth + 1)
		end
	end

	walk_nodes(info, 0)
	if not (ids.protocol and ids.proxy) then
		walk_keys(info, 0)
	end
	return ids
end

-- The protocol id alone; the name the import used before ids_from.
function lights.protocol_id_from(info)
	return lights.ids_from(info).protocol
end

-- Name order, case-insensitive, ties by rid: the order every list is in.
local function by_name(a, b)
	local an, bn = string.lower(tostring(a.name or "")), string.lower(tostring(b.name or ""))
	if an ~= bn then
		return an < bn
	end
	return tostring(a.rid) < tostring(b.rid)
end

-- Trimmed, lower-cased: the key for "exact, case-insensitive" name matches.
local function norm(name)
	return (tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")):lower()
end

-- Picker and property texts: commas become spaces, since CUSTOM_SELECT lists
-- are comma-delimited [verified: FUND 12.3].
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

-- "#12" from Hue's v1 id ("/lights/12"), else the first 8 hex of the rid:
-- the stable number the owner also sees in the Hue app and the dev log.
local function v1_tag(id_v1, rid)
	local n = id_v1 and tostring(id_v1):match("(%d+)%s*$")
	if n then
		return "#" .. n
	end
	return "#" .. tostring(rid):sub(1, 8)
end

local function plural(n, word)
	return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

-- "a, b, c +2 more": at most lights.MAX_NAMED names.
local function some(names)
	if #names <= lights.MAX_NAMED then
		return table.concat(names, ", ")
	end
	local head = {}
	for i = 1, lights.MAX_NAMED do
		head[i] = names[i]
	end
	return table.concat(head, ", ") .. string.format(" +%d more", #names - lights.MAX_NAMED)
end

-- The sorted HUE_CONFIGURE params as one string, for change detection.
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

-- Registry access ---------------------------------------------------------------

local function copy_caps(caps)
	if type(caps) ~= "table" then
		return nil
	end
	return {
		has_color = caps.has_color == true or caps.has_color == "true",
		has_cct = caps.has_cct == true or caps.has_cct == "true",
		mirek_min = tonumber(caps.mirek_min),
		mirek_max = tonumber(caps.mirek_max),
		min_dim = tonumber(caps.min_dim),
	}
end

local function same_caps(a, b)
	if a == nil or b == nil then
		return a == b
	end
	return a.has_color == b.has_color and a.has_cct == b.has_cct and a.mirek_min == b.mirek_min
		and a.mirek_max == b.mirek_max and a.min_dim == b.min_dim
end

-- Read the persisted registry (v1 entries upgrade in place, see
-- bridge.registry) and normalise the caps as before. Returns the entries table.
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

-- Something changed that must reach the store at the end of this batch.
function lights:mark()
	self.dirty = true
end

function lights:flush()
	if self.dirty then
		self.dirty = false
		self.reg:save()
	end
end

-- Save now, whatever the dirty flag (driver.lua's dev actions poke entries directly).
function lights:save()
	self.dirty = false
	self.reg:save()
end

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

-- A copy of the registry entry, or nil for an unknown rid.
function lights:entry(rid)
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

function lights:rid_for(device_id)
	return (self.reg:by_device(device_id))
end

function lights:count()
	local n = 0
	for _ in pairs(self.registry) do
		n = n + 1
	end
	return n
end

-- Lights seen on the bridge in the last GET.
function lights:bridge_count()
	local n = 0
	for _ in pairs(self.models) do
		n = n + 1
	end
	return n
end

-- Registered rids in name order.
function lights:registered_rids()
	return self.reg:rids()
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

-- ok, result of one ctx.project call; a raised error is logged and read as
-- "unknown" by every caller.
function lights:project_call(name, ...)
	local ok, result = pcall(self.ctx.project[name], ...)
	if not ok then
		self.ctx.log.warn("lights: project.%s failed: %s", name, tostring(result))
		return false, nil
	end
	return true, result
end

-- { [room_id] = name } with numeric ids; empty when unknown.
function lights:project_rooms()
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

-- room_id → floor name from the project hierarchy: nested nodes keyed by
-- location id, numeric types 4 floor and 8 room [verified: hardware OS 3.4.2].
function lights:room_floors()
	local _, tree = self:project_call("hierarchy")
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

-- { [device_id] = true } of the devices bound to the bridge's binding 1; nil
-- when the lookup failed (GetBoundConsumerDevices returns nil when nothing is
-- bound [verified: API 32/_3], which is an empty set, not a failure).
function lights:project_bound_set()
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

-- The hue_light devices in the project as { [device_id] = GetDevices info },
-- or nil when the call failed or returned nothing: unknown, never "deleted" (§5).
function lights:project_lights()
	local ok, raw = self:project_call("devices", { C4iNames = lights.LIGHT_DRIVER })
	if not ok or type(raw) ~= "table" or next(raw) == nil then
		return nil
	end
	local out = {}
	for id, info in pairs(raw) do
		out[tonumber(id) or id] = info
	end
	return out
end

-- The Composer name of a device (protocol or proxy id), or nil.
function lights:display_name(id)
	if not id then
		return nil
	end
	local ok, name = self:project_call("display_name", id)
	if ok and name ~= nil and name ~= "" then
		return tostring(name)
	end
	return nil
end

-- Model-derived views -----------------------------------------------------------

-- Lights on the bridge without a registry entry, in name order (tombstoned
-- ones included; see new_models()).
function lights:unimported_models()
	local list = {}
	for rid, model in pairs(self.models) do
		if not self.registry[rid] then
			list[#list + 1] = model
		end
	end
	table.sort(list, by_name)
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

-- The Control4 room a light is added to when the owner names none: the
-- mapping of its Hue room. Returns room_id, room_name or nil, reason.
function lights:default_room(model, rooms)
	local room_rid, label = self:hue_room_of(model)
	if not room_rid then
		return nil, "no Hue room"
	end
	local mapping = self.reg:room_mapping(room_rid)
	if not mapping or not mapping.c4_room_id then
		return nil, "Hue room " .. label .. " not mapped"
	end
	local name = rooms[mapping.c4_room_id]
	if not name then
		if next(rooms) == nil then
			-- The project is unknown right now; trust the mapping.
			return mapping.c4_room_id, mapping.c4_room_name or ("room " .. tostring(mapping.c4_room_id))
		end
		return nil, "Hue room " .. label .. " mapped to a Control4 room that no longer exists"
	end
	return mapping.c4_room_id, name
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
		if type(item) == "table" and item.id ~= nil then
			local model = hue_model.light(item)
			local old = self.models[item.id]
			if old then
				model.online = old.online
			end
			models[item.id] = model
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
		for _, kind in ipairs({ "room", "zone", "bridge_home" }) do
			for _, item in ipairs(res[kind] or {}) do
				items[#items + 1] = item
			end
		end
		self.groups = groups.new()
		local counts = self.groups:absorb(items)
		self.groups_loaded = true
		self.ctx.log.debug("lights: %d rooms, %d zones, %d bridge_home cached", counts.room, counts.zone, counts.bridge_home)
	end
	self:refresh_registry()
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
function lights:refresh_registry()
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
			local changed = {}
			for k, v in pairs(fields) do
				if entry[k] ~= v then
					changed[k] = v
				end
			end
			if next(changed) then
				self.reg:update(rid, changed)
				self:mark()
			end
		end
	end
end

-- Messages -----------------------------------------------------------------

-- HUE_CONFIGURE params from a registry entry: the lights-design fields plus
-- hue_room (the group label, absent for no room), id_v1, and state "gone"
-- with gone_since while the light is missing (absent means linked) (§4).
function lights.configure_params(_self, rid, entry)
	local extra = { hue_room = entry.hue_room, id_v1 = entry.id_v1 }
	if entry.state == "gone" then
		extra.state = "gone"
		extra.gone_since = entry.gone_since
	end
	return hue_model.registry_configure_params(rid, entry, extra)
end

-- HUE_CONFIGURE to a registered light, from the registry entry (which the
-- last fetch refreshed, and which is available before any fetch).
function lights:send_configure(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	local params = self:configure_params(rid, entry)
	self.last_configure[rid] = signature(params)
	self.ctx.send(entry.device_id, "HUE_CONFIGURE", params)
	return true
end

-- True when the light has not been told its current configuration (first
-- time, or something in it changed: caps, name, room, state).
function lights:configure_changed(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	return self.last_configure[rid] ~= signature(self:configure_params(rid, entry))
end

-- Full HUE_STATE to a registered light that has a model.
function lights:send_state(rid, reason)
	local entry, model = self.registry[rid], self.models[rid]
	if not entry or not model then
		return false
	end
	self.ctx.send(entry.device_id, "HUE_STATE", hue_model.state_params(model, nil, reason))
	return true
end

-- HUE_CONFIGURE (when asked for, or when it changed) then full HUE_STATE.
-- False when the rid is not registered or has no model yet.
function lights:push(rid, reason, with_configure)
	if not self.registry[rid] or not self.models[rid] then
		return false
	end
	if with_configure or self:configure_changed(rid) then
		self:send_configure(rid)
	end
	self:send_state(rid, reason)
	return true
end

-- A light that left the bridge: HUE_CONFIGURE with state "gone" and
-- ONLINE false through HUE_STATE (§3). The device keeps everything else.
function lights:announce_gone(rid, reason)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	self:send_configure(rid)
	self.ctx.send(entry.device_id, "HUE_STATE", { rid = rid, online = "false", reason = reason or "event" })
	return true
end

-- Bridge startup, before any GET: HUE_CONFIGURE to every registered, bound
-- light from the persisted entry. Returns the number sent. Marks the lights
-- as configured so the first resync sends state only, then answers the
-- hellos that arrived before the registry was loaded (§4).
function lights:configure_all()
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

-- A device left the picture (forgotten, deleted, re-linked): the conflicts
-- that named it are over.
function lights:clear_conflicts_for(device_id)
	for rid, c in pairs(self.conflicts) do
		if c.holder == device_id or c.claimant == device_id then
			self.conflicts[rid] = nil
		end
	end
end

-- Answer a hello: configuration and full state when the light is modelled,
-- the configuration alone before the first GET (the resync brings the state).
function lights:answer_hello(rid)
	if self.models[rid] then
		return self:push(rid, "hello", true)
	end
	return self:send_configure(rid)
end

-- Register a bound device for a rid the registry lacks (§4 auto-adopt, Link
-- Devices). Fields from the model when it is known, else from what the light
-- announced. Returns the entry or nil.
function lights:adopt(device_id, rid, hello, how)
	local model = self.models[rid]
	local fields = self:fields_from_model(model)
	fields.device_id = device_id
	fields.name = fields.name or hello.name
	fields.model = fields.model or hello.model
	local entry, err = self.reg:add(rid, fields)
	if not entry then
		self.ctx.log.warn("lights: could not adopt device %d for %s: %s", device_id, tostring(rid), tostring(err))
		return nil
	end
	self:mark()
	if not model and self.synced then
		self.reg:set_state(rid, "gone")
	end
	self.ctx.log.always("lights: adopted %s (device %d) %s", tostring(entry.name or rid), device_id, how)
	return entry
end

-- A light said HUE_HELLO { rid?, device_id?, name?, model? }. Answers a known
-- rid; a device registered under another rid is answered with that one (its
-- persisted rid is stale after a re-link); a rid the registry lacks from
-- exactly one bound device is adopted (§4); two devices claiming one rid
-- change nothing and go to Attention. Before load() the hello waits for
-- configure_all(). Returns true when answered.
function lights:hello(rid, params)
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
		self.announced[device_id] = { rid = rid, name = params.name, model = params.model }
	end

	local entry = rid and self.registry[rid] or nil
	if entry then
		if device_id and entry.device_id ~= device_id then
			self.conflicts[rid] = { holder = entry.device_id, claimant = device_id }
			self.ctx.log.warn("lights: device %d claims %s, which device %d holds; nothing changed (see Attention)",
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
		self.ctx.log.info("lights: device %d said hello with %s; its registered light is %s", device_id,
			tostring(rid), held_rid)
		return self:answer_hello(held_rid)
	end
	if not rid then
		return false  -- a bare light: Link Devices matches it by name
	end

	local bound = self:project_bound_set()
	if not bound or not bound[device_id] then
		self.ctx.log.info("lights: device %d announced %s but is not bound; not adopted", device_id, rid)
		return false
	end
	for other_id, h in pairs(self.announced) do
		if other_id ~= device_id and h.rid == rid then
			self.conflicts[rid] = { holder = other_id, claimant = device_id }
			self.ctx.log.warn("lights: devices %d and %d both announce %s; neither adopted (see Attention)",
				other_id, device_id, rid)
			return false
		end
	end
	if not self:adopt(device_id, rid, params, "from its own persisted rid") then
		return false
	end
	self:flush()
	return self:answer_hello(rid)
end

-- HUE_GOODBYE { rid?, device_id }: the device is being deleted in Composer.
-- The entry becomes a tombstone (§3). Returns the tombstone or nil.
function lights:goodbye(params)
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
		self.ctx.log.debug("lights: HUE_GOODBYE from an unregistered device (%s, %s)", tostring(params.device_id),
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
	self.ctx.log.always("lights: %s (device %d) was deleted in Composer; Add Light lists it as deleted, "
		.. "Import All New Lights skips it", label, entry.device_id)
	return tomb
end

-- OnBindingChanged for the bridge's binding 1: an unbound device's entry
-- becomes "unbound", a re-bound one "linked" (and is told its configuration
-- and state). Returns true when an entry changed state.
function lights:on_binding_changed(binding, class, bound, other_id)
	if tonumber(binding) ~= lights.BINDING then
		return false
	end
	if class ~= nil and class ~= lights.BINDING_CLASS then
		return false
	end
	local device_id = positive(other_id)
	if not device_id then
		return false
	end
	local rid, entry = self.reg:by_device(device_id)
	if not rid then
		if bound == true or bound == "true" then
			self.ctx.log.info("lights: device %d bound but not registered; its hello or Link Devices adopts it", device_id)
		end
		return false
	end
	local changed = false
	if bound == false or bound == "false" then
		if entry.state == "linked" and self.reg:set_state(rid, "unbound") then
			changed = true
			self.ctx.log.warn("lights: %s (device %d) was unbound from the bridge", self:entry_label(rid, entry), device_id)
		end
	elseif bound == true or bound == "true" then
		if entry.state == "unbound" and self.reg:set_state(rid, "linked") then
			changed = true
			self.ctx.log.info("lights: %s (device %d) is bound again", self:entry_label(rid, entry), device_id)
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

-- Step 1, the project side: the bound set and the hue_light devices in the
-- project decide linked / unbound / tombstone per entry (bridge.registry
-- holds the rules; a failed or empty GetDevices is "unknown"). Called by
-- driver.lua at late init and here after every resync and import. Saves
-- unless `no_save` (the caller's batch does).
function lights:reconcile(no_save)
	local bound = self:project_bound_set()
	if not bound then
		self.ctx.log.warn("lights: reconcile skipped: the bound-device lookup failed")
		return { unbound = {}, relinked = {}, tombstoned = {} }
	end
	local infos = self:project_lights()
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
		self.ctx.log.warn("lights: %s was deleted in Composer while the bridge was not watching; Add Light lists it "
			.. "as deleted", tostring(tomb.name or rid))
	end
	for _, rid in ipairs(r.unbound) do
		local entry = self.registry[rid]
		self.ctx.log.warn("lights: %s (device %d) is not bound to this bridge", self:entry_label(rid, entry),
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
		if not self.announced_new[model.rid] then
			self.announced_new[model.rid] = true
			local hint_rid, hint = self:relink_hint(model)
			self.ctx.log.always("lights: new light %s on the bridge; use Add Light or Import All New Lights%s",
				self:light_label(model), hint and string.format("; it looks like %s (device %d): re-link?",
					self:entry_label(hint_rid, hint), hint.device_id) or "")
		end
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
	if self.ctx.persist_get(lights.AUTOMAP_KEY) then
		return false
	end
	if #self.groups:groups() == 0 or next(self:project_rooms()) == nil then
		return false
	end
	local text = self:map_rooms_by_name(true)
	self.ctx.persist_set(lights.AUTOMAP_KEY, "done")
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

-- After every stream connect: the six GETs, the reconciliation, then full
-- HUE_STATE (reason "resync") to every registered light, with HUE_CONFIGURE
-- first the first time or when it changed. done(ok, err, sent). A resync
-- requested while one (or an import) is running is run once more after it
-- (the latest done wins).
function lights:resync(done)
	done = done or function() end
	if self.resyncing or self.importing then
		self.resync_pending = done
		return
	end
	self.resyncing = true
	self:fetch_all(function(res, err)
		local sent = 0
		local ok, e = true, nil
		if res then
			ok, e = pcall(function()
				self:absorb(res)
				sent = self:settle("resync", not self.configured_once)
			end)
			if not ok then
				self.ctx.log.error("lights: resync failed: %s", tostring(e))
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

function lights:run_pending_resync()
	local pending = self.resync_pending
	self.resync_pending = nil
	if pending then
		self:resync(pending)
	end
end

-- Event fan-out --------------------------------------------------------------

local function has_field(fields, name)
	for _, field in ipairs(fields) do
		if field == name then
			return true
		end
	end
	return false
end

-- A light item of an event container. Returns the number of messages sent.
function lights:on_light_item(item, kind)
	local rid = item.id
	local entry, model = self.registry[rid], self.models[rid]
	if kind == "add" then
		local fresh = hue_model.light(item)
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
		if not self.announced_new[rid] and not self:is_tombstoned(rid) then
			self.announced_new[rid] = true
			local hint_rid, hint = self:relink_hint(fresh)
			self.ctx.log.always("lights: new light %s on the bridge; use Add Light or Import All New Lights%s",
				self:light_label(fresh), hint and string.format("; it looks like %s (device %d): re-link?",
					self:entry_label(hint_rid, hint), hint.device_id) or "")
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
		self.ctx.send(entry.device_id, "HUE_STATE", params)
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
			self.ctx.send(entry.device_id, "HUE_STATE", hue_model.state_params(model, { "online" }, "event"))
			sent = sent + 1
		end
	end
	return sent
end

-- A device item: a new device record, a renamed device, or a deleted one.
function lights:on_device_item(item, kind)
	if kind == "add" then
		local parsed = hue_model.devices({ item })
		self.devices[item.id] = parsed[item.id]
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
function lights:on_container(container)
	if type(container) ~= "table" or type(container.data) ~= "table" then
		return 0
	end
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
	return sent
end

-- Device creation ---------------------------------------------------------------

-- The text an action gets while another is running (§6).
function lights:busy_text()
	if self.importing then
		return "Busy: importing; try again in a moment"
	elseif self.resyncing then
		return "Busy: resyncing; try again in a moment"
	end
	return nil
end

-- Composer name at creation (§7): the Hue device name for a single-light
-- device (what the Hue app shows), the light's own name on a multi-light device.
function lights:creation_name(model)
	local device = self.devices[model.device_rid]
	if device and device.name and #device.light_rids <= 1 then
		return device.name
	end
	return model.name
end

-- One AddDevice per job, one at a time (the next from the previous
-- callback, so Director adds one driver at a time), each bound, registered
-- (saved at once) and told its configuration and state. jobs = { { model,
-- room_id, room_name } ... }; finish(created, failed, err) with created =
-- { { model, device_id, room_name } ... }, failed = { model ... }, err the
-- Lua error that stopped the run early, if any. The caller owns `importing`.
function lights:create_lights(jobs, finish)
	local total, i, created, failed = #jobs, 0, {}, {}
	local add_next

	local function on_added(job, device_id, info)
		local model = job.model
		if not self.device_info_logged then
			self.device_info_logged = true
			self.ctx.log.always("AddDevice callback for %s: deviceId=%s info=%s",
				tostring(model.name), tostring(device_id), lights.dump(info))
		end
		device_id = tonumber(device_id)
		if not device_id or device_id <= 0 then
			self.ctx.log.error("lights: AddDevice failed for %s (deviceId %s); skipped",
				tostring(model.name), tostring(device_id))
			failed[#failed + 1] = model
			return
		end
		local ids = lights.ids_from(info)
		if ids.protocol and ids.protocol ~= device_id then
			self.ctx.log.always("AddDevice for %s: binding protocol id %d rather than deviceId %d",
				tostring(model.name), ids.protocol, device_id)
			device_id = ids.protocol
		end
		self.ctx.bind(self:bridge_id(), device_id)
		local fields = self:fields_from_model(model)
		fields.device_id = device_id
		fields.proxy_id = ids.proxy
		fields.created_room_id = job.room_id
		local entry, err = self.reg:add(model.rid, fields)
		if not entry then
			self.ctx.log.error("lights: AddDevice created device %d for %s but the registry refused it: %s",
				device_id, tostring(model.name), tostring(err))
			failed[#failed + 1] = model
			return
		end
		self:save()  -- after every add: a failure half-way must not leave a created device unregistered
		created[#created + 1] = { model = model, device_id = device_id, room_name = job.room_name }
		self.ctx.log.info("lights: added %s to %s (device %d, %d of %d)", tostring(model.name),
			tostring(job.room_name), device_id, i, total)
		self:push(model.rid, "resync", true)
	end

	-- Each step is its own pcall so an error stops the run cleanly, with the
	-- caller told what happened.
	local function step()
		local ok, err = pcall(add_next)
		if not ok then
			self.ctx.log.error("lights: adding lights failed: %s", tostring(err))
			finish(created, failed, tostring(err))
		end
	end

	add_next = function()
		i = i + 1
		local job = jobs[i]
		if not job then
			return finish(created, failed)
		end
		local name = self:creation_name(job.model)
		self.ctx.log.info("lights: adding %s to %s (%d of %d)", tostring(name), tostring(job.room_name), i, total)
		self.ctx.add_device(lights.LIGHT_DRIVER, job.room_id, name, function(device_id, info)
			self:protect("register " .. tostring(name), on_added, job, device_id, info)
			step()
		end)
	end

	step()
end

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
	local rooms = self:project_rooms()
	local room_name
	room_id = positive(room_id)
	if room_id then
		room_name = rooms[room_id]
		if not room_name then
			if next(rooms) ~= nil then
				done(false, string.format("Not added: Control4 room %d no longer exists", room_id))
				return false
			end
			room_name = "room " .. tostring(room_id)
		end
	else
		local why
		room_id, why = self:default_room(model, rooms)
		if not room_id then
			done(false, string.format("Not added: %s: %s; pick a room, or Set Room Mapping first",
				self:light_label(model, false), why))
			return false
		end
		room_name = why
	end

	self.importing = true
	local label = self:light_label(model, false)
	self:create_lights({ { model = model, room_id = room_id, room_name = room_name } }, function(created, _, err)
		self.importing = false
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
	self.importing = true
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

	local rooms = self:project_rooms()
	local jobs, unmapped, deleted = {}, {}, {}
	for _, model in ipairs(self:unimported_models()) do
		if self:is_tombstoned(model.rid) then
			local tomb = self.reg:tombstones()[model.rid]
			deleted[#deleted + 1] = string.format("%s (deleted %s)", self:light_label(model, false),
				date_of(tomb.deleted_at))
		else
			local room_id, why = self:default_room(model, rooms)
			if room_id then
				jobs[#jobs + 1] = { model = model, room_id = room_id, room_name = why }
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
				names[#names + 1] = string.format("%s to %s (device %d)", self:light_label(c.model, false),
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

	self:create_lights(jobs, function(created, failed, err)
		self:reconcile(true)
		self:flush()
		finish(err == nil and #failed == 0, summary(created, failed, err))
	end)
end

-- The scaffold's name for the import, kept for callers that predate
-- import_new: report(text) gets the final text.
function lights:import(report)
	report = report or function() end
	return self:import_new(function(_, text)
		report(text)
	end)
end

-- Re-link Device To Light: the entry keeps its device, proxy, programming
-- and name and swaps the rid (§1 rule 3); the light hears its new
-- configuration and state. Returns ok, text.
function lights:relink(device_id, new_rid)
	local busy = self:busy_text()
	if busy then
		return false, busy
	end
	device_id = positive(device_id)
	if not device_id or type(new_rid) ~= "string" or new_rid == "" then
		return false, "Not re-linked: pick a device and a light"
	end
	local old_rid, entry = self.reg:by_device(device_id)
	if not old_rid then
		return false, string.format("Not re-linked: device %d is not a registered light", device_id)
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
	local model = self.models[new_rid]
	if not model then
		return false, string.format("Not re-linked: light %s is not on the bridge (connect the event stream and try again)",
			tostring(new_rid))
	end
	local old_label = self:entry_label(old_rid, entry)
	local fields = self:fields_from_model(model)
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
	local text = string.format("Re-linked device %d (was %s) to %s", device_id, old_label, self:light_label(model))
	self.ctx.log.always("lights: %s", text)
	return true, text
end

-- The unimported lights whose Hue name (or device name) matches one of `names`.
function lights:match_unimported_by_name(names)
	local wanted = {}
	for _, name in ipairs(names) do
		if name ~= nil and norm(name) ~= "" then
			wanted[norm(name)] = true
		end
	end
	local out = {}
	for _, model in ipairs(self:unimported_models()) do
		local device = self.devices[model.device_rid]
		if wanted[norm(model.name)] or (device and device.name and wanted[norm(device.name)]) then
			out[#out + 1] = model
		end
	end
	return out
end

-- Link Devices: every device bound to the bridge that the registry lacks
-- is adopted by the rid it announced in HUE_HELLO, else by an exact, unique
-- name match (Composer name or announced name) against the unimported
-- lights. Returns the report text.
function lights:link_devices()
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local bound = self:project_bound_set()
	if not bound then
		return "Not linked: the bound-device lookup failed (see the Lua output)"
	end
	local ids = {}
	for id in pairs(bound) do
		if positive(id) and not self.reg:by_device(id) then
			ids[#ids + 1] = positive(id)
		end
	end
	table.sort(ids)
	if #ids == 0 then
		local n = 0
		for _ in pairs(bound) do
			n = n + 1
		end
		if n == 0 then
			return "No devices are bound to this bridge"
		end
		return string.format("All %d bound devices are registered", n)
	end

	-- Two unregistered devices with one Composer name cannot both be the
	-- light of that name; neither is matched by name.
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
			problems[#problems + 1] = string.format("%s announces %s, which device %d holds (Forget Light on one of them)",
				who, self:entry_label(rid, holder), holder.device_id)
		elseif rid then
			local entry = self:adopt(id, rid, hello, "from its own persisted rid (Link Devices)")
			if entry then
				linked[#linked + 1] = string.format("%s to %s by its rid%s", who, self:registered_label(rid, entry),
					self.models[rid] and "" or " (not on the bridge: marked gone)")
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
				local model = matches[1]
				local entry = self:adopt(id, model.rid, hello, "by its name (Link Devices)")
				if entry then
					linked[#linked + 1] = string.format("%s to %s by name", who, self:light_label(model))
					self:answer_hello(model.rid)
				else
					problems[#problems + 1] = string.format("%s: could not register %s (see the Lua output)", who, model.rid)
				end
			elseif #matches > 1 then
				problems[#problems + 1] = string.format("%s: %d unimported Hue lights have that name; "
					.. "rename the device in Composer to one Hue light's exact name and run Link Devices again", who,
					#matches)
			else
				problems[#problems + 1] = string.format("%s: no unimported Hue light has that name; "
					.. "rename the device in Composer to the Hue light's exact name and run Link Devices again", who)
			end
		end
	end
	self:flush()
	local parts = {}
	if #linked > 0 then
		parts[#parts + 1] = string.format("Linked %s: %s", plural(#linked, "device"), table.concat(linked, ", "))
	end
	if #problems > 0 then
		parts[#parts + 1] = string.format("not linked %d: %s", #problems, table.concat(problems, "; "))
	end
	local text = table.concat(parts, "; ")
	self.ctx.log.always("lights: %s", text)
	return text
end

-- Forget Light: the entry goes, the device is unbound and told HUE_FORGOTTEN,
-- and stays in the project for the owner to delete; the rid is listed under
-- Add Light again. Returns ok, text.
function lights:forget(device_id)
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
		return false, string.format("Not forgotten: device %d is not a registered light", device_id)
	end
	local label = self:entry_label(rid, entry)
	self.reg:forget(rid)
	self:mark()
	self.last_configure[rid] = nil
	self.conflicts[rid] = nil
	self:clear_conflicts_for(device_id)
	self.announced[device_id] = nil
	self.ctx.send(device_id, "HUE_FORGOTTEN", { rid = rid, name = entry.name })
	local ok, err = self:project_call("unbind", device_id)
	if not ok then
		self.ctx.log.warn("lights: unbind of device %d failed: %s", device_id, tostring(err))
	end
	self:flush()
	local text = string.format("Forgot %s (device %d): unbound and left in the project for you to delete; "
		.. "the Hue light is listed under Add Light again", label, device_id)
	self.ctx.log.always("lights: %s", text)
	return true, text
end

-- HUE_FORGET { rid?, device_id } from a light's Forget This Light action.
-- A device the registry lacks is still told HUE_FORGOTTEN, so its Status
-- explains what to do. Returns ok, text.
function lights:forget_request(params)
	params = params or {}
	local device_id = positive(params.device_id)
	if not device_id and type(params.rid) == "string" and self.registry[params.rid] then
		device_id = self.registry[params.rid].device_id
	end
	if not device_id then
		return false, "Not forgotten: the light named no device"
	end
	if not self.reg:by_device(device_id) then
		self.ctx.send(device_id, "HUE_FORGOTTEN", { rid = params.rid, name = params.name })
		self.announced[device_id] = nil
		return false, string.format("Not forgotten: device %d is not a registered light (told it so)", device_id)
	end
	return self:forget(device_id)
end

-- Linked entries whose Composer name differs from the Hue name and whose
-- difference the owner has not accepted [Q 10]: { rid, entry, current }...
function lights:name_differences()
	local out = {}
	for _, rid in ipairs(self.reg:rids("linked")) do
		local entry = self.registry[rid]
		local hue = entry.name
		if hue and hue ~= "" and entry.name_dismissed ~= hue then
			local current = self:display_name(entry.proxy_id or entry.device_id)
			if current and current ~= hue then
				out[#out + 1] = { rid = rid, entry = entry, current = current }
			end
		end
	end
	return out
end

-- Adopt Hue Names: RenameDevice(proxy_id, Hue name) for every linked device
-- whose Composer name differs [verified: API 22/_32]; entries without a
-- proxy id are listed, not renamed. Returns the report text.
function lights:adopt_hue_names()
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local renamed, skipped = {}, {}
	for _, rid in ipairs(self.reg:rids("linked")) do
		local entry = self.registry[rid]
		local hue = entry.name
		if hue and hue ~= "" then
			local current = self:display_name(entry.proxy_id or entry.device_id)
			if current and current ~= hue then
				if not entry.proxy_id then
					skipped[#skipped + 1] = string.format("%s (device %d): no proxy id known", current, entry.device_id)
				else
					local ok, err = self:project_call("rename", entry.proxy_id, hue)
					if ok then
						renamed[#renamed + 1] = string.format("%s → %s (device %d)", current, hue, entry.device_id)
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
		text = "No Composer names differ from the Hue names"
	else
		local parts = {}
		if #renamed > 0 then
			parts[#parts + 1] = string.format("Renamed %s: %s", plural(#renamed, "device"), table.concat(renamed, ", "))
		end
		if #skipped > 0 then
			parts[#parts + 1] = string.format("not renamed %d: %s", #skipped, table.concat(skipped, ", "))
		end
		text = table.concat(parts, "; ")
	end
	self.ctx.log.always("lights: %s", text)
	return text
end

-- Accept Names As They Are: every current difference is recorded as
-- accepted and leaves Attention until the Hue name changes again [Q 10].
function lights:accept_names()
	local busy = self:busy_text()
	if busy then
		return busy
	end
	local accepted = {}
	for _, d in ipairs(self:name_differences()) do
		self.reg:update(d.rid, { name_dismissed = d.entry.name })
		self:mark()
		accepted[#accepted + 1] = string.format("%s (Hue: %s)", d.current, d.entry.name)
	end
	self:flush()
	local text
	if #accepted == 0 then
		text = "No Composer names differ from the Hue names"
	else
		text = string.format("Accepted %s: %s", plural(#accepted, "name difference"), table.concat(accepted, ", "))
	end
	self.ctx.log.always("lights: %s", text)
	return text
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
	local rooms = self:project_rooms()
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
	local rooms = self:project_rooms()
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
-- only; nothing is moved (no API exists). Returns the text.
function lights:room_audit()
	if next(self.reg:room_mappings()) == nil then
		return "No room mappings; use Map Rooms By Name or Set Room Mapping first"
	end
	local checks, ids = {}, {}
	for _, rid in ipairs(self.reg:rids("linked")) do
		local entry = self.registry[rid]
		local mapping = self.reg:room_mapping(entry.hue_room_rid)
		if mapping and mapping.c4_room_id then
			checks[#checks + 1] = { rid = rid, entry = entry, mapping = mapping }
			ids[#ids + 1] = tostring(entry.device_id)
		end
	end
	if #checks == 0 then
		return "Nothing to audit: no linked light is in a mapped Hue room"
	end
	local ok, raw = self:project_call("devices", { DeviceIds = table.concat(ids, ",") })
	if not ok or type(raw) ~= "table" or next(raw) == nil then
		return "Room Audit unavailable: the project lookup returned nothing (see the Lua output)"
	end
	local infos = {}
	for id, info in pairs(raw) do
		infos[tonumber(id) or id] = info
	end
	local rooms = self:project_rooms()
	local lines, unknown = {}, 0
	for _, c in ipairs(checks) do
		local info = infos[c.entry.device_id]
		if type(info) ~= "table" then
			unknown = unknown + 1
		elseif tonumber(info.roomId) ~= c.mapping.c4_room_id then
			local name = tostring(info.deviceName or c.entry.name)
			local hue_room = self.groups:label(c.entry.hue_room_rid)
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
		text = string.format("All %d linked lights in mapped Hue rooms are in the rooms their Hue rooms map to", #checks)
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

-- The Lights property: "47 on bridge, 47 imported, 2 new, 1 missing, 0
-- unbound, 1 deleted"; "<n> imported" before the first full GET.
function lights:summary()
	if not self.synced then
		return string.format("%d imported", self:count())
	end
	local c = self.reg:counts()
	return string.format("%d on bridge, %d imported, %d new, %d missing, %d unbound, %d deleted", self:bridge_count(),
		self:count(), #self:new_models(), c.gone, c.unbound, c.tombstones)
end

-- The Attention property: one item per kind of thing waiting for the owner,
-- joined with "; ", or "None".
function lights:attention()
	local items = {}

	local new = self:new_models()
	if #new > 0 then
		local names = {}
		for _, model in ipairs(new) do
			local hint_rid, hint = self:relink_hint(model)
			names[#names + 1] = self:light_label(model) .. (hint and string.format(" (looks like %s, device %d; re-link?)",
				self:entry_label(hint_rid, hint), hint.device_id) or "")
		end
		items[#items + 1] = string.format("%s on the bridge: %s (Add Light or Import All New Lights)",
			plural(#new, "new light"), some(names))
	end

	local gone = self.reg:rids("gone")
	if #gone > 0 then
		local names = {}
		for _, rid in ipairs(gone) do
			local entry = self.registry[rid]
			names[#names + 1] = string.format("%s (device %d, since %s)", self:entry_label(rid, entry), entry.device_id,
				date_of(entry.gone_since))
		end
		items[#items + 1] = string.format("%s missing from the bridge: %s (Re-link Device To Light or Forget Light)",
			plural(#gone, "light"), some(names))
	end

	local unbound = self.reg:rids("unbound")
	if #unbound > 0 then
		local names = {}
		for _, rid in ipairs(unbound) do
			local entry = self.registry[rid]
			names[#names + 1] = string.format("%s (device %d)", self:entry_label(rid, entry), entry.device_id)
		end
		items[#items + 1] = string.format("%s: %s (bind it to this bridge in Composer, or Forget Light)",
			plural(#unbound, "unbound device"), some(names))
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
		elseif self.models[rid] then
			label = self:light_label(self.models[rid], false)
		end
		items[#items + 1] = string.format("2 devices claim Hue light %s: %d and %d (Forget Light on one of them)", label,
			c.holder, c.claimant)
	end

	local diffs = self:name_differences()
	if #diffs > 0 then
		local names = {}
		for _, d in ipairs(diffs) do
			names[#names + 1] = string.format("%s is %s in Hue", d.current, d.entry.name)
		end
		items[#items + 1] = string.format("%d Hue name%s differ%s from the Composer names: %s "
			.. "(Adopt Hue Names or Accept Names As They Are)", #diffs, #diffs == 1 and "" or "s",
			#diffs == 1 and "s" or "", some(names))
	end

	local rooms = self:project_rooms()
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
				.. "(Set Room Mapping)", #broken, #broken == 1 and "" or "s", #broken == 1 and "s" or "", some(broken))
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
		items[#items + 1] = string.format("%s offline for more than 24 h: %s", plural(#offline, "light"), some(offline))
	end

	if #items == 0 then
		return "None"
	end
	return table.concat(items, "; ")
end

-- The Room Mappings property: every Hue room and zone with its Control4
-- room, "(unmapped)" or "(Control4 room gone)", then mappings whose Hue
-- group was deleted; "None; use Map Rooms By Name" while nothing is mapped.
function lights:room_mappings_text()
	local mappings = self.reg:room_mappings()
	if next(mappings) == nil then
		return "None; use Map Rooms By Name"
	end
	local rooms = self:project_rooms()
	local parts, seen = {}, {}
	for _, group in ipairs(self.groups:groups()) do
		seen[group.rid] = true
		parts[#parts + 1] = string.format("%s → %s", self.groups:label(group.rid),
			self:mapping_target(mappings[group.rid], rooms))
	end
	local stale = {}
	for group_rid, mapping in pairs(mappings) do
		if not seen[group_rid] then
			stale[#stale + 1] = { rid = group_rid, name = mapping.hue_name or group_rid, mapping = mapping }
		end
	end
	table.sort(stale, by_name)
	for _, s in ipairs(stale) do
		parts[#parts + 1] = string.format("%s → %s", self:group_label(s.rid, s.mapping),
			self:mapping_target(s.mapping, rooms))
	end
	return table.concat(parts, "; ")
end

-- Pickers (§8): { text, value } arrays, value a string; one explanatory
-- entry with value "" when there is nothing to pick ------------------------------

local function empty_list(text)
	return { { text = text, value = "" } }
end

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
			local hint_rid, hint = self:relink_hint(model)
			if hint then
				hinted[#hinted + 1] = { text = string.format("%s (looks like %s, device %d; re-link?)", self:light_label(model),
					self:entry_label(hint_rid, hint), hint.device_id), value = model.rid }
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
-- name), sorted; mode "add" starts with "(mapped room)" (value ""), mode
-- "mapping" with "(no mapping)" (value "none").
function lights:picker_rooms(mode)
	local rooms = self:project_rooms()
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
		table.insert(list, 1, { text = "(mapped room)", value = "" })
	elseif mode == "mapping" then
		table.insert(list, 1, { text = "(no mapping)", value = "none" })
	end
	return list
end

-- Re-link's Device: the gone and unbound entries.
function lights:picker_relink_devices()
	local list = {}
	for _, state in ipairs({ "gone", "unbound" }) do
		for _, rid in ipairs(self.reg:rids(state)) do
			local entry = self.registry[rid]
			list[#list + 1] = { text = string.format("%s (device %d, %s since %s)", sanitise(entry.name or rid),
				entry.device_id, state, short_date_of(entry[state .. "_since"])), value = tostring(entry.device_id) }
		end
	end
	if #list == 0 then
		return empty_list("(no gone or unbound devices)")
	end
	return list
end

-- Forget Light's Device: every entry.
function lights:picker_forget_devices()
	local list = {}
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		local text = string.format("%s (device %d)", self:entry_label(rid, entry), entry.device_id)
		if entry.state ~= "linked" then
			text = text .. " " .. entry.state
		end
		list[#list + 1] = { text = text, value = tostring(entry.device_id) }
	end
	if #list == 0 then
		return empty_list("(no registered lights)")
	end
	return list
end

-- Set Room Mapping's Hue Room: rooms then zones, each with its mapping, then
-- mappings whose Hue group was deleted (so they can be removed).
function lights:picker_hue_rooms()
	local rooms = self:project_rooms()
	local mappings = self.reg:room_mappings()
	local list, seen = {}, {}
	for _, group in ipairs(self.groups:groups()) do
		seen[group.rid] = true
		list[#list + 1] = { text = string.format("%s → %s", sanitise(self.groups:label(group.rid)),
			sanitise(self:mapping_target(mappings[group.rid], rooms))), value = group.rid }
	end
	local stale = {}
	for group_rid, mapping in pairs(mappings) do
		if not seen[group_rid] then
			stale[#stale + 1] = { rid = group_rid, name = mapping.hue_name or group_rid, mapping = mapping }
		end
	end
	table.sort(stale, by_name)
	for _, s in ipairs(stale) do
		list[#list + 1] = { text = string.format("%s → %s", sanitise(self:group_label(s.rid, s.mapping)),
			sanitise(self:mapping_target(s.mapping, rooms))), value = s.rid }
	end
	if #list == 0 then
		return empty_list("(no Hue rooms fetched yet; connect the event stream)")
	end
	return list
end

return lights
