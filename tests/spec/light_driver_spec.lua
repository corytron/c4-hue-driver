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

local function last_sent(c4)
	return c4.sent[#c4.sent]
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
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO", params = { rid = "l1", device_id = "2001" } } }, c4.sent)
			assert.equal("l1", env.Properties["Hue Light ID"])
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

		it("greets without a rid key when it has none (SendToDevice drops empty values)", function()
			local _, c4 = load_light()
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO", params = { device_id = "2001" } } }, c4.sent)
		end)

		it("greets with its persisted name and model too, and shows them before the bridge answers", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c4.persist.hue_rid, c4.persist.hue_name, c4.persist.hue_model = "l1", "Desk", "Hue color lamp"
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO",
				params = { rid = "l1", device_id = "2001", name = "Desk", model = "Hue color lamp" } } }, c4.sent)
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
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO", params = { rid = "l1", device_id = "2001" } } }, c4.sent)
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
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO", params = { rid = "l1", device_id = "2001" } } }, c4.sent)
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
				.. "; re-link or Forget"
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
			assert.equal("Gone from the Hue bridge; re-link or Forget", env.Properties["Status"])
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
			.. "Delete this device in Composer, or bind it again and use Link Devices"

		it("explains in Status, goes offline and drops proxy commands", function()
			local env, c4 = known_light()
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = "l1", name = "Desk" })
			assert.equal(FORGOTTEN, env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
			assert.equal("Forgotten by the bridge", env.Properties["Last Action"])
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
			assert.equal(1, #notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 }, { LIGHT_BRIGHTNESS_CURRENT = 55 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "both states, in arrival order")
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO",
				params = { rid = "l1", device_id = "2001", name = "Desk", model = "Hue color lamp" } } }, c4.sent,
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
	end)

	describe("actions", function()
		-- The light_v2 proxy the fake's project gave this light: the consumer of
		-- the protocol driver's binding 5001, as on the controller.
		local function proxy_of(light_id)
			return assert(fake.project.devices[light_id].proxy_id, "the fake registers a proxy per loaded light")
		end

		it("Adopt Hue Name renames the proxy device, not the protocol driver", function()
			local env, c4 = lit_light()
			local proxy_id = proxy_of(LIGHT_ID)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.same({ { proxy_id, "Desk" } }, c4.calls_to("RenameDevice"))
			assert.equal("Desk", fake.project.devices[proxy_id].name)
			assert.equal("Hue Light", fake.project.devices[LIGHT_ID].name, "the protocol driver keeps its name")
			assert.equal(string.format("Renamed device %d to Desk", proxy_id), env.Properties["Last Action"])
		end)

		it("Adopt Hue Name refuses without a Hue name or without a proxy", function()
			local env, c4 = load_light({ rid = "l1" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.truthy(env.Properties["Last Action"]:find("^Not renamed: no Hue name known yet"))

			env, c4 = lit_light()
			c4.GetBoundConsumerDevices = function() return nil end -- nothing bound, as documented
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.equal("Not renamed: no light_v2 proxy is bound to binding 5001", env.Properties["Last Action"])
		end)

		it("Forget This Light asks the bridge with HUE_FORGET", function()
			local env, c4 = lit_light()
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Light" })
			assert.same({ { id = BRIDGE_ID, command = "HUE_FORGET", params = { rid = "l1", device_id = "2001" } } },
				messages(c4, "HUE_FORGET"))
			assert.equal("Asked the bridge to forget this light; its answer sets Status", env.Properties["Last Action"])
			assert.equal("Desk (Hue color lamp)", env.Properties["Status"], "Status waits for HUE_FORGOTTEN")
		end)

		it("Forget This Light refuses when no bridge is bound", function()
			local env, c4 = load_light({ bind = false, rid = "l1" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Light" })
			assert.equal(0, #c4.sent)
			assert.equal("Not sent: not bound to a Hue Bridge", env.Properties["Last Action"])
		end)
	end)

	describe("SET_BRIGHTNESS_STOP and SET_COLOR_STOP", function()
		it("settles a pending brightness target by reporting the cached level, and cancels the fallback", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "5000" })
			assert.equal(1, #c4.active_timers())
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
			assert.equal(0, c4.fire_timers())
			assert.equal(1, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "no second CHANGED")
			assert.equal(1, #messages(c4, "HUE_SET"), "nothing more goes to the bridge")
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
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "5000" })
			env.ReceivedFromProxy(5001, "STOP_SCENE_RAMP", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
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

		it("declares the lifecycle properties and both actions", function()
			local props = fake.declared_properties("hue_light")
			assert.equal("", props["Hue Room"])
			assert.equal("", props["Last Action"])
			for _, name in ipairs({ "Adopt Hue Name", "Forget This Light" }) do
				assert.truthy(xml:find("<action>%s*<name>" .. name .. "</name>%s*<command>" .. name .. "</command>"), name)
			end
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
			assert.equal(0, #messages(c4, "HUE_SET"), "nothing goes to the bridge while off")
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
			assert.equal(2, #sends)
			assert.equal("HUE_HELLO", sends[1].command)
			assert.same({ id = BRIDGE_ID, command = "HUE_LOG",
				params = { rid = "l1", line = "[INFO] Hue Light: warming up" },
				allow_empty = false, log_command = false }, sends[2], "allowEmptyValues and logCommand off")
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
			assert.equal(1, #c4.sent, "just the HUE_HELLO")
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

		it("tap top goes to the On preset over the click rate; tap bottom turns off", function()
			local env, c4 = lit_light()
			c4.sent = {}
			press_and_click(env, 0)
			assert.equal(1, #messages(c4, "HUE_SET"))
			assert.equal("100", tostring(messages(c4, "HUE_SET")[1].params.brightness))
			assert.equal("250", tostring(messages(c4, "HUE_SET")[1].params.rate))
			c4.sent = {}
			press_and_click(env, 1)
			assert.equal("false", tostring(messages(c4, "HUE_SET")[1].params.on))
		end)

		it("uses a preset and click rate set through the proxy, and persists them", function()
			local env, c4 = lit_light()
			env.ReceivedFromProxy(5001, "SET_PRESET_LEVEL", { LEVEL = "40" })
			env.ReceivedFromProxy(5001, "SET_CLICK_RATE_UP", { RATE = "1500" })
			assert.equal(40, c4.persist.preset_level)
			assert.equal(1500, c4.persist.click_rate_up)
			c4.sent = {}
			press_and_click(env, 0)
			assert.equal("40", tostring(messages(c4, "HUE_SET")[1].params.brightness))
			assert.equal("1500", tostring(messages(c4, "HUE_SET")[1].params.rate))
		end)

		it("a held top button dims up with HUE_DIM over the scaled hold rate; the release stops at the estimate", function()
			local env, c4 = lit_light() -- on at 40 %
			c4.sent = {}
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			assert.equal(0, #c4.sent, "nothing until the hold timer")
			c4.fire_timers() -- the 400 ms hold timer: the ramp starts
			assert.same({ { rid = "l1", direction = "up", duration = "3000" } }, dims(c4), "60 % of 5000 ms")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 3000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			for _ = 1, 10 do c4.fire_timers() end -- ten 100 ms ticks: about a third of the way
			c4.sent = {}
			c4.calls = {}
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "0" })
			assert.same({ { rid = "l1", direction = "stop", level = "60" } }, dims(c4))
			assert.equal(0, #messages(c4, "HUE_SET"), "no absolute target for a hold any more")
			assert.equal(2, #c4.active_timers(), "the brightness fallback and the click guard")
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
			assert.same({ { rid = "l1", direction = "down", duration = "1950" } }, dims(c4), "39 % of 5000 ms")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 1, RATE = 1950 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.equal(0, #messages(c4, "HUE_SET"))
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
			assert.same({ { rid = "l1", direction = "up", duration = "4950" } }, dims(c4))
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

		it("a click on binding 200 turns on to the preset, on 201 off, with no proxy echo", function()
			local env, c4 = lit_light()
			c4.sent = {}
			c4.calls = {}
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.equal(1, #messages(c4, "HUE_SET"))
			assert.equal("100", tostring(messages(c4, "HUE_SET")[1].params.brightness))
			assert.equal(0, #notifies(c4, "BUTTON_ACTION"))
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
			} }, notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"), "the union of the members, as for a bulb")
			assert.same({ hue_rid = ZONE_RID, hue_name = "Bedside Lights", hue_model = "Hue zone", hue_kind = "group" },
				c4.persist)
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
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO",
				params = { rid = ZONE_RID, device_id = "2001", name = "Bedside Lights", kind = "group" } } }, c4.sent)
			assert.equal("Hue zone Bedside Lights", env.Properties["Status"],
				"the persisted model stands in for the type until the bridge answers")
			assert.equal(ZONE_RID, env.Properties["Hue Light ID"])
			assert.equal("", env.Properties["Online"])
		end)

		it("applies a configure buffered before late init, and the hello carries the kind it delivered", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			configure_group(env, ZONE)
			assert.equal(0, #c4.calls_to("PersistSetValue"))
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal("Hue zone Bedside Lights (2 lights)", env.Properties["Status"])
			assert.same({ { id = BRIDGE_ID, command = "HUE_HELLO",
				params = { rid = ZONE_RID, device_id = "2001", name = "Bedside Lights", kind = "group" } } }, c4.sent)
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
			assert.equal("Group deleted in Hue since " .. os.date("%Y-%m-%d", 1761000000) .. "; re-link or Forget",
				env.Properties["Status"])
			assert.equal("Hue zone", env.Properties["Model"])

			configure_group(env, ZONE, { kind = "entertainment" })
			assert.equal("group", c4.persist.hue_kind)
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
			local expected = "Zone deleted in Hue since " .. os.date("%Y-%m-%d", 1761000000) .. "; re-link or Forget"
			assert.equal(expected, fits(env.Properties["Status"]))
			assert.equal("Offline", env.Properties["Online"])
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))

			c4.sent = {}
			c4.calls = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(0, #c4.sent, "dropped")
			assert.equal(expected, env.Properties["Status"])

			-- Re-link Device To Light to another zone: a configure with the new identity.
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
			assert.equal("Room deleted in Hue; re-link or Forget", env.Properties["Status"])
		end)

		it("names the zone when forgotten and puts the instruction in Last Action", function()
			local env, c4 = lit_zone()
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = ZONE_RID, name = "Bedside Lights" })
			assert.equal("Forgotten by the bridge (was Hue zone Bedside Lights)", fits(env.Properties["Status"]))
			assert.equal("Delete this device in Composer, or bind it again and use Link Devices",
				env.Properties["Last Action"])
			assert.equal("Offline", env.Properties["Online"])
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))

			c4.sent = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "75", RATE = "0" })
			assert.equal(0, #c4.sent)
			assert.same({ hue_rid = ZONE_RID, hue_name = "Bedside Lights", hue_model = "Hue zone", hue_kind = "group" },
				c4.persist, "the identity stays, so binding the device again lets Link Devices adopt it")

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
			assert.same({ {
				supports_color = "false",
				supports_color_correlated_temperature = "true",
				color_correlated_temperature_min = 2210,
				color_correlated_temperature_max = 6530,
			} }, notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"), "both flags in one notify")
			assert.equal("Hue zone Bedside Lights (3 lights)", env.Properties["Status"])

			c4.calls = {}
			configure_group(env, ZONE, { has_color = "false", has_cct = "false", light_count = "3" })
			assert.same({ { supports_color = "false", supports_color_correlated_temperature = "false" } },
				notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"))

			c4.calls = {}
			configure_group(env, ZONE, { light_count = "3" })
			assert.equal(1, #notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"), "every configure announces them again")
			assert.equal("true", notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED")[1].supports_color)
		end)

		it("drives the group exactly as a light: HUE_DIM holds, HUE_SET bodies, HUE_STATE mapping", function()
			local env, c4 = lit_zone() -- on at 40 %
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time
			assert.same({ { rid = ZONE_RID, direction = "up", duration = "3000" } }, dims(c4))
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
			assert.same({ LIGHT_BRIGHTNESS_CURRENT = 0 }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")[2])
			assert.equal(1, #c4.active_timers(), "only the hold's click guard is left: both targets were confirmed")
		end)

		it("Adopt Hue Name and Forget This Light speak of the zone or room", function()
			local env, c4 = lit_zone()
			local proxy_id = proxy_of(LIGHT_ID)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.same({ { proxy_id, "Bedside Lights" } }, c4.calls_to("RenameDevice"), "a zone's name verbatim")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Light" })
			assert.same({ rid = ZONE_RID, device_id = "2001" }, messages(c4, "HUE_FORGET")[1].params)
			assert.equal("Asked the bridge to forget this zone light; its answer sets Status", env.Properties["Last Action"])

			env, c4 = load_light({ rid = ROOM_RID })
			configure_group(env, ROOM)
			proxy_id = proxy_of(LIGHT_ID)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.same({ { proxy_id, "Master Bedroom Lights" } }, c4.calls_to("RenameDevice"),
				"a room device is <Room> Lights (contract §5 Naming)")
			assert.equal(string.format("Renamed device %d to Master Bedroom Lights", proxy_id), env.Properties["Last Action"])
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Light" })
			assert.equal("Asked the bridge to forget this room light; its answer sets Status", env.Properties["Last Action"])

			env = load_light({ rid = ZONE_RID })
			configure_group(env, ZONE, nil, { "name" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.equal("Not renamed: no Hue name known yet (the bridge has not configured this zone light)",
				env.Properties["Last Action"])
		end)
	end)
end)
