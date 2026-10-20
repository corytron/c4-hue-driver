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
local ca_probe = require("bridge.ca_probe")
local pairing = require("bridge.pairing")
local stream = require("bridge.stream")

local state = {
	ip = nil,            -- validated Bridge IP Address property
	creds = nil,         -- credentials.load() result
	stream = nil,        -- bridge.stream instance, created in OnDriverLateInit
	late_init_done = false,
	certs_error = nil,   -- set when the CA bundle could not be installed
	probing = false,     -- a CA probe is running
	probe_handle = nil,  -- its handle, for cancelling
	probe_failed = false,
	after_probe = {},    -- callbacks waiting for the probe result
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
	elseif state.probing then
		prop("Status", "Probing how to load the CA bundle (see Lua output)")
	elseif state.probe_failed then
		prop("Status", "No CA configuration works on this controller; see the CA probe lines in the Lua output")
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

-- Make sure http has a working CA configuration, then call `callback(ok)`.
-- The first call per IP runs the probe (one request per candidate); later
-- calls return at once.
local function ensure_ca(callback)
	if http.ca then
		return callback(true)
	end
	if state.certs_error or not state.ip then
		return callback(false)
	end
	table.insert(state.after_probe, callback)
	if state.probing then
		return
	end
	state.probing = true
	state.probe_failed = false
	refresh_status()
	prop("CA Mode", "probing")
	state.probe_handle = ca_probe.run(state.ip, {
		on_candidate = function(index, count, name)
			prop("CA Mode", string.format("probing %d/%d: %s", index, count, name))
		end,
		on_done = function(winner, insecure_ok)
			state.probing = false
			state.probe_handle = nil
			if winner then
				http.set_ca(winner)
				prop("CA Mode", http.describe_ca(winner))
			else
				state.probe_failed = true
				prop("CA Mode", "none works; unverified handshake " .. (insecure_ok and "works" or "fails too"))
			end
			refresh_status()
			local waiting = state.after_probe
			state.after_probe = {}
			for _, cb in ipairs(waiting) do
				cb(winner ~= nil)
			end
		end,
	})
end

-- Rebuild the stream with the current properties and CA configuration. It
-- is started again if it was running, or if `force` is set and the driver
-- is paired with an IP.
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
		state.probe_failed = false
		ensure_ca(function() restart_stream() end)
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
	ensure_ca(function(ok)
		if not ok then
			return -- Status already explains why
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
	end)
end

dispatch.commands["Probe_CA_Paths"] = function()
	if not state.ip then
		prop("Status", "Enter the bridge IP address first")
		return
	end
	-- Abort any probe in progress (it may be stuck waiting for a callback
	-- Director will never deliver) and start over.
	if state.probe_handle then
		state.probe_handle:cancel()
		state.probe_handle = nil
	end
	state.probing = false
	state.after_probe = {}
	http.set_ca(nil)
	ensure_ca(function(ok)
		if ok then
			restart_stream(true)
		end
	end)
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
	lines[#lines + 1] = "http CA: " .. http.describe_ca()
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
	local result = certs.install()
	for _, err in ipairs(result.errors) do
		log.warn("CA bundle: %s", err)
	end
	if result.sandbox then
		state.certs_error = nil
		log.info("CA bundle written to %s%s", result.sandbox, result.c4z and (" and " .. result.c4z) or "")
	else
		state.certs_error = table.concat(result.errors, "; ")
		log.error("CA bundle install failed: %s", state.certs_error)
	end
	return result.sandbox ~= nil
end

function OnDriverLateInit()
	state.creds = credentials.load()
	local certs_ok = install_certificates()
	dispatch.replay_properties(Properties)
	state.stream = new_stream()
	state.late_init_done = true
	refresh_status()
	if not certs_ok then
		return
	end
	-- Probe as soon as there is an IP, paired or not, so the CA result is
	-- visible right after a driver update without pressing anything.
	if state.ip then
		ensure_ca(function(ok)
			if ok and connection() then state.stream:start() end
		end)
	end
	if not connection() then
		prop("Event Stream", paired() and "Waiting for IP address" or "Not paired")
	end
end

function OnDriverDestroyed()
	if state.stream then
		state.stream:stop()
	end
end
