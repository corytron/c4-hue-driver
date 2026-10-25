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
local device = require("common.device")
local state = require("light.state")
local caps = require("light.caps")

-- Binding IDs, see driver.xml; common/device.lua holds the proxy's (5001).
local BRIDGE_BINDING = device.BRIDGE_BINDING

-- Grace after the requested ramp before a target the bridge never confirmed
-- is reported as reached, so the UI never sticks in "changing".
local FALLBACK_MS = 1000

-- Prefix of every line this driver logs.
local LOG_PREFIX = "Hue Light"

-- SET_COLOR_TARGET parameter names: the docs print them with spaces, one with
-- a "CIE 1931" suffix. The house's proxy sends the first spelling of each
-- list [verified: hardware 2026-10-22, checklist D.10; see SET_COLOR_TARGET
-- below]; the others are kept for other proxy versions [assumed]. Each list
-- is tried in order.
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
-- none, as every light did before zone lights existed. So is a group's type
-- ("zone" / "room"): its texts, and the name Adopt Hue Name gives a room
-- device, are right after a restart, before the bridge configures it again
-- (#234).
local PERSISTED = { rid = "hue_rid", name = "hue_name", model = "hue_model", kind = "hue_kind",
	group_type = "hue_group_type" }

-- What a forgotten device's owner can do; a light's Status says it, a group
-- device's Last Action (its Status names the group instead).
local FORGOTTEN_INSTRUCTION = "Delete this device in Composer, or bind it again and use Link Devices"

local st = state.new()
local bridge = nil           -- device id of the bound Hue Bridge driver, or nil
local fallback = {}          -- "brightness" / "color" -> { timer = armed C4LuaTimer, assume = fn }

-- The plumbing both device drivers share (common/device.lua): properties and
-- proxy notifies, the bridge and proxy lookups, Driver Version, the buffer
-- for bridge messages that arrive before late init, the keypad (LEDs, Button
-- Links, settings, the press machine), the binding re-check, the goodbye, and
-- in dev builds the dev loop's log forwarding and DEV_RELOAD. Its hooks
-- (is_on, on_bridge_found, on_click, on_hold, on_finish) are set below.
local dev = device.new({
	prefix = LOG_PREFIX,
	tree = "light", -- the dev loop's name for this driver's source tree
	bridge = function() return bridge end,
	rid = function() return st.rid end,
	noun = "light",
	-- driver.xml declares supports_default_on, click_rates and hold_rates.
	settings = { "preset", "click_up", "click_down", "hold_up", "hold_down" },
})
local prop, notify, device_id, result = dev.prop, dev.notify, dev.device_id, dev.result
local bound_bridge, proxy_id, after_late_init = dev.bound_bridge, dev.proxy_id, dev.after_late_init
local update_leds, LINK_BUTTON, send = dev.update_leds, device.LINK_BUTTON, dev.send

-- Identity and status texts ------------------------------------------------

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

-- "Hue light"; for a group "Hue zone" / "Hue room" from its group_type
-- (persisted, so right after a start too), else the model the bridge sent,
-- which reads the same (a device last configured by a build that did not
-- persist the type, until the bridge answers its hello).
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
-- MATCH_LED_STATE on each Button Link and BUTTON_INFO per button follow the
-- light (common/device.lua, docs/keypad-design.md "Keypad LEDs"); what they
-- follow here is st.on, nil until the bridge has reported.
function dev.is_on()
	return st.on
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

-- True when the target went to the bridge. When the send fails
-- (common/device.lua logs why) nothing changed: the proxy hears CHANGED with
-- the level its CHANGING came from, and a colour kept for the next turn-on
-- keeps waiting for it.
local function set_brightness(target, rate)
	target, rate = tonumber(target), tonumber(rate) or 0
	if not target then
		return log.warn("brightness command without a target")
	end
	if not ready("brightness target") then
		return
	end
	local current = state.to_proxy_brightness(st) or 0
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = current,
		LIGHT_BRIGHTNESS_TARGET = target,
		RATE = rate,
	})
	local stored = st.pending_color
	local params = state.from_brightness_target(st, target, rate)
	if not send("HUE_SET", params) then
		st.pending_color = stored
		notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = current })
		return false
	end
	arm("brightness", rate, function()
		log.debug("brightness target %s unconfirmed after %d ms; assuming it", tostring(target), rate + FALLBACK_MS)
		local changed = state.apply_hue(st, params)
		report_brightness()
		if changed.color then
			report_color() -- the turn-on carried a colour stored while off
		end
	end)
	return true
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
		if not send("HUE_SET", params) then
			-- Nothing reached the bridge (logged): the proxy hears the colour
			-- the light still has, when one is known, as for an ignored target.
			report_color()
			return
		end
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
		dev.flush_log() -- dev builds: lines logged while the bridge was unknown
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

-- The persisted fields as they stand, for save_identity to compare with.
local function identity()
	local fields = {}
	for field in pairs(PERSISTED) do
		fields[field] = st[field]
	end
	return fields
end

-- After a configure: store what it left. Only the group type can go back to
-- none (state.configure takes it as sent), and its stored copy then goes too
-- (an empty value would not remove it [verified: API 26.5, PersistSetValue,
-- PersistDeleteValue]), so a restart shows what the device showed before.
local function save_identity(before)
	for field, key in pairs(PERSISTED) do
		if st[field] then
			C4:PersistSetValue(key, st[field])
		elseif before[field] ~= nil then
			C4:PersistDeleteValue(key)
		end
	end
end

-- From the bridge (ExecuteCommand) -------------------------------------------
-- Director late-inits drivers in no particular order, so the bridge's
-- messages can reach a light before its own OnDriverLateInit, where
-- UpdateProperty and SendToProxy are not yet safe; after_late_init
-- (common/device.lua) holds them until then, in order.

-- The kind a configure names ("group" for a zone or room, "light" or none for
-- a light) is kept by state.configure; this only says what happened. A later
-- configure also carries changed capabilities (lights added to or removed
-- from a group, Decision 7), which the notify below re-announces every time.
dispatch.commands["HUE_CONFIGURE"] = after_late_init("HUE_CONFIGURE", function(params)
	local before = identity()
	state.configure(st, params)
	local named = params.kind
	if named ~= nil and named ~= "" and not state.KINDS[named] then
		log.warn("HUE_CONFIGURE with unknown kind %s ignored; still a %s", tostring(named), what())
	elseif before.kind and st.kind ~= before.kind then
		log.info("now a %s (was a %s)", what(), before.kind == state.KIND_GROUP and "group light" or "light")
	end
	save_identity(before)
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

-- Composer actions (LUA_ACTION) ----------------------------------------------
-- Every click ends in Last Action and a log line, whatever happened.

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

-- A Navigator's colour pick arrives as LIGHT_COLOR_TARGET_MODE 0 with X and
-- Y, a temperature pick as mode 1 with the temperature's X and Y, and RATE
-- [verified: hardware 2026-10-22, the one-time parameter log this driver
-- carried until 2026-10-25, checklist D.10]; the other spellings in
-- COLOR_KEYS are kept for other proxy versions [assumed].
dispatch.proxy["SET_COLOR_TARGET"] = function(_, params)
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
-- What a tap and a hold do to a light; the press / click / release machine
-- and the proxy's preset and rates are common/device.lua's. A hold's record
-- carries the ramp: ramping, the level estimate, its step and its end (to).
-- Behaviour: docs/keypad-design.md, "Driver behaviour" and "Light parity".
local BUTTON_TOP, BUTTON_BOTTOM = device.BUTTON_TOP, device.BUTTON_BOTTOM
local HOLD_TICK_MS = 100 -- the level estimate advances this often during a ramp
-- A longer hold rate is used as this, for the light and its tile alike: the
-- bound the bridge holds a zone light's and a scene's hold to (100 minutes;
-- zone_lights.DIM_MAX_DURATION, scenes.DIM_MAX_DURATION), which a light's
-- lacked (#234).
local HOLD_MAX_MS = 6000000
local setting = dev.setting

-- A tap: top goes to the On preset over the click rate up, bottom off over
-- the click rate down, toggle either way from the state the light shows.
function dev.on_click(button)
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

-- A hold uses Hue's own relative dim (HUE_DIM up / down to the bridge: a
-- dimming_delta on the light, or on a zone's grouped_light), stopped by the
-- release, as the scene does (docs/keypad-design.md). A hold rate is the
-- time of the whole range [verified: proxy reference, HOLD_RATE_UP/DOWN], so
-- a hold moves at 100 % per rate from any level: Hue is asked for the whole
-- range (the bridge's brightness_delta 100) over the whole rate, and the
-- proxy hears CHANGING toward the end of the range over the share of the
-- rate the distance takes, with a 100 ms tick keeping an estimate of the
-- level at that speed for the stop and its fallback.
--
-- #232: Hue used to get that share with the whole range, so from 50 % it ran
-- at twice the tile's speed. The whole rate rather than the distance left as
-- the delta: a zone or room light's level is its lamps' average, and the
-- whole range brings a lamp below the average to the end too while the
-- button is held; the start stays a whole-range dim, which the bridge sends
-- without waiting for its request bucket (commands.urgent); and a scene's
-- hold sends the same. Assumed until the hold on the house that #232 asks
-- for: Hue keeps the speed, and stops at the end of the range when the delta
-- reaches past it, as a Zigbee level step does.
--
-- A dim that never reaches the bridge (logged) moves nothing: the tick
-- stops, the release has nothing to stop, and the proxy hears the level the
-- hold began at.
local function start_ramp(h, up, from)
	local to = up and 100 or 1
	local full = math.floor(math.min(setting(up and "hold_up" or "hold_down"), HOLD_MAX_MS))
	local duration = math.floor(full * math.abs(to - from) / 100)
	h.ramping, h.level, h.to = true, from, to
	h.step = (to - from) / math.max(1, duration / HOLD_TICK_MS)
	h.timer = C4:SetTimer(HOLD_TICK_MS, function()
		if not dev.holding(h) then
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
	log.debug("hold: dim %s from %d, the tile over %d ms, Hue the whole range over %d ms", up and "up" or "down",
		from, duration, full)
	if not send("HUE_DIM", { rid = st.rid, direction = up and "up" or "down",
		duration = string.format("%d", full) }) then
		h.timer:Cancel()
		h.timer, h.ramping = nil, false
		notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = from })
	end
end

-- A hold began (the machine chose the direction; down from off does
-- nothing): on, the ramp starts from the level shown; off, the light turns
-- on at 1 % first and the ramp up follows (dev.dim_after_on).
function dev.on_hold(h, up, on)
	if not ready("hold") then
		return
	end
	if on then
		return start_ramp(h, up, state.to_proxy_brightness(st) or 1)
	end
	if not set_brightness(1, 0) then
		return -- the turn-on never reached the bridge (logged): nothing to dim up from
	end
	dev.dim_after_on(h, function()
		start_ramp(h, true, st.on == true and state.to_proxy_brightness(st) or 1)
	end)
end

-- The release (or release-as-click) after a hold: stop the dim at Hue,
-- which keeps the level it reached; `level` is the estimate, for the bridge
-- to write should Hue refuse the stop. The proxy hears the bridge's next
-- report, or the estimate after the fallback time, also when the stop
-- itself never reaches the bridge (logged; Hue then dims on to the end of
-- the range and reports it). The machine has armed the click guard.
function dev.on_finish(h)
	if not (h.ramping and bridge and st.rid) then
		return
	end
	local level = math.floor(h.level + 0.5)
	send("HUE_DIM", { rid = st.rid, direction = "stop", level = string.format("%d", level) })
	arm("brightness", 0, function()
		log.debug("dim stop unconfirmed after %d ms; assuming %d %%", FALLBACK_MS, level)
		state.apply_hue(st, { on = "true", brightness = tostring(level) })
		report_brightness()
	end)
end

-- Lifecycle ----------------------------------------------------------------

dispatch.install(_G)

function OnDriverInit()
end

-- After a Director restart the binding to the bridge can be invisible at late
-- init although Composer shows it [hardware 2026-10-22, docs/keypad-design.md];
-- while unbound the device looks again at 5, 15, 30 and 60 s
-- (common/device.lua) and greets the bridge as soon as it is visible.
function dev.on_bridge_found()
	hello()
	report_online()
end
local schedule_recheck, cancel_recheck = dev.schedule_recheck, dev.cancel_recheck

function OnDriverLateInit()
	load_identity()
	dev.load_settings()
	dev.load_colors()
	dispatch.replay_properties(Properties)
	dev.show_driver_version(1)
	prop("Hue Light ID", light_id_label())
	-- The bridge first, so messages it sent before this point are applied
	-- against the right binding state; then the hello carries whatever
	-- identity they delivered.
	bridge = bound_bridge()
	dev.late_init()
	hello()
	report_online()
	-- The LEDs, once, when buffered messages made the state known already
	-- (otherwise the first report sends them).
	update_leds()
	if not bridge then
		schedule_recheck(1)
	end
	-- Last: a binding change Director delivered before late init acts now
	-- (common/device.lua), against the binding state read above.
	dev.replay_bindings()
end

-- Control bindings only: the bridge binding, and the Button Links, where a
-- newly bound keypad gets the LED state; the proxy's binding is not one. A
-- call before late init waits for it (common/device.lua).
OnBindingChanged = dev.binding_changed(function(idBinding, _, bound, otherDevice)
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
end)

-- Composer is deleting this device: tell the bridge, so it tombstones the
-- entry instead of fanning state out to a dead id (common/device.lua).
-- OnDriverDestroyed follows and stops the timers.
function OnDriverRemovedFromProject()
	dev.goodbye("HUE_GOODBYE")
end

function OnDriverDestroyed()
	settle("brightness")
	settle("color")
	dev.cancel_timers() -- a keypad press and the click guard, the binding re-check, the Driver Version looks
end
