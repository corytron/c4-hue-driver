-- Hue Scene driver against the fake runtime, with a bridge driver standing
-- behind binding 1 as device 15 (bound with C4:Bind, as Composer or the
-- bridge's Add Scene would), so SendToDevice to it can be asserted on.
-- The contract is docs/scenes-design.md §2 (messages) and §3 (this device).

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BRIDGE_ID = 15
local SCENE_ID = 2061

-- The scene HUE_SCENE_CONFIGURE describes, every value a string as Director hands it over.
local CONFIGURE = { rid = "s1", name = "Relax", group_name = "Kitchen", group_type = "room",
	id_v1 = "/scenes/AbCdEf", auto_dynamic = "false", state = "linked" }

local LINKED_STATUS = "Hue scene Relax in Kitchen"

local function quiet()
	log.sink = function() end
end

-- opts.bind=false leaves the device unbound; opts.rid persists a rid first.
local function load_scene(opts)
	opts = opts or {}
	local env, c4 = fake.load_driver("hue_scene", opts.props or {}, { device_id = SCENE_ID })
	if opts.bind ~= false then
		c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
	end
	if opts.rid then
		c4.persist.hue_rid = opts.rid
	end
	if opts.name then
		c4.persist.hue_name = opts.name
	end
	env.OnDriverLateInit("DIT_STARTUP")
	return env, c4
end

local function configure(env, extra)
	local params = {}
	for k, v in pairs(CONFIGURE) do params[k] = v end
	for k, v in pairs(extra or {}) do params[k] = v end
	env.ExecuteCommand("HUE_SCENE_CONFIGURE", params)
end

local function state(env, active, extra)
	local params = { rid = "s1", active = active, reason = "event" }
	for k, v in pairs(extra or {}) do params[k] = v end
	env.ExecuteCommand("HUE_SCENE_STATE", params)
end

-- A configured scene whose status the bridge has reported (inactive unless
-- told otherwise), with the recording cleared.
local function known_scene(active, opts)
	local env, c4 = load_scene(opts or { rid = "s1" })
	configure(env)
	state(env, active or "inactive", { reason = "hello" })
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

describe("Hue Scene driver", function()
	before_each(quiet)

	describe("startup and binding", function()
		it("greets the bridge with its persisted rid on late init", function()
			local env, c4 = load_scene({ rid = "s1" })
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_HELLO", params = { rid = "s1", device_id = "2061" } } },
				c4.sent)
			assert.equal("s1", env.Properties["Hue Scene ID"])
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
			assert.equal("", env.Properties["Online"], "not known until the bridge says")
			assert.equal("1", env.Properties["Driver Version"])
		end)

		it("greets without a rid key when it has none (SendToDevice drops empty values)", function()
			local _, c4 = load_scene()
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_HELLO", params = { device_id = "2061" } } }, c4.sent)
		end)

		it("greets with its persisted name too, and shows it before the bridge answers", function()
			local env, c4 = load_scene({ rid = "s1", name = "Relax" })
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_HELLO",
				params = { rid = "s1", device_id = "2061", name = "Relax" } } }, c4.sent)
			assert.equal("Relax", env.Properties["Status"])
			assert.equal("Relax", env.Properties["Hue Scene"])
			assert.equal("", env.Properties["Online"], "still not known until the bridge says")
		end)

		it("accepts GetBoundProviderDevice answering with a table of id/name pairs", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			c4.GetBoundProviderDevice = function() return { [BRIDGE_ID] = "Hue Bridge" } end
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(BRIDGE_ID, c4.sent[1].id)
		end)

		it("treats GetBoundProviderDevice answering 0 as unbound (OS 3.4.2 with nothing bound)", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			c4.GetBoundProviderDevice = function() return 0 end
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(0, #c4.sent)
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
		end)

		it("stays quiet and says so when no bridge is bound", function()
			local env, c4 = load_scene({ bind = false })
			assert.equal(0, #c4.sent)
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))
		end)

		it("re-greets the bridge when binding 1 is bound later, and goes offline when unbound", function()
			local env, c4 = load_scene({ bind = false, rid = "s1" })
			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_HELLO", params = { rid = "s1", device_id = "2061" } } },
				c4.sent)
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])

			c4.calls = {}
			c4.bindings = {}
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
		end)

		it("settles a pending recall when the bridge is unbound, so no fallback fires", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal(1, #c4.active_timers())
			c4.bindings = {}
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.equal(0, #c4.active_timers())
		end)

		it("trusts the device id in the binding notification when the lookup lags behind", function()
			local env, c4 = load_scene({ bind = false, rid = "s1" })
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_HELLO", params = { rid = "s1", device_id = "2061" } } },
				c4.sent)
		end)

		it("ignores binding changes other than the bridge's", function()
			local env, c4 = load_scene({ rid = "s1" })
			c4.sent = {}
			c4.calls = {}
			env.OnBindingChanged(5001, "LIGHT_V2", true, 99, 1)
			assert.equal(0, #c4.sent)
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)
	end)

	describe("HUE_SCENE_CONFIGURE", function()
		it("stores the identity, fills the properties and reports online, without any state yet", function()
			local env, c4 = load_scene()
			c4.calls = {}
			configure(env)

			assert.same({ hue_rid = "s1", hue_name = "Relax", recall_as = "active" }, c4.persist)
			assert.equal("#AbCdEf (s1)", env.Properties["Hue Scene ID"], "a rid without dashes is shown whole")
			assert.equal("Relax", env.Properties["Hue Scene"])
			assert.equal("Kitchen", env.Properties["Hue Room"])
			assert.equal(LINKED_STATUS, env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])

			assert.equal(0, #notifies(c4, "DYNAMIC_CAPABILITIES_CHANGED"), "the switch declares everything statically")
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "state not known yet")
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
		end)

		it("shortens a UUID rid behind the v1 id, and shows the rid alone without one", function()
			local env = load_scene()
			configure(env, { rid = "0f3a2b1c-1234-5678-9abc-def012345678" })
			assert.equal("#AbCdEf (0f3a2b1c…)", env.Properties["Hue Scene ID"])
			configure(env, { rid = "s1", id_v1 = "" })
			assert.equal("s1", env.Properties["Hue Scene ID"])
		end)

		it("labels a zone and the bridge home after the lights' wording", function()
			local env = load_scene()
			configure(env, { group_name = "Downstairs", group_type = "zone" })
			assert.equal("Downstairs (zone)", env.Properties["Hue Room"])
			assert.equal("Hue scene Relax in Downstairs (zone)", env.Properties["Status"])
			configure(env, { group_name = "Home", group_type = "bridge_home" })
			assert.equal("Home (bridge home)", env.Properties["Hue Room"])
		end)

		it("reads an absent group as none (SendToDevice drops empty values)", function()
			local env = load_scene()
			configure(env)
			configure(env, { group_name = "", group_type = "" })
			assert.equal("", env.Properties["Hue Room"])
			assert.equal("Hue scene Relax in (no room)", env.Properties["Status"])
		end)

		it("refreshes the persisted name with every configure", function()
			local env, c4 = load_scene()
			configure(env)
			configure(env, { name = "Relax Evening" })
			assert.equal("Relax Evening", c4.persist.hue_name)
			assert.equal("Relax Evening", env.Properties["Hue Scene"])
		end)

		it("re-reports the known status after a re-configure", function()
			local env, c4 = known_scene("static")
			configure(env)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
		end)

		it("takes a scene offline while the bridge says it is gone, and back when it is linked again", function()
			local env, c4 = known_scene("static")
			configure(env, { state = "gone", gone_since = "1761000000" })
			local expected = "Scene deleted in Hue since " .. os.date("%Y-%m-%d %H:%M", 1761000000)
				.. "; ON does nothing; re-link or Forget"
			assert.equal(expected, env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))

			c4.calls = {}
			configure(env, { state = "linked" })
			assert.equal(LINKED_STATUS, env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
		end)

		it("says deleted without a date when the bridge sends none", function()
			local env = known_scene()
			configure(env, { state = "gone" })
			assert.equal("Scene deleted in Hue; ON does nothing; re-link or Forget", env.Properties["Status"])
		end)

		it("while gone, drops ON with a warning and reports OFF at once, nothing to the bridge", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local env, c4 = known_scene("static")
			configure(env, { state = "gone" })
			c4.calls = {}
			c4.sent = {}

			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal(0, #messages(c4, "HUE_SCENE_RECALL"))
			assert.equal(0, #messages(c4, "HUE_SCENE_OFF"))
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
			local warned = false
			for _, line in ipairs(lines) do
				if line:find("^%[WARN%] Hue Scene: ON dropped: scene deleted in Hue") then warned = true end
			end
			assert.is_true(warned)
		end)
	end)

	describe("HUE_SCENE_STATE", function()
		it("maps static and dynamic_palette to 100 and inactive to 0", function()
			local env, c4 = load_scene()
			configure(env)
			c4.calls = {}
			state(env, "static")
			state(env, "inactive")
			state(env, "dynamic_palette")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 }, { LIGHT_BRIGHTNESS_CURRENT = 0 },
				{ LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #notifies(c4, "ONLINE_CHANGED"))
		end)

		it("says nothing when the switch position has not changed", function()
			local env, c4 = known_scene("static")
			state(env, "static", { reason = "resync" })
			state(env, "dynamic_palette", { reason = "event" })
			assert.equal(0, #c4.calls_to("SendToProxy"), "static to dynamic is still on")
		end)

		it("reports the first status even when it is inactive", function()
			local env, c4 = load_scene()
			configure(env)
			c4.calls = {}
			state(env, "inactive", { reason = "hello" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("ignores state for another rid", function()
			local env, c4 = known_scene()
			env.ExecuteCommand("HUE_SCENE_STATE", { rid = "other", active = "static" })
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)

		it("ignores an unknown status value", function()
			local env, c4 = known_scene()
			state(env, "sparkly")
			assert.equal(0, #c4.calls_to("SendToProxy"))
			env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "cache untouched")
		end)
	end)

	describe("ON", function()
		it("acknowledges with CHANGING 0 -> 100, asks the bridge to recall, and falls back to CHANGED 100", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "ON", {})

			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 0 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ id = BRIDGE_ID, command = "HUE_SCENE_RECALL", params = { rid = "s1", action = "active" } },
				last_sent(c4))
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))

			local timers = c4.active_timers()
			assert.equal(1, #timers)
			assert.equal(2000, timers[1].delay, "2 s fallback")
			c4.fire_timers()
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
		end)

		it("lets the bridge's STATE send CHANGED and cancel the fallback", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "ON", {})
			state(env, "static", { reason = "recall" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
			assert.equal(0, c4.fire_timers())
			assert.equal(1, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "no second CHANGED")
		end)

		it("always answers a CHANGING with a CHANGED, even when the status did not change", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "ON", {})
			state(env, "static", { reason = "recall" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("closes the transaction with whatever the bridge reports, inactive included", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "ON", {})
			state(env, "inactive", { reason = "event" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
		end)

		it("corrects the proxy when a later report contradicts an assumed recall", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "ON", {})
			c4.fire_timers()
			state(env, "inactive", { reason = "resync" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 }, { LIGHT_BRIGHTNESS_CURRENT = 0 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("sends the ramp as the recall's duration in ms, only when there is one", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "1500" })
			assert.same({ rid = "s1", action = "active", duration = "1500" }, last_sent(c4).params)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 1500 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "0" })
			assert.is_nil(last_sent(c4).params.duration)
		end)

		it("re-arms the fallback when a second ON follows before the first settles", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal(1, #c4.active_timers())
			assert.equal(2, #messages(c4, "HUE_SCENE_RECALL"))
			c4.fire_timers()
			assert.equal(1, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("assumes the palette plays when Hue would (auto_dynamic) and TOGGLE then turns it off", function()
			local env, c4 = known_scene()
			configure(env, { auto_dynamic = "true" })
			c4.calls = {}
			env.ReceivedFromProxy(5001, "ON", {})
			c4.fire_timers()
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal("HUE_SCENE_OFF", last_sent(c4).command)
		end)
	end)

	describe("OFF", function()
		it("acknowledges with CHANGING 100 -> 0, asks the bridge for off, and falls back to CHANGED 0", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "OFF", {})

			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100, LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ id = BRIDGE_ID, command = "HUE_SCENE_OFF", params = { rid = "s1" } }, last_sent(c4))
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))

			assert.equal(2000, c4.active_timers()[1].delay)
			c4.fire_timers()
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("carries the ramp in CHANGING but never to the bridge", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "3000" })
			assert.equal(3000, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[1].RATE)
			assert.same({ rid = "s1" }, last_sent(c4).params)
		end)

		it("lets the bridge's STATE inactive settle it", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "OFF", {})
			state(env, "inactive", { reason = "recall" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
		end)
	end)

	describe("TOGGLE, SET_BRIGHTNESS_TARGET, SET_LEVEL and RAMP_TO_LEVEL", function()
		it("toggles from the cached status: on goes off, off and unknown go on", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal("HUE_SCENE_OFF", last_sent(c4).command)
			state(env, "inactive")
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal("HUE_SCENE_RECALL", last_sent(c4).command)

			env, c4 = load_scene({ rid = "s1" })
			configure(env)
			c4.sent = {}
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal("HUE_SCENE_RECALL", last_sent(c4).command, "unknown status toggles on")
		end)

		it("toggles against a pending target, so two quick presses end up off", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.same({ "HUE_SCENE_RECALL", "HUE_SCENE_OFF" }, { c4.sent[1].command, c4.sent[2].command })
			assert.equal(1, #c4.active_timers(), "the second target replaced the first's fallback")
		end)

		it("treats any target above zero as ON and zero as OFF", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "37", RATE = "0" })
			assert.equal("HUE_SCENE_RECALL", last_sent(c4).command)
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "0" })
			assert.equal("HUE_SCENE_OFF", last_sent(c4).command)
			env.ReceivedFromProxy(5001, "SET_LEVEL", { LEVEL = "50", TIME = "2000" })
			assert.same({ rid = "s1", action = "active", duration = "2000" }, last_sent(c4).params)
			env.ReceivedFromProxy(5001, "SET_LEVEL", { LEVEL = "0", TIME = "0" })
			assert.equal("HUE_SCENE_OFF", last_sent(c4).command)
			env.ReceivedFromProxy(5001, "RAMP_TO_LEVEL", { LEVEL = "100", TIME = "4000" })
			assert.same({ rid = "s1", action = "active", duration = "4000" }, last_sent(c4).params)
			assert.equal(5, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
		end)

		it("ignores a target command without a target", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { RATE = "0" })
			assert.equal(0, #messages(c4, "HUE_SCENE_RECALL"))
			assert.equal(0, #messages(c4, "HUE_SCENE_OFF"))
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)
	end)

	describe("Recall As", function()
		it("maps the three choices to Hue's recall actions", function()
			local env, c4 = known_scene(nil, { rid = "s1", props = { ["Recall As"] = "Static" } })
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal("static", last_sent(c4).params.action)

			env, c4 = known_scene(nil, { rid = "s1", props = { ["Recall As"] = "Dynamic" } })
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal("dynamic_palette", last_sent(c4).params.action)

			env, c4 = known_scene(nil, { rid = "s1", props = { ["Recall As"] = "As set in Hue" } })
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal("active", last_sent(c4).params.action)
		end)

		it("follows a change made in Composer and persists the action", function()
			local env, c4 = known_scene()
			assert.equal("active", c4.persist.recall_as, "the default, persisted at late init")
			env.Properties["Recall As"] = "Dynamic"
			env.OnPropertyChanged("Recall As")
			assert.equal("dynamic_palette", c4.persist.recall_as)
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal("dynamic_palette", last_sent(c4).params.action)
			c4.fire_timers()
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal("HUE_SCENE_OFF", last_sent(c4).command, "an assumed dynamic recall counts as on")
		end)

		it("falls back to Hue's own choice for a value it does not know", function()
			local env, c4 = known_scene()
			env.Properties["Recall As"] = "Sparkly"
			env.OnPropertyChanged("Recall As")
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal("active", last_sent(c4).params.action)
			assert.equal("active", c4.persist.recall_as)
		end)

		it("is declared as a list defaulting to Hue's own choice", function()
			local props = fake.declared_properties("hue_scene")
			assert.equal("As set in Hue", props["Recall As"])
		end)
	end)

	describe("SET_BRIGHTNESS_STOP", function()
		it("settles a pending recall by reporting the cached status, and cancels the fallback", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal(1, #c4.active_timers())
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
			assert.equal(0, c4.fire_timers())
			assert.equal(1, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "no second CHANGED")
			assert.equal(1, #c4.sent, "nothing more goes to the bridge")
		end)

		it("assumes the target when nothing is cached yet, so the proxy never waits on a CHANGING", function()
			local env, c4 = load_scene({ rid = "s1" })
			configure(env)
			c4.calls = {}
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
		end)

		it("reports the cached status even with no transition in progress", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.sent)
		end)

		it("accepts STOP_SCENE_RAMP as a brightness stop", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "OFF", {})
			env.ReceivedFromProxy(5001, "STOP_SCENE_RAMP", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #c4.active_timers())
		end)
	end)

	describe("SYNCHRONIZE", function()
		it("replays online and the cached status", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
			local calls = c4.calls_to("SendToProxy")
			assert.equal(2, #calls)
			assert.same({ "ONLINE_CHANGED", { STATE = true } }, { calls[1][2], calls[1][3] })
			assert.same({ "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 100 } }, { calls[2][2], calls[2][3] })
		end)

		it("replays only what is known", function()
			local env, c4 = load_scene({ rid = "s1" })
			c4.calls = {}
			env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
			assert.equal(1, #c4.calls_to("SendToProxy"))
		end)
	end)

	describe("HUE_SCENE_FORGOTTEN", function()
		local FORGOTTEN = "Forgotten by the bridge (was Hue scene Relax). "
			.. "Delete this device in Composer, or bind it again and use Link Devices"

		it("explains in Status, goes offline and drops proxy commands", function()
			local env, c4 = known_scene("static")
			env.ExecuteCommand("HUE_SCENE_FORGOTTEN", { rid = "s1", name = "Relax" })
			assert.equal(FORGOTTEN, env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
			assert.equal("Forgotten by the bridge", env.Properties["Last Action"])
			assert.same({ { STATE = false } }, notifies(c4, "ONLINE_CHANGED"))

			c4.calls = {}
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "OFF", {})
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal(0, #messages(c4, "HUE_SCENE_RECALL"))
			assert.equal(0, #messages(c4, "HUE_SCENE_OFF"))
			assert.equal(0, #c4.calls_to("SendToProxy"), "not even CHANGING")
			assert.equal(0, #c4.active_timers())
			assert.equal(FORGOTTEN, env.Properties["Status"])
			assert.same({ hue_rid = "s1", hue_name = "Relax", recall_as = "active" }, c4.persist,
				"the identity stays, so binding the device again lets the bridge adopt it")
		end)

		it("names the scene from its own state when the message carries no name", function()
			local env = known_scene()
			env.ExecuteCommand("HUE_SCENE_FORGOTTEN", { rid = "s1" })
			assert.equal(FORGOTTEN, env.Properties["Status"])
		end)

		it("keeps the forgotten text when the bridge then unbinds it", function()
			local env, c4 = known_scene()
			env.ExecuteCommand("HUE_SCENE_FORGOTTEN", { rid = "s1", name = "Relax" })
			c4.bindings = {}
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.equal(FORGOTTEN, env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
		end)

		it("is cleared by the next HUE_SCENE_CONFIGURE", function()
			local env, c4 = known_scene()
			env.ExecuteCommand("HUE_SCENE_FORGOTTEN", { rid = "s1", name = "Relax" })
			c4.calls = {}
			configure(env)
			assert.equal(LINKED_STATUS, env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
			assert.same({ { STATE = true } }, notifies(c4, "ONLINE_CHANGED"))
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
		end)

		it("settles a pending recall so no fallback fires afterwards", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal(1, #c4.active_timers())
			env.ExecuteCommand("HUE_SCENE_FORGOTTEN", { rid = "s1", name = "Relax" })
			assert.equal(0, #c4.active_timers())
		end)

		it("ignores a forgotten for another rid", function()
			local env, c4 = known_scene()
			env.ExecuteCommand("HUE_SCENE_FORGOTTEN", { rid = "other", name = "Bright" })
			assert.equal(LINKED_STATUS, env.Properties["Status"])
			assert.equal(0, #c4.calls_to("SendToProxy"))
		end)
	end)

	describe("before late init", function()
		it("buffers CONFIGURE, STATE and FORGOTTEN and applies them in order from OnDriverLateInit", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			configure(env)
			state(env, "static", { reason = "resync" })
			state(env, "inactive")
			assert.equal(0, #c4.calls_to("UpdateProperty"), "nothing touches Director before late init")
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.equal(0, #c4.calls_to("PersistSetValue"))
			assert.equal(0, #c4.sent)

			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(LINKED_STATUS, env.Properties["Status"])
			assert.equal("s1", c4.persist.hue_rid)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 }, { LIGHT_BRIGHTNESS_CURRENT = 0 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "both states, in arrival order")
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_HELLO",
				params = { rid = "s1", device_id = "2061", name = "Relax" } } }, c4.sent,
				"the hello carries the identity the buffered configure delivered")
			local online = notifies(c4, "ONLINE_CHANGED")
			assert.same({ STATE = true }, online[#online])
		end)

		it("applies a buffered FORGOTTEN after the configure that preceded it", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			configure(env)
			env.ExecuteCommand("HUE_SCENE_FORGOTTEN", { rid = "s1", name = "Relax" })
			env.OnDriverLateInit("DIT_STARTUP")
			assert.truthy(env.Properties["Status"]:find("^Forgotten by the bridge %(was Hue scene Relax%)"))
			assert.equal("Offline", env.Properties["Online"])
		end)

		it("handles messages at once after late init, and again after a dev reload's late init", function()
			local env, c4 = load_scene({ rid = "s1" })
			configure(env)
			assert.equal(LINKED_STATUS, env.Properties["Status"])
			env.OnDriverLateInit("DIT_STARTUP") -- the dev loop re-runs the entry points after a reload
			c4.calls = {}
			state(env, "static")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)
	end)

	describe("OnDriverRemovedFromProject", function()
		it("says goodbye to the bound bridge with its rid and device id", function()
			local env, c4 = known_scene()
			env.OnDriverRemovedFromProject()
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_GOODBYE", params = { rid = "s1", device_id = "2061" } } },
				c4.sent)
			env.OnDriverDestroyed("DIT_LOADED")
			assert.equal(0, #c4.active_timers())
		end)

		it("sends only the device id when it never had a rid", function()
			local env, c4 = load_scene()
			c4.sent = {}
			env.OnDriverRemovedFromProject()
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_GOODBYE", params = { device_id = "2061" } } }, c4.sent)
		end)

		it("runs through the fake's Composer delete: goodbye, then destroyed with its timer killed", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "ON", {})
			fake.delete_device(SCENE_ID)
			assert.equal(1, #messages(c4, "HUE_SCENE_GOODBYE"))
			assert.equal(0, #c4.active_timers())
			assert.is_nil(fake.project.devices[SCENE_ID])
		end)

		it("stays quiet when no bridge is bound", function()
			local env, c4 = load_scene({ bind = false, rid = "s1" })
			assert.has_no.errors(function() env.OnDriverRemovedFromProject() end)
			assert.equal(0, #c4.sent)
		end)

		it("survives a failing SendToDevice", function()
			local env, c4 = known_scene()
			local original = c4.SendToDevice
			c4.SendToDevice = function(self, id, command, ...)
				if command == "HUE_SCENE_GOODBYE" then error("Director says no") end
				return original(self, id, command, ...)
			end
			assert.has_no.errors(function() env.OnDriverRemovedFromProject() end)
			assert.equal(0, #messages(c4, "HUE_SCENE_GOODBYE"))
		end)
	end)

	describe("actions", function()
		-- The light_v2 proxy the fake's project gave this device: the consumer
		-- of the protocol driver's binding 5001, as on the controller.
		local function proxy_of(id)
			return assert(fake.project.devices[id].proxy_id, "the fake registers a proxy per loaded device")
		end

		it("Adopt Hue Name renames the proxy device, not the protocol driver", function()
			local env, c4 = known_scene()
			local proxy_id = proxy_of(SCENE_ID)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.same({ { proxy_id, "Relax" } }, c4.calls_to("RenameDevice"))
			assert.equal("Relax", fake.project.devices[proxy_id].name)
			assert.equal("Hue Scene", fake.project.devices[SCENE_ID].name, "the protocol driver keeps its name")
			assert.equal(string.format("Renamed device %d to Relax", proxy_id), env.Properties["Last Action"])
		end)

		it("Adopt Hue Name gives a zone scene the zone's name in front, as the bridge does at creation", function()
			local env, c4 = known_scene()
			configure(env, { group_name = "Downstairs", group_type = "zone" })
			c4.calls = {}
			local proxy_id = proxy_of(SCENE_ID)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.same({ { proxy_id, "Downstairs Relax" } }, c4.calls_to("RenameDevice"))
			assert.equal(string.format("Renamed device %d to Downstairs Relax", proxy_id), env.Properties["Last Action"])
		end)

		it("Adopt Hue Name refuses without a Hue name or without a proxy", function()
			local env, c4 = load_scene({ rid = "s1" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.truthy(env.Properties["Last Action"]:find("^Not renamed: no Hue name known yet"))

			env, c4 = known_scene()
			c4.GetBoundConsumerDevices = function() return nil end -- nothing bound, as documented
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.equal("Not renamed: no light_v2 proxy is bound to binding 5001", env.Properties["Last Action"])
		end)

		it("Forget This Scene asks the bridge with HUE_SCENE_FORGET", function()
			local env, c4 = known_scene()
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Scene" })
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_FORGET", params = { rid = "s1", device_id = "2061" } } },
				messages(c4, "HUE_SCENE_FORGET"))
			assert.equal("Asked the bridge to forget this scene; its answer sets Status", env.Properties["Last Action"])
			assert.equal(LINKED_STATUS, env.Properties["Status"], "Status waits for HUE_SCENE_FORGOTTEN")
		end)

		it("Forget This Scene refuses when no bridge is bound", function()
			local env, c4 = load_scene({ bind = false, rid = "s1" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Scene" })
			assert.equal(0, #c4.sent)
			assert.equal("Not sent: not bound to a Hue Bridge", env.Properties["Last Action"])
		end)
	end)

	describe("without a bridge or a scene", function()
		it("drops proxy commands and explains in Status when unbound", function()
			local env, c4 = load_scene({ bind = false, rid = "s1" })
			c4.calls = {}
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "0" })
			assert.equal(0, #c4.sent)
			assert.equal(0, #c4.calls_to("SendToProxy"), "not even CHANGING")
			assert.equal(0, #c4.active_timers())
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
		end)

		it("drops proxy commands while bound but not yet assigned a scene", function()
			local env, c4 = load_scene()
			c4.sent = {}
			c4.calls = {}
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal(0, #c4.sent)
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
		end)

		it("does not error on unknown proxy commands", function()
			local env = known_scene()
			assert.has_no.errors(function()
				env.ReceivedFromProxy(5001, "SOMETHING_NEW", {})
			end)
		end)
	end)

	describe("driver.xml", function()
		local xml

		setup(function()
			local file = assert(io.open("src/hue_scene/driver.xml"))
			xml = file:read("*a")
			file:close()
		end)

		local function capability(name)
			return xml:match("<" .. name .. ">%s*(%w+)%s*</" .. name .. ">")
		end

		it("is a switch on the light_v2 proxy with the brightness-target API", function()
			assert.equal("False", capability("dimmer"))
			assert.equal("True", capability("on_off"))
			assert.equal("False", capability("set_level"))
			assert.equal("False", capability("ramp_level"))
			assert.equal("True", capability("supports_target"))
			assert.equal("True", capability("supports_brightness_stop"))
			assert.equal("False", capability("supports_color"))
			assert.equal("False", capability("supports_color_correlated_temperature"))
			assert.equal("True", capability("reduced_als_support"))
			assert.equal("False", capability("advanced_scene_support"))
			assert.equal("True", capability("buttons_are_virtual"))
			assert.equal("True", capability("hide_proxy_properties"))
			assert.truthy(xml:find('<proxy proxybindingid="5001" name="Hue Scene" image_source="c4z" '
				.. 'small_image="images/devices_sm/hue_scene_16.png" large_image="images/devices_lg/hue_scene_32.png">'
				.. 'light_v2</proxy>', 1, true))
			assert.truthy(xml:find('<documentation file="www/documentation.html"/>', 1, true))
		end)

		it("names the driver and its minimum OS", function()
			assert.truthy(xml:find("<name>Hue Scene</name>", 1, true))
			assert.truthy(xml:find("<model>Hue Scene (CLIP v2)</model>", 1, true))
			assert.truthy(xml:find("<minimum_os_version>3.3.0</minimum_os_version>", 1, true))
		end)

		it("declares the properties and both actions", function()
			local props = fake.declared_properties("hue_scene")
			for _, name in ipairs({ "Driver Version", "Status", "Hue Scene", "Hue Room", "Hue Scene ID", "Online",
				"Last Action" }) do
				assert.equal("", props[name], name)
			end
			assert.equal("Off", props["Debug Mode"])
			assert.equal("As set in Hue", props["Recall As"])
			for _, name in ipairs({ "Adopt Hue Name", "Forget This Scene" }) do
				assert.truthy(xml:find("<action>%s*<name>" .. name .. "</name>%s*<command>" .. name .. "</command>"), name)
			end
		end)

		it("has the light's two connections: the LIGHT_V2 provider and the HUE_BRIDGE consumer", function()
			assert.truthy(xml:find("<id>5001</id>%s*<facing>6</facing>%s*<connectionname>LIGHT</connectionname>"
				.. "%s*<type>2</type>%s*<consumer>False</consumer>"))
			assert.truthy(xml:find("<classname>LIGHT_V2</classname>", 1, true))
			assert.truthy(xml:find("<id>1</id>%s*<facing>6</facing>%s*<connectionname>Hue Bridge</connectionname>"
				.. "%s*<type>1</type>%s*<consumer>True</consumer>"))
			assert.truthy(xml:find("<classname>HUE_BRIDGE</classname>", 1, true))
		end)
	end)

	describe("DEV_RELOAD", function()
		it("hands the bundle to the dev loop when the build has one with apply_forwarded", function()
			local env = known_scene()
			local got
			with_apply_forwarded(function(params) got = params end, function()
				env.ExecuteCommand("DEV_RELOAD", { tree = "scene", version = "7", files = "{}" })
				assert.same({ tree = "scene", version = "7", files = "{}" }, got)
			end)
		end)

		it("ignores another tree's bundle silently", function()
			local env, c4 = known_scene()
			local called = false
			with_apply_forwarded(function() called = true end, function()
				env.ExecuteCommand("DEV_RELOAD", { tree = "light", version = "7", files = "{}" })
			end)
			assert.is_false(called)
			assert.equal(0, #c4.sent, "no HUE_LOG either")
		end)

		it("logs the new version at info after a successful reload, forwarded to the bridge", function()
			local env, c4 = load_scene({ rid = "s1", props = { ["Debug Mode"] = "On" } })
			c4.sent = {}
			with_apply_forwarded(function() return true end, function()
				env.ExecuteCommand("DEV_RELOAD", { version = "7", files = "{}" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_LOG",
					params = { rid = "s1", line = "Hue Scene: scene reloaded to version 7" } } }, c4.sent)
			end)
		end)

		it("warns, forwarded, when the reload fails", function()
			local env, c4 = known_scene()
			with_apply_forwarded(function() return false end, function()
				env.ExecuteCommand("DEV_RELOAD", { tree = "scene", version = "8", files = "{}" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_LOG",
					params = { rid = "s1", line = "[WARN] Hue Scene: scene reload failed; see this scene's Lua output" } } },
					c4.sent)
			end)
		end)
	end)

	-- Dev builds (common/devloop.lua is present here, as in the test tree)
	-- forward the scene's log lines to the bridge as HUE_LOG.
	describe("dev log forwarding", function()
		after_each(function() log.set_debug(false) end)

		it("buffers lines logged before the bridge is known and flushes them after the hello", function()
			local env, c4 = load_scene({ bind = false, rid = "s1", props = { ["Debug Mode"] = "On" } })
			local sends = capture_sends(c4)
			log.info("warming up")
			assert.equal(0, #c4.sent, "nowhere to send yet")

			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			assert.equal(2, #sends)
			assert.equal("HUE_SCENE_HELLO", sends[1].command)
			assert.same({ id = BRIDGE_ID, command = "HUE_LOG",
				params = { rid = "s1", line = "[INFO] Hue Scene: warming up" },
				allow_empty = false, log_command = false }, sends[2], "allowEmptyValues and logCommand off")
		end)

		it("keeps only the newest 30 lines while the bridge is unknown", function()
			local env, c4 = load_scene({ bind = false, rid = "s1", props = { ["Debug Mode"] = "On" } })
			for i = 1, 35 do
				log.info("line %d", i)
			end
			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			local logs = messages(c4, "HUE_LOG")
			assert.equal(30, #logs)
			assert.equal("[INFO] Hue Scene: line 6", logs[1].params.line)
			assert.equal("[INFO] Hue Scene: line 35", logs[30].params.line)
		end)

		it("never forwards debug lines, buffered or bound", function()
			local env, c4 = load_scene({ bind = false, rid = "s1", props = { ["Debug Mode"] = "On" } })
			log.debug("noise before binding")
			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			log.debug("noise after binding")
			state(env, "static") -- dispatch logs it at debug
			assert.equal(0, #messages(c4, "HUE_LOG"))
			assert.equal(1, #c4.sent, "just the hello")
		end)

		it("sends lines straight through once bound, log.always included, and omits a missing rid", function()
			local _, c4 = known_scene()
			log.warn("something odd")
			log.always("diagnostic")
			assert.same({
				{ id = BRIDGE_ID, command = "HUE_LOG", params = { rid = "s1", line = "[WARN] Hue Scene: something odd" } },
				{ id = BRIDGE_ID, command = "HUE_LOG", params = { rid = "s1", line = "Hue Scene: diagnostic" } },
			}, c4.sent)

			_, c4 = load_scene()
			c4.sent = {}
			log.warn("no scene yet")
			assert.same({ { id = BRIDGE_ID, command = "HUE_LOG", params = { line = "[WARN] Hue Scene: no scene yet" } } },
				c4.sent)
		end)

		it("reports a failing HUE_LOG send once, through print, without forwarding the failure", function()
			local printed = {}
			local real_print = print
			_G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
			local ok, err = pcall(function()
				local _, c4 = known_scene()
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
				local env, c4 = load_scene({ rid = "s1" })
				assert.equal(sink, log.sink)
				log.warn("stays local")
				assert.equal(0, #messages(c4, "HUE_LOG"))
				env.ExecuteCommand("DEV_RELOAD", { tree = "scene", version = "7", files = "{}" })
				assert.equal(0, #messages(c4, "HUE_LOG"), "a DEV_RELOAD is only warned about locally")
			end)
			package.preload["common.devloop"] = nil
			assert(ok, err)
		end)
	end)
end)
