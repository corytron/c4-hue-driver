-- The Hue Sync Box's local API client (#514, docs/hdmi-sync-stage2-design.md
-- §3.1, contracts C2 and C3): common/https.lua configured for the box, with
-- one request in flight and a short queue behind it.
--
-- The box's API (docs/syncbox-api-research.md, R1; docs/syncbox-architecture-
-- research.md, R5):
--   - base https://<address>/api/v1; a keyed request carries
--     "Authorization: Bearer <token>" (R1 §2.1, §2.3);
--   - the certificate chains to the self-signed root C=NL, O=Philips Hue,
--     CN=root-hsb (certs/hsb_ca.pem, SHA-256 A8:4F:E4:D6:...:8C:74), and its
--     common name is the box id, not the address, so the host name is not
--     verified and the id is checked by syncbox/identity.lua instead (R5
--     §2.2; common/https.lua's header);
--   - one request at a time: aiohuesyncbox opens one connection, with the
--     comment that the box handles only a few, and Homebridge sends every
--     request through one lock (R1 §2.13). Director runs at most four C4:url
--     transfers controller-wide (R5 §2.1), so one is also all the box driver
--     should hold.
--
--   local c = client.new{ address, token, log, https }
--   c:set_address(a)       the box's address (nil clears); a new one drops
--                          the trust below
--   c:set_token(t)         the token (nil clears: Forget Pairing); a new one
--                          drops the trust, a cleared one answers every keyed
--                          request still waiting with "not paired"
--   c:set_trusted(bool)    syncbox/identity.lua's verdict for the current
--                          address and token; keyed requests wait until true
--   c:get(path, cb[, opts]), c:put(path, body, cb[, opts]),
--   c:post(path, body, cb[, opts]), c:delete(path, cb[, opts])
--                          `path` after /api/v1 ("", "/device",
--                          "/registrations"); returns a handle whose
--                          Cancel() drops the request (its cb never called)
--
-- cb(ok, status, decoded, err, err_code):
--   ok        true on a 2xx with a JSON body; also on a 2xx with an empty
--             body to a PUT or a DELETE (decoded nil then)
--   status    the HTTP status, or nil when no answer came
--   decoded   the decoded JSON body, error answers included (the box's
--             {code, message}: pairing reads code 16 from it)
--   err       a short text when ok is false, through peer_text, never
--             holding the token
--   err_code  curl's code when no answer came (c:certificate_failure tells a
--             certificate that did not verify from the rest; identity.lua)
--
-- opts (the argument after cb; get and delete also take it as a fourth):
--   unkeyed   true: no token is sent, and the request does not wait for the
--             trust. GET /device and POST /registrations only (identity,
--             pairing, discovery)
--   address   an unkeyed request's own address (identity checks a candidate
--             or a pairing address without moving the client); a keyed
--             request goes only to the client's address
--   timeout   seconds (default the https instance's, 6)
--   quiet     a failure is logged at debug, not warn (pairing's code 16 every
--             second; discovery's candidates)
--
-- The queue: one request in flight; the rest wait first in, first out, at
-- most MAX_WAITING; one more is answered at once with err "busy". A keyed
-- request waits while the client is not trusted, and unkeyed ones go past it
-- (the identity check that grants the trust is one of them). A request with
-- no address, or a keyed one with no token, is answered at once. One whose
-- end never came (no OnDone SLOT_GRACE_S after its timeout) is answered
-- "no end reported" and its place freed, so a lost callback cannot stop the
-- box's traffic for good: checked at every new request, and by a timer while
-- requests wait (whose callback re-reads the clock, so firing early is
-- harmless), as common/https.lua's keyed queue does. A request that raised
-- while it was built frees its place too. The next request is started from
-- the end of the last, inside C4:url's OnDone: the bridge's identity check
-- starts its TLS self-check the same way, which works on OS 3.4.2 [verified:
-- hardware, docs/design.md "TLS self-check in release builds"]; only
-- OnHeaders and OnBodyChunk refuse a new transfer (bridge/stream.lua, rule 1).
--
-- A keyed request never follows a redirect: common/https.lua aborts it on a
-- 3xx in OnHeaders (R5 §2.5), err "redirect refused (HTTP 3xx)".
--
-- The token never appears in a log line, a property, Last Action or an error
-- text, not even at debug: common/https.lua logs the method, the URL and the
-- request body (never the headers), the default instance's log lines pass
-- through cut_token on their way out (curl's error texts are not this
-- module's), and every err this module hands out has the token cut out. No
-- answer body is logged, so the registration answer (pairing) never is.
--
-- DriverWorks calls: C4:url (through common/https.lua), C4:SetTimer and
-- C4:GetTime (both injectable: deps.timer(ms, fn), deps.now()).

local client = {}
client.__index = client

client.BASE = "/api/v1"
client.CA_BUNDLE = "certs/hsb_ca.pem"
client.MAX_WAITING = 8        -- waiting behind the one in flight; one more is "busy"
client.SLOT_GRACE_S = 10      -- beyond a request's own timeout, before its place is freed regardless
client.TOKEN_MAX = 512        -- the most bytes of a token taken from the box (R5 §3.2)
client.ERR_MAX = 160          -- the most bytes of an err text
client.BUSY = "busy"
client.NOT_PAIRED = "not paired"
client.NO_ADDRESS = "no box address"
client.INVALID_PATH = "invalid request path"

-- The https instance the box uses (§3.1): its bundle, the Bearer header, one
-- keyed request at a time, short timeouts (C2: connect 3 s, total 6 s) and
-- bodies over 256 KB refused before decoding (R5 §3.2, N-4).
function client.default_https(log)
	return require("common.https").new({
		ca_bundle = client.CA_BUNDLE,
		header_key = { name = "Authorization", prefix = "Bearer " },
		max_keyed = 1,
		timeout = 6,
		connect_timeout = 3,
		max_body = 262144,
		log_prefix = "Sync box: ",
		log = log,
	})
end

-- A token the box issued, fit to travel as a header value: 1 to TOKEN_MAX
-- printable ASCII characters, no space (R5 §3.2; the token looks like base64
-- text, R1 §2.1 [community]).
function client.usable_token(t)
	return type(t) == "string" and #t >= 1 and #t <= client.TOKEN_MAX and not t:find("[^!-~]")
end

-- An address the URL can carry without moving the request elsewhere: a host
-- name or an IPv4 address, letters, digits, dots and hyphens, with an
-- optional port; never "@", "/", "?", "#" or a space (security review
-- 2026-10-25, finding 10, for paths; the same reasoning for the host).
function client.valid_address(a)
	if type(a) ~= "string" or #a < 1 or #a > 253 then
		return false
	end
	return a:match("^[%w%.%-]+$") ~= nil or a:match("^[%w%.%-]+:%d+$") ~= nil
end

-- A path after /api/v1: "" (the whole state) or "/" and letters, digits,
-- "-", "_" and "/" (no dot, no query): every path is a literal of the driver
-- or an id the box reported (R5 §3.5, D-2).
local function valid_path(path)
	return type(path) == "string" and (path == "" or path:match("^/[%w%-_/]*$") ~= nil)
end

local function default_timer(ms, fn)
	return C4:SetTimer(ms, fn)
end

local function default_now()
	return C4:GetTime()
end

local function noop() end

-- `text` with every token the client holds or has in flight replaced by
-- "<token>".
local function cut_token(self, text, sent)
	text = tostring(text)
	local in_flight = self.in_flight and self.in_flight.sent
	for _, token in ipairs({ sent or false, in_flight or false, self.tok or false }) do
		if token and text:find(token, 1, true) then
			text = text:gsub(token:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"), "<token>")
		end
	end
	return text
end

-- The logger of the default https instance: each line formatted, the token
-- cut out of it (cut_token), then written. common/https.lua never logs a
-- header, but its failure lines carry curl's error text, which this module
-- does not control.
local function token_free_log(self, log)
	local out = {}
	for _, level in ipairs({ "error", "warn", "info", "debug" }) do
		out[level] = function(fmt, ...)
			if log.enabled and not log.enabled(level) then
				return
			end
			local ok, line = pcall(string.format, fmt, ...)
			log[level]("%s", cut_token(self, ok and line or fmt))
		end
	end
	out.enabled = function(level)
		return log.enabled == nil or log.enabled(level)
	end
	return out
end

function client.new(deps)
	deps = deps or {}
	local self = setmetatable({
		log = deps.log or require("common.log"),
		timer = deps.timer or default_timer,
		now = deps.now or default_now,
		addr = nil,
		tok = nil,
		trust = false,
		waiting = {},
		in_flight = nil,
		pumping = false,
		watchdog = nil,
	}, client)
	self.https = deps.https or client.default_https(token_free_log(self, self.log))
	if deps.address ~= nil then
		self:set_address(deps.address)
	end
	if deps.token ~= nil then
		self:set_token(deps.token)
	end
	return self
end

-- Text a peer sent, cut for a row (the https instance's peer_text).
function client:peer_text(value, max)
	return self.https.peer_text(value, max)
end

-- True when a request that got no answer failed because the peer's
-- certificate did not verify against the bundle (curl 51 or 60).
function client:certificate_failure(err_code)
	return self.https.certificate_failure({ err_code = err_code })
end

function client:get_address()
	return self.addr
end

function client:has_token()
	return self.tok ~= nil
end

function client:is_trusted()
	return self.trust
end

-- Requests in flight and waiting.
function client:pending()
	return (self.in_flight and 1 or 0) + #self.waiting
end

local pump -- below

-- Answer a request at once, before it was queued.
local function refuse(cb, err)
	cb(false, nil, nil, err)
	return nil
end

-- Answer and drop every waiting keyed request (the token was cleared).
local function fail_waiting_keyed(self, err)
	local kept, dropped = {}, {}
	for _, entry in ipairs(self.waiting) do
		if entry.keyed then
			dropped[#dropped + 1] = entry
		else
			kept[#kept + 1] = entry
		end
	end
	self.waiting = kept
	for _, entry in ipairs(dropped) do
		entry.finished = true
		local ok, why = pcall(entry.cb, false, nil, nil, err)
		if not ok then
			self.log.warn("Sync box: %s %s: its callback failed: %s", entry.method, entry.path, tostring(why))
		end
	end
end

function client:set_address(a)
	local ok = true
	if a ~= nil and not client.valid_address(a) then
		self.log.warn("Sync box: address refused: %s", self:peer_text(a, 64))
		a, ok = nil, false
	end
	if a ~= self.addr then
		self.addr = a
		self.trust = false
	end
	pump(self)
	return ok
end

function client:set_token(t)
	local ok = true
	if t ~= nil and not client.usable_token(t) then
		self.log.warn("Sync box: a token that cannot be sent was refused") -- never its value
		t, ok = nil, false
	end
	if t ~= self.tok then
		self.tok = t
		self.trust = false
	end
	if t == nil then
		fail_waiting_keyed(self, client.NOT_PAIRED)
	end
	return ok
end

function client:set_trusted(trusted)
	self.trust = trusted == true and self.addr ~= nil
	if self.trust then
		pump(self)
	end
end

-- `text` without the token in it, cut to ERR_MAX bytes.
local function scrub(self, text, sent)
	return self.https.peer_text(cut_token(self, text, sent), client.ERR_MAX)
end

-- The callback's arguments from a common/https.lua result.
local function outcome(self, entry, r)
	local status, decoded = r.code, r.json
	local ok, err = false, nil
	if r.ok then
		local empty = r.body == nil or r.body == ""
		if decoded ~= nil then
			ok = true
		elseif empty and (entry.method == "PUT" or entry.method == "DELETE") then
			ok = true
		else
			err = empty and "empty answer" or "the answer is not JSON"
		end
	else
		err = r.err or "failed"
		-- The box's own error (R1 §2.1, §2.14): {"code": n, "message": "..."}.
		if status and type(decoded) == "table" and decoded.code ~= nil then
			err = string.format("HTTP %s, box error %s: %s", tostring(status),
				self.https.peer_text(decoded.code, 8), self.https.peer_text(decoded.message or "", 96))
		end
	end
	return ok, status, decoded, err and scrub(self, err, entry.sent) or nil, r.err_code
end

-- Hand the result to the request's caller; a raise there is logged and
-- stops nothing.
local function deliver(self, entry, r)
	local fine, why
	if entry.raw then
		fine, why = pcall(entry.cb, r)
	else
		fine, why = pcall(entry.cb, outcome(self, entry, r))
	end
	if not fine then
		self.log.warn("Sync box: %s %s: its callback failed: %s", entry.method, entry.path, scrub(self, why, entry.sent))
	end
end

local function finish(self, entry, r)
	if entry.finished then
		return
	end
	entry.finished = true
	if self.in_flight == entry then
		self.in_flight = nil
	end
	if not entry.cancelled then
		deliver(self, entry, r)
	end
	entry.sent = nil -- the token's copy (for scrub) goes with the request
	pump(self)
end

-- Free the place of a request whose end is overdue (see the header).
local function reap(self)
	local entry = self.in_flight
	if entry and entry.deadline and self.now() >= entry.deadline then
		self.log.warn("Sync box: %s %s: no end reported %d s after its timeout; its place is freed", entry.method,
			entry.path, client.SLOT_GRACE_S)
		self.in_flight = nil
		if entry.transfer then
			pcall(function() entry.transfer:Cancel() end)
		end
		finish(self, entry, { ok = false, err = "no end reported" })
	end
end

local function cancel_watchdog(self)
	if self.watchdog then
		pcall(function() self.watchdog:Cancel() end)
		self.watchdog = nil
	end
end

-- While requests wait behind one in flight: a timer at its deadline.
local function arm_watchdog(self)
	local entry = self.in_flight
	if not entry or #self.waiting == 0 then
		return cancel_watchdog(self)
	end
	if self.watchdog then
		return
	end
	local ok, timer = pcall(self.timer, math.max(1, entry.deadline - self.now()), function()
		self.watchdog = nil
		reap(self)
		pump(self)
	end)
	self.watchdog = ok and timer or nil
end

-- The first waiting request that may go now: a keyed one only while the
-- client holds a token and is trusted at its address.
local function first_ready(self)
	for i, entry in ipairs(self.waiting) do
		if entry.keyed then
			if self.tok and self.trust and self.addr then
				return i
			end
		elseif entry.address or self.addr then
			return i
		end
	end
	return nil
end

local function start(self, entry)
	local https = self.https
	local req
	if entry.raw then
		req = {}
		for k, v in pairs(entry.raw) do
			req[k] = v
		end
		req.key = nil -- never a token with another bundle (common/tlscheck.lua)
		req.ip = req.ip or self.addr
	else
		req = {
			ip = entry.address or self.addr,
			path = client.BASE .. entry.path,
			method = entry.method,
			body = entry.body,
			timeout = entry.timeout,
			quiet = entry.quiet,
			key = entry.keyed and self.tok or nil,
		}
		entry.sent = req.key
	end
	local timeout = tonumber(req.timeout) or tonumber(https.DEFAULT_TIMEOUT) or 6
	entry.deadline = self.now() + (timeout + client.SLOT_GRACE_S) * 1000
	self.in_flight = entry
	local ok, transfer = pcall(https.request, req, function(r)
		finish(self, entry, r)
	end)
	if not ok then
		finish(self, entry, { ok = false, err = "could not start transfer: " .. tostring(transfer) })
	elseif not entry.finished then
		entry.transfer = transfer
	end
end

pump = function(self)
	if self.pumping then
		return -- the loop below goes on
	end
	self.pumping = true
	reap(self)
	while not self.in_flight do
		local index = first_ready(self)
		if not index then
			break
		end
		start(self, table.remove(self.waiting, index))
	end
	self.pumping = false
	arm_watchdog(self)
end

-- A handle whose Cancel() drops the request: out of the queue while it
-- waits; once started, its transfer is cancelled and its place freed at
-- once (C4LuaUrl:Cancel may not end it, bridge/stream.lua rule 2; a late end
-- is ignored). Its callback is never called.
local function handle_of(self, entry)
	return {
		Cancel = function(handle)
			if entry.finished or entry.cancelled then
				return handle
			end
			entry.cancelled = true
			for i, e in ipairs(self.waiting) do
				if e == entry then
					table.remove(self.waiting, i)
					return handle
				end
			end
			if self.in_flight == entry then
				self.in_flight = nil
				entry.finished, entry.sent = true, nil
				if entry.transfer then
					pcall(function() entry.transfer:Cancel() end)
				end
				pump(self)
			end
			return handle
		end,
	}
end

local function enqueue(self, entry)
	reap(self)
	if #self.waiting >= client.MAX_WAITING then
		self.log.warn("Sync box: %s %s refused: %d requests wait already", entry.method, entry.path, #self.waiting)
		return refuse(entry.cb, client.BUSY)
	end
	self.waiting[#self.waiting + 1] = entry
	pump(self)
	return handle_of(self, entry)
end

function client:request(method, path, body, cb, opts)
	cb = cb or noop
	opts = type(opts) == "table" and opts or {}
	if not valid_path(path) then
		self.log.warn("Sync box: %s refused: %s", method, client.INVALID_PATH)
		return refuse(cb, client.INVALID_PATH)
	end
	local keyed = opts.unkeyed ~= true
	local address = opts.address
	if address ~= nil then
		if keyed and address ~= self.addr then
			return refuse(cb, "a keyed request goes only to the paired box's address")
		elseif not client.valid_address(address) then
			return refuse(cb, "invalid address")
		end
	elseif not self.addr then
		return refuse(cb, client.NO_ADDRESS)
	end
	if keyed and not self.tok then
		return refuse(cb, client.NOT_PAIRED)
	end
	return enqueue(self, {
		method = method,
		path = path,
		body = body,
		cb = cb,
		keyed = keyed,
		address = (not keyed) and address or nil,
		timeout = tonumber(opts.timeout),
		quiet = opts.quiet == true or nil,
	})
end

function client:get(path, cb, opts, more)
	return self:request("GET", path, nil, cb, opts or more)
end

function client:put(path, body, cb, opts)
	return self:request("PUT", path, body, cb, opts)
end

function client:post(path, body, cb, opts)
	return self:request("POST", path, body, cb, opts)
end

function client:delete(path, cb, opts, more)
	return self:request("DELETE", path, nil, cb, opts or more)
end

-- A common/https.lua request (req as https.request takes it: ip, path,
-- tls, timeout, quiet; never key) through this client's queue, its
-- callback getting https's own result table. For the TLS self-check, so that
-- its decoy request is one of the box's one-at-a-time requests too.
function client:raw(req, callback)
	local entry = {
		raw = req,
		method = req.method or "GET",
		path = tostring(req.path),
		cb = callback or noop,
		keyed = false,
		address = req.ip,
	}
	if not (entry.address or self.addr) then
		callback({ ok = false, err = client.NO_ADDRESS })
		return nil
	end
	if entry.address ~= nil and not client.valid_address(entry.address) then
		callback({ ok = false, err = "invalid address" })
		return nil
	end
	return enqueue(self, entry)
end

-- What common/tlscheck.lua takes as its `https`: request through the queue
-- (raw), certificate_failure from the instance (syncbox/identity.lua).
function client:tls_transport()
	return {
		request = function(req, callback)
			return self:raw(req, callback)
		end,
		certificate_failure = function(r)
			return self.https.certificate_failure(r)
		end,
	}
end

-- Drop every request: the waiting ones and the one in flight, none of their
-- callbacks called (OnDriverDestroyed).
function client:cancel_all()
	for _, entry in ipairs(self.waiting) do
		entry.cancelled = true
	end
	self.waiting = {}
	local entry = self.in_flight
	if entry then
		entry.cancelled = true
		self.in_flight = nil
		if entry.transfer then
			pcall(function() entry.transfer:Cancel() end)
		end
	end
	cancel_watchdog(self)
end

return client
