local log = require("common.log")

describe("bridge.registry", function()
	local registry, reg, store, saved, clock, logged

	-- Plain persistence: a table keyed by name, plus the order of writes.
	local function persist_get(name)
		return store[name]
	end

	local function persist_set(name, value)
		store[name] = value
		saved[#saved + 1] = name
	end

	local function now()
		return clock
	end

	local function new_reg()
		return registry.new({ persist_get = persist_get, persist_set = persist_set, now = now, log = log })
	end

	local function saw_log(text)
		for _, line in ipairs(logged) do
			if line:find(text, 1, true) then return true end
		end
		return false
	end

	-- A v1 entry as lights.lua persisted it.
	local function v1(device_id, name)
		return {
			device_id = device_id, proxy_id = device_id + 1, name = name, model = "LCA001",
			caps = { has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 0.2 },
		}
	end

	local function add(rid, device_id, name, extra)
		local fields = { device_id = device_id, name = name }
		for k, v in pairs(extra or {}) do fields[k] = v end
		local entry, err = reg:add(rid, fields)
		assert.truthy(entry, err)
		return entry
	end

	before_each(function()
		logged = {}
		log.sink = function(line) table.insert(logged, line) end
		log.set_debug(true)
		package.loaded["bridge.registry"] = nil
		registry = require("bridge.registry")
		store = {}
		saved = {}
		clock = 1000
		reg = new_reg()
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("load()", function()
		it("starts empty when nothing is persisted", function()
			assert.same({ linked = 0, gone = 0, unbound = 0, tombstones = 0, rooms = 0 }, reg:load())
			assert.same({}, reg:entries())
			assert.same({}, reg:tombstones())
			assert.same({}, reg:room_mappings())
			assert.same({}, reg:rids())
		end)

		it("upgrades v1 entries in place: state linked, the new fields nil, the old ones kept", function()
			store.hue_lights = { ["rid-a"] = v1(2043, "Desk Lamp"), ["rid-b"] = v1(2050, "Porch") }
			local counts = reg:load()
			assert.same({ linked = 2, gone = 0, unbound = 0, tombstones = 0, rooms = 0 }, counts)
			local a = reg:get("rid-a")
			assert.equal("linked", a.state)
			assert.equal(2043, a.device_id)
			assert.equal(2044, a.proxy_id)
			assert.equal("Desk Lamp", a.name)
			assert.equal("LCA001", a.model)
			assert.same({ has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 0.2 }, a.caps)
			for _, field in ipairs({ "device_name", "device_rid", "mac_address", "service_id", "id_v1", "hue_room_rid",
				"gone_since", "unbound_since", "created_room_id", "created_at", "name_dismissed" }) do
				assert.is_nil(a[field], field .. " stays nil until the next resync")
			end
			assert.truthy(saw_log("upgraded v1 entry"))
		end)

		it("keeps v2 fields, unknown keys and the state, and coerces ids and timestamps", function()
			store.hue_lights = {
				["rid-a"] = {
					device_id = "2043", proxy_id = "2044", name = "Desk Lamp", state = "gone", gone_since = "1234",
					device_name = "Desk", mac_address = "00:17:88:01:aa:bb:cc:dd", id_v1 = "/lights/12",
					created_at = "900", created_room_id = "7", future_field = { x = 1 },
				},
			}
			local counts = reg:load()
			assert.equal(1, counts.gone)
			local a = reg:get("rid-a")
			assert.equal("gone", a.state)
			assert.equal(2043, a.device_id)
			assert.equal(2044, a.proxy_id)
			assert.equal(1234, a.gone_since)
			assert.equal(900, a.created_at)
			assert.equal(7, a.created_room_id)
			assert.equal("/lights/12", a.id_v1)
			assert.same({ x = 1 }, a.future_field)
		end)

		it("drops an entry without a device id and normalises a bad state and stray timestamps", function()
			store.hue_lights = {
				["no-device"] = { name = "Orphan" },
				[42] = { device_id = 1 },
				["bad-state"] = { device_id = 2060, name = "Odd", state = "tombstone", gone_since = 5, unbound_since = 6 },
			}
			local counts = reg:load()
			assert.same({ linked = 1, gone = 0, unbound = 0, tombstones = 0, rooms = 0 }, counts)
			assert.is_nil(reg:get("no-device"))
			assert.is_nil(reg:get(42))
			local odd = reg:get("bad-state")
			assert.equal("linked", odd.state)
			assert.is_nil(odd.gone_since, "a stamp belongs to its state only")
			assert.is_nil(odd.unbound_since)
			assert.truthy(saw_log("dropped a malformed hue_lights entry for no-device"))
			assert.truthy(saw_log("had state tombstone"))
		end)

		it("keeps the table identity of entries(), tombstones() and room_mappings() across a reload", function()
			local entries, tombs, rooms = reg:entries(), reg:tombstones(), reg:room_mappings()
			add("rid-a", 2043, "Desk Lamp")
			store.hue_lights = { ["rid-b"] = v1(2050, "Porch") }
			reg:load()
			assert.equal(entries, reg:entries())
			assert.equal(tombs, reg:tombstones())
			assert.equal(rooms, reg:room_mappings())
			assert.is_nil(entries["rid-a"], "load replaces the contents")
			assert.equal("Porch", entries["rid-b"].name)
		end)

		it("loads room mappings and tombstones, and starts empty for a non-table value", function()
			store.hue_rooms = { ["room-1"] = { c4_room_id = "12", c4_room_name = "Kitchen", hue_name = "Kitchen" } }
			store.hue_tombstones = { ["rid-x"] = { name = "Old Lamp", device_name = "Old", deleted_at = "777" } }
			store.hue_lights = "garbage"
			local counts = reg:load()
			assert.same({ linked = 0, gone = 0, unbound = 0, tombstones = 1, rooms = 1 }, counts)
			assert.same({ c4_room_id = 12, c4_room_name = "Kitchen", hue_name = "Kitchen", type = "room" },
				reg:room_mapping("room-1"))
			assert.same({ name = "Old Lamp", device_name = "Old", deleted_at = 777 }, reg:tombstones()["rid-x"])
			assert.truthy(saw_log("hue_lights is a string, not a table"))
		end)
	end)

	describe("add()", function()
		it("creates a linked entry stamped created_at = now(), copying known and unknown fields", function()
			clock = 5000
			local entry = reg:add("rid-a", {
				device_id = "2043", proxy_id = 2044, name = "Desk Lamp", device_name = "Desk", model = "LCA001",
				caps = { has_color = true }, created_room_id = 7, extra = "kept",
			})
			assert.equal("linked", entry.state)
			assert.equal(5000, entry.created_at)
			assert.equal(2043, entry.device_id, "ids become numbers")
			assert.equal(2044, entry.proxy_id)
			assert.equal("Desk", entry.device_name)
			assert.equal(7, entry.created_room_id)
			assert.equal("kept", entry.extra)
			assert.equal(entry, reg:get("rid-a"), "get() returns the live entry")
			local rid, found = reg:by_device(2043)
			assert.equal("rid-a", rid)
			assert.equal(entry, found)
			assert.equal("rid-a", (reg:by_device("2043")), "by_device accepts a string id")
			assert.is_nil(reg:by_device(9999))
		end)

		it("forces state linked and keeps a given created_at", function()
			local entry = reg:add("rid-a", { device_id = 2043, state = "gone", gone_since = 1, created_at = 42 })
			assert.equal("linked", entry.state)
			assert.is_nil(entry.gone_since)
			assert.equal(42, entry.created_at)
		end)

		it("refuses an existing rid, a missing device, a device another entry holds and a bad rid", function()
			add("rid-a", 2043, "Desk Lamp")
			assert.same({ nil, "exists" }, { reg:add("rid-a", { device_id = 2099 }) })
			assert.same({ nil, "no device_id" }, { reg:add("rid-b", { name = "No device" }) })
			assert.same({ nil, "no device_id" }, { reg:add("rid-b", { device_id = 0 }) })
			assert.same({ nil, "device exists" }, { reg:add("rid-b", { device_id = 2043 }) })
			assert.same({ nil, "bad rid" }, { reg:add("", { device_id = 2050 }) })
			assert.same({ nil, "bad rid" }, { reg:add(nil, { device_id = 2050 }) })
			assert.same({ "rid-a" }, reg:rids())
		end)

		it("clears a tombstone for the rid", function()
			add("rid-a", 2043, "Desk Lamp")
			reg:tombstone("rid-a")
			assert.truthy(reg:tombstones()["rid-a"])
			add("rid-a", 2060, "Desk Lamp")
			assert.is_nil(reg:tombstones()["rid-a"])
			assert.equal(0, reg:counts().tombstones)
			assert.truthy(saw_log("tombstone cleared"))
		end)
	end)

	describe("update()", function()
		it("merges shallowly, coerces ids and returns nil for an unknown rid", function()
			add("rid-a", 2043, "Desk Lamp", { caps = { has_color = false } })
			local entry = reg:update("rid-a", {
				name = "Desk", mac_address = "aa:bb", proxy_id = "2044", device_id = "bad", caps = { has_color = true },
			})
			assert.equal(reg:get("rid-a"), entry)
			assert.equal("Desk", entry.name)
			assert.equal("aa:bb", entry.mac_address)
			assert.equal(2044, entry.proxy_id)
			assert.equal(2043, entry.device_id, "an invalid device id leaves the old one")
			assert.same({ has_color = true }, entry.caps)
			assert.is_nil(reg:update("rid-zz", { name = "x" }))
		end)

		it("removes a field given registry.CLEAR and routes state through set_state", function()
			add("rid-a", 2043, "Desk Lamp", { name_dismissed = "Old Name" })
			clock = 2000
			reg:update("rid-a", { name_dismissed = registry.CLEAR, state = "gone" })
			local entry = reg:get("rid-a")
			assert.is_nil(entry.name_dismissed)
			assert.equal("gone", entry.state)
			assert.equal(2000, entry.gone_since)
		end)
	end)

	describe("set_state()", function()
		before_each(function()
			add("rid-a", 2043, "Desk Lamp")
		end)

		it("linked -> gone stamps gone_since; gone -> linked clears it", function()
			clock = 2000
			assert.is_true(reg:set_state("rid-a", "gone"))
			assert.equal("gone", reg:get("rid-a").state)
			assert.equal(2000, reg:get("rid-a").gone_since)
			assert.is_nil(reg:get("rid-a").unbound_since)
			clock = 3000
			assert.is_true(reg:set_state("rid-a", "linked"))
			assert.equal("linked", reg:get("rid-a").state)
			assert.is_nil(reg:get("rid-a").gone_since)
		end)

		it("linked -> unbound stamps unbound_since; unbound -> linked clears it", function()
			clock = 2000
			assert.is_true(reg:set_state("rid-a", "unbound"))
			assert.equal(2000, reg:get("rid-a").unbound_since)
			assert.is_nil(reg:get("rid-a").gone_since)
			assert.is_true(reg:set_state("rid-a", "linked"))
			assert.is_nil(reg:get("rid-a").unbound_since)
		end)

		it("gone <-> unbound swaps the stamps", function()
			clock = 2000
			reg:set_state("rid-a", "gone")
			clock = 2500
			assert.is_true(reg:set_state("rid-a", "unbound"))
			assert.is_nil(reg:get("rid-a").gone_since)
			assert.equal(2500, reg:get("rid-a").unbound_since)
			clock = 3000
			assert.is_true(reg:set_state("rid-a", "gone"))
			assert.equal(3000, reg:get("rid-a").gone_since)
			assert.is_nil(reg:get("rid-a").unbound_since)
		end)

		it("returns false and changes nothing for the same state, an unknown rid or an unknown state", function()
			assert.is_false(reg:set_state("rid-a", "linked"))
			assert.is_false(reg:set_state("rid-zz", "gone"))
			assert.is_false(reg:set_state("rid-a", "tombstone"))
			assert.equal("linked", reg:get("rid-a").state)
			assert.is_nil(reg:get("rid-a").gone_since)
			assert.truthy(saw_log("unknown state tombstone"))
		end)

		it("logs each transition", function()
			reg:set_state("rid-a", "gone")
			assert.truthy(saw_log("Desk Lamp (device 2043, rid-a): linked -> gone"))
		end)
	end)

	describe("relink()", function()
		it("moves the same entry under the new rid, linked, stamps cleared, device and proxy intact", function()
			local entry = add("rid-old", 2043, "Desk Lamp", { proxy_id = 2044, caps = { has_color = false } })
			reg:set_state("rid-old", "gone")
			local moved = reg:relink("rid-old", "rid-new", { name = "New Lamp", caps = { has_color = true } })
			assert.equal(entry, moved, "the entry table survives, so nothing the device references changes")
			assert.is_nil(reg:get("rid-old"))
			assert.equal(entry, reg:get("rid-new"))
			assert.equal("linked", entry.state)
			assert.is_nil(entry.gone_since)
			assert.equal(2043, entry.device_id)
			assert.equal(2044, entry.proxy_id)
			assert.equal("New Lamp", entry.name)
			assert.same({ has_color = true }, entry.caps)
			assert.equal("rid-new", (reg:by_device(2043)))
			assert.truthy(saw_log("re-linked from rid-old"))
		end)

		it("works without fields and from the unbound state", function()
			add("rid-old", 2043, "Desk Lamp")
			reg:set_state("rid-old", "unbound")
			local entry = reg:relink("rid-old", "rid-new")
			assert.equal("linked", entry.state)
			assert.is_nil(entry.unbound_since)
			assert.equal("Desk Lamp", entry.name)
		end)

		it("refuses when the new rid has an entry (including the same rid), or the old rid is unknown", function()
			add("rid-a", 2043, "Desk Lamp")
			add("rid-b", 2050, "Porch")
			assert.same({ nil, "exists" }, { reg:relink("rid-a", "rid-b") })
			assert.same({ nil, "exists" }, { reg:relink("rid-a", "rid-a") })
			assert.same({ nil, "unknown" }, { reg:relink("rid-zz", "rid-c") })
			assert.same({ nil, "bad rid" }, { reg:relink("rid-a", "") })
			assert.equal("Desk Lamp", reg:get("rid-a").name)
			assert.equal("Porch", reg:get("rid-b").name)
		end)

		it("clears a tombstone for the new rid", function()
			add("rid-dead", 2010, "Deleted Lamp")
			reg:tombstone("rid-dead")
			add("rid-a", 2043, "Desk Lamp")
			reg:relink("rid-a", "rid-dead")
			assert.is_nil(reg:tombstones()["rid-dead"])
			assert.equal("Desk Lamp", reg:get("rid-dead").name)
		end)
	end)

	describe("forget() and tombstone()", function()
		before_each(function()
			add("rid-a", 2043, "Desk Lamp", { device_name = "Desk" })
		end)

		it("forget removes the entry and leaves no tombstone", function()
			local entry = reg:forget("rid-a")
			assert.equal("Desk Lamp", entry.name)
			assert.is_nil(reg:get("rid-a"))
			assert.same({}, reg:tombstones())
			assert.same({ linked = 0, gone = 0, unbound = 0, tombstones = 0, rooms = 0 }, reg:counts())
			assert.is_nil(reg:forget("rid-a"))
			assert.truthy(saw_log("forgot Desk Lamp"))
		end)

		it("tombstone removes the entry and remembers the names and the time", function()
			clock = 4000
			local tomb = reg:tombstone("rid-a")
			assert.same({ name = "Desk Lamp", device_name = "Desk", deleted_at = 4000 }, tomb)
			assert.equal(tomb, reg:tombstones()["rid-a"])
			assert.is_nil(reg:get("rid-a"))
			assert.is_nil(reg:by_device(2043))
			assert.equal(1, reg:counts().tombstones)
			assert.is_nil(reg:tombstone("rid-a"), "nothing left to tombstone")
			assert.truthy(saw_log("tombstoned Desk Lamp"))
		end)

		it("clear_tombstone reports whether there was one", function()
			reg:tombstone("rid-a")
			assert.is_true(reg:clear_tombstone("rid-a"))
			assert.is_false(reg:clear_tombstone("rid-a"))
			assert.is_false(reg:clear_tombstone(nil))
			assert.same({}, reg:tombstones())
		end)
	end)

	describe("rids()", function()
		it("sorts by name case-insensitively, ties and missing names by rid, and filters by state", function()
			add("rid-3", 3, "porch")
			add("rid-2", 2, "Desk Lamp")
			add("rid-1", 1, "Zebra")
			add("rid-5", 5, "Desk Lamp")
			add("rid-4", 4)
			add("rid-0", 6)
			reg:set_state("rid-1", "gone")
			reg:set_state("rid-3", "unbound")
			assert.same({ "rid-0", "rid-4", "rid-2", "rid-5", "rid-3", "rid-1" }, reg:rids())
			assert.same({ "rid-0", "rid-4", "rid-2", "rid-5" }, reg:rids("linked"))
			assert.same({ "rid-1" }, reg:rids("gone"))
			assert.same({ "rid-3" }, reg:rids("unbound"))
			assert.same({}, reg:rids("tombstone"))
		end)
	end)

	describe("counts()", function()
		it("counts every state, the tombstones and the room mappings", function()
			add("rid-a", 1, "A")
			add("rid-b", 2, "B")
			add("rid-c", 3, "C")
			add("rid-d", 4, "D")
			reg:set_state("rid-b", "gone")
			reg:set_state("rid-c", "unbound")
			reg:tombstone("rid-d")
			reg:set_room_mapping("room-1", { c4_room_id = 1 })
			assert.same({ linked = 1, gone = 1, unbound = 1, tombstones = 1, rooms = 1 }, reg:counts())
		end)
	end)

	describe("reconcile()", function()
		before_each(function()
			add("rid-linked", 100, "Linked")
			add("rid-unbound", 200, "Unbound")
			add("rid-gone", 300, "Gone")
			reg:set_state("rid-unbound", "unbound")
			reg:set_state("rid-gone", "gone")
		end)

		it("marks a linked entry unbound when its device is present but not bound", function()
			clock = 7000
			local out = reg:reconcile({ bound = {}, present = { [100] = true, [200] = true, [300] = true } })
			assert.same({ unbound = { "rid-linked" }, relinked = {}, tombstoned = {} }, out)
			assert.equal("unbound", reg:get("rid-linked").state)
			assert.equal(7000, reg:get("rid-linked").unbound_since)
			assert.equal("unbound", reg:get("rid-unbound").state, "already unbound: not reported again")
			assert.equal("gone", reg:get("rid-gone").state, "gone is about the Hue side")
		end)

		it("re-links an unbound entry whose device is bound again", function()
			local out = reg:reconcile({ bound = { [100] = true, [200] = true, [300] = true } })
			assert.same({ unbound = {}, relinked = { "rid-unbound" }, tombstoned = {} }, out)
			assert.equal("linked", reg:get("rid-unbound").state)
			assert.is_nil(reg:get("rid-unbound").unbound_since)
			assert.equal("gone", reg:get("rid-gone").state, "a bound gone entry stays gone")
		end)

		it("tombstones entries in neither set when the present set is known, whatever their state", function()
			clock = 8000
			local out = reg:reconcile({ bound = { [100] = true }, present = { [100] = true } })
			assert.same({ unbound = {}, relinked = {}, tombstoned = { "rid-gone", "rid-unbound" } }, out)
			assert.is_nil(reg:get("rid-gone"))
			assert.is_nil(reg:get("rid-unbound"))
			assert.equal("linked", reg:get("rid-linked").state)
			assert.same({ name = "Gone", device_name = nil, deleted_at = 8000 }, reg:tombstones()["rid-gone"])
			assert.equal(2, reg:counts().tombstones)
		end)

		it("tombstones nothing when the present set is nil, but still marks unbound", function()
			local out = reg:reconcile({ bound = { [200] = true } })
			assert.same({ unbound = { "rid-linked" }, relinked = { "rid-unbound" }, tombstoned = {} }, out)
			assert.equal("gone", reg:get("rid-gone").state)
			assert.equal(0, reg:counts().tombstones)
		end)

		it("treats an empty present set as unknown", function()
			local out = reg:reconcile({ bound = {}, present = {} })
			assert.same({}, out.tombstoned)
			assert.same({ "rid-linked" }, out.unbound)
			assert.equal(3, reg:counts().linked + reg:counts().gone + reg:counts().unbound)
			assert.truthy(saw_log("empty present set treated as unknown"))
		end)

		it("accepts string device ids in the sets and a missing argument", function()
			local out = reg:reconcile({ bound = { ["100"] = true, ["200"] = true }, present = { ["300"] = true } })
			assert.same({ unbound = {}, relinked = { "rid-unbound" }, tombstoned = {} }, out)
			assert.equal("gone", reg:get("rid-gone").state)
			out = reg:reconcile()
			assert.same({ unbound = { "rid-linked", "rid-unbound" }, relinked = {}, tombstoned = {} }, out)
		end)

		it("reports in name order", function()
			add("rid-a", 400, "Aardvark")
			add("rid-z", 500, "zzz")
			local out = reg:reconcile({ bound = {}, present = { [400] = true, [500] = true, [100] = true,
				[200] = true, [300] = true } })
			assert.same({ "rid-a", "rid-linked", "rid-z" }, out.unbound)
		end)
	end)

	describe("room mappings", function()
		it("stores a normalised copy, reads it back, lists and removes it", function()
			local given = { c4_room_id = "12", c4_room_name = "Kitchen", hue_name = "Kitchen", type = "zone" }
			local m = reg:set_room_mapping("zone-1", given)
			assert.same({ c4_room_id = 12, c4_room_name = "Kitchen", hue_name = "Kitchen", type = "zone" }, m)
			assert.are_not.equal(given, m, "a copy, so the caller's table is not shared")
			assert.equal(m, reg:room_mapping("zone-1"))
			reg:set_room_mapping("room-1", { c4_room_id = 7, c4_room_name = "Hall", hue_name = "Hall" })
			assert.equal("room", reg:room_mapping("room-1").type, "type defaults to room")
			assert.same({ ["zone-1"] = m, ["room-1"] = reg:room_mapping("room-1") }, reg:room_mappings())
			assert.equal(m, reg:remove_room_mapping("zone-1"))
			assert.is_nil(reg:room_mapping("zone-1"))
			assert.is_nil(reg:remove_room_mapping("zone-1"))
			assert.is_nil(reg:room_mapping(nil))
			assert.same({ nil, "bad rid" }, { reg:set_room_mapping("", { c4_room_id = 1 }) })
		end)

		it("overwrites an existing mapping for the same group", function()
			reg:set_room_mapping("room-1", { c4_room_id = 7, c4_room_name = "Hall", hue_name = "Hall" })
			reg:set_room_mapping("room-1", { c4_room_id = 9, c4_room_name = "Office", hue_name = "Hall" })
			assert.equal(9, reg:room_mapping("room-1").c4_room_id)
			assert.equal(1, reg:counts().rooms)
		end)
	end)

	describe("save()", function()
		it("writes exactly the three keys with the current tables; mutators alone persist nothing", function()
			clock = 1500
			add("rid-a", 2043, "Desk Lamp", { proxy_id = 2044, device_name = "Desk" })
			add("rid-b", 2050, "Porch")
			reg:set_state("rid-a", "gone")
			reg:tombstone("rid-b")
			reg:set_room_mapping("room-1", { c4_room_id = 7, c4_room_name = "Hall", hue_name = "Hall", type = "room" })
			assert.same({}, saved, "nothing persisted before save()")
			assert.is_nil(store.hue_lights)

			reg:save()
			table.sort(saved)
			assert.same({ "hue_lights", "hue_rooms", "hue_tombstones" }, saved)
			assert.same({
				["rid-a"] = {
					device_id = 2043, proxy_id = 2044, name = "Desk Lamp", device_name = "Desk",
					state = "gone", gone_since = 1500, created_at = 1500,
				},
			}, store.hue_lights)
			assert.same({ ["rid-b"] = { name = "Porch", device_name = nil, deleted_at = 1500 } }, store.hue_tombstones)
			assert.same({ ["room-1"] = { c4_room_id = 7, c4_room_name = "Hall", hue_name = "Hall", type = "room" } },
				store.hue_rooms)
		end)

		it("round-trips through load()", function()
			add("rid-a", 2043, "Desk Lamp", { proxy_id = 2044, mac_address = "aa:bb", caps = { has_cct = true } })
			reg:set_state("rid-a", "unbound")
			add("rid-b", 2050, "Porch")
			reg:tombstone("rid-b")
			reg:set_room_mapping("zone-1", { c4_room_id = 7, c4_room_name = "Hall", hue_name = "Downstairs", type = "zone" })
			reg:save()

			local again = new_reg()
			assert.same({ linked = 0, gone = 0, unbound = 1, tombstones = 1, rooms = 1 }, again:load())
			assert.same(reg:get("rid-a"), again:get("rid-a"))
			assert.same(reg:tombstones(), again:tombstones())
			assert.same(reg:room_mappings(), again:room_mappings())
		end)
	end)
end)
