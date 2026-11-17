-- #514, stage 2 §3.2 (docs/hdmi-sync-stage2-design.md): syncbox/store.lua,
-- what pairing with a Hue Sync Box produced, in the device's persistent
-- storage: the token encrypted, the rest plain, all of it kept in memory.
-- Placeholders only: box 10.0.2.150, id 0A1B2C3D4E5F, token
-- TEST-TOKEN-NOT-REAL.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")

local TOKEN = "TEST-TOKEN-NOT-REAL"
local RECORD = { token = TOKEN, registration_id = "7", box_id = "0A1B2C3D4E5F", address = "10.0.2.150" }

describe("syncbox/store.lua (#514 stage 2)", function()
	local store, c4, s, lines

	-- The PersistSetValue calls as { name, value, encrypted }.
	local function sets()
		return c4.calls_to("PersistSetValue")
	end

	before_each(function()
		lines = {}
		log.set_debug(true)
		log.sink = function(line) lines[#lines + 1] = line end
		c4 = fake.install_c4()
		package.loaded["syncbox.store"] = nil
		store = require("syncbox.store")
		s = store.new()
	end)

	after_each(function()
		for _, line in ipairs(lines) do
			assert.is_nil(line:find(TOKEN, 1, true), "a log line holds the token: " .. line)
		end
		log.set_debug(false)
		log.sink = print
	end)

	it("loads nothing from an empty storage", function()
		assert.same({}, s:load())
		assert.is_false(s:paired())
	end)

	it("saves the token encrypted and the rest plain", function()
		assert.is_true(s:save(RECORD))
		local by_name = {}
		for _, args in ipairs(sets()) do by_name[args[1]] = args end
		assert.same({ "syncbox_token", TOKEN, true }, by_name.syncbox_token)
		assert.same({ "syncbox_registration_id", "7", false }, by_name.syncbox_registration_id)
		assert.same({ "syncbox_box_id", "0A1B2C3D4E5F", false }, by_name.syncbox_box_id)
		assert.same({ "syncbox_address", "10.0.2.150", false }, by_name.syncbox_address)
		assert.is_true(s:paired())
	end)

	it("reads the token back with the encrypted flag, and the rest plain", function()
		c4.persist.syncbox_token = TOKEN
		c4.persist.syncbox_registration_id = "7"
		c4.persist.syncbox_box_id = "0a1b2c3d4e5f"
		c4.persist.syncbox_address = "10.0.2.150"
		assert.same({ token = TOKEN, registration_id = "7", box_id = "0A1B2C3D4E5F", address = "10.0.2.150" }, s:load())
		local flags = {}
		for _, args in ipairs(c4.calls_to("PersistGetValue")) do flags[args[1]] = args[2] end
		assert.is_true(flags.syncbox_token)
		assert.is_false(flags.syncbox_box_id)
	end)

	it("keeps what it saved in memory, whatever the storage answers right after", function()
		local stored = {}
		s = store.new({
			persist_get = function() return nil end, -- the database thread has not written yet
			persist_set = function(name, value, encrypted) stored[name] = { value, encrypted } end,
			persist_delete = function(name) stored[name] = nil end,
		})
		s:save(RECORD)
		assert.same(RECORD, s:load())
		assert.same({ TOKEN, true }, stored.syncbox_token)
	end)

	it("reads the storage only at the first load of a run", function()
		c4.persist.syncbox_box_id = "0A1B2C3D4E5F"
		s:load()
		c4.persist.syncbox_box_id = "FFFFFFFFFFFF"
		assert.equal("0A1B2C3D4E5F", s:load().box_id)
	end)

	it("hands out copies: changing one changes nothing stored", function()
		s:save(RECORD)
		local t = s:load()
		t.token = nil
		assert.equal(TOKEN, s:load().token)
	end)

	it("saves only the fields given and keeps the others", function()
		s:save(RECORD)
		assert.is_true(s:save({ address = "198.51.100.150" }))
		assert.same({ token = TOKEN, registration_id = "7", box_id = "0A1B2C3D4E5F", address = "198.51.100.150" }, s:load())
		assert.equal("198.51.100.150", c4.persist.syncbox_address)
		assert.equal(TOKEN, c4.persist.syncbox_token)
	end)

	it("turns a whole-number registration id into its text and upper-cases the box id", function()
		s:save({ registration_id = 12, box_id = "0a1b2c3d4e5f" })
		assert.equal("12", s:load().registration_id)
		assert.equal("0A1B2C3D4E5F", s:load().box_id)
		assert.equal("12", c4.persist.syncbox_registration_id)
	end)

	it("refuses a record with any unusable value and writes nothing of it", function()
		for field, bad in pairs({
			token = "TEST TOKEN",
			registration_id = "7; DROP",
			box_id = "0A1B2C3D4E5",
			address = "10.0.2.150/x",
		}) do
			local record = {}
			for k, v in pairs(RECORD) do record[k] = v end
			record[field] = bad
			local ok, which = s:save(record)
			assert.is_false(ok)
			assert.equal(field, which)
		end
		assert.same({}, sets())
		assert.same({}, s:load())
		assert.is_false(s:save("not a record"))
	end)

	it("ignores a stored value that fails its check", function()
		c4.persist.syncbox_token = "TEST\nTOKEN"
		c4.persist.syncbox_box_id = "not-an-id"
		c4.persist.syncbox_registration_id = "-1"
		c4.persist.syncbox_address = "10.0.2.150"
		assert.same({ address = "10.0.2.150" }, s:load())
	end)

	it("clears all four, in the storage and in memory", function()
		s:save(RECORD)
		s:clear()
		local deleted = {}
		for _, args in ipairs(c4.calls_to("PersistDeleteValue")) do deleted[#deleted + 1] = args[1] end
		table.sort(deleted)
		assert.same({ "syncbox_address", "syncbox_box_id", "syncbox_registration_id", "syncbox_token" }, deleted)
		assert.same({}, s:load())
		assert.same({}, c4.persist)
	end)

	it("keeps what it saved for this run when the storage raises, and logs no token", function()
		s = store.new({
			persist_get = function() return nil end,
			persist_set = function() error("database busy " .. TOKEN) end,
			persist_delete = function() error("database busy") end,
		})
		assert.is_true(s:save(RECORD))
		assert.equal(TOKEN, s:load().token)
		s:clear()
		assert.same({}, s:load())
		assert.is_true(#lines > 0)
	end)

	it("summarises without the token", function()
		s:save(RECORD)
		local line = s:summary()
		assert.is_nil(line:find(TOKEN, 1, true))
		assert.truthy(line:find("token present", 1, true))
		assert.truthy(line:find("0A1B2C3D4E5F", 1, true))
	end)
	it("calls Director's Persist functions with the encrypted flag only when true (#547)", function()
		-- Director raises on an explicit nil flag [verified: house, build 682, 2026-11-17].
		local calls = {}
		local strict = function(kind)
			return function(_, ...)
				local n = select("#", ...)
				local flag_at = kind == "get" and 2 or 3
				if n >= flag_at and type((select(flag_at, ...))) ~= "boolean" then
					error("bad argument: encrypted must be a boolean")
				end
				calls[#calls + 1] = { kind, n }
				return nil
			end
		end
		local saved = { get = C4.PersistGetValue, set = C4.PersistSetValue }
		C4.PersistGetValue, C4.PersistSetValue = strict("get"), strict("set")
		local ok, err = pcall(function()
			local st = require("syncbox.store").new({ log = log })
			assert.same({}, st:load())
			assert.is_true(st:save({ token = "TEST-TOKEN-NOT-REAL", box_id = "0A1B2C3D4E5F", address = "10.0.2.150",
				registration_id = "7" }))
		end)
		C4.PersistGetValue, C4.PersistSetValue = saved.get, saved.set
		assert.is_true(ok, tostring(err))
		assert.is_true(#calls >= 8)
	end)
end)
