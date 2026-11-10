-- Control4 load groups end to end (#435, docs/load-groups-design.md §8.1
-- part D): the real Hue Bridge driver and three real Hue Light devices on
-- the fake runtime, wired as offline_roundtrip_spec.lua wires them (the
-- bridge loaded, paired and read; the lights added from it with Add From
-- Hue; SendToDevice routed between them; every clock moving together).
-- What a Control4 Load Group would send each member arrives through each
-- device's light_v2 proxy; what reaches Hue is read off the bridge's PUTs.
--
-- The fixture's groups (tests/fixtures/hue_resources.lua): Downstairs (zone)
-- = Garage White + Living Room Lamp; Living Room (room) = Hallway Ambiance +
-- Living Room Lamp; Garage (room) = Garage White alone. So a load group of
-- the Living Room Lamp and Garage White is the whole Downstairs zone, and
-- one of Garage White and Hallway Ambiance makes up no whole room or zone.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local json = require("dkjson")
local F = require("fixtures.hue_resources")

local BRIDGE_IP = "10.0.2.143"
local BRIDGE_HUE_ID = "001788fffe123abc"
local APP_KEY = "<key>"
local LIVING_ROOM = 7
-- The ids the fake's AddDevice hands out, in the order the lights are added.
local LAMP_ID, GARAGE_ID, HALLWAY_ID = 2001, 2002, 2003
local S = 1000
local EMPTY = '{"errors":[],"data":[]}'
local OK_PUT = '{"data":[],"errors":[]}'
local BRIDGE_PROPERTIES = { ["Event Stream Transport"] = "Web transfer", ["Bridge IP Address"] = BRIDGE_IP }
local LIGHT_URL = "https://" .. BRIDGE_IP .. "/clip/v2/resource/light/"
local GROUPED_URL = "https://" .. BRIDGE_IP .. "/clip/v2/resource/grouped_light/"

-- Two Control4 Load Group devices (their GROUP IDs).
local DOWNSTAIRS_GROUP, MIXED_GROUP = "4001", "4002"

local BODIES = {
	light = F.light, device = F.device, zigbee_connectivity = F.zigbee_connectivity,
	room = F.room, zone = F.zone, bridge_home = F.bridge_home,
	scene = EMPTY, smart_scene = EMPTY, grouped_light = F.grouped_light,
}

describe("load group round trip (#435)", function()
	local bridge, bc4, lamp, garage, hallway, devices, logged, world

	-- The bridge at BRIDGE_IP answers every transfer the bridge driver has
	-- open: the identity, the self-check, the stream (kept open), every
	-- resource GET, and every PUT (recorded in world.puts). Returns how many
	-- it answered.
	local function serve()
		local answered = 0
		for i = world.first, #bc4.transfers do
			local t = bc4.transfers[i]
			if not t.finished and not t.streaming then
				answered = answered + 1
				assert(answered < 2000, "the bridge driver keeps opening transfers: " .. tostring(t.url))
				fake.as(bridge, function()
					local path = t.url:match("^https://[^/]+(/.*)$") or t.url
					if path:find("^/eventstream/clip/v2") then
						t:respond_headers(200, {})
						t.streaming = true
					elseif path == "/api/0/config" then
						t.finished = true
						t:respond(200, '{"bridgeid":"' .. BRIDGE_HUE_ID:upper() .. '","modelid":"BSB003"}')
					elseif path == "/clip/v2/resource/bridge" then
						t.finished = true
						t:respond(200, '{"errors":[],"data":[{"bridge_id":"' .. BRIDGE_HUE_ID .. '"}]}')
					elseif t.method == "PUT" then
						t.finished = true
						world.puts[#world.puts + 1] = { url = t.url, data = t.data, at = bc4.now_ms }
						t:respond(200, OK_PUT)
					else
						local kind = assert(path:match("^/clip/v2/resource/([%w_]+)$"), "unexpected " .. t.method .. " "
							.. t.url)
						t.finished = true
						t:respond(200, BODIES[kind] or EMPTY)
					end
				end)
			end
		end
		while world.first <= #bc4.transfers
			and (bc4.transfers[world.first].finished or bc4.transfers[world.first].streaming) do
			world.first = world.first + 1
		end
		return answered
	end

	-- Until nothing moves: the bridge's transfers answered, every queued
	-- message delivered.
	local function settle()
		for _ = 1, 100 do
			if serve() + fake.pump() == 0 then
				return
			end
		end
		error("the drivers never settle")
	end

	-- `ms` of time for every driver, in steps of at most `step` ms, the
	-- network answering after each.
	local function tick(ms, step)
		step = step or 10
		local left = ms
		while left > 0 do
			local d = math.min(step, left)
			fake.as(bridge, function() bc4.advance(d) end)
			settle()
			for _, env in ipairs(devices) do
				fake.as(env, function() env.C4.advance(d) end)
			end
			settle()
			left = left - d
		end
	end

	local function action(name, params)
		params = params or {}
		params.ACTION = name
		fake.as(bridge, bridge.ExecuteCommand, "LUA_ACTION", params)
		settle()
		return fake.last_action(bridge)
	end

	-- A command from a device's proxy, and what it sends delivered at once.
	local function proxy(env, command, params)
		fake.as(env, env.ReceivedFromProxy, 5001, command, params or {})
		settle()
	end

	-- What a Load Group sends one member [assumed: each member through its
	-- own proxy, A2].
	local function group(env, command, id, params)
		local p = { GROUP_ID = id }
		for k, v in pairs(params or {}) do p[k] = v end
		proxy(env, command, p)
	end

	-- The light and grouped_light command PUTs since `mark` (an index into
	-- world.puts), as "light <rid>" / "grouped_light <rid>", and their bodies.
	local function puts_since(mark)
		local names, bodies = {}, {}
		for i = mark + 1, #world.puts do
			local put = world.puts[i]
			local kind = (put.url:find(LIGHT_URL, 1, true) == 1 and "light")
				or (put.url:find(GROUPED_URL, 1, true) == 1 and "grouped_light") or nil
			local body = kind and json.decode(put.data) or nil
			if body and body.metadata == nil then
				names[#names + 1] = kind .. " " .. put.url:match("([^/]+)$")
				bodies[#bodies + 1] = body
			end
		end
		return names, bodies
	end

	local function levels(env)
		local out = {}
		for _, args in ipairs(env.C4.calls_to("SendToProxy")) do
			if args[1] == 5001 and args[2] == "LIGHT_BRIGHTNESS_CHANGED" then
				out[#out + 1] = args[3].LIGHT_BRIGHTNESS_CURRENT
			end
		end
		return out
	end

	local function clear()
		bc4.sent = {}
		for _, env in ipairs(devices) do
			env.C4.calls, env.C4.sent = {}, {}
		end
	end

	-- The bridge as the house has it: loaded, paired, its first resync done,
	-- the three lights added from it and live.
	local function start()
		logged = {}
		log.sink = function(line) logged[#logged + 1] = line end
		lamp = fake.load_driver("hue_light", {}, { device_id = LAMP_ID })
		garage = fake.load_driver("hue_light", {}, { device_id = GARAGE_ID })
		hallway = fake.load_driver("hue_light", {}, { device_id = HALLWAY_ID })
		devices = { lamp, garage, hallway }
		bridge = fake.load_driver("hue_bridge", BRIDGE_PROPERTIES)
		bc4 = bridge.C4
		bc4.persist.hue_app_key = APP_KEY
		bc4.persist.hue_bridge_id = BRIDGE_HUE_ID
		world = { first = 1, puts = {} }

		fake.as(bridge, bridge.OnDriverLateInit, "DIT_STARTUP")
		settle()
		fake.as(bridge, function() bc4.advance(2500) end) -- the on_connected deferral, the resync's debounce
		settle()
		assert.equal("Paired", bridge.Properties["Status"])

		for _, env in ipairs(devices) do
			fake.pair(bridge, env, { light_id = env.C4.device_id, bind = false })
		end
		for _, key in ipairs({ "living", "garage", "hallway" }) do
			action("Add From Hue", { What = "light:" .. F.rids[key], Room = tostring(LIVING_ROOM) })
		end
		assert.same({ LAMP_ID, GARAGE_ID, HALLWAY_ID }, { bc4.added[1].id, bc4.added[2].id, bc4.added[3].id })
		assert.same({ F.names.living, F.names.garage, F.names.hallway },
			{ bc4.added[1].name, bc4.added[2].name, bc4.added[3].name })
		for _, env in ipairs(devices) do
			fake.as(env, env.OnDriverLateInit, "DIT_ADDING")
		end
		settle()
		tick(5 * S, S)
		clear()
	end

	before_each(function()
		start()
	end)

	-- common.dispatch and the modules' protect() turn a handler's error into
	-- an [ERROR] line instead of raising it: none may have been logged.
	after_each(function()
		log.sink = function() end
		log.set_debug(false)
		for _, line in ipairs(logged or {}) do
			assert.is_nil(line:find("[ERROR]", 1, true), line)
		end
	end)

	it("moves a load group that is a whole Hue zone with one grouped_light PUT, and others lamp by lamp", function()
		-- The dealer adds the Living Room Lamp and Garage White to one Load
		-- Group, Garage White and Hallway Ambiance to another (E1).
		group(lamp, "JOIN_GROUP", DOWNSTAIRS_GROUP, { KEEP_SYNC = "0" })
		group(garage, "JOIN_GROUP", DOWNSTAIRS_GROUP, { KEEP_SYNC = "0" })
		group(garage, "JOIN_GROUP", MIXED_GROUP, { KEEP_SYNC = "0" })
		group(hallway, "JOIN_GROUP", MIXED_GROUP, { KEEP_SYNC = "0" })
		assert.equal("device 4001 (not found), device 4002 (not found)", garage.Properties["Load Groups"])

		-- The Downstairs group to 40 %: each member sends its tagged HUE_SET,
		-- the batch closes at the second (every member known), and the
		-- members make up the whole Downstairs zone: one request (D7, D8).
		local mark = #world.puts
		group(lamp, "GROUP_SET_LEVEL", DOWNSTAIRS_GROUP, { LEVEL = "40" })
		group(garage, "GROUP_SET_LEVEL", DOWNSTAIRS_GROUP, { LEVEL = "40" })
		tick(200)
		local names, bodies = puts_since(mark)
		assert.same({ "grouped_light " .. F.grouped_light_rids.downstairs }, names)
		assert.equal(40, bodies[1].dimming.brightness)
		tick(2 * S, 100)
		assert.same({ "grouped_light " .. F.grouped_light_rids.downstairs }, (puts_since(mark)), "no lamp alone too")
		for _, env in ipairs({ lamp, garage }) do
			local all = levels(env)
			assert.equal(40, all[#all], "device " .. env.C4.device_id .. " hears the level")
		end

		-- The other group to 60 %: Garage White and Hallway Ambiance make up
		-- no whole room or zone, so each lamp gets its own PUT, in arrival
		-- order (D8 c).
		mark = #world.puts
		group(garage, "GROUP_SET_LEVEL", MIXED_GROUP, { LEVEL = "60" })
		group(hallway, "GROUP_SET_LEVEL", MIXED_GROUP, { LEVEL = "60" })
		tick(200)
		names, bodies = puts_since(mark)
		assert.same({ "light " .. F.rids.garage, "light " .. F.rids.hallway }, names)
		assert.equal(60, bodies[1].dimming.brightness)
		assert.equal(60, bodies[2].dimming.brightness)
	end)

	it("a member's own keypad stops only its own share of a group ramp (D11, D12)", function()
		group(lamp, "JOIN_GROUP", DOWNSTAIRS_GROUP, { KEEP_SYNC = "0" })
		group(garage, "JOIN_GROUP", DOWNSTAIRS_GROUP, { KEEP_SYNC = "0" })
		group(lamp, "GROUP_SET_LEVEL", DOWNSTAIRS_GROUP, { LEVEL = "40" })
		group(garage, "GROUP_SET_LEVEL", DOWNSTAIRS_GROUP, { LEVEL = "40" })
		tick(2 * S, 100)
		clear()

		-- The group ramps to 100 % over 4 s: one request for the zone.
		local mark = #world.puts
		group(lamp, "GROUP_RAMP_TO_LEVEL", DOWNSTAIRS_GROUP, { LEVEL = "100", TIME = "4000" })
		group(garage, "GROUP_RAMP_TO_LEVEL", DOWNSTAIRS_GROUP, { LEVEL = "100", TIME = "4000" })
		tick(200)
		local names, bodies = puts_since(mark)
		assert.same({ "grouped_light " .. F.grouped_light_rids.downstairs }, names)
		assert.equal(4000, bodies[1].dynamics.duration)

		-- Halfway, the Living Room Lamp's own keypad is pressed: its ramp
		-- stops at its estimate, sent for that lamp alone; Garage White ramps
		-- on, and its proxy hears nothing until its ramp ends.
		tick(1800, 100)
		mark = #world.puts
		proxy(lamp, "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "1" })
		proxy(lamp, "BUTTON_ACTION", { BUTTON_ID = "1", ACTION = "2" })
		tick(200)
		names, bodies = puts_since(mark)
		assert.same({ "light " .. F.rids.living }, names)
		assert.equal(70, bodies[1].dimming.brightness)
		local all = levels(lamp)
		assert.equal(70, all[#all])
		assert.same({}, levels(garage), "the other member's ramp goes on")
		tick(3 * S, 100)
		names = puts_since(mark)
		assert.same({ "light " .. F.rids.living }, names, "nothing more for either lamp")
		all = levels(garage)
		assert.equal(100, all[#all], "Garage White reaches the group's level")
	end)

	it("holds a load group lamp by lamp, never as one group request, and stops it the same way (D9)", function()
		group(lamp, "JOIN_GROUP", DOWNSTAIRS_GROUP, { KEEP_SYNC = "0" })
		group(garage, "JOIN_GROUP", DOWNSTAIRS_GROUP, { KEEP_SYNC = "0" })
		group(lamp, "GROUP_SET_LEVEL", DOWNSTAIRS_GROUP, { LEVEL = "40" })
		group(garage, "GROUP_SET_LEVEL", DOWNSTAIRS_GROUP, { LEVEL = "40" })
		tick(2 * S, 100)

		local mark = #world.puts
		group(lamp, "GROUP_START_RAMP", DOWNSTAIRS_GROUP, { RAMP_UP = "1", RATE = "4000" })
		group(garage, "GROUP_START_RAMP", DOWNSTAIRS_GROUP, { RAMP_UP = "1", RATE = "4000" })
		tick(200)
		local names, bodies = puts_since(mark)
		assert.same({ "light " .. F.rids.living, "light " .. F.rids.garage }, names)
		for _, body in ipairs(bodies) do
			assert.equal("up", body.dimming_delta.action)
		end

		tick(800, 100)
		mark = #world.puts
		group(lamp, "GROUP_STOP_RAMP", DOWNSTAIRS_GROUP)
		group(garage, "GROUP_STOP_RAMP", DOWNSTAIRS_GROUP)
		tick(200)
		names, bodies = puts_since(mark)
		assert.same({ "light " .. F.rids.living, "light " .. F.rids.garage }, names, "the stops in the starts' order")
		for _, body in ipairs(bodies) do
			assert.equal("stop", body.dimming_delta.action)
		end
	end)
end)
