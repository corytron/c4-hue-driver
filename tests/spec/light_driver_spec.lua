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

-- opts.bind=false leaves the light unbound; opts.rid persists a rid first.
local function load_light(opts)
	opts = opts or {}
	local env, c4 = fake.load_driver("hue_light", opts.props or {}, { device_id = LIGHT_ID })
	if opts.bind ~= false then
		c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
	end
	if opts.rid then
		c4.persist.hue_rid = opts.rid
	end
	env.OnDriverLateInit("DIT_STARTUP")
	return env, c4
end

local function configure(env, extra)
	local params = {}
	for k, v in pairs(CONFIGURE) do params[k] = v end
	for k, v in pairs(extra or {}) do params[k] = v end
	env.ExecuteCommand("HUE_CONFIGURE", params)
end

-- A configured, on, white light at 40%.
local function lit_light()
	local env, c4 = load_light({ rid = "l1" })
	configure(env)
	env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "40", mirek = "370",
		color_mode = "ct", online = "true", reason = "hello" })
	c4.calls = {}
	c4.sent = {}
	return env, c4
end

-- Params of every SendToProxy with that command, in order.
local function notifies(c4, command)
	local out = {}
	for _, args in ipairs(c4.calls_to("SendToProxy")) do
		assert.equal(5001, args[1])
		if args[2] == command then out[#out + 1] = args[3] end
	end
	return out
end

local function last_sent(c4)
	return c4.sent[#c4.sent]
end

describe("Hue Light driver", function()
	before_each(quiet)

	describe("startup and binding", function()
		it("greets the bridge with its persisted rid on late init", function()
			local env, c4 = load_light({ rid = "l1" })
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO", params = { rid = "l1" } } }, c4.sent)
			assert.equal("l1", env.Properties["Hue Light ID"])
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
			assert.equal("", env.Properties["Online"], "not known until the bridge says")
			assert.equal("1", env.Properties["Driver Version"])
		end)

		it("greets without a rid key when it has none (SendToDevice drops empty values)", function()
			local _, c4 = load_light()
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO", params = {} } }, c4.sent)
		end)

		it("accepts GetBoundProviderDevice answering with a table of id/name pairs", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4.GetBoundProviderDevice = function() return { [BRIDGE_ID] = "Hue Bridge" } end
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(BRIDGE_ID, c4.sent[1].id)
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
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO", params = { rid = "l1" } } }, c4.sent)
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
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO", params = { rid = "l1" } } }, c4.sent)
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
		it("stores the rid, fills the properties and sends one capabilities notify with both supports_* keys", function()
			local env, c4 = load_light()
			c4.calls = {}
			configure(env)

			assert.equal("l1", c4.persist.hue_rid)
			assert.equal("l1", env.Properties["Hue Light ID"])
			assert.equal("Desk", env.Properties["Hue Name"])
			assert.equal("Hue color lamp", env.Properties["Model"])
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"])

			local dyn = notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED")
			assert.equal(1, #dyn)
			assert.same({
				supports_color = "true",
				supports_color_correlated_temperature = "true",
				color_correlated_temperature_min = 2000,
				color_correlated_temperature_max = 6530,
			}, dyn[1])
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "state not known yet")
			assert.equal(0, #notifies(c4, "LIGHT_COLOR_CHANGED"))
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
		end)

		it("re-reports known state after a re-configure", function()
			local env, c4 = lit_light()
			configure(env)
			assert.equal(1, #notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(1, #notifies(c4, "LIGHT_COLOR_CHANGED"))
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
			assert.equal(1, #timers)
			assert.equal(1500, timers[1].delay, "rate + 1000 ms")
			c4.fire_timers()
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 75 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("turns the light off for target 0", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "0" })
			assert.same({ rid = "l1", on = "false", rate = "0" }, last_sent(c4).params)
			c4.fire_timers()
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("lets a confirming HUE_STATE send CHANGED and cancel the fallback", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "500" })
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "75", reason = "event" })
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

		it("logs every param of the first one received, once", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local env = lit_light()
			local params = { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35", LIGHT_COLOR_TARGET_COLOR_MODE = "0" }
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", params)
			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", params)
			local hits = 0
			for _, line in ipairs(lines) do
				if line:find("first SET_COLOR_TARGET params:", 1, true) then
					hits = hits + 1
					assert.truthy(line:find("LIGHT_COLOR_TARGET_X=0.4", 1, true))
					assert.truthy(line:find("LIGHT_COLOR_TARGET_COLOR_MODE=0", 1, true))
				end
			end
			assert.equal(1, hits)
		end)

		it("stores the colour while off, closes with CHANGED, and sends it with the next turn-on", function()
			local env, c4 = lit_light()
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "false" })
			c4.calls = {}
			c4.sent = {}

			env.ReceivedFromProxy(5001, "SET_COLOR_TARGET", { LIGHT_COLOR_TARGET_X = "0.4", LIGHT_COLOR_TARGET_Y = "0.35",
				LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "0" })
			assert.equal(0, #c4.sent, "nothing goes to the bridge while off")
			assert.equal(0, #c4.active_timers())
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
			assert.equal(0, #c4.active_timers())
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
			-- The instance the driver loaded (fake.load_driver reloads common.* per driver).
			local devloop = require("common.devloop")
			local got
			local original = devloop.apply_forwarded
			devloop.apply_forwarded = function(params) got = params end
			local ok, err = pcall(function()
				env.ExecuteCommand("DEV_RELOAD", { version = "7", files = "{}" })
				assert.same({ version = "7", files = "{}" }, got)
			end)
			devloop.apply_forwarded = original
			assert(ok, err)
		end)
	end)
end)
