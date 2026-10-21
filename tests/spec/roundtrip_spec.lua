-- End to end on the two-driver harness: the bridge imports the fixture
-- lights, one of them is a loaded Hue Light driver, and a slider move from
-- the proxy becomes one coalesced PUT whose stream event closes the loop.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local json = require("dkjson")
local F = require("fixtures.hue_resources")

local CHECK_URL = "https://192.00.02.10/clip/v2/resource/bridge"
local STREAM_URL = "https://192.000.002.10/eventstream/clip/v2"

-- Fire the env's active timers whose delay is at most max_delay ms, with the
-- env's globals in place (the stream's watchdog stays armed).
local function fire_fast_timers(env, max_delay)
	return fake.as(env, function()
		local n = 0
		for _, t in ipairs(env.C4.active_timers()) do
			if t.delay <= max_delay then
				if not t.repeating then t.active = false end
				t.callback(t, 0)
				n = n + 1
			end
		end
		return n
	end)
end

-- The registry fetches light, device and zigbee_connectivity one after the
-- other (each GET starts from the previous one's OnDone), so keep answering
-- until no unanswered resource GET is left.
local function answer_resource_gets(bridge, from_index)
	local c4 = bridge.C4
	local bodies = { light = F.light, device = F.device, zigbee_connectivity = F.zigbee_connectivity }
	local answered, progress = 0, true
	while progress do
		progress = false
		for i = from_index, #c4.transfers do
			local t = c4.transfers[i]
			local kind = t.url:match("/clip/v2/resource/([%w_]+)$")
			if kind and bodies[kind] and not t.answered then
				t.answered = true
				fake.as(bridge, function() t:respond(200, bodies[kind]) end)
				answered = answered + 1
				progress = true
			end
		end
	end
	return answered
end

local function proxy_calls(light, command)
	local out = {}
	for _, args in ipairs(light.C4.calls_to("SendToProxy")) do
		if args[2] == command then out[#out + 1] = args[3] end
	end
	return out
end

describe("round trip: import, state, command, event", function()
	local bridge, light, living

	before_each(function()
		log.sink = function() end
		local data = json.decode(F.light).data
		for _, item in ipairs(data) do
			if item.id == F.rids.living then living = item end
		end
		assert(living, "living room lamp fixture")

		-- The light first, so the bridge's globals are the ones left in place.
		light = fake.load_driver("hue_light", {}, { device_id = 2004 })
		bridge = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		bridge.C4.persist.hue_app_key = "abc123"
		bridge.C4.persist.hue_bridge_id = "001788fffe25b8f8"
		bridge.OnDriverLateInit("DIT_STARTUP")
	end)

	it("runs the whole loop", function()
		local bc4 = bridge.C4

		-- Self-check, then the stream connects and the deferred resync runs
		-- against an empty registry (three GETs, nothing to send).
		assert.equal(CHECK_URL, bc4.last_transfer().url)
		bc4.last_transfer():respond(200, '{"data":[{"bridge_id":"001788fffe25b8f8"}]}')
		local stream_t = bc4.last_transfer()
		assert.equal(STREAM_URL, stream_t.url)
		stream_t:respond_headers(200, {})
		assert.equal(1, fire_fast_timers(bridge, 1), "on_connected deferral")
		assert.equal(3, answer_resource_gets(bridge, 1))
		assert.equal(0, #bc4.sent, "nothing registered yet")

		-- Import Lights: three GETs, four AddDevice calls in name order, each
		-- bound and told its configuration and state.
		bridge.ExecuteCommand("LUA_ACTION", { ACTION = "Import Lights" })
		assert.equal(3, answer_resource_gets(bridge, 1))
		assert.equal(4, #bc4.added)
		assert.equal("Garage White", bc4.added[1].name)
		assert.equal("Living Room Lamp", bc4.added[4].name)
		assert.equal(2004, bc4.added[4].id)
		assert.equal(4, #bc4.bindings)
		assert.equal("4 lights on bridge, 4 imported, 4 new", bridge.Properties["Lights"])
		local to_living = {}
		for _, m in ipairs(bc4.sent) do
			if m.id == 2004 then to_living[#to_living + 1] = m.command end
		end
		assert.same({ "HUE_CONFIGURE", "HUE_STATE" }, to_living)

		-- Now the Living Room Lamp is a real driver bound to this bridge.
		fake.pair(bridge, light, { light_id = 2004, bind = false })
		assert.equal(15, light.C4:GetBoundProviderDevice(2004, 1))
		fake.as(light, light.OnDriverLateInit, "DIT_STARTUP")
		fake.pump()

		local caps = proxy_calls(light, "DYNAMIC_CAPABILITIES_CHANGED")
		assert.is_true(#caps >= 1)
		assert.equal("true", tostring(caps[1].supports_color))
		assert.equal("true", tostring(caps[1].supports_color_correlated_temperature))
		assert.equal("Living Room Lamp", light.Properties["Hue Name"])
		assert.equal(F.rids.living, light.Properties["Hue Light ID"])
		local br = proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED")
		assert.is_true(#br >= 1)
		assert.equal(living.on.on and living.dimming.brightness or 0, br[#br].LIGHT_BRIGHTNESS_CURRENT)
		local col = proxy_calls(light, "LIGHT_COLOR_CHANGED")
		assert.is_true(#col >= 1)
		assert.equal(1, col[#col].LIGHT_COLOR_CURRENT_COLOR_MODE, "mirek_valid -> CCT mode")

		-- A slider move and a colour pick arrive back to back from the proxy.
		light.C4.calls = {}
		fake.as(light, light.ReceivedFromProxy, 5001, "SET_BRIGHTNESS_TARGET",
			{ LIGHT_BRIGHTNESS_TARGET = "50", RATE = "400" })
		fake.as(light, light.ReceivedFromProxy, 5001, "SET_COLOR_TARGET",
			{ LIGHT_COLOR_TARGET_X = "0.3", LIGHT_COLOR_TARGET_Y = "0.3",
			  LIGHT_COLOR_TARGET_COLOR_MODE = "0", LIGHT_COLOR_TARGET_RATE = "400" })
		assert.equal(1, #proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGING"))
		assert.equal(1, #proxy_calls(light, "LIGHT_COLOR_CHANGING"))
		assert.equal(2, fake.pump(), "two HUE_SET messages reached the bridge")

		-- One coalesced PUT after the debounce.
		local before = #bc4.transfers
		assert.is_true(fire_fast_timers(bridge, 80) >= 1, "debounce timer")
		assert.equal(before + 1, #bc4.transfers, "exactly one PUT for both commands")
		local put = bc4.last_transfer()
		assert.equal("PUT", put.method)
		assert.equal("https://192.0.2.10/clip/v2/resource/light/" .. F.rids.living, put.url)
		local body = json.decode(put.data)
		assert.is_true(body.on.on)
		assert.equal(50, body.dimming.brightness)
		assert.equal(0.3, body.color.xy.x)
		assert.is_nil(body.color_temperature, "xy beats mirek")
		assert.equal(400, body.dynamics.duration)
		fake.as(bridge, function()
			put:respond(200, '{"data":[{"rid":"' .. F.rids.living .. '","rtype":"light"}],"errors":[]}')
		end)

		-- The bridge's event for that change fans out and closes the loop:
		-- CHANGED notifies, and the light's fallback timers are cancelled.
		local event = json.encode({ {
			creationtime = "2026-10-21T18:10:00Z", id = "evt-1", type = "update",
			-- As the bridge reports it: a move to xy also marks the CCT invalid.
			data = { { id = F.rids.living, type = "light", on = { on = true },
				dimming = { brightness = 50 }, color = { xy = { x = 0.3, y = 0.3 } },
				color_temperature = { mirek_valid = false } } },
		} })
		fake.as(bridge, function() stream_t:chunk("id: 10:0\ndata: " .. event .. "\n\n") end)
		assert.equal(1, fake.pump(), "one HUE_STATE to the living room lamp")
		br = proxy_calls(light, "LIGHT_BRIGHTNESS_CHANGED")
		assert.equal(50, br[#br].LIGHT_BRIGHTNESS_CURRENT)
		col = proxy_calls(light, "LIGHT_COLOR_CHANGED")
		assert.equal(0, col[#col].LIGHT_COLOR_CURRENT_COLOR_MODE)
		for _, t in ipairs(light.C4.active_timers()) do
			assert.are_not.equal(1400, t.delay, "fallback timer still armed")
		end
	end)
end)
