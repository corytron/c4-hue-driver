-- The gate in front of the network-connection event stream (#317; #373
-- moved it out of hue_bridge/driver.lua): before the stream's first keyed
-- connect on a network connection in a run, the TLS check of
-- bridge/netcheck.lua (unkeyed probes on fresh binding ids, a decoy CA file,
-- then the Signify roots) must show the decoy refused; on a Director version
-- that answered pinned before, netcheck answers pinned without a probe. Its
-- answer holds for the run (state.net_check), whatever the address: it is
-- the controller's.
--
--   local gate = netgate.new(ctx)
--   gate:run(continue)   the check, or joins the one in flight; continue()
--                        once it passed or fell back, or after the backoff
--                        (the driver re-enters choose_stream_address)
--   gate:reset()         an address change, a transport change, Forget
--                        Pairing or OnDriverDestroyed: the waiter, the probe
--                        in flight (its binding closed, cleared and removed,
--                        #329) and the backoff go; the run's verdict stays
--   netgate.ATTENTION    the Attention text of a decoy accepted
--
-- pinned, or inconclusive on a Director version that answered pinned before
-- ("accepted"), lets the stream connect; not_pinned moves it to Web transfer
-- with an Attention item until the next start (the Event Stream Transport
-- property stays as the owner set it, so the check runs again after a
-- Director upgrade); any other inconclusive answer holds it and asks again
-- after netcheck's backoff. One waiter, the latest; one check at a time, the
-- latest address's.
--
-- ctx:
--   state               the driver's state table; read: address_gen, ip;
--                       written: net_check ("pinned", "accepted", "not_pinned")
--   prop(name, value)   a Composer row (the Event Stream row)
--   refresh()           the owner-facing rows (Attention)
--   log
--
-- DriverWorks calls: C4:SetTimer; the probes are bridge/netcheck.lua's.

local netcheck = require("bridge.netcheck")

local netgate = {}
netgate.__index = netgate

netgate.ATTENTION = "Event stream: the network connection did not verify the bridge's certificate on this "
	.. "controller; using Web transfer (#317)"

function netgate.new(ctx)
	return setmetatable({
		ctx = ctx,
		waiter = nil,    -- the latest continue
		running = nil,   -- the address generation whose probe is in flight
		timer = nil,     -- the backoff after an inconclusive answer
		attempts = 0,    -- inconclusive answers in a row
	}, netgate)
end

function netgate:reset()
	if self.timer then
		self.timer:Cancel()
	end
	self.waiter, self.running, self.timer, self.attempts = nil, nil, nil, 0
	netcheck.cancel()
end

function netgate:run(continue)
	local ctx = self.ctx
	local state = ctx.state
	self.waiter = continue
	local gen, ip = state.address_gen, state.ip
	if self.running == gen then
		return -- the probe in flight answers this waiter too
	end
	if self.timer then
		self.timer:Cancel()
		self.timer = nil
	end
	self.running = gen
	ctx.prop("Event Stream", "Not connected: network connection TLS check running") -- about 12 s
	netcheck.run(ip, function(verdict, detail)
		if gen ~= state.address_gen then
			return -- the address changed meanwhile; its own check runs
		end
		self.running = nil
		detail = tostring(detail)
		local function wake()
			local waiter = self.waiter
			self.waiter = nil
			if waiter then
				waiter()
			end
		end
		if verdict == "pinned" then
			state.net_check = verdict
			netcheck.remember_pinned()
			ctx.log.debug("network connection TLS check: the decoy CA file was refused (%s)", detail)
		elseif verdict == "not_pinned" then
			state.net_check = verdict
			ctx.log.warn("network connection TLS check: the bridge at %s was accepted with a decoy CA file (%s); the "
				.. "event stream uses Web transfer until the driver restarts", ip, detail)
			ctx.refresh() -- the Attention item
		elseif netcheck.pinned_before() then
			state.net_check = "accepted"
			ctx.log.warn("network connection TLS check inconclusive (%s); this Director version answered pinned "
				.. "before, so it passes", detail)
		else
			self.attempts = self.attempts + 1
			local delay = netcheck.retry_delay(self.attempts)
			ctx.prop("Event Stream", string.format("Not connected: network connection TLS check inconclusive (%s); "
				.. "checking again in %d s", detail, delay))
			ctx.log.warn("network connection TLS check inconclusive (%s) on a Director version that has not answered "
				.. "pinned: nothing keyed is sent on it; again in %d s", detail, delay)
			self.timer = C4:SetTimer(delay * 1000, function()
				self.timer = nil
				wake()
			end)
			return
		end
		self.attempts = 0
		wake()
	end)
end

return netgate
