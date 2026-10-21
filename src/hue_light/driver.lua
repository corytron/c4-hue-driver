-- Hue Light driver: one light_v2 proxy per Hue light. It never speaks to the
-- bridge itself: commands go to the Hue Bridge driver it is bound to
-- (consumer binding 1, class HUE_BRIDGE) with C4:SendToDevice, and the bridge
-- pushes configuration and state back through ExecuteCommand. The message
-- contract is in docs/lights-design.md; the light_v2 facts in docs/design.md.

local log = require("common.log")
local dispatch = require("common.dispatch")
local state = require("light.state")
local caps = require("light.caps")

-- Dev builds only (tools/build.sh --dev ships common/devloop.lua): the bridge
-- forwards this driver's new code as DEV_RELOAD, see docs/dev-loop.md.
-- Release builds have no such module, so this is nil.
local devloop_ok, devloop = pcall(require, "common.devloop")
if not devloop_ok then
	-- Absent in release builds (expected); anything else is a real error
	-- that must be visible, since the loop is how the controller gets tested.
	if not tostring(devloop):find("not found", 1, true) then
		print("[ERROR] Hue Light: dev loop failed to load: " .. tostring(devloop))
	end
	devloop = nil
end

-- Binding IDs, see driver.xml.
local PROXY_BINDING = 5001
local BRIDGE_BINDING = 1

-- Grace after the requested ramp before a target the bridge never confirmed
-- is reported as reached, so the UI never sticks in "changing".
local FALLBACK_MS = 1000

-- Prefix of every line this driver logs; the dev-build log forwarding below
-- recognises its own lines by it.
local LOG_PREFIX = "Hue Light"

-- Lines logged before the bridge is known wait for hello(); only this many.
local LOG_BUFFER = 30

-- SET_COLOR_TARGET parameter names are [assumed] (the docs print them with
-- spaces, one with a "CIE 1931" suffix); the first one received is logged
-- in full so the dev loop can settle them. Each list is tried in order.
local COLOR_KEYS = {
	x = { "LIGHT_COLOR_TARGET_X", "LIGHT_COLOR_TARGET_X_CIE_1931" },
	y = { "LIGHT_COLOR_TARGET_Y", "LIGHT_COLOR_TARGET_Y_CIE_1931" },
	mode = { "LIGHT_COLOR_TARGET_COLOR_MODE", "LIGHT_COLOR_TARGET_MODE" },
	rate = { "LIGHT_COLOR_TARGET_RATE", "LIGHT_COLOR_TARGET_COLOR_RATE", "RATE" },
}

local st = state.new()
local bridge = nil           -- device id of the bound Hue Bridge driver, or nil
local fallback = {}          -- "brightness" / "color" -> armed C4LuaTimer
local color_params_logged = false

-- Dev log forwarding -------------------------------------------------------

-- Dev builds: every line this driver logs, debug excepted, also goes to the
-- bridge as HUE_LOG { rid, line }, so the dev loop shows the lights' output
-- next to the bridge's own (docs/dev-loop.md). Release builds leave log.sink
-- alone. Lines logged before the bridge is known wait, newest LOG_BUFFER
-- kept, and go out from hello().
local flush_log = function() end

if devloop then
	local previous_sink = log.sink
	local original_print = print
	local pending = {}
	local send_failed = false

	-- Only lines our own logger produced: "[LEVEL] Hue Light: ..." or, from
	-- log.always, "Hue Light: ...". On the controller that is every line;
	-- the test harness shares one common.log between drivers, where
	-- forwarding another driver's output would echo back and forth.
	local OWN_PLAIN = "^" .. LOG_PREFIX .. ": "
	local OWN_LEVELED = "^%[%u+%] " .. LOG_PREFIX .. ": "
	local function own_line(line)
		return line:find(OWN_PLAIN) ~= nil or line:find(OWN_LEVELED) ~= nil
	end

	-- A failing send is said once per failure streak, through print alone,
	-- so it cannot feed back into the forwarding.
	local function send_log(line)
		local ok, err = pcall(function()
			C4:SendToDevice(bridge, "HUE_LOG", { rid = st.rid, line = line }, false, false)
		end)
		if ok then
			send_failed = false
		elseif not send_failed then
			send_failed = true
			original_print("[WARN] " .. LOG_PREFIX .. ": log forwarding to the bridge failed: " .. tostring(err))
		end
	end

	log.sink = function(line)
		previous_sink(line)
		line = tostring(line)
		if line:sub(1, 7) == "[DEBUG]" or not own_line(line) then
			return
		end
		if bridge then
			send_log(line)
		else
			pending[#pending + 1] = line
			if #pending > LOG_BUFFER then
				table.remove(pending, 1)
			end
		end
	end

	flush_log = function()
		local lines = pending
		pending = {}
		for _, line in ipairs(lines) do
			send_log(line)
		end
	end
end

local function prop(name, value)
	C4:UpdateProperty(name, tostring(value == nil and "" or value))
end

local function notify(command, params)
	C4:SendToProxy(PROXY_BINDING, command, params)
end

-- Why a command cannot reach the light right now, or nil when it can.
local function blocker()
	if not bridge then
		return "not bound to a Hue Bridge"
	elseif not st.rid then
		return "waiting for the bridge to assign a Hue light (run Import Lights on it)"
	end
	return nil
end

-- What ONLINE_CHANGED carries: reachable through a bridge that knows us, and
-- not reported unreachable by Zigbee.
local function is_online()
	return blocker() == nil and st.online ~= false
end

local function refresh_status()
	if not bridge then
		prop("Status", "Not bound to a Hue Bridge")
	elseif not st.rid or not st.name then
		prop("Status", "Bound; waiting for the bridge")
	else
		prop("Status", string.format("%s (%s)", st.name, st.model or "unknown model"))
	end
	if not bridge or st.online == false then
		prop("Online", "Offline")
	else
		prop("Online", st.online and "Online" or "")
	end
end

-- Proxy notifies -----------------------------------------------------------

local function report_brightness()
	local brightness = state.to_proxy_brightness(st)
	if brightness then
		notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = brightness })
	end
end

local function report_color()
	local x, y, mode = state.to_proxy_color(st)
	if x then
		notify("LIGHT_COLOR_CHANGED", {
			LIGHT_COLOR_CURRENT_X = x,
			LIGHT_COLOR_CURRENT_Y = y,
			LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
		})
	end
end

local function report_online()
	notify("ONLINE_CHANGED", { STATE = is_online() })
end

-- Targets ------------------------------------------------------------------

-- A target sent to the bridge stays pending until a HUE_STATE carrying that
-- field arrives or its fallback fires; either way the proxy gets a CHANGED.
local function settle(kind)
	if fallback[kind] then
		fallback[kind]:Cancel()
		fallback[kind] = nil
	end
end

local function arm(kind, rate, on_timeout)
	settle(kind)
	fallback[kind] = C4:SetTimer(rate + FALLBACK_MS, function()
		fallback[kind] = nil
		on_timeout()
	end)
end

-- True when a proxy command can be acted on; otherwise it is dropped here,
-- with Status saying why.
local function ready(command)
	local why = blocker()
	if why then
		log.info("%s dropped: %s", command, why)
		refresh_status()
		return false
	end
	return true
end

local function set_brightness(target, rate)
	target, rate = tonumber(target), tonumber(rate) or 0
	if not target then
		return log.warn("brightness command without a target")
	end
	if not ready("brightness target") then
		return
	end
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = state.to_proxy_brightness(st) or 0,
		LIGHT_BRIGHTNESS_TARGET = target,
		RATE = rate,
	})
	local params = state.from_brightness_target(st, target, rate)
	C4:SendToDevice(bridge, "HUE_SET", params)
	arm("brightness", rate, function()
		log.debug("brightness target %s unconfirmed after %d ms; assuming it", tostring(target), rate + FALLBACK_MS)
		local changed = state.apply_hue(st, params)
		report_brightness()
		if changed.color then
			report_color() -- the turn-on carried a colour stored while off
		end
	end)
end

local function set_color(x, y, mode, rate)
	x, y, mode, rate = tonumber(x), tonumber(y), tonumber(mode) or state.MODE_XY, tonumber(rate) or 0
	if not (x and y) then
		return log.warn("colour command without x/y")
	end
	if not ready("colour target") then
		return
	end
	local cx, cy, cmode = state.to_proxy_color(st)
	notify("LIGHT_COLOR_CHANGING", {
		LIGHT_COLOR_TARGET_X = x,
		LIGHT_COLOR_TARGET_Y = y,
		LIGHT_COLOR_TARGET_COLOR_MODE = mode,
		LIGHT_COLOR_TARGET_RATE = rate,
		LIGHT_COLOR_CURRENT_X = cx,
		LIGHT_COLOR_CURRENT_Y = cy,
		LIGHT_COLOR_CURRENT_COLOR_MODE = cmode,
	})
	local params, why = state.from_color_target(st, x, y, mode, rate)
	if params then
		C4:SendToDevice(bridge, "HUE_SET", params)
		arm("color", rate, function()
			log.debug("colour target unconfirmed after %d ms; assuming it", rate + FALLBACK_MS)
			state.apply_hue(st, params)
			report_color()
		end)
	elseif why == "stored" then
		-- Light off: the colour waits for the next turn-on (light_v2 best
		-- practice). The proxy still needs its CHANGED, and the colour it
		-- asked for is what the light will show.
		log.debug("light is off; colour stored for the next turn-on")
		notify("LIGHT_COLOR_CHANGED", {
			LIGHT_COLOR_CURRENT_X = x,
			LIGHT_COLOR_CURRENT_Y = y,
			LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
		})
	else
		log.warn("colour target ignored: %s", tostring(why))
		report_color()
	end
end

-- Bridge binding -----------------------------------------------------------

-- The bound bridge's device id. The API documents a table of id/name pairs,
-- the idc_client sample uses the result as a number: accept both.
local function bound_bridge()
	local found = C4:GetBoundProviderDevice(C4:GetDeviceID(), BRIDGE_BINDING)
	if type(found) == "table" then
		found = next(found)
	end
	return tonumber(found)
end

-- Announce ourselves; the bridge answers with HUE_CONFIGURE and full state
-- when it knows the rid. No rid key when unknown: SendToDevice drops empty
-- values anyway. `hint` is the device id OnBindingChanged named, for when
-- Director's lookup does not reflect the new binding yet.
local function hello(hint)
	bridge = bound_bridge() or tonumber(hint)
	if bridge then
		C4:SendToDevice(bridge, "HUE_HELLO", st.rid and { rid = st.rid } or {})
		flush_log() -- dev builds: lines logged while the bridge was unknown
	end
	refresh_status()
end

-- Properties ---------------------------------------------------------------

dispatch.properties["Driver_Version"] = function()
	prop("Driver Version", C4:GetDriverConfigInfo("version"))
end

dispatch.properties["Debug_Mode"] = function(value)
	log.set_debug(value == "On")
end

-- From the bridge (ExecuteCommand) -------------------------------------------

dispatch.commands["HUE_CONFIGURE"] = function(params)
	state.configure(st, params)
	if st.rid then
		C4:PersistSetValue("hue_rid", st.rid)
	end
	prop("Hue Light ID", st.rid)
	prop("Hue Name", st.name)
	prop("Model", st.model)
	-- Both supports_* in one notify, then the current colour straight after
	-- (the proxy docs ask for both), then brightness.
	notify("DYNAMIC_CAPABILITIES_CHANGED", caps.params(st))
	report_color()
	report_brightness()
	report_online()
	refresh_status()
end

dispatch.commands["HUE_STATE"] = function(params)
	if st.rid and params.rid and params.rid ~= st.rid then
		return log.warn("HUE_STATE for rid %s ignored (ours is %s)", params.rid, st.rid)
	end
	local changed = state.apply_hue(st, params)
	-- Any report of a pending field settles the target, whatever the value:
	-- the proxy heard CHANGING and must hear CHANGED.
	if fallback.brightness and (params.on ~= nil or params.brightness ~= nil) then
		settle("brightness")
		changed.brightness = true
	end
	if fallback.color and (params.x ~= nil or params.mirek ~= nil or params.color_mode ~= nil) then
		settle("color")
		changed.color = true
	end
	if changed.brightness then report_brightness() end
	if changed.color then report_color() end
	if changed.online then
		report_online()
		refresh_status()
	end
end

dispatch.commands["DEV_RELOAD"] = function(params)
	if not (devloop and devloop.apply_forwarded) then
		return log.warn("DEV_RELOAD ignored: no dev loop in this build")
	end
	-- On success the new code is already running; this handler, its log
	-- module and its bridge id are the old instance's, still good for one
	-- more line. The failure detail went through devloop's own print, which
	-- is not forwarded.
	if devloop.apply_forwarded(params) then
		log.always("light reloaded to version %s", tostring(params.version))
	else
		log.warn("light reload failed; see this light's Lua output")
	end
end

-- From the proxy (ReceivedFromProxy) ------------------------------------------
-- Commands without a handler are logged at debug by common.dispatch.

-- The proxy asks for current state after Director starts or a UI connects.
dispatch.proxy["SYNCHRONIZE"] = function()
	report_online()
	report_brightness()
	report_color()
end

dispatch.proxy["SET_BRIGHTNESS_TARGET"] = function(_, params)
	set_brightness(params.LIGHT_BRIGHTNESS_TARGET, params.RATE)
end

local function pick(params, names)
	for _, name in ipairs(names) do
		if params[name] ~= nil then
			return params[name]
		end
	end
	return nil
end

dispatch.proxy["SET_COLOR_TARGET"] = function(_, params)
	if not color_params_logged then
		color_params_logged = true
		local parts = {}
		for k, v in pairs(params) do
			parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
		end
		table.sort(parts)
		log.always("first SET_COLOR_TARGET params: %s", table.concat(parts, " "))
	end
	set_color(pick(params, COLOR_KEYS.x), pick(params, COLOR_KEYS.y),
		pick(params, COLOR_KEYS.mode), pick(params, COLOR_KEYS.rate))
end

dispatch.proxy["TOGGLE"] = function()
	set_brightness(st.on and 0 or 100, 0)
end

-- Legacy commands that old programming may still send.
dispatch.proxy["ON"] = function() set_brightness(100, 0) end
dispatch.proxy["OFF"] = function() set_brightness(0, 0) end
dispatch.proxy["SET_LEVEL"] = function(_, params) set_brightness(params.LEVEL, params.TIME) end
dispatch.proxy["RAMP_TO_LEVEL"] = function(_, params) set_brightness(params.LEVEL, params.TIME) end

-- Lifecycle ----------------------------------------------------------------

log.set_prefix(LOG_PREFIX)
dispatch.install(_G)

function OnDriverInit()
end

function OnDriverLateInit()
	local rid = C4:PersistGetValue("hue_rid")
	st.rid = (rid ~= nil and rid ~= "") and tostring(rid) or nil
	dispatch.replay_properties(Properties)
	prop("Hue Light ID", st.rid)
	hello()
	report_online()
end

-- Control bindings only; the bridge binding is one, the proxy's is not.
function OnBindingChanged(idBinding, _, bound, otherDevice)
	if idBinding ~= BRIDGE_BINDING then
		return
	end
	if bound then
		hello(otherDevice)
	else
		bridge = nil
		settle("brightness")
		settle("color")
		refresh_status()
		report_online()
	end
end

function OnDriverDestroyed()
	settle("brightness")
	settle("color")
end
