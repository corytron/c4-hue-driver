-- Polling the Hue Play HDMI Sync Box (#534, docs/hdmi-sync-stage2-design.md
-- §3.6, contracts C2): the box has no event stream, so its whole state is
-- read with GET /api/v1 again and again (docs/syncbox-api-research.md (R1)
-- §2.12: no client has a push channel; one GET returns everything, a few
-- kilobytes), one read at a time (R1 §2.13: aiohuesyncbox opens one
-- connection per box because the box handles only a few;
-- docs/syncbox-architecture-research.md (R5) §2.4).
--
--   local p = poller.new{ client, timer, now, log, on_state, on_offline,
--                         on_online, on_refused }
--   p:start(opts)   reads at once, then on the cadence below. opts
--                   (optional): offline_since, the time (ms) of an outage the
--                   driver already reported (a persisted one, after a
--                   restart): on_offline is not called again for it, and
--                   on_online comes at the first good read.
--   p:stop()        no read is started, no callback called, until start.
--   p:soon(reason)  "command": a read 1 s from now (after a command's
--                   answer, stage 3 on); any other reason (a bridge hint,
--                   a click): a read at once, but at most one read start per
--                   2 s. A read in flight is never doubled: the asked read
--                   follows its answer.
--   p:is_running(), p:is_offline(), p:last_model()
--
-- Callbacks (each optional, each under pcall):
--   on_state(model, changes)  after every good read: state.from_api's model
--                     and its changes since the last good read (every field
--                     on the first read after start)
--   on_offline(since_ms)      once, when no answer has come for
--                     OFFLINE_AFTER_MS (5 minutes), since_ms the first
--                     unanswered read (#428 D1, docs/offline-design.md; the
--                     box's rule in docs/edge-cases-syncbox.md B13, K10)
--   on_online()               once, at the first good read after that,
--                     before that read's on_state
--   on_refused(status)        a 401 or 403 (R1 §2.14: a token the box no
--                     longer knows): polling stops first; the driver says
--                     the box forgot the registration and offers Pair Sync
--                     Box (stage 2 §3.6), after re-checking the identity
--                     (R5 §3.4, as #490 N-6 for the bridge)
--
-- The cadence (contracts C2): 5 s while the box is on, 30 s in power save,
-- 60 s after 3 failed reads in a row, each counted from the previous read's
-- answer. A failed read is any that brought no state: no answer, an error
-- status, or a body that is not the box's state.
--
-- What counts for the 5 minutes (#428 D2, the bridge's rule): a read with
-- no HTTP status at all (timeout, refused, no route) starts the outage; a
-- good read ends it. An answer with another status (5xx, 4xx other than
-- 401 and 403, a 2xx body that is not the state) is neither: the box
-- answered. The client's own refusals (LOCAL_ERRORS: its queue full) are
-- neither too. A read whose callback has not come READ_GUARD_MS after it
-- started counts as unanswered and is abandoned: dropped from the client
-- through the handle client:get returns (syncbox/client.lua: its cb is then
-- never called), else its late answer is ignored. The client's own timeouts
-- (6 s, and its "no end reported" after 10 s more) come before; the guard
-- is for a read that waits in the client, a keyed one before the identity
-- check passed, say.
--
-- `client` is syncbox/client.lua's: client:get("", cb), the path after
-- /api/v1, cb(ok, status, decoded, err). `timer(ms, fn)` is one-shot and
-- returns a handle with :Cancel() (default C4:SetTimer); `now()` is the
-- time in ms (default C4:GetTime, SDK 34_timer/_2-GetTime); `log` the
-- logger (default common.log). Every read's duration is logged at debug
-- only (R5 §2.4).

local state = require("syncbox.state")

local poller = {}

poller.ON_MS = 5000               -- the box on (passthrough or syncing)
poller.POWERSAVE_MS = 30000       -- the box in power save
poller.FAILING_MS = 60000         -- after FAILURES_SLOW failed reads in a row
poller.FAILURES_SLOW = 3
poller.AFTER_COMMAND_MS = 1000    -- p:soon("command")
poller.HINT_GAP_MS = 2000         -- p:soon(other): at most one read start per this
poller.OFFLINE_AFTER_MS = 300000  -- #428 D1
poller.READ_GUARD_MS = 20000      -- a read's callback is given up after this
-- Errors the client answers itself, without asking the box (syncbox/client.lua
-- BUSY, NOT_PAIRED, NO_ADDRESS, INVALID_PATH): neither an answer nor silence.
poller.LOCAL_ERRORS = {
	["busy"] = true, ["not paired"] = true, ["no box address"] = true, ["invalid request path"] = true,
}

local P = {}
P.__index = P

local function cancel(handle)
	if handle then
		pcall(function() handle:Cancel() end)
	end
end

local function have_c4(name)
	return type(C4) == "table" and type(C4[name]) == "function"
end

function poller.new(deps)
	deps = deps or {}
	if type(deps.client) ~= "table" or type(deps.client.get) ~= "function" then
		error("poller.new: client with a get function required", 2)
	end
	local p = setmetatable({}, P)
	p.client = deps.client
	p.log = deps.log or require("common.log")
	p.timer = deps.timer or function(ms, fn)
		return C4:SetTimer(ms, function() fn() end)
	end
	p.now = deps.now or function()
		if have_c4("GetTime") then
			return C4:GetTime()
		end
		return os.time() * 1000
	end
	p.on = {
		state = deps.on_state, offline = deps.on_offline, online = deps.on_online, refused = deps.on_refused,
	}
	p.running = false
	p.gen = 0             -- every start and stop begins a new generation; older answers are ignored
	p.reading = nil       -- the read in flight, of any generation
	p.failures = 0        -- failed reads in a row
	p.since = nil         -- the first unanswered read of the outage, in ms
	p.offline = false     -- on_offline was called (or start said so) and no good read since
	p.model = nil         -- the last good read's model
	p.pending = {}        -- soon() reasons that came while a read was in flight
	return p
end

function P:_now()
	return tonumber(self.now()) or 0
end

-- `fn` after `ms`, unless a stop or start came in between.
function P:_after(ms, fn)
	local gen = self.gen
	return self.timer(math.max(1, math.floor(ms)), function()
		if self.gen ~= gen or not self.running then
			return
		end
		local ok, err = pcall(fn)
		if not ok then
			self.log.warn("poller: a step failed: %s", tostring(err))
		end
	end)
end

function P:_call(name, ...)
	local fn = self.on[name]
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		self.log.warn("poller: on_%s failed: %s", name, tostring(err))
	end
end

function P:is_running()
	return self.running
end

function P:is_offline()
	return self.offline
end

function P:last_model()
	return self.model
end

function P:start(opts)
	if self.running then
		return
	end
	self.running = true
	self.gen = self.gen + 1
	self.model = nil
	self.failures = 0
	self.since = nil
	self.pending = {}
	local since = type(opts) == "table" and tonumber(opts.offline_since) or nil
	if since then
		self.offline = true
		self.offline_since = since
	end
	self.log.debug("poller: started%s", self.offline and " (offline)" or "")
	self:_read("start")
end

function P:stop()
	if not self.running then
		return
	end
	self.running = false
	self.gen = self.gen + 1
	cancel(self.next_timer)
	cancel(self.offline_timer)
	self.next_timer, self.next_due, self.offline_timer, self.since = nil, nil, nil, nil
	self.pending = {}
	-- The read in flight is dropped from the client's queue when the client
	-- gave a handle (syncbox/client.lua: its cb is then never called); else
	-- its answer comes and is ignored, and a start meanwhile waits for it.
	local read = self.reading
	if read and type(read.handle) == "table" and type(read.handle.Cancel) == "function" then
		read.done = true
		cancel(read.guard)
		cancel(read.handle)
		self.reading = nil
	end
	self.log.debug("poller: stopped")
end

-- The delay of the next regular read.
function P:_cadence()
	if self.failures >= poller.FAILURES_SLOW then
		return poller.FAILING_MS
	end
	local m = self.model
	if m and (m.power == "powersave" or m.mode == "powersave") then
		return poller.POWERSAVE_MS
	end
	return poller.ON_MS
end

-- How long a read asked for `reason` waits from now.
function P:_soon_delay(reason)
	if reason == "command" then
		return poller.AFTER_COMMAND_MS
	end
	if self.last_start then
		return math.max(0, self.last_start + poller.HINT_GAP_MS - self:_now())
	end
	return 0
end

-- The next read in `ms`, unless one is already due sooner when `sooner`.
function P:_arm(ms, why, sooner)
	local due = self:_now() + ms
	if sooner and self.next_timer and self.next_due and self.next_due <= due then
		return
	end
	cancel(self.next_timer)
	self.next_due = due
	self.next_timer = self:_after(ms, function()
		self.next_timer, self.next_due = nil, nil
		self:_read(why)
	end)
end

function P:soon(reason)
	reason = type(reason) == "string" and reason or "asked"
	if not self.running then
		self.log.debug("poller: a read for %s not started: polling is stopped", reason)
		return
	end
	if self.reading then
		self.pending[reason] = true
		return
	end
	local ms = self:_soon_delay(reason)
	if ms <= 0 then
		self:_read(reason)
	else
		self:_arm(ms, reason, true)
	end
end

function P:_read(why)
	if not self.running or self.reading then
		return
	end
	cancel(self.next_timer)
	self.next_timer, self.next_due = nil, nil
	local read = { gen = self.gen, t0 = self:_now(), why = why }
	self.reading = read
	self.last_start = read.t0
	-- The guard is not tied to a generation: it frees `reading` even after a
	-- stop. It drops the request from the client when the client gave a
	-- handle, so the client never holds two reads.
	read.guard = self.timer(poller.READ_GUARD_MS, function()
		if not read.done then
			cancel(read.handle)
		end
		self:_answered(read, false, nil, nil,
			string.format("no answer within %d s", math.floor(poller.READ_GUARD_MS / 1000)), true)
	end)
	local ok, handle = pcall(self.client.get, self.client, "", function(fine, status, decoded, text)
		self:_answered(read, fine, status, decoded, text)
	end)
	if not ok then
		self:_answered(read, false, nil, nil, "the read could not start: " .. tostring(handle))
	elseif not read.done then
		read.handle = handle
	end
end

function P:_answered(read, ok, status, decoded, err, guard)
	if read.done then
		return
	end
	read.done = true
	if not guard then
		cancel(read.guard)
	end
	if self.reading == read then
		self.reading = nil
	end
	local ms = self:_now() - read.t0
	if read.gen ~= self.gen or not self.running then
		self.log.debug("poller: an answer after a stop or a restart, %d ms, not used", ms)
		-- A start that came while this read was in flight reads now.
		if self.running and not self.next_timer then
			self:_read("start")
		end
		return
	end
	local fine, why = pcall(self._handle, self, ok, status, decoded, err, ms)
	if not fine then
		self.log.warn("poller: a read's answer failed: %s", tostring(why))
	end
	if self.running then
		self:_schedule()
	end
end

function P:_handle(ok, status, decoded, err, ms)
	status = tonumber(status)
	if ok then
		local model, changes = state.from_api(decoded, self.model)
		if model then
			return self:_good(model, changes, ms)
		end
		return self:_failed(false, string.format("HTTP %s, %s", tostring(status), tostring(changes)), ms)
	end
	if status == 401 or status == 403 then
		self.log.info("poller: the box refused the registration (HTTP %d); polling stops", status)
		self:stop()
		return self:_call("refused", status)
	end
	local text = err ~= nil and tostring(err) or nil
	if status ~= nil then
		return self:_failed(false, string.format("HTTP %d%s", status, text and (", " .. text) or ""), ms)
	end
	if text and poller.LOCAL_ERRORS[text] then
		return self:_failed(false, "not sent: " .. text, ms)
	end
	return self:_failed(true, text or "no answer", ms)
end

function P:_good(model, changes, ms)
	if self.failures > 0 or self.since then
		self.log.debug("poller: the box answers again after %d failed read(s)", self.failures)
	end
	self.failures = 0
	self.since = nil
	cancel(self.offline_timer)
	self.offline_timer = nil
	self.model = model
	self.log.debug("poller: read in %d ms (%s, %d change(s))", ms, tostring(model.mode), #changes)
	if self.offline then
		self.offline = false
		self.offline_since = nil
		self.log.info("poller: the box answers again; online")
		self:_call("online")
	end
	self:_call("state", model, changes)
end

-- A read that brought no state; `silent` when the box did not answer at all.
function P:_failed(silent, why, ms)
	self.failures = self.failures + 1
	self.log.debug("poller: read %d failed after %d ms: %s", self.failures, ms, why)
	if silent and not self.since and not self.offline then
		self.since = self:_now() - ms
		local left = self.since + poller.OFFLINE_AFTER_MS - self:_now()
		self.offline_timer = self:_after(left, function()
			self.offline_timer = nil
			self:_go_offline()
		end)
	end
end

function P:_go_offline()
	if self.offline or not self.since then
		return
	end
	self.offline = true
	self.offline_since = self.since
	self.log.info("poller: no answer from the box for %d s; offline", math.floor(poller.OFFLINE_AFTER_MS / 1000))
	self:_call("offline", self.since)
end

-- After an answer: an asked read first, else the cadence. A read a callback
-- asked for meanwhile (on_state calling soon) stays when it is due sooner.
function P:_schedule()
	if self.reading then
		return
	end
	local best, why
	for reason in pairs(self.pending) do
		local ms = self:_soon_delay(reason)
		if best == nil or ms < best or (ms == best and reason < why) then
			best, why = ms, reason
		end
	end
	self.pending = {}
	if best == nil then
		return self:_arm(self:_cadence(), "cadence", true)
	end
	-- From a timer, never inside the client's callback.
	self:_arm(math.max(1, best), why, true)
end

return poller
