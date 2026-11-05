-- Local bridge discovery (#334, docs/simplify-actions-design.md §3.4, the
-- owner's answers D5 and D12; docs/simplify-research-discovery.md): finds
-- Hue bridges on the controller's network, never through the internet.
--
--   local d = discovery.new(ctx)
--   d:find_all(done(list, detail))
--       first load and "Search again": one mDNS search (about 3 s), then
--       the identity check of every address that answered; nothing more.
--   d:find_subnet(done(list, detail), around_ip)
--       the offered search, on a click only: the TCP 443 sweep of the
--       controller's /24 (and first the /24 of around_ip, when given), then
--       the identity check of every address that accepted.
--   d:find_paired(bridge_id, last_ip, done(ip | nil, how, detail))
--       the follow-up of an address change: mDNS first; only when mDNS does
--       not find bridge_id, the sweep of at most two /24 networks (around
--       last_ip, then around the controller), at most once an hour. Only
--       the address where bridge_id itself passed the identity check comes
--       back, never another bridge's.
--   d:received(binding, port, data, from)   ReceivedFromNetwork
--   d:status_changed(binding, port, status) OnConnectionStatusChanged
--       each true for discovery's binding (handled, whatever the state),
--       false for any other: the driver passes everything else on.
--   d:owns(binding), d:busy(), d:sweep_wait_ms(), d:stop()
--   discovery.item_label(item, paired_id)   the Bridges Found text of an item
--
-- list items: { id, name, model, ip, how = "mdns" | "sweep", sw_version,
-- api_version, supported (bridge/config.lua model_supported), replaces (a
-- normalised replacesbridgeid, when ctx.identify reports one) }; one per
-- bridge id, sorted by name, then id. `how` of find_paired: "mdns" or
-- "sweep" with an address; "not_found", "limited" (the hourly limit held
-- the sweep back: detail.next_sweep_ms), "cancelled" (another bridge id was
-- asked for meanwhile) or "error" without one. `detail.text` is one short
-- line for Last Action or the log ("found by mDNS", "found by a search of
-- 10.0.2.x", "not found on the network (mDNS: no answer; searched 10.0.2.x
-- and 192.0.2.x)"); the rest of detail is for the log.
--
-- Every done comes once, from a timer, never inside the call that asked or
-- inside a Director callback. A second call while one of the same kind runs
-- joins it (find_paired: for the same bridge id) and gets the same answer.
-- find_all may run while a sweep runs; two sweeps never run at once (the
-- second waits). d:stop() (OnDriverDestroyed) cancels everything: the
-- binding is disconnected, every TCP client closed, every timer cancelled,
-- and no done is called afterwards.
--
-- ctx (identify is the one that matters; everything has a default):
--   identify(ip, done(info | nil, err))  the identity check exactly as pairing
--                                does it: bridge/pairing.lua probe, the
--                                unkeyed GET /api/0/config under the pinned
--                                Signify chain (bridge/http.lua), info = {
--                                bridge_id, model, name, sw_version,
--                                api_version }; may return a transfer with
--                                :Cancel(). Default pairing.probe.
--   controller_ip()              default C4:GetControllerNetworkAddress()
--   log                          default common.log
--   now_ms()                     default C4:GetTime() (ms since the epoch
--                                [verified: SDK 34_timer/_2-GetTime], so the
--                                persisted sweep time survives a restart)
--   timer(ms, fn)                one-shot, returns a handle with :Cancel();
--                                default C4:SetTimer
--   net = { create(binding, address), connect(binding, port, kind),
--           send(binding, port, data), disconnect(binding, port) }
--                                default C4:CreateNetworkConnection,
--                                C4:NetConnect, C4:SendToNetwork, C4:NetDisconnect
--   tcp()                        a new TCP client; default C4:CreateTCPClient
--                                (none when the controller lacks it: no sweep)
--   store = { get(name), set(name, value) }
--                                default C4:PersistGetValue / PersistSetValue
--   binding                      default discovery.BINDING
--
-- DriverWorks calls, with the SDK file of each (API/ is
-- ~/c4-tools/reference/docs-driverworks-api/source/includes/, 32/ its
-- 32_serial_network_device/):
--   C4:CreateNetworkConnection(6008, "224.0.0.251")  32/_1 (no type: the type is NetConnect's)
--   C4:NetConnect(6008, 5353, "UDP")                 32/_23
--   C4:SendToNetwork(6008, 5353, query)              32/_20 (NUL bytes allowed)
--   C4:NetDisconnect(6008, 5353)                     32/_24
--   OnConnectionStatusChanged(binding, port, status) 32/_27
--   ReceivedFromNetwork(binding, port, data, from)   32/_15 ("from" only since OS 4.0.0)
--   C4:GetControllerNetworkAddress()                 32/_5 (the master controller's)
--   C4:CreateTCPClient() and its methods             API/14_lua_tcp_client/ (bridge/sweep.lua)
--   C4:SetTimer, C4:GetTime                          API/34_timer/
--   C4:PersistGetValue, C4:PersistSetValue           API/26.5_persistence/
-- None may run in OnDriverInit (each page says so); the driver searches from
-- OnDriverLateInit on. The UDP pattern (create, NetConnect "UDP", send on
-- "ONLINE") is the one Snap One's SSDP module uses
-- (~/c4-tools/drivers-common-public/module/ssdp.lua, read, not copied) and
-- the one the dev probe ran on the house (bridge/probe12.lua).
--
-- What the house showed (dev build 447, OS 3.4.2 with Director 3.4.3, Hue
-- Bridge Pro, 2026-11-05, #334) [verified: hardware, the probe's log]:
--  * The legacy query from the driver's own port, on a UDP network
--    connection to 224.0.0.251:5353, was "ONLINE" 4 ms after NetConnect and
--    got the paired bridge's answer 1 ms after the query: PTR, SRV (443),
--    TXT (bridgeid, modelid), A and AAAA records (bridge/mdns.lua). The
--    MULTICAST type gave the same answer; this module uses "UDP", the
--    documented type of Snap One's module.
--  * ReceivedFromNetwork never named the sender (three arguments), so the
--    address is the A record's. On OS 4.x a fourth argument names it
--    (32/_15): it becomes a second candidate address, checked like the first.
--  * Port 5353 itself is Director's (C4:PortInUse(5353) true): no query from
--    5353, no MIRROR_UDP_PORT.
--  * After the probe's NetDisconnect Director reported "OFFLINE" once and
--    did not reconnect by itself in the 86 s the run went on, without any
--    NetPortOptions: none is set here either.
--  * The sweep (bridge/sweep.lua) and the identity check: 9 addresses
--    accepted port 443, their identity checks took 2.4 s, and each one that
--    was not a Hue bridge failed at TLS (error 60) before any HTTP request.
--
-- The network binding id: one fixed id, BINDING = 6008, for every mDNS
-- search of every run, never netcheck's persisted fresh-id counter. It is
-- created at the first search of each run of the driver's Lua (a Director
-- restart, a driver update, a dev-loop reload), connected for one search
-- window and disconnected at its end, and never cleared: no
-- SetBindingAddress with '', the step after which netcheck saw a reused id
-- misbehave. Why, weighed against bridge/netcheck.lua's evidence:
--  * netcheck's decoy evidence (OS 3.4.3, builds 414 to 416) concerns ids
--    that were cleared and then created again: those inherited the old
--    connection or did nothing. The stream's 6001 is created again at every
--    start and never cleared, and has worked in every build since #317
--    [verified: hardware]. This binding follows 6001's rule.
--  * Fresh ids would not last: netcheck spends two per Director version,
--    while the driver searches at first load (the research's plan, §2.4: 3 s,
--    1 and 5 minutes, then every 15 minutes until paired, 96 a day) and
--    every few minutes while the paired bridge is missing. The 900 ids (6100
--    to 6999) would be gone within ten days of an unpaired driver, and the
--    TLS check, which needs them, with them.
--  * #329: a probe binding stays registered in Director after its close. A
--    fresh id per search would leave hundreds of dead network bindings in
--    the project; one fixed id leaves one, as 6001 does.
--  * A decoy costs nothing here. A stale or inherited connection could at
--    worst bring an old answer or none: every address an answer names must
--    still pass the identity check before anything uses it, and silence
--    only means the sweep's turn. Nothing secret ever goes on this binding.
--  * The house answered on fresh ids (6004 and 6007, each at its first
--    creation). 6008 is fresh in every project, the house's included: it
--    was reserved for discovery (docs/simplify-research-discovery.md O8) and
--    left unused by the probe, while 6004 to 6007 carry the probe's history
--    on the house. A second run on the same id was not tested on the house
--    (the probe's P6 did not run) [assumed: it behaves as 6001 does]. 6009
--    stays free as the spare should 6008 ever need replacing.
-- In dev builds bridge/probe12.lua's Probe Discovery claims 6004 to 6009
-- while its own run lasts: do not run it during a discovery search.
--
-- Identity, exactly as pairing: ctx.identify is pairing.probe, and an
-- address counts only when the bridge there reports the wanted id (both
-- through config.normalise_bridge_id). No CN is compared: no API exposes
-- the peer certificate (docs/simplify-research-discovery.md §1, finding 4).
-- The driver's own identity and TLS checks of the new address still run
-- before any keyed request (driver.lua, the Bridge IP Address handler).
--
-- Cost: one datagram per search window (two, the repeat); per sweep at
-- most 2 × 254 TCP connects, 4 at once, 8 a second, nothing written; one
-- unkeyed GET per address that answered or accepted (at most IDENTITY_MAX
-- per job, one at a time). The automatic sweep runs at most once per
-- SWEEP_INTERVAL_MS; the time of every sweep, clicked or automatic, is
-- persisted (STORE_LAST_SWEEP) before it starts, so no restart resets it.

local config = require("bridge.config")
local mdns = require("bridge.mdns")
local sweep = require("bridge.sweep")

local discovery = {}

discovery.BINDING = 6008
discovery.ONLINE_WAIT_MS = 1500       -- the query goes out after this even without "ONLINE"
discovery.REPEAT_MS = 1000            -- the query once more, for a lost datagram
discovery.WINDOW_MS = 3000            -- answers taken after the first query
discovery.MAX_ANSWERS = 32            -- datagrams parsed per window; the rest are counted
discovery.IDENTITY_WAIT_MS = 20000    -- per address (bridge/http.lua's own timeout is 15 s)
discovery.IDENTITY_MAX = 32           -- addresses given the identity check per job
discovery.IDENTITY_CAP_MS = 45000     -- the identity stage after mDNS, and after a sweep's last connect
discovery.SWEEP_INTERVAL_MS = 3600000 -- the automatic sweep: at most once an hour
discovery.STORE_LAST_SWEEP = "discovery_last_sweep_ms"
discovery.JOB_CAP_MS = 330000         -- a safety net: any job ends by then

-- binding -> true once CreateNetworkConnection ran in this run of the Lua.
local created = {}

local D = {}
D.__index = D

local function cancel(handle)
	if handle then
		pcall(function() handle:Cancel() end)
	end
end

local function have_c4(name)
	return type(C4) == "table" and type(C4[name]) == "function"
end

local function default_ctx(ctx)
	local out = {}
	for k, v in pairs(ctx or {}) do
		out[k] = v
	end
	out.log = out.log or require("common.log")
	out.now_ms = out.now_ms or function() return C4:GetTime() end
	out.timer = out.timer or function(ms, fn)
		return C4:SetTimer(ms, function() fn() end)
	end
	out.controller_ip = out.controller_ip or function()
		if not have_c4("GetControllerNetworkAddress") then
			return nil
		end
		local ok, ip = pcall(C4.GetControllerNetworkAddress, C4)
		return ok and ip or nil
	end
	out.identify = out.identify or function(ip, done)
		return require("bridge.pairing").probe(ip, done)
	end
	out.net = out.net or {
		create = function(binding, address) C4:CreateNetworkConnection(binding, address) end,
		connect = function(binding, port, kind) C4:NetConnect(binding, port, kind) end,
		send = function(binding, port, data) C4:SendToNetwork(binding, port, data) end,
		disconnect = function(binding, port) C4:NetDisconnect(binding, port) end,
	}
	out.store = out.store or {
		get = function(name) return C4:PersistGetValue(name) end,
		set = function(name, value) C4:PersistSetValue(name, value) end,
	}
	return out
end

function discovery.new(ctx)
	local d = setmetatable({}, D)
	d.ctx = default_ctx(ctx)
	d.log = d.ctx.log
	d.binding = d.ctx.binding or discovery.BINDING
	d.window = nil          -- the mDNS search window, shared by every job that waits for it
	d.identities = {}       -- ip -> the identity check in flight, shared too
	d.jobs = {}             -- kind -> the job of that kind ("all", "subnet", "paired")
	d.sweep_queue = {}      -- sweep tasks waiting for the one running
	d.sweeping = nil        -- the sweep task running
	d.late = 0              -- datagrams outside a window
	d.query_id = math.floor(tonumber(d.ctx.now_ms()) or 0) % 65535
	return d
end

function D:now()
	return self.ctx.now_ms()
end

-- `fn` from a timer, under pcall; a raise goes to `on_error` (or the log).
function D:_after(ms, fn, on_error)
	local d = self
	return self.ctx.timer(math.max(1, math.floor(ms)), function()
		if d.stopped then
			return
		end
		local ok, err = pcall(fn)
		if not ok then
			d.log.warn("discovery: a step failed: %s", tostring(err))
			if on_error then
				pcall(on_error, tostring(err))
			end
		end
	end)
end

function D:_soon(fn, on_error)
	return self:_after(1, fn, on_error)
end

function D:owns(binding)
	return tonumber(binding) == self.binding
end

function D:busy()
	return next(self.jobs) ~= nil or self.window ~= nil or self.sweeping ~= nil
end

-- Jobs -------------------------------------------------------------------------

-- A job's answer to every caller waiting for it, once, from a timer.
function D:_deliver(job, ...)
	if job.over then
		return
	end
	job.over = true
	cancel(job.cap_timer)
	if self.jobs[job.kind] == job then
		self.jobs[job.kind] = nil
	end
	if job.task then
		self:_end_task(job.task, "the search ended")
	end
	local args, n = { ... }, select("#", ...)
	local waiters = job.waiters
	self:_soon(function()
		for _, done in ipairs(waiters) do
			local ok, err = pcall(done, unpack(args, 1, n))
			if not ok then
				self.log.warn("discovery: a %s caller failed: %s", job.kind, tostring(err))
			end
		end
	end)
end

function D:_job(kind, done, fail)
	local job = { kind = kind, waiters = { done }, t0 = self:now(), fail = fail }
	self.jobs[kind] = job
	job.cap_timer = self:_after(discovery.JOB_CAP_MS, function()
		job.fail(string.format("stopped at the %d s cap", math.floor(discovery.JOB_CAP_MS / 1000)))
	end)
	return job
end

-- A callback of `job`'s that fails the job, rather than leaving it waiting,
-- when it raises.
function D:_guard(job, fn)
	local d = self
	return function(...)
		if d.stopped or job.over then
			return
		end
		local ok, err = pcall(fn, ...)
		if not ok then
			d.log.warn("discovery: %s search failed: %s", job.kind, tostring(err))
			pcall(job.fail, "an error: " .. tostring(err))
		end
	end
end

-- The mDNS window ----------------------------------------------------------------

function D:_query(w)
	w.sent = w.sent + 1 -- first: an answer may come before SendToNetwork returns
	local ok, err = pcall(self.ctx.net.send, self.binding, mdns.PORT, mdns.query(w.query_id))
	if not ok then
		self.log.warn("discovery mdns: SendToNetwork failed: %s", tostring(err))
		if w.sent == 1 then
			w.error = "could not send the mDNS query: " .. tostring(err)
			self:_close_window(w)
		end
	end
end

function D:_send(w, why)
	if not w.open or w.sent > 0 then
		return
	end
	cancel(w.online_timer)
	self.log.debug("discovery mdns: query 0x%04x sent, %d ms after NetConnect%s", w.query_id, self:now() - w.t0,
		why and ("; " .. why) or "")
	w.first_at = self:now()
	local fail = function(err)
		w.error = w.error or err
		self:_close_window(w)
	end
	w.end_timer = self:_after(discovery.WINDOW_MS, function() self:_close_window(w) end, fail)
	w.repeat_timer = self:_after(discovery.REPEAT_MS, function()
		if w.open then
			self:_query(w)
		end
	end, fail)
	self:_query(w)
end

function D:_close_window(w)
	if not w.open then
		return
	end
	w.open = false
	cancel(w.online_timer)
	cancel(w.end_timer)
	cancel(w.repeat_timer)
	if w.connected then
		local ok, err = pcall(self.ctx.net.disconnect, self.binding, mdns.PORT)
		if not ok then
			self.log.warn("discovery mdns: NetDisconnect failed: %s", tostring(err))
		end
	end
	if self.window == w then
		self.window = nil
	end
	local info = { answers = w.answers, parsed = w.parsed, rejected = w.rejected, candidates = #w.cands,
		online = w.online, sent = w.sent, error = w.error, ms = self:now() - w.t0 }
	self.log.debug("discovery mdns: window closed after %d ms: %d answer(s), %d not usable, %d candidate address(es)%s",
		info.ms, info.answers, info.rejected, info.candidates, info.error and ("; " .. info.error) or "")
	if self.stopped then
		return
	end
	local cands = w.cands
	for _, waiter in ipairs(w.waiters) do
		self:_soon(function()
			local copy = {}
			for i, c in ipairs(cands) do
				copy[i] = c
			end
			waiter(copy, info)
		end)
	end
end

-- `cb(candidates, info)` after the window, joining the one open.
-- candidates: { { id, raw_id, model, instance, ip, port, via = "a" | "from" } }
function D:_mdns(cb)
	local w = self.window
	if w then
		w.waiters[#w.waiters + 1] = cb
		return
	end
	self.query_id = self.query_id % 65535 + 1
	w = { waiters = { cb }, t0 = self:now(), open = true, sent = 0, answers = 0, parsed = 0, rejected = 0,
		cands = {}, keys = {}, query_id = self.query_id }
	self.window = w
	local net = self.ctx.net
	local ok, err = pcall(function()
		if not created[self.binding] then
			net.create(self.binding, mdns.GROUP)
			created[self.binding] = true
			self.log.debug("discovery mdns: binding %d created for %s", self.binding, mdns.GROUP)
		end
		-- As Snap One's SSDP module and the stream's first connect do.
		pcall(net.disconnect, self.binding, mdns.PORT)
		w.connected = true
		net.connect(self.binding, mdns.PORT, "UDP")
	end)
	if not ok then
		w.error = "could not open the mDNS connection: " .. tostring(err)
		self.log.warn("discovery mdns: %s", w.error)
		return self:_close_window(w)
	end
	if w.open and w.sent == 0 then
		w.online_timer = self:_after(discovery.ONLINE_WAIT_MS, function()
			self:_send(w, string.format("no ONLINE within %d ms, sent anyway", discovery.ONLINE_WAIT_MS))
		end, function(e)
			w.error = w.error or e
			self:_close_window(w)
		end)
	end
end

function D:status_changed(binding, port, status)
	if not self:owns(binding) then
		return false
	end
	local w = self.window
	local text = tostring(status)
	if self.stopped or not w or not w.open then
		self.log.debug("discovery mdns: %s on binding %s port %s outside a search", text, tostring(binding),
			tostring(port))
		return true
	end
	if text:upper() == "ONLINE" then
		w.online = true
		local ok, err = pcall(self._send, self, w, nil)
		if not ok then
			self.log.warn("discovery mdns: the query failed: %s", tostring(err))
		end
	end
	return true
end

local function contains(list, value)
	for _, v in ipairs(list) do
		if v == value then
			return true
		end
	end
	return false
end

function D:_take(w, data, from)
	local cands, msg = mdns.read(data)
	if not cands then
		w.rejected = w.rejected + 1
		self.log.debug("discovery mdns: an answer of %d bytes not used: %s", #data, tostring(msg))
		return
	end
	if msg.id ~= w.query_id then
		self.log.debug("discovery mdns: an answer with id 0x%04x to query 0x%04x, taken all the same", msg.id,
			w.query_id)
	end
	local sender = type(from) == "string" and config.parse_ipv4(from) or nil
	for _, c in ipairs(cands) do
		local ips = {}
		for _, ip in ipairs(c.ips) do
			ips[#ips + 1] = ip
		end
		if sender and not contains(ips, sender) then
			ips[#ips + 1] = sender
		end
		self.log.debug("discovery mdns: %q: bridge id %s, model %s, host %s port %s, address %s", c.instance,
			tostring(c.id or c.raw_id), tostring(c.model), tostring(c.host), tostring(c.port),
			#ips > 0 and table.concat(ips, " or ") or "none")
		for _, ip in ipairs(ips) do
			local key = (c.id or ("?" .. c.instance:lower())) .. "@" .. ip
			if not w.keys[key] then
				w.keys[key] = true
				w.cands[#w.cands + 1] = { id = c.id, raw_id = c.raw_id, model = c.model, instance = c.instance,
					ip = ip, port = c.port, via = contains(c.ips, ip) and "a" or "from" }
			end
		end
	end
end

function D:received(binding, port, data, from)
	if not self:owns(binding) then
		return false
	end
	local w = self.window
	if self.stopped or not w or not w.open or w.sent == 0 or type(data) ~= "string" then
		self.late = self.late + 1
		self.log.debug("discovery mdns: %s bytes on binding %s port %s outside a search", type(data) == "string"
			and #data or "no", tostring(binding), tostring(port))
		return true
	end
	w.answers = w.answers + 1
	if w.parsed >= discovery.MAX_ANSWERS then
		return true
	end
	w.parsed = w.parsed + 1
	local ok, err = pcall(self._take, self, w, data, from)
	if not ok then
		w.rejected = w.rejected + 1
		self.log.warn("discovery mdns: an answer not taken: %s", tostring(err))
	end
	return true
end

-- Identity -------------------------------------------------------------------------

-- `cb(info | nil, err)` for `ip`, from a timer, sharing a check in flight.
-- info.bridge_id is normalised; an answer without a usable id is a failure.
function D:_identify(ip, cb)
	local f = self.identities[ip]
	if f then
		f.waiters[#f.waiters + 1] = cb
		return
	end
	f = { waiters = { cb } }
	self.identities[ip] = f
	local d = self
	local function finish(info, err)
		if f.over then
			return
		end
		f.over = true
		cancel(f.timer)
		if d.identities[ip] == f then
			d.identities[ip] = nil
		end
		local id = type(info) == "table" and config.normalise_bridge_id(info.bridge_id) or nil
		local result
		if id then
			result = {}
			for k, v in pairs(info) do
				result[k] = v
			end
			result.bridge_id = id
		else
			err = info and "no bridge id in its public config" or err
		end
		if d.stopped then
			return
		end
		for _, waiter in ipairs(f.waiters) do
			d:_soon(function() waiter(result, err) end)
		end
	end
	f.timer = self:_after(discovery.IDENTITY_WAIT_MS, function()
		finish(nil, string.format("no answer within %d s", math.floor(discovery.IDENTITY_WAIT_MS / 1000)))
		cancel(f.handle)
	end)
	local ok, handle = pcall(self.ctx.identify, ip, function(info, err)
		local fine, why = pcall(finish, info, err)
		if not fine then
			d.log.warn("discovery: the identity answer of %s failed: %s", ip, tostring(why))
		end
	end)
	if not ok then
		finish(nil, "the identity check could not start: " .. tostring(handle))
	elseif not f.over then
		f.handle = handle
	end
end

-- The identity check of `ips`, one at a time, at most IDENTITY_MAX and
-- within IDENTITY_CAP_MS; on_result(ip, info, err) returns true to stop;
-- then on_end(stopped, unchecked).
function D:_check_each(job, ips, on_result, on_end)
	local i, t0 = 0, self:now()
	local step
	step = function()
		i = i + 1
		local ip = ips[i]
		if ip and (i > discovery.IDENTITY_MAX or self:now() - t0 >= discovery.IDENTITY_CAP_MS) then
			local left = #ips - i + 1
			self.log.info("discovery: %d address(es) left without the identity check (its cap)", left)
			return on_end(false, left)
		end
		if not ip then
			return on_end(false, 0)
		end
		self:_identify(ip, self:_guard(job, function(info, err)
			if on_result(ip, info, err) then
				return on_end(true, #ips - i)
			end
			step()
		end))
	end
	step()
end

-- Items -------------------------------------------------------------------------

local function item_of(info, ip, how)
	return {
		id = info.bridge_id, name = info.name, model = info.model, ip = ip, how = how,
		sw_version = info.sw_version, api_version = info.api_version,
		supported = config.model_supported(info.model),
		replaces = config.normalise_bridge_id(info.replaces_bridge_id or info.replacesbridgeid),
	}
end

-- One item per bridge id (the first address kept), sorted by name, then id.
local function add_item(items, item, log)
	for _, other in ipairs(items) do
		if other.id == item.id then
			if other.ip ~= item.ip then
				log.debug("discovery: bridge %s answers at %s and at %s; %s kept", item.id, other.ip, item.ip, other.ip)
			end
			return
		end
	end
	items[#items + 1] = item
end

local function sorted(items)
	table.sort(items, function(a, b)
		local an, bn = tostring(a.name or ""):lower(), tostring(b.name or ""):lower()
		if an ~= bn then
			return an < bn
		end
		return a.id < b.id
	end)
	return items
end

local function nets_text(nets)
	local parts = {}
	for _, net in ipairs(nets or {}) do
		parts[#parts + 1] = net .. ".x"
	end
	return table.concat(parts, " and ")
end

local function bridges_text(n)
	return n == 1 and "1 Hue bridge" or (n .. " Hue bridges")
end

-- find_all ---------------------------------------------------------------------------

function D:find_all(done)
	if self.stopped then
		return
	end
	local running = self.jobs.all
	if running then
		running.waiters[#running.waiters + 1] = done
		return
	end
	local items, dropped = {}, {}
	local job
	job = self:_job("all", done, function(text)
		self:_deliver(job, sorted(items), { text = "the search stopped: " .. text, error = text, dropped = dropped })
	end)
	self:_mdns(self:_guard(job, function(cands, info)
		local ips = {}
		for _, c in ipairs(cands) do
			if not contains(ips, c.ip) then
				ips[#ips + 1] = c.ip
			end
		end
		self:_check_each(job, ips, function(ip, found, err)
			if found then
				add_item(items, item_of(found, ip, "mdns"), self.log)
				for _, c in ipairs(cands) do
					if c.ip == ip and c.id and c.id ~= found.bridge_id then
						self.log.debug("discovery mdns: %s announced bridge %s at %s, but bridge %s answers there", c.instance,
							c.id, ip, found.bridge_id)
					end
				end
			else
				dropped[#dropped + 1] = { ip = ip, why = err }
				self.log.debug("discovery mdns: %s answered mDNS but not the identity check: %s", ip, tostring(err))
			end
			return false
		end, function()
			local text
			if info.error then
				text = "mDNS search failed: " .. info.error
			elseif #items == 0 then
				text = info.answers == 0 and "no Hue bridge answered" or "no answer led to a Hue bridge"
			else
				text = bridges_text(#items) .. " found by mDNS"
			end
			self.log.info("discovery: %s (%d answer(s), %d address(es) checked)", text, info.answers, #ips)
			self:_deliver(job, sorted(items), { text = text, mdns = info, dropped = dropped, error = info.error,
				ms = self:now() - job.t0 })
		end)
	end))
end

-- Sweeps ----------------------------------------------------------------------------

function D:sweep_wait_ms()
	local now = self:now()
	local last = self.last_sweep
	local ok, stored = pcall(self.ctx.store.get, discovery.STORE_LAST_SWEEP)
	stored = ok and tonumber(stored) or nil
	if stored and (not last or stored > last) then
		last = stored
	end
	if not last or last > now then
		return 0 -- never swept, or a clock that went back: allowed
	end
	return math.max(0, last + discovery.SWEEP_INTERVAL_MS - now)
end

function D:_record_sweep()
	local now = self:now()
	self.last_sweep = now
	local ok, err = pcall(self.ctx.store.set, discovery.STORE_LAST_SWEEP, now)
	if not ok then
		self.log.warn("discovery: could not store the sweep time: %s", tostring(err))
	end
end

function D:_tcp()
	if self.ctx.tcp then
		return self.ctx.tcp
	end
	if have_c4("CreateTCPClient") then
		return function() return C4:CreateTCPClient() end
	end
	return nil
end

-- A sweep of `plan` for `job`: on_identity(ip, info, err) for every address
-- that accepted (true stops the sweep), then on_end(result, task).
function D:_sweep(job, plan, on_identity, on_end)
	local task = { job = job, plan = plan, on_identity = on_identity, on_end = on_end, queue = {}, checked = 0,
		unchecked = 0 }
	job.task = task
	self.sweep_queue[#self.sweep_queue + 1] = task
	self:_next_sweep()
end

function D:_next_sweep()
	if self.sweeping or self.stopped then
		return
	end
	local task = table.remove(self.sweep_queue, 1)
	while task and (task.over or task.job.over) do
		task = table.remove(self.sweep_queue, 1)
	end
	if not task then
		return
	end
	self.sweeping = task
	self:_record_sweep()
	self.log.info("discovery: searching %s for Hue bridges (%d addresses, port %d)", nets_text(task.plan.nets),
		#task.plan.hosts, sweep.PORT)
	task.run = sweep.start({
		hosts = task.plan.hosts,
		cap_ms = sweep.CAP_PER_NET_MS * math.max(1, #task.plan.nets),
		tcp = self:_tcp(),
		timer = function(ms, fn) return self:_after(ms, fn, function(e) task.job.fail(e) end) end,
		now_ms = self.ctx.now_ms,
		log = self.log,
		on_open = function(ip)
			if task.over then
				return
			end
			task.queue[#task.queue + 1] = ip
			self:_pump_task(task)
		end,
		on_done = function(result)
			if task.over then
				return
			end
			task.result = result
			task.stage_a_done = true
			task.tail_timer = self:_after(discovery.IDENTITY_CAP_MS, function()
				self.log.info("discovery: the identity checks after the sweep stopped at their cap")
				self:_end_task(task, "the identity cap")
			end, function(e) task.job.fail(e) end)
			self:_pump_task(task)
		end,
	})
end

function D:_pump_task(task)
	if task.over or task.busy then
		return
	end
	if task.job.over then
		return self:_end_task(task, "the search ended")
	end
	local ip = table.remove(task.queue, 1)
	if ip and task.checked >= discovery.IDENTITY_MAX then
		task.unchecked = task.unchecked + 1 + #task.queue
		task.queue = {}
		ip = nil
	end
	if ip then
		task.busy = true
		task.checked = task.checked + 1
		self:_identify(ip, self:_guard(task.job, function(info, err)
			task.busy = false
			if task.over then
				return
			end
			if task.on_identity(ip, info, err) then
				return self:_end_task(task, "found")
			end
			self:_pump_task(task)
		end))
		return
	end
	if task.stage_a_done then
		self:_end_task(task, nil)
	end
end

function D:_end_task(task, why)
	if task.over then
		return
	end
	task.over = true
	cancel(task.tail_timer)
	if task.run and task.run:running() then
		task.run:stop(why or "ended")
	end
	if self.sweeping == task then
		self.sweeping = nil
	end
	local result = task.result or (task.run and task.run.result) or {}
	if not task.job.over then
		local ok, err = pcall(task.on_end, result, task)
		if not ok then
			self.log.warn("discovery: the end of a sweep failed: %s", tostring(err))
			pcall(task.job.fail, "an error: " .. tostring(err))
		end
	end
	if not self.stopped then
		self:_soon(function() self:_next_sweep() end)
	end
end

local function sweep_summary(result, plan, task)
	return { nets = plan.nets, total = result.total, tried = result.tried, open = result.open and #result.open or 0,
		ms = result.ms, stopped = result.stopped, error = result.error, unchecked = task and task.unchecked or 0,
		skipped = plan.skipped }
end

-- The plan of a sweep around `first` (may be nil) and the controller.
function D:_plan(first)
	local ok, controller = pcall(self.ctx.controller_ip)
	if not ok then
		self.log.warn("discovery: the controller's address could not be read: %s", tostring(controller))
		controller = nil
	end
	if type(controller) ~= "string" or controller == "" then
		controller = nil
	end
	local plan = sweep.plan({ first, controller }, { controller }, 2)
	return plan, controller
end

local function plan_refusal(plan, controller)
	local parts = {}
	for _, s in ipairs(plan.skipped) do
		parts[#parts + 1] = string.format("%s is %s", s.ip, s.why)
	end
	if not controller then
		parts[#parts + 1] = "no controller address"
	end
	return "no network to search" .. (#parts > 0 and (": " .. table.concat(parts, "; ")) or "")
end

-- find_subnet --------------------------------------------------------------------------

function D:find_subnet(done, around_ip)
	if self.stopped then
		return
	end
	local running = self.jobs.subnet
	if running then
		running.waiters[#running.waiters + 1] = done
		return
	end
	local items, dropped = {}, {}
	local job
	job = self:_job("subnet", done, function(text)
		self:_deliver(job, sorted(items), { text = "the search stopped: " .. text, error = text, dropped = dropped })
	end)
	local plan, controller = self:_plan(around_ip)
	if #plan.hosts == 0 then
		local text = plan_refusal(plan, controller)
		self.log.info("discovery: %s", text)
		return self:_deliver(job, {}, { text = text, error = text })
	end
	self:_sweep(job, plan, function(ip, info, err)
		if info then
			add_item(items, item_of(info, ip, "sweep"), self.log)
		else
			dropped[#dropped + 1] = { ip = ip, why = err }
			self.log.debug("discovery sweep: %s accepts port 443 but is not a Hue bridge: %s", ip, tostring(err))
		end
		return false
	end, function(result, task)
		local summary = sweep_summary(result, plan, task)
		local text
		if result.error then
			text = "the search of " .. nets_text(plan.nets) .. " failed: " .. result.error
		else
			text = string.format("searched %s: %s (of %d address(es) that accept port 443)", nets_text(plan.nets),
				#items == 0 and "no Hue bridge" or bridges_text(#items), summary.open)
		end
		self.log.info("discovery: %s", text)
		self:_deliver(job, sorted(items), { text = text, sweep = summary, dropped = dropped, error = result.error,
			ms = self:now() - job.t0 })
	end)
end

-- find_paired --------------------------------------------------------------------------

function D:find_paired(bridge_id, last_ip, done)
	if self.stopped then
		return
	end
	local id = config.normalise_bridge_id(bridge_id)
	if not id then
		self:_soon(function()
			done(nil, "error", { text = "no bridge id to look for", error = "no bridge id to look for" })
		end)
		return
	end
	local running = self.jobs.paired
	if running and running.id == id then
		running.waiters[#running.waiters + 1] = done
		return
	end
	if running then
		running.fail_as("cancelled", "another bridge id was asked for")
	end
	local job
	job = self:_job("paired", done, function(text)
		job.fail_as("error", text)
	end)
	job.fail_as = function(how, text)
		self:_deliver(job, nil, how, { text = "the search stopped: " .. text, error = text })
	end
	job.id = id
	local short = id:sub(-6):upper()
	self:_mdns(self:_guard(job, function(cands, info)
		local ips = {}
		-- The answers that name the id first, then those that name none;
		-- another id's are never checked (never adopted either).
		for pass = 1, 2 do
			for _, c in ipairs(cands) do
				local wanted = (pass == 1 and c.id == id) or (pass == 2 and c.id == nil)
				if wanted and not contains(ips, c.ip) then
					ips[#ips + 1] = c.ip
				end
			end
		end
		local found
		self:_check_each(job, ips, function(ip, got, err)
			if got and got.bridge_id == id then
				found = ip
				return true
			end
			self.log.debug("discovery mdns: %s named for bridge %s, but %s", ip, short,
				got and ("bridge " .. got.bridge_id:sub(-6):upper() .. " answers there") or tostring(err))
			return false
		end, function()
			if found then
				self.log.info("discovery: bridge %s found at %s by mDNS", short, found)
				return self:_deliver(job, found, "mdns", { text = "found by mDNS", mdns = info, ms = self:now() - job.t0 })
			end
			local heard = info.error and ("mDNS failed: " .. info.error)
				or (#ips == 0 and "mDNS: no answer for it" or "mDNS: its answer did not check out")
			self:_paired_sweep(job, last_ip, info, heard)
		end)
	end))
end

function D:_paired_sweep(job, last_ip, mdns_info, heard)
	local id = job.id
	local short = id:sub(-6):upper()
	local wait = self:sweep_wait_ms()
	if wait > 0 then
		local minutes = math.max(1, math.ceil(wait / 60000))
		local text = string.format("not found by mDNS; the address search runs at most once an hour (next in %d min)",
			minutes)
		self.log.info("discovery: bridge %s %s", short, text)
		return self:_deliver(job, nil, "limited", { text = text, mdns = mdns_info, next_sweep_ms = self:now() + wait,
			ms = self:now() - job.t0 })
	end
	local plan, controller = self:_plan(last_ip)
	if #plan.hosts == 0 then
		local text = "not found by mDNS; " .. plan_refusal(plan, controller)
		self.log.info("discovery: bridge %s %s", short, text)
		return self:_deliver(job, nil, "not_found", { text = text, mdns = mdns_info, ms = self:now() - job.t0 })
	end
	local found
	self:_sweep(job, plan, function(ip, info, err)
		if info and info.bridge_id == id then
			found = ip
			return true
		end
		if info then
			-- Another bridge: noted, never returned (D5: the paired id only).
			self.log.debug("discovery sweep: %s is Hue bridge %s, not the paired %s", ip,
				info.bridge_id:sub(-6):upper(), short)
		else
			self.log.debug("discovery sweep: %s accepts port 443 but is not a Hue bridge: %s", ip, tostring(err))
		end
		return false
	end, function(result, task)
		local summary = sweep_summary(result, plan, task)
		if found then
			local text = "found by a search of " .. nets_text(plan.nets)
			self.log.info("discovery: bridge %s found at %s by a search of %s", short, found, nets_text(plan.nets))
			return self:_deliver(job, found, "sweep", { text = text, mdns = mdns_info, sweep = summary,
				ms = self:now() - job.t0 })
		end
		local text = string.format("not found on the network (%s; searched %s%s)", heard, nets_text(plan.nets),
			result.error and (": " .. result.error) or "")
		self.log.info("discovery: bridge %s %s", short, text)
		self:_deliver(job, nil, result.error and "error" or "not_found", { text = text, mdns = mdns_info,
			sweep = summary, error = result.error, next_sweep_ms = self:now() + self:sweep_wait_ms(),
			ms = self:now() - job.t0 })
	end)
end

-- Stop ------------------------------------------------------------------------------

-- OnDriverDestroyed: everything cancelled, no done afterwards.
function D:stop()
	if self.stopped then
		return
	end
	self.stopped = true
	local w = self.window
	if w then
		self:_close_window(w)
	end
	for _, job in pairs(self.jobs) do
		job.over = true
		cancel(job.cap_timer)
	end
	self.jobs = {}
	local tasks = { self.sweeping }
	for _, task in ipairs(self.sweep_queue) do
		tasks[#tasks + 1] = task
	end
	self.sweep_queue = {}
	for _, task in pairs(tasks) do
		task.over = true
		cancel(task.tail_timer)
		if task.run and task.run:running() then
			task.run:stop("the driver stopped")
		end
	end
	self.sweeping = nil
	for _, f in pairs(self.identities) do
		f.over = true
		cancel(f.timer)
		cancel(f.handle)
	end
	self.identities = {}
end

-- Bridges Found ---------------------------------------------------------------------

discovery.ITEM_MAX = 72 -- characters; Composer clips a row at about 75

local MODEL_LABELS = { BSB001 = "Hue Bridge v1", BSB002 = "Hue Bridge v2", BSB003 = "Hue Bridge Pro" }

local function utf8_len(s)
	local n = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 128 or b >= 192 then
			n = n + 1
		end
	end
	return n
end

-- The first `n` characters of `s` (whole UTF-8 characters).
local function utf8_head(s, n)
	if n <= 0 then
		return ""
	end
	local count = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 128 or b >= 192 then
			count = count + 1
			if count > n then
				return s:sub(1, i - 1)
			end
		end
	end
	return s
end

-- "Hue Bridge Pro - Upstairs - 10.0.2.143 - 123ABC": the model's short
-- label, the bridge's name (cut so the item stays within ITEM_MAX), the
-- address, the last six hex digits of the id (the mDNS instance name's);
-- "(paired) " in front for the paired id; "- replaces the paired bridge"
-- for a bridge whose replacesbridgeid is the paired id; "- not supported
-- (no CLIP v2)" for a first-generation bridge.
function discovery.item_label(item, paired_id)
	local paired = config.normalise_bridge_id(paired_id)
	local model = tostring(item.model or "")
	local label = MODEL_LABELS[model] or (model:match("^BSB") and ("Hue bridge " .. model)) or "Hue bridge"
	local tail
	if item.supported == false or model == "BSB001" then
		tail = "not supported (no CLIP v2)"
	elseif paired and item.replaces == paired and item.id ~= paired then
		tail = "replaces the paired bridge"
	else
		tail = tostring(item.id or ""):sub(-6):upper()
	end
	local prefix = (paired and item.id == paired) and "(paired) " or ""
	local name = tostring(item.name or ""):gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", "")
	name = utf8_head(name, 20)
	local function build(n)
		local parts = { prefix .. label }
		if n ~= "" then
			parts[#parts + 1] = n
		end
		parts[#parts + 1] = tostring(item.ip or "")
		parts[#parts + 1] = tail
		return table.concat(parts, " - ")
	end
	local text = build(name)
	while utf8_len(text) > discovery.ITEM_MAX and name ~= "" do
		name = utf8_head(name, utf8_len(name) - 1):gsub("%s+$", "")
		text = build(name)
	end
	return text
end

return discovery
