-- Hue devices offline while the bridge is unreachable (#428,
-- docs/offline-design.md §8.1), end to end on the real drivers: the bridge is
-- src/hue_bridge/driver.lua as Director runs it (late init, the identity
-- check, the event stream, the resync chain, the command queues, the link of
-- bridge/link.lua), the devices are a Hue Light, a zone light (the same
-- driver), a Hue Scene and a Hue Motion Sensor, each added from the bridge,
-- with SendToDevice and the bindings routed by the fake runtime.
--
-- The network is modelled, not scripted: every transfer the bridge opens is
-- answered by the bridge at BRIDGE_IP while it is up (the identity, the TLS
-- self-check's keyed GET, the stream, every resource GET and PUT), and fails
-- at once with a transfer error and no HTTP status while it is down, as an
-- unplugged bridge does (D2 c). The clocks of all five drivers move together
-- (tick). What is pinned is the contract's §3 examples on the real wiring:
-- a 3-minute restart shows nothing, 300 s of trouble takes every device
-- offline once, the first contact brings each back with one message, a
-- command that cannot land is answered with what the bridge knows, a hello
-- during the outage hears the link first, and a restart of the controller
-- during a long outage neither waits 5 more minutes nor fires the motion
-- Offline event again.
--
-- The bridge is tests/fixtures/hue_resources.lua with the Hallway sensor of
-- tests/fixtures/hue_motion.lua added (its device and Zigbee items, in no
-- Hue room); the address, bridge id and key are the documented placeholders.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local json = require("dkjson")
local F = require("fixtures.hue_resources")
local M = require("fixtures.hue_motion")

local BRIDGE_IP = "10.0.2.143"
local BRIDGE_HUE_ID = "001788fffe123abc"
local APP_KEY = "<key>"
local LIVING_ROOM, GARAGE_ROOM = 7, 8
-- The ids the fake's AddDevice hands out, in the order the devices are added.
local LIGHT_ID, ZONE_ID, SCENE_ID, SENSOR_ID = 2001, 2002, 2003, 2004
local S, MIN = 1000, 60000
local EMPTY = '{"errors":[],"data":[]}'
local OK_PUT = '{"data":[],"errors":[]}'
local BRIDGE_PROPERTIES = { ["Event Stream Transport"] = "Web transfer", ["Bridge IP Address"] = BRIDGE_IP }

-- The motion driver's event ids (src/hue_motion/driver.xml).
local EVENT_OFFLINE, EVENT_ONLINE = 5, 6

-- One item of a fixture body, as its text: from `{"id":"<id>"` to its
-- closing brace (the fixtures hold no braces inside strings).
local function item_text(body, id)
	local start = assert(body:find('{"id":"' .. id .. '"', 1, true), "no item " .. id)
	local depth = 0
	for i = start, #body do
		local c = body:sub(i, i)
		if c == "{" then
			depth = depth + 1
		elseif c == "}" then
			depth = depth - 1
			if depth == 0 then
				return body:sub(start, i)
			end
		end
	end
	error("unterminated item " .. id)
end

-- A fixture body with more items at the end of its data list.
local function with_items(body, ...)
	local head = assert(body:match("^(.*)%]%s*}%s*$"), "not a CLIP v2 body")
	return head .. "," .. table.concat({ ... }, ",") .. "]}"
end

-- What the bridge answers to GET /clip/v2/resource/<type>.
local BODIES = {
	light = F.light,
	device = with_items(F.device, item_text(M.device, M.devices.hallway)),
	zigbee_connectivity = with_items(F.zigbee_connectivity, item_text(M.zigbee_connectivity, M.zigbee.hallway)),
	room = F.room, zone = F.zone, bridge_home = F.bridge_home,
	scene = F.scene, smart_scene = F.smart_scene, grouped_light = F.grouped_light,
	motion = M.motion_body, light_level = M.light_level_body, temperature = M.temperature_body,
	device_power = M.device_power_body,
}

-- "14:02" when `since_s` is on today's date, "10-26 14:02" otherwise: the
-- rule of §6.3, which the device applies against the controller's clock.
local function clock(since_s)
	if os.date("%Y-%m-%d", since_s) == os.date("%Y-%m-%d", os.time()) then
		return os.date("%H:%M", since_s)
	end
	return os.date("%m-%d %H:%M", since_s)
end

describe("offline round trip (#428)", function()
	local bridge, bc4, light, zone, scene, sensor, devices, logged, world

	-- The commands a device sent its proxy (binding 5001), with their params.
	local function notifies(env, command)
		local out = {}
		for _, args in ipairs(env.C4.calls_to("SendToProxy")) do
			if args[1] == 5001 and args[2] == command then out[#out + 1] = args[3] end
		end
		return out
	end

	local function online_states(env)
		local out = {}
		for _, p in ipairs(notifies(env, "ONLINE_CHANGED")) do out[#out + 1] = p.STATE end
		return out
	end

	local function levels(env)
		local out = {}
		for _, p in ipairs(notifies(env, "LIGHT_BRIGHTNESS_CHANGED")) do out[#out + 1] = p.LIGHT_BRIGHTNESS_CURRENT end
		return out
	end

	-- The contact proxy's commands of the motion device, in order.
	local function contact(env)
		local out = {}
		for _, args in ipairs(env.C4.calls_to("SendToProxy")) do
			if args[1] == 5001 then out[#out + 1] = args[2] end
		end
		return out
	end

	-- What the bridge sent device `id` since bc4.sent was last cleared.
	local function messages_to(id)
		local out = {}
		for _, m in ipairs(bc4.sent) do
			if m.id == id then out[#out + 1] = m.command end
		end
		return out
	end

	-- The HUE_BRIDGE_LINK messages to device `id`, as { state, reason, since }.
	local function links_to(id)
		local out = {}
		for _, m in ipairs(bc4.sent) do
			if m.id == id and m.command == "HUE_BRIDGE_LINK" then
				out[#out + 1] = { m.params.state, m.params.reason, m.params.since }
			end
		end
		return out
	end

	local function sent_by(env, command)
		local out = {}
		for _, m in ipairs(env.C4.sent) do
			if m.command == command then out[#out + 1] = m.params end
		end
		return out
	end

	-- Every recording of every driver cleared: what follows is what a step did.
	local function clear()
		bc4.sent = {}
		for _, env in ipairs(devices) do
			env.C4.calls, env.C4.sent, env.C4.events_fired = {}, {}, {}
		end
	end

	-- The bridge at BRIDGE_IP answers every transfer the bridge driver has
	-- open: as itself while world.up, else each fails at once with no HTTP
	-- status (an unplugged bridge: refused, or nothing at the address). A
	-- connected stream stays open while up and ends with the outage. A PUT
	-- is answered by world.put (code, body) when set. Returns how many it
	-- answered.
	local function serve()
		local answered = 0
		for i = world.first, #bc4.transfers do
			local t = bc4.transfers[i]
			if not t.finished and (not t.streaming or not world.up) then
				answered = answered + 1
				assert(answered < 2000, "the bridge driver keeps opening transfers: " .. tostring(t.url))
				fake.as(bridge, function()
					if not world.up then
						t.finished = true
						t:done(t.streaming and 56 or 7, t.streaming and "Recv failure: Connection reset by peer"
							or "Failed to connect to " .. BRIDGE_IP)
						return
					end
					local path = t.url:match("^https://[^/]+(/.*)$") or t.url
					if path:find("^/eventstream/clip/v2") then
						t:respond_headers(200, {})
						t.streaming = true
						if t.aborted then
							t.finished = true
							t:done(-1, nil)
						end
					elseif path == "/api/0/config" then
						t.finished = true
						t:respond(200, '{"bridgeid":"' .. BRIDGE_HUE_ID:upper() .. '","modelid":"BSB003"}')
					elseif path == "/clip/v2/resource/bridge" then
						t.finished = true
						t:respond(200, '{"errors":[],"data":[{"bridge_id":"' .. BRIDGE_HUE_ID .. '"}]}')
					elseif t.method == "PUT" then
						t.finished = true
						local code, body = 200, OK_PUT
						if world.put then
							code, body = world.put(t)
						end
						world.puts[#world.puts + 1] = { url = t.url, data = t.data, code = code }
						t:respond(code, body)
					else
						local kind = assert(path:match("^/clip/v2/resource/([%w_]+)$"), "unexpected " .. t.method .. " "
							.. t.url)
						t.finished = true
						t:respond(200, BODIES[kind] or EMPTY)
					end
				end)
			end
		end
		while world.first <= #bc4.transfers and bc4.transfers[world.first].finished do
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

	-- `ms` of time for every driver, in steps of at most `step` ms (1 s),
	-- the network answering after each.
	local function tick(ms, step)
		step = step or S
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

	-- A command from the device's proxy, and what it sends delivered at once.
	local function proxy(env, command, params)
		fake.as(env, env.ReceivedFromProxy, 5001, command, params or {})
		settle()
	end

	-- The bridge as the house has it: loaded, paired, its first resync done,
	-- and the four devices added from it and live.
	local function start()
		logged = {}
		log.sink = function(line) logged[#logged + 1] = line end
		-- The devices first, the bridge last (its globals stay in place), then
		-- the project's rooms: Living Room (the default) and Garage map by name.
		light = fake.load_driver("hue_light", {}, { device_id = LIGHT_ID })
		zone = fake.load_driver("hue_light", {}, { device_id = ZONE_ID })
		scene = fake.load_driver("hue_scene", {}, { device_id = SCENE_ID })
		sensor = fake.load_driver("hue_motion", {}, { device_id = SENSOR_ID })
		fake.as(sensor, sensor.OnDriverInit, "DIT_ADDING")
		devices = { light, zone, scene, sensor }
		bridge = fake.load_driver("hue_bridge", BRIDGE_PROPERTIES)
		bc4 = bridge.C4
		-- Noon today: every time the drivers show is "12:00"-like, with no
		-- date, whenever the spec runs (§6.3).
		local today = os.date("*t")
		bc4.now_ms = os.time({ year = today.year, month = today.month, day = today.day, hour = 12 }) * 1000
		fake.add_room(GARAGE_ROOM, "Garage")
		bc4.persist.hue_app_key = APP_KEY
		bc4.persist.hue_bridge_id = BRIDGE_HUE_ID
		world = { up = true, first = 1, puts = {} }

		fake.as(bridge, bridge.OnDriverLateInit, "DIT_STARTUP")
		settle()
		fake.as(bridge, function() bc4.advance(2500) end) -- the on_connected deferral, the resync's 2 s debounce
		settle()
		assert.equal("Paired", bridge.Properties["Status"])

		-- Routed before they are added, as on a controller: what the bridge
		-- tells a device right after AddDevice (its configuration) reaches it
		-- before its late init, which takes it first.
		for _, env in ipairs(devices) do
			fake.pair(bridge, env, { light_id = env.C4.device_id, bind = false })
		end
		assert.equal("Added Living Room Lamp #1 to Living Room (device 2001)",
			action("Add Light", { Light = F.rids.living, Room = "" }))
		assert.truthy(action("Add Zone Light", { Group = F.group_rids.downstairs, Room = tostring(LIVING_ROOM) })
			:find("(device 2002)", 1, true), fake.last_action(bridge))
		assert.equal("Added Relax to Living Room (device 2003)", action("Add Scene", { Scene = F.scene_rids.relax,
			Room = "" }))
		assert.truthy(action("Add Motion Sensor", { Sensor = M.devices.hallway, Room = tostring(LIVING_ROOM) })
			:find("(device 2004)", 1, true), fake.last_action(bridge))

		for _, env in ipairs(devices) do
			fake.as(env, env.OnDriverLateInit, "DIT_ADDING")
		end
		settle()
		tick(5 * S)
		clear()
	end

	-- common.dispatch and the modules' protect() turn a handler's error into
	-- an [ERROR] line instead of raising it: none may have been logged.
	after_each(function()
		log.sink = function() end
		for _, line in ipairs(logged or {}) do
			assert.is_nil(line:find("[ERROR]", 1, true), line)
		end
	end)

	before_each(function()
		start()
	end)

	-- The bridge stops answering now (t0): the stream drops at once.
	local function unplug()
		world.up = false
		settle()
		return bc4.now_ms
	end

	-- The Status a light, zone light or scene shows while the link is offline (§6.3).
	local function not_answering(since_ms)
		return "Hue Bridge not answering since " .. clock(math.floor(since_ms / 1000))
	end

	-- Every device told offline once, 300 s after t0 (D1), recordings cleared.
	local function offline_from(t0)
		tick(t0 + 300 * S - bc4.now_ms)
		for _, env in ipairs(devices) do
			assert.same({ { "offline", "not_answering", tostring(math.floor(t0 / 1000)) } },
				links_to(env.C4.device_id), "device " .. env.C4.device_id)
		end
		clear()
	end

	-- A driver of the house loaded again as Director does after an update or
	-- a restart (E14 to E18): a fresh Lua state with the store it had. Its
	-- binding and project entry stay; the harness routes to the new one.
	local function reload(old, driver, properties)
		local project = fake.project
		local env = fake.load_driver(driver, properties or {}, { device_id = old.C4.device_id })
		fake.project = project
		for k, v in pairs(old.C4.persist) do env.C4.persist[k] = v end
		env.C4.now_ms = old.C4.now_ms
		return env
	end

	-- The harness routes `list` (and the bridge) again after a reload.
	local function route(list)
		for _, env in ipairs(list) do
			fake.pair(bridge, env, { light_id = env.C4.device_id, bind = false })
		end
	end

	it("shows nothing of a 3-minute bridge restart; a command meanwhile is answered with what the bridge knows", function()
		assert.equal("Living Room Lamp (Hue color lamp)", light.Properties["Status"])
		local t0 = unplug()
		tick(90 * S)

		-- t0 + 90 s: a slider move to 30 %. The bridge refuses the PUT (its
		-- identity is being checked again) and answers with the level it
		-- knows; the tile goes back to it, never to the target (D8, D9).
		proxy(light, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "0" })
		assert.equal(1, #notifies(light, "LIGHT_BRIGHTNESS_CHANGING"))
		tick(S)
		local answer
		for _, m in ipairs(bc4.sent) do
			if m.id == LIGHT_ID and m.command == "HUE_STATE" then answer = answer or m.params end
		end
		assert.truthy(answer, "an undelivered answer")
		assert.equal("undelivered", answer.reason)
		assert.equal("73.52", tostring(answer.brightness))
		-- (The queue retries for 30 s; each refusal is answered again, D8.)
		assert.is_true(#levels(light) >= 1)
		for _, level in ipairs(levels(light)) do
			assert.equal(74, level, "the level the bridge knows (73.52 %), not 30")
		end

		-- Back at t0 + 3 min: the identity check passes (contact), the stream
		-- connects and the resync runs. No device ever hears the link.
		tick(t0 + 3 * MIN - bc4.now_ms)
		world.up = true
		tick(5 * MIN)
		for _, env in ipairs(devices) do
			assert.same({}, links_to(env.C4.device_id), "device " .. env.C4.device_id)
		end
		for _, env in ipairs({ light, zone, scene }) do
			for i, state in ipairs(online_states(env)) do
				assert.is_true(state, "ONLINE_CHANGED " .. i .. " of device " .. env.C4.device_id)
			end
			assert.equal("Online", env.Properties["Online"])
		end
		for _, level in ipairs(levels(light)) do
			assert.equal(74, level)
		end
		assert.equal("Living Room Lamp (Hue color lamp)", light.Properties["Status"])
		assert.equal("Hue zone Downstairs (2 lights)", zone.Properties["Status"])
		assert.equal("Hue scene Relax in Living Room", scene.Properties["Status"])
		assert.same({}, sensor.C4.events_fired, "no Offline or Online event")
		assert.equal("Yes", sensor.Properties["Online"])
		assert.equal("Hue motion sensor Hallway sensor", sensor.Properties["Status"])
		assert.is_nil(bc4.persist.hue_bridge_link)
		assert.is_nil(fake.attention(bridge):find("Hue devices offline", 1, true))
		assert.truthy(tostring(bridge.Properties["Event Stream"]):find("^Connected since"))
	end)

	it("takes every device offline once after 300 s of trouble, drops commands, and brings each back with one "
		.. "message at the first contact", function()
		local t0 = unplug()
		tick(299 * S)
		for _, env in ipairs(devices) do
			assert.same({}, links_to(env.C4.device_id), "nothing during the trouble")
		end
		assert.same({}, online_states(light))

		-- 300 s: one HUE_BRIDGE_LINK offline to every device (D1, D4).
		tick(S)
		local since = tostring(math.floor(t0 / 1000))
		for _, env in ipairs(devices) do
			assert.same({ { "offline", "not_answering", since } }, links_to(env.C4.device_id),
				"device " .. env.C4.device_id)
		end
		for _, env in ipairs({ light, zone, scene }) do
			assert.same({ false }, online_states(env), "device " .. env.C4.device_id)
			assert.equal(not_answering(t0), env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
		end
		-- The motion device: Online No and its Offline event, once; the contact
		-- as it was (D14).
		assert.equal("No", sensor.Properties["Online"])
		assert.same({ EVENT_OFFLINE }, sensor.C4.events_fired)
		assert.equal(not_answering(t0) .. "; motion not current", sensor.Properties["Status"])
		assert.same({}, contact(sensor))
		assert.same({ since = t0, reason = "not_answering" }, bc4.persist.hue_bridge_link)
		assert.truthy(fake.attention(bridge):find("Hue devices offline since " .. clock(math.floor(t0 / 1000) + 300)
			.. ": the bridge has not answered since " .. clock(math.floor(t0 / 1000))
			.. "; they come back by themselves when it answers", 1, true), fake.attention(bridge))

		-- A command to an offline device is dropped there, before any CHANGING
		-- (D5, E25): nothing reaches the bridge, nothing is queued.
		clear()
		local puts = #world.puts
		proxy(light, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "0" })
		proxy(light, "TOGGLE")
		proxy(zone, "ON")
		proxy(scene, "ON")
		tick(5 * S)
		for _, env in ipairs({ light, zone, scene }) do
			assert.same({}, notifies(env, "LIGHT_BRIGHTNESS_CHANGING"), "device " .. env.C4.device_id)
			assert.same({}, notifies(env, "LIGHT_BRIGHTNESS_CHANGED"), "device " .. env.C4.device_id)
			assert.same({}, env.C4.sent, "device " .. env.C4.device_id)
		end
		assert.equal(puts, #world.puts)

		-- Told once: 15 more minutes change nothing.
		tick(15 * MIN, 10 * S)
		for _, env in ipairs(devices) do
			assert.same({}, links_to(env.C4.device_id), "device " .. env.C4.device_id)
		end
		assert.same({}, sensor.C4.events_fired)

		-- The bridge answers again: its first contact (the identity check, every
		-- 30 s) tells every device online, one message each, and nothing flickers.
		clear()
		world.up = true
		local contact_at
		for _ = 1, 30 do
			tick(S)
			if #links_to(LIGHT_ID) > 0 then
				contact_at = bc4.now_ms
				break
			end
		end
		assert.truthy(contact_at, "contact within 30 s")
		for _, env in ipairs(devices) do
			assert.same({ { "online" } }, links_to(env.C4.device_id), "device " .. env.C4.device_id)
		end
		for _, env in ipairs({ light, zone, scene }) do
			assert.same({ true }, online_states(env), "device " .. env.C4.device_id)
		end
		assert.equal("Yes", sensor.Properties["Online"])
		assert.same({ EVENT_ONLINE }, sensor.C4.events_fired)

		-- Then the stream and its resync: no second message, no flicker.
		tick(3 * MIN)
		assert.truthy(tostring(bridge.Properties["Event Stream"]):find("^Connected since"))
		for _, env in ipairs(devices) do
			assert.same({ { "online" } }, links_to(env.C4.device_id), "device " .. env.C4.device_id)
		end
		for _, env in ipairs({ light, zone, scene }) do
			for i, state in ipairs(online_states(env)) do
				assert.is_true(state, "ONLINE_CHANGED " .. i .. " of device " .. env.C4.device_id)
			end
			assert.equal("Online", env.Properties["Online"])
		end
		assert.equal("Living Room Lamp (Hue color lamp)", light.Properties["Status"])
		assert.equal("Hue zone Downstairs (2 lights)", zone.Properties["Status"])
		assert.equal("Hue scene Relax in Living Room", scene.Properties["Status"])
		assert.equal("Hue motion sensor Hallway sensor", sensor.Properties["Status"])
		assert.same({ EVENT_ONLINE }, sensor.C4.events_fired)
		assert.is_nil(bc4.persist.hue_bridge_link)
		assert.is_nil(fake.attention(bridge):find("Hue devices offline", 1, true))
	end)

	it("answers a PUT that fails while the bridge is up with what it knows: the tile shows the bridge's level, "
		.. "not the target", function()
		world.put = function()
			return 400, '{"errors":[{"description":"invalid value for brightness"}],"data":[]}'
		end
		proxy(light, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "0" })
		assert.equal(1, #notifies(light, "LIGHT_BRIGHTNESS_CHANGING"))
		tick(S)
		assert.equal(1, #world.puts)
		assert.equal(400, world.puts[1].code)
		assert.equal(30, json.decode(world.puts[1].data).dimming.brightness, "the target went out")
		local answers = {}
		for _, m in ipairs(bc4.sent) do
			if m.id == LIGHT_ID and m.command == "HUE_STATE" then answers[#answers + 1] = m.params end
		end
		assert.equal(1, #answers)
		assert.equal("undelivered", answers[1].reason)
		assert.equal("73.52", tostring(answers[1].brightness))
		assert.same({ 74 }, levels(light))
		-- The light's own fallback (the ramp plus 1 s) finds nothing to assume.
		tick(10 * S)
		assert.same({ 74 }, levels(light))
		assert.same({}, links_to(LIGHT_ID), "a refusal is no trouble")
		assert.same({}, online_states(light))
		assert.equal("Online", light.Properties["Online"])
	end)

	it("answers a zone light's and a scene's command that fails with what the bridge knows (the group queue, D8)",
		function()
		world.put = function()
			return 400, '{"errors":[{"description":"invalid value"}],"data":[]}'
		end
		-- The zone: one grouped_light PUT, refused; the tile shows the group's
		-- level as the bridge knows it (73.52 %), not 30.
		proxy(zone, "SET_BRIGHTNESS_TARGET", { LIGHT_BRIGHTNESS_TARGET = "30", RATE = "0" })
		assert.equal(1, #notifies(zone, "LIGHT_BRIGHTNESS_CHANGING"))
		tick(2 * S)
		assert.equal(1, #world.puts)
		assert.truthy(world.puts[1].url:find("/clip/v2/resource/grouped_light/" .. F.grouped_light_rids.downstairs, 1,
			true), world.puts[1].url)
		local answer
		for _, m in ipairs(bc4.sent) do
			if m.id == ZONE_ID and m.command == "HUE_STATE" then answer = m.params end
		end
		assert.equal("undelivered", answer and answer.reason)
		assert.same({ 74 }, levels(zone))

		-- The scene: its recall PUT refused; the answer comes from a timer
		-- (D8), and the tile goes back to where its CHANGING started.
		local changing = #notifies(scene, "LIGHT_BRIGHTNESS_CHANGING")
		proxy(scene, "ON")
		local started = notifies(scene, "LIGHT_BRIGHTNESS_CHANGING")
		assert.equal(changing + 1, #started)
		local from = started[#started].LIGHT_BRIGHTNESS_CURRENT
		assert.equal(1, #sent_by(scene, "HUE_SCENE_RECALL"))
		for _, m in ipairs(bc4.sent) do
			assert.is_false(m.id == SCENE_ID and m.command == "HUE_SCENE_STATE", "not before the timer")
		end
		tick(3 * S)
		assert.equal(2, #world.puts)
		assert.truthy(world.puts[2].url:find("/clip/v2/resource/scene/" .. F.scene_rids.relax, 1, true))
		local state
		for _, m in ipairs(bc4.sent) do
			if m.id == SCENE_ID and m.command == "HUE_SCENE_STATE" then state = m.params end
		end
		assert.equal("undelivered", state and state.reason)
		local shown = levels(scene)
		assert.equal(from, shown[#shown], "the level before the ON, not the scene's")
		for _, env in ipairs(devices) do
			assert.same({}, links_to(env.C4.device_id))
		end
	end)

	-- Pending (bug): a re-bind is answered with the state before HUE_BRIDGE_LINK (driver.lua OnBindingChanged).
	it("tells a device bound again during the outage the link before its state: no online flicker, no motion "
		.. "events (E21)", function()
		offline_from(unplug())
		for _, env in ipairs({ light, scene, sensor }) do
			local id = env.C4.device_id
			fake.as(bridge, function() bc4:Unbind(id, 1) end)
			settle()
			clear()
			fake.as(bridge, function() bc4:Bind(bc4.device_id, 1, id, 1, "HUE_BRIDGE") end)
			settle()
			local to = messages_to(id)
			assert.equal("HUE_BRIDGE_LINK", to[1], "device " .. id .. ": " .. table.concat(to, " "))
			for i, state in ipairs(online_states(env)) do
				assert.is_false(state, "ONLINE_CHANGED " .. i .. " of device " .. id)
			end
		end
		assert.same({}, sensor.C4.events_fired, "neither Online nor Offline fires again")
		assert.equal("No", sensor.Properties["Online"])
		assert.equal("Offline", light.Properties["Online"])
		assert.equal("Offline", scene.Properties["Online"])
	end)

	it("answers a hello during the outage with the link first (D4, E17)", function()
		local t0 = unplug()
		offline_from(t0)

		-- The motion device asks again (Refresh From Bridge): the link comes
		-- first, and the Offline event does not fire again.
		fake.as(sensor, sensor.ExecuteCommand, "LUA_ACTION", { ACTION = "Refresh From Bridge" })
		settle()
		local to_sensor = messages_to(SENSOR_ID)
		assert.equal("HUE_BRIDGE_LINK", to_sensor[1], table.concat(to_sensor, " "))
		assert.equal("offline", links_to(SENSOR_ID)[1][1])
		assert.same({}, sensor.C4.events_fired)
		assert.equal("No", sensor.Properties["Online"])

		-- The light and the scene updated during the outage (E16, E17): fresh
		-- drivers whose hello answer starts with the link; from that answer on
		-- they never report online.
		clear()
		local new_light = reload(light, "hue_light")
		local new_scene = reload(scene, "hue_scene")
		devices = { new_light, zone, new_scene, sensor }
		route(devices)
		local before = {}
		for _, env in ipairs({ new_light, new_scene }) do
			fake.as(env, env.OnDriverInit, "DIT_UPDATING")
			fake.as(env, env.OnDriverLateInit, "DIT_UPDATING")
			before[env] = #online_states(env)
		end
		settle()
		assert.same({ "HUE_BRIDGE_LINK", "HUE_CONFIGURE", "HUE_STATE" }, messages_to(LIGHT_ID))
		assert.equal("HUE_BRIDGE_LINK", messages_to(SCENE_ID)[1], table.concat(messages_to(SCENE_ID), " "))
		for _, env in ipairs({ new_light, new_scene }) do
			assert.equal("offline", links_to(env.C4.device_id)[1][1])
			local states = online_states(env)
			assert.is_true(#states > before[env], "device " .. env.C4.device_id .. " reported")
			for i = before[env] + 1, #states do
				assert.is_false(states[i], "ONLINE_CHANGED " .. i .. " of device " .. env.C4.device_id)
			end
			assert.equal("Offline", env.Properties["Online"])
			assert.equal(not_answering(t0), env.Properties["Status"])
		end
	end)

	it("goes offline at the first failed check after a controller restart during a long outage, and fires the "
		.. "motion Offline event only once", function()
		local t0 = unplug()
		offline_from(t0)
		tick(15 * MIN, 10 * S)
		assert.same({}, sensor.C4.events_fired)

		-- The controller restarts, the bridge still down: every driver loaded
		-- again with its store; the bindings and the project stay.
		local bindings, now = bc4.bindings, bc4.now_ms + MIN
		local new = {
			reload(light, "hue_light"), reload(zone, "hue_light"), reload(scene, "hue_scene"),
			reload(sensor, "hue_motion"),
		}
		light, zone, scene, sensor = new[1], new[2], new[3], new[4]
		devices = new
		bridge = reload(bridge, "hue_bridge", BRIDGE_PROPERTIES)
		bc4 = bridge.C4
		bc4.now_ms = now
		for _, b in ipairs(bindings) do bc4.bindings[#bc4.bindings + 1] = b end
		world.first = 1
		route(devices)
		for _, env in ipairs(devices) do
			fake.as(env, env.OnDriverInit, "DIT_STARTUP")
		end

		-- The bridge first: its identity check fails at once, and with the
		-- stored outage 16 minutes old every device is told offline at once
		-- (D12, E14), with the outage's own start.
		fake.as(bridge, bridge.OnDriverLateInit, "DIT_STARTUP")
		settle()
		for _, env in ipairs(devices) do
			assert.same({ { "offline", "not_answering", tostring(math.floor(t0 / 1000)) } },
				links_to(env.C4.device_id), "device " .. env.C4.device_id)
		end
		assert.same({ since = t0, reason = "not_answering" }, bc4.persist.hue_bridge_link)
		assert.truthy(fake.attention(bridge):find("Hue devices offline since " .. clock(math.floor(t0 / 1000) + 300)
			.. ": the bridge has not answered since " .. clock(math.floor(t0 / 1000)), 1, true), fake.attention(bridge))
		for _, env in ipairs(devices) do
			fake.as(env, env.OnDriverLateInit, "DIT_STARTUP")
		end
		settle()
		tick(MIN)
		for _, env in ipairs({ light, zone, scene }) do
			local states = online_states(env)
			assert.is_false(states[#states], "device " .. env.C4.device_id)
			assert.equal(not_answering(t0), env.Properties["Status"])
			assert.equal("Offline", env.Properties["Online"])
		end
		-- The motion device kept the link in its store: Online stays No and
		-- nothing fires a second time (D14, E14).
		assert.equal("No", sensor.Properties["Online"])
		assert.same({}, sensor.C4.events_fired)
		assert.equal(not_answering(t0) .. "; motion not current", sensor.Properties["Status"])

		-- And back: the Online event, once.
		world.up = true
		tick(3 * MIN)
		assert.equal("Yes", sensor.Properties["Online"])
		assert.same({ EVENT_ONLINE }, sensor.C4.events_fired)
		for _, env in ipairs({ light, zone, scene }) do
			local states = online_states(env)
			assert.is_true(states[#states], "device " .. env.C4.device_id)
			assert.equal("Online", env.Properties["Online"])
		end
		assert.is_nil(bc4.persist.hue_bridge_link)
	end)
end)
