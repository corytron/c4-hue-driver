-- The Hue lights a bridge represents as Control4 devices: the persisted
-- registry (rid → device), and the flows that keep the light drivers current:
-- import (Composer action), resync (after every stream connect), event
-- fan-out, the HUE_HELLO handshake. docs/lights-design.md, "Bridge: model,
-- registry, import".
--
-- Every C4 call goes through ctx so the module runs on plain tables in specs.
-- Each ctx field defaults to the real call when the driver leaves it out, so
-- the driver only has to supply `http`.
--
-- Two rules inherited from the spike (docs/design.md): the three GETs run one
-- after another (one C4:url queue per host spelling), chained from
-- http.request callbacks, which are OnDone callbacks and may start a transfer;
-- on_container runs inside OnBodyChunk and must not start one, so it only
-- sends messages. Every callback body is pcall-wrapped: an error raised into
-- Director's callback machinery would leave an import or resync half done
-- with its guard flag still set.

local log = require("common.log")
local hue_model = require("bridge.hue_model")

local lights = {}
lights.__index = lights

lights.REGISTRY_KEY = "hue_lights"
lights.LIGHT_DRIVER = "hue_light.c4z"
lights.BINDING = 1
lights.BINDING_CLASS = "HUE_BRIDGE"
lights.RESOURCES = {
	{ kind = "light", path = "/clip/v2/resource/light" },
	{ kind = "device", path = "/clip/v2/resource/device" },
	{ kind = "zigbee", path = "/clip/v2/resource/zigbee_connectivity" },
}

-- ctx fields (all but http optional):
--   http(req, cb)            req = { path, method }; the driver adds ip and key
--                            and calls bridge.http.request; cb(result)
--   send(id, cmd, params)    C4:SendToDevice(id, cmd, params)
--   add_device(driver, room_id, name, cb)   C4:AddDevice; cb(device_id, info)
--   bind(bridge_id, light_id)               C4:Bind(bridge_id, 1, light_id, 1, "HUE_BRIDGE")
--   persist_get(name) / persist_set(name, value)   C4:PersistGetValue / SetValue
--   bridge_id, room_id       numbers; default C4:GetDeviceID() / C4:RoomGetId()
--                            read at the time of use
--   log                      a common.log look-alike
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

	return setmetatable({
		ctx = ctx,
		registry = {},          -- rid → { device_id, proxy_id?, name, model, caps }, persisted
		models = {},            -- rid → normalised light, from the last GET (memory only)
		devices = {},           -- device rid → hue_model.devices() record (memory only)
		configured_once = false,
		importing = false,
		resyncing = false,
		resync_pending = nil,   -- a done callback to run a second resync for
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

local function by_name(a, b)
	if a.name == b.name then
		return tostring(a.rid) < tostring(b.rid)
	end
	return tostring(a.name) < tostring(b.name)
end

-- Registered rids in a stable order (by name, then rid).
function lights:registered_rids()
	local list = {}
	for rid, entry in pairs(self.registry) do
		list[#list + 1] = { rid = rid, name = entry.name or "" }
	end
	table.sort(list, by_name)
	for i, item in ipairs(list) do
		list[i] = item.rid
	end
	return list
end

-- Registry -----------------------------------------------------------------

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

-- Read the persisted registry. Entries are validated: a string rid and a
-- numeric device id are required, everything else is optional (entries
-- written before proxy_id existed have none).
function lights:load()
	local stored = self.ctx.persist_get(lights.REGISTRY_KEY)
	self.registry = {}
	if type(stored) == "table" then
		for rid, entry in pairs(stored) do
			local device_id = type(entry) == "table" and tonumber(entry.device_id) or nil
			if type(rid) == "string" and device_id then
				self.registry[rid] = {
					device_id = device_id,
					proxy_id = positive(entry.proxy_id),
					name = entry.name ~= nil and tostring(entry.name) or "",
					model = entry.model ~= nil and tostring(entry.model) or nil,
					caps = copy_caps(entry.caps),
				}
			end
		end
	end
	return self.registry
end

function lights:save()
	self.ctx.persist_set(lights.REGISTRY_KEY, self.registry)
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
	return {
		device_id = entry.device_id,
		proxy_id = entry.proxy_id,
		name = entry.name,
		model = entry.model,
		caps = copy_caps(entry.caps),
	}
end

function lights:rid_for(device_id)
	device_id = tonumber(device_id)
	for rid, entry in pairs(self.registry) do
		if entry.device_id == device_id then
			return rid
		end
	end
	return nil
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

-- The Lights property before any import has run.
function lights:summary()
	return string.format("%d imported", self:count())
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

-- Fetching and absorbing bridge state ---------------------------------------

-- GET the three resource lists one after another. done({ light, device,
-- zigbee }) with the decoded `data` arrays, or done(nil, err) after the first
-- failure. Chaining from the http callback is fine: it is an OnDone callback.
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

-- Replace the in-memory models and devices with a fetch result, apply the
-- connectivity to the models, and refresh the registry's cached name, model
-- and caps (persisted when something changed). Logs lights that are
-- registered but gone from the bridge, and Hue renames.
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
			local device = self.devices[conn.device_rid]
			for _, rid in ipairs(device and device.light_rids or {}) do
				if models[rid] then
					models[rid].online = conn.online
				end
			end
		end
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

function lights:refresh_registry()
	local dirty = false
	for _, rid in ipairs(self:registered_rids()) do
		local entry, model = self.registry[rid], self.models[rid]
		if not model then
			self.ctx.log.warn("lights: %s (device %s) is registered but no longer on the bridge",
				tostring(entry.name), tostring(entry.device_id))
		else
			if self:take_name(entry, model) then
				dirty = true
			end
			local device = self.devices[model.device_rid]
			local model_name = device and device.model or entry.model
			if model_name ~= entry.model then
				entry.model = model_name
				dirty = true
			end
			local caps = hue_model.caps(model)
			if not same_caps(caps, entry.caps) then
				entry.caps = caps
				dirty = true
			end
		end
	end
	if dirty then
		self:save()
	end
end

-- Messages -----------------------------------------------------------------

-- HUE_CONFIGURE to a registered light, from the registry entry (which the
-- last fetch refreshed, and which is available before any fetch).
function lights:send_configure(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	self.ctx.send(entry.device_id, "HUE_CONFIGURE", hue_model.registry_configure_params(rid, entry))
	return true
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

-- HUE_CONFIGURE (optional) then full HUE_STATE. False when the rid is not
-- registered or has no model yet.
function lights:push(rid, reason, with_configure)
	if not self.registry[rid] or not self.models[rid] then
		return false
	end
	if with_configure then
		self:send_configure(rid)
	end
	self:send_state(rid, reason)
	return true
end

-- Bridge startup, before any GET: HUE_CONFIGURE to every registered light
-- from the persisted caps. Returns the number sent. Marks the lights as
-- configured so the first resync sends state only.
function lights:configure_all()
	local n = 0
	for _, rid in ipairs(self:registered_rids()) do
		if self:send_configure(rid) then
			n = n + 1
		end
	end
	self.configured_once = true
	return n
end

-- A light said HUE_HELLO. The rid is nil when the light has none yet
-- (SendToDevice drops empty strings), which cannot be answered.
function lights:hello(rid)
	if type(rid) ~= "string" or rid == "" then
		return false
	end
	return self:push(rid, "hello", true)
end

-- Import ---------------------------------------------------------------------

-- Run the import flow from the Import Lights action. report(text) receives
-- the Lights property texts. Returns false when an import is already running.
function lights:import(report)
	report = report or function() end
	if self.importing then
		report("Import already running")
		return false
	end
	self.importing = true

	local function fail(text)
		self.importing = false
		report(text)
	end

	report("Importing: fetching lights")
	self:fetch_all(function(res, err)
		if not res then
			return fail("Import failed: " .. tostring(err))
		end
		local ok, e = pcall(self.import_fetched, self, res, report)
		if not ok then
			self.ctx.log.error("lights: import failed: %s", tostring(e))
			fail("Import failed: " .. tostring(e))
		end
	end)
	return true
end

-- The part of the import that runs once the three GETs are in.
function lights:import_fetched(res, report)
	self:absorb(res)

	-- Already registered: configure and state again (fixes a light that lost
	-- its persisted rid). Then the new ones, one AddDevice at a time.
	for _, rid in ipairs(self:registered_rids()) do
		self:push(rid, "resync", true)
	end

	local pending = {}
	for rid, model in pairs(self.models) do
		if not self.registry[rid] then
			pending[#pending + 1] = model
		end
	end
	table.sort(pending, by_name)

	local total, created, i = #pending, 0, 0

	local function finish()
		self.importing = false
		report(string.format("%d lights on bridge, %d imported, %d new", self:bridge_count(), self:count(), created))
	end

	local add_next

	local function on_added(model, device_id, info)
		if not self.device_info_logged then
			self.device_info_logged = true
			self.ctx.log.always("AddDevice callback for %s: deviceId=%s info=%s",
				tostring(model.name), tostring(device_id), lights.dump(info))
		end
		device_id = tonumber(device_id)
		if not device_id or device_id <= 0 then
			self.ctx.log.error("lights: AddDevice failed for %s (deviceId %s); skipped",
				tostring(model.name), tostring(device_id))
			return
		end
		local ids = lights.ids_from(info)
		if ids.protocol and ids.protocol ~= device_id then
			self.ctx.log.always("AddDevice for %s: binding protocol id %d rather than deviceId %d",
				tostring(model.name), ids.protocol, device_id)
			device_id = ids.protocol
		end
		self.ctx.bind(self:bridge_id(), device_id)
		self.registry[model.rid] = {
			device_id = device_id,
			proxy_id = ids.proxy,
			name = model.name,
			model = self.devices[model.device_rid] and self.devices[model.device_rid].model or nil,
			caps = hue_model.caps(model),
		}
		self:save()
		created = created + 1
		report(string.format("Importing: added %s (%d of %d)", tostring(model.name), i, total))
		self:push(model.rid, "resync", true)
	end

	-- Each step is its own pcall so an error stops the import cleanly, with
	-- the guard cleared and the failure in the property.
	local function step()
		local ok, err = pcall(add_next)
		if not ok then
			self.importing = false
			self.ctx.log.error("lights: import failed: %s", tostring(err))
			report("Import failed: " .. tostring(err))
		end
	end

	add_next = function()
		i = i + 1
		local model = pending[i]
		if not model then
			return finish()
		end
		self.ctx.log.info("lights: adding %s (%d of %d)", tostring(model.name), i, total)
		self.ctx.add_device(lights.LIGHT_DRIVER, self:room_id(), model.name, function(device_id, info)
			self:protect("register " .. tostring(model.name), on_added, model, device_id, info)
			-- The next AddDevice only from this callback, so Director adds one
			-- driver at a time.
			step()
		end)
	end

	step()
end

-- Resync ---------------------------------------------------------------------

-- After every stream connect: the three GETs, then full HUE_STATE (reason
-- "resync") to every registered light, with HUE_CONFIGURE first the first
-- time. done(ok, err, sent). A resync requested while one is running is run
-- once more after it (the latest done wins).
function lights:resync(done)
	done = done or function() end
	if self.resyncing then
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
				local configure = not self.configured_once
				for _, rid in ipairs(self:registered_rids()) do
					if self:push(rid, "resync", configure) then
						sent = sent + 1
					end
				end
				self.configured_once = true
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
		local pending = self.resync_pending
		self.resync_pending = nil
		if pending then
			self:resync(pending)
		end
	end)
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

-- One event-stream container. Returns the number of messages sent. Runs
-- inside OnBodyChunk: no transfers are started here. A Hue rename in an
-- event refreshes the registry's cached name at once (a name is not a state
-- field, so nothing is sent for it), rather than at the next resync.
function lights:on_container(container)
	local sent = 0
	local dirty = false
	if type(container) ~= "table" or type(container.data) ~= "table" then
		return 0
	end
	for _, item in ipairs(container.data) do
		if type(item) == "table" and item.type == "light" then
			local entry, model = self.registry[item.id], self.models[item.id]
			if container.type == "add" then
				self.ctx.log.info("lights: new light %s on the bridge; run Import Lights to add it",
					tostring(type(item.metadata) == "table" and item.metadata.name or item.id))
			elseif container.type == "delete" then
				if entry then
					self.ctx.log.warn("lights: %s (device %s) was deleted on the bridge",
						tostring(entry.name), tostring(entry.device_id))
				end
			elseif entry and model then
				local changed = hue_model.update(model, item)
				if has_field(changed, "name") and self:take_name(entry, model) then
					dirty = true
				end
				local params = hue_model.state_params(model, changed, "event")
				if hue_model.has_state(params) then
					self.ctx.send(entry.device_id, "HUE_STATE", params)
					sent = sent + 1
				end
			end
		elseif type(item) == "table" and item.type == "zigbee_connectivity" then
			local conn = hue_model.connectivity(item)
			local device = self.devices[conn.device_rid]
			for _, rid in ipairs(device and device.light_rids or {}) do
				local entry, model = self.registry[rid], self.models[rid]
				if entry and model then
					model.online = conn.online
					self.ctx.send(entry.device_id, "HUE_STATE", hue_model.state_params(model, { "online" }, "event"))
					sent = sent + 1
				end
			end
		end
	end
	if dirty then
		self:save()
	end
	return sent
end

return lights
