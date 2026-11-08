local log = require("common.log")

-- Issue #249, docs/group-hold-design.md: a keypad hold on a scene, a zone
-- light or a room light, per-light up to PER_LIGHT_MAX lit members, stepped
-- above, the group as before when nothing is lit.
describe("bridge.group_hold", function()
	local group_hold, gh, lines, timers, light_sets, group_sets, members, on

	local G1 = "8e7d6c5b-0000-4000-8000-00000000g001"
	local G2 = "8e7d6c5b-0000-4000-8000-00000000g002"

	-- n light rids, in order.
	local function rids(n, prefix)
		local out = {}
		for i = 1, n do
			out[i] = string.format("%s-%02d", prefix or "light", i)
		end
		return out
	end

	-- Every one of `list` on.
	local function light_up(list)
		for _, rid in ipairs(list) do
			on[rid] = true
		end
	end

	-- A one-shot timer fired by hand: fire() runs every timer still active
	-- once (the ones armed meanwhile wait for the next fire()).
	local function set_timer(ms, fn)
		local t = { ms = ms, fn = fn, active = true }
		function t.Cancel()
			t.active = false
		end
		timers[#timers + 1] = t
		return t
	end

	local function active_timers()
		local out = {}
		for _, t in ipairs(timers) do
			if t.active then
				out[#out + 1] = t
			end
		end
		return out
	end

	local function fire()
		for _, t in ipairs(active_timers()) do
			t.active = false
			t.fn()
		end
	end

	local function new_hold(extra)
		local ctx = {
			members = function(rid) return members[rid] or {} end,
			is_on = function(rid) return on[rid] end,
			light_set = function(rid, fields) light_sets[#light_sets + 1] = { rid = rid, fields = fields }; return true end,
			group_set = function(rid, fields) group_sets[#group_sets + 1] = { rid = rid, fields = fields }; return true end,
			set_timer = set_timer,
			log = log,
		}
		for k, v in pairs(extra or {}) do
			ctx[k] = v
		end
		return group_hold.new(ctx)
	end

	-- The bodies scenes:dim and zone_lights:dim build.
	local function start_body(action, duration)
		return { dimming_delta = { action = action, brightness_delta = 100 }, dynamics = { duration = duration } }
	end
	local STOP = { dimming_delta = { action = "stop" } }

	local function light_rids_sent(list)
		local out = {}
		for i, sent in ipairs(list or light_sets) do
			out[i] = sent.rid
		end
		return out
	end

	local function deltas()
		local out = {}
		for i, sent in ipairs(group_sets) do
			out[i] = sent.fields.delta
		end
		return out
	end

	local function saw(text)
		for _, line in ipairs(lines) do
			if line:find(text, 1, true) then
				return true
			end
		end
		return false
	end

	before_each(function()
		lines = {}
		log.sink = function(line) table.insert(lines, line) end
		log.set_debug(true)
		package.loaded["bridge.group_hold"] = nil
		group_hold = require("bridge.group_hold")
		timers, light_sets, group_sets, members, on = {}, {}, {}, {}, {}
		gh = new_hold()
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("module", function()
		it("has the contract's constants as fields (G10)", function()
			assert.equal(10, group_hold.PER_LIGHT_MAX)
			assert.equal(1000, group_hold.STEP_MS)
		end)

		it("requires group_set", function()
			assert.has_error(function() group_hold.new({}) end)
			assert.has_error(function() group_hold.new() end)
		end)

		it("builds the old hook's fields from a body", function()
			assert.same({ dim = "up", delta = 100, rate = 5000, level = 42 },
				group_hold.fields(start_body("up", 5000), "42"))
			assert.same({ dim = "stop" }, group_hold.fields(STOP))
			assert.same({ dim = "down", delta = 30 }, group_hold.fields({ dimming_delta = { action = "down",
				brightness_delta = 30 }, dynamics = "junk" }))
		end)

		it("ignores a body without a dimming_delta and a dim without a grouped_light", function()
			assert.is_false(gh:dim(G1, nil))
			assert.is_false(gh:dim(G1, {}))
			assert.is_false(gh:dim(G1, { dimming_delta = "up" }))
			assert.is_false(gh:dim(nil, start_body("up", 5000)))
			assert.is_false(gh:dim("", STOP))
			assert.same({}, group_sets)
			assert.same({}, light_sets)
			assert.is_true(saw("a dim without a grouped_light ignored"))
		end)
	end)

	describe("per-light (G4)", function()
		it("sends the start to the lit members only, in member order, through the light queue", function()
			members[G1] = { "a", "b", "c", "d" }
			light_up({ "d", "b", "a" })  -- c is off
			assert.is_true(gh:dim(G1, start_body("down", 5000)))
			assert.same({ "a", "b", "d" }, light_rids_sent())
			for _, sent in ipairs(light_sets) do
				assert.same({ dim = "down", delta = 100, rate = 5000 }, sent.fields)
			end
			assert.same({}, group_sets, "nothing to the group")
			assert.same({}, active_timers(), "no timer")
			assert.equal("[INFO] group hold 8e7d6c5b down: per-light, 3 lights, 5000 ms", lines[#lines])
		end)

		it("sends the stop to exactly the lights that took the start, without a level", function()
			members[G1] = { "a", "b", "c" }
			light_up({ "a", "c" })
			gh:dim(G1, start_body("up", 3000))
			light_sets = {}
			assert.is_true(gh:dim(G1, STOP, 37))
			assert.same({ "a", "c" }, light_rids_sent())
			for _, sent in ipairs(light_sets) do
				assert.same({ dim = "stop" }, sent.fields)
			end
			assert.same({}, group_sets)
			assert.equal("[DEBUG] group hold 8e7d6c5b stop: per-light, 2 lights", lines[#lines])
		end)

		it("keeps the lit set of the start for the whole hold (G3)", function()
			members[G1] = { "a", "b", "c" }
			light_up({ "a", "b" })
			gh:dim(G1, start_body("down", 5000))
			on.a, on.c = false, true  -- a reaches off, c is switched on meanwhile
			members[G1] = { "c" }
			light_sets = {}
			gh:dim(G1, STOP)
			assert.same({ "a", "b" }, light_rids_sent())
		end)

		it("says 1 light for one", function()
			members[G1] = { "a" }
			light_up({ "a" })
			gh:dim(G1, start_body("up", 400))
			assert.equal("[INFO] group hold 8e7d6c5b up: per-light, 1 light, 400 ms", lines[#lines])
		end)

		it("counts a start without a brightness_delta as a hold (G2)", function()
			members[G1] = { "a" }
			light_up({ "a" })
			assert.is_true(gh:dim(G1, { dimming_delta = { action = "up" }, dynamics = { duration = 2000 } }))
			assert.same({ { rid = "a", fields = { dim = "up", delta = 100, rate = 2000 } } }, light_sets)
		end)

		it("reads a member listed twice once", function()
			members[G1] = { "a", "b", "a" }
			light_up({ "a", "b" })
			gh:dim(G1, start_body("up", 2000))
			assert.same({ "a", "b" }, light_rids_sent())
		end)

		it("uses the light queue up to PER_LIGHT_MAX lit members, the steps above", function()
			members[G1] = rids(12)
			light_up(rids(10))
			gh:dim(G1, start_body("up", 5000))
			assert.equal(10, #light_sets)
			assert.same({}, group_sets)
			gh:dim(G1, STOP)

			light_sets = {}
			light_up(rids(11))
			gh:dim(G1, start_body("up", 5000))
			assert.same({}, light_sets, "11 lit: stepped, nothing per light")
			assert.equal(1, #group_sets)
		end)

		it("reads PER_LIGHT_MAX when a hold starts", function()
			group_hold.PER_LIGHT_MAX = 2
			members[G1] = rids(3)
			light_up(rids(3))
			gh:dim(G1, start_body("up", 5000))
			assert.same({}, light_sets)
			assert.equal(1, #group_sets)
		end)

		it("goes to the group as before when the light queue takes none", function()
			gh = new_hold({ light_set = function() return false end })
			members[G1] = { "a", "b" }
			light_up({ "a", "b" })
			assert.is_true(gh:dim(G1, start_body("down", 5000)))
			assert.same({ { rid = G1, fields = { dim = "down", delta = 100, rate = 5000 } } }, group_sets)
			assert.is_true(saw("the light queue took none of 2 lights; the group instead"))
			group_sets = {}
			gh:dim(G1, STOP, 20)
			assert.same({ { rid = G1, fields = { dim = "stop", level = 20 } } }, group_sets, "no hold: the stop as before")
		end)

		it("stops only the lights the queue took", function()
			gh = new_hold({ light_set = function(rid, fields)
				light_sets[#light_sets + 1] = { rid = rid, fields = fields }
				return rid ~= "b" or fields.dim == "stop"
			end })
			members[G1] = { "a", "b", "c" }
			light_up({ "a", "b", "c" })
			gh:dim(G1, start_body("up", 5000))
			assert.is_true(saw("the light queue took 2 of 3 lights"))
			assert.is_true(saw("per-light, 2 lights, 5000 ms"))
			light_sets = {}
			gh:dim(G1, STOP)
			assert.same({ "a", "c" }, light_rids_sent())
		end)

		it("passes a hold without dynamics on with no rate", function()
			members[G1] = { "a" }
			light_up({ "a" })
			gh:dim(G1, { dimming_delta = { action = "down", brightness_delta = 100 } })
			assert.same({ dim = "down", delta = 100 }, light_sets[1].fields)
			assert.equal("[INFO] group hold 8e7d6c5b down: per-light, 1 light, 0 ms", lines[#lines])
		end)
	end)

	describe("stepped (G5)", function()
		before_each(function()
			members[G1] = rids(14)
			light_up(rids(14))
		end)

		it("sends one step at once, then one every STEP_MS, each 100 * STEP_MS / duration %, up to 100", function()
			assert.is_true(gh:dim(G1, start_body("down", 5000)))
			assert.same({ { rid = G1, fields = { dim = "down", delta = 20 } } }, group_sets, "no rate on a step")
			assert.equal("[INFO] group hold 8e7d6c5b down: stepped, 14 lights, 20 % a step", lines[#lines])
			assert.equal(1, #active_timers())
			assert.equal(1000, active_timers()[1].ms)
			for _ = 1, 4 do
				fire()
			end
			assert.same({ 20, 20, 20, 20, 20 }, deltas())
			assert.same({}, active_timers(), "the steps add up to 100: no more timer")
			fire()
			assert.equal(5, #group_sets)
			assert.same({}, light_sets)
		end)

		it("makes the last step what is left: 40, 40, 20 for 2500 ms", function()
			gh:dim(G1, start_body("up", 2500))
			assert.is_true(saw("stepped, 14 lights, 40 % a step"))
			fire()
			fire()
			assert.same({ 40, 40, 20 }, deltas())
			assert.same({}, active_timers())
		end)

		it("sends one step of 100 for a duration of 0, or none", function()
			gh:dim(G1, start_body("up", 0))
			assert.same({ { rid = G1, fields = { dim = "up", delta = 100 } } }, group_sets)
			assert.same({}, active_timers())
			assert.is_true(saw("stepped, 14 lights, 100 % a step"))
			gh:dim(G1, STOP)

			group_sets = {}
			gh:dim(G1, { dimming_delta = { action = "down", brightness_delta = 100 } })
			assert.same({ 100 }, deltas())
			assert.same({}, active_timers())
		end)

		it("caps a step at 100 for a hold shorter than STEP_MS", function()
			gh:dim(G1, start_body("down", 400))
			assert.same({ 100 }, deltas())
			assert.same({}, active_timers())
		end)

		it("ends thirds after three steps, rounded to 2 decimals, with no step of nothing after", function()
			gh:dim(G1, start_body("up", 3000))
			assert.is_true(saw("33.33 % a step"))
			fire()
			fire()
			assert.same({ 33.33, 33.33, 33.33 }, deltas())
			assert.same({}, active_timers())
		end)

		it("sends small steps for a long hold: 20 steps of 5 for 20 s", function()
			gh:dim(G1, start_body("down", 20000))
			for _ = 1, 30 do
				fire()
			end
			assert.equal(20, #group_sets)
			for _, sent in ipairs(group_sets) do
				assert.same({ dim = "down", delta = 5 }, sent.fields)
			end
		end)

		it("reads STEP_MS when a hold starts", function()
			group_hold.STEP_MS = 500
			gh:dim(G1, start_body("up", 5000))
			assert.same({ 10 }, deltas())
			assert.equal(500, active_timers()[1].ms)
		end)

		it("cancels the timer at the stop and sends nothing more, not even a group stop", function()
			gh:dim(G1, start_body("down", 5000))
			fire()
			local timer = active_timers()[1]
			assert.is_true(gh:dim(G1, STOP, 55), "carried out, though nothing is queued")
			assert.is_false(timer.active, "the step timer was cancelled")
			assert.same({ 20, 20 }, deltas())
			assert.equal("[DEBUG] group hold 8e7d6c5b stop: stepped, 14 lights, 40 % of 100 sent", lines[#lines])
			fire()
			assert.equal(2, #group_sets)
			assert.same({}, light_sets)
		end)

		it("sends nothing at the release of a hold whose steps already added up to 100", function()
			gh:dim(G1, start_body("up", 0))
			assert.is_true(gh:dim(G1, STOP, 100))
			assert.same({ 100 }, deltas(), "no group stop to cut the last step short")
			group_sets = {}
			gh:dim(G1, STOP, 100)
			assert.same({ { rid = G1, fields = { dim = "stop", level = 100 } } }, group_sets,
				"a second stop has no hold left: as before")
		end)

		it("sends nothing from a stale timer after the stop", function()
			gh:dim(G1, start_body("down", 5000))
			local stale = active_timers()[1]
			gh:dim(G1, STOP)
			stale.fn()  -- its Cancel came too late
			assert.same({ 20 }, deltas())
		end)

		it("sends nothing from the old hold's timer once a new hold runs", function()
			gh:dim(G1, start_body("down", 5000))
			local stale = active_timers()[1]
			gh:dim(G1, start_body("up", 2500))
			assert.is_false(stale.active, "the new start cancelled the old timer")
			stale.fn()
			assert.same({ 20, 40 }, deltas(), "the old hold's step, then the new hold's first")
			assert.equal(1, #active_timers())
			fire()
			assert.same({ 20, 40, 40 }, deltas())
			assert.equal("up", group_sets[3].fields.dim)
		end)

		it("stops stepping when the group queue takes no step", function()
			local take = true
			gh = new_hold({ group_set = function(rid, fields)
				group_sets[#group_sets + 1] = { rid = rid, fields = fields }
				return take
			end })
			gh:dim(G1, start_body("down", 5000))
			take = false
			fire()
			assert.same({}, active_timers())
			assert.is_true(saw("the group queue took no step; the hold stops here"))
			take = true
			group_sets = {}
			assert.is_true(gh:dim(G1, STOP))
			assert.same({}, group_sets, "the hold still ends at its release")
		end)

		it("returns false and keeps no hold when the group queue takes no first step", function()
			gh = new_hold({ group_set = function() return false end })
			assert.is_false(gh:dim(G1, start_body("down", 5000)))
			assert.same({}, active_timers())
			assert.is_nil(gh.holds[G1])
		end)
	end)

	describe("one hold per grouped_light (G7)", function()
		it("ends a running per-light hold with its stops before the new start", function()
			members[G1] = { "a", "b" }
			light_up({ "a", "b" })
			gh:dim(G1, start_body("up", 5000))
			on.b = false
			light_sets = {}
			gh:dim(G1, start_body("down", 5000))
			assert.same({
				{ rid = "a", fields = { dim = "stop" } },
				{ rid = "b", fields = { dim = "stop" } },
				{ rid = "a", fields = { dim = "down", delta = 100, rate = 5000 } },
			}, light_sets)
			assert.is_true(saw("group hold 8e7d6c5b stop before a new start: per-light, 2 lights"))
			light_sets = {}
			gh:dim(G1, STOP)
			assert.same({ "a" }, light_rids_sent(), "the new hold's stop goes to its own lights")
		end)

		it("ends a running stepped hold before a per-light one", function()
			members[G1] = rids(11)
			light_up(rids(11))
			gh:dim(G1, start_body("up", 5000))
			local timer = active_timers()[1]
			for i = 3, 11 do
				on[rids(11)[i]] = false
			end
			gh:dim(G1, start_body("down", 5000))
			assert.is_false(timer.active)
			assert.same({}, active_timers())
			assert.same({ 20 }, deltas(), "no stop to the group")
			assert.same({ "light-01", "light-02" }, light_rids_sent())
		end)

		it("keeps holds on different grouped_lights apart", function()
			members[G1] = { "a" }
			members[G2] = rids(11, "g2")
			light_up({ "a" })
			light_up(rids(11, "g2"))
			gh:dim(G1, start_body("up", 5000))
			gh:dim(G2, start_body("down", 5000))
			assert.equal(1, #active_timers())
			light_sets = {}
			gh:dim(G1, STOP)
			assert.same({ "a" }, light_rids_sent())
			assert.equal(1, #active_timers(), "G2's steps go on")
			fire()
			assert.same({ 20, 20 }, deltas())
			assert.equal(G2, group_sets[2].rid)
			gh:dim(G2, STOP)
			assert.same({}, active_timers())
		end)
	end)

	describe("as before (G2, G6, G7)", function()
		it("passes a lone stop to the group with its level", function()
			assert.is_true(gh:dim(G1, STOP, 42))
			assert.same({ { rid = G1, fields = { dim = "stop", level = 42 } } }, group_sets)
			assert.same({}, light_sets)
		end)

		it("passes a slider's relative move on unchanged, and leaves a running hold alone", function()
			assert.is_true(gh:dim(G1, { dimming_delta = { action = "up", brightness_delta = 30 } }))
			assert.same({ { rid = G1, fields = { dim = "up", delta = 30 } } }, group_sets)
			group_sets = {}
			gh:dim(G1, { dimming_delta = { action = "down", brightness_delta = 12.5 }, dynamics = { duration = 400 } })
			assert.same({ { rid = G1, fields = { dim = "down", delta = 12.5, rate = 400 } } }, group_sets)

			members[G1] = { "a" }
			light_up({ "a" })
			gh:dim(G1, start_body("up", 5000))
			group_sets, light_sets = {}, {}
			gh:dim(G1, { dimming_delta = { action = "down", brightness_delta = 30 }, dynamics = { duration = 0 } })
			assert.same({ { rid = G1, fields = { dim = "down", delta = 30, rate = 0 } } }, group_sets)
			assert.same({}, light_sets, "the hold was not ended")
			gh:dim(G1, STOP)
			assert.same({ "a" }, light_rids_sent())
		end)

		it("passes an unknown action on as the old hook did", function()
			gh:dim(G1, { dimming_delta = { action = "sideways", brightness_delta = 100 } })
			assert.same({ { rid = G1, fields = { dim = "sideways", delta = 100 } } }, group_sets)
		end)

		it("sends a down and its stop to the group, rate and level included, when no member is lit", function()
			members[G1] = { "a", "b" }
			on.b = false
			assert.is_true(gh:dim(G1, start_body("down", 5000), 7))
			assert.same({ { rid = G1, fields = { dim = "down", delta = 100, rate = 5000, level = 7 } } }, group_sets)
			assert.equal("[INFO] group hold 8e7d6c5b down: group, no lit member, 5000 ms", lines[#lines])
			assert.is_nil(gh.holds[G1], "no hold registered")
			group_sets = {}
			gh:dim(G1, STOP, 64)
			assert.same({ { rid = G1, fields = { dim = "stop", level = 64 } } }, group_sets)
			assert.same({}, light_sets)
		end)

		it("sends the start to the group for a grouped_light without known members, up or down", function()
			light_up({ "a" })
			assert.is_true(gh:dim(G2, start_body("down", 2000)))
			assert.same({ { rid = G2, fields = { dim = "down", delta = 100, rate = 2000 } } }, group_sets)
			assert.equal("[INFO] group hold 8e7d6c5b down: group, no members known, 2000 ms", lines[#lines])
			gh:dim(G2, STOP)
			group_sets = {}
			assert.is_true(gh:dim(G2, start_body("up", 2000), 3))
			assert.same({ { rid = G2, fields = { dim = "up", delta = 100, rate = 2000, level = 3 } } }, group_sets)
			assert.equal("[INFO] group hold 8e7d6c5b up: group, no members known, 2000 ms", lines[#lines])
		end)
	end)

	-- Amendment A1: a hold from off dims up about 600 ms after its 1 % start,
	-- before the stream has reported the lamps on.
	describe("an up with no lit member (A1)", function()
		it("takes every member, in member order, per-light up to PER_LIGHT_MAX", function()
			members[G1] = { "c", "a", "b" }
			on.a = false  -- b and c unknown
			assert.is_true(gh:dim(G1, start_body("up", 5000), 1))
			assert.same({ "c", "a", "b" }, light_rids_sent())
			for _, sent in ipairs(light_sets) do
				assert.same({ dim = "up", delta = 100, rate = 5000 }, sent.fields)
			end
			assert.same({}, group_sets)
			assert.equal("[INFO] group hold 8e7d6c5b up: per-light, 3 lights (every member, none lit yet), 5000 ms",
				lines[#lines])
			light_sets = {}
			gh:dim(G1, STOP, 40)
			assert.same({ "c", "a", "b" }, light_rids_sent(), "the stop to the same set")
			assert.same({}, group_sets)
		end)

		it("goes stepped by the member count above PER_LIGHT_MAX", function()
			members[G1] = rids(11)
			assert.is_true(gh:dim(G1, start_body("up", 5000)))
			assert.same({}, light_sets)
			assert.same({ { rid = G1, fields = { dim = "up", delta = 20 } } }, group_sets)
			assert.equal("[INFO] group hold 8e7d6c5b up: stepped, 11 lights (every member, none lit yet), 20 % a step",
				lines[#lines])
			assert.equal(1, #active_timers())
		end)

		it("keeps the lit members alone when one is lit", function()
			members[G1] = { "a", "b", "c" }
			light_up({ "b" })
			gh:dim(G1, start_body("up", 5000))
			assert.same({ "b" }, light_rids_sent())
			assert.equal("[INFO] group hold 8e7d6c5b up: per-light, 1 light, 5000 ms", lines[#lines])
		end)

		it("counts a member listed twice once", function()
			members[G1] = { "a", "b", "a" }
			gh:dim(G1, start_body("up", 5000))
			assert.same({ "a", "b" }, light_rids_sent())
		end)
	end)

	-- Amendment G6a (A2): a running Hue scene keeps the hold on the grouped_light.
	describe("a Hue scene running on the group (G6a)", function()
		local kept

		before_each(function()
			kept = {}
			gh = new_hold({ keep_group = function(rid) kept[#kept + 1] = rid; return true end })
		end)

		it("goes stepped with 3 lit lamps", function()
			members[G1] = { "a", "b", "c" }
			light_up({ "a", "b", "c" })
			assert.is_true(gh:dim(G1, start_body("down", 5000)))
			assert.same({}, light_sets)
			assert.same({ { rid = G1, fields = { dim = "down", delta = 20 } } }, group_sets)
			assert.same({ G1 }, kept)
			assert.equal("[INFO] group hold 8e7d6c5b down: stepped (scene running), 3 lights, 20 % a step", lines[#lines])
			fire()
			assert.same({ 20, 20 }, deltas())
			assert.is_true(gh:dim(G1, STOP))
			assert.same({}, active_timers())
			assert.equal(2, #group_sets, "no group stop")
		end)

		it("goes stepped for an up from off as well", function()
			members[G1] = { "a", "b" }
			gh:dim(G1, start_body("up", 2500))
			assert.same({}, light_sets)
			assert.equal("[INFO] group hold 8e7d6c5b up: stepped (scene running), 2 lights (every member, none lit yet), "
				.. "40 % a step", lines[#lines])
		end)

		it("is not asked, nor named, when the hold is stepped anyway or goes to the group", function()
			members[G1] = rids(11)
			light_up(rids(11))
			gh:dim(G1, start_body("down", 5000))
			assert.equal("[INFO] group hold 8e7d6c5b down: stepped, 11 lights, 20 % a step", lines[#lines])
			gh:dim(G1, STOP)
			members[G2] = { "x" }
			gh:dim(G2, start_body("down", 5000))
			assert.same({}, kept)
		end)

		it("counts false, a raise or a missing callback as no scene running", function()
			members[G1] = { "a" }
			light_up({ "a" })
			for _, keep in ipairs({ function() return false end, function() return "yes" end,
				function() error("no scenes") end, false }) do
				light_sets = {}
				gh = new_hold({ keep_group = keep or nil })
				gh:dim(G1, start_body("up", 5000))
				assert.same({ "a" }, light_rids_sent())
				gh:dim(G1, STOP)
			end
			assert.is_true(saw("[ERROR] group hold: ctx.keep_group raised:"))
		end)

		it("returns what the group queue answers", function()
			gh = new_hold({ group_set = function() return false end })
			assert.is_false(gh:dim(G1, STOP, 42))
			assert.is_false(gh:dim(G1, start_body("up", 5000)))
			gh = new_hold({ group_set = function() return "yes" end })
			assert.is_false(gh:dim(G1, STOP), "only true counts")
		end)
	end)

	describe("stop_all (G8)", function()
		it("cancels every step timer, sends nothing and forgets every hold", function()
			members[G1] = rids(11)
			members[G2] = { "a" }
			light_up(rids(11))
			light_up({ "a" })
			gh:dim(G1, start_body("down", 5000))
			gh:dim(G2, start_body("up", 5000))
			local stale = active_timers()[1]
			group_sets, light_sets = {}, {}
			gh:stop_all()
			assert.same({}, active_timers())
			assert.same({}, group_sets, "the queues are being dropped: no stop is queued")
			assert.same({}, light_sets)
			stale.fn()
			assert.same({}, group_sets, "a timer from before stop_all sends nothing")
			gh:dim(G2, STOP, 9)
			assert.same({ { rid = G2, fields = { dim = "stop", level = 9 } } }, group_sets, "no hold left")
			assert.same({}, light_sets)
		end)

		it("works with no holds and twice", function()
			gh:stop_all()
			gh:stop_all()
			assert.same({}, gh.holds)
		end)
	end)

	describe("callbacks that raise", function()
		it("sends the start to the group when members raises", function()
			gh = new_hold({ members = function() error("boom") end })
			assert.is_true(gh:dim(G1, start_body("up", 5000)))
			assert.same({ dim = "up", delta = 100, rate = 5000 }, group_sets[1].fields)
			assert.is_true(saw("[ERROR] group hold: ctx.members raised:"))
			assert.is_true(saw("boom"))
		end)

		it("counts a light whose is_on raises as off", function()
			gh = new_hold({ is_on = function(rid)
				if rid == "b" then error("no model") end
				return true
			end })
			members[G1] = { "a", "b", "c" }
			gh:dim(G1, start_body("up", 5000))
			assert.same({ "a", "c" }, light_rids_sent())
			assert.is_true(saw("ctx.is_on raised"))
		end)

		it("goes on with the other lights when light_set raises for one", function()
			gh = new_hold({ light_set = function(rid, fields)
				if rid == "a" then error("queue gone") end
				light_sets[#light_sets + 1] = { rid = rid, fields = fields }
				return true
			end })
			members[G1] = { "a", "b" }
			light_up({ "a", "b" })
			assert.is_true(gh:dim(G1, start_body("up", 5000)))
			assert.same({ "b" }, light_rids_sent())
			assert.is_true(saw("ctx.light_set raised"))
			light_sets = {}
			assert.is_true(gh:dim(G1, STOP))
			assert.same({ "b" }, light_rids_sent())
		end)

		it("returns false when group_set raises", function()
			gh = new_hold({ group_set = function() error("no queue") end })
			assert.is_false(gh:dim(G1, STOP, 1))
			assert.is_true(saw("ctx.group_set raised"))
		end)

		it("keeps the first step and the release when set_timer raises", function()
			gh = new_hold({ set_timer = function() error("no timers") end })
			members[G1] = rids(11)
			light_up(rids(11))
			assert.is_true(gh:dim(G1, start_body("down", 5000)))
			assert.same({ 20 }, deltas())
			assert.is_true(saw("ctx.set_timer raised"))
			assert.is_true(gh:dim(G1, STOP))
			assert.same({ 20 }, deltas())
		end)

		it("contains a step that raises inside the timer", function()
			local calls = 0
			gh = new_hold({ group_set = function(rid, fields)
				calls = calls + 1
				if calls == 2 then error("late boom") end
				group_sets[#group_sets + 1] = { rid = rid, fields = fields }
				return true
			end })
			members[G1] = rids(11)
			light_up(rids(11))
			gh:dim(G1, start_body("down", 5000))
			assert.has_no.errors(fire)
			assert.same({}, active_timers(), "the steps end with the raise")
			assert.is_true(saw("ctx.group_set raised"))
			assert.is_true(gh:dim(G1, STOP), "the hold still ends at its release")
		end)

		it("contains a timer whose Cancel raises", function()
			gh = new_hold({ set_timer = function(ms, fn)
				local t = set_timer(ms, fn)
				t.Cancel = function() error("cancel failed") end
				return t
			end })
			members[G1] = rids(11)
			light_up(rids(11))
			gh:dim(G1, start_body("down", 5000))
			assert.has_no.errors(function() gh:dim(G1, STOP) end)
			assert.has_no.errors(function() gh:stop_all() end)
			fire()
			assert.same({ 20 }, deltas(), "the token keeps the uncancelled timer quiet")
		end)

		it("contains a raise inside the step timer", function()
			local errors = {}
			local stand_in = { info = function() end, debug = function() end,
				warn = function() error("warn broke") end,
				error = function(fmt, ...) errors[#errors + 1] = string.format(fmt, ...) end }
			local take = true
			gh = new_hold({ log = stand_in, group_set = function(rid, fields)
				group_sets[#group_sets + 1] = { rid = rid, fields = fields }
				return take
			end })
			members[G1] = rids(11)
			light_up(rids(11))
			gh:dim(G1, start_body("down", 5000))
			take = false
			assert.has_no.errors(fire)
			assert.equal(1, #errors)
			assert.truthy(errors[1]:find("group hold 8e7d6c5b: a step failed:", 1, true))
			assert.same({}, active_timers())
		end)

		it("defaults the timer to C4:SetTimer and the log to common.log", function()
			local armed
			-- busted runs a spec in its own environment: the module sees _G's C4.
			local saved = _G.C4
			finally(function() _G.C4 = saved end)
			_G.C4 = { SetTimer = function(_, ms, fn) armed = { ms = ms, fn = fn }; return { Cancel = function() end } end }
			gh = group_hold.new({ members = function() return rids(11) end, is_on = function() return true end,
				group_set = function(rid, fields) group_sets[#group_sets + 1] = { rid = rid, fields = fields }; return true end })
			gh:dim(G1, start_body("up", 5000))
			assert.equal(1000, armed.ms)
			assert.is_true(saw("[INFO] group hold 8e7d6c5b up: stepped, 11 lights, 20 % a step"))
			armed.fn()
			assert.same({ 20, 20 }, deltas())
		end)
	end)
end)
