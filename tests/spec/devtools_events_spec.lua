-- bridge/devtools.lua's Watch Events (#432 D17, docs/light-events-design.md
-- §6.6, §8.1): a signed dev loop command that registers a light_v2 proxy for
-- a list of event ids and logs each one that fires, for house check P3. The
-- fake runtime has no device events, so this spec stubs them
-- [verified: API 7_event/_5-RegisterDeviceEvent.md, _4.1-OnDeviceEvent.md,
-- _6-UnRegisterAllDeviceEvents.md, _7-UnRegisterDeviceEvent.md].

local fake = require("helpers.fake_c4")
local log = require("common.log")

describe("bridge/devtools.lua Watch Events", function()
	local IP = "10.0.2.143"
	local CHECK_URL = "https://10.00.02.143/clip/v2/resource/bridge"
	local IDENTITY = '{"bridgeid":"001788FFFE123ABC","modelid":"BSB003","name":"Hue","swversion":"1968096020",'
		.. '"apiversion":"1.68.0"}'
	local BRIDGE_RESOURCE = '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"001788fffe123abc"}]}'
	local TEST_KEY = string.rep("0123456789abcdef", 4)

	local env, c4, lines, real_sink, registered, unregistered

	-- A signed dev loop command, as tools/devctl.py run queues it.
	local function signed(name, params)
		return require("common.devloop").execute(name, params or {})
	end

	-- A dev build of the bridge (common.devloop is on the test path, so
	-- bridge/devtools.lua is installed), paired and its identity checked,
	-- with a light (protocol 2004, proxy 2005) and a zone light (protocol
	-- 2010, proxy 2011) registered, their proxies bound as Director binds a
	-- proxy driver, and the device event calls stubbed: `registered` lists
	-- "device:event" per RegisterDeviceEvent, `unregistered` the
	-- UnregisterAllDeviceEvents and UnregisterDeviceEvent calls.
	local function dev_bridge()
		env, c4 = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
			["Bridge IP Address"] = IP })
		c4.persist.hue_app_key = "abc123"
		c4.persist.hue_bridge_id = "001788fffe123abc"
		c4.persist.hue_lights = { ["rid-1"] = { device_id = 2004, name = "Desk Lamp", model = "Hue color lamp",
			caps = { has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 0.2 } } }
		c4.persist.hue_zone_lights = { ["grp-1"] = { device_id = 2010, name = "Downstairs", group_type = "zone",
			light_count = 2, state = "linked" } }
		c4:Bind(2004, 5001, 2005, 5001, "LIGHT_V2")
		c4:Bind(2010, 5001, 2011, 5001, "LIGHT_V2")
		registered, unregistered = {}, {}
		function c4:RegisterDeviceEvent(device, event)
			registered[#registered + 1] = tostring(device) .. ":" .. tostring(event)
		end
		function c4:UnregisterAllDeviceEvents()
			unregistered[#unregistered + 1] = "all"
		end
		function c4:UnregisterDeviceEvent(device, event)
			unregistered[#unregistered + 1] = tostring(device) .. ":" .. tostring(event)
		end
		env.OnDriverLateInit("DIT_STARTUP")
		local t = c4.last_transfer()
		assert(t and t.url == "https://" .. IP .. "/api/0/config", "expected the identity check")
		t:respond(200, IDENTITY)
		t = c4.last_transfer()
		assert(t and t.url == CHECK_URL, "expected the self-check")
		t:respond(200, BRIDGE_RESOURCE)
	end

	-- The lines logged since `from` (an index into `lines`).
	local function since(from)
		local out = {}
		for i = from + 1, #lines do out[#out + 1] = lines[i] end
		return out
	end

	-- Director calling the driver's OnDeviceEvent; the driver's globals are
	-- the runtime's (driver.lua runs in _G on the controller).
	local function fire(device, event)
		local handler = env.OnDeviceEvent
		assert.is_function(handler, "an OnDeviceEvent is installed")
		return handler(device, event)
	end

	-- `fn()` with a release build's modules: no common.devloop, hence no
	-- bridge/devtools.lua (tools/build.sh strips both).
	local function as_release(fn)
		package.loaded["common.devloop"] = nil
		package.preload["common.devloop"] = function() error("module 'common.devloop' not found") end
		local ok, result = pcall(fn)
		package.preload["common.devloop"] = nil
		package.loaded["common.devloop"] = nil
		assert(ok, result)
		return result
	end

	before_each(function()
		lines = {}
		real_sink = log.sink
		log.sink = function(line) lines[#lines + 1] = line end
		rawset(_G, "OnDeviceEvent", nil)
	end)

	after_each(function()
		log.sink = real_sink
		rawset(_G, "OnDeviceEvent", nil)
		-- The loop's state outlives a driver load (_G.__DEVLOOP): leave no
		-- handler, redactor or kept value of this spec behind.
		local loop = package.loaded["common.devloop"]
		if type(loop) == "table" and loop.set_signed_commands then
			loop.set_signed_commands(nil)
			loop.set_redactor(nil)
		end
		package.preload["common.devkey"] = nil
		package.loaded["common.devkey"] = nil
		rawset(_G, "__DEVLOOP", nil)
	end)

	it("Watch Events registers the proxy for the listed events and logs each one that fires", function()
		dev_bridge()
		-- An OnDeviceEvent the driver had before is chained, not replaced.
		local earlier = {}
		rawset(_G, "OnDeviceEvent", function(device, event) earlier[#earlier + 1] = { device, event } end)

		local from = #lines
		signed("Watch Events", { Light = "desk lamp" })
		local expected = {}
		for id = 5001, 5015 do expected[#expected + 1] = "2005:" .. id end
		assert.same(expected, registered, "the default list, on the light's proxy")
		assert.same({ "Hue Bridge: Watch Events: Desk Lamp (proxy 2005): registered 5001-5015; watching 15 events "
			.. "on 1 device" }, since(from))

		from = #lines
		local t0 = c4.now_ms
		fire(2005, 5002)
		c4.advance(250)
		fire(2005, 5003)
		c4.advance(350)
		fire(2005, 5001)
		fire(2005, 5015)
		assert.same({
			"Hue Bridge: event 5002 (Top Push) from device 2005 at " .. t0,
			"Hue Bridge: event 5003 (Top Single) from device 2005 at " .. (t0 + 250),
			"Hue Bridge: event 5001 (Top Release) from device 2005 at " .. (t0 + 600),
			"Hue Bridge: event 5015 (Toggle Triple) from device 2005 at " .. (t0 + 600),
		}, since(from))
		assert.same({ { 2005, 5002 }, { 2005, 5003 }, { 2005, 5001 }, { 2005, 5015 } }, earlier)

		-- Every name of the light_v2 keypad events (F3): 5001 + action + 5 x button.
		local names = require("bridge.devtools").EVENT_NAMES
		assert.equal("Bottom Release", names[5006])
		assert.equal("Bottom Double", names[5009])
		assert.equal("Toggle Push", names[5012])
		assert.equal("Light On", names[5100])

		-- A second call adds ids, on another device too (a zone light found by
		-- its Hue name), as a comma list with a range; ids already registered
		-- are not registered again.
		registered = {}
		from = #lines
		signed("Watch Events", { Light = "Downstairs", Events = "5003, 4001,5100-5101,5003" })
		signed("Watch Events", { Light = "2004", Events = "5001-5005" })
		signed("Watch Events", { Light = "rid-1", Events = "4001" })
		assert.same({ "2011:5003", "2011:4001", "2011:5100", "2011:5101", "2005:4001" }, registered)
		assert.same({
			"Hue Bridge: Watch Events: Downstairs (proxy 2011): registered 4001,5003,5100-5101; watching 19 events "
				.. "on 2 devices",
			"Hue Bridge: Watch Events: Desk Lamp (proxy 2005): registered nothing new; watching 19 events on 2 devices",
			"Hue Bridge: Watch Events: Desk Lamp (proxy 2005): registered 4001; watching 20 events on 2 devices",
		}, since(from))

		-- One hook for all of it: each event is logged once, whatever fires it.
		from = #lines
		fire(2011, 4001)
		fire(2011, 9999)
		assert.same({
			"Hue Bridge: event 4001 (Brightness Changed) from device 2011 at " .. c4.now_ms,
			"Hue Bridge: event 9999 (?) from device 2011 at " .. c4.now_ms,
		}, since(from))
		assert.equal(6, #earlier)
	end)

	it("Watch Events with Events=none unregisters them", function()
		dev_bridge()
		local earlier = function() end
		rawset(_G, "OnDeviceEvent", earlier)
		signed("Watch Events", { Light = "Desk Lamp", Events = "5001-5005" })
		signed("Watch Events", { Light = "Downstairs", Events = "5011" })
		assert.are_not.equal(earlier, rawget(_G, "OnDeviceEvent"))

		local from = #lines
		signed("Watch Events", { Events = "None" })
		assert.same({ "all" }, unregistered, "one UnregisterAllDeviceEvents")
		assert.same({ "Hue Bridge: Watch Events: stopped; 6 events on 2 devices unregistered" }, since(from))
		assert.equal(earlier, rawget(_G, "OnDeviceEvent"), "the earlier OnDeviceEvent is back")
		from = #lines
		fire(2005, 5002)
		assert.same({}, since(from), "nothing logged any more")

		-- Watching again starts from nothing; a controller without
		-- UnregisterAllDeviceEvents gets UnregisterDeviceEvent per event.
		registered, unregistered = {}, {}
		signed("Watch Events", { Light = "Desk Lamp", Events = "5002,5003" })
		assert.same({ "2005:5002", "2005:5003" }, registered)
		c4.UnregisterAllDeviceEvents = nil
		signed("Watch Events", { Events = "none" })
		table.sort(unregistered)
		assert.same({ "2005:5002", "2005:5003" }, unregistered)
		assert.equal(earlier, rawget(_G, "OnDeviceEvent"))

		-- With no earlier OnDeviceEvent, none leaves none.
		rawset(_G, "OnDeviceEvent", nil)
		signed("Watch Events", { Light = "Desk Lamp", Events = "5002" })
		assert.is_function(rawget(_G, "OnDeviceEvent"))
		signed("Watch Events", { Events = "none" })
		assert.is_nil(rawget(_G, "OnDeviceEvent"))
	end)

	it("Watch Events refuses a bad Events list or an unknown light and registers nothing", function()
		dev_bridge()
		local from = #lines
		signed("Watch Events", { Light = "Desk Lamp", Events = "50x" })
		signed("Watch Events", { Light = "Desk Lamp", Events = "5015-5001" })
		signed("Watch Events", { Light = "Desk Lamp", Events = "1-50000" })
		signed("Watch Events", { Light = "Desk Lamp", Events = "5001," })
		signed("Watch Events", { Light = "nope" })
		assert.same({
			'Hue Bridge: Watch Events: Events "50x" is not an event id or a range of them; nothing registered',
			'Hue Bridge: Watch Events: Events "5015-5001" runs backwards; nothing registered',
			'Hue Bridge: Watch Events: Events "1-50000" lists more than 64 ids; nothing registered',
			'Hue Bridge: Watch Events: Events "" is not an event id or a range of them; nothing registered',
			'Hue Bridge: Watch Events: no registered light, zone light or scene matches "nope"; nothing registered',
		}, since(from))
		assert.same({}, registered)
		assert.is_nil(rawget(_G, "OnDeviceEvent"), "no hook either")
	end)

	it("Watch Events answers signed dev loop commands only, and a release build has none", function()
		dev_bridge()
		local from = #lines
		env.ExecuteCommand("Watch Events", { Light = "Desk Lamp" })                       -- C4:SendToDevice
		env.ExecuteCommand("Watch_Events", { Light = "Desk Lamp" })
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Watch Events", Light = "Desk Lamp" }) -- dressed as an action
		assert.same({}, registered)
		assert.same({}, since(from), "no handler ran")
		assert.is_nil(rawget(_G, "OnDeviceEvent"))
		assert.is_nil(require("common.dispatch").commands["Watch_Events"])

		as_release(function()
			dev_bridge()
			assert.is_nil(package.loaded["bridge.devtools"], "no devtools without the dev loop")
			assert.is_nil(require("common.dispatch").commands["Watch_Events"])
			env.ExecuteCommand("Watch Events", { Light = "Desk Lamp" })
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Watch Events", Light = "Desk Lamp" })
			assert.same({}, registered)
			assert.is_nil(rawget(_G, "OnDeviceEvent"))
		end)
	end)

	it("a dev loop reload hands the hook over, so each event is still logged once", function()
		-- A dev build carries its key, so the loop keeps values across a
		-- reload (devloop.keep); the reload is a second load of the driver's
		-- code in the same Lua state, where Director keeps the registrations
		-- and the global OnDeviceEvent.
		package.preload["common.devkey"] = function() return TEST_KEY end
		package.loaded["common.devkey"] = nil
		rawset(_G, "__DEVLOOP", nil)
		local earlier = {}
		rawset(_G, "OnDeviceEvent", function(device, event) earlier[#earlier + 1] = { device, event } end)
		dev_bridge()
		signed("Watch Events", { Light = "Desk Lamp", Events = "5001-5005" })
		local old_handler = rawget(_G, "OnDeviceEvent")

		dev_bridge()
		assert.are_not.equal(old_handler, rawget(_G, "OnDeviceEvent"), "the new code's handler is in")
		local from = #lines
		fire(2005, 5004)
		assert.same({ "Hue Bridge: event 5004 (Top Double) from device 2005 at " .. c4.now_ms }, since(from))
		assert.same({ { 2005, 5004 } }, earlier, "the first earlier handler, once")

		-- The registrations came along: nothing is registered twice, and none
		-- counts them and puts the first earlier handler back.
		registered = {}
		signed("Watch Events", { Light = "Desk Lamp", Events = "5001-5006" })
		assert.same({ "2005:5006" }, registered)
		from = #lines
		signed("Watch Events", { Events = "none" })
		assert.same({ "Hue Bridge: Watch Events: stopped; 6 events on 1 device unregistered" }, since(from))
		fire(2005, 5004)
		assert.equal(2, #earlier)
		assert.same({ "Hue Bridge: Watch Events: stopped; 6 events on 1 device unregistered" }, since(from))
	end)
end)
