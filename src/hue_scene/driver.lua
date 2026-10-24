-- Hue Scene driver: one light_v2 dimmer per Hue scene. ON recalls the scene,
-- OFF turns the scene's group off, the level shown is the group's brightness
-- as Hue reports it, and the slider moves the group relative to it, so the
-- scene's per-light differences stay (docs/scene-dimmer-design.md). A device
-- can also stand for a time-based ("smart") scene, a kind its configuration
-- names: it is on exactly while Hue says the schedule runs, ON starts it and
-- OFF stops it (docs/smart-scenes-design.md). It never speaks to the bridge
-- itself: commands go to the Hue Bridge driver it is bound to (consumer
-- binding 1, class HUE_BRIDGE) with C4:SendToDevice, and the bridge pushes
-- configuration and state back through ExecuteCommand. The message contract
-- is docs/scenes-design.md §2, this device §3, extended by
-- docs/keypad-design.md, docs/scene-dimmer-design.md and
-- docs/smart-scenes-design.md; the structure is the Hue Light driver's
-- (src/hue_light/driver.lua) with everything colour specific left out.

local log = require("common.log")
local dispatch = require("common.dispatch")

-- Dev builds only (tools/build.sh --dev ships common/devloop.lua): the bridge
-- forwards this driver's new code as DEV_RELOAD, see docs/dev-loop.md.
-- Release builds have no such module, so this is nil.
local devloop_ok, devloop = pcall(require, "common.devloop")
if not devloop_ok then
	-- Absent in release builds (expected); anything else is a real error
	-- that must be visible, since the loop is how the controller gets tested.
	-- A missing module reads "not found" under busted and "An unknown error
	-- occurred" on the controller [hardware 2026-10-24].
	local reason = tostring(devloop):lower()
	if not (reason:find("not found", 1, true) or reason:find("unknown error", 1, true)) then
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
local level_seq = 0        -- counts lit level reports, to tell whether one arrived since a recall
local last_reported = nil  -- the LIGHT_BRIGHTNESS_CURRENT last sent to the proxy
local level_window = nil   -- { timer, dirty } for LEVEL_REPORT_MS after a level report went out
local bridge = nil           -- device id of the bound Hue Bridge driver, or nil
local pending = nil          -- { timer, assume, on } while a recall/off awaits its STATE
local follow = nil           -- what follows a time-based scene's start from off (arm_follow)
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
	if st.active == nil and not held() then
		return nil
	end
	if not effective_on() then
		return 0
	end
	return st.level and whole_percent(st.level) or 100
end

-- Keypad LEDs ----------------------------------------------------------------
-- A keypad bound to a Button Link follows the scene: MATCH_LED_STATE on each
-- link, and BUTTON_INFO per button to the proxy [verified: Snap One's
-- drivers-template-code-public c4hook_light_v2.lua, docs/keypad-design.md
-- "Keypad LEDs"; BUTTON_INFO fields: proxy ref, BUTTON_INFO notification].

-- Keypad buttons bound to the driver's Button Link connections (driver.xml
-- 200 top, 201 bottom, 202 toggle) -> BUTTON_ID.
local LINK_BUTTON = { [200] = 0, [201] = 1, [202] = 2 }
local LINK_BINDINGS = { 200, 201, 202 }
local BUTTON_LINK = { [0] = 200, [1] = 201, [2] = 202 }

-- Per-button colours: bottom is lit while the scene is off.
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
		CURRENT_COLOR = button_color(button, (effective_on()) and "on" or "off"),
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

-- The LEDs follow the on state once it is known; `force` resends an
-- unchanged state (a keypad was just bound to a link).
local function update_leds(force)
	if brightness() == nil then
		return
	end
	local on = effective_on()
	if force or on ~= led_on then
		send_leds(on)
	end
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
local function send_level(level, rate, unconfirmed)
	log.info("level: %d %% over %d ms", level, rate)
	C4:SendToDevice(bridge, "HUE_SCENE_LEVEL", {
		rid = st.rid,
		device_id = device_id(),
		level = string.format("%d", level),
		rate = string.format("%d", rate),
	})
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
end

local function go_level(f)
	if blocker() then
		return false
	end
	send_level(f.level, f.rate, not is_on())
	return true
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
-- which then closes the proxy's transaction (Decision 4).
local function start_smart(rate, level)
	if level then
		log.info("ON: starting the time-based scene, then the room to %d %%", level)
	else
		log.info("ON: starting the time-based scene")
	end
	C4:SendToDevice(bridge, "HUE_SCENE_RECALL", { rid = st.rid, action = DEFAULT_RECALL })
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
-- A time-based scene starts instead (start_smart).
local function turn_on(rate, level)
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
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = brightness() or 0,
		LIGHT_BRIGHTNESS_TARGET = level or 100,
		RATE = rate,
	})
	if is_smart() then
		return start_smart(rate, level)
	end
	local action = recall_action
	local params = recall_params(rate)
	if level then
		params.brightness = string.format("%d", level)
		log.info("ON: recalling as %s at %d %%", action, level)
	else
		log.info("ON: recalling as %s", action)
	end
	C4:SendToDevice(bridge, "HUE_SCENE_RECALL", params)
	local p = { kind = "switch", on = true, level = level, seq = level_seq }
	p.assume = function()
		log.debug("recall (%s) unconfirmed after %d ms; assuming the scene is on", action, FALLBACK_MS)
		st.active = assumed_active(action)
		take_recalled_level(p)
		report_brightness()
	end
	arm(p, FALLBACK_MS)
end

-- This device turning the scene off ends the held state at once. A
-- time-based scene stops: the bridge deactivates it, then turns the group
-- off (docs/smart-scenes-design.md, Decision 5).
local function turn_off(rate)
	rate = tonumber(rate) or 0
	if not ready("OFF") then
		return
	end
	cancel_follow()
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = brightness() or 100,
		LIGHT_BRIGHTNESS_TARGET = 0,
		RATE = rate,
	})
	set_held(false)
	C4:SendToDevice(bridge, "HUE_SCENE_OFF", { rid = st.rid })
	arm({ kind = "switch", on = false, assume = function()
		log.debug("off unconfirmed after %d ms; assuming the scene is off", FALLBACK_MS)
		st.active = "inactive"
		if is_smart() then
			refresh_status()
		end
		report_brightness()
	end }, FALLBACK_MS)
end

-- The slider while the scene is on: the bridge moves the group to `level`
-- relative to its current level, so the scene's per-light differences stay
-- (HUE_SCENE_LEVEL, docs/scene-dimmer-design.md). The proxy hears CHANGED
-- with the bridge's next level report, or the target after the ramp plus
-- LEVEL_FALLBACK_MS (send_level).
local function move_level(level, rate)
	if not ready("brightness target") then
		return
	end
	cancel_follow()
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = brightness() or 100,
		LIGHT_BRIGHTNESS_TARGET = level,
		RATE = rate,
	})
	send_level(level, rate)
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
	if (pending and pending.kind == "switch") or not effective_on() then
		return turn_on(rate, level)
	end
	move_level(level, rate)
end

-- SET_BRIGHTNESS_STOP: the proxy wants the transition closed now. The cached
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
		flush_log() -- dev builds: lines logged while the bridge was unknown
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

-- Director answers the version lookup with nothing at the first init of a
-- device created by AddDevice [hardware 2026-10-24, device 1166], so the
-- build's own stamp (common/build_version.lua, tools/build.sh) is the fallback.
local build_version_ok, build_version = pcall(require, "common.build_version")
local function driver_version()
	local v = C4:GetDriverConfigInfo("version")
	if v == nil or tostring(v) == "" then
		v = build_version_ok and tostring(build_version) or ""
	end
	return v
end

dispatch.properties["Driver_Version"] = function()
	prop("Driver Version", driver_version())
end

-- Director fills a new device's property table late: at the first init of
-- a device created by AddDevice the replay of the properties reaches no
-- Driver_Version handler [hardware 2026-10-24, devices 1166 and 1168], so
-- late init writes the row itself and looks again twice while it is empty.
local function show_driver_version(attempt)
	local v = driver_version()
	prop("Driver Version", v)
	if v == "" and attempt < 3 then
		C4:SetTimer(5000 * attempt, function() show_driver_version(attempt + 1) end)
	end
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

-- The kind a configure names; none (a bridge from before time-based scenes)
-- is an ordinary scene. A change (Re-link Scene across kinds) drops what
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
dispatch.commands["HUE_SCENE_STATE"] = after_late_init("HUE_SCENE_STATE", function(params)
	params = params or {}
	if st.rid and params.rid and params.rid ~= st.rid then
		return log.warn("HUE_SCENE_STATE for rid %s ignored (ours is %s)", params.rid, st.rid)
	end
	if not ACTIVE_VALUES[params.active] then
		return log.warn("HUE_SCENE_STATE without a known status (%s) ignored", tostring(params.active))
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
dispatch.commands["HUE_SCENE_GROUP"] = after_late_init("HUE_SCENE_GROUP", function(params)
	params = params or {}
	if st.rid and params.rid and params.rid ~= st.rid then
		return log.warn("HUE_SCENE_GROUP for rid %s ignored (ours is %s)", params.rid, st.rid)
	end
	local before = brightness()
	local level = tonumber(params.level)
	if level and level > 0 then
		st.level = math.min(level, 100)
		level_seq = level_seq + 1
	end
	local on = to_bool(params.on)
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
	local ended = on == false or (to_bool(params.other_active) == true and not is_smart())
	if ended then
		if held_on then
			log.debug("held-on state ended: %s", on == false and "the group went off" or "another scene is active")
		end
		set_held(false)
	end
	if pending and pending.kind == "level" and (level or ended) then
		settle()
		report_brightness()
		if level then
			open_level_window()
		end
	elseif ended then
		report_if_changed(before)
	elseif level and level > 0 and effective_on() then
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
	log.warn("forgotten by the bridge (was Hue scene %s)", st.forgotten.name or st.rid or "unknown")
	prop("Last Action", "Forgotten by the bridge")
	refresh_status()
	report_online()
end)

-- Dev-only: dump what Director's Properties table holds and what this
-- driver believes, for the dev loop (the bridge sends it with SendToDevice).
-- Release builds (no devloop module) drop the handler below.
dispatch.commands["HUE_DUMP"] = function()
	local parts = {}
	for k, v in pairs(Properties or {}) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
	table.sort(parts)
	log.always("Properties: %s", table.concat(parts, " | "))
	log.always("state: rid=%s name=%s kind=%s configured=%s active=%s slot=%s held_on=%s level=%s "
		.. "recall_action=%s debug=%s", tostring(st.rid), tostring(st.name), tostring(st.kind),
		tostring(st.configured), tostring(st.active), tostring(st.slot_name), tostring(held_on),
		tostring(st.level), tostring(recall_action), tostring(log.enabled("debug")))
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
	-- §1): the scene's own name in a room, the zone's name in front for a zone;
	-- a time-based scene's without the app's number (docs/smart-scenes-design.md,
	-- Decision 7).
	local name = is_smart() and base_name(st.name) or st.name
	if st.group_type == "zone" and st.group_name then
		name = st.group_name .. " " .. name
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
-- [verified: proxy ref, SET_BRIGHTNESS_TARGET]; the Navigator slider is this
-- (set_target above).
dispatch.proxy["SET_BRIGHTNESS_TARGET"] = function(_, params)
	set_target(params.LIGHT_BRIGHTNESS_TARGET, params.RATE)
end

-- Advanced Lighting Scenes with reduced_als_support drive the scene with
-- SET_BRIGHTNESS_TARGET and end a scene ramp with these; both carry no
-- parameters [verified: proxy ref, SET_BRIGHTNESS_STOP, reduced_als_support,
-- supports_brightness_stop]. Nothing goes to the bridge: a scene recall
-- cannot be stopped, the proxy only needs its CHANGED (a level move's
-- end comes with the bridge's next level report).
dispatch.proxy["SET_BRIGHTNESS_STOP"] = function()
	stop()
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
		on = effective_on()
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
-- A tap of the top button recalls, of the bottom button turns the group off,
-- of the toggle button toggles. A hold dims the scene's group relatively, so
-- its colours and per-light differences stay: top (or toggle while off) up,
-- bottom (or toggle while on) down; holding top while off recalls the scene
-- at 1 % first. Every BUTTON_ACTION is echoed as the proxy requires
-- [verified: proxy-protocol reference, light_v2 BUTTON_ACTION]; behaviour:
-- docs/keypad-design.md, "Scene device".
local BUTTON_TOP, BUTTON_BOTTOM = 0, 1
local ACT_RELEASE, ACT_PRESS, ACT_CLICK = 0, 1, 2
local HOLD_AFTER_MS = 400       -- a press still down after this is a hold
local RECALL_DIM_AFTER_MS = 600 -- hold from off: the dim follows the 1 % recall this much later
local CLICK_GUARD_MS = 1000     -- a click this soon after a hold's release on that button is ignored
local SETTING_KEYS = { hold_up = "hold_rate_up", hold_down = "hold_rate_down" }
local SETTING_DEFAULTS = { hold_up = 5000, hold_down = 5000 }
local settings = {}
local hold = nil  -- { button, timer, held, dim_sent } while a button is down
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
	-- A time-based scene this hold started: its dim follows only while held.
	if hold and follow and follow.hold == hold then
		cancel_follow()
	end
	hold = nil
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

local function button_click(button)
	if button == BUTTON_TOP then
		turn_on(0)
	elseif button == BUTTON_BOTTOM then
		turn_off(0)
	else
		dispatch.proxy["TOGGLE"]()
	end
end

-- HUE_SCENE_DIM to the bridge: up / down over `duration` ms, or stop.
local function send_dim(direction, duration)
	local params = { rid = st.rid, device_id = device_id(), direction = direction }
	if duration then
		params.duration = string.format("%d", duration)
	end
	log.debug("hold: dim %s%s", direction, duration and (" over " .. params.duration .. " ms") or "")
	C4:SendToDevice(bridge, "HUE_SCENE_DIM", params)
end

-- The proxy hears a hold as a CHANGING toward the end of the range over the
-- hold rate when it starts (docs/scene-dimmer-design.md, Keypad holds); the
-- bridge's level reports settle it. It replaces whatever target was pending.
local function hold_changing(h, current, up, duration)
	settle()
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = current,
		LIGHT_BRIGHTNESS_TARGET = up and 100 or 1,
		RATE = duration,
	})
	h.changing = true
end

-- A time-based scene that is off starts (its activate has no brightness to
-- start at 1 % with), and the dim up follows once the slot's look is on,
-- while the button is still down (docs/smart-scenes-design.md, Decision 4);
-- released before then, the scene just runs. The tile and the LEDs follow
-- its STATE.
local function start_smart_hold(h, duration)
	hold_changing(h, 0, true, duration)
	log.info("hold: starting the time-based scene, then dimming up")
	C4:SendToDevice(bridge, "HUE_SCENE_RECALL", { rid = st.rid, action = DEFAULT_RECALL })
	arm_follow({ kind = "dim", hold = h, go = function()
		if hold ~= h or not h.held or blocker() then
			return false
		end
		send_dim("up", duration)
		h.dim_sent = true
		return true
	end })
end

-- The hold timer fired with the button still down. A hold from here makes an
-- ordinary scene held on (a keypad recall or dim, the on rule).
local function start_hold(h)
	h.held = true
	local on = effective_on()
	local up = h.button == BUTTON_TOP or (h.button ~= BUTTON_BOTTOM and not on)
	if not up and not on then
		return log.debug("hold: dimming down a scene that is off does nothing")
	end
	if not ready("hold") then
		return
	end
	cancel_follow()
	local duration = setting(up and "hold_up" or "hold_down")
	if not is_smart() then
		set_held(true)
	end
	if on then
		hold_changing(h, brightness() or 100, up, duration)
		send_dim(up and "up" or "down", duration)
		h.dim_sent = true
		return
	end
	if is_smart() then
		return start_smart_hold(h, duration)
	end
	-- Off: recall at 1 %, then ramp up from there once Hue has applied it.
	-- The LEDs turn on at once; the tile follows the CHANGING.
	hold_changing(h, 0, true, duration)
	update_leds()
	local params = recall_params(0)
	params.brightness = "1"
	log.info("hold: recalling as %s at 1 %%, then dimming up", recall_action)
	C4:SendToDevice(bridge, "HUE_SCENE_RECALL", params)
	h.timer = C4:SetTimer(RECALL_DIM_AFTER_MS, function()
		if hold ~= h then
			return
		end
		h.timer = nil
		if bridge and st.rid then
			send_dim("up", duration)
			h.dim_sent = true
		end
	end)
end

-- Release (or release-as-click) after a hold: stop a dim that was sent, close
-- the hold's CHANGING with the bridge's next level report (or the cached
-- level after LEVEL_FALLBACK_MS), and ignore the click some keypads send
-- after it.
local function finish_hold()
	local h = hold
	end_hold()
	if h.dim_sent and bridge and st.rid then
		send_dim("stop")
	end
	if h.changing then
		arm({ kind = "level", on = true, assume = function()
			log.debug("no level report %d ms after the hold; reporting the cached one", LEVEL_FALLBACK_MS)
			report_brightness()
		end }, LEVEL_FALLBACK_MS)
	end
	arm_guard(h.button)
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
			button_click(button)
		end
	elseif action == ACT_RELEASE then
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

-- Keypad buttons bound to the driver's Button Link connections (200 top,
-- 201 bottom, 202 toggle) deliver DO_PUSH / DO_RELEASE / DO_CLICK on the
-- binding [verified: public light_v2 drivers].
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

dispatch.proxy["SET_HOLD_RATE_UP"] = function(_, params) save_setting("hold_up", params.RATE) end
dispatch.proxy["SET_HOLD_RATE_DOWN"] = function(_, params) save_setting("hold_down", params.RATE) end

-- A keypad on a link asks for its button's colours and the LED state.
dispatch.proxy["REQUEST_BUTTON_COLORS"] = function(binding)
	local button = link_button(binding, "REQUEST_BUTTON_COLORS")
	if not button then
		return
	end
	send_button_colors(tonumber(binding), button)
	C4:SendToProxy(tonumber(binding), "MATCH_LED_STATE", { STATE = effective_on() }, "COMMAND")
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
	send_button_info(button, effective_on())
end

-- Legacy commands that old programming may still send: the slider's path.
dispatch.proxy["SET_LEVEL"] = function(_, params) set_target(params.LEVEL, params.TIME) end
dispatch.proxy["RAMP_TO_LEVEL"] = function(_, params) set_target(params.LEVEL, params.TIME) end

-- Lifecycle ----------------------------------------------------------------

log.set_prefix(LOG_PREFIX)
-- Release builds (no dev loop) carry no dump handler.
if not devloop then
	dispatch.commands["HUE_DUMP"] = nil
end

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
	recall_as_hidden = nil -- Recall As is shown or hidden again at every late init
	load_identity()
	load_settings()
	load_colors()
	load_held()
	dispatch.replay_properties(Properties)
	show_driver_version(1)
	prop("Hue Scene ID", scene_id_label())
	prop("Hue Scene", st.name)
	-- The bridge first, so messages it sent before this point are applied
	-- against the right binding state; then the hello carries whatever
	-- identity they delivered.
	bridge = bound_bridge()
	drain_early()
	apply_recall_as() -- for the persisted kind, unless a buffered configure just did
	hello()
	report_online()
	-- The LEDs, once, when buffered messages or a persisted held_on made the
	-- state known already (otherwise the first report sends them).
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
		settle()
		cancel_follow()
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
	cancel_follow()
	end_hold()
	disarm_guard()
	cancel_recheck()
	close_level_window()
end
