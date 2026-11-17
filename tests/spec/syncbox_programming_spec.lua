-- syncbox/programming.lua (#568, docs/hdmi-sync-stage4-design.md §3,
-- contracts C1.6 to C1.9, design docs/hdmi-sync-design.md §5.3 and §5.5):
-- the commands as queue writes, the variables set before their events, no
-- event for a value that did not change (a restart, a first read), the
-- conditionals, the manual hold, the UI Buttons. The first parts drive the
-- module with a recording queue and a stand-in for agent B's
-- syncbox/periods.lua, and the fake runtime's C4:AddVariable, SetVariable,
-- FireEventByID and Persist calls; the last part runs it with the real
-- queue, client and poller against the Lua fake box
-- (tests/helpers/fake_syncbox.lua). Parameters are text, as Director sends
-- them. Placeholders only: box 10.0.2.150, id 0A1B2C3D4E5F, token
-- TEST-TOKEN-NOT-REAL.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_syncbox")

describe("syncbox/programming.lua (#568)", function()
	local programming, state, c4, p, sq, periods, actions, current, busy

	local NAMES = { "SYNC_ACTIVE", "SYNC_MODE", "INTENSITY", "BRIGHTNESS", "HDMI_INPUT", "HDMI_INPUT_NAME",
		"ENTERTAINMENT_AREA", "POWER", "ONLINE" }

	-- The recording queue: every set kept; target() merges the sets not yet
	-- ended, as the real queue's; finish(i, ok, why, detail) ends set i.
	local function stub_queue()
		local s = { sets = {} }
		function s:set(fields, tag, cb)
			if self.refuse then
				return false, self.refuse
			end
			self.sets[#self.sets + 1] = { fields = fields, tag = tag, cb = cb }
			return true
		end
		function s:target()
			local out = {}
			for _, e in ipairs(self.sets) do
				if not e.ended then
					for k, v in pairs(e.fields) do out[k] = v end
				end
			end
			return out
		end
		function s:finish(i, ok, why, detail)
			local entry = assert(self.sets[i], "no set " .. tostring(i))
			entry.ended = true
			entry.cb(entry.tag, ok, nil, why, detail)
		end
		function s:last()
			return self.sets[#self.sets] and self.sets[#self.sets].fields
		end
		return s
	end

	-- Agent B's periods as stage 4 §4 names them: hold, release, current,
	-- settings_for (and held, which this module asks when it is there).
	local function stub_periods()
		local s = { holds = {}, releases = {}, settings = { intensity = "Moderate", brightness = 90 } }
		function s:hold(field)
			self.holds[#self.holds + 1] = field
			self.held_now = self.held_now or {}
			self.held_now[field] = true
		end
		function s:release(reason) self.releases[#self.releases + 1] = reason; self.held_now = {} end
		function s:held(field) return self.held_now ~= nil and self.held_now[field] == true end
		function s:current() return "evening" end
		function s:settings_for(period, mode)
			self.asked = { period = period, mode = mode }
			return self.settings
		end
		return s
	end

	local function model_of(name, edit)
		local raw = F.copy(F.state[name])
		if edit then edit(raw) end
		return (state.from_api(raw))
	end

	local function new_p(extra)
		local deps = {
			queue = sq,
			model_now = function() return current end,
			periods = periods,
			last_action = function(text) actions[#actions + 1] = text end,
			on_busy = function(fields, tag) busy[#busy + 1] = { fields = fields, tag = tag }; return busy.handle end,
			log = log,
		}
		for k, v in pairs(extra or {}) do deps[k] = v end
		return programming.new(deps)
	end

	-- The variable writes and events since `from` (an index into c4.calls),
	-- as "SET NAME=value" and "EVENT id", in order.
	local function trace(from)
		local out = {}
		for i = (from or 0) + 1, #c4.calls do
			local call = c4.calls[i]
			if call.name == "SetVariable" then
				out[#out + 1] = "SET " .. call.args[1] .. "=" .. tostring(call.args[2])
			elseif call.name == "FireEventByID" then
				out[#out + 1] = "EVENT " .. tostring(call.args[1])
			end
		end
		return out
	end

	local function events(from)
		local out = {}
		for _, line in ipairs(trace(from)) do
			local id = line:match("^EVENT (%d+)")
			if id then out[#out + 1] = tonumber(id) end
		end
		return out
	end

	-- A driver that saw `model` before (its store), started again.
	local function restarted(model)
		local first = new_p()
		first:init()
		first:observe(model)
		local stored = c4.persist[programming.PERSIST_KEY]
		c4 = fake.install_c4()
		c4.persist[programming.PERSIST_KEY] = stored
		local again = new_p()
		again:init()
		return again
	end

	before_each(function()
		log.sink = function() end
		log.set_debug(true)
		c4 = fake.install_c4()
		for _, m in ipairs({ "syncbox.programming", "syncbox.state" }) do package.loaded[m] = nil end
		programming, state = require("syncbox.programming"), require("syncbox.state")
		sq, periods = stub_queue(), stub_periods()
		actions, busy = {}, {}
		current = model_of("HSB2")
		p = new_p()
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("the variables (C1.9)", function()
		it("adds the nine in C1.9's order, read-only and shown, by name from 1001", function()
			p:init()
			assert.same(NAMES, c4.variable_names)
			local types = {}
			for i, name in ipairs(NAMES) do
				local v = c4.variables[name]
				types[#types + 1] = v.type
				assert.equal(1000 + i, v.id)
				assert.is_true(v.read_only)
				assert.is_false(v.hidden)
			end
			assert.same({ "BOOL", "STRING", "STRING", "NUMBER", "INT", "STRING", "STRING", "STRING", "BOOL" }, types)
			assert.same({}, c4.calls_to("SetVariable"), "nothing set in OnDriverInit")
		end)

		it("starts each at its persisted value; a stored value it cannot hold reads the default", function()
			c4.persist[programming.PERSIST_KEY] = { v = { SYNC_ACTIVE = "1", SYNC_MODE = "game", INTENSITY = "loud",
				BRIGHTNESS = "999", HDMI_INPUT = "2", HDMI_INPUT_NAME = "PlayStation", POWER = "on", ONLINE = "1" },
				area = F.AREA.tv }
			p:init()
			assert.equal("1", c4.variables.SYNC_ACTIVE.value)
			assert.equal("game", c4.variables.SYNC_MODE.value)
			assert.equal("", c4.variables.INTENSITY.value)
			assert.equal("100", c4.variables.BRIGHTNESS.value)
			assert.equal("2", c4.variables.HDMI_INPUT.value)
			assert.equal("PlayStation", c4.variables.HDMI_INPUT_NAME.value)
			assert.equal("on", c4.variables.POWER.value)
			assert.equal("1", p:value("ONLINE"))
		end)

		it("goes on when the variables exist already (an update in place: AddVariable answers false)", function()
			p:init()
			p = new_p()
			assert.same(NAMES, p:init())
			assert.same(NAMES, c4.variable_names)
		end)

		it("survives a store that is not a table", function()
			c4.persist[programming.PERSIST_KEY] = "garbage"
			assert.same(NAMES, p:init())
			assert.equal("0", p:value("SYNC_ACTIVE"))
		end)
	end)

	describe("events from the reads (C1.7)", function()
		it("takes the first read after an install as a baseline: every variable set, no event", function()
			p:init()
			p:observe(current, nil, "read")
			assert.same({}, c4.events_fired)
			assert.equal("1", c4.variables.SYNC_ACTIVE.value)
			assert.equal("video", c4.variables.SYNC_MODE.value)
			assert.equal("high", c4.variables.INTENSITY.value)
			assert.equal("100", c4.variables.BRIGHTNESS.value)
			assert.equal("1", c4.variables.HDMI_INPUT.value)
			assert.equal("Apple TV", c4.variables.HDMI_INPUT_NAME.value)
			assert.equal("Living Room TV", c4.variables.ENTERTAINMENT_AREA.value)
			assert.equal("on", c4.variables.POWER.value)
			assert.equal("1", c4.variables.ONLINE.value)
			assert.is_table(c4.persist[programming.PERSIST_KEY], "the baseline is stored")
			assert.same({}, periods.releases)
		end)

		it("fires nothing after a restart during a film: the same read sets and fires nothing", function()
			p = restarted(current)
			assert.equal("1", c4.variables.SYNC_ACTIVE.value)
			p:observe(current)
			assert.same({}, trace())
		end)

		it("sets the variables before the events of a sync start, and fires Sync Started and Sync Mode Changed",
			function()
				p = restarted(model_of("HSB1"))
				local mark = #c4.calls
				p:observe(model_of("HSB1", function(raw)
					raw.execution.mode, raw.execution.syncActive = "video", true
				end))
				assert.same({ "SET SYNC_ACTIVE=1", "SET SYNC_MODE=video", "SET INTENSITY=moderate",
					"EVENT 1", "EVENT 3", "EVENT 4" }, trace(mark))
			end)

		it("fires Sync Stopped and Sync Mode Changed when sync stops, and releases the manual hold", function()
			p = restarted(current)
			local mark = #c4.calls
			p:observe(model_of("HSB2", function(raw)
				raw.execution.mode, raw.execution.syncActive = "passthrough", false
			end))
			assert.same({ "SET SYNC_ACTIVE=0", "SET SYNC_MODE=off", "EVENT 2", "EVENT 3" }, trace(mark))
			assert.same({ "stop" }, periods.releases)
		end)

		it("fires Sync Stopped before Power Save, and Powered On before Sync Started", function()
			p = restarted(current)
			local mark = #c4.calls
			local asleep = model_of("HSB2", function(raw)
				raw.execution.mode, raw.execution.syncActive, raw.execution.hdmiActive = "powersave", false, false
			end)
			p:observe(asleep)
			assert.same({ 2, 3, 10 }, events(mark))
			assert.equal("powersave", c4.variables.POWER.value)
			mark = #c4.calls
			p:observe(current)
			assert.same({ 9, 1, 3 }, events(mark))
		end)

		it("fires Intensity Changed and Brightness Changed", function()
			p = restarted(current)
			local mark = #c4.calls
			p:observe(model_of("HSB2", function(raw)
				raw.execution.video.intensity, raw.execution.brightness = "intense", 140
			end))
			assert.same({ "SET INTENSITY=intense", "SET BRIGHTNESS=140", "EVENT 4", "EVENT 5" }, trace(mark))
		end)

		it("fires HDMI Input Changed from any cause, with the input's name set first, and releases the hold",
			function()
				p = restarted(current)
				local mark = #c4.calls
				p:observe(model_of("HSB2", function(raw) raw.execution.hdmiSource = "input2" end), nil, "read")
				assert.same({ "SET HDMI_INPUT=2", "SET HDMI_INPUT_NAME=PlayStation", "EVENT 6" }, trace(mark))
				assert.same({ "source" }, periods.releases)
			end)

		it("sets HDMI_INPUT_NAME without an event when only the input's name changes", function()
			p = restarted(current)
			local mark = #c4.calls
			p:observe(model_of("HSB2", function(raw) raw.hdmi.input1.name = "Apple TV 4K" end))
			assert.same({ "SET HDMI_INPUT_NAME=Apple TV 4K" }, trace(mark))
		end)

		it("fires Entertainment Area Changed for another area, not for a rename of the same one", function()
			p = restarted(current)
			local mark = #c4.calls
			p:observe(model_of("HSB2", function(raw) raw.hue.groups[F.AREA.tv].name = "Lounge TV" end))
			assert.same({ "SET ENTERTAINMENT_AREA=Lounge TV" }, trace(mark))
			mark = #c4.calls
			p:observe(model_of("HSB2", function(raw) raw.execution.hueTarget = F.AREA.office end))
			assert.same({ "SET ENTERTAINMENT_AREA=Office", "EVENT 7" }, trace(mark))
		end)

		it("fires Sync Taken Over only for the take-over's read, and only when the box syncs", function()
			p = restarted(model_of("HSB1"))
			local mark = #c4.calls
			local syncing = model_of("HSB1", function(raw) raw.execution.mode, raw.execution.syncActive = "video", true end)
			p:observe(syncing, nil, "takeover")
			assert.same({ 1, 3, 4, 8 }, events(mark))
			mark = #c4.calls
			p:observe(syncing, nil, "read")
			assert.same({}, events(mark))
			p:observe(model_of("HSB1"), nil, "takeover")
			assert.same({ 2, 3, 4 }, events(mark), "no take-over while the box does not sync")
			mark = #c4.calls
			p:observe(syncing, nil, "takeover")
			assert.same({ 1, 3, 4, 8 }, events(mark), "the take-over after the sync started in an earlier read")
		end)

		it("fires Sync Taken Over once when the take-over's observe comes after the read's (either order)", function()
			p = restarted(model_of("HSB1"))
			local syncing = model_of("HSB1", function(raw) raw.execution.mode, raw.execution.syncActive = "video", true end)
			local mark = #c4.calls
			p:observe(syncing, nil, "read")
			p:observe(syncing, nil, "takeover")
			assert.same({ 1, 3, 4, 8 }, events(mark))
		end)

		it("fires Offline and Online, and keeps an outage across a restart", function()
			p = restarted(current)
			local mark = #c4.calls
			p:online(false)
			assert.same({ "SET ONLINE=0", "EVENT 12" }, trace(mark))
			local stored = c4.persist[programming.PERSIST_KEY]
			c4 = fake.install_c4()
			c4.persist[programming.PERSIST_KEY] = stored
			p = new_p()
			p:init()
			assert.equal("0", c4.variables.ONLINE.value)
			p:online(false)
			assert.same({}, trace(), "no second Offline after the restart")
			p:observe(current)
			assert.same({ "SET ONLINE=1", "EVENT 11" }, trace())
		end)

		it("takes the first Offline after an install as a baseline too", function()
			p:init()
			p:online(false)
			assert.same({}, c4.events_fired)
			p:observe(current)
			assert.same({ 11 }, c4.events_fired)
		end)

		it("keeps a variable when the read lacks its field or names a value none of ours does", function()
			p = restarted(current)
			local mark = #c4.calls
			p:observe(model_of("HSB2", function(raw)
				raw.execution.mode = "ambient"
				raw.execution.brightness = nil
				raw.execution.video.intensity = "dazzling"
			end))
			assert.same({}, trace(mark))
		end)

		it("hands the changed names and the values to the change callback, after the events", function()
			local seen = {}
			p = new_p({ changed = function(names, values)
				seen[#seen + 1] = { names = names, sync = values.SYNC_ACTIVE, fired = #c4.events_fired }
			end })
			p:init()
			p:observe(current)
			seen = {}
			p:observe(model_of("HSB2", function(raw) raw.execution.mode, raw.execution.syncActive = "passthrough", false end))
			assert.same({ { names = { "SYNC_ACTIVE", "SYNC_MODE" }, sync = "0", fired = 2 } }, seen)
			p:observe(model_of("HSB2", function(raw) raw.execution.mode, raw.execution.syncActive = "passthrough", false end))
			assert.equal(1, #seen, "nothing changed, no callback")
		end)

		it("ignores a read that is not a model", function()
			p:init()
			assert.is_false(p:observe(nil))
			assert.same({}, trace())
		end)
	end)

	describe("commands (C1.6)", function()
		before_each(function()
			current = model_of("HSB1") -- passthrough on HDMI 2, brightness 120, last sync mode music
			p:init()
		end)

		it("Start Sync: syncActive with the period's intensity and brightness (design 5.3)", function()
			assert.is_true(p:command("Start Sync", {}))
			assert.same({ syncActive = true, intensity = "moderate", brightness = 90 }, sq:last())
			assert.same({ period = "evening", mode = "music" }, periods.asked)
			assert.same({}, periods.holds, "starting is no manual adjustment")
		end)

		it("Start Sync leaves out what the periods hold", function()
			periods.held_now = { brightness = true }
			p:command("Start Sync", {})
			assert.same({ syncActive = true, intensity = "moderate" }, sq:last())
		end)

		it("Start Sync takes the driver's own period function when it is given", function()
			p = new_p({ period = function(mode) return { intensity = "intense", brightness = "70", mode = mode } end })
			p:command("Start Sync")
			assert.same({ syncActive = true, intensity = "intense", brightness = 70 }, sq:last())
		end)

		it("Start Sync while syncing sends only syncActive", function()
			current = model_of("HSB2")
			p:command("Start Sync", {})
			assert.same({ syncActive = true }, sq:last())
		end)

		it("Start Sync without periods sends only syncActive", function()
			p = new_p({ periods = false })
			p:command("Start Sync", {})
			assert.same({ syncActive = true }, sq:last())
		end)

		it("Stop Sync", function()
			p:command("Stop Sync", {})
			assert.same({ syncActive = false }, sq:last())
		end)

		it("Toggle Sync starts from passthrough, stops while syncing, and counts a start not yet read", function()
			p:command("Toggle Sync", {})
			assert.is_true(sq:last().syncActive)
			p:command("Toggle Sync", {})
			assert.same({ syncActive = false }, sq:last(), "the start is pending: the toggle stops it")
			current = model_of("HSB2")
			sq.sets = {}
			p:command("Toggle Sync", {})
			assert.same({ syncActive = false }, sq:last())
		end)

		it("Toggle Sync from power save starts (syncActive wakes the box, SB32)", function()
			current = model_of("HSB3")
			p:command("Toggle Sync")
			assert.is_true(sq:last().syncActive)
		end)

		it("Set Sync Mode: the mode, and the period's settings when it starts the sync", function()
			p:command("Set Sync Mode", { Mode = "Game" })
			assert.same({ mode = "game", intensity = "moderate", brightness = 90 }, sq:last())
			assert.same("game", periods.asked.mode)
		end)

		it("Set Sync Mode while syncing carries the period's intensity, or the held one, to the new mode", function()
			current = model_of("HSB2")
			p:command("Set Sync Mode", { Mode = "game" })
			assert.same({ mode = "game", intensity = "moderate" }, sq:last())
			periods.held_now = { intensity = true }
			p:command("Set Sync Mode", { Mode = "music" })
			assert.same({ mode = "music", intensity = "moderate" }, sq:last(), "the pending write's intensity")
			sq.sets = {}
			p:command("Set Sync Mode", { Mode = "music" })
			assert.same({ mode = "music", intensity = "high" }, sq:last(), "the read's (video at high)")
		end)

		it("Set Sync Mode refuses a mode it does not know, in Last Action", function()
			assert.is_false(p:command("Set Sync Mode", { Mode = "Ambient" }))
			assert.same({}, sq.sets)
			assert.same({ "Set Sync Mode not done: Mode must be Video, Music or Game, not Ambient" }, actions)
		end)

		it("Set Intensity: the intensity on its own, held", function()
			p:command("Set Intensity", { Intensity = "Intense" })
			assert.same({ intensity = "intense" }, sq:last())
			assert.same({ "intensity" }, periods.holds)
			assert.is_false(p:command("Set Intensity", { Intensity = "Max" }))
			assert.equal(1, #sq.sets)
		end)

		it("Next Intensity steps Subtle, Moderate, High, Intense, Subtle from the last value asked for", function()
			current = model_of("HSB2") -- video at high
			local seen = {}
			for _ = 1, 5 do
				p:command("Next Intensity")
				seen[#seen + 1] = sq:last().intensity
			end
			assert.same({ "intense", "subtle", "moderate", "high", "intense" }, seen)
			assert.same({ "intensity", "intensity", "intensity", "intensity", "intensity" }, periods.holds)
		end)

		it("Set Brightness takes 0 to 200 and refuses the rest", function()
			p:command("Set Brightness", { Brightness = "0" })
			assert.same({ brightness = 0 }, sq:last())
			p:command("Set Brightness", { Brightness = "200" })
			assert.same({ brightness = 200 }, sq:last())
			assert.same({ "brightness", "brightness" }, periods.holds)
			for _, bad in ipairs({ "201", "-1", "12.5", "bright", "" }) do
				assert.is_false(p:command("Set Brightness", { Brightness = bad }))
			end
			assert.equal(2, #sq.sets)
			assert.equal("Set Brightness not done: Brightness must be 0 to 200 %, not 201", actions[1])
		end)

		it("Adjust Brightness steps from the pending value and clamps to 0 to 200", function()
			p:command("Adjust Brightness", { Step = "10" })
			assert.same({ brightness = 130 }, sq:last())
			p:command("Adjust Brightness", { Step = "10" })
			assert.same({ brightness = 140 }, sq:last(), "from the write not yet read, not the read's 120")
			p:command("Adjust Brightness", { Step = "200" })
			assert.same({ brightness = 200 }, sq:last())
			sq.sets = {}
			p:command("Adjust Brightness", { Step = "-200" })
			assert.same({ brightness = 0 }, sq:last())
			assert.is_false(p:command("Adjust Brightness", { Step = "250" }))
			assert.is_false(p:command("Adjust Brightness", { Step = "x" }))
		end)

		it("Adjust Brightness starts from 100 when no read gave a brightness", function()
			current = nil
			p:command("Adjust Brightness", { Step = "-10" })
			assert.same({ brightness = 90 }, sq:last())
		end)

		it("Set Entertainment Area by the area's name (any case) or id", function()
			p:command("Set Entertainment Area", { Area = "Office" })
			assert.same({ hueTarget = F.AREA.office }, sq:last())
			p:command("Set Entertainment Area", { Area = "living room tv" })
			assert.same({ hueTarget = F.AREA.tv }, sq:last())
			p:command("Set Entertainment Area", { Area = F.AREA.office })
			assert.same({ hueTarget = F.AREA.office }, sq:last())
		end)

		it("Set Entertainment Area refuses an area the box does not list, and two of one name", function()
			assert.is_false(p:command("Set Entertainment Area", { Area = "Kitchen" }))
			assert.equal("Set Entertainment Area not done: the box has no entertainment area named Kitchen", actions[1])
			current = model_of("HSB1", function(raw) raw.hue.groups[F.AREA.office].name = "Living Room TV" end)
			assert.is_false(p:command("Set Entertainment Area", { Area = "Living Room TV" }))
			assert.equal("Set Entertainment Area not done: 2 entertainment areas are named Living Room TV; "
				.. "rename one in the Hue app", actions[2])
			current = model_of("HSB3_standalone")
			assert.is_false(p:command("Set Entertainment Area", { Area = "Office" }))
			assert.equal("Set Entertainment Area not done: the box lists no entertainment areas yet", actions[3])
			assert.same({}, sq.sets)
		end)

		it("Set Entertainment Area takes the areas module's values (area:<id>, re-points followed)", function()
			-- syncbox/areas.lua's resolve as its header documents it.
			local NEW = "6a7b8c9d-0000-4000-8000-0000000ea009"
			local areas = { resolve = function(_, v)
				if v == "area:" .. F.AREA.tv then return NEW, "Living Room TV" end
				return nil, "Not set: the entertainment area Den was deleted in Hue"
			end }
			p = new_p({ areas = function() return areas end })
			p:command("Set Entertainment Area", { Area = "area:" .. F.AREA.tv })
			assert.same({ hueTarget = NEW }, sq:last())
			p:command("Set Entertainment Area", { Area = "Office" })
			assert.same({ hueTarget = F.AREA.office }, sq:last(), "a name the box lists needs no module")
			p:command("Set Entertainment Area", { Area = "area:" .. F.AREA.office })
			p:command("Set Entertainment Area", { Area = "Den" })
			assert.same({ "Not set: the entertainment area Den was deleted in Hue",
				"Set Entertainment Area not done: the box has no entertainment area named Den" }, actions)
			assert.equal(2, #sq.sets)
		end)

		it("Apply Sync Settings resolves its Area the same way, in its one write", function()
			local areas = { resolve = function(_, v)
				if v == "area:" .. F.AREA.office then return F.AREA.office, "Office" end
				return nil, "Not set: no entertainment area was chosen in this programming line"
			end }
			p = new_p({ areas = areas })
			p:command("Apply Sync Settings", { Area = "area:" .. F.AREA.office, Start = "Stop" })
			assert.same({ hueTarget = F.AREA.office, syncActive = false }, sq:last())
		end)

		it("Apply Sync Settings: every field in one write, the area and the mode with its intensity", function()
			assert.is_true(p:command("Apply Sync Settings", { Mode = "Video", Intensity = "High", Brightness = "150",
				Area = "Office", Start = "Start" }))
			assert.equal(1, #sq.sets)
			assert.same({ mode = "video", intensity = "high", brightness = 150, hueTarget = F.AREA.office }, sq:last())
			assert.same({ "intensity", "brightness" }, periods.holds)
		end)

		it("Apply Sync Settings leaves each field given as Leave (or empty, or a negative brightness)", function()
			p:command("Apply Sync Settings", { Mode = "Leave", Intensity = "Leave", Brightness = "-1", Area = "Leave",
				Start = "Start" })
			assert.same({ syncActive = true, intensity = "moderate", brightness = 90 }, sq:last(),
				"a start carries the period's settings")
			p:command("Apply Sync Settings", { Intensity = "Subtle", Start = "Leave" })
			assert.same({ intensity = "subtle" }, sq:last())
			p:command("Apply Sync Settings", { Brightness = "60 %" })
			assert.same({ brightness = 60 }, sq:last())
		end)

		it("Apply Sync Settings with Stop leaves the mode and says so", function()
			current = model_of("HSB2")
			p:command("Apply Sync Settings", { Mode = "Game", Intensity = "Subtle", Start = "Stop" })
			assert.same({ syncActive = false, intensity = "subtle" }, sq:last())
			sq:finish(1, true)
			assert.same({ "Sync settings applied: sync stopped, subtle, the mode is left (Stop leaves the box not "
				.. "syncing)" }, actions)
		end)

		it("Apply Sync Settings with nothing to apply, or a value it does not take, sends nothing", function()
			assert.is_false(p:command("Apply Sync Settings", { Mode = "Leave", Start = "Leave" }))
			assert.is_false(p:command("Apply Sync Settings", { Start = "Maybe" }))
			assert.is_false(p:command("Apply Sync Settings", { Brightness = "300" }))
			assert.is_false(p:command("Apply Sync Settings", { Area = "Kitchen" }))
			assert.same({}, sq.sets)
			assert.same({ programming.TEXT.NOTHING,
				"Apply Sync Settings not done: Start must be Leave, Start or Stop, not Maybe",
				"Apply Sync Settings not done: Brightness must be Leave or 0 to 200 %, not 300",
				"Apply Sync Settings not done: the box has no entertainment area named Kitchen" }, actions)
		end)

		it("Power Save and Wake", function()
			p:command("Power Save")
			assert.same({ mode = "powersave" }, sq:last())
			p:command("Wake")
			assert.same({ hdmiActive = true }, sq:last())
		end)

		it("Select HDMI Input switches only the input, and Last Action warns that the room does not follow",
			function()
				p:command("Select HDMI Input", { Input = "HDMI 1" })
				assert.same({ hdmiSource = "input1" }, sq:last())
				sq:finish(1, true)
				assert.same({ "HDMI 1 (Blu-ray) selected: the Control4 room does not follow it" }, actions)
			end)

		it("Select HDMI Input refuses an input the box lacks (HSB3) or does not name", function()
			current = model_of("HSB3")
			assert.is_false(p:command("Select HDMI Input", { Input = "HDMI 2" }))
			assert.is_false(p:command("Select HDMI Input", { Input = "HDMI 9" }))
			assert.same({}, sq.sets)
			assert.equal("Not switched: this box has 1 HDMI input", actions[1])
			assert.is_true(p:command("Select HDMI Input", { Input = "HDMI 1" }))
		end)

		it("takes the names with underscores and in any case, and refuses a command it does not know", function()
			assert.is_true(p:command("Set_Sync_Mode", { Mode = "music" }))
			assert.is_true(p:command("POWER SAVE"))
			assert.is_false(p:command("Make Coffee", {}))
		end)

		it("says the driver is still starting when the queue is not built yet", function()
			p = new_p({ queue = function() return nil end })
			assert.is_false(p:command("Wake"))
			assert.same({ "Not turned on: the driver is still starting" }, actions)
		end)

		it("says what the queue refused", function()
			sq.refuse = "the queue does not take hueTarget=x"
			assert.is_false(p:command("Stop Sync"))
			assert.same({ "Not stopped: the queue does not take hueTarget=x" }, actions)
			assert.same({}, periods.holds)
		end)

		describe("outcomes in Last Action", function()
			it("says what landed once a read shows it", function()
				p:command("Set Brightness", { Brightness = "110" })
				p:command("Set Sync Mode", { Mode = "Video" })
				p:command("Set Entertainment Area", { Area = "Office" })
				assert.same({}, actions, "nothing before the read")
				sq:finish(1, true)
				sq:finish(2, true)
				sq:finish(3, true)
				assert.same({ "Brightness 110 %", "Syncing video", "Entertainment area Office" }, actions)
			end)

			it("is quiet for a write a later one replaced, or one cancelled", function()
				p:command("Adjust Brightness", { Step = "10" })
				p:command("Adjust Brightness", { Step = "10" })
				sq:finish(1, false, "superseded")
				sq:finish(2, false, "cancelled")
				assert.same({}, actions)
			end)

			it("words each failure", function()
				p:command("Wake")
				p:command("Power Save")
				p:command("Stop Sync")
				p:command("Set Intensity", { Intensity = "High" })
				sq:finish(1, false, "not landed")
				sq:finish(2, false, "refused", "code 15")
				sq:finish(3, false, "not sent", "not paired")
				sq:finish(4, false, "not sent", "the client is busy")
				assert.same({ "Not turned on: the box did not wake from power save",
					"Not turned off: the box refused it (code 15)",
					"Not stopped: the box is not paired; run Pair Sync Box",
					"Intensity not changed: the client is busy" }, actions)
			end)

			it("hands a busy sync start to the take-over, else says the box is busy", function()
				busy.handle = true
				p:command("Start Sync")
				sq:finish(1, false, "busy")
				assert.same({}, actions)
				assert.equal(1, #busy)
				assert.is_true(busy[1].fields.syncActive)
				assert.same("programming", busy[1].tag.kind)
				busy.handle = false
				p:command("Set Sync Mode", { Mode = "Game" })
				sq:finish(2, false, "busy")
				assert.same({ "Sync mode not changed: " .. programming.TEXT.BUSY }, actions)
			end)
		end)
	end)

	describe("the UI Buttons (C1.1, design 5.6)", function()
		before_each(function()
			current = model_of("HSB2")
			p:init()
		end)

		it("Hue Sync toggles, Brighter and Dimmer step by 10, Sync Intensity steps the intensity", function()
			p:button("Hue Sync")
			assert.same({ syncActive = false }, sq:last())
			p:button("Sync Brighter")
			assert.same({ brightness = 110 }, sq:last())
			p:button("Sync Dimmer")
			p:button("Sync Dimmer")
			assert.same({ brightness = 90 }, sq:last())
			p:button("Sync Intensity")
			assert.same({ intensity = "intense" }, sq:last())
			assert.is_false(p:button("Sync Louder"))
		end)

		it("Brighter stops at 200 and Dimmer at 0", function()
			current = model_of("HSB2", function(raw) raw.execution.brightness = 195 end)
			p:button("Sync Brighter")
			p:button("Sync Brighter")
			assert.same({ brightness = 200 }, sq:last())
		end)

		it("gives the icons' states from the variables", function()
			p:observe(current)
			assert.equal("on", p:icon_state("Hue Sync"))
			assert.equal("high", p:icon_state("Sync Intensity"))
			assert.is_nil(p:icon_state("Sync Brighter"))
			p:observe(model_of("HSB2", function(raw) raw.execution.mode, raw.execution.syncActive = "passthrough", false end))
			assert.equal("off", p:icon_state("Hue Sync"))
		end)
	end)

	describe("conditionals (C1.8)", function()
		before_each(function()
			p:init()
			p:observe(current) -- HSB2: syncing video, high, 100, HDMI 1, on, online
		end)

		it("Sync Active, Powered On and Online as BOOL, by the true and false texts", function()
			assert.is_true(p:test("BOOL_SYNC_ACTIVE", { VALUE = "True" }))
			assert.is_false(p:test("BOOL_SYNC_ACTIVE", { VALUE = "False" }))
			assert.is_false(p:test("BOOL_SYNC_ACTIVE", { VALUE = "True", LOGIC = "NOT_EQUAL" }))
			assert.is_true(p:test("BOOL_SYNC_ACTIVE", {}), "no VALUE: is it true")
			assert.is_true(p:test("BOOL_POWERED_ON", { VALUE = "True" }))
			assert.is_true(p:test("BOOL_ONLINE", { VALUE = "True" }))
			assert.is_false(p:test("BOOL_ONLINE", { VALUE = "Maybe" }))
			p:observe(model_of("HSB3"))
			assert.is_true(p:test("BOOL_POWERED_ON", { VALUE = "False" }))
			assert.is_false(p:test("BOOL_SYNC_ACTIVE", { VALUE = "True" }))
			p:online(false)
			assert.is_true(p:test("Online", { VALUE = "False" }), "by the contract's label too")
		end)

		it("Sync Mode as a LIST, Off when not syncing", function()
			assert.is_true(p:test("LIST_SYNC_MODE", { VALUE = "Video", LOGIC = "EQUAL" }))
			assert.is_false(p:test("LIST_SYNC_MODE", { VALUE = "Game", LOGIC = "EQUAL" }))
			assert.is_true(p:test("LIST_SYNC_MODE", { VALUE = "Game", LOGIC = "NOT_EQUAL" }))
			assert.is_false(p:test("LIST_SYNC_MODE", { VALUE = "Music", LOGIC = "LESS_THAN" }), "the modes have no order")
			p:observe(model_of("HSB1"))
			assert.is_true(p:test("Sync Mode", { VALUE = "Off", LOGIC = "EQUAL" }))
		end)

		it("Intensity as a LIST, in its order", function()
			assert.is_true(p:test("LIST_INTENSITY", { VALUE = "High", LOGIC = "EQUAL" }))
			assert.is_true(p:test("LIST_INTENSITY", { VALUE = "Moderate", LOGIC = "GREATER_THAN" }))
			assert.is_false(p:test("LIST_INTENSITY", { VALUE = "Intense", LOGIC = "GREATER_THAN_OR_EQUAL" }))
			assert.is_false(p:test("LIST_INTENSITY", { VALUE = "Loud", LOGIC = "EQUAL" }))
		end)

		it("HDMI Input as a LIST", function()
			assert.is_true(p:test("LIST_HDMI_INPUT", { VALUE = "HDMI 1", LOGIC = "EQUAL" }))
			assert.is_true(p:test("LIST_HDMI_INPUT", { VALUE = "HDMI 3", LOGIC = "NOT_EQUAL" }))
			assert.is_true(p:test("HDMI Input", { VALUE = "HDMI 2", LOGIC = "LESS_THAN" }))
		end)

		it("Brightness as a NUMBER with every operator", function()
			local cases = { EQUAL = { 100, true }, NOT_EQUAL = { 100, false }, LESS_THAN = { 101, true },
				LESS_THAN_OR_EQUAL = { 99, false }, GREATER_THAN = { 99, true }, GREATER_THAN_OR_EQUAL = { 100, true } }
			for logic, case in pairs(cases) do
				assert.equal(case[2], p:test("NUMBER_BRIGHTNESS", { VALUE = tostring(case[1]), LOGIC = logic }), logic)
			end
			assert.is_false(p:test("NUMBER_BRIGHTNESS", { VALUE = "x", LOGIC = "EQUAL" }))
			assert.is_false(p:test("NUMBER_BRIGHTNESS", { VALUE = "100", LOGIC = "ABOUT" }))
		end)

		it("answers false for a conditional it does not have", function()
			assert.is_false(p:test("BOOL_RAINING", { VALUE = "True" }))
		end)

		it("an intensity not known yet equals nothing", function()
			c4 = fake.install_c4()
			p = new_p()
			p:init()
			assert.is_false(p:test("LIST_INTENSITY", { VALUE = "High", LOGIC = "EQUAL" }))
			assert.is_true(p:test("LIST_INTENSITY", { VALUE = "High", LOGIC = "NOT_EQUAL" }))
			assert.is_false(p:test("LIST_INTENSITY", { VALUE = "High", LOGIC = "LESS_THAN" }))
		end)
	end)

	describe("GetCommandParamList (the Area parameters)", function()
		it("lists the box's areas by name, with Leave first for Apply Sync Settings", function()
			assert.same({ "Living Room TV", "Office" }, p:param_list("Set Entertainment Area", "Area"))
			assert.same({ "Leave", "Living Room TV", "Office" }, p:param_list("Apply Sync Settings", "Area"))
			assert.same({}, p:param_list("Set Sync Mode", "Mode"))
			current = nil
			assert.same({}, p:param_list("Set Entertainment Area", "Area"))
		end)

		it("takes the areas module's names when it has them", function()
			p = new_p({ areas = { names = function() return { "Lounge" } end } })
			assert.same({ "Lounge" }, p:param_list("Set_Entertainment_Area", "Area"))
		end)
	end)

	describe("manual changes (design 5.3)", function()
		it("holds intensity and brightness only", function()
			assert.is_true(p:manual("intensity"))
			assert.is_true(p:manual("brightness"))
			assert.is_false(p:manual("mode"))
			assert.same({ "intensity", "brightness" }, periods.holds)
			p = new_p({ periods = nil })
			p.deps.periods = nil
			assert.is_false(p:manual("intensity"))
		end)
	end)

	describe("end to end against the Lua fake box (queue, client and poller)", function()
		local queue, h, c, poll, q

		local function rig(fixture)
			for _, m in ipairs({ "common.https", "syncbox.client", "syncbox.poller", "syncbox.queue" }) do
				package.loaded[m] = nil
			end
			local clientmod, pollermod = require("syncbox.client"), require("syncbox.poller")
			queue = require("syncbox.queue")
			h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN }, state = fixture and F.state[fixture] })
			local timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end
			local now = function() return c4:GetTime() end
			c = clientmod.new({ address = F.ADDRESS, token = F.TOKEN, log = log, timer = timer, now = now })
			c:set_trusted(true)
			poll = pollermod.new({ client = c, timer = timer, now = now, log = log,
				on_state = function(m)
					q:observe(m)
					p:observe(m, nil, "read")
				end })
			q = queue.new({ client = c, poller = poll, timer = timer, now = now, log = log })
			p = new_p({ queue = q, model_now = function() return poll:last_model() end })
			p:init()
			poll:start()
			c4.advance(1000)
		end

		local function puts()
			return h:requests_of("PUT", "/api/v1/execution")
		end

		it("Apply Sync Settings is one PUT, the mode's intensity inside its object, then the events", function()
			rig("HSB1")
			assert.same({}, c4.events_fired, "the first read is a baseline")
			local before = #puts()
			p:command("Apply Sync Settings", { Mode = "Game", Intensity = "Intense", Brightness = "150",
				Area = "Office", Start = "Start" })
			c4.advance(queue.COALESCE_MS)
			assert.equal(before + 1, #puts())
			assert.same({ mode = "game", game = { intensity = "intense" }, brightness = 150,
				hueTarget = F.AREA.office }, puts()[#puts()].json)
			c4.advance(1000)
			assert.equal("game", h:value("execution.mode"))
			assert.equal("intense", h:value("execution.game.intensity"))
			assert.same({ "Sync settings applied: game, intense, brightness 150 %, on Office" }, actions)
			assert.same({ 1, 3, 4, 5, 7 }, c4.events_fired)
			assert.equal("1", c4.variables.SYNC_ACTIVE.value)
			assert.equal("Office", c4.variables.ENTERTAINMENT_AREA.value)
		end)

		it("three Sync Brighter presses become one PUT of the last value", function()
			rig("HSB2")
			local before = #puts()
			p:button("Sync Brighter")
			p:button("Sync Brighter")
			p:button("Sync Brighter")
			c4.advance(queue.COALESCE_MS)
			assert.equal(before + 1, #puts())
			assert.same({ brightness = 130 }, puts()[#puts()].json)
			c4.advance(1000)
			assert.equal(130, h:value("execution.brightness"))
			assert.same({ "Brightness 130 %" }, actions)
			assert.same({ 5 }, c4.events_fired)
			assert.equal("130", c4.variables.BRIGHTNESS.value)
		end)

		it("a change in the Hue Sync app fires its events with no command", function()
			rig("HSB2")
			assert.equal(200, (h:request("PUT", "/execution", { Authorization = "Bearer " .. F.TOKEN },
				{ hdmiSource = "input2" })))
			c4.advance(5000)
			assert.same({ 6 }, c4.events_fired)
			assert.equal("PlayStation", c4.variables.HDMI_INPUT_NAME.value)
			assert.same({}, actions)
		end)
	end)
end)
