-- Numbers and timestamps from outside the driver (proxy commands, bridge
-- messages, Hue reports, persisted values) are checked here before they
-- reach a request body, a timer, a comparison or os.date: NaN fails every
-- comparison and slips through a plain range check, infinity makes a timer
-- or a ramp that never ends, and os.date raises on an absurd timestamp
-- (security review of 2026-11-13, #486 and #487;
-- docs/security-fixes-2026-11-design.md).
--
-- No module-level state.

local num = {}

-- `v` as a finite number (a number, or a string Lua reads as one), else nil.
function num.finite(v)
	v = tonumber(v)
	if v == nil or v ~= v or v == math.huge or v == -math.huge then
		return nil
	end
	return v
end

-- `v` as a finite number within lo..hi (either bound may be nil), else
-- `default` (nil when not given). Out of range is refused, not clamped:
-- use num.clamp to clamp.
function num.within(v, lo, hi, default)
	v = num.finite(v)
	if v == nil or (lo ~= nil and v < lo) or (hi ~= nil and v > hi) then
		return default
	end
	return v
end

-- `v` as a finite number clamped into lo..hi, else `default`.
function num.clamp(v, lo, hi, default)
	v = num.finite(v)
	if v == nil then
		return default
	end
	if lo ~= nil and v < lo then
		v = lo
	end
	if hi ~= nil and v > hi then
		v = hi
	end
	return v
end

-- `v` rounded to the nearest whole number within lo..hi, else `default`.
function num.int(v, lo, hi, default)
	v = num.finite(v)
	if v == nil then
		return default
	end
	v = math.floor(v + 0.5)
	if (lo ~= nil and v < lo) or (hi ~= nil and v > hi) then
		return default
	end
	return v
end

-- A Unix time in seconds that os.date accepts on every controller: within
-- 1970..2099, else nil. (The bridge's util.date_of uses the same bounds.)
num.TIME_MAX = 4102444800

function num.timestamp(ts)
	return num.within(ts, 0, num.TIME_MAX - 1)
end

-- os.date(fmt, ts) for a sane `ts`, else `fallback` (default "?"). With
-- `ts` nil, the current time, as os.date itself.
function num.date(fmt, ts, fallback)
	if ts == nil then
		return os.date(fmt)
	end
	ts = num.timestamp(ts)
	if ts == nil then
		return fallback or "?"
	end
	return os.date(fmt, math.floor(ts))
end

return num
