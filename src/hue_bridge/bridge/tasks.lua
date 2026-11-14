-- The bridge driver's background tasks (contract §1.3, §3.1 of
-- docs/simplify-actions-design.md; scheduler research §5; #373 moved them
-- out of hue_bridge/driver.lua): what runs, when and under which guards, on
-- the one engine of bridge/housekeeping.lua. Every run reports to the log
-- (Debug Mode shows each one, owner's answer D4).
--
--   local hk = tasks.new(ctx)   the engine with every task below defined;
--                               the driver keeps it in state.hk and starts it
--   tasks.after_user(user_active, fn)
--                               fn once no user command is waiting, or after
--                               housekeeping.GATE_MAX_MS whatever
--
--   resync            essential; every stream connect, Refresh All (a
--                     click), and again after a failure (60 s doubling to
--                     15 min); full or quick as state.resync_tier asks
--   safety_quick      optional; a quick read when none for 6 h
--   safety_full       optional; a full read when none for 24 h
--   stream_down_read  optional; a quick read every 10 minutes once the
--                     stream has been down 5 minutes while the bridge answers
--   key_recheck       essential; a rejected key checked again (D8): 5 min
--                     after the refusal, then 15 min, then an hour, then hourly
--   find_bridge       essential; the paired bridge at a new address (D5,
--                     D12; bridge/discovery.lua)
--
-- The resync chain's GETs go through the driver's bridge_request, not
-- through the engine's job.http: the engine schedules, retries and
-- coalesces the chain, and the user-first rule (after_user) is applied
-- once, before the chain starts. An optional task's chain charges each GET
-- to its job (job.charge, through state.charge), so the hourly budget of
-- optional requests counts it (§4 finding 7).
--
-- ctx:
--   state             the driver's state table; read: creds, identity_ok,
--                     key_rejected, stream_connected, stream_down_ms,
--                     pairing_active, lights, scenes, zone_lights, motion,
--                     discovery, address_gen, ip, last_good_ip, away
--                     (bridge/away.lua); written: resync_tier, charge
--   http(req, cb)     the driver's bridge_request (the engine's job.http)
--   log
--   user_active(quiet_ms)
--                     true while a command queue holds work or a person's
--                     write went out in the last quiet_ms
--   connection()      what the stream connects with, or nil: the "paired" guard
--   keyed_refusal()   why nothing keyed may go out now, or nil
--   resync_all(done(failures), tier)
--                     every module's resync, one GET at a time
--   recheck_key(done(ok, text, cleared))
--                     one keyed GET of the bridge resource
--   last_action(text) Last Action
--   set_address(ip)   Bridge IP Address set, its handler run
--   now_ms()          default C4:GetTime

local housekeeping = require("bridge.housekeeping")

local tasks = {}

-- The guards of the safety reads.
tasks.SAFETY_GUARDS = { "paired", "identity_ok", "key_ok", "not_pairing", "stream_up", "modules_idle" }
-- The most GETs one background read may make: the full chain is 20 on a
-- Bridge Pro and 18 on a v2 (one more each when it reads the automation
-- scripts), the quick one 16 and 14 (2.0 added the entertainment areas,
-- #514); the rest is room for a module that reads one type more. A run starts only when its whole budget
-- fits in the hour.
tasks.READ_BUDGET = 25

-- fn once no user command is waiting, or after GATE_MAX_MS whatever, so a
-- long slider session cannot starve the resync after a reconnect.
function tasks.after_user(user_active, fn)
	local waited = 0
	local function look()
		if waited >= housekeeping.GATE_MAX_MS or not user_active() then
			return fn()
		end
		waited = waited + housekeeping.GATE_POLL_MS
		C4:SetTimer(housekeeping.GATE_POLL_MS, look)
	end
	look()
end

-- True while a module resyncs or holds a busy flag.
local function modules_busy(state)
	for _, m in ipairs({ state.lights, state.scenes, state.zone_lights, state.motion }) do
		if m and (m.resyncing or (m.BUSY_FLAGS and m[m.BUSY_FLAGS[1]])) then
			return true
		end
	end
	return false
end

function tasks.new(ctx)
	local state, log = ctx.state, ctx.log
	local now_ms = ctx.now_ms or function() return C4:GetTime() end
	local hk = housekeeping.new({
		http = ctx.http,
		log = log,
		user_active = ctx.user_active,
		bridge_id = function() return state.creds and state.creds.bridge_id or nil end,
		state = function()
			return {
				paired = ctx.connection() ~= nil,
				identity_ok = state.identity_ok == true,
				key_ok = state.key_rejected == nil and ctx.keyed_refusal() == nil,
				stream_up = state.stream_connected == true,
				not_pairing = not state.pairing_active,
				modules_idle = not modules_busy(state),
			}
		end,
		on_status = function(report)
			local line = string.format("background %s (%s): %s in %d ms%s", tostring(report.task),
				tostring(report.trigger), report.ok and "OK" or "failed", tonumber(report.ms) or 0,
				report.text and (": " .. tostring(report.text)) or "")
			if report.ok then
				log.debug("%s", line)
			else
				log.info("%s", line)
			end
		end,
	})
	-- The resync after every connect (as beta 8 did), now retried after a
	-- failure (60 s doubling to 15 min); also Refresh All (a click). A full
	-- one counts as both safety reads, a quick one as the quick one. The
	-- optional tasks pass their `job`: every GET of the chain is charged to
	-- it (bridge_request, job.charge), so the reads count against the hourly
	-- budget of optional requests (§4 finding 7); the essential resync passes
	-- none and stays outside it, as before.
	local function run_resync(tier, done, job)
		tasks.after_user(ctx.user_active, function()
			local charge = job and job.charge or nil
			state.charge = charge
			ctx.resync_all(function(failures)
				if charge and state.charge == charge then
					state.charge = nil
				end
				if #failures > 0 then
					state.resync_tier = state.resync_tier == "full" and "full" or tier
					return done(false, table.concat(failures, "; "))
				end
				hk:mark_fresh("safety_quick")
				if tier == "full" then
					hk:mark_fresh("safety_full")
				end
				done(true, tier .. " resync")
			end, tier)
		end)
	end
	hk:define({
		name = "resync", class = "essential", triggers = { "connect", "click", "error" },
		debounce_s = 2, backoff_max_s = 900,
		run = function(_job, done)
			local tier = state.resync_tier or "full"
			state.resync_tier = nil
			run_resync(tier, done)
		end,
	})
	-- The net under the stream: a quick read when none for 6 h, a full one
	-- when none for 24 h.
	hk:define({
		name = "safety_quick", class = "optional", triggers = { "timer" }, interval_s = 6 * 3600,
		persist = true, guards = tasks.SAFETY_GUARDS, budget = tasks.READ_BUDGET,
		run = function(job, done) run_resync("quick", done, job) end,
	})
	hk:define({
		name = "safety_full", class = "optional", triggers = { "timer" }, interval_s = 24 * 3600,
		persist = true, guards = tasks.SAFETY_GUARDS, budget = tasks.READ_BUDGET,
		run = function(job, done) run_resync("full", done, job) end,
	})
	-- The lists stay current while the stream is down but the bridge answers:
	-- a quick read every 10 minutes once the stream has been down 5 minutes
	-- (six an hour fit the hourly budget, housekeeping.HOUR_BUDGET).
	hk:define({
		name = "stream_down_read", class = "optional", triggers = { "timer" }, interval_s = 600,
		guards = { "paired", "identity_ok", "key_ok", "not_pairing", "modules_idle" }, budget = tasks.READ_BUDGET,
		run = function(job, done)
			if state.stream_connected or state.stream_down_ms == nil then
				return done(true, "the event stream is connected")
			elseif now_ms() - state.stream_down_ms < 300000 then
				return done(true, "the event stream is down for less than 5 minutes")
			end
			run_resync("quick", done, job)
		end,
	})
	-- A rejected key is checked again by itself (D8): 5 min after the
	-- refusal, then 15 min, then an hour, then hourly.
	hk:define({
		name = "key_recheck", class = "essential", triggers = { "error" },
		debounce_s = 300, backoff_s = { 900, 3600 }, guards = { "paired", "identity_ok", "not_pairing" },
		run = function(_job, done)
			ctx.recheck_key(function(ok, text, cleared)
				if cleared then
					ctx.last_action("The bridge accepts the application key again: event stream restarting")
				end
				done(ok, text)
			end)
		end,
	})
	-- The paired bridge at a new address (D5, D12): mDNS first, a sweep of
	-- at most two /24 networks at most hourly (bridge/discovery.lua); only
	-- the paired id's address is ever taken, and Last Action says what moved.
	hk:define({
		name = "find_bridge", class = "essential", triggers = { "error" },
		debounce_s = 5, min_gap_s = 300, timeout_s = 360, guards = { "paired", "not_pairing" },
		run = function(_job, done)
			local creds, gen, old = state.creds, state.address_gen, state.ip
			if not (state.discovery and creds and creds.bridge_id) then
				return done(true, "nothing to look for")
			end
			if state.identity_ok == true then
				-- Never while the bridge answers at its address (discovery research §2.5).
				return done(true, "the bridge answers at its address")
			end
			state.discovery:find_paired(creds.bridge_id, state.last_good_ip or old, function(ip, how, detail)
				local text = detail and detail.text or tostring(how)
				if gen ~= state.address_gen then
					return done(true, "the address changed meanwhile")
				end
				if ip and ip ~= old then
					local moved = string.format("The bridge moved from %s to %s (%s): Bridge IP Address updated; "
						.. "reserve its address in the router", tostring(old), ip, text)
					-- Attention keeps the same text for a day (discovery research
					-- §2.5, bridge/away.lua), across a restart too.
					state.away:moved(old, ip, moved)
					ctx.set_address(ip)
					ctx.last_action(moved)
				elseif not ip and (how == "not_found" or how == "limited") then
					-- mDNS, then the sweep (or the sweep of the last hour) found it
					-- nowhere: Attention says "missing" once it is away an hour.
					state.away:find_missed()
				end
				done(ip ~= nil, text)
			end)
		end,
	})
	return hk
end

return tasks
