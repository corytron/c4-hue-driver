-- The shared pure helpers of the bridge modules: the outputs the modules'
-- own copies produced before they were merged (docs/reviews/slim-lights.md).

local util = require("bridge.util")

describe("bridge.util", function()
	it("positive takes numbers above zero only", function()
		assert.equal(3, util.positive("3"))
		assert.equal(0.5, util.positive(0.5))
		assert.is_nil(util.positive(0))
		assert.is_nil(util.positive("-1"))
		assert.is_nil(util.positive("x"))
		assert.is_nil(util.positive(nil))
	end)

	it("norm trims and lower-cases", function()
		assert.equal("living room", util.norm("  Living Room "))
		assert.equal("", util.norm(nil))
	end)

	it("sanitise turns commas into spaces", function()
		assert.equal("a  b", util.sanitise("a, b"))
		assert.equal("7", util.sanitise(7))
	end)

	it("dates read ? when unknown", function()
		assert.equal("?", util.date_of(nil))
		assert.equal("?", util.short_date_of(nil))
		assert.equal(os.date("%Y-%m-%d", 1761000000), util.date_of(1761000000))
		assert.equal(os.date("%m-%d", 1761000000), util.short_date_of(1761000000))
	end)

	it("plural adds an s except for one", function()
		assert.equal("1 light", util.plural(1, "light"))
		assert.equal("0 lights", util.plural(0, "light"))
		assert.equal("3 scenes", util.plural(3, "scene"))
	end)

	it("some names up to the limit, then counts the rest", function()
		assert.equal("a, b", util.some({ "a", "b" }, 3))
		assert.equal("a, b, c", util.some({ "a", "b", "c" }, 3))
		assert.equal("a, b, c +2 more", util.some({ "a", "b", "c", "d", "e" }, 3))
		assert.equal("", util.some({}, 3))
	end)

	it("signature is stable across key order", function()
		assert.equal(util.signature({ a = 1, b = "x" }), util.signature({ b = "x", a = 1 }))
		assert.equal("a=1\nb=x", util.signature({ b = "x", a = 1 }))
		assert.are_not.equal(util.signature({ a = 1 }), util.signature({ a = 2 }))
	end)

	it("has_field and empty_list", function()
		assert.is_true(util.has_field({ "on", "brightness" }, "on"))
		assert.is_false(util.has_field({ "on" }, "x"))
		assert.same({ { text = "(nothing)", value = "" } }, util.empty_list("(nothing)"))
	end)
end)
