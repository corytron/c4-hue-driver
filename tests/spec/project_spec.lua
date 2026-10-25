-- The project access the lights, scenes and zone-light modules share: the
-- defaults to the real C4 calls and the pcall-wrapped reads, with the outputs
-- the modules' own copies produced before they were merged
-- (docs/reviews/slim-scenes-zones.md, row 6; docs/reviews/diff-review-2026-10-24.md, row 10).

local fake = require("helpers.fake_c4")
local log = require("common.log")

describe("bridge.project", function()
	local project, c4, logged

	local function saw_log(text)
		for _, line in ipairs(logged) do
			if line:find(text, 1, true) then return true end
		end
		return false
	end

	-- A view over explicit calls (no C4 involved).
	local function view(calls, prefix)
		return project.new({ project = calls, log = log }, prefix or "scenes")
	end

	before_each(function()
		logged = {}
		log.sink = function(line) table.insert(logged, line) end
		c4 = fake.install_c4()
		fake.add_room(8, "Garage")
		package.loaded["bridge.project"] = nil
		project = require("bridge.project")
	end)

	describe("defaults", function()
		it("fills in every call the ctx lacks and keeps the ones given", function()
			local mine = function() return { [42] = "Mine" } end
			local ctx = { project = { rooms = mine } }
			local calls = project.defaults(ctx, 1)
			assert.equal(ctx.project, calls)
			assert.equal(mine, calls.rooms)
			for _, name in ipairs({ "hierarchy", "devices", "bound", "unbind", "rename", "display_name" }) do
				assert.equal("function", type(calls[name]), name)
			end
			local bare = {}
			project.defaults(bare, 1)
			assert.equal("function", type(bare.project.rooms))
		end)

		it("reads the fake project through the real calls, bound on the binding given", function()
			local calls = project.defaults({}, 1)
			fake.project.devices[2001] = { name = "Lamp", room_id = 7, c4i = "hue_light.c4z", driver_name = "Hue Light" }
			c4:Bind(15, 1, 2001, 1, "HUE_BRIDGE")
			local p = project.new({ project = calls, log = log }, "scenes")
			assert.same({ [7] = "Living Room", [8] = "Garage" }, p:rooms())
			assert.same({ [2001] = true }, p:bound_set())
			assert.equal("Lamp", p:display_name(2001))
			assert.equal("Lamp", p:devices_of("hue_light.c4z")[2001].deviceName)
			assert.is_nil(p:devices_of("hue_scene.c4z"), "nothing of that driver: unknown, never deleted")
			calls.rename(2001, "Desk Lamp")
			assert.same({ { id = 2001, name = "Desk Lamp" } }, c4.renamed)
			calls.unbind(2001)
			assert.same({ { 2001, 1 } }, c4.calls_to("Unbind"))
			assert.is_nil(project.defaults({}, 1).bound(), "nothing bound on this binding")
		end)
	end)

	describe("call", function()
		it("returns true and the result, or false after a warning naming the module", function()
			local p = view({ rooms = function() return "r" end, bound = function() error("boom") end }, "zone_lights")
			assert.same({ true, "r" }, { p:call("rooms") })
			assert.same({ false, nil }, { p:call("bound") })
			assert.is_true(saw_log("[WARN] zone_lights: project.bound failed: "))
			assert.is_true(saw_log("boom"))
			assert.same({ false, nil }, { p:call("missing") }, "a call the ctx lacks is a failed call")
		end)
	end)

	describe("reads", function()
		it("rooms: numeric ids and string names, empty when the call fails or answers junk", function()
			local p = view({ rooms = function() return { ["7"] = "Living Room", [8] = 9, x = "no", [3] = nil } end })
			assert.same({ [7] = "Living Room", [8] = "9" }, p:rooms())
			assert.same({}, view({ rooms = function() error("boom") end }):rooms())
			assert.same({}, view({ rooms = function() return "junk" end }):rooms())
			assert.same({}, view({ rooms = function() return nil end }):rooms())
		end)

		-- Issue #48 item 14: a nil answer is unknown, never "nothing bound";
		-- an empty table still is.
		it("bound_set: a set of numeric ids; nil and why when the lookup failed or answered no table", function()
			local p = view({ bound = function() return { ["2001"] = "Hue Light", [2002] = "Hue Scene" } end })
			assert.same({ [2001] = true, [2002] = true }, p:bound_set())
			assert.same({}, view({ bound = function() return {} end }):bound_set(), "an empty table: nothing bound")
			assert.same({ nil, "unknown" }, { view({ bound = function() return nil end }):bound_set() })
			assert.same({ nil, "unknown" }, { view({ bound = function() return "junk" end }):bound_set() })
			assert.same({ nil, "failed" }, { view({ bound = function() error("boom") end }):bound_set() })
		end)

		it("devices_of: asks for the driver file, keys by numeric id, nil when failed or empty", function()
			local asked
			local p = view({ devices = function(filter)
				asked = filter
				return { ["2001"] = { deviceName = "Relax" }, [2002] = { deviceName = "Bright" } }
			end })
			local out = p:devices_of("hue_scene.c4z")
			assert.same({ C4iNames = "hue_scene.c4z" }, asked)
			assert.equal("Relax", out[2001].deviceName)
			assert.equal("Bright", out[2002].deviceName)
			assert.is_nil(view({ devices = function() return {} end }):devices_of("hue_scene.c4z"))
			assert.is_nil(view({ devices = function() return nil end }):devices_of("hue_scene.c4z"))
			assert.is_nil(view({ devices = function() return "junk" end }):devices_of("hue_scene.c4z"))
			assert.is_nil(view({ devices = function() error("boom") end }):devices_of("hue_scene.c4z"))
		end)

		it("display_name: a string, nil for no id, an empty name, nil or a failed call", function()
			local names = { [2001] = "Relax", [2002] = "", [2003] = 7 }
			local p = view({ display_name = function(id) return names[id] end })
			assert.equal("Relax", p:display_name(2001))
			assert.is_nil(p:display_name(2002))
			assert.equal("7", p:display_name(2003))
			assert.is_nil(p:display_name(2004))
			assert.is_nil(p:display_name(nil))
			assert.is_nil(view({ display_name = function() error("boom") end }):display_name(2001))
		end)
	end)

	describe("a nil bound list (issue #48, verified 2026-10-25: nil means nothing bound on OS 3.4.2)", function()
		local now, answer, calls, p
		before_each(function()
			now, answer = 1000, nil
			calls = { bound = function() return answer end, clock = function() return now end }
			p = project.new({ project = calls, log = { warn = function() end } }, "lights")
		end)

		it("is unknown once, and nothing bound when a second lookup NIL_CONFIRM_S later is nil too", function()
			assert.same({ nil, "unknown" }, { p:bound_set() })
			now = now + project.NIL_CONFIRM_S - 1
			assert.same({ nil, "unknown" }, { p:bound_set() }, "too soon to confirm")
			now = now + 1
			assert.same({}, (p:bound_set()))
		end)

		it("starts over when a list is answered in between", function()
			assert.same({ nil, "unknown" }, { p:bound_set() })
			answer = { [7] = "Hue Light" }
			assert.same({ [7] = true }, (p:bound_set()))
			answer = nil
			now = now + 60
			assert.same({ nil, "unknown" }, { p:bound_set() }, "a new first nil")
		end)

		it("is shared by the modules through ctx.project", function()
			local q = project.new({ project = calls, log = { warn = function() end } }, "scenes")
			assert.same({ nil, "unknown" }, { p:bound_set() })
			now = now + project.NIL_CONFIRM_S
			assert.same({}, (q:bound_set()), "the other module's lookup confirms it")
		end)
	end)
end)
