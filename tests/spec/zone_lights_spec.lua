local json = require("dkjson")
local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_resources")

-- Rooms of the fake project: the default Living Room (7) and a Garage (8);
-- the Hue rooms Living Room and Garage are mapped to them, the Downstairs
-- zone is not (specs map it when they need to).
local LIVING_ROOM, GARAGE_ROOM = 7, 8

local T0 = 1761000000

-- The fixture's groups (docs/zone-light-design.md specs):
--   Downstairs (zone, /groups/3): Garage White (white, off) + Living Room Lamp (colour + CCT 153-500, on,
--                                 at mirek 366); grouped_light g003 on at 73.52
--   Living Room (room, /groups/2): Hallway Ambiance (CCT 153-454, on at mirek 250) + Living Room Lamp;
--                                  grouped_light g002 on at 56.84
--   Garage (room, /groups/1): Garage White alone; grouped_light g001 off
--   Attic (zone, /groups/4): no lights, no grouped_light
local DOWNSTAIRS, LIVING, GARAGE, ATTIC = F.group_rids.downstairs, F.group_rids.living_room, F.group_rids.garage,
	F.group_rids.attic
local G_DOWNSTAIRS, G_LIVING, G_GARAGE = F.grouped_light_rids.downstairs, F.grouped_light_rids.living_room,
	F.grouped_light_rids.garage

describe("bridge.zone_lights", function()
	local zone_lights, lights, http, c4, L, Z, results, logged, now, sets, dims

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

	local function done(ok, text, sent)
		table.insert(results, { ok = ok, text = text, sent = sent })
	end

	local function last_result()
		return results[#results] or {}
	end

	local function decode_data(text)
		return json.decode(text).data
	end

	-- The lights' caches filled from the fixtures without HTTP: models,
	-- devices, connectivity and the group cache.
	local function new_lights()
		local l = lights.new({ http = http_ctx, now = function() return now end })
		l:absorb({ light = decode_data(F.light), device = decode_data(F.device), zigbee = decode_data(F.zigbee_connectivity),
			room = decode_data(F.room), zone = decode_data(F.zone), bridge_home = decode_data(F.bridge_home) })
		l.reg:set_room_mapping(LIVING, { c4_room_id = LIVING_ROOM, c4_room_name = "Living Room", hue_name = "Living Room",
			type = "room" })
		l.reg:set_room_mapping(GARAGE, { c4_room_id = GARAGE_ROOM, c4_room_name = "Garage", hue_name = "Garage",
			type = "room" })
		return l
	end

	local function new_zone_lights(extra)
		local ctx = { http = http_ctx, now = function() return now end, lights = L,
			group_set = function(rid, fields) sets[#sets + 1] = { rid = rid, fields = fields }; return true end,
			group_dim = function(rid, body, level) dims[#dims + 1] = { rid = rid, body = body, level = level }; return true end }
		for k, v in pairs(extra or {}) do ctx[k] = v end
		return zone_lights.new(ctx)
	end

	-- Answer the GET /grouped_light of a resync.
	local function answer_get(opts)
		opts = opts or {}
		local t = c4.last_transfer()
		assert.truthy(t, "expected a GET for grouped_light")
		assert.equal("GET", t.method)
		assert.equal("https://192.0.2.10/clip/v2/resource/grouped_light", t.url)
		t:respond(opts.code or 200, opts.body or F.grouped_light)
	end

	local function resync(opts)
		Z:resync(done)
		answer_get(opts)
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

	-- Plain-text replacement: rids contain "-", a pattern quantifier.
	local function replace(text, from, to)
		local escaped = from:gsub("%W", "%%%0")
		return (text:gsub(escaped, (to:gsub("%%", "%%%%"))))
	end

	-- Every container of an event fixture (one SSE data line) through the
	-- lights first, as the coordinator does, then through the zone lights.
	-- Returns the number of messages the zone lights sent.
	local function feed(text)
		local sent = 0
		for _, c in ipairs(C4:JsonDecode(text)) do
			L:on_container(c)
			sent = sent + Z:on_container(c)
		end
		return sent
	end

	-- A one-item light event (the lights' cache follows it first).
	local function light_event(key, body)
		return '[{"creationtime":"2026-10-24T16:00:00Z","id":"9de116fc-00e0-4a2b-8c3d-0000000000e0","type":"update",'
			.. '"data":[{"id":"' .. F.rids[key] .. '","owner":{"rid":"' .. F.device_rids[key] .. '","rtype":"device"},' .. body
			.. ',"type":"light"}]}]'
	end

	-- Resync, then Add Zone Light for Downstairs into the Garage (device 2001).
	local function add_downstairs(opts)
		resync(opts)
		Z:add(DOWNSTAIRS, GARAGE_ROOM, done)
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
			"bridge.zone_lights" }) do
			package.loaded[m] = nil
		end
		http = require("bridge.http")
		lights = require("bridge.lights")
		zone_lights = require("bridge.zone_lights")
		results = {}
		sets = {}
		dims = {}
		L = new_lights()
		Z = new_zone_lights()
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("new", function()
		it("requires http and persists under the zone-light keys", function()
			assert.has_error(function() zone_lights.new({}) end)
			assert.same({ lights = "hue_zone_lights", tombstones = "hue_zone_light_tombstones", rooms = false }, Z.reg.keys)
			assert.equal("2 zones, 2 rooms on bridge; 0 imported", Z:summary())
			assert.equal(0, Z:count())
			assert.equal("None", Z:attention())
			assert.same({}, Z:attention_items())
			assert.same({}, Z:device_ids())
			assert.is_true(Z:is_group(DOWNSTAIRS))
			assert.is_true(Z:is_group(GARAGE))
			assert.is_false(Z:is_group(F.group_rids.home), "the bridge_home is never a zone light")
			assert.is_false(Z:is_group(F.rids.living), "a light is not a group")
			assert.is_false(Z:is_group(nil))
		end)

		it("reads nothing into the summary without a lights instance", function()
			Z = zone_lights.new({ http = http_ctx })
			assert.equal("0 imported", Z:summary())
			assert.is_nil(Z:entry(DOWNSTAIRS))
			assert.same({ { text = "(no zones or rooms on the bridge)", value = "" } }, Z:picker_groups())
		end)
	end)

	describe("resync", function()
		it("GETs /grouped_light with the key and caches each group's on/off, level and owner", function()
			Z:resync(done)
			assert.equal(1, #c4.transfers)
			assert.equal("k", c4.transfers[1].headers["hue-application-key"])
			assert.is_nil(last_result().ok)
			c4.transfers[1]:respond(200, F.grouped_light)
			assert.same({ ok = true, text = nil, sent = 0 }, last_result())
			assert.is_true(Z.synced)
			assert.same({ rid = G_DOWNSTAIRS, owner_rid = DOWNSTAIRS, owner_type = "zone", on = true, brightness = 73.52 },
				Z.group_state[G_DOWNSTAIRS])
			assert.is_false(Z.group_state[G_GARAGE].on)
			assert.equal(G_LIVING, Z.owners[LIVING])
			assert.equal(G_DOWNSTAIRS, Z:grouped_light_of(DOWNSTAIRS))
			assert.is_nil(Z:grouped_light_of(ATTIC), "the empty zone has no grouped_light")
			assert.equal(0, #c4.sent, "nothing registered, nothing told")
			assert.is_true(saw_log("4 grouped_lights cached"))
		end)

		it("reports a failed GET and keeps the previous on/off and level", function()
			resync()
			resync({ code = 500 })
			assert.is_false(last_result().ok)
			assert.equal("GET /clip/v2/resource/grouped_light: HTTP 500", last_result().text)
			assert.is_true(Z.synced, "the earlier GET still counts")
			assert.equal(73.52, Z.group_state[G_DOWNSTAIRS].brightness)
			assert.is_true(saw_log("the groups' on/off and level stay as they were"))
			resync({ body = "not json" })
			assert.equal("GET /clip/v2/resource/grouped_light: malformed response", last_result().text)
		end)

		-- #56 (docs/review-leftovers-design.md §5): until 2026-10-25 the latest
		-- waiting done replaced the others, as the lights' and the scenes' did
		-- before #47 F2.
		it("runs a resync requested during a resync once more afterwards, answering every caller that waited once", function()
			Z:resync(function() done(true, "first") end)
			Z:resync(function() done(true, "second") end)
			Z:resync(function() done(true, "third") end)
			answer_get()
			assert.same({ "first" }, texts(results))
			assert.equal(2, #c4.transfers, "the pending resync started")
			answer_get()
			assert.same({ "first", "second", "third" }, texts(results))
			assert.equal(2, #c4.transfers, "one resync for the two that waited")
		end)

		it("takes the grouped_light items another module fetched and skips its own GET", function()
			add_downstairs()
			c4.sent = {}
			local n = #c4.transfers
			Z:resync(done, decode_data(F.grouped_light))
			assert.equal(n, #c4.transfers, "no GET of its own")
			assert.same({ ok = true, text = nil, sent = 1 }, last_result())
			assert.same({ "HUE_STATE@2001" }, commands_sent())
			assert.equal("73.52", c4.sent[1].params.brightness)
			assert.equal("resync", c4.sent[1].params.reason)
			assert.is_false(Z.resyncing)
			c4.sent = {}
			Z:resync(done, decode_data((F.grouped_light:gsub('"brightness":73.52', '"brightness":20.5'))))
			assert.equal("20.5", c4.sent[1].params.brightness, "the items given are the state")
			assert.equal(20.5, Z.group_state[G_DOWNSTAIRS].brightness)
			assert.equal(n, #c4.transfers)
			Z:resync(done, "junk")
			assert.equal(n + 1, #c4.transfers, "anything but a list of items: the GET as before")
			answer_get()
			assert.equal(73.52, Z.group_state[G_DOWNSTAIRS].brightness)
		end)

		it("refuses actions while resyncing", function()
			Z:resync(done)
			Z:add(DOWNSTAIRS, GARAGE_ROOM, done)
			assert.equal("Busy: resyncing zone lights; try again in a moment", last_result().text)
			assert.same({ false, "Busy: resyncing zone lights; try again in a moment" }, { Z:relink(2001, DOWNSTAIRS) })
			assert.equal("Busy: resyncing zone lights; try again in a moment", Z:link_devices())
			assert.same({ false, "Busy: resyncing zone lights; try again in a moment" }, { Z:forget(2001) })
			assert.equal("Busy: resyncing zone lights; try again in a moment", Z:adopt_hue_names())
		end)
	end)

	describe("add", function()
		it("refuses without a pick, an unknown rid, the bridge_home, a group without lights and an unmapped one", function()
			resync()
			Z:add("", nil, done)
			assert.same({ ok = false, text = "Not added: pick a zone or room first" }, last_result())
			Z:add("nope", nil, done)
			assert.equal("Not added: zone or room nope is not on the bridge (connect the event stream and try again)",
				last_result().text)
			Z:add(F.group_rids.home, nil, done)
			assert.equal("Not added: the whole bridge cannot be a zone light", last_result().text)
			Z:add(ATTIC, GARAGE_ROOM, done)
			assert.same({ ok = false, text = "Not added: Attic (zone) has no lights" }, last_result())
			Z:add(DOWNSTAIRS, nil, done)
			assert.same({ ok = false, text = "Not added: Downstairs (zone): Hue room Downstairs (zone) not mapped; pick a room, "
				.. "or Set Room Mapping first" }, last_result())
			Z:add(DOWNSTAIRS, "mapped", done)
			assert.equal("Not added: Downstairs (zone): Hue room Downstairs (zone) not mapped; pick a room, "
				.. "or Set Room Mapping first", last_result().text)
			Z:add(DOWNSTAIRS, "99", done)
			assert.same({ ok = false, text = "Not added: Control4 room 99 no longer exists" }, last_result())
			L.reg:set_room_mapping(DOWNSTAIRS, { c4_room_id = 99, c4_room_name = "Cellar", hue_name = "Downstairs",
				type = "zone" })
			Z:add(DOWNSTAIRS, nil, done)
			assert.equal("Not added: Downstairs (zone): Hue room Downstairs (zone) mapped to a Control4 room that no longer "
				.. "exists; pick a room, or Set Room Mapping first", last_result().text)
			assert.equal(0, #c4.added)
			assert.equal(0, Z:count())
		end)

		it("creates a zone light: AddDevice hue_light.c4z, Bind, registry, save, CONFIGURE + STATE", function()
			add_downstairs()
			assert.same({ ok = true, text = "Added Downstairs (zone) to Garage (device 2001)" }, last_result())
			assert.same({ { id = 2001, driver = "hue_light.c4z", room = GARAGE_ROOM, name = "Downstairs" } }, c4.added)
			assert.same({ { provider = 15, provider_binding = 1, consumer = 2001, consumer_binding = 1, class = "HUE_BRIDGE" } },
				c4.bindings)
			local entry = Z:entry(DOWNSTAIRS)
			assert.equal(2001, entry.device_id)
			assert.equal("Downstairs", entry.name)
			assert.equal("zone", entry.group_type)
			assert.equal(2, entry.light_count)
			assert.is_false(entry.no_lights)
			assert.same({ has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 1 }, entry.caps)
			assert.equal("/groups/3", entry.id_v1)
			assert.equal("linked", entry.state)
			assert.equal(GARAGE_ROOM, entry.created_room_id)
			assert.equal(T0, entry.created_at)
			assert.equal(2001, c4.persist.hue_zone_lights[DOWNSTAIRS].device_id)
			assert.is_nil(c4.persist.hue_lights, "the lights' key is untouched")
			assert.is_nil(c4.persist.hue_scenes, "the scenes' key is untouched")
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.same({ rid = DOWNSTAIRS, name = "Downstairs", kind = "group", group_type = "zone", model = "Hue zone",
				light_count = "2", no_lights = "false", hue_room = "Downstairs (zone)", id_v1 = "/groups/3", has_color = "true",
				has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }, c4.sent[1].params)
			assert.same({ rid = DOWNSTAIRS, on = "true", brightness = "73.52", mirek = "366", color_mode = "ct", online = "true",
				reason = "resync" }, c4.sent[2].params)
			for _, m in ipairs(c4.sent) do
				for k, v in pairs(m.params) do
					assert.equal("string", type(v), k)
				end
			end
			assert.equal("2 zones, 2 rooms on bridge; 1 imported", Z:summary())
			assert.equal(DOWNSTAIRS, (Z.reg:by_device(2001)))
			assert.same({ [2001] = true }, Z:device_ids())
			assert.is_true(saw_log("zone_lights: Added Downstairs (zone) to Garage (device 2001)"))
		end)

		it("creates a room light named '<Room> Lights' in its mapped room, with the members' CT intersection", function()
			resync()
			Z:add(LIVING, nil, done)
			assert.same({ ok = true, text = "Added Living Room (room) to Living Room (device 2001)" }, last_result())
			assert.equal("Living Room Lights", c4.added[1].name)
			assert.equal(LIVING_ROOM, c4.added[1].room)
			assert.same({ rid = LIVING, name = "Living Room", kind = "group", group_type = "room", model = "Hue room",
				light_count = "2", no_lights = "false", hue_room = "Living Room", id_v1 = "/groups/2", has_color = "true",
				has_cct = "true", mirek_min = "153", mirek_max = "454", min_dim = "1" }, c4.sent[1].params)
			assert.same({ rid = LIVING, on = "true", brightness = "56.84", mirek = "250", color_mode = "ct", online = "true",
				reason = "resync" }, c4.sent[2].params, "the colour of the first lit member, Hallway Ambiance")
		end)

		it("takes the action's own params, a white room shows no colour, an off group no colour either", function()
			resync()
			assert.is_true(Z:add({ Group = GARAGE, Room = "mapped" }, done))
			assert.same({ ok = true, text = "Added Garage (room) to Garage (device 2001)" }, last_result())
			assert.equal("Garage Lights", c4.added[1].name)
			local configure = c4.sent[1].params
			assert.equal("false", configure.has_color)
			assert.equal("false", configure.has_cct)
			assert.is_nil(configure.mirek_min)
			assert.equal("1", configure.light_count)
			assert.same({ rid = GARAGE, on = "false", brightness = "100", online = "true", reason = "resync" },
				c4.sent[2].params)
			Z:add({ Group = GARAGE, Room = tostring(LIVING_ROOM) }, done)
			assert.same({ ok = false, text = "Not added: Garage (room) is already imported (device 2001)" }, last_result())
		end)

		it("before any GET sends the configuration alone; the first resync brings the state", function()
			Z:add(DOWNSTAIRS, GARAGE_ROOM, done)
			assert.same({ ok = true, text = "Added Downstairs (zone) to Garage (device 2001)" }, last_result())
			assert.same({ "HUE_CONFIGURE@2001" }, commands_sent())
			c4.sent = {}
			resync()
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent(),
				"the first resync of a run configures everything, as the lights' does")
			assert.equal("73.52", c4.sent[2].params.brightness)
			assert.equal("resync", c4.sent[2].params.reason)
			assert.same({ ok = true, text = nil, sent = 1 }, last_result())
			c4.sent = {}
			resync()
			assert.same({ "HUE_STATE@2001" }, commands_sent())
		end)

		it("reports an AddDevice failure and a raising AddDevice", function()
			resync()
			c4.AddDevice = function(_, _, _, _, cb) cb(0, nil) end
			Z:add(DOWNSTAIRS, GARAGE_ROOM, done)
			assert.same({ ok = false, text = "Not added: AddDevice failed for Downstairs (zone) (see the Lua output)" },
				last_result())
			assert.equal(0, Z:count())
			assert.is_false(Z.adding)
			assert.is_true(saw_log("AddDevice failed for Downstairs"))
			Z = new_zone_lights({ add_device = function() error("boom") end })
			resync()
			Z:add(DOWNSTAIRS, GARAGE_ROOM, done)
			assert.is_false(last_result().ok)
			assert.truthy(last_result().text:find("^Not added: .*boom"))
			assert.is_false(Z.adding)
		end)

		it("binds the protocol id and keeps the proxy id from the OS 3.4.2 callback info", function()
			Z = new_zone_lights({ add_device = function(driver, room_id, name, cb)
				C4:AddDevice(driver, room_id, name, function(id)
					cb(id, { Name = "devices", ChildNodes = {
						{ Name = "protocol", Value = tostring(id) }, { Name = "proxy", Value = "3001" } } })
				end)
			end })
			add_downstairs()
			assert.equal(2001, Z:entry(DOWNSTAIRS).device_id)
			assert.equal(3001, Z:entry(DOWNSTAIRS).proxy_id)
			assert.is_true(saw_log("AddDevice callback for zone light Downstairs"))
		end)
	end)

	describe("resync fan-out", function()
		it("sends the full state at every resync, CONFIGURE only when it changed", function()
			add_downstairs()
			c4.sent = {}
			resync()
			assert.same({ "HUE_STATE@2001" }, commands_sent())
			assert.same({ rid = DOWNSTAIRS, on = "true", brightness = "73.52", mirek = "366", color_mode = "ct", online = "true",
				reason = "resync" }, c4.sent[1].params)
			c4.sent = {}
			resync({ body = F.grouped_light:gsub('"brightness":73.52', '"brightness":20.5') })
			assert.equal("20.5", c4.sent[1].params.brightness)
			assert.equal(1, #c4.sent)
		end)

		it("sends nothing to an unbound device", function()
			add_downstairs()
			c4:Unbind(2001, 1)
			Z:on_binding_changed(1, "HUE_BRIDGE", false, 2001)
			c4.sent = {}
			resync()
			assert.same({}, c4.sent)
			assert.equal("unbound", Z:entry(DOWNSTAIRS).state)
		end)

		it("marks a registered zone gone when the fetched cache lacks it, and linked when it returns", function()
			add_downstairs()
			c4.sent = {}
			now = T0 + 10
			L:absorb({ room = decode_data(F.room), bridge_home = decode_data(F.bridge_home),
				zone = decode_data(F.zone:gsub(replace(DOWNSTAIRS, "-", "%-"), "deadbeef-0000-4000-8000-000000000000")) })
			resync()
			assert.equal("gone", Z:entry(DOWNSTAIRS).state)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.equal("gone", c4.sent[1].params.state)
			assert.equal(tostring(T0 + 10), c4.sent[1].params.gone_since)
			assert.equal("Downstairs", c4.sent[1].params.name, "the entry remembers the name")
			assert.same({ rid = DOWNSTAIRS, online = "false", reason = "resync" }, c4.sent[2].params)
			assert.is_true(saw_log("Downstairs (zone) (device 2001) is no longer on the bridge; marked gone "
				.. "(Re-link Zone Light or Forget Light)"))
			assert.equal("2 zones, 2 rooms on bridge; 1 imported, 1 missing", Z:summary(), "the zone came back under a new rid")
			assert.equal("1 zone light missing from the bridge: Downstairs (device 2001, since " .. os.date("%Y-%m-%d", T0 + 10)
				.. ") (Re-link Zone Light or Forget Light)", Z:attention())
			c4.sent = {}
			resync()
			assert.same({}, c4.sent, "a gone group hears nothing while nothing changes")
			L:absorb({ room = decode_data(F.room), zone = decode_data(F.zone), bridge_home = decode_data(F.bridge_home) })
			resync()
			assert.equal("linked", Z:entry(DOWNSTAIRS).state)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.is_nil(c4.sent[1].params.state)
			assert.equal("true", c4.sent[2].params.online)
			assert.equal("true", c4.sent[2].params.on)
			assert.is_true(saw_log("Downstairs (zone) (device 2001) is back on the bridge"))
		end)

		it("still reconciles against the cache when the GET fails", function()
			add_downstairs()
			c4.sent = {}
			L:absorb({ room = decode_data(F.room), bridge_home = decode_data(F.bridge_home),
				zone = decode_data(F.zone:gsub(replace(DOWNSTAIRS, "-", "%-"), "deadbeef-0000-4000-8000-000000000000")) })
			resync({ code = 503 })
			assert.is_false(last_result().ok)
			assert.equal("gone", Z:entry(DOWNSTAIRS).state)
			assert.equal("gone", c4.sent[1].params.state)
		end)

		it("finds devices unbound or deleted in Composer through the project", function()
			add_downstairs()
			Z:add(LIVING, nil, done)
			c4.sent = {}
			c4.bindings = {}
			-- A light stays bound: the list is a table, the group devices are not
			-- in it (an answer of nil would be unknown, issue #48 item 14).
			c4:Bind(15, 1, 4242, 1, "HUE_BRIDGE")
			now = T0 + 20
			local r = Z:reconcile()
			assert.same({ DOWNSTAIRS, LIVING }, r.unbound)
			assert.equal("unbound", Z:entry(DOWNSTAIRS).state)
			assert.equal("2 zones, 2 rooms on bridge; 2 imported, 2 unbound", Z:summary())
			assert.equal("2 unbound zone light devices: Downstairs (device 2001), Living Room (device 2002) (bind it to this "
				.. "bridge in Composer, or Forget Light)", Z:attention())
			assert.is_true(saw_log("Downstairs (zone) (device 2001) is not bound to this bridge"))

			fake.project.devices[2001] = nil
			fake.project.devices[3001] = nil
			r = Z:reconcile()
			assert.same({ DOWNSTAIRS }, r.tombstoned)
			assert.is_nil(Z:entry(DOWNSTAIRS))
			assert.equal("Downstairs", c4.persist.hue_zone_light_tombstones[DOWNSTAIRS].name)
			assert.equal("2 zones, 2 rooms on bridge; 1 imported, 1 unbound, 1 deleted", Z:summary())
			assert.is_true(saw_log("Downstairs was deleted in Composer while the bridge was not watching"))

			c4:Bind(15, 1, 2002, 1, "HUE_BRIDGE")
			c4.sent = {}
			r = Z:reconcile()
			assert.same({ LIVING }, r.relinked)
			assert.same({ "HUE_CONFIGURE@2002", "HUE_STATE@2002" }, commands_sent())
		end)

		it("treats a failed bound lookup as unknown and an empty project lookup as not deleted", function()
			add_downstairs()
			Z = new_zone_lights({ project = { bound = function() error("boom") end } })
			Z:load()
			assert.same({ unbound = {}, relinked = {}, tombstoned = {} }, Z:reconcile())
			assert.is_true(saw_log("reconcile skipped"))
			Z = new_zone_lights({ project = { devices = function() return {} end } })
			Z:load()
			c4.bindings = {}
			c4:Bind(15, 1, 4242, 1, "HUE_BRIDGE")  -- known: the list is a table without the group device
			local r = Z:reconcile()
			assert.same({ DOWNSTAIRS }, r.unbound)
			assert.same({}, r.tombstoned)
		end)

		-- Issue #48 item 14: GetBoundConsumerDevices answering nil is unknown.
		it("changes nothing while the bound-device lookup answers nil, and adopts nobody on it", function()
			add_downstairs()
			Z:add(LIVING, nil, done)
			fake.delete_device(2002)
			c4.bindings = {}
			assert.is_nil(C4:GetBoundConsumerDevices(15, 1), "the fake answers nil when nothing is bound, as the SDK says")
			c4.sent = {}
			assert.same({ unbound = {}, relinked = {}, tombstoned = {} }, Z:reconcile())
			assert.equal("linked", Z:entry(DOWNSTAIRS).state)
			assert.equal("linked", Z:entry(LIVING).state, "not tombstoned on an unknown list")
			assert.equal(0, #c4.sent)
			assert.is_true(saw_log("zone_lights: reconcile skipped: the bound-device lookup answered no list"))
			assert.is_false(saw_log("is not bound to this bridge"))
			assert.equal("No zone light devices are bound to this bridge", Z:link_devices())
			assert.is_false(Z:hello({ rid = GARAGE, device_id = "2099", kind = "group" }))
			assert.is_nil(Z:entry(GARAGE))
			assert.is_true(saw_log("device 2099 announced " .. GARAGE .. ", but the bound-device list is unknown; not adopted"))
			Z.ctx.project.bound = function() error("boom") end
			assert.equal("Not linked: the bound-device lookup failed (see the Lua output)", Z:link_devices())
		end)

		-- Issue #48 item 13: Director may not list the device just created.
		it("leaves the device Add Zone Light just created alone in the reconcile after the click", function()
			resync()
			Z.ctx.project.bound = function() return {} end
			Z.ctx.project.devices = function() return { [9999] = { deviceName = "Somebody else's" } } end
			Z:add(DOWNSTAIRS, GARAGE_ROOM, done)
			assert.same({ ok = true, text = "Added Downstairs (zone) to Garage (device 2001)" }, last_result())
			assert.equal("linked", Z:entry(DOWNSTAIRS).state, "neither unbound nor tombstoned")
			assert.is_false(saw_log("was deleted in Composer while the bridge was not watching"))
			assert.same({ DOWNSTAIRS }, Z:reconcile().tombstoned, "the next reconcile judges it (Director still lagging)")
		end)
	end)

	describe("events", function()
		it("mirrors the grouped_light's on, off and level onto the device, only what the item carried", function()
			add_downstairs()
			c4.sent = {}
			assert.equal(1, feed(F.events.zone_level))
			assert.same({ { id = 2001, command = "HUE_STATE",
				params = { rid = DOWNSTAIRS, brightness = "40", reason = "event" } } }, c4.sent)
			assert.equal(40, Z.group_state[G_DOWNSTAIRS].brightness)
			c4.sent = {}
			assert.equal(1, feed(F.events.zone_off))
			assert.same({ rid = DOWNSTAIRS, on = "false", reason = "event" }, c4.sent[1].params)
			c4.sent = {}
			assert.equal(1, feed(F.events.zone_on))
			assert.same({ rid = DOWNSTAIRS, on = "true", brightness = "73.52", reason = "event" }, c4.sent[1].params)
			c4.sent = {}
			assert.equal(1, feed(F.events.zone_on))
			assert.same({ rid = DOWNSTAIRS, on = "true", brightness = "73.52", reason = "event" }, c4.sent[1].params,
				"carried again is sent again: the device may be waiting for the echo")
		end)

		it("ignores events for groups without a device, non-group containers and junk", function()
			add_downstairs()
			c4.sent = {}
			assert.equal(0, feed(F.events.off), "the Garage's grouped_light has no device")
			assert.is_false(Z.group_state[G_GARAGE].on, "cached all the same")
			assert.equal(0, feed(F.events.scene_renamed))
			assert.equal(0, feed(F.events.noop), "a light event that changes nothing a group shows")
			assert.equal(0, feed(F.events.room_rename), "a room without a device")
			assert.equal(0, Z:on_container("garbage"))
			assert.equal(0, Z:on_container({ type = "update" }))
			assert.same({}, c4.sent)
			assert.equal(1, feed(F.events.scene_recalled), "the Downstairs level rides in the recall's batch")
			assert.same({ rid = DOWNSTAIRS, brightness = "56.69", reason = "event" }, c4.sent[1].params)
			assert.equal(56.69, Z.group_state[G_LIVING].brightness, "the other groups are cached all the same")
		end)

		-- Issue #45: an id that is not a resource id reaches no cache.
		it("ignores a grouped_light item whose id is not a resource id", function()
			add_downstairs()
			c4.sent = {}
			for _, kind in ipairs({ "add", "update", "delete" }) do
				assert.equal(0, Z:on_container({ type = kind, data = { { id = "a/b", type = "grouped_light",
					owner = { rid = DOWNSTAIRS, rtype = "zone" }, on = { on = false } } } }), kind)
			end
			assert.is_nil(Z.group_state["a/b"])
			assert.is_nil(Z.gone_grouped["a/b"])
			assert.equal(G_DOWNSTAIRS, Z.owners[DOWNSTAIRS], "the zone keeps its own grouped_light")
			assert.same({}, c4.sent)
		end)

		it("caches a grouped_light event before any GET and tells the device, online the first time", function()
			Z:add(DOWNSTAIRS, GARAGE_ROOM, done)
			c4.sent = {}
			assert.equal(1, feed(F.events.zone_on))
			assert.same({ rid = DOWNSTAIRS, on = "true", brightness = "73.52", mirek = "366", color_mode = "ct", online = "true",
				reason = "event" }, c4.sent[1].params, "with the colour and online, told for the first time")
			assert.is_false(Z.synced)
			c4.sent = {}
			assert.equal(1, feed(F.events.zone_level))
			assert.same({ rid = DOWNSTAIRS, brightness = "40", reason = "event" }, c4.sent[1].params, "online was told")
		end)

		it("does not send state to an unbound device", function()
			add_downstairs()
			Z:on_binding_changed(1, "HUE_BRIDGE", false, 2001)
			c4.sent = {}
			assert.equal(0, feed(F.events.zone_on))
			assert.equal(0, feed(F.events.color))
			assert.same({}, c4.sent)
		end)

		it("derives the colour from the members: xy of the first lit colour member, else the first valid mirek", function()
			resync()
			Z:add(LIVING, nil, done)
			assert.equal("250", c4.sent[2].params.mirek, "Hallway Ambiance first in the room")
			c4.sent = {}
			assert.equal(1, feed(F.events.zone_member_ct))
			assert.same({ rid = LIVING, mirek = "400", color_mode = "ct", reason = "event" }, c4.sent[1].params)
			c4.sent = {}
			assert.equal(1, feed(F.events.zone_member_off))
			assert.same({ rid = LIVING, brightness = "73.52", mirek = "366", color_mode = "ct", reason = "event" },
				c4.sent[1].params, "Hallway off: the Lamp's white point, with the level the grouped_light carried, in one message")
			c4.sent = {}
			assert.equal(1, feed(F.events.color))
			assert.same({ rid = LIVING, x = "0.1532", y = "0.0475", color_mode = "xy", reason = "event" }, c4.sent[1].params,
				"the Lamp moved to a colour")
			c4.sent = {}
			assert.equal(0, feed(light_event("hallway", '"on":{"on":true}')), "a lit CCT member does not beat a lit xy member")
			assert.equal(0, feed(F.events.ct), "the Kitchen Strip is in no group")
			assert.equal(0, feed(light_event("hallway", '"on":{"on":false}')), "the Lamp still shows its colour")
			assert.equal(0, feed(light_event("living", '"on":{"on":false}')),
				"nothing lit with a colour: nothing to send, the colour is forgotten")
			assert.equal(1, feed(light_event("living", '"on":{"on":true}')))
			assert.same({ rid = LIVING, x = "0.1532", y = "0.0475", color_mode = "xy", reason = "event" }, c4.sent[1].params,
				"the same colour is sent again after a gap")
		end)

		it("colour and level land in one STATE when a container carries both", function()
			add_downstairs()
			c4.sent = {}
			feed(F.events.zone_off)
			assert.equal(1, feed(F.events.scene_recalled .. ""), "the Downstairs level in the batch (no on in it)")
			c4.sent = {}
			local both = C4:JsonDecode(F.events.color)[1]
			both.data[#both.data + 1] = C4:JsonDecode(F.events.zone_on)[1].data[1]
			L:on_container(both)
			assert.equal(1, Z:on_container(both))
			assert.same({ rid = DOWNSTAIRS, on = "true", brightness = "73.52", x = "0.1532", y = "0.0475", color_mode = "xy",
				reason = "event" }, c4.sent[1].params)
		end)

		it("re-sends CONFIGURE with the new count and caps when the zone's members change", function()
			add_downstairs()
			c4.sent = {}
			assert.equal(1, feed(F.events.zone_children))
			assert.same({ "HUE_CONFIGURE@2001" }, commands_sent())
			assert.equal("3", c4.sent[1].params.light_count)
			assert.equal("454", c4.sent[1].params.mirek_max, "Hallway Ambiance narrows the CT range")
			assert.equal("false", c4.sent[1].params.no_lights)
			assert.equal(3, Z:entry(DOWNSTAIRS).light_count)
			assert.same({ has_color = true, has_cct = true, mirek_min = 153, mirek_max = 454, min_dim = 1 },
				Z:entry(DOWNSTAIRS).caps)
			assert.equal(3, c4.persist.hue_zone_lights[DOWNSTAIRS].light_count)
			c4.sent = {}
			assert.equal(0, feed(F.events.zone_children), "the same members again change nothing")
		end)

		it("tells the device no_lights and offline when the zone is emptied, online again when refilled", function()
			add_downstairs()
			c4.sent = {}
			local sent = feed(F.events.zone_emptied)
			assert.equal("true", sent_to(2001, "HUE_CONFIGURE")[#sent_to(2001, "HUE_CONFIGURE")].params.no_lights)
			assert.equal("0", sent_to(2001, "HUE_CONFIGURE")[1].params.light_count)
			assert.same({ rid = DOWNSTAIRS, online = "false", on = "false", reason = "event" },
				sent_to(2001, "HUE_STATE")[#sent_to(2001, "HUE_STATE")].params)
			assert.truthy(sent >= 2)
			assert.is_true(Z:entry(DOWNSTAIRS).no_lights)
			assert.equal(0, Z:entry(DOWNSTAIRS).light_count)
			assert.equal("linked", Z:entry(DOWNSTAIRS).state, "the zone still exists: not gone")
			assert.equal("None", Z:attention())
			assert.is_nil(Z:grouped_light_of(DOWNSTAIRS))
			assert.is_false(Z:set({ rid = DOWNSTAIRS, on = "true", brightness = "100" }), "nothing to control")
			assert.is_true(saw_log("it has no lights; nothing to control"))
			assert.same({}, sets)

			c4.sent = {}
			feed(F.events.zone_refilled)
			assert.equal(F.refilled_grouped_light_rid, Z:grouped_light_of(DOWNSTAIRS))
			local configures = sent_to(2001, "HUE_CONFIGURE")
			assert.equal("false", configures[#configures].params.no_lights)
			assert.equal("1", configures[#configures].params.light_count)
			assert.same({ rid = DOWNSTAIRS, online = "true", on = "false", brightness = "100", reason = "event" },
				sent_to(2001, "HUE_STATE")[1].params, "the new grouped_light's state arrived with its add")
			assert.is_false(Z:entry(DOWNSTAIRS).no_lights)
			assert.is_true(Z:set({ rid = DOWNSTAIRS, on = "true", brightness = "100" }))
			assert.equal(F.refilled_grouped_light_rid, sets[1].rid, "commands go to the new grouped_light")
		end)

		it("reads an emptied zone from the grouped_light delete alone when the zone item has no services", function()
			add_downstairs()
			c4.sent = {}
			local containers = C4:JsonDecode(F.events.zone_emptied)
			containers[1].data[1].services = nil
			for _, c in ipairs(containers) do
				L:on_container(c)
				Z:on_container(c)
			end
			assert.equal(G_DOWNSTAIRS, L.groups:group(DOWNSTAIRS).grouped_light_rid, "the cache keeps the stale rid")
			assert.is_nil(Z:grouped_light_of(DOWNSTAIRS), "the delete item is remembered")
			assert.is_true(Z:entry(DOWNSTAIRS).no_lights)
			assert.equal("false", sent_to(2001, "HUE_STATE")[#sent_to(2001, "HUE_STATE")].params.online)
			c4.sent = {}
			feed(F.events.zone_refilled)
			assert.equal(F.refilled_grouped_light_rid, Z:grouped_light_of(DOWNSTAIRS))
			assert.equal("true", sent_to(2001, "HUE_STATE")[1].params.online)
		end)

		it("marks a linked zone gone on delete: CONFIGURE state gone and STATE offline, then back on add", function()
			add_downstairs()
			c4.sent = {}
			now = T0 + 50
			assert.equal(1, feed(F.events.zone_deleted))
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.equal("gone", c4.sent[1].params.state)
			assert.equal(tostring(T0 + 50), c4.sent[1].params.gone_since)
			assert.same({ rid = DOWNSTAIRS, online = "false", reason = "event" }, c4.sent[2].params)
			assert.equal("gone", Z:entry(DOWNSTAIRS).state)
			assert.equal("gone", c4.persist.hue_zone_lights[DOWNSTAIRS].state)
			assert.equal("1 zone, 2 rooms on bridge; 1 imported, 1 missing", Z:summary())
			assert.equal("1 zone light missing from the bridge: Downstairs (device 2001, since " .. os.date("%Y-%m-%d", T0 + 50)
				.. ") (Re-link Zone Light or Forget Light)", Z:attention())
			assert.is_true(saw_log("Downstairs (zone) (device 2001) was deleted on the bridge; marked gone"))
			assert.is_false(Z:set({ rid = DOWNSTAIRS, on = "true" }))
			assert.is_true(saw_log("HUE_SET for Downstairs (zone) (device 2001) ignored: zone deleted in Hue since"))
			assert.is_false(Z:dim({ rid = DOWNSTAIRS, direction = "up" }))

			c4.sent = {}
			local back = replace(replace(F.events.zone_add, F.new_zone_rid, DOWNSTAIRS), F.new_zone_grouped_light_rid,
				G_DOWNSTAIRS)
			assert.equal(1, feed(back))
			assert.equal("linked", Z:entry(DOWNSTAIRS).state)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.is_nil(c4.sent[1].params.state)
			assert.equal("Upstairs", c4.sent[1].params.name, "the re-added zone's name")
			assert.equal("1", c4.sent[1].params.light_count)
			assert.same({ rid = DOWNSTAIRS, on = "true", brightness = "40.16", mirek = "250", color_mode = "ct", online = "true",
				reason = "event" }, c4.sent[2].params, "Hallway Ambiance alone now")
			assert.is_true(saw_log("Downstairs (zone) (device 2001) is back on the bridge"))
			assert.equal("Upstairs", Z:entry(DOWNSTAIRS).name)
			assert.equal("1 zone light name differs from the Composer names: Downstairs is Upstairs in Hue "
				.. "(Adopt Hue Names or Accept Names As They Are)", Z:attention())
		end)

		it("a delete of a zone without a device, or of an unbound one, changes nothing visible", function()
			resync()
			assert.equal(0, feed(F.events.zone_deleted))
			assert.is_true(saw_log("Add Zone Light lists it") == false)
			L = new_lights()
			Z = new_zone_lights()
			add_downstairs()
			Z:on_binding_changed(1, "HUE_BRIDGE", false, 2001)
			c4.sent = {}
			assert.equal(0, feed(F.events.zone_deleted))
			assert.equal("unbound", Z:entry(DOWNSTAIRS).state)
		end)

		it("checks only the registered groups an item can change: an outsider's event costs nothing", function()
			add_downstairs()
			Z:add(GARAGE, nil, done)  -- Downstairs (zone: Garage White + Living Room Lamp) and Garage (room: Garage White)
			c4.sent = {}
			local refreshed = {}
			local refresh_entry = Z.refresh_entry
			Z.refresh_entry = function(self, rid)
				refreshed[#refreshed + 1] = rid
				return refresh_entry(self, rid)
			end
			local color_sent, online_sent = Z.color_sent[DOWNSTAIRS], Z.online_sent[DOWNSTAIRS]
			assert.equal(0, feed(F.events.ct), "the Kitchen Strip is in no group")
			assert.equal(0, feed(F.events.zone_member_ct), "Hallway Ambiance is in the Living Room, which has no device")
			assert.equal(0, feed(F.events.room_rename), "the Living Room renamed")
			assert.equal(0, feed('[{"creationtime":"2026-10-24T16:00:00Z","id":"9de116fc-00e1-4a2b-8c3d-0000000000e1",'
				.. '"type":"update","data":[{"id":"' .. F.device_rids.hallway .. '","metadata":{"name":"Hall"},'
				.. '"type":"device"}]}]'), "the Hallway's device renamed")
			assert.same({}, refreshed, "no registered group was looked at")
			assert.same({}, c4.sent)
			assert.equal(color_sent, Z.color_sent[DOWNSTAIRS])
			assert.equal(online_sent, Z.online_sent[DOWNSTAIRS])
			assert.equal(0, feed(light_event("living", '"on":{"on":false}')), "a member of the zone alone")
			assert.same({ DOWNSTAIRS }, refreshed)
			refreshed = {}
			assert.equal(1, feed(F.events.off), "Garage White is in both; the Garage's grouped_light rides along")
			assert.same({ DOWNSTAIRS, GARAGE }, refreshed, "in name order")
			assert.same({ rid = GARAGE, on = "false", reason = "event" }, c4.sent[1].params)
			refreshed = {}
			feed('[{"creationtime":"2026-10-24T16:00:00Z","id":"9de116fc-00e2-4a2b-8c3d-0000000000e2","type":"delete",'
				.. '"data":[{"id":"unknown-device","type":"device"}]}]')
			assert.same({ DOWNSTAIRS, GARAGE }, refreshed, "a device the cache has no record for: every entry, as before")
			refreshed = {}
			assert.equal(0, feed(replace(F.events.zone_renamed, DOWNSTAIRS, ATTIC)), "a zone without a device")
			assert.same({}, refreshed)
		end)

		it("logs a new zone, and follows a Hue rename: entry, CONFIGURE, the Composer name untouched", function()
			add_downstairs()
			assert.equal(0, feed(F.events.zone_add))
			assert.is_true(saw_log("new zone Upstairs (zone) on the bridge; Add Zone Light lists it"))
			assert.equal(1, #c4.added, "nothing is created from an event")
			c4.sent = {}
			assert.equal(1, feed(F.events.zone_renamed))
			assert.same({ "HUE_CONFIGURE@2001" }, commands_sent())
			assert.equal("Ground Floor", c4.sent[1].params.name)
			assert.equal("Ground Floor (zone)", c4.sent[1].params.hue_room)
			assert.equal("Ground Floor", Z:entry(DOWNSTAIRS).name)
			assert.equal("Ground Floor", c4.persist.hue_zone_lights[DOWNSTAIRS].name)
			assert.equal(0, #c4.renamed)
			assert.is_true(saw_log("Downstairs was renamed to Ground Floor in Hue (Composer name unchanged)"))
		end)
	end)

	describe("hello", function()
		it("answers a known rid with CONFIGURE and STATE, a stale rid with the device's own group", function()
			add_downstairs()
			c4.sent = {}
			assert.is_true(Z:hello({ rid = DOWNSTAIRS, device_id = "2001", kind = "group" }))
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.equal("hello", c4.sent[2].params.reason)
			assert.equal("true", c4.sent[2].params.on)
			c4.sent = {}
			assert.is_true(Z:hello({ rid = "stale", device_id = "2001", kind = "group" }))
			assert.equal(DOWNSTAIRS, c4.sent[1].params.rid)
			assert.is_true(Z:hello(DOWNSTAIRS, { device_id = "2001" }), "the lights' hello(rid, params) shape works too")
			assert.is_true(Z:hello({ rid = DOWNSTAIRS }), "a hello without a device id is answered too")
			assert.is_false(Z:hello({ device_id = "2099", kind = "group" }), "a bare unknown device waits for Link Devices")
			assert.is_false(Z:hello({ rid = "nope", kind = "group" }))
		end)

		it("answers with the configuration alone before the first GET", function()
			c4.persist.hue_zone_lights = { [DOWNSTAIRS] = { device_id = 2001, name = "Downstairs", group_type = "zone",
				light_count = "2", no_lights = "false", caps = { has_color = "true", has_cct = "true", mirek_min = "153",
				mirek_max = "500" }, id_v1 = "/groups/3", state = "linked" } }
			Z:load()
			assert.is_true(Z:hello({ rid = DOWNSTAIRS, device_id = "2001", kind = "group" }))
			assert.same({ "HUE_CONFIGURE@2001" }, commands_sent())
			assert.same({ rid = DOWNSTAIRS, name = "Downstairs", kind = "group", group_type = "zone", model = "Hue zone",
				light_count = "2", no_lights = "false", hue_room = "Downstairs (zone)", id_v1 = "/groups/3", has_color = "true",
				has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }, c4.sent[1].params)
			assert.equal(2, Z:entry(DOWNSTAIRS).light_count, "persisted strings are normalised")
			assert.is_false(Z:entry(DOWNSTAIRS).no_lights)
			c4.sent = {}
			feed(F.events.zone_on)
			c4.sent = {}
			assert.is_true(Z:hello({ rid = DOWNSTAIRS, device_id = "2001", kind = "group" }))
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent(), "once an event told the state")
			assert.equal("hello", c4.sent[2].params.reason)
		end)

		it("adopts a bound device announcing kind group for a rid the registry lacks; gone when not on the bridge", function()
			resync()
			c4:Bind(15, 1, 2099, 1, "HUE_BRIDGE")
			assert.is_true(Z:hello({ rid = DOWNSTAIRS, device_id = "2099", name = "Downstairs", kind = "group" }))
			local entry = Z:entry(DOWNSTAIRS)
			assert.equal(2099, entry.device_id)
			assert.equal("zone", entry.group_type)
			assert.equal(2, entry.light_count)
			assert.equal("/groups/3", entry.id_v1)
			assert.same({ "HUE_CONFIGURE@2099", "HUE_STATE@2099" }, commands_sent())
			assert.is_true(saw_log("adopted Downstairs (zone) (device 2099) from its own persisted rid"))
			assert.equal(2099, c4.persist.hue_zone_lights[DOWNSTAIRS].device_id)

			c4:Bind(15, 1, 2098, 1, "HUE_BRIDGE")
			assert.is_true(Z:hello({ rid = "vanished", device_id = "2098", name = "Old Zone", kind = "group" }))
			assert.equal("gone", Z:entry("vanished").state)
			assert.equal("Old Zone", Z:entry("vanished").name)
			assert.same({ rid = "vanished", name = "Old Zone", kind = "group", no_lights = "false", hue_room = "Old Zone",
				has_color = "false", has_cct = "false", min_dim = "1", state = "gone", gone_since = tostring(T0) },
				sent_to(2098, "HUE_CONFIGURE")[1].params)
			assert.same({ rid = "vanished", online = "false", reason = "hello" }, sent_to(2098, "HUE_STATE")[1].params)
		end)

		it("does not adopt an unbound device, a light's hello, or two devices claiming one group", function()
			add_downstairs()
			assert.is_false(Z:hello({ rid = LIVING, device_id = "2099", kind = "group" }))
			assert.is_nil(Z:entry(LIVING))
			assert.is_true(saw_log("device 2099 announced"))
			c4:Bind(15, 1, 2097, 1, "HUE_BRIDGE")
			assert.is_false(Z:hello({ rid = F.rids.living, device_id = "2097", name = "Living Room Lamp",
				model = "Hue color lamp" }), "a light's hello (no kind) is the lights' business")
			assert.is_nil(Z:entry(F.rids.living))
			assert.is_false(Z:hello({ rid = DOWNSTAIRS, device_id = "2099", kind = "group" }))
			assert.equal(2001, Z:entry(DOWNSTAIRS).device_id)
			assert.equal("2 devices claim Hue zone Downstairs: 2001 and 2099 (Forget Light on one of them)", Z:attention())
			-- Two devices announcing one unregistered group: neither is adopted.
			assert.is_false(Z:hello({ rid = LIVING, device_id = "2098", kind = "group" }), "not bound: remembered, not adopted")
			c4:Bind(15, 1, 2096, 1, "HUE_BRIDGE")
			assert.is_false(Z:hello({ rid = LIVING, device_id = "2096", kind = "group" }))
			assert.is_nil(Z:entry(LIVING))
			assert.truthy(Z:attention():find("2 devices claim Hue room Living Room: 2098 and 2096 (Forget Light on one of them)",
				1, true))
			assert.is_true(saw_log("devices 2098 and 2096 both announce"))
		end)

		-- Code analysis 2026-10-22 R11, as the lights'.
		it("takes a hello's name, kind and model only when they are strings", function()
			resync()
			c4:Bind(15, 1, 2099, 1, "HUE_BRIDGE")
			assert.is_true(Z:hello({ rid = "vanished", device_id = "2099", name = { "junk" }, kind = "group" }))
			assert.is_nil(Z:entry("vanished").name)
			assert.same({ rid = "vanished", kind = "group" }, Z.announced[2099])
			Z:hello({ rid = "other", device_id = "2098", name = 7, kind = {}, model = true })
			assert.same({ rid = "other" }, Z.announced[2098])
			assert.truthy(Z:attention():find("^1 zone light missing from the bridge: vanished %(device 2099"))
		end)

		it("keeps at most 200 hellos before load() and drops the rest with a warning", function()
			for i = 1, 202 do
				Z:hello({ rid = DOWNSTAIRS, device_id = tostring(3000 + i), kind = "group" })
			end
			assert.equal(200, #Z.early_hellos)
			assert.equal(200, zone_lights.EARLY_HELLOS_MAX)
			assert.is_true(saw_log("zone_lights: HUE_HELLO from device 3201 before the registry was loaded: dropped "
				.. "(200 waiting)"))
		end)

		it("queues a hello that arrives before load() and answers it from configure_all()", function()
			c4.persist.hue_zone_lights = { [DOWNSTAIRS] = { device_id = 2001, name = "Downstairs", state = "linked" } }
			assert.is_false(Z:hello({ rid = DOWNSTAIRS, device_id = "2001", kind = "group" }))
			assert.equal(0, #c4.sent)
			Z:load()
			assert.equal(1, Z:configure_all())
			assert.same({ "HUE_CONFIGURE@2001", "HUE_CONFIGURE@2001" }, commands_sent(),
				"configure_all, then the queued hello answered with the configuration (no state known yet)")
		end)
	end)

	describe("goodbye and tombstones", function()
		it("tombstones the entry; the picker lists the group last as deleted; Add Zone Light clears it", function()
			add_downstairs()
			now = T0 + 100
			local tomb = Z:goodbye({ rid = DOWNSTAIRS, device_id = "2001" })
			assert.same({ name = "Downstairs", device_name = nil, deleted_at = T0 + 100 }, tomb)
			assert.is_nil(Z:entry(DOWNSTAIRS))
			assert.same(tomb, c4.persist.hue_zone_light_tombstones[DOWNSTAIRS])
			assert.equal("2 zones, 2 rooms on bridge; 0 imported, 1 deleted", Z:summary())
			assert.equal("None", Z:attention())
			local date = os.date("%Y-%m-%d", T0 + 100)
			local list = texts(Z:picker_groups())
			assert.equal("Downstairs (zone, 2 lights) (deleted from Composer " .. date .. ")", list[#list])
			assert.is_true(saw_log("Downstairs (zone) (device 2001) was deleted in Composer; Add Zone Light lists it as "
				.. "deleted"))
			Z:add(DOWNSTAIRS, GARAGE_ROOM, done)
			assert.equal("Added Downstairs (zone) to Garage (device 2002)", last_result().text)
			assert.is_nil(c4.persist.hue_zone_light_tombstones[DOWNSTAIRS])
		end)

		it("finds the entry by device id alone, by rid alone, and leaves strangers to the lights' module", function()
			add_downstairs()
			Z:add(LIVING, nil, done)
			assert.truthy(Z:goodbye({ device_id = "2001" }))
			assert.truthy(Z:goodbye({ rid = LIVING }))
			assert.is_nil(Z:goodbye({ rid = F.rids.living, device_id = "999" }))
			assert.is_nil(Z:goodbye({}))
			assert.equal(0, Z:count())
			assert.is_true(saw_log("HUE_GOODBYE from a device that is not a zone light"))
		end)
	end)

	describe("on_binding_changed", function()
		it("marks an entry unbound on binding 1 false and linked again on true, ignoring other bindings", function()
			add_downstairs()
			c4.sent = {}
			now = T0 + 7
			assert.is_true(Z:on_binding_changed(1, "HUE_BRIDGE", false, "2001"))
			assert.equal("unbound", Z:entry(DOWNSTAIRS).state)
			assert.equal(T0 + 7, Z:entry(DOWNSTAIRS).unbound_since)
			assert.is_true(saw_log("Downstairs (zone) (device 2001) was unbound from the bridge"))
			assert.is_false(Z:on_binding_changed(1, "HUE_BRIDGE", false, 2001), "already unbound")
			assert.is_true(Z:on_binding_changed(1, "HUE_BRIDGE", true, 2001))
			assert.equal("linked", Z:entry(DOWNSTAIRS).state)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.is_false(Z:on_binding_changed(5001, nil, false, 2001))
			assert.is_false(Z:on_binding_changed(1, "OTHER", false, 2001))
			assert.is_false(Z:on_binding_changed(1, "HUE_BRIDGE", false, 4242), "a light, not ours")
			assert.equal("linked", Z:entry(DOWNSTAIRS).state)
		end)
	end)

	describe("set (HUE_SET)", function()
		it("queues the absolute fields on the group's grouped_light: ON is on=true brightness=100", function()
			add_downstairs()
			c4.sent = {}
			local n = #c4.transfers
			assert.is_true(Z:set({ rid = DOWNSTAIRS, on = "true", brightness = "100", rate = "0" }))
			assert.same({ { rid = G_DOWNSTAIRS, fields = { on = true, brightness = 100, rate = 0 } } }, sets)
			assert.is_true(Z:set({ rid = DOWNSTAIRS, on = "false", rate = "250" }))
			assert.same({ on = false, rate = 250 }, sets[2].fields)
			assert.is_true(Z:set({ rid = DOWNSTAIRS, brightness = "40", rate = "400" }))
			assert.same({ brightness = 40, rate = 400 }, sets[3].fields)
			assert.equal(n, #c4.transfers, "no transfer of its own")
			assert.same({}, c4.sent, "no STATE: the stream reports")
			assert.is_true(saw_log("HUE_SET Downstairs (zone) (device 2001): grouped_light 8e7d6c5b on=true brightness=100"))
		end)

		it("passes colour and colour temperature through, one of the two", function()
			add_downstairs()
			assert.is_true(Z:set({ rid = DOWNSTAIRS, x = "0.1532", y = "0.0475", rate = "400" }))
			assert.same({ x = 0.1532, y = 0.0475, rate = 400 }, sets[1].fields)
			assert.is_true(Z:set({ rid = DOWNSTAIRS, mirek = "366", rate = "0" }))
			assert.same({ mirek = 366, rate = 0 }, sets[2].fields)
			assert.is_true(Z:set({ rid = DOWNSTAIRS, on = "true", brightness = "100", mirek = "300" }))
			assert.same({ on = true, brightness = 100, mirek = 300 }, sets[3].fields,
				"a colour kept while off rides with the turn-on")
		end)

		it("refuses an unknown rid, no rid, nothing to set, and a group_set that queues nothing", function()
			add_downstairs()
			assert.is_false(Z:set({ rid = LIVING, on = "true" }))
			assert.is_true(saw_log("HUE_SET for unregistered group"))
			assert.is_false(Z:set({ on = "true" }))
			assert.is_true(saw_log("HUE_SET without a rid ignored"))
			assert.is_false(Z:set({ rid = DOWNSTAIRS, rate = "400" }))
			assert.is_true(saw_log("carries nothing to set"))
			assert.is_false(Z:set({ rid = DOWNSTAIRS, x = "0.5" }), "half a colour is nothing to set")
			Z.ctx.group_set = function() return false end
			assert.is_false(Z:set({ rid = DOWNSTAIRS, on = "true" }))
			assert.is_true(saw_log("HUE_SET for Downstairs (zone) (device 2001): nothing queued"))
			assert.same({}, sets)
		end)

		it("without group_set in ctx logs and returns false", function()
			Z = zone_lights.new({ http = http_ctx, now = function() return now end, lights = L })
			add_downstairs()
			assert.is_false(Z:set({ rid = DOWNSTAIRS, on = "true" }))
			assert.is_true(saw_log("no group_set in ctx"))
		end)
	end)

	describe("dim (HUE_DIM)", function()
		it("queues a dimming_delta up or down over the duration, clamped, default 5000 ms", function()
			add_downstairs()
			c4.sent = {}
			assert.is_true(Z:dim({ rid = DOWNSTAIRS, direction = "up", duration = "5000" }))
			assert.same({ rid = G_DOWNSTAIRS, body = { dimming_delta = { action = "up", brightness_delta = 100 },
				dynamics = { duration = 5000 } } }, dims[1])
			assert.is_true(Z:dim({ rid = DOWNSTAIRS, direction = "down", duration = "99999999" }))
			assert.equal(6000000, dims[2].body.dynamics.duration)
			assert.equal("down", dims[2].body.dimming_delta.action)
			assert.is_true(Z:dim({ rid = DOWNSTAIRS, direction = "up", duration = "-5" }))
			assert.equal(0, dims[3].body.dynamics.duration)
			assert.is_true(Z:dim({ rid = DOWNSTAIRS, direction = "up" }))
			assert.equal(5000, dims[4].body.dynamics.duration)
			assert.same({}, c4.sent, "no STATE")
		end)

		it("queues a stop without dynamics, carrying the device's level estimate", function()
			add_downstairs()
			assert.is_true(Z:dim({ rid = DOWNSTAIRS, direction = "stop", level = "42" }))
			assert.same({ rid = G_DOWNSTAIRS, body = { dimming_delta = { action = "stop" } }, level = 42 }, dims[1])
			assert.is_true(Z:dim({ rid = DOWNSTAIRS, direction = "stop" }))
			assert.is_nil(dims[2].level)
		end)

		it("refuses a bad direction, an unknown rid and a group_dim that queues nothing", function()
			add_downstairs()
			assert.is_false(Z:dim({ rid = DOWNSTAIRS, direction = "sideways" }))
			assert.is_true(saw_log("unknown direction sideways"))
			assert.is_false(Z:dim({ rid = "nope", direction = "up" }))
			assert.is_false(Z:dim({ direction = "up" }))
			Z.ctx.group_dim = function() return false end
			assert.is_false(Z:dim({ rid = DOWNSTAIRS, direction = "up" }))
			assert.is_true(saw_log("HUE_DIM for Downstairs (zone) (device 2001): nothing queued"))
			assert.same({}, dims)
		end)

		it("without group_dim in ctx logs and returns false", function()
			Z = zone_lights.new({ http = http_ctx, now = function() return now end, lights = L })
			add_downstairs()
			assert.is_false(Z:dim({ rid = DOWNSTAIRS, direction = "up" }))
			assert.is_true(saw_log("no group_dim in ctx"))
		end)
	end)

	describe("relink", function()
		it("re-points the entry at another zone or room, keeping the device, and tells it", function()
			add_downstairs()
			feed(F.events.zone_deleted)
			c4.sent = {}
			local ok, text = Z:relink("2001", GARAGE)
			assert.is_true(ok)
			assert.equal("Re-linked device 2001 (was Downstairs) to room Garage", text)
			assert.is_nil(Z:entry(DOWNSTAIRS))
			local entry = Z:entry(GARAGE)
			assert.equal(2001, entry.device_id)
			assert.equal("linked", entry.state)
			assert.equal("Garage", entry.name)
			assert.equal("room", entry.group_type)
			assert.equal(1, entry.light_count)
			assert.equal("/groups/1", entry.id_v1)
			assert.same({ has_color = false, has_cct = false, min_dim = 1 }, entry.caps)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.equal("Hue room", c4.sent[1].params.model)
			assert.is_nil(c4.sent[1].params.state)
			assert.same({ rid = GARAGE, on = "false", brightness = "100", online = "true", reason = "resync" },
				c4.sent[2].params)
			assert.equal(2001, c4.persist.hue_zone_lights[GARAGE].device_id)
			assert.equal(0, #c4.renamed)
			assert.equal("1 zone light name differs from the Composer names: Downstairs is Garage Lights in Hue "
				.. "(Adopt Hue Names or Accept Names As They Are)", Z:attention(), "the device keeps its name; Attention says so")
		end)

		-- Code analysis 2026-10-22 R5: a stale `announced` made false conflicts.
		it("forgets what the device announced when it is re-linked or tombstoned", function()
			add_downstairs()
			Z:hello({ rid = DOWNSTAIRS, device_id = "2001", kind = "group" })
			assert.equal(DOWNSTAIRS, Z.announced[2001].rid)
			feed(F.events.zone_deleted)
			assert.is_true((Z:relink("2001", GARAGE)))
			assert.is_nil(Z.announced[2001])
			-- A restored device announcing the old rid is no conflict with device 2001.
			c4:Bind(15, 1, 2099, 1, "HUE_BRIDGE")
			assert.is_true(Z:hello({ rid = DOWNSTAIRS, device_id = "2099", kind = "group" }))
			assert.equal(2099, Z:entry(DOWNSTAIRS).device_id)
			assert.is_false(saw_log("both announce"))
			-- Deleted in Composer while the bridge was not watching.
			fake.project.devices[2099] = nil
			c4.bindings = {}
			c4:Bind(15, 1, 2001, 1, "HUE_BRIDGE")
			assert.same({ DOWNSTAIRS }, Z:reconcile().tombstoned)
			assert.is_nil(Z.announced[2099])
			-- A goodbye that names the rid alone.
			Z:hello({ rid = GARAGE, device_id = "2001", kind = "group" })
			assert.truthy(Z:goodbye({ rid = GARAGE }))
			assert.is_nil(Z.announced[2001])
		end)

		it("refuses bad arguments, unknown devices, held groups, a light rid and groups not on the bridge", function()
			add_downstairs()
			Z:add(LIVING, nil, done)
			assert.same({ false, "Not re-linked: pick a device and a zone or room" }, { Z:relink(nil, GARAGE) })
			assert.same({ false, "Not re-linked: pick a device and a zone or room" }, { Z:relink(2001, "") })
			assert.same({ false, "Not re-linked: device 999 is not a registered zone light" }, { Z:relink(999, GARAGE) })
			assert.same({ false, "Not re-linked: device 2001 is already linked to Downstairs (zone)" },
				{ Z:relink(2001, DOWNSTAIRS) })
			assert.same({ false, "Not re-linked: Living Room (room) is already linked to device 2002" },
				{ Z:relink(2001, LIVING) })
			assert.same({ false, "Not re-linked: device 2001 is a zone light; pick a zone or room" },
				{ Z:relink(2001, F.rids.living) })
			assert.same({ false, "Not re-linked: zone or room nope is not on the bridge (connect the event stream and try "
				.. "again)" }, { Z:relink(2001, "nope") })
			assert.same({ false, "Not re-linked: zone or room " .. F.group_rids.home .. " is not on the bridge (connect the "
				.. "event stream and try again)" }, { Z:relink(2001, F.group_rids.home) })
			assert.equal(2001, Z:entry(DOWNSTAIRS).device_id)
		end)
	end)

	describe("forget", function()
		it("removes the entry, unbinds, tells the device, and lists the group under Add Zone Light again", function()
			add_downstairs()
			c4.sent = {}
			local ok, text = Z:forget("2001")
			assert.is_true(ok)
			assert.equal("Forgot Downstairs (zone, device 2001): unbound and left in the project for you to delete", text)
			assert.is_nil(Z:entry(DOWNSTAIRS))
			assert.same({ { id = 2001, command = "HUE_FORGOTTEN", params = { rid = DOWNSTAIRS, name = "Downstairs" } } },
				c4.sent)
			assert.same({ { 2001, 1 } }, c4.calls_to("Unbind"))
			assert.is_nil(c4.persist.hue_zone_lights[DOWNSTAIRS])
			assert.is_nil(c4.persist.hue_zone_light_tombstones[DOWNSTAIRS], "forget leaves no tombstone")
			assert.same({ DOWNSTAIRS }, { values(Z:picker_groups())[2] })
			assert.same({ false, "Not forgotten: pick a device first" }, { Z:forget(nil) })
			assert.same({ false, "Not forgotten: device 2001 is not a registered zone light" }, { Z:forget(2001) })
		end)

		it("forget_request from the device: by device id, by rid, and nil for a device that is not ours", function()
			add_downstairs()
			Z:add(LIVING, nil, done)
			c4.sent = {}
			assert.is_true((Z:forget_request({ rid = DOWNSTAIRS, device_id = "2001" })))
			assert.is_true((Z:forget_request({ rid = LIVING })))
			assert.equal(0, Z:count())
			assert.is_nil(Z:forget_request({ rid = F.rids.living, device_id = "2099", name = "Lamp" }))
			assert.is_nil(Z:forget_request({}))
			assert.equal(2, #c4.sent, "a stranger is not told anything here; the lights' module does that")
		end)
	end)

	describe("link_devices", function()
		local function bound_light_device(id, name)
			fake.project.devices[id] = { name = name, room_id = LIVING_ROOM, c4i = "hue_light.c4z", driver_name = "Hue Light" }
			c4:Bind(15, 1, id, 1, "HUE_BRIDGE")
		end

		it("counts only the hue_light devices announcing kind group, or saying nothing, outside the skip set", function()
			resync()
			bound_light_device(4242, "Lamp")
			Z:hello({ rid = F.rids.living, device_id = "4242", name = "Lamp", model = "Hue color lamp" })
			assert.equal("No zone light devices are bound to this bridge", Z:link_devices())
			bound_light_device(4243, "Downstairs")
			assert.equal("No zone light devices are bound to this bridge", Z:link_devices({ [4243] = true }), "in the skip set")
			assert.equal("No zone light devices are bound to this bridge", Z:link_devices({ 4243 }), "a list works too")
			add_downstairs()
			assert.equal("All 1 bound zone light devices are registered", Z:link_devices({ [4243] = true }))
		end)

		it("adopts by announced rid, by a zone's name, by a room's creation name, and reports the rest", function()
			resync()
			for id, name in pairs({ [2091] = "Whatever", [2092] = "Downstairs", [2093] = "Living Room Lights",
				[2094] = "Garage", [2095] = "Mystery", [2096] = "Attic", [2097] = "Attic" }) do
				bound_light_device(id, name)
			end
			Z:hello({ rid = GARAGE, device_id = "2091", name = "Garage", kind = "group" })  -- adopted at once by its hello
			c4.sent = {}
			Z.registry[GARAGE] = nil  -- pretend the registry was lost; the hello was remembered
			Z.reg.lights[GARAGE] = nil
			local text = Z:link_devices()
			assert.equal("Linked 3 zone light devices: Whatever (device 2091) to Garage (room) by its rid, "
				.. "Downstairs (device 2092) to Downstairs (zone) by name, "
				.. "Living Room Lights (device 2093) to Living Room (room) by name; "
				.. "not linked 4: Garage (device 2094): no unimported Hue zone or room has that name; rename the device in "
				.. "Composer to the zone's exact name (a room's as \"<Room> Lights\") and run Link Devices again; "
				.. "Mystery (device 2095): no unimported Hue zone or room has that name; rename the device in Composer to the "
				.. "zone's exact name (a room's as \"<Room> Lights\") and run Link Devices again; "
				.. "Attic (device 2096): 2 bound devices share that name; rename one in Composer and run Link Devices again; "
				.. "Attic (device 2097): 2 bound devices share that name; rename one in Composer and run Link Devices again",
				text)
			assert.equal(2091, Z:entry(GARAGE).device_id)
			assert.equal(2092, Z:entry(DOWNSTAIRS).device_id)
			assert.equal(2093, Z:entry(LIVING).device_id)
			assert.same({ "HUE_CONFIGURE@2091", "HUE_STATE@2091", "HUE_CONFIGURE@2092", "HUE_STATE@2092", "HUE_CONFIGURE@2093",
				"HUE_STATE@2093" }, commands_sent())
			assert.equal("Living Room Lights", c4.added[1] and c4.added[1].name or "Living Room Lights", "nothing was created")
			assert.equal(0, #c4.added)
		end)

		it("reports a device whose announced rid another device holds, and a group not on the bridge as gone", function()
			add_downstairs()
			bound_light_device(2099, "Downstairs")
			Z:hello({ rid = DOWNSTAIRS, device_id = "2099", kind = "group" })
			bound_light_device(2098, "Old")
			Z:hello({ rid = "vanished", device_id = "2098", kind = "group" })  -- no name announced: the Composer name serves
			Z.registry["vanished"] = nil
			Z.reg.lights["vanished"] = nil
			assert.equal("Linked 1 zone light device: Old (device 2098) to Old by its rid (not on the bridge: marked gone); "
				.. "not linked 1: Downstairs (device 2099) announces Downstairs (zone), which device 2001 holds "
				.. "(Forget Light on one of them)", Z:link_devices())
			assert.equal("gone", Z:entry("vanished").state)
		end)

		it("uses the hellos when the project lookup is unavailable", function()
			Z = new_zone_lights({ project = { devices = function() return nil end } })
			Z:load()
			resync()
			c4:Bind(15, 1, 2091, 1, "HUE_BRIDGE")
			c4:Bind(15, 1, 4242, 1, "HUE_BRIDGE")
			assert.equal("No zone light devices are bound to this bridge", Z:link_devices())
			Z.announced[2091] = { rid = DOWNSTAIRS, kind = "group" }
			Z.announced[4242] = { rid = F.rids.living, model = "Hue color lamp" }
			assert.equal("Linked 1 zone light device: device 2091 (device 2091) to Downstairs (zone) by its rid",
				Z:link_devices())
			assert.equal(2091, Z:entry(DOWNSTAIRS).device_id)
		end)
	end)

	describe("names", function()
		local function import_two()
			add_downstairs()
			Z:add(LIVING, nil, done)
			-- The proxies the fake made for the two devices.
			Z.registry[DOWNSTAIRS].proxy_id = 3001
			Z.registry[LIVING].proxy_id = 3002
		end

		it("compares the Composer name with the creation name and renames through the proxy", function()
			import_two()
			assert.equal("No Composer names differ from the Hue zone and room names", Z:adopt_hue_names())
			assert.same({}, Z:name_differences())
			fake.project.devices[3001].name = "Bedside"
			fake.project.devices[3002].name = "Living Room"
			local diffs = Z:name_differences()
			assert.equal(2, #diffs)
			assert.equal("Downstairs", diffs[1].expected)
			assert.equal("Living Room Lights", diffs[2].expected)
			assert.equal("2 zone light names differ from the Composer names: Bedside is Downstairs in Hue, "
				.. "Living Room is Living Room Lights in Hue (Adopt Hue Names or Accept Names As They Are)", Z:attention())
			assert.equal("Renamed 2 zone light devices: Bedside → Downstairs (device 2001), "
				.. "Living Room → Living Room Lights (device 2002)", Z:adopt_hue_names())
			assert.same({ { id = 3001, name = "Downstairs" }, { id = 3002, name = "Living Room Lights" } }, c4.renamed)
			assert.equal("None", Z:attention())
		end)

		it("accepts differences until the Hue name changes, and skips devices without a proxy id", function()
			import_two()
			fake.project.devices[3001].name = "Bedside"
			assert.equal("Accepted 1 zone light name difference: Bedside (Hue: Downstairs)", Z:accept_names())
			assert.equal("Downstairs", c4.persist.hue_zone_lights[DOWNSTAIRS].name_dismissed)
			assert.equal("None", Z:attention())
			assert.equal("No Composer names differ from the Hue zone and room names", Z:accept_names())
			feed(F.events.zone_renamed)
			assert.equal("1 zone light name differs from the Composer names: Bedside is Ground Floor in Hue "
				.. "(Adopt Hue Names or Accept Names As They Are)", Z:attention())
			Z.registry[DOWNSTAIRS].proxy_id = nil
			assert.equal("not renamed 1: Downstairs (device 2001): no proxy id known", Z:adopt_hue_names(),
				"without a proxy id the protocol device's own name is compared")
		end)
	end)

	-- Security review 2026-10-25 finding 8: AddDevice, Adopt Hue Names and
	-- the device's Hue Name and Hue Room rows get display names; the registry
	-- keeps Hue's own. bridge/owner_spec.lua has the upgrade cases.
	describe("names that reach Control4 (security review 2026-10-25 finding 8)", function()
		-- The Living Room called at length, with a newline, in an app paired
		-- with the bridge (JSON contents), as the registry keeps it ...
		local ROOM = "Living Room\\n with the bay window seat and the doors to the garden"
		local RAW = "Living Room\n with the bay window seat and the doors to the garden"
		-- ... and the display names of the name and of "<Room> Lights".
		local SHOWN = "Living Room with the bay window seat and the doors to the garden"
		local SHOWN_LIGHTS = SHOWN .. " Lights"

		-- The lights' caches with the Living Room and the Downstairs zone named
		-- as given (JSON contents), then a fresh Z over them.
		local function groups_named(room, zone)
			L = lights.new({ http = http_ctx, now = function() return now end })
			L:absorb({ light = decode_data(F.light), device = decode_data(F.device),
				zigbee = decode_data(F.zigbee_connectivity),
				room = decode_data(replace(F.room, '"name":"Living Room"', '"name":"' .. room .. '"')),
				zone = decode_data(replace(F.zone, '"name":"Downstairs"', '"name":"' .. zone .. '"')),
				bridge_home = decode_data(F.bridge_home) })
			Z = new_zone_lights()
		end

		it("adds a room device under the display name of '<Room> Lights'; the device hears display names", function()
			groups_named(ROOM, "Downstairs")
			resync()
			Z:add(LIVING, LIVING_ROOM, done)
			assert.is_true(last_result().ok)
			assert.equal(SHOWN_LIGHTS, c4.added[1].name)
			local configure = sent_to(2001, "HUE_CONFIGURE")[1].params
			assert.same({ SHOWN, SHOWN }, { configure.name, configure.hue_room })
			assert.equal(RAW, Z:entry(LIVING).name, "the registry keeps Hue's name")
		end)

		it("does not list a room device an older build created under the raw name", function()
			groups_named(ROOM, "Downstairs")
			resync()
			Z:add(LIVING, LIVING_ROOM, done)
			Z.registry[LIVING].proxy_id = 3001
			fake.project.devices[3001].name = RAW .. " Lights"  -- what an older build's AddDevice was given
			assert.same({}, Z:name_differences())
			assert.equal("No Composer names differ from the Hue zone and room names", Z:adopt_hue_names())
			assert.same({}, c4.renamed)
		end)

		it("adds a zone whose Hue name has nothing to show as Hue zone light", function()
			groups_named("Living Room", "\\t\\n")
			resync()
			Z:add(DOWNSTAIRS, GARAGE_ROOM, done)
			assert.is_true(last_result().ok)
			assert.equal("Hue zone light", c4.added[1].name)
			local configure = sent_to(2001, "HUE_CONFIGURE")[1].params
			assert.is_nil(configure.name)
			assert.equal("(zone)", configure.hue_room)
		end)
	end)

	describe("pickers", function()
		it("picker_groups lists zones then rooms with their light counts, deleted ones last", function()
			assert.same({ "Attic (zone, no lights)", "Downstairs (zone, 2 lights)", "Garage (room, 1 light)",
				"Living Room (room, 2 lights)" }, texts(Z:picker_groups()))
			assert.same({ ATTIC, DOWNSTAIRS, GARAGE, LIVING }, values(Z:picker_groups()))
			add_downstairs()
			Z:add(GARAGE, nil, done)
			Z:goodbye({ device_id = "2002" })
			assert.same({ "Attic (zone, no lights)", "Living Room (room, 2 lights)",
				"Garage (room, 1 light) (deleted from Composer " .. os.date("%Y-%m-%d", T0) .. ")" }, texts(Z:picker_groups()))
			Z:add(GARAGE, nil, done)
			Z:add(LIVING, nil, done)
			Z.reg.lights[ATTIC] = { device_id = 11, state = "linked" }
			assert.same({ { text = "(every zone and room on the bridge is imported)", value = "" } }, Z:picker_groups())
		end)

		it("replaces commas in names with spaces", function()
			L:absorb({ room = decode_data(F.room), bridge_home = decode_data(F.bridge_home),
				zone = decode_data(F.zone:gsub('"name":"Downstairs"', '"name":"Down, stairs"')) })
			assert.equal("Down  stairs (zone, 2 lights)", texts(Z:picker_groups())[2])
		end)

		it("picker_relink_devices and picker_forget_devices name the kind, empty arrays when there is nothing", function()
			assert.same({}, Z:picker_relink_devices())
			assert.same({}, Z:picker_forget_devices())
			add_downstairs()
			Z:add(LIVING, nil, done)
			Z:add(GARAGE, nil, done)
			assert.same({ "Downstairs (zone light, device 2001)", "Garage (room light, device 2003)",
				"Living Room (room light, device 2002)" }, texts(Z:picker_forget_devices()))
			now = T0 + 3600 * 24
			feed(F.events.zone_deleted)
			Z:on_binding_changed(1, "HUE_BRIDGE", false, 2003)
			local date = os.date("%m-%d", now)
			assert.same({ "Downstairs (zone light, device 2001, gone since " .. date .. ")",
				"Garage (room light, device 2003, unbound since " .. date .. ")" }, texts(Z:picker_relink_devices()))
			assert.same({ "2001", "2003" }, values(Z:picker_relink_devices()))
			assert.same({ "Downstairs (zone light, device 2001) gone", "Garage (room light, device 2003) unbound",
				"Living Room (room light, device 2002)" }, texts(Z:picker_forget_devices()))
		end)
	end)

	describe("summary and attention", function()
		it("keeps the Zone Lights text under 60 characters in the usual cases", function()
			add_downstairs()
			assert.equal("2 zones, 2 rooms on bridge; 1 imported", Z:summary())
			assert.is_true(#Z:summary() < 60)
			feed(F.events.zone_deleted)
			assert.equal("1 zone, 2 rooms on bridge; 1 imported, 1 missing", Z:summary())
			assert.is_true(#Z:summary() < 60)
			assert.is_true(#string.format("%d zones, %d rooms on bridge; %d imported, %d missing", 7, 16, 23, 1) < 60)
			assert.is_true(#string.format("%d zones, %d rooms on bridge; %d imported, %d deleted", 7, 16, 23, 2) < 60)
		end)

		it("lists missing, unbound and conflicting group devices and name differences as separate items", function()
			add_downstairs()
			Z:add(LIVING, nil, done)
			Z:add(GARAGE, nil, done)
			now = T0 + 60
			feed(F.events.zone_deleted)
			Z:on_binding_changed(1, "HUE_BRIDGE", false, 2003)
			Z:hello({ rid = LIVING, device_id = "2099", kind = "group" })
			fake.project.devices[2002].name = "Lounge"
			local items = Z:attention_items()
			assert.same({
				"1 zone light missing from the bridge: Downstairs (device 2001, since " .. os.date("%Y-%m-%d", T0 + 60)
					.. ") (Re-link Zone Light or Forget Light)",
				"1 unbound zone light device: Garage (device 2003) (bind it to this bridge in Composer, or Forget Light)",
				"2 devices claim Hue room Living Room: 2002 and 2099 (Forget Light on one of them)",
				"1 zone light name differs from the Composer names: Lounge is Living Room Lights in Hue "
					.. "(Adopt Hue Names or Accept Names As They Are)",
			}, items)
			assert.equal(table.concat(items, "; "), Z:attention())
		end)
	end)

	describe("load and configure_all", function()
		it("configures every bound entry from the persisted record before any GET, counts and caps included", function()
			c4.persist.hue_zone_lights = {
				[DOWNSTAIRS] = { device_id = 2001, name = "Downstairs", group_type = "zone", light_count = 2, no_lights = false,
					caps = { has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 1 }, id_v1 = "/groups/3",
					state = "linked" },
				["gone-zone"] = { device_id = 2002, name = "Cellar", group_type = "zone", light_count = "0", no_lights = "true",
					state = "gone", gone_since = T0 - 5 },
				[GARAGE] = { device_id = 2003, name = "Garage", group_type = "room", state = "unbound", unbound_since = T0 - 5 },
			}
			-- No lights instance at all: everything must come from the entries.
			Z = zone_lights.new({ http = http_ctx, now = function() return now end })
			Z:load()
			assert.equal(3, Z:count())
			assert.equal(2, Z:configure_all())
			assert.same({ "HUE_CONFIGURE@2002", "HUE_CONFIGURE@2001" }, commands_sent(), "name order")
			assert.same({ rid = DOWNSTAIRS, name = "Downstairs", kind = "group", group_type = "zone", model = "Hue zone",
				light_count = "2", no_lights = "false", hue_room = "Downstairs (zone)", id_v1 = "/groups/3", has_color = "true",
				has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "1" }, c4.sent[2].params)
			assert.same({ rid = "gone-zone", name = "Cellar", kind = "group", group_type = "zone", model = "Hue zone",
				light_count = "0", no_lights = "true", hue_room = "Cellar (zone)", has_color = "false", has_cct = "false",
				min_dim = "1", state = "gone", gone_since = tostring(T0 - 5) }, c4.sent[1].params)
			assert.equal("3 imported", Z:summary())
			assert.equal("1 zone light missing from the bridge: Cellar (device 2002, since " .. os.date("%Y-%m-%d", T0 - 5)
				.. ") (Re-link Zone Light or Forget Light); 1 unbound zone light device: Garage (device 2003) (bind it to "
				.. "this bridge in Composer, or Forget Light)", Z:attention())
			assert.is_true(Z.configured_once)
		end)

		it("after load, a resync refreshes the entries from the cache and sends CONFIGURE only on change", function()
			c4.persist.hue_zone_lights = {
				[DOWNSTAIRS] = { device_id = 2001, name = "Old Downstairs", group_type = "zone", light_count = 5, state = "linked",
					caps = { has_color = false, has_cct = false } },
			}
			c4:Bind(15, 1, 2001, 1, "HUE_BRIDGE")
			Z:load()
			Z:configure_all()
			c4.sent = {}
			resync()
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.equal("Downstairs", c4.sent[1].params.name)
			assert.equal("2", c4.sent[1].params.light_count)
			assert.equal("true", c4.sent[1].params.has_color)
			assert.equal("/groups/3", c4.sent[1].params.id_v1)
			assert.equal("Downstairs", Z:entry(DOWNSTAIRS).name)
			assert.equal(2, #c4.calls_to("PersistSetValue"), "one save of the two keys for the whole resync")
			c4.sent = {}
			resync()
			assert.same({ "HUE_STATE@2001" }, commands_sent())
		end)

		it("does not judge a missing group before the lights have fetched the groups", function()
			c4.persist.hue_zone_lights = { [DOWNSTAIRS] = { device_id = 2001, name = "Downstairs", group_type = "zone",
				state = "linked" } }
			c4:Bind(15, 1, 2001, 1, "HUE_BRIDGE")
			L = lights.new({ http = http_ctx, now = function() return now end })  -- nothing fetched yet
			Z = new_zone_lights()
			Z:load()
			Z:configure_all()
			c4.sent = {}
			resync()
			assert.equal("linked", Z:entry(DOWNSTAIRS).state)
			assert.same({}, c4.sent, "no state is known yet, nothing is told")
			assert.equal("1 imported", Z:summary())
		end)
	end)

	describe("list_items", function()
		local function deleted(ts)
			return " (deleted from Composer " .. os.date("%Y-%m-%d", ts) .. ")"
		end

		local function no_commas(items)
			for _, item in ipairs(items) do
				assert.is_nil(item:find(",", 1, true), "comma in " .. item)
			end
		end

		it("is empty without groups or a registry", function()
			Z = zone_lights.new({ http = http_ctx })
			assert.same({}, Z:list_items())
		end)

		it("lists zones then rooms with the picker's labels, ';' inside the parentheses, and the device", function()
			assert.same({ "Attic (zone; no lights)", "Downstairs (zone; 2 lights)", "Garage (room; 1 light)",
				"Living Room (room; 2 lights)" }, Z:list_items())
			add_downstairs()
			Z:add(LIVING, nil, done)
			assert.same({ "Attic (zone; no lights)", "Downstairs (zone; 2 lights) → device 2001", "Garage (room; 1 light)",
				"Living Room (room; 2 lights) → device 2002" }, Z:list_items())
		end)

		it("marks tombstones, groups deleted in Hue (after the rooms) and unbound devices", function()
			add_downstairs()          -- device 2001
			Z:add(LIVING, nil, done)  -- device 2002
			Z:add(GARAGE, nil, done)  -- device 2003
			now = T0 + 100
			Z:goodbye({ device_id = "2002" })
			feed(F.events.zone_deleted)
			Z:on_binding_changed(1, "HUE_BRIDGE", false, 2003)
			assert.same({
				"Attic (zone; no lights)",
				"Garage (room; 1 light) (unbound; device 2003)",
				"Living Room (room; 2 lights)" .. deleted(T0 + 100),
				"Downstairs (zone; 2 lights) (deleted in Hue; device 2001)",
			}, Z:list_items())
			assert.equal("1 zone, 2 rooms on bridge; 2 imported, 1 missing, 1 unbound, 1 deleted", Z:summary())
		end)

		it("reads the registry alone before the groups are fetched", function()
			add_downstairs()
			Z = new_zone_lights({ lights = lights.new({ http = http_ctx }) })
			Z:load()
			assert.is_false(Z:groups_loaded())
			assert.same({ "Downstairs (zone; 2 lights) → device 2001" }, Z:list_items())
		end)

		it("turns commas in names into U+201A so Composer keeps one line per group", function()
			L:absorb({ room = decode_data(F.room), bridge_home = decode_data(F.bridge_home),
				zone = decode_data(F.zone:gsub('"name":"Downstairs"', '"name":"Down, stairs"')) })
			local items = Z:list_items()
			assert.equal("Down‚ stairs (zone; 2 lights)", items[2])
			assert.equal(4, #items)
			no_commas(items)
		end)
	end)

	-- Issue #58 (docs/zone-light-design.md Decision 7): the bridge clamps a
	-- zone light's PUTs to the members' common colour temperature range too.
	describe("limits (issue #58)", function()
		it("gives the group queue the members' intersected CT range, exactly as the device's CONFIGURE", function()
			add_downstairs()
			Z:add(LIVING, nil, done)
			Z:add(GARAGE, GARAGE_ROOM, done)
			-- Downstairs: Garage White (white) and Living Room Lamp (153-500).
			assert.same({ min_dim = 1, mirek_min = 153, mirek_max = 500 }, Z:limits(G_DOWNSTAIRS))
			-- Living Room: Hallway Ambiance (153-454) and Living Room Lamp (153-500).
			assert.same({ min_dim = 1, mirek_min = 153, mirek_max = 454 }, Z:limits(G_LIVING))
			for id, grouped in pairs({ [2001] = G_DOWNSTAIRS, [2002] = G_LIVING, [2003] = G_GARAGE }) do
				local configure = sent_to(id, "HUE_CONFIGURE")[1].params
				local limits = Z:limits(grouped)
				assert.equal(configure.mirek_min, limits.mirek_min and tostring(limits.mirek_min), id)
				assert.equal(configure.mirek_max, limits.mirek_max and tostring(limits.mirek_max), id)
				assert.equal(configure.min_dim, tostring(limits.min_dim), id)
			end
			-- Garage: Garage White alone, no CT member: no range, the queue keeps its defaults.
			assert.same({ min_dim = 1 }, Z:limits(G_GARAGE))
			assert.are_not.equal(Z:limits(G_LIVING), Z:limits(G_LIVING), "a fresh table each call")
		end)

		it("is nil for a grouped_light no zone light owns, or a group whose members are unknown", function()
			add_downstairs()
			assert.is_nil(Z:limits(G_LIVING), "the Living Room has no zone light")
			assert.is_nil(Z:limits(F.grouped_light_rids.home))
			assert.is_nil(Z:limits("nope"))
			assert.is_nil(Z:limits(nil))
			assert.is_nil(Z:limits(""))
			Z.registry[DOWNSTAIRS].caps = nil  -- adopted before its group was ever seen: nothing known of the members
			assert.is_nil(Z:limits(G_DOWNSTAIRS))
		end)

		it("follows the members: a membership change narrows the range", function()
			add_downstairs()
			feed(F.events.zone_children)  -- Hallway Ambiance (153-454) joins Downstairs
			assert.same({ min_dim = 1, mirek_min = 153, mirek_max = 454 }, Z:limits(G_DOWNSTAIRS))
			assert.equal("454", c4.sent[#c4.sent].params.mirek_max, "the CONFIGURE says the same")
		end)
	end)
end)
