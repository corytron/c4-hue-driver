-- The throttle of one Hue Light device's (single lamp, zone light or room
-- light) Hue-side level reports (#433 D12 to D15, docs/light-events-design.md
-- §6.4): a level that Hue reports while it moves (the Hue app's slider, a Hue
-- dimmer switch, a Hue automation) reaches the proxy as at most one
-- LIGHT_BRIGHTNESS_CHANGED per window, and the last one is exact. Row L7 of
-- docs/c4-lighting-guidelines.md: no flood of intermediate levels.
--
-- The pattern is the Hue Scene device's (src/hue_scene/driver.lua, its
-- level window), leading and trailing: with no window open, a report goes
-- out at once and opens a window; a report inside the window only marks it;
-- when the window ends marked, the level the proxy should show then goes out
-- if it differs from the last one sent, and a new window opens.
--
-- The driver decides which reports come here (D12): only a HUE_STATE with
-- reason "event" whose only brightness change is a level. On and off edges,
-- a report that settles a Control4 target and full states go out at once,
-- and the driver then calls open(). Every LIGHT_BRIGHTNESS_CHANGING calls
-- close() (D13), and every LIGHT_BRIGHTNESS_CHANGED, the trailing one this
-- module asks for included, calls sent(level) (D14).
--
-- Pure Lua. The timers come from C4:SetTimer [verified: API
-- 34_timer/_1-SetTimer.md: the delay in ms and a callback, a timer object
-- with Cancel()], looked up when a window opens, so the C4 of that moment
-- arms it. The module holds no state outside the objects it returns.
--
--   local levels = throttle.new({
--   	ms = 1000,                    -- the window, LEVEL_REPORT_MS
--   	current = function() ... end, -- the level the proxy should show now (0-100), nil when unknown
--   	send = function() ... end,    -- send LIGHT_BRIGHTNESS_CHANGED; it must call levels:sent(level)
--   })
--   levels:sent(level)   -- a LIGHT_BRIGHTNESS_CHANGED went out with `level`
--   levels:edge(level)   -- true when nothing was sent yet, or `level` and the last sent differ in being 0
--   levels:report()      -- throttled: send now and open the window, or mark the open window
--   levels:open()        -- (re)start the window after an immediate report
--   levels:close()       -- drop the window and any pending trailing report
--   levels.last          -- the last level sent, nil before the first

local throttle = {}

-- The window when new() is given none: LEVEL_REPORT_MS of the scene and of
-- the light (#433 D12).
throttle.DEFAULT_MS = 1000

local Levels = {}
Levels.__index = Levels

-- Whether the level the proxy should show now is one to send: known, and
-- not the last one sent.
local function differs(self)
	local level = self.current()
	return level ~= nil and level ~= self.last
end

function Levels:sent(level)
	self.last = level
end

-- An on or off edge (#433 D12): the first report of all, or one where
-- exactly one of `level` and the last level sent is 0.
function Levels:edge(level)
	if self.last == nil then
		return true
	end
	return (level == 0) ~= (self.last == 0)
end

-- No window any more, and so no trailing report (#433 D13). A timer that
-- fires after its Cancel finds its window gone and does nothing.
function Levels:close()
	local w = self.window
	self.window = nil
	if w and w.timer then
		w.timer:Cancel()
	end
end

-- A new window of `ms` from now, unmarked; an open one is dropped first.
function Levels:open()
	self:close()
	local w = { marked = false }
	self.window = w
	w.timer = C4:SetTimer(self.ms, function()
		if self.window ~= w then
			return
		end
		self.window = nil
		if w.marked and differs(self) then
			self.send()
			self:open()
		end
	end)
end

-- A Hue-side level report: inside the window it only marks the window;
-- outside, the level goes out at once when it is not the last one sent,
-- and only then a window opens.
function Levels:report()
	if self.window then
		self.window.marked = true
	elseif differs(self) then
		self.send()
		self:open()
	end
end

-- opts = { ms, current, send }, see the top of this file.
function throttle.new(opts)
	opts = opts or {}
	assert(type(opts.current) == "function", "throttle.new: current must be a function")
	assert(type(opts.send) == "function", "throttle.new: send must be a function")
	local ms = tonumber(opts.ms) or throttle.DEFAULT_MS
	assert(ms > 0, "throttle.new: ms must be above 0")
	return setmetatable({
		ms = ms,
		current = opts.current,
		send = opts.send,
		last = nil,    -- the last level sent (sent())
		window = nil,  -- { timer, marked } while a window is open
	}, Levels)
end

return throttle
