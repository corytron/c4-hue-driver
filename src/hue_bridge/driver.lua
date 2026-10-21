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
	lights = nil,        -- bridge.lights registry, created in OnDriverLateInit
	queue = nil,         -- bridge.commands coalescer, created in OnDriverLateInit
	late_init_done = false,
}

-- Stream timeout in single-queue mode: commands wait for the stream to
-- end, so it must end often.
local SINGLE_QUEUE_TIMEOUT = 60

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
		return { ip = state.ip, key = state.creds.key, stream_ip = state.stream_ip or state.ip }
	end
	return nil
end

local function number_property(name, default)
	return tonumber(Properties[name]) or default
end

-- True when the stream has its own C4:url queue (a padded address spelling
-- that the startup self-check confirmed), so commands never wait for it.
local function dual_queue()
	return state.stream_ip ~= nil and state.stream_ip ~= state.ip
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


local function new_lights()
	return lights_mod.new({
		http = bridge_request,
		send = function(id, command, params) C4:SendToDevice(id, command, params) end,
		bridge_id = C4:GetDeviceID(),
		room_id = C4:RoomGetId(),
		log = log,
	})
end

local function new_queue()
	return commands.new({
		send = function(rid, body, done)
			bridge_request({ method = "PUT", path = "/clip/v2/resource/light/" .. rid, body = body }, done)
		end,
	})
end

local function new_stream()
	return stream.new({
		connection = connection,
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
			end)
		end,
		on_container = function(container)
			-- Fan-out only sends SendToDevice, which is safe inside a C4:url
			-- callback; nothing here starts a transfer.
			state.lights:on_container(container)
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

-- Decide which spelling of the bridge address the stream uses (docs/design.md,
-- "Two ways to keep commands flowing"). Director queues C4:url transfers per
-- host text, so a zero-padded spelling gives the stream its own queue. The
-- self-check uses a third spelling, so it can never queue behind a stream,
-- or an abandoned stream, on the stream's spelling. Calls back when done;
-- until then the stream must not be started.
local function choose_stream_address(callback)
	local check_ip = altaddr.for_check(state.ip)
	local padded = altaddr.for_stream(state.ip)
	local function single(reason)
		state.stream_ip = state.ip
		prop("Stream Address", string.format("%s (shared queue with commands: %s; stream timeout capped at %d s)",
			state.ip, reason, SINGLE_QUEUE_TIMEOUT))
		log.warn("stream shares the command queue: %s", reason)
		callback()
	end
	if not padded or not check_ip or not paired() then
		return single(paired() and "no octet below 8 to pad" or "not paired")
	end
	http.request({ ip = check_ip, key = state.creds.key, path = "/clip/v2/resource/bridge", timeout = 10 }, function(r)
		if r.ok then
			state.stream_ip = padded
			prop("Stream Address", padded .. " (own queue; commands use " .. state.ip .. ")")
			log.info("stream will use %s; self-check via %s OK", padded, check_ip)
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
-- optional; default the dotted address). Logs the status, elapsed time and
-- a summary of the response: ids and names for resource lists, otherwise
-- the first 300 characters of the body.
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
		log.always("Hue Request %s %s via %s: %s in %d s: %s", method, path, host,
			r.ok and ("HTTP " .. tostring(r.code)) or tostring(r.err), os.time() - t0, summary)
	end)
end

-- Import Lights: one Control4 light per Hue light, idempotent; see
-- docs/lights-design.md. Progress and the final count go to the Lights
-- property.
dispatch.commands["Import_Lights"] = function()
	if not connection() then
		prop("Lights", "Not paired")
		return
	end
	state.lights:import(function(text) prop("Lights", text) end)
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
	log.always("Lights Report: %d registered, queue %s", #names, C4:JsonEncode(state.queue:stats()))
	for i = 1, math.min(limit, #names) do
		local e = names[i].entry
		local caps = e.caps or {}
		log.always("  %s: device %s proxy %s rid %s color=%s cct=%s mirek %s-%s",
			tostring(e.name), tostring(e.device_id), tostring(e.proxy_id), names[i].rid,
			tostring(caps.has_color), tostring(caps.has_cct), tostring(caps.mirek_min), tostring(caps.mirek_max))
	end
end

-- From a light driver at its startup or binding: resend its configuration
-- and state.
dispatch.commands["HUE_HELLO"] = function(params)
	local rid = params and params.rid or ""
	if not state.lights:hello(rid) then
		log.debug("HUE_HELLO from unregistered light %q", tostring(rid))
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
	prop("Stream Address", "")
	prop("Bridge Model", "")
	prop("Events Received", 0)
	prop("Last Event", "")
	refresh_status()
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
	prop("Lights", state.lights:summary())
	dispatch.replay_properties(Properties)
	state.stream = new_stream()
	state.late_init_done = true
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
end
