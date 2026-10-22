-- Hue Light driver: one light_v2 proxy per Hue light. It never speaks to the
-- bridge itself: commands go to the Hue Bridge driver it is bound to
-- (consumer binding 1, class HUE_BRIDGE) with C4:SendToDevice, and the bridge
-- pushes configuration and state back through ExecuteCommand. The message
-- contract is in docs/lights-design.md and docs/import-design.md §4/§13; the
-- light_v2 facts in docs/design.md.

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

-- The light's own copy of its identity (PersistSetValue key per state field),
-- so a bridge that lost its registry can rebuild it from the lights instead
-- of importing them a second time (docs/import-design.md §1, rule 3).
local PERSISTED = { rid = "hue_rid", name = "hue_name", model = "hue_model" }

local st = state.new()
local bridge = nil           -- device id of the bound Hue Bridge driver, or nil
local fallback = {}          -- "brightness" / "color" -> { timer = armed C4LuaTimer, assume = fn }
local color_params_logged = false
local late_init_done = false -- UpdateProperty and SendToProxy are unsafe before OnDriverLateInit
local early = {}             -- bridge messages received before late init, in arrival order

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
	local parts = {}
	for k, v in pairs(params or {}) do parts[#parts + 1] = k .. "=" .. tostring(v) end
	table.sort(parts)
	log.debug("-> proxy %s %s", command, table.concat(parts, " "))
	C4:SendToProxy(PROXY_BINDING, command, params)
end

-- Identity and status texts ------------------------------------------------

-- Every inter-driver param is a string.
local function device_id()
	return tostring(C4:GetDeviceID())
end

-- "#12" from Hue's v1 id (the bridge sends "/lights/12" or "12"), or nil.
local function v1_label()
	local num = st.id_v1 and st.id_v1:match("(%d+)%s*$")
	return num and ("#" .. num) or nil
end

-- What Hue Light ID shows: "#12 (e0e51794…)" once the v1 id is known, the
-- rid alone until then. A rid without dashes (not a UUID) is shown whole.
local function light_id_label()
	if not st.rid then
		return ""
	end
	local v1 = v1_label()
	if not v1 then
		return st.rid
	end
	local head = st.rid:match("^([^-]+)-")
	return string.format("%s (%s)", v1, head and (head .. "…") or st.rid)
end

-- "Desk Lamp #12", or whatever part of that is known, for the forgotten text.
local function light_label(name)
	local parts = {}
	name = name or st.name
	if name then parts[#parts + 1] = name end
	local v1 = v1_label()
	if v1 then parts[#parts + 1] = v1 end
	if #parts == 0 then
		return st.rid or "unknown"
	end
	return table.concat(parts, " ")
end

local function forgotten_status()
	return string.format("Forgotten by the bridge (was Hue light %s). "
		.. "Delete this device in Composer, or bind it again and use Link Devices", light_label(st.forgotten.name))
end

local function gone_status()
	local since = st.gone_since and (" since " .. os.date("%Y-%m-%d %H:%M", st.gone_since)) or ""
	return "Gone from the Hue bridge" .. since .. "; re-link or Forget"
end

-- Why a command cannot reach the light right now, or nil when it can. The
-- order is the order Status explains things in: a forgotten light is told
-- what to do even while its binding is already gone.
local function blocker()
	if st.forgotten then
		return "forgotten by the bridge; delete this device or bind it again and use Link Devices"
	elseif not bridge then
		return "not bound to a Hue Bridge"
	elseif not st.rid then
		return "waiting for the bridge to assign a Hue light (use Add Light or Link Devices on it)"
	elseif st.gone then
		return "gone from the Hue bridge; re-link or Forget"
	end
	return nil
end

-- What ONLINE_CHANGED carries: reachable through a bridge that knows us, and
-- not reported unreachable by Zigbee.
local function is_online()
	return blocker() == nil and st.online ~= false
end

local function refresh_status()
	if st.forgotten then
		prop("Status", forgotten_status())
	elseif not bridge then
		prop("Status", "Not bound to a Hue Bridge")
	elseif st.gone then
		prop("Status", gone_status())
	elseif not st.rid or not st.name then
		prop("Status", "Bound; waiting for the bridge")
	else
		prop("Status", string.format("%s (%s)", st.name, st.model or "unknown model"))
	end
	-- "" while nothing says either way: bound, but the bridge has not reported.
	if not bridge or st.forgotten or st.gone or st.online == false then
		prop("Online", "Offline")
	else
		prop("Online", st.online and "Online" or "")
	end
end

-- Proxy notifies -----------------------------------------------------------
-- The report_* functions return true when they had something to report.

local function report_brightness()
	local brightness = state.to_proxy_brightness(st)
	if not brightness then
		return false
	end
	notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = brightness })
	return true
end

local function report_color()
	local x, y, mode = state.to_proxy_color(st)
	if not x then
		return false
	end
	notify("LIGHT_COLOR_CHANGED", {
		LIGHT_COLOR_CURRENT_X = x,
		LIGHT_COLOR_CURRENT_Y = y,
		LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
	})
	return true
end

local function report_online()
	notify("ONLINE_CHANGED", { STATE = is_online() })
	return true
end

-- Targets ------------------------------------------------------------------

-- A target sent to the bridge stays pending until a HUE_STATE carrying that
-- field arrives, its fallback fires, or the proxy says stop; either way the
-- proxy gets a CHANGED.
local function settle(kind)
	if fallback[kind] then
		fallback[kind].timer:Cancel()
		fallback[kind] = nil
	end
end

-- `assume` applies the sent target to the cache and reports it; it runs when
-- the bridge has not confirmed within the ramp plus FALLBACK_MS.
local function arm(kind, rate, assume)
	settle(kind)
	local pending = { assume = assume }
	pending.timer = C4:SetTimer(rate + FALLBACK_MS, function()
		fallback[kind] = nil
		assume()
	end)
	fallback[kind] = pending
end

-- SET_BRIGHTNESS_STOP / SET_COLOR_STOP: the proxy wants the transition closed
-- now. The cached value goes out as CHANGED (the next real report corrects
-- it if the bulb went on ramping; Hue has no stop primitive, so it does).
-- With nothing cached yet the target is assumed, as the fallback would have,
-- so the proxy never waits on a CHANGING.
local function stop(kind, report)
	local pending = fallback[kind]
	settle(kind)
	if not report() and pending then
		pending.assume()
	end
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
-- the idc_client sample uses the result as a number: accept both. With
-- nothing bound the docs say nil but OS 3.4.2 answers the number 0 [hardware
-- 2026-10-22, design.md "Project APIs"], which Lua would take for a bridge.
local function bound_bridge()
	local found = C4:GetBoundProviderDevice(C4:GetDeviceID(), BRIDGE_BINDING)
	if type(found) == "table" then
		found = next(found)
	end
	found = tonumber(found)
	if found and found > 0 then
		return found
	end
	return nil
end

-- Our light_v2 proxy: the consumer bound to binding 5001, the device Composer
-- shows and renames [verified: API 32/_3 usage note; hardware, docs/design.md
-- "Lights: verified on hardware": first key of the table]. nil when none.
local function proxy_id()
	local bound = C4:GetBoundConsumerDevices(C4:GetDeviceID(), PROXY_BINDING)
	if type(bound) ~= "table" then
		return nil
	end
	return tonumber((next(bound)))
end

-- What HUE_HELLO carries: the persisted identity, so the bridge can adopt a
-- bound light its registry lacks. Absent keys for what is unknown: a rid-less
-- light sends no rid (SendToDevice drops empty values anyway).
local function hello_params()
	return { rid = st.rid, device_id = device_id(), name = st.name, model = st.model }
end

-- Announce ourselves; the bridge answers with HUE_CONFIGURE and full state
-- when it knows the rid. `hint` is the device id OnBindingChanged named, for
-- when Director's lookup does not reflect the new binding yet.
local function hello(hint)
	bridge = bound_bridge() or tonumber(hint)
	if bridge then
		C4:SendToDevice(bridge, "HUE_HELLO", hello_params())
		flush_log() -- dev builds: lines logged while the bridge was unknown
	end
	refresh_status()
end

local function load_identity()
	for field, key in pairs(PERSISTED) do
		local value = C4:PersistGetValue(key)
		st[field] = (value ~= nil and value ~= "") and tostring(value) or nil
	end
end

local function save_identity()
	for field, key in pairs(PERSISTED) do
		if st[field] then
			C4:PersistSetValue(key, st[field])
		end
	end
end

-- Properties ---------------------------------------------------------------

dispatch.properties["Driver_Version"] = function()
	prop("Driver Version", C4:GetDriverConfigInfo("version"))
end

dispatch.properties["Debug_Mode"] = function(value)
	log.set_debug(value == "On")
end

-- From the bridge (ExecuteCommand) -------------------------------------------

-- Director late-inits drivers in no particular order, so the bridge's
-- messages can reach a light before its own OnDriverLateInit, where
-- UpdateProperty and SendToProxy are not yet safe [verified: API 22/_25.2].
-- Such messages wait, in order, and OnDriverLateInit applies them.
local function after_late_init(name, handler)
	return function(params)
		if late_init_done then
			return handler(params)
		end
		early[#early + 1] = { name = name, handler = handler, params = params }
		log.debug("%s before late init; buffered (%d waiting)", name, #early)
	end
end

local function drain_early()
	local queued = early
	early = {}
	for _, m in ipairs(queued) do
		log.debug("applying buffered %s", m.name)
		local ok, err = pcall(m.handler, m.params)
		if not ok then
			log.error("buffered %s failed: %s", m.name, tostring(err))
		end
	end
end

dispatch.commands["HUE_CONFIGURE"] = after_late_init("HUE_CONFIGURE", function(params)
	state.configure(st, params)
	save_identity()
	prop("Hue Light ID", light_id_label())
	prop("Hue Name", st.name)
	prop("Model", st.model)
	prop("Hue Room", st.hue_room)
	if st.gone then
		log.debug("configured as gone from the bridge%s", st.gone_since and (" since " .. st.gone_since) or "")
	end
	-- Both supports_* in one notify, then the current colour straight after
	-- (the proxy docs ask for both), then brightness.
	notify("DYNAMIC_CAPABILITIES_CHANGED", caps.params(st))
	report_color()
	report_brightness()
	report_online()
	refresh_status()
end)

dispatch.commands["HUE_STATE"] = after_late_init("HUE_STATE", function(params)
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
end)

-- The bridge ran Forget for this light (from its own action or ours): the
-- device stays, the owner decides. The identity stays persisted too, so
-- binding the device again lets the bridge adopt it from its own rid.
dispatch.commands["HUE_FORGOTTEN"] = after_late_init("HUE_FORGOTTEN", function(params)
	if st.rid and params.rid and params.rid ~= st.rid then
		return log.warn("HUE_FORGOTTEN for rid %s ignored (ours is %s)", params.rid, st.rid)
	end
	st.forgotten = { name = params.name or st.name }
	settle("brightness")
	settle("color")
	log.warn("forgotten by the bridge (was Hue light %s)", light_label(st.forgotten.name))
	prop("Last Action", "Forgotten by the bridge")
	refresh_status()
	report_online()
end)

dispatch.commands["DEV_RELOAD"] = function(params)
	if not (devloop and devloop.apply_forwarded) then
		return log.warn("DEV_RELOAD ignored: no dev loop in this build")
	end
	-- Lights and scene devices share the bridge's binding; a bundle for the
	-- scene tree is not ours (an older bridge forwards without filtering).
	if params and params.tree and params.tree ~= "light" then
		return log.debug("DEV_RELOAD for the %s tree ignored", tostring(params.tree))
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

-- Composer actions (LUA_ACTION) ----------------------------------------------
-- Every click ends in Last Action and a log line, whatever happened.

local function result(text)
	log.always("%s", text)
	prop("Last Action", text)
end

-- Rename our proxy (the device Composer shows) to the Hue name. Only ever
-- from this click: names belong to the owner (docs/import-design.md §7).
dispatch.commands["Adopt_Hue_Name"] = function()
	if not st.name then
		return result("Not renamed: no Hue name known yet (the bridge has not configured this light)")
	end
	local id = proxy_id()
	if not id then
		return result("Not renamed: no light_v2 proxy is bound to binding 5001")
	end
	C4:RenameDevice(id, st.name) -- [verified: API 22/_32]
	result(string.format("Renamed device %d to %s", id, st.name))
end

-- Ask the bridge to Forget this light; it answers HUE_FORGOTTEN, which sets
-- Status. The bridge finds the entry by rid or, for a rid-less light, by
-- device id.
dispatch.commands["Forget_This_Light"] = function()
	if not bridge then
		return result("Not sent: not bound to a Hue Bridge")
	end
	C4:SendToDevice(bridge, "HUE_FORGET", { rid = st.rid, device_id = device_id() })
	result("Asked the bridge to forget this light; its answer sets Status")
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

-- Advanced Lighting Scenes with reduced_als_support drive the light with
-- SET_BRIGHTNESS_TARGET / SET_COLOR_TARGET and end a scene ramp with these;
-- both carry no parameters [verified: proxy-protocol reference, light_v2
-- SET_BRIGHTNESS_STOP, SET_COLOR_STOP, reduced_als_support,
-- supports_brightness_stop]. Nothing goes to the bridge: Hue cannot stop a
-- transition, the proxy only needs its CHANGED.
dispatch.proxy["SET_BRIGHTNESS_STOP"] = function()
	stop("brightness", report_brightness)
end

dispatch.proxy["SET_COLOR_STOP"] = function()
	stop("color", report_color)
end

-- The ALS section lists STOP_SCENE_RAMP among what a reduced-ALS driver must
-- support; whether the proxy forwards it under that name is unverified, so it
-- is accepted as a brightness stop.
dispatch.proxy["STOP_SCENE_RAMP"] = dispatch.proxy["SET_BRIGHTNESS_STOP"]

dispatch.proxy["TOGGLE"] = function()
	set_brightness(st.on and 0 or 100, 0)
end

-- Legacy commands that old programming may still send.
dispatch.proxy["ON"] = function() set_brightness(100, 0) end
dispatch.proxy["OFF"] = function() set_brightness(0, 0) end
dispatch.proxy["SET_LEVEL"] = function(_, params) set_brightness(params.LEVEL, params.TIME) end
dispatch.proxy["RAMP_TO_LEVEL"] = function(_, params) set_brightness(params.LEVEL, params.TIME) end

-- Keypad buttons ----------------------------------------------------------
-- A keypad bound to the proxy's Top / Bottom / Toggle Button Link inputs
-- reaches the driver as BUTTON_ACTION { BUTTON_ID 0 top 1 bottom 2 toggle,
-- ACTION 1 press, 2 release as a click, 0 release after a hold }; the proxy
-- expects a BUTTON_ACTION notification echoing every press and release
-- [verified: proxy-protocol reference, light_v2 BUTTON_ACTION command and
-- notification]. Behaviour and defaults: docs/keypad-design.md.
local BUTTON_TOP, BUTTON_BOTTOM = 0, 1
local ACT_RELEASE, ACT_PRESS, ACT_CLICK = 0, 1, 2
local HOLD_AFTER_MS = 400   -- a press still down after this starts a ramp
local HOLD_TICK_MS = 100    -- the level estimate advances this often during a ramp
local SETTING_KEYS = { preset = "preset_level", click_up = "click_rate_up", click_down = "click_rate_down",
	hold_up = "hold_rate_up", hold_down = "hold_rate_down" }
local SETTING_DEFAULTS = { preset = 100, click_up = 250, click_down = 250, hold_up = 5000, hold_down = 5000 }
local settings = {}
local hold = nil            -- { button, timer, ramping, level, step, to } while a button is down

local function setting(name)
	return tonumber(settings[name]) or SETTING_DEFAULTS[name]
end

local function load_settings()
	for name, key in pairs(SETTING_KEYS) do
		settings[name] = tonumber(C4:PersistGetValue(key))
	end
end

local function save_setting(name, value)
	value = tonumber(value)
	if not value then
		return log.warn("%s without a number", SETTING_KEYS[name])
	end
	settings[name] = value
	C4:PersistSetValue(SETTING_KEYS[name], value)
end

local function end_hold()
	if hold and hold.timer then
		hold.timer:Cancel()
	end
	hold = nil
end

local function click(button)
	if button == BUTTON_TOP then
		set_brightness(setting("preset"), setting("click_up"))
	elseif button == BUTTON_BOTTOM then
		set_brightness(0, setting("click_down"))
	elseif st.on then
		set_brightness(0, setting("click_down"))
	else
		set_brightness(setting("preset"), setting("click_up"))
	end
end

-- Hue has no "ramp until told to stop": the ramp is a timed target to the
-- end of the range, and the release writes the level the ramp had reached.
local function start_ramp()
	local dimming = hold.button == BUTTON_BOTTOM or (hold.button ~= BUTTON_TOP and st.on)
	local from = state.to_proxy_brightness(st) or 0
	local to = dimming and 1 or 100
	local full = setting(dimming and "hold_down" or "hold_up")
	local duration = math.floor(full * math.abs(to - from) / 100)
	hold.ramping, hold.level, hold.to = true, from, to
	hold.step = (to - from) / math.max(1, duration / HOLD_TICK_MS)
	hold.timer = C4:SetTimer(HOLD_TICK_MS, function()
		if not hold or not hold.ramping then
			return
		end
		hold.level = hold.level + hold.step
		if (hold.step >= 0 and hold.level >= hold.to) or (hold.step < 0 and hold.level <= hold.to) then
			hold.level = hold.to
			hold.timer:Cancel()
		end
	end, true)
	set_brightness(to, duration)
end

local function stop_ramp()
	local level = math.floor(hold.level + 0.5)
	end_hold()
	set_brightness(level, 0)
end

local function button_action(button, action)
	if action == ACT_PRESS then
		end_hold()
		hold = { button = button }
		hold.timer = C4:SetTimer(HOLD_AFTER_MS, function()
			if hold and hold.button == button and not hold.ramping then
				start_ramp()
			end
		end)
	elseif action == ACT_CLICK then
		if hold and hold.ramping then
			stop_ramp()
		else
			end_hold()
			click(button)
		end
	elseif action == ACT_RELEASE then
		-- Release after a hold: stop the ramp; a release that follows a click
		-- has nothing left to do.
		if hold and hold.ramping then
			stop_ramp()
		else
			end_hold()
		end
	end
end

-- The proxy's own route (BUTTON_ACTION on the proxy binding) carries the
-- button in the parameters and wants every action echoed.
dispatch.proxy["BUTTON_ACTION"] = function(_, params)
	local button, action = tonumber(params.BUTTON_ID), tonumber(params.ACTION)
	if not button or not action then
		return log.warn("BUTTON_ACTION without BUTTON_ID/ACTION")
	end
	notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = action })
	button_action(button, action)
end

-- A keypad button bound to one of the driver's Button Link connections
-- (driver.xml ids 200 top, 201 bottom, 202 toggle) delivers DO_PUSH,
-- DO_RELEASE and DO_CLICK on that binding [verified: public light_v2
-- drivers].
local LINK_BUTTON = { [200] = 0, [201] = 1, [202] = 2 }

local function link_button(binding, command)
	local button = LINK_BUTTON[tonumber(binding)]
	if not button then
		log.warn("%s on binding %s: not a Button Link", command, tostring(binding))
	end
	return button
end

dispatch.proxy["DO_PUSH"] = function(binding)
	local button = link_button(binding, "DO_PUSH")
	if button then button_action(button, ACT_PRESS) end
end

dispatch.proxy["DO_RELEASE"] = function(binding)
	local button = link_button(binding, "DO_RELEASE")
	if button then button_action(button, ACT_RELEASE) end
end

dispatch.proxy["DO_CLICK"] = function(binding)
	local button = link_button(binding, "DO_CLICK")
	if button then button_action(button, ACT_CLICK) end
end

dispatch.proxy["SET_PRESET_LEVEL"] = function(_, params) save_setting("preset", params.LEVEL) end
dispatch.proxy["SET_CLICK_RATE_UP"] = function(_, params) save_setting("click_up", params.RATE) end
dispatch.proxy["SET_CLICK_RATE_DOWN"] = function(_, params) save_setting("click_down", params.RATE) end
dispatch.proxy["SET_HOLD_RATE_UP"] = function(_, params) save_setting("hold_up", params.RATE) end
dispatch.proxy["SET_HOLD_RATE_DOWN"] = function(_, params) save_setting("hold_down", params.RATE) end

-- Lifecycle ----------------------------------------------------------------

log.set_prefix(LOG_PREFIX)
dispatch.install(_G)

function OnDriverInit()
end

-- After a Director restart the binding to the bridge can be invisible to
-- GetBoundProviderDevice at late init although Composer shows it, and no
-- OnBindingChanged follows, so the device read "Not bound to a Hue Bridge"
-- until something else woke it [hardware 2026-10-22, docs/keypad-design.md].
-- While unbound it looks again a few times, then gives up quietly; a binding
-- event or a bridge found ends the retries.
local RECHECK_MS = { 5000, 10000, 15000, 30000 }  -- gaps: checks at 5, 15, 30 and 60 s
local recheck_timer = nil

local function cancel_recheck()
	if recheck_timer then
		recheck_timer:Cancel()
		recheck_timer = nil
	end
end

local function schedule_recheck(attempt)
	cancel_recheck()
	local delay = RECHECK_MS[attempt]
	if not delay then
		return log.info("still not bound to a Hue Bridge %d s after start; waiting for a binding", 60)
	end
	recheck_timer = C4:SetTimer(delay, function()
		recheck_timer = nil
		if bridge then
			return
		end
		local found = bound_bridge()
		if found then
			log.info("bridge binding visible after %d checks; greeting device %d", attempt, found)
			hello()
			report_online()
		else
			schedule_recheck(attempt + 1)
		end
	end)
end

function OnDriverLateInit()
	late_init_done = true
	load_identity()
	load_settings()
	dispatch.replay_properties(Properties)
	prop("Hue Light ID", light_id_label())
	-- The bridge first, so messages it sent before this point are applied
	-- against the right binding state; then the hello carries whatever
	-- identity they delivered.
	bridge = bound_bridge()
	drain_early()
	hello()
	report_online()
	if not bridge then
		schedule_recheck(1)
	end
end

-- Control bindings only; the bridge binding is one, the proxy's is not.
function OnBindingChanged(idBinding, _, bound, otherDevice)
	if idBinding ~= BRIDGE_BINDING then
		return
	end
	cancel_recheck()
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

-- Composer is deleting this device: tell the bridge, so it tombstones the
-- entry instead of fanning state out to a dead id [verified: API 22/_26;
-- that SendToDevice still works here is assumed, docs/import-design.md
-- probe 2]. OnDriverDestroyed follows and stops the timers.
function OnDriverRemovedFromProject()
	if not bridge then
		return
	end
	local target = bridge
	local ok, err = pcall(function()
		C4:SendToDevice(target, "HUE_GOODBYE", { rid = st.rid, device_id = device_id() })
	end)
	if ok then
		log.debug("HUE_GOODBYE sent to bridge %d", target)
	else
		log.warn("HUE_GOODBYE failed: %s", tostring(err))
	end
end

function OnDriverDestroyed()
	settle("brightness")
	settle("color")
	end_hold()
	cancel_recheck()
end
