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
end)
