-- Hue Bridge driver: owns the connection to one Hue bridge and serves the
-- Hue Light drivers bound to it.
--
-- This build is the hardware spike: pairing, one authenticated request, and
-- the event stream, with enough Composer-visible diagnostics to judge how
-- C4:url behaves on the controller. No light control yet.

local log = require("common.log")
local dispatch = require("common.dispatch")
local config = require("bridge.config")
local http = require("bridge.http")
local credentials = require("bridge.credentials")
local certs = require("bridge.certs")
local pairing = require("bridge.pairing")
local stream = require("bridge.stream")

local state = {
	ip = nil,            -- validated Bridge IP Address property
	creds = nil,         -- credentials.load() result
	stream = nil,        -- bridge.stream instance, created in OnDriverLateInit
	late_init_done = false,
	certs_error = nil,   -- set when the CA bundle could not be installed
}

local function prop(name, value)
	C4:UpdateProperty(name, tostring(value == nil and "" or value))
end

local function paired()
	return state.creds ~= nil and credentials.paired(state.creds)
end

local function refresh_status()
	if state.certs_error then
		-- Nothing works without the bundle; keep that visible over everything.
		prop("Status", "Certificate install failed: " .. state.certs_error)
	elseif not state.ip then
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
	local n = tonumber(Properties[name])
	return n or default
end

local function new_stream()
	return stream.new({
		connection = connection,
		timeout = number_property("Stream Timeout (s)", stream.DEFAULT_TIMEOUT),
		watchdog = number_property("Stream Watchdog (s)", stream.DEFAULT_WATCHDOG),
		on_status = function(text) prop("Event Stream", text) end,
		on_connected = function()
			-- The real driver resyncs all light state here.
			log.info("event stream connected")
		end,
		on_container = function()
			prop("Events Received", state.stream.stats.containers)
			prop("Last Event", state.stream.stats.last_event)
		end,
	})
end

-- Restart the stream with the current properties, if it should be running.
local function restart_stream()
	if not state.stream then
		return
	end
	local was_running = state.stream:running()
	state.stream:stop()
	state.stream = new_stream()
	if was_running and connection() then
		state.stream:start()
	end
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
		if ip and paired() then
			credentials.save_ip(ip)
			state.creds.ip = ip
		end
		restart_stream()
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
			state.creds = credentials.load()
			prop("Bridge Model", creds.model or "")
			refresh_status()
			if state.stream then
				state.stream:start()
			end
		end,
		on_error = function(message)
			prop("Status", "Pairing failed: " .. message)
		end,
	})
end

dispatch.commands["Test_Connection"] = function()
	if not connection() then
		prop("Status", "Not paired")
		return
	end
	prop("Status", "Testing: GET /clip/v2/resource/bridge")
	http.request({ ip = state.ip, key = state.creds.key, path = "/clip/v2/resource/bridge" }, function(r)
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
		prop("Status", "Test OK: HTTP 200, bridge " .. tostring(reported or state.creds.bridge_id))
	end)
end

dispatch.commands["Connect_Event_Stream"] = function()
	if not connection() then
		prop("Event Stream", "Not paired")
		return
	end
	state.stream:start()
end

dispatch.commands["Disconnect_Event_Stream"] = function()
	state.stream:stop()
end

dispatch.commands["Diagnose_Certificates"] = function()
	local lines = certs.diagnose()
	lines[#lines + 1] = "http CA bundle: " .. tostring(http.ca_bundle)
	for _, line in ipairs(lines) do
		log.always("diag %s", line)
	end
	prop("Status", "Diagnostics written to the Lua output (" .. #lines .. " lines)")
end

dispatch.commands["Forget_Pairing"] = function()
	state.stream:stop()
	credentials.clear()
	state.creds = credentials.load()
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

-- Write the Signify CA bundle into the sandbox and point the HTTP client at
-- it. Without this every HTTPS call fails, so the failure is made loud.
local function install_certificates()
	local path, err = certs.install()
	if path then
		http.set_ca_bundle(path)
		state.certs_error = nil
		log.info("CA bundle at %s", path)
	else
		state.certs_error = tostring(err)
		log.error("CA bundle install failed: %s", err)
	end
	return path ~= nil
end

function OnDriverLateInit()
	state.creds = credentials.load()
	local certs_ok = install_certificates()
	dispatch.replay_properties(Properties)
	state.stream = new_stream()
	state.late_init_done = true
	refresh_status()
	if connection() and certs_ok then
		state.stream:start()
	else
		prop("Event Stream", paired() and "Waiting for IP address" or "Not paired")
	end
end

function OnDriverDestroyed()
	if state.stream then
		state.stream:stop()
	end
end
