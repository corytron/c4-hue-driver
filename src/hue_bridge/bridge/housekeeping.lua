-- The bridge driver's background tasks: one engine, one alarm (#334).
--
-- Contract: docs/simplify-actions-design.md §2.1, which builds the
-- interface and rules of docs/simplify-research-scheduler.md §3.1 to §3.7
-- with three amendments: background tasks are always on (no enable(), owner's
-- answer D4), the engine only reads (every request it makes is a GET), and
-- the tasks themselves are bridge/tasks.lua's (since #373); §4
-- of the contract adds job.charge and the hourly budget of 100 (finding 7).
--
--   local hk = housekeeping.new(ctx)
--   hk:define(task)           a task (fields below); before or after start()
--   hk:start(dit)             from OnDriverLateInit: the quiet period by DIT,
--                             the persisted last runs; the first timer
--   hk:poke(name, why, done)  a trigger; done(ok, text) once, by the run
--                             that serves it
--   hk:wake()                 the driver's state changed: look again now
--   hk:mark_fresh(name)       work done elsewhere counts as this task's run
--   hk:reset(generation, forget)
--                             an address change (forget: Forget Pairing or
--                             another bridge): the running job is dropped
--   hk:stop()                 OnDriverDestroyed: every timer cancelled
--   hk:info(name)             a copy of one task's counters, for the rows
--
-- ctx (http is required; the rest have defaults):
--   http(req, cb)             bridge_request (hue_bridge/driver.lua); only
--                             job.http calls it, and only with GETs
--   now_ms()                  millisecond clock (default C4:GetTime)
--   wall()                    wall-clock seconds for the store (default
--                             now_ms() / 1000: C4:GetTime counts from the
--                             epoch [verified: SDK 34_timer/_2-GetTime])
--   set_timer(ms, fn)         a one-shot timer with :Cancel() (default
--                             C4:SetTimer)
--   persist_get(name), persist_set(name, value)
--                             default C4:PersistGetValue / PersistSetValue
--   log                       common.log or a stand-in
--   user_active(quiet_ms)     true while a command queue holds work
--                             (commands:busy()) or the driver sent a user
--                             write in the last quiet_ms (default 1500)
--   state()                   the guards: a table { paired, identity_ok,
--                             key_ok, stream_up, not_pairing, modules_idle },
--                             each true when it holds; anything else fails
--   device_id                 a value or a function (default C4:GetDeviceID):
--                             seeds the jitter
--   bridge_id()               the paired bridge's id, or nil: the store
--                             belongs to one bridge
--   on_status(report)         every finished run: { task, trigger, class,
--                             requests, budget, ok, text, ms, notes }
--
-- A task (hk:define):
--   name, run                 a stable id; run(job, done) does the work and
--                             ends with done(ok, text)
--   class                     "essential" (outside the hourly budget, not
--                             held by the quiet period) or "optional"
--   triggers                  any of TRIGGERS; "timer" goes with interval_s,
--                             "click" is always accepted, "startup" makes
--                             the task pending at start()
--   interval_s                a freshness deadline: due when the last success
--                             is older (nil: runs only when poked)
--   jitter                    a fraction of the interval (default 0.1): the
--                             deadline moves later by up to that much, by a
--                             hash of the device id and the task name
--   debounce_s, min_gap_s     quiet time after the last trigger; the least
--                             time between the end of a run and the next
--   budget                    the most requests one run may make (default 0);
--                             job.http refuses beyond it
--   timeout_s                 a run whose done never comes is ended as a
--                             failure (default 300; owner.lua's BUSY_MAX
--                             does the same for the modules' busy flags)
--   guards                    names from GUARDS (default DEFAULT_GUARDS)
--   persist                   keep the last run across restarts; only with
--                             interval_s of an hour or more
--   backoff_s                 after a failure: a number (the first delay,
--                             doubled per failure in a row; default 60) or a
--                             list of delays whose last one repeats
--   backoff_max_s             a cap below the default one (the smaller of
--                             the interval and an hour)
--   refreshes                 names of tasks a success also marks fresh (the
--                             resync after a connect is the safety net's run)
--
-- Inside run: job.http(req, cb) is the gated, counted GET; job.note(text)
-- adds a line to the run's report; job.name, job.trigger, job.click.
-- job.charge() counts one request the run sends by another path (the
-- driver's resync chain goes through bridge_request, which calls it for
-- each of its GETs, #334 §4 finding 7): in the run's report and, for an
-- optional run, in the rolling hour, so the hourly budget holds the next
-- optional run back as job.http's requests would. It refuses nothing: that
-- path also carries a person's requests (a click's GETs while the read
-- runs), which the engine must never fail. The start rule bounds such a
-- run all the same: it starts only when its whole budget fits the hour.
--
-- The rules (research §3.3 to §3.5):
--  * One job at a time: a global lock; the others wait their turn. Clicks
--    go first, then essential tasks, then optional ones by oldest deadline,
--    then by the order of definition.
--  * When a task is due: the latest of its want (the earlier of the trigger
--    plus debounce and the freshness deadline; after a failure no sooner
--    than the backoff), the end of its last run plus min_gap, and for
--    optional tasks the quiet period and OPTIONAL_GAP_MS after any run's
--    end, so overdue tasks go one at a time, 30 s apart. A click waits for
--    nothing but the lock.
--  * Coalescing (the owner.lua resync pattern): a trigger while the task
--    waits moves its debounce; a trigger while it runs makes exactly one
--    more run after it. Each caller is answered once, by the first run that
--    starts after it asked.
--  * Backoff: base * 2^(failures - 1), capped by min(interval, an hour) and
--    backoff_max_s; one success resets it. It holds the retry and any
--    trigger that came before the failed run ended; a trigger after that is
--    news and goes at its debounce (min_gap_s is what limits a task that is
--    poked often).
--  * Budgets: job.http refuses a request beyond the run's budget; optional
--    runs (unless a click asked) count against HOUR_BUDGET requests in any
--    rolling hour (job.charge's too), and one starts only when its whole
--    budget fits. HOUR_BUDGET is 100, not the research's 60: the contract
--    keeps the stream-down read every 10 minutes (§1.3, §4 finding 7), six
--    quick reads of 15 GETs an hour on a Bridge Pro, and the sixth starts
--    only when its budget of 25 fits beside the five before it.
--  * User first: each request waits while ctx.user_active(quiet_ms) is true,
--    looking again every GATE_POLL_MS, and goes after GATE_MAX_MS whatever,
--    so a long slider session cannot starve the resync after a reconnect. A
--    request may carry quiet_ms (5000 for the 351 KB /scene, research §3.4);
--    the field is removed before the request is sent. Clicks skip the gate.
--  * One request in flight per job: job.http queues the rest.
--  * The quiet period from start(dit): DIT_STARTUP 300 s plus 0 to 60 s of
--    jitter, DIT_UPDATING 60 s, DIT_ADDING none; a missing or unknown value
--    counts as DIT_STARTUP. The DIT values are documented from OS 3.2.0
--    [verified: SDK 22_miscellaneous/_25.1-OnDriverLateInit]; what OS 3.4.x
--    passes [assumed until logged, research §8 Q-M3].
--  * Guards are read through ctx.state() when a task is otherwise due; a
--    task held by one is looked at again after GUARD_RECHECK_MS or at
--    hk:wake(). A click held by one is answered at once with the reason.
--  * reset(generation) drops the running job: its requests' late answers
--    never reach the run, its done is ignored, its callers are answered
--    "cancelled"; backoffs are cleared and last runs kept (forget clears
--    them and the store too). stop() cancels every timer and answers no one.
--
-- Timers. Nothing is armed before start(): C4:SetTimer must not be called
-- in OnDriverInit [verified: SDK 34_timer/_1-SetTimer and
-- 22_miscellaneous/_25.2-SafeUsageTable]. The alarm is one one-shot timer
-- re-armed for the earliest time anything could start, never more than
-- MAX_ARM_MS ahead (whether Director keeps a one-shot of hours exactly is
-- not documented [assumed], and a clock jump then costs at most an hour).
-- A running job adds its timeout timer and, while it waits for the user,
-- its gate timer. Every timer callback is pcall-wrapped.
--
-- Persistence (research §3.7). Director kills a driver's timers in
-- OnDriverDestroyed, at every update and shutdown [verified: SDK
-- 22_miscellaneous/_24-OnDriverDestroyed], so a task with persist keeps its
-- last run in one NEW store key, STORE_NAME, that no earlier build wrote:
-- { v = 1, bridge_id, tasks = { [name] = { at, ok, text, runs, fails, ok_at } } },
-- times in wall-clock seconds. A table persists [verified: SDK
-- 26.5_persistence/_4-PersistSetValue], written on its own thread, so a
-- read just after a write may miss it [same file]: the store is read once,
-- at start(), and this run keeps its own copy. Written once per finished
-- run of a persisted task (and by mark_fresh and reset(…, true)). A time
-- from the future (a clock that jumped) counts as now; a store of another
-- bridge id, or of another shape, is ignored.

local housekeeping = {}
housekeeping.__index = housekeeping

housekeeping.STORE_NAME = "hue_housekeeping"
housekeeping.STORE_VERSION = 1
housekeeping.MAX_ARM_MS = 3600000       -- one arm of the alarm, at most an hour
housekeeping.HOUR_MS = 3600000
housekeeping.HOUR_BUDGET = 100          -- optional requests in any rolling hour (see "Budgets" above)
housekeeping.OPTIONAL_GAP_MS = 30000    -- from the end of any run to the next optional start
housekeeping.GATE_POLL_MS = 250         -- the user gate looks again this often
housekeeping.GATE_MAX_MS = 10000        -- and lets a request go after this long
housekeeping.USER_QUIET_MS = 1500       -- no request within this long of a user write
housekeeping.GUARD_RECHECK_MS = 60000   -- a task held by a guard is looked at again
housekeeping.QUIET_S = { DIT_STARTUP = 300, DIT_UPDATING = 60, DIT_ADDING = 0 }
housekeeping.STARTUP_JITTER_S = 60      -- DIT_STARTUP's quiet period: 300 s plus 0 to 60 s
housekeeping.BACKOFF_S = 60
housekeeping.BACKOFF_CAP_S = 3600
housekeeping.DEFAULT_TIMEOUT_S = 300
housekeeping.DEFAULT_JITTER = 0.1
housekeeping.PERSIST_MIN_INTERVAL_S = 3600
housekeeping.MAX_TEXT = 200             -- characters of a result kept in the store

housekeeping.CLASSES = { essential = true, optional = true }
housekeeping.TRIGGERS = { startup = true, connect = true, event = true, timer = true, error = true, setting = true,
	click = true }
housekeeping.GUARDS = { paired = true, identity_ok = true, key_ok = true, stream_up = true, not_pairing = true,
	modules_idle = true }
-- A task that names no guards sends no keyed request to a bridge that is not
-- paired, verified and accepting the key, nor while Pair Bridge runs.
housekeeping.DEFAULT_GUARDS = { "paired", "identity_ok", "key_ok", "not_pairing" }

local NEVER = -math.huge
local PRIORITY = { click = 0, essential = 1, optional = 2 }

local function c4_time()
	return C4:GetTime()
end

-- Milliseconds from C4:GetTime, else os.time() (as bridge/commands.lua).
local function default_now()
	local ok, ms = pcall(c4_time)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

local function default_device_id()
	local ok, id = pcall(function() return C4:GetDeviceID() end)
	return ok and id or 0
end

-- djb2 over the text, kept below 2^31 so every step is exact in a double.
local function hash(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + text:byte(i)) % 2147483647
	end
	return h
end

-- A fraction in [0, 1), the same for the same device id and name on every
-- controller and in every run: the jitter, without math.random.
function housekeeping.spread(device_id, name)
	return (hash(tostring(device_id) .. "/" .. tostring(name)) % 10007) / 10007
end

local function set_of(list)
	local set = {}
	for _, v in ipairs(list or {}) do set[v] = true end
	return set
end

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function positive(value, what, name)
	if value == nil then
		return nil
	end
	assert(type(value) == "number" and value >= 0, string.format("housekeeping: task %s: %s must be a number >= 0",
		tostring(name), what))
	return value
end

local function plural(n, word)
	return string.format("%d %s%s", n, word, n == 1 and "" or "s")
end

-- opts: the ctx above.
function housekeeping.new(ctx)
	assert(type(ctx) == "table" and type(ctx.http) == "function", "housekeeping.new needs ctx.http")
	local self = setmetatable({
		ctx = ctx,
		log = ctx.log or require("common.log"),
		tasks = {},           -- name -> task record (spec fields and counters)
		order = {},           -- the records in the order of definition
		job = nil,            -- the running job, or nil: the lock
		alarm = nil,          -- the one scheduling timer
		alarm_token = nil,
		generation = 0,
		started = false,
		stopped = false,
		quiet_until = NEVER,
		last_end_ms = nil,    -- when the last run (any task) ended
		hour_log = {},        -- send times of counted optional requests
		stored = nil,         -- the store's tasks table as read at start()
		dit = nil,
	}, housekeeping)
	self.now = ctx.now_ms or default_now
	self.wall = ctx.wall or function() return math.floor(self.now() / 1000) end
	self.set_timer = ctx.set_timer or function(ms, fn) return C4:SetTimer(ms, fn) end
	self.persist_get = ctx.persist_get or function(name) return C4:PersistGetValue(name) end
	self.persist_set = ctx.persist_set or function(name, value) C4:PersistSetValue(name, value) end
	return self
end

-- Run fn(...) pcall-wrapped; a raise is logged, never passed on.
function housekeeping:protect(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		self.log.error("housekeeping: %s failed: %s", what, tostring(err))
	end
	return ok
end

local function cancel(timer)
	if timer then
		pcall(function() timer:Cancel() end)
	end
end

-- Tasks ---------------------------------------------------------------------

function housekeeping:device_id()
	local id = self.ctx.device_id
	if type(id) == "function" then
		local ok, value = pcall(id)
		id = ok and value or nil
	end
	if id == nil then
		id = default_device_id()
	end
	return id
end

function housekeeping:define(spec)
	assert(type(spec) == "table", "housekeeping: define needs a task table")
	local name = spec.name
	assert(type(name) == "string" and name ~= "", "housekeeping: a task needs a name")
	assert(not self.tasks[name], "housekeeping: task " .. name .. " is defined twice")
	assert(housekeeping.CLASSES[spec.class], "housekeeping: task " .. name .. ": class must be essential or optional")
	assert(type(spec.run) == "function", "housekeeping: task " .. name .. " needs run(job, done)")
	local interval = positive(spec.interval_s, "interval_s", name)
	assert(interval == nil or interval > 0, "housekeeping: task " .. name .. ": interval_s must be > 0")
	local triggers = spec.triggers or (interval and { "timer" } or {})
	for _, why in ipairs(triggers) do
		assert(housekeeping.TRIGGERS[why], "housekeeping: task " .. name .. ": unknown trigger " .. tostring(why))
	end
	assert(not set_of(triggers).timer or interval, "housekeeping: task " .. name .. ": trigger timer needs interval_s")
	local guards = spec.guards or housekeeping.DEFAULT_GUARDS
	for _, guard in ipairs(guards) do
		assert(housekeeping.GUARDS[guard], "housekeeping: task " .. name .. ": unknown guard " .. tostring(guard))
	end
	local budget = positive(spec.budget, "budget", name) or 0
	assert(budget == math.floor(budget), "housekeeping: task " .. name .. ": budget must be a whole number")
	assert(spec.class == "essential" or budget <= housekeeping.HOUR_BUDGET,
		"housekeeping: task " .. name .. ": an optional budget above the hourly budget could never run")
	assert(not spec.persist or (interval and interval >= housekeeping.PERSIST_MIN_INTERVAL_S),
		"housekeeping: task " .. name .. ": persist needs interval_s of an hour or more")
	local jitter = positive(spec.jitter, "jitter", name) or housekeeping.DEFAULT_JITTER
	assert(jitter <= 1, "housekeeping: task " .. name .. ": jitter is a fraction of the interval")
	local backoff = spec.backoff_s or housekeeping.BACKOFF_S
	if type(backoff) == "table" then
		assert(#backoff > 0, "housekeeping: task " .. name .. ": backoff_s needs at least one delay")
		for _, s in ipairs(backoff) do positive(s, "backoff_s", name) end
	else
		positive(backoff, "backoff_s", name)
	end
	local timeout = positive(spec.timeout_s, "timeout_s", name) or housekeeping.DEFAULT_TIMEOUT_S
	assert(timeout > 0, "housekeeping: task " .. name .. ": timeout_s must be > 0")

	local t = {
		name = name,
		class = spec.class,
		run = spec.run,
		trigger_set = set_of(triggers),
		interval_ms = interval and interval * 1000 or nil,
		jitter_ms = interval and math.floor(interval * 1000 * jitter * housekeeping.spread(self:device_id(), name)) or 0,
		debounce_ms = (positive(spec.debounce_s, "debounce_s", name) or 0) * 1000,
		min_gap_ms = (positive(spec.min_gap_s, "min_gap_s", name) or 0) * 1000,
		budget = budget,
		timeout_ms = timeout * 1000,
		guards = guards,
		persist = spec.persist == true,
		backoff = backoff,
		backoff_max_ms = (positive(spec.backoff_max_s, "backoff_max_s", name) or housekeeping.BACKOFF_CAP_S) * 1000,
		refreshes = spec.refreshes or {},
		order = #self.order + 1,
		-- Counters and the pending trigger.
		pending = false,      -- a trigger waits for a run
		click = false,        -- a click is among the pending triggers
		why = nil,            -- the latest pending trigger
		trigger_at = nil,     -- when it came (the debounce counts from here)
		callers = {},         -- done callbacks for the next run
		running = false,
		last_run_ms = nil,    -- end of the last run
		last_ok_ms = nil,     -- end of the last successful run
		last_ok = nil,        -- the last run's result
		last_text = nil,
		runs = 0,
		fails = 0,            -- failures in a row
	}
	self.tasks[name] = t
	self.order[#self.order + 1] = t
	if self.stored then
		self:apply_stored(t)
	end
	if self.started and t.trigger_set.startup then
		self:trigger(t, "startup")
	end
	self:plan()
	return t
end

-- The backoff after t.fails failures in a row, in ms.
local function backoff_ms(t)
	local cap = math.min(t.backoff_max_ms, housekeeping.BACKOFF_CAP_S * 1000, t.interval_ms or math.huge)
	local delay
	if type(t.backoff) == "table" then
		delay = t.backoff[math.min(t.fails, #t.backoff)] * 1000
	else
		delay = t.backoff * 1000 * 2 ^ (math.max(1, t.fails) - 1)
	end
	return math.min(delay, cap)
end

-- When the task wants to run, before the engine's own gaps; nil: it does not.
local function want_at(t)
	if t.click then
		return t.trigger_at
	end
	local want
	if t.pending then
		want = t.trigger_at + t.debounce_ms
	end
	if t.interval_ms then
		local fresh = t.last_ok_ms and (t.last_ok_ms + t.interval_ms + t.jitter_ms) or NEVER
		want = want and math.min(want, fresh) or fresh
	end
	-- After a failure the retry waits for the backoff, and so does a trigger
	-- that came before the failed run ended; a trigger after it is news (a
	-- stream that connected again, say) and goes at its debounce.
	if t.fails > 0 and t.last_run_ms and not (t.pending and t.trigger_at > t.last_run_ms) then
		local retry = t.last_run_ms + backoff_ms(t)
		want = want and math.max(want, retry) or retry
	end
	return want
end

-- The earliest the task could start, all gaps counted, and its want; nil
-- when it wants nothing.
function housekeeping:ready_at(t)
	local want = want_at(t)
	if want == nil then
		return nil
	end
	if t.click then
		return want, want
	end
	local at = want
	if t.last_run_ms then
		at = math.max(at, t.last_run_ms + t.min_gap_ms)
	end
	if t.class == "optional" then
		at = math.max(at, self.quiet_until)
		if self.last_end_ms then
			at = math.max(at, self.last_end_ms + housekeeping.OPTIONAL_GAP_MS)
		end
	end
	return at, want
end

-- True when an optional run of this task counts against the hourly budget.
local function counted(t)
	return t.class == "optional" and not t.click
end

-- Counted requests sent in the rolling hour up to now (older ones pruned).
function housekeeping:hour_used(now)
	local log = self.hour_log
	local first = 1
	while log[first] and log[first] <= now - housekeeping.HOUR_MS do
		first = first + 1
	end
	if first > 1 then
		local kept = {}
		for i = first, #log do kept[#kept + 1] = log[i] end
		self.hour_log = kept
	end
	return #self.hour_log
end

-- When the task's whole budget fits in the rolling hour: now, or later.
function housekeeping:budget_free_at(t, now)
	if not counted(t) or t.budget == 0 then
		return now
	end
	local used = self:hour_used(now)
	local over = used - (housekeeping.HOUR_BUDGET - t.budget)
	if over <= 0 then
		return now
	end
	return self.hour_log[over] + housekeeping.HOUR_MS
end

-- true, or false and the first guard that does not hold.
function housekeeping:guards_ok(t)
	if #t.guards == 0 then
		return true
	end
	local ok, state = pcall(self.ctx.state or function() return nil end)
	if not ok or type(state) ~= "table" then
		return false, "state unreadable"
	end
	for _, guard in ipairs(t.guards) do
		if state[guard] ~= true then
			return false, guard
		end
	end
	return true
end

-- The time the task could start (<= now: it can start now) and its want;
-- nil when it wants nothing or runs.
function housekeeping:candidate(t, now)
	if t.running then
		return nil
	end
	local at, want = self:ready_at(t)
	if at == nil then
		return nil
	end
	if at > now then
		return at, want
	end
	local free = self:budget_free_at(t, now)
	if free > now then
		return free, want
	end
	if not self:guards_ok(t) then
		-- A held click is answered at the next tick (refuse_held_clicks).
		return t.click and now or now + housekeeping.GUARD_RECHECK_MS, want
	end
	return now, want
end

-- The alarm --------------------------------------------------------------------

function housekeeping:cancel_alarm()
	cancel(self.alarm)
	self.alarm, self.alarm_token = nil, nil
end

function housekeeping:arm(delay_ms)
	self:cancel_alarm()
	local token = {}
	self.alarm_token = token
	self.alarm = self.set_timer(math.max(1, math.floor(delay_ms)), function()
		if self.alarm_token ~= token then
			return
		end
		self.alarm, self.alarm_token = nil, nil
		self:protect("alarm", self.tick, self)
	end)
end

-- Arm the alarm for the earliest time anything could start; none while a
-- job runs (its end plans again) or nothing is wanted.
function housekeeping:plan()
	if not self.started or self.stopped or self.job then
		return
	end
	local now = self.now()
	local next_at
	for _, t in ipairs(self.order) do
		local at = self:candidate(t, now)
		if at and (next_at == nil or at < next_at) then
			next_at = at
		end
	end
	if next_at == nil then
		self:cancel_alarm()
		return
	end
	self:arm(math.min(next_at - now, housekeeping.MAX_ARM_MS))
end

-- A click that a guard holds is answered now rather than left waiting.
function housekeeping:refuse_held_clicks()
	for _, t in ipairs(self.order) do
		if t.click and not t.running then
			local ok, guard = self:guards_ok(t)
			if not ok then
				local callers = t.callers
				t.callers, t.click, t.pending, t.why = {}, false, false, nil
				self.log.info("housekeeping: %s (click): not now, %s does not hold", t.name, tostring(guard))
				self:answer(callers, false, "not now: " .. tostring(guard) .. " does not hold")
			end
		end
	end
end

function housekeeping:tick()
	if self.stopped or self.job then
		return
	end
	self:refuse_held_clicks()
	local now = self.now()
	local best, best_key
	for _, t in ipairs(self.order) do
		local at, want = self:candidate(t, now)
		if at and at <= now then
			local key = { t.click and PRIORITY.click or PRIORITY[t.class], want, t.order }
			if not best or key[1] < best_key[1] or (key[1] == best_key[1] and (key[2] < best_key[2]
					or (key[2] == best_key[2] and key[3] < best_key[3]))) then
				best, best_key = t, key
			end
		end
	end
	if best then
		self:start_run(best, now)
	else
		self:plan()
	end
end

-- Triggers --------------------------------------------------------------------

function housekeeping:trigger(t, why, done)
	t.pending = true
	t.trigger_at = self.now()
	t.why = why
	if why == "click" then
		t.click = true
	end
	if done then
		t.callers[#t.callers + 1] = done
	end
end

-- A trigger for one task: "click" (a person asked: front of the queue, no
-- gate, no debounce), or one of the task's own triggers. done(ok, text) is
-- answered once. Returns true when the trigger was taken.
function housekeeping:poke(name, why, done)
	why = why or "event"
	local t = self.tasks[name]
	local refusal
	if self.stopped then
		refusal = "stopped"
	elseif not t then
		refusal = "no task " .. tostring(name)
	elseif why ~= "click" and not t.trigger_set[why] then
		refusal = string.format("%s is not a trigger of %s", tostring(why), name)
	end
	if refusal then
		self.log.warn("housekeeping: poke refused: %s", refusal)
		if done then
			self:answer({ done }, false, refusal)
		end
		return false
	end
	self:trigger(t, why, done)
	self.log.debug("housekeeping: %s poked (%s)%s", name, why, t.running and "; one more run after this one" or "")
	self:plan()
	return true
end

-- The driver's state changed (a guard may hold now): look again at once.
function housekeeping:wake()
	if self.started and not self.stopped and not self.job then
		self:arm(1)
	end
end

-- A success: fresh now, no failures in a row.
local function freshen(t, now)
	t.last_ok_ms, t.last_run_ms, t.fails = now, now, 0
	t.last_ok = true
end

-- Work done outside the engine counts as this task's successful run.
function housekeeping:mark_fresh(name)
	local t = self.tasks[name]
	if not t then
		return false
	end
	freshen(t, self.now())
	if t.persist then
		self:save()
	end
	self:plan()
	return true
end

-- Runs ---------------------------------------------------------------------

function housekeeping:alive(job)
	return self.job == job and not job.finished and not self.stopped and job.gen == self.generation
end

function housekeeping:answer(callers, ok, text)
	for _, done in ipairs(callers or {}) do
		self:protect("a caller's done", done, ok, text)
	end
end

function housekeeping:start_run(t, now)
	local trigger = t.click and "click" or (t.pending and t.why) or (t.fails > 0 and "retry") or "timer"
	local job = {
		name = t.name,
		trigger = trigger,
		click = t.click,
		counted = counted(t),
		budget = t.budget,
		used = 0,            -- requests asked for (the budget counts these)
		sent = 0,            -- requests sent
		started_ms = now,
		gen = self.generation,
		callers = t.callers,
		queue = {},
		notes = {},
	}
	t.callers, t.pending, t.click, t.why = {}, false, false, nil
	t.running = true
	self.job = job
	job.http = function(req, cb)
		self:request(job, req, cb)
	end
	job.note = function(text)
		job.notes[#job.notes + 1] = tostring(text)
	end
	job.charge = function()
		return self:charge(job)
	end
	job.timer = self.set_timer(math.max(1, t.timeout_ms), function()
		if self:alive(job) then
			self:protect("timeout", self.finish, self, job, false,
				string.format("timed out after %d s", math.floor(t.timeout_ms / 1000)))
		end
	end)
	self.log.debug("housekeeping: %s starts (%s)", t.name, trigger)
	local ok, err = pcall(t.run, job, function(done_ok, text)
		self:finish(job, done_ok, text)
	end)
	if not ok then
		self:finish(job, false, "raised: " .. tostring(err))
	end
end

-- The run's end: counters, store, report, callers, then the next plan. A
-- second done, a done after a timeout or after reset, does nothing.
function housekeeping:finish(job, ok, text)
	if not self:alive(job) then
		return
	end
	ok = ok == true
	job.finished = true
	self.job = nil
	cancel(job.timer)
	cancel(job.gate_timer)
	local t = self.tasks[job.name]
	local now = self.now()
	t.running = false
	t.runs = t.runs + 1
	t.last_run_ms = now
	t.last_ok = ok
	t.last_text = text ~= nil and tostring(text) or nil
	local save = t.persist
	if ok then
		t.last_ok_ms, t.fails = now, 0
		for _, name in ipairs(t.refreshes) do
			local other = self.tasks[name]
			if other then
				freshen(other, now)
				save = save or other.persist
			end
		end
	else
		t.fails = t.fails + 1
	end
	self.last_end_ms = now
	if save then
		self:save()
	end
	self:report(job, t, ok, t.last_text, now)
	self:answer(job.callers, ok, t.last_text)
	self:plan()
end

function housekeeping:report(job, t, ok, text, now)
	local ms = now - job.started_ms
	local line = string.format("housekeeping: %s (%s): %s%s; %s, %.1f s", job.name, job.trigger,
		ok and "OK" or "failed", text and (": " .. text) or "", plural(job.sent, "request"), ms / 1000)
	if ok then
		self.log.info("%s", line)
	else
		self.log.warn("%s%s", line, t.fails > 0 and string.format("; next try in %d s", math.floor(
			backoff_ms(t) / 1000)) or "")
	end
	for _, note in ipairs(job.notes) do
		self.log.debug("housekeeping: %s: %s", job.name, note)
	end
	if self.ctx.on_status then
		self:protect("on_status", self.ctx.on_status, {
			task = job.name, trigger = job.trigger, class = t.class, requests = job.sent, budget = job.budget,
			ok = ok, text = text, ms = ms, notes = job.notes,
		})
	end
end

-- Requests -----------------------------------------------------------------

local function respond(self, job, cb, result)
	local ok, err = pcall(cb, result)
	if not ok then
		self.log.error("housekeeping: %s: a request's callback raised: %s", job.name, tostring(err))
		self:finish(job, false, "raised: " .. tostring(err))
	end
end

-- job.http: a GET within the run's budget, queued behind the run's request
-- in flight. A refused request is answered at once with { ok = false, err };
-- a request of a run that has ended is neither sent nor answered.
function housekeeping:request(job, req, cb)
	cb = cb or function() end
	if not self:alive(job) then
		return
	end
	req = req or {}
	local method = string.upper(tostring(req.method or "GET"))
	if method ~= "GET" then
		return respond(self, job, cb, { ok = false, err = "housekeeping only reads: " .. method .. " refused" })
	end
	if job.used >= job.budget then
		return respond(self, job, cb, { ok = false, err = string.format("request budget of %d used up", job.budget) })
	end
	job.used = job.used + 1
	job.queue[#job.queue + 1] = { req = req, cb = cb }
	self:pump(job)
end

-- job.charge: one request sent outside job.http, counted as job.http counts
-- (the report, and the rolling hour for an optional run), never refused.
-- After the run's end (a timeout, a reset) its chain may still be sending:
-- the hour still sees those requests.
function housekeeping:charge(job)
	if job.counted then
		self.hour_log[#self.hour_log + 1] = self.now()
	end
	if self:alive(job) then
		job.used = job.used + 1
		job.sent = job.sent + 1
		if job.used == job.budget + 1 then
			self.log.debug("housekeeping: %s sent more than its budget of %d by another path", job.name, job.budget)
		end
	end
end

function housekeeping:pump(job)
	if job.inflight or not job.queue[1] or not self:alive(job) then
		return
	end
	local item = table.remove(job.queue, 1)
	job.inflight = item
	self:gate(job, item.req, function()
		if not self:alive(job) then
			return
		end
		if job.counted then
			local now = self.now()
			if self:hour_used(now) >= housekeeping.HOUR_BUDGET then
				job.inflight = nil
				respond(self, job, item.cb, { ok = false, err = "hourly request budget used up" })
				return self:pump(job)
			end
			self.hour_log[#self.hour_log + 1] = now
		end
		local out = copy(item.req)
		out.quiet_ms = nil
		out.method = "GET"
		job.sent = job.sent + 1
		local ok, err = pcall(self.ctx.http, out, function(result)
			if job.inflight ~= item then
				return -- a second answer
			end
			job.inflight = nil
			if not self:alive(job) then
				return -- the run ended (timeout, reset, stop): its late result is dropped
			end
			respond(self, job, item.cb, type(result) == "table" and result or {})
			self:pump(job)
		end)
		if not ok then
			job.inflight = nil
			respond(self, job, item.cb, { ok = false, err = "request raised: " .. tostring(err) })
			self:pump(job)
		end
	end)
end

function housekeeping:user_active(quiet_ms)
	if not self.ctx.user_active then
		return false
	end
	local ok, active = pcall(self.ctx.user_active, quiet_ms)
	return ok and active and true or false
end

-- User first: go() once no user command is busy, or after GATE_MAX_MS.
function housekeeping:gate(job, req, go)
	if job.click then
		return go()
	end
	local quiet = tonumber(req.quiet_ms) or housekeeping.USER_QUIET_MS
	local since = self.now()
	local function check()
		job.gate_timer = nil
		if not self:alive(job) then
			return
		end
		if not self:user_active(quiet) then
			return go()
		end
		local waited = self.now() - since
		if waited >= housekeeping.GATE_MAX_MS then
			self.log.debug("housekeeping: %s: user commands busy for %d s; sending anyway", job.name,
				math.floor(waited / 1000))
			return go()
		end
		job.gate_timer = self.set_timer(housekeeping.GATE_POLL_MS, function()
			self:protect("user gate", check)
		end)
	end
	check()
end

-- Lifecycle -------------------------------------------------------------------

-- From OnDriverLateInit(dit): the quiet period, the store, the first alarm.
function housekeeping:start(dit)
	if self.stopped then
		return
	end
	local now = self.now()
	local quiet_s = housekeeping.QUIET_S[dit]
	if quiet_s == nil or dit == "DIT_STARTUP" then
		quiet_s = housekeeping.QUIET_S.DIT_STARTUP
			+ math.floor(housekeeping.STARTUP_JITTER_S * housekeeping.spread(self:device_id(), "startup"))
	end
	self.dit = dit
	self.quiet_until = now + quiet_s * 1000
	if not self.stored then
		self:load()
	end
	local first = not self.started
	self.started = true
	if first then
		for _, t in ipairs(self.order) do
			if t.trigger_set.startup then
				self:trigger(t, "startup")
			end
		end
	end
	self.log.info("housekeeping: started (%s); optional tasks wait %d s", tostring(dit or "no DIT"), quiet_s)
	self:plan()
end

-- Drop the running job: its late answers are ignored; its callers hear why
-- when `answer_why` is given.
function housekeeping:drop_job(answer_why)
	local job = self.job
	if not job then
		return
	end
	job.finished = true
	self.job = nil
	cancel(job.timer)
	cancel(job.gate_timer)
	local t = self.tasks[job.name]
	if t then
		t.running = false
	end
	self.log.info("housekeeping: %s dropped (%s)", job.name, answer_why or "stopped")
	if answer_why then
		self:answer(job.callers, false, "cancelled: " .. answer_why)
	end
end

-- An address change (the driver's address_gen) or, with forget, Forget
-- Pairing or another bridge paired: the running job is dropped, backoffs are
-- cleared; last runs are kept, or with forget cleared here and in the store.
function housekeeping:reset(generation, forget)
	self.generation = self.generation + 1
	self.address_gen = generation
	self:drop_job(forget and "pairing forgotten" or "bridge address changed")
	self:cancel_alarm()
	for _, t in ipairs(self.order) do
		t.fails = 0
		if forget then
			t.last_run_ms, t.last_ok_ms, t.last_ok, t.last_text, t.runs = nil, nil, nil, nil, 0
		end
	end
	if forget then
		self.stored = {}
		self:protect("store", self.persist_set, housekeeping.STORE_NAME,
			{ v = housekeeping.STORE_VERSION, tasks = {} })
	end
	self:plan()
end

-- OnDriverDestroyed: every timer cancelled, nothing answered, nothing more.
function housekeeping:stop()
	self.stopped = true
	self:drop_job(nil)
	self:cancel_alarm()
end

-- A copy of one task's counters (times in the engine's ms clock), or nil.
function housekeeping:info(name)
	local t = self.tasks[name]
	if not t then
		return nil
	end
	local at = self:ready_at(t)
	return {
		name = t.name, class = t.class, running = t.running, pending = t.pending, runs = t.runs, fails = t.fails,
		last_run_ms = t.last_run_ms, last_ok_ms = t.last_ok_ms, last_ok = t.last_ok, last_text = t.last_text,
		next_ms = at ~= NEVER and at or nil, jitter_ms = t.jitter_ms, hour_used = self:hour_used(self.now()),
	}
end

-- Persistence -------------------------------------------------------------------

function housekeeping:bridge_id()
	local fn = self.ctx.bridge_id
	if type(fn) ~= "function" then
		return nil
	end
	local ok, id = pcall(fn)
	return ok and id or nil
end

-- Wall-clock seconds of an engine time, and back; a stored time from the
-- future counts as now.
function housekeeping:wall_of(ms)
	return math.floor(self.wall() - (self.now() - ms) / 1000 + 0.5)
end

function housekeeping:ms_of(seconds)
	local wall = self.wall()
	return self.now() - (wall - math.min(seconds, wall)) * 1000
end

function housekeeping:load()
	self.stored = {}
	local ok, value = pcall(self.persist_get, housekeeping.STORE_NAME)
	if not ok or value == nil then
		return
	end
	if type(value) ~= "table" or value.v ~= housekeeping.STORE_VERSION or type(value.tasks) ~= "table" then
		self.log.warn("housekeeping: %s has an unknown shape; ignored", housekeeping.STORE_NAME)
		return
	end
	local current = self:bridge_id()
	if value.bridge_id ~= nil and current ~= nil and tostring(value.bridge_id) ~= tostring(current) then
		self.log.info("housekeeping: last runs stored for another bridge; discarded")
		return
	end
	for name, rec in pairs(value.tasks) do
		if type(name) == "string" and type(rec) == "table" then
			self.stored[name] = rec
		end
	end
	for _, t in ipairs(self.order) do
		self:apply_stored(t)
	end
end

function housekeeping:apply_stored(t)
	local rec = self.stored and self.stored[t.name]
	if not t.persist or type(rec) ~= "table" or t.last_run_ms then
		return
	end
	local at, ok_at = tonumber(rec.at), tonumber(rec.ok_at)
	if not at then
		return
	end
	t.last_run_ms = self:ms_of(at)
	t.last_ok_ms = ok_at and self:ms_of(ok_at) or nil
	t.last_ok = rec.ok == true
	t.last_text = type(rec.text) == "string" and rec.text or nil
	t.runs = math.max(0, math.floor(tonumber(rec.runs) or 0))
	t.fails = math.max(0, math.floor(tonumber(rec.fails) or 0))
end

-- One write of every persisted task's last run (and the entries of tasks
-- this build does not define, as they were).
function housekeeping:save()
	local tasks = {}
	for name, rec in pairs(self.stored or {}) do
		if not self.tasks[name] then
			tasks[name] = rec
		end
	end
	for _, t in ipairs(self.order) do
		if t.persist and t.last_run_ms then
			local text = t.last_text
			if text and #text > housekeeping.MAX_TEXT then
				text = text:sub(1, housekeeping.MAX_TEXT)
			end
			tasks[t.name] = {
				at = self:wall_of(t.last_run_ms),
				ok = t.last_ok == true,
				ok_at = t.last_ok_ms and self:wall_of(t.last_ok_ms) or nil,
				text = text,
				runs = t.runs,
				fails = t.fails,
			}
		end
	end
	self:protect("store", self.persist_set, housekeeping.STORE_NAME,
		{ v = housekeeping.STORE_VERSION, bridge_id = self:bridge_id(), tasks = tasks })
end

return housekeeping
