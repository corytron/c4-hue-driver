-- End to end for a zone light on the two-driver harness
-- (docs/zone-light-design.md): the bridge side is bridge.zone_lights with
-- the real group queue (bridge.commands) on a fake bridge runtime, routed as
-- driver.lua routes it; the device side is the real Hue Light driver. Add
-- Zone Light creates the device in the zone's mapped room, its hello is
-- answered with kind "group", ON is one absolute grouped_light PUT, a hold
-- is dimming_delta start and stop, OFF is one group off, a zone deleted in
-- Hue leaves the device gone, a re-link moves it to a room, and deleting
-- the device in Composer leaves a tombstone that Add Zone Light clears.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local json = require("dkjson")
local F = require("fixtures.hue_resources")

local LIVING_ROOM, GARAGE_ROOM = 7, 8
local DEVICE_ID = 2001 -- the first id the fake's AddDevice hands out
local BRIDGE_ID = 15
local T0 = 1761000000
local GROUPED = "https://192.0.2.10/clip/v2/resource/grouped_light/"

local function proxy_calls(env, command)
	local out = {}
	for _, args in ipairs(env.C4.calls_to("SendToProxy")) do
		if args[2] == command then out[#out + 1] = args[3] end
	end
	return out
end

local function messages_to(c4, id)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.id == id then out[#out + 1] = m.command end
	end
	return out
end

local function sent_params(c4, command)
	for _, m in ipairs(c4.sent) do
		if m.command == command then return m.params end
	end
end

describe("zone light round trip: add, hello, on, hold, off, deleted in Hue, re-link, deleted in Composer", function()
	local bridge, light, bc4, L, Z, Q, now, last_hello

	local function http_ctx(req, cb)
		req.ip = "192.0.2.10"
		req.key = "k"
		return require("bridge.http").request(req, cb)
	end

	local function decode_data(text)
		return json.decode(text).data
	end

	local function answer_grouped_light_get()
		local t = bc4.last_transfer()
		assert.equal("https://192.0.2.10/clip/v2/resource/grouped_light", t.url)
		fake.as(bridge, function() t:respond(200, F.grouped_light) end)
	end

	-- Every container of a recorded event, lights first (the groups cache),
	-- then the zone lights, as driver.lua orders them.
	local function event(text)
		fake.as(bridge, function()
			for _, container in ipairs(bridge.C4:JsonDecode(text)) do
				L:on_container(container)
				Z:on_container(container)
			end
		end)
	end

	-- The group queue's debounce timer, then the PUT it sends.
	local function flush_put()
		fake.as(bridge, function() bc4.fire_timers() end)
		local put = bc4.last_transfer()
		assert.equal("PUT", put.method)
		return put, json.decode(put.data)
	end

	local function answer_put(put)
		fake.as(bridge, function() put:respond(200, '{"data":[],"errors":[]}') end)
	end

	before_each(function()
		log.sink = function() end
		now = T0

		light = fake.load_driver("hue_light", {}, { device_id = DEVICE_ID })
		local env
		bc4, env = fake.install_c4()
		bridge = env
		fake.add_room(GARAGE_ROOM, "Garage")
		log.set_prefix("Hue Bridge")

		for _, m in ipairs({ "bridge.http", "bridge.hue_model", "bridge.registry", "bridge.groups", "bridge.lights",
			"bridge.commands", "bridge.zone_lights" }) do
			package.loaded[m] = nil
		end
		local lights = require("bridge.lights")
		local commands = require("bridge.commands")
		local zone_lights = require("bridge.zone_lights")
		L = lights.new({ http = http_ctx, now = function() return now end })
		L:absorb({ light = decode_data(F.light), device = decode_data(F.device), room = decode_data(F.room),
			zone = decode_data(F.zone), bridge_home = decode_data(F.bridge_home) })
		L.reg:set_room_mapping(F.group_rids.downstairs, { c4_room_id = GARAGE_ROOM, c4_room_name = "Garage",
			hue_name = "Downstairs", type = "zone" })
		L.reg:set_room_mapping(F.group_rids.living_room, { c4_room_id = LIVING_ROOM, c4_room_name = "Living Room",
			hue_name = "Living Room", type = "room" })
		-- The grouped_light queue as driver.lua creates it (Decision 9).
		Q = commands.new({
			rate_per_sec = 1,
			burst = 3,
			send = function(rid, body, done)
				http_ctx({ method = "PUT", path = "/clip/v2/resource/grouped_light/" .. rid, body = body }, done)
			end,
		})
		Z = zone_lights.new({
			http = http_ctx,
			now = function() return now end,
			lights = L,
			-- As driver.lua's group_set hook: the zone's limits go to the queue
			-- first (issue #58, docs/zone-light-design.md Decision 7).
			group_set = function(rid, fields)
				local limits = Z:limits(rid)
				if limits then
					Q:limits(rid, limits)
				end
				Q:set(rid, fields)
				return true
			end,
			group_dim = function(rid, body, level)
				Q:set(rid, {
					dim = body.dimming_delta.action,
					delta = body.dimming_delta.brightness_delta,
					rate = type(body.dynamics) == "table" and body.dynamics.duration or nil,
					level = tonumber(level),
				})
				return true
			end,
		})
		Z:load()

		-- What driver.lua does with a zone light's messages.
		bridge.ExecuteCommand = function(command, params)
			if command == "HUE_HELLO" then
				last_hello = params
				Z:hello(params)
			elseif command == "HUE_SET" then
				Z:set(params)
			elseif command == "HUE_DIM" then
				Z:dim(params)
			elseif command == "HUE_GOODBYE" then
				Z:goodbye(params)
			elseif command == "HUE_FORGET" then
				Z:forget_request(params)
			end
		end
		bridge.OnBindingChanged = function(binding, class, bound, other)
			Z:on_binding_changed(binding, class, bound, other)
		end
	end)

	it("runs the whole loop", function()
		-- The resync reads the groups' on/off and levels; nothing is created.
		Z:resync()
		answer_grouped_light_get()
		assert.equal("2 zones + 2 rooms on bridge, 0 imported, 3 new", Z:summary())
		assert.equal(0, #bc4.added)

		-- Add Zone Light for Downstairs with "(mapped room)": one AddDevice
		-- into the zone's mapped room, bound, registered, configured as a
		-- group of two lights and told its state.
		local results = {}
		Z:add(F.group_rids.downstairs, nil, function(ok, text) results[#results + 1] = { ok, text } end)
		assert.same({ { true, "Added Downstairs (zone) to Garage (device 2001)" } }, results)
		assert.same({ { id = DEVICE_ID, driver = "hue_light.c4z", room = GARAGE_ROOM, name = "Downstairs" } }, bc4.added)
		assert.equal(1, #bc4.bindings)
		assert.same({ "HUE_CONFIGURE", "HUE_STATE" }, messages_to(bc4, DEVICE_ID))
		local conf = sent_params(bc4, "HUE_CONFIGURE")
		assert.equal("group", conf.kind)
		assert.equal("zone", conf.group_type)
		assert.equal("2", conf.light_count)
		assert.equal("false", conf.no_lights)
		assert.equal("Hue zone", conf.model)
		assert.equal("Downstairs (zone)", conf.hue_room)
		local st = sent_params(bc4, "HUE_STATE")
		assert.equal("true", st.on)
		assert.equal("73.52", st.brightness)
		assert.equal("2 zones + 2 rooms on bridge, 1 imported, 2 new", Z:summary())
		assert.equal(GARAGE_ROOM, fake.project.devices[DEVICE_ID].room_id)

		-- A second Add for the same zone is refused.
		results = {}
		Z:add(F.group_rids.downstairs, nil, function(ok, text) results[#results + 1] = { ok, text } end)
		assert.same({ { false, "Not added: Downstairs (zone) is already imported (device 2001)" } }, results)

		-- Now the device is the real Hue Light driver, bound to this bridge:
		-- its hello (no rid persisted yet) is answered from the device id and
		-- it learns it is a zone light.
		fake.pair(bridge, light, { light_id = DEVICE_ID, bind = false })
		assert.equal(BRIDGE_ID, light.C4:GetBoundProviderDevice(DEVICE_ID, 1))
		fake.as(light, light.OnDriverLateInit, "DIT_STARTUP")
		bc4.sent = {}
		assert.is_true(fake.pump() >= 3, "hello, then configure and state back")
		assert.same({ "HUE_CONFIGURE", "HUE_STATE" }, messages_to(bc4, DEVICE_ID))
		assert.equal("hello", sent_params(bc4, "HUE_STATE").reason)
		assert.equal("Hue zone Downstairs (2 lights)", light.Properties["Status"])
		assert.equal("Hue zone (2 lights)", light.Properties["Model"])
		assert.equal("Downstairs (zone)", light.Properties["Hue Room"])
		assert.equal("Online", light.Properties["Online"])
		assert.equal("group", light.C4.persist.hue_kind, "the kind survives a restart")
		assert.equal(F.group_rids.downstairs, light.C4.persist.hue_rid)
		local br = proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED")
		assert.is_true(#br >= 1)
		assert.equal(74, br[#br].LIGHT_BRIGHTNESS_CURRENT, "the group's average, rounded")

		-- A restart of the device: the hello now carries the kind.
		bc4.sent = {}
		fake.as(light, light.OnDriverLateInit, "DIT_STARTUP")
		fake.pump()
		assert.equal("group", last_hello.kind)

		-- ON from the proxy: HUE_SET to the bridge, one absolute PUT on the
		-- zone's grouped_light (Decision 4: on at 100 %).
		light.C4.calls = {}
		bc4.sent = {}
		local before = #bc4.transfers
		fake.as(light, light.ReceivedFromProxy, 5001, "ON", {})
		assert.is_true(fake.pump() >= 1, "HUE_SET reached the bridge")
		local put, body = flush_put()
		assert.equal(before + 1, #bc4.transfers, "exactly one PUT")
		assert.equal(GROUPED .. F.grouped_light_rids.downstairs, put.url)
		assert.same({ on = { on = true }, dimming = { brightness = 100 } }, body)
		answer_put(put)

		-- The grouped_light event closes the loop: HUE_STATE with the group's
		-- on and level, the tile follows.
		light.C4.calls = {}
		bc4.sent = {}
		event(F.events.zone_on)
		local state = sent_params(bc4, "HUE_STATE")
		assert.is_not_nil(state, "the event reaches the device")
		assert.equal("true", state.on)
		assert.equal("event", state.reason)
		fake.pump()
		br = proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED")
		assert.is_true(#br >= 1)
		assert.equal(math.floor(tonumber(state.brightness) + 0.5), br[#br].LIGHT_BRIGHTNESS_CURRENT)

		-- A keypad hold (HUE_DIM as the light driver sends it): the start is
		-- dimming_delta up over the whole range with the ramp, the stop is a
		-- stop; both go out at once (urgent, Decision 9).
		bc4.sent = {}
		before = #bc4.transfers
		bridge.ExecuteCommand("HUE_DIM", { rid = F.group_rids.downstairs, device_id = tostring(DEVICE_ID),
			direction = "up", duration = "5000" })
		put, body = flush_put()
		assert.equal(before + 1, #bc4.transfers)
		assert.equal(GROUPED .. F.grouped_light_rids.downstairs, put.url)
		assert.same({ dimming_delta = { action = "up", brightness_delta = 100 }, dynamics = { duration = 5000 } }, body)
		answer_put(put)
		bridge.ExecuteCommand("HUE_DIM", { rid = F.group_rids.downstairs, device_id = tostring(DEVICE_ID),
			direction = "stop", level = "60" })
		put, body = flush_put()
		assert.equal(before + 2, #bc4.transfers)
		assert.same({ dimming_delta = { action = "stop" } }, body)
		answer_put(put)

		-- OFF from the proxy: one group off.
		light.C4.calls = {}
		bc4.sent = {}
		before = #bc4.transfers
		fake.as(light, light.ReceivedFromProxy, 5001, "OFF", {})
		assert.is_true(fake.pump() >= 1)
		put, body = flush_put()
		assert.equal(before + 1, #bc4.transfers)
		assert.same({ on = { on = false } }, body)
		answer_put(put)
		event(F.events.zone_off)
		assert.equal("false", sent_params(bc4, "HUE_STATE").on)
		fake.pump()
		br = proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED")
		assert.equal(0, br[#br].LIGHT_BRIGHTNESS_CURRENT)

		-- The zone is deleted in the Hue app: the device stays, marked gone,
		-- its Status explains, the bridge counts it missing, ON is dropped.
		now = T0 + 3600
		light.C4.calls = {}
		bc4.sent = {}
		event(F.events.zone_deleted)
		assert.equal("gone", sent_params(bc4, "HUE_CONFIGURE").state)
		fake.pump()
		assert.equal("Zone deleted in Hue since " .. os.date("%Y-%m-%d", now) .. "; re-link or Forget",
			light.Properties["Status"])
		assert.equal("Offline", light.Properties["Online"])
		assert.equal("1 zone + 2 rooms on bridge, 1 imported, 2 new, 1 missing", Z:summary())
		assert.equal("1 zone light missing from the bridge: Downstairs (device 2001, since " .. os.date("%Y-%m-%d", now)
			.. ") (Re-link Zone Light or Forget Light)", Z:attention())
		bc4.sent = {}
		before = #bc4.transfers
		fake.as(light, light.ReceivedFromProxy, 5001, "ON", {})
		fake.pump()
		fake.as(bridge, function() bc4.fire_timers() end)
		assert.equal(before, #bc4.transfers, "nothing is sent for a gone zone")

		-- Re-link the device to the Garage room: the device, its programming
		-- and its Composer name stay; it is now a room light.
		bc4.sent = {}
		local ok, text = Z:relink(DEVICE_ID, F.group_rids.garage)
		assert.is_true(ok)
		assert.equal("Re-linked device 2001 (was Downstairs) to room Garage", text)
		fake.pump()
		assert.equal("Hue room Garage (1 light)", light.Properties["Status"])
		assert.equal(F.group_rids.garage, light.C4.persist.hue_rid)
		assert.equal("Downstairs", fake.project.devices[DEVICE_ID].name, "the Composer name is the owner's")
		assert.equal("1 zone light name differs from the Composer names: Downstairs is Garage Lights in Hue "
			.. "(Adopt Hue Names or Accept Names As They Are)", Z:attention())
		assert.truthy(Z:accept_names():find("^Accepted 1 zone light name difference"))
		assert.equal("None", Z:attention())

		-- Composer deletes the device: HUE_GOODBYE tombstones the entry; Add
		-- Zone Light lists it as deleted and re-creates it, clearing the tombstone.
		fake.delete_device(DEVICE_ID)
		assert.is_nil(bc4.persist.hue_zone_lights[F.group_rids.garage])
		assert.equal("Garage", bc4.persist.hue_zone_light_tombstones[F.group_rids.garage].name)
		assert.equal("1 zone + 2 rooms on bridge, 0 imported, 1 new, 1 deleted", Z:summary())
		local list = Z:picker_groups()
		assert.truthy(list[#list].text:find("^Garage %(room, 1 light%) %(deleted from Composer "))
		results = {}
		Z:add(F.group_rids.garage, GARAGE_ROOM, function(_, t) results[#results + 1] = t end)
		assert.equal("Added Garage (room) to Garage (device 2002)", results[1])
		assert.is_nil(bc4.persist.hue_zone_light_tombstones[F.group_rids.garage])
		assert.equal(2002, bc4.persist.hue_zone_lights[F.group_rids.garage].device_id)
		assert.equal("Garage Lights", bc4.added[2].name, "a room light is named <Room> Lights")
	end)

	-- Issue #58: the bridge clamps a zone light's colour temperature to the
	-- members' common range, as the device's own Kelvin range already does.
	it("clamps a colour temperature to the range the zone's members share", function()
		Z:resync()
		answer_grouped_light_get()
		Z:add(F.group_rids.downstairs, nil, function() end)
		bc4.sent = {}
		event(F.events.zone_children)  -- Hallway Ambiance (153-454) joins: the shared range is 153-454
		assert.equal("454", sent_params(bc4, "HUE_CONFIGURE").mirek_max, "the device's own range")
		-- Three PUTs fit the group queue's burst.
		local function set_mirek(mirek)
			bridge.ExecuteCommand("HUE_SET", { rid = F.group_rids.downstairs, device_id = tostring(DEVICE_ID),
				mirek = tostring(mirek) })
			local put, body = flush_put()
			assert.equal(GROUPED .. F.grouped_light_rids.downstairs, put.url)
			answer_put(put)
			return body.color_temperature.mirek
		end
		assert.equal(454, set_mirek(500), "a programming command beyond the shared range")
		assert.equal(153, set_mirek(100))
		assert.equal(300, set_mirek(300))
	end)
end)
