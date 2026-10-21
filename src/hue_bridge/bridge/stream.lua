-- The bridge's server-sent event stream (/eventstream/clip/v2).
--
-- Keeps one streaming GET open, parses events as chunks arrive, and hands
-- each Hue "container" to the owner. Reconnects with backoff whenever the
-- transfer ends, and a watchdog reconnects if nothing at all arrives for a
-- while. Every reconnect is reported through on_status so the owner can
-- resync state with a full GET.
--
-- Two rules, both from the spike on OS 3.4.2 (docs/design.md, Event stream):
--
-- 1. on_container and on_connected run inside C4:url callbacks (OnBodyChunk,
--    OnHeaders). A C4:url transfer started from inside OnHeaders fails at
--    once with curl error 2 "Failed initialization", so never start a
--    transfer from those callbacks without deferring it. on_connected is
--    already deferred to a 1 ms C4:SetTimer here, so the owner's resync GET
--    is safe; anything the owner starts from on_container must defer the same
--    way.
-- 2. C4LuaUrl:Cancel() does not stop an active streaming transfer: chunks keep
--    arriving until the transfer's total timeout. Returning true from the next
--    OnHeaders/OnBodyChunk callback does abort it, which is what the
--    generation check at the top of every callback does for an abandoned
--    transfer. drop_transfer still calls Cancel() for the case where it works.

local log = require("common.log")
local http = require("bridge.http")
local sse = require("bridge.sse")

local stream = {}
stream.__index = stream

stream.PATH = "/eventstream/clip/v2"
stream.DEFAULT_TIMEOUT = 3600       -- seconds; the transfer's total lifetime
stream.DEFAULT_WATCHDOG = 300       -- seconds of silence before reconnecting
stream.BACKOFF_MIN = 1              -- seconds
stream.BACKOFF_MAX = 60

-- opts:
--   connection()    returns { ip, key, stream_ip } or nil when not paired;
--                   stream_ip (optional) is the address spelling the stream
--                   uses so that it has its own C4:url queue (bridge/altaddr).
--                   Called again for every connection attempt, so the owner
--                   may return a different stream_ip each time: the driver
--                   rotates over altaddr.stream_family so a new transfer never
--                   queues behind the abandoned one (docs/design.md, Stream
--                   address rotation)
--   timeout         seconds, see DEFAULT_TIMEOUT
--   watchdog        seconds, see DEFAULT_WATCHDOG
--   on_container(container, event)  one Hue event container (type, data, ...)
--   on_status(text)                 human-readable state for a property
--   on_connected()                  stream is up; resync state here
function stream.new(opts)
	return setmetatable({
		opts = opts,
		state = "stopped",          -- stopped | connecting | connected | waiting
		generation = 0,
		transfer = nil,
		parser = nil,
		watchdog = nil,
		connected_timer = nil,      -- defers on_connected out of OnHeaders
		retry_timer = nil,
		backoff = stream.BACKOFF_MIN,
		stats = { containers = 0, events = 0, keepalives = 0, reconnects = 0,
			last_event = nil, connected_since = nil, last_error = nil,
			address = nil },        -- the address spelling the current/last transfer used
	}, stream)
end

local function clock()
	return os.date("%H:%M:%S")
end

function stream:status(text)
	if self.opts.on_status then
		self.opts.on_status(text)
	end
end

function stream:cancel_timer(name)
	if self[name] then
		self[name]:Cancel()
		self[name] = nil
	end
end

function stream:arm_watchdog()
	self:cancel_timer("watchdog")
	local seconds = self.opts.watchdog or stream.DEFAULT_WATCHDOG
	if seconds <= 0 then
		return
	end
	local gen = self.generation
	self.watchdog = C4:SetTimer(seconds * 1000, function()
		if gen ~= self.generation then
			return
		end
		log.warn("event stream: no data for %d s, reconnecting", seconds)
		self.stats.last_error = "watchdog: no data for " .. seconds .. " s"
		self:drop_transfer()
		self:schedule_reconnect()
	end)
end

-- Abandon the current transfer. Any late callbacks from it are aborted (they
-- return true) because the generation has moved on; Cancel() alone is not
-- enough, see rule 2 above.
function stream:drop_transfer()
	self.generation = self.generation + 1
	self:cancel_timer("watchdog")
	self:cancel_timer("connected_timer")
	if self.transfer then
		self.transfer:Cancel()
		self.transfer = nil
	end
end

function stream:start()
	self:cancel_timer("retry_timer")
	if self.state == "connecting" or self.state == "connected" then
		return
	end
	self:connect()
end

function stream:stop()
	self:cancel_timer("retry_timer")
	self:drop_transfer()
	self.state = "stopped"
	self.stats.connected_since = nil
	self:status("Stopped")
end

function stream:running()
	return self.state ~= "stopped"
end

function stream:connect()
	local conn = self.opts.connection()
	if not conn then
		self.state = "stopped"
		self:status("Not paired")
		return
	end

	self:drop_transfer()
	local gen = self.generation
	self.state = "connecting"
	self.parser = sse.new()
	local parser = self.parser -- this connection's own parser, for its late chunks
	self:status("Connecting")
	local host = conn.stream_ip or conn.ip -- a second spelling keeps commands unblocked
	self.stats.address = host
	if host ~= conn.ip then
		log.info("event stream: connecting to %s via %s", conn.ip, host)
	else
		log.info("event stream: connecting to %s", conn.ip)
	end

	self.transfer = http.stream({
		ip = host,
		key = conn.key,
		path = stream.PATH,
		headers = { Accept = "text/event-stream" },
		timeout = self.opts.timeout or stream.DEFAULT_TIMEOUT,
	}, {
		on_headers = function(code)
			if gen ~= self.generation then return true end
			return self:handle_headers(code)
		end,
		on_chunk = function(data)
			if gen ~= self.generation then
				-- An abandoned transfer: Cancel() did not end it, and the
				-- replacement stream is queued behind it, so the events in
				-- this chunk would otherwise be lost. Deliver them, then abort
				-- by returning true.
				if self.state ~= "stopped" then
					for _, event in ipairs(parser:feed(data)) do
						self:handle_event(event)
					end
				end
				return true
			end
			self:handle_chunk(data)
		end,
		on_done = function(err_code, err_msg, code)
			if gen ~= self.generation then return end
			self:handle_done(err_code, err_msg, code)
		end,
	})
end

function stream:handle_headers(code)
	if code ~= 200 then
		self.stats.last_error = "HTTP " .. tostring(code)
		log.warn("event stream: rejected with HTTP %s", tostring(code))
		return true -- abort; handle_done will run with err_code -1
	end
	self.state = "connected"
	self.backoff = stream.BACKOFF_MIN
	self.stats.connected_since = clock()
	self:arm_watchdog()
	self:status("Connected since " .. self.stats.connected_since)
	-- Deferred: this runs inside OnHeaders, and the owner issues a resync GET
	-- from on_connected, which would fail if started here (rule 1 above).
	self:cancel_timer("connected_timer")
	if self.opts.on_connected then
		local gen = self.generation
		self.connected_timer = C4:SetTimer(1, function()
			self.connected_timer = nil
			if gen ~= self.generation then
				return
			end
			self.opts.on_connected()
		end)
	end
	return false
end

function stream:handle_chunk(data)
	self:arm_watchdog()
	local before = self.parser.comments
	for _, event in ipairs(self.parser:feed(data)) do
		self:handle_event(event)
	end
	self.stats.keepalives = self.stats.keepalives + (self.parser.comments - before)
	if self.parser.overflowed then
		self.stats.last_error = "oversized line in stream"
		log.warn("event stream: oversized line, reconnecting")
		self:drop_transfer()
		self:schedule_reconnect()
	end
end

function stream:handle_event(event)
	self.stats.events = self.stats.events + 1
	self.stats.last_event = clock()
	local containers, err = http.decode(event.data)
	if type(containers) ~= "table" then
		log.warn("event stream: undecodable event %s: %s", tostring(event.id), tostring(err))
		return
	end
	for _, container in ipairs(containers) do
		self.stats.containers = self.stats.containers + 1
		if log.enabled("debug") then
			local types = {}
			for _, item in ipairs(container.data or {}) do
				types[#types + 1] = tostring(item.type)
			end
			log.debug("event %s %s: %s", tostring(event.id), tostring(container.type), table.concat(types, ","))
		end
		if self.opts.on_container then
			self.opts.on_container(container, event)
		end
	end
	self:status(string.format("Connected since %s, %d containers, last %s",
		tostring(self.stats.connected_since), self.stats.containers, self.stats.last_event))
end

function stream:handle_done(err_code, err_msg, code)
	self.transfer = nil
	self:cancel_timer("watchdog")
	self:cancel_timer("connected_timer") -- the stream ended before it fired
	local reason
	if err_code == -1 then
		reason = self.stats.last_error or "aborted"
	elseif err_code ~= 0 then
		reason = string.format("transfer error %d: %s", err_code, tostring(err_msg))
	else
		reason = string.format("server closed the stream (HTTP %s)", tostring(code))
	end
	self.stats.last_error = reason
	log.info("event stream ended: %s", reason)
	self:schedule_reconnect()
end

function stream:schedule_reconnect()
	if self.state == "stopped" then
		return
	end
	self.state = "waiting"
	self.stats.connected_since = nil
	self.stats.reconnects = self.stats.reconnects + 1
	local delay = self.backoff
	self.backoff = math.min(self.backoff * 2, stream.BACKOFF_MAX)
	self:status(string.format("Disconnected: %s. Reconnecting in %d s", tostring(self.stats.last_error), delay))
	self:cancel_timer("retry_timer")
	self.retry_timer = C4:SetTimer(delay * 1000, function()
		self.retry_timer = nil
		if self.state == "waiting" then
			self:connect()
		end
	end)
end

return stream
