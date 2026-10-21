-- light.caps: the single DYNAMIC_CAPABILITIES_CHANGED per light.

local fake = require("helpers.fake_c4")

describe("light.caps", function()
	local caps, state

	before_each(function()
		fake.install_c4()
		package.loaded["light.caps"] = nil
		package.loaded["light.state"] = nil
		caps = require("light.caps")
		state = require("light.state")
	end)

	local function bulb(params)
		local st = state.new()
		state.configure(st, params)
		return st
	end

	it("announces colour and CCT with the Kelvin bounds as multiples of 10", function()
		local p = caps.params(bulb({ has_color = "true", has_cct = "true", mirek_min = "153", mirek_max = "500" }))
		assert.same({
			supports_color = "true",
			supports_color_correlated_temperature = "true",
			color_correlated_temperature_min = 2000,   -- 1000000 / 500
			color_correlated_temperature_max = 6530,   -- 1000000 / 153 = 6535.9, rounded inward
		}, p)
	end)

	it("announces a CCT-only bulb without colour", function()
		local p = caps.params(bulb({ has_color = "false", has_cct = "true", mirek_min = "153", mirek_max = "454" }))
		assert.equal("false", p.supports_color)
		assert.equal("true", p.supports_color_correlated_temperature)
		assert.equal(2210, p.color_correlated_temperature_min)   -- 2202.6 rounded up
		assert.equal(6530, p.color_correlated_temperature_max)
	end)

	it("announces a white-only bulb with neither, and no bounds", function()
		local p = caps.params(bulb({ has_color = "false", has_cct = "false" }))
		assert.same({ supports_color = "false", supports_color_correlated_temperature = "false" }, p)
	end)

	it("uses one value for both bounds when the white point is fixed", function()
		local p = caps.params(bulb({ has_cct = "true", mirek_min = "370", mirek_max = "370" }))
		assert.equal(2700, p.color_correlated_temperature_min)
		assert.equal(2700, p.color_correlated_temperature_max)
	end)

	it("keeps the bounds inside what the proxy accepts", function()
		local p = caps.params(bulb({ has_cct = "true", mirek_min = "10", mirek_max = "5000" }))
		assert.equal(500, p.color_correlated_temperature_min)
		assert.equal(20000, p.color_correlated_temperature_max)
	end)
end)
