-- Smoke tests: each driver loads against the fake runtime and handles its
-- startup entry points without errors.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local function quiet()
	log.sink = function() end
end

describe("Hue Bridge driver", function()
	before_each(quiet)

	it("asks for an IP address when none is set", function()
		local env = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
		env.OnDriverInit("DIT_ADDING")
		env.OnDriverLateInit("DIT_ADDING")
		assert.equal("Enter the bridge IP address", env.Properties["Status"])
		assert.equal("1", env.Properties["Driver Version"])
	end)

	it("moves to 'Not paired' once a valid IP is entered", function()
		local env = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
		env.OnDriverLateInit("DIT_STARTUP")
		env.Properties["Bridge IP Address"] = "192.0.2.10"
		env.OnPropertyChanged("Bridge IP Address")
		assert.equal("Not paired", env.Properties["Status"])
	end)

	it("ignores an invalid IP", function()
		local env = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "not-an-ip" })
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal("Enter the bridge IP address", env.Properties["Status"])
	end)
end)

describe("Hue Light driver", function()
	before_each(quiet)

	it("reports offline and zero brightness on SYNCHRONIZE", function()
		local env, c4 = fake.load_driver("hue_light", {})
		env.OnDriverLateInit("DIT_STARTUP")
		c4.calls = {}

		env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})

		local sent = c4.calls_to("SendToProxy")
		assert.same({ 5001, "ONLINE_CHANGED", { STATE = false } }, sent[1])
		assert.same({ 5001, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 0 } }, sent[2])
	end)

	it("does not error on unknown proxy commands", function()
		local env = fake.load_driver("hue_light", {})
		assert.has_no.errors(function()
			env.ReceivedFromProxy(5001, "SOMETHING_NEW", {})
		end)
	end)
end)
