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
-- An abandoned transfer (a watchdog reconnect, a stop, a rebuild of the
-- stream by its owner) is not ended by Cancel() (rule 2): it lives on until
-- its next callback, which returns true. That callback's chunk is its last,
-- and its events reach the owner at most once [code analysis 2026-10-22, L1]:
--  * only that one chunk, should Director deliver more after the abort;
--  * only while the stream runs and its current transfer is not connected:
--    a connected transfer receives the same events itself, and the resync
--    after its connect covers anything older;
--  * and the current transfer skips an event an abandoned one delivered (the
--    same SSE id), which it carries too when it reached the bridge first.
--
-- Events are decoded and handed to the owner inside OnBodyChunk, each one
-- under pcall: an event that raises (an owner callback, a container no
-- bridge would send) costs that event and one warning per chunk, never the
-- rest of the chunk or the overflow check after it. What Director does with
-- an error raised in a C4:url callback is not documented [assumed: logged,
-- and the transfer continues] [security review 2026-10-25, finding 6].

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

-- Director runs at most four C4:url transfers at once: on 2026-10-25 (OS
-- 3.4.2, dev build 276) three abandoned stream transfers plus the live one
-- were open and every other transfer, to the bridge and to another host
-- alike, timed out until a bridge event let the abandoned ones abort
-- [verified: hardware, docs/design.md "Concurrent transfers"]. An abandoned
-- transfer stays open until its next callback or its own timeout (rule 2),
-- and the bridge sends no keepalive, so in a quiet house every watchdog
-- reconnect used to leave one more open. So the stream keeps at most
-- MAX_ABANDONED + 1 of its transfers open, live and abandoned together: two,
-- which leaves two for commands. Every new transfer waits while that many
-- may still be open (connect, whatever led there: a reconnect, a stop and a
-- start, a rebuild by the owner, an address change), showing WAITING; the
-- watchdog, which abandons a live transfer before it opens the next, goes
-- ahead only while fewer than MAX_ABANDONED abandoned ones may be open
-- [security review 2026-10-25, finding 5]. The list is shared by the
-- stream objects an owner rebuilds (opts.abandoned).
stream.MAX_ABANDONED = 1

-- The status while a new transfer waits for an earlier one to close.
stream.WAITING = "Waiting for an earlier stream transfer to close"

-- opts:
--   connection()    returns { ip, key, stream_ip }, or nil and optionally a
--                   reason when the stream may not connect: the reason is the
--                   status to show (a full text, such as "Not connected: key
--                   rejected"), "Not paired" when there is none. The stream
--                   then stops (no transfer, no retry) until start();
--                   stream_ip (optional) is the address spelling the stream
--                   uses so that it has its own C4:url queue (bridge/altaddr).
--                   Called again for every transfer the stream opens (not
--                   while it waits for an earlier one to close, see connect),
--                   so the owner may return a different stream_ip each time:
--                   the driver rotates over altaddr.stream_family so a new
--                   transfer never queues behind the abandoned one
--                   (docs/design.md, Stream address rotation)
--   timeout         seconds, see DEFAULT_TIMEOUT
--   watchdog        seconds, see DEFAULT_WATCHDOG
--   on_container(container, event)  one Hue event container (type, data, ...)
--   on_status(text, per_event)      human-readable state for a property;
--                                   per_event is true for the per-container
--                                   rewrite (count and clock), so the owner
--                                   can coalesce those writes
--   on_connected()                  stream is up; resync state here
--   abandoned       a list shared by successive stream objects (the driver
--                   rebuilds the stream on a property change): the abandoned
--                   transfers that may still be open, { gen, owner, expires_ms }
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
		hold_backoff = false,       -- an oversized line ended a transfer: keep the backoff (handle_headers)
		cap_waiting = false,        -- connect() is waiting for an earlier transfer to close (wait_for_close)
		abandoned = opts.abandoned or {}, -- see MAX_ABANDONED
		transfer_expires_ms = nil,  -- when the current transfer's own timeout ends it
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

-- The abandoned transfers that may still be open: those whose own timeout
-- has not passed and that have not called back since (a callback aborts
-- them, see connect). Expired ones are pruned.
function stream:open_abandoned()
	local now, kept = now_ms(), {}
	for _, z in ipairs(self.abandoned) do
		if z.expires_ms > now then
			kept[#kept + 1] = z
		end
	end
	for i = #self.abandoned, 1, -1 do
		self.abandoned[i] = nil
	end
	for i, z in ipairs(kept) do
		self.abandoned[i] = z
	end
	return #kept
end

-- An abandoned transfer called back (and is aborted by its answer): it is
-- no longer open.
function stream:forget_abandoned(gen)
	for i = #self.abandoned, 1, -1 do
		local z = self.abandoned[i]
		if z.owner == self and z.gen == gen then
			table.remove(self.abandoned, i)
		end
	end
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
		local open = self:open_abandoned()
		if open >= stream.MAX_ABANDONED then
			-- A quiet house, most likely: the transfer that the previous
			-- watchdog abandoned is still open too. Another one would bring
			-- Director towards its four-transfer limit and stall commands.
			log.info("event stream: no data for %d s; not reconnecting while %d earlier transfer(s) may still be "
				.. "open (Director runs at most four at once)", seconds, open)
			return self:arm_watchdog()
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
		-- Cancel() does not end a streaming transfer (rule 2): it stays open
		-- until its next callback or its own timeout.
		self.abandoned[#self.abandoned + 1] = { gen = self.generation - 1, owner = self,
			expires_ms = self.transfer_expires_ms or (now_ms() + (self.opts.timeout or stream.DEFAULT_TIMEOUT) * 1000) }
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
	self.cap_waiting = false
	self.stats.connected_since = nil
	self.abandoned_ids = nil
	self:status(text or "Stopped")
end

function stream:running()
	return self.state ~= "stopped"
end

function stream:connect()
	self:drop_transfer()
	-- The cap (see MAX_ABANDONED) before connection(): the owner picks and
	-- persists the next address spelling there, which must move on only for
	-- a transfer that opens (bridge/altaddr, the driver's rotation).
	local open = self:open_abandoned()
	if open >= stream.MAX_ABANDONED + 1 then
		return self:wait_for_close(open)
	end
	self.cap_waiting = false

	local conn, reason = self.opts.connection()
	if not conn then
		self.state = "stopped"
		self:status(reason or "Not paired")
		return
	end

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
	self.transfer_expires_ms = now_ms() + (self.opts.timeout or stream.DEFAULT_TIMEOUT) * 1000
	local last_chunk_seen = false -- this transfer's, once it is abandoned
	self.transfer = http.stream({
		ip = host,
		key = conn.key,
		path = stream.PATH,
		headers = { Accept = "text/event-stream" },
		timeout = self.opts.timeout or stream.DEFAULT_TIMEOUT,
	}, {
		on_headers = function(code)
			if gen ~= self.generation then
				self:forget_abandoned(gen)
				return true
			end
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
				self:forget_abandoned(gen)
				return true
			end
			return self:handle_chunk(data)
		end,
		on_done = function(err_code, err_msg, code)
			if gen ~= self.generation then
				return self:forget_abandoned(gen)
			end
			self:handle_done(err_code, err_msg, code)
		end,
	})
end

-- Too many stream transfers may still be open (see MAX_ABANDONED): open
-- none, say so, and look again after the current backoff. The wait ends
-- once an abandoned transfer calls back (it is aborted then and forgotten,
-- see connect) or its own timeout passes (open_abandoned prunes it), at the
-- latest the Stream Timeout after it was opened, when Director ends it
-- itself; stop() ends the wait at once and leaves no timer.
function stream:wait_for_close(open)
	self.state = "waiting"
	self.stats.connected_since = nil
	local delay = self:next_delay()
	-- At info once per wait, the retries that follow at debug.
	local note = self.cap_waiting and log.debug or log.info
	note("event stream: %d earlier stream transfer(s) may still be open (Director runs at most four C4:url "
		.. "transfers at once); opening none, next try in %d s", open, delay)
	self.cap_waiting = true
	self:status(stream.WAITING)
	self:retry_in(delay)
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
	-- A connection resets the backoff, except after a transfer that ended in
	-- an oversized line: a peer that answers 200 and then overflows would be
	-- reconnected every second otherwise. The doubled backoff stays until a
	-- transfer delivers an event normally (handle_chunk) [security review
	-- 2026-10-25, finding 5].
	if not self.hold_backoff then
		self.backoff = stream.BACKOFF_MIN
	end
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

-- Hand each event to fn(self, event) under pcall (see the header): one that
-- raises is skipped, the rest of the chunk is delivered, and the caller's
-- checks after the loop still run. One warning per chunk. With `gen`, the
-- delivery ends once the generation moves on (an owner callback stopped or
-- rebuilt the stream: the rest belongs to a transfer it gave up). Returns
-- how many events fn reported as delivered normally (a true result).
local function deliver_each(self, events, fn, gen)
	local normal, failed, first = 0, 0, nil
	for _, event in ipairs(events) do
		if gen and gen ~= self.generation then
			break
		end
		local ok, result = pcall(fn, self, event)
		if not ok then
			failed = failed + 1
			first = first or result
		elseif result then
			normal = normal + 1
		end
	end
	if failed > 0 then
		log.warn("event stream: %d of %d event(s) in a chunk raised an error and were skipped; the first: %s",
			failed, #events, tostring(first))
	end
	return normal
end

-- A chunk of the current transfer. Returns true to abort the transfer.
function stream:handle_chunk(data)
	-- This transfer's own parser and generation: an owner callback below may
	-- stop or rebuild the stream.
	local parser, gen = self.parser, self.generation
	local before = parser.comments
	local events = parser:feed(data)
	local keepalives = parser.comments - before
	self.stats.keepalives = self.stats.keepalives + keepalives
	-- Only an event or a keepalive feeds the watchdog (see the header), and
	-- before the events are handled, so an owner callback that raises cannot
	-- leave a live stream looking silent.
	if #events > 0 or keepalives > 0 then
		self.last_data = now_ms()
		self.fed_since_arm = true
	end
	local normal = deliver_each(self, events, stream.deliver, gen)
	if gen ~= self.generation then
		-- An owner callback stopped or rebuilt the stream: whatever gave this
		-- transfer up counted it as abandoned, and like any abandoned one it
		-- is aborted by its callback's answer.
		return true
	end
	if parser.overflowed then
		self.stats.last_error = "oversized line in stream"
		log.warn("event stream: oversized line; transfer aborted, reconnecting")
		self.hold_backoff = true
		self:drop_transfer()
		self:schedule_reconnect()
		-- Aborted here rather than left open until its timeout: Cancel()
		-- does not end a streaming transfer (rule 2), a true returned from
		-- OnBodyChunk does [verified: SDK 35_url/_7-OnBodyChunk; hardware,
		-- rule 2]. drop_transfer counted it as abandoned until then; its
		-- OnDone (errCode -1, SDK 35_url/_8-OnDone) forgets it.
		return true
	end
	if normal > 0 and self.hold_backoff then
		self.hold_backoff = false
		self.backoff = stream.BACKOFF_MIN
	end
	return false
end

-- An event of the current transfer. One that an abandoned transfer already
-- delivered (the same id) is skipped, once; the first event that is not one
-- of those shows the current transfer is past them, and the list goes.
-- Returns true when the event was delivered normally (handle_event).
function stream:deliver(event)
	local seen = self.abandoned_ids
	if seen then
		if event.id and seen[event.id] then
			seen[event.id] = nil
			return false
		end
		self.abandoned_ids = nil
	end
	return self:handle_event(event)
end

-- The last chunk of an abandoned transfer (see the header), read with that
-- transfer's own parser. Its events reach the owner only while the stream
-- runs and its current transfer is not connected, and only those no other
-- abandoned transfer delivered before; their ids are kept for deliver().
function stream:deliver_abandoned(parser, data)
	if self.state == "stopped" or self.state == "connected" then
		return
	end
	deliver_each(self, parser:feed(data), stream.deliver_late)
end

-- One event of that last chunk (deliver_abandoned). The state is checked
-- again for each event: an owner callback may have stopped the stream.
function stream:deliver_late(event)
	if self.state == "stopped" or self.state == "connected" then
		return false
	end
	local seen = self.abandoned_ids
	if event.id and seen and seen[event.id] then
		return false
	end
	if event.id then
		self.abandoned_ids = seen or {}
		self.abandoned_ids[event.id] = true
	end
	return self:handle_event(event)
end

-- Decode one event and hand its containers to the owner. A container that
-- is not a table (`data: [1]`) is skipped: the owner and the debug line
-- below index it [security review 2026-10-25, finding 6]. Returns true when
-- the event's data decoded to a table.
function stream:handle_event(event)
	self.stats.events = self.stats.events + 1
	self.stats.last_event = clock()
	local containers, err = http.decode(event.data)
	if type(containers) ~= "table" then
		log.warn("event stream: undecodable event %s: %s", tostring(event.id),
			tostring(err or ("a " .. type(containers) .. ", not a list")))
		return false
	end
	local skipped = 0
	for _, container in ipairs(containers) do
		if type(container) ~= "table" then
			skipped = skipped + 1
		else
			self.stats.containers = self.stats.containers + 1
			if log.enabled("debug") then
				local types = {}
				if type(container.data) == "table" then
					for _, item in ipairs(container.data) do
						types[#types + 1] = type(item) == "table" and tostring(item.type) or type(item)
					end
				end
				log.debug("event %s %s: %s", tostring(event.id), tostring(container.type), table.concat(types, ","))
			end
			if self.opts.on_container then
				self.opts.on_container(container, event)
			end
		end
	end
	if skipped > 0 then
		log.warn("event stream: event %s: skipped %d container(s) that are not objects", tostring(event.id), skipped)
	end
	-- The per-event text only while connected: an abandoned transfer's last
	-- chunk can arrive while the current one is still connecting or waiting
	-- (it used to write "Connected since nil" then [code analysis 2026-10-22, L1]).
	if self.state == "connected" then
		self:status(string.format("Connected since %s, %d containers, last %s",
			tostring(self.stats.connected_since), self.stats.containers, self.stats.last_event), true)
	end
	return true
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
	local delay = self:next_delay()
	self:status(string.format("Disconnected: %s. Reconnecting in %d s", tostring(self.stats.last_error), delay))
	self:retry_in(delay)
end

-- The current backoff in seconds, doubled (up to BACKOFF_MAX) for the next.
function stream:next_delay()
	local delay = self.backoff
	self.backoff = math.min(self.backoff * 2, stream.BACKOFF_MAX)
	return delay
end

-- connect() again in `delay` seconds, unless start() or stop() comes first.
function stream:retry_in(delay)
	self:cancel_timer("retry_timer")
	self.retry_timer = C4:SetTimer(delay * 1000, function()
		self.retry_timer = nil
		if self.state == "waiting" then
			self:connect()
		end
	end)
end

return stream
