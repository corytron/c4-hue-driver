-- The Day, Evening and Night periods of the Hue Sync Box driver (#568,
-- docs/hdmi-sync-stage4-design.md §4; design docs/hdmi-sync-design.md 5.3;
-- contracts docs/hdmi-sync-contracts.md C1.4, C1.9 and C3).
--
-- Each period has its own intensity and brightness. Day and Night start at
-- clock times (Day Starts, Night Starts: 07:00 and 22:00), Evening at an
-- offset in minutes from the controller's sunset (Evening Starts: -60, one
-- hour before; the owner, 2026-11-13). The driver applies the period's
-- settings when sync starts and at each boundary while syncing. A manual
-- change (a Watch-menu button, a remote, a keypad, a programmed command) is
-- never overridden by a boundary: it holds until the source changes or sync
-- stops (design 5.3, contracts C1.9).
--
--   local p = periods.new{ timer, now, settings, sunset, log, on_boundary,
--                          zone, persist_get, persist_set }
--   p:start()            arms the boundary timer (OnDriverLateInit: no timer
--                        in OnDriverInit, SDK 34_timer/_1-SetTimer.md) and
--                        loads the holds; returns the period now. Nothing
--                        fires for a boundary passed while the driver was
--                        down: start only notes the period it finds.
--   p:stop()             cancels the timer (OnDriverDestroyed); no callback
--                        after it until the next start
--   p:refresh()          the settings or the location changed: re-armed,
--                        and on_boundary(period, prev, "settings") when the
--                        period now differs from the one last noted
--   p:current([now])     "day" | "evening" | "night" (nil when the clock or
--                        the zone cannot say), and that period's start and
--                        end (epoch ms)
--   p:next_boundary([now])  the epoch ms of the next change of period and
--                        the period that begins there, or nil when none
--                        comes within three days (a degenerate setting)
--   p:settings_for([period][, mode])  the execution fields the period sets,
--                        { intensity = "high", brightness = 100 } by the
--                        box's names (syncbox/queue.lua's q:set takes them as
--                        they are: the intensity goes to the current sync
--                        mode), without the fields a manual change holds;
--                        second value the list of the held fields left out.
--                        `period` defaults to the current one; `mode` (the
--                        state model's mode) other than video, game or music
--                        (passthrough, powersave) gives nothing to apply
--   p:hold(field)        "intensity" | "brightness" set by hand: boundaries
--                        and settings_for leave it out until p:release.
--                        Persisted, so a Director restart during a film
--                        keeps it. true, or false for an unknown field
--   p:release(reason)    every hold ends ("source": the source changed;
--                        "stop": sync stopped); returns the fields released
--   p:held(field), p:holds()  one hold; the held fields, sorted
--   p:period()           the period last noted (start, boundary, refresh)
--   p:describe([now])    "Evening until 22:00; brightness set by hand"
--   p.sunset             the sunset source in use (below)
--
-- Callbacks: on_boundary(period, prev, why) under pcall, when the period
-- changes while running: why "boundary" (the timer) or "settings"
-- (p:refresh). The driver applies p:settings_for(period, model.mode) when
-- the box syncs, and ignores it otherwise.
--
-- Settings: `settings` is a table, or a function returning one (read at
-- every use, so a property change is seen at once), in the form
-- periods.normalize takes (below); periods.from_properties builds it from
-- the Composer properties of contracts C1.4 and lists what it refused.
--
-- The timer: one one-shot timer to the next boundary plus SLACK_MS, never
-- more than MAX_ARM_MS ahead (the bridge's housekeeping rule,
-- docs/simplify-research-scheduler.md §3.1: a clock jump or a timer that
-- never fires costs at most an hour). A wake-up before the boundary only
-- re-arms. Director kills a driver's timers on update and shutdown
-- (OnDriverDestroyed, SDK 22_miscellaneous/_24-OnDriverDestroyed.md), so
-- the driver calls p:start() again at every late init.
--
-- The day: the cycle of the local date X runs from Day Starts on X to Day
-- Starts on X+1: Day from Day Starts, Evening from sunset(X) + Evening
-- Starts, Night from Night Starts (on X when it is later than Day Starts,
-- else on X+1, so a Night from 01:00 belongs to the evening before).
-- Evening is clamped into [Day start, Night start]: an Evening that would
-- start before Day (a polar winter, a large negative offset) starts with
-- Day and there is no Day that cycle; one that would start at or after
-- Night (a late summer sunset, a large positive offset) does not happen
-- that cycle. Night Starts equal to Day Starts leaves no Night. Every
-- boundary is a clock time on a calendar date resolved by the zone, so a
-- daylight-saving change moves nothing: Day still starts at 07:00 on the
-- day the clocks change (that night is an hour shorter or longer); a clock
-- time the change skips (02:30 in spring) is resolved by the zone: with
-- glibc's mktime the time after the gap, and a repeated one (01:30 in
-- autumn) the first (checked on the VM; the controller's C library
-- [assumed] alike).
--
-- The zone: zone.date_of(ms) → year, month, day, hour, min (local), and
-- zone.ms_of(year, month, day, hour, min) → epoch ms (a day past the end of
-- the month rolls over). Default periods.os_zone(): os.date("*t") and
-- os.time, which follow the controller's time zone [assumed; the drivers'
-- "since 14:02" texts rely on it already, common/link.lua].
--
-- The sunset source (stage 4 §2, checked in the SDK, docs-driverworks-api):
--   * The Scheduler Agent's daily sunset entries (28_scheduler_agent_add_event/
--     _8-AddDailySunsetEntry.md, _9-AddDailySunsetOffsetEntry.md, OS 3.0)
--     make events for Composer programming (27_scheduler_agent/_1-Overview.md;
--     3_whats_new/_20-WhatwasNewinOS3.md). No page documents a callback into
--     the driver that made the entry: the Get pages (30_scheduler_agent_get_event)
--     list no handler, and hearing it through C4:RegisterDeviceEvent and
--     OnDeviceEvent (7_event/_5-RegisterDeviceEvent.md, _4.1-OnDeviceEvent.md)
--     would need the agent's device id and its event ids, which no page
--     gives. An entry would also be a thing the driver adds to the project by
--     itself (design 8). Not used.
--   * C4:GetProjectProperty("Latitude") and ("Longitude") (24_properties/
--     _2-GetProjectProperty.md, OS 3.0.0; the driver declares 3.3.0) read
--     the project location the dealer set, which is what Director computes
--     its own sunrise and sunset from (8.5_geolocation/_0-Header.md). Used:
--     the sunset is computed here, on the controller, from that location,
--     with no request to anything (no internet reliance). Assumed until the
--     house logs it: the values are decimal degrees, north and east
--     positive; the names' case (the list says "Latitude", the
--     GetGeoSettings page reads "countrycode" in lower case, so both are
--     tried); an unset location reads as nothing, "" or 0 and 0. A guard
--     catches a wrong sign or a location from elsewhere: when the computed
--     solar noon is more than NOON_SLACK_MIN from the controller's 12:00,
--     the location does not fit the controller's clock and is not used.
--   * Without a usable location, and on a day the sun does not set or does
--     not rise there, STAND_IN (19:00) stands in for the sunset, and
--     sunset.source() says so.
--
--   local s = periods.new_sunset{ get_property, zone, now, log, stand_in }
--   s.today([now])   today's sunset as minutes after local midnight (more
--                    than 1440 for a sunset after midnight), nil when no
--                    sunset is known today (the stand-in is used then)
--   s.at(y, m, d)    that local date's sunset as epoch ms (to the nearest
--                    minute), or nil and why:
--                    "no location", "unreadable", "time zone", "midnight
--                    sun", "polar night", "clock"
--   s.source([now])  the text for the Composer property, and "sunset" or
--                    "stand-in": "Sunset 16:52 today, from the project's
--                    location" / "No location is set in the project: 19:00
--                    stands in for sunset"
--   s.refresh()      reads the location again at the next use (it is read
--                    again at most once an hour by itself, LOCATION_TTL_MS)
--   s.stand_in       the stand-in, minutes after midnight
-- The coordinates are never logged or shown: they locate the house.
--
-- The sunset itself: the sun's declination and the equation of time from
-- the low-precision solar coordinates of Meeus, Astronomical Algorithms
-- (ch. 25), the formulas NOAA's solar calculator uses; sunset is when the
-- sun's centre is 90.833° from the zenith (refraction and the sun's radius),
-- iterated so the declination and equation of time are taken at the sunset
-- itself. Within a minute or two of published tables; the specs check it
-- against known sunsets.

local num = require("common.num")

local periods = {}

periods.NAMES = { "day", "evening", "night" }
periods.LABELS = { day = "Day", evening = "Evening", night = "Night" }
periods.FIELDS = { "intensity", "brightness" }
periods.INTENSITIES = { "subtle", "moderate", "high", "intense" }
periods.SYNC_MODES = { video = true, game = true, music = true }

periods.DEFAULTS = {
	day_starts = 7 * 60,
	night_starts = 22 * 60,
	evening_offset = -60,
	day = { intensity = "high", brightness = 100 },
	evening = { intensity = "moderate", brightness = 100 },
	night = { intensity = "subtle", brightness = 70 },
}

-- The Composer properties (contracts C1.4).
periods.PROPERTIES = {
	day_starts = "Day Starts",
	night_starts = "Night Starts",
	evening_offset = "Evening Starts",
	intensity = { day = "Day Intensity", evening = "Evening Intensity", night = "Night Intensity" },
	brightness = { day = "Day Brightness", evening = "Evening Brightness", night = "Night Brightness" },
}

-- The Scheduler Agent's own range for an offset from sunset (SDK
-- 27_scheduler_agent/_1-Overview.md): six hours either way.
periods.OFFSET_MIN = -360
periods.OFFSET_MAX = 360
periods.BRIGHTNESS_MAX = 200            -- contracts C1.4: 0-200 %
periods.STAND_IN = 19 * 60              -- 19:00 stands in for an unknown sunset
periods.MAX_ARM_MS = 3600000            -- never arm further ahead than an hour
periods.SLACK_MS = 1000                 -- wake a second past the boundary
periods.LOCATION_TTL_MS = 3600000       -- the location is read again after an hour
periods.NOON_SLACK_MIN = 240            -- solar noon this far from 12:00: not this place
periods.HOLD_KEY = "syncbox_period_holds"
periods.CYCLES_AHEAD = 3                -- next_boundary looks this many days ahead

local MINUTE = 60000
local DAY_MS = 86400000
local RAD = math.pi / 180
local ZENITH = 90.833                   -- the sunset's zenith distance, degrees

local INTENSITY_SET, FIELD_SET = {}, {}
for _, v in ipairs(periods.INTENSITIES) do INTENSITY_SET[v] = true end
for _, v in ipairs(periods.FIELDS) do FIELD_SET[v] = true end

-- Calendar dates as day numbers (days since 1970-01-01), proleptic
-- Gregorian, for any whole year, month 1-12 and day (a day out of the month
-- counts on from its first: 2026-03-32 is 2026-04-01).
function periods.days_from_civil(y, m, d)
	if m <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

function periods.civil_from_days(n)
	n = n + 719468
	local era = math.floor(n / 146097)
	local doe = n - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	local y = yoe + era * 400
	if m <= 2 then
		y = y + 1
	end
	return y, m, d
end

function periods.add_days(y, m, d, k)
	return periods.civil_from_days(periods.days_from_civil(y, m, d) + k)
end

-- The controller's local time (see the header).
function periods.os_zone()
	local z = {}
	function z.date_of(ms)
		local s = num.timestamp(num.finite(ms) and math.floor(ms / 1000))
		if not s then
			return nil
		end
		local t = os.date("*t", s)
		return t.year, t.month, t.day, t.hour, t.min
	end
	function z.ms_of(y, m, d, hour, min)
		local ok, s = pcall(os.time, { year = y, month = m, day = d, hour = hour, min = min, sec = 0 })
		s = ok and num.finite(s)
		return s and s * 1000 or nil
	end
	return z
end

-- "HH:MM" (or "H:MM"), 24-hour → minutes after midnight, else nil.
function periods.parse_clock(v)
	if type(v) ~= "string" then
		return nil
	end
	local h, m = v:match("^%s*(%d%d?):(%d%d)%s*$")
	h, m = tonumber(h), tonumber(m)
	if not h or h > 23 or m > 59 then
		return nil
	end
	return h * 60 + m
end

-- "-60", "+30", "0" → whole minutes within OFFSET_MIN..OFFSET_MAX, else nil.
function periods.parse_offset(v)
	if type(v) == "number" then
		if v ~= math.floor(v) then
			return nil
		end
		return num.within(v, periods.OFFSET_MIN, periods.OFFSET_MAX)
	end
	if type(v) ~= "string" then
		return nil
	end
	local sign, digits = v:match("^%s*([%+%-]?)(%d+)%s*$")
	if not digits or #digits > 4 then
		return nil
	end
	local n = tonumber(digits)
	if sign == "-" then
		n = -n
	end
	return num.within(n, periods.OFFSET_MIN, periods.OFFSET_MAX)
end

-- Minutes after midnight → "07:00" (wrapped into one day).
function periods.clock_text(minutes)
	minutes = math.floor(num.finite(minutes) or 0) % 1440
	return string.format("%02d:%02d", math.floor(minutes / 60), minutes % 60)
end

local function intensity_of(v)
	if type(v) ~= "string" then
		return nil
	end
	v = v:lower():match("^%s*(.-)%s*$")
	return INTENSITY_SET[v] and v or nil
end

local function brightness_of(v)
	v = num.finite(v)
	if v == nil or v ~= math.floor(v) then
		return nil
	end
	return num.within(v, 0, periods.BRIGHTNESS_MAX)
end

local function clock_of(v)
	if type(v) == "number" then
		return (v == math.floor(v)) and num.within(v, 0, 1439) or nil
	end
	return periods.parse_clock(v)
end

-- Any settings table → one with every field valid (the default where not):
-- { day_starts, night_starts (minutes, or "HH:MM"), evening_offset
-- (minutes from sunset), day, evening, night = { intensity, brightness } }.
function periods.normalize(t)
	t = type(t) == "table" and t or {}
	local d = periods.DEFAULTS
	local out = {
		day_starts = clock_of(t.day_starts) or d.day_starts,
		night_starts = clock_of(t.night_starts) or d.night_starts,
		evening_offset = periods.parse_offset(t.evening_offset) or d.evening_offset,
	}
	for _, name in ipairs(periods.NAMES) do
		local levels = type(t[name]) == "table" and t[name] or {}
		out[name] = {
			intensity = intensity_of(levels.intensity) or d[name].intensity,
			brightness = brightness_of(levels.brightness) or d[name].brightness,
		}
	end
	return out
end

local function shown(raw)
	local text = tostring(raw):gsub("[%c\"]", " ")
	if #text > 40 then
		text = text:sub(1, 40) .. "..."
	end
	return text
end

-- The Composer properties (Properties, contracts C1.4) → settings, and the
-- list of what was refused, each { property, text } with the value used
-- instead. A property the table lacks (a driver.xml without it) takes its
-- default silently.
function periods.from_properties(props)
	props = type(props) == "table" and props or {}
	local d, names = periods.DEFAULTS, periods.PROPERTIES
	local s, problems = {}, {}
	local function refuse(name, text)
		problems[#problems + 1] = { property = name, text = text }
	end
	for _, key in ipairs({ "day_starts", "night_starts" }) do
		local raw = props[names[key]]
		s[key] = periods.parse_clock(raw)
		if s[key] == nil then
			s[key] = d[key]
			if raw ~= nil then
				refuse(names[key], string.format("%s: \"%s\" is not a 24-hour time like %s; %s is used", names[key],
					shown(raw), periods.clock_text(d[key]), periods.clock_text(d[key])))
			end
		end
	end
	local raw = props[names.evening_offset]
	s.evening_offset = periods.parse_offset(raw)
	if s.evening_offset == nil then
		s.evening_offset = d.evening_offset
		if raw ~= nil then
			refuse(names.evening_offset, string.format("%s: \"%s\" is not minutes from sunset between %d and %d; %d is used",
				names.evening_offset, shown(raw), periods.OFFSET_MIN, periods.OFFSET_MAX, d.evening_offset))
		end
	end
	for _, period in ipairs(periods.NAMES) do
		s[period] = {}
		local iname, bname = names.intensity[period], names.brightness[period]
		local iraw, braw = props[iname], props[bname]
		s[period].intensity = intensity_of(iraw)
		if s[period].intensity == nil then
			s[period].intensity = d[period].intensity
			if iraw ~= nil then
				refuse(iname, string.format("%s: \"%s\" is not Subtle, Moderate, High or Intense; %s is used", iname,
					shown(iraw), d[period].intensity))
			end
		end
		s[period].brightness = brightness_of(braw)
		if s[period].brightness == nil then
			s[period].brightness = d[period].brightness
			if braw ~= nil then
				refuse(bname, string.format("%s: \"%s\" is not a whole number from 0 to %d; %d is used", bname, shown(braw),
					periods.BRIGHTNESS_MAX, d[period].brightness))
			end
		end
	end
	if s.night_starts == s.day_starts then
		refuse(names.night_starts, string.format("%s is the same as %s (%s): there is no Night", names.night_starts,
			names.day_starts, periods.clock_text(s.day_starts)))
	end
	return s, problems
end

-- The sun ------------------------------------------------------------------

local function julian(ms)
	return ms / DAY_MS + 2440587.5
end

-- The sun's declination (radians) and the equation of time (minutes) at
-- epoch ms `ms` (see the header).
function periods.sun(ms)
	local t = (julian(ms) - 2451545) / 36525          -- Julian centuries from J2000.0
	local l0 = (280.46646 + t * (36000.76983 + t * 0.0003032)) % 360   -- mean longitude
	local m = (357.52911 + t * (35999.05029 - t * 0.0001537)) * RAD    -- mean anomaly
	local e = 0.016708634 - t * (0.000042037 + t * 0.0000001267)      -- orbit's eccentricity
	local centre = math.sin(m) * (1.914602 - t * (0.004817 + t * 0.000014))
		+ math.sin(2 * m) * (0.019993 - t * 0.000101) + math.sin(3 * m) * 0.000289
	local omega = (125.04 - 1934.136 * t) * RAD
	local lambda = (l0 + centre - 0.00569 - 0.00478 * math.sin(omega)) * RAD   -- apparent longitude
	local eps0 = 23 + (26 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60) / 60
	local eps = (eps0 + 0.00256 * math.cos(omega)) * RAD                    -- obliquity, corrected
	local decl = math.asin(math.sin(eps) * math.sin(lambda))
	local y = math.tan(eps / 2) ^ 2
	local l0r = l0 * RAD
	local eqt = y * math.sin(2 * l0r) - 2 * e * math.sin(m) + 4 * e * y * math.sin(m) * math.cos(2 * l0r)
		- 0.5 * y * y * math.sin(4 * l0r) - 1.25 * e * e * math.sin(2 * m)
	return decl, 4 * eqt / RAD
end

-- The sun's hour angle at `ms` seen from longitude `lon` (degrees, east
-- positive), -180..180: 0 at solar noon.
local function hour_angle(ms, lon)
	local _, eqt = periods.sun(ms)
	local ha = ((ms % DAY_MS) / MINUTE + eqt + 4 * lon) / 4 - 180
	ha = ha % 360
	if ha > 180 then
		ha = ha - 360
	end
	return ha
end

-- The solar noon at longitude `lon` nearest the epoch ms `ref_ms`.
function periods.solar_noon(ref_ms, lon)
	local t = ref_ms
	for _ = 1, 3 do
		t = t - hour_angle(t, lon) * 4 * MINUTE
	end
	return t
end

-- The sunset after the solar noon `noon_ms` (periods.solar_noon: it holds
-- the longitude) at latitude `lat` (degrees, north positive), as epoch ms;
-- or nil and "midnight sun" (the sun does not set that day) or "polar
-- night" (it does not rise).
function periods.sunset_after(noon_ms, lat)
	local phi = lat * RAD
	local _, eqt_noon = periods.sun(noon_ms)
	local cos_z = math.cos(ZENITH * RAD)
	local t = noon_ms + 6 * 3600000
	for _ = 1, 4 do
		local decl, eqt = periods.sun(t)
		local cos_h = (cos_z - math.sin(phi) * math.sin(decl)) / (math.cos(phi) * math.cos(decl))
		if cos_h >= 1 then
			return nil, "polar night"
		elseif cos_h <= -1 then
			return nil, "midnight sun"
		end
		local h = math.acos(cos_h) / RAD
		-- The hour angle at t counted from noon, without wrapping: the time
		-- since noon plus the drift of the equation of time.
		local ha = (t - noon_ms) / (4 * MINUTE) + (eqt - eqt_noon) / 4
		t = t + (h - ha) * 4 * MINUTE
	end
	return t
end

-- The sunset source --------------------------------------------------------

local function default_now()
	if type(C4) == "table" and type(C4.GetTime) == "function" then
		local ok, t = pcall(C4.GetTime, C4)
		if ok and num.finite(t) then
			return t
		end
	end
	return os.time() * 1000
end

local function project_property(name)
	if type(C4) ~= "table" or type(C4.GetProjectProperty) ~= "function" then
		return nil
	end
	return C4:GetProjectProperty(name)
end

local function first_value(get, names)
	for _, name in ipairs(names) do
		local ok, v = pcall(get, name)
		if ok and v ~= nil and v ~= "" then
			return v
		end
	end
	return nil
end

-- { lat, lon } or { why = "no location" | "unreadable" }.
local function read_location(get)
	local rlat = first_value(get, { "Latitude", "latitude" })
	local rlon = first_value(get, { "Longitude", "longitude" })
	if rlat == nil and rlon == nil then
		return { why = "no location" }
	end
	local lat, lon = num.within(rlat, -90, 90), num.within(rlon, -180, 180)
	if lat == nil or lon == nil then
		return { why = "unreadable" }
	elseif lat == 0 and lon == 0 then
		return { why = "no location" }
	end
	return { lat = lat, lon = lon }
end

local STAND_IN_TEXTS = {
	["no location"] = "No location is set in the project",
	["unreadable"] = "The project's location cannot be read",
	["time zone"] = "The project's location does not fit the controller's time zone",
	["midnight sun"] = "The sun does not set today at the project's location",
	["polar night"] = "The sun does not rise today at the project's location",
	["clock"] = "The controller's clock gives no date",
}

function periods.new_sunset(deps)
	deps = deps or {}
	local zone = deps.zone or periods.os_zone()
	local now = deps.now or default_now
	local get = deps.get_property or project_property
	local log = deps.log or require("common.log")
	local s = { stand_in = num.int(deps.stand_in, 0, 1439) or periods.STAND_IN }
	local loc, read_at, said
	local cache, cached = {}, 0

	local function location()
		local t = num.finite(now()) or 0
		if loc and read_at and t >= read_at and t - read_at < periods.LOCATION_TTL_MS then
			return loc
		end
		local fresh = read_location(get)
		if not loc or fresh.lat ~= loc.lat or fresh.lon ~= loc.lon or fresh.why ~= loc.why then
			cache, cached = {}, 0
		end
		loc, read_at = fresh, t
		local now_saying = fresh.why or "location"
		if now_saying ~= said then
			said = now_saying
			if fresh.why then
				log.info("periods: %s; %s stands in for sunset", STAND_IN_TEXTS[fresh.why],
					periods.clock_text(s.stand_in))
			else
				log.info("periods: sunset from the project's location")
			end
		end
		return loc
	end

	function s.refresh()
		read_at = nil
	end

	function s.at(y, m, d)
		local l = location()
		if not l.lat then
			return nil, l.why
		end
		local key = string.format("%d-%d-%d", y, m, d)
		local hit = cache[key]
		if hit then
			return hit.at, hit.why
		end
		local at, why
		local noon_here = zone.ms_of(y, m, d, 12, 0)
		if not num.finite(noon_here) then
			why = "clock"
		else
			local noon = periods.solar_noon(noon_here, l.lon)
			if math.abs(noon - noon_here) > periods.NOON_SLACK_MIN * MINUTE then
				why = "time zone"
			else
				at, why = periods.sunset_after(noon, l.lat)
				if at then
					-- to the nearest minute, as published tables give it: the
					-- Evening then starts on a whole minute
					at = math.floor((at + MINUTE / 2) / MINUTE) * MINUTE
				end
			end
		end
		if cached >= 16 then
			cache, cached = {}, 0
		end
		cache[key], cached = { at = at, why = why }, cached + 1
		return at, why
	end

	-- `ms`'s local date and the sunset on it as minutes after its midnight.
	local function minutes_of(now_ms)
		now_ms = num.finite(now_ms) or num.finite(now())
		local y, m, d = zone.date_of(now_ms)
		if not y then
			return nil, "clock"
		end
		local at, why = s.at(y, m, d)
		if not at then
			return nil, why
		end
		local y2, m2, d2, hh, mm = zone.date_of(at)
		if not y2 then
			return nil, "clock"
		end
		return (periods.days_from_civil(y2, m2, d2) - periods.days_from_civil(y, m, d)) * 1440 + hh * 60 + mm
	end

	function s.today(now_ms)
		return (minutes_of(now_ms))
	end

	function s.source(now_ms)
		local minutes, why = minutes_of(now_ms)
		if minutes then
			return string.format("Sunset %s today, from the project's location", periods.clock_text(minutes)), "sunset"
		end
		return string.format("%s: %s stands in for sunset", STAND_IN_TEXTS[why] or STAND_IN_TEXTS["no location"],
			periods.clock_text(s.stand_in)), "stand-in"
	end

	return s
end

-- The periods ----------------------------------------------------------------

local P = {}
P.__index = P

local function cancel(handle)
	if handle then
		pcall(function() handle:Cancel() end)
	end
end

local function clamp(v, lo, hi)
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end

function periods.new(deps)
	deps = deps or {}
	local p = setmetatable({}, P)
	p.log = deps.log or require("common.log")
	p.timer = deps.timer or function(ms, fn)
		return C4:SetTimer(ms, function() fn() end)
	end
	p.now = deps.now or default_now
	p.zone = deps.zone or periods.os_zone()
	p.settings_source = deps.settings
	p.sunset = deps.sunset or periods.new_sunset({ zone = p.zone, now = p.now, log = p.log })
	p.on_boundary = deps.on_boundary
	p.persist_get = deps.persist_get or function(name) return C4:PersistGetValue(name) end
	p.persist_set = deps.persist_set or function(name, value) return C4:PersistSetValue(name, value) end
	p.running = false
	p.gen = 0
	p.handle = nil
	p.last = nil        -- the period last noted
	p.hold_set = nil    -- loaded at the first use
	return p
end

function P:_now()
	return num.finite(self.now()) or 0
end

function P:_settings()
	local src = self.settings_source
	if type(src) == "function" then
		local ok, t = pcall(src)
		src = ok and t or nil
		if not ok then
			self.log.warn("periods: reading the settings failed: %s", tostring(t))
		end
	end
	return periods.normalize(src)
end

-- The local clock time `minutes` (any whole number: below 0 or past 1440
-- counts into the days around) on the date y-m-d, as epoch ms.
function P:_clock_ms(y, m, d, minutes)
	minutes = math.floor(minutes)
	local days = math.floor(minutes / 1440)
	local rest = minutes - days * 1440
	if days ~= 0 then
		y, m, d = periods.add_days(y, m, d, days)
	end
	return num.finite(self.zone.ms_of(y, m, d, math.floor(rest / 60), rest % 60))
end

-- The sunset of the date y-m-d (epoch ms), from the source, else the stand-in.
function P:_sunset_ms(y, m, d)
	local src = self.sunset or {}
	local at
	if type(src.at) == "function" then
		local ok, v = pcall(src.at, y, m, d)
		at = ok and num.finite(v) or nil
	elseif type(src.today) == "function" then
		local noon = self:_clock_ms(y, m, d, 720)
		local ok, minutes = pcall(src.today, noon)
		minutes = ok and num.finite(minutes) or nil
		at = minutes and self:_clock_ms(y, m, d, minutes) or nil
	end
	if at then
		return at
	end
	return self:_clock_ms(y, m, d, num.int(src.stand_in, 0, 1439) or periods.STAND_IN)
end

-- The cycle of the local date y-m-d (see the header): its day, evening,
-- night and next (the next Day start) instants, or nil.
function P:_cycle(y, m, d, s)
	local ny, nm, nd = periods.add_days(y, m, d, 1)
	local day = self:_clock_ms(y, m, d, s.day_starts)
	local nxt = self:_clock_ms(ny, nm, nd, s.day_starts)
	if not day or not nxt or nxt <= day then
		return nil
	end
	local night
	if s.night_starts > s.day_starts then
		night = self:_clock_ms(y, m, d, s.night_starts)
	elseif s.night_starts < s.day_starts then
		night = self:_clock_ms(ny, nm, nd, s.night_starts)
	end
	night = clamp(night or nxt, day, nxt)
	local sunset = self:_sunset_ms(y, m, d)
	local evening = clamp((sunset or night) + s.evening_offset * MINUTE, day, night)
	return { y = y, m = m, d = d, day = day, evening = evening, night = night, next = nxt }
end

-- The non-empty periods of a cycle, in order: { period, from, to }.
local function segments(c)
	local out = {}
	if c.evening > c.day then
		out[#out + 1] = { "day", c.day, c.evening }
	end
	if c.night > c.evening then
		out[#out + 1] = { "evening", c.evening, c.night }
	end
	if c.next > c.night then
		out[#out + 1] = { "night", c.night, c.next }
	end
	return out
end

function P:_next_cycle(c, s)
	local y, m, d = periods.add_days(c.y, c.m, c.d, 1)
	return self:_cycle(y, m, d, s)
end

-- The cycle `now` falls in.
function P:_cycle_at(now, s)
	local y, m, d = self.zone.date_of(now)
	if not y then
		return nil
	end
	local c = self:_cycle(y, m, d, s)
	if c and now < c.day then
		local py, pm, pd = periods.add_days(y, m, d, -1)
		c = self:_cycle(py, pm, pd, s)
	end
	if c and now >= c.next then
		c = self:_next_cycle(c, s)
	end
	if c and (now < c.day or now >= c.next) then
		return nil
	end
	return c
end

function P:current(now)
	now = num.finite(now) or self:_now()
	local c = self:_cycle_at(now, self:_settings())
	if not c then
		return nil
	end
	for _, seg in ipairs(segments(c)) do
		if now >= seg[2] and now < seg[3] then
			return seg[1], seg[2], seg[3]
		end
	end
	return nil
end

function P:next_boundary(now)
	now = num.finite(now) or self:_now()
	local s = self:_settings()
	local c = self:_cycle_at(now, s)
	local current
	for _ = 1, periods.CYCLES_AHEAD + 1 do
		if not c then
			return nil
		end
		for _, seg in ipairs(segments(c)) do
			if seg[2] <= now and now < seg[3] then
				current = seg[1]
			elseif seg[2] > now and current and seg[1] ~= current then
				return seg[2], seg[1]
			end
		end
		c = self:_next_cycle(c, s)
	end
	return nil
end

-- Holds ------------------------------------------------------------------------

function P:_holds()
	if not self.hold_set then
		self.hold_set = {}
		local ok, v = pcall(self.persist_get, periods.HOLD_KEY)
		if ok and type(v) == "string" then
			for field in v:gmatch("[%a_]+") do
				if FIELD_SET[field] then
					self.hold_set[field] = true
				end
			end
		end
	end
	return self.hold_set
end

function P:holds()
	local out = {}
	for _, field in ipairs(periods.FIELDS) do
		if self:_holds()[field] then
			out[#out + 1] = field
		end
	end
	table.sort(out)
	return out
end

function P:held(field)
	return self:_holds()[field] == true
end

function P:_save_holds()
	local ok, err = pcall(self.persist_set, periods.HOLD_KEY, table.concat(self:holds(), ","))
	if not ok then
		self.log.warn("periods: saving the holds failed: %s", tostring(err))
	end
end

function P:hold(field)
	if not FIELD_SET[field] then
		return false
	end
	local set = self:_holds()
	if not set[field] then
		set[field] = true
		self:_save_holds()
		self.log.info("periods: %s set by hand; the periods leave it until the source changes or sync stops", field)
	end
	return true
end

function P:release(reason)
	local released = self:holds()
	if #released == 0 then
		return released
	end
	self.hold_set = {}
	self:_save_holds()
	self.log.info("periods: %s follows the periods again (%s)", table.concat(released, " and "),
		tostring(reason or "released"))
	return released
end

function P:settings_for(period, mode)
	period = period or self:current()
	if mode ~= nil and not periods.SYNC_MODES[mode] then
		return {}, {}
	end
	local levels = period and self:_settings()[period]
	if type(levels) ~= "table" or not periods.LABELS[period] then
		return {}, {}
	end
	local out, kept = {}, {}
	for _, field in ipairs(periods.FIELDS) do
		if self:held(field) then
			kept[#kept + 1] = field
		else
			out[field] = levels[field]
		end
	end
	table.sort(kept)
	return out, kept
end

-- The timer ------------------------------------------------------------------

function P:_arm()
	cancel(self.handle)
	self.handle = nil
	if not self.running then
		return
	end
	local now = self:_now()
	local delay = periods.MAX_ARM_MS
	local ok, at = pcall(self.next_boundary, self, now)
	if ok and at then
		delay = math.min(delay, at - now + periods.SLACK_MS)
	elseif not ok then
		self.log.warn("periods: finding the next boundary failed: %s", tostring(at))
	end
	delay = math.max(1, math.floor(delay))
	local gen = self.gen
	self.handle = self.timer(delay, function()
		if gen ~= self.gen or not self.running then
			return
		end
		self.handle = nil
		self:_tick("boundary")
	end)
	self.log.debug("periods: next look in %d s", math.floor(delay / 1000))
end

function P:_tick(why)
	local ok, period = pcall(self.current, self)
	if not ok then
		self.log.warn("periods: finding the period failed: %s", tostring(period))
		period = nil
	end
	local prev = self.last
	if period then
		self.last = period
	end
	if period and prev and period ~= prev then
		self.log.info("periods: %s from now (was %s, %s)", periods.LABELS[period], periods.LABELS[prev], why)
		if type(self.on_boundary) == "function" then
			local cb_ok, err = pcall(self.on_boundary, period, prev, why)
			if not cb_ok then
				self.log.warn("periods: on_boundary failed: %s", tostring(err))
			end
		end
	end
	self:_arm()
end

function P:start()
	self.gen = self.gen + 1
	self.running = true
	self:_holds()
	local ok, period = pcall(self.current, self)
	self.last = ok and period or nil
	self:_arm()
	return self.last
end

function P:stop()
	self.gen = self.gen + 1
	self.running = false
	cancel(self.handle)
	self.handle = nil
end

function P:refresh()
	if self.running then
		self:_tick("settings")
	end
end

function P:period()
	return self.last
end

function P:is_running()
	return self.running
end

function P:describe(now)
	now = num.finite(now) or self:_now()
	local period = self:current(now)
	if not period then
		return "No period: the controller's clock gives no date"
	end
	local text = periods.LABELS[period]
	local at = self:next_boundary(now)
	if at then
		local _, _, _, hh, mm = self.zone.date_of(at)
		if hh then
			text = text .. " until " .. periods.clock_text(hh * 60 + mm)
		end
	end
	local held = self:holds()
	if #held > 0 then
		text = text .. "; " .. table.concat(held, " and ") .. " set by hand"
	end
	return text
end

return periods
