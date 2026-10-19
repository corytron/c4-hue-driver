-- Hue Bridge driver: owns the connection to one Hue bridge and serves the
-- Hue Light drivers bound to it. Scaffold only: properties and status so far.

local log = require("common.log")
local dispatch = require("common.dispatch")
local config = require("bridge.config")

local state = {
	ip = nil,
}

local function set_status(text)
	C4:UpdateProperty("Status", text)
end

local function refresh_status()
	if not state.ip then
		set_status("Enter the bridge IP address")
	else
		set_status("Not paired")
	end
end

dispatch.properties["Driver_Version"] = function()
	C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

dispatch.properties["Debug_Mode"] = function(value)
	log.set_debug(value == "On")
end

dispatch.properties["Bridge_IP_Address"] = function(value)
	local ip, err = config.parse_ipv4(value)
	if not ip and value ~= "" then
		log.warn("ignoring bridge IP %q: %s", value, err)
	end
	state.ip = ip
	refresh_status()
end

log.set_prefix("Hue Bridge")
dispatch.install(_G)

function OnDriverInit()
end

function OnDriverLateInit()
	dispatch.replay_properties(Properties)
	refresh_status()
end

function OnDriverDestroyed()
	state.ip = nil
end
