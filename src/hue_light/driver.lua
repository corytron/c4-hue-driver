-- Hue Light driver: one light_v2 proxy per Hue light. The same driver, told
-- kind "group" by its configure, stands for a Hue zone or room through its
-- grouped_light (docs/zone-light-design.md): the proxy, keypad, LED and
-- lifecycle behaviour is the same, only the identity texts and the hello
-- know the difference. It never speaks to the bridge itself: commands go to
-- the Hue Bridge driver it is bound to (consumer binding 1, class
-- HUE_BRIDGE) with C4:SendToDevice, and the bridge pushes configuration and
-- state back through ExecuteCommand. The message contract is in
-- docs/lights-design.md, docs/import-design.md §4/§13 and
-- docs/zone-light-design.md §5; the light_v2 facts in docs/design.md.

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
-- of importing them a second time (docs/import-design.md §1, rule 3). The
-- kind is part of it (docs/zone-light-design.md §2): a zone or room device
-- persists "group" and the bridge routes its hello on it; a light persists
-- none, as every light did before zone lights existed.
local PERSISTED = { rid = "hue_rid", name = "hue_name", model = "hue_model", kind = "hue_kind" }

-- What a forgotten device's owner can do; a light's Status says it, a group
-- device's Last Action (its Status names the group instead).
local FORGOTTEN_INSTRUCTION = "Delete this device in Composer, or bind it again and use Link Devices"

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

-- "#12" from Hue's v1 id (the bridge sends "/lights/12" or "12"; "/groups/2"
-- for a zone or room), or nil.
local function v1_label()
	local num = st.id_v1 and st.id_v1:match("(%d+)%s*$")
	return num and ("#" .. num) or nil
end

-- Zone and room devices (kind "group", docs/zone-light-design.md §5
-- "Composer properties"): the texts name what the device stands for. Every
-- text stays under about 60 characters where the name allows, since
-- Composer clips a property at about 75.

-- "Hue light"; for a group "Hue zone" / "Hue room" from the configure's
-- group_type, else the model the bridge sent (which reads the same, and is
-- persisted, so the text is right before the bridge answers after a start).
local function kind_label()
	if not state.is_group(st) then
		return "Hue light"
	elseif st.group_type then
		return "Hue " .. st.group_type
	end
	return st.model or "Hue group"
end

-- "light", "zone light", "room light": what this device is, for the action texts.
local function what()
	if not state.is_group(st) then
		return "light"
	end
	return (st.group_type or "group") .. " light"
end

-- "Zone" / "Room" ("Group" while the type is unknown) for a group device.
local function group_word()
	local t = st.group_type or "group"
	return t:sub(1, 1):upper() .. t:sub(2)
end

-- " (2 lights)" / " (1 light)" after a group's name or model; "" while the
-- count is unknown, " (no lights)" when the bridge says so without a count.
local function count_suffix()
	if st.light_count then
		local n = math.floor(st.light_count)
		return string.format(" (%d light%s)", n, n == 1 and "" or "s")
	elseif st.no_lights then
		return " (no lights)"
	end
	return ""
end

-- What Hue Light ID shows: "#12 (e0e51794…)" once the v1 id is known, the
-- rid alone until then; a group's says what it is: "zone #2 (b90ea7b4…)".
-- A rid without dashes (not a UUID) is shown whole.
local function light_id_label()
	if not st.rid then
		return ""
	end
	local v1 = v1_label()
	if not v1 then
		return st.rid
	end
	local head = st.rid:match("^([^-]+)-")
	local label = string.format("%s (%s)", v1, head and (head .. "…") or st.rid)
	if state.is_group(st) then
		label = (st.group_type or "group") .. " " .. label
	end
	return label
end

-- What Model shows: the bulb's model; for a group "Hue zone (2 lights)".
local function model_label()
	if not state.is_group(st) then
		return st.model
	end
	return kind_label() .. count_suffix()
end

-- "Desk Lamp #12" (a group: its name alone), or whatever part of that is
-- known, for the forgotten text.
local function light_label(name)
	local parts = {}
	name = name or st.name
	if name then parts[#parts + 1] = name end
	local v1 = not state.is_group(st) and v1_label() or nil
	if v1 then parts[#parts + 1] = v1 end
	if #parts == 0 then
		return st.rid or "unknown"
	end
	return table.concat(parts, " ")
end

-- "Hue light Desk #12" / "Hue zone Bedside Lights": what a forgotten device was.
local function was_label()
	return kind_label() .. " " .. light_label(st.forgotten.name)
end

-- A light's Status carries the instruction too; a group's names the group
-- and leaves the instruction to Last Action, so the text fits the column.
local function forgotten_status()
	if state.is_group(st) then
		return string.format("Forgotten by the bridge (was %s)", was_label())
	end
	return string.format("Forgotten by the bridge (was %s). %s", was_label(), FORGOTTEN_INSTRUCTION)
end

-- "Gone from the Hue bridge since 2026-10-24 12:00; re-link or Forget" for a
-- light; "Zone deleted in Hue since 2026-10-24; re-link or Forget" for a group
-- (the day alone keeps it under 60 characters).
local function gone_status()
	if state.is_group(st) then
		local since = st.gone_since and (" since " .. os.date("%Y-%m-%d", st.gone_since)) or ""
		return group_word() .. " deleted in Hue" .. since .. "; re-link or Forget"
	end
	local since = st.gone_since and (" since " .. os.date("%Y-%m-%d %H:%M", st.gone_since)) or ""
	return "Gone from the Hue bridge" .. since .. "; re-link or Forget"
end

-- Decision 11: "Hue zone Bedside Lights has no lights; nothing to control".
local function no_lights_text()
	return string.format("%s %s has no lights; nothing to control", kind_label(), st.name or st.rid or "?")
end

-- Why a command cannot reach the light right now, or nil when it can. The
-- order is the order Status explains things in: a forgotten light is told
-- what to do even while its binding is already gone. A group with no lights
-- has no grouped_light to command (docs/zone-light-design.md Decision 11).
local function blocker()
	if st.forgotten then
		return "forgotten by the bridge; delete this device or bind it again and use Link Devices"
	elseif not bridge then
		return "not bound to a Hue Bridge"
	elseif not st.rid then
		return "waiting for the bridge to assign a Hue light (use Add Light or Link Devices on it)"
	elseif st.gone then
		if state.is_group(st) then
			return group_word():lower() .. " deleted in Hue; re-link or Forget"
		end
		return "gone from the Hue bridge; re-link or Forget"
	elseif st.no_lights then
		return no_lights_text()
	end
	return nil
end

-- What ONLINE_CHANGED carries: reachable through a bridge that knows us, and
-- not reported unreachable by Zigbee (a group: not without lights).
local function is_online()
	return blocker() == nil and st.online ~= false
end

-- "Desk (Hue color lamp)"; a group "Hue zone Bedside Lights (2 lights)".
local function identity_status()
	if state.is_group(st) then
		return kind_label() .. " " .. st.name .. count_suffix()
	end
	return string.format("%s (%s)", st.name, st.model or "unknown model")
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
	elseif st.no_lights then
		prop("Status", no_lights_text())
	else
		prop("Status", identity_status())
	end
	-- "" while nothing says either way: bound, but the bridge has not reported.
	if not bridge or st.forgotten or st.gone or st.no_lights or st.online == false then
		prop("Online", "Offline")
	else
		prop("Online", st.online and "Online" or "")
	end
end

-- Keypad LEDs ----------------------------------------------------------------
-- A keypad bound to a Button Link follows the light: MATCH_LED_STATE on each
-- link, and BUTTON_INFO per button to the proxy [verified: Snap One's
-- drivers-template-code-public c4hook_light_v2.lua, docs/keypad-design.md
-- "Keypad LEDs"; BUTTON_INFO fields: proxy ref, BUTTON_INFO notification].

-- Keypad buttons bound to the driver's Button Link connections (driver.xml
-- 200 top, 201 bottom, 202 toggle) -> BUTTON_ID.
local LINK_BUTTON = { [200] = 0, [201] = 1, [202] = 2 }
local LINK_BINDINGS = { 200, 201, 202 }
local BUTTON_LINK = { [0] = 200, [1] = 201, [2] = 202 }

-- Per-button colours: bottom is lit while the light is off.
local COLOR_DEFAULTS = {
	[0] = { on = "0000ff", off = "000000" },
	[1] = { on = "000000", off = "0000ff" },
	[2] = { on = "0000ff", off = "000000" },
}
local colors = { [0] = {}, [1] = {}, [2] = {} } -- persisted overrides, nil = default
local led_on = nil -- the on state the LEDs were last sent, nil before the first

-- "0000ff" from a 6-digit hex string, nil for anything else.
local function valid_color(v)
	v = v ~= nil and tostring(v) or ""
	if v:match("^%x%x%x%x%x%x$") then
		return v:lower()
	end
	return nil
end

local function color_key(button, which)
	return string.format("button_%d_%s_color", button, which)
end

local function button_color(button, which)
	return colors[button][which] or COLOR_DEFAULTS[button][which]
end

local function load_colors()
	for button in pairs(COLOR_DEFAULTS) do
		for _, which in ipairs({ "on", "off" }) do
			colors[button][which] = valid_color(C4:PersistGetValue(color_key(button, which)))
		end
	end
end

local function send_button_info(button, on)
	C4:SendToProxy(PROXY_BINDING, "BUTTON_INFO", {
		BUTTON_ID = button,
		ON_COLOR = button_color(button, "on"),
		OFF_COLOR = button_color(button, "off"),
		CURRENT_COLOR = button_color(button, on and "on" or "off"),
	}, "NOTIFY")
end

-- BUTTON_COLORS on a link: the colours of the button bound there, with the
-- same four fields as BUTTON_INFO [verified: Snap One c4hook_light_v2.lua,
-- NOTIFY.BTN_COLOR_CHANGED].
local function send_button_colors(binding, button)
	C4:SendToProxy(binding, "BUTTON_COLORS", {
		BUTTON_ID = button,
		ON_COLOR = button_color(button, "on"),
		OFF_COLOR = button_color(button, "off"),
		CURRENT_COLOR = button_color(button, (st.on == true) and "on" or "off"),
	}, "NOTIFY")
end

local function send_leds(on)
	led_on = on
	for _, binding in ipairs(LINK_BINDINGS) do
		C4:SendToProxy(binding, "MATCH_LED_STATE", { STATE = on }, "COMMAND")
	end
	for button = 0, 2 do
		send_button_info(button, on)
	end
end

-- The LEDs follow st.on once it is known; `force` resends an unchanged
-- state (a keypad was just bound to a link).
local function update_leds(force)
	if st.on == nil then
		return
	end
	local on = st.on == true
	if force or on ~= led_on then
		send_leds(on)
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
	update_leds()
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
-- light sends no rid, a light never told its kind no kind (SendToDevice drops
-- empty values anyway). A zone or room device says kind "group", which the
-- bridge routes on, and no model (docs/zone-light-design.md §5 Messages).
local function hello_params()
	local params = { rid = st.rid, device_id = device_id(), name = st.name, kind = st.kind }
	if not state.is_group(st) then
		params.model = st.model
	end
	return params
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
	if st.kind and not state.KINDS[st.kind] then
		log.warn("persisted kind %q is not one this build knows; taken as a light", st.kind)
		st.kind = nil
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

-- The kind a configure names ("group" for a zone or room, "light" or none for
-- a light) is kept by state.configure; this only says what happened. A later
-- configure also carries changed capabilities (lights added to or removed
-- from a group, Decision 7), which the notify below re-announces every time.
dispatch.commands["HUE_CONFIGURE"] = after_late_init("HUE_CONFIGURE", function(params)
	local before = st.kind
	state.configure(st, params)
	local named = params.kind
	if named ~= nil and named ~= "" and not state.KINDS[named] then
		log.warn("HUE_CONFIGURE with unknown kind %s ignored; still a %s", tostring(named), what())
	elseif before and st.kind ~= before then
		log.info("now a %s (was a %s)", what(), before == state.KIND_GROUP and "group light" or "light")
	end
	save_identity()
	prop("Hue Light ID", light_id_label())
	prop("Hue Name", st.name)
	prop("Model", model_label())
	prop("Hue Room", st.hue_room)
	if st.gone then
		log.debug("configured as %s%s", state.is_group(st) and "deleted in Hue" or "gone from the bridge",
			st.gone_since and (" since " .. st.gone_since) or "")
	elseif st.no_lights then
		log.debug("configured without lights; nothing to control until the group is refilled")
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
	log.warn("forgotten by the bridge (was %s)", was_label())
	-- A group's Status names the group, so the instruction goes here.
	prop("Last Action", state.is_group(st) and FORGOTTEN_INSTRUCTION or "Forgotten by the bridge")
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

-- The Composer name the Hue name calls for: the Hue name itself, except that
-- a room device is "<Room> Lights", so the Lighting page of a Control4 room
-- does not list a light named like the room (docs/zone-light-design.md §5
-- Naming; the bridge's Attention and Adopt Hue Names apply the same rule).
local function expected_name()
	if state.is_group(st) and st.group_type == "room" then
		return st.name .. " Lights"
	end
	return st.name
end

-- Rename our proxy (the device Composer shows) to the Hue name. Only ever
-- from this click: names belong to the owner (docs/import-design.md §7).
dispatch.commands["Adopt_Hue_Name"] = function()
	if not st.name then
		return result(string.format("Not renamed: no Hue name known yet (the bridge has not configured this %s)",
			what()))
	end
	local id = proxy_id()
	if not id then
		return result("Not renamed: no light_v2 proxy is bound to binding 5001")
	end
	local name = expected_name()
	C4:RenameDevice(id, name) -- [verified: API 22/_32]
	result(string.format("Renamed device %d to %s", id, name))
end

-- Ask the bridge to Forget this light (or zone/room device); it answers
-- HUE_FORGOTTEN, which sets Status. The bridge finds the entry by rid or,
-- for a rid-less light, by device id.
dispatch.commands["Forget_This_Light"] = function()
	if not bridge then
		return result("Not sent: not bound to a Hue Bridge")
	end
	C4:SendToDevice(bridge, "HUE_FORGET", { rid = st.rid, device_id = device_id() })
	result(string.format("Asked the bridge to forget this %s; its answer sets Status", what()))
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
local HOLD_AFTER_MS = 400       -- a press still down after this starts a ramp
local HOLD_TICK_MS = 100        -- the level estimate advances this often during a ramp
local RAMP_AFTER_ON_MS = 600    -- hold from off: the ramp follows the turn-on at 1 % this much later
local CLICK_GUARD_MS = 1000     -- a click this soon after a hold's release on that button is ignored
local SETTING_KEYS = { preset = "preset_level", click_up = "click_rate_up", click_down = "click_rate_down",
	hold_up = "hold_rate_up", hold_down = "hold_rate_down" }
local SETTING_DEFAULTS = { preset = 100, click_up = 250, click_down = 250, hold_up = 5000, hold_down = 5000 }
local settings = {}
local hold = nil  -- { button, timer, held, ramping, level, step, to } while a button is down
local guard = nil -- { button, timer } for CLICK_GUARD_MS after a hold's release

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

local function disarm_guard()
	if guard then
		guard.timer:Cancel()
		guard = nil
	end
end

local function arm_guard(button)
	disarm_guard()
	local g = { button = button }
	g.timer = C4:SetTimer(CLICK_GUARD_MS, function()
		if guard == g then
			guard = nil
		end
	end)
	guard = g
end

-- A hold uses Hue's own relative dim (HUE_DIM up / down to the bridge, a
-- grouped dimming_delta on the light), stopped by the release, as the scene
-- does; the proxy hears CHANGING toward the end of the range over the hold
-- rate scaled by the distance, and a 100 ms tick keeps an estimate of the
-- level for the stop and its fallback (docs/keypad-design.md).
local function start_ramp(h, up, from)
	local to = up and 100 or 1
	local full = setting(up and "hold_up" or "hold_down")
	local duration = math.floor(full * math.abs(to - from) / 100)
	h.ramping, h.level, h.to = true, from, to
	h.step = (to - from) / math.max(1, duration / HOLD_TICK_MS)
	h.timer = C4:SetTimer(HOLD_TICK_MS, function()
		if hold ~= h then
			return
		end
		h.level = h.level + h.step
		if (h.step >= 0 and h.level >= h.to) or (h.step < 0 and h.level <= h.to) then
			h.level = h.to
			h.timer:Cancel()
		end
	end, true)
	-- The ramp replaces whatever target was pending (the turn-on at 1 %).
	settle("brightness")
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = from,
		LIGHT_BRIGHTNESS_TARGET = to,
		RATE = duration,
	})
	log.debug("hold: dim %s from %d over %d ms", up and "up" or "down", from, duration)
	C4:SendToDevice(bridge, "HUE_DIM", { rid = st.rid, direction = up and "up" or "down",
		duration = string.format("%d", duration) })
end

-- The hold timer fired with the button still down: top (or toggle while
-- off) dims up, bottom (or toggle while on) down. From off, top turns the
-- light on at 1 % first and ramps up from there; bottom does nothing.
local function start_hold(h)
	h.held = true
	local on = st.on == true
	local up = h.button == BUTTON_TOP or (h.button ~= BUTTON_BOTTOM and not on)
	if not up and not on then
		return log.debug("hold: dimming down a light that is off does nothing")
	end
	if not ready("hold") then
		return
	end
	if on then
		return start_ramp(h, up, state.to_proxy_brightness(st) or 1)
	end
	set_brightness(1, 0)
	h.timer = C4:SetTimer(RAMP_AFTER_ON_MS, function()
		if hold ~= h then
			return
		end
		h.timer = nil
		if bridge and st.rid then
			start_ramp(h, true, st.on == true and state.to_proxy_brightness(st) or 1)
		end
	end)
end

-- Release (or release-as-click) after a hold: stop the dim at Hue, which
-- keeps the level it reached; `level` is the estimate, for the bridge to
-- write should Hue refuse the stop. The proxy hears the bridge's next
-- report, or the estimate after the fallback time. The click some keypads
-- send after a hold is ignored for a moment.
local function finish_hold()
	local h = hold
	end_hold()
	arm_guard(h.button)
	if not (h.ramping and bridge and st.rid) then
		return
	end
	local level = math.floor(h.level + 0.5)
	C4:SendToDevice(bridge, "HUE_DIM", { rid = st.rid, direction = "stop", level = string.format("%d", level) })
	arm("brightness", 0, function()
		log.debug("dim stop unconfirmed after %d ms; assuming %d %%", FALLBACK_MS, level)
		state.apply_hue(st, { on = "true", brightness = tostring(level) })
		report_brightness()
	end)
end

local function button_action(button, action)
	if action == ACT_PRESS then
		end_hold()
		local h = { button = button }
		h.timer = C4:SetTimer(HOLD_AFTER_MS, function()
			if hold == h then
				h.timer = nil
				start_hold(h)
			end
		end)
		hold = h
	elseif action == ACT_CLICK then
		if hold and hold.held then
			finish_hold()
		elseif guard and guard.button == button then
			end_hold()
			log.debug("click on button %d right after a hold ignored", button)
		else
			end_hold()
			click(button)
		end
	elseif action == ACT_RELEASE then
		-- Release after a hold: stop the ramp; a release that follows a click
		-- has nothing left to do.
		if hold and hold.held then
			finish_hold()
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
-- drivers]. LINK_BUTTON is with the keypad LEDs above.
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

-- A keypad on a link asks for its button's colours and the LED state.
dispatch.proxy["REQUEST_BUTTON_COLORS"] = function(binding)
	local button = link_button(binding, "REQUEST_BUTTON_COLORS")
	if not button then
		return
	end
	send_button_colors(tonumber(binding), button)
	C4:SendToProxy(tonumber(binding), "MATCH_LED_STATE", { STATE = st.on == true }, "COMMAND")
end

-- The proxy stores a button's on or off colour (the docs print the names
-- with spaces; both spellings are accepted).
dispatch.proxy["SET_BUTTON_COLOR"] = function(_, params)
	local button = tonumber(params.BUTTON_ID or params["BUTTON ID"])
	if not (button and COLOR_DEFAULTS[button]) then
		return log.warn("SET_BUTTON_COLOR without a known BUTTON_ID (%s)", tostring(params.BUTTON_ID))
	end
	for which, names in pairs({ on = { "ON_COLOR", "ON COLOR" }, off = { "OFF_COLOR", "OFF COLOR" } }) do
		local raw = params[names[1]] or params[names[2]]
		if raw ~= nil then
			local color = valid_color(raw)
			if color then
				colors[button][which] = color
				C4:PersistSetValue(color_key(button, which), color)
			else
				log.warn("SET_BUTTON_COLOR: %s %q is not a 6-digit hex colour", names[1], tostring(raw))
			end
		end
	end
	send_button_colors(BUTTON_LINK[button], button)
	send_button_info(button, st.on == true)
end

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
	load_colors()
	dispatch.replay_properties(Properties)
	prop("Hue Light ID", light_id_label())
	-- The bridge first, so messages it sent before this point are applied
	-- against the right binding state; then the hello carries whatever
	-- identity they delivered.
	bridge = bound_bridge()
	drain_early()
	hello()
	report_online()
	-- The LEDs, once, when buffered messages made the state known already
	-- (otherwise the first report sends them).
	update_leds()
	if not bridge then
		schedule_recheck(1)
	end
end

-- Control bindings only: the bridge binding, and the Button Links, where a
-- newly bound keypad gets the LED state; the proxy's binding is not one.
function OnBindingChanged(idBinding, _, bound, otherDevice)
	if LINK_BUTTON[idBinding] then
		if bound then
			update_leds(true)
		end
		return
	end
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
	disarm_guard()
	cancel_recheck()
end
