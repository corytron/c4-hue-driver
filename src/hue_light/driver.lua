-- Hue Light driver: one light_v2 proxy per Hue light. The same driver, told
-- kind "group" by its configure, stands for a Hue zone or room through its
-- grouped_light (docs/zone-light-design.md): the proxy, keypad, LED and
-- lifecycle behaviour is the same, only the identity texts and the hello
-- know the difference. It never speaks to the bridge itself: commands go to
-- the Hue Bridge driver it is bound to (consumer binding 1, class
-- HUE_BRIDGE) with C4:SendToDevice, and the bridge pushes configuration and
-- state back through ExecuteCommand. The message contract is in
-- docs/lights-design.md, docs/import-design.md §4/§13 and
-- docs/zone-light-design.md §5; the light_v2 facts in docs/design.md; the
-- programming commands (Raise Level By, Restore Saved Level) in
-- docs/relative-level-design.md; the turn-on behaviour (brightness On Mode,
-- the On and Dim colours, the colour on modes, the rate ranges) in
-- docs/turn-on-design.md (#429, #427, #430), whose decisions the comments
-- cite as D<n>; the bridge's link offline and its answers to commands that
-- did not land in docs/offline-design.md, cited as #428 D<n>; Control4 load
-- groups (the GROUP_* commands, the Load Groups row) in
-- docs/load-groups-design.md, cited as #435 D<n>; the throttle of Hue-side
-- level reports in docs/light-events-design.md, cited as #433 D<n>.

local log = require("common.log")
local dispatch = require("common.dispatch")
local device = require("common.device")
-- #486, #487: every number and time from outside (docs/security-fixes-2026-11-design.md).
local num = require("common.num")
local state = require("light.state")
local caps = require("light.caps")
local turnon = require("light.turnon")
local load_group = require("light.load_group")
local throttle = require("light.throttle")

-- Binding IDs, see driver.xml; common/device.lua holds the proxy's (5001).
local BRIDGE_BINDING = device.BRIDGE_BINDING

-- Grace after the requested ramp before a target the bridge never confirmed
-- is reported as reached, so the UI never sticks in "changing".
local FALLBACK_MS = 1000

-- #433 D12: a level Hue reports while it moves reaches the proxy at most
-- once per this window, the last one exact (light.throttle), as the Hue
-- Scene device's level reports do.
local LEVEL_REPORT_MS = 1000

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
	-- #427 D16: a driver with colour on modes is sent the preset a colour
	-- target comes from [verified: LV2 cmds _9.6-SET_COLOR_TARGET.md, which
	-- prints the names with spaces]; underscores first, as the house's
	-- proxy spells the other names (docs/turn-on-design.md §2.4).
	preset_id = { "LIGHT_COLOR_TARGET_PRESET_ID", "LIGHT COLOR TARGET PRESET ID" },
	preset_origin = { "LIGHT_COLOR_TARGET_PRESET_ORIGIN", "LIGHT COLOR TARGET PRESET ORIGIN" },
}

-- #429 D7, D6: a SET_BRIGHTNESS_TARGET from a driver with On Modes names the
-- preset it goes to [verified: LV2 cmds _1.5-SETBRIGHTNESSTARGET.md]; both
-- spellings, as COLOR_KEYS.
local BRIGHTNESS_PRESET_KEYS = { "LIGHT_BRIGHTNESS_TARGET_PRESET_ID", "LIGHT BRIGHTNESS TARGET PRESET ID" }

-- docs/turn-on-design.md §7.7. The proxy's presets are read SETUP_READ_MS
-- after late init (D19), out of late init itself; a hold's blend follows
-- its release by HOLD_COLOR_DELAY_MS, gliding over HOLD_COLOR_GLIDE_MS
-- (D15); every rate sent to Hue is clamped to 0..RATE_MAX (D20).
local SETUP_READ_MS = 3000
local HOLD_COLOR_DELAY_MS = 500
local HOLD_COLOR_GLIDE_MS = 1000
local RATE_MAX = device.RATE_MAX
-- The raw GET_SETUP (or variable 1300) text is logged at debug once per
-- read, cut here (D19).
local SETUP_LOG_MAX = 2000

-- The light's own copy of its identity (PersistSetValue key per state field),
-- so a bridge that lost its registry can rebuild it from the lights instead
-- of importing them a second time (docs/import-design.md §1, rule 3). The
-- kind is part of it (docs/zone-light-design.md §2): a zone or room device
-- persists "group" and the bridge routes its hello on it; a light persists
-- none, as every light did before zone lights existed. So is a group's type
-- ("zone" / "room"): its texts, and the name Adopt Hue Name (a hidden
-- alias since 1.2) gives a room device, are right after a restart, before
-- the bridge configures it again (#234).
local PERSISTED = { rid = "hue_rid", name = "hue_name", model = "hue_model", kind = "hue_kind",
	group_type = "hue_group_type" }

-- What a forgotten device's owner can do; a light's Status says it, a group
-- device's Last Action (its Status names the group instead). The device has
-- no actions since 1.2 (#334, D3): every remedy is an action of the Hue
-- Bridge device, and the texts name it (Link Device, Forget Device).
local FORGOTTEN_INSTRUCTION = "Delete this device, or bind it again and use Link Device on the Hue Bridge"

-- The remedy for a device whose light, zone or room is gone from Hue: the
-- bridge's Link Device or Forget Device, in words that keep a group's
-- Status under 60 characters.
local GONE_REMEDY = "Link or Forget Device"

-- The remedy for a bound device the bridge has not linked to a Hue light.
local UNLINKED_REMEDY = "use Link Device on the Hue Bridge"

local st = state.new()
local bridge = nil           -- device id of the bound Hue Bridge driver, or nil
local fallback = {}          -- "brightness" / "color" -> { timer = armed C4LuaTimer, assume = fn }
-- The brightness ramp the light is running (#421 D6), nil while none is:
-- { from, to, time, started, tap, timer }, levels in proxy percent (to 0 for
-- off), time and started in controller ms. "Targets" below says when one
-- begins and ends.
local ramp = nil
-- The device's Control4 load groups (#435): light.load_group's instance,
-- made under "Load groups" below, once the paths it drives exist. It keeps
-- the memberships (D6) and the group hold (D3), a hold no keypad button
-- owns, whose dim and stop run through start_ramp and finish.
local groups

-- The turn-on behaviour's own state (docs/turn-on-design.md). The proxy's
-- On Modes and presets, and the decisions made from them, live in the
-- light.turnon module, which persists its copies through the functions it
-- is handed (§7.6); `modes` is that module's instance. What only the driver
-- knows, in one table (it keeps the main chunk's locals down):
--   last_on   the last non-zero level reported in LIGHT_BRIGHTNESS_CHANGED,
--             which Previous turns on to (D6: the proxy tracks the same,
--             F3); in memory only, empty after a restart
--   preset    { id, level }: the brightness preset last targeted, while the
--             light may still sit at it (D7)
--   color     { id, origin, fields }: the colour preset last sent and the
--             HUE_SET fields it went out as, while the light may show it (D16)
--   expected  the HUE_SET colour fields Control4 last sent, then what the
--             bridge confirmed for them: what tells a colour changed in Hue
--             (§7.4 foreign_color)
--   stored    the proxy colour { x, y, mode, id, origin } behind the colour
--             fields state keeps for the next turn-on (st.pending_color)
--   hold_color  the timer of a hold's blend after its release (D15)
--   setup_timer the timer of the GET_SETUP read after late init (D19)
local mem = {}
local modes = turnon.new({
	-- One value: Director's PersistGetValue returns none for a key never
	-- written (#298, common/device.lua).
	get = function(key) return (C4:PersistGetValue(key)) end,
	set = function(key, value) C4:PersistSetValue(key, value) end,
	delete = function(key) C4:PersistDeleteValue(key) end,
})

-- The plumbing both device drivers share (common/device.lua): properties and
-- proxy notifies, the bridge and proxy lookups, Driver Version, the buffer
-- for bridge messages that arrive before late init, the keypad (LEDs, Button
-- Links, settings, the press machine), the binding re-check, the goodbye, and
-- in dev builds the dev loop's log forwarding and DEV_RELOAD. Its hooks
-- (is_on, on_bridge_found, on_click, on_hold, on_finish, and for #421
-- ramp_active and on_ramp_stop) are set below.
local dev = device.new({
	prefix = LOG_PREFIX,
	tree = "light", -- the dev loop's name for this driver's source tree
	bridge = function() return bridge end,
	rid = function() return st.rid end,
	noun = "light",
	-- driver.xml declares the brightness On Modes (#429 D2), click_rates and
	-- hold_rates; the preset is the On preset's level, Default On Brightness.
	settings = { "preset", "click_up", "click_down", "hold_up", "hold_down" },
})
local prop, notify, device_id, result = dev.prop, dev.notify, dev.device_id, dev.result
local bound_bridge, proxy_id, after_late_init = dev.bound_bridge, dev.proxy_id, dev.after_late_init
local update_leds, LINK_BUTTON, send = dev.update_leds, device.LINK_BUTTON, dev.send
local setting = dev.setting -- the keypad settings: "preset" (Default On Brightness), the rates

-- Identity and status texts ------------------------------------------------

-- "#12" from Hue's v1 id (the bridge sends "/lights/12" or "12"; "/groups/2"
-- for a zone or room), or nil.
local function v1_label()
	local digits = st.id_v1 and st.id_v1:match("(%d+)%s*$")
	return digits and ("#" .. digits) or nil
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

-- "Gone from the Hue bridge since 2026-10-24 12:00; Link or Forget Device"
-- for a light; "Zone deleted in Hue since 2026-10-24; Link or Forget Device"
-- for a group (the day alone keeps it under 60 characters). The time comes
-- from the bridge's configure, so it goes through num.date (#487 D-6): one
-- os.date cannot take never raises here.
local function gone_status()
	if state.is_group(st) then
		local since = st.gone_since and (" since " .. num.date("%Y-%m-%d", st.gone_since)) or ""
		return group_word() .. " deleted in Hue" .. since .. "; " .. GONE_REMEDY
	end
	local since = st.gone_since and (" since " .. num.date("%Y-%m-%d %H:%M", st.gone_since)) or ""
	return "Gone from the Hue bridge" .. since .. "; " .. GONE_REMEDY
end

-- Decision 11: "Hue zone Bedside Lights has no lights; nothing to control".
local function no_lights_text()
	return string.format("%s %s has no lights; nothing to control", kind_label(), st.name or st.rid or "?")
end

-- Why a command cannot reach the light right now, or nil when it can. The
-- order is the order Status explains things in: a forgotten light is told
-- what to do even while its binding is already gone. A group with no lights
-- has no grouped_light to command (docs/zone-light-design.md Decision 11).
-- The bridge's link offline (#428 D5, docs/offline-design.md §6.3) comes
-- after the device's own deliberate ends and before no lights: "Hue Bridge
-- not answering since 14:02". Its first letter stays upper case, unlike the
-- other reasons: "Hue" is a name ("brightness target dropped: Hue Bridge
-- not answering since 14:02").
local function blocker()
	if st.forgotten then
		return "forgotten by the bridge; " .. FORGOTTEN_INSTRUCTION:gsub("^D", "d")
	elseif not bridge then
		return "not bound to a Hue Bridge"
	elseif not st.rid then
		return "waiting for the bridge to assign a Hue light (" .. UNLINKED_REMEDY .. ")"
	elseif st.gone then
		if state.is_group(st) then
			return group_word():lower() .. " deleted in Hue; " .. GONE_REMEDY
		end
		return "gone from the Hue bridge; " .. GONE_REMEDY
	elseif dev.link_offline() then
		return dev.link_text()
	elseif st.no_lights then
		return no_lights_text()
	end
	return nil
end

-- What ONLINE_CHANGED carries: reachable through a bridge that knows us and
-- whose link is not offline, and not reported unreachable by Zigbee (a
-- group: not without lights). The link and Zigbee are two conditions, both
-- needed (#428 D6).
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

-- While the bridge's link is offline Status names it, whatever Zigbee last
-- said: that is not current then (#428 D6, §6.3), and the bridge's fix is
-- the one to act on. A light the bridge has not linked yet keeps saying so.
local function refresh_status()
	if st.forgotten then
		prop("Status", forgotten_status())
	elseif not bridge then
		prop("Status", "Not bound to a Hue Bridge")
	elseif st.gone then
		prop("Status", gone_status())
	elseif st.rid and dev.link_offline() then
		prop("Status", dev.link_text())
	elseif not st.rid or not st.name then
		prop("Status", "Bound; waiting for the bridge")
	elseif st.no_lights then
		prop("Status", no_lights_text())
	else
		prop("Status", identity_status())
	end
	-- "" while nothing says either way: bound, but the bridge has not reported.
	if not bridge or st.forgotten or st.gone or dev.link_offline() or st.no_lights or st.online == false then
		prop("Online", "Offline")
	else
		prop("Online", st.online and "Online" or "")
	end
end

-- Keypad LEDs ----------------------------------------------------------------
-- MATCH_LED_STATE on each Button Link and BUTTON_INFO per button follow the
-- light (common/device.lua, docs/keypad-design.md "Keypad LEDs"); what they
-- follow here is st.on, nil until the bridge has reported. While a ramp runs
-- whose start or end is lit, the lamp is on throughout, whatever the cache
-- says before its held reports come out (#421 D10): a tap from off lights
-- the LEDs as it starts, not when its ramp ends.
function dev.is_on()
	if ramp and (ramp.from > 0 or ramp.to > 0) then
		return true
	end
	return st.on
end

-- Proxy notifies -----------------------------------------------------------
-- The report_* functions return true when they had something to report.

-- #433 D12 to D14: the throttle of Hue-side level reports (light.throttle),
-- made after report_brightness below. Every CHANGING closes its window
-- (brightness_changing, D13) and every CHANGED records its level
-- (brightness_changed, D14); HUE_STATE decides which reports wait (D12).
local levels

-- #429 D7: the brightness notifies name presets, so the proxy can move the
-- light when a preset's level changes (the Daylight Agent) [verified: LV2
-- notif _10.2-LIGHTBRIGHTNESSCHANGED.md, _10.3-LIGHTBRIGHTNESSCHANGING.md].
-- CHANGING names the preset it goes to, when it goes to one; CHANGING and
-- CHANGED name the preset last targeted while the light sits at it (within
-- a point, as Hue reports its Zigbee level). A level away from it, or a
-- target that names none, forgets it.
local function preset_at(level)
	local mark = mem.preset
	if mark and level and math.abs(level - mark.level) <= 1 then
		return mark.id
	end
	return nil
end

-- LIGHT_BRIGHTNESS_CHANGING; `preset_id` the preset the target is, or nil.
-- The one helper every CHANGING goes through (#433 D13, the contract's
-- changing()): a target's, a tap's, a hold's (keypad or load group, #435)
-- and a turn-on's (#429). It closes the throttle's window, so a Hue-side
-- level still waiting there never goes out as a stale CHANGED while the
-- tile animates the Control4 ramp; the ramp's own CHANGED ends it.
local function brightness_changing(current, target, rate, preset_id)
	levels:close()
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = current,
		LIGHT_BRIGHTNESS_TARGET = target,
		RATE = rate,
		LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = preset_at(current),
		LIGHT_BRIGHTNESS_TARGET_PRESET_ID = preset_id,
	})
	mem.preset = preset_id and { id = preset_id, level = target } or nil
end

-- LIGHT_BRIGHTNESS_CHANGED with `level`. The last level above 0 is what a
-- Previous turn-on goes back to (#429 D6), as the proxy remembers the last
-- non-zero level reported before a 0 [verified: LV2 caps
-- _7-brightnessonmodeprevious.md]. Every CHANGED goes through here and is
-- recorded as the last level sent (#433 D14): the throttle's trailing report
-- goes out only when the cache differs from it, so a stop's estimate or an
-- unsent command's CHANGED is never repeated.
local function brightness_changed(level)
	local id = preset_at(level)
	if not id then
		mem.preset = nil
	end
	if level > 0 then
		mem.last_on = level
	end
	notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level, LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = id })
	levels:sent(level)
end

local function report_brightness()
	local brightness = state.to_proxy_brightness(st)
	if not brightness then
		return false
	end
	brightness_changed(brightness)
	update_leds()
	return true
end

-- #433 D12 (docs/light-events-design.md §6.4, §6.5): the window's trailing
-- report is the cache's level, through report_brightness (which records it).
levels = throttle.new({
	ms = LEVEL_REPORT_MS,
	current = function() return state.to_proxy_brightness(st) end,
	send = function() report_brightness() end,
})

-- How close a reported colour must be to one Control4 sent to count as it
-- (§7.4, §7.7): Hue rounds what it stores.
local FOREIGN_XY, FOREIGN_MIREK = turnon.FOREIGN_XY, turnon.FOREIGN_MIREK

-- HUE_SET colour fields (state.color_fields) as numbers, or nil when the
-- params carry no colour.
local function color_of(params)
	if params.mirek then
		return { mirek = tonumber(params.mirek) }
	elseif params.x and params.y then
		return { x = tonumber(params.x), y = tonumber(params.y) }
	end
	return nil
end

-- The colour the cache shows, in the same form.
local function cached_color()
	if st.color_mode == "ct" and st.mirek then
		return { mirek = st.mirek }
	elseif st.x and st.y then
		return { x = st.x, y = st.y }
	end
	return nil
end

-- True when the cache shows the colour `fields` describe.
local function shows(fields)
	if not fields then
		return false
	end
	if fields.mirek then
		return st.color_mode == "ct" and st.mirek ~= nil and math.abs(st.mirek - fields.mirek) <= FOREIGN_MIREK
	end
	return st.color_mode ~= "ct" and st.x ~= nil and st.y ~= nil and math.abs(st.x - fields.x) <= FOREIGN_XY
		and math.abs(st.y - fields.y) <= FOREIGN_XY
end

-- #427 D16: the colour notifies name the preset the light shows [verified:
-- LV2 notif _10.5-LIGHTCOLORCHANGED.md, _10.7-LIGHTCOLORCHANGING.md; the
-- origin parameters: LV2 caps _7.3-coloronmodepreset.md]. The id and origin
-- of the colour preset last sent, while the light shows it.
local function color_preset_now()
	local mark = mem.color
	if mark and shows(mark.fields) then
		return mark.id, mark.origin
	end
	return nil
end

local function report_color()
	local x, y, mode = state.to_proxy_color(st)
	if not x then
		return false
	end
	local id, origin = color_preset_now()
	if not id then
		mem.color = nil
	end
	notify("LIGHT_COLOR_CHANGED", {
		LIGHT_COLOR_CURRENT_X = x,
		LIGHT_COLOR_CURRENT_Y = y,
		LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
		LIGHT_COLOR_CURRENT_PRESET_ID = id,
		LIGHT_COLOR_CURRENT_PRESET_ORIGIN = origin,
	})
	return true
end

-- LIGHT_COLOR_CHANGING toward the proxy colour `c` ({ x, y, mode, id,
-- origin }) over `rate`, sent as the HUE_SET fields `fields`: for a
-- SET_COLOR_TARGET, and since #427 also for a turn-on, turn-off or blend
-- that carries a colour (§7.3). The preset it names, if any, is the one the
-- light shows from now on.
local function color_changing(c, rate, fields)
	local cx, cy, cmode = state.to_proxy_color(st)
	local id, origin = color_preset_now()
	notify("LIGHT_COLOR_CHANGING", {
		LIGHT_COLOR_TARGET_X = c.x,
		LIGHT_COLOR_TARGET_Y = c.y,
		LIGHT_COLOR_TARGET_COLOR_MODE = c.mode,
		LIGHT_COLOR_TARGET_RATE = rate,
		LIGHT_COLOR_CURRENT_X = cx,
		LIGHT_COLOR_CURRENT_Y = cy,
		LIGHT_COLOR_CURRENT_COLOR_MODE = cmode,
		LIGHT_COLOR_CURRENT_PRESET_ID = id,
		LIGHT_COLOR_CURRENT_PRESET_ORIGIN = origin,
		LIGHT_COLOR_TARGET_PRESET_ID = c.id,
		LIGHT_COLOR_TARGET_PRESET_ORIGIN = c.id and c.origin or nil,
	})
	mem.color = c.id and { id = c.id, origin = c.origin, fields = color_of(fields or {}) } or nil
end

local function report_online()
	notify("ONLINE_CHANGED", { STATE = is_online() })
end

-- Targets ------------------------------------------------------------------

-- A target sent to the bridge stays pending until a HUE_STATE carrying that
-- field arrives, its fallback fires, or the proxy says stop; either way the
-- proxy gets a CHANGED.
--
-- A turn-on from off also waits for its level (#308): Hue's first report
-- after it can carry the level the lamp had before it went off (seen on the
-- house: 70 % for 16 ms, then the 30 % asked for). While it waits, a
-- report's on and brightness are held back, out of the cache and away from
-- the proxy, when they would show the light on at neither the target
-- (within a point: Hue reports its Zigbee level) nor a level on the way up
-- to it (with a ramp only), or a level while the light still shows off. The
-- rest of the report (colour, online) goes through, and so does an off.
-- Held fields go under the next report that goes through (the target often
-- comes alone, without the on). When the wait ends any other way they go
-- into the cache as the bridge's word, and when the fallback ends it, at
-- the ramp plus FALLBACK_MS (as long as the driver waits for any
-- confirmation), they are reported: a change made elsewhere meanwhile is
-- late by at most that, never lost.
--
-- A brightness change with a time above 0 whose send succeeded is a ramp
-- (#421 D6), kept in `ramp`: a keypad tap's, and a timed target from
-- programming, Navigator or a lighting scene. While it runs the bridge's
-- reports of on and brightness are held back the same way (D10), because
-- Hue reports the target as soon as the transition starts, about 50 ms
-- after the request, while the lamp still moves and the tile animates from
-- the CHANGING [verified: house, #421 §7 L1, measured 2026-11-09]. A report
-- the ramp explains (a
-- level between where it started and its target, within a point; off at
-- the end of a ramp to off) waits for the ramp's end, then goes into the
-- cache and out as the ramp's one CHANGED. One it cannot explain (off while
-- it ramps up, on while it ramps to off, a level outside that span) is
-- someone else's change: it goes through at once and ends the ramp. A level
-- held back for #308 keeps waiting for the turn-on's goal, as above, and a
-- ramp whose time ran out without a report leaves its CHANGED to the
-- bridge's next report or the fallback. A ramp also ends at a stop
-- (stop_ramp), at any other brightness command (D11) or the start of a
-- hold, and with its target (settle). A colour command leaves it alone.

-- The level the proxy shows for a light on at `brightness` (Hue percent).
local function on_level(brightness)
	return state.to_proxy_brightness({ on = true, brightness = brightness })
end

-- #430 D20: every rate the light sends Hue, 0 to RATE_MAX (6 000 000 ms,
-- the Hue duration ceiling the bridge already clamps scenes and groups to
-- [assumed for a light: docs/turn-on-design.md D20]). A rate that is not a
-- finite number is 0, as before (#486: through common/num.lua).
local function clamp_rate(rate)
	return num.clamp(rate, 0, RATE_MAX, 0)
end

-- Every merge into the cache goes through here. A light that goes from on
-- to off ends a blend (#427 D14, turnon.ended): Control4's colours apply
-- again from the next turn-on.
local function apply(params)
	local was = st.on
	local changed = state.apply_hue(st, params)
	if was == true and st.on == false then
		turnon.ended(modes)
	end
	return changed
end

-- The controller's clock in ms [verified: API 34_timer/_2-GetTime, OS 3.2.3
-- on], or os.time() where it is missing, as common/devloop.lua reads it.
local function now_ms()
	local ok, t = pcall(function() return C4:GetTime() end)
	return ok and type(t) == "number" and t or os.time() * 1000
end

-- Where a ramp has the light now, by the clock: from + (to - from) x elapsed
-- / time, rounded (#421 §4.2); and the ms elapsed, 0 to its time.
local function ramp_estimate(r)
	local elapsed = math.max(0, math.min(r.time, now_ms() - r.started))
	return math.floor(r.from + (r.to - r.from) * elapsed / r.time + 0.5), elapsed
end

local function end_ramp()
	if ramp then
		ramp.timer:Cancel()
		ramp = nil
	end
end

-- Held fields into the cache; apply_hue's answer, nil when none were held.
local function release(pending)
	local held = pending.held
	pending.held, pending.stale = nil, nil
	return held and apply(held)
end

-- The target is over, and for brightness so is its ramp.
local function settle(kind)
	if kind == "brightness" then
		end_ramp()
	end
	local pending = fallback[kind]
	if pending then
		pending.timer:Cancel()
		fallback[kind] = nil
		release(pending)
	end
end

-- `assume` applies the sent target to the cache and reports it; it runs when
-- the bridge has not confirmed within the ramp plus FALLBACK_MS. `goal` is
-- the level a turn-on from off waits for (nil otherwise); a report held back
-- for it is reported then instead, as the bridge's word beats a guess.
-- `from` is the level the brightness CHANGING started from: what the proxy
-- hears when the target ends without the bridge knowing any level (an
-- undelivered answer or the link going offline, #428 D9, D5; report_known).
local function arm(kind, rate, assume, goal, from)
	settle(kind)
	local pending = { assume = assume, goal = goal, ramp = rate > 0, from = from }
	pending.timer = C4:SetTimer(rate + FALLBACK_MS, function()
		fallback[kind] = nil
		if kind == "brightness" then
			end_ramp() -- its time is past (the ramp's own timer fires first on the clock)
		end
		local changed = release(pending)
		if not changed then
			return assume()
		end
		log.debug("brightness target unconfirmed after %d ms; showing what the bridge reported", rate + FALLBACK_MS)
		report_brightness()
		if changed.color then
			report_color()
		end
	end)
	fallback[kind] = pending
end

-- #421 D10: a ramp's time ran out. A report it held back goes into the
-- cache and out as its one CHANGED, and settles the target; without one
-- (or with only a #308 one) the bridge's next report or the fallback ends
-- the target, as for any other.
local function ramp_done(r)
	if ramp ~= r then
		return
	end
	ramp = nil
	local pending = fallback.brightness
	if pending and pending.held and not pending.stale then
		settle("brightness")
		report_brightness()
	end
end

-- After a successful send with a time above 0 (#421 D6): the ramp's record,
-- its end on a timer, and the LEDs, which a ramp from off lights at once
-- (dev.is_on). `group` is the GROUP ID of a load group's GROUP_RAMP_TO_LEVEL
-- (#435 D12): that group's GROUP_STOP_RAMP stops this ramp, tagged.
local function begin_ramp(from, to, time, tap, group)
	local r = { from = from, to = math.max(0, math.min(100, to)), time = time, started = now_ms(), tap = tap,
		group = group }
	r.timer = C4:SetTimer(math.max(1, math.floor(time + 0.5)), function()
		ramp_done(r)
	end)
	ramp = r
	update_leds()
end

-- A HUE_STATE while a turn-on from off waits for its level (#308) or a ramp
-- runs (#421 D10): the params to apply, with the held fields under them when
-- the report goes through, or without their on and brightness when these
-- are held back too. A report the ramp cannot explain ends it here.
local function hold_back(params)
	local pending = fallback.brightness
	if not (pending and (pending.goal or ramp)) or (params.on == nil and params.brightness == nil) then
		return params
	end
	local held = pending.held or {}
	local merged = { on = params.on or held.on, brightness = params.brightness or held.brightness }
	local said = device.to_bool(merged.on) -- nil when the report does not say
	local on = said
	if on == nil then
		on = st.on
	end
	-- No level known at all (a plug never reports one): nothing to compare.
	local brightness = num.finite(merged.brightness) or st.brightness
	local level = on and brightness and on_level(brightness) or nil
	local verdict = nil -- "stale" (#308), "ramp" (D10, held), "foreign" (through, ends the ramp)
	if pending.goal and said ~= false then -- an off always gets past #308
		if not on then
			verdict = "stale" -- a level while the light still shows off
		elseif level and math.abs(level - pending.goal) > 1 and not (pending.ramp and level <= pending.goal) then
			verdict = "stale"
		end
	end
	if not verdict and ramp then
		local lo, hi = math.min(ramp.from, ramp.to), math.max(ramp.from, ramp.to)
		if (said == false and ramp.to > 0) or (said == true and ramp.to == 0)
			or (level and (level < lo - 1 or level > hi + 1)) then
			verdict = "foreign"
		else
			verdict = "ramp"
		end
	end
	local out = {}
	for k, v in pairs(params) do
		out[k] = v
	end
	if verdict == "stale" or verdict == "ramp" then
		pending.held, pending.stale = merged, verdict == "stale" or nil
		out.on, out.brightness = nil, nil
		if verdict == "stale" then
			log.debug("held back on=%s brightness=%s: the turn-on waits for %d %%", tostring(merged.on),
				tostring(merged.brightness), pending.goal)
		else
			log.debug("held back on=%s brightness=%s until the ramp to %d %% ends", tostring(merged.on),
				tostring(merged.brightness), ramp.to)
		end
		return out
	end
	if verdict == "foreign" then
		log.debug("on=%s brightness=%s is not the ramp to %d %%: it ends", tostring(merged.on),
			tostring(merged.brightness), ramp.to)
		end_ramp()
	end
	pending.held, pending.stale = nil, nil
	out.on, out.brightness = merged.on, merged.brightness
	return out
end

-- #421 D9: how a ramp is stopped at Hue; no property. The default since the
-- house measurement (#421 §7, measured 2026-11-09) is "level" (option C):
-- the estimate as an absolute HUE_SET, on, urgent (D12), over
-- STOP_GLIDE_MS. A new absolute command replaces the running transition,
-- and the bridge reports the estimate straight back, so the bridge, the Hue
-- app and Control4 agree at once [verified: house, the level-mode runs of
-- §7]. The alternative, "stop" (D8, option B), sends HUE_DIM stop, which
-- the bridge turns into Hue's dimming_delta stop (writing the estimate only
-- if Hue refuses it). It does halt an absolute transition on a light, but
-- the bridge keeps its cached level at the old target until the original
-- transition time is over (26 s in one run) and computes relative commands
-- from that stale level: a +10 nudge read target + 10 [verified: house, §7
-- L2]. A hold or a Raise in that window would start from the wrong level,
-- so "stop" lost. It stays for a later bridge firmware that corrects its
-- cache at the stop.
local STOP_MODE = "level"
-- A "level" stop glides to the estimate over this long instead of jumping:
-- Hue's fade runs slightly behind a linear estimate, so an instant level
-- (rate 0) showed as a small jump down, and a 1000 ms glide looked smooth
-- [verified: house, owner watching, #421 §7, measured 2026-11-09]. The
-- glide is no ramp of the device's (no record, nothing to stop): the cache
-- and the proxy hold the estimate already.
local STOP_GLIDE_MS = 1000

-- Turn-on state (docs/turn-on-design.md) -------------------------------------

-- True while the light is on, or while a Control4 turn-on of it is under
-- way whose report has not come yet (#427 D17): a brightness target above 0
-- sent from off (its pending record says turning_on), or a ramp to a level
-- above 0. The cache alone says off until the bridge reports the turn-on.
local function lit()
	if st.on == true or (ramp and ramp.to > 0) then
		return true
	end
	local pending = fallback.brightness
	return pending ~= nil and pending.turning_on == true
end

-- The level the light heads for: a ramp's target, a target the bridge has
-- not confirmed, else the level it shows (nil while unknown).
local function heading()
	if ramp then
		return ramp.to
	end
	local pending = fallback.brightness
	if pending and pending.target then
		return pending.target
	end
	return state.to_proxy_brightness(st)
end

-- The level the tile shows now (proxy percent; nil while unknown): a ramp's
-- estimate, a load group's hold's estimate (#435 D3), else the cache. A
-- target that replaces either starts its CHANGING from there.
local function shown()
	if ramp then
		return (ramp_estimate(ramp))
	end
	local held = groups and groups:holding()
	if held and held.ramping and held.level then
		return math.floor(held.level + 0.5)
	end
	return state.to_proxy_brightness(st)
end

-- What light.turnon decides from (§7.4): the On preset's level (Default On
-- Brightness), a zone or room light, the last level above 0 reported, the
-- level Hue keeps while the light is off, and the bulb's colour abilities.
local function context()
	return {
		preset = setting("preset"),
		group = state.is_group(st),
		last_on = mem.last_on,
		cached = st.brightness and on_level(st.brightness) or nil,
		has_color = st.has_color,
		has_cct = st.has_cct,
	}
end

-- #427 D15: a hold's blend waiting for its time after the release goes when
-- anything else moves the light: a brightness or colour command, a press.
local function cancel_hold_color()
	if mem.hold_color then
		mem.hold_color:Cancel()
		mem.hold_color = nil
	end
end

-- After a HUE_SET that carried a colour (`params`; `c` the proxy colour it
-- came from, nil when unknown): the colour CHANGING (§7.3), the colour
-- Control4 now expects to see (§7.4), and a colour target of its own, so
-- the proxy hears CHANGED for it even when Hue reports nothing new.
local function color_sent(c, rate, params)
	local fields = { x = params.x, y = params.y, mirek = params.mirek }
	if c then
		color_changing(c, rate, params)
	end
	mem.expected = color_of(params)
	arm("color", rate, function()
		log.debug("colour unconfirmed after %d ms; assuming it", rate + FALLBACK_MS)
		apply(fields)
		report_color()
	end)
end

-- #421 D5, D7: stop the running ramp where the light is by the clock; false
-- when none runs. The estimate is at least 1, so a stop near off leaves the
-- light on, as a dimmer stopped near the bottom does (§3). It goes into the
-- cache, where a hold or the next tap starts from it, and out as the ramp's
-- CHANGED at once. With nothing pending and no ramp, the bridge's next
-- report goes straight through: in "level" mode the estimate itself, at
-- once, which matches the cache and sends no second CHANGED; any other
-- level corrects it. A #308 wait ends with it. `why` names the stop in the
-- log. In "level" mode the stop carries the blend for the estimate while one
-- runs (#427 D15); HUE_DIM stop has no colour. `group` tags the stop with a
-- load group's GROUP ID when that group's GROUP_STOP_RAMP stops it, so the
-- bridge batches it with the other members' stops (#435 D12, D5); the
-- light's own stops (a tap, SET_BRIGHTNESS_STOP) pass none, whatever
-- started the ramp, and go out untagged (D11).
local function stop_ramp(why, group)
	local r = ramp
	if not r then
		return false
	end
	local level, elapsed = ramp_estimate(r)
	level = math.max(1, level)
	settle("brightness")
	log.debug("%s: the %sramp to %d %% stopped at %d %% after %d of %d ms", why, r.tap and "tap " or "", r.to, level,
		elapsed, r.time)
	if STOP_MODE == "level" then
		local c = turnon.level_color(modes, level, context())
		local fields = c and state.color_fields(st, c.x, c.y, c.mode) or nil
		local params, which = state.from_brightness_target(st, level, STOP_GLIDE_MS, { color = fields })
		params.urgent, params.group = "true", group -- #421 D12; #435 D12
		if send("HUE_SET", params) and which == "given" then
			color_sent(c, STOP_GLIDE_MS, params)
		end
	else
		send("HUE_DIM", { rid = st.rid, direction = "stop", level = string.format("%d", level), group = group })
	end
	mem.preset = nil -- a stop is no preset
	apply({ on = "true", brightness = tostring(level) })
	report_brightness()
	return true
end

-- SET_BRIGHTNESS_STOP / SET_COLOR_STOP with no ramp running: the proxy wants
-- the transition closed now. The cached value goes out as CHANGED (the next
-- real report corrects it if the bulb went on changing). With nothing cached
-- yet the target is assumed, as the fallback would have, so the proxy never
-- waits on a CHANGING.
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

-- The colour a brightness target carries (docs/turn-on-design.md §4): a
-- turn-off with a fade time the Dim colour (#427 D12); a target while the
-- light is lit the blend, while one runs (D14, D15); a turn-on from off the
-- colour its colour on mode asks for, C(level) (D10, D11, D13). nil for
-- none: Previous, no On colour known, a bulb without colour (light.turnon),
-- and a turn-off of a light that is off already.
local function target_color(target, rate, was_lit)
	if target <= 0 then
		return was_lit and turnon.off_color(modes, rate) or nil
	elseif was_lit then
		return turnon.level_color(modes, target, context())
	end
	return turnon.on_color(modes, target, context())
end

-- True when the target went to the bridge. When the send fails
-- (common/device.lua logs why) nothing changed: the proxy hears CHANGED with
-- the level its CHANGING came from, and a colour kept for the next turn-on
-- keeps waiting for it. A running ramp is replaced (#421 D11): the CHANGING
-- starts from its estimate, where the tile is. `opts`:
--   urgent     a keypad tap (#421 D12): the HUE_SET goes past the bridge's
--              request bucket
--   tap        marks the ramp a tap's, for the log
--   preset_id  the brightness preset the target is (#429 D7); an off names
--              the Off preset by itself when its id is known
--   native     a zone or room light's Previous turn-on: on without a
--              brightness, so Hue brings every lamp back at its own level;
--              `target` is only what the proxy is told (#429 D6), and no
--              #308 goal is set, since the group's level is only known from
--              Hue
--   group      the GROUP ID of the Control4 load group whose command this
--              is (#435 D5): the HUE_SET carries it, so the bridge batches
--              the members' requests, and a ramp keeps it (D12)
-- A target above 0 carries the colour of target_color (#427), unless a
-- colour stored while the light was off wins (D11); a turn-on from off then
-- starts or skips the blend (turnon.started). The rate is clamped (#430
-- D20). A load group's hold still running ends without a stop: the target
-- replaces its dim at Hue (#435, #421 D11). The target is clamped to 0..100
-- and one that is no finite number is dropped (#486 D-4): "inf" went out as
-- a brightness of -9223372036854775808, "nan" as "nan".
local function set_brightness(target, rate, opts)
	opts = opts or {}
	local raw = target
	target, rate = num.clamp(target, 0, 100), clamp_rate(rate)
	if not target then
		return log.warn("brightness command without a target%s", raw ~= nil and string.format(" (%q)", tostring(raw))
			or "")
	end
	if not ready("brightness target") then
		return
	end
	cancel_hold_color()
	local was_lit = lit()
	local current = shown() or 0
	end_ramp()
	groups:end_hold("a brightness target")
	-- From off, the level the turn-on waits for (#308); Hue raises a level
	-- below the bulb's lowest to that.
	local goal = st.on == false and target > 0 and not opts.native and on_level(math.max(target, st.min_dim or 0))
		or nil
	local c = target_color(target, rate, was_lit)
	local fields = c and state.color_fields(st, c.x, c.y, c.mode) or nil
	local preset_id = opts.preset_id
	if target <= 0 and preset_id == nil then
		preset_id = turnon.off_preset_id(modes)
	end
	local mark = mem.preset
	brightness_changing(current, target, rate, preset_id)
	local stored = st.pending_color
	local params, which = state.from_brightness_target(st, target, rate, { color = fields, native = opts.native })
	if opts.urgent then
		params.urgent = "true"
	end
	params.group = opts.group
	if not send("HUE_SET", params) then
		st.pending_color = stored
		mem.preset = mark
		brightness_changed(current)
		return false
	end
	local turning_on = target > 0 and not was_lit
	if turning_on then
		turnon.started(modes, which == "given")
	end
	if which == "given" then
		color_sent(c, rate, params)
	elseif which == "stored" then
		color_sent(mem.stored, rate, params)
		mem.stored = nil
	end
	arm("brightness", rate, function()
		log.debug("brightness target %s unconfirmed after %d ms; assuming it", tostring(target), rate + FALLBACK_MS)
		apply({ on = params.on, brightness = params.brightness })
		report_brightness()
	end, goal, current)
	fallback.brightness.target, fallback.brightness.turning_on = target, turning_on or nil
	-- #428 D9: an undelivered answer puts back the preset named before this
	-- CHANGING, as a send that fails does above.
	fallback.brightness.before = { preset = mark }
	if rate > 0 then
		begin_ramp(current, target, rate, opts.tap, opts.group)
	end
	return true
end

-- SET_COLOR_TARGET. `id` and `origin` name the colour preset it comes from,
-- when the proxy says (#427 D16); without x and y the learned preset gives
-- them. The on colour (turnon.is_on_color) leaves a blend running; any other
-- is explicit and ends a Preset blend (D14). While a Control4 turn-on is
-- under way the colour goes out at once (D17); the on colour then goes out
-- as the blend for where the light heads, so both orders of the proxy's
-- turn-on commands end alike. While the light is off a colour waits for the
-- next turn-on (light_v2 best practice), except the on colour, which the
-- next turn-on sends by itself, blended for its level (D11). #486 D-4: x and
-- y are taken in 0..1 only, the mode as 0 or 1 (else xy), the preset's id
-- and origin as finite numbers; anything else is dropped, never sent ("nan"
-- went out as x = "nan").
local function set_color(x, y, mode, rate, id, origin)
	x, y, id, origin = num.within(x, 0, 1), num.within(y, 0, 1), num.finite(id), num.finite(origin)
	if not (x and y) and id then
		local known = turnon.color_for_preset(modes, id, origin)
		if known then
			x, y, mode = num.within(known.x, 0, 1), num.within(known.y, 0, 1), mode or known.mode
		end
	end
	mode, rate = num.int(mode, state.MODE_XY, state.MODE_CCT, state.MODE_XY), clamp_rate(rate)
	if not (x and y) then
		return log.warn("colour command without x/y%s", id and (" (preset " .. tostring(id) .. " not known)") or "")
	end
	if not ready("colour target") then
		return
	end
	cancel_hold_color()
	local soon = lit()
	local on_color = turnon.is_on_color(modes, x, y, mode, id, origin)
	local target = { x = x, y = y, mode = mode, id = id, origin = origin }
	local level = soon and on_color and heading() or nil
	local blend = level and level > 0 and turnon.level_color(modes, level, context()) or nil
	if blend then
		target.x, target.y, target.mode = blend.x, blend.y, blend.mode
	end
	color_changing(target, rate, state.color_fields(st, target.x, target.y, target.mode))
	local params, why = state.from_color_target(st, target.x, target.y, target.mode, rate, { on_soon = soon })
	if params then
		if not send("HUE_SET", params) then
			-- Nothing reached the bridge (logged): the proxy hears the colour
			-- the light still has, when one is known, as for an ignored target.
			report_color()
			return
		end
		mem.expected = color_of(params)
		if not on_color then
			turnon.explicit_color(modes)
		end
		arm("color", rate, function()
			log.debug("colour target unconfirmed after %d ms; assuming it", rate + FALLBACK_MS)
			apply(params)
			report_color()
		end)
	elseif why == "stored" then
		-- Light off: the colour waits for the next turn-on (light_v2 best
		-- practice). The proxy still needs its CHANGED, and the colour it
		-- asked for is what the light will show.
		if on_color and turnon.on_color(modes, setting("preset"), context()) then
			st.pending_color, mem.stored = nil, nil
			log.debug("light is off; the on colour goes with the next turn-on, blended for its level")
		else
			mem.stored = target
			log.debug("light is off; colour stored for the next turn-on")
		end
		notify("LIGHT_COLOR_CHANGED", {
			LIGHT_COLOR_CURRENT_X = x,
			LIGHT_COLOR_CURRENT_Y = y,
			LIGHT_COLOR_CURRENT_COLOR_MODE = mode,
			LIGHT_COLOR_CURRENT_PRESET_ID = id,
			LIGHT_COLOR_CURRENT_PRESET_ORIGIN = id and origin or nil,
		})
	else
		log.warn("colour target ignored: %s", tostring(why))
		report_color()
	end
end

-- The brightness On Mode (#429 D5, D6): a turn-on from off goes to the
-- level the mode names, with the preset it is; a zone or room light's
-- Previous is Hue's own on (native). `rate_for(level)` gives the ramp time
-- for that level; the opts are set_brightness's.
local function turn_on(rate_for, opts)
	local go = turnon.turn_on(modes, context())
	opts = opts or {}
	opts.preset_id, opts.native = go.preset_id, go.native or nil
	return set_brightness(go.level, rate_for(go.level), opts)
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
-- when Director's lookup does not reflect the new binding yet. The load
-- groups follow every hello (#435 D6, E19: the bridge keeps them in memory
-- only), and the Load Groups row is written with them (E5: names read now).
-- The first configure after it may move the device to another rid (#483
-- D-1, dev.greeted); a configure that would without one makes the device
-- ask again (dev.greet), through the bridge it has.
local function hello(hint)
	bridge = bound_bridge() or tonumber(hint)
	if bridge then
		dev.send_to(bridge, "HUE_HELLO", hello_params())
		dev.greeted()
		dev.flush_log() -- dev builds: lines logged while the bridge was unknown
	end
	refresh_status()
	groups:announce()
end

function dev.greet()
	hello(bridge)
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
-- #483 D-1: one that would move the device to another rid is taken only as
-- the answer to its hello (dev.configure_ok).
dispatch.commands["HUE_CONFIGURE"] = after_late_init("HUE_CONFIGURE", function(params)
	if not dev.configure_ok("HUE_CONFIGURE", params) then
		return
	end
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
	-- Both supports_* in one notify, then the rate ranges in a second one of
	-- their own (#430 D20, §7.2: a proxy that refuses them cannot take the
	-- colour flags down too), then the current colour (the proxy docs ask for
	-- it straight after the colour flags), then brightness.
	notify("DYNAMIC_CAPABILITIES_CHANGED", caps.params(st))
	notify("DYNAMIC_CAPABILITIES_CHANGED", caps.rate_params())
	report_color()
	report_brightness()
	report_online()
	refresh_status()
end)

-- §7.4: a reported colour no Control4 command explains (none pending, and
-- not the colour Control4 last sent or saw confirmed, within FOREIGN_XY or
-- FOREIGN_MIREK) was changed in Hue: the Hue app, a switch, a Hue scene. A
-- Preset blend ends there (#427 D14); nothing is pushed back (§5). Either
-- way the reported colour is the one expected from now on.
local function noticed_color(confirming)
	local seen = cached_color()
	if not seen then
		return
	end
	if not confirming and mem.expected and not shows(mem.expected) then
		log.debug("colour changed outside Control4")
		turnon.foreign_color(modes)
	end
	mem.expected = seen
end

-- The bridge's link (#428, docs/offline-design.md) ----------------------------

-- The proxy hears the level the cache shows, or, while it shows none (a
-- light the bridge has no model of), `from`: the level the CHANGING it
-- closes started from (#428 D9, L4). Nothing without either.
local function report_known(from)
	if not report_brightness() and from then
		brightness_changed(from)
	end
end

-- #428 D8, D9 (§6.2): a HUE_STATE with reason "undelivered", the bridge's
-- answer to a PUT for this light (a zone or room light: its grouped_light)
-- that did not land, carrying what the bridge last knew (only the rid when
-- it has no model of the light). Nothing of it is held back (#421 D10 does
-- not apply): the running ramp ends, the brightness and colour targets
-- settle with no fallback left to assume them, a report held back for
-- either goes into the cache under the answer's fields, and the proxy hears
-- them as CHANGED: the level the bridge knows, not the target. The keypad
-- LEDs follow (L53). The brightness preset named before that CHANGING
-- comes back, as for a send that fails (#429 D7); a light the answer shows
-- off ends a blend its turn-on started (#427 D14, as apply does for a light
-- that goes off); and the colour reported is the one Control4 expects from
-- now on (§7.4), with no foreign change read into it. A hold in progress
-- goes on: its release sends the stop as usual, and the stop's own failure
-- brings the next answer.
local function undelivered(params)
	local pending = fallback.brightness
	if pending and pending.before then
		mem.preset = pending.before.preset
	end
	settle("brightness")
	settle("color")
	local changed = apply(params)
	if st.on == false then
		turnon.ended(modes)
	end
	mem.expected = cached_color() or mem.expected
	log.debug("undelivered: the proxy hears what the bridge last knew (%s)",
		st.on == nil and "nothing" or (st.on and ("on at " .. tostring(state.to_proxy_brightness(st)) .. " %") or "off"))
	report_known(pending and pending.from)
	report_color()
	if changed.online then
		report_online()
		refresh_status()
	end
end

-- #428 D5, D6 (common/device.lua calls it at every HUE_BRIDGE_LINK). Going
-- offline, a ramp running or a target pending ends with the cached state,
-- a report held back for it included, and the proxy hears it: nothing is
-- assumed, since the command may not have landed. A hold's blend still
-- waiting goes. Either way ONLINE_CHANGED and Status follow (is_online,
-- blocker); back online, the resync that every stream connect runs brings
-- the state (D7). An unchanged link changes nothing.
function dev.on_link(_, changed)
	if not changed then
		return
	end
	if dev.link_offline() then
		local pending = fallback.brightness
		local moving, coloring = pending ~= nil or ramp ~= nil, fallback.color ~= nil
		settle("brightness")
		settle("color")
		cancel_hold_color()
		if moving then
			report_known(pending and pending.from)
		end
		if coloring then
			report_color()
		end
	end
	report_online()
	refresh_status()
end

-- #433 D12: a HUE_STATE that changed the level the proxy shows, already in
-- the cache. It goes out at once, and the throttle's window starts again
-- after it, when it settled a pending Control4 target (a ramp's foreign
-- report included: the proxy heard CHANGING and waits for its CHANGED),
-- when it turns the light on or off against the last level sent (the
-- first report of all too; L53, L6), or when it is a full state (`reason`
-- hello, resync or import, not "event"; L5). Anything else is a level Hue
-- reports while it moves (the Hue app, a Hue switch, a Hue automation): at
-- most one CHANGED per LEVEL_REPORT_MS, the first at once and the latest at
-- the window's end (L7). Only the notification waits: the cache already
-- holds the level, so Raise, Restore, the tap rule and the next CHANGING
-- read it exactly, and the LEDs follow it now (they change only with an
-- on or off, which never waits).
local function report_level(reason, settled)
	local full = reason ~= nil and reason ~= "" and reason ~= "event"
	if settled or full or levels:edge(state.to_proxy_brightness(st)) then
		if report_brightness() then
			levels:open()
		end
		return
	end
	update_leds()
	levels:report()
end

-- #483 D-1: once the device has a rid, a state that does not name it (another
-- rid, or none) is not this device's (dev.addressed); before #483 one without
-- a rid was taken, and one for another rid ignored with a warning.
dispatch.commands["HUE_STATE"] = after_late_init("HUE_STATE", function(params)
	if not dev.addressed("HUE_STATE", params) then
		return
	end
	if params.reason == "undelivered" then
		return undelivered(params)
	end
	params = hold_back(params)
	local colored = params.x ~= nil or params.mirek ~= nil or params.color_mode ~= nil
	local confirming = fallback.color ~= nil
	local changed = apply(params)
	-- Any report of a pending field that got past hold_back settles the
	-- target, whatever the value: the proxy heard CHANGING and must hear
	-- CHANGED, at once (#433 D12). One held back for a ramp settles it at
	-- the ramp's end.
	local settled = false
	if fallback.brightness and (params.on ~= nil or params.brightness ~= nil) then
		settle("brightness")
		changed.brightness, settled = true, true
	end
	if colored then
		noticed_color(confirming)
	end
	if fallback.color and colored then
		settle("color")
		changed.color = true
	end
	-- Colour reports are not throttled (#433 D16, owner 2026-11-09).
	if changed.brightness then report_level(params.reason, settled) end
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
	if not dev.addressed("HUE_FORGOTTEN", params) then -- #483 D-1, as HUE_STATE
		return
	end
	st.forgotten = { name = params.name or st.name }
	settle("brightness")
	settle("color")
	levels:close() -- #433 §6.5: no Hue-side level of a forgotten light still to come
	log.warn("forgotten by the bridge (was %s)", was_label())
	-- A group's Status names the group, so the instruction goes here.
	prop("Last Action", state.is_group(st) and FORGOTTEN_INSTRUCTION or "Forgotten by the bridge")
	refresh_status()
	report_online()
end)

-- Hidden aliases (LUA_ACTION or by name) ------------------------------------
-- Since 1.2 the device has no actions (#334, docs/simplify-actions-design.md
-- §1.2, D3): names follow Hue by themselves and the Hue Bridge's Resolve
-- Names settles what cannot, its Forget Device releases any device. The two
-- old commands still answer as they did, for the dev loop, older briefs and
-- any C4:SendToDevice caller, until 2.0 (§3.3; tests/fixtures/ledger.lua
-- lists them). Every call ends in Last Action and a log line, whatever
-- happened.

-- `fn` under the old command, saying in the log (Debug Mode) what replaced it.
local function alias(old, now, fn)
	return function(...)
		log.info("%s is a hidden alias until 2.0; %s on the Hue Bridge does this now", old, now)
		return fn(...)
	end
end

-- The Composer name the Hue name calls for: the Hue name itself, except that
-- a room device is "<Room> Lights", so the Lighting page of a Control4 room
-- does not list a light named like the room (docs/zone-light-design.md §5
-- Naming; the bridge's Attention and Resolve Names apply the same rule).
local function expected_name()
	if state.is_group(st) and st.group_type == "room" then
		return st.name .. " Lights"
	end
	return st.name
end

-- Rename our proxy (the device Composer shows) to the Hue name. Only ever
-- from this command: names belong to the owner (docs/import-design.md §7).
dispatch.commands["Adopt_Hue_Name"] = alias("Adopt Hue Name", "Resolve Names", function()
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
end)

-- Ask the bridge to Forget this light (or zone/room device); it answers
-- HUE_FORGOTTEN, which sets Status. The bridge finds the entry by rid or,
-- for a rid-less light, by device id.
dispatch.commands["Forget_This_Light"] = alias("Forget This Light", "Forget Device", function()
	if not bridge then
		return result("Not sent: not bound to a Hue Bridge")
	end
	dev.send_to(bridge, "HUE_FORGET", { rid = st.rid, device_id = device_id() }) -- #493 D-8: logged only in Debug Mode
	result(string.format("Asked the bridge to forget this %s; its answer sets Status", what()))
end)

-- Programming commands -------------------------------------------------------
-- Raise Level By and Restore Saved Level (docs/relative-level-design.md,
-- #297): two primitives stock programming lacks, for "when motion is
-- sensed, raise the lamp by 30 points; when it stops, put it back".
-- Programming decides when; nothing here runs on its own. driver.xml
-- declares them in <commands>; Director hands each to ExecuteCommand under
-- its name, spaces and all ("Raise Level By", which common.dispatch keys as
-- Raise_Level_By), with the parameters keyed by their names [verified: API
-- 5/_1, "includes commands created in Composer programming"; FUND 15/_4;
-- FUND 12.3/_1, whose sample reads tParams["Select List Item"] for its
-- programming command "CUSTOM_SELECT List"]. Values are read with tonumber,
-- strings and numbers alike [assumed: Director sends strings].
--
-- Both drive the light through set_brightness, the slider's own path
-- (CHANGING, HUE_SET, the fallback), so the bridge queues, coalesces and
-- rate-limits them as it does the slider. A device blocker() names (gone,
-- unbound, forgotten, no Hue light assigned yet, a zone or room without
-- lights) refuses both and keeps what was saved. Like the bridge's
-- messages they wait for late init, before which UpdateProperty is not safe
-- (after_late_init), and every outcome ends in Last Action and a log line
-- (result).

-- What a Raise saved, until a Restore uses or drops it: { level = the level
-- it started from (0 off), target = the level the last Raise set, at =
-- os.time() of the save, nil when unknown }. Persisted as one table, so a
-- driver restart or update in between keeps it [verified: API 26.5/_4,
-- tables allowed].
local SAVED_KEY = "saved_level"
local saved = nil

-- The parameters as driver.xml declares them; one absent or empty is the
-- default.
local POINTS = { name = "Points", min = 1, max = 100, default = 30 }
local RAMP = { name = "Ramp (ms)", min = 0, max = 60000, default = 1000 }

-- A parameter as a whole number (rounded) inside its range; otherwise nil
-- and why, for Last Action. Composer's RANGED_INTEGER never sends anything
-- else; a value from elsewhere is refused rather than guessed at (a
-- negative Points would lower the lamp).
local function param(params, spec)
	local raw = params[spec.name]
	if raw == nil or raw == "" then
		return spec.default
	end
	local n = tonumber(raw)
	n = n and math.floor(n + 0.5)
	if not (n and n >= spec.min and n <= spec.max) then -- NaN fails both
		return nil, string.format("%s must be %d to %d, not %s", spec.name, spec.min, spec.max, tostring(raw))
	end
	return n
end

-- "40 %"; "off" for 0.
local function level_text(level)
	if level == 0 then
		return "off"
	end
	return string.format("%d %%", level)
end

-- When the saved level was saved: "at 14:02" today, "2026-10-24 14:02" on
-- another day (a Restore that never came); nil when unknown. Through
-- num.date (#487 D-6), as the time was persisted.
local function saved_when(at)
	if not at then
		return nil
	end
	if num.date("%Y-%m-%d", at) == os.date("%Y-%m-%d") then
		return "at " .. num.date("%H:%M", at)
	end
	return num.date("%Y-%m-%d %H:%M", at)
end

-- The memory and the stored copy are separate tables: the database keeps
-- what was written, not a live reference.
local function save(level, target, at)
	saved = { level = level, target = target, at = at }
	C4:PersistSetValue(SAVED_KEY, { level = level, target = target, at = at })
end

local function forget_saved()
	saved = nil
	C4:PersistDeleteValue(SAVED_KEY)
end

-- At late init, before the buffered messages and commands run: what a Raise
-- saved before the restart. Anything else under the key (not a table, a
-- level out of range) is dropped with a warning, never restored. A time
-- num.timestamp refuses is cleared, stored copy included, and the level
-- kept with its time unknown (#487 D-6).
local function load_saved()
	saved = nil
	local value = C4:PersistGetValue(SAVED_KEY)
	if value == nil then
		return
	end
	local level = type(value) == "table" and num.within(value.level, 0, 100) or nil
	local target = type(value) == "table" and num.within(value.target, 1, 100) or nil
	if level and target then
		local at = num.timestamp(value.at)
		saved = { level = math.floor(level + 0.5), target = math.floor(target + 0.5), at = at }
		if value.at ~= nil and not at then
			log.warn("stored %s time %s is not a time; cleared", SAVED_KEY, tostring(value.at))
			save(saved.level, saved.target, nil)
		end
	else
		log.warn("stored %s is not a saved level (%s); dropped", SAVED_KEY, tostring(value))
		C4:PersistDeleteValue(SAVED_KEY)
	end
end

-- The level Raise Level By and Restore Saved Level take the light to be at:
-- the one it shows; while a ramp runs (#421 D6), the level the ramp heads
-- for, where the light ends without further input (the light_v2 guidance's
-- target), or what the bridge reported meanwhile, held back for the ramp's
-- end (D10). A ramp's own way to its target is nobody's change: a Restore
-- during the Raise's ramp still restores, and a second Raise during it does
-- not climb. A tap stop is a change: it leaves its estimate in the cache.
local function level_now()
	if not ramp then
		return state.to_proxy_brightness(st)
	end
	local pending = fallback.brightness
	local held = pending and not pending.stale and pending.held
	if not held then
		return math.floor(ramp.to + 0.5)
	end
	local on = device.to_bool(held.on)
	if on == nil then
		on = st.on
	end
	return state.to_proxy_brightness({ on = on, brightness = num.finite(held.brightness) or st.brightness })
end

-- " (capped; saved 40 %)": the notes after a Raise, "" without any.
local function notes(list)
	if #list == 0 then
		return ""
	end
	return " (" .. table.concat(list, "; ") .. ")"
end

-- Nothing saved: the level the light shows (0 while off) is saved with the
-- time, and the light goes to it plus Points, capped at 100. Saved already:
-- the light goes to the saved level plus Points again, so a Raise repeated
-- before the Restore never climbs; the saved level and its time stay, only
-- the target follows this Raise. Saved, but the light stands neither where
-- the last Raise put it nor at the saved level (someone changed it since):
-- that change is the new
-- starting point, so a Raise never lowers a light turned up by hand; the
-- old saved level is dropped and the current one saved. Nothing is saved when the command never
-- reached the bridge (set_brightness logs it and closes the proxy's
-- CHANGING). A ramp running meanwhile is replaced (#421 D11), and the level
-- it heads for counts as the light's (level_now).
dispatch.commands["Raise_Level_By"] = after_late_init("Raise Level By", function(params)
	local points, ramp_ms, why
	points, why = param(params, POINTS)
	if points then
		ramp_ms, why = param(params, RAMP)
	end
	why = why or blocker()
	if why then
		return result("Not raised: " .. why)
	end
	local now = level_now()
	local restarted = nil
	-- Still at the saved level counts as unchanged too: the bridge may not
	-- have reported the last Raise's level yet.
	if saved and now ~= nil and math.abs(now - saved.target) > 1 and math.abs(now - saved.level) > 1 then
		restarted = level_text(saved.level)
		forget_saved()
	end
	local from = saved and saved.level or now
	if from == nil then
		return result(string.format("Not raised: the %s's level is not known yet", what()))
	end
	local target = math.min(100, from + points)
	if not set_brightness(target, ramp_ms) then
		return result("Not raised: the command did not reach the bridge")
	end
	local list = {}
	if target < from + points then
		list[1] = "capped"
	end
	if saved then
		if saved.target ~= target then
			save(saved.level, target, saved.at)
		end
		local when = saved_when(saved.at)
		list[#list + 1] = when and ("saved " .. when) or nil
		return result(string.format("Raised from %s to %d %% again%s", level_text(from), target, notes(list)))
	end
	save(from, target, os.time())
	list[#list + 1] = "saved " .. level_text(from)
	if restarted then
		list[#list + 1] = "changed since the last raise; " .. restarted .. " no longer kept"
	end
	result(string.format("Raised from %s to %d %%%s", level_text(from), target, notes(list)))
end)

-- Only a light still where the last Raise put it goes back: within a point
-- of the target, since Hue reports its Zigbee level (a requested 70 comes
-- back as 70.08). Any other level, or off, is someone's change, which a
-- Restore must not undo: the light stays, and the saved level is dropped.
-- A level not known yet (a restart the bridge has not answered) is no
-- change: the saved level stays for the next Restore. While a ramp runs the
-- level it heads for counts (level_now): a Restore during the Raise's own
-- ramp still puts the light back and replaces that ramp (#421 D11); one
-- that finds someone else's change leaves the ramp alone, as it leaves the
-- light.
dispatch.commands["Restore_Saved_Level"] = after_late_init("Restore Saved Level", function(params)
	if not saved then
		return result("Nothing to restore")
	end
	local kept = string.format(" (saved %s kept)", level_text(saved.level))
	local ramp_ms, why = param(params, RAMP)
	why = why or blocker()
	if why then
		return result("Not restored: " .. why .. kept)
	end
	local now = level_now()
	if now == nil then
		return result(string.format("Not restored: the %s's level is not known yet%s", what(), kept))
	end
	if now == 0 or math.abs(now - saved.target) > 1 then
		forget_saved()
		return result(string.format("Not restored: %s since the raise; saved level forgotten",
			now == 0 and "turned off" or string.format("changed to %d %%", now)))
	end
	local level = saved.level
	if not set_brightness(level, ramp_ms) then
		return result("Not restored: the command did not reach the bridge" .. kept)
	end
	forget_saved()
	result("Restored to " .. level_text(level))
end)

-- From the proxy (ReceivedFromProxy) ------------------------------------------
-- Commands without a handler are logged at debug by common.dispatch. The
-- first arrival of each turn-on command per driver start is logged at debug
-- with every parameter (§7.3, dev.first_arrival): their names and the order
-- the proxy sends them in can only be seen on a controller (D27, checks
-- T2-T11).

-- The proxy asks for current state after Director starts or a UI connects.
dispatch.proxy["SYNCHRONIZE"] = function()
	report_online()
	report_brightness()
	report_color()
end

local function pick(params, names)
	for _, name in ipairs(names) do
		if params[name] ~= nil then
			return params[name]
		end
	end
	return nil
end

-- A rate the command left out (or sent empty) is the proxy's default rate
-- (#430 D8, common/device.lua); 0 until the proxy sends one. So, since #486
-- (D-4), is one that is no finite number, as the Hue Scene takes it.
local function rate_or_default(rate, which)
	if num.finite(rate) == nil then
		return dev.rate_default(which)
	end
	return rate
end

-- #429 D7, D6: the preset the target names goes into the notifies; on a
-- zone or room light that is off, the Previous preset is Hue's own on, as
-- for any Previous turn-on.
dispatch.proxy["SET_BRIGHTNESS_TARGET"] = function(_, params)
	dev.first_arrival("SET_BRIGHTNESS_TARGET", params)
	local id = num.finite(pick(params, BRIGHTNESS_PRESET_KEYS)) -- #486 D-4
	local target = num.finite(params.LIGHT_BRIGHTNESS_TARGET)
	local native = id ~= nil and target ~= nil and target > 0 and state.is_group(st) and not lit()
		and turnon.is_previous_preset(modes, id)
	set_brightness(params.LIGHT_BRIGHTNESS_TARGET, rate_or_default(params.RATE, "brightness"),
		{ preset_id = id, native = native or nil })
end

-- A Navigator's colour pick arrives as LIGHT_COLOR_TARGET_MODE 0 with X and
-- Y, a temperature pick as mode 1 with the temperature's X and Y, and RATE
-- [verified: hardware 2026-10-22, the one-time parameter log this driver
-- carried until 2026-10-25, checklist D.10]; the other spellings in
-- COLOR_KEYS are kept for other proxy versions [assumed]. With colour on
-- modes it can name a preset instead (#427 D16).
dispatch.proxy["SET_COLOR_TARGET"] = function(_, params)
	dev.first_arrival("SET_COLOR_TARGET", params)
	set_color(pick(params, COLOR_KEYS.x), pick(params, COLOR_KEYS.y), pick(params, COLOR_KEYS.mode),
		rate_or_default(pick(params, COLOR_KEYS.rate), "color"), pick(params, COLOR_KEYS.preset_id),
		pick(params, COLOR_KEYS.preset_origin))
end

-- Advanced Lighting Scenes with reduced_als_support drive the light with
-- SET_BRIGHTNESS_TARGET / SET_COLOR_TARGET and end a scene ramp with these;
-- both carry no parameters [verified: proxy-protocol reference, light_v2
-- SET_BRIGHTNESS_STOP, SET_COLOR_STOP, reduced_als_support,
-- supports_brightness_stop]. A brightness stop while a ramp runs stops it
-- at Hue exactly as a keypad tap does (#421 D7, stop_ramp, STOP_MODE): the
-- stop goes to the bridge and the proxy hears the estimate. With no ramp
-- running, nothing goes to the bridge: the proxy only needs its CHANGED
-- (stop). A load group's hold is stopped as its own GROUP_STOP_RAMP would,
-- untagged (#435 D12, D11). A colour transition has no stop at Hue:
-- SET_COLOR_STOP only closes the proxy's.
dispatch.proxy["SET_BRIGHTNESS_STOP"] = function()
	if not stop_ramp("brightness stop") and not groups:stop_hold("brightness stop") then
		stop("brightness", report_brightness)
	end
end

dispatch.proxy["SET_COLOR_STOP"] = function()
	stop("color", report_color)
end

-- The ALS section lists STOP_SCENE_RAMP among what a reduced-ALS driver must
-- support; whether the proxy forwards it under that name is unverified, so it
-- is accepted as a brightness stop.
dispatch.proxy["STOP_SCENE_RAMP"] = dispatch.proxy["SET_BRIGHTNESS_STOP"]

-- ON, TOGGLE and OFF over the proxy's default brightness rate (#430 D8; 0,
-- at once as before, until the proxy sends one). From off, ON and TOGGLE
-- follow the brightness On Mode (#429 D5, D6; turn_on): Preset, the
-- default, goes to the On preset at the Default On Brightness as before
-- (#233), Previous to the level the light had. TOGGLE from off activates the
-- On Mode [verified: proxy reference, light_v2 TOGGLE]. ON on a light
-- already on goes to the on mode preset's level, in Previous mode to the On
-- preset, as the top tap does (D5) [verified: proxy reference, light_v2
-- variables, Default On Preset Brightness]. A preset never set reads as 100,
-- the level both commands always had, and one out of range (0 included) is
-- never taken (common/device.lua), so neither turns a light off. A zone or
-- room light sends the same HUE_SET and the bridge sets every lamp. Whether
-- the light is on counts a Control4 turn-on under way (lit), so a second
-- TOGGLE right after the first turns the light off again.
local function default_rate()
	return dev.rate_default("brightness")
end

local function turn_off()
	set_brightness(0, default_rate())
end

dispatch.proxy["TOGGLE"] = function()
	if lit() then
		return turn_off()
	end
	turn_on(default_rate)
end

-- Legacy commands that old programming may still send. Which command
-- "Turn On" in programming sends is unverified; ON goes where TOGGLE does.
-- OFF on a light that shows off and has no turn-on under way only reports
-- (§4): there is nothing to fade, and no Dim colour to give it.
dispatch.proxy["ON"] = function()
	if lit() then
		local go = turnon.while_on(modes, context())
		return set_brightness(go.level, default_rate(), { preset_id = go.preset_id })
	end
	turn_on(default_rate)
end

dispatch.proxy["OFF"] = function()
	if st.on == false and not lit() then
		return report_brightness()
	end
	turn_off()
end

dispatch.proxy["SET_LEVEL"] = function(_, params) set_brightness(params.LEVEL, params.TIME) end
dispatch.proxy["RAMP_TO_LEVEL"] = function(_, params) set_brightness(params.LEVEL, params.TIME) end

-- #429 D25: from OS 3.3.2 Navigators send DYNAMIC_ON and DYNAMIC_OFF
-- [verified: LV2 cmds _1.3-DYNAMICON.md, _1.2-DYNAMICOFF.md]; whether the
-- proxy forwards them to a driver with On Modes or turns them into targets
-- itself is [assumed] (F21). Handled in case they arrive: on as ON from
-- off, at the default rate; off as OFF. On a light already on (or off),
-- only a report.
dispatch.proxy["DYNAMIC_ON"] = function(_, params)
	dev.first_arrival("DYNAMIC_ON", params)
	if lit() then
		return report_brightness()
	end
	turn_on(default_rate)
end

dispatch.proxy["DYNAMIC_OFF"] = function(_, params)
	dev.first_arrival("DYNAMIC_OFF", params)
	if st.on == false and not lit() then
		return report_brightness()
	end
	turn_off()
end

-- What the proxy tells a driver with On Modes (#429 D4, #427 D10, D16): the
-- on modes and the presets, kept and persisted by light.turnon and used
-- from the next command. None of them moves the light (D26): when a preset
-- the light sits at changes, the proxy moves it itself (F8). The On
-- preset's level also becomes the Default On Brightness the keypad uses,
-- without the PRESET_LEVEL echo SET_PRESET_LEVEL gets, so proxy and driver
-- never ping-pong (D4, dev.take_setting, which warns about a value out of
-- range itself).
dispatch.proxy["UPDATE_BRIGHTNESS_ON_MODE"] = function(_, params)
	dev.first_arrival("UPDATE_BRIGHTNESS_ON_MODE", params)
	if turnon.update_brightness_on_mode(modes, params) then
		log.debug("brightness On Mode now %s", (turnon.modes(modes)))
	end
end

dispatch.proxy["UPDATE_BRIGHTNESS_PRESET"] = function(_, params)
	dev.first_arrival("UPDATE_BRIGHTNESS_PRESET", params)
	local _, level = turnon.update_brightness_preset(modes, params)
	local before = setting("preset")
	if level and dev.take_setting("preset", level) and setting("preset") ~= before then
		log.debug("Default On Brightness now %s %% (UPDATE_BRIGHTNESS_PRESET)", tostring(setting("preset")))
	end
end

dispatch.proxy["UPDATE_COLOR_ON_MODE"] = function(_, params)
	dev.first_arrival("UPDATE_COLOR_ON_MODE", params)
	if turnon.update_color_on_mode(modes, params) then
		log.debug("colour on mode now %s", select(2, turnon.modes(modes)))
	end
end

dispatch.proxy["UPDATE_COLOR_PRESET"] = function(_, params)
	dev.first_arrival("UPDATE_COLOR_PRESET", params)
	turnon.update_color_preset(modes, params)
end

-- Keypad buttons ----------------------------------------------------------
-- What a tap and a hold do to a light; the press / click / release machine
-- and the proxy's preset and rates are common/device.lua's. A hold's record
-- carries its own ramp (#249; `ramp` above is a tap's or a timed target's,
-- #421): ramping, the level estimate, its step and its end (to).
-- Behaviour: docs/keypad-design.md, "Driver behaviour" and "Light parity".
local BUTTON_TOP, BUTTON_BOTTOM = device.BUTTON_TOP, device.BUTTON_BOTTOM
local HOLD_TICK_MS = 100 -- the level estimate advances this often during a ramp
-- A longer hold rate is used as this, for the light and its tile alike: the
-- bound the bridge holds a zone light's and a scene's hold to (100 minutes;
-- zone_lights.DIM_MAX_DURATION, scenes.DIM_MAX_DURATION), which a light's
-- lacked (#234); since #430 D20 also the most the proxy can set.
local HOLD_MAX_MS = RATE_MAX

-- A tap ramps the light, and a press while it ramps stops it (#421,
-- docs/tap-stop-design.md §3). Click rates are whole-range times, as hold
-- rates are (D3): a tap's ramp takes the rate's share of the distance,
-- rounded to whole ms; a rate of 0 is a change at once, with nothing to
-- stop. The start goes past the bridge's request bucket (D12). `preset_id`
-- and `native` as set_brightness's (#429 D6, D7).
local function tap(target, rate, distance, preset_id, native)
	set_brightness(target, math.floor(rate * distance / 100 + 0.5),
		{ urgent = true, tap = true, preset_id = preset_id, native = native })
end

-- An idle tap (§3). Top from off follows the brightness On Mode (#429 D5,
-- D6): Preset goes to the on mode preset (the On preset at the Default On
-- Brightness, D2 and #233, unless the dealer chose another), Previous to
-- the level the light had, over the click rate up's share of that level.
-- Top while on goes to turnon.while_on's level (the on mode preset; in
-- Previous mode the On preset): up to it from below over the click rate up,
-- down to it from above over the click rate down; at it (within a point)
-- nothing goes to Hue and the proxy hears the level, at that preset. Bottom
-- goes off over the click rate down's share of the level; off already,
-- nothing. Toggle goes off while the light shows on, else as top from off.
-- A light whose state is not known yet is taken as off by top and toggle,
-- and bottom turns it off over the whole rate. Colours as for any target
-- (set_brightness, #427). The machine stops a running ramp on the press and
-- swallows its click (D5, common/device.lua), so a click reaches here during
-- a ramp only when the ramp began between the press and the click: it stops
-- that one too, and so a load group's hold (#435 D12). A device that cannot
-- be driven drops the tap with its reason, as it drops a target.
function dev.on_click(button)
	if stop_ramp("tap") or groups:stop_hold("tap") or not ready("brightness target") then
		return
	end
	local on, level = st.on, state.to_proxy_brightness(st)
	if button == BUTTON_BOTTOM or (button ~= BUTTON_TOP and on) then
		if on == false then
			return log.debug("tap: the %s is off already", what())
		end
		return tap(0, setting("click_down"), level or 100)
	end
	if not on then
		local go = turnon.turn_on(modes, context())
		return tap(go.level, setting("click_up"), go.level, go.preset_id, go.native or nil)
	end
	local go = turnon.while_on(modes, context())
	if math.abs(level - go.level) <= 1 then
		log.debug("tap: at the on preset (%d %%) already", go.level)
		mem.preset = go.preset_id and { id = go.preset_id, level = go.level } or nil
		return report_brightness()
	end
	if level < go.level then
		return tap(go.level, setting("click_up"), go.level - level, go.preset_id)
	end
	tap(go.level, setting("click_down"), level - go.level, go.preset_id)
end

-- The machine's hooks for the stop (#421 D5, common/device.lua): a press
-- outside the double-tap window while a ramp runs stops it on the push, on
-- any button; a press held on afterwards holds from the stopped level. A
-- load group's hold is stopped the same way (#435 D12), its stop untagged
-- (D11): the light's own keypad wins over its group.
function dev.ramp_active()
	return ramp ~= nil or groups:holding() ~= nil
end

function dev.on_ramp_stop()
	if not stop_ramp("tap") then
		groups:stop_hold("tap")
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
--
-- `h` is the keypad machine's press record, or a load group's hold record
-- (#435 D3, light.load_group): `alive(h)` says whether it still runs
-- (dev.holding for a press, the record's active flag for a group hold),
-- `rate` is the whole-range time (a Hold Rate, or the group's RATE), and
-- the arithmetic is load_group.hold_plan's, one copy for both. A group
-- hold's dim carries its GROUP ID (h.group), so the members' dims batch.
local function start_ramp(h, up, from, alive, rate)
	local plan = load_group.hold_plan(from, up, rate, HOLD_MAX_MS)
	local to, full, duration = plan.to, plan.full, plan.duration
	h.ramping, h.level, h.to = true, from, to
	h.step = plan.step
	h.timer = C4:SetTimer(HOLD_TICK_MS, function()
		if not alive(h) then
			return
		end
		h.level = h.level + h.step
		if (h.step >= 0 and h.level >= h.to) or (h.step < 0 and h.level <= h.to) then
			h.level = h.to
			h.timer:Cancel()
		end
	end, true)
	-- The ramp replaces whatever target was pending (the turn-on at 1 %), and
	-- a brightness ramp still running (#421: a hold ends it).
	settle("brightness")
	brightness_changing(from, to, duration, nil) -- a hold names no preset (#429 D7)
	log.debug("hold: dim %s from %d, the tile over %d ms, Hue the whole range over %d ms", up and "up" or "down",
		from, duration, full)
	if not send("HUE_DIM", { rid = st.rid, direction = up and "up" or "down",
		duration = string.format("%d", full), group = h.group }) then
		h.timer:Cancel()
		h.timer, h.ramping = nil, false
		brightness_changed(from)
	end
end

-- A hold began (the machine chose the direction; down from off does
-- nothing): on, the ramp starts from the level shown; off, the light turns
-- on at 1 % first and the ramp up follows (dev.dim_after_on). A press that
-- stopped a ramp (#421 D5, h.stopped) holds from the stopped level, which
-- the stop left in the cache. A ramp that began after the press (from
-- programming, say) holds from its estimate, and the hold's dim replaces it
-- at Hue [assumed: #421 §7 L9]; start_ramp ends its record. So does a load
-- group's hold still running (a press in the double-tap window stops
-- nothing): the keypad wins, its record ends without a stop (#435 §6.6).
function dev.on_hold(h, up, on)
	cancel_hold_color()
	if not ready("hold") then
		return
	end
	if on then
		local from = shown() or 1
		groups:end_hold("a keypad hold")
		return start_ramp(h, up, math.max(1, from), dev.holding, setting(up and "hold_up" or "hold_down"))
	end
	groups:end_hold("a keypad hold")
	if not set_brightness(1, 0) then
		return -- the turn-on never reached the bridge (logged): nothing to dim up from
	end
	dev.dim_after_on(h, function()
		start_ramp(h, true, st.on == true and state.to_proxy_brightness(st) or 1, dev.holding, setting("hold_up"))
	end)
end

-- #427 D15: a hold carries no colour, since Hue's dimming_delta has no
-- colour curve (guidelines D12), and the Dim colour never goes with a hold
-- down, whose end is unknown (D12). HOLD_COLOR_DELAY_MS after the release,
-- once the stop has gone out (a colour merged onto a pending dim stop is
-- dropped by the bridge's queue, docs/tap-stop-design.md §8), the blend for
-- the level reached glides in over HOLD_COLOR_GLIDE_MS, while a blend runs
-- (in Fade mode always). The level is the bridge's report of the stop, or
-- the release's estimate while that has not come. A press, or any
-- brightness or colour command, cancels it first (cancel_hold_color).
-- Nothing is armed while no blend would follow.
local function hold_color(estimate)
	cancel_hold_color()
	if not turnon.level_color(modes, estimate, context()) then
		return
	end
	mem.hold_color = C4:SetTimer(HOLD_COLOR_DELAY_MS, function()
		mem.hold_color = nil
		if blocker() then
			return
		end
		local level = (not fallback.brightness and state.to_proxy_brightness(st)) or estimate
		local c = turnon.level_color(modes, level, context())
		local fields = c and state.color_fields(st, c.x, c.y, c.mode) or nil
		if not fields then
			return
		end
		local params = { rid = st.rid, rate = string.format("%d", HOLD_COLOR_GLIDE_MS) }
		for k, v in pairs(fields) do
			params[k] = v
		end
		log.debug("hold: the blend for %d %% follows the release", level)
		if send("HUE_SET", params) then
			color_sent(c, HOLD_COLOR_GLIDE_MS, params)
		end
	end)
end

-- The release (or release-as-click) after a hold: stop the dim at Hue,
-- which keeps the level it reached; `level` is the estimate, for the bridge
-- to write should Hue refuse the stop. The proxy hears the bridge's next
-- report, or the estimate after the fallback time, also when the stop
-- itself never reaches the bridge (logged; Hue then dims on to the end of
-- the range and reports it). The machine has armed the click guard. The
-- blend follows (hold_color). A load group's hold ends here too (#435 D12):
-- `group` tags the stop when the group's own GROUP_STOP_RAMP ended it, so
-- it batches with the other members' stops; the light's own stop of it
-- goes untagged (D11).
local function finish(h, group)
	if not (h.ramping and bridge and st.rid) then
		return
	end
	local level = math.floor(h.level + 0.5)
	send("HUE_DIM", { rid = st.rid, direction = "stop", level = string.format("%d", level), group = group })
	arm("brightness", 0, function()
		log.debug("dim stop unconfirmed after %d ms; assuming %d %%", FALLBACK_MS, level)
		apply({ on = "true", brightness = tostring(level) })
		report_brightness()
	end)
	hold_color(level)
end

function dev.on_finish(h)
	finish(h)
end

-- #427 D15: any new press cancels a hold's blend still waiting. Every keypad
-- route ends in dev.button_action (common/device.lua), so the press is
-- caught here, before the machine judges it.
local machine_action = dev.button_action
function dev.button_action(button, action)
	if action == device.ACT_PRESS then
		cancel_hold_color()
	end
	return machine_action(button, action)
end

-- Load groups (#435, docs/load-groups-design.md) ------------------------------
-- A Control4 Load Group sends each member JOIN_GROUP, LEAVE_GROUP,
-- SET_GROUP_SYNC and the GROUP_* commands through the member's light_v2
-- proxy [verified: LV2 cmds _14 to _20; that the Load Group sends each
-- group command to every member is assumed, A2]. light.load_group keeps the
-- memberships (D6) and turns each group command into the path of its
-- ordinary counterpart (D3, §6.2): set_brightness with the group's tag for
-- GROUP_SET_LEVEL and GROUP_RAMP_TO_LEVEL, which then follow the turn-on
-- design's brightness-target rules (D4: no On Mode, the default rate where
-- no TIME is given), and start_ramp and finish for the group hold. What it
-- does to the light, the bridge and Composer goes through these callbacks.
-- A command the light cannot act on is dropped by ready() with its reason
-- in Status, as any command (L56); its GROUP ID is learnt all the same.

groups = load_group.new({
	-- One value: Director's PersistGetValue returns none for a key never
	-- written (#298). The list is a table (§6.4) [verified: API 26.5/_4].
	persist_get = function(key) return (C4:PersistGetValue(key)) end,
	persist_set = function(key, value) C4:PersistSetValue(key, value) end,
	display_name = function(id) return C4:GetDeviceDisplayName(id) end, -- [verified: API 32/_6]
	log = log,
	set_timer = function(ms, fn) return C4:SetTimer(ms, fn) end,
	-- §6.3: the list, with what the bridge keys it by; nothing while unbound
	-- (the next hello carries it).
	send_groups = function(wire)
		if bridge then
			send("HUE_LOAD_GROUPS", { device_id = device_id(), rid = st.rid,
				kind = state.is_group(st) and state.KIND_GROUP or nil, groups = wire })
		end
	end,
	show = function(text) prop("Load Groups", text) end,
	ready = ready,
	is_on = function() return dev.is_on() end,
	level = shown,
	set_brightness = function(level, rate, group) return set_brightness(level, rate, { group = group }) end,
	default_rate = default_rate,
	hold_rate = function(up) return setting(up and "hold_up" or "hold_down") end,
	ramp = function() return ramp end,
	stop_ramp = stop_ramp,
	-- CHANGED with the cache, closing the group's CHANGING (a hold whose
	-- GROUP_STOP_RAMP never came, E10; a stop with nothing of its group's
	-- running, D12), as SET_BRIGHTNESS_STOP with nothing running does. A
	-- target still waiting for the bridge (the light's own stop of the group
	-- hold, a target that replaced it) closes its own CHANGING with the
	-- bridge's word instead: the cache still shows the level before it.
	report = function()
		if not fallback.brightness then
			report_brightness()
		end
	end,
	-- The group hold's dim, as dev.on_hold starts a keypad's: a blend still
	-- waiting goes first (#427 D15); the record's own flag is its liveness.
	start_dim = function(rec, up, from, rate)
		cancel_hold_color()
		start_ramp(rec, up, from, function(r) return r.active == true end, rate)
	end,
	finish_dim = finish,
})

-- §6.2: every command name (the alias SET_GROUP_LEVEL too). Like the
-- bridge's messages they wait for late init, where the memberships are
-- loaded and UpdateProperty is safe (after_late_init).
for command in pairs(load_group.COMMANDS) do
	local handle = after_late_init(command, function(params)
		groups:handle(command, params)
	end)
	dispatch.proxy[command] = function(_, params)
		handle(params)
	end
end

-- Presets at start (#427 D19) ---------------------------------------------

-- One answer read (`read` returns the text) and handed to light.turnon's
-- parser; how many colour presets it gave, 0 when it failed or gave none.
-- The raw text is logged once at debug, cut at SETUP_LOG_MAX characters.
local function setup_from(source, read)
	local ok, text = pcall(read)
	if not ok then
		log.warn("%s failed: %s; presets not read from it", source, tostring(text))
		return 0
	end
	if type(text) ~= "string" or text == "" then
		log.debug("%s gave nothing", source)
		return 0
	end
	log.debug("%s: %s", source, text:sub(1, SETUP_LOG_MAX))
	local colors, presets = turnon.take_setup(modes, text)
	log.debug("%s: %d colour and %d brightness presets", source, colors, presets)
	return colors
end

-- SETUP_READ_MS after late init (a timer keeps the calls out of late init,
-- and GetDeviceVariable must not run in OnDriverInit [verified: API
-- 36_variable/_5-GetDeviceVariable.md]): the proxy's own answer to GET_SETUP
-- through C4:SendUIRequest [verified: API 22_miscellaneous/_36-SendUIRequest.md;
-- that the light_v2 proxy answers GET_SETUP to a driver this way is
-- assumed, F19], else its variable 1300 "Color Presets" [verified: LV2 vars
-- _0-HEADER.md; its format assumed, F20]. Both calls are protected, and what
-- they give only fills gaps and maps: it never moves a light (D26). The
-- persisted copies cover a proxy that answers neither.
local function read_setup()
	mem.setup_timer = nil
	local id = proxy_id()
	if not id then
		return log.debug("no light_v2 proxy bound; presets not read")
	end
	if setup_from("GET_SETUP", function() return C4:SendUIRequest(id, "GET_SETUP", {}) end) == 0 then
		setup_from("variable 1300", function() return C4:GetDeviceVariable(id, 1300) end)
	end
end

local function cancel_setup_read()
	if mem.setup_timer then
		mem.setup_timer:Cancel()
		mem.setup_timer = nil
	end
end

-- Lifecycle ----------------------------------------------------------------

dispatch.install(_G)

-- #492 (I-5, I-6): a release build locks Composer's Lua command window and
-- refuses a dev loop left behind by an earlier dev build (common/device.lua).
function OnDriverInit()
	dev.init()
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
	load_saved() -- before dev.late_init() runs a Restore that arrived early
	dev.load_settings()
	dev.load_colors()
	turnon.load(modes) -- the On Modes and presets persisted before (#429, #427 §7.6)
	groups:load() -- the load groups persisted before (#435 D6); the hello below announces them
	cancel_setup_read() -- a late init run again (a dev reload) starts one read
	mem.setup_timer = C4:SetTimer(SETUP_READ_MS, read_setup)
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
		dev.link = nil -- the next bridge's hello answer says its own (#428 D4)
		settle("brightness")
		settle("color")
		levels:close() -- #433 §6.5: the window's level came from the bridge just unbound
		cancel_hold_color()
		groups:end_hold("unbound from the bridge") -- #435: nothing left to stop it through
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
	levels:close() -- #433 §6.5: the window's timer
	cancel_hold_color()
	groups:end_hold("driver destroyed") -- #435: its tick and end-of-range timers
	cancel_setup_read()
	dev.cancel_timers() -- a keypad press and the click guard, the binding re-check, the Driver Version looks
end
