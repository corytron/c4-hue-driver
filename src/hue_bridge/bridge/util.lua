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

-- A name trimmed and lower-cased, for comparisons.
function util.norm(name)
	return (tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")):lower()
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
