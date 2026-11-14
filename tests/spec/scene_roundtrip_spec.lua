-- End to end for scenes on the two-driver harness: the bridge side is the
-- bridge.scenes module on a fake bridge runtime (driver.lua's wiring of it is
-- the coordinator's; the routing below is what §5 of docs/scenes-design.md
-- asks of it), the scene side is the real Hue Scene driver. Add Scene creates
-- the device, its hello is answered, ON becomes one recall PUT whose stream
-- item closes the loop, a member light changed by hand turns the switch off,
-- OFF is one grouped_light call, a scene deleted in Hue leaves the device
-- gone, and deleting the device in Composer leaves a tombstone that Add Scene
-- clears.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local json = require("dkjson")
local F = require("fixtures.hue_resources")

local LIVING_ROOM, GARAGE_ROOM = 7, 8
local SCENE_ID = 2001     -- the first id the fake's AddDevice hands out
local BRIDGE_ID = 15
local T0 = 1761000000

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

describe("scene round trip: add, hello, recall, event, off, deleted in Hue, deleted in Composer", function()
	local bridge, scene, bc4, L, S, offs, now, last_action

	local function http_ctx(req, cb)
		req.ip = "192.0.2.10"
		req.key = "k"
		return require("bridge.http").request(req, cb)
	end

	local function decode_data(text)
		return json.decode(text).data
	end

	-- The resync's three GETs, the scenes as `scene_body` (default F.scene).
	local function answer_scene_gets(scene_body)
		local t = bc4.last_transfer()
		assert.equal("https://192.0.2.10/clip/v2/resource/scene", t.url)
		fake.as(bridge, function() t:respond(200, scene_body or F.scene) end)
		t = bc4.last_transfer()
		assert.equal("https://192.0.2.10/clip/v2/resource/smart_scene", t.url)
		fake.as(bridge, function() t:respond(200, F.smart_scene) end)
		t = bc4.last_transfer()
		assert.equal("https://192.0.2.10/clip/v2/resource/grouped_light", t.url)
		fake.as(bridge, function()
			t:respond(200, '{"errors":[],"data":[{"id":"' .. F.grouped_light_rids.living_room
				.. '","on":{"on":true},"type":"grouped_light"}]}')
		end)
	end

	local function event(text)
		fake.as(bridge, function() S:on_container(bridge.C4:JsonDecode(text)[1]) end)
	end

	before_each(function()
		log.sink = function() end
		now = T0

		-- The scene driver first, then the bridge runtime (its globals stay in
		-- place), then the project. Keypad Follows "This scene": the loop pins
		-- the on rule, and the fixture's room is lit (the lights mode is pinned
		-- in scene_driver_spec.lua, docs/scene-led-design.md).
		scene = fake.load_driver("hue_scene", { ["Keypad Follows"] = "This scene" }, { device_id = SCENE_ID })
		local env
		bc4, env = fake.install_c4()
		bridge = env
		fake.add_room(GARAGE_ROOM, "Garage")
		-- The harness shares one common.log between the two sides; the real
		-- bridge driver sets its own prefix, which keeps the scene driver's
		-- dev-build log forwarding (HUE_LOG for its own lines) off the bridge's lines.
		log.set_prefix("Hue Bridge")

		for _, m in ipairs({ "bridge.http", "bridge.hue_model", "bridge.registry", "bridge.groups", "bridge.lights",
			"bridge.scenes" }) do
			package.loaded[m] = nil
		end
		local lights = require("bridge.lights")
		local scenes = require("bridge.scenes")
		L = lights.new({ http = http_ctx, now = function() return now end })
		L:absorb({ room = decode_data(F.room), zone = decode_data(F.zone), bridge_home = decode_data(F.bridge_home) })
		L.reg:set_room_mapping(F.group_rids.living_room, { c4_room_id = LIVING_ROOM, c4_room_name = "Living Room",
			hue_name = "Living Room", type = "room" })
		offs = {}
		S = scenes.new({ http = http_ctx, now = function() return now end, lights = L,
			group_off = function(rid) offs[#offs + 1] = rid; return true end })
		S:load()

		-- What driver.lua does with the scene messages (docs/scenes-design.md §5).
		last_action = nil
		bridge.ExecuteCommand = function(command, params)
			if command == "HUE_SCENE_HELLO" then
				S:hello(params.rid, params)
			elseif command == "HUE_SCENE_RECALL" then
				S:recall(params)
			elseif command == "HUE_SCENE_OFF" then
				S:off(params)
			elseif command == "HUE_SCENE_GOODBYE" then
				S:goodbye(params)
			elseif command == "HUE_SCENE_FORGET" then
				local _, text = S:forget_request(params)
				last_action = text
			end
		end
		bridge.OnBindingChanged = function(binding, class, bound, other)
			S:on_binding_changed(binding, class, bound, other)
		end
	end)

	it("runs the whole loop", function()
		-- The bridge's resync brings the catalogue; nothing is created from it.
		S:resync()
		answer_scene_gets()
		assert.equal("5 scenes + 1 time-based on bridge, 0 imported, 6 new", S:summary())
		assert.equal(0, #bc4.added)

		-- Add Scene for Relax: one AddDevice into the mapped Living Room, bound,
		-- registered and told its configuration and (inactive) status.
		local results = {}
		S:add_scene(F.scene_rids.relax, nil, function(ok, text) results[#results + 1] = { ok, text } end)
		assert.same({ { true, "Added Relax to Living Room (device 2001)" } }, results)
		assert.same({ { id = SCENE_ID, driver = "hue_scene.c4z", room = LIVING_ROOM, name = "Relax" } }, bc4.added)
		assert.equal(1, #bc4.bindings)
		assert.same({ "HUE_SCENE_CONFIGURE", "HUE_SCENE_STATE" }, messages_to(bc4, SCENE_ID))
		assert.equal("5 scenes + 1 time-based on bridge, 1 imported, 5 new", S:summary())
		assert.equal(LIVING_ROOM, fake.project.devices[SCENE_ID].room_id)
		assert.equal("Relax", fake.project.devices[SCENE_ID].name)

		-- Now the device is the real Hue Scene driver, bound to this bridge. Its
		-- late init says hello without a rid (nothing persisted yet); the bridge
		-- answers from the device id.
		fake.pair(bridge, scene, { light_id = SCENE_ID, bind = false })
		assert.equal(BRIDGE_ID, scene.C4:GetBoundProviderDevice(SCENE_ID, 1))
		fake.as(scene, scene.OnDriverLateInit, "DIT_STARTUP")
		bc4.sent = {}
		assert.is_true(fake.pump() >= 3, "hello, then configure and state back")
		assert.same({ "HUE_SCENE_CONFIGURE", "HUE_SCENE_STATE", "HUE_SCENE_GROUP" }, messages_to(bc4, SCENE_ID),
			"the hello answer carries the group's known on/off and level")
		assert.equal("hello", bc4.sent[2].params.reason)
		assert.equal("Hue scene Relax in Living Room", scene.Properties["Status"])
		assert.equal("Relax", scene.Properties["Hue Scene"])
		assert.equal("Living Room", scene.Properties["Hue Room"])
		assert.equal("Online", scene.Properties["Online"])
		assert.equal(F.scene_rids.relax, scene.C4.persist.hue_rid, "the device keeps its own identity")
		local br = proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGED")
		assert.is_true(#br >= 1)
		assert.equal(0, br[#br].LIGHT_BRIGHTNESS_CURRENT, "inactive is OFF")

		-- ON from the proxy: CHANGING at once, HUE_SCENE_RECALL to the bridge,
		-- one PUT with the recall body; the bridge's answer settles the switch.
		scene.C4.calls = {}
		bc4.sent = {}
		local before = #bc4.transfers
		fake.as(scene, scene.ReceivedFromProxy, 5001, "ON", {})
		assert.equal(1, #proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGING"))
		assert.equal(1, fake.pump(), "one HUE_SCENE_RECALL reached the bridge")
		assert.equal(before + 1, #bc4.transfers, "exactly one PUT")
		local put = bc4.last_transfer()
		assert.equal("PUT", put.method)
		assert.equal("https://192.0.2.10/clip/v2/resource/scene/" .. F.scene_rids.relax, put.url)
		assert.same({ recall = { action = "active" } }, json.decode(put.data))
		assert.equal(0, #proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGED"), "nothing until the bridge answers")
		fake.as(bridge, function()
			put:respond(200, '{"data":[{"rid":"' .. F.scene_rids.relax .. '","rtype":"scene"}],"errors":[]}')
		end)
		assert.same({ "HUE_SCENE_STATE" }, messages_to(bc4, SCENE_ID))
		assert.same({ rid = F.scene_rids.relax, active = "static", reason = "recall" }, bc4.sent[1].params)
		assert.equal(1, fake.pump())
		br = proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGED")
		assert.equal(1, #br)
		assert.equal(100, br[1].LIGHT_BRIGHTNESS_CURRENT)
		for _, t in ipairs(scene.C4.active_timers()) do
			assert.are_not.equal(2000, t.delay, "the fallback timer is settled")
		end

		-- The bridge's scene item for that recall (9 ms later on hardware): the
		-- status is already known; the event also carries the room's level,
		-- which reaches the device first and becomes the tile's percentage.
		scene.C4.calls = {}
		bc4.sent = {}
		event(F.events.scene_recalled)
		local function sent_cmd(command)
			for _, m in ipairs(bc4.sent) do
				if m.command == command then return m.params end
			end
		end
		assert.same({ rid = F.scene_rids.relax, level = "56.69" }, sent_cmd("HUE_SCENE_GROUP"))
		assert.same({ rid = F.scene_rids.relax, active = "static", reason = "event" }, sent_cmd("HUE_SCENE_STATE"))
		assert.equal(2, fake.pump())
		br = proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGED")
		assert.equal(57, br[#br].LIGHT_BRIGHTNESS_CURRENT, "the room's level, rounded")

		-- A member light dimmed by hand (Hue app): Hue calls the scene inactive,
		-- but under the on rule (docs/scene-dimmer-design.md) the tile stays on
		-- and shows the room's new level.
		scene.C4.calls = {}
		bc4.sent = {}
		event(F.events.scene_inactive)
		assert.equal("inactive", sent_cmd("HUE_SCENE_STATE").active)
		assert.equal(2, fake.pump())
		scene.C4.fire_timers() -- the one-a-second level throttle
		br = proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGED")
		assert.is_true(#br >= 1)
		for _, n in ipairs(br) do
			assert.are_not.equal(0, n.LIGHT_BRIGHTNESS_CURRENT, "the tile does not go off")
		end
		assert.equal(48, br[#br].LIGHT_BRIGHTNESS_CURRENT)

		-- ON again (so OFF has something to do), then OFF from the proxy: one
		-- grouped_light call for the scene's room, no transfer of its own, and
		-- the switch settles OFF from the bridge's STATE. The first ON's
		-- recall window (scenes.RECALL_WINDOW_MS) is long over by now.
		bc4.fire_timers()
		fake.as(scene, scene.ReceivedFromProxy, 5001, "ON", {})
		fake.pump()
		fake.as(bridge, function()
			bc4.last_transfer():respond(200, '{"data":[{"rid":"' .. F.scene_rids.relax .. '","rtype":"scene"}],"errors":[]}')
		end)
		fake.pump()
		scene.C4.calls = {}
		bc4.sent = {}
		before = #bc4.transfers
		fake.as(scene, scene.ReceivedFromProxy, 5001, "OFF", {})
		assert.equal(1, #proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGING"))
		assert.equal(2, fake.pump(), "HUE_SCENE_OFF to the bridge, its STATE straight back (no PUT to wait for)")
		assert.same({ F.grouped_light_rids.living_room }, offs, "one grouped_light off through the driver's queue")
		assert.equal(before, #bc4.transfers, "the module starts no transfer for OFF")
		assert.same({ rid = F.scene_rids.relax, active = "inactive", reason = "recall" }, bc4.sent[1].params)
		br = proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGED")
		assert.equal(1, #br)
		assert.equal(0, br[1].LIGHT_BRIGHTNESS_CURRENT)

		-- A SYNCHRONIZE from the proxy reports the cached state without asking the bridge.
		scene.C4.calls = {}
		bc4.sent = {}
		fake.as(scene, scene.ReceivedFromProxy, 5001, "SYNCHRONIZE", {})
		assert.equal(0, proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGED")[1].LIGHT_BRIGHTNESS_CURRENT)
		assert.equal(0, fake.pump())

		-- Relax is deleted in the Hue app: the device stays, marked gone, its
		-- Status explains, ON does nothing but report OFF.
		now = T0 + 3600
		scene.C4.calls = {}
		bc4.sent = {}
		event(F.events.scene_deleted)
		assert.same({ "HUE_SCENE_CONFIGURE", "HUE_SCENE_STATE" }, messages_to(bc4, SCENE_ID))
		assert.equal("gone", bc4.sent[1].params.state)
		assert.equal(2, fake.pump())
		assert.equal("Scene deleted in Hue since " .. os.date("%Y-%m-%d %H:%M", now)
			.. "; ON does nothing; Link or Forget Device", scene.Properties["Status"])
		assert.equal("Offline", scene.Properties["Online"])
		assert.equal("4 scenes + 1 time-based on bridge, 1 imported, 5 new, 1 missing", S:summary())
		assert.equal("1 scene missing from the bridge: Relax (device 2001, since " .. os.date("%Y-%m-%d", now)
			.. ") (Link or Forget Device)", S:attention())
		bc4.sent = {}
		before = #bc4.transfers
		fake.as(scene, scene.ReceivedFromProxy, 5001, "ON", {})
		assert.equal(0, fake.pump(), "the device drops ON itself while gone")
		assert.equal(before, #bc4.transfers)

		-- Re-link the device to another Living Room scene: the device, its
		-- programming and its Composer name stay; it hears the new scene.
		bc4.sent = {}
		local ok, text = S:relink(SCENE_ID, F.scene_rids.savanna)
		assert.is_true(ok)
		assert.equal("Re-linked device 2001 (was Relax) to Living Room: Savanna sunset", text)
		assert.equal(2, fake.pump())
		-- #483 D-1: that configure came by itself, not as the answer to the
		-- device's hello, so the device leaves it and asks the bridge with a
		-- hello; the bridge answers with the rid it holds for the device.
		assert.equal("Scene deleted in Hue since " .. os.date("%Y-%m-%d %H:%M", now)
			.. "; ON does nothing; Link or Forget Device", scene.Properties["Status"])
		assert.equal(1, fake.as(scene, scene.C4.fire_timers_of, 500))
		assert.equal("HUE_SCENE_HELLO", scene.C4.sent[#scene.C4.sent].command)
		assert.equal(F.scene_rids.relax, scene.C4.sent[#scene.C4.sent].params.rid)
		assert.equal(4, fake.pump(), "the hello, and the bridge's link, configure and state")
		assert.equal("Hue scene Savanna sunset in Living Room", scene.Properties["Status"])
		assert.equal(F.scene_rids.savanna, scene.C4.persist.hue_rid)
		assert.equal("Relax", fake.project.devices[SCENE_ID].name, "the Composer name is the owner's")
		assert.equal("1 Hue scene name differs from the Composer names: Relax is Savanna sunset in Hue "
			.. "(Resolve Names)", S:attention())
		assert.equal("Accepted 1 scene name difference: Relax (Hue: Savanna sunset)", S:accept_names())
		assert.equal("None", S:attention())

		-- Composer deletes the device: HUE_SCENE_GOODBYE tombstones the entry and
		-- the binding goes; Add All Scenes Of Room skips it, Add Scene re-creates
		-- it and clears the tombstone.
		fake.delete_device(SCENE_ID)
		assert.is_nil(bc4.persist.hue_scenes[F.scene_rids.savanna])
		assert.equal("Savanna sunset", bc4.persist.hue_scene_tombstones[F.scene_rids.savanna].name)
		assert.equal("4 scenes + 1 time-based on bridge, 0 imported, 4 new, 1 deleted", S:summary())
		local list = S:picker_scenes()
		assert.truthy(list[#list].text:find("^Living Room: Savanna sunset %(dynamic%) %(deleted from Composer "))
		results = {}
		S:add_all_of_group(F.group_rids.living_room, function(_, t) results[#results + 1] = t end)
		assert.equal("Added no scenes; skipped 1 deleted in Composer (Add From Hue re-creates one): Savanna sunset (deleted "
			.. os.date("%Y-%m-%d", now) .. ")", results[1])
		S:add_scene(F.scene_rids.savanna, nil, function(_, t) results[#results + 1] = t end)
		assert.equal("Added Savanna sunset to Living Room (device 2002)", results[2])
		assert.is_nil(bc4.persist.hue_scene_tombstones[F.scene_rids.savanna])
		assert.equal(2002, bc4.persist.hue_scenes[F.scene_rids.savanna].device_id)
		assert.equal("4 scenes + 1 time-based on bridge, 1 imported, 4 new", S:summary())
	end)

	-- #469 D1, D9, D13: the tile follows the scene alone, so the room's lights
	-- no longer turn it on (until 1.6 the lights mode showed the inactive
	-- scene on here); a keypad bound to it follows the room's lights (Keypad
	-- Follows "Room/zone lights", O1, departure D20).
	it("with Keypad Follows on the room's lights, the hello's group report lights the keypad, not the tile", function()
		S:resync()
		answer_scene_gets()
		S:add_scene(F.scene_rids.relax, nil, function() end)
		fake.pair(bridge, scene, { light_id = SCENE_ID, bind = false })
		scene.Properties["Keypad Follows"] = "Room/zone lights"
		fake.as(scene, scene.OnDriverLateInit, "DIT_STARTUP")
		fake.pump()
		assert.equal("inactive", S:scene(F.scene_rids.relax).active)
		assert.is_true(S.group_on[F.grouped_light_rids.living_room], "the fixture's room is lit")
		for _, n in ipairs(proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGED")) do
			assert.equal(0, n.LIGHT_BRIGHTNESS_CURRENT, "the room is lit, but this scene is not the one playing")
		end
		local leds = proxy_calls(scene, "MATCH_LED_STATE")
		assert.is_true(#leds > 0)
		assert.is_true(leds[#leds].STATE, "the keypad reads the room's lights on")
	end)

	-- #469 D7: the bridge tells a scene that another one took over, which
	-- ends its held state, so its tile goes to 0: from Hue's event for a scene
	-- of an overlapping zone (the groups' lamps known), and at a resync after
	-- another scene played while the stream was down.
	it("a scene of an overlapping zone, and a resync after another scene played, take a held scene's tile to 0",
		function()
		local function status(rid, active)
			return '[{"creationtime":"2026-11-12T18:00:00Z","id":"9de116fc-0469-4a2b-8c3d-000000000469","type":"update",'
				.. '"data":[{"id":"' .. rid .. '","type":"scene","status":{"active":"' .. active .. '"}}]}]'
		end
		local function tile()
			local br = proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGED")
			return br[#br] and br[#br].LIGHT_BRIGHTNESS_CURRENT
		end
		-- Play Relax from the tile and let Hue call it inactive (a lamp changed
		-- by hand): held on, the tile lit.
		local function play_and_hold()
			bc4.fire_timers()  -- any recall window is over
			fake.as(scene, scene.ReceivedFromProxy, 5001, "ON", {})
			fake.pump()
			local put = bc4.last_transfer()
			fake.as(bridge, function()
				put:respond(200, '{"data":[{"rid":"' .. F.scene_rids.relax .. '","rtype":"scene"}],"errors":[]}')
			end)
			fake.pump()
			event(F.events.scene_inactive)
			fake.pump()
			scene.C4.fire_timers()  -- the one-a-second level throttle
			assert.is_true((tile() or 0) > 0, "held on")
		end

		S:resync()
		answer_scene_gets()
		L:absorb({ device = decode_data(F.device) })  -- the lamps: Downstairs holds the Living Room Lamp
		S:add_scene(F.scene_rids.relax, nil, function() end)
		fake.pair(bridge, scene, { light_id = SCENE_ID, bind = false })
		fake.as(scene, scene.OnDriverLateInit, "DIT_STARTUP")
		fake.pump()

		play_and_hold()
		bc4.sent = {}
		event(status(F.scene_rids.bright, "static"))  -- a Downstairs scene played in the Hue app
		assert.same({ rid = F.scene_rids.relax, other_active = "true" }, bc4.sent[1].params)
		fake.pump()
		scene.C4.fire_timers()
		assert.equal(0, tile(), "another scene has the Living Room Lamp")

		play_and_hold()
		bc4.sent = {}
		S:resync()
		answer_scene_gets(F.scene:gsub('"active":"static"', '"active":"inactive"')
			:gsub('("name":"Savanna sunset".-"active":)"inactive"', '%1"dynamic_palette"'))
		assert.same({ "HUE_SCENE_STATE", "HUE_SCENE_GROUP", "HUE_SCENE_GROUP" }, messages_to(bc4, SCENE_ID))
		assert.equal("true", bc4.sent[2].params.other_active)
		fake.pump()
		scene.C4.fire_timers()
		assert.equal(0, tile(), "Savanna sunset played while the stream was down")
	end)

	it("a dynamic scene recalled from the proxy ends up dynamic_palette, and Recall As Static makes it static", function()
		S:resync()
		answer_scene_gets()
		S:add_scene(F.scene_rids.savanna, nil, function() end)
		fake.pair(bridge, scene, { light_id = SCENE_ID, bind = false })
		fake.as(scene, scene.OnDriverLateInit, "DIT_STARTUP")
		fake.pump()
		assert.equal("Downstairs Savanna sunset" ~= bc4.added[1].name, true)
		assert.equal("Savanna sunset", bc4.added[1].name, "a room scene is named after the scene alone")

		scene.C4.calls = {}
		fake.as(scene, scene.ReceivedFromProxy, 5001, "SET_BRIGHTNESS_TARGET",
			{ LIGHT_BRIGHTNESS_TARGET = "100", RATE = "400" })
		fake.pump()
		local put = bc4.last_transfer()
		assert.same({ recall = { action = "active", duration = 400 } }, json.decode(put.data))
		fake.as(bridge, function()
			put:respond(200, '{"data":[{"rid":"' .. F.scene_rids.savanna .. '","rtype":"scene"}],"errors":[]}')
		end)
		fake.pump()
		scene.C4.advance(400) -- the 400 ms recall is a ramp: its report waits for its end (#421 S-D4)
		local br = proxy_calls(scene, "LIGHT_BRIGHTNESS_CHANGED")
		assert.equal(100, br[#br].LIGHT_BRIGHTNESS_CURRENT)
		assert.equal("dynamic_palette", S:scene(F.scene_rids.savanna).active)

		fake.as(scene, scene.OnPropertyChanged, "Recall As")
		scene.Properties["Recall As"] = "Static"
		fake.as(scene, scene.OnPropertyChanged, "Recall As")
		bc4.fire_timers()  -- the first recall's window (scenes.RECALL_WINDOW_MS) ended while Composer was open
		fake.as(scene, scene.ReceivedFromProxy, 5001, "ON", {})
		fake.pump()
		assert.same({ recall = { action = "static" } }, json.decode(bc4.last_transfer().data))

		-- Forget Device on the bridge: the bridge forgets, unbinds and answers
		-- HUE_SCENE_FORGOTTEN; the device stays with a Status that says what to do.
		fake.as(bridge, function() local _, text = S:forget(SCENE_ID); last_action = text end)
		fake.pump()
		assert.equal("Forgot Savanna sunset (device 2001): unbound and left in the project for you to delete; "
			.. "the Hue scene is listed under Add From Hue again", last_action)
		assert.equal(0, S:count())
		assert.equal(0, #bc4.bindings)
		assert.equal("Forgotten by the bridge (was Hue scene Savanna sunset). Delete this device, "
			.. "or bind it again and use Link Device on the Hue Bridge", scene.Properties["Status"])
		assert.equal(F.scene_rids.savanna, S:picker_scenes()[#S:picker_scenes()].value, "listed under Add From Hue again")
	end)

	-- #514 (docs/hdmi-sync-stage1-design.md §4.6, §5.2): lamps of the scene's
	-- room sync with the TV. The Living Room holds Hallway Ambiance and Living
	-- Room Lamp.
	it("tells the scene how many lamps of its room keep syncing with the TV, and when none does", function()
		-- A container with the lamps' `mode`, as driver.lua runs it: the lights
		-- take it, then the entertainment module's settle calls streaming_changed.
		local function modes(keys, mode)
			local items, rids = {}, {}
			for i, key in ipairs(keys) do
				rids[i] = F.rids[key]
				items[i] = '{"id":"' .. F.rids[key] .. '","mode":"' .. mode .. '","type":"light"}'
			end
			fake.as(bridge, function()
				local c = bridge.C4:JsonDecode('[{"creationtime":"2026-11-14T20:00:00Z",'
					.. '"id":"9de116fc-00e1-4a2b-8c3d-0000000000e1","type":"update","data":[' .. table.concat(items, ",")
					.. ']}]')[1]
				L:on_container(c)
				S:streaming_changed(rids)
				S:on_container(c)
			end)
			fake.pump()
		end

		L:absorb({ light = decode_data(F.light), device = decode_data(F.device) })
		S:resync()
		answer_scene_gets()
		S:add_scene(F.scene_rids.relax, nil, function() end)
		fake.pair(bridge, scene, { light_id = SCENE_ID, bind = false })
		fake.as(scene, scene.OnDriverLateInit, "DIT_STARTUP")
		fake.pump()
		assert.equal("Hue scene Relax in Living Room", scene.Properties["Status"])

		modes({ "living" }, "streaming")
		assert.equal("Hue scene Relax in Living Room; 1 lamp keeps syncing with the TV", scene.Properties["Status"])
		modes({ "hallway" }, "streaming")
		assert.equal("Hue scene Relax in Living Room; 2 lamps keep syncing with the TV", scene.Properties["Status"])
		modes({ "living", "hallway" }, "normal")
		assert.equal("Hue scene Relax in Living Room", scene.Properties["Status"], "streaming_lamps 0 clears it")
	end)
end)
