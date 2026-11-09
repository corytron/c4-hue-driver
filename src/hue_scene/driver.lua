-- Hue Scene driver: one light_v2 dimmer per Hue scene. ON recalls the scene,
-- OFF turns the scene's group off, the level shown is the group's brightness
-- as Hue reports it, and the slider moves the group relative to it, so the
-- scene's per-light differences stay (docs/scene-dimmer-design.md). A device
-- can also stand for a time-based ("smart") scene, a kind its configuration
-- names: it is on exactly while Hue says the schedule runs, ON starts it and
-- OFF stops it (docs/smart-scenes-design.md). It never speaks to the bridge
-- itself: commands go to the Hue Bridge driver it is bound to (consumer
-- binding 1, class HUE_BRIDGE) with C4:SendToDevice, and the bridge pushes
-- configuration and state back through ExecuteCommand. Keypad taps fade an
-- ordinary scene in or its group out over the click rate, and a press while
-- it fades stops it where it is (#421, docs/tap-stop-design.md §10.1). The
-- message contract is docs/scenes-design.md §2, this device §3, extended by
-- docs/keypad-design.md, docs/scene-dimmer-design.md and
-- docs/smart-scenes-design.md; the structure is the Hue Light driver's
-- (src/hue_light/driver.lua) with everything colour specific left out.

local log = require("common.log")
local dispatch = require("common.dispatch")
local device = require("common.device")

-- Binding IDs, see driver.xml; common/device.lua holds the proxy's (5001).
local BRIDGE_BINDING = device.BRIDGE_BINDING

-- How long a recall or off waits for the bridge's HUE_SCENE_STATE before the
-- requested state is assumed, so the UI never sticks in "changing". The
-- bridge normally answers within a few hundred ms (its own STATE right after
-- the PUT succeeded, then the stream's scene item).
local FALLBACK_MS = 2000

-- A level move (the slider while on) waits for the bridge's level report this
-- much beyond its ramp, and a hold's release this long, before the target (or
-- the cached level) is reported: the light's "rate + 1 s" fallback pattern.
local LEVEL_FALLBACK_MS = 1000

-- Level reports reach the proxy at most once per this many ms, the latest
-- value when the window ends, so a ramp does not flood Navigators.
local LEVEL_REPORT_MS = 1000

-- A time-based scene started from off with a level or a hold to follow waits
-- this long at most for the bridge to report its group on with a level
-- before that follows anyway (docs/smart-scenes-design.md, Decision 4).
local FOLLOW_MS = 1500

-- Prefix of every line this driver logs.
local LOG_PREFIX = "Hue Scene"

-- Recall As property value -> the recall action the bridge sends to Hue.
local RECALL_ACTIONS = {
	["As set in Hue"] = "active",
	["Static"] = "static",
	["Dynamic"] = "dynamic_palette",
}
local DEFAULT_RECALL = "active"

-- On State Follows property values (docs/scene-led-design.md): the room or
-- zone's lights (the default) or this scene alone (the on rule).
local FOLLOW_LIGHTS, FOLLOW_SCENE = "Room/zone lights", "This scene"

-- The device's kinds (docs/smart-scenes-design.md, Decision 1): an ordinary
-- Hue scene, or a time-based one (CLIP v2 smart_scene). The configure names
-- the kind; a device never told one is an ordinary scene.
local KIND_SCENE, KIND_SMART = "scene", "smart_scene"
local KINDS = { [KIND_SCENE] = true, [KIND_SMART] = true }

-- Hue's status values; anything else in a HUE_SCENE_STATE is ignored. A scene
-- is inactive, static or dynamic_palette; a time-based scene active or inactive.
local ACTIVE_VALUES = { inactive = true, static = true, dynamic_palette = true, active = true }

-- The scene's own copy of its identity (PersistSetValue key per state field),
-- so a bridge that lost its registry can rebuild it from the devices instead
-- of importing them a second time (docs/import-design.md §1, rule 3); the
-- kind is part of it (docs/smart-scenes-design.md, Decision 1). The Recall As
-- choice is persisted separately under "recall_as" by its handler.
local PERSISTED = { rid = "hue_rid", name = "hue_name", kind = "hue_kind" }

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
	kind = nil,           -- KIND_SCENE / KIND_SMART; nil until told (an ordinary scene)
	slot_name = nil,      -- time-based: the scene its current time slot plays; nil while unknown
	slot_start = nil,     -- time-based: when that slot starts ("07:00", "sunset"); nil while unknown
	active = nil,         -- "inactive" / "static" / "dynamic_palette" / "active"; nil until reported
	level = nil,          -- the group's brightness (0-100, decimals) last reported lit; nil until then
}
local recall_action = DEFAULT_RECALL
-- The on rule (docs/scene-dimmer-design.md, Behaviour): set whenever the scene
-- becomes active by any route (a static / dynamic_palette report from the
-- bridge, whoever recalled it, or a keypad hold from here); cleared only by
-- its group going off, another scene of the group becoming active, or this
-- device turning it off. Hue calling the scene inactive afterwards (something
-- dimmed or changed its lights) leaves the tile and the keypad LEDs on.
-- Persisted under "held_on", so it survives a restart. Ordinary scenes only:
-- a time-based scene is on exactly while Hue says it runs (held() below).
local held_on = false
-- The lights mode (docs/scene-led-design.md): the device also reads on while
-- its room or zone is on, whatever turned it on. group_on is the group's
-- on/off from HUE_SCENE_GROUP (nil until the bridge sends it; not persisted,
-- the hello's answer carries it again); follow_lights is the On State Follows
-- property.
local group_on = nil
local follow_lights = true
local level_seq = 0       -- counts lit level reports, to tell whether one arrived since a recall
local last_reported = nil  -- the LIGHT_BRIGHTNESS_CURRENT last sent to the proxy
local level_window = nil   -- { timer, dirty } for LEVEL_REPORT_MS after a level report went out
local bridge = nil           -- device id of the bound Hue Bridge driver, or nil
local pending = nil          -- { timer, assume, on } while a recall/off awaits its STATE
local follow = nil           -- what follows a time-based scene's start from off (arm_follow)
-- The brightness ramp an ordinary scene is running (#421 S-D4, D6), nil
-- while none is: { from, to, time, started, tap, recall, lo, hi, timer,
-- held }. "Ramps" below says when one begins and ends.
local ramp = nil

-- The plumbing both device drivers share (common/device.lua): properties and
-- proxy notifies, the bridge and proxy lookups, Driver Version, the buffer
-- for bridge messages that arrive before late init, the keypad (LEDs, Button
-- Links, settings, the press machine), the binding re-check, the goodbye, and
-- in dev builds the dev loop's log forwarding and DEV_RELOAD
-- (docs/scenes-design.md §6). Its hooks (is_on, on_bridge_found, on_click,
-- on_hold, on_finish, on_end_hold, and for #421 ramp_active and
-- on_ramp_stop) are set below.
local dev = device.new({
	prefix = LOG_PREFIX,
	tree = "scene", -- the dev loop's name for this driver's source tree
	bridge = function() return bridge end,
	rid = function() return st.rid end,
	noun = "scene",
	settings = { "hold_up", "hold_down" }, -- driver.xml declares hold_rates
})
local prop, notify, device_id, result = dev.prop, dev.notify, dev.device_id, dev.result
local bound_bridge, proxy_id, after_late_init = dev.bound_bridge, dev.proxy_id, dev.after_late_init
local update_leds, LINK_BUTTON, send = dev.update_leds, device.LINK_BUTTON, dev.send

-- Parsing ------------------------------------------------------------------

-- A string param or nil when absent or empty, and a boolean from "true"/"1"
-- and "false"/"0" (common/device.lua).
local text, to_bool = device.text, device.to_bool

-- Identity and status texts ------------------------------------------------

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

-- The device has no actions since 1.2 (#334, D3): every remedy is an action
-- of the Hue Bridge device, and the texts name it.
local FORGOTTEN_INSTRUCTION = "Delete this device, or bind it again and use Link Device on the Hue Bridge"
local GONE_REMEDY = "Link or Forget Device"
local UNLINKED_REMEDY = "use Link Device on the Hue Bridge"

local function forgotten_status()
	return string.format("Forgotten by the bridge (was Hue scene %s). %s", st.forgotten.name or st.rid or "unknown",
		FORGOTTEN_INSTRUCTION)
end

local function gone_status()
	local since = st.gone_since and (" since " .. os.date("%Y-%m-%d %H:%M", st.gone_since)) or ""
	return "Scene deleted in Hue" .. since .. "; ON does nothing; " .. GONE_REMEDY
end

-- Why a command cannot reach the scene right now, or nil when it can. The
-- order is the order Status explains things in: a forgotten scene is told
-- what to do even while its binding is already gone.
local function blocker()
	if st.forgotten then
		return "forgotten by the bridge; " .. FORGOTTEN_INSTRUCTION:gsub("^D", "d")
	elseif not bridge then
		return "not bound to a Hue Bridge"
	elseif not st.rid then
		return "waiting for the bridge to assign a Hue scene (" .. UNLINKED_REMEDY .. ")"
	elseif st.gone then
		return "scene deleted in Hue; " .. GONE_REMEDY
	end
	return nil
end

-- What ONLINE_CHANGED carries: reachable through a bridge that knows us.
local function is_online()
	return blocker() == nil
end

local function is_smart()
	return st.kind == KIND_SMART
end

-- Hue's status says the scene plays: an ordinary scene's static or
-- dynamic_palette, a time-based scene's active.
local function is_on()
	return st.active == "static" or st.active == "dynamic_palette" or st.active == "active"
end

-- A time-based scene's name without the number the Hue app gives repeats
-- ("Golden hours 4" -> "Golden hours"): the rule the bridge names its devices
-- by (docs/smart-scenes-design.md, Decision 7), one trailing " <digits>".
local function base_name(name)
	local base = name and name:match("^(.-) %d+$")
	if base and base ~= "" then
		return base
	end
	return name
end

-- A configured time-based scene's Status (docs/smart-scenes-design.md,
-- Decision 13): what it is and where, then the slot it plays while it runs.
local function smart_status()
	local head = string.format("Hue time-based scene %s in %s", base_name(st.name),
		group_label() or "(no room)")
	if st.active == nil then
		return head
	elseif not is_on() then
		return head .. "; not running"
	elseif not st.slot_name then
		return head .. "; running"
	end
	local from = st.slot_start and (" (from " .. st.slot_start .. ")") or ""
	return string.format("%s; now %s%s", head, st.slot_name, from)
end

local function refresh_status()
	if st.forgotten then
		prop("Status", forgotten_status())
	elseif not bridge then
		prop("Status", "Not bound to a Hue Bridge")
	elseif st.gone then
		prop("Status", gone_status())
	elseif st.configured and st.name and is_smart() then
		prop("Status", smart_status())
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

-- The on rule's flag counts for ordinary scenes only: a time-based scene is
-- on exactly while Hue says it runs (Hue keeps it running through whole-room
-- dims and stops it, with an event, when anything else takes its lights;
-- docs/smart-scenes-design.md, Decision 2).
local function held()
	return held_on and not is_smart()
end

-- What the tile and the LEDs show: the scene is active, or held on since it
-- was (held_on above).
local function effective_on()
	return is_on() or held()
end

-- The device's one on state: the tile, the LEDs, TOGGLE, the slider's choice
-- and the holds follow it. In the lights mode the scene's own state or its
-- group being on; the union keeps the tile from blinking off between a
-- recall's status and its group report (docs/scene-led-design.md).
local function shown_on()
	return effective_on() or (follow_lights and group_on == true)
end

-- Whether the lights mode knows the group's on/off.
local function group_known()
	return follow_lights and group_on ~= nil
end

local function set_held(on)
	if held_on == on then
		return
	end
	held_on = on
	log.debug("held on: %s", tostring(on))
	C4:PersistSetValue("held_on", on) -- a boolean persists [verified: API 26.5/_4]
end

local function load_held()
	held_on = to_bool(C4:PersistGetValue("held_on")) == true
end

-- A status from the bridge: an active one holds an ordinary scene on. (A
-- fallback's assumption sets st.active directly: it is not a report, so it
-- does not.)
local function take_status(active)
	st.active = active
	if is_on() and not is_smart() then
		set_held(true)
	end
end

-- A whole percent, 1-100: the proxy mishandles decimals (docs/design.md,
-- "Navigator slider") and a lit scene never reads 0.
local function whole_percent(v)
	return math.max(1, math.min(100, math.floor(v + 0.5)))
end

-- LIGHT_BRIGHTNESS_CURRENT: the group's level while the scene is on (100
-- while none is known yet), 0 while off, nil until the bridge has reported
-- (or a hold turned it on, or held_on came back from a restart).
local function brightness()
	if st.active == nil and not held() and not group_known() then
		return nil
	end
	if not shown_on() then
		return 0
	end
	return st.level and whole_percent(st.level) or 100
end

-- Keypad LEDs ----------------------------------------------------------------
-- MATCH_LED_STATE on each Button Link and BUTTON_INFO per button follow the
-- scene (common/device.lua, docs/keypad-design.md "Keypad LEDs"): what they
-- follow here is shown_on(), nil while neither a status, a held-on state nor
-- (in the lights mode) the group's on/off is known yet. While a ramp runs
-- whose start or end is lit, the scene is on throughout, whatever the cache
-- says before its held reports come out (#421 D10): a tap from off lights
-- the LEDs as it starts, and an off keeps them on until its ramp ends.
function dev.is_on()
	if ramp and (ramp.from > 0 or ramp.to > 0) then
		return true
	end
	if brightness() == nil then
		return nil
	end
	return shown_on()
end

-- The report_* functions return true when they had something to report.
local function report_brightness()
	local level = brightness()
	if not level then
		return false
	end
	last_reported = level
	notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = level })
	update_leds()
	return true
end

-- A command that never reached the bridge (common/device.lua logged why):
-- the proxy heard CHANGING and hears CHANGED with the level the tile shows,
-- which nothing changed, or `current`, the level that CHANGING came from,
-- while the bridge has reported none.
local function report_unchanged(current)
	if not report_brightness() then
		last_reported = current
		notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = current })
	end
end

-- Report only when what the tile shows moved from `before`.
local function report_if_changed(before)
	if brightness() ~= before then
		report_brightness()
	end
end

-- Level reports are throttled: one goes to the proxy at once when none went
-- out in the last LEVEL_REPORT_MS; within that window a report only marks
-- the window, and when it ends the tile's value then goes out (if it differs
-- from the last one sent) and a new window begins.
local function close_level_window()
	if level_window then
		level_window.timer:Cancel()
		level_window = nil
	end
end

local function open_level_window()
	close_level_window()
	local w = { dirty = false }
	w.timer = C4:SetTimer(LEVEL_REPORT_MS, function()
		if level_window ~= w then
			return
		end
		level_window = nil
		if w.dirty and brightness() ~= last_reported then
			report_brightness()
			open_level_window()
		end
	end)
	level_window = w
end

local function report_level()
	if level_window then
		level_window.dirty = true
	elseif brightness() ~= last_reported then
		report_brightness()
		open_level_window()
	end
end

local function report_online()
	notify("ONLINE_CHANGED", { STATE = is_online() })
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

-- A command sent to the bridge stays pending until the report it waits for
-- arrives (kind "switch", a recall or off: a HUE_SCENE_STATE; kind "level",
-- a level move or a hold's release: a level in HUE_SCENE_GROUP), its fallback
-- fires, or the proxy says stop; either way the proxy gets a CHANGED after
-- its CHANGING. One at a time: a new command replaces the previous one.
local function settle()
	if pending then
		pending.timer:Cancel()
		pending = nil
	end
end

-- `p.assume` applies the sent target to the cache and reports it; it runs
-- when the bridge has not confirmed within `delay` ms. `p.on` is where the
-- scene is heading (TOGGLE reads it).
local function arm(p, delay)
	settle()
	p.timer = C4:SetTimer(delay, function() -- [verified: API 34/_1]
		if pending ~= p then
			return -- settled already: only a timer firing despite its Cancel gets here
		end
		pending = nil
		p.assume()
	end)
	pending = p
end

-- A recall at a brightness (the slider from off) that ended on: Hue set every
-- light of the scene to it, so it is the group's level until the bridge
-- reports one, unless a report already arrived since the recall was sent.
local function take_recalled_level(p)
	if p.level and effective_on() and level_seq == p.seq then
		st.level = p.level
	end
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
		set_held(false)
		report_brightness()
	else
		log.info("%s dropped: %s", command, why)
	end
	return false
end

-- What every HUE_SCENE_RECALL carries: the rid, the Recall As action and,
-- with a ramp, its duration in ms.
local function recall_params(rate)
	local params = { rid = st.rid, action = recall_action }
	if rate > 0 then
		params.duration = string.format("%d", rate)
	end
	return params
end

-- Ramps (#421) --------------------------------------------------------------
-- A brightness change of an ordinary scene with a time above 0 whose send
-- succeeded is a ramp (#421 S-D4, D6): a keypad tap's recall or off (S-D1,
-- S-D2), and a timed target from programming, Navigator or a lighting scene
-- (a recall, an off or a level move with a rate). Levels are the tile's
-- percent: `to` is 0 for an off and 100 for a recall as designed (the
-- target its CHANGING names); lo..hi are the levels the ramp explains, none
-- for a recall as designed (only Hue knows the scene's own level, and any
-- lit level is its look). `time` and `started` are controller ms.
--
-- While it runs the bridge's reports are judged (#421 D10). One the ramp
-- explains (the recall's own status and group on, the off's inactive and
-- group off, a level within lo..hi, any status during a level move) is held
-- back in `held`, out of the cache and away from the proxy: Hue reports a
-- timed target as soon as the fade starts [verified: house, #421 §10 L1].
-- One it cannot explain (the group off or another scene active while it
-- ramps up, a recall failing, the scene or its group on while it ramps to
-- off, a level outside lo..hi) goes through with what was held under it and
-- ends the ramp. At the ramp's end what was held goes into the cache and out
-- as its one CHANGED, settling the target; with nothing held, the next
-- report or the fallback (the ramp plus FALLBACK_MS) closes it. A stop drops
-- what was held (stop_ramp); any other brightness command (D11) or a hold
-- ends the ramp with what was held taken into the cache, and reports for
-- itself.
--
-- The on state during an off ramp: the scene shows on until the ramp ends.
-- turn_off defers the end of the held state (the on rule) to the ramp's end,
-- the bridge's inactive and group off are held back meanwhile, and
-- dev.is_on() is true while a ramp runs from or to a lit level, so the LEDs
-- stay on too. A stop therefore leaves the scene as it was before the off,
-- lit at the estimate.
--
-- Time-based scenes never ramp (S-D5): Hue's activate and deactivate have no
-- duration, so their taps and targets act at once as before.

-- The controller's clock in ms [verified: API 34_timer/_2-GetTime, OS 3.2.3
-- on], or os.time() where it is missing, as the Hue Light driver reads it.
local function now_ms()
	local ok, t = pcall(function() return C4:GetTime() end)
	return ok and type(t) == "number" and t or os.time() * 1000
end

-- Where a ramp has the scene now, by the clock: from + (to - from) x elapsed
-- / time, rounded (#421 §4.2); and the ms elapsed, 0 to its time.
local function ramp_estimate(r)
	local elapsed = math.max(0, math.min(r.time, now_ms() - r.started))
	return math.floor(r.from + (r.to - r.from) * elapsed / r.time + 0.5), elapsed
end

-- Where the tile is: a running ramp's estimate, else the level shown, else
-- `default` (a CHANGING's current).
local function tile_level(default)
	if ramp then
		return (ramp_estimate(ramp))
	end
	return brightness() or default
end

-- What a ramp held back goes into the cache as HUE_SCENE_GROUP and
-- HUE_SCENE_STATE would have put it there, without a report: the group's
-- level, its on/off (off ends the held state) and the scene's status, an on
-- one first (`seen_on`), which holds the scene on under a later inactive as
-- the on rule does.
local function apply_held(h)
	if not h then
		return
	end
	if h.level then
		st.level = h.level
		level_seq = level_seq + 1
	end
	if h.on ~= nil then
		group_on = h.on
		if not h.on then
			set_held(false)
		end
	end
	if h.seen_on then
		take_status(h.seen_on)
	end
	if h.active then
		take_status(h.active)
	end
end

-- The ramp ends before its time: its timer stops, and `keep` takes what it
-- held back into the cache (D11, a report it cannot explain; a stop drops it).
local function end_ramp(keep)
	local r = ramp
	if not r then
		return
	end
	r.timer:Cancel()
	ramp = nil
	if keep then
		apply_held(r.held)
	end
end

-- #421 D10: the ramp's time ran out. An off ends the held state now (turn_off
-- deferred it). What the ramp held back goes into the cache and out as its
-- one CHANGED, and settles the target; with nothing held, the LEDs follow
-- the cache and the bridge's next report or the fallback closes it.
local function ramp_done(r)
	if ramp ~= r then
		return
	end
	ramp = nil
	if r.to == 0 then
		set_held(false)
	end
	local held_back = r.held
	if not held_back then
		return update_leds()
	end
	apply_held(held_back)
	local p = pending
	settle()
	if p and p.kind == "switch" then
		take_recalled_level(p)
	end
	report_unchanged(r.to)
	if held_back.level then
		open_level_window()
	end
end

-- After a successful send with a time above 0: the ramp's record and its end
-- on a timer; the LEDs light as a ramp from off starts (dev.is_on).
local function begin_ramp(r)
	r.started = now_ms()
	r.timer = C4:SetTimer(math.max(1, r.time), function() -- [verified: API 34/_1]
		ramp_done(r)
	end)
	ramp = r
	update_leds()
end

-- #421 D10 for a HUE_SCENE_STATE while a ramp runs: true when the ramp holds
-- it back. An on status while it ramps to off is someone's recall; an
-- inactive while a recall ramps up, on a scene neither held on nor reported
-- on since, is the recall failing (the bridge answers a failed PUT with the
-- status it had). Both go through and end the ramp, with what was held under
-- them. A level move holds back any status: Hue calls a dimmed scene
-- inactive, which the on rule ignores.
local function hold_status(active)
	local r = ramp
	if not r then
		return false
	end
	local lit = active ~= "inactive"
	local foreign
	if r.to == 0 then
		foreign = lit
	else
		foreign = not lit and r.recall and not held() and not (r.held and r.held.seen_on)
	end
	if foreign then
		log.debug("status %s is not the ramp to %d %%: it ends", active, r.to)
		end_ramp(true)
		return false
	end
	r.held = r.held or {}
	r.held.active = active
	if lit then
		r.held.seen_on = active
	end
	log.debug("status %s held back until the ramp to %d %% ends", active, r.to)
	return true
end

-- #421 D10 for a HUE_SCENE_GROUP while a ramp runs (`level` a lit level or
-- nil, `on` nil when the report does not say, `other` another scene of the
-- group became active): true when the ramp holds it back. Another scene, the
-- group off while it ramps up, on while it ramps to off, or a level outside
-- lo..hi go through and end the ramp, with what was held under them.
local function hold_group(level, on, other)
	local r = ramp
	if not r then
		return false
	end
	local outside = level and r.lo and (level < r.lo - 1 or level > r.hi + 1)
	if other or (on ~= nil and on == (r.to == 0)) or outside then
		log.debug("group on=%s level=%s%s is not the ramp to %d %%: it ends", tostring(on), tostring(level),
			other and ", another scene active" or "", r.to)
		end_ramp(true)
		return false
	end
	r.held = r.held or {}
	r.held.level = level or r.held.level
	if on ~= nil then
		r.held.on = on
	end
	log.debug("group on=%s level=%s held back until the ramp to %d %% ends", tostring(on), tostring(level), r.to)
	return true
end

-- HUE_SCENE_DIM to the bridge: up / down over `duration` ms (a hold), or
-- stop; a ramp's stop carries its estimate as `level`, which the bridge
-- writes only should Hue refuse the stop (#421 S-D3). True when it went out
-- (common/device.lua logs a failure).
local function send_dim(direction, duration, level)
	local params = { rid = st.rid, device_id = device_id(), direction = direction }
	if duration then
		params.duration = string.format("%d", duration)
	end
	if level then
		params.level = string.format("%d", level)
	end
	log.debug("dim %s%s%s", direction, duration and (" over " .. params.duration .. " ms") or "",
		level and (" at " .. params.level .. " %") or "")
	return send("HUE_SCENE_DIM", params)
end

-- #421 S-D3, D5, D7: stop the running ramp where the scene is by the clock;
-- false when none runs. The stop is the group's dimming_delta stop, which
-- halts a scene's fade with each lamp at its own level [verified: house,
-- #421 §10 S2, S4], never a level, which would bring every lamp to one level
-- and lose the scene's look. The estimate, at least 1 (a stop near off
-- leaves the scene lit, §3), goes with it for the bridge to write only
-- should Hue refuse the stop, into the cache, where a hold (S3) or the next
-- tap starts from it, and out as the ramp's CHANGED at once. What the ramp
-- held back is dropped: the bridge's report of the real level, about 10 s
-- after the fade's planned end (§10 L2), goes through and corrects the
-- estimate. A recall stopped partway leaves the scene held on (the on rule:
-- it was played from here); an off stopped partway leaves it as it was,
-- held on too should nothing else show it lit (its recall never confirmed):
-- the stop leaves its lamps lit. A stop that never reaches the bridge
-- (logged) still closes the proxy's ramp.
-- `why` names the stop in the log.
local function stop_ramp(why)
	local r = ramp
	if not r then
		return false
	end
	local level, elapsed = ramp_estimate(r)
	level = math.max(1, level)
	end_ramp(false)
	settle()
	log.debug("%s: the %sramp to %d %% stopped at %d %% after %d of %d ms", why, r.tap and "tap " or "", r.to, level,
		elapsed, r.time)
	send_dim("stop", nil, level)
	st.level = level
	if r.recall or not shown_on() then
		set_held(true)
	end
	report_unchanged(level)
	return true
end

-- Time-based scenes: what follows a start from off (docs/smart-scenes-design.md,
-- Decision 4). The slider's level below 100, or a held button's dim up, waits
-- until the bridge reports the scene's group on with a level (the slot's look
-- is on, so a relative move is measured from it), FOLLOW_MS at the latest;
-- then `go(f)` sends it and answers true when something went to the bridge.
-- follow = { kind = "level" | "dim", go, timer, level and rate (the slider)
-- or hold (the button) }; one at a time.
local function cancel_follow()
	if follow then
		if follow.timer then
			follow.timer:Cancel()
		end
		follow = nil
	end
end

local function fire_follow(why)
	local f = follow
	cancel_follow()
	if not f then
		return false
	end
	log.debug("time-based scene started (%s); its %s follows", why, f.kind)
	return f.go(f) == true
end

local function arm_follow(f)
	cancel_follow()
	f.timer = C4:SetTimer(FOLLOW_MS, function()
		if follow == f then
			f.timer = nil
			fire_follow(string.format("no group report within %d ms", FOLLOW_MS))
		end
	end)
	follow = f
end

-- True while a time-based scene's start from off still has something to
-- follow, or the level move that followed is out before any STATE confirmed
-- the start: what follows closes the proxy's transaction then.
local function starting()
	return follow ~= nil or (pending ~= nil and pending.starting == true)
end

-- HUE_SCENE_LEVEL to the bridge: the group moves to `level` relative to its
-- current level, and the move stays pending until the bridge's next level
-- report, or the target after the ramp plus LEVEL_FALLBACK_MS. `unconfirmed`:
-- the move follows a time-based scene's start that no STATE has confirmed
-- yet, so its fallback assumes the start too, as the start's own would have.
-- True when the move went to the bridge; otherwise the unchanged state is
-- reported (`current`: what the CHANGING before it came from).
local function send_level(level, rate, unconfirmed, current)
	log.info("level: %d %% over %d ms", level, rate)
	if not send("HUE_SCENE_LEVEL", {
		rid = st.rid,
		device_id = device_id(),
		level = string.format("%d", level),
		rate = string.format("%d", rate),
	}) then
		report_unchanged(current)
		return false
	end
	local delay = rate + LEVEL_FALLBACK_MS
	local p = { kind = "level", on = true, starting = unconfirmed == true }
	p.assume = function()
		log.debug("level %d %% unconfirmed after %d ms; assuming it", level, delay)
		if p.starting and not is_on() then
			st.active = "active"
			refresh_status()
		end
		st.level = level
		report_brightness()
	end
	arm(p, delay)
	return true
end

-- What follows a time-based scene's start: the CHANGING before it (the
-- start's, or the slider's while the start was on its way) came from off.
local function go_level(f)
	if blocker() then
		return false
	end
	return send_level(f.level, f.rate, not is_on(), 0)
end

-- The level the room moves to once a starting time-based scene's look is
-- on; a target before then replaces it (a second activate could land after
-- the move and undo it).
local function follow_with_level(level, rate)
	if follow and follow.kind == "level" then
		follow.level, follow.rate = level, rate
	else
		arm_follow({ kind = "level", level = level, rate = rate, go = go_level })
	end
end

-- A time-based scene starts with an activate: the bridge turns any recall of
-- a smart entry into {"recall":{"action":"activate"}} and ignores a ramp or a
-- brightness, so neither is sent, and the action is Hue's own choice
-- (Decision 3). Its STATE active settles it, or the fallback assumes it runs.
-- A level below 100 (the slider from off) follows as a move of the room,
-- which then closes the proxy's transaction (Decision 4). A start that never
-- reaches the bridge (logged) reports the unchanged state, and nothing
-- follows it (`current`: what turn_on's CHANGING came from).
local function start_smart(rate, level, current)
	if level then
		log.info("ON: starting the time-based scene, then the room to %d %%", level)
	else
		log.info("ON: starting the time-based scene")
	end
	if not send("HUE_SCENE_RECALL", { rid = st.rid, action = DEFAULT_RECALL }) then
		return report_unchanged(current)
	end
	arm({ kind = "switch", on = true, assume = function()
		log.debug("start unconfirmed after %d ms; assuming the time-based scene runs", FALLBACK_MS)
		st.active = "active"
		refresh_status()
		report_brightness()
	end }, FALLBACK_MS)
	if level then
		follow_with_level(level, rate)
	end
end

-- Recall the scene; with `level` (the slider from off) at that brightness.
-- The bridge's STATE settles it. The fallback's assumption is not a report:
-- it does not hold the scene on, so a later inactive report still corrects it.
-- A time-based scene starts instead (start_smart). A recall that never
-- reaches the bridge (logged) reports the unchanged state. With a rate the
-- recall fades the scene in over it [verified: house, #421 §10 S1] and is a
-- ramp (#421 S-D1, D6): its STATE then settles it at the ramp's end, and the
-- fallback waits the ramp out too. A ramp running is replaced (D11), the
-- CHANGING starting from its estimate. `urgent` (a keypad tap, S-D6, D12)
-- sends the recall past the bridge's request bucket.
local function turn_on(rate, level, urgent)
	rate = tonumber(rate) or 0
	-- 100 % from off is the scene as designed: a brightness override would
	-- set every light to 100 % and lose its look, and a Navigator's plain
	-- "on" may arrive as a target of 100.
	if level and level >= 100 then
		level = nil
	end
	if not ready("ON") then
		return
	end
	cancel_follow()
	local current = tile_level(0)
	end_ramp(true)
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = current,
		LIGHT_BRIGHTNESS_TARGET = level or 100,
		RATE = rate,
	})
	if is_smart() then
		return start_smart(rate, level, current)
	end
	local action = recall_action
	local params = recall_params(rate)
	if urgent then
		params.urgent = "true"
	end
	if level then
		params.brightness = string.format("%d", level)
		log.info("ON: recalling as %s at %d %%", action, level)
	else
		log.info("ON: recalling as %s", action)
	end
	if not send("HUE_SCENE_RECALL", params) then
		return report_unchanged(current)
	end
	local p = { kind = "switch", on = true, level = level, seq = level_seq }
	local delay = rate + FALLBACK_MS
	p.assume = function()
		log.debug("recall (%s) unconfirmed after %d ms; assuming the scene is on", action, delay)
		st.active = assumed_active(action)
		take_recalled_level(p)
		report_brightness()
	end
	arm(p, delay)
	if rate > 0 then
		begin_ramp({ from = current, to = level or 100, time = rate, tap = urgent, recall = true,
			lo = level and math.min(current, level), hi = level and math.max(current, level) })
	end
end

-- This device turning the scene off ends the held state at once. A
-- time-based scene stops: the bridge deactivates it, then turns the group
-- off (docs/smart-scenes-design.md, Decision 5). An off that never reaches
-- the bridge (logged) ends nothing and reports the unchanged state. An
-- ordinary scene's off with a rate fades the group out over it as its
-- `duration` [verified: house, #421 §10 S4; S-D6]; a time-based scene's stop
-- has none at Hue (S-D5). From a lit level that is a ramp (#421 S-D2, D6),
-- which ends the held state at its end rather than now (Ramps above), and
-- the fallback waits it out. A ramp running is replaced (D11). `urgent` (a
-- keypad tap, S-D6, D12) sends the off past the bridge's request bucket.
local function turn_off(rate, urgent)
	rate = tonumber(rate) or 0
	if not ready("OFF") then
		return
	end
	cancel_follow()
	local current = tile_level(100)
	end_ramp(true)
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = current,
		LIGHT_BRIGHTNESS_TARGET = 0,
		RATE = rate,
	})
	local params = { rid = st.rid }
	if rate > 0 and not is_smart() then
		params.duration = string.format("%d", rate)
	end
	if urgent then
		params.urgent = "true"
	end
	local timed = params.duration ~= nil and current > 0
	local was_held = held_on
	if not timed then
		set_held(false)
	end
	if not send("HUE_SCENE_OFF", params) then
		set_held(was_held)
		return report_unchanged(current)
	end
	local delay = (timed and rate or 0) + FALLBACK_MS
	arm({ kind = "switch", on = false, assume = function()
		log.debug("off unconfirmed after %d ms; assuming the scene is off", delay)
		st.active = "inactive"
		if is_smart() then
			refresh_status()
		end
		report_brightness()
	end }, delay)
	if timed then
		begin_ramp({ from = current, to = 0, time = rate, tap = urgent, lo = 0, hi = current })
	end
end

-- The slider while the scene is on: the bridge moves the group to `level`
-- relative to its current level, so the scene's per-light differences stay
-- (HUE_SCENE_LEVEL, docs/scene-dimmer-design.md). The proxy hears CHANGED
-- with the bridge's next level report, or the target after the ramp plus
-- LEVEL_FALLBACK_MS (send_level). An ordinary scene's move with a rate is a
-- ramp (#421 D6): the level reports it explains wait for its end (D10). A
-- ramp running is replaced (D11).
local function move_level(level, rate)
	if not ready("brightness target") then
		return
	end
	cancel_follow()
	local current = tile_level(100)
	end_ramp(true)
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = current,
		LIGHT_BRIGHTNESS_TARGET = level,
		RATE = rate,
	})
	if send_level(level, rate, false, current) and rate > 0 and not is_smart() then
		begin_ramp({ from = current, to = level, time = rate, lo = math.min(current, level),
			hi = math.max(current, level) })
	end
end

-- SET_BRIGHTNESS_TARGET (and SET_LEVEL / RAMP_TO_LEVEL): 0 turns the scene off
-- over the rate; above 0 recalls it at that brightness over the rate while it
-- is off, or while a recall or off is still on its way (the group's level is
-- in flux then, so only an absolute target is safe), and moves the group's
-- level otherwise. A time-based scene on its way up (its start is out, or
-- something still follows it) takes the target as the level that follows.
local function set_target(target, rate)
	target = tonumber(target)
	if not target then
		return log.warn("brightness command without a target")
	end
	rate = math.max(0, math.floor((tonumber(rate) or 0) + 0.5))
	if target <= 0 then
		return turn_off(rate)
	end
	local level = whole_percent(target)
	if is_smart() and (follow or (pending and pending.kind == "switch" and pending.on)) then
		if not ready("brightness target") then
			return
		end
		notify("LIGHT_BRIGHTNESS_CHANGING", {
			LIGHT_BRIGHTNESS_CURRENT = brightness() or 0,
			LIGHT_BRIGHTNESS_TARGET = level,
			RATE = rate,
		})
		log.info("level: %d %% once the time-based scene has started", level)
		return follow_with_level(level, rate)
	end
	if (pending and pending.kind == "switch") or not shown_on() then
		return turn_on(rate, level)
	end
	move_level(level, rate)
end

-- SET_BRIGHTNESS_STOP with no ramp running: the proxy wants the transition
-- closed now. The cached
-- state goes out as CHANGED (the bridge's next real report corrects it if
-- need be). With nothing cached yet the target is assumed, as the fallback
-- would have, so the proxy never waits on a CHANGING. What was to follow a
-- time-based scene's start is dropped: the scene plays as its slot has it.
local function stop()
	local p = pending
	settle()
	cancel_follow()
	if not report_brightness() and p then
		p.assume()
	end
end

-- Bridge binding -----------------------------------------------------------

-- What HUE_SCENE_HELLO carries: the persisted identity, so the bridge can
-- adopt a bound scene device its registry lacks, as the right kind
-- (docs/smart-scenes-design.md, Decision 1). Absent keys for what is
-- unknown: a rid-less device sends no rid, one never told its kind no kind
-- (SendToDevice drops empty values).
local function hello_params()
	return { rid = st.rid, device_id = device_id(), name = st.name, kind = st.kind }
end

-- Announce ourselves; the bridge answers with HUE_SCENE_CONFIGURE and the
-- scene's status when it knows the rid. `hint` is the device id
-- OnBindingChanged named, for when Director's lookup does not reflect the
-- new binding yet.
local function hello(hint)
	bridge = bound_bridge() or tonumber(hint)
	if bridge then
		C4:SendToDevice(bridge, "HUE_SCENE_HELLO", hello_params())
		dev.flush_log() -- dev builds: lines logged while the bridge was unknown
	end
	refresh_status()
end

local function load_identity()
	for field, key in pairs(PERSISTED) do
		local value = C4:PersistGetValue(key)
		st[field] = (value ~= nil and value ~= "") and tostring(value) or nil
	end
	if st.kind and not KINDS[st.kind] then
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

-- What the device's on state follows (docs/scene-led-design.md): the room or
-- zone's lights as well as the scene (the default, also when Director has no
-- value yet after an update), or the scene alone. A change shows at once.
dispatch.properties["On_State_Follows"] = function(value)
	if value ~= FOLLOW_LIGHTS and value ~= FOLLOW_SCENE and value ~= nil and value ~= "" then
		log.warn("On State Follows %q is not a known choice; using %q", tostring(value), FOLLOW_LIGHTS)
	end
	local before = brightness()
	follow_lights = value ~= FOLLOW_SCENE
	log.debug("On State Follows %q", follow_lights and FOLLOW_LIGHTS or FOLLOW_SCENE)
	report_if_changed(before)
end

-- Recall As means nothing to a time-based scene (its start has no action to
-- choose), so Composer hides it there and shows it on ordinary scenes
-- (docs/smart-scenes-design.md, Decision 12) [verified: API 24_properties/_4,
-- SetPropertyAttribs(name, 1) hides and is not for OnDriverInit; 0 shows, as
-- in Snap One's drivers-common-public SetPropertyVisible]. Applied at late
-- init and whenever a configure changes the kind; nil until applied.
local recall_as_hidden = nil

local function apply_recall_as()
	local hide = is_smart()
	if recall_as_hidden == hide then
		return
	end
	recall_as_hidden = hide
	-- Every controller has it (OS 1.6.0); looked up first, as Snap One's
	-- libraries look up C4.GetTime, so a runtime without it (the test
	-- harness) only skips it, and protected, so it cannot stop late init.
	if not C4.SetPropertyAttribs then
		return log.debug("no C4:SetPropertyAttribs here; Recall As left as it is")
	end
	local ok, err = pcall(C4.SetPropertyAttribs, C4, "Recall As", hide and 1 or 0)
	if ok then
		log.debug("Recall As %s", hide and "hidden (time-based scene)" or "shown")
	else
		log.warn("could not %s Recall As: %s", hide and "hide" or "show", tostring(err))
	end
end

-- From the bridge (ExecuteCommand) -------------------------------------------
-- Director late-inits drivers in no particular order, so the bridge's
-- messages can reach a scene device before its own OnDriverLateInit, where
-- UpdateProperty and SendToProxy are not yet safe; after_late_init
-- (common/device.lua) holds them until then, in order.

-- The kind a configure names; none (a bridge from before time-based scenes)
-- is an ordinary scene. A change (Link Device across kinds) drops what
-- belonged to the old kind: a time-based scene never holds on, and nothing
-- follows a start of the other kind.
local function take_kind(params)
	local kind = text(params.kind)
	if kind and not KINDS[kind] then
		log.warn("HUE_SCENE_CONFIGURE with unknown kind %s; taken as an ordinary scene", kind)
		kind = nil
	end
	kind = kind or KIND_SCENE
	if kind == st.kind then
		return
	end
	if st.kind then
		log.info("now %s", kind == KIND_SMART and "a time-based scene" or "an ordinary scene")
	end
	st.kind = kind
	cancel_follow()
	end_ramp(false) -- a time-based scene never ramps (#421 S-D5)
	if is_smart() then
		set_held(false)
	end
end

-- The bridge builds every configure from its whole registry entry, so the
-- group, kind, time slot and lifecycle fields are taken as sent and reset
-- when absent. A configure also ends a forgotten state: the bridge knows the
-- scene again.
dispatch.commands["HUE_SCENE_CONFIGURE"] = after_late_init("HUE_SCENE_CONFIGURE", function(params)
	params = params or {}
	if text(params.rid) then
		if params.rid ~= st.rid then
			group_on = nil -- another scene's group: its first group message refills it
		end
		st.rid = params.rid
	end
	st.name = text(params.name) or st.name
	st.group_name = text(params.group_name)
	st.group_type = text(params.group_type)
	st.id_v1 = text(params.id_v1)
	local b = to_bool(params.auto_dynamic)
	if b ~= nil then st.auto_dynamic = b end
	take_kind(params)
	st.slot_name = text(params.slot_name)
	st.slot_start = text(params.slot_start)
	st.gone = params.state == "gone"
	st.gone_since = st.gone and tonumber(params.gone_since) or nil
	st.forgotten = nil
	st.configured = true
	save_identity()
	prop("Hue Scene ID", scene_id_label())
	prop("Hue Scene", st.name)
	prop("Hue Room", group_label())
	apply_recall_as()
	if st.gone then
		cancel_follow()
		end_ramp(false)
		log.debug("configured as deleted in Hue%s", st.gone_since and (" since " .. st.gone_since) or "")
	end
	report_brightness() -- the proxy hears the cached status again, if any
	report_online()
	refresh_status()
end)

-- A time-based scene's slot as a STATE names it; a STATE without one keeps
-- what is known (the configure's, or an earlier STATE's).
local function take_slot(params)
	local name, start = text(params.slot_name), text(params.slot_start)
	if name or start then
		st.slot_name, st.slot_start = name, start
	end
end

-- Every scene status the bridge learns. A report settles a pending recall or
-- off whatever the value: the proxy heard CHANGING and must hear CHANGED.
-- Otherwise only a change of what the tile shows reaches the proxy. An active
-- status holds an ordinary scene on; an inactive one never turns a held scene
-- off. A time-based scene follows its status alone, and its Status names the
-- slot it plays (docs/smart-scenes-design.md, Decisions 2 and 13). While its
-- start from off has something to follow (starting()), that closes the
-- proxy's transaction: active only confirms the start (the LEDs follow), and
-- inactive ends it with nothing to follow (the start failed or was undone).
-- While an ordinary scene's ramp runs, a status it explains waits for its
-- end, and one it cannot explain ends it first (#421 D10, hold_status).
dispatch.commands["HUE_SCENE_STATE"] = after_late_init("HUE_SCENE_STATE", function(params)
	params = params or {}
	if st.rid and params.rid and params.rid ~= st.rid then
		return log.warn("HUE_SCENE_STATE for rid %s ignored (ours is %s)", params.rid, st.rid)
	end
	if not ACTIVE_VALUES[params.active] then
		return log.warn("HUE_SCENE_STATE without a known status (%s) ignored", tostring(params.active))
	end
	if hold_status(params.active) then
		return
	end
	local before = brightness()
	take_status(params.active)
	if is_smart() then
		take_slot(params)
		refresh_status()
	end
	if is_smart() and starting() then
		if is_on() then
			if pending and pending.kind == "switch" then
				settle()
			elseif pending then
				pending.starting = false
			end
			update_leds()
			return
		end
		log.debug("the time-based scene is not running; nothing follows its start")
		cancel_follow()
		if pending and pending.starting then
			settle()
			report_brightness()
			return
		end
	end
	if pending and pending.kind == "switch" then
		local p = pending
		settle()
		take_recalled_level(p)
		report_brightness()
	else
		report_if_changed(before)
	end
end)

-- The scene's room/zone (docs/keypad-design.md and docs/scene-dimmer-design.md,
-- Messages): its grouped_light's level, its on/off, or another scene of the
-- group became active; every key optional. A level is cached and, while the
-- scene is on, reported (throttled); it also settles a pending level move or
-- hold release. The group going off or another scene becoming active ends
-- the held state; on="true" alone changes nothing (the scene's own status
-- says whether it is active). A level of 0 means none of the group's lights
-- is lit, which says nothing about the scene's level: the last lit one stays.
-- While an ordinary scene's ramp runs, what it explains waits for its end;
-- what it cannot explain ends it and closes the proxy's ramp with the state
-- the report leaves (#421 D10, hold_group).
dispatch.commands["HUE_SCENE_GROUP"] = after_late_init("HUE_SCENE_GROUP", function(params)
	params = params or {}
	if st.rid and params.rid and params.rid ~= st.rid then
		return log.warn("HUE_SCENE_GROUP for rid %s ignored (ours is %s)", params.rid, st.rid)
	end
	local level = tonumber(params.level)
	local lit = level and level > 0 and math.min(level, 100) or nil
	local on = to_bool(params.on)
	local other = to_bool(params.other_active) == true
	local foreign = false
	if ramp and (lit or on ~= nil or other) then
		if hold_group(lit, on, other) then
			return
		end
		foreign = true
	end
	local before = brightness()
	if lit then
		st.level = lit
		level_seq = level_seq + 1
	end
	if on ~= nil then
		group_on = on
	end
	-- A time-based scene started from here: the group on with a level means
	-- the slot's look is on, so what was to follow goes now; the group off
	-- means the start was undone (a dropped slider level closes the proxy's
	-- transaction with what is known). A slider's move closes the transaction
	-- itself, so the slot's level just cached is not reported on its own.
	if follow then
		local kind = follow.kind
		if on == false then
			log.debug("the group went off before the time-based scene's %s followed; dropped", kind)
			cancel_follow()
			if kind == "level" and not pending then
				report_brightness()
			end
		elseif (level and level > 0) or (on == true and st.level) then
			if fire_follow("the bridge reported the group on") and kind == "level" then
				return
			end
		end
	end
	-- other_active says nothing to a time-based scene: its own status does.
	local ended = on == false or (other and not is_smart())
	if ended then
		if held_on then
			log.debug("held-on state ended: %s", on == false and "the group went off" or "another scene is active")
		end
		set_held(false)
	end
	if foreign then
		settle()
		report_unchanged(before or 0)
		if lit then
			open_level_window()
		end
		return
	end
	if pending and pending.kind == "level" and (level or ended) then
		settle()
		report_brightness()
		if level then
			open_level_window()
		end
	elseif ended then
		report_if_changed(before)
	elseif on ~= nil and group_known() and (before or 0) == 0 and brightness() ~= before then
		-- The lights mode: the group came on, so the tile and LEDs go on at once.
		report_brightness()
	elseif level and level > 0 and shown_on() then
		report_level()
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
	cancel_follow()
	end_ramp(false)
	log.warn("forgotten by the bridge (was Hue scene %s)", st.forgotten.name or st.rid or "unknown")
	prop("Last Action", "Forgotten by the bridge")
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

-- Rename our proxy (the device Composer shows) to the Hue scene name. Only
-- ever from this command: names belong to the owner (docs/import-design.md §7).
dispatch.commands["Adopt_Hue_Name"] = alias("Adopt Hue Name", "Resolve Names", function()
	if not st.name then
		return result("Not renamed: no Hue name known yet (the bridge has not configured this scene)")
	end
	local id = proxy_id()
	if not id then
		return result("Not renamed: no light_v2 proxy is bound to binding 5001")
	end
	-- The name the bridge gives a scene device at creation (docs/scenes-design.md
	-- §1): the scene's own name in a room, the zone's name in front for a zone;
	-- a time-based scene's without the app's number (docs/smart-scenes-design.md,
	-- Decision 7).
	local name = is_smart() and base_name(st.name) or st.name
	if st.group_type == "zone" and st.group_name then
		name = st.group_name .. " " .. name
	end
	C4:RenameDevice(id, name) -- [verified: API 22/_32]
	result(string.format("Renamed device %d to %s", id, name))
end)

-- Ask the bridge to Forget this scene; it answers HUE_SCENE_FORGOTTEN, which
-- sets Status. The bridge finds the entry by rid or, for a rid-less device,
-- by device id.
dispatch.commands["Forget_This_Scene"] = alias("Forget This Scene", "Forget Device", function()
	if not bridge then
		return result("Not sent: not bound to a Hue Bridge")
	end
	C4:SendToDevice(bridge, "HUE_SCENE_FORGET", { rid = st.rid, device_id = device_id() })
	result("Asked the bridge to forget this scene; its answer sets Status")
end)

-- From the proxy (ReceivedFromProxy) ------------------------------------------
-- Commands without a handler are logged at debug by common.dispatch.

-- The proxy asks for current state after Director starts or a UI connects.
dispatch.proxy["SYNCHRONIZE"] = function()
	report_online()
	report_brightness()
end

-- With supports_target the proxy sends LIGHT_BRIGHTNESS_TARGET and RATE
-- [verified: proxy ref, SET_BRIGHTNESS_TARGET]; the Navigator slider is this
-- (set_target above).
dispatch.proxy["SET_BRIGHTNESS_TARGET"] = function(_, params)
	set_target(params.LIGHT_BRIGHTNESS_TARGET, params.RATE)
end

-- Advanced Lighting Scenes with reduced_als_support drive the scene with
-- SET_BRIGHTNESS_TARGET and end a scene ramp with these; both carry no
-- parameters [verified: proxy ref, SET_BRIGHTNESS_STOP, reduced_als_support,
-- supports_brightness_stop]. A ramp running (#421 D6: a tap's, or a timed
-- recall, off or level move's) stops at Hue exactly as a tap stops it (#421
-- D7, S-D3, stop_ramp), and the proxy hears the estimate. With none running
-- nothing goes to the bridge: the proxy only needs its CHANGED (stop; a
-- level move's end comes with the bridge's next level report).
dispatch.proxy["SET_BRIGHTNESS_STOP"] = function()
	if not stop_ramp("brightness stop") then
		stop()
	end
end

-- The ALS section lists STOP_SCENE_RAMP among what a reduced-ALS driver must
-- support; whether the proxy forwards it under that name is unverified, so it
-- is accepted as a brightness stop.
dispatch.proxy["STOP_SCENE_RAMP"] = dispatch.proxy["SET_BRIGHTNESS_STOP"]

-- Toggle relative to where the scene is heading: a pending recall counts as
-- on, so two quick presses end up off [verified: proxy ref, TOGGLE].
dispatch.proxy["TOGGLE"] = function()
	local on
	if pending then
		on = pending.on
	else
		on = shown_on()
	end
	if on then
		turn_off(0)
	else
		turn_on(0)
	end
end

dispatch.proxy["ON"] = function() turn_on(0) end
dispatch.proxy["OFF"] = function() turn_off(0) end

-- Keypad buttons -------------------------------------------------------------
-- What a tap and a hold do to a scene; the press / click / release machine
-- (with the double-tap window and the stop on the press, #421 D4, D5) and
-- the proxy's hold rates are common/device.lua's. A tap of the top button
-- fades the scene in, of the bottom button fades its group out, of the
-- toggle button does either by the on state, and a press while a fade runs
-- stops it there (#421 §10.1). A hold dims the scene's group relatively, so
-- its colours and per-light differences stay; holding top while off recalls
-- at 1 % first. A hold's record carries changing (the proxy heard the hold's
-- CHANGING) and dim_sent (a dim went out: the release stops it).
-- docs/keypad-design.md.
local BUTTON_TOP, BUTTON_BOTTOM = device.BUTTON_TOP, device.BUTTON_BOTTOM
local setting = dev.setting

-- A tap's ramp time: a click rate is the time of the whole range (#421 D3),
-- so a tap takes its share of the distance, rounded to whole ms. The
-- scene's driver.xml declares no click rates, so Composer shows none, the
-- proxy sends none and none is loaded (opts.settings above): setting()
-- always gives common/device.lua's defaults, 3000 ms each.
local function share(rate, distance)
	return math.floor(rate * distance / 100 + 0.5)
end

-- A tap (#421 §10.1). A ramp still running here began between the press and
-- its click (the machine stops one running at the press and swallows its
-- click): it is stopped instead. Top, or toggle while the scene shows off
-- or is heading off, fades the scene in over the click rate up's share of
-- the distance from the scene's own level to 100 (S-D1): the whole rate
-- from off or when only its room is lit by something else (On State
-- Follows "Room/zone lights"), the rest of it from a level the scene was
-- dimmed to. A scene Hue reports active at 100 is there already: nothing
-- goes to Hue and the proxy hears the level. Bottom, or toggle while it
-- shows on, fades the group out over the click rate down's share of the
-- level shown (S-D2): at once while it shows off (the group goes off as
-- before), over the whole rate while nothing is known. Both go past the
-- bridge's request bucket (S-D6, D12). A time-based scene keeps its taps,
-- at once (S-D5), and the double-tap window. A device that cannot be driven
-- drops the tap with its reason, as it drops a target.
function dev.on_click(button)
	if stop_ramp("tap") then
		return
	end
	if is_smart() then
		if button == BUTTON_TOP then
			turn_on(0)
		elseif button == BUTTON_BOTTOM then
			turn_off(0)
		else
			dispatch.proxy["TOGGLE"]()
		end
		return
	end
	if not ready("tap") then
		return
	end
	local up = button == BUTTON_TOP
	if button ~= BUTTON_TOP and button ~= BUTTON_BOTTOM then
		if pending then
			up = not pending.on
		else
			up = not shown_on()
		end
	end
	local level = brightness()
	if not up then
		return turn_off(share(setting("click_down"), level or 100), true)
	end
	if is_on() and level == 100 then
		log.debug("tap: the scene is on at 100 %% already")
		return report_brightness()
	end
	local own = effective_on() and level or 0
	turn_on(share(setting("click_up"), 100 - own), nil, true)
end

-- The machine's hooks for the stop (#421 S-D4, D5, common/device.lua): a
-- press outside the double-tap window while a ramp runs stops it on the
-- push, on any button; a press held on afterwards holds from the stopped
-- level. A time-based scene never ramps, so its presses get only the window.
function dev.ramp_active()
	return ramp ~= nil
end

function dev.on_ramp_stop()
	stop_ramp("tap")
end

-- A press that ends: a time-based scene this hold started has its dim
-- follow only while the button is held (docs/smart-scenes-design.md,
-- Decision 4).
function dev.on_end_hold(h)
	if follow and follow.hold == h then
		cancel_follow()
	end
end

-- The bound the bridge holds a scene's hold rate to (scenes.DIM_MAX_DURATION,
-- 100 minutes): a longer rate reaches Hue as this, so the tile's ramp is
-- worked out from it too (#243), as a Hue Light's is (#234).
local HOLD_MAX_MS = 6000000

-- The proxy hears a hold as a CHANGING toward the end of the range when it
-- starts (docs/scene-dimmer-design.md, Keypad holds); the bridge's level
-- reports settle it. It replaces whatever target was pending.
--
-- #243: a hold rate is the time of the whole range [verified: proxy
-- reference, HOLD_RATE_UP/DOWN], and Hue covers the whole range at that
-- speed from any level (docs/group-hold-design.md: each lit lamp ramps at
-- the hold rate, or the group's steps are sized so the range takes it), so
-- from mid-range it reaches the end in the share of the rate the distance
-- left takes. The tile hears that share, at Hue's speed, as a Hue Light's
-- does (#232); the dim to the bridge keeps the whole rate (send_dim). A hold
-- from off starts the tile at 0 and keeps the whole rate; one from the end
-- of the range has no distance left (RATE 0). The tile is an estimate: the
-- level is the lamps' average, so lamps below it reach the end later, and
-- the bridge's level reports correct the tile during and after the hold.
local function hold_changing(h, current, up, duration)
	local target = up and 100 or 1
	local full = math.min(duration, HOLD_MAX_MS)
	settle()
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = current,
		LIGHT_BRIGHTNESS_TARGET = target,
		RATE = math.floor(full * math.abs(target - current) / 100),
	})
	h.changing = true
end

-- A time-based scene that is off starts (its activate has no brightness to
-- start at 1 % with), and the dim up follows once the slot's look is on,
-- while the button is still down (docs/smart-scenes-design.md, Decision 4);
-- released before then, the scene just runs. The tile and the LEDs follow
-- its STATE. A start that never reaches the bridge (logged) closes the
-- hold's CHANGING with the unchanged state, and nothing follows it.
local function start_smart_hold(h, duration)
	hold_changing(h, 0, true, duration)
	log.info("hold: starting the time-based scene, then dimming up")
	if not send("HUE_SCENE_RECALL", { rid = st.rid, action = DEFAULT_RECALL }) then
		h.changing = false
		return report_unchanged(0)
	end
	arm_follow({ kind = "dim", hold = h, go = function()
		if not dev.holding(h) or not h.held or blocker() then
			return false
		end
		h.dim_sent = send_dim("up", duration)
		return h.dim_sent
	end })
end

-- A hold began (the machine chose the direction; down from off does
-- nothing). A hold from here makes an ordinary scene held on (a keypad
-- recall or dim, the on rule). A dim or recall that never reaches the bridge
-- (logged) leaves the scene as it was, not held by this hold, and closes the
-- hold's CHANGING with the unchanged state; the dim that follows a recall
-- that did go out is then just not sent (no stop at the release), and the
-- bridge's level reports close the hold as they do after any recall. A
-- press that stopped a ramp (#421 D5) holds from the level the stop left in
-- the cache (S3: a hold right after a stop rises from where the lamps
-- stopped). A ramp that began after the press (programming, say) ends here,
-- and the hold starts from its estimate.
function dev.on_hold(h, up, on)
	if not ready("hold") then
		return
	end
	cancel_follow()
	local estimate = ramp and (ramp_estimate(ramp))
	end_ramp(true)
	local duration = setting(up and "hold_up" or "hold_down")
	local was_held = held_on
	if not is_smart() then
		set_held(true)
	end
	local function failed(current)
		set_held(was_held)
		h.changing = false
		report_unchanged(current)
	end
	if on then
		local current = estimate and math.max(1, estimate) or brightness() or 100
		hold_changing(h, current, up, duration)
		if send_dim(up and "up" or "down", duration) then
			h.dim_sent = true
		else
			failed(current)
		end
		return
	end
	if is_smart() then
		return start_smart_hold(h, duration)
	end
	-- Off: recall at 1 %, then ramp up from there once Hue has applied it.
	-- The LEDs turn on once the recall is out; the tile follows the CHANGING.
	hold_changing(h, 0, true, duration)
	local params = recall_params(0)
	params.brightness = "1"
	log.info("hold: recalling as %s at 1 %%, then dimming up", recall_action)
	if not send("HUE_SCENE_RECALL", params) then
		return failed(0)
	end
	update_leds()
	dev.dim_after_on(h, function()
		h.dim_sent = send_dim("up", duration)
	end)
end

-- Release (or release-as-click) after a hold: stop a dim that was sent and
-- close the hold's CHANGING with the bridge's next level report (or the
-- cached level after LEVEL_FALLBACK_MS). The machine has armed the click
-- guard.
function dev.on_finish(h)
	if h.dim_sent and bridge and st.rid then
		send_dim("stop")
	end
	if h.changing then
		arm({ kind = "level", on = true, assume = function()
			log.debug("no level report %d ms after the hold; reporting the cached one", LEVEL_FALLBACK_MS)
			report_brightness()
		end }, LEVEL_FALLBACK_MS)
	end
end

-- Legacy commands that old programming may still send: the slider's path.
dispatch.proxy["SET_LEVEL"] = function(_, params) set_target(params.LEVEL, params.TIME) end
dispatch.proxy["RAMP_TO_LEVEL"] = function(_, params) set_target(params.LEVEL, params.TIME) end

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
	recall_as_hidden = nil -- Recall As is shown or hidden again at every late init
	load_identity()
	dev.load_settings()
	dev.load_colors()
	load_held()
	dispatch.replay_properties(Properties)
	dev.show_driver_version(1)
	prop("Hue Scene ID", scene_id_label())
	prop("Hue Scene", st.name)
	-- The bridge first, so messages it sent before this point are applied
	-- against the right binding state; then the hello carries whatever
	-- identity they delivered.
	bridge = bound_bridge()
	dev.late_init()
	apply_recall_as() -- for the persisted kind, unless a buffered configure just did
	hello()
	report_online()
	-- The LEDs, once, when buffered messages or a persisted held_on made the
	-- state known already (otherwise the first report sends them).
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
		settle()
		cancel_follow()
		end_ramp(false)
		refresh_status()
		report_online()
	end
end)

-- Composer is deleting this device: tell the bridge, so it tombstones the
-- entry instead of fanning state out to a dead id (common/device.lua).
-- OnDriverDestroyed follows and stops the timers.
function OnDriverRemovedFromProject()
	dev.goodbye("HUE_SCENE_GOODBYE")
end

function OnDriverDestroyed()
	settle()
	cancel_follow()
	end_ramp(false)
	dev.cancel_timers() -- a keypad press and the click guard, the binding re-check, the Driver Version looks
	close_level_window()
end
