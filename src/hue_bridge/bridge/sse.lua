-- Incremental parser for a server-sent-events stream (text/event-stream).
-- Feed it the body chunks as they arrive; it returns the complete events.
-- Pure Lua, no C4 calls.
--
--   local p = sse.new()
--   for _, ev in ipairs(p:feed(chunk)) do print(ev.id, ev.data) end
--
-- An event is { id = string|nil, event = string|nil, data = string }.
-- Comment lines (":keepalive") are counted but produce no event, so a
-- caller can still treat them as signs of life.

local sse = {}
sse.__index = sse

-- A single line longer than this means we're not reading an event stream.
sse.MAX_LINE = 1024 * 1024

function sse.new()
	return setmetatable({
		buffer = "",
		id = nil,
		event = nil,
		data = {},
		comments = 0,
		overflowed = false,
	}, sse)
end

local function reset_event(self)
	self.event = nil
	self.data = {}
end

function sse:dispatch(out)
	-- Per the spec, a blank line with no data lines is not an event.
	if #self.data == 0 then
		reset_event(self)
		return
	end
	table.insert(out, {
		id = self.id,
		event = self.event,
		data = table.concat(self.data, "\n"),
	})
	reset_event(self)
end

function sse:line(text, out)
	if text == "" then
		self:dispatch(out)
		return
	end
	if text:sub(1, 1) == ":" then
		self.comments = self.comments + 1
		return
	end
	local field, value = text:match("^([^:]*):%s?(.*)$")
	if not field then
		field, value = text, ""
	end
	if field == "data" then
		table.insert(self.data, value)
	elseif field == "id" then
		-- Hue ids look like "1634576695:0"; keep the whole thing.
		self.id = value
	elseif field == "event" then
		self.event = value
	end
	-- "retry" and unknown fields are ignored.
end

-- Returns an array of the events completed by this chunk. The buffer is
-- walked by position and cut once at the end, not once per line (a chunk
-- used to be copied about as many times as it had lines).
function sse:feed(chunk)
	local out = {}
	local buffer = self.buffer .. chunk
	local pos = 1
	while true do
		local nl = buffer:find("\n", pos, true)
		if not nl then
			break
		end
		local text = buffer:sub(pos, nl - 1)
		pos = nl + 1
		if text:sub(-1) == "\r" then
			text = text:sub(1, -2)
		end
		self:line(text, out)
	end
	self.buffer = pos > 1 and buffer:sub(pos) or buffer
	if #self.buffer > sse.MAX_LINE then
		self.overflowed = true
		self.buffer = ""
		reset_event(self)
	end
	return out
end

return sse
