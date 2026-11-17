-- syncbox/periods.lua (#568, docs/hdmi-sync-stage4-design.md §4, design
-- docs/hdmi-sync-design.md 5.3, contracts C1.4, C1.9 and C3): Day, Evening
-- and Night with their intensity and brightness; Day and Night at clock
-- times, Evening at an offset from the sunset computed from the project's
-- location (C4:GetProjectProperty), a stand-in clock time without one;
-- boundaries on timers, re-armed at start, none fired for one passed while
-- down; a manual change held until the source changes or sync stops.
--
-- Time zones are fakes made here (a fixed offset, and US Eastern's 2026
-- daylight saving), so nothing depends on the VM's own zone. The known
-- sunsets are published values for public places (city centres), within
-- 2 minutes; no house's location appears anywhere.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")

local H = 3600000
local MIN = 60000

describe("syncbox/periods.lua (#568)", function()
	local periods, c4, lines

	local function utc(y, m, d, h, mi)
		return (periods.days_from_civil(y, m, d) * 86400 + (h or 0) * 3600 + (mi or 0) * 60) * 1000
	end

	-- A zone `std_h` hours from UTC, with daylight saving at `dst.h` hours
	-- from dst.from to dst.to (UTC ms). A clock time the change skips is read
	-- as standard time (the instant after the gap); one it repeats, as the
	-- first.
	local function new_zone(std_h, dst)
		local z = {}
		local function offset(ms)
			if dst and ms >= dst.from and ms < dst.to then
				return dst.h * H
			end
			return std_h * H
		end
		function z.date_of(ms)
			local l = ms + offset(ms)
			local days = math.floor(l / 86400000)
			local y, m, d = periods.civil_from_days(days)
			local r = (l - days * 86400000) / MIN
			return y, m, d, math.floor(r / 60), math.floor(r % 60)
		end
		function z.ms_of(y, m, d, hour, min)
			local naive = utc(y, m, d, hour, min)
			local fits = {}
			for _, h in ipairs({ dst and dst.h or std_h, std_h }) do
				local at = naive - h * H
				if offset(at) == h * H then
					fits[#fits + 1] = at
				end
			end
			if #fits == 0 then
				return naive - std_h * H
			end
			table.sort(fits)
			return fits[1]
		end
		return z
	end

	-- US Eastern in 2026: EDT from 2026-03-08 02:00 EST to 2026-11-01 02:00 EDT.
	local function eastern()
		return new_zone(-5, { h = -4, from = utc(2026, 3, 8, 7, 0), to = utc(2026, 11, 1, 6, 0) })
	end

	-- A sunset source whose sunset is `clock` ("17:30", or a function of the
	-- date giving one, or nil for none) on the zone `z`.
	local function stub_sunset(z, clock, stand_in)
		local s = { stand_in = stand_in }
		function s.at(y, m, d)
			local c = type(clock) == "function" and clock(y, m, d) or clock
			if not c then
				return nil, "no location"
			end
			local hh, mm = c:match("^(%d+):(%d+)$")
			local minutes = tonumber(hh) * 60 + tonumber(mm)
			local days = math.floor(minutes / 1440)
			local yy, mo, dd = periods.add_days(y, m, d, days)
			minutes = minutes - days * 1440
			return z.ms_of(yy, mo, dd, math.floor(minutes / 60), minutes % 60)
		end
		return s
	end

	-- A local clock reading of `ms` on `z`: "2026-11-17 16:30".
	local function at_text(z, ms)
		local y, m, d, hh, mm = z.date_of(ms)
		return string.format("%04d-%02d-%02d %02d:%02d", y, m, d, hh, mm)
	end

	local seen

	local function new_periods(extra)
		local deps = {
			log = log,
			timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end,
			now = function() return c4:GetTime() end,
			zone = new_zone(0),
			settings = {},
			on_boundary = function(period, prev, why) seen[#seen + 1] = { period, prev, why, at = c4.now_ms } end,
		}
		deps.sunset = stub_sunset(deps.zone, "17:30")
		for k, v in pairs(extra or {}) do deps[k] = v end
		return periods.new(deps)
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
		package.loaded["syncbox.periods"] = nil
		periods = require("syncbox.periods")
		seen = {}
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("the settings", function()
		it("reads 24-hour clock times", function()
			assert.equal(420, periods.parse_clock("07:00"))
			assert.equal(425, periods.parse_clock("7:05"))
			assert.equal(1320, periods.parse_clock(" 22:00 "))
			assert.equal(0, periods.parse_clock("00:00"))
			assert.equal(1439, periods.parse_clock("23:59"))
			for _, bad in ipairs({ "24:00", "7", "7:5", "07:60", "seven", "", "-1:00", "07:00pm" }) do
				assert.is_nil(periods.parse_clock(bad), bad)
			end
			assert.is_nil(periods.parse_clock(420))
			assert.is_nil(periods.parse_clock(nil))
		end)

		it("reads the Evening offset as whole minutes within the Scheduler Agent's six hours", function()
			assert.equal(-60, periods.parse_offset("-60"))
			assert.equal(30, periods.parse_offset("+30"))
			assert.equal(0, periods.parse_offset(" 0 "))
			assert.equal(-360, periods.parse_offset("-360"))
			assert.equal(360, periods.parse_offset(360))
			for _, bad in ipairs({ "-361", "361", "-60 min", "1.5", "", "--60", "00000060", "nan" }) do
				assert.is_nil(periods.parse_offset(bad), bad)
			end
			assert.is_nil(periods.parse_offset(1.5))
			assert.is_nil(periods.parse_offset(0 / 0))
			assert.is_nil(periods.parse_offset(math.huge))
		end)

		it("writes clock times", function()
			assert.equal("07:00", periods.clock_text(420))
			assert.equal("00:04", periods.clock_text(1444))
			assert.equal("23:00", periods.clock_text(-60))
		end)

		it("takes the defaults of contracts C1.4 from properties that are not there", function()
			local s, problems = periods.from_properties({})
			assert.same({}, problems)
			assert.same(periods.normalize(nil), s)
			assert.equal(420, s.day_starts)
			assert.equal(1320, s.night_starts)
			assert.equal(-60, s.evening_offset)
			assert.same({ intensity = "high", brightness = 100 }, s.day)
			assert.same({ intensity = "moderate", brightness = 100 }, s.evening)
			assert.same({ intensity = "subtle", brightness = 70 }, s.night)
		end)

		it("reads the Composer properties by their C1.4 names", function()
			local s, problems = periods.from_properties({
				["Day Starts"] = "06:30", ["Night Starts"] = "23:15", ["Evening Starts"] = "-45",
				["Day Intensity"] = "Intense", ["Evening Intensity"] = "High", ["Night Intensity"] = "Moderate",
				["Day Brightness"] = "150", ["Evening Brightness"] = "90", ["Night Brightness"] = "40",
			})
			assert.same({}, problems)
			assert.equal(390, s.day_starts)
			assert.equal(1395, s.night_starts)
			assert.equal(-45, s.evening_offset)
			assert.same({ intensity = "intense", brightness = 150 }, s.day)
			assert.same({ intensity = "high", brightness = 90 }, s.evening)
			assert.same({ intensity = "moderate", brightness = 40 }, s.night)
		end)

		it("refuses what it cannot read, names the property and the value used instead", function()
			local s, problems = periods.from_properties({
				["Day Starts"] = "7am", ["Night Starts"] = "", ["Evening Starts"] = "-400",
				["Day Intensity"] = "Loud", ["Night Brightness"] = "250", ["Evening Brightness"] = "12.5",
			})
			assert.equal(420, s.day_starts)
			assert.equal(1320, s.night_starts)
			assert.equal(-60, s.evening_offset)
			assert.equal("high", s.day.intensity)
			assert.equal(70, s.night.brightness)
			assert.equal(100, s.evening.brightness)
			local by = {}
			for _, p in ipairs(problems) do by[p.property] = p.text end
			assert.equal('Day Starts: "7am" is not a 24-hour time like 07:00; 07:00 is used', by["Day Starts"])
			assert.equal('Night Starts: "" is not a 24-hour time like 22:00; 22:00 is used', by["Night Starts"])
			assert.equal('Evening Starts: "-400" is not minutes from sunset between -360 and 360; -60 is used',
				by["Evening Starts"])
			assert.equal('Day Intensity: "Loud" is not Subtle, Moderate, High or Intense; high is used', by["Day Intensity"])
			assert.equal('Night Brightness: "250" is not a whole number from 0 to 200; 70 is used', by["Night Brightness"])
			assert.truthy(by["Evening Brightness"])
			assert.equal(6, #problems)
		end)

		it("says so when Night starts with Day (there is no Night then)", function()
			local _, problems = periods.from_properties({ ["Day Starts"] = "07:00", ["Night Starts"] = "07:00" })
			assert.equal(1, #problems)
			assert.equal("Night Starts is the same as Day Starts (07:00): there is no Night", problems[1].text)
		end)

		it("caps a long or odd value in its text", function()
			local _, problems = periods.from_properties({ ["Day Starts"] = string.rep("x", 100) .. '"\n' })
			assert.truthy(#problems[1].text < 140)
			assert.is_nil(problems[1].text:find("\n"))
		end)

		it("normalizes any settings table, minutes or clock texts", function()
			local s = periods.normalize({ day_starts = "08:00", night_starts = 1380, evening_offset = "+15",
				day = { intensity = "SUBTLE", brightness = 200 }, night = { brightness = -1 }, evening = "junk" })
			assert.equal(480, s.day_starts)
			assert.equal(1380, s.night_starts)
			assert.equal(15, s.evening_offset)
			assert.same({ intensity = "subtle", brightness = 200 }, s.day)
			assert.same({ intensity = "subtle", brightness = 70 }, s.night)
			assert.same({ intensity = "moderate", brightness = 100 }, s.evening)
			assert.equal(420, periods.normalize({ day_starts = 1440 }).day_starts)
			assert.equal(420, periods.normalize({ day_starts = 7.5 }).day_starts)
		end)
	end)

	describe("the calendar", function()
		it("counts days both ways and rolls a day past the month's end over", function()
			assert.equal(0, periods.days_from_civil(1970, 1, 1))
			assert.equal(20409, periods.days_from_civil(2025, 11, 17))
			assert.same({ 2026, 3, 1 }, { periods.civil_from_days(periods.days_from_civil(2026, 2, 28) + 1) })
			assert.same({ 2028, 2, 29 }, { periods.add_days(2028, 2, 28, 1) })
			assert.same({ 2027, 1, 1 }, { periods.add_days(2026, 12, 31, 1) })
			assert.same({ 2026, 4, 1 }, { periods.add_days(2026, 3, 32, 0) })
			assert.same({ 2025, 12, 31 }, { periods.add_days(2026, 1, 1, -1) })
		end)

		it("the controller's zone (os.date, os.time) gives back the minute it was given", function()
			local z = periods.os_zone()
			for _, ms in ipairs({ utc(2026, 1, 15, 12, 0), utc(2026, 7, 15, 17, 30), utc(2026, 11, 17, 9, 45) }) do
				local y, m, d, hh, mm = z.date_of(ms)
				assert.equal(ms, z.ms_of(y, m, d, hh, mm))
			end
			assert.is_nil(z.date_of(0 / 0))
			assert.is_nil(z.date_of(1e18))
		end)
	end)

	describe("the sun", function()
		-- Published sunsets (local clock) for city centres, the zone in force
		-- that day: { place, latitude, longitude, y, m, d, UTC offset, sunset }.
		local KNOWN = {
			{ "London, June solstice", 51.5074, -0.1278, 2026, 6, 21, 1, "21:21" },
			{ "London, December solstice", 51.5074, -0.1278, 2026, 12, 21, 0, "15:53" },
			{ "New York, December solstice", 40.7128, -74.0060, 2026, 12, 21, -5, "16:32" },
			{ "New York, June solstice", 40.7128, -74.0060, 2026, 6, 21, -4, "20:31" },
			{ "Sydney, June solstice", -33.8688, 151.2093, 2026, 6, 21, 10, "16:54" },
			{ "Sydney, December solstice", -33.8688, 151.2093, 2026, 12, 21, 11, "20:05" },
			{ "Reykjavik, June solstice (after midnight)", 64.1466, -21.9426, 2026, 6, 21, 0, "24:04" },
		}

		for _, k in ipairs(KNOWN) do
			it("sets within 2 minutes of the published time: " .. k[1], function()
				local lat, lon, y, m, d, off, clock = k[2], k[3], k[4], k[5], k[6], k[7], k[8]
				local noon_here = utc(y, m, d, 12, 0) - off * H
				local noon = periods.solar_noon(noon_here, lon)
				local set = periods.sunset_after(noon, lat)
				local hh, mm = clock:match("^(%d+):(%d+)$")
				local expect = utc(y, m, d, tonumber(hh), tonumber(mm)) - off * H
				assert.truthy(math.abs(set - expect) <= 2 * MIN,
					string.format("%s: off by %.1f min", k[1], (set - expect) / MIN))
			end)
		end

		it("knows the days the sun does not set or does not rise (Tromsø)", function()
			local june = periods.solar_noon(utc(2026, 6, 21, 10, 0), 18.9553)
			local dec = periods.solar_noon(utc(2026, 12, 21, 11, 0), 18.9553)
			assert.same({ nil, "midnight sun" }, { periods.sunset_after(june, 69.6492) })
			assert.same({ nil, "polar night" }, { periods.sunset_after(dec, 69.6492) })
			-- and at the pole itself, without dividing by nothing
			assert.same({ nil, "midnight sun" }, { periods.sunset_after(june, 90) })
			assert.same({ nil, "polar night" }, { periods.sunset_after(june, -90) })
		end)

		it("finds solar noon with the equation of time (Greenwich, within a minute)", function()
			local nov = periods.solar_noon(utc(2026, 11, 3, 12, 0), 0)
			local feb = periods.solar_noon(utc(2026, 2, 11, 12, 0), 0)
			assert.truthy(math.abs(nov - (utc(2026, 11, 3, 11, 43) + 35000)) < MIN)
			assert.truthy(math.abs(feb - (utc(2026, 2, 11, 12, 14) + 13000)) < MIN)
		end)
	end)

	describe("the sunset source", function()
		local function london(extra)
			c4.project_properties = { Latitude = "51.5074", Longitude = "-0.1278" }
			local deps = { zone = new_zone(0), now = function() return c4:GetTime() end, log = log }
			for k, v in pairs(extra or {}) do deps[k] = v end
			return periods.new_sunset(deps)
		end

		it("computes today's sunset from C4:GetProjectProperty's Latitude and Longitude", function()
			c4.now_ms = utc(2026, 12, 21, 9, 0)
			local s = london()
			assert.equal(15 * 60 + 53, s.today())
			local text, kind = s.source()
			assert.equal("Sunset 15:53 today, from the project's location", text)
			assert.equal("sunset", kind)
			local asked = {}
			for _, args in ipairs(c4.calls_to("GetProjectProperty")) do asked[#asked + 1] = args[1] end
			assert.same({ "Latitude", "Longitude" }, asked)
		end)

		it("takes a date's sunset as an instant, and today's as minutes past 1440 after midnight", function()
			c4.project_properties = { Latitude = "64.1466", Longitude = "-21.9426" }
			local z = new_zone(0)
			local s = periods.new_sunset({ zone = z, now = function() return utc(2026, 6, 21, 10, 0) end, log = log })
			assert.equal(1444, s.today())
			assert.equal("Sunset 00:04 today, from the project's location", (s.source()))
			assert.equal("2026-06-22 00:04", at_text(z, s.at(2026, 6, 21)))
		end)

		it("tries the lower-case names too (the SDK writes both)", function()
			c4.project_properties = { latitude = 51.5074, longitude = -0.1278 }
			c4.now_ms = utc(2026, 12, 21, 9, 0)
			local s = periods.new_sunset({ zone = new_zone(0), log = log })
			assert.equal(953, s.today())
		end)

		it("without a location, nothing is computed and 19:00 stands in, saying so", function()
			c4.now_ms = utc(2026, 12, 21, 9, 0)
			for _, props in ipairs({ {}, { Latitude = "", Longitude = "" }, { Latitude = "0", Longitude = "0" },
				{ Latitude = 0, Longitude = 0 } }) do
				c4.project_properties = props
				local s = periods.new_sunset({ zone = new_zone(0), log = log })
				assert.is_nil(s.today())
				assert.same({ nil, "no location" }, { s.at(2026, 12, 21) })
				assert.same({ "No location is set in the project: 19:00 stands in for sunset", "stand-in" }, { s.source() })
			end
		end)

		it("a location it cannot read is not used", function()
			c4.project_properties = { Latitude = "51°30'N", Longitude = "0°7'W" }
			local s = periods.new_sunset({ zone = new_zone(0), log = log })
			assert.equal("The project's location cannot be read: 19:00 stands in for sunset", (s.source()))
			c4.project_properties = { Latitude = "91", Longitude = "0.5" }
			s = periods.new_sunset({ zone = new_zone(0), log = log })
			assert.equal("The project's location cannot be read: 19:00 stands in for sunset", (s.source()))
		end)

		it("a location that does not fit the controller's clock (a wrong sign) is not used", function()
			c4.project_properties = { Latitude = "40.7128", Longitude = "74.0060" } -- New York, east instead of west
			c4.now_ms = utc(2026, 12, 21, 17, 0)
			local s = periods.new_sunset({ zone = new_zone(-5), log = log })
			assert.same({ nil, "time zone" }, { s.at(2026, 12, 21) })
			assert.equal("The project's location does not fit the controller's time zone: 19:00 stands in for sunset",
				(s.source()))
			c4.project_properties.Longitude = "-74.0060"
			s.refresh()
			assert.equal(16 * 60 + 32, s.today())
		end)

		it("says when the sun does not set or rise today", function()
			c4.project_properties = { Latitude = "69.6492", Longitude = "18.9553" }
			c4.now_ms = utc(2026, 6, 21, 10, 0)
			local s = periods.new_sunset({ zone = new_zone(2), log = log })
			assert.equal("The sun does not set today at the project's location: 19:00 stands in for sunset", (s.source()))
			c4.now_ms = utc(2026, 12, 21, 10, 0)
			assert.equal("The sun does not rise today at the project's location: 19:00 stands in for sunset", (s.source()))
		end)

		it("takes its stand-in from deps", function()
			local s = periods.new_sunset({ zone = new_zone(0), log = log, stand_in = 18 * 60 + 30 })
			assert.equal(1110, s.stand_in)
			assert.equal("No location is set in the project: 18:30 stands in for sunset", (s.source()))
		end)

		it("reads the location again after an hour, or at once after refresh", function()
			c4.now_ms = utc(2026, 12, 21, 9, 0)
			local s = london()
			s.today()
			assert.equal(2, #c4.calls_to("GetProjectProperty"))
			c4.now_ms = c4.now_ms + H - 1
			s.today()
			assert.equal(2, #c4.calls_to("GetProjectProperty"))
			c4.project_properties = { Latitude = "40.7128", Longitude = "-74.0060" }
			c4.now_ms = c4.now_ms + 1
			-- New York's sunset on a UTC+0 clock does not fit: the new location was read
			assert.is_nil(s.today())
			assert.equal(4, #c4.calls_to("GetProjectProperty"))
			c4.project_properties = { Latitude = "51.5074", Longitude = "-0.1278" }
			s.refresh()
			assert.equal(953, s.today())
		end)

		it("never logs or shows the coordinates", function()
			c4.now_ms = utc(2026, 12, 21, 9, 0)
			local s = london()
			s.today()
			s.source()
			c4.project_properties = { Latitude = "51.5074", Longitude = "east" }
			s.refresh()
			s.source()
			assert.truthy(#lines >= 2)
			for _, line in ipairs(lines) do
				assert.is_nil(line:find("51.50", 1, true), line)
				assert.is_nil(line:find("0.12", 1, true), line)
			end
		end)

		it("logs what it reckons from once per change, not at every use", function()
			c4.now_ms = utc(2026, 12, 21, 9, 0)
			local s = london()
			for _ = 1, 5 do
				s.today()
				s.refresh()
			end
			local n = 0
			for _, line in ipairs(lines) do
				if line:find("sunset from the project's location", 1, true) then n = n + 1 end
			end
			assert.equal(1, n)
		end)

		it("works without GetProjectProperty in the runtime", function()
			c4.GetProjectProperty = nil
			local s = periods.new_sunset({ zone = new_zone(0), log = log })
			assert.is_nil(s.today())
			assert.equal("stand-in", select(2, s.source()))
		end)
	end)

	describe("the periods of a day", function()
		local z, p

		before_each(function()
			z = new_zone(0)
			p = new_periods({ zone = z, sunset = stub_sunset(z, "17:30") })
		end)

		local function period_at(clock, y, m, d)
			local hh, mm = clock:match("^(%d+):(%d+)$")
			return p:current(z.ms_of(y or 2026, m or 11, d or 17, tonumber(hh), tonumber(mm)))
		end

		it("Day from 07:00, Evening an hour before sunset, Night from 22:00", function()
			assert.equal("night", period_at("06:59"))
			assert.equal("day", period_at("07:00"))
			assert.equal("day", period_at("16:29"))
			assert.equal("evening", period_at("16:30"))
			assert.equal("evening", period_at("21:59"))
			assert.equal("night", period_at("22:00"))
			assert.equal("night", period_at("00:00"))
			local name, from, to = p:current(z.ms_of(2026, 11, 17, 12, 0))
			assert.equal("day", name)
			assert.equal("2026-11-17 07:00", at_text(z, from))
			assert.equal("2026-11-17 16:30", at_text(z, to))
		end)

		it("names the next boundary and the period it begins", function()
			local now = z.ms_of(2026, 11, 17, 12, 0)
			local order = {}
			for _ = 1, 4 do
				local at, period = p:next_boundary(now)
				order[#order + 1] = at_text(z, at) .. " " .. period
				now = at
			end
			assert.same({ "2026-11-17 16:30 evening", "2026-11-17 22:00 night", "2026-11-18 07:00 day",
				"2026-11-18 16:30 evening" }, order)
		end)

		it("follows the sunset of each date", function()
			p = new_periods({ zone = z, sunset = stub_sunset(z, function(_, _, d) return d == 17 and "17:30" or "17:29" end) })
			local at = p:next_boundary(z.ms_of(2026, 11, 18, 12, 0))
			assert.equal("2026-11-18 16:29", at_text(z, at))
		end)

		it("a Night from 01:00 belongs to the evening before", function()
			p = new_periods({ zone = z, settings = { night_starts = "01:00" }, sunset = stub_sunset(z, "17:30") })
			assert.equal("evening", period_at("23:30"))
			assert.equal("evening", period_at("00:59", 2026, 11, 18))
			assert.equal("night", period_at("01:00", 2026, 11, 18))
			assert.equal("night", period_at("06:59", 2026, 11, 18))
			local at, period = p:next_boundary(z.ms_of(2026, 11, 17, 23, 30))
			assert.equal("2026-11-18 01:00 night", at_text(z, at) .. " " .. period)
		end)

		it("an Evening that would start at or after Night does not happen (a late summer sunset)", function()
			p = new_periods({ zone = z, sunset = stub_sunset(z, "23:30") })
			assert.equal("day", period_at("21:59"))
			assert.equal("night", period_at("22:00"))
			local at, period = p:next_boundary(z.ms_of(2026, 6, 21, 12, 0))
			assert.equal("2026-06-21 22:00 night", at_text(z, at) .. " " .. period)
			-- exactly at Night: no Evening of no length
			p = new_periods({ zone = z, sunset = stub_sunset(z, "23:00") })
			at, period = p:next_boundary(z.ms_of(2026, 6, 21, 12, 0))
			assert.equal("2026-06-21 22:00 night", at_text(z, at) .. " " .. period)
		end)

		it("an Evening that would start before Day starts with it, and there is no Day (a polar winter)", function()
			p = new_periods({ zone = z, sunset = stub_sunset(z, "07:30") })
			assert.equal("night", period_at("06:59"))
			assert.equal("evening", period_at("07:00"))
			assert.equal("evening", period_at("12:00"))
			local at, period = p:next_boundary(z.ms_of(2026, 12, 21, 3, 0))
			assert.equal("2026-12-21 07:00 evening", at_text(z, at) .. " " .. period)
			at, period = p:next_boundary(at)
			assert.equal("2026-12-21 22:00 night", at_text(z, at) .. " " .. period)
		end)

		it("an offset past midnight starts Evening after midnight, before a later Night", function()
			p = new_periods({ zone = z, settings = { night_starts = "02:00", evening_offset = 180 },
				sunset = stub_sunset(z, "21:30") })
			assert.equal("day", period_at("23:59"))
			assert.equal("evening", period_at("00:30", 2026, 11, 18))
			assert.equal("night", period_at("02:00", 2026, 11, 18))
		end)

		it("a Night that starts with Day leaves Day and Evening", function()
			p = new_periods({ zone = z, settings = { night_starts = "07:00" } })
			assert.equal("evening", period_at("06:59"))
			assert.equal("day", period_at("07:00"))
			local at, period = p:next_boundary(z.ms_of(2026, 11, 17, 20, 0))
			assert.equal("2026-11-18 07:00 day", at_text(z, at) .. " " .. period)
		end)

		it("no boundary within three days (Night with Day, Evening from Day's start): nil", function()
			p = new_periods({ zone = z, settings = { night_starts = "07:00" }, sunset = stub_sunset(z, "05:00") })
			assert.equal("evening", period_at("12:00"))
			assert.equal("evening", period_at("06:59"))
			assert.is_nil(p:next_boundary(z.ms_of(2026, 11, 17, 12, 0)))
			c4.now_ms = z.ms_of(2026, 11, 17, 12, 0)
			p:start()
			assert.equal(periods.MAX_ARM_MS, c4.active_timers()[1].delay)
		end)

		it("the stand-in clock time when the source knows no sunset", function()
			p = new_periods({ zone = z, sunset = stub_sunset(z, nil) })
			assert.equal("day", period_at("17:59"))
			assert.equal("evening", period_at("18:00"))
			p = new_periods({ zone = z, sunset = stub_sunset(z, nil, 20 * 60) })
			assert.equal("evening", period_at("19:00"))
		end)

		it("takes a source with only today(), as minutes after midnight", function()
			local calls = 0
			p = new_periods({ zone = z, sunset = { today = function() calls = calls + 1; return 17 * 60 end } })
			assert.equal("evening", period_at("16:00"))
			assert.equal("day", period_at("15:59"))
			assert.truthy(calls > 0)
		end)

		it("a source that raises is the same as one that knows nothing", function()
			p = new_periods({ zone = z, sunset = { at = function() error("boom") end } })
			assert.equal("evening", period_at("18:00"))
		end)

		it("reads the settings function at every use", function()
			local s = { day_starts = "07:00" }
			p = new_periods({ zone = z, settings = function() return s end })
			assert.equal("day", period_at("07:30"))
			s.day_starts = "08:00"
			assert.equal("night", period_at("07:30"))
		end)

		it("a clock that gives no date: no period and no boundary", function()
			local broken = { date_of = function() return nil end, ms_of = z.ms_of }
			p = new_periods({ zone = broken })
			assert.is_nil(p:current(utc(2026, 11, 17, 12, 0)))
			assert.is_nil(p:next_boundary(utc(2026, 11, 17, 12, 0)))
			assert.same({}, p:settings_for(nil, "video"))
			assert.equal("No period: the controller's clock gives no date", p:describe(utc(2026, 11, 17, 12, 0)))
		end)

		describe("with daylight saving (US Eastern, 2026)", function()
			before_each(function()
				z = eastern()
				p = new_periods({ zone = z, sunset = stub_sunset(z, "18:10") })
			end)

			it("Day still starts at 07:00 on the morning the clocks go forward; that Night is an hour shorter", function()
				local night = p:next_boundary(z.ms_of(2026, 3, 7, 20, 0))
				local day = p:next_boundary(night)
				assert.equal("2026-03-07 22:00", at_text(z, night))
				assert.equal("2026-03-08 07:00", at_text(z, day))
				assert.equal(8 * H, day - night)
				assert.equal(utc(2026, 3, 8, 11, 0), day)
			end)

			it("and the morning they go back; that Night is an hour longer", function()
				local night = p:next_boundary(z.ms_of(2026, 10, 31, 20, 0))
				local day = p:next_boundary(night)
				assert.equal("2026-11-01 07:00", at_text(z, day))
				assert.equal(10 * H, day - night)
				assert.equal(utc(2026, 11, 1, 12, 0), day)
			end)

			it("a Night Starts the change skips (02:30) comes after the gap", function()
				p = new_periods({ zone = z, settings = { night_starts = "02:30" }, sunset = stub_sunset(z, "18:10") })
				local at, period = p:next_boundary(z.ms_of(2026, 3, 7, 20, 0))
				assert.equal("night", period)
				assert.equal("2026-03-08 03:30", at_text(z, at))
			end)

			it("a Night Starts the change repeats (01:30) comes the first time", function()
				p = new_periods({ zone = z, settings = { night_starts = "01:30" }, sunset = stub_sunset(z, "18:10") })
				local at = p:next_boundary(z.ms_of(2026, 10, 31, 20, 0))
				assert.equal(utc(2026, 11, 1, 5, 30), at)
			end)
		end)
	end)

	describe("the timer", function()
		local z, p

		before_each(function()
			z = new_zone(0)
			c4.now_ms = utc(2026, 11, 17, 12, 0)
			p = new_periods({ zone = z, sunset = stub_sunset(z, "17:30") })
		end)

		local function seen_text()
			local out = {}
			for _, s in ipairs(seen) do
				out[#out + 1] = string.format("%s %s<-%s %s", at_text(z, s.at), s[1], s[2], s[3])
			end
			return out
		end

		it("start notes the period, fires nothing, and arms no further than an hour ahead", function()
			assert.equal("day", p:start())
			assert.equal("day", p:period())
			assert.is_true(p:is_running())
			assert.same({}, seen)
			local timers = c4.active_timers()
			assert.equal(1, #timers)
			assert.equal(periods.MAX_ARM_MS, timers[1].delay)
		end)

		it("fires at each boundary with the period, the one before, and why", function()
			p:start()
			c4.advance(2 * 24 * H)
			assert.same({
				"2026-11-17 16:30 evening<-day boundary",
				"2026-11-17 22:00 night<-evening boundary",
				"2026-11-18 07:00 day<-night boundary",
				"2026-11-18 16:30 evening<-day boundary",
				"2026-11-18 22:00 night<-evening boundary",
				"2026-11-19 07:00 day<-night boundary",
			}, seen_text())
			for _, s in ipairs(seen) do
				assert.equal(periods.SLACK_MS, s.at % MIN) -- a second after the minute
			end
			assert.equal(1, #c4.active_timers())
		end)

		it("arms the last stretch to the boundary itself", function()
			c4.now_ms = utc(2026, 11, 17, 16, 0)
			p:start()
			assert.equal(30 * MIN + periods.SLACK_MS, c4.active_timers()[1].delay)
		end)

		it("a wake-up before the boundary (an early timer) only re-arms", function()
			p:start()
			c4.fire_timers()
			assert.same({}, seen)
			assert.equal(1, #c4.active_timers())
		end)

		it("nothing fires for a boundary passed while the driver was down; the next one does", function()
			p:start()
			p:stop()
			assert.equal(0, #c4.active_timers())
			c4.advance(5 * H) -- Director down over 16:30
			c4.now_ms = utc(2026, 11, 17, 17, 0)
			local again = new_periods({ zone = z, sunset = stub_sunset(z, "17:30") })
			assert.equal("evening", again:start())
			assert.same({}, seen)
			c4.advance(5 * H + 1000)
			assert.same({ "2026-11-17 22:00 night<-evening boundary" }, seen_text())
		end)

		it("stop: no callback and no timer after it, until start", function()
			p:start()
			local timer = c4.active_timers()[1]
			p:stop()
			assert.is_false(p:is_running())
			timer.callback(timer, 0) -- a timer Director had already queued
			c4.advance(24 * H)
			assert.same({}, seen)
			p:start()
			c4.advance(24 * H)
			assert.equal(3, #seen)
		end)

		it("refresh: a settings change that moves the period applies at once, as \"settings\"", function()
			local s = {}
			p = new_periods({ zone = z, sunset = stub_sunset(z, "17:30"), settings = function() return s end })
			p:start()
			p:refresh()
			assert.same({}, seen)
			s.night_starts = "11:00"
			p:refresh()
			assert.same({ "2026-11-17 12:00 night<-day settings" }, seen_text())
			assert.equal(1, #c4.active_timers())
		end)

		it("refresh before start does nothing", function()
			p:refresh()
			assert.same({}, seen)
			assert.equal(0, #c4.active_timers())
		end)

		it("a clock that jumps ahead is noticed within the hour, with one callback", function()
			p:start()
			c4.now_ms = utc(2026, 11, 17, 23, 0) -- the clock set late, no timer fired yet
			c4.advance(H)
			assert.same({ "2026-11-17 23:00 night<-day boundary" }, seen_text())
		end)

		it("an on_boundary that raises is logged, and the periods go on", function()
			p = new_periods({ zone = z, sunset = stub_sunset(z, "17:30"), on_boundary = function() error("boom") end })
			p:start()
			c4.advance(24 * H)
			local warned = 0
			for _, line in ipairs(lines) do
				if line:find("on_boundary failed", 1, true) then warned = warned + 1 end
			end
			assert.equal(3, warned)
			assert.equal(1, #c4.active_timers())
		end)

		it("uses C4:SetTimer and C4:GetTime by default", function()
			p = periods.new({ zone = z, sunset = stub_sunset(z, "17:30"), log = log,
				on_boundary = function(period) seen[#seen + 1] = { period, at = c4.now_ms } end })
			p:start()
			assert.equal(1, #c4.calls_to("SetTimer"))
			c4.advance(5 * H)
			assert.equal("evening", seen[1][1])
		end)

		it("describes the period, its end and what is held", function()
			p:start()
			assert.equal("Day until 16:30", p:describe())
			p:hold("brightness")
			assert.equal("Day until 16:30; brightness set by hand", p:describe())
			p:hold("intensity")
			assert.equal("Evening until 22:00; brightness and intensity set by hand", p:describe(utc(2026, 11, 17, 17, 0)))
		end)
	end)

	describe("manual changes", function()
		local z, p

		before_each(function()
			z = new_zone(0)
			c4.now_ms = utc(2026, 11, 17, 12, 0)
			p = new_periods({ zone = z, sunset = stub_sunset(z, "17:30") })
		end)

		it("settings_for gives the period's intensity and brightness by the box's names", function()
			assert.same({ intensity = "high", brightness = 100 }, p:settings_for("day", "video"))
			assert.same({ intensity = "moderate", brightness = 100 }, p:settings_for("evening", "game"))
			assert.same({ intensity = "subtle", brightness = 70 }, p:settings_for("night", "music"))
			assert.same({ intensity = "high", brightness = 100 }, p:settings_for()) -- the current period, at noon
		end)

		it("gives nothing for a mode that does not sync, or a period it does not know", function()
			assert.same({}, p:settings_for("day", "passthrough"))
			assert.same({}, p:settings_for("day", "powersave"))
			assert.same({}, p:settings_for("day", "unknown"))
			assert.same({}, p:settings_for("dusk", "video"))
		end)

		it("a field held by hand is left out, and named, until release", function()
			assert.is_true(p:hold("brightness"))
			assert.is_true(p:held("brightness"))
			local fields, kept = p:settings_for("night", "video")
			assert.same({ intensity = "subtle" }, fields)
			assert.same({ "brightness" }, kept)
			assert.is_true(p:hold("intensity"))
			fields, kept = p:settings_for("night", "video")
			assert.same({}, fields)
			assert.same({ "brightness", "intensity" }, kept)
			assert.same({ "brightness", "intensity" }, p:release("source"))
			assert.same({ intensity = "subtle", brightness = 70 }, (p:settings_for("night", "video")))
			assert.same({}, p:release("stop"))
		end)

		it("refuses to hold a field it does not know", function()
			assert.is_false(p:hold("mode"))
			assert.is_false(p:hold(nil))
			assert.same({}, p:holds())
		end)

		it("a boundary does not end a hold", function()
			p:start()
			p:hold("brightness")
			c4.advance(24 * H)
			assert.equal(3, #seen)
			assert.is_true(p:held("brightness"))
			assert.same({ intensity = "subtle" }, (p:settings_for("night", "video")))
		end)

		it("keeps the holds across a Director restart, and their end too", function()
			p:hold("intensity")
			assert.equal("intensity", c4.persist[periods.HOLD_KEY])
			local again = new_periods({ zone = z, sunset = stub_sunset(z, "17:30") })
			again:start()
			assert.same({ "intensity" }, again:holds())
			again:release("stop")
			assert.equal("", c4.persist[periods.HOLD_KEY])
			local third = new_periods({ zone = z, sunset = stub_sunset(z, "17:30") })
			assert.same({}, third:holds())
		end)

		it("stores with PersistSetValue without the encrypted flag, and reads only once", function()
			p:hold("brightness")
			p:hold("intensity")
			for _, args in ipairs(c4.calls_to("PersistSetValue")) do
				assert.is_false(args[3])
			end
			assert.equal(1, #c4.calls_to("PersistGetValue"))
		end)

		it("ignores stored junk", function()
			c4.persist[periods.HOLD_KEY] = "brightness,mode,;rm"
			assert.same({ "brightness" }, new_periods():holds())
			c4.persist[periods.HOLD_KEY] = { "brightness" }
			assert.same({}, new_periods():holds())
		end)

		it("logs a hold and its end with the reason", function()
			p:hold("brightness")
			p:release("source")
			local text = table.concat(lines, "\n")
			assert.truthy(text:find("brightness set by hand", 1, true))
			assert.truthy(text:find("brightness follows the periods again (source)", 1, true))
		end)
	end)
end)
