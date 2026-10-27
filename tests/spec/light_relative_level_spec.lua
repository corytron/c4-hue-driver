-- Raise Level By and Restore Saved Level on the Hue Light driver
-- (docs/relative-level-design.md, #297), against the fake runtime with a
-- bridge standing behind binding 1 as device 15. A programming command
-- reaches ExecuteCommand under its <name>, spaces and all, with the
-- parameters keyed by their names [verified: API 5/_1; FUND 12.3/_1]; the
-- specs send every value as a string.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BRIDGE_ID = 15
local LIGHT_ID = 2001
local ZONE_RID = "b90ea7b4-aaaa-4bbb-8ccc-ddddeeeeffff"

-- The bulb HUE_CONFIGURE describes, every value a string as Director hands it over.
local CONFIGURE = { rid = "l1", name = "Desk", model = "Hue color lamp", has_color = "true", has_cct = "true",
	mirek_min = "153", mirek_max = "500", min_dim = "0.2" }

-- A zone device's configure (docs/zone-light-design.md §5).
local ZONE = { rid = ZONE_RID, kind = "group", group_type = "zone", name = "Bedside Lights", light_count = "2",
	model = "Hue zone", has_color = "true", has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }

local function quiet()
	log.sink = function() end
end

-- A light late-inited with its rid persisted (opts.rid, default "l1"; false
-- for none) and bound to the bridge (unless opts.bind is false). `persist`
-- is what the database holds before the start: for a restart, what the
-- last run left.
local function load_light(persist, opts)
	opts = opts or {}
	local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
	if opts.bind ~= false then
		c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
	end
	if opts.rid ~= false then
		c4.persist.hue_rid = opts.rid or "l1"
	end
	for k, v in pairs(persist or {}) do
		c4.persist[k] = v
	end
	env.OnDriverLateInit("DIT_STARTUP")
	return env, c4
end

local function configure(env, extra, base)
	local params = {}
	for k, v in pairs(base or CONFIGURE) do params[k] = v end
	for k, v in pairs(extra or {}) do params[k] = v end
	env.ExecuteCommand("HUE_CONFIGURE", params)
end

-- The bridge reports the light at `level` %, 0 for off (Hue keeps the
-- brightness of a light that is off; here 40).
local function report(env, level, rid)
	if level == 0 then
		env.ExecuteCommand("HUE_STATE", { rid = rid or "l1", on = "false", brightness = "40" })
	else
		env.ExecuteCommand("HUE_STATE", { rid = rid or "l1", on = "true", brightness = tostring(level) })
	end
end

-- A configured, online light the bridge reports at `level` (0 off), with
-- the recorded calls and messages cleared.
local function light_at(level, persist)
	local env, c4 = load_light(persist)
	configure(env)
	env.ExecuteCommand("HUE_STATE", { rid = "l1", online = "true", reason = "hello" })
	report(env, level)
	c4.calls, c4.sent = {}, {}
	return env, c4
end

-- The commands as programming sends them; a nil leaves the parameter out.
local function raise(env, points, ramp)
	env.ExecuteCommand("Raise Level By", { Points = points, ["Ramp (ms)"] = ramp })
end

local function restore(env, ramp)
	env.ExecuteCommand("Restore Saved Level", { ["Ramp (ms)"] = ramp })
end

-- Params of every HUE_SET sent, in order.
local function sets(c4)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.command == "HUE_SET" then out[#out + 1] = m.params end
	end
	return out
end

-- Every SendToDevice but the log lines a dev build forwards (HUE_LOG, which
-- the spec's build is), as { id, command, params }, in order.
local function commands(c4)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.command ~= "HUE_LOG" then out[#out + 1] = m end
	end
	return out
end

-- Params of every SendToProxy to the proxy binding (5001) with that command, in order.
local function notifies(c4, command)
	local out = {}
	for _, args in ipairs(c4.calls_to("SendToProxy")) do
		if args[1] == 5001 and args[2] == command then out[#out + 1] = args[3] end
	end
	return out
end

-- The delays of the timers still armed.
local function delays(c4)
	local out = {}
	for _, timer in ipairs(c4.active_timers()) do out[#out + 1] = timer.delay end
	return out
end

-- What the database holds for the saved level, as { level, target }.
local function stored(c4)
	local value = c4.persist.saved_level
	return value and { value.level, value.target } or nil
end

-- From here on SendToDevice raises for HUE_SET, as a failing Director call
-- would (common/device.lua send).
local function failing(c4)
	local original = c4.SendToDevice
	c4.SendToDevice = function(self, id, command, ...)
		if command == "HUE_SET" then
			error("Director says no")
		end
		return original(self, id, command, ...)
	end
end

describe("Hue Light: Raise Level By and Restore Saved Level (#297)", function()
	before_each(quiet)

	describe("driver.xml", function()
		local xml

		setup(function()
			local file = assert(io.open("src/hue_light/driver.xml"))
			xml = file:read("*a")
			file:close()
		end)

		-- The body of the <command> named `name` in <config><commands>, or nil.
		local function command(name)
			local config = assert(xml:match("<config>(.-)</config>"))
			local block = assert(config:match("<commands>(.-)</commands>"), "a <commands> block in <config>")
			for body in block:gmatch("<command>(.-)</command>") do
				if body:match("<name>(.-)</name>") == name then return body end
			end
			return nil
		end

		-- A command body's parameters by name: { type, minimum, maximum, default }.
		local function params_of(body)
			local out = {}
			for p in body:gmatch("<param>(.-)</param>") do
				out[p:match("<name>(.-)</name>")] = { type = p:match("<type>(.-)</type>"),
					minimum = p:match("<minimum>(.-)</minimum>"), maximum = p:match("<maximum>(.-)</maximum>"),
					default = p:match("<default>(.-)</default>") }
			end
			return out
		end

		local RAMP = { type = "RANGED_INTEGER", minimum = "0", maximum = "60000", default = "1000" }

		it("declares Raise Level By with Points 1 to 100 (30) and Ramp (ms) 0 to 60000 (1000), sorted first", function()
			local body = assert(command("Raise Level By"))
			assert.same({ Points = { type = "RANGED_INTEGER", minimum = "1", maximum = "100", default = "30" },
				["Ramp (ms)"] = RAMP }, params_of(body))
			assert.equal("0", body:match("<sort_order>(.-)</sort_order>"))
			assert.equal("Raise NAME by PARAM1 points over PARAM2 ms", body:match("<description>(.-)</description>"))
		end)

		it("declares Restore Saved Level with Ramp (ms) alone, sorted second", function()
			local body = assert(command("Restore Saved Level"))
			assert.same({ ["Ramp (ms)"] = RAMP }, params_of(body))
			assert.equal("1", body:match("<sort_order>(.-)</sort_order>"))
			assert.equal("Restore NAME to its saved level over PARAM1 ms", body:match("<description>(.-)</description>"))
		end)
	end)

	describe("Raise Level By", function()
		it("raises a light by the points over the ramp, saving the level it found and the time", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local env, c4 = light_at(40)
			local before = os.time()
			raise(env, "30", "1000")
			assert.same({ { rid = "l1", on = "true", brightness = "70", rate = "1000" } }, sets(c4))
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40, LIGHT_BRIGHTNESS_TARGET = 70, RATE = 1000 } },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same({ 40, 70 }, stored(c4))
			local at = c4.persist.saved_level.at
			assert.is_true(at >= before and at <= os.time(), "the time of the save")
			assert.equal("Raised from 40 % to 70 % (saved 40 %)", fake.last_action(env))
			assert.equal("Hue Light: Raised from 40 % to 70 % (saved 40 %)", lines[#lines], "and a log line")
		end)

		it("sends exactly what the slider sends for that level and ramp", function()
			local env, c4 = light_at(40)
			raise(env, "30", "1500")
			local slider_env, slider = light_at(40)
			slider_env.ReceivedFromProxy(5001, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "70", RATE = "1500" })
			assert.same(commands(slider), commands(c4))
			assert.equal(1, #commands(c4))
			assert.same(notifies(slider, "LIGHT_BRIGHTNESS_CHANGING"), notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.same(delays(slider), delays(c4), "the same fallback")
			assert.is_not_nil(env)
		end)

		it("raises a light that is off from 0, saving off", function()
			local env, c4 = light_at(0)
			raise(env, "30", "1000")
			assert.same({ { rid = "l1", on = "true", brightness = "30", rate = "1000" } }, sets(c4))
			assert.same({ 0, 30 }, stored(c4))
			assert.equal("Raised from off to 30 % (saved off)", fake.last_action(env))
		end)

		it("caps the level at 100 and says so, the first time and again", function()
			local env, c4 = light_at(80)
			raise(env, "30", "1000")
			assert.equal("100", sets(c4)[1].brightness)
			assert.same({ 80, 100 }, stored(c4))
			assert.equal("Raised from 80 % to 100 % (capped; saved 80 %)", fake.last_action(env))
			raise(env, "30", "1000")
			assert.equal("100", sets(c4)[2].brightness)
			assert.equal("Raised from 80 % to 100 % again (capped; saved at "
				.. os.date("%H:%M", c4.persist.saved_level.at) .. ")", fake.last_action(env))
		end)

		it("raises from the saved level again on a second raise, so the light never climbs", function()
			local env, c4 = light_at(40)
			raise(env, "30", "1000")
			report(env, 70)
			local first = c4.persist.saved_level
			c4.calls = {}
			raise(env, "30", "1000")
			assert.same({ "70", "70" }, { sets(c4)[1].brightness, sets(c4)[2].brightness })
			assert.equal(first, c4.persist.saved_level, "the same level, target and time")
			assert.equal(0, #c4.calls_to("PersistSetValue"), "nothing written again")
			assert.equal("Raised from 40 % to 70 % again (saved at " .. os.date("%H:%M", first.at) .. ")",
				fake.last_action(env))

			-- Other points: the target follows them from the saved level, which
			-- keeps its time.
			raise(env, "10", "1000")
			assert.equal("50", sets(c4)[3].brightness)
			assert.same({ level = 40, target = 50, at = first.at }, c4.persist.saved_level)
		end)

		it("starts over from a level someone set by hand since the raise, so a raise never lowers it", function()
			local env, c4 = light_at(40)
			raise(env, "30", "1000")
			report(env, 70)
			report(env, 90) -- turned up by hand while raised
			raise(env, "30", "1000")
			assert.equal("100", sets(c4)[2].brightness)
			assert.same(90, c4.persist.saved_level.level)
			assert.truthy(fake.last_action(env):find("changed since the last raise; 40 % no longer kept", 1, true),
				fake.last_action(env))
		end)

		it("takes Points 30 and Ramp 1000 ms when programming sends no value, and rounds a fraction", function()
			local env, c4 = light_at(40)
			raise(env)
			assert.same({ rid = "l1", on = "true", brightness = "70", rate = "1000" }, sets(c4)[1])
			local env2, c42 = light_at(40)
			raise(env2, "", "")
			assert.same({ rid = "l1", on = "true", brightness = "70", rate = "1000" }, sets(c42)[1])
			local env3, c43 = light_at(40)
			raise(env3, "29.6", "1499.5")
			assert.same({ rid = "l1", on = "true", brightness = "70", rate = "1500" }, sets(c43)[1])
			assert.is_not_nil(env)
		end)

		it("refuses Points or a ramp outside their ranges, sending and saving nothing", function()
			local env, c4 = light_at(40)
			for _, case in ipairs({
				{ "0", nil, "Not raised: Points must be 1 to 100, not 0" },
				{ "101", nil, "Not raised: Points must be 1 to 100, not 101" },
				{ "-30", nil, "Not raised: Points must be 1 to 100, not -30" },
				{ "lots", nil, "Not raised: Points must be 1 to 100, not lots" },
				{ "30", "60001", "Not raised: Ramp (ms) must be 0 to 60000, not 60001" },
				{ "30", "-1", "Not raised: Ramp (ms) must be 0 to 60000, not -1" },
				{ "30", "nan", "Not raised: Ramp (ms) must be 0 to 60000, not nan" },
			}) do
				raise(env, case[1], case[2])
				assert.equal(case[3], fake.last_action(env))
			end
			assert.equal(0, #sets(c4))
			assert.equal(0, #notifies(c4, "LIGHT_BRIGHTNESS_CHANGING"))
			assert.is_nil(c4.persist.saved_level)
		end)

		it("refuses while the bridge has not reported the light's level, saving nothing", function()
			local env, c4 = load_light()
			configure(env)
			c4.calls, c4.sent = {}, {}
			raise(env, "30", "1000")
			assert.equal(0, #sets(c4))
			assert.is_nil(c4.persist.saved_level)
			assert.equal("Not raised: the light's level is not known yet", fake.last_action(env))
		end)

		it("saves nothing when the command never reaches the bridge; the proxy hears the unchanged level", function()
			local env, c4 = light_at(40)
			failing(c4)
			raise(env, "30", "1000")
			assert.same({ { LIGHT_BRIGHTNESS_CURRENT = 40 } }, notifies(c4, "LIGHT_BRIGHTNESS_CHANGED"))
			assert.is_nil(c4.persist.saved_level)
			assert.equal("Not raised: the command did not reach the bridge", fake.last_action(env))
		end)
	end)

	describe("Restore Saved Level", function()
		it("puts a light still at the raised level back to the saved one, and forgets it", function()
			local env, c4 = light_at(40)
			raise(env, "30", "1000")
			report(env, 70)
			restore(env, "1000")
			assert.same({ rid = "l1", on = "true", brightness = "40", rate = "1000" }, sets(c4)[2])
			assert.same({ LIGHT_BRIGHTNESS_CURRENT = 70, LIGHT_BRIGHTNESS_TARGET = 40, RATE = 1000 },
				notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[2])
			assert.is_nil(c4.persist.saved_level)
			assert.equal("Restored to 40 %", fake.last_action(env))

			restore(env, "1000")
			assert.equal(2, #sets(c4), "forgotten: nothing more to do")
			assert.equal("Nothing to restore", fake.last_action(env))
		end)

		it("takes a level within one point of the raised one as unchanged (Hue reports its Zigbee level)", function()
			for _, reported in ipairs({ "69", "69.4", "70.08", "71" }) do
				local env, c4 = light_at(40)
				raise(env, "30", "1000")
				env.ExecuteCommand("HUE_STATE", { rid = "l1", on = "true", brightness = reported })
				restore(env, "1000")
				assert.equal("40", sets(c4)[2] and sets(c4)[2].brightness, reported)
				assert.equal("Restored to 40 %", fake.last_action(env))
			end
		end)

		it("turns a light raised from off back off", function()
			local env, c4 = light_at(0)
			raise(env, "30", "1000")
			report(env, 30)
			restore(env, "1000")
			assert.same({ rid = "l1", on = "false", rate = "1000" }, sets(c4)[2])
			assert.is_nil(c4.persist.saved_level)
			assert.equal("Restored to off", fake.last_action(env))
		end)

		it("leaves a light changed since the raise alone and forgets the saved level", function()
			local env, c4 = light_at(40)
			raise(env, "30", "1000")
			report(env, 55) -- someone dimmed it, in the Hue app or on a keypad
			restore(env, "1000")
			assert.equal(1, #sets(c4), "only the raise")
			assert.is_nil(c4.persist.saved_level)
			assert.equal("Not restored: changed to 55 % since the raise; saved level forgotten", fake.last_action(env))

			restore(env, "1000")
			assert.equal("Nothing to restore", fake.last_action(env))
			-- The next raise starts from the level the light has now.
			raise(env, "30", "1000")
			assert.equal("85", sets(c4)[2].brightness)
			assert.equal("Raised from 55 % to 85 % (saved 55 %)", fake.last_action(env))
		end)

		it("leaves a light changed by more than a point, or turned off, alone", function()
			local env = light_at(40)
			raise(env, "30", "1000")
			report(env, 72)
			restore(env, "1000")
			assert.equal("Not restored: changed to 72 % since the raise; saved level forgotten", fake.last_action(env))

			local c4
			env, c4 = light_at(40)
			raise(env, "30", "1000")
			report(env, 0)
			restore(env, "1000")
			assert.equal(1, #sets(c4))
			assert.is_nil(c4.persist.saved_level)
			assert.equal("Not restored: turned off since the raise; saved level forgotten", fake.last_action(env))
		end)

		it("does nothing with nothing saved", function()
			local env, c4 = light_at(40)
			restore(env, "1000")
			assert.equal(0, #sets(c4))
			assert.equal(0, #c4.calls_to("SendToProxy"))
			assert.equal("Nothing to restore", fake.last_action(env))
		end)

		it("keeps the saved level when it cannot act: level unknown, ramp refused, command lost", function()
			-- Saved before a restart the bridge has not answered yet.
			local env, c4 = load_light({ saved_level = { level = 40, target = 70, at = os.time() } })
			configure(env)
			restore(env, "1000")
			assert.equal("Not restored: the light's level is not known yet (saved 40 % kept)", fake.last_action(env))
			report(env, 70)
			restore(env, "90000")
			assert.equal("Not restored: Ramp (ms) must be 0 to 60000, not 90000 (saved 40 % kept)",
				fake.last_action(env))
			failing(c4)
			restore(env, "1000")
			assert.equal("Not restored: the command did not reach the bridge (saved 40 % kept)", fake.last_action(env))
			assert.same({ 40, 70 }, stored(c4))
		end)

		it("passes the ramp to the bridge, the proxy and the fallback, for a raise and a restore", function()
			local env, c4 = light_at(40)
			raise(env, "30", "2500")
			assert.equal("2500", sets(c4)[1].rate)
			assert.equal(2500, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[1].RATE)
			assert.same({ 3500 }, delays(c4), "the fallback: the ramp plus 1000 ms")
			report(env, 70) -- the bridge confirms: the fallback is settled
			restore(env, "45000")
			assert.equal("45000", sets(c4)[2].rate)
			assert.equal(45000, notifies(c4, "LIGHT_BRIGHTNESS_CHANGING")[2].RATE)
			assert.same({ 46000 }, delays(c4))

			env, c4 = light_at(40)
			raise(env, "30", "0")
			assert.equal("0", sets(c4)[1].rate, "0 is a jump")
		end)
	end)

	describe("across a restart", function()
		it("keeps the saved level and the target: a Restore after it puts the light back", function()
			local env, c4 = light_at(40)
			raise(env, "30", "1000")
			local kept = c4.persist.saved_level

			-- A Director restart or a driver update: a new runtime, the same database.
			local env2, c42 = light_at(70, { saved_level = kept })
			restore(env2, "1000")
			assert.same({ { rid = "l1", on = "true", brightness = "40", rate = "1000" } }, sets(c42))
			assert.is_nil(c42.persist.saved_level)
			assert.equal("Restored to 40 %", fake.last_action(env2))
			assert.is_not_nil(env)
		end)

		it("raises from the level saved before it, also before the bridge has reported", function()
			local at = os.time()
			local env, c4 = load_light({ saved_level = { level = 40, target = 70, at = at } })
			configure(env)
			c4.calls, c4.sent = {}, {}
			raise(env, "30", "1000")
			assert.equal("70", sets(c4)[1].brightness)
			assert.equal("Raised from 40 % to 70 % again (saved at " .. os.date("%H:%M", at) .. ")", fake.last_action(env))
		end)

		it("names the day of a level saved on another day, and no time when none was stored", function()
			local at = os.time() - 3 * 86400
			local env = light_at(70, { saved_level = { level = 40, target = 70, at = at } })
			raise(env, "30", "1000")
			assert.equal("Raised from 40 % to 70 % again (saved " .. os.date("%Y-%m-%d %H:%M", at) .. ")",
				fake.last_action(env))
			env = light_at(70, { saved_level = { level = 40, target = 70 } })
			raise(env, "30", "1000")
			assert.equal("Raised from 40 % to 70 % again", fake.last_action(env))
		end)

		it("applies a Restore that arrived before late init, after the bridge state buffered before it", function()
			local env, c4 = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
			c4:Bind(BRIDGE_ID, 1, LIGHT_ID, 1, "HUE_BRIDGE")
			c4.persist.hue_rid = "l1"
			c4.persist.saved_level = { level = 40, target = 70, at = os.time() }
			configure(env)
			report(env, 70)
			restore(env, "1000")
			assert.equal(0, #c4.calls_to("UpdateProperty"), "nothing touches Director before late init")
			assert.equal(0, #c4.sent)

			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ { rid = "l1", on = "true", brightness = "40", rate = "1000" } }, sets(c4))
			assert.equal("Restored to 40 %", fake.last_action(env))
		end)

		it("drops a stored value that is not a saved level, with a warning, and restores nothing", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			local junk = { "40", { level = 40 }, { level = 140, target = 170 }, { level = 40, target = 0 } }
			for _, value in ipairs(junk) do
				local env, c4 = light_at(70, { saved_level = value })
				assert.is_nil(c4.persist.saved_level)
				restore(env, "1000")
				assert.equal(0, #sets(c4))
				assert.equal("Nothing to restore", fake.last_action(env))
			end
			local warned = 0
			for _, line in ipairs(lines) do
				if line:find("^%[WARN%] Hue Light: stored saved_level is not a saved level") then warned = warned + 1 end
			end
			assert.equal(#junk, warned)
		end)
	end)

	describe("on a device that cannot be driven", function()
		it("a gone light refuses both and keeps the saved level until it is linked again", function()
			local env, c4 = light_at(40)
			raise(env, "30", "1000")
			report(env, 70)
			configure(env, { state = "gone" })
			c4.sent = {}
			raise(env, "30", "1000")
			assert.equal("Not raised: gone from the Hue bridge; re-link or Forget", fake.last_action(env))
			restore(env, "1000")
			assert.equal("Not restored: gone from the Hue bridge; re-link or Forget (saved 40 % kept)",
				fake.last_action(env))
			assert.equal(0, #sets(c4))
			assert.same({ 40, 70 }, stored(c4))

			configure(env, { state = "linked" })
			restore(env, "1000")
			assert.equal("40", sets(c4)[1].brightness)
			assert.equal("Restored to 40 %", fake.last_action(env))
		end)

		it("an unbound light refuses both and keeps the saved level", function()
			local env, c4 = light_at(40)
			raise(env, "30", "1000")
			c4.bindings = {}
			env.OnBindingChanged(1, "HUE_BRIDGE", false, BRIDGE_ID, 1)
			c4.sent = {}
			raise(env, "30", "1000")
			assert.equal("Not raised: not bound to a Hue Bridge", fake.last_action(env))
			restore(env, "1000")
			assert.equal("Not restored: not bound to a Hue Bridge (saved 40 % kept)", fake.last_action(env))
			assert.equal(0, #sets(c4))
			assert.same({ 40, 70 }, stored(c4))
		end)

		it("a forgotten light and one the bridge has not assigned a Hue light refuse with their reason", function()
			local env, c4 = light_at(40)
			env.ExecuteCommand("HUE_FORGOTTEN", { rid = "l1", name = "Desk" })
			raise(env, "30", "1000")
			assert.equal("Not raised: forgotten by the bridge; delete this device or bind it again and use Link Devices",
				fake.last_action(env))
			assert.equal(0, #sets(c4))

			env, c4 = load_light(nil, { rid = false })
			raise(env, "30", "1000")
			assert.equal("Not raised: waiting for the bridge to assign a Hue light (use Add Light or Link Devices on it)",
				fake.last_action(env))
			assert.equal(0, #sets(c4))
		end)
	end)

	describe("zone and room lights", function()
		it("raise and restore a zone's grouped_light as a light's, and name the zone light", function()
			local env, c4 = load_light(nil, { rid = ZONE_RID })
			configure(env, nil, ZONE)
			c4.sent = {}
			raise(env, "30", "1000")
			assert.equal("Not raised: the zone light's level is not known yet", fake.last_action(env))

			report(env, 40, ZONE_RID)
			raise(env, "30", "1000")
			assert.same({ { rid = ZONE_RID, on = "true", brightness = "70", rate = "1000" } }, sets(c4))
			assert.equal("Raised from 40 % to 70 % (saved 40 %)", fake.last_action(env))
			report(env, 70, ZONE_RID)
			restore(env, "1000")
			assert.same({ rid = ZONE_RID, on = "true", brightness = "40", rate = "1000" }, sets(c4)[2])
			assert.equal("Restored to 40 %", fake.last_action(env))

			configure(env, { no_lights = "true", light_count = "0" }, ZONE)
			raise(env, "30", "1000")
			assert.equal("Not raised: Hue zone Bedside Lights has no lights; nothing to control", fake.last_action(env))
			assert.equal(2, #sets(c4))
		end)
	end)
end)
