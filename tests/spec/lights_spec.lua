local json = require("dkjson")
local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_resources")

describe("bridge.lights", function()
	local lights, http, c4, L, reports, logged

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

	local function new_lights(extra)
		local ctx = { http = http_ctx }
		for k, v in pairs(extra or {}) do ctx[k] = v end
		return lights.new(ctx)
	end

	local function report(text)
		table.insert(reports, text)
	end

	-- Answer the three serial GETs with the fixtures (or overrides by kind).
	local function answer_gets(overrides)
		overrides = overrides or {}
		local bodies = {
			light = overrides.light or F.light,
			device = overrides.device or F.device,
			zigbee = overrides.zigbee or F.zigbee_connectivity,
		}
		for _, kind in ipairs({ "light", "device", "zigbee" }) do
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

	local function import_all()
		L:import(report)
		answer_gets()
	end

	before_each(function()
		logged = {}
		log.sink = function(line) table.insert(logged, line) end
		log.set_debug(true) -- renames are logged at info level
		c4 = fake.install_c4()
		for _, m in ipairs({ "bridge.http", "bridge.hue_model", "bridge.lights" }) do
			package.loaded[m] = nil
		end
		http = require("bridge.http")
		lights = require("bridge.lights")
		reports = {}
		L = new_lights()
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("import", function()
		it("runs the three GETs one at a time with the key", function()
			assert.is_true(L:import(report))
			assert.equal(1, #c4.transfers)
			assert.equal("https://192.0.2.10/clip/v2/resource/light", c4.transfers[1].url)
			assert.equal("k", c4.transfers[1].headers["hue-application-key"])
			assert.equal("Importing: fetching lights", reports[1])

			c4.transfers[1]:respond(200, F.light)
			assert.equal(2, #c4.transfers)
			assert.equal("https://192.0.2.10/clip/v2/resource/device", c4.transfers[2].url)
			c4.transfers[2]:respond(200, F.device)
			assert.equal(3, #c4.transfers)
			assert.equal("https://192.0.2.10/clip/v2/resource/zigbee_connectivity", c4.transfers[3].url)
			assert.equal(0, #c4.added, "no AddDevice before all three GETs are in")
			c4.transfers[3]:respond(200, F.zigbee_connectivity)
			assert.equal(3, #c4.transfers)
			assert.equal(4, #c4.added)
		end)

		it("creates one device per light, in name order, in the bridge's room", function()
			import_all()
			assert.equal(4, #c4.added)
			for i, key in ipairs(F.by_name) do
				assert.equal("hue_light.c4z", c4.added[i].driver)
				assert.equal(7, c4.added[i].room)
				assert.equal(F.names[key], c4.added[i].name)
				assert.equal(2000 + i, c4.added[i].id)
			end
		end)

		it("binds each new light to the bridge with the HUE_BRIDGE class", function()
			import_all()
			local binds = c4.calls_to("Bind")
			assert.equal(4, #binds)
			for i = 1, 4 do
				assert.same({ 15, 1, 2000 + i, 1, "HUE_BRIDGE" }, binds[i])
			end
		end)

		it("persists the registry with device ids, names, model and caps", function()
			import_all()
			local stored = c4.persist.hue_lights
			assert.truthy(stored)
			assert.same({ device_id = 2001, name = "Garage White", model = "Hue white lamp",
				caps = { has_color = false, has_cct = false, min_dim = 5 } }, stored[F.rids.garage])
			assert.same({ device_id = 2004, name = "Living Room Lamp", model = "Hue color lamp",
				caps = { has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 0.2 } },
				stored[F.rids.living])
			assert.equal(4, L:count())
			assert.equal(2003, L:device_for(F.rids.kitchen))
			assert.equal(F.rids.kitchen, L:rid_for(2003))
			assert.is_nil(L:device_for("nope"))
		end)

		it("sends HUE_CONFIGURE then a full HUE_STATE to each new light", function()
			import_all()
			assert.same({
				"HUE_CONFIGURE@2001", "HUE_STATE@2001",
				"HUE_CONFIGURE@2002", "HUE_STATE@2002",
				"HUE_CONFIGURE@2003", "HUE_STATE@2003",
				"HUE_CONFIGURE@2004", "HUE_STATE@2004",
			}, commands_sent())
			local configure = sent_to(2004, "HUE_CONFIGURE")[1].params
			assert.same({ rid = F.rids.living, name = "Living Room Lamp", model = "Hue color lamp",
				has_color = "true", has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "0.2" }, configure)
			local state = sent_to(2004, "HUE_STATE")[1].params
			assert.same({ rid = F.rids.living, reason = "resync", on = "true", brightness = "73.52",
				x = "0.4575", y = "0.4101", mirek = "366", color_mode = "ct", online = "true" }, state)
			-- Garage White has a connectivity issue: offline, and no colour fields.
			assert.same({ rid = F.rids.garage, reason = "resync", on = "false", brightness = "100", online = "false" },
				sent_to(2001, "HUE_STATE")[1].params)
		end)

		it("reports progress and the final summary", function()
			import_all()
			assert.same({
				"Importing: fetching lights",
				"Importing: added Garage White (1 of 4)",
				"Importing: added Hallway Ambiance (2 of 4)",
				"Importing: added Kitchen Strip (3 of 4)",
				"Importing: added Living Room Lamp (4 of 4)",
				"4 lights on bridge, 4 imported, 4 new",
			}, reports)
			assert.equal("4 imported", L:summary())
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

		it("adds nothing on a second import after a restart and reports 0 new", function()
			import_all()
			local persisted = c4.persist.hue_lights
			c4.sent, c4.added, c4.calls = {}, {}, {}
			reports = {}

			L = new_lights()
			L:load()
			assert.equal(4, L:count())
			L:import(report)
			answer_gets()
			assert.equal(0, #c4.added)
			assert.equal(0, #c4.calls_to("Bind"))
			assert.equal("4 lights on bridge, 4 imported, 0 new", reports[#reports])
			assert.same(persisted, c4.persist.hue_lights)
			-- Registered lights still get CONFIGURE + STATE, in name order.
			assert.same({
				"HUE_CONFIGURE@2001", "HUE_STATE@2001",
				"HUE_CONFIGURE@2002", "HUE_STATE@2002",
				"HUE_CONFIGURE@2003", "HUE_STATE@2003",
				"HUE_CONFIGURE@2004", "HUE_STATE@2004",
			}, commands_sent())
		end)

		it("adds only the lights that are new since the last import", function()
			-- First import sees two lights; the second sees all four.
			L:import(report)
			answer_gets({ light = lights_json({ "living", "garage" }) })
			assert.equal(2, #c4.added)
			assert.equal("2 lights on bridge, 2 imported, 2 new", reports[#reports])

			c4.added = {}
			L:import(report)
			answer_gets()
			assert.equal(2, #c4.added)
			assert.equal("Hallway Ambiance", c4.added[1].name)
			assert.equal(2003, c4.added[1].id)
			assert.equal("Kitchen Strip", c4.added[2].name)
			assert.equal("4 lights on bridge, 4 imported, 2 new", reports[#reports])
		end)

		it("stops and reports when a GET fails", function()
			L:import(report)
			c4.transfers[1]:respond(401, F.unauthorized)
			assert.equal(1, #c4.transfers)
			assert.equal(0, #c4.added)
			assert.equal("Import failed: GET /clip/v2/resource/light: HTTP 401", reports[#reports])
			assert.is_false(L.importing)

			-- A transfer error on the second GET.
			L:import(report)
			c4.transfers[2]:respond(200, F.light)
			c4.transfers[3]:done(28, "Connection timed out")
			assert.equal(3, #c4.transfers)
			assert.truthy(reports[#reports]:find("^Import failed: GET /clip/v2/resource/device: transfer failed %(28%)"))
			assert.is_true(L:import(report), "a failed import releases the guard")
		end)

		it("refuses a second import while one is running", function()
			assert.is_true(L:import(report))
			assert.is_false(L:import(report))
			assert.equal("Import already running", reports[#reports])
			assert.equal(1, #c4.transfers)
			answer_gets()
			assert.equal(4, #c4.added)
			assert.is_true(L:import(report), "accepted again once finished")
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
			import_all()
			assert.equal(4, calls)
			assert.equal(3, #c4.added)
			assert.equal(3, L:count())
			assert.is_nil(L:device_for(F.rids.hallway))
			assert.equal("4 lights on bridge, 3 imported, 3 new", reports[#reports])
		end)

		it("binds the protocol id when the callback info exposes one", function()
			L = new_lights({
				add_device = function(_, _, _, cb)
					cb(3001, { proxyIds = { 3001 }, protocolId = 3002 })
				end,
			})
			L:import(report)
			answer_gets({ light = lights_json({ "living" }) })
			assert.same({ { 15, 1, 3002, 1, "HUE_BRIDGE" } }, c4.calls_to("Bind"))
			assert.is_true(saw_log("binding protocol id 3002 rather than deviceId 3001"))
			assert.equal(3002, L:device_for(F.rids.living))
		end)

		it("logs registered lights that are gone from the bridge and leaves them alone", function()
			import_all()
			c4.added = {}
			L:import(report)
			answer_gets({ light = lights_json({ "living", "kitchen", "hallway" }) })
			assert.equal(0, #c4.added)
			assert.equal(2001, L:device_for(F.rids.garage))
			assert.is_true(saw_log("Garage White (device 2001) is registered but no longer on the bridge"))
			assert.equal("3 lights on bridge, 4 imported, 0 new", reports[#reports])
		end)

		it("logs a Hue rename and refreshes the registry name", function()
			import_all()
			L:import(report)
			answer_gets({ light = F.light:gsub("Garage White", "Garage Lamp") })
			assert.is_true(saw_log("Garage White was renamed to Garage Lamp in Hue"))
			assert.equal("Garage Lamp", c4.persist.hue_lights[F.rids.garage].name)
			assert.equal(0, #c4.calls_to("RenameDevice"))
		end)
	end)

	describe("on_container", function()
		local function container(text)
			return C4:JsonDecode(text)[1]
		end

		before_each(function()
			import_all()
			c4.sent = {}
		end)

		it("fans out only the changed fields of a light event with reason event", function()
			assert.equal(1, L:on_container(container(F.events.brightness)))
			assert.equal(1, #c4.sent)
			assert.equal(2004, c4.sent[1].id)
			assert.equal("HUE_STATE", c4.sent[1].command)
			assert.same({ rid = F.rids.living, brightness = "50", reason = "event" }, c4.sent[1].params)
		end)

		it("sends the colour fields with the derived mode", function()
			assert.equal(1, L:on_container(container(F.events.color)))
			assert.same({ rid = F.rids.living, x = "0.1532", y = "0.0475", color_mode = "xy", reason = "event" },
				c4.sent[1].params)
			assert.equal("xy", L.models[F.rids.living].color_mode)
		end)

		it("ignores items that are not registered lights", function()
			assert.equal(1, L:on_container(container(F.events.off)), "grouped_light item is skipped")
			assert.equal(2001, c4.sent[1].id)
			assert.same({ rid = F.rids.garage, on = "false", reason = "event" }, c4.sent[1].params)
			assert.equal(0, L:on_container(container(F.events.add)))
			assert.equal(0, L:on_container({ type = "update",
				data = { { id = "unknown", type = "light", on = { on = true } } } }))
			assert.equal(0, L:on_container({}))
			assert.equal(1, #c4.sent)
		end)

		it("sends nothing for an event that touches no reported field", function()
			assert.equal(0, L:on_container(container(F.events.noop)))
			assert.equal(0, #c4.sent)
		end)

		it("fans a zigbee_connectivity event out to the device's lights as online", function()
			assert.equal(1, L:on_container(container(F.events.connectivity)))
			assert.equal(2001, c4.sent[1].id)
			assert.same({ rid = F.rids.garage, online = "true", reason = "event" }, c4.sent[1].params)
			assert.is_true(L.models[F.rids.garage].online)
		end)
	end)

	describe("resync", function()
		it("sends CONFIGURE then full STATE the first time, STATE only after that", function()
			import_all()
			c4.sent = {}
			local results = {}
			L:resync(function(...) table.insert(results, { ... }) end)
			answer_gets()
			assert.same({ { true, nil, 4 } }, results)
			assert.same({
				"HUE_CONFIGURE@2001", "HUE_STATE@2001",
				"HUE_CONFIGURE@2002", "HUE_STATE@2002",
				"HUE_CONFIGURE@2003", "HUE_STATE@2003",
				"HUE_CONFIGURE@2004", "HUE_STATE@2004",
			}, commands_sent())
			assert.equal("resync", c4.sent[2].params.reason)

			c4.sent = {}
			L:resync(function(...) table.insert(results, { ... }) end)
			answer_gets()
			assert.same({ "HUE_STATE@2001", "HUE_STATE@2002", "HUE_STATE@2003", "HUE_STATE@2004" }, commands_sent())
			assert.equal(2, #results)
		end)

		it("works from the persisted registry after a restart and refreshes caps", function()
			import_all()
			c4.persist.hue_lights[F.rids.hallway].caps.mirek_max = 400 -- stale, as if the bulb's firmware changed
			L = new_lights()
			L:load()
			c4.sent = {}
			L:resync()
			answer_gets()
			assert.equal(8, #c4.sent)
			assert.equal("454", sent_to(2002, "HUE_CONFIGURE")[1].params.mirek_max)
			assert.equal(454, c4.persist.hue_lights[F.rids.hallway].caps.mirek_max)
		end)

		it("reports a failed GET without touching the lights", function()
			import_all()
			c4.sent = {}
			local results = {}
			L:resync(function(...) table.insert(results, { ... }) end)
			c4.last_transfer():respond(503, "")
			assert.same({ { false, "GET /clip/v2/resource/light: HTTP 503" } }, results)
			assert.equal(0, #c4.sent)
			assert.is_false(L.configured_once)
		end)

		it("runs once more when asked again while running", function()
			import_all()
			local results = {}
			L:resync(function(ok) table.insert(results, ok) end)
			L:resync(function(ok) table.insert(results, ok) end)
			assert.equal(4, #c4.transfers, "the second resync waits")
			answer_gets()
			assert.same({ true }, results)
			assert.equal(7, #c4.transfers, "then runs")
			answer_gets()
			assert.same({ true, true }, results)
		end)
	end)

	describe("configure_all and hello", function()
		it("configures every registered light from the persisted caps before any GET", function()
			import_all()
			L = new_lights()
			L:load()
			c4.sent = {}
			assert.equal(4, L:configure_all())
			assert.same({ "HUE_CONFIGURE@2001", "HUE_CONFIGURE@2002", "HUE_CONFIGURE@2003", "HUE_CONFIGURE@2004" },
				commands_sent())
			assert.same({ rid = F.rids.hallway, name = "Hallway Ambiance", model = "Hue ambiance lamp",
				has_color = "false", has_cct = "true", mirek_min = "153", mirek_max = "454", min_dim = "0.2" },
				c4.sent[2].params)
			-- The first resync after that sends state only.
			c4.sent = {}
			L:resync()
			answer_gets()
			assert.same({ "HUE_STATE@2001", "HUE_STATE@2002", "HUE_STATE@2003", "HUE_STATE@2004" }, commands_sent())
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

		it("answers hello with CONFIGURE and full STATE for a known light", function()
			import_all()
			c4.sent = {}
			assert.is_true(L:hello(F.rids.kitchen))
			assert.same({ "HUE_CONFIGURE@2003", "HUE_STATE@2003" }, commands_sent())
			assert.equal("hello", c4.sent[2].params.reason)
			assert.equal("xy", c4.sent[2].params.color_mode)
		end)

		it("returns false for an unknown, empty or missing rid", function()
			import_all()
			c4.sent = {}
			assert.is_false(L:hello("not-a-light"))
			assert.is_false(L:hello(""))
			assert.is_false(L:hello(nil))
			assert.equal(0, #c4.sent)
			-- Registered but not yet modelled (startup before the first GET).
			L = new_lights()
			L:load()
			assert.is_false(L:hello(F.rids.kitchen))
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

		it("uses the real C4 calls when ctx leaves them out", function()
			L = lights.new({ http = http_ctx })
			import_all()
			assert.equal(4, #c4.calls_to("AddDevice"))
			assert.equal(4, #c4.calls_to("Bind"))
			assert.equal(8, #c4.calls_to("SendToDevice"))
			assert.truthy(c4.calls_to("PersistSetValue")[1])
			assert.equal("hue_lights", c4.calls_to("PersistSetValue")[1][1])
		end)
	end)
end)
