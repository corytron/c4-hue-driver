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
			assert.equal("Renamed device 7 to Desk", env.Properties["Last Action"])
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
