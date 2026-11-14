-- HTTPS client core for a Hue device's local API, built on C4:url(): the
-- part of bridge/http.lua that does not depend on which device answers
-- (#514, docs/hdmi-sync-stage1-design.md §3, contracts C3). The Hue Bridge
-- configures one instance in bridge/http.lua; the Hue Sync Box (stage 2)
-- will configure its own. This module requires no bridge.* module: it ships
-- in every package (tools/build.sh copies src/common/ into each .c4z).
--
-- https.new(opts) returns an instance: a table of fields and functions.
-- Every function is called with a dot, never a colon (http.request(req, cb),
-- http.peer_text(text)), and reads the instance's fields at every call, so
-- whoever changes one (ca, MAX_KEYED) changes what the next request does.
-- `opts`:
--   ca_bundle        the CA bundle's path inside the archive (CA_BUNDLE);
--                    ca = { path = ca_bundle }, or nil without one, which
--                    fails every request ("no CA configuration")
--   header_key       required: the header that carries req.key. A string
--                    is the header's name and the key its value (the
--                    bridge's "hue-application-key"); a table { name,
--                    prefix } sends prefix .. key under name (the box's
--                    { name = "Authorization", prefix = "Bearer " })
--                    (AUTH_HEADER, AUTH_PREFIX)
--   max_keyed        keyed requests in flight at once (MAX_KEYED, default 3)
--   timeout          seconds per transfer unless req.timeout says otherwise
--                    (DEFAULT_TIMEOUT, default 15)
--   connect_timeout  seconds to connect (CONNECT_TIMEOUT, default 5)
--   slot_grace_s     see the keyed queue below (SLOT_GRACE_S, default 10)
--   text_row, text_log  peer_text's caps (TEXT_ROW 256, TEXT_LOG 2000)
--   max_body         the most bytes of a response body; a longer one is
--                    refused before it is decoded (MAX_BODY; nil, the
--                    bridge's case, caps nothing)
--   log_prefix       text in front of every log line of the instance
--                    (LOG_PREFIX, default "")
--   log              the logger (default common.log, looked up at new())
--
-- Every request verifies the peer's certificate against the instance's CA
-- bundle. Hostname verification is off: a Hue device's certificate names
-- its id (the bridge id, the box id), not the address in the URL, so the
-- id is checked at the application layer instead (bridge/pairing.lua,
-- bridge/identity.lua; docs/design.md). The bundle is referenced relative
-- to the archive: on OS 3.4.2, C4:url prefixes ssl_cabundle with the
-- extracted archive's directory, and the option replaces the system CA
-- bundle, so trust is pinned to the roots in the bundle (spike runs 4 and
-- 5; see docs/design.md). One bundle per product: a box certificate must
-- never verify as a bridge's (docs/syncbox-architecture-research.md 2.2).
--
-- That is the only TLS configuration an instance knows. A request may adjust
-- it through req.tls, applied on top of it (options): the development
-- diagnostics (bridge/conntest.lua and bridge/pinning.lua, dev builds only)
-- for their other targets, and the TLS self-check (common/tlscheck.lua),
-- which swaps the bundle for a decoy. No keyed request does: bridge_request
-- in hue_bridge/driver.lua clears req.tls.
--
-- At most MAX_KEYED keyed requests (those with req.key) are in flight at
-- once; the rest wait, first in, first out (security review 2026-11-13,
-- N-8, #489). Director runs at most four C4:url transfers at once,
-- controller-wide [verified: hardware, docs/design.md "Concurrent
-- transfers"], and against a device that has stopped answering every
-- transfer holds its slot until its timeout: a burst of light commands
-- would hold all four and stall every other driver's C4:url traffic. The
-- event stream's C4:url transfers (stream) are not counted here: the
-- bridge's stream caps its own (bridge/stream.lua, MAX_ABANDONED), and its
-- default transport holds none (bridge/netstream.lua). Unkeyed requests
-- (the identity check, pairing, discovery, the TLS self-check) are not
-- queued. A slot is freed by the transfer's OnDone; one whose OnDone has
-- not come SLOT_GRACE_S after the transfer's own timeout is freed all the
-- same, so a lost callback cannot block keyed traffic for good. Each
-- instance counts its own requests, one set per runtime (see keyed_queue):
-- a driver that talks to one kind of device has one instance.

local https = {}

-- The defaults of https.new, the bridge's values since 1.0.
https.DEFAULT_TIMEOUT = 15
https.CONNECT_TIMEOUT = 5
https.MAX_KEYED = 3        -- keyed requests in flight at once (see the header)
https.SLOT_GRACE_S = 10    -- beyond a transfer's own timeout, before its slot is freed regardless

-- The most bytes of peer text (see https.peer_text) in a Composer row,
-- Status or Attention, and in a log line (security review 2026-11-13, #489).
https.TEXT_ROW = 256
https.TEXT_LOG = 2000

https.INVALID_PATH = "invalid request path"

-- A continuation byte of a UTF-8 character (0x80-0xBF).
local function continuation(b)
	return b ~= nil and b >= 0x80 and b <= 0xBF
end

-- Text a peer sent (the device, or whatever answers at its address: an
-- error description, a model id, an event id), fit for a row or a log line:
-- a non-string is its tostring, as the callers' own tostring was; at most
-- `max` bytes (default `default`, else TEXT_ROW), cut before a UTF-8
-- character (backing over at most three continuation bytes) and marked
-- "..."; control characters removed (`%c`: a newline would forge a log line
-- or garble a row). Only the first `max` bytes are read, so a megabyte costs
-- no more than a short text (security review 2026-11-13, N-4 and C-4, #489).
local function peer_text(value, max, default)
	max = math.max(4, math.floor(tonumber(max) or tonumber(default) or https.TEXT_ROW))
	local text = type(value) == "string" and value or tostring(value)
	local cut = #text > max
	if cut then
		local n = max - 3
		for _ = 1, 3 do
			if not continuation(text:byte(n + 1)) then
				break
			end
			n = n - 1
		end
		text = text:sub(1, n)
	end
	text = text:gsub("%c", "")
	return cut and (text .. "...") or text
end

-- peer_text with the module's caps, for code that holds no instance.
function https.peer_text(value, max)
	return peer_text(value, max, https.TEXT_ROW)
end

-- A request path starts with "/". url() puts it straight after the address,
-- so anything else moves the request to another host: "@..." makes the
-- address user info, ".example/..." or ":8443/..." extend it [security
-- review 2026-10-25, finding 10]. Release code always passes a literal path
-- (/clip/... or /api... on the bridge); request and stream refuse the rest
-- as an ordinary failure, url itself raises.
local function valid_path(path)
	return type(path) == "string" and path:sub(1, 1) == "/"
end

local function json_decode(body)
	return C4:JsonDecode(body)
end

-- Decode a JSON body. Returns the value, or nil and an error string; never
-- raises. The SDK gives both a nil-and-message return and a raised error for
-- invalid JSON [verified: SDK 12_json/_3-JsonDecode], so the call runs under
-- pcall and a raise becomes the same nil-and-message answer [security review
-- 2026-10-25, finding 6]. OS 3.4.2 returns nil [assumed: a 403 HTML body is
-- read as HTTP 403, not as an error].
function https.decode(body)
	if body == nil or body == "" then
		return nil, "empty body"
	end
	local ok, value, err = pcall(json_decode, body)
	if not ok then
		return nil, "invalid JSON: " .. tostring(value)
	end
	if value == nil then
		return nil, "invalid JSON: " .. tostring(err)
	end
	return value
end

-- curl's codes for a peer certificate that did not verify against the CA
-- bundle: 60 (CURLE_PEER_FAILED_VERIFICATION since curl 7.62, CURLE_SSL_CACERT
-- before it) and 51 (CURLE_PEER_FAILED_VERIFICATION before 7.62). Director
-- hands curl's code to OnDone as errCode: on OS 3.4.2 a public site refused
-- with the Signify bundle gave 60, an unreadable bundle path 77, a GET stuck
-- behind the stream 28 and an unresolvable spelling 6 [verified: hardware,
-- docs/design.md "Certificates" and "C4:url transfer scheduling"]. The SDK
-- itself promises only "a number with an error code" [verified: SDK
-- 35_url/_8-OnDone]. 51 is from curl's documentation and has not been seen on
-- a controller [assumed]. Each instance has its own copy (CERTIFICATE_ERRORS).
local function certificate_errors()
	return { [51] = true, [60] = true }
end

-- True when `result` (a request result) is a transfer that failed because
-- the peer's certificate did not verify: no HTTP status, and curl's code
-- (one of `codes`) says so. Anything else is not: a timeout (28), a refused
-- or unreachable host (7), a name that does not resolve (6), a CA file that
-- cannot be read (77), a TLS handshake that failed some other way (35), a
-- transfer that never started (no code at all) [curl's codes: assumed from
-- curl's documentation where the list above does not say verified].
local function certificate_failure(codes, result)
	return type(result) == "table" and result.code == nil
		and type(codes) == "table" and codes[tonumber(result.err_code)] == true
end

-- certificate_failure against the module's own list.
function https.certificate_failure(result)
	return certificate_failure(certificate_errors(), result)
end

-- Milliseconds (C4:GetTime, SDK 34_timer/_2-GetTime), else os.time().
local function now_ms()
	local ok, ms = pcall(function() return C4:GetTime() end)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

-- C4:url raises a Lua error at Get()/Post() time for some problems (a CA
-- file it can't open, for one). Turn that into a normal failure.
local function start(transfer, fn)
	local ok, err = pcall(fn)
	if ok then
		return transfer
	end
	return nil, "could not start transfer: " .. tostring(err)
end

-- The instance's private record, `self` below: pub (the instance's table),
-- log, prefix (log_prefix, its "%" escaped for string.format) and queues.

-- One log line of the instance, behind its prefix.
local function say(self, level, fmt, ...)
	self.log[level](self.prefix .. fmt, ...)
end

-- A failed request's log line: a warning, or a debug line for a request
-- that is expected to fail (req.quiet).
local function failed(self, method, req, err)
	say(self, req.quiet and "debug" or "warn", "%s %s: %s", method, tostring(req.path), err)
end

-- TLS options of every transfer: the peer verified against the bundle, the
-- hostname not (see the header).
local function ssl_options(self)
	return { ssl_verify_peer = true, ssl_verify_host = false, ssl_cabundle = self.pub.ca.path }
end

-- Shared options for every transfer. `tls` (see the header) is applied on
-- top of the bundle's ssl_* options, so whatever it does not name stays as
-- every request has it: ssl_verify_peer in particular stays true unless
-- `tls` itself sets it false (docs/reviews/diff-review-2026-10-24.md row 6;
-- a partial table used to leave it out altogether). An ssl_cabundle of false
-- leaves the option out, which puts the platform's own CA bundle in charge
-- [verified: SDK 35_url/_12-SetOption, ssl_cabundle is used "instead of the
-- system's"].
local function options(self, overrides, tls)
	local pub = self.pub
	local opts = {
		fail_on_error = false,
		timeout = pub.DEFAULT_TIMEOUT,
		connect_timeout = pub.CONNECT_TIMEOUT,
	}
	for k, v in pairs(ssl_options(self)) do
		opts[k] = v
	end
	for k, v in pairs(tls or {}) do
		opts[k] = v
	end
	if opts.ssl_cabundle == false then
		opts.ssl_cabundle = nil
	end
	for k, v in pairs(overrides or {}) do
		opts[k] = v
	end
	return opts
end

-- The request's headers: the key under the instance's auth header (see
-- header_key), then `extra`.
local function headers_for(self, key, extra)
	local headers = {}
	if key then
		local pub = self.pub
		headers[pub.AUTH_HEADER] = (pub.AUTH_PREFIX or "") .. key
	end
	for k, v in pairs(extra or {}) do
		headers[k] = v
	end
	return headers
end

-- The keyed requests in flight and waiting. One set per runtime (the C4
-- object): a spec installs a new fake runtime per test, and a transfer it
-- left unanswered must not hold a slot in the next one. On a controller
-- there is one.
local function keyed_queue(self)
	local runtime = C4 or self.queues
	local q = self.queues[runtime]
	if not q then
		q = { busy = {}, n = 0, waiting = {}, reaper = nil, pumping = false }
		self.queues[runtime] = q
	end
	return q
end

local function release(q, slot)
	if slot.released then
		return
	end
	slot.released = true
	q.busy[slot] = nil
	q.n = q.n - 1
end

-- Free the slots whose OnDone is overdue (see the header).
local function reap(self, q)
	local now = now_ms()
	for slot in pairs(q.busy) do
		if slot.deadline <= now then
			say(self, "warn", "%s %s: no end reported %d s after its timeout; its keyed request slot is freed",
				slot.method, tostring(slot.path), self.pub.SLOT_GRACE_S)
			release(q, slot)
		end
	end
end

local pump -- below

-- While requests wait: a timer for the earliest overdue slot.
local function arm_reaper(self, q)
	if q.reaper or #q.waiting == 0 then
		return
	end
	local first
	for slot in pairs(q.busy) do
		if not first or slot.deadline < first then
			first = slot.deadline
		end
	end
	if not first then
		return
	end
	local ok, timer = pcall(function()
		return C4:SetTimer(math.max(1, first - now_ms()), function()
			q.reaper = nil
			reap(self, q)
			pump(self, q)
		end)
	end)
	q.reaper = ok and timer or nil
end

-- One transfer, started now. `q`: the keyed queue whose slot it takes, or
-- nil for an unkeyed request. The slot is freed before the callback runs,
-- and the next waiting request started, so a callback that raises cannot
-- leave the queue stuck; so is a request that raised while it was built
-- (its slot freed, the raise passed on).
local send -- below

-- Start waiting requests while slots are free.
pump = function(self, q)
	if q.pumping then
		return -- the loop below goes on
	end
	q.pumping = true
	while q.n < self.pub.MAX_KEYED and #q.waiting > 0 do
		local entry = table.remove(q.waiting, 1)
		local method, answered = entry.req.method or "GET", false
		local ok, transfer = pcall(send, self, entry.req, function(result)
			answered = true
			return entry.callback(result)
		end, q)
		if ok then
			entry.transfer = transfer
		elseif answered then
			say(self, "warn", "%s %s: its callback failed: %s", method, tostring(entry.req.path), tostring(transfer))
		else
			-- Its caller is answered, as for a transfer that could not start.
			local err = "could not start transfer: " .. tostring(transfer)
			failed(self, method, entry.req, err)
			local fine, why = pcall(entry.callback, { ok = false, err = err })
			if not fine then
				say(self, "warn", "%s %s: its callback failed: %s", method, tostring(entry.req.path), tostring(why))
			end
		end
	end
	q.pumping = false
	if #q.waiting == 0 and q.reaper then
		pcall(function() q.reaper:Cancel() end)
		q.reaper = nil
	else
		arm_reaper(self, q)
	end
end

-- One request/response exchange. `req` has:
--   ip, path (starts with "/", see url), method ("GET"|"POST"|"PUT"|
--   "DELETE"), key (optional; sent under the instance's auth header; a
--   keyed request refuses redirects, see build), body (table, JSON-encoded,
--   optional), timeout (optional),
--   tls (optional ssl_* options on top of the bundle's, see options; dev
--   diagnostics and the TLS self-check only),
--   quiet (optional: a failure is logged at debug, not warn; for a request
--   expected to fail, the TLS self-check's).
-- `callback(result)` receives { ok, code, body, json, err, err_code }:
--   ok        true when the transfer completed and the status is 2xx
--   code      HTTP status, or nil when no response arrived
--   json      decoded body when it parsed, else nil
--   err       a human-readable reason when ok is false
--   err_code  the transfer's error code (curl's, see CERTIFICATE_ERRORS)
--             when it failed without a response; nil otherwise
-- A keyed request answered with a redirect gets { ok = false, code = <3xx>,
-- err = "redirect refused (HTTP <3xx>)" }. A body over MAX_BODY gets
-- { ok = false, code = <status>, err = "response of <n> bytes refused (over
-- <MAX_BODY>)" }, without body or json.
-- Returns the C4LuaUrl transfer so callers can Cancel() it, or nil when the
-- transfer could not be started (the callback has then already been called).
-- A keyed request that has to wait (see the header) returns a handle whose
-- Cancel() takes it out of the queue (its callback is then never called)
-- or, once it has started, cancels its transfer.
local function request(self, req, callback)
	local pub = self.pub
	local method = req.method or "GET"
	if not valid_path(req.path) then
		failed(self, method, req, pub.INVALID_PATH)
		callback({ ok = false, err = pub.INVALID_PATH })
		return nil
	end
	if not pub.ca then
		failed(self, method, req, "no CA configuration")
		callback({ ok = false, err = "no CA configuration" })
		return nil
	end
	if not req.key then
		return send(self, req, callback, nil)
	end
	local q = keyed_queue(self)
	reap(self, q)
	if q.n < pub.MAX_KEYED and #q.waiting == 0 then
		return send(self, req, callback, q)
	end
	local entry = { req = req, callback = callback }
	q.waiting[#q.waiting + 1] = entry
	say(self, "debug", "%s %s waits: %d keyed request(s) in flight, %d waiting", method, tostring(req.path), q.n,
		#q.waiting)
	arm_reaper(self, q)
	return {
		Cancel = function(handle)
			if entry.transfer then
				entry.transfer:Cancel()
				return handle
			end
			for i, e in ipairs(q.waiting) do
				if e == entry then
					table.remove(q.waiting, i)
					break
				end
			end
			return handle
		end,
	}
end

local build -- below

send = function(self, req, callback, q)
	if not q then
		return build(self, req, callback)
	end
	local pub = self.pub
	local slot = { method = req.method or "GET", path = req.path,
		deadline = now_ms() + ((tonumber(req.timeout) or pub.DEFAULT_TIMEOUT) + pub.SLOT_GRACE_S) * 1000 }
	q.busy[slot] = true
	q.n = q.n + 1
	local ok, transfer = pcall(build, self, req, function(result)
		release(q, slot)
		pump(self, q)
		callback(result)
	end)
	if not ok then
		release(q, slot)
		pump(self, q)
		error(transfer, 0)
	end
	return transfer
end

-- The result of a completed transfer (see request). Runs under pcall.
local function result_of(self, refused, responses, err_code, err_msg)
	if refused then
		return { ok = false, code = refused, err = string.format("redirect refused (HTTP %d)", refused) }
	end
	local pub = self.pub
	local result = {}
	local response = type(responses) == "table" and responses[#responses] or nil
	local cap = tonumber(pub.MAX_BODY)
	if err_code ~= 0 then
		result.ok = false
		result.err_code = err_code
		result.err = string.format("transfer failed (%s): %s", tostring(err_code), tostring(err_msg))
	elseif type(response) ~= "table" or type(response.code) ~= "number" then
		result.ok = false
		result.err = "no response"
	elseif cap and type(response.body) == "string" and #response.body > cap then
		-- Refused before C4:JsonDecode sees it (N-4's advice,
		-- docs/syncbox-architecture-research.md 2.4).
		result.ok = false
		result.code = response.code
		result.err = string.format("response of %d bytes refused (over %d)", #response.body, cap)
	else
		result.code = response.code
		result.body = response.body
		result.json = pub.decode(response.body)
		result.ok = response.code >= 200 and response.code < 300
		if not result.ok then
			result.err = "HTTP " .. tostring(response.code)
		end
	end
	return result
end

build = function(self, req, callback)
	local pub = self.pub
	local method = req.method or "GET"
	local url = pub.url(req.ip, req.path)
	-- encodeArrays = true is passed, but Director's JsonEncode was seen to
	-- write Lua arrays as objects even so (docs/design.md, "C4:url
	-- transfer scheduling on OS 3.4.2"); no body the drivers send holds an array, so nothing depends on it.
	local data = req.body and C4:JsonEncode(req.body, false, true) or nil
	local headers = headers_for(self, req.key, data and { ["Content-Type"] = "application/json" } or nil)

	if self.log.enabled("debug") then
		say(self, "debug", "%s %s%s", method, url, data and (" " .. data) or "")
	end

	local transfer = C4:url()
		:SetOptions(pub.options({ timeout = req.timeout }, req.tls))

	-- C4:url follows redirects by itself: OnHeaders runs once per response,
	-- "e.g. due to redirects" [verified: SDK 35_url/_9-OnHeaders], and no
	-- documented option turns that off [verified: SDK 35_url/_12-SetOption,
	-- 35_url/_13-SetOptions]. A keyed request must not go on to wherever a
	-- Location points: curl may send the key's header (the bridge's
	-- hue-application-key, the box's Authorization) there too, over plain
	-- http even [assumed]. So it aborts on a 3xx (a true returned from
	-- OnHeaders aborts the transfer, same page) and reports the refusal
	-- whatever OnDone then says [security review 2026-10-25, finding 7].
	-- Unkeyed requests (identity check, TLS self-check, pairing) follow
	-- redirects as before. OnHeaders alone leaves the body aggregated for
	-- OnDone: only an OnBodyChunk callback stops that [verified: SDK
	-- 35_url/_7-OnBodyChunk; assumed on hardware, where only the stream has
	-- used OnHeaders so far].
	local refused -- the 3xx this keyed request refused
	if req.key then
		transfer:OnHeaders(function(_, response)
			local code = type(response) == "table" and tonumber(response.code) or nil
			if code and code >= 300 and code <= 399 then
				refused = code
				return true
			end
			return false
		end)
	end

	transfer:OnDone(function(_, responses, err_code, err_msg)
		-- Guarded up to the callback: a raise here would leave the caller
		-- waiting for ever (a light's queue stays "in flight") [code
		-- analysis 2026-10-22, H2].
		local built, result = pcall(result_of, self, refused, responses, err_code, err_msg)
		if not built then
			result = { ok = false, err = "done handler: " .. tostring(result) }
		end
		if not result.ok then
			failed(self, method, req, result.err)
		end
		callback(result)
	end)

	local started, err = start(transfer, function()
		if method == "GET" then
			transfer:Get(url, headers)
		elseif method == "POST" then
			transfer:Post(url, data or "", headers)
		elseif method == "PUT" then
			transfer:Put(url, data or "", headers)
		elseif method == "DELETE" then
			transfer:Delete(url, headers)
		else
			error("unsupported method " .. tostring(method))
		end
	end)
	if not started then
		failed(self, method, req, err)
		callback({ ok = false, err = err })
	end
	return started
end

-- A long-lived GET whose body is handed over chunk by chunk. `req` as for
-- request, plus headers (extra request headers). A redirect reaches
-- on_headers like any other response (OnHeaders runs once per response,
-- SDK 35_url/_9-OnHeaders); the bridge's event stream aborts on every code
-- but 200, so it never follows one.
-- `handlers`:
--   on_headers(code, headers)  once per response; return true to abort
--   on_chunk(data)             each body chunk
--   on_done(err_code, err_msg, code)  when the transfer ends for any reason;
--                              err_code -2 means it never started
-- Returns the transfer so the caller can Cancel() it, or nil when it could
-- not be started (on_done has then already been called).
local function stream(self, req, handlers)
	local pub = self.pub
	if not valid_path(req.path) then
		say(self, "warn", "STREAM %s: %s", tostring(req.path), pub.INVALID_PATH)
		handlers.on_done(-2, pub.INVALID_PATH, nil)
		return nil
	end
	if not pub.ca then
		handlers.on_done(-2, "no CA configuration", nil)
		return nil
	end

	local url = pub.url(req.ip, req.path)
	local headers = headers_for(self, req.key, req.headers)
	local last_code

	if self.log.enabled("debug") then
		say(self, "debug", "STREAM %s (timeout %s s)", url, tostring(req.timeout))
	end

	local transfer = C4:url()
		:SetOptions(pub.options({ timeout = req.timeout }, req.tls))
		:OnHeaders(function(_, response)
			last_code = response.code
			if handlers.on_headers then
				return handlers.on_headers(response.code, response.headers)
			end
		end)
		:OnBodyChunk(function(_, _, chunk)
			if handlers.on_chunk then
				return handlers.on_chunk(chunk)
			end
		end)
		:OnDone(function(_, _, err_code, err_msg)
			if handlers.on_done then
				handlers.on_done(err_code, err_msg, last_code)
			end
		end)

	local started, err = start(transfer, function()
		transfer:Get(url, headers)
	end)
	if not started then
		say(self, "warn", "STREAM %s: %s", req.path, err)
		handlers.on_done(-2, err, nil)
	end
	return started
end

-- The auth header's name and value prefix from header_key (see the header).
local function auth_header(header_key)
	local name, prefix = header_key, nil
	if type(header_key) == "table" then
		name, prefix = header_key.name, header_key.prefix
	end
	if type(name) ~= "string" or not name:match("^[%w%-]+$") then
		error("https.new: header_key must name a header", 3)
	end
	if prefix ~= nil and (type(prefix) ~= "string" or prefix:find("%c")) then
		error("https.new: header_key.prefix must be text without control characters", 3)
	end
	return name, prefix
end

local function number_or(value, default)
	return tonumber(value) or default
end

-- A new instance (see the header).
function https.new(opts)
	opts = opts or {}
	local pub = {}
	pub.AUTH_HEADER, pub.AUTH_PREFIX = auth_header(opts.header_key)
	pub.DEFAULT_TIMEOUT = number_or(opts.timeout, https.DEFAULT_TIMEOUT)
	pub.CONNECT_TIMEOUT = number_or(opts.connect_timeout, https.CONNECT_TIMEOUT)
	pub.MAX_KEYED = number_or(opts.max_keyed, https.MAX_KEYED)
	pub.SLOT_GRACE_S = number_or(opts.slot_grace_s, https.SLOT_GRACE_S)
	pub.TEXT_ROW = number_or(opts.text_row, https.TEXT_ROW)
	pub.TEXT_LOG = number_or(opts.text_log, https.TEXT_LOG)
	pub.MAX_BODY = tonumber(opts.max_body)
	pub.LOG_PREFIX = tostring(opts.log_prefix or "")
	pub.CA_BUNDLE = opts.ca_bundle
	pub.ca = opts.ca_bundle and { path = opts.ca_bundle } or nil
	pub.CERTIFICATE_ERRORS = certificate_errors()
	pub.INVALID_PATH = https.INVALID_PATH

	local self = {
		pub = pub,
		log = opts.log or require("common.log"),
		prefix = (pub.LOG_PREFIX:gsub("%%", "%%%%")),
		queues = setmetatable({}, { __mode = "k" }),
	}

	function pub.peer_text(value, max)
		return peer_text(value, max, pub.TEXT_ROW)
	end
	function pub.options(overrides, tls)
		return options(self, overrides, tls)
	end
	function pub.certificate_failure(result)
		return certificate_failure(pub.CERTIFICATE_ERRORS, result)
	end
	function pub.url(ip, path)
		if not valid_path(path) then
			error(pub.INVALID_PATH, 2)
		end
		return "https://" .. ip .. path
	end
	pub.decode = https.decode
	function pub.request(req, callback)
		return request(self, req, callback)
	end
	function pub.stream(req, handlers)
		return stream(self, req, handlers)
	end
	return pub
end

return https
