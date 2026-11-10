local fake = require("helpers.fake_c4")
local log = require("common.log")

-- Issue #435, docs/load-groups-design.md §6.7 and §8.1 (B): the bridge
-- batches the requests a Load Group's members send for one group command,
-- sends whole Hue rooms and zones as one grouped_light request, and keeps
-- holds lamp by lamp.
describe("bridge.load_groups", function()
	local load_groups, lg, lines, timers, sent, clock
	local devices, zones, covers, busy_lights, busy_groups, token, zone_ok, group_ok

	local G = "1234"

	-- n lamp rids, lamp-01 ... and their devices 101 ...
	local function lamp(i)
		return string.format("lamp-%02d", i)
	end

	local function add_lamps(n)
		for i = 1, n do
			devices[100 + i] = { rid = lamp(i) }
		end
	end

	-- Devices 101 .. 100+n in group `gid` (default G).
	local function join(n, gid, first)
		for i = first or 1, n do
			lg:memberships(100 + i, (gid or G) .. ":0")
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

	local function new_lg(extra)
		local ctx = {
			light_set = function(rid, fields)
				sent[#sent + 1] = { to = "light", rid = rid, fields = fields }
				return true
			end,
			zone_set = function(params)
				sent[#sent + 1] = { to = "zone_set", rid = params.rid, params = params }
				return zone_ok
			end,
			zone_dim = function(params)
				sent[#sent + 1] = { to = "zone_dim", rid = params.rid, params = params }
				return true
			end,
			group_set = function(rid, fields)
				sent[#sent + 1] = { to = "group", rid = rid, fields = fields }
				return group_ok
			end,
			zone_lights = function(rid)
				local z = zones[rid]
				if z then
					return z.grouped, z.lights
				end
				return nil
			end,
			covers = function() return covers end,
			rid_of = function(id)
				local d = devices[id]
				if d then
					return d.rid, d.kind
				end
				return nil
			end,
			light_idle = function(rid) return not busy_lights[rid] end,
			group_idle = function(rid) return not busy_groups[rid] end,
			group_token = function() return token end,
			set_timer = set_timer,
			now = function() return clock end,
			log = log,
		}
		for k, v in pairs(extra or {}) do
			ctx[k] = v
		end
		return load_groups.new(ctx)
	end

	-- A group set-level request as the light device tags it (§6.3).
	local function set(rid, extra, gid)
		local params = { rid = rid, group = gid or G, on = "true", brightness = "40", rate = "0" }
		for k, v in pairs(extra or {}) do
			params[k] = v
		end
		return lg:command("set", params)
	end

	local function dim(rid, direction, gid, extra)
		local params = { rid = rid, group = gid or G, direction = direction }
		if direction ~= "stop" then
			params.duration = "5000"
		end
		for k, v in pairs(extra or {}) do
			params[k] = v
		end
		return lg:command("dim", params)
	end

	local function sent_to(kind)
		local out = {}
		for _, s in ipairs(sent) do
			if s.to == kind then
				out[#out + 1] = s
			end
		end
		return out
	end

	local function rids(list)
		local out = {}
		for i, s in ipairs(list or sent) do
			out[i] = s.rid
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

	local function room(label, grouped, ...)
		return { grouped_light = grouped, label = label, lights = { ... } }
	end

	before_each(function()
		lines = {}
		log.sink = function(line) table.insert(lines, line) end
		log.set_debug(true)
		package.loaded["bridge.load_groups"] = nil
		load_groups = require("bridge.load_groups")
		timers, sent, clock = {}, {}, 5000
		devices, zones, covers, busy_lights, busy_groups = {}, {}, {}, {}, {}
		token, zone_ok, group_ok = true, true, true
		lg = new_lg()
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("module", function()
		it("has the contract's constants as fields (§6.7)", function()
			assert.equal(150, load_groups.BATCH_MS)
			assert.equal(3, load_groups.MISS_LIMIT)
			assert.equal(10, load_groups.PER_LIGHT_MAX)
			assert.is_true(load_groups.COVER)
			assert.equal(2, load_groups.COVER_MIN)
		end)

		it("needs ctx.light_set", function()
			assert.has_error(function() load_groups.new({}) end)
		end)

		it("reads one spelling of a GROUP ID", function()
			assert.equal("1234", load_groups.group_id("1234"))
			assert.equal("1234", load_groups.group_id(" 01234 "))
			assert.equal("1234", load_groups.group_id(1234))
			assert.is_nil(load_groups.group_id("0"))
			assert.is_nil(load_groups.group_id("-5"))
			assert.is_nil(load_groups.group_id("12a"))
			assert.is_nil(load_groups.group_id(""))
			assert.is_nil(load_groups.group_id(nil))
			assert.is_nil(load_groups.group_id({}))
		end)

		it("parses HUE_LOAD_GROUPS' groups, sync flags dropped (§6.3, D13)", function()
			assert.same({ ["1234"] = true, ["5678"] = true }, load_groups.parse_groups("1234:1,5678:0"))
			assert.same({ ["1234"] = true }, load_groups.parse_groups(" 01234 :1, bad:1,:0,0:1"))
			assert.same({}, load_groups.parse_groups("none"))
			assert.same({}, load_groups.parse_groups(""))
			assert.same({}, load_groups.parse_groups(nil))
		end)

		it("maps fields exactly as the HUE_SET and HUE_DIM handlers do", function()
			assert.same({ on = true, brightness = 40, rate = 0 },
				load_groups.set_fields({ on = "true", brightness = "40", rate = "0" }))
			assert.same({ on = false, rate = 300, urgent = true },
				load_groups.set_fields({ on = "false", rate = "300", urgent = "true" }))
			assert.same({ x = 0.3, y = 0.4, mirek = 250 }, load_groups.set_fields({ x = "0.3", y = "0.4", mirek = "250" }))
			assert.same({ dim = "up", rate = 5000 }, load_groups.dim_fields({ direction = "up", duration = "5000" }))
			assert.same({ dim = "stop", level = 37 }, load_groups.dim_fields({ direction = "stop", level = "37" }))
			assert.is_nil(load_groups.dim_fields({ direction = "sideways" }))
		end)

		it("keys a class by the fields a PUT carries, rounded as commands.body rounds them (D8)", function()
			local key = load_groups.class_key
			assert.equal(key({ on = true, brightness = 40, rate = 0 }), key({ on = true, brightness = 40.001, rate = 0.2 }))
			assert.equal(key({ on = true, brightness = 40 }), key({ on = true, brightness = 40, urgent = true }))
			assert.are_not.equal(key({ on = true, brightness = 40 }), key({ on = true, brightness = 40.01 }))
			assert.are_not.equal(key({ on = true, brightness = 40 }), key({ on = true, brightness = 40, x = 0.3, y = 0.3 }))
			assert.are_not.equal(key({ on = true, brightness = 40, rate = 0 }), key({ on = true, brightness = 40, rate = 400 }))
			assert.are_not.equal(key({ on = false }), key({ on = true }))
		end)
	end)

	describe("batches (D7)", function()
		before_each(function()
			add_lamps(3)
			join(3)
		end)

		it("close as soon as every expected member has sent", function()
			assert.is_true(set(lamp(1)))
			assert.is_true(set(lamp(2)))
			assert.same({}, sent, "nothing goes out before the close")
			assert.equal(1, #active_timers())
			assert.equal(150, active_timers()[1].ms)
			assert.is_true(set(lamp(3)))
			assert.same({ lamp(1), lamp(2), lamp(3) }, rids())
			assert.same({}, active_timers(), "the timer is cancelled")
			assert.same({ on = true, brightness = 40, rate = 0 }, sent[1].fields)
		end)

		it("close at BATCH_MS when a member does not send", function()
			set(lamp(1))
			set(lamp(2))
			assert.same({}, sent)
			fire()
			assert.same({ lamp(1), lamp(2) }, rids())
		end)

		it("wait for the timer while no member is known (a restart before the hellos, E19)", function()
			lg = new_lg()
			set(lamp(1))
			assert.same({}, sent)
			fire()
			assert.same({ lamp(1) }, rids())
		end)

		it("close at once for a group of one known member", function()
			lg:memberships(101, "777:1")
			set(lamp(1), nil, "777")
			assert.same({ lamp(1) }, rids())
		end)

		it("close at a second request for a rid and open a new one with it", function()
			set(lamp(1))
			set(lamp(1), { brightness = "60" })
			assert.same({ lamp(1) }, rids())
			assert.equal(40, sent[1].fields.brightness)
			assert.equal(1, #active_timers(), "the new batch waits")
			set(lamp(2), { brightness = "60" })
			set(lamp(3), { brightness = "60" })
			assert.same({ lamp(1), lamp(1), lamp(2), lamp(3) }, rids())
			assert.equal(60, sent[2].fields.brightness)
			assert.is_true(saw("closed (a second request for lamp-01)"))
		end)

		it("keeps the groups apart (E22)", function()
			lg:memberships(101, "1234:0,5678:0")
			lg:memberships(102, "5678:0")
			set(lamp(1))
			set(lamp(1), nil, "5678")
			assert.same({}, sent, "a request in another group is no second request")
			set(lamp(2), nil, "5678")
			assert.same({ lamp(1), lamp(2) }, rids(), "group 5678 had every member")
			fire()
			assert.same({ lamp(1), lamp(2), lamp(1) }, rids())
		end)

		it("reads the GROUP ID in one spelling", function()
			set(lamp(1), nil, "01234")
			set(lamp(2), nil, " 1234")
			set(lamp(3))
			assert.equal(3, #sent)
		end)

		it("take nothing that is no load group request", function()
			assert.is_false(lg:command("set", { rid = lamp(1) }))
			assert.is_false(lg:command("set", { rid = lamp(1), group = "abc" }))
			assert.is_false(lg:command("set", { rid = lamp(1), group = "0" }))
			assert.is_false(lg:command("set", { group = G }))
			assert.is_false(lg:command("set", { rid = "", group = G }))
			assert.is_false(lg:command("level", { rid = lamp(1), group = G }))
			assert.is_false(lg:command("set", nil))
			assert.is_false(dim(lamp(1), "sideways"))
			assert.same({}, sent)
			assert.same({}, active_timers())
		end)
	end)

	describe("covers (D8)", function()
		before_each(function()
			add_lamps(6)
		end)

		it("send members that make up a whole zone as one group request", function()
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			join(3)
			clock = 5000
			set(lamp(1))
			clock = 5040
			set(lamp(2))
			set(lamp(3))
			assert.same({ "group", "light" }, { sent[1].to, sent[2].to })
			assert.equal("gl-island", sent[1].rid)
			assert.same({ on = true, brightness = 40, rate = 0 }, sent[1].fields)
			assert.equal(lamp(3), sent[2].rid)
			assert.is_true(saw("load group 1234: 3 lights in 40 ms: Island (zone) as 1 request, 1 light alone"))
		end)

		it("send every lamp alone when a lamp of the zone is missing", function()
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2), lamp(3)) }
			join(2)
			set(lamp(1))
			set(lamp(2))
			assert.same({}, sent_to("group"))
			assert.same({ lamp(1), lamp(2) }, rids())
		end)

		it("send two disjoint rooms as two requests, the largest first, never two that overlap", function()
			covers = {
				room("Hall (room)", "gl-hall", lamp(4), lamp(5)),
				room("Corner (zone)", "gl-corner", lamp(3), lamp(4)),
				room("Kitchen (room)", "gl-kitchen", lamp(1), lamp(2), lamp(3)),
			}
			join(5)
			for i = 1, 5 do
				set(lamp(i))
			end
			assert.same({ "gl-kitchen", "gl-hall" }, rids())
			assert.same({ "group", "group" }, { sent[1].to, sent[2].to })
			assert.is_true(saw("Corner (zone) (2 lights) refused: overlaps one taken before it"))
		end)

		it("prefer the larger of two overlapping candidates", function()
			covers = {
				room("A small (zone)", "gl-small", lamp(1), lamp(2)),
				room("Z big (room)", "gl-big", lamp(1), lamp(2), lamp(3)),
			}
			join(3)
			for i = 1, 3 do
				set(lamp(i))
			end
			assert.same({ "gl-big" }, rids())
		end)

		it("break a tie between candidates of one size by label", function()
			covers = {
				room("Pantry (zone)", "gl-pantry", lamp(2), lamp(3)),
				room("Den (zone)", "gl-den", lamp(1), lamp(2)),
			}
			join(3)
			for i = 1, 3 do
				set(lamp(i))
			end
			assert.same({ "gl-den", lamp(3) }, rids())
		end)

		it("fold a zone light member's own lamps into its request when the fields match (D8 a, E21)", function()
			devices[201] = { rid = "zone-island", kind = "group" }
			zones["zone-island"] = { grouped = "gl-island", lights = { lamp(1), lamp(2) } }
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			join(2)
			lg:memberships(201, G .. ":0")
			set(lamp(1))
			set("zone-island")
			set(lamp(2))
			assert.equal(1, #sent)
			assert.equal("zone_set", sent[1].to)
			assert.equal("zone-island", sent[1].params.rid)
			assert.is_true(saw("Island (zone) zone light as 1 request (2 lights folded in)"))
		end)

		it("not fold a lamp whose fields differ from the zone light's", function()
			devices[201] = { rid = "zone-island", kind = "group" }
			zones["zone-island"] = { grouped = "gl-island", lights = { lamp(1), lamp(2) } }
			join(2)
			lg:memberships(201, G .. ":0")
			set("zone-island")
			set(lamp(1))
			set(lamp(2), { x = "0.3", y = "0.3" }) -- a turn-on colour kept while off
			assert.same({ "zone_set", "light" }, { sent[1].to, sent[2].to })
			assert.equal(lamp(2), sent[2].rid)
			assert.equal(0.3, sent[2].fields.x)
		end)

		it("not fold a lamp with an older request in its queue", function()
			devices[201] = { rid = "zone-island", kind = "group" }
			zones["zone-island"] = { grouped = "gl-island", lights = { lamp(1), lamp(2) } }
			join(2)
			lg:memberships(201, G .. ":0")
			busy_lights[lamp(2)] = true
			set("zone-island")
			set(lamp(1))
			set(lamp(2))
			assert.same({ "zone-island", lamp(2) }, rids())
		end)

		it("send the folded lamps alone when the zone light's request was not queued", function()
			devices[201] = { rid = "zone-island", kind = "group" }
			zones["zone-island"] = { grouped = "gl-island", lights = { lamp(1), lamp(2) } }
			join(2)
			lg:memberships(201, G .. ":0")
			zone_ok = false
			set("zone-island")
			set(lamp(1))
			set(lamp(2))
			assert.same({ "zone-island", lamp(1), lamp(2) }, rids())
		end)

		it("split a class at differing fields (a turn-on colour on one lamp)", function()
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			join(2)
			set(lamp(1))
			set(lamp(2), { mirek = "300" })
			assert.same({}, sent_to("group"))
			assert.same({ lamp(1), lamp(2) }, rids())
		end)

		it("send a cover urgent when any of its entries was, urgent being no part of the class", function()
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			join(2)
			set(lamp(1), { urgent = "true", rate = "1000" })
			set(lamp(2), { rate = "1000" })
			assert.equal(1, #sent)
			assert.same({ on = true, brightness = 40, rate = 1000, urgent = true }, sent[1].fields)
		end)

		it("refuse a cover while its grouped_light is busy", function()
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			busy_groups["gl-island"] = true
			join(2)
			set(lamp(1))
			set(lamp(2))
			assert.same({ lamp(1), lamp(2) }, rids())
			assert.is_true(saw("refused: its grouped_light is busy"))
		end)

		it("refuse a cover while one of its lamps is busy", function()
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			busy_lights[lamp(2)] = true
			join(2)
			set(lamp(1))
			set(lamp(2))
			assert.same({ lamp(1), lamp(2) }, rids())
			assert.is_true(saw("refused: light lamp-02 is busy"))
		end)

		it("refuse a cover without a group token", function()
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			token = false
			join(2)
			set(lamp(1))
			set(lamp(2))
			assert.same({ lamp(1), lamp(2) }, rids())
			assert.is_true(saw("refused: no group token"))
		end)

		it("take a smaller cover when a larger one is refused", function()
			covers = {
				room("Kitchen (room)", "gl-kitchen", lamp(1), lamp(2), lamp(3)),
				room("Island (zone)", "gl-island", lamp(1), lamp(2)),
			}
			busy_groups["gl-kitchen"] = true
			join(3)
			for i = 1, 3 do
				set(lamp(i))
			end
			assert.same({ "gl-island", lamp(3) }, rids())
		end)

		it("send a cover's lamps alone when the group queue takes nothing", function()
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			group_ok = false
			join(2)
			set(lamp(1))
			set(lamp(2))
			assert.same({ "gl-island", lamp(1), lamp(2) }, rids())
			assert.is_true(saw("the group queue took nothing for Island (zone)"))
		end)

		it("make no cover of a class that sets nothing", function()
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			join(2)
			lg:command("set", { rid = lamp(1), group = G, rate = "0" })
			lg:command("set", { rid = lamp(2), group = G, rate = "0" })
			assert.same({ lamp(1), lamp(2) }, rids())
		end)

		it("send every lamp alone with COVER = false", function()
			load_groups.COVER = false
			devices[201] = { rid = "zone-island", kind = "group" }
			zones["zone-island"] = { grouped = "gl-island", lights = { lamp(3), lamp(4) } }
			covers = { room("Kitchen (room)", "gl-kitchen", lamp(1), lamp(2)) }
			join(4)
			lg:memberships(201, G .. ":0")
			for i = 1, 4 do
				set(lamp(i))
			end
			set("zone-island")
			assert.same({}, sent_to("group"))
			assert.same({ "zone-island", lamp(1), lamp(2), lamp(3), lamp(4) }, rids())
			assert.is_true(saw("(covers off)"))
		end)

		it("send a zone light member found by its kind or by ctx.zone_lights through zone_set", function()
			zones["zone-den"] = { grouped = "gl-den", lights = { lamp(5), lamp(6) } }
			set("zone-den")
			fire()
			assert.same({ "zone_set" }, { sent[1].to })
			lg:command("set", { rid = "zone-x", group = G, on = "false" }, "zone")
			fire()
			assert.equal("zone_set", sent[2].to)
		end)
	end)

	describe("holds (D9, D10)", function()
		it("never cover dims, and send a zone light's dim through zone_dim", function()
			add_lamps(2)
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			devices[201] = { rid = "zone-den", kind = "group" }
			join(2)
			lg:memberships(201, G .. ":0")
			dim(lamp(1), "up")
			dim(lamp(2), "up")
			dim("zone-den", "up")
			assert.same({ "light", "light", "zone_dim" }, { sent[1].to, sent[2].to, sent[3].to })
			assert.same({ dim = "up", rate = 5000 }, sent[1].fields)
			assert.equal("5000", sent[3].params.duration)
			assert.is_true(saw("2 lights dim up one by one, 1 zone light dim up"))
		end)

		it("pace the lamps past the tenth, in the same order for starts and stops", function()
			add_lamps(12)
			join(12)
			for i = 1, 12 do
				dim(lamp(i), "up")
			end
			assert.equal(12, #sent)
			for i = 1, 12 do
				assert.equal(lamp(i), sent[i].rid)
				assert.equal(i > 10 and true or nil, sent[i].fields.paced, "start " .. i)
			end
			assert.is_true(saw("12 lights dim up one by one, 2 paced"))
			sent = {}
			for i = 12, 1, -1 do -- the stops arrive in another order
				dim(lamp(i), "stop", nil, { level = "50" })
			end
			assert.equal(12, #sent)
			for i = 1, 12 do
				assert.equal(lamp(i), sent[i].rid, "stops go in the starts' order")
				assert.equal("stop", sent[i].fields.dim)
				assert.equal(i > 10 and true or nil, sent[i].fields.paced, "stop " .. i)
			end
			assert.is_true(saw("12 lights stop one by one, 2 paced"))
		end)

		it("pace urgent sets past the tenth by dropping urgent, which would clear paced (§6.8)", function()
			add_lamps(12)
			join(12)
			for i = 1, 12 do
				set(lamp(i), { urgent = "true", brightness = tostring(30 + i) })
			end
			assert.equal(12, #sent)
			for i = 1, 12 do
				local fields = sent[i].fields
				if i <= 10 then
					assert.is_true(fields.urgent, "set " .. i)
					assert.is_nil(fields.paced)
				else
					assert.is_nil(fields.urgent, "set " .. i)
					assert.is_true(fields.paced)
				end
			end
		end)

		it("leave sets that are not urgent alone", function()
			add_lamps(12)
			join(12)
			for i = 1, 12 do
				set(lamp(i), { brightness = tostring(30 + i) })
			end
			for i = 1, 12 do
				assert.is_nil(sent[i].fields.paced)
				assert.is_nil(sent[i].fields.urgent)
			end
		end)

		it("send the sets of a batch before its dims (a hold up while some lamps are off)", function()
			add_lamps(3)
			join(3)
			dim(lamp(1), "up")
			set(lamp(2), { brightness = "1" })
			dim(lamp(3), "up")
			assert.same({ lamp(2), lamp(1), lamp(3) }, rids())
		end)
	end)

	describe("release (D11)", function()
		before_each(function()
			add_lamps(3)
			join(3)
		end)

		it("sends that rid's entry alone and leaves the rest in the batch", function()
			set(lamp(1), { urgent = "true" })
			set(lamp(2))
			assert.is_true(lg:release(lamp(1)))
			assert.same({ lamp(1) }, rids())
			assert.same({ on = true, brightness = 40, rate = 0, urgent = true }, sent[1].fields)
			assert.equal(1, #active_timers(), "the batch stays open")
			set(lamp(3))
			assert.same({ lamp(1), lamp(2), lamp(3) }, rids(), "the released member counts as heard from")
		end)

		it("sends nothing for a rid in no batch", function()
			set(lamp(1))
			assert.is_false(lg:release(lamp(2)))
			assert.is_false(lg:release(nil))
			assert.same({}, sent)
		end)

		it("sends a zone light's entry through zone_set or zone_dim", function()
			devices[201] = { rid = "zone-den", kind = "group" }
			lg:memberships(201, G .. ":0,5678:0")
			lg:memberships(101, "5678:0") -- so that neither batch closes at once
			set("zone-den")
			lg:release("zone-den")
			dim("zone-den", "up", "5678")
			lg:release("zone-den")
			assert.same({ "zone_set", "zone_dim" }, { sent[1].to, sent[2].to })
		end)

		it("counts nothing when every entry was released", function()
			set(lamp(1))
			lg:release(lamp(1))
			fire()
			assert.same({ lamp(1) }, rids())
			assert.is_true(saw("closed with nothing left to send"))
		end)
	end)

	describe("self-healing membership (D15)", function()
		before_each(function()
			add_lamps(3)
			join(3)
		end)

		local function timed_batch()
			set(lamp(1))
			set(lamp(2))
			fire()
		end

		it("stops waiting for a member missing from three timed-out batches", function()
			timed_batch()
			timed_batch()
			assert.is_false(saw("missed 3 batches"))
			timed_batch()
			assert.is_true(saw("load group 1234: device 103 (lamp-03) missed 3 batches in a row"))
			sent = {}
			set(lamp(1))
			set(lamp(2))
			assert.same({ lamp(1), lamp(2) }, rids(), "closes without waiting")
		end)

		it("waits again after the member's HUE_LOAD_GROUPS", function()
			timed_batch()
			timed_batch()
			timed_batch()
			lg:memberships(103, G .. ":1")
			assert.is_true(saw("load group 1234: device 103 is waited for again"))
			sent = {}
			set(lamp(1))
			set(lamp(2))
			assert.same({}, sent)
		end)

		it("waits again after a tagged request of the member", function()
			timed_batch()
			timed_batch()
			timed_batch()
			sent = {}
			set(lamp(3))
			assert.same({}, sent, "the request waits for the others")
			set(lamp(1))
			set(lamp(2))
			assert.equal(3, #sent)
			sent = {}
			set(lamp(1))
			set(lamp(2))
			assert.same({}, sent, "lamp-03 is waited for again")
		end)

		it("starts counting again when the member sends", function()
			timed_batch()
			timed_batch()
			set(lamp(1))
			set(lamp(2))
			set(lamp(3))
			timed_batch()
			timed_batch()
			assert.is_false(saw("missed 3 batches"))
		end)

		it("counts no miss at a batch closed by a second request", function()
			timed_batch()
			timed_batch()
			set(lamp(1))
			set(lamp(1)) -- closes the first batch: no miss for lamp-03
			set(lamp(2))
			fire() -- the second batch, by time: the third miss
			assert.is_true(saw("missed 3 batches"))
			assert.equal(1, select(2, table.concat(lines, "\n"):gsub("missed 3 batches", "")))
		end)
	end)

	describe("memberships", function()
		before_each(function()
			add_lamps(3)
		end)

		it("replace the device's groups; none clears them", function()
			join(2)
			lg:memberships(102, "5678:0")
			set(lamp(1))
			assert.same({ lamp(1) }, rids(), "lamp-02 left group 1234: lamp-01 is its only member")
			lg:memberships(101, "none")
			set(lamp(1))
			assert.equal(1, #sent, "no member known: the batch waits")
			fire()
			assert.equal(2, #sent)
		end)

		it("close an open batch when a member that has not sent leaves", function()
			join(2)
			set(lamp(1))
			assert.same({}, sent)
			lg:memberships(102, "none")
			assert.same({ lamp(1) }, rids())
		end)

		it("ignore a message without a device id", function()
			assert.is_false(lg:memberships(nil, "1234:1"))
			assert.is_false(lg:memberships("abc", "1234:1"))
			assert.is_true(saw("HUE_LOAD_GROUPS without a device id ignored"))
		end)

		it("leave out a member that is not linked or gone", function()
			join(2)
			devices[102] = nil -- its light deleted in Hue, or its device no longer linked (E12)
			set(lamp(1))
			assert.same({ lamp(1) }, rids())
		end)

		it("forget a device: its groups go and its open entry goes unsent", function()
			join(3)
			set(lamp(1))
			set(lamp(2))
			assert.is_true(lg:forget_device(102))
			assert.same({}, sent)
			set(lamp(3))
			assert.same({ lamp(1), lamp(3) }, rids())
			sent = {}
			set(lamp(1))
			set(lamp(3))
			assert.equal(2, #sent, "device 102 is not waited for any more")
		end)

		it("forget a device after the registry no longer knows it (goodbye first)", function()
			join(2)
			set(lamp(2))
			devices[102] = nil
			lg:forget_device("102")
			assert.same({}, sent)
			fire()
			assert.same({}, sent, "nothing was left to send")
			assert.is_false(lg:forget_device(nil))
		end)

		it("stop_all cancels the timers and drops the open batches unsent", function()
			join(3)
			set(lamp(1))
			lg:memberships(101, "5678:0")
			set(lamp(1), nil, "5678")
			assert.equal(1, #sent)
			lg:stop_all()
			assert.same({}, active_timers())
			fire()
			assert.equal(1, #sent, "the batch of group 1234 went unsent")
			set(lamp(2))
			assert.equal(1, #sent)
			set(lamp(3))
			assert.equal(3, #sent, "it works again after, the memberships kept")
		end)
	end)

	describe("robustness", function()
		before_each(function()
			add_lamps(3)
		end)

		it("logs a raising hook and sends the rest", function()
			lg = new_lg({
				light_set = function(rid, fields)
					if rid == lamp(1) then
						error("boom")
					end
					sent[#sent + 1] = { to = "light", rid = rid, fields = fields }
					return true
				end,
			})
			join(2)
			set(lamp(1))
			set(lamp(2))
			assert.same({ lamp(2) }, rids())
			assert.is_true(saw("ctx.light_set raised"))
		end)

		it("sends lamps alone when covers() raises", function()
			lg = new_lg({ covers = function() error("no cache") end })
			join(2)
			set(lamp(1))
			set(lamp(2))
			assert.same({ lamp(1), lamp(2) }, rids())
			assert.is_true(saw("ctx.covers raised"))
		end)

		it("refuses a cover when an idle hook is missing", function()
			covers = { room("Island (zone)", "gl-island", lamp(1), lamp(2)) }
			lg = new_lg({ light_idle = false })
			join(2)
			set(lamp(1))
			set(lamp(2))
			assert.same({ lamp(1), lamp(2) }, rids())
		end)

		it("sends at once without a timer", function()
			lg = new_lg({ set_timer = function() return nil end })
			join(2)
			set(lamp(1))
			assert.same({ lamp(1) }, rids())
			assert.is_true(saw("no timer for the batch"))
		end)

		it("a timer that fires after its batch closed sends nothing", function()
			join(2)
			set(lamp(1))
			local first = timers[1]
			set(lamp(2))
			assert.equal(2, #sent)
			first.fn()
			assert.equal(2, #sent)
		end)

		it("runs on C4:SetTimer and C4:GetTime by default", function()
			local c4 = fake.install_c4()
			lg = new_lg({ set_timer = false, now = false })
			join(3)
			set(lamp(1))
			c4.advance(30)
			set(lamp(2), { brightness = "41" })
			c4.advance(100)
			assert.same({}, sent)
			c4.advance(20)
			assert.same({ lamp(1), lamp(2) }, rids())
			assert.is_true(saw("closed (after 150 ms): lamp-01 +0 ms, lamp-02 +30 ms; 3 members waited for, missing device 103"))
		end)
	end)

	describe("logs (D16)", function()
		it("names the close, the arrivals and the members missing at debug", function()
			add_lamps(3)
			join(3)
			clock = 1000
			set(lamp(1))
			clock = 1012
			set(lamp(2))
			fire()
			assert.is_true(saw("load group 1234: closed (after 150 ms): lamp-01 +0 ms, lamp-02 +12 ms; 3 members "
				.. "waited for, missing device 103"))
			assert.is_true(saw("load group 1234: 2 lights in 12 ms: 2 lights alone"))
		end)

		it("says nothing at info or debug without Debug Mode", function()
			log.set_debug(false)
			add_lamps(2)
			join(2)
			set(lamp(1))
			set(lamp(2))
			assert.same({}, lines)
		end)
	end)
end)
