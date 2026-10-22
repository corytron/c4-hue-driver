-- Hue Scene driver: one light_v2 switch per Hue scene. ON recalls the scene,
-- OFF turns the scene's group off, and the bridge's scene status (active /
-- inactive) is mirrored as brightness 100 / 0. It never speaks to the bridge
-- itself: commands go to the Hue Bridge driver it is bound to (consumer
-- binding 1, class HUE_BRIDGE) with C4:SendToDevice, and the bridge pushes
-- configuration and state back through ExecuteCommand. The message contract
-- is docs/scenes-design.md §2, this device §3; the structure is the Hue Light
-- driver's (src/hue_light/driver.lua) with everything colour and dimming
-- specific left out.

local log = require("common.log")
local dispatch = require("common.dispatch")

-- Dev builds only (tools/build.sh --dev ships common/devloop.lua): the bridge
-- forwards this driver's new code as DEV_RELOAD, see docs/dev-loop.md.
-- Release builds have no such module, so this is nil.
local devloop_ok, devloop = pcall(require, "common.devloop")
if not devloop_ok then
	-- Absent in release builds (expected); anything else is a real error
	-- that must be visible, since the loop is how the controller gets tested.
	if not tostring(devloop):find("not found", 1, true) then
		print("[ERROR] Hue Scene: dev loop failed to load: " .. tostring(devloop))
	end
	devloop = nil
end

-- Binding IDs, see driver.xml.
local PROXY_BINDING = 5001
local BRIDGE_BINDING = 1

-- The dev loop's name for this driver's source tree (docs/scenes-design.md §6).
local DEV_TREE = "scene"

-- How long a recall or off waits for the bridge's HUE_SCENE_STATE before the
-- requested state is assumed, so the UI never sticks in "changing". The
-- bridge normally answers within a few hundred ms (its own STATE right after
-- the PUT succeeded, then the stream's scene item).
local FALLBACK_MS = 2000

-- Prefix of every line this driver logs; the dev-build log forwarding below
-- recognises its own lines by it.
local LOG_PREFIX = "Hue Scene"

-- Lines logged before the bridge is known wait for hello(); only this many.
local LOG_BUFFER = 30

-- Recall As property value -> the recall action the bridge sends to Hue.
local RECALL_ACTIONS = {
	["As set in Hue"] = "active",
	["Static"] = "static",
	["Dynamic"] = "dynamic_palette",
}
local DEFAULT_RECALL = "active"

-- Hue's scene status values; anything else in a HUE_SCENE_STATE is ignored.
local ACTIVE_VALUES = { inactive = true, static = true, dynamic_palette = true }

-- The scene's own copy of its identity (PersistSetValue key per state field),
-- so a bridge that lost its registry can rebuild it from the devices instead
-- of importing them a second time (docs/import-design.md §1, rule 3). The
-- Recall As choice is persisted separately under "recall_as" by its handler.
local PERSISTED = { rid = "hue_rid", name = "hue_name" }

local st = {
	rid = nil,            -- Hue scene resource id; the key in every message
	name = nil,
	group_name = nil,     -- the scene's room or zone, nil while unknown
	group_type = nil,     -- "room" / "zone" / "bridge_home"
	id_v1 = nil,          -- "/scenes/AbCdEf", nil while unknown
	auto_dynamic = false, -- Hue plays this scene's palette when recalled "active"
	configured = false,   -- a HUE_SCENE_CONFIGURE has arrived since load
	gone = false,         -- the bridge reports the scene no longer exists on it
	gone_since = nil,     -- unix time the bridge entered that state, when it said
	forgotten = nil,      -- { name } after HUE_SCENE_FORGOTTEN, until the next configure
	active = nil,         -- "inactive" / "static" / "dynamic_palette"; nil until reported
}
local recall_action = DEFAULT_RECALL
local bridge = nil           -- device id of the bound Hue Bridge driver, or nil
local pending = nil          -- { timer, assume, on } while a recall/off awaits its STATE
local late_init_done = false -- UpdateProperty and SendToProxy are unsafe before OnDriverLateInit
local early = {}             -- bridge messages received before late init, in arrival order

-- Dev log forwarding -------------------------------------------------------

-- Dev builds: every line this driver logs, debug excepted, also goes to the
-- bridge as HUE_LOG { rid, line }, so the dev loop shows the scenes' output
-- next to the bridge's own (docs/dev-loop.md). Release builds leave log.sink
-- alone. Lines logged before the bridge is known wait, newest LOG_BUFFER
-- kept, and go out from hello().
local flush_log = function() end

if devloop then
	local previous_sink = log.sink
	local original_print = print
	local waiting = {}
	local send_failed = false

	-- Only lines our own logger produced: "[LEVEL] Hue Scene: ..." or, from
	-- log.always, "Hue Scene: ...". On the controller that is every line;
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
			waiting[#waiting + 1] = line
			if #waiting > LOG_BUFFER then
				table.remove(waiting, 1)
			end
		end
	end

	flush_log = function()
		local lines = waiting
		waiting = {}
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

-- Parsing ------------------------------------------------------------------

-- A string param, or nil when absent or empty (SendToDevice drops empty
-- values, so "" never arrives; an absent key is the same thing).
local function text(v)
	if v == nil or v == "" then
		return nil
	end
	return tostring(v)
end

local function to_bool(v)
	if type(v) == "boolean" then
		return v
	end
	v = v ~= nil and tostring(v):lower() or nil
	if v == "true" or v == "1" then
		return true
	elseif v == "false" or v == "0" then
		return false
	end
	return nil
end

-- Identity and status texts ------------------------------------------------

-- Every inter-driver param is a string.
local function device_id()
	return tostring(C4:GetDeviceID())
end

-- "#AbCdEf" from Hue's v1 id (the bridge sends "/scenes/AbCdEf" or "AbCdEf"), or nil.
local function v1_label()
	local tail = st.id_v1 and st.id_v1:match("([^/%s]+)%s*$")
	return tail and ("#" .. tail) or nil
end

-- What Hue Scene ID shows: "#AbCdEf (0f3a2b1c…)" once the v1 id is known,
-- the rid alone until then. A rid without dashes (not a UUID) is shown whole.
local function scene_id_label()
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

-- "Kitchen", "Downstairs (zone)", "Home (bridge home)"; nil while the bridge
-- has not named a group (the lights' groups:label wording).
local function group_label()
	if not st.group_name then
		return nil
	end
	if st.group_type == "zone" then
		return st.group_name .. " (zone)"
	elseif st.group_type == "bridge_home" then
		return st.group_name .. " (bridge home)"
	end
	return st.group_name
end

local function forgotten_status()
	return string.format("Forgotten by the bridge (was Hue scene %s). "
		.. "Delete this device in Composer, or bind it again and use Link Devices",
		st.forgotten.name or st.rid or "unknown")
end

local function gone_status()
	local since = st.gone_since and (" since " .. os.date("%Y-%m-%d %H:%M", st.gone_since)) or ""
	return "Scene deleted in Hue" .. since .. "; ON does nothing; re-link or Forget"
end

-- Why a command cannot reach the scene right now, or nil when it can. The
-- order is the order Status explains things in: a forgotten scene is told
-- what to do even while its binding is already gone.
local function blocker()
	if st.forgotten then
		return "forgotten by the bridge; delete this device or bind it again and use Link Devices"
	elseif not bridge then
		return "not bound to a Hue Bridge"
	elseif not st.rid then
		return "waiting for the bridge to assign a Hue scene (use Add Scene or Link Devices on it)"
	elseif st.gone then
		return "scene deleted in Hue; re-link or Forget"
	end
	return nil
end

-- What ONLINE_CHANGED carries: reachable through a bridge that knows us.
local function is_online()
	return blocker() == nil
end

local function refresh_status()
	if st.forgotten then
		prop("Status", forgotten_status())
	elseif not bridge then
		prop("Status", "Not bound to a Hue Bridge")
	elseif st.gone then
		prop("Status", gone_status())
	elseif st.configured and st.name then
		prop("Status", string.format("Hue scene %s in %s", st.name, group_label() or "(no room)"))
	elseif st.rid and st.name then
		prop("Status", st.name) -- the persisted copy, until the bridge answers
	else
		prop("Status", "Bound; waiting for the bridge")
	end
	-- "" while nothing says either way: bound, but the bridge has not reported.
	if not is_online() then
		prop("Online", "Offline")
	else
		prop("Online", st.configured and "Online" or "")
	end
end

-- State and proxy notifies -------------------------------------------------

local function is_on()
	return st.active == "static" or st.active == "dynamic_palette"
end

-- LIGHT_BRIGHTNESS_CURRENT for a switch: 100 while the scene is active, 0
-- while inactive, nil until the bridge has reported.
local function brightness()
	if st.active == nil then
		return nil
	end
	return is_on() and 100 or 0
end

-- The report_* functions return true when they had something to report.
local function report_brightness()
	local level = brightness()
	if not level then
		return false
	end
	notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level })
	return true
end

local function report_online()
	notify("ONLINE_CHANGED", { STATE = is_online() })
	return true
end

-- The status an ON is expected to end in, for the fallback and for a stop
-- before any report: what Hue would do with that recall action.
local function assumed_active(action)
	if action == "dynamic_palette" then
		return "dynamic_palette"
	elseif action == "static" then
		return "static"
	end
	return st.auto_dynamic and "dynamic_palette" or "static"
end

-- Targets ------------------------------------------------------------------

-- A recall or off sent to the bridge stays pending until a HUE_SCENE_STATE
-- arrives, its fallback fires, or the proxy says stop; either way the proxy
-- gets a CHANGED after its CHANGING.
local function settle()
	if pending then
		pending.timer:Cancel()
		pending = nil
	end
end

-- `assume` applies the sent target to the cache and reports it; it runs when
-- the bridge has not confirmed within FALLBACK_MS.
local function arm(on, assume)
	settle()
	local p = { on = on, assume = assume }
	p.timer = C4:SetTimer(FALLBACK_MS, function() -- [verified: API 34/_1]
		pending = nil
		assume()
	end)
	pending = p
end

-- True when a proxy command can be acted on; otherwise it is dropped here,
-- with Status saying why. A scene deleted in Hue is the one case that still
-- answers: it warns and reports OFF at once (docs/scenes-design.md §1,
-- Lifecycle), so a UI that asked for ON sees the switch stay off.
local function ready(command)
	local why = blocker()
	if not why then
		return true
	end
	refresh_status()
	if st.gone then
		log.warn("%s dropped: %s", command, why)
		st.active = "inactive"
		report_brightness()
	else
		log.info("%s dropped: %s", command, why)
	end
	return false
end

local function turn_on(rate)
	rate = tonumber(rate) or 0
	if not ready("ON") then
		return
	end
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = 0,
		LIGHT_BRIGHTNESS_TARGET = 100,
		RATE = rate,
	})
	local action = recall_action
	log.info("ON: recalling as %s", action)
	local params = { rid = st.rid, action = action }
	if rate > 0 then
		params.duration = string.format("%d", rate)
	end
	C4:SendToDevice(bridge, "HUE_SCENE_RECALL", params)
	arm(true, function()
		log.debug("recall (%s) unconfirmed after %d ms; assuming the scene is on", action, FALLBACK_MS)
		st.active = assumed_active(action)
		report_brightness()
	end)
end

local function turn_off(rate)
	rate = tonumber(rate) or 0
	if not ready("OFF") then
		return
	end
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = 100,
		LIGHT_BRIGHTNESS_TARGET = 0,
		RATE = rate,
	})
	C4:SendToDevice(bridge, "HUE_SCENE_OFF", { rid = st.rid })
	arm(false, function()
		log.debug("off unconfirmed after %d ms; assuming the scene is off", FALLBACK_MS)
		st.active = "inactive"
		report_brightness()
	end)
end

-- A brightness target is a switch position: anything above 0 is ON.
local function set_target(target, rate)
	target = tonumber(target)
	if not target then
		return log.warn("brightness command without a target")
	end
	if target > 0 then
		turn_on(rate)
	else
		turn_off(rate)
	end
end

-- SET_BRIGHTNESS_STOP: the proxy wants the transition closed now. The cached
-- state goes out as CHANGED (the bridge's next real report corrects it if
-- need be). With nothing cached yet the target is assumed, as the fallback
-- would have, so the proxy never waits on a CHANGING.
local function stop()
	local p = pending
	settle()
	if not report_brightness() and p then
		p.assume()
	end
end

-- Bridge binding -----------------------------------------------------------

-- The bound bridge's device id. The API documents a table of id/name pairs,
-- the idc_client sample uses the result as a number: accept both.
local function bound_bridge()
	local found = C4:GetBoundProviderDevice(C4:GetDeviceID(), BRIDGE_BINDING) -- [verified: API 32/_4]
	if type(found) == "table" then
		found = next(found)
	end
	-- Nothing bound: the docs say nil, OS 3.4.2 answers 0 [hardware 2026-10-22].
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

-- What HUE_SCENE_HELLO carries: the persisted identity, so the bridge can
-- adopt a bound scene device its registry lacks. Absent keys for what is
-- unknown: a rid-less device sends no rid (SendToDevice drops empty values).
local function hello_params()
	return { rid = st.rid, device_id = device_id(), name = st.name }
end

-- Announce ourselves; the bridge answers with HUE_SCENE_CONFIGURE and the
-- scene's status when it knows the rid. `hint` is the device id
-- OnBindingChanged named, for when Director's lookup does not reflect the
-- new binding yet.
local function hello(hint)
	bridge = bound_bridge() or tonumber(hint)
	if bridge then
		C4:SendToDevice(bridge, "HUE_SCENE_HELLO", hello_params())
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

-- The owner's choice of recall action; the action word is what gets
-- persisted, so a bridge rebuilding its registry reads what Hue is told.
dispatch.properties["Recall_As"] = function(value)
	local action = RECALL_ACTIONS[value]
	if not action then
		if value ~= nil and value ~= "" then
			log.warn("Recall As %q is not a known choice; using \"As set in Hue\"", tostring(value))
		end
		action = DEFAULT_RECALL
	end
	recall_action = action
	C4:PersistSetValue("recall_as", action)
	log.info("Recall As %q -> recall action %s", tostring(value), action)
end

-- From the bridge (ExecuteCommand) -------------------------------------------

-- Director late-inits drivers in no particular order, so the bridge's
-- messages can reach a scene device before its own OnDriverLateInit, where
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

-- The bridge builds every configure from its whole registry entry, so the
-- group and lifecycle fields are taken as sent and reset when absent. A
-- configure also ends a forgotten state: the bridge knows the scene again.
dispatch.commands["HUE_SCENE_CONFIGURE"] = after_late_init("HUE_SCENE_CONFIGURE", function(params)
	params = params or {}
	if text(params.rid) then
		st.rid = params.rid
	end
	st.name = text(params.name) or st.name
	st.group_name = text(params.group_name)
	st.group_type = text(params.group_type)
	st.id_v1 = text(params.id_v1)
	local b = to_bool(params.auto_dynamic)
	if b ~= nil then st.auto_dynamic = b end
	st.gone = params.state == "gone"
	st.gone_since = st.gone and tonumber(params.gone_since) or nil
	st.forgotten = nil
	st.configured = true
	save_identity()
	prop("Hue Scene ID", scene_id_label())
	prop("Hue Scene", st.name)
	prop("Hue Room", group_label())
	if st.gone then
		log.debug("configured as deleted in Hue%s", st.gone_since and (" since " .. st.gone_since) or "")
	end
	report_brightness() -- the proxy hears the cached status again, if any
	report_online()
	refresh_status()
end)

-- Every scene status the bridge learns. A report settles a pending recall or
-- off whatever the value: the proxy heard CHANGING and must hear CHANGED.
-- Otherwise only a change reaches the proxy.
dispatch.commands["HUE_SCENE_STATE"] = after_late_init("HUE_SCENE_STATE", function(params)
	params = params or {}
	if st.rid and params.rid and params.rid ~= st.rid then
		return log.warn("HUE_SCENE_STATE for rid %s ignored (ours is %s)", params.rid, st.rid)
	end
	if not ACTIVE_VALUES[params.active] then
		return log.warn("HUE_SCENE_STATE without a known status (%s) ignored", tostring(params.active))
	end
	local before = brightness()
	st.active = params.active
	if pending then
		settle()
		report_brightness()
	elseif brightness() ~= before then
		report_brightness()
	end
end)

-- The bridge ran Forget for this scene (from its own action or ours): the
-- device stays, the owner decides. The identity stays persisted too, so
-- binding the device again lets the bridge adopt it from its own rid.
dispatch.commands["HUE_SCENE_FORGOTTEN"] = after_late_init("HUE_SCENE_FORGOTTEN", function(params)
	params = params or {}
	if st.rid and params.rid and params.rid ~= st.rid then
		return log.warn("HUE_SCENE_FORGOTTEN for rid %s ignored (ours is %s)", params.rid, st.rid)
	end
	st.forgotten = { name = text(params.name) or st.name }
	settle()
	log.warn("forgotten by the bridge (was Hue scene %s)", st.forgotten.name or st.rid or "unknown")
	prop("Last Action", "Forgotten by the bridge")
	refresh_status()
	report_online()
end)

-- Dev-only: dump what Director's Properties table holds and what this
-- driver believes, for the dev loop (the bridge sends it with SendToDevice).
dispatch.commands["HUE_DUMP"] = function()
	local parts = {}
	for k, v in pairs(Properties or {}) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
	table.sort(parts)
	log.always("Properties: %s", table.concat(parts, " | "))
	log.always("state: rid=%s name=%s configured=%s active=%s recall_action=%s debug=%s", tostring(st.rid),
		tostring(st.name), tostring(st.configured), tostring(st.active), tostring(recall_action),
		tostring(log.enabled("debug")))
end

dispatch.commands["DEV_RELOAD"] = function(params)
	params = params or {}
	if not (devloop and devloop.apply_forwarded) then
		return log.warn("DEV_RELOAD ignored: no dev loop in this build")
	end
	-- The bridge forwards every non-bridge tree to everything on binding 1;
	-- only our own tree is ours to apply (docs/scenes-design.md §6).
	if params.tree and params.tree ~= DEV_TREE then
		return log.debug("DEV_RELOAD for tree %s ignored", tostring(params.tree))
	end
	-- On success the new code is already running; this handler, its log
	-- module and its bridge id are the old instance's, still good for one
	-- more line. The failure detail went through devloop's own print, which
	-- is not forwarded.
	if devloop.apply_forwarded(params) then
		log.always("scene reloaded to version %s", tostring(params.version))
	else
		log.warn("scene reload failed; see this scene's Lua output")
	end
end

-- Composer actions (LUA_ACTION) ----------------------------------------------
-- Every click ends in Last Action and a log line, whatever happened.

local function result(fmt_text)
	log.always("%s", fmt_text)
	prop("Last Action", fmt_text)
end

-- Rename our proxy (the device Composer shows) to the Hue scene name. Only
-- ever from this click: names belong to the owner (docs/import-design.md §7).
dispatch.commands["Adopt_Hue_Name"] = function()
	if not st.name then
		return result("Not renamed: no Hue name known yet (the bridge has not configured this scene)")
	end
	local id = proxy_id()
	if not id then
		return result("Not renamed: no light_v2 proxy is bound to binding 5001")
	end
	-- The name the bridge gives a scene device at creation (docs/scenes-design.md
	-- §1): the scene's own name in a room, the zone's name in front for a zone.
	local name = st.name
	if st.group_type == "zone" and st.group_name then
		name = st.group_name .. " " .. st.name
	end
	C4:RenameDevice(id, name) -- [verified: API 22/_32]
	result(string.format("Renamed device %d to %s", id, name))
end

-- Ask the bridge to Forget this scene; it answers HUE_SCENE_FORGOTTEN, which
-- sets Status. The bridge finds the entry by rid or, for a rid-less device,
-- by device id.
dispatch.commands["Forget_This_Scene"] = function()
	if not bridge then
		return result("Not sent: not bound to a Hue Bridge")
	end
	C4:SendToDevice(bridge, "HUE_SCENE_FORGET", { rid = st.rid, device_id = device_id() })
	result("Asked the bridge to forget this scene; its answer sets Status")
end

-- From the proxy (ReceivedFromProxy) ------------------------------------------
-- Commands without a handler are logged at debug by common.dispatch.

-- The proxy asks for current state after Director starts or a UI connects.
dispatch.proxy["SYNCHRONIZE"] = function()
	report_online()
	report_brightness()
end

-- With supports_target the proxy sends LIGHT_BRIGHTNESS_TARGET and RATE
-- [verified: proxy ref, SET_BRIGHTNESS_TARGET]; here a target is a switch
-- position, and RATE becomes the recall's transition.
dispatch.proxy["SET_BRIGHTNESS_TARGET"] = function(_, params)
	set_target(params.LIGHT_BRIGHTNESS_TARGET, params.RATE)
end

-- Advanced Lighting Scenes with reduced_als_support drive the switch with
-- SET_BRIGHTNESS_TARGET and end a scene ramp with these; both carry no
-- parameters [verified: proxy ref, SET_BRIGHTNESS_STOP, reduced_als_support,
-- supports_brightness_stop]. Nothing goes to the bridge: a scene recall
-- cannot be stopped, the proxy only needs its CHANGED.
dispatch.proxy["SET_BRIGHTNESS_STOP"] = function()
	stop()
end

-- The ALS section lists STOP_SCENE_RAMP among what a reduced-ALS driver must
-- support; whether the proxy forwards it under that name is unverified, so it
-- is accepted as a brightness stop.
dispatch.proxy["STOP_SCENE_RAMP"] = dispatch.proxy["SET_BRIGHTNESS_STOP"]

-- Toggle relative to where the switch is heading: a pending recall counts as
-- on, so two quick presses end up off [verified: proxy ref, TOGGLE].
dispatch.proxy["TOGGLE"] = function()
	local on
	if pending then
		on = pending.on
	else
		on = is_on()
	end
	if on then
		turn_off(0)
	else
		turn_on(0)
	end
end

dispatch.proxy["ON"] = function() turn_on(0) end
dispatch.proxy["OFF"] = function() turn_off(0) end

-- Keypad buttons: a click or release of the top button recalls, of the
-- bottom button turns the group off, of the toggle button toggles; holds do
-- nothing. Every action is echoed as the proxy requires [verified:
-- proxy-protocol reference, light_v2 BUTTON_ACTION]; docs/keypad-design.md.
local function button_click(button)
	if button == 0 then
		turn_on(0)
	elseif button == 1 then
		turn_off(0)
	else
		dispatch.proxy["TOGGLE"]()
	end
end

dispatch.proxy["BUTTON_ACTION"] = function(_, params)
	local button, action = tonumber(params.BUTTON_ID), tonumber(params.ACTION)
	if not button or not action then
		return log.warn("BUTTON_ACTION without BUTTON_ID/ACTION")
	end
	notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = action })
	if action == 2 then
		button_click(button)
	end
end

-- Keypad buttons bound to the driver's Button Link connections (200 top,
-- 201 bottom, 202 toggle) deliver DO_PUSH / DO_RELEASE / DO_CLICK on the
-- binding; only the click acts [verified: public light_v2 drivers].
local LINK_BUTTON = { [200] = 0, [201] = 1, [202] = 2 }

dispatch.proxy["DO_CLICK"] = function(binding)
	local button = LINK_BUTTON[tonumber(binding)]
	if button then
		button_click(button)
	else
		log.warn("DO_CLICK on binding %s: not a Button Link", tostring(binding))
	end
end
dispatch.proxy["DO_PUSH"] = function() end
dispatch.proxy["DO_RELEASE"] = function() end

-- Legacy commands that old programming may still send.
dispatch.proxy["SET_LEVEL"] = function(_, params) set_target(params.LEVEL, params.TIME) end
dispatch.proxy["RAMP_TO_LEVEL"] = function(_, params) set_target(params.LEVEL, params.TIME) end

-- Lifecycle ----------------------------------------------------------------

log.set_prefix(LOG_PREFIX)
dispatch.install(_G)

function OnDriverInit()
end

function OnDriverLateInit()
	late_init_done = true
	load_identity()
	dispatch.replay_properties(Properties)
	prop("Hue Scene ID", scene_id_label())
	prop("Hue Scene", st.name)
	-- The bridge first, so messages it sent before this point are applied
	-- against the right binding state; then the hello carries whatever
	-- identity they delivered.
	bridge = bound_bridge()
	drain_early()
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
		settle()
		refresh_status()
		report_online()
	end
end

-- Composer is deleting this device: tell the bridge, so it tombstones the
-- entry instead of fanning state out to a dead id [verified: API 22/_26;
-- that SendToDevice still works here is assumed, docs/import-design.md
-- probe 2]. OnDriverDestroyed follows and stops the timer.
function OnDriverRemovedFromProject()
	if not bridge then
		return
	end
	local target = bridge
	local ok, err = pcall(function()
		C4:SendToDevice(target, "HUE_SCENE_GOODBYE", { rid = st.rid, device_id = device_id() })
	end)
	if ok then
		log.debug("HUE_SCENE_GOODBYE sent to bridge %d", target)
	else
		log.warn("HUE_SCENE_GOODBYE failed: %s", tostring(err))
	end
end

function OnDriverDestroyed()
	settle()
end
