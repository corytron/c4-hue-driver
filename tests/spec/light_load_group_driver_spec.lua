-- Control4 load groups on the Hue Light driver (#435,
-- docs/load-groups-design.md §6.1 to §6.6, §8.1 part D): the real
-- src/hue_light/driver.lua on the fake runtime, with a bridge standing
-- behind binding 1 as device 15, as light_driver_spec.lua drives it. The
-- light's group commands arrive through its light_v2 proxy (5001); what it
-- sends the bridge (HUE_LOAD_GROUPS, HUE_SET and HUE_DIM with `group`) and
-- tells the proxy (CHANGING, CHANGED, the Load Groups row) is asserted.
--
-- The light's own stops (a keypad press, SET_BRIGHTNESS_STOP) go out
-- untagged, also for a ramp or hold a group started (D11: a lamp's own
-- request is sent alone, ahead of anything in a batch); only the group's
-- own GROUP_STOP_RAMP is tagged (D12, D5).

local fake = require("helpers.fake_c4")
local log = require("common.log")
local link = require("common.link")

local BRIDGE_ID = 15
local LIGHT_ID = 2001
local GROUP, OTHER = "1234", "5678"
local SETUP_READ_MS = 3000 -- the read of the proxy's presets after late init (#427 D19)

-- The bulb HUE_CONFIGURE describes, every value a string as Director hands it over.
local CONFIGURE = { rid = "l1", name = "Desk", model = "Hue color lamp", has_color = "true", has_cct = "true",
	mirek_min = "153", mirek_max = "500", min_dim = "0.2" }

local ZONE_RID = "b90ea7b4-aaaa-4bbb-8ccc-ddddeeeeffff"
local ZONE = { rid = ZONE_RID, kind = "group", group_type = "zone", name = "Bedside Lights", light_count = "2",
	model = "Hue zone", has_color = "true", has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }

local function source(path)
	local f = assert(io.open(path, "r"))
	local text = f:read("*a")
	f:close()
	return text
end

-- opts.bind=false leaves the light unbound; opts.rid persists a rid first;
-- opts.persist holds more persisted values. The read of the proxy's presets
-- runs at once (it learns nothing).
local function load_light(opts)
	opts = opts or {}
	local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
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
	assert(c4.fire_timers_of(SETUP_READ_MS) == 1, "late init arms the read of the proxy's presets")
	return env, c4
end

local function configure(env, base, extra)
	local params = {}
	for k, v in pairs(base or CONFIGURE) do params[k] = v end
	for k, v in pairs(extra or {}) do params[k] = v end
	env.ExecuteCommand("HUE_CONFIGURE", params)
end

-- A configured light the bridge reports on at `level` (0: off, Hue keeping
-- 70), its recordings cleared. opts.zone makes it a zone light.
local function light(level, opts)
	opts = opts or {}
	local rid = opts.zone and ZONE_RID or "l1"
	local env, c4 = load_light({ rid = rid, bind = opts.bind })
	configure(env, opts.zone and ZONE or CONFIGURE)
	local on = level > 0
	env.ExecuteCommand("HUE_STATE", { rid = rid, on = tostring(on), brightness = on and tostring(level) or "70",
		mirek = "370", color_mode = "ct", online = "true", reason = "hello" })
	c4.calls, c4.sent = {}, {}
	return env, c4
end

local function proxy(env, command, params)
	env.ReceivedFromProxy(5001, command, params or {})
end

-- A group command with its GROUP ID (underscore spellings, as the house's
-- proxy spells SET_COLOR_TARGET's; the module reads both, A-keys).
local function group(env, command, id, params)
	local p = { GROUP_ID = id }
	for k, v in pairs(params or {}) do p[k] = v end
	proxy(env, command, p)
end

local function notifies(c4, command)
	local out = {}
	for _, args in ipairs(c4.calls_to("SendToProxy")) do
		if args[1] == 5001 and args[2] == command then out[#out + 1] = args[3] end
	end
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

-- Every LIGHT_BRIGHTNESS_CURRENT the proxy heard as CHANGED, in order.
local function levels(c4)
	local out = {}
	for _, p in ipairs(notifies(c4, "LIGHT_BRIGHTNESS_CHANGED")) do out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT end
	return out
end

-- Params of every SendToDevice with that command, in order.
local function sent(c4, command)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.command == command then out[#out + 1] = m.params end
	end
	return out
end

-- The commands sent, in order; the dev build's HUE_LOG lines left out.
local function commands(c4)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.command ~= "HUE_LOG" then out[#out + 1] = m.command end
	end
	return out
end

local function button(env, id, act)
	proxy(env, "BUTTON_ACTION", { BUTTON_ID = tostring(id), ACTION = act })
end

-- The armed timers of `delay` ms (repeating ones included).
local function armed(c4, delay)
	local n = 0
	for _, t in ipairs(c4.active_timers()) do
		if t.delay == delay then n = n + 1 end
	end
	return n
end

describe("Hue Light driver in Control4 load groups (#435)", function()
	local lines

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = function() end
	end)

	local function logged(text)
		for _, line in ipairs(lines) do
			if line:find(text, 1, true) then return line end
		end
		return nil
	end

	describe("driver.xml (§6.1, D1)", function()
		local xml = source("src/hue_light/driver.xml")

		it("declares load_group_support True, once", function()
			assert.equal(1, select(2, xml:gsub("<load_group_support>True</load_group_support>", "")))
			assert.is_nil(xml:find("<load_group_support>False", 1, true))
		end)

		it("has a read-only Load Groups row right after Status", function()
			local names, readonly = {}, {}
			for body in xml:gmatch("<property>(.-)</property>") do
				local name = body:match("<name>(.-)</name>")
				names[#names + 1] = name
				readonly[name] = body:match("<readonly>(.-)</readonly>")
				if name == "Load Groups" then
					assert.equal("STRING", body:match("<type>(.-)</type>"))
				end
			end
			local at
			for i, name in ipairs(names) do
				if name == "Load Groups" then at = i end
			end
			assert.truthy(at, "a Load Groups property")
			assert.equal("Status", names[at - 1])
			assert.equal("true", readonly["Load Groups"])
		end)

		it("keeps the Hue Scene driver out (D2)", function()
			assert.truthy(source("src/hue_scene/driver.xml"):find("<load_group_support>False</load_group_support>", 1, true))
		end)
	end)

	describe("memberships (D6, §6.2 to §6.4)", function()
		it("JOIN_GROUP persists, writes Load Groups and sends HUE_LOAD_GROUPS (E1)", function()
			local env, c4 = light(40)
			fake.project.devices[1234] = { name = "Kitchen Group" }
			group(env, "JOIN_GROUP", GROUP, { KEEP_SYNC = "0" })
			assert.same({ [GROUP] = { sync = false } }, c4.persist.hue_load_groups)
			assert.equal("Kitchen Group", env.Properties["Load Groups"])
			assert.same({ { device_id = "2001", rid = "l1", groups = "1234:0" } }, sent(c4, "HUE_LOAD_GROUPS"))
			assert.same({ "HUE_LOAD_GROUPS" }, commands(c4), "nothing else: a join moves no light")
		end)

		it("LEAVE_GROUP removes it the same way (E2); an id the list lacks changes nothing", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP, { KEEP_SYNC = "1" })
			c4.sent = {}
			proxy(env, "LEAVE_GROUP", { ["GROUP ID"] = GROUP })
			assert.same({}, c4.persist.hue_load_groups)
			assert.equal("None", env.Properties["Load Groups"])
			assert.same({ { device_id = "2001", rid = "l1", groups = "none" } }, sent(c4, "HUE_LOAD_GROUPS"))
			c4.sent = {}
			proxy(env, "LEAVE_GROUP", { ["GROUP ID"] = GROUP })
			assert.same({}, c4.sent)
		end)

		it("SET_GROUP_SYNC records the flag and shows it, and never moves the light (E4, D13)", function()
			local env, c4 = light(40)
			fake.project.devices[1234] = { name = "Kitchen Group" }
			group(env, "JOIN_GROUP", GROUP, { KEEP_SYNC = "0" })
			c4.sent, c4.calls = {}, {}
			proxy(env, "SET_GROUP_SYNC", { ["GROUP ID"] = GROUP, ["KEEP SYNC"] = "1" })
			assert.same({ [GROUP] = { sync = true } }, c4.persist.hue_load_groups)
			assert.equal("Kitchen Group (in sync)", env.Properties["Load Groups"])
			assert.same({ "HUE_LOAD_GROUPS" }, commands(c4))
			assert.equal("1234:1", sent(c4, "HUE_LOAD_GROUPS")[1].groups)
			assert.same({}, changing(c4))
		end)

		it("follows every hello with the persisted list, and shows it (A6, E19, E5)", function()
			local env, c4 = load_light({ rid = "l1", persist = { hue_load_groups = {
				[GROUP] = { sync = true }, [OTHER] = { sync = false } } } })
			assert.same({
				{ id = BRIDGE_ID, command = "HUE_HELLO", params = { rid = "l1", device_id = "2001" } },
				{ id = BRIDGE_ID, command = "HUE_LOAD_GROUPS",
					params = { rid = "l1", device_id = "2001", groups = "1234:1,5678:0" } },
			}, c4.sent)
			assert.equal("device 1234 (not found) (in sync), device 5678 (not found)", env.Properties["Load Groups"])
			-- A binding made again greets again; the list follows, and the row
			-- reads the names as they are now (E5).
			fake.project.devices[1234] = { name = "Kitchen Group" }
			c4.sent = {}
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			env.OnBindingChanged(1, "HUE_BRIDGE", true, BRIDGE_ID, 1)
			assert.same({ "HUE_HELLO", "HUE_LOAD_GROUPS" }, commands(c4))
			assert.equal("Kitchen Group (in sync), device 5678 (not found)", env.Properties["Load Groups"])
		end)

		it("drops a persisted value that is no list of load groups at late init (L83)", function()
			local env, c4 = load_light({ rid = "l1", persist = { hue_load_groups = "1234" } })
			assert.equal("None", env.Properties["Load Groups"])
			assert.same({}, c4.persist.hue_load_groups)
			assert.equal("none", sent(c4, "HUE_LOAD_GROUPS")[1].groups)
		end)

		it("a zone or room light says kind group (§6.3)", function()
			local env, c4 = light(40, { zone = true })
			group(env, "JOIN_GROUP", GROUP, { KEEP_SYNC = "0" })
			assert.same({ { device_id = "2001", rid = ZONE_RID, kind = "group", groups = "1234:0" } },
				sent(c4, "HUE_LOAD_GROUPS"))
		end)

		it("a group command before late init waits for it (§6.2, after_late_init)", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c4.persist.hue_rid = "l1"
			group(env, "JOIN_GROUP", GROUP, { KEEP_SYNC = "1" })
			assert.equal(0, #c4.calls_to("UpdateProperty"))
			assert.equal(0, #c4.calls_to("PersistSetValue"))
			assert.same({}, c4.sent)
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ [GROUP] = { sync = true } }, c4.persist.hue_load_groups)
			assert.equal("device 1234 (not found) (in sync)", env.Properties["Load Groups"])
			local all = commands(c4)
			assert.equal("HUE_HELLO", all[#all - 1])
			assert.equal("HUE_LOAD_GROUPS", all[#all])
			assert.equal("1234:1", c4.sent[#c4.sent].params.groups)
		end)

		it("logs the first arrival of each command with its parameters once, while Debug Mode shows it (D16)", function()
			local env = light(40)
			group(env, "JOIN_GROUP", OTHER, { KEEP_SYNC = "0" }) -- Debug Mode off: not marked
			log.set_debug(true)
			proxy(env, "JOIN_GROUP", { ["GROUP ID"] = GROUP, ["KEEP SYNC"] = "1" })
			group(env, "JOIN_GROUP", "9999", { KEEP_SYNC = "0" })
			local n = 0
			for _, line in ipairs(lines) do
				if line:find("first JOIN_GROUP this run", 1, true) then n = n + 1 end
			end
			assert.equal(1, n)
			assert.truthy(logged('first JOIN_GROUP this run: GROUP ID="1234", KEEP SYNC="1"'))
		end)
	end)

	describe("level commands (D3, D4, D10)", function()
		it("GROUP_SET_LEVEL sends CHANGING and a HUE_SET with the group at rate 0, not urgent", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			c4.sent = {}
			group(env, "GROUP_SET_LEVEL", GROUP, { LEVEL = "70" })
			assert.same({ { 40, 70, 0 } }, changing(c4))
			assert.same({ { rid = "l1", on = "true", brightness = "70", rate = "0", group = GROUP } }, sent(c4, "HUE_SET"))
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "70" })
			assert.same({ 70 }, levels(c4))
		end)

		it("SET_GROUP_LEVEL, the reference's other spelling, is the same command", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			c4.sent = {}
			proxy(env, "SET_GROUP_LEVEL", { ["GROUP ID"] = GROUP, LEVEL = "0" })
			assert.same({ { rid = "l1", on = "false", rate = "0", group = GROUP } }, sent(c4, "HUE_SET"))
		end)

		it("learns an unknown GROUP ID and announces it before the command's own request (D6)", function()
			local env, c4 = light(40)
			group(env, "GROUP_SET_LEVEL", GROUP, { LEVEL = "70" })
			assert.same({ "HUE_LOAD_GROUPS", "HUE_SET" }, commands(c4))
			assert.equal("1234:0", c4.sent[1].params.groups)
			assert.same({ [GROUP] = { sync = false } }, c4.persist.hue_load_groups)
		end)

		it("takes the proxy's default brightness rate where none is given (#430 D8)", function()
			local env, c4 = light(40)
			proxy(env, "UPDATE_BRIGHTNESS_RATE_DEFAULT", { RATE = "750" })
			group(env, "JOIN_GROUP", GROUP)
			c4.sent = {}
			group(env, "GROUP_SET_LEVEL", GROUP, { LEVEL = "70" })
			group(env, "GROUP_RAMP_TO_LEVEL", GROUP, { LEVEL = "20" })
			local all = sent(c4, "HUE_SET")
			assert.equal("750", all[1].rate)
			assert.equal("750", all[2].rate)
			assert.same({ 40, 70, 750 }, changing(c4)[1])
		end)

		it("goes to the level it names from off: no On Mode, no Default On Brightness (D4)", function()
			local env, c4 = light(0)
			proxy(env, "SET_PRESET_LEVEL", { LEVEL = "60" })
			group(env, "JOIN_GROUP", GROUP)
			c4.sent, c4.calls = {}, {}
			group(env, "GROUP_SET_LEVEL", GROUP, { LEVEL = "30" })
			assert.same({ { 0, 30, 0 } }, changing(c4))
			local set = sent(c4, "HUE_SET")[1]
			assert.equal("30", set.brightness)
			assert.equal("true", set.on)
			assert.equal(GROUP, set.group)
		end)

		it("GROUP_RAMP_TO_LEVEL is a ramp: reports held back, a keypad press stops it untagged (D11, D12)", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			c4.sent = {}
			group(env, "GROUP_RAMP_TO_LEVEL", GROUP, { LEVEL = "100", TIME = "2000" })
			assert.same({ { rid = "l1", on = "true", brightness = "100", rate = "2000", group = GROUP } },
				sent(c4, "HUE_SET"))
			assert.same({ { 40, 100, 2000 } }, changing(c4))
			-- Hue reports the target as the transition starts: held back (#421 D10).
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" })
			assert.same({}, levels(c4))
			c4.advance(1000)
			c4.sent = {}
			button(env, 1, "1") -- the light's own keypad, mid-ramp
			assert.same({ { rid = "l1", on = "true", brightness = "70", rate = "1000", urgent = "true" } },
				sent(c4, "HUE_SET"), "the estimate, with no group tag")
			assert.same({ 70 }, levels(c4))
			button(env, 1, "2")
			assert.equal(1, #sent(c4, "HUE_SET"), "the click is swallowed")
		end)

		it("its group's GROUP_STOP_RAMP stops the ramp, tagged (D12)", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			group(env, "GROUP_RAMP_TO_LEVEL", GROUP, { LEVEL = "100", TIME = "2000" })
			c4.advance(1000)
			c4.sent = {}
			group(env, "GROUP_STOP_RAMP", GROUP)
			assert.same({ { rid = "l1", on = "true", brightness = "70", rate = "1000", urgent = "true", group = GROUP } },
				sent(c4, "HUE_SET"))
			assert.same({ 70 }, levels(c4))
		end)

		it("another group's GROUP_STOP_RAMP leaves the ramp running; with nothing running it reports the level", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			group(env, "JOIN_GROUP", OTHER)
			group(env, "GROUP_RAMP_TO_LEVEL", GROUP, { LEVEL = "100", TIME = "2000" })
			c4.advance(500)
			c4.sent, c4.calls = {}, {}
			group(env, "GROUP_STOP_RAMP", OTHER)
			assert.same({}, c4.sent)
			assert.same({}, levels(c4))
			c4.advance(2500) -- the ramp and its fallback run out: the target is assumed
			assert.same({ 100 }, levels(c4))
			c4.calls = {}
			group(env, "GROUP_STOP_RAMP", GROUP)
			assert.same({}, c4.sent)
			assert.same({ 100 }, levels(c4), "CHANGED with the cache, as SET_BRIGHTNESS_STOP with nothing running")
		end)

		it("a light that cannot be driven drops a group command with its Status; the id is still learnt (L56)", function()
			local env, c4 = light(40)
			local since = os.time() - 120
			env.ExecuteCommand("HUE_BRIDGE_LINK", { state = "offline", reason = "not_answering", since = tostring(since) })
			c4.sent, c4.calls = {}, {}
			log.set_debug(true)
			group(env, "GROUP_SET_LEVEL", GROUP, { LEVEL = "70" })
			group(env, "GROUP_RAMP_TO_LEVEL", GROUP, { LEVEL = "70", TIME = "1000" })
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			assert.same({ "HUE_LOAD_GROUPS" }, commands(c4), "learnt and announced; no request")
			assert.same({}, changing(c4))
			local not_answering = "Hue Bridge not answering since " .. link.clock(since)
			assert.equal(not_answering, env.Properties["Status"])
			assert.truthy(logged("brightness target dropped: " .. not_answering))
			assert.truthy(logged("GROUP_START_RAMP dropped: " .. not_answering))
			assert.is_true(c4.persist.hue_load_groups[GROUP] ~= nil)
		end)

		it("an unbound light sends nothing at all, and still keeps and shows the group", function()
			local env, c4 = light(40, { bind = false })
			group(env, "GROUP_SET_LEVEL", GROUP, { LEVEL = "70" })
			assert.same({}, c4.sent)
			assert.equal("device 1234 (not found)", env.Properties["Load Groups"])
			assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
		end)
	end)

	describe("the group hold (D3, D9, D12)", function()
		it("up while on dims with the group's RATE as the whole range, tagged, CHANGING toward 100 (L14)", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			c4.sent = {}
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			assert.same({ { rid = "l1", direction = "up", duration = "4000", group = GROUP } }, sent(c4, "HUE_DIM"))
			assert.same({ { 40, 100, 2400 } }, changing(c4), "60 points of a 4000 ms range")
		end)

		it("down while on without RATE takes the Hold Rate Down, toward 1", function()
			local env, c4 = light(40)
			proxy(env, "SET_HOLD_RATE_DOWN", { RATE = "8000" })
			group(env, "JOIN_GROUP", GROUP)
			c4.sent, c4.calls = {}, {}
			proxy(env, "GROUP_START_RAMP", { ["GROUP ID"] = GROUP, ["RAMP UP"] = "0" })
			assert.same({ { rid = "l1", direction = "down", duration = "8000", group = GROUP } }, sent(c4, "HUE_DIM"))
			assert.same({ { 40, 1, 3120 } }, changing(c4))
		end)

		it("up from off turns on at 1 %, tagged, and dims up 600 ms later (L43)", function()
			local env, c4 = light(0)
			group(env, "JOIN_GROUP", GROUP)
			c4.sent = {}
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "3000" })
			local on = sent(c4, "HUE_SET")
			assert.equal(1, #on)
			assert.equal("true", on[1].on)
			assert.equal("0", on[1].rate)
			assert.equal(GROUP, on[1].group)
			assert.same({}, sent(c4, "HUE_DIM"))
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "1" })
			c4.advance(599)
			assert.same({}, sent(c4, "HUE_DIM"))
			c4.advance(1)
			assert.same({ { rid = "l1", direction = "up", duration = "3000", group = GROUP } }, sent(c4, "HUE_DIM"))
		end)

		it("down from off does nothing (L43)", function()
			local env, c4 = light(0)
			group(env, "JOIN_GROUP", GROUP)
			c4.sent, c4.calls = {}, {}
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "0" })
			assert.same({}, c4.sent)
			assert.same({}, changing(c4))
		end)

		it("its GROUP_STOP_RAMP stops it at the estimate, tagged; the estimate is assumed without a report", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			c4.advance(1000) -- ten ticks of 2.5 points
			c4.sent, c4.calls = {}, {}
			group(env, "GROUP_STOP_RAMP", GROUP)
			assert.same({ { rid = "l1", direction = "stop", level = "65", group = GROUP } }, sent(c4, "HUE_DIM"))
			c4.advance(1000)
			assert.same({ 65 }, levels(c4))
			assert.equal(0, armed(c4, 100), "the tick stopped")
			assert.equal(0, armed(c4, 5000), "the end-of-range timer too")
		end)

		it("another group's GROUP_STOP_RAMP leaves it running", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			group(env, "JOIN_GROUP", OTHER)
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			c4.sent, c4.calls = {}, {}
			group(env, "GROUP_STOP_RAMP", OTHER)
			assert.same({}, c4.sent)
			assert.same({}, levels(c4))
			c4.advance(1000)
			group(env, "GROUP_STOP_RAMP", GROUP)
			assert.same({ { rid = "l1", direction = "stop", level = "65", group = GROUP } }, sent(c4, "HUE_DIM"))
		end)

		it("ends by itself after the whole range plus the fallback when its stop never comes (E10)", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			c4.advance(2500)
			env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = "100" }) -- the end of the range
			c4.sent, c4.calls = {}, {}
			c4.advance(2499)
			assert.same({}, levels(c4))
			c4.advance(1)
			assert.same({ 100 }, levels(c4), "the proxy hears the cache")
			assert.same({}, c4.sent, "nothing to stop: Hue is at the end of the range")
			-- Nothing runs any more: a press is a tap again, not a stop.
			button(env, 1, "1")
			button(env, 1, "2")
			assert.equal("false", sent(c4, "HUE_SET")[1].on, "the bottom tap turns it off")
		end)

		it("the light's own keypad press stops it untagged and swallows its click (D11, D12)", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			c4.advance(1000)
			c4.sent = {}
			button(env, 0, "1")
			assert.same({ { rid = "l1", direction = "stop", level = "65" } }, sent(c4, "HUE_DIM"))
			button(env, 0, "2")
			assert.same({}, sent(c4, "HUE_SET"), "the click is swallowed")
			-- The group's own stop, later, finds nothing of its own and leaves
			-- the light's stop to close its CHANGING with the bridge's word.
			c4.calls = {}
			group(env, "GROUP_STOP_RAMP", GROUP)
			assert.same({ { rid = "l1", direction = "stop", level = "65" } }, sent(c4, "HUE_DIM"))
			assert.same({}, levels(c4))
			env.ExecuteCommand("HUE_STATE", { rid = "l1", brightness = "64.6" })
			assert.same({ 65 }, levels(c4))
		end)

		it("SET_BRIGHTNESS_STOP and STOP_SCENE_RAMP stop it untagged", function()
			for _, command in ipairs({ "SET_BRIGHTNESS_STOP", "STOP_SCENE_RAMP" }) do
				local env, c4 = light(40)
				group(env, "JOIN_GROUP", GROUP)
				group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
				c4.advance(1000)
				c4.sent = {}
				proxy(env, command)
				assert.same({ { rid = "l1", direction = "stop", level = "65" } }, sent(c4, "HUE_DIM"), command)
			end
		end)

		it("a brightness target replaces it without a stop, its CHANGING from the estimate (#421 D11)", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			c4.advance(1000)
			c4.sent, c4.calls = {}, {}
			proxy(env, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "20", RATE = "0" })
			assert.same({ { 65, 20, 0 } }, changing(c4))
			assert.same({}, sent(c4, "HUE_DIM"))
			assert.equal(0, armed(c4, 100), "its tick is gone")
			c4.sent = {}
			button(env, 1, "1")
			button(env, 1, "2")
			assert.equal("false", sent(c4, "HUE_SET")[1].on, "no hold left for a press to stop: a tap")
		end)

		it("a keypad hold ends it: the keypad's dim, untagged, from the group's estimate (§6.6)", function()
			local env, c4 = light(40)
			proxy(env, "SET_PRESET_LEVEL", { LEVEL = "40" })
			group(env, "JOIN_GROUP", GROUP)
			button(env, 0, "1") -- a top tap at the preset: no ramp to stop later
			button(env, 0, "2")
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			c4.advance(300)
			c4.sent, c4.calls = {}, {}
			button(env, 0, "1") -- inside the double-tap window: it stops nothing
			assert.same({}, c4.sent)
			c4.advance(400) -- the hold time: 40 + 7 x 2.5
			assert.same({ { rid = "l1", direction = "up", duration = "5000" } }, sent(c4, "HUE_DIM"))
			assert.same({ { 58, 100, 2100 } }, changing(c4))
			button(env, 0, "0")
			assert.same({ rid = "l1", direction = "stop", level = "58" }, sent(c4, "HUE_DIM")[2],
				"the keypad's own stop (the tick has not moved yet)")
			c4.sent = {}
			group(env, "GROUP_STOP_RAMP", GROUP)
			assert.same({}, c4.sent, "the group hold was over: nothing tagged follows")
		end)

		it("a new GROUP_START_RAMP replaces the running one from its estimate, without a stop", function()
			local env, c4 = light(40)
			group(env, "JOIN_GROUP", GROUP)
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			c4.advance(1000)
			c4.sent, c4.calls = {}, {}
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "0", RATE = "4000" })
			assert.same({ { rid = "l1", direction = "down", duration = "4000", group = GROUP } }, sent(c4, "HUE_DIM"))
			assert.same({ { 65, 1, 2560 } }, changing(c4))
		end)

		it("ends on unbind and when the driver is destroyed, its timers with it", function()
			local env, c4 = light(40)
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			assert.equal(1, armed(c4, 100))
			assert.equal(1, armed(c4, 5000))
			c4.bindings = {}
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			assert.equal(0, armed(c4, 100))
			assert.equal(0, armed(c4, 5000))

			env, c4 = light(40)
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "1", RATE = "4000" })
			env.OnDriverDestroyed()
			assert.equal(0, armed(c4, 100))
			assert.equal(0, armed(c4, 5000))
		end)
	end)

	describe("a zone or room light (D2)", function()
		it("takes the same commands, its requests for the zone's rid, tagged", function()
			local env, c4 = light(40, { zone = true })
			group(env, "JOIN_GROUP", GROUP)
			c4.sent = {}
			group(env, "GROUP_SET_LEVEL", GROUP, { LEVEL = "70" })
			assert.same({ { rid = ZONE_RID, on = "true", brightness = "70", rate = "0", group = GROUP } },
				sent(c4, "HUE_SET"))
			env.ExecuteCommand("HUE_STATE", { rid = ZONE_RID, on = "true", brightness = "70" })
			c4.sent = {}
			group(env, "GROUP_START_RAMP", GROUP, { RAMP_UP = "0", RATE = "5000" })
			assert.same({ { rid = ZONE_RID, direction = "down", duration = "5000", group = GROUP } }, sent(c4, "HUE_DIM"))
			c4.advance(1000)
			group(env, "GROUP_STOP_RAMP", GROUP)
			assert.same({ rid = ZONE_RID, direction = "stop", level = "50", group = GROUP }, sent(c4, "HUE_DIM")[2])
		end)
	end)
end)
