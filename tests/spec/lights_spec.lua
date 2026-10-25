local json = require("dkjson")
local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_resources")

-- Device ids after import_all(): Import All New Lights creates the three
-- lights with a mapped Hue room in name order (Garage White into Garage,
-- Hallway Ambiance and Living Room Lamp into Living Room); Kitchen Strip is in
-- no Hue room and is added by hand into Living Room.
local ID = { garage = 2001, hallway = 2002, living = 2003, kitchen = 2004 }
local GARAGE_ROOM, LIVING_ROOM = 8, 7

-- A replacement bulb for Garage White: a new rid on the same device (same MAC).
local REPLACED = "9a8b7c6d-5e4f-4a3b-2c1d-0e9f8a7b6c99"
local NEW_BULB = "ffffffff-0000-4000-8000-00000000new1"

local T0 = 1761000000

describe("bridge.lights", function()
	local lights, http, c4, L, results, logged, now

	-- The driver's http wrapper: adds ip and key and calls bridge.http.
	local function http_ctx(req, cb)
		req.ip = "192.0.2.10"
		req.key = "k"
		return http.request(req, cb)
	end

	-- The light fixture reduced to the given keys (fixture order kept).
	local function lights_json(keys)
		local keep = {}
		for _, key in ipairs(keys) do keep[F.rids[key]] = true end
		local doc = json.decode(F.light)
		local data = {}
		for _, item in ipairs(doc.data) do
			if keep[item.id] then data[#data + 1] = item end
		end
		doc.data = data
		return json.encode(doc)
	end

	local function saw_log(text)
		for _, line in ipairs(logged) do
			if line:find(text, 1, true) then return true end
		end
		return false
	end

	local function log_index(text)
		for i, line in ipairs(logged) do
			if line:find(text, 1, true) then return i end
		end
		return nil
	end

	local function new_lights(extra)
		local ctx = { http = http_ctx, now = function() return now end }
		for k, v in pairs(extra or {}) do ctx[k] = v end
		return lights.new(ctx)
	end

	local function done(ok, text)
		table.insert(results, { ok = ok, text = text })
	end

	local function last_result()
		return results[#results] or {}
	end

	-- Answer the six serial GETs with the fixtures (or overrides by kind).
	local function answer_gets(overrides)
		overrides = overrides or {}
		local bodies = {
			light = overrides.light or F.light,
			device = overrides.device or F.device,
			zigbee = overrides.zigbee or F.zigbee_connectivity,
			room = overrides.room or F.room,
			zone = overrides.zone or F.zone,
			bridge_home = overrides.bridge_home or F.bridge_home,
		}
		for _, kind in ipairs({ "light", "device", "zigbee", "room", "zone", "bridge_home" }) do
			local t = c4.last_transfer()
			assert.truthy(t, "expected a GET for " .. kind)
			assert.equal("GET", t.method)
			t:respond(200, bodies[kind])
		end
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

	local function saves()
		local n = 0
		for _, args in ipairs(c4.calls_to("PersistSetValue")) do
			if args[1] == "hue_lights" then n = n + 1 end
		end
		return n
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

	-- Import All New Lights (three lights land, Kitchen Strip has no room), then
	-- Add Light puts Kitchen Strip into Living Room.
	local function import_all()
		L:import_new(done)
		answer_gets()
		L:add_light(F.rids.kitchen, LIVING_ROOM, done)
	end

	local function resync(overrides)
		L:resync(done)
		answer_gets(overrides)
	end

	-- Plain-text replacement: rids contain "-", a pattern quantifier.
	local function replace(text, from, to)
		local escaped = from:gsub("%W", "%%%0")
		return (text:gsub(escaped, (to:gsub("%%", "%%%%"))))
	end

	-- The room fixture with one device moved from Living Room to Garage.
	local function rooms_moved(device_rid)
		local doc = json.decode(F.room)
		for _, room in ipairs(doc.data) do
			local kept = {}
			for _, child in ipairs(room.children) do
				if child.rid ~= device_rid then kept[#kept + 1] = child end
			end
			if room.id == F.group_rids.garage then kept[#kept + 1] = { rid = device_rid, rtype = "device" } end
			room.children = kept
		end
		return json.encode(doc)
	end

	-- Garage White deleted and re-added in the Hue app: a new rid on the same device.
	local function replaced_bulb()
		return { light = replace(F.light, F.rids.garage, REPLACED), device = replace(F.device, F.rids.garage, REPLACED) }
	end

	local function container(text)
		return C4:JsonDecode(text)[1]
	end

	-- The AddDevice callback's info table exactly as OS 3.4.2 passed it for a
	-- hue_light device (deviceId was 1036, the protocol id).
	local function os342_info()
		return {
			Name = "devices", Value = "", Attributes = {},
			ChildNodes = {
				{ Name = "protocol", Value = "1036", Attributes = {}, ChildNodes = {} },
				{ Name = "proxy", Value = "1037", Attributes = {}, ChildNodes = {} },
			},
		}
	end

	before_each(function()
		logged = {}
		log.sink = function(line) table.insert(logged, line) end
		log.set_debug(true)
		now = T0
		c4 = fake.install_c4()
		fake.add_room(GARAGE_ROOM, "Garage")
		for _, m in ipairs({ "bridge.http", "bridge.hue_model", "bridge.registry", "bridge.groups", "bridge.lights" }) do
			package.loaded[m] = nil
		end
		http = require("bridge.http")
		lights = require("bridge.lights")
		results = {}
		L = new_lights()
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("ids_from", function()
		it("reads the protocol and proxy ids from the OS 3.4.2 parsed-XML node tree", function()
			assert.same({ protocol = 1036, proxy = 1037 }, lights.ids_from(os342_info()))
			assert.equal(1036, lights.ids_from(os342_info()).protocol)
		end)

		it("matches node names case-insensitively and accepts numeric Values", function()
			local info = { Name = "Devices", ChildNodes = {
				{ Name = "Protocol", Value = 42 },
				{ Name = "PROXY", Value = "43", ChildNodes = {} },
			} }
			assert.same({ protocol = 42, proxy = 43 }, lights.ids_from(info))
		end)

		it("falls back to a key naming the protocol for the old flat shape", function()
			assert.same({ protocol = 3002 }, lights.ids_from({ protocolId = 3002, proxyIds = { 3001 } }))
			assert.equal(3002, lights.ids_from({ protocolId = 3002, proxyIds = { 3001 } }).protocol)
			assert.same({ protocol = 5, proxy = 6 }, lights.ids_from({ ids = { protocol_id = "5", proxy_id = "6" } }))
		end)

		it("returns nothing for an empty table, nil or a non-table", function()
			assert.same({}, lights.ids_from({}))
			assert.same({}, lights.ids_from(nil))
			assert.same({}, lights.ids_from("1036"))
			assert.same({}, lights.ids_from({ Name = "protocol", Value = "0" }), "ids must be positive")
			assert.is_nil(lights.ids_from(nil).protocol)
		end)
	end)

	describe("import_new", function()
		it("runs the six GETs one at a time with the key, adding nothing before all are in", function()
			assert.is_true(L:import_new(done))
			local paths = { "light", "device", "zigbee_connectivity", "room", "zone", "bridge_home" }
			for i, path in ipairs(paths) do
				assert.equal(i, #c4.transfers)
				assert.equal("https://192.0.2.10/clip/v2/resource/" .. path, c4.transfers[i].url)
				assert.equal("k", c4.transfers[i].headers["hue-application-key"])
				assert.equal(0, #c4.added, "no AddDevice before all six GETs are in")
				c4.transfers[i]:respond(200, ({ F.light, F.device, F.zigbee_connectivity, F.room, F.zone, F.bridge_home })[i])
			end
			assert.equal(6, #c4.transfers)
			assert.equal(3, #c4.added)
		end)

		it("creates the lights with a mapped Hue room in name order, in the mapped room, and lists the skipped", function()
			L:import_new(done)
			answer_gets()
			assert.equal(3, #c4.added)
			assert.same({ "Garage White", "Hallway Ambiance", "Living Room Lamp" },
				{ c4.added[1].name, c4.added[2].name, c4.added[3].name })
			assert.same({ GARAGE_ROOM, LIVING_ROOM, LIVING_ROOM }, { c4.added[1].room, c4.added[2].room, c4.added[3].room })
			assert.same({ 2001, 2002, 2003 }, { c4.added[1].id, c4.added[2].id, c4.added[3].id })
			assert.equal("hue_light.c4z", c4.added[1].driver)
			assert.same({ ok = true, text = "Added 3 new lights: Garage White #4 to Garage (device 2001), "
				.. "Hallway Ambiance #3 to Living Room (device 2002), Living Room Lamp #1 to Living Room (device 2003); "
				.. "skipped 1 with no mapped room (Set Room Mapping or Add Light): Kitchen Strip #2 (no Hue room)" },
				last_result())
			assert.equal("4 on bridge, 3 imported, 1 new, 0 missing, 0 unbound, 0 deleted", L:summary())
			assert.is_true(saw_log("one-time Map Rooms By Name"))
		end)

		it("binds each new light to the bridge with the HUE_BRIDGE class", function()
			import_all()
			local binds = c4.calls_to("Bind")
			assert.equal(4, #binds)
			for i = 1, 4 do
				assert.same({ 15, 1, 2000 + i, 1, "HUE_BRIDGE" }, binds[i])
			end
		end)

		it("persists v2 entries: identity, MAC, Hue room, state and creation fields", function()
			import_all()
			local stored = c4.persist.hue_lights
			assert.truthy(stored)
			assert.same({
				device_id = ID.garage, name = "Garage White", device_name = "Garage White", model = "Hue white lamp",
				caps = { has_color = false, has_cct = false, min_dim = 5 },
				device_rid = F.device_rids.garage, mac_address = "00:17:88:01:0b:12:34:04-0b", service_id = 0,
				id_v1 = "/lights/4", hue_room_rid = F.group_rids.garage, hue_room = "Garage",
				state = "linked", created_room_id = GARAGE_ROOM, created_at = T0,
			}, stored[F.rids.garage])
			assert.same({
				device_id = ID.kitchen, name = "Kitchen Strip", device_name = "Kitchen Strip", model = "Hue lightstrip plus",
				caps = { has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 0.39 },
				device_rid = F.device_rids.kitchen, mac_address = "00:17:88:01:0b:12:34:02-0b", service_id = 0,
				id_v1 = "/lights/2", state = "linked", created_room_id = LIVING_ROOM, created_at = T0,
			}, stored[F.rids.kitchen], "no Hue room: no hue_room fields")
			assert.equal(4, L:count())
			assert.equal(ID.kitchen, L:device_for(F.rids.kitchen))
			assert.equal(F.rids.kitchen, L:rid_for(ID.kitchen))
			assert.is_nil(L:device_for("nope"))
			assert.same({ [F.group_rids.living_room] = { c4_room_id = LIVING_ROOM, c4_room_name = "Living Room",
				hue_name = "Living Room", type = "room" }, [F.group_rids.garage] = { c4_room_id = GARAGE_ROOM,
				c4_room_name = "Garage", hue_name = "Garage", type = "room" } }, c4.persist.hue_rooms)
			assert.equal("done", c4.persist.hue_rooms_automapped)
		end)

		it("sends HUE_CONFIGURE with hue_room and id_v1, then a full HUE_STATE, to each new light", function()
			import_all()
			assert.same({
				"HUE_CONFIGURE@2001", "HUE_STATE@2001",
				"HUE_CONFIGURE@2002", "HUE_STATE@2002",
				"HUE_CONFIGURE@2003", "HUE_STATE@2003",
				"HUE_CONFIGURE@2004", "HUE_STATE@2004",
			}, commands_sent())
			assert.same({ rid = F.rids.living, name = "Living Room Lamp", model = "Hue color lamp",
				has_color = "true", has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "0.2",
				hue_room = "Living Room", id_v1 = "/lights/1" }, sent_to(ID.living, "HUE_CONFIGURE")[1].params)
			assert.same({ rid = F.rids.living, reason = "resync", on = "true", brightness = "73.52",
				x = "0.4575", y = "0.4101", mirek = "366", color_mode = "ct", online = "true" },
				sent_to(ID.living, "HUE_STATE")[1].params)
			-- Garage White has a connectivity issue: offline, and no colour fields.
			assert.same({ rid = F.rids.garage, reason = "resync", on = "false", brightness = "100", online = "false" },
				sent_to(ID.garage, "HUE_STATE")[1].params)
			-- Kitchen Strip is in no room: no hue_room param at all.
			assert.is_nil(sent_to(ID.kitchen, "HUE_CONFIGURE")[1].params.hue_room)
			assert.equal("/lights/2", sent_to(ID.kitchen, "HUE_CONFIGURE")[1].params.id_v1)
		end)

		it("names a device after its Hue device, or after the light on a multi-light device", function()
			-- The Garage device is called differently from its light; the Living
			-- Room device owns two lights (its own and Hallway Ambiance).
			local device = replace(F.device, '"metadata":{"name":"Garage White"', '"metadata":{"name":"Garage Device"')
			device = replace(device, '{"rid":"' .. F.rids.living .. '","rtype":"light"}',
				'{"rid":"' .. F.rids.living .. '","rtype":"light"},{"rid":"' .. F.rids.hallway .. '","rtype":"light"}')
			local light = replace(F.light, F.device_rids.hallway, F.device_rids.living)
			L:import_new(done)
			answer_gets({ light = light, device = device })
			assert.same({ "Garage Device", "Hallway Ambiance", "Living Room Lamp" },
				{ c4.added[1].name, c4.added[2].name, c4.added[3].name })
			assert.equal("Garage White", L.registry[F.rids.garage].name, "the registry keeps the light's name")
			assert.equal("Garage Device", L.registry[F.rids.garage].device_name)
			assert.equal("Living Room Lamp", L.registry[F.rids.hallway].device_name, "owned by the two-light device")
			assert.equal("Hue color lamp", L.registry[F.rids.hallway].model)
		end)

		it("logs the first AddDevice callback's info table once", function()
			import_all()
			local dumps = {}
			for _, line in ipairs(logged) do
				if line:find("AddDevice callback", 1, true) then dumps[#dumps + 1] = line end
			end
			assert.equal(1, #dumps)
			assert.truthy(dumps[1]:find("deviceId=2001 info={}", 1, true), dumps[1])
		end)

		it("is idempotent by rid: a second import after a restart adds nothing", function()
			import_all()
			local persisted = c4.persist.hue_lights
			c4.sent, c4.added, c4.calls = {}, {}, {}

			L = new_lights()
			L:load()
			assert.equal(4, L:count())
			L:import_new(done)
			answer_gets()
			assert.equal(0, #c4.added)
			assert.equal(0, #c4.calls_to("Bind"))
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.same({ ok = true, text = "No new lights on the bridge (4 on bridge, 4 imported)" }, last_result())
			assert.same(persisted, c4.persist.hue_lights)
			-- Registered lights get CONFIGURE + STATE again (a fresh instance), in name order.
			assert.same({
				"HUE_CONFIGURE@2001", "HUE_STATE@2001",
				"HUE_CONFIGURE@2002", "HUE_STATE@2002",
				"HUE_CONFIGURE@2004", "HUE_STATE@2004",
				"HUE_CONFIGURE@2003", "HUE_STATE@2003",
			}, commands_sent())
		end)

		it("adds only the lights that are new since the last import", function()
			L:import_new(done)
			answer_gets({ light = lights_json({ "living", "garage" }) })
			assert.equal(2, #c4.added)
			assert.truthy(last_result().text:find("^Added 2 new lights: Garage White #4 to Garage %(device 2001%), "
				.. "Living Room Lamp #1 to Living Room %(device 2002%)$"))

			c4.added = {}
			L:import_new(done)
			answer_gets()
			assert.equal(1, #c4.added)
			assert.equal("Hallway Ambiance", c4.added[1].name)
			assert.equal(2003, c4.added[1].id)
			assert.equal("Added 1 new light: Hallway Ambiance #3 to Living Room (device 2003); skipped 1 with no mapped room "
				.. "(Set Room Mapping or Add Light): Kitchen Strip #2 (no Hue room)", last_result().text)
		end)

		it("skips lights whose Hue room is unmapped or mapped to a room that no longer exists", function()
			c4.persist.hue_rooms_automapped = "done"  -- no automatic mapping this time
			c4.persist.hue_rooms = { [F.group_rids.garage] = { c4_room_id = 99, c4_room_name = "Shed", type = "room",
				hue_name = "Garage" } }
			L:load()
			L:import_new(done)
			answer_gets()
			assert.equal(0, #c4.added)
			assert.same({ ok = true, text = "Added no lights; skipped 4 with no mapped room (Set Room Mapping or Add Light): "
				.. "Garage White #4 (Hue room Garage mapped to a Control4 room that no longer exists), "
				.. "Hallway Ambiance #3 (Hue room Living Room not mapped), Kitchen Strip #2 (no Hue room), "
				.. "Living Room Lamp #1 (Hue room Living Room not mapped)" }, last_result())
		end)

		it("stops and reports when a GET fails", function()
			L:import_new(done)
			c4.transfers[1]:respond(401, F.unauthorized)
			assert.equal(1, #c4.transfers)
			assert.equal(0, #c4.added)
			assert.same({ ok = false, text = "Import failed: GET /clip/v2/resource/light: HTTP 401" }, last_result())
			assert.is_false(L.importing)

			-- A transfer error on the second GET.
			L:import_new(done)
			c4.transfers[2]:respond(200, F.light)
			c4.transfers[3]:done(28, "Connection timed out")
			assert.equal(3, #c4.transfers)
			assert.truthy(last_result().text:find("^Import failed: GET /clip/v2/resource/device: transfer failed %(28%)"))
			assert.is_true(L:import_new(done), "a failed import releases the guard")
		end)

		it("refuses a second import, an add and a re-link while one is running", function()
			assert.is_true(L:import_new(done))
			assert.is_false(L:import_new(done))
			assert.same({ ok = false, text = "Busy: importing; try again in a moment" }, last_result())
			assert.is_false(L:add_light(F.rids.kitchen, LIVING_ROOM, done))
			assert.equal("Busy: importing; try again in a moment", last_result().text)
			assert.same({ false, "Busy: importing; try again in a moment" }, { L:relink(2001, F.rids.kitchen) })
			assert.equal(1, #c4.transfers)
			answer_gets()
			assert.equal(3, #c4.added)
			assert.is_true(L:import_new(done), "accepted again once finished")
		end)

		it("skips a light whose AddDevice fails and carries on", function()
			local calls = 0
			L = new_lights({
				add_device = function(driver, room, name, cb)
					calls = calls + 1
					if name == "Hallway Ambiance" then
						cb(0, {})
					else
						C4:AddDevice(driver, room, name, cb)
					end
				end,
			})
			L:import_new(done)
			answer_gets()
			assert.equal(3, calls)
			assert.equal(2, #c4.added)
			assert.equal(2, L:count())
			assert.is_nil(L:device_for(F.rids.hallway))
			assert.is_false(last_result().ok)
			assert.truthy(last_result().text:find("; AddDevice failed for 1: Hallway Ambiance #3; ", 1, true))
		end)

		it("binds the protocol id when the callback info exposes one", function()
			L = new_lights({
				add_device = function(_, _, _, cb)
					cb(3001, { proxyIds = { 3001 }, protocolId = 3002 })
				end,
			})
			L:import_new(done)
			answer_gets({ light = lights_json({ "living" }) })
			assert.same({ { 15, 1, 3002, 1, "HUE_BRIDGE" } }, c4.calls_to("Bind"))
			assert.is_true(saw_log("binding protocol id 3002 rather than deviceId 3001"))
			assert.equal(3002, L:device_for(F.rids.living))
			assert.is_nil(L:proxy_for(F.rids.living))
		end)

		it("binds the protocol id and keeps the proxy id from the OS 3.4.2 callback shape", function()
			L = new_lights({
				add_device = function(_, _, _, cb)
					cb(1036, os342_info())
				end,
			})
			L:import_new(done)
			answer_gets({ light = lights_json({ "living" }) })
			assert.same({ { 15, 1, 1036, 1, "HUE_BRIDGE" } }, c4.calls_to("Bind"))
			assert.is_false(saw_log("rather than deviceId"), "deviceId already is the protocol id")
			assert.equal(1036, L:device_for(F.rids.living))
			assert.equal(F.rids.living, L:rid_for(1036))
			assert.equal(1037, L:proxy_for(F.rids.living))
			assert.same({ "HUE_CONFIGURE@1036", "HUE_STATE@1036" }, commands_sent())

			-- Persisted, and back after a reload from the store.
			assert.equal(1037, c4.persist.hue_lights[F.rids.living].proxy_id)
			L = new_lights()
			L:load()
			assert.equal(1036, L:device_for(F.rids.living))
			assert.equal(1037, L:proxy_for(F.rids.living))
			assert.is_nil(L:proxy_for("nope"))
			assert.is_nil(L:proxy_for(nil))
		end)

		it("gives a copy of the registry entry", function()
			L = new_lights({
				add_device = function(_, _, _, cb)
					cb(1036, os342_info())
				end,
			})
			L:import_new(done)
			answer_gets({ light = lights_json({ "living" }) })
			local entry = L:entry(F.rids.living)
			assert.equal(1036, entry.device_id)
			assert.equal(1037, entry.proxy_id)
			assert.equal("Living Room Lamp", entry.name)
			assert.equal("linked", entry.state)
			assert.same({ has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 0.2 }, entry.caps)
			entry.device_id, entry.caps.min_dim = 1, 99
			assert.equal(1036, L:device_for(F.rids.living))
			assert.equal(0.2, L.registry[F.rids.living].caps.min_dim)
			assert.is_nil(L:entry("nope"))
			assert.is_nil(L:entry(nil))
		end)

		it("logs a Hue rename and refreshes the registry name, never the Composer name", function()
			import_all()
			L:import_new(done)
			answer_gets({ light = F.light:gsub("Garage White", "Garage Lamp") })
			assert.is_true(saw_log("Garage White was renamed to Garage Lamp in Hue"))
			assert.equal("Garage Lamp", c4.persist.hue_lights[F.rids.garage].name)
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.equal("Garage White", c4:GetDeviceDisplayName(ID.garage))
		end)
	end)

	describe("add_light", function()
		it("adds one light into the chosen room and reports it", function()
			L:import_new(done)
			answer_gets()
			c4.sent = {}
			assert.is_true(L:add_light(F.rids.kitchen, LIVING_ROOM, done))
			assert.same({ ok = true, text = "Added Kitchen Strip #2 to Living Room (device 2004)" }, last_result())
			assert.equal(LIVING_ROOM, c4.added[4].room)
			assert.same({ "HUE_CONFIGURE@2004", "HUE_STATE@2004" }, commands_sent())
			assert.equal(LIVING_ROOM, L.registry[F.rids.kitchen].created_room_id)
			assert.equal("4 on bridge, 4 imported, 0 new, 0 missing, 0 unbound, 0 deleted", L:summary())
		end)

		it("defaults to the mapped room of the light's Hue room", function()
			resync()
			L:add_light(F.rids.garage, nil, done)
			assert.same({ ok = true, text = "Added Garage White #4 to Garage (device 2001)" }, last_result())
			assert.equal(GARAGE_ROOM, c4.added[1].room)
		end)

		it("refuses when the light has no mapped room and none was chosen [Q 9]", function()
			resync()
			L:add_light(F.rids.kitchen, nil, done)
			assert.same({ ok = false,
				text = "Not added: Kitchen Strip #2: no Hue room; pick a room, or Set Room Mapping first" }, last_result())
			L:set_room_mapping(F.group_rids.garage, nil)
			L:add_light(F.rids.garage, nil, done)
			assert.equal("Not added: Garage White #4: Hue room Garage not mapped; pick a room, or Set Room Mapping first",
				last_result().text)
			L:set_room_mapping(F.group_rids.garage, GARAGE_ROOM)
			fake.delete_room(GARAGE_ROOM)
			L:add_light(F.rids.garage, nil, done)
			assert.equal("Not added: Garage White #4: Hue room Garage mapped to a Control4 room that no longer exists; "
				.. "pick a room, or Set Room Mapping first", last_result().text)
			assert.equal(0, #c4.added)
		end)

		it("refuses an empty or unknown light, an imported light and a room that no longer exists", function()
			import_all()
			c4.added = {}
			L:add_light("", LIVING_ROOM, done)
			assert.equal("Not added: pick a light first", last_result().text)
			L:add_light(nil, LIVING_ROOM, done)
			assert.equal("Not added: pick a light first", last_result().text)
			L:add_light("nope", LIVING_ROOM, done)
			assert.equal("Not added: light nope is not on the bridge (connect the event stream and try again)",
				last_result().text)
			L:add_light(F.rids.garage, LIVING_ROOM, done)
			assert.equal("Not added: Garage White #4 is already imported (device 2001)", last_result().text)
			L:forget(ID.garage)
			L:add_light(F.rids.garage, 99, done)
			assert.equal("Not added: Control4 room 99 no longer exists", last_result().text)
			assert.equal(0, #c4.added)
		end)

		it("is refused while a resync runs", function()
			import_all()
			L:resync(done)
			assert.is_false(L:add_light(F.rids.garage, LIVING_ROOM, done))
			assert.equal("Busy: resyncing; try again in a moment", last_result().text)
			answer_gets()
		end)
	end)

	describe("resync", function()
		it("sends CONFIGURE then full STATE the first time, STATE only after that", function()
			import_all()
			L = new_lights()
			L:load()
			c4.sent = {}
			resync()
			assert.same({ ok = true, text = nil }, last_result())
			assert.same({
				"HUE_CONFIGURE@2001", "HUE_STATE@2001",
				"HUE_CONFIGURE@2002", "HUE_STATE@2002",
				"HUE_CONFIGURE@2004", "HUE_STATE@2004",
				"HUE_CONFIGURE@2003", "HUE_STATE@2003",
			}, commands_sent(), "name order: Kitchen Strip before Living Room Lamp")
			assert.equal("resync", c4.sent[2].params.reason)

			c4.sent = {}
			resync()
			assert.same({ "HUE_STATE@2001", "HUE_STATE@2002", "HUE_STATE@2004", "HUE_STATE@2003" }, commands_sent())

			-- The lights an import just created were configured by it.
			c4.sent = {}
			L:import_new(done)
			answer_gets()
			assert.same({ "HUE_STATE@2001", "HUE_STATE@2002", "HUE_STATE@2004", "HUE_STATE@2003" }, commands_sent())
		end)

		it("reports the number of lights told", function()
			import_all()
			local got = {}
			L:resync(function(...) got = { ... } end)
			answer_gets()
			assert.same({ true, nil, 4 }, got)
		end)

		it("works from the persisted registry after a restart and refreshes the caps", function()
			import_all()
			c4.persist.hue_lights[F.rids.hallway].caps.mirek_max = 400 -- stale, as if the bulb's firmware changed
			L = new_lights()
			L:load()
			c4.sent = {}
			resync()
			assert.equal(8, #c4.sent)
			assert.equal("454", sent_to(ID.hallway, "HUE_CONFIGURE")[1].params.mirek_max)
			assert.equal(454, c4.persist.hue_lights[F.rids.hallway].caps.mirek_max)
		end)

		it("sends CONFIGURE again only to a light whose configuration changed (a Hue room move)", function()
			import_all()
			c4.sent = {}
			-- Hallway Ambiance's device now lives in the Garage.
			resync({ room = rooms_moved(F.device_rids.hallway) })
			assert.same({ "HUE_STATE@2001", "HUE_CONFIGURE@2002", "HUE_STATE@2002", "HUE_STATE@2004", "HUE_STATE@2003" },
				commands_sent())
			assert.equal("Garage", sent_to(ID.hallway, "HUE_CONFIGURE")[1].params.hue_room)
			assert.equal(F.group_rids.garage, c4.persist.hue_lights[F.rids.hallway].hue_room_rid)
			assert.equal("Garage", c4.persist.hue_lights[F.rids.hallway].hue_room)
			assert.is_true(saw_log("Hallway Ambiance #3 is in Hue room Garage"))
		end)

		it("reports a failed GET without touching the lights", function()
			import_all()
			c4.sent = {}
			L:resync(done)
			c4.last_transfer():respond(503, "")
			assert.same({ ok = false, text = "GET /clip/v2/resource/light: HTTP 503" }, last_result())
			assert.equal(0, #c4.sent)
		end)

		it("runs once more when asked again while running, and waits for an import", function()
			import_all()
			local got = {}
			L:resync(function(ok) table.insert(got, ok) end)
			L:resync(function(ok) table.insert(got, ok) end)
			assert.equal(7, #c4.transfers, "the second resync waits")
			answer_gets()
			assert.same({ true }, got)
			assert.equal(13, #c4.transfers, "then runs")
			answer_gets()
			assert.same({ true, true }, got)

			L:import_new(done)
			L:resync(function(ok) table.insert(got, ok) end)
			assert.equal(19, #c4.transfers, "a resync waits for the import")
			answer_gets()
			assert.equal(25, #c4.transfers, "and runs after it")
			answer_gets()
			assert.same({ true, true, true }, got)
		end)

		it("marks a registered light gone when a full GET lacks it, tells the device, and links it again when back",
			function()
			import_all()
			c4.sent = {}
			now = T0 + 60
			resync({ light = lights_json({ "living", "kitchen", "hallway" }) })
			local garage = L.registry[F.rids.garage]
			assert.equal("gone", garage.state)
			assert.equal(T0 + 60, garage.gone_since)
			assert.equal("gone", c4.persist.hue_lights[F.rids.garage].state)
			assert.equal(ID.garage, L:device_for(F.rids.garage), "the device is kept")
			assert.is_true(saw_log("Garage White #4 (device 2001) is no longer on the bridge; marked gone"))
			local configure = sent_to(ID.garage, "HUE_CONFIGURE")
			assert.equal(1, #configure)
			assert.equal("gone", configure[1].params.state)
			assert.equal(tostring(T0 + 60), configure[1].params.gone_since)
			assert.equal("Garage", configure[1].params.hue_room)
			assert.same({ { rid = F.rids.garage, online = "false", reason = "resync" } },
				{ sent_to(ID.garage, "HUE_STATE")[1].params })
			assert.equal(1, #sent_to(ID.garage, "HUE_STATE"), "no full state for a light that is not there")
			assert.equal("3 on bridge, 4 imported, 0 new, 1 missing, 0 unbound, 0 deleted", L:summary())
			assert.equal("1 light missing from the bridge: Garage White #4 (device 2001, since " .. os.date("%Y-%m-%d", T0 + 60)
				.. ") (Re-link Device To Light or Forget Light)", L:attention())
			assert.same({ "Garage White (device 2001, gone since " .. os.date("%m-%d", T0 + 60) .. ")" },
				texts(L:picker_relink_devices()))
			assert.same({ "2001" }, values(L:picker_relink_devices()))

			-- The same GET again: nothing new is said.
			c4.sent = {}
			resync({ light = lights_json({ "living", "kitchen", "hallway" }) })
			assert.equal(0, #sent_to(ID.garage))

			-- Back on the bridge: linked, configured without the gone state, full state.
			c4.sent = {}
			resync()
			assert.equal("linked", L.registry[F.rids.garage].state)
			assert.is_nil(L.registry[F.rids.garage].gone_since)
			assert.is_true(saw_log("Garage White #4 (device 2001) is back on the bridge"))
			assert.is_nil(sent_to(ID.garage, "HUE_CONFIGURE")[1].params.state)
			assert.equal("false", sent_to(ID.garage, "HUE_STATE")[1].params.on)
			assert.equal("None", L:attention())
		end)

		it("lists a new light with a re-link hint when a gone entry shares its MAC or its name", function()
			import_all()
			resync({ light = lights_json({ "living", "kitchen", "hallway" }) })
			-- Garage White was deleted and re-added in the Hue app: new rid, same radio.
			logged = {}
			resync(replaced_bulb())
			assert.equal("4 on bridge, 4 imported, 1 new, 1 missing, 0 unbound, 0 deleted", L:summary())
			assert.is_true(saw_log("new light Garage White [Garage] #4 on the bridge; use Add Light or Import All New Lights; "
				.. "it looks like Garage White #4 (device 2001): re-link?"))
			assert.same({ "Garage White [Garage] #4 (looks like Garage White #4, device 2001; re-link?)" },
				texts(L:picker_lights()))
			assert.same({ REPLACED }, values(L:picker_lights()))
			assert.truthy(L:attention():find("^1 new light on the bridge: Garage White %[Garage%] #4 %(looks like Garage White "
				.. "#4, device 2001; re%-link%?%) %(Add Light or Import All New Lights%); 1 light missing"))

			-- Logged once, however many resyncs see it.
			logged = {}
			resync(replaced_bulb())
			assert.is_false(saw_log("new light"))

			-- A different radio but the same name still hints.
			L.registry[F.rids.garage].mac_address = "00:17:88:01:0b:12:34:ff-0b"
			assert.same({ "Garage White [Garage] #4 (looks like Garage White #4, device 2001; re-link?)" },
				texts(L:picker_lights()))
			L.registry[F.rids.garage].name = "Other"
			assert.same({ "Garage White [Garage] #4" }, texts(L:picker_lights()))
		end)

		it("runs Map Rooms By Name once, at the first resync that knows the rooms, guarded by a persisted flag", function()
			assert.is_nil(c4.persist.hue_rooms)
			resync()
			assert.equal("done", c4.persist.hue_rooms_automapped)
			assert.equal("Garage → Garage; Living Room → Living Room; Attic (zone) → (unmapped); "
				.. "Downstairs (zone) → (unmapped)", L:room_mappings_text())
			assert.is_true(saw_log("one-time Map Rooms By Name at the first resync of this build: Mapped 2: "
				.. "Garage → Garage, Living Room → Living Room; no Control4 room named: Attic (zone), Downstairs (zone)"))

			-- Removed by the owner: the next resync leaves it alone.
			L:set_room_mapping(F.group_rids.garage, nil)
			logged = {}
			resync()
			assert.is_false(saw_log("one-time Map Rooms By Name"))
			assert.equal("Garage → (unmapped); Living Room → Living Room; Attic (zone) → (unmapped); "
				.. "Downstairs (zone) → (unmapped)", L:room_mappings_text())

			-- A project whose room list is unknown postpones the run instead of using it up.
			c4 = fake.install_c4()
			L = new_lights({ project = { rooms = function() return {} end } })
			resync()
			assert.is_nil(c4.persist.hue_rooms_automapped)
		end)

		it("reconciles in the contract's order: project, lights, rooms, then the state fan-out", function()
			import_all()
			-- Hallway Ambiance was deleted in Composer while the bridge was down,
			-- Garage White left the bridge, and Living Room Lamp's device moved to the Garage.
			fake.delete_device(ID.hallway)
			logged, c4.sent = {}, {}
			resync({ light = lights_json({ "living", "kitchen" }), room = rooms_moved(F.device_rids.living) })
			local step1 = log_index("Hallway Ambiance was deleted in Composer while the bridge was not watching")
			local step2 = log_index("Garage White #4 (device 2001) is no longer on the bridge")
			local step3 = log_index("Living Room Lamp #1 is in Hue room Garage")
			assert.truthy(step1 and step2 and step3, table.concat(logged, "\n"))
			assert.is_true(step1 < step2 and step2 < step3)
			assert.is_nil(L.registry[F.rids.hallway])
			assert.truthy(c4.persist.hue_tombstones[F.rids.hallway])
			assert.equal("gone", L.registry[F.rids.garage].state)
			-- The gone light hears first (step 2), the fan-out last (step 5).
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001", "HUE_STATE@2004", "HUE_CONFIGURE@2003", "HUE_STATE@2003" },
				commands_sent())
			assert.equal("Garage", sent_to(ID.living, "HUE_CONFIGURE")[1].params.hue_room)
			assert.equal("2 on bridge, 3 imported, 0 new, 1 missing, 0 unbound, 1 deleted", L:summary())
		end)
	end)

	describe("events", function()
		before_each(function()
			import_all()
			c4.sent = {}
		end)

		it("fans out only the changed fields of a light event with reason event", function()
			assert.equal(1, L:on_container(container(F.events.brightness)))
			assert.equal(1, #c4.sent)
			assert.equal(ID.living, c4.sent[1].id)
			assert.equal("HUE_STATE", c4.sent[1].command)
			assert.same({ rid = F.rids.living, brightness = "50", reason = "event" }, c4.sent[1].params)
		end)

		it("sends the colour fields with the derived mode", function()
			assert.equal(1, L:on_container(container(F.events.color)))
			assert.same({ rid = F.rids.living, x = "0.1532", y = "0.0475", color_mode = "xy", reason = "event" },
				c4.sent[1].params)
			assert.equal("xy", L.models[F.rids.living].color_mode)
		end)

		it("ignores items that are not registered lights, and junk", function()
			assert.equal(1, L:on_container(container(F.events.off)), "grouped_light item is skipped")
			assert.equal(ID.garage, c4.sent[1].id)
			assert.same({ rid = F.rids.garage, on = "false", reason = "event" }, c4.sent[1].params)
			assert.equal(0, L:on_container({ type = "update",
				data = { { id = "unknown", type = "light", on = { on = true } } } }))
			assert.equal(0, L:on_container({}))
			assert.equal(0, L:on_container(nil))
			assert.equal(1, #c4.sent)
		end)

		-- The zone lights derive a group's colour from the member lights' models,
		-- imported or not (docs/zone-light-design.md Decision 8).
		it("keeps the model of an unimported light current, telling nobody", function()
			L = new_lights()
			L:import_new(done)
			answer_gets()  -- Kitchen Strip stays unimported
			c4.sent = {}
			assert.is_nil(L:device_for(F.rids.kitchen))
			assert.equal(0, L:on_container({ type = "update", data = { { id = F.rids.kitchen, type = "light",
				on = { on = true }, dimming = { brightness = 42 }, color = { xy = { x = 0.2, y = 0.3 } } } } }))
			local model = L.models[F.rids.kitchen]
			assert.same({ true, 42, 0.2, 0.3, "xy" }, { model.on, model.brightness, model.x, model.y, model.color_mode })
			assert.equal(0, L:on_container({ type = "update", data = { { id = F.zigbee_rids.kitchen,
				type = "zigbee_connectivity", owner = { rid = F.device_rids.kitchen, rtype = "device" },
				status = "connectivity_issue" } } }))
			assert.is_false(L.models[F.rids.kitchen].online)
			assert.equal(0, L:on_container({ type = "update", data = { { id = F.rids.kitchen, type = "light",
				color_temperature = { mirek = 300, mirek_valid = true } } } }))
			assert.same({ 300, "ct" }, { L.models[F.rids.kitchen].mirek, L.models[F.rids.kitchen].color_mode })
			assert.equal(0, #c4.sent)
		end)

		it("sends nothing for an event that touches no reported field", function()
			assert.equal(0, L:on_container(container(F.events.noop)))
			assert.equal(0, #c4.sent)
		end)

		it("fans a zigbee_connectivity event out to the device's lights as online", function()
			assert.equal(1, L:on_container(container(F.events.connectivity)))
			assert.equal(ID.garage, c4.sent[1].id)
			assert.same({ rid = F.rids.garage, online = "true", reason = "event" }, c4.sent[1].params)
			assert.is_true(L.models[F.rids.garage].online)
		end)

		it("caches a new light from an add event and lists it, without creating anything", function()
			assert.equal(0, L:on_container(container(F.events.add)))
			assert.equal(0, #c4.sent)
			assert.equal(4, #c4.added)
			assert.equal("5 on bridge, 4 imported, 1 new, 0 missing, 0 unbound, 0 deleted", L:summary())
			assert.same({ { text = "New Bulb #5", value = NEW_BULB } }, L:picker_lights())
			assert.equal("1 new light on the bridge: New Bulb #5 (Add Light or Import All New Lights)", L:attention())
			assert.is_true(saw_log("new light New Bulb #5 on the bridge; use Add Light or Import All New Lights"))
			-- Again: idempotent, logged once.
			logged = {}
			assert.equal(0, L:on_container(container(F.events.add)))
			assert.is_false(saw_log("new light"))
			assert.equal(1, #L:picker_lights())
		end)

		it("marks a light gone at once on a delete event [Q 11] and tells the device", function()
			now = T0 + 5
			local del = { type = "delete", data = { { id = F.rids.garage, type = "light" } } }
			assert.equal(1, L:on_container(del))
			assert.equal("gone", L.registry[F.rids.garage].state)
			assert.equal("gone", c4.persist.hue_lights[F.rids.garage].state)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.equal("gone", c4.sent[1].params.state)
			assert.equal(tostring(T0 + 5), c4.sent[1].params.gone_since)
			assert.same({ rid = F.rids.garage, online = "false", reason = "event" }, c4.sent[2].params)
			assert.is_nil(L.models[F.rids.garage])
			assert.equal("3 on bridge, 4 imported, 0 new, 1 missing, 0 unbound, 0 deleted", L:summary())
			-- Idempotent.
			c4.sent = {}
			assert.equal(0, L:on_container(del))
			assert.equal(0, #c4.sent)
			-- An unimported light's delete is nothing to tell.
			assert.equal(0, L:on_container({ type = "delete", data = { { id = NEW_BULB, type = "light" } } }))

			-- Re-added in the Hue app with the same rid: an add event brings it back.
			local item = json.decode(lights_json({ "garage" })).data[1]
			assert.equal(1, L:on_container({ type = "add", data = { item } }))
			assert.equal("linked", L.registry[F.rids.garage].state)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.is_nil(c4.sent[1].params.state)
		end)

		it("moves a device between Hue rooms on a room update and re-configures the light", function()
			assert.equal(1, L:on_container(container(F.events.room_move)))
			assert.same({ "HUE_CONFIGURE@2002" }, commands_sent())
			assert.equal("Garage", c4.sent[1].params.hue_room)
			assert.equal(F.group_rids.garage, L.registry[F.rids.hallway].hue_room_rid)
			assert.equal(F.group_rids.garage, c4.persist.hue_lights[F.rids.hallway].hue_room_rid)
			assert.equal("Garage", c4.persist.hue_lights[F.rids.hallway].hue_room)
			-- Idempotent.
			c4.sent = {}
			assert.equal(0, L:on_container(container(F.events.room_move)))
			assert.equal(0, #c4.sent)
		end)

		it("renames a Hue room: the lights in it hear the new label and the mapping follows", function()
			assert.equal(2, L:on_container(container(F.events.room_rename)))
			assert.same({ "HUE_CONFIGURE@2002", "HUE_CONFIGURE@2003" }, commands_sent())
			assert.equal("Lounge", c4.sent[1].params.hue_room)
			assert.equal("Lounge", c4.persist.hue_rooms[F.group_rids.living_room].hue_name)
			assert.equal("Garage → Garage; Lounge → Living Room; Attic (zone) → (unmapped); "
				.. "Downstairs (zone) → (unmapped)", L:room_mappings_text())
		end)

		it("adds and deletes a zone without touching the lights", function()
			assert.equal(0, L:on_container(container(F.events.zone_add)))
			assert.same({ "Attic (zone) → (unmapped)", "Downstairs (zone) → (unmapped)", "Upstairs (zone) → (unmapped)" },
				{ texts(L:picker_hue_rooms())[3], texts(L:picker_hue_rooms())[4], texts(L:picker_hue_rooms())[5] })
			assert.equal(0, L:on_container(container(F.events.zone_delete)))
			assert.equal(4, #L:picker_hue_rooms())
			assert.equal(0, #c4.sent)
		end)

		it("takes a device rename into device_name and drops deleted devices from the cache", function()
			assert.equal(0, L:on_container({ type = "update", data = { { id = F.device_rids.garage, type = "device",
				metadata = { name = "Garage Device" } } } }))
			assert.equal("Garage Device", L.registry[F.rids.garage].device_name)
			assert.equal("Garage White", L.registry[F.rids.garage].name)
			assert.equal(0, L:on_container({ type = "delete", data = { { id = F.device_rids.garage, type = "device" } } }))
			assert.is_nil(L.devices[F.device_rids.garage])
		end)

		it("refreshes and persists the registry name on a Hue rename event", function()
			local function rename(rid, name, extra)
				local item = { id = rid, type = "light", metadata = { name = name } }
				for k, v in pairs(extra or {}) do item[k] = v end
				return { type = "update", data = { item } }
			end
			local before = saves()

			-- A rename alone: nothing to send, registry and store updated at once.
			assert.equal(0, L:on_container(rename(F.rids.garage, "Garage Lamp")))
			assert.equal(0, #c4.sent)
			assert.equal("Garage Lamp", L.registry[F.rids.garage].name)
			assert.equal("Garage Lamp", c4.persist.hue_lights[F.rids.garage].name)
			assert.equal(ID.garage, L:device_for(F.rids.garage), "the device id is untouched")
			assert.equal(before + 1, saves())
			assert.is_true(saw_log("Garage White was renamed to Garage Lamp in Hue"))
			assert.equal(0, #c4.calls_to("RenameDevice"))

			-- A rename alongside state: the state is sent, the name is taken.
			assert.equal(1, L:on_container(rename(F.rids.living, "Lounge Lamp", { on = { on = false } })))
			assert.same({ rid = F.rids.living, on = "false", reason = "event" }, c4.sent[1].params)
			assert.equal("Lounge Lamp", c4.persist.hue_lights[F.rids.living].name)
			assert.equal(before + 2, saves())

			-- The same name again, and a rename of an unregistered light: no save.
			assert.equal(0, L:on_container(rename(F.rids.living, "Lounge Lamp")))
			assert.equal(0, L:on_container(rename("unknown", "Whatever")))
			assert.equal(before + 2, saves())

			-- The next resync sees the same names: no rename logged, no save.
			logged = {}
			resync({ light = F.light:gsub("Garage White", "Garage Lamp"):gsub("Living Room Lamp", "Lounge Lamp") })
			assert.is_false(saw_log("was renamed"))
			assert.equal(before + 2, saves())
		end)

		it("skips the devices of unbound entries", function()
			L:on_binding_changed(1, "HUE_BRIDGE", false, ID.garage)
			c4.sent = {}
			assert.equal(0, L:on_container(container(F.events.off)))
			assert.equal(0, L:on_container(container(F.events.connectivity)))
			assert.equal(0, #c4.sent)
		end)
	end)

	describe("relink", function()
		before_each(function()
			import_all()
			resync({ light = lights_json({ "living", "kitchen", "hallway" }) })
			resync(replaced_bulb())
			c4.sent = {}
		end)

		it("swaps the rid of a gone entry, keeps the device, and tells the light", function()
			assert.same({ true, "Re-linked device 2001 (was Garage White #4) to Garage White [Garage] #4" },
				{ L:relink(ID.garage, REPLACED) })
			assert.is_nil(L.registry[F.rids.garage])
			local entry = L.registry[REPLACED]
			assert.equal(ID.garage, entry.device_id)
			assert.equal("linked", entry.state)
			assert.is_nil(entry.gone_since)
			assert.equal(T0, entry.created_at, "the entry is the same record")
			assert.equal(REPLACED, c4.persist.hue_lights[REPLACED] and REPLACED)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.equal(REPLACED, c4.sent[1].params.rid)
			assert.is_nil(c4.sent[1].params.state)
			assert.equal(REPLACED, c4.sent[2].params.rid)
			assert.equal("4 on bridge, 4 imported, 0 new, 0 missing, 0 unbound, 0 deleted", L:summary())
			assert.equal("None", L:attention())
			assert.same({ "(no gone or unbound devices)" }, texts(L:picker_relink_devices()))
			assert.equal(4, #c4.calls_to("Bind"), "the import's bindings only: untouched")
			assert.equal(0, #c4.calls_to("RenameDevice"))
		end)

		it("refuses bad input and reports why", function()
			assert.same({ false, "Not re-linked: pick a device and a light" }, { L:relink(nil, REPLACED) })
			assert.same({ false, "Not re-linked: pick a device and a light" }, { L:relink(ID.garage, "") })
			assert.same({ false, "Not re-linked: device 99 is not a registered light" }, { L:relink(99, REPLACED) })
			assert.same({ false, "Not re-linked: Living Room Lamp #1 is already linked to device 2003" },
				{ L:relink(ID.garage, F.rids.living) })
			assert.same({ false, "Not re-linked: device 2003 is already linked to Living Room Lamp #1" },
				{ L:relink(ID.living, F.rids.living) })
			assert.same({ false, "Not re-linked: light nope is not on the bridge (connect the event stream and try again)" },
				{ L:relink(ID.garage, "nope") })
			assert.equal(0, #c4.sent)
			assert.equal("gone", L.registry[F.rids.garage].state)
		end)
	end)

	describe("link_devices", function()
		it("adopts bound devices by announced rid, else by an exact unique name, and reports the rest", function()
			import_all()
			-- The bridge lost its registry; the devices and bindings are still there.
			c4.persist.hue_lights = nil
			L = new_lights()
			L:load()
			resync()
			assert.equal(0, L:count())
			-- Garage White announced its rid before the owner clicked; a hand-added
			-- "Mystery" device and a second claimant of the living room rid are bound too.
			L:hello(nil, { device_id = tostring(ID.garage) })  -- a rid-less hello: nothing adopted yet
			L.announced[ID.garage] = { rid = F.rids.garage }
			c4:AddDevice("hue_light.c4z", LIVING_ROOM, "Mystery", function() end)        -- 2005
			c4:Bind(15, 1, 2005, 1, "HUE_BRIDGE")
			c4:AddDevice("hue_light.c4z", LIVING_ROOM, "Living Room Lamp", function() end) -- 2006, same name as 2003
			c4:Bind(15, 1, 2006, 1, "HUE_BRIDGE")
			c4.sent = {}

			local text = L:link_devices()
			assert.equal("Linked 3 devices: Garage White (device 2001) to Garage White [Garage] #4 by its rid, "
				.. "Hallway Ambiance (device 2002) to Hallway Ambiance [Living Room] #3 by name, "
				.. "Kitchen Strip (device 2004) to Kitchen Strip #2 by name; "
				.. "not linked 3: Living Room Lamp (device 2003): 2 bound devices share that name; rename one in Composer and "
				.. "run Link Devices again; "
				.. "Mystery (device 2005): no unimported Hue light has that name; rename the device in Composer to the Hue "
				.. "light's exact name and run Link Devices again; "
				.. "Living Room Lamp (device 2006): 2 bound devices share that name; rename one in Composer and run Link "
				.. "Devices again", text)
			assert.equal(3, L:count())
			assert.equal(ID.garage, L:device_for(F.rids.garage))
			assert.equal(ID.hallway, L:device_for(F.rids.hallway))
			assert.equal(ID.kitchen, L:device_for(F.rids.kitchen))
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001", "HUE_CONFIGURE@2002", "HUE_STATE@2002",
				"HUE_CONFIGURE@2004", "HUE_STATE@2004" }, commands_sent())
			assert.equal("linked", c4.persist.hue_lights[F.rids.garage].state)
			assert.is_true(saw_log("adopted Garage White (device 2001) from its own persisted rid (Link Devices)"))
			assert.is_true(saw_log("adopted Hallway Ambiance (device 2002) by its name (Link Devices)"))
			assert.equal(6, #c4.calls_to("AddDevice"), "the import's four and the spec's two: nothing created")

			-- Two devices with one name: ambiguous, left alone; the one with a name
			-- match is linked once the other is forgotten by the owner (deleted).
			fake.delete_device(2006)
			text = L:link_devices()
			assert.equal("Linked 1 device: Living Room Lamp (device 2003) to Living Room Lamp [Living Room] #1 by name; "
				.. "not linked 1: Mystery (device 2005): no unimported Hue light has that name; rename the device in Composer "
				.. "to the Hue light's exact name and run Link Devices again", text)

			-- A device announcing a rid another device holds is a conflict.
			L.announced[2005] = { rid = F.rids.living }
			text = L:link_devices()
			assert.equal("not linked 1: Mystery (device 2005) announces Living Room Lamp #1, which device 2003 holds "
				.. "(Forget Light on one of them)", text)
			assert.truthy(L:attention():find("2 devices claim Hue light Living Room Lamp #1: 2003 and 2005 "
				.. "(Forget Light on one of them)", 1, true))
		end)

		it("adopts a device by a rid that is not on the bridge as gone", function()
			import_all()
			c4.persist.hue_lights = nil
			L = new_lights()
			L:load()
			resync()
			L.announced[ID.garage] = { rid = "old-rid", name = "Old Lamp", model = "Hue white lamp" }
			local text = L:link_devices()
			assert.truthy(text:find("^Linked 4 devices: Garage White %(device 2001%) to Old Lamp #old%-rid by its rid "
				.. "%(not on the bridge: marked gone%), Hallway Ambiance"), text)
			assert.same({ device_id = ID.garage, name = "Old Lamp", model = "Hue white lamp", state = "gone", gone_since = T0,
				created_at = T0 }, L.registry["old-rid"])
			assert.same({ "Old Lamp (device 2001, gone since " .. os.date("%m-%d", T0) .. ")" },
				texts(L:picker_relink_devices()))
		end)

		it("reports when every bound device is registered, or none is bound", function()
			assert.equal("No devices are bound to this bridge", L:link_devices())
			import_all()
			assert.equal("All 4 bound devices are registered", L:link_devices())
		end)
	end)

	-- docs/zone-light-design.md §4: zone-light devices run hue_light.c4z too.
	-- The module is told which devices another module owns (ctx.skip_devices,
	-- or link_devices' own argument) and never adopts, lists, re-links or
	-- messages one of them.
	describe("skip set (zone-light devices)", function()
		local ZONE_DEVICE = 2005

		-- A zone-light device bound to the bridge, named like an unimported
		-- light so that a name match would otherwise adopt it.
		local function add_zone_device(name)
			c4:AddDevice("hue_light.c4z", LIVING_ROOM, name, function() end)  -- 2005
			c4:Bind(15, 1, ZONE_DEVICE, 1, "HUE_BRIDGE")
		end

		local function logs_matching(text)
			local n = 0
			for _, line in ipairs(logged) do
				if line:find(text, 1, true) then n = n + 1 end
			end
			return n
		end

		it("link_devices leaves the call's skip set out of matching and counting", function()
			import_all()
			c4.persist.hue_lights = nil
			L = new_lights()
			L:load()
			resync()
			add_zone_device("Kitchen Strip")
			L.announced[ZONE_DEVICE] = { rid = F.rids.hallway }  -- even an announced rid adopts nothing
			c4.sent = {}
			assert.equal("Linked 4 devices: Garage White (device 2001) to Garage White [Garage] #4 by name, "
				.. "Hallway Ambiance (device 2002) to Hallway Ambiance [Living Room] #3 by name, "
				.. "Living Room Lamp (device 2003) to Living Room Lamp [Living Room] #1 by name, "
				.. "Kitchen Strip (device 2004) to Kitchen Strip #2 by name", L:link_devices({ [ZONE_DEVICE] = true }))
			assert.equal(4, L:count())
			assert.is_nil(L:rid_for(ZONE_DEVICE))
			assert.same({}, sent_to(ZONE_DEVICE))
			assert.equal("All 4 bound devices are registered", L:link_devices({ [ZONE_DEVICE] = true }),
				"the skipped device is not counted")
			-- Without the skip set the zone light would be a candidate and nagged about.
			L.announced[ZONE_DEVICE] = nil
			assert.equal("not linked 1: Kitchen Strip (device 2005): no unimported Hue light has that name; "
				.. "rename the device in Composer to the Hue light's exact name and run Link Devices again", L:link_devices())
		end)

		it("ctx.skip_devices does the same for every call, as a set, a list or a function", function()
			import_all()
			add_zone_device("Kitchen Strip")
			local shapes = { { [ZONE_DEVICE] = true }, { ZONE_DEVICE }, function() return { [ZONE_DEVICE] = true } end }
			for i, skip in ipairs(shapes) do
				c4.persist.hue_lights = nil
				L = new_lights({ skip_devices = skip })
				L:load()
				resync()
				assert.same({ [ZONE_DEVICE] = true }, L:skip_set(), "shape " .. i)
				assert.truthy(L:link_devices():find("^Linked 4 devices: "), "shape " .. i)
				assert.is_nil(L:rid_for(ZONE_DEVICE), "shape " .. i)
				assert.equal("All 4 bound devices are registered", L:link_devices(), "shape " .. i)
			end
			assert.same({ [ZONE_DEVICE] = true, [7] = true, [9] = true }, L:skip_set({ 7, "junk", [9] = true, [0] = true }),
				"the call's set is added; junk is ignored")
		end)

		it("a failing skip provider reads as empty and is logged", function()
			L = new_lights({ skip_devices = function() error("boom") end })
			assert.same({}, L:skip_set())
			assert.is_true(saw_log("skip_devices failed"))
			assert.is_false(L:foreign(ZONE_DEVICE))
		end)

		it("a hello from a foreign device adopts nothing", function()
			L = new_lights({ skip_devices = { [ZONE_DEVICE] = true } })
			L:import_new(done)
			answer_gets()
			add_zone_device("Bedside Lights")
			c4.sent = {}
			assert.is_false(L:hello(F.rids.kitchen, { device_id = tostring(ZONE_DEVICE), name = "Bedside Lights" }))
			assert.is_nil(L:device_for(F.rids.kitchen))
			assert.is_true(saw_log("not adopting device 2005 for " .. F.rids.kitchen
				.. ": the device belongs to another module"))
			assert.same({}, c4.sent)
		end)

		it("keeps a stale entry held by a zone light, never messages it, refuses its re-link and drops it on forget",
			function()
			L:import_new(done)
			answer_gets()
			add_zone_device("Bedside Lights")
			-- A build without kinds adopted the zone light's hello as a light [§7 Q11].
			L.reg:add("zone-rid", { device_id = ZONE_DEVICE, name = "Bedside Lights" })
			L:save()
			L.ctx.skip_devices = function() return { [ZONE_DEVICE] = true } end
			c4.sent = {}

			-- Startup: the lights hear HUE_CONFIGURE, the zone light hears nothing from this module.
			L:configure_all()
			assert.same({ "HUE_CONFIGURE@2001", "HUE_CONFIGURE@2002", "HUE_CONFIGURE@2003" }, commands_sent())
			assert.is_true(saw_log("HUE_CONFIGURE to device 2005 not sent: the device belongs to another module"))

			-- Reconcile: the device exists, so the entry is not tombstoned; the oddity is logged once.
			assert.same({ unbound = {}, relinked = {}, tombstoned = {} }, L:reconcile())
			assert.equal(ZONE_DEVICE, L:device_for("zone-rid"))
			assert.equal(1, logs_matching("Bedside Lights #zone-rid (device 2005) is registered as a light, but the device "
				.. "is a zone light; Forget Light drops the stale entry (the device stays bound)"))
			L:reconcile()
			assert.equal(1, logs_matching("is registered as a light, but the device is a zone light"))

			-- A resync finds no such light and marks the entry gone, telling the device nothing.
			resync()
			assert.equal("gone", L.registry["zone-rid"].state)
			assert.same({}, sent_to(ZONE_DEVICE))

			-- Re-link to a real light is refused; Forget drops the entry and leaves the binding alone.
			assert.same({ false, "Not re-linked: device 2005 is a zone light; Forget Light drops its stale light entry" },
				{ L:relink(ZONE_DEVICE, F.rids.kitchen) })
			assert.same({ true, "Forgot Bedside Lights #zone-rid (device 2005): dropped the stale light entry; "
				.. "the device stays bound as a zone light" }, { L:forget(ZONE_DEVICE) })
			assert.is_nil(L.registry["zone-rid"])
			assert.is_nil(c4.persist.hue_lights["zone-rid"])
			assert.same({}, sent_to(ZONE_DEVICE), "no HUE_FORGOTTEN")
			assert.equal(0, #c4.calls_to("Unbind"))
			assert.equal(3, L:count())
		end)
	end)

	describe("forget", function()
		before_each(function()
			import_all()
			c4.sent = {}
		end)

		it("drops the entry, unbinds the device, tells it HUE_FORGOTTEN, and lists the light under Add Light", function()
			assert.same({ true, "Forgot Garage White #4 (device 2001): unbound and left in the project for you to delete; "
				.. "the Hue light is listed under Add Light again" }, { L:forget(ID.garage) })
			assert.is_nil(L.registry[F.rids.garage])
			assert.is_nil(c4.persist.hue_lights[F.rids.garage])
			assert.is_nil(c4.persist.hue_tombstones[F.rids.garage], "forget leaves no tombstone")
			assert.same({ { ID.garage, 1 } }, c4.calls_to("Unbind"))
			assert.same({ { id = ID.garage, command = "HUE_FORGOTTEN",
				params = { rid = F.rids.garage, name = "Garage White" } } }, c4.sent)
			assert.same({ "Garage White [Garage] #4" }, texts(L:picker_lights()))
			assert.equal("4 on bridge, 3 imported, 1 new, 0 missing, 0 unbound, 0 deleted", L:summary())
			assert.truthy(fake.project.devices[ID.garage], "the device stays for the owner to delete")
			-- The device is still in the project: the next import would add the
			-- light again as a new device, which is the owner's call.
			c4.added = {}
			L:import_new(done)
			answer_gets()
			assert.equal(1, #c4.added)
			assert.equal(2005, c4.added[1].id)
		end)

		it("refuses an unknown device", function()
			assert.same({ false, "Not forgotten: pick a device first" }, { L:forget(nil) })
			assert.same({ false, "Not forgotten: device 99 is not a registered light" }, { L:forget(99) })
			assert.equal(0, #c4.sent)
		end)

		it("handles HUE_FORGET from a light by device id or rid, and tells a stranger it is forgotten", function()
			assert.is_true((L:forget_request({ device_id = tostring(ID.garage) })))
			assert.is_nil(L.registry[F.rids.garage])
			assert.is_true((L:forget_request({ rid = F.rids.kitchen })))
			assert.is_nil(L.registry[F.rids.kitchen])
			assert.same({ false, "Not forgotten: device 99 is not a registered light (told it so)" },
				{ L:forget_request({ device_id = "99", rid = "x" }) })
			assert.same({ id = 99, command = "HUE_FORGOTTEN", params = { rid = "x" } }, c4.sent[#c4.sent])
			assert.same({ false, "Not forgotten: the light named no device" }, { L:forget_request({}) })
		end)
	end)

	describe("names", function()
		before_each(function()
			import_all()
			-- The owner renamed two devices in Composer; Garage White's proxy id is
			-- known (as the OS 3.4.2 callback supplies it), Hallway Ambiance's is not.
			L.registry[F.rids.garage].proxy_id = fake.project.devices[ID.garage].proxy_id
			c4:RenameDevice(fake.project.devices[ID.garage].proxy_id, "Garage")
			-- Composer renames both halves [verified: hardware]; the fake renames one id at a time.
			c4:RenameDevice(ID.hallway, "Hall")
			c4:RenameDevice(fake.project.devices[ID.hallway].proxy_id, "Hall")
			c4.renamed = {}
		end)

		it("counts the differences in Attention until adopted or accepted [Q 10]", function()
			assert.equal("2 Hue names differ from the Composer names: Garage is Garage White in Hue, Hall is Hallway Ambiance "
				.. "in Hue (Adopt Hue Names or Accept Names As They Are)", L:attention())
			assert.equal("Accepted 2 name differences: Garage (Hue: Garage White), Hall (Hue: Hallway Ambiance)",
				L:accept_names())
			assert.equal("None", L:attention())
			assert.equal("Garage White", c4.persist.hue_lights[F.rids.garage].name_dismissed)
			assert.equal("No Composer names differ from the Hue names", L:accept_names())
			-- A Hue rename makes the difference new again.
			L:on_container({ type = "update", data = { { id = F.rids.garage, type = "light",
				metadata = { name = "Garage Lamp" } } } })
			assert.equal("1 Hue name differs from the Composer names: Garage is Garage Lamp in Hue "
				.. "(Adopt Hue Names or Accept Names As They Are)", L:attention())
		end)

		it("adopt_hue_names renames the proxy of every linked device whose Composer name differs", function()
			assert.equal("Renamed 1 device: Garage → Garage White (device 2001); not renamed 1: Hall (device 2002): "
				.. "no proxy id known", L:adopt_hue_names())
			assert.same({ { id = 3001, name = "Garage White" } }, c4.renamed)
			assert.equal("Garage White", c4:GetDeviceDisplayName(3001))
			assert.equal("not renamed 1: Hall (device 2002): no proxy id known", L:adopt_hue_names())
			L.registry[F.rids.hallway].proxy_id = fake.project.devices[ID.hallway].proxy_id
			assert.equal("Renamed 1 device: Hall → Hallway Ambiance (device 2002)", L:adopt_hue_names())
			assert.equal("No Composer names differ from the Hue names", L:adopt_hue_names())
			assert.equal("None", L:attention())
			assert.equal(0, #c4.calls_to("RenameDevice") - 5, "three renames by the spec, two by the action")
		end)

		it("never renames from an event, an import or a resync", function()
			resync({ light = F.light:gsub("Garage White", "Garage Lamp") })
			L:on_container({ type = "update", data = { { id = F.rids.kitchen, type = "light",
				metadata = { name = "Island" } } } })
			assert.same({}, c4.renamed)
		end)
	end)

	-- Security review 2026-10-25 finding 8: AddDevice and the light's Hue Name
	-- and Hue Room rows get display names (util.display_name); the registry
	-- keeps Hue's own. bridge/owner_spec.lua has the upgrade cases.
	describe("names that reach Control4 (security review 2026-10-25 finding 8)", function()
		-- Garage White and its room called at length, with control characters,
		-- in an app paired with the bridge (JSON string contents) ...
		local LIGHT = "Garage\\tWhite\\n" .. string.rep(" over the bench", 8)
		local ROOM = "Garage\\n" .. string.rep(" and workshop", 9)
		-- ... as the registry keeps them ...
		local LIGHT_RAW = "Garage\tWhite\n" .. string.rep(" over the bench", 8)
		local ROOM_RAW = "Garage\n" .. string.rep(" and workshop", 9)
		-- ... and as Control4 gets them: no control characters, 100 characters at most.
		local LIGHT_SHOWN = "GarageWhite" .. string.rep(" over the bench", 5) .. " over the benc"
		local ROOM_SHOWN = "Garage" .. string.rep(" and workshop", 7) .. " an"

		local function named_gets()
			return {
				light = replace(F.light, '"name":"Garage White"', '"name":"' .. LIGHT .. '"'),
				device = replace(F.device, '"name":"Garage White"', '"name":"' .. LIGHT .. '"'),
				room = replace(F.room, '"name":"Garage"', '"name":"' .. ROOM .. '"'),
			}
		end

		it("adds and configures the light under display names", function()
			resync(named_gets())
			L:add_light(F.rids.garage, GARAGE_ROOM, done)
			assert.is_true(last_result().ok)
			assert.equal(LIGHT_SHOWN, c4.added[1].name)
			local configure = sent_to(ID.garage, "HUE_CONFIGURE")[1].params
			assert.equal(LIGHT_SHOWN, configure.name)
			assert.equal(ROOM_SHOWN, configure.hue_room)
			local entry = L:entry(F.rids.garage)
			assert.same({ LIGHT_RAW, ROOM_RAW }, { entry.name, entry.hue_room }, "the registry keeps Hue's names")
		end)

		it("configures the model the bridge reports as a display name too", function()
			resync({ device = replace(F.device, '"product_name":"Hue white lamp"', '"product_name":"Hue white\\tlamp\\n"') })
			L:add_light(F.rids.garage, GARAGE_ROOM, done)
			assert.equal("Hue whitelamp", sent_to(ID.garage, "HUE_CONFIGURE")[1].params.model)
			assert.equal("Hue white\tlamp\n", L:entry(F.rids.garage).model, "the registry keeps the bridge's")
		end)

		it("names a light after its own name when its device's name has nothing to show", function()
			resync()
			L.devices[F.device_rids.garage].name = {}  -- how the controller decodes a JSON null
			L:add_light(F.rids.garage, GARAGE_ROOM, done)
			assert.equal("Garage White", c4.added[1].name)
			L.devices[F.device_rids.hallway].name = "\n"
			L:add_light(F.rids.hallway, GARAGE_ROOM, done)
			assert.equal("Hallway Ambiance", c4.added[2].name)
		end)

		it("does not list a light an older build created under the raw name", function()
			resync(named_gets())
			L:add_light(F.rids.garage, GARAGE_ROOM, done)
			local proxy = fake.project.devices[ID.garage].proxy_id
			L.registry[F.rids.garage].proxy_id = proxy
			c4:RenameDevice(proxy, LIGHT_RAW)  -- what an older build's AddDevice was given
			c4.renamed = {}
			assert.same({}, L:name_differences())
			assert.is_nil(L:attention():find("differ", 1, true))
			assert.equal("No Composer names differ from the Hue names", L:adopt_hue_names())
			assert.same({}, c4.renamed)
		end)
	end)

	describe("room mappings", function()
		it("set_room_mapping maps rooms and zones, re-maps, removes, and refuses bad input", function()
			resync()
			assert.same({ true, "Mapped Garage → Living Room" }, { L:set_room_mapping(F.group_rids.garage, LIVING_ROOM) })
			assert.same({ true, "Mapped Downstairs (zone) → Garage" },
				{ L:set_room_mapping(F.group_rids.downstairs, GARAGE_ROOM) })
			assert.same({ c4_room_id = GARAGE_ROOM, c4_room_name = "Garage", hue_name = "Downstairs", type = "zone" },
				c4.persist.hue_rooms[F.group_rids.downstairs])
			assert.equal("Garage → Living Room; Living Room → Living Room; Attic (zone) → (unmapped); "
				.. "Downstairs (zone) → Garage", L:room_mappings_text())
			assert.same({ true, "Removed the mapping for Garage" }, { L:set_room_mapping(F.group_rids.garage, nil) })
			assert.same({ true, "No mapping for Garage to remove" }, { L:set_room_mapping(F.group_rids.garage, nil) })
			assert.same({ false, "Not mapped: pick a Hue room first" }, { L:set_room_mapping("", LIVING_ROOM) })
			assert.same({ false, "Not mapped: Hue room nope is not on the bridge (connect the event stream and try again)" },
				{ L:set_room_mapping("nope", LIVING_ROOM) })
			assert.same({ false, "Not mapped: the whole bridge cannot be mapped to one room" },
				{ L:set_room_mapping(F.group_rids.home, LIVING_ROOM) })
			assert.same({ false, "Not mapped: Control4 room 99 does not exist" },
				{ L:set_room_mapping(F.group_rids.garage, 99) })
			assert.same({ false, "Not mapped: pick a Control4 room or (no mapping)" },
				{ L:set_room_mapping(F.group_rids.garage, "x") })
		end)

		it("map_rooms_by_name matches exactly (case-insensitive, trimmed), never overrides, and reports", function()
			c4.persist.hue_rooms_automapped = "done"
			fake.rename_room(GARAGE_ROOM, "GARAGE")
			fake.add_room(9, " Downstairs ", 4, "Lower")
			fake.add_room(10, "Living Room", 4, "Lower")  -- a second room with that name: ambiguous
			resync()
			assert.equal("None; use Map Rooms By Name", L:room_mappings_text())
			assert.equal("Mapped 2: Garage → GARAGE, Downstairs (zone) →  Downstairs ; no Control4 room named: Attic (zone); "
				.. "ambiguous: Living Room (2 Control4 rooms are named Living Room)", L:map_rooms_by_name())
			L:set_room_mapping(F.group_rids.living_room, 10)
			L:set_room_mapping(F.group_rids.garage, LIVING_ROOM)
			assert.equal("Nothing new to map; 3 already mapped (kept); no Control4 room named: Attic (zone)",
				L:map_rooms_by_name())
			assert.equal(LIVING_ROOM, c4.persist.hue_rooms[F.group_rids.garage].c4_room_id, "never overridden")
		end)

		it("map_rooms_by_name needs the groups and the rooms", function()
			assert.equal("Nothing mapped: no Hue rooms fetched yet (connect the event stream and try again)",
				L:map_rooms_by_name())
			L = new_lights({ project = { rooms = function() return {} end } })
			resync()
			assert.equal("Nothing mapped: no Control4 rooms found in the project", L:map_rooms_by_name())
		end)

		it("room_mappings_text shows broken mappings and groups deleted in Hue", function()
			c4.persist.hue_rooms = {
				[F.group_rids.garage] = { c4_room_id = 99, c4_room_name = "Shed", hue_name = "Garage", type = "room" },
				["old-office"] = { c4_room_id = LIVING_ROOM, c4_room_name = "Living Room", hue_name = "Office", type = "room" },
				["old-zone"] = { c4_room_id = 98, c4_room_name = "Loft", hue_name = "Upstairs", type = "zone" },
			}
			L:load()
			resync()
			assert.equal("Garage → (Control4 room gone); Living Room → Living Room; Attic (zone) → (unmapped); "
				.. "Downstairs (zone) → (unmapped); Office (deleted in Hue) → Living Room; "
				.. "Upstairs (zone) (deleted in Hue) → (Control4 room gone)", L:room_mappings_text())
			assert.truthy(L:attention():find("; 2 room mappings point at a Control4 room that no longer exists: Garage, "
				.. "Upstairs (zone) (deleted in Hue) (Set Room Mapping)", 1, true), L:attention())
			-- The stale mappings can still be removed through the picker.
			local hue_rooms = L:picker_hue_rooms()
			assert.same({ "Garage → (Control4 room gone)", "Living Room → Living Room", "Attic (zone) → (unmapped)",
				"Downstairs (zone) → (unmapped)", "Office (deleted in Hue) → Living Room",
				"Upstairs (zone) (deleted in Hue) → (Control4 room gone)" }, texts(hue_rooms))
			assert.equal("old-zone", hue_rooms[6].value)
			assert.same({ true, "Removed the mapping for Upstairs (zone) (deleted in Hue)" },
				{ L:set_room_mapping("old-zone", nil) })
			-- A deleted-in-Hue mapping can be re-pointed too.
			assert.same({ true, "Mapped Office (deleted in Hue) → Garage" }, { L:set_room_mapping("old-office", GARAGE_ROOM) })
		end)

		it("judges a mapping's Hue group missing only once this run has fetched the groups", function()
			c4.persist.hue_rooms = {
				[F.group_rids.garage] = { c4_room_id = GARAGE_ROOM, c4_room_name = "Garage", hue_name = "Garage", type = "room" },
				[F.group_rids.living_room] = { c4_room_id = LIVING_ROOM, c4_room_name = "Living Room", hue_name = "Living Room",
					type = "room" },
				[F.group_rids.downstairs] = { c4_room_id = 99, c4_room_name = "Cellar", hue_name = "Downstairs", type = "zone" },
			}
			L:load()
			-- Right after a reload, before any resync: the cached names, no suffix.
			assert.is_false(L.groups_loaded)
			assert.equal("Downstairs (zone) → (Control4 room gone); Garage → Garage; Living Room → Living Room",
				L:room_mappings_text())
			assert.equal("1 room mapping points at a Control4 room that no longer exists: Downstairs (zone) (Set Room Mapping)",
				L:attention())
			assert.same({ "Downstairs (zone) → (Control4 room gone)", "Garage → Garage", "Living Room → Living Room" },
				texts(L:picker_hue_rooms()))
			-- An event before the first resync cannot blank a light's room either.
			assert.same({}, L:reconcile_rooms())

			-- A resync whose /room lacks the Garage: now that one is deleted in Hue.
			local doc = json.decode(F.room)
			for i = #doc.data, 1, -1 do
				if doc.data[i].id == F.group_rids.garage then table.remove(doc.data, i) end
			end
			resync({ room = json.encode(doc) })
			assert.is_true(L.groups_loaded)
			assert.equal("Living Room → Living Room; Attic (zone) → (unmapped); Downstairs (zone) → (Control4 room gone); "
				.. "Garage (deleted in Hue) → Garage", L:room_mappings_text())
			assert.equal("Garage (deleted in Hue) → Garage", texts(L:picker_hue_rooms())[4])
			-- And a full fetch that has the Garage again drops the suffix.
			resync()
			assert.equal("Garage → Garage; Living Room → Living Room; Attic (zone) → (unmapped); "
				.. "Downstairs (zone) → (Control4 room gone)", L:room_mappings_text())
		end)

		it("room_audit lists devices whose Control4 room differs from their Hue room's mapping [Q 12]", function()
			assert.equal("No room mappings; use Map Rooms By Name or Set Room Mapping first", L:room_audit())
			import_all()
			assert.equal("All 3 linked lights in mapped Hue rooms are in the rooms their Hue rooms map to", L:room_audit())
			fake.move_device(ID.garage, LIVING_ROOM)
			fake.move_device(ID.hallway, GARAGE_ROOM)
			assert.equal("2 of 3 are not in the room their Hue room maps to: "
				.. "Garage White is in Living Room; Hue says Garage → drag it to Garage in Composer if you want it there; "
				.. "Hallway Ambiance is in Garage; Hue says Living Room → drag it to Living Room in Composer if you want it there",
				L:room_audit())
			assert.same({ { { DeviceIds = "2001,2002,2003" } } }, { c4.calls_to("GetDevices")[#c4.calls_to("GetDevices")] })
			-- Nothing moved, no rename: the audit only reads.
			assert.equal(0, #c4.calls_to("RenameDevice"))
			assert.equal(LIVING_ROOM, fake.project.devices[ID.garage].room_id)
		end)

		it("room_audit audits another module's devices by their group's mapping, after the lights", function()
			import_all()
			c4:AddDevice("hue_light.c4z", LIVING_ROOM, "Bedside Lights", function() end)  -- 2005, a zone light
			L:set_room_mapping(F.group_rids.downstairs, GARAGE_ROOM)
			local extra = {
				{ device_id = 2005, name = "Bedside Lights", group_rid = F.group_rids.downstairs },
				{ device_id = 2005, name = "Twice", group_rid = F.group_rids.downstairs },        -- a duplicate: once
				{ device_id = ID.garage, name = "Garage White", group_rid = F.group_rids.downstairs }, -- a light's: left out
				{ device_id = 2006, name = "Attic Light", group_rid = F.group_rids.attic },        -- unmapped group: left out
				{ device_id = 0, name = "Nobody", group_rid = F.group_rids.downstairs },           -- bad id: left out
				{ device_id = 2007, name = "Vanished", group_rid = F.group_rids.downstairs },      -- not in the project
				"junk",
			}
			assert.equal("1 of 5 are not in the room their Hue room maps to: Bedside Lights is in Living Room; "
				.. "Hue says Downstairs (zone) → drag it to Garage in Composer if you want it there; 1 not found in the project",
				L:room_audit(extra))
			assert.same({ { { DeviceIds = "2001,2002,2003,2005,2007" } } },
				{ c4.calls_to("GetDevices")[#c4.calls_to("GetDevices")] })
			fake.move_device(2005, GARAGE_ROOM)
			assert.equal("All 4 linked lights in mapped Hue rooms are in the rooms their Hue rooms map to",
				L:room_audit({ extra[1] }))
			assert.equal("All 3 linked lights in mapped Hue rooms are in the rooms their Hue rooms map to", L:room_audit())
			-- The project's name wins over the given one, as for a light.
			fake.move_device(2005, LIVING_ROOM)
			assert.equal("1 of 4 are not in the room their Hue room maps to: Bedside Lights is in Living Room; "
				.. "Hue says Downstairs (zone) → drag it to Garage in Composer if you want it there",
				L:room_audit({ { device_id = 2005, name = "Other Name", group_rid = F.group_rids.downstairs } }))
		end)
	end)

	describe("hello", function()
		it("answers hello with CONFIGURE and full STATE for a known light", function()
			import_all()
			c4.sent = {}
			assert.is_true(L:hello(F.rids.kitchen, { device_id = tostring(ID.kitchen) }))
			assert.same({ "HUE_CONFIGURE@2004", "HUE_STATE@2004" }, commands_sent())
			assert.equal("hello", c4.sent[2].params.reason)
			assert.equal("xy", c4.sent[2].params.color_mode)
			assert.is_true(L:hello(F.rids.kitchen), "a hello without a device id is answered too")
		end)

		it("answers a stale rid with the registry's for that device", function()
			import_all()
			c4.sent = {}
			assert.is_true(L:hello("stale-rid", { device_id = tostring(ID.garage) }))
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.equal(F.rids.garage, c4.sent[1].params.rid)
			assert.is_nil(L.registry["stale-rid"])
		end)

		it("answers with the configuration alone before the first GET", function()
			import_all()
			L = new_lights()
			L:load()
			c4.sent = {}
			assert.is_true(L:hello(F.rids.kitchen))
			assert.same({ "HUE_CONFIGURE@2004" }, commands_sent())
		end)

		it("returns false for an unknown, empty or missing rid without a device", function()
			import_all()
			c4.sent = {}
			assert.is_false(L:hello("not-a-light"))
			assert.is_false(L:hello(""))
			assert.is_false(L:hello(nil))
			assert.is_false(L:hello(nil, { device_id = "2099" }))
			assert.equal(0, #c4.sent)
			assert.equal(4, L:count())
		end)

		it("auto-adopts exactly one bound device carrying a rid the registry lacks [Q 3]", function()
			import_all()
			c4.persist.hue_lights = nil
			L = new_lights()
			L:load()
			resync()
			c4.sent = {}
			assert.is_true(L:hello(F.rids.garage, { device_id = tostring(ID.garage), name = "Garage White",
				model = "Hue white lamp" }))
			local entry = L.registry[F.rids.garage]
			assert.equal(ID.garage, entry.device_id)
			assert.equal("linked", entry.state)
			assert.equal("00:17:88:01:0b:12:34:04-0b", entry.mac_address, "completed from the model")
			assert.equal(T0, entry.created_at)
			assert.equal(ID.garage, c4.persist.hue_lights[F.rids.garage].device_id)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.is_true(saw_log("adopted Garage White (device 2001) from its own persisted rid"))
			assert.equal(0, #c4.calls_to("AddDevice") - 4, "nothing created")
			assert.equal(0, #c4.calls_to("Bind") - 4, "nothing bound")

			-- Not on the bridge yet (before the first GET): the entry comes from the hello.
			L = new_lights()
			c4.persist.hue_lights = nil
			L:load()
			assert.is_true(L:hello(F.rids.hallway, { device_id = tostring(ID.hallway), name = "Hallway Ambiance",
				model = "Hue ambiance lamp" }))
			assert.same({ device_id = ID.hallway, name = "Hallway Ambiance", model = "Hue ambiance lamp", state = "linked",
				created_at = T0 }, L.registry[F.rids.hallway])
			assert.same({ rid = F.rids.hallway, name = "Hallway Ambiance", model = "Hue ambiance lamp", has_color = "false",
				has_cct = "false" }, c4.sent[#c4.sent].params)
		end)

		it("refuses two devices claiming one rid and names both in Attention", function()
			import_all()
			c4.sent = {}
			assert.is_false(L:hello(F.rids.garage, { device_id = tostring(ID.hallway) }))
			assert.equal(0, #c4.sent)
			assert.equal(ID.garage, L:device_for(F.rids.garage), "the holder keeps the rid")
			assert.equal("2 devices claim Hue light Garage White #4: 2001 and 2002 (Forget Light on one of them)", L:attention())
			assert.is_true(saw_log("device 2002 claims Garage White #4, which device 2001 holds"))
			-- Forgetting (or deleting) either device ends the conflict.
			L:forget(ID.hallway)
			assert.equal("4 on bridge, 3 imported, 1 new, 0 missing, 0 unbound, 0 deleted", L:summary())
			assert.equal("1 new light on the bridge: Hallway Ambiance [Living Room] #3 (Add Light or Import All New Lights)",
				L:attention())

			-- Two unregistered devices announcing one rid: neither is adopted.
			c4.persist.hue_lights = nil
			L = new_lights()
			L:load()
			resync()
			c4.sent = {}
			assert.is_true(L:hello(F.rids.kitchen, { device_id = tostring(ID.kitchen) }))
			L.registry[F.rids.kitchen] = nil  -- as if the first had not been adopted yet
			L.reg.lights[F.rids.kitchen] = nil
			assert.is_false(L:hello(F.rids.kitchen, { device_id = tostring(ID.living) }))
			assert.is_nil(L.registry[F.rids.kitchen])
			assert.truthy(L:attention():find("2 devices claim Hue light Kitchen Strip #2: 2004 and 2003", 1, true))
		end)

		it("does not adopt an unbound device", function()
			import_all()
			c4:AddDevice("hue_light.c4z", LIVING_ROOM, "Loose", function() end)  -- 2005, never bound
			assert.is_false(L:hello(NEW_BULB, { device_id = "2005" }))
			assert.is_nil(L.registry[NEW_BULB])
			assert.is_true(saw_log("device 2005 announced " .. NEW_BULB .. " but is not bound; not adopted"))
		end)

		it("queues a hello that arrives before load() and answers it from configure_all()", function()
			import_all()
			L = new_lights()
			assert.is_false(L:hello(F.rids.garage, { device_id = tostring(ID.garage) }))
			c4.sent = {}
			L:load()
			assert.equal(4, L:configure_all())
			assert.same({ "HUE_CONFIGURE@2001", "HUE_CONFIGURE@2002", "HUE_CONFIGURE@2004", "HUE_CONFIGURE@2003",
				"HUE_CONFIGURE@2001" }, commands_sent(), "every light, then the queued hello's answer")
			assert.same({ rid = F.rids.hallway, name = "Hallway Ambiance", model = "Hue ambiance lamp",
				has_color = "false", has_cct = "true", mirek_min = "153", mirek_max = "454", min_dim = "0.2",
				hue_room = "Living Room", id_v1 = "/lights/3" }, c4.sent[2].params)
			-- The first resync after that sends state only.
			c4.sent = {}
			resync()
			assert.same({ "HUE_STATE@2001", "HUE_STATE@2002", "HUE_STATE@2004", "HUE_STATE@2003" }, commands_sent())
		end)

		it("gives the command queue limits from the model, or from caps before a GET", function()
			import_all()
			assert.same({ min_dim = 0.2, mirek_min = 153, mirek_max = 500 }, L:limits(F.rids.living))
			assert.same({ min_dim = 5 }, L:limits(F.rids.garage))
			assert.is_nil(L:limits("nope"))
			assert.is_nil(L:limits(nil))
			L = new_lights()
			L:load()
			assert.same({ min_dim = 0.2, mirek_min = 153, mirek_max = 454 }, L:limits(F.rids.hallway))
		end)
	end)

	describe("goodbye and tombstones", function()
		it("tombstones the entry, which Import skips and Add Light re-creates", function()
			import_all()
			now = T0 + 100
			local tomb = L:goodbye({ rid = F.rids.garage, device_id = tostring(ID.garage) })
			assert.same({ name = "Garage White", device_name = "Garage White", deleted_at = T0 + 100 }, tomb)
			assert.is_nil(L.registry[F.rids.garage])
			assert.same(tomb, c4.persist.hue_tombstones[F.rids.garage])
			assert.is_nil(c4.persist.hue_lights[F.rids.garage])
			assert.equal("4 on bridge, 3 imported, 0 new, 0 missing, 0 unbound, 1 deleted", L:summary())
			assert.equal("None", L:attention(), "a deletion the owner made is not a nag")
			assert.is_true(saw_log("Garage White #4 (device 2001) was deleted in Composer"))
			local date = os.date("%Y-%m-%d", T0 + 100)
			assert.same({ "Garage White [Garage] #4 (deleted from Composer " .. date .. ")" }, texts(L:picker_lights()))

			c4.added = {}
			L:import_new(done)
			answer_gets()
			assert.equal(0, #c4.added)
			assert.same({ ok = true, text = "Added no lights; skipped 1 deleted in Composer (Add Light re-creates one): "
				.. "Garage White #4 (deleted " .. date .. ")" }, last_result())

			L:add_light(F.rids.garage, nil, done)
			assert.same({ ok = true, text = "Added Garage White #4 to Garage (device 2005)" }, last_result())
			assert.is_nil(c4.persist.hue_tombstones[F.rids.garage], "Add Light clears the tombstone")
			assert.equal(2005, L:device_for(F.rids.garage))
		end)

		it("finds the entry by device id alone, by rid alone, and ignores strangers", function()
			import_all()
			assert.truthy(L:goodbye({ device_id = tostring(ID.garage) }))
			assert.truthy(L:goodbye({ rid = F.rids.hallway }))
			assert.is_nil(L:goodbye({ rid = F.rids.living, device_id = "999" }), "a rid with another device's id")
			assert.is_nil(L:goodbye({ device_id = "999" }))
			assert.is_nil(L:goodbye({}))
			assert.equal(2, L:count())
		end)

		it("a hello from a tombstoned light's device re-adopts it and clears the tombstone", function()
			import_all()
			L:goodbye({ rid = F.rids.garage, device_id = tostring(ID.garage) })
			assert.is_true(L:hello(F.rids.garage, { device_id = tostring(ID.garage), name = "Garage White" }))
			assert.is_nil(c4.persist.hue_tombstones[F.rids.garage])
			assert.equal(ID.garage, L:device_for(F.rids.garage))
		end)
	end)

	describe("on_binding_changed", function()
		it("marks an entry unbound on binding 1 false and linked again on true", function()
			import_all()
			c4.sent = {}
			now = T0 + 7
			-- Composer unbinds the light; Director then reports it to the bridge.
			c4:Unbind(ID.garage, 1)
			assert.is_true(L:on_binding_changed(1, "HUE_BRIDGE", false, ID.garage))
			local entry = L.registry[F.rids.garage]
			assert.equal("unbound", entry.state)
			assert.equal(T0 + 7, entry.unbound_since)
			assert.equal("unbound", c4.persist.hue_lights[F.rids.garage].state)
			assert.equal("4 on bridge, 4 imported, 0 new, 0 missing, 1 unbound, 0 deleted", L:summary())
			assert.equal("1 unbound device: Garage White #4 (device 2001) (bind it to this bridge in Composer, or Forget Light)",
				L:attention())
			assert.same({ "Garage White (device 2001, unbound since " .. os.date("%m-%d", T0 + 7) .. ")" },
				texts(L:picker_relink_devices()))
			assert.is_false(L:on_binding_changed(1, "HUE_BRIDGE", false, ID.garage), "idempotent")

			-- The fan-out skips it; configure_all skips it.
			resync()
			assert.equal(0, #sent_to(ID.garage))
			assert.equal(3, L:configure_all())

			-- Bound again: linked, told its configuration and state.
			c4.sent = {}
			c4:Bind(15, 1, ID.garage, 1, "HUE_BRIDGE")
			assert.is_true(L:on_binding_changed(1, "HUE_BRIDGE", true, tostring(ID.garage)))
			assert.equal("linked", L.registry[F.rids.garage].state)
			assert.is_nil(L.registry[F.rids.garage].unbound_since)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
		end)

		it("ignores other bindings, other classes and unknown devices", function()
			import_all()
			assert.is_false(L:on_binding_changed(5001, "LIGHT_V2", false, ID.garage))
			assert.is_false(L:on_binding_changed(1, "OTHER", false, ID.garage))
			assert.is_false(L:on_binding_changed(1, "HUE_BRIDGE", false, 999))
			assert.is_false(L:on_binding_changed(1, "HUE_BRIDGE", true, 999))
			assert.is_false(L:on_binding_changed(1, nil, false, nil))
			assert.equal("linked", L.registry[F.rids.garage].state)
		end)
	end)

	describe("reconcile", function()
		it("marks present-but-unbound devices unbound, tombstones deleted ones, and treats an empty project as unknown",
			function()
			import_all()
			c4:Unbind(ID.garage, 1)
			fake.delete_device(ID.hallway)
			local r = L:reconcile()
			assert.same({ unbound = { F.rids.garage }, relinked = {}, tombstoned = { F.rids.hallway } }, r)
			assert.equal("unbound", c4.persist.hue_lights[F.rids.garage].state)
			assert.is_nil(c4.persist.hue_lights[F.rids.hallway])
			assert.equal("Hallway Ambiance", c4.persist.hue_tombstones[F.rids.hallway].name)
			assert.is_true(saw_log("Hallway Ambiance was deleted in Composer while the bridge was not watching"))

			-- Bound again: relinked, and told its configuration and state.
			c4:Bind(15, 1, ID.garage, 1, "HUE_BRIDGE")
			c4.sent = {}
			assert.same({ F.rids.garage }, L:reconcile().relinked)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())

			-- A project lookup that returns nothing: nothing is tombstoned.
			L.ctx.project.devices = function() return {} end
			c4:Unbind(ID.living, 1)
			fake.delete_device(ID.kitchen)
			r = L:reconcile()
			assert.same({ unbound = { F.rids.kitchen, F.rids.living }, relinked = {}, tombstoned = {} }, r)
			assert.equal(3, L:count())

			-- A failed bound-device lookup changes nothing.
			L.ctx.project.bound = function() error("boom") end
			assert.same({ unbound = {}, relinked = {}, tombstoned = {} }, L:reconcile())
			assert.is_true(saw_log("reconcile skipped: the bound-device lookup failed"))
		end)
	end)

	describe("pickers", function()
		it("picker_lights lists unimported lights with room and number, hints first, deleted last", function()
			assert.same({ { text = "(no lights fetched yet; connect the event stream)", value = "" } }, L:picker_lights())
			resync()
			assert.same({ "Garage White [Garage] #4", "Hallway Ambiance [Living Room] #3", "Kitchen Strip #2",
				"Living Room Lamp [Living Room] #1" }, texts(L:picker_lights()))
			assert.same({ F.rids.garage, F.rids.hallway, F.rids.kitchen, F.rids.living }, values(L:picker_lights()))
			import_all()
			assert.same({ { text = "(every light on the bridge is imported)", value = "" } }, L:picker_lights())
			L:goodbye({ rid = F.rids.living, device_id = tostring(ID.living) })
			L:on_container(container(F.events.add))
			assert.same({ "New Bulb #5", "Living Room Lamp [Living Room] #1 (deleted from Composer " .. os.date("%Y-%m-%d", T0)
				.. ")" }, texts(L:picker_lights()))
		end)

		it("replaces commas in Hue names with spaces", function()
			resync({ light = F.light:gsub("Kitchen Strip", "Kitchen, Strip") })
			assert.equal("Kitchen  Strip #2", texts(L:picker_lights())[3])
		end)

		it("picker_rooms lists Floor / Room, disambiguates by id, and starts with the mode's entry", function()
			fake.add_room(9, "Garage", 4, "Upstairs")
			assert.same({
				{ text = "(mapped room)", value = "mapped" },
				{ text = "Main / Garage (8)", value = "8" },
				{ text = "Main / Living Room", value = "7" },
				{ text = "Upstairs / Garage (9)", value = "9" },
			}, L:picker_rooms("add"))
			assert.same({ "(no mapping)", "Main / Garage (8)", "Main / Living Room", "Upstairs / Garage (9)" },
				texts(L:picker_rooms("mapping")))
			assert.equal("none", L:picker_rooms("mapping")[1].value)
			assert.same({ "Main / Garage (8)", "Main / Living Room", "Upstairs / Garage (9)" }, texts(L:picker_rooms()))

			L = new_lights({ project = { rooms = function() return {} end } })
			assert.same({ { text = "(mapped room)", value = "mapped" },
				{ text = "(no rooms found in the project)", value = "" } },
				L:picker_rooms("add"))
			L = new_lights({ project = { hierarchy = function() return {} end } })
			assert.same({ "Garage (8)", "Garage (9)", "Living Room" }, texts(L:picker_rooms()),
				"no floors known: room names alone")
		end)

		it("picker_forget_devices lists every entry with its state", function()
			assert.same({ { text = "(no registered lights)", value = "" } }, L:picker_forget_devices())
			import_all()
			c4:Unbind(ID.kitchen, 1)
			L:on_binding_changed(1, "HUE_BRIDGE", false, ID.kitchen)
			resync({ light = lights_json({ "living", "kitchen", "hallway" }) })
			assert.same({
				{ text = "Garage White #4 (device 2001) gone", value = "2001" },
				{ text = "Hallway Ambiance #3 (device 2002)", value = "2002" },
				{ text = "Kitchen Strip #2 (device 2004) unbound", value = "2004" },
				{ text = "Living Room Lamp #1 (device 2003)", value = "2003" },
			}, L:picker_forget_devices())
			assert.same({ "Garage White (device 2001, gone since " .. os.date("%m-%d", T0) .. ")",
				"Kitchen Strip (device 2004, unbound since " .. os.date("%m-%d", T0) .. ")" },
				texts(L:picker_relink_devices()))
		end)

		it("picker_hue_rooms lists rooms then zones with their mappings", function()
			assert.same({ { text = "(no Hue rooms fetched yet; connect the event stream)", value = "" } }, L:picker_hue_rooms())
			resync()
			assert.same({
				{ text = "Garage → Garage", value = F.group_rids.garage },
				{ text = "Living Room → Living Room", value = F.group_rids.living_room },
				{ text = "Attic (zone) → (unmapped)", value = F.group_rids.attic },
				{ text = "Downstairs (zone) → (unmapped)", value = F.group_rids.downstairs },
			}, L:picker_hue_rooms())
		end)
	end)

	describe("texts", function()
		it("summary counts before and after the first GET", function()
			assert.equal("0 imported", L:summary())
			import_all()
			L = new_lights()
			L:load()
			assert.equal("4 imported", L:summary())
			resync()
			assert.equal("4 on bridge, 4 imported, 0 new, 0 missing, 0 unbound, 0 deleted", L:summary())
		end)

		it("attention nags about lights offline for more than 24 h [Q 8] and is None otherwise", function()
			import_all()
			assert.equal("None", L:attention())
			now = T0 + lights.OFFLINE_NAG_S - 1
			assert.equal("None", L:attention())
			now = T0 + lights.OFFLINE_NAG_S
			assert.equal("1 light offline for more than 24 h: Garage White #4", L:attention())
			-- Back online: the clock resets.
			L:on_container(container(F.events.connectivity))
			assert.equal("None", L:attention())
			now = now + lights.OFFLINE_NAG_S
			assert.equal("None", L:attention())
		end)
	end)

	describe("load", function()
		it("tolerates an empty or malformed store", function()
			assert.same({}, L:load())
			c4.persist.hue_lights = "garbage"
			assert.same({}, L:load())
			c4.persist.hue_lights = { [F.rids.living] = { device_id = "2004", name = "L", caps = { has_color = "true" } },
				bad = { name = "no id" } }
			L:load()
			assert.equal(2004, L:device_for(F.rids.living))
			assert.is_true(L.registry[F.rids.living].caps.has_color)
			assert.is_nil(L.registry.bad)
			assert.equal(1, L:count())
		end)

		it("upgrades v1 entries in place and keeps v2 fields, with or without a proxy id", function()
			c4.persist.hue_lights = {
				[F.rids.living] = { device_id = 2004, name = "L" },                         -- v1, before proxy_id
				[F.rids.garage] = { device_id = 2001, proxy_id = "2005", name = "G" },      -- v1, string from the store
				[F.rids.kitchen] = { device_id = 2003, proxy_id = "none", name = "K", state = "gone", gone_since = "1761000000",
					mac_address = "00:17:88:01:0b:12:34:02-0b", hue_room = "Kitchen" },     -- v2
			}
			local registry = L:load()
			assert.equal(L.registry, registry, "load() returns the live entries table")
			assert.equal(3, L:count())
			assert.is_nil(L:proxy_for(F.rids.living))
			assert.same({ device_id = 2004, name = "L", state = "linked" }, L:entry(F.rids.living))
			assert.equal(2005, L:proxy_for(F.rids.garage))
			assert.is_nil(L:proxy_for(F.rids.kitchen))
			assert.same({ device_id = 2003, name = "K", state = "gone", gone_since = 1761000000,
				mac_address = "00:17:88:01:0b:12:34:02-0b", hue_room = "Kitchen" }, L:entry(F.rids.kitchen))
			-- The entries table keeps its identity across a reload.
			L:load()
			assert.equal(registry, L.registry)
			-- configure_all sends the persisted room and state.
			L:configure_all()
			local configure = sent_to(2003, "HUE_CONFIGURE")[1].params
			assert.equal("gone", configure.state)
			assert.equal("1761000000", configure.gone_since)
			assert.equal("Kitchen", configure.hue_room)
		end)

		it("uses the real C4 calls when ctx leaves them out", function()
			L = lights.new({ http = http_ctx })
			import_all()
			assert.equal(4, #c4.calls_to("AddDevice"))
			assert.equal(4, #c4.calls_to("Bind"))
			assert.equal(8, #c4.calls_to("SendToDevice"))
			local persisted = {}
			for _, args in ipairs(c4.calls_to("PersistSetValue")) do persisted[args[1]] = true end
			assert.same({ hue_lights = true, hue_rooms = true, hue_tombstones = true, hue_rooms_automapped = true }, persisted)
			-- The project calls default to C4 too (the fake records these two).
			assert.same({ { C4iNames = "hue_light.c4z" } }, c4.calls_to("GetDevices")[1])
			assert.same({ "roomdevice.c4i" }, c4.calls_to("GetDevicesByC4iName")[1])
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

		it("is empty before the first GET with nothing registered, and for a bridge without lights", function()
			assert.same({}, L:list_items())
			resync({ light = lights_json({}) })
			assert.same({}, L:list_items())
		end)

		it("lists every light on the bridge as room: light with its state, by room label then name", function()
			resync()
			assert.same({
				"(no room): Kitchen Strip (new)",
				"Garage: Garage White (new)",
				"Living Room: Hallway Ambiance (new)",
				"Living Room: Living Room Lamp (new)",
			}, L:list_items())
			import_all()
			assert.same({
				"(no room): Kitchen Strip → device 2004",
				"Garage: Garage White → device 2001",
				"Living Room: Hallway Ambiance → device 2002",
				"Living Room: Living Room Lamp → device 2003",
			}, L:list_items())
		end)

		it("marks tombstones, missing lights (under the room they were last seen in) and unbound devices", function()
			import_all()
			now = T0 + 100
			L:goodbye({ rid = F.rids.hallway, device_id = tostring(ID.hallway) })
			c4:Unbind(ID.kitchen, 1)
			L:on_binding_changed(1, "HUE_BRIDGE", false, ID.kitchen)
			resync({ light = lights_json({ "living", "kitchen", "hallway" }) })
			assert.same({
				"(no room): Kitchen Strip (unbound; device 2004)",
				"Garage: Garage White (missing; device 2001)",
				"Living Room: Hallway Ambiance" .. deleted(T0 + 100),
				"Living Room: Living Room Lamp → device 2003",
			}, L:list_items())
			assert.equal("3 on bridge, 3 imported, 0 new, 1 missing, 1 unbound, 1 deleted", L:summary())
			-- Deleted on the bridge as well: a tombstone without a light is nothing to list.
			resync({ light = lights_json({ "living", "kitchen" }) })
			assert.same({
				"(no room): Kitchen Strip (unbound; device 2004)",
				"Garage: Garage White (missing; device 2001)",
				"Living Room: Living Room Lamp → device 2003",
			}, L:list_items())
		end)

		it("reads the registry alone before the first GET", function()
			import_all()
			L = new_lights()
			L:load()
			assert.is_false(L.synced)
			assert.same({
				"(no room): Kitchen Strip → device 2004",
				"Garage: Garage White → device 2001",
				"Living Room: Hallway Ambiance → device 2002",
				"Living Room: Living Room Lamp → device 2003",
			}, L:list_items())
		end)

		it("turns commas in names and room labels into U+201A so Composer keeps one line per light", function()
			resync({ light = F.light:gsub("Kitchen Strip", "Kitchen, Strip"),
				room = F.room:gsub('"name":"Garage"', '"name":"Gar, age"') })
			local items = L:list_items()
			assert.equal("(no room): Kitchen‚ Strip (new)", items[1])
			assert.equal("Gar‚ age: Garage White (new)", items[2])
			assert.equal(4, #items)
			no_commas(items)
		end)
	end)

	-- docs/review-leftovers-design.md, issue #45 (security review 2026-10-24
	-- finding 5): ids that are not resource ids never reach the caches.
	describe("resource ids (issue #45)", function()
		it("drops a light or device whose id is not a resource id, from a GET and from an add event", function()
			local doc = json.decode(F.light)
			doc.data[1].id = "../config?x=1"
			L:resync(done)
			answer_gets({ light = json.encode(doc) })
			assert.equal(3, L:bridge_count())
			assert.is_nil(L.models["../config?x=1"])
			assert.is_true(saw_log("hue_model: dropped a light item with id \"../config?x=1\": not a resource id"))
			local function add(item)
				return L:on_container({ type = "add", data = { item } })
			end
			assert.equal(0, add({ id = "a/b", type = "light", metadata = { name = "X" } }))
			assert.equal(0, add({ id = { "null" }, type = "light" }))
			assert.equal(3, L:bridge_count())
			assert.equal(0, add({ id = "a b", type = "device", metadata = { name = "X" } }))
			assert.is_nil(L.devices["a b"])
			assert.same({ "Garage White [Garage] #4", "Hallway Ambiance [Living Room] #3", "Kitchen Strip #2" },
				texts(L:picker_lights()))
		end)
	end)

	-- Issue #48 (code analysis 2026-10-22 items 13, 14 and 18).
	describe("hardening (issue #48)", function()
		-- Item 13: Director may not list a device AddDevice has just created
		-- (nor its binding) when the reconcile after the click runs.
		it("the reconcile after an import or Add Light leaves the devices it just created alone (item 13)", function()
			local bound, devices = L.ctx.project.bound, L.ctx.project.devices
			-- An import's devices, all new to Director at once: it lists none of
			-- them yet (another hue_light device makes the project lookup known).
			L.ctx.project.bound = function() return {} end
			L.ctx.project.devices = function() return { [9999] = { deviceName = "Somebody else's" } } end
			L:import_new(done)
			answer_gets()
			assert.truthy(last_result().text:find("^Added 3 new lights"))
			for _, rid in ipairs({ F.rids.garage, F.rids.hallway, F.rids.living }) do
				assert.equal("linked", L.registry[rid].state, "neither unbound nor tombstoned")
			end
			assert.equal(0, L.reg:counts().tombstones)
			assert.is_false(saw_log("was deleted in Composer while the bridge was not watching"))

			-- Add Light, while Director's lists lag behind its AddDevice and Bind.
			local lagging = { [ID.kitchen] = true }
			L.ctx.project.bound = function()
				local out = {}
				for id, name in pairs(bound() or {}) do
					if not lagging[id] then out[id] = name end
				end
				return out
			end
			L.ctx.project.devices = function(filter)
				local out = {}
				for id, info in pairs(devices(filter) or {}) do
					if not lagging[id] then out[id] = info end
				end
				return out
			end
			L:add_light(F.rids.kitchen, LIVING_ROOM, done)
			assert.equal("Added Kitchen Strip #2 to Living Room (device 2004)", last_result().text)
			assert.equal("linked", L.registry[F.rids.kitchen].state)
			assert.is_false(saw_log("Kitchen Strip was deleted in Composer while the bridge was not watching"))
			-- The next reconcile judges it like any other entry (Director still lagging here).
			assert.same({ unbound = {}, relinked = {}, tombstoned = { F.rids.kitchen } }, L:reconcile())
		end)

		-- Item 14: GetBoundConsumerDevices answering nil is unknown.
		it("a bound-device lookup that answers nil unbinds, relabels and tombstones nothing (item 14)", function()
			import_all()
			fake.delete_device(ID.hallway)
			c4.bindings = {}  -- the fake answers nil when nothing is bound, as the SDK documents
			assert.is_nil(C4:GetBoundConsumerDevices(15, 1))
			c4.sent = {}
			assert.same({ unbound = {}, relinked = {}, tombstoned = {} }, L:reconcile())
			for _, rid in ipairs({ F.rids.garage, F.rids.hallway, F.rids.kitchen, F.rids.living }) do
				assert.equal("linked", L.registry[rid].state, rid)
				assert.equal("linked", c4.persist.hue_lights[rid].state)
			end
			assert.equal(0, #c4.sent)
			assert.is_false(saw_log("is not bound to this bridge"))
			assert.is_true(saw_log("lights: reconcile skipped: the bound-device lookup answered no list"))
			assert.equal("4 on bridge, 4 imported, 0 new, 0 missing, 0 unbound, 0 deleted", L:summary())
			-- Link Devices finds nothing to adopt either way and says so as before.
			assert.equal("No devices are bound to this bridge", L:link_devices())

			-- An empty table is a known "nothing bound".
			L.ctx.project.bound = function() return {} end
			assert.same({ unbound = { F.rids.garage, F.rids.kitchen, F.rids.living }, relinked = {},
				tombstoned = { F.rids.hallway } }, L:reconcile())
		end)

		it("a hello is not adopted while the bound-device list is unknown, and says why (item 14)", function()
			import_all()
			c4.persist.hue_lights = nil
			L = new_lights()
			L:load()
			resync()
			L.ctx.project.bound = function() return nil end
			assert.is_false(L:hello(F.rids.garage, { device_id = tostring(ID.garage) }))
			assert.is_nil(L.registry[F.rids.garage])
			assert.is_true(saw_log("device 2001 announced " .. F.rids.garage
				.. ", but the bound-device list is unknown; not adopted"))
			L.ctx.project.bound = function() error("boom") end
			assert.equal("Not linked: the bound-device lookup failed (see the Lua output)", L:link_devices())
		end)

		-- R5: a stale `announced` made false conflicts.
		it("forgets what a device announced when it is re-linked or tombstoned (R5)", function()
			import_all()
			resync({ light = lights_json({ "living", "kitchen", "hallway" }) })
			resync(replaced_bulb())
			L:hello(F.rids.garage, { device_id = tostring(ID.garage) })
			assert.equal(F.rids.garage, L.announced[ID.garage].rid)
			assert.is_true((L:relink(ID.garage, REPLACED)))
			assert.is_nil(L.announced[ID.garage])
			-- A restored device announcing the old rid is no conflict with device 2001.
			c4:AddDevice("hue_light.c4z", LIVING_ROOM, "Restored", function() end)  -- 2005
			c4:Bind(15, 1, 2005, 1, "HUE_BRIDGE")
			assert.is_true(L:hello(F.rids.garage, { device_id = "2005" }))
			assert.equal(2005, L:device_for(F.rids.garage))
			assert.equal("gone", L.registry[F.rids.garage].state, "its light is not on the bridge")
			assert.is_false(saw_log("both announce"))

			-- Deleted in Composer while the bridge was not watching.
			L:hello(F.rids.hallway, { device_id = tostring(ID.hallway) })
			assert.truthy(L.announced[ID.hallway])
			fake.delete_device(ID.hallway)
			assert.same({ F.rids.hallway }, L:reconcile().tombstoned)
			assert.is_nil(L.announced[ID.hallway])

			-- A goodbye that names the rid alone.
			L:hello(F.rids.kitchen, { device_id = tostring(ID.kitchen) })
			assert.truthy(L:goodbye({ rid = F.rids.kitchen }))
			assert.is_nil(L.announced[ID.kitchen])
		end)

		-- R6: the AddDevice cannot be taken back; the device exists.
		it("registers a light deleted on the bridge while its AddDevice was pending as gone, and tells it (R6)",
			function()
			resync()
			local add_device = L.ctx.add_device
			L.ctx.add_device = function(driver, room_id, name, cb)
				-- The Hue app deletes the light while Composer creates the device.
				L:on_container({ type = "delete", data = { { id = F.rids.kitchen, type = "light" } } })
				return add_device(driver, room_id, name, cb)
			end
			c4.sent = {}
			L:add_light(F.rids.kitchen, LIVING_ROOM, done)
			assert.same({ ok = true, text = "Added Kitchen Strip #2 to Living Room (device 2001)" }, last_result())
			local entry = L.registry[F.rids.kitchen]
			assert.equal(2001, entry.device_id)
			assert.equal("gone", entry.state)
			assert.equal(T0, entry.gone_since)
			assert.equal("gone", c4.persist.hue_lights[F.rids.kitchen].state)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.equal("gone", c4.sent[1].params.state)
			assert.equal("Kitchen Strip", c4.sent[1].params.name)
			assert.same({ rid = F.rids.kitchen, online = "false", reason = "resync" }, c4.sent[2].params)
			assert.is_true(saw_log("Kitchen Strip #2 (device 2001) was deleted on the bridge while its device was being "
				.. "added; marked gone (Re-link Device To Light or Forget Light)"))
			assert.equal("3 on bridge, 1 imported, 3 new, 1 missing, 0 unbound, 0 deleted", L:summary())
			-- Its hello is answered with the gone configuration.
			c4.sent = {}
			assert.is_true(L:hello(nil, { device_id = "2001" }))
			assert.same({ "HUE_CONFIGURE@2001" }, commands_sent())
			assert.equal("gone", c4.sent[1].params.state)
		end)

		it("marks a linked entry whose light a synced run lacks gone when its device says hello (R6)", function()
			import_all()
			L.models[F.rids.kitchen] = nil  -- registered linked, the light gone: what R6 leaves behind
			c4.sent = {}
			assert.is_true(L:hello(F.rids.kitchen, { device_id = tostring(ID.kitchen) }))
			assert.equal("gone", L.registry[F.rids.kitchen].state)
			assert.same({ "HUE_CONFIGURE@2004", "HUE_STATE@2004" }, commands_sent())
			assert.same({ rid = F.rids.kitchen, online = "false", reason = "hello" }, c4.sent[2].params)
			assert.is_true(saw_log("Kitchen Strip #2 (device 2004) is no longer on the bridge; marked gone"))
			-- Gone already: the next hello is an ordinary one.
			c4.sent = {}
			assert.is_true(L:hello(F.rids.kitchen, { device_id = tostring(ID.kitchen) }))
			assert.same({ "HUE_CONFIGURE@2004" }, commands_sent())
		end)

		it("marks gone at its hello a device bound again after its light left the bridge", function()
			import_all()
			L:on_binding_changed(1, "HUE_BRIDGE", false, ID.garage)
			assert.equal(0, L:on_container({ type = "delete", data = { { id = F.rids.garage, type = "light" } } }),
				"an unbound device hears nothing")
			assert.equal("unbound", L.registry[F.rids.garage].state)
			L:on_binding_changed(1, "HUE_BRIDGE", true, ID.garage)
			assert.equal("linked", L.registry[F.rids.garage].state)
			c4.sent = {}
			assert.is_true(L:hello(F.rids.garage, { device_id = tostring(ID.garage) }))  -- the light's own hello on binding
			assert.equal("gone", L.registry[F.rids.garage].state)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands_sent())
			assert.equal("gone", c4.sent[1].params.state)
		end)

		-- R9: lights.ENTRY_FIELDS is the schema; anything else goes at load.
		it("drops the persisted entry fields this build no longer has at load (R9)", function()
			c4.persist.hue_lights = { [F.rids.living] = { device_id = 2003, name = "L", model = "LCA001", hue_room = "Kitchen",
				mac_address = "m", room_name = "Old", c4_room = 7, caps = { has_color = true } } }
			L:load()
			assert.same({ device_id = 2003, name = "L", model = "LCA001", hue_room = "Kitchen", mac_address = "m",
				caps = { has_color = true, has_cct = false }, state = "linked" }, L:entry(F.rids.living))
			assert.is_true(saw_log(F.rids.living .. ": dropped c4_room, room_name, which this build no longer keeps"))
			L:save()
			assert.is_nil(c4.persist.hue_lights[F.rids.living].room_name)
		end)

		-- R11: SendToDevice delivers strings; anything else is a misbehaving driver.
		it("takes a hello's name and model only when they are strings (R11)", function()
			c4:AddDevice("hue_light.c4z", LIVING_ROOM, "Hallway", function() end)  -- 2001
			c4:Bind(15, 1, 2001, 1, "HUE_BRIDGE")
			L:load()
			assert.is_true(L:hello(F.rids.hallway, { device_id = "2001", name = { "junk" }, model = 7 }))
			assert.same({ device_id = 2001, state = "linked", created_at = T0 }, L.registry[F.rids.hallway])
			assert.same({ rid = F.rids.hallway }, L.announced[2001])
			assert.same({ rid = F.rids.hallway, has_color = "false", has_cct = "false" }, c4.sent[#c4.sent].params)
			assert.equal("None", L:attention())
			assert.same({ "? #" .. F.rids.hallway:sub(1, 8) .. " (device 2001)" }, texts(L:picker_forget_devices()))
		end)

		it("keeps at most 200 hellos before load() and drops the rest with a warning", function()
			for i = 1, 203 do
				L:hello(nil, { device_id = tostring(3000 + i) })
			end
			assert.equal(lights.EARLY_HELLOS_MAX, #L.early_hellos)
			assert.equal(200, lights.EARLY_HELLOS_MAX)
			assert.is_true(saw_log("HUE_HELLO from device 3201 before the registry was loaded: dropped (200 waiting)"))
			assert.is_true(saw_log("HUE_HELLO from device 3203 before the registry was loaded: dropped (200 waiting)"))
			assert.equal(3001, tonumber(L.early_hellos[1].params.device_id), "the first ones are kept")
		end)
	end)

	-- Issue #47 F2 (lights half; docs/reviews/diff-review-2026-10-24.md row 2(b)).
	describe("pending resyncs (issue #47)", function()
		it("runs one more resync for every request that waited and calls each done once", function()
			import_all()
			local got = {}
			L:resync(function(ok) got[#got + 1] = "first " .. tostring(ok) end)
			L:resync(function(ok) got[#got + 1] = "second " .. tostring(ok) end)
			L:resync(function() error("a broken done") end)
			L:resync(function(ok, _, sent) got[#got + 1] = "fourth " .. tostring(ok) .. " " .. tostring(sent) end)
			answer_gets()
			assert.same({ "first true" }, got)
			answer_gets()
			assert.same({ "first true", "second true", "fourth true 4" }, got, "each once, a failing one in between")
			assert.is_true(saw_log("lights: resync done failed: "))
			assert.equal(18, #c4.transfers, "the import's six GETs, then two resyncs: one for the three that waited")
			assert.is_nil(L.resync_pending)
		end)
	end)

	-- Issue #50 R6 (docs/reviews/efficiency-2026-10-24.md): the texts count
	-- new lights without sorting them; Attention sorts only to name them.
	describe("refresh cost (issue #50)", function()
		it("summary counts the new lights without sorting; attention sorts only when there are some", function()
			resync()
			local sorted = 0
			local unimported = L.unimported_models
			L.unimported_models = function(...)
				sorted = sorted + 1
				return unimported(...)
			end
			assert.equal("4 on bridge, 0 imported, 4 new, 0 missing, 0 unbound, 0 deleted", L:summary())
			assert.equal(0, sorted)
			assert.truthy(L:attention():find("^4 new lights on the bridge: Garage White %[Garage%] #4, "))
			assert.equal(1, sorted)
			L.unimported_models = nil
			import_all()
			L.unimported_models = function(...)
				sorted = sorted + 1
				return unimported(...)
			end
			sorted = 0
			assert.equal("None", L:attention())
			assert.equal(0, sorted)
			assert.equal(0, L:new_count())
		end)
	end)
end)
