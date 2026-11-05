-- The TCP 443 sweep (#334, docs/simplify-actions-design.md D12 and §3.4;
-- docs/simplify-research-discovery.md §2.3, stage A): which addresses of at
-- most two /24 networks accept a TCP connection on port 443. Nothing is
-- written on any connection: each is closed as soon as it opens, fails or
-- times out. bridge/discovery.lua runs the identity check (stage B) on the
-- addresses that accepted, as they are found.
--
-- What the house showed (dev build 447, OS 3.4.2) [verified: hardware,
-- 2026-11-05, #334]: with C4:CreateTCPClient, 4 connects in flight, 1500 ms
-- per connect and 125 ms between starts, 253 addresses of one /24 took 83 s:
-- 9 accepted, 213 gave no answer within 1500 ms, 31 refused at once (error
-- 111). The same constants are the defaults here.
--
-- DriverWorks calls (API/ is ~/c4-tools/reference/docs-driverworks-api/
-- source/includes/), through the opts adapters bridge/discovery.lua passes:
--   C4:CreateTCPClient()                API/14_lua_tcp_client/_1-Overview.md
--   client:OnConnect(fn(client))        API/14_lua_tcp_client/_6-OnConnect.md
--   client:OnError(fn(client, code, msg)) API/14_lua_tcp_client/_8-OnError.md
--   client:Connect(host, port)          API/14_lua_tcp_client/_3-Connect.md (nil on an error)
--   client:Close(false)                 API/14_lua_tcp_client/_2-Close.md: it cancels a
--                                       pending connect, which then calls OnError; that
--                                       late OnError is ignored here
--   C4:SetTimer, C4:GetTime             API/34_timer/
-- A pending client stays alive until its callback ran, whether or not Lua
-- still holds it (14/_1); this module holds each one until its end anyway.
-- None of these may run in OnDriverInit (14/_1); discovery runs from late
-- init on.
--
-- Which addresses (sweep.plan): the /24 of each centre given (the bridge's
-- last good address first, then the controller's), at most MAX_NETS of
-- them, each from its centre outward (centre, +1, -1, +2, ...), .1 to .254,
-- the skipped addresses (the controller's own) left out. Only networks
-- that cannot be on the internet: the private ranges of RFC 1918, and the
-- documentation networks of RFC 5737, which no host on the internet holds
-- (the project's placeholders, 192.0.2.x and 198.51.100.x, are such). A
-- centre anywhere else is skipped and says why: a mistyped public address
-- must never turn into a sweep of somebody's network. No API gives a
-- driver its netmask (docs/simplify-research-discovery.md §2.1), so nothing
-- wider than a /24 is ever guessed.
--
--   local run = sweep.start(opts)
--   opts = { hosts, port (443), in_flight (4), connect_ms (1500), gap_ms (125),
--            cap_ms (CAP_PER_NET_MS), tcp = fn() -> client | nil,
--            timer = fn(ms, fn) -> handle with :Cancel(), now_ms = fn(),
--            log, on_open = fn(ip, ms), on_done = fn(result) }
--   run:stop(why)   every pending connect closed; on_done follows
--   run:running()
--   result = { total, tried, open = { { ip, ms } }, timeouts, errors, failed,
--              aborted, codes = { ["111 Connection refused"] = n }, ms,
--              max_in_flight, stopped = why | nil, error = text | nil }
-- on_done comes once, from a 1 ms timer, never inside a TCP callback or
-- inside run:stop. on_open comes from the client's OnConnect, under pcall.

local config = require("bridge.config")

local sweep = {}

sweep.PORT = 443
sweep.IN_FLIGHT = 4          -- connects at once, never more
sweep.CONNECT_MS = 1500      -- a connect still pending then is closed: no answer
sweep.GAP_MS = 125           -- between two starts: at most 8 a second
sweep.CAP_PER_NET_MS = 110000 -- per /24 of the plan; the house needed 83 s for one
sweep.MAX_NETS = 2

-- The networks a sweep may cover: the leading octets and the prefix length.
sweep.RANGES = {
	{ 10, bits = 8 }, { 172, 16, bits = 12 }, { 192, 168, bits = 16 },         -- RFC 1918
	{ 192, 0, 2, bits = 24 }, { 198, 51, 100, bits = 24 }, { 203, 0, 113, bits = 24 }, -- RFC 5737
}

-- The four octets of a dotted address (bridge/config.lua's rules), or nil.
function sweep.octets(ip)
	local text = config.parse_ipv4(ip)
	if not text then
		return nil
	end
	local a, b, c, d = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	return { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
end

-- True when the /24 of `ip` may be swept; else false and why.
function sweep.searchable(ip)
	local o = sweep.octets(ip)
	if not o then
		return false, "not an IPv4 address"
	end
	for _, r in ipairs(sweep.RANGES) do
		local inside = o[1] == r[1]
		if r.bits == 12 then
			inside = inside and o[2] >= r[2] and o[2] <= r[2] + 15
		elseif r.bits >= 16 then
			inside = inside and o[2] == r[2] and (r.bits == 16 or o[3] == r[3])
		end
		if inside then
			return true
		end
	end
	return false, "not a private network"
end

-- The addresses to try: { hosts = { ip, ... }, nets = { "a.b.c", ... },
-- skipped = { { ip, why } } }. `centres` is a list (nil holes allowed, up
-- to n) of addresses whose /24 to cover, in order; `skip` a list of
-- addresses never tried.
function sweep.plan(centres, skip, n)
	local out = { hosts = {}, nets = {}, skipped = {} }
	local never = {}
	for _, ip in pairs(skip or {}) do
		local o = sweep.octets(ip)
		if o then
			never[table.concat(o, ".")] = true
		end
	end
	local seen = {}
	for i = 1, n or 2 do
		local ip = centres and centres[i]
		if ip ~= nil and ip ~= "" then
			local o = sweep.octets(ip)
			local ok, why = sweep.searchable(ip)
			local net = o and string.format("%d.%d.%d", o[1], o[2], o[3])
			if not ok then
				out.skipped[#out.skipped + 1] = { ip = tostring(ip), why = why }
			elseif not seen[net] and #out.nets < sweep.MAX_NETS then
				seen[net] = true
				out.nets[#out.nets + 1] = net
				local centre = o[4] >= 1 and o[4] <= 254 and o[4] or 1
				local function add(h)
					local addr = net .. "." .. h
					if h >= 1 and h <= 254 and not never[addr] then
						out.hosts[#out.hosts + 1] = addr
					end
				end
				add(centre)
				for d = 1, 253 do
					add(centre + d)
					add(centre - d)
				end
			end
		end
	end
	return out
end

local Run = {}
Run.__index = Run

local function cancel(handle)
	if handle then
		pcall(function() handle:Cancel() end)
	end
end

function Run:running()
	return not self.done
end

-- A timer through opts.timer whose callback runs under pcall; a raise stops
-- the run with its text as the error.
function Run:_after(ms, fn)
	local run = self
	return self.opts.timer(math.max(1, math.floor(ms)), function()
		local ok, err = pcall(fn)
		if not ok then
			run.log.warn("discovery sweep: a step failed: %s", tostring(err))
			run.result.error = run.result.error or tostring(err)
			run:stop("an error")
		end
	end)
end

function Run:_finish()
	if self.done then
		return
	end
	self.done = true
	cancel(self.cap_timer)
	cancel(self.pump_timer)
	self.cap_timer, self.pump_timer = nil, nil
	local r = self.result
	r.ms = self.opts.now_ms() - self.t0
	if self.log.enabled("info") then
		local codes = {}
		for code, count in pairs(r.codes) do
			codes[#codes + 1] = string.format("%s x%d", code, count)
		end
		table.sort(codes)
		self.log.info("discovery sweep: %d of %d addresses in %.1f s%s: %d open on %d, %d silent, %d refused or "
			.. "failed (%s), %d could not start, %d closed at the stop", r.tried, r.total, r.ms / 1000,
			r.stopped and (", stopped (" .. r.stopped .. ")") or "", #r.open, self.port, r.timeouts, r.errors,
			#codes > 0 and table.concat(codes, ", ") or "none", r.failed, r.aborted)
	end
	local on_done = self.opts.on_done
	-- From a timer: never inside a TCP callback or inside stop().
	self.opts.timer(1, function()
		if on_done then
			local ok, err = pcall(on_done, r)
			if not ok then
				self.log.warn("discovery sweep: on_done failed: %s", tostring(err))
			end
		end
	end)
end

local function close_client(h)
	local client = h.client
	if client then
		pcall(function() client:Close(false) end)
	end
end

-- The end of one connect, once: "open", "timeout", "error", "failed" or "aborted".
function Run:_result(h, outcome, code, msg)
	if h.over then
		return
	end
	h.over = true
	cancel(h.timer)
	self.live[h] = nil
	self.in_flight = self.in_flight - 1
	local r = self.result
	local ms = self.opts.now_ms() - h.t0
	if outcome == "aborted" then
		r.aborted = r.aborted + 1
	elseif outcome == "open" then
		r.open[#r.open + 1] = { ip = h.ip, ms = ms }
		self.log.debug("discovery sweep: %s accepts port %d (%d ms)", h.ip, self.port, ms)
		if self.opts.on_open and not self.done then
			local ok, err = pcall(self.opts.on_open, h.ip, ms)
			if not ok then
				self.log.warn("discovery sweep: on_open failed: %s", tostring(err))
			end
		end
	elseif outcome == "timeout" then
		r.timeouts = r.timeouts + 1
	elseif outcome == "error" then
		r.errors = r.errors + 1
		local key = tostring(code) .. " " .. tostring(msg or ""):gsub("%c", "")
		r.codes[key] = (r.codes[key] or 0) + 1
	elseif outcome == "failed" then
		r.failed = r.failed + 1
		if r.failed <= 3 then
			self.log.warn("discovery sweep: a connect to %s could not start: %s", h.ip, tostring(msg))
		end
	end
	if outcome ~= "aborted" then
		self:_schedule(1)
	end
end

function Run:_schedule(ms)
	if self.pump_timer or self.done then
		return
	end
	self.pump_timer = self:_after(ms, function()
		self.pump_timer = nil
		self:_pump()
	end)
end

function Run:_connect(ip)
	local run = self
	local h = { ip = ip, t0 = self.opts.now_ms() }
	local r = self.result
	self.in_flight = self.in_flight + 1
	r.max_in_flight = math.max(r.max_in_flight, self.in_flight)
	self.last_start = h.t0
	self.live[h] = true
	r.tried = r.tried + 1
	h.timer = self:_after(self.connect_ms, function()
		if not h.over then
			run:_result(h, "timeout")
			close_client(h)
		end
	end)
	local ok, err = pcall(function()
		local client = run.opts.tcp()
		if not client then
			error("no TCP client", 0)
		end
		h.client = client
		client:OnConnect(function(c)
			-- A connect that already timed out is only closed (_result ignores it).
			local fine, why = pcall(run._result, run, h, "open")
			-- Closed whatever happened: nothing is ever written.
			pcall(function() c:Close(false) end)
			if not fine then
				run.log.warn("discovery sweep: OnConnect failed: %s", tostring(why))
			end
		end)
		client:OnError(function(_, code, msg)
			local fine, why = pcall(run._result, run, h, "error", code, msg)
			if not fine then
				run.log.warn("discovery sweep: OnError failed: %s", tostring(why))
			end
		end)
		if client:Connect(ip, run.port) == nil then
			error("Connect answered nil", 0)
		end
	end)
	if not ok then
		self:_result(h, "failed", nil, tostring(err))
		close_client(h)
	end
end

function Run:_pump()
	if self.done then
		return
	end
	local hosts = self.opts.hosts
	while self.in_flight < self.limit and self.index < #hosts do
		local wait = self.last_start and (self.last_start + self.gap_ms - self.opts.now_ms()) or 0
		if wait > 0 then
			return self:_schedule(wait)
		end
		self.index = self.index + 1
		self:_connect(hosts[self.index])
		if self.done then
			return
		end
	end
	if self.index >= #hosts and self.in_flight == 0 then
		self:_finish()
	end
end

-- Every pending connect closed and counted as aborted; on_done follows.
function Run:stop(why)
	if self.done then
		return
	end
	self.result.stopped = self.result.stopped or why or "stopped"
	self.index = #self.opts.hosts
	local pending = {}
	for h in pairs(self.live) do
		pending[#pending + 1] = h
	end
	for _, h in ipairs(pending) do
		self:_result(h, "aborted")
		close_client(h)
	end
	self:_finish()
end

function sweep.start(opts)
	local run = setmetatable({}, Run)
	run.opts = opts
	run.log = opts.log or require("common.log")
	run.port = opts.port or sweep.PORT
	run.limit = math.max(1, math.min(math.floor(opts.in_flight or sweep.IN_FLIGHT), sweep.IN_FLIGHT))
	run.connect_ms = opts.connect_ms or sweep.CONNECT_MS
	run.gap_ms = opts.gap_ms or sweep.GAP_MS
	run.index, run.in_flight, run.live = 0, 0, {}
	run.t0 = opts.now_ms()
	run.result = { total = #opts.hosts, tried = 0, open = {}, timeouts = 0, errors = 0, failed = 0, aborted = 0,
		codes = {}, max_in_flight = 0 }
	if type(opts.tcp) ~= "function" then
		run.result.error = "no C4:CreateTCPClient on this controller"
		run.log.warn("discovery sweep: %s", run.result.error)
		run:_finish()
		return run
	end
	run.log.debug("discovery sweep: %d addresses on port %d, %d in flight, %d ms per connect, %d ms between starts",
		#opts.hosts, run.port, run.limit, run.connect_ms, run.gap_ms)
	run.cap_timer = run:_after(opts.cap_ms or sweep.CAP_PER_NET_MS, function()
		run:stop("the time cap")
	end)
	run:_pump()
	return run
end

return sweep
