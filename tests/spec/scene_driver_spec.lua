-- Hue Scene driver against the fake runtime, with a bridge driver standing
-- behind binding 1 as device 15 (bound with C4:Bind, as Composer or the
-- bridge's Add Scene would), so SendToDevice to it can be asserted on.
-- The contract is docs/scenes-design.md §2 (messages) and §3 (this device),
-- extended by docs/keypad-design.md, docs/scene-dimmer-design.md and
-- docs/smart-scenes-design.md (time-based scenes, at the end).

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BRIDGE_ID = 15
local SCENE_ID = 2061

-- The scene HUE_SCENE_CONFIGURE describes, every value a string as Director hands it over.
local CONFIGURE = { rid = "s1", name = "Relax", group_name = "Kitchen", group_type = "room",
	id_v1 = "/scenes/AbCdEf", auto_dynamic = "false", state = "linked", kind = "scene" }

local LINKED_STATUS = "Hue scene Relax in Kitchen"

-- A time-based scene's configure (over CONFIGURE): "Golden hours 4" in the
-- Downstairs zone, its current slot playing Shine from sunset; no v1 id.
local SMART = { kind = "smart_scene", name = "Golden hours 4", group_name = "Downstairs", group_type = "zone",
	id_v1 = "", slot_name = "Shine", slot_start = "sunset" }

local SMART_STATUS = "Hue time-based scene Golden hours in Downstairs (zone)"

local function quiet()
	log.sink = function() end
end

-- The fake has no C4:SetPropertyAttribs; this one records its calls with the
-- others, so c4.calls_to("SetPropertyAttribs") lists them.
local function stub_attribs(c4)
	c4.SetPropertyAttribs = function(_, name, value)
		table.insert(c4.calls, { name = "SetPropertyAttribs", args = { name, value } })
	end
end

-- opts.bind=false leaves the device unbound; opts.rid persists a rid first,
-- opts.name a name and opts.kind a kind.
local function load_scene(opts)
	opts = opts or {}
	local env, c4 = fake.load_driver("hue_scene", opts.props or {}, { device_id = SCENE_ID })
	stub_attribs(c4)
	if opts.bind ~= false then
		c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
	end
	if opts.rid then
		c4.persist.hue_rid = opts.rid
	end
	if opts.name then
		c4.persist.hue_name = opts.name
	end
	if opts.kind then
		c4.persist.hue_kind = opts.kind
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

-- The same for a time-based scene (SMART): Hue says active or inactive.
local function smart_scene(active)
	local env, c4 = load_scene({ rid = "s1" })
	configure(env, SMART)
	state(env, active or "inactive", { reason = "hello" })
	c4.calls = {}
	c4.sent = {}
	return env, c4
end

-- Fire only the active timers with that delay, as if just that much time had
-- passed for them (c4.fire_timers fires every timer at once). Returns the count.
local function fire(c4, delay)
	local due = {}
	for _, timer in ipairs(c4.active_timers()) do
		if timer.delay == delay then due[#due + 1] = timer end
	end
	for _, timer in ipairs(due) do
		if timer.active then
			timer.active = false
			timer.callback(timer, 0)
		end
	end
	return #due
end

-- The delays of the active timers, smallest first.
local function delays(c4)
	local out = {}
	for _, timer in ipairs(c4.active_timers()) do out[#out + 1] = timer.delay end
	table.sort(out)
	return out
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

			assert.same({ hue_rid = "s1", hue_name = "Relax", hue_kind = "scene", recall_as = "active" }, c4.persist)
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
		it("maps a first inactive to 0, and static and dynamic_palette to on (100 while no level is known)", function()
			local env, c4 = load_scene()
			configure(env)
			c4.calls = {}
			state(env, "inactive")
			state(env, "dynamic_palette")
			state(env, "static")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 }, { LIGHT_BRIGHTNESS_CURRENT = 100 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
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

		it("maps SET_LEVEL and RAMP_TO_LEVEL onto the slider's path: LEVEL is the target, TIME the rate", function()
			local env, c4 = known_scene()
			env.ReceivedFromProxy(5001, "SET_LEVEL", { LEVEL = "50", TIME = "2000" })
			assert.same({ rid = "s1", action = "active", brightness = "50", duration = "2000" }, last_sent(c4).params)
			state(env, "static", { reason = "recall" })
			env.ReceivedFromProxy(5001, "RAMP_TO_LEVEL", { LEVEL = "30", TIME = "4000" })
			assert.same({ id = BRIDGE_ID, command = "HUE_SCENE_LEVEL",
				params = { rid = "s1", device_id = "2061", level = "30", rate = "4000" } }, last_sent(c4))
			env.ReceivedFromProxy(5001, "SET_LEVEL", { LEVEL = "0", TIME = "0" })
			assert.equal("HUE_SCENE_OFF", last_sent(c4).command)
			assert.same({
				{ LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 50, RATE = 2000 },
				{ LIGHT_BRIGHTNESS_CURRENT = 50, LIGHT_BRIGHTNESS_TARGET = 30, RATE = 4000 },
				{ LIGHT_BRIGHTNESS_CURRENT = 50, LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 },
			}, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
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
			assert.equal("Forgotten by the bridge", fake.last_action(env))
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
			assert.same({ hue_rid = "s1", hue_name = "Relax", hue_kind = "scene", recall_as = "active", held_on = true },
				c4.persist, "the identity stays, so binding the device again lets the bridge adopt it")
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
			state(env, "inactive", { reason = "resync" })
			state(env, "static")
			assert.equal(0, #c4.calls_to("UpdateProperty"), "nothing touches Director before late init")
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.equal(0, #c4.calls_to("PersistSetValue"))
			assert.equal(0, #c4.sent)

			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(LINKED_STATUS, env.Properties["Status"])
			assert.equal("s1", c4.persist.hue_rid)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 }, { LIGHT_BRIGHTNESS_CURRENT = 100 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "both states, in arrival order")
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_HELLO",
				params = { rid = "s1", device_id = "2061", name = "Relax", kind = "scene" } } }, c4.sent,
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

		-- docs/review-leftovers-design.md #49: the bridge's Add Scene binds a
		-- device it has just created, so OnBindingChanged can come before late init.
		it("holds a bridge binding that arrives before late init and greets through it once late init has run", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			stub_attribs(c4)
			c4.persist.hue_rid = "s1"
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			assert.equal(0, #c4.calls_to("UpdateProperty"), "nothing touches Director before late init")
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.equal(0, #c4.sent)

			-- Director's lookup does not show the binding yet at late init.
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_HELLO", params = { rid = "s1", device_id = "2061" } } },
				c4.sent)
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
			assert.same({}, delays(c4), "the binding ended the re-checks late init started")
		end)

		it("greets once when late init already sees the binding that arrived before it", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			stub_attribs(c4)
			c4.persist.hue_rid = "s1"
			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(1, #messages(c4, "HUE_SCENE_HELLO"))
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
		end)

		it("applies an unbind that arrived before late init after it", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			stub_attribs(c4)
			c4.persist.hue_rid = "s1"
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

		it("stops the Driver Version looks on destroy", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			stub_attribs(c4)
			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			c4.config_info.version = ""
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ 5000 }, delays(c4), "the second look")
			env.OnDriverDestroyed("DIT_LOADED")
			assert.same({}, delays(c4))
		end)
	end)

	-- docs/review-leftovers-design.md #49: a command that never reaches the
	-- bridge (SendToDevice raising) closes the proxy's CHANGING with the
	-- unchanged state, and the error is logged.
	describe("a command the bridge never gets", function()
		local SCENE_COMMANDS = { HUE_SCENE_RECALL = true, HUE_SCENE_OFF = true, HUE_SCENE_LEVEL = true,
			HUE_SCENE_DIM = true }

		-- From here on SendToDevice raises for the commands in `which` (every
		-- scene command by default); returns the commands it was asked to send.
		local function failing(c4, which)
			local tried = {}
			local original = c4.SendToDevice
			c4.SendToDevice = function(self, id, command, ...)
				if (which or SCENE_COMMANDS)[command] then
					tried[#tried + 1] = command
					error("Director says no")
				end
				return original(self, id, command, ...)
			end
			return tried
		end

		-- LIGHT_BRIGHTNESS_CURRENT of every CHANGED, in order.
		local function changed(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")) do out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT end
			return out
		end

		it("ON closes its CHANGING with the unchanged level, logs, and leaves nothing pending", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local env, c4 = known_scene("inactive")
			local tried = failing(c4)
			env.ReceivedFromProxy(5001, "ON", {})
			assert.same({ "HUE_SCENE_RECALL" }, tried)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 0 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ 0 }, changed(c4))
			assert.same({}, delays(c4), "no fallback")
			local logged = false
			for _, line in ipairs(lines) do
				if line:find("^%[ERROR%] Hue Scene: HUE_SCENE_RECALL to the bridge failed: .*Director says no") then
					logged = true
				end
			end
			assert.is_true(logged)
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.same({ "HUE_SCENE_RECALL", "HUE_SCENE_RECALL" }, tried, "still off, so TOGGLE recalls")
		end)

		it("OFF closes with the level the scene shows and keeps it held on", function()
			local env, c4 = known_scene("static")
			local tried = failing(c4)
			env.ReceivedFromProxy(5001, "OFF", {})
			assert.same({ "HUE_SCENE_OFF" }, tried)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100, LIGHT_BRIGHTNESS_TARGET = 0, RATE = 0 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ 100 }, changed(c4))
			assert.is_true(c4.persist.held_on)
			assert.same({}, delays(c4))
			state(env, "inactive", { reason = "event" })
			assert.same({ 100 }, changed(c4), "still held: an inactive report leaves the tile on")
		end)

		it("a slider move closes with the level the scene shows and leaves nothing pending", function()
			local env, c4 = known_scene("static")
			env.ExecuteCommand("HUE_SCENE_GROUP", { rid = "s1", level = "57" })
			c4.calls = {}
			local tried = failing(c4)
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "500" })
			assert.same({ "HUE_SCENE_LEVEL" }, tried)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 57, LIGHT_BRIGHTNESS_TARGET = 30, RATE = 500 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ 57 }, changed(c4))
			assert.same({ 1000 }, delays(c4), "the level reports' window only, no 1.5 s fallback")
		end)

		it("a hold on a lit scene whose dim fails closes at its level; the release sends no stop", function()
			local env, c4 = known_scene("static")
			local tried = failing(c4)
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time: the dim up fails
			assert.same({ "HUE_SCENE_DIM" }, tried)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ 100 }, changed(c4))
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			assert.same({ "HUE_SCENE_DIM" }, tried, "no stop for a dim that never started")
			assert.same({ 1000 }, delays(c4), "the click guard alone: the hold's CHANGING is closed already")
		end)

		it("a hold from off whose recall fails leaves the scene off and not held, the LEDs off", function()
			local env, c4 = known_scene("inactive")
			local proxy = capture_proxy(c4)
			local tried = failing(c4)
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time: the recall at 1 % fails
			assert.same({ "HUE_SCENE_RECALL" }, tried)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ 0 }, changed(c4))
			assert.same({}, with_command(proxy, "MATCH_LED_STATE"), "the LEDs never went on")
			assert.is_false(c4.persist.held_on)
			assert.same({}, delays(c4), "no dim 600 ms later")
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			assert.same({ "HUE_SCENE_RECALL" }, tried)
		end)

		it("a hold from off whose later dim fails sends no stop; the level reports close the hold", function()
			local env, c4 = known_scene("inactive")
			local tried = failing(c4, { HUE_SCENE_DIM = true })
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time: the recall at 1 % goes out
			assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
			c4.fire_timers() -- 600 ms later: the dim up fails
			assert.same({ "HUE_SCENE_DIM" }, tried)
			env.ExecuteCommand("HUE_SCENE_GROUP", { rid = "s1", on = "true", level = "1" })
			assert.same({ 1 }, changed(c4))
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			assert.same({ "HUE_SCENE_DIM" }, tried, "no stop for a dim that never started")
		end)

		it("a time-based scene whose start fails closes at 0 with nothing to follow", function()
			local env, c4 = smart_scene("inactive")
			local tried = failing(c4)
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "800" })
			assert.same({ "HUE_SCENE_RECALL" }, tried)
			assert.same({ 0 }, changed(c4))
			assert.same({}, delays(c4), "no fallback, nothing to follow")
		end)

		it("a time-based scene's level that cannot follow its start closes with the look the slot has", function()
			local env, c4 = smart_scene("inactive")
			local tried = failing(c4, { HUE_SCENE_LEVEL = true })
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "800" })
			state(env, "active", { reason = "event" })
			assert.same({}, changed(c4), "the move is to close the transaction")
			env.ExecuteCommand("HUE_SCENE_GROUP", { rid = "s1", on = "true", level = "100" })
			assert.same({ "HUE_SCENE_LEVEL" }, tried)
			assert.same({ 100 }, changed(c4))
			assert.same({}, delays(c4))
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
			assert.equal(string.format("Renamed device %d to Relax", proxy_id), fake.last_action(env))
		end)

		it("Adopt Hue Name gives a zone scene the zone's name in front, as the bridge does at creation", function()
			local env, c4 = known_scene()
			configure(env, { group_name = "Downstairs", group_type = "zone" })
			c4.calls = {}
			local proxy_id = proxy_of(SCENE_ID)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.same({ { proxy_id, "Downstairs Relax" } }, c4.calls_to("RenameDevice"))
			assert.equal(string.format("Renamed device %d to Downstairs Relax", proxy_id), fake.last_action(env))
		end)

		it("Adopt Hue Name refuses without a Hue name or without a proxy", function()
			local env, c4 = load_scene({ rid = "s1" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.truthy(fake.last_action(env):find("^Not renamed: no Hue name known yet"))

			env, c4 = known_scene()
			c4.GetBoundConsumerDevices = function() return nil end -- nothing bound, as documented
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.equal("Not renamed: no light_v2 proxy is bound to binding 5001", fake.last_action(env))
		end)

		it("Forget This Scene asks the bridge with HUE_SCENE_FORGET", function()
			local env, c4 = known_scene()
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Scene" })
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_FORGET", params = { rid = "s1", device_id = "2061" } } },
				messages(c4, "HUE_SCENE_FORGET"))
			assert.equal("Asked the bridge to forget this scene; its answer sets Status", fake.last_action(env))
			assert.equal(LINKED_STATUS, env.Properties["Status"], "Status waits for HUE_SCENE_FORGOTTEN")
		end)

		it("Forget This Scene refuses when no bridge is bound", function()
			local env, c4 = load_scene({ bind = false, rid = "s1" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget This Scene" })
			assert.equal(0, #c4.sent)
			assert.equal("Not sent: not bound to a Hue Bridge", fake.last_action(env))
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
			local timers = c4.active_timers()
			assert.equal(1, #timers, "only the binding re-check, no fallback")
			assert.equal(5000, timers[1].delay)
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

		it("is a dimmer on the light_v2 proxy with the brightness-target API", function()
			assert.equal("True", capability("dimmer"))
			assert.equal("True", capability("on_off"))
			assert.equal("True", capability("set_level"))
			assert.equal("True", capability("ramp_level"))
			assert.equal("True", capability("supports_target"))
			assert.equal("True", capability("supports_brightness_stop"))
			assert.equal("False", capability("supports_color"))
			assert.equal("False", capability("supports_color_correlated_temperature"))
			assert.equal("True", capability("reduced_als_support"))
			assert.equal("False", capability("advanced_scene_support"))
			assert.equal("True", capability("buttons_are_virtual"))
			assert.equal("False", capability("hide_proxy_properties"), "the proxy's own settings are shown (#59)")
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

	describe("keypad buttons (BUTTON_ACTION)", function()
		it("top clicks recall, bottom clicks turn off, presses only echo", function()
			local env, c4 = known_scene()
			c4.sent = {}
			c4.calls = {}
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			assert.equal(0, #c4.sent)
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "2" })
			assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "2" })
			assert.equal(1, #messages(c4, "HUE_SCENE_OFF"))
			assert.equal(3, #notifies(c4, "BUTTON_ACTION"))
		end)
	end)

	describe("keypad buttons on the Button Link bindings", function()
		it("clicks on 200 recall, on 201 turn off; a push alone sends nothing", function()
			local env, c4 = known_scene()
			c4.sent = {}
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			assert.equal(0, #c4.sent)
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
			env.ReceivedFromProxy(201, "DO_CLICK", {})
			assert.equal(1, #messages(c4, "HUE_SCENE_OFF"))
			local xml = io.open("src/hue_scene/driver.xml"):read("*a")
			assert.truthy(xml:find("Toggle Button Link", 1, true))
		end)
	end)

	describe("keypad holds (hold to dim)", function()
		local function dims(c4)
			local out = {}
			for _, m in ipairs(messages(c4, "HUE_SCENE_DIM")) do out[#out + 1] = m.params end
			return out
		end

		it("holding top on an active scene dims up over the hold rate; the release stops it", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			assert.equal(0, #c4.sent, "nothing before the hold time")
			assert.same({ 400, false }, c4.calls_to("SetTimer")[1])
			c4.fire_timers()
			assert.same({ { rid = "s1", device_id = "2061", direction = "up", duration = "5000" } }, dims(c4))
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			assert.same({ rid = "s1", device_id = "2061", direction = "stop" }, dims(c4)[2])
			assert.equal(0, #messages(c4, "HUE_SCENE_RECALL"))
			assert.equal(0, #messages(c4, "HUE_SCENE_OFF"))
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "it was on and stays on")
		end)

		it("holding bottom (proxy route) dims down over the hold-down rate set through the proxy, persisted", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "SET_HOLD_RATE_DOWN", { RATE = "3000" })
			assert.equal(3000, c4.persist.hold_rate_down)
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "1" })
			c4.fire_timers()
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "0" })
			assert.same({
				{ rid = "s1", device_id = "2061", direction = "down", duration = "3000" },
				{ rid = "s1", device_id = "2061", direction = "stop" },
			}, dims(c4))
			assert.same({ { BUTTON_ID = 1, ACTION = 1 }, { BUTTON_ID = 1, ACTION = 0 } }, notifies(c4, "BUTTON_ACTION"))
		end)

		it("reads persisted hold rates at late init; toggle held while on dims down, while off up", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			c4.persist.hue_rid = "s1"
			c4.persist.hold_rate_up = 7000
			c4.persist.hold_rate_down = 2000
			env.OnDriverLateInit("DIT_STARTUP")
			configure(env)
			state(env, "static")
			c4.sent = {}
			env.ReceivedFromProxy(202, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(202, "DO_RELEASE", {})
			assert.same({ direction = "down", duration = "2000" },
				{ direction = dims(c4)[1].direction, duration = dims(c4)[1].duration })
			env.ReceivedFromProxy(5001, "SET_HOLD_RATE_UP", { RATE = "8000" })
			assert.equal(8000, c4.persist.hold_rate_up)
		end)

		it("holding top while off recalls at 1 % at once, then dims up 600 ms later", function()
			local env, c4 = known_scene("inactive")
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers() -- the hold time
			assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_RECALL",
				params = { rid = "s1", action = "active", brightness = "1" } } }, c4.sent)
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"), "the level reports settle it")
			local timers = c4.calls_to("SetTimer")
			assert.same({ 600, false }, timers[#timers])
			assert.equal(0, #dims(c4))
			c4.fire_timers() -- 600 ms later
			assert.same({ { rid = "s1", device_id = "2061", direction = "up", duration = "5000" } }, dims(c4))
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			assert.equal("stop", dims(c4)[2].direction)
		end)

		it("a release before the delayed dim cancels it and sends no stop", function()
			local env, c4 = known_scene("inactive")
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			c4.fire_timers()
			assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
			assert.equal(0, #dims(c4))
		end)

		it("holding bottom while off sends nothing, nor does the click after it", function()
			local env, c4 = known_scene("inactive")
			env.ReceivedFromProxy(201, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(201, "DO_RELEASE", {})
			env.ReceivedFromProxy(201, "DO_CLICK", {})
			assert.same({}, c4.sent)
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("a tap is still a tap: push, release and click recall once, with no dim", function()
			local env, c4 = known_scene("inactive")
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
			assert.is_nil(messages(c4, "HUE_SCENE_RECALL")[1].params.brightness)
			assert.equal(0, #dims(c4))
		end)

		it("a release-as-click after a hold (proxy route) stops the dim instead of recalling", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "1" })
			c4.fire_timers()
			env.ReceivedFromProxy(5001, "BUTTON_ACTION", { BUTTON_ID = "0", ACTION = "2" })
			assert.same({ "up", "stop" }, { dims(c4)[1].direction, dims(c4)[2].direction })
			assert.equal(0, #messages(c4, "HUE_SCENE_RECALL"))
		end)

		it("ignores a click on the same button within 1 s after a hold's release, not on another", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			local timers = c4.calls_to("SetTimer")
			assert.same({ 1000, false }, timers[#timers])
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.equal(0, #messages(c4, "HUE_SCENE_RECALL"), "the keypad's click after the hold")
			c4.fire_timers() -- 1 s later
			env.ReceivedFromProxy(200, "DO_CLICK", {})
			assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
		end)

		it("only guards the held button: a bottom tap right after a top hold turns off", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			env.ReceivedFromProxy(201, "DO_CLICK", {})
			assert.equal(1, #messages(c4, "HUE_SCENE_OFF"))
		end)

		it("does nothing to the bridge while unbound", function()
			local env, c4 = load_scene({ bind = false, rid = "s1" })
			c4.sent = {}
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			assert.equal(0, #messages(c4, "HUE_SCENE_DIM"))
			assert.equal(0, #messages(c4, "HUE_SCENE_RECALL"))
		end)

		it("is cancelled on destroy", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			env.OnDriverDestroyed()
			assert.equal(0, #c4.active_timers())
		end)
	end)

	describe("held-on state after a keypad hold-dim", function()
		-- Held up and released on an active scene: dimmed from its own buttons.
		local function dimmed_scene()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers()
			env.ReceivedFromProxy(200, "DO_RELEASE", {})
			c4.fire_timers() -- the click guard runs out
			c4.calls = {}
			c4.sent = {}
			return env, c4
		end

		it("keeps the switch at 100 and the LEDs on when Hue then reports the scene inactive", function()
			local env, c4 = dimmed_scene()
			local proxy = capture_proxy(c4)
			state(env, "inactive")
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.equal(0, #with_command(proxy, "MATCH_LED_STATE"))
			env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 100 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("ends with HUE_SCENE_GROUP on=false: CHANGED 0 and the LEDs off; on=true alone changes nothing", function()
			local env, c4 = dimmed_scene()
			state(env, "inactive")
			local proxy = capture_proxy(c4)
			env.ExecuteCommand("HUE_SCENE_GROUP", { rid = "s1", on = "true" })
			assert.same({}, proxy)
			env.ExecuteCommand("HUE_SCENE_GROUP", { rid = "s1", on = "false" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.same(leds(false), with_command(proxy, "MATCH_LED_STATE"))
		end)

		it("ends when another scene of the group becomes active", function()
			local env, c4 = dimmed_scene()
			state(env, "inactive")
			env.ExecuteCommand("HUE_SCENE_GROUP", { rid = "s1", other_active = "true" })
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("ignores HUE_SCENE_GROUP for another rid", function()
			local env, c4 = dimmed_scene()
			state(env, "inactive")
			env.ExecuteCommand("HUE_SCENE_GROUP", { rid = "other", on = "false" })
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("ends with a bottom tap: OFF to the bridge and CHANGED 0 when it settles", function()
			local env, c4 = dimmed_scene()
			state(env, "inactive")
			env.ReceivedFromProxy(201, "DO_CLICK", {})
			assert.equal(1, #messages(c4, "HUE_SCENE_OFF"))
			state(env, "inactive")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
		end)

		it("makes TOGGLE turn the scene off although Hue reports it inactive", function()
			local env, c4 = dimmed_scene()
			state(env, "inactive")
			env.ReceivedFromProxy(5001, "TOGGLE", {})
			assert.equal(1, #messages(c4, "HUE_SCENE_OFF"))
		end)

		it("survives a recall from here: a later inactive report still leaves the tile on", function()
			local env, c4 = dimmed_scene()
			env.ReceivedFromProxy(5001, "ON", {})
			state(env, "static")
			c4.calls = {}
			state(env, "inactive")
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.is_true(c4.persist.held_on)
		end)

		it("is buffered before late init like the other bridge messages", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			env.ExecuteCommand("HUE_SCENE_GROUP", { rid = "s1", on = "false" })
			assert.equal(0, #c4.calls_to("SendToProxy"))
			env.OnDriverLateInit("DIT_STARTUP")
		end)
	end)

	describe("keypad LEDs", function()
		it("MATCH_LED_STATE follows the scene on 200, 201 and 202, with BUTTON_INFO to the proxy", function()
			local env, c4 = known_scene("inactive")
			local proxy = capture_proxy(c4)
			state(env, "static")
			assert.same(leds(true), with_command(proxy, "MATCH_LED_STATE"))
			assert.same({
				{ 5001, "BUTTON_INFO", { BUTTON_ID = 0, ON_COLOR = "0000ff", OFF_COLOR = "000000",
					CURRENT_COLOR = "0000ff" }, "NOTIFY" },
				{ 5001, "BUTTON_INFO", { BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff",
					CURRENT_COLOR = "000000" }, "NOTIFY" },
				{ 5001, "BUTTON_INFO", { BUTTON_ID = 2, ON_COLOR = "0000ff", OFF_COLOR = "000000",
					CURRENT_COLOR = "0000ff" }, "NOTIFY" },
			}, with_command(proxy, "BUTTON_INFO"))
			state(env, "dynamic_palette")
			assert.equal(3, #with_command(proxy, "MATCH_LED_STATE"), "still on: nothing new")
			state(env, "inactive")
			assert.equal(3, #with_command(proxy, "MATCH_LED_STATE"), "held on: an inactive report alone is no flip")
			env.ExecuteCommand("HUE_SCENE_GROUP", { rid = "s1", on = "false" })
			local all = with_command(proxy, "MATCH_LED_STATE")
			assert.same(leds(false), { all[4], all[5], all[6] })
			assert.equal("0000ff", with_command(proxy, "BUTTON_INFO")[5][3].CURRENT_COLOR, "bottom lit while off")
		end)

		it("sends them with the first known status, not before, and again only on a flip", function()
			local env, c4 = load_scene({ rid = "s1" })
			local proxy = capture_proxy(c4)
			configure(env)
			assert.equal(0, #with_command(proxy, "MATCH_LED_STATE"))
			state(env, "inactive")
			assert.same(leds(false), with_command(proxy, "MATCH_LED_STATE"))
			configure(env) -- re-reports the brightness, but the LEDs have not changed
			assert.equal(3, #with_command(proxy, "MATCH_LED_STATE"))
		end)

		it("turns on with a hold from off, before Hue reports anything", function()
			local env, c4 = known_scene("inactive")
			local proxy = capture_proxy(c4)
			env.ReceivedFromProxy(200, "DO_PUSH", {})
			c4.fire_timers()
			assert.same(leds(true), with_command(proxy, "MATCH_LED_STATE"))
		end)

		it("resends the state when a keypad is bound to a Button Link", function()
			local env, c4 = known_scene("static")
			local proxy = capture_proxy(c4)
			env.OnBindingChanged(201, "BUTTON_LINK", true, 77, 1)
			assert.same(leds(true), with_command(proxy, "MATCH_LED_STATE"))
			env.OnBindingChanged(201, "BUTTON_LINK", false, 77, 1)
			assert.equal(3, #with_command(proxy, "MATCH_LED_STATE"))
			assert.equal(0, #c4.sent, "a link binding is not the bridge's")
		end)

		it("REQUEST_BUTTON_COLORS on 201 answers the default bottom colours there, then the LED state", function()
			local env, c4 = known_scene("static")
			local proxy = capture_proxy(c4)
			env.ReceivedFromProxy(201, "REQUEST_BUTTON_COLORS", {})
			assert.same({
				{ 201, "BUTTON_COLORS", { BUTTON_ID = 1, ON_COLOR = "000000", OFF_COLOR = "0000ff",
					CURRENT_COLOR = "000000" }, "NOTIFY" },
				{ 201, "MATCH_LED_STATE", { STATE = true }, "COMMAND" },
			}, proxy)
		end)

		it("SET_BUTTON_COLOR persists the colour and echoes it on the link and to the proxy", function()
			local env, c4 = known_scene("static")
			local proxy = capture_proxy(c4)
			env.ReceivedFromProxy(5001, "SET_BUTTON_COLOR", { BUTTON_ID = "1", ON_COLOR = "FF8000" })
			assert.equal("ff8000", c4.persist.button_1_on_color)
			assert.same({
				{ 201, "BUTTON_COLORS", { BUTTON_ID = 1, ON_COLOR = "ff8000", OFF_COLOR = "0000ff",
					CURRENT_COLOR = "ff8000" }, "NOTIFY" },
				{ 5001, "BUTTON_INFO", { BUTTON_ID = 1, ON_COLOR = "ff8000", OFF_COLOR = "0000ff",
					CURRENT_COLOR = "ff8000" }, "NOTIFY" },
			}, proxy)
		end)

		it("accepts the documented spelling with spaces and ignores a colour that is not 6-digit hex", function()
			local env, c4 = known_scene("static")
			env.ReceivedFromProxy(5001, "SET_BUTTON_COLOR", { BUTTON_ID = "2", ["OFF COLOR"] = "00ff00",
				ON_COLOR = "blue" })
			assert.equal("00ff00", c4.persist.button_2_off_color)
			assert.is_nil(c4.persist.button_2_on_color)
		end)

		it("uses persisted colours after a restart", function()
			local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
			c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
			c4.persist.hue_rid = "s1"
			c4.persist.button_0_on_color = "ff0000"
			env.OnDriverLateInit("DIT_STARTUP")
			local proxy = capture_proxy(c4)
			env.ReceivedFromProxy(200, "REQUEST_BUTTON_COLORS", {})
			assert.same({ BUTTON_ID = 0, ON_COLOR = "ff0000", OFF_COLOR = "000000", CURRENT_COLOR = "000000" },
				proxy[1][3])
			assert.same({ STATE = false }, proxy[2][3], "nothing known yet reads as off")
		end)
	end)

	describe("dimmer (docs/scene-dimmer-design.md)", function()
		-- An active scene whose group the bridge reported at `level`, with the
		-- recording cleared and that report's throttle window run out.
		local function lit_scene(level)
			local env, c4 = known_scene("static")
			env.ExecuteCommand("HUE_SCENE_GROUP", { rid = "s1", on = "true", level = tostring(level or 80) })
			c4.fire_timers()
			c4.calls = {}
			c4.sent = {}
			return env, c4
		end

		local function group(env, params)
			params.rid = params.rid or "s1"
			env.ExecuteCommand("HUE_SCENE_GROUP", params)
		end

		local function changed(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")) do out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT end
			return out
		end

		describe("the slider (SET_BRIGHTNESS_TARGET)", function()
			it("while on sends HUE_SCENE_LEVEL and CHANGING at once; the bridge's level report settles it", function()
				local env, c4 = lit_scene(80)
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "500" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_LEVEL",
					params = { rid = "s1", device_id = "2061", level = "40", rate = "500" } } }, c4.sent)
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 80, LIGHT_BRIGHTNESS_TARGET = 40, RATE = 500 } },
					notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
				assert.same({}, changed(c4))
				local timers = c4.active_timers()
				assert.equal(1, #timers)
				assert.equal(1500, timers[1].delay, "the ramp plus 1 s")

				group(env, { level = "40.39" })
				assert.same({ 40 }, changed(c4), "a whole percent")
				c4.fire_timers()
				assert.same({ 40 }, changed(c4), "settled: no fallback CHANGED follows")
				assert.equal(0, #c4.active_timers())
			end)

			it("while on reports the target when no level report comes within the ramp plus 1 s", function()
				local env, c4 = lit_scene(80)
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "25", RATE = "0" })
				assert.equal(1000, c4.active_timers()[1].delay)
				c4.fire_timers()
				assert.same({ 25 }, changed(c4))
				env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
				assert.same({ 25, 25 }, changed(c4), "the assumed level is cached")
			end)

			it("counts a held scene (Hue calls it inactive) as on: it moves the level, it does not recall", function()
				local env, c4 = lit_scene(80)
				state(env, "inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "0" })
				assert.equal(1, #messages(c4, "HUE_SCENE_LEVEL"))
				assert.equal(0, #messages(c4, "HUE_SCENE_RECALL"))
			end)

			it("sends a whole percent from 1 to 100", function()
				local env, c4 = lit_scene(80)
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0.3", RATE = "0" })
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "62.5", RATE = "0" })
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "150", RATE = "0" })
				local levels = {}
				for _, m in ipairs(messages(c4, "HUE_SCENE_LEVEL")) do levels[#levels + 1] = m.params.level end
				assert.same({ "1", "63", "100" }, levels)
			end)

			it("from off recalls at the target over the rate, and the recall's STATE reports that level", function()
				local env, c4 = known_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "1200" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_RECALL",
					params = { rid = "s1", action = "active", brightness = "35", duration = "1200" } } }, c4.sent)
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 0, LIGHT_BRIGHTNESS_TARGET = 35, RATE = 1200 } },
					notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
				state(env, "static", { reason = "recall" })
				assert.same({ 35 }, changed(c4))
				assert.equal(0, #c4.active_timers())
				assert.is_true(c4.persist.held_on)
			end)

			it("from off takes a level the bridge reported since the recall over the target", function()
				local env, c4 = known_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				group(env, { on = "true" })
				group(env, { level = "33.2" })
				assert.same({}, changed(c4), "not on yet: only cached")
				state(env, "static", { reason = "recall" })
				assert.same({ 33 }, changed(c4))
			end)

			it("from off assumes the target with the recall when the bridge never answers", function()
				local env, c4 = known_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				assert.equal(2000, c4.active_timers()[1].delay)
				c4.fire_timers()
				assert.same({ 35 }, changed(c4))
			end)

			it("recalls at the target while a recall or off is still on its way (the level is in flux)", function()
				local env, c4 = lit_scene(80)
				env.ReceivedFromProxy(5001, "OFF", {})
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" })
				assert.equal(0, #messages(c4, "HUE_SCENE_LEVEL"))
				assert.same({ rid = "s1", action = "active", brightness = "50" }, last_sent(c4).params)
				assert.equal(1, #c4.active_timers(), "the recall replaced the off's fallback")
			end)

			it("to 0 turns the scene off over the rate and ends the held state", function()
				local env, c4 = lit_scene(80)
				state(env, "inactive")
				assert.is_true(c4.persist.held_on)
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "800" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_OFF", params = { rid = "s1" } } }, c4.sent)
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 80, LIGHT_BRIGHTNESS_TARGET = 0, RATE = 800 } },
					notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
				assert.is_false(c4.persist.held_on)
				state(env, "inactive", { reason = "recall" })
				assert.same({ 0 }, changed(c4))
			end)

			it("SET_BRIGHTNESS_STOP during a level move reports the cached level and cancels the fallback", function()
				local env, c4 = lit_scene(80)
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "3000" })
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
				assert.same({ 80 }, changed(c4))
				assert.equal(0, #c4.active_timers())
			end)
		end)

		describe("level reports (HUE_SCENE_GROUP level)", function()
			it("update the tile while on, at most once a second, the latest when the second ends", function()
				local env, c4 = known_scene("static")
				group(env, { level = "50" })
				assert.same({ 50 }, changed(c4), "the first goes at once")
				local timers = c4.active_timers()
				assert.equal(1, #timers)
				assert.equal(1000, timers[1].delay)
				for _, level in ipairs({ "55.4", "61", "70.2" }) do
					group(env, { level = level })
				end
				assert.same({ 50 }, changed(c4), "within the second: held back")
				c4.fire_timers()
				assert.same({ 50, 70 }, changed(c4), "the latest, when the second ends")
				c4.fire_timers() -- a quiet second: nothing more, and the throttle rests
				assert.same({ 50, 70 }, changed(c4))
				assert.equal(0, #c4.active_timers())
				group(env, { level = "20" })
				assert.same({ 50, 70, 20 }, changed(c4), "at once again after a quiet second")
			end)

			it("are only cached while the scene is off, and shown once it is on", function()
				local env, c4 = known_scene("inactive")
				group(env, { level = "30" })
				assert.same({}, changed(c4))
				state(env, "static", { reason = "event" }) -- recalled in the Hue app
				assert.same({ 30 }, changed(c4))
				group(env, { level = "30.3" })
				assert.same({ 30 }, changed(c4), "the same whole percent is not sent again")
			end)

			it("ignore a level of 0 (none of the group's lights lit): the last lit level stays", function()
				local env, c4 = lit_scene(80)
				group(env, { level = "0" })
				assert.same({}, changed(c4))
				env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
				assert.same({ 80 }, changed(c4))
			end)

			it("for another rid are ignored", function()
				local env, c4 = lit_scene(80)
				group(env, { rid = "other", level = "20" })
				env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
				assert.same({ 80 }, changed(c4))
			end)

			it("stop being throttled on destroy (the timer is cancelled)", function()
				local env, c4 = known_scene("static")
				group(env, { level = "50" })
				assert.equal(1, #c4.active_timers())
				env.OnDriverDestroyed()
				assert.equal(0, #c4.active_timers())
			end)
		end)

		describe("the on rule (held_on)", function()
			it("keeps the tile on at the new level when Hue reports the scene inactive after a Hue-app dim", function()
				local env, c4 = lit_scene(80)
				local proxy = capture_proxy(c4)
				group(env, { level = "35" })
				state(env, "inactive", { reason = "event" })
				assert.same({ 35 }, changed(c4))
				assert.equal(0, #with_command(proxy, "MATCH_LED_STATE"), "the LEDs stay on")
				env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
				assert.same({ 35, 35 }, changed(c4))
			end)

			it("holds a scene recalled in the Hue app (a static report) and persists that", function()
				local env, c4 = known_scene("inactive")
				assert.is_nil(c4.persist.held_on)
				state(env, "static", { reason = "event" })
				assert.is_true(c4.persist.held_on)
				state(env, "inactive", { reason = "event" })
				assert.same({ 100 }, changed(c4))
			end)

			it("ends when the group goes off: CHANGED 0, the LEDs off, the persisted flag cleared", function()
				local env, c4 = lit_scene(80)
				state(env, "inactive")
				local proxy = capture_proxy(c4)
				group(env, { on = "false", level = "0" })
				assert.same({ 0 }, changed(c4), "no stray level on the way")
				assert.same(leds(false), with_command(proxy, "MATCH_LED_STATE"))
				assert.is_false(c4.persist.held_on)
			end)

			it("ends when another scene of the group becomes active", function()
				local env, c4 = lit_scene(80)
				state(env, "inactive")
				group(env, { other_active = "true" })
				assert.same({ 0 }, changed(c4))
				assert.is_false(c4.persist.held_on)
			end)

			it("closes a pending level move when the group goes off", function()
				local env, c4 = lit_scene(80)
				state(env, "inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "0" })
				group(env, { on = "false" })
				assert.same({ 0 }, changed(c4))
				assert.equal(0, #c4.active_timers(), "no fallback left to fire")
			end)

			it("survives a restart (persisted) and is dropped by the first group off", function()
				local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
				c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
				c4.persist.hue_rid = "s1"
				c4.persist.held_on = true
				local proxy = capture_proxy(c4)
				env.OnDriverLateInit("DIT_STARTUP")
				assert.same(leds(true), with_command(proxy, "MATCH_LED_STATE"),
					"on from the persisted flag, before the bridge says anything")
				configure(env)
				state(env, "inactive", { reason = "hello" })
				group(env, { on = "true", level = "45" })
				assert.same({ 100, 45 }, changed(c4), "on while no level is known, then the group's level")
				group(env, { on = "false" })
				assert.same({ 100, 45, 0 }, changed(c4))
				assert.is_false(c4.persist.held_on)
				local all = with_command(proxy, "MATCH_LED_STATE")
				assert.same(leds(false), { all[4], all[5], all[6] })
			end)

			it("is not set by a fallback's assumption: a later inactive report still turns the tile off", function()
				local env, c4 = known_scene("inactive")
				env.ReceivedFromProxy(5001, "ON", {})
				c4.fire_timers()
				assert.is_nil(c4.persist.held_on)
				state(env, "inactive", { reason = "resync" })
				assert.same({ 100, 0 }, changed(c4))
			end)
		end)

		describe("keypad holds", function()
			it("report CHANGING toward 100 (top) or 1 (bottom) over the hold rate; level reports settle it", function()
				local env, c4 = lit_scene(60)
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				c4.fire_timers()
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 60, LIGHT_BRIGHTNESS_TARGET = 100, RATE = 5000 } },
					notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
				group(env, { level = "72" })
				assert.same({ 72 }, changed(c4), "during the ramp")
				env.ReceivedFromProxy(200, "DO_RELEASE", {})
				group(env, { level = "78.6" })
				assert.same({ 72, 79 }, changed(c4), "the report after the release settles it at once")

				c4.fire_timers() -- the click guard and the throttle window run out
				c4.calls = {}
				env.ReceivedFromProxy(5001, "SET_HOLD_RATE_DOWN", { RATE = "3000" })
				env.ReceivedFromProxy(201, "DO_PUSH", {})
				c4.fire_timers()
				assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 79, LIGHT_BRIGHTNESS_TARGET = 1, RATE = 3000 } },
					notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			end)

			it("close the CHANGING with the cached level 1 s after the release when no level report comes", function()
				local env, c4 = lit_scene(60)
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				c4.fire_timers()
				env.ReceivedFromProxy(200, "DO_RELEASE", {})
				assert.same({}, changed(c4))
				c4.fire_timers()
				assert.same({ 60 }, changed(c4))
			end)

			it("from off hold the scene on: an inactive report after the 1 % recall keeps the tile on", function()
				local env, c4 = known_scene("inactive")
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				c4.fire_timers()
				assert.is_true(c4.persist.held_on)
				state(env, "inactive", { reason = "event" })
				env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})
				assert.same({ 100 }, changed(c4), "on, no level reported yet")
			end)
		end)
	end)

	describe("binding re-check after start (Director restart)", function()
		it("greets the bridge once a binding that was invisible at late init shows up, with no binding event", function()
			local env, c4 = load_scene({ bind = false, rid = "x1" })
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			c4.fire_timers() -- 5 s: still nothing bound
			assert.equal(0, #messages(c4, "HUE_SCENE_HELLO"))
			c4.bindings[#c4.bindings + 1] = { provider = BRIDGE_ID, provider_binding = 1, consumer = SCENE_ID,
				consumer_binding = 1, class = "HUE_BRIDGE" }
			c4.fire_timers() -- 15 s: the binding is visible now
			assert.equal(1, #messages(c4, "HUE_SCENE_HELLO"))
			assert.equal(BRIDGE_ID, messages(c4, "HUE_SCENE_HELLO")[1].id)
			assert.equal(0, #c4.active_timers(), "no further re-checks")
		end)

		it("stops after the check at 60 s", function()
			local _, c4 = load_scene({ bind = false, rid = "x1" })
			for _ = 1, 4 do c4.fire_timers() end
			assert.equal(0, #c4.active_timers())
		end)

		it("ends the re-checks on a binding event and on destroy, and never starts them when bound", function()
			local env, c4 = load_scene({ bind = false, rid = "x1" })
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.equal(0, #c4.active_timers())
			env, c4 = load_scene({ bind = false, rid = "x1" })
			env.OnDriverDestroyed()
			assert.equal(0, #c4.active_timers())
			local _, bound_c4 = load_scene({ rid = "x1" })
			assert.equal(0, #bound_c4.active_timers())
		end)
	end)

	describe("slider to 100 from off", function()
		it("plays the scene as designed, without a brightness override", function()
			local env, c4 = known_scene("inactive")
			c4.sent = {}
			env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "0" })
			local recalls = messages(c4, "HUE_SCENE_RECALL")
			assert.equal(1, #recalls)
			assert.is_nil(recalls[1].params.brightness)
		end)
	end)

	describe("time-based scenes (docs/smart-scenes-design.md)", function()
		-- What a time-based device sends to start: the bridge activates a smart
		-- entry whatever the action, so the device sends Hue's own choice.
		local START = { rid = "s1", action = "active" }

		local function changed(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")) do out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT end
			return out
		end

		-- { current, target, rate } of every CHANGING, in order.
		local function changing(c4)
			local out = {}
			for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")) do
				out[#out + 1] = { p.LIGHT_BRIGHTNESS_CURRENT, p.LIGHT_BRIGHTNESS_TARGET, p.RATE }
			end
			return out
		end

		local function group(env, params)
			params.rid = params.rid or "s1"
			env.ExecuteCommand("HUE_SCENE_GROUP", params)
		end

		local function params_of(c4, command)
			local out = {}
			for _, m in ipairs(messages(c4, command)) do out[#out + 1] = m.params end
			return out
		end

		-- SMART with some fields replaced ("" drops one, as Director would).
		local function smart_with(extra)
			local params = {}
			for k, v in pairs(SMART) do params[k] = v end
			for k, v in pairs(extra or {}) do params[k] = v end
			return params
		end

		describe("the kind (Decision 1)", function()
			it("is persisted from HUE_SCENE_CONFIGURE and named in the hello after a restart", function()
				local env, c4 = load_scene({ rid = "s1" })
				configure(env, SMART)
				assert.equal("smart_scene", c4.persist.hue_kind)

				local _, again = load_scene({ rid = "s1", name = "Golden hours 4", kind = "smart_scene" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_HELLO",
					params = { rid = "s1", device_id = "2061", name = "Golden hours 4", kind = "smart_scene" } } },
					again.sent)
			end)

			it("is an ordinary scene when a configure names none (a bridge from before time-based scenes)", function()
				local env, c4 = load_scene({ rid = "s1", kind = "smart_scene" })
				local params = {}
				for k, v in pairs(CONFIGURE) do params[k] = v end
				params.kind = nil
				env.ExecuteCommand("HUE_SCENE_CONFIGURE", params)
				assert.equal("scene", c4.persist.hue_kind)
				assert.equal(LINKED_STATUS, env.Properties["Status"])
			end)

			it("takes a kind it does not know as an ordinary scene, with a warning", function()
				local lines = {}
				log.sink = function(line) lines[#lines + 1] = line end
				local env, c4 = load_scene({ rid = "s1" })
				configure(env, { kind = "entertainment" })
				assert.equal("scene", c4.persist.hue_kind)
				local warned = false
				for _, line in ipairs(lines) do
					if line:find("^%[WARN%] Hue Scene: HUE_SCENE_CONFIGURE with unknown kind entertainment") then
						warned = true
					end
				end
				assert.is_true(warned)
			end)

			it("ignores a persisted kind it does not know: the hello names none", function()
				local _, c4 = load_scene({ rid = "s1", kind = "sparkly" })
				assert.same({ rid = "s1", device_id = "2061" }, messages(c4, "HUE_SCENE_HELLO")[1].params)
			end)
		end)

		describe("on state (Decision 2)", function()
			it("follows Hue's active and inactive, without the on rule's held_on", function()
				local env, c4 = smart_scene("inactive")
				local proxy = capture_proxy(c4)
				state(env, "active", { reason = "event" })
				assert.same({ 100 }, changed(c4))
				assert.same(leds(true), with_command(proxy, "MATCH_LED_STATE"))
				assert.is_nil(c4.persist.held_on, "never held on")
				state(env, "inactive", { reason = "event" })
				assert.same({ 100, 0 }, changed(c4))
				local all = with_command(proxy, "MATCH_LED_STATE")
				assert.same(leds(false), { all[4], all[5], all[6] })
			end)

			it("turns off with Hue's inactive even after a dim from its own keypad", function()
				local env, c4 = smart_scene("active")
				group(env, { on = "true", level = "60" })
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				fire(c4, 400)
				env.ReceivedFromProxy(200, "DO_RELEASE", {})
				group(env, { level = "75" })
				assert.equal(2, #messages(c4, "HUE_SCENE_DIM"), "up, then stop")
				assert.is_nil(c4.persist.held_on, "a hold does not hold it on")
				state(env, "inactive", { reason = "event" })
				assert.same({ 60, 75, 0 }, changed(c4))
			end)

			it("is not turned off by its group going off or another scene alone: its STATE does that", function()
				local env, c4 = smart_scene("active")
				group(env, { on = "false" })
				group(env, { other_active = "true" })
				assert.same({}, changed(c4))
				state(env, "inactive", { reason = "event" })
				assert.same({ 0 }, changed(c4))
			end)

			it("leaves the on rule to ordinary scenes: one stays on when Hue calls it inactive", function()
				local env, c4 = known_scene("static")
				state(env, "inactive", { reason = "event" })
				assert.same({}, changed(c4))
				assert.is_true(c4.persist.held_on)
			end)

			it("drops a held-on state when Re-link makes an ordinary scene's device time-based", function()
				local env, c4 = known_scene("static")
				assert.is_true(c4.persist.held_on)
				configure(env, SMART)
				assert.is_false(c4.persist.held_on)
				state(env, "inactive", { reason = "hello" })
				assert.same({ 100, 0 }, changed(c4), "the configure re-reports, then Hue's inactive turns it off")
			end)
		end)

		describe("ON, OFF, TOGGLE and taps (Decisions 3 and 5)", function()
			it("ON from off starts the scene without a ramp or a level; the fallback assumes it runs", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "400" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_RECALL", params = START } }, c4.sent,
					"no duration, no brightness")
				assert.same({ { 0, 100, 400 } }, changing(c4))
				assert.same({ 2000 }, delays(c4), "the 2 s fallback, and nothing to follow")
				fire(c4, 2000)
				assert.same({ 100 }, changed(c4))
				assert.equal(SMART_STATUS .. "; now Shine (from sunset)", env.Properties["Status"])
				state(env, "inactive", { reason = "resync" })
				assert.same({ 100, 0 }, changed(c4), "an assumption, not a report: a later inactive corrects it")
			end)

			it("ON settles with the bridge's STATE active", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "ON", {})
				state(env, "active", { reason = "event" })
				assert.same({ 100 }, changed(c4))
				assert.same({}, delays(c4))
				state(env, "active", { reason = "recall" })
				assert.same({ 100 }, changed(c4), "the recall's own STATE changes nothing more")
			end)

			it("OFF asks the bridge to stop it and turn the group off; the inactive STATE settles it", function()
				local env, c4 = smart_scene("active")
				env.ReceivedFromProxy(5001, "OFF", {})
				assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_OFF", params = { rid = "s1" } } }, c4.sent)
				assert.same({ { 100, 0, 0 } }, changing(c4))
				state(env, "inactive", { reason = "recall" })
				assert.same({ 0 }, changed(c4))
				assert.equal(SMART_STATUS .. "; not running", env.Properties["Status"])
				assert.same({}, delays(c4))
			end)

			it("OFF (the slider to 0) assumes the scene stopped when the bridge never answers", function()
				local env, c4 = smart_scene("active")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "0", RATE = "0" })
				assert.equal("HUE_SCENE_OFF", last_sent(c4).command)
				fire(c4, 2000)
				assert.same({ 0 }, changed(c4))
				assert.equal(SMART_STATUS .. "; not running", env.Properties["Status"])
			end)

			it("TOGGLE and keypad taps go by Hue's status", function()
				local env, c4 = smart_scene("active")
				env.ReceivedFromProxy(5001, "TOGGLE", {})
				assert.equal("HUE_SCENE_OFF", last_sent(c4).command)
				state(env, "inactive", { reason = "recall" })
				env.ReceivedFromProxy(5001, "TOGGLE", {})
				assert.same({ id = BRIDGE_ID, command = "HUE_SCENE_RECALL", params = START }, last_sent(c4))
				state(env, "active", { reason = "recall" })
				env.ReceivedFromProxy(201, "DO_CLICK", {})
				assert.equal("HUE_SCENE_OFF", last_sent(c4).command)
				state(env, "inactive", { reason = "recall" })
				env.ReceivedFromProxy(200, "DO_CLICK", {})
				assert.same({ id = BRIDGE_ID, command = "HUE_SCENE_RECALL", params = START }, last_sent(c4))
			end)
		end)

		describe("the slider from off below 100 (Decision 4)", function()
			it("starts the scene, then moves the room once the bridge reports the group on with a level", function()
				local env, c4 = smart_scene("inactive")
				local proxy = capture_proxy(c4)
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "40", RATE = "800" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_RECALL", params = START } }, c4.sent)
				assert.same({ { 0, 40, 800 } }, changing(c4))
				assert.same({ 1500, 2000 }, delays(c4), "what follows, and the start's fallback")

				state(env, "active", { reason = "event" })
				state(env, "active", { reason = "recall" })
				assert.same({}, changed(c4), "the move closes the proxy's transaction, not the start")
				assert.same(leds(true), with_command(proxy, "MATCH_LED_STATE"), "the LEDs follow the start")
				assert.same({}, params_of(c4, "HUE_SCENE_LEVEL"), "not before the slot's look is on")

				group(env, { on = "true", level = "100" })
				assert.same({ { rid = "s1", device_id = "2061", level = "40", rate = "800" } },
					params_of(c4, "HUE_SCENE_LEVEL"))
				assert.same({}, changed(c4), "the slot's level is not shown on the way to 40")
				assert.equal(1, #changing(c4), "no second CHANGING")
				assert.same({ 1800 }, delays(c4), "the move's fallback: the ramp plus 1 s")

				group(env, { level = "40.2" })
				assert.same({ 40 }, changed(c4))
				assert.is_nil(c4.persist.held_on)
			end)

			it("moves the room 1.5 s after the start when no group report comes; the move's fallback reports it", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				state(env, "active", { reason = "event" })
				assert.same({ 1500 }, delays(c4))
				fire(c4, 1500)
				assert.same({ { rid = "s1", device_id = "2061", level = "35", rate = "0" } },
					params_of(c4, "HUE_SCENE_LEVEL"))
				assert.same({ 1000 }, delays(c4))
				fire(c4, 1000)
				assert.same({ 35 }, changed(c4))
			end)

			it("follows a report of the group on alone when its level is known (unchanged, so not sent again)", function()
				local env, c4 = smart_scene("inactive")
				group(env, { level = "60" })
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "0" })
				state(env, "active", { reason = "event" })
				group(env, { on = "true" })
				assert.equal(1, #messages(c4, "HUE_SCENE_LEVEL"))
			end)

			it("moves the room before any STATE confirmed the start, and that move's fallback assumes the start", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				fire(c4, 1500)
				assert.equal(1, #messages(c4, "HUE_SCENE_LEVEL"))
				assert.same({ 1000 }, delays(c4), "the move replaced the start's fallback")
				fire(c4, 1000)
				assert.same({ 35 }, changed(c4))
				assert.equal(SMART_STATUS .. "; now Shine (from sunset)", env.Properties["Status"])
			end)

			it("lets a late STATE active only confirm the start; the move's own report closes the transaction", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				fire(c4, 1500)
				state(env, "active", { reason = "recall" })
				assert.same({}, changed(c4))
				group(env, { level = "35.4" })
				assert.same({ 35 }, changed(c4))
				assert.same({ 1000 }, delays(c4), "only the throttle window is left")
			end)

			it("drops what follows when the start fails (STATE inactive) and closes at 0", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				state(env, "inactive", { reason = "recall" })
				assert.same({ 0 }, changed(c4))
				assert.same({}, delays(c4))
				c4.fire_timers()
				assert.same({}, params_of(c4, "HUE_SCENE_LEVEL"))

				env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				fire(c4, 1500) -- the move went out before any STATE
				state(env, "inactive", { reason = "recall" })
				assert.same({ 0 }, changed(c4))
				assert.same({}, delays(c4), "the move's fallback cannot assume the start any more")
			end)

			it("drops what follows when the group goes off first, and closes with what is known", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				state(env, "active", { reason = "event" })
				group(env, { on = "false" })
				assert.same({ 100 }, changed(c4), "running as far as Hue has said")
				assert.same({}, delays(c4))
				state(env, "inactive", { reason = "event" })
				assert.same({ 100, 0 }, changed(c4))
				assert.same({}, params_of(c4, "HUE_SCENE_LEVEL"))
			end)

			it("takes a second target before the slot's look is on as the level that follows, with no second start", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "60", RATE = "500" })
				assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
				assert.same({ { 0, 35, 0 }, { 0, 60, 500 } }, changing(c4))
				state(env, "active", { reason = "event" })
				group(env, { on = "true", level = "90" })
				assert.same({ { rid = "s1", device_id = "2061", level = "60", rate = "500" } },
					params_of(c4, "HUE_SCENE_LEVEL"))
			end)

			it("takes a target that arrives while a plain start is on its way as a level to follow", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "ON", {})
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "0" })
				assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
				assert.same({ 1500, 2000 }, delays(c4))
				state(env, "active", { reason = "event" })
				assert.same({}, changed(c4), "the move closes the transaction")
				fire(c4, 1500)
				assert.same({ { rid = "s1", device_id = "2061", level = "30", rate = "0" } },
					params_of(c4, "HUE_SCENE_LEVEL"))
			end)

			it("plays the scene as its slot has it at 100: nothing follows the start", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "100", RATE = "0" })
				assert.same({ 2000 }, delays(c4))
				state(env, "active", { reason = "event" })
				group(env, { on = "true", level = "85" })
				assert.same({}, params_of(c4, "HUE_SCENE_LEVEL"))
				assert.same({ 100, 85 }, changed(c4))
			end)

			it("SET_BRIGHTNESS_STOP before the level follows drops it and reports what is known", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				state(env, "active", { reason = "event" })
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_STOP", {})
				assert.same({ 100 }, changed(c4))
				assert.same({}, delays(c4))
				group(env, { on = "true", level = "90" })
				assert.same({}, params_of(c4, "HUE_SCENE_LEVEL"))
			end)

			it("drops what follows when the bridge is unbound", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "35", RATE = "0" })
				c4.bindings = {}
				env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
				assert.same({}, delays(c4))
			end)
		end)

		describe("holds (Decisions 4 and 6)", function()
			local function dims(c4)
				return params_of(c4, "HUE_SCENE_DIM")
			end

			it("holding top while off starts the scene, then dims up while held once the group report comes", function()
				local env, c4 = smart_scene("inactive")
				local proxy = capture_proxy(c4)
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				fire(c4, 400)
				assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_RECALL", params = START } }, c4.sent,
					"no 1 % start: an activate has no brightness")
				assert.same({ { 0, 100, 5000 } }, changing(c4))
				assert.equal(0, #with_command(proxy, "MATCH_LED_STATE"), "the LEDs wait for Hue's status")
				state(env, "active", { reason = "event" })
				assert.same(leds(true), with_command(proxy, "MATCH_LED_STATE"))
				assert.same({}, changed(c4))
				assert.same({}, dims(c4))

				group(env, { on = "true", level = "70" })
				assert.same({ { rid = "s1", device_id = "2061", direction = "up", duration = "5000" } }, dims(c4))
				assert.same({ 70 }, changed(c4), "the tile starts from the slot's level")
				env.ReceivedFromProxy(200, "DO_RELEASE", {})
				assert.same({ rid = "s1", device_id = "2061", direction = "stop" }, dims(c4)[2])
				assert.is_nil(c4.persist.held_on)
			end)

			it("holding top while off dims up 1.5 s after the start when no group report comes", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				fire(c4, 400)
				state(env, "active", { reason = "event" })
				assert.same({ 1500 }, delays(c4))
				fire(c4, 1500)
				assert.same({ { rid = "s1", device_id = "2061", direction = "up", duration = "5000" } }, dims(c4))
				env.ReceivedFromProxy(200, "DO_RELEASE", {})
				assert.equal("stop", dims(c4)[2].direction)
			end)

			it("a release before the dim follows leaves the scene started, with no dim and no stop", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(200, "DO_PUSH", {})
				fire(c4, 400)
				env.ReceivedFromProxy(200, "DO_RELEASE", {})
				assert.equal(0, fire(c4, 1500), "nothing follows any more")
				state(env, "active", { reason = "event" })
				group(env, { on = "true", level = "70" })
				assert.same({}, dims(c4))
				assert.equal(1, #messages(c4, "HUE_SCENE_RECALL"))
				assert.equal(0, #messages(c4, "HUE_SCENE_OFF"))
				assert.same({ 100, 70 }, changed(c4), "the tile follows the scene once Hue says it runs")
			end)

			it("holding bottom while off does nothing, as for scenes", function()
				local env, c4 = smart_scene("inactive")
				env.ReceivedFromProxy(201, "DO_PUSH", {})
				fire(c4, 400)
				env.ReceivedFromProxy(201, "DO_RELEASE", {})
				assert.same({}, c4.sent)
			end)

			it("while it runs, holds dim the room and the slider moves it, as for scenes", function()
				local env, c4 = smart_scene("active")
				group(env, { on = "true", level = "50" })
				fire(c4, 1000) -- the level report's throttle window
				c4.sent = {}
				env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "0" })
				assert.same({ { id = BRIDGE_ID, command = "HUE_SCENE_LEVEL",
					params = { rid = "s1", device_id = "2061", level = "30", rate = "0" } } }, c4.sent)
				group(env, { level = "30" })
				env.ReceivedFromProxy(201, "DO_PUSH", {})
				fire(c4, 400)
				env.ReceivedFromProxy(201, "DO_RELEASE", {})
				assert.same({
					{ rid = "s1", device_id = "2061", direction = "down", duration = "5000" },
					{ rid = "s1", device_id = "2061", direction = "stop" },
				}, dims(c4))
				assert.equal(0, #messages(c4, "HUE_SCENE_RECALL"))
			end)
		end)

		describe("Recall As (Decision 12)", function()
			it("is hidden after late init on a time-based device and shown on an ordinary one", function()
				local _, smart = load_scene({ rid = "s1", kind = "smart_scene" })
				assert.same({ { "Recall As", 1 } }, smart.calls_to("SetPropertyAttribs"))
				local _, plain = load_scene({ rid = "s1" })
				assert.same({ { "Recall As", 0 } }, plain.calls_to("SetPropertyAttribs"))
			end)

			it("is shown or hidden again whenever a configure changes the kind, and only then", function()
				local env, c4 = load_scene({ rid = "s1" })
				c4.calls = {}
				configure(env)
				configure(env, SMART)
				configure(env, SMART)
				configure(env)
				assert.same({ { "Recall As", 1 }, { "Recall As", 0 } }, c4.calls_to("SetPropertyAttribs"))
			end)

			it("is applied once, at late init, when a configure that came before it names the kind", function()
				local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
				stub_attribs(c4)
				c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
				configure(env, SMART)
				assert.same({}, c4.calls_to("SetPropertyAttribs"), "never before late init")
				env.OnDriverLateInit("DIT_STARTUP")
				assert.same({ { "Recall As", 1 } }, c4.calls_to("SetPropertyAttribs"))
			end)

			it("never stops late init: on a runtime without SetPropertyAttribs, or when it fails", function()
				local env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
				c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
				c4.persist.hue_rid = "s1"
				c4.persist.hue_kind = "smart_scene"
				assert.has_no.errors(function() env.OnDriverLateInit("DIT_STARTUP") end)
				assert.equal(1, #messages(c4, "HUE_SCENE_HELLO"))

				env, c4 = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
				c4.SetPropertyAttribs = function() error("Director says no") end
				c4:Bind(BRIDGE_ID, 1, SCENE_ID, 1, "HUE_BRIDGE")
				c4.persist.hue_rid = "s1"
				c4.persist.hue_kind = "smart_scene"
				assert.has_no.errors(function() env.OnDriverLateInit("DIT_STARTUP") end)
				assert.equal(1, #messages(c4, "HUE_SCENE_HELLO"))
			end)
		end)

		describe("Status (Decision 13)", function()
			it("names the slot it plays while it runs, and says when it does not", function()
				local env = smart_scene("inactive")
				assert.equal(SMART_STATUS .. "; not running", env.Properties["Status"])
				state(env, "active", { reason = "event" })
				assert.equal(SMART_STATUS .. "; now Shine (from sunset)", env.Properties["Status"])
				state(env, "active", { reason = "event", slot_name = "Relax", slot_start = "16:00" })
				assert.equal(SMART_STATUS .. "; now Relax (from 16:00)", env.Properties["Status"])
				state(env, "active", { reason = "recall" })
				assert.equal(SMART_STATUS .. "; now Relax (from 16:00)", env.Properties["Status"],
					"a STATE without a slot keeps the one known")
				state(env, "inactive", { reason = "event" })
				assert.equal(SMART_STATUS .. "; not running", env.Properties["Status"])
			end)

			it("says running while the slot is unknown, and names only the scene before any status", function()
				local env = load_scene({ rid = "s1" })
				configure(env, smart_with({ name = "Natural light", group_name = "Living Room", group_type = "room",
					slot_name = "", slot_start = "" }))
				assert.equal("Hue time-based scene Natural light in Living Room", env.Properties["Status"])
				state(env, "active", { reason = "event" })
				assert.equal("Hue time-based scene Natural light in Living Room; running", env.Properties["Status"])
			end)

			it("takes the slot as each configure sends it", function()
				local env = smart_scene("active")
				configure(env, smart_with({ slot_name = "Arise", slot_start = "07:00" }))
				assert.equal(SMART_STATUS .. "; now Arise (from 07:00)", env.Properties["Status"])
				configure(env, smart_with({ slot_name = "", slot_start = "" }))
				assert.equal(SMART_STATUS .. "; running", env.Properties["Status"])
			end)

			it("gives way to the deleted-in-Hue text", function()
				local env = smart_scene("active")
				configure(env, smart_with({ state = "gone" }))
				assert.equal("Scene deleted in Hue; ON does nothing; re-link or Forget", env.Properties["Status"])
			end)
		end)

		describe("Adopt Hue Name (Decision 7)", function()
			it("names a zone's time-based scene after the zone and the scene without the app's number", function()
				local env, c4 = smart_scene()
				local proxy_id = fake.project.devices[SCENE_ID].proxy_id
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
				assert.same({ { proxy_id, "Downstairs Golden hours" } }, c4.calls_to("RenameDevice"))
			end)

			it("names a room's after the scene alone, and leaves a name without a number as it is", function()
				local env, c4 = smart_scene()
				configure(env, smart_with({ name = "Natural light", group_name = "Living Room", group_type = "room" }))
				local proxy_id = fake.project.devices[SCENE_ID].proxy_id
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Adopt Hue Name" })
				assert.same({ { proxy_id, "Natural light" } }, c4.calls_to("RenameDevice"))
			end)
		end)
	end)
end)
