-- The plumbing the Hue Light and Hue Scene drivers share around their
-- light_v2 proxy and their bridge binding: properties and proxy notifies, the
-- bridge and proxy lookups, the Driver Version row, the buffer for bridge
-- messages that arrive before late init, the keypad Button Links with their
-- LEDs and button colours, the binding re-check after a Director restart, the
-- goodbye on a Composer delete, and the dev-build pieces (log forwarding,
-- DEV_RELOAD) that common/devloop.lua carries. Until 2026-10-24 each driver
-- had its own byte-identical copy of every block here
-- (docs/reviews/slim-device-drivers.md, #5 Stage A); the code is that copy,
-- and both drivers' specs pin it end to end. What the two drivers do
-- differently (the hold machine, the targets, the identity texts) stays in
-- the drivers and reaches this module through three hooks.
--
-- No module-level state: device.new() returns one instance per driver.
--
--   local dev = device.new({
--       prefix = "Hue Light",   -- the log prefix; the dev-build forwarding knows its own lines by it
--       tree = "light",         -- the dev loop's name for this driver's source tree (DEV_RELOAD)
--       bridge = function() return bridge end,  -- device id of the bound Hue Bridge driver, or nil
--       rid = function() return st.rid end,     -- the device's Hue resource id, or nil
--   })
--
-- Hooks the driver assigns once the functions they call exist (they are read
-- when something arrives, never at load):
--   dev.is_on()                        nil while the on state is unknown, else whether
--                                      the device shows on: what the keypad LEDs follow
--   dev.button_action(button, action)  the driver's press / click / release machine,
--                                      fed from BUTTON_ACTION and the Button Links
--   dev.on_bridge_found()              the re-check found the bridge: greet it and report online
--
-- The instance: devloop (the module; nil in release builds), flush_log(),
-- prop(), notify(), device_id(), result(), bound_bridge(), proxy_id(),
-- send(), after_late_init(), late_init(), binding_changed(),
-- replay_bindings(), show_driver_version(), load_colors(), update_leds(),
-- link_button(), schedule_recheck(), cancel_recheck(), cancel_timers() and
-- goodbye(). It registers the Driver_Version and Debug_Mode property
-- handlers, the proxy's BUTTON_ACTION, DO_PUSH, DO_RELEASE, DO_CLICK,
-- REQUEST_BUTTON_COLORS and SET_BUTTON_COLOR, and DEV_RELOAD in dev builds.
--
-- OnDriverLateInit in both drivers: read the binding (bound_bridge), then
-- late_init() (the buffered bridge messages), greet, and replay_bindings()
-- last; OnDriverDestroyed calls cancel_timers().

local log = require("common.log")
local dispatch = require("common.dispatch")

local device = {}

-- Binding IDs, the same in both driver.xml: the light_v2 proxy on 5001, the
-- Hue Bridge consumer connection on 1.
device.PROXY_BINDING = 5001
device.BRIDGE_BINDING = 1
local PROXY_BINDING, BRIDGE_BINDING = device.PROXY_BINDING, device.BRIDGE_BINDING

-- BUTTON_ACTION's actions: 1 press, 2 release as a click, 0 release after a
-- hold [verified: proxy-protocol reference, light_v2 BUTTON_ACTION].
device.ACT_RELEASE, device.ACT_PRESS, device.ACT_CLICK = 0, 1, 2

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

	-- Keypad buttons --------------------------------------------------------
	-- The proxy's own route (BUTTON_ACTION on the proxy binding) carries the
	-- button in the parameters and wants every action echoed [verified:
	-- proxy-protocol reference, light_v2 BUTTON_ACTION command and
	-- notification]; a keypad button bound to one of the driver's Button Link
	-- connections (200 top, 201 bottom, 202 toggle) delivers DO_PUSH,
	-- DO_RELEASE and DO_CLICK on that binding [verified: public light_v2
	-- drivers]. Both end in the driver's machine, dev.button_action.

	local function link_button(binding, command)
		local button = LINK_BUTTON[tonumber(binding)]
		if not button then
			log.warn("%s on binding %s: not a Button Link", command, tostring(binding))
		end
		return button
	end
	dev.link_button = link_button

	dispatch.proxy["BUTTON_ACTION"] = function(_, params)
		local button, action = tonumber(params.BUTTON_ID), tonumber(params.ACTION)
		if not button or not action then
			return log.warn("BUTTON_ACTION without BUTTON_ID/ACTION")
		end
		notify("BUTTON_ACTION", { BUTTON_ID = button, ACTION = action })
		dev.button_action(button, action)
	end

	dispatch.proxy["DO_PUSH"] = function(binding)
		local button = link_button(binding, "DO_PUSH")
		if button then dev.button_action(button, device.ACT_PRESS) end
	end

	dispatch.proxy["DO_RELEASE"] = function(binding)
		local button = link_button(binding, "DO_RELEASE")
		if button then dev.button_action(button, device.ACT_RELEASE) end
	end

	dispatch.proxy["DO_CLICK"] = function(binding)
		local button = link_button(binding, "DO_CLICK")
		if button then dev.button_action(button, device.ACT_CLICK) end
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

	-- OnDriverDestroyed: the timers this module arms (the Driver Version looks
	-- and the binding re-check) stop with the driver. Harmless on the
	-- controller, where the Lua state goes with the device, but after a
	-- dev-loop reload a stray look would still write the row
	-- (docs/reviews/slim-device-drivers.md §4 question 5).
	function dev.cancel_timers()
		if version_timer then
			version_timer:Cancel()
			version_timer = nil
		end
		dev.cancel_recheck()
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
