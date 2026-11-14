-- Lamps that stream (2.0 beta stage 1, #514; docs/hdmi-sync-stage1-design.md
-- §4.5, docs/hdmi-sync-contracts.md C7): the lights module tells the
-- entertainment module of every change of a lamp's `streaming` before that
-- lamp's HUE_STATE, settles it once per event container and per fetch, puts
-- the stream label next to streaming "true", never tells a streaming lamp's
-- device it is offline, and answers is_streaming for driver.lua's guard.
--
-- The entertainment module is a stub here (bridge/entertainment.lua is built
-- beside this change); the light items with `mode` are built from the
-- fixture in this file (docs/entertainment-areas-research.md §4.1: `mode` is
-- "streaming" or "normal").

local json = require("dkjson")
local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_resources")

-- Device ids after import_all() (as in lights_spec): Garage White, Hallway
-- Ambiance and Living Room Lamp by Import All New in name order, Kitchen
-- Strip by Add Light.
local ID = { garage = 2001, hallway = 2002, living = 2003, kitchen = 2004 }
local GARAGE_ROOM, LIVING_ROOM = 8, 7
local LIVING = F.rids.living
local T0 = 1761000000
local DAY = 24 * 3600

describe("bridge.lights while lamps stream (#514)", function()
	local lights, http, c4, L, ent, logged, now, timeline

	local function http_ctx(req, cb)
		req.ip = "10.0.2.143"
		req.key = "k"
		return http.request(req, cb)
	end

	-- The entertainment module's calls this module makes, recorded in the
	-- timeline next to the messages to the devices.
	local function stub_entertainment()
		local e = { modes = {}, settles = 0, labels = 0 }
		function e:lamp_mode(rid, streaming, before)
			self.modes[#self.modes + 1] = { rid = rid, streaming = streaming, before = before }
			timeline[#timeline + 1] = "lamp_mode@" .. rid
		end
		function e:settle()
			self.settles = self.settles + 1
			timeline[#timeline + 1] = "settle"
		end
		function e:stream_label()
			self.labels = self.labels + 1
			return "another app"
		end
		return e
	end

	local function new_lights(extra)
		local ctx = {
			http = http_ctx,
			now = function() return now end,
			send = function(id, command, params)
				timeline[#timeline + 1] = command .. "@" .. id
				C4:SendToDevice(id, command, params)
			end,
		}
		for k, v in pairs(extra or {}) do ctx[k] = v end
		return lights.new(ctx)
	end

	-- The light fixture with `mode` set per key ("streaming", "normal", or
	-- false to drop it); `without` leaves a light out altogether.
	local function light_body(modes, without)
		local doc = json.decode(F.light)
		local data = {}
		for _, item in ipairs(doc.data) do
			local keep = true
			for key, rid in pairs(F.rids) do
				if item.id == rid then
					if modes[key] ~= nil then item.mode = modes[key] or nil end
					if without == key then keep = false end
				end
			end
			if keep then data[#data + 1] = item end
		end
		doc.data = data
		return json.encode(doc)
	end

	-- Answer the six serial GETs with the fixtures, the light list as given.
	local function answer_gets(light)
		local bodies = { light = light or F.light, device = F.device, zigbee = F.zigbee_connectivity, room = F.room,
			zone = F.zone, bridge_home = F.bridge_home }
		for _, kind in ipairs({ "light", "device", "zigbee", "room", "zone", "bridge_home" }) do
			local t = c4.last_transfer()
			assert.truthy(t, "expected a GET for " .. kind)
			assert.equal("GET", t.method)
			t:respond(200, bodies[kind])
		end
	end

	local function import_all()
		L:import_new()
		answer_gets()
		L:add_light(F.rids.kitchen, LIVING_ROOM)
	end

	local function resync(light)
		L:resync()
		answer_gets(light)
	end

	local function sent_to(device_id, command)
		local out = {}
		for _, m in ipairs(c4.sent) do
			if m.id == device_id and (command == nil or m.command == command) then out[#out + 1] = m end
		end
		return out
	end

	local function index_of(entry)
		for i, e in ipairs(timeline) do
			if e == entry then return i end
		end
		return nil
	end

	local function saw_log(text)
		for _, line in ipairs(logged) do
			if line:find(text, 1, true) then return true end
		end
		return false
	end

	local function light_event(fields, kind)
		local item = { id = LIVING, type = "light" }
		for k, v in pairs(fields) do item[k] = v end
		return L:on_container({ type = kind or "update", data = { item } })
	end

	local function connectivity_event(key, status)
		return L:on_container({ type = "update", data = { { id = F.zigbee_rids[key], type = "zigbee_connectivity",
			owner = { rid = F.device_rids[key], rtype = "device" }, status = status } } })
	end

	-- What the steps after it did: the recordings cleared.
	local function clear()
		c4.sent, timeline = {}, {}
		ent.modes, ent.settles, ent.labels = {}, 0, 0
	end

	before_each(function()
		logged = {}
		log.sink = function(line) table.insert(logged, line) end
		log.set_debug(true)
		now = T0
		timeline = {}
		c4 = fake.install_c4()
		fake.add_room(GARAGE_ROOM, "Garage")
		for _, m in ipairs({ "bridge.http", "bridge.hue_model", "bridge.registry", "bridge.groups", "bridge.lights" }) do
			package.loaded[m] = nil
		end
		http = require("bridge.http")
		lights = require("bridge.lights")
		ent = stub_entertainment()
		L = new_lights({ entertainment = ent })
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("lamp_mode", function()
		it("is not called for lamps that do not stream: nil to false is no change", function()
			import_all()
			assert.same({}, ent.modes)
			assert.is_false(L.models[LIVING].streaming, "the fixture's mode normal")
		end)

		it("is called at a fetch's change, with the model from before, before that light's HUE_STATE", function()
			import_all()
			clear()
			resync(light_body({ living = "streaming" }))
			assert.equal(1, #ent.modes)
			local call = ent.modes[1]
			assert.equal(LIVING, call.rid)
			assert.is_true(call.streaming)
			assert.is_false(call.before.streaming)
			assert.equal(73.52, call.before.brightness)
			assert.is_true(call.before.on)
			assert.are_not.equal(L.models[LIVING], call.before, "a copy, not the live model")
			assert.truthy(index_of("HUE_STATE@" .. ID.living))
			assert.is_true(index_of("lamp_mode@" .. LIVING) < index_of("HUE_STATE@" .. ID.living))
			assert.equal(1, ent.settles)
			assert.equal("settle", timeline[#timeline], "after the fan-out")
		end)

		it("is called with no before at first sight (a reload in the middle of a sync)", function()
			import_all()
			c4.sent, timeline = {}, {}
			ent = stub_entertainment()
			L = new_lights({ entertainment = ent })
			L:load()
			resync(light_body({ living = "streaming", garage = "streaming" }))
			assert.equal(2, #ent.modes)
			-- In rid order: Living Room Lamp (0b21…) before Garage White (9a8b…).
			assert.same({ LIVING, F.rids.garage }, { ent.modes[1].rid, ent.modes[2].rid })
			for _, call in ipairs(ent.modes) do
				assert.is_true(call.streaming)
				assert.is_nil(call.before)
			end
			assert.is_true(index_of("lamp_mode@" .. LIVING) < index_of("HUE_STATE@" .. ID.living))
			assert.is_true(index_of("lamp_mode@" .. F.rids.garage) < index_of("HUE_STATE@" .. ID.garage))
			assert.equal(1, ent.settles)
		end)

		it("is called for a lamp Control4 has no device for, which hears nothing", function()
			resync(light_body({ hallway = "streaming" }))
			assert.equal(1, #ent.modes)
			assert.equal(F.rids.hallway, ent.modes[1].rid)
			assert.same({}, c4.sent)
			assert.equal(1, ent.settles)
		end)

		it("is called when an event starts a stream, with the state from before the item", function()
			import_all()
			clear()
			assert.equal(1, light_event({ mode = "streaming", on = { on = false } }))
			assert.equal(1, #ent.modes)
			local call = ent.modes[1]
			assert.equal(LIVING, call.rid)
			assert.is_true(call.streaming)
			assert.is_true(call.before.on, "the pre-sync state: on")
			assert.is_false(call.before.streaming)
			assert.is_false(L.models[LIVING].on)
			assert.same({ "lamp_mode@" .. LIVING, "HUE_STATE@" .. ID.living, "settle" }, timeline)
			assert.same({ rid = LIVING, reason = "event", on = "false", streaming = "true", stream_label = "another app",
				online = "true" }, c4.sent[1].params)
		end)

		it("is called when an event ends a stream, and the HUE_STATE carries no label then", function()
			import_all()
			light_event({ mode = "streaming" })
			clear()
			assert.equal(1, light_event({ mode = "normal" }))
			assert.equal(1, #ent.modes)
			assert.is_false(ent.modes[1].streaming)
			assert.is_true(ent.modes[1].before.streaming)
			assert.same({ "lamp_mode@" .. LIVING, "HUE_STATE@" .. ID.living, "settle" }, timeline)
			assert.same({ rid = LIVING, reason = "event", streaming = "false", online = "true" }, c4.sent[1].params)
			assert.equal(0, ent.labels)
		end)

		it("is not called again for the same mode, nor for an event without one", function()
			import_all()
			light_event({ mode = "streaming" })
			clear()
			light_event({ mode = "streaming" })
			light_event({ dimming = { brightness = 40 } })
			assert.same({}, ent.modes)
			assert.equal(2, ent.settles)
		end)

		it("is called when a fetch finds the stream over, or the lamp gone", function()
			import_all()
			resync(light_body({ living = "streaming", kitchen = "streaming" }))
			clear()
			resync(light_body({ living = "normal", kitchen = "streaming" }, "kitchen"))
			assert.equal(2, #ent.modes)
			-- In rid order: Living Room Lamp (0b21…) before Kitchen Strip (7f3c…).
			assert.same({ LIVING, false }, { ent.modes[1].rid, ent.modes[1].streaming })
			assert.same({ F.rids.kitchen, false }, { ent.modes[2].rid, ent.modes[2].streaming })
			assert.is_true(ent.modes[2].before.streaming)
			assert.equal(1, ent.settles)
		end)

		it("is called when a streaming lamp is deleted, before its device hears it is gone", function()
			import_all()
			light_event({ mode = "streaming" })
			clear()
			light_event({}, "delete")
			assert.equal(1, #ent.modes)
			assert.is_false(ent.modes[1].streaming)
			assert.is_true(ent.modes[1].before.streaming)
			assert.same({ "lamp_mode@" .. LIVING, "HUE_CONFIGURE@" .. ID.living, "HUE_STATE@" .. ID.living, "settle" },
				timeline)
		end)

		it("is called when a lamp is added back streaming", function()
			import_all()
			light_event({}, "delete")
			clear()
			local item = json.decode(light_body({ living = "streaming" })).data[1]
			assert.equal(LIVING, item.id)
			L:on_container({ type = "add", data = { item } })
			assert.equal(1, #ent.modes)
			assert.is_true(ent.modes[1].streaming)
			assert.is_true(index_of("lamp_mode@" .. LIVING) < index_of("HUE_STATE@" .. ID.living))
		end)
	end)

	describe("settle", function()
		it("runs once per event container, whatever it holds", function()
			import_all()
			clear()
			light_event({ mode = "streaming" })
			light_event({ dimming = { brightness = 40 } })
			connectivity_event("living", "connected")
			L:on_container({ type = "update", data = { { id = "x", type = "grouped_light" } } })
			L:on_container({})
			L:on_container(nil)
			assert.equal(6, ent.settles)
		end)

		it("runs once per fetch: an import, a resync", function()
			import_all()
			assert.equal(1, ent.settles, "Import All New's fetch; Add Light fetches nothing")
			resync()
			assert.equal(2, ent.settles)
		end)

		it("runs after a container whose handler failed, which still raises", function()
			import_all()
			clear()
			L.on_light_item = function() error("boom") end
			assert.has_error(function() light_event({ mode = "streaming" }) end)
			assert.equal(1, ent.settles)
		end)
	end)

	describe("HUE_STATE", function()
		it("carries streaming false while the lamp does not stream, and no label", function()
			import_all()
			local state = sent_to(ID.living, "HUE_STATE")[1].params
			assert.equal("false", state.streaming)
			assert.is_nil(state.stream_label)
			assert.equal(0, ent.labels)
		end)

		it("carries the stream label next to streaming true in the full state, and loses it after", function()
			import_all()
			light_event({ mode = "streaming" })
			clear()
			assert.is_true(L:hello(LIVING, { device_id = tostring(ID.living) }))
			local state = sent_to(ID.living, "HUE_STATE")[1].params
			assert.equal("hello", state.reason)
			assert.equal("true", state.streaming)
			assert.equal("another app", state.stream_label)
			assert.equal("73.52", state.brightness, "the state from before the stream")
			light_event({ mode = "normal" })
			clear()
			L:hello(LIVING, { device_id = tostring(ID.living) })
			state = sent_to(ID.living, "HUE_STATE")[1].params
			assert.equal("false", state.streaming)
			assert.is_nil(state.stream_label)
		end)

		it("carries the label in a resync's full state", function()
			import_all()
			clear()
			resync(light_body({ living = "streaming" }))
			local state = sent_to(ID.living, "HUE_STATE")[1].params
			assert.same({ "true", "another app" }, { state.streaming, state.stream_label })
			assert.equal("false", sent_to(ID.hallway, "HUE_STATE")[1].params.streaming)
			assert.is_nil(sent_to(ID.hallway, "HUE_STATE")[1].params.stream_label)
		end)

		it("carries the label as a display name, and none when the module gives none", function()
			import_all()
			ent.stream_label = function() return "  Living Room sync box\n" end
			light_event({ mode = "streaming" })
			assert.equal("Living Room sync box", c4.sent[#c4.sent].params.stream_label)
			light_event({ mode = "normal" })
			ent.stream_label = function() return nil end
			light_event({ mode = "streaming" })
			assert.equal("true", c4.sent[#c4.sent].params.streaming)
			assert.is_nil(c4.sent[#c4.sent].params.stream_label)
		end)
	end)

	describe("offline while streaming", function()
		it("never tells the device offline during the stream, and tells it when the stream ends", function()
			import_all()
			light_event({ mode = "streaming" })
			clear()
			assert.equal(0, connectivity_event("living", "connectivity_issue"))
			assert.same({}, c4.sent)
			assert.is_false(L.models[LIVING].online, "the model keeps Hue's report")
			assert.is_nil(L.offline_since[LIVING])
			assert.is_true(saw_log("Living Room Lamp #1 (device 2003) is reported not connected while it streams; "
				.. "its device stays online until the stream ends"))
			-- Its full state leaves the online out, too.
			L:hello(LIVING, { device_id = tostring(ID.living) })
			assert.is_nil(sent_to(ID.living, "HUE_STATE")[1].params.online)
			-- A day later: no Attention nag for it (Garage White, offline since
			-- the import, has one).
			now = T0 + DAY + 60
			local attention = L:attention()
			assert.truthy(attention:find("offline for more than 24 h: Garage White", 1, true), attention)
			assert.is_nil(attention:find("Living Room Lamp", 1, true), attention)
			-- The stream ends: the device hears Hue's report, and the clock starts.
			clear()
			light_event({ mode = "normal" })
			assert.same({ rid = LIVING, reason = "event", streaming = "false", online = "false" }, c4.sent[1].params)
			assert.equal(now, L.offline_since[LIVING])
		end)

		it("tells the device online during the stream", function()
			import_all()
			light_event({ mode = "streaming" })
			connectivity_event("living", "connectivity_issue")
			clear()
			assert.equal(1, connectivity_event("living", "connected"))
			assert.same({ rid = LIVING, reason = "event", online = "true" }, c4.sent[1].params)
		end)

		it("stops the offline clock of a lamp that was offline before the stream, until it ends", function()
			import_all()
			assert.equal(T0, L.offline_since[F.rids.garage], "Garage White has a connectivity issue")
			clear()
			now = T0 + 3600
			resync(light_body({ garage = "streaming" }))
			local state = sent_to(ID.garage, "HUE_STATE")[1].params
			assert.equal("true", state.streaming)
			assert.is_nil(state.online)
			assert.is_nil(L.offline_since[F.rids.garage])
			now = T0 + 2 * DAY
			assert.is_nil(L:attention():find("offline for more than 24 h", 1, true))
			clear()
			resync(light_body({ garage = "normal" }))
			assert.equal("false", sent_to(ID.garage, "HUE_STATE")[1].params.online)
			assert.equal(T0 + 2 * DAY, L.offline_since[F.rids.garage], "counted afresh from the end of the stream")
		end)

		it("holds without the entertainment module", function()
			L = new_lights()
			import_all()
			c4.sent = {}
			light_event({ mode = "streaming" })
			assert.same({ rid = LIVING, reason = "event", streaming = "true", online = "true" }, c4.sent[1].params)
			c4.sent = {}
			assert.equal(0, connectivity_event("living", "connectivity_issue"))
			assert.same({}, c4.sent)
			assert.is_nil(L.offline_since[LIVING])
		end)
	end)

	describe("is_streaming", function()
		it("is true only while Hue reports the lamp streaming", function()
			assert.is_false(L:is_streaming(LIVING), "no model yet")
			assert.is_false(L:is_streaming(nil))
			import_all()
			assert.is_false(L:is_streaming(LIVING))
			assert.is_false(L:is_streaming("unknown"))
			light_event({ mode = "streaming" })
			assert.is_true(L:is_streaming(LIVING))
			assert.is_false(L:is_streaming(F.rids.kitchen))
			light_event({ mode = "normal" })
			assert.is_false(L:is_streaming(LIVING))
		end)
	end)

	describe("ctx.entertainment", function()
		it("may be a function, read at each use", function()
			local current
			L = new_lights({ entertainment = function() return current end })
			import_all()
			light_event({ mode = "streaming" })
			assert.same({}, ent.modes, "nothing to call yet")
			assert.is_nil(c4.sent[#c4.sent].params.stream_label)
			current = ent
			light_event({ mode = "normal" })
			light_event({ mode = "streaming" })
			assert.equal(2, #ent.modes)
			assert.equal("another app", c4.sent[#c4.sent].params.stream_label)
		end)

		it("failing is logged, and the light still hears its state", function()
			import_all()
			clear()
			ent.lamp_mode = function() error("lamp_mode broke") end
			ent.settle = function() error("settle broke") end
			ent.stream_label = function() error("stream_label broke") end
			assert.equal(1, light_event({ mode = "streaming" }))
			assert.same({ rid = LIVING, reason = "event", streaming = "true", online = "true" }, c4.sent[1].params)
			assert.is_true(saw_log("entertainment lamp_mode failed"))
			assert.is_true(saw_log("entertainment settle failed"))
			assert.is_true(saw_log("entertainment stream_label failed"))
		end)
	end)
end)
