-- The two-driver harness itself: bindings, routing and the colour maths.

local fake = require("helpers.fake_c4")
local log = require("common.log")

describe("fake C4 harness", function()
	before_each(function() log.sink = function() end end)

	it("binds a bridge and a light and answers the bound-device lookups", function()
		local bridge = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
		local light = fake.load_driver("hue_light", {})
		local light_id = fake.pair(bridge, light)
		assert.equal(2001, light_id)
		assert.same({ [2001] = "Device 2001" }, bridge.C4:GetBoundConsumerDevices(15, 1))
		assert.equal(15, light.C4:GetBoundProviderDevice(2001, 1))
		assert.is_nil(bridge.C4:GetBoundConsumerDevices(15, 2))
	end)

	it("routes SendToDevice between the pair with stringified params", function()
		local bridge = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
		local light = fake.load_driver("hue_light", {})
		fake.pair(bridge, light)
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
		local ids = {}
		c4:AddDevice("hue_light.c4z", 7, "Desk", function(id) ids[#ids + 1] = id end)
		c4:AddDevice("hue_light.c4z", function(id) ids[#ids + 1] = id end)
		assert.same({ 2001, 2002 }, ids)
		assert.equal("Desk", c4.added[1].name)
	end)

	it("colour conversions round-trip to within a few percent", function()
		local c4 = fake.install_c4()
		for _, k in ipairs({ 2000, 2700, 4000, 6500 }) do
			local x, y = c4:ColorCCTtoXY(k)
			local back = c4:ColorXYtoCCT(x, y)
			assert.is_true(math.abs(back - k) / k < 0.05, string.format("%d K -> %.4f,%.4f -> %.0f K", k, x, y, back))
		end
	end)
end)
