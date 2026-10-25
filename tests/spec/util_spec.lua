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

	-- Issue #45 (security review 2026-10-24 finding 10).
	it("sanitise drops control characters and keeps UTF-8 text", function()
		assert.equal("DeskLamp", util.sanitise("Desk\nLamp"))
		assert.equal("Desk Lamp", util.sanitise("Desk\t Lamp\r\0\127"))
		assert.equal("Küche → Bad 2", util.sanitise("Küche → Bad 2"))
		assert.equal("a b", util.sanitise("a,\nb"))
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

	-- docs/reviews/diff-review-2026-10-24.md row 7 (issue #55).
	it("has_field is false for a nil or non-table list", function()
		assert.is_false(util.has_field(nil, "x"))
		assert.is_false(util.has_field("on", "on"))
	end)

	-- Row 10: the one copy lights.lua and zone_lights.lua share.
	it("copy_caps normalises a persisted caps block, with an optional min_dim default", function()
		local stored = { has_color = "true", has_cct = true, mirek_min = "153", mirek_max = 454, min_dim = "0.2", extra = 1 }
		assert.same({ has_color = true, has_cct = true, mirek_min = 153, mirek_max = 454, min_dim = 0.2 },
			util.copy_caps(stored))
		assert.same({ has_color = false, has_cct = false }, util.copy_caps({ has_color = "yes" }))
		assert.same({ has_color = false, has_cct = false, min_dim = 1 }, util.copy_caps({}, 1), "the zone lights' default")
		assert.equal(0.2, util.copy_caps(stored, 1).min_dim, "the default fills only a missing min_dim")
		assert.is_nil(util.copy_caps(nil))
		assert.is_nil(util.copy_caps("junk", 1))
	end)

	it("same_caps compares every field, and nil only with nil", function()
		local a = util.copy_caps({ has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 1 })
		assert.is_true(util.same_caps(a, util.copy_caps(a)))
		for field, value in pairs({ has_color = false, has_cct = false, mirek_min = 154, mirek_max = 454, min_dim = 2 }) do
			local b = util.copy_caps(a)
			b[field] = value
			assert.is_false(util.same_caps(a, b), field)
		end
		assert.is_true(util.same_caps(nil, nil))
		assert.is_false(util.same_caps(nil, a))
		assert.is_false(util.same_caps(a, nil))
	end)
end)
