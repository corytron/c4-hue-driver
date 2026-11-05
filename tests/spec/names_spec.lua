-- bridge/names.lua: the two-way names of docs/simplify-research-names-sync.md
-- §5 (cases N1-N34) as docs/simplify-actions-design.md §3 builds them. The
-- registries are small stand-ins with the interface names.lua reads; the
-- clock and the timers are the spec's own.

local log = require("common.log")

local T0_MS = 1762300000000

describe("bridge.names", function()
	local names, n, now_ms, timers, store, composer, puts, renames, actions, changed, user_busy, ready
	local regs, auto_answer, held_answers, logged

	-- Timers -------------------------------------------------------------------------------
	local function set_timer(ms, fn)
		local t = { at = now_ms + ms, fn = fn, active = true }
		function t.Cancel() t.active = false end
		timers[#timers + 1] = t
		return t
	end

	-- Move the clock by `ms`, firing every timer that comes due, in due order.
	local function advance(ms)
		local target = now_ms + ms
		while true do
			local next_t
			for _, t in ipairs(timers) do
				if t.active and t.at <= target and (not next_t or t.at < next_t.at) then next_t = t end
			end
			if not next_t then break end
			now_ms = math.max(now_ms, next_t.at)
			next_t.active = false
			next_t.fn()
		end
		now_ms = target
	end

	-- Registries ---------------------------------------------------------------------------
	local function fake_reg(kind)
		local r = { kind = kind, registry = {}, conflicts = {}, resyncing = false }
		r.reg = {
			rids = function(_, state)
				local out = {}
				for rid, e in pairs(r.registry) do
					if state == nil or e.state == state then out[#out + 1] = rid end
				end
				table.sort(out)
				return out
			end,
		}
		function r.hue_name(_, _, entry) return entry.hue end
		function r.name_form(_, _, entry) return entry.form or {} end
		function r.name_requests(_, rid, name)
			return { { method = "PUT", path = "/clip/v2/resource/" .. kind .. "/" .. rid,
				body = { metadata = { name = name } } } }
		end
		function r.remember_proxy(self, rid, id) self.registry[rid].proxy_id = id end
		function r.entry_label(_, _, entry) return entry.hue end
		function r.name_source(_, rid, entry) return entry.source or (kind .. ":" .. rid) end
		return r
	end

	-- A linked entry: rid, the Hue name, the Composer name, its device and proxy ids.
	local function add(kind, rid, hue, comp, ids)
		ids = ids or {}
		local device_id = ids.device or (1000 + #regs[kind].reg:rids() + (kind == "scene" and 100 or 0))
		local proxy_id = ids.proxy or device_id + 5000
		if ids.proxy == false then
			proxy_id = nil
		end
		regs[kind].registry[rid] = { device_id = device_id, proxy_id = proxy_id, state = "linked", hue = hue,
			form = ids.form, name_dismissed = ids.dismissed, source = ids.source }
		composer[proxy_id or device_id] = comp
		return regs[kind].registry[rid]
	end

	local function new_names(extra)
		local ctx = {
			persist_get = function(k) return store[k] end,
			persist_set = function(k, v) store[k] = v end,
			registries = regs,
			display_name = function(id) return composer[id] end,
			rename_device = function(id, name)
				renames[#renames + 1] = { id = id, name = name }
				composer[id] = name
			end,
			put_name = function(kind, rid, name, done)
				puts[#puts + 1] = { kind = kind, rid = rid, name = name, at = now_ms }
				if auto_answer then
					regs[kind].registry[rid].hue = name  -- the bridge takes it
					done(true)
				else
					held_answers[#held_answers + 1] = { kind = kind, rid = rid, name = name, done = done }
				end
			end,
			user_active = function() return user_busy end,
			bridge_ready = function() return ready end,
			last_action = function(text) actions[#actions + 1] = text end,
			attention_changed = function() changed = changed + 1 end,
			set_timer = set_timer,
			now_ms = function() return now_ms end,
		}
		for k, v in pairs(extra or {}) do ctx[k] = v end
		return names.new(ctx)
	end

	-- Every name PUT so far as "name" strings.
	local function put_names()
		local out = {}
		for i, p in ipairs(puts) do out[i] = p.name end
		return out
	end

	local function rename_names()
		local out = {}
		for i, r in ipairs(renames) do out[i] = r.name end
		return out
	end

	local function pair(kind, rid)
		return n.pairs[kind .. ":" .. rid]
	end

	local function saw_log(text)
		for _, line in ipairs(logged) do
			if line:find(text, 1, true) then return true end
		end
		return false
	end

	-- A light "l1" (proxy 6000) paired as Desk Lamp both sides, the names ready.
	local function paired_light()
		add("light", "l1", "Desk Lamp", "Desk Lamp", { device = 1000, proxy = 6000 })
		n = new_names()
		n:pass("light")
		advance(5000)
		assert.same({ h = "Desk Lamp", c = "Desk Lamp" }, { h = pair("light", "l1").h, c = pair("light", "l1").c })
		actions = {}
	end

	before_each(function()
		package.loaded["bridge.names"] = nil
		names = require("bridge.names")
		logged = {}
		log.sink = function(line) table.insert(logged, line) end
		log.set_debug(true)
		now_ms, timers, store, composer, puts, renames, actions, changed = T0_MS, {}, {}, {}, {}, {}, {}, 0
		user_busy, ready, auto_answer, held_answers = false, true, true, {}
		regs = { light = fake_reg("light"), scene = fake_reg("scene"), motion = fake_reg("motion") }
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("the forms f and g (research §5.2)", function()
		it("maps a zone scene, a time-based scene and an owner affix both ways", function()
			local zone = { prefix = "Upstairs " }
			assert.equal("Upstairs Relax", names.f("Relax", nil, zone))
			assert.equal("Relax", names.g("Upstairs Relax", nil, zone))
			assert.equal("Relax", names.g("Relax", nil, zone), "no prefix: the name whole")
			local smart = { smart = true }
			assert.equal("Golden hours", names.f("Golden hours 4", nil, smart))
			assert.equal("Evening", names.g("Evening", nil, smart), "N32: the app's number goes")
			local p = { pre = "Kitchen " }
			assert.equal("Kitchen Island", names.f("Island", p, {}))
			assert.equal("Lamp", names.g("Kitchen Lamp", p, {}))
			assert.equal("Lamp Kitchen", names.g("Lamp Kitchen", p, {}), "N30: the affix is dropped once it is gone")
			assert.equal("Chill", names.g("Downstairs Chill", { zp = "Downstairs " }, zone),
				"N23: the prefix the pair agreed on, after the zone was renamed")
			assert.equal("Chill", names.g("Upstairs Chill", { zp = "Downstairs " }, zone), "or the zone's current one")
		end)

		it("relates names that agree in form, with the owner's affix at word boundaries only", function()
			assert.same({ true }, { names.related("Desk Lamp", "Desk Lamp", {}) })
			assert.same({ true, "Kitchen " }, { names.related("Kitchen Pendant", "Pendant", {}) })
			assert.same({ true, nil, " (2)" }, { names.related("Desk Lamp (2)", "Desk Lamp", {}) })
			assert.is_false((names.related("Banana", "nan", {})))
			assert.is_false((names.related("Reading Lamp", "Desk Lamp", {})))
			assert.is_true((names.related("Golden hours", "Golden hours 4", { smart = true })))
			assert.is_true((names.related("Relax", "Relax", { prefix = "Upstairs " })), "the owner dropped the prefix")
		end)

		it("N25: checks Hue's 32 bytes before any request, and cuts at a character", function()
			assert.is_nil(names.too_long(string.rep("a", 32)))
			assert.equal("33 characters, Hue takes 32", names.too_long(string.rep("a", 33)))
			assert.is_nil(names.too_long(string.rep("é", 16)))
			assert.equal("34 bytes, Hue takes 32 (accented letters count twice)", names.too_long(string.rep("é", 17)))
			assert.equal(string.rep("é", 16), names.cut(string.rep("é", 17)))
			assert.equal("Kitchen Under-Cabinet Left Strip", names.cut("Kitchen Under-Cabinet Left Strip 2"))
			assert.equal("ab", names.cut("ab"))
		end)
	end)

	describe("put_via", function()
		it("sends the requests in turn; the first decides, a later failure is only logged", function()
			local sent, answers = {}, { { ok = true, code = 200 }, { ok = false, code = 404, err = "HTTP 404" } }
			local put = names.put_via({ light = {
				name_requests = function() return { { path = "/device/d1" }, { path = "/light/l1" } } end,
			} }, function(req, cb)
				sent[#sent + 1] = req.path
				cb(answers[#sent])
			end, log)
			local got
			put("light", "l1", "Desk", function(...) got = { ... } end)
			assert.same({ "/device/d1", "/light/l1" }, sent)
			assert.same({ true }, got)
			assert.is_true(saw_log("the name itself was taken"))
		end)

		it("reports Hue's own words and the status of a refused first request", function()
			local put = names.put_via({ scene = { name_requests = function() return { { path = "/scene/s1" } } end } },
				function(_, cb)
					cb({ ok = false, code = 400, err = "HTTP 400", json = { errors = { { description = "Invalid name" } } } })
				end)
			local got
			put("scene", "s1", "x", function(...) got = { ... } end)
			assert.same({ false, "Invalid name", 400 }, got)
			put("motion", "m1", "x", function(...) got = { ... } end)
			assert.same({ false, "no way to write this name on the bridge" }, got)
		end)
	end)

	describe("the rule (research §5.1)", function()
		it("N1: a Composer rename goes to Hue after the settle, the pair moves once Hue answers", function()
			paired_light()
			composer[6000] = "Reading Lamp"
			assert.is_true(n:on_composer_rename(6000))
			assert.equal(0, #puts, "nothing at once: only from a timer")
			advance(1500)
			assert.same({ "Reading Lamp" }, put_names())
			assert.same({ h = "Reading Lamp", c = "Reading Lamp" }, { h = pair("light", "l1").h, c = pair("light", "l1").c })
			advance(3000)
			assert.same({ "Name sent to Hue: Reading Lamp (was Desk Lamp in Hue)" }, actions)
			assert.equal(0, #renames)
			assert.equal("Reading Lamp", store.hue_name_pairs.pairs["light:l1"].h, "persisted under the new key")
			assert.equal(1, store.hue_name_pairs.v)
		end)

		it("N2: a Hue rename renames the Control4 device through its proxy, the pair set before the call", function()
			paired_light()
			regs.light.registry.l1.hue = "Office Lamp"
			assert.is_true(n:on_hue_name("light", "l1"))
			advance(1500)
			assert.same({ { id = 6000, name = "Office Lamp" } }, renames)
			assert.equal("Office Lamp", pair("light", "l1").c)
			assert.equal(0, #puts)
			advance(3000)
			assert.same({ "Name taken from Hue: Office Lamp (device 1000, was Desk Lamp)" }, actions)
		end)

		it("N3: both renamed while nobody watched: Control4 wins and says which Hue name it replaced", function()
			paired_light()
			regs.light.registry.l1.hue = "Office lamp"
			composer[6000] = "Reading Lamp"
			n:pass("light")
			advance(3000)
			assert.same({ "Reading Lamp" }, put_names())
			assert.equal(0, #renames)
			assert.same({ "Both renamed: kept the Composer name Reading Lamp and sent it to Hue (Hue had Office lamp)" },
				actions)
		end)

		it("N3: both renamed to names that agree in form: only the pair moves", function()
			paired_light()
			regs.light.registry.l1.hue = "Reading Lamp"
			composer[6000] = "Reading Lamp"
			n:pass("light")
			advance(3000)
			assert.same({}, puts)
			assert.same({}, renames)
			assert.equal("Reading Lamp", pair("light", "l1").h)
		end)

		it("N5, N6: the echo of each write is absorbed, with or without its event", function()
			paired_light()
			composer[6000] = "Reading Lamp"
			n:on_composer_rename(6000)
			advance(1500)
			-- Hue's update event for our PUT: the same name, nothing more happens.
			n:on_hue_name("light", "l1")
			advance(1000)
			assert.equal(1, #puts)
			assert.equal(0, #renames)
			-- A Hue rename, then our RenameDevice's echo as OnItemNameChanged (T4).
			regs.light.registry.l1.hue = "Office Lamp"
			n:on_hue_name("light", "l1")
			advance(3000)
			assert.equal(1, #renames)
			assert.is_true(n:on_composer_rename(6000))
			advance(1000)
			assert.equal(1, #puts, "no PUT back")
			-- And without any event: the next pass finds both sides agree.
			n:pass("light")
			advance(3000)
			assert.equal(1, #puts)
			assert.equal(1, #renames)
		end)

		it("N7: a side that keeps other text than we sent is taken as the echo, within 10 s", function()
			paired_light()
			composer[6000] = "Reading Lamp "
			n:on_composer_rename(6000)
			advance(1500)
			assert.same({ "Reading Lamp" }, put_names(), "display names go out")
			regs.light.registry.l1.hue = "Reading lamp"  -- Hue normalised it
			n:on_hue_name("light", "l1")
			advance(1000)
			assert.equal("Reading lamp", pair("light", "l1").h)
			assert.equal(0, #renames, "no counter-write")
			assert.is_true(saw_log("hue echo"))
		end)

		it("N7: more than 3 automatic writes for one device in 10 minutes hold it; Attention says so", function()
			paired_light()
			for i = 1, 4 do
				regs.light.registry.l1.hue = "Hue " .. i
				n:on_hue_name("light", "l1")
				advance(12000)  -- past the echo window
				composer[6000] = "Composer " .. i
				n:on_composer_rename(6000)
				advance(12000)
			end
			assert.equal("loop", pair("light", "l1").held)
			assert.equal(3, #puts + #renames, "the fourth write is not made")
			assert.same({ "Names of Composer 4 keep changing; their sync is paused (Resolve Names)" }, n:attention())
		end)

		it("N8: a burst of Composer renames: one PUT a second, the latest per device, never within 1.5 s of a person",
			function()
			for i = 1, 3 do
				add("light", "l" .. i, "Lamp " .. i, "Lamp " .. i, { device = 1000 + i, proxy = 6000 + i })
			end
			n = new_names()
			n:pass("light")
			advance(5000)
			composer[6001] = "First"
			composer[6002] = "Second"
			composer[6003] = "Third"
			n:on_composer_rename(6001)
			n:on_composer_rename(6002)
			n:on_composer_rename(6003)
			composer[6001] = "First again"
			n:on_composer_rename(6001)
			user_busy = true
			advance(5000)
			assert.equal(0, #puts, "a person's command is queued: names wait")
			user_busy = false
			advance(10000)
			assert.same({ "First again", "Second", "Third" }, put_names())
			assert.is_true(puts[2].at - puts[1].at >= 1000)
			assert.is_true(puts[3].at - puts[2].at >= 1000)
		end)

		it("N9: past 10 Hue renames in a minute the rest are held", function()
			for i = 1, 12 do
				add("light", string.format("l%02d", i), "Lamp " .. i, "Lamp " .. i, { device = 1000 + i, proxy = 6000 + i })
			end
			n = new_names()
			n:pass("light")
			advance(5000)
			for i = 1, 12 do
				regs.light.registry[string.format("l%02d", i)].hue = "Renamed " .. i
				n:on_hue_name("light", string.format("l%02d", i))
			end
			advance(60000)
			assert.equal(10, #renames)
			assert.equal(2, #n:held_keys("bulk"))
			assert.truthy(renames[2].name and true)
		end)

		it("paces the renames at one per 2 s", function()
			for i = 1, 3 do
				add("light", "l" .. i, "Lamp " .. i, "Lamp " .. i, { device = 1000 + i, proxy = 6000 + i })
			end
			n = new_names()
			n:pass("light")
			for i = 1, 3 do
				regs.light.registry["l" .. i].hue = "Renamed " .. i
				n:on_hue_name("light", "l" .. i)
			end
			advance(1100)
			assert.equal(1, #renames)
			advance(1800)
			assert.equal(1, #renames)
			advance(200)
			assert.equal(2, #renames)
			advance(2000)
			assert.equal(3, #renames)
		end)

		it("N10: more than 5 differences found in one pass are held and offered", function()
			for i = 1, 6 do
				add("light", "l" .. i, "Lamp " .. i, "Lamp " .. i, { device = 1000 + i, proxy = 6000 + i })
			end
			n = new_names()
			n:pass("light")
			for i = 1, 6 do
				regs.light.registry["l" .. i].hue = "Restored " .. i
			end
			n:pass("light")
			advance(20000)
			assert.same({}, renames)
			assert.equal(6, #n:held_keys("bulk"))
			assert.same({ "6 names changed while the driver was not watching (Resolve Names)" }, n:attention())
			assert.is_true(saw_log("6 light names changed while the driver was not watching"))
			-- Five are fine.
			regs.light.registry.l1.hue = "x"
		end)

		it("N11: while the bridge is unavailable a rename waits in its pair, survives a restart, and goes after the next "
			.. "resync", function()
			paired_light()
			ready = false
			composer[6000] = "Reading Lamp"
			n:on_composer_rename(6000)
			advance(5000)
			assert.equal(0, #puts)
			assert.equal("Reading Lamp", store.hue_name_pairs.pairs["light:l1"].push)
			assert.same({}, n:attention(), "not before 10 minutes")
			advance(600000)
			assert.same({ "1 rename waits for the bridge: Reading Lamp" }, n:attention())
			-- A restart: the pair comes back from the store; the bridge answers again.
			n = new_names()
			ready = true
			n:pass("light")
			advance(3000)
			assert.same({ "Reading Lamp" }, put_names())
			assert.is_nil(pair("light", "l1").push)
			assert.same({}, n:attention())
		end)

		it("N11: a transfer that fails keeps the name waiting, a 404 too", function()
			paired_light()
			auto_answer = false
			composer[6000] = "Reading Lamp"
			n:on_composer_rename(6000)
			advance(1500)
			held_answers[1].done(false, "no response")
			assert.equal("Reading Lamp", pair("light", "l1").push)
			assert.is_nil(pair("light", "l1").held)
			assert.equal("Desk Lamp", pair("light", "l1").h)
		end)

		it("N4: Hue refuses a name: held with Hue's reason, Attention, and a cut row in Resolve Names", function()
			paired_light()
			auto_answer = false
			composer[6000] = "Kitchen Under-Cabinet Left Strip"
			n:on_composer_rename(6000)
			advance(1500)
			held_answers[1].done(false, "Invalid name", 400)
			assert.equal("refused", pair("light", "l1").held)
			assert.same({ "1 name Hue refused: Kitchen Under-Cabinet Left Strip (Hue: Invalid name) (Resolve Names)" },
				n:attention())
			local rows = n:resolve_rows()
			assert.same({ "names:composer_to_hue", "names:hue_to_composer", "c2h:light:l1", "h2c:light:l1", "cut:light:l1" },
				{ rows[1].value, rows[2].value, rows[3].value, rows[4].value, rows[5].value })
			assert.equal("Composer names to Hue (all 1)", rows[1].text)
		end)

		it("N25: a name over 32 bytes is never sent; the cut row sends 32 and the Composer name stays", function()
			paired_light()
			composer[6000] = "Kitchen Under-Cabinet Left Strip 2"
			n:on_composer_rename(6000)
			advance(5000)
			assert.equal(0, #puts)
			assert.same({ "1 name Hue refused: Kitchen Under-Cabinet Left Strip 2 (34 characters, Hue takes 32) "
				.. "(Resolve Names)" }, n:attention())
			local result
			n:resolve("cut:light:l1", function(ok, text) result = { ok, text } end)
			advance(2000)
			assert.same({ "Kitchen Under-Cabinet Left Strip" }, put_names())
			assert.same({ true, "Sent to Hue 1 name: Kitchen Under-Cabinet Left Strip" }, result)
			assert.is_nil(pair("light", "l1").held)
			assert.equal("Kitchen Under-Cabinet Left Strip 2", composer[6000])
			assert.same({}, n:attention())
		end)

		it("Q8: a Hue rename of a held device waits; a Composer rename of it resolves it, Control4 winning", function()
			add("light", "l1", "Hue color lamp 1", "Desk Lamp", { device = 1000, proxy = 6000 })
			n = new_names()
			n:pass("light")
			assert.equal("first", pair("light", "l1").held)
			regs.light.registry.l1.hue = "Hue color lamp 2"
			n:on_hue_name("light", "l1")
			advance(5000)
			assert.same({}, renames)
			assert.same({}, puts)
			composer[6000] = "Reading Lamp"
			n:on_composer_rename(6000)
			advance(3000)
			assert.same({ "Reading Lamp" }, put_names())
			assert.is_nil(pair("light", "l1").held)
		end)

		it("a held pair whose names were made to agree leaves Resolve Names by itself", function()
			add("light", "l1", "Hue color lamp 1", "Desk Lamp", { device = 1000, proxy = 6000 })
			n = new_names()
			n:pass("light")
			assert.equal("first", pair("light", "l1").held)
			regs.light.registry.l1.hue = "Desk Lamp"  -- renamed in the Hue app to match
			n:on_hue_name("light", "l1")
			advance(3000)
			assert.is_nil(pair("light", "l1").held)
			assert.same({}, renames)
			assert.same({}, puts)
			assert.same({}, n:attention())
		end)

		it("N13, N14: a gone or unbound device is not synced; once linked again the pass decides", function()
			paired_light()
			regs.light.registry.l1.state = "unbound"
			composer[6000] = "Reading Lamp"
			n:on_composer_rename(6000)
			advance(5000)
			assert.equal(0, #puts)
			regs.light.registry.l1.state = "linked"
			n:pass("light")
			advance(3000)
			assert.same({ "Reading Lamp" }, put_names())
		end)

		it("N15: two devices on one Hue name source never sync; Attention and the rows say so", function()
			add("light", "l1", "Porch", "Porch", { device = 1000, proxy = 6000, source = "device:d1" })
			add("motion", "d1", "Porch", "Porch Motion", { device = 1100, proxy = 6100, source = "device:d1" })
			n = new_names()
			n:pass("light")
			n:pass("motion")
			assert.equal("shared", pair("light", "l1").held)
			assert.equal("shared", pair("motion", "d1").held)
			composer[6000] = "Front Porch"
			n:on_composer_rename(6000)
			advance(5000)
			assert.same({}, puts)
			assert.same({ "2 devices share one Hue name and do not sync: Front Porch, Porch Motion (Forget Device on one)" },
				n:attention())
			assert.same({ "" }, { n:resolve_rows()[1].value })
		end)

		it("N24: control characters in a Hue name reach Composer cleaned, the pair keeps Hue's text, no loop", function()
			paired_light()
			regs.light.registry.l1.hue = " Desk\tLamp 2 "
			n:on_hue_name("light", "l1")
			advance(3000)
			assert.same({ "DeskLamp 2" }, rename_names())
			assert.equal(" Desk\tLamp 2 ", pair("light", "l1").h)
			n:pass("light")
			advance(3000)
			assert.equal(0, #puts)
			assert.equal(1, #renames)
		end)

		it("N30: a room prefix typed in Composer stays on the Composer side both ways", function()
			add("light", "l1", "Pendant", "Kitchen Pendant", { device = 1000, proxy = 6000 })
			n = new_names()
			n:pass("light")
			assert.equal("Kitchen ", pair("light", "l1").pre)
			regs.light.registry.l1.hue = "Island"
			n:on_hue_name("light", "l1")
			advance(3000)
			assert.same({ "Kitchen Island" }, rename_names())
			advance(20000)
			composer[6000] = "Kitchen Lamp"
			n:on_composer_rename(6000)
			advance(3000)
			assert.same({ "Lamp" }, put_names())
		end)

		it("N23, N32: a zone scene and a time-based scene keep their Composer forms", function()
			add("scene", "s1", "Relax", "Upstairs Relax", { device = 1200, proxy = 6200, form = { prefix = "Upstairs " } })
			add("scene", "s2", "Golden hours 4", "Golden hours", { device = 1201, proxy = 6201, form = { smart = true } })
			n = new_names()
			n:pass("scene")
			assert.is_nil(pair("scene", "s1").held)
			assert.is_nil(pair("scene", "s2").held)
			composer[6200] = "Upstairs Chill"
			composer[6201] = "Evening"
			n:on_composer_rename(6200)
			n:on_composer_rename(6201)
			advance(5000)
			assert.same({ "Chill", "Evening" }, put_names())
			-- The app numbers the time-based scene again: Composer keeps its base name.
			advance(20000)
			regs.scene.registry.s2.hue = "Evening 2"
			n:on_hue_name("scene", "s2")
			advance(5000)
			assert.same({}, renames)
			assert.equal("Evening 2", pair("scene", "s2").h)
			-- The zone renamed in Hue: the zone scene's Composer name keeps its prefix.
			regs.scene.registry.s1.form = { prefix = "Loft " }
			n:pass("scene")
			advance(5000)
			assert.same({}, renames)
			assert.equal(2, #puts)
		end)

		it("N34: an id that is no light, scene or motion device of this bridge is ignored", function()
			paired_light()
			assert.is_false(n:on_composer_rename(4242))
			assert.is_false(n:on_composer_rename(nil))
			advance(5000)
			assert.same({}, puts)
		end)

		it("§3.3: before a kind's first pass of the run, and while it resyncs, events wait for the pass", function()
			add("light", "l1", "Desk Lamp", "Desk Lamp", { device = 1000, proxy = 6000 })
			n = new_names()
			n:pass("light")
			n = new_names()  -- a restart: the pairs load, nothing is ready
			regs.light.registry.l1.hue = "Office Lamp"
			assert.is_false(n:on_hue_name("light", "l1"))
			composer[6000] = "Reading Lamp"
			assert.is_false(n:on_composer_rename(6000))
			advance(5000)
			assert.same({}, puts)
			regs.light.resyncing = true
			n.ready.light = true
			assert.is_false(n:on_hue_name("light", "l1"))
			regs.light.resyncing = false
			n:pass("light")
			advance(3000)
			assert.same({ "Reading Lamp" }, put_names(), "the Composer rename counted as one (Control4 wins)")
		end)

		it("fills a missing proxy id once through proxy_of; without one the device is not synced", function()
			add("light", "l1", "Desk Lamp", "Desk Lamp", { device = 1000, proxy = false })
			n = new_names({ proxy_of = function(id) return id == 1000 and 6000 or nil end })
			composer[6000] = "Desk Lamp"
			n:pass("light")
			assert.equal(6000, regs.light.registry.l1.proxy_id)
			assert.equal("Desk Lamp", pair("light", "l1").c)
			add("light", "l2", "Lamp", "Lamp", { device = 1001, proxy = false })
			n:pass("light")
			assert.is_nil(pair("light", "l2"))
		end)
	end)

	describe("lifecycle", function()
		it("N16: a re-link moves the pair and gives the Hue thing the Composer name, said in the re-link's text",
			function()
			paired_light()
			-- Re-linked to a new rid whose Hue name is the bulb's default.
			local entry = regs.light.registry.l1
			regs.light.registry.l1 = nil
			regs.light.registry.l9 = entry
			entry.hue = "Hue color lamp 1"
			assert.equal("; Hue gets the Composer name Desk Lamp", n:relinked("light", "l1", "l9"))
			assert.is_nil(pair("light", "l1"))
			advance(3000)
			assert.same({ "Desk Lamp" }, put_names())
			assert.equal("Desk Lamp", pair("light", "l9").h)
			assert.same({ "Name sent to Hue after the re-link: Desk Lamp (was Hue color lamp 1 in Hue)" }, actions)
			-- The same name already: nothing to send.
			regs.light.registry.l9 = nil
			regs.light.registry.l8 = entry
			assert.is_nil(n:relinked("light", "l9", "l8"))
		end)

		it("N17: a device AddDevice created is paired at its first look, whatever Composer shows", function()
			add("light", "l1", "Desk Lamp", "Desk Lamp (2)", { device = 1000, proxy = 6000 })
			n = new_names()
			n:added("light", "l1", "Desk Lamp")
			n:pass("light")
			assert.is_nil(pair("light", "l1").held)
			assert.equal(" (2)", pair("light", "l1").post)
			add("light", "l2", "Hue lamp", "Something else", { device = 1001, proxy = 6001 })
			n:added("light", "l2", "Hue lamp")
			n:pass("light")
			assert.is_nil(pair("light", "l2").held)
		end)

		it("forgets a device's pair and its queued writes", function()
			paired_light()
			auto_answer = false
			composer[6000] = "Reading Lamp"
			n:on_composer_rename(6000)
			n:forgotten("light", "l1")
			advance(5000)
			assert.same({}, puts)
			assert.is_nil(pair("light", "l1"))
			assert.is_nil(store.hue_name_pairs.pairs["light:l1"])
		end)
	end)

	describe("the first run of 1.2 (N19, N20, D11)", function()
		it("pairs the names that agree, holds the rest (accepted ones too) and says so once every kind has passed",
			function()
			add("light", "l1", "Desk Lamp", "Desk Lamp", { device = 1000, proxy = 6000 })
			add("light", "l2", "Hue color lamp 1", "Reading Lamp", { device = 1001, proxy = 6001 })
			add("light", "l3", "Porch", "Front Porch", { device = 1002, proxy = 6002, dismissed = "Porch" })
			add("scene", "s1", "Relax", "Relax", { device = 1200, proxy = 6200 })
			n = new_names()
			assert.is_true(n:migrate(450))
			n:pass("light")
			n:pass("scene")
			assert.same({}, actions)
			n:pass("motion")
			assert.same({ "Names: 2 names differ between Composer and Hue (Resolve Names: \"Composer names to Hue\" "
				.. "sends the Composer names); other renames now sync both ways" }, actions)
			assert.equal(450, store.hue_name_pairs.seeded_build)
			assert.is_nil(pair("light", "l1").held)
			assert.equal("first", pair("light", "l2").held)
			assert.equal("first", pair("light", "l3").held, "an accepted difference is held too")
			assert.same({ "2 names differ between Composer and Hue (Resolve Names)" }, n:attention())
			advance(20000)
			assert.same({}, puts)
			assert.same({}, renames)
			-- Not again at the next start.
			n = new_names()
			assert.is_false(n:migrate(451))
		end)

		it("Resolve Names: Composer names to Hue first, Hue names to Composer, then two rows per device", function()
			add("light", "l2", "Hue color lamp 1", "Reading Lamp", { device = 1001, proxy = 6001 })
			add("light", "l3", "Porch light", "Entrance", { device = 1002, proxy = 6002 })
			n = new_names()
			n:migrate(450)
			n:pass("light")
			local texts = {}
			for i, row in ipairs(n:resolve_rows()) do texts[i] = row.text .. " = " .. row.value end
			assert.same({
				"Composer names to Hue (all 2) = names:composer_to_hue",
				"Hue names to Composer (all 2) = names:hue_to_composer",
				"Entrance: send it to Hue (Hue has Porch light) = c2h:light:l3",
				"Entrance: rename it to Porch light from Hue = h2c:light:l3",
				"Reading Lamp: send it to Hue (Hue has Hue color lamp 1) = c2h:light:l2",
				"Reading Lamp: rename it to Hue color lamp 1 from Hue = h2c:light:l2",
			}, texts)
			local result
			n:resolve("names:composer_to_hue", function(ok, text) result = { ok, text } end)
			advance(5000)
			assert.same({ "Entrance", "Reading Lamp" }, put_names())
			assert.same({ true, "Sent to Hue 2 names: Entrance, Reading Lamp" }, result)
			assert.same({ { text = "(no names to resolve: Composer and Hue agree)", value = "" } }, n:resolve_rows())
			-- From then on every rename syncs by itself.
			advance(20000)
			regs.light.registry.l2.hue = "Office Lamp"
			n:on_hue_name("light", "l2")
			advance(3000)
			assert.same({ "Office Lamp" }, rename_names())
		end)

		it("Resolve Names: Hue names to Composer for one device, at the paced rate", function()
			add("light", "l2", "Hue color lamp 1", "Reading Lamp", { device = 1001, proxy = 6001 })
			n = new_names()
			n:pass("light")
			local result
			n:resolve("h2c:light:l2", function(ok, text) result = { ok, text } end)
			advance(3000)
			assert.same({ { id = 6001, name = "Hue color lamp 1" } }, renames)
			assert.same({ true, "Renamed from Hue 1 name: Hue color lamp 1 (device 1001)" }, result)
			assert.is_nil(pair("light", "l2").held)
			n:resolve("nonsense", function(ok, text) result = { ok, text } end)
			assert.same({ false, "Not resolved: pick a row of Names first" }, result)
		end)

		it("Resolve Names: names:hue_to_composer takes the Hue name of every held pair, of every kind", function()
			add("light", "l2", "Hue color lamp 1", "Reading Lamp", { device = 1001, proxy = 6001 })
			add("scene", "s1", "Relax", "Chill Out", { device = 1200, proxy = 6200 })
			n = new_names()
			n:pass("light")
			n:pass("scene")
			local result
			n:resolve("names:hue_to_composer", function(ok, text) result = { ok, text } end)
			advance(6000)
			assert.same({ "Relax", "Hue color lamp 1" }, rename_names(), "in the rows' order (by Composer name)")
			assert.same({}, puts)
			assert.is_true(result[1])
			assert.is_nil(pair("light", "l2").held)
			assert.is_nil(pair("scene", "s1").held)
		end)

		it("lists the zone lights' differences and settles them through the module's own pair", function()
			local zl = { name_differences = function() return { {}, {} } end,
				adopt_hue_names = function() return "Renamed 2 zone light devices" end,
				accept_names = function() return "Accepted 2 zone light name differences" end }
			regs.zone_light = zl
			n = new_names()
			local rows = n:resolve_rows()
			assert.same({ "Zone lights: rename to the Hue names (all 2)", "Zone lights: keep the Composer names (all 2)" },
				{ rows[1].text, rows[2].text })
			local result
			n:resolve("zl:adopt", function(ok, text) result = { ok, text } end)
			assert.same({ true, "Renamed 2 zone light devices" }, result)
			n:resolve("zl:keep", function(ok, text) result = { ok, text } end)
			assert.same({ true, "Accepted 2 zone light name differences" }, result)
		end)

		it("the hidden alias of Adopt Hue Names takes the Hue names of one kind's held pairs", function()
			add("light", "l2", "Hue color lamp 1", "Reading Lamp", { device = 1001, proxy = 6001 })
			add("scene", "s1", "Relax", "Chill Out", { device = 1200, proxy = 6200 })
			n = new_names()
			n:pass("light")
			n:pass("scene")
			assert.equal("Renaming 1 light device to the Hue names (one every 2 s): Reading Lamp → Hue color lamp 1",
				n:adopt_all("light"))
			advance(3000)
			assert.same({ "Hue color lamp 1" }, rename_names())
			assert.equal("first", pair("scene", "s1").held)
			assert.equal("No motion names wait for Resolve Names; the others sync by themselves", n:adopt_all("motion"))
		end)
	end)

	it("with the real lights module: a Hue device rename reaches Composer, a Composer rename both Hue names", function()
		local json = require("dkjson")
		local fake = require("helpers.fake_c4")
		local F = require("fixtures.hue_resources")
		local c4 = fake.install_c4()
		fake.add_room(8, "Garage")
		for _, m in ipairs({ "bridge.http", "bridge.hue_model", "bridge.registry", "bridge.groups", "bridge.lights" }) do
			package.loaded[m] = nil
		end
		local http = require("bridge.http")
		local L = require("bridge.lights").new({ http = function(req, cb)
			req.ip, req.key = "192.0.2.10", "k"
			return http.request(req, cb)
		end })
		L:import_new(function() end)
		for _, body in ipairs({ F.light, F.device, F.zigbee_connectivity, F.room, F.zone, F.bridge_home }) do
			c4.last_transfer():respond(200, body)
		end
		assert.equal(3, L:count())
		local sent = {}
		n = new_names({
			registries = { light = L },
			put_name = names.put_via({ light = L }, function(req, cb)
				sent[#sent + 1] = req.method .. " " .. req.path .. " " .. req.body.metadata.name
				cb({ ok = true, code = 200 })
			end),
			display_name = function(id) return C4:GetDeviceDisplayName(id) end,
			rename_device = function(id, name) C4:RenameDevice(id, name) end,
			proxy_of = function(id)
				local bound = C4:GetBoundConsumerDevices(id, 5001)
				return type(bound) == "table" and next(bound) or nil
			end,
		})
		L:set_names(n)
		n:pass("light")
		local garage = L.registry[F.rids.garage]
		assert.truthy(garage.proxy_id, "filled from the proxy binding")
		assert.equal("Garage White", pair("light", F.rids.garage).c)

		L:on_container(json.decode(F.events.device_rename)[1])
		advance(3000)
		assert.same({ { id = garage.proxy_id, name = "Garage Spot" } }, c4.renamed)

		advance(20000)
		fake.project.devices[garage.proxy_id].name = "Garage Lamp"
		n:on_composer_rename(garage.proxy_id)
		advance(3000)
		assert.same({ "PUT /clip/v2/resource/device/" .. F.device_rids.garage .. " Garage Lamp",
			"PUT /clip/v2/resource/light/" .. F.rids.garage .. " Garage Lamp" }, sent)
		assert.equal(1, #c4.renamed, "no rename back")
	end)

	it("reads a store an older build or a bug left, and keeps nothing it cannot use", function()
		store.hue_name_pairs = "junk"
		n = new_names()
		assert.same({}, n.pairs)
		store.hue_name_pairs = { v = 1, seeded_build = 3, pairs = { ["light:l1"] = { h = "a", c = "a" }, bad = {},
			["scene:s1"] = "x" } }
		n = new_names()
		assert.same({ ["light:l1"] = { h = "a", c = "a" } }, n.pairs)
		assert.equal(3, n.seeded_build)
	end)
end)
