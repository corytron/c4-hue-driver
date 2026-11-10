-- light.turnon: On Mode, colour on modes and what the proxy says about them
-- (#429, #427; docs/turn-on-design.md §7.4, §9.1).

local fake = require("helpers.fake_c4")
local log = require("common.log")

describe("light.turnon", function()
	local turnon, c4, lines

	-- A colour temperature as the proxy sends it: the controller's xy, mode 1.
	local function cct(k)
		local x, y = C4:ColorCCTtoXY(k)
		return { x = x, y = y, mode = 1 }
	end

	local function kelvin(c)
		return C4:ColorXYtoCCT(c.x, c.y)
	end

	-- The module on the fake controller's persistence, as the driver hands it.
	local function new()
		return turnon.new({
			get = function(key) return C4:PersistGetValue(key) end,
			set = function(key, value) C4:PersistSetValue(key, value) end,
			delete = function(key) C4:PersistDeleteValue(key) end,
		})
	end

	local function color_preset(t, name, id, c, command)
		return turnon.update_color_preset(t, { COMMAND = command or "MODIFIED", ID = id and tostring(id), NAME = name,
			COLOR_X = tostring(c.x), COLOR_Y = tostring(c.y), COLOR_MODE = tostring(c.mode) })
	end

	local function brightness_preset(t, name, id, level, command)
		return turnon.update_brightness_preset(t, { COMMAND = command or "MODIFIED", ID = id and tostring(id),
			NAME = name, LEVEL = level and tostring(level) })
	end

	-- A light with On 2700 K (id 20) and Dim 2200 K (id 21), as the house will have.
	local function with_on_and_dim(t, on, dim)
		color_preset(t, "On", 20, on or cct(2700))
		color_preset(t, "Dim", 21, dim or cct(2200))
		return t
	end

	local function fade(t, on, dim)
		return turnon.update_color_on_mode(t, {
			COLOR_PRESET_ID = "20", COLOR_PRESET_ORIGIN = "1",
			COLOR_PRESET_COLOR_X = tostring(on.x), COLOR_PRESET_COLOR_Y = tostring(on.y),
			COLOR_PRESET_COLOR_MODE = tostring(on.mode),
			COLOR_FADE_PRESET_ID = "21", COLOR_FADE_PRESET_ORIGIN = "1",
			COLOR_FADE_PRESET_COLOR_X = tostring(dim.x), COLOR_FADE_PRESET_COLOR_Y = tostring(dim.y),
			COLOR_FADE_PRESET_COLOR_MODE = tostring(dim.mode),
		})
	end

	local function near(expected, actual, tolerance, what)
		assert.is_true(math.abs(expected - actual) <= tolerance,
			string.format("%s: expected %s within %s, got %s", what or "value", tostring(expected),
				tostring(tolerance), tostring(actual)))
	end

	local function same_xy(expected, actual, what)
		assert.is_table(actual, what)
		near(expected.x, actual.x, 1e-9, (what or "colour") .. " x")
		near(expected.y, actual.y, 1e-9, (what or "colour") .. " y")
		assert.equal(expected.mode, actual.mode, (what or "colour") .. " mode")
	end

	local function warnings()
		local out = {}
		for _, line in ipairs(lines) do
			if line:find("^%[WARN%]") then
				out[#out + 1] = line
			end
		end
		return out
	end

	before_each(function()
		c4 = fake.install_c4()
		package.loaded["light.turnon"] = nil
		turnon = require("light.turnon")
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(false)
	end)

	after_each(function()
		log.sink = print
	end)

	describe("UPDATE_* from the proxy", function()
		it("parses UPDATE_* with underscore and spaced names", function()
			local t = new()
			assert.is_true(turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "4",
				BRIGHTNESS_PRESET_LEVEL = "30" }))
			assert.same({ level = 30, preset_id = 4, native = false }, turnon.turn_on(t, { preset = 100 }))
			assert.is_true(turnon.update_brightness_on_mode(t, { ["BRIGHTNESS PRESET ID"] = "5",
				["BRIGHTNESS PRESET LEVEL"] = "40" }))
			assert.same({ level = 40, preset_id = 5, native = false }, turnon.turn_on(t, { preset = 100 }))
			assert.is_false(turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "5",
				BRIGHTNESS_PRESET_LEVEL = "40" }), "the same mode again changes nothing")

			-- UPDATE_BRIGHTNESS_PRESET prints its id as ID on one page, PRESET ID on another.
			assert.is_true(turnon.update_brightness_preset(t, { COMMAND = "ADDED", ["PRESET ID"] = "3",
				NAME = "Previous", LEVEL = "20" }))
			assert.is_true(turnon.is_previous_preset(t, 3))
			assert.is_true(turnon.update_brightness_preset(t, { COMMAND = "ADDED", PRESET_ID = "2", NAME = "Off",
				LEVEL = "0" }))
			assert.equal(2, turnon.off_preset_id(t))

			local dim = cct(2200)
			assert.is_true(turnon.update_color_preset(t, { COMMAND = "ADDED", ID = "7", NAME = "Dim",
				["COLOR X"] = tostring(dim.x), ["COLOR Y"] = tostring(dim.y), ["COLOR MODE"] = "1" }))
			same_xy(dim, turnon.off_color(t, 1000), "the Dim colour")

			local red = { x = 0.64, y = 0.33, mode = 0 }
			assert.is_true(turnon.update_color_on_mode(t, { ["COLOR PRESET ID"] = "8", ["COLOR PRESET ORIGIN"] = "2",
				["COLOR PRESET COLOR X"] = "0.64", ["COLOR PRESET COLOR Y"] = "0.33", ["COLOR PRESET COLOR MODE"] = "0" }))
			local on = turnon.on_color(t, 40, { preset = 40 })
			same_xy(red, on, "the on mode colour")
			assert.equal(8, on.id)
			assert.equal(2, on.origin)
			assert.same({}, warnings())
		end)

		it("refuses messages without what they need, with a warning, and keeps the mode", function()
			local t = new()
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "4", BRIGHTNESS_PRESET_LEVEL = "30" })
			assert.is_false(turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_LEVEL = "50" }))
			assert.is_false(turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "four" }))
			assert.is_false(turnon.update_brightness_preset(t, { COMMAND = "MODIFIED", LEVEL = "50" }))
			assert.is_false(turnon.update_brightness_preset(t, { COMMAND = "RENAMED", ID = "4", LEVEL = "50" }))
			assert.is_false(turnon.update_color_preset(t, { COMMAND = "ADDED", COLOR_X = "0.3", COLOR_Y = "0.3" }))
			assert.is_false(turnon.update_color_on_mode(t, { COLOR_PRESET_ORIGIN = "1" }))
			assert.is_false(turnon.update_color_on_mode(t, nil))
			assert.equal(7, #warnings())
			assert.same({ level = 30, preset_id = 4, native = false }, turnon.turn_on(t, { preset = 100 }))
			assert.equal(turnon.MODE_PRESET, select(2, turnon.modes(t)))
		end)

		it("an UPDATE_BRIGHTNESS_PRESET for the On preset returns its level", function()
			local t = new()
			local _, level = brightness_preset(t, "On", 1, 60)
			assert.equal(60, level)
			_, level = turnon.update_brightness_preset(t, { COMMAND = "MODIFIED", ID = "1", LEVEL = "70" })
			assert.equal(70, level, "id 1 is the On preset (F6)")
			_, level = brightness_preset(t, "Ein", 1, 65)
			assert.equal(65, level, "a name of none of the three, on the On id")
			_, level = brightness_preset(t, "Off", 2, 0)
			assert.is_nil(level)
			_, level = brightness_preset(t, "Evening", 6, 30)
			assert.is_nil(level)
			_, level = brightness_preset(t, "On", 1, nil)
			assert.is_nil(level, "no level, nothing to store")
			_, level = brightness_preset(t, "On", 1, 60, "REMOVED")
			assert.is_nil(level)
		end)

		it("REMOVED of the on mode preset falls back to the On preset", function()
			local t = new()
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "6", BRIGHTNESS_PRESET_LEVEL = "30" })
			assert.is_false((brightness_preset(t, "Other", 9, nil, "REMOVED")), "another preset: nothing to do")
			assert.same({ level = 30, preset_id = 6, native = false }, turnon.turn_on(t, { preset = 80 }))
			assert.is_true((brightness_preset(t, "Evening", 6, nil, "REMOVED")))
			assert.same({ level = 80, preset_id = 1, native = false }, turnon.turn_on(t, { preset = 80 }))
			assert.is_nil(c4.persist.turnon_brightness)
		end)

		it("follows a preset's level change while it is the on mode", function()
			local t = new()
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "6", BRIGHTNESS_PRESET_LEVEL = "30" })
			assert.is_true((brightness_preset(t, "Evening", 6, 45)))
			assert.equal(45, turnon.turn_on(t, { preset = 80 }).level)
			assert.equal(45, c4.persist.turnon_brightness.level)
		end)

		it("a change to the on mode's colour preset changes the on colour; REMOVED falls back to On", function()
			local t = with_on_and_dim(new())
			local blue = { x = 0.15, y = 0.06, mode = 0 }
			turnon.update_color_on_mode(t, { COLOR_PRESET_ID = "30", COLOR_PRESET_COLOR_X = "0.15",
				COLOR_PRESET_COLOR_Y = "0.06", COLOR_PRESET_COLOR_MODE = "0" })
			same_xy(blue, turnon.on_color(t, 100, { preset = 100 }))

			local purple = { x = 0.25, y = 0.1, mode = 0 }
			assert.is_true(color_preset(t, "Mine", 30, purple))
			same_xy(purple, turnon.on_color(t, 100, { preset = 100 }))
			assert.equal(0.25, c4.persist.turnon_color.x, "the mode's copy is persisted")

			assert.is_true(color_preset(t, "Mine", 30, purple, "REMOVED"))
			same_xy(cct(2700), turnon.on_color(t, 100, { preset = 100 }), "back to the On colour")
			assert.is_nil(c4.persist.turnon_color)
		end)

		it("tells the colour on modes apart (§7.3)", function()
			local t = with_on_and_dim(new())
			assert.equal(turnon.MODE_PRESET, select(2, turnon.modes(t)), "the default (D10)")

			assert.is_true(fade(t, cct(4000), cct(2000)))
			assert.equal(turnon.MODE_FADE, select(2, turnon.modes(t)))

			color_preset(t, "Previous", 22, { x = 0.5, y = 0.4, mode = 0 })
			assert.is_true(turnon.update_color_on_mode(t, { COLOR_PRESET_ID = "22", COLOR_PRESET_ORIGIN = "1",
				COLOR_PRESET_COLOR_X = "0.5", COLOR_PRESET_COLOR_Y = "0.4", COLOR_PRESET_COLOR_MODE = "0" }))
			assert.equal(turnon.MODE_PREVIOUS, select(2, turnon.modes(t)))
			assert.is_nil(c4.persist.turnon_color.x, "the Previous colour moves at every off; not kept")

			-- A preset named by id only is looked up at each turn-on, so a later answer fills it.
			assert.is_true(turnon.update_color_on_mode(t, { COLOR_PRESET_ID = "31", COLOR_PRESET_ORIGIN = "1" }))
			assert.equal(turnon.MODE_PRESET, select(2, turnon.modes(t)))
			same_xy(cct(2700), turnon.on_color(t, 100, { preset = 100 }), "unknown id: the proxy's On colour")
			local green = { x = 0.3, y = 0.6, mode = 0 }
			color_preset(t, "Garden", 31, green)
			same_xy(green, turnon.on_color(t, 100, { preset = 100 }))
		end)

		it("never keeps a Previous brightness level", function()
			local t = new()
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "3", BRIGHTNESS_PRESET_LEVEL = "35" })
			assert.equal(35, c4.persist.turnon_brightness.level)
			brightness_preset(t, "Previous", 3, 35)
			assert.same({ id = 3 }, c4.persist.turnon_brightness, "stripped once 3 is known as Previous")
			local writes = #c4.calls
			assert.is_false((brightness_preset(t, "Previous", 3, 50)), "the proxy moving Previous at an off")
			assert.equal(writes, #c4.calls, "nothing written")
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "3", BRIGHTNESS_PRESET_LEVEL = "50" })
			assert.same({ id = 3 }, c4.persist.turnon_brightness)
		end)
	end)

	describe("GET_SETUP", function()
		-- Shaped as the proxy's answer (LV2 cmds _16.5-GETSETUP.md), values our own.
		local SETUP = [[<?xml version="1.0" encoding="UTF-8"?>
<setup>
  <supports_target>True</supports_target>
  <brightnesses minimum="0" maximum="100" resolution="1">
    <level name="Off" level_setable="true" level="0" levelType="2"/>
    <level name="On" level_setable="true" level="80" levelType="2"/>
  </brightnesses>
  <supports_color>True</supports_color>
  <colors color_correlated_temperature_min="2000" color_correlated_temperature_max="6500">
    <color name="Relax" category="2" color_x="0" color_y="0" color_mode="1" color_correlated_temperature="0"/>
    <color name="Red" category="2" editable="" color_x="0.64" color_y="0.33" color_mode="0"/>
    <color name="Dim" category="1" editable="" color_x="%s" color_y="%s" color_mode="1"/>
    <color name="On" category="1" editable="" color_x="%s" color_y="%s" color_mode="1"/>
  </colors>
</setup>]]

		local function setup_text()
			local dim, on = cct(2200), cct(2700)
			return string.format(SETUP, dim.x, dim.y, on.x, on.y)
		end

		it("take_setup reads the GET_SETUP sample, with and without ids; junk changes nothing", function()
			local t = new()
			local colors, levels = turnon.take_setup(t, setup_text())
			assert.equal(3, colors, "Red, Dim, On; Relax has no colour")
			assert.equal(2, levels)
			same_xy(cct(2700), turnon.on_color(t, 80, { preset = 80 }), "the On colour at the preset level")
			same_xy(cct(2200), turnon.off_color(t, 3000), "the Dim colour")
			assert.same({ level = 80, preset_id = 1, native = false }, turnon.turn_on(t, { preset = 80 }),
				"never moves the brightness side (D19)")
			assert.is_not_nil(c4.persist.turnon_presets.on_x)

			local with_ids = [[<setup><brightnesses>
				<level name="Off" level="0" id="2"/><level name="On" level="80" id="1"/>
				<level name="Previous" level="35" id="3"/><level name="Evening" level="30" id="6"/>
				</brightnesses><colors>
				<color name="Red" category="2" color_x="0.64" color_y="0.33" color_mode="0" id="12"/>
				<color name="Previous" category="1" color_x="0" color_y="0" color_mode="0" id="22"/>
				<color name="Warm" category="1" color_x="0" color_y="0" color_mode="1"
					color_correlated_temperature="3000" id="13"/>
				</colors></setup>]]
			colors, levels = turnon.take_setup(t, with_ids)
			assert.equal(2, colors)
			assert.equal(4, levels)
			assert.equal(2, turnon.off_preset_id(t))
			assert.is_true(turnon.is_previous_preset(t, 3))
			assert.equal(22, c4.persist.turnon_presets.color_previous_id)
			local red = turnon.color_for_preset(t, 12, 2)
			same_xy({ x = 0.64, y = 0.33, mode = 0 }, red)
			assert.equal(12, red.id)
			near(3000, kelvin(turnon.color_for_preset(t, 13)), 20, "a CCT preset given by temperature")
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "6" })
			assert.equal(30, turnon.turn_on(t, { preset = 80 }).level, "a level learned for the on mode's preset")

			local before = c4.persist.turnon_presets
			local writes = #c4.calls
			for _, junk in ipairs({ "not xml at all", "", "<<<>>>", "&lt;junk", "<setup><color name=",
				"<error>no such request</error>" }) do
				assert.same({ 0, 0 }, { turnon.take_setup(t, junk) }, junk)
			end
			assert.same({ 0, 0 }, { turnon.take_setup(t, nil) })
			assert.same({ 0, 0 }, { turnon.take_setup(t, { "<color/>" }) })
			assert.equal(writes, #c4.calls, "junk writes nothing")
			assert.equal(before, c4.persist.turnon_presets)
			same_xy(cct(2700), turnon.on_color(t, 80, { preset = 80 }))
		end)

		it("reads escaped XML, single quotes and upper-case attributes (variable 1300)", function()
			local t = new()
			local on = cct(3000)
			local text = string.format("&lt;colors&gt;&lt;color name=&quot;On&quot; color_x=&quot;%s&quot; "
				.. "color_y=&quot;%s&quot; color_mode=&quot;1&quot;/&gt;&lt;/colors&gt;", on.x, on.y)
			assert.equal(1, (turnon.take_setup(t, text)))
			same_xy(on, turnon.on_color(t, 100, { preset = 100 }))

			local dim = cct(2000)
			text = string.format("<Colors><Color NAME='dim' COLOR_X='%s' COLOR_Y='%s' COLOR_MODE='1'/></Colors>",
				dim.x, dim.y)
			assert.equal(1, (turnon.take_setup(t, text)))
			same_xy(dim, turnon.off_color(t, 1000))
		end)

		it("prefers the device's own On preset to a Color Agent preset of the same name", function()
			local t = new()
			local mine = cct(2700)
			turnon.take_setup(t, string.format([[<colors>
				<color name="On" category="2" color_x="0.2" color_y="0.2" color_mode="0"/>
				<color name="On" category="1" color_x="%s" color_y="%s" color_mode="1"/>
				<color name="ON" category="2" color_x="0.3" color_y="0.3" color_mode="0"/>
				</colors>]], mine.x, mine.y))
			same_xy(mine, turnon.on_color(t, 100, { preset = 100 }))
		end)

		it("refreshes the on mode's copy of a preset it names", function()
			local t = new()
			color_preset(t, "On", 20, cct(4000))
			turnon.update_color_on_mode(t, { COLOR_PRESET_ID = "20", COLOR_PRESET_ORIGIN = "1",
				COLOR_PRESET_COLOR_X = tostring(cct(4000).x), COLOR_PRESET_COLOR_Y = tostring(cct(4000).y),
				COLOR_PRESET_COLOR_MODE = "1" })
			turnon.take_setup(t, setup_text()) -- On 2700 K, no ids: matched through the learned id 20
			same_xy(cct(2700), turnon.on_color(t, 100, { preset = 100 }))
		end)
	end)

	describe("persistence", function()
		it("persists and reloads; a corrupt copy is dropped with a warning", function()
			local t = with_on_and_dim(new())
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "6", BRIGHTNESS_PRESET_LEVEL = "30" })
			brightness_preset(t, "Off", 2, 0)
			brightness_preset(t, "Previous", 3, 40)
			fade(t, cct(4000), cct(2000))

			local stored = c4.persist.turnon_brightness
			t.brightness.level = 99
			assert.equal(30, stored.level, "the database holds a copy, not the live table")
			t.brightness.level = 30

			local again = new()
			turnon.load(again)
			assert.same({ level = 30, preset_id = 6, native = false }, turnon.turn_on(again, { preset = 80 }))
			assert.equal(2, turnon.off_preset_id(again))
			assert.is_true(turnon.is_previous_preset(again, 3))
			assert.equal(turnon.MODE_FADE, select(2, turnon.modes(again)))
			same_xy(turnon.level_color(t, 50, {}), turnon.level_color(again, 50, {}), "the fade formula")
			same_xy(turnon.off_color(t, 1000), turnon.off_color(again, 1000), "the Dim colour")
			assert.same(t.presets, again.presets)
			assert.same({}, warnings())

			c4.persist.turnon_brightness = "junk"
			c4.persist.turnon_color = { kind = "sparkle" }
			c4.persist.turnon_presets = { on_x = 5, on_y = 0.4 }
			local fresh = new()
			turnon.load(fresh)
			assert.equal(3, #warnings())
			assert.is_nil(c4.persist.turnon_brightness)
			assert.is_nil(c4.persist.turnon_color)
			assert.is_nil(c4.persist.turnon_presets)
			assert.same({ level = 80, preset_id = 1, native = false }, turnon.turn_on(fresh, { preset = 80 }))
			assert.is_nil(turnon.on_color(fresh, 80, { preset = 80 }), "defaults: no On colour known")

			-- Corrupt in other ways: each dropped on its own.
			c4.persist.turnon_brightness = { id = 4, level = 140 }
			c4.persist.turnon_color = { kind = "fade", id = 20, x = 0.4, y = 0.4 }
			c4.persist.turnon_presets = { on_id = "one" }
			lines = {}
			turnon.load(new())
			assert.equal(3, #warnings())
		end)

		it("loads nothing from a fresh device without a warning", function()
			local t = turnon.new({ get = function() end }) -- Director returns no value at all
			turnon.load(t)
			assert.same({}, warnings())
			assert.same({ level = 100, preset_id = 1, native = false }, turnon.turn_on(t, {}))
		end)

		it("works without a store", function()
			local t = turnon.new()
			turnon.load(t)
			assert.is_true(turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "6",
				BRIGHTNESS_PRESET_LEVEL = "30" }))
			assert.equal(30, turnon.turn_on(t, nil).level)
		end)
	end)

	describe("brightness decisions", function()
		local function previous_mode(t)
			brightness_preset(t, "Previous", 3, 40)
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "3", BRIGHTNESS_PRESET_LEVEL = "40" })
			return t
		end

		it("turn_on: Preset at the preset level; unknown id at its level; Previous single from last_on, "
			.. "then cached, then preset; Previous group is native", function()
			local t = new()
			assert.same({ level = 80, preset_id = 1, native = false }, turnon.turn_on(t, { preset = 80 }), "D3")
			assert.same({ level = 100, preset_id = 1, native = false }, turnon.turn_on(t, nil))
			assert.same({ level = 80, preset_id = 1, native = false },
				turnon.turn_on(t, { preset = 80, last_on = 35, cached = 50 }), "Preset ignores the last level")

			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "1", BRIGHTNESS_PRESET_LEVEL = "60" })
			assert.equal(80, turnon.turn_on(t, { preset = 80 }).level, "the On preset is the Default On Brightness")

			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "7", BRIGHTNESS_PRESET_LEVEL = "25" })
			assert.same({ level = 25, preset_id = 7, native = false }, turnon.turn_on(t, { preset = 80 }))
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "8" })
			assert.same({ level = 80, preset_id = 8, native = false }, turnon.turn_on(t, { preset = 80 }),
				"no level known: the Default On Brightness")

			previous_mode(t)
			assert.equal(turnon.MODE_PREVIOUS, (turnon.modes(t)))
			assert.same({ level = 35, preset_id = 3, native = false },
				turnon.turn_on(t, { preset = 80, last_on = 35, cached = 50 }))
			assert.same({ level = 20, preset_id = 3, native = false },
				turnon.turn_on(t, { preset = 80, cached = 20.16 }), "Hue's level, a whole percent")
			assert.same({ level = 80, preset_id = 3, native = false }, turnon.turn_on(t, { preset = 80 }))
			assert.same({ level = 80, preset_id = 3, native = false },
				turnon.turn_on(t, { preset = 80, last_on = 0, cached = 0 }))
			assert.same({ level = 35, preset_id = 3, native = true },
				turnon.turn_on(t, { preset = 80, group = true, last_on = 35 }), "D6: each lamp at its own level")
			assert.same({ level = 80, preset_id = 3, native = true }, turnon.turn_on(t, { preset = 80, group = true }))
		end)

		it("while_on: Preset gives the mode's level, Previous the On preset", function()
			local t = new()
			assert.same({ level = 70, preset_id = 1 }, turnon.while_on(t, { preset = 70 }))
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "7", BRIGHTNESS_PRESET_LEVEL = "25" })
			assert.same({ level = 25, preset_id = 7 }, turnon.while_on(t, { preset = 70 }))
			previous_mode(t)
			assert.same({ level = 70, preset_id = 1 }, turnon.while_on(t, { preset = 70, last_on = 35 }))
			brightness_preset(t, "On", 11, 70)
			assert.same({ level = 70, preset_id = 11 }, turnon.while_on(t, { preset = 70 }), "a learned On id")
		end)

		it("is_previous_preset and off_preset_id know only learned ids", function()
			local t = new()
			assert.is_false(turnon.is_previous_preset(t, 3))
			assert.is_false(turnon.is_previous_preset(t, nil))
			assert.is_nil(turnon.off_preset_id(t))
			brightness_preset(t, "previous", 3, 40)
			brightness_preset(t, " OFF ", 2, 0)
			assert.is_true(turnon.is_previous_preset(t, "3"))
			assert.equal(2, turnon.off_preset_id(t))
			brightness_preset(t, "Off", 2, nil, "REMOVED")
			assert.is_nil(turnon.off_preset_id(t))
		end)
	end)

	describe("colour decisions", function()
		it("on_color: nil without an On colour, in Previous, without abilities; the On colour at the preset level",
			function()
			local t = new()
			assert.is_nil(turnon.on_color(t, 80, { preset = 80 }), "D10: unknown means unchanged")

			color_preset(t, "On", 20, cct(2700))
			local on = turnon.on_color(t, 80, { preset = 80 })
			same_xy(cct(2700), on)
			assert.equal(20, on.id, "the preset as it stands carries its id (D16)")
			same_xy(cct(2700), turnon.on_color(t, 10, { preset = 80 }), "no Dim known: On at every level")

			color_preset(t, "Dim", 21, cct(2200))
			same_xy(cct(2700), turnon.on_color(t, 80, { preset = 80 }))
			same_xy(cct(2200), turnon.on_color(t, 1, { preset = 80 }), "a hold from off starts at 1 %")
			local mid = kelvin(turnon.on_color(t, 40, { preset = 80 }))
			assert.is_true(mid > 2250 and mid < 2650, "blended toward Dim: " .. mid)

			assert.is_nil(turnon.on_color(t, 80, { preset = 80, has_color = false, has_cct = false }))
			assert.is_not_nil(turnon.on_color(t, 80, { preset = 80, has_color = false, has_cct = true }))
			assert.is_not_nil(turnon.on_color(t, 80, { preset = 80, has_color = true, has_cct = false }))
			assert.is_nil(turnon.on_color(t, 0, { preset = 80 }))

			-- The on mode's level is the top: a custom preset turns on in the On colour too.
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "7", BRIGHTNESS_PRESET_LEVEL = "30" })
			same_xy(cct(2700), turnon.on_color(t, 30, { preset = 80 }))
			-- Previous brightness: the top is the Default On Brightness (F14).
			brightness_preset(t, "Previous", 3, 40)
			turnon.update_brightness_on_mode(t, { BRIGHTNESS_PRESET_ID = "3" })
			assert.is_true(kelvin(turnon.on_color(t, 40, { preset = 80, last_on = 40 })) < 2650)

			color_preset(t, "Previous", 22, { x = 0.5, y = 0.4, mode = 0 })
			turnon.update_color_on_mode(t, { COLOR_PRESET_ID = "22", COLOR_PRESET_ORIGIN = "1" })
			assert.is_nil(turnon.on_color(t, 80, { preset = 80 }), "Previous: Hue keeps its colour (D11)")
		end)

		it("blend: the UPDATE_COLOR_PRESET example gives about 3000 K at 40 % (within 20 K)", function()
			local on, dim = cct(4000), cct(2000)
			local c = turnon.blend(dim, on, 40, 80)
			assert.equal(1, c.mode)
			near(3000, kelvin(c), 20, "40 %")
			same_xy(on, turnon.blend(dim, on, 80, 80), "at the Default On Brightness")
			same_xy(on, turnon.blend(dim, on, 100, 80), "and above")

			-- The same through the module: Preset mode while blending.
			local t = with_on_and_dim(new(), on, dim)
			turnon.started(t, true)
			near(3000, kelvin(turnon.level_color(t, 40, { preset = 80 })), 20, "level_color at 40 %")
		end)

		it("blend: fade gives Dim at 1, the mix at 50, On at 100; xy for mixed modes; Dim = On gives On", function()
			local t = new()
			fade(t, cct(4000), cct(2000))
			same_xy(cct(2000), turnon.level_color(t, 1, {}))
			near(2000 + 2000 * 49 / 99, kelvin(turnon.level_color(t, 50, {})), 25, "50 %")
			same_xy(cct(4000), turnon.level_color(t, 100, {}))
			same_xy(cct(2000), turnon.on_color(t, 1, { preset = 80 }), "a turn-on in fade mode")
			same_xy(cct(4000), turnon.on_color(t, 100, { preset = 80 }), "fade's top is 100, not the preset")

			local red, warm = { x = 0.64, y = 0.33, mode = 0 }, cct(2200)
			local f = 49 / 99
			same_xy({ x = warm.x + (red.x - warm.x) * f, y = warm.y + (red.y - warm.y) * f, mode = 0 },
				turnon.blend(warm, red, 50, 100), "mixed modes: linear in xy, full colour")

			local same = cct(2700)
			same_xy(same, turnon.blend(cct(2700), same, 1, 100))
			same_xy(same, turnon.blend(cct(2700), same, 50, 100))
			same_xy(same, turnon.blend(nil, same, 1, 100), "no Dim")
			assert.is_nil(turnon.blend(cct(2200), nil, 50, 100), "no On")
			same_xy(same, turnon.blend(cct(2200), same, 1, 1), "top 1")

			local copy = turnon.blend(nil, same, 1, 100)
			copy.x = 0
			assert.is_true(same.x > 0, "a copy")
		end)

		it("off_color: Dim with a rate, nil at rate 0, nil in Previous", function()
			local t = new()
			color_preset(t, "On", 20, cct(2700))
			assert.is_nil(turnon.off_color(t, 3000), "no Dim known")
			color_preset(t, "Dim", 21, cct(2200))
			local dim = turnon.off_color(t, 3000)
			same_xy(cct(2200), dim)
			assert.equal(21, dim.id)
			same_xy(cct(2200), turnon.off_color(t, "3000"))
			assert.is_nil(turnon.off_color(t, 0), "instant off (guidelines D16)")
			assert.is_nil(turnon.off_color(t, nil))

			fade(t, cct(4000), cct(1900))
			same_xy(cct(1900), turnon.off_color(t, 1000), "Fade: its Dim colour")

			color_preset(t, "Previous", 22, { x = 0.5, y = 0.4, mode = 0 })
			turnon.update_color_on_mode(t, { COLOR_PRESET_ID = "22" })
			assert.is_nil(turnon.off_color(t, 3000))
		end)

		it("blending: an explicit colour ends Preset, not Fade; the on colour keeps it; foreign ends it; "
			.. "off ends it", function()
			local t = with_on_and_dim(new())
			local ctx = { preset = 100 }
			assert.is_nil(turnon.level_color(t, 50, ctx), "no Control4 turn-on yet")
			turnon.started(t, true)
			assert.is_true(turnon.is_blending(t))
			assert.is_not_nil(turnon.level_color(t, 50, ctx))
			assert.is_nil(turnon.level_color(t, 0, ctx))
			assert.is_nil(turnon.level_color(t, 50, { preset = 100, has_color = false, has_cct = false }))

			local on = cct(2700)
			assert.is_true(turnon.is_on_color(t, on.x, on.y, 1), "the on colour: the driver keeps the blend")
			assert.is_not_nil(turnon.level_color(t, 50, ctx))
			turnon.explicit_color(t)
			assert.is_nil(turnon.level_color(t, 50, ctx))

			turnon.started(t, false)
			assert.is_nil(turnon.level_color(t, 50, ctx), "a colour stored while off won (D11)")
			turnon.started(t, true)
			turnon.foreign_color(t)
			assert.is_nil(turnon.level_color(t, 50, ctx))
			turnon.started(t, true)
			turnon.ended(t)
			assert.is_nil(turnon.level_color(t, 50, ctx))

			fade(t, cct(4000), cct(2000))
			turnon.explicit_color(t)
			assert.is_not_nil(turnon.level_color(t, 50, ctx), "Fade applies the formula at the next target")

			color_preset(t, "Previous", 22, { x = 0.5, y = 0.4, mode = 0 })
			turnon.update_color_on_mode(t, { COLOR_PRESET_ID = "22" })
			turnon.started(t, true)
			assert.is_nil(turnon.level_color(t, 50, ctx), "Previous never blends")
		end)

		it("is_on_color matches the on mode preset by id and origin, or by xy within 0.002", function()
			local t = with_on_and_dim(new())
			local on = cct(2700)
			assert.is_true(turnon.is_on_color(t, nil, nil, nil, 20), "the learned On id")
			assert.is_true(turnon.is_on_color(t, on.x + 0.0015, on.y - 0.0015, 1))
			assert.is_false(turnon.is_on_color(t, on.x + 0.003, on.y, 1))
			assert.is_false(turnon.is_on_color(t, on.x, on.y, 0), "same xy, other mode")
			assert.is_false(turnon.is_on_color(t, 0.64, 0.33, 0, 12))

			turnon.update_color_on_mode(t, { COLOR_PRESET_ID = "20", COLOR_PRESET_ORIGIN = "1",
				COLOR_PRESET_COLOR_X = tostring(on.x), COLOR_PRESET_COLOR_Y = tostring(on.y),
				COLOR_PRESET_COLOR_MODE = "1" })
			assert.is_true(turnon.is_on_color(t, nil, nil, nil, "20", "1"))
			assert.is_true(turnon.is_on_color(t, nil, nil, nil, 20))
			assert.is_false(turnon.is_on_color(t, nil, nil, nil, 20, 2), "a Color Agent preset of the same id")
			assert.is_false(turnon.is_on_color(new(), on.x, on.y, 1), "nothing known")
		end)

		it("color_for_preset finds learned presets by id and origin", function()
			local t = with_on_and_dim(new())
			same_xy(cct(2700), turnon.color_for_preset(t, 20))
			same_xy(cct(2200), turnon.color_for_preset(t, "21", "1"))
			assert.is_nil(turnon.color_for_preset(t, 99))
			assert.is_nil(turnon.color_for_preset(t, nil))

			local red, blue = { x = 0.64, y = 0.33, mode = 0 }, { x = 0.15, y = 0.06, mode = 0 }
			color_preset(t, "Red", 12, red) -- UPDATE_COLOR_PRESET carries no origin
			turnon.take_setup(t, '<colors><color name="Blue" category="2" color_x="0.15" color_y="0.06" '
				.. 'color_mode="0" id="12"/></colors>')
			local c = turnon.color_for_preset(t, 12, 2)
			same_xy(blue, c, "the exact origin first")
			assert.equal(12, c.id)
			assert.equal(2, c.origin)
			same_xy(red, turnon.color_for_preset(t, 12, 1), "else one of unknown origin")
			same_xy(red, turnon.color_for_preset(t, 12))

			turnon.update_color_on_mode(t, { COLOR_PRESET_ID = "30", COLOR_PRESET_ORIGIN = "2",
				COLOR_PRESET_COLOR_X = "0.3", COLOR_PRESET_COLOR_Y = "0.6", COLOR_PRESET_COLOR_MODE = "0" })
			same_xy({ x = 0.3, y = 0.6, mode = 0 }, turnon.color_for_preset(t, 30, 2))
			assert.is_nil(turnon.color_for_preset(t, 30, 1), "an origin that differs never matches")

			local got = turnon.color_for_preset(t, 20)
			got.x = 0
			same_xy(cct(2700), turnon.color_for_preset(t, 20), "callers get copies")
		end)
	end)
end)
