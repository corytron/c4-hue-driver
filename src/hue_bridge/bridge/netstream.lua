-- The bridge's server-sent event stream (/eventstream/clip/v2) over a
-- network connection (docs/raw-stream-design.md §0, issue #317).
--
-- Why: Director runs at most four C4:url transfers at once, controller-wide
-- and across all drivers (docs/design.md, "Concurrent transfers"), and the
-- C4:url stream of bridge/stream.lua holds one of them for good; on a
-- tester's controller every request to the bridge timed out while it was
-- open. This module holds the stream on a dynamic network connection
-- instead, which no C4:url transfer waits for.
--
-- What: the job, the options (opts), the public surface and the behaviour
-- of bridge/stream.lua, which the driver builds instead when Event Stream
-- Transport is Web transfer. One GET kept open, its events parsed as they
-- arrive and every Hue container handed to the owner; a reconnect with
-- backoff whenever the stream ends; the watchdog for silence; on_connected
-- after every connect, so the owner can resync; a 401 or 403 stops the
-- stream for good and tells the owner once, through on_key_rejected (#44).
-- The status texts are stream.lua's.
--
-- How, with the SDK file that documents each call (API/ is
-- ~/c4-tools/reference/docs-driverworks-api/source/includes/, 32/ its
-- 32_serial_network_device/):
--   C4:CreateNetworkConnection(6001, ip, "SSL")   32/_1-CreateNetworkConnection.md
--   C4:NetPortOptions(6001, 443, "SSL", options)  32/_25-NetPortOptions.md (port_options below)
--   C4:NetConnect(6001, 443)                      32/_23-NetConnect.md, 32/_30-SampleSSLConnection.md
--   C4:SendToNetwork(6001, 443, request)          32/_20-SendToNetwork.md, once per "ONLINE"
--   C4:NetDisconnect(6001, 443)                   32/_24-NetDisconnect.md
--   C4:SetBindingAddress(6001, ip)                32/_16-SetBindingAddress.md
-- None of them may run in OnDriverInit (API/22_miscellaneous/_25.2-SafeUsageTable.md):
-- the owner starts the stream from OnDriverLateInit or later. The first
-- connect after every start() (and a new object's first) creates the
-- connection afresh, then disconnects it before connecting, the pattern of
-- Control4's websocket module; a reconnect within one run moves an existing
-- connection with SetBindingAddress when the address changed, which the SDK
-- wants followed by a NetConnect (32/_16).
--
-- The driver's globals feed two entry points, for netstream.BINDING only
-- (any other binding is ignored), and route them to the current stream
-- object only:
--   OnConnectionStatusChanged(idBinding, nPort, strStatus)    32/_27
--       -> netstream:on_status_changed(idBinding, nPort, strStatus)
--   ReceivedFromNetwork(idBinding, nPort, strData)             32/_15
--       -> netstream:on_data(idBinding, strData)
-- On "ONLINE" the request goes out (contract §0.4). The answer arrives in
-- pieces of any size, split anywhere ("may only include part of a protocol
-- command", 32/_15), and is put together here: the status line and the
-- headers, then the chunked body (RFC 9112 §7.1), or a body without chunked
-- encoding, read to its Content-Length or to the end of the connection. The
-- payload goes to bridge/sse.lua as stream.lua's chunks do, one feed per
-- network read. 200 is connected; 401 or 403 is the key rejected; any other
-- status, "OFFLINE", a malformed answer or the end of the body reconnect.
--
-- What stream.lua has and this module has not, because a network
-- connection has none of it:
--  * abandoned transfers, and the cap on open transfers with its WAITING
--    status: C4LuaUrl:Cancel() left a streaming transfer open, NetDisconnect
--    ends the connection (opts.abandoned is ignored);
--  * address rotation: the spellings gave C4:url transfers queues of their
--    own, so this stream uses the dotted address, conn.ip (conn.stream_ip
--    is ignored);
--  * the per-transfer total timeout: the connection lives until it drops,
--    the watchdog fires or the owner stops it (opts.timeout is ignored).
-- In their place, the connect timer: a connect that brings no "ONLINE"
-- within CONNECT_TIMEOUT counts as failed (contract §0.4), and so does an
-- "ONLINE" whose answer has not arrived CONNECT_TIMEOUT later.
--
-- Director's callbacks carry no connection identity, so a report about a
-- connection this stream already gave up cannot be told apart by a
-- generation, as stream.lua tells its transfers apart. The rules:
--  * "ONLINE" counts only while a connect is pending and data only while
--    the connection is open; anything else is a leftover, ignored.
--  * Every NetDisconnect of its own may still bring an "OFFLINE" that is
--    no news [assumed: Director reports a driver's own NetDisconnect,
--    docs/raw-stream-design.md §3], and so may its predecessor's on a new
--    object; the stream counts them (stale_offline) and skips that many,
--    even while the next connect is pending, when a connect that fails is
--    caught by the connect timer instead. "ONLINE" clears the count: what
--    Director reports about a connection it closed comes before the next
--    one is up [assumed].
--  * Director never reconnects on its own: AUTO_CONNECT and KEEP_CONNECTION
--    are off, and after an "OFFLINE" the stream connects again itself.
--
-- [assumed] until the hardware tests of docs/raw-stream-design.md §5: that
-- CACERTFILE resolves inside the .c4z as ssl_cabundle does, and that
-- VERIFY_MODE "peer" checks the chain but not the name (the certificate's
-- CN is the bridge id), both test 2; that "ONLINE" comes after the TLS
-- handshake (§3); how Director reports a failed connect (test 8).
--
-- The application key is in the request text only, which no log line and
-- no status text carries; an error raised while sending it is reported with
-- the key replaced by "<key>". And it goes out only once the network
-- connection's TLS self-check has passed (bridge/netcheck.lua): every
-- connect asks opts.tls_checked() first, and without a true answer nothing
-- is created, connected or sent. A stream built without that option never
-- connects.
--
-- Two rules carry over from stream.lua. on_connected is deferred out of the
-- data callback to a 1 ms C4:SetTimer, so the owner's resync GET never
-- starts inside ReceivedFromNetwork (a C4:url transfer started inside
-- another's callback failed at once on OS 3.4.2; whether ReceivedFromNetwork
-- has the same limit is §5 test 6), and this module starts no C4:url
-- transfer at all. on_container and on_key_rejected run inside
-- ReceivedFromNetwork: anything the owner starts from them must defer the
-- same way. Each event is delivered under pcall, as in stream.lua: an event
-- that raises costs that event and one warning per read.

local log = require("common.log")
local http = require("bridge.http")
local sse = require("bridge.sse")

local netstream = {}
netstream.__index = netstream

netstream.PATH = "/eventstream/clip/v2"
netstream.BINDING = 6001            -- network bindings are 6000-6999 (32/_1); the bridge has no other
netstream.PORT = 443
netstream.CONNECTION_TYPE = "SSL"   -- 32/_1 example, 32/_30
netstream.CONNECT_TIMEOUT = 10      -- seconds for "ONLINE", then again for the answer's head
netstream.DEFAULT_WATCHDOG = 600    -- seconds of silence before reconnecting, as stream.lua
netstream.BACKOFF_MIN = 1           -- seconds, as stream.lua
netstream.BACKOFF_MAX = 60

-- What the answer may hold back while it is incomplete: one line of the
-- head, the head as a whole, a chunk-size or trailer line. The SSE parser's
-- own line limit (bridge/sse.lua), so the framing never holds more than the
-- content it carries may.
netstream.MAX_LINE = sse.MAX_LINE

-- The tPortParams of NetPortOptions. Every key is one of 32/_25; the values
-- are contract §0.2, plus KEEP_CONNECTION and DELIMITER from §2, which §0.2
-- does not name. A new table per call, so no caller can change what a
-- connection gets; nil without a CA configuration (http.ca), so the stream
-- never connects unverified. Left out on purpose: METHOD/VERIFY_METHOD
-- (Director then negotiates, "sslv23"; every listed value is TLS 1.1 or
-- older, §2) and the client certificate keys.
function netstream.port_options()
	if not (http.ca and http.ca.path) then
		return nil
	end
	return {
		CACERTFILE = http.ca.path,          -- the two Signify roots; "relative to the driver's C4Z location"
		VERIFY_MODE = "peer",               -- left out, Director verifies nothing ("none")
		KEEP_ALIVE = true,                  -- TCP keep-alive: dead-peer detection, slow (§4)
		AUTO_CONNECT = false,               -- connects only on NetConnect
		MONITOR_CONNECTION = false,         -- Director's polling would take a quiet stream for a dead one
		KEEP_CONNECTION = false,            -- the stream's own backoff reconnects, not Director
		DELIMITER = "",                     -- none: data is delivered as it arrives
		-- No OnDeviceOnline/Offline, which make room drivers rebuild their media
		-- cache (API/7_event/_8 recommends true); OnConnectionStatusChanged still fires.
		SUPPRESS_CONNECTION_EVENTS = true,
	}
end

-- Clear the binding's address (Forget Pairing, contract §0.2), as Control4's
-- websocket module does when it lets a connection go: SetBindingAddress
-- with '' (32/_16; drivers-common-public module/websocket.lua). Stop the
-- stream first. Returns false when the call raised.
function netstream.clear_address()
	local ok, err = pcall(function()
		C4:SetBindingAddress(netstream.BINDING, "")
	end)
	if not ok then
		log.warn("event stream: could not clear the network binding's address: %s", tostring(err))
	end
	return ok
end

-- One HTTP/1.1 answer, read incrementally (RFC 9112). feed(data) takes the
-- bytes as they arrive, split anywhere, and returns the items they
-- complete, in order:
--   { kind = "head", code = n, headers = { [lower-case name] = value }, problem = text|nil }
--       problem: a body this reader cannot decode (a transfer coding other
--       than chunked, a malformed Content-Length); nothing follows it
--   { kind = "body", data = bytes }      decoded body, any length
--   { kind = "done" }                    the body ended: the last chunk and
--                                        its trailers, or Content-Length reached
--   { kind = "error", message = text }   malformed or oversized; nothing follows
-- An interim 1xx answer other than 101 is skipped (RFC 9110 §15.2). Lines
-- end in LF, with or without CR (RFC 9112 §2.2). Without Transfer-Encoding
-- or Content-Length the body runs until the connection closes (RFC 9112
-- §6.3), which the caller learns from "OFFLINE".
local reader = {}
reader.__index = reader

local function new_reader()
	return setmetatable({
		phase = "status",   -- status | headers | size | data | data_end | trailer | body | done | failed
		parts = {},         -- the pieces of an incomplete line
		parts_len = 0,
		head_len = 0,       -- bytes of the head read so far
		code = nil,
		headers = {},
		last_header = nil,  -- the header an obsolete folded line continues
		head = nil,         -- the head item, once the head is complete
		need = nil,         -- bytes left of the current chunk, or of a Content-Length body
	}, reader)
end

function reader:fail(out, message)
	self.phase = "failed"
	out[#out + 1] = { kind = "error", message = message }
end

-- True while the body runs until the connection closes.
function reader:until_close()
	return self.phase == "body" and self.need == nil
end

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function reader:end_of_head(out)
	local code = self.code
	if code >= 100 and code < 200 and code ~= 101 then
		self.phase = "status" -- an interim answer: the real one follows
		return
	end
	local item = { kind = "head", code = code, headers = self.headers }
	self.head = item
	out[#out + 1] = item
	local coding, length = self.headers["transfer-encoding"], self.headers["content-length"]
	if coding then
		local chunked, other = false, false
		for name in coding:lower():gmatch("[^,%s]+") do
			if name == "chunked" then
				chunked = true
			elseif name ~= "identity" then
				other = true
			end
		end
		if other or not chunked then
			item.problem = "malformed answer: unsupported transfer coding"
			self.phase = "failed"
			return
		end
		self.phase = "size"
	elseif length then
		local digits = length:match("^%d+$")
		if not digits or #digits > 12 then
			item.problem = "malformed answer: Content-Length"
			self.phase = "failed"
			return
		end
		self.need = tonumber(digits)
		if self.need == 0 then
			self.phase = "done"
			out[#out + 1] = { kind = "done" }
		else
			self.phase = "body"
		end
	else
		self.phase = "body"
	end
end

-- One complete line, without its LF and CR.
function reader:line(text, out)
	local phase = self.phase
	if phase == "status" then
		if text == "" then
			return -- tolerated before the status line
		end
		local code = text:match("^HTTP/%d%.%d[ \t]+(%d%d%d)")
		if not code then
			return self:fail(out, "malformed answer: status line")
		end
		self.code = tonumber(code)
		self.headers, self.last_header = {}, nil
		self.phase = "headers"
	elseif phase == "headers" then
		if text == "" then
			return self:end_of_head(out)
		end
		if text:find("^[ \t]") then
			-- An obsolete folded line continues the header before it (RFC 9112 §5.2).
			if self.last_header then
				self.headers[self.last_header] = self.headers[self.last_header] .. " " .. trim(text)
			end
			return
		end
		local name, value = text:match("^([^:%s]+)[ \t]*:(.*)$")
		if name then
			name = name:lower()
			value = trim(value)
			local before = self.headers[name]
			self.headers[name] = before and (before .. ", " .. value) or value
			self.last_header = name
		end
		-- A line that is no header is skipped.
	elseif phase == "size" then
		local hex, rest = text:match("^[ \t]*(%x+)[ \t]*(.-)$")
		if not hex or (rest ~= "" and rest:sub(1, 1) ~= ";") then
			return self:fail(out, "malformed answer: chunk size")
		end
		hex = hex:gsub("^0+", "")
		if #hex > 8 then
			return self:fail(out, "malformed answer: chunk size")
		end
		local size = hex == "" and 0 or tonumber(hex, 16)
		if size == 0 then
			self.phase = "trailer"
		else
			self.need, self.phase = size, "data"
		end
	elseif phase == "data_end" then
		if text ~= "" then
			return self:fail(out, "malformed answer: chunk longer than its size")
		end
		self.phase = "size"
	elseif phase == "trailer" then
		if text == "" then
			self.phase = "done"
			out[#out + 1] = { kind = "done" }
		end
		-- A trailer field is skipped.
	end
end

function reader:feed(data)
	local out, pos, n = {}, 1, #data
	while pos <= n do
		local phase = self.phase
		if phase == "done" or phase == "failed" then
			break
		elseif phase == "data" or phase == "body" then
			local take = n - pos + 1
			if self.need and self.need < take then
				take = self.need
			end
			out[#out + 1] = { kind = "body", data = data:sub(pos, pos + take - 1) }
			pos = pos + take
			if self.need then
				self.need = self.need - take
				if self.need == 0 and phase == "data" then
					self.phase = "data_end"
				elseif self.need == 0 then
					self.phase = "done"
					out[#out + 1] = { kind = "done" }
				end
			end
		else
			local nl = data:find("\n", pos, true)
			local last = nl or n
			local in_head = phase == "status" or phase == "headers"
			self.parts_len = self.parts_len + (last - pos + 1)
			if self.parts_len > netstream.MAX_LINE
				or (in_head and self.head_len + self.parts_len > netstream.MAX_LINE) then
				self:fail(out, in_head and "oversized answer head" or "oversized line in stream")
				break
			end
			if not nl then
				self.parts[#self.parts + 1] = data:sub(pos)
				break
			end
			local text = data:sub(pos, nl - 1)
			if #self.parts > 0 then
				self.parts[#self.parts + 1] = text
				text = table.concat(self.parts)
				self.parts = {}
			end
			if in_head then
				self.head_len = self.head_len + self.parts_len
			end
			self.parts_len = 0
			pos = nl + 1
			if text:byte(-1) == 13 then
				text = text:sub(1, -2)
			end
			self:line(text, out)
		end
	end
	return out
end

-- The request of contract §0.4: these four headers and nothing else.
local function request_text(ip, key)
	return table.concat({
		"GET " .. netstream.PATH .. " HTTP/1.1",
		"Host: " .. ip,
		"hue-application-key: " .. key,
		"Accept: text/event-stream",
		"Connection: keep-alive",
		"",
		"",
	}, "\r\n")
end

-- A value that can go into a request line: a CR or LF would end the line
-- early and start a header of the sender's choosing. Neither the dotted
-- address nor a key the bridge issued holds a space or a control character.
local function header_safe(value)
	return type(value) == "string" and value ~= "" and not value:find("[%c%s]")
end

-- `text` with every occurrence of `key` replaced by "<key>"; a plain
-- search, the key is data, not a pattern.
local function redact(text, key)
	local parts, from = {}, 1
	while true do
		local first, last = text:find(key, from, true)
		if not first then
			break
		end
		parts[#parts + 1] = text:sub(from, first - 1)
		parts[#parts + 1] = "<key>"
		from = last + 1
	end
	parts[#parts + 1] = text:sub(from)
	return table.concat(parts)
end

-- opts: those of stream.new (bridge/stream.lua), read the same way, except
-- that conn.stream_ip, opts.timeout and opts.abandoned do not apply (see the
-- header):
--   connection()    returns { ip, key }, or nil and optionally a reason (the
--                   status to show, "Not paired" when there is none); asked
--                   again for every connect
--   watchdog        seconds, see DEFAULT_WATCHDOG
--   on_container(container, event), on_status(text, per_event),
--   on_connected(), on_key_rejected(code)    as in stream.lua
-- and one stream.lua has not:
--   tls_checked()   true once the network connection's TLS self-check
--                   (bridge/netcheck.lua) lets the key go out on it; asked
--                   again for every connect. Missing, false or raising: the
--                   stream does not connect (see the header).
--
-- stats, as stream.lua's: containers, events, keepalives, reconnects (every
-- reconnect scheduled since netstream.new), last_event, connected_since,
-- started (the clock text of the first connect since netstream.new), last_error,
-- address (the address of the current or last connection).
function netstream.new(opts)
	return setmetatable({
		opts = opts,
		state = "stopped",          -- stopped | connecting | connected | waiting, as stream.lua
		generation = 0,             -- moves on with every connection given up; timers check it
		link = "closed",            -- closed | opening | open: the connection as far as this stream knows
		stale_offline = 1,          -- "OFFLINE" reports still owed for connections given up (see the header)
		created_ip = nil,           -- the address the connection was created with in this run
		send_request = nil,         -- sends this connection's request (it holds the key)
		reader = nil,               -- this connection's HTTP answer
		parser = nil,               -- this connection's SSE parser
		watchdog = nil,
		last_data = nil,            -- ms clock of the last event or keepalive, for the watchdog
		fed_since_arm = false,      -- an event or keepalive arrived since the watchdog was (re)armed
		connect_timer = nil,        -- CONNECT_TIMEOUT for "ONLINE", then for the answer's head
		connected_timer = nil,      -- defers on_connected out of ReceivedFromNetwork
		retry_timer = nil,
		backoff = netstream.BACKOFF_MIN,
		hold_backoff = false,       -- a malformed or oversized answer: keep the backoff (connected)
		stats = { containers = 0, events = 0, keepalives = 0, reconnects = 0,
			last_event = nil, connected_since = nil, last_error = nil,
			started = nil,          -- clock() of the first connect, kept across reconnects
			address = nil },        -- the address the current/last connection used
	}, netstream)
end

local function clock()
	return os.date("%H:%M:%S")
end

-- opts.tls_checked() under pcall: only a true answer lets the stream connect.
local function tls_checked(opts)
	if type(opts.tls_checked) ~= "function" then
		return false
	end
	local ok, passed = pcall(opts.tls_checked)
	return ok and passed == true
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

function netstream:status(text, per_event)
	if self.opts.on_status then
		self.opts.on_status(text, per_event)
	end
end

function netstream:cancel_timer(name)
	if self[name] then
		self[name]:Cancel()
		self[name] = nil
	end
end

-- Arm the watchdog for the whole period, or for `delay_ms` (the remainder
-- of a period an event interrupted). As stream.lua: armed at the connect and
-- again for a whole period at the 200; events and keepalive comments feed
-- it by noting the clock; when it fires it reconnects if nothing fed it for
-- the whole period, else it is armed again for the rest of the period.
function netstream:arm_watchdog(delay_ms)
	self:cancel_timer("watchdog")
	local seconds = self.opts.watchdog or netstream.DEFAULT_WATCHDOG
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
		self:fail("watchdog: no data for " .. seconds .. " s")
	end)
end

-- The connect timer (see the header): armed at the connect, and again at
-- "ONLINE" for the answer's head; the head ends it.
function netstream:arm_connect_timer(online)
	self:cancel_timer("connect_timer")
	local gen = self.generation
	self.connect_timer = C4:SetTimer(netstream.CONNECT_TIMEOUT * 1000, function()
		if gen ~= self.generation then
			return
		end
		self.connect_timer = nil
		self:fail(string.format(online and "no answer within %d s" or "no connection within %d s",
			netstream.CONNECT_TIMEOUT))
	end)
end

-- NetDisconnect, and count the "OFFLINE" it may bring (see the header).
function netstream:disconnect()
	self.stale_offline = self.stale_offline + 1
	local ok, err = pcall(function()
		C4:NetDisconnect(netstream.BINDING, netstream.PORT)
	end)
	if not ok then
		log.warn("event stream: NetDisconnect failed: %s", tostring(err))
	end
end

-- Give up the current connection: its timers go, and every timer it armed
-- is left powerless by the generation; a connection still open or pending
-- is disconnected.
function netstream:drop_connection()
	self.generation = self.generation + 1
	self:cancel_timer("watchdog")
	self:cancel_timer("connect_timer")
	self:cancel_timer("connected_timer")
	self.reader = nil
	self.send_request = nil
	if self.link ~= "closed" then
		self.link = "closed"
		self:disconnect()
	end
end

function netstream:start()
	self:cancel_timer("retry_timer")
	if self.state == "connecting" or self.state == "connected" then
		return
	end
	self:connect()
end

-- Stop until the next start(): no reconnect, and the next start() creates
-- the connection afresh. `text` is the status to show (default "Stopped").
function netstream:stop(text)
	self:cancel_timer("retry_timer")
	self:drop_connection()
	self.state = "stopped"
	self.created_ip = nil
	self.stats.connected_since = nil
	self:status(text or "Stopped")
end

function netstream:running()
	return self.state ~= "stopped"
end

-- Create (first connect of a run) or move (address changed) the connection,
-- set its port options and connect. Raises what a C4 call raises.
local function open(self, ip, options)
	local binding, port, kind = netstream.BINDING, netstream.PORT, netstream.CONNECTION_TYPE
	self.link = "opening" -- before NetConnect, should Director report at once
	local fresh = self.created_ip == nil
	if fresh then
		C4:CreateNetworkConnection(binding, ip, kind)
	elseif self.created_ip ~= ip then
		log.info("event stream: bridge address changed from %s to %s", self.created_ip, ip)
		C4:SetBindingAddress(binding, ip)
	end
	self.created_ip = ip
	C4:NetPortOptions(binding, port, kind, options)
	if fresh then
		self:disconnect()
	end
	C4:NetConnect(binding, port)
end

function netstream:connect()
	self:drop_connection()
	local conn, reason = self.opts.connection()
	if not conn then
		self.state = "stopped"
		self:status(reason or "Not paired")
		return
	end
	local ip, key = conn.ip, conn.key
	if not (header_safe(ip) and header_safe(key)) then
		local what = header_safe(ip) and "application key" or "bridge address"
		log.warn("event stream: the %s cannot go into the request; not connecting", what)
		self.state = "stopped"
		self:status("Not connected: invalid " .. what)
		return
	end
	-- The last guard (the driver gates every start already): nothing keyed
	-- on a network connection whose TLS check has not passed (#317).
	if not tls_checked(self.opts) then
		log.warn("event stream: the network connection's TLS check has not passed; not connecting")
		self.state = "stopped"
		self:status("Not connected: network connection TLS check pending")
		return
	end

	self.state = "connecting"
	self.parser = sse.new()
	self.reader = new_reader()
	self.stats.address = ip
	self:status("Connecting")
	log.info("event stream: connecting to %s (network connection, binding %d)", ip, netstream.BINDING)
	-- Armed now, as in stream.lua: a connection that never answers is
	-- restarted after the watchdog period too.
	self:arm_watchdog()

	local options = netstream.port_options()
	if not options then
		return self:fail("no CA configuration")
	end
	local request = request_text(ip, key)
	self.send_request = function()
		local ok, err = pcall(function()
			C4:SendToNetwork(netstream.BINDING, netstream.PORT, request)
		end)
		if not ok then
			return false, redact(tostring(err), key)
		end
		return true, #request
	end
	-- Before the calls, should Director report from inside one of them.
	self:arm_connect_timer(false)
	local ok, err = pcall(open, self, ip, options)
	if not ok then
		log.warn("event stream: could not open the network connection: %s", tostring(err))
		return self:fail("could not open the network connection: " .. tostring(err))
	end
end

-- Director's OnConnectionStatusChanged, routed by the driver.
function netstream:on_status_changed(binding, port, status)
	if tonumber(binding) ~= netstream.BINDING then
		return
	end
	status = tostring(status):upper()
	if status == "ONLINE" then
		self:handle_online()
	elseif status == "OFFLINE" then
		self:handle_offline()
	else
		log.debug("event stream: connection status %s on port %s ignored", status, tostring(port))
	end
end

function netstream:handle_online()
	if self.link ~= "opening" then
		log.debug("event stream: ONLINE ignored (%s)",
			self.link == "open" and "already online" or "no connect pending")
		return
	end
	self.link = "open"
	self.stale_offline = 0
	local ok, detail = self.send_request()
	if not ok then
		log.warn("event stream: could not send the request: %s", detail)
		return self:fail("could not send the request: " .. detail)
	end
	log.debug("event stream: online; GET %s sent (%d bytes)", netstream.PATH, detail)
	self:arm_connect_timer(true)
end

function netstream:handle_offline()
	if self.link == "closed" then
		log.debug("event stream: OFFLINE of a connection already given up ignored")
		self.stale_offline = math.max(0, self.stale_offline - 1)
		return
	end
	if self.link == "opening" and self.stale_offline > 0 then
		self.stale_offline = self.stale_offline - 1
		log.debug("event stream: OFFLINE taken for a connection given up before this connect")
		return
	end
	local reason
	if self.link == "opening" then
		reason = "could not connect (OFFLINE)"
	elseif not self.reader.head then
		reason = "connection closed before an answer"
	elseif self.reader:until_close() then
		reason = "server closed the stream (HTTP 200)" -- the end of a body that runs to the close
	else
		reason = "connection closed (OFFLINE)"
	end
	self.link = "closed" -- Director closed it: nothing to disconnect
	self:fail(reason)
end

-- Director's ReceivedFromNetwork, routed by the driver: the next piece of
-- the answer. The body pieces of one read reach the SSE parser together.
function netstream:on_data(binding, data)
	if tonumber(binding) ~= netstream.BINDING or type(data) ~= "string" or data == "" then
		return
	end
	local current = self.reader
	if self.link ~= "open" or not current then
		log.debug("event stream: %d byte(s) with no open connection ignored", #data)
		return
	end
	local ok, items = pcall(current.feed, current, data)
	if not ok then
		log.error("event stream: the answer could not be read: %s", tostring(items))
		return self:fail("unreadable answer", true)
	end
	local body = {}
	for _, item in ipairs(items) do
		if item.kind == "body" then
			body[#body + 1] = item.data
		else
			if #body > 0 then
				if not self:handle_body(table.concat(body)) then
					return
				end
				body = {}
			end
			if item.kind == "head" then
				if not self:handle_head(item) then
					return
				end
			elseif item.kind == "done" then
				return self:fail("server closed the stream (HTTP 200)")
			else
				log.warn("event stream: %s; reconnecting", item.message)
				return self:fail(item.message, true)
			end
		end
	end
	if #body > 0 then
		self:handle_body(table.concat(body))
	end
end

-- The answer's head. Returns true when the stream goes on with its body.
function netstream:handle_head(item)
	self:cancel_timer("connect_timer")
	local code = item.code
	if code == 401 or code == 403 then
		self:key_rejected(code)
		return false
	end
	if code ~= 200 then
		log.warn("event stream: rejected with HTTP %s", tostring(code))
		self:fail("HTTP " .. tostring(code))
		return false
	end
	if item.problem then
		log.warn("event stream: %s; reconnecting", item.problem)
		self:fail(item.problem, true)
		return false
	end
	self:connected()
	return true
end

-- A 200: connected, as stream.lua's handle_headers.
function netstream:connected()
	self.state = "connected"
	-- A connection resets the backoff, except after a malformed or oversized
	-- answer: a peer that answers 200 and then overflows would be reconnected
	-- every second otherwise. The doubled backoff stays until a connection
	-- delivers an event normally (handle_body), as in stream.lua.
	if not self.hold_backoff then
		self.backoff = netstream.BACKOFF_MIN
	end
	self.stats.connected_since = clock()
	self.stats.started = self.stats.started or self.stats.connected_since
	self:arm_watchdog()
	self:status("Connected since " .. self.stats.connected_since)
	-- Deferred: this runs inside ReceivedFromNetwork, and the owner issues a
	-- resync GET from on_connected (see the header).
	self:cancel_timer("connected_timer")
	if self.opts.on_connected then
		local gen = self.generation
		self.connected_timer = C4:SetTimer(1, function()
			if gen ~= self.generation then
				return
			end
			self.connected_timer = nil
			self.opts.on_connected()
		end)
	end
end

-- The bridge refused the application key: stop for good (no reconnect,
-- until start()), say so, and tell the owner once, under pcall. As
-- stream.lua's key_rejected; this runs inside ReceivedFromNetwork.
function netstream:key_rejected(code)
	self.stats.last_error = string.format("key rejected (HTTP %s)", tostring(code))
	log.warn("event stream: the bridge rejected the application key (HTTP %s); stopped, no reconnect",
		tostring(code))
	self:stop(string.format("Stopped: key rejected (HTTP %s)", tostring(code)))
	if self.opts.on_key_rejected then
		local ok, err = pcall(self.opts.on_key_rejected, code)
		if not ok then
			log.error("event stream: on_key_rejected failed: %s", tostring(err))
		end
	end
end

-- Hand each event to handle_event under pcall: one that raises is skipped,
-- the rest are delivered, and the checks after them still run; one warning
-- per read. The delivery ends once the generation moves on (an owner
-- callback stopped or rebuilt the stream). Returns how many events were
-- delivered normally.
local function deliver_each(self, events, gen)
	local normal, failed, first = 0, 0, nil
	for _, event in ipairs(events) do
		if gen ~= self.generation then
			break
		end
		local ok, result = pcall(self.handle_event, self, event)
		if not ok then
			failed = failed + 1
			first = first or result
		elseif result then
			normal = normal + 1
		end
	end
	if failed > 0 then
		log.warn("event stream: %d of %d event(s) in one read raised an error and were skipped; the first: %s",
			failed, #events, tostring(first))
	end
	return normal
end

-- Decoded body bytes of the current connection, as stream.lua's
-- handle_chunk. Returns true when the connection goes on.
function netstream:handle_body(data)
	-- This connection's own parser and generation: an owner callback below
	-- may stop or rebuild the stream.
	local parser, gen = self.parser, self.generation
	local before = parser.comments
	local events = parser:feed(data)
	local keepalives = parser.comments - before
	self.stats.keepalives = self.stats.keepalives + keepalives
	-- Only an event or a keepalive feeds the watchdog, and before the events
	-- are handled, so an owner callback that raises cannot leave a live
	-- stream looking silent.
	if #events > 0 or keepalives > 0 then
		self.last_data = now_ms()
		self.fed_since_arm = true
	end
	local normal = deliver_each(self, events, gen)
	if gen ~= self.generation then
		return false
	end
	if parser.overflowed then
		log.warn("event stream: oversized line; reconnecting")
		self:fail("oversized line in stream", true)
		return false
	end
	if normal > 0 and self.hold_backoff then
		self.hold_backoff = false
		self.backoff = netstream.BACKOFF_MIN
	end
	return true
end

-- Decode one event and hand its containers to the owner, as stream.lua's
-- handle_event: a container that is not a table is skipped. Returns true
-- when the event's data decoded to a table.
function netstream:handle_event(event)
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
	if self.state == "connected" then
		self:status(string.format("Connected since %s, %d containers, last %s",
			tostring(self.stats.connected_since), self.stats.containers, self.stats.last_event), true)
	end
	return true
end

-- The connection ended or failed for `reason`: give it up and reconnect
-- after the backoff. `hold` keeps the backoff from being reset by the next
-- 200 (see connected).
function netstream:fail(reason, hold)
	self.stats.last_error = reason
	log.info("event stream ended: %s", reason)
	if hold then
		self.hold_backoff = true
	end
	self:drop_connection()
	self:schedule_reconnect()
end

function netstream:schedule_reconnect()
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
function netstream:next_delay()
	local delay = self.backoff
	self.backoff = math.min(self.backoff * 2, netstream.BACKOFF_MAX)
	return delay
end

-- connect() again in `delay` seconds, unless start() or stop() comes first.
function netstream:retry_in(delay)
	self:cancel_timer("retry_timer")
	self.retry_timer = C4:SetTimer(delay * 1000, function()
		self.retry_timer = nil
		if self.state == "waiting" then
			self:connect()
		end
	end)
end

return netstream
