-- Hue Light driver: one light_v2 proxy per Hue light, controlled through the
-- Hue Bridge driver it is bound to. Scaffold only: reports itself offline
-- until the bridge side exists.

local log = require("common.log")
local dispatch = require("common.dispatch")

-- Binding IDs, see driver.xml.
local PROXY_BINDING = 5001

local state = {
	online = false,
	brightness = 0,
}

local function notify_proxy(command, params)
	C4:SendToProxy(PROXY_BINDING, command, params)
end

local function report_state()
	notify_proxy("ONLINE_CHANGED", { STATE = state.online })
	notify_proxy("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = state.brightness })
end

dispatch.properties["Driver_Version"] = function()
	C4:UpdateProperty("Driver Version", C4:GetDriverConfigInfo("version"))
end

dispatch.properties["Debug_Mode"] = function(value)
	log.set_debug(value == "On")
end

-- The proxy asks for current state after Director starts or a UI connects.
dispatch.proxy["SYNCHRONIZE"] = function()
	report_state()
end

dispatch.proxy["SET_BRIGHTNESS_TARGET"] = function(_, params)
	log.info("SET_BRIGHTNESS_TARGET %s ignored: not connected to a bridge yet",
		tostring(params.LIGHT_BRIGHTNESS_TARGET))
	report_state()
end

log.set_prefix("Hue Light")
dispatch.install(_G)

function OnDriverInit()
end

function OnDriverLateInit()
	dispatch.replay_properties(Properties)
	C4:UpdateProperty("Status", "Not connected to a Hue Bridge")
	report_state()
end
