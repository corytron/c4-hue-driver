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
-- docs/relative-level-design.md.

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
	-- driver.xml declares supports_default_on, click_rates and hold_rates.
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

-- "Gone from the Hue bridge since 2026-10-24 12:00; Link or Forget Device"
-- for a light; "Zone deleted in Hue since 2026-10-24; Link or Forget Device"
-- for a group (the day alone keeps it under 60 characters).
local function gone_status()
	if state.is_group(st) then
		local since = st.gone_since and (" since " .. os.date("%Y-%m-%d", st.gone_since)) or ""
		return group_word() .. " deleted in Hue" .. since .. "; " .. GONE_REMEDY
	end
	local since = st.gone_since and (" since " .. os.date("%Y-%m-%d %H:%M", st.gone_since)) or ""
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
	return held and state.apply_hue(st, held)
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
local function arm(kind, rate, assume, goal)
	settle(kind)
	local pending = { assume = assume, goal = goal, ramp = rate > 0 }
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
-- (dev.is_on).
local function begin_ramp(from, to, time, tap)
	local r = { from = from, to = math.max(0, math.min(100, to)), time = time, started = now_ms(), tap = tap }
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
	local brightness = tonumber(merged.brightness) or st.brightness
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

-- #421 D5, D7: stop the running ramp where the light is by the clock; false
-- when none runs. The estimate is at least 1, so a stop near off leaves the
-- light on, as a dimmer stopped near the bottom does (§3). It goes into the
-- cache, where a hold or the next tap starts from it, and out as the ramp's
-- CHANGED at once. With nothing pending and no ramp, the bridge's next
-- report goes straight through: in "level" mode the estimate itself, at
-- once, which matches the cache and sends no second CHANGED; any other
-- level corrects it. A #308 wait ends with it. `why` names the stop in the
-- log.
local function stop_ramp(why)
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
		local params = state.from_brightness_target(st, level, STOP_GLIDE_MS)
		params.urgent = "true" -- #421 D12
		send("HUE_SET", params)
	else
		send("HUE_DIM", { rid = st.rid, direction = "stop", level = string.format("%d", level) })
	end
	state.apply_hue(st, { on = "true", brightness = tostring(level) })
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

-- True when the target went to the bridge. When the send fails
-- (common/device.lua logs why) nothing changed: the proxy hears CHANGED with
-- the level its CHANGING came from, and a colour kept for the next turn-on
-- keeps waiting for it. A running ramp is replaced (#421 D11): the CHANGING
-- starts from its estimate, where the tile is. `urgent` (a keypad tap, D12)
-- sends the HUE_SET past the bridge's request bucket; `tap` marks the ramp
-- a tap's, for the log.
local function set_brightness(target, rate, urgent, tap)
	target, rate = tonumber(target), tonumber(rate) or 0
	if not target then
		return log.warn("brightness command without a target")
	end
	if not ready("brightness target") then
		return
	end
	local current = ramp and ramp_estimate(ramp) or state.to_proxy_brightness(st) or 0
	end_ramp()
	-- From off, the level the turn-on waits for (#308); Hue raises a level
	-- below the bulb's lowest to that.
	local goal = st.on == false and target > 0 and on_level(math.max(target, st.min_dim or 0)) or nil
	notify("LIGHT_BRIGHTNESS_CHANGING", {
		LIGHT_BRIGHTNESS_CURRENT = current,
		LIGHT_BRIGHTNESS_TARGET = target,
		RATE = rate,
	})
	local stored = st.pending_color
	local params = state.from_brightness_target(st, target, rate)
	if urgent then
		params.urgent = "true"
	end
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
	end, goal)
	if rate > 0 then
		begin_ramp(current, target, rate, tap)
	end
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
	params = hold_back(params)
	local changed = state.apply_hue(st, params)
	-- Any report of a pending field that got past hold_back settles the
	-- target, whatever the value: the proxy heard CHANGING and must hear
	-- CHANGED. One held back for a ramp settles it at the ramp's end.
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
	C4:SendToDevice(bridge, "HUE_FORGET", { rid = st.rid, device_id = device_id() })
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
-- another day (a Restore that never came); nil when unknown.
local function saved_when(at)
	if not at then
		return nil
	end
	if os.date("%Y-%m-%d", at) == os.date("%Y-%m-%d") then
		return "at " .. os.date("%H:%M", at)
	end
	return os.date("%Y-%m-%d %H:%M", at)
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
-- level out of range) is dropped with a warning, never restored.
local function load_saved()
	saved = nil
	local value = C4:PersistGetValue(SAVED_KEY)
	if value == nil then
		return
	end
	local level = type(value) == "table" and tonumber(value.level) or nil
	local target = type(value) == "table" and tonumber(value.target) or nil
	if level and target and level >= 0 and level <= 100 and target >= 1 and target <= 100 then
		saved = { level = math.floor(level + 0.5), target = math.floor(target + 0.5), at = tonumber(value.at) }
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
	return state.to_proxy_brightness({ on = on, brightness = tonumber(held.brightness) or st.brightness })
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
-- supports_brightness_stop]. A brightness stop while a ramp runs stops it
-- at Hue exactly as a keypad tap does (#421 D7, stop_ramp, STOP_MODE): the
-- stop goes to the bridge and the proxy hears the estimate. With no ramp
-- running, nothing goes to the bridge: the proxy only needs its CHANGED
-- (stop). A colour transition has no stop at Hue: SET_COLOR_STOP only
-- closes the proxy's.
dispatch.proxy["SET_BRIGHTNESS_STOP"] = function()
	if not stop_ramp("brightness stop") then
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

-- ON and TOGGLE turn the light on at the On preset, the Default On
-- Brightness a top keypad tap goes to (#233, owner 2026-11-08), at once as
-- before: TOGGLE from off activates the On preset [verified: proxy
-- reference, light_v2 TOGGLE], and the On preset is the level a top tap
-- gives whatever level the light is at, a higher one too [verified: proxy
-- reference, light_v2 variables, Default On Preset Brightness], so ON on a
-- light already on goes to it as well, as the top tap here does. A preset
-- never set reads as 100, the level both commands always had, and one out
-- of range (0 included) is never taken (common/device.lua), so neither
-- turns a light off. The click rates stay with keypad taps, so a light at
-- the default preset behaves exactly as before; a zone or room light sends
-- the same HUE_SET and the bridge sets every lamp.
dispatch.proxy["TOGGLE"] = function()
	set_brightness(st.on and 0 or setting("preset"), 0)
end

-- Legacy commands that old programming may still send. Which command
-- "Turn On" in programming sends is unverified; ON goes where TOGGLE does.
dispatch.proxy["ON"] = function() set_brightness(setting("preset"), 0) end
dispatch.proxy["OFF"] = function() set_brightness(0, 0) end
dispatch.proxy["SET_LEVEL"] = function(_, params) set_brightness(params.LEVEL, params.TIME) end
dispatch.proxy["RAMP_TO_LEVEL"] = function(_, params) set_brightness(params.LEVEL, params.TIME) end

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
-- lacked (#234).
local HOLD_MAX_MS = 6000000

-- A tap ramps the light, and a press while it ramps stops it (#421,
-- docs/tap-stop-design.md §3). Click rates are whole-range times, as hold
-- rates are (D3): a tap's ramp takes the rate's share of the distance,
-- rounded to whole ms; a rate of 0 is a change at once, with nothing to
-- stop. The start goes past the bridge's request bucket (D12).
local function tap(target, rate, distance)
	set_brightness(target, math.floor(rate * distance / 100 + 0.5), true, true)
end

-- An idle tap (§3). Top goes to the On preset (D2, #233): from off over the
-- click rate up's share of the preset, up to it from below, down to it from
-- above over the click rate down; at it (within a point) nothing goes to
-- Hue and the proxy hears the level. Bottom goes off over the click rate
-- down's share of the level; off already, nothing. Toggle goes off while
-- the light shows on, else as top from off. A light whose state is not
-- known yet is taken as off by top and toggle, and bottom turns it off over
-- the whole rate. The machine stops a running ramp on the press and
-- swallows its click (D5, common/device.lua), so a click reaches here during
-- a ramp only when the ramp began between the press and the click: it stops
-- that one too. A device that cannot be driven drops the tap with its
-- reason, as it drops a target.
function dev.on_click(button)
	if stop_ramp("tap") or not ready("brightness target") then
		return
	end
	local preset, on, level = setting("preset"), st.on, state.to_proxy_brightness(st)
	if button == BUTTON_BOTTOM or (button ~= BUTTON_TOP and on) then
		if on == false then
			return log.debug("tap: the %s is off already", what())
		end
		return tap(0, setting("click_down"), level or 100)
	end
	if not on then
		return tap(preset, setting("click_up"), preset)
	end
	if math.abs(level - preset) <= 1 then
		log.debug("tap: at the On preset (%d %%) already", preset)
		return report_brightness()
	end
	if level < preset then
		return tap(preset, setting("click_up"), preset - level)
	end
	tap(preset, setting("click_down"), level - preset)
end

-- The machine's hooks for the stop (#421 D5, common/device.lua): a press
-- outside the double-tap window while a ramp runs stops it on the push, on
-- any button; a press held on afterwards holds from the stopped level.
function dev.ramp_active()
	return ramp ~= nil
end

function dev.on_ramp_stop()
	stop_ramp("tap")
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
	-- The ramp replaces whatever target was pending (the turn-on at 1 %), and
	-- a brightness ramp still running (#421: a hold ends it).
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
-- on at 1 % first and the ramp up follows (dev.dim_after_on). A press that
-- stopped a ramp (#421 D5, h.stopped) holds from the stopped level, which
-- the stop left in the cache. A ramp that began after the press (from
-- programming, say) holds from its estimate, and the hold's dim replaces it
-- at Hue [assumed: #421 §7 L9]; start_ramp ends its record.
function dev.on_hold(h, up, on)
	if not ready("hold") then
		return
	end
	if on then
		local from = ramp and ramp_estimate(ramp) or state.to_proxy_brightness(st) or 1
		return start_ramp(h, up, math.max(1, from))
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
	load_saved() -- before dev.late_init() runs a Restore that arrived early
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
