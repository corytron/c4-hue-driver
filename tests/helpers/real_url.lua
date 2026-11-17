-- A real C4:url transport for the fake runtime (#547, docs/fakebox-design.md
-- §6): every transfer a driver starts goes over real HTTPS through the curl
-- command, the library Director's C4:url is built on, and its answer comes
-- back through the transfer's OnHeaders, OnBodyChunk or OnBody and OnDone,
-- in Director's order, on the runtime's fake clock. The end-to-end harness
-- (tests/e2e/syncbox_e2e.lua, tools/e2e_syncbox.sh) runs the box driver with
-- it against the Python fake box (tools/fakebox/). Not for busted specs: it
-- needs curl and a listening server.
--
--   local real_url = require("helpers.real_url")
--   local T = real_url.new(opts)
--     opts.archive_dir  where the driver's .c4z is "extracted": a relative
--                       ssl_cabundle is read from <archive_dir>/<path>, as
--                       Director prefixes it with the archive's directory
--                       (docs/design.md "Certificates"). Default
--                       "src/hue_syncbox" (the repository's bundle).
--     opts.routes       { ["10.0.2.150"] = "127.0.0.1:8443", ... }: the
--                       address in a URL (host, or host:port) and where curl
--                       really connects (--connect-to), so the release
--                       driver's port-443 URLs reach a fake on another port.
--                       A route must lead to the loopback interface.
--     opts.time_scale   real seconds per fake second (default 1): curl's
--                       timeouts are the transfer's options times this, and a
--                       real duration is divided by it on the fake clock.
--     opts.curl         the curl command (default "curl")
--     opts.trace        function(line), every exchange in one line (never a
--                       header: the token is not in it)
--     opts.c4           the runtime whose clock delivers the answers (default
--                       the global C4 when the transfer starts)
--   T:install(fake)     hand T to the fake runtime: fake.set_url_transport
--                       when the runtime has it (agent F3's hook), else
--                       T:wrap(C4) of the current runtime; call it after
--                       every fake.load_driver
--   T:uninstall(fake)   fake.set_url_transport(nil) again
--   T:wrap(c4)          the fallback: c4.url makes the fake runtime's
--                       transfers, whose Get, Post, Put, Delete and Custom
--                       come here instead of to the fake's own answers
--   T:route(address, target)  add, change (target nil: remove) a route
--   T:perform(method, url, data, headers, options)
--                       one exchange now, no callbacks: { exit, text,
--                       detail, responses = {{code, headers, body}},
--                       ms, attempts, name, target }
--   T.history           every transfer (each hop of a redirect): { method,
--                       url, path, data, target, name, status, err_code,
--                       detail, ms, attempts, settled, cancelled, aborted,
--                       redirects, redirected }; T:since(n) those after the
--                       n-th (see T:deliver for settled). data is the request
--                       body as sent (a box's bodies carry no token: that
--                       goes in a header, which is never kept)
--   T:close()           removes the temporary directory
--
-- What it does as Director does [verified: SDK 35_url/_8-OnDone,
-- _9-OnHeaders, _7-OnBodyChunk, _6-OnBody, _12-SetOption; docs/design.md,
-- the OS 3.4.2 hardware notes]:
--   - OnHeaders once per response (redirects included), then the body:
--     OnBodyChunk when set (no body aggregated), else response.body, then
--     OnBody, then OnDone(transfer, responses, errCode, errMsg) once. A true
--     from OnHeaders, OnBodyChunk or OnBody aborts: OnDone gets -1.
--   - errCode is curl's exit code and errMsg curl's text for it (the
--     controller's 60 read "SSL peer certificate or SSH remote key was not
--     OK", docs/design.md); curl's own detailed message goes to T.history.
--   - ssl_cabundle relative to the archive and instead of the system's CAs
--     (--cacert, and --capath an empty directory, since curl on Ubuntu reads
--     /etc/ssl/certs besides --cacert); an absolute or unreadable path ends
--     with 77, as on OS 3.4.2. ssl_verify_peer is never turned off (no -k):
--     a transfer that asks for it fails with 2, as do ssl_cacerts and client
--     certificates, which no box request uses.
--   - ssl_verify_host = false: the chain is verified, the name is not. The
--     curl command has no switch for that alone (-k drops both), so the URL
--     names the certificate's subject instead of the address and
--     --connect-to sends it to the address: curl verifies the chain against
--     the bundle and then compares the name with itself. The subject is
--     learnt from curl: the first handshake with a target names the address,
--     curl refuses it with "certificate subject name 'X' does not match
--     target hostname" before any HTTP is sent, and the transfer is repeated
--     once with X (kept per target, learnt again when another certificate
--     answers there). The Host header still carries the URL's address, as
--     Director sends it. Limits: a certificate whose subject is not a host
--     name, or that has a DNS subjectAltName (curl then names no subject), is
--     refused with 60 where Director would accept it. A box's leaf names its
--     id as CN (docs/syncbox-architecture-research.md §2.2; aiohuesyncbox
--     checks it with hostname_checks_common_name, which needs a leaf without
--     a DNS subjectAltName [inferred]); the fake's has none
--     (tools/fakebox/ca.py).
--   - timeout and connect_timeout (defaults 300 and 5 s, SDK _12-SetOption)
--     become --max-time and --connect-timeout; a timeout is delivered at the
--     option's time on the fake clock (28). fail_on_error, true unless set
--     false, becomes --fail (22).
--   - Redirects are followed by Director's libcurl, OnHeaders running once
--     per response: here each 3xx is delivered and, unless OnHeaders aborted,
--     its Location requested next (POST becomes GET after 301, 302 and 303,
--     libcurl's default), at most MAX_REDIRECTS.
--   - A transfer started inside another one's OnHeaders or OnBodyChunk fails
--     at once with 2 "Failed initialization" (docs/design.md, OS 3.4.2).
--   - Each transfer is performed when Get()/Post()/... is called (curl
--     blocks; a host's transfers are serialized as on OS 3.4.2) and its
--     callbacks come later, at start + its duration on the fake clock, from
--     a timer of the runtime (c4.timers, url_transport = true; no SetTimer
--     call recorded), so c4.advance delivers them. A transfer the driver
--     cancelled before then gets no callback [assumed: Director's one-shot
--     transfers; a stream's Cancel does not end it, docs/design.md].
-- Other assumptions: no User-Agent header (libcurl sends none unless told;
-- what Director sets is [assumed]); response header names as the server
-- wrote them, repeated ones joined with ", " [assumed]; 1xx responses are not
-- reported [assumed].
--
-- Safety: a transfer goes only to a routed address or to the loopback
-- interface. Any other address ends with 7 "Couldn't connect to server"
-- without running curl, so a test never reaches the LAN. Headers and bodies
-- go to curl through files in a private temporary directory (-H @file,
-- --data-binary @file), never on its command line, so the token is not in a
-- process listing; each file is removed after its transfer.

local real_url = {}

real_url.MAX_REDIRECTS = 10
real_url.MAX_ATTEMPTS = 2           -- the first handshake that learns the subject, then the transfer
real_url.FAILED_INIT_MS = 2         -- docs/design.md: curl 2 came after 2 ms

-- curl's text for its codes (curl_easy_strerror), as Director hands them to
-- OnDone; the rest get curl's own message.
real_url.CURL_TEXT = {
	[1] = "Unsupported protocol",
	[2] = "Failed initialization",
	[3] = "URL using bad/illegal format or missing URL",
	[6] = "Couldn't resolve host name",
	[7] = "Couldn't connect to server",
	[18] = "Transferred a partial file",
	[22] = "HTTP response code said error",
	[28] = "Timeout was reached",
	[35] = "SSL connect error",
	[47] = "Number of redirects hit maximum amount",
	[52] = "Server returned nothing (no headers, no data)",
	[55] = "Failed sending data to the peer",
	[56] = "Failure when receiving data from the peer",
	[60] = "SSL peer certificate or SSH remote key was not OK",
	[77] = "Problem with the SSL CA cert (path? access rights?)",
}

local T = {}
T.__index = T

-- One shell word.
local function q(s)
	return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

local function slurp(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end

local function spit(path, data)
	local f = assert(io.open(path, "wb"))
	f:write(data)
	f:close()
end

local function readable(path)
	local f = io.open(path, "rb")
	if f then
		f:close()
		return true
	end
	return false
end

local function is_loopback(host)
	return host == "localhost" or host:match("^127%.%d+%.%d+%.%d+$") ~= nil
end

local function valid_name(name)
	return type(name) == "string" and #name >= 1 and #name <= 253 and name:match("^[%w][%w%.%-]*$") ~= nil
end

-- scheme, host, port, path and authority of a URL; nil and a reason for
-- anything curl and Director would not take the same way here (user info,
-- IPv6 literals, other schemes).
local function parse_url(url)
	local scheme, rest = tostring(url):match("^(%a[%w+.%-]*)://(.*)$")
	if not scheme then
		return nil, "not a URL"
	end
	scheme = scheme:lower()
	local default = ({ https = 443, http = 80 })[scheme]
	if not default then
		return nil, "scheme " .. scheme
	end
	local authority, path = rest:match("^([^/?#]*)(.*)$")
	if authority:find("@", 1, true) then
		return nil, "user info in the URL"
	end
	local host, port = authority:match("^(.-):(%d+)$")
	host = host or authority
	if not valid_name(host) then
		return nil, "host " .. host
	end
	port = tonumber(port) or default
	if path == "" or path:sub(1, 1) ~= "/" then
		path = "/" .. path
	end
	return { scheme = scheme, host = host:lower(), port = port, path = path, authority = authority,
		default_port = default }
end

-- "127.0.0.1:8443" -> "127.0.0.1", 8443.
local function split_target(target)
	local host, port = tostring(target):match("^([%w%.%-]+):(%d+)$")
	return host, tonumber(port)
end

function real_url.new(opts)
	opts = opts or {}
	local self = setmetatable({
		archive_dir = opts.archive_dir or "src/hue_syncbox",
		routes = {},
		names = {},           -- target -> the certificate subject last learnt there
		time_scale = tonumber(opts.time_scale) or 1,
		curl = opts.curl or "curl",
		trace = opts.trace,
		c4 = opts.c4,
		history = {},
		in_callback = 0,      -- inside an OnHeaders or OnBodyChunk
		seq = 0,
	}, T)
	assert(self.time_scale > 0, "real_url.new: time_scale must be above 0")
	for address, target in pairs(opts.routes or {}) do
		self:route(address, target)
	end
	local p = assert(io.popen("mktemp -d \"${TMPDIR:-/tmp}/c4e2e-url.XXXXXX\""))
	self.dir = p:read("*l")
	p:close()
	assert(self.dir and self.dir ~= "", "real_url.new: mktemp -d failed")
	self.capath = self.dir .. "/capath"
	assert(os.execute("mkdir -m 700 " .. q(self.capath)) == 0, "real_url.new: mkdir failed")
	return self
end

function T:close()
	if self.dir then
		os.execute("rm -rf " .. q(self.dir))
		self.dir = nil
	end
end

function T:route(address, target)
	address = tostring(address):lower()
	if target == nil then
		self.routes[address] = nil
		return
	end
	local host, port = split_target(target)
	assert(host and port, "real_url: a route's target is host:port, not " .. tostring(target))
	assert(is_loopback(host), "real_url: a route leads to the loopback interface only, not " .. tostring(target))
	self.routes[address] = host .. ":" .. port
end

-- Where curl connects for this URL, or nil (refused: see Safety).
function T:target_of(u)
	local routed = self.routes[u.host .. ":" .. u.port] or self.routes[u.host]
	if routed then
		return routed
	end
	if is_loopback(u.host) then
		return u.host .. ":" .. u.port
	end
	return nil
end

-- The responses of a -D dump: { code, headers } per final or redirect
-- response, 1xx left out.
local function parse_headers(text)
	local responses, current = {}, nil
	for line in (text or ""):gmatch("([^\n]*)\n") do
		line = line:gsub("\r$", "")
		local code = line:match("^HTTP/%S+%s+(%d%d%d)")
		if code then
			current = { code = tonumber(code), headers = {} }
			responses[#responses + 1] = current
		elseif current and line ~= "" then
			local name, value = line:match("^([^:%s]+):%s*(.-)%s*$")
			if name then
				local old = current.headers[name]
				current.headers[name] = old and (old .. ", " .. value) or value
			end
		end
	end
	local out = {}
	for _, r in ipairs(responses) do
		if r.code >= 200 then
			out[#out + 1] = r
		end
	end
	return out
end

local function seconds(value)
	return string.format("%.3f", value)
end

-- The TLS arguments of a transfer's options, or nil, an exit code and why.
function T:tls_args(options)
	local args = {}
	if options.ssl_verify_peer == false then
		return nil, 2, "ssl_verify_peer false is not emulated (the e2e transport never uses -k)"
	end
	for _, name in ipairs({ "ssl_cacerts", "ssl_cert", "ssl_key", "ssl_passwd" }) do
		if options[name] ~= nil then
			return nil, 2, name .. " is not emulated by the e2e transport"
		end
	end
	local bundle = options.ssl_cabundle
	if bundle ~= nil then
		bundle = tostring(bundle)
		if bundle:sub(1, 1) == "/" then
			return nil, 77, "an absolute ssl_cabundle fails on OS 3.4.2 (docs/design.md)"
		end
		local path = self.archive_dir .. "/" .. bundle
		if not readable(path) then
			return nil, 77, "ssl_cabundle " .. bundle .. " is not in the archive (" .. path .. ")"
		end
		args[#args + 1] = "--cacert " .. q(path)
		args[#args + 1] = "--capath " .. q(self.capath)
	end
	return args
end

-- One curl run. Returns exit, http code, ms, curl's message.
function T:run_curl(args, url)
	local cmd = table.concat({ q(self.curl), "-q -s -g --noproxy '*'", table.concat(args, " "),
		"-w", q("\nC4E2E-W %{exitcode} %{http_code} %{time_total}\nC4E2E-M %{errormsg}\n"), q(url),
		"2>/dev/null; echo \"C4E2E-EXIT $?\"" }, " ")
	local p = assert(io.popen(cmd))
	local out = p:read("*a")
	p:close()
	local exit = tonumber(out:match("C4E2E%-EXIT (%d+)")) or 2
	local _, http, total = out:match("C4E2E%-W (%d+) (%d+) ([%d%.]+)")
	local msg = out:match("C4E2E%-M ([^\n]*)") or ""
	return exit, tonumber(http), math.floor((tonumber(total) or 0) * 1000 + 0.5), msg
end

-- One exchange (no redirect followed): see the header, T:perform.
function T:exchange(method, url, data, headers, options)
	options = options or {}
	local hop = { method = method, url = url, responses = {}, attempts = 0, ms = 0 }
	local function fail(exit, detail)
		hop.exit, hop.detail = exit, detail
		hop.text = real_url.CURL_TEXT[exit] or detail
		return hop
	end
	local u, why = parse_url(url)
	if not u then
		return fail(3, "the e2e transport takes no such URL: " .. tostring(why))
	end
	hop.path = u.path
	if not tostring(method):match("^[A-Z]+$") then
		return fail(2, "method " .. tostring(method))
	end
	local target = self:target_of(u)
	if not target then
		return fail(7, "the e2e transport connects only to routed and loopback addresses, not " .. u.host)
	end
	hop.target = target
	local thost, tport = split_target(target)
	local args = {}
	if u.scheme == "https" then
		local tls, code, detail = self:tls_args(options)
		if not tls then
			return fail(code, detail)
		end
		for _, a in ipairs(tls) do
			args[#args + 1] = a
		end
	end
	local timeout, connect = tonumber(options.timeout) or 300, tonumber(options.connect_timeout) or 5
	if timeout > 0 then
		args[#args + 1] = "--max-time " .. seconds(timeout * self.time_scale)
	end
	if connect > 0 then
		args[#args + 1] = "--connect-timeout " .. seconds(connect * self.time_scale)
	end
	if options.fail_on_error ~= false then
		args[#args + 1] = "--fail"
	end
	self.seq = self.seq + 1
	local base = string.format("%s/t%d", self.dir, self.seq)
	local hfile, dfile, ofile, rfile = base .. ".hdr", base .. ".data", base .. ".body", base .. ".req"
	-- Request headers through a file: the token never on a command line.
	local lines = { "Host: " .. u.authority, "User-Agent:" }
	for name, value in pairs(headers or {}) do
		name, value = tostring(name), tostring(value)
		if not name:match("^[%w%-]+$") or value:find("[%c]") then
			return fail(2, "a request header the e2e transport cannot send")
		end
		if name:lower() ~= "host" then
			lines[#lines + 1] = name .. ": " .. value
		end
	end
	spit(rfile, table.concat(lines, "\n") .. "\n")
	args[#args + 1] = "-H @" .. q(rfile)
	if method == "POST" and data ~= nil then
		spit(dfile, tostring(data))
		args[#args + 1] = "--data-binary @" .. q(dfile)
	elseif method ~= "GET" then
		args[#args + 1] = "-X " .. method
		if data ~= nil then
			spit(dfile, tostring(data))
			args[#args + 1] = "--data-binary @" .. q(dfile)
		end
	end
	args[#args + 1] = "-D " .. q(hfile)
	args[#args + 1] = "-o " .. q(ofile)
	local verify_name = u.scheme == "https" and options.ssl_verify_host == false
	local tried = {}
	local exit, http, ms, msg
	repeat
		local name = verify_name and (self.names[target] or u.host) or u.host
		tried[name] = true
		hop.name = name
		os.remove(hfile)
		os.remove(ofile)
		local run = {}
		for _, a in ipairs(args) do
			run[#run + 1] = a
		end
		run[#run + 1] = "--connect-to " .. q(string.format("%s:%d:%s:%d", name, u.port, thost, tport))
		local curl_url = string.format("%s://%s:%d%s", u.scheme, name, u.port, u.path)
		exit, http, ms, msg = self:run_curl(run, curl_url)
		hop.attempts = hop.attempts + 1
		hop.ms = hop.ms + ms
		local learnt = verify_name and exit == 60 and msg:match("subject name '([^']+)' does not match target host")
		if learnt and valid_name(learnt) and not tried[learnt:lower()] and not tried[learnt] then
			self.names[target] = learnt
		else
			break
		end
	until hop.attempts >= real_url.MAX_ATTEMPTS
	hop.exit, hop.detail, hop.http = exit, msg, http
	hop.text = exit ~= 0 and (real_url.CURL_TEXT[exit] or msg) or nil
	hop.responses = parse_headers(slurp(hfile))
	local body = slurp(ofile)
	if #hop.responses > 0 then
		hop.responses[#hop.responses].body = body or ""
	end
	for _, f in ipairs({ hfile, dfile, ofile, rfile }) do
		os.remove(f)
	end
	return hop
end

-- One exchange now, redirects not followed, no callbacks (a harness's own
-- probe, the negative check of §6).
function T:perform(method, url, data, headers, options)
	return self:exchange(method, url, data, headers, options)
end

-- Delivery on the fake clock ------------------------------------------------------

-- A one-shot timer of the runtime, as the fake box's own timeouts are made
-- (fake_c4.lua box_timeout): in c4.timers, no SetTimer call recorded.
local function schedule(c4, ms, fn)
	ms = math.max(1, math.floor(ms))
	local timer = { delay = ms, repeating = false, active = true, armed_at = c4.now_ms, due = c4.now_ms + ms,
		url_transport = true }
	function timer:Cancel()
		self.active = false
	end
	timer.callback = fn
	table.insert(c4.timers, timer)
	return timer
end

-- The hop's duration on the fake clock: a timeout at its option's time, else
-- the real time scaled, at least 1 ms and at most the transfer's timeout.
function T:fake_ms(hop, options)
	local timeout = (tonumber(options.timeout) or 300) * 1000
	if hop.exit == 28 then
		local detail = tostring(hop.detail)
		if detail:find("^Connection timed out") or detail:find("^Failed to connect") then
			return math.min(timeout, (tonumber(options.connect_timeout) or 5) * 1000)
		end
		return timeout
	end
	return math.max(1, math.min(timeout, hop.ms / self.time_scale))
end

-- Call a callback that may start a transfer (curl 2 inside it, see header).
function T:guarded(fn, ...)
	self.in_callback = self.in_callback + 1
	local ok, err = pcall(fn, ...)
	self.in_callback = self.in_callback - 1
	if not ok then
		error(err, 0)
	end
end

local function abort_text()
	return "Operation was aborted by an application callback"
end

-- Where a redirect leads: the next method, URL and body (libcurl's defaults).
local function redirect_of(hop, method, data, location)
	local u = parse_url(hop.url)
	local next_url
	if location:match("^%a[%w+.%-]*://") then
		next_url = location
	elseif location:sub(1, 2) == "//" then
		next_url = u.scheme .. ":" .. location
	elseif location:sub(1, 1) == "/" then
		next_url = u.scheme .. "://" .. u.authority .. location
	else
		next_url = u.scheme .. "://" .. u.authority .. (u.path:gsub("[^/]*$", "")) .. location
	end
	local code = hop.responses[#hop.responses].code
	if code == 303 and method ~= "HEAD" or (method == "POST" and (code == 301 or code == 302)) then
		return "GET", next_url, nil
	end
	return method, next_url, data
end

function T:record(t, hop)
	local entry = { method = t.method, url = t.url, path = hop.path, data = hop.data, target = hop.target,
		name = hop.name,
		status = #hop.responses > 0 and hop.responses[#hop.responses].code or nil,
		err_code = hop.exit ~= 0 and hop.exit or nil, detail = hop.exit ~= 0 and hop.detail or nil,
		ms = hop.ms, attempts = hop.attempts }
	self.history[#self.history + 1] = entry
	if self.trace then
		self.trace(string.format("%s %s -> %s%s (%d ms, %d handshake%s%s)", t.method, tostring(hop.url),
			entry.status and ("HTTP " .. entry.status) or "no answer",
			entry.err_code and (", curl " .. entry.err_code .. ": " .. tostring(entry.detail)) or "",
			hop.ms, hop.attempts, hop.attempts == 1 and "" or "s",
			hop.target and (" via " .. hop.target) or ""))
	end
	return entry
end

-- Hand one hop to the transfer's callbacks (see the header). Its history
-- entry is settled (entry.settled) once the driver has had everything of it:
-- OnDone called, the next hop of a redirect started (entry.redirects; that
-- hop has an entry of its own), or the transfer found cancelled
-- (entry.cancelled, no callback). A harness reads the driver's state only
-- for settled entries: an entry's status is known when curl returns, before
-- its callbacks are due on the fake clock.
function T:deliver(c4, t, hop, entry, hops)
	if t.cancelled and not t.aborted then
		entry.cancelled, entry.settled = true, true
		return
	end
	local function done(code, text)
		entry.settled = true
		return t:done(code, text)
	end
	local responses = hop.responses
	if hop.exit ~= 0 and #responses == 0 then
		return done(hop.exit, hop.text)
	end
	local last
	for _, r in ipairs(responses) do
		last = t:respond_headers(r.code, r.headers)
		if t.aborted then
			entry.aborted = true
			return done(-1, abort_text())
		end
	end
	local code = last and last.code
	local location = last and last.headers and (last.headers.Location or last.headers.location)
	if hop.exit == 0 and code and code >= 300 and code <= 399 and location then
		if hops >= real_url.MAX_REDIRECTS then
			return done(47, real_url.CURL_TEXT[47])
		end
		local method, url, data = redirect_of(hop, hop.method, hop.data, location)
		local next_hop = self:exchange(method, url, data, t.headers, t.options)
		next_hop.data = data
		entry.redirects, entry.settled = 1, true
		local next_entry = self:record(t, next_hop)
		next_entry.redirected = true
		schedule(c4, self:fake_ms(next_hop, t.options), function()
			self:deliver(c4, t, next_hop, next_entry, hops + 1)
		end)
		return
	end
	local body = last and responses[#responses].body or ""
	if t.callbacks.chunk then
		if body ~= "" then
			t:chunk(body)
		end
	elseif last then
		last.body = body
		if t.callbacks.body and t.callbacks.body(t, last) then
			t.cancelled, t.aborted = true, true
		end
	end
	if t.aborted then
		entry.aborted = true
		return done(-1, abort_text())
	end
	return done(hop.exit, hop.exit ~= 0 and hop.text or nil)
end

-- A transfer the driver just started (t.method, t.url, t.data, t.headers,
-- t.options and the callbacks set): performed now, delivered later.
function T:start(t, c4)
	c4 = c4 or self.c4 or rawget(_G, "C4")
	assert(type(c4) == "table" and c4.timers, "real_url: no fake runtime to deliver on")
	-- The fake transfer's respond_headers and chunk run the callbacks; count
	-- them, so a transfer started inside one fails as on OS 3.4.2.
	if not t.real_url_wrapped then
		t.real_url_wrapped = true
		local respond_headers, chunk = t.respond_headers, t.chunk
		t.respond_headers = function(tt, ...)
			local results
			self:guarded(function(...) results = { respond_headers(tt, ...) } end, ...)
			return unpack(results)
		end
		t.chunk = function(tt, ...)
			self:guarded(chunk, tt, ...)
		end
	end
	if self.in_callback > 0 then
		local hop = { url = t.url, exit = 2, text = real_url.CURL_TEXT[2], ms = 0, attempts = 0, responses = {},
			detail = "started inside OnHeaders or OnBodyChunk (docs/design.md: curl 2 on OS 3.4.2)" }
		local entry = self:record(t, hop)
		schedule(c4, real_url.FAILED_INIT_MS, function()
			self:deliver(c4, t, hop, entry, 0)
		end)
		return t
	end
	local hop = self:exchange(t.method, t.url, t.data, t.headers, t.options)
	hop.data = t.data
	local entry = self:record(t, hop)
	schedule(c4, self:fake_ms(hop, t.options), function()
		self:deliver(c4, t, hop, entry, 0)
	end)
	return t
end

-- The fallback when the fake runtime has no transport hook (see the header).
function T:wrap(c4)
	if c4.real_url_wrapped then
		return
	end
	c4.real_url_wrapped = true
	local make = c4.url
	local transport = self
	c4.url = function(runtime)
		local t = make(runtime)
		local function start(tt, method, url, data, headers)
			assert(not tt.started, "transfer already started")
			tt.started = true
			tt.method, tt.url, tt.data, tt.headers = method, url, data, headers or {}
			transport:start(tt, c4)
			return tt
		end
		function t:Get(url, headers) return start(self, "GET", url, nil, headers) end
		function t:Post(url, data, headers) return start(self, "POST", url, data, headers) end
		function t:Put(url, data, headers) return start(self, "PUT", url, data, headers) end
		function t:Delete(url, headers) return start(self, "DELETE", url, nil, headers) end
		function t:Custom(url, method, data, headers) return start(self, method, url, data, headers) end
		return t
	end
end

-- Plug into the fake runtime (see the header). Returns how.
function T:install(fake, c4)
	if type(fake.set_url_transport) == "function" then
		fake.set_url_transport(function(t, runtime)
			self:start(t, runtime)
			return true
		end)
		self.how = "fake.set_url_transport"
	else
		self:wrap(c4 or rawget(_G, "C4"))
		self.how = "C4.url wrapper (fake.set_url_transport not in the fake runtime)"
	end
	return self.how
end

-- Hand the transfers back to the fake runtime's own handling (F3's hook
-- is kept across harness runs, so whoever sets it clears it).
function T:uninstall(fake)
	if self.how == "fake.set_url_transport" and type(fake.set_url_transport) == "function" then
		fake.set_url_transport(nil)
	end
	self.how = nil
end

-- The history after the n-th entry.
function T:since(n)
	local out = {}
	for i = (n or 0) + 1, #self.history do
		out[#out + 1] = self.history[i]
	end
	return out
end

return real_url
