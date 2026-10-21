-- The two-driver harness itself: bindings, routing, the project model, the
-- Composer-side helpers and the colour maths.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BRIDGE_PROPS = { ["Bridge IP Address"] = "" }

-- A bridge (15) and a light paired to it; the light is 2001 with proxy 3001.
local function pair_up(opts)
	local bridge = fake.load_driver("hue_bridge", BRIDGE_PROPS)
	local light = fake.load_driver("hue_light", {})
	local light_id = fake.pair(bridge, light, opts)
	return bridge, light, light_id
end

-- Sorted keys of a table.
local function keys(t)
	local out = {}
	for k in pairs(t) do out[#out + 1] = k end
	table.sort(out)
	return out
end

local function clear(t)
	for i = #t, 1, -1 do t[i] = nil end
end

-- Record every OnBindingChanged of an env as { who, ...its five params }.
local function watch_bindings(env, who, into)
	env.OnBindingChanged = function(...) into[#into + 1] = { who, ... } end
end

describe("fake C4 harness", function()
	before_each(function() log.sink = function() end end)

	it("binds a bridge and a light and answers the bound-device lookups", function()
		local bridge, light, light_id = pair_up()
		assert.equal(2001, light_id)
		-- The value is the driver's <name>, not the Composer name [verified: hardware].
		assert.same({ [2001] = "Hue Light" }, bridge.C4:GetBoundConsumerDevices(15, 1))
		assert.equal(15, light.C4:GetBoundProviderDevice(2001, 1))
		assert.is_nil(bridge.C4:GetBoundConsumerDevices(15, 2))
	end)

	it("routes SendToDevice between the pair with stringified params", function()
		local bridge, light = pair_up()
		local got, saw_c4
		light.ExecuteCommand = function(command, params)
			got = { command, params }
			saw_c4 = rawget(_G, "C4")
		end
		fake.as(bridge, function() bridge.C4:SendToDevice(2001, "HUE_STATE", { rid = "r1", brightness = 50 }) end)
		assert.equal(1, fake.pump())
		assert.same({ "HUE_STATE", { rid = "r1", brightness = "50" } }, got)
		assert.equal(light.C4, saw_c4, "receiver ran with its own C4")
		assert.equal(0, fake.pump())
	end)

	it("AddDevice hands back ascending ids and records the request", function()
		local c4 = fake.install_c4()
		local ids, infos = {}, {}
		c4:AddDevice("hue_light.c4z", 7, "Desk", function(id, info) ids[#ids + 1] = id; infos[#infos + 1] = info end)
		c4:AddDevice("hue_light.c4z", function(id, info) ids[#ids + 1] = id; infos[#infos + 1] = info end)
		assert.same({ 2001, 2002 }, ids)
		assert.same({ {}, {} }, infos, "the callback's info table stays empty")
		assert.equal("Desk", c4.added[1].name)
		assert.same({ { "hue_light.c4z", 7, "Desk" }, { "hue_light.c4z" } }, c4.calls_to("AddDevice"))
	end)

	it("colour conversions round-trip to within a few percent", function()
		local c4 = fake.install_c4()
		for _, k in ipairs({ 2000, 2700, 4000, 6500 }) do
			local x, y = c4:ColorCCTtoXY(k)
			local back = c4:ColorXYtoCCT(x, y)
			assert.is_true(math.abs(back - k) / k < 0.05, string.format("%d K -> %.4f,%.4f -> %.0f K", k, x, y, back))
		end
	end)

	describe("project", function()
		it("starts every runtime with the default room and the runtime's own device", function()
			local c4 = fake.install_c4()
			assert.same({ name = "Living Room", floor_id = 3, floor_name = "Main" }, fake.project.rooms[7])
			assert.same({ 7 }, keys(fake.project.rooms))
			assert.equal(7, c4:RoomGetId())
			assert.equal("Hue Bridge", c4:GetDeviceDisplayName())
			assert.same({ name = "Hue Bridge", room_id = 7, c4i = "hue_bridge.c4z", driver_name = "Hue Bridge" },
				fake.project.devices[15])
			assert.same({ 15 }, keys(fake.project.devices), "no proxy for the bridge")
			assert.equal("hue_bridge.c4z", c4:GetDriverFileName())
		end)

		it("gives a loaded light its driver name and a light_v2 proxy on binding 5001", function()
			local _, c4 = fake.load_driver("hue_light", {}, { device_id = 2001 })
			assert.same({ name = "Hue Light", room_id = 7, c4i = "hue_light.c4z", proxy_id = 3001, proxy_binding = 5001,
				driver_name = "Hue Light" }, fake.project.devices[2001])
			assert.same({ name = "Hue Light", room_id = 7, c4i = "light_v2.c4i", protocol_id = 2001,
				driver_name = "Hue Light" }, fake.project.devices[3001])
			assert.same({ [3001] = "Hue Light" }, c4:GetBoundConsumerDevices(2001, 5001))
			assert.equal(2001, c4:GetBoundProviderDevice(3001, 5001))
			assert.is_nil(c4:GetBoundProviderDevice(3001, 1))
			assert.equal(0, #c4.bindings, "the proxy binding is implied, not listed")
			assert.equal("hue_light.c4z", c4:GetDriverFileName())
		end)

		it("resets when a runtime is loaded; pair registers both drivers at their final ids", function()
			local bridge = fake.load_driver("hue_bridge", BRIDGE_PROPS)
			fake.add_room(8, "Kitchen")
			local light = fake.load_driver("hue_light", {})
			assert.is_nil(fake.project.rooms[8], "a new runtime starts a new project")
			assert.equal("hue_light.c4z", fake.project.devices[15].c4i, "the light's placeholder id")

			local light_id = fake.pair(bridge, light)
			assert.equal(2001, light_id)
			assert.same({ 15, 2001, 3001 }, keys(fake.project.devices))
			assert.equal("hue_bridge.c4z", fake.project.devices[15].c4i)
			assert.is_nil(fake.project.devices[15].proxy_id)
			assert.equal(3001, fake.project.devices[2001].proxy_id, "the placeholder's proxy id was handed back")
			assert.equal("Hue Light", bridge.C4:GetDeviceDisplayName(2001))
		end)

		it("keeps the entry AddDevice made when pair reuses its id", function()
			local light = fake.load_driver("hue_light", {}, { device_id = 2001 })
			local bridge = fake.load_driver("hue_bridge", BRIDGE_PROPS)
			bridge.C4:AddDevice("hue_light.c4z", 7, "Desk Lamp", function() end)
			fake.pair(bridge, light, { light_id = 2001, bind = false })
			assert.same({ 15, 2001, 3001 }, keys(fake.project.devices))
			assert.equal("Desk Lamp", light.C4:GetDeviceDisplayName())
			assert.equal("Desk Lamp", fake.project.devices[3001].name)
		end)

		it("reset_project keeps the loaded drivers and drops everything else", function()
			local bridge, _, light_id = pair_up()
			fake.add_room(8, "Kitchen")
			bridge.C4:AddDevice("hue_light.c4z", 8, "Island", function() end)
			fake.move_device(light_id, 8)
			fake.reset_project()
			assert.same({ 7 }, keys(fake.project.rooms))
			assert.same({ 15, light_id, 3001 }, keys(fake.project.devices))
			assert.equal(7, fake.project.devices[light_id].room_id)
		end)

		it("AddDevice registers the device and its proxy in the room it was given", function()
			local c4 = fake.install_c4()
			fake.add_room(8, "Kitchen", 4, "Upstairs")
			c4:AddDevice("hue_light.c4z", 8, "Island", function() end)
			assert.same({ name = "Island", room_id = 8, c4i = "hue_light.c4z", proxy_id = 3001, proxy_binding = 5001,
				driver_name = "Hue Light" }, fake.project.devices[2001])
			assert.same({ name = "Island", room_id = 8, c4i = "light_v2.c4i", protocol_id = 2001,
				driver_name = "Hue Light" }, fake.project.devices[3001])

			-- No room: the caller's; no name: the driver's <name>.
			c4:AddDevice("hue_light.c4z", function() end)
			assert.equal(7, fake.project.devices[2002].room_id)
			assert.equal("Hue Light", fake.project.devices[2002].name)
			assert.equal(3002, fake.project.devices[2002].proxy_id)

			-- A driver without a src/ tree: base name, no proxy.
			c4:AddDevice("driver_properties.c4z", function() end)
			assert.same({ name = "driver_properties", room_id = 7, c4i = "driver_properties.c4z",
				driver_name = "driver_properties" }, fake.project.devices[2003])

			assert.has_error(function() c4:AddDevice("hue_light.c4z", 99, function() end) end,
				"C4:AddDevice: unknown room 99; fake.add_room() it first")
		end)

		it("moves devices and renames and deletes rooms", function()
			local c4 = fake.install_c4()
			fake.add_room(8, "Kitchen")
			c4:AddDevice("hue_light.c4z", 7, "Lamp", function() end)
			fake.move_device(3001, 8)  -- by proxy id: both halves move
			assert.equal(8, fake.project.devices[2001].room_id)
			assert.equal(8, fake.project.devices[3001].room_id)
			fake.move_device(15, 8)
			assert.equal(8, c4:RoomGetId(), "the room containing this driver")

			fake.rename_room(8, "Scullery")
			assert.equal("Scullery", c4:GetDevices({ DeviceIds = "2001" })[2001].roomName)

			assert.has_error(function() fake.delete_room(8) end)  -- still holds devices
			fake.delete_room(7)
			assert.same({ 8 }, keys(fake.project.rooms))
			assert.has_error(function() fake.move_device(2001, 7) end)
			assert.has_error(function() fake.add_room(8, "Again") end)
			assert.has_error(function() fake.rename_room(7, "Gone") end)
		end)
	end)

	describe("GetDevices", function()
		local c4

		before_each(function()
			c4 = fake.install_c4()
			fake.add_room(8, "Kitchen")
			fake.add_room(9, "Bedroom", 4, "Upstairs")
			c4:AddDevice("hue_light.c4z", 8, "Island", function() end)   -- 2001, proxy 3001
			c4:AddDevice("hue_light.c4z", 9, "Bedside", function() end)  -- 2002, proxy 3002
		end)

		it("filters by a comma-delimited DeviceIds string, proxy ids included", function()
			local got = c4:GetDevices({ DeviceIds = "2001, 3002" })
			assert.same({
				[2001] = { deviceName = "Island", roomId = 8, roomName = "Kitchen", driverFileName = "hue_light.c4z",
					proxies = { [3001] = { deviceName = "Island", driverFileName = "light_v2.c4i" } } },
				[3002] = { deviceName = "Bedside", roomId = 9, roomName = "Bedroom", driverFileName = "light_v2.c4i",
					protocol = { [2002] = { deviceName = "Bedside", driverFileName = "hue_light.c4z" } } },
			}, got)
			assert.same({ { { DeviceIds = "2001, 3002" } } }, c4.calls_to("GetDevices"))
			assert.same({}, c4:GetDevices({ DeviceIds = "99" }))
		end)

		it("filters by C4iNames: the protocol devices of that driver, no proxies key without proxies", function()
			assert.same({ 2001, 2002 }, keys(c4:GetDevices({ C4iNames = "hue_light.c4z" })))
			assert.same({
				[15] = { deviceName = "Hue Bridge", roomId = 7, roomName = "Living Room", driverFileName = "hue_bridge.c4z" },
			}, c4:GetDevices({ C4iNames = "hue_bridge.c4z" }))
			assert.same({ 15, 2001, 2002 }, keys(c4:GetDevices({ C4iNames = "hue_bridge.c4z,hue_light.c4z" })))
			assert.same({ 3001, 3002 }, keys(c4:GetDevices({ C4iNames = "light_v2.c4i" })))
		end)

		it("narrows by location: a room, a floor, the building or site", function()
			local lights = { C4iNames = "hue_light.c4z" }
			assert.same({ 2002 }, keys(c4:GetDevices(lights, "9")))
			assert.same({ 2002 }, keys(c4:GetDevices(lights, 4)), "floor Upstairs")
			assert.same({ 2001, 2002 }, keys(c4:GetDevices(lights, "3,9")))
			assert.same({ 2001, 2002 }, keys(c4:GetDevices(lights, 2)), "the building")
			assert.same({}, keys(c4:GetDevices(lights, 99)))
			assert.same({ 7, 15 }, keys(c4:GetDevices({}, 7)), "the room and the bridge in it")
		end)

		it("returns everything, rooms included, for an empty or missing filter", function()
			local got = c4:GetDevices({})
			assert.same({ 7, 8, 9, 15, 2001, 2002, 3001, 3002 }, keys(got))
			assert.same({ deviceName = "Kitchen", roomId = 8, roomName = "Kitchen", driverFileName = "roomdevice.c4i" },
				got[8])
			assert.same(keys(got), keys(c4:GetDevices()))
			assert.same({ 7, 8, 9 }, keys(c4:GetDevices({ C4iNames = "roomdevice.c4i" })))
		end)

		it("refuses a table of ids and unknown filter keys, as the controller does", function()
			assert.has_error(function() c4:GetDevices({ DeviceIds = { 2001 } }) end, "DeviceIds should be a string")
			assert.has_error(function() c4:GetDevices({ C4iNames = { "hue_light.c4z" } }) end, "C4iNames should be a string")
			assert.has_error(function() c4:GetDevices({ c4iNames = "hue_light.c4z" }) end)
			assert.has_error(function() c4:GetDevices("hue_light.c4z") end)
		end)
	end)

	describe("project lookups", function()
		it("GetDevicesByC4iName lists devices by driver file and rooms through roomdevice.c4i", function()
			local c4 = fake.install_c4()
			fake.add_room(8, "Kitchen")
			c4:AddDevice("hue_light.c4z", 8, "Island", function() end)
			assert.same({ [2001] = "Island" }, c4:GetDevicesByC4iName("hue_light.c4z"))
			assert.same({ [3001] = "Island" }, c4:GetDevicesByC4iName("light_v2.c4i"))
			assert.same({ [7] = "Living Room", [8] = "Kitchen" }, c4:GetDevicesByC4iName("roomdevice.c4i"))
			assert.same({}, c4:GetDevicesByC4iName("nothing.c4z"))
			assert.same({ { "hue_light.c4z" } }, { c4.calls_to("GetDevicesByC4iName")[1] })
		end)

		it("GetProjectHierarchy nests the tree with the controller's numeric types", function()
			local c4 = fake.install_c4()
			fake.add_room(8, "Kitchen")
			fake.add_room(9, "Bedroom", 4, "Upstairs")
			local kitchen, bedroom = { name = "Kitchen", type = 8 }, { name = "Bedroom", type = 8 }
			local upstairs = { name = "Upstairs", type = 4, [9] = bedroom }
			assert.same({ [1] = { name = "Home", type = 2, [2] = { name = "House", type = 3,
				[3] = { name = "Main", type = 4, [7] = { name = "Living Room", type = 8 }, [8] = kitchen },
				[4] = upstairs } } }, c4:GetProjectHierarchy())
			assert.same({ [4] = upstairs }, c4:GetProjectHierarchy(4))
			assert.same({ [8] = kitchen }, c4:GetProjectHierarchy("8"))
			assert.same({}, c4:GetProjectHierarchy(99))
			assert.same({ site = 2, building = 3, floor = 4, room = 8 }, fake.location_types)
		end)

		it("GetDeviceDisplayName answers for protocol and proxy ids, nil for strangers", function()
			local c4 = fake.install_c4()
			c4:AddDevice("hue_light.c4z", 7, "Island", function() end)
			assert.equal("Island", c4:GetDeviceDisplayName(2001))
			assert.equal("Island", c4:GetDeviceDisplayName(3001))
			assert.equal("Hue Bridge", c4:GetDeviceDisplayName())
			assert.is_nil(c4:GetDeviceDisplayName(99))
			assert.equal(4, #c4.calls_to("GetDeviceDisplayName"))
		end)

		it("RenameDevice records the rename and applies it to the id named only", function()
			local c4 = fake.install_c4()
			c4:AddDevice("hue_light.c4z", 7, "Island", function() end)
			c4:RenameDevice(3001, "Kitchen Island")
			assert.same({ { id = 3001, name = "Kitchen Island" } }, c4.renamed)
			assert.same({ { 3001, "Kitchen Island" } }, c4.calls_to("RenameDevice"))
			assert.equal("Kitchen Island", c4:GetDeviceDisplayName(3001))
			assert.equal("Island", c4:GetDeviceDisplayName(2001), "the protocol driver keeps its name")
			assert.equal("Kitchen Island", c4:GetDevices({ DeviceIds = "2001" })[2001].proxies[3001].deviceName)
			assert.same({ [2001] = "Hue Light" }, c4:GetBoundConsumerDevices(15, 1) or { [2001] = "Hue Light" })
			assert.has_no.errors(function() c4:RenameDevice(99, "Ghost") end)
			assert.equal(2, #c4.renamed)
		end)
	end)

	describe("Bind and Unbind", function()
		it("tell both drivers of a pair, provider first, and mirror each other", function()
			local bridge, light, light_id = pair_up({ bind = false })
			local seen = {}
			watch_bindings(bridge, "bridge", seen)
			watch_bindings(light, "light", seen)

			bridge.C4:Bind(15, 1, light_id, 1, "HUE_BRIDGE")
			assert.same({
				{ "bridge", 1, "HUE_BRIDGE", true, light_id, 1 },
				{ "light", 1, "HUE_BRIDGE", true, 15, 1 },
			}, seen)
			assert.equal(1, #light.C4.bindings, "one shared table")

			clear(seen)
			light.C4:Unbind(light_id, 1)
			assert.same({
				{ "bridge", 1, "HUE_BRIDGE", false, light_id, 1 },
				{ "light", 1, "HUE_BRIDGE", false, 15, 1 },
			}, seen)
			assert.equal(0, #bridge.C4.bindings)
			assert.is_nil(bridge.C4:GetBoundConsumerDevices(15, 1))
			assert.is_nil(light.C4:GetBoundProviderDevice(light_id, 1))
			assert.same({ { light_id, 1 } }, light.C4.calls_to("Unbind"))

			clear(seen)
			light.C4:Unbind(light_id, 1)
			assert.same({}, seen, "nothing to unbind, nothing said")
		end)

		it("stay silent while one end is not a loaded driver, and for pair's own bind", function()
			local seen = {}
			local light = fake.load_driver("hue_light", {}, { device_id = 2001 })
			watch_bindings(light, "light", seen)
			light.C4:Bind(15, 1, 2001, 1, "HUE_BRIDGE")
			assert.equal(15, light.C4:GetBoundProviderDevice(2001, 1))
			light.C4:Unbind(2001, 1)
			assert.is_nil(light.C4:GetBoundProviderDevice(2001, 1))
			assert.same({}, seen)

			local bridge = fake.load_driver("hue_bridge", BRIDGE_PROPS)
			light = fake.load_driver("hue_light", {})
			watch_bindings(bridge, "bridge", seen)
			watch_bindings(light, "light", seen)
			fake.pair(bridge, light)
			assert.same({}, seen)
			assert.equal(1, #bridge.C4.bindings)
		end)
	end)

	describe("delete_device", function()
		it("runs Composer's delete on a paired light: callbacks, goodbye, unbinding, gone", function()
			local bridge, light, light_id = pair_up()
			local proxy_id = fake.project.devices[light_id].proxy_id
			local events = {}
			light.OnDriverRemovedFromProject = function()
				events[#events + 1] = { "removed", rawget(_G, "C4") == light.C4 }
				light.C4:SendToDevice(15, "HUE_GOODBYE", { rid = "r1", device_id = light_id })
			end
			light.OnDriverDestroyed = function(dit) events[#events + 1] = { "destroyed", dit } end
			light.OnBindingChanged = function() error("the deleted driver hears nothing") end
			bridge.ExecuteCommand = function(command, params) events[#events + 1] = { "bridge", command, params } end
			watch_bindings(bridge, "unbound", events)
			fake.as(light, function() light.C4:SetTimer(500, function() end) end)
			-- A second binding on the proxy side, as Director wires a light_v2 proxy.
			table.insert(bridge.C4.bindings, { provider = proxy_id, provider_binding = 5001, consumer = 7,
				consumer_binding = 1, class = "LIGHT_V2" })

			local removed = fake.delete_device(light_id)
			assert.same({
				{ "removed", true },
				{ "destroyed", "DIT_LOADED" },
				{ "bridge", "HUE_GOODBYE", { rid = "r1", device_id = tostring(light_id) } },
				{ "unbound", 1, "HUE_BRIDGE", false, light_id, 1 },
			}, events)
			assert.equal("Hue Light", removed.name)
			assert.equal(proxy_id, removed.proxy_id)
			assert.equal(0, #light.C4.active_timers(), "OnDriverDestroyed kills the timers")
			assert.same({}, bridge.C4.bindings)
			assert.same({ 15 }, keys(fake.project.devices))
			assert.is_nil(bridge.C4:GetBoundConsumerDevices(15, 1))

			-- Messages to the dead id vanish; the id cannot be deleted twice.
			fake.as(bridge, function() bridge.C4:SendToDevice(light_id, "HUE_STATE", { rid = "r1" }) end)
			assert.equal(0, fake.pump())
			assert.has_error(function() fake.delete_device(light_id) end)
		end)

		it("accepts the proxy id and a device whose driver is not loaded", function()
			local c4, env = fake.install_c4()
			c4:AddDevice("hue_light.c4z", 7, "Island", function() end)
			c4:Bind(15, 1, 2001, 1, "HUE_BRIDGE")
			local seen = {}
			watch_bindings(env, "bridge", seen)
			local removed = fake.delete_device(3001)
			assert.equal("Island", removed.name)
			assert.same({ { "bridge", 1, "HUE_BRIDGE", false, 2001, 1 } }, seen)
			assert.same({ 15 }, keys(fake.project.devices))
			assert.equal(0, #c4.bindings)
			assert.has_error(function() fake.delete_device(99) end)
		end)

		it("deleting the bridge unbinds every light and leaves them in the project", function()
			local bridge, light, light_id = pair_up()
			bridge.OnDriverDestroyed = function() end
			local seen = {}
			watch_bindings(light, "light", seen)
			fake.delete_device(15)
			assert.same({ { "light", 1, "HUE_BRIDGE", false, 15, 1 } }, seen)
			assert.same({ light_id, 3001 }, keys(fake.project.devices))
			assert.is_nil(light.C4:GetBoundProviderDevice(light_id, 1))
			assert.equal(7, light.C4:RoomGetId())
		end)
	end)

	it("custom_select calls a driver's list function with its globals in place", function()
		local bridge, light = pair_up()
		bridge.ListRooms = function(prefix)
			return { prefix .. tostring(rawget(_G, "C4") == bridge.C4), tostring(C4:GetDeviceID()) }
		end
		fake.as(light, function()
			assert.same({ "mine: true", "15" }, fake.custom_select(bridge, "ListRooms", "mine: "))
			assert.equal(light.C4, rawget(_G, "C4"), "globals restored afterwards")
		end)
		assert.has_error(function() fake.custom_select(bridge, "NoSuchList") end)
	end)
end)
