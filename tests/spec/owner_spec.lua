-- bridge/owner.lua: the lifecycle the lights, the scenes and the zone lights
-- share (issue #56, docs/lifecycle-refactor-design.md). The three modules'
-- own specs pin their behaviour end to end through the base; this file
-- pins the base's wiring and the four behaviour changes the refactor made on
-- purpose (docs/review-leftovers-design.md §5): the zone lights answer every
-- waiting resync caller, mark a zone deleted while its AddDevice was pending
-- gone, give the registry their field schema, and a refresh clears a field
-- whose value became nil (analysis R9).

local json = require("dkjson")
local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_resources")

local T0 = 1761000000
local GARAGE_ROOM = 8

-- What every module gives bridge/owner.lua (its header lists them).
local WORDS = { "held", "stranger", "goodbye_tail", "add_action", "busy_job", "busy_resync", "kind", "unbound_kind",
	"relink_or_forget", "forget_action", "name_kind", "hue_names", "device_noun", "name_difference", "callback_kind",
	"registered", "relink_target", "forget_tail", "link_noun", "link_many", "link_one", "link_none" }
local HOOKS = { "entry_label", "creation_name", "configure_params", "send_state", "state_known", "announce_gone",
	"record_of", "fields_of", "hello_fields", "fetched", "adopted_label", "announcement", "conflict_label",
	"device_text", "room_group_of", "add_label", "fetch_all", "absorb", "settle", "relink_refusal", "record_label",
	"linked_label", "link_candidates", "unimported_named" }

-- Plain-text replacement: rids and MACs contain pattern characters.
local function replace(text, from, to)
	local escaped = from:gsub("%W", "%%%0")
	local out, n = text:gsub(escaped, (to:gsub("%%", "%%%%")))
	assert(n > 0, "fixture text not found: " .. from)
	return out
end

describe("bridge.owner", function()
	local owner, lights, scenes, zone_lights, logged, store, sent, bound

	local function data(text)
		return json.decode(text).data
	end

	local function saw_log(text)
		for _, line in ipairs(logged) do
			if line:find(text, 1, true) then return true end
		end
		return false
	end

	local function commands()
		local out = {}
		for _, m in ipairs(sent) do
			out[#out + 1] = m.command .. "@" .. m.id
		end
		return out
	end

	-- The project as driver.lua's project_calls would answer it: the Garage
	-- room, `bound` as the bound set, no device list (unknown).
	local function project_calls()
		return {
			rooms = function() return { [GARAGE_ROOM] = "Garage" } end,
			hierarchy = function() return {} end,
			devices = function() return nil end,
			bound = function() return bound end,
			unbind = function() end,
			rename = function() end,
			display_name = function() return nil end,
		}
	end

	local function ctx(extra)
		local c = {
			http = function() error("no request expected") end,
			send = function(id, command, params) sent[#sent + 1] = { id = id, command = command, params = params } end,
			add_device = function() error("no AddDevice expected") end,
			bind = function() end,
			now = function() return T0 end,
			persist_get = function(key) return store[key] end,
			persist_set = function(key, value) store[key] = value end,
			project = project_calls(),
			bridge_id = 100,
			room_id = 1,
		}
		for k, v in pairs(extra or {}) do c[k] = v end
		return c
	end

	-- The lights' GETs, decoded, with some fixture bodies replaced.
	local function resources(overrides)
		local res = { light = F.light, device = F.device, zigbee = F.zigbee_connectivity, room = F.room, zone = F.zone,
			bridge_home = F.bridge_home }
		for k, v in pairs(overrides or {}) do res[k] = v end
		for k, v in pairs(res) do res[k] = data(v) end
		return res
	end

	local function new_lights(extra, overrides)
		local L = lights.new(ctx(extra))
		L:load()
		L:absorb(resources(overrides))
		return L
	end

	local function new_zone_lights(L, extra)
		local c = { lights = L, group_set = function() return true end, group_dim = function() return true end }
		for k, v in pairs(extra or {}) do c[k] = v end
		return zone_lights.new(ctx(c))
	end

	-- Register `rid` of module M (lights, scenes or zone lights) for device
	-- `id` from its record, as an AddDevice would.
	local function register(M, rid, id, extra)
		local fields = M:fields_of(M:record_of(rid))
		fields.device_id, fields.proxy_id = id, id + 1000
		for k, v in pairs(extra or {}) do fields[k] = v end
		assert.truthy(M.reg:add(rid, fields))
	end

	before_each(function()
		logged, store, sent, bound = {}, {}, {}, {}
		log.sink = function(line) logged[#logged + 1] = line end
		log.set_debug(true)
		fake.install_c4()
		for _, m in ipairs({ "bridge.owner", "bridge.registry", "bridge.hue_model", "bridge.groups", "bridge.util",
			"bridge.project", "bridge.lights", "bridge.scenes", "bridge.zone_lights" }) do
			package.loaded[m] = nil
		end
		owner = require("bridge.owner")
		lights = require("bridge.lights")
		scenes = require("bridge.scenes")
		zone_lights = require("bridge.zone_lights")
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("the modules on the base", function()
		it("fall through to it and give it every word, message, option table and hook it reads", function()
			for _, M in ipairs({ lights, scenes, zone_lights }) do
				assert.equal(owner, getmetatable(M).__index, M.TAG)
				assert.is_string(M.TAG)
				assert.is_string(M.DEVICE_DRIVER)
				assert.equal(1, M.BINDING)
				assert.equal("HUE_BRIDGE", M.BINDING_CLASS)
				assert.equal(3, M.MAX_NAMED)
				assert.equal("resyncing", M.BUSY_FLAGS[2])
				assert.is_table(M.OPTIONS)
				for _, key in ipairs(WORDS) do
					assert.is_string(M.WORDS[key], M.TAG .. " WORDS." .. key)
				end
				for _, key in ipairs({ "configure", "hello", "goodbye", "forgotten" }) do
					assert.is_string(M.MESSAGES[key], M.TAG .. " MESSAGES." .. key)
				end
				for _, hook in ipairs(HOOKS) do
					assert.is_function(M[hook], M.TAG .. ":" .. hook)
				end
			end
			assert.same({ "hue_light.c4z", "hue_scene.c4z", "hue_light.c4z" },
				{ lights.DEVICE_DRIVER, scenes.DEVICE_DRIVER, zone_lights.DEVICE_DRIVER })
			assert.same({ "importing", "adding", "adding" }, { lights.BUSY_FLAGS[1], scenes.BUSY_FLAGS[1],
				zone_lights.BUSY_FLAGS[1] })
			assert.equal(owner.ids_from, lights.ids_from, "the AddDevice shapes keep their lights.* names")
			assert.equal(owner.dump, lights.dump)
		end)

		it("speak each module's words: the busy texts", function()
			local L = new_lights()
			local S = scenes.new(ctx({ lights = L }))
			local Z = new_zone_lights(L)
			L.importing, L.importing_since = true, os.time()
			S.adding, S.adding_since = true, os.time()
			Z.resyncing, Z.resyncing_since = true, os.time()
			assert.equal("Busy: importing; try again in a moment", L:busy_text())
			assert.equal("Busy: adding scenes; try again in a moment", S:busy_text())
			assert.equal("Busy: resyncing zone lights; try again in a moment", Z:busy_text())
			assert.same({ false, "Busy: resyncing zone lights; try again in a moment" }, { Z:forget(2001) })
		end)
	end)

	describe("helpers", function()
		it("hello_text keeps only non-empty strings (R11)", function()
			assert.equal("Lamp", owner.hello_text("Lamp"))
			assert.is_nil(owner.hello_text(""))
			assert.is_nil(owner.hello_text(42))
			assert.is_nil(owner.hello_text({}))
		end)

		it("created_set is the rids a creation registered", function()
			assert.same({ a = true, b = true }, owner.created_set({ { record = { rid = "a" } }, { record = { rid = "b" } } }))
			assert.same({}, owner.created_set({}))
			assert.same({}, owner.created_set(nil))
		end)

		it("refresh_fields updates what changed and clears the listed fields the record no longer supplies", function()
			local L = new_lights()
			local rid = F.rids.garage
			register(L, rid, 2001)
			local entry = L.registry[rid]
			assert.is_false(L:refresh_fields(rid, { model = entry.model, id_v1 = entry.id_v1 }, { "id_v1" }))
			assert.is_true(L:refresh_fields(rid, { model = "Hue lamp v2" }, { "device_name" }))
			assert.equal("Hue lamp v2", entry.model)
			assert.is_nil(entry.device_name)
			assert.equal("/lights/4", entry.id_v1, "a field not listed stays when the record has none")
		end)
	end)

	-- §5 item 1: until 2026-10-25 the zone lights kept only the latest waiting
	-- done (zone_lights_spec has the success case).
	describe("the zone lights' waiting resyncs", function()
		it("each hear a failed GET once, after the groups were still settled against the cache", function()
			local answers = {}
			local Z = new_zone_lights(new_lights(), {
				http = function(req, cb) answers[#answers + 1] = { req = req, cb = cb } end,
			})
			Z:load()
			local got = {}
			Z:resync(function(ok, err, n) got[#got + 1] = { "first", ok, err, n } end)
			Z:resync(function(ok, err, n) got[#got + 1] = { "second", ok, err, n } end)
			Z:resync(function(ok, err, n) got[#got + 1] = { "third", ok, err, n } end)
			assert.equal(1, #answers)
			assert.equal("/clip/v2/resource/grouped_light", answers[1].req.path)
			answers[1].cb({ ok = true, json = { data = data(F.grouped_light) } })
			assert.same({ { "first", true, nil, 0 } }, got)
			assert.equal(2, #answers, "one more resync for the two that waited")
			answers[2].cb({ ok = false, err = "HTTP 503" })
			assert.same({ { "first", true, nil, 0 },
				{ "second", false, "GET /clip/v2/resource/grouped_light: HTTP 503", 0 },
				{ "third", false, "GET /clip/v2/resource/grouped_light: HTTP 503", 0 } }, got)
			assert.equal(2, #answers)
			assert.is_nil(Z.resync_pending)
			assert.is_false(Z.resyncing)
		end)
	end)

	-- §5 item 2: code analysis 2026-10-22 R6, as lights.lua has done since #48.
	describe("a zone deleted in Hue while its AddDevice is pending", function()
		local L, Z, pending, result

		before_each(function()
			L = new_lights()
			Z = new_zone_lights(L, { add_device = function(driver, room_id, name, cb)
				pending = { driver = driver, room_id = room_id, name = name, cb = cb }
			end })
			Z:load()
			Z:resync(function() end, data(F.grouped_light))
			result = nil
			assert.is_true(Z:add(F.group_rids.downstairs, GARAGE_ROOM, function(ok, text) result = { ok, text } end))
			assert.same({ "hue_light.c4z", GARAGE_ROOM, "Downstairs" }, { pending.driver, pending.room_id, pending.name })
		end)

		it("is registered gone when the AddDevice answers, and its device is told so", function()
			for _, c in ipairs(C4:JsonDecode(F.events.zone_deleted)) do
				L:on_container(c)
				Z:on_container(c)
			end
			sent = {}
			pending.cb(2001, nil)
			local entry = Z:entry(F.group_rids.downstairs)
			assert.equal("gone", entry.state)
			assert.equal(T0, entry.gone_since)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands())
			assert.equal("gone", sent[1].params.state)
			assert.same({ rid = F.group_rids.downstairs, online = "false", reason = "resync" }, sent[2].params)
			assert.is_true(saw_log("zone_lights: Downstairs (zone) (device 2001) was deleted on the bridge while its device "
				.. "was being added; marked gone (Re-link Zone Light or Forget Light)"))
			assert.same({ true, "Added Downstairs (zone) to Garage (device 2001)" }, result)
			assert.equal("gone", store.hue_zone_lights[F.group_rids.downstairs].state, "saved")
			assert.equal("1 zone light missing from the bridge: Downstairs (device 2001, since " .. os.date("%Y-%m-%d", T0)
				.. ") (Re-link Zone Light or Forget Light)", Z:attention())
		end)

		it("is registered linked and told its state when the zone is still there", function()
			sent = {}
			pending.cb(2001, nil)
			assert.equal("linked", Z:entry(F.group_rids.downstairs).state)
			assert.same({ "HUE_CONFIGURE@2001", "HUE_STATE@2001" }, commands())
			assert.is_nil(sent[1].params.state)
			assert.equal("true", sent[2].params.online)
			assert.is_false(saw_log("while its device was being added"))
		end)
	end)

	-- §5 item 3: code analysis 2026-10-22 R9 (the persisted half), as
	-- lights.lua has done since #48.
	describe("the zone lights' field schema", function()
		it("drops a persisted field this build does not keep, at load", function()
			store.hue_zone_lights = { [F.group_rids.downstairs] = { device_id = 2001, name = "Downstairs", group_type = "zone",
				light_count = 2, state = "linked", color_sent = "xy:0.1,0.2", kind = "group" } }
			local Z = new_zone_lights(new_lights())
			Z:load()
			local entry = Z:entry(F.group_rids.downstairs)
			assert.is_nil(entry.color_sent)
			assert.is_nil(entry.kind)
			assert.same({ "Downstairs", "zone", 2 }, { entry.name, entry.group_type, entry.light_count })
			assert.is_true(saw_log("registry: " .. F.group_rids.downstairs
				.. ": dropped color_sent, kind, which this build no longer keeps"))
		end)

		it("keeps every field the module writes", function()
			local L = new_lights()
			local Z = new_zone_lights(L, { add_device = function(_, _, _, cb) cb(2001, nil) end })
			Z:load()
			Z:resync(function() end, data(F.grouped_light))
			Z:add(F.group_rids.downstairs, GARAGE_ROOM, function() end)
			Z:accept_names()
			Z.reg:update(F.group_rids.downstairs, { name_dismissed = "Downstairs" })
			Z:save()
			local written = {}
			for k in pairs(store.hue_zone_lights[F.group_rids.downstairs]) do written[#written + 1] = k end
			table.sort(written)
			assert.same({ "caps", "created_at", "created_room_id", "device_id", "group_type", "id_v1", "light_count",
				"name", "name_dismissed", "no_lights", "state" }, written)
			logged = {}
			local again = new_zone_lights(L)
			again:load()
			assert.is_false(saw_log("dropped"))
			assert.same(Z:entry(F.group_rids.downstairs), again:entry(F.group_rids.downstairs))
		end)
	end)

	-- Security review 2026-10-25 finding 8: a Hue name reaches AddDevice and
	-- RenameDevice only as util.display_name, and the name comparisons run
	-- both sides through it, so the devices an older build created under raw
	-- names stay as they are (the cases at owner:name_differences). Through the
	-- lights, whose expected name is the Hue name itself.
	describe("names that reach Control4 (security review 2026-10-25 finding 8)", function()
		-- 127 characters: a light named at length by a hostile peer (Hue itself
		-- allows 32).
		local LONG = "Garage White " .. string.rep("over the workbench ", 6)
		-- Its display name: the first 100 characters.
		local SHOWN = "Garage White" .. string.rep(" over the workbench", 4) .. " over the wo"
		local names, renamed, added

		-- The project: Composer names by device or proxy id; renames are
		-- recorded and applied.
		local function named_project()
			local p = project_calls()
			p.display_name = function(id) return names[id] end
			p.rename = function(id, name)
				renamed[#renamed + 1] = { id = id, name = name }
				names[id] = name
			end
			return p
		end

		-- The lights' GET bodies with Garage White's light and device both
		-- called `json_name` in Hue (JSON string contents: escapes allowed).
		local function named(json_name)
			return { light = replace(F.light, '"name":"Garage White"', '"name":"' .. json_name .. '"'),
				device = replace(F.device, '"name":"Garage White"', '"name":"' .. json_name .. '"') }
		end

		-- The lights after a full GET of named(json_name); AddDevice answers
		-- 2001, 2002, ... and records each call in `added`.
		local function lights_named(json_name)
			return new_lights({ project = named_project(), add_device = function(driver, room_id, name, cb)
				added[#added + 1] = { driver = driver, room_id = room_id, name = name }
				cb(2000 + #added, nil)
			end }, named(json_name))
		end

		before_each(function()
			names, renamed, added = {}, {}, {}
		end)

		it("creates a device under the display name of its Hue name; the registry keeps Hue's", function()
			local util = require("bridge.util")
			assert.equal(SHOWN, util.display_name(LONG))
			assert.same({ 127, 100 }, { #LONG, #SHOWN })
			local L = lights_named(LONG)
			local result
			L:add_light(F.rids.garage, GARAGE_ROOM, function(ok, text) result = { ok, text } end)
			assert.same({ { driver = "hue_light.c4z", room_id = GARAGE_ROOM, name = SHOWN } }, added)
			assert.is_true(result[1])
			assert.equal(LONG, L.registry[F.rids.garage].name)
			assert.is_true(saw_log("lights: adding " .. SHOWN .. " to Garage (1 of 1)"))

			added, store = {}, {}  -- a fresh bridge: the first one saved its entry
			L = lights_named("Garage\\tWhite\\n")
			L:add_light(F.rids.garage, GARAGE_ROOM, function() end)
			assert.equal("GarageWhite", added[1].name, "control characters go")
		end)

		it("creates a device whose Hue name has nothing to show as Hue light, and never renames it", function()
			local L = lights_named("\\n\\t ")
			L:add_light(F.rids.garage, GARAGE_ROOM, function() end)
			assert.equal("Hue light", added[1].name)
			names[2001] = "Workbench"  -- AddDevice gave no proxy id: the protocol device is compared
			assert.same({}, L:name_differences(true), "nothing to rename to")
			assert.equal("No Composer names differ from the Hue names", L:adopt_hue_names())
			assert.same({}, renamed)
		end)

		it("leaves an older device under its raw name alone: nothing listed, renamed or accepted", function()
			for _, raw in ipairs({ { LONG, LONG }, { "Garage\\tWhite\\n", "Garage\tWhite\n" } }) do
				names, renamed, store = {}, {}, {}
				local L = lights_named(raw[1])
				register(L, F.rids.garage, 2001)
				assert.equal(raw[2], L.registry[F.rids.garage].name)
				names[3001] = raw[2]  -- what an older build's AddDevice was given
				assert.same({}, L:name_differences(), raw[2])
				assert.same({}, L:name_differences(true), "nor for Adopt Hue Names")
				assert.equal("No Composer names differ from the Hue names", L:adopt_hue_names())
				assert.equal("No Composer names differ from the Hue names", L:accept_names())
				assert.same({}, renamed)
				assert.is_nil(L.registry[F.rids.garage].name_dismissed)
				assert.equal(raw[2], names[3001], "its raw name stays until the owner renames it")
			end
		end)

		it("keeps a difference an older build accepted under the raw expected name accepted", function()
			local L = lights_named(LONG)
			register(L, F.rids.garage, 2001, { name_dismissed = LONG })
			names[3001] = "Workbench"
			assert.same({}, L:name_differences())
			local all = L:name_differences(true)
			assert.equal(1, #all, "Adopt Hue Names still renames accepted differences, as always")
			assert.same({ "Workbench", SHOWN }, { all[1].current, all[1].expected })
		end)

		it("lists a Hue rename to a long name, and Adopt Hue Names renames to its display name", function()
			local L = lights_named("Garage White")
			register(L, F.rids.garage, 2001)
			names[3001] = "Garage White"
			assert.same({}, L:name_differences())
			L:on_container({ type = "update", data = { { id = F.rids.garage, type = "light", metadata = { name = LONG } } } })
			assert.equal(LONG, L.registry[F.rids.garage].name)
			local diffs = L:name_differences()
			assert.equal(1, #diffs)
			assert.same({ "Garage White", SHOWN }, { diffs[1].current, diffs[1].expected })
			assert.same({}, renamed, "an event renames nothing")
			assert.equal("Renamed 1 device: Garage White → " .. SHOWN .. " (device 2001)", L:adopt_hue_names())
			assert.same({ { id = 3001, name = SHOWN } }, renamed)
			assert.same({}, L:name_differences(true), "the display name then compares equal")
			-- A Hue rename past the 100th character, or in control characters only, shows nowhere: not listed.
			L:on_container({ type = "update", data = { { id = F.rids.garage, type = "light",
				metadata = { name = LONG .. "s\n" } } } })
			assert.same({}, L:name_differences())
			-- A Hue rename with a control character is renamed to without it.
			L:on_container({ type = "update", data = { { id = F.rids.garage, type = "light",
				metadata = { name = "Garage\tLamp" } } } })
			assert.equal("Renamed 1 device: " .. SHOWN .. " → GarageLamp (device 2001)", L:adopt_hue_names())
			assert.same({ id = 3001, name = "GarageLamp" }, renamed[2])
		end)

		it("leaves an owner's rename to the owner: listed until accepted, renamed by nothing else", function()
			local L = lights_named(LONG)
			register(L, F.rids.garage, 2001)
			bound[2001] = "Hue Light"
			names[3001] = "Workbench"
			local diffs = L:name_differences()
			assert.equal(1, #diffs)
			assert.same({ "Workbench", SHOWN }, { diffs[1].current, diffs[1].expected })
			-- An event and a resync's absorb and settle rename nothing.
			L:on_container({ type = "update", data = { { id = F.rids.garage, type = "light", on = { on = true } } } })
			L:absorb(resources(named(LONG)))
			L:settle("resync")
			assert.same({}, renamed)
			assert.equal("Accepted 1 name difference: Workbench (Hue: " .. SHOWN .. ")", L:accept_names())
			assert.equal(SHOWN, L.registry[F.rids.garage].name_dismissed)
			assert.same({}, L:name_differences())
			assert.same({}, renamed)
			assert.equal("Workbench", names[3001])
		end)

		it("Link Devices links a device named after the display name of a long Hue name, as one under the raw name",
			function()
				for _, composer in ipairs({ SHOWN, LONG }) do
					names, bound, store = { [2050] = composer }, { [2050] = "Hue Light" }, {}
					local L = lights_named(LONG)
					local text = L:link_devices()
					local head = "Linked 1 device: " .. composer .. " (device 2050) to "
					assert.equal(head, text:sub(1, #head))
					assert.truthy(text:find(" by name", 1, true))
					assert.equal(2050, L.registry[F.rids.garage].device_id)
				end
				-- Both at once cannot both be that light: neither is linked by name.
				names, store = { [2050] = SHOWN, [2051] = LONG }, {}
				bound = { [2050] = "Hue Light", [2051] = "Hue Light" }
				local L = lights_named(LONG)
				local text = L:link_devices()
				assert.truthy(text:find("2 bound devices share that name", 1, true))
				assert.is_nil(L.registry[F.rids.garage])
			end)
	end)

	-- §5 item 4: code analysis 2026-10-22 R9 (the refresh half).
	describe("a refresh clears a field whose value became nil", function()
		it("lights: a full GET clears the MAC and the device name the bridge no longer reports; an event does not",
			function()
				-- Garage White's radio stopped reporting its MAC and its device record lost its name.
				local stale = { zigbee = replace(F.zigbee_connectivity, '"mac_address":"00:17:88:01:0b:12:34:04-0b",', ""),
					device = replace(F.device, '"name":"Garage White",', "") }
				local L = new_lights(nil, stale)
				register(L, F.rids.garage, 2001, { mac_address = "00:17:88:01:0b:12:34:99-0b", device_name = "Garage White" })
				local entry = L.registry[F.rids.garage]
				-- An event's refresh (a light added in the Hue app) leaves them.
				register(L, "ffffffff-0000-4000-8000-00000000new1", 2002, { device_name = "Old Name", model = "Old Model" })
				L:on_container(C4:JsonDecode(F.events.add)[1])
				assert.same({ "Old Name", "Old Model" }, { L.registry["ffffffff-0000-4000-8000-00000000new1"].device_name,
					L.registry["ffffffff-0000-4000-8000-00000000new1"].model })
				assert.equal("00:17:88:01:0b:12:34:99-0b", entry.mac_address)
				-- The next full GET clears them.
				L:absorb(resources(stale))
				assert.is_nil(entry.mac_address)
				assert.is_nil(entry.device_name)
				assert.equal("Hue white lamp", entry.model, "what the bridge still reports stays")
				assert.is_nil(L:entry(F.rids.garage).mac_address)
				assert.is_true(L.dirty, "marked for the batch's save")
			end)

		it("scenes: a time-based entry loses the id_v1 an ordinary scene left it", function()
			local L = new_lights()
			local S = scenes.new(ctx({ lights = L }))
			S:load()
			S:absorb({ scene = data(F.scene), smart_scene = data(F.smart_scene), grouped_light = data(F.grouped_light) })
			register(S, F.smart_scene_rid, 2101, { id_v1 = "/scenes/0000000000000001" })
			register(S, F.scene_rids.relax, 2102)
			local relax_id_v1 = S.registry[F.scene_rids.relax].id_v1
			assert.is_string(relax_id_v1)
			S:send_configure(F.smart_scene_rid)
			assert.equal("/scenes/0000000000000001", sent[#sent].params.id_v1)
			S:absorb({ scene = data(F.scene), smart_scene = data(F.smart_scene), grouped_light = data(F.grouped_light) })
			assert.is_nil(S.registry[F.smart_scene_rid].id_v1)
			assert.equal(relax_id_v1, S.registry[F.scene_rids.relax].id_v1, "an ordinary scene keeps its own")
			assert.is_true(S:configure_changed(F.smart_scene_rid))
			S:send_configure(F.smart_scene_rid)
			assert.is_nil(sent[#sent].params.id_v1)
		end)

		it("zone lights: the id_v1 a group no longer has goes", function()
			local L = new_lights()
			local Z = new_zone_lights(L)
			Z:load()
			Z:resync(function() end, data(F.grouped_light))
			register(Z, F.group_rids.downstairs, 2201)
			assert.equal("/groups/3", Z.registry[F.group_rids.downstairs].id_v1)
			L:absorb(resources({ zone = replace(F.zone, '"id_v1":"/groups/3",', "") }))
			Z:resync(function() end, data(F.grouped_light))
			assert.is_nil(Z.registry[F.group_rids.downstairs].id_v1)
			assert.equal("Downstairs", Z.registry[F.group_rids.downstairs].name, "the rest stays")
		end)
	end)
end)
