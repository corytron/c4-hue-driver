-- bridge/motion_model.lua (docs/motion-design.md §4.1): the pure parsing of
-- the motion feature. The fixtures are docs/motion-hue-research.md §5
-- (tests/fixtures/hue_motion.lua); the rows named are those of
-- docs/edge-cases-motion.md.

local json = require("dkjson")
local log = require("common.log")
local M = require("fixtures.hue_motion")

local function data(text)
	return json.decode(text).data
end

local function first(text)
	return data(text)[1]
end

-- The first item of an event fixture's first container.
local function event_item(key, n)
	return json.decode(M.events[key])[1].data[n or 1]
end

-- Plain-text replacement: ids and times contain pattern characters.
local function replace(text, from, to)
	local escaped = from:gsub("%W", "%%%0")
	local out, n = text:gsub(escaped, (to:gsub("%%", "%%%%")))
	assert(n > 0, "fixture text not found: " .. from)
	return out
end

describe("bridge.motion_model", function()
	local model, hue_model, groups

	-- The sensor services of the fixture's GETs, by type.
	local function sensor_services(overrides)
		local out = {}
		for _, rtype in ipairs({ "motion", "light_level", "temperature", "device_power", "zigbee_connectivity" }) do
			out[rtype] = data(M.get[rtype])
		end
		for k, v in pairs(overrides or {}) do
			out[k] = v
		end
		return out
	end

	local function area_services()
		return { convenience_area_motion = data(M.convenience_area_motion),
			security_area_motion = data(M.security_area_motion) }
	end

	local function group_cache()
		local cache = groups.new()
		local items = data(M.room)
		for _, item in ipairs(data(M.bridge_home)) do
			items[#items + 1] = item
		end
		cache:absorb(items)
		return cache
	end

	before_each(function()
		log.sink = function() end
		for _, m in ipairs({ "bridge.motion_model", "bridge.hue_model", "bridge.groups" }) do
			package.loaded[m] = nil
		end
		model = require("bridge.motion_model")
		hue_model = require("bridge.hue_model")
		groups = require("bridge.groups")
	end)

	describe("time_of and newer (EC rule 5: the bridge's clock orders readings)", function()
		it("reads a bridge time as UTC seconds, with or without milliseconds and offsets", function()
			assert.equal(0, model.time_of("1970-01-01T00:00:00Z"))
			-- The SSE id of HR's E1 is the Unix second of its motion report.
			assert.equal(1792998902, math.floor(model.time_of(M.changed.e1)))
			assert.near(1792998902.087, model.time_of(M.changed.e1), 1e-6)
			assert.equal(model.time_of("2026-10-26T07:15:02Z"), model.time_of("2026-10-26T09:15:02+02:00"))
			assert.equal(model.time_of("2026-10-26T07:15:02Z"), model.time_of("2026-10-26T07:15:02"))
			assert.equal(model.time_of("2024-03-01T00:00:00Z") - 86400, model.time_of("2024-02-29T00:00:00Z"), "a leap day")
		end)

		it("answers nil for anything that is not one", function()
			for _, junk in ipairs({ "", "yesterday", "2026-13-01T00:00:00Z", "2026-10-26 07:15:02Z", "2026-10-26T07:15:02X",
				string.rep("2", 50) }) do
				assert.is_nil(model.time_of(junk), junk)
			end
			assert.is_nil(model.time_of(nil))
			assert.is_nil(model.time_of(1792998902))
			assert.is_nil(model.time_of({}))
		end)

		it("orders two times, false when either is unknown", function()
			assert.is_true(model.newer(M.changed.e2, M.changed.e1))
			assert.is_false(model.newer(M.changed.e1, M.changed.e2))
			assert.is_false(model.newer(M.changed.e1, M.changed.e1))
			assert.is_false(model.newer(nil, M.changed.e1))
			assert.is_false(model.newer(M.changed.e1, "junk"))
		end)
	end)

	describe("lux (HR §1.4)", function()
		it("turns 10000·log10(lux)+1 into whole lux, 0 into dark", function()
			assert.equal(0, model.lux(0))
			assert.equal(1, model.lux(1))
			assert.equal(6, model.lux(7728))
			assert.equal(10, model.lux(10001))
			assert.equal(63, model.lux(18027))
			assert.equal(126, model.lux(21000))
			assert.equal(1000, model.lux(30001))
			assert.equal(1770, model.lux(32480))
		end)

		it("refuses junk", function()
			assert.is_nil(model.lux(-1))
			assert.is_nil(model.lux("18027"))
			assert.is_nil(model.lux(0 / 0))
			assert.is_nil(model.lux(math.huge))
			assert.is_nil(model.lux(90000), "a million lux and more is not a reading")
		end)
	end)

	describe("reading", function()
		it("reads a motion item: motion_report first, its time, motion_valid and enabled", function()
			assert.same({ motion = false, changed = M.changed.hallway_motion, valid = true, enabled = true },
				model.reading(first(M.motion_body)))
			assert.same({ motion = true, changed = M.changed.e1, valid = true }, model.reading(event_item("e1")))
		end)

		it("S10: falls back to the deprecated value only when the report is missing (HR §1.3)", function()
			local item = { type = "motion", motion = { motion = true, motion_valid = true } }
			assert.same({ motion = true, valid = true }, model.reading(item))
			item.motion.motion_report = { changed = M.changed.e2, motion = false }
			assert.same({ motion = false, changed = M.changed.e2, valid = true }, model.reading(item),
				"the report wins over the deprecated field")
		end)

		it("leaves out what a partial item does not carry (HR §3.1)", function()
			assert.same({ enabled = false }, model.reading(event_item("e6")), "E6: switched off, no motion block")
			assert.same({}, model.reading(event_item("e7_raised")), "E7: a sensitivity change carries no reading")
			assert.same({}, model.reading({ type = "motion", motion = {} }), "S13 and HR §1.3: an empty motion block")
			assert.same({}, model.reading({ type = "motion", motion = "junk", enabled = "yes" }))
		end)

		it("reads light level, temperature, battery, connectivity and an area's health", function()
			assert.same({ lux = 63, changed = "2026-10-26T07:11:58.002Z", valid = true, enabled = true },
				model.reading(first(M.light_level_body)))
			assert.same({ lux = 126, changed = "2026-10-26T07:16:39.877Z", valid = true }, model.reading(event_item("e3")))
			assert.same({ lux = 0, valid = false }, model.reading({ type = "light_level", light = { light_level = 0,
				light_level_valid = false } }), "the deprecated field, 0 for dark")
			assert.same({ temperature = 21.37, changed = "2026-10-26T07:08:20.551Z", valid = true, enabled = true },
				model.reading(first(M.temperature_body)))
			assert.same({ temperature = 14.88, changed = "2026-10-26T07:18:04.610Z", valid = true },
				model.reading(event_item("e4")))
			assert.same({ battery_level = 87, battery_state = "normal" }, model.reading(first(M.device_power_body)))
			assert.same({ battery_level = 9, battery_state = "low" }, model.reading(event_item("e12")))
			assert.same({}, model.reading({ type = "device_power", power_state = { battery_level = 140,
				battery_state = "empty" } }), "out of range and an undocumented state are not passed on")
			assert.same({ status = "connected" }, model.reading(first(M.zigbee_connectivity)))
			assert.same({ status = "connectivity_issue" }, model.reading(event_item("e5")))
			assert.same({ enabled = true, health = "healthy" }, model.reading(first(M.motion_area_configuration)))
			assert.same({ health = "degraded" }, model.reading(event_item("e9_degraded")))
			assert.same({ motion = true, changed = M.changed.e8_motion, valid = true },
				model.reading(event_item("e8_motion")))
		end)

		it("answers nil for any other type or no table", function()
			assert.is_nil(model.reading({ type = "grouped_motion", motion = { motion_report = { motion = true } } }))
			assert.is_nil(model.reading({ type = "light" }))
			assert.is_nil(model.reading(nil))
			assert.is_nil(model.reading("motion"))
		end)
	end)

	describe("merge (EC rule 5, R6)", function()
		local function reading(motion, changed, extra)
			local r = { motion = motion, changed = changed }
			for k, v in pairs(extra or {}) do
				r[k] = v
			end
			return r
		end

		it("takes a newer reading and reports what changed", function()
			local held = {}
			assert.same({ "motion", "changed", "enabled" },
				model.merge(held, reading(false, M.changed.e1, { enabled = true }), { get = 0 }))
			assert.same({ "motion", "changed" }, model.merge(held, reading(true, M.changed.e2), { event = 1 }))
			assert.is_true(held.motion)
			assert.same({}, model.merge(held, reading(true, M.changed.e2), { event = 2 }), "the same reading again")
		end)

		it("R6: a GET answered with an older reading than an event already applied keeps the event's", function()
			local held = {}
			model.merge(held, reading(true, M.changed.e2), { event = 5 })
			assert.same({}, model.merge(held, reading(false, M.changed.e1, { valid = true }), { get = 9 }))
			assert.is_true(held.motion)
			assert.equal(M.changed.e2, held.changed)
		end)

		it("R6 without times (old firmware): an event after the GET was sent beats the GET, an earlier one does not",
			function()
			local held = {}
			model.merge(held, { motion = true }, { event = 5 })
			assert.same({}, model.merge(held, { motion = false }, { get = 4 }), "sent before event 5")
			assert.is_true(held.motion)
			assert.same({ "motion" }, model.merge(held, { motion = false }, { get = 5 }), "sent after it")
			assert.is_false(held.motion)
		end)

		it("keeps the other fields an event set after the GET was sent", function()
			local held = {}
			model.merge(held, { enabled = false }, { event = 3 })
			assert.same({ "health" }, model.merge(held, { enabled = true, health = "healthy" }, { get = 2 }))
			assert.is_false(held.enabled)
			assert.equal("healthy", held.health)
			model.merge(held, { enabled = true }, { get = 3 })
			assert.is_true(held.enabled)
		end)

		it("ignores what is not two tables", function()
			assert.same({}, model.merge(nil, {}, {}))
			assert.same({}, model.merge({}, nil, {}))
		end)
	end)

	describe("sensors (§4.1)", function()
		it("finds every device owning a motion service, its services by owner whatever their order", function()
			local devices = hue_model.devices(data(M.device))
			local sensors = model.sensors(devices, sensor_services(), group_cache())
			local rids = {}
			for rid in pairs(sensors) do
				rids[#rids + 1] = rid
			end
			table.sort(rids)
			assert.same({ M.devices.hallway, M.devices.porch }, rids, "the lamp and the kitchen lights are no sensors")
			assert.same({
				rid = M.devices.hallway, kind = "sensor", name = "Hallway sensor", model_id = "SML003",
				product_name = "Hue motion sensor", id_v1 = "/sensors/12", room = M.rooms.hallway, room_name = "Hallway",
				motion = M.motion.hallway, light_level = M.light_level.hallway, temperature = M.temperature.hallway,
				device_power = M.device_power.hallway, zigbee = M.zigbee.hallway,
			}, sensors[M.devices.hallway])
			local porch = sensors[M.devices.porch]
			assert.equal("SML002", porch.model_id)
			assert.equal("Hue outdoor motion sensor", porch.product_name)
			assert.equal("/sensors/20", porch.id_v1)
			assert.is_nil(porch.room, "S1: a sensor in no Hue room (the bridge_home lists it)")
			assert.equal(M.zigbee.porch, porch.zigbee)
		end)

		it("S13: a device of any make with a motion service, its missing services nil", function()
			local devices = { ["0f000000-0000-4000-8000-000000000001"] = { name = "Garden PIR", model = "PIR-9",
				model_id = "PIR-9", light_rids = {} } }
			local services = { motion = { { id = "0a000000-0000-4000-8000-000000000001", type = "motion",
				owner = { rid = "0f000000-0000-4000-8000-000000000001", rtype = "device" } } } }
			local record = model.sensors(devices, services)["0f000000-0000-4000-8000-000000000001"]
			assert.equal("0a000000-0000-4000-8000-000000000001", record.motion)
			assert.is_nil(record.light_level)
			assert.is_nil(record.temperature)
			assert.is_nil(record.device_power)
			assert.is_nil(record.zigbee)
			assert.is_nil(record.product_name, "the model string is the bare model id")
			assert.is_nil(record.room, "no group cache given")
		end)

		it("makes no record for a motion service whose device the cache does not hold yet (HR §3.5)", function()
			local devices = hue_model.devices(data(M.device))
			devices[M.devices.porch] = nil
			assert.is_nil(model.sensors(devices, sensor_services())[M.devices.porch])
		end)

		it("S14: sensor() gives a device without its motion service a record without one", function()
			local devices = hue_model.devices(data(M.device))
			local record = model.sensor(M.devices.hallway, devices[M.devices.hallway], nil, group_cache())
			assert.equal("Hallway sensor", record.name)
			assert.is_nil(record.motion)
			assert.equal(M.zigbee.hallway, record.zigbee, "the device record's own zigbee service")
			assert.equal("Hallway", record.room_name)
		end)

		it("keeps the first service of a kind per owner and drops items without an owner or a resource id", function()
			local services = sensor_services({ motion = {
				{ id = M.motion.hallway, owner = { rid = M.devices.hallway }, id_v1 = "/sensors/12" },
				{ id = "a0000000-0000-4000-8000-0000000000ff", owner = { rid = M.devices.hallway } },
				{ id = "../../bridge", owner = { rid = M.devices.porch } },
				{ id = M.motion.porch },
			} })
			local owned = model.owned(services)
			assert.equal(M.motion.hallway, owned[M.devices.hallway].motion)
			assert.equal("/sensors/12", owned[M.devices.hallway].id_v1)
			assert.is_nil(owned[M.devices.porch].motion)
		end)
	end)

	describe("areas (§4.1)", function()
		it("reads a configuration: name, group, enabled, health, participants, its two services", function()
			local areas = model.areas(data(M.motion_area_configuration), area_services())
			assert.same({
				rid = M.area, kind = "area", name = "Kitchen motion area", group = { rid = M.rooms.kitchen, rtype = "room" },
				enabled = true, health = "healthy", participants = 3, unhealthy = 0, convenience = M.convenience,
				security = M.security, partial = false,
			}, areas[M.area])
		end)

		it("counts the participants a light failed (A5)", function()
			local item = first(M.motion_area_configuration)
			item.participants = event_item("e9_degraded").participants
			item.health = "degraded"
			local record = model.area(item, {})
			assert.equal(3, record.participants)
			assert.equal(1, record.unhealthy)
		end)

		it("A16: tolerates a configuration served in part, its services found by their owner", function()
			local record = model.areas(data(M.motion_area_configuration_partial), area_services())[M.area]
			assert.is_true(record.partial)
			assert.is_nil(record.name)
			assert.is_nil(record.group)
			assert.is_nil(record.health)
			assert.is_true(record.enabled)
			assert.equal(M.convenience, record.convenience)
			assert.equal(M.security, record.security)
		end)

		it("A15: keeps a whole-home group; drops junk", function()
			local item = first(M.motion_area_configuration)
			item.group = { rid = M.rooms.home, rtype = "bridge_home" }
			assert.same({ rid = M.rooms.home, rtype = "bridge_home" }, model.area(item, {}).group)
			assert.same({}, model.areas({ { id = "no/such" }, "junk", { id = M.area, type = "room" } }, {}))
		end)
	end)

	describe("area_motion (EC rule 7, A9, A12; HR §2.5)", function()
		local function readings(conv, sec)
			return { [M.convenience] = conv, [M.security] = sec }
		end

		local function area()
			return model.areas(data(M.motion_area_configuration), area_services())[M.area]
		end

		it("is the reading of the enabled service that changed last: the live convenience one here", function()
			local conv = model.reading(first(M.convenience_area_motion))
			local sec = model.reading(first(M.security_area_motion))
			local r, rid = model.area_motion(area(), readings(conv, sec))
			assert.equal(conv, r)
			assert.equal(M.convenience, rid)
		end)

		it("A9: follows the security service when it reported last, whatever its motion_valid", function()
			local conv = model.reading(first(M.convenience_area_motion))
			local sec = model.reading(event_item("area_security"))
			sec.valid = false
			local r, rid = model.area_motion(area(), readings(conv, sec))
			assert.equal(M.security, rid)
			assert.is_true(r.motion)
		end)

		it("skips a disabled service and a service without a motion value (A12: none is nil)", function()
			local conv = model.reading(first(M.convenience_area_motion))
			local sec = model.reading(first(M.security_area_motion))
			conv.enabled = false
			assert.equal(M.security, select(2, model.area_motion(area(), readings(conv, sec))))
			assert.is_nil(model.area_motion(area(), readings({ enabled = true }, {})), "A12: no motion anywhere")
			assert.is_nil(model.area_motion(area(), {}))
		end)

		it("#288: shows motion while either service does, as both services reported a walk on the house", function()
			local function at(motion, t) return { enabled = true, motion = motion, changed = t } end
			local t = { "2026-10-26T20:48:15Z", "2026-10-26T20:48:19Z", "2026-10-26T20:48:30Z",
				"2026-10-26T20:48:40Z", "2026-10-26T20:48:42Z", "2026-10-26T20:48:50Z" }
			-- The house's sequence: convenience on, security on, security off,
			-- security on, convenience off, security off.
			local steps = {
				{ at(true, t[1]), nil, true },
				{ at(true, t[1]), at(true, t[2]), true },
				{ at(true, t[1]), at(false, t[3]), true },
				{ at(true, t[1]), at(true, t[4]), true },
				{ at(false, t[5]), at(true, t[4]), true },
				{ at(false, t[5]), at(false, t[6]), false },
			}
			for i, step in ipairs(steps) do
				local r = model.area_motion(area(), readings(step[1], step[2]))
				assert.equal(step[3], r and r.motion, "step " .. i)
			end
			-- The motion reading is the newest of those reporting motion; the
			-- end is the newest of all.
			assert.equal(t[4], (model.area_motion(area(), readings(at(true, t[1]), at(true, t[4])))).changed)
			assert.equal(t[6], (model.area_motion(area(), readings(at(false, t[5]), at(false, t[6])))).changed)
		end)

		it("is nothing while the area is paused or not running (A6, A7)", function()
			local conv = model.reading(first(M.convenience_area_motion))
			local record = area()
			record.enabled = false
			assert.is_nil(model.area_motion(record, readings(conv, nil)))
			record.enabled, record.health = true, "not_running"
			assert.is_nil(model.area_motion(record, readings(conv, nil)))
			record.health = "unrecoverable"
			assert.is_nil(model.area_motion(record, readings(conv, nil)))
			record.health = "degraded"
			assert.is_not_nil(model.area_motion(record, readings(conv, nil)), "a degraded area still senses (A5)")
		end)

		it("takes the convenience service on a tie or without times", function()
			assert.equal(M.convenience, select(2, model.area_motion(area(), readings({ motion = true }, { motion = false }))))
			assert.equal(M.convenience, select(2, model.area_motion(area(), readings(
				{ motion = true, changed = M.changed.e1 }, { motion = false, changed = M.changed.e1 }))))
			assert.equal(M.security, select(2, model.area_motion(area(), readings(
				{ motion = false }, { motion = false, changed = M.changed.e1 }))), "a time beats none")
			assert.equal(M.convenience, select(2, model.area_motion(area(), readings(
				{ motion = true }, { motion = false, changed = M.changed.e1 }))), "motion beats a newer no motion")
		end)
	end)

	describe("labels", function()
		it("gives the model text and the tags of S1 and A11", function()
			local devices = hue_model.devices(data(M.device))
			local sensors = model.sensors(devices, sensor_services())
			assert.equal("Hue motion sensor (SML003)", model.model_text(sensors[M.devices.hallway]))
			assert.equal("Hue outdoor motion sensor (SML002)", model.model_text(sensors[M.devices.porch]))
			assert.equal("MotionAware area", model.model_text({ kind = "area" }))
			assert.equal("PIR-9", model.model_text({ kind = "sensor", model_id = "PIR-9" }))
			assert.equal("#12", model.tag(sensors[M.devices.hallway]))
			assert.equal("#de000000", model.tag({ kind = "sensor", rid = M.devices.hallway }), "8 characters without /sensors/N")
			assert.equal("#ac00", model.tag({ kind = "area", rid = M.area }))
		end)

		it("reads the fixture's partial area body as the shape HR §2.3 reports", function()
			local partial = replace(M.motion_area_configuration_partial, '"enabled":true', '"enabled":false')
			assert.is_false(model.reading(first(partial)).enabled)
		end)
	end)
end)
