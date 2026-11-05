-- bridge/actions.lua (#334, docs/simplify-actions-design.md §3.3 and §3.4):
-- the pickers and runners of Add From Hue, Link Device, Forget Device,
-- Resolve Names and Diagnostics, against spy modules that answer the public
-- methods the real ones have (bridge/lights.lua, scenes.lua, zone_lights.lua,
-- motion.lua, owner.lua) and names.lua's resolve_rows / resolve. Folders as
-- the house showed them (§2.3): the list function gets the folder value, ""
-- at the top, and answers list, back; one pick per picker; the two pickers
-- of an action never see each other, so the runner checks the pair.

local log = require("common.log")
local actions = require("bridge.actions")

-- The spy world --------------------------------------------------------------

local function empty(text) return { { text = text, value = "" } } end

local BASE = {
	lights = {
		picker_lights = function()
			return { { text = "Desk Lamp [Office] #3", value = "L1" },
				{ text = "Porch Light [Porch] #4 (deleted from Composer 10-22)", value = "L2" } }
		end,
		picker_rooms = function(_, mode)
			assert(mode == "add", "the Room picker is picker_rooms(\"add\")")
			return { { text = "(mapped room)", value = "mapped" }, { text = "Main / Office", value = "7" } }
		end,
		picker_relink_devices = function()
			return { { text = "Old Lamp (device 1001, gone since 10-24)", value = "1001" } }
		end,
		picker_forget_devices = function()
			return { { text = "Old Lamp #1 (device 1001) gone", value = "1001" },
				{ text = "Desk #2 (device 1002)", value = "1002" } }
		end,
		add_light = function(_, _, _, done) done(true, "Added Desk Lamp to Office (device 2001)") return true end,
		import_new = function(_, done) done(true, "Imported 1 light") return true end,
		relink = function(_, id, rid) return true, string.format("Re-linked device %d to %s", id, rid) end,
		forget = function(_, id) return true, string.format("Forgot light device %d", id) end,
		link_devices = function() return "All 2 bound lights are registered" end,
		new_count = function() return 1 end,
		bridge_count = function() return 2 end,
		adopt_hue_names = function() return "Renamed 1 light" end,
		accept_names = function() return "Kept 1 light name" end,
	},
	zone_lights = {
		picker_groups = function() return { { text = "Attic (zone, 2 lights)", value = "G1" } } end,
		picker_relink_devices = function() return {} end,
		picker_forget_devices = function() return { { text = "Attic (zone light, device 1101)", value = "1101" } } end,
		add = function(_, _, _, done) done(true, "Added Attic") return true end,
		relink = function(_, id, rid) return true, string.format("Re-linked zone light %d to %s", id, rid) end,
		forget = function(_, id) return true, string.format("Forgot zone light %d", id) end,
		link_devices = function() return "No zone lights are bound to this bridge" end,
		device_ids = function() return { [1101] = true } end,
		adopt_hue_names = function() return "" end,
		accept_names = function() return "" end,
	},
	scenes = {
		picker_scenes = function()
			return { { text = "Kitchen: Relax", value = "S1" }, { text = "Kitchen: Bright (dynamic)", value = "S2" },
				{ text = "Attic (zone): Night", value = "S3" } }
		end,
		record_of = function(_, rid)
			return ({ S1 = { group_rid = "R1" }, S2 = { group_rid = "R1" }, S3 = { group_rid = "Z1" } })[rid]
		end,
		group_label = function(_, g) return ({ R1 = "Kitchen", Z1 = "Attic (zone)" })[g] end,
		picker_relink_devices = function()
			return { { text = "Kitchen: Old (device 1201, gone since 10-20)", value = "1201" } }
		end,
		picker_forget_devices = function() return { { text = "Kitchen: Old (device 1201) gone", value = "1201" } } end,
		add_scene = function(_, _, _, done) done(true, "Added Relax") return true end,
		add_all_of_group = function(_, _, done) done(true, "Added 2 scenes of Kitchen") return true end,
		relink = function(_, id, rid) return true, string.format("Re-linked scene %d to %s", id, rid) end,
		forget = function(_, id) return true, string.format("Forgot scene %d", id) end,
		link_devices = function() return "No scene devices are bound" end,
		adopt_hue_names = function() return "" end,
		accept_names = function() return "" end,
	},
	motion = {
		picker_sensors = function() return { { text = "Hall sensor [Hall] #31", value = "M1" } } end,
		picker_areas = function() return { { text = "Kitchen area (MotionAware) [Kitchen]", value = "A1" } } end,
		new_records = function(_, kind) return kind == "sensor" and { {} } or {} end,
		picker_relink_devices = function()
			return { { text = "Hall sensor (device 1301, gone since 10-25)", value = "1301" } }
		end,
		picker_forget_devices = function() return { { text = "Hall sensor (device 1301)", value = "1301" } } end,
		add = function(_, _, _, done) done(true, "Added Hall sensor") return true end,
		import_new = function(_, done) done(true, "Imported 1 motion sensor") return true end,
		relink = function(_, id, rid) return true, string.format("Re-linked motion device %d to %s", id, rid) end,
		forget = function(_, id) return true, string.format("Forgot motion device %d", id) end,
		link_devices = function() return "No motion devices are bound" end,
		adopt_hue_names = function() return "" end,
		accept_names = function() return "" end,
	},
	names = {
		resolve_rows = function()
			return { { text = "Composer names to Hue (all 2)", value = "names:composer_to_hue" },
				{ text = "Hue names to Composer (all 2)", value = "names:hue_to_composer" },
				{ text = "Desk #2: rename to Desk Lamp", value = "row:1002:hue" } }
		end,
		resolve = function(_, value, done) done(true, "Resolved " .. value) end,
	},
}

local KEYS = { "lights", "zone_lights", "scenes", "motion", "names" }

-- opts: [module] = false (absent) or { method = fn | false }, paired = false,
-- diagnostics, dev.
local function world(opts)
	opts = opts or {}
	local w = { calls = {}, said = {}, logs = {} }
	local ctx = { diagnostics = opts.diagnostics, dev = opts.dev }
	for _, key in ipairs(KEYS) do
		if opts[key] ~= false then
			local m = {}
			local methods = {}
			for name, fn in pairs(BASE[key]) do methods[name] = fn end
			for name, fn in pairs(opts[key] or {}) do methods[name] = fn or nil end
			for name, fn in pairs(methods) do
				m[name] = function(self, ...)
					w.calls[#w.calls + 1] = { name = key .. ":" .. name, args = { ... } }
					return fn(self, ...)
				end
			end
			ctx[key] = m
		end
	end
	ctx.last_action = function(text) w.said[#w.said + 1] = text end
	ctx.can = function()
		if opts.paired == false then
			ctx.last_action("Not paired")
			return false
		end
		return true
	end
	ctx.log = {
		always = function(fmt, ...) w.logs[#w.logs + 1] = "always " .. string.format(fmt, ...) end,
		info = function() end, debug = function() end,
		warn = function(fmt, ...) w.logs[#w.logs + 1] = "warn " .. string.format(fmt, ...) end,
		error = function(fmt, ...) w.logs[#w.logs + 1] = "error " .. string.format(fmt, ...) end,
	}
	w.ctx = ctx
	w.a = actions.new(ctx)
	-- The calls of one method (its args), in order.
	function w.of(name)
		local out = {}
		for _, c in ipairs(w.calls) do
			if c.name == name then out[#out + 1] = c.args end
		end
		return out
	end
	function w.last() return w.said[#w.said] end
	-- The module calls that act (anything but the pickers and look-ups).
	function w.acted()
		local out = {}
		for _, c in ipairs(w.calls) do
			local method = c.name:match(":(.+)$")
			if not method:match("^picker_") and not ({ record_of = true, group_label = true, new_count = true,
				new_records = true, bridge_count = true, device_ids = true, suggested = true, resolve_rows = true })[method] then
				out[#out + 1] = c.name
			end
		end
		return out
	end
	return w
end

local function texts(list)
	local out = {}
	for _, e in ipairs(list) do out[#out + 1] = e.text end
	return out
end

local function values(list)
	local out = {}
	for _, e in ipairs(list) do out[#out + 1] = e.value end
	return out
end

-- Every entry under a list function, its folders opened (each once).
local function walk(fn, problems)
	local seen, leaves = {}, {}
	local function visit(folder_value, depth)
		if seen[folder_value] or depth > 4 then return end
		seen[folder_value] = true
		local list, back = fn(folder_value)
		if type(list) ~= "table" or #list == 0 then
			problems[#problems + 1] = string.format("folder %q: no list", folder_value)
			return
		end
		-- The labelled Back row to the top (f:top) opens the top itself.
		local top = folder_value == "" or folder_value == "f:top"
		if top and back ~= nil then problems[#problems + 1] = "the top has a back" end
		if not top and type(back) ~= "string" then
			problems[#problems + 1] = string.format("folder %q: back is %s", folder_value, type(back))
		end
		-- Every folder's list starts with a Back row that says where it goes (§4 finding 14).
		if not top and type(back) == "string" then
			local first = list[1]
			if not (first.folder and first.value == (back == "" and "f:top" or back)
				and first.text:find("^Back to %S")) then
				problems[#problems + 1] = string.format("folder %q: no labelled Back row first (%s)", folder_value,
					tostring(first.text))
			end
		end
		for _, e in ipairs(list) do
			if type(e.text) ~= "string" or e.text == "" then problems[#problems + 1] = "an entry without text" end
			if type(e.value) ~= "string" then problems[#problems + 1] = "a value that is not a string: " .. tostring(e.text) end
			for k in pairs(e) do
				if k ~= "text" and k ~= "value" and k ~= "folder" and k ~= "selectable" then
					problems[#problems + 1] = "an unknown field " .. tostring(k) .. " on " .. tostring(e.text)
				end
			end
			if e.folder then
				if e.selectable then leaves[#leaves + 1] = e end
				visit(e.value, depth + 1)
			else
				leaves[#leaves + 1] = e
			end
		end
	end
	visit("", 0)
	return leaves
end

describe("bridge/actions.lua", function()
	local real_sink
	before_each(function()
		real_sink = log.sink
		log.sink = function() end
	end)
	after_each(function()
		log.sink = real_sink
	end)

	describe("the contract tables", function()
		it("names a list function for every CUSTOM_SELECT parameter and a runner for every action", function()
			for _, action in ipairs(actions.ACTIONS) do
				assert.is_function(actions[action.runner], action.command)
				for _, param in ipairs(action.params) do
					if param.list then
						assert.is_string(actions.LISTS[param.list], param.list)
						assert.is_function(actions[actions.LISTS[param.list]], param.list)
					else
						assert.same({ "No", "Yes, forget" }, param.items)
					end
				end
			end
			assert.equal("Yes, forget", actions.CONFIRM_YES)
			assert.equal("Not forgotten: choose Yes, forget", actions.NOT_CONFIRMED)
		end)

		it("points every alias at a 1.2 bridge action and a runner", function()
			local targets = { ["Import All New"] = true }
			for _, action in ipairs(actions.ACTIONS) do targets[action.command] = true end
			local n = 0
			for old, alias in pairs(actions.ALIASES) do
				n = n + 1
				assert.is_true(targets[alias.target] == true, old .. " → " .. tostring(alias.target))
				assert.is_function(actions[alias.runner], old)
			end
			assert.equal(23, n)
		end)
	end)

	describe("Add From Hue's What (add_list)", function()
		it("opens on one folder per kind, with its count, in a fixed order, and no back", function()
			local w = world()
			local list, back = w.a:add_list("")
			assert.is_nil(back)
			assert.same({ "Lights (2)", "Zones and rooms (1)", "Scenes (3 in 2 rooms)", "Motion sensors and areas (2)" },
				texts(list))
			assert.same({ "f:lights", "f:groups", "f:scenes", "f:motion" }, values(list))
			for _, e in ipairs(list) do
				assert.is_true(e.folder)
				assert.is_nil(e.selectable)
			end
			assert.same(texts(list), texts((w.a:add_list(nil))))
			assert.same({}, w.acted())
		end)

		it("leaves out a folder whose list would be empty, and names motion by what it holds", function()
			local w = world({
				lights = { picker_lights = function() return empty("(every light on the bridge is imported)") end },
				zone_lights = false,
				motion = { picker_areas = function() return empty("(this bridge offers no MotionAware areas)") end },
			})
			assert.same({ "Scenes (3 in 2 rooms)", "Motion sensors (1)" }, texts((w.a:add_list(""))))
			w = world({ motion = { picker_sensors = function() return {} end } })
			assert.equal("MotionAware areas (1)", texts((w.a:add_list("")))[4])
		end)

		it("shows one explanatory row with value \"\" when there is nothing to add", function()
			local none = {
				lights = { picker_lights = function() return empty("(every light on the bridge is imported)") end },
				zone_lights = { picker_groups = function() return empty("(every zone and room on the bridge is imported)") end },
				scenes = { picker_scenes = function() return empty("(every scene on the bridge is imported)") end },
				motion = { picker_sensors = function() return {} end, picker_areas = function() return {} end },
			}
			assert.same({ { text = "(everything on the bridge is in Control4 already)", value = "" } },
				(world(none).a:add_list("")))
			none.lights.bridge_count = function() return 0 end
			none.lights.picker_lights = function() return empty("(no lights fetched yet; Diagnostics ▸ Read everything from "
				.. "the bridge now)") end
			assert.same({ { text = "(no lights fetched yet; Diagnostics ▸ Read everything from the bridge "
				.. "now)", value = "" } },
				(world(none).a:add_list("")))
			local bare = world({ lights = false, zone_lights = false, scenes = false, motion = false })
			local list = bare.a:add_list("")
			assert.equal(1, #list)
			assert.equal("", list[1].value)
		end)

		it("lists the lights after an All row that is Import All New's lights", function()
			local w = world()
			local list, back = w.a:add_list("f:lights")
			assert.equal("", back)
			assert.same({ "Back to all folders", "All 1 new light, each into its mapped room", "Desk Lamp [Office] #3",
				"Porch Light [Porch] #4 (deleted from Composer 10-22)" }, texts(list))
			assert.same({ "f:top", "all:lights", "light:L1", "light:L2" }, values(list))
			assert.is_true(list[1].folder)
			assert.is_nil(list[1].selectable)
			w = world({ lights = { new_count = function() return 0 end } })
			assert.same({ "f:top", "light:L1", "light:L2" }, values((w.a:add_list("f:lights"))))
		end)

		it("lists the zones and rooms, and the motion sensors and areas after their All row", function()
			local w = world()
			local groups, back = w.a:add_list("f:groups")
			assert.equal("", back)
			assert.same({ "f:top", "group:G1" }, values(groups))
			local motion = w.a:add_list("f:motion")
			assert.same({ "f:top", "all:motion", "sensor:M1", "area:A1" }, values(motion))
			assert.equal("All 1 new motion sensor, each into its mapped room", motion[2].text)
		end)

		it("puts the scenes in a selectable folder per room or zone, each opening on its All row", function()
			local w = world()
			local folders, back = w.a:add_list("f:scenes")
			assert.equal("", back)
			assert.same({ "Back to all folders", "Attic (zone): 1 scene", "Kitchen: 2 scenes" }, texts(folders))
			assert.same({ "f:top", "f:scenes:Z1", "f:scenes:R1" }, values(folders))
			for i, e in ipairs(folders) do
				assert.is_true(e.folder)
				assert.equal(i > 1 or nil, e.selectable, "the Back row is never picked")
			end
			local kitchen
			kitchen, back = w.a:add_list("f:scenes:R1")
			assert.equal("f:scenes", back)
			assert.same({ "Back to Scenes", "All scenes of Kitchen not in Control4 yet", "Relax", "Bright (dynamic)" },
				texts(kitchen))
			assert.same({ "f:scenes", "f:scenes:R1", "scene:S1", "scene:S2" }, values(kitchen))
			assert.is_true(kitchen[1].folder)
			assert.is_nil(kitchen[2].folder)
			local gone
			gone, back = w.a:add_list("f:scenes:R9")
			assert.equal("f:scenes", back)
			assert.same({ "f:scenes", "" }, values(gone))
			-- The Back row to the top opens the top (Composer passes its value as the folder).
			local top
			top, back = w.a:add_list("f:top")
			assert.is_nil(back)
			assert.same(texts((w.a:add_list(""))), texts(top))
		end)

		it("answers the top for a value it does not know (a leaf Composer passes back)", function()
			local w = world()
			assert.same(values((w.a:add_list(""))), values((w.a:add_list("light:L1"))))
		end)

		it("answers strings only, every folder with a back, and nothing but text, value, folder, selectable", function()
			local problems = {}
			local w = world()
			local leaves = walk(function(f) return w.a:add_list(f) end, problems)
			assert.same({}, problems)
			local got = {}
			for _, e in ipairs(leaves) do got[e.value] = true end
			for _, v in ipairs({ "all:lights", "light:L1", "light:L2", "group:G1", "f:scenes:R1", "f:scenes:Z1",
				"scene:S1", "scene:S2", "scene:S3", "all:motion", "sensor:M1", "area:A1" }) do
				assert.is_true(got[v] == true, v)
			end
		end)

		it("survives a module whose picker raises: its folder goes, a row says so", function()
			local w = world({ scenes = { picker_scenes = function() error("boom") end } })
			local list = w.a:add_list("")
			assert.same({ "Lights (2)", "Zones and rooms (1)", "Motion sensors and areas (2)",
				"(the scenes could not be listed; see the Lua output)" }, texts(list))
			assert.equal("", list[4].value)
			assert.truthy(w.logs[1]:find("scenes:picker_scenes failed: ", 1, true))
		end)
	end)

	describe("Add From Hue's Room (room_list)", function()
		it("is the lights' picker_rooms(\"add\"), its (mapped room) first", function()
			local w = world()
			assert.same({ { text = "(mapped room)", value = "mapped" }, { text = "Main / Office", value = "7" } },
				(w.a:room_list()))
			assert.same({ { text = "(not ready yet; open the list again)", value = "" } },
				(world({ lights = false }).a:room_list()))
		end)
	end)

	describe("Add From Hue (run_add)", function()
		it("sends each kind to the module method that adds it, with the room picked or the mapping", function()
			local cases = {
				{ { What = "light:L1", Room = "7" }, "lights:add_light", { "L1", 7 } },
				{ { What = "light:L2", Room = "mapped" }, "lights:add_light", { "L2" } },
				{ { What = "group:G1" }, "zone_lights:add", { "G1" } },
				{ { What = "scene:S1", Room = "" }, "scenes:add_scene", { "S1" } },
				{ { What = "sensor:M1" }, "motion:add", { "M1" } },
				{ { What = "area:A1", Room = "7" }, "motion:add", { "A1", 7 } },
				{ { What = "f:scenes:R1" }, "scenes:add_all_of_group", { "R1" } },
				{ { What = "all:lights" }, "lights:import_new", {} },
				{ { What = "all:motion" }, "motion:import_new", {} },
			}
			for _, case in ipairs(cases) do
				local w = world()
				w.a:run_add(case[1])
				assert.same({ case[2] }, w.acted(), case[1].What)
				local args = w.of(case[2])[1]
				for i, want in ipairs(case[3]) do assert.equal(want, args[i], case[1].What) end
				if #case[3] == 1 and case[2] ~= "scenes:add_all_of_group" then
					assert.is_nil(args[2], case[1].What .. ": no room means the mapping")
				end
				assert.equal(1, #w.said)
				assert.is_string(w.last())
			end
		end)

		it("ends in the module's own text", function()
			local w = world()
			w.a:run_add({ What = "light:L1", Room = "7" })
			assert.same({ "Added Desk Lamp to Office (device 2001)" }, w.said)
		end)

		it("refuses, with a reason and no module call, what it cannot do", function()
			local cases = {
				{ {}, "Not added: pick a light, zone, scene or motion sensor under What first" },
				{ { What = "" }, "Not added: pick a light, zone, scene or motion sensor under What first" },
				{ { What = "light:L1", Room = "none" }, "Not added: pick a room under Room, or (mapped room)" },
				{ { What = "all:lights", Room = "7" }, "Not added: all new lights go each into the room its Hue room "
					.. "maps to; set Room to (mapped room), or pick one" },
				{ { What = "f:scenes:R1", Room = "7" }, "Not added: all new scenes of a room or zone go each into the "
					.. "room its Hue room maps to; set Room to (mapped room), or pick one" },
				{ { What = "f:lights" }, "Not added: Lights is a folder; open it and pick one inside" },
				{ { What = "f:scenes" }, "Not added: Scenes is a folder; open it and pick one inside" },
				{ { What = "f:scenes:?" }, "Not added: open this folder and pick one scene" },
				{ { What = "bogus" }, "Not added: \"bogus\" is not something Add From Hue offers; open What again" },
				{ { What = "dev:1001" }, "Not added: \"dev:1001\" is not something Add From Hue offers; open What again" },
			}
			for _, case in ipairs(cases) do
				local w = world()
				w.a:run_add(case[1])
				assert.same({ case[2] }, w.said)
				assert.same({}, w.acted())
			end
		end)

		it("says Not paired (ctx.can) and touches nothing when the bridge is not paired", function()
			local w = world({ paired = false })
			w.a:run_add({ What = "light:L1" })
			assert.same({ "Not paired" }, w.said)
			assert.same({}, w.acted())
		end)

		it("says a part is not ready when its module or method is missing, and turns a raise into Last Action", function()
			local w = world({ zone_lights = false })
			w.a:run_add({ What = "group:G1" })
			assert.same({ "Not added: the zones and rooms are not ready yet; try again in a minute" }, w.said)
			w = world({ lights = { import_new = false } })
			w.a:run_add({ What = "all:lights" })
			assert.same({ "Not added: the lights are not ready yet; try again in a minute" }, w.said)
			w = world({ scenes = { add_scene = function() error("kaputt") end } })
			w.a:run_add({ What = "scene:S1" })
			assert.equal(1, #w.said)
			assert.truthy(w.last():find("^Add From Hue failed: .*kaputt"))
			assert.truthy(w.logs[#w.logs]:find("^error actions: Add From Hue failed"))
		end)
	end)

	describe("Link Device's Device (link_list)", function()
		it("opens on the every-suggestion row, then one folder per kind with devices to link", function()
			local w = world()
			local list, back = w.a:link_list("")
			assert.is_nil(back)
			assert.same({ "Every bound device the bridge does not know yet, by its own id or name", "Lights (1)",
				"Scenes (1)", "Motion sensors and areas (1)" }, texts(list))
			assert.same({ "dev:suggested", "f:lights", "f:scenes", "f:motion" }, values(list))
			local lights
			lights, back = w.a:link_list("f:lights")
			assert.equal("", back)
			assert.same({ { text = "Back to all folders", value = "f:top", folder = true },
				{ text = "Old Lamp (device 1001, gone since 10-24)", value = "dev:1001" } }, lights)
			assert.same({ { text = "Back to all folders", value = "f:top", folder = true },
				{ text = "(no zone light device is gone or unbound)", value = "" } }, (w.a:link_list("f:groups")))
			assert.same({}, w.acted())
		end)

		it("counts the suggestions and shows each next to its device; one the lists lack joins its kind", function()
			local w = world({ lights = { suggested = function()
				return { { device_id = 1001, rid = "L1", text = "Desk Lamp [Office] #3", why = "same radio" },
					{ device_id = 1002, rid = "L2" }, { device_id = 1003, rid = "L3", text = "Desk, Lamp #9" } }
			end, picker_relink_devices = function()
				return { { text = "Old Lamp (device 1001, gone since 10-24)", value = "1001" },
					{ text = "Lamp (device 1003, gone since 10-24)", value = "1003" } }
			end } })
			local list = w.a:link_list("")
			assert.same({ text = "Every device with a suggested match (3)", value = "dev:suggested" }, list[1])
			-- The device once, then the Hue thing and the reason (§4 finding 5); no comma
			-- of a Hue name inside the row.
			assert.same({ "Back to all folders",
				"Old Lamp (device 1001, gone since 10-24) → Desk Lamp [Office] #3 (suggested: same radio)",
				"Lamp (device 1003, gone since 10-24) → Desk  Lamp #9 (suggested)",
				"Desk #2 (device 1002) (has a suggested match)" }, texts((w.a:link_list("f:lights"))))
		end)

		it("takes suggestions as a map of device id to rid too", function()
			local w = world({ motion = { suggested = function() return { [1301] = "M1" } end } })
			assert.equal("Every device with a suggested match (1)", (w.a:link_list(""))[1].text)
		end)

		it("shows a lone kind's devices in place of its folder", function()
			local w = world({
				scenes = { picker_relink_devices = function() return empty("(no gone or unbound scene devices)") end },
				motion = { picker_relink_devices = function() return {} end } })
			assert.same({ "dev:suggested", "dev:1001" }, values((w.a:link_list(""))))
		end)
	end)

	describe("Link Device's To (link_target_list)", function()
		it("opens on (its suggested match), then the free Hue things by kind", function()
			local w = world()
			local list, back = w.a:link_target_list("")
			assert.is_nil(back)
			assert.same({ "(its suggested match)", "Lights (2)", "Zones and rooms (1)", "Scenes (3 in 2 rooms)",
				"Motion sensors and areas (2)" }, texts(list))
			assert.same({ "to:suggested", "f:lights", "f:groups", "f:scenes", "f:motion" }, values(list))
			assert.same({ "f:top", "light:L1", "light:L2" }, values((w.a:link_target_list("f:lights"))))
			assert.same({ "f:top", "sensor:M1", "area:A1" }, values((w.a:link_target_list("f:motion"))))
		end)

		it("puts scenes in room folders that cannot be picked themselves, with no All row", function()
			local w = world()
			local folders = w.a:link_target_list("f:scenes")
			assert.same({ "f:top", "f:scenes:Z1", "f:scenes:R1" }, values(folders))
			for _, e in ipairs(folders) do assert.is_nil(e.selectable) end
			local kitchen, back = w.a:link_target_list("f:scenes:R1")
			assert.equal("f:scenes", back)
			assert.same({ "Back to Scenes", "Relax", "Bright (dynamic)" }, texts(kitchen))
			assert.same({ "f:scenes", "scene:S1", "scene:S2" }, values(kitchen))
		end)

		it("shows a lone kind in place of its folder, and its room folders go back to the top", function()
			local w = world({
				lights = { picker_lights = function() return empty("(every light on the bridge is imported)") end },
				zone_lights = { picker_groups = function() return {} end }, motion = false,
			})
			assert.same({ "to:suggested", "f:scenes:Z1", "f:scenes:R1" }, values((w.a:link_target_list(""))))
			local kitchen, back = w.a:link_target_list("f:scenes:R1")
			assert.equal("", back)
			assert.same({ text = "Back to all folders", value = "f:top", folder = true }, kitchen[1])
		end)

		it("answers strings only and a back in every folder", function()
			local problems = {}
			local w = world()
			walk(function(f) return w.a:link_target_list(f) end, problems)
			walk(function(f) return w.a:link_list(f) end, problems)
			walk(function(f) return w.a:forget_list(f) end, problems)
			assert.same({}, problems)
		end)
	end)

	describe("Link Device (run_link)", function()
		it("re-links a device of each kind to the Hue thing of its kind", function()
			local cases = {
				{ { Device = "dev:1001", To = "light:L1" }, "lights:relink", 1001, "L1" },
				{ { Device = "dev:1201", To = "scene:S3" }, "scenes:relink", 1201, "S3" },
				{ { Device = "dev:1301", To = "area:A1" }, "motion:relink", 1301, "A1" },
				{ { Device = "dev:1301", To = "sensor:M1" }, "motion:relink", 1301, "M1" },
				-- A device that came back since the list was opened is re-pointed as asked.
				{ { Device = "dev:1002", To = "light:L2" }, "lights:relink", 1002, "L2" },
				{ { Device = "dev:1101", To = "group:G1" }, "zone_lights:relink", 1101, "G1" },
			}
			for _, case in ipairs(cases) do
				local w = world()
				w.a:run_link(case[1])
				assert.same({ case[2] }, w.acted(), case[1].Device)
				assert.same({ case[3], case[4] }, w.of(case[2])[1])
				assert.same({ string.format("Re-linked %s %d to %s", ({ ["lights:relink"] = "device",
					["scenes:relink"] = "scene", ["motion:relink"] = "motion device",
					["zone_lights:relink"] = "zone light" })[case[2]], case[3], case[4]) }, w.said)
			end
		end)

		it("refuses a pair that does not match, a folder, and what it does not offer", function()
			local cases = {
				{ {}, "Not linked: pick a device under Device first" },
				{ { Device = "dev:1001", To = "group:G1" }, "Not linked: device 1001 is a light; under To pick a light "
					.. "(the Lights folder)" },
				{ { Device = "dev:1201", To = "light:L1" }, "Not linked: device 1201 is a scene; under To pick a scene "
					.. "(the Scenes folder)" },
				{ { Device = "dev:1001", To = "f:lights" }, "Not linked: Lights under To is a folder; open it and pick one "
					.. "inside" },
				{ { Device = "dev:1201", To = "f:scenes:R1" }, "Not linked: Scenes under To is a folder; open it and pick "
					.. "one inside" },
				{ { Device = "dev:1001", To = "light:" }, "Not linked: pick a light (the Lights folder) under To" },
				{ { Device = "dev:1001", To = "thing:x" }, "Not linked: \"thing:x\" is not something Link Device offers; "
					.. "open To again" },
				{ { Device = "light:L1", To = "light:L1" }, "Not linked: \"light:L1\" is not a device Link Device offers; "
					.. "open Device again" },
				{ { Device = "dev:4242", To = "light:L1" }, "Not linked: device 4242 is not a device of this bridge any "
					.. "more; open Device again" },
				{ { Device = "dev:1001" }, "Not linked: device 1001 has no suggested match; under To pick a light (the "
					.. "Lights folder)" },
				{ { Device = "dev:suggested", To = "light:L1" }, "Not linked: every device with a suggested match goes "
					.. "to its own match; set To to (its suggested match)" },
			}
			for _, case in ipairs(cases) do
				local w = world()
				w.a:run_link(case[1])
				assert.same({ case[2] }, w.said)
				assert.same({}, w.acted())
			end
			local w = world({ paired = false })
			w.a:run_link({ Device = "dev:1001", To = "light:L1" })
			assert.same({ "Not paired" }, w.said)
		end)

		it("follows the device's suggestion for (its suggested match) or an empty To", function()
			for _, to in ipairs({ "to:suggested", "" }) do
				local w = world({ lights = { suggested = function() return { { device_id = 1001, rid = "L2" } } end } })
				w.a:run_link({ Device = "dev:1001", To = to })
				assert.same({ { 1001, "L2" } }, w.of("lights:relink"))
				assert.same({ "Re-linked device 1001 to L2" }, w.said)
			end
		end)

		it("does every suggestion, then today's Link Devices with each module skipping the other's devices", function()
			local w = world({ lights = { suggested = function() return { { device_id = 1001, rid = "L1" } } end },
				motion = { suggested = function() return { { device_id = 1301, rid = "M1" } } end } })
			w.a:run_link({ Device = "dev:suggested", To = "to:suggested" })
			assert.same({ "lights:relink", "motion:relink", "lights:link_devices", "scenes:link_devices",
				"zone_lights:link_devices", "motion:link_devices" }, w.acted())
			assert.same({ [1101] = true }, w.of("lights:link_devices")[1][1])
			assert.same({ [1001] = true, [1002] = true }, w.of("zone_lights:link_devices")[1][1])
			assert.same({ "Suggested matches: Re-linked device 1001 to L1; Re-linked motion device 1301 to M1 | All 2 "
				.. "bound lights are registered | Scenes: No scene devices are bound | Zone lights: No zone lights are "
				.. "bound to this bridge | Motion: No motion devices are bound" }, w.said)
			w = world()
			w.a:run_link({ Device = "dev:suggested" })
			assert.same({ "lights:link_devices", "scenes:link_devices", "zone_lights:link_devices", "motion:link_devices" },
				w.acted())
			assert.same({ "All 2 bound lights are registered | Scenes: No scene devices are bound | Zone lights: No zone "
				.. "lights are bound to this bridge | Motion: No motion devices are bound" }, w.said)
		end)
	end)

	describe("Forget Device (forget_list, run_forget)", function()
		it("lists every linked device by kind, a lone kind in place, and says so when there is none", function()
			local w = world()
			local list, back = w.a:forget_list("")
			assert.is_nil(back)
			assert.same({ "Lights (2)", "Zone lights (1)", "Scenes (1)", "Motion sensors and areas (1)" }, texts(list))
			local lights
			lights, back = w.a:forget_list("f:lights")
			assert.equal("", back)
			assert.same({ "f:top", "dev:1001", "dev:1002" }, values(lights))
			local only = world({ zone_lights = false, scenes = false, motion = false })
			assert.same({ "dev:1001", "dev:1002" }, values((only.a:forget_list(""))))
			local none = world({ lights = false, zone_lights = false, scenes = false,
				motion = { picker_forget_devices = function() return empty("(no motion devices registered)") end } })
			assert.same({ { text = "(no device is linked to this bridge)", value = "" } }, (none.a:forget_list("")))
		end)

		it("forgets only with Confirm \"Yes, forget\"", function()
			for _, confirm in ipairs({ false, "No", "yes, forget", "Yes" }) do
				local w = world()
				w.a:run_forget({ Device = "dev:1002", Confirm = confirm or nil })
				assert.same({ "Not forgotten: choose Yes, forget" }, w.said)
				assert.same({}, w.acted())
			end
			local w = world()
			w.a:run_forget({ Device = "dev:1002", Confirm = "Yes, forget" })
			assert.same({ { 1002 } }, w.of("lights:forget"))
			assert.same({ "Forgot light device 1002" }, w.said)
		end)

		it("sends each device to its module; a zone light's stale light entry goes too", function()
			local cases = {
				{ "dev:1201", { "scenes:forget" }, "Forgot scene 1201" },
				{ "dev:1301", { "motion:forget" }, "Forgot motion device 1301" },
				{ "dev:1101", { "zone_lights:forget" }, "Forgot zone light 1101" },
			}
			for _, case in ipairs(cases) do
				local w = world()
				w.a:run_forget({ Device = case[1], Confirm = "Yes, forget" })
				assert.same(case[2], w.acted())
				assert.same({ case[3] }, w.said)
			end
			local w = world({ lights = { picker_forget_devices = function()
				return { { text = "Attic #9 (device 1101) unbound", value = "1101" } }
			end } })
			w.a:run_forget({ Device = "dev:1101", Confirm = "Yes, forget" })
			assert.same({ "zone_lights:forget", "lights:forget" }, w.acted())
			assert.same({ "Forgot zone light 1101 | Forgot light device 1101" }, w.said)
		end)

		it("refuses no device, an unknown value and a device the bridge does not have", function()
			local cases = {
				{ { Confirm = "Yes, forget" }, "Not forgotten: pick a device under Device first" },
				{ { Device = "x", Confirm = "Yes, forget" }, "Not forgotten: \"x\" is not a device Forget Device offers; "
					.. "open Device again" },
				{ { Device = "dev:4242", Confirm = "Yes, forget" }, "Not forgotten: device 4242 is not linked to this "
					.. "bridge any more" },
			}
			for _, case in ipairs(cases) do
				local w = world()
				w.a:run_forget(case[1])
				assert.same({ case[2] }, w.said)
				assert.same({}, w.acted())
			end
		end)
	end)

	describe("Resolve Names (names_list, run_names)", function()
		it("lists names.lua's rows, or says every name agrees", function()
			local w = world()
			assert.same({ "names:composer_to_hue", "names:hue_to_composer", "row:1002:hue" }, values((w.a:names_list())))
			w = world({ names = { resolve_rows = function() return {} end } })
			assert.same({ { text = "(every name agrees between Composer and Hue)", value = "" } }, (w.a:names_list()))
		end)

		it("hands the row picked to names:resolve and ends in its text", function()
			local w = world()
			w.a:run_names({ Names = "row:1002:hue" })
			assert.equal("row:1002:hue", w.of("names:resolve")[1][1])
			assert.same({ "Resolved row:1002:hue" }, w.said)
			w = world()
			w.a:run_names({ Names = "" })
			assert.same({ "Nothing renamed: pick a row under Names first" }, w.said)
			assert.same({}, w.acted())
		end)

		it("falls back to beta 8's pair without bridge/names.lua, paired only", function()
			local w = world({ names = false })
			assert.same({ actions.NAMES.HUE_TO_COMPOSER, actions.NAMES.KEEP_COMPOSER }, values((w.a:names_list())))
			w.a:run_names({ Names = actions.NAMES.HUE_TO_COMPOSER })
			assert.same({ "lights:adopt_hue_names", "zone_lights:adopt_hue_names", "scenes:adopt_hue_names",
				"motion:adopt_hue_names" }, w.acted())
			assert.same({ "Renamed 1 light" }, w.said)
			-- The proxy ids first (driver.lua's fill_proxy_ids): beta 8's renames need them.
			local order = {}
			w = world({ names = false, lights = { adopt_hue_names = function() order[#order + 1] = "adopt" return "x" end } })
			w.ctx.before_names = function() order[#order + 1] = "proxy ids" end
			w.a:run_names({ Names = actions.NAMES.HUE_TO_COMPOSER })
			assert.same({ "proxy ids", "adopt" }, order)
			w = world({ names = false })
			w.a:run_names({ Names = actions.NAMES.KEEP_COMPOSER })
			assert.same({ "Kept 1 light name" }, w.said)
			w = world({ names = false })
			w.a:run_names({ Names = "row:1002:hue" })
			assert.same({ "Nothing renamed: that row is not offered any more; open Names again" }, w.said)
			w = world({ names = false, paired = false })
			w.a:run_names({ Names = actions.NAMES.HUE_TO_COMPOSER })
			assert.same({ "Not paired" }, w.said)
			assert.same({ { text = "(names are not ready yet; open the list again)", value = "" } },
				(world({ names = false, lights = false, zone_lights = false, scenes = false, motion = false }).a:names_list()))
		end)
	end)

	describe("Diagnostics (diagnostics_list, run_diagnostics)", function()
		local function diag(ran)
			return {
				["diag:test"] = { text = "Check the connection now", order = 1, shows = "Status",
					run = function(params) ran[#ran + 1] = { "test", params.What } end },
				["diag:refresh"] = { text = "Read everything from the bridge now", order = 2,
					run = function(_, say) ran[#ran + 1] = { "refresh" } say("Refreshed from the bridge") end },
				["diag:disconnect"] = { text = "Stop the event stream until the next start", order = 4,
					run = function() ran[#ran + 1] = { "disconnect" } return "Event stream stopped" end },
				["diag:reload_credentials"] = { text = "(dev) Reload credentials", order = 9, dev = true,
					run = function() ran[#ran + 1] = { "reload" } end },
				["diag:boom"] = { text = "Raise", order = 5, run = function() error("broken") end },
			}
		end

		it("lists the entries by order, the dev ones only in a dev build", function()
			local w = world({ diagnostics = diag({}) })
			assert.same({ "diag:test", "diag:refresh", "diag:disconnect", "diag:boom" }, values((w.a:diagnostics_list())))
			w = world({ diagnostics = diag({}), dev = true })
			assert.same({ "diag:test", "diag:refresh", "diag:disconnect", "diag:boom", "diag:reload_credentials" },
				values((w.a:diagnostics_list())))
			w = world({ diagnostics = { { value = "b", text = "B", run = function() end },
				{ value = "a", text = "A", run = function() end } } })
			assert.same({ "b", "a" }, values((w.a:diagnostics_list())), "a list keeps its order")
			assert.same({ { text = "(no diagnostics in this build)", value = "" } }, (world().a:diagnostics_list()))
		end)

		it("says it started before the entry runs, so what the entry writes itself stays", function()
			local ran = {}
			local w = world({ diagnostics = diag(ran) })
			w.a:run_diagnostics({ What = "diag:test" })
			w.a:run_diagnostics({ What = "diag:refresh" })
			w.a:run_diagnostics({ What = "diag:disconnect" })
			assert.same({ { "test", "diag:test" }, { "refresh" }, { "disconnect" } }, ran)
			assert.same({ "Check the connection now: started (the result shows in Status)",
				"Read everything from the bridge now: started", "Refreshed from the bridge",
				"Stop the event stream until the next start: started", "Event stream stopped" }, w.said)
			-- An entry that writes Last Action through the driver, not through say.
			local driver_rows = {}
			w = world({ diagnostics = { ["diag:motion_log"] = { text = "Log motion diagnostics (10 minutes)",
				run = function() w.ctx.last_action("Motion diagnostics start in 20 seconds") end } } })
			w.ctx.last_action = function(text) driver_rows[#driver_rows + 1] = text end
			w.a:run_diagnostics({ What = "diag:motion_log" })
			assert.equal("Motion diagnostics start in 20 seconds", driver_rows[#driver_rows])
		end)

		it("refuses nothing picked, a value this build lacks, and turns a raise into Last Action", function()
			local ran = {}
			local w = world({ diagnostics = diag(ran) })
			w.a:run_diagnostics({})
			w.a:run_diagnostics({ What = "diag:reload_credentials" })
			w.a:run_diagnostics({ What = "diag:boom" })
			assert.same({}, ran)
			assert.equal("Nothing run: pick what to run under What first", w.said[1])
			assert.equal("Nothing run: \"diag:reload_credentials\" is not a diagnostic of this build", w.said[2])
			assert.equal("Raise: started", w.said[3])
			assert.truthy(w.said[4]:find("^Diagnostics failed: .*broken"))
		end)
	end)

	describe("aliases: beta 8's commands until 2.0 (run_alias)", function()
		local function alias(old, params, opts)
			local w = world(opts)
			assert.is_true(w.a:run_alias(old, params))
			return w
		end

		it("maps each old command and its old params onto the new runner", function()
			local cases = {
				{ "Add Light", { Light = "L1", Room = "7" }, "lights:add_light", { "L1", 7 } },
				{ "Import All New Lights", {}, "lights:import_new", {} },
				{ "Add Zone Light", { Group = "G1", Room = "mapped" }, "zone_lights:add", { "G1" } },
				{ "Re-link Device To Light", { Device = "1001", Light = "L2" }, "lights:relink", { 1001, "L2" } },
				{ "Re-link Zone Light", { Device = "1101", Group = "G1" }, "zone_lights:relink", { 1101, "G1" } },
				{ "Forget Light", { Device = "1002" }, "lights:forget", { 1002 } },
				{ "Add Scene", { Scene = "S1", Room = "7" }, "scenes:add_scene", { "S1", 7 } },
				{ "Add All Scenes Of Room", { ["Hue Room"] = "R1" }, "scenes:add_all_of_group", { "R1" } },
				{ "Re-link Scene", { Device = "1201", Scene = "S2" }, "scenes:relink", { 1201, "S2" } },
				{ "Forget Scene", { Device = "1201" }, "scenes:forget", { 1201 } },
				{ "Add Motion Sensor", { Sensor = "M1" }, "motion:add", { "M1" } },
				{ "Import All New Motion Sensors", {}, "motion:import_new", {} },
				{ "Add Motion Area", { Area = "A1", Room = "7" }, "motion:add", { "A1", 7 } },
				{ "Re-link Motion Device", { Device = "1301", Target = "A1" }, "motion:relink", { 1301, "A1" } },
				{ "Re-link Motion Device", { Device = "1301", Target = "M1" }, "motion:relink", { 1301, "M1" } },
				{ "Forget Motion Device", { Device = "1301" }, "motion:forget", { 1301 } },
				{ "Adopt Hue Names", {}, "names:resolve", { actions.NAMES.HUE_TO_COMPOSER } },
			}
			for _, case in ipairs(cases) do
				local w = alias(case[1], case[2])
				assert.same({ case[3] }, w.acted(), case[1])
				local args = w.of(case[3])[1]
				for i, want in ipairs(case[4]) do assert.equal(want, args[i], case[1]) end
				assert.equal(1, #w.said, case[1])
				assert.is_nil(w.last():find(" is now ", 1, true), "the old Last Action, no pointer: " .. case[1])
				assert.truthy(w.logs[1]:find("^always actions: " .. case[1]:gsub("%-", "%%-") .. " is now "), case[1])
			end
		end)

		it("keeps beta 8's refusal of a missing pick, after the pairing check", function()
			local cases = {
				{ "Add Light", { Room = "7" }, "Not added: pick a light first" },
				{ "Add Zone Light", {}, "Not added: pick a zone or room first" },
				{ "Add Scene", { Scene = "" }, "Not added: pick a scene first" },
				{ "Add All Scenes Of Room", {}, "Not added: pick a Hue room first" },
				{ "Add Motion Sensor", {}, "Not added: pick a motion sensor first" },
				{ "Add Motion Area", {}, "Not added: pick a MotionAware area first" },
				{ "Re-link Device To Light", { Device = "1001" }, "Not re-linked: pick a device and a light" },
				{ "Re-link Zone Light", { Group = "G1" }, "Not re-linked: pick a device and a zone or room" },
				{ "Re-link Scene", {}, "Not re-linked: pick a device and a scene" },
				{ "Re-link Motion Device", { Device = "1301" }, "Not re-linked: pick a device and a sensor or area" },
				{ "Forget Light", {}, "Not forgotten: pick a device first" },
				{ "Forget Scene", {}, "Not forgotten: pick a device first" },
				{ "Forget Motion Device", {}, "Not forgotten: pick a device first" },
			}
			for _, case in ipairs(cases) do
				local w = alias(case[1], case[2])
				assert.same({ case[3] }, w.said, case[1])
				assert.same({}, w.acted(), case[1])
				w = alias(case[1], case[2], { paired = false })
				assert.same({ "Not paired" }, w.said, case[1])
			end
		end)

		it("Link Devices is today's Link Devices: no suggestion is applied", function()
			local w = alias("Link Devices", {},
				{ lights = { suggested = function() return { { device_id = 1001, rid = "L1" } } end } })
			assert.same({ "lights:link_devices", "scenes:link_devices", "zone_lights:link_devices", "motion:link_devices" },
				w.acted())
		end)

		it("Accept Names As They Are writes nothing once names follow each other; without names.lua it accepts", function()
			local w = alias("Accept Names As They Are", {})
			assert.same({}, w.acted())
			assert.same({ "Nothing to accept: names follow each other between Composer and Hue by themselves; the ones "
				.. "that cannot are in Resolve Names" }, w.said)
			w = alias("Accept Names As They Are", {}, { names = false })
			assert.same({ "lights:accept_names", "zone_lights:accept_names", "scenes:accept_names", "motion:accept_names" },
				w.acted())
		end)

		it("sends the old diagnostics to their Diagnostics entries", function()
			local D = actions.DIAGNOSTICS
			local cases = { ["Test Connection"] = D.TEST, ["Refresh All"] = D.REFRESH,
				["Connect Event Stream"] = D.CONNECT, ["Disconnect Event Stream"] = D.DISCONNECT,
				["Log Motion Diagnostics"] = D.MOTION_LOG }
			for old, value in pairs(cases) do
				local ran = {}
				local entries = {}
				for _, v in pairs(D) do
					entries[v] = { text = v, run = function() ran[#ran + 1] = v end }
				end
				local w = alias(old, {}, { diagnostics = entries })
				assert.same({ value }, ran, old)
				assert.equal(1, #w.said)
			end
		end)

		it("answers false for a command it does not know", function()
			assert.is_false(world().a:run_alias("Pair Bridge", {}))
			assert.is_false(world().a:run_alias("Map Rooms By Name", {}))
			assert.is_false(world().a:run_alias("Refresh Scenes", {}), "beta 8's handler: the scenes alone, at once")
		end)
	end)
end)
