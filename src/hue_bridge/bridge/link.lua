-- The bridge's link to the Hue Bridge (#428, docs/offline-design.md §3; D1-D4,
-- D7, D11-D13): up, in trouble since a time, or offline once the trouble has
-- lasted OFFLINE_AFTER_S without a break. Offline is what every Hue device
-- (lights, zone and room lights, scenes, motion sensors) is told with
-- HUE_BRIDGE_LINK (§6.1), and what the bridge's Attention says while it lasts
-- (§6.4). The first proof of contact ends it at once (D7).
--
--            trouble (D2 a-d)               OFFLINE_AFTER_S without contact
--   up ───────────────────────────▶ trouble ───────────────────────────▶ offline
--    ▲                                 │                                    │
--    └─────────── contact (D2 e-g) ────┴──────────── contact ───────────────┘
--
--   local l = link.new(ctx)
--   l:load()             late init, after away:load(): the stored outage
--                        (KEY), and the FIRST_LOOK_S fallback of the first
--                        evaluation (D12)
--   l:trouble()          D2 a-d: trouble begins, unless it already runs; while
--                        offline, a changed reason is told again (D3)
--   l:contact()          D2 e-g: trouble and offline end; the stored outage goes
--   l:evaluate()         refresh_status(): trouble while the bridge cannot be
--                        used (D2 d); never contact
--   l:first_look()       the first identity answer (bridge/away.lua): the first
--                        evaluation of the run, unless it ran (D12)
--   l:status()           "up", "trouble" or "offline"
--   l:offline()          true while offline
--   l:reason()           why, derived now (D3)
--   l:params()           the HUE_BRIDGE_LINK params (§6.1)
--   l:tell(device_id)    HUE_BRIDGE_LINK to one device (a hello's answer, D4);
--                        nothing before the first evaluation
--   l:attention_items()  the bridge's Attention item while offline (§6.4)
--   l:retime()           dev builds: OFFLINE_AFTER_S changed (bridge/devtools.lua,
--                        D15); a running count is re-armed against it
--   l:cancel()           OnDriverDestroyed
--
-- What starts and ends trouble (D2), as the callers wire it:
--   trouble  (a) a drop of a running, connected event stream (away:stream_status);
--            (b) the identity check finds nothing, or another bridge
--                (away:unreachable, away:other_bridge);
--            (c) a keyed request whose transfer failed without an HTTP status,
--                except the local invalid request path (driver.lua);
--            (d) not paired, key rejected, TLS not_pinned or identity_ok ==
--                false, at every refresh_status() (evaluate)
--   contact  (e) the stream connects ("Connected since", away:stream_status);
--            (f) a keyed request answered 2xx (driver.lua);
--            (g) the identity check passes while keyed_refusal() is nil
--                (away:answered)
--   neither  429 and 5xx, other 4xx (401/403 reach (d) through the key
--            confirmation), bridge_request's own refusals, a deliberate stream
--            stop, a stream attempt that fails before it ever connected.
--
-- The first evaluation of a run (D12, E14-E18): until it has run, nothing is
-- told and the count is not armed. It runs at the first identity answer (pass
-- or failure), at the first contact, or FIRST_LOOK_S after load(), whichever
-- comes first, and then always tells every device the state: offline when the
-- trouble that holds began OFFLINE_AFTER_S ago or more (a stored outage that
-- outlived a restart), online otherwise. A stored outage keeps its start
-- until contact: the trouble of this run counts from it, so a restart does not
-- grant 5 more minutes, and a bridge that came back meanwhile is never shown
-- offline (its first contact deletes the store).
--
-- ctx:
--   state            the driver's state table; read: identity_ok, key_rejected,
--                    tls_verdict, away_other, unreachable_ms, destroyed
--   paired()         true while the driver holds a key
--   keyed_refusal()  why nothing keyed may go out now, or nil
--   now_ms()         ms since the epoch; default C4:GetTime [verified: API
--                    34_timer/_2-GetTime]
--   device_ids()     { [device_id] = true }: every Hue device of the four
--                    modules (lights, zone lights, scenes, motion)
--   send(device_id, command, params)
--                    one message to a device (the driver's device_send)
--   refresh()        the owner-facing rows (Attention)
--   log
--   clock(ms)        "14:02" today, "10-26 14:02" another day (away:clock)
--
-- DriverWorks calls: C4:SetTimer [verified: API 34_timer/_1-SetTimer, delay >
-- 0, :Cancel()], C4:PersistGetValue, C4:PersistSetValue, C4:PersistDeleteValue
-- [verified: API 26.5_persistence, tables of strings and numbers], as
-- bridge/away.lua uses them.

local num = require("common.num")

local link = {}
link.__index = link

-- Continuous trouble before the devices go offline (D1: the owner's 5
-- minutes, away.FIND_AFTER_S). A module field: the dev loop's
-- Link_Offline_After changes it for the run (D15); release builds have no way to.
link.OFFLINE_AFTER_S = 300
-- The first evaluation's fallback when no identity answer or contact came (D12).
link.FIRST_LOOK_S = 60
-- The outage that went offline: { since = <ms>, reason = <text> }; written at
-- the change to offline only, deleted at contact (D12).
link.KEY = "hue_bridge_link"
-- The bridge → device message (§6.1).
link.COMMAND = "HUE_BRIDGE_LINK"

-- §6.4: what the bridge does, by reason, and what brings the devices back
-- when it is not just the bridge answering again.
local PHRASE = {
	not_answering = "has not answered",
	other_bridge = "is not at its address",
	key_rejected = "refuses the pairing",
	blocked = "cannot be used",
	not_paired = "is not paired",
}
local TAIL = {
	key_rejected = "they come back once it accepts it (re-pair with Pair Bridge if it stays)",
	blocked = "see Status",
	not_paired = "run Pair Bridge",
}
local BACK_BY_THEMSELVES = "they come back by themselves when it answers"

function link.new(ctx)
	return setmetatable({
		ctx = ctx,
		now = ctx.now_ms or function() return C4:GetTime() end,
		since = nil,        -- ms: when the trouble that holds began; nil while up
		is_offline = false,
		told_reason = nil,  -- the reason the devices were told "offline" with
		stored = nil,       -- { since, reason }: the outage in the store (KEY), loaded or written
		first_done = false, -- the first evaluation of this run ran (D12)
		timer = nil,        -- the count to offline
		look_timer = nil,   -- the FIRST_LOOK_S fallback
	}, link)
end

-- "14:02" today, "10-26 14:02" another day: ctx.clock (away:clock), or the same rule here.
function link:clock(ms)
	if self.ctx.clock then
		return self.ctx.clock(ms)
	end
	-- num.date (#487): a time os.date cannot take reads "?" instead of raising.
	local t = num.finite(ms) and math.floor(ms / 1000) or -1
	if num.date("%Y-%m-%d", t) == num.date("%Y-%m-%d", math.floor(self.now() / 1000)) then
		return num.date("%H:%M", t)
	end
	return num.date("%m-%d %H:%M", t)
end

local function duration(ms)
	local s = math.max(0, math.floor(ms / 1000))
	if s < 120 then
		return s .. " s"
	elseif s < 7200 then
		return math.floor(s / 60) .. " min"
	end
	return string.format("%d h %d min", math.floor(s / 3600), math.floor((s % 3600) / 60))
end

-- A one-shot timer whose callback is pcall-wrapped and starts nothing once
-- OnDriverDestroyed ran (a dev loop reload keeps the old Lua state, and its
-- timers, alive).
function link:set_timer(ms, fn)
	local ctx = self.ctx
	return C4:SetTimer(math.max(1, math.ceil(ms)), function()
		if ctx.state and ctx.state.destroyed then
			return
		end
		local ok, err = pcall(fn)
		if not ok then
			ctx.log.error("bridge link: timer failed: %s", tostring(err))
		end
	end)
end

function link:cancel_count()
	if self.timer then
		self.timer:Cancel()
		self.timer = nil
	end
end

function link:cancel_look()
	if self.look_timer then
		self.look_timer:Cancel()
		self.look_timer = nil
	end
end

function link:cancel()
	self:cancel_count()
	self:cancel_look()
end

-- The stored outage, kept when well formed (a since in ms no later than now,
-- a reason), deleted otherwise (L83); then the first evaluation's fallback.
function link:load()
	local ctx = self.ctx
	local value = C4:PersistGetValue(link.KEY)
	if value ~= nil then
		-- A stored time num.timestamp refuses is malformed (#487): `since` is in ms.
		local since = type(value) == "table" and num.finite(value.since) or nil
		if since and since > 0 and since <= self.now() and num.timestamp(since / 1000)
				and type(value.reason) == "string" then
			self.stored = { since = since, reason = value.reason }
			-- Trouble seen before load() counts from the stored start too.
			if self.since and not self.is_offline and since < self.since then
				self.since = since
			end
			ctx.log.info("bridge link: an outage since %s was stored (%s)", self:clock(since), value.reason)
		else
			C4:PersistDeleteValue(link.KEY)
			ctx.log.info("bridge link: a malformed stored outage was deleted")
		end
	end
	if not self.first_done then
		self:cancel_look()
		self.look_timer = self:set_timer(link.FIRST_LOOK_S * 1000, function()
			self.look_timer = nil
			self:first_look()
		end)
	end
end

-- D3: the reason, derived from the driver's state whenever the link reports,
-- in the contract's order. A missing address while paired reads as blocked:
-- the bridge's Status says what to do ("Enter the bridge IP address"). An
-- identity check that failed with neither nothing answering nor another
-- bridge answering is an unsupported model or a TLS check that stays
-- inconclusive: blocked too.
function link:reason()
	local ctx = self.ctx
	local state = ctx.state
	if not ctx.paired() then
		return "not_paired"
	end
	local refusal = ctx.keyed_refusal()
	if state.key_rejected or refusal == "key rejected" then
		return "key_rejected"
	end
	if refusal ~= nil or state.tls_verdict == "not_pinned" then
		return "blocked"
	end
	if state.away_other then
		return "other_bridge"
	end
	if state.identity_ok == false and state.unreachable_ms == nil then
		return "blocked"
	end
	return "not_answering"
end

function link:status()
	if self.is_offline then
		return "offline"
	elseif self.since ~= nil then
		return "trouble"
	end
	return "up"
end

function link:offline()
	return self.is_offline
end

-- §6.1: state, and with "offline" the reason and since (epoch seconds as a
-- decimal string). A fresh table per call: a receiver may keep or change it.
function link:params()
	if self.is_offline then
		return { state = "offline", reason = self.told_reason or self:reason(),
			since = tostring(math.floor(self.since / 1000)) }
	end
	return { state = "online" }
end

function link:send_to(device_id, params)
	local ok, err = pcall(self.ctx.send, device_id, link.COMMAND, params)
	if not ok then
		self.ctx.log.warn("bridge link: %s to device %s failed: %s", link.COMMAND, tostring(device_id), tostring(err))
	end
end

-- Every device of the four modules, in id order (D4). Returns how many.
function link:broadcast()
	local ok, set = pcall(self.ctx.device_ids)
	if not ok then
		self.ctx.log.warn("bridge link: the devices could not be listed: %s", tostring(set))
		set = nil
	end
	local ids = {}
	for id in pairs(type(set) == "table" and set or {}) do
		ids[#ids + 1] = id
	end
	table.sort(ids, function(a, b)
		local na, nb = tonumber(a), tonumber(b)
		if na and nb then
			return na < nb
		end
		return tostring(a) < tostring(b)
	end)
	for _, id in ipairs(ids) do
		self:send_to(id, self:params())
	end
	return #ids
end

-- One device, first in its hello's answer (D4, E17, E21): nothing before the
-- first evaluation, which tells every device anyway. False when nothing went.
function link:tell(device_id)
	if not self.first_done or device_id == nil then
		return false
	end
	self:send_to(device_id, self:params())
	return true
end

-- The change to offline (§3 "Timer fires"; D12, D13).
function link:go_offline()
	self:cancel_count()
	if self.is_offline then
		return
	end
	local ctx = self.ctx
	self.is_offline = true
	local reason = self:reason()
	self.told_reason = reason
	if not (self.stored and self.stored.since == self.since) then
		self.stored = { since = self.since, reason = reason }
		C4:PersistSetValue(link.KEY, { since = self.since, reason = reason })
	end
	local count = self:broadcast()
	ctx.log.info("Hue devices offline: the bridge %s since %s (%s); %d devices told", PHRASE[reason] or reason,
		self:clock(self.since), reason, count)
	ctx.refresh()
end

-- The count to offline, from `since`: OFFLINE_AFTER_S as it is now. Offline
-- at once when that time has passed (a stored outage, or a shorter dev setting).
function link:arm()
	self:cancel_count()
	local left = self.since + link.OFFLINE_AFTER_S * 1000 - self.now()
	if left <= 0 then
		return self:go_offline()
	end
	self.timer = self:set_timer(left, function()
		self.timer = nil
		if self.since == nil or self.is_offline then
			return
		end
		-- Re-armed when OFFLINE_AFTER_S grew meanwhile (retime is the usual way).
		self:arm()
	end)
end

-- While offline: a reason that changed is told again, with the same since (D3).
function link:recheck_reason()
	local reason = self:reason()
	if reason == self.told_reason then
		return
	end
	local ctx = self.ctx
	ctx.log.info("Hue devices offline: the bridge now %s (%s, was %s)", PHRASE[reason] or reason, reason,
		tostring(self.told_reason))
	self.told_reason = reason
	self:broadcast()
	ctx.refresh()
end

function link:trouble()
	if self.is_offline then
		return self:recheck_reason()
	end
	if self.since == nil then
		self.since = (self.stored and self.stored.since) or self.now()
		self.ctx.log.debug("bridge link: trouble since %s", self:clock(self.since))
	end
	if self.first_done and not self.timer then
		self:arm()
	end
end

-- D7: back at the first contact, without a settling wait. Cheap when nothing
-- is wrong: every 2xx of a keyed request lands here.
function link:contact()
	local ctx = self.ctx
	if self.since ~= nil or self.timer or self.is_offline then
		self:cancel_count()
		local since, was_offline = self.since, self.is_offline
		self.since, self.is_offline, self.told_reason = nil, false, nil
		if was_offline then
			local count = self:broadcast()
			ctx.log.info("Hue devices online: the bridge answers again after %s; %d devices told",
				duration(self.now() - (since or self.now())), count)
			ctx.refresh()
		end
	end
	if self.stored then
		self.stored = nil
		C4:PersistDeleteValue(link.KEY)
	end
	if not self.first_done then
		self:first_look()
	end
end

-- D2 (d), at every refresh_status(): trouble while the bridge cannot be used.
-- Never contact: that needs proof (D2 e-g).
function link:evaluate()
	local ctx = self.ctx
	if not ctx.paired() or ctx.keyed_refusal() ~= nil or ctx.state.identity_ok == false then
		self:trouble()
	end
end

-- The first evaluation of the run (D12): from now on the link tells and
-- counts. Every device hears the state now, whatever it is (D4, E18). D2 (d)
-- is evaluated first: bridge/identity.lua sets identity_ok = false for an
-- unsupported model, or a TLS check that stays inconclusive, without a
-- refresh_status() or an away call, so the FIRST_LOOK_S fallback is the
-- first moment that condition is seen at start.
function link:first_look()
	if self.first_done then
		return
	end
	self:cancel_look()
	self:evaluate() -- before first_done: it only notes the start, the count is armed below
	self.first_done = true
	if self.since ~= nil then
		if self.now() - self.since >= link.OFFLINE_AFTER_S * 1000 then
			return self:go_offline()
		end
		self:arm()
	end
	local count = self:broadcast()
	self.ctx.log.debug("bridge link: first look, %s; %d devices told online", self:status(), count)
end

-- Dev builds (D15): OFFLINE_AFTER_S changed; a running count follows it at once.
function link:retime()
	if self.first_done and self.since ~= nil and not self.is_offline then
		self:arm()
	end
end

-- §6.4, while offline and while there are Hue devices to be offline: one item,
-- with the time the devices went offline (since + OFFLINE_AFTER_S) and the
-- time the trouble began.
function link:attention_items()
	if not self.is_offline or self.since == nil then
		return {}
	end
	local ok, set = pcall(self.ctx.device_ids)
	if not ok or type(set) ~= "table" or next(set) == nil then
		return {}
	end
	local reason = self.told_reason or self:reason()
	return { string.format("Hue devices offline since %s: the bridge %s since %s; %s",
		self:clock(self.since + link.OFFLINE_AFTER_S * 1000), PHRASE[reason] or reason, self:clock(self.since),
		TAIL[reason] or BACK_BY_THEMSELVES) }
end

return link
