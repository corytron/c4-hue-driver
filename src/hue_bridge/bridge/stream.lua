-- The bridge's server-sent event stream (/eventstream/clip/v2).
--
-- Keeps one streaming GET open, parses events as chunks arrive, and hands
-- each Hue "container" to the owner. Reconnects with backoff whenever the
-- transfer ends, and a watchdog reconnects if nothing at all arrives for a
-- while. Every reconnect is reported through on_status so the owner can
-- resync state with a full GET. A 401 or 403 is the bridge refusing the
-- application key: every reconnect would present the same key, so the
-- stream stops for good instead and tells the owner once, through
-- on_key_rejected (issue #44).
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
--
-- The watchdog is one timer per connection, armed when the transfer starts
-- (so a transfer that never answers is restarted too) and again for a full
-- period when the headers arrive. Events and keepalive comments feed it: it
-- notes the clock instead of being cancelled and re-created per event (two
-- Director calls each). Bytes that make neither do not count, so a connected
-- stream that delivers nothing usable is restarted all the same [code
-- analysis 2026-10-22, L3]. When it fires it reconnects if nothing fed it
-- for the whole period, else it is re-armed for what remains of the period
-- after the last feed.
--
-- An abandoned transfer (a watchdog reconnect, an oversized line) is not
-- ended by Cancel() (rule 2): it lives on until its next callback, which
-- returns true. That callback's chunk is its last, and its events reach the
-- owner at most once [code analysis 2026-10-22, L1]:
--  * only that one chunk, should Director deliver more after the abort;
--  * only while the stream runs and its current transfer is not connected:
--    a connected transfer receives the same events itself, and the resync
--    after its connect covers anything older;
--  * and the current transfer skips an event an abandoned one delivered (the
--    same SSE id), which it carries too when it reached the bridge first.

local log = require("common.log")
local http = require("bridge.http")
local sse = require("bridge.sse")

local stream = {}
stream.__index = stream

stream.PATH = "/eventstream/clip/v2"
stream.DEFAULT_TIMEOUT = 3600       -- seconds; the transfer's total lifetime
stream.DEFAULT_WATCHDOG = 600       -- seconds of silence before reconnecting
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
--   on_status(text, per_event)      human-readable state for a property;
--                                   per_event is true for the per-container
--                                   rewrite (count and clock), so the owner
--                                   can coalesce those writes
--   on_connected()                  stream is up; resync state here
--   on_key_rejected(code)           the bridge answered the stream with 401 or
--                                   403; called once, after the stream has
--                                   stopped itself. It runs inside OnHeaders,
--                                   so it must not start a transfer (rule 1)
--
-- stats (all builds): containers, events, keepalives, reconnects (every
-- reconnect scheduled since stream.new), last_event, connected_since,
-- started (the clock text of the first connect since stream.new, kept across
-- reconnects), last_error, address.
function stream.new(opts)
	return setmetatable({
		opts = opts,
		state = "stopped",          -- stopped | connecting | connected | waiting
		generation = 0,
		transfer = nil,
		parser = nil,
		watchdog = nil,
		last_data = nil,            -- ms clock of the last event or keepalive, for the watchdog
		fed_since_arm = false,      -- an event or keepalive arrived since the watchdog was (re)armed
		connected_timer = nil,      -- defers on_connected out of OnHeaders
		retry_timer = nil,
		backoff = stream.BACKOFF_MIN,
		abandoned_ids = nil,        -- SSE ids an abandoned transfer delivered (see the header)
		stats = { containers = 0, events = 0, keepalives = 0, reconnects = 0,
			last_event = nil, connected_since = nil, last_error = nil,
			started = nil,          -- clock() of the first connect, kept across reconnects
			address = nil },        -- the address spelling the current/last transfer used
	}, stream)
end

local function clock()
	return os.date("%H:%M:%S")
end

-- Milliseconds (C4:GetTime, SDK 34_timer/_2-GetTime; OS 3.2.3 and later),
-- falling back to os.time() where it is missing.
local function c4_time()
	return C4:GetTime()
end

local function now_ms()
	local ok, ms = pcall(c4_time)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

function stream:status(text, per_event)
	if self.opts.on_status then
		self.opts.on_status(text, per_event)
	end
end

function stream:cancel_timer(name)
	if self[name] then
		self[name]:Cancel()
		self[name] = nil
	end
end

-- Arm the watchdog for the whole period, or for `delay_ms` (the remainder
-- of a period a chunk interrupted). See the header.
function stream:arm_watchdog(delay_ms)
	self:cancel_timer("watchdog")
	local seconds = self.opts.watchdog or stream.DEFAULT_WATCHDOG
	if seconds <= 0 then
		return
	end
	self.fed_since_arm = false
	local gen = self.generation
	self.watchdog = C4:SetTimer(delay_ms or seconds * 1000, function()
		if gen ~= self.generation then
			return
		end
		self.watchdog = nil
		if self.fed_since_arm then
			local remaining = seconds * 1000 - (now_ms() - (self.last_data or 0))
			if remaining > 0 then
				return self:arm_watchdog(remaining)
			end
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

-- Stop until the next start(): no reconnect. `text` is the status to show
-- (default "Stopped").
function stream:stop(text)
	self:cancel_timer("retry_timer")
	self:drop_transfer()
	self.state = "stopped"
	self.stats.connected_since = nil
	self.abandoned_ids = nil
	self:status(text or "Stopped")
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

	-- Armed now, not only when the headers arrive: a transfer that never
	-- answers is restarted after the watchdog period too (see the header).
	-- Before the transfer starts, so a start that fails at once (on_done -2)
	-- cancels it again.
	self:arm_watchdog()
	local last_chunk_seen = false -- this transfer's, once it is abandoned
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
				-- events in this chunk may reach the owner no other way (the
				-- replacement may still be connecting, or queued behind it).
				-- Deliver them at most once (see the header), then abort by
				-- returning true; any later chunk is dropped.
				if not last_chunk_seen then
					last_chunk_seen = true
					self:deliver_abandoned(parser, data)
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
	if code == 401 or code == 403 then
		return self:key_rejected(code)
	end
	if code ~= 200 then
		self.stats.last_error = "HTTP " .. tostring(code)
		log.warn("event stream: rejected with HTTP %s", tostring(code))
		return true -- abort; handle_done will run with err_code -1
	end
	self.state = "connected"
	self.backoff = stream.BACKOFF_MIN
	self.stats.connected_since = clock()
	self.stats.started = self.stats.started or self.stats.connected_since
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

-- The bridge refused the application key: a 401 or 403 on the stream
-- request. The house Bridge Pro answers an unknown key with 403 and an HTML
-- body [verified: hardware 2026-10-25, docs/review-leftovers-design.md #44];
-- a revoked key is an unknown key to it [assumed]. The stream stops for good
-- (no reconnect timer, until start()), says so, and tells the owner once.
-- This runs inside OnHeaders: the transfer ends by the true returned from
-- there, as every refused stream request always did (rule 2; SDK
-- 35_url/_9-OnHeaders), so it is not Cancel()ed from inside its own
-- callback, and the owner's callback is pcall'd so that true is returned
-- whatever it does.
function stream:key_rejected(code)
	self.stats.last_error = string.format("key rejected (HTTP %s)", tostring(code))
	log.warn("event stream: the bridge rejected the application key (HTTP %s); stopped, no reconnect",
		tostring(code))
	self.transfer = nil -- ended by the true returned below
	self:stop(string.format("Stopped: key rejected (HTTP %s)", tostring(code)))
	if self.opts.on_key_rejected then
		local ok, err = pcall(self.opts.on_key_rejected, code)
		if not ok then
			log.error("event stream: on_key_rejected failed: %s", tostring(err))
		end
	end
	return true
end

function stream:handle_chunk(data)
	local before = self.parser.comments
	local events = self.parser:feed(data)
	local keepalives = self.parser.comments - before
	self.stats.keepalives = self.stats.keepalives + keepalives
	-- Only an event or a keepalive feeds the watchdog (see the header), and
	-- before the events are handled, so an owner callback that raises cannot
	-- leave a live stream looking silent.
	if #events > 0 or keepalives > 0 then
		self.last_data = now_ms()
		self.fed_since_arm = true
	end
	for _, event in ipairs(events) do
		self:deliver(event)
	end
	if self.parser.overflowed then
		self.stats.last_error = "oversized line in stream"
		log.warn("event stream: oversized line, reconnecting")
		self:drop_transfer()
		self:schedule_reconnect()
	end
end

-- An event of the current transfer. One that an abandoned transfer already
-- delivered (the same id) is skipped, once; the first event that is not one
-- of those shows the current transfer is past them, and the list goes.
function stream:deliver(event)
	local seen = self.abandoned_ids
	if seen then
		if event.id and seen[event.id] then
			seen[event.id] = nil
			return
		end
		self.abandoned_ids = nil
	end
	self:handle_event(event)
end

-- The last chunk of an abandoned transfer (see the header), read with that
-- transfer's own parser. Its events reach the owner only while the stream
-- runs and its current transfer is not connected, and only those no other
-- abandoned transfer delivered before; their ids are kept for deliver().
function stream:deliver_abandoned(parser, data)
	if self.state == "stopped" or self.state == "connected" then
		return
	end
	for _, event in ipairs(parser:feed(data)) do
		local seen = self.abandoned_ids
		if not (event.id and seen and seen[event.id]) then
			if event.id then
				self.abandoned_ids = seen or {}
				self.abandoned_ids[event.id] = true
			end
			self:handle_event(event)
		end
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
	-- The per-event text only while connected: an abandoned transfer's last
	-- chunk can arrive while the current one is still connecting or waiting
	-- (it used to write "Connected since nil" then [code analysis 2026-10-22, L1]).
	if self.state == "connected" then
		self:status(string.format("Connected since %s, %d containers, last %s",
			tostring(self.stats.connected_since), self.stats.containers, self.stats.last_event), true)
	end
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
