-- Small pure helpers shared by the bridge modules (lights, scenes, zone
-- lights, registry). Until 2026-10-24 each module carried its own
-- byte-identical copy (docs/reviews/slim-lights.md). No state, no C4 calls,
-- so the outputs are exactly what the copies produced.
local util = {}

-- A number above zero, or nil.
function util.positive(value)
	local n = tonumber(value)
	if n and n > 0 then
		return n
	end
	return nil
end

-- `s` without its trailing blanks (`%s`: space and bytes 9-13), counted
-- from the end: the pattern "%s+$" takes time quadratic in an inner run of
-- blanks, and util.norm sees raw Hue names (group names in Map Rooms By
-- Name, say), which a hostile peer can make a megabyte long.
local function rtrim(s)
	local last = #s
	while last > 0 do
		local b = s:byte(last)
		if b ~= 32 and (b < 9 or b > 13) then
			break
		end
		last = last - 1
	end
	return s:sub(1, last)
end

-- A name trimmed and lower-cased, for comparisons.
function util.norm(name)
	return rtrim((tostring(name or ""):gsub("^%s+", ""))):lower()
end

-- A text with its commas turned into spaces (picker items are
-- comma-delimited) and its control characters removed (`%c`: a newline or a
-- tab in a Hue name would garble a Composer row). `%c` is ASCII only (bytes
-- 0-31 and 127): LuaJIT, which runs the drivers (docs/design.md), classes
-- characters without the locale, so UTF-8 text such as "→" or "ü" is kept.
function util.sanitise(text)
	local s = tostring(text):gsub(",", " ")
	return (s:gsub("%c", ""))
end

-- The most characters a name the bridge hands to Control4 may have, and the
-- most bytes, for text that is not UTF-8 (docs/security-fixes-design.md §2).
-- No genuine Hue name comes near: Hue allows 32 characters
-- (docs/edge-cases-hue.md §6), and the longest name built from them, a zone
-- scene's "<Zone> <Scene>", has 65. A real name is never cut; a hostile one
-- is still bounded. 100 characters of UTF-8 are at most 400 bytes.
util.NAME_MAX = 100
util.NAME_MAX_BYTES = 400

-- A continuation byte of a UTF-8 character (0x80-0xBF); every other byte
-- starts a character.
local function continuation(b)
	return b >= 0x80 and b <= 0xBF
end

-- The length of the longest prefix of `s` that holds at most NAME_MAX
-- characters (counted by their first bytes) and ends before a character.
-- Only the first NAME_MAX_BYTES + 1 bytes are read, so a megabyte costs no
-- more than a short name. Text with too few character starts there is not
-- UTF-8: it is cut at NAME_MAX_BYTES, backing over at most three
-- continuation bytes (the most a UTF-8 character has), wherever that ends.
local function cut_point(s)
	local chars = 0
	for i = 1, math.min(#s, util.NAME_MAX_BYTES + 1) do
		if not continuation(s:byte(i)) then
			chars = chars + 1
			if chars > util.NAME_MAX then
				return i - 1
			end
		end
	end
	if #s <= util.NAME_MAX_BYTES then
		return #s
	end
	local cut = util.NAME_MAX_BYTES
	for _ = 1, 3 do
		if not continuation(s:byte(cut + 1)) then
			break
		end
		cut = cut - 1
	end
	return cut
end

-- A name fit for a Composer device name or a plain property row: what
-- AddDevice, RenameDevice and the devices' name and model rows get from the
-- bridge, where any app paired with it can set a name, as can a hostile peer
-- answering as the bridge (security review 2026-10-25 finding 8). nil or a
-- non-string is "" (a number its tostring); control characters go (`%c`, as
-- in sanitise); leading and trailing blanks go; at most NAME_MAX characters
-- and NAME_MAX_BYTES bytes stay, cut before a character (cut_point). Commas
-- stay: only picker lists need sanitise's rule. Idempotent (the cut is
-- trimmed again), which the name comparisons in bridge/owner.lua rely on: a
-- name made from a display name compares equal to the display name of the
-- raw one. Linear in the length: the trailing blanks are counted from the
-- end, as the pattern "%s+$" would take time quadratic in an inner run of
-- blanks (20000 of them: 1.5 s on lua5.1).
function util.display_name(text)
	if type(text) == "number" then
		text = tostring(text)
	elseif type(text) ~= "string" then
		return ""
	end
	local s = text:gsub("%c", ""):gsub("^%s+", "")
	if #s > util.NAME_MAX then  -- fewer bytes are fewer characters: nothing to count
		s = s:sub(1, cut_point(s))
	end
	-- With the control characters gone, a space is the only blank `%s` knows.
	local last = #s
	while last > 0 and s:byte(last) == 32 do
		last = last - 1
	end
	return s:sub(1, last)
end

-- A name as the name matches compare it (Link Devices): its display name,
-- trimmed and lower-cased. A device named after the display name of a long
-- or garbled Hue name and that Hue name meet on the same key.
function util.name_key(text)
	return util.norm(util.display_name(text))
end

-- A persisted timestamp is trusted only within this century: os.date
-- raises on absurd values, and a restored backup is not above them.
local function sane(ts)
	ts = tonumber(ts)
	return ts and ts >= 0 and ts < 4102444800 and ts or nil
end

function util.date_of(ts)
	ts = sane(ts)
	if not ts then
		return "?"
	end
	return os.date("%Y-%m-%d", ts)
end

function util.short_date_of(ts)
	ts = sane(ts)
	if not ts then
		return "?"
	end
	return os.date("%m-%d", ts)
end

function util.plural(n, word)
	return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

-- Up to `max` names joined with ", ", then " +N more".
function util.some(names, max)
	if #names <= max then
		return table.concat(names, ", ")
	end
	local head = {}
	for i = 1, max do
		head[i] = names[i]
	end
	return table.concat(head, ", ") .. string.format(" +%d more", #names - max)
end

-- A stable one-line signature of a params table (sorted keys), to tell
-- whether a message would repeat the last one sent.
function util.signature(params)
	local keys = {}
	for k in pairs(params) do
		keys[#keys + 1] = k
	end
	table.sort(keys)
	local parts = {}
	for _, k in ipairs(keys) do
		parts[#parts + 1] = k .. "=" .. tostring(params[k])
	end
	return table.concat(parts, "\n")
end

-- True when the list `fields` holds `name`; false for a nil (or any other
-- non-table) list, which a future caller may pass as "nothing changed".
function util.has_field(fields, name)
	for _, field in ipairs(type(fields) == "table" and fields or {}) do
		if field == name then
			return true
		end
	end
	return false
end

-- The one explanatory picker entry with value "" (nothing to pick).
function util.empty_list(text)
	return { { text = text, value = "" } }
end

-- A registry entry's capabilities as the command queue and HUE_CONFIGURE
-- read them: booleans and numbers (a store an older build wrote may hold
-- strings), nil for anything that is not a table. `min_dim_default` fills a
-- missing min_dim (the zone lights' 1; the lights leave it nil). Until
-- 2026-10-25 lights.lua and zone_lights.lua each carried a copy
-- (docs/reviews/diff-review-2026-10-24.md, row 10).
function util.copy_caps(caps, min_dim_default)
	if type(caps) ~= "table" then
		return nil
	end
	return {
		has_color = caps.has_color == true or caps.has_color == "true",
		has_cct = caps.has_cct == true or caps.has_cct == "true",
		mirek_min = tonumber(caps.mirek_min),
		mirek_max = tonumber(caps.mirek_max),
		min_dim = tonumber(caps.min_dim) or min_dim_default,
	}
end

-- True when two copy_caps() tables say the same (both nil counts as the same).
function util.same_caps(a, b)
	if a == nil or b == nil then
		return a == b
	end
	return a.has_color == b.has_color and a.has_cct == b.has_cct and a.mirek_min == b.mirek_min
		and a.mirek_max == b.mirek_max and a.min_dim == b.min_dim
end

return util
