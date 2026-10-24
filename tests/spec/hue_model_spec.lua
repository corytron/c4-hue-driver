local json = require("dkjson")
local hue_model = require("bridge.hue_model")
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

local function by_rid(list)
	local out = {}
	for _, item in ipairs(list) do
		out[item.id] = item
	end
	return out
end

describe("bridge.hue_model", function()
	local light_items, device_items, zigbee_items

	before_each(function()
		light_items = by_rid(items(F.light))
		device_items = items(F.device)
		zigbee_items = items(F.zigbee_connectivity)
	end)

	describe("light()", function()
		it("normalises a colour light sitting at a white point (CCT mode)", function()
			local l = hue_model.light(light_items[F.rids.living])
			assert.equal(F.rids.living, l.rid)
			assert.equal(F.device_rids.living, l.device_rid)
			assert.equal("Living Room Lamp", l.name)
			assert.equal("sultan_bulb", l.archetype)
			assert.is_true(l.on)
			assert.equal(73.52, l.brightness)
			assert.equal(0.2, l.min_dim)
			assert.is_true(l.has_color)
			assert.equal(0.4575, l.x)
			assert.equal(0.4101, l.y)
			assert.same({ r = { x = 0.6915, y = 0.3083 }, g = { x = 0.17, y = 0.7 }, b = { x = 0.1532, y = 0.0475 } }, l.gamut)
			assert.is_true(l.has_cct)
			assert.equal(366, l.mirek)
			assert.is_true(l.mirek_valid)
			assert.equal(153, l.mirek_min)
			assert.equal(500, l.mirek_max)
			assert.equal("ct", l.color_mode)
			assert.is_nil(l.online)
		end)

		it("normalises a colour light in xy mode, whose mirek is null and invalid", function()
			local l = hue_model.light(light_items[F.rids.kitchen])
			assert.is_true(l.has_color)
			assert.is_true(l.has_cct)
			assert.equal(0.2731, l.x)
			assert.equal(0.1192, l.y)
			assert.is_false(l.mirek_valid)
			assert.is_nil(l.mirek)
			assert.equal(153, l.mirek_min)
			assert.equal(500, l.mirek_max)
			assert.equal("xy", l.color_mode)
			assert.equal(100, l.brightness)
			assert.equal(0.39, l.min_dim)
		end)

		it("normalises a CCT-only light", function()
			local l = hue_model.light(light_items[F.rids.hallway])
			assert.is_false(l.has_color)
			assert.is_nil(l.x)
			assert.is_nil(l.gamut)
			assert.is_true(l.has_cct)
			assert.equal(250, l.mirek)
			assert.is_true(l.mirek_valid)
			assert.equal(153, l.mirek_min)
			assert.equal(454, l.mirek_max)
			assert.equal("ct", l.color_mode)
		end)

		it("normalises a dimmable-only white light", function()
			local l = hue_model.light(light_items[F.rids.garage])
			assert.is_false(l.on)
			assert.equal(100, l.brightness)
			assert.equal(5, l.min_dim)
			assert.is_false(l.has_color)
			assert.is_false(l.has_cct)
			assert.is_nil(l.mirek)
			assert.is_nil(l.mirek_min)
			assert.is_nil(l.color_mode)
			assert.equal("classic_bulb", l.archetype)
		end)

		it("has exactly the fields of the contract", function()
			local l = hue_model.light(light_items[F.rids.living])
			local expected = { rid = 1, id_v1 = 1, device_rid = 1, service_id = 1, name = 1, archetype = 1, on = 1,
				brightness = 1, min_dim = 1, has_color = 1, x = 1, y = 1, gamut = 1, has_cct = 1, mirek = 1,
				mirek_valid = 1, mirek_min = 1, mirek_max = 1, color_mode = 1 }
			for k in pairs(l) do
				assert.truthy(expected[k], "unexpected field " .. k)
			end
		end)

		it("gives a nameless light a fallback name", function()
			local l = hue_model.light({ id = "x", id_v1 = "/lights/9", on = { on = true } })
			assert.equal("Hue light /lights/9", l.name)
		end)

		it("carries id_v1 and service_id when present, and only then", function()
			local l = hue_model.light(light_items[F.rids.kitchen])
			assert.equal("/lights/2", l.id_v1)
			assert.equal(0, l.service_id)
			local bare = hue_model.light({ id = "x", on = { on = true } })
			assert.is_nil(bare.id_v1)
			assert.is_nil(bare.service_id)
			local odd = hue_model.light({ id = "x", id_v1 = "", service_id = "1", on = { on = true } })
			assert.is_nil(odd.id_v1, "an empty id_v1 is no id_v1")
			assert.is_nil(odd.service_id, "only a number is a service_id")
			assert.equal(1, hue_model.light({ id = "x", service_id = 1 }).service_id)
		end)

		it("never reports id_v1 or service_id as changed by an event", function()
			local l = hue_model.light(light_items[F.rids.living])
			local event = decode(F.events.brightness)[1].data[1]
			assert.equal("/lights/1", event.id_v1, "events do carry id_v1")
			assert.same({ "brightness" }, hue_model.update(l, event))
			assert.equal("/lights/1", l.id_v1)
		end)
	end)

	describe("update()", function()
		it("merges a brightness-only event and reports just that field", function()
			local l = hue_model.light(light_items[F.rids.living])
			local event = decode(F.events.brightness)[1].data[1]
			local changed = hue_model.update(l, event)
			assert.same({ "brightness" }, changed)
			assert.equal(50, l.brightness)
			assert.is_true(l.on)
			assert.equal(366, l.mirek)
			assert.equal("ct", l.color_mode)
			assert.equal("Living Room Lamp", l.name)
		end)

		it("switches to xy mode on a colour event with an invalid mirek", function()
			local l = hue_model.light(light_items[F.rids.living])
			local event = decode(F.events.color)[1].data[1]
			local changed = hue_model.update(l, event)
			assert.same({ "x", "y", "mirek", "color_mode" }, changed)
			assert.equal(0.1532, l.x)
			assert.equal(0.0475, l.y)
			assert.is_false(l.mirek_valid)
			assert.is_nil(l.mirek)
			assert.equal("xy", l.color_mode)
			assert.is_true(l.has_cct, "capabilities are not touched by events")
		end)

		it("switches back to ct mode when mirek becomes valid", function()
			local l = hue_model.light(light_items[F.rids.kitchen])
			local changed = hue_model.update(l, decode(F.events.ct)[1].data[1])
			assert.same({ "x", "y", "mirek", "color_mode" }, changed)
			assert.equal(153, l.mirek)
			assert.equal("ct", l.color_mode)
		end)

		it("reports an on/off change", function()
			local l = hue_model.light(light_items[F.rids.garage])
			l.on = true
			local changed = hue_model.update(l, decode(F.events.off)[1].data[1])
			assert.same({ "on" }, changed)
			assert.is_false(l.on)
		end)

		it("reports nothing for an event that touches no modelled field", function()
			local l = hue_model.light(light_items[F.rids.living])
			local before = {}
			for k, v in pairs(l) do before[k] = v end
			assert.same({}, hue_model.update(l, decode(F.events.noop)[1].data[1]))
			for k, v in pairs(before) do
				assert.equal(v, l[k], k)
			end
			assert.same({}, hue_model.update(l, nil))
		end)

		it("treats a numeric mirek without mirek_valid as valid", function()
			local l = hue_model.light(light_items[F.rids.kitchen])
			local changed = hue_model.update(l, { color_temperature = { mirek = 300 } })
			assert.same({ "mirek", "color_mode" }, changed)
			assert.equal(300, l.mirek)
			assert.is_true(l.mirek_valid)
			assert.equal("ct", l.color_mode)
		end)

		it("reports a Hue rename without touching state", function()
			local l = hue_model.light(light_items[F.rids.living])
			assert.same({ "name" }, hue_model.update(l, { metadata = { name = "Lounge Lamp" } }))
			assert.equal("Lounge Lamp", l.name)
		end)
	end)

	describe("devices()", function()
		it("maps device rid to name, model, light rids and zigbee rid", function()
			local devices = hue_model.devices(device_items)
			local living = devices[F.device_rids.living]
			assert.equal("Living Room Lamp", living.name)
			assert.equal("Hue color lamp", living.model)
			assert.equal("LCA001", living.model_id)
			assert.same({ F.rids.living }, living.light_rids)
			assert.equal(F.zigbee_rids.living, living.zigbee_rid)
			assert.equal("Hue white lamp", devices[F.device_rids.garage].model)
			assert.same({ F.rids.hallway }, devices[F.device_rids.hallway].light_rids)
		end)

		it("keeps the bridge's own device with no light rids", function()
			local devices = hue_model.devices(device_items)
			local bridge = devices[F.device_rids.bridge]
			assert.same({}, bridge.light_rids)
			assert.equal("Philips hue", bridge.model)
			local n = 0
			for _ in pairs(devices) do n = n + 1 end
			assert.equal(5, n)
		end)

		it("falls back to the model id when there is no product name", function()
			local devices = hue_model.devices({ { id = "d1", product_data = { model_id = "LCA001" },
				services = { { rid = "l1", rtype = "light" } } } })
			assert.equal("LCA001", devices.d1.model)
			assert.is_nil(devices.d1.name)
			assert.same({}, hue_model.devices(nil))
		end)
	end)

	describe("connectivity()", function()
		it("reads connected as online and anything else as offline", function()
			local by_status = {}
			for _, item in ipairs(zigbee_items) do
				local c = hue_model.connectivity(item)
				by_status[c.device_rid] = c
			end
			assert.is_true(by_status[F.device_rids.living].online)
			assert.equal(F.zigbee_rids.living, by_status[F.device_rids.living].rid)
			assert.is_false(by_status[F.device_rids.garage].online)
			assert.equal("connectivity_issue", by_status[F.device_rids.garage].status)
			assert.is_false(hue_model.connectivity({ id = "z", owner = { rid = "d" }, status = "disconnected" }).online)
			assert.is_false(hue_model.connectivity({ id = "z", owner = { rid = "d" },
				status = "unidirectional_incoming" }).online)
		end)

		it("carries the mac_address when the item has one", function()
			local by_device = {}
			for _, item in ipairs(zigbee_items) do
				local c = hue_model.connectivity(item)
				by_device[c.device_rid] = c
			end
			assert.equal("00:17:88:01:0b:12:34:01-0b", by_device[F.device_rids.living].mac_address)
			assert.equal("00:17:88:01:0b:12:34:04-0b", by_device[F.device_rids.garage].mac_address)
			local event = decode(F.events.connectivity)[1].data[1]
			assert.is_nil(hue_model.connectivity(event).mac_address, "a status event carries no MAC")
			assert.is_nil(hue_model.connectivity({ id = "z", status = "connected", mac_address = "" }).mac_address)
			assert.is_nil(hue_model.connectivity({ id = "z", status = "connected", mac_address = {} }).mac_address,
				"a null decoded as a table is no MAC")
		end)
	end)

	describe("group()", function()
		local room_items, zone_items, home_items

		before_each(function()
			room_items = by_rid(items(F.room))
			zone_items = by_rid(items(F.zone))
			home_items = items(F.bridge_home)
		end)

		it("parses a room: device children, grouped_light, id_v1, name", function()
			local room = hue_model.group(room_items[F.group_rids.living_room])
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
			assert.same({ F.device_rids.garage }, hue_model.group(room_items[F.group_rids.garage]).children)
		end)

		it("parses a zone: light children", function()
			local zone = hue_model.group(zone_items[F.group_rids.downstairs])
			assert.equal("zone", zone.type)
			assert.equal("Downstairs", zone.name)
			assert.equal("light", zone.child_rtype)
			assert.same({ F.rids.garage, F.rids.living }, zone.children)
			assert.same({ [F.rids.garage] = "light", [F.rids.living] = "light" }, zone.child_rtypes)
			assert.equal(F.grouped_light_rids.downstairs, zone.grouped_light_rid)
			assert.equal("/groups/3", zone.id_v1)
		end)

		it("parses an empty zone, which has no grouped_light", function()
			local attic = hue_model.group(zone_items[F.group_rids.attic])
			assert.equal("Attic", attic.name)
			assert.same({}, attic.children)
			assert.same({}, attic.child_rtypes)
			assert.equal("light", attic.child_rtype, "the nominal rtype of a zone's children")
			assert.is_nil(attic.grouped_light_rid)
			assert.equal("/groups/4", attic.id_v1)
		end)

		it("parses the bridge_home: mixed children, no name", function()
			local home = hue_model.group(home_items[1])
			assert.equal(F.group_rids.home, home.rid)
			assert.equal("bridge_home", home.type)
			assert.is_nil(home.name)
			assert.equal("room", home.child_rtype, "nominal only; child_rtypes is the truth")
			assert.same({ F.device_rids.kitchen, F.device_rids.bridge, F.group_rids.living_room, F.group_rids.garage },
				home.children)
			assert.same({
				[F.device_rids.kitchen] = "device",
				[F.device_rids.bridge] = "device",
				[F.group_rids.living_room] = "room",
				[F.group_rids.garage] = "room",
			}, home.child_rtypes)
			assert.equal(F.grouped_light_rids.home, home.grouped_light_rid)
			assert.equal("/groups/0", home.id_v1)
		end)

		it("is nil for anything that is not a room, zone or bridge_home", function()
			assert.is_nil(hue_model.group(light_items[F.rids.living]))
			assert.is_nil(hue_model.group(device_items[1]))
			assert.is_nil(hue_model.group(decode(F.events.zone_add)[1].data[1]), "a grouped_light")
			assert.is_nil(hue_model.group({ id = "x", children = {} }), "no type")
			assert.is_nil(hue_model.group({ type = "room", children = {} }), "no id")
			assert.is_nil(hue_model.group(nil))
		end)

		it("gives a nameless room a fallback name and skips malformed children", function()
			local room = hue_model.group({ id = "r", id_v1 = "/groups/7", type = "room",
				children = { { rid = "d1", rtype = "device" }, {}, "junk", { rid = "d2" } } })
			assert.equal("Hue room /groups/7", room.name)
			assert.same({ "d1", "d2" }, room.children)
			assert.same({ d1 = "device", d2 = "unknown" }, room.child_rtypes)
			assert.equal("device", room.child_rtype, "mixed rtypes fall back to the nominal one")
			assert.equal("Hue zone z", hue_model.group({ id = "z", type = "zone" }).name)
		end)
	end)

	describe("update_group()", function()
		local room

		before_each(function()
			room = hue_model.group(by_rid(items(F.room))[F.group_rids.living_room])
		end)

		it("replaces the whole children list from a room update", function()
			local event = decode(F.events.room_move)[1].data[1]
			assert.equal(F.group_rids.living_room, event.id)
			assert.same({ "children", "id_v1" }, hue_model.update_group(room, event))
			assert.same({ F.device_rids.living }, room.children)
			assert.same({ [F.device_rids.living] = "device" }, room.child_rtypes)
			assert.equal("device", room.child_rtype)
			assert.equal("Living Room", room.name)
			assert.equal(F.grouped_light_rids.living_room, room.grouped_light_rid)
		end)

		it("renames without touching the children", function()
			local event = decode(F.events.room_rename)[1].data[1]
			assert.same({ "name", "id_v1" }, hue_model.update_group(room, event))
			assert.equal("Lounge", room.name)
			assert.same({ F.device_rids.hallway, F.device_rids.living }, room.children)
		end)

		it("reports nothing for an item without modelled fields, or no item", function()
			assert.same({}, hue_model.update_group(room, { id = F.group_rids.living_room, type = "room" }))
			assert.same({}, hue_model.update_group(room, { metadata = { archetype = "lounge" } }))
			assert.same({}, hue_model.update_group(room, nil))
			assert.same({}, hue_model.update_group(room, { children = "junk", services = 3, id_v1 = "" }))
			assert.equal("Living Room", room.name)
			assert.equal(2, #room.children)
		end)

		it("empties the children from an empty array and takes a new grouped_light", function()
			assert.same({ "children", "grouped_light_rid" },
				hue_model.update_group(room, { children = {}, services = { { rid = "gl2", rtype = "grouped_light" } } }))
			assert.same({}, room.children)
			assert.same({}, room.child_rtypes)
			assert.equal("device", room.child_rtype)
			assert.equal("gl2", room.grouped_light_rid)
			assert.same({}, hue_model.update_group(room, { services = { { rid = "x", rtype = "light" } } }),
				"other services are not a grouped_light")
			assert.equal("gl2", room.grouped_light_rid)
		end)

		it("lets a zone's children follow their rtype", function()
			local zone = hue_model.group(by_rid(items(F.zone))[F.group_rids.attic])
			assert.same({ "children" },
				hue_model.update_group(zone, { children = { { rid = F.rids.hallway, rtype = "light" } } }))
			assert.same({ F.rids.hallway }, zone.children)
			assert.equal("light", zone.child_rtype)
		end)
	end)

	describe("state_params()", function()
		local function assert_all_strings(params)
			for k, v in pairs(params) do
				assert.equal("string", type(v), k .. " must be a string")
			end
		end

		it("carries every field as a string when fields is nil", function()
			local l = hue_model.light(light_items[F.rids.living])
			l.online = true
			local p = hue_model.state_params(l, nil, "resync")
			assert_all_strings(p)
			assert.same({ rid = F.rids.living, reason = "resync", on = "true", brightness = "73.52",
				x = "0.4575", y = "0.4101", mirek = "366", color_mode = "ct", online = "true" }, p)
		end)

		it("leaves out fields without a value", function()
			local l = hue_model.light(light_items[F.rids.kitchen])
			local p = hue_model.state_params(l, nil, "resync")
			assert_all_strings(p)
			assert.is_nil(p.mirek)
			assert.is_nil(p.online)
			assert.equal("xy", p.color_mode)
			local white = hue_model.state_params(hue_model.light(light_items[F.rids.garage]), nil, "hello")
			assert.same({ rid = F.rids.garage, reason = "hello", on = "false", brightness = "100" }, white)
		end)

		it("carries only the listed fields, ignoring names that are not state", function()
			local l = hue_model.light(light_items[F.rids.living])
			local p = hue_model.state_params(l, { "brightness", "name", "gamut" }, "event")
			assert.same({ rid = F.rids.living, reason = "event", brightness = "73.52" }, p)
			assert.is_true(hue_model.has_state(p))
			assert.is_false(hue_model.has_state(hue_model.state_params(l, { "name" }, "event")))
		end)

		it("always includes rid and a reason", function()
			local p = hue_model.state_params({ rid = "r" }, {}, nil)
			assert.same({ rid = "r", reason = "event" }, p)
		end)
	end)

	describe("caps() and configure_params()", function()
		it("extracts the capabilities the registry persists", function()
			assert.same({ has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 0.2 },
				hue_model.caps(hue_model.light(light_items[F.rids.living])))
			assert.same({ has_color = false, has_cct = false, min_dim = 5 },
				hue_model.caps(hue_model.light(light_items[F.rids.garage])))
		end)

		it("builds string-valued HUE_CONFIGURE params from a light and its device", function()
			local devices = hue_model.devices(device_items)
			local l = hue_model.light(light_items[F.rids.living])
			local p = hue_model.configure_params(l, devices[l.device_rid])
			for k, v in pairs(p) do
				assert.equal("string", type(v), k)
			end
			assert.same({ rid = F.rids.living, name = "Living Room Lamp", model = "Hue color lamp",
				has_color = "true", has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "0.2" }, p)
		end)

		it("omits unknown limits for a white light and the model without a device", function()
			local p = hue_model.configure_params(hue_model.light(light_items[F.rids.garage]), nil)
			assert.same({ rid = F.rids.garage, name = "Garage White", has_color = "false", has_cct = "false",
				min_dim = "5" }, p)
		end)

		it("builds the same params from a persisted registry entry", function()
			local p = hue_model.registry_configure_params(F.rids.hallway, {
				device_id = 2002, name = "Hallway Ambiance", model = "Hue ambiance lamp",
				caps = { has_color = false, has_cct = true, mirek_min = 153, mirek_max = 454, min_dim = 0.2 },
			})
			assert.same({ rid = F.rids.hallway, name = "Hallway Ambiance", model = "Hue ambiance lamp",
				has_color = "false", has_cct = "true", mirek_min = "153", mirek_max = "454", min_dim = "0.2" }, p)
			assert.same({ rid = "r", has_color = "false", has_cct = "false" },
				hue_model.registry_configure_params("r", { device_id = 1 }))
		end)

		it("merges the import-ui fields of `extra` as strings, after the existing fields", function()
			local devices = hue_model.devices(device_items)
			local l = hue_model.light(light_items[F.rids.living])
			local p = hue_model.configure_params(l, devices[l.device_rid],
				{ hue_room = "Living Room", id_v1 = "/lights/1", state = "linked" })
			for k, v in pairs(p) do
				assert.equal("string", type(v), k)
			end
			assert.same({ rid = F.rids.living, name = "Living Room Lamp", model = "Hue color lamp",
				has_color = "true", has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "0.2",
				hue_room = "Living Room", id_v1 = "/lights/1", state = "linked" }, p)
		end)

		it("skips nil and empty extra values, turns numbers and booleans into strings, drops tables", function()
			local p = hue_model.registry_configure_params("r", { device_id = 1 },
				{ hue_room = "", id_v1 = nil, state = "gone", service_id = 0, flag = true, caps = { has_color = true },
					[1] = "positional" })
			assert.same({ rid = "r", has_color = "false", has_cct = "false", state = "gone", service_id = "0",
				flag = "true" }, p)
		end)

		it("is unchanged without extra", function()
			local l = hue_model.light(light_items[F.rids.garage])
			local plain = hue_model.configure_params(l, nil)
			assert.same(plain, hue_model.configure_params(l, nil, nil))
			assert.same(plain, hue_model.configure_params(l, nil, {}))
			assert.same(plain, hue_model.configure_params(l, nil, "junk"))
			assert.same({ rid = F.rids.garage, name = "Garage White", has_color = "false", has_cct = "false",
				min_dim = "5" }, plain)
		end)
	end)

	describe("scene()", function()
		local scene_items

		before_each(function()
			scene_items = by_rid(items(F.scene))
		end)

		-- The one scene recorded whole from the house bridge: a static zone scene.
		it("parses the recorded static zone scene: group, status, last_recall, speed", function()
			local s = hue_model.scene(scene_items[F.scene_rids.nightlight])
			assert.same({
				rid = F.scene_rids.nightlight,
				name = "Nightlight",
				group_rid = F.group_rids.downstairs,
				group_type = "zone",
				id_v1 = F.scene_id_v1.nightlight,
				active = "static",
				last_recall = F.scene_last_recall,
				auto_dynamic = false,
				speed = 0.603,
			}, s)
		end)

		it("parses a room scene that was never recalled", function()
			local s = hue_model.scene(scene_items[F.scene_rids.relax])
			assert.equal("Relax", s.name)
			assert.equal(F.group_rids.living_room, s.group_rid)
			assert.equal("room", s.group_type)
			assert.equal("inactive", s.active)
			assert.is_nil(s.last_recall)
			assert.is_false(s.auto_dynamic)
			assert.equal(0.603, s.speed)
		end)

		it("keeps an inactive scene's earlier last_recall and reads auto_dynamic", function()
			local bright = hue_model.scene(scene_items[F.scene_rids.bright])
			assert.equal("inactive", bright.active)
			assert.equal("2026-10-20T07:12:03.110Z", bright.last_recall)
			local savanna = hue_model.scene(scene_items[F.scene_rids.savanna])
			assert.is_true(savanna.auto_dynamic)
			assert.equal(0.6031746, savanna.speed)
			assert.equal("Savanna sunset", savanna.name)
		end)

		it("has exactly the fields of the contract and drops actions, palette and image", function()
			local expected = { rid = 1, name = 1, group_rid = 1, group_type = 1, id_v1 = 1, active = 1,
				last_recall = 1, auto_dynamic = 1, speed = 1 }
			for _, rid in pairs(F.scene_rids) do
				local raw = scene_items[rid]
				assert.is_table(raw.actions, "the fixture does carry actions")
				assert.is_table(raw.palette)
				assert.is_table(raw.metadata.image)
				local s = hue_model.scene(raw)
				for k in pairs(s) do
					assert.truthy(expected[k], "unexpected field " .. k)
				end
				assert.is_nil(s.actions)
				assert.is_nil(s.palette)
				assert.is_nil(s.image)
			end
		end)

		it("parses every scene of the GET body into its group", function()
			local per_group = {}
			for _, raw in ipairs(items(F.scene)) do
				local s = hue_model.scene(raw)
				per_group[s.group_rid] = (per_group[s.group_rid] or 0) + 1
			end
			assert.same({
				[F.group_rids.living_room] = 2,
				[F.group_rids.downstairs] = 2,
				[F.group_rids.garage] = 1,
			}, per_group)
		end)

		it("parses a complete add item from the stream", function()
			local s = hue_model.scene(decode(F.events.scene_added)[1].data[1])
			assert.equal(F.new_scene_rid, s.rid)
			assert.equal("Read", s.name)
			assert.equal(F.new_scene_id_v1, s.id_v1)
			assert.equal(F.group_rids.living_room, s.group_rid)
			assert.equal("room", s.group_type)
			assert.equal("inactive", s.active)
			assert.is_nil(s.last_recall)
			assert.is_false(s.auto_dynamic)
			assert.equal(0.6269841, s.speed)
		end)

		it("is nil for anything that is not a scene", function()
			assert.is_nil(hue_model.scene(light_items[F.rids.living]))
			assert.is_nil(hue_model.scene(by_rid(items(F.room))[F.group_rids.living_room]))
			assert.is_nil(hue_model.scene(items(F.smart_scene)[1]), "a smart_scene")
			assert.is_nil(hue_model.scene(decode(F.events.scene_recalled)[1].data[1]), "a grouped_light")
			assert.is_nil(hue_model.scene({ id = "x", metadata = { name = "Relax" } }), "no type")
			assert.is_nil(hue_model.scene({ type = "scene", metadata = { name = "Relax" } }), "no id")
			assert.is_nil(hue_model.scene("junk"))
			assert.is_nil(hue_model.scene(nil))
		end)

		it("gives a nameless scene a fallback name and ignores an empty id_v1", function()
			assert.equal("Hue scene /scenes/AbCdEfGhIjKlMnOp",
				hue_model.scene({ id = "s", type = "scene", id_v1 = "/scenes/AbCdEfGhIjKlMnOp" }).name)
			local bare = hue_model.scene({ id = "s", type = "scene", id_v1 = "" })
			assert.equal("Hue scene s", bare.name)
			assert.is_nil(bare.id_v1)
			assert.is_nil(bare.group_rid)
			assert.is_nil(bare.active)
			assert.is_false(bare.auto_dynamic)
		end)

		it("treats nulls decoded as empty tables like absent fields", function()
			local s = hue_model.scene({ id = "s", type = "scene", id_v1 = {}, metadata = { name = {}, image = {} },
				group = {}, status = { active = {}, last_recall = {} }, speed = {}, auto_dynamic = {} })
			assert.equal("Hue scene s", s.name)
			assert.is_nil(s.id_v1)
			assert.is_nil(s.group_rid)
			assert.is_nil(s.group_type)
			assert.is_nil(s.active)
			assert.is_nil(s.last_recall)
			assert.is_false(s.auto_dynamic)
			assert.is_nil(s.speed)
			local halves = hue_model.scene({ id = "s", type = "scene", metadata = {}, group = { rtype = "zone" },
				status = {} })
			assert.is_nil(halves.group_rid, "a group without a rid is no group")
			assert.is_nil(halves.group_type)
		end)

		it("keeps the group rid of a scene under an rtype the contract does not name", function()
			local s = hue_model.scene({ id = "s", type = "scene", metadata = { name = "Private" },
				group = { rid = "pg", rtype = "private_group" } })
			assert.equal("pg", s.group_rid)
			assert.is_nil(s.group_type)
			local home = hue_model.scene({ id = "s", type = "scene",
				group = { rid = F.group_rids.home, rtype = "bridge_home" } })
			assert.equal("bridge_home", home.group_type)
		end)
	end)

	describe("update_scene()", function()
		local relax, savanna

		local function scene_in(container)
			for _, item in ipairs(container.data) do
				if item.type == "scene" then
					return item
				end
			end
		end

		before_each(function()
			local scene_items = by_rid(items(F.scene))
			relax = hue_model.scene(scene_items[F.scene_rids.relax])
			savanna = hue_model.scene(scene_items[F.scene_rids.savanna])
		end)

		it("goes static with a last_recall from a recall event that shares its container with grouped_lights", function()
			local container = decode(F.events.scene_recalled)[1]
			assert.equal(4, #container.data)
			local item = scene_in(container)
			assert.equal(F.scene_rids.relax, item.id)
			assert.same({ "active" }, hue_model.update_scene(relax, item))
			assert.equal("static", relax.active)
			assert.equal(F.scene_recall_time, relax.last_recall)
			assert.equal("Relax", relax.name)
			assert.equal(F.group_rids.living_room, relax.group_rid)
			assert.equal("room", relax.group_type)
			assert.equal(0.603, relax.speed)
		end)

		it("goes inactive and keeps the last_recall when a status item carries only active", function()
			hue_model.update_scene(relax, scene_in(decode(F.events.scene_recalled)[1]))
			local item = scene_in(decode(F.events.scene_inactive)[1])
			assert.same({ "active" }, hue_model.update_scene(relax, item))
			assert.equal("inactive", relax.active)
			assert.equal(F.scene_recall_time, relax.last_recall)
		end)

		it("goes dynamic_palette on an auto_dynamic scene's recall", function()
			local item = decode(F.events.scene_dynamic)[1].data[1]
			assert.equal(F.scene_rids.savanna, item.id)
			assert.same({ "active" }, hue_model.update_scene(savanna, item))
			assert.equal("dynamic_palette", savanna.active)
			assert.equal("2026-10-21T18:17:00.219Z", savanna.last_recall)
			assert.is_true(savanna.auto_dynamic)
		end)

		it("renames without touching the status", function()
			local item = decode(F.events.scene_renamed)[1].data[1]
			assert.same({ "name" }, hue_model.update_scene(relax, item))
			assert.equal("Chill", relax.name)
			assert.equal("inactive", relax.active)
			assert.equal(F.scene_id_v1.relax, relax.id_v1)
		end)

		it("moves the scene to another group and follows the group's rtype", function()
			assert.same({ "group_rid" },
				hue_model.update_scene(relax, { group = { rid = F.group_rids.downstairs, rtype = "zone" } }))
			assert.equal(F.group_rids.downstairs, relax.group_rid)
			assert.equal("zone", relax.group_type)
			assert.same({ "group_rid" }, hue_model.update_scene(relax, { group = { rid = "pg", rtype = "private_group" } }))
			assert.is_nil(relax.group_type)
		end)

		it("reports every carried field in a stable order", function()
			local changed = hue_model.update_scene(relax, {
				group = { rid = F.group_rids.garage, rtype = "room" },
				speed = 0.75,
				auto_dynamic = true,
				status = { active = "static", last_recall = "2026-10-21T18:20:00.000Z" },
				metadata = { name = "Evening" },
			})
			assert.same({ "name", "active", "auto_dynamic", "speed", "group_rid" }, changed)
			assert.equal("Evening", relax.name)
			assert.equal("static", relax.active)
			assert.is_true(relax.auto_dynamic)
			assert.equal(0.75, relax.speed)
			assert.equal(F.group_rids.garage, relax.group_rid)
			assert.same({ "auto_dynamic" }, hue_model.update_scene(relax, { auto_dynamic = false }))
			assert.is_false(relax.auto_dynamic)
		end)

		it("reports nothing for an autogrow edit of the actions, junk, or no item", function()
			local before = {}
			for k, v in pairs(relax) do before[k] = v end
			assert.same({}, hue_model.update_scene(relax, {
				id = F.scene_rids.relax, id_v1 = F.scene_id_v1.relax, type = "scene",
				actions = { { target = { rid = F.rids.living, rtype = "light" }, action = { on = { on = true } } } },
				palette = { color = {} },
				last_actions_update = { source = "autogrow" },
			}))
			assert.same({}, hue_model.update_scene(relax, { metadata = { image = { rid = "i", rtype = "public_image" } } }))
			assert.same({}, hue_model.update_scene(relax, { status = { last_recall = "2026-10-21T18:21:00Z" } }),
				"last_recall alone is not a status change")
			assert.equal("2026-10-21T18:21:00Z", relax.last_recall, "but it is kept")
			relax.last_recall = nil
			assert.same({}, hue_model.update_scene(relax, { metadata = "junk", status = 3, group = "g", speed = "0.5",
				auto_dynamic = "true" }))
			assert.same({}, hue_model.update_scene(relax, nil))
			assert.same({}, hue_model.update_scene(relax, "junk"))
			for k, v in pairs(before) do
				assert.equal(v, relax[k], k)
			end
		end)

		it("treats nulls decoded as empty tables like absent fields", function()
			assert.same({}, hue_model.update_scene(relax, { metadata = { name = {} }, status = { active = {} },
				group = { rid = {}, rtype = "room" }, speed = {}, auto_dynamic = {} }))
			assert.equal("Relax", relax.name)
			assert.equal("inactive", relax.active)
			assert.equal(F.group_rids.living_room, relax.group_rid)
			assert.is_false(relax.auto_dynamic)
			assert.equal(0.603, relax.speed)
		end)

		it("never reports id_v1 as changed and leaves a delete item's bare fields alone", function()
			assert.same({}, hue_model.update_scene(relax, { id = F.scene_rids.relax, id_v1 = "/scenes/other", type = "scene" }))
			assert.equal(F.scene_id_v1.relax, relax.id_v1)
			local deleted = decode(F.events.scene_deleted)[1]
			assert.equal("delete", deleted.type)
			assert.same({ id = F.scene_rids.relax, type = "scene" }, deleted.data[1])
			assert.same({}, hue_model.update_scene(relax, deleted.data[1]))
		end)
	end)

	describe("scene_state_params() and scene_configure_params()", function()
		local function assert_all_strings(params)
			for k, v in pairs(params) do
				assert.equal("string", type(v), k .. " must be a string")
			end
		end

		it("carries rid, active and the reason as strings", function()
			local s = hue_model.scene(by_rid(items(F.scene))[F.scene_rids.nightlight])
			local p = hue_model.scene_state_params(s, "resync")
			assert_all_strings(p)
			assert.same({ rid = F.scene_rids.nightlight, active = "static", reason = "resync" }, p)
			assert.same({ rid = F.scene_rids.nightlight, active = "static", reason = "event" },
				hue_model.scene_state_params(s, nil), "the reason defaults to event")
		end)

		it("leaves active out while the status is unknown", function()
			assert.same({ rid = "s", reason = "hello" }, hue_model.scene_state_params({ rid = "s" }, "hello"))
			assert.same({ rid = "s", active = "inactive", reason = "recall" },
				hue_model.scene_state_params({ rid = "s", active = "inactive" }, "recall"))
		end)

		it("builds string-valued HUE_SCENE_CONFIGURE params from a scene", function()
			local s = hue_model.scene(by_rid(items(F.scene))[F.scene_rids.savanna])
			local p = hue_model.scene_configure_params(s)
			assert_all_strings(p)
			assert.same({ rid = F.scene_rids.savanna, name = "Savanna sunset", id_v1 = F.scene_id_v1.savanna,
				auto_dynamic = "true" }, p)
			local relax = hue_model.scene_configure_params(hue_model.scene(by_rid(items(F.scene))[F.scene_rids.relax]))
			assert.equal("false", relax.auto_dynamic)
			assert.equal("Relax", relax.name)
		end)

		it("merges the string fields of extra, skipping nil and empty values", function()
			local s = hue_model.scene(by_rid(items(F.scene))[F.scene_rids.relax])
			local p = hue_model.scene_configure_params(s, { group_name = "Living Room", group_type = "room",
				state = "linked", gone_since = nil })
			assert_all_strings(p)
			assert.same({ rid = F.scene_rids.relax, name = "Relax", id_v1 = F.scene_id_v1.relax, auto_dynamic = "false",
				group_name = "Living Room", group_type = "room", state = "linked" }, p)
			local gone = hue_model.scene_configure_params(s, { group_name = "", state = "gone",
				gone_since = "2026-10-21T18:19:00Z", caps = { nested = true }, [1] = "positional" })
			assert.same({ rid = F.scene_rids.relax, name = "Relax", id_v1 = F.scene_id_v1.relax, auto_dynamic = "false",
				state = "gone", gone_since = "2026-10-21T18:19:00Z" }, gone)
		end)

		it("builds the same params from a registry-shaped record and omits what it lacks", function()
			local p = hue_model.scene_configure_params({ rid = "s", name = "Relax" })
			assert.same({ rid = "s", name = "Relax", auto_dynamic = "false" }, p)
			assert.same({ rid = "s", auto_dynamic = "true" },
				hue_model.scene_configure_params({ rid = "s", id_v1 = "", auto_dynamic = true }, "junk"))
			assert.same(hue_model.scene_configure_params({ rid = "s" }), hue_model.scene_configure_params({ rid = "s" }, {}))
		end)
	end)

	describe("base_name()", function()
		it("drops the number the Hue app gives repeats", function()
			assert.equal("Golden hours", hue_model.base_name("Golden hours 4"))
			assert.equal("Golden hours", hue_model.base_name("Golden hours 11"))
			assert.equal("Natural light", hue_model.base_name("Natural light 6"))
		end)

		it("strips exactly one trailing number", function()
			assert.equal("Scene 2", hue_model.base_name("Scene 2 3"))
			assert.equal("Scene", hue_model.base_name(hue_model.base_name("Scene 2 3")))
		end)

		it("leaves a name without a trailing space and digits as it is", function()
			for _, name in ipairs({ "Natural light", "Golden hours", "Room4", "Golden hours 4a", "Golden hours\t4",
				"Golden hours 4 ", "4", "", "Scene 2 three" }) do
				assert.equal(name, hue_model.base_name(name))
			end
		end)

		it("keeps a name that would be left blank", function()
			assert.equal(" 4", hue_model.base_name(" 4"))
			assert.equal("   12", hue_model.base_name("   12"))
		end)

		it("is nil for anything that is not a string", function()
			assert.is_nil(hue_model.base_name(nil))
			assert.is_nil(hue_model.base_name(4))
			assert.is_nil(hue_model.base_name({}))
			assert.is_nil(hue_model.base_name(true))
		end)
	end)

	-- Every fixture schedule runs every day, in the order the house bridge
	-- lists the days.
	local EVERY_DAY = { "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday" }

	-- A week_timeslots entry for `days`; each slot is { start_time, target rid }.
	local function schedule(days, slots)
		local timeslots = {}
		for i, slot in ipairs(slots) do
			timeslots[i] = { start_time = slot[1], target = { rid = slot[2], rtype = "scene" } }
		end
		return { recurrence = days, timeslots = timeslots }
	end

	-- A start_time of kind "time".
	local function at(hour, minute)
		return { kind = "time", time = { hour = hour, minute = minute, second = 0 } }
	end

	describe("smart_scene()", function()
		local smart_items

		before_each(function()
			smart_items = by_rid(items(F.smart_scenes))
		end)

		it("parses a room's smart scene: names, group, state, slot, slots and transition", function()
			local s = hue_model.smart_scene(decode(F.smart_scene_items.living))
			assert.same({
				rid = F.smart_scene_rids.living,
				name = "Golden hours 4",
				base_name = "Golden hours",
				group_rid = F.group_rids.living_room,
				group_type = "room",
				state = "inactive",
				slot_id = 0,
				slot_weekday = "saturday",
				slots = {
					{ days = EVERY_DAY, start = "07:00", target_rid = F.scene_rids.savanna },
					{ days = EVERY_DAY, start = "16:00", target_rid = F.scene_rids.relax },
				},
				transition_duration = 60000,
			}, s)
			assert.same(s, hue_model.smart_scene(smart_items[F.smart_scene_rids.living]), "the same from the GET body")
		end)

		it("parses every smart scene of the GET body, two of them in one zone", function()
			local seen, per_group = {}, {}
			for _, raw in ipairs(items(F.smart_scenes)) do
				local s = hue_model.smart_scene(raw)
				seen[#seen + 1] = s.name .. " / " .. s.base_name .. " / " .. s.group_type
				per_group[s.group_rid] = (per_group[s.group_rid] or 0) + 1
				assert.equal("inactive", s.state)
				assert.equal(60000, s.transition_duration)
				assert.equal(2, #s.slots)
			end
			assert.same({
				"Golden hours / Golden hours / zone",
				"Natural light 6 / Natural light / zone",
				"Golden hours 4 / Golden hours / room",
			}, seen)
			assert.same({ [F.group_rids.downstairs] = 2, [F.group_rids.living_room] = 1 }, per_group)
		end)

		it("reads a sunset start as sunset, with or without its time block", function()
			local raw = smart_items[F.smart_scene_rids.golden]
			assert.is_table(raw.week_timeslots[1].timeslots[2].start_time.time, "the house bridge sends one")
			local golden = hue_model.smart_scene(raw)
			assert.same({ "07:00", "sunset" }, { golden.slots[1].start, golden.slots[2].start })
			assert.same({ F.scene_rids.bright, F.scene_rids.nightlight },
				{ golden.slots[1].target_rid, golden.slots[2].target_rid })
			local older = items(F.smart_scene)[1]
			assert.is_nil(older.week_timeslots[1].timeslots[2].start_time.time)
			assert.equal("sunset", hue_model.smart_scene(older).slots[2].start)
		end)

		it("writes a time start as zero-padded HH:MM without seconds, slots in their order", function()
			local natural = hue_model.smart_scene(smart_items[F.smart_scene_rids.natural])
			assert.same({ "06:30", "21:00" }, { natural.slots[1].start, natural.slots[2].start })
			local s = hue_model.smart_scene({ id = "ss", type = "smart_scene", week_timeslots = {
				schedule({ "monday" }, {
					{ { kind = "time", time = { hour = 23, minute = 59, second = 30 } }, "a" },
					{ { kind = "time", time = { hour = 0, minute = 5 } }, "b" },
					{ at(9, 0), "c" },
				}),
			} })
			assert.same({ "23:59", "00:05", "09:00" }, { s.slots[1].start, s.slots[2].start, s.slots[3].start })
			assert.same({ "a", "b", "c" }, { s.slots[1].target_rid, s.slots[2].target_rid, s.slots[3].target_rid })
		end)

		it("takes any other start kind as written, sunrise included", function()
			local s = hue_model.smart_scene({ id = "ss", type = "smart_scene", week_timeslots = {
				schedule({ "monday" }, {
					{ { kind = "sunrise", time = { hour = 0, minute = 0, second = 0 } }, "a" },
					{ { kind = "sunset" }, "b" },
					{ { kind = "civil_dusk" }, "c" },
				}),
			} })
			assert.same({ "sunrise", "sunset", "civil_dusk" }, { s.slots[1].start, s.slots[2].start, s.slots[3].start })
		end)

		it("leaves a start unknown without a kind, or without a whole clock in range", function()
			local function start(start_time)
				local s = hue_model.smart_scene({ id = "ss", type = "smart_scene",
					week_timeslots = { schedule({ "monday" }, { { start_time, "a" } }) } })
				assert.equal("a", s.slots[1].target_rid, "the target is read on its own")
				return s.slots[1].start
			end
			assert.equal("07:00", start(at(7, 0)))
			assert.is_nil(start(nil))
			assert.is_nil(start("07:00"))
			assert.is_nil(start({ kind = "" }))
			assert.is_nil(start({ kind = {} }))
			assert.is_nil(start({ time = { hour = 7, minute = 0 } }))
			assert.is_nil(start({ kind = "time" }))
			assert.is_nil(start({ kind = "time", time = "07:00" }))
			assert.is_nil(start({ kind = "time", time = { hour = "7", minute = 0 } }))
			assert.is_nil(start({ kind = "time", time = { hour = 7 } }))
			assert.is_nil(start(at(24, 0)))
			assert.is_nil(start(at(7, 60)))
			assert.is_nil(start(at(7.5, 0)))
			assert.is_nil(start(at(-1, 0)))
		end)

		it("keeps a malformed timeslot's place, so a timeslot_id still names the right slot", function()
			local s = hue_model.smart_scene({ id = "ss", type = "smart_scene",
				active_timeslot = { timeslot_id = 4, weekday = "monday" },
				week_timeslots = { "junk", { recurrence = { "monday" }, timeslots = {
					"junk",
					{},
					{ start_time = "t", target = "x" },
					{ start_time = at(7, 0), target = { rid = {} } },
					{ start_time = at(9, 0), target = { rid = "a", rtype = "scene" } },
				} } } })
			assert.same({
				{ days = { "monday" } },
				{ days = { "monday" } },
				{ days = { "monday" } },
				{ days = { "monday" }, start = "07:00" },
				{ days = { "monday" }, start = "09:00", target_rid = "a" },
			}, s.slots)
			assert.equal(s.slots[5], hue_model.current_slot(s))
		end)

		it("gives each slot its week entry's weekday names, skipping junk days", function()
			local s = hue_model.smart_scene({ id = "ss", type = "smart_scene", week_timeslots = {
				{ recurrence = { "monday", 5, {}, "", "friday" }, timeslots = { { target = { rid = "a" } } } },
				{ recurrence = "junk", timeslots = { { target = { rid = "b" } } } },
				{ recurrence = { "saturday" }, timeslots = "junk" },
				{ recurrence = { "sunday" } },
			} })
			assert.same({ { days = { "monday", "friday" }, target_rid = "a" }, { days = {}, target_rid = "b" } }, s.slots)
		end)

		it("has exactly the fields of the contract and drops the image", function()
			local fields = { rid = 1, name = 1, base_name = 1, group_rid = 1, group_type = 1, state = 1, slot_id = 1,
				slot_weekday = 1, slots = 1, transition_duration = 1 }
			for _, raw in ipairs(items(F.smart_scenes)) do
				assert.is_table(raw.metadata.image, "the fixture does carry an image")
				local s = hue_model.smart_scene(raw)
				for k in pairs(s) do
					assert.truthy(fields[k], "unexpected field " .. k)
				end
				for _, slot in ipairs(s.slots) do
					for k in pairs(slot) do
						assert.truthy(({ days = 1, start = 1, target_rid = 1 })[k], "unexpected slot field " .. k)
					end
				end
			end
		end)

		it("parses a complete add item from the stream, which arrives active", function()
			local container = decode(F.events.smart_added)[1]
			assert.equal("add", container.type)
			local s = hue_model.smart_scene(container.data[1])
			assert.equal(F.smart_scene_rids.added, s.rid)
			assert.equal("Natural light 7", s.name)
			assert.equal("Natural light", s.base_name)
			assert.equal("active", s.state)
			assert.equal(F.group_rids.living_room, s.group_rid)
			assert.equal("room", s.group_type)
			assert.same({ days = EVERY_DAY, start = "07:00", target_rid = F.scene_rids.bright }, hue_model.current_slot(s))
			assert.equal("22:00", s.slots[2].start)
		end)

		it("is nil for anything that is not a smart scene", function()
			local container = decode(F.events.smart_slot_scene)[1]
			assert.equal(2, #container.data)
			for _, item in ipairs(container.data) do
				assert.is_nil(hue_model.smart_scene(item), item.type)
			end
			assert.is_nil(hue_model.smart_scene(items(F.scene)[1]))
			assert.is_nil(hue_model.smart_scene(light_items[F.rids.living]))
			assert.is_nil(hue_model.smart_scene(items(F.zone)[1]))
			assert.is_nil(hue_model.smart_scene({ id = "x", metadata = { name = "Golden hours" } }), "no type")
			assert.is_nil(hue_model.smart_scene({ type = "smart_scene", metadata = { name = "Golden hours" } }), "no id")
			assert.is_nil(hue_model.smart_scene({ id = "", type = "smart_scene" }), "an empty id")
			assert.is_nil(hue_model.smart_scene({ id = {}, type = "smart_scene" }), "a null id")
			assert.is_nil(hue_model.smart_scene({ id = 7, type = "smart_scene" }), "a number")
			assert.is_nil(hue_model.smart_scene("junk"))
			assert.is_nil(hue_model.smart_scene(nil))
		end)

		it("gives a bare item, such as a delete's, a fallback name and an empty slot list", function()
			local deleted = decode(F.events.smart_deleted)[1]
			assert.equal("delete", deleted.type)
			assert.same({ id = F.smart_scene_rids.living, type = "smart_scene" }, deleted.data[1])
			local s = hue_model.smart_scene(deleted.data[1])
			local name = "Hue time-based scene " .. F.smart_scene_rids.living
			assert.same({ rid = F.smart_scene_rids.living, name = name, base_name = name, slots = {} }, s)
			assert.is_nil(hue_model.current_slot(s))
		end)

		it("treats nulls decoded as empty tables, and values of the wrong type, like absent fields", function()
			local bare = hue_model.smart_scene({ id = "ss", type = "smart_scene" })
			assert.same({ rid = "ss", name = "Hue time-based scene ss", base_name = "Hue time-based scene ss",
				slots = {} }, bare)
			assert.same(bare, hue_model.smart_scene({ id = "ss", type = "smart_scene",
				metadata = { name = {}, image = {} }, group = { rid = {}, rtype = "zone" }, state = {},
				active_timeslot = { timeslot_id = {}, weekday = {} }, transition_duration = {}, week_timeslots = {} }))
			assert.same(bare, hue_model.smart_scene({ id = "ss", type = "smart_scene", metadata = "junk", group = "g",
				state = 5, active_timeslot = "t", transition_duration = "60000", week_timeslots = "w" }))
			assert.same(bare, hue_model.smart_scene({ id = "ss", type = "smart_scene", metadata = { name = "" },
				group = { rtype = "zone" }, active_timeslot = { timeslot_id = "1", weekday = 6 } }))
		end)

		it("keeps the state only when it is active or inactive", function()
			local function state(value)
				return hue_model.smart_scene({ id = "ss", type = "smart_scene", state = value }).state
			end
			assert.equal("active", state("active"))
			assert.equal("inactive", state("inactive"))
			assert.is_nil(state("paused"))
			assert.is_nil(state("ACTIVE"))
			assert.is_nil(state(""))
			assert.is_nil(state(true))
		end)

		it("takes a whole timeslot_id from 0 up, and the weekday on its own", function()
			local function slot(timeslot_id)
				return hue_model.smart_scene({ id = "ss", type = "smart_scene",
					active_timeslot = { timeslot_id = timeslot_id, weekday = "monday" } })
			end
			assert.equal(0, slot(0).slot_id)
			assert.equal(4, slot(4).slot_id)
			assert.is_nil(slot(-1).slot_id)
			assert.is_nil(slot(1.5).slot_id)
			assert.is_nil(slot("1").slot_id)
			assert.equal("monday", slot(-1).slot_weekday)
		end)

		it("keeps the group rid under an rtype the contract does not name", function()
			local s = hue_model.smart_scene({ id = "ss", type = "smart_scene",
				group = { rid = "pg", rtype = "private_group" } })
			assert.equal("pg", s.group_rid)
			assert.is_nil(s.group_type)
			assert.equal("bridge_home", hue_model.smart_scene({ id = "ss", type = "smart_scene",
				group = { rid = F.group_rids.home, rtype = "bridge_home" } }).group_type)
		end)
	end)

	describe("current_slot()", function()
		local smart_items

		before_each(function()
			smart_items = by_rid(items(F.smart_scenes))
		end)

		it("finds each fixture's slot: timeslot_id counts from 0", function()
			local living = hue_model.smart_scene(smart_items[F.smart_scene_rids.living])
			assert.same({ days = EVERY_DAY, start = "07:00", target_rid = F.scene_rids.savanna },
				hue_model.current_slot(living))
			local natural = hue_model.smart_scene(smart_items[F.smart_scene_rids.natural])
			assert.equal(1, natural.slot_id)
			assert.same({ days = EVERY_DAY, start = "21:00", target_rid = F.scene_rids.nightlight },
				hue_model.current_slot(natural))
			local older = hue_model.smart_scene(items(F.smart_scene)[1])
			assert.same({ 1, "tuesday" }, { older.slot_id, older.slot_weekday })
			assert.equal("sunset", hue_model.current_slot(older).start)
		end)

		it("returns the model's own slot table", function()
			local living = hue_model.smart_scene(smart_items[F.smart_scene_rids.living])
			assert.equal(living.slots[1], hue_model.current_slot(living))
		end)

		it("counts within the week entry that holds the weekday", function()
			local s = hue_model.smart_scene({ id = "ss", type = "smart_scene", week_timeslots = {
				schedule({ "monday", "tuesday", "wednesday", "thursday", "friday" },
					{ { at(6, 0), "wake" }, { at(9, 0), "work" }, { at(18, 0), "evening" } }),
				schedule({ "saturday", "sunday" }, { { at(8, 0), "lazy" }, { at(20, 0), "night" } }),
			} })
			assert.equal(5, #s.slots)
			local function current(slot_id, weekday)
				s.slot_id, s.slot_weekday = slot_id, weekday
				local slot = hue_model.current_slot(s)
				return slot and slot.target_rid
			end
			assert.equal("wake", current(0, "monday"))
			assert.equal("evening", current(2, "wednesday"))
			assert.equal("lazy", current(0, "saturday"), "not the flat list's first slot")
			assert.equal("night", current(1, "sunday"))
			assert.is_nil(current(2, "saturday"), "past the end of the weekend's slots")
		end)

		it("is nil when the slot or the weekday is unknown, or no week entry holds the weekday", function()
			local living = hue_model.smart_scene(smart_items[F.smart_scene_rids.living])
			living.slot_id = 2
			assert.is_nil(hue_model.current_slot(living), "past the end")
			living.slot_id, living.slot_weekday = 0, "funday"
			assert.is_nil(hue_model.current_slot(living), "a weekday no entry holds")
			living.slot_weekday = nil
			assert.is_nil(hue_model.current_slot(living), "no weekday")
			living.slot_id, living.slot_weekday = nil, "saturday"
			assert.is_nil(hue_model.current_slot(living), "no slot")
			living.slot_id = 0
			assert.is_not_nil(hue_model.current_slot(living))
			living.slots = {}
			assert.is_nil(hue_model.current_slot(living), "no slots")
		end)

		it("is nil for, and never raises on, a model of the wrong shape", function()
			assert.is_nil(hue_model.current_slot(nil))
			assert.is_nil(hue_model.current_slot("junk"))
			assert.is_nil(hue_model.current_slot({}))
			assert.is_nil(hue_model.current_slot({ slot_id = 0, slot_weekday = "monday", slots = "junk" }))
			assert.is_nil(hue_model.current_slot({ slot_id = "0", slot_weekday = "monday",
				slots = { { days = { "monday" } } } }))
			assert.is_nil(hue_model.current_slot({ slot_id = 0, slot_weekday = 5, slots = { { days = { 5 } } } }))
			local slot = { days = { "monday" }, start = "07:00" }
			assert.equal(slot, hue_model.current_slot({ slot_id = 0, slot_weekday = "monday",
				slots = { "junk", { days = "monday" }, { start = "06:00" }, slot } }))
		end)
	end)

	describe("update_smart_scene()", function()
		local living

		-- The changed fields come as a list in field order that also holds the
		-- same names as keys; check both views.
		local function assert_changed(expected, changed)
			assert.is_table(changed)
			local list, set, expected_set = {}, {}, {}
			for key, value in pairs(changed) do
				if type(key) == "number" then
					list[key] = value
				else
					set[key] = value
				end
			end
			for _, name in ipairs(expected) do
				expected_set[name] = true
			end
			assert.same(expected, list)
			assert.same(expected_set, set)
		end

		-- The smart_scene item of a feed container.
		local function smart_in(container)
			for _, item in ipairs(decode(container)[1].data) do
				if item.type == "smart_scene" then
					return item
				end
			end
		end

		local function fresh()
			return hue_model.smart_scene(by_rid(items(F.smart_scenes))[F.smart_scene_rids.living])
		end

		before_each(function()
			living = fresh()
		end)

		it("goes active from the activation event; the slot it reports is the one it had", function()
			assert_changed({ "state" }, hue_model.update_smart_scene(living, smart_in(F.events.smart_activated)))
			assert.equal("active", living.state)
			assert.equal(0, living.slot_id)
			assert.equal("saturday", living.slot_weekday)
			assert.equal("Golden hours 4", living.name)
			assert.equal(2, #living.slots)
		end)

		it("moves to the next time slot while it runs", function()
			hue_model.update_smart_scene(living, smart_in(F.events.smart_activated))
			assert.equal(2, #decode(F.events.smart_next_slot)[1].data, "the slot's scene shares the container")
			assert_changed({ "slot_id" }, hue_model.update_smart_scene(living, smart_in(F.events.smart_next_slot)))
			assert.equal(1, living.slot_id)
			assert.equal("active", living.state)
			assert.same({ days = EVERY_DAY, start = "16:00", target_rid = F.scene_rids.relax },
				hue_model.current_slot(living))
		end)

		it("goes inactive and keeps its slot", function()
			hue_model.update_smart_scene(living, smart_in(F.events.smart_activated))
			assert_changed({ "state" }, hue_model.update_smart_scene(living, smart_in(F.events.smart_inactive)))
			assert.equal("inactive", living.state)
			assert.equal(0, living.slot_id)
			assert.equal(F.scene_rids.savanna, hue_model.current_slot(living).target_rid)
		end)

		it("renames, and the base name follows", function()
			assert_changed({ "name", "base_name" },
				hue_model.update_smart_scene(living, smart_in(F.events.smart_renamed)))
			assert.equal("Evening glow", living.name)
			assert.equal("Evening glow", living.base_name)
			assert.equal("inactive", living.state)
		end)

		it("reports only the name when the app renumbers, and nothing for the same name", function()
			assert_changed({ "name" }, hue_model.update_smart_scene(living, { metadata = { name = "Golden hours 5" } }))
			assert.equal("Golden hours 5", living.name)
			assert.equal("Golden hours", living.base_name)
			assert.is_nil(hue_model.update_smart_scene(living, { metadata = { name = "Golden hours 5" } }))
		end)

		it("replaces the slot list when renamed and re-timed in one item", function()
			local week = schedule(EVERY_DAY, { { at(7, 0), F.scene_rids.savanna }, { at(16, 30), F.scene_rids.relax },
				{ { kind = "sunset" }, F.scene_rids.nightlight } })
			assert_changed({ "name", "base_name", "slots" },
				hue_model.update_smart_scene(living, { metadata = { name = "Evening glow" }, week_timeslots = { week } }))
			assert.same({ "07:00", "16:30", "sunset" },
				{ living.slots[1].start, living.slots[2].start, living.slots[3].start })
			assert.equal(F.scene_rids.nightlight, living.slots[3].target_rid)
			assert.equal(living.slots[1], hue_model.current_slot(living))
			assert_changed({ "slots" }, hue_model.update_smart_scene(living, { week_timeslots = {} }))
			assert.same({}, living.slots, "an empty schedule empties the list")
			assert.is_nil(hue_model.current_slot(living))
		end)

		it("notices a change in any slot's start, target or days, and nothing else", function()
			local function retime(edit)
				local week_timeslots = decode(F.smart_scene_items.living).week_timeslots
				edit(week_timeslots[1])
				return hue_model.update_smart_scene(fresh(), { week_timeslots = week_timeslots })
			end
			assert.is_nil(retime(function() end), "the same timeslots again")
			assert_changed({ "slots" }, retime(function(week) week.timeslots[2].start_time.time.minute = 15 end))
			assert_changed({ "slots" }, retime(function(week) week.timeslots[2].start_time = { kind = "sunset" } end))
			assert_changed({ "slots" }, retime(function(week) week.timeslots[1].target.rid = F.scene_rids.bright end))
			assert_changed({ "slots" }, retime(function(week) week.recurrence[7] = nil end))
			assert_changed({ "slots" }, retime(function(week) week.timeslots[3] = week.timeslots[1] end))
		end)

		it("reports every changed field in a stable order, with the same names as keys", function()
			local changed = hue_model.update_smart_scene(living, {
				group = { rid = F.group_rids.downstairs, rtype = "zone" },
				transition_duration = 30000,
				week_timeslots = {
					schedule({ "sunday" }, { { at(5, 0), F.scene_rids.bright }, { at(20, 0), F.scene_rids.nightlight } }),
				},
				active_timeslot = { timeslot_id = 1, weekday = "sunday" },
				state = "active",
				metadata = { name = "Nightfall 2" },
			})
			assert_changed({ "name", "base_name", "state", "slot_id", "slot_weekday", "slots", "transition_duration",
				"group_rid", "group_type" }, changed)
			assert.same({ "Nightfall 2", "Nightfall", "active", 1, "sunday", 30000, F.group_rids.downstairs, "zone" },
				{ living.name, living.base_name, living.state, living.slot_id, living.slot_weekday,
					living.transition_duration, living.group_rid, living.group_type })
			assert.same({ days = { "sunday" }, start = "20:00", target_rid = F.scene_rids.nightlight },
				hue_model.current_slot(living))
		end)

		it("returns nil when nothing changed: the same values again, an image, a delete item, no item", function()
			assert.is_nil(hue_model.update_smart_scene(living, decode(F.smart_scene_items.living)), "the whole item")
			assert.is_nil(hue_model.update_smart_scene(living, { state = "inactive" }))
			assert.is_nil(hue_model.update_smart_scene(living,
				{ active_timeslot = { timeslot_id = 0, weekday = "saturday" } }))
			assert.is_nil(hue_model.update_smart_scene(living, { transition_duration = 60000 }))
			assert.is_nil(hue_model.update_smart_scene(living,
				{ group = { rid = F.group_rids.living_room, rtype = "room" } }))
			assert.is_nil(hue_model.update_smart_scene(living,
				{ metadata = { image = { rid = "i", rtype = "public_image" } } }))
			assert.is_nil(hue_model.update_smart_scene(living, decode(F.events.smart_deleted)[1].data[1]))
			assert.is_nil(hue_model.update_smart_scene(living, {}))
			assert.is_nil(hue_model.update_smart_scene(living, nil))
			assert.is_nil(hue_model.update_smart_scene(living, "junk"))
			assert.same(fresh(), living)
		end)

		it("ignores values of the wrong type, nulls decoded as empty tables included", function()
			assert.is_nil(hue_model.update_smart_scene(living, { metadata = { name = {} }, state = {},
				active_timeslot = { timeslot_id = {}, weekday = {} }, transition_duration = {},
				group = { rid = {}, rtype = "zone" } }))
			assert.is_nil(hue_model.update_smart_scene(living, { metadata = "junk", state = 5, active_timeslot = "t",
				transition_duration = "1000", week_timeslots = "w", group = "g" }))
			assert.is_nil(hue_model.update_smart_scene(living, { metadata = { name = "" },
				active_timeslot = { timeslot_id = -1, weekday = "" } }))
			assert.same(fresh(), living)
		end)

		it("takes either leaf of active_timeslot on its own", function()
			assert_changed({ "slot_id" }, hue_model.update_smart_scene(living, { active_timeslot = { timeslot_id = 1 } }))
			assert.equal("saturday", living.slot_weekday)
			assert_changed({ "slot_weekday" },
				hue_model.update_smart_scene(living, { active_timeslot = { weekday = "sunday" } }))
			assert.equal(1, living.slot_id)
		end)

		it("drops a state string it does not know to nil", function()
			hue_model.update_smart_scene(living, { state = "active" })
			assert_changed({ "state" }, hue_model.update_smart_scene(living, { state = "paused" }))
			assert.is_nil(living.state)
			assert.is_nil(hue_model.update_smart_scene(living, { state = "paused" }), "still unknown: no change")
			assert_changed({ "state" }, hue_model.update_smart_scene(living, { state = "inactive" }))
			assert.equal("inactive", living.state)
		end)

		it("moves to another group and follows its rtype", function()
			assert_changed({ "group_rid", "group_type" },
				hue_model.update_smart_scene(living, { group = { rid = F.group_rids.downstairs, rtype = "zone" } }))
			assert.equal(F.group_rids.downstairs, living.group_rid)
			assert.equal("zone", living.group_type)
			assert_changed({ "group_type" }, hue_model.update_smart_scene(living,
				{ group = { rid = F.group_rids.downstairs, rtype = "private_group" } }))
			assert.is_nil(living.group_type)
		end)

		it("leaves a model that is not a table alone and fills a hand-made one", function()
			assert.is_nil(hue_model.update_smart_scene(nil, { state = "active" }))
			assert.is_nil(hue_model.update_smart_scene("junk", { state = "active" }))
			local bare = { rid = "ss" }
			assert.is_nil(hue_model.update_smart_scene(bare, { id = "ss", type = "smart_scene" }), "no slots either side")
			assert_changed({ "state" }, hue_model.update_smart_scene(bare, { state = "active" }))
			local named = { rid = "ss", name = "Golden hours 4" }
			assert_changed({ "base_name" }, hue_model.update_smart_scene(named, { metadata = { name = "Golden hours 4" } }))
			assert.equal("Golden hours", named.base_name)
			local odd = { rid = "ss", slots = "junk" }
			assert_changed({ "slots" }, hue_model.update_smart_scene(odd, { week_timeslots = {} }))
			assert.same({}, odd.slots)
		end)
	end)

	describe("smart_scene_count()", function()
		it("counts the smart_scene items of a GET body", function()
			assert.equal(1, hue_model.smart_scene_count(items(F.smart_scene)))
			assert.equal(3, hue_model.smart_scene_count(items(F.smart_scenes)))
			assert.equal(0, hue_model.smart_scene_count(items(F.scene)))
		end)

		it("counts only smart scenes in a mixed list and tolerates junk", function()
			local mixed = items(F.scene)
			mixed[#mixed + 1] = items(F.smart_scene)[1]
			mixed[#mixed + 1] = { id = "x", type = "smart_scene" }
			mixed[#mixed + 1] = "junk"
			mixed[#mixed + 1] = { type = "scene" }
			assert.equal(2, hue_model.smart_scene_count(mixed))
			assert.equal(0, hue_model.smart_scene_count({}))
			assert.equal(0, hue_model.smart_scene_count(nil))
			assert.equal(0, hue_model.smart_scene_count("junk"))
		end)
	end)

	-- docs/zone-light-design.md: grouped lights and the group derivations.
	describe("grouped_light() and update_grouped_light()", function()
		it("normalises a GET item: rid, owner, on and the average brightness, nothing else", function()
			local by = by_rid(items(F.grouped_light))
			local g = hue_model.grouped_light(by[F.grouped_light_rids.downstairs])
			assert.same({ rid = F.grouped_light_rids.downstairs, owner_rid = F.group_rids.downstairs, owner_type = "zone",
				on = true, brightness = 73.52 }, g)
			local garage = hue_model.grouped_light(by[F.grouped_light_rids.garage])
			assert.is_false(garage.on)
			assert.equal(100, garage.brightness)
			assert.equal("room", garage.owner_type)
			assert.equal("bridge_home", hue_model.grouped_light(by[F.grouped_light_rids.home]).owner_type)
			assert.equal(4, #items(F.grouped_light), "the empty zone has no grouped_light")
		end)

		it("takes a stream item without an owner, and refuses junk and other types", function()
			local event = decode(F.events.zone_level)[1].data[1]
			local g = hue_model.grouped_light({ id = event.id, type = "grouped_light", dimming = event.dimming })
			assert.same({ rid = F.grouped_light_rids.downstairs, brightness = 40 }, g)
			assert.is_nil(hue_model.grouped_light(nil))
			assert.is_nil(hue_model.grouped_light("junk"))
			assert.is_nil(hue_model.grouped_light({ type = "grouped_light" }))
			assert.is_nil(hue_model.grouped_light({ id = "", type = "grouped_light" }))
			assert.is_nil(hue_model.grouped_light(decode(F.events.brightness)[1].data[1]), "a light item")
			assert.same({ rid = "bare" }, hue_model.grouped_light({ id = "bare" }), "no type: taken as one")
		end)

		it("merges on and brightness as carried, reporting them in a stable order", function()
			local g = hue_model.grouped_light(by_rid(items(F.grouped_light))[F.grouped_light_rids.downstairs])
			assert.same({ "on" }, hue_model.update_grouped_light(g, decode(F.events.zone_off)[1].data[1]))
			assert.is_false(g.on)
			assert.equal(73.52, g.brightness)
			assert.same({ "brightness" }, hue_model.update_grouped_light(g, decode(F.events.zone_level)[1].data[1]))
			assert.equal(40, g.brightness)
			assert.same({ "on", "brightness" }, hue_model.update_grouped_light(g, decode(F.events.zone_on)[1].data[1]))
			assert.is_true(g.on)
			assert.equal(73.52, g.brightness)
			assert.same({ "on", "brightness" }, hue_model.update_grouped_light(g, decode(F.events.zone_on)[1].data[1]),
				"carried counts as changed, value or no value")
		end)

		it("ignores nulls, junk and an owner change is taken but not reported", function()
			local g = hue_model.grouped_light({ id = "g", type = "grouped_light" })
			assert.same({}, hue_model.update_grouped_light(g, { on = { on = {} }, dimming = { brightness = {} } }))
			assert.same({}, hue_model.update_grouped_light(g, { on = "yes", dimming = 7 }))
			assert.same({}, hue_model.update_grouped_light(g, nil))
			assert.same({}, hue_model.update_grouped_light(nil, { on = { on = true } }))
			assert.is_nil(g.on)
			assert.same({}, hue_model.update_grouped_light(g, { owner = { rid = "z", rtype = "zone" } }))
			assert.equal("z", g.owner_rid)
			assert.equal("zone", g.owner_type)
		end)
	end)

	describe("group_caps()", function()
		local lights

		before_each(function()
			lights = {}
			for key, rid in pairs(F.rids) do
				lights[key] = hue_model.light(light_items[rid])
			end
		end)

		it("takes the union of the flags and the intersection of the CT ranges, min_dim 1", function()
			assert.same({ has_color = true, has_cct = true, mirek_min = 153, mirek_max = 454, min_dim = 1 },
				hue_model.group_caps({ lights.hallway, lights.living }), "Living Room: 153-454 within 153-500")
			assert.same({ has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 1 },
				hue_model.group_caps({ lights.garage, lights.living }), "Downstairs: the white lamp adds nothing")
			assert.same({ has_color = false, has_cct = false, min_dim = 1 }, hue_model.group_caps({ lights.garage }))
			assert.same({ has_color = false, has_cct = true, mirek_min = 153, mirek_max = 454, min_dim = 1 },
				hue_model.group_caps({ lights.hallway }))
		end)

		it("falls back to the first ranged member's range when the intersection is empty", function()
			local warm = { has_cct = true, mirek_min = 400, mirek_max = 500 }
			local cool = { has_cct = true, mirek_min = 153, mirek_max = 300 }
			assert.same({ has_color = false, has_cct = true, mirek_min = 400, mirek_max = 500, min_dim = 1 },
				hue_model.group_caps({ warm, cool }))
			assert.same({ has_color = false, has_cct = true, mirek_min = 153, mirek_max = 300, min_dim = 1 },
				hue_model.group_caps({ cool, warm }))
			assert.same({ has_color = false, has_cct = true, mirek_min = 200, mirek_max = 300, min_dim = 1 },
				hue_model.group_caps({ { has_cct = true, mirek_min = 200, mirek_max = 454 }, cool }))
		end)

		it("leaves the bounds out when no CT member has a range, and tolerates junk", function()
			assert.same({ has_color = false, has_cct = true, min_dim = 1 }, hue_model.group_caps({ { has_cct = true } }))
			assert.same({ has_color = false, has_cct = true, mirek_min = 153, mirek_max = 454, min_dim = 1 },
				hue_model.group_caps({ { has_cct = true, mirek_min = "153" }, lights.hallway }), "a half range is no range")
			assert.same({ has_color = false, has_cct = false, min_dim = 1 }, hue_model.group_caps({}))
			assert.same({ has_color = false, has_cct = false, min_dim = 1 }, hue_model.group_caps(nil))
			assert.same({ has_color = false, has_cct = false, min_dim = 1 }, hue_model.group_caps({ "junk", 7 }))
		end)

		it("feeds registry_configure_params() like a light's caps", function()
			local p = hue_model.registry_configure_params("z", { device_id = 1, name = "Downstairs",
				caps = hue_model.group_caps({ lights.garage, lights.living }) })
			assert.same({ rid = "z", name = "Downstairs", has_color = "true", has_cct = "true", mirek_min = "153",
				mirek_max = "500", min_dim = "1" }, p)
		end)
	end)

	describe("group_color()", function()
		local lights

		before_each(function()
			lights = {}
			for key, rid in pairs(F.rids) do
				lights[key] = hue_model.light(light_items[rid])
			end
		end)

		it("shows the first lit member's mirek when no lit member sits in xy mode", function()
			assert.same({ mirek = 250, color_mode = "ct" }, hue_model.group_color({ lights.hallway, lights.living }),
				"Living Room: Hallway Ambiance first in the room's order")
			assert.same({ mirek = 366, color_mode = "ct" }, hue_model.group_color({ lights.garage, lights.living }),
				"Downstairs: the white lamp is off and has no colour anyway")
			assert.same({ mirek = 366, color_mode = "ct" }, hue_model.group_color({ lights.living, lights.hallway }))
		end)

		it("prefers a lit colour-capable member in xy mode, wherever it stands", function()
			assert.same({ x = 0.2731, y = 0.1192, color_mode = "xy" },
				hue_model.group_color({ lights.hallway, lights.kitchen }), "the Kitchen Strip sits at a colour")
			hue_model.update(lights.living, decode(F.events.color)[1].data[1])
			assert.same({ x = 0.1532, y = 0.0475, color_mode = "xy" }, hue_model.group_color({ lights.hallway, lights.living }))
			assert.same({ x = 0.1532, y = 0.0475, color_mode = "xy" }, hue_model.group_color({ lights.living, lights.kitchen }),
				"the first xy member wins")
		end)

		it("is nil while no member is lit, or no lit member shows a colour", function()
			assert.is_nil(hue_model.group_color({ lights.garage }))
			lights.living.on = false
			assert.is_nil(hue_model.group_color({ lights.garage, lights.living }))
			lights.garage.on = true
			assert.is_nil(hue_model.group_color({ lights.garage, lights.living }), "a lit white lamp has no colour")
			assert.is_nil(hue_model.group_color({}))
			assert.is_nil(hue_model.group_color(nil))
			assert.is_nil(hue_model.group_color({ "junk" }))
		end)

		it("skips a lit member whose mirek is invalid and has no xy", function()
			local odd = { on = true, has_cct = true, mirek_valid = false, mirek = nil }
			assert.is_nil(hue_model.group_color({ odd }))
			assert.same({ mirek = 250, color_mode = "ct" }, hue_model.group_color({ odd, lights.hallway }))
		end)
	end)

	describe("group_label() and group_configure_params()", function()
		it("labels a zone with its type, a room by name, the bridge_home and no name specially", function()
			assert.equal("Bedside Lights (zone)", hue_model.group_label("Bedside Lights", "zone"))
			assert.equal("Master Bedroom", hue_model.group_label("Master Bedroom", "room"))
			assert.equal("(all lights)", hue_model.group_label(nil, "bridge_home"))
			assert.equal("(no room)", hue_model.group_label(nil, "zone"))
			assert.equal("(no room)", hue_model.group_label("", "room"))
			assert.equal("Odd", hue_model.group_label("Odd", nil))
		end)

		it("builds the string-valued HUE_CONFIGURE params of a zone from a registry entry", function()
			local p = hue_model.group_configure_params(F.group_rids.downstairs, {
				device_id = 2001, name = "Downstairs", group_type = "zone", light_count = 2, no_lights = false,
				caps = { has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 1 },
				id_v1 = "/groups/3", state = "linked",
			})
			for k, v in pairs(p) do
				assert.equal("string", type(v), k)
			end
			assert.same({ rid = F.group_rids.downstairs, name = "Downstairs", kind = "group", group_type = "zone",
				model = "Hue zone", light_count = "2", no_lights = "false", hue_room = "Downstairs (zone)", id_v1 = "/groups/3",
				has_color = "true", has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }, p)
		end)

		it("builds a room's, with no_lights true, persisted strings normalised and the extra fields merged", function()
			local p = hue_model.group_configure_params("r", {
				device_id = 2002, name = "Garage", group_type = "room", light_count = "0", no_lights = "true",
				caps = { has_color = "false", has_cct = "false", min_dim = "1" },
			}, { state = "gone", gone_since = 1761000000, hue_room = "ignored: the label is the group's own" })
			assert.same({ rid = "r", name = "Garage", kind = "group", group_type = "room", model = "Hue room",
				light_count = "0", no_lights = "true", hue_room = "ignored: the label is the group's own",
				has_color = "false", has_cct = "false", min_dim = "1", state = "gone", gone_since = "1761000000" }, p)
		end)

		it("leaves out what the entry lacks: an adopted entry whose group is not on the bridge", function()
			local p = hue_model.group_configure_params("z", { device_id = 3, name = "Old Zone" })
			assert.same({ rid = "z", name = "Old Zone", kind = "group", no_lights = "false", hue_room = "Old Zone",
				has_color = "false", has_cct = "false", min_dim = "1" }, p)
			assert.same({ rid = "z", kind = "group", no_lights = "false", has_color = "false", has_cct = "false",
				min_dim = "1" }, hue_model.group_configure_params("z", nil))
		end)
	end)
end)
