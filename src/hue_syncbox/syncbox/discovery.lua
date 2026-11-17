-- Finding Hue Play HDMI Sync Boxes on the controller's network (#534,
-- docs/hdmi-sync-stage2-design.md §3.7, contracts C3; design 7.1): one mDNS
-- search for _huesync._tcp.local, then the identity check of every address
-- that answered. Local only, never the internet (the owner's rule,
-- docs/simplify-actions-design.md D5). The driver searches at first load,
-- on Pair Sync Box, and every HOURLY_MS while no box is paired.
--
--   local d = discovery.new{ mdns, identity_for, timer, log, net, binding, now }
--   d:search(done, want_id)  done(list, detail) once, from a timer. list:
--                 { { id, name, model, address, device_type, firmware,
--                 api_level, warning } }, at most MAX_LIST, sorted by name,
--                 then id. want_id (optional, the paired box's id): its
--                 answers are taken beyond the window's cap and checked
--                 first, and it is never the one cut by MAX_LIST. A second
--                 search while one runs joins it and gets the same answer.
--   d:received(binding, port, data, from)    ReceivedFromNetwork
--   d:status_changed(binding, port, status)  OnConnectionStatusChanged
--                 each true for the search's binding (handled, whatever the
--                 state), false for any other: the driver passes the rest on.
--   d:owns(binding), d:busy(), d:stop()
--   detail: { text (one line for Last Action or the log: "1 Hue sync box
--   found", "no Hue sync box answered", ...), answers, checked, unchecked,
--   dropped = { { address, why } }, error, ms }
--
-- deps (identity_for is required; the rest have defaults):
--   identity_for(address, cb)  the identity check of syncbox/identity.lua
--                 (§3.3): TLS against the box's pinned root, then the unkeyed
--                 GET /api/v1/device; cb(result), result = { ok, reason,
--                 device = { id, name, model, firmware, api_level,
--                 device_type } }. It must leave the paired box's client
--                 alone (its trust and address). May return a handle with
--                 :Cancel(), used when it does not answer in time.
--   mdns          a common/mdns.lua instance for _huesync._tcp.local;
--                 default discovery.new_mdns()
--   timer(ms, fn) one-shot, a handle with :Cancel(); default C4:SetTimer
--   log           default common.log
--   now()         ms; default C4:GetTime
--   net = { create(binding, address), connect(binding, port, kind),
--           send(binding, port, data), disconnect(binding, port) }
--                 default C4:CreateNetworkConnection, C4:NetConnect,
--                 C4:SendToNetwork, C4:NetDisconnect
--   binding       default BINDING
--
-- DriverWorks calls, with the SDK file of each (32/ is
-- ~/c4-tools/reference/docs-driverworks-api/source/includes/32_serial_network_device/):
--   C4:CreateNetworkConnection(6008, "224.0.0.251")  32/_1
--   C4:NetConnect(6008, 5353, "UDP")                 32/_23
--   C4:SendToNetwork(6008, 5353, query)              32/_20
--   C4:NetDisconnect(6008, 5353)                     32/_24
--   OnConnectionStatusChanged(binding, port, status) 32/_27
--   ReceivedFromNetwork(binding, port, data, from)   32/_15 ("from" only since OS 4.0.0)
-- None may run in OnDriverInit; the driver searches from OnDriverLateInit on.
-- The pattern is the bridge's (bridge/discovery.lua, which the house's
-- Bridge Pro answered on dev build 447 [verified: hardware, #334]): create
-- the binding once per run of the Lua, connect it for one window, send the
-- legacy unicast query once "ONLINE" (or after ONLINE_WAIT_MS), once more
-- after REPEAT_MS, take answers for WINDOW_MS, then disconnect. That a box
-- answers the legacy unicast query for _huesync._tcp.local at all, with TXT
-- name, devicetype, uniqueid and path (docs/syncbox-api-research.md (R1)
-- §2.2), is [assumed] until the first install on the house
-- (docs/syncbox-architecture-research.md (R5) §2.6); without it, the typed
-- address of Pair Sync Box works.
--
-- The binding: 6008, the bridge driver's discovery binding, fresh in this
-- driver too (a network binding belongs to its device, API 32/_1). One
-- fixed id for every search of every run, never cleared, for the reasons
-- bridge/discovery.lua gives (#329: a dead binding stays in the project).
--
-- What an answer must be to count (security review 2026-11-13, N-3, #490;
-- R5 §3.3): an answer to this window's query, its id repeated; every
-- address it names, and the sender's on OS 4.x, private, link-local or a
-- documentation network (common/mdns.lua usable_address), never the
-- internet; at most mdns.MAX_ANSWERS datagrams parsed per window, and as
-- many again that name a wanted id (common/mdns.lua's window does all of
-- that). Then, here: the TXT uniqueid 12 hex digits; an SRV port, when
-- there is one, 443 (R1 §2.2; a dev build's syncbox/devhooks.lua takes
-- another too, carried into the address as "ip:port", for the VM's fake box,
-- #547); the TXT path is never used (the client's path is its own literal
-- /api/v1). A candidate is listed only after the
-- identity check at its address passed and reported the same id
-- (contracts C3): one check at a time, at most IDENTITY_MAX per search,
-- within IDENTITY_CAP_MS. The Hue Play Screen Sync camera is never listed
-- (O2: no camera; docs/edge-cases-syncbox.md B30).

local mdns_module = require("common.mdns")
local https = require("common.https")

-- Dev builds only (#547, docs/fakebox-design.md §7): syncbox/devhooks.lua,
-- which a release build does not carry; without it the search is the
-- release's, port 443 only.
local hooks_ok, devhooks = pcall(require, "syncbox.devhooks")
if not hooks_ok or type(devhooks) ~= "table" then
	devhooks = nil
end

local discovery = {}

discovery.BINDING = 6008
discovery.SERVICE = "_huesync._tcp"
discovery.PORT = 443                  -- the only SRV port a box may announce (R1 §2.2)
discovery.ONLINE_WAIT_MS = 1500       -- the query goes out after this even without "ONLINE"
discovery.REPEAT_MS = 1000            -- the query once more, for a lost datagram
discovery.WINDOW_MS = 3000            -- answers taken after the first query
discovery.IDENTITY_WAIT_MS = 30000    -- per address (TLS check plus GET /device, 6 s each at most)
discovery.IDENTITY_MAX = 16           -- addresses given the identity check per search
discovery.IDENTITY_CAP_MS = 60000     -- the identity stage, from the window's end
discovery.JOB_CAP_MS = 120000         -- a safety net: any search ends by then
discovery.MAX_LIST = 8                -- boxes listed (§3.7)
discovery.HOURLY_MS = 3600000         -- the driver's search while no box is paired (§3.7)
discovery.NAME_MAX = 64

-- binding -> true once CreateNetworkConnection ran in this run of the Lua.
local created = {}

-- The dotted IPv4 address in `value`, or nil and why: four decimal octets,
-- none above 255, none with a leading zero (ambiguous: octal in some
-- parsers). The bridge's rule (bridge/config.lua parse_ipv4), which this
-- package does not ship.
function discovery.parse_ipv4(value)
	if type(value) ~= "string" then
		return nil, "not a string"
	end
	local trimmed = value:match("^%s*(.-)%s*$")
	local octets = { trimmed:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$") }
	if #octets ~= 4 then
		return nil, "not an IPv4 address"
	end
	for i, octet in ipairs(octets) do
		if (#octet > 1 and octet:sub(1, 1) == "0") or #octet > 3 or tonumber(octet) > 255 then
			return nil, "not an IPv4 address"
		end
		octets[i] = tostring(tonumber(octet))
	end
	return table.concat(octets, ".")
end

-- A box id: 12 hex digits, upper case (R1 §1.2), else nil.
function discovery.normalise_id(value)
	if type(value) ~= "string" or #value ~= 12 or not value:match("^%x+$") then
		return nil
	end
	return value:upper()
end

-- The mDNS instance for the box's service (common/mdns.lua; R1 §2.2: TXT
-- name, devicetype, uniqueid).
function discovery.new_mdns()
	return mdns_module.new({
		service = discovery.SERVICE,
		config = { parse_ipv4 = discovery.parse_ipv4 },
		txt = { id = "uniqueid", model = "devicetype", name = "name" },
		normalise_id = discovery.normalise_id,
	})
end

local D = {}
D.__index = D

local function cancel(handle)
	if type(handle) == "table" then
		pcall(function() handle:Cancel() end)
	end
end

local function have_c4(name)
	return type(C4) == "table" and type(C4[name]) == "function"
end

local function peer(v, max)
	return https.peer_text(v, max or discovery.NAME_MAX)
end

function discovery.new(deps)
	deps = deps or {}
	if type(deps.identity_for) ~= "function" then
		error("discovery.new: identity_for required", 2)
	end
	local d = setmetatable({}, D)
	d.identity_for = deps.identity_for
	d.mdns = deps.mdns or discovery.new_mdns()
	d.log = deps.log or require("common.log")
	d.timer = deps.timer or function(ms, fn)
		return C4:SetTimer(ms, function() fn() end)
	end
	d.now = deps.now or function()
		if have_c4("GetTime") then
			return C4:GetTime()
		end
		return os.time() * 1000
	end
	d.net = deps.net or {
		create = function(binding, address) C4:CreateNetworkConnection(binding, address) end,
		connect = function(binding, port, kind) C4:NetConnect(binding, port, kind) end,
		send = function(binding, port, data) C4:SendToNetwork(binding, port, data) end,
		disconnect = function(binding, port) C4:NetDisconnect(binding, port) end,
	}
	d.binding = tonumber(deps.binding) or discovery.BINDING
	d.job = nil      -- the search running, shared by every caller
	d.window = nil   -- its mDNS window while open
	d.late = 0       -- datagrams outside a window
	d.query_id = math.floor(tonumber(d.now()) or 0) % 65535
	return d
end

function D:_now()
	return tonumber(self.now()) or 0
end

-- `fn` from a timer, under pcall, unless stopped; a raise goes to `on_error`.
function D:_after(ms, fn, on_error)
	return self.timer(math.max(1, math.floor(ms)), function()
		if self.stopped then
			return
		end
		local ok, err = pcall(fn)
		if not ok then
			self.log.warn("discovery: a step failed: %s", tostring(err))
			if on_error then
				pcall(on_error, tostring(err))
			end
		end
	end)
end

function D:owns(binding)
	return tonumber(binding) == self.binding
end

function D:busy()
	return self.job ~= nil
end

-- The search ---------------------------------------------------------------------

function D:search(done, want_id)
	if self.stopped or type(done) ~= "function" then
		return
	end
	local want = discovery.normalise_id(want_id)
	local job = self.job
	if job then
		job.waiters[#job.waiters + 1] = done
		if want then
			job.want[want] = true
			if self.window then
				self.window.mw:want(want)
			end
		end
		return
	end
	job = { waiters = { done }, want = {}, t0 = self:_now(), items = {}, dropped = {}, checked = 0, unchecked = 0 }
	if want then
		job.want[want] = true
	end
	self.job = job
	job.cap_timer = self:_after(discovery.JOB_CAP_MS, function()
		self:_finish(job, string.format("stopped at the %d s cap", math.floor(discovery.JOB_CAP_MS / 1000)))
	end)
	self:_open(job)
end

function D:_open(job)
	self.query_id = self.query_id % 65535 + 1
	local w = { job = job, mw = self.mdns.window(self.query_id), open = true, sent = 0, t0 = self:_now() }
	for id in pairs(job.want) do
		w.mw:want(id)
	end
	self.window = w
	local net = self.net
	local ok, err = pcall(function()
		if not created[self.binding] then
			net.create(self.binding, self.mdns.GROUP)
			created[self.binding] = true
			self.log.debug("discovery: binding %d created for %s", self.binding, self.mdns.GROUP)
		end
		pcall(net.disconnect, self.binding, self.mdns.PORT)
		w.connected = true
		net.connect(self.binding, self.mdns.PORT, "UDP")
	end)
	if not ok then
		w.error = "could not open the mDNS connection: " .. tostring(err)
		self.log.warn("discovery: %s", w.error)
		return self:_close(w)
	end
	if w.open and w.sent == 0 then
		w.online_timer = self:_after(discovery.ONLINE_WAIT_MS, function()
			self:_send(w, string.format("no ONLINE within %d ms, sent anyway", discovery.ONLINE_WAIT_MS))
		end, function(e)
			w.error = w.error or e
			self:_close(w)
		end)
	end
end

function D:_query(w)
	w.sent = w.sent + 1 -- first: an answer may come before SendToNetwork returns
	local ok, err = pcall(self.net.send, self.binding, self.mdns.PORT, w.mw:query())
	if not ok then
		self.log.warn("discovery: SendToNetwork failed: %s", tostring(err))
		if w.sent == 1 then
			w.error = "could not send the mDNS query: " .. tostring(err)
			self:_close(w)
		end
	end
end

function D:_send(w, why)
	if not w.open or w.sent > 0 then
		return
	end
	cancel(w.online_timer)
	self.log.debug("discovery: query 0x%04x sent, %d ms after NetConnect%s", w.mw.query_id, self:_now() - w.t0,
		why and ("; " .. why) or "")
	local fail = function(e)
		w.error = w.error or e
		self:_close(w)
	end
	w.end_timer = self:_after(discovery.WINDOW_MS, function() self:_close(w) end, fail)
	w.repeat_timer = self:_after(discovery.REPEAT_MS, function()
		if w.open then
			self:_query(w)
		end
	end, fail)
	self:_query(w)
end

function D:_close(w)
	if not w.open then
		return
	end
	w.open = false
	cancel(w.online_timer)
	cancel(w.end_timer)
	cancel(w.repeat_timer)
	if w.connected then
		local ok, err = pcall(self.net.disconnect, self.binding, self.mdns.PORT)
		if not ok then
			self.log.warn("discovery: NetDisconnect failed: %s", tostring(err))
		end
	end
	if self.window == w then
		self.window = nil
	end
	local mw = w.mw
	self.log.debug("discovery: window closed after %d ms: %d answer(s), %d not usable, %d over the cap, "
		.. "%d candidate address(es)%s", self:_now() - w.t0, mw.answers, mw.rejected, mw.dropped, #mw.cands,
		w.error and ("; " .. w.error) or "")
	local job = w.job
	if self.stopped or job.over then
		return
	end
	job.answers, job.error = mw.answers, w.error
	self:_after(1, function() self:_check_all(job, mw.cands) end, function(e) self:_finish(job, "an error: " .. e) end)
end

function D:status_changed(binding, port, status)
	if not self:owns(binding) then
		return false
	end
	local w = self.window
	if self.stopped or not w or not w.open then
		self.log.debug("discovery: %s on binding %s port %s outside a search", tostring(status), tostring(binding),
			tostring(port))
		return true
	end
	if tostring(status):upper() == "ONLINE" then
		local ok, err = pcall(self._send, self, w, nil)
		if not ok then
			self.log.warn("discovery: the query failed: %s", tostring(err))
		end
	end
	return true
end

function D:received(binding, port, data, from)
	if not self:owns(binding) then
		return false
	end
	local w = self.window
	if self.stopped or not w or not w.open or w.sent == 0 or type(data) ~= "string" then
		self.late = self.late + 1
		self.log.debug("discovery: %s bytes on binding %s port %s outside a search",
			type(data) == "string" and #data or "no", tostring(binding), tostring(port))
		return true
	end
	local ok, added, why = pcall(w.mw.take, w.mw, data, from)
	if not ok then
		self.log.warn("discovery: an answer not taken: %s", tostring(added))
	elseif not added then
		self.log.debug("discovery: an answer of %d bytes not used: %s", #data, peer(why, 200))
	else
		for _, c in ipairs(added) do
			self.log.debug("discovery: %s: box id %s, model %s, address %s (%s), port %s", peer(c.instance, 300),
				peer(c.id or c.raw_id or "none"), peer(c.model or "none"), c.ip, c.via, tostring(c.port))
		end
	end
	return true
end

-- Identity -----------------------------------------------------------------------

-- Where a candidate is checked and listed: its address, when it announced
-- no SRV port or 443 (R1 §2.2); else nil, and it is dropped. A dev build's
-- syncbox/devhooks.lua takes another port too, as "ip:port" (#547).
local function address_of(c)
	if c.port == nil or c.port == discovery.PORT then
		return c.ip
	end
	return devhooks and devhooks.srv_address(c.ip, c.port) or nil
end

-- The addresses to check, the wanted ids' first, one per address; the
-- candidates that cannot be a box are dropped here.
local function plan(job, cands)
	local ips, by_ip = {}, {}
	for _, c in ipairs(cands) do
		if not c.id then
			job.dropped[#job.dropped + 1] = { address = c.ip, why = "no 12-digit uniqueid in its TXT record" }
		elseif not address_of(c) then
			job.dropped[#job.dropped + 1] = { address = c.ip, why = "announced port " .. tostring(c.port) }
		end
	end
	for pass = 1, 2 do
		for _, c in ipairs(cands) do
			local address = c.id and address_of(c)
			if address and (pass == 1) == (job.want[c.id] == true) and not by_ip[address] then
				by_ip[address] = c
				ips[#ips + 1] = address
			end
		end
	end
	return ips, by_ip
end

function D:_check_all(job, cands)
	if job.over then
		return
	end
	job.ips, job.by_ip = plan(job, cands)
	job.i, job.checks_t0, job.found = 0, self:_now(), {}
	self:_check_next(job)
end

function D:_check_next(job)
	if job.over or self.stopped then
		return
	end
	while true do
		job.i = job.i + 1
		local ip = job.ips[job.i]
		if not ip then
			return self:_finish(job)
		end
		if job.checked >= discovery.IDENTITY_MAX or self:_now() - job.checks_t0 >= discovery.IDENTITY_CAP_MS then
			job.unchecked = #job.ips - job.i + 1
			self.log.info("discovery: %d address(es) left without the identity check (its cap)", job.unchecked)
			return self:_finish(job)
		end
		local c = job.by_ip[ip]
		if not job.found[c.id] then
			job.checked = job.checked + 1
			return self:_identify(job, ip, c)
		end
	end
end

-- One identity check, guarded by IDENTITY_WAIT_MS; its answer from a timer.
function D:_identify(job, ip, c)
	local check = {}
	job.check = check
	local function finish(result, why)
		if check.over then
			return
		end
		check.over = true
		cancel(check.guard)
		self:_after(1, function()
			if job.over then
				return
			end
			self:_take_identity(job, ip, c, result, why)
			self:_check_next(job)
		end, function(e) self:_finish(job, "an error: " .. e) end)
	end
	check.guard = self:_after(discovery.IDENTITY_WAIT_MS, function()
		cancel(check.handle)
		finish(nil, string.format("no answer within %d s", math.floor(discovery.IDENTITY_WAIT_MS / 1000)))
	end)
	local ok, handle = pcall(self.identity_for, ip, function(result) finish(result) end)
	if not ok then
		finish(nil, "the identity check could not start: " .. tostring(handle))
	elseif not check.over then
		check.handle = handle
	end
end

function D:_take_identity(job, ip, c, result, why)
	local r = type(result) == "table" and result or nil
	local dev = r and type(r.device) == "table" and r.device or nil
	local id = dev and discovery.normalise_id(dev.id)
	local reason = r and r.reason and peer(r.reason, 64) or nil
	local drop
	if not r then
		drop = why or "no identity answer"
	elseif reason == "camera" or (dev and dev.model == "HSC001") then
		drop = "a Hue Play Screen Sync camera, not an HDMI sync box"
	elseif r.ok ~= true then
		drop = "identity: " .. (reason or "failed")
	elseif not id then
		drop = "no box id in its answer"
	elseif id ~= c.id then
		drop = string.format("announced box %s, but box %s answers there", c.id, id)
	end
	if drop then
		job.dropped[#job.dropped + 1] = { address = ip, why = drop }
		self.log.debug("discovery: %s answered mDNS but is not listed: %s", ip, drop)
		return
	end
	job.found[id] = true
	local name = type(dev.name) == "string" and dev.name ~= "" and peer(dev.name)
		or (type(c.name) == "string" and c.name ~= "" and peer(c.name))
		or ("Hue Sync Box #" .. id:sub(-4))
	job.items[#job.items + 1] = {
		id = id,
		name = name,
		model = type(dev.model) == "string" and peer(dev.model, 32) or "unknown",
		address = ip,
		device_type = type(dev.device_type) == "string" and peer(dev.device_type, 32) or nil,
		firmware = type(dev.firmware) == "string" and peer(dev.firmware, 32) or nil,
		api_level = tonumber(dev.api_level),
		warning = reason == "unknown_model" and "a model this driver does not know" or nil,
	}
end

-- The list ----------------------------------------------------------------------

local function sorted(items)
	table.sort(items, function(a, b)
		local an, bn = a.name:lower(), b.name:lower()
		if an ~= bn then
			return an < bn
		end
		return a.id < b.id
	end)
	return items
end

-- At most MAX_LIST, the wanted ids kept.
local function capped(items, want)
	local out, extra = {}, 0
	local wanted = 0
	for _, it in ipairs(items) do
		if want[it.id] then
			wanted = wanted + 1
		end
	end
	local room = discovery.MAX_LIST - wanted
	for _, it in ipairs(items) do
		if want[it.id] then
			out[#out + 1] = it
		elseif room > 0 then
			out[#out + 1] = it
			room = room - 1
		else
			extra = extra + 1
		end
	end
	while #out > discovery.MAX_LIST do
		table.remove(out)
		extra = extra + 1
	end
	return out, extra
end

local function boxes_text(n)
	return n == 1 and "1 Hue sync box" or (n .. " Hue sync boxes")
end

function D:_finish(job, stopped_why)
	if job.over then
		return
	end
	job.over = true
	cancel(job.cap_timer)
	if job.check and not job.check.over then
		cancel(job.check.guard)
		cancel(job.check.handle)
	end
	if self.job == job then
		self.job = nil
	end
	if self.window and self.window.job == job then
		self:_close(self.window)
	end
	local list, extra = capped(sorted(job.items), job.want)
	local text
	if stopped_why then
		text = "the search stopped: " .. stopped_why
	elseif job.error then
		text = "mDNS search failed: " .. job.error
	elseif #job.items == 0 then
		text = (job.answers or 0) == 0 and "no Hue sync box answered" or "no answer led to a Hue sync box"
	else
		text = boxes_text(#job.items) .. " found"
	end
	if extra > 0 then
		text = text .. string.format(" (%d listed)", #list)
	end
	local detail = { text = text, answers = job.answers or 0, checked = job.checked, unchecked = job.unchecked,
		dropped = job.dropped, error = stopped_why or job.error, ms = self:_now() - job.t0 }
	self.log.info("discovery: %s (%d answer(s), %d address(es) checked)", text, detail.answers, job.checked)
	local waiters = job.waiters
	self:_after(1, function()
		for _, done in ipairs(waiters) do
			local copy = {}
			for i, it in ipairs(list) do
				copy[i] = it
			end
			local ok, err = pcall(done, copy, detail)
			if not ok then
				self.log.warn("discovery: a caller failed: %s", tostring(err))
			end
		end
	end)
end

-- OnDriverDestroyed: everything cancelled, the binding disconnected, no done
-- called afterwards.
function D:stop()
	if self.stopped then
		return
	end
	self.stopped = true
	local w = self.window
	if w then
		self:_close(w)
	end
	local job = self.job
	if job then
		job.over = true
		cancel(job.cap_timer)
		if job.check and not job.check.over then
			cancel(job.check.guard)
			cancel(job.check.handle)
		end
		self.job = nil
	end
end

return discovery
