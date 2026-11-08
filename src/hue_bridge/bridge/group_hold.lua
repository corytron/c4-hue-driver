-- Keypad holds on a grouped_light (issue #249, docs/group-hold-design.md):
-- the one place that decides how a hold on a Hue Scene device, a zone light
-- or a room light reaches Hue. bridge/scenes.lua and bridge/zone_lights.lua
-- keep calling ctx.group_dim(grouped_light_rid, body, level) as before (G1);
-- the driver's group_dim hook hands every call to gh:dim here.
--
-- Why not one dimming_delta on the grouped_light, as before: measured on the
-- house on 2026-10-25 (#249), Hue ignores dynamics.duration for a
-- dimming_delta on a grouped_light and covers the whole delta in about a
-- second, so the release's stop comes too late and the lamps jump to full or
-- off [verified: keypad holds on two room scenes and a zone light, and a
-- direct PUT with a 10 s duration on a zone's grouped_light]. On a single
-- light Hue honours the duration and the stop: a lamp held for about 3 s of a
-- 10 s ramp ended near 46 % [verified: the same session]. So (G2 to G7):
--
--   per-light  1 to PER_LIGHT_MAX lit members: the hold's start goes to each
--              lit member through the light queue as a single Hue Light's
--              hold does ({ dim, delta = 100, rate }), in member order, and
--              its stop to each light that took a start ({ dim = "stop" }, no
--              level: each light keeps the light queue's own refused-stop
--              fallback). A smooth ramp at the hold rate; relative levels kept.
--   stepped    more lit members than that, or a Hue scene running on the
--              group (G6a): one group dimming_delta step without a duration
--              at once, then one every STEP_MS while held, each
--              min(100, 100 * STEP_MS / duration) % (one step of 100 for a
--              duration of 0), until they add up to 100 or the stop. The stop
--              cancels the timer and sends nothing: a group stop would only
--              cut short the step in flight, which finishes Hue's short
--              default transition. Visible steps; relative levels kept.
--   group      a down with no lit member, a grouped_light the caches do not
--              know, or no members: the start and its stop go to the group
--              queue exactly as before, rate and level included (G6).
--
-- An up with no lit member takes every member as its set (A1): a hold from
-- off sends a 1 % start and the dim about 600 ms later, before the event
-- stream has reported the lamps on, and the mode follows the member count.
--
-- A Hue scene running on the group keeps the hold on the grouped_light (G6a,
-- ctx.keep_group): a relative or absolute group dim left a time-based scene
-- active and a dynamic palette playing, while a change to one light ended a
-- scene [verified: V11, docs/smart-scenes-research.md]; that per-light dims
-- end a schedule as well is [assumed] (not measured).
--
-- Everything else group_dim carries (a scene slider's relative move: a
-- brightness_delta under 100) and a stop with no running hold go to the
-- group queue unchanged (G2, G7), with the fields the old hook built:
-- dim = dimming_delta.action, delta = brightness_delta, rate =
-- dynamics.duration, level = tonumber(level).
--
-- [assumed] A dimming_delta leaves lamps that are off alone, which is why
-- only the lit members get per-light starts (G3; on the contract's list to
-- measure, §5). [assumed] A stop that replaced its start in the light queue
-- is harmless: Hue stops a ramp that never started (G4). Hue's guidance is
-- about ten requests a second to lights and one a second to grouped_lights
-- [verified: Core Concepts, as bridge/commands.lua and the driver's queues
-- say], hence the per-light ceiling and the step period.
--
-- One hold per grouped_light (G7): a new start ends the running hold first,
-- as its stop would. A hold stays registered until its stop or the next
-- start, even after its steps added up to 100, so the release of a finished
-- stepped hold sends nothing either. The lit members are read once, at the
-- start (G3): members that change during the hold are not re-read.
--
-- Every ctx callback and every timer body runs pcall-wrapped (a raise is
-- logged, never passed on), and a step timer acts only for the hold that
-- armed it (its token), so a timer whose Cancel came too late, or one from
-- before stop_all(), sends nothing.
--
--   local gh = group_hold.new(ctx)
--   gh:dim(grouped_light_rid, body, level)   true when carried out (the group_dim contract)
--   gh:stop_all()                            teardown (G8): timers cancelled, nothing sent
--
-- ctx (group_set is required):
--   members(grouped_light_rid)     member light rids in the group's order; {} when unknown
--   is_on(light_rid)               the cached on state: true, false or nil (only true counts as lit)
--   light_set(light_rid, fields)   the light queue's set(); true when queued
--   group_set(grouped_light_rid, fields)   the group queue's set(); true when queued
--   set_timer(ms, fn)              a one-shot timer with :Cancel() (default C4:SetTimer)
--   keep_group(grouped_light_rid)  true while a time-based scene is active or a scene plays its
--                                  dynamic palette on that room or zone (G6a); raising or missing = false
--   log                            common.log or a stand-in (default common.log)

local default_log = require("common.log")

local group_hold = {}
group_hold.__index = group_hold

group_hold.PER_LIGHT_MAX = 10  -- G4: the most lit members a hold sends per-light dims to
group_hold.STEP_MS = 1000      -- G5: a stepped hold's period (Hue's guidance for groups, the group queue's rate)

-- What is left of the 100 % below this is not worth another step: it keeps
-- float noise (three steps of 33.33... %) from sending a last step of nothing.
local REMAINDER_MIN = 0.5

local function c4_timer(ms, fn)
	return C4:SetTimer(ms, fn)
end

local DEFAULTS = { set_timer = c4_timer }

local function short(rid)
	return tostring(rid):sub(1, 8)
end

local function round2(n)
	return math.floor(n * 100 + 0.5) / 100
end

local function percent(n)
	return string.format("%g", round2(n))
end

local function count_text(n)
	return n .. (n == 1 and " light" or " lights")
end

local function ms_text(duration)
	return string.format("%d ms", math.floor((duration or 0) + 0.5))
end

local function cancel(timer)
	if timer then
		pcall(function() timer:Cancel() end)
	end
end

function group_hold.new(ctx)
	ctx = ctx or {}
	assert(type(ctx.group_set) == "function", "group_hold.new: ctx.group_set is required")
	return setmetatable({
		ctx = ctx,
		log = ctx.log or default_log,
		holds = {},   -- grouped_light rid -> the running hold { token, mode, action, lights?, count, step?, sent?, timer? }
		tokens = 0,   -- the last token given to a hold
	}, group_hold)
end

-- ctx[name](...) pcall-wrapped: its first result, or nil (logged) when it
-- raised; nil as well for a callback the ctx does not have.
function group_hold:call(name, ...)
	local fn = self.ctx[name] or DEFAULTS[name]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		self.log.error("group hold: ctx.%s raised: %s", name, tostring(result))
		return nil
	end
	return result
end

-- The group queue's fields for a dimming_delta body, exactly as the old
-- group_dim hook built them, so the pass-through paths (G2, G6, G7) reach
-- the queue unchanged. A zone light's stop carries the level it ended at,
-- written only if the bridge refuses the stop (as the light queue does).
function group_hold.fields(body, level)
	local delta = body.dimming_delta
	return {
		dim = delta.action,
		delta = delta.brightness_delta,
		rate = type(body.dynamics) == "table" and body.dynamics.duration or nil,
		level = tonumber(level),
	}
end

-- The request as before: to the group queue.
function group_hold:pass(rid, fields)
	return self:call("group_set", rid, fields) == true
end

-- A keypad hold's start or stop, or anything else a dimming_delta carries
-- (scenes:dim, scenes:level's relative move, zone_lights:dim). Returns true
-- when the request was carried out: something queued, or a stepped hold's
-- stop, which by design queues nothing (G5) and must not read as a failure
-- to the callers' "nothing queued" warning.
function group_hold:dim(rid, body, level)
	local delta = type(body) == "table" and body.dimming_delta or nil
	if type(delta) ~= "table" then
		return false
	end
	if type(rid) ~= "string" or rid == "" then
		self.log.warn("group hold: a dim without a grouped_light ignored")
		return false
	end
	local fields = group_hold.fields(body, level)
	local hold = self.holds[rid]
	if fields.dim == "stop" then
		if hold then
			return self:finish(rid, hold, "stop")
		end
		return self:pass(rid, fields)  -- G7: no running hold, a stop as before (harmless)
	end
	if (fields.dim ~= "up" and fields.dim ~= "down") or (fields.delta ~= nil and tonumber(fields.delta) ~= 100) then
		return self:pass(rid, fields)  -- G2: not a hold (a slider's move)
	end
	if hold then
		self:finish(rid, hold, "stop before a new start")  -- G7
	end
	return self:start(rid, fields)
end

-- G3: the members that are on now and all the members, both in member
-- order, each light once.
function group_hold:lit_members(rid)
	local members = self:call("members", rid)
	if type(members) ~= "table" then
		members = {}
	end
	local lit, all, seen = {}, {}, {}
	for _, light_rid in ipairs(members) do
		if not seen[light_rid] then
			seen[light_rid] = true
			all[#all + 1] = light_rid
			if self:call("is_on", light_rid) == true then
				lit[#lit + 1] = light_rid
			end
		end
	end
	return lit, all
end

-- The hold's set (G3, A1), then its mode (G4, G5, G6a).
function group_hold:start(rid, fields)
	local duration = tonumber(fields.rate)
	local set, all = self:lit_members(rid)
	local note = ""
	if #set == 0 then
		if fields.dim ~= "up" or #all == 0 then
			-- G6: nothing lit to dim down (or nothing known): the group, as before.
			self.log.info("group hold %s %s: group, %s, %s", short(rid), fields.dim,
				#all == 0 and "no members known" or "no lit member", ms_text(duration))
			return self:pass(rid, fields)
		end
		set, note = all, " (every member, none lit yet)"  -- A1: an up from off
	end
	if #set > group_hold.PER_LIGHT_MAX then
		return self:start_stepped(rid, fields.dim, duration, #set, "", note)
	end
	if self:call("keep_group", rid) == true then
		return self:start_stepped(rid, fields.dim, duration, #set, " (scene running)", note)  -- G6a
	end
	return self:start_per_light(rid, fields, duration, set, note)
end

-- G4: the start to each light of the set through the light queue.
function group_hold:start_per_light(rid, fields, duration, lit, note)
	local started = {}
	for _, light_rid in ipairs(lit) do
		if self:call("light_set", light_rid, { dim = fields.dim, delta = 100, rate = duration }) == true then
			started[#started + 1] = light_rid
		end
	end
	if #started == 0 then
		self.log.warn("group hold %s %s: the light queue took none of %s; the group instead", short(rid), fields.dim,
			count_text(#lit))
		return self:pass(rid, fields)
	end
	if #started < #lit then
		self.log.warn("group hold %s %s: the light queue took %d of %s", short(rid), fields.dim, #started,
			count_text(#lit))
	end
	self:register(rid, { mode = "per-light", action = fields.dim, lights = started, count = #started })
	self.log.info("group hold %s %s: per-light, %s%s, %s", short(rid), fields.dim, count_text(#started), note,
		ms_text(duration))
	return true
end

-- G5: one step at once, the rest from the step timer. `why` and `note` go
-- into the log line: " (scene running)" (G6a) and the A1 note.
function group_hold:start_stepped(rid, action, duration, count, why, note)
	local step = 100
	if duration and duration > 0 then
		step = math.min(100, 100 * group_hold.STEP_MS / duration)
	end
	local hold = { mode = "stepped", action = action, count = count, step = step, sent = 0 }
	self.log.info("group hold %s %s: stepped%s, %s%s, %s %% a step", short(rid), action, why, count_text(count), note,
		percent(step))
	self:register(rid, hold)
	if not self:step(rid, hold) then
		self.holds[rid] = nil
		return false
	end
	return true
end

function group_hold:register(rid, hold)
	self.tokens = self.tokens + 1
	hold.token = self.tokens
	self.holds[rid] = hold
end

-- Send a stepped hold's next step (the last one only what is left of 100)
-- and arm the timer for the one after while the steps fall short of 100.
-- True when the step was queued.
function group_hold:step(rid, hold)
	local size = math.min(hold.step, 100 - hold.sent)
	if self:call("group_set", rid, { dim = hold.action, delta = round2(size) }) ~= true then
		self.log.warn("group hold %s %s: the group queue took no step; the hold stops here", short(rid), hold.action)
		return false
	end
	hold.sent = hold.sent + size
	if 100 - hold.sent >= REMAINDER_MIN then
		self:arm(rid, hold)
	end
	return true
end

function group_hold:arm(rid, hold)
	local token = hold.token
	hold.timer = self:call("set_timer", group_hold.STEP_MS, function()
		local current = self.holds[rid]
		if not current or current.token ~= token then
			return  -- the hold ended (its stop, a new start, stop_all) after this timer was armed
		end
		current.timer = nil
		local ok, err = pcall(self.step, self, rid, current)
		if not ok then
			self.log.error("group hold %s: a step failed: %s", short(rid), tostring(err))
		end
	end)
end

-- End a running hold, as its stop does: a per-light hold's stop to each
-- light that took its start, in the same order (G4); a stepped hold's timer
-- cancelled and nothing sent (G5). `why` is for the debug line (G9).
function group_hold:finish(rid, hold, why)
	self.holds[rid] = nil
	cancel(hold.timer)
	hold.timer = nil
	if hold.mode == "stepped" then
		self.log.debug("group hold %s %s: stepped, %s, %s %% of 100 sent", short(rid), why, count_text(hold.count),
			percent(hold.sent))
		return true
	end
	local queued = false
	for _, light_rid in ipairs(hold.lights) do
		if self:call("light_set", light_rid, { dim = "stop" }) == true then
			queued = true
		end
	end
	self.log.debug("group hold %s %s: per-light, %s", short(rid), why, count_text(#hold.lights))
	return queued
end

-- Teardown (G8): every step timer cancelled and every hold forgotten.
-- Nothing is sent: the queues are being dropped or replaced with this call,
-- so a stop queued now would go nowhere, or to a fresh queue that never
-- carried the start; a lamp still ramping finishes its ramp by itself.
function group_hold:stop_all()
	local holds = self.holds
	self.holds = {}
	for _, hold in pairs(holds) do
		cancel(hold.timer)
		hold.timer = nil
	end
end

return group_hold
