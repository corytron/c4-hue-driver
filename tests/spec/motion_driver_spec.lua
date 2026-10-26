-- Hue Motion driver against the fake runtime, with a bridge driver standing
-- behind binding 1 as device 15 (bound with C4:Bind, as the bridge's Add
-- Motion Sensor or Composer would), so SendToDevice to it can be asserted on.
-- The contract is docs/motion-design.md §2 (this device) and §3 (messages);
-- the owner-facing texts per state are docs/edge-cases-motion.md §6 (EC).
-- Every id below is invented.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BRIDGE_ID = 15
local MOTION_ID = 2101
local RID = "0f3a2b1c-0000-4000-8000-000000001201"
local OTHER_RID = "0f3a2b1c-0000-4000-8000-000000001207"
local AREA_RID = "ac00d1e2-0000-4000-8000-000000001203"

local HOLD = "Occupancy Hold Time (s)"

-- The sensor and the area HUE_MOTION_CONFIGURE describes, every value a
-- string as Director hands it over.
local SENSOR = { rid = RID, kind = "sensor", name = "Hallway sensor", model = "Hue motion sensor (SML003)",
	hue_room = "Hallway", id_v1 = "/sensors/12", gone = "false", has_light_level = "true",
	has_temperature = "true", has_battery = "true" }
local AREA = { rid = AREA_RID, kind = "area", name = "Kitchen motion area", hue_room = "Kitchen", gone = "false",
	has_light_level = "false", has_temperature = "false", has_battery = "false" }

local SENSOR_STATUS = "Hue motion sensor Hallway sensor in Hallway"
local AREA_STATUS = "MotionAware area Kitchen motion area in Kitchen"

local VARIABLE_NAMES = { "Online", "Enabled", "Light Level", "Temperature C", "Temperature F", "Battery Level",
	"Battery Low" }

local function quiet()
	log.sink = function() end
end

-- The bridge's change time, as it sends it: ISO 8601 in UTC.
local function iso(t)
	return os.date("!%Y-%m-%dT%H:%M:%S.000Z", t)
end

-- opts.bind=false leaves the device unbound; opts.persist puts values in the
-- store before the driver starts (its earlier life); opts.props sets
-- properties; opts.dit the init type. OnDriverInit runs first, as Director
-- runs it.
local function load_motion(opts)
	opts = opts or {}
	local env, c4 = fake.load_driver("hue_motion", opts.props or {}, { device_id = MOTION_ID })
	for k, v in pairs(opts.persist or {}) do
		c4.persist[k] = v
	end
	env.OnDriverInit(opts.dit or "DIT_STARTUP")
	if opts.bind ~= false then
		c4:Bind(BRIDGE_ID, 1, MOTION_ID, 1, "HUE_BRIDGE")
	end
	env.OnDriverLateInit(opts.dit or "DIT_STARTUP")
	return env, c4
end

local function configure(env, base, extra)
	local params = {}
	for k, v in pairs(base or SENSOR) do params[k] = v end
	for k, v in pairs(extra or {}) do params[k] = v end
	env.ExecuteCommand("HUE_MOTION_CONFIGURE", params)
end

local function state(env, params)
	params.rid = params.rid or RID
	params.reason = params.reason or "event"
	env.ExecuteCommand("HUE_MOTION_STATE", params)
end

local function clear(c4)
	c4.calls = {}
	c4.sent = {}
	c4.events_fired = {}
end

-- A configured sensor (or opts.base) whose first state the bridge reported:
-- no motion (opts.motion "true" for motion), online and enabled, with the
-- recordings cleared.
local function known(opts)
	opts = opts or {}
	local env, c4 = load_motion(opts)
	configure(env, opts.base or SENSOR)
	state(env, { rid = (opts.base or SENSOR).rid, reason = "hello", motion = opts.motion or "false",
		motion_changed = iso(os.time()), online = "true", enabled = "true" })
	clear(c4)
	return env, c4
end

-- The commands sent to the contact proxy (binding 5001), in order.
local function contact(c4)
	local out = {}
	for _, args in ipairs(c4.calls_to("SendToProxy")) do
		if args[1] == 5001 then out[#out + 1] = args[2] end
	end
	return out
end

-- What went out on the temperature output (binding 2): { command, params }.
local function output(c4)
	local out = {}
	for _, args in ipairs(c4.calls_to("SendToProxy")) do
		if args[1] == 2 then out[#out + 1] = { args[2], args[3] } end
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

-- The fake records three SendToDevice arguments; this keeps all five.
local function capture_sends(c4)
	local out = {}
	local original = c4.SendToDevice
	c4.SendToDevice = function(self, id, command, params, allow_empty, log_command)
		out[#out + 1] = { id = id, command = command, params = params, allow_empty = allow_empty,
			log_command = log_command }
		return original(self, id, command, params, allow_empty, log_command)
	end
	return out
end

-- Every SendToDevice with that command, in order.
local function messages(c4, command)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.command == command then out[#out + 1] = m end
	end
	return out
end

-- Fire only the active timers with that delay, as if just that much time had
-- passed for them. Returns the count.
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

local function count_timers(c4, delay)
	local n = 0
	for _, timer in ipairs(c4.active_timers()) do
		if timer.delay == delay then n = n + 1 end
	end
	return n
end

local function variable(c4, name)
	return c4.variables[name] and c4.variables[name].value
end

local function action(env, command)
	env.ExecuteCommand("LUA_ACTION", { ACTION = command })
end

describe("Hue Motion driver", function()
	before_each(quiet)

	describe("variables (§2.3)", function()
		it("adds the seven variables in OnDriverInit, in the fixed order, read-only, ids 1001 to 1007", function()
			local env, c4 = fake.load_driver("hue_motion", {}, { device_id = MOTION_ID })
			env.OnDriverInit("DIT_ADDING")
			assert.same(VARIABLE_NAMES, c4.variable_names)
			local types = { "BOOL", "BOOL", "INT", "NUMBER", "NUMBER", "INT", "BOOL" }
			for i, name in ipairs(VARIABLE_NAMES) do
				local var = c4.variables[name]
				assert.equal(1000 + i, var.id, name)
				assert.equal(types[i], var.type, name)
				assert.is_true(var.read_only, name)
				assert.is_false(var.hidden, name)
			end
			-- A new device starts at 0 and false, and nothing is set before late init.
			assert.same({ "0", "0", "0", "0", "0", "0", "0" }, {
				variable(c4, "Online"), variable(c4, "Enabled"), variable(c4, "Light Level"),
				variable(c4, "Temperature C"), variable(c4, "Temperature F"), variable(c4, "Battery Level"),
				variable(c4, "Battery Low") })
			assert.same({}, c4.calls_to("SetVariable"))
			assert.same({}, c4.calls_to("SendToProxy"))
		end)

		it("starts every variable at its persisted value, so a restart keeps the last readings", function()
			local _, c4 = load_motion({ persist = { hue_rid = RID, hue_kind = "sensor", motion_values = {
				online = true, enabled = true, lux = 123, temp_c = 21.53, battery_level = 85, battery_state = "low",
			} } })
			assert.equal("1", variable(c4, "Online"))
			assert.equal("1", variable(c4, "Enabled"))
			assert.equal("123", variable(c4, "Light Level"))
			assert.equal("21.5", variable(c4, "Temperature C"))
			assert.equal("70.8", variable(c4, "Temperature F"))
			assert.equal("85", variable(c4, "Battery Level"))
			assert.equal("1", variable(c4, "Battery Low"))
			assert.same({}, c4.calls_to("SetVariable"), "nothing changed, nothing set")
		end)

		it("sets a variable from a reading, only when its value changes", function()
			local env, c4 = known()
			state(env, { online = "true", lux = "123.4", temperature = "21.53", battery_level = "85",
				battery_state = "normal" })
			assert.equal("1", variable(c4, "Online"))
			assert.equal("1", variable(c4, "Enabled"))
			assert.equal("123", variable(c4, "Light Level"))
			assert.equal("21.5", variable(c4, "Temperature C"))
			assert.equal("70.8", variable(c4, "Temperature F"))
			assert.equal("85", variable(c4, "Battery Level"))
			assert.equal("0", variable(c4, "Battery Low"))
			local sets = #c4.calls_to("SetVariable")
			state(env, { lux = "123", temperature = "21.53", battery_level = "85", battery_state = "normal" })
			assert.equal(sets, #c4.calls_to("SetVariable"), "the same values are not set again")
		end)

		it("keeps a variable's last value when the reading is lost, and across a restart", function()
			local env, c4 = known()
			state(env, { lux = "40", temperature = "19.5", battery_level = "60", battery_state = "normal" })
			state(env, { online = "false", status = "Not reachable since 14:02; motion not current" })
			assert.equal("0", variable(c4, "Online"))
			assert.equal("40", variable(c4, "Light Level"))
			assert.equal("19.5", variable(c4, "Temperature C"))
			assert.equal("60", variable(c4, "Battery Level"))

			local persisted = c4.persist
			local _, c4b = load_motion({ persist = persisted })
			assert.equal("0", variable(c4b, "Online"))
			assert.equal("40", variable(c4b, "Light Level"))
			assert.equal("19.5", variable(c4b, "Temperature C"))
		end)

		it("keeps an area's reading variables at 0 and Battery Low false", function()
			local env, c4 = known({ base = AREA })
			state(env, { rid = AREA_RID, lux = "200", temperature = "20", battery_level = "5", battery_state = "low" })
			assert.equal("0", variable(c4, "Light Level"))
			assert.equal("0", variable(c4, "Temperature C"))
			assert.equal("0", variable(c4, "Temperature F"))
			assert.equal("0", variable(c4, "Battery Level"))
			assert.equal("0", variable(c4, "Battery Low"))
			assert.equal("1", variable(c4, "Online"))
			assert.same({}, c4.events_fired)
		end)
	end)

	describe("the contact proxy (§2.7)", function()
		it("sends nothing before the first state and leaves GET_STATE unanswered until then", function()
			local env, c4 = load_motion({ persist = { hue_rid = RID, hue_kind = "sensor", motion_shown = "open" } })
			configure(env)
			env.ReceivedFromProxy(5001, "GET_STATE", {})
			assert.same({}, contact(c4))
			assert.equal("Waiting for the bridge", env.Properties["Status"])
		end)

		it("sends the first state after a start as STATE_* when nothing was persisted", function()
			local env, c4 = load_motion()
			configure(env)
			state(env, { reason = "hello", motion = "true", motion_changed = iso(os.time()) })
			assert.same({ "STATE_OPENED" }, contact(c4))
			assert.equal("open", c4.persist.motion_shown)

			env, c4 = load_motion()
			configure(env)
			state(env, { reason = "hello", motion = "false", motion_changed = iso(os.time()) })
			assert.same({ "STATE_CLOSED" }, contact(c4))
			assert.equal("closed", c4.persist.motion_shown)
		end)

		it("sends STATE_* when the first state equals what the proxy last got", function()
			for _, case in ipairs({ { "open", "true", "STATE_OPENED" }, { "closed", "false", "STATE_CLOSED" } }) do
				local env, c4 = load_motion({ persist = { motion_shown = case[1] } })
				configure(env)
				state(env, { reason = "resync", motion = case[2], motion_changed = iso(os.time()) })
				assert.same({ case[3] }, contact(c4), case[1])
			end
		end)

		it("sends OPENED or CLOSED when the first state differs from what the proxy last got (EC R4, R5)", function()
			local env, c4 = load_motion({ persist = { motion_shown = "closed" } })
			configure(env)
			state(env, { reason = "resync", motion = "true", motion_changed = iso(os.time() - 3600) })
			assert.same({ "OPENED" }, contact(c4))

			env, c4 = load_motion({ persist = { motion_shown = "open" } })
			configure(env)
			state(env, { reason = "resync", motion = "false", motion_changed = iso(os.time()) })
			assert.same({ "CLOSED" }, contact(c4))
			assert.equal("closed", c4.persist.motion_shown)
		end)

		it("later sends only real changes; a repeated reading sends nothing", function()
			local env, c4 = known()
			state(env, { motion = "true", motion_changed = iso(os.time()) })
			state(env, { motion = "true", motion_changed = iso(os.time()) })
			state(env, { lux = "50" })
			state(env, { motion = "false", motion_changed = iso(os.time()) })
			state(env, { motion = "false", motion_changed = iso(os.time()), reason = "resync" })
			assert.same({ "OPENED", "CLOSED" }, contact(c4))
		end)

		it("answers GET_STATE with STATE_* once the state is known", function()
			local env, c4 = known()
			env.ReceivedFromProxy(5001, "GET_STATE", {})
			state(env, { motion = "true", motion_changed = iso(os.time()) })
			env.ReceivedFromProxy(5001, "GET_STATE", {})
			assert.same({ "STATE_CLOSED", "OPENED", "STATE_OPENED" }, contact(c4))
		end)

		it("sends every contact message on 5001 as NOTIFY with an empty table", function()
			local env, c4 = load_motion()
			local captured = capture_proxy(c4)
			configure(env)
			state(env, { reason = "hello", motion = "false" })
			state(env, { motion = "true" })
			state(env, { motion = "false" })
			env.ReceivedFromProxy(5001, "GET_STATE", {})
			assert.same({
				{ 5001, "STATE_CLOSED", {}, "NOTIFY" },
				{ 5001, "OPENED", {}, "NOTIFY" },
				{ 5001, "CLOSED", {}, "NOTIFY" },
				{ 5001, "STATE_CLOSED", {}, "NOTIFY" },
			}, captured)
		end)

		it("holds the bridge's messages until late init and applies them then", function()
			local env, c4 = fake.load_driver("hue_motion", {}, { device_id = MOTION_ID })
			env.OnDriverInit("DIT_STARTUP")
			c4:Bind(BRIDGE_ID, 1, MOTION_ID, 1, "HUE_BRIDGE")
			configure(env)
			state(env, { reason = "hello", motion = "true", lux = "80" })
			assert.same({}, c4.calls_to("SendToProxy"))
			assert.same({}, c4.calls_to("UpdateProperty"))
			assert.same({}, c4.calls_to("SetVariable"))
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ "STATE_OPENED" }, contact(c4))
			assert.equal("80 lux", env.Properties["Light Level"])
			assert.equal(SENSOR_STATUS, env.Properties["Status"])
		end)

		it("ignores a state or a forgotten for another rid", function()
			local env, c4 = known()
			state(env, { rid = OTHER_RID, motion = "true", online = "false" })
			env.ExecuteCommand("HUE_MOTION_FORGOTTEN", { rid = OTHER_RID, name = "Porch sensor" })
			assert.same({}, contact(c4))
			assert.equal("Yes", env.Properties["Online"])
			assert.equal(SENSOR_STATUS, env.Properties["Status"])
		end)
	end)

	describe("Occupancy Hold Time (D10, EC R11)", function()
		it("closes at once with the default of 0", function()
			local env, c4 = known()
			state(env, { motion = "true" })
			state(env, { motion = "false" })
			assert.same({ "OPENED", "CLOSED" }, contact(c4))
			assert.equal(0, #c4.active_timers())
		end)

		it("holds Hue's no motion for the set time, then sends CLOSED", function()
			local env, c4 = known({ props = { [HOLD] = "30" } })
			state(env, { motion = "true", motion_changed = iso(os.time()) })
			state(env, { motion = "false", motion_changed = iso(os.time()) })
			assert.same({ "OPENED" }, contact(c4))
			assert.matches("^No motion", env.Properties["Hue Motion"], "the row shows Hue's own state")
			assert.equal(1, fire(c4, 30000))
			assert.same({ "OPENED", "CLOSED" }, contact(c4))
		end)

		it("is cancelled by new motion, and the next no motion holds again in full", function()
			local env, c4 = known({ props = { [HOLD] = "30" } })
			state(env, { motion = "true" })
			state(env, { motion = "false" })
			state(env, { motion = "true" })
			assert.equal(0, fire(c4, 30000), "the wait was cancelled")
			assert.same({ "OPENED" }, contact(c4))
			state(env, { motion = "false" })
			assert.equal(1, count_timers(c4, 30000))
			fire(c4, 30000)
			assert.same({ "OPENED", "CLOSED" }, contact(c4))
		end)

		it("leaves a running hold alone when no motion is reported again", function()
			local env, c4 = known({ props = { [HOLD] = "30" } })
			state(env, { motion = "true" })
			state(env, { motion = "false" })
			state(env, { motion = "false", reason = "check" })
			assert.equal(1, count_timers(c4, 30000))
		end)

		it("applies a changed value from the next no motion", function()
			local env, c4 = known({ props = { [HOLD] = "30" } })
			state(env, { motion = "true" })
			state(env, { motion = "false" })
			env.Properties[HOLD] = "10"
			env.OnPropertyChanged(HOLD)
			assert.equal(1, count_timers(c4, 30000), "the running hold keeps its length")
			fire(c4, 30000)
			state(env, { motion = "true" })
			state(env, { motion = "false" })
			assert.equal(1, count_timers(c4, 10000))
			fire(c4, 10000)
			assert.same({ "OPENED", "CLOSED", "OPENED", "CLOSED" }, contact(c4))
		end)

		it("after a restart with motion shown, reports STATE_OPENED and holds the first no motion in full", function()
			local env, c4 = load_motion({ props = { [HOLD] = "30" }, persist = { motion_shown = "open" } })
			configure(env)
			state(env, { reason = "hello", motion = "false", motion_changed = iso(os.time()) })
			assert.same({ "STATE_OPENED" }, contact(c4))
			fire(c4, 30000)
			assert.same({ "STATE_OPENED", "CLOSED" }, contact(c4))
		end)

		it("does not hold a no motion the proxy never showed as motion", function()
			local env, c4 = load_motion({ props = { [HOLD] = "30" }, persist = { motion_shown = "closed" } })
			configure(env)
			state(env, { reason = "hello", motion = "false" })
			assert.same({ "STATE_CLOSED" }, contact(c4))
			assert.equal(0, count_timers(c4, 30000))
		end)

		it("takes 0 to 3600 s, a larger value as 3600 and anything else as 0", function()
			local env, c4 = known({ props = { [HOLD] = "5000" } })
			state(env, { motion = "true" })
			state(env, { motion = "false" })
			assert.equal(1, count_timers(c4, 3600000))

			for _, junk in ipairs({ "-5", "abc", "" }) do
				env, c4 = known({ props = { [HOLD] = junk } })
				state(env, { motion = "true" })
				state(env, { motion = "false" })
				assert.same({ "OPENED", "CLOSED" }, contact(c4), junk)
			end
		end)

		it("never holds a deliberate end", function()
			local env, c4 = known({ props = { [HOLD] = "30" } })
			state(env, { motion = "true" })
			state(env, { motion = "false" })
			state(env, { ended = "off", enabled = "false", status = "Switched off in the Hue app; no motion is reported" })
			assert.same({ "OPENED", "CLOSED" }, contact(c4))
			assert.equal(0, count_timers(c4, 30000))
		end)
	end)

	describe("deliberate ends and failures (§2.7, EC §6)", function()
		it("closes once and at once when the sensor is deleted in Hue, and takes it offline", function()
			local env, c4 = known({ motion = "true" })
			state(env, { lux = "30", temperature = "20.5" })
			state(env, { ended = "deleted", status = "Sensor deleted in Hue since 10-26; re-link or Forget" })
			state(env, { ended = "deleted", status = "Sensor deleted in Hue since 10-26; re-link or Forget" })
			assert.same({ "CLOSED" }, contact(c4))
			assert.equal("No", env.Properties["Online"])
			assert.equal("0", variable(c4, "Online"))
			assert.same({ 5 }, c4.events_fired)
			assert.equal("Sensor deleted in Hue since 10-26; re-link or Forget", env.Properties["Status"])
			assert.equal("Unknown", env.Properties["Hue Motion"])
			local out = output(c4)
			assert.equal("VALUE_UNAVAILABLE", out[#out][1])
			assert.same({ STATUS = "offline" }, out[#out][2])
		end)

		it("closes once when the sensor is switched off in Hue, and still takes what Hue reports", function()
			local env, c4 = known({ motion = "true" })
			state(env, { lux = "30", temperature = "20.5", battery_level = "70", battery_state = "normal" })
			state(env, { ended = "off", enabled = "false", status = "Switched off in the Hue app; no motion is reported" })
			assert.same({ "CLOSED" }, contact(c4))
			assert.equal("Switched off in the Hue app", env.Properties["Enabled"])
			assert.equal("0", variable(c4, "Enabled"))
			assert.same({ 7 }, c4.events_fired)
			assert.equal("Yes", env.Properties["Online"], "a switched-off sensor is still online")
			assert.equal("Unknown", env.Properties["Hue Motion"])
			assert.equal("Switched off in the Hue app; no motion is reported", env.Properties["Status"])
			assert.same({ "VALUE_UNAVAILABLE", { STATUS = "offline" } }, output(c4)[2])

			-- The bridge repeats the end with every state while it lasts, and
			-- passes on what Hue still reports: taken, without a second end.
			state(env, { ended = "off", status = "Switched off in the Hue app; no motion is reported",
				battery_level = "69", motion = "true" })
			assert.same({ "CLOSED" }, contact(c4), "no motion is reported while switched off")
			assert.equal("69 % (normal)", env.Properties["Battery"])
			assert.equal(2, #output(c4), "no second VALUE_UNAVAILABLE")
			state(env, { ended = "off", status = "Switched off in the Hue app; no motion is reported",
				temperature = "20.9" })
			assert.same({ "VALUE_CHANGED", "20.9" }, { output(c4)[3][1], output(c4)[3][2].CELSIUS })
			assert.equal("30 lux", env.Properties["Light Level"])
			assert.equal("20.9 °C (69.6 °F)", env.Properties["Temperature"])

			-- Switched on again: Enabled returns, the next reading goes out as a change.
			state(env, { enabled = "true", motion = "true", lux = "31" })
			assert.same({ "CLOSED", "OPENED" }, contact(c4))
			assert.equal("Yes", env.Properties["Enabled"])
			assert.same({ 7, 8 }, c4.events_fired)
			assert.equal("31 lux", env.Properties["Light Level"])
			assert.equal(SENSOR_STATUS, env.Properties["Status"])
		end)

		it("closes once when an area is paused and says so in its words", function()
			local env, c4 = known({ base = AREA, motion = "true" })
			state(env, { rid = AREA_RID, ended = "paused", enabled = "false",
				status = "Paused in the Hue app; no motion is reported" })
			assert.same({ "CLOSED" }, contact(c4))
			assert.equal("Paused in the Hue app", env.Properties["Enabled"])
			assert.same({ 7 }, c4.events_fired)
			assert.same({}, output(c4), "an area never sends on the temperature output")
		end)

		it("sends nothing on a deliberate end while no motion shows", function()
			for _, ended in ipairs({ "deleted", "off", "paused", "forgotten" }) do
				local env, c4 = known()
				state(env, { ended = ended })
				assert.same({}, contact(c4), ended)
			end
		end)

		it("keeps the sensor as it is on a failure, and says the motion is not current (D3)", function()
			local env, c4 = known({ motion = "true" })
			state(env, { lux = "30", temperature = "20.5", battery_level = "70", battery_state = "normal" })
			c4.events_fired = {}
			state(env, { online = "false", status = "Not reachable since 14:02; motion not current" })
			assert.same({}, contact(c4), "no CLOSED")
			assert.equal("No", env.Properties["Online"])
			assert.same({ 5 }, c4.events_fired)
			assert.equal("Not reachable since 14:02; motion not current", env.Properties["Status"])
			assert.matches("^Motion", env.Properties["Hue Motion"], "Hue's last state stays")
			local since = os.date("%H:%M", c4.persist.motion_values.offline_since)
			assert.equal("30 lux (old, " .. since .. ")", env.Properties["Light Level"])
			assert.equal("20.5 °C (68.9 °F) (old, " .. since .. ")", env.Properties["Temperature"])
			assert.equal("70 % (normal) (old, " .. since .. ")", env.Properties["Battery"])

			-- Reachable again with no motion: Online, a change, fresh rows.
			state(env, { online = "true", motion = "false", lux = "28" })
			assert.same({ "CLOSED" }, contact(c4))
			assert.same({ 5, 6 }, c4.events_fired)
			assert.equal("28 lux", env.Properties["Light Level"])
			assert.equal(SENSOR_STATUS, env.Properties["Status"])
		end)

		it("keeps a reading that arrives while offline, shown as old and never on the output", function()
			local env, c4 = known()
			state(env, { temperature = "20" })
			state(env, { online = "false", status = "Not reachable since 14:02; motion not current" })
			-- A full state while the sensor is away carries the bridge's last values.
			state(env, { reason = "resync", online = "false", status = "Not reachable since 14:02; motion not current",
				lux = "12", temperature = "19", battery_level = "40", battery_state = "normal" })
			assert.equal("19.0", variable(c4, "Temperature C"))
			local since = os.date("%H:%M", c4.persist.motion_values.offline_since)
			assert.equal("12 lux (old, " .. since .. ")", env.Properties["Light Level"])
			assert.equal("19.0 °C (66.2 °F) (old, " .. since .. ")", env.Properties["Temperature"])
			local out = output(c4)
			assert.equal(2, #out)
			assert.equal("VALUE_UNAVAILABLE", out[2][1])
		end)

		it("does not let a repeated end cancel a test", function()
			local env, c4 = known({ base = AREA })
			state(env, { rid = AREA_RID, ended = "paused", enabled = "false",
				status = "Paused in the Hue app; no motion is reported" })
			action(env, "Test Motion")
			state(env, { rid = AREA_RID, ended = "paused", status = "Paused in the Hue app; no motion is reported" })
			assert.equal(1, count_timers(c4, 30000))
			fire(c4, 30000)
			assert.same({ "OPENED", "CLOSED" }, contact(c4))
			-- Resumed: its next state has no end, and its motion is reported again.
			state(env, { rid = AREA_RID, enabled = "true", motion = "true" })
			assert.same({ "OPENED", "CLOSED", "OPENED" }, contact(c4))
			assert.same({ 7, 8 }, c4.events_fired)
		end)

		it("shows the bridge's Status text as sent; a state without one is fine again", function()
			local env = known({ base = AREA })
			state(env, { rid = AREA_RID, status = "Area degraded: Desk Lamp not responding", motion = "true" })
			assert.equal("Area degraded: Desk Lamp not responding", env.Properties["Status"])
			state(env, { rid = AREA_RID, status = "Bridge not answering since 14:02; motion not current" })
			assert.equal("Bridge not answering since 14:02; motion not current", env.Properties["Status"])
			assert.equal("Yes", env.Properties["Online"], "the bridge away leaves Online alone")
			state(env, { rid = AREA_RID, motion = "false", reason = "resync" })
			assert.equal(AREA_STATUS, env.Properties["Status"])
		end)

		it("takes a device configured as deleted in Hue as a deliberate end", function()
			local env, c4 = known({ motion = "true" })
			configure(env, SENSOR, { gone = "true" })
			assert.same({ "CLOSED" }, contact(c4))
			assert.equal("No", env.Properties["Online"])
			assert.equal("Sensor deleted in Hue; re-link or Forget", env.Properties["Status"])
			configure(env, SENSOR, { gone = "true" })
			assert.same({ "CLOSED" }, contact(c4), "once")
		end)

		it("closes once when forgotten, says so, and a configure ends the forgotten state", function()
			local env, c4 = known({ motion = "true" })
			env.ExecuteCommand("HUE_MOTION_FORGOTTEN", { rid = RID, name = "Hallway sensor" })
			assert.same({ "CLOSED" }, contact(c4))
			assert.equal("Forgotten by the bridge (was Hue motion sensor Hallway sensor)", env.Properties["Status"])
			assert.equal("Delete this device in Composer, or bind it again and use Link Devices",
				env.Properties["Last Action"])
			assert.equal("No", env.Properties["Online"])
			-- Unbound by the bridge afterwards: still the forgotten text, nothing more to close.
			c4:Unbind(MOTION_ID, 1)
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.same({ "CLOSED" }, contact(c4))
			assert.equal("Forgotten by the bridge (was Hue motion sensor Hallway sensor)", env.Properties["Status"])
			c4:Bind(BRIDGE_ID, 1, MOTION_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			configure(env)
			assert.equal("Waiting for the bridge", env.Properties["Status"])
			state(env, { reason = "hello", motion = "false", online = "true" })
			assert.equal(SENSOR_STATUS, env.Properties["Status"])
		end)

		it("forgets Hue's state at a re-link and catches up with the new sensor's first reading", function()
			local env, c4 = known({ props = { [HOLD] = "30" }, motion = "true" })
			state(env, { motion = "false" })
			assert.equal(1, count_timers(c4, 30000))
			configure(env, SENSOR, { rid = OTHER_RID, name = "Hallway sensor 2" })
			assert.equal(0, count_timers(c4, 30000), "the old sensor's hold ends")
			assert.equal("Unknown", env.Properties["Hue Motion"])
			assert.equal(OTHER_RID, c4.persist.hue_rid)
			state(env, { rid = RID, motion = "true" })
			assert.same({}, contact(c4), "the old rid is ignored")
			state(env, { rid = OTHER_RID, motion = "false" })
			assert.equal(1, count_timers(c4, 30000), "held again in full")
			fire(c4, 30000)
			assert.same({ "CLOSED" }, contact(c4))
		end)
	end)

	describe("the temperature output (§2.7, C4R §3.1)", function()
		it("sends VALUE_CHANGED with CELSIUS, FAHRENHEIT and TIMESTAMP on binding 2 for a reading", function()
			local env, c4 = known()
			local captured = capture_proxy(c4)
			local before = os.time()
			state(env, { temperature = "21.53" })
			local after = os.time()
			assert.equal(1, #captured)
			local call = captured[1]
			assert.equal(2, call[1])
			assert.equal("VALUE_CHANGED", call[2])
			assert.equal("NOTIFY", call[4])
			assert.equal("21.53", call[3].CELSIUS)
			assert.equal("70.75", call[3].FAHRENHEIT)
			local ts = tonumber(call[3].TIMESTAMP)
			assert.is_true(ts >= before and ts <= after)
			assert.same({ "CELSIUS", "FAHRENHEIT", "TIMESTAMP" }, (function()
				local keys = {}
				for k in pairs(call[3]) do keys[#keys + 1] = k end
				table.sort(keys)
				return keys
			end)())
			state(env, { temperature = "-3.5" })
			assert.equal("-3.5", captured[2][3].CELSIUS)
			assert.equal("25.7", captured[2][3].FAHRENHEIT)
		end)

		it("sends the last value when binding 2 becomes bound, nothing before the first reading", function()
			local env, c4 = known()
			env.OnBindingChanged(2, "TEMPERATURE_VALUE", true, 3005, 500)
			assert.same({}, output(c4))
			state(env, { temperature = "22" })
			env.OnBindingChanged(2, "TEMPERATURE_VALUE", true, 3005, 500)
			local out = output(c4)
			assert.equal(2, #out)
			assert.equal("VALUE_CHANGED", out[2][1])
			assert.equal("22", out[2][2].CELSIUS)
			assert.equal("71.6", out[2][2].FAHRENHEIT)
			env.OnBindingChanged(2, "TEMPERATURE_VALUE", false, 3005, 500)
			assert.equal(2, #output(c4), "nothing to send to a consumer that left")
		end)

		it("answers GET_SENSOR_VALUE with the last value", function()
			local env, c4 = known()
			env.ReceivedFromProxy(2, "GET_SENSOR_VALUE", {})
			assert.same({}, output(c4), "nothing before the first reading")
			state(env, { temperature = "20.25" })
			env.ReceivedFromProxy(2, "GET_SENSOR_VALUE", {})
			local out = output(c4)
			assert.equal(2, #out)
			assert.same(out[1], out[2])
		end)

		it("sends VALUE_UNAVAILABLE once when the reading is lost, until a new reading", function()
			local env, c4 = known()
			state(env, { temperature = "20" })
			state(env, { online = "false", status = "Not reachable since 14:02; motion not current" })
			state(env, { online = "false", status = "Not reachable since 14:02; motion not current" })
			local out = output(c4)
			assert.equal(2, #out)
			assert.same({ "VALUE_UNAVAILABLE", { STATUS = "offline" } }, out[2])
			env.ReceivedFromProxy(2, "GET_SENSOR_VALUE", {})
			assert.same({ "VALUE_UNAVAILABLE", { STATUS = "offline" } }, output(c4)[3])
			state(env, { online = "true" })
			assert.equal(3, #output(c4), "back online: the next reading brings the value")
			state(env, { temperature = "20.5" })
			out = output(c4)
			assert.equal("VALUE_CHANGED", out[4][1])
			assert.equal("20.5", out[4][2].CELSIUS)
		end)

		it("makes the temperature unavailable when the sensor is switched off, forgotten or unbound", function()
			local env, c4 = known()
			state(env, { temperature = "20" })
			state(env, { ended = "off", enabled = "false" })
			assert.equal("VALUE_UNAVAILABLE", output(c4)[2][1])

			env, c4 = known()
			state(env, { temperature = "20" })
			env.ExecuteCommand("HUE_MOTION_FORGOTTEN", { rid = RID })
			assert.equal("VALUE_UNAVAILABLE", output(c4)[2][1])

			env, c4 = known()
			state(env, { temperature = "20" })
			c4:Unbind(MOTION_ID, 1)
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.equal("VALUE_UNAVAILABLE", output(c4)[2][1])
		end)

		it("never sends on binding 2 for an area or for a sensor without a temperature", function()
			local env, c4 = known({ base = AREA })
			state(env, { rid = AREA_RID, temperature = "20", online = "false" })
			env.OnBindingChanged(2, "TEMPERATURE_VALUE", true, 3005, 500)
			env.ReceivedFromProxy(2, "GET_SENSOR_VALUE", {})
			assert.same({}, output(c4))

			env, c4 = load_motion()
			configure(env, SENSOR, { has_temperature = "false" })
			state(env, { temperature = "20", reason = "hello", motion = "false" })
			env.ReceivedFromProxy(2, "GET_SENSOR_VALUE", {})
			assert.same({}, output(c4))
			assert.equal("Not available", env.Properties["Temperature"])
			assert.equal("0", variable(c4, "Temperature C"))
		end)
	end)

	describe("events (§2.4)", function()
		it("fires Light Level Changed when the lux moved by at least max(5 lux, 10 %) since it last fired", function()
			local env, c4 = known()
			state(env, { lux = "100" })
			assert.same({}, c4.events_fired, "the first reading sets the baseline")
			state(env, { lux = "109" })
			assert.same({}, c4.events_fired)
			state(env, { lux = "110" })
			assert.same({ 1 }, c4.events_fired)
			state(env, { lux = "120" })
			assert.same({ 1 }, c4.events_fired, "10 % of 110 is 11")
			state(env, { lux = "121" })
			assert.same({ 1, 1 }, c4.events_fired)
			state(env, { lux = "20" })
			state(env, { lux = "24" })
			assert.same({ 1, 1, 1 }, c4.events_fired, "at 20 lux the step is 5")
			state(env, { lux = "25" })
			assert.same({ 1, 1, 1, 1 }, c4.events_fired)
			state(env, { lux = "0" })
			assert.same({ 1, 1, 1, 1, 1 }, c4.events_fired)
			assert.equal("Dark", env.Properties["Light Level"])
			assert.equal("0", variable(c4, "Light Level"))
		end)

		it("fires Temperature Changed when it moved by at least 0.5 °C since it last fired", function()
			local env, c4 = known()
			state(env, { temperature = "21.03" })
			state(env, { temperature = "21.4" })
			assert.same({}, c4.events_fired)
			state(env, { temperature = "21.53" })
			assert.same({ 2 }, c4.events_fired)
			state(env, { temperature = "21.1" })
			assert.same({ 2 }, c4.events_fired)
			state(env, { temperature = "21.03" })
			assert.same({ 2, 2 }, c4.events_fired)
		end)

		it("keeps the baselines across a restart: a change while down fires once", function()
			local env, c4 = known()
			state(env, { lux = "100", temperature = "20" })
			local persisted = c4.persist
			env, c4 = load_motion({ persist = persisted })
			configure(env)
			state(env, { reason = "hello", motion = "false", lux = "105", temperature = "20.4" })
			assert.same({}, c4.events_fired)
			state(env, { lux = "112", temperature = "20.5" })
			assert.same({ 1, 2 }, c4.events_fired)
		end)

		it("fires Battery Low when Hue's battery state becomes low or critical, Battery Normal when normal again", function()
			local env, c4 = known()
			state(env, { battery_level = "40", battery_state = "normal" })
			assert.same({}, c4.events_fired)
			state(env, { battery_level = "12", battery_state = "low" })
			assert.same({ 3 }, c4.events_fired)
			assert.equal("1", variable(c4, "Battery Low"))
			assert.equal("12 % (low)", env.Properties["Battery"])
			state(env, { battery_level = "3", battery_state = "critical" })
			assert.same({ 3 }, c4.events_fired, "still low")
			state(env, { battery_level = "100", battery_state = "normal" })
			assert.same({ 3, 4 }, c4.events_fired)
			assert.equal("0", variable(c4, "Battery Low"))

			env, c4 = known()
			state(env, { battery_state = "critical" })
			assert.same({ 3 }, c4.events_fired, "a first reading of critical is news")
			assert.equal("critical", env.Properties["Battery"])
		end)

		it("fires Offline and Online, and the Hue switch events, only between known values", function()
			local env, c4 = load_motion()
			configure(env)
			state(env, { reason = "hello", motion = "false", online = "true", enabled = "true" })
			assert.same({}, c4.events_fired, "from not known to known is no change")
			state(env, { online = "false" })
			state(env, { online = "true" })
			state(env, { enabled = "false" })
			state(env, { enabled = "true" })
			assert.same({ 5, 6, 7, 8 }, c4.events_fired)
		end)

		it("sets the variables before the events fire", function()
			local env, c4 = known()
			state(env, { lux = "100" })
			clear(c4)
			state(env, { lux = "300", online = "false" })
			local order = {}
			for _, call in ipairs(c4.calls) do
				if call.name == "SetVariable" or call.name == "FireEventByID" then
					order[#order + 1] = call.name .. " " .. tostring(call.args[1])
				end
			end
			assert.same({ "SetVariable Online", "SetVariable Light Level", "FireEventByID 5", "FireEventByID 1" }, order)
		end)
	end)

	describe("rows (§2.2) and hidden rows per kind", function()
		it("shows the configured identity, the readings and Hue's own state", function()
			local env, c4 = load_motion()
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
			assert.equal("Unknown", env.Properties["Hue Motion"])
			configure(env)
			assert.equal("Motion sensor", env.Properties["Kind"])
			assert.equal("Hallway sensor", env.Properties["Hue Name"])
			assert.equal("Hallway", env.Properties["Hue Room"])
			assert.equal("Hue motion sensor (SML003)", env.Properties["Model"])
			assert.equal("Waiting for the bridge", env.Properties["Status"], "until the first state")
			local now = os.time()
			state(env, { reason = "hello", motion = "true", motion_changed = iso(now), online = "true", enabled = "true",
				lux = "123", temperature = "21.5", battery_level = "85", battery_state = "normal" })
			assert.equal(SENSOR_STATUS, env.Properties["Status"])
			assert.equal("Yes", env.Properties["Online"])
			assert.equal("Yes", env.Properties["Enabled"])
			assert.equal("Motion since " .. os.date("%H:%M", now), env.Properties["Hue Motion"])
			assert.equal("123 lux", env.Properties["Light Level"])
			assert.equal("21.5 °C (70.7 °F)", env.Properties["Temperature"])
			assert.equal("85 % (normal)", env.Properties["Battery"])
			-- The identity persists, so the hello after a restart carries it.
			assert.equal(RID, c4.persist.hue_rid)
			assert.equal("sensor", c4.persist.hue_kind)
			assert.equal("Hallway sensor", c4.persist.hue_name)
			assert.equal("Hue motion sensor (SML003)", c4.persist.hue_model)
		end)

		it("shows the change time with its day when it is not today, and no time when none came", function()
			local env, c4 = known()
			local when = "2026-01-02T03:04:05Z"
			local _, epoch = c4:ParseIso8601DateTime(when)
			state(env, { motion = "true", motion_changed = when })
			assert.equal("Motion since " .. os.date("%m-%d %H:%M", epoch), env.Properties["Hue Motion"])
			state(env, { motion = "false" })
			assert.equal("No motion", env.Properties["Hue Motion"])
		end)

		it("reads Not available for a service the sensor lacks", function()
			local env = load_motion()
			configure(env, SENSOR, { has_light_level = "false", has_battery = "false" })
			state(env, { reason = "hello", motion = "false", lux = "10", battery_level = "50" })
			assert.equal("Not available", env.Properties["Light Level"])
			assert.equal("Not available", env.Properties["Battery"])
			assert.equal("", env.Properties["Temperature"])
		end)

		it("hides the sensor rows on an area's device and shows them on a sensor's", function()
			local env, c4 = load_motion()
			for _, name in ipairs({ "Light Level", "Temperature", "Battery" }) do
				assert.equal(0, c4.property_attribs[name], name .. " shown while the kind is not known")
			end
			configure(env, AREA)
			for _, name in ipairs({ "Light Level", "Temperature", "Battery" }) do
				assert.equal(1, c4.property_attribs[name], name)
			end
			assert.is_nil(c4.property_attribs["Hue Motion"])
			assert.equal("MotionAware area", env.Properties["Kind"])
			assert.equal("MotionAware area", env.Properties["Model"])
			assert.is_nil(c4.persist.hue_model, "an area has no model of its own")
			configure(env, SENSOR)
			for _, name in ipairs({ "Light Level", "Temperature", "Battery" }) do
				assert.equal(0, c4.property_attribs[name], name)
			end
			-- A restarted area's device hides them at late init.
			local _, c4b = load_motion({ persist = { hue_rid = AREA_RID, hue_kind = "area" } })
			assert.equal(1, c4b.property_attribs["Temperature"])
		end)

		it("words the Status, Online and Enabled rows of an area", function()
			local env = known({ base = AREA })
			assert.equal(AREA_STATUS, env.Properties["Status"])
			configure(env, AREA, { hue_room = "(whole home)", name = "Home motion" })
			assert.equal("MotionAware area Home motion (whole home)", env.Properties["Status"])
			state(env, { rid = AREA_RID, online = "false", status = "Area not running in Hue; save it again in the Hue app" })
			assert.equal("No", env.Properties["Online"])
			assert.equal("Area not running in Hue; save it again in the Hue app", env.Properties["Status"])
		end)

		it("says Bound; waiting for the bridge without a Hue resource, Waiting for the bridge with one", function()
			-- A device added by hand from Composer's driver search has no rid.
			local env = load_motion()
			assert.equal("Bound; waiting for the bridge", env.Properties["Status"])
			env = load_motion({ persist = { hue_rid = RID } })
			assert.equal("Waiting for the bridge", env.Properties["Status"])
			env = load_motion({ bind = false })
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
		end)
	end)

	describe("binding to the bridge (§2.7, EC C11, C12)", function()
		it("greets the bridge with HUE_MOTION_HELLO as the bridge's device_send does", function()
			local env, c4 = fake.load_driver("hue_motion", {}, { device_id = MOTION_ID })
			local sends = capture_sends(c4)
			c4.persist.hue_rid, c4.persist.hue_name, c4.persist.hue_kind, c4.persist.hue_model =
				RID, "Hallway sensor", "sensor", "Hue motion sensor (SML003)"
			env.OnDriverInit("DIT_STARTUP")
			c4:Bind(BRIDGE_ID, 1, MOTION_ID, 1, "HUE_BRIDGE")
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal(1, #sends)
			assert.same({ id = BRIDGE_ID, command = "HUE_MOTION_HELLO", params = { rid = RID, device_id = "2101",
				name = "Hallway sensor", kind = "sensor", model = "Hue motion sensor (SML003)" }, allow_empty = false,
				log_command = false }, sends[1])

			-- Debug Mode asks Director to log the message.
			env.Properties["Debug Mode"] = "On"
			env.OnPropertyChanged("Debug Mode")
			action(env, "Refresh From Bridge")
			assert.is_true(sends[2].log_command)
		end)

		it("greets with rid \"\" while it has none (a device added by hand)", function()
			local _, c4 = load_motion()
			local hello = messages(c4, "HUE_MOTION_HELLO")
			assert.equal(1, #hello)
			assert.same({ rid = "", device_id = "2101" }, hello[1].params)
		end)

		it("takes an unbind as a deliberate end", function()
			local env, c4 = known({ motion = "true" })
			state(env, { temperature = "20" })
			c4:Unbind(MOTION_ID, 1)
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.same({ "CLOSED" }, contact(c4))
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			assert.equal("No", env.Properties["Online"])
			assert.same({ 5 }, c4.events_fired)
			assert.equal("VALUE_UNAVAILABLE", output(c4)[2][1])
			action(env, "Refresh From Bridge")
			assert.equal("Not sent: not bound to a Hue Bridge", env.Properties["Last Action"])

			-- Bound again (another bridge): it greets that one and waits for its state.
			clear(c4)
			c4:Bind(16, 1, MOTION_ID, 1, "HUE_BRIDGE")
			env.OnBindingChanged(1, "HUE_BRIDGE", true, 16, 1)
			assert.equal(16, messages(c4, "HUE_MOTION_HELLO")[1].id)
			assert.equal("Waiting for the bridge", env.Properties["Status"])
			state(env, { reason = "hello", motion = "false", online = "true" })
			assert.equal(SENSOR_STATUS, env.Properties["Status"])
			assert.equal("Yes", env.Properties["Online"])
			assert.same({ 6 }, c4.events_fired)
			assert.same({}, contact(c4), "closed already")
		end)

		it("changes nothing while unbound at the start, and gives up after the re-check", function()
			local env, c4 = load_motion({ bind = false, persist = { hue_rid = RID, hue_kind = "sensor",
				motion_shown = "open", motion_values = { online = true } } })
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
			assert.same({}, contact(c4))
			assert.equal("1", variable(c4, "Online"))
			assert.equal(1, count_timers(c4, 5000), "the binding re-check")
			assert.equal(1, count_timers(c4, 61000))
			-- The re-check looks at 5, 15, 30 and 60 s and finds nothing.
			for _, delay in ipairs({ 5000, 10000, 15000, 30000 }) do
				assert.equal(1, fire(c4, delay), delay)
			end
			assert.same({}, contact(c4))
			assert.equal(1, fire(c4, 61000))
			assert.same({ "CLOSED" }, contact(c4))
			assert.equal("No", env.Properties["Online"])
			assert.same({ 5 }, c4.events_fired)
		end)

		it("greets the bridge the re-check finds and gives up nothing", function()
			local env, c4 = load_motion({ bind = false, persist = { hue_rid = RID, motion_shown = "open" } })
			c4:Bind(BRIDGE_ID, 1, MOTION_ID, 1, "HUE_BRIDGE")
			fire(c4, 5000)
			assert.equal(1, #messages(c4, "HUE_MOTION_HELLO"))
			assert.equal(0, count_timers(c4, 61000))
			assert.equal("Waiting for the bridge", env.Properties["Status"])
			assert.same({}, contact(c4))
		end)

		it("says goodbye when Composer deletes the device", function()
			local env, c4 = known()
			local sends = capture_sends(c4)
			env.OnDriverRemovedFromProject()
			assert.same({ { id = BRIDGE_ID, command = "HUE_MOTION_GOODBYE", params = { rid = RID, device_id = "2101" },
				allow_empty = false, log_command = false } }, sends)
			env.OnDriverDestroyed("DIT_LOADED")
			assert.equal(0, #c4.active_timers())
		end)
	end)

	describe("actions (§2.6)", function()
		it("Refresh From Bridge asks the bridge again", function()
			local env, c4 = known()
			action(env, "Refresh From Bridge")
			local hello = messages(c4, "HUE_MOTION_HELLO")
			assert.equal(1, #hello)
			assert.equal(RID, hello[1].params.rid)
			assert.equal("Asked the bridge for this device's state; its answer updates the rows",
				env.Properties["Last Action"])
		end)

		it("Test: Motion opens the sensor, and Hue's state comes back after 30 s", function()
			local env, c4 = known()
			action(env, "Test Motion")
			assert.same({ "OPENED" }, contact(c4))
			assert.equal("Test: motion sent; Hue's state returns within 30 s", env.Properties["Last Action"])
			assert.equal(1, fire(c4, 30000))
			assert.same({ "OPENED", "CLOSED" }, contact(c4))
		end)

		it("Test: No Motion closes the sensor, and the next reading puts Hue's state back at once", function()
			local env, c4 = known({ motion = "true" })
			action(env, "Test No Motion")
			assert.same({ "CLOSED" }, contact(c4))
			assert.equal("Test: no motion sent; Hue's state returns within 30 s", env.Properties["Last Action"])
			state(env, { motion = "true" })
			assert.same({ "CLOSED", "OPENED" }, contact(c4))
			assert.equal(0, count_timers(c4, 30000))
		end)

		it("works without any sensor: the state before the test comes back", function()
			local env, c4 = load_motion({ bind = false, dit = "DIT_ADDING" })
			action(env, "Test Motion")
			fire(c4, 30000)
			action(env, "Test No Motion")
			fire(c4, 30000)
			assert.same({ "OPENED", "CLOSED", "CLOSED" }, contact(c4))
			env.ReceivedFromProxy(5001, "GET_STATE", {})
			assert.same({ "OPENED", "CLOSED", "CLOSED", "STATE_CLOSED" }, contact(c4))
		end)

		it("puts back Hue's held state after a test during a hold", function()
			local env, c4 = known({ props = { [HOLD] = "10" }, motion = "true" })
			state(env, { motion = "false" })
			action(env, "Test Motion")
			assert.same({ "OPENED" }, contact(c4))
			-- The hold ends during the test: nothing yet, the test's own end puts Hue's state back.
			assert.equal(1, fire(c4, 10000))
			assert.same({ "OPENED" }, contact(c4))
			assert.equal(1, fire(c4, 30000))
			assert.same({ "OPENED", "CLOSED" }, contact(c4))

			-- A hold only the test showed is no hold: Hue's next no motion closes at once.
			action(env, "Test Motion")
			state(env, { motion = "false", reason = "check" })
			assert.same({ "OPENED", "CLOSED", "OPENED", "CLOSED" }, contact(c4))
			assert.equal(0, count_timers(c4, 10000))
		end)
	end)

	describe("conditionals (§2.5)", function()
		it("answers the BOOL conditionals from Online, Enabled and Battery Low", function()
			local env = known()
			state(env, { battery_level = "10", battery_state = "low" })
			assert.is_true(env.TestCondition("BOOL_ONLINE", { VALUE = "True" }))
			assert.is_false(env.TestCondition("BOOL_ONLINE", { VALUE = "False" }))
			assert.is_true(env.TestCondition("BOOL_ENABLED", { VALUE = "True" }))
			assert.is_true(env.TestCondition("BOOL_BATTERY_LOW", { VALUE = "True" }))
			state(env, { online = "false", enabled = "false" })
			assert.is_true(env.TestCondition("BOOL_ONLINE", { VALUE = "False" }))
			assert.is_false(env.TestCondition("BOOL_ENABLED", { VALUE = "True" }))
		end)

		it("compares the NUMBER conditionals in whole numbers with LOGIC", function()
			local env = known()
			state(env, { lux = "123", temperature = "21.53", battery_level = "85", battery_state = "normal" })
			assert.is_true(env.TestCondition("NUMBER_LIGHT_LEVEL", { LOGIC = "GREATER_THAN", VALUE = "100" }))
			assert.is_true(env.TestCondition("NUMBER_LIGHT_LEVEL", { LOGIC = "EQUAL", VALUE = "123" }))
			assert.is_false(env.TestCondition("NUMBER_LIGHT_LEVEL", { LOGIC = "LESS_THAN", VALUE = "123" }))
			assert.is_true(env.TestCondition("NUMBER_LIGHT_LEVEL", { LOGIC = "LESS_THAN_OR_EQUAL", VALUE = "123" }))
			assert.is_true(env.TestCondition("NUMBER_TEMPERATURE_C", { LOGIC = "EQUAL", VALUE = "22" }))
			assert.is_true(env.TestCondition("NUMBER_TEMPERATURE_C", { LOGIC = "NOT_EQUAL", VALUE = "21" }))
			assert.is_true(env.TestCondition("NUMBER_TEMPERATURE_C", { LOGIC = "GREATER_THAN_OR_EQUAL", VALUE = "22" }))
			assert.is_true(env.TestCondition("NUMBER_BATTERY_LEVEL", { LOGIC = "LESS_THAN", VALUE = "90" }))
			assert.is_false(env.TestCondition("NUMBER_BATTERY_LEVEL", { LOGIC = "SOMETHING", VALUE = "90" }))
			assert.is_false(env.TestCondition("NUMBER_BATTERY_LEVEL", { LOGIC = "EQUAL" }))
			assert.is_false(env.TestCondition("NOT_OURS", {}))
		end)
	end)
end)
