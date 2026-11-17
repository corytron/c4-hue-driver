-- syncbox/areas.lua (2.0 beta stage 4, #568; docs/hdmi-sync-stage4-design.md
-- §1.5 and §5, design §6.1 and §8, contracts C1.4 and C1.6, owner's answer
-- O3; edge cases E1 to E4, E7, B20, C19 and §6): the box's entertainment
-- area, picked from the areas the box lists, stored by id with its name, a
-- gone area shown as such, its same-name successor offered once and never
-- applied by itself, and one pick re-pointing the programming that named it.
-- The writes go through the real queue and client to the Lua fake box
-- (tests/helpers/fake_syncbox.lua; hueTarget is SB48, SB98). Placeholders
-- only: box 10.0.2.150, id 0A1B2C3D4E5F, token TEST-TOKEN-NOT-REAL.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_syncbox")

local TV, OFFICE = F.AREA.tv, F.AREA.office
local REMADE = "6a7b8c9d-0000-4000-8000-0000000ea003"
local OTHER = "6a7b8c9d-0000-4000-8000-0000000eb003"

describe("syncbox/areas.lua (#568)", function()
	local areas, c4, h, q, p, a, said, answers, lines

	local function rig(fixture, extra)
		for _, name in ipairs({ "common.https", "syncbox.client", "syncbox.poller", "syncbox.state", "syncbox.queue",
			"syncbox.areas" }) do
			package.loaded[name] = nil
		end
		areas = require("syncbox.areas")
		local clientmod, pollermod, queuemod = require("syncbox.client"), require("syncbox.poller"),
			require("syncbox.queue")
		h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN }, state = F.copy(F.state[fixture or "HSB1"]) })
		for k, v in pairs(extra or {}) do h.state.hue.groups[k] = v end
		local timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end
		local now = function() return c4:GetTime() end
		local c = clientmod.new({ address = F.ADDRESS, token = F.TOKEN, log = log, timer = timer, now = now })
		c:set_trusted(true)
		p = pollermod.new({ client = c, timer = timer, now = now, log = log,
			on_state = function(m)
				q:observe(m)
				local text = a:observe(m)
				if text then said[#said + 1] = text end
			end })
		q = queuemod.new({ client = c, poller = p, log = log, timer = timer, now = now })
		a = areas.new({ queue = q, log = log })
		p:start()
	end

	-- A read now (as a bridge hint asks for one), and the time for it.
	local function read()
		p:soon("hint")
		c4.advance(2100)
	end

	local function answer(ok, text)
		answers[#answers + 1] = { ok = ok, text = text }
	end

	local function execution_puts()
		return h:requests_of("PUT", "/api/v1/execution")
	end

	local function area_sets()
		local out = {}
		for _, args in ipairs(c4.calls_to("PersistSetValue")) do
			if args[1] == areas.KEY then out[#out + 1] = args end
		end
		return out
	end

	before_each(function()
		said, answers, lines = {}, {}, {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
	end)

	after_each(function()
		if p then p:stop() end
		for _, line in ipairs(lines) do
			assert.is_nil(line:find(F.TOKEN, 1, true), "a log line holds the token: " .. line)
		end
		log.set_debug(false)
		log.sink = print
	end)

	describe("the list (contracts C1.4, E1, E7)", function()
		it("lists the box's areas by name, the box's own as the value", function()
			rig()
			local items, value = a:items()
			assert.same({ "Living Room TV", "Office" }, items)
			assert.equal("Living Room TV", value)
			assert.same({ how = "ok", id = TV, name = "Living Room TV", text = "Living Room TV" }, a:status())
			assert.same({ { text = "Living Room TV", value = "area:" .. TV }, { text = "Office", value = "area:" .. OFFICE } },
				a:list())
		end)

		it("lists first the areas whose lamps sit in the box's room, never choosing one", function()
			rig()
			local items, value = a:items({ [OFFICE] = true })
			assert.same({ "Office", "Living Room TV" }, items)
			assert.equal("Living Room TV", value)
			assert.equal(0, #execution_puts())
		end)

		it("keeps the labels apart: commas, a shared name, an unnamed area", function()
			rig("HSB1", {
				[REMADE] = { name = "Office", numLights = 2, active = false },
				[OTHER] = { name = "Den, back", numLights = 1, active = false },
				["groups/3"] = { name = "", numLights = 1, active = false },
			})
			read()
			local items = a:items()
			assert.same({ "Area #3", "Den\226\128\154 back", "Living Room TV", "Office (#a002)", "Office (#a003)" },
				items)
			-- A pick by a shared name's label sends that area.
			assert.is_true(a:choose("Office (#a003)", answer))
			c4.advance(3000)
			assert.equal(REMADE, h:value("execution.hueTarget"))
		end)

		it("before any read, says so; on a standalone box, offers nothing to pick (B20)", function()
			rig()
			a = areas.new({ queue = q, log = log })
			assert.same({ { text = "(the box has not been read yet; open the list again)", value = "" } }, a:list())
			local items, value = a:items()
			assert.same({}, items)
			assert.equal("", value)
			rig("HSB3_standalone")
			items, value = a:items()
			assert.same({ areas.LABEL_STANDALONE }, items)
			assert.equal(areas.LABEL_STANDALONE, value)
			local ok, why = a:choose(areas.LABEL_STANDALONE, answer)
			assert.is_false(ok)
			assert.equal("Not set: this box runs without a Hue Bridge (standalone mode)", why)
			assert.is_nil(a:resolve("area:" .. TV))
			assert.equal(0, #execution_puts())
		end)
	end)

	describe("a pick (contracts C1.4: selecting one writes hueTarget)", function()
		it("writes hueTarget through the queue and answers once a read shows it", function()
			rig()
			a:items()
			assert.is_true(a:choose("Office", answer))
			assert.equal(0, #answers)
			c4.advance(3000)
			assert.same({ hueTarget = OFFICE }, execution_puts()[1].json)
			assert.same({ { ok = true, text = "Entertainment area set to Office" } }, answers)
			assert.equal(OFFICE, a:record().id)
			assert.equal("Office", a:record().name)
		end)

		it("refuses a label that is no area of this box, sending nothing", function()
			rig()
			local ok, why = a:choose("Kitchen", answer)
			assert.is_false(ok)
			assert.equal("Not set: Kitchen is not an entertainment area of this box", why)
			c4.advance(3000)
			assert.equal(0, #execution_puts())
		end)

		it("a later pick supersedes an earlier one in the same burst: one PUT, one answer", function()
			rig()
			a:items()
			a:choose("Office", answer)
			a:choose("Living Room TV", answer)
			c4.advance(3000)
			assert.equal(1, #execution_puts())
			assert.same({ { ok = true, text = "Entertainment area set to Living Room TV" } }, answers)
		end)

		it("SB98: picking the area again while the box reads invalidgroup makes it connected", function()
			rig()
			h:event("bridge", { state = "invalidgroup" })
			read()
			assert.equal("invalid", a:status().how)
			assert.equal("The box cannot sync to Living Room TV (invalid area): pick it again in Entertainment Area",
				a:status().text)
			assert.is_true(a:choose("Living Room TV", answer))
			c4.advance(3000)
			assert.equal("connected", h:value("hue.connectionState"))
			read()
			assert.equal("ok", a:status().how)
		end)

		it("reports a write the box refused", function()
			rig()
			h:fault("5xx", { status = 400, body = { code = 15, message = "Invalid Value" }, method = "PUT",
				path = "/execution" })
			a:items()
			a:choose("Office", answer)
			c4.advance(3000)
			assert.equal(1, #answers)
			assert.is_false(answers[1].ok)
			assert.truthy(answers[1].text:find("^Not set: the box refused the entertainment area Office"))
		end)
	end)

	describe("the box is the truth (rule 7, E2, B23)", function()
		it("follows a rename in Hue by id", function()
			rig()
			h.state.hue.groups[TV].name = "Movie Lights"
			read()
			local items, value = a:items()
			assert.same({ "Movie Lights", "Office" }, items)
			assert.equal("Movie Lights", value)
			assert.equal("Movie Lights", a:record().name)
			assert.equal(0, #execution_puts())
		end)

		it("follows an area set in the Hue Sync app, writing nothing", function()
			rig()
			h:request("PUT", "/execution", { Authorization = "Bearer " .. F.TOKEN }, { hueTarget = OFFICE })
			read()
			assert.equal(OFFICE, a:record().id)
			assert.equal("Office", select(2, a:items()))
			assert.equal(1, #execution_puts(), "the app's own PUT only")
		end)

		it("stores the record only when it changed, never on every read", function()
			rig()
			local after_first = #area_sets()
			for _ = 1, 5 do read() end
			assert.equal(after_first, #area_sets())
			assert.is_false(area_sets()[1][3], "plain: no encrypted flag")
		end)
	end)

	describe("an area deleted in Hue (E3) and its successor (E4)", function()
		local function delete_tv()
			h.state.hue.groups[TV] = nil
			read()
		end

		local function remake_tv()
			h.state.hue.groups[REMADE] = { name = "Living Room TV", numLights = 5, active = false }
			read()
		end

		it("E3: shows the gone area by the name it had, says so once, and chooses no other", function()
			rig()
			delete_tv()
			assert.same({ "The box syncs to an entertainment area deleted in Hue (Living Room TV): pick another in "
				.. "Entertainment Area" }, said)
			local st = a:status()
			assert.equal("gone", st.how)
			assert.equal("Entertainment area deleted in Hue (Living Room TV): pick another in Entertainment Area", st.text)
			local items, value = a:items()
			assert.same({ "Office" }, items)
			assert.equal("Living Room TV (deleted in Hue)", value)
			read()
			read()
			assert.equal(1, #said)
			assert.equal(0, #execution_puts(), "never another area by itself, even the only one left")
			assert.equal(TV, h:value("execution.hueTarget"))
		end)

		it("E4: offers the same-name successor once, never applying it, and once only across a restart", function()
			rig()
			delete_tv()
			remake_tv()
			assert.equal(2, #said)
			assert.equal("Living Room TV is on the bridge again (made anew in Hue): pick it in Entertainment Area",
				said[2])
			assert.same({ id = REMADE, name = "Living Room TV", text = said[2] }, a:status().offer)
			read()
			assert.equal(2, #said)
			assert.equal(TV, h:value("execution.hueTarget"))
			assert.equal(0, #execution_puts())
			-- A restart: the record says it was offered.
			a = areas.new({ queue = q, log = log })
			read()
			assert.equal(2, #said)
			assert.equal("gone", a:status().how)
		end)

		it("E3 and E4 at once: said together", function()
			rig()
			h.state.hue.groups[TV] = nil
			h.state.hue.groups[REMADE] = { name = "Living Room TV", numLights = 5, active = false }
			read()
			assert.same({ "The box syncs to an entertainment area deleted in Hue (Living Room TV): pick another in "
				.. "Entertainment Area; Living Room TV is on the bridge again (made anew in Hue): pick it in "
				.. "Entertainment Area" }, said)
		end)

		it("offers nothing when two areas carry the gone one's name", function()
			rig()
			delete_tv()
			h.state.hue.groups[REMADE] = { name = "Living Room TV", numLights = 5, active = false }
			h.state.hue.groups[OTHER] = { name = "Living Room TV", numLights = 2, active = false }
			read()
			assert.equal(1, #said)
			assert.is_nil(a:status().offer)
		end)

		it("C19: programming that names the gone area is not set, and points at the successor", function()
			rig()
			delete_tv()
			local id, text = a:resolve("area:" .. TV)
			assert.is_nil(id)
			assert.equal("Not set: the entertainment area Living Room TV was deleted in Hue", text)
			local ok, why = a:set("area:" .. TV, answer)
			assert.is_false(ok)
			assert.equal(text, why)
			remake_tv()
			id, text = a:resolve("area:" .. TV)
			assert.is_nil(id)
			assert.equal("Not set: the entertainment area Living Room TV was deleted in Hue; Living Room TV is on the "
				.. "bridge again: pick it in Entertainment Area to re-point this programming", text)
			c4.advance(3000)
			assert.equal(0, #execution_puts())
		end)

		it("one pick of the successor sets the box and re-points the programming (§6 option A)", function()
			rig()
			delete_tv()
			remake_tv()
			a:items()
			assert.is_true(a:choose("Living Room TV", answer))
			c4.advance(3000)
			assert.same({ hueTarget = REMADE }, execution_puts()[1].json)
			assert.same({ { ok = true, text = "Entertainment area set to Living Room TV; programming that named the "
				.. "deleted Living Room TV uses it now" } }, answers)
			assert.same({ [TV] = REMADE }, a:record().repoint)
			assert.equal(REMADE, (a:resolve("area:" .. TV)))
			-- The programming line runs: the new area, by the old value.
			h:request("PUT", "/execution", { Authorization = "Bearer " .. F.TOKEN }, { hueTarget = OFFICE })
			read()
			assert.is_true(a:set("area:" .. TV, answer))
			c4.advance(3000)
			assert.equal(REMADE, h:value("execution.hueTarget"))
			assert.equal("Entertainment area set to Living Room TV", answers[2].text)
			-- Made again a second time: the chain follows the next pick.
			h.state.hue.groups[REMADE] = nil
			h.state.hue.groups[OTHER] = { name = "Living Room TV", numLights = 5, active = false }
			read()
			a:items()
			a:choose("Living Room TV", answer)
			c4.advance(3000)
			assert.equal(OTHER, (a:resolve("area:" .. TV)))
		end)

		it("a pick of an area with another name re-points nothing", function()
			rig()
			delete_tv()
			remake_tv()
			a:items()
			a:choose("Office", answer)
			c4.advance(3000)
			assert.same({}, a:record().repoint)
			assert.is_nil((a:resolve("area:" .. TV)))
		end)
	end)

	describe("the command (Set Entertainment Area, contracts C1.6)", function()
		it("sets the area a value names, bare ids too", function()
			rig()
			assert.is_true(a:set("area:" .. OFFICE, answer))
			c4.advance(3000)
			assert.equal(OFFICE, h:value("execution.hueTarget"))
			assert.is_true(a:set(TV, answer))
			c4.advance(3000)
			assert.equal(TV, h:value("execution.hueTarget"))
		end)

		it("refuses a value that is no area id, and an empty one", function()
			rig()
			for _, v in ipairs({ "", "area:", "area:../x", 42 }) do
				local ok, why = a:set(v, answer)
				assert.is_false(ok)
				assert.equal("Not set: no entertainment area was chosen in this programming line", why)
			end
		end)

		it("before the first read, lets the box judge the id (SB48 refuses an unknown one)", function()
			rig()
			a = areas.new({ queue = q, log = log })
			assert.equal(OFFICE, (a:resolve("area:" .. OFFICE)))
		end)
	end)

	it("drops a stored record it cannot use and keeps only valid entries", function()
		rig()
		c4.persist[areas.KEY] = "garbage"
		a = areas.new({ queue = q, log = log })
		read()
		assert.equal(TV, a:record().id)
		assert.truthy(lines[1] and table.concat(lines, "\n"):find("not usable", 1, true))
		c4.persist[areas.KEY] = { v = 1, id = "../etc", name = 5, known = { { id = TV, name = "Old TV" }, "x",
			{ id = "bad id" } }, repoint = { [OFFICE] = "bad id", [OTHER] = TV } }
		a = areas.new({ queue = q, log = log })
		local r = a:record()
		assert.is_nil(r.id)
		assert.same({ { id = TV, name = "Old TV" } }, r.known)
		assert.same({ [OTHER] = TV }, r.repoint)
	end)
end)
