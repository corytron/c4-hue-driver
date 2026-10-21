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
			local expected = { rid = 1, device_rid = 1, name = 1, archetype = 1, on = 1, brightness = 1, min_dim = 1,
				has_color = 1, x = 1, y = 1, gamut = 1, has_cct = 1, mirek = 1, mirek_valid = 1, mirek_min = 1,
				mirek_max = 1, color_mode = 1 }
			for k in pairs(l) do
				assert.truthy(expected[k], "unexpected field " .. k)
			end
		end)

		it("gives a nameless light a fallback name", function()
			local l = hue_model.light({ id = "x", id_v1 = "/lights/9", on = { on = true } })
			assert.equal("Hue light /lights/9", l.name)
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
	end)
end)
