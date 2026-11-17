#!/usr/bin/env lua5.1
-- Writes tests/fixtures/hue_syncbox.lua's data as JSON on stdout (#547,
-- docs/fakebox-design.md §2): the fake sync boxes read the same fixtures, the
-- Lua fake from the Lua file and the Python fake (tools/fakebox/) from
-- tests/fixtures/hue_syncbox.json, which is this script's output, so Python
-- never types them again. tools/check.sh fails when the two drift.
--
--   lua5.1 tools/fakebox/export_fixtures.lua > tests/fixtures/hue_syncbox.json
--
-- The output is deterministic: object keys sorted (byte order), two-space
-- indents, one value per line, a final newline. A table is a JSON array when
-- its keys are exactly 1..n, an object otherwise; an empty table follows
-- dkjson's rule (the fixture's object mark makes {}, no mark makes []), so
-- the JSON matches what the Lua fake answers. Functions (M.copy, M.json,
-- M.unkeyed_device) are left out. Whole numbers are written without a
-- decimal point. Run from anywhere: the repository is found from this
-- script's path.

local script = (arg and arg[0]) or "tools/fakebox/export_fixtures.lua"
local here = script:match("^(.*)/[^/]*$") or "."
local root = here .. "/../.."
package.path = root .. "/tests/?.lua;" .. package.path

local fixtures = require("fixtures.hue_syncbox")

local encode

local function quote(s)
	local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n",
		["\r"] = "\\r", ["\t"] = "\\t" }
	return '"' .. s:gsub('[%c"\\]', function(c)
		return escapes[c] or string.format("\\u%04x", c:byte())
	end) .. '"'
end

local function number(n)
	if n ~= n or n == math.huge or n == -math.huge then
		error("export_fixtures: a number JSON cannot hold: " .. tostring(n))
	end
	if n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	return string.format("%.17g", n)
end

-- "array", "object" or "empty-object"/"empty-array" for a table.
local function kind(t)
	local count, max = 0, 0
	for k, v in pairs(t) do
		if type(v) ~= "function" then
			count = count + 1
			if type(k) == "number" and k >= 1 and k == math.floor(k) then
				if k > max then max = k end
			else
				max = -1
			end
		end
	end
	if count == 0 then
		local mt = getmetatable(t)
		return (mt and mt.__jsontype == "object") and "empty-object" or "empty-array"
	end
	return (max == count) and "array" or "object"
end

local function keys_of(t)
	local out = {}
	for k, v in pairs(t) do
		if type(v) ~= "function" then
			out[#out + 1] = tostring(k)
		end
	end
	table.sort(out)
	return out
end

local function value_at(t, key)
	local v = t[key]
	if v == nil then
		v = t[tonumber(key)]
	end
	return v
end

function encode(value, indent, seen)
	local kind_of = type(value)
	if kind_of == "string" then
		return quote(value)
	elseif kind_of == "number" then
		return number(value)
	elseif kind_of == "boolean" then
		return tostring(value)
	elseif kind_of ~= "table" then
		error("export_fixtures: a value JSON cannot hold: " .. kind_of)
	end
	if seen[value] then
		error("export_fixtures: a table that contains itself")
	end
	seen[value] = true
	local inner = indent .. "  "
	local lines = {}
	local shape = kind(value)
	local out
	if shape == "empty-object" then
		out = "{}"
	elseif shape == "empty-array" then
		out = "[]"
	elseif shape == "array" then
		for i = 1, #value do
			lines[#lines + 1] = inner .. encode(value[i], inner, seen)
		end
		out = "[\n" .. table.concat(lines, ",\n") .. "\n" .. indent .. "]"
	else
		for _, key in ipairs(keys_of(value)) do
			lines[#lines + 1] = inner .. quote(key) .. ": " .. encode(value_at(value, key), inner, seen)
		end
		out = "{\n" .. table.concat(lines, ",\n") .. "\n" .. indent .. "}"
	end
	seen[value] = nil
	return out
end

io.write(encode(fixtures, "", {}), "\n")
