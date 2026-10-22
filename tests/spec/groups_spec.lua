local json = require("dkjson")
local groups = require("bridge.groups")
local F = require("fixtures.hue_resources")

-- Decode a fixture the way http.request does (dkjson, null → nil).
local function decode(text)
	local value, _, err = json.decode(text)
	assert(value, err)
	return value
end

local function items(text)
	return decode(text).data
end

-- The one container an event fixture carries.
local function container(text)
	return decode(text)[1]
end

local function rids(list)
	local out = {}
	for i, group in ipairs(list) do
		out[i] = group.rid
	end
	return out
end

local function names(list)
	local out = {}
	for i, group in ipairs(list) do
		out[i] = group.name
	end
	return out
end

-- A hand-made group item in the shape the bridge sends.
local function room_item(rid, name, device_rids)
	local children = {}
	for i, device in ipairs(device_rids or {}) do
		children[i] = { rid = device, rtype = "device" }
	end
	return { id = rid, id_v1 = "/groups/9", type = "room", metadata = { name = name, archetype = "other" },
		children = children, services = { { rid = rid .. "-gl", rtype = "grouped_light" } } }
end

describe("bridge.groups", function()
	local g, all

	before_each(function()
		all = {}
		for _, text in ipairs({ F.room, F.zone, F.bridge_home }) do
			for _, item in ipairs(items(text)) do
				all[#all + 1] = item
			end
		end
		g = groups.new()
		g:absorb(all)
	end)

	describe("absorb()", function()
		it("caches every room, zone and the bridge_home from one mixed list", function()
			assert.same({ room = 2, zone = 2, bridge_home = 1 }, g:counts())
			assert.equal("Garage", g:group(F.group_rids.garage).name)
			assert.equal("zone", g:group(F.group_rids.downstairs).type)
			assert.equal("bridge_home", g:group(F.group_rids.home).type)
		end)

		it("returns the counts and ignores items of other types", function()
			local fresh = groups.new()
			local mixed = { items(F.light)[1], items(F.room)[1], items(F.device)[1] }
			assert.same({ room = 1, zone = 0, bridge_home = 0 }, fresh:absorb(mixed))
			assert.is_nil(fresh:group(F.rids.living))
			assert.same({ room = 0, zone = 0, bridge_home = 0 }, groups.new():absorb(nil))
		end)

		it("replaces only the types that appear in the list", function()
			-- A /room GET that no longer lists the Living Room.
			local garage_only = { items(F.room)[2] }
			assert.equal(F.group_rids.garage, garage_only[1].id)
			g:absorb(garage_only)
			assert.same({ room = 1, zone = 2, bridge_home = 1 }, g:counts())
			assert.is_nil(g:group(F.group_rids.living_room))
			assert.is_nil(g:room_of_device(F.device_rids.living), "membership of the dropped room is gone")
			assert.equal(F.group_rids.garage, g:room_of_device(F.device_rids.garage))
			assert.same({ F.group_rids.downstairs }, g:zones_of_light(F.rids.living), "zones were not in the list")
		end)

		it("is idempotent", function()
			local before = rids(g:groups())
			g:absorb(all)
			assert.same(before, rids(g:groups()))
			assert.same({ room = 2, zone = 2, bridge_home = 1 }, g:counts())
		end)
	end)

	describe("group()", function()
		it("gives the contract's shape for a room", function()
			local room = g:group(F.group_rids.living_room)
			assert.same({
				rid = F.group_rids.living_room,
				type = "room",
				name = "Living Room",
				children = { F.device_rids.hallway, F.device_rids.living },
				child_rtype = "device",
				child_rtypes = { [F.device_rids.hallway] = "device", [F.device_rids.living] = "device" },
				grouped_light_rid = F.grouped_light_rids.living_room,
				id_v1 = "/groups/2",
			}, room)
		end)

		it("gives the contract's shape for a zone and leaves an empty zone without a grouped_light", function()
			local zone = g:group(F.group_rids.downstairs)
			assert.equal("light", zone.child_rtype)
			assert.same({ F.rids.garage, F.rids.living }, zone.children)
			assert.equal(F.grouped_light_rids.downstairs, zone.grouped_light_rid)
			assert.equal("/groups/3", zone.id_v1)
			local attic = g:group(F.group_rids.attic)
			assert.same({}, attic.children)
			assert.is_nil(attic.grouped_light_rid)
			assert.equal("light", attic.child_rtype)
		end)

		it("keeps the per-child rtypes of the bridge_home, which has no name", function()
			local home = g:group(F.group_rids.home)
			assert.is_nil(home.name)
			assert.equal("/groups/0", home.id_v1)
			assert.equal(F.grouped_light_rids.home, home.grouped_light_rid)
			assert.same({
				[F.device_rids.kitchen] = "device",
				[F.device_rids.bridge] = "device",
				[F.group_rids.living_room] = "room",
				[F.group_rids.garage] = "room",
			}, home.child_rtypes)
			assert.equal(4, #home.children)
		end)

		it("is nil for nil and unknown rids", function()
			assert.is_nil(g:group(nil))
			assert.is_nil(g:group("nope"))
			assert.is_nil(g:group(F.rids.living), "a light rid is not a group")
		end)
	end)

	describe("groups()", function()
		it("lists rooms then zones, each sorted by name, when no type is given", function()
			assert.same({ "Garage", "Living Room", "Attic", "Downstairs" }, names(g:groups()))
		end)

		it("lists one type sorted by name", function()
			assert.same({ F.group_rids.garage, F.group_rids.living_room }, rids(g:groups("room")))
			assert.same({ F.group_rids.attic, F.group_rids.downstairs }, rids(g:groups("zone")))
			assert.same({ F.group_rids.home }, rids(g:groups("bridge_home")))
			assert.same({}, groups.new():groups("room"))
		end)

		it("sorts case-insensitively and breaks ties by rid", function()
			local fresh = groups.new()
			fresh:absorb({
				room_item("r-b", "office", {}),
				room_item("r-c", "Attic", {}),
				room_item("r-a", "Office", {}),
				room_item("r-d", "basement", {}),
			})
			assert.same({ "r-c", "r-d", "r-a", "r-b" }, rids(fresh:groups("room")))
		end)

		it("returns a fresh array each time", function()
			local first = g:groups("room")
			first[1] = nil
			assert.equal(2, #g:groups("room"))
		end)
	end)

	describe("membership", function()
		it("finds the room of a device from the room's children", function()
			assert.equal(F.group_rids.living_room, g:room_of_device(F.device_rids.living))
			assert.equal(F.group_rids.living_room, g:room_of_device(F.device_rids.hallway))
			assert.equal(F.group_rids.garage, g:room_of_device(F.device_rids.garage))
		end)

		it("has no room for a device that is a direct child of the bridge_home, or unknown", function()
			assert.is_nil(g:room_of_device(F.device_rids.kitchen))
			assert.is_nil(g:room_of_device(F.device_rids.bridge))
			assert.is_nil(g:room_of_device("nope"))
			assert.is_nil(g:room_of_device(nil))
			assert.is_nil(g:room_of_device(F.group_rids.living_room), "a room is not a device")
		end)

		it("lists the room-less devices from the bridge_home, sorted", function()
			local expected = { F.device_rids.kitchen, F.device_rids.bridge }
			table.sort(expected)
			assert.same(expected, g:roomless_devices())
		end)

		it("finds the zones of a light, sorted by zone name", function()
			assert.same({ F.group_rids.downstairs }, g:zones_of_light(F.rids.living))
			assert.same({ F.group_rids.downstairs }, g:zones_of_light(F.rids.garage))
			assert.same({}, g:zones_of_light(F.rids.kitchen))
			assert.same({}, g:zones_of_light(nil))
			local zone = container(F.events.zone_add).data[2]
			zone.children = { { rid = F.rids.living, rtype = "light" }, { rid = F.rids.living, rtype = "light" } }
			zone.metadata.name = "Accent"
			assert.is_true(g:apply(zone, "add"))
			assert.same({ F.new_zone_rid, F.group_rids.downstairs }, g:zones_of_light(F.rids.living),
				"Accent sorts before Downstairs; a duplicate child counts once")
		end)

		it("never infers a room from a zone", function()
			-- Garage White is in the Downstairs zone and the Garage room.
			assert.equal(F.group_rids.garage, g:room_of_device(F.device_rids.garage))
			assert.is_nil(g:room_of_device(F.rids.garage), "a light rid is not a device")
		end)
	end)

	describe("label()", function()
		it("names rooms plainly, zones with a suffix, and everything else as no room", function()
			assert.equal("Garage", g:label(F.group_rids.garage))
			assert.equal("Living Room", g:label(F.group_rids.living_room))
			assert.equal("Downstairs (zone)", g:label(F.group_rids.downstairs))
			assert.equal("(all lights)", g:label(F.group_rids.home))
			assert.equal("(no room)", g:label(nil))
			assert.equal("(no room)", g:label("nope"))
			assert.equal("(no room)", g:label(g:room_of_device(F.device_rids.kitchen)))
		end)
	end)

	describe("apply()", function()
		it("moves a device between rooms when both rooms send their whole children arrays", function()
			local event = container(F.events.room_move)
			assert.equal("update", event.type)
			assert.is_true(g:apply(event.data[1], event.type))
			assert.is_true(g:apply(event.data[2], event.type))
			assert.equal(F.group_rids.garage, g:room_of_device(F.device_rids.hallway))
			assert.equal(F.group_rids.living_room, g:room_of_device(F.device_rids.living))
			assert.same({ F.device_rids.living }, g:group(F.group_rids.living_room).children)
			assert.same({ F.device_rids.garage, F.device_rids.hallway }, g:group(F.group_rids.garage).children)
			assert.equal("Living Room", g:group(F.group_rids.living_room).name, "the name is untouched")
		end)

		it("is idempotent for a move applied twice", function()
			local event = container(F.events.room_move)
			for _ = 1, 2 do
				for _, item in ipairs(event.data) do
					g:apply(item, event.type)
				end
			end
			assert.equal(F.group_rids.garage, g:room_of_device(F.device_rids.hallway))
			assert.same({ F.device_rids.garage, F.device_rids.hallway }, g:group(F.group_rids.garage).children)
		end)

		it("renames a room and re-sorts", function()
			local event = container(F.events.room_rename)
			assert.is_true(g:apply(event.data[1], event.type))
			assert.equal("Lounge", g:group(F.group_rids.living_room).name)
			assert.equal("Lounge", g:label(F.group_rids.living_room))
			assert.same({ F.group_rids.garage, F.group_rids.living_room }, rids(g:groups("room")))
			assert.is_true(g:apply({ id = F.group_rids.living_room, type = "room", metadata = { name = "Attic" } },
				"update"))
			assert.same({ F.group_rids.living_room, F.group_rids.garage }, rids(g:groups("room")))
			assert.same({ F.device_rids.hallway, F.device_rids.living }, g:group(F.group_rids.living_room).children,
				"children are untouched by a rename")
		end)

		it("ignores an update for an unknown rid, leaving the resync to bring it", function()
			local event = container(F.events.room_move)
			event.data[1].id = "7d6c5b4a-0000-4000-8000-00000000r999"
			assert.is_false(g:apply(event.data[1], "update"))
			assert.is_nil(g:group("7d6c5b4a-0000-4000-8000-00000000r999"))
			assert.same({ room = 2, zone = 2, bridge_home = 1 }, g:counts())
		end)

		it("ignores an update that carries nothing modelled", function()
			local item = { id = F.group_rids.garage, id_v1 = "/groups/1", type = "room", metadata = { archetype = "garage" } }
			assert.is_true(g:apply(item, "update"), "id_v1 counts as carried")
			item.id_v1 = nil
			assert.is_false(g:apply(item, "update"))
			assert.is_false(g:apply({ id = F.group_rids.garage, type = "room" }, "update"))
		end)

		it("adds a zone together with its grouped_light item, and deletes it again", function()
			local add = container(F.events.zone_add)
			assert.equal("add", add.type)
			assert.is_false(g:apply(add.data[1], add.type), "the grouped_light item is not a group")
			assert.is_true(g:apply(add.data[2], add.type))
			local zone = g:group(F.new_zone_rid)
			assert.equal("Upstairs", zone.name)
			assert.equal("zone", zone.type)
			assert.same({ F.rids.hallway }, zone.children)
			assert.equal(F.new_zone_grouped_light_rid, zone.grouped_light_rid)
			assert.equal("/groups/5", zone.id_v1)
			assert.same({ F.new_zone_rid }, g:zones_of_light(F.rids.hallway))
			assert.same({ "Attic", "Downstairs", "Upstairs" }, names(g:groups("zone")))
			assert.equal("Upstairs (zone)", g:label(F.new_zone_rid))

			local del = container(F.events.zone_delete)
			assert.equal("delete", del.type)
			assert.is_false(g:apply(del.data[1], del.type), "grouped_light delete: not a cached group")
			assert.is_true(g:apply(del.data[2], del.type))
			assert.is_nil(g:group(F.new_zone_rid))
			assert.same({}, g:zones_of_light(F.rids.hallway))
			assert.equal("(no room)", g:label(F.new_zone_rid))
			assert.is_false(g:apply(del.data[2], del.type), "a second delete changes nothing")
		end)

		it("adding a known rid replaces the cached group", function()
			local item = room_item(F.group_rids.garage, "Carport", { F.device_rids.garage, F.device_rids.kitchen })
			assert.is_true(g:apply(item, "add"))
			assert.equal("Carport", g:group(F.group_rids.garage).name)
			assert.equal(F.group_rids.garage, g:room_of_device(F.device_rids.kitchen))
			assert.same({ room = 2, zone = 2, bridge_home = 1 }, g:counts())
			assert.same({ F.device_rids.bridge }, g:roomless_devices(), "the kitchen device now has a room")
		end)

		it("drops a deleted room and its memberships; a room-less device then shows no room", function()
			assert.is_true(g:apply({ id = F.group_rids.living_room, type = "room" }, "delete"))
			assert.is_nil(g:group(F.group_rids.living_room))
			assert.is_nil(g:room_of_device(F.device_rids.living))
			assert.equal("(no room)", g:label(g:room_of_device(F.device_rids.hallway)))
			assert.same({ F.group_rids.garage }, rids(g:groups("room")))
			assert.same({ F.group_rids.downstairs }, g:zones_of_light(F.rids.living), "zones are unaffected")
		end)

		it("refuses junk: wrong kind, type mismatch, no id, non-group add", function()
			assert.is_false(g:apply({ id = F.group_rids.garage, type = "room" }, "bogus"))
			assert.is_false(g:apply({ id = F.group_rids.garage, type = "zone" }, "delete"), "type mismatch")
			assert.is_false(g:apply({ type = "room", metadata = { name = "x" } }, "update"))
			assert.is_false(g:apply(nil, "update"))
			assert.is_false(g:apply(items(F.light)[1], "add"))
			assert.same({ room = 2, zone = 2, bridge_home = 1 }, g:counts())
		end)

		it("keeps the room-less list in step with rooms", function()
			-- bridge_home still lists Kitchen Strip's device, but a room now claims it: rooms win.
			assert.is_true(g:apply({ id = F.group_rids.garage, type = "room",
				children = { { rid = F.device_rids.garage, rtype = "device" },
					{ rid = F.device_rids.kitchen, rtype = "device" } } },
				"update"))
			assert.equal(F.group_rids.garage, g:room_of_device(F.device_rids.kitchen))
			assert.same({ F.device_rids.bridge }, g:roomless_devices())
			-- bridge_home children arrive whole too.
			assert.is_true(g:apply({ id = F.group_rids.home, type = "bridge_home",
				children = { { rid = F.group_rids.garage, rtype = "room" },
					{ rid = F.group_rids.living_room, rtype = "room" } } },
				"update"))
			assert.same({}, g:roomless_devices())
		end)
	end)
end)
