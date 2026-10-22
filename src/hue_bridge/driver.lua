-- Hue Bridge driver: owns the connection to one Hue bridge and serves the
-- Hue Light drivers bound to it: pairing, the event stream (on its own
-- address spelling, see choose_stream_address), the light registry and
-- import, state fan-out to the light drivers, and the coalesced command
-- queue. docs/lights-design.md is the contract with the light driver.

local log = require("common.log")
local dispatch = require("common.dispatch")
local config = require("bridge.config")
local altaddr = require("bridge.altaddr")
local http = require("bridge.http")
local credentials = require("bridge.credentials")
local pinning = require("bridge.pinning")
local conntest = require("bridge.conntest")
local pairing = require("bridge.pairing")
local stream = require("bridge.stream")
local lights_mod = require("bridge.lights")
local commands = require("bridge.commands")

-- Dev builds only (tools/build.sh --dev ships common/devloop.lua): the
-- driver fetches its code from a server on the LAN and reloads itself.
-- See docs/dev-loop.md. Release builds have no such module, so this is nil.
local devloop_ok, devloop = pcall(require, "common.devloop")
if not devloop_ok then
	-- Absent in release builds (expected); anything else is a real error
	-- that must be visible, since the loop is how the controller gets tested.
	if not tostring(devloop):find("not found", 1, true) then
		print("[ERROR] Hue Bridge: dev loop failed to load: " .. tostring(devloop))
	end
	devloop = nil
end

local state = {
	ip = nil,            -- validated Bridge IP Address property
	creds = nil,         -- what pairing produced; loaded from the store at startup
	stream = nil,        -- bridge.stream instance, created in OnDriverLateInit
	stream_ip = nil,     -- spelling of the bridge address the stream uses, see choose_stream_address
	stream_family = nil, -- spellings the stream rotates over (altaddr.stream_family); nil in single-queue mode
	last_stream_ip = nil, -- spelling of the previous stream transfer, so the next one differs
	lights = nil,        -- bridge.lights registry, created in OnDriverLateInit
	scenes = nil,        -- bridge.scenes (docs/scenes-design.md), created in OnDriverLateInit when the module exists
	queue = nil,         -- bridge.commands coalescer, created in OnDriverLateInit
	group_queue = nil,   -- the same for grouped_light (scene OFF)
	late_init_done = false,
}

-- Stream timeout in single-queue mode: commands wait for the stream to
-- end, so it must end often.
local SINGLE_QUEUE_TIMEOUT = 60

-- Persisted spelling of the last stream transfer, so a reloaded driver does
-- not reuse the one its predecessor's abandoned transfer still holds.
local STREAM_SPELLING_KEY = "hue_stream_spelling"

local function prop(name, value)
	C4:UpdateProperty(name, tostring(value == nil and "" or value))
end

local function paired()
	return credentials.paired(state.creds)
end

local function refresh_status()
	if not state.ip then
		prop("Status", "Enter the bridge IP address")
	elseif not paired() then
		prop("Status", "Not paired: press the link button, then run Pair Bridge")
	else
		prop("Status", "Paired")
	end
	prop("Bridge ID", paired() and state.creds.bridge_id or "")
end

-- What the stream needs to connect, or nil when it can't.
local function connection()
	if state.ip and paired() then
		return { ip = state.ip, key = state.creds.key }
	end
	return nil
end

local function number_property(name, default)
	return tonumber(Properties[name]) or default
end

-- True when the stream has its own C4:url queues (padded address spellings
-- that the startup self-check confirmed), so commands never wait for it.
local function dual_queue()
	return state.stream_family ~= nil
end

-- The spelling the next stream transfer uses: the family entry after the one
-- the previous transfer used (in memory, or persisted by the driver instance
-- a reload replaced), wrapping around, so a new transfer never queues behind
-- the abandoned one (docs/design.md, "Stream address rotation"). With
-- `commit` the pick is recorded and persisted as used.
local function next_stream_address(commit)
	local family = state.stream_family
	if not family then
		return state.ip
	end
	local last = state.last_stream_ip or C4:PersistGetValue(STREAM_SPELLING_KEY)
	local index = 0
	for i, spelling in ipairs(family) do
		if spelling == last then
			index = i
		end
	end
	index = index % #family + 1
	local pick = family[index]
	if commit then
		state.last_stream_ip = pick
		C4:PersistSetValue(STREAM_SPELLING_KEY, pick)
		log.debug("stream spelling %s (%d of %d)", pick, index, #family)
	end
	return pick
end

-- The `Stream Address` text in dual-queue mode.
local function stream_address_text(spelling)
	local n = #state.stream_family
	return string.format("%s (own queue, %s; commands use %s)", spelling,
		n > 1 and string.format("rotating over %d spellings", n) or "no second spelling to rotate", state.ip)
end

-- What the stream connects with. The stream calls this for every attempt,
-- so each connection gets the next spelling.
local function stream_connection()
	local conn = connection()
	if conn then
		state.stream_ip = next_stream_address(true)
		conn.stream_ip = state.stream_ip
		if dual_queue() then
			prop("Stream Address", stream_address_text(state.stream_ip))
		end
	end
	return conn
end

local function stream_timeout()
	local configured = number_property("Stream Timeout (s)", stream.DEFAULT_TIMEOUT)
	if dual_queue() then
		return configured
	end
	return math.min(configured, SINGLE_QUEUE_TIMEOUT)
end

-- Authenticated request on the dotted address. The registry and the command
-- queue go through this, so they never learn about addresses or keys.
local function bridge_request(req, callback)
	if not connection() then
		return callback({ ok = false, err = "not paired" })
	end
	req.ip = state.ip
	req.key = state.creds.key
	return http.request(req, callback)
end


-- The project calls (docs/import-design.md §13), wrapped so the modules stay
-- free of C4. Shapes verified on hardware (design.md "Project APIs"):
-- GetDevices wants comma-separated strings; GetBoundConsumerDevices values
-- are driver names, not Composer names.
local project_calls = {
	rooms = function() return C4:GetDevicesByC4iName("roomdevice.c4i") end,
	hierarchy = function() return C4:GetProjectHierarchy() end,
	devices = function(filter) return C4:GetDevices(filter) end,
	bound = function() return C4:GetBoundConsumerDevices(C4:GetDeviceID(), 1) end,
	unbind = function(device_id) C4:Unbind(device_id, 1) end,
	rename = function(proxy_id, name) C4:RenameDevice(proxy_id, name) end,
	display_name = function(id) return C4:GetDeviceDisplayName(id) end,
}

-- "k=v k=v" of a message's params, rid left out, for debug lines.
local function params_text(params)
	local parts = {}
	for k, v in pairs(params or {}) do
		if k ~= "rid" then parts[#parts + 1] = k .. "=" .. tostring(v) end
	end
	table.sort(parts)
	return table.concat(parts, " ")
end

local function new_lights()
	return lights_mod.new({
		http = bridge_request,
		send = function(id, command, params)
			if command == "HUE_STATE" then
				log.debug("HUE_STATE %s -> %d: %s", tostring(params.rid):sub(1, 8), id, params_text(params))
			end
			C4:SendToDevice(id, command, params)
		end,
		bridge_id = C4:GetDeviceID(),
		room_id = C4:RoomGetId(),
		log = log,
		now = os.time,
		project = project_calls,
	})
end

-- The scenes module (docs/scenes-design.md §4) is optional while the feature
-- lands in pieces: without it the driver still loads and the scene actions
-- say so.
local scenes_ok, scenes_mod = pcall(require, "bridge.scenes")
if not scenes_ok then
	log.warn("bridge.scenes not loadable: %s", tostring(scenes_mod))
	scenes_mod = nil
end

local function new_scenes()
	if not scenes_mod then
		return nil
	end
	return scenes_mod.new({
		http = bridge_request,
		send = function(id, command, params)
			log.debug("%s %s -> %d: %s", command, tostring(params and params.rid):sub(1, 8), id, params_text(params))
			C4:SendToDevice(id, command, params)
		end,
		bridge_id = C4:GetDeviceID(),
		log = log,
		now = os.time,
		project = project_calls,
		lights = state.lights,
		-- Scene OFF turns the scene's group off through its own coalescing
		-- queue, so a "room off" reaching several switches sends one PUT.
		group_off = function(grouped_light_rid)
			if state.group_queue then
				state.group_queue:set(grouped_light_rid, { on = false })
			end
		end,
		persist_get = function(name) return C4:PersistGetValue(name) end,
		persist_set = function(name, value) C4:PersistSetValue(name, value) end,
	})
end

-- The owner-facing counts and lists (docs/import-design.md §6). Methods the
-- running lights.lua does not have yet are skipped: the integration lands
-- in pieces and the driver must keep loading in between.
-- The lights' Attention text followed by the scenes' items.
local function attention_text()
	local items = {}
	if state.lights and state.lights.attention then
		local text = state.lights:attention()
		if text and text ~= "" and text ~= "None" then
			items[#items + 1] = text
		end
	end
	if state.scenes and state.scenes.attention_items then
		for _, item in ipairs(state.scenes:attention_items() or {}) do
			items[#items + 1] = item
		end
	end
	return #items > 0 and table.concat(items, "; ") or "None"
end

local function refresh_lights_props()
	if not state.lights then
		return
	end
	prop("Lights", state.lights:summary())
	if state.lights.attention then
		prop("Attention", attention_text())
	end
	if state.lights.room_mappings_text then
		prop("Room Mappings", state.lights:room_mappings_text())
	end
	if state.scenes and state.scenes.summary then
		prop("Scenes", state.scenes:summary())
	end
end

local function new_queue()
	return commands.new({
		send = function(rid, body, done)
			bridge_request({ method = "PUT", path = "/clip/v2/resource/light/" .. rid, body = body }, done)
		end,
	})
end

-- Grouped-light PUTs (scene OFF) have their own queue and bucket: the
-- bridge's group budget is about one request a second [verified: Core
-- Concepts], separate from the lights'.
local function new_group_queue()
	return commands.new({
		send = function(rid, body, done)
			bridge_request({ method = "PUT", path = "/clip/v2/resource/grouped_light/" .. rid, body = body }, done)
		end,
	})
end

local function new_stream()
	return stream.new({
		connection = stream_connection,
		timeout = stream_timeout(),
		watchdog = number_property("Stream Watchdog (s)", stream.DEFAULT_WATCHDOG),
		on_status = function(text) prop("Event Stream", text) end,
		on_connected = function()
			-- Runs from a timer, never inside the stream's callbacks (see
			-- stream.lua); events may have been missed while reconnecting.
			log.info("event stream connected; resyncing %d lights", state.lights:count())
			state.lights:resync(function(ok, err, sent)
				if ok then
					log.info("resync done: %d state messages", tonumber(sent) or 0)
				else
					log.warn("resync failed: %s", tostring(err))
				end
				refresh_lights_props()
				-- The scenes follow the lights: their catalogue GET is the
				-- large one (351 KB on the house bridge) and their groups and
				-- room mappings come from the lights' resync.
				if state.scenes and state.scenes.resync then
					state.scenes:resync(function(sok, serr, ssent)
						if sok then
							log.info("scene resync done: %d state messages", tonumber(ssent) or 0)
						else
							log.warn("scene resync failed: %s", tostring(serr))
						end
						refresh_lights_props()
					end)
				end
			end)
		end,
		on_container = function(container)
			-- Fan-out only sends SendToDevice, which is safe inside a C4:url
			-- callback; nothing here starts a transfer.
			state.lights:on_container(container)
			if state.scenes and state.scenes.on_container then
				state.scenes:on_container(container)
			end
			prop("Events Received", state.stream.stats.containers)
			prop("Last Event", state.stream.stats.last_event)
		end,
	})
end

-- Rebuild the stream with the current properties. It is started again if it
-- was running, or if `force` is set and the driver is paired with an IP.
local function restart_stream(force)
	if not state.stream then
		return
	end
	local was_running = state.stream:running()
	state.stream:stop()
	state.stream = new_stream()
	if (was_running or force) and connection() then
		state.stream:start()
	end
end

-- Decide which spellings of the bridge address the stream uses (docs/design.md,
-- "Two ways to keep commands flowing" and "Stream address rotation"). Director
-- queues C4:url transfers per host text, so zero-padded spellings give the
-- stream its own queues, one per connection, rotating so a reconnect never
-- waits for the transfer it replaced. The self-check uses a spelling no
-- stream ever takes, so it can never queue behind a stream or an abandoned
-- one. Calls back when done; until then the stream must not be started.
local function choose_stream_address(callback)
	local check_ip = altaddr.for_check(state.ip)
	local family = altaddr.stream_family(state.ip)
	local function single(reason)
		state.stream_family = nil
		state.stream_ip = state.ip
		prop("Stream Address", string.format("%s (shared queue with commands: %s; stream timeout capped at %d s)",
			state.ip, reason, SINGLE_QUEUE_TIMEOUT))
		log.warn("stream shares the command queue: %s", reason)
		callback()
	end
	if not family or not check_ip or not paired() then
		return single(paired() and "no octet below 8 to pad" or "not paired")
	end
	http.request({ ip = check_ip, key = state.creds.key, path = "/clip/v2/resource/bridge", timeout = 10 }, function(r)
		if r.ok then
			state.stream_family = family
			state.stream_ip = next_stream_address(false)
			prop("Stream Address", stream_address_text(state.stream_ip))
			log.info("stream will use %s, rotating over %d spelling(s); self-check via %s OK",
				state.stream_ip, #family, check_ip)
			callback()
		else
			single("self-check via " .. check_ip .. " failed: " .. tostring(r.err))
		end
	end)
end

-- Properties ---------------------------------------------------------------

dispatch.properties["Driver_Version"] = function()
	prop("Driver Version", C4:GetDriverConfigInfo("version"))
end

dispatch.properties["Debug_Mode"] = function(value)
	log.set_debug(value == "On")
end

dispatch.properties["Bridge_IP_Address"] = function(value)
	local ip, err = config.parse_ipv4(value)
	if not ip and value ~= "" then
		log.warn("ignoring bridge IP %q: %s", value, err)
	end
	local changed = ip ~= state.ip
	state.ip = ip
	refresh_status()
	if changed and state.late_init_done then
		state.stream_ip = nil
		state.stream_family = nil
		if ip and paired() then
			credentials.save_ip(ip)
			state.creds.ip = ip
			local was_running = state.stream and state.stream:running()
			if state.stream then state.stream:stop() end
			choose_stream_address(function() restart_stream(was_running) end)
		else
			restart_stream()
		end
	end
end

-- host:port of tools/devserver.py; empty disables the loop. Dev builds only.
dispatch.properties["Dev_Server"] = function(value)
	local host = (value or ""):match("^%s*(.-)%s*$")
	if not devloop then
		if host ~= "" then
			log.always("dev loop: module not loaded in this build; Dev Server ignored")
		end
		return
	end
	if host == "" then
		devloop.stop()
	elseif state.late_init_done then
		log.always("dev loop: starting against %s", host)
		devloop.start(host)
	end
end

dispatch.properties["Stream_Timeout_(s)"] = function()
	if state.late_init_done then restart_stream() end
end

dispatch.properties["Stream_Watchdog_(s)"] = function()
	if state.late_init_done then restart_stream() end
end

-- Actions ------------------------------------------------------------------

dispatch.commands["Pair_Bridge"] = function()
	if not state.ip then
		prop("Status", "Enter the bridge IP address first")
		return
	end
	prop("Status", "Pairing: contacting bridge")
	pairing.pair(state.ip, {
		on_probed = function(info)
			prop("Bridge Model", info.model or "")
			prop("Status", string.format("Pairing: found %s %s, requesting key", tostring(info.model), info.bridge_id))
		end,
		on_link_button = function()
			prop("Status", "Press the link button on the bridge, then run Pair Bridge again")
		end,
		on_paired = function(creds)
			-- Use the in-memory result: the store writes on its own thread
			-- and may not return the value yet.
			state.creds = creds
			prop("Bridge Model", creds.model or "")
			refresh_status()
			local stored = credentials.load()
			if stored.key == creds.key and stored.bridge_id == creds.bridge_id then
				log.info("credentials read back from the store immediately")
			else
				log.info("store not yet readable after save (expected): %s", credentials.summary(stored))
			end
			choose_stream_address(function() restart_stream(true) end)
		end,
		on_error = function(message)
			prop("Status", "Pairing failed: " .. message)
		end,
	})
end

-- Optional param Host: an alternative spelling of the bridge address (for
-- example its decimal form) to probe whether Director's per-host transfer
-- queue keys on the host string. Dev use only; the TLS check ignores the
-- host name for the bridge anyway.
dispatch.commands["Test_Connection"] = function(params)
	if not connection() then
		prop("Status", "Not paired")
		return
	end
	local host = state.ip
	if params and params.Host and params.Host ~= "" then
		host = params.Host
		log.always("Test Connection via host %s instead of %s", host, state.ip)
	end
	prop("Status", "Testing: GET /clip/v2/resource/bridge via " .. host)
	local started = os.time()
	http.request({ ip = host, key = state.creds.key, path = "/clip/v2/resource/bridge" }, function(r)
		local secs = os.time() - started
		log.always("Test Connection via %s: %s after %d s", host, r.ok and "OK" or tostring(r.err), secs)
		if not r.ok then
			if r.code == 401 or r.code == 403 then
				prop("Status", "Test failed: key rejected (HTTP " .. r.code .. "). Re-pair with Pair Bridge")
			else
				prop("Status", "Test failed: " .. tostring(r.err))
			end
			return
		end
		-- [assumed] the bridge resource carries bridge_id; used as the
		-- application-layer identity check described in docs/design.md.
		local item = r.json and r.json.data and r.json.data[1] or {}
		local reported = config.normalise_bridge_id(item.bridge_id)
		if reported and reported ~= state.creds.bridge_id then
			prop("Status", string.format("Test failed: bridge reports ID %s, expected %s",
				reported, state.creds.bridge_id))
			return
		end
		prop("Status", string.format("Test OK: HTTP 200 via %s in %d s, bridge %s", host, secs,
			tostring(reported or state.creds.bridge_id)))
	end)
end

-- Dev-only (not in driver.xml, reachable through the dev loop): an arbitrary
-- authenticated request to the bridge. Params: Method (GET/PUT/POST/DELETE),
-- Path (/clip/v2/...), Body (JSON text, optional), Host (address spelling,
-- optional; default the dotted address), Raw ("true" logs the whole body).
-- Logs the status, elapsed time and a summary of the response: ids and
-- names for resource lists, otherwise the first 300 characters of the body.
dispatch.commands["Hue_Request"] = function(params)
	params = params or {}
	if not connection() then
		return log.always("Hue Request: not paired")
	end
	local method = (params.Method or "GET"):upper()
	local path = params.Path or "/clip/v2/resource/bridge"
	local host = (params.Host and params.Host ~= "") and params.Host or state.ip
	local body
	if params.Body and params.Body ~= "" then
		body = C4:JsonDecode(params.Body)
		if body == nil then
			return log.always("Hue Request: Body is not valid JSON")
		end
	end
	local t0 = os.time()
	http.request({ ip = host, key = state.creds.key, method = method, path = path, body = body }, function(r)
		local summary
		local items = r.json and type(r.json.data) == "table" and r.json.data or nil
		if items and #items == 1 and items[1].type == "light" then
			-- A single light: show the fields that matter for state tests.
			local it = items[1]
			summary = string.format("%s on=%s brightness=%s mirek=%s valid=%s xy=%s,%s",
				it.metadata and it.metadata.name or it.id, tostring(it.on and it.on.on),
				tostring(it.dimming and it.dimming.brightness),
				tostring(it.color_temperature and it.color_temperature.mirek),
				tostring(it.color_temperature and it.color_temperature.mirek_valid),
				tostring(it.color and it.color.xy and it.color.xy.x), tostring(it.color and it.color.xy and it.color.xy.y))
		elseif items and #items > 0 and items[1].id then
			local parts = {}
			for i = 1, math.min(#items, 15) do
				local item = items[i]
				local name = item.metadata and item.metadata.name or item.type or "?"
				parts[#parts + 1] = string.format("%s=%s", item.id, tostring(name))
			end
			summary = string.format("%d items: %s", #items, table.concat(parts, "; "))
		else
			summary = tostring(r.body or ""):sub(1, 300)
		end
		log.always("Hue Request %s %s via %s: %s in %d s, %d bytes: %s", method, path, host,
			r.ok and ("HTTP " .. tostring(r.code)) or tostring(r.err), os.time() - t0, #tostring(r.body or ""), summary)
		if params.Raw == "true" and r.body then
			-- The whole body, in pieces a log line can carry: for recording
			-- fixtures of resources the driver does not summarise.
			local text = tostring(r.body)
			local pieces = math.ceil(#text / 800)
			for i = 1, #text, 800 do
				log.always("Hue Request body %d/%d: %s", math.ceil(i / 800), pieces, text:sub(i, i + 799))
			end
		end
	end)
end

-- Dev-only probes for docs/import-design.md §11: what the project APIs
-- return on this controller, and whether misuse errors or stays silent.
local function log_dump(label, value)
	local text = lights_mod.dump(value)
	local pieces = math.ceil(#text / 800)
	for i = 1, #text, 800 do
		log.always("%s %d/%d: %s", label, math.ceil(i / 800), pieces, text:sub(i, i + 799))
	end
end

local function probe(label, fn)
	local ok, result = pcall(fn)
	if ok then
		log_dump(label, result)
	else
		log.always("%s: error %s", label, tostring(result))
	end
end

dispatch.commands["Probe_Project"] = function()
	probe("GetProjectHierarchy", function() return C4:GetProjectHierarchy() end)
	probe("GetDevicesByC4iName roomdevice.c4i", function() return C4:GetDevicesByC4iName("roomdevice.c4i") end)
	probe("GetDevices hue_light.c4z", function()
		local devices = C4:GetDevices({ C4iNames = "hue_light.c4z" })
		local count, first = 0, nil
		for id, info in pairs(devices or {}) do
			count = count + 1
			if not first or tostring(id) < tostring(first.id) then
				first = { id = id, info = info }
			end
		end
		return { count = count, first = first }
	end)
	probe("GetBoundConsumerDevices binding 1", function() return C4:GetBoundConsumerDevices(C4:GetDeviceID(), 1) end)
end

dispatch.commands["Probe_Errors"] = function()
	probe("UpdateProperty Nonexistent", function() return C4:UpdateProperty("Nonexistent", "x") end)
	probe("SendToDevice 99999", function() return C4:SendToDevice(99999, "HUE_STATE", { rid = "probe" }) end)
end

-- Probe Scenes (dev-only, groundwork for the scenes feature): every scene
-- and smart scene on the bridge with its group, status and dynamics.
dispatch.commands["Probe_Scenes"] = function()
	if not connection() then
		return log.always("Probe Scenes: not paired")
	end
	local groups = state.lights and state.lights.groups
	local function str(v)
		if v == nil or type(v) == "table" then return "-" end -- JSON null decodes to {}
		return tostring(v)
	end
	local function label(ref)
		local rid = type(ref) == "table" and ref.rid or nil
		local text = (groups and groups.label) and groups:label(rid) or "?"
		return text .. " " .. tostring(rid or ""):sub(1, 8)
	end
	bridge_request({ method = "GET", path = "/clip/v2/resource/scene" }, function(r)
		local items = r.json and type(r.json.data) == "table" and r.json.data or {}
		log.always("Probe Scenes: %s, %d scenes, %d bytes", r.ok and ("HTTP " .. tostring(r.code)) or tostring(r.err),
			#items, #tostring(r.body or ""))
		local per_group, lines = {}, {}
		for _, s in ipairs(items) do
			local g = label(s.group)
			per_group[g] = (per_group[g] or 0) + 1
			lines[#lines + 1] = string.format("%s %q [%s] %s%s%s", tostring(s.id):sub(1, 8),
				str(s.metadata and s.metadata.name), g, str(type(s.status) == "table" and s.status.active),
				s.auto_dynamic == true and " dynamic" or "", type(s.speed) == "number" and (" speed " .. s.speed) or "")
		end
		table.sort(lines)
		for i = 1, #lines, 3 do
			log.always("  %s", table.concat(lines, " | ", i, math.min(i + 2, #lines)))
		end
		local summary = {}
		for g, n in pairs(per_group) do summary[#summary + 1] = g .. "=" .. n end
		table.sort(summary)
		log.always("  scenes per group: %s", table.concat(summary, "; "))
		bridge_request({ method = "GET", path = "/clip/v2/resource/smart_scene" }, function(r2)
			local smart = r2.json and type(r2.json.data) == "table" and r2.json.data or {}
			log.always("Probe Scenes: %d smart scenes, %d bytes", #smart, #tostring(r2.body or ""))
			for _, s in ipairs(smart) do
				log.always("  %s %q [%s] state=%s slot=%s", tostring(s.id):sub(1, 8), str(s.metadata and s.metadata.name),
					label(s.group), str(s.state), str(type(s.active_timeslot) == "table" and s.active_timeslot.timeslot_id))
			end
		end)
	end)
end

-- Probe Call: any C4 method by name, arguments as a JSON array, result dumped.
-- e.g. Fn=GetDevices Args=[{"DeviceIds":[1080]}]; Fn=GetDeviceDisplayName Args=[1081]
dispatch.commands["Probe_Call"] = function(params)
	params = params or {}
	local fn = tostring(params.Fn or "")
	local args = {}
	if params.Args and params.Args ~= "" then
		args = C4:JsonDecode(params.Args)
		if type(args) ~= "table" then
			return log.always("Probe Call: Args is not a JSON array")
		end
	end
	if type(C4[fn]) ~= "function" then
		return log.always("Probe Call: C4.%s is not a function", fn)
	end
	probe("C4:" .. fn .. "(" .. tostring(params.Args or "") .. ")", function()
		return C4[fn](C4, unpack(args))
	end)
end

-- Owner actions (docs/import-design.md §6): every click writes its result to
-- Last Action and refreshes the counts. The pickers are CUSTOM_SELECT lists
-- built on demand by the global functions below [verified: FUND 12.3].

local function last_action(text)
	text = tostring(text == nil and "" or text)
	log.always("%s", text)
	prop("Last Action", text)
	refresh_lights_props()
end

-- False, with the reason in Last Action, when the action cannot run.
local function can(method)
	if not connection() then
		last_action("Not paired")
		return false
	end
	if not state.lights or type(state.lights[method]) ~= "function" then
		last_action("Not available in this build (" .. method .. ")")
		return false
	end
	return true
end

-- A picker value, or nil for the empty-list entry and a missing param.
local function selection(params, name)
	local value = params and params[name]
	if value == nil or value == "" then
		return nil
	end
	return tostring(value)
end

local function picker(method, ...)
	if state.lights and type(state.lights[method]) == "function" then
		local ok, list = pcall(state.lights[method], state.lights, ...)
		if ok and type(list) == "table" then
			return list
		end
		log.warn("%s: %s", method, tostring(list))
		return { { text = "(error building the list; see Lua output)", value = "" } }
	end
	return { { text = "(not available in this build)", value = "" } }
end

function HueLightList() return picker("picker_lights") end
function RoomList() return picker("picker_rooms", "add") end
function RelinkDeviceList() return picker("picker_relink_devices") end
function ForgetDeviceList() return picker("picker_forget_devices") end
function HueRoomList() return picker("picker_hue_rooms") end
function MappingTargetList() return picker("picker_rooms", "mapping") end

-- Scenes (docs/scenes-design.md §5): the same shapes against state.scenes.
local function can_scene(method)
	if not connection() then
		last_action("Not paired")
		return false
	end
	if not state.scenes or type(state.scenes[method]) ~= "function" then
		last_action("Not available in this build (scenes." .. method .. ")")
		return false
	end
	return true
end

local function scene_picker(method, ...)
	if state.scenes and type(state.scenes[method]) == "function" then
		local ok, list = pcall(state.scenes[method], state.scenes, ...)
		if ok and type(list) == "table" then
			return list
		end
		log.warn("%s: %s", method, tostring(list))
		return { { text = "(error building the list; see Lua output)", value = "" } }
	end
	return { { text = "(not available in this build)", value = "" } }
end

function SceneList() return scene_picker("picker_scenes") end
function SceneGroupList() return scene_picker("picker_groups") end
function RelinkSceneList() return scene_picker("picker_relink_devices") end
function ForgetSceneList() return scene_picker("picker_forget_devices") end

-- The scenes' half of an action both kinds share, or nil without scenes.
local function scene_text(method, ...)
	if state.scenes and type(state.scenes[method]) == "function" then
		return state.scenes[method](state.scenes, ...)
	end
	return nil
end

local function join_texts(lights_text, scenes_text)
	if scenes_text == nil or scenes_text == "" then
		return lights_text
	end
	return tostring(lights_text) .. " | Scenes: " .. tostring(scenes_text)
end

-- A message from a scene device, routed when the module is present.
local function scene_message(method, params)
	if state.scenes and type(state.scenes[method]) == "function" then
		return state.scenes[method](state.scenes, params or {})
	end
	log.warn("%s ignored: scenes not available in this build", method)
end

dispatch.commands["Add_Light"] = function(params)
	if not can("add_light") then return end
	local rid = selection(params, "Light")
	if not rid then
		return last_action("Not added: pick a light first")
	end
	state.lights:add_light(rid, tonumber(selection(params, "Room")), function(_, text) last_action(text) end)
end

dispatch.commands["Import_All_New_Lights"] = function()
	if not connection() then
		return last_action("Not paired")
	end
	if type(state.lights.import_new) == "function" then
		return state.lights:import_new(function(_, text) last_action(text) end)
	end
	-- Until lights.lua's integration lands: the scaffold import (every light
	-- into the bridge's room), reporting through Lights as before.
	state.lights:import(function(text) prop("Lights", text) end)
end
dispatch.commands["Import_Lights"] = dispatch.commands["Import_All_New_Lights"]

dispatch.commands["Re-link_Device_To_Light"] = function(params)
	if not can("relink") then return end
	local device, rid = tonumber(selection(params, "Device")), selection(params, "Light")
	if not device or not rid then
		return last_action("Not re-linked: pick a device and a light")
	end
	local _, text = state.lights:relink(device, rid)
	last_action(text)
end

dispatch.commands["Link_Devices"] = function()
	if can("link_devices") then
		last_action(join_texts(state.lights:link_devices(), scene_text("link_devices")))
	end
end

dispatch.commands["Forget_Light"] = function(params)
	if not can("forget") then return end
	local device = tonumber(selection(params, "Device"))
	if not device then
		return last_action("Not forgotten: pick a device first")
	end
	local _, text = state.lights:forget(device)
	last_action(text)
end

-- Entries created before proxy ids were recorded get theirs from the proxy's
-- binding: the light_v2 proxy is the bound consumer of the protocol driver's
-- binding 5001 [verified: hardware]. Renames need it (Composer shows the proxy).
local function fill_proxy_ids()
	local filled = 0
	for rid, entry in pairs(state.lights.registry) do
		if not entry.proxy_id and entry.device_id then
			local consumers = C4:GetBoundConsumerDevices(entry.device_id, 5001)
			local proxy = type(consumers) == "table" and next(consumers) or nil
			if proxy then
				entry.proxy_id = proxy
				filled = filled + 1
				log.debug("proxy id %s recorded for %s", tostring(proxy), rid:sub(1, 8))
			end
		end
	end
	if filled > 0 and state.lights.save then
		state.lights:save()
	end
	return filled
end

dispatch.commands["Adopt_Hue_Names"] = function()
	if can("adopt_hue_names") then
		fill_proxy_ids()
		last_action(join_texts(state.lights:adopt_hue_names(), scene_text("adopt_hue_names")))
	end
end

dispatch.commands["Accept_Names_As_They_Are"] = function()
	if can("accept_names") then
		last_action(join_texts(state.lights:accept_names(), scene_text("accept_names")))
	end
end

dispatch.commands["Set_Room_Mapping"] = function(params)
	if not can("set_room_mapping") then return end
	local group, target = selection(params, "Hue Room"), selection(params, "Room")
	if not group then
		return last_action("Not mapped: pick a Hue room first")
	end
	local room_id = nil
	if target ~= "none" then
		room_id = tonumber(target)
		if not room_id then
			return last_action("Not mapped: pick a Control4 room or (no mapping)")
		end
	end
	local _, text = state.lights:set_room_mapping(group, room_id)
	last_action(text)
end

dispatch.commands["Map_Rooms_By_Name"] = function()
	if can("map_rooms_by_name") then last_action(state.lights:map_rooms_by_name()) end
end

dispatch.commands["Room_Audit"] = function()
	if can("room_audit") then last_action(state.lights:room_audit()) end
end

-- From a light being deleted in Composer (docs/import-design.md §4).
dispatch.commands["HUE_GOODBYE"] = function(params)
	if state.lights and state.lights.goodbye then
		state.lights:goodbye(params or {})
		refresh_lights_props()
	else
		log.warn("HUE_GOODBYE ignored: not available in this build")
	end
end

-- From a light's Forget This Light action.
dispatch.commands["HUE_FORGET"] = function(params)
	if can("forget_request") then
		local _, text = state.lights:forget_request(params or {})
		last_action(text)
	end
end

-- Scene actions (docs/scenes-design.md §5) ----------------------------------

dispatch.commands["Add_Scene"] = function(params)
	if not can_scene("add_scene") then return end
	local rid = selection(params, "Scene")
	if not rid then
		return last_action("Not added: pick a scene first")
	end
	state.scenes:add_scene(rid, tonumber(selection(params, "Room")), function(_, text) last_action(text) end)
end

dispatch.commands["Add_All_Scenes_Of_Room"] = function(params)
	if not can_scene("add_all_of_group") then return end
	local group = selection(params, "Hue Room")
	if not group then
		return last_action("Not added: pick a Hue room first")
	end
	state.scenes:add_all_of_group(group, function(_, text) last_action(text) end)
end

dispatch.commands["Re-link_Scene"] = function(params)
	if not can_scene("relink") then return end
	local device, rid = tonumber(selection(params, "Device")), selection(params, "Scene")
	if not device or not rid then
		return last_action("Not re-linked: pick a device and a scene")
	end
	local _, text = state.scenes:relink(device, rid)
	last_action(text)
end

dispatch.commands["Forget_Scene"] = function(params)
	if not can_scene("forget") then return end
	local device = tonumber(selection(params, "Device"))
	if not device then
		return last_action("Not forgotten: pick a device first")
	end
	local _, text = state.scenes:forget(device)
	last_action(text)
end

dispatch.commands["Refresh_Scenes"] = function()
	if not can_scene("resync") then return end
	state.scenes:resync(function(ok, err)
		if ok then
			last_action("Scenes refreshed: " .. tostring(state.scenes:summary()))
		else
			last_action("Scene refresh failed: " .. tostring(err))
		end
	end)
end

-- Messages from scene devices (docs/scenes-design.md §2).
dispatch.commands["HUE_SCENE_HELLO"] = function(params)
	params = params or {}
	if not (state.scenes and state.scenes.hello) then
		return log.warn("HUE_SCENE_HELLO ignored: scenes not available in this build")
	end
	-- hello(rid, params): the rid is a separate argument, as for lights.
	if not state.scenes:hello(params.rid or "", params) then
		log.debug("HUE_SCENE_HELLO not answered for %q (device %s)", tostring(params.rid), tostring(params.device_id))
	end
end

dispatch.commands["HUE_SCENE_RECALL"] = function(params)
	scene_message("recall", params)
end

dispatch.commands["HUE_SCENE_OFF"] = function(params)
	scene_message("off", params)
end

dispatch.commands["HUE_SCENE_GOODBYE"] = function(params)
	scene_message("goodbye", params)
	refresh_lights_props()
end

dispatch.commands["HUE_SCENE_FORGET"] = function(params)
	if can_scene("forget_request") then
		local _, text = state.scenes:forget_request(params or {})
		last_action(text)
	end
end

-- From a light driver: a proxy command mapped to Hue fields (strings).
dispatch.commands["HUE_SET"] = function(params)
	params = params or {}
	local rid = params.rid
	if not rid or rid == "" or not state.lights:device_for(rid) then
		log.warn("HUE_SET for unknown light %s", tostring(rid))
		return
	end
	local fields = {
		brightness = tonumber(params.brightness),
		x = tonumber(params.x),
		y = tonumber(params.y),
		mirek = tonumber(params.mirek),
		rate = tonumber(params.rate),
	}
	if params.on == "true" then fields.on = true elseif params.on == "false" then fields.on = false end
	log.info("HUE_SET %s: on=%s brightness=%s x=%s y=%s mirek=%s rate=%s", rid:sub(1, 8), tostring(fields.on),
		tostring(fields.brightness), tostring(fields.x), tostring(fields.y), tostring(fields.mirek), tostring(fields.rate))
	state.queue:limits(rid, state.lights:limits(rid))
	state.queue:set(rid, fields)
end

-- A light driver's own log line (dev builds forward info and above), so it
-- shows up in this driver's output and in the dev loop's shipped log.
dispatch.commands["HUE_LOG"] = function(params)
	params = params or {}
	local who = "light"
	if params.rid and params.rid ~= "" then
		local entry = state.lights and state.lights.registry and state.lights.registry[params.rid]
		who = (entry and entry.name) or params.rid:sub(1, 8)
	end
	log.always("[%s] %s", who, tostring(params.line))
end

-- Find a registered light by rid, Hue name or protocol device id.
local function find_light(key)
	local registry = state.lights and state.lights.registry or {}
	if registry[key] then return key, registry[key] end
	local wanted = tostring(key):lower()
	for rid, entry in pairs(registry) do
		if tostring(entry.device_id) == wanted or (entry.name or ""):lower() == wanted then
			return rid, entry
		end
	end
	return nil
end

-- Dev-only (not in driver.xml): a light_v2 proxy command to one light, the
-- way a Navigator or programming would send it, so the whole command path
-- can be exercised from the dev loop. Params: Light (rid, Hue name or
-- protocol device id), Command (e.g. SET_BRIGHTNESS_TARGET), and the
-- command's own params (e.g. LIGHT_BRIGHTNESS_TARGET=50 RATE=0).
dispatch.commands["Proxy_Command"] = function(params)
	params = params or {}
	local rid, entry = find_light(params.Light or "")
	if not rid then
		return log.always("Proxy Command: no registered light matches %q", tostring(params.Light))
	end
	local proxy = state.lights.proxy_for and state.lights:proxy_for(rid)
	if not proxy then
		-- The protocol driver provides binding 5001 (driver.xml: consumer
		-- False) and its light_v2 proxy consumes it, so the proxy is a bound
		-- consumer of that binding. Seen on hardware: proxy id = protocol id + 1.
		local consumers = C4:GetBoundConsumerDevices(entry.device_id, 5001)
		if type(consumers) == "table" then proxy = next(consumers) end
		if proxy and state.lights.registry[rid] then
			state.lights.registry[rid].proxy_id = proxy
			if state.lights.save then state.lights:save() end
		end
	end
	if not proxy then
		return log.always("Proxy Command: no proxy found for %s (device %s)", entry.name, tostring(entry.device_id))
	end
	local command = params.Command or "SET_BRIGHTNESS_TARGET"
	local forwarded = {}
	for k, v in pairs(params) do
		if k ~= "Light" and k ~= "Command" then forwarded[k] = v end
	end
	C4:SendToDevice(proxy, command, forwarded)
	log.always("Proxy Command: %s -> %s (proxy %s): %s", command, entry.name, tostring(proxy),
		C4:JsonEncode(forwarded))
end

-- Dev-only: a summary of the light registry. Param Limit (default 5).
dispatch.commands["Lights_Report"] = function(params)
	params = params or {}
	local limit = tonumber(params.Limit) or 5
	local registry = state.lights and state.lights.registry or {}
	local names = {}
	for rid, entry in pairs(registry) do names[#names + 1] = { rid = rid, entry = entry } end
	table.sort(names, function(a, b) return (a.entry.name or "") < (b.entry.name or "") end)
	local tombstones = state.lights.reg and state.lights.reg:tombstones() or {}
	local deleted = 0
	for _ in pairs(tombstones) do deleted = deleted + 1 end
	log.always("Lights Report: %d registered, %d deleted in Composer, queue %s", #names, deleted,
		C4:JsonEncode(state.queue:stats()))
	-- The owner-facing texts, for dev builds whose installed driver.xml
	-- predates the properties.
	log.always("  Lights: %s", state.lights:summary())
	if state.lights.attention then log.always("  Attention: %s", state.lights:attention()) end
	if state.lights.room_mappings_text then log.always("  Room Mappings: %s", state.lights:room_mappings_text()) end
	if state.scenes and state.scenes.summary then log.always("  Scenes: %s", state.scenes:summary()) end
	for i = 1, math.min(limit, #names) do
		local e = names[i].entry
		local caps = e.caps or {}
		log.always("  %s: device %s proxy %s rid %s %s id_v1=%s room=%s mac=%s color=%s cct=%s mirek %s-%s",
			tostring(e.name), tostring(e.device_id), tostring(e.proxy_id), names[i].rid, tostring(e.state),
			tostring(e.id_v1), tostring(e.hue_room), tostring(e.mac_address),
			tostring(caps.has_color), tostring(caps.has_cct), tostring(caps.mirek_min), tostring(caps.mirek_max))
	end
	for rid, tomb in pairs(tombstones) do
		log.always("  deleted in Composer: %s rid %s at %s", tostring(tomb.name), rid,
			os.date("%Y-%m-%d %H:%M", tomb.deleted_at))
	end
end

-- From a light driver at its startup or binding: resend its configuration
-- and state.
dispatch.commands["HUE_HELLO"] = function(params)
	params = params or {}
	local rid = params.rid or ""
	if not state.lights:hello(rid, params) then
		log.debug("HUE_HELLO from unregistered light %q (device %s)", tostring(rid), tostring(params.device_id))
	end
end

dispatch.commands["Connect_Event_Stream"] = function()
	if not connection() then
		prop("Event Stream", "Not paired")
		return
	end
	if not state.stream_ip then
		return choose_stream_address(function() restart_stream(true) end)
	end
	state.stream:start()
end

dispatch.commands["Disconnect_Event_Stream"] = function()
	state.stream:stop()
end

-- Shows whether the persisted credentials can be read back, without
-- exposing the key. Compares against what the driver holds in memory.
dispatch.commands["Reload_Credentials"] = function()
	local stored = credentials.load()
	log.always("stored credentials: %s", credentials.summary(stored))
	log.always("in-memory credentials: %s", credentials.summary(state.creds))
	if credentials.paired(stored) then
		local same = state.creds and stored.key == state.creds.key and stored.bridge_id == state.creds.bridge_id
		prop("Status", same and "Stored credentials readable and match memory"
			or "Stored credentials readable but differ from memory; see Lua output")
	elseif paired() then
		prop("Status", "Stored credentials NOT readable although paired in memory; see Lua output")
	else
		prop("Status", "No stored credentials")
	end
end

dispatch.commands["Check_CA_Pinning"] = function()
	prop("Status", "Checking CA pinning against " .. pinning.PUBLIC_HOST)
	pinning.check(http.ca, function(verdict)
		local text = {
			pinned = "Pinning check passed: only Signify-signed certificates are trusted",
			not_pinned = "Pinning check FAILED: public CAs are trusted too; see Lua output",
			inconclusive = "Pinning check inconclusive: " .. pinning.PUBLIC_HOST .. " unreachable",
		}
		prop("Status", text[verdict] or verdict)
	end)
end

-- The connection experiment, see bridge/conntest.lua. The driver's own
-- stream is stopped for the duration so it cannot confound the result.
dispatch.commands["Connection_Test"] = function(params)
	local target
	if params.Target == "Diagnostic Server" then
		local host = (Properties["Diagnostic Server"] or ""):match("^%s*(.-)%s*$")
		if host == "" then
			prop("Status", "Set the Diagnostic Server property first (host:port)")
			return
		end
		target = { name = "diagnostic server", ip = host, stream_path = "/stream", ping_path = "/ping",
			ca = { mode = "insecure" } }
	else
		if not connection() then
			prop("Status", "Not paired")
			return
		end
		target = { name = "bridge", ip = state.ip, key = state.creds.key,
			stream_path = "/eventstream/clip/v2", ping_path = "/clip/v2/resource/bridge",
			headers = { Accept = "text/event-stream" }, ca = http.ca }
	end

	local was_running = state.stream:running()
	state.stream:stop()
	prop("Status", "Connection test against " .. target.name .. " running; see Lua output")
	conntest.run(target, nil, function(summary)
		prop("Status", string.format("Connection test (%s): stream %s, GET with stream open %s, concurrent %s/2, control %s",
			target.name,
			summary.stream_ok and "OK" or "FAIL",
			summary.ping_ok and "OK" or "FAIL",
			tostring(summary.concurrent_ok or 0),
			summary.control_ok and "OK" or "FAIL"))
		if was_running then
			restart_stream(true)
		end
	end)
end

dispatch.commands["Forget_Pairing"] = function()
	state.stream:stop()
	credentials.clear()
	state.creds = nil
	state.stream_ip = nil
	state.stream_family = nil
	prop("Stream Address", "")
	prop("Bridge Model", "")
	prop("Events Received", 0)
	prop("Last Event", "")
	refresh_status()
end

-- Bindings and system events --------------------------------------------------

-- Director reports changes to the HUE_BRIDGE control binding here [verified:
-- API 9/_12]. Logged in full while docs/import-design.md §11 probe 1 is open;
-- the registry reconciliation hooks in here next.
function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceID, otherBindingID)
	log.always("OnBindingChanged(%s, %s, %s, %s, %s)", tostring(idBinding), tostring(strClass), tostring(bIsBound),
		tostring(otherDeviceID), tostring(otherBindingID))
	if state.scenes and state.scenes.on_binding_changed then
		state.scenes:on_binding_changed(idBinding, strClass, bIsBound, otherDeviceID)
	end
	if state.lights and state.lights.on_binding_changed then
		state.lights:on_binding_changed(idBinding, strClass, bIsBound, otherDeviceID)
		refresh_lights_props()
		-- Director settles the binding tables after the callback; the SDK's
		-- own sample re-enumerates a second later [verified: sample idc_controller].
		if state.lights.reconcile then
			C4:SetTimer(1000, function()
				state.lights:reconcile()
				refresh_lights_props()
			end)
		end
	end
end

-- Called before Director adds a binding [verified: API 32/_26]; only the
-- HUE_BRIDGE class belongs here [assumed: returning false rejects].
function OnBindingValidate(idBinding, strClass)
	local ok = strClass == "HUE_BRIDGE"
	log.always("OnBindingValidate(%s, %s) -> %s", tostring(idBinding), tostring(strClass), tostring(ok))
	return ok
end

-- Probe 3: which project events reach a driver when lights and rooms are
-- added, renamed, moved or deleted, and what their data carries. The
-- registration call is documented [verified: API 7/_1, 7/_5.5]; the event
-- names come from Control4's own handlers.lua; the payloads are not
-- documented, hence the raw log.
local PROBE_EVENTS = { "OnItemAdded", "OnItemRemoved", "OnItemNameChanged", "OnItemMoved",
	"OnDeviceUserInitiatedRemove", "OnPIP" }

local function register_probe_events()
	if type(C4SystemEvents) ~= "table" or type(C4.RegisterSystemEvent) ~= "function" then
		return log.debug("system events unavailable in this runtime")
	end
	for _, name in ipairs(PROBE_EVENTS) do
		local id = C4SystemEvents[name]
		if id then
			local ok, err = pcall(C4.RegisterSystemEvent, C4, id, 0)
			if not ok then
				log.warn("RegisterSystemEvent %s: %s", name, tostring(err))
			end
		else
			log.debug("no system event named %s", name)
		end
	end
end

function OnSystemEvent(data)
	log.always("OnSystemEvent: %s", tostring(data):sub(1, 600))
end

-- Lifecycle ----------------------------------------------------------------

log.set_prefix("Hue Bridge")
dispatch.install(_G)

function OnDriverInit()
end

function OnDriverLateInit()
	state.creds = credentials.load()
	log.info("credentials at startup: %s", credentials.summary(state.creds))
	state.lights = new_lights()
	state.lights:load()
	-- Configure every known light from the persisted registry before any
	-- GET: a light that restarted with us gets its capabilities at once.
	state.lights:configure_all()
	state.queue = new_queue()
	state.group_queue = new_group_queue()
	state.scenes = new_scenes()
	if state.scenes then
		state.scenes:load()
		if state.scenes.configure_all then state.scenes:configure_all() end
		if state.scenes.reconcile then state.scenes:reconcile() end
	end
	-- Bindings are complete at late init [verified: FUND 28/_3]: settle which
	-- registered devices are still bound and present (docs/import-design.md §5).
	if state.lights.reconcile then
		local r = state.lights:reconcile()
		log.info("startup reconcile: %d unbound, %d relinked, %d deleted in Composer",
			#(r.unbound or {}), #(r.relinked or {}), #(r.tombstoned or {}))
	end
	fill_proxy_ids()
	refresh_lights_props()
	dispatch.replay_properties(Properties)
	state.stream = new_stream()
	state.late_init_done = true
	register_probe_events()
	refresh_status()
	if connection() then
		choose_stream_address(function() restart_stream(true) end)
	else
		prop("Event Stream", paired() and "Waiting for IP address" or "Not paired")
	end
	-- Started last so a reload pushed through the loop sees a fully
	-- initialised driver; the property handler above only arms it after this.
	if devloop then
		local host = (Properties["Dev Server"] or ""):match("^%s*(.-)%s*$")
		if host ~= "" then
			devloop.start(host)
		end
	end
end

function OnDriverDestroyed()
	if state.stream then
		state.stream:stop()
	end
	if state.queue then
		state.queue:stop()
	end
	if state.group_queue then
		state.group_queue:stop()
	end
end
