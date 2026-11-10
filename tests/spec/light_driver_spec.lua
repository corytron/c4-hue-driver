-- Hue Light driver against the fake runtime, with a bridge driver standing
-- behind binding 1 as device 15 (bound with C4:Bind, as Composer or the
-- bridge's import would), so SendToDevice to it can be asserted on.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BRIDGE_ID = 15
local LIGHT_ID = 2001

-- The bulb HUE_CONFIGURE describes, every value a string as Director hands it over.
local CONFIGURE = { rid = "l1", name = "Desk", model = "Hue color lamp", has_color = "true", has_cct = "true",
	mirek_min = "153", mirek_max = "500", min_dim = "0.2" }

local function quiet()
	log.sink = function() end
end

-- The read of the proxy's presets SETUP_READ_MS after late init (#427 D19).
local SETUP_READ_MS = 3000

-- opts.bind=false leaves the light unbound; opts.rid persists a rid first;
-- opts.persist holds more persisted values. The read of the proxy's presets
-- after late init runs at once (nothing scripted: it learns nothing), so the
-- specs see no timer of it; opts.setup = "wait" leaves it armed.
local function load_light(opts)
	opts = opts or {}
	local env, c4 = fake.load_driver("hue_light", opts.props or {}, { device_id = LIGHT_ID })
	if opts.bind ~= false then
		c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
	end
	if opts.rid then
		c4.persist.hue_rid = opts.rid
	end
	for k, v in pairs(opts.persist or {}) do
		c4.persist[k] = v
	end
	env.OnDriverLateInit("DIT_STARTUP")
	if opts.setup ~= "wait" then
		assert(c4.fire_timers_of(SETUP_READ_MS) == 1, "late init arms the read of the proxy's presets")
	end
	return env, c4
end

local function configure(env, extra)
	local params = {}
	for k, v in pairs(CONFIGURE) do params[k] = v end
	for k, v in pairs(extra or {}) do params[k] = v end
	env.ExecuteCommand("HUE_CONFIGURE", params)
end

-- The window of the light's Hue-side level reports (#433 D12, LEVEL_REPORT_MS).
local LEVEL_REPORT_MS = 1000
-- The double-tap window, after which a press's tap count goes to the proxy
-- (#432 D6, common/device.lua DOUBLE_TAP_MS).
local DOUBLE_TAP_MS = 600

-- A configured, on, white light at 40%. The hello's report opened the level
-- window (#433 D12); it has run out quietly, so the light starts idle.
local function lit_light()
	local env, c4 = load_light({ rid = "l1" })
	configure(env)
	env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40", mirek = "370",
		color_mode = "ct", online = "true", reason = "hello" })
	assert(c4.fire_timers_of(LEVEL_REPORT_MS) == 1, "the hello's report opens the level window")
	c4.calls = {}
	c4.sent = {}
	return env, c4
end

-- Params of every SendToProxy to the proxy binding (5001) with that
-- command, in order; the keypad LED messages on the Button Links (200-202)
-- are left out.
local function notifies(c4, command)
	local out = {}
	for _, args in ipairs(c4.calls_to("SendToProxy")) do
		if args[1] == 5001 and args[2] == command then out[#out + 1] = args[3] end
	end
	return out
end

-- The fake records three SendToProxy arguments; this keeps the message type
-- too, as { binding, command, params, type }, from now on.
local function capture_proxy(c4)
	local out = {}
	local original = c4.SendToProxy
	c4.SendToProxy = function(self, binding, command, params, message_type)
		out[#out + 1] = { binding, command, params, message_type }
		return original(self, binding, command, params, message_type)
	end
	return out
end

-- The captured calls with that command, in order.
local function with_command(captured, command)
	local out = {}
	for _, call in ipairs(captured) do
		if call[2] == command then out[#out + 1] = call end
	end
	return out
end

-- The three MATCH_LED_STATE commands, one per Button Link, for `on`.
local function leds(on)
	return {
		{ 200, "MATCH_LED_STATE", { STATE = on }, "COMMAND" },
		{ 201, "MATCH_LED_STATE", { STATE = on }, "COMMAND" },
		{ 202, "MATCH_LED_STATE", { STATE = on }, "COMMAND" },
	}
end

-- Params of every HUE_DIM sent, in order.
local function dims(c4)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.command == "HUE_DIM" then out[#out + 1] = m.params end
	end
	return out
end

-- Params of every ramp stop sent, in order. Since the house measurement
-- (#421 §7, measured 2026-11-09) a stop is STOP_MODE "level": an urgent
-- HUE_SET of the estimate, on, over the STOP_GLIDE_MS glide of 1000 ms.
local function stops(c4)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.command == "HUE_SET" and m.params.urgent == "true" and m.params.rate == "1000" then
			out[#out + 1] = m.params
		end
	end
	return out
end

-- The stop at `level` (a string) for `rid` (default "l1").
local function stop_at(level, rid)
	return { rid = rid or "l1", on = "true", brightness = level, rate = "1000", urgent = "true" }
end

local function last_sent(c4)
	return c4.sent[#c4.sent]
end

-- The delays of the active timers, lowest first.
local function delays_of(c4)
	local out = {}
	for _, timer in ipairs(c4.active_timers()) do out[#out + 1] = timer.delay end
	table.sort(out)
	return out
end

-- What a hello sends since #435 (docs/load-groups-design.md §6.3, D6,
-- E19): HUE_HELLO with `hello`, then HUE_LOAD_GROUPS with the device's id,
-- rid and kind as the hello names them, and `groups` ("none" by default).
local function greeting(hello, groups)
	return {
		{ id = BRIDGE_ID, command = "HUE_HELLO", params = hello },
		{ id = BRIDGE_ID, command = "HUE_LOAD_GROUPS", params = { device_id = hello.device_id, rid = hello.rid,
			kind = hello.kind == "group" and "group" or nil, groups = groups or "none" } },
	}
end

-- Every SendToDevice with that command, in order.
local function messages(c4, command)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.command == command then out[#out + 1] = m end
	end
	return out
end

-- The fake records three SendToDevice arguments; this keeps all five, as
-- { id, command, params, allow_empty, log_command }, from now on.
local function capture_sends(c4)
	local out = {}
	local original = c4.SendToDevice
	c4.SendToDevice = function(self, id, command, params, allow_empty, log_command)
		out[#out + 1] = { id = id, command = command, params = params,
			allow_empty = allow_empty, log_command = log_command }
		return original(self, id, command, params, allow_empty, log_command)
	end
	return out
end

-- Load a light as load_light does, and keep the instance device.new gave the
-- driver (common/device.lua), so a spec can call its hooks directly.
local function load_light_with_dev(opts)
	local dev
	package.preload["common.device"] = function(name)
		package.preload["common.device"] = nil
		local module = assert(loadfile("src/common/device.lua"))(name)
		local new = module.new
		module.new = function(...)
			dev = new(...)
			return dev
		end
		return module
	end
	local ok, env, c4 = pcall(load_light, opts)
	package.preload["common.device"] = nil
	assert(ok, env)
	return env, c4, assert(dev, "the driver made its device instance")
end

-- Load a light whose driver.lua says STOP_MODE = "stop" (#421 D8, the
-- alternative the house measurement set aside), through the loadfile
-- fake.load_driver uses: a test-only seam, no global of the driver's.
local function load_light_stop_mode(opts)
	local real = loadfile
	local swapped = 0
	rawset(_G, "loadfile", function(path, ...)
		if path == "src/hue_light/driver.lua" then
			local file = assert(io.open(path))
			local source = file:read("*a")
			file:close()
			source, swapped = source:gsub('local STOP_MODE = "level"', 'local STOP_MODE = "stop"')
			return loadstring(source, "@" .. path)
		end
		return real(path, ...)
	end)
	local ok, env, c4 = pcall(load_light, opts)
	rawset(_G, "loadfile", real)
	assert(ok, env)
	assert(swapped == 1, "driver.lua declares STOP_MODE = \"level\" once")
	return env, c4
end

-- Run `body` with devloop.apply_forwarded replaced by `stub`, on the instance
-- the driver loaded (fake.load_driver reloads common.* per driver, so this
-- must run after the driver is up).
local function with_apply_forwarded(stub, body)
	local devloop = require("common.devloop")
	local original = devloop.apply_forwarded
	devloop.apply_forwarded = stub
	local ok, err = pcall(body)
	devloop.apply_forwarded = original
	assert(ok, err)
end

describe("Hue Light driver", function()
	before_each(quiet)

	describe("startup and binding", function()
		it("greets the bridge with its persisted rid on late init", function()
			local env, c4 = load_light({ rid = "l1" })
			assert.same(greeting({ rid = "l1", device_id = "2001" }), c4.sent)
			assert.equal("l1", env.Properties["Hue Light ID"])
			assert.equal("None", env.Properties["Load Groups"], "#435 §6.1")
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
			assert.equal("", env.Properties["Online"], "not known until the bridge says")
			assert.equal("1", env.Properties["Driver Version"])
		end)

		it("shows the build's own version stamp when Director answers the lookup with nothing", function()
			-- A device created by AddDevice gets no version at its first init
			-- [hardware 2026-10-24, device 1166]; tools/build.sh stamps
			-- common/build_version.lua for that case.
			package.preload["common.build_version"] = function() return "196" end
			package.loaded["common.build_version"] = nil
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4.config_info.version = ""
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal("196", env.Properties["Driver Version"])
			package.preload["common.build_version"] = nil
			package.loaded["common.build_version"] = nil
		end)

		it("shows its version even when Director's property table is still empty at late init", function()
			-- The first init of a device created by AddDevice [hardware
			-- 2026-10-24, devices 1166 and 1168]: nothing to replay.
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			for name in pairs(env.Properties) do env.Properties[name] = nil end
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal("1", env.Properties["Driver Version"])
			-- And when the version is not known at all yet, it is looked at again.
			local env2, c42 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c42.config_info.version = ""
			env2.OnDriverLateInit("DIT_STARTUP")
			assert.equal("", env2.Properties["Driver Version"])
			c42.config_info.version = "7"
			c42.fire_timers()
			assert.equal("7", env2.Properties["Driver Version"])
			assert.is_not_nil(c4)
		end)

		it("greets without a rid key when it has none (SendToDevice drops empty values)", function()
			local _, c4 = load_light()
			assert.same(greeting({ device_id = "2001" }), c4.sent)
		end)

		it("greets with its persisted name and model too, and shows them before the bridge answers", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c4.persist.hue_rid, c4.persist.hue_name, c4.persist.hue_model = "l1", "Desk", "Hue color lamp"
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same(greeting({ rid = "l1", device_id = "2001", name = "Desk", model = "Hue color lamp" }), c4.sent)
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
			assert.equal("", env.Properties["Online"], "still not known until the bridge says")
		end)

		it("accepts GetBoundProviderDevice answering with a table of id/name pairs", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4.GetBoundProviderDevice = function() return { [BRIDGE_ID] = "Hue Bridge" } end
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(BRIDGE_ID, c4.sent[1].id)
		end)

		it("treats GetBoundProviderDevice answering 0 as unbound (OS 3.4.2 with nothing bound)", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4.GetBoundProviderDevice = function() return 0 end
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(0, #c4.sent)
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
		end)

		it("stays quiet and says so when no bridge is bound", function()
			local env, c4 = load_light({ bind = false })
			assert.equal(0, #c4.sent)
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))
		end)

		it("re-greets the bridge when binding 1 is bound later, and goes offline when unbound", function()
			local env, c4 = load_light({ bind = false, rid = "l1" })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			assert.same(greeting({ rid = "l1", device_id = "2001" }), c4.sent)
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])

			c4.calls = {}
			c4.bindings = {}
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
		end)

		it("trusts the device id in the binding notification when the lookup lags behind", function()
			local env, c4 = load_light({ bind = false, rid = "l1" })
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			assert.same(greeting({ rid = "l1", device_id = "2001" }), c4.sent)
		end)

		it("ignores binding changes other than the bridge's", function()
			local env, c4 = load_light({ rid = "l1" })
			c4.sent = {}
			c4.calls = {}
			env.OnBindingChanged(5001, "LIGHT_V2", true, 99, 1)
			assert.equal(0, #c4.sent)
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)
	end)

	describe("HUE_CONFIGURE", function()
		it("stores the rid, fills the properties, sends both supports_* keys in one notify, rates in a second", function()
			local env, c4 = load_light()
			c4.calls = {}
			configure(env)

			assert.equal("l1", c4.persist.hue_rid)
			assert.equal("l1", env.Properties["Hue Light ID"])
			assert.equal("Desk", env.Properties["Hue Name"])
			assert.equal("Hue color lamp", env.Properties["Model"])
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"])

			local dyn = notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED")
			assert.equal(2, #dyn)
			assert.same({
				supports_color = "true",
				supports_color_correlated_temperature = "true",
				color_correlated_temperature_min = 2000,
				color_correlated_temperature_max = 6530,
			}, dyn[1])
			assert.same({ brightness_rate_min = 0, brightness_rate_max = 6000000, color_rate_behavior = 1,
				color_rate_min = 0, color_rate_max = 6000000 }, dyn[2], "#430 D20, §7.2")
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "state not known yet")
			assert.equal(0, #notifies(c4, "LIGHT_COLOR_CHANGED"))
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
		end)

		-- #246: the bridge leaves the name out while it cannot tell yet whether
		-- the lamp's Hue name is its device's or its own (right after a start).
		it("keeps the Hue Name row and the stored name when a configure carries no name", function()
			local env, c4 = load_light()
			configure(env)
			local nameless = {}
			for k, v in pairs(CONFIGURE) do nameless[k] = v end
			nameless.name = nil
			env.ExecuteCommand("HUE_CONFIGURE", nameless)
			assert.equal("Desk", env.Properties["Hue Name"])
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
			assert.equal("Desk", c4.persist.hue_name)
			configure(env, { name = "Desk Lamp" })
			assert.equal("Desk Lamp", env.Properties["Hue Name"])
		end)

		it("re-reports known state after a re-configure", function()
			local env, c4 = lit_light()
			configure(env)
			assert.equal(2, #notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"), "the colour flags, then the rate ranges")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGED"))
		end)

		it("persists the Hue name and model next to the rid, refreshed by every configure", function()
			local env, c4 = load_light()
			configure(env)
			assert.same({ hue_rid = "l1", hue_name = "Desk", hue_model = "Hue color lamp" }, c4.persist)
			configure(env, { name = "Desk Lamp" })
			assert.equal("Desk Lamp", c4.persist.hue_name)
		end)

		it("shows the Hue room and the v1 id in front of the rid", function()
			local env = load_light()
			configure(env, { rid = "e0e51794-1234-5678-9abc-def012345678", hue_room = "Office", id_v1 = "/lights/12" })
			assert.equal("#12 (e0e51794…)", env.Properties["Hue Light ID"])
			assert.equal("Office", env.Properties["Hue Room"])
			configure(env, { rid = "l1", id_v1 = "7" })
			assert.equal("#7 (l1)", env.Properties["Hue Light ID"], "a rid without dashes is shown whole")
		end)

		it("falls back to the rid and an empty room when a configure carries neither", function()
			local env = load_light()
			configure(env, { hue_room = "Office", id_v1 = "/lights/12" })
			configure(env)
			assert.equal("l1", env.Properties["Hue Light ID"])
			assert.equal("", env.Properties["Hue Room"], "SendToDevice drops an empty room, so absent means none")
		end)

		it("takes a light offline while the bridge says it is gone, and back when it is linked again", function()
			local env, c4 = lit_light()
			configure(env, { state = "gone", gone_since = "1761000000" })
			local expected = "Gone from the Hue bridge since " .. os.date("%Y-%m-%d %H:%M", 1761000000)
				.. "; Link or Forget Device"
			assert.equal(expected, env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))

			c4.sent = {}
			c4.calls = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(0, #c4.sent, "dropped")
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.equal(expected, env.Properties["Status"])

			configure(env, { state = "linked" })
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(1, #messages(c4, "HUE_SET"))
		end)

		it("says gone without a date when the bridge sends none", function()
			local env = lit_light()
			configure(env, { state = "gone" })
			assert.equal("Gone from the Hue bridge; Link or Forget Device", env.Properties["Status"])
		end)
	end)

	describe("HUE_FORGOTTEN", function()
		-- A lit light whose v1 id is known, so the forgotten text can name it.
		local function known_light()
			local env, c4 = lit_light()
			configure(env, { id_v1 = "/lights/12" })
			c4.calls = {}
			c4.sent = {}
			return env, c4
		end

		local FORGOTTEN = "Forgotten by the bridge (was Hue light Desk #12). "
			.. "Delete this device, or bind it again and use Link Device on the Hue Bridge"

		it("explains in Status, goes offline and drops proxy commands", function()
			local env, c4 = known_light()
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = "l1", name = "Desk" })
			assert.equal(FORGOTTEN, env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
			assert.equal("Forgotten by the bridge", fake.last_action(env))
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))

			c4.calls = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35" })
			assert.equal(0, #messages(c4, "HUE_SET"))
			assert.equal(0, #c4.calls_to("SendToProxy"), "not even CHANGING")
			assert.equal(0, #c4.active_timers())
			assert.equal(FORGOTTEN, env.Properties["Status"])
			assert.same({ hue_rid = "l1", hue_name = "Desk", hue_model = "Hue color lamp" }, c4.persist,
				"the identity stays, so binding the device again lets the bridge adopt it")
		end)

		it("names the light from its own state when the message carries no name", function()
			local env = known_light()
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = "l1" })
			assert.equal(FORGOTTEN, env.Properties["Status"])
		end)

		it("keeps the forgotten text when the bridge then unbinds it", function()
			local env, c4 = known_light()
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = "l1", name = "Desk" })
			c4.bindings = {}
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.equal(FORGOTTEN, env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
		end)

		it("is cleared by the next HUE_CONFIGURE", function()
			local env, c4 = known_light()
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = "l1", name = "Desk" })
			c4.calls = {}
			configure(env)
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(1, #messages(c4, "HUE_SET"))
		end)

		it("settles pending targets so no fallback fires afterwards", function()
			local env, c4 = known_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(1, #c4.active_timers())
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = "l1", name = "Desk" })
			assert.equal(0, #c4.active_timers())
		end)

		it("ignores a forgotten for another rid", function()
			local env, c4 = known_light()
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = "other", name = "Lamp" })
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)
	end)

	describe("before late init", function()
		it("buffers HUE_CONFIGURE, HUE_STATE and HUE_FORGOTTEN and applies them in order from OnDriverLateInit", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			configure(env)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40", reason = "resync" })
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "55" })
			assert.equal(0, #c4.calls_to("UpdateProperty"), "nothing touches Director before late init")
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.equal(0, #c4.calls_to("PersistSetValue"))
			assert.equal(0, #c4.sent)

			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
			assert.equal("l1", c4.persist.hue_rid)
			assert.equal(2, #notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"))
			-- The second, a Hue-side level, comes at the end of the window the
			-- resync's report opened (#433 D12).
			assert.equal(1, c4.fire_timers_of(LEVEL_REPORT_MS))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 }, { LIGHT_BRIGHTNESS_CURRENT = 55 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "both states, in arrival order")
			assert.same(greeting({ rid = "l1", device_id = "2001", name = "Desk", model = "Hue color lamp" }), c4.sent,
				"the hello carries the identity the buffered configure delivered")
			local online = notifies(c4, "ONLINE_CHANGED")
			assert.same({ STATE = true }, online[#online])
		end)

		it("applies a buffered HUE_FORGOTTEN after the configure that preceded it", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			configure(env)
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = "l1", name = "Desk" })
			env.OnDriverLateInit("DIT_STARTUP")
			assert.truthy(env.Properties["Status"]:find("^Forgotten by the bridge %(was Hue light Desk%)"))
			assert.equal("Offline", env.Properties["Online"])
		end)

		it("handles messages at once after late init, and again after a dev reload's late init", function()
			local env, c4 = load_light({ rid = "l1" })
			configure(env)
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
			env.OnDriverLateInit("DIT_STARTUP") -- the dev loop re-runs the entry points after a reload
			c4.calls = {}
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "20" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 20 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		-- docs/review-leftovers-design.md #49: the bridge's import binds a device
		-- it has just created, so OnBindingChanged can come before late init.
		it("holds a bridge binding that arrives before late init and greets through it once late init has run", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4.persist.hue_rid = "l1"
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			assert.equal(0, #c4.calls_to("UpdateProperty"), "nothing touches Director before late init")
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.equal(0, #c4.sent)

			-- Director's lookup does not show the binding yet at late init.
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same(greeting({ rid = "l1", device_id = "2001" }), c4.sent)
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
			local delays = {}
			for _, timer in ipairs(c4.active_timers()) do delays[#delays + 1] = timer.delay end
			assert.same({ SETUP_READ_MS }, delays,
				"the binding ended the re-checks late init started; only the read of the presets waits (#427 D19)")
		end)

		it("greets once when late init already sees the binding that arrived before it", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4.persist.hue_rid = "l1"
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(1, #messages(c4, "HUE_HELLO"))
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
		end)

		it("applies an unbind that arrived before late init after it", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4.persist.hue_rid = "l1"
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.equal(0, #c4.calls_to("UpdateProperty"))
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
			assert.equal(0, #c4.sent)
		end)
	end)

	describe("OnDriverRemovedFromProject", function()
		it("says goodbye to the bound bridge with its rid and device id", function()
			local env, c4 = lit_light()
			env.OnDriverRemovedFromProject()
			assert.same({ { id = BRIDGE_ID, command = "HUE_GOODBYE", params = { rid = "l1", device_id = "2001" } } }, c4.sent)
			env.OnDriverDestroyed("DIT_LOADED")
			assert.equal(0, #c4.active_timers())
		end)

		it("sends only the device id when it never had a rid", function()
			local env, c4 = load_light()
			c4.sent = {}
			env.OnDriverRemovedFromProject()
			assert.same({ { id = BRIDGE_ID, command = "HUE_GOODBYE", params = { device_id = "2001" } } }, c4.sent)
		end)

		it("runs through the fake's Composer delete: goodbye, then destroyed with its timers killed", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			fake.delete_device(LIGHT_ID)
			assert.equal(1, #messages(c4, "HUE_GOODBYE"))
			assert.equal(0, #c4.active_timers())
			assert.is_nil(fake.project.devices[LIGHT_ID])
		end)

		it("stays quiet when no bridge is bound", function()
			local env, c4 = load_light({ bind = false, rid = "l1" })
			assert.has_no.errors(function() env.OnDriverRemovedFromProject() end)
			assert.equal(0, #c4.sent)
		end)

		it("survives a failing SendToDevice", function()
			local env, c4 = lit_light()
			local original = c4.SendToDevice
			c4.SendToDevice = function(self, id, command, ...)
				if command == "HUE_GOODBYE" then error("Director says no") end
				return original(self, id, command, ...)
			end
			assert.has_no.errors(function() env.OnDriverRemovedFromProject() end)
			assert.equal(0, #messages(c4, "HUE_GOODBYE"))
		end)

		it("stops the Driver Version looks on destroy", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c4.config_info.version = ""
			env.OnDriverLateInit("DIT_STARTUP")
			local delays = {}
			for _, timer in ipairs(c4.active_timers()) do delays[#delays + 1] = timer.delay end
			assert.same({ SETUP_READ_MS, 5000 }, delays, "the read of the presets (#427 D19), the second look")
			env.OnDriverDestroyed("DIT_LOADED")
			assert.equal(0, #c4.active_timers(), "both stop")
		end)
	end)

	-- docs/review-leftovers-design.md #49: a command that never reaches the
	-- bridge (SendToDevice raising) closes the proxy's CHANGING with the
	-- unchanged state, and the error is logged.
	describe("a command the bridge never gets", function()
		-- From here on SendToDevice raises for HUE_SET and HUE_DIM; returns the
		-- commands it was asked to send.
		local function failing(c4)
			local tried = {}
			local original = c4.SendToDevice
			c4.SendToDevice = function(self, id, command, ...)
				if command == "HUE_SET" or command == "HUE_DIM" then
					tried[#tried + 1] = command
					error("Director says no")
				end
				return original(self, id, command, ...)
			end
			return tried
		end

		it("a brightness target closes its CHANGING with the unchanged level, logs, and arms no fallback", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local env, c4 = lit_light() -- on at 40 %
			local tried = failing(c4)
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "500" })
			assert.same({ "HUE_SET" }, tried)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 75, RATE = 500 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
			local logged = false
			for _, line in ipairs(lines) do
				if line:find("^%[ERROR%] Hue Light: HUE_SET to the bridge failed: .*Director says no") then logged = true end
			end
			assert.is_true(logged)
		end)

		it("closes with 0 a target for a light the bridge has not reported yet", function()
			local env, c4 = load_light({ rid = "l1" })
			configure(env)
			c4.calls = {}
			failing(c4)
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 0,
				LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"),
				"no preset named: the light is not at it")
		end)

		it("keeps a colour stored while off for the next turn-on when a turn-on fails", function()
			local env, c4 = lit_light()
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35",
				LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
			c4.calls = {}
			local original = c4.SendToDevice
			failing(c4)
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "0" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			c4.SendToDevice = original
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "0" })
			assert.same({ rid = "l1", on = "true", brightness = "60", rate = "0", x = "0.4", y = "0.35" },
				last_sent(c4).params)
		end)

		it("a colour target closes its CHANGING with the colour the light still has", function()
			local env, c4 = lit_light() -- white at 370 mirek
			failing(c4)
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35",
				LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "3000" })
			assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGING"))
			local ex, ey = c4:ColorCCTtoXY(1000000 / 370)
			assert.same({ { LIGHT_COLOR_CURRENT_X = ex, LIGHT_COLOR_CURRENT_Y = ey, LIGHT_COLOR_CURRENT_COLOR_MODE = 1 } },
				notifies(c4, "LIGHT_COLOR_CHANGED"))
			assert.equal(0, #c4.active_timers())
		end)

		it("a hold whose dim fails closes its CHANGING at the level it began from; the release sends nothing", function()
			local env, c4 = lit_light() -- on at 40 %
			local tried = failing(c4)
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time: the dim up fails
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers(), "no estimate ticking")
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			assert.same({ "HUE_DIM" }, tried, "no stop for a dim that never started")
			assert.same({ 1000 }, { c4.active_timers()[1].delay }, "only the click guard, no fallback")
			assert.equal(1, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("a hold from off whose turn-on fails does not dim up afterwards", function()
			local env, c4 = load_light({ rid = "l1" })
			configure(env)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", brightness = "40", online = "true" })
			c4.calls = {}
			local tried = failing(c4)
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time: the turn-on at 1 % fails
			assert.same({ "HUE_SET" }, tried)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers(), "no dim 600 ms later")
		end)

		it("a release whose stop fails still closes the hold through the fallback", function()
			local env, c4 = lit_light() -- on at 40 %
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the dim up goes out
			for _ = 1, 10 do c4.fire_timers() end -- the estimate reaches 60
			local tried = failing(c4)
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			assert.same({ "HUE_DIM" }, tried)
			c4.fire_timers()
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 60 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)
	end)

	describe("hidden aliases until 2.0 (no actions since 1.2, docs/simplify-actions-design.md §3.3)", function()
		-- The light_v2 proxy the fake's project gave this light: the consumer of
		-- the protocol driver's binding 5001, as on the controller.
		local function proxy_of(light_id)
			return assert(fake.project.devices[light_id].proxy_id, "the fake registers a proxy per loaded light")
		end

		it("Adopt Hue Name and Forget This Light answer sent by name too, as the dev loop sends them", function()
			local env, c4 = lit_light()
			env.ExecuteCommand("Adopt Hue Name", {})
			assert.same({ { proxy_of(LIGHT_ID), "Desk" } }, c4.calls_to("RenameDevice"))
			env.ExecuteCommand("Forget This Light", {})
			assert.equal(1, #messages(c4, "HUE_FORGET"))
		end)

		it("say in the log, in Debug Mode, which action of the Hue Bridge does the job now", function()
			local env = lit_light()
			local lines = {}
			log.set_debug(true)
			log.sink = function(line) lines[#lines + 1] = line end
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Light" })
			log.set_debug(false)
			log.sink = function() end
			local text = table.concat(lines, "\n")
			assert.truthy(text:find("Adopt Hue Name is a hidden alias until 2.0; Resolve Names on the Hue Bridge "
				.. "does this now", 1, true))
			assert.truthy(text:find("Forget This Light is a hidden alias until 2.0; Forget Device on the Hue Bridge "
				.. "does this now", 1, true))
		end)

		it("Adopt Hue Name renames the proxy device, not the protocol driver", function()
			local env, c4 = lit_light()
			local proxy_id = proxy_of(LIGHT_ID)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.same({ { proxy_id, "Desk" } }, c4.calls_to("RenameDevice"))
			assert.equal("Desk", fake.project.devices[proxy_id].name)
			assert.equal("Hue Light", fake.project.devices[LIGHT_ID].name, "the protocol driver keeps its name")
			assert.equal(string.format("Renamed device %d to Desk", proxy_id), fake.last_action(env))
		end)

		it("Adopt Hue Name refuses without a Hue name or without a proxy", function()
			local env, c4 = load_light({ rid = "l1" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.truthy(fake.last_action(env):find("^Not renamed: no Hue name known yet"))

			env, c4 = lit_light()
			c4.GetBoundConsumerDevices = function() return nil end -- nothing bound, as documented
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.equal("Not renamed: no light_v2 proxy is bound to binding 5001", fake.last_action(env))
		end)

		it("Forget This Light asks the bridge with HUE_FORGET", function()
			local env, c4 = lit_light()
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Light" })
			assert.same({ { id = BRIDGE_ID, command = "HUE_FORGET", params = { rid = "l1", device_id = "2001" } } },
				messages(c4, "HUE_FORGET"))
			assert.equal("Asked the bridge to forget this light; its answer sets Status", fake.last_action(env))
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"], "Status waits for HUE_FORGOTTEN")
		end)

		it("Forget This Light refuses when no bridge is bound", function()
			local env, c4 = load_light({ bind = false, rid = "l1" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Light" })
			assert.equal(0, #c4.sent)
			assert.equal("Not sent: not bound to a Hue Bridge", fake.last_action(env))
		end)
	end)

	describe("SET_BRIGHTNESS_STOP and SET_COLOR_STOP", function()
		-- #421 D7: a timed target is a ramp (D6), and the stop stops it at Hue.
		it("stops a timed target at Hue where the clock says the light is, and cancels the fallback (#421 D7)", function()
			local env, c4 = lit_light() -- on at 40 %
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "5000" })
			assert.equal(2, #c4.active_timers(), "the ramp's end and the fallback")
			c4.advance(2000) -- 35 points over 5 s: 14 in 2 s
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			assert.same({ stop_at("54") }, stops(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 54 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
			assert.equal(0, c4.fire_timers())
			assert.equal(1, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "no second CHANGED")
			assert.equal(2, #messages(c4, "HUE_SET"), "the start and the stop")
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "55.3" })
			assert.same({ LIGHT_BRIGHTNESS_CURRENT = 55 }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")[2],
				"the bridge's later word corrects the estimate")
		end)

		it("settles a target given at once by reporting the cached level, sending nothing, as before", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(1, #c4.active_timers())
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
			assert.equal(0, #dims(c4))
			assert.equal(1, #messages(c4, "HUE_SET"))
		end)

		it("assumes the target when nothing is cached yet, so the proxy never waits on a CHANGING", function()
			local env, c4 = load_light({ rid = "l1" })
			configure(env)
			c4.calls = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 75 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
		end)

		it("settles a pending colour target the same way", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35",
				LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "3000" })
			assert.equal(1, #c4.active_timers())
			env.ReceivedFromProxy(5001, "SET_COLOR_STOP", {})
			local changed = notifies(c4, "LIGHT_COLOR_CHANGED")
			assert.equal(1, #changed)
			assert.equal(1, changed[1].LIGHT_COLOR_CURRENT_COLOR_MODE, "the cached CCT, not the xy target")
			assert.equal(0, #c4.active_timers())
		end)

		it("reports the cached value even with no ramp in progress", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			env.ReceivedFromProxy(5001, "SET_COLOR_STOP", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGED"))
			assert.equal(0, #c4.sent)
		end)

		it("accepts STOP_SCENE_RAMP as a brightness stop", function()
			local env, c4 = lit_light() -- on at 40 %
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "5000" })
			c4.advance(2500) -- half way to off
			env.ReceivedFromProxy(5001, "STOP_SCENE_RAMP", {})
			assert.same({ stop_at("20") }, stops(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 20 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
			env.ReceivedFromProxy(5001, "STOP_SCENE_RAMP", {})
			assert.equal(1, #stops(c4), "no ramp left: a second stop only reports")
			assert.same({ LIGHT_BRIGHTNESS_CURRENT = 20 }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")[2])
		end)
	end)

	describe("driver.xml", function()
		local xml

		setup(function()
			local file = assert(io.open("src/hue_light/driver.xml"))
			xml = file:read("*a")
			file:close()
		end)

		local function capability(name)
			return xml:match("<" .. name .. ">%s*(%w+)%s*</" .. name .. ">")
		end

		it("joins Advanced Lighting Scenes as a reduced-ALS light with brightness and colour stop", function()
			assert.equal("True", capability("reduced_als_support"))
			assert.equal("False", capability("advanced_scene_support"))
			assert.equal("True", capability("supports_brightness_stop"))
			assert.equal("True", capability("supports_color_stop"))
			assert.equal("True", capability("supports_target"))
		end)

		it("declares the lifecycle properties and no actions (1.2, D3: the Hue Bridge has them)", function()
			local props = fake.declared_properties("hue_light")
			assert.equal("", props["Hue Room"])
			assert.equal("", props["Last Action"])
			assert.is_nil(xml:find("<action>", 1, true))
			assert.is_nil(xml:find("<actions>", 1, true))
			assert.is_nil(xml:find("<actions/>", 1, true))
		end)
	end)

	describe("HUE_STATE", function()
		it("maps on/off and brightness to LIGHT_BRIGHTNESS_CHANGED", function()
			local env, c4 = load_light()
			configure(env)
			c4.calls = {}
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "55", reason = "event" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 55 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
			assert.same({ LIGHT_BRIGHTNESS_CURRENT = 0 }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")[2])
			assert.equal(0, #notifies(c4, "LIGHT_COLOR_CHANGED"))
			assert.equal(0, #notifies(c4, "ONLINE_CHANGED"))
		end)

		it("maps xy colour to LIGHT_COLOR_CHANGED mode 0 and a CCT to mode 1", function()
			local env, c4 = load_light()
			configure(env)
			c4.calls = {}
			env.ExecuteCommand("HUE_STATE", { rid = "l1", x = "0.4", y = "0.35", color_mode = "xy" })
			assert.same({ { LIGHT_COLOR_CURRENT_X = 0.4, LIGHT_COLOR_CURRENT_Y = 0.35, LIGHT_COLOR_CURRENT_COLOR_MODE = 0 } },
				notifies(c4, "LIGHT_COLOR_CHANGED"))

			env.ExecuteCommand("HUE_STATE", { rid = "l1", mirek = "250", color_mode = "ct" })
			local ex, ey = c4:ColorCCTtoXY(4000)
			assert.same({ LIGHT_COLOR_CURRENT_X = ex, LIGHT_COLOR_CURRENT_Y = ey, LIGHT_COLOR_CURRENT_COLOR_MODE = 1 },
				notifies(c4, "LIGHT_COLOR_CHANGED")[2])
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("maps online to ONLINE_CHANGED and the Online property", function()
			local env, c4 = lit_light()
			env.ExecuteCommand("HUE_STATE", { rid = "l1", online = "false" })
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))
			assert.equal("Offline", env.Properties["Online"])
			env.ExecuteCommand("HUE_STATE", { rid = "l1", online = "true" })
			assert.same({ STATE = true }, notifies(c4, "ONLINE_CHANGED")[2])
			assert.equal("Online", env.Properties["Online"])
		end)

		it("says nothing when nothing the proxy sees has changed", function()
			local env, c4 = lit_light()
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40", mirek = "370",
				color_mode = "ct", online = "true", reason = "resync" })
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)

		it("ignores state for another rid", function()
			local env, c4 = lit_light()
			env.ExecuteCommand("HUE_STATE", { rid = "other", on = "false" })
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)
	end)

	-- #433 (docs/light-events-design.md D12 to D14, §6.5, §8.1): a level Hue
	-- reports while it moves (the Hue app's slider, a Hue dimmer switch, a Hue
	-- automation) reaches the proxy at most once per LEVEL_REPORT_MS window,
	-- the first at once and the latest, exact, at the window's end. An on or
	-- an off, the report that settles a Control4 target and a full state go
	-- out at once; every CHANGING drops a report still waiting; the cache
	-- always holds the latest level.
	describe("Hue-side level reports (#433)", function()
		local ZONE_RID = "b90ea7b4-aaaa-4bbb-8ccc-ddddeeeeffff"
		local ZONE = { rid = ZONE_RID, kind = "group", group_type = "zone", name = "Bedside Lights", light_count = "2",
			model = "Hue zone", hue_room = "Bedside Lights (zone)", id_v1 = "/groups/2", has_color = "true",
			has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }

		-- A HUE_STATE for `rid` (default "l1"), reason "event" unless `params` names one.
		local function hue(env, params, rid)
			params.rid = rid or "l1"
			params.reason = params.reason or "event"
			env.ExecuteCommand("HUE_STATE", params)
		end

		-- Every LIGHT_BRIGHTNESS_CURRENT the proxy heard as CHANGED, in order.
		local function levels(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")) do out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT end
			return out
		end

		-- From now on, every CHANGED as { ms since now on the fake clock, level }.
		local function timeline(c4)
			local out, start, original = {}, c4.now_ms, c4.SendToProxy
			c4.SendToProxy = function(self, binding, command, params, message_type)
				if binding == 5001 and command == "LIGHT_BRIGHTNESS_CHANGED" then
					out[#out + 1] = { c4.now_ms - start, params.LIGHT_BRIGHTNESS_CURRENT }
				end
				return original(self, binding, command, params, message_type)
			end
			return out
		end

		local function button(env, id, action)
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = tostring(id), ACTION = action })
		end

		-- Params of every HUE_SET sent, in order.
		local function sets_of(c4)
			local out = {}
			for _, m in ipairs(messages(c4, "HUE_SET")) do out[#out + 1] = m.params end
			return out
		end

		it("Hue-side level reports reach the proxy at most once a second, the last one exact", function()
			local env, c4 = lit_light() -- on at 40 %, the hello's window run out
			local start = c4.now_ms
			local seen = timeline(c4)
			-- The Hue app's slider dragged up for about 2 s: an event every
			-- 300 ms (the bridge sends at most about two containers a second).
			for i, level in ipairs({ "45", "50", "55", "60", "65", "70", "72.4" }) do
				if i > 1 then c4.advance(300) end
				hue(env, { brightness = level })
			end
			local let_go = c4.now_ms - start -- 1800
			c4.advance(5000)
			assert.same({ { 0, 45 }, { 1000, 60 }, { 2000, 72 } }, seen,
				"the first at once, then the latest level at each window's end")
			for i = 2, #seen do
				assert.is_true(seen[i][1] - seen[i - 1][1] >= LEVEL_REPORT_MS, "at most one a second")
			end
			assert.equal(72, seen[#seen][2], "the last one exact: Hue's 72.4 as the proxy's whole percent")
			assert.is_true(seen[#seen][1] - let_go <= LEVEL_REPORT_MS, "within a second of the last report")
			assert.equal(0, #c4.active_timers(), "a window that ends with nothing new closes")
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"), "Hue-side changes send no CHANGING")
		end)

		it("an off or an on from Hue goes to the proxy at once, inside a window", function()
			local env, c4 = lit_light()
			local seen = timeline(c4)
			hue(env, { brightness = "50" }) -- 0: at once, a window opens
			c4.advance(200)
			hue(env, { brightness = "55" }) -- 200: waits for the window's end
			c4.advance(200)
			hue(env, { on = "false" }) -- 400: off
			c4.advance(200)
			hue(env, { on = "true", brightness = "30" }) -- 600: on again
			assert.same({ { 0, 50 }, { 400, 0 }, { 600, 30 } }, seen, "on and off at once")
			c4.advance(5000)
			assert.same({ { 0, 50 }, { 400, 0 }, { 600, 30 } }, seen, "the 55 never shows: the off came after it")
		end)

		it("a report that settles a Control4 target goes out at once", function()
			-- The proxy heard CHANGING and waits for its CHANGED, even when the
			-- level is the one it shows already.
			local env, c4 = lit_light() -- on at 40 %
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
			hue(env, { brightness = "40.2" })
			assert.same({ 40 }, levels(c4))
			hue(env, { brightness = "45" }) -- a Hue-side level waits for the window the CHANGED opened
			assert.same({ 40 }, levels(c4))
			c4.advance(LEVEL_REPORT_MS)
			assert.same({ 40, 45 }, levels(c4))

			-- A hold's release has no CHANGING of its own: the stop's report
			-- settles it, also while Hue's levels of the dim wait in a window.
			env, c4 = lit_light()
			button(env, 0, "1")
			c4.advance(400) -- the hold: HUE_DIM up, CHANGING toward 100
			hue(env, { brightness = "45" }) -- Hue reports the dim as it goes: at once, a window opens
			c4.advance(300)
			hue(env, { brightness = "50" }) -- waits in the window
			button(env, 0, "0") -- the release: HUE_DIM stop, a target the bridge's report settles
			assert.equal("stop", dims(c4)[2].direction)
			hue(env, { brightness = "52.3" })
			assert.same({ 45, 52 }, levels(c4), "at once, inside the window")
			c4.advance(5000)
			assert.same({ 45, 52 }, levels(c4), "and never repeated")
		end)

		it("a resync or hello state is not throttled", function()
			local env, c4 = lit_light()
			hue(env, { brightness = "50" }) -- at once, a window opens
			hue(env, { on = "true", brightness = "60", reason = "resync" })
			hue(env, { on = "true", brightness = "65", reason = "hello" })
			hue(env, { on = "true", brightness = "70", reason = "import" })
			assert.same({ 50, 60, 65, 70 }, levels(c4), "each full state at once, inside the window")
			-- A report without a reason is Hue's word as it moves, as "event":
			-- it waits for the window the import's report started again.
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "75" })
			assert.same({ 50, 60, 65, 70 }, levels(c4))
			c4.advance(LEVEL_REPORT_MS)
			assert.same({ 50, 60, 65, 70, 75 }, levels(c4))
		end)

		it("a report from outside HUE_STATE goes at once, and the window's end does not repeat it", function()
			local env, c4 = lit_light()
			hue(env, { brightness = "50" }) -- at once, a window opens
			hue(env, { brightness = "55" }) -- waits
			env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
			assert.same({ 50, 55 }, levels(c4), "the proxy asked: the cache's level at once")
			c4.advance(5000)
			assert.same({ 50, 55 }, levels(c4), "it was the last level sent (D14)")
		end)

		it("a brightness command closes the window: no stale CHANGED during its ramp", function()
			local env, c4 = lit_light() -- on at 40 %
			hue(env, { brightness = "50" }) -- 0: at once, a window opens until 1000
			c4.advance(300)
			hue(env, { brightness = "55" }) -- 300: waits for the window's end
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "3000" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 55, LIGHT_BRIGHTNESS_TARGET = 80, RATE = 3000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"), "from the level the light is at, not the 50 the proxy shows")
			hue(env, { brightness = "80" }) -- Hue reports the target as the transition starts: held (#421 D10)
			c4.advance(2999)
			assert.same({ 50 }, levels(c4), "no 55 at the window's end, nothing while the tile animates")
			c4.advance(1)
			assert.same({ 50, 80 }, levels(c4), "the ramp's one CHANGED")
			c4.advance(5000)
			assert.same({ 50, 80 }, levels(c4))
		end)

		it("a hold's CHANGING closes the window", function()
			local env, c4 = lit_light() -- on at 40 %
			hue(env, { brightness = "50" }) -- 0: at once, a window opens until 1000
			c4.advance(300)
			hue(env, { brightness = "55" }) -- 300: waits for the window's end
			button(env, 1, "1")
			c4.advance(400) -- 700: the hold starts, down from the level the light is at
			local changing = notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")
			assert.same({ 55, 1 }, { changing[1].LIGHT_BRIGHTNESS_CURRENT, changing[1].LIGHT_BRIGHTNESS_TARGET })
			c4.advance(500) -- 1200: past the window's end
			assert.same({ 50 }, levels(c4), "no stale 55 while the tile animates the hold")
			button(env, 1, "0")
			hue(env, { brightness = "47.3" }) -- the stop's level
			assert.same({ 50, 47 }, levels(c4))
		end)

		it("a load group's CHANGING closes the window too (#435)", function()
			local env, c4 = lit_light() -- on at 40 %
			env.ReceivedFromProxy(5001, "JOIN_GROUP", { GROUP_ID = "1234", KEEP_SYNC = "0" })
			hue(env, { brightness = "50" }) -- 0: at once, a window opens until 1000
			c4.advance(300)
			hue(env, { brightness = "55" }) -- 300: waits for the window's end
			env.ReceivedFromProxy(5001, "GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1", RATE = "4000" })
			local changing = notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")
			assert.same({ 55, 100 }, { changing[1].LIGHT_BRIGHTNESS_CURRENT, changing[1].LIGHT_BRIGHTNESS_TARGET })
			c4.advance(1000) -- 1300: past the window's end
			assert.same({ 50 }, levels(c4), "no stale 55 while the tile animates the group's hold")
			env.ReceivedFromProxy(5001, "GROUP_STOP_RAMP", { GROUP_ID = "1234" })
			hue(env, { brightness = "70" }) -- the stop's level
			assert.same({ 50, 70 }, levels(c4))

			env.ReceivedFromProxy(5001, "GROUP_SET_LEVEL", { GROUP_ID = "1234", LEVEL = "20" })
			assert.equal(2, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"), "a group level is a target as any other")
		end)

		it("the LEDs follow an on or off from Hue at once", function()
			local env, c4 = lit_light() -- on at 40 %, the LEDs lit
			local captured = capture_proxy(c4)
			hue(env, { brightness = "50" }) -- at once, a window opens
			c4.advance(200)
			hue(env, { brightness = "55" }) -- waits; a level changes no LED
			assert.same({}, with_command(captured, "MATCH_LED_STATE"))
			hue(env, { on = "false" })
			assert.same(leds(false), with_command(captured, "MATCH_LED_STATE"), "off, inside the window")
			c4.advance(200)
			hue(env, { on = "true", brightness = "30" })
			local all = with_command(captured, "MATCH_LED_STATE")
			assert.same(leds(true), { all[4], all[5], all[6] }, "on again, inside the off's window")
			assert.equal(6, #all)
		end)

		it("Raise Level By reads the exact level while a report waits in the window", function()
			local env, c4 = lit_light() -- on at 40 %
			hue(env, { brightness = "50" }) -- at once, a window opens
			hue(env, { brightness = "55" }) -- the proxy still shows 50
			assert.same({ 50 }, levels(c4))
			env.ExecuteCommand("Raise Level By", { Points = "10", ["Ramp (ms)"] = "0" })
			assert.same({ { rid = "l1", on = "true", brightness = "65", rate = "0" } }, sets_of(c4),
				"55 + 10: the level the light is at")
			assert.truthy(fake.last_action(env):find("Raised from 55 % to 65 %", 1, true), fake.last_action(env))
		end)

		it("a zone light's level reports are throttled the same way", function()
			local env, c4 = load_light({ rid = ZONE_RID })
			env.ExecuteCommand("HUE_CONFIGURE", ZONE)
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "40", x = "0.4", y = "0.35",
				color_mode = "xy", online = "true", reason = "hello" })
			assert.equal(1, c4.fire_timers_of(LEVEL_REPORT_MS), "the hello's report opened a window")
			local seen = timeline(c4)
			hue(env, { brightness = "50" }, ZONE_RID) -- 0: at once
			c4.advance(300)
			hue(env, { brightness = "55" }, ZONE_RID) -- 300: waits
			c4.advance(300)
			hue(env, { brightness = "60.4" }, ZONE_RID) -- 600: waits
			c4.advance(600)
			hue(env, { on = "false" }, ZONE_RID) -- 1200: off, at once
			c4.advance(5000)
			assert.same({ { 0, 50 }, { 1000, 60 }, { 1200, 0 } }, seen)
		end)

		it("HUE_FORGOTTEN, an unbind from the bridge and destroy drop a report still waiting", function()
			for _, ending in ipairs({ "forgotten", "unbound", "destroyed" }) do
				local env, c4 = lit_light()
				hue(env, { brightness = "50" }) -- at once, a window opens
				hue(env, { brightness = "55" }) -- waits for the window's end
				if ending == "forgotten" then
					env.ExecuteCommand("HUE_FORGOTTEN", { rid = "l1", name = "Desk" })
				elseif ending == "unbound" then
					c4.bindings = {}
					env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
				else
					env.OnDriverDestroyed()
				end
				c4.advance(5000)
				assert.same({ 50 }, levels(c4), ending)
			end
		end)
	end)

	describe("SYNCHRONIZE", function()
		it("replays online, brightness and colour", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
			local calls = c4.calls_to("SendToProxy")
			assert.equal(3, #calls)
			assert.equal("ONLINE_CHANGED", calls[1][2])
			assert.same({ STATE = true }, calls[1][3])
			assert.same({ "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 40 } }, { calls[2][2], calls[2][3] })
			assert.equal("LIGHT_COLOR_CHANGED", calls[3][2])
			assert.equal(1, calls[3][3].LIGHT_COLOR_CURRENT_COLOR_MODE)
		end)

		it("replays only what is known", function()
			local env, c4 = load_light({ rid = "l1" })
			c4.calls = {}
			env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
			assert.equal(1, #c4.calls_to("SendToProxy"))
		end)
	end)

	describe("SET_BRIGHTNESS_TARGET", function()
		it("acknowledges with CHANGING, sends HUE_SET to the bridge, and falls back to CHANGED", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "500" })

			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 75, RATE = 500 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ id = BRIDGE_ID, command = "HUE_SET",
				params = { rid = "l1", on = "true", brightness = "75", rate = "500" } }, last_sent(c4))
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))

			local timers = c4.active_timers()
			assert.same({ 1500, 500 }, { timers[1].delay, timers[2].delay }, "the fallback (rate + 1000 ms), the ramp's end")
			c4.advance(500)
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "the ramp ran out unreported: the fallback waits")
			c4.advance(1000)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 75 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("turns the light off for target 0", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "0" })
			assert.same({ rid = "l1", on = "false", rate = "0" }, last_sent(c4).params)
			c4.fire_timers()
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("lets a confirming HUE_STATE send CHANGED and cancel the fallback, at the ramp's end (#421 D10)", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "75", reason = "event" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 75 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "at once")
			assert.same({ LEVEL_REPORT_MS }, delays_of(c4), "no fallback; only the level window it opened (#433 D12)")

			env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "500" })
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "75", reason = "event" })
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "held back while the ramp runs")
			c4.advance(499)
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			c4.advance(1)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 75 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
			assert.equal(0, c4.fire_timers())
			assert.equal(1, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "no second CHANGED")
		end)

		it("closes the proxy's transaction even when the target equals the current level", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
			c4.fire_timers()
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("corrects the proxy when a later report contradicts an assumed target", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			c4.fire_timers()
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40", reason = "resync" })
			assert.same({ LIGHT_BRIGHTNESS_CURRENT = 40 }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")[2])
		end)

		it("serves TOGGLE, ON, OFF, SET_LEVEL and RAMP_TO_LEVEL through the same path", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal("false", last_sent(c4).params.on, "on, so toggle turns off")
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.same({ rid = "l1", on = "true", brightness = "100", rate = "0" }, last_sent(c4).params)

			env.ReceivedFromProxy(5001, "OFF", {})
			assert.equal("false", last_sent(c4).params.on)
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal("100", last_sent(c4).params.brightness)
			env.ReceivedFromProxy(5001, "SET_LEVEL", { LEVEL = "20", TIME = "0" })
			assert.equal("20", last_sent(c4).params.brightness)
			env.ReceivedFromProxy(5001, "RAMP_TO_LEVEL", { LEVEL = "30", TIME = "4000" })
			assert.same({ rid = "l1", on = "true", brightness = "30", rate = "4000" }, last_sent(c4).params)
			assert.equal(6, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
		end)
	end)

	-- #233 (owner, 2026-11-08): ON and TOGGLE turn the light on at the On
	-- preset, the Default On Brightness a top keypad tap goes to [proxy
	-- reference: light_v2 TOGGLE, and the variable Default On Preset
	-- Brightness], at once as before; the click rates stay with keypad taps.
	describe("ON and TOGGLE at the Default On Brightness (#233)", function()
		-- The configured light off; Hue keeps its level, 70 %.
		local function dark_light(opts)
			local env, c4 = load_light(opts or { rid = "l1" })
			configure(env)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", brightness = "70", mirek = "370",
				color_mode = "ct", online = "true", reason = "hello" })
			c4.calls, c4.sent = {}, {}
			return env, c4
		end

		local function set_preset(env, c4, level)
			env.ReceivedFromProxy(5001, "SET_PRESET_LEVEL", { LEVEL = level })
			c4.calls, c4.sent = {}, {}
		end

		local function brightness_sent(c4)
			local sets = messages(c4, "HUE_SET")
			return sets[#sets] and sets[#sets].params.brightness
		end

		it("goes to 100 at once while the Default On Brightness was never set, exactly as before", function()
			local env, c4 = dark_light()
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ rid = "l1", on = "true", brightness = "100", rate = "0" }, last_sent(c4).params)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.same({ rid = "l1", on = "true", brightness = "100", rate = "0" }, last_sent(c4).params)
		end)

		it("ON from off goes to a changed Default On Brightness, at once, and the proxy hears that target", function()
			local env, c4 = dark_light()
			set_preset(env, c4, "40")
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ id = BRIDGE_ID, command = "HUE_SET",
				params = { rid = "l1", on = "true", brightness = "40", rate = "0" } }, last_sent(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 40, RATE = 0,
				LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"),
				"the On preset, id 1 (#429 D7)")
			c4.advance(1000) -- nothing from the bridge: the fallback assumes the target
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = 1 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("TOGGLE from off goes to it too; TOGGLE from on turns the light off at once", function()
			local env, c4 = dark_light()
			set_preset(env, c4, "40")
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.same({ rid = "l1", on = "true", brightness = "40", rate = "0" }, last_sent(c4).params)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40" })
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.same({ rid = "l1", on = "false", rate = "0" }, last_sent(c4).params)
		end)

		it("TOGGLE before the bridge reported the light goes to it, as to 100 before", function()
			local env, c4 = load_light({ rid = "l1" })
			configure(env)
			set_preset(env, c4, "40")
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal("40", brightness_sent(c4))
		end)

		it("ON on a light already on goes to it from a lower and from a higher level, as a top tap does", function()
			local env, c4 = lit_light() -- on at 40 %
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal("100", brightness_sent(c4), "the default: 100, as before")
			set_preset(env, c4, "60")
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ rid = "l1", on = "true", brightness = "60", rate = "0" }, last_sent(c4).params)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "85" })
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal("60", brightness_sent(c4), "down from 85")
		end)

		it("keeps the click rates for keypad taps: ON is at once, a top tap over the click rate up", function()
			local env, c4 = dark_light()
			set_preset(env, c4, "40")
			env.ReceivedFromProxy(5001, "SET_CLICK_RATE_UP", { RATE = "1500" })
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ rid = "l1", on = "true", brightness = "40", rate = "0" }, last_sent(c4).params)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.same({ rid = "l1", on = "true", brightness = "40", rate = "600", urgent = "true" }, last_sent(c4).params,
				"the click rate's share of the way from off to 40 (#421 D3)")
		end)

		it("uses the Default On Brightness persisted before a restart", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c4.persist.hue_rid = "l1"
			c4.persist.preset_level = 25
			env.OnDriverLateInit("DIT_STARTUP")
			configure(env)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", online = "true" })
			c4.sent = {}
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal("25", brightness_sent(c4))
		end)

		it("never turns the light off for ON: a refused 0 or text keeps the level in use; a stored 0 reads as 100", function()
			local env, c4 = dark_light()
			set_preset(env, c4, "0")
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ rid = "l1", on = "true", brightness = "100", rate = "0" }, last_sent(c4).params)
			set_preset(env, c4, "40")
			env.ReceivedFromProxy(5001, "SET_PRESET_LEVEL", { LEVEL = "bright" })
			assert.same({ { 5001, "40" } }, (function()
				local out = {}
				for _, args in ipairs(c4.calls_to("SendToProxy")) do
					if args[2] == "PRESET_LEVEL" then out[#out + 1] = { args[1], args[3] } end
				end
				return out
			end)(), "the level kept is reported back")
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal("false", last_sent(c4).params.on, "the ON is under way, so TOGGLE turns the light off")
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal("40", brightness_sent(c4))

			env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c4.persist.hue_rid = "l1"
			c4.persist.preset_level = 0 -- as the house had it for minutes on 2026-10-25 (#59)
			env.OnDriverLateInit("DIT_STARTUP")
			configure(env)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", online = "true" })
			c4.sent = {}
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal("100", brightness_sent(c4))
		end)

		it("takes a colour picked while off along, as any turn-on does", function()
			local env, c4 = dark_light()
			set_preset(env, c4, "40")
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35",
				LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ rid = "l1", on = "true", brightness = "40", rate = "0", x = "0.4", y = "0.35" },
				last_sent(c4).params)
		end)
	end)

	-- #308: the bridge's first event after a turn-on can carry the level the
	-- lamp had before it went off. The bridge sends only what changed, so an
	-- event with the on alone leaves that old level in the light's cache.
	describe("a turn-on from off waits for its level (#308)", function()
		-- A configured light the bridge reports off; Hue keeps its level, 70 %.
		local function dark_at_70(extra)
			local env, c4 = load_light({ rid = "l1" })
			configure(env, extra)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", brightness = "70", mirek = "370",
				color_mode = "ct", online = "true", reason = "hello" })
			assert(c4.fire_timers_of(LEVEL_REPORT_MS) == 1, "the hello's level window (#433 D12) runs out")
			c4.calls, c4.sent = {}, {}
			return env, c4
		end

		local function turn_on(env, target, rate)
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = target, RATE = rate })
		end

		local function hue_state(env, params)
			params.rid = "l1"
			env.ExecuteCommand("HUE_STATE", params)
		end

		-- Every LIGHT_BRIGHTNESS_CURRENT the proxy heard as CHANGED, in order.
		local function levels(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")) do
				out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT
			end
			return out
		end

		-- Every MATCH_LED_STATE the Top Button Link (200) heard, in order.
		local function led_states(c4)
			local out = {}
			for _, args in ipairs(c4.calls_to("SendToProxy")) do
				if args[1] == 200 and args[2] == "MATCH_LED_STATE" then
					out[#out + 1] = args[3].STATE
				end
			end
			return out
		end

		it("as seen on the house: off at 70, Raise Level By 30, an event with the on, then 30; never 70", function()
			local env, c4 = dark_at_70()
			env.ExecuteCommand("Raise Level By", { Points = "30", ["Ramp (ms)"] = "1000" })
			assert.same({ rid = "l1", on = "true", brightness = "30", rate = "1000" }, messages(c4, "HUE_SET")[1].params)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 30, RATE = 1000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ true }, led_states(c4), "the LEDs light as the ramp starts (#421 D10), never on a level")
			hue_state(env, { on = "true", reason = "event" })
			assert.same({}, levels(c4), "the 70 % the cache still holds is not shown")
			c4.advance(16)
			hue_state(env, { brightness = "30.2", reason = "event" })
			assert.same({}, levels(c4), "the target is held back until the 1 s ramp ends (#421 D10)")
			c4.advance(984)
			assert.same({ 30 }, levels(c4))
			assert.same({ true }, led_states(c4))
			assert.equal(0, #c4.active_timers(), "the fallback is settled")
			c4.advance(5000)
			assert.same({ 30 }, levels(c4))
		end)

		it("holds the old level whether an event spells it out or comes before the on", function()
			for _, first in ipairs({ { { on = "true", brightness = "70" } }, { { brightness = "70" }, { on = "true" } } }) do
				local env, c4 = dark_at_70()
				turn_on(env, "30", "0")
				for _, params in ipairs(first) do
					hue_state(env, params)
				end
				assert.same({}, levels(c4))
				hue_state(env, { brightness = "30" })
				assert.same({ 30 }, levels(c4))
			end
		end)

		it("lets the rest of a held event through: its colour and online", function()
			local env, c4 = dark_at_70()
			turn_on(env, "30", "0")
			hue_state(env, { on = "true", brightness = "70", x = "0.4", y = "0.35", color_mode = "xy", online = "false" })
			assert.same({}, levels(c4))
			assert.same({ { LIGHT_COLOR_CURRENT_X = 0.4, LIGHT_COLOR_CURRENT_Y = 0.35, LIGHT_COLOR_CURRENT_COLOR_MODE = 0 } },
				notifies(c4, "LIGHT_COLOR_CHANGED"))
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))
		end)

		it("lets an off through at once, also after a held event", function()
			local env, c4 = dark_at_70()
			turn_on(env, "30", "0")
			hue_state(env, { on = "false" })
			assert.same({ 0 }, levels(c4))
			assert.same({ LEVEL_REPORT_MS }, delays_of(c4), "no fallback; only the level window the report opened")

			env, c4 = dark_at_70()
			turn_on(env, "30", "0")
			hue_state(env, { on = "true", brightness = "70" })
			hue_state(env, { on = "false" })
			assert.same({ 0 }, levels(c4))
			assert.same({ LEVEL_REPORT_MS }, delays_of(c4), "no fallback; only the level window the report opened")
		end)

		it("shows a held level once the ramp plus 1 s passed without the target, and later ones at once", function()
			local env, c4 = dark_at_70()
			turn_on(env, "30", "1000")
			hue_state(env, { on = "true", brightness = "70" }) -- the Hue app, say, at the same moment
			c4.advance(1999)
			assert.same({}, levels(c4))
			c4.advance(1)
			assert.same({ 70 }, levels(c4), "what the bridge said, not the 30 the fallback would assume")
			hue_state(env, { brightness = "55" })
			assert.same({ 70, 55 }, levels(c4))
		end)

		it("still assumes the target at that time when the bridge said nothing", function()
			local env, c4 = dark_at_70()
			turn_on(env, "30", "1000")
			c4.advance(2000)
			assert.same({ 30 }, levels(c4))
			hue_state(env, { on = "true", brightness = "70" })
			assert.same({ 30, 70 }, levels(c4), "a report after the wait goes through")
		end)

		it("lets a level reported after the target through at once", function()
			local env, c4 = dark_at_70()
			turn_on(env, "30", "0")
			hue_state(env, { on = "true", brightness = "30" })
			hue_state(env, { brightness = "70" })
			-- Into the cache at once; to the proxy as a Hue-side level, at the
			-- end of the window the target's report opened (#433 D12).
			assert.same({ 30 }, levels(c4))
			c4.advance(LEVEL_REPORT_MS)
			assert.same({ 30, 70 }, levels(c4))
		end)

		it("holds a level on the way up until the ramp ends (#421 D10); without a ramp, until the target", function()
			local env, c4 = dark_at_70()
			turn_on(env, "80", "2000")
			hue_state(env, { on = "true", brightness = "20" })
			hue_state(env, { brightness = "80.3" })
			assert.same({}, levels(c4), "the tile animates from the CHANGING meanwhile")
			c4.advance(2000)
			assert.same({ 80 }, levels(c4))

			env, c4 = dark_at_70()
			turn_on(env, "80", "0")
			hue_state(env, { on = "true", brightness = "20" })
			assert.same({}, levels(c4))
			hue_state(env, { brightness = "80.3" })
			assert.same({ 80 }, levels(c4))
		end)

		it("waits for the Default On Brightness after ON or TOGGLE from off (#233)", function()
			for _, command in ipairs({ "ON", "TOGGLE" }) do
				local env, c4 = dark_at_70()
				env.ReceivedFromProxy(5001, "SET_PRESET_LEVEL", { LEVEL = "30" })
				env.ReceivedFromProxy(5001, command, {})
				assert.same({ rid = "l1", on = "true", brightness = "30", rate = "0" }, messages(c4, "HUE_SET")[1].params)
				hue_state(env, { on = "true", reason = "event" })
				assert.same({}, levels(c4), command .. ": the 70 % the cache still holds is not shown")
				hue_state(env, { brightness = "30.2", reason = "event" })
				assert.same({ 30 }, levels(c4))
				assert.same({ LEVEL_REPORT_MS }, delays_of(c4), "the fallback is settled; the level window is open")
			end
		end)

		it("takes the bulb's lowest level for a target below it (Hue raises the level to it)", function()
			local env, c4 = dark_at_70({ min_dim = "4" })
			turn_on(env, "1", "0")
			hue_state(env, { on = "true", brightness = "4" })
			assert.same({ 4 }, levels(c4))
		end)

		it("ends the wait with what the bridge said when the proxy stops a target given at once", function()
			local env, c4 = dark_at_70()
			turn_on(env, "30", "0")
			hue_state(env, { on = "true", brightness = "70" })
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			assert.same({ 70 }, levels(c4))
			assert.equal(0, #c4.active_timers())
		end)

		it("ends the wait at the estimate when the proxy stops a ramp; the old level never shows (#421 D7)", function()
			local env, c4 = dark_at_70()
			turn_on(env, "30", "1000")
			hue_state(env, { on = "true", brightness = "70" })
			c4.advance(500)
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			assert.same({ stop_at("15") }, stops(c4))
			assert.same({ 15 }, levels(c4))
			assert.equal(0, #c4.active_timers())
			hue_state(env, { brightness = "16.4" }) -- the bridge's own word, later
			assert.same({ 15, 16 }, levels(c4))
		end)

		it("does not move a keypad hold from off: the dim up starts from 1 %", function()
			local env, c4 = dark_at_70()
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time: the turn-on at 1 %
			hue_state(env, { on = "true", brightness = "70" })
			c4.fire_timers_of(600) -- the dim up
			local changing = notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")
			assert.same({ LIGHT_BRIGHTNESS_CURRENT = 1, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 4950 }, changing[#changing])
			assert.same({}, levels(c4))
		end)

		it("guards only a turn-on from off: a light already on shows every report", function()
			local env, c4 = lit_light()
			turn_on(env, "75", "0")
			hue_state(env, { brightness = "60" })
			assert.same({ 60 }, levels(c4))
		end)

		it("shows a light that never reports a level (a plug) on at once", function()
			local env, c4 = load_light({ rid = "l1" })
			configure(env, { has_color = "false", has_cct = "false" })
			hue_state(env, { on = "false", online = "true" })
			c4.calls = {}
			turn_on(env, "30", "0")
			hue_state(env, { on = "true" })
			assert.same({ 100 }, levels(c4))
		end)
	end)

	describe("SET_COLOR_TARGET", function()
		it("acknowledges with CHANGING and sends a mirek inside the bulb's range for mode 1", function()
			local env, c4 = lit_light()
			local x, y = c4:ColorCCTtoXY(3000)
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = tostring(x),
				LIGHT_COLOR_TARGET_Y = tostring(y), LIGHT_COLOR_TARGET_COLOR_MODE = "1", LIGHT_COLOR_TARGET_RATE = "200" })

			local changing = notifies(c4, "LIGHT_COLOR_CHANGING")
			assert.equal(1, #changing)
			assert.equal(1, changing[1].LIGHT_COLOR_TARGET_COLOR_MODE)
			assert.equal(200, changing[1].LIGHT_COLOR_TARGET_RATE)
			assert.equal(1, changing[1].LIGHT_COLOR_CURRENT_COLOR_MODE, "where it is coming from")

			local sent = last_sent(c4)
			assert.equal("HUE_SET", sent.command)
			assert.equal("l1", sent.params.rid)
			assert.equal("200", sent.params.rate)
			assert.is_nil(sent.params.x)
			local mirek = tonumber(sent.params.mirek)
			assert.is_true(mirek >= 153 and mirek <= 500)
			assert.is_true(math.abs(1000000 / mirek - 3000) < 150, "got " .. sent.params.mirek)

			assert.equal(1200, c4.active_timers()[1].delay)
			c4.fire_timers()
			local changed = notifies(c4, "LIGHT_COLOR_CHANGED")
			assert.equal(1, #changed)
			assert.equal(1, changed[1].LIGHT_COLOR_CURRENT_COLOR_MODE)
		end)

		it("passes xy through for mode 0 and lets a confirming HUE_STATE cancel the fallback", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35",
				LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
			assert.same({ rid = "l1", x = "0.4", y = "0.35", rate = "0" }, last_sent(c4).params)

			env.ExecuteCommand("HUE_STATE", { rid = "l1", x = "0.4", y = "0.35", color_mode = "xy" })
			assert.same({ { LIGHT_COLOR_CURRENT_X = 0.4, LIGHT_COLOR_CURRENT_Y = 0.35, LIGHT_COLOR_CURRENT_COLOR_MODE = 0 } },
				notifies(c4, "LIGHT_COLOR_CHANGED"))
			assert.equal(0, #c4.active_timers())
		end)

		it("tolerates the CIE 1931 spelling of the x key and a plain RATE", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X_CIE_1931 = "0.4",
				LIGHT_COLOR_TARGET_Y = "0.35", LIGHT_COLOR_TARGET_COLOR_MODE = "0", RATE = "100" })
			assert.same({ rid = "l1", x = "0.4", y = "0.35", rate = "100" }, last_sent(c4).params)
		end)

		it("takes a temperature pick as the Navigator sends it: LIGHT_COLOR_TARGET_MODE 1", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_MODE = "1", LIGHT_COLOR_TARGET_RATE = "0",
				LIGHT_COLOR_TARGET_X = "0.317097", LIGHT_COLOR_TARGET_Y = "0.327069" })
			local params = last_sent(c4).params
			assert.truthy(params.mirek, "a temperature pick becomes a colour temperature")
			assert.is_nil(params.x)
		end)

		it("stores the colour while off, closes with CHANGED, and sends it with the next turn-on", function()
			local env, c4 = lit_light()
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
			c4.calls = {}
			c4.sent = {}

			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35",
				LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
			assert.equal(0, #messages(c4, "HUE_SET"), "nothing goes to the bridge while off")
			assert.same({ LEVEL_REPORT_MS }, delays_of(c4), "no fallback; only the level window the off opened (#433)")
			assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGING"))
			assert.same({ { LIGHT_COLOR_CURRENT_X = 0.4, LIGHT_COLOR_CURRENT_Y = 0.35, LIGHT_COLOR_CURRENT_COLOR_MODE = 0 } },
				notifies(c4, "LIGHT_COLOR_CHANGED"))

			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "0" })
			assert.same({ rid = "l1", on = "true", brightness = "60", rate = "0", x = "0.4", y = "0.35" },
				last_sent(c4).params)
		end)
	end)

	describe("without a bridge", function()
		it("drops proxy commands and explains in Status when unbound", function()
			local env, c4 = load_light({ bind = false, rid = "l1" })
			c4.calls = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35" })
			assert.equal(0, #c4.sent)
			assert.equal(0, #c4.calls_to("SendToProxy"), "not even CHANGING")
			local timers = c4.active_timers()
			assert.equal(1, #timers, "only the binding re-check, no fallback")
			assert.equal(5000, timers[1].delay)
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
		end)

		it("drops proxy commands while bound but not yet assigned a light", function()
			local env, c4 = load_light()
			c4.sent = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(0, #c4.sent)
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
		end)

		it("does not error on unknown proxy commands", function()
			local env = lit_light()
			assert.has_no.errors(function()
				env.ReceivedFromProxy(5001, "SOMETHING_NEW", {})
			end)
		end)
	end)

	describe("DEV_RELOAD", function()
		it("hands the bundle to the dev loop when the build has one with apply_forwarded", function()
			local env = lit_light()
			local got
			with_apply_forwarded(function(params) got = params end, function()
				env.ExecuteCommand("DEV_RELOAD", { version = "7", files = "{}" })
				assert.same({ version = "7", files = "{}" }, got)
			end)
		end)

		it("logs the new version at info after a successful reload, forwarded to the bridge", function()
			local env, c4 = load_light({ rid = "l1", props = { ["Debug Mode"] = "On" } })
			c4.sent = {}
			with_apply_forwarded(function() return true end, function()
				env.ExecuteCommand("DEV_RELOAD", { version = "7", files = "{}" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_LOG",
					params = { rid = "l1", line = "Hue Light: light reloaded to version 7" } } }, c4.sent)
			end)
		end)

		it("warns, forwarded, when the reload fails", function()
			local env, c4 = lit_light()
			with_apply_forwarded(function() return false end, function()
				env.ExecuteCommand("DEV_RELOAD", { version = "8", files = "{}" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_LOG",
					params = { rid = "l1", line = "[WARN] Hue Light: light reload failed; see this light's Lua output" } } },
					c4.sent)
			end)
		end)
	end)

	-- Dev builds (common/devloop.lua is present here, as in the test tree)
	-- forward the light's log lines to the bridge as HUE_LOG.
	describe("dev log forwarding", function()
		after_each(function() log.set_debug(false) end)

		it("buffers lines logged before the bridge is known and flushes them after HUE_HELLO", function()
			local env, c4 = load_light({ bind = false, rid = "l1", props = { ["Debug Mode"] = "On" } })
			local sends = capture_sends(c4)
			log.info("warming up")
			assert.equal(0, #c4.sent, "nowhere to send yet")

			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			assert.equal(3, #sends)
			assert.equal("HUE_HELLO", sends[1].command)
			assert.same({ id = BRIDGE_ID, command = "HUE_LOG",
				params = { rid = "l1", line = "[INFO] Hue Light: warming up" },
				allow_empty = false, log_command = false }, sends[2], "allowEmptyValues and logCommand off")
			assert.equal("HUE_LOAD_GROUPS", sends[3].command, "the load groups follow the hello (#435)")
		end)

		it("keeps only the newest 30 lines while the bridge is unknown", function()
			local env, c4 = load_light({ bind = false, rid = "l1", props = { ["Debug Mode"] = "On" } })
			for i = 1, 35 do
				log.info("line %d", i)
			end
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			local logs = messages(c4, "HUE_LOG")
			assert.equal(30, #logs)
			assert.equal("[INFO] Hue Light: line 6", logs[1].params.line)
			assert.equal("[INFO] Hue Light: line 35", logs[30].params.line)
		end)

		it("never forwards debug lines, buffered or bound", function()
			local env, c4 = load_light({ bind = false, rid = "l1", props = { ["Debug Mode"] = "On" } })
			log.debug("noise before binding")
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			log.debug("noise after binding")
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true" }) -- dispatch logs it at debug
			assert.equal(0, #messages(c4, "HUE_LOG"))
			assert.same({ "HUE_HELLO", "HUE_LOAD_GROUPS" }, { c4.sent[1].command, c4.sent[2].command })
			assert.equal(2, #c4.sent, "just the HUE_HELLO and its HUE_LOAD_GROUPS (#435)")
		end)

		it("sends lines straight through once bound, log.always included", function()
			local _, c4 = lit_light()
			log.warn("something odd")
			log.always("diagnostic")
			assert.same({
				{ id = BRIDGE_ID, command = "HUE_LOG", params = { rid = "l1", line = "[WARN] Hue Light: something odd" } },
				{ id = BRIDGE_ID, command = "HUE_LOG", params = { rid = "l1", line = "Hue Light: diagnostic" } },
			}, c4.sent)
		end)

		it("omits rid while the light has none", function()
			local _, c4 = load_light()
			c4.sent = {}
			log.warn("no light yet")
			assert.same({ { id = BRIDGE_ID, command = "HUE_LOG", params = { line = "[WARN] Hue Light: no light yet" } } },
				c4.sent)
		end)

		it("still feeds the previous sink", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			lit_light()
			log.warn("both places")
			assert.same({ "[WARN] Hue Light: both places" }, lines)
		end)

		it("reports a failing HUE_LOG send once, through print, without forwarding the failure", function()
			local printed = {}
			local real_print = print
			_G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
			local ok, err = pcall(function()
				local _, c4 = lit_light()
				local original = c4.SendToDevice
				c4.SendToDevice = function(self, id, command, ...)
					if command == "HUE_LOG" then error("Director says no") end
					return original(self, id, command, ...)
				end
				log.warn("one")
				log.warn("two")
				assert.equal(0, #c4.sent)
				assert.equal(1, #printed)
				assert.truthy(printed[1]:find("log forwarding to the bridge failed", 1, true))
				assert.truthy(printed[1]:find("Director says no", 1, true))
			end)
			_G.print = real_print
			assert(ok, err)
		end)

		it("leaves log.sink alone in a release build (no dev loop module)", function()
			local sink = function() end
			log.sink = sink
			-- A preload loader that fails the way a missing module does.
			package.preload["common.devloop"] = function() error("module 'common.devloop' not found: release build") end
			local ok, err = pcall(function()
				local _, c4 = load_light({ rid = "l1" })
				assert.equal(sink, log.sink)
				log.warn("stays local")
				assert.equal(0, #messages(c4, "HUE_LOG"))
			end)
			package.preload["common.devloop"] = nil
			assert(ok, err)
		end)
	end)

	describe("keypad buttons (BUTTON_ACTION)", function()
		local function press_and_click(env, button)
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = tostring(button), ACTION = "1" })
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = tostring(button), ACTION = "2" })
		end

		it("echoes every press and release to the proxy", function()
			local env, c4 = lit_light()
			c4.calls = {}
			press_and_click(env, 0)
			local echoes = notifies(c4, "BUTTON_ACTION")
			assert.equal(2, #echoes)
			assert.equal(1, echoes[1].ACTION)
			assert.equal(2, echoes[2].ACTION)
			assert.equal(0, echoes[2].BUTTON_ID)
		end)

		it("tap top ramps to the On preset over the click rate's share; tap bottom ramps off (#421 D3)", function()
			local env, c4 = lit_light() -- on at 40 %
			c4.sent = {}
			press_and_click(env, 0)
			assert.equal(1, #messages(c4, "HUE_SET"))
			assert.same({ rid = "l1", on = "true", brightness = "100", rate = "1800", urgent = "true" },
				messages(c4, "HUE_SET")[1].params, "the default 3000 ms is the whole range: 60 points take 1800")
			c4.advance(1800) -- the ramp runs out
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" })
			c4.sent = {}
			press_and_click(env, 1)
			assert.same({ rid = "l1", on = "false", rate = "3000", urgent = "true" }, messages(c4, "HUE_SET")[1].params)
		end)

		it("uses a preset and click rate set through the proxy, and persists them", function()
			local env, c4 = lit_light() -- on at 40 %
			env.ReceivedFromProxy(5001, "SET_PRESET_LEVEL", { LEVEL = "60" })
			env.ReceivedFromProxy(5001, "SET_CLICK_RATE_UP", { RATE = "1500" })
			assert.equal(60, c4.persist.preset_level)
			assert.equal(1500, c4.persist.click_rate_up)
			c4.sent = {}
			press_and_click(env, 0)
			assert.equal("60", tostring(messages(c4, "HUE_SET")[1].params.brightness))
			assert.equal("300", tostring(messages(c4, "HUE_SET")[1].params.rate), "20 points of 1500 ms")
		end)

		it("a held top button dims up with HUE_DIM over the hold rate; the release stops at the estimate", function()
			local env, c4 = lit_light() -- on at 40 %
			c4.sent = {}
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			assert.equal(0, #c4.sent, "nothing until the hold timer")
			c4.fire_timers() -- the 400 ms hold timer: the ramp starts
			assert.same({ { rid = "l1", direction = "up", duration = "5000" } }, dims(c4),
				"the whole range over the whole hold rate")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"), "the tile: the 60 % left over 60 % of 5000 ms")
			for _ = 1, 10 do c4.fire_timers() end -- ten 100 ms ticks: about a third of the way
			c4.sent = {}
			c4.calls = {}
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "0" })
			assert.same({ { rid = "l1", direction = "stop", level = "60" } }, dims(c4))
			assert.equal(0, #messages(c4, "HUE_SET"), "no absolute target for a hold any more")
			assert.equal(2, #c4.active_timers(), "the brightness fallback and the click guard; no blend follows")
			c4.fire_timers() -- no report from the bridge: the estimate is assumed
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 60 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("a HUE_STATE after the stop settles it, and the estimate is never assumed", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			c4.fire_timers()
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "0" })
			c4.calls = {}
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "47" })
			c4.fire_timers()
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 47 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("a held bottom button dims down toward 1, never off", function()
			local env, c4 = lit_light()
			c4.sent = {}
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "1" })
			c4.fire_timers()
			assert.same({ { rid = "l1", direction = "down", duration = "5000" } }, dims(c4), "the whole range")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 1, RATE = 1950 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"), "the tile: 39 % of 5000 ms")
			assert.equal(0, #messages(c4, "HUE_SET"))
		end)

		-- Issue #232: Hue was sent the tile's share of the hold rate with the
		-- whole range (the bridge always asks for brightness_delta 100,
		-- commands.body), so from 50 % it ran at twice the tile's speed.
		it("a hold from 50 % moves Hue at the tile's speed, the whole range per hold rate (#232)", function()
			for _, case in ipairs({
				{ button = "0", direction = "up", duration = "5000", to = 100, rate = 2500, level = "70" },
				{ button = "1", direction = "down", duration = "5000", to = 1, rate = 2450, level = "30" },
				{ button = "0", hold_rate = "2000", direction = "up", duration = "2000", to = 100, rate = 1000,
					level = "100" },
			}) do
				local env, c4 = load_light({ rid = "l1" })
				configure(env)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "50", online = "true" })
				if case.hold_rate then
					env.ReceivedFromProxy(5001, "SET_HOLD_RATE_UP", { RATE = case.hold_rate })
				end
				c4.calls, c4.sent = {}, {}
				env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = case.button, ACTION = "1" })
				c4.fire_timers() -- the hold time
				local dim = dims(c4)[1]
				local changing = notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[1]
				assert.same({ rid = "l1", direction = case.direction, duration = case.duration }, dim)
				assert.same({ LIGHT_BRIGHTNESS_CURRENT = 50, LIGHT_BRIGHTNESS_TARGET = case.to, RATE = case.rate },
					changing)
				local hue_per_ms = 100 / tonumber(dim.duration)
				local tile_per_ms = math.abs(case.to - 50) / changing.RATE
				assert.is_true(math.abs(hue_per_ms - tile_per_ms) < 1e-9,
					string.format("Hue %.4f %%/ms, the tile %.4f %%/ms", hue_per_ms, tile_per_ms))
				for _ = 1, 10 do c4.fire_timers() end -- ten 100 ms ticks: one second
				env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = case.button, ACTION = "0" })
				assert.same({ rid = "l1", direction = "stop", level = case.level }, dims(c4)[2],
					"the estimate after a second, where Hue is at that speed")
			end
		end)

		-- Issue #234: a light's hold had no upper bound, while the bridge holds a
		-- zone light's and a scene's to 6 000 000 ms. Since #430 D20 that is the
		-- most the proxy can set (hold_rate_max), and common/device.lua refuses more.
		it("holds over a hold rate of 6 000 000 ms, the bound, for Hue and the tile alike (#234, #430)", function()
			local env, c4 = lit_light() -- on at 40 %
			env.ReceivedFromProxy(5001, "SET_HOLD_RATE_UP", { RATE = "6000000" })
			assert.same({ "6000000" }, notifies(c4, "HOLD_RATE_UP"), "a valid setting, kept and shown as set")
			c4.calls, c4.sent = {}, {}
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time
			assert.same({ { rid = "l1", direction = "up", duration = "6000000" } }, dims(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3600000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"), "60 % of the bound")
		end)

		it("refuses a hold rate above 6 000 000 ms and keeps the one in use (#430 D20)", function()
			local env, c4 = lit_light() -- on at 40 %
			env.ReceivedFromProxy(5001, "SET_HOLD_RATE_UP", { RATE = "86400000" })
			assert.same({ "5000" }, notifies(c4, "HOLD_RATE_UP"), "the rate kept is shown again")
			c4.calls, c4.sent = {}, {}
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time
			assert.same({ { rid = "l1", direction = "up", duration = "5000" } }, dims(c4))
		end)

		it("a release-as-click after a hold stops the dim instead of tapping", function()
			local env, c4 = lit_light()
			c4.sent = {}
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			c4.fire_timers()
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "2" })
			assert.same({ "up", "stop" }, { dims(c4)[1].direction, dims(c4)[2].direction })
			assert.equal(0, #messages(c4, "HUE_SET"))
		end)
	end)

	describe("keypad holds from off and the click guard", function()
		-- A configured light, reported off.
		local function dark_light()
			local env, c4 = load_light({ rid = "l1" })
			configure(env)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", brightness = "40", online = "true" })
			c4.calls = {}
			c4.sent = {}
			return env, c4
		end

		it("holding top while off turns on at 1 % at once, then dims up 600 ms later", function()
			local env, c4 = dark_light()
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time
			assert.same({ { id = BRIDGE_ID, command = "HUE_SET",
				params = { rid = "l1", on = "true", brightness = "1", rate = "0" } } }, c4.sent)
			local timers = c4.calls_to("SetTimer")
			assert.same({ 600, false }, timers[#timers])
			assert.equal(0, #dims(c4))
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "1" })
			c4.fire_timers() -- 600 ms later
			assert.same({ { rid = "l1", direction = "up", duration = "5000" } }, dims(c4))
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			assert.equal("stop", dims(c4)[2].direction)
		end)

		it("a release before the delayed dim cancels it and sends no stop", function()
			local env, c4 = dark_light()
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			c4.fire_timers()
			assert.equal(1, #messages(c4, "HUE_SET"))
			assert.equal(0, #dims(c4))
		end)

		it("holding bottom while off sends nothing, nor does the click after it", function()
			local env, c4 = dark_light()
			env.ReceivedFromProxy(201, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(201, "DO_RELEASE", {})
			env.ReceivedFromProxy(201, "DO_CLICK", {})
			assert.same({}, c4.sent)
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
		end)

		it("holding toggle dims down while on and up while off", function()
			local env, c4 = lit_light()
			c4.sent = {}
			env.ReceivedFromProxy(202, "DO_PUSH", {})
			c4.fire_timers()
			assert.equal("down", dims(c4)[1].direction)
			env.ReceivedFromProxy(202, "DO_RELEASE", {})
			env, c4 = dark_light()
			env.ReceivedFromProxy(202, "DO_PUSH", {})
			c4.fire_timers()
			assert.equal("1", messages(c4, "HUE_SET")[1].params.brightness)
		end)

		it("ignores a click on the same button within 1 s after a hold's release, not on another", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			local timers = c4.calls_to("SetTimer")
			assert.same({ 1000, false }, timers[#timers])
			c4.sent = {}
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.same({}, c4.sent, "the keypad's click after the hold")
			env.ReceivedFromProxy(201, "DO_CLICK", {})
			assert.equal("false", messages(c4, "HUE_SET")[1].params.on, "another button is not guarded")
			c4.fire_timers() -- 1 s later
			c4.sent = {}
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.equal("100", messages(c4, "HUE_SET")[1].params.brightness)
		end)

		it("cancels the hold, the guard and the fallback on destroy", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			env.OnDriverDestroyed()
			assert.equal(0, #c4.active_timers())
		end)
	end)

	-- #421 (docs/tap-stop-design.md): a keypad tap ramps the light over its
	-- click rate's share of the distance, and a press outside the double-tap
	-- window while any timed brightness change runs stops it where it is.
	-- The press machine is common/device.lua's (§4.1); the ramp is the
	-- driver's (§4.2). Two taps on one button stand more than DOUBLE_TAP_MS
	-- apart on the fake clock unless a spec says otherwise.
	describe("tap ramps and tap stops (#421)", function()
		-- A configured light the bridge reports on at `level` (a string keeps
		-- Hue's decimals), or off for 0 (Hue keeps 70); `settings` go through
		-- the proxy first: { preset = 60, up = 2000, down = 4000 } (ms).
		local function light(level, settings)
			local env, c4 = load_light({ rid = "l1" })
			configure(env)
			local on = tonumber(level) > 0
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = tostring(on), brightness = on and tostring(level) or "70",
				mirek = "370", color_mode = "ct", online = "true", reason = "hello" })
			assert(c4.fire_timers_of(LEVEL_REPORT_MS) == 1, "the hello's level window (#433 D12) runs out")
			settings = settings or {}
			if settings.preset then
				env.ReceivedFromProxy(5001, "SET_PRESET_LEVEL", { LEVEL = tostring(settings.preset) })
			end
			if settings.up then
				env.ReceivedFromProxy(5001, "SET_CLICK_RATE_UP", { RATE = tostring(settings.up) })
			end
			if settings.down then
				env.ReceivedFromProxy(5001, "SET_CLICK_RATE_DOWN", { RATE = tostring(settings.down) })
			end
			c4.calls, c4.sent = {}, {}
			return env, c4
		end

		local function action(env, button, act)
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = tostring(button), ACTION = act })
		end
		local function press(env, button) action(env, button, "1") end
		local function click(env, button) action(env, button, "2") end
		local function release(env, button) action(env, button, "0") end
		local function tap(env, button)
			press(env, button)
			click(env, button)
		end

		-- Params of every HUE_SET sent, in order.
		local function sets(c4)
			local out = {}
			for _, m in ipairs(messages(c4, "HUE_SET")) do out[#out + 1] = m.params end
			return out
		end

		-- Every LIGHT_BRIGHTNESS_CURRENT the proxy heard as CHANGED, in order.
		local function levels(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")) do out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT end
			return out
		end

		-- Every CHANGING as { current, target, rate }, in order.
		local function changing(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")) do
				out[#out + 1] = { p.LIGHT_BRIGHTNESS_CURRENT, p.LIGHT_BRIGHTNESS_TARGET, p.RATE }
			end
			return out
		end

		-- Every MATCH_LED_STATE the Top Button Link (200) heard, in order.
		local function led_states(c4)
			local out = {}
			for _, args in ipairs(c4.calls_to("SendToProxy")) do
				if args[1] == 200 and args[2] == "MATCH_LED_STATE" then out[#out + 1] = args[3].STATE end
			end
			return out
		end

		describe("idle taps (§3)", function()
			it("top or toggle from off ramps to the preset over the click rate up's share of it", function()
				for _, button in ipairs({ 0, 2 }) do
					local env, c4 = light(0, { preset = 40, up = 2000, down = 4000 })
					tap(env, button)
					assert.same({ { rid = "l1", on = "true", brightness = "40", rate = "800", urgent = "true" } }, sets(c4),
						"button " .. button)
					assert.same({ { 0, 40, 800 } }, changing(c4))
				end
			end)

			it("top below the preset ramps up to it over the click rate up's share of the distance", function()
				local env, c4 = light(40, { preset = 60, up = 2000, down = 4000 })
				tap(env, 0)
				assert.same({ { rid = "l1", on = "true", brightness = "60", rate = "400", urgent = "true" } }, sets(c4))
				assert.same({ { 40, 60, 400 } }, changing(c4))
			end)

			it("top above the preset ramps down to it over the click rate down's share of the distance (D2)", function()
				local env, c4 = light(85, { preset = 60, up = 2000, down = 4000 })
				tap(env, 0)
				assert.same({ { rid = "l1", on = "true", brightness = "60", rate = "1000", urgent = "true" } }, sets(c4))
				assert.same({ { 85, 60, 1000 } }, changing(c4))
			end)

			it("top at the preset, within a point, sends nothing to Hue and reports the level", function()
				for _, case in ipairs({ { "59", 59 }, { "60.4", 60 }, { "61", 61 } }) do
					local env, c4 = light(case[1], { preset = 60 })
					tap(env, 0)
					assert.same({}, sets(c4), case[1])
					assert.same({}, changing(c4))
					assert.same({ case[2] }, levels(c4))
					assert.same({ DOUBLE_TAP_MS }, delays_of(c4), "no ramp, no fallback: only the tap's count (#432 D6)")
				end
				local env, c4 = light(62, { preset = 60 })
				tap(env, 0)
				assert.same({ { rid = "l1", on = "true", brightness = "60", rate = "60", urgent = "true" } }, sets(c4),
					"two points down at the default 3000 ms")
			end)

			it("bottom, or toggle while on, ramps off over the click rate down's share of the level", function()
				for _, button in ipairs({ 1, 2 }) do
					local env, c4 = light(40, { down = 4000 })
					tap(env, button)
					assert.same({ { rid = "l1", on = "false", rate = "1600", urgent = "true" } }, sets(c4), "button " .. button)
					assert.same({ { 40, 0, 1600 } }, changing(c4))
				end
			end)

			it("bottom while off does nothing", function()
				local env, c4 = light(0)
				tap(env, 1)
				assert.same({}, sets(c4))
				assert.same({}, changing(c4))
				assert.same({}, levels(c4))
			end)

			it("a click rate of 0 changes the light at once, with nothing to stop", function()
				local env, c4 = light(40, { up = 0 })
				tap(env, 0)
				assert.same({ { rid = "l1", on = "true", brightness = "100", rate = "0", urgent = "true" } }, sets(c4))
				tap(env, 1)
				assert.equal(0, #stops(c4), "no ramp ran: the bottom press is a tap, not a stop")
				assert.equal("false", sets(c4)[2].on)
			end)

			it("the default click rates are 3000 ms for the whole range (D3)", function()
				local env, c4 = light(0)
				tap(env, 0)
				assert.same({ { 0, 100, 3000 } }, changing(c4))
				c4.advance(3000)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" })
				tap(env, 1)
				assert.same({ 100, 0, 3000 }, changing(c4)[2])
			end)
		end)

		describe("the stop (§3, D5 to D8)", function()
			it("a press outside the window, on any button, stops the ramp by the clock and swallows its click", function()
				for _, button in ipairs({ 0, 1, 2 }) do
					local env, c4 = light(40) -- the top tap: 40 to 100 over 1800 ms
					tap(env, 0)
					c4.advance(900)
					press(env, button)
					assert.same({ stop_at("70") }, stops(c4), "button " .. button)
					assert.same({ 70 }, levels(c4), "the estimate at once")
					click(env, button)
					assert.equal(2, #sets(c4), "the start and the stop: the click is swallowed")
					assert.same({ DOUBLE_TAP_MS }, delays_of(c4),
						"no ramp, no fallback: the CHANGED is sent; only the stopping press's tap count (#432 D8)")
					c4.advance(5000)
					assert.same({ 70 }, levels(c4), "one CHANGED for the ramp")
					env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "68.6" })
					assert.same({ 70, 69 }, levels(c4), "the bridge's next report corrects the estimate")
				end
			end)

			it("a press within the window of the same button starts and stops nothing: the ramp goes on (D4)", function()
				local env, c4 = light(40)
				tap(env, 0)
				c4.advance(300)
				tap(env, 0) -- a double tap: the keypad's own event
				assert.equal(1, #sets(c4))
				assert.equal(0, #stops(c4))
				assert.same({}, levels(c4))
				c4.advance(300)
				press(env, 1)
				assert.same({ stop_at("60") }, stops(c4), "still ramping: 600 of 1800 ms")
			end)

			it("a stopping press held on holds from the stopped level: top up, bottom down, toggle by the on state", function()
				for _, case in ipairs({ { 0, "up", { 70, 100, 1500 } }, { 1, "down", { 70, 1, 3450 } },
					{ 2, "down", { 70, 1, 3450 } } }) do
					local env, c4 = light(40)
					tap(env, 0)
					c4.advance(900)
					press(env, case[1])
					c4.advance(400) -- the hold time
					assert.same({ stop_at("70") }, stops(c4))
					assert.same({ { rid = "l1", direction = case[2], duration = "5000" } }, dims(c4),
						"button " .. case[1])
					local all = changing(c4)
					assert.same(case[3], all[#all])
					release(env, case[1])
					assert.same({ rid = "l1", direction = "stop", level = "70" }, dims(c4)[2], "the hold's own stop")
				end
			end)

			it("rounds the estimate to a whole level", function()
				for _, case in ipairs({ { 435, "55" }, { 434, "54" } }) do -- 54.5 and 54.47
					local env, c4 = light(40)
					tap(env, 0)
					c4.advance(case[1])
					press(env, 1)
					assert.same({ stop_at(case[2]) }, stops(c4), case[1] .. " ms")
				end
			end)

			it("stops at 1 % at the start of a ramp from off and near the end of one to off: the light stays on", function()
				local env, c4 = light(0)
				tap(env, 0)
				press(env, 1) -- 0 % elapsed
				assert.same({ stop_at("1") }, stops(c4))
				assert.same({ 1 }, levels(c4))

				env, c4 = light(40)
				tap(env, 1) -- 40 to off over 1200 ms
				c4.advance(1190)
				press(env, 0)
				assert.same({ stop_at("1") }, stops(c4), "0.33 rounds to 0, and a stop never turns the light off")
				assert.same({ 1 }, levels(c4))
				assert.same({}, led_states(c4), "the LEDs never went off")
			end)

			it("stops near 100 % elapsed at the target's level", function()
				local env, c4 = light(40)
				tap(env, 0)
				c4.advance(1799)
				press(env, 1)
				assert.same({ stop_at("100") }, stops(c4))
			end)

			it("stops with the estimate as a level over a 1000 ms glide, and stays idle through it (D9, §7)", function()
				local env, c4 = light(40)
				tap(env, 0)
				c4.advance(900)
				press(env, 1)
				assert.same({ rid = "l1", on = "true", brightness = "70", rate = "1000", urgent = "true" }, sets(c4)[2],
					"a glide, not a jump: Hue's fade runs a little behind the estimate")
				assert.equal(0, #dims(c4), "no dimming_delta stop")
				assert.same({ 70 }, levels(c4))
				assert.same({ 400, DOUBLE_TAP_MS }, delays_of(c4),
					"only the press's hold timer and its tap count (#432 D6): the glide is no ramp and arms no fallback")
				click(env, 1)
				assert.equal(2, #sets(c4))
				-- The bridge reports the estimate at once: it matches, so no second CHANGED.
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "70.08", reason = "event" })
				assert.same({ 70 }, levels(c4))
				c4.advance(700)
				tap(env, 1) -- idle: a tap, not a stop
				assert.same({ rid = "l1", on = "false", rate = "2100", urgent = "true" }, sets(c4)[3])
			end)

			it("STOP_MODE \"stop\" (D8), the alternative: HUE_DIM stop with the estimate", function()
				local env, c4 = load_light_stop_mode({ rid = "l1" })
				configure(env)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40", online = "true" })
				c4.calls, c4.sent = {}, {}
				tap(env, 0)
				c4.advance(900)
				press(env, 1)
				assert.same({ { rid = "l1", direction = "stop", level = "70" } }, dims(c4))
				assert.equal(1, #sets(c4), "the start only")
				assert.same({ 70 }, levels(c4))
				click(env, 1)
				assert.equal(1, #sets(c4))
			end)

			it("stops a timed target from programming too (D6), through the hooks the machine calls", function()
				local env, c4, dev = load_light_with_dev({ rid = "l1" })
				configure(env)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40", online = "true" })
				c4.calls, c4.sent = {}, {}
				assert.is_false(dev.ramp_active())
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
				assert.is_false(dev.ramp_active(), "a target at once is no ramp")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "3500" })
				assert.is_true(dev.ramp_active())
				c4.advance(1000)
				dev.on_ramp_stop(1)
				assert.same({ stop_at("50") }, stops(c4))
				assert.is_false(dev.ramp_active())
				assert.same({ 50 }, levels(c4))
				dev.on_ramp_stop(1)
				assert.equal(1, #stops(c4), "nothing to stop")

				env.ReceivedFromProxy(5001, "RAMP_TO_LEVEL", { LEVEL = "80", TIME = "1000" })
				assert.is_true(dev.ramp_active())
				c4.advance(1000)
				assert.is_false(dev.ramp_active(), "its time ran out")
				env.ReceivedFromProxy(5001, "SET_LEVEL", { LEVEL = "60", TIME = "1000" })
				assert.is_true(dev.ramp_active())
				c4.bindings = {}
				env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
				assert.is_false(dev.ramp_active(), "an unbind ends it")
				assert.equal(0, #c4.active_timers())
			end)

			it("a press stops a ramp a programming target started; destroy cancels a ramp's timer", function()
				local env, c4 = light(40)
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "1800" })
				c4.advance(900)
				tap(env, 2)
				assert.same({ stop_at("70") }, stops(c4))
				assert.equal(2, #sets(c4), "the target and the stop")

				env, c4 = light(40)
				tap(env, 0)
				env.OnDriverDestroyed()
				assert.equal(0, #c4.active_timers())
			end)

			it("a click that finds a ramp begun after its press stops it rather than tapping", function()
				local env, c4 = light(40)
				press(env, 0)
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "1800" })
				c4.advance(100)
				click(env, 0)
				assert.same({ stop_at("43") }, stops(c4))
				assert.equal(2, #sets(c4), "the target and the stop: no tap")
			end)

			it("a hold that begins while a ramp runs holds from its estimate and ends it", function()
				local env, c4 = light(40)
				press(env, 0)
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "1800" })
				c4.advance(400) -- the hold time: 53 % by the clock
				assert.same({ { rid = "l1", direction = "up", duration = "5000" } }, dims(c4))
				local all = changing(c4)
				assert.same({ 53, 100, 2350 }, all[#all])
				release(env, 0)
				c4.advance(2000)
				assert.equal(2, #dims(c4), "the hold's stop; no ramp left to end")
			end)
		end)

		describe("reporting while a ramp runs (D10)", function()
			it("CHANGING once at the start; the bridge's levels wait for the end, then the latest is the one CHANGED", function()
				local env, c4 = light(40)
				tap(env, 0)
				assert.same({ { 40, 100, 1800 } }, changing(c4))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "100" }) -- Hue reports the target at once
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "99.6" })
				assert.same({}, levels(c4))
				c4.advance(1799)
				assert.same({}, levels(c4))
				c4.advance(1)
				assert.same({ 100 }, levels(c4))
				assert.equal(0, #c4.active_timers(), "the fallback is settled")
				c4.advance(5000)
				assert.same({ 100 }, levels(c4))
				assert.equal(1, #changing(c4))
			end)

			it("without a report, the target is assumed after the fallback time", function()
				local env, c4 = light(40)
				tap(env, 0)
				c4.advance(1800)
				assert.same({}, levels(c4))
				c4.advance(999)
				assert.same({}, levels(c4))
				c4.advance(1)
				assert.same({ 100 }, levels(c4))
				assert.is_not_nil(env)
			end)

			it("lets an off through while ramping up, and a level outside the ramp, and ends it", function()
				local env, c4 = light(40)
				tap(env, 0)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
				assert.same({ 0 }, levels(c4))
				-- No ramp and no fallback left: the tap's count (#432 D6) and the
				-- level window the report opened (#433 D12).
				assert.same({ DOUBLE_TAP_MS, LEVEL_REPORT_MS }, delays_of(c4))

				env, c4 = light(40)
				tap(env, 0)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "39" }) -- within a point of the start
				assert.same({}, levels(c4))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "20" }) -- the Hue app, say
				assert.same({ 20 }, levels(c4), "at once: it settles the tap's target (#433 D12)")
				assert.same({ DOUBLE_TAP_MS, LEVEL_REPORT_MS }, delays_of(c4))
				c4.advance(1800)
				press(env, 1)
				assert.equal(0, #stops(c4), "no ramp left to stop")
			end)

			it("holds the off at the end of a ramp to off, with the LEDs on, and lets an on through", function()
				local env, c4 = light(40)
				tap(env, 1) -- off over 1200 ms
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
				assert.same({}, levels(c4))
				assert.same({}, led_states(c4))
				c4.advance(1200)
				assert.same({ 0 }, levels(c4))
				assert.same({ false }, led_states(c4))

				env, c4 = light(40)
				tap(env, 1)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40", reason = "resync" })
				assert.same({ 40 }, levels(c4))
				assert.same({ DOUBLE_TAP_MS, LEVEL_REPORT_MS }, delays_of(c4),
					"no ramp, no fallback: the tap's count (#432 D6) and the level window (#433 D12)")
			end)

			it("lights the LEDs as a tap from off starts", function()
				local env, c4 = light(0)
				tap(env, 0)
				assert.same({ true }, led_states(c4))
				assert.same({}, levels(c4))
			end)

			it("keeps the #308 guard for a tap from off: the old level never shows, the target at the end", function()
				local env, c4 = light(0, { preset = 30 }) -- off at 70; 900 ms to 30
				tap(env, 0)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true" })
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "70" })
				assert.same({}, levels(c4))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "30.2" })
				assert.same({}, levels(c4))
				c4.advance(900)
				assert.same({ 30 }, levels(c4))
			end)

			it("a stop during the #308 wait settles it at the estimate", function()
				local env, c4 = light(0, { preset = 30 })
				tap(env, 0)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "70" })
				c4.advance(450)
				press(env, 1)
				assert.same({ stop_at("15") }, stops(c4))
				assert.same({ 15 }, levels(c4))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "16.2" })
				assert.same({ 15, 16 }, levels(c4))
			end)
		end)

		describe("other commands during a ramp (D11)", function()
			it("a brightness command replaces the ramp, from its estimate, and leaves nothing to stop", function()
				for _, case in ipairs({
					{ "ON", {} }, { "OFF", {} }, { "TOGGLE", {} },
					{ "SET_LEVEL", { LEVEL = "20", TIME = "0" } }, { "RAMP_TO_LEVEL", { LEVEL = "20", TIME = "0" } },
					{ "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "0" } },
				}) do
					local env, c4 = light(40)
					tap(env, 0)
					c4.advance(900)
					env.ReceivedFromProxy(5001, case[1], case[2])
					assert.equal(70, changing(c4)[2][1], case[1] .. ": the CHANGING starts where the tile is")
					press(env, 1)
					assert.equal(0, #stops(c4), case[1] .. ": idle again")
				end
			end)

			it("a timed command replaces it with a ramp of its own", function()
				local env, c4 = light(40)
				tap(env, 0)
				c4.advance(900)
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "1000" })
				assert.same({ 70, 20, 1000 }, changing(c4)[2])
				c4.advance(500)
				press(env, 1)
				assert.same({ stop_at("45") }, stops(c4))
			end)

			it("a colour command leaves the ramp running", function()
				local env, c4 = light(40)
				tap(env, 0)
				env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
				assert.same({ rid = "l1", x = "0.4", y = "0.35", rate = "0" }, sets(c4)[2])
				c4.advance(900)
				press(env, 1)
				assert.same({ stop_at("70") }, stops(c4))
			end)
		end)
	end)

	describe("keypad LEDs", function()
		it("MATCH_LED_STATE follows on/off on 200, 201 and 202, with BUTTON_INFO to the proxy", function()
			local env, c4 = lit_light()
			local proxy = capture_proxy(c4)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "70" })
			assert.equal(0, #with_command(proxy, "MATCH_LED_STATE"), "a level change is not a flip")
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
			assert.same(leds(false), with_command(proxy, "MATCH_LED_STATE"))
			assert.same({
				{ 5001, "BUTTON_INFO", { BUTTON_ID = 0, ON_COLOR = "0000ff", OFF_COLOR = "000000",
					CURRENT_COLOR = "000000" }, "NOTIFY" },
				{ 5001, "BUTTON_INFO", { BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff",
					CURRENT_COLOR = "0000ff" }, "NOTIFY" },
				{ 5001, "BUTTON_INFO", { BUTTON_ID = 2, ON_COLOR = "0000ff", OFF_COLOR = "000000",
					CURRENT_COLOR = "000000" }, "NOTIFY" },
			}, with_command(proxy, "BUTTON_INFO"))
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true" })
			local all = with_command(proxy, "MATCH_LED_STATE")
			assert.same(leds(true), { all[4], all[5], all[6] })
		end)

		it("sends them with the first known state, not before", function()
			local env, c4 = load_light({ rid = "l1" })
			local proxy = capture_proxy(c4)
			configure(env)
			assert.equal(0, #with_command(proxy, "MATCH_LED_STATE"))
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40" })
			assert.same(leds(true), with_command(proxy, "MATCH_LED_STATE"))
		end)

		it("resends the state when a keypad is bound to a Button Link", function()
			local env, c4 = lit_light()
			local proxy = capture_proxy(c4)
			env.OnBindingChanged(200, "BUTTON_LINK", true, 77, 1)
			assert.same(leds(true), with_command(proxy, "MATCH_LED_STATE"))
			assert.equal(0, #c4.sent, "a link binding is not the bridge's")
		end)

		it("REQUEST_BUTTON_COLORS on 201 answers the default bottom colours there, then the LED state", function()
			local env, c4 = lit_light()
			local proxy = capture_proxy(c4)
			env.ReceivedFromProxy(201, "REQUEST_BUTTON_COLORS", {})
			assert.same({
				{ 201, "BUTTON_COLORS", { BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff",
					CURRENT_COLOR = "000000" }, "NOTIFY" },
				{ 201, "MATCH_LED_STATE", { STATE = true }, "COMMAND" },
			}, proxy)
		end)

		it("SET_BUTTON_COLOR persists the colour, echoes it, and uses it after a restart", function()
			local env, c4 = lit_light()
			local proxy = capture_proxy(c4)
			env.ReceivedFromProxy(5001, "SET_BUTTON_COLOR", { BUTTON_ID = "0", OFF_COLOR = "00FF00" })
			assert.equal("00ff00", c4.persist.button_0_off_color)
			assert.same({
				{ 200, "BUTTON_COLORS", { BUTTON_ID = 0, ON_COLOR = "0000ff", OFF_COLOR = "00ff00",
					CURRENT_COLOR = "0000ff" }, "NOTIFY" },
				{ 5001, "BUTTON_INFO", { BUTTON_ID = 0, ON_COLOR = "0000ff", OFF_COLOR = "00ff00",
					CURRENT_COLOR = "0000ff" }, "NOTIFY" },
			}, proxy)
			local env2, c42 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c42.persist.button_0_off_color = "00ff00"
			env2.OnDriverLateInit("DIT_STARTUP")
			local proxy2 = capture_proxy(c42)
			env2.ReceivedFromProxy(200, "REQUEST_BUTTON_COLORS", {})
			assert.same({ BUTTON_ID = 0, ON_COLOR = "0000ff", OFF_COLOR = "00ff00", CURRENT_COLOR = "00ff00" },
				proxy2[1][3])
			assert.same({ STATE = false }, proxy2[2][3], "nothing known yet reads as off")
		end)
	end)

	describe("keypad buttons on the Button Link bindings (DO_PUSH / DO_RELEASE / DO_CLICK)", function()
		it("declares the three Button Link connections", function()
			local xml = io.open("src/hue_light/driver.xml"):read("*a")
			for _, name in ipairs({ "Top Button Link", "Bottom Button Link", "Toggle Button Link" }) do
				assert.truthy(xml:find(name, 1, true), name)
			end
		end)

		it("a click on binding 200 turns on to the preset, on 201 off, with the link notifies", function()
			local env, c4 = lit_light()
			c4.sent = {}
			c4.calls = {}
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.equal(1, #messages(c4, "HUE_SET"))
			assert.equal("100", tostring(messages(c4, "HUE_SET")[1].params.brightness))
			-- #432 D4: the proxy hears the link press as its own route would echo
			-- it, the push and its click, so it can fire Top Press and Release;
			-- the keypad's DO_CLICK after the DO_RELEASE adds nothing.
			assert.same({ { BUTTON_ID = 0, ACTION = 1 }, { BUTTON_ID = 0, ACTION = 2 } }, notifies(c4, "BUTTON_ACTION"))
			c4.advance(1800) -- the ramp runs out; a click during it would stop it (#421 D5)
			assert.same({ { BUTTON_ID = 0, COUNT = 1 } }, notifies(c4, "CLICK_COUNT"),
				"one tap, counted DOUBLE_TAP_MS after its press (#432 D6, mode \"count\")")
			c4.sent = {}
			env.ReceivedFromProxy(201, "DO_CLICK", {})
			assert.equal("false", tostring(messages(c4, "HUE_SET")[1].params.on))
		end)

		it("a push held on binding 201 dims down and the release stops at the reached level", function()
			local env, c4 = lit_light() -- on at 40 %
			c4.sent = {}
			env.ReceivedFromProxy(201, "DO_PUSH", {})
			c4.fire_timers()
			assert.equal("down", dims(c4)[1].direction)
			for _ = 1, 5 do c4.fire_timers() end
			c4.sent = {}
			env.ReceivedFromProxy(201, "DO_RELEASE", {})
			local stop = dims(c4)[1]
			assert.equal("stop", stop.direction)
			assert.is_true(tonumber(stop.level) < 40 and tonumber(stop.level) > 1)
			assert.equal(0, #messages(c4, "HUE_SET"))
		end)

		it("ignores the commands on an unknown binding", function()
			local env, c4 = lit_light()
			c4.sent = {}
			env.ReceivedFromProxy(5001, "DO_CLICK", {})
			assert.equal(0, #messages(c4, "HUE_SET"), "only a log line, no command")
		end)
	end)

	describe("binding re-check after start (Director restart)", function()
		it("greets the bridge once a binding that was invisible at late init shows up, with no binding event", function()
			local env, c4 = load_light({ bind = false, rid = "x1" })
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			c4.fire_timers() -- 5 s: still nothing bound
			assert.equal(0, #messages(c4, "HUE_HELLO"))
			c4.bindings[#c4.bindings + 1] = { provider = BRIDGE_ID, provider_binding = 1, consumer = LIGHT_ID,
				consumer_binding = 1, class = "HUE_BRIDGE" }
			c4.fire_timers() -- 15 s: the binding is visible now
			assert.equal(1, #messages(c4, "HUE_HELLO"))
			assert.equal(BRIDGE_ID, messages(c4, "HUE_HELLO")[1].id)
			assert.equal(0, #c4.active_timers(), "no further re-checks")
		end)

		it("stops after the check at 60 s", function()
			local _, c4 = load_light({ bind = false, rid = "x1" })
			for _ = 1, 4 do c4.fire_timers() end
			assert.equal(0, #c4.active_timers())
		end)

		it("ends the re-checks on a binding event and on destroy, and never starts them when bound", function()
			local env, c4 = load_light({ bind = false, rid = "x1" })
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.equal(0, #c4.active_timers())
			env, c4 = load_light({ bind = false, rid = "x1" })
			env.OnDriverDestroyed()
			assert.equal(0, #c4.active_timers())
			local _, bound_c4 = load_light({ rid = "x1" })
			assert.equal(0, #bound_c4.active_timers())
		end)
	end)

	-- A Hue zone or room as a Hue Light device (docs/zone-light-design.md §5):
	-- the bridge's HUE_CONFIGURE names kind "group" and the group's fields; the
	-- proxy, keypad and bridge-command side stays the light's.
	describe("zone and room devices (kind group)", function()
		local ZONE_RID = "b90ea7b4-aaaa-4bbb-8ccc-ddddeeeeffff"
		local ROOM_RID = "7104cbc3-aaaa-4bbb-8ccc-ddddeeeeffff"

		-- What the bridge sends for a zone and a room, every value a string.
		local ZONE = { rid = ZONE_RID, kind = "group", group_type = "zone", name = "Bedside Lights", light_count = "2",
			model = "Hue zone", hue_room = "Bedside Lights (zone)", id_v1 = "/groups/2", has_color = "true",
			has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }
		local ROOM = { rid = ROOM_RID, kind = "group", group_type = "room", name = "Master Bedroom", light_count = "9",
			model = "Hue room", hue_room = "Master Bedroom", id_v1 = "/groups/5", has_color = "true",
			has_cct = "true", mirek_min = "153", mirek_max = "454", min_dim = "1" }

		-- HUE_CONFIGURE from `base` with `extra` merged in and the keys in `drop` left out.
		local function configure_group(env, base, extra, drop)
			local params = {}
			for k, v in pairs(base) do params[k] = v end
			for k, v in pairs(extra or {}) do params[k] = v end
			for _, k in ipairs(drop or {}) do params[k] = nil end
			env.ExecuteCommand("HUE_CONFIGURE", params)
		end

		-- A configured zone device, on at 40 % in a member's colour, as the
		-- bridge reports a group (Decisions 3 and 8).
		local function lit_zone()
			local env, c4 = load_light({ rid = ZONE_RID })
			configure_group(env, ZONE)
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "40", x = "0.4", y = "0.35",
				color_mode = "xy", online = "true", reason = "hello" })
			c4.calls = {}
			c4.sent = {}
			return env, c4
		end

		-- Composer clips a property at about 75 characters; the contract asks
		-- for texts under 60 where the name allows.
		local function fits(text)
			assert.is_true(#text <= 60, string.format("%d characters: %s", #text, text))
			return text
		end

		local function proxy_of(light_id)
			return assert(fake.project.devices[light_id].proxy_id, "the fake registers a proxy per loaded light")
		end

		local NO_LIGHTS = "Hue zone Bedside Lights has no lights; nothing to control"

		after_each(function() log.set_debug(false) end)

		it("labels a zone from the configure and persists the kind beside the rid", function()
			local env, c4 = load_light({ rid = ZONE_RID })
			c4.calls = {}
			configure_group(env, ZONE)
			assert.equal("Hue zone Bedside Lights (2 lights)", fits(env.Properties["Status"]))
			assert.equal("zone #2 (b90ea7b4…)", env.Properties["Hue Light ID"])
			assert.equal("Hue zone (2 lights)", env.Properties["Model"])
			assert.equal("Bedside Lights", env.Properties["Hue Name"])
			assert.equal("Bedside Lights (zone)", env.Properties["Hue Room"])
			assert.equal("", env.Properties["Online"], "not known until the bridge reports")
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
			assert.same({ {
				supports_color = "true",
				supports_color_correlated_temperature = "true",
				color_correlated_temperature_min = 2000,
				color_correlated_temperature_max = 6530,
			}, { brightness_rate_min = 0, brightness_rate_max = 6000000, color_rate_behavior = 1, color_rate_min = 0,
				color_rate_max = 6000000 } }, notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"),
				"the union of the members, as for a bulb; then the rate ranges (#430 D20)")
			assert.same({ hue_rid = ZONE_RID, hue_name = "Bedside Lights", hue_model = "Hue zone", hue_kind = "group",
				hue_group_type = "zone" }, c4.persist)
		end)

		it("labels a room the same way", function()
			local env = load_light({ rid = ROOM_RID })
			configure_group(env, ROOM)
			assert.equal("Hue room Master Bedroom (9 lights)", fits(env.Properties["Status"]))
			assert.equal("room #5 (7104cbc3…)", env.Properties["Hue Light ID"])
			assert.equal("Hue room (9 lights)", env.Properties["Model"])
			assert.equal("Master Bedroom", env.Properties["Hue Name"])
			assert.equal("Master Bedroom", env.Properties["Hue Room"])
		end)

		it("counts one light in the singular, and shows no count while the bridge sends none", function()
			local env = load_light({ rid = ZONE_RID })
			configure_group(env, ZONE, { light_count = "1" })
			assert.equal("Hue zone Bedside Lights (1 light)", env.Properties["Status"])
			assert.equal("Hue zone (1 light)", env.Properties["Model"])
			configure_group(env, ZONE, nil, { "light_count" })
			assert.equal("Hue zone Bedside Lights", env.Properties["Status"])
			assert.equal("Hue zone", env.Properties["Model"])
		end)

		it("greets the bridge with kind group and no model after a restart, labelled from what it persisted", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c4.persist.hue_rid, c4.persist.hue_name = ZONE_RID, "Bedside Lights"
			c4.persist.hue_model, c4.persist.hue_kind = "Hue zone", "group"
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same(greeting({ rid = ZONE_RID, device_id = "2001", name = "Bedside Lights", kind = "group" }), c4.sent)
			assert.equal("Hue zone Bedside Lights", env.Properties["Status"],
				"the persisted model stands in for the type until the bridge answers")
			assert.equal(ZONE_RID, env.Properties["Hue Light ID"])
			assert.equal("", env.Properties["Online"])
		end)

		-- Issue #234: the group type was not persisted, so after a restart a
		-- room device spoke of a "group light", and Adopt Hue Name (a hidden
		-- alias since 1.2) gave it the room's bare name, until the bridge
		-- configured it again.
		it("persists the group type, so after a restart its texts and Adopt Hue Name need no configure (#234)", function()
			local first, c4 = load_light({ rid = ROOM_RID })
			configure_group(first, ROOM)
			assert.equal("room", c4.persist.hue_group_type)

			local env, c42 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c42:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c42.persist.hue_rid, c42.persist.hue_name = ROOM_RID, "Master Bedroom"
			c42.persist.hue_model, c42.persist.hue_kind, c42.persist.hue_group_type = "Hue room", "group", "room"
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(1, #messages(c42, "HUE_HELLO"), "greeted; the bridge has not answered yet")
			assert.equal("Hue room Master Bedroom", env.Properties["Status"])
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.same({ { proxy_of(LIGHT_ID), "Master Bedroom Lights" } }, c42.calls_to("RenameDevice"))
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Light" })
			assert.equal("Asked the bridge to forget this room light; its answer sets Status", fake.last_action(env))
		end)

		it("applies a configure buffered before late init, and the hello carries the kind it delivered", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			configure_group(env, ZONE)
			assert.equal(0, #c4.calls_to("PersistSetValue"))
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal("Hue zone Bedside Lights (2 lights)", env.Properties["Status"])
			assert.same(greeting({ rid = ZONE_RID, device_id = "2001", name = "Bedside Lights", kind = "group" }), c4.sent)
		end)

		it("a light told kind light persists it and says so in its hello; one never told stays silent", function()
			local env, c4 = load_light({ rid = "l1" })
			configure(env, { kind = "light" })
			assert.equal("light", c4.persist.hue_kind)
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
			assert.equal("l1", env.Properties["Hue Light ID"])

			local env2, c42 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c42:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c42.persist.hue_rid, c42.persist.hue_name = "l1", "Desk"
			c42.persist.hue_model, c42.persist.hue_kind = "Hue color lamp", "light"
			env2.OnDriverLateInit("DIT_STARTUP")
			assert.same({ rid = "l1", device_id = "2001", name = "Desk", model = "Hue color lamp", kind = "light" },
				c42.sent[1].params)
			-- The startup specs above cover a light never told its kind: no kind key in the hello.
		end)

		it("keeps its kind when a configure names none, and ignores one it does not know, with a warning", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local env, c4 = load_light({ rid = ZONE_RID })
			configure_group(env, ZONE)

			-- An older bridge answering a zone light's hello as if it were a
			-- light (contract §7 Q11): no kind, no group fields, state gone.
			configure_group(env, ZONE, { state = "gone", gone_since = "1761000000" }, { "kind", "group_type", "light_count" })
			assert.equal("group", c4.persist.hue_kind)
			assert.is_nil(c4.persist.hue_group_type, "the stored type follows the one the device shows")
			assert.equal("Group deleted in Hue since " .. os.date("%Y-%m-%d", 1761000000) .. "; Link or Forget Device",
				env.Properties["Status"])
			assert.equal("Hue zone", env.Properties["Model"])

			configure_group(env, ZONE, { kind = "entertainment" })
			assert.equal("group", c4.persist.hue_kind)
			assert.equal("zone", c4.persist.hue_group_type)
			assert.equal("Hue zone Bedside Lights (2 lights)", env.Properties["Status"])
			local warned = false
			for _, line in ipairs(lines) do
				if line:find("^%[WARN%] Hue Light: HUE_CONFIGURE with unknown kind entertainment ignored; still a zone light") then
					warned = true
				end
			end
			assert.is_true(warned)
		end)

		it("ignores a persisted kind it does not know: the hello names none", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c4.persist.hue_rid, c4.persist.hue_kind = "l1", "sparkly"
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ rid = "l1", device_id = "2001" }, c4.sent[1].params)
		end)

		it("Decision 11: without lights it goes offline, shows off, and drops commands with the reason", function()
			local env, c4 = lit_zone()
			local proxy = capture_proxy(c4)
			configure_group(env, ZONE, { no_lights = "true", light_count = "0" })
			assert.equal(NO_LIGHTS, fits(env.Properties["Status"]))
			assert.equal("Offline", env.Properties["Online"])
			assert.equal("Hue zone (0 lights)", env.Properties["Model"])
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "tile off")
			assert.same(leds(false), with_command(proxy, "MATCH_LED_STATE"))
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, online = "false", reason = "event" })

			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			log.set_debug(true) -- the dropped-command line is info level
			c4.calls = {}
			c4.sent = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.3", LIGHT_COLOR_TARGET_Y = "0.3",
				LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			env.ReceivedFromProxy(201, "DO_CLICK", {})
			assert.equal(0, #messages(c4, "HUE_SET"), "no HUE_SET")
			assert.equal(0, #dims(c4), "no HUE_DIM")
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.equal(0, #notifies(c4, "LIGHT_COLOR_CHANGING"))
			assert.equal(NO_LIGHTS, env.Properties["Status"])
			local dropped = {}
			for _, line in ipairs(lines) do
				local what = line:match("^%[INFO%] Hue Light: (.-) dropped: " .. NO_LIGHTS:gsub("%p", "%%%0") .. "$")
				if what then dropped[#dropped + 1] = what end
			end
			assert.same({ "brightness target", "colour target", "hold", "brightness target" }, dropped,
				"the slider, the colour pick, the held top button and the tap on bottom, each with the reason")
		end)

		it("comes back online when the group is refilled, with nothing to click", function()
			local env, c4 = lit_zone()
			configure_group(env, ZONE, { no_lights = "true", light_count = "0" })
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, online = "false", reason = "event" })
			c4.calls = {}
			configure_group(env, ZONE, { light_count = "1" })
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "60", online = "true",
				reason = "event" })
			assert.equal("Hue zone Bedside Lights (1 light)", env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
			local online = notifies(c4, "ONLINE_CHANGED")
			assert.same({ STATE = true }, online[#online])
			-- The configure re-reports the cached off (as every configure does); the report lights the tile.
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 }, { LIGHT_BRIGHTNESS_CURRENT = 60 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))

			c4.sent = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.same({ rid = ZONE_RID, on = "true", brightness = "75", rate = "0" }, last_sent(c4).params)
		end)

		it("says deleted in Hue while the bridge reports the zone gone, and comes back when re-linked", function()
			local env, c4 = lit_zone()
			configure_group(env, ZONE, { state = "gone", gone_since = "1761000000" })
			local expected = "Zone deleted in Hue since " .. os.date("%Y-%m-%d", 1761000000) .. "; Link or Forget Device"
			assert.equal(expected, fits(env.Properties["Status"]))
			assert.equal("Offline", env.Properties["Online"])
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))

			c4.sent = {}
			c4.calls = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(0, #c4.sent, "dropped")
			assert.equal(expected, env.Properties["Status"])

			-- Link Device on the bridge, to another zone: a configure with the new identity.
			local other = "c0ffee00-aaaa-4bbb-8ccc-ddddeeeeffff"
			configure_group(env, ZONE, { rid = other, name = "Reading Nook", id_v1 = "/groups/7", light_count = "3" })
			assert.equal("Hue zone Reading Nook (3 lights)", env.Properties["Status"])
			assert.equal("zone #7 (c0ffee00…)", env.Properties["Hue Light ID"])
			assert.equal("Online", env.Properties["Online"])
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
			assert.equal(other, c4.persist.hue_rid)
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(other, messages(c4, "HUE_SET")[1].params.rid)
		end)

		it("says Room deleted for a room, without a date when the bridge sends none", function()
			local env = load_light({ rid = ROOM_RID })
			configure_group(env, ROOM, { state = "gone" })
			assert.equal("Room deleted in Hue; Link or Forget Device", fits(env.Properties["Status"]))
		end)

		it("names the zone when forgotten and puts the instruction in Last Action", function()
			local env, c4 = lit_zone()
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = ZONE_RID, name = "Bedside Lights" })
			assert.equal("Forgotten by the bridge (was Hue zone Bedside Lights)", fits(env.Properties["Status"]))
			assert.equal("Delete this device, or bind it again and use Link Device on the Hue Bridge",
				fake.last_action(env))
			assert.equal("Offline", env.Properties["Online"])
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))

			c4.sent = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(0, #c4.sent)
			assert.same({ hue_rid = ZONE_RID, hue_name = "Bedside Lights", hue_model = "Hue zone", hue_kind = "group",
				hue_group_type = "zone" }, c4.persist, "the identity stays, so binding the device again lets Link Device adopt it")

			c4.calls = {}
			configure_group(env, ZONE)
			assert.equal("Hue zone Bedside Lights (2 lights)", env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
		end)

		it("names a forgotten room from its own state when the message carries no name", function()
			local env = load_light({ rid = ROOM_RID })
			configure_group(env, ROOM)
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = ROOM_RID })
			assert.equal("Forgotten by the bridge (was Hue room Master Bedroom)", fits(env.Properties["Status"]))
		end)

		it("Decision 7: re-announces both colour flags and the CT range when a configure changes them", function()
			local env, c4 = lit_zone()
			configure_group(env, ZONE, { has_color = "false", has_cct = "true", mirek_min = "153", mirek_max = "454",
				light_count = "3" })
			assert.same({
				supports_color = "false",
				supports_color_correlated_temperature = "true",
				color_correlated_temperature_min = 2210,
				color_correlated_temperature_max = 6530,
			}, notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED")[1], "both flags in one notify")
			assert.equal("Hue zone Bedside Lights (3 lights)", env.Properties["Status"])

			c4.calls = {}
			configure_group(env, ZONE, { has_color = "false", has_cct = "false", light_count = "3" })
			assert.same({ supports_color = "false", supports_color_correlated_temperature = "false" },
				notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED")[1])

			c4.calls = {}
			configure_group(env, ZONE, { light_count = "3" })
			assert.equal(2, #notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"), "every configure announces them again")
			assert.equal("true", notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED")[1].supports_color)
		end)

		it("drives the group exactly as a light: HUE_DIM holds, HUE_SET bodies, HUE_STATE mapping", function()
			local env, c4 = lit_zone() -- on at 40 %
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time
			assert.same({ { rid = ZONE_RID, direction = "up", duration = "5000" } }, dims(c4),
				"the whole range over the hold rate, as a light (#232)")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"), "the tile over its share, at the same speed")
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			assert.equal("stop", dims(c4)[2].direction)
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, brightness = "47", reason = "event" })

			c4.sent = {}
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ id = BRIDGE_ID, command = "HUE_SET",
				params = { rid = ZONE_RID, on = "true", brightness = "100", rate = "0" } }, last_sent(c4))
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.3", LIGHT_COLOR_TARGET_Y = "0.3",
				LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
			assert.same({ rid = ZONE_RID, x = "0.3", y = "0.3", rate = "0" }, last_sent(c4).params)

			c4.calls = {}
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "55.5", mirek = "370",
				color_mode = "ct", reason = "event" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 56 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(1, notifies(c4, "LIGHT_COLOR_CHANGED")[1].LIGHT_COLOR_CURRENT_COLOR_MODE)
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "false" })
			assert.same({ LIGHT_BRIGHTNESS_CURRENT = 0 }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")[2], "an off: at once")
			assert.equal(2, #c4.active_timers(),
				"only the hold's click guard and the level window the off opened (#433 D12): both targets were confirmed")
		end)

		it("ON and TOGGLE set every lamp to the zone light's own Default On Brightness, as on a light (#233)", function()
			local env, c4 = lit_zone() -- on at 40 %
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ rid = ZONE_RID, on = "true", brightness = "100", rate = "0" }, last_sent(c4).params,
				"100 while it was never changed")
			env.ReceivedFromProxy(5001, "SET_PRESET_LEVEL", { LEVEL = "60" })
			assert.equal(60, c4.persist.preset_level)
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ id = BRIDGE_ID, command = "HUE_SET",
				params = { rid = ZONE_RID, on = "true", brightness = "60", rate = "0" } }, last_sent(c4))
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "60", reason = "event" })
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.same({ rid = ZONE_RID, on = "false", rate = "0" }, last_sent(c4).params)
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "false", reason = "event" })
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.same({ rid = ZONE_RID, on = "true", brightness = "60", rate = "0" }, last_sent(c4).params)
		end)

		-- #421 D14: the same path on the grouped_light; whether Hue honours a
		-- group's duration and stop is measured on the house (§7, Z1/Z2).
		it("taps ramp and a press stops a zone or room light as a light's, on its grouped_light (#421)", function()
			for _, base in ipairs({ ZONE, ROOM }) do
				local env, c4 = load_light({ rid = base.rid })
				configure_group(env, base)
				env.ExecuteCommand("HUE_STATE", { rid = base.rid, on = "true", brightness = "40", online = "true" })
				c4.calls, c4.sent = {}, {}
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				env.ReceivedFromProxy(200, "DO_RELEASE", {})
				env.ReceivedFromProxy(200, "DO_CLICK", {})
				assert.same({ id = BRIDGE_ID, command = "HUE_SET",
					params = { rid = base.rid, on = "true", brightness = "100", rate = "1800", urgent = "true" } },
					last_sent(c4), base.group_type)
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 1800,
					LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
				env.ExecuteCommand("HUE_STATE", { rid = base.rid, brightness = "100", reason = "event" })
				assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "the group's level waits for the ramp's end")
				c4.advance(900)
				env.ReceivedFromProxy(201, "DO_PUSH", {})
				assert.same({ stop_at("70", base.rid) }, stops(c4))
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 70 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
				env.ReceivedFromProxy(201, "DO_RELEASE", {})
				env.ReceivedFromProxy(201, "DO_CLICK", {})
				assert.equal(2, #messages(c4, "HUE_SET"), "the start and the stop: the click after it is swallowed")
			end
		end)

		it("Adopt Hue Name and Forget This Light (hidden aliases) speak of the zone or room", function()
			local env, c4 = lit_zone()
			local proxy_id = proxy_of(LIGHT_ID)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.same({ { proxy_id, "Bedside Lights" } }, c4.calls_to("RenameDevice"), "a zone's name verbatim")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Light" })
			assert.same({ rid = ZONE_RID, device_id = "2001" }, messages(c4, "HUE_FORGET")[1].params)
			assert.equal("Asked the bridge to forget this zone light; its answer sets Status", fake.last_action(env))

			env, c4 = load_light({ rid = ROOM_RID })
			configure_group(env, ROOM)
			proxy_id = proxy_of(LIGHT_ID)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.same({ { proxy_id, "Master Bedroom Lights" } }, c4.calls_to("RenameDevice"),
				"a room device is <Room> Lights (contract §5 Naming)")
			assert.equal(string.format("Renamed device %d to Master Bedroom Lights", proxy_id), fake.last_action(env))
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Light" })
			assert.equal("Asked the bridge to forget this room light; its answer sets Status", fake.last_action(env))

			env = load_light({ rid = ZONE_RID })
			configure_group(env, ZONE, nil, { "name" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.equal("Not renamed: no Hue name known yet (the bridge has not configured this zone light)",
				fake.last_action(env))
		end)
	end)

	-- docs/turn-on-design.md (#429, #427, #430): the turn-on behaviour, built
	-- on light.turnon. The proxy's messages carry the names with underscores
	-- here, as the house's proxy spells SET_COLOR_TARGET's (§2.4); the
	-- module's own spec covers the spaced spellings.
	describe("turn-on behaviour (#429, #427, #430)", function()
		local ON_COLOR, DIM_COLOR, RELAX = 11, 12, 17 -- colour preset ids the proxy might use
		local OFF_PRESET, PREVIOUS_PRESET, DIM_PRESET = 2, 3, 5 -- brightness preset ids
		local ZONE_RID = "b90ea7b4-aaaa-4bbb-8ccc-ddddeeeeffff"
		local ZONE = { rid = ZONE_RID, kind = "group", group_type = "zone", name = "Bedside Lights", light_count = "2",
			model = "Hue zone", has_color = "true", has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }

		after_each(function() log.set_debug(false) end)

		-- The configured colour light, off; Hue keeps its level, 70 %, at 2700 K.
		local function dark_light(opts)
			opts = opts or {}
			opts.rid = opts.rid or "l1"
			local env, c4 = load_light(opts)
			configure(env, opts.configure)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", brightness = "70", mirek = "370",
				color_mode = "ct", online = "true", reason = "hello" })
			c4.calls, c4.sent = {}, {}
			return env, c4
		end

		-- A zone device, reported off, its lamps' average 20 % when it was on.
		local function dark_zone()
			local env, c4 = load_light({ rid = ZONE_RID })
			env.ExecuteCommand("HUE_CONFIGURE", ZONE)
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "20", online = "true" })
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "false" })
			c4.calls, c4.sent = {}, {}
			return env, c4
		end

		local function proxy(env, command, params)
			env.ReceivedFromProxy(5001, command, params or {})
		end

		-- A colour preset as UPDATE_COLOR_PRESET carries it: a colour
		-- temperature (mode 1) from Kelvin, or full colour from x and y.
		local function color_preset(env, c4, name, id, k_or_x, y)
			local x, mode = k_or_x, "0"
			if y == nil then
				x, y = c4:ColorCCTtoXY(k_or_x)
				mode = "1"
			end
			proxy(env, "UPDATE_COLOR_PRESET", { COMMAND = "MODIFIED", ID = tostring(id), NAME = name,
				COLOR_X = tostring(x), COLOR_Y = tostring(y), COLOR_MODE = mode })
		end

		-- The proxy's On and Dim colours (Dim = On when Composer's box is off).
		local function on_and_dim(env, c4, on_k, dim_k)
			color_preset(env, c4, "On", ON_COLOR, on_k)
			color_preset(env, c4, "Dim", DIM_COLOR, dim_k or on_k)
		end

		local function brightness_preset(env, name, id, level)
			proxy(env, "UPDATE_BRIGHTNESS_PRESET", { COMMAND = "ADDED", ID = tostring(id), NAME = name,
				LEVEL = tostring(level) })
		end

		-- On Mode Previous, as the proxy says it (#429 D4).
		local function previous_mode(env)
			brightness_preset(env, "Previous", PREVIOUS_PRESET, 0)
			proxy(env, "UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = tostring(PREVIOUS_PRESET) })
		end

		local function hue_sets(c4)
			local out = {}
			for _, m in ipairs(messages(c4, "HUE_SET")) do out[#out + 1] = m.params end
			return out
		end

		local function last_set(c4)
			local sets = hue_sets(c4)
			return sets[#sets]
		end

		-- The Kelvin a HUE_SET's mirek stands for, nil without one.
		local function kelvin(params)
			return params.mirek and 1000000 / tonumber(params.mirek) or nil
		end

		local function near(expected, got, tolerance, what)
			assert.is_true(got ~= nil and math.abs(got - expected) <= tolerance,
				string.format("%s: expected about %s, got %s", what or "value", tostring(expected), tostring(got)))
		end

		local function tap_top(env)
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			env.ReceivedFromProxy(200, "DO_CLICK", {})
		end

		local function tap_bottom(env)
			env.ReceivedFromProxy(201, "DO_PUSH", {})
			env.ReceivedFromProxy(201, "DO_RELEASE", {})
			env.ReceivedFromProxy(201, "DO_CLICK", {})
		end

		local function timer_delays(c4)
			local out = {}
			for _, timer in ipairs(c4.active_timers()) do out[#out + 1] = timer.delay end
			table.sort(out)
			return out
		end

		describe("On Mode (#429)", function()
			it("ON, TOGGLE, OFF use the default rate after UPDATE_BRIGHTNESS_RATE_DEFAULT; 0 before", function()
				local env, c4 = dark_light()
				proxy(env, "ON")
				assert.same({ rid = "l1", on = "true", brightness = "100", rate = "0" }, last_set(c4), "0 before (D8)")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" })

				proxy(env, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "2000" })
				proxy(env, "OFF")
				assert.same({ rid = "l1", on = "false", rate = "2000" }, last_set(c4))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
				c4.advance(3000)
				proxy(env, "TOGGLE")
				assert.same({ rid = "l1", on = "true", brightness = "100", rate = "2000" }, last_set(c4))
				proxy(env, "TOGGLE")
				assert.same({ rid = "l1", on = "false", rate = "2000" }, last_set(c4),
					"the turn-on is under way: a second TOGGLE turns the light off again")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" })
				c4.advance(3000)
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30" })
				assert.same({ rid = "l1", on = "true", brightness = "30", rate = "2000" }, last_set(c4),
					"a target without RATE fades over the default too")
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
				assert.equal("0", last_set(c4).rate, "one that names a rate keeps it")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40" })
				c4.advance(3000)
				tap_top(env)
				assert.equal("1800", last_set(c4).rate, "taps keep the click rates: 3000 x 60 / 100")
			end)

			it("a top tap from off in Previous goes to the last reported level; while on, to the On preset", function()
				local env, c4 = dark_light()
				previous_mode(env)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "35" })
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
				c4.calls, c4.sent = {}, {}
				tap_top(env)
				assert.same({ rid = "l1", on = "true", brightness = "35", rate = "1050", urgent = "true" }, last_set(c4),
					"the click rate up's share of 35")
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 35, RATE = 1050,
					LIGHT_BRIGHTNESS_TARGET_PRESET_ID = PREVIOUS_PRESET } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "35" })
				c4.advance(2100)
				c4.calls, c4.sent = {}, {}
				tap_top(env)
				assert.same({ rid = "l1", on = "true", brightness = "100", rate = "1950", urgent = "true" }, last_set(c4),
					"while on Previous has nothing to restore: the On preset (D5)")
				assert.equal(1, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[1].LIGHT_BRIGHTNESS_TARGET_PRESET_ID)
			end)

			it("Previous without a reported level falls back to the level Hue keeps, then the preset", function()
				local env, c4 = dark_light() -- off; Hue keeps 70 %, nothing above 0 reported since the start
				previous_mode(env)
				proxy(env, "ON")
				assert.same({ rid = "l1", on = "true", brightness = "70", rate = "0" }, last_set(c4))
			end)

			it("a zone light in Previous sends HUE_SET on without brightness, so every lamp keeps its own", function()
				local env, c4 = dark_zone()
				previous_mode(env)
				tap_top(env)
				assert.same({ rid = ZONE_RID, on = "true", rate = "600", urgent = "true" }, last_set(c4),
					"on alone (D6), over the click rate's share of the last level")
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 20, RATE = 600,
					LIGHT_BRIGHTNESS_TARGET_PRESET_ID = PREVIOUS_PRESET } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
				env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "47" })
				c4.advance(2000)
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 47 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"),
					"the group's own average, whatever it is: no #308 goal holds it back")

				env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "false" })
				c4.sent = {}
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "47", RATE = "0",
					LIGHT_BRIGHTNESS_TARGET_PRESET_ID = tostring(PREVIOUS_PRESET) })
				assert.same({ rid = ZONE_RID, on = "true", rate = "0" }, last_set(c4), "the proxy's own Previous turn-on")
				env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "47" })
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "0",
					LIGHT_BRIGHTNESS_TARGET_PRESET_ID = tostring(PREVIOUS_PRESET) })
				assert.equal("60", last_set(c4).brightness, "on already: the level")
			end)

			it("CHANGING and CHANGED carry preset ids; a slider level clears them", function()
				local env, c4 = dark_light()
				brightness_preset(env, "Off", OFF_PRESET, 0)
				proxy(env, "ON")
				assert.same({ LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 0,
					LIGHT_BRIGHTNESS_TARGET_PRESET_ID = 1 }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[1])
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "99.6" })
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100, LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = 1 } },
					notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "at the On preset")

				c4.calls = {}
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" })
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100, LIGHT_BRIGHTNESS_TARGET = 50, RATE = 0,
					LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = 1 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"),
					"it sits at the On preset as it leaves it")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "50" })
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 50 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "cleared")

				c4.calls = {}
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "25", RATE = "0",
					LIGHT_BRIGHTNESS_TARGET_PRESET_ID = tostring(DIM_PRESET) })
				assert.equal(DIM_PRESET, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[1].LIGHT_BRIGHTNESS_TARGET_PRESET_ID,
					"the id a target carries is echoed")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "25" })
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 25, LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = DIM_PRESET } },
					notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "40" }) -- someone moved it in Hue
				c4.advance(LEVEL_REPORT_MS) -- a Hue-side level: at the end of the target's window (#433 D12)
				assert.same({ LIGHT_BRIGHTNESS_CURRENT = 40 }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")[2])

				c4.calls = {}
				proxy(env, "OFF")
				assert.equal(OFF_PRESET, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[1].LIGHT_BRIGHTNESS_TARGET_PRESET_ID,
					"an off names the Off preset once its id is known")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = OFF_PRESET } },
					notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			end)

			it("UPDATE_BRIGHTNESS_PRESET for the On preset changes the tap level and sends no PRESET_LEVEL", function()
				local env, c4 = dark_light()
				brightness_preset(env, "On", 1, 60)
				assert.equal(0, #notifies(c4, "PRESET_LEVEL"), "no echo (D4)")
				assert.equal(60, c4.persist.preset_level)
				tap_top(env)
				assert.equal("60", last_set(c4).brightness)
				proxy(env, "SET_PRESET_LEVEL", { LEVEL = "70" })
				assert.same({ "70" }, notifies(c4, "PRESET_LEVEL"), "SET_PRESET_LEVEL is answered as before")
			end)

			it("UPDATE_BRIGHTNESS_ON_MODE to another preset turns on at that preset's level, and moves nothing", function()
				local env, c4 = dark_light()
				brightness_preset(env, "Evening", DIM_PRESET, 30)
				proxy(env, "UPDATE_BRIGHTNESS_ON_MODE", { BRIGHTNESS_PRESET_ID = tostring(DIM_PRESET),
					BRIGHTNESS_PRESET_LEVEL = "30" })
				assert.equal(0, #c4.sent, "an UPDATE never moves the light (D26)")
				proxy(env, "TOGGLE")
				assert.equal("30", last_set(c4).brightness)
				assert.equal(DIM_PRESET, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[1].LIGHT_BRIGHTNESS_TARGET_PRESET_ID)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "80" })
				proxy(env, "ON")
				assert.equal("30", last_set(c4).brightness, "ON while on goes to the on mode preset (D5)")
			end)

			it("modes survive a restart (persisted)", function()
				local env, c4 = dark_light()
				previous_mode(env)
				on_and_dim(env, c4, 2700)
				local persisted = {}
				for k, v in pairs(c4.persist) do persisted[k] = v end
				env, c4 = dark_light({ persist = persisted })
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "35" })
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
				c4.sent = {}
				proxy(env, "ON")
				local sent = last_set(c4)
				assert.equal("35", sent.brightness, "Previous, from the persisted mode")
				near(2700, kelvin(sent), 40, "the On colour, from the persisted presets")
			end)

			it("DYNAMIC_ON and DYNAMIC_OFF", function()
				local env, c4 = dark_light()
				proxy(env, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "1500" })
				proxy(env, "DYNAMIC_OFF")
				assert.equal(0, #c4.sent, "off already: only a report")
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
				proxy(env, "DYNAMIC_ON")
				assert.same({ rid = "l1", on = "true", brightness = "100", rate = "1500" }, last_set(c4),
					"as ON from off, at the default rate (D25)")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" })
				c4.advance(2500)
				c4.sent = {}
				proxy(env, "DYNAMIC_ON")
				assert.equal(0, #c4.sent, "on already: only a report")
				proxy(env, "DYNAMIC_OFF")
				assert.same({ rid = "l1", on = "false", rate = "1500" }, last_set(c4))
			end)

			it("OFF on a light that shows off only reports", function()
				local env, c4 = dark_light()
				proxy(env, "OFF")
				assert.equal(0, #c4.sent)
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			end)

			it("logs the first arrival of each turn-on command at debug, with every parameter", function()
				local lines = {}
				log.sink = function(line) lines[#lines + 1] = line end
				local env = dark_light()
				log.set_debug(true)
				previous_mode(env)
				previous_mode(env)
				local firsts = {}
				for _, line in ipairs(lines) do
					if line:find("first UPDATE_BRIGHTNESS_ON_MODE", 1, true) then firsts[#firsts + 1] = line end
				end
				assert.equal(1, #firsts)
				assert.truthy(firsts[1]:find("BRIGHTNESS_PRESET_ID=3", 1, true))
			end)
		end)

		describe("Colour on modes (#427)", function()
			it("a turn-on carries the On colour and sends LIGHT_COLOR_CHANGING; without an On colour none", function()
				local env, c4 = dark_light()
				proxy(env, "ON")
				assert.is_nil(last_set(c4).mirek, "no On colour known: Hue's last colour (D10)")
				assert.equal(0, #notifies(c4, "LIGHT_COLOR_CHANGING"))

				env, c4 = dark_light()
				on_and_dim(env, c4, 2700)
				proxy(env, "ON")
				local sent = last_set(c4)
				assert.same({ "l1", "true", "100", "0" }, { sent.rid, sent.on, sent.brightness, sent.rate })
				near(2700, kelvin(sent), 40, "the On colour")
				local x, y = c4:ColorCCTtoXY(2700)
				local changing = notifies(c4, "LIGHT_COLOR_CHANGING")
				assert.equal(1, #changing)
				near(x, changing[1].LIGHT_COLOR_TARGET_X, 0.0001, "target x")
				near(y, changing[1].LIGHT_COLOR_TARGET_Y, 0.0001, "target y")
				assert.equal(1, changing[1].LIGHT_COLOR_TARGET_COLOR_MODE)
				assert.equal(ON_COLOR, changing[1].LIGHT_COLOR_TARGET_PRESET_ID, "it is the On preset itself (D16)")

				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100", mirek = sent.mirek,
					color_mode = "ct" })
				local changed = notifies(c4, "LIGHT_COLOR_CHANGED")
				assert.equal(1, #changed)
				assert.equal(ON_COLOR, changed[1].LIGHT_COLOR_CURRENT_PRESET_ID)
				assert.same({ LEVEL_REPORT_MS }, delays_of(c4),
					"the report settles both targets; only the level window it opened is left (#433 D12)")
			end)

			it("turns on blended toward the Dim colour below the preset (D13, F14)", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 4000, 2000)
				proxy(env, "SET_PRESET_LEVEL", { LEVEL = "80" })
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
				near(1000000 / 3000, tonumber(last_set(c4).mirek), 5, "3000 K at 40 % (the page's example)")
				assert.is_nil(notifies(c4, "LIGHT_COLOR_CHANGING")[1].LIGHT_COLOR_TARGET_PRESET_ID,
					"a mix is no preset")
			end)

			it("a slider move while blending carries the blend; after an explicit colour it does not", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 4000, 2000)
				proxy(env, "SET_PRESET_LEVEL", { LEVEL = "80" })
				proxy(env, "ON")
				assert.equal("250", last_set(c4).mirek, "4000 K at the preset")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "80", mirek = "250",
					color_mode = "ct" })
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "1", RATE = "0" })
				assert.equal("500", last_set(c4).mirek, "the Dim colour at 1 %, clamped to the bulb's warmest")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "1", mirek = "500", color_mode = "ct" })

				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.64", LIGHT_COLOR_TARGET_Y = "0.33",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
				assert.same({ rid = "l1", x = "0.64", y = "0.33", rate = "0" }, last_set(c4))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", x = "0.64", y = "0.33", color_mode = "xy" })
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "70", RATE = "0" })
				assert.same({ rid = "l1", on = "true", brightness = "70", rate = "0" }, last_set(c4), "red stays (D14)")

				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
				proxy(env, "ON")
				assert.equal("250", last_set(c4).mirek, "the next off and on blends again")
			end)

			it("the on colour itself leaves the blend running (D16)", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 4000, 2000)
				proxy(env, "ON")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100", mirek = "250",
					color_mode = "ct" })
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_PRESET_ID = tostring(ON_COLOR),
					LIGHT_COLOR_TARGET_PRESET_ORIGIN = "1", LIGHT_COLOR_TARGET_RATE = "0" })
				assert.equal("250", last_set(c4).mirek, "the On preset by id")
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" })
				assert.truthy(last_set(c4).mirek, "still blending")
			end)

			it("a colour changed in Hue ends a Preset blend, and nothing is pushed back (§7.4)", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 4000, 2000)
				proxy(env, "ON")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100", mirek = "250",
					color_mode = "ct" })
				env.ExecuteCommand("HUE_STATE", { rid = "l1", mirek = "252", color_mode = "ct" }) -- Hue's rounding
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "0" })
				assert.truthy(last_set(c4).mirek, "a few mirek is no change")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "60", mirek = last_set(c4).mirek,
					color_mode = "ct" })
				local sent = #c4.sent
				env.ExecuteCommand("HUE_STATE", { rid = "l1", x = "0.2", y = "0.1", color_mode = "xy" }) -- the Hue app
				assert.equal(sent, #c4.sent, "nothing pushed back")
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "0" })
				assert.same({ rid = "l1", on = "true", brightness = "80", rate = "0" }, last_set(c4))
			end)

			it("a timed off carries the Dim colour; an instant off and a hold do not", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 2700, 2200)
				proxy(env, "ON")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100", mirek = "370",
					color_mode = "ct" })
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "3000" })
				local sent = last_set(c4)
				assert.same({ "false", "3000" }, { sent.on, sent.rate })
				near(2200, kelvin(sent), 40, "the Dim colour (D12)")
				local changing = notifies(c4, "LIGHT_COLOR_CHANGING")
				assert.equal(DIM_COLOR, changing[#changing].LIGHT_COLOR_TARGET_PRESET_ID)

				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100", mirek = "370",
					color_mode = "ct" })
				c4.advance(5000)
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "0" })
				assert.same({ rid = "l1", on = "false", rate = "0" }, last_set(c4), "an instant off: no colour")

				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100", mirek = "370",
					color_mode = "ct" })
				c4.advance(5000)
				c4.sent = {}
				env.ReceivedFromProxy(201, "DO_PUSH", {})
				c4.advance(400) -- the hold
				assert.same({ { rid = "l1", direction = "down", duration = "5000" } }, dims(c4))
				assert.equal(0, #hue_sets(c4), "a hold down carries no colour")
			end)

			it("a hold from off turns on at 1 % in the colour for 1 %, then dims up without colour", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 4000, 2000)
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				c4.advance(400) -- the hold time
				local first = hue_sets(c4)[1]
				assert.same({ "true", "1", "0" }, { first.on, first.brightness, first.rate })
				assert.equal("500", first.mirek, "C(1): the Dim colour, clamped to the bulb's warmest")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "1", mirek = "500",
					color_mode = "ct" })
				c4.advance(600) -- the dim up follows
				assert.same({ { rid = "l1", direction = "up", duration = "5000" } }, dims(c4))
				assert.equal(1, #hue_sets(c4))
			end)

			it("a tap to off fades to the Dim colour; a tap stop carries the blend for the estimate", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 4000, 2000)
				proxy(env, "ON")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100", mirek = "250",
					color_mode = "ct" })
				c4.sent = {}
				tap_bottom(env)
				local start = last_set(c4)
				assert.same({ "false", "3000", "500" }, { start.on, start.rate, start.mirek },
					"off over click down with the Dim colour")
				c4.advance(1500)
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				local stop = stops(c4)[1]
				assert.equal("50", stop.brightness)
				near(1000000 / (1979 + (4006 - 1979) * 49 / 99), tonumber(stop.mirek), 6, "the blend at 50 % (D15)")
			end)

			it("a hold's release sends the blend 500 ms later; a press in between cancels it", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 4000, 2000)
				proxy(env, "ON")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100", mirek = "250",
					color_mode = "ct" })
				c4.advance(2000)
				c4.sent = {}
				env.ReceivedFromProxy(201, "DO_PUSH", {})
				c4.advance(400 + 2500) -- the hold, then half the range at 5000 ms per range
				env.ReceivedFromProxy(201, "DO_RELEASE", {})
				assert.same({ "stop", "50" }, { dims(c4)[2].direction, dims(c4)[2].level })
				env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "50" })
				c4.advance(499)
				assert.equal(0, #hue_sets(c4), "not before 500 ms")
				c4.advance(1)
				local glide = last_set(c4)
				assert.same({ "l1", "1000" }, { glide.rid, glide.rate })
				assert.is_nil(glide.brightness)
				near(1000000 / (1979 + (4006 - 1979) * 49 / 99), tonumber(glide.mirek), 6,
					"the blend for 50 % below a preset of 100 % over 1 s (D15)")

				c4.advance(3000)
				c4.sent = {}
				env.ReceivedFromProxy(201, "DO_PUSH", {})
				c4.advance(400 + 1000)
				env.ReceivedFromProxy(201, "DO_RELEASE", {})
				c4.advance(200)
				env.ReceivedFromProxy(200, "DO_PUSH", {}) -- a press before the blend went
				c4.advance(1000)
				for _, params in ipairs(hue_sets(c4)) do
					assert.is_nil(params.mirek, "the blend was cancelled")
				end
			end)

			it("SET_COLOR_TARGET with only a preset id uses the learned colour, and the notifies name it", function()
				local env, c4 = lit_light()
				color_preset(env, c4, "Relax", RELAX, 0.5, 0.41)
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_PRESET_ID = tostring(RELAX),
					LIGHT_COLOR_TARGET_PRESET_ORIGIN = "2", LIGHT_COLOR_TARGET_RATE = "0" })
				assert.same({ rid = "l1", x = "0.5", y = "0.41", rate = "0" }, last_set(c4))
				local changing = notifies(c4, "LIGHT_COLOR_CHANGING")[1]
				assert.same({ RELAX, 2 }, { changing.LIGHT_COLOR_TARGET_PRESET_ID, changing.LIGHT_COLOR_TARGET_PRESET_ORIGIN })
				env.ExecuteCommand("HUE_STATE", { rid = "l1", x = "0.5", y = "0.41", color_mode = "xy" })
				local changed = notifies(c4, "LIGHT_COLOR_CHANGED")[1]
				assert.same({ RELAX, 2 }, { changed.LIGHT_COLOR_CURRENT_PRESET_ID, changed.LIGHT_COLOR_CURRENT_PRESET_ORIGIN })
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.3", LIGHT_COLOR_TARGET_Y = "0.3",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
				changing = notifies(c4, "LIGHT_COLOR_CHANGING")[2]
				assert.equal(RELAX, changing.LIGHT_COLOR_CURRENT_PRESET_ID, "where it comes from")
				assert.is_nil(changing.LIGHT_COLOR_TARGET_PRESET_ID)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", x = "0.3", y = "0.3", color_mode = "xy" })
				assert.is_nil(notifies(c4, "LIGHT_COLOR_CHANGED")[2].LIGHT_COLOR_CURRENT_PRESET_ID)

				c4.sent = {}
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_PRESET_ID = "99", LIGHT_COLOR_TARGET_RATE = "0" })
				assert.equal(0, #hue_sets(c4), "an unknown preset without x and y is ignored")
			end)

			it("a colour right after a turn-on goes out, not stored and lost (D17)", function()
				local env, c4 = dark_light()
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "0" })
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.64", LIGHT_COLOR_TARGET_Y = "0.33",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
				assert.same({ rid = "l1", x = "0.64", y = "0.33", rate = "0" }, last_set(c4),
					"sent at once (the bridge folds it into the turn-on)")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "60" })
				env.ExecuteCommand("HUE_STATE", { rid = "l1", x = "0.64", y = "0.33", color_mode = "xy" })
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
				proxy(env, "ON")
				assert.is_nil(last_set(c4).x, "nothing was left stored for a later turn-on")

				-- The same on a tap's ramp from off.
				env, c4 = dark_light()
				tap_top(env)
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.64", LIGHT_COLOR_TARGET_Y = "0.33",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
				assert.equal("0.64", last_set(c4).x)
			end)

			it("the On colour sent while off is not stored: the turn-on blends it for its level (D11, D16)", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 4000, 2000)
				proxy(env, "SET_PRESET_LEVEL", { LEVEL = "80" })
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_PRESET_ID = tostring(ON_COLOR),
					LIGHT_COLOR_TARGET_RATE = "0" })
				assert.equal(0, #c4.sent)
				assert.equal(ON_COLOR, notifies(c4, "LIGHT_COLOR_CHANGED")[1].LIGHT_COLOR_CURRENT_PRESET_ID)
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
				near(1000000 / 3000, tonumber(last_set(c4).mirek), 5, "blended, as without the colour")
			end)

			it("a colour set while off wins at the next turn-on, and no blend runs that time on (D11)", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 4000, 2000)
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.15", LIGHT_COLOR_TARGET_Y = "0.06",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
				proxy(env, "ON")
				local sent = last_set(c4)
				assert.same({ "0.15", "0.06" }, { sent.x, sent.y })
				assert.is_nil(sent.mirek)
				assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGING") - 1, "a CHANGING for it at the turn-on too")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100", x = "0.15", y = "0.06",
					color_mode = "xy" })
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" })
				assert.is_nil(last_set(c4).mirek, "blue stays")
			end)

			it("Fade: the formula on every target; an explicit colour lasts until the next target", function()
				local env, c4 = dark_light()
				local x4, y4 = c4:ColorCCTtoXY(4000)
				local x2, y2 = c4:ColorCCTtoXY(2000)
				proxy(env, "UPDATE_COLOR_ON_MODE", { COLOR_PRESET_ID = tostring(ON_COLOR), COLOR_PRESET_ORIGIN = "1",
					COLOR_PRESET_COLOR_X = tostring(x4), COLOR_PRESET_COLOR_Y = tostring(y4), COLOR_PRESET_COLOR_MODE = "1",
					COLOR_FADE_PRESET_ID = tostring(DIM_COLOR), COLOR_FADE_PRESET_ORIGIN = "1",
					COLOR_FADE_PRESET_COLOR_X = tostring(x2), COLOR_FADE_PRESET_COLOR_Y = tostring(y2),
					COLOR_FADE_PRESET_COLOR_MODE = "1" })
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "1", RATE = "0" })
				assert.equal("500", last_set(c4).mirek, "2000 K at 1 %, clamped to the bulb")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "1", mirek = "500",
					color_mode = "ct" })
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" })
				near(1000000 / (1979 + (4006 - 1979) * 49 / 99), tonumber(last_set(c4).mirek), 6, "the mix at 50 %")
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "0" })
				assert.equal("250", last_set(c4).mirek, "4000 K at 100 %")
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.64", LIGHT_COLOR_TARGET_Y = "0.33",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
				assert.equal("0.64", last_set(c4).x, "red is obeyed")
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "0" })
				assert.truthy(last_set(c4).mirek, "the next target applies the formula again (F12)")
			end)

			it("Previous: no colour at a turn-on, and no Dim colour at a timed off", function()
				local env, c4 = dark_light()
				on_and_dim(env, c4, 2700, 2200)
				color_preset(env, c4, "Previous", 13, 0.4, 0.4)
				proxy(env, "UPDATE_COLOR_ON_MODE", { COLOR_PRESET_ID = "13", COLOR_PRESET_ORIGIN = "1" })
				proxy(env, "ON")
				assert.same({ rid = "l1", on = "true", brightness = "100", rate = "0" }, last_set(c4))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" })
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "3000" })
				assert.same({ rid = "l1", on = "false", rate = "3000" }, last_set(c4))
			end)

			it("a white-only light never sends colour", function()
				local env, c4 = dark_light({ configure = { has_color = "false", has_cct = "false" } })
				on_and_dim(env, c4, 2700, 2200)
				proxy(env, "ON")
				assert.same({ rid = "l1", on = "true", brightness = "100", rate = "0" }, last_set(c4))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" })
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "3000" })
				assert.same({ rid = "l1", on = "false", rate = "3000" }, last_set(c4))
				assert.equal(0, #notifies(c4, "LIGHT_COLOR_CHANGING"))
			end)

			it("a zone light sends one colour to its grouped_light; Previous keeps each lamp's own", function()
				local env, c4 = dark_zone()
				on_and_dim(env, c4, 2700)
				proxy(env, "ON")
				near(2700, kelvin(last_set(c4)), 40, "the On colour to the group")
				env, c4 = dark_zone()
				on_and_dim(env, c4, 2700)
				color_preset(env, c4, "Previous", 13, 0.4, 0.4)
				proxy(env, "UPDATE_COLOR_ON_MODE", { COLOR_PRESET_ID = "13" })
				proxy(env, "ON")
				assert.is_nil(last_set(c4).mirek)
			end)

			it("GET_SETUP is asked 3 s after late init; what it gives is the On colour", function()
				local env, c4 = load_light({ rid = "l1", setup = "wait" })
				configure(env)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", online = "true" })
				local x, y = c4:ColorCCTtoXY(2700)
				c4.ui_answers.GET_SETUP = string.format('<setup><brightnesses><level name="On" level="100"/></brightnesses>'
					.. '<colors><color name="On" category="1" color_x="%f" color_y="%f" color_mode="1"/>'
					.. '<color name="Dim" category="1" color_x="%f" color_y="%f" color_mode="1"/></colors></setup>',
					x, y, x, y)
				c4.advance(2999)
				assert.equal(0, #c4.calls_to("SendUIRequest"))
				c4.advance(1)
				local proxy_id = fake.project.devices[LIGHT_ID].proxy_id
				assert.same({ { proxy_id, "GET_SETUP", {} } }, c4.calls_to("SendUIRequest"))
				assert.equal(0, #c4.calls_to("GetDeviceVariable"), "colours found: the variable is not read")
				assert.equal(0, #messages(c4, "HUE_SET"), "what it learns never moves the light (D26)")
				proxy(env, "ON")
				near(2700, kelvin(last_set(c4)), 40)
			end)

			it("a failing GET_SETUP is logged and ignored; variable 1300 is read instead", function()
				local lines = {}
				log.sink = function(line) lines[#lines + 1] = line end
				local env, c4 = load_light({ rid = "l1", setup = "wait" })
				configure(env)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", online = "true" })
				c4.ui_answers.GET_SETUP = function() error("no UIRequest here") end
				local proxy_id = fake.project.devices[LIGHT_ID].proxy_id
				local x, y = c4:ColorCCTtoXY(3000)
				c4.device_variables[proxy_id] = { [1300] = string.format(
					'<colors><color name="On" color_x="%f" color_y="%f" color_mode="1"/></colors>', x, y) }
				c4.advance(3000)
				local logged = false
				for _, line in ipairs(lines) do
					if line:find("GET_SETUP failed: .*no UIRequest here") then logged = true end
				end
				assert.is_true(logged)
				assert.same({ { proxy_id, 1300 } }, c4.calls_to("GetDeviceVariable"))
				proxy(env, "ON")
				near(3000, kelvin(last_set(c4)), 40, "the variable's On colour")

				-- Neither answers: nothing learned, nothing breaks.
				env, c4 = load_light({ rid = "l1", setup = "wait" })
				configure(env)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", online = "true" })
				c4.ui_answers.GET_SETUP = function() error("no") end
				proxy_id = fake.project.devices[LIGHT_ID].proxy_id
				c4.device_variables[proxy_id] = nil
				c4.GetDeviceVariable = function() error("not now") end
				assert.has_no.errors(function() c4.advance(3000) end)
				proxy(env, "ON")
				assert.is_nil(last_set(c4).mirek)
			end)

			it("destroy cancels the read of the presets and a hold's waiting blend", function()
				local env, c4 = load_light({ rid = "l1", setup = "wait" })
				env.OnDriverDestroyed("DIT_LOADED")
				assert.same({}, timer_delays(c4))
			end)
		end)

		describe("Rate ranges (#430)", function()
			it("rates above 6 000 000 are clamped in HUE_SET, and the proxy hears the time used", function()
				local env, c4 = lit_light()
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "9000000" })
				assert.equal("6000000", last_set(c4).rate)
				assert.equal(6000000, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[1].RATE)
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.4",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "7000000" })
				assert.equal("6000000", last_set(c4).rate)
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "50", RATE = "-5" })
				assert.equal("0", last_set(c4).rate, "and none below 0")
			end)

			it("a second DYNAMIC_CAPABILITIES_CHANGED carries the rate ranges, right after the colour one", function()
				local env, c4 = load_light({ rid = "l1" })
				c4.calls = {}
				configure(env)
				local dyn = notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED")
				assert.equal("true", dyn[1].supports_color)
				assert.is_nil(dyn[1].brightness_rate_max, "not in the colour notify")
				assert.same({ brightness_rate_min = 0, brightness_rate_max = 6000000, color_rate_behavior = 1,
					color_rate_min = 0, color_rate_max = 6000000 }, dyn[2])
			end)

			it("driver.xml declares the five on mode capabilities and both maxima, and no deprecated flag", function()
				local file = assert(io.open("src/hue_light/driver.xml"))
				local xml = file:read("*a")
				file:close()
				local function capability(name)
					return xml:match("<" .. name .. ">%s*(%w+)%s*</" .. name .. ">")
				end
				for _, name in ipairs({ "brightness_on_mode_preset", "brightness_on_mode_previous", "color_on_mode_preset",
					"color_on_mode_previous", "color_on_mode_fade" }) do
					assert.equal("True", capability(name), name)
				end
				assert.equal("6000000", capability("click_rate_max"))
				assert.equal("6000000", capability("hold_rate_max"))
				assert.equal("0", capability("click_rate_min"))
				assert.equal("1000", capability("hold_rate_min"))
				for _, name in ipairs({ "supports_default_on", "ramp_level", "on_off", "min_max", "buttons_are_virtual" }) do
					assert.is_nil(xml:find("<" .. name .. ">", 1, true), name)
				end
			end)
		end)
	end)

	-- #428, docs/offline-design.md: the bridge's link offline as one more
	-- blocker (D5, D6), and its answer to a command that did not land (D8,
	-- D9, §6.2 "undelivered").
	describe("the bridge's link and commands that do not land (#428)", function()
		local link = require("common.link")
		local SINCE = os.time() - 120 -- two minutes ago, in epoch seconds as the bridge sends it
		local NOT_ANSWERING = "Hue Bridge not answering since " .. link.clock(SINCE)
		local ZONE_RID = "b90ea7b4-aaaa-4bbb-8ccc-ddddeeeeffff"
		local ZONE = { rid = ZONE_RID, kind = "group", group_type = "zone", name = "Bedside Lights", light_count = "2",
			model = "Hue zone", has_color = "true", has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }

		after_each(function() log.set_debug(false) end)

		local function offline(env, reason, since)
			env.ExecuteCommand("HUE_BRIDGE_LINK", { state = "offline", reason = reason or "not_answering",
				since = tostring(since or SINCE) })
		end

		local function online(env)
			env.ExecuteCommand("HUE_BRIDGE_LINK", { state = "online" })
		end

		-- lights:undelivered's HUE_STATE: the bridge's model of the lit light
		-- (on at 40 %, 2700 K), with `extra` over it.
		local function undelivered(env, extra)
			local params = { rid = "l1", on = "true", brightness = "40", mirek = "370", color_mode = "ct", online = "true",
				reason = "undelivered" }
			for k, v in pairs(extra or {}) do params[k] = v end
			env.ExecuteCommand("HUE_STATE", params)
		end

		local function proxy(env, command, params)
			env.ReceivedFromProxy(5001, command, params or {})
		end

		-- A keypad tap on a Button Link (200 top, 201 bottom): push, release, click.
		local function link_tap(env, binding)
			env.ReceivedFromProxy(binding, "DO_PUSH", {})
			env.ReceivedFromProxy(binding, "DO_RELEASE", {})
			env.ReceivedFromProxy(binding, "DO_CLICK", {})
		end

		local function levels(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")) do out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT end
			return out
		end

		local function changing(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")) do
				out[#out + 1] = { p.LIGHT_BRIGHTNESS_CURRENT, p.LIGHT_BRIGHTNESS_TARGET, p.RATE }
			end
			return out
		end

		local function online_states(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "ONLINE_CHANGED")) do out[#out + 1] = p.STATE end
			return out
		end

		local function led_states(c4)
			local out = {}
			for _, args in ipairs(c4.calls_to("SendToProxy")) do
				if args[1] == 200 and args[2] == "MATCH_LED_STATE" then out[#out + 1] = args[3].STATE end
			end
			return out
		end

		local function sets(c4)
			local out = {}
			for _, m in ipairs(messages(c4, "HUE_SET")) do out[#out + 1] = m.params end
			return out
		end

		describe("offline (D5, D6)", function()
			it("goes offline at HUE_BRIDGE_LINK offline, Status naming the bridge, and back at online", function()
				local env, c4 = lit_light()
				offline(env)
				assert.same({ false }, online_states(c4))
				assert.equal(NOT_ANSWERING, env.Properties["Status"])
				assert.equal("Offline", env.Properties["Online"])
				assert.same({}, levels(c4), "nothing was moving: nothing to report")
				c4.calls = {}
				online(env)
				assert.same({ true }, online_states(c4))
				assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
				assert.equal("Online", env.Properties["Online"])
			end)

			it("drops every command before any CHANGING, from any source, and keeps the LEDs (E25)", function()
				local env, c4 = lit_light()
				offline(env)
				c4.calls, c4.sent = {}, {}
				log.set_debug(true)
				local lines = {}
				log.sink = function(line) lines[#lines + 1] = line end
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "0" })
				proxy(env, "ON")
				proxy(env, "TOGGLE")
				proxy(env, "SET_LEVEL", { LEVEL = "10" })
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.3", LIGHT_COLOR_TARGET_Y = "0.3",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
				link_tap(env, 200)
				c4.advance(1000)
				link_tap(env, 201)
				c4.advance(1000)
				env.ReceivedFromProxy(201, "DO_PUSH", {})
				c4.advance(500) -- held: a hold down
				env.ReceivedFromProxy(201, "DO_RELEASE", {})
				env.ExecuteCommand("Raise Level By", { Points = "30" })
				assert.same({}, c4.sent, "nothing to the bridge")
				assert.same({}, changing(c4))
				assert.same({}, notifies(c4, "LIGHT_COLOR_CHANGING"))
				assert.same({}, levels(c4))
				assert.same({}, led_states(c4), "the LEDs keep the last known state")
				assert.equal("Not raised: " .. NOT_ANSWERING, fake.last_action(env))
				assert.equal(NOT_ANSWERING, env.Properties["Status"])
				local dropped = 0
				for _, line in ipairs(lines) do
					if line:find("dropped: " .. NOT_ANSWERING, 1, true) then dropped = dropped + 1 end
				end
				assert.equal(8, dropped, "five proxy commands, two taps and a hold, each with its log line")
			end)

			it("is online only while both the link and Zigbee say so (D6)", function()
				local env, c4 = lit_light()
				offline(env)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", online = "false" })
				assert.equal(NOT_ANSWERING, env.Properties["Status"], "Zigbee's word is not current while offline")
				assert.equal("Offline", env.Properties["Online"])
				c4.calls = {}
				online(env)
				assert.same({ false }, online_states(c4), "the link is back, Zigbee still says unreachable")
				assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
				assert.equal("Offline", env.Properties["Online"])
				env.ExecuteCommand("HUE_STATE", { rid = "l1", online = "true" })
				assert.same({ false, true }, online_states(c4))
				assert.equal("Online", env.Properties["Online"])
			end)

			it("changes nothing for an unchanged link; a new reason while offline shows (D3)", function()
				local env, c4 = lit_light()
				online(env)
				assert.same({}, online_states(c4), "online after nothing (the first broadcast)")
				offline(env)
				c4.calls = {}
				offline(env)
				assert.same({}, online_states(c4), "the same offline again (a hello answer)")
				offline(env, "key_rejected")
				assert.same({ false }, online_states(c4))
				assert.equal("Hue Bridge refuses the pairing since " .. link.clock(SINCE), env.Properties["Status"])
			end)

			it("never shows online between a hello answer's link and its configure (D4)", function()
				local env, c4 = load_light({ rid = "l1" })
				c4.calls = {}
				offline(env)
				configure(env)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40", mirek = "370",
					color_mode = "ct", online = "true", reason = "hello" })
				local states = online_states(c4)
				assert.is_true(#states > 0)
				for i, s in ipairs(states) do assert.is_false(s, "ONLINE_CHANGED " .. i) end
				assert.equal(NOT_ANSWERING, env.Properties["Status"])
				assert.equal("Offline", env.Properties["Online"])
			end)

			it("takes a link sent before late init first, then greets and reports offline (E17)", function()
				local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
				c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
				c4.persist.hue_rid, c4.persist.hue_name, c4.persist.hue_model = "l1", "Desk", "Hue color lamp"
				offline(env)
				env.OnDriverLateInit("DIT_STARTUP")
				local states = online_states(c4)
				assert.is_true(#states > 0)
				for i, s in ipairs(states) do assert.is_false(s, "ONLINE_CHANGED " .. i) end
				assert.equal(NOT_ANSWERING, env.Properties["Status"])
				assert.equal("HUE_HELLO", c4.sent[1].command)
			end)

			it("forgets the link with its bridge binding: another bridge's answer says its own", function()
				local env, c4 = lit_light()
				offline(env)
				c4.bindings = {}
				env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
				assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
				c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
				env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
				assert.equal("Desk (Hue color lamp)", env.Properties["Status"])
				assert.equal("Online", env.Properties["Online"])
			end)

			it("settles a target pending as it goes offline with the cached level; no fallback follows", function()
				local env, c4 = lit_light()
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "0" })
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.3", LIGHT_COLOR_TARGET_Y = "0.3",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
				c4.calls = {}
				offline(env)
				assert.same({ 40 }, levels(c4), "the cached level, not the target")
				local colors = notifies(c4, "LIGHT_COLOR_CHANGED")
				assert.equal(1, #colors)
				assert.equal(1, colors[1].LIGHT_COLOR_CURRENT_COLOR_MODE, "the cached white, not the colour asked for")
				c4.advance(5000)
				assert.same({ 40 }, levels(c4), "no fallback assumes the target afterwards")
				assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGED"))
			end)

			it("ends a tap ramp as it goes offline, with what the bridge reported meanwhile (#421 D10)", function()
				local env, c4 = lit_light()
				link_tap(env, 200) -- 40 -> 100 over 1800 ms
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" }) -- held back
				c4.advance(600)
				c4.calls = {}
				offline(env)
				assert.same({ 100 }, levels(c4), "the bridge's word, at once")
				c4.advance(5000)
				assert.same({ 100 }, levels(c4))
				c4.sent = {}
				link_tap(env, 201)
				assert.same({}, c4.sent, "no ramp left to stop, and the tap is dropped")
			end)
		end)

		describe("undelivered (D8, D9)", function()
			it("ends a tap ramp at once and reports the bridge's level; nothing follows at its end", function()
				local env, c4 = lit_light()
				link_tap(env, 200) -- 40 -> 100 over 1800 ms
				c4.advance(600)
				c4.calls = {}
				undelivered(env) -- the bridge still knows 40: the start never landed
				assert.same({ 40 }, levels(c4))
				assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGED"), "and the colour it knows")
				c4.advance(5000)
				assert.same({ 40 }, levels(c4), "nothing at the ramp's end nor at the fallback time")
				c4.sent = {}
				link_tap(env, 200)
				assert.same({ { rid = "l1", on = "true", brightness = "100", rate = "1800", urgent = "true" } }, sets(c4),
					"the ramp is over: the next press is a fresh tap, not a stop")
			end)

			it("after a tap stop that did not land, shows the level the bridge knows (#421 D10, §7)", function()
				local env, c4 = lit_light()
				link_tap(env, 200) -- 40 -> 100 over 1800 ms
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" }) -- held back
				c4.advance(600)
				c4.calls, c4.sent = {}, {}
				link_tap(env, 201) -- stops at the estimate
				assert.same({ stop_at("60") }, stops(c4))
				assert.same({ 60 }, levels(c4))
				undelivered(env, { brightness = "100" }) -- Hue goes on to the fade's target
				assert.same({ 60, 100 }, levels(c4))
			end)

			it("settles a target given at once: the fallback never assumes it", function()
				local env, c4 = lit_light()
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "0" })
				c4.calls = {}
				undelivered(env)
				assert.same({ 40 }, levels(c4))
				c4.advance(5000)
				assert.same({ 40 }, levels(c4))
			end)

			it("reports the level the CHANGING started from when the bridge knows none (L4)", function()
				local env, c4 = load_light({ rid = "l1" })
				configure(env)
				c4.calls = {}
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "2000" })
				c4.advance(1000)
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "0" })
				assert.same({ { 0, 80, 2000 }, { 40, 20, 0 } }, changing(c4))
				env.ExecuteCommand("HUE_STATE", { rid = "l1", reason = "undelivered" }) -- no model at the bridge
				assert.same({ 40 }, levels(c4))
				c4.advance(5000)
				assert.same({ 40 }, levels(c4))
			end)

			it("names the brightness preset the light was at again (#429 D7)", function()
				local env, c4 = lit_light()
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0",
					LIGHT_BRIGHTNESS_TARGET_PRESET_ID = "5" })
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40" })
				c4.calls = {}
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "0",
					LIGHT_BRIGHTNESS_TARGET_PRESET_ID = "1" })
				assert.equal(5, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[1].LIGHT_BRIGHTNESS_CURRENT_PRESET_ID)
				undelivered(env)
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_CURRENT_PRESET_ID = 5 } },
					notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			end)

			it("closes a colour target with the colour the bridge knows", function()
				local env, c4 = lit_light()
				proxy(env, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.3", LIGHT_COLOR_TARGET_Y = "0.3",
					LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
				c4.calls = {}
				undelivered(env)
				local colors = notifies(c4, "LIGHT_COLOR_CHANGED")
				assert.equal(1, #colors)
				assert.equal(1, colors[1].LIGHT_COLOR_CURRENT_COLOR_MODE, "the white, not the colour asked for")
				c4.advance(5000)
				assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGED"), "the colour is never assumed")
			end)

			it("closes a turn-on's colour CHANGING too, and ends the blend it started (#427 D14)", function()
				local env, c4 = load_light({ rid = "l1" })
				configure(env)
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false", brightness = "70", mirek = "250",
					color_mode = "ct", online = "true", reason = "hello" })
				local x, y = c4:ColorCCTtoXY(2700)
				for _, preset in ipairs({ { "On", 11 }, { "Dim", 12 } }) do
					proxy(env, "UPDATE_COLOR_PRESET", { COMMAND = "MODIFIED", ID = tostring(preset[2]), NAME = preset[1],
						COLOR_X = tostring(x), COLOR_Y = tostring(y), COLOR_MODE = "1" })
				end
				c4.calls, c4.sent = {}, {}
				proxy(env, "ON")
				assert.is_not_nil(sets(c4)[1].mirek, "the turn-on carries the On colour")
				assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGING"))
				c4.calls = {}
				undelivered(env, { on = "false", brightness = "70", mirek = "250" })
				assert.same({ 0 }, levels(c4), "still off")
				local colors = notifies(c4, "LIGHT_COLOR_CHANGED")
				assert.equal(1, #colors)
				assert.is_nil(colors[1].LIGHT_COLOR_CURRENT_PRESET_ID, "4000 K is not the On preset")
				c4.advance(5000)
				assert.same({ 0 }, levels(c4))
				assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGED"))
				-- The Hue app turns it on; a slider move then carries no blend.
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "50", mirek = "250", color_mode = "ct" })
				c4.sent = {}
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "0" })
				assert.same({ { rid = "l1", on = "true", brightness = "30", rate = "0" } }, sets(c4))
			end)

			it("leaves a hold in progress alone: its release still sends the stop", function()
				local env, c4 = lit_light()
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				c4.advance(400) -- the hold starts: HUE_DIM up
				c4.advance(1000) -- ten ticks: 60 %
				c4.calls = {}
				undelivered(env) -- the dim did not land
				assert.same({ 40 }, levels(c4))
				env.ReceivedFromProxy(200, "DO_RELEASE", {})
				assert.same({ { rid = "l1", direction = "up", duration = "5000" },
					{ rid = "l1", direction = "stop", level = "60" } }, dims(c4))
			end)

			it("works the same for a zone light; offline drops its commands too", function()
				local env, c4 = load_light({ rid = ZONE_RID })
				env.ExecuteCommand("HUE_CONFIGURE", ZONE)
				env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "40", x = "0.4", y = "0.35",
					color_mode = "xy", online = "true", reason = "hello" })
				c4.calls, c4.sent = {}, {}
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "0" })
				env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "40", x = "0.4", y = "0.35",
					online = "true", reason = "undelivered" })
				assert.same({ 40 }, levels(c4))
				c4.advance(5000)
				assert.same({ 40 }, levels(c4))
				offline(env)
				assert.same({ false }, online_states(c4))
				assert.equal(NOT_ANSWERING, env.Properties["Status"])
				assert.equal("Offline", env.Properties["Online"])
				c4.sent = {}
				proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "80", RATE = "0" })
				assert.same({}, c4.sent)
			end)
		end)
	end)
end)
