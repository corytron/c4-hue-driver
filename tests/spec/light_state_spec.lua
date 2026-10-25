-- light.state: the Hue <-> light_v2 mapping both ways.

local fake = require("helpers.fake_c4")

describe("light.state", function()
	local state, c4

	-- A colour + CCT bulb as HUE_CONFIGURE describes it (all strings).
	local function color_bulb()
		local st = state.new()
		state.configure(st, { rid = "l1", name = "Desk", model = "Hue color lamp", has_color = "true",
			has_cct = "true", mirek_min = "153", mirek_max = "500", min_dim = "0.2" })
		return st
	end

	before_each(function()
		c4 = fake.install_c4()
		package.loaded["light.state"] = nil
		state = require("light.state")
	end)

	describe("configure", function()
		it("parses the string params into typed fields and keeps defaults otherwise", function()
			local st = color_bulb()
			assert.equal("l1", st.rid)
			assert.equal("Desk", st.name)
			assert.equal("Hue color lamp", st.model)
			assert.is_true(st.has_color)
			assert.is_true(st.has_cct)
			assert.equal(153, st.mirek_min)
			assert.equal(500, st.mirek_max)
			assert.equal(0.2, st.min_dim)

			local plain = state.new()
			state.configure(plain, { rid = "l2", has_color = "false", has_cct = "false" })
			assert.is_false(plain.has_color)
			assert.is_false(plain.has_cct)
			assert.equal(153, plain.mirek_min, "Hue's widest range stays as the default")
		end)

		it("does not lose the rid to an empty one", function()
			local st = color_bulb()
			state.configure(st, { rid = "" })
			assert.equal("l1", st.rid)
		end)

		it("takes the lifecycle fields as sent and resets them when absent", function()
			local st = color_bulb()
			assert.is_nil(st.hue_room)
			assert.is_nil(st.id_v1)
			assert.is_false(st.gone)

			state.configure(st, { hue_room = "Office", id_v1 = "/lights/12", state = "gone", gone_since = "1761000000" })
			assert.equal("Office", st.hue_room)
			assert.equal("/lights/12", st.id_v1)
			assert.is_true(st.gone)
			assert.equal(1761000000, st.gone_since)

			state.configure(st, { state = "linked" })
			assert.is_nil(st.hue_room, "an empty room is dropped by SendToDevice, so absent means none")
			assert.is_nil(st.id_v1)
			assert.is_false(st.gone)
			assert.is_nil(st.gone_since)

			state.configure(st, { hue_room = "", state = "gone" })
			assert.is_nil(st.hue_room)
			assert.is_true(st.gone)
			assert.is_nil(st.gone_since, "gone without a date")
		end)

		it("ends a forgotten state", function()
			local st = color_bulb()
			st.forgotten = { name = "Desk" }
			state.configure(st, { rid = "l1" })
			assert.is_nil(st.forgotten)
		end)
	end)

	-- A Hue zone or room as a Hue Light device (docs/zone-light-design.md §5
	-- Messages): the configure names kind "group" and the group's fields.
	describe("configure for a zone or room device", function()
		local function zone(extra)
			local params = { rid = "z1", kind = "group", group_type = "zone", name = "Bedside Lights", light_count = "2",
				model = "Hue zone", hue_room = "Bedside Lights (zone)", id_v1 = "/groups/2", min_dim = "1" }
			for k, v in pairs(extra or {}) do params[k] = v end
			return params
		end

		it("takes the kind as sent, keeps it when a configure names none, and ignores one it does not know", function()
			local st = state.new()
			assert.is_false(state.is_group(st), "never told its kind: a light")
			assert.is_nil(st.kind)

			state.configure(st, zone())
			assert.is_true(state.is_group(st))
			assert.equal(state.KIND_GROUP, st.kind)

			state.configure(st, { rid = "z1", name = "Bedside Lights", state = "gone" })
			assert.is_true(state.is_group(st), "an older bridge answering a zone light as a light names no kind")

			state.configure(st, zone({ kind = "entertainment" }))
			assert.is_true(state.is_group(st))

			state.configure(st, zone({ kind = "light" }))
			assert.is_false(state.is_group(st), "an explicit kind is taken as sent")
			assert.equal(state.KIND_LIGHT, st.kind)
		end)

		it("parses the group fields and resets them when a configure leaves them out", function()
			local st = state.new()
			state.configure(st, zone())
			assert.equal("zone", st.group_type)
			assert.equal(2, st.light_count)
			assert.is_false(st.no_lights)
			assert.equal("Bedside Lights", st.name)
			assert.equal("Hue zone", st.model)
			assert.equal("Bedside Lights (zone)", st.hue_room)
			assert.equal("/groups/2", st.id_v1)
			assert.equal(1, st.min_dim)

			state.configure(st, { rid = "z1", kind = "group", group_type = "room", light_count = "9" })
			assert.equal("room", st.group_type)
			assert.equal(9, st.light_count)

			state.configure(st, { rid = "z1", kind = "group" })
			assert.is_nil(st.group_type)
			assert.is_nil(st.light_count)
			assert.is_false(st.no_lights)
		end)

		it("reads no_lights as off for the proxy until the bridge reports the refilled group", function()
			local st = state.new()
			state.configure(st, zone())
			state.apply_hue(st, { on = "true", brightness = "40", online = "true" })
			assert.equal(40, state.to_proxy_brightness(st))

			state.configure(st, zone({ light_count = "0", no_lights = "true" }))
			assert.is_true(st.no_lights)
			assert.is_false(st.on, "nothing in the group can be lit")
			assert.equal(0, state.to_proxy_brightness(st))
			assert.equal(40, st.brightness, "Hue's last level is kept, as while off")

			state.configure(st, zone({ light_count = "1", no_lights = "false" }))
			assert.is_false(st.no_lights)
			assert.equal(0, state.to_proxy_brightness(st), "still off until a report says otherwise")
			local changed = state.apply_hue(st, { on = "true", brightness = "60" })
			assert.is_true(changed.brightness)
			assert.equal(60, state.to_proxy_brightness(st))

			state.configure(st, zone())
			assert.is_false(st.no_lights, "absent reads as false, as every lifecycle field")
		end)

		it("reads no_lights as off even before any report, so the tile never shows unknown", function()
			local st = state.new()
			state.configure(st, zone({ light_count = "0", no_lights = "true" }))
			assert.is_false(st.on)
			assert.equal(0, state.to_proxy_brightness(st))
		end)

		it("leaves a light's configure alone: no kind, type, count or no_lights", function()
			local st = color_bulb()
			assert.is_nil(st.kind)
			assert.is_nil(st.group_type)
			assert.is_nil(st.light_count)
			assert.is_false(st.no_lights)
			assert.is_nil(st.on, "a light's on state waits for the bridge")
		end)
	end)

	describe("apply_hue and the proxy view", function()
		it("knows nothing until the bridge reports", function()
			local st = color_bulb()
			assert.is_nil(state.to_proxy_brightness(st))
			assert.is_nil(state.to_proxy_color(st))
		end)

		it("maps on/off and brightness, reporting only what the proxy would see change", function()
			local st = color_bulb()
			local changed = state.apply_hue(st, { on = "true", brightness = "50" })
			assert.same({ brightness = true, color = false, online = false }, changed)
			assert.equal(50, state.to_proxy_brightness(st))

			changed = state.apply_hue(st, { on = "false" })
			assert.is_true(changed.brightness)
			assert.equal(0, state.to_proxy_brightness(st))

			-- Hue keeps reporting a brightness while off; the proxy sees 0 either way.
			changed = state.apply_hue(st, { brightness = "70" })
			assert.is_false(changed.brightness)
			assert.equal(0, state.to_proxy_brightness(st))

			changed = state.apply_hue(st, { on = "true" })
			assert.is_true(changed.brightness)
			assert.equal(70, state.to_proxy_brightness(st), "turned back on at the level Hue kept")
		end)

		it("hands the proxy whole percents, never 0 while on", function()
			local st = color_bulb()
			state.apply_hue(st, { on = "true", brightness = "20.16" })
			assert.equal(20, state.to_proxy_brightness(st), "Hue's decimal for a requested 20")
			local changed = state.apply_hue(st, { brightness = "20.4" })
			assert.is_false(changed.brightness, "same whole percent, nothing for the proxy")
			state.apply_hue(st, { brightness = "50.5" })
			assert.equal(51, state.to_proxy_brightness(st))
			state.apply_hue(st, { brightness = "0.39" })
			assert.equal(1, state.to_proxy_brightness(st), "Hue's lowest level is still on")
			state.apply_hue(st, { brightness = "100" })
			assert.equal(100, state.to_proxy_brightness(st))
		end)

		it("treats an on light without dimming as full brightness", function()
			local st = state.new()
			state.apply_hue(st, { on = "true" })
			assert.equal(100, state.to_proxy_brightness(st))
		end)

		it("maps xy colour to mode 0", function()
			local st = color_bulb()
			local changed = state.apply_hue(st, { x = "0.4", y = "0.35", color_mode = "xy" })
			assert.is_true(changed.color)
			local x, y, mode = state.to_proxy_color(st)
			assert.equal(0.4, x)
			assert.equal(0.35, y)
			assert.equal(state.MODE_XY, mode)
		end)

		it("maps a colour temperature to the controller's xy for it, mode 1", function()
			local st = color_bulb()
			local changed = state.apply_hue(st, { mirek = "370", color_mode = "ct" })
			assert.is_true(changed.color)
			local x, y, mode = state.to_proxy_color(st)
			local ex, ey = c4:ColorCCTtoXY(1000000 / 370)
			assert.equal(ex, x)
			assert.equal(ey, y)
			assert.equal(state.MODE_CCT, mode)
		end)

		it("infers the colour mode when a report carries only one kind of colour", function()
			local st = color_bulb()
			state.apply_hue(st, { mirek = "250" })
			assert.equal("ct", st.color_mode)
			state.apply_hue(st, { x = "0.2", y = "0.1" })
			assert.equal("xy", st.color_mode)
			state.apply_hue(st, { x = "0.3", y = "0.3", mirek = "300", color_mode = "ct" })
			assert.equal("ct", st.color_mode, "an explicit mode wins")
		end)

		-- docs/reviews/efficiency-2026-10-24.md R10: a one-entry memo of mirek -> xy.
		it("converts a colour temperature once while the mirek stays the same", function()
			local st = color_bulb()
			local calls = 0
			local convert = c4.ColorCCTtoXY
			c4.ColorCCTtoXY = function(self, k)
				calls = calls + 1
				return convert(self, k)
			end
			st.color_mode, st.mirek = "ct", 370
			local x1, y1, mode = state.to_proxy_color(st)
			local x2, y2 = state.to_proxy_color(st)
			assert.equal(1, calls, "two calls with the same mirek compute once")
			assert.same({ x1, y1, state.MODE_CCT }, { x2, y2, mode })
			local ex, ey = convert(c4, 1000000 / 370)
			assert.same({ ex, ey }, { x1, y1 }, "the controller's conversion, unchanged")

			st.mirek = 250
			local x3 = state.to_proxy_color(st)
			assert.equal(2, calls)
			assert.are_not.equal(x1, x3)
			st.mirek = 370
			assert.equal(x1, (state.to_proxy_color(st)))
			assert.equal(3, calls, "one entry: the mirek before last is converted again")

			-- A ct-mode HUE_STATE that keeps the mirek: the view before and after
			-- the merge, and the report, convert nothing more.
			state.apply_hue(st, { on = "true", brightness = "40", mirek = "370", color_mode = "ct" })
			state.to_proxy_color(st)
			assert.equal(3, calls)
			-- One that moves it converts the new mirek once.
			state.apply_hue(st, { mirek = "300", color_mode = "ct" })
			state.to_proxy_color(st)
			assert.equal(4, calls)
		end)

		it("does not flag colour when a full report in ct mode carries a slightly different xy", function()
			local st = color_bulb()
			state.apply_hue(st, { mirek = "370", x = "0.44", y = "0.40", color_mode = "ct" })
			local changed = state.apply_hue(st, { mirek = "370", x = "0.4401", y = "0.4001", color_mode = "ct" })
			assert.is_false(changed.color, "the proxy sees the mirek's xy, which did not move")
		end)

		it("maps online", function()
			local st = color_bulb()
			local changed = state.apply_hue(st, { online = "false" })
			assert.same({ brightness = false, color = false, online = true }, changed)
			assert.is_false(st.online)
			changed = state.apply_hue(st, { online = "false" })
			assert.is_false(changed.online)
		end)

		it("ignores unparsable values", function()
			local st = color_bulb()
			state.apply_hue(st, { on = "true", brightness = "50" })
			local changed = state.apply_hue(st, { on = "maybe", brightness = "lots" })
			assert.is_false(changed.brightness)
			assert.equal(50, state.to_proxy_brightness(st))
		end)
	end)

	describe("from_brightness_target", function()
		it("turns the light off for target 0", function()
			local st = color_bulb()
			assert.same({ rid = "l1", on = "false", rate = "500" }, state.from_brightness_target(st, "0", "500"))
		end)

		it("turns the light on at the target, all values as strings", function()
			local st = color_bulb()
			assert.same({ rid = "l1", on = "true", brightness = "50", rate = "0" }, state.from_brightness_target(st, 50))
			assert.same({ rid = "l1", on = "true", brightness = "33.3", rate = "2000" },
				state.from_brightness_target(st, 33.3, 2000))
		end)
	end)

	describe("from_color_target", function()
		it("passes xy through as strings for mode 0", function()
			local st = color_bulb()
			state.apply_hue(st, { on = "true" })
			assert.same({ rid = "l1", x = "0.4", y = "0.35", rate = "0" }, state.from_color_target(st, 0.4, 0.35, 0))
			assert.same({ rid = "l1", x = "0.3127", y = "0.329", rate = "300" },
				state.from_color_target(st, "0.3127", "0.3290", "0", "300"))
		end)

		it("converts mode 1 to a mirek inside the bulb's range", function()
			local st = color_bulb()
			state.apply_hue(st, { on = "true" })
			local x, y = c4:ColorCCTtoXY(2700)
			local params = state.from_color_target(st, x, y, 1, 400)
			assert.equal("l1", params.rid)
			assert.equal("400", params.rate)
			assert.is_nil(params.x)
			local mirek = tonumber(params.mirek)
			assert.is_true(mirek >= 153 and mirek <= 500)
			assert.is_true(math.abs(1000000 / mirek - 2700) / 2700 < 0.05, "got " .. params.mirek)
		end)

		it("clamps the mirek to the bulb's range", function()
			local st = color_bulb()
			state.configure(st, { mirek_min = "200", mirek_max = "450" })
			state.apply_hue(st, { on = "true" })
			local x, y = c4:ColorCCTtoXY(1800)       -- warmer than 450 mirek (2222 K)
			assert.equal("450", state.from_color_target(st, x, y, 1).mirek)
			x, y = c4:ColorCCTtoXY(9000)             -- cooler than 200 mirek (5000 K)
			assert.equal("200", state.from_color_target(st, x, y, 1).mirek)
		end)

		it("round-trips a CCT through the proxy view within tolerance", function()
			local st = color_bulb()
			state.apply_hue(st, { on = "true" })
			for _, k in ipairs({ 2200, 2700, 4000, 6500 }) do
				local x, y = c4:ColorCCTtoXY(k)
				local params = state.from_color_target(st, x, y, 1)
				state.apply_hue(st, { mirek = params.mirek, color_mode = "ct" })
				local px, py, mode = state.to_proxy_color(st)
				assert.equal(state.MODE_CCT, mode)
				local back = c4:ColorXYtoCCT(px, py)
				assert.is_true(math.abs(back - k) / k < 0.05, string.format("%d K came back as %.0f K", k, back))
			end
		end)

		it("sends a CCT to a bulb that only does CCT whatever the mode, and xy to a bulb without CCT", function()
			local cct_only = state.new()
			state.configure(cct_only, { rid = "w", has_color = "false", has_cct = "true", mirek_min = "153",
				mirek_max = "454" })
			state.apply_hue(cct_only, { on = "true" })
			local x, y = c4:ColorCCTtoXY(3000)
			local params = state.from_color_target(cct_only, x, y, 0)
			assert.truthy(params.mirek)
			assert.is_nil(params.x)

			local xy_only = state.new()
			state.configure(xy_only, { rid = "c", has_color = "true", has_cct = "false" })
			state.apply_hue(xy_only, { on = "true" })
			params = state.from_color_target(xy_only, x, y, 1)
			assert.truthy(params.x)
			assert.is_nil(params.mirek)
		end)

		it("refuses a bulb with no colour at all, and a target without xy", function()
			local plain = state.new()
			state.configure(plain, { rid = "p", has_color = "false", has_cct = "false" })
			state.apply_hue(plain, { on = "true" })
			local params, why = state.from_color_target(plain, 0.4, 0.4, 0)
			assert.is_nil(params)
			assert.equal("unsupported", why)
			params, why = state.from_color_target(color_bulb(), nil, nil, 0)
			assert.is_nil(params)
			assert.equal("no xy", why)
		end)

		it("stores the colour while the light is off and sends it with the next turn-on", function()
			local st = color_bulb()
			state.apply_hue(st, { on = "false", brightness = "40" })
			local params, why = state.from_color_target(st, 0.4, 0.35, 0, 300)
			assert.is_nil(params)
			assert.equal("stored", why)
			assert.same({ x = "0.4", y = "0.35" }, st.pending_color)

			assert.same({ rid = "l1", on = "false", rate = "0" }, state.from_brightness_target(st, 0),
				"turning off again does not spend the stored colour")
			assert.truthy(st.pending_color)

			assert.same({ rid = "l1", on = "true", brightness = "60", rate = "0", x = "0.4", y = "0.35" },
				state.from_brightness_target(st, 60))
			assert.is_nil(st.pending_color)
		end)

		it("the latest colour stored while off wins, including a CCT", function()
			local st = color_bulb()
			state.apply_hue(st, { on = "false" })
			state.from_color_target(st, 0.4, 0.35, 0)
			local x, y = c4:ColorCCTtoXY(4000)
			state.from_color_target(st, x, y, 1)
			local params = state.from_brightness_target(st, 100)
			assert.truthy(params.mirek)
			assert.is_nil(params.x)
		end)

		it("sends the colour straight away while the on state is still unknown", function()
			local st = color_bulb()
			assert.truthy(state.from_color_target(st, 0.4, 0.35, 0))
			assert.is_nil(st.pending_color)
		end)

		it("forgets a stored colour when something else turns the light on, and re-flags the colour", function()
			local st = color_bulb()
			state.apply_hue(st, { on = "false", x = "0.2", y = "0.1", color_mode = "xy" })
			state.from_color_target(st, 0.4, 0.35, 0)
			local changed = state.apply_hue(st, { on = "true" })
			assert.is_nil(st.pending_color)
			assert.is_true(changed.color, "the proxy was told the stored colour; it must hear the real one")
			local x = state.to_proxy_color(st)
			assert.equal(0.2, x)
		end)
	end)
end)
