-- common.device: the plumbing the Hue Light and Hue Scene drivers share,
-- on the fake runtime by itself. The two drivers' specs pin every block end
-- to end; this one pins the module's own contract: the three hooks, the
-- handlers it registers, and what each block does with the runtime.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local function quiet()
	log.sink = function() end
end

-- Every line the logger emits from here on.
local function capture_log()
	local lines = {}
	log.sink = function(line) lines[#lines + 1] = line end
	return lines
end

-- A fresh instance on a fresh runtime: common.device and common.dispatch
-- reloaded, so the handlers it registers land in this test's dispatch. The
-- hooks answer from `st`, which a test changes as the driver would.
local function new_device(opts)
	opts = opts or {}
	package.loaded["common.device"] = nil
	package.loaded["common.dispatch"] = nil
	local c4, env = fake.install_c4({ ["Debug Mode"] = "Off", ["Driver Version"] = "" })
	local device = require("common.device")
	local dispatch = require("common.dispatch")
	local st = { bridge = 15, rid = "r1", on = nil, buttons = {}, found = 0 }
	local dev = device.new({
		prefix = opts.prefix or "Hue Test",
		tree = opts.tree or "light",
		bridge = function() return st.bridge end,
		rid = function() return st.rid end,
	})
	dev.is_on = function() return st.on end
	dev.button_action = function(button, action) st.buttons[#st.buttons + 1] = { button, action } end
	dev.on_bridge_found = function() st.found = st.found + 1 end
	return dev, c4, env, dispatch, st, device
end

-- Every SendToProxy with that command, as { binding, params }.
local function proxied(c4, command)
	local out = {}
	for _, args in ipairs(c4.calls_to("SendToProxy")) do
		if args[2] == command then out[#out + 1] = { args[1], args[3] } end
	end
	return out
end

local function delays(c4)
	local out = {}
	for _, timer in ipairs(c4.active_timers()) do out[#out + 1] = timer.delay end
	table.sort(out)
	return out
end

describe("common.device", function()
	before_each(quiet)
	after_each(function()
		log.set_debug(false)
		log.set_prefix(nil)
	end)

	describe("construction", function()
		it("sets the log prefix and, with the dev loop present, forwards logs and takes DEV_RELOAD", function()
			local dev, _, _, dispatch = new_device()
			local lines = capture_log()
			log.warn("hello")
			assert.same({ "[WARN] Hue Test: hello" }, lines)
			assert.equal(require("common.devloop"), dev.devloop)
			assert.is_function(dev.flush_log)
			assert.is_function(dispatch.commands["DEV_RELOAD"])
		end)

		it("in a release build (no dev loop module) leaves log.sink alone and registers no DEV_RELOAD", function()
			local sink = function() end
			log.sink = sink
			local real = package.loaded["common.devloop"]
			package.loaded["common.devloop"] = nil
			package.preload["common.devloop"] = function() error("module 'common.devloop' not found: release build") end
			local ok, err = pcall(function()
				local dev, _, _, dispatch = new_device()
				assert.is_nil(dev.devloop)
				assert.equal(sink, log.sink)
				assert.is_nil(dispatch.commands["DEV_RELOAD"])
				assert.has_no.errors(dev.flush_log)
			end)
			package.preload["common.devloop"] = nil
			package.loaded["common.devloop"] = real
			assert(ok, err)
		end)

		it("says so through print when the dev loop fails to load for another reason", function()
			local printed = {}
			local real_print = print
			local real = package.loaded["common.devloop"]
			package.loaded["common.devloop"] = nil
			package.preload["common.devloop"] = function() error("boom") end
			_G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
			local ok, err = pcall(function()
				local dev = new_device()
				assert.is_nil(dev.devloop)
				assert.equal(1, #printed)
				assert.truthy(printed[1]:find("^%[ERROR%] Hue Test: dev loop failed to load: .*boom"))
			end)
			_G.print = real_print
			package.preload["common.devloop"] = nil
			package.loaded["common.devloop"] = real
			assert(ok, err)
		end)
	end)

	describe("properties and notifies", function()
		it("prop writes strings, an empty one for nil", function()
			local dev, _, env = new_device()
			dev.prop("Status", 5)
			dev.prop("Online", nil)
			assert.equal("5", env.Properties["Status"])
			assert.equal("", env.Properties["Online"])
		end)

		it("notify sends to the proxy binding and dumps the parameters only in Debug Mode", function()
			local dev, c4 = new_device()
			local lines = capture_log()
			dev.notify("LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 40 })
			assert.same({ { 5001, { LIGHT_BRIGHTNESS_CURRENT = 40 } } }, proxied(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.same({}, lines, "nothing built for a line nobody sees")
			log.set_debug(true)
			dev.notify("LIGHT_BRIGHTNESS_CHANGING", { RATE = 0, LIGHT_BRIGHTNESS_TARGET = 75, LIGHT_BRIGHTNESS_CURRENT = 40 })
			assert.same({ "[DEBUG] Hue Test: -> proxy LIGHT_BRIGHTNESS_CHANGING"
				.. " LIGHT_BRIGHTNESS_CURRENT=40 LIGHT_BRIGHTNESS_TARGET=75 RATE=0" }, lines, "sorted keys")
			dev.notify("SYNC", nil)
			assert.equal("[DEBUG] Hue Test: -> proxy SYNC ", lines[2])
		end)

		it("device_id is a string, result logs always and fills Last Action", function()
			local dev, _, env = new_device()
			assert.equal("15", dev.device_id())
			local lines = capture_log()
			dev.result("Renamed device 7 to Desk")
			assert.same({ "Hue Test: Renamed device 7 to Desk" }, lines)
			assert.equal("Renamed device 7 to Desk", fake.last_action(env))
		end)
	end)

	describe("bridge and proxy lookups", function()
		it("bound_bridge takes a table of id/name pairs or a number, and 0 or nil as unbound", function()
			local dev, c4 = new_device()
			c4.GetBoundProviderDevice = function() return { [15] = "Hue Bridge" } end
			assert.equal(15, dev.bound_bridge())
			c4.GetBoundProviderDevice = function() return 16 end
			assert.equal(16, dev.bound_bridge())
			c4.GetBoundProviderDevice = function() return "17" end
			assert.equal(17, dev.bound_bridge())
			c4.GetBoundProviderDevice = function() return 0 end
			assert.is_nil(dev.bound_bridge(), "OS 3.4.2 with nothing bound")
			c4.GetBoundProviderDevice = function() return nil end
			assert.is_nil(dev.bound_bridge())
		end)

		it("proxy_id is the first consumer on 5001, nil without one", function()
			local dev, c4 = new_device()
			c4.GetBoundConsumerDevices = function(_, id, binding)
				assert.equal(15, id)
				assert.equal(5001, binding)
				return { [3001] = "Hue Light" }
			end
			assert.equal(3001, dev.proxy_id())
			c4.GetBoundConsumerDevices = function() return nil end
			assert.is_nil(dev.proxy_id())
		end)
	end)

	describe("Driver Version and Debug Mode", function()
		it("Driver_Version writes Director's version; show_driver_version looks again twice while it is empty", function()
			local dev, c4, env, dispatch = new_device()
			dispatch.property_changed("Driver Version", "")
			assert.equal("1", env.Properties["Driver Version"])
			c4.config_info.version = ""
			dev.show_driver_version(1)
			assert.equal("", env.Properties["Driver Version"])
			assert.same({ 5000 }, delays(c4))
			c4.fire_timers()
			assert.same({ 10000 }, delays(c4))
			c4.config_info.version = "7"
			c4.fire_timers()
			assert.equal("7", env.Properties["Driver Version"])
			assert.same({}, delays(c4), "found: no third look")
		end)

		it("gives up after the third look and falls back to the build's own stamp", function()
			local dev, c4, env = new_device()
			c4.config_info.version = ""
			dev.show_driver_version(1)
			c4.fire_timers()
			c4.fire_timers()
			assert.same({}, delays(c4))
			assert.equal("", env.Properties["Driver Version"])

			package.preload["common.build_version"] = function() return "196" end
			package.loaded["common.build_version"] = nil
			local ok, err = pcall(function()
				local dev2, c42, env2 = new_device()
				c42.config_info.version = ""
				dev2.show_driver_version(1)
				assert.equal("196", env2.Properties["Driver Version"])
				assert.same({}, delays(c42))
			end)
			package.preload["common.build_version"] = nil
			package.loaded["common.build_version"] = nil
			assert(ok, err)
		end)

		it("a second show_driver_version starts over: one look pending, never two chains", function()
			local dev, c4 = new_device()
			c4.config_info.version = ""
			dev.show_driver_version(1)
			c4.fire_timers()
			assert.same({ 10000 }, delays(c4))
			dev.show_driver_version(1) -- late init run again
			assert.same({ 5000 }, delays(c4), "the pending look was replaced")
		end)

		it("cancel_timers stops the pending look and the binding re-check (OnDriverDestroyed)", function()
			local dev, c4, env, _, st = new_device()
			c4.config_info.version = ""
			dev.show_driver_version(1)
			st.bridge = nil
			dev.schedule_recheck(1)
			assert.same({ 5000, 5000 }, delays(c4))
			dev.cancel_timers()
			assert.same({}, delays(c4))
			c4.config_info.version = "7"
			assert.equal(0, c4.fire_timers())
			assert.equal("", env.Properties["Driver Version"], "no stray write after the destroy")
			assert.has_no.errors(dev.cancel_timers, "nothing pending is fine")
		end)

		it("Debug_Mode On enables debug lines, anything else keeps them off", function()
			local _, _, _, dispatch = new_device()
			dispatch.property_changed("Debug Mode", "On")
			assert.is_true(log.enabled("debug"))
			dispatch.property_changed("Debug Mode", "Off")
			assert.is_false(log.enabled("debug"))
		end)
	end)

	describe("before late init", function()
		it("after_late_init buffers in order until late_init applies them, then passes straight through", function()
			local dev = new_device()
			local seen = {}
			local a = dev.after_late_init("A", function(params) seen[#seen + 1] = "A:" .. params.n end)
			local b = dev.after_late_init("B", function(params) seen[#seen + 1] = "B:" .. params.n end)
			a({ n = "1" })
			b({ n = "2" })
			a({ n = "3" })
			assert.same({}, seen)
			dev.late_init()
			assert.same({ "A:1", "B:2", "A:3" }, seen)
			assert.equal("done", a({ n = "4" }) or "done")
			assert.same({ "A:1", "B:2", "A:3", "A:4" }, seen)
		end)

		it("a buffered handler that fails is logged and does not stop the rest", function()
			local dev = new_device()
			local lines = capture_log()
			local seen = {}
			dev.after_late_init("BAD", function() error("boom") end)({})
			dev.after_late_init("GOOD", function() seen[#seen + 1] = "good" end)({})
			dev.late_init()
			assert.same({ "good" }, seen)
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("^%[ERROR%] Hue Test: buffered BAD failed: .*boom"))
		end)
	end)

	-- docs/review-leftovers-design.md #49: OnBindingChanged acts only after
	-- late init; an earlier call waits and is replayed once late init has run.
	describe("binding changes before late init", function()
		-- A handler through binding_changed that records every call it gets.
		local function recorder(dev)
			local seen = {}
			local handler = dev.binding_changed(function(id, class, bound, other, other_binding)
				seen[#seen + 1] = { id, class, bound, other, other_binding }
			end)
			return handler, seen
		end

		it("wait until replay_bindings, the latest call per binding in arrival order, then pass straight through", function()
			local dev, c4 = new_device()
			local handler, seen = recorder(dev)
			c4.calls = {}
			handler(200, "BUTTON_LINK", true, 77, 1)
			handler(1, "HUE_BRIDGE", true, 16, 1)
			handler(200, "BUTTON_LINK", false, 77, 1)
			assert.same({}, seen)
			assert.same({}, c4.calls, "nothing touches Director before late init")
			dev.late_init()
			assert.same({}, seen, "late_init applies the bridge's messages only; the driver greets first")
			dev.replay_bindings()
			assert.same({ { 1, "HUE_BRIDGE", true, 16, 1 }, { 200, "BUTTON_LINK", false, 77, 1 } }, seen,
				"one call per binding, the latest; the older one for 200 says nothing the latest does not")
			handler(201, "BUTTON_LINK", true, 78, 1)
			assert.same({ 201, "BUTTON_LINK", true, 78, 1 }, seen[3], "after late init: at once")
			dev.replay_bindings()
			assert.equal(3, #seen, "nothing is replayed twice")
		end)

		it("drop a bridge binding bound to the bridge late init found, which it has greeted already", function()
			local dev = new_device() -- its bridge is 15: what late init's lookup found
			local handler, seen = recorder(dev)
			handler(1, "HUE_BRIDGE", true, 15, 1)
			dev.late_init()
			dev.replay_bindings()
			assert.same({}, seen)

			-- Late init's lookup did not show the binding yet: the call is what says it.
			local lagging, _, _, _, st = new_device()
			handler, seen = recorder(lagging)
			st.bridge = nil
			handler(1, "HUE_BRIDGE", true, 15, 1)
			lagging.late_init()
			lagging.replay_bindings()
			assert.same({ { 1, "HUE_BRIDGE", true, 15, 1 } }, seen)

			-- An unbind, and a binding to another bridge, are replayed too.
			for _, call in ipairs({ { 1, "HUE_BRIDGE", false, 15, 1 }, { 1, "HUE_BRIDGE", true, 16, 1 } }) do
				dev = new_device()
				handler, seen = recorder(dev)
				handler(unpack(call))
				dev.late_init()
				dev.replay_bindings()
				assert.same({ call }, seen)
			end
		end)

		it("a replayed call that fails is logged and does not stop the rest", function()
			local dev = new_device()
			local seen = {}
			local handler = dev.binding_changed(function(id)
				if id == 200 then error("boom") end
				seen[#seen + 1] = id
			end)
			handler(200, "BUTTON_LINK", true, 77, 1)
			handler(201, "BUTTON_LINK", true, 78, 1)
			dev.late_init()
			local lines = capture_log()
			dev.replay_bindings()
			assert.same({ 201 }, seen)
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find(
				"^%[ERROR%] Hue Test: OnBindingChanged on binding 200 from before late init failed: .*boom"))
		end)
	end)

	describe("commands to the bridge", function()
		it("send hands the command to the bound bridge and answers true", function()
			local dev, c4 = new_device()
			assert.is_true(dev.send("HUE_SET", { rid = "r1", on = "true" }))
			assert.same({ { id = 15, command = "HUE_SET", params = { rid = "r1", on = "true" } } }, c4.sent)
		end)

		it("answers false with an error line when SendToDevice fails, and raises nothing", function()
			local dev, c4 = new_device()
			local lines = capture_log()
			c4.SendToDevice = function() error("Director says no") end
			local ok
			assert.has_no.errors(function() ok = dev.send("HUE_SCENE_RECALL", { rid = "r1" }) end)
			assert.is_false(ok)
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("^%[ERROR%] Hue Test: HUE_SCENE_RECALL to the bridge failed: .*Director says no"))
		end)
	end)

	describe("keypad LEDs", function()
		local INFO_OFF = {
			{ 5001, { BUTTON_ID = 0, ON_COLOR = "0000ff", OFF_COLOR = "000000", CURRENT_COLOR = "000000" } },
			{ 5001, { BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff", CURRENT_COLOR = "0000ff" } },
			{ 5001, { BUTTON_ID = 2, ON_COLOR = "0000ff", OFF_COLOR = "000000", CURRENT_COLOR = "000000" } },
		}

		it("update_leds waits for a known on state, sends on a change or when forced, with BUTTON_INFO", function()
			local dev, c4, _, _, st = new_device()
			dev.update_leds()
			dev.update_leds(true)
			assert.equal(0, #c4.calls_to("SendToProxy"), "nothing while is_on() is nil")
			st.on = false
			dev.update_leds()
			assert.same({ { 200, { STATE = false } }, { 201, { STATE = false } }, { 202, { STATE = false } } },
				proxied(c4, "MATCH_LED_STATE"))
			assert.same(INFO_OFF, proxied(c4, "BUTTON_INFO"))
			dev.update_leds()
			assert.equal(3, #proxied(c4, "MATCH_LED_STATE"), "unchanged: nothing")
			dev.update_leds(true)
			assert.equal(6, #proxied(c4, "MATCH_LED_STATE"), "forced: again")
			st.on = true
			dev.update_leds()
			local all = proxied(c4, "MATCH_LED_STATE")
			assert.same({ { 200, { STATE = true } }, { 201, { STATE = true } }, { 202, { STATE = true } } },
				{ all[7], all[8], all[9] })
			assert.equal("0000ff", proxied(c4, "BUTTON_INFO")[7][2].CURRENT_COLOR, "top lit while on")
		end)

		it("load_colors reads persisted overrides and ignores what is not a 6-digit hex colour", function()
			local dev, c4, _, _, st = new_device()
			c4.persist.button_0_on_color = "FF0000"
			c4.persist.button_1_off_color = "blue"
			dev.load_colors()
			st.on = true
			dev.update_leds()
			local info = proxied(c4, "BUTTON_INFO")
			assert.same({ BUTTON_ID = 0, ON_COLOR = "ff0000", OFF_COLOR = "000000", CURRENT_COLOR = "ff0000" }, info[1][2])
			assert.same({ BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff", CURRENT_COLOR = "000000" }, info[2][2])
		end)

		it("REQUEST_BUTTON_COLORS on a link answers BUTTON_COLORS there, then MATCH_LED_STATE", function()
			local _, c4, _, dispatch, st = new_device()
			dispatch.received_from_proxy(201, "REQUEST_BUTTON_COLORS", {})
			assert.same({ { 201, { BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff", CURRENT_COLOR = "0000ff" } } },
				proxied(c4, "BUTTON_COLORS"), "bottom lit while off")
			assert.same({ { 201, { STATE = false } } }, proxied(c4, "MATCH_LED_STATE"), "unknown reads as off")
			st.on = true
			dispatch.received_from_proxy("200", "REQUEST_BUTTON_COLORS", {})
			assert.equal("0000ff", proxied(c4, "BUTTON_COLORS")[2][2].CURRENT_COLOR)
			assert.same({ 200, { STATE = true } }, proxied(c4, "MATCH_LED_STATE")[2], "a string binding is fine")
		end)

		it("REQUEST_BUTTON_COLORS on a binding that is no link warns and sends nothing", function()
			local _, c4, _, dispatch = new_device()
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "REQUEST_BUTTON_COLORS", {})
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.same({ "[WARN] Hue Test: REQUEST_BUTTON_COLORS on binding 5001: not a Button Link" }, lines)
		end)

		it("SET_BUTTON_COLOR persists a valid colour under either spelling, echoes it, and warns on a bad one", function()
			local _, c4, _, dispatch, st = new_device()
			st.on = true
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "SET_BUTTON_COLOR", { BUTTON_ID = "2", ["OFF COLOR"] = "00FF00",
				ON_COLOR = "blue" })
			assert.equal("00ff00", c4.persist.button_2_off_color)
			assert.is_nil(c4.persist.button_2_on_color)
			assert.same({ { 202, { BUTTON_ID = 2, ON_COLOR = "0000ff", OFF_COLOR = "00ff00", CURRENT_COLOR = "0000ff" } } },
				proxied(c4, "BUTTON_COLORS"))
			assert.same({ { 5001, { BUTTON_ID = 2, ON_COLOR = "0000ff", OFF_COLOR = "00ff00", CURRENT_COLOR = "0000ff" } } },
				proxied(c4, "BUTTON_INFO"))
			assert.same({ '[WARN] Hue Test: SET_BUTTON_COLOR: ON_COLOR "blue" is not a 6-digit hex colour' }, lines)

			dispatch.received_from_proxy(5001, "SET_BUTTON_COLOR", { BUTTON_ID = "7", ON_COLOR = "ffffff" })
			assert.equal("[WARN] Hue Test: SET_BUTTON_COLOR without a known BUTTON_ID (7)", lines[2])
			assert.equal(1, #proxied(c4, "BUTTON_COLORS"))
		end)
	end)

	describe("keypad buttons", function()
		it("BUTTON_ACTION is echoed to the proxy and handed to the driver's machine", function()
			local _, c4, _, dispatch, st = new_device()
			dispatch.received_from_proxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			dispatch.received_from_proxy(5001, "BUTTON_ACTION", { BUTTON_ID = "2", ACTION = "2" })
			assert.same({ { 5001, { BUTTON_ID = 0, ACTION = 1 } }, { 5001, { BUTTON_ID = 2, ACTION = 2 } } },
				proxied(c4, "BUTTON_ACTION"))
			assert.same({ { 0, 1 }, { 2, 2 } }, st.buttons)
		end)

		it("BUTTON_ACTION without its ids warns and reaches nothing", function()
			local _, c4, _, dispatch, st = new_device()
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0" })
			assert.same({ "[WARN] Hue Test: BUTTON_ACTION without BUTTON_ID/ACTION" }, lines)
			assert.same({}, st.buttons)
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)

		it("DO_PUSH, DO_RELEASE and DO_CLICK on the links become the button's press, release and click", function()
			local _, c4, _, dispatch, st, device = new_device()
			dispatch.received_from_proxy(200, "DO_PUSH", {})
			dispatch.received_from_proxy(201, "DO_RELEASE", {})
			dispatch.received_from_proxy("202", "DO_CLICK", {})
			assert.same({ { 0, device.ACT_PRESS }, { 1, device.ACT_RELEASE }, { 2, device.ACT_CLICK } }, st.buttons)
			assert.same({ 0, 1, 2 }, { device.ACT_RELEASE, device.ACT_PRESS, device.ACT_CLICK })
			assert.equal(0, #c4.calls_to("SendToProxy"), "no echo on the link route")
		end)

		it("ignores the link commands on a binding that is no link, with a warning", function()
			local dev, _, _, dispatch, st = new_device()
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "DO_CLICK", {})
			assert.same({}, st.buttons)
			assert.same({ "[WARN] Hue Test: DO_CLICK on binding 5001: not a Button Link" }, lines)
			assert.equal(1, dev.link_button(201, "x"))
			assert.is_nil(dev.link_button(nil, "DO_PUSH"))
		end)
	end)

	describe("binding re-check", function()
		it("looks at 5, 15, 30 and 60 s while unbound, then waits for a binding", function()
			local dev, c4, _, _, st = new_device()
			st.bridge = nil
			log.set_debug(true) -- the lines are info level
			local lines = capture_log()
			dev.schedule_recheck(1)
			for _, delay in ipairs({ 5000, 10000, 15000, 30000 }) do
				assert.same({ delay }, delays(c4))
				c4.fire_timers()
			end
			assert.same({}, delays(c4))
			assert.equal(0, st.found)
			assert.same({ "[INFO] Hue Test: still not bound to a Hue Bridge 60 s after start; waiting for a binding" },
				lines)
		end)

		it("greets through the hook as soon as the lookup shows the bridge, once", function()
			local dev, c4, _, _, st = new_device()
			st.bridge = nil
			log.set_debug(true)
			local lines = capture_log()
			dev.schedule_recheck(1)
			c4.fire_timers()
			c4:Bind(15, 1, c4.device_id, 1, "HUE_BRIDGE")
			c4.fire_timers()
			assert.equal(1, st.found)
			assert.same({}, delays(c4))
			assert.same({ "[INFO] Hue Test: bridge binding visible after 2 checks; greeting device 15" }, lines)
		end)

		it("does nothing when the driver already knows its bridge, and cancel_recheck ends the retries", function()
			local dev, c4, _, _, st = new_device()
			st.bridge = nil
			dev.schedule_recheck(1)
			st.bridge = 15 -- a binding event greeted it meanwhile
			c4.fire_timers()
			assert.equal(0, st.found)
			assert.same({}, delays(c4), "no further checks either")
			st.bridge = nil
			dev.schedule_recheck(1)
			dev.cancel_recheck()
			assert.same({}, delays(c4))
			dev.cancel_recheck()
		end)
	end)

	describe("goodbye", function()
		it("tells the bound bridge with the rid and device id, and nothing when unbound", function()
			local dev, c4, _, _, st = new_device()
			dev.goodbye("HUE_GOODBYE")
			assert.same({ { id = 15, command = "HUE_GOODBYE", params = { rid = "r1", device_id = "15" } } }, c4.sent)
			st.rid = nil
			dev.goodbye("HUE_SCENE_GOODBYE")
			assert.same({ id = 15, command = "HUE_SCENE_GOODBYE", params = { device_id = "15" } }, c4.sent[2])
			st.bridge = nil
			dev.goodbye("HUE_GOODBYE")
			assert.equal(2, #c4.sent)
		end)

		it("survives a failing SendToDevice with a warning", function()
			local dev, c4 = new_device()
			local lines = capture_log()
			c4.SendToDevice = function() error("Director says no") end
			assert.has_no.errors(function() dev.goodbye("HUE_GOODBYE") end)
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("^%[WARN%] Hue Test: HUE_GOODBYE failed: .*Director says no"))
		end)
	end)

	-- #57: the keypad press / click / release machine both drivers share
	-- (docs/lifecycle-refactor-design.md), its hooks recording what reaches
	-- them. The drivers' specs pin what each driver does in its hooks.
	describe("keypad machine", function()
		-- BUTTON_ACTION's ACTION values (device.ACT_*).
		local RELEASE, PRESS, CLICK = 0, 1, 2

		-- An instance with the module's own machine in dev.button_action and
		-- every hook recording into st.calls; st.on is what the device shows.
		local function new_keypad(opts)
			opts = opts or {}
			package.loaded["common.device"] = nil
			package.loaded["common.dispatch"] = nil
			local c4, env = fake.install_c4({ ["Debug Mode"] = "Off", ["Driver Version"] = "" })
			local device = require("common.device")
			local dispatch = require("common.dispatch")
			local st = { bridge = 15, rid = "r1", on = true, calls = {} }
			local dev = device.new({
				prefix = "Hue Test",
				tree = "light",
				bridge = function() return st.bridge end,
				rid = function() return st.rid end,
				noun = opts.noun,
				settings = opts.settings,
			})
			local function record(...) st.calls[#st.calls + 1] = { ... } end
			dev.is_on = function() return st.on end
			dev.on_bridge_found = function() end
			dev.on_click = function(button) record("click", button) end
			dev.on_hold = function(h, up, on) record("hold", h.button, up, on) end
			dev.on_finish = function(h) record("finish", h.button) end
			dev.on_end_hold = function(h) record("end", h.button) end
			quiet() -- the dev loop's forwarding sink; nothing here reads the bridge's HUE_LOG
			return dev, c4, env, dispatch, st
		end

		it("a click before the hold time is a tap: the press ends, then on_click; a click alone too", function()
			local dev, c4, _, _, st = new_keypad()
			dev.button_action(0, PRESS)
			assert.same({ 400, false }, c4.calls_to("SetTimer")[1])
			dev.button_action(0, CLICK)
			assert.same({ { "end", 0 }, { "click", 0 } }, st.calls)
			assert.same({}, delays(c4), "the hold timer is cancelled")
			dev.button_action(2, CLICK)
			assert.same({ "click", 2 }, st.calls[3])
		end)

		it("holds once the press is still down at 400 ms: top up, bottom down, toggle by the on state then", function()
			-- { button, what the device shows, the direction (up), the on state on_hold hears }
			for _, case in ipairs({
				{ 0, true, true, true }, { 0, false, true, false },
				{ 1, true, false, true },
				{ 2, true, false, true }, { 2, false, true, false }, { 2, nil, true, false },
			}) do
				local dev, c4, _, _, st = new_keypad()
				st.on = case[2]
				dev.button_action(case[1], PRESS)
				assert.same({ 400 }, delays(c4))
				c4.fire_timers()
				assert.same({ { "hold", case[1], case[3], case[4] } }, st.calls)
			end
			-- The on state counts when the hold time passes, not at the press.
			local dev, c4, _, _, st = new_keypad()
			st.on = false
			dev.button_action(2, PRESS)
			st.on = true
			c4.fire_timers()
			assert.same({ { "hold", 2, false, true } }, st.calls)
		end)

		it("does nothing for down from off, with the device's own word in the debug line", function()
			for _, noun in ipairs({ "light", "scene" }) do
				local dev, c4, _, _, st = new_keypad({ noun = noun })
				st.on = false
				log.set_debug(true)
				local lines = capture_log()
				dev.button_action(1, PRESS)
				c4.fire_timers()
				assert.same({}, st.calls)
				assert.same({ "[DEBUG] Hue Test: hold: dimming down a " .. noun .. " that is off does nothing" }, lines)
				dev.button_action(1, RELEASE) -- still a hold that ends: the click after it is guarded
				assert.same({ { "end", 1 }, { "finish", 1 } }, st.calls)
				assert.same({ 1000 }, delays(c4))
			end
		end)

		it("finishes a hold at its release and then ignores a click on that button for 1 s, not on another", function()
			local dev, c4, _, _, st = new_keypad()
			log.set_debug(true)
			local lines = capture_log()
			dev.button_action(0, PRESS)
			c4.fire_timers()
			dev.button_action(0, RELEASE)
			assert.same({ { "hold", 0, true, true }, { "end", 0 }, { "finish", 0 } }, st.calls)
			assert.same({ 1000 }, delays(c4), "the click guard")
			st.calls = {}
			dev.button_action(0, CLICK)
			assert.same({}, st.calls, "the keypad's click after the hold")
			assert.same({ "[DEBUG] Hue Test: click on button 0 right after a hold ignored" }, lines)
			dev.button_action(0, PRESS)
			dev.button_action(0, CLICK)
			assert.same({ { "end", 0 } }, st.calls, "a new tap within the second is the keypad's too")
			dev.button_action(1, CLICK)
			assert.same({ "click", 1 }, st.calls[2], "another button is not guarded")
			c4.fire_timers() -- 1 s later
			dev.button_action(0, CLICK)
			assert.same({ "click", 0 }, st.calls[3])
		end)

		it("finishes a hold at a release-as-click instead of tapping", function()
			local dev, c4, _, _, st = new_keypad()
			dev.button_action(2, PRESS)
			c4.fire_timers()
			dev.button_action(2, CLICK)
			assert.same({ { "hold", 2, false, true }, { "end", 2 }, { "finish", 2 } }, st.calls)
			assert.same({ 1000 }, delays(c4))
		end)

		it("ends a press released before the hold time quietly: no tap, no finish, no guard", function()
			local dev, c4, _, _, st = new_keypad()
			dev.button_action(0, PRESS)
			dev.button_action(0, RELEASE)
			assert.same({ { "end", 0 } }, st.calls)
			assert.same({}, delays(c4))
			dev.button_action(0, CLICK) -- the click a keypad sends after such a release is the tap
			assert.same({ { "end", 0 }, { "click", 0 } }, st.calls)
		end)

		it("ends a press when the next one starts, which gets its own hold time", function()
			local dev, c4, _, _, st = new_keypad()
			dev.button_action(0, PRESS)
			dev.button_action(1, PRESS)
			assert.same({ { "end", 0 } }, st.calls)
			assert.same({ 400 }, delays(c4), "only the new press's hold timer")
			c4.fire_timers()
			assert.same({ { "end", 0 }, { "hold", 1, false, true } }, st.calls)
		end)

		it("cancels the timer a hook keeps in h.timer when the press ends; holding(h) names the press", function()
			local dev, c4 = new_keypad()
			local held
			dev.on_hold = function(h)
				held = h
				h.timer = c4:SetTimer(100, function() end, true)
			end
			dev.button_action(0, PRESS)
			c4.fire_timers()
			assert.is_true(dev.holding(held))
			assert.same({ 100 }, delays(c4))
			dev.button_action(0, RELEASE)
			assert.is_false(dev.holding(held))
			assert.same({ 1000 }, delays(c4), "the hook's timer is gone; the click guard remains")
		end)

		it("dim_after_on dims up 600 ms later while the press lasts and the device is bound with a rid", function()
			for _, case in ipairs({ "held", "released", "unbound", "no rid" }) do
				local dev, c4, _, _, st = new_keypad()
				local dims = 0
				dev.on_hold = function(h)
					dev.dim_after_on(h, function() dims = dims + 1 end)
				end
				dev.button_action(0, PRESS)
				c4.fire_timers() -- the hold time
				assert.same({ 600, false }, c4.calls_to("SetTimer")[2], case)
				if case == "released" then dev.button_action(0, RELEASE) end
				if case == "unbound" then st.bridge = nil end
				if case == "no rid" then st.rid = nil end
				c4.fire_timers() -- 600 ms later
				assert.equal(case == "held" and 1 or 0, dims, case)
			end
		end)

		it("#298: loads on a new device, where Director's PersistGetValue returns no value at all", function()
			local dev, c4 = new_keypad({ settings = { "preset", "click_up", "click_down", "hold_up", "hold_down" } })
			-- Director answers a key never written with nothing (not nil);
			-- tonumber() without an argument raises.
			c4.PersistGetValue = function() end
			assert.has_no.errors(function() dev.load_settings() end)
			assert.same({ 100, 250, 250, 5000, 5000 }, { dev.setting("preset"), dev.setting("click_up"),
				dev.setting("click_down"), dev.setting("hold_up"), dev.setting("hold_down") })
		end)

		it("takes the declared settings: defaults, persisted values, and the proxy's commands that set them", function()
			local dev, c4, _, dispatch = new_keypad({ settings = { "preset", "click_up", "click_down", "hold_up",
				"hold_down" } })
			local function all()
				return { dev.setting("preset"), dev.setting("click_up"), dev.setting("click_down"),
					dev.setting("hold_up"), dev.setting("hold_down") }
			end
			assert.same({ 100, 250, 250, 5000, 5000 }, all())
			c4.persist.preset_level = 40
			c4.persist.hold_rate_down = "2000"
			dev.load_settings()
			assert.same({ 40, 250, 250, 5000, 2000 }, all())
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", { LEVEL = "60" })
			dispatch.received_from_proxy(5001, "SET_CLICK_RATE_UP", { RATE = "1500" })
			dispatch.received_from_proxy(5001, "SET_CLICK_RATE_DOWN", { RATE = "500" })
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_UP", { RATE = "7000" })
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_DOWN", { RATE = "3000" })
			assert.same({ 60, 1500, 500, 7000, 3000 }, all())
			assert.same({ preset_level = 60, click_rate_up = 1500, click_rate_down = 500, hold_rate_up = 7000,
				hold_rate_down = 3000 }, c4.persist)
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_UP", { RATE = "fast" })
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", {})
			assert.same({ '[WARN] Hue Test: hold_rate_up "fast" is not a number; kept 7000',
				"[WARN] Hue Test: preset_level without a value; kept 60" }, lines)
			assert.same({ 60, 1500, 500, 7000, 3000 }, all(), "unchanged")
		end)

		-- Hardware 2026-10-25 (dev build 284): without the answer the proxy kept
		-- its old value, so Composer showed 5.000 s after a change to 2.000 s
		-- and setting 5.000 s again sent nothing.
		it("answers each setting command with the notification the proxy stores, and reports all at late init", function()
			local dev, c4, _, dispatch = new_keypad({ settings = { "preset", "click_up", "click_down", "hold_up",
				"hold_down" } })
			c4.persist.hold_rate_down = "2000"
			dev.load_settings()
			assert.same({ { 5001, "100" } }, proxied(c4, "PRESET_LEVEL"))
			assert.same({ { 5001, "250" } }, proxied(c4, "CLICK_RATE_UP"))
			assert.same({ { 5001, "250" } }, proxied(c4, "CLICK_RATE_DOWN"))
			assert.same({ { 5001, "5000" } }, proxied(c4, "HOLD_RATE_UP"))
			assert.same({ { 5001, "2000" } }, proxied(c4, "HOLD_RATE_DOWN"),
				"the persisted value, bare (the proxy reads a table as 0)")
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_DOWN", { RATE = "5000" })
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", { LEVEL = "60" })
			assert.same({ 5001, "5000" }, proxied(c4, "HOLD_RATE_DOWN")[2])
			assert.same({ 5001, "60" }, proxied(c4, "PRESET_LEVEL")[2])
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_UP", { RATE = "fast" })
			assert.same({ 5001, "5000" }, proxied(c4, "HOLD_RATE_UP")[2], "a refused value: the one kept")
		end)

		-- Issue #234: a value that is not a number was dropped without an
		-- answer, so Composer went on showing what had been typed.
		it("answers a value that is not a number with the value kept, as one out of range (#234)", function()
			local dev, c4, _, dispatch = new_keypad({ settings = { "preset", "click_up", "hold_down" } })
			c4.persist.click_rate_up = 1500
			dev.load_settings()
			c4.calls = {}
			local lines = capture_log()
			dispatch.received_from_proxy(5001, "SET_CLICK_RATE_UP", { RATE = "1.5 s" })
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", { LEVEL = "" })
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_DOWN", {})
			assert.same({ { 5001, "1500" } }, proxied(c4, "CLICK_RATE_UP"))
			assert.same({ { 5001, "100" } }, proxied(c4, "PRESET_LEVEL"))
			assert.same({ { 5001, "5000" } }, proxied(c4, "HOLD_RATE_DOWN"))
			assert.same({ 1500, 100, 5000 }, { dev.setting("click_up"), dev.setting("preset"), dev.setting("hold_down") })
			assert.equal(0, #c4.calls_to("PersistSetValue"), "nothing stored")
			assert.same({
				'[WARN] Hue Test: click_rate_up "1.5 s" is not a number; kept 1500',
				'[WARN] Hue Test: preset_level "" is not a number; kept 100',
				"[WARN] Hue Test: hold_rate_down without a value; kept 5000",
			}, lines)
		end)

		it("refuses a setting out of range, from the proxy and at load, and tells the proxy the value kept", function()
			local dev, c4, _, dispatch = new_keypad({ settings = { "preset", "hold_down" } })
			c4.persist.preset_level = "0"
			local lines = capture_log()
			dev.load_settings()
			assert.equal(100, dev.setting("preset"), "a persisted 0 reads as the default")
			assert.same({ { 5001, "100" } }, proxied(c4, "PRESET_LEVEL"))
			assert.same({ "[WARN] Hue Test: preset_level 0 is out of range; using 100" }, lines)
			assert.is_nil(c4.persist.preset_level, "the bad value is deleted, so the next start does not warn again")
			dev.load_settings()
			assert.equal(1, #lines, "warned once")
			dispatch.received_from_proxy(5001, "SET_PRESET_LEVEL", { LEVEL = "0" })
			assert.equal(100, dev.setting("preset"))
			assert.same({ 5001, "100" }, proxied(c4, "PRESET_LEVEL")[2], "the proxy hears the value kept")
			dispatch.received_from_proxy(5001, "SET_HOLD_RATE_DOWN", { RATE = "-5" })
			assert.equal(5000, dev.setting("hold_down"))
		end)

		it("handles only the settings a driver declares; the rest stay without a handler", function()
			local dev, c4, _, dispatch = new_keypad({ settings = { "hold_up", "hold_down" } })
			assert.is_function(dispatch.proxy["SET_HOLD_RATE_UP"])
			assert.is_function(dispatch.proxy["SET_HOLD_RATE_DOWN"])
			for _, command in ipairs({ "SET_PRESET_LEVEL", "SET_CLICK_RATE_UP", "SET_CLICK_RATE_DOWN" }) do
				assert.is_nil(dispatch.proxy[command], command)
			end
			dev.load_settings()
			local keys = {}
			for _, args in ipairs(c4.calls_to("PersistGetValue")) do keys[#keys + 1] = args[1] end
			assert.same({ "hold_rate_up", "hold_rate_down" }, keys)
			local _, _, _, none = new_keypad()
			assert.is_nil(none.proxy["SET_HOLD_RATE_UP"], "no settings declared, none handled")
		end)

		it("is fed by both routes: the Button Links and the proxy's BUTTON_ACTION", function()
			local _, c4, _, dispatch, st = new_keypad()
			dispatch.received_from_proxy(201, "DO_PUSH", {})
			c4.fire_timers()
			dispatch.received_from_proxy(5001, "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "0" })
			assert.same({ { "hold", 1, false, true }, { "end", 1 }, { "finish", 1 } }, st.calls)
			assert.same({ { 5001, { BUTTON_ID = 1, ACTION = 0 } } }, proxied(c4, "BUTTON_ACTION"))
		end)

		it("arms the click guard before on_finish, so a failing hook still leaves the keypad's click ignored", function()
			local dev, c4, _, dispatch, st = new_keypad()
			dev.on_finish = function() error("boom") end
			local lines = capture_log()
			dispatch.received_from_proxy(200, "DO_PUSH", {})
			c4.fire_timers()
			dispatch.received_from_proxy(200, "DO_RELEASE", {})
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("^%[ERROR%] Hue Test: proxy handler DO_RELEASE failed: .*boom"))
			dispatch.received_from_proxy(200, "DO_CLICK", {})
			assert.same({ { "hold", 0, true, true }, { "end", 0 } }, st.calls, "no tap after the hold")
		end)

		it("cancel_timers ends a press and the click guard (OnDriverDestroyed)", function()
			local dev, c4, _, _, st = new_keypad()
			dev.button_action(0, PRESS)
			dev.cancel_timers()
			assert.same({ { "end", 0 } }, st.calls)
			assert.same({}, delays(c4))
			dev.button_action(1, PRESS)
			c4.fire_timers()
			dev.button_action(1, RELEASE)
			assert.same({ 1000 }, delays(c4))
			dev.cancel_timers()
			assert.same({}, delays(c4))
			dev.button_action(1, CLICK)
			assert.same({ "click", 1 }, st.calls[#st.calls], "the guard went with it")
		end)
	end)

	describe("parsers", function()
		it("text is a string or nil for absent and empty", function()
			local device = require("common.device")
			assert.equal("7", device.text(7))
			assert.equal("a", device.text("a"))
			assert.is_nil(device.text(""))
			assert.is_nil(device.text(nil))
		end)

		it("to_bool reads booleans, true/false and 1/0 in any case, nil otherwise", function()
			local device = require("common.device")
			assert.is_true(device.to_bool(true))
			assert.is_false(device.to_bool(false))
			assert.is_true(device.to_bool("TRUE"))
			assert.is_true(device.to_bool("1"))
			assert.is_false(device.to_bool("False"))
			assert.is_false(device.to_bool(0))
			assert.is_nil(device.to_bool("yes"))
			assert.is_nil(device.to_bool(nil))
		end)
	end)
end)
