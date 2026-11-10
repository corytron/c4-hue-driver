-- End to end for the Hue automation audit (#280, docs/hue-automation-audit-design.md
-- §8, "the contract") on the real bridge driver: src/hue_bridge/driver.lua as
-- Director runs it (late init, the identity and TLS checks, the event stream,
-- the resync chain lights → scenes → zone lights → motion → automations),
-- with the fake runtime. What this pins is driver.lua's wiring of
-- bridge/automations.lua, for which automations_spec stands in: the chain
-- step of a full resync and none in a quick one, the stream fan-out, the row
-- and Attention, the re-evaluation after an import, the Hue Automations
-- action with HueAutomationList's values, Forget Pairing's Last Action and
-- OnDriverRemovedFromProject.
--
-- The bridge is tests/fixtures/hue_automations.lua's: its lights, devices,
-- rooms, zone and bridge_home are built below from A.ids and A.topology, so
-- the driver's own caches expand the instances' references (D4); scenes and
-- motion resources are empty. Its 15 instances (A.INSTANCES) include one
-- that fires by itself on the Bedroom (Wake Weekdays: a wake up on Bedroom
-- Lamp and Bedside, room Bedroom). Importing Bedroom Lamp as a Hue Light
-- device makes it a conflict (D3, D8). Addresses, ids and the key are the
-- documented placeholders.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local json = require("dkjson")
local A = require("fixtures.hue_automations")

local LAMP_ID = 2001                    -- the id the fake's AddDevice hands out first
local BEDROOM = 8                       -- a Control4 room named after the Hue room
local BRIDGE_IP = "10.0.2.143"
local BRIDGE_HUE_ID = "001788fffe123abc"
local APP_KEY = "zzzz0000zzzz0000"
local START_MS = 1794208800000          -- 2026-11-09T07:20:00Z on the controller's clock
local WAKE = A.ids.instances.wake_up
local LAMP = A.ids.lights.bedroom_lamp
local CONFIRM_YES = "Yes, forget"       -- bridge/actions.lua CONFIRM_YES

-- The bridge's lights and their devices -----------------------------------------------------------

local function id(prefix, n)
	return prefix .. "000000-0000-4000-8000-0000000000" .. n
end

local function ref(rid, rtype)
	return { rid = rid, rtype = rtype }
end

local function body(items)
	return json.encode({ errors = {}, data = items })
end

-- The light keys in a stable order, each with its number (the last two
-- digits of its fixture ids).
local LIGHTS = {}
for key, rid in pairs(A.ids.lights) do
	LIGHTS[#LIGHTS + 1] = { key = key, rid = rid, n = rid:sub(-2), device = A.ids.devices[key],
		name = A.light_names[key] }
end
table.sort(LIGHTS, function(a, b) return a.n < b.n end)

local DEVICE_OF = {}
for _, l in ipairs(LIGHTS) do
	DEVICE_OF[l.rid] = l.device
end

local light_items, device_items, zigbee_items = {}, {}, {}
for i, l in ipairs(LIGHTS) do
	light_items[i] = { id = l.rid, id_v1 = "/lights/" .. i, owner = ref(l.device, "device"), service_id = 0,
		metadata = { name = l.name, archetype = "classic_bulb" }, on = { on = false },
		dimming = { brightness = 50.0, min_dim_level = 2.0 }, mode = "normal", type = "light" }
	device_items[i] = { id = l.device, id_v1 = "/lights/" .. i,
		product_data = { model_id = "LWA001", manufacturer_name = "Signify Netherlands B.V.",
			product_name = "Hue white lamp", product_archetype = "classic_bulb", software_version = "1.122.2" },
		metadata = { name = l.name, archetype = "classic_bulb" },
		services = { ref(id("2b", l.n), "zigbee_connectivity"), ref(l.rid, "light") }, type = "device" }
	zigbee_items[i] = { id = id("2b", l.n), id_v1 = "/lights/" .. i, owner = ref(l.device, "device"),
		status = "connected", mac_address = "00:17:88:01:0b:00:00:" .. l.n .. "-0b", type = "zigbee_connectivity" }
end

-- Rooms (device children), the zone (light children) and bridge_home (the
-- rooms and the one light in no room), each with its grouped_light.
local R = A.ids.rooms
local ROOMS = {
	{ rid = R.bedroom, name = "Bedroom", archetype = "bedroom", n = "01" },
	{ rid = R.hallway, name = "Hallway", archetype = "hallway", n = "02" },
	{ rid = R.kitchen, name = "Kitchen", archetype = "kitchen", n = "03" },
	{ rid = R.living, name = "Living Room", archetype = "living_room", n = "04" },
	{ rid = R.outdoor, name = "Outdoor", archetype = "garden", n = "05" },
}
local room_items = {}
for i, r in ipairs(ROOMS) do
	local children = {}
	for _, light in ipairs(A.topology.members[r.rid]) do
		children[#children + 1] = ref(DEVICE_OF[light], "device")
	end
	room_items[i] = { id = r.rid, id_v1 = "/groups/" .. i, children = children,
		services = { ref(id("9e", r.n), "grouped_light") }, metadata = { name = r.name, archetype = r.archetype },
		type = "room" }
end
local downstairs = A.ids.zones.downstairs
local zone_children = {}
for _, light in ipairs(A.topology.members[downstairs]) do
	zone_children[#zone_children + 1] = ref(light, "light")
end
local zone_items = { { id = downstairs, id_v1 = "/groups/6", children = zone_children,
	services = { ref(id("9e", "06"), "grouped_light") }, metadata = { name = "Downstairs", archetype = "downstairs" },
	type = "zone" } }
local home_children = { ref(A.ids.devices.tv_strip, "device") }
for _, r in ipairs(ROOMS) do
	home_children[#home_children + 1] = ref(r.rid, "room")
end
local home_items = { { id = A.ids.home, id_v1 = "/groups/0", children = home_children,
	services = { ref(id("9e", "f0"), "grouped_light") }, type = "bridge_home" } }

local EMPTY = body({})

-- The bodies of every resource GET, by type.
local BODIES = {
	light = body(light_items), device = body(device_items), zigbee_connectivity = body(zigbee_items),
	room = body(room_items), zone = body(zone_items), bridge_home = body(home_items),
	scene = EMPTY, smart_scene = EMPTY, grouped_light = EMPTY,
	motion = EMPTY, light_level = EMPTY, temperature = EMPTY, device_power = EMPTY,
	motion_area_configuration = EMPTY, convenience_area_motion = EMPTY, security_area_motion = EMPTY,
	behavior_instance = A.get_instances(), behavior_script = A.get_scripts(),
}

-- The GETs of a full resync after the stream connects, in order: the lights'
-- six, the scenes' three, the motion module's eight, then the audit's two
-- (the contract D18: last, full tier only).
local CHAIN = { "light", "device", "zigbee_connectivity", "room", "zone", "bridge_home", "scene", "smart_scene",
	"grouped_light", "motion", "light_level", "temperature", "device_power", "zigbee_connectivity",
	"motion_area_configuration", "convenience_area_motion", "security_area_motion", "behavior_instance",
	"behavior_script" }

-- One instance as GET behavior_instance/<rid> answers it, `enabled` as given.
local function instance_body(key, enabled)
	local item = A.instance(key)
	item.enabled = enabled
	item.status = enabled and "running" or "disabled"
	return body({ item })
end

local PUT_OK = body({ { rid = WAKE, rtype = "behavior_instance" } })

-- A container as the event stream sends it (JSON text of a one-container array).
local function container_text(kind, items)
	return json.encode({ A.container(kind, items) })
end

describe("Hue automation audit round trip", function()
	local bridge, bc4, stream_t, logged, sse_n

	-- The pending resource GET of the bridge, answered from `bodies`: its
	-- type, or nil when none is pending. Every module waits for one answer
	-- before its next GET, so the pending one is the last transfer. Also an
	-- iterator: `for kind in answer_next, bodies do`.
	local function answer_next(bodies)
		local t = bc4.last_transfer()
		local kind = t and not t.answered and t.method == "GET" and t.url:match("/clip/v2/resource/([%w_]+)$")
		if not kind then
			return nil
		end
		assert(bodies[kind], "no body for GET " .. kind)
		t.answered = true
		fake.as(bridge, function() t:respond(200, bodies[kind]) end)
		return kind
	end

	-- Every GET as it comes; the types answered, in order.
	local function answer_gets(bodies)
		local order = {}
		for kind in answer_next, bodies do
			order[#order + 1] = kind
		end
		return order
	end

	-- One SSE message of `containers` (JSON text) on the event stream, then
	-- the messages it caused delivered.
	local function stream(containers)
		sse_n = sse_n + 1
		fake.as(bridge, function()
			stream_t:chunk(string.format("id: %d:0\ndata: %s\n\n", 1794208900 + sse_n, containers))
		end)
		return fake.pump()
	end

	-- A bridge action as Composer sends it; the Last Action it leaves.
	local function action(name, params)
		params = params or {}
		params.ACTION = name
		fake.as(bridge, bridge.ExecuteCommand, "LUA_ACTION", params)
		return fake.last_action(bridge)
	end

	-- HueAutomationList's answer for a folder value (nil: the top).
	local function picker(folder)
		return fake.custom_select(bridge, "HueAutomationList", folder)
	end

	-- The entry of a picker list whose text starts with `prefix`.
	local function entry(list, prefix)
		for _, e in ipairs(list) do
			if e.text:sub(1, #prefix) == prefix then return e end
		end
		local texts = {}
		for _, e in ipairs(list) do texts[#texts + 1] = e.text end
		error("no entry starting with " .. prefix .. " in: " .. table.concat(texts, " | "))
	end

	-- The Hue Automations row: its summary, and the drop-down lines after it.
	local function row()
		local lines = {}
		for line in (bc4.property_lists["Hue Automations"] .. ","):gmatch("([^,]*),") do
			lines[#lines + 1] = line
		end
		assert.equal(bridge.Properties["Hue Automations"], table.remove(lines, 1), "the row shows the summary")
		return bridge.Properties["Hue Automations"], lines
	end

	-- The transfers from index `from` on, as "<METHOD> <type>[/<rid>]".
	local function sent_since(from)
		local out = {}
		for i = from, #bc4.transfers do
			local t = bc4.transfers[i]
			out[#out + 1] = t.method .. " " .. tostring(t.url:match("/clip/v2/resource/(.+)$") or t.url)
		end
		return out
	end

	-- Every write the bridge sent (anything but a GET), in order.
	local function writes()
		local out = {}
		for _, t in ipairs(bc4.transfers) do
			if t.method ~= "GET" then out[#out + 1] = t end
		end
		return out
	end

	-- The pending transfer: its method and URL checked, then answered.
	local function answer(method, path, code, text)
		local t = bc4.last_transfer()
		assert.is_falsy(t.answered, "the last transfer was answered already: " .. t.url)
		assert.equal(method, t.method)
		assert.equal("https://" .. BRIDGE_IP .. "/clip/v2/resource/" .. path, t.url)
		t.answered = true
		fake.as(bridge, function() t:respond(code, text) end)
		return t
	end

	local function logged_since(first, text)
		local out = {}
		for i = first, #logged do
			if logged[i]:find(text, 1, true) then out[#out + 1] = logged[i] end
		end
		return out
	end

	local function load()
		logged, sse_n = {}, 0
		log.sink = function(line) logged[#logged + 1] = line end
		bridge = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
			["Bridge IP Address"] = BRIDGE_IP })
		bc4 = bridge.C4
		bc4.now_ms = START_MS
		fake.add_room(BEDROOM, "Bedroom")
		bc4.persist.hue_app_key = APP_KEY
		bc4.persist.hue_bridge_id = BRIDGE_HUE_ID
	end

	-- The bridge starts: its late init, its identity (asked without the key),
	-- the TLS self-check (the fake fails its decoy at once), the stream, and
	-- the first resync, which is full and reads the automations last.
	local function start()
		fake.as(bridge, bridge.OnDriverLateInit, "DIT_STARTUP")
		local t = bc4.last_transfer()
		assert.equal("https://" .. BRIDGE_IP .. "/api/0/config", t.url)
		fake.as(bridge, function() t:respond(200, '{"bridgeid":"' .. BRIDGE_HUE_ID:upper() .. '","modelid":"BSB003"}') end)
		t = bc4.last_transfer()
		assert.truthy(t.url:find("/clip/v2/resource/bridge$"), t.url)
		fake.as(bridge, function() t:respond(200, '{"errors":[],"data":[{"bridge_id":"' .. BRIDGE_HUE_ID .. '"}]}') end)
		stream_t = bc4.last_transfer()
		assert.truthy(stream_t.url:find("/eventstream/clip/v2$"), stream_t.url)
		fake.as(bridge, function() stream_t:respond_headers(200, {}) end)
		bc4.advance(2500) -- the on_connected deferral, then the background resync's 2 s debounce
		assert.same(CHAIN, answer_gets(BODIES))
	end

	-- Add From Hue for Bedroom Lamp into the Bedroom: a Hue Light device for
	-- a light Wake Weekdays acts on (the contract C1).
	local function import_lamp()
		local text = action("Add From Hue", { What = "light:" .. LAMP, Room = tostring(BEDROOM) })
		assert.truthy(text:find("^Added Bedroom Lamp"), text)
		assert.equal(LAMP_ID, bc4.added[1].id)
		assert.equal("Bedroom Lamp", fake.project.devices[LAMP_ID].name)
	end

	-- Hue Automations ▸ Disable in Hue ▸ Wake Weekdays, every answer as the bridge gives it.
	local function disable_wake()
		local off = entry(picker("f:off"), "Wake Weekdays (wake up)")
		assert.equal("off:" .. WAKE, off.value)
		action("Hue Automations", { Automation = off.value })
		answer("GET", "behavior_instance/" .. WAKE, 200, instance_body("wake_up", true))
		answer("PUT", "behavior_instance/" .. WAKE, 200, PUT_OK)
		answer("GET", "behavior_instance/" .. WAKE, 200, instance_body("wake_up", false))
		return fake.last_action(bridge)
	end

	-- common.dispatch and the modules' protect() turn a handler's error into
	-- an [ERROR] line instead of raising it: none may have been logged.
	after_each(function()
		log.set_debug(false)
		for _, line in ipairs(logged) do
			assert.is_nil(line:find("[ERROR]", 1, true), line)
		end
	end)

	before_each(function()
		load()
		start()
	end)

	it("lists a conflicting Hue automation in the row and in Attention", function()
		-- The full resync filled the row: every instance on the bridge, none
		-- on a Control4 light yet (no device), the MotionAware set-up that
		-- does nothing, the safety lighting, the one disabled in Hue, the
		-- entertainment setting counted, and the coverage line last.
		local summary, lines = row()
		assert.equal("15 on bridge‚ 0 on Control4 lights‚ 0 disabled by Control4", summary)
		assert.truthy(#lines > 10, table.concat(lines, " | "))
		local function has(line)
			for _, l in ipairs(lines) do
				if l == line then return true end
			end
			return false
		end
		assert.is_true(has("Does nothing: Kitchen motion area (MotionAware)‚ Control4 decides"), table.concat(lines, " | "))
		assert.is_true(has("Safety lighting (kept): Smoke alarm lights"), table.concat(lines, " | "))
		assert.is_true(has("Not audited: 1 entertainment setting"), table.concat(lines, " | "))
		assert.equal("Not seen here: other apps' v1 rules‚ Hue Labs‚ Alexa‚ Google‚ Apple Home routines", lines[#lines])
		for _, l in ipairs(lines) do
			assert.is_nil(l:find("^On Control4 lights"), l)
		end
		assert.is_nil(fake.attention(bridge):find("Hue automation", 1, true), fake.attention(bridge))

		-- Bedroom Lamp becomes a Hue Light device: Wake Weekdays, which fires
		-- by itself on it, is a conflict at once, with no GET (D19), and the
		-- log says so once (H1).
		local transfers, first = #bc4.transfers, #logged + 1
		import_lamp()
		assert.same({}, sent_since(transfers + 1), "the import re-evaluates the audit without a GET")
		local attention = fake.attention(bridge)
		assert.truthy(attention:find("1 Hue automation acts on Control4 lights: Wake Weekdays (Hue Automations)", 1,
			true), attention)
		summary, lines = row()
		assert.equal("15 on bridge‚ 3 on Control4 lights‚ 0 disabled by Control4", summary)
		assert.equal("On Control4 lights: Wake Weekdays (wake up) on Bedroom Lamp‚ Bedroom Ceiling‚ Bedside", lines[1])
		assert.equal(1, #logged_since(first, "Hue automation Wake Weekdays (wake up) acts by itself on Control4 lights: "
			.. "Bedroom Lamp"))

		-- Switched off in the Hue app, then on again (stream updates of
		-- `enabled` alone): it leaves Attention and comes back, with no GET.
		transfers = #bc4.transfers
		stream(container_text("update", { A.updates.enabled("wake_up", false) }))
		assert.is_nil(fake.attention(bridge):find("Hue automation", 1, true), fake.attention(bridge))
		summary = row()
		assert.equal("15 on bridge‚ 2 on Control4 lights‚ 0 disabled by Control4", summary)
		stream(container_text("update", { A.updates.enabled("wake_up", true) }))
		assert.truthy(fake.attention(bridge):find("1 Hue automation acts on Control4 lights: Wake Weekdays", 1, true),
			fake.attention(bridge))
		assert.same({}, sent_since(transfers + 1), "an automation event is read from the stream alone")

		-- The audit only read: no write went to the bridge.
		assert.same({}, writes())
	end)

	it("disables a conflicting automation from the action and restores it", function()
		import_lamp()

		-- The action's one picker: the Disable folder, then the line for Wake Weekdays.
		local top = picker()
		local off = entry(top, "Disable in Hue (")
		assert.equal("f:off", off.value)
		assert.is_true(off.folder)
		local list = picker("f:off")
		assert.equal("Back to all folders", list[1].text)
		assert.equal("Wake Weekdays (wake up) on Bedroom Lamp; also 2 lights outside Control4",
			entry(list, "Wake Weekdays").text)

		-- Disable: one fresh GET of the instance, then exactly one PUT
		-- {"enabled": false} on it, then one GET to confirm (R1, D2, D18). The
		-- record is persisted as pending before the PUT (D13).
		local transfers = #bc4.transfers
		action("Hue Automations", { Automation = "off:" .. WAKE })
		answer("GET", "behavior_instance/" .. WAKE, 200, instance_body("wake_up", true))
		local put = bc4.last_transfer()
		assert.equal("PUT", put.method)
		assert.same({ enabled = false }, json.decode(put.data))
		assert.equal("pending", bc4.persist.hue_automations.entries[WAKE].state, "written ahead of the PUT")
		answer("PUT", "behavior_instance/" .. WAKE, 200, PUT_OK)
		answer("GET", "behavior_instance/" .. WAKE, 200, instance_body("wake_up", false))
		assert.same({ "GET behavior_instance/" .. WAKE, "PUT behavior_instance/" .. WAKE,
			"GET behavior_instance/" .. WAKE }, sent_since(transfers + 1))
		assert.equal(1, #writes())
		assert.equal("Disabled in Hue: Wake Weekdays. It stays on the bridge and shows as off in the Hue app; Hue "
			.. "Automations ▸ Restore turns it on again. It also controlled Bedroom Ceiling and Bedside, which Control4 "
			.. "does not control: they no longer follow it either.", fake.last_action(bridge))

		-- The record persists (D11), and the row and Attention follow.
		local rec = bc4.persist.hue_automations
		assert.equal(BRIDGE_HUE_ID, rec.bridge_id)
		assert.equal("disabled", rec.entries[WAKE].state)
		assert.equal("Wake Weekdays", rec.entries[WAKE].name)
		assert.same({ "Bedroom Lamp" }, rec.entries[WAKE].lights)
		assert.is_nil(fake.attention(bridge):find("Hue automation", 1, true), fake.attention(bridge))
		local today = os.date("%m-%d")
		local summary, lines = row()
		assert.equal("15 on bridge‚ 2 on Control4 lights‚ 1 disabled by Control4", summary)
		assert.equal("Disabled by Control4 " .. today .. ": Wake Weekdays (wake up) on Bedroom Lamp‚ Bedroom Ceiling‚ "
			.. "Bedside", lines[1])

		-- The bridge's own echo on the stream changes nothing and sends nothing.
		transfers = #bc4.transfers
		stream(container_text("update", { A.updates.enabled("wake_up", false) }))
		assert.same({}, sent_since(transfers + 1))
		assert.equal("disabled", bc4.persist.hue_automations.entries[WAKE].state)

		-- Restore: the same three requests with {"enabled": true}; it still
		-- acts on Bedroom Lamp, so it is kept (D15) and stays off Attention.
		local restore = entry(picker(), "Restore (1 disabled by Control4)")
		assert.equal("f:on", restore.value)
		local on = entry(picker("f:on"), "Wake Weekdays (disabled " .. today .. ")")
		assert.equal("on:" .. WAKE, on.value)
		action("Hue Automations", { Automation = on.value })
		answer("GET", "behavior_instance/" .. WAKE, 200, instance_body("wake_up", false))
		put = bc4.last_transfer()
		assert.same({ enabled = true }, json.decode(put.data))
		assert.equal("restoring", bc4.persist.hue_automations.entries[WAKE].state, "written ahead of the PUT")
		answer("PUT", "behavior_instance/" .. WAKE, 200, PUT_OK)
		answer("GET", "behavior_instance/" .. WAKE, 200, instance_body("wake_up", true))
		assert.same({ "GET behavior_instance/" .. WAKE, "PUT behavior_instance/" .. WAKE,
			"GET behavior_instance/" .. WAKE }, sent_since(transfers + 1))
		assert.equal(2, #writes())
		assert.equal("Turned on again in Hue: Wake Weekdays (disabled by Control4 since " .. today .. "). It acts on "
			.. "Bedroom Lamp, a Control4 light, so it is now kept (Hue Automations ▸ Stop keeping lists it again).",
			fake.last_action(bridge))
		rec = bc4.persist.hue_automations
		assert.is_nil(rec.entries[WAKE])
		assert.same({ [LAMP] = true }, rec.kept[WAKE].lights)
		assert.is_nil(fake.attention(bridge):find("Hue automation", 1, true), fake.attention(bridge))
		summary, lines = row()
		assert.equal("15 on bridge‚ 3 on Control4 lights‚ 0 disabled by Control4‚ 1 kept", summary)
		assert.equal("Kept: Wake Weekdays (wake up) on Bedroom Lamp‚ Bedroom Ceiling‚ Bedside", lines[1])
	end)

	-- Pending: driver.lua hands bridge/automations.lua `busy = function() return nil end`, so a click
	-- during a resync goes ahead (its GET beside the chain's) instead of the contract's R9 refusal.
	it("refuses a click while the bridge is being read, and sends nothing (R9)", function()
		import_lamp()
		-- Diagnostics ▸ Read everything from the bridge now: the full chain
		-- starts, and its first GET (the lights') waits for its answer.
		action("Diagnostics", { What = "diag:refresh" })
		bc4.advance(2500)
		assert.truthy(bc4.last_transfer().url:find("/clip/v2/resource/light$"), bc4.last_transfer().url)
		local transfers = #bc4.transfers
		local text = action("Hue Automations", { Automation = "off:" .. WAKE })
		assert.truthy(text:find("^Busy: "), text)
		assert.same({}, sent_since(transfers + 1), "a refused click sends nothing")
		answer_gets(BODIES)
		assert.same({}, writes())
		assert.is_nil(bc4.persist.hue_automations and bc4.persist.hue_automations.entries[WAKE])
	end)

	it("still lists what Control4 disabled after late init runs again, from the store alone (C5, C6)", function()
		import_lamp()
		disable_wake()
		-- Late init again (as after an update in place or a Director restart):
		-- the audit is rebuilt and loads the record before any read.
		local first = #bc4.transfers
		fake.as(bridge, bridge.OnDriverLateInit, "DIT_STARTUP")
		assert.equal("Not read yet", bridge.Properties["Hue Automations"])
		for i = first + 1, #bc4.transfers do
			assert.equal("GET", bc4.transfers[i].method, "nothing written at start: " .. bc4.transfers[i].url)
		end
		assert.same({ text = "(not read yet; Diagnostics ▸ Read everything from the bridge now)", value = "" },
			picker()[1])
		-- The next full read finds it still disabled: the row says so, and
		-- Restore offers it.
		action("Diagnostics", { What = "diag:refresh" })
		bc4.advance(2500)
		local bodies = setmetatable({ behavior_instance = (function()
			local items = A.instances()
			for _, item in ipairs(items) do
				if item.id == WAKE then item.enabled, item.status = false, "disabled" end
			end
			return body(items)
		end)() }, { __index = BODIES })
		local order = answer_gets(bodies)
		assert.equal("behavior_script", order[#order], table.concat(order, " "))
		local summary, lines = row()
		assert.equal("15 on bridge‚ 2 on Control4 lights‚ 1 disabled by Control4", summary)
		assert.equal("Disabled by Control4 " .. os.date("%m-%d") .. ": Wake Weekdays (wake up) on Bedroom Lamp‚ Bedroom "
			.. "Ceiling‚ Bedside", lines[1])
		assert.equal("on:" .. WAKE, entry(picker("f:on"), "Wake Weekdays (disabled ").value)
		assert.equal(1, #writes(), "only the Disable's PUT")
	end)

	it("names the automations Control4 disabled in Forget Pairing's Last Action, and keeps the record (C8)", function()
		import_lamp()
		disable_wake()
		local transfers = #bc4.transfers
		assert.equal("Pairing forgotten: the key is gone and the event stream stopped; devices and the address are "
			.. "kept. Control4 still has 1 Hue automation disabled on this bridge: Wake Weekdays; pair again to restore "
			.. "it, or turn it on in the Hue app", action("Forget Pairing", { Confirm = CONFIRM_YES }))
		assert.equal("disabled", bc4.persist.hue_automations.entries[WAKE].state, "the record is kept")
		assert.equal(BRIDGE_HUE_ID, bc4.persist.hue_automations.bridge_id)
		for i = transfers + 1, #bc4.transfers do
			assert.equal("GET", bc4.transfers[i].method, "nothing written: " .. bc4.transfers[i].url)
		end
		assert.equal(1, #writes(), "only the Disable's PUT")
		assert.equal("Not paired", bridge.Properties["Hue Automations"])
	end)

	it("reads no behaviour resource in the quick resync after a silence (watchdog) reconnect", function()
		local summary = row()
		-- No event for the watchdog's period (Stream Watchdog (s), 600 by
		-- default, armed at the connect, 2.5 s before start() returned): the
		-- stream reconnects, and the connect's resync is the quick tier
		-- (bridge/away.lua connect_tier).
		local before = #bc4.transfers
		bc4.advance(600000 - 2500)
		assert.same({}, sent_since(before + 1), "nothing sent while the house is quiet")
		assert.truthy(bridge.Properties["Event Stream"]:find("watchdog", 1, true), bridge.Properties["Event Stream"])
		-- Debug Mode: the chain's own lines say which tier ran.
		bridge.Properties["Debug Mode"] = "On"
		fake.as(bridge, bridge.OnPropertyChanged, "Debug Mode")
		local first, transfers = #logged + 1, #bc4.transfers
		bc4.advance(1000) -- the reconnect's backoff
		stream_t = bc4.last_transfer()
		assert.truthy(stream_t.url:find("/eventstream/clip/v2$"), stream_t.url)
		fake.as(bridge, function() stream_t:respond_headers(200, {}) end)
		bc4.advance(2500)
		-- The lights' six, no scene catalogue (the zone lights read
		-- grouped_light themselves), the motion module's eight, and nothing of
		-- the audit's (D18: the stream keeps its cache current).
		assert.same({ "light", "device", "zigbee_connectivity", "room", "zone", "bridge_home", "grouped_light", "motion",
			"light_level", "temperature", "device_power", "zigbee_connectivity", "motion_area_configuration",
			"convenience_area_motion", "security_area_motion" }, answer_gets(BODIES))
		assert.equal(1, #logged_since(first, "scene resync skipped (quick resync)"), "the quick tier ran")
		assert.same({}, logged_since(first, "automation resync"), "the quick tier reports no audit read")
		for _, kind in ipairs(sent_since(transfers + 1)) do
			assert.is_nil(kind:find("behavior_", 1, true), "a quick resync sent " .. kind)
		end
		assert.equal(summary, (row()), "the row keeps what the full read found")
	end)

	it("logs what stays disabled when the driver is removed from the project, and sends nothing (C9)", function()
		-- Nothing disabled: nothing to say.
		local first, transfers = #logged + 1, #bc4.transfers
		fake.as(bridge, bridge.OnDriverRemovedFromProject)
		assert.same({}, logged_since(first, "was removed"))
		assert.equal(transfers, #bc4.transfers)

		import_lamp()
		disable_wake()
		local rec = bc4.persist.hue_automations
		first, transfers = #logged + 1, #bc4.transfers
		fake.as(bridge, bridge.OnDriverRemovedFromProject)
		local lines = logged_since(first, "was removed")
		assert.equal(1, #lines, table.concat(lines, " | "))
		assert.truthy(lines[1]:find("The Hue Bridge driver was removed while Control4 had 1 Hue automation disabled on "
			.. "the bridge: Wake Weekdays. It stays off; turn it on in the Hue app", 1, true), lines[1])
		assert.equal(transfers, #bc4.transfers, "nothing sent from the removal callback")
		assert.equal(rec, bc4.persist.hue_automations, "the record is not even saved again")
		assert.equal("disabled", rec.entries[WAKE].state)
		assert.equal(1, #writes(), "only the Disable's PUT")
	end)
end)
