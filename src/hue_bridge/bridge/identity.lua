-- The bridge's identity, checked without the key before any request carries
-- it (docs/reviews/security-2026-10-24.md; #373 moved it out of
-- hue_bridge/driver.lua): GET /api/0/config is public and answers the
-- bridge id. Until it matches the paired id nothing keyed is sent; an
-- unreachable bridge is asked again every 30 s, a different bridge never
-- (it does not become ours by waiting). The TLS self-check
-- (bridge/tlscheck.lua) runs inside it, before the first keyed request of a
-- start and address.
--
--   local id = identity.new(ctx)
--   id:verify(purpose, callback(ok))
--                     runs the check, or joins the one in flight; a retry
--                     passes neither argument (below)
--   id:recheck(callback(same))
--                     a 401 or 403: the check again, before the driver
--                     locks the key (below)
--   id:reset()        an address change or Forget Pairing: the waiters, the
--                     retry and a pending re-check go
--   id:cancel_retry() OnDriverDestroyed
--   identity.TLS_ATTENTION   the Attention text of a failed TLS self-check
--
-- Who waits for the check, by purpose ("key", "stream", "test"): one check
-- answers them all, so Test Connection never drops the stream's pending
-- start and two stream starts never queue twice (the later callback of a
-- purpose replaces the earlier). Kept across the 30 s retries; dropped at
-- an address change or Forget Pairing. "key" is answered first, so a key
-- lock is in place before a stream waiter starts anything.
--
-- Only an answer that reports the paired bridge id reaches the rows (Bridge
-- Model, Name, Firmware): another bridge at the address used to rewrite
-- them before its id was compared (security review 2026-11-13, N-4, #490).
-- Peer text in Status is cut (http.peer_text). `running` is the address generation whose check
-- is in flight (its GET or its TLS check). During a 30 s wait it is nil, so
-- a new waiter (a Test Connection click) starts the check at once instead of
-- waiting for the timer.
--
-- ctx:
--   state               the driver's state table; read: ip, address_gen,
--                       creds, destroyed; written: identity_ok,
--                       identity_text, tls_verdict, attention_sent
--   paired()            true while the driver holds a key
--   prop(name, value)   a Composer row
--   show_bridge_info(info)
--                       the model, name and firmware rows from the answer
--   refresh_status()    the Status row
--   show_stream_waiting()
--                       the Event Stream row while the stream waits
--   show_attention(text)
--                       Attention, written now
--   away                bridge/away.lua instance: answered(ip),
--                       other_bridge(reported), unreachable()
--   log
--
-- DriverWorks calls: C4:SetTimer; the GET is bridge/http.lua's.

local config = require("bridge.config")
local http = require("bridge.http")
local tlscheck = require("bridge.tlscheck")

local identity = {}
identity.__index = identity

identity.RETRY_MS = 30000
identity.PURPOSES = { "key", "stream", "test" }

-- The Attention text of a failed TLS self-check (issue #53).
identity.TLS_ATTENTION = "TLS check failed: the controller accepted the bridge without its Signify roots; "
	.. "keyed requests stopped (see the manual)"

function identity.new(ctx)
	return setmetatable({
		ctx = ctx,
		timer = nil,     -- the 30 s retry
		recheck_timer = nil, -- recheck's 1 ms hop out of a transfer's callback
		waiters = {},    -- purpose -> callback(ok)
		running = nil,   -- the address generation whose check is in flight
	}, identity)
end

function identity:cancel_retry()
	if self.timer then
		self.timer:Cancel()
		self.timer = nil
	end
end

function identity:answer(ok)
	self.running = nil
	local waiters = self.waiters
	self.waiters = {}
	for _, purpose in ipairs(identity.PURPOSES) do
		if waiters[purpose] then
			waiters[purpose](ok)
		end
	end
end

function identity:reset()
	self:cancel_retry()
	if self.recheck_timer then
		self.recheck_timer:Cancel()
		self.recheck_timer = nil
	end
	self.waiters = {}
	self.running = nil
end

-- A Status text of the identity check or of the TLS check it waits for: shown
-- now and kept while the check has not passed, so that the driver's
-- refresh_status (a Bridge IP Address set again, say) shows it instead of
-- "Paired" (#236).
function identity:status(text)
	self.ctx.state.identity_text = text
	self.ctx.prop("Status", text)
end

-- The TLS self-check (issue #53, bridge/tlscheck.lua): before the key goes
-- anywhere, a request with a decoy CA bundle must fail certificate
-- verification. If the controller accepts it, its OS is not using the
-- configured bundle and nothing keyed is sent. Once per start and address.
-- `done(trusted, again)`: `again` asks the identity check to run again in
-- 30 s, keeping its waiters.
-- - not_pinned sticks until the next start or address change: a later
--   inconclusive answer must not lift it (security review 2026-10-25
--   finding 2).
-- - inconclusive passes only on a Director version that has answered pinned
--   before: pinning is a property of the OS, and an active attacker can
--   always make the decoy request fail some other way (finding 3).
function identity:tls_gate(gen, ip, done)
	local ctx = self.ctx
	local state = ctx.state
	if state.tls_verdict == "pinned" then
		return done(true)
	end
	if state.tls_verdict == "not_pinned" then
		return done(false)
	end
	tlscheck.run(ip, function(verdict, detail)
		if gen ~= state.address_gen or state.destroyed then
			return -- the address changed meanwhile (its own check runs), or this code was unloaded
		end
		if verdict == "not_pinned" then
			state.tls_verdict = verdict
			ctx.log.warn("TLS check: the bridge at %s was accepted with a decoy CA bundle (%s); nothing keyed is sent",
				ip, tostring(detail))
			ctx.refresh_status()
			ctx.show_stream_waiting() -- "Not connected: TLS check failed", as Connect Event Stream would say
			ctx.show_attention(identity.TLS_ATTENTION)
			state.attention_sent = identity.TLS_ATTENTION
			return done(false)
		end
		if verdict == "pinned" then
			state.tls_verdict = verdict
			tlscheck.remember_pinned()
			ctx.log.debug("TLS check: the decoy bundle was refused (%s); trust is pinned", tostring(detail))
			return done(true)
		end
		if tlscheck.pinned_before() then
			ctx.log.warn("TLS check inconclusive (%s); this Director version answered pinned before, so it passes",
				tostring(detail))
			return done(true)
		end
		self:status(string.format("TLS check inconclusive (%s): nothing is sent; checking again in %d s",
			tostring(detail), identity.RETRY_MS / 1000))
		ctx.log.warn("TLS check inconclusive (%s) on a Director version that has not answered pinned: nothing keyed "
			.. "is sent; again in %d s", tostring(detail), identity.RETRY_MS / 1000)
		done(false, true)
	end)
end

function identity:verify(purpose, callback)
	local ctx = self.ctx
	local state = ctx.state
	if purpose then
		self.waiters[purpose] = callback
	end
	local ip, gen = state.ip, state.address_gen
	if self.running == gen then
		return -- the check in flight answers this waiter too
	end
	self:cancel_retry()
	self.running = gen
	local function again()
		self.running = nil
		self.timer = C4:SetTimer(identity.RETRY_MS, function()
			self.timer = nil
			self:verify()
		end)
	end
	http.request({ ip = ip, path = "/api/0/config", timeout = 10 }, function(r)
		if ip ~= state.ip or gen ~= state.address_gen then
			return -- the address changed meanwhile; its own check runs
		end
		if state.destroyed then
			return -- OnDriverDestroyed ran (a dev loop reload keeps the Lua state): the new code checks
		end
		if not ctx.paired() then
			return -- Forget Pairing overtook the check (#236: the step before pairing another bridge)
		end
		local cfg = r.ok and type(r.json) == "table" and r.json or nil
		local reported = cfg and config.normalise_bridge_id(cfg.bridgeid) or nil
		if reported and reported == state.creds.bridge_id then
			-- The paired bridge: its rows, then its model (N-4, #490: not before
			-- the id matched).
			ctx.show_bridge_info({ model = cfg.modelid, name = cfg.name, sw_version = cfg.swversion,
				api_version = cfg.apiversion })
			-- A model id this driver cannot use (none at all is let through).
			if cfg.modelid and not config.model_supported(cfg.modelid) then
				state.identity_ok = false
				local label = http.peer_text(config.model_label(cfg.modelid), 64)
				self:status(string.format("Bridge at %s is a %s: no CLIP v2 API; nothing is sent", ip, label))
				ctx.log.warn("bridge at %s is %s: no request is sent", ip, label)
				return self:answer(false)
			end
			return self:tls_gate(gen, ip, function(trusted, retry)
				if gen ~= state.address_gen then
					return
				end
				state.identity_ok = trusted
				if retry then
					return again() -- Status already says why
				end
				if trusted then
					state.identity_text = nil
					ctx.away:answered(ip)
				end
				ctx.refresh_status()
				self:answer(trusted)
			end)
		end
		state.identity_ok = false
		if reported then
			self:status(string.format("Bridge at %s reports ID %s, expected %s; nothing is sent until the address "
				.. "is corrected", ip, reported, state.creds.bridge_id))
			ctx.log.warn("bridge at %s reports id %s, expected %s: no request is sent", ip, reported,
				state.creds.bridge_id)
			ctx.away:other_bridge(reported)
			return self:answer(false)
		end
		self:status(string.format("Bridge at %s not reachable (%s); checking again in %d s", ip,
			http.peer_text(r.ok and "no bridge id in the answer" or r.err, 128), identity.RETRY_MS / 1000))
		ctx.log.warn("bridge identity check via %s failed: %s; again in %d s", ip,
			http.peer_text(r.err, http.TEXT_LOG), identity.RETRY_MS / 1000)
		ctx.away:unreachable()
		again()
	end)
end

-- A 401 or 403 (security review 2026-11-13, N-6, #490): before the driver
-- locks the key, the bridge at the address is asked for its id again,
-- unkeyed. Another bridge there (one DHCP gave the address to, say) refuses
-- a key it never issued; locking would show "key rejected" for a fault that
-- is not the key's, and the background key re-check would send that bridge
-- the key every hour. Meanwhile nothing keyed goes out (identity_ok is
-- cleared until the check answers). The check starts from a 1 ms timer: a
-- 401 or 403 arrives inside a C4:url or network callback, where no transfer
-- may start (bridge/stream.lua, rule 1); a check already in flight for
-- this address answers it as well. callback(same) is the "key" waiter:
-- true once the paired bridge answered and the TLS gate passed; false for
-- another bridge (Status says which, and away:other_bridge looks for the
-- paired one) or a model without CLIP v2; an unreachable bridge is asked
-- again every 30 s, the waiter kept. An address change or Forget Pairing
-- (reset) drops it.
function identity:recheck(callback)
	local state = self.ctx.state
	local gen = state.address_gen
	state.identity_ok = nil
	self.waiters.key = callback
	if self.recheck_timer then
		return -- the check starts in a moment
	end
	self.recheck_timer = C4:SetTimer(1, function()
		self.recheck_timer = nil
		if gen ~= state.address_gen or state.destroyed or not self.waiters.key then
			return -- the address changed, the code was unloaded, or a check in flight answered it
		end
		self:verify()
	end)
end

return identity
