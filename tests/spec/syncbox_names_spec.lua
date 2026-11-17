-- syncbox/names.lua (2.0 beta stage 4, #568; docs/hdmi-sync-stage4-design.md
-- §1.7 and §5, design §8, owner's answer O14; edge cases B22 and C3): the
-- box's name two-way, by the rules and loop guards 1.2 decided for lights
-- (docs/simplify-actions-design.md D6, D11, §3.1;
-- docs/simplify-research-names-sync.md §5, the N cases named below). The box
-- is the Lua fake (tests/helpers/fake_syncbox.lua: PUT /device applies, SB110;
-- the Hue Sync app's rename is its rename event, SB112), reached through the
-- real client; the device is one proxy of the fake project. Placeholders
-- only: box 10.0.2.150, id 0A1B2C3D4E5F, token TEST-TOKEN-NOT-REAL.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_syncbox")

local PROXY = 1301   -- the box device's AV switch proxy in Composer

describe("syncbox/names.lua (#568)", function()
	local names, state, c4, h, c, n, said, soons, answers, lines

	local function composer_name(name)
		fake.project.devices[PROXY] = fake.project.devices[PROXY] or { room_id = 7 }
		fake.project.devices[PROXY].name = name
	end

	local function new_names(extra)
		local deps = {
			client = c,
			poller = { soon = function(_, reason) soons[#soons + 1] = reason end },
			display_name = function() return c4:GetDeviceDisplayName(PROXY) end,
			rename_device = function(name) c4:RenameDevice(PROXY, name) end,
			timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end,
			now = function() return c4:GetTime() end,
			log = log,
			last_action = function(text) said[#said + 1] = text end,
		}
		for k, v in pairs(extra or {}) do deps[k] = v end
		return names.new(deps)
	end

	-- A read: the box's state now, as the poller hands it over.
	local function read()
		n:observe(assert(state.from_api(h:view())))
		c4.advance(10)
	end

	-- A rename in Composer: the proxy's name, then OnItemNameChanged.
	local function rename_in_composer(name)
		composer_name(name)
		n:on_composer_rename()
		c4.advance(names.SETTLE_MS)
	end

	local function rename_on_box(name)
		assert.is_true(h:event("rename", { name = name }))
	end

	local function rig(device_name, box_name, fixture)
		for _, m in ipairs({ "common.https", "syncbox.client", "syncbox.state", "syncbox.names" }) do
			package.loaded[m] = nil
		end
		state, names = require("syncbox.state"), require("syncbox.names")
		local clientmod = require("syncbox.client")
		local s = F.copy(F.state[fixture or "HSB2"])
		s.device.name = box_name or s.device.name
		h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN }, state = s })
		c = clientmod.new({ address = F.ADDRESS, token = F.TOKEN, log = log,
			timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end,
			now = function() return c4:GetTime() end })
		c:set_trusted(true)
		composer_name(device_name or s.device.name)
		n = new_names()
	end

	-- Paired and agreeing: "Living Room Sync Box" on both sides.
	local function paired()
		rig("Living Room Sync Box")
		read()
		assert.same({}, said)
		assert.is_nil(n:record().held)
	end

	local function puts()
		return h:requests_of("PUT", "/api/v1/device")
	end

	local function click(value)
		local before = #answers
		assert.is_true(n:choose(value, function(ok, text) answers[#answers + 1] = { ok = ok, text = text } end))
		c4.advance(10)
		return answers[before + 1]
	end

	before_each(function()
		said, soons, answers, lines = {}, {}, {}, {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
	end)

	after_each(function()
		if n then n:stop() end
		for _, line in ipairs(lines) do
			assert.is_nil(line:find(F.TOKEN, 1, true), "a log line holds the token: " .. line)
		end
		log.set_debug(false)
		log.sink = print
	end)

	describe("the first look (N19, N20, D11)", function()
		it("pairs names that agree silently, writing nothing", function()
			paired()
			assert.equal(0, #puts())
			assert.same({}, c4.renamed)
			assert.same({}, n:choices())
			assert.is_nil(n:attention())
			local sets = c4.calls_to("PersistSetValue")
			assert.equal(names.KEY, sets[1][1])
			assert.is_false(sets[1][3], "plain: no encrypted flag")
		end)

		it("holds names that differ, says so once and offers both, syncing neither by itself", function()
			rig("Hue Sync Box", "Den Sync Box")
			read()
			read()
			assert.same({ "The box is named Den Sync Box and this device Hue Sync Box: Sync Box Settings offers either "
				.. "name, and a rename in Composer sends its name to the box" }, said)
			assert.same({
				{ text = "Name the box after this device (Hue Sync Box)", value = names.OFFER_TO_BOX },
				{ text = "Name this device after the box (Den Sync Box)", value = names.OFFER_TO_DEVICE },
			}, n:choices())
			assert.equal("The box (Den Sync Box) and this device (Hue Sync Box) have different names: Sync Box Settings "
				.. "offers either", n:attention())
			-- A box rename while held changes only the box's own row (Q8).
			rename_on_box("Bedroom Box")
			read()
			assert.equal(0, #puts())
			assert.same({}, c4.renamed)
		end)

		it("Name the box after this device: one PUT, then paired", function()
			rig("Hue Sync Box", "Den Sync Box")
			read()
			local a = click(names.OFFER_TO_BOX)
			assert.same({ ok = true, text = "Named the box Hue Sync Box" }, a)
			assert.same({ name = "Hue Sync Box" }, puts()[1].json)
			assert.equal("Hue Sync Box", h:value("device.name"))
			assert.same({ "command" }, soons)
			read()
			assert.is_nil(n:record().held)
			assert.same({}, n:choices())
			assert.same({}, c4.renamed)
		end)

		it("Name this device after the box: one RenameDevice, then paired; its echo is absorbed (N6)", function()
			rig("Hue Sync Box", "Den Sync Box")
			read()
			local a = click(names.OFFER_TO_DEVICE)
			assert.same({ ok = true, text = "Named this device Den Sync Box" }, a)
			assert.same({ { id = PROXY, name = "Den Sync Box" } }, c4.renamed)
			n:on_composer_rename()   -- Composer reports our own rename
			c4.advance(names.SETTLE_MS)
			read()
			assert.equal(0, #puts())
			assert.equal(1, #c4.renamed)
		end)

		it("N17 + N1: a Composer rename before the first look sends its name", function()
			rig("Hue Sync Box", "Den Sync Box")
			rename_in_composer("Bedroom TV Box")
			assert.equal(0, #puts(), "nothing before a read")
			read()
			assert.same({ name = "Bedroom TV Box" }, puts()[1].json)
			assert.same({ "Name sent to the box: Bedroom TV Box (was Den Sync Box)" }, said)
		end)

		it("a replaced box (another id) is a first look again (B7)", function()
			paired()
			h.state.device.uniqueId = "0A1B2C3D4E60"
			rename_on_box("New Box")
			read()
			assert.equal("first", n:record().held)
			assert.same({}, c4.renamed)
		end)
	end)

	describe("the rule (research §5.1)", function()
		it("N1: a Composer rename reaches the box after the settle; the read that shows it is its echo", function()
			paired()
			rename_in_composer("Movie Room Box")
			assert.same({ name = "Movie Room Box" }, puts()[1].json)
			assert.same({ "Name sent to the box: Movie Room Box (was Living Room Sync Box)" }, said)
			assert.same({ h = "Movie Room Box", c = "Movie Room Box" }, { h = n:record().h, c = n:record().c })
			read()
			read()
			assert.equal(1, #puts())
			assert.same({}, c4.renamed)
		end)

		it("coalesces a burst of Composer renames into one PUT of the latest", function()
			paired()
			composer_name("A")
			n:on_composer_rename()
			c4.advance(300)
			composer_name("AB")
			n:on_composer_rename()
			c4.advance(300)
			composer_name("ABC Box")
			n:on_composer_rename()
			c4.advance(names.SETTLE_MS)
			assert.equal(1, #puts())
			assert.same({ name = "ABC Box" }, puts()[1].json)
		end)

		it("N2, B22: a rename in the Hue Sync app renames the device once; nothing goes back", function()
			paired()
			rename_on_box("TV Box")
			read()
			assert.same({ { id = PROXY, name = "TV Box" } }, c4.renamed)
			assert.same({ "Name taken from the box: TV Box (was Living Room Sync Box)" }, said)
			n:on_composer_rename()
			c4.advance(names.SETTLE_MS)
			read()
			assert.equal(0, #puts())
			assert.equal(1, #c4.renamed)
		end)

		it("N3: both renamed while nobody watched: Control4 wins and says which box name it replaced", function()
			paired()
			n:stop()
			rename_on_box("Hue App Name")
			composer_name("Composer Name")
			n = new_names()   -- a Director restart
			read()
			assert.same({ name = "Composer Name" }, puts()[1].json)
			assert.same({ "Both renamed: kept the Composer name Composer Name and sent it to the box (the box had Hue "
				.. "App Name)" }, said)
			assert.same({}, c4.renamed)
		end)

		it("N3: both renamed to the same name: only the pair moves", function()
			paired()
			rename_on_box("Same Box")
			composer_name("Same Box")
			read()
			assert.equal(0, #puts())
			assert.same({}, c4.renamed)
			assert.equal("Same Box", n:record().c)
		end)

		it("N7: the box keeps other text than we sent: taken as the echo within 10 s, never answered", function()
			paired()
			rename_in_composer("Movie Room Box")
			h.state.device.name = "Movie Room"   -- the box shortened it
			read()
			assert.same({}, c4.renamed)
			assert.equal("Movie Room", n:record().h)
			assert.equal("Movie Room Box", n:record().c)
			-- Later, a real rename on the box is one again.
			c4.advance(names.ECHO_MS)
			rename_on_box("Film Box")
			read()
			assert.same({ { id = PROXY, name = "Film Box" } }, c4.renamed)
		end)

		it("N7: Composer keeps other text than we renamed it to: taken as the echo", function()
			paired()
			rename_on_box("TV Box")
			read()
			composer_name("TV Box (Den)")   -- as if Composer had changed it
			n:on_composer_rename()
			c4.advance(names.SETTLE_MS)
			assert.equal(0, #puts())
			assert.equal("TV Box (Den)", n:record().c)
		end)

		it("N7: more than 3 automatic writes in 10 minutes hold the pair; Attention and the offer say so", function()
			paired()
			for i = 1, 3 do
				rename_on_box("Box " .. i)
				read()
				c4.advance(names.RENAME_GAP_MS)
			end
			assert.equal(3, #c4.renamed)
			rename_on_box("Box 4")
			read()
			assert.equal(3, #c4.renamed)
			assert.equal("loop", n:record().held)
			assert.equal("The names of the box (Box 4) and of this device (Box 3) keep changing; their sync is paused "
				.. "(Sync Box Settings offers either name)", said[#said])
			assert.equal("The names of the box and of this device keep changing; their sync is paused (Sync Box "
				.. "Settings)", n:attention())
			-- A click is never counted: it settles the pair.
			assert.is_true(click(names.OFFER_TO_DEVICE).ok)
			assert.equal(4, #c4.renamed)
			assert.is_nil(n:record().held)
		end)

		it("paces RenameDevice at one per 2 s", function()
			paired()
			rename_on_box("One")
			read()
			rename_on_box("Two")
			read()
			assert.equal(1, #c4.renamed)
			c4.advance(names.RENAME_GAP_MS)
			assert.same({ id = PROXY, name = "Two" }, c4.renamed[2])
		end)

		it("Q8: a Composer rename resolves a held pair, Control4 winning", function()
			rig("Hue Sync Box", "Den Sync Box")
			read()
			rename_in_composer("Den TV Box")
			assert.same({ name = "Den TV Box" }, puts()[1].json)
			assert.is_nil(n:record().held)
		end)

		it("names made to agree end a hold by themselves", function()
			rig("Hue Sync Box", "Den Sync Box")
			read()
			rename_on_box("Hue Sync Box")
			read()
			assert.is_nil(n:record().held)
			assert.equal(0, #puts())
		end)

		it("syncs nothing for a box without a name or a device whose name cannot be read", function()
			paired()
			h.state.device.name = ""
			read()
			assert.same({}, c4.renamed)
			composer_name(nil)
			n:on_composer_rename()
			c4.advance(names.SETTLE_MS)
			rename_on_box("Named Again")
			read()
			assert.same({}, c4.renamed)
			assert.equal(0, #puts())
		end)
	end)

	describe("names the box cannot hold (N4, N25, Q3)", function()
		it("never sends a name over the limit, never cuts it by itself, and offers the cut", function()
			paired()
			local long = "Living Room Home Cinema Sync Box!"   -- 33 characters
			rename_in_composer(long)
			assert.equal(0, #puts())
			assert.equal("refused", n:record().held)
			assert.equal("Name not sent to the box: " .. long .. " (33 characters, the box takes 32); Sync Box "
				.. "Settings offers the names", said[#said])
			assert.same({
				{ text = "Name the box after this device, cut to 32 bytes (Living Room Home Cinema Sync Box)",
					value = names.OFFER_CUT },
				{ text = "Name this device after the box (Living Room Sync Box)", value = names.OFFER_TO_DEVICE },
			}, n:choices())
			local a = click(names.OFFER_CUT)
			assert.same({ ok = true, text = "Named the box Living Room Home Cinema Sync Box" }, a)
			assert.same({ name = "Living Room Home Cinema Sync Box" }, puts()[1].json)
			-- The Composer name stays; no loop follows.
			read()
			read()
			assert.equal(1, #puts())
			assert.same({}, c4.renamed)
			assert.equal(long, n:record().c)
		end)

		it("counts bytes: accented letters count twice", function()
			paired()
			rename_in_composer(string.rep("\195\169", 17))   -- 17 characters, 34 bytes
			assert.equal(0, #puts())
			assert.truthy(said[#said]:find("34 bytes, the box takes 32 (accented letters count twice)", 1, true))
			assert.equal(string.rep("\195\169", 16), names.cut(string.rep("\195\169", 17), 32))
		end)

		it("a box that reported a longer name takes at least that many bytes", function()
			rig("A Forty Byte Name For The Den Sync Box!!", "A Forty Byte Name For The Den Sync Box!!")
			read()
			rename_in_composer("A Forty Byte Name For The Den Sync Box!")
			assert.same({ name = "A Forty Byte Name For The Den Sync Box!" }, puts()[1].json)
		end)

		it("the box's own refusal (code 15, SB110) holds the pair with the box's words", function()
			paired()
			h:fault("5xx", { status = 400, body = { code = 15, message = "Invalid Value" }, method = "PUT",
				path = "/device", count = 1 })
			rename_in_composer("Odd Name")
			assert.equal("refused", n:record().held)
			assert.equal("Name not sent to the box: Odd Name (the box refused it: Invalid Value); Sync Box Settings "
				.. "offers the names", said[#said])
			assert.equal("The box did not take the name Odd Name (the box refused it: Invalid Value): Sync Box "
				.. "Settings offers the names", n:attention())
		end)
	end)

	describe("the lifecycle", function()
		it("N11: a rename the box did not answer waits in the difference and goes after the next read", function()
			paired()
			h:silence(true)
			rename_in_composer("Movie Room Box")
			c4.advance(20000)
			assert.equal("Living Room Sync Box", h:value("device.name"))
			assert.equal("Living Room Sync Box", n:record().c, "the pair did not move")
			h:silence(false)
			read()
			assert.equal("Movie Room Box", h:value("device.name"))
			assert.equal("Movie Room Box", n:record().h)
		end)

		it("reads the Composer name on a read only when the box's side changed; check() finds a missed event", function()
			paired()
			local before = #c4.calls_to("GetDeviceDisplayName")
			for _ = 1, 5 do read() end
			assert.equal(before, #c4.calls_to("GetDeviceDisplayName"))
			composer_name("Renamed Without An Event")
			read()
			assert.equal(0, #puts())
			n:check()
			c4.advance(10)
			assert.same({ name = "Renamed Without An Event" }, puts()[1].json)
		end)

		it("survives a restart: the pair is read once and the rule picks up where it was", function()
			paired()
			n:stop()
			composer_name("Renamed While Down")
			n = new_names()
			read()
			assert.same({ name = "Renamed While Down" }, puts()[1].json)
		end)

		it("a RenameDevice that raises holds the pair and leaves the box alone", function()
			paired()
			n = new_names({ rename_device = function() error("no project") end })
			read()
			rename_on_box("TV Box")
			read()
			assert.equal("refused", n:record().held)
			assert.truthy(said[#said]:find("^This device was not renamed TV Box %(.*no project"))
			assert.truthy(n:attention():find("^This device was not renamed TV Box"))
			assert.equal(0, #puts())
		end)

		it("answers a click while a name is on its way, and stop() drops a late answer", function()
			rig("Hue Sync Box", "Den Sync Box")
			read()
			h:defer(true)
			n:choose(names.OFFER_TO_BOX, function() error("stopped: never called") end)
			local a = click(names.OFFER_TO_DEVICE)
			assert.same({ ok = false, text = "Not changed: the last name is still on its way to the box" }, a)
			n:stop()
			h:answer()
			assert.equal("first", n:record().held)
		end)

		it("a click when the names agree does nothing; another value is not ours", function()
			paired()
			assert.same({ ok = false, text = "Nothing to do: the box and this device keep one name" },
				click(names.OFFER_TO_BOX))
			assert.is_false(n:choose("inputs:control4", function() error("not ours") end))
		end)

		it("drops a stored pair it cannot use and looks afresh", function()
			rig("Hue Sync Box", "Den Sync Box")
			c4.persist[names.KEY] = { v = 1, box_id = "nope", h = 1 }
			n = new_names()
			read()
			assert.equal("first", n:record().held)
			assert.truthy(table.concat(lines, "\n"):find("not usable", 1, true))
		end)
	end)
end)
