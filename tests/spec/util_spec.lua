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
		assert.equal("living\troom", util.norm("\n Living\tRoom \t\r\n"))
		assert.equal("", util.norm(" \t "))
	end)

	it("norm takes time linear in the length, however the blanks lie", function()
		-- "%s+$" would take minutes on this (20000 inner blanks: 1.5 s on lua5.1).
		assert.equal("x" .. string.rep(" ", 200000) .. "y", util.norm("X" .. string.rep(" ", 200000) .. "Y"))
		assert.equal("x y", util.norm("x y" .. string.rep("\t", 200000)))
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

	-- Security review 2026-10-25 finding 8 (docs/security-fixes-design.md §2).
	describe("display_name", function()
		local function utf8_whole(text)
			-- No lead byte without all its continuation bytes, and no stray ones.
			local i = 1
			while i <= #text do
				local b = text:byte(i)
				local n = b < 0x80 and 0 or (b >= 0xF0 and 3) or (b >= 0xE0 and 2) or (b >= 0xC0 and 1) or -1
				if n < 0 then return false end
				for k = 1, n do
					local c = text:byte(i + k)
					if not c or c < 0x80 or c > 0xBF then return false end
				end
				i = i + n + 1
			end
			return true
		end

		it("caps at 100 characters, and at 400 bytes for text that is not UTF-8", function()
			assert.equal(100, util.NAME_MAX)
			assert.equal(400, util.NAME_MAX_BYTES)
		end)

		it("is empty for nil and every non-string but a number", function()
			assert.equal("", util.display_name(nil))
			assert.equal("", util.display_name({}), "a JSON null decodes as a table")
			assert.equal("", util.display_name(true))
			assert.equal("", util.display_name(print))
			assert.equal("7", util.display_name(7))
			assert.equal("2.5", util.display_name(2.5))
		end)

		it("drops control characters, trims, and keeps commas and UTF-8 text", function()
			assert.equal("DeskLamp", util.display_name("Desk\nLamp"))
			assert.equal("Desk Lamp", util.display_name("\t Desk\r Lamp\0\127 \n"))
			assert.equal("Kitchen, North", util.display_name("Kitchen, North"))
			assert.equal("Küche → Bad 2", util.display_name("  Küche → Bad 2  "))
			assert.equal("Desk Lamp", util.display_name("Desk Lamp"), "a plain name is left as it is")
		end)

		it("is empty for a name with nothing to show", function()
			assert.equal("", util.display_name(""))
			assert.equal("", util.display_name("\n\t\r\0\27"))
			assert.equal("", util.display_name("   \n  "))
		end)

		it("keeps exactly 100 characters and cuts the 101st", function()
			local name = string.rep("a", 100)
			assert.equal(name, util.display_name(name))
			assert.equal(name, util.display_name(name .. "b"))
			assert.equal(name, util.display_name(name .. "bcdefgh" .. string.rep("x", 1000)))
			assert.equal(name, util.display_name("\n" .. name .. "\n"), "control characters do not count")
		end)

		it("never cuts a name a genuine bridge gives: a zone scene of two 32-character names", function()
			for _, name in ipairs({ string.rep("z", 32) .. " " .. string.rep("s", 32),
				string.rep("ü", 32) .. " " .. string.rep("→", 32), string.rep("😀", 32) .. " " .. string.rep("😀", 32) }) do
				assert.equal(name, util.display_name(name))
			end
		end)

		it("counts characters, not bytes, and never cuts inside one", function()
			assert.equal(string.rep("ü", 100), util.display_name(string.rep("ü", 100)), "200 bytes stay")
			assert.equal(string.rep("ü", 100), util.display_name(string.rep("ü", 101)))
			assert.equal(string.rep("→", 100), util.display_name(string.rep("→", 150)))
			assert.equal(string.rep("😀", 100), util.display_name(string.rep("😀", 120)), "400 bytes, the most UTF-8 takes")
			assert.equal(string.rep("a", 99) .. "😀", util.display_name(string.rep("a", 99) .. "😀😀"))
			for _, text in ipairs({ string.rep("ü", 140), "x" .. string.rep("→", 130), "xy" .. string.rep("😀", 120),
				string.rep("aü→😀", 40) }) do
				local out = util.display_name(text)
				assert.is_true(utf8_whole(out), text)
				assert.equal(text:sub(1, #out), out, "a prefix of the name")
				local chars = select(2, out:gsub("[^\128-\191]", ""))
				assert.equal(100, chars, text)
			end
		end)

		it("trims a blank the cut leaves at the end", function()
			assert.equal(string.rep("a", 99), util.display_name(string.rep("a", 99) .. " bcd"))
		end)

		it("bounds text that is not UTF-8 at 400 bytes, backing over at most three", function()
			assert.equal(397, #util.display_name(string.rep("\128", 1000)))
			local out = util.display_name(string.rep("ü", 100) .. string.rep("\128", 300))
			assert.equal(397, #out)
			assert.equal(string.rep("ü", 100), out:sub(1, 200))
		end)

		it("takes time linear in the length, however the blanks lie", function()
			-- "%s+$" would take minutes on this (20000 inner blanks: 1.5 s on lua5.1).
			assert.equal("x", util.display_name("x" .. string.rep(" ", 200000) .. "y"))
			assert.equal("x y", util.display_name("x y" .. string.rep(" ", 200000)))
			assert.equal(string.rep("a ", 49) .. "a", util.display_name(string.rep("a ", 200000)), "the cut's blank trimmed")
		end)

		it("is idempotent, so a name made from a display name compares equal to it", function()
			for _, text in ipairs({ "Desk Lamp", "Desk\nLamp", "  a  ", string.rep("a", 99) .. " bcd",
				string.rep("ü", 140), string.rep("a", 99) .. "😀😀", string.rep("\128", 1000),
				string.rep("ü", 100) .. string.rep("\128", 300), "\n", 7, {} }) do
				local once = util.display_name(text)
				assert.equal(once, util.display_name(once), tostring(text))
			end
		end)
	end)

	it("name_key compares display names, trimmed and case-insensitive", function()
		local long = string.rep("Lamp ", 20)
		assert.equal(util.name_key(long), util.name_key(util.display_name(long)))
		assert.equal("desklamp", util.name_key(" Desk\nLamp "))
		assert.equal("living room", util.name_key("  Living Room "))
		assert.equal("", util.name_key(nil))
		assert.equal("", util.name_key({}))
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
