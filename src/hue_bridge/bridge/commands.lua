-- Coalescing command queue: Control4 light commands in, Hue PUTs out.
--
-- Why a queue at all, rather than one PUT per proxy command:
--
-- 1. Director runs one C4:url transfer per host at a time (docs/design.md,
--    "C4:url transfer scheduling"), so a burst of PUTs queues up and the last
--    one lands long after the slider stopped moving. Keeping one PUT in flight
--    per light and sending only the latest state keeps that queue short.
-- 2. Hue asks for about 10 commands per second to /resource/light and about
--    one per second to /resource/grouped_light; the REST API is not for
--    continuous fast streams. A token bucket per queue (opts.rate_per_sec
--    sustained, opts.burst at once; defaults RATE_PER_SEC and BURST) enforces
--    that across all rids of the queue. A keypad hold's start and its stop
--    never wait for a token (docs/zone-light-design.md Decision 9): they are
--    one request each, paced by the owner's thumb, and a late stop overshoots
--    the ramp; a slider drag is what the bucket is for, and it settles to the
--    latest level at the sustained rate.
-- 3. The light_v2 best-practice doc wants back-to-back brightness and colour
--    commands merged into one request. A short debounce (DEBOUNCE_MS) after
--    the last change does that.
-- 4. The bridge applies color.xy and ignores color_temperature.mirek when both
--    are in one body, so the pending state keeps only the most recent colour
--    mode: setting xy clears mirek and vice versa.
--
-- Pending state is the single source of truth per light. A PUT that fails
-- with 429, 5xx or a transport error is folded back under whatever arrived
-- since (latest wins) and flushed again after a growing backoff, for at most
-- MAX_AGE_S from the state's last change: after that it is dropped with one
-- warning, so a bridge that comes back never replays minutes-old slider
-- positions over what was set meanwhile (issue #43). Any other 4xx drops the
-- state, since repeating a rejected body cannot help, and so do the two
-- answers no retry can mend, "not paired" and "key rejected": the driver
-- gives them at once, without a request, until the owner pairs again.
--
-- The owner supplies `send(rid, body, done)` (an http.request PUT) and may
-- supply `now()` (a millisecond clock) for tests. Everything that runs later,
-- in a timer or in done(), is pcall-wrapped and checked against a generation
-- counter so that one bad send cannot break the queue and stop() silences
-- every late callback.

local log = require("common.log")

local commands = {}
commands.__index = commands

commands.DEBOUNCE_MS = 80            -- quiet time after the last change before a PUT
commands.RATE_PER_SEC = 10           -- Hue guidance for /resource/light
commands.BURST = 10                  -- token bucket capacity
commands.BACKOFF_MS = 500            -- first retry delay, doubled per consecutive failure
commands.BACKOFF_MAX_MS = 8000
commands.MAX_AGE_S = 30              -- a failing state is retried this long after its last change, then dropped
commands.DEFAULT_LIMITS = { min_dim = 1, mirek_min = 153, mirek_max = 500 }

-- Answers that no retry can mend: bridge_request (hue_bridge/driver.lua)
-- gives them at once, without a request, while the driver has no key or the
-- bridge has refused it. The pending state ends there (issue #43).
local FINAL_ERRORS = { ["not paired"] = true, ["key rejected"] = true }

local NUMERIC_FIELDS = { "brightness", "x", "y", "mirek", "rate" }

local function c4_time()
	return C4:GetTime()
end

-- Milliseconds from C4:GetTime, else os.time() (the pcall'd function is
-- hoisted: now() runs two or three times per PUT).
local function default_now()
	local ok, ms = pcall(c4_time)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function clamp(n, lo, hi)
	if n < lo then return lo end
	if n > hi then return hi end
	return n
end

local function round(n, decimals)
	local scale = 10 ^ (decimals or 0)
	return math.floor(n * scale + 0.5) / scale
end

-- opts:
--   send(rid, body, done)  issue the PUT; done(result) with http's result
--                          table { ok, code, json, err }
--   now()                  millisecond clock (default C4:GetTime)
--   rate_per_sec           sustained PUTs per second across the queue's rids
--                          (default commands.RATE_PER_SEC): once the bucket is
--                          empty, one more PUT every 1/rate_per_sec seconds
--   burst                  the bucket's capacity (default commands.BURST): how
--                          many PUTs go out at once after an idle period; the
--                          bucket refills to it at rate_per_sec and is full
--                          again after burst/rate_per_sec seconds of quiet
--   level_of(rid)          current brightness or nil, the start of a refused
--                          dim stop's fallback estimate
--   label                  what a rid is, for log lines (default "light"; the
--                          grouped_light queue passes "grouped_light")
function commands.new(opts)
	local rate = tonumber(opts.rate_per_sec) or commands.RATE_PER_SEC
	local burst = tonumber(opts.burst) or commands.BURST
	assert(rate > 0, "commands.new: rate_per_sec must be > 0")
	assert(burst >= 1, "commands.new: burst must be >= 1")
	return setmetatable({
		send = assert(opts.send, "commands.new needs opts.send"),
		now = opts.now or default_now,
		level_of = opts.level_of,  -- rid -> current brightness or nil (start of a dim's fallback estimate)
		label = opts.label or "light",
		rate = rate,                -- tokens per second
		burst = burst,              -- token bucket capacity
		lights = {},                -- rid -> { pending, timer(_kind), inflight, failures, limits, updated_at, final_err }
		generation = 0,
		tokens = burst,
		refilled_at = nil,          -- ms of the last refill; nil until the first take
		counters = { sent = 0, retried = 0, dropped = 0, coalesced = 0 },
	}, commands)
end

-- True for a pending state the bucket must not hold back: a dim stop, or a
-- hold's start (a whole-range dimming_delta: no `delta`, or 100). A scene
-- slider's relative move (a smaller `delta`) is a drag like any other and
-- waits its turn, as absolute levels and colours do.
function commands.urgent(pending)
	if type(pending) ~= "table" or pending.dim == nil then
		return false
	end
	if pending.dim == "stop" then
		return true
	end
	return pending.delta == nil or pending.delta >= 100
end

-- Merge one set() call's fields into a pending table, in place. Order inside
-- a call: colour (mirek, then xy so xy wins when both are given), brightness
-- (0 means off; > 0 implies on), then an explicit `on`, which beats the
-- implication. Turning on after a "to zero" forgets the zero so the light
-- comes back at its remembered level.
local function merge(pending, fields)
	local f = {}
	for _, name in ipairs(NUMERIC_FIELDS) do
		f[name] = tonumber(fields[name])
	end
	if fields.on == true or fields.on == "true" then
		f.on = true
	elseif fields.on == false or fields.on == "false" then
		f.on = false
	end

	-- A relative dim (Hue's dimming_delta) is an action, not a state: it
	-- replaces a pending brightness or on/off, and either of those replaces
	-- a pending dim. `level` travels with a stop as the fallback brightness.
	if fields.dim == "up" or fields.dim == "down" or fields.dim == "stop" then
		pending.dim = fields.dim
		pending.level = tonumber(fields.level)
		pending.delta = tonumber(fields.delta)
		pending.brightness, pending.on = nil, nil
	elseif f.brightness or f.on ~= nil then
		pending.dim, pending.level, pending.delta = nil, nil, nil
	end

	if f.mirek then
		pending.mirek = f.mirek
		pending.x, pending.y = nil, nil
	end
	if f.x or f.y then
		pending.x = f.x or pending.x
		pending.y = f.y or pending.y
		pending.mirek = nil
	end
	if f.brightness then
		if f.brightness <= 0 then
			pending.brightness, pending.on = 0, false
		else
			pending.brightness, pending.on = f.brightness, true
		end
	end
	if f.on ~= nil then
		pending.on = f.on
		if f.on and pending.brightness == 0 then
			pending.brightness = nil
		end
	end
	if f.rate then
		pending.rate = f.rate
	end
	return pending
end

-- The PUT body for a pending state. Pure, so it can be tested on its own.
-- Brightness 0 is `on:false` with no dimming; dimming is clamped to
-- [min_dim, 100] and rounded to 2 decimals; mirek is an integer inside the
-- light's range; xy is clamped to [0, 1] and rounded to 4 decimals and needs
-- both coordinates. dynamics.duration goes along only when there is
-- something for it to apply to.
function commands.body(pending, limits)
	limits = limits or commands.DEFAULT_LIMITS
	local body = {}
	if pending.dim then
		-- Hue ramps the whole range over `rate` and keeps the lights' relative
		-- levels; "stop" ends a ramp where it is [verified on a grouped_light
		-- 2026-10-23; assumed for a single light; docs/keypad-design.md].
		if pending.dim == "stop" then
			body.dimming_delta = { action = "stop" }
		else
			-- `delta` moves by that much (a scene slider); a hold moves the
			-- whole range.
			local delta = pending.delta and clamp(pending.delta, 0, 100) or 100
			body.dimming_delta = { action = pending.dim, brightness_delta = round(delta, 2) }
			if pending.rate and pending.rate > 0 then
				body.dynamics = { duration = round(pending.rate) }
			end
		end
		return body
	end
	if pending.brightness ~= nil and pending.brightness <= 0 then
		body.on = { on = false }
	else
		if pending.on ~= nil then
			body.on = { on = pending.on == true }
		end
		if pending.brightness ~= nil then
			body.dimming = { brightness = round(clamp(pending.brightness, limits.min_dim or 1, 100), 2) }
		end
	end
	if pending.x ~= nil and pending.y ~= nil then
		body.color = { xy = { x = round(clamp(pending.x, 0, 1), 4), y = round(clamp(pending.y, 0, 1), 4) } }
	elseif pending.mirek ~= nil then
		local lo = limits.mirek_min or commands.DEFAULT_LIMITS.mirek_min
		local hi = limits.mirek_max or commands.DEFAULT_LIMITS.mirek_max
		body.color_temperature = { mirek = clamp(round(pending.mirek), lo, hi) }
	end
	if next(body) ~= nil and pending.rate and pending.rate > 0 then
		body.dynamics = { duration = round(pending.rate) }
	end
	return body
end

function commands:light(rid)
	local light = self.lights[rid]
	if not light then
		light = { failures = 0 }
		self.lights[rid] = light
	end
	return light
end

-- Cache a light's limits (from the registry's model). Missing values keep
-- the defaults.
function commands:limits(rid, limits)
	local merged = copy(commands.DEFAULT_LIMITS)
	for k, v in pairs(limits or {}) do merged[k] = v end
	self:light(rid).limits = merged
end

local function cancel_timer(light)
	if light.timer then
		light.timer:Cancel()
		light.timer, light.timer_kind = nil, nil
	end
end

-- One timer per light, whatever it is waiting for. The callback runs
-- pcall-wrapped and only for the generation that armed it.
function commands:arm(rid, light, delay_ms, kind)
	cancel_timer(light)
	local gen = self.generation
	light.timer_kind = kind
	light.timer = C4:SetTimer(math.max(1, delay_ms), function()
		if gen ~= self.generation then
			return
		end
		light.timer, light.timer_kind = nil, nil
		local ok, err = pcall(self.flush, self, rid)
		if not ok then
			log.error("command queue: flush of %s failed: %s", tostring(rid), tostring(err))
		end
	end)
end

-- Merge `fields` into the light's pending state and (re)start its debounce.
-- A retry already armed is left alone, and so is a token wait unless the
-- merged state became urgent (a hold's start or stop must not sit behind a
-- drag's wait): the new state simply replaces what will be sent when the
-- timer fires.
function commands:set(rid, fields)
	local light = self:light(rid)
	if light.pending then
		self.counters.coalesced = self.counters.coalesced + 1
	else
		light.pending = {}
	end
	merge(light.pending, fields or {})
	light.updated_at = self.now() -- the retries' age counts from here
	if light.timer_kind == "retry" or (light.timer_kind == "wait" and not commands.urgent(light.pending)) then
		return
	end
	self:arm(rid, light, commands.DEBOUNCE_MS, "debounce")
end

-- Token bucket (self.rate tokens per second, self.burst at most). Returns
-- true and takes a token, or false and the ms to wait. An urgent request
-- (commands.urgent) neither waits nor takes a token: a hold is two requests
-- paced by a thumb, and counting them would make the tap that often follows
-- a hold wait behind the drag that emptied the bucket a moment before.
function commands:take_token(urgent)
	local now = self.now()
	if self.refilled_at then
		local elapsed = math.max(0, now - self.refilled_at)
		self.tokens = math.min(self.burst, self.tokens + elapsed * self.rate / 1000)
	end
	self.refilled_at = now
	if urgent then
		return true
	end
	if self.tokens >= 1 then
		self.tokens = self.tokens - 1
		return true
	end
	return false, math.ceil((1 - self.tokens) * 1000 / self.rate)
end

-- Send the pending state now if nothing stands in the way: an in-flight PUT
-- (done() flushes again when it returns) or an empty bucket (a timer does).
function commands:flush(rid)
	local light = self.lights[rid]
	if not light or not light.pending or light.inflight then
		return
	end
	local ok, wait = self:take_token(commands.urgent(light.pending))
	if not ok then
		self:arm(rid, light, wait, "wait")
		return
	end

	local fields = light.pending
	light.pending = nil
	local body = commands.body(fields, light.limits)
	if next(body) == nil then
		return -- nothing the bridge could act on (a lone rate, say)
	end
	light.inflight = fields
	if fields.dim == "up" or fields.dim == "down" then
		light.dim_start = { t = self.now(), dir = fields.dim, duration = fields.rate or 0,
			from = self.level_of and tonumber(self.level_of(rid)) or nil }
	elseif fields.dim == "stop" then
		light.dim_stop_at = self.now()
	end
	if log.enabled("debug") then
		log.debug("PUT %s %s: %s", self.label, tostring(rid), C4:JsonEncode(body))
	end

	local gen = self.generation
	local sent, err = pcall(self.send, rid, body, function(result)
		if gen ~= self.generation or light.inflight ~= fields then
			return -- stopped since, or a duplicate done()
		end
		local done_ok, done_err = pcall(self.on_done, self, rid, light, result or {})
		if not done_ok then
			log.error("command queue: done() for %s failed: %s", tostring(rid), tostring(done_err))
		end
	end)
	if sent then
		self.counters.sent = self.counters.sent + 1
	else
		-- A raising send is a bug in the glue, not a bridge condition: retrying
		-- would only repeat it. Drop this state and carry on with the next.
		log.error("command queue: send for %s raised: %s", tostring(rid), tostring(err))
		light.inflight = nil
		self.counters.dropped = self.counters.dropped + 1
	end
end

-- The level a refused stop falls back to: the device's own estimate sent
-- with the stop, else the start level moved by the elapsed share of the
-- ramp. nil when neither is known (the ramp then runs to its end).
function commands:stop_fallback(light, sent)
	local level = tonumber(sent.level)
	local start = light.dim_start
	if not level and start and start.from and start.duration > 0 then
		local elapsed = (light.dim_stop_at or self.now()) - start.t
		local moved = 100 * math.min(1, math.max(0, elapsed / start.duration))
		level = start.dir == "up" and start.from + moved or start.from - moved
	end
	if not level then
		return nil
	end
	return math.floor(math.max(1, math.min(100, level)) + 0.5)
end

local function retriable(result)
	return result.code == nil or result.code == 429 or result.code >= 500
end

-- End a light's state: whatever was pending goes, with its timer.
function commands:drop(light)
	cancel_timer(light)
	light.pending = nil
	light.failures = 0
	self.counters.dropped = self.counters.dropped + 1
end

function commands:on_done(rid, light, result)
	local sent = light.inflight
	light.inflight = nil
	if result.ok then
		light.failures = 0
		light.final_err = nil
	elseif FINAL_ERRORS[result.err] then
		-- Not paired, or the key refused: nothing gets through until the owner
		-- pairs again, and a state kept until then would be stale. The newer
		-- fields that arrived meanwhile go too. One warning per rid and
		-- condition: a slider dragged meanwhile would warn at every step.
		self:drop(light)
		if light.final_err ~= result.err then
			light.final_err = result.err
			log.warn("%s %s: %s, dropping the command (no retry)", self.label, tostring(rid), tostring(result.err))
		else
			log.debug("%s %s: %s, dropping the command (no retry)", self.label, tostring(rid), tostring(result.err))
		end
		return
	elseif retriable(result) then
		light.failures = light.failures + 1
		local delay = math.min(commands.BACKOFF_MS * 2 ^ (light.failures - 1), commands.BACKOFF_MAX_MS)
		local now = self.now()
		local age = now - (light.updated_at or now)
		if age + delay > commands.MAX_AGE_S * 1000 then
			-- The retry would go out more than MAX_AGE_S after the owner last
			-- changed this state: by then it is stale (issue #43).
			self:drop(light)
			log.warn("%s %s: %s; dropping the command, last changed %d s ago (retries stop after %d s)",
				self.label, tostring(rid), tostring(result.err), math.floor(age / 1000 + 0.5), commands.MAX_AGE_S)
			return
		end
		-- Newer fields win over the ones that failed.
		light.pending = merge(copy(sent), light.pending or {})
		self.counters.retried = self.counters.retried + 1
		log.warn("%s %s: %s, retrying in %d ms (attempt %d)", self.label, tostring(rid), tostring(result.err), delay,
			light.failures)
		self:arm(rid, light, delay, "retry")
		return
	else
		light.failures = 0
		self.counters.dropped = self.counters.dropped + 1
		log.warn("%s %s: %s, dropping the command", self.label, tostring(rid), tostring(result.err))
		if sent and sent.dim == "stop" then
			local level = self:stop_fallback(light, sent)
			if level then
				log.warn("%s %s: the bridge refused the dim stop; setting %d %% instead", self.label, tostring(rid),
					level)
				light.pending = merge(light.pending or {}, { brightness = level })
			end
		end
	end
	if light.pending then
		self:flush(rid) -- changes made while this PUT was in flight
	end
end

-- Cancel every timer and forget pending and in-flight state. Late done()
-- callbacks and timers from before are ignored; set() works again after.
function commands:stop()
	self.generation = self.generation + 1
	for _, light in pairs(self.lights) do
		cancel_timer(light)
		light.pending, light.inflight, light.failures = nil, nil, 0
	end
end

-- A copy of the pending fields for a light, or nil when nothing is pending.
function commands:pending(rid)
	local light = self.lights[rid]
	return light and light.pending and copy(light.pending) or nil
end

function commands:stats()
	return copy(self.counters)
end

return commands
