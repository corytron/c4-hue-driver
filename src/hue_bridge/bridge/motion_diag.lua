-- Log Motion Diagnostics (docs/motion-design.md §4.3): the bridge action a
-- tester who owns Hue motion sensors runs on his own system. He pastes its
-- Lua output into a public GitHub issue, so every line is written for that
-- page: the resource types his bridge serves, every sensor and MotionAware
-- resource with its fields, their types and the values that identify no one,
-- the links between the resources, then ten minutes of their events. Names,
-- ids and addresses are taken out. What is fetched, logged and redacted
-- follows docs/motion-hue-research.md (HR) §6; the shapes are its §1-§3 and §5.
--
-- Interface: motion_diag.new(ctx), :run(cb), :on_container(container),
-- :capturing(). ctx needs `http` (the bridge's keyed request); `log`,
-- `now_ms`, `set_timer`, `secrets`, `bridge_info` and `on_done` are optional
-- (the list above motion_diag.new says what each is).
--
-- A run. `run(cb)` answers at once, cb(true, text) for Last Action ("Motion
-- diagnostics start in 20 seconds: open this bridge's Lua tab now. ..."), and
-- waits WAIT_MS (20 s) on ctx.set_timer: Composer collects a device's Lua
-- output only while its Lua tab is open, and the action is clicked on the
-- Actions tab. Then the pass:
--   - one GET at a time of every type in STEPS (HR §6.1), each logged as a
--     "GET <type>" line (HTTP status, the errors array, the item count) and
--     one line per item logged;
--   - a "counts" line;
--   - the line "Motion diagnostics: pass done (N sensors, M areas, K
--     automations); capturing events for 10 minutes." (or "pass failed"
--     when the bridge never answered).
-- Then the capture: for CAPTURE_MS (10 minutes, measured by ctx.set_timer and
-- by the ctx clock) every stream item of those types is logged the same way,
-- at most CAPTURE_LINES (200) lines, closed by a "capture end" line. A second
-- run while one waits, fetches or captures starts over: the wait is cancelled,
-- an unfinished pass is dropped, a capture logs its end, and a new wait begins.
--
-- What is logged (HR §6.1, §6.3):
--   - clip: the served types, sorted, then which sensor and MotionAware types
--     are served and which are not.
--   - motion, light_level, temperature, grouped_motion, grouped_light_level,
--     service_group and the four MotionAware types: every item.
--   - device: only sensors (a `motion` service, a model id starting "SML", or
--     the owner of a motion, light_level or temperature item).
--   - device_power, zigbee_connectivity, device_software_update: only items
--     a sensor owns.
--   - camera_motion, contact, tamper: counted only.
--   - room, zone, bridge_home: one summary line per group that lists a
--     grouped_motion or grouped_light_level service or has a sensor child.
--   - behavior_script: one line listing every script by alias, name and
--     category ("6b21… "Timers" (automation)"): a script's name is Signify's
--     product text, never the owner's.
--   - behavior_instance (the Hue automations, #280): every item, its header
--     naming its script ("behavior_instance 9ad5… for "Timers"
--     (automation)"); strings under `state` shown as enumerations;
--     `migrated_from` as "/<word>/<number>" only; `configuration` walked
--     like any other block, so its references read rtype:alias and the
--     areas, rooms, lights and sensors it targets match the rest of the pass.
-- At most PASS_ITEMS items per type in the pass (behavior_instance: 40); the
-- rest are counted. The capture also logs an item of any other type that a
-- sensor device owns.
--
-- An item's line: its type and redacted id, then every key path present,
-- sorted, as path=value. The value's form gives its JSON type: true/false,
-- numbers (a light_level also in lux), "text" (a string shown as sent),
-- <str:N> (a string withheld, N bytes), [..], {..}, rtype:abcd… (a {rid,
-- rtype} reference), ±N.NNs (a time). In the capture the line starts with
-- the time since the pass began, the container's number and type ("+12.40s
-- c#3 update"), and says how long after the same resource's previous item it
-- came. A line longer than LINE_MAX bytes continues on "diag: + " lines.
--
-- Redaction comes first: no Hue name, full resource id, MAC address, bridge
-- id, IP address or application key may reach the log. Two layers:
--  1. Values are shown by their key. Booleans and numbers are shown.
--     - Strings are shown only under the keys that HR §6.4 keeps: enumerations
--       (`type`, `rtype`, `status`, `state`, `health`, `battery_state`,
--       archetypes, `capabilities`, `problems`, a script's `category`, a
--       dependee's `level`, and everything under an automation's `state`)
--       when they are snake_case words, and the manufacturer's product data
--       (`model_id`, `product_name`, `manufacturer_name`, `software_version`,
--       `hardware_platform_type`, a behavior_script's name) in a plain
--       character set.
--     - `id_v1` and `migrated_from` are shown only as "/<word>/<number>".
--     - A time of day (`hour`, `minute`, `second`) gives <clock>: an
--       automation's times say when people wake, leave and come home.
--     Keys are matched by their words ("extended_pan_id" is extended, pan,
--     id; "participants" holds no "pan"):
--     - A name key (`name`, a word ending in "name" or "names") gives
--       "name#N": one N per distinct text, kept for the run.
--     - An id key (`id`, `rid`, a word `id`, `uuid` or `guid`) gives the id's
--       first 4 characters and "…" when it is a UUID; a second UUID with the
--       same 4 gets "…2", so one alias never stands for two resources.
--       Anything else there gives "id?N".
--     - MAC, PAN, bridge-id, key, password, address, URL, serial and location
--       keys give a placeholder (<mac>, <pan>, <bridge>, <secret>, <addr>,
--       <serial>, <geo>), whatever they hold. Location covers coordinates,
--       geofences, positions, time zones, cities, countries and postal codes.
--     - Times (`changed`, `creationtime`, ...) become seconds relative to the
--       pass's start.
--     - Every other string is <str:N>: an unknown field shows its path and
--       type, never its value.
--  2. Every finished line is scrubbed before it is logged. Control characters
--     become spaces, so a value never starts a line of its own. Then these are
--     replaced: the strings ctx.secrets() names; UUIDs (by their alias); MAC-
--     and IPv6-like runs; IPv4 addresses; clock times ("07:15", "7:05:16.5")
--     by <clock>; runs of 12 or more hex digits (a bridge id is 16); and
--     key-like tokens (20 or more letters and digits).
-- No logged line holds a wall-clock time: times are relative to the pass's
-- start, and nothing logs when that was, since the two together would date
-- the household's motion. Only the Last Action text that run() answers with
-- (cb) says when the pass starts.
-- Error descriptions from the bridge are shown only when every word is in a
-- small vocabulary of error words, else as <text:N>. The raw body is never
-- logged. Requests go out with `quiet`, so bridge/http.lua logs a failed GET
-- at debug level only (curl's text can carry the bridge's address); the
-- failure line here is scrubbed.
--
-- Callback rules as in the other bridge modules: the GETs run from the timer
-- and from http callbacks; on_container runs inside OnBodyChunk, starts no
-- transfer and only logs. Every callback body is pcall-wrapped. Nothing here
-- writes to the bridge, sends to a device or persists anything.

local log = require("common.log")
local util = require("bridge.util")

local motion_diag = {}
motion_diag.__index = motion_diag

motion_diag.WAIT_MS = 20000          -- from the click to the pass: time to open the Lua tab
motion_diag.CAPTURE_MS = 600000      -- the event capture after the pass
motion_diag.CAPTURE_LINES = 200      -- the capture's lines, its limit and end lines included
motion_diag.CAPTURE_RESERVE = 3      -- of those, kept for the limit line and two end lines
motion_diag.PASS_ITEMS = 20          -- items logged per type in the pass
motion_diag.NO_ANSWER_MAX = 3        -- GETs in a row without an HTTP answer that end the pass
motion_diag.LINE_MAX = 400           -- bytes of one logged line
motion_diag.ITEM_MAX = 2400          -- bytes of one item's text
motion_diag.FIELDS_MAX = 60          -- fields shown per item
motion_diag.ARRAY_MAX = 12           -- elements shown per array (and fields per object inside one)
motion_diag.DEPTH_MAX = 10           -- nesting levels shown (an automation's configuration nests deep)
motion_diag.PREFIX = "diag: "
-- Continuation lines are numbered ("diag: +2 ", "diag: +3 "): Composer's Lua
-- pane has shown two of them in swapped order (#288).
motion_diag.CONTINUED = "diag: +%d "
motion_diag.RESOURCE_PATH = "/clip/v2/resource/"

-- The pass, in order (HR §6.1). Modes:
--   clip     the served types
--   all      every item
--   sensors  sensor devices only
--   owned    items a sensor device owns
--   count    the count only
--   groups   a summary line per group with motion services or sensor children
--   scripts  one line listing the scripts (each step's `max` caps its item lines)
-- motion, light_level and temperature come before device: their owners are
-- sensors too; behavior_script before behavior_instance, whose lines name
-- their scripts.
motion_diag.STEPS = {
	{ type = "clip", mode = "clip" },
	{ type = "motion", mode = "all" },
	{ type = "light_level", mode = "all" },
	{ type = "temperature", mode = "all" },
	{ type = "device", mode = "sensors" },
	{ type = "device_power", mode = "owned" },
	{ type = "zigbee_connectivity", mode = "owned" },
	{ type = "device_software_update", mode = "owned" },
	{ type = "grouped_motion", mode = "all" },
	{ type = "grouped_light_level", mode = "all" },
	{ type = "service_group", mode = "all" },
	{ type = "motion_area_configuration", mode = "all" },
	{ type = "convenience_area_motion", mode = "all" },
	{ type = "security_area_motion", mode = "all" },
	{ type = "motion_area_candidate", mode = "all" },
	{ type = "camera_motion", mode = "count" },
	{ type = "contact", mode = "count" },
	{ type = "tamper", mode = "count" },
	{ type = "room", mode = "groups" },
	{ type = "zone", mode = "groups" },
	{ type = "bridge_home", mode = "groups" },
	{ type = "behavior_script", mode = "scripts" },
	{ type = "behavior_instance", mode = "all", max = 40 },
}

-- The capture's rule per item type: the pass's, a script logged as any item
-- (a type not listed is not logged).
motion_diag.CAPTURE_MODES = {}
for _, step in ipairs(motion_diag.STEPS) do
	if step.mode ~= "clip" then
		motion_diag.CAPTURE_MODES[step.type] = step.mode == "scripts" and "all" or step.mode
	end
end

-- The clip line's two families (HR §1.2, §1.8, §1.9 and §2).
local SENSOR_TYPES = { "motion", "light_level", "temperature", "device_power", "zigbee_connectivity",
	"device_software_update", "grouped_motion", "grouped_light_level", "service_group", "camera_motion", "contact",
	"tamper" }
local AREA_TYPES = { "motion_area_configuration", "convenience_area_motion", "security_area_motion",
	"motion_area_candidate" }
local COUNTED = { "camera_motion", "contact", "tamper" }

-- The items whose owner is a sensor device.
local SENSOR_SERVICES = { motion = true, light_level = true, temperature = true }

local LEGEND = "legend: \"x\" a string as sent; <str:N> a string withheld (N bytes); name#N a Hue name; "
	.. "abcd… a resource id (its first 4 characters; …2 for a second id with the same 4); rtype:abcd… a "
	.. "reference; ±N.NNs a time from the pass's start (bridge clock against controller clock); <clock> a time "
	.. "of day; <mac> <pan> <bridge> <secret> <addr> <geo> <ip> <hex> <token> <key> removed"

-- Keys and values ---------------------------------------------------------------

-- The manufacturer's product data, shown in a plain character set: words
-- with spaces for the two names, one word for the rest.
local PRODUCT_KEYS = { model_id = "word", manufacturer_name = "text", product_name = "text", software_version = "word",
	hardware_platform_type = "word" }
-- Enumerations, shown when they are snake_case words.
local ENUM_KEYS = { type = true, rtype = true, status = true, state = true, health = true, battery_state = true,
	archetype = true, product_archetype = true, capabilities = true, problems = true, resources = true,
	["function"] = true, mode = true, action = true, category = true, level = true }
-- A time of day, as an automation's `time` block holds it.
local CLOCK_KEYS = { hour = true, minute = true, second = true }
-- Paths shown only as "/<word>/<number>".
local PATH_KEYS = { id_v1 = true, migrated_from = true }
-- Times, shown relative to the pass's start.
local TIME_KEYS = { changed = true, creationtime = true, last_recall = true, last_changed = true, updated = true }
-- Arrays, so an empty one reads [] rather than {}.
local ARRAY_KEYS = { services = true, children = true, participants = true, problems = true, capabilities = true,
	resources = true, errors = true, data = true, dependees = true, timeslots = true, recurrence_days = true,
	who = true, what = true, where = true, items = true }

local function has(k, word)
	return k:find(word, 1, true) ~= nil
end

-- A key's words: "extended_pan_id" is extended, pan, id. Whole words, so
-- "participants" holds no "pan" and "identify" no "id".
local function words(k)
	local list = {}
	for w in k:gmatch("[^_]+") do
		list[w] = true
	end
	return list
end

local function any_word(list, pred)
	for w in pairs(list) do
		if pred(w) then
			return true
		end
	end
	return false
end

local SECRET_WORDS = { key = true, keys = true, token = true, secret = true, password = true, passwd = true,
	pass = true, username = true, credential = true, credentials = true }
local ADDRESS_WORDS = { ip = true, ipv4 = true, ipv6 = true, ipaddress = true, address = true, addr = true,
	host = true, hostname = true, url = true, uri = true, href = true }
local GEO_WORDS = { latitude = true, longitude = true, lat = true, lon = true, lng = true, geo = true,
	geolocation = true, location = true, locations = true, geometry = true, geofence = true, geofences = true,
	geofencing = true, coordinates = true, coordinate = true, coords = true, position = true, positions = true,
	gps = true, altitude = true, elevation = true, timezone = true, tz = true, country = true, city = true,
	postal = true, postcode = true, zip = true, zipcode = true, street = true, region = true }

-- The placeholder a key's value becomes, whatever it holds; nil for a key
-- that is shown. `k` is lower-cased.
local function withheld(k)
	if PATH_KEYS[k] or PRODUCT_KEYS[k] then
		return nil
	end
	local w = words(k)
	if any_word(w, function(x) return x:sub(1, 3) == "mac" end) then
		return "<mac>"
	elseif w.pan or w.panid then
		return "<pan>"
	elseif k == "bridgeid" or (w.bridge and w.id) then
		return "<bridge>"
	elseif (w.user and w.name) or any_word(w, function(x) return SECRET_WORDS[x] or x:sub(-3) == "key" end) then
		return "<secret>"
	elseif any_word(w, function(x) return ADDRESS_WORDS[x] end) then
		return "<addr>"
	elseif any_word(w, function(x) return x:sub(1, 6) == "serial" end) then
		return "<serial>"
	elseif (w.time and w.zone) or any_word(w, function(x) return GEO_WORDS[x] or x:sub(1, 3) == "geo" end) then
		return "<geo>"
	end
	return nil
end

-- `name`, `metadata.name`, an area's `name`, "nickname", "display_name",
-- "names"; not the product data's names.
local function name_key(k)
	return not PRODUCT_KEYS[k] and any_word(words(k), function(x)
		return x:sub(-4) == "name" or x:sub(-5) == "names"
	end)
end

-- `id`, `rid`, `owner_id`, "uuid"; not `id_v1` (shown as a path) nor
-- `model_id` (product data).
local function id_key(k)
	if PATH_KEYS[k] or PRODUCT_KEYS[k] then
		return false
	end
	local w = words(k)
	return k == "rid" or w.id or w.uuid or w.guid or false
end

-- A key whose value is never walked into as an object.
local function special(k)
	return withheld(k) ~= nil or name_key(k) or id_key(k) or PATH_KEYS[k] == true or TIME_KEYS[k] == true
		or CLOCK_KEYS[k] == true
end

local SNAKE = "^[a-z][a-z0-9_]*$"

local function word_of(v)
	if type(v) == "string" and #v <= 40 and v:match(SNAKE) then
		return v
	end
	return nil
end

local function type_word(v)
	return word_of(v) or "<type?>"
end

local function key_text(key)
	if type(key) == "string" and #key <= 40 and key:match("^[a-z_][a-z0-9_]*$") then
		return key
	end
	return "<key>"
end

local function number_text(n)
	if n ~= n then
		return "nan"
	elseif n == math.huge or n == -math.huge then
		return n > 0 and "inf" or "-inf"
	elseif n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	return string.format("%.6g", n)
end

-- A light level's lux (HR §1.4): 10^((v - 1) / 10000), 0 meaning too dark.
local function lux_text(v)
	if v <= 0 then
		return "(dark)"
	elseif v > 100000 then
		return ""
	end
	local lux = 10 ^ ((v - 1) / 10000)
	if lux < 10 then
		return string.format("(%.2flx)", lux)
	elseif lux < 100 then
		return string.format("(%.1flx)", lux)
	end
	return string.format("(%.0flx)", lux)
end

local function quoted(s)
	return '"' .. s .. '"'
end

local function withheld_string(s)
	return "<str:" .. #s .. ">"
end

local function enum_text(s)
	local w = word_of(s)
	return w and quoted(w) or withheld_string(s)
end

local function product_text(kind, s)
	if kind == "word" and #s <= 32 and s:match("^[%w%.%-_]+$") then
		return quoted(s)
	elseif kind == "text" and #s <= 64 and s:match("^[%w%.%-_ ()/+,']+$") then
		return quoted(s)
	end
	return withheld_string(s)
end

local function v1_text(v)
	if type(v) ~= "string" then
		return "<v1:" .. type(v) .. ">"
	elseif #v <= 32 and v:match("^/[a-z_]+/%d+$") then
		return quoted(v)
	end
	return "<v1:" .. #v .. ">"
end

-- Days from 1970-01-01 to a date of the proleptic Gregorian calendar.
local function days_from_civil(y, m, d)
	if m <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local doy = math.floor((153 * ((m + 9) % 12) + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

-- Seconds since the epoch of an ISO 8601 date-time ("2026-10-26T07:02:41.318Z",
-- or with an offset), as the bridge writes `changed` and `creationtime`; nil
-- for anything else.
local function iso_seconds(s)
	if #s > 40 then
		return nil
	end
	local y, mo, d, h, mi, sec, rest = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
	if not y then
		return nil
	end
	local frac = 0
	local digits, zone = rest:match("^%.(%d+)(.*)$")
	if digits then
		if #digits > 9 then
			return nil
		end
		frac = tonumber("0." .. digits)
		rest = zone
	end
	local offset = 0
	if rest ~= "Z" then
		local sign, oh, om = rest:match("^([%+%-])(%d%d):?(%d%d)$")
		if not sign then
			return nil
		end
		offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
	end
	y, mo, d, h, mi, sec = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(sec)
	if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or sec > 60 then
		return nil
	end
	return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec + frac - offset
end

local function is_array(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
			return false
		end
		n = n + 1
	end
	for i = 1, n do
		if t[i] == nil then
			return false
		end
	end
	return n > 0
end

-- A {rid, rtype} reference, as `owner`, `group` and the entries of
-- `services` and `children` are.
local function is_ref(t)
	local n = 0
	for key in pairs(t) do
		if key ~= "rid" and key ~= "rtype" then
			return false
		end
		n = n + 1
	end
	return n == 2 and type(t.rid) == "string"
end

local function key_order(a, b)
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return ta < tb
	elseif ta == "string" or ta == "number" then
		return a < b
	end
	return tostring(a) < tostring(b)
end

local function sorted_keys(t)
	local keys = {}
	for key in pairs(t) do
		keys[#keys + 1] = key
	end
	table.sort(keys, key_order)
	return keys
end

-- Text -------------------------------------------------------------------------

local function continuation(b)
	return b ~= nil and b >= 0x80 and b <= 0xBF
end

-- The length of the longest prefix of `text` of at most `max` bytes that ends
-- before a UTF-8 character.
local function cut_point(text, max)
	local cut = max
	while cut > 1 and continuation(text:byte(cut + 1)) do
		cut = cut - 1
	end
	return cut
end

-- `text` in pieces of at most `max` bytes, cut at a space in the second half
-- of a piece: the last one that starts a field (" path="), so a quoted value
-- stays whole, else the last one after a comma, else the last one; else
-- before a UTF-8 character. The space at a cut is dropped: a reader joins
-- the pieces with one.
local function wrap(text, max)
	local pieces = {}
	while #text > max do
		local window = text:sub(1, max + 1)
		local space
		for pos in window:gmatch("() [^ =]+=") do
			if pos > max / 2 then
				space = pos
			end
		end
		if not space then
			local comma = window:match(".*(), ")
			space = comma and comma + 1 > max / 2 and comma + 1 or window:match(".*() ")
		end
		if space and space > max / 2 then
			pieces[#pieces + 1] = text:sub(1, space - 1)
			text = text:sub(space + 1)
		else
			local cut = cut_point(text, max)
			pieces[#pieces + 1] = text:sub(1, cut)
			text = text:sub(cut + 1)
		end
	end
	pieces[#pieces + 1] = text
	return pieces
end

-- `text` with every occurrence of `needle` (compared without case, as plain
-- text) replaced by `repl`.
local function replace_plain(text, needle, repl)
	local lower, n = text:lower(), needle:lower()
	local parts, from = {}, 1
	while true do
		local first, last = lower:find(n, from, true)
		if not first then
			break
		end
		parts[#parts + 1] = text:sub(from, first - 1)
		parts[#parts + 1] = repl
		from = last + 1
	end
	if from == 1 then
		return text
	end
	parts[#parts + 1] = text:sub(from)
	return table.concat(parts)
end

local UUID = "%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x"
local UUID_EXACT = "^" .. UUID .. "$"

-- The scrubber's rules for one run of characters; nil keeps the run.
local function address_run(s)
	if s:match("^%x%x[:%-]%x%x[:%-]%x%x[:%-]%x%x") then
		return "<mac>"
	end
	local _, colons = s:gsub(":", ":")
	if colons >= 3 and (has(s, "::") or s:find("[a-fA-F]")) then
		return "<addr>"
	end
	return nil
end

local function ipv4_run(s)
	for part in s:gmatch("%d+") do
		if #part > 3 or tonumber(part) > 255 then
			return nil
		end
	end
	return "<ip>"
end

local function hex_run(s)
	if #s >= 12 then
		return "<hex>"
	end
	return nil
end

local function token_run(s)
	if #s >= 20 and s:find("%d") and s:find("%a") and (s:find("%u") or not s:find("_", 1, true)) then
		return "<token>"
	end
	return nil
end

-- ctx.secrets() labels, by the words of the name a secret is given under.
local function secret_label(name)
	local w = words(type(name) == "string" and name:lower() or "")
	if any_word(w, function(x) return x:sub(-3) == "key" end) then
		return "<key>"
	elseif any_word(w, function(x) return ADDRESS_WORDS[x] end) then
		return "<ip>"
	elseif w.bridge or w.bridgeid then
		return "<bridge>"
	end
	return "<secret>"
end

-- The words a bridge's error description may consist of to be shown (with
-- the words of the types fetched, and "name" for a name's alias).
local VOCABULARY = {}
for word in ([[
	a access again allowed an and are as at available bad be been body busy by can cannot contains could denied does
	error errors exceeded exist exists failed field for forbidden found get has have in internal invalid is it json
	later limit link many method missing no not of ok on only or parameter please post put rate request requests
	required resource resources server service supported the this timeout to too try type unable unauthorized
	unavailable unknown unsupported user value was with name
	clip v motion light level temperature device power zigbee connectivity software update grouped group camera
	contact tamper area configuration convenience security candidate room zone bridge home
]]):gmatch("%a+") do
	VOCABULARY[word] = true
end

local function c4_time()
	return C4:GetTime()
end

-- Milliseconds since the epoch: C4:GetTime [verified: SDK 34_timer/_2-GetTime,
-- OS 3.2.3 and later], else os.time().
local function default_now_ms()
	local ok, ms = pcall(c4_time)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

-- The bridge driver's own rows and the controller's version, for the first lines.
local function default_bridge_info()
	local info = {}
	if type(Properties) == "table" then
		info.model = Properties["Bridge Model"]
		info.firmware = Properties["Bridge Firmware"]
		info.driver = Properties["Driver Version"]
	end
	local ok, v = pcall(function()
		return C4:GetVersionInfo()
	end)
	if ok and type(v) == "table" then
		info.os = v.version
	end
	return info
end

-- ctx fields (all but http optional):
--   http(req, cb)            the bridge's keyed request (driver.lua's bridge_request): req = { path, method = "GET",
--                            quiet = true }; cb(result) with bridge.http's { ok, code, json, err }
--   log                      common.log look-alike; log.always for the output, log.warn for this module's own faults
--   now_ms()                 milliseconds since the epoch (default C4:GetTime, else os.time() * 1000)
--   set_timer(delay_ms, fn)  C4:SetTimer(delay_ms, fn), an object with Cancel() [verified: SDK 34_timer/_1-SetTimer]
--   secrets()                strings never to be logged, by name: { key = <the application key>, ip = <the bridge's
--                            address>, bridge_id = <its id> }; each is replaced by <key>, <ip>, <bridge> (any
--                            other name: <secret>) wherever it appears, before the patterns below
--   bridge_info()            { model, firmware, driver, os } texts for the first lines (default: the Bridge Model,
--                            Bridge Firmware and Driver Version properties and C4:GetVersionInfo().version)
--   on_done(text)            called once when a run is over (its capture ended, or its pass had no answer from the
--                            bridge) with a text for Last Action
function motion_diag.new(ctx)
	ctx = ctx or {}
	assert(type(ctx.http) == "function", "motion_diag.new: ctx.http is required")
	ctx.log = ctx.log or log
	ctx.now_ms = ctx.now_ms or default_now_ms
	ctx.set_timer = ctx.set_timer or function(delay_ms, fn)
		return C4:SetTimer(delay_ms, fn)
	end
	ctx.bridge_info = ctx.bridge_info or default_bridge_info
	local self = setmetatable({
		ctx = ctx,
		gen = 0,           -- the run; a callback of an earlier run sees a newer one and stops
		wait = nil,        -- { gen, timer, at } while a run waits for its pass
		pass = nil,        -- { gen, answered, no_answer, last_failure } while the pass's GETs run
		capture = nil,     -- the capture's state while it runs (start_capture)
		t0 = 0,            -- the pass's start (ms): times are relative to it
		results = {},      -- type → what its GET answered, for the counts line
	}, motion_diag)
	self:reset_aliases()
	return self
end

-- The aliases and sensor sets of one run.
function motion_diag:reset_aliases()
	self.aliases = { ids = {}, prefixes = {}, names = {}, names_n = 0, odd = 0 }
	self.sensors = {}          -- sensor device rid → true
	self.sensor_services = {}  -- rid of a service a sensor device owns → true
	self.sensor_groups = {}    -- rid of a group with motion services or sensor children → true
	self.scripts = {}          -- behavior_script rid → { name, category, text } (learn_script)
	self.instance_scripts = {} -- behavior_instance rid → its script's rid
	self.results = {}
end

-- Plumbing ---------------------------------------------------------------------

function motion_diag:now_ms()
	local ok, ms = pcall(self.ctx.now_ms)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

function motion_diag:failed(what, err)
	self.ctx.log.warn("motion_diag: %s failed: %s", what, self:scrub(tostring(err)))
end

-- pcall wrapper for callback bodies; failures are logged, not raised.
function motion_diag:protect(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		self:failed(what, err)
	end
	return ok
end

function motion_diag:timer(delay_ms, fn)
	local ok, timer = pcall(self.ctx.set_timer, delay_ms, fn)
	if ok and timer ~= nil then
		return timer
	end
	self:failed("timer", ok and "no timer" or timer)
	return nil
end

local function cancel(timer)
	if timer and type(timer.Cancel) == "function" then
		pcall(timer.Cancel, timer)
	end
end

-- The secrets ctx.secrets() names, longest first.
function motion_diag:secrets()
	local fn = self.ctx.secrets
	if type(fn) ~= "function" then
		return {}
	end
	local ok, given = pcall(fn)
	if not ok or type(given) ~= "table" then
		return {}
	end
	local list = {}
	for name, value in pairs(given) do
		if type(value) == "string" and #value >= 4 then
			list[#list + 1] = { value = value, label = secret_label(name) }
		end
	end
	table.sort(list, function(a, b)
		return #a.value > #b.value
	end)
	return list
end

-- Layer 2 (see the header): the last pass over every line before it is
-- logged. `keep_clock` leaves clock times alone: only for the Last Action
-- text run() answers with.
function motion_diag:scrub(text, keep_clock)
	text = tostring(text):gsub("%c", " ")
	for _, secret in ipairs(self:secrets()) do
		text = replace_plain(text, secret.value, secret.label)
	end
	text = text:gsub(UUID, function(id)
		return self:id_alias(id)
	end)
	text = text:gsub("[%x:%-]+", address_run)
	text = text:gsub("%d+%.%d+%.%d+%.%d+", ipv4_run)
	if not keep_clock then
		text = text:gsub("%f[%w]%d%d?:%d%d[%d:%.]*", function(run)
			return "<clock>" .. run:match("[:%.]*$")  -- a separator after the time stays
		end)
	end
	text = text:gsub("%x+", hex_run)
	text = text:gsub("[%w%-_]+", token_run)
	return text
end

-- The logged pieces of a line: scrubbed, then wrapped.
function motion_diag:pieces(text)
	return wrap(self:scrub(text), motion_diag.LINE_MAX)
end

function motion_diag:write(pieces)
	for i, piece in ipairs(pieces) do
		self.ctx.log.always("%s", (i == 1 and motion_diag.PREFIX or motion_diag.CONTINUED:format(i)) .. piece)
	end
	return #pieces
end

function motion_diag:emit(text)
	return self:write(self:pieces(text))
end

-- Aliases ----------------------------------------------------------------------

function motion_diag:id_alias(value)
	if type(value) ~= "string" then
		return "<id:" .. type(value) .. ">"
	end
	local a = self.aliases
	local alias = a.ids[value]
	if alias then
		return alias
	end
	if value:match(UUID_EXACT) then
		local prefix = value:sub(1, 4):lower()
		local n = (a.prefixes[prefix] or 0) + 1
		a.prefixes[prefix] = n
		alias = prefix .. "…" .. (n > 1 and tostring(n) or "")
	else
		a.odd = a.odd + 1
		alias = "id?" .. a.odd
	end
	a.ids[value] = alias
	return alias
end

function motion_diag:name_alias(value)
	if type(value) ~= "string" then
		return "<name:" .. type(value) .. ">"
	elseif value == "" then
		return '""'
	end
	local a = self.aliases
	local alias = a.names[value]
	if not alias then
		a.names_n = a.names_n + 1
		alias = "name#" .. a.names_n
		a.names[value] = alias
	end
	return alias
end

-- Rendering (layer 1) -------------------------------------------------------------

function motion_diag:time_text(v)
	if type(v) ~= "string" then
		return "<time:" .. type(v) .. ">"
	end
	local s = iso_seconds(v)
	if not s then
		return "<time?>"
	end
	return string.format("%+.2fs", s - self.t0 / 1000)
end

-- `enum`: every string here is an enumeration (an automation's `state`).
function motion_diag.scalar_text(_, k, v, enum)
	local tv = type(v)
	if tv == "boolean" then
		return tostring(v)
	elseif tv == "number" then
		return number_text(v) .. (k == "light_level" and lux_text(v) or "")
	elseif tv == "string" then
		if k and PRODUCT_KEYS[k] then
			return product_text(PRODUCT_KEYS[k], v)
		elseif enum or (k and ENUM_KEYS[k]) then
			return enum_text(v)
		end
		return withheld_string(v)
	end
	return "<" .. tv .. ">"
end

function motion_diag:table_text(k, t, depth, enum)
	if next(t) == nil then
		return (k and ARRAY_KEYS[k]) and "[]" or "{}"
	elseif is_ref(t) then
		return type_word(t.rtype) .. ":" .. self:id_alias(t.rid)
	elseif depth >= motion_diag.DEPTH_MAX then
		return "{…}"
	elseif is_array(t) then
		local parts, n = {}, #t
		for i = 1, math.min(n, motion_diag.ARRAY_MAX) do
			parts[i] = self:value_text(k, t[i], depth + 1, enum)
		end
		if n > motion_diag.ARRAY_MAX then
			parts[#parts + 1] = string.format("+%d more", n - motion_diag.ARRAY_MAX)
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	return "{" .. table.concat(self:fields(t, depth + 1, motion_diag.ARRAY_MAX, nil, enum or nil), " ") .. "}"
end

-- One value under the (lower-cased) key `k`, nil for a key that is not a
-- string; `enum` as for scalar_text.
function motion_diag:value_text(k, v, depth, enum)
	if k then
		local placeholder = withheld(k)
		if placeholder then
			return placeholder
		elseif CLOCK_KEYS[k] then
			return "<clock>"
		end
		local list = type(v) == "table" and is_array(v)
		if PATH_KEYS[k] then
			return v1_text(v)
		elseif name_key(k) and not list then
			return self:name_alias(v)
		elseif id_key(k) and not list then
			return self:id_alias(v)
		elseif TIME_KEYS[k] and not list then
			return self:time_text(v)
		end
	end
	if type(v) == "table" then
		return self:table_text(k, v, depth, enum)
	end
	return self:scalar_text(k, v, enum)
end

-- Every field of `obj` as "path=value", objects walked into, in key order
-- (so sorted by path); at most `max`, the rest counted in out.more. `enums`:
-- true when every string below is an enumeration, or (at the top) the set of
-- keys whose values are.
function motion_diag:collect(obj, prefix, out, depth, max, skip, enums)
	for _, key in ipairs(sorted_keys(obj)) do
		local v = obj[key]
		if not (skip and skip[key]) then
			local enum = enums == true or (type(enums) == "table" and enums[key] == true)
			local k = type(key) == "string" and key:lower() or nil
			local path = prefix and (prefix .. "." .. key_text(key)) or key_text(key)
			if k and type(v) == "table" and next(v) ~= nil and not is_array(v) and not is_ref(v) and not special(k)
				and depth < motion_diag.DEPTH_MAX then
				self:collect(v, path, out, depth + 1, max, nil, enum or nil)
			elseif #out >= max then
				out.more = out.more + 1
			else
				out[#out + 1] = path .. "=" .. self:value_text(k, v, depth, enum)
			end
		end
	end
end

function motion_diag:fields(obj, depth, max, skip, enums)
	local out = { more = 0 }
	self:collect(obj, nil, out, depth, max, skip, enums)
	local more = out.more
	out.more = nil
	if more > 0 then
		out[#out + 1] = string.format("(+%d more fields)", more)
	end
	return out
end

local TOP = { id = true, type = true }
local INSTANCE_ENUMS = { state = true }

-- An item's header: its type and redacted id ("motion a0f3…").
function motion_diag:item_header(item)
	return type_word(item.type) .. " " .. self:id_alias(item.id)
end

-- A behavior_script as the pass lists it and an automation names it: its
-- name, Signify's product text, and its category ("Timers" (automation)).
-- A partial item (a stream update) keeps what the script showed before.
function motion_diag:learn_script(item)
	local id = type(item.id) == "string" and item.id or nil
	local known = id and self.scripts[id] or {}
	local meta = type(item.metadata) == "table" and item.metadata or {}
	local name, category = known.name, known.category
	if meta.name ~= nil then
		name = type(meta.name) == "string" and product_text("text", meta.name) or ("<name:" .. type(meta.name) .. ">")
	end
	if meta.category ~= nil then
		category = word_of(meta.category)
			or (type(meta.category) == "string" and withheld_string(meta.category) or "<category?>")
	end
	local script = { name = name or "<no name>", category = category or "no category" }
	script.text = script.name .. " (" .. script.category .. ")"
	if id then
		self.scripts[id] = script
	end
	return script
end

-- An automation's script, remembered so its later partial items and its
-- delete still name it.
function motion_diag:learn_instance(item)
	if type(item.id) == "string" and type(item.script_id) == "string" then
		self.instance_scripts[item.id] = item.script_id
	end
end

-- What follows an automation's header: " for "Timers" (automation)".
function motion_diag:item_note(item)
	if item.type ~= "behavior_instance" then
		return ""
	end
	local sid = item.script_id
	if type(sid) ~= "string" then
		sid = type(item.id) == "string" and self.instance_scripts[item.id] or nil
	end
	if not sid then
		return ""
	end
	local script = self.scripts[sid]
	return script and (" for " .. script.text) or " for an unknown script"
end

-- An item's fields, id and type left to the header; a script as its name and category.
function motion_diag:item_body(item)
	if item.type == "behavior_script" then
		return self:learn_script(item).text
	end
	local enums = item.type == "behavior_instance" and INSTANCE_ENUMS or nil
	local body = table.concat(self:fields(item, 1, motion_diag.FIELDS_MAX, TOP, enums), " ")
	if body == "" then
		body = "(no fields)"
	end
	if #body > motion_diag.ITEM_MAX then
		local cut = cut_point(body, motion_diag.ITEM_MAX)
		body = body:sub(1, cut) .. string.format(" (+%d bytes cut)", #body - cut)
	end
	return body
end

-- A bridge error description: shown when every word is an error word (a
-- name already met reads as its alias), else only its length.
function motion_diag:bridge_text(v)
	if type(v) ~= "string" then
		return "<" .. type(v) .. ">"
	end
	local s = v:gsub("%c", " ")
	local names = {}
	for text, alias in pairs(self.aliases.names) do
		if #text >= 3 then
			names[#names + 1] = { text = text, alias = alias }
		end
	end
	table.sort(names, function(a, b)
		return #a.text > #b.text
	end)
	for _, n in ipairs(names) do
		s = replace_plain(s, n.text, n.alias)
	end
	if #s > 100 then
		return "<text:" .. #v .. ">"
	end
	for word in s:gmatch("%a+") do
		if not VOCABULARY[word:lower()] then
			return "<text:" .. #v .. ">"
		end
	end
	return quoted((s:gsub('"', "'")))
end

-- A transfer's failure (curl's or the driver's text, never the bridge's
-- data): its control characters out, at most 120 bytes; scrubbed when logged.
local function failure_text(err)
	local s = tostring(err == nil and "no answer" or err):gsub("%c", " ")
	if #s > 120 then
		s = s:sub(1, cut_point(s, 120)) .. "…"
	end
	return s
end

-- A property or version text for the first lines.
local function info_text(v)
	if type(v) == "number" then
		return number_text(v)
	elseif type(v) ~= "string" or v == "" then
		return "unknown"
	end
	local s = v:gsub("%c", " ")
	if #s > 80 then
		s = s:sub(1, cut_point(s, 80)) .. "…"
	end
	return quoted((s:gsub('"', "'")))
end

-- Director's "3.4.2.746094" as "3.4.2 build 746094": four dotted numbers
-- would read as an address to the scrubber.
local function os_text(v)
	if type(v) == "string" then
		local a, b, c, d = v:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
		if a then
			return quoted(string.format("%s.%s.%s build %s", a, b, c, d))
		end
	end
	return info_text(v)
end

-- Sensors and groups ---------------------------------------------------------------

function motion_diag.is_sensor_device(_, item)
	if type(item.services) == "table" then
		for _, ref in ipairs(item.services) do
			if type(ref) == "table" and ref.rtype == "motion" then
				return true
			end
		end
	end
	local product = item.product_data
	local model = type(product) == "table" and product.model_id or nil
	return type(model) == "string" and model:sub(1, 3) == "SML"
end

-- A sensor device: it and its services are remembered for the run.
function motion_diag:learn_device(item)
	local id = item.id
	if not (self:is_sensor_device(item) or (type(id) == "string" and self.sensors[id])) then
		return false
	end
	if type(id) == "string" then
		self.sensors[id] = true
	end
	if type(item.services) == "table" then
		for _, ref in ipairs(item.services) do
			if type(ref) == "table" and type(ref.rid) == "string" then
				self.sensor_services[ref.rid] = true
			end
		end
	end
	return true
end

-- A motion, light_level or temperature item: its owner is a sensor.
function motion_diag:learn_owner(item)
	local owner = item.owner
	if type(owner) == "table" and owner.rtype == "device" and type(owner.rid) == "string" then
		self.sensors[owner.rid] = true
	end
	if type(item.id) == "string" then
		self.sensor_services[item.id] = true
	end
end

-- Whether a sensor owns the item (by its owner, or by its id for an item
-- that carries no owner, as a `delete` does).
function motion_diag:owned(item)
	local owner = item.owner
	local rid = type(owner) == "table" and owner.rid or nil
	local id = type(item.id) == "string" and item.id or nil
	if (type(rid) == "string" and self.sensors[rid]) or (id and self.sensor_services[id]) then
		if id then
			self.sensor_services[id] = true
		end
		return true
	end
	return false
end

function motion_diag:group_has_sensors(item)
	if type(item.services) == "table" then
		for _, ref in ipairs(item.services) do
			if type(ref) == "table" and (ref.rtype == "grouped_motion" or ref.rtype == "grouped_light_level") then
				return true
			end
		end
	end
	if type(item.children) == "table" then
		for _, ref in ipairs(item.children) do
			if type(ref) == "table" and type(ref.rid) == "string" and self.sensors[ref.rid] then
				return true
			end
		end
	end
	return false
end

-- The pass's line for a group (HR §6.1 item 4): its services, its number of
-- children and the sensors among them.
function motion_diag:group_line(item)
	local header = type_word(item.type) .. " " .. self:id_alias(item.id)
	local services = type(item.services) == "table" and self:value_text("services", item.services, 1) or "none"
	local children = type(item.children) == "table" and item.children or {}
	local sensors = {}
	for _, ref in ipairs(children) do
		if type(ref) == "table" and type(ref.rid) == "string" and self.sensors[ref.rid] then
			sensors[#sensors + 1] = type_word(ref.rtype) .. ":" .. self:id_alias(ref.rid)
		end
	end
	return string.format("%s services=%s children=%d sensors=[%s]", header, services, #children,
		table.concat(sensors, ","))
end

-- The pass ---------------------------------------------------------------------------

local MODES = {}

function MODES.clip(self, _, data, head, rec)
	local seen, types = {}, {}
	for _, item in ipairs(data) do
		local list = type(item) == "table" and item.resources or nil
		if type(list) == "table" then
			for _, t in ipairs(list) do
				local w = word_of(t) or "<type?>"
				if not seen[w] then
					seen[w] = true
					types[#types + 1] = w
				end
			end
		end
	end
	table.sort(types)
	rec.items = #types
	self:emit(string.format("%s, %d types: %s", head, #types, table.concat(types, " ")))
	local function split(family)
		local served, missing = {}, {}
		for _, t in ipairs(family) do
			if seen[t] then
				served[#served + 1] = t
			else
				missing[#missing + 1] = t
			end
		end
		return #served > 0 and table.concat(served, " ") or "none", #missing > 0 and table.concat(missing, " ") or "none"
	end
	local s_served, s_missing = split(SENSOR_TYPES)
	local a_served, a_missing = split(AREA_TYPES)
	self:emit(string.format("clip: sensor types served: %s; not served: %s. MotionAware types served: %s; not "
		.. "served: %s", s_served, s_missing, a_served, a_missing))
end

-- The GET line, then the items' lines (at most PASS_ITEMS).
function motion_diag:emit_items(step, list, head, rec, what)
	if what then
		self:emit(string.format("%s, %s, %s", head, util.plural(rec.items, "item"), what(#list)))
	else
		self:emit(string.format("%s, %s", head, util.plural(rec.items, "item")))
	end
	local max = step.max or motion_diag.PASS_ITEMS
	rec.logged = math.min(#list, max)
	for i = 1, rec.logged do
		self:emit(self:item_header(list[i]) .. self:item_note(list[i]) .. " " .. self:item_body(list[i]))
	end
	if #list > max then
		self:emit(string.format("%s: %d more not shown", step.type, #list - max))
	end
end

function MODES.all(self, step, data, head, rec)
	local list = {}
	for _, item in ipairs(data) do
		if type(item) == "table" then
			if SENSOR_SERVICES[item.type] then
				self:learn_owner(item)
			end
			self:learn_instance(item)
			list[#list + 1] = item
		end
	end
	self:emit_items(step, list, head, rec)
end

-- The scripts in one line, by alias, name and category.
function MODES.scripts(self, _, data, head, rec)
	local entries = {}
	for _, item in ipairs(data) do
		if type(item) == "table" then
			entries[#entries + 1] = self:id_alias(item.id) .. " " .. self:learn_script(item).text
		end
	end
	self:emit(string.format("%s, %s%s", head, util.plural(rec.items, "item"),
		#entries > 0 and (": " .. util.some(entries, 40)) or ""))
end

function MODES.sensors(self, step, data, head, rec)
	local list = {}
	for _, item in ipairs(data) do
		if type(item) == "table" and self:learn_device(item) then
			list[#list + 1] = item
		end
	end
	rec.matched = #list
	self:emit_items(step, list, head, rec, function(n)
		return util.plural(n, "sensor")
	end)
end

function MODES.owned(self, step, data, head, rec)
	local list = {}
	for _, item in ipairs(data) do
		if type(item) == "table" and self:owned(item) then
			list[#list + 1] = item
		end
	end
	rec.matched = #list
	self:emit_items(step, list, head, rec, function(n)
		return n .. " owned by sensors"
	end)
end

function MODES.count(self, _, _, head, rec)
	self:emit(string.format("%s, %s (counted only)", head, util.plural(rec.items, "item")))
end

function MODES.groups(self, step, data, head, rec)
	local list = {}
	for _, item in ipairs(data) do
		if type(item) == "table" and self:group_has_sensors(item) then
			if type(item.id) == "string" then
				self.sensor_groups[item.id] = true
			end
			list[#list + 1] = item
		end
	end
	rec.matched = #list
	self:emit(string.format("%s, %s, %d with motion services or sensors", head, util.plural(rec.items, "item"),
		#list))
	for i = 1, math.min(#list, motion_diag.PASS_ITEMS) do
		self:emit(self:group_line(list[i]))
	end
	if #list > motion_diag.PASS_ITEMS then
		self:emit(string.format("%s: %d more not shown", step.type, #list - motion_diag.PASS_ITEMS))
	end
end

function motion_diag:errors_text(errors)
	if type(errors) ~= "table" then
		return ", no errors array"
	end
	local n = #errors
	if n == 0 then
		return ", errors 0"
	end
	local shown = {}
	for i = 1, math.min(n, 2) do
		local e = errors[i]
		shown[i] = self:bridge_text(type(e) == "table" and e.description or e)
	end
	return string.format(", errors %d: %s%s", n, table.concat(shown, ", "), n > 2 and ", …" or "")
end

-- One GET's answer.
function motion_diag:on_answer(pass, step, r)
	local rec = { items = 0 }
	self.results[step.type] = rec
	if type(r) ~= "table" then
		r = { ok = false, err = "no result" }
	end
	local code = tonumber(r.code)
	if code == nil then
		pass.no_answer = pass.no_answer + 1
		rec.failed = true
		pass.last_failure = failure_text(r.err)
		self:emit(string.format("GET %s: no answer (%s)", step.type, pass.last_failure))
		return
	end
	pass.no_answer = 0
	pass.answered = pass.answered + 1
	rec.code = code
	local body = type(r.json) == "table" and r.json or nil
	local data = body and body.data
	local head = string.format("GET %s: HTTP %d", step.type, code)
	if not body then
		rec.no_data = true
		self:emit(head .. ", no JSON body")
		return
	end
	head = head .. self:errors_text(body.errors)
	if type(data) ~= "table" then
		rec.no_data = true
		self:emit(head .. ", no data array")
		return
	end
	rec.items = #data
	MODES[step.mode](self, step, data, head, rec)
end

function motion_diag:counts_text()
	local parts = {}
	for _, step in ipairs(motion_diag.STEPS) do
		local rec = self.results[step.type]
		local text
		if not rec then
			text = "not fetched"
		elseif rec.failed then
			text = "no answer"
		elseif rec.code < 200 or rec.code > 299 then
			text = "HTTP " .. rec.code
		elseif rec.no_data then
			text = "no data"
		elseif step.mode == "clip" then
			text = rec.items .. " types"
		elseif step.mode == "sensors" then
			text = string.format("%d (%s)", rec.items, util.plural(rec.matched or 0, "sensor"))
		elseif step.mode == "owned" then
			text = string.format("%d (%d owned by sensors)", rec.items, rec.matched or 0)
		elseif step.mode == "groups" then
			text = string.format("%d (%d with sensors)", rec.items, rec.matched or 0)
		else  -- all, count, scripts
			text = tostring(rec.items)
		end
		parts[#parts + 1] = step.type .. " " .. text
	end
	return "counts: " .. table.concat(parts, ", ")
end

-- The sensors and areas the pass found, for its last line.
function motion_diag:found()
	local devices = self.results.device
	local sensors = 0
	if devices and devices.matched then
		sensors = devices.matched
	else
		for _ in pairs(self.sensors) do
			sensors = sensors + 1
		end
	end
	local function items(t)
		local rec = self.results[t]
		return (rec and not rec.failed and rec.code >= 200 and rec.code <= 299 and rec.items) or 0
	end
	return sensors, items("motion_area_configuration"), items("behavior_instance")
end

function motion_diag:done(text)
	if type(self.ctx.on_done) == "function" then
		local ok, err = pcall(self.ctx.on_done, self:scrub(text))
		if not ok then
			self:failed("on_done", err)
		end
	end
end

function motion_diag:finish(pass)
	self.pass = nil
	self:emit(self:counts_text())
	if pass.answered == 0 then
		local why = pass.last_failure or "no answer"
		self:emit(string.format("Motion diagnostics: pass failed, the bridge did not answer (%s); no capture.", why))
		return self:done(string.format("Motion diagnostics stopped: the bridge did not answer (%s). See the Lua output.",
			why))
	end
	local sensors, areas, automations = self:found()
	self:start_capture()
	self:emit(string.format("Motion diagnostics: pass done (%s, %s, %s); capturing events for %d minutes.",
		util.plural(sensors, "sensor"), util.plural(areas, "area"), util.plural(automations, "automation"),
		motion_diag.CAPTURE_MS / 60000))
end

function motion_diag:next_step(pass, i)
	if self.pass ~= pass then
		return  -- a newer run took over
	end
	local step = motion_diag.STEPS[i]
	if not step then
		return self:finish(pass)
	elseif pass.no_answer >= motion_diag.NO_ANSWER_MAX then
		self:emit(string.format("pass stopped: %d GETs in a row without an answer", pass.no_answer))
		return self:finish(pass)
	end
	local answered = false
	local function answer(r)
		if answered or self.pass ~= pass then
			return
		end
		answered = true
		self:protect("GET " .. step.type, self.on_answer, self, pass, step, r)
		self:protect("pass", self.next_step, self, pass, i + 1)
	end
	local ok, err = pcall(self.ctx.http, { path = motion_diag.RESOURCE_PATH .. step.type, method = "GET", quiet = true },
		answer)
	if not ok and not answered then
		answer({ ok = false, err = "request failed: " .. tostring(err) })
	end
end

function motion_diag:start_pass(gen)
	if self.gen ~= gen then
		return
	end
	self.wait = nil
	self:reset_aliases()
	self.t0 = self:now_ms()
	local pass = { gen = gen, answered = 0, no_answer = 0, last_failure = nil }
	self.pass = pass
	self:emit(string.format("motion diagnostics, run %d: one GET per type, then %d s of events in at most %d lines",
		gen, motion_diag.CAPTURE_MS / 1000, motion_diag.CAPTURE_LINES))
	self:emit(LEGEND)
	local info = {}
	local ok, given = pcall(self.ctx.bridge_info)
	if ok and type(given) == "table" then
		info = given
	end
	self:emit(string.format("bridge: model %s, firmware %s; controller OS %s; driver version %s", info_text(info.model),
		info_text(info.firmware), os_text(info.os), info_text(info.driver)))
	self:next_step(pass, 1)
end

-- Stops whatever an earlier run still does; true when something was running.
function motion_diag:stop(why)
	local was = false
	if self.wait then
		cancel(self.wait.timer)
		self.wait = nil
		was = true
	end
	if self.pass then
		self.pass = nil
		self:emit("pass cut short: " .. why)
		was = true
	end
	if self.capture then
		self:end_capture(why)
		was = true
	end
	return was
end

-- The action. cb(true, text) at once; the pass follows after WAIT_MS.
function motion_diag:run(cb)
	local restarted = self:stop("restarted")
	self.gen = self.gen + 1
	local gen = self.gen
	local now = self:now_ms()
	local wait = { gen = gen, at = now + motion_diag.WAIT_MS }
	self.wait = wait
	wait.timer = self:timer(motion_diag.WAIT_MS, function()
		self:protect("pass", self.start_pass, self, gen)
	end)
	if not wait.timer then
		wait.at = now
	end
	if restarted then
		self:emit(string.format("restarted: the pass starts again in %d s", (wait.at - now) / 1000))
	end
	if type(cb) == "function" then
		-- No clock time: the bridge's last_action() also writes this text to the
		-- Lua output, and a start time there would anchor the relative times of
		-- every line that follows.
		local secs = math.floor((wait.at - now) / 1000 + 0.5)
		local when = secs > 0 and string.format("start in %d seconds", secs) or "start now"
		local ok, err = pcall(cb, true, self:scrub(string.format("Motion diagnostics %s: open this bridge's Lua tab "
			.. "now. The pass and 10 minutes of events follow; copy them into the Beta feedback issue.", when), true))
		if not ok then
			self:failed("run callback", err)
		end
	end
	if not wait.timer then
		self:protect("pass", self.start_pass, self, gen)
	end
end

-- The capture ----------------------------------------------------------------------

function motion_diag:elapsed(ms)
	return string.format("%+.2fs", (ms - self.t0) / 1000)
end

function motion_diag:start_capture()
	local now = self:now_ms()
	local cap = {
		start = now,
		lines = 0,        -- lines logged by the capture
		containers = 0,   -- containers received
		with_items = 0,   -- containers with an item logged
		items = 0,        -- items of the watched types
		logged = 0,       -- of those, logged
		dropped = 0,      -- of those, not logged after the line limit
		other = 0,        -- items of other types (lights, scenes, ...)
		counted = {},     -- type → count, for the counted-only types
		per = {},         -- "type alias" → items
		last = {},        -- id → when its previous item came (ms)
		full = false,
	}
	self.capture = cap
	cap.timer = self:timer(motion_diag.CAPTURE_MS, function()
		self:protect("capture end", function()
			if self.capture == cap then
				self:end_capture("time")
			end
		end)
	end)
end

function motion_diag:end_text(cap, why, now)
	local per = {}
	for header, n in pairs(cap.per) do
		per[#per + 1] = { header = header, n = n }
	end
	table.sort(per, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		end
		return a.header < b.header
	end)
	local shown = {}
	for i = 1, math.min(#per, 8) do
		shown[i] = per[i].header .. " " .. per[i].n
	end
	if #per > 8 then
		shown[#shown + 1] = string.format("+%d more", #per - 8)
	end
	local counted = {}
	for i, t in ipairs(COUNTED) do
		counted[i] = t .. " " .. (cap.counted[t] or 0)
	end
	return string.format("capture end (%s) at %s: %s logged (%d more after the line limit) from %d of %d "
		.. "containers; per resource: %s; counted only: %s; other items: %d", why, self:elapsed(now),
		util.plural(cap.logged, "item"), cap.dropped, cap.with_items, cap.containers,
		#shown > 0 and table.concat(shown, ", ") or "none", table.concat(counted, ", "), cap.other)
end

function motion_diag:end_capture(why)
	local cap = self.capture
	if not cap then
		return
	end
	self.capture = nil
	cancel(cap.timer)
	local now = self:now_ms()
	local pieces = self:pieces(self:end_text(cap, why, now))
	while #pieces > motion_diag.CAPTURE_RESERVE - 1 do
		table.remove(pieces)
	end
	cap.lines = cap.lines + self:write(pieces)
	self:done(string.format("Motion diagnostics done: %s of events logged. Copy the Lua output into the Beta "
		.. "feedback issue.", util.plural(cap.logged, "item")))
end

-- Whether the capture runs; one that is past its time ends here (its timer
-- may come later or not at all).
function motion_diag:capturing()
	local cap = self.capture
	if not cap then
		return false
	end
	if self:now_ms() - cap.start >= motion_diag.CAPTURE_MS then
		self:protect("capture end", self.end_capture, self, "time")
		return false
	end
	return true
end

-- What the capture does with an item: "log", "count" or nil (another type).
function motion_diag:verdict(item, kind)
	local mode = motion_diag.CAPTURE_MODES[item.type]
	if mode == nil then
		return self:owned(item) and "log" or nil  -- a sensor's service of a type HR §6.1 does not name
	elseif mode == "count" then
		return "count"
	elseif mode == "all" then
		if SENSOR_SERVICES[item.type] and kind ~= "delete" then
			self:learn_owner(item)
		end
		self:learn_instance(item)
		return "log"
	elseif mode == "sensors" then
		local id = type(item.id) == "string" and item.id or nil
		return ((id and self.sensors[id]) or (kind ~= "delete" and self:learn_device(item))) and "log" or nil
	elseif mode == "owned" then
		return self:owned(item) and "log" or nil
	end
	-- groups
	local id = type(item.id) == "string" and item.id or nil
	if (id and self.sensor_groups[id]) or self:group_has_sensors(item) then
		if id then
			self.sensor_groups[id] = true
		end
		return "log"
	end
	return nil
end

-- One item's line, logged when the line limit allows.
function motion_diag:capture_item(cap, item, kind, cnum, now, created)
	local header = self:item_header(item)
	cap.items = cap.items + 1
	cap.per[header] = (cap.per[header] or 0) + 1
	local id = type(item.id) == "string" and item.id or nil
	local last = id and cap.last[id] or nil
	if id then
		cap.last[id] = now
	end
	if cap.full then
		cap.dropped = cap.dropped + 1
		return false
	end
	local since = last and string.format("(%.2fs after its last)", (now - last) / 1000) or "(first)"
	local parts = { string.format("%s c#%d %s %s%s %s", self:elapsed(now), cnum, type_word(kind), header,
		self:item_note(item), since) }
	if created ~= nil then
		parts[#parts + 1] = "created=" .. self:time_text(created)
	end
	parts[#parts + 1] = self:item_body(item)
	local pieces = self:pieces(table.concat(parts, " "))
	if cap.lines + #pieces > motion_diag.CAPTURE_LINES - motion_diag.CAPTURE_RESERVE then
		cap.full = true
		cap.dropped = cap.dropped + 1
		cap.lines = cap.lines + self:emit(string.format("capture: line limit (%d) reached at %s; counting until the "
			.. "capture ends", motion_diag.CAPTURE_LINES, self:elapsed(now)))
		return false
	end
	cap.lines = cap.lines + self:write(pieces)
	cap.logged = cap.logged + 1
	return true
end

function motion_diag:capture_container(container)
	local cap = self.capture
	cap.containers = cap.containers + 1
	if type(container) ~= "table" or type(container.data) ~= "table" then
		return 0
	end
	local cnum, kind = cap.containers, container.type
	-- Devices first: a sensor paired in this container has its services logged too.
	if kind ~= "delete" then
		for _, item in ipairs(container.data) do
			if type(item) == "table" and item.type == "device" then
				self:learn_device(item)
			end
		end
	end
	local now = self:now_ms()
	local logged, created = 0, container.creationtime
	for _, item in ipairs(container.data) do
		if type(item) == "table" then
			local verdict = self:verdict(item, kind)
			if verdict == "log" then
				if self:capture_item(cap, item, kind, cnum, now, created) then
					logged = logged + 1
					created = nil  -- the container's time on its first line only
				end
			elseif verdict == "count" then
				cap.counted[item.type] = (cap.counted[item.type] or 0) + 1
			else
				cap.other = cap.other + 1
			end
		end
	end
	if logged > 0 then
		cap.with_items = cap.with_items + 1
	end
	return logged
end

-- One event-stream container (the coordinator's fan-out, after the motion
-- module): logged while the capture runs. Returns the number of items logged.
function motion_diag:on_container(container)
	if not self:capturing() then
		return 0
	end
	local ok, n = pcall(self.capture_container, self, container)
	if not ok then
		self:failed("capture", n)
		return 0
	end
	return n
end

return motion_diag
