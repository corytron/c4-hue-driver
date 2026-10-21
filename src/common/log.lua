-- Leveled logger shared by both drivers. Output goes through print(), which
-- the controller routes to Composer's Lua output window.

local log = {}

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4 }

local threshold = LEVELS.warn
local prefix = ""

-- Sink is swappable so tests can capture output.
log.sink = print

function log.set_prefix(value)
	prefix = value and (value .. ": ") or ""
end

-- Debug Mode property: "On" logs everything, anything else keeps warnings and errors.
function log.set_debug(enabled)
	threshold = enabled and LEVELS.debug or LEVELS.warn
end

function log.enabled(level)
	return LEVELS[level] <= threshold
end

local function emit(level, fmt, ...)
	if not log.enabled(level) then
		return
	end
	local ok, msg = pcall(string.format, fmt, ...)
	if not ok then
		msg = tostring(fmt)
	end
	log.sink(string.format("[%s] %s%s", level:upper(), prefix, msg))
end

-- For diagnostics the user asked for: shown whatever the level.
function log.always(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	log.sink(prefix .. (ok and msg or tostring(fmt)))
end

function log.error(fmt, ...) emit("error", fmt, ...) end
function log.warn(fmt, ...) emit("warn", fmt, ...) end
function log.info(fmt, ...) emit("info", fmt, ...) end
function log.debug(fmt, ...) emit("debug", fmt, ...) end

return log
