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

-- A text with its commas turned into spaces (picker items are comma-delimited).
function util.sanitise(text)
	return (tostring(text):gsub(",", " "))
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

function util.has_field(fields, name)
	for _, field in ipairs(fields) do
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

return util
