local json = require("dkjson")
local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_resources")

-- Rooms of the fake project: the default Living Room (7) and a Garage (8);
-- the Hue rooms Living Room and Garage are mapped to them, the Downstairs
-- zone is not (specs map it when they need to).
local LIVING_ROOM, GARAGE_ROOM = 7, 8

-- A sixth scene in the Attic zone, which has no grouped_light (the fixture's
-- empty zone), for the OFF-without-a-PUT case.
local ATTIC_RID = "5e4d3c2b-0000-4000-8000-00000000s0aa"
local ATTIC_ITEM = '{"id":"' .. ATTIC_RID .. '","id_v1":"/scenes/AtTiC0000000Dust","actions":[],'
	.. '"metadata":{"name":"Dusty"},"group":{"rid":"' .. F.group_rids.attic .. '","rtype":"zone"},'
	.. '"speed":0.5,"auto_dynamic":false,"status":{"active":"inactive"},"type":"scene"}'

local T0 = 1761000000

-- GET /grouped_light bodies: the default answer knows no group's on/off (so
-- resyncs send no HUE_SCENE_GROUP); grouped_lights({ living_room = true })
-- lists the named groups' grouped_lights with on.on.
local NO_GROUPED_LIGHTS = '{"errors":[],"data":[]}'
local function grouped_lights(on_by_key)
	local items = {}
	for _, key in ipairs({ "garage", "living_room", "downstairs", "home" }) do
		if on_by_key[key] ~= nil then
			items[#items + 1] = '{"id":"' .. F.grouped_light_rids[key] .. '","on":{"on":' .. tostring(on_by_key[key])
				.. '},"dimming":{"brightness":50.0},"type":"grouped_light"}'
		end
	end
	return '{"errors":[],"data":[' .. table.concat(items, ",") .. ']}'
end

-- A one-item event container for a grouped_light's on/off.
local function grouped_light_event(key, on)
	return '[{"creationtime":"2026-10-23T18:00:00Z","id":"9de116fc-00f0-4a2b-8c3d-0000000000f0","type":"update",'
		.. '"data":[{"id":"' .. F.grouped_light_rids[key] .. '","on":{"on":' .. tostring(on) .. '},"type":"grouped_light"}]}]'
end

describe("bridge.scenes", function()
	local scenes, lights, http, c4, L, S, results, logged, now, offs, dims

	local function http_ctx(req, cb)
		req.ip = "192.0.2.10"
		req.key = "k"
		return http.request(req, cb)
	end

	local function saw_log(text)
		for _, line in ipairs(logged) do
			if line:find(text, 1, true) then return true end
		end
		return false
	end

	local function done(ok, text)
		table.insert(results, { ok = ok, text = text })
	end

	local function last_result()
		return results[#results] or {}
	end

	local function decode_data(text)
		return json.decode(text).data
	end

	-- The lights' group cache and room mappings, filled without HTTP.
	local function new_lights()
		local l = lights.new({ http = http_ctx, now = function() return now end })
		l:absorb({ room = decode_data(F.room), zone = decode_data(F.zone), bridge_home = decode_data(F.bridge_home) })
		l.reg:set_room_mapping(F.group_rids.living_room, { c4_room_id = LIVING_ROOM, c4_room_name = "Living Room",
			hue_name = "Living Room", type = "room" })
		l.reg:set_room_mapping(F.group_rids.garage, { c4_room_id = GARAGE_ROOM, c4_room_name = "Garage",
			hue_name = "Garage", type = "room" })
		return l
	end

	local function new_scenes(extra)
		local ctx = { http = http_ctx, now = function() return now end, lights = L,
			group_off = function(rid) offs[#offs + 1] = rid; return true end,
			group_dim = function(rid, body) dims[#dims + 1] = { rid = rid, body = body }; return true end }
		for k, v in pairs(extra or {}) do ctx[k] = v end
		return scenes.new(ctx)
	end

	-- The scene fixture with the Attic scene appended, or with overrides.
	local function scene_body(opts)
		opts = opts or {}
		local body = opts.body or F.scene
		if opts.attic then
			body = body:gsub("%]}$", "," .. ATTIC_ITEM .. "]}")
		end
		return body
	end

	-- Answer the three serial GETs: /scene, /smart_scene, then /grouped_light.
	local function answer_gets(opts)
		opts = opts or {}
		local t = c4.last_transfer()
		assert.truthy(t, "expected a GET for scene")
		assert.equal("GET", t.method)
		assert.equal("https://192.0.2.10/clip/v2/resource/scene", t.url)
		t:respond(opts.scene_code or 200, scene_body(opts))
		if opts.scene_code and opts.scene_code ~= 200 then
			return
		end
		local t2 = c4.last_transfer()
		assert.equal("https://192.0.2.10/clip/v2/resource/smart_scene", t2.url)
		t2:respond(opts.smart_code or 200, opts.smart or F.smart_scene)
		local t3 = c4.last_transfer()
		assert.equal("https://192.0.2.10/clip/v2/resource/grouped_light", t3.url)
		t3:respond(opts.grouped_code or 200, opts.grouped or NO_GROUPED_LIGHTS)
	end

	local function resync(opts)
		S:resync(done)
		answer_gets(opts)
	end

	local function sent_to(device_id, command)
		local out = {}
		for _, m in ipairs(c4.sent) do
			if m.id == device_id and (command == nil or m.command == command) then
				out[#out + 1] = m
			end
		end
		return out
	end

	local function commands_sent()
		local out = {}
		for _, m in ipairs(c4.sent) do
			out[#out + 1] = m.command .. "@" .. m.id
		end
		return out
	end

	local function texts(list)
		local out = {}
		for i, item in ipairs(list) do out[i] = item.text end
		return out
	end

	local function values(list)
		local out = {}
		for i, item in ipairs(list) do out[i] = item.value end
		return out
	end

	local function container(text)
		return C4:JsonDecode(text)[1]
	end

	-- Plain-text replacement: rids contain "-", a pattern quantifier.
	local function replace(text, from, to)
		local escaped = from:gsub("%W", "%%%0")
		return (text:gsub(escaped, (to:gsub("%%", "%%%%"))))
	end

	-- Resync, then Add Scene for Relax (device 2001, Living Room).
	local function add_relax(opts)
		resync(opts)
		S:add_scene(F.scene_rids.relax, nil, done)
		return 2001
	end

	before_each(function()
		logged = {}
		log.sink = function(line) table.insert(logged, line) end
		log.set_debug(true)
		now = T0
		c4 = fake.install_c4()
		fake.add_room(GARAGE_ROOM, "Garage")
		for _, m in ipairs({ "bridge.http", "bridge.hue_model", "bridge.registry", "bridge.groups", "bridge.lights",
			"bridge.scenes" }) do
			package.loaded[m] = nil
		end
		http = require("bridge.http")
		lights = require("bridge.lights")
		scenes = require("bridge.scenes")
		results = {}
		offs = {}
		dims = {}
		L = new_lights()
		S = new_scenes()
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("new", function()
		it("requires http and persists under the scene keys", function()
			assert.has_error(function() scenes.new({}) end)
			assert.same({ lights = "hue_scenes", tombstones = "hue_scene_tombstones", rooms = false }, S.reg.keys)
			assert.equal("0 imported", S:summary())
			assert.equal(0, S:count())
			assert.equal("None", S:attention())
			assert.same({}, S:attention_items())
		end)
	end)

	describe("resync", function()
		it("GETs /scene, /smart_scene and /grouped_light with the key, caches scenes and counts smart ones", function()
			S:resync(done)
			assert.equal(1, #c4.transfers)
			assert.equal("k", c4.transfers[1].headers["hue-application-key"])
			c4.transfers[1]:respond(200, F.scene)
			assert.equal(2, #c4.transfers)
			c4.transfers[2]:respond(200, F.smart_scene)
			assert.equal(3, #c4.transfers)
			assert.is_nil(last_result().ok, "done waits for the grouped_light GET")
			assert.equal("k", c4.transfers[3].headers["hue-application-key"])
			c4.transfers[3]:respond(200, grouped_lights({ living_room = true, garage = false }))
			assert.same({ ok = true, text = nil }, last_result())
			assert.equal(5, S:bridge_count())
			assert.equal(1, S.smart_scenes)
			assert.equal("5 on bridge, 0 imported, 0 missing, 0 unbound, 0 deleted", S:summary())
			assert.equal(0, #c4.sent, "nothing registered, nothing told")
			local relax = S:scene(F.scene_rids.relax)
			assert.equal("Relax", relax.name)
			assert.equal(F.group_rids.living_room, relax.group_rid)
			assert.equal("inactive", relax.active)
			assert.equal("static", S:scene(F.scene_rids.nightlight).active)
			assert.is_true(S:scene(F.scene_rids.savanna).auto_dynamic)
			assert.is_nil(relax.actions, "the catalogue is compact")
			assert.is_true(saw_log("5 scenes cached, 1 smart scenes"))
			assert.same({ [F.grouped_light_rids.living_room] = true, [F.grouped_light_rids.garage] = false }, S.group_on)
		end)

		it("fails on a failed /scene GET and survives a failed /smart_scene GET", function()
			resync({ scene_code = 500 })
			assert.is_false(last_result().ok)
			assert.equal("GET /clip/v2/resource/scene: HTTP 500", last_result().text)
			assert.is_false(S.synced)
			resync({ smart_code = 503 })
			assert.is_true(last_result().ok)
			assert.is_nil(S.smart_scenes)
			assert.is_true(saw_log("smart scenes not counted"))
			assert.equal(5, S:bridge_count())
		end)

		it("survives a failed /grouped_light GET, which leaves the groups' on/off unknown", function()
			resync({ grouped = grouped_lights({ living_room = true }) })
			assert.is_true(S.group_on[F.grouped_light_rids.living_room])
			resync({ grouped_code = 503 })
			assert.is_true(last_result().ok)
			assert.same({}, S.group_on)
			assert.is_true(saw_log("group on/off unknown"))
			assert.equal(5, S:bridge_count())
		end)

		it("runs a resync requested during a resync once more afterwards, latest done wins", function()
			S:resync(function() done(true, "first") end)
			S:resync(function() done(true, "second") end)
			S:resync(function() done(true, "third") end)
			answer_gets()
			assert.equal("first", last_result().text)
			assert.equal(4, #c4.transfers, "the pending resync started")
			answer_gets()
			assert.equal("third", last_result().text)
			assert.equal(2, #results)
		end)

		it("refuses actions while resyncing", function()
			S:resync(done)
			S:add_scene(F.scene_rids.relax, nil, done)
			assert.equal("Busy: resyncing scenes; try again in a moment", last_result().text)
			assert.same({ false, "Busy: resyncing scenes; try again in a moment" }, { S:relink(2001, F.scene_rids.relax) })
			assert.equal("Busy: resyncing scenes; try again in a moment", S:link_devices())
		end)
	end)

	describe("add_scene", function()
		it("refuses without a scene, an unknown scene, and a scene already imported", function()
			S:add_scene("", nil, done)
			assert.same({ ok = false, text = "Not added: pick a scene first" }, last_result())
			S:add_scene(F.scene_rids.relax, nil, done)
			assert.equal("Not added: scene " .. F.scene_rids.relax .. " is not on the bridge (Refresh Scenes and try again)",
				last_result().text)
			add_relax()
			assert.equal(1, #c4.added)
			S:add_scene(F.scene_rids.relax, nil, done)
			assert.same({ ok = false, text = "Not added: Relax is already imported (device 2001)" }, last_result())
			assert.equal(1, #c4.added)
		end)

		it("creates a room scene in its mapped room: AddDevice, Bind, registry, save, CONFIGURE + STATE", function()
			add_relax()
			assert.same({ ok = true, text = "Added Relax to Living Room (device 2001)" }, last_result())
			assert.same({ { id = 2001, driver = "hue_scene.c4z", room = LIVING_ROOM, name = "Relax" } }, c4.added)
			assert.same({ { provider = 15, provider_binding = 1, consumer = 2001, consumer_binding = 1, class = "HUE_BRIDGE" } },
				c4.bindings)
			local entry = S:entry(F.scene_rids.relax)
			assert.equal(2001, entry.device_id)
			assert.equal("Relax", entry.name)
			assert.equal(F.group_rids.living_room, entry.group_rid)
			assert.equal("room", entry.group_type)
			assert.equal("Living Room", entry.group_name)
			assert.equal(F.scene_id_v1.relax, entry.id_v1)
			assert.is_false(entry.auto_dynamic)
			assert.equal("linked", entry.state)
			assert.equal(LIVING_ROOM, entry.created_room_id)
			assert.equal(T0, entry.created_at)
			assert.equal(2001, c4.persist.hue_scenes[F.scene_rids.relax].device_id)
			assert.is_nil(c4.persist.hue_lights, "the lights' key is untouched")
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.same({ rid = F.scene_rids.relax, name = "Relax", group_name = "Living Room", group_type = "room",
				id_v1 = F.scene_id_v1.relax, auto_dynamic = "false", state = "linked" }, c4.sent[1].params)
			assert.same({ rid = F.scene_rids.relax, active = "inactive", reason = "resync" }, c4.sent[2].params)
			assert.equal("5 on bridge, 1 imported, 0 missing, 0 unbound, 0 deleted", S:summary())
			assert.equal(2001, S:device_for(F.scene_rids.relax))
			assert.equal(F.scene_rids.relax, S:rid_for(2001))
			assert.is_true(saw_log("scenes: Added Relax to Living Room (device 2001)"))
		end)

		it("names a zone scene '<Zone> <Scene>' and takes the room given; a dynamic scene says so", function()
			resync()
			S:add_scene(F.scene_rids.nightlight, tostring(GARAGE_ROOM), done)
			assert.same({ ok = true, text = "Added Nightlight to Garage (device 2001)" }, last_result())
			assert.equal("Downstairs Nightlight", c4.added[1].name)
			assert.equal(GARAGE_ROOM, c4.added[1].room)
			assert.equal("zone", S:entry(F.scene_rids.nightlight).group_type)
			assert.same({ rid = F.scene_rids.nightlight, active = "static", reason = "resync" }, c4.sent[2].params)
			assert.equal("Downstairs", c4.sent[1].params.group_name)
			S:add_scene(F.scene_rids.savanna, nil, done)
			assert.equal("Added Savanna sunset to Living Room (device 2002)", last_result().text)
			assert.equal("true", sent_to(2002, "HUE_SCENE_CONFIGURE")[1].params.auto_dynamic)
			assert.is_true(S:entry(F.scene_rids.savanna).auto_dynamic)
		end)

		it("refuses a scene whose Hue room is unmapped unless a room is picked, and a room that is gone", function()
			resync()
			S:add_scene(F.scene_rids.nightlight, nil, done)
			assert.same({ ok = false, text = "Not added: Nightlight: Hue room Downstairs (zone) not mapped; pick a room, "
				.. "or Set Room Mapping first" }, last_result())
			S:add_scene(F.scene_rids.nightlight, "99", done)
			assert.same({ ok = false, text = "Not added: Control4 room 99 no longer exists" }, last_result())
			assert.equal(0, #c4.added)
			L.reg:set_room_mapping(F.group_rids.downstairs, { c4_room_id = 99, c4_room_name = "Cellar", hue_name = "Downstairs",
				type = "zone" })
			S:add_scene(F.scene_rids.nightlight, nil, done)
			assert.equal("Not added: Nightlight: Hue room Downstairs (zone) mapped to a Control4 room that no longer exists; "
				.. "pick a room, or Set Room Mapping first", last_result().text)
		end)

		it("reports an AddDevice failure", function()
			resync()
			c4.AddDevice = function(_, _, _, _, cb) cb(0, nil) end
			S:add_scene(F.scene_rids.relax, nil, done)
			assert.same({ ok = false, text = "Not added: AddDevice failed for Relax (see the Lua output)" }, last_result())
			assert.equal(0, S:count())
			assert.is_true(saw_log("AddDevice failed for Relax"))
		end)

		it("binds the protocol id and keeps the proxy id from the OS 3.4.2 callback info", function()
			resync()
			S = new_scenes({ add_device = function(driver, room_id, name, cb)
				C4:AddDevice(driver, room_id, name, function(id)
					cb(id, { Name = "devices", ChildNodes = {
						{ Name = "protocol", Value = tostring(id) }, { Name = "proxy", Value = "3001" } } })
				end)
			end })
			resync()
			S:add_scene(F.scene_rids.relax, nil, done)
			assert.equal(2001, S:entry(F.scene_rids.relax).device_id)
			assert.equal(3001, S:proxy_for(F.scene_rids.relax))
			assert.is_true(saw_log("AddDevice callback for scene Relax"))
		end)
	end)

	describe("add_all_of_group", function()
		it("refuses without a group, an unknown group, an unmapped group and a group without scenes", function()
			resync()
			S:add_all_of_group("", done)
			assert.same({ ok = false, text = "Not added: pick a Hue room first" }, last_result())
			S:add_all_of_group("nope", done)
			assert.equal("Not added: Hue room nope is not on the bridge (connect the event stream and try again)",
				last_result().text)
			S:add_all_of_group(F.group_rids.downstairs, done)
			assert.same({ ok = false, text = "Not added: Hue room Downstairs (zone) not mapped; Set Room Mapping first" },
				last_result())
			S:add_all_of_group(F.group_rids.attic, done)
			assert.same({ ok = false, text = "Not added: Attic (zone) has no scenes" }, last_result())
			assert.equal(0, #c4.added)
		end)

		it("adds every unimported scene of the group in name order into the mapped room, then has nothing to add", function()
			resync()
			S:add_all_of_group(F.group_rids.living_room, done)
			assert.same({ ok = true, text = "Added 2 scenes of Living Room to Living Room: Relax (device 2001), "
				.. "Savanna sunset (device 2002)" }, last_result())
			assert.same({ "Relax", "Savanna sunset" }, { c4.added[1].name, c4.added[2].name })
			assert.equal(LIVING_ROOM, c4.added[2].room)
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001", "HUE_SCENE_CONFIGURE@2002",
				"HUE_SCENE_STATE@2002" }, commands_sent())
			S:add_all_of_group(F.group_rids.living_room, done)
			assert.same({ ok = true, text = "No new scenes in Living Room (2 on bridge, 2 imported)" }, last_result())
			assert.equal(2, #c4.added)
		end)

		it("skips and lists scenes deleted in Composer; Add Scene re-creates one", function()
			resync()
			S:add_all_of_group(F.group_rids.living_room, done)
			now = T0 + 100
			S:goodbye({ rid = F.scene_rids.relax, device_id = "2001" })
			local date = os.date("%Y-%m-%d", T0 + 100)
			S:add_all_of_group(F.group_rids.living_room, done)
			assert.same({ ok = true, text = "Added no scenes; skipped 1 deleted in Composer (Add Scene re-creates one): "
				.. "Relax (deleted " .. date .. ")" }, last_result())
			assert.equal(2, #c4.added)
			S:add_scene(F.scene_rids.relax, nil, done)
			assert.equal("Added Relax to Living Room (device 2003)", last_result().text)
			assert.is_nil(c4.persist.hue_scene_tombstones[F.scene_rids.relax])
		end)

		it("zone scenes get the zone's name in front, in the zone's mapped room", function()
			resync()
			L.reg:set_room_mapping(F.group_rids.downstairs, { c4_room_id = GARAGE_ROOM, c4_room_name = "Garage",
				hue_name = "Downstairs", type = "zone" })
			S:add_all_of_group(F.group_rids.downstairs, done)
			assert.equal("Added 2 scenes of Downstairs (zone) to Garage: Bright (device 2001), Nightlight (device 2002)",
				last_result().text)
			assert.same({ "Downstairs Bright", "Downstairs Nightlight" }, { c4.added[1].name, c4.added[2].name })
		end)
	end)

	describe("events", function()
		it("mirrors a recall and the status going inactive onto the scene device, with its group's on", function()
			add_relax()
			c4.sent = {}
			assert.equal(2, S:on_container(container(F.events.scene_recalled)))
			assert.same({ { id = 2001, command = "HUE_SCENE_GROUP", params = { rid = F.scene_rids.relax, on = "true" } },
				{ id = 2001, command = "HUE_SCENE_STATE",
				params = { rid = F.scene_rids.relax, active = "static", reason = "event" } } }, c4.sent)
			assert.equal("static", S:scene(F.scene_rids.relax).active)
			c4.sent = {}
			assert.equal(1, S:on_container(container(F.events.scene_inactive)))
			assert.equal("inactive", c4.sent[1].params.active)
		end)

		it("follows a rename: the entry's name, a new CONFIGURE, the Composer name untouched", function()
			add_relax()
			c4.sent = {}
			assert.equal(1, S:on_container(container(F.events.scene_renamed)))
			assert.equal("Chill", S:entry(F.scene_rids.relax).name)
			assert.equal("Chill", c4.sent[1].params.name)
			assert.equal("HUE_SCENE_CONFIGURE", c4.sent[1].command)
			assert.equal(0, #c4.renamed)
			assert.is_true(saw_log("Relax was renamed to Chill in Hue (Composer name unchanged)"))
			assert.equal("Chill", c4.persist.hue_scenes[F.scene_rids.relax].name)
		end)

		it("updates the catalogue for unimported scenes without telling anyone", function()
			resync()
			assert.equal(0, S:on_container(container(F.events.scene_dynamic)))
			assert.equal("dynamic_palette", S:scene(F.scene_rids.savanna).active)
			assert.equal(0, S:on_container(container(F.events.scene_added)))
			assert.equal("Read", S:scene(F.new_scene_rid).name)
			assert.equal(0, #c4.added, "nothing is created from an event")
			assert.equal(6, S:bridge_count())
			assert.is_true(saw_log("new scene Living Room: Read on the bridge; Add Scene lists it"))
		end)

		it("ignores an update for a scene the resync has not brought, and non-scene containers", function()
			assert.equal(0, S:on_container(container(F.events.scene_recalled)))
			assert.is_nil(S:scene(F.scene_rids.relax))
			assert.equal(0, S:on_container(container(F.events.brightness)))
			assert.equal(0, S:on_container("garbage"))
		end)

		it("marks a linked scene gone on delete: CONFIGURE state gone and STATE inactive, then back on add", function()
			add_relax()
			S:on_container(container(F.events.scene_recalled))
			c4.sent = {}
			now = T0 + 50
			assert.equal(1, S:on_container(container(F.events.scene_deleted)))
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.equal("gone", c4.sent[1].params.state)
			assert.equal(tostring(T0 + 50), c4.sent[1].params.gone_since)
			assert.same({ rid = F.scene_rids.relax, active = "inactive", reason = "event" }, c4.sent[2].params)
			assert.equal("gone", S:entry(F.scene_rids.relax).state)
			assert.equal("4 on bridge, 1 imported, 1 missing, 0 unbound, 0 deleted", S:summary())
			assert.equal("1 scene missing from the bridge: Relax (device 2001, since " .. os.date("%Y-%m-%d", T0 + 50)
				.. ") (Re-link Scene or Forget Scene)", S:attention())
			assert.is_true(saw_log("Relax (device 2001) was deleted on the bridge; marked gone"))
			assert.equal("gone", c4.persist.hue_scenes[F.scene_rids.relax].state)

			c4.sent = {}
			local back = replace(F.events.scene_added, F.new_scene_rid, F.scene_rids.relax)
			assert.equal(1, S:on_container(container(back)))
			assert.equal("linked", S:entry(F.scene_rids.relax).state)
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.equal("linked", c4.sent[1].params.state)
			assert.equal("Read", c4.sent[1].params.name, "the re-added scene's name")
			assert.is_true(saw_log("Relax (device 2001) is back on the bridge"), "logged under the name the owner knows")
			assert.equal("Read", S:entry(F.scene_rids.relax).name)
			-- Not missing any more; the Composer device is still called Relax, which Attention now points out.
			assert.equal("1 Hue scene name differs from the Composer names: Relax is Read in Hue "
				.. "(Adopt Hue Names or Accept Names As They Are)", S:attention())
		end)

		it("a delete of an unimported or unbound scene changes nothing visible", function()
			add_relax()
			S:on_binding_changed(1, "HUE_BRIDGE", false, 2001)
			c4.sent = {}
			assert.equal(0, S:on_container(container(F.events.scene_deleted)))
			assert.equal("unbound", S:entry(F.scene_rids.relax).state)
			assert.is_nil(S:scene(F.scene_rids.relax))
		end)

		it("tells scene devices about a renamed Hue room once the lights' cache has it", function()
			add_relax()
			c4.sent = {}
			local renamed = container(F.events.room_rename)
			L:on_container(renamed)
			c4.sent = {}
			assert.equal(1, S:on_container(renamed))
			assert.equal("Lounge", c4.sent[1].params.group_name)
			assert.equal("Lounge", S:entry(F.scene_rids.relax).group_name)
			assert.same({ "Lounge: Savanna sunset (dynamic)" }, { texts(S:picker_scenes())[4] },
				"catalogue labels are read from the live cache")
		end)

		it("does not send state to an unbound scene device", function()
			add_relax()
			S:on_binding_changed(1, "HUE_BRIDGE", false, 2001)
			c4.sent = {}
			assert.equal(0, S:on_container(container(F.events.scene_recalled)))
			assert.equal(0, #c4.sent)
		end)
	end)

	describe("resync reconciliation", function()
		it("marks a registered scene gone when the GET lacks it, and linked when it returns", function()
			add_relax()
			c4.sent = {}
			now = T0 + 10
			resync({ body = F.scene:gsub(replace(F.scene_rids.relax, "-", "%-"), "deadbeef-0000-4000-8000-000000000000") })
			assert.equal("gone", S:entry(F.scene_rids.relax).state)
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.equal("gone", c4.sent[1].params.state)
			assert.equal("inactive", c4.sent[2].params.active)
			assert.equal("resync", c4.sent[2].params.reason)
			assert.is_true(saw_log("Relax (device 2001) is no longer on the bridge; marked gone "
				.. "(Re-link Scene or Forget Scene)"))
			assert.same({ "Living Room: Relax (device 2001, gone since " .. os.date("%m-%d", T0 + 10) .. ")" },
				texts(S:picker_relink_devices()))
			c4.sent = {}
			resync()
			assert.equal("linked", S:entry(F.scene_rids.relax).state)
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.equal("linked", c4.sent[1].params.state)
			assert.is_true(saw_log("Relax (device 2001) is back on the bridge"))
		end)

		it("sends STATE to every linked scene at each resync, CONFIGURE only when it changed", function()
			add_relax()
			c4.sent = {}
			resync()
			assert.same({ "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.equal("resync", c4.sent[1].params.reason)
			resync({ body = F.scene:gsub('"name":"Relax"', '"name":"Chill"') })
			assert.same({ "HUE_SCENE_STATE@2001", "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.equal("Chill", c4.sent[2].params.name)
		end)

		it("finds devices unbound or deleted in Composer through the project", function()
			add_relax()
			S:add_scene(F.scene_rids.concentrate, nil, done)
			c4.sent = {}
			c4.bindings = {}
			now = T0 + 20
			local r = S:reconcile()
			assert.same({ F.scene_rids.concentrate, F.scene_rids.relax }, r.unbound)
			assert.equal("unbound", S:entry(F.scene_rids.relax).state)
			assert.equal("5 on bridge, 2 imported, 0 missing, 2 unbound, 0 deleted", S:summary())
			assert.equal("2 unbound scene devices: Concentrate (device 2002), Relax (device 2001) (bind it to this bridge in "
				.. "Composer, or Forget Scene)", S:attention())
			assert.is_true(saw_log("Relax (device 2001) is not bound to this bridge"))

			fake.project.devices[2001] = nil
			fake.project.devices[3001] = nil
			r = S:reconcile()
			assert.same({ F.scene_rids.relax }, r.tombstoned)
			assert.is_nil(S:entry(F.scene_rids.relax))
			assert.equal("Relax", c4.persist.hue_scene_tombstones[F.scene_rids.relax].name)
			assert.equal("5 on bridge, 1 imported, 0 missing, 1 unbound, 1 deleted", S:summary())
			assert.is_true(saw_log("Relax was deleted in Composer while the bridge was not watching"))

			c4:Bind(15, 1, 2002, 1, "HUE_BRIDGE")
			c4.sent = {}
			r = S:reconcile()
			assert.same({ F.scene_rids.concentrate }, r.relinked)
			assert.same({ "HUE_SCENE_CONFIGURE@2002", "HUE_SCENE_STATE@2002" }, commands_sent())
		end)

		it("treats a failed bound lookup as unknown and an empty project lookup as not deleted", function()
			add_relax()
			S = new_scenes({ project = { bound = function() error("boom") end } })
			S:load()
			local r = S:reconcile()
			assert.same({ unbound = {}, relinked = {}, tombstoned = {} }, r)
			assert.is_true(saw_log("reconcile skipped"))
			S = new_scenes({ project = { devices = function() return {} end } })
			S:load()
			c4.bindings = {}
			r = S:reconcile()
			assert.same({ F.scene_rids.relax }, r.unbound)
			assert.same({}, r.tombstoned)
		end)
	end)

	describe("hello", function()
		it("answers a known rid with CONFIGURE and STATE, a stale rid with the device's own scene", function()
			add_relax()
			c4.sent = {}
			assert.is_true(S:hello(F.scene_rids.relax, { device_id = "2001" }))
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.equal("hello", c4.sent[2].params.reason)
			c4.sent = {}
			assert.is_true(S:hello("stale", { device_id = "2001" }))
			assert.equal(F.scene_rids.relax, c4.sent[1].params.rid)
			assert.is_true(S:hello(F.scene_rids.relax), "a hello without a device id is answered too")
			assert.is_false(S:hello(nil, { device_id = "2099" }), "a bare unknown device waits for Link Devices")
			assert.is_false(S:hello("nope"))
		end)

		it("answers with the configuration alone before the first GET", function()
			c4.persist.hue_scenes = { [F.scene_rids.relax] = { device_id = 2001, name = "Relax",
				group_rid = F.group_rids.living_room, group_type = "room", group_name = "Living Room", state = "linked",
				auto_dynamic = "false" } }
			S:load()
			assert.is_true(S:hello(F.scene_rids.relax, { device_id = "2001" }))
			assert.same({ "HUE_SCENE_CONFIGURE@2001" }, commands_sent())
			assert.equal("Living Room", c4.sent[1].params.group_name)
			assert.equal("false", c4.sent[1].params.auto_dynamic)
			assert.is_false(S:entry(F.scene_rids.relax).auto_dynamic, "persisted strings are normalised")
		end)

		it("adopts a bound device announcing a rid the registry lacks, and marks it gone when not on the bridge", function()
			resync()
			c4:Bind(15, 1, 2099, 1, "HUE_BRIDGE")
			assert.is_true(S:hello(F.scene_rids.relax, { device_id = "2099", name = "Relax" }))
			local entry = S:entry(F.scene_rids.relax)
			assert.equal(2099, entry.device_id)
			assert.equal("Living Room", entry.group_name)
			assert.equal(F.scene_id_v1.relax, entry.id_v1)
			assert.same({ "HUE_SCENE_CONFIGURE@2099", "HUE_SCENE_STATE@2099" }, commands_sent())
			assert.is_true(saw_log("adopted Relax (device 2099) from its own persisted rid"))
			assert.equal(2099, c4.persist.hue_scenes[F.scene_rids.relax].device_id)

			c4:Bind(15, 1, 2098, 1, "HUE_BRIDGE")
			assert.is_true(S:hello("vanished", { device_id = "2098", name = "Old" }))
			assert.equal("gone", S:entry("vanished").state)
			assert.equal("Old", S:entry("vanished").name)
			assert.equal("gone", sent_to(2098, "HUE_SCENE_CONFIGURE")[1].params.state)
		end)

		it("does not adopt an unbound device, and two devices claiming one scene go to Attention", function()
			add_relax()
			assert.is_false(S:hello(F.scene_rids.savanna, { device_id = "2099" }))
			assert.is_nil(S:entry(F.scene_rids.savanna))
			assert.is_true(saw_log("device 2099 announced"))
			assert.is_false(S:hello(F.scene_rids.relax, { device_id = "2099" }))
			assert.equal(2001, S:entry(F.scene_rids.relax).device_id)
			assert.equal("2 devices claim Hue scene Relax: 2001 and 2099 (Forget Scene on one of them)", S:attention())
			-- Two devices announcing one unregistered scene: neither is adopted.
			assert.is_false(S:hello(F.scene_rids.bright, { device_id = "2098" }), "not bound: remembered, not adopted")
			c4:Bind(15, 1, 2097, 1, "HUE_BRIDGE")
			assert.is_false(S:hello(F.scene_rids.bright, { device_id = "2097" }))
			assert.is_nil(S:entry(F.scene_rids.bright))
			assert.truthy(S:attention():find("2 devices claim Hue scene Downstairs (zone): Bright: 2098 and 2097 "
				.. "(Forget Scene on one of them)", 1, true))
			assert.is_true(saw_log("devices 2098 and 2097 both announce"))
		end)

		it("queues a hello that arrives before load() and answers it from configure_all()", function()
			c4.persist.hue_scenes = { [F.scene_rids.relax] = { device_id = 2001, name = "Relax", state = "linked" } }
			assert.is_false(S:hello(F.scene_rids.relax, { device_id = "2001" }))
			assert.equal(0, #c4.sent)
			S:load()
			assert.equal(1, S:configure_all())
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_CONFIGURE@2001" }, commands_sent())
		end)
	end)

	describe("goodbye and tombstones", function()
		it("tombstones the entry; pickers list it last as deleted; Add Scene clears it", function()
			add_relax()
			now = T0 + 100
			local tomb = S:goodbye({ rid = F.scene_rids.relax, device_id = "2001" })
			assert.same({ name = "Relax", device_name = nil, deleted_at = T0 + 100 }, tomb)
			assert.is_nil(S:entry(F.scene_rids.relax))
			assert.same(tomb, c4.persist.hue_scene_tombstones[F.scene_rids.relax])
			assert.equal("5 on bridge, 0 imported, 0 missing, 0 unbound, 1 deleted", S:summary())
			assert.equal("None", S:attention())
			local date = os.date("%Y-%m-%d", T0 + 100)
			local list = texts(S:picker_scenes())
			assert.equal("Living Room: Relax (deleted from Composer " .. date .. ")", list[#list])
			assert.is_true(saw_log("Relax (device 2001) was deleted in Composer; Add Scene lists it as deleted"))
			S:add_scene(F.scene_rids.relax, nil, done)
			assert.equal("Added Relax to Living Room (device 2002)", last_result().text)
			assert.is_nil(c4.persist.hue_scene_tombstones[F.scene_rids.relax])
		end)

		it("finds the entry by device id alone, by rid alone, and ignores strangers", function()
			add_relax()
			S:add_scene(F.scene_rids.concentrate, nil, done)
			assert.truthy(S:goodbye({ device_id = "2001" }))
			assert.truthy(S:goodbye({ rid = F.scene_rids.concentrate }))
			assert.is_nil(S:goodbye({ rid = F.scene_rids.bright, device_id = "999" }))
			assert.is_nil(S:goodbye({}))
			assert.equal(0, S:count())
		end)
	end)

	describe("on_binding_changed", function()
		it("marks an entry unbound on binding 1 false and linked again on true, ignoring other bindings", function()
			add_relax()
			c4.sent = {}
			now = T0 + 7
			assert.is_true(S:on_binding_changed(1, "HUE_BRIDGE", false, "2001"))
			assert.equal("unbound", S:entry(F.scene_rids.relax).state)
			assert.equal(T0 + 7, S:entry(F.scene_rids.relax).unbound_since)
			assert.is_true(saw_log("Relax (device 2001) was unbound from the bridge"))
			assert.is_false(S:on_binding_changed(1, "HUE_BRIDGE", false, 2001), "already unbound")
			assert.is_true(S:on_binding_changed(1, "HUE_BRIDGE", true, 2001))
			assert.equal("linked", S:entry(F.scene_rids.relax).state)
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.is_false(S:on_binding_changed(5001, nil, false, 2001))
			assert.is_false(S:on_binding_changed(1, "OTHER", false, 2001))
			assert.is_false(S:on_binding_changed(1, "HUE_BRIDGE", false, 4242), "a light, not ours")
			assert.equal("linked", S:entry(F.scene_rids.relax).state)
		end)
	end)

	describe("recall", function()
		local function respond_ok(t)
			t:respond(200, '{"data":[{"rid":"' .. F.scene_rids.relax .. '","rtype":"scene"}],"errors":[]}')
		end

		it("PUTs the recall and reports the resulting state when the bridge accepts it", function()
			add_relax()
			c4.sent = {}
			local n = #c4.transfers
			assert.is_true(S:recall({ rid = F.scene_rids.relax, action = "active" }))
			assert.equal(n + 1, #c4.transfers)
			local put = c4.last_transfer()
			assert.equal("PUT", put.method)
			assert.equal("https://192.0.2.10/clip/v2/resource/scene/" .. F.scene_rids.relax, put.url)
			assert.equal("k", put.headers["hue-application-key"])
			assert.same({ recall = { action = "active" } }, json.decode(put.data))
			assert.equal(0, #c4.sent, "nothing until the PUT answers")
			respond_ok(put)
			assert.same({ { id = 2001, command = "HUE_SCENE_STATE",
				params = { rid = F.scene_rids.relax, active = "static", reason = "recall" } } }, c4.sent)
			assert.equal("static", S:scene(F.scene_rids.relax).active)
			assert.is_true(saw_log("recall Relax as active (device 2001)"))
		end)

		it("lets an OFF issued before the recall's PUT answers win: the late callback reports nothing", function()
			add_relax()
			S:recall({ rid = F.scene_rids.relax, action = "active" })
			local put = c4.last_transfer()
			assert.is_true(S:off({ rid = F.scene_rids.relax }))
			assert.equal("inactive", S:scene(F.scene_rids.relax).active)
			c4.sent = {}
			respond_ok(put)
			assert.same({}, c4.sent, "the superseded recall stays silent")
			assert.equal("inactive", S:scene(F.scene_rids.relax).active)
		end)

		it("reports the unchanged state when OFF could queue nothing", function()
			add_relax()
			S:recall({ rid = F.scene_rids.relax, action = "active" })
			respond_ok(c4.last_transfer())
			local real = S.ctx.group_off
			S.ctx.group_off = function() return false end
			c4.sent = {}
			assert.is_false(S:off({ rid = F.scene_rids.relax }))
			S.ctx.group_off = real
			assert.equal("static", S:scene(F.scene_rids.relax).active)
			assert.equal("static", c4.sent[1].params.active)
		end)

		it("maps active to dynamic_palette for an auto_dynamic scene, static and dynamic_palette as asked", function()
			resync()
			S:add_scene(F.scene_rids.savanna, nil, done)
			c4.sent = {}
			S:recall({ rid = F.scene_rids.savanna })
			respond_ok(c4.last_transfer())
			assert.equal("dynamic_palette", c4.sent[1].params.active)
			S:recall({ rid = F.scene_rids.savanna, action = "static" })
			assert.same({ recall = { action = "static" } }, json.decode(c4.last_transfer().data))
			respond_ok(c4.last_transfer())
			assert.equal("static", c4.sent[2].params.active)
			S:recall({ rid = F.scene_rids.savanna, action = "dynamic_palette", duration = "400" })
			assert.same({ recall = { action = "dynamic_palette", duration = 400 } }, json.decode(c4.last_transfer().data))
			respond_ok(c4.last_transfer())
			assert.equal("dynamic_palette", c4.sent[3].params.active)
		end)

		it("passes a brightness 1-100 as recall.dimming and ignores one out of range", function()
			add_relax()
			S:recall({ rid = F.scene_rids.relax, action = "active", brightness = "1" })
			assert.same({ recall = { action = "active", dimming = { brightness = 1 } } }, json.decode(c4.last_transfer().data))
			respond_ok(c4.last_transfer())
			S:recall({ rid = F.scene_rids.relax, brightness = "100" })
			assert.same({ brightness = 100 }, json.decode(c4.last_transfer().data).recall.dimming)
			respond_ok(c4.last_transfer())
			for _, bad in ipairs({ "0", "101", "-3", "lots" }) do
				S:recall({ rid = F.scene_rids.relax, brightness = bad })
				assert.same({ recall = { action = "active" } }, json.decode(c4.last_transfer().data))
				respond_ok(c4.last_transfer())
			end
			assert.is_true(saw_log("recall brightness 101 for Relax out of range"))
			S:recall({ rid = F.scene_rids.relax, brightness = "" })
			assert.same({ recall = { action = "active" } }, json.decode(c4.last_transfer().data))
		end)

		it("treats an unknown action as active with a warning", function()
			add_relax()
			S:recall({ rid = F.scene_rids.relax, action = "sideways" })
			assert.same({ recall = { action = "active" } }, json.decode(c4.last_transfer().data))
			assert.is_true(saw_log("unknown recall action sideways"))
		end)

		it("on failure warns and sends the cached status so the switch settles", function()
			add_relax()
			S:on_container(container(F.events.scene_recalled))
			c4.sent = {}
			S:recall({ rid = F.scene_rids.relax })
			c4.last_transfer():respond(404, '{"errors":[{"description":"Not Found"}],"data":[]}')
			assert.same({ rid = F.scene_rids.relax, active = "static", reason = "recall" }, c4.sent[1].params)
			assert.is_true(saw_log("Relax (device 2001): Recall failed: HTTP 404 (scene gone?)"))
			S:recall({ rid = F.scene_rids.relax })
			c4.last_transfer():respond(503, "")
			assert.is_true(saw_log("Recall failed: HTTP 503"))
			S:recall({ rid = F.scene_rids.relax })
			c4.last_transfer():done(7, "Couldn't connect")
			assert.is_true(saw_log("Recall failed: transfer failed (7): Couldn't connect"))
			assert.equal(3, #c4.sent)
		end)

		it("does not PUT for a gone scene, an unregistered scene or a missing rid; a gone one settles OFF", function()
			add_relax()
			S:on_container(container(F.events.scene_deleted))
			c4.sent = {}
			local n = #c4.transfers
			assert.is_false(S:recall({ rid = F.scene_rids.relax, action = "active" }))
			assert.equal(n, #c4.transfers)
			assert.same({ rid = F.scene_rids.relax, active = "inactive", reason = "recall" }, c4.sent[1].params)
			assert.is_true(saw_log("recall of Relax (device 2001) ignored: scene deleted in Hue since"))
			assert.is_false(S:recall({ rid = F.scene_rids.bright }))
			assert.is_true(saw_log("HUE_SCENE_RECALL for unregistered scene"))
			assert.is_false(S:recall({}))
			assert.is_true(saw_log("HUE_SCENE_RECALL without a rid ignored"))
			assert.equal(1, #c4.sent)
		end)

		it("drops the answer when the device was re-linked or forgotten while the PUT was in flight", function()
			add_relax()
			c4.sent = {}
			S:recall({ rid = F.scene_rids.relax })
			local put = c4.last_transfer()
			S:forget(2001)
			c4.sent = {}
			respond_ok(put)
			assert.equal(0, #c4.sent)
		end)
	end)

	describe("group on/off and other scenes (HUE_SCENE_GROUP)", function()
		-- Relax (2001) and Savanna sunset (2002) in the Living Room, Concentrate
		-- (2003) in the Garage.
		local function add_three(opts)
			resync(opts)
			S:add_all_of_group(F.group_rids.living_room, done)
			S:add_scene(F.scene_rids.concentrate, nil, done)
			c4.sent = {}
		end

		it("sends each linked scene its group's on/off after a resync", function()
			add_three()
			resync({ grouped = grouped_lights({ living_room = true, garage = false }) })
			local groups_sent = {}
			for _, m in ipairs(c4.sent) do
				if m.command == "HUE_SCENE_GROUP" then groups_sent[#groups_sent + 1] = m end
			end
			table.sort(groups_sent, function(a, b) return a.id < b.id end)
			assert.same({
				{ id = 2001, command = "HUE_SCENE_GROUP", params = { rid = F.scene_rids.relax, on = "true" } },
				{ id = 2002, command = "HUE_SCENE_GROUP", params = { rid = F.scene_rids.savanna, on = "true" } },
				{ id = 2003, command = "HUE_SCENE_GROUP", params = { rid = F.scene_rids.concentrate, on = "false" } },
			}, groups_sent)
			c4.sent = {}
			resync({ grouped = grouped_lights({ living_room = true, garage = false }) })
			for _, id in ipairs({ 2001, 2002, 2003 }) do
				assert.equal(1, #sent_to(id, "HUE_SCENE_GROUP"), "again at every resync, changed or not")
			end
		end)

		it("sends nothing at resync for an unknown group, an unbound or a gone scene", function()
			add_three()
			local kept = {}
			for _, b in ipairs(c4.bindings) do
				if b.consumer ~= 2002 then kept[#kept + 1] = b end
			end
			c4.bindings = kept
			resync({ body = F.scene:gsub(replace(F.scene_rids.concentrate, "-", "%-"), "deadbeef-0000-4000-8000-000000000000"),
				grouped = grouped_lights({ garage = true }) })
			assert.equal("gone", S:entry(F.scene_rids.concentrate).state)
			assert.same({}, sent_to(2001, "HUE_SCENE_GROUP"), "the Living Room's on/off is unknown")
			assert.same({}, sent_to(2002), "unbound")
			assert.same({}, sent_to(2003, "HUE_SCENE_GROUP"), "gone")
		end)

		it("a grouped_light event that flips on tells the scenes of that group only, once", function()
			add_three({ grouped = grouped_lights({ living_room = false, garage = false }) })
			S:on_binding_changed(1, "HUE_BRIDGE", false, 2002)
			c4.sent = {}
			assert.equal(1, S:on_container(container(grouped_light_event("living_room", true))))
			assert.same({ { id = 2001, command = "HUE_SCENE_GROUP", params = { rid = F.scene_rids.relax, on = "true" } } },
				c4.sent)
			c4.sent = {}
			assert.equal(0, S:on_container(container(grouped_light_event("living_room", true))))
			assert.same({}, c4.sent, "the same value again sends nothing")
			assert.equal(1, S:on_container(container(grouped_light_event("garage", true))))
			assert.same({ "HUE_SCENE_GROUP@2003" }, commands_sent())
			assert.equal("true", c4.sent[1].params.on)
			c4.sent = {}
			assert.equal(1, S:on_container(container(grouped_light_event("living_room", false))))
			assert.equal("false", c4.sent[1].params.on)
			assert.equal(0, S:on_container(container(grouped_light_event("home", true))), "a group without imported scenes")
		end)

		it("a scene becoming active tells the other linked scenes of its group, not itself", function()
			add_three()
			assert.equal(1 + 1, S:on_container(container(F.events.scene_dynamic)))
			assert.same({ "HUE_SCENE_GROUP@2001", "HUE_SCENE_STATE@2002" }, commands_sent())
			assert.same({ rid = F.scene_rids.relax, other_active = "true" }, c4.sent[1].params)
			c4.sent = {}
			S:on_container(container(F.events.scene_inactive))
			assert.same({}, sent_to(2002, "HUE_SCENE_GROUP"), "going inactive tells no one")
			assert.same({}, sent_to(2003))
		end)

		it("an unimported scene becoming active tells the linked scenes of its group", function()
			resync()
			S:add_scene(F.scene_rids.relax, nil, done)
			c4.sent = {}
			assert.equal(1, S:on_container(container(F.events.scene_dynamic)))
			assert.same({ { id = 2001, command = "HUE_SCENE_GROUP",
				params = { rid = F.scene_rids.relax, other_active = "true" } } }, c4.sent)
		end)
	end)

	describe("dim", function()
		it("queues a dimming_delta up or down on the scene's grouped_light with the duration clamped", function()
			add_relax()
			c4.sent = {}
			local n = #c4.transfers
			assert.is_true(S:dim({ rid = F.scene_rids.relax, device_id = "2001", direction = "up", duration = "5000" }))
			assert.same({ rid = F.grouped_light_rids.living_room, body = { dimming_delta = { action = "up",
				brightness_delta = 100 }, dynamics = { duration = 5000 } } }, dims[1])
			assert.is_true(S:dim({ rid = F.scene_rids.relax, direction = "down", duration = "99999999" }))
			assert.same({ dimming_delta = { action = "down", brightness_delta = 100 }, dynamics = { duration = 6000000 } },
				dims[2].body)
			assert.is_true(S:dim({ rid = F.scene_rids.relax, direction = "up", duration = "-5" }))
			assert.equal(0, dims[3].body.dynamics.duration)
			assert.is_true(S:dim({ rid = F.scene_rids.relax, direction = "up" }))
			assert.equal(5000, dims[4].body.dynamics.duration, "the default hold rate")
			assert.equal(n, #c4.transfers, "no transfer of its own")
			assert.same({}, c4.sent, "no STATE")
		end)

		it("queues a stop without dynamics", function()
			add_relax()
			assert.is_true(S:dim({ rid = F.scene_rids.relax, direction = "stop", duration = "5000" }))
			assert.same({ rid = F.grouped_light_rids.living_room, body = { dimming_delta = { action = "stop" } } }, dims[1])
		end)

		it("returns false when nothing was queued, for a gone scene, a group without grouped_light or bad params", function()
			add_relax()
			S.ctx.group_dim = function() return false end
			assert.is_false(S:dim({ rid = F.scene_rids.relax, direction = "up" }))
			assert.is_true(saw_log("nothing queued"))
			S.ctx.group_dim = function(rid, body) dims[#dims + 1] = { rid = rid, body = body }; return true end
			assert.is_false(S:dim({ rid = F.scene_rids.relax, direction = "sideways" }))
			assert.is_false(S:dim({ rid = "nope", direction = "up" }))
			assert.is_false(S:dim({ direction = "up" }))
			S:on_container(container(F.events.scene_deleted))
			assert.is_false(S:dim({ rid = F.scene_rids.relax, direction = "up" }))
			assert.is_true(saw_log("dim of Relax (device 2001) ignored: scene not on the bridge"))

			resync({ attic = true })
			L.reg:set_room_mapping(F.group_rids.attic, { c4_room_id = GARAGE_ROOM, c4_room_name = "Garage", hue_name = "Attic",
				type = "zone" })
			S:add_scene(ATTIC_RID, nil, done)
			assert.is_false(S:dim({ rid = ATTIC_RID, direction = "down" }))
			assert.is_true(saw_log("its group has no grouped_light"))
			assert.same({}, dims)
		end)

		it("without group_dim in ctx logs and returns false", function()
			S = scenes.new({ http = http_ctx, now = function() return now end, lights = L })
			resync()
			S:add_scene(F.scene_rids.relax, nil, done)
			assert.is_false(S:dim({ rid = F.scene_rids.relax, direction = "up" }))
			assert.is_true(saw_log("no group_dim in ctx"))
		end)
	end)

	describe("off", function()
		it("turns the scene's group off through group_off once and reports inactive", function()
			add_relax()
			S:on_container(container(F.events.scene_recalled))
			c4.sent = {}
			assert.is_true(S:off({ rid = F.scene_rids.relax }))
			assert.same({ F.grouped_light_rids.living_room }, offs)
			assert.same({ { id = 2001, command = "HUE_SCENE_STATE",
				params = { rid = F.scene_rids.relax, active = "inactive", reason = "recall" } } }, c4.sent)
			assert.equal("inactive", S:scene(F.scene_rids.relax).active)
			assert.equal(#c4.transfers, 3, "no transfer of its own")
		end)

		it("reports inactive without a call for a group without grouped_light, a gone scene or an unknown rid", function()
			resync({ attic = true })
			L.reg:set_room_mapping(F.group_rids.attic, { c4_room_id = GARAGE_ROOM, c4_room_name = "Garage", hue_name = "Attic",
				type = "zone" })
			S:add_scene(ATTIC_RID, nil, done)
			assert.equal("Added Dusty to Garage (device 2001)", last_result().text)
			assert.equal("Attic Dusty", c4.added[1].name)
			c4.sent = {}
			assert.is_false(S:off({ rid = ATTIC_RID }))
			assert.same({}, offs)
			assert.equal("inactive", c4.sent[1].params.active)
			assert.is_true(saw_log("its group has no grouped_light; reporting inactive"))

			S:add_scene(F.scene_rids.relax, nil, done)
			S:on_container(container(F.events.scene_deleted))
			c4.sent = {}
			assert.is_false(S:off({ rid = F.scene_rids.relax }))
			assert.same({}, offs)
			assert.equal("inactive", c4.sent[1].params.active)
			assert.is_false(S:off({ rid = "nope" }))
			assert.is_false(S:off({}))
			assert.equal(1, #c4.sent)
		end)
	end)

	describe("relink", function()
		it("re-points the entry at the new scene, keeping the device, and tells it", function()
			add_relax()
			S:on_container(container(F.events.scene_deleted))
			c4.sent = {}
			local ok, text = S:relink("2001", F.scene_rids.bright)
			assert.is_true(ok)
			assert.equal("Re-linked device 2001 (was Relax) to Downstairs (zone): Bright", text)
			assert.is_nil(S:entry(F.scene_rids.relax))
			local entry = S:entry(F.scene_rids.bright)
			assert.equal(2001, entry.device_id)
			assert.equal("linked", entry.state)
			assert.equal("Bright", entry.name)
			assert.equal("zone", entry.group_type)
			assert.equal("Downstairs", entry.group_name)
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.equal("Downstairs", c4.sent[1].params.group_name)
			assert.equal("linked", c4.sent[1].params.state)
			assert.equal(2001, c4.persist.hue_scenes[F.scene_rids.bright].device_id)
			assert.equal(0, #c4.renamed)
		end)

		it("refuses bad arguments, unknown devices, held scenes and scenes not on the bridge", function()
			add_relax()
			S:add_scene(F.scene_rids.concentrate, nil, done)
			assert.same({ false, "Not re-linked: pick a device and a scene" }, { S:relink(nil, F.scene_rids.bright) })
			assert.same({ false, "Not re-linked: pick a device and a scene" }, { S:relink(2001, "") })
			assert.same({ false, "Not re-linked: device 999 is not a registered scene" }, { S:relink(999, F.scene_rids.bright) })
			assert.same({ false, "Not re-linked: device 2001 is already linked to Relax" },
				{ S:relink(2001, F.scene_rids.relax) })
			assert.same({ false, "Not re-linked: Concentrate is already linked to device 2002" },
				{ S:relink(2001, F.scene_rids.concentrate) })
			assert.same({ false, "Not re-linked: scene nope is not on the bridge (Refresh Scenes and try again)" },
				{ S:relink(2001, "nope") })
		end)
	end)

	describe("forget", function()
		it("removes the entry, unbinds, tells the device, and lists the scene under Add Scene again", function()
			add_relax()
			c4.sent = {}
			local ok, text = S:forget("2001")
			assert.is_true(ok)
			assert.equal("Forgot Relax (device 2001): unbound and left in the project for you to delete; "
				.. "the Hue scene is listed under Add Scene again", text)
			assert.is_nil(S:entry(F.scene_rids.relax))
			assert.same({ { id = 2001, command = "HUE_SCENE_FORGOTTEN",
				params = { rid = F.scene_rids.relax, name = "Relax" } } }, c4.sent)
			assert.same({ { 2001, 1 } }, c4.calls_to("Unbind"))
			assert.is_nil(c4.persist.hue_scenes[F.scene_rids.relax])
			assert.is_nil(c4.persist.hue_scene_tombstones[F.scene_rids.relax], "forget leaves no tombstone")
			assert.truthy(values(S:picker_scenes())[4] == F.scene_rids.relax)
			assert.same({ false, "Not forgotten: pick a device first" }, { S:forget(nil) })
			assert.same({ false, "Not forgotten: device 2001 is not a registered scene" }, { S:forget(2001) })
		end)

		it("forget_request from the device: by device id, by rid, and a stranger is told so", function()
			add_relax()
			S:add_scene(F.scene_rids.concentrate, nil, done)
			c4.sent = {}
			assert.is_true((S:forget_request({ rid = F.scene_rids.relax, device_id = "2001" })))
			assert.is_true((S:forget_request({ rid = F.scene_rids.concentrate })))
			assert.equal(0, S:count())
			local ok, text = S:forget_request({ rid = "x", device_id = "2099", name = "Ghost" })
			assert.is_false(ok)
			assert.equal("Not forgotten: device 2099 is not a registered scene (told it so)", text)
			assert.same({ id = 2099, command = "HUE_SCENE_FORGOTTEN", params = { rid = "x", name = "Ghost" } },
				c4.sent[#c4.sent])
			assert.same({ false, "Not forgotten: the scene device named no device" }, { S:forget_request({}) })
		end)
	end)

	describe("link_devices", function()
		it("counts only hue_scene devices among the bound ones", function()
			resync()
			c4:Bind(15, 1, 4242, 1, "HUE_BRIDGE")  -- a light
			fake.project.devices[4242] = { name = "Lamp", room_id = LIVING_ROOM, c4i = "hue_light.c4z",
				driver_name = "Hue Light" }
			assert.equal("No scene devices are bound to this bridge", S:link_devices())
			S:add_scene(F.scene_rids.relax, nil, done)
			assert.equal("All 1 bound scene devices are registered", S:link_devices())
		end)

		it("adopts by announced rid, by Composer name, by the zone creation name, and reports the rest", function()
			resync()
			for id, name in pairs({ [2091] = "Whatever", [2092] = "Savanna sunset", [2093] = "Downstairs Nightlight",
				[2094] = "Mystery", [2095] = "Bright", [2096] = "Bright" }) do
				fake.project.devices[id] = { name = name, room_id = LIVING_ROOM, c4i = "hue_scene.c4z", driver_name = "Hue Scene" }
				c4:Bind(15, 1, id, 1, "HUE_BRIDGE")
			end
			S:hello(F.scene_rids.relax, { device_id = "2091", name = "Relax" })  -- adopted at once by its hello
			c4.sent = {}
			S.registry[F.scene_rids.relax] = nil  -- pretend the registry was lost; the hello was remembered
			S.reg.lights[F.scene_rids.relax] = nil
			local text = S:link_devices()
			assert.equal("Linked 3 scene devices: Whatever (device 2091) to Living Room: Relax by its rid, "
				.. "Savanna sunset (device 2092) to Living Room: Savanna sunset by name, "
				.. "Downstairs Nightlight (device 2093) to Downstairs (zone): Nightlight by name; "
				.. "not linked 3: Mystery (device 2094): no unimported Hue scene has that name; rename the device in Composer "
				.. "to the Hue scene's exact name and run Link Devices again; "
				.. "Bright (device 2095): 2 bound devices share that name; rename one in Composer and run Link Devices again; "
				.. "Bright (device 2096): 2 bound devices share that name; rename one in Composer and run Link Devices again",
				text)
			assert.equal(2091, S:device_for(F.scene_rids.relax))
			assert.equal(2092, S:device_for(F.scene_rids.savanna))
			assert.equal(2093, S:device_for(F.scene_rids.nightlight))
			assert.same({ "HUE_SCENE_CONFIGURE@2091", "HUE_SCENE_STATE@2091", "HUE_SCENE_CONFIGURE@2092", "HUE_SCENE_STATE@2092",
				"HUE_SCENE_CONFIGURE@2093", "HUE_SCENE_STATE@2093" }, commands_sent())
		end)

		it("reports a device whose announced rid another device holds", function()
			add_relax()
			fake.project.devices[2099] = { name = "Relax", room_id = LIVING_ROOM, c4i = "hue_scene.c4z",
				driver_name = "Hue Scene" }
			c4:Bind(15, 1, 2099, 1, "HUE_BRIDGE")
			S:hello(F.scene_rids.relax, { device_id = "2099" })
			assert.equal("not linked 1: Relax (device 2099) announces Relax, which device 2001 holds "
				.. "(Forget Scene on one of them)", S:link_devices())
		end)

		it("uses the hellos when the project lookup is unavailable", function()
			resync()
			S = new_scenes({ project = { devices = function() return nil end } })
			S:load()
			resync()
			c4:Bind(15, 1, 2091, 1, "HUE_BRIDGE")
			c4:Bind(15, 1, 4242, 1, "HUE_BRIDGE")
			assert.equal("No scene devices are bound to this bridge", S:link_devices())
			S.announced[2091] = { rid = F.scene_rids.relax }
			assert.truthy(S:link_devices():find("^Linked 1 scene device: device 2091 %(device 2091%) to Living Room: Relax "
				.. "by its rid"))
		end)
	end)

	describe("names", function()
		local function import_two()
			add_relax()
			S:add_scene(F.scene_rids.nightlight, tostring(GARAGE_ROOM), done)
			-- The proxies the fake made for the two devices.
			S.registry[F.scene_rids.relax].proxy_id = 3001
			S.registry[F.scene_rids.nightlight].proxy_id = 3002
		end

		it("compares the Composer name with the creation name and renames through the proxy", function()
			import_two()
			assert.equal("No Composer names differ from the Hue scene names", S:adopt_hue_names())
			assert.same({}, S:name_differences())
			fake.project.devices[3001].name = "My Relax"
			fake.project.devices[3002].name = "Nightlight"
			local diffs = S:name_differences()
			assert.equal(2, #diffs)
			assert.equal("Downstairs Nightlight", diffs[1].expected)
			assert.equal("2 Hue scene names differ from the Composer names: Nightlight is Downstairs Nightlight in Hue, "
				.. "My Relax is Relax in Hue (Adopt Hue Names or Accept Names As They Are)", S:attention())
			assert.equal("Renamed 2 scene devices: Nightlight → Downstairs Nightlight (device 2002), "
				.. "My Relax → Relax (device 2001)", S:adopt_hue_names())
			assert.same({ { id = 3002, name = "Downstairs Nightlight" }, { id = 3001, name = "Relax" } }, c4.renamed)
			assert.equal("None", S:attention())
		end)

		it("accepts differences until the Hue name changes, and skips devices without a proxy id", function()
			import_two()
			fake.project.devices[3001].name = "My Relax"
			assert.equal("Accepted 1 scene name difference: My Relax (Hue: Relax)", S:accept_names())
			assert.equal("Relax", c4.persist.hue_scenes[F.scene_rids.relax].name_dismissed)
			assert.equal("None", S:attention())
			assert.equal("No Composer names differ from the Hue scene names", S:accept_names())
			S:on_container(container(F.events.scene_renamed))
			assert.equal("1 Hue scene name differs from the Composer names: My Relax is Chill in Hue "
				.. "(Adopt Hue Names or Accept Names As They Are)", S:attention())
			S.registry[F.scene_rids.relax].proxy_id = nil
			-- Without a proxy id the protocol device's own name ("Relax", as AddDevice named it) is compared.
			assert.equal("not renamed 1: Relax (device 2001): no proxy id known", S:adopt_hue_names())
		end)
	end)

	describe("pickers", function()
		it("picker_scenes groups by room label then name, marks dynamic scenes, lists deleted ones last", function()
			assert.same({ { text = "(no scenes fetched yet; connect the event stream)", value = "" } }, S:picker_scenes())
			resync()
			assert.same({ "Downstairs (zone): Bright", "Downstairs (zone): Nightlight", "Garage: Concentrate",
				"Living Room: Relax", "Living Room: Savanna sunset (dynamic)" }, texts(S:picker_scenes()))
			assert.same({ F.scene_rids.bright, F.scene_rids.nightlight, F.scene_rids.concentrate, F.scene_rids.relax,
				F.scene_rids.savanna }, values(S:picker_scenes()))
			S:add_scene(F.scene_rids.relax, nil, done)
			S:add_scene(F.scene_rids.concentrate, nil, done)
			S:goodbye({ device_id = "2002" })
			assert.same({ "Downstairs (zone): Bright", "Downstairs (zone): Nightlight", "Living Room: Savanna sunset (dynamic)",
				"Garage: Concentrate (deleted from Composer " .. os.date("%Y-%m-%d", T0) .. ")" }, texts(S:picker_scenes()))
			S.reg.lights[F.scene_rids.bright] = { device_id = 11, state = "linked" }
			S.reg.lights[F.scene_rids.nightlight] = { device_id = 12, state = "linked" }
			S.reg.lights[F.scene_rids.savanna] = { device_id = 13, state = "linked" }
			S.reg.lights[F.scene_rids.concentrate] = { device_id = 14, state = "linked" }
			assert.same({ { text = "(every scene on the bridge is imported)", value = "" } }, S:picker_scenes())
		end)

		it("replaces commas in names and labels with spaces", function()
			resync({ body = F.scene:gsub('"name":"Relax"', '"name":"Relax, please"') })
			assert.equal("Living Room: Relax  please", texts(S:picker_scenes())[4])
		end)

		it("picker_groups lists the groups that have scenes with their mapping and counts", function()
			assert.same({ { text = "(no scenes fetched yet; connect the event stream)", value = "" } }, S:picker_groups())
			resync()
			assert.same({ "Downstairs (zone) → (unmapped) (2 scenes)", "Garage → Garage (1 scene)",
				"Living Room → Living Room (2 scenes)" }, texts(S:picker_groups()))
			assert.same({ F.group_rids.downstairs, F.group_rids.garage, F.group_rids.living_room }, values(S:picker_groups()))
			S:add_scene(F.scene_rids.relax, nil, done)
			fake.project.rooms[GARAGE_ROOM] = nil
			assert.same({ "Downstairs (zone) → (unmapped) (2 scenes)", "Garage → (Control4 room gone) (1 scene)",
				"Living Room → Living Room (2 scenes, 1 imported)" }, texts(S:picker_groups()))
		end)

		it("picker_relink_devices and picker_forget_devices", function()
			assert.same({ { text = "(no gone or unbound scene devices)", value = "" } }, S:picker_relink_devices())
			assert.same({ { text = "(no registered scenes)", value = "" } }, S:picker_forget_devices())
			add_relax()
			S:add_scene(F.scene_rids.nightlight, tostring(GARAGE_ROOM), done)
			S:add_scene(F.scene_rids.concentrate, nil, done)
			assert.same({ "Garage: Concentrate (device 2003)", "Downstairs (zone): Nightlight (device 2002)",
				"Living Room: Relax (device 2001)" }, texts(S:picker_forget_devices()))
			now = T0 + 3600 * 24
			S:on_container(container(F.events.scene_deleted))
			S:on_binding_changed(1, "HUE_BRIDGE", false, 2003)
			local date = os.date("%m-%d", now)
			assert.same({ "Living Room: Relax (device 2001, gone since " .. date .. ")",
				"Garage: Concentrate (device 2003, unbound since " .. date .. ")" }, texts(S:picker_relink_devices()))
			assert.same({ "2001", "2003" }, values(S:picker_relink_devices()))
			assert.same({ "Garage: Concentrate (device 2003) unbound", "Downstairs (zone): Nightlight (device 2002)",
				"Living Room: Relax (device 2001) gone" }, texts(S:picker_forget_devices()))
		end)
	end)

	describe("load and configure_all", function()
		it("configures every bound entry from the persisted record before any GET, group names included", function()
			c4.persist.hue_scenes = {
				[F.scene_rids.relax] = { device_id = 2001, name = "Relax", group_rid = F.group_rids.living_room,
					group_type = "room", group_name = "Living Room", id_v1 = F.scene_id_v1.relax, auto_dynamic = false,
					state = "linked" },
				[F.scene_rids.nightlight] = { device_id = 2002, name = "Nightlight", group_rid = "gone-zone",
					group_type = "zone", group_name = "Cellar", state = "gone", gone_since = T0 - 5, auto_dynamic = "true" },
				[F.scene_rids.bright] = { device_id = 2003, name = "Bright", state = "unbound", unbound_since = T0 - 5 },
			}
			-- No lights instance at all: the group names must come from the entries.
			S = scenes.new({ http = http_ctx, now = function() return now end })
			S:load()
			assert.equal(3, S:count())
			assert.equal(2, S:configure_all())
			assert.same({ "HUE_SCENE_CONFIGURE@2002", "HUE_SCENE_CONFIGURE@2001" }, commands_sent(), "name order")
			assert.same({ rid = F.scene_rids.relax, name = "Relax", group_name = "Living Room", group_type = "room",
				id_v1 = F.scene_id_v1.relax, auto_dynamic = "false", state = "linked" }, c4.sent[2].params)
			assert.same({ rid = F.scene_rids.nightlight, name = "Nightlight", group_name = "Cellar", group_type = "zone",
				auto_dynamic = "true", state = "gone", gone_since = tostring(T0 - 5) }, c4.sent[1].params)
			assert.equal("3 imported", S:summary())
			assert.equal("1 scene missing from the bridge: Nightlight (device 2002, since " .. os.date("%Y-%m-%d", T0 - 5)
				.. ") (Re-link Scene or Forget Scene); 1 unbound scene device: Bright (device 2003) (bind it to this bridge in "
				.. "Composer, or Forget Scene)", S:attention())
		end)

		it("after load, a resync refreshes the entries from the catalogue and sends CONFIGURE only on change", function()
			c4.persist.hue_scenes = {
				[F.scene_rids.relax] = { device_id = 2001, name = "Old Relax", group_rid = F.group_rids.living_room,
					group_type = "room", group_name = "Living Room", state = "linked" },
			}
			c4:Bind(15, 1, 2001, 1, "HUE_BRIDGE")
			S:load()
			S:configure_all()
			c4.sent = {}
			resync()
			assert.same({ "HUE_SCENE_CONFIGURE@2001", "HUE_SCENE_STATE@2001" }, commands_sent())
			assert.equal("Relax", c4.sent[1].params.name)
			assert.equal(F.scene_id_v1.relax, c4.sent[1].params.id_v1)
			assert.equal("Relax", S:entry(F.scene_rids.relax).name)
			assert.equal(2, #c4.calls_to("PersistSetValue"), "one save of the two keys for the whole resync")
		end)
	end)
end)
