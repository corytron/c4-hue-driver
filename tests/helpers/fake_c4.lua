-- Minimal stand-in for the DriverWorks runtime. Implements only the C4 calls
-- the drivers actually make, and records them so specs can assert on them.
-- Add a method here when a driver starts using a new documented API.
--
-- The project model
-- -----------------
-- fake.project is one Control4 project shared by every runtime of a harness
-- run (several drivers loaded, then fake.pair):
--
--   fake.project.rooms[id]   = { name, floor_id, floor_name }
--   fake.project.devices[id] = { name, room_id, c4i, driver_name, proxy_id, proxy_binding }  -- a protocol driver
--                            | { name, room_id, c4i, driver_name, protocol_id }              -- its proxy device
--
-- `name` is the Composer display name; `driver_name` the driver's <name>,
-- which is what GetBoundConsumerDevices reports. Shapes of the lookups
-- (numeric roomId, nested GetProjectHierarchy with numeric types, no proxies
-- key for the bridge) follow the OS 3.4.2 hardware notes in the comments.
--
-- Reset rule: fake.install_c4 and fake.load_driver start a fresh project
-- (they already start fresh driver modules and routes) holding the default
-- room 7 "Living Room" on floor 3 "Main" and the new runtime's own device
-- (id C4:GetDeviceID(), room 7, name and proxy from src/<driver>/driver.xml).
-- fake.pair registers both drivers too, so load every driver first, then add
-- rooms or move devices, then pair. fake.reset_project() from a spec goes
-- back to the default room plus the loaded drivers' own devices.
--
-- C4:AddDevice registers the new device and, when the driver's xml declares
-- a <proxy>, its proxy device (ids 3001, 3002, ...; the callback still gets
-- (id, {}) as the specs expect). The protocol <-> proxy binding is implied
-- by the project rather than listed in c4.bindings (which specs count), and
-- GetBoundConsumerDevices(protocolId, 5001) answers from it [verified:
-- hardware, docs/edge-cases-control4.md section 0].
--
-- C4:Bind and C4:Unbind deliver OnBindingChanged(binding, class, bound,
-- otherId, otherBinding) to both drivers when both ends of the binding are
-- loaded drivers (after fake.pair), provider first; otherwise nothing fires
-- and the spec calls OnBindingChanged itself, as single-driver specs do.
-- fake.pair's own Bind runs before the pair is routed and stays silent, like
-- a binding that already existed at project load.
--
-- fake.delete_device(id) is Composer's Delete: the driver's
-- OnDriverRemovedFromProject(), then OnDriverDestroyed("DIT_LOADED") with
-- its timers killed [verified: API 22/_26, 22/_24], its queued SendToDevice
-- messages delivered, then every binding of the device removed with
-- OnBindingChanged(..., false, ...) to the other side [assumed: that Director
-- notifies on delete], then the device and its proxy leave the project.

local json = require("dkjson")

local fake = {}

-- Project constants: the location ids and names of the default tree
-- [assumed]; the location types GetProjectHierarchy reports are the
-- controller's numbers [verified: hardware OS 3.4.2].
local SITE_ID, SITE_NAME = 1, "Home"
local BUILDING_ID, BUILDING_NAME = 2, "House"
local DEFAULT_FLOOR_ID, DEFAULT_FLOOR_NAME = 3, "Main"
local DEFAULT_ROOM_ID, DEFAULT_ROOM_NAME = 7, "Living Room"
local FIRST_PROXY_ID = 3001
local ROOM_C4I = "roomdevice.c4i"   -- [verified: common lib lib.lua HideProxyInAllRooms; hardware]
fake.location_types = { site = 2, building = 3, floor = 4, room = 8 }

-- Driver xml, read once per driver directory under src/; nil when absent.
local xml_cache = {}
local function driver_xml(driver)
	if xml_cache[driver] == nil then
		local file = io.open("src/" .. driver .. "/driver.xml")
		xml_cache[driver] = file and file:read("*a") or false
		if file then file:close() end
	end
	return xml_cache[driver] or nil
end

-- What Composer would take from a driver file: its display name and the
-- proxy it declares, if any. Unknown drivers get their base name, no proxy.
local function driver_info(file)
	local base = tostring(file):gsub("%.c4[iz]$", "")
	local xml = driver_xml(base)
	if not xml then
		return { name = base }
	end
	-- "<proxy>" or "<proxy attr=...>", never the enclosing "<proxies>". A
	-- combo driver's proxy names the driver itself (hue_bridge) and is no
	-- separate device: the bridge lists without a proxies key [verified: hardware].
	local proxy = xml:match("<proxy>(.-)</proxy>") or xml:match("<proxy%s[^>]*>(.-)</proxy>")
	if proxy == base then proxy = nil end
	return {
		name = xml:match("<name>(.-)</name>") or base,
		proxy = proxy and (proxy .. ".c4i") or nil,
		proxy_binding = tonumber(xml:match('<proxy%s[^>]*proxybindingid="(%d+)"')) or 5001,
	}
end

-- A device and its proxy share the Composer name AddDevice gave them, and
-- both remember the driver's <name> (driver_name), which is what
-- GetBoundConsumerDevices reports [verified: hardware].
local function add_device_entry(id, file, name, room_id)
	local info = driver_info(file)
	local rec = { name = name or info.name, room_id = room_id, c4i = file, driver_name = info.name }
	fake.project.devices[id] = rec
	if info.proxy then
		local pid = fake.project.next_proxy_id
		fake.project.next_proxy_id = pid + 1
		rec.proxy_id, rec.proxy_binding = pid, info.proxy_binding
		fake.project.devices[pid] = { name = rec.name, room_id = room_id, c4i = info.proxy, protocol_id = id,
			driver_name = info.name }
	end
	return rec
end

-- The protocol device behind an id that may name its proxy.
local function protocol_id_of(id)
	local rec = fake.project.devices[id]
	return rec and rec.protocol_id or id
end

local function remove_device_entry(id)
	id = protocol_id_of(id)
	local rec = fake.project.devices[id]
	if not rec then return nil end
	fake.project.devices[id] = nil
	if rec.proxy_id then fake.project.devices[rec.proxy_id] = nil end
	return rec, id
end

-- The name the bound-device lookups report: the driver's <name>, not the
-- Composer display name [verified: hardware]; "Device N" when unknown.
local function bound_name(id)
	local rec = fake.project.devices[id]
	return rec and rec.driver_name or ("Device " .. tostring(id))
end

-- "22,34,56" (the documented filter shape [verified: API 22/_9]) -> set.
-- A table raises, as on the controller [verified: hardware].
local function csv_set(value, what, numeric)
	assert(type(value) ~= "table", what .. " should be a string")
	local set = {}
	for item in tostring(value):gmatch("[^,%s]+") do
		set[numeric and tonumber(item) or item] = true
	end
	return set
end

-- A C4LuaUrl look-alike: records the request, and lets a spec drive the
-- response through respond_headers()/chunk()/done(), or respond() for the
-- common one-shot case.
local function new_transfer(c4)
	local t = {
		options = {},
		callbacks = {},
		cancelled = false,
		started = false,
	}

	local function setter(name)
		return function(self, fn)
			self.callbacks[name] = fn
			return self
		end
	end
	t.OnDone = setter("done")
	t.OnHeaders = setter("headers")
	t.OnBody = setter("body")
	t.OnBodyChunk = setter("chunk")

	function t:SetOption(name, value)
		self.options[name] = value
		return self
	end

	function t:SetOptions(opts)
		for k, v in pairs(opts) do
			self.options[k] = v
		end
		return self
	end

	local function start(self, method, url, data, headers)
		assert(not self.started, "transfer already started")
		self.started = true
		self.method, self.url, self.data, self.headers = method, url, data, headers or {}
		table.insert(c4.transfers, self)
		return self
	end
	function t:Get(url, headers) return start(self, "GET", url, nil, headers) end
	function t:Post(url, data, headers) return start(self, "POST", url, data, headers) end
	function t:Put(url, data, headers) return start(self, "PUT", url, data, headers) end
	function t:Delete(url, headers) return start(self, "DELETE", url, nil, headers) end
	function t:Custom(url, method, data, headers) return start(self, method, url, data, headers) end

	function t:Cancel()
		self.cancelled = true
		return self
	end

	function t:TicketId()
		return self.started and 1 or 0
	end

	-- Spec-side drivers of the response.
	t.responses = {}

	function t:respond_headers(code, headers)
		local response = { code = code, headers = headers or {} }
		table.insert(self.responses, response)
		if self.callbacks.headers then
			local abort = self.callbacks.headers(self, response)
			if abort then self.cancelled = true end
		end
		return response
	end

	function t:chunk(data)
		assert(#self.responses > 0, "respond_headers() before chunk()")
		if self.callbacks.chunk and not self.cancelled then
			local abort = self.callbacks.chunk(self, self.responses[#self.responses], data)
			if abort then self.cancelled = true end
		end
	end

	function t:done(err_code, err_msg)
		if self.callbacks.done then
			self.callbacks.done(self, self.responses, err_code or 0, err_msg)
		end
	end

	-- Complete the transfer with one response. Mirrors the controller: with no
	-- OnBodyChunk callback the body is aggregated into response.body.
	function t:respond(code, body, headers)
		local response = self:respond_headers(code, headers)
		if self.callbacks.chunk then
			self:chunk(body or "")
		else
			response.body = body or ""
			if self.callbacks.body then
				self.callbacks.body(self, response)
			end
		end
		self:done(0, nil)
	end

	return t
end

-- The loaded runtimes of this harness run (fake.load_driver / install_c4
-- start a new list, fake.pair adds both drivers), and lookups over them.
local envs = {}

local function add_env(env)
	for _, e in ipairs(envs) do
		if e == env then return end
	end
	table.insert(envs, env)
end

-- The loaded driver whose device id this is, or nil (deleted drivers never match).
local function env_for(id)
	for _, env in ipairs(envs) do
		if env.C4.device_id == id and not env.C4.removed then return env end
	end
	return nil
end

-- Forward declared: runs fn with env's globals in place (defined below).
local as

local function deliver_binding_changed(env, binding, class, bound, other_id, other_binding)
	if env and type(env.OnBindingChanged) == "function" then
		as(env, env.OnBindingChanged, binding, class, bound, other_id, other_binding)
	end
end

-- Both sides hear about a binding only when both are loaded drivers.
local function notify_binding(b, bound)
	local provider, consumer = env_for(b.provider), env_for(b.consumer)
	if not (provider and consumer) then return end
	deliver_binding_changed(provider, b.provider_binding, b.class, bound, b.consumer, b.consumer_binding)
	deliver_binding_changed(consumer, b.consumer_binding, b.class, bound, b.provider, b.provider_binding)
end

local function new_c4(env)
	local c4 = {
		calls = {},
		config_info = { version = "1" },
		transfers = {},
		timers = {},
		persist = {},
	}

	local function record(name, ...)
		table.insert(c4.calls, { name = name, args = { ... } })
	end

	function c4:UpdateProperty(name, value)
		record("UpdateProperty", name, value)
		env.Properties[name] = value
	end

	function c4:GetDriverConfigInfo(tag)
		record("GetDriverConfigInfo", tag)
		return c4.config_info[tag]
	end

	function c4:SendToProxy(binding, command, params)
		record("SendToProxy", binding, command, params)
	end

	function c4:url()
		return new_transfer(c4)
	end

	function c4:SetTimer(delay_ms, callback, repeating)
		assert(delay_ms > 0, "timer delay must be > 0")
		local timer = { delay = delay_ms, callback = callback, repeating = repeating or false, active = true }
		function timer:Cancel()
			self.active = false
		end
		table.insert(c4.timers, timer)
		record("SetTimer", delay_ms, repeating or false)
		return timer
	end

	function c4:PersistSetValue(name, value, encrypted)
		record("PersistSetValue", name, value, encrypted or false)
		c4.persist[name] = value
	end

	function c4:PersistGetValue(name, encrypted)
		record("PersistGetValue", name, encrypted or false)
		return c4.persist[name]
	end

	function c4:PersistDeleteValue(name)
		record("PersistDeleteValue", name)
		c4.persist[name] = nil
	end

	-- File API: one name -> contents table per alias directory, with the
	-- File API's current directory selectable through FileSetDir, as on the
	-- controller. c4.files is the SANDBOX directory for convenience. Handles
	-- mirror the controller: FileOpen positions at end-of-file.
	c4.sandbox_dir = "/control4/drivers/lua/sandbox/15"
	c4.dirs = { SANDBOX = {}, C4Z = {} }
	c4.files = c4.dirs.SANDBOX
	c4.cwd = "SANDBOX"
	c4.handles = {}

	local function cwd() return c4.dirs[c4.cwd] end

	-- Millisecond clock; specs advance c4.now_ms to simulate elapsed time.
	c4.now_ms = 1000000
	function c4:GetTime() return c4.now_ms end

	c4.driver_file = "hue_bridge.c4z"   -- fake.load_driver sets the real one
	function c4:GetSandboxDir() return c4.sandbox_dir end
	function c4:GetC4zDir() return "/opt/control4/var/drivers/c4z" end
	function c4:GetDriverFileName() return c4.driver_file end

	-- Devices, bindings and inter-driver messages. Bindings live in a table
	-- that fake.pair() shares between two loaded drivers; SendToDevice queues
	-- into an outbox that fake.pump() delivers (Director delivers
	-- asynchronously too).
	c4.device_id = 15
	c4.room_id = 7      -- the room this driver is registered in when the project does not say
	c4.next_device_id = 2001
	c4.added = {}       -- { id, driver, room, name } per AddDevice
	c4.bindings = {}    -- { provider, provider_binding, consumer, consumer_binding, class }
	c4.sent = {}        -- every SendToDevice { id, command, params }
	c4.outbox = {}      -- not yet delivered by fake.pump()
	c4.renamed = {}     -- every RenameDevice { id, name }

	function c4:GetDeviceID() return c4.device_id end

	-- The room containing this driver [verified: API 22/_33].
	function c4:RoomGetId()
		local rec = fake.project.devices[c4.device_id]
		return rec and rec.room_id or c4.room_id
	end

	-- C4:AddDevice(driver [, room [, name]], callback) [verified: API 9/_0.1];
	-- the callback gets the new device id at once (Director calls it later;
	-- specs see no difference). The room defaults to the caller's and must
	-- exist in the project; the device and its proxy are registered there.
	function c4:AddDevice(driver, a, b, cb)
		local room, name, callback
		if type(a) == "function" then
			callback = a
		elseif type(b) == "function" then
			room, callback = a, b
		else
			room, name, callback = a, b, cb
		end
		local room_id = room or c4:RoomGetId()
		assert(fake.project.rooms[room_id],
			"C4:AddDevice: unknown room " .. tostring(room_id) .. "; fake.add_room() it first")
		local id = c4.next_device_id
		c4.next_device_id = id + 1
		table.insert(c4.added, { id = id, driver = driver, room = room, name = name })
		record("AddDevice", driver, room, name)
		remove_device_entry(id)
		add_device_entry(id, driver, name, room_id)
		callback(id, {})
	end

	-- [verified: API 9/_1]; OnBindingChanged(true) to both sides when both are loaded drivers.
	function c4:Bind(provider, provider_binding, consumer, consumer_binding, class)
		record("Bind", provider, provider_binding, consumer, consumer_binding, class)
		local b = { provider = provider, provider_binding = provider_binding,
			consumer = consumer, consumer_binding = consumer_binding, class = class }
		table.insert(c4.bindings, b)
		notify_binding(b, true)
	end

	-- [verified: API 9/_19]; the mirror of Bind: removes the consumer's binding
	-- and delivers OnBindingChanged(false) to both sides when both are loaded.
	function c4:Unbind(consumer, consumer_binding)
		record("Unbind", consumer, consumer_binding)
		local removed = {}
		for i = #c4.bindings, 1, -1 do
			local b = c4.bindings[i]
			if b.consumer == consumer and b.consumer_binding == consumer_binding then
				table.remove(c4.bindings, i)
				table.insert(removed, 1, b)
			end
		end
		for _, b in ipairs(removed) do
			notify_binding(b, false)
		end
	end

	-- Returns deviceId -> driver <name>, or nil when nothing is bound
	-- [verified: API 32/_3; hardware for the name]. A protocol driver's proxy
	-- binding answers from the project.
	function c4:GetBoundConsumerDevices(device, binding)
		local out, any = {}, false
		for _, b in ipairs(c4.bindings) do
			if b.provider == device and b.provider_binding == binding then
				out[b.consumer] = bound_name(b.consumer)
				any = true
			end
		end
		local rec = fake.project.devices[device]
		if rec and rec.proxy_id and binding == rec.proxy_binding then
			out[rec.proxy_id] = bound_name(rec.proxy_id)
			any = true
		end
		return any and out or nil
	end

	-- [verified: API 32/_4]; a proxy's protocol driver answers from the
	-- project [assumed: the binding reads the same way from the proxy side].
	function c4:GetBoundProviderDevice(device, binding)
		for _, b in ipairs(c4.bindings) do
			if b.consumer == device and b.consumer_binding == binding then
				return b.provider
			end
		end
		local rec = fake.project.devices[device]
		if rec and rec.protocol_id then
			local protocol = fake.project.devices[rec.protocol_id]
			if protocol and binding == protocol.proxy_binding then
				return rec.protocol_id
			end
		end
		return nil
	end

	-- [verified: API 22/_32]; renames just the id named (a proxy rename leaves
	-- the protocol driver's own name alone [assumed]).
	function c4:RenameDevice(id, name)
		record("RenameDevice", id, name)
		table.insert(c4.renamed, { id = id, name = name })
		local rec = fake.project.devices[id]
		if rec then rec.name = name end
	end

	-- The Composer name of a device (protocol or proxy id), this one when no
	-- id is given [verified: API 32/_6; hardware]; nil for an unknown id [assumed].
	function c4:GetDeviceDisplayName(id)
		record("GetDeviceDisplayName", id)
		local rec = fake.project.devices[id or c4.device_id]
		return rec and rec.name or nil
	end

	-- The GetDevices entry for a device [verified: API 22/_9 examples 1-3;
	-- hardware: roomId is a number and a driver without proxies has no
	-- proxies key]. Rooms are devices of roomdevice.c4i [assumed].
	local function device_info(rec)
		local room = fake.project.rooms[rec.room_id]
		local out = { deviceName = rec.name, roomId = rec.room_id, roomName = room and room.name or "",
			driverFileName = rec.c4i }
		if rec.proxy_id then
			local proxy = fake.project.devices[rec.proxy_id]
			out.proxies = { [rec.proxy_id] = { driverFileName = proxy.c4i, deviceName = proxy.name } }
		end
		if rec.protocol_id then
			local protocol = fake.project.devices[rec.protocol_id]
			out.protocol = { [rec.protocol_id] = { driverFileName = protocol.c4i, deviceName = protocol.name } }
		end
		return out
	end

	local function room_info(id, room)
		return { deviceName = room.name, roomId = id, roomName = room.name, driverFileName = ROOM_C4I }
	end

	-- A location filter names rooms, floors, the building or the site.
	local function in_locations(room_id, locations)
		local room = fake.project.rooms[room_id]
		return locations[room_id] or (room and locations[room.floor_id]) or locations[BUILDING_ID] or locations[SITE_ID]
			or false
	end

	-- C4:GetDevices(tFilter, locationFilter) [verified: API 22/_9; hardware]:
	-- tFilter is nil, {}, { DeviceIds = "22,34" } (proxy or device ids) or
	-- { C4iNames = "a.c4i,b.c4z" }; locationFilter a comma list of location ids.
	function c4:GetDevices(filter, location_filter)
		record("GetDevices", filter, location_filter)
		assert(filter == nil or type(filter) == "table", "C4:GetDevices: tFilter should be a table")
		local ids, names
		for key, value in pairs(filter or {}) do
			if key == "DeviceIds" then
				ids = csv_set(value, "DeviceIds", true)
			elseif key == "C4iNames" then
				names = csv_set(value, "C4iNames")
			else
				error("C4:GetDevices: unknown filter key " .. tostring(key) .. " (DeviceIds or C4iNames) [API 22/_9]")
			end
		end
		local locations = location_filter and csv_set(location_filter, "locationFilter", true)
		local function wanted(id, c4i, room_id)
			if ids and not ids[id] then return false end
			if names and not names[c4i] then return false end
			if locations and not in_locations(room_id, locations) then return false end
			return true
		end
		local out = {}
		for id, rec in pairs(fake.project.devices) do
			if wanted(id, rec.c4i, rec.room_id) then out[id] = device_info(rec) end
		end
		for id, room in pairs(fake.project.rooms) do
			if wanted(id, ROOM_C4I, id) then out[id] = room_info(id, room) end
		end
		return out
	end

	-- id -> name of the devices using that driver file [verified: API 25/_4
	-- documents "a table of device ids"; the common lib reads it as id -> name
	-- and lists rooms with "roomdevice.c4i", as the hardware does]. Empty
	-- table when none [assumed].
	function c4:GetDevicesByC4iName(c4i)
		record("GetDevicesByC4iName", c4i)
		local out = {}
		if c4i == ROOM_C4I then
			for id, room in pairs(fake.project.rooms) do out[id] = room.name end
		else
			for id, rec in pairs(fake.project.devices) do
				if rec.c4i == c4i then out[id] = rec.name end
			end
		end
		return out
	end

	-- The project tree, nested: { [siteId] = { name, type = 2, [buildingId] =
	-- { name, type = 3, [floorId] = { name, type = 4, [roomId] = { name,
	-- type = 8 } } } } }; children are the numeric keys of a node and rooms
	-- have none [verified: hardware OS 3.4.2; API 22/_15]. With `location`,
	-- that node under its own id [assumed from the doc's "including itself"].
	function c4:GetProjectHierarchy(location)
		record("GetProjectHierarchy", location)
		local types = fake.location_types
		local nodes = {}   -- id -> node, for the location lookup
		local site = { name = SITE_NAME, type = types.site }
		local building = { name = BUILDING_NAME, type = types.building }
		site[BUILDING_ID] = building
		nodes[SITE_ID], nodes[BUILDING_ID] = site, building
		for id, room in pairs(fake.project.rooms) do
			local floor = nodes[room.floor_id]
			if not floor then
				floor = { name = room.floor_name, type = types.floor }
				nodes[room.floor_id] = floor
				building[room.floor_id] = floor
			end
			local node = { name = room.name, type = types.room }
			nodes[id] = node
			floor[id] = node
		end
		if location == nil then return { [SITE_ID] = site } end
		local id = tonumber(location)
		return nodes[id] and { [id] = nodes[id] } or {}
	end

	function c4:SendToDevice(id, command, params)
		record("SendToDevice", id, command, params)
		local message = { id = id, command = command, params = params }
		table.insert(c4.sent, message)
		table.insert(c4.outbox, message)
	end

	-- Colour conversions, approximations of the controller's: Kim et al.
	-- for CCT -> xy (1667-25000 K), McCamy for xy -> CCT. Good to a few
	-- percent, which is what specs should assert.
	function c4:ColorCCTtoXY(k)
		k = math.max(1667, math.min(25000, k))
		local x
		if k <= 4000 then
			x = -0.2661239e9 / k ^ 3 - 0.2343589e6 / k ^ 2 + 0.8776956e3 / k + 0.179910
		else
			x = -3.0258469e9 / k ^ 3 + 2.1070379e6 / k ^ 2 + 0.2226347e3 / k + 0.240390
		end
		local y
		if k <= 2222 then
			y = -1.1063814 * x ^ 3 - 1.34811020 * x ^ 2 + 2.18555832 * x - 0.20219683
		elseif k <= 4000 then
			y = -0.9549476 * x ^ 3 - 1.37418593 * x ^ 2 + 2.09137015 * x - 0.16748867
		else
			y = 3.0817580 * x ^ 3 - 5.87338670 * x ^ 2 + 3.75112997 * x - 0.37001483
		end
		return x, y
	end

	function c4:ColorXYtoCCT(x, y)
		local n = (x - 0.3320) / (0.1858 - y)
		return 449 * n ^ 3 + 3525 * n ^ 2 + 6823.3 * n + 5520.33
	end

	function c4:FileSetDir(alias)
		record("FileSetDir", alias)
		assert(c4.dirs[alias], "unknown path alias " .. tostring(alias))
		c4.cwd = alias
		return true
	end

	function c4:FileExists(name)
		return cwd()[name] ~= nil
	end

	function c4:FileOpen(name)
		record("FileOpen", name)
		local dir = cwd()
		if dir[name] == nil then
			dir[name] = ""
		end
		local fh = #c4.handles + 1
		c4.handles[fh] = { dir = dir, name = name, pos = #dir[name] }
		return fh
	end

	function c4:FileSetPos(fh, pos)
		c4.handles[fh].pos = pos
	end

	function c4:FileGetSize(fh)
		local h = c4.handles[fh]
		return #h.dir[h.name]
	end

	function c4:FileRead(fh, count)
		local h = c4.handles[fh]
		local data = h.dir[h.name]:sub(h.pos + 1, h.pos + count)
		h.pos = h.pos + #data
		return data
	end

	function c4:FileWriteString(fh, text)
		local h = c4.handles[fh]
		h.dir[h.name] = h.dir[h.name] .. text
		h.pos = #h.dir[h.name]
		record("FileWriteString", h.name, #text)
		return #text
	end

	function c4:FileClose(fh)
		c4.handles[fh] = nil
	end

	function c4:FileDelete(name)
		record("FileDelete", name)
		cwd()[name] = nil
	end

	function c4:FileList()
		local names = {}
		for name in pairs(cwd()) do names[#names + 1] = name end
		return names
	end

	function c4:JsonEncode(value)
		return json.encode(value)
	end

	function c4:JsonDecode(text)
		local value, _, err = json.decode(text)
		if err then
			return nil, err
		end
		return value
	end

	-- Every recorded call with the given name, in order.
	function c4.calls_to(name)
		local out = {}
		for _, call in ipairs(c4.calls) do
			if call.name == name then
				table.insert(out, call.args)
			end
		end
		return out
	end

	-- The most recent transfer started, or nil.
	function c4.last_transfer()
		return c4.transfers[#c4.transfers]
	end

	-- Fire every active timer once, as if its delay had elapsed. Non-repeating
	-- timers are retired; repeating ones stay armed.
	function c4.fire_timers()
		local due = {}
		for _, timer in ipairs(c4.timers) do
			if timer.active then table.insert(due, timer) end
		end
		for _, timer in ipairs(due) do
			if not timer.repeating then timer.active = false end
			timer.callback(timer, 0)
		end
		return #due
	end

	function c4.active_timers()
		local out = {}
		for _, timer in ipairs(c4.timers) do
			if timer.active then table.insert(out, timer) end
		end
		return out
	end

	return c4
end

local DRIVER_MODULE_PREFIXES = { "common%.", "bridge%.", "light%." }

-- Drop cached driver modules so each load starts clean. common.log is kept so
-- a spec can silence or capture its sink before loading a driver.
local function forget_driver_modules()
	for name in pairs(package.loaded) do
		for _, prefix in ipairs(DRIVER_MODULE_PREFIXES) do
			if name ~= "common.log" and name:match("^" .. prefix) then
				package.loaded[name] = nil
			end
		end
	end
end

-- Property names and defaults declared in a driver.xml, as Director would
-- present them in Properties.
function fake.declared_properties(driver)
	local xml = assert(driver_xml(driver), "no src/" .. driver .. "/driver.xml")
	local props = {}
	for body in xml:gmatch("<property>(.-)</property>") do
		local name = body:match("<name>(.-)</name>")
		props[name] = body:match("<default>(.-)</default>") or ""
	end
	return props
end

-- Each runtime's own project entry, so a stale one can be moved when
-- fake.pair changes the light's device id. Weak keys: envs come and go.
local self_registered = setmetatable({}, { __mode = "k" })

-- Drop a runtime's own entry when its device id has moved on (fake.pair
-- gave the light its real id) and the entry is still the placeholder.
local function drop_stale_self(env)
	local old = self_registered[env]
	if old and old.id ~= env.C4.device_id and fake.project.devices[old.id] == old.rec then
		remove_device_entry(old.id)
		-- The placeholder's proxy id goes back when it was the last one handed
		-- out, so a light's proxy is 3001 whichever driver loaded first.
		if old.rec.proxy_id and old.rec.proxy_id + 1 == fake.project.next_proxy_id then
			fake.project.next_proxy_id = old.rec.proxy_id
		end
		self_registered[env] = nil
	end
end

-- Register a runtime's own device in the project, unless something (an
-- AddDevice, a spec) already described that id: then that entry is adopted.
local function register_self(env)
	local c4 = env.C4
	drop_stale_self(env)
	local rec = fake.project.devices[c4.device_id]
		or add_device_entry(c4.device_id, c4.driver_file, nil, c4.room_id)
	self_registered[env] = { id = c4.device_id, rec = rec }
	return rec
end

-- Back to the default room and the loaded runtimes' own devices.
function fake.reset_project()
	fake.project = {
		rooms = { [DEFAULT_ROOM_ID] = { name = DEFAULT_ROOM_NAME, floor_id = DEFAULT_FLOOR_ID,
			floor_name = DEFAULT_FLOOR_NAME } },
		devices = {},
		next_proxy_id = FIRST_PROXY_ID,
	}
	for _, env in ipairs(envs) do register_self(env) end
end
fake.reset_project()

-- A new runtime starts a new harness run: a fresh project with the loaded
-- runtimes' own devices.
local function begin_run(env)
	envs = {}
	fake.reset_project()
	add_env(env)
	register_self(env)
end

-- A fake C4 for module-level specs that don't load a whole driver. Also
-- installs it as the global C4 so the module under test can see it.
function fake.install_c4(properties)
	local env = { Properties = properties or {} }
	env.C4 = new_c4(env)
	rawset(_G, "C4", env.C4)
	rawset(_G, "Properties", env.Properties)
	begin_run(env)
	return env.C4, env
end

-- Run `fn` with the globals C4 and Properties pointing at `env`, as they
-- are whenever Director calls into that driver. Needed when a spec holds
-- two loaded drivers: fire a driver's timers or answer its transfers inside
-- fake.as(env, ...), or use the wrapped c4.fire_timers that fake.pair installs.
function fake.as(env, fn, ...)
	local saved_c4, saved_props = rawget(_G, "C4"), rawget(_G, "Properties")
	rawset(_G, "C4", env.C4)
	rawset(_G, "Properties", env.Properties)
	local results = { pcall(fn, ...) }
	rawset(_G, "C4", saved_c4)
	rawset(_G, "Properties", saved_props)
	if not results[1] then
		error(results[2], 0)
	end
	return select(2, unpack(results))
end
as = fake.as

-- Make two loaded drivers see each other: shared bindings, routed
-- SendToDevice, and c4.fire_timers that runs with the right globals. With
-- opts.bind (default true) the light's binding 1 is bound to the bridge's
-- binding 1, class HUE_BRIDGE, as Composer or C4:Bind would. Both drivers'
-- devices are registered in the project (an entry AddDevice made is kept).
function fake.pair(bridge_env, light_env, opts)
	opts = opts or {}
	local b, l = bridge_env.C4, light_env.C4
	l.device_id = opts.light_id or b.next_device_id
	if not opts.light_id then b.next_device_id = b.next_device_id + 1 end
	l.bindings = b.bindings
	if opts.bind ~= false then
		b:Bind(b.device_id, 1, l.device_id, 1, "HUE_BRIDGE")
	end
	-- Placeholders first (the light may have sat on the bridge's id), then both.
	drop_stale_self(bridge_env)
	drop_stale_self(light_env)
	for _, env in ipairs({ bridge_env, light_env }) do
		add_env(env)
		register_self(env)
		if not env.C4.fire_timers_wrapped then
			local orig = env.C4.fire_timers
			env.C4.fire_timers = function() return fake.as(env, orig) end
			env.C4.fire_timers_wrapped = true
		end
	end
	return l.device_id
end

-- Deliver the queued SendToDevice messages of one runtime (fake.pump's loop body).
local function drain_outbox(env)
	local delivered = 0
	local outbox = env.C4.outbox
	while #outbox > 0 do
		local m = table.remove(outbox, 1)
		local target = env_for(m.id)
		if target and type(target.ExecuteCommand) == "function" then
			local params = {}
			for k, v in pairs(m.params or {}) do params[k] = tostring(v) end
			fake.as(target, target.ExecuteCommand, m.command, params)
			delivered = delivered + 1
		end
	end
	return delivered
end

-- Deliver queued SendToDevice messages between paired drivers through the
-- receiver's ExecuteCommand, with every param value stringified as Director
-- hands them over. Repeats until nothing is queued. Returns the count.
function fake.pump()
	local delivered = 0
	local progress = true
	while progress do
		progress = false
		for _, env in ipairs(envs) do
			local n = drain_outbox(env)
			if n > 0 then
				delivered = delivered + n
				progress = true
			end
		end
	end
	return delivered
end

-- Load a driver.lua into a fresh environment, the way Director would.
-- `driver` is "hue_bridge" or "hue_light"; `properties` overrides the
-- defaults from driver.xml; opts.device_id sets C4:GetDeviceID(). Returns
-- the environment (driver globals) and the fake C4.
function fake.load_driver(driver, properties, opts)
	forget_driver_modules()

	local env = setmetatable({}, { __index = _G })
	env.Properties = fake.declared_properties(driver)
	for k, v in pairs(properties or {}) do
		assert(env.Properties[k], "property not declared in driver.xml: " .. k)
		env.Properties[k] = v
	end
	env.C4 = new_c4(env)
	env.C4.driver_file = driver .. ".c4z"
	if opts and opts.device_id then env.C4.device_id = opts.device_id end
	env._G = env
	begin_run(env)

	-- Modules loaded with require() resolve globals through the real _G, so
	-- point C4 and Properties there too, as on the controller.
	rawset(_G, "C4", env.C4)
	rawset(_G, "Properties", env.Properties)

	local chunk = assert(loadfile("src/" .. driver .. "/driver.lua"))
	setfenv(chunk, env)
	chunk()

	return env, env.C4
end

-- Project helpers (what the dealer does in Composer) ------------------------

function fake.add_room(id, name, floor_id, floor_name)
	assert(not fake.project.rooms[id], "fake.add_room: room " .. tostring(id) .. " exists")
	local room = { name = name, floor_id = floor_id or DEFAULT_FLOOR_ID,
		floor_name = floor_name or (floor_id and ("Floor " .. tostring(floor_id))) or DEFAULT_FLOOR_NAME }
	fake.project.rooms[id] = room
	return room
end

function fake.rename_room(id, name)
	local room = assert(fake.project.rooms[id], "fake.rename_room: unknown room " .. tostring(id))
	room.name = name
end

-- Composer asks to move the devices out first; the fake insists on it.
function fake.delete_room(id)
	assert(fake.project.rooms[id], "fake.delete_room: unknown room " .. tostring(id))
	for device_id, rec in pairs(fake.project.devices) do
		assert(rec.room_id ~= id, "fake.delete_room: room " .. tostring(id) .. " still holds device " .. tostring(device_id))
	end
	fake.project.rooms[id] = nil
end

-- Move a device (by its protocol or proxy id) and its other half to a room.
function fake.move_device(id, room_id)
	assert(fake.project.rooms[room_id], "fake.move_device: unknown room " .. tostring(room_id))
	local protocol_id = protocol_id_of(id)
	local rec = assert(fake.project.devices[protocol_id], "fake.move_device: unknown device " .. tostring(id))
	rec.room_id = room_id
	if rec.proxy_id then fake.project.devices[rec.proxy_id].room_id = room_id end
end

-- Delete a device (by its protocol or proxy id) as Composer would; see the
-- file header for the sequence. Returns the removed project entry.
function fake.delete_device(id)
	local protocol_id = protocol_id_of(id)
	local rec = assert(fake.project.devices[protocol_id], "fake.delete_device: unknown device " .. tostring(id))
	local env = env_for(protocol_id)
	if env then
		fake.as(env, function()
			if type(env.OnDriverRemovedFromProject) == "function" then env.OnDriverRemovedFromProject() end
			if type(env.OnDriverDestroyed) == "function" then env.OnDriverDestroyed("DIT_LOADED") end
		end)
		for _, timer in ipairs(env.C4.timers) do timer.active = false end
		drain_outbox(env)
		env.C4.removed = true
	end

	-- Every binding touching the device or its proxy, in every loaded
	-- runtime's table (paired runtimes share one).
	local mine = { [protocol_id] = true }
	if rec.proxy_id then mine[rec.proxy_id] = true end
	local seen = {}
	local tables = {}
	for _, e in ipairs(envs) do
		if not seen[e.C4.bindings] then
			seen[e.C4.bindings] = true
			table.insert(tables, e.C4.bindings)
		end
	end
	for _, bindings in ipairs(tables) do
		for i = #bindings, 1, -1 do
			local b = bindings[i]
			if mine[b.provider] or mine[b.consumer] then
				table.remove(bindings, i)
				if mine[b.provider] then
					deliver_binding_changed(env_for(b.consumer), b.consumer_binding, b.class, false,
						b.provider, b.provider_binding)
				else
					deliver_binding_changed(env_for(b.provider), b.provider_binding, b.class, false,
						b.consumer, b.consumer_binding)
				end
			end
		end
	end

	remove_device_entry(protocol_id)
	return rec
end

-- Call a driver's CUSTOM_SELECT list function (a global of its env) with
-- its globals in place and return what it returns.
function fake.custom_select(env, fn_name, ...)
	local fn = env[fn_name]
	assert(type(fn) == "function", "fake.custom_select: " .. tostring(fn_name) .. " is not a function of that driver")
	return fake.as(env, fn, ...)
end

return fake
