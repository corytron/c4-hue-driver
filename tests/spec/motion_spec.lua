-- bridge/motion.lua (docs/motion-design.md §4.2): the fourth registry owner,
-- the motion sensors and MotionAware areas. Test names carry the row ids of
-- docs/edge-cases-motion.md (EC) they pin; "§6" is its table of what a
-- device shows when its state is not known. The fixtures are
-- docs/motion-hue-research.md §5 (tests/fixtures/hue_motion.lua): the
-- Hallway sensor (SML003, Hue room Hallway), the Porch sensor (SML002, no
-- room) and the Kitchen motion area.

local json = require("dkjson")
local fake = require("helpers.fake_c4")
local log = require("common.log")
local M = require("fixtures.hue_motion")

-- Control4 rooms of the fake project: Hall (the Hue room Hallway is mapped
-- to it), Porch (nothing mapped) and Kitchen (the Hue room Kitchen).
local HALL, PORCH, KITCHEN = 8, 9, 10
local T0 = 1792998000
-- The timers' delays: the stuck-motion tick and the bridge-away grace (ms).
local TICK, GRACE = 30000, 60000

-- The resync's GETs (§4.2), in order.
local GET_ORDER = { "motion", "light_level", "temperature", "device_power", "zigbee_connectivity",
	"motion_area_configuration", "convenience_area_motion", "security_area_motion" }

local function clock(ts)
	return os.date("%H:%M", ts)
end

local function day(ts)
	return os.date("%m-%d", ts)
end

local function date(ts)
	return os.date("%Y-%m-%d", ts)
end

-- Plain-text replacement: ids and times contain pattern characters.
local function replace(text, from, to)
	local escaped = from:gsub("%W", "%%%0")
	local out, n = text:gsub(escaped, (to:gsub("%%", "%%%%")))
	assert(n > 0, "fixture text not found: " .. from)
	return out
end

local function body(...)
	return '{"errors":[],"data":[' .. table.concat({ ... }, ",") .. "]}"
end

-- An event container of `kind` holding the given items (JSON text each).
local function container(kind, ...)
	return '[{"creationtime":"2026-10-26T08:30:00Z","data":[' .. table.concat({ ... }, ",")
		.. '],"id":"e0000000-0000-4000-8000-0000000000ff","type":"' .. kind .. '"}]'
end

-- A sensor's motion resource: `motion` with its report at `changed` (nil:
-- the deprecated field alone, old firmware); opts.valid, opts.enabled.
local function motion_json(key, motion, changed, opts)
	opts = opts or {}
	local report = changed and string.format(',"motion_report":{"changed":"%s","motion":%s}', changed, tostring(motion))
		or ""
	return string.format('{"id":"%s","owner":{"rid":"%s","rtype":"device"},"enabled":%s,'
		.. '"motion":{"motion":%s,"motion_valid":%s%s},"type":"motion"}', M.motion[key], M.devices[key],
		tostring(opts.enabled ~= false), tostring(motion), tostring(opts.valid ~= false), report)
end

-- One of the area's services: `rtype` with motion at `changed`, or no motion block.
local function area_service_json(rtype, rid, motion, changed, enabled)
	local block = motion == nil and "" or string.format(',"motion":{"motion":%s,"motion_valid":true,'
		.. '"motion_report":{"changed":"%s","motion":%s}}', tostring(motion), changed, tostring(motion))
	return string.format('{"id":"%s","owner":{"rid":"%s","rtype":"motion_area_configuration"},"enabled":%s%s,"type":"%s"}',
		rid, M.area, tostring(enabled ~= false), block, rtype)
end

-- A sensor paired later (S4, S6): device, motion and zigbee items of an `add`.
local NEW = {
	device = "de000000-0000-4000-8000-000000000031",
	motion = "a0000000-0000-4000-8000-000000000031",
	zigbee = "2b000000-0000-4000-8000-000000000031",
}

local function new_sensor_add(name, mac)
	return container("add",
		string.format('{"id":"%s","id_v1":"/sensors/31","metadata":{"name":"%s","archetype":"unknown_archetype"},'
			.. '"product_data":{"model_id":"SML003","product_name":"Hue motion sensor"},"services":[{"rid":"%s",'
			.. '"rtype":"motion"},{"rid":"%s","rtype":"zigbee_connectivity"}],"type":"device"}', NEW.device, name, NEW.motion,
			NEW.zigbee),
		string.format('{"id":"%s","id_v1":"/sensors/31","owner":{"rid":"%s","rtype":"device"},"enabled":true,'
			.. '"motion":{"motion":false,"motion_valid":true,"motion_report":{"changed":"2026-10-26T08:40:00.000Z",'
			.. '"motion":false}},"type":"motion"}', NEW.motion, NEW.device),
		string.format('{"id":"%s","id_v1":"/sensors/31","owner":{"rid":"%s","rtype":"device"},"status":"connected",'
			.. '"mac_address":"%s","type":"zigbee_connectivity"}', NEW.zigbee, NEW.device, mac))
end

-- The Hue room Hallway with these device children (S3, S4).
local function hallway_children(...)
	local children = {}
	for _, rid in ipairs({ ... }) do
		children[#children + 1] = string.format('{"rid":"%s","rtype":"device"}', rid)
	end
	return container("update", string.format('{"id":"%s","children":[%s],"type":"room"}', M.rooms.hallway,
		table.concat(children, ",")))
end

-- The Hue room Garden, created in the Hue app with these device children; no
-- Control4 room maps to it until a spec says so (#319).
local GARDEN = "40000000-0000-4000-8000-000000000003"

local function garden_room(...)
	local children = {}
	for _, rid in ipairs({ ... }) do
		children[#children + 1] = string.format('{"rid":"%s","rtype":"device"}', rid)
	end
	return container("add", string.format('{"id":"%s","id_v1":"/groups/9","children":[%s],"services":[],'
		.. '"metadata":{"name":"Garden","archetype":"garden"},"type":"room"}', GARDEN, table.concat(children, ",")))
end

describe("bridge.motion", function()
	local motion, lights, http, c4, L, D, results, logged, now, timers

	local function data(text)
		return json.decode(text).data
	end

	local function http_ctx(req, cb)
		req.ip = "192.0.2.10"
		req.key = "k"
		return http.request(req, cb)
	end

	local function saw_log(text)
		for _, line in ipairs(logged) do
			if line:find(text, 1, true) then
				return true
			end
		end
		return false
	end

	local function count_log(text)
		local n = 0
		for _, line in ipairs(logged) do
			if line:find(text, 1, true) then
				n = n + 1
			end
		end
		return n
	end

	local function done(ok, text, sent)
		results[#results + 1] = { ok = ok, text = text, sent = sent }
	end

	local function last_result()
		return results[#results] or {}
	end

	-- The lights' caches as their resync leaves them: devices, MACs, groups.
	local function new_lights(overrides)
		local l = lights.new({ http = http_ctx, now = function() return now end })
		local res = { light = M.light, device = M.device, zigbee = M.zigbee_connectivity, room = M.room, zone = M.zone,
			bridge_home = M.bridge_home }
		for k, v in pairs(overrides or {}) do
			res[k] = v
		end
		for k, v in pairs(res) do
			res[k] = data(v)
		end
		l:absorb(res)
		l.synced = true  -- as lights:settle leaves it after a full GET
		l.reg:set_room_mapping(M.rooms.hallway, { c4_room_id = HALL, c4_room_name = "Hall", hue_name = "Hallway",
			type = "room" })
		l.reg:set_room_mapping(M.rooms.kitchen, { c4_room_id = KITCHEN, c4_room_name = "Kitchen", hue_name = "Kitchen",
			type = "room" })
		return l
	end

	local function set_timer(ms, fn)
		local t = { ms = ms, fn = fn, active = true }
		function t.Cancel(self)
			self.active = false
		end
		timers[#timers + 1] = t
		return t
	end

	local function active_timers(ms)
		local out = {}
		for _, t in ipairs(timers) do
			if t.active and (ms == nil or t.ms == ms) then
				out[#out + 1] = t
			end
		end
		return out
	end

	-- Fire every active timer of that delay once.
	local function fire(ms)
		local due = active_timers(ms)
		for _, t in ipairs(due) do
			t.active = false
			t.fn(t)
		end
		return #due
	end

	local function new_motion(extra)
		local ctx = { http = http_ctx, now = function() return now end, lights = L, set_timer = set_timer }
		for k, v in pairs(extra or {}) do
			ctx[k] = v
		end
		return motion.new(ctx)
	end

	local function unanswered()
		local out = {}
		for _, t in ipairs(c4.transfers) do
			if #t.responses == 0 and not t.ended then
				out[#out + 1] = t
			end
		end
		return out
	end

	-- Answer the GETs in flight one at a time (there is never more than one)
	-- from `bodies` (type → body text, or { code, body }, or { fail = true }
	-- for no answer at all) or the fixtures. Returns the types asked, in order.
	local function answer(bodies)
		local seen = {}
		while true do
			local open = unanswered()
			if #open == 0 then
				break
			end
			assert.equal(1, #open, "one GET at a time")
			local t = open[1]
			assert.equal("GET", t.method)
			local rtype = t.url:match("/clip/v2/resource/(.+)$")
			seen[#seen + 1] = rtype
			local o = bodies and bodies[rtype]
			if type(o) == "table" and o.fail then
				t.ended = true
				t:done(7, "Couldn't connect to server")
			elseif type(o) == "table" then
				t:respond(o.code or 200, o.body or "")
			else
				t:respond(200, o or M.get[rtype])
			end
		end
		return seen
	end

	local function resync(bodies)
		D:resync(done)
		return answer(bodies)
	end

	local function sent_to(id, command)
		local out = {}
		for _, m in ipairs(c4.sent) do
			if m.id == id and (command == nil or m.command == command) then
				out[#out + 1] = m.params
			end
		end
		return out
	end

	local function commands()
		local out = {}
		for _, m in ipairs(c4.sent) do
			out[#out + 1] = m.command .. "@" .. m.id
		end
		return out
	end

	local function states(id)
		return sent_to(id, "HUE_MOTION_STATE")
	end

	-- Every container of an event (a fixture key or JSON text) through the
	-- lights first, as the coordinator does, then through the motion module.
	-- Returns the number of messages the motion module sent.
	local function feed(key)
		local text = M.events[key] or key
		local sent = 0
		for _, c in ipairs(json.decode(text)) do
			L:on_container(c)
			sent = sent + D:on_container(c)
		end
		return sent
	end

	-- Resync, then add the hallway sensor (device 2001) and the kitchen area
	-- (device 2002) into their mapped rooms; the messages are cleared.
	local function add_both()
		resync()
		D:add(M.devices.hallway, nil, done)
		assert.equal("Added Hallway sensor to Hall (device 2001)", last_result().text)
		D:add(M.area, nil, done)
		assert.equal("Added Kitchen motion area to Kitchen (device 2002)", last_result().text)
		c4.sent = {}
	end

	-- A device of hue_motion.c4z added and bound by hand (C1: from Composer's search).
	local function hand_added(name, room)
		local id
		C4:AddDevice("hue_motion.c4z", room or HALL, name, function(device_id)
			id = device_id
		end)
		C4:Bind(15, 1, id, 1, "HUE_BRIDGE")
		return id
	end

	local function texts(list)
		local out = {}
		for i, item in ipairs(list) do
			out[i] = item.text
		end
		return out
	end

	local function attention()
		return D:attention_items()
	end

	local function has_item(items, text)
		for _, item in ipairs(items) do
			if item == text then
				return true
			end
		end
		return false
	end

	before_each(function()
		logged = {}
		log.sink = function(line) logged[#logged + 1] = line end
		log.set_debug(true)
		now = T0
		timers, results = {}, {}
		c4 = fake.install_c4()
		fake.add_room(HALL, "Hall")
		fake.add_room(PORCH, "Porch")
		fake.add_room(KITCHEN, "Kitchen")
		for _, m in ipairs({ "bridge.http", "bridge.hue_model", "bridge.registry", "bridge.groups", "bridge.util",
			"bridge.project", "bridge.owner", "bridge.lights", "bridge.motion_model", "bridge.motion" }) do
			package.loaded[m] = nil
		end
		http = require("bridge.http")
		lights = require("bridge.lights")
		motion = require("bridge.motion")
		L = new_lights()
		D = new_motion()
		D:load()
	end)

	after_each(function()
		log.set_debug(false)
		-- D7: the driver never changes anything on the Hue side.
		for _, t in ipairs(c4.transfers) do
			assert.equal("GET", t.method, "a request that is not a GET: " .. tostring(t.url))
		end
	end)

	describe("new, load and the persisted registry", function()
		it("requires http and keeps its own keys; nothing is known before the first GET", function()
			assert.has_error(function() motion.new({}) end)
			assert.same({ lights = "hue_motion", tombstones = "hue_motion_tombstones", rooms = false }, D.reg.keys)
			assert.equal("0 added", D:summary())
			assert.same({}, D:list_items())
			assert.same({}, attention())
			assert.same({ { text = "(no motion sensors fetched yet; connect the event stream)", value = "" } },
				D:picker_sensors())
			assert.same({ { text = "(no MotionAware areas fetched yet; connect the event stream)", value = "" } },
				D:picker_areas())
			assert.same({}, D:picker_relink_devices(), "driver.lua adds its own placeholder")
			assert.same({ { text = "(no motion devices registered)", value = "" } }, D:picker_forget_devices())
			assert.same({}, D:device_ids())
			assert.same({}, D:registered_rids())
		end)

		it("round-trips the registry, its tombstones and the forgotten marks through persistence", function()
			add_both()
			D:add(M.devices.porch, PORCH, done)
			assert.equal("Added Porch sensor to Porch (device 2003)", last_result().text)
			D:goodbye({ device_id = "2003", rid = M.devices.porch })
			D:forget(2002)
			assert.equal(2001, c4.persist.hue_motion[M.devices.hallway].device_id)
			assert.equal("Porch sensor", c4.persist.hue_motion_tombstones[M.devices.porch].name)
			assert.equal(M.area, c4.persist.hue_motion_forgotten["2002"].rid)
			assert.is_nil(c4.persist.hue_lights, "the lights' key is untouched")

			local D2 = new_motion()
			D2:load()
			assert.same({
				device_id = 2001, name = "Hallway sensor", kind = "sensor", model = "Hue motion sensor (SML003)",
				model_id = "SML003", id_v1 = "/sensors/12", hue_room_rid = M.rooms.hallway, hue_room = "Hallway",
				mac_address = M.macs.hallway, has_light_level = true, has_temperature = true, has_battery = true,
				state = "linked", created_room_id = HALL, created_at = T0,
			}, D2:entry(M.devices.hallway))
			assert.same({ M.devices.hallway }, D2:registered_rids())
			assert.same({ [2001] = true }, D2:device_ids())
			assert.equal("Porch sensor", D2.reg:tombstones()[M.devices.porch].name)
			assert.same({ rid = M.area, name = "Kitchen motion area", kind = "area", at = T0 }, D2.forgotten[2002])
		end)

		it("normalises what an older or foreign store holds", function()
			c4.persist.hue_motion = { [M.devices.hallway] = { device_id = "2001", name = "Hallway sensor", kind = "light",
				has_battery = "true", has_temperature = "false", stale_field = 1 } }
			c4.persist.hue_motion_forgotten = { ["2009"] = { rid = "", kind = "scene" }, junk = { rid = M.area }, ["7"] = "x" }
			local D2 = new_motion()
			D2:load()
			local entry = D2:entry(M.devices.hallway)
			assert.is_nil(entry.kind)
			assert.is_true(entry.has_battery)
			assert.is_false(entry.has_temperature)
			assert.is_nil(entry.stale_field)
			assert.same({ [2009] = { at = nil } }, D2.forgotten)
		end)
	end)

	describe("resync", function()
		it("GETs the eight types one at a time in order, with the key, then knows the sensors and the area", function()
			assert.same(GET_ORDER, resync())
			assert.equal("k", c4.transfers[1].headers["hue-application-key"])
			assert.same({ ok = true, sent = 0 }, last_result())
			assert.equal("2 sensors and 1 area on the bridge; 0 added", D:summary())
			assert.same({ "Hallway sensor [Hallway] #12", "Porch sensor #20" }, texts(D:picker_sensors()))
			assert.same({ "Kitchen motion area (MotionAware) [Kitchen] #ac00" }, texts(D:picker_areas()))
		end)

		it("#318: a 503 on the area types (a Hue Bridge v2) means none too, unless areas were served in this run", function()
			assert.same({ "motion", "light_level", "temperature", "device_power", "zigbee_connectivity",
				"motion_area_configuration" }, resync({ motion_area_configuration = { code = 503,
				body = '{"errors":[{"description":"Service Unavailable"}],"data":[]}' } }))
			assert.truthy(D:summary():find("MotionAware not supported by this bridge", 1, true), D:summary())
			assert.is_true(saw_log("this bridge offers no MotionAware areas (GET /clip/v2/resource/"
				.. "motion_area_configuration answered 503)"))
		end)

		it("#318: a 503 after the areas were served is a failed GET, not a bridge without MotionAware", function()
			add_both()
			resync()
			resync({ motion_area_configuration = { code = 503,
				body = '{"errors":[{"description":"Service Unavailable"}],"data":[]}' } })
			assert.is_nil(D:summary():find("not supported", 1, true), D:summary())
		end)

		it("B5: a 404 on the area types means this bridge offers none: nothing is gone, the rest is not asked", function()
			add_both()
			assert.same({ "motion", "light_level", "temperature", "device_power", "zigbee_connectivity",
				"motion_area_configuration" }, resync({ motion_area_configuration = { code = 404, body = M.not_found } }))
			assert.is_true(last_result().ok)
			assert.equal("linked", D:entry(M.area).state)
			assert.equal("2 sensors on the bridge; 2 added; MotionAware not supported by this bridge", D:summary())
			assert.same({ { text = "(this bridge offers no MotionAware areas)", value = "" } }, D:picker_areas())
			assert.same({ rid = M.area, reason = "resync", online = "false",
				status = "This bridge offers no MotionAware areas; Forget Motion Device removes it" }, states(2002)[1])
			assert.is_true(has_item(attention(), "1 motion area device on a bridge without MotionAware: Kitchen motion area "
				.. "(Forget Motion Device)"))
			assert.is_true(saw_log("this bridge offers no MotionAware areas (GET /clip/v2/resource/"
				.. "motion_area_configuration answered 404)"))
			-- Served again (a firmware update, B4): the area reports as before.
			c4.sent = {}
			resync()
			assert.equal("true", states(2002)[1].online)
			assert.is_nil(states(2002)[1].status)
			assert.equal("2 sensors and 1 area on the bridge; 2 added", D:summary())
		end)

		it("B-rows: a failed GET is reported and marks nothing gone; what the other GETs brought is used", function()
			add_both()
			resync({ motion = { code = 500 }, motion_area_configuration = { code = 503 },
				temperature = replace(M.temperature_body, "21.37", "22.5") })
			assert.is_false(last_result().ok)
			assert.equal("GET /clip/v2/resource/motion: HTTP 500; GET /clip/v2/resource/motion_area_configuration: HTTP 503",
				last_result().text)
			assert.equal("linked", D:entry(M.devices.hallway).state)
			assert.equal("linked", D:entry(M.area).state)
			assert.equal("22.5", states(2001)[1].temperature)
			assert.equal("false", states(2001)[1].motion, "the motion held from before")
			assert.is_true(saw_log("nothing is marked gone"))
		end)

		it("§6 bridge away: every GET unanswered says the motion is not current, and the contacts stay", function()
			add_both()
			feed("e1")
			c4.sent = {}
			resync({ motion = { fail = true }, light_level = { fail = true }, temperature = { fail = true },
				device_power = { fail = true }, zigbee_connectivity = { fail = true },
				motion_area_configuration = { fail = true }, convenience_area_motion = { fail = true },
				security_area_motion = { fail = true } })
			assert.is_false(last_result().ok)
			local away = string.format("Bridge not answering since %s; motion not current", clock(T0))
			local st = states(2001)[1]
			assert.equal(away, st.status)
			assert.is_nil(st.motion, "no motion from what is not known to be current")
			assert.is_nil(st.ended, "a failure, not a deliberate end")
			assert.equal("true", st.online, "Online is about the sensor, not the bridge (R1)")
			assert.equal(away, states(2002)[1].status)
			-- Any container proves the bridge answers again.
			c4.sent = {}
			feed("e3")
			assert.same({ { rid = M.devices.hallway, reason = "event", lux = "126" } }, states(2001))
			assert.same({ { rid = M.area, reason = "event" } }, states(2002), "status cleared")
		end)

		it("A3, S5: a successful GET lacking an area, or the lights' fetched devices lacking a sensor, marks it gone; "
			.. "back again, linked", function()
			add_both()
			local device = L.devices[M.devices.hallway]
			L.devices[M.devices.hallway] = nil
			now = T0 + 60
			resync({ motion_area_configuration = M.empty, convenience_area_motion = M.empty, security_area_motion = M.empty })
			assert.equal("gone", D:entry(M.devices.hallway).state)
			assert.equal("gone", D:entry(M.area).state)
			assert.equal("true", sent_to(2001, "HUE_MOTION_CONFIGURE")[1].gone)
			assert.same({ rid = M.devices.hallway, reason = "resync", online = "false", ended = "deleted",
				status = string.format("Sensor deleted in Hue since %s; re-link or Forget", day(now)) }, states(2001)[1])
			assert.same({ rid = M.area, reason = "resync", online = "false", ended = "deleted",
				status = string.format("Area deleted in Hue since %s; re-link or Forget", day(now)) }, states(2002)[1])
			assert.is_true(saw_log("motion: Hallway sensor (device 2001) is no longer on the bridge; marked gone"))
			local items = attention()
			assert.is_true(has_item(items, string.format("1 motion sensor missing from the bridge: Hallway sensor (device 2001, "
				.. "since %s) (Re-link Motion Device or Forget Motion Device)", date(now))))
			assert.is_true(has_item(items, string.format("1 motion area missing from the bridge: Kitchen motion area (device "
				.. "2002, since %s) (Re-link Motion Device or Forget Motion Device)", date(now))))
			assert.equal("1 sensor and 0 areas on the bridge; 2 added, 2 missing", D:summary())

			L.devices[M.devices.hallway] = device
			c4.sent = {}
			resync()
			assert.equal("linked", D:entry(M.devices.hallway).state)
			assert.equal("linked", D:entry(M.area).state)
			assert.equal("false", sent_to(2001, "HUE_MOTION_CONFIGURE")[1].gone)
			assert.is_nil(states(2001)[1].ended)
			assert.equal("false", states(2001)[1].motion)
			assert.is_true(saw_log("motion: Hallway sensor (device 2001) is back on the bridge"))
		end)

		it("answers every caller that waited, with one more resync", function()
			D:resync(function() done(true, "first") end)
			D:resync(function() done(true, "second") end)
			D:resync(function() done(true, "third") end)
			answer()
			assert.same({ "first", "second", "third" }, texts(results))
			assert.equal(16, #c4.transfers, "two resyncs of eight GETs")
		end)
	end)

	describe("add (C1, C9, C15, A15)", function()
		it("refuses without a pick, a rid not on the bridge, a missing room and A15: a whole-home area without one",
			function()
			D:add(M.devices.hallway, nil, done)
			assert.equal("Not added: motion sensor or area " .. M.devices.hallway .. " is not on the bridge (connect the event "
				.. "stream and try again)", last_result().text)
			resync({ motion_area_configuration = replace(M.motion_area_configuration,
				'"group":{"rid":"' .. M.rooms.kitchen .. '","rtype":"room"}', '"group":{"rid":"' .. M.rooms.home
				.. '","rtype":"bridge_home"}') })
			D:add("", nil, done)
			assert.same({ ok = false, text = "Not added: pick a motion sensor or area first" }, last_result())
			D:add(M.devices.porch, nil, done)
			assert.equal("Not added: Porch sensor: no Hue room; pick a room, or Set Room Mapping first", last_result().text)
			D:add(M.devices.hallway, 99, done)
			assert.equal("Not added: Control4 room 99 no longer exists", last_result().text)
			D:add(M.area, "mapped", done)
			assert.equal("Not added: Kitchen motion area: the whole home has no mapped room; pick a room, or Set Room "
				.. "Mapping first", last_result().text)
			assert.same({ "Kitchen motion area (MotionAware) [(whole home)] #ac00" }, texts(D:picker_areas()))
			assert.same({}, c4.added)
			D:add(M.area, KITCHEN, done)
			assert.equal("Added Kitchen motion area to Kitchen (device 2001)", last_result().text)
			assert.equal("(whole home)", sent_to(2001, "HUE_MOTION_CONFIGURE")[1].hue_room, "A15")
		end)

		it("C1: creates a sensor device: AddDevice hue_motion.c4z, Bind, the registry, CONFIGURE then the full STATE",
			function()
			resync()
			D:add(M.devices.hallway, nil, done)
			assert.same({ ok = true, text = "Added Hallway sensor to Hall (device 2001)" }, last_result())
			assert.same({ { id = 2001, driver = "hue_motion.c4z", room = HALL, name = "Hallway sensor" } }, c4.added)
			assert.same({ { provider = 15, provider_binding = 1, consumer = 2001, consumer_binding = 1, class = "HUE_BRIDGE" } },
				c4.bindings)
			assert.equal(2001, c4.persist.hue_motion[M.devices.hallway].device_id)
			assert.same({ "HUE_MOTION_CONFIGURE@2001", "HUE_MOTION_STATE@2001" }, commands())
			assert.same({ rid = M.devices.hallway, kind = "sensor", name = "Hallway sensor",
				model = "Hue motion sensor (SML003)", hue_room = "Hallway", id_v1 = "/sensors/12", gone = "false",
				has_light_level = "true", has_temperature = "true",
				has_battery = "true" }, c4.sent[1].params)
			assert.same({ rid = M.devices.hallway, reason = "resync", online = "true", enabled = "true", motion = "false",
				motion_changed = M.changed.hallway_motion, lux = "63", temperature = "21.37", battery_level = "87",
				battery_state = "normal" }, c4.sent[2].params)
			assert.equal("2 sensors and 1 area on the bridge; 1 added", D:summary())
		end)

		it("D2: creates an area device of the same driver, kind area, without the sensor rows", function()
			resync()
			D:add(M.area, nil, done)
			assert.same({ id = 2001, driver = "hue_motion.c4z", room = KITCHEN, name = "Kitchen motion area" }, c4.added[1])
			assert.same({ rid = M.area, kind = "area", name = "Kitchen motion area", model = "MotionAware area",
				hue_room = "Kitchen", gone = "false", has_light_level = "false", has_temperature = "false",
				has_battery = "false" }, c4.sent[1].params)
			assert.same({ rid = M.area, reason = "resync", online = "true", enabled = "true", motion = "false",
				motion_changed = M.changed.convenience }, c4.sent[2].params)
		end)

		it("C15: refuses a second device for one sensor", function()
			add_both()
			D:add(M.devices.hallway, HALL, done)
			assert.same({ ok = false, text = "Not added: Hallway sensor is already imported (device 2001)" }, last_result())
			assert.equal(2, #c4.added)
		end)

		it("C9: AddDevice failing (the motion driver not on the controller) registers nothing", function()
			D = new_motion({ add_device = function(_, _, _, cb) cb(0, {}) end })
			D:load()
			resync()
			D:add(M.devices.hallway, nil, done)
			assert.same({ ok = false, text = "Not added: AddDevice failed for Hallway sensor (see the Lua output)" },
				last_result())
			assert.same({}, D:registered_rids())
		end)

		it("C4: a device deleted in Composer leaves a tombstone: listed as deleted, not new, re-created by Add", function()
			add_both()
			now = T0 + 86400
			assert.is_not_nil(D:goodbye({ device_id = "2001", rid = M.devices.hallway }))
			assert.is_nil(D:entry(M.devices.hallway))
			assert.is_true(saw_log("motion: Hallway sensor (device 2001) was deleted in Composer; Add Motion Sensor and Add "
				.. "Motion Area list it as deleted"))
			assert.same({ "Porch sensor #20", string.format("Hallway sensor [Hallway] #12 (deleted from Composer %s)",
				date(now)) }, texts(D:picker_sensors()))
			assert.is_true(has_item(attention(), "1 new motion sensor on the bridge: Porch sensor #20 (Add Motion Sensor)"))
			assert.equal("2 sensors and 1 area on the bridge; 1 added, 1 deleted", D:summary())
			D:add(M.devices.hallway, nil, done)
			assert.equal("Added Hallway sensor to Hall (device 2003)", last_result().text)
			assert.is_nil(D.reg:tombstones()[M.devices.hallway])
		end)
	end)

	describe("add_all_new: Add All New Motion Sensors (#319, EC §7)", function()
		-- The text's tail while the Kitchen motion area has no device, and its
		-- part for the Porch sensor, which is in no Hue room.
		local AREA_NOTE = "not included: 1 new motion area (Add Motion Area adds areas one at a time)"
		local NO_ROOM = "skipped 1 with no mapped room (Set Room Mapping or Add Motion Sensor): Porch sensor #20 "
			.. "(no Hue room)"

		it("C1: adds every new sensor whose Hue room is mapped into that room, and lists the ones in no Hue room or an "
			.. "unmapped one, never guessing a room; never from an event, never an area (A15)", function()
			resync()
			-- A third sensor, paired in the Hue app and placed in the Hue room Garden, which nothing maps.
			feed(new_sensor_add("Garden sensor", "00:17:88:01:0c:00:00:31-02"))
			feed(garden_room(NEW.device))
			assert.same({}, c4.added, "nothing is added from an event (S1)")
			assert.is_true(D:add_all_new(done))
			assert.same({ { id = 2001, driver = "hue_motion.c4z", room = HALL, name = "Hallway sensor" } }, c4.added)
			assert.same({ ok = true, text = "Added 1 new motion sensor: Hallway sensor #12 to Hall (device 2001); skipped 2 "
				.. "with no mapped room (Set Room Mapping or Add Motion Sensor): Garden sensor #31 (Hue room Garden not "
				.. "mapped), Porch sensor #20 (no Hue room); " .. AREA_NOTE }, last_result())
			assert.same({ { provider = 15, provider_binding = 1, consumer = 2001, consumer_binding = 1, class = "HUE_BRIDGE" } },
				c4.bindings)
			assert.same({ "HUE_MOTION_CONFIGURE@2001", "HUE_MOTION_STATE@2001" }, commands())
			assert.equal("linked", D:entry(M.devices.hallway).state)
			assert.equal(HALL, D:entry(M.devices.hallway).created_room_id)
			assert.is_nil(D:entry(M.area), "an area comes one at a time from Add Motion Area, even in a mapped room")
			assert.is_false(D.adding)
			assert.is_true(saw_log("motion: Added 1 new motion sensor: Hallway sensor #12 to Hall (device 2001); skipped 2"))

			-- A mapping to a Control4 room that no longer exists is no mapping.
			L.reg:set_room_mapping(GARDEN, { c4_room_id = 99, c4_room_name = "Shed", hue_name = "Garden", type = "room" })
			assert.is_true(D:add_all_new(done))
			assert.same({ ok = true, text = "Added no motion sensors; skipped 2 with no mapped room (Set Room Mapping or Add "
				.. "Motion Sensor): Garden sensor #31 (Hue room Garden mapped to a Control4 room that no longer exists), Porch "
				.. "sensor #20 (no Hue room); " .. AREA_NOTE }, last_result())
			assert.equal(1, #c4.added)

			-- Mapped now: the next click adds it, and only it.
			L.reg:set_room_mapping(GARDEN, { c4_room_id = PORCH, c4_room_name = "Porch", hue_name = "Garden", type = "room" })
			D:add_all_new(done)
			assert.same({ ok = true, text = "Added 1 new motion sensor: Garden sensor #31 to Porch (device 2002); " .. NO_ROOM
				.. "; " .. AREA_NOTE }, last_result())
			assert.same({ id = 2002, driver = "hue_motion.c4z", room = PORCH, name = "Garden sensor" }, c4.added[2])
			assert.equal(2, #c4.added)
		end)

		it("C4, C15: idempotent by rid: a second click and one after a restart add nothing; a sensor deleted in Composer "
			.. "is skipped and listed, never re-created", function()
			resync()
			D:add_all_new(done)
			D:add(M.devices.porch, PORCH, done)
			D:add(M.area, nil, done)
			assert.equal(3, #c4.added)
			c4.sent, c4.calls = {}, {}
			assert.is_true(D:add_all_new(done))
			assert.same({ ok = true, text = "No new motion sensors on the bridge (2 on bridge, 2 added)" }, last_result())
			assert.equal(3, #c4.added)
			assert.same({}, c4.calls_to("Bind"))
			assert.same({}, c4.calls_to("Unbind"))
			assert.same({}, c4.calls_to("RenameDevice"))
			assert.same({}, c4.calls_to("PersistSetValue"), "the registry is unchanged")
			assert.same({}, commands(), "the devices hear nothing")

			-- After a restart: a fresh instance from the persisted registry.
			D = new_motion()
			D:load()
			resync()
			D:add_all_new(done)
			assert.same({ ok = true, text = "No new motion sensors on the bridge (2 on bridge, 2 added)" }, last_result())
			assert.equal(3, #c4.added)

			-- C4: the hallway sensor's device deleted in Composer.
			now = T0 + 86400
			assert.is_not_nil(D:goodbye({ device_id = "2001", rid = M.devices.hallway }))
			D:add_all_new(done)
			assert.same({ ok = true, text = string.format("Added no motion sensors; skipped 1 deleted in Composer (Add Motion "
				.. "Sensor re-creates one): Hallway sensor #12 (deleted %s)", date(now)) }, last_result())
			assert.equal(3, #c4.added)
			assert.is_nil(D:entry(M.devices.hallway))
			-- Add Motion Sensor re-creates it on purpose; then nothing is left.
			D:add(M.devices.hallway, nil, done)
			assert.equal("Added Hallway sensor to Hall (device 2004)", last_result().text)
			D:add_all_new(done)
			assert.equal("No new motion sensors on the bridge (2 on bridge, 2 added)", last_result().text)
		end)

		it("S4, S6: a sensor that looks like the replacement of a device is skipped and listed, so that Re-link keeps "
			.. "that device and its programming (rule 3)", function()
			add_both()
			feed(container("delete", '{"id":"' .. M.motion.hallway .. '","type":"motion"}', '{"id":"' .. M.devices.hallway
				.. '","type":"device"}'))
			assert.equal("gone", D:entry(M.devices.hallway).state)
			-- The sensor reset and paired again (the same radio), back in its mapped Hue room.
			feed(new_sensor_add("Hallway sensor", M.macs.hallway))
			feed(hallway_children(M.devices.lamp, NEW.device))
			assert.is_true(D:add_all_new(done))
			assert.equal(2, #c4.added, "no second device for the sensor")
			assert.same({ ok = true, text = "Added no motion sensors; skipped 1 that may be a replacement (Re-link Motion "
				.. "Device or Add Motion Sensor): Hallway sensor #31 (same radio as Hallway sensor, device 2001; re-link?); "
				.. NO_ROOM }, last_result())
			assert.same({ true, "Re-linked device 2001 (was Hallway sensor) to Hallway sensor [Hallway] #31" },
				{ D:relink(2001, NEW.device) })
			D:add_all_new(done)
			assert.same({ ok = true, text = "Added no motion sensors; " .. NO_ROOM }, last_result())
			assert.equal(2, #c4.added)
		end)

		it("B1: refused before the first GET and while an add or a resync runs; while it runs, the other actions are "
			.. "refused and a resync waits for it", function()
			local held = {}
			D = new_motion({ add_device = function(driver, room, name, cb)
				held[#held + 1] = function() C4:AddDevice(driver, room, name, cb) end
			end })
			D:load()
			assert.is_false(D:add_all_new(done))
			assert.same({ ok = false, text = "Not added: no motion sensors fetched yet (connect the event stream and try "
				.. "again)" }, last_result())
			D:resync(done)
			assert.is_false(D:add_all_new(done))
			assert.same({ ok = false, text = "Busy: resyncing motion devices; try again in a moment" }, last_result())
			answer()
			assert.is_true(D:add(M.devices.porch, PORCH, done))
			assert.is_false(D:add_all_new(done))
			assert.same({ ok = false, text = "Busy: adding a motion device; try again in a moment" }, last_result())
			held[1]()
			assert.equal("Added Porch sensor to Porch (device 2001)", last_result().text)

			assert.is_true(D:add_all_new(done))
			assert.equal(2, #held, "its one AddDevice waits for Director")
			local busy = "Busy: adding a motion device; try again in a moment"
			assert.is_false(D:add_all_new(done))
			assert.equal(busy, last_result().text)
			assert.is_false(D:add(M.area, nil, done))
			assert.equal(busy, last_result().text)
			assert.same({ false, busy }, { D:relink(2001, M.devices.hallway) })
			assert.same({ false, busy }, { D:forget(2001) })
			local transfers = #c4.transfers
			D:resync(function(ok) done(ok, "the resync asked for meanwhile") end)
			assert.equal(transfers, #c4.transfers, "the resync waits")
			held[2]()
			assert.same({ ok = true, text = "Added 1 new motion sensor: Hallway sensor #12 to Hall (device 2002); "
				.. AREA_NOTE }, last_result())
			assert.equal(transfers + 1, #c4.transfers, "then it runs")
			answer()
			assert.same({ ok = true, text = "the resync asked for meanwhile" }, last_result())
			assert.is_true(D:add_all_new(done), "accepted again once finished")
			assert.same({ ok = true, text = "No new motion sensors on the bridge (2 on bridge, 2 added); " .. AREA_NOTE },
				last_result())
		end)

		it("C9: an AddDevice that fails is listed and the others carry on; one that raises stops the run early and keeps "
			.. "what it created", function()
			local refuse, raise = {}, {}
			D = new_motion({ add_device = function(driver, room, name, cb)
				if raise[name] then
					error("Director refused " .. name, 0)
				elseif refuse[name] then
					return cb(0, {})
				end
				C4:AddDevice(driver, room, name, cb)
			end })
			D:load()
			resync()
			feed(new_sensor_add("Landing sensor", "00:17:88:01:0c:00:00:31-02"))
			feed(hallway_children(M.devices.lamp, M.devices.hallway, NEW.device))
			refuse["Hallway sensor"] = true
			D:add_all_new(done)
			assert.same({ ok = false, text = "Added 1 new motion sensor: Landing sensor #31 to Hall (device 2001); AddDevice "
				.. "failed for 1: Hallway sensor #12; " .. NO_ROOM .. "; " .. AREA_NOTE }, last_result())
			assert.same({ NEW.device }, D:registered_rids())

			-- The porch sensor placed in the Hue room Garden, mapped to Porch; its AddDevice raises.
			refuse["Hallway sensor"], raise["Porch sensor"] = nil, true
			feed(garden_room(M.devices.porch))
			L.reg:set_room_mapping(GARDEN, { c4_room_id = PORCH, c4_room_name = "Porch", hue_name = "Garden", type = "room" })
			assert.is_true(D:add_all_new(done))
			assert.same({ ok = false, text = "Added 1 new motion sensor: Hallway sensor #12 to Hall (device 2002); stopped "
				.. "early: Director refused Porch sensor; " .. AREA_NOTE }, last_result())
			assert.equal(2002, D:entry(M.devices.hallway).device_id)
			assert.is_nil(D:entry(M.devices.porch))
			assert.is_false(D.adding, "the busy flag is released")
			raise["Porch sensor"] = nil
			D:add_all_new(done)
			assert.same({ ok = true, text = "Added 1 new motion sensor: Porch sensor #20 to Porch (device 2003); "
				.. AREA_NOTE }, last_result())
		end)

		it("B5: a bridge without MotionAware has no areas to mention", function()
			resync({ motion_area_configuration = { code = 404, body = M.not_found } })
			D:add_all_new(done)
			assert.same({ ok = true, text = "Added 1 new motion sensor: Hallway sensor #12 to Hall (device 2001); " .. NO_ROOM },
				last_result())
		end)
	end)

	describe("§6: what a device shows when its state is not known", function()
		it("no reading yet since the start (C12): CONFIGURE from the registry, no STATE before the first GET", function()
			add_both()
			local D2 = new_motion()
			assert.is_false(D2:hello({ rid = M.devices.hallway, device_id = "2001", kind = "sensor" }), "waits for load")
			D2:load()
			c4.sent = {}
			assert.equal(2, D2:configure_all())
			assert.same({ "HUE_MOTION_CONFIGURE@2001", "HUE_MOTION_CONFIGURE@2002", "HUE_MOTION_CONFIGURE@2001" }, commands(),
				"both configured (name order), then the early hello answered with its configuration alone")
			c4.sent = {}
			D = D2
			resync()
			assert.same({ "HUE_MOTION_STATE@2001", "HUE_MOTION_STATE@2002" }, commands(), "the first reading, in full")
			assert.equal("resync", states(2001)[1].reason)
		end)

		it("R1: the bridge away for less than a minute changes nothing", function()
			add_both()
			D:on_stream_state(false)
			assert.equal(1, #active_timers(GRACE))
			D:on_stream_state(true)
			assert.equal(0, #active_timers(GRACE))
			assert.same({}, c4.sent)
		end)

		it("R1: the bridge away for longer: the status says so; contact, Online and Enabled stay", function()
			add_both()
			feed("e1")
			c4.sent = {}
			D:on_stream_state(false)
			D:on_stream_state(false)
			assert.equal(1, #active_timers(GRACE), "one grace timer")
			now = T0 + 60
			fire(GRACE)
			local away = string.format("Bridge not answering since %s; motion not current", clock(T0))
			assert.same({ { rid = M.devices.hallway, reason = "event", status = away } }, states(2001))
			assert.same({ { rid = M.area, reason = "event", status = away } }, states(2002))
			assert.is_true(saw_log("the motion devices say their motion is not current"))
			-- The stream back: the resync that follows tells every device its state.
			c4.sent = {}
			D:on_stream_state(true)
			assert.same({}, c4.sent)
			resync()
			assert.is_nil(states(2001)[1].status)
			assert.equal("true", states(2001)[1].motion)
		end)

		it("S9: unreachable: Online false and the status, the contact as it is; back, the status clears (R8)", function()
			resync()
			D:add(M.devices.porch, PORCH, done)
			feed(container("update", motion_json("porch", true, "2026-10-26T07:20:00.000Z")))
			c4.sent = {}
			now = T0 + 120
			feed("e5")
			assert.same({ { rid = M.devices.porch, reason = "event", online = "false",
				status = string.format("Not reachable since %s; motion not current", clock(now)) } }, states(2001))
			c4.sent = {}
			feed("e5_back")
			assert.same({ { rid = M.devices.porch, reason = "event", online = "true" } }, states(2001),
				"the motion it showed is current again: nothing to change")
		end)

		it("no motion reading: motion_valid false while enabled; S14: the motion service gone, never gone itself", function()
			add_both()
			feed(container("update", motion_json("hallway", false, M.changed.hallway_motion, { valid = false })))
			assert.same({ { rid = M.devices.hallway, reason = "event", status = "No motion reading from Hue yet" } },
				states(2001))
			c4.sent = {}
			feed(container("delete", '{"id":"' .. M.motion.hallway .. '","type":"motion"}'))
			assert.same({}, c4.sent, "the same status")
			resync({ motion = body(motion_json("porch", false, M.changed.porch_motion)) })
			assert.equal("linked", D:entry(M.devices.hallway).state, "S14: gone only when the device is")
			assert.equal("No motion reading from Hue yet", states(2001)[1].status)
			assert.equal("true", states(2001)[1].online)
			assert.is_nil(states(2001)[1].motion)
			assert.is_false(has_item(attention(), "1 motion device without a motion reading from Hue for more than 1 h: "
				.. "Hallway sensor"))
			now = T0 + 3600
			assert.is_true(has_item(attention(), "1 motion device without a motion reading from Hue for more than 1 h: "
				.. "Hallway sensor"))
		end)

		it("A12: an area with no enabled service carrying motion has no reading", function()
			add_both()
			resync({
				convenience_area_motion = body(area_service_json("convenience_area_motion", M.convenience, nil)),
				security_area_motion = body(area_service_json("security_area_motion", M.security, true,
					"2026-10-26T07:00:00.000Z", false)),
			})
			assert.same({ rid = M.area, reason = "resync", online = "true", enabled = "true",
				status = "No motion reading from Hue yet" }, states(2002)[1],
				"no motion value: the device keeps the one it shows (a failure); the disabled service is not read")
		end)

		it("A7: an area not running: Online false and the status, the contact as it is; Attention at once", function()
			add_both()
			feed("e8_motion")
			c4.sent = {}
			feed("area_not_running")
			assert.same({ { rid = M.area, reason = "event", online = "false",
				status = "Area not running in Hue; save it again in the Hue app" } }, states(2002))
			assert.is_true(has_item(attention(), "1 motion area not running: Kitchen motion area (open it in the Hue app and "
				.. "save it again)"))
		end)

		it("A5: a degraded area still reports motion and counts its lights; Attention after an hour", function()
			add_both()
			feed("e9_degraded")
			assert.same({ { rid = M.area, reason = "event", status = "Area degraded: 1 of its 3 lights not responding" } },
				states(2002))
			c4.sent = {}
			feed("e8_motion")
			assert.same({ { rid = M.area, reason = "event", motion = "true", motion_changed = M.changed.e8_motion,
				status = "Area degraded: 1 of its 3 lights not responding" } }, states(2002))
			assert.is_false(has_item(attention(), "1 motion area degraded for more than 1 h: Kitchen motion area (power its "
				.. "lights)"))
			now = T0 + 3600
			assert.is_true(has_item(attention(), "1 motion area degraded for more than 1 h: Kitchen motion area (power its "
				.. "lights)"))
		end)

		it("S7: switched off is a deliberate end; switched on, only the next reading counts", function()
			add_both()
			feed("e1")
			c4.sent = {}
			feed("e6")
			assert.same({ { rid = M.devices.hallway, reason = "event", enabled = "false", ended = "off",
				status = "Switched off in the Hue app; no motion is reported" } }, states(2001))
			assert.is_true(has_item(attention(), "1 motion sensor switched off in the Hue app: Hallway sensor"))
			c4.sent = {}
			feed("e6_on")
			assert.same({ { rid = M.devices.hallway, reason = "event", enabled = "true",
				status = "No motion reading from Hue yet" } }, states(2001), "the motion it held from before is not reported")
			c4.sent = {}
			feed("e2")
			assert.same({ { rid = M.devices.hallway, reason = "event", motion = "false", motion_changed = M.changed.e2 } },
				states(2001))
		end)

		it("A6: paused is a deliberate end, the services not read meanwhile; resumed, the next reading counts", function()
			add_both()
			feed("e8_motion")
			c4.sent = {}
			feed("e9_paused")
			assert.same({ { rid = M.area, reason = "event", enabled = "false", ended = "paused",
				status = "Paused in the Hue app; no motion is reported" } }, states(2002))
			assert.is_true(has_item(attention(), "1 motion area paused in the Hue app: Kitchen motion area"))
			c4.sent = {}
			feed(container("update", area_service_json("convenience_area_motion", M.convenience, false,
				"2026-10-26T07:40:30.000Z")))
			assert.same({}, c4.sent, "a frozen service while paused")
			feed("area_resumed")
			assert.same({ { rid = M.area, reason = "event", enabled = "true", motion = "false",
				motion_changed = "2026-10-26T07:40:30.000Z" } }, states(2002),
				"the no-motion reported meanwhile is newer than the pause: it counts")
			c4.sent = {}
			feed(container("update", area_service_json("convenience_area_motion", M.convenience, true,
				"2026-10-26T07:46:00.000Z")))
			assert.same({ { rid = M.area, reason = "event", motion = "true", motion_changed = "2026-10-26T07:46:00.000Z" } },
				states(2002))
		end)

		it("S5, E10, E11: deleted in Hue: gone at once, CONFIGURE gone and the deliberate end; Re-link or Forget",
			function()
			resync()
			feed("e10")
			D:add(M.devices.new, HALL, done)
			assert.equal("Added Hue motion sensor 1 to Hall (device 2001)", last_result().text)
			c4.sent = {}
			now = T0 + 600
			feed("e11")
			assert.equal("gone", D:entry(M.devices.new).state)
			assert.same({ "HUE_MOTION_CONFIGURE@2001", "HUE_MOTION_STATE@2001" }, commands())
			assert.equal("true", c4.sent[1].params.gone)
			assert.same({ rid = M.devices.new, reason = "event", online = "false", ended = "deleted",
				status = string.format("Sensor deleted in Hue since %s; re-link or Forget", day(now)) }, c4.sent[2].params)
			assert.same({ { text = string.format("Hue motion sensor 1 (motion sensor, device 2001, gone since %s)", day(now)),
				value = "2001" } }, D:picker_relink_devices())
			assert.equal("Hue motion sensor 1 (motion sensor, device 2001) gone", D:picker_forget_devices()[1].text)
		end)

		it("A3: an area deleted in Hue", function()
			add_both()
			feed("area_deleted")
			assert.equal("gone", D:entry(M.area).state)
			assert.equal("deleted", states(2002)[1].ended)
			assert.equal("Area deleted in Hue since " .. day(now) .. "; re-link or Forget", states(2002)[1].status)
			assert.equal("linked", D:entry(M.devices.hallway).state)
		end)

		it("C17: forgotten: the deliberate end, HUE_MOTION_FORGOTTEN, unbound; refused at its hello until Link Devices",
			function()
			add_both()
			local ok, text = D:forget(2001)
			assert.is_true(ok)
			assert.equal("Forgot Hallway sensor (device 2001): unbound and left in the project for you to delete; the Hue "
				.. "motion sensor is listed under Add Motion Sensor again", text)
			assert.same({ "HUE_MOTION_STATE@2001", "HUE_MOTION_FORGOTTEN@2001" }, commands())
			assert.same({ rid = M.devices.hallway, reason = "event", online = "false", ended = "forgotten",
				status = "Forgotten by the bridge (was Hue motion sensor Hallway sensor)" }, c4.sent[1].params)
			assert.same({ rid = M.devices.hallway, name = "Hallway sensor" }, c4.sent[2].params)
			assert.same({ { 2001, 1 } }, c4.calls_to("Unbind"))
			assert.same({ "Hallway sensor [Hallway] #12", "Porch sensor #20" }, texts(D:picker_sensors()))
			assert.is_not_nil(c4.persist.hue_motion_forgotten["2001"])
			local _, area_text = D:forget(2002)
			assert.equal("Forgot Kitchen motion area (device 2002): unbound and left in the project for you to delete; the "
				.. "MotionAware area is listed under Add Motion Area again", area_text)

			-- Bound again by the owner: its hello is refused, told again, never adopted.
			C4:Bind(15, 1, 2001, 1, "HUE_BRIDGE")
			c4.sent = {}
			assert.is_false(D:hello({ rid = M.devices.hallway, device_id = "2001", kind = "sensor", name = "Hallway sensor" }))
			assert.same({ "HUE_MOTION_FORGOTTEN@2001" }, commands())
			assert.is_nil(D:entry(M.devices.hallway))
			assert.is_true(saw_log("but Forget let it go on"))
			-- Link Devices is the way back, by the rid it had.
			assert.equal("Linked 1 motion device: Hallway sensor (device 2001) to Hallway sensor [Hallway] #12 by its rid",
				D:link_devices())
			assert.equal(2001, D:entry(M.devices.hallway).device_id)
			assert.is_nil(D.forgotten[2001])
		end)

		it("C11: unbound from the bridge: the entry is unbound and listed; bound again, it hears its state", function()
			add_both()
			assert.is_true(D:on_binding_changed(1, "HUE_BRIDGE", false, 2001))
			assert.equal("unbound", D:entry(M.devices.hallway).state)
			assert.same({}, c4.sent, "the device ends its motion itself (§2.7)")
			assert.is_true(has_item(attention(), "1 unbound motion device: Hallway sensor (device 2001) (bind it to this "
				.. "bridge in Composer, or Forget Motion Device)"))
			feed("e1")
			assert.same({}, c4.sent, "an unbound device is not told")
			assert.is_true(D:on_binding_changed(1, "HUE_BRIDGE", true, 2001))
			assert.same({ "HUE_MOTION_CONFIGURE@2001", "HUE_MOTION_STATE@2001" }, commands())
			assert.equal("hello", states(2001)[1].reason)
			assert.equal("true", states(2001)[1].motion)
		end)
	end)

	describe("events", function()
		it("E1, E2: motion and no motion go out alone, with the bridge's time", function()
			add_both()
			assert.equal(1, feed("e1"))
			assert.same({ { rid = M.devices.hallway, reason = "event", motion = "true", motion_changed = M.changed.e1 } },
				states(2001))
			c4.sent = {}
			assert.equal(1, feed("e2"))
			assert.same({ { rid = M.devices.hallway, reason = "event", motion = "false", motion_changed = M.changed.e2 } },
				states(2001))
			assert.same({}, states(2002), "grouped motion is not this module's (D13)")
		end)

		it("E3, E4, E12: light level, temperature and battery go out on their own; S8: a low battery in Attention at once",
			function()
			add_both()
			D:add(M.devices.porch, PORCH, done)
			c4.sent = {}
			feed("e3")
			assert.same({ { rid = M.devices.hallway, reason = "event", lux = "126" } }, states(2001))
			feed("e4")
			assert.same({ { rid = M.devices.porch, reason = "event", temperature = "14.88" } }, states(2003))
			feed("e12")
			assert.same({ rid = M.devices.hallway, reason = "event", battery_level = "9", battery_state = "low" },
				states(2001)[2])
			assert.is_true(has_item(attention(), "1 motion sensor battery low: Hallway sensor 9 %"))
			feed(container("update", '{"id":"' .. M.device_power.porch .. '","owner":{"rid":"' .. M.devices.porch
				.. '","rtype":"device"},"power_state":{"battery_level":2,"battery_state":"critical"},"type":"device_power"}'))
			assert.is_true(has_item(attention(), "1 motion sensor battery critical: Porch sensor 2 %"))
		end)

		it("S12, E7, A10, A4: sensitivity, an area's settings and its lights changed send nothing", function()
			add_both()
			assert.equal(0, feed("e7_raised"))
			assert.equal(0, feed("e7_set"))
			assert.equal(0, feed(container("update", '{"id":"' .. M.convenience .. '","owner":{"rid":"' .. M.area
				.. '","rtype":"motion_area_configuration"},"sensitivity":{"sensitivity":3},"type":"convenience_area_motion"}')))
			assert.equal(0, feed(container("update", '{"id":"' .. M.area .. '","participants":[{"resource":{"rid":"'
				.. M.candidates[1] .. '","rtype":"motion_area_candidate"},"status":{"health":"healthy"}},{"resource":{"rid":"'
				.. M.candidates[4] .. '","rtype":"motion_area_candidate"},"status":{"health":"healthy"}}],'
				.. '"type":"motion_area_configuration"}')))
			assert.equal(0, feed(container("update", '{"id":"' .. M.lights.lamp .. '","on":{"on":true},"owner":{"rid":"'
				.. M.devices.lamp .. '","rtype":"device"},"type":"light"}')))
			assert.same({}, c4.sent)
			assert.equal(M.area, D:registered_rids()[2], "A4: the key does not change")
		end)

		it("A2: an area renamed in Hue: CONFIGURE carries the new name, Composer's is kept", function()
			add_both()
			feed(container("update", '{"id":"' .. M.area .. '","name":"Kitchen island","type":"motion_area_configuration"}'))
			assert.same({ "HUE_MOTION_CONFIGURE@2002" }, commands())
			assert.equal("Kitchen island", c4.sent[1].params.name)
			assert.is_true(has_item(attention(), "1 motion device name differs from the Composer names: Kitchen motion area "
				.. "is Kitchen island in Hue (Adopt Hue Names or Accept Names As They Are)"))
		end)

		it("S13: a sensor without some services: their rows are not offered, Online is unknown rather than false", function()
			local plain = "0f000000-0000-4000-8000-000000000001"
			L.devices[plain] = { name = "Garden PIR", model = "PIR-9", model_id = "PIR-9", light_rids = {} }
			resync({ motion = body(motion_json("hallway", false, M.changed.hallway_motion),
				string.format('{"id":"0a000000-0000-4000-8000-000000000001","owner":{"rid":"%s","rtype":"device"},'
					.. '"enabled":true,"motion":{"motion":true,"motion_report":{"changed":"%s","motion":true}},"type":"motion"}',
					plain, M.changed.e1)) })
			D:add(plain, PORCH, done)
			assert.equal("Added Garden PIR to Porch (device 2001)", last_result().text)
			assert.same({ rid = plain, kind = "sensor", name = "Garden PIR", model = "PIR-9", gone = "false",
				has_light_level = "false", has_temperature = "false", has_battery = "false" },
				sent_to(2001, "HUE_MOTION_CONFIGURE")[1])
			assert.same({ rid = plain, reason = "resync", enabled = "true", motion = "true", motion_changed = M.changed.e1 },
				states(2001)[1], "R5: motion already active at the start goes out as it is")
		end)

		it("E8, A9: an area's motion is its live service's; used for security, the other service's once it reports",
			function()
			add_both()
			feed("e8_motion")
			assert.same({ { rid = M.area, reason = "event", motion = "true", motion_changed = M.changed.e8_motion } },
				states(2002))
			feed("e8_clear")
			assert.equal("false", states(2002)[2].motion)
			c4.sent = {}
			feed("area_security")
			assert.same({ { rid = M.area, reason = "event", motion = "true", motion_changed = "2026-10-26T07:34:59.120Z" } },
				states(2002))
			c4.sent = {}
			feed(container("update", area_service_json("convenience_area_motion", M.convenience, false,
				"2026-10-26T07:20:00.000Z")))
			assert.same({}, c4.sent, "an older report of the frozen service changes nothing")
		end)

		it("R6: a resync GET older than an event already applied changes nothing", function()
			add_both()
			feed("e1")
			c4.sent = {}
			resync()
			assert.equal("true", states(2001)[1].motion)
			assert.equal(M.changed.e1, states(2001)[1].motion_changed)
			assert.is_false(saw_log("missed while the stream was down"))
		end)

		it("R6 without times (old firmware): an event that arrived after the GET was sent beats it", function()
			add_both()
			D:resync(done)
			local first = unanswered()[1]
			assert.truthy(first.url:find("/resource/motion$"))
			feed(container("update", motion_json("hallway", true, nil)))
			first:respond(200, body(motion_json("hallway", false, nil), motion_json("porch", false, nil)))
			answer()
			assert.equal("true", states(2001)[#states(2001)].motion)
		end)

		it("R1: a state that changed while the stream was down goes out at the resync and is logged", function()
			add_both()
			feed("e1")
			c4.sent = {}
			resync({ motion = body(motion_json("hallway", false, "2026-10-26T07:20:00.000Z"),
				motion_json("porch", false, M.changed.porch_motion)) })
			assert.equal("false", states(2001)[1].motion)
			assert.is_true(saw_log("motion: Hallway sensor: no motion since 07:20:00 UTC (missed while the stream was down)"))
		end)

		it("R2, D8: an episode missed while the stream was down is logged, never replayed", function()
			add_both()
			resync({ motion = body(motion_json("hallway", false, "2026-10-26T07:40:00.000Z"),
				motion_json("porch", false, M.changed.porch_motion)) })
			assert.same({ rid = M.devices.hallway, reason = "resync", online = "true", enabled = "true", motion = "false",
				motion_changed = "2026-10-26T07:40:00.000Z", lux = "63", temperature = "21.37", battery_level = "87",
				battery_state = "normal" }, states(2001)[1], "the same value: no pulse")
			assert.is_true(saw_log("motion: Hallway sensor: a motion at 07:40:00 UTC (bridge time) was missed while the "
				.. "stream was down"))
		end)

		it("S1, A1, E10: a new sensor is logged once, listed in Attention and in the picker, never added on its own",
			function()
			resync()
			feed("e10")
			feed("e10")
			assert.equal(1, count_log("motion: new motion sensor Hue motion sensor 1 #30 on the bridge; use Add Motion Sensor"))
			assert.same({}, c4.added)
			assert.is_true(has_item(attention(), "3 new motion sensors on the bridge: Hallway sensor [Hallway] #12, Hue motion "
				.. "sensor 1 #30, Porch sensor #20 (Add Motion Sensor)"))
			assert.same({ "Hallway sensor [Hallway] #12", "Hue motion sensor 1 #30", "Porch sensor #20" },
				texts(D:picker_sensors()))
			feed("e11")
			assert.same({ "Hallway sensor [Hallway] #12", "Porch sensor #20" }, texts(D:picker_sensors()))
			assert.is_true(has_item(attention(), "1 new motion area on the bridge: Kitchen motion area (MotionAware) [Kitchen] "
				.. "#ac00 (Add Motion Area)"))
		end)

		it("S2: renamed in Hue: CONFIGURE carries the new name, Composer's is kept and listed until adopted or accepted",
			function()
			add_both()
			feed(container("update", '{"id":"' .. M.devices.hallway .. '","metadata":{"name":"Front hall sensor"},'
				.. '"type":"device"}'))
			assert.equal("Front hall sensor", sent_to(2001, "HUE_MOTION_CONFIGURE")[1].name)
			assert.equal("Front hall sensor", D:entry(M.devices.hallway).name)
			assert.same({}, c4.renamed)
			assert.is_true(has_item(attention(), "1 motion device name differs from the Composer names: Hallway sensor is "
				.. "Front hall sensor in Hue (Adopt Hue Names or Accept Names As They Are)"))
			assert.equal("Accepted 1 motion device name difference: Hallway sensor (Hue: Front hall sensor)",
				D:accept_names())
			assert.is_false(has_item(attention(), "1 motion device name differs from the Composer names: Hallway sensor is "
				.. "Front hall sensor in Hue (Adopt Hue Names or Accept Names As They Are)"))
			assert.equal("not renamed 1: Hallway sensor (device 2001): no proxy id known", D:adopt_hue_names())
		end)

		it("S3, A14, A8: a moved sensor's and a deleted room's Hue Room follow; the area keeps reporting", function()
			add_both()
			feed(hallway_children(M.devices.lamp))
			assert.is_nil(sent_to(2001, "HUE_MOTION_CONFIGURE")[1].hue_room, "the sensor left the Hallway room")
			assert.is_nil(D:entry(M.devices.hallway).hue_room)
			feed(hallway_children(M.devices.lamp, M.devices.hallway))
			assert.equal("Hallway", sent_to(2001, "HUE_MOTION_CONFIGURE")[2].hue_room)
			c4.sent = {}
			feed(container("delete", '{"id":"' .. M.rooms.kitchen .. '","type":"room"}'))
			assert.equal("Kitchen (deleted in Hue)", sent_to(2002, "HUE_MOTION_CONFIGURE")[1].hue_room)
			assert.equal("linked", D:entry(M.area).state)
			feed("e8_motion")
			assert.equal("true", states(2002)[1].motion)
		end)

		it("A16: a configuration served in part: its label falls back, its motion still comes from the services", function()
			resync({ motion_area_configuration = M.motion_area_configuration_partial })
			assert.same({ "MotionAware area #ac00" }, texts(D:picker_areas()))
			D:add(M.area, nil, done)
			assert.equal("Not added: MotionAware area #ac00: Hue names no room or zone for it; pick a room, or Set Room "
				.. "Mapping first", last_result().text)
			D:add(M.area, KITCHEN, done)
			assert.equal("Added MotionAware area #ac00 to Kitchen (device 2001)", last_result().text)
			assert.same({ rid = M.area, kind = "area", name = "MotionAware area #ac00", model = "MotionAware area",
				gone = "false", has_light_level = "false", has_temperature = "false", has_battery = "false" },
				sent_to(2001, "HUE_MOTION_CONFIGURE")[1])
			assert.same({ rid = M.area, reason = "resync", online = "true", enabled = "true", motion = "false",
				motion_changed = M.changed.convenience, status = "Hue reports this area only in part; update the bridge" },
				states(2001)[1])
			-- The full shape later: the name and room arrive, nothing was gone meanwhile.
			c4.sent = {}
			resync()
			assert.equal("Kitchen motion area", sent_to(2001, "HUE_MOTION_CONFIGURE")[1].name)
			assert.is_nil(states(2001)[1].status)
		end)
	end)

	describe("the stuck-motion check (D9, R3)", function()
		local function motion_body_at(value, changed)
			return body(motion_json("hallway", value, changed))
		end

		it("runs only while a device shows motion: one GET after 5 minutes without news, again every 5, none after",
			function()
			add_both()
			assert.same({}, active_timers(), "nothing shows motion: no timer")
			feed("e1")
			assert.equal(1, #active_timers(TICK))
			now = T0 + 60
			fire(TICK)
			assert.equal(0, #unanswered(), "not due yet")
			assert.equal(1, #active_timers(TICK), "armed again")
			now = T0 + 300
			fire(TICK)
			local open = unanswered()
			assert.equal(1, #open)
			assert.equal("https://192.0.2.10/clip/v2/resource/motion/" .. M.motion.hallway, open[1].url)
			c4.sent = {}
			open[1]:respond(200, motion_body_at(true, M.changed.e1))
			assert.same({}, c4.sent, "still on: nothing changed")
			now = T0 + 540
			fire(TICK)
			assert.equal(0, #unanswered(), "5 minutes from the last check")
			now = T0 + 600
			fire(TICK)
			open = unanswered()
			assert.equal(1, #open)
			open[1]:respond(200, motion_body_at(false, "2026-10-26T07:20:30.000Z"))
			assert.same({ { rid = M.devices.hallway, reason = "check", motion = "false",
				motion_changed = "2026-10-26T07:20:30.000Z" } }, states(2001))
			now = T0 + 660
			fire(TICK)
			assert.same({}, active_timers(), "no device shows motion: the timer is dropped")
		end)

		it("an area's check GETs its configuration and its two services, one at a time", function()
			add_both()
			feed("e8_motion")
			now = T0 + 300
			fire(TICK)
			local seen = answer({
				["motion_area_configuration/" .. M.area] = M.motion_area_configuration,
				["convenience_area_motion/" .. M.convenience] = body(area_service_json("convenience_area_motion",
					M.convenience, false, "2026-10-26T07:31:00.000Z")),
				["security_area_motion/" .. M.security] = M.security_area_motion,
			})
			assert.same({ "motion_area_configuration/" .. M.area, "convenience_area_motion/" .. M.convenience,
				"security_area_motion/" .. M.security }, seen)
			assert.equal("false", states(2002)[#states(2002)].motion)
			assert.equal("check", states(2002)[#states(2002)].reason)
		end)

		it("a check the bridge does not answer says it is away; the next answer clears it", function()
			add_both()
			feed("e1")
			c4.sent = {}
			now = T0 + 300
			fire(TICK)
			answer({ ["motion/" .. M.motion.hallway] = { fail = true } })
			local away = string.format("Bridge not answering since %s; motion not current", clock(now))
			assert.same({ { rid = M.devices.hallway, reason = "event", status = away } }, states(2001))
			assert.equal(away, states(2002)[1].status)
			c4.sent = {}
			now = T0 + 600
			fire(TICK)
			answer({ ["motion/" .. M.motion.hallway] = motion_body_at(true, M.changed.e1) })
			assert.same({ { rid = M.devices.hallway, reason = "event" } }, states(2001))
			assert.same({ { rid = M.area, reason = "event" } }, states(2002))
		end)
	end)

	describe("hello (C5, C8, C19, D4)", function()
		it("C8: a bound device's hello with a rid the registry lacks is adopted with its kind", function()
			resync()
			local id = hand_added("Kitchen motion", KITCHEN)
			c4.sent = {}
			assert.is_true(D:hello({ rid = M.area, device_id = tostring(id), name = "Kitchen motion area", kind = "area",
				model = "MotionAware area" }))
			assert.equal(id, D:entry(M.area).device_id)
			assert.equal("area", D:entry(M.area).kind)
			assert.is_true(saw_log("motion: adopted Kitchen motion area (device " .. id .. ") from its own persisted rid"))
			assert.same({ "HUE_MOTION_CONFIGURE@" .. id, "HUE_MOTION_STATE@" .. id }, commands())
			assert.equal("hello", c4.sent[2].params.reason)
		end)

		it("D4: a device announcing the other kind than its rid's record is not adopted", function()
			resync()
			local id = hand_added("Kitchen motion", KITCHEN)
			assert.is_false(D:hello({ rid = M.area, device_id = tostring(id), kind = "sensor" }))
			assert.is_nil(D:entry(M.area))
			assert.is_false(D:hello({ rid = M.area, device_id = tostring(id), kind = "group" }))
		end)

		it("C5: two devices claiming one rid: neither adopted, Attention names them", function()
			add_both()
			local id = hand_added("Hallway sensor copy")
			assert.is_false(D:hello({ rid = M.devices.hallway, device_id = tostring(id), kind = "sensor" }))
			assert.equal(2001, D:entry(M.devices.hallway).device_id)
			assert.is_true(has_item(attention(), "2 devices claim Hue motion sensor Hallway sensor: 2001 and " .. id
				.. " (Forget Motion Device on one of them)"))
		end)

		it("C19: a registered device's hello (the driver updated in place) is answered in full", function()
			add_both()
			assert.is_true(D:hello({ rid = M.devices.hallway, device_id = "2001", kind = "sensor" }))
			assert.same({ "HUE_MOTION_CONFIGURE@2001", "HUE_MOTION_STATE@2001" }, commands())
			assert.equal("hello", states(2001)[1].reason)
			c4.sent = {}
			assert.is_true(D:hello({ rid = "", device_id = "2002" }), "a device that lost its rid hears its own")
			assert.equal(M.area, sent_to(2002, "HUE_MOTION_CONFIGURE")[1].rid)
		end)
	end)

	describe("relink (D4, S4, S6, A13, B1)", function()
		it("B1, B3: a bridge replaced or reset: entries whose rids left go gone, the new resources are hinted, nothing "
			.. "is matched on its own", function()
			add_both()
			local new_area = "ac000000-0000-4000-8000-000000000009"
			-- The hallway sensor and the area under new rids, as a bridge that
			-- did not keep them would list them (the sensor's radio is the same).
			local function moved(text)
				local out = text:gsub(M.devices.hallway:gsub("%W", "%%%0"), NEW.device)
				return (out:gsub(M.area:gsub("%W", "%%%0"), new_area))
			end
			L = new_lights({ device = moved(M.device), zigbee = moved(M.zigbee_connectivity), room = moved(M.room) })
			D.ctx.lights = L
			resync({ motion = moved(M.motion_body), light_level = moved(M.light_level_body),
				temperature = moved(M.temperature_body), device_power = moved(M.device_power_body),
				zigbee_connectivity = moved(M.zigbee_connectivity),
				motion_area_configuration = moved(M.motion_area_configuration),
				convenience_area_motion = moved(M.convenience_area_motion), security_area_motion = moved(M.security_area_motion) })
			assert.equal("gone", D:entry(M.devices.hallway).state)
			assert.equal("gone", D:entry(M.area).state)
			assert.same({ "Hallway sensor [Hallway] #12 (same radio as Hallway sensor, device 2001; re-link?)",
				"Porch sensor #20" }, texts(D:picker_sensors()))
			assert.same({ "Kitchen motion area (MotionAware) [Kitchen] #ac00 (looks like Kitchen motion area, device 2002; "
				.. "re-link?)" }, texts(D:picker_areas()))
			assert.equal(2, #c4.added, "nothing created")
			assert.same({ true, "Re-linked device 2001 (was Hallway sensor) to Hallway sensor [Hallway] #12" },
				{ D:relink(2001, NEW.device) })
		end)

		it("D4: refuses a change of kind", function()
			add_both()
			assert.same({ false, "Not re-linked: device 2001 is a motion sensor; pick a sensor" },
				{ D:relink(2001, M.area) })
			assert.same({ false, "Not re-linked: device 2002 is a motion area; pick an area" },
				{ D:relink(2002, M.devices.porch) })
			assert.same({ false, "Not re-linked: motion sensor or area nope is not on the bridge (connect the event stream "
				.. "and try again)" }, { D:relink(2001, "nope") })
		end)

		it("S6: a sensor deleted and paired again (same radio) is hinted; Re-link keeps the device", function()
			add_both()
			feed(container("delete", '{"id":"' .. M.motion.hallway .. '","type":"motion"}', '{"id":"' .. M.devices.hallway
				.. '","type":"device"}'))
			assert.equal("gone", D:entry(M.devices.hallway).state)
			feed(new_sensor_add("Hallway sensor", M.macs.hallway))
			local hinted = "Hallway sensor #31 (same radio as Hallway sensor, device 2001; re-link?)"
			assert.equal(hinted, D:picker_sensors()[1].text)
			assert.is_true(has_item(attention(), "2 new motion sensors on the bridge: " .. hinted
				.. ", Porch sensor #20 (Add Motion Sensor)"))
			assert.is_true(saw_log("motion: new motion sensor Hallway sensor #31 on the bridge; use Add Motion Sensor (same "
				.. "radio as Hallway sensor, device 2001; re-link?)"))
			c4.sent = {}
			assert.same({ true, "Re-linked device 2001 (was Hallway sensor) to Hallway sensor #31" },
				{ D:relink(2001, NEW.device) })
			assert.is_nil(D:entry(M.devices.hallway))
			assert.equal(2001, D:entry(NEW.device).device_id)
			assert.equal("linked", D:entry(NEW.device).state)
			assert.same({ "HUE_MOTION_CONFIGURE@2001", "HUE_MOTION_STATE@2001" }, commands())
			assert.equal(NEW.device, c4.sent[1].params.rid)
			assert.equal("/sensors/31", c4.sent[1].params.id_v1)
			assert.equal("false", c4.sent[2].params.motion)
		end)

		it("S4, S9: a sensor unreachable for an hour is a re-link source; the name hint needs the same Hue room",
			function()
			add_both()
			feed(container("update", '{"id":"' .. M.zigbee.hallway .. '","owner":{"rid":"' .. M.devices.hallway
				.. '","rtype":"device"},"status":"disconnected","type":"zigbee_connectivity"}'))
			feed(new_sensor_add("Hallway sensor", "00:17:88:01:0c:00:00:31-02"))
			assert.equal("Hallway sensor #31", D:picker_sensors()[1].text, "not yet an hour")
			assert.same({}, D:picker_relink_devices())
			now = T0 + 3600
			assert.equal("Hallway sensor #31", D:picker_sensors()[1].text, "another room (none): no name hint")
			feed(hallway_children(M.devices.lamp, M.devices.hallway, NEW.device))
			assert.equal("Hallway sensor [Hallway] #31 (looks like Hallway sensor, device 2001; re-link?)",
				D:picker_sensors()[1].text)
			assert.same({ { text = string.format("Hallway sensor (motion sensor, device 2001, not reachable since %s)", day(T0)),
				value = "2001" } }, D:picker_relink_devices())
			assert.is_true(has_item(attention(), "1 motion sensor not reachable for more than 1 h: Hallway sensor"))
		end)

		it("A13: a MotionAware area set up again under its name in its room is hinted", function()
			add_both()
			feed("area_deleted")
			local new_area = "ac000000-0000-4000-8000-000000000002"
			local item = json.encode(data(M.motion_area_configuration)[1])
			item = replace(item, M.area, new_area)
			item = replace(item, M.convenience, "ca000000-0000-4000-8000-000000000002")
			item = replace(item, M.security, "5a000000-0000-4000-8000-000000000002")
			feed(container("add", item))
			assert.equal("Kitchen motion area (MotionAware) [Kitchen] #ac00 (looks like Kitchen motion area, device 2002; "
				.. "re-link?)", D:picker_areas()[1].text)
			assert.same({ true, "Re-linked device 2002 (was Kitchen motion area) to Kitchen motion area (MotionAware) "
				.. "[Kitchen] #ac00" }, { D:relink(2002, new_area) })
		end)
	end)

	describe("link devices (S11, A11)", function()
		it("links a bound device that never said hello by its exact name", function()
			resync()
			hand_added("Porch sensor", PORCH)
			assert.equal("Linked 1 motion device: Porch sensor (device 2001) to Porch sensor #20 by name", D:link_devices())
			assert.equal(2001, D:entry(M.devices.porch).device_id)
			assert.equal("All 1 bound motion devices are registered", D:link_devices())
		end)

		it("S11: refuses a name two sensors share (default names repeat)", function()
			L.devices[M.devices.hallway].name = "Hue motion sensor 1"
			L.devices[M.devices.porch].name = "Hue motion sensor 1"
			resync()
			local id = hand_added("Hue motion sensor 1")
			assert.equal("not linked 1: Hue motion sensor 1 (device " .. id .. "): 2 unimported Hue motion sensors or areas "
				.. "have that name; rename the device in Composer to one sensor's or area's exact name and run Link Devices "
				.. "again", D:link_devices())
			assert.same({}, D:registered_rids())
		end)

		it("leaves the devices it is told to skip and other drivers' devices alone", function()
			resync()
			local id = hand_added("Porch sensor", PORCH)
			C4:AddDevice("hue_light.c4z", HALL, "Porch sensor", function() end)
			C4:Bind(15, 1, 2002, 1, "HUE_BRIDGE")
			assert.equal("No motion devices are bound to this bridge", D:link_devices({ id }))
			assert.equal("Linked 1 motion device: Porch sensor (device 2001) to Porch sensor #20 by name",
				D:link_devices({ [9999] = true }))
		end)
	end)

	describe("attention, summary and lists", function()
		it("orders the items: new, missing, unbound, claims, names, then batteries and the sensors' and areas' states",
			function()
			add_both()
			D:add(M.devices.porch, PORCH, done)
			feed(container("update", motion_json("porch", true, "2026-10-26T07:19:00.000Z")))
			feed("e5")
			feed("e12")
			now = T0 + 3600
			assert.same({
				"1 motion sensor battery low: Hallway sensor 9 %",
				"1 motion sensor not reachable for more than 1 h: Porch sensor (still showing motion)",
			}, attention())
			feed("e9_paused")
			D:on_binding_changed(1, "HUE_BRIDGE", false, 2001)
			assert.same({
				"1 unbound motion device: Hallway sensor (device 2001) (bind it to this bridge in Composer, or Forget Motion "
					.. "Device)",
				"1 motion sensor not reachable for more than 1 h: Porch sensor (still showing motion)",
				"1 motion area paused in the Hue app: Kitchen motion area",
			}, attention(), "an unbound device's battery is not watched")
		end)

		it("summarises the bridge and lists every sensor and area with its device", function()
			add_both()
			D:goodbye({ device_id = "2002" })
			D:add(M.devices.porch, PORCH, done)
			D:on_binding_changed(1, "HUE_BRIDGE", false, 2003)
			assert.equal("2 sensors and 1 area on the bridge; 2 added, 1 unbound, 1 deleted", D:summary())
			assert.same({
				"Hallway sensor [Hallway] #12 → device 2001",
				"Porch sensor #20 (unbound; device 2003)",
				string.format("Kitchen motion area (MotionAware) [Kitchen] #ac00 (deleted from Composer %s)", date(T0)),
			}, D:list_items())
			feed("area_deleted")
			L.devices[M.devices.hallway] = nil
			feed(container("delete", '{"id":"' .. M.devices.hallway .. '","type":"device"}'))
			assert.same({
				"Porch sensor #20 (unbound; device 2003)",
				"Hallway sensor (motion sensor) (missing; device 2001)",
			}, D:list_items())
		end)

		it("keeps commas out of the comma-delimited lists", function()
			resync()
			L.devices[M.devices.porch].name = "Porch, front"
			D:rebuild()
			assert.same({ "Hallway sensor [Hallway] #12", "Porch  front #20" }, texts(D:picker_sensors()))
			assert.equal("Porch  front #20", D:list_items()[2])
			for _, item in ipairs(D:list_items()) do
				assert.is_nil(item:find(",", 1, true))
			end
		end)
	end)
end)
