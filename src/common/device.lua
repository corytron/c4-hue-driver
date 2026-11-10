-- The plumbing the Hue Light and Hue Scene drivers share around their
-- light_v2 proxy and their bridge binding: properties and proxy notifies, the
-- bridge and proxy lookups, the Driver Version row, the buffer for bridge
-- messages that arrive before late init, the keypad Button Links with their
-- LEDs, button colours and press / click / release machine, the binding
-- re-check after a Director restart, the goodbye on a Composer delete, and
-- the dev-build pieces (log forwarding, DEV_RELOAD) that common/devloop.lua
-- carries. Until 2026-10-24 each driver had its own byte-identical copy of
-- every block here (docs/reviews/slim-device-drivers.md, #5 Stage A), and
-- until 2026-10-25 its own copy of the keypad machine (Stage B, #57); the
-- code is those copies, and both drivers' specs pin it end to end. What the
-- two drivers do differently (the hold itself, the targets, the identity
-- texts) stays in the drivers and reaches this module through hooks.
--
-- No module-level state: device.new() returns one instance per driver.
--
--   local dev = device.new({
--       prefix = "Hue Light",   -- the log prefix; the dev-build forwarding knows its own lines by it
--       tree = "light",         -- the dev loop's name for this driver's source tree (DEV_RELOAD)
--       bridge = function() return bridge end,  -- device id of the bound Hue Bridge driver, or nil
--       rid = function() return st.rid end,     -- the device's Hue resource id, or nil
--       noun = "light",         -- what the keypad's log lines call the device
--       settings = { "hold_up", "hold_down" },  -- the keypad settings its driver.xml declares (SETTINGS)
--   })
--
-- Hooks the driver assigns once the functions they call exist (they are read
-- when something arrives, never at load):
--   dev.is_on()              nil while the on state is unknown, else whether the device
--                            shows on: what the keypad LEDs and holds follow
--   dev.on_bridge_found()    the re-check found the bridge: greet it and report online
--   dev.on_click(button)     a keypad tap
--   dev.on_hold(h, up, on)   a keypad hold began ("Keypad press, click and release" below)
--   dev.on_finish(h)         the release of a hold that began
--   dev.on_end_hold(h)       optional: a press ended, whatever ended it
--   dev.ramp_active()        optional: true while a brightness ramp a tap can stop runs
--                            (#421 D6); the default, false, leaves only the double-tap window
--   dev.on_ramp_stop(button) optional: stop that ramp now (#421 D5); the default does nothing
--   dev.on_link(l, changed)  optional: a HUE_BRIDGE_LINK was taken into dev.link (#428 D5,
--                            docs/offline-design.md §6.6); `changed` says whether what the
--                            device shows moves: offline, back online, or another reason or
--                            since while offline. The default does nothing
--
-- The instance: devloop (the module; nil in release builds), flush_log(),
-- prop(), notify(), device_id(), result(), bound_bridge(), proxy_id(),
-- send(), after_late_init(), late_init(), link (the bridge's link as
-- common/link.lua parsed it, nil until told), link_offline(), link_text(),
-- binding_changed(),
-- replay_bindings(), show_driver_version(), load_colors(), update_leds(),
-- setting(), take_setting(), load_settings(), rate_default(), rate_caps(),
-- first_arrival(), button_action(), holding(), dim_after_on(),
-- link_button(), schedule_recheck(), cancel_recheck(), cancel_timers() and
-- goodbye(). It registers the Driver_Version and Debug_Mode property
-- handlers, the bridge's HUE_BRIDGE_LINK (#428; the Hue Motion driver puts
-- its own in place after device.new), the proxy's BUTTON_ACTION, DO_PUSH,
-- DO_RELEASE, DO_CLICK,
-- REQUEST_BUTTON_COLORS, SET_BUTTON_COLOR and SET_ALL_LED (#432 D11), the SET_* command of each
-- keypad setting it takes, UPDATE_BRIGHTNESS_RATE_DEFAULT and
-- UPDATE_COLOR_RATE_DEFAULT (#430 D8), and DEV_RELOAD in dev builds.
--
-- OnDriverLateInit in both drivers: load_settings() (the keypad settings
-- and the default rates) and load_colors() with
-- the persisted identity, read the binding (bound_bridge), then late_init()
-- (the buffered bridge messages), greet, and replay_bindings() last;
-- OnDriverDestroyed calls cancel_timers().
--
-- The light's own button events (#432, docs/light-events-design.md §3.1):
-- every press that reaches the device, by either route, tells the proxy
-- what the button did (BUTTON_ACTION push and release, then the tap count
-- when the double-tap window closes), so the proxy fires the device's Press,
-- Release and Single, Double and Triple Tap events. device.BUTTON_EVENTS_MODE
-- says how the count goes out.

local log = require("common.log")
local dispatch = require("common.dispatch")
local link = require("common.link")

local device = {}

-- Binding IDs, the same in both driver.xml: the light_v2 proxy on 5001, the
-- Hue Bridge consumer connection on 1.
device.PROXY_BINDING = 5001
device.BRIDGE_BINDING = 1
local PROXY_BINDING, BRIDGE_BINDING = device.PROXY_BINDING, device.BRIDGE_BINDING

-- BUTTON_ACTION's actions: 1 press, 2 release as a click, 0 release after a
-- hold; its buttons: 0 top, 1 bottom, 2 toggle [verified: proxy-protocol
-- reference, light_v2 BUTTON_ACTION].
device.ACT_RELEASE, device.ACT_PRESS, device.ACT_CLICK = 0, 1, 2
local ACT_RELEASE, ACT_PRESS, ACT_CLICK = device.ACT_RELEASE, device.ACT_PRESS, device.ACT_CLICK
device.BUTTON_TOP, device.BUTTON_BOTTOM = 0, 1
local BUTTON_TOP, BUTTON_BOTTOM = device.BUTTON_TOP, device.BUTTON_BOTTOM

-- Keypad buttons bound to the driver's Button Link connections (driver.xml
-- 200 top, 201 bottom, 202 toggle) -> BUTTON_ID.
device.LINK_BUTTON = { [200] = 0, [201] = 1, [202] = 2 }
local LINK_BUTTON = device.LINK_BUTTON
local LINK_BINDINGS = { 200, 201, 202 }
local BUTTON_LINK = { [0] = 200, [1] = 201, [2] = 202 }

-- Per-button colours: bottom is lit while the device is off.
local COLOR_DEFAULTS = {
	[0] = { on = "0000ff", off = "000000" },
	[1] = { on = "000000", off = "0000ff" },
	[2] = { on = "0000ff", off = "000000" },
}

-- The keypad machine's timing (docs/keypad-design.md): a press still down
-- after HOLD_AFTER_MS is a hold; a hold from off dims up DIM_AFTER_ON_MS
-- after the device was turned on at 1 %; a click on the same button within
-- CLICK_GUARD_MS after a hold's release is the keypad's own and is ignored.
local HOLD_AFTER_MS = 400
local DIM_AFTER_ON_MS = 600
local CLICK_GUARD_MS = 1000

-- #421 D4: a press within DOUBLE_TAP_MS of the previous press on the same
-- button is part of a double or triple tap, which is the keypad's event
-- (its programming), not a second command. Composer puts that window at
-- about half a second [verified: Composer Pro help, configuring lighting;
-- docs/tap-stop-research-c4.md §1.4]; the keypad's real one is to be
-- measured on the house (that note's §9). Fixed here, no property.
device.DOUBLE_TAP_MS = 600
local DOUBLE_TAP_MS = device.DOUBLE_TAP_MS

-- #432 D7: how a closed tap sequence reaches the proxy, read at each close
-- (the specs set it per test). "count": CLICK_COUNT {BUTTON_ID, COUNT}, the
-- keypad pattern [verified: LV2 notif _3-CLICKCOUNT.md; KP
-- 61_keypad_protocol_notifications/_2-CLICKCOUNT.md]. "action": BUTTON_ACTION
-- with ACTION 2, 3 or 4, single, double or triple tap [verified: LV2 notif
-- _1-BUTTONACTION.md], and every Button Link release then notifies 0. Which
-- of the two the proxy fires its tap events from is not documented
-- [assumed: "count"]; house check P3 (docs/light-events-design.md §8.2,
-- step 100) settles it before the release. Lua only: a change needs no
-- reboot. No property.
device.BUTTON_EVENTS_MODE = "count"

-- #432 D6: a sequence counts at most a triple tap (the proxy's button events
-- stop at Triple Click [verified: LV2 25_light_v2_events/_0-HEADER.md]).
local MAX_TAPS = 3

-- Milliseconds since the epoch on the controller's clock [verified: API
-- 34/_2, C4:GetTime, OS 3.2.3; the drivers declare 3.3.0], else os.time(),
-- as hue_motion's now_ms does. C4 is looked up at the call: the runtime's.
local function now_ms()
	local ok, ms = pcall(C4.GetTime, C4)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

-- #430 D20 (docs/turn-on-design.md): the longest ramp the drivers take,
-- 6 000 000 ms (100 minutes), the Hue duration ceiling the bridge already
-- holds scene and group durations to (bridge/scenes.lua,
-- bridge/zone_lights.lua) [assumed for a single light's PUT, D20]. It is the
-- click and hold rates' maximum below, the default rates' (D8), the
-- click_rate_max and hold_rate_max both driver.xml files declare, and the
-- dynamic brightness_rate_max (rate_caps). Until #430 the click and hold
-- rates took up to 86 400 000 ms, the documented hold_rate_max default
-- [verified: LV2 caps _16-HOLDRATEMAX.md]; a stored rate above the new
-- maximum is dropped at load with one warning (load_settings).
device.RATE_MAX = 6000000
local RATE_MAX = device.RATE_MAX

-- The keypad settings the light_v2 proxy sends when the dealer edits them in
-- Composer [verified: proxy-protocol reference, light_v2 SET_PRESET_LEVEL
-- {LEVEL}, SET_CLICK_RATE_* and SET_HOLD_RATE_* {RATE ms}]: the persisted key,
-- the default, the command and its parameter, and the notification that
-- tells the proxy the value now in use (PRESET_LEVEL, CLICK_RATE_UP/DOWN,
-- HOLD_RATE_UP/DOWN). Without that answer the proxy keeps its old value: on
-- the house (dev build 284, 2026-10-25) a hold rate set to 2.000 s reached the
-- driver, Composer still showed 5.000 afterwards, and setting 5.000 again sent
-- nothing. The notification carries the BARE value: the reference documents
-- a table ({RATE} / {BRIGHTNESS}), but the proxy reads such a table as 0
-- (Default On Brightness 0, click rates 0, hold rates clamped to its 1 s
-- minimum), while "5000" or 5000 is stored as sent [verified: hardware,
-- Composer rounds 41 and 42]. A driver takes the ones its driver.xml
-- declares (opts.settings). The click rates are the time of the whole range,
-- as the hold rates are [verified: proxy reference, CLICK_RATE_UP/DOWN], and
-- default to 3000 ms so a tap's ramp is slow enough to catch with a second
-- tap after the double-tap window (#421 D3; 250 ms until then). A device
-- with a stored rate keeps it. Click and hold rates run 0..RATE_MAX (#430
-- D20), the range driver.xml declares, so Composer and the driver agree.
local SETTINGS = {
	preset = { key = "preset_level", default = 100, command = "SET_PRESET_LEVEL", param = "LEVEL",
		notify = "PRESET_LEVEL", min = 1, max = 100 },
	click_up = { key = "click_rate_up", default = 3000, command = "SET_CLICK_RATE_UP", param = "RATE",
		notify = "CLICK_RATE_UP", min = 0, max = RATE_MAX },
	click_down = { key = "click_rate_down", default = 3000, command = "SET_CLICK_RATE_DOWN", param = "RATE",
		notify = "CLICK_RATE_DOWN", min = 0, max = RATE_MAX },
	hold_up = { key = "hold_rate_up", default = 5000, command = "SET_HOLD_RATE_UP", param = "RATE",
		notify = "HOLD_RATE_UP", min = 0, max = RATE_MAX },
	hold_down = { key = "hold_rate_down", default = 5000, command = "SET_HOLD_RATE_DOWN", param = "RATE",
		notify = "HOLD_RATE_DOWN", min = 0, max = RATE_MAX },
}

-- #430 D8: the proxy's default rates [verified: LV2 cmds
-- _20.2-UPDATEBRIGHTNESSRATEDEFAULT.md, _20.5-UPDATECOLORRATEDEFAULT.md:
-- RATE in ms, the rate used where a command names none], in the order they
-- load: the persisted key and the command that sets each.
local RATE_DEFAULTS = {
	{ which = "brightness", key = "brightness_rate_default", command = "UPDATE_BRIGHTNESS_RATE_DEFAULT" },
	{ which = "color", key = "color_rate_default", command = "UPDATE_COLOR_RATE_DEFAULT" },
}

-- The binding re-check's gaps: checks at 5, 15, 30 and 60 s after start.
local RECHECK_MS = { 5000, 10000, 15000, 30000 }

-- Parsing ------------------------------------------------------------------

-- A string param, or nil when absent or empty (SendToDevice drops empty
-- values, so "" never arrives; an absent key is the same thing).
function device.text(v)
	if v == nil or v == "" then
		return nil
	end
	return tostring(v)
end

function device.to_bool(v)
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

-- The instance ---------------------------------------------------------------

function device.new(opts)
	local prefix, tree = opts.prefix, opts.tree
	local get_bridge, get_rid = opts.bridge, opts.rid
	local dev = {}

	log.set_prefix(prefix)

	-- Dev loop ---------------------------------------------------------------

	-- Dev builds only (tools/build.sh --dev ships common/devloop.lua): the
	-- bridge forwards this driver's new code as DEV_RELOAD, see
	-- docs/dev-loop.md. Release builds have no such module, so this is nil.
	local devloop_ok, devloop = pcall(require, "common.devloop")
	if not devloop_ok then
		-- Absent in release builds (expected); anything else is a real error
		-- that must be visible, since the loop is how the controller gets
		-- tested. A missing module reads "not found" under busted and "An
		-- unknown error occurred" on the controller [hardware 2026-10-24].
		local reason = tostring(devloop):lower()
		if not (reason:find("not found", 1, true) or reason:find("unknown error", 1, true)) then
			print("[ERROR] " .. prefix .. ": dev loop failed to load: " .. tostring(devloop))
		end
		devloop = nil
	end
	dev.devloop = devloop

	-- Dev builds: every line this driver logs, debug excepted, also goes to
	-- the bridge as HUE_LOG (devloop.forward_logs); lines logged before the
	-- bridge is known wait and go out from flush_log(), which the driver's
	-- hello calls. Release builds leave log.sink alone and have no DEV_RELOAD.
	dev.flush_log = function() end
	if devloop then
		dev.flush_log = devloop.forward_logs(log, prefix, get_bridge, get_rid)
		dispatch.commands["DEV_RELOAD"] = devloop.reload_handler(log, tree)
	end

	-- Properties and proxy notifies ----------------------------------------

	local function prop(name, value)
		C4:UpdateProperty(name, tostring(value == nil and "" or value))
	end
	dev.prop = prop

	-- The parameter dump is for the debug line alone: with Debug Mode off
	-- (the default) nothing is built, sorted or joined per notification.
	local function notify(command, params)
		if log.enabled("debug") then
			local parts = {}
			for k, v in pairs(params or {}) do parts[#parts + 1] = k .. "=" .. tostring(v) end
			table.sort(parts)
			log.debug("-> proxy %s %s", command, table.concat(parts, " "))
		end
		C4:SendToProxy(PROXY_BINDING, command, params)
	end
	dev.notify = notify

	-- Every inter-driver param is a string.
	local function device_id()
		return tostring(C4:GetDeviceID())
	end
	dev.device_id = device_id

	-- Composer actions (LUA_ACTION): every click ends in Last Action and a
	-- log line, whatever happened.
	function dev.result(text)
		log.always("%s", text)
		prop("Last Action", text)
	end

	-- Bridge binding --------------------------------------------------------

	-- The bound bridge's device id. The API documents a table of id/name
	-- pairs, the idc_client sample uses the result as a number: accept both.
	-- With nothing bound the docs say nil but OS 3.4.2 answers the number 0
	-- [hardware 2026-10-22, design.md "Project APIs"], which Lua would take
	-- for a bridge.
	local function bound_bridge()
		local found = C4:GetBoundProviderDevice(C4:GetDeviceID(), BRIDGE_BINDING) -- [verified: API 32/_4]
		if type(found) == "table" then
			found = next(found)
		end
		found = tonumber(found)
		if found and found > 0 then
			return found
		end
		return nil
	end
	dev.bound_bridge = bound_bridge

	-- Our light_v2 proxy: the consumer bound to binding 5001, the device
	-- Composer shows and renames [verified: API 32/_3 usage note; hardware,
	-- docs/design.md "Lights: verified on hardware": first key of the table].
	-- nil when none.
	function dev.proxy_id()
		local bound = C4:GetBoundConsumerDevices(C4:GetDeviceID(), PROXY_BINDING)
		if type(bound) ~= "table" then
			return nil
		end
		return tonumber((next(bound)))
	end

	-- A command to the bound bridge that follows a *_CHANGING notify (or ends
	-- what one began) goes through here, protected: whatever makes the call
	-- raise [assumed possible: the API documents no error and returns None,
	-- API 32/_19; a missing id returned nil silently on OS 3.4.2,
	-- docs/design.md], the handler still gets to tell the proxy CHANGED
	-- instead of ending in dispatch's error line, or a timer's, with the
	-- proxy waiting on its CHANGING (docs/code-analysis-2026-10-22.md item
	-- 15). True when the call went through; false once the error is logged,
	-- and the driver then reports the unchanged state.
	function dev.send(command, params)
		local target = get_bridge()
		local ok, err = pcall(function()
			C4:SendToDevice(target, command, params)
		end)
		if not ok then
			log.error("%s to the bridge failed: %s", command, tostring(err))
		end
		return ok
	end

	-- Driver Version and Debug Mode -----------------------------------------

	-- Director answers the version lookup with nothing at the first init of a
	-- device created by AddDevice [hardware 2026-10-24, device 1166], so the
	-- build's own stamp (common/build_version.lua, tools/build.sh) is the
	-- fallback.
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

	-- Director fills a new device's property table late: at the first init
	-- of a device created by AddDevice the replay of the properties reaches
	-- no Driver_Version handler [hardware 2026-10-24, devices 1166 and 1168],
	-- so late init writes the row itself and looks again twice while it is
	-- empty. The pending look is tracked: cancel_timers() (OnDriverDestroyed)
	-- stops it, and a late init run again starts over instead of adding a
	-- second chain.
	local version_timer = nil

	local function show_driver_version(attempt)
		if version_timer then
			version_timer:Cancel()
			version_timer = nil
		end
		local v = driver_version()
		prop("Driver Version", v)
		if v == "" and attempt < 3 then
			version_timer = C4:SetTimer(5000 * attempt, function()
				version_timer = nil
				show_driver_version(attempt + 1)
			end)
		end
	end
	dev.show_driver_version = show_driver_version

	dispatch.properties["Debug_Mode"] = function(value)
		log.set_debug(value == "On")
	end

	-- Before late init --------------------------------------------------------

	-- Director late-inits drivers in no particular order, so the bridge's
	-- messages can reach a device before its own OnDriverLateInit, where
	-- UpdateProperty and SendToProxy are not yet safe [verified: API 22/_25.2].
	-- Such messages wait, in order, and late_init() applies them.
	local late_init_done = false
	local early = {} -- bridge messages received before late init, in arrival order

	function dev.after_late_init(name, handler)
		return function(params)
			if late_init_done then
				return handler(params)
			end
			if #early >= 200 then
				log.warn("%s before late init dropped: %d already waiting", name, #early)
				return
			end
			early[#early + 1] = { name = name, handler = handler, params = params }
			log.debug("%s before late init; buffered (%d waiting)", name, #early)
		end
	end

	-- OnDriverLateInit, once the binding state is read: from here messages
	-- are handled at once, and the buffered ones are applied in order.
	function dev.late_init()
		late_init_done = true
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

	-- The bridge's link (#428) -----------------------------------------------
	-- The bridge sends HUE_BRIDGE_LINK to every Hue device once it has been
	-- unreachable, or has refused the pairing, for 5 minutes (offline, D1), at
	-- the first contact after it (online, D7), at a reason change while
	-- offline (D3), at its first evaluation of a run, and first in every hello
	-- answer, before the configure (D4; docs/offline-design.md §6.1). Each
	-- driver treats offline as one more reason it cannot be reached (D5, D6):
	-- its blocker() names link_text() and dev.on_link reports the change.
	-- dev.link is common/link.lua's parse, nil until the bridge said anything
	-- (a device of a bridge that predates #428 never hears one, and reads as
	-- online). It lives in memory only: the bridge tells a restarted device
	-- in its hello answer (E14 to E17). A driver forgets it when its bridge
	-- binding goes (dev.link = nil): another bridge's word does not carry
	-- over. The Hue Motion driver keeps and persists its own (D14) and
	-- registers its own handler after device.new, which replaces this one.

	dev.link = nil

	function dev.on_link() end

	-- True while the bridge says it is offline.
	function dev.link_offline()
		return dev.link ~= nil and dev.link.offline == true
	end

	-- §6.3's Status text ("Hue Bridge not answering since 14:02"), computed
	-- from the link's since at each call, so a refresh after midnight names
	-- the day; nil while the link is not offline.
	function dev.link_text()
		return link.text(dev.link, os.time())
	end

	-- What the device shows moves when the link goes offline, comes back, or
	-- names another reason or time while offline; an online after nothing
	-- (the first broadcast, a hello answer) or after online changes nothing.
	local function link_changed(was, told)
		if not told.offline then
			return was ~= nil and was.offline == true
		end
		return not (was and was.offline and was.reason == told.reason and was.since == told.since)
	end

	-- A state this build does not know is ignored and logged once (§6.1).
	local link_unknown_logged = false

	dispatch.commands["HUE_BRIDGE_LINK"] = dev.after_late_init("HUE_BRIDGE_LINK", function(params)
		local told = link.parse(params)
		if not told then
			if not link_unknown_logged then
				link_unknown_logged = true
				log.warn("HUE_BRIDGE_LINK with state %q ignored", tostring(type(params) == "table" and params.state))
			end
			return
		end
		local changed = link_changed(dev.link, told)
		dev.link = told
		if changed then
			if told.offline then
				log.info("offline: %s", dev.link_text())
			else
				log.info("online: the Hue Bridge answers again")
			end
		else
			log.debug("HUE_BRIDGE_LINK %s, as already known", told.offline and "offline" or "online")
		end
		dev.on_link(told, changed)
	end)

	-- OnBindingChanged before late init: the bridge's import binds a device it
	-- has just created, so Director can call it while the driver is still
	-- initialising, where UpdateProperty and SendToProxy are not yet safe
	-- [verified: API 22/_25.2; the race: docs/code-analysis-2026-10-22.md
	-- item 15]. binding_changed(handler) wraps the driver's handler: before
	-- late init the latest call per binding waits (an older one for the same
	-- binding says nothing the latest does not), and replay_bindings(), the
	-- last step of OnDriverLateInit, hands those calls over in arrival order;
	-- from late init on, calls pass straight through.
	local early_bindings = {} -- { id, handler, args, n }: the latest call per binding, in arrival order

	function dev.binding_changed(handler)
		return function(...)
			if late_init_done then
				return handler(...)
			end
			local id, _, bound, other = ...
			for i = #early_bindings, 1, -1 do
				if early_bindings[i].id == id then
					table.remove(early_bindings, i)
				end
			end
			early_bindings[#early_bindings + 1] = { id = id, handler = handler, args = { ... }, n = select("#", ...) }
			log.debug("OnBindingChanged on binding %s (%s, device %s) before late init; applied after it",
				tostring(id), bound and "bound" or "unbound", tostring(other))
		end
	end

	-- Late init has read the bridge binding itself and greeted what it found,
	-- so a waiting call that says the bridge binding is bound to that same
	-- bridge would only greet it twice: it is dropped. What late init could
	-- not see (a binding Director's lookup does not show yet, an unbind, a
	-- keypad on a Button Link) reaches the handler.
	function dev.replay_bindings()
		local queued = early_bindings
		early_bindings = {}
		for _, call in ipairs(queued) do
			local _, _, bound, other = unpack(call.args, 1, call.n)
			local known = get_bridge()
			if tonumber(call.id) == BRIDGE_BINDING and bound and known and known == tonumber(other) then
				log.debug("bridge binding to device %d from before late init: greeted already", known)
			else
				log.debug("applying OnBindingChanged on binding %s from before late init", tostring(call.id))
				local ok, err = pcall(call.handler, unpack(call.args, 1, call.n))
				if not ok then
					log.error("OnBindingChanged on binding %s from before late init failed: %s", tostring(call.id),
						tostring(err))
				end
			end
		end
	end

	-- Keypad LEDs -----------------------------------------------------------
	-- A keypad bound to a Button Link follows the device: MATCH_LED_STATE on
	-- each link, and BUTTON_INFO per button to the proxy [verified: Snap One's
	-- drivers-template-code-public c4hook_light_v2.lua, docs/keypad-design.md
	-- "Keypad LEDs"; BUTTON_INFO fields: proxy ref, BUTTON_INFO notification].
	-- The on state is the driver's (dev.is_on): nil while unknown.

	local colors = { [0] = {}, [1] = {}, [2] = {} } -- persisted overrides, nil = default
	local led_on = nil -- the on state the LEDs were last sent, nil before the first

	local function button_color(button, which)
		return colors[button][which] or COLOR_DEFAULTS[button][which]
	end

	function dev.load_colors()
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

	-- BUTTON_COLORS on a link: the colours of the button bound there, with
	-- the same four fields as BUTTON_INFO [verified: Snap One
	-- c4hook_light_v2.lua, NOTIFY.BTN_COLOR_CHANGED].
	local function send_button_colors(binding, button)
		C4:SendToProxy(binding, "BUTTON_COLORS", {
			BUTTON_ID = button,
			ON_COLOR = button_color(button, "on"),
			OFF_COLOR = button_color(button, "off"),
			CURRENT_COLOR = button_color(button, (dev.is_on() == true) and "on" or "off"),
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
	function dev.update_leds(force)
		local on = dev.is_on()
		if on == nil then
			return
		end
		on = on == true
		if force or on ~= led_on then
			send_leds(on)
		end
	end

	-- First arrivals (#429, #427, #430) ------------------------------------
	-- docs/turn-on-design.md §7.3: the first arrival of each proxy command
	-- the feature reads is logged at debug with every parameter, once per
	-- driver start, so a Debug Mode session shows the names the proxy really
	-- sends (its pages print some with spaces; D27's checks read them). A
	-- command that arrives while Debug Mode is off is not marked: the first
	-- one after Debug Mode is turned on is logged instead.

	local first_seen = {}

	function dev.first_arrival(command, params)
		if first_seen[command] or not log.enabled("debug") then
			return
		end
		first_seen[command] = true
		local parts = {}
		for k, v in pairs(params or {}) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
		table.sort(parts)
		log.debug("first %s from the proxy: %s", command, #parts > 0 and table.concat(parts, " ") or "no parameters")
	end

	-- Default rates (#430 D8) ----------------------------------------------
	-- What ON, OFF, TOGGLE, DYNAMIC_ON, DYNAMIC_OFF and a
	-- SET_BRIGHTNESS_TARGET without a RATE fade over (the colour one: a
	-- SET_COLOR_TARGET without one), in both drivers. Each is taken in
	-- 0..RATE_MAX, persisted, loaded by load_settings(), and 0 while the
	-- proxy never sent one, so those commands stay instant as before #430.
	-- Nothing is notified back: the proxy owns these values and the pages
	-- document no answer [assumed: it does not wait for one, as it does for
	-- the keypad settings below]. A Hue Scene device keeps the colour one
	-- and never uses it.

	local rate_defaults = {} -- "brightness" / "color" -> whole ms; nil while never heard

	function dev.rate_default(which)
		return rate_defaults[which] or 0
	end

	local function valid_rate(value)
		return value ~= nil and value >= 0 and value <= RATE_MAX
	end

	-- At load one out of range or not a number reads as 0 and is deleted,
	-- with one warning (L83), as a keypad setting is.
	local function load_rate_defaults()
		for _, d in ipairs(RATE_DEFAULTS) do
			local raw = C4:PersistGetValue(d.key) -- may return no value at all (#298)
			local value = tonumber(raw)
			if raw ~= nil and not valid_rate(value) then
				if value then
					log.warn("%s %s is out of range; using 0", d.key, tostring(raw))
				else
					log.warn("%s %q is not a number; using 0", d.key, tostring(raw))
				end
				C4:PersistDeleteValue(d.key)
				value = nil
			end
			rate_defaults[d.which] = value and math.floor(value + 0.5) or nil
		end
	end

	for _, d in ipairs(RATE_DEFAULTS) do
		dispatch.proxy[d.command] = function(_, params)
			dev.first_arrival(d.command, params)
			local raw = params.RATE
			local value = tonumber(raw)
			if raw == nil then
				return log.warn("%s without a value; kept %d", d.key, dev.rate_default(d.which))
			elseif not value then
				return log.warn("%s %q is not a number; kept %d", d.key, tostring(raw), dev.rate_default(d.which))
			elseif not valid_rate(value) then
				return log.warn("%s %s is out of range; kept %d", d.key, tostring(raw), dev.rate_default(d.which))
			end
			value = math.floor(value + 0.5)
			rate_defaults[d.which] = value
			C4:PersistSetValue(d.key, value)
			log.debug("%s default rate: %d ms", d.which, value)
		end
	end

	-- #430 D20: the dynamic brightness rate range [verified: LV2 caps
	-- _1-BRIGHTNESSRATEMAX.md, _1.5-BRIGHTNESSRATEMIN.md: dynamic], for one
	-- DYNAMIC_CAPABILITIES_CHANGED of its own (the driver sends it). A fresh
	-- table per call.
	function dev.rate_caps()
		return { brightness_rate_min = 0, brightness_rate_max = RATE_MAX }
	end

	-- Keypad settings (SETTINGS) -------------------------------------------
	-- Persisted per device; one never set reads as its default.

	local setting_names = opts.settings or {}
	local settings = {}

	function dev.setting(name)
		return tonumber(settings[name]) or SETTINGS[name].default
	end

	-- The proxy hears the value in use, so Composer shows what the driver
	-- does (and a later edit back to the old value is sent at all).
	local function report_setting(name)
		local value = tostring(dev.setting(name))
		log.debug("-> proxy %s %s", SETTINGS[name].notify, value)
		C4:SendToProxy(PROXY_BINDING, SETTINGS[name].notify, value)
	end

	-- A setting outside its range is never taken: a preset level of 0 would
	-- make the top button turn the light off (seen on the house, 2026-10-25,
	-- after the proxy had been told 0 by a malformed notification).
	local function in_range(name, value)
		local s = SETTINGS[name]
		return value ~= nil and value >= s.min and value <= s.max
	end

	-- At late init: the persisted values, each reported to the proxy. One out
	-- of range reads as the default and is deleted, so it is warned about once
	-- rather than at every start (Composer shows the default, so nobody has a
	-- reason to edit the field and overwrite it): since #430 D20 that includes
	-- a click or hold rate above RATE_MAX stored before #430. Then the default
	-- rates (above), which are not reported.
	function dev.load_settings()
		for _, name in ipairs(setting_names) do
			-- The extra parentheses keep one value: Director's PersistGetValue
			-- returns none at all for a key never written, and tonumber() with no
			-- argument raises (a new device failed its late init on the house, #298).
			local value = tonumber((C4:PersistGetValue(SETTINGS[name].key)))
			if value ~= nil and not in_range(name, value) then
				log.warn("%s %s is out of range; using %s", SETTINGS[name].key, tostring(value),
					tostring(SETTINGS[name].default))
				C4:PersistDeleteValue(SETTINGS[name].key)
				value = nil
			end
			settings[name] = value
			report_setting(name)
		end
		load_rate_defaults()
	end

	-- The value `raw` names when it is a number in range, else nil once the
	-- warning says what was kept.
	local function checked(name, raw)
		local value = tonumber(raw)
		if not value then
			log.warn("%s %s; kept %s", SETTINGS[name].key,
				raw == nil and "without a value" or string.format("%q is not a number", tostring(raw)),
				tostring(dev.setting(name)))
			return nil
		end
		if not in_range(name, value) then
			log.warn("%s %s is out of range; kept %s", SETTINGS[name].key, tostring(value), tostring(dev.setting(name)))
			return nil
		end
		return value
	end

	-- A value that is not a number is refused as one out of range is: the
	-- proxy hears the value kept, so Composer shows that one again rather
	-- than what was typed (#234).
	local function save_setting(name, raw)
		local value = checked(name, raw)
		if value then
			settings[name] = value
			C4:PersistSetValue(SETTINGS[name].key, value)
		end
		report_setting(name)
	end

	-- #429 D4: a value the proxy sent of its own accord (the On preset's
	-- level in UPDATE_BRIGHTNESS_PRESET) is checked, stored and persisted as
	-- a SET_* command's is, but never echoed: the proxy told us, and an echo
	-- could loop if the proxy answered every set. True when taken; refused
	-- (not a number, out of range, or no such setting), it warns, keeps the
	-- old value and sends nothing.
	function dev.take_setting(name, raw)
		if not SETTINGS[name] then
			log.warn("no keypad setting %s to take", tostring(name))
			return false
		end
		local value = checked(name, raw)
		if not value then
			return false
		end
		settings[name] = value
		C4:PersistSetValue(SETTINGS[name].key, value)
		return true
	end

	for _, name in ipairs(setting_names) do
		local s = SETTINGS[name]
		dispatch.proxy[s.command] = function(_, params) save_setting(name, params[s.param]) end
	end

	-- Keypad press, click and release ----------------------------------------
	-- A click before the hold timer fires is a tap (dev.on_click). A press
	-- still down after HOLD_AFTER_MS is a hold: top, or toggle while off, dims
	-- up; bottom, or toggle while on, down; down from off does nothing.
	-- dev.on_hold gets the direction and the on state and keeps a timer it
	-- arms for the hold in h.timer, cancelled when the press ends (for any
	-- reason; dev.on_end_hold hears each end). The release, or a
	-- release-as-click, of a hold calls dev.on_finish and ignores a click on
	-- that button for CLICK_GUARD_MS (some keypads send one).
	--
	-- Each press is judged as it arrives, and its click follows the verdict
	-- (#421, docs/tap-stop-design.md §3 and §4.1):
	--   * The double-tap window (#421 D4). A press within DOUBLE_TAP_MS of the
	--     previous press on the same button, by the controller's clock, is
	--     part of a double or triple tap: the keypad's own event, for its
	--     programming. Its record is marked multi: it starts and stops nothing
	--     (a running ramp goes on) and its click is swallowed. The window is
	--     per button and runs press to press, so a third tap is measured from
	--     the second. A press that became a hold opens no window: a hold is no
	--     tap.
	--   * The stop (#421 D5). Otherwise, while dev.ramp_active(), the press
	--     calls dev.on_ramp_stop(button) at once, on the push as the keypad
	--     link page advises where hold versus click does not matter
	--     [verified: keypad proxy reference, Button Link bindings, DO_PUSH],
	--     and is marked stopped: its click is swallowed. Any button stops,
	--     the other one and the toggle too; the light does not reverse. A stop
	--     is no hold release, so it arms no guard.
	--   * Either way the hold timer then starts as before: a multi or stopped
	--     press held past HOLD_AFTER_MS becomes a hold, and a stopped one
	--     holds from the level the stop applied.
	-- A click finds its press as the live record, or as the one a release
	-- ended before its hold time (PUSH, RELEASE, CLICK). A click with neither
	-- (a route that sends only the click) is judged at the click by the same
	-- two rules, and counts as that button's press for the window. The hold's
	-- release-as-click and the guard come first, as before. On the proxy
	-- route every action is echoed before it gets here, a swallowed one too.
	--
	-- The drivers' own copies (until #57) also differed in the settings
	-- (opts.settings), one debug line's word (opts.noun), and the guard, armed
	-- before the light's stop but after the scene's. That order is observable
	-- only for a click that lands between two timers due at the same moment
	-- (the scene's guard and its level window are both 1000 ms); it is armed
	-- first, so a failing hook still leaves the keypad's click ignored. The on state a
	-- hold starts from (st.on == true, effective_on()) is dev.is_on() == true.

	local noun = opts.noun or "device"
	local hold = nil  -- { button, timer, held, multi, stopped, ... } while a button is down; hooks add fields
	local guard = nil -- { button, timer } for CLICK_GUARD_MS after a hold's release
	local released = nil  -- the press a release ended before its hold time, while its click may follow
	local last_press = {} -- button -> controller ms of its last press that opens a window (#421 D4)

	function dev.on_end_hold() end

	-- Hue Scene devices keep these: no ramp to stop, only the window (#421 D1).
	function dev.ramp_active() return false end
	function dev.on_ramp_stop() end

	-- True while `h` is the press in progress: no release, click or new press since.
	function dev.holding(h)
		return hold == h
	end

	-- The light's own button events (#432, docs/light-events-design.md §3.1).
	-- They are sent beside the machine, never in place of a decision (D8):
	-- every press that reaches the device fires its events, whatever the
	-- device then does with it, a swallowed or dropped one too (D3). Two
	-- records per button:
	--   down[button] = { held }  from a push the proxy heard (notified on a
	--                            Button Link, or echoed on its own route) to
	--                            its release (D4, D5); held once the hold
	--                            timer made that press a hold
	--   taps[button] = { count, timer, press, added }  the open tap sequence
	--                            (D6): the presses counted (at most MAX_TAPS),
	--                            the timer that closes it DOUBLE_TAP_MS after
	--                            its last press, that press's record, and
	--                            whether that press added one
	local down = {}
	local taps = {}

	-- D6, D7: the sequence on `button` ends; a count of 1 or more tells the
	-- proxy, by the mode.
	local function close_taps(button)
		local seq = taps[button]
		if not seq then
			return
		end
		taps[button] = nil
		if seq.timer then
			seq.timer:Cancel()
			seq.timer = nil
		end
		if seq.count < 1 then
			return
		end
		if device.BUTTON_EVENTS_MODE == "action" then
			notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = ACT_PRESS + seq.count })
		else
			notify("CLICK_COUNT", { BUTTON_ID = button, COUNT = seq.count })
		end
	end

	-- D6: a press judge() saw, after its window verdict. Outside the window it
	-- closes the button's open sequence and starts one at 1; inside, it adds
	-- one, up to MAX_TAPS. Either way the window's end, DOUBLE_TAP_MS after
	-- this press (the same window judge() measures), closes the sequence.
	local function count_tap(h)
		local button = h.button
		local seq = taps[button]
		if seq and not h.multi then
			close_taps(button)
			seq = nil
		end
		if not seq then
			seq = { count = 0 }
			taps[button] = seq
		end
		seq.press = h
		seq.added = seq.count < MAX_TAPS
		if seq.added then
			seq.count = seq.count + 1
		end
		if seq.timer then
			seq.timer:Cancel()
		end
		seq.timer = C4:SetTimer(DOUBLE_TAP_MS, function()
			if taps[button] ~= seq then
				return
			end
			seq.timer = nil
			-- D6: a sequence never closes while its last press is undecided.
			-- On the controller that cannot happen (the hold timer, armed at
			-- the same press, is due HOLD_AFTER_MS < DOUBLE_TAP_MS after it),
			-- only when timers run out of order (the specs' fire_timers): the
			-- hold, when it comes, closes the sequence (uncount_tap).
			if hold == seq.press and not seq.press.held then
				return
			end
			close_taps(button)
		end)
	end

	-- D6: the press `h` became a hold. It takes back its count (when it
	-- added one) and the button's sequence closes at once with the taps
	-- before it.
	local function uncount_tap(h)
		local seq = taps[h.button]
		if not seq then
			return
		end
		if seq.press == h and seq.added then
			seq.count = seq.count - 1
		end
		close_taps(h.button)
	end

	local function end_hold()
		if hold and hold.timer then
			hold.timer:Cancel()
		end
		if hold then
			dev.on_end_hold(hold)
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

	-- #421 D4 and D5 for a press, or for a click with no press on record:
	-- within the window of the button's previous press it is multi; else,
	-- while a ramp runs, it stops the ramp and is stopped. Its time is the
	-- button's last press either way.
	local function judge(h)
		local now = now_ms()
		local prev = last_press[h.button]
		last_press[h.button] = now
		if prev and now >= prev and now - prev < DOUBLE_TAP_MS then
			h.multi = true
			log.debug("button %d %d ms after its last press: part of a double tap", h.button, now - prev)
		elseif dev.ramp_active() then
			h.stopped = true
			log.debug("button %d stops the ramp", h.button)
		end
		-- #432 D6, D8: the press counts beside the verdict, before the stop
		-- runs, so a tap that stops a ramp is a tap and a stop that fails
		-- still counts (D3).
		count_tap(h)
		if h.stopped then
			dev.on_ramp_stop(h.button)
		end
	end

	-- The hold timer fired with the button still down. A hold is no tap: the
	-- next press on the button opens a window of its own (#421 D4).
	local function start_hold(h)
		h.held = true
		last_press[h.button] = nil
		uncount_tap(h) -- #432 D6
		if down[h.button] then
			down[h.button].held = true -- #432 D4: its release notifies 0
		end
		local on = dev.is_on() == true
		local up = h.button == BUTTON_TOP or (h.button ~= BUTTON_BOTTOM and not on)
		if not up and not on then
			return log.debug("hold: dimming down a %s that is off does nothing", noun)
		end
		dev.on_hold(h, up, on)
	end

	local function finish_hold()
		local h = hold
		end_hold()
		arm_guard(h.button)
		dev.on_finish(h)
	end

	-- A hold from off: once dev.on_hold has turned the device on at 1 %, the
	-- dim up follows DIM_AFTER_ON_MS later, while the button is still down and
	-- the device is still bound with a Hue resource.
	function dev.dim_after_on(h, dim_up)
		h.timer = C4:SetTimer(DIM_AFTER_ON_MS, function()
			if hold ~= h then
				return
			end
			h.timer = nil
			if get_bridge() and get_rid() then
				dim_up()
			end
		end)
	end

	-- The routes below end here (a spec may put its own in place).
	function dev.button_action(button, action)
		if action == ACT_PRESS then
			end_hold()
			released = nil
			-- The record is the press in progress before the stop runs, so a
			-- stop that fails (logged by dispatch) still swallows the click.
			local h = { button = button }
			hold = h
			judge(h)
			h.timer = C4:SetTimer(HOLD_AFTER_MS, function()
				if hold == h then
					h.timer = nil
					start_hold(h)
				end
			end)
		elseif action == ACT_CLICK then
			if hold and hold.held then
				finish_hold()
			elseif guard and guard.button == button then
				end_hold()
				released = nil
				log.debug("click on button %d right after a hold ignored", button)
			else
				local h = (hold and hold.button == button and hold)
					or (released and released.button == button and released) or nil
				end_hold()
				released = nil
				if not h then
					h = { button = button }
					judge(h)
				end
				if h.multi then
					log.debug("click on button %d is part of a double tap: ignored", button)
				elseif h.stopped then
					log.debug("click on button %d stopped the ramp: swallowed", button)
				else
					dev.on_click(button)
				end
			end
		elseif action == ACT_RELEASE then
			-- Release after a hold: finish it; a release that follows a click
			-- has nothing left to do; one before the hold time ends the press,
			-- whose click may still follow (PUSH, RELEASE, CLICK).
			if hold and hold.held then
				finish_hold()
			else
				released = hold
				end_hold()
			end
		end
	end

	-- Keypad buttons --------------------------------------------------------
	-- The proxy's own route (BUTTON_ACTION on the proxy binding) carries the
	-- button in the parameters and wants every action echoed [verified:
	-- proxy-protocol reference, light_v2 BUTTON_ACTION command and
	-- notification]; a keypad button bound to one of the driver's Button Link
	-- connections (200 top, 201 bottom, 202 toggle) delivers DO_PUSH,
	-- DO_RELEASE and DO_CLICK on that binding [verified: public light_v2
	-- drivers]. Both end in the machine above, dev.button_action.

	local function link_button(binding, command)
		local button = LINK_BUTTON[tonumber(binding)]
		if not button then
			log.warn("%s on binding %s: not a Button Link", command, tostring(binding))
		end
		return button
	end
	dev.link_button = link_button

	-- #432 D4: a Button Link press tells the proxy what the proxy's own route
	-- would echo, so the proxy hears one sequence from both routes and can
	-- fire the device's Press and Release (F4, F10). A push on a button still
	-- down first sends the release it never had (a lost DO_RELEASE, L47): after
	-- a push the proxy wants a release, or later pushes fail [verified: LV2
	-- notif _1-BUTTONACTION.md].
	local function notify_press(button)
		if down[button] then
			notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = ACT_RELEASE })
		end
		down[button] = { held = false }
		notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = ACT_PRESS })
	end

	-- #432 D4, D7: exactly one release per notified push: 2 when the press
	-- ends as a click, 0 after a hold (in mode "action", 0 either way). A
	-- button not down sends nothing: the keypad's click after a hold's
	-- release (the guard ignores it), or the click after PUSH, RELEASE. The
	-- held test is the down record's, which start_hold marks: §6.3's `hold and
	-- hold.button == button and hold.held`, also for a hold that another
	-- button's press ended before this release.
	local function notify_release(button)
		local d = down[button]
		if not d then
			return
		end
		down[button] = nil
		local action = ACT_CLICK
		if d.held or device.BUTTON_EVENTS_MODE == "action" then
			action = ACT_RELEASE
		end
		notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = action })
	end

	dispatch.proxy["BUTTON_ACTION"] = function(_, params)
		local button, action = tonumber(params.BUTTON_ID), tonumber(params.ACTION)
		if not button or not action then
			return log.warn("BUTTON_ACTION without BUTTON_ID/ACTION")
		end
		notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = action })
		-- #432 D5: the echo, unchanged, keeps the down mark, so a Button Link
		-- press after it stays consistent.
		if action == ACT_PRESS then
			down[button] = { held = false }
		elseif action == ACT_RELEASE or action == ACT_CLICK then
			down[button] = nil
		end
		dev.button_action(button, action)
	end

	-- #432 §3.1: each link command notifies before the machine runs, so the
	-- held test reads the press as it was.
	dispatch.proxy["DO_PUSH"] = function(binding)
		local button = link_button(binding, "DO_PUSH")
		if button then
			notify_press(button)
			dev.button_action(button, ACT_PRESS)
		end
	end

	dispatch.proxy["DO_RELEASE"] = function(binding)
		local button = link_button(binding, "DO_RELEASE")
		if button then
			notify_release(button)
			dev.button_action(button, ACT_RELEASE)
		end
	end

	dispatch.proxy["DO_CLICK"] = function(binding)
		local button = link_button(binding, "DO_CLICK")
		if button then
			notify_release(button)
			dev.button_action(button, ACT_CLICK)
		end
	end

	-- A keypad on a link asks for its button's colours and the LED state.
	dispatch.proxy["REQUEST_BUTTON_COLORS"] = function(binding)
		local button = link_button(binding, "REQUEST_BUTTON_COLORS")
		if not button then
			return
		end
		send_button_colors(tonumber(binding), button)
		C4:SendToProxy(tonumber(binding), "MATCH_LED_STATE", { STATE = dev.is_on() == true }, "COMMAND")
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
		send_button_info(button, dev.is_on() == true)
	end

	-- #432 D11: the proxy sets every button's LED colour, on and off, to one
	-- colour: COLOR, a 6-digit hex RGB string [verified: LV2 cmds
	-- _13-SET_ALL_LED.md]. The six colours are stored and persisted under
	-- SET_BUTTON_COLOR's keys, so a Director restart keeps them and a later
	-- SET_BUTTON_COLOR changes single ones again (L51). Then each link hears
	-- its button's colours, the proxy each button's BUTTON_INFO, and, while
	-- the on state is known, each link MATCH_LED_STATE. A COLOR that is
	-- missing or not 6-digit hex changes nothing: a warning, and the colours
	-- kept go to the proxy again, so Composer shows the truth. Whatever the
	-- device's state (unbound, offline, forgotten).
	dispatch.proxy["SET_ALL_LED"] = function(_, params)
		dev.first_arrival("SET_ALL_LED", params)
		local color = valid_color(params.COLOR)
		local on = dev.is_on()
		if not color then
			if params.COLOR == nil then
				log.warn("SET_ALL_LED without a COLOR; the LED colours are kept")
			else
				log.warn("SET_ALL_LED: COLOR %q is not a 6-digit hex colour; the LED colours are kept",
					tostring(params.COLOR))
			end
			for button = 0, 2 do
				send_button_info(button, on == true)
			end
			return
		end
		for button = 0, 2 do
			for _, which in ipairs({ "on", "off" }) do
				colors[button][which] = color
				C4:PersistSetValue(color_key(button, which), color)
			end
		end
		for button = 0, 2 do
			send_button_colors(BUTTON_LINK[button], button)
		end
		for button = 0, 2 do
			send_button_info(button, on == true)
		end
		if on ~= nil then
			led_on = on == true
			for _, binding in ipairs(LINK_BINDINGS) do
				C4:SendToProxy(binding, "MATCH_LED_STATE", { STATE = led_on }, "COMMAND")
			end
		end
	end

	-- Binding re-check ------------------------------------------------------
	-- After a Director restart the binding to the bridge can be invisible to
	-- GetBoundProviderDevice at late init although Composer shows it, and no
	-- OnBindingChanged follows, so the device read "Not bound to a Hue Bridge"
	-- until something else woke it [hardware 2026-10-22, docs/keypad-design.md].
	-- While unbound it looks again a few times (RECHECK_MS), then gives up
	-- quietly; a binding event or a bridge found ends the retries.

	local recheck_timer = nil

	function dev.cancel_recheck()
		if recheck_timer then
			recheck_timer:Cancel()
			recheck_timer = nil
		end
	end

	local function schedule_recheck(attempt)
		dev.cancel_recheck()
		local delay = RECHECK_MS[attempt]
		if not delay then
			return log.info("still not bound to a Hue Bridge %d s after start; waiting for a binding", 60)
		end
		recheck_timer = C4:SetTimer(delay, function()
			recheck_timer = nil
			if get_bridge() then
				return
			end
			local found = bound_bridge()
			if found then
				log.info("bridge binding visible after %d checks; greeting device %d", attempt, found)
				dev.on_bridge_found()
			else
				schedule_recheck(attempt + 1)
			end
		end)
	end
	dev.schedule_recheck = schedule_recheck

	-- OnDriverDestroyed: the timers this module arms (a keypad press and its
	-- hold, the click guard, the Driver Version looks and the binding
	-- re-check) stop with the driver. Harmless on the controller, where the
	-- Lua state goes with the device, but after a dev-loop reload a stray look
	-- would still write the row (docs/reviews/slim-device-drivers.md §4
	-- question 5).
	--
	-- #432 D6, E9: open tap sequences go too, unsent, and each button still
	-- down gets its release (0), so the proxy is not left refusing pushes
	-- after a driver update in the middle of a press; the new code starts
	-- with nothing down. That a notify sent from OnDriverDestroyed still
	-- reaches the proxy is [assumed].
	function dev.cancel_timers()
		end_hold()
		disarm_guard()
		if version_timer then
			version_timer:Cancel()
			version_timer = nil
		end
		dev.cancel_recheck()
		for _, seq in pairs(taps) do
			if seq.timer then
				seq.timer:Cancel()
			end
		end
		taps = {}
		local buttons = {}
		for button in pairs(down) do
			buttons[#buttons + 1] = button
		end
		table.sort(buttons)
		down = {}
		for _, button in ipairs(buttons) do
			notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = ACT_RELEASE })
		end
	end

	-- Composer delete -------------------------------------------------------

	-- OnDriverRemovedFromProject: tell the bridge (`command` is the driver's
	-- goodbye message), so it tombstones the entry instead of fanning state
	-- out to a dead id [verified: API 22/_26; that SendToDevice still works
	-- here is assumed, docs/import-design.md probe 2].
	function dev.goodbye(command)
		local target = get_bridge()
		if not target then
			return
		end
		local ok, err = pcall(function()
			C4:SendToDevice(target, command, { rid = get_rid(), device_id = device_id() })
		end)
		if ok then
			log.debug("%s sent to bridge %d", command, target)
		else
			log.warn("%s failed: %s", command, tostring(err))
		end
	end

	return dev
end

return device
