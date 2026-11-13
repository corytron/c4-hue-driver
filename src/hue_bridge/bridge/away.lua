-- The paired bridge away, and the event stream down (contract §1.3, owner's
-- answers D5 and D12; docs/simplify-research-discovery.md §2.5; #373 moved
-- it out of hue_bridge/driver.lua): how long the bridge has not answered at
-- its address or the stream has been down, the identity check after an
-- outage, the follow-up search for the bridge at a new address, the resync
-- a connect needs, and the bridge's own Attention items about all of it.
-- The measures live in the driver's state table, where the background
-- tasks' guards and the stream's own code read them too.
--
--   local a = away.new(ctx)
--   a:load()                   late init: the last good address and the last
--                              move the follow-up made, from the store
--   a:attention_items()        the bridge's own Attention items (below)
--   a:answered(ip)             the identity check passed at ip
--   a:other_bridge(reported)   another bridge (id `reported`) answers there
--   a:unreachable()            nothing answers at the address
--   a:want_find()              the follow-up search (housekeeping's
--                              find_bridge), at the last good address only
--   a:stream_status(text)      every status text of the stream that is not
--                              a per-event rewrite: an outage starts or ends
--   a:connect_tier()           at a connect: "full" or "quick" (below)
--   a:moved(from, to, text)    the follow-up changed the address to `to`
--   a:find_missed()            the follow-up ended without the paired bridge
--   a:reset()                  a Bridge IP Address change
--   a:forget()                 Forget Pairing: nothing away, down or moved
--   a:cancel_outage_check()    also OnDriverDestroyed
--
-- ctx:
--   state                 the driver's state table; the measures (nil while
--                         the condition does not hold): stream_down_ms,
--                         stream_down_reason, unreachable_ms, away_ms,
--                         away_other, find_missed_ms, moved, last_good_ip;
--                         read: ip, creds, identity_ok, stream,
--                         stream_connected (written by stream_status),
--                         net_check, address_gen, hk; written: identity_ok
--                         and identity_text (the outage check),
--                         outage_restart, resync_connects, offer_gen
--   paired()              true while the driver holds a key
--   keyed_refusal()       why nothing keyed may go out now, or nil
--   use_netstream()       true when the stream runs on a network connection
--   heard_elsewhere()     where Bridges Found heard the paired bridge, when
--                         not at Bridge IP Address (bridge/bridges_found.lua)
--   offer()               Bridges Found's one search for a typed address
--   refresh()             the owner-facing rows (Attention)
--   refresh_status()      the Status row
--   verify_identity(purpose, callback(ok))
--                         the identity check (bridge/identity.lua)
--   log
--   now_ms()              ms since the epoch; default C4:GetTime [verified:
--                         SDK 34_timer/_2-GetTime, OS 3.2.3 on], so the
--                         specs' fake clock (c4.advance) moves the measures
--   link                  optional: bridge/link.lua instance (#428,
--                         docs/offline-design.md §6.6), looked up at every
--                         call, since the driver creates it after this module
--                         and may set ctx.link afterwards; nil-safe
--
-- The link's inputs from here (#428 D2, D12): a drop of a running, connected
-- stream is trouble (a), "Connected since" is contact (e); the identity check
-- that finds nothing or another bridge is trouble (b), one that passes is
-- contact while keyed_refusal() is nil (g); every identity answer, pass or
-- failure, is the link's first look.
--
-- The Attention items (§4 finding 6; the texts of the discovery research
-- §2.5 where they fit): the paired bridge away an hour ("missing" once the
-- local search found it nowhere), the event stream down an hour while the
-- bridge answers, the paired bridge answering elsewhere than an address
-- typed by hand, and a move the driver followed (for a day). Each ends with
-- what resolves it and goes by itself when its condition ends; the driver's
-- rows timer (every 5 minutes) brings the hour-old ones.
--
-- DriverWorks calls: C4:SetTimer, C4:PersistGetValue, C4:PersistSetValue,
-- C4:PersistDeleteValue, C4:GetTime.

local num = require("common.num")

local away = {}
away.__index = away

away.ATTENTION_S = 3600
away.MOVED_S = 86400
away.MOVED_KEY = "hue_bridge_moved" -- { from, to, text, at }: the last move the follow-up made
-- The address the paired bridge last answered at: where the follow-up starts looking.
away.LAST_GOOD_IP_KEY = "hue_bridge_last_good_ip"
-- The follow-up is asked for once the bridge has not answered at the address
-- where it last did for FIND_AFTER_S, or another bridge answers there. Never
-- for an address typed by hand that never answered: there the owner's
-- Bridges Found list offers the fix.
away.FIND_AFTER_S = 300
-- The identity check after an outage: once the stream has been down CHECK_S.
away.CHECK_S = 60
-- A connect's resync is full at the first connect of the run, after an
-- error and after an outage of RESYNC_FULL_OUTAGE_S or more.
away.RESYNC_FULL_OUTAGE_S = 600

-- One call into the link (#428 §6.6), when there is one. A raise is logged,
-- never passed on: the identity check and the stream's status callback,
-- which call this module, must go on whatever the link does.
local function tell_link(self, method)
	local l = self.ctx.link
	if type(l) ~= "table" or type(l[method]) ~= "function" then
		return
	end
	local ok, err = pcall(l[method], l)
	if not ok and self.ctx.log then
		self.ctx.log.error("bridge link: %s failed: %s", method, tostring(err))
	end
end

function away.new(ctx)
	return setmetatable({
		ctx = ctx,
		now = ctx.now_ms or function() return C4:GetTime() end,
		outage_timer = nil,
	}, away)
end

function away:load()
	local state = self.ctx.state
	state.last_good_ip = C4:PersistGetValue(away.LAST_GOOD_IP_KEY)
	local moved = C4:PersistGetValue(away.MOVED_KEY)
	-- A stored time num.timestamp refuses is no move (#487): `at` is in ms.
	if type(moved) == "table" and type(moved.to) == "string" and type(moved.text) == "string"
			and num.finite(moved.at) and num.timestamp(moved.at / 1000) then
		state.moved = moved
	end
end

-- "14:02" today, "10-26 14:02" on another day.
function away:clock(ms)
	-- num.date (#487): a time os.date cannot take reads "?" instead of raising.
	local t = num.finite(ms) and math.floor(ms / 1000) or -1
	if num.date("%Y-%m-%d", t) == num.date("%Y-%m-%d", math.floor(self.now() / 1000)) then
		return num.date("%H:%M", t)
	end
	return num.date("%m-%d %H:%M", t)
end

-- The remedy of an event stream that stays down while the bridge answers: the other transport
-- (the manual's advice for a feed that does not connect), or the bridge's restart when the
-- network connection's TLS check already moved the feed to Web transfer (netgate.ATTENTION).
function away:stream_remedy()
	if self.ctx.use_netstream() then
		return "set Event Stream Transport to Web transfer if it stays"
	elseif self.ctx.state.net_check == "not_pinned" then
		return "restart the bridge if it stays"
	end
	return "set Event Stream Transport to Network connection if it stays"
end

function away:attention_items()
	local ctx = self.ctx
	local state = ctx.state
	local items = {}
	if not (ctx.paired() and state.ip) then
		return items
	end
	local now = self.now()
	-- The last six hex digits of the id, as the mDNS instance name and Bridges Found show it.
	local id = tostring(state.creds.bridge_id or ""):sub(-6):upper()
	local elsewhere = state.identity_ok ~= true and state.ip ~= state.last_good_ip and ctx.heard_elsewhere()
	if elsewhere then
		-- A typed address that never verified is the installer's: offered, never rewritten (principle 1).
		items[#items + 1] = string.format("Bridge %s answers at %s, not at the typed %s: pick it in Bridges Found", id,
			elsewhere, state.ip)
	elseif state.away_ms and now - state.away_ms >= away.ATTENTION_S * 1000 then
		if state.find_missed_ms and state.ip == state.last_good_ip then
			items[#items + 1] = string.format("Bridge %s missing since %s: not found on the network (searched %s); check "
				.. "its power, or type its address in Bridge IP Address", id, self:clock(state.away_ms),
				self:clock(state.find_missed_ms))
		elseif state.away_other then
			items[#items + 1] = string.format("Bridge %s not found at %s since %s: another bridge answers there; check "
				.. "its power, or type its address in Bridge IP Address", id, state.ip, self:clock(state.away_ms))
		else
			items[#items + 1] = string.format("Bridge %s not answering at %s since %s: check its power, or type its "
				.. "address in Bridge IP Address", id, state.ip, self:clock(state.away_ms))
		end
	end
	if state.stream_down_ms and not state.stream_connected and state.identity_ok == true and ctx.keyed_refusal() == nil
			and state.stream and state.stream:running() and now - state.stream_down_ms >= away.ATTENTION_S * 1000 then
		items[#items + 1] = string.format("Event stream down since %s while the bridge answers (lists read every 10 "
			.. "minutes): %s", self:clock(state.stream_down_ms), self:stream_remedy())
	end
	local moved = state.moved
	if moved and moved.to == state.ip and now - moved.at < away.MOVED_S * 1000 then
		items[#items + 1] = moved.text
	end
	return items
end

function away:answered(ip)
	local state = self.ctx.state
	local was_away = state.away_ms ~= nil
	state.unreachable_ms, state.away_ms, state.find_missed_ms, state.away_other = nil, nil, nil, nil
	-- The address the paired bridge last answered at: where the address
	-- follow-up starts looking (D5, discovery research §2.5).
	if state.last_good_ip ~= ip then
		state.last_good_ip = ip
		C4:PersistSetValue(away.LAST_GOOD_IP_KEY, ip)
	end
	-- #428 D2 (g): contact, unless nothing keyed may go out (a rejected key:
	-- its own re-check or Pair Bridge brings contact); the first look in any case (D12).
	if self.ctx.keyed_refusal() == nil then
		tell_link(self, "contact")
	end
	tell_link(self, "first_look")
	if was_away then
		self.ctx.refresh() -- Attention's "away" or "typed" item goes at once
	end
end

function away:other_bridge(reported)
	local ctx = self.ctx
	local state = ctx.state
	state.away_ms = state.away_ms or self.now()
	if state.away_other ~= reported then
		state.away_other = reported
		ctx.refresh() -- Attention's "away" item names the other bridge at once
	end
	-- #428 D2 (b): trouble, and the first look (D12).
	tell_link(self, "trouble")
	tell_link(self, "first_look")
	-- Another bridge where ours answered (a DHCP swap, research T3);
	-- at a typed address, where ours may answer instead (Bridges Found's offer).
	self:want_find()
	ctx.offer()
end

function away:unreachable()
	local ctx = self.ctx
	local state = ctx.state
	state.unreachable_ms = state.unreachable_ms or self.now()
	state.away_ms = state.away_ms or state.unreachable_ms
	if state.away_other then
		state.away_other = nil -- nothing answers now
		ctx.refresh()
	end
	-- #428 D2 (b): trouble, and the first look (D12).
	tell_link(self, "trouble")
	tell_link(self, "first_look")
	if self.now() - state.unreachable_ms >= away.FIND_AFTER_S * 1000 then
		self:want_find()
	end
	ctx.offer()
end

function away:want_find()
	local state = self.ctx.state
	if state.hk and self.ctx.paired() and state.ip ~= nil and state.ip == state.last_good_ip then
		state.hk:poke("find_bridge", "error")
	end
end

-- What the next connect's resync needs (contract §3.1): when the outage
-- began and the reason it began with.
function away:stream_status(text)
	local state = self.ctx.state
	local up = tostring(text):find("^Connected since") ~= nil
	local was_up = state.stream_connected
	state.stream_connected = up
	if up then
		self:cancel_outage_check()
		tell_link(self, "contact") -- #428 D2 (e)
	else
		state.stream_down_ms = state.stream_down_ms or self.now()
		if state.stream_down_reason == nil and tostring(text):find("^Disconnected") then
			state.stream_down_reason = tostring(text)
		end
		-- A drop, not a stop (Diagnostics, a rejected key, a rebuild). Also
		-- the link's trouble (#428 D2 a); a stop, or an attempt that fails
		-- before it ever connected, is not.
		if was_up and state.stream and state.stream:running() then
			self:arm_outage_check()
			tell_link(self, "trouble")
		end
		-- Only while the bridge itself does not answer: a stream that
		-- fails on its own is no reason to look elsewhere.
		if state.identity_ok ~= true and self.now() - state.stream_down_ms >= away.FIND_AFTER_S * 1000 then
			self:want_find()
		end
	end
end

-- The resync a connect needs (contract §3.1, #65): full at the first connect
-- of this run, after an error and after an outage of RESYNC_FULL_OUTAGE_S or
-- more; quick (no scene catalogue) after a silence (watchdog) reconnect.
function away:connect_tier()
	local state = self.ctx.state
	state.resync_connects = (state.resync_connects or 0) + 1
	local down_s = state.stream_down_ms and (self.now() - state.stream_down_ms) / 1000 or nil
	local reason = state.stream_down_reason or ""
	state.stream_down_ms, state.stream_down_reason = nil, nil
	if state.resync_connects > 1 and down_s ~= nil and down_s < away.RESYNC_FULL_OUTAGE_S
			and reason:find("watchdog") then
		return "quick"
	end
	return "full"
end

-- Attention keeps the move's text for a day (discovery research §2.5),
-- across a restart too.
function away:moved(from, to, text)
	local state = self.ctx.state
	state.moved = { from = from, to = to, text = text, at = self.now() }
	C4:PersistSetValue(away.MOVED_KEY, state.moved)
end

-- mDNS, then the sweep (or the sweep of the last hour) found it nowhere:
-- Attention says "missing" once it is away an hour.
function away:find_missed()
	self.ctx.state.find_missed_ms = self.now()
end

-- Everything measured at the old address goes; the new address gets its own
-- identity check.
function away:reset()
	local state = self.ctx.state
	state.unreachable_ms, state.away_ms, state.find_missed_ms, state.away_other = nil, nil, nil, nil
	self:cancel_outage_check()
	state.outage_restart = nil
end

-- Nothing is paired: no outage, nothing away or moved.
function away:forget()
	local state = self.ctx.state
	self:cancel_outage_check()
	state.outage_restart = nil
	state.unreachable_ms, state.away_ms, state.find_missed_ms, state.offer_gen = nil, nil, nil, nil
	state.away_other = nil
	state.moved = nil
	C4:PersistDeleteValue(away.MOVED_KEY)
end

-- The identity check after an outage (contract §1.3; maintenance research
-- §2.4 c; discovery research T2): once the event stream has been down
-- CHECK_S, the bridge at the address is asked for its id again, without
-- the key, before the key goes out again: until it answers with the paired
-- id, keyed requests are refused and the stream's next attempt waits (its
-- row reads "Not connected: bridge identity not verified yet"). Once per
-- outage, armed when a connected stream drops; the TLS self-check's verdict
-- of this start and address stands (pinning is the controller's).
function away:cancel_outage_check()
	if self.outage_timer then
		self.outage_timer:Cancel()
		self.outage_timer = nil
	end
end

function away:arm_outage_check()
	self:cancel_outage_check()
	self.outage_timer = C4:SetTimer(away.CHECK_S * 1000, function()
		self.outage_timer = nil
		self:outage_check()
	end)
end

-- The stream starts again once the check passes, unless the owner stopped
-- it meanwhile (Diagnostics), the address changed (its own checks restart
-- it) or the pairing was forgotten.
function away:outage_check()
	local ctx = self.ctx
	local state = ctx.state
	if state.stream_connected or not (state.stream and state.stream:running()) then
		return -- back already, or stopped on purpose (Diagnostics, a rejected key)
	end
	if state.identity_ok ~= true or ctx.keyed_refusal() ~= nil then
		return -- being checked already, or nothing keyed goes out anyway
	end
	ctx.log.info("event stream down for %d s: the bridge's identity is checked again before the key goes out",
		math.floor((self.now() - (state.stream_down_ms or self.now())) / 1000))
	state.identity_ok = nil
	state.identity_text = nil
	state.outage_restart = state.address_gen
	ctx.refresh_status()
	ctx.verify_identity("stream", function(ok)
		if ok and state.outage_restart == state.address_gen and state.stream and not state.stream_connected then
			state.outage_restart = nil
			state.stream:start()
		end
	end)
end

return away
