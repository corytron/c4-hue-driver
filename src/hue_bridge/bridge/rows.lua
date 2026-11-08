-- The bridge driver's owner-facing Composer rows (#373: moved out of
-- hue_bridge/driver.lua, whose main chunk had reached 199 of Lua 5.1's 200
-- locals). Four kinds of row, each written the way Composer showed it best:
--
--   local r = rows.new()
--   r:prop(name, value)           a plain row, now (nil reads ""); wins over
--                                 a value r:prop_soon still holds back
--   r:prop_soon(name, value)      a row the event stream rewrites per event:
--                                 at most one write a second (below)
--   r:stop()                      OnDriverDestroyed: prop_soon's timer cancelled
--   r:list(name, summary, items)  a list row (DYNAMIC_LIST): the summary on
--                                 the row, every item on a line of the
--                                 drop-down; sent only when the list changed
--   r:list_moved(name, value)     a pick in Composer moved the row off its
--                                 summary: true, and the next r:list sends again
--   r:list_reset(name)            the next r:list of `name` sends again
--   r:wrapped(name, opts) -> w    a text word-wrapped onto `name` and its
--                                 continuation rows "<name> (2)" ... (below)
--   rows.commaless(text)          a text fit for a comma-delimited list
--   rows.wrap(text, width)        the lines word-wrapping `text` makes
--
-- prop_soon (`Events Received`, `Last Event`, `Event Stream`): a row's first
-- value of a burst is written at once, its latest when the one-shot timer
-- fires a second later (so the final value always lands), and the timer
-- stays armed while values keep coming.
--
-- List rows (`Room Mappings`, `Lights`, `Scenes`, `Zone Lights`, `Motion
-- Sensors`, `Bridges Found`): Composer clips a value at about 75 characters,
-- so the row shows a summary and the drop-down every item on a line of its
-- own. The list is comma-delimited, so a comma in any text becomes "‚". A
-- pick in Composer changes nothing: the row snaps back to the summary
-- (r:list remembers it, and only a value that left it is reset, so this
-- cannot loop).
--
-- Wrapped rows (`Attention`, `Last Action`, #68): Composer's value column
-- holds about 75 characters and does not wrap, so a long text is
-- word-wrapped onto the row and its continuation rows; rows not in use are
-- hidden (SetPropertyAttribs 1). Composer dropped a show (build 243) and a
-- hide (build 245) that arrived in the same burst as the rows' text updates
-- [hardware 2026-10-24], so the visibility goes out as one batch 400 ms
-- after the texts and once more at 1.5 s; nothing depends on what was shown
-- before.
--
--   w = r:wrapped(name, { rows = 6, width = 72, empty = "", on_overflow = fn(text) })
--     rows, width   how many rows (the first included) and characters a row
--     empty         what the first row shows for an empty text
--     on_overflow   called with the whole text, before the rows are
--                   written, when it needs more rows than there are (the
--                   last row then ends in " … (Lua output)")
--   w:show(text)    the text onto the rows
--   w:settle(properties)
--                   late init: continuation rows that still hold text from
--                   before the restart stay shown, the empty ones are hidden
--   w:cancel()      the visibility timer cancelled
--
-- DriverWorks calls: C4:UpdateProperty, C4:UpdatePropertyList (SDK
-- 24_properties/_6-UpdatePropertyList), C4:SetPropertyAttribs, C4:SetTimer.

local rows = {}
rows.__index = rows

rows.SOON_MS = 1000
rows.WRAP_ROWS, rows.WRAP_WIDTH = 6, 72

function rows.new()
	return setmetatable({
		soon_pending = {},   -- name -> the latest value, waiting for the timer
		soon_written = {},   -- name -> true once written in the current second
		soon_timer = nil,
		summaries = {},      -- list row name -> the summary it was given
		sent = {},           -- list row name -> the list last sent
	}, rows)
end

function rows:prop(name, value)
	self.soon_pending[name] = nil
	C4:UpdateProperty(name, tostring(value == nil and "" or value))
end

function rows:flush_soon()
	self.soon_timer = nil
	local pending = self.soon_pending
	self.soon_pending, self.soon_written = {}, {}
	if next(pending) == nil then
		return
	end
	for name, value in pairs(pending) do
		self.soon_written[name] = true
		self:prop(name, value)
	end
	self.soon_timer = C4:SetTimer(rows.SOON_MS, function() self:flush_soon() end)
end

function rows:prop_soon(name, value)
	if self.soon_written[name] then
		self.soon_pending[name] = value
	else
		self.soon_written[name] = true
		self:prop(name, value)
	end
	if not self.soon_timer then
		self.soon_timer = C4:SetTimer(rows.SOON_MS, function() self:flush_soon() end)
	end
end

function rows:stop()
	if self.soon_timer then
		self.soon_timer:Cancel()
		self.soon_timer = nil
	end
end

function rows.commaless(text)
	return (tostring(text == nil and "" or text):gsub("%c", ""):gsub(",", "‚"))
end

-- A list property: the drop-down holds `items`, `value` is what the row
-- shows. Comma-delimited (SDK 24_properties/_6-UpdatePropertyList); the
-- list's default alone did not move the row after a pick in Composer (build
-- 184), so the value is set as well.
local function update_list(name, items, value)
	C4:UpdatePropertyList(name, table.concat(items, ","), value)
	C4:UpdateProperty(name, value)
end

function rows:list(name, summary, items)
	summary = rows.commaless(summary)
	local list = { summary }
	for _, item in ipairs(items or {}) do
		list[#list + 1] = rows.commaless(item)
	end
	self.summaries[name] = summary
	-- Director and Composer are told only when the list changed (the lists
	-- are rebuilt at every refresh); a pick clears the memory first.
	local joined = table.concat(list, ",")
	if self.sent[name] ~= joined then
		self.sent[name] = joined
		update_list(name, list, summary)
	end
end

function rows:list_moved(name, value)
	local summary = self.summaries[name]
	if summary ~= nil and value ~= summary then
		self.sent[name] = nil
		return true
	end
	return false
end

function rows:list_reset(name)
	self.sent[name] = nil
end

function rows.wrap(text, width)
	local lines, line = {}, ""
	for word in text:gmatch("%S+") do
		while #word > width do
			if line ~= "" then
				lines[#lines + 1] = line
				line = ""
			end
			lines[#lines + 1] = word:sub(1, width)
			word = word:sub(width + 1)
		end
		if line == "" then
			line = word
		elseif #line + 1 + #word <= width then
			line = line .. " " .. word
		else
			lines[#lines + 1] = line
			line = word
		end
	end
	if line ~= "" then
		lines[#lines + 1] = line
	end
	return lines
end

local function row_visible(name, visible)
	if C4.SetPropertyAttribs then
		pcall(C4.SetPropertyAttribs, C4, name, visible and 0 or 1)
	end
end

local wrapped = {}
wrapped.__index = wrapped

function rows:wrapped(name, opts)
	opts = opts or {}
	return setmetatable({
		rows = self,
		name = name,
		count = opts.rows or rows.WRAP_ROWS,
		width = opts.width or rows.WRAP_WIDTH,
		empty = opts.empty or "",
		on_overflow = opts.on_overflow,
		shown = {},   -- continuation row index -> true while the row holds text
		timer = nil,
	}, wrapped)
end

function wrapped:row(i)
	return string.format("%s (%d)", self.name, i)
end

-- Every continuation row's visibility, asserted in full.
function wrapped:assert_rows()
	for i = 2, self.count do
		row_visible(self:row(i), self.shown[i] == true)
	end
end

function wrapped:assert_soon()
	if self.timer then
		self.timer:Cancel()
	end
	self.timer = C4:SetTimer(400, function()
		self:assert_rows()
		self.timer = C4:SetTimer(1500, function()
			self.timer = nil
			self:assert_rows()
		end)
	end)
end

function wrapped:show(text)
	local lines = rows.wrap(text, self.width)
	if #lines > self.count then
		if self.on_overflow then
			self.on_overflow(text)
		end
		lines[self.count] = lines[self.count]:sub(1, self.width - 16) .. " … (Lua output)"
	end
	self.rows:prop(self.name, lines[1] or self.empty)
	for i = 2, self.count do
		self.rows:prop(self:row(i), lines[i] or "")
		self.shown[i] = lines[i] ~= nil
	end
	self:assert_soon()
end

function wrapped:settle(properties)
	for i = 2, self.count do
		local value = properties and properties[self:row(i)] or ""
		self.shown[i] = value ~= ""
	end
	self:assert_rows()
	self:assert_soon()
end

function wrapped:cancel()
	if self.timer then
		self.timer:Cancel()
		self.timer = nil
	end
end

return rows
