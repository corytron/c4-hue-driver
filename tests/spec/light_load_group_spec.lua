-- light.load_group (#435, docs/load-groups-design.md §6.2, §6.5, §8.1): a
-- Hue Light device's load group memberships (D6), the Load Groups row and
-- HUE_LOAD_GROUPS wire text, and the translation of each group command into
-- the light's own paths (D3, D4, D11, D12), through callbacks recorded here.

local fake = require("helpers.fake_c4")

describe("light.load_group", function()
	local load_group, c4, store, saves, names, lines

	before_each(function()
		c4 = fake.install_c4()
		package.loaded["light.load_group"] = nil
		load_group = require("light.load_group")
		store, saves, names, lines = {}, {}, {}, {}
	end)

	-- A log that keeps "[LEVEL] text" lines.
	local function capture(level)
		return function(fmt, ...)
			lines[#lines + 1] = string.format("[%s] %s", level, string.format(fmt, ...))
		end
	end
	local test_log = { info = capture("INFO"), debug = capture("DEBUG"), warn = capture("WARN"),
		error = capture("ERROR") }

	local function logged(pattern)
		for _, line in ipairs(lines) do
			if line:find(pattern) then
				return line
			end
		end
		return nil
	end

	local function count_logged(pattern)
		local n = 0
		for _, line in ipairs(lines) do
			if line:find(pattern) then
				n = n + 1
			end
		end
		return n
	end

	local function new(extra)
		local opts = {
			persist_get = function(key) return store[key] end,
			persist_set = function(key, value)
				store[key] = value
				saves[#saves + 1] = { key = key, value = value }
			end,
			display_name = function(id) return names[id] end,
			log = test_log,
		}
		for k, v in pairs(extra or {}) do
			opts[k] = v
		end
		return load_group.new(opts)
	end

	-- Characters of a UTF-8 text.
	local function chars(s)
		local n = 0
		for i = 1, #s do
			local b = s:byte(i)
			if b < 128 or b > 191 then
				n = n + 1
			end
		end
		return n
	end

	describe("parse", function()
		it("reads JOIN_GROUP with underscore spellings, and with the reference's spaces", function()
			assert.same({ op = "join", group = "1234", sync = true },
				load_group.parse("JOIN_GROUP", { GROUP_ID = "1234", KEEP_SYNC = "1" }))
			assert.same({ op = "join", group = "1234", sync = false },
				load_group.parse("JOIN_GROUP", { ["GROUP ID"] = "1234", ["KEEP SYNC"] = "0" }))
		end)

		it("tries the underscore spelling first", function()
			local p = load_group.parse("SET_GROUP_SYNC", { GROUP_ID = "11", ["GROUP ID"] = "22",
				KEEP_SYNC = "0", ["KEEP SYNC"] = "1" })
			assert.same({ op = "sync", group = "11", sync = false }, p)
		end)

		it("skips an empty value and takes the next spelling", function()
			assert.equal("22", load_group.parse("LEAVE_GROUP", { GROUP_ID = "", ["GROUP ID"] = "22" }).group)
		end)

		it("reads LEAVE_GROUP and SET_GROUP_SYNC", function()
			assert.same({ op = "leave", group = "1234" }, load_group.parse("LEAVE_GROUP", { ["GROUP ID"] = "1234" }))
			assert.same({ op = "sync", group = "1234", sync = true },
				load_group.parse("SET_GROUP_SYNC", { ["GROUP ID"] = "1234", ["KEEP SYNC"] = "1" }))
		end)

		it("reads both names of the group set-level", function()
			assert.same({ op = "set", group = "1234", level = 40 },
				load_group.parse("GROUP_SET_LEVEL", { GROUP_ID = "1234", LEVEL = "40" }))
			assert.same({ op = "set", group = "1234", level = 40 },
				load_group.parse("SET_GROUP_LEVEL", { ["GROUP ID"] = "1234", LEVEL = "40" }))
		end)

		it("reads GROUP_RAMP_TO_LEVEL's level and time", function()
			assert.same({ op = "ramp", group = "1234", level = 60, time = 3000 },
				load_group.parse("GROUP_RAMP_TO_LEVEL", { ["GROUP ID"] = "1234", LEVEL = "60", TIME = "3000" }))
		end)

		it("reads GROUP_START_RAMP's direction and rate in both spellings", function()
			assert.same({ op = "start", group = "1234", up = true, rate = 5000 },
				load_group.parse("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1", RATE = "5000" }))
			assert.same({ op = "start", group = "1234", up = false, rate = 2500 },
				load_group.parse("GROUP_START_RAMP", { ["GROUP ID"] = "1234", ["RAMP UP"] = "0", RATE = "2500" }))
		end)

		it("reads GROUP_STOP_RAMP", function()
			assert.same({ op = "stop", group = "1234" }, load_group.parse("GROUP_STOP_RAMP", { ["GROUP ID"] = "1234" }))
		end)

		it("clamps numbers: level 0 to 100, time and rate at least 0", function()
			assert.equal(100, load_group.parse("GROUP_SET_LEVEL", { GROUP_ID = "1", LEVEL = "150" }).level)
			assert.equal(0, load_group.parse("GROUP_SET_LEVEL", { GROUP_ID = "1", LEVEL = "-3" }).level)
			assert.equal(0, load_group.parse("GROUP_RAMP_TO_LEVEL", { GROUP_ID = "1", LEVEL = "5", TIME = "-5" }).time)
			assert.equal(0, load_group.parse("GROUP_START_RAMP", { GROUP_ID = "1", RATE = "-1" }).rate)
		end)

		it("leaves out numbers that are not numbers", function()
			for _, bad in ipairs({ "abc", "nan", "inf", "-inf" }) do
				local p = load_group.parse("GROUP_RAMP_TO_LEVEL", { GROUP_ID = "1", LEVEL = bad, TIME = bad, RATE = bad })
				assert.is_nil(p.level, bad)
				assert.is_nil(p.time, bad)
				assert.is_nil(p.rate, bad)
			end
		end)

		it("takes any RAMP UP other than 1 as down", function()
			assert.is_false(load_group.parse("GROUP_START_RAMP", { GROUP_ID = "1", RAMP_UP = "2" }).up)
			assert.is_true(load_group.parse("GROUP_START_RAMP", { GROUP_ID = "1", RAMP_UP = 1 }).up)
			assert.is_nil(load_group.parse("GROUP_START_RAMP", { GROUP_ID = "1" }).up)
		end)

		it("rejects a command without a group id", function()
			for _, params in ipairs({ {}, { GROUP_ID = "" }, { GROUP_ID = "abc" }, { GROUP_ID = "0" },
				{ GROUP_ID = "-5" }, { GROUP_ID = "12.5" }, { ["GROUP ID"] = "1 2" }, { LEVEL = "40" } }) do
				local p, why = load_group.parse("GROUP_SET_LEVEL", params)
				assert.is_nil(p)
				assert.equal("no group id", why)
			end
		end)

		it("rejects a command it does not know", function()
			local p, why = load_group.parse("SET_BRIGHTNESS_TARGET", { GROUP_ID = "1234" })
			assert.is_nil(p)
			assert.equal("unknown command", why)
		end)

		it("keys the group id without leading zeros", function()
			assert.equal("1234", load_group.parse("GROUP_STOP_RAMP", { GROUP_ID = "01234" }).group)
			assert.equal("77", load_group.parse("GROUP_STOP_RAMP", { GROUP_ID = 77 }).group)
		end)

		it("scales TIME by ASSUME.time_scale (A5)", function()
			load_group.ASSUME.time_scale = 1000
			assert.equal(2000, load_group.parse("GROUP_RAMP_TO_LEVEL", { GROUP_ID = "1", LEVEL = "5", TIME = "2" }).time)
		end)

		it("reads a spelling added to ASSUME.keys", function()
			table.insert(load_group.ASSUME.keys.group, "GROUPID")
			assert.equal("9", load_group.parse("GROUP_STOP_RAMP", { GROUPID = "9" }).group)
		end)
	end)

	describe("membership", function()
		it("join, leave, set_sync and learn report changed only on a change", function()
			local m = new()
			assert.is_true(m:join("1234", false))
			assert.is_false(m:join("1234", false))
			assert.is_true(m:join("1234", true))
			assert.is_false(m:set_sync("1234", true))
			assert.is_true(m:set_sync("1234", false))
			assert.is_false(m:learn("1234"))
			assert.is_true(m:learn("5678"))
			assert.is_true(m:leave("5678"))
			assert.is_false(m:leave("5678"))
			assert.is_false(m:leave("9999"))
			assert.is_true(m:set_sync("4321", true)) -- learnt with its flag
			assert.same({ "1234", "4321" }, m:ids())
		end)

		it("ignores ids that are not device ids", function()
			local m = new()
			assert.is_false(m:join("abc", true))
			assert.is_false(m:learn(nil))
			assert.is_false(m:set_sync("0", true))
			assert.same({}, m:ids())
			assert.same({}, saves)
		end)

		it("has() and ids() in numeric order", function()
			local m = new()
			m:join("1234", false)
			m:learn("999")
			m:join("20000", true)
			assert.is_true(m:has("999"))
			assert.is_true(m:has(1234))
			assert.is_false(m:has("5"))
			assert.same({ "999", "1234", "20000" }, m:ids())
		end)

		it("persists each change as a fresh table", function()
			local m = new()
			m:join("1234", true)
			m:learn("5678")
			assert.equal(2, #saves)
			assert.equal(load_group.KEY, saves[2].key)
			assert.equal("hue_load_groups", saves[2].key)
			assert.same({ ["1234"] = { sync = true }, ["5678"] = { sync = false } }, store.hue_load_groups)
			assert.are_not.equal(saves[1].value, saves[2].value)
			m:join("1234", true) -- no change, no write
			assert.equal(2, #saves)
		end)

		it("survives load after persist_set", function()
			local m = new()
			m:join("1234", true)
			m:join("5678", false)
			local again = new()
			assert.equal(2, again:load())
			assert.same({ "1234", "5678" }, again:ids())
			assert.equal("1234:1,5678:0", again:wire())
		end)

		it("loads nothing from an empty store, and writes nothing", function()
			local m = new()
			assert.equal(0, m:load())
			assert.same({}, saves)
		end)

		it("drops a stored value that is not a table, and stores the empty list", function()
			store.hue_load_groups = "1234:1"
			local m = new()
			assert.equal(0, m:load())
			assert.same({}, m:ids())
			assert.same({}, store.hue_load_groups)
			assert.truthy(logged("^%[WARN%] stored hue_load_groups is not a list of load groups"))
		end)

		it("drops entries with a bad key or a value that is not a table, and keeps the rest", function()
			store.hue_load_groups = {
				["1234"] = { sync = true },
				abc = { sync = true },
				["0"] = { sync = false },
				["-5"] = { sync = false },
				["12.5"] = { sync = false },
				[""] = { sync = false },
				["5678"] = true,
				["4321"] = { sync = "yes" }, -- kept; only true is in sync
			}
			local m = new()
			assert.equal(2, m:load())
			assert.same({ "1234", "4321" }, m:ids())
			assert.equal("1234:1,4321:0", m:wire())
			assert.same({ ["1234"] = { sync = true }, ["4321"] = { sync = false } }, store.hue_load_groups)
			assert.equal(6, count_logged("^%[WARN%] stored load group "))
		end)

		it("takes a whole-number key as that device id and stores it as a string", function()
			store.hue_load_groups = { [1234] = { sync = true } }
			local m = new()
			assert.equal(1, m:load())
			assert.same({ ["1234"] = { sync = true } }, store.hue_load_groups)
		end)

		it("does not write back a clean list at load", function()
			store.hue_load_groups = { ["1234"] = { sync = true } }
			new():load()
			assert.same({}, saves)
		end)

		it("load replaces what was in memory", function()
			local m = new()
			m:join("1234", true)
			store.hue_load_groups = { ["5678"] = { sync = false } }
			m:load()
			assert.same({ "5678" }, m:ids())
		end)

		it("logs JOIN, LEAVE and sync changes at info (D16)", function()
			names[1234] = "Kitchen Group"
			local m = new()
			m:join("1234", false)
			m:set_sync("1234", true)
			m:leave("1234")
			m:learn("5678")
			assert.truthy(logged("^%[INFO%] joined load group 1234 %(Kitchen Group%), keep loads in sync off$"))
			assert.truthy(logged("^%[INFO%] load group 1234 %(Kitchen Group%): keep loads in sync on$"))
			assert.truthy(logged("^%[INFO%] left load group 1234 %(Kitchen Group%)$"))
			assert.truthy(logged("^%[INFO%] load group 5678 learnt from a group command$"))
		end)
	end)

	describe("wire and text", function()
		local m

		before_each(function()
			m = new()
		end)

		it("say none", function()
			assert.equal("none", m:wire())
			assert.equal("None", m:text())
		end)

		it("name one group", function()
			names[1234] = "Kitchen Group"
			m:join("1234", false)
			assert.equal("1234:0", m:wire())
			assert.equal("Kitchen Group", m:text())
		end)

		it("name two, one of them in sync", function()
			names[1234], names[5678] = "Kitchen Group", "Hallway Group"
			m:join("1234", true)
			m:join("5678", false)
			assert.equal("1234:1,5678:0", m:wire())
			assert.equal("Kitchen Group (in sync), Hallway Group", m:text())
		end)

		it("say which id has no name, and keep it (E3)", function()
			m:join("1234", false)
			assert.equal("device 1234 (not found)", m:text())
			names[1234] = ""
			assert.equal("device 1234 (not found)", m:text())
			assert.is_true(m:has("1234"))
		end)

		it("treat a raising name lookup as no name", function()
			local raising = new({ display_name = function() error("no such device") end })
			raising:join("1234", true)
			assert.equal("device 1234 (not found) (in sync)", raising:text())
		end)

		it("read names when written, so a renamed group shows its new name (E5)", function()
			names[1234] = "Kitchen Group"
			m:join("1234", false)
			names[1234] = "Kitchen Lights"
			assert.equal("Kitchen Lights", m:text())
		end)

		it("summarise a list over 75 characters", function()
			names[1234] = "Kitchen Group"
			names[5678] = "Downstairs Hallway, Stairs and Landing Lights"
			names[9012] = "Outdoor Garden Path Lights"
			m:join("1234", false)
			m:join("5678", false)
			m:join("9012", false)
			assert.equal("3 load groups: Kitchen Group, …", m:text())
		end)

		it("fit as many names as the column holds", function()
			for i = 1, 20 do
				local id = 1000 + i
				names[id] = string.format("Group %02d", i)
				m:join(tostring(id), i % 2 == 0)
			end
			local text = m:text()
			assert.truthy(text:find("^20 load groups: Group 01, Group 02 %(in sync%), Group 03, "))
			assert.truthy(text:find(", …$"))
			assert.is_true(chars(text) <= 75)
			-- one more name would not have fitted
			assert.is_true(chars(text) + #", Group 99 (in sync)" > 75)
		end)

		it("cut one long name to the column", function()
			names[1234] = string.rep("Long name ", 10)
			m:join("1234", false)
			local text = m:text()
			assert.equal(75, chars(text))
			assert.truthy(text:find("^Long name Long name"))
			assert.truthy(text:find("…$"))
		end)

		it("cut the first name when not even it fits the summary", function()
			names[1234] = string.rep("x", 80)
			names[5678] = "Hallway Group"
			m:join("1234", false)
			m:join("5678", false)
			local text = m:text()
			assert.equal("2 load groups: " .. string.rep("x", 59) .. "…", text)
			assert.equal(75, chars(text))
		end)

		it("count UTF-8 characters, and never cut one in half", function()
			names[1234] = string.rep("é", 80)
			m:join("1234", false)
			local text = m:text()
			assert.equal(75, chars(text))
			assert.equal(string.rep("é", 74) .. "…", text)
			names[1234] = string.rep("é", 75) -- fits as it is
			assert.equal(string.rep("é", 75), m:text())
		end)

		it("strip control characters from names", function()
			names[1234] = "Kitchen\nGroup\t"
			m:join("1234", false)
			assert.equal("KitchenGroup", m:text())
		end)
	end)

	describe("hold_plan", function()
		-- The arithmetic of src/hue_light/driver.lua start_ramp, as it stands.
		local HOLD_TICK_MS, HOLD_MAX_MS = 100, 6000000
		local function start_ramp_math(from, up, setting)
			local to = up and 100 or 1
			local full = math.floor(math.min(setting, HOLD_MAX_MS))
			local duration = math.floor(full * math.abs(to - from) / 100)
			return { to = to, duration = duration, full = full,
				step = (to - from) / math.max(1, duration / HOLD_TICK_MS) }
		end

		it("matches start_ramp's arithmetic up, down and above the cap", function()
			for _, from in ipairs({ 1, 13, 37.5, 50, 99, 100 }) do
				for _, up in ipairs({ true, false }) do
					for _, rate in ipairs({ 0, 250, 5000, 7333, 6000000, 6000001, 9e9 }) do
						assert.same(start_ramp_math(from, up, rate), load_group.hold_plan(from, up, rate, HOLD_MAX_MS),
							string.format("from %s %s over %s", tostring(from), up and "up" or "down", tostring(rate)))
					end
				end
			end
		end)

		it("works out the example of the keypad's hold", function()
			assert.same({ to = 100, duration = 2500, full = 5000, step = 2 }, load_group.hold_plan(50, true, 5000))
			assert.same({ to = 1, duration = 2450, full = 5000, step = -49 / 24.5 }, load_group.hold_plan(50, false, 5000))
			assert.equal(6000000, load_group.hold_plan(50, true, 1e12).full)
			assert.equal(1000, load_group.hold_plan(50, true, 5000, 1000).full)
		end)

		it("mirrors the driver's constants", function()
			local function source(path)
				local f = assert(io.open(path, "r"))
				local text = f:read("*a")
				f:close()
				return text
			end
			local driver = source("src/hue_light/driver.lua")
			local device = source("src/common/device.lua")
			assert.equal(load_group.HOLD_TICK_MS, tonumber(driver:match("\nlocal HOLD_TICK_MS = (%d+)")))
			assert.equal(load_group.HOLD_MAX_MS, tonumber(driver:match("\nlocal HOLD_MAX_MS = (%d+)")))
			assert.equal(load_group.FALLBACK_MS, tonumber(driver:match("\nlocal FALLBACK_MS = (%d+)")))
			assert.equal(load_group.DIM_AFTER_ON_MS, tonumber(device:match("\nlocal DIM_AFTER_ON_MS = (%d+)")))
		end)
	end)

	-- The translation, against a light whose paths are recorded in `calls`.
	describe("handle", function()
		local light, calls, m

		local function wired(extra)
			light = { on = true, level = 50, ready = true, sent = true, ramp = nil }
			calls = {}
			local function rec(...)
				calls[#calls + 1] = { ... }
			end
			local opts = {
				send_groups = function(wire) rec("send_groups", wire) end,
				show = function(text) rec("show", text) end,
				ready = function(command)
					rec("ready", command)
					return light.ready
				end,
				is_on = function() return light.on end,
				level = function() return light.level end,
				set_brightness = function(level, rate, group)
					rec("set_brightness", level, rate, group)
					return light.sent
				end,
				hold_rate = function(up) return up and 4000 or 8000 end,
				ramp = function() return light.ramp end,
				stop_ramp = function(why, group)
					rec("stop_ramp", why, group)
					light.ramp = nil
					return true
				end,
				report = function() rec("report") end,
				-- As start_ramp does: ramping, the estimate and its tick.
				start_dim = function(r, up, from, rate)
					rec("start_dim", r.group, up, from, rate)
					r.ramping, r.level = light.sent, from
					if light.sent then
						r.timer = C4:SetTimer(100, function() end, true)
					end
				end,
				finish_dim = function(r, group) rec("finish_dim", r.group, group, r.level) end,
			}
			for k, v in pairs(extra or {}) do
				opts[k] = v
			end
			m = new(opts)
			return m
		end

		local function names_of(list)
			local out = {}
			for i, call in ipairs(list) do
				out[i] = call[1]
			end
			return out
		end

		local function find(name)
			for _, call in ipairs(calls) do
				if call[1] == name then
					return call
				end
			end
			return nil
		end

		local function active_timers()
			local n = 0
			for _, t in ipairs(c4.timers) do
				if t.active then
					n = n + 1
				end
			end
			return n
		end

		before_each(function()
			wired()
		end)

		describe("membership commands", function()
			it("JOIN_GROUP persists, then sends HUE_LOAD_GROUPS and writes the row (E1)", function()
				names[1234] = "Kitchen Group"
				local p, done = m:handle("JOIN_GROUP", { GROUP_ID = "1234", KEEP_SYNC = "0" })
				assert.equal("join", done)
				assert.equal("1234", p.group)
				assert.same({ ["1234"] = { sync = false } }, store.hue_load_groups)
				assert.same({ { "send_groups", "1234:0" }, { "show", "Kitchen Group" } }, calls)
			end)

			it("a JOIN_GROUP that changes nothing announces nothing", function()
				m:handle("JOIN_GROUP", { GROUP_ID = "1234", KEEP_SYNC = "0" })
				calls = {}
				m:handle("JOIN_GROUP", { GROUP_ID = "1234", KEEP_SYNC = "0" })
				assert.same({}, calls)
			end)

			it("LEAVE_GROUP removes and announces (E2); an unknown id does nothing", function()
				m:handle("JOIN_GROUP", { GROUP_ID = "1234", KEEP_SYNC = "0" })
				calls = {}
				m:handle("LEAVE_GROUP", { ["GROUP ID"] = "1234" })
				assert.same({ { "send_groups", "none" }, { "show", "None" } }, calls)
				calls = {}
				local before = #saves
				m:handle("LEAVE_GROUP", { ["GROUP ID"] = "1234" })
				assert.same({}, calls)
				assert.equal(before, #saves)
			end)

			it("SET_GROUP_SYNC records the flag (E4, D13), learning an unknown id", function()
				names[1234] = "Kitchen Group"
				m:handle("SET_GROUP_SYNC", { ["GROUP ID"] = "1234", ["KEEP SYNC"] = "1" })
				assert.same({ { "send_groups", "1234:1" }, { "show", "Kitchen Group (in sync)" } }, calls)
				assert.truthy(logged("keep loads in sync on %(learnt%)"))
				-- recorded, never acted on: nothing else went anywhere
				assert.is_nil(find("set_brightness"))
			end)

			it("JOIN without KEEP SYNC joins out of sync", function()
				m:handle("JOIN_GROUP", { GROUP_ID = "1234" })
				assert.equal("1234:0", m:wire())
			end)
		end)

		describe("level commands", function()
			it("GROUP_SET_LEVEL learns the id, announces it, then sets the level at rate 0 with the tag (D3, D6)", function()
				local _, done = m:handle("GROUP_SET_LEVEL", { GROUP_ID = "1234", LEVEL = "40" })
				assert.equal("set", done)
				assert.same({ { "send_groups", "1234:0" }, { "show", "device 1234 (not found)" },
					{ "set_brightness", 40, 0, "1234" } }, calls)
				assert.is_true(m:has("1234"))
			end)

			it("SET_GROUP_LEVEL is the same command", function()
				m:join("1234", false)
				m:handle("SET_GROUP_LEVEL", { ["GROUP ID"] = "1234", LEVEL = "0" })
				assert.same({ { "set_brightness", 0, 0, "1234" } }, calls)
			end)

			it("a known id is not announced again", function()
				m:join("1234", false)
				m:handle("GROUP_SET_LEVEL", { GROUP_ID = "1234", LEVEL = "40" })
				assert.same({ "set_brightness" }, names_of(calls))
			end)

			it("GROUP_SET_LEVEL follows #430's default rate when the driver has one (D4)", function()
				wired({ default_rate = function() return 750 end })
				m:handle("GROUP_SET_LEVEL", { GROUP_ID = "1234", LEVEL = "40" })
				assert.same({ "set_brightness", 40, 750, "1234" }, find("set_brightness"))
			end)

			it("GROUP_RAMP_TO_LEVEL is a timed target with the tag (D3)", function()
				local _, done = m:handle("GROUP_RAMP_TO_LEVEL", { GROUP_ID = "1234", LEVEL = "60", TIME = "3000" })
				assert.equal("ramp", done)
				assert.same({ "set_brightness", 60, 3000, "1234" }, find("set_brightness"))
			end)

			it("GROUP_RAMP_TO_LEVEL without TIME takes the default rate, else 0", function()
				m:handle("GROUP_RAMP_TO_LEVEL", { GROUP_ID = "1234", LEVEL = "60" })
				assert.same({ "set_brightness", 60, 0, "1234" }, find("set_brightness"))
				wired({ default_rate = function() return 500 end })
				m:handle("GROUP_RAMP_TO_LEVEL", { GROUP_ID = "1234", LEVEL = "60" })
				assert.same({ "set_brightness", 60, 500, "1234" }, find("set_brightness"))
				calls = {}
				m:handle("GROUP_RAMP_TO_LEVEL", { GROUP_ID = "1234", LEVEL = "60", TIME = "0" })
				assert.same({ "set_brightness", 60, 0, "1234" }, find("set_brightness"))
			end)

			it("a level command without a level is ignored, but its id is learnt", function()
				local _, done = m:handle("GROUP_SET_LEVEL", { GROUP_ID = "1234", LEVEL = "abc" })
				assert.equal("ignored", done)
				assert.is_nil(find("set_brightness"))
				assert.is_true(m:has("1234"))
				assert.truthy(logged("^%[WARN%] GROUP_SET_LEVEL from load group 1234 without a level; ignored$"))
			end)

			it("acts on an unknown id without learning it when ASSUME.learn is off (D5)", function()
				load_group.ASSUME.learn = false
				m:handle("GROUP_SET_LEVEL", { GROUP_ID = "1234", LEVEL = "40" })
				assert.same({ { "set_brightness", 40, 0, "1234" } }, calls)
				assert.is_false(m:has("1234"))
			end)

			it("ends a running group hold without a stop (#421 D11)", function()
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				local hold = m:holding()
				m:handle("GROUP_SET_LEVEL", { GROUP_ID = "5678", LEVEL = "20" })
				assert.is_nil(m:holding())
				assert.is_false(hold.active)
				assert.is_nil(find("finish_dim"))
				assert.same({ "set_brightness", 20, 0, "5678" }, find("set_brightness"))
				assert.equal(0, active_timers())
			end)
		end)

		describe("the group hold", function()
			it("up while on dims from the level shown over the Hold Rate Up, tagged (D3, L14)", function()
				local _, done = m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				assert.equal("hold", done)
				assert.same({ "start_dim", "1234", true, 50, 4000 }, find("start_dim"))
				assert.same({ "ready", "GROUP_START_RAMP" }, find("ready"))
				local hold = m:holding()
				assert.equal("1234", hold.group)
				assert.is_true(hold.active)
				assert.equal(4000, hold.full)
			end)

			it("down while on uses the Hold Rate Down", function()
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "0" })
				assert.same({ "start_dim", "1234", false, 50, 8000 }, find("start_dim"))
			end)

			it("takes RATE as the whole-range time, capped at HOLD_MAX_MS (A5)", function()
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1", RATE = "2000" })
				assert.same({ "start_dim", "1234", true, 50, 2000 }, find("start_dim"))
				wired()
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1", RATE = "99999999" })
				assert.same({ "start_dim", "1234", true, 50, 6000000 }, find("start_dim"))
			end)

			it("works the whole range out of RATE when ASSUME.rate_whole_range is off", function()
				load_group.ASSUME.rate_whole_range = false
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1", RATE = "2000" })
				assert.same({ "start_dim", "1234", true, 50, 4000 }, find("start_dim")) -- 50 points in 2 s
			end)

			it("from a level not known yet starts at 1", function()
				light.level = nil
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				assert.same({ "start_dim", "1234", true, 1, 4000 }, find("start_dim"))
			end)

			it("down while off does nothing (L43)", function()
				light.on = false
				local _, done = m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "0" })
				assert.equal("nothing", done)
				assert.is_nil(find("set_brightness"))
				assert.is_nil(find("start_dim"))
				assert.is_nil(m:holding())
			end)

			it("up while off turns on at 1 % with the tag, then dims up 600 ms later (L43)", function()
				light.on = false
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1", RATE = "3000" })
				assert.same({ "set_brightness", 1, 0, "1234" }, find("set_brightness"))
				assert.is_nil(find("start_dim"))
				c4.advance(599)
				assert.is_nil(find("start_dim"))
				light.on, light.level = true, 1 -- the bridge reported the turn-on
				c4.advance(1)
				assert.same({ "start_dim", "1234", true, 1, 3000 }, find("start_dim"))
			end)

			it("up while off dims from 1 when the turn-on is not reported yet", function()
				light.on, light.level = false, 0
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				c4.advance(600)
				assert.same({ "start_dim", "1234", true, 1, 4000 }, find("start_dim"))
			end)

			it("up while off: a turn-on that did not reach the bridge starts no hold", function()
				light.on, light.sent = false, false
				local _, done = m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				assert.equal("failed", done)
				assert.is_nil(m:holding())
				assert.equal(0, active_timers())
			end)

			it("a light that cannot be driven drops the start; the id is still learnt", function()
				light.ready = false
				local _, done = m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				assert.equal("dropped", done)
				assert.same({ "send_groups", "show", "ready" }, names_of(calls))
				assert.is_nil(m:holding())
			end)

			it("a dim that did not reach the bridge ends the record", function()
				light.sent = false
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				assert.truthy(find("start_dim"))
				assert.is_nil(m:holding())
				assert.equal(0, active_timers())
			end)

			it("a start_dim that answers false ends the record too", function()
				wired({ start_dim = function() return false end })
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				assert.is_nil(m:holding())
			end)

			it("GROUP_STOP_RAMP of that group stops it with the estimate, tagged (D12)", function()
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				local hold = m:holding()
				hold.level = 63.4 -- the tick moved the estimate
				calls = {}
				local _, done = m:handle("GROUP_STOP_RAMP", { ["GROUP ID"] = "1234" })
				assert.equal("hold stopped", done)
				assert.same({ { "finish_dim", "1234", "1234", 63.4 } }, calls)
				assert.is_nil(m:holding())
				assert.is_false(hold.active)
				assert.equal(0, active_timers()) -- the tick and the end-of-range timer
			end)

			it("a stop for another group leaves it running", function()
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				calls = {}
				local _, done = m:handle("GROUP_STOP_RAMP", { GROUP_ID = "5678" })
				assert.equal("left running", done)
				assert.same({ "send_groups", "show" }, names_of(calls)) -- 5678 learnt, nothing else
				assert.equal("1234", m:holding().group)
			end)

			it("a stop while the hold waits for its turn-on sends nothing, and the dim never starts", function()
				light.on = false
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				calls = {}
				m:handle("GROUP_STOP_RAMP", { GROUP_ID = "1234" })
				assert.same({}, calls)
				c4.advance(1000)
				assert.same({}, calls)
				assert.is_nil(m:holding())
			end)

			it("a lost stop ends the record after the whole range plus the fallback (E10)", function()
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" }) -- 4000 ms
				calls = {}
				c4.advance(4999)
				assert.truthy(m:holding())
				c4.advance(1)
				assert.is_nil(m:holding())
				assert.same({ { "report" } }, calls)
				assert.truthy(logged("^%[INFO%] group hold of load group 1234 ended by itself after 5000 ms"))
				-- the late stop finds nothing running: CHANGED with the cache
				calls = {}
				m:handle("GROUP_STOP_RAMP", { GROUP_ID = "1234" })
				assert.same({ { "report" } }, calls)
			end)

			it("a new start ends the running one first and starts from its estimate", function()
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				local first = m:holding()
				first.level = 73
				calls = {}
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "0" })
				assert.is_false(first.active)
				assert.is_nil(find("finish_dim")) -- the new dim replaces the old at Hue
				assert.same({ "start_dim", "1234", false, 73, 8000 }, find("start_dim"))
				assert.are_not.equal(first, m:holding())
				-- the first one's end-of-range timer is gone with it
				c4.advance(8000 + 1000 - 1)
				assert.truthy(m:holding())
			end)

			it("the light's own stop stops it untagged (D11, D12)", function()
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				calls = {}
				assert.is_true(m:stop_hold("tap"))
				assert.same({ { "finish_dim", "1234", nil, 50 } }, calls)
				assert.is_nil(m:holding())
				assert.is_false(m:stop_hold("tap"))
			end)

			it("end_hold ends it without a stop", function()
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				calls = {}
				assert.is_true(m:end_hold("keypad hold"))
				assert.same({}, calls)
				assert.is_nil(m:holding())
				assert.equal(0, active_timers())
				assert.is_false(m:end_hold("again"))
			end)

			it("a failing callback in a timer is logged, not raised", function()
				wired({ report = function() error("boom") end })
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				c4.advance(5000)
				assert.truthy(logged("^%[ERROR%] load group timer failed: .*boom"))
				assert.is_nil(m:holding())
			end)
		end)

		describe("GROUP_STOP_RAMP without a hold", function()
			it("stops a timed ramp that group started, tagged (D12)", function()
				light.ramp = { group = "1234" }
				local _, done = m:handle("GROUP_STOP_RAMP", { GROUP_ID = "1234" })
				assert.equal("ramp stopped", done)
				assert.same({ "stop_ramp", "GROUP_STOP_RAMP", "1234" }, find("stop_ramp"))
				assert.is_nil(find("report"))
			end)

			it("leaves a ramp of another group, or of the light's own, running", function()
				light.ramp = { group = "5678" }
				local _, done = m:handle("GROUP_STOP_RAMP", { GROUP_ID = "1234" })
				assert.equal("left running", done)
				light.ramp = { tap = true }
				_, done = m:handle("GROUP_STOP_RAMP", { GROUP_ID = "1234" })
				assert.equal("left running", done)
				assert.is_nil(find("stop_ramp"))
				assert.is_nil(find("report"))
			end)

			it("with nothing running reports the cached level", function()
				local _, done = m:handle("GROUP_STOP_RAMP", { GROUP_ID = "1234" })
				assert.equal("report", done)
				assert.same({ "report" }, find("report"))
			end)
		end)

		describe("logs and refusals", function()
			it("logs the first arrival of each command name in full, once a run (D16)", function()
				m:handle("GROUP_SET_LEVEL", { ["GROUP ID"] = "1234", LEVEL = "40" })
				m:handle("GROUP_SET_LEVEL", { ["GROUP ID"] = "1234", LEVEL = "50" })
				m:handle("JOIN_GROUP", { GROUP_ID = "1234", KEEP_SYNC = "1" })
				assert.equal(1, count_logged("^%[INFO%] first GROUP_SET_LEVEL this run: "))
				assert.truthy(logged('^%[INFO%] first GROUP_SET_LEVEL this run: GROUP ID="1234", LEVEL="40"$'))
				assert.truthy(logged('^%[INFO%] first JOIN_GROUP this run: GROUP_ID="1234", KEEP_SYNC="1"$'))
			end)

			it("logs a command without a group id and does nothing", function()
				local p, why = m:handle("GROUP_SET_LEVEL", { LEVEL = "40" })
				assert.is_nil(p)
				assert.equal("no group id", why)
				assert.same({}, calls)
				assert.truthy(logged("^%[WARN%] GROUP_SET_LEVEL ignored: no group id$"))
				assert.truthy(logged("^%[INFO%] first GROUP_SET_LEVEL this run: LEVEL=\"40\"$"))
			end)

			it("refuses a command it does not know", function()
				local p, why = m:handle("SET_BRIGHTNESS_TARGET", { GROUP_ID = "1" })
				assert.is_nil(p)
				assert.equal("unknown command", why)
				assert.is_nil(logged("first SET_BRIGHTNESS_TARGET"))
			end)

			it("warns once about a callback that is not wired", function()
				local bare = new()
				bare:handle("GROUP_SET_LEVEL", { GROUP_ID = "1234", LEVEL = "40" })
				bare:handle("GROUP_SET_LEVEL", { GROUP_ID = "1234", LEVEL = "50" })
				assert.equal(1, count_logged("^%[WARN%] load groups: no set_brightness callback; skipped$"))
				assert.equal(1, count_logged("no send_groups callback"))
			end)

			it("announce sends the list and writes the row (after a hello, at late init)", function()
				names[1234] = "Kitchen Group"
				m:join("1234", true)
				calls = {}
				m:announce()
				assert.same({ { "send_groups", "1234:1" }, { "show", "Kitchen Group (in sync)" } }, calls)
			end)

			it("uses C4:SetTimer when no set_timer is given", function()
				light.on = false
				m:handle("GROUP_START_RAMP", { GROUP_ID = "1234", RAMP_UP = "1" })
				assert.equal(600, c4.timers[#c4.timers].delay)
			end)
		end)
	end)
end)
