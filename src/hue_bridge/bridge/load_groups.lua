-- Control4 load groups on the bridge side (issue #435,
-- docs/load-groups-design.md §6.7): the requests that the members of one
-- Load Group send for one group command are collected into a batch and sent
-- together, and members that make up whole Hue rooms or zones get one
-- grouped_light request instead of one request per lamp.
--
-- Why: Director runs one C4:url transfer per host at a time [verified:
-- docs/design.md, "C4:url transfer scheduling"], so N lamp requests leave one
-- after another and the lamps "popcorn" (§2.4). One grouped_light request
-- moves every lamp of a room or zone at once [assumed: watched at H3].
--
-- What a member does never depends on this module (D5): each light device
-- acts on its own group command and tags its HUE_SET or HUE_DIM with `group`
-- = the GROUP ID. The memberships the devices report (HUE_LOAD_GROUPS, D6)
-- only let a batch close early (D7), so a stale membership costs at most
-- BATCH_MS, never a wrong command.
--
-- Batches (D7). The first tagged request of a group opens one. It closes
--   - when every expected member has sent (at once, from the caller);
--   - BATCH_MS after its first request (from its timer); or
--   - when a second request for a rid already in it arrives: the batch closes
--     and the new request opens the next one.
-- The expected members are the devices whose HUE_LOAD_GROUPS names the group
-- and whose light or zone entry is linked and not gone (ctx.rid_of). A group
-- with no expected member waits BATCH_MS: its membership is not known yet (a
-- bridge restart before the hellos, E19; a project restored from a backup,
-- E8), and "every expected member has sent" says nothing then.
--
-- At the close (D8), the `set` entries with identical fields form a class:
-- on, brightness, x, y, mirek and rate, each rounded as commands.body rounds
-- it; `urgent` is not part of it. In each class:
--   a. a zone or room light member goes out as today (ctx.zone_set), and the
--      lamp members of its Hue group are folded into it;
--   b. of the lamps left, every Hue room or zone (ctx.covers) with at least
--      COVER_MIN lights, all of them in the class, is a candidate: the largest
--      first, then by label; a chosen one never overlaps another, and each goes
--      out as one grouped_light request (ctx.group_set), urgent when any of its
--      entries was;
--   c. every other lamp goes out alone (ctx.light_set), in arrival order.
-- A lamp is folded only while its light queue is idle, and a cover is used
-- only while its grouped_light and every one of its lamps are idle and the
-- group queue has a token (ctx.light_idle, ctx.group_idle, ctx.group_token:
-- bridge/commands.lua's idle and token_ready, §6.8). Otherwise those lamps go
-- alone: the two queues have separate buckets, and an older lamp request must
-- never land after a newer group request. Every light of a cover is in the
-- class, so a lamp outside the load group is never touched. COVER = false
-- turns a's folding and b off: every lamp goes alone.
--
-- Holds (D9, D10). `dim` entries are never covered: Hue ignores a
-- dimming_delta's duration on a grouped_light and covers the delta in about a
-- second [verified: house 2026-10-25, docs/group-hold-design.md §1]. They go
-- out one by one after the sets, a zone or room light's through ctx.zone_dim
-- (bridge/group_hold.lua, as today), a lamp's through ctx.light_set. A lamp
-- request the light queue would send past its bucket (a dim, or a set marked
-- urgent: commands.urgent) keeps that urgency for the first PER_LIGHT_MAX
-- lamps of a batch; the later ones are marked `paced` (and lose `urgent`,
-- which would clear `paced` in the queue) and take the bucket's tokens. The
-- dims of a batch go out in arrival order, except that the rids of the
-- group's last hold start keep that start's order, so a hold's stops go out
-- in the order of its starts and every lamp ramps for about as long as the
-- button is held, the paced ones included (D9).
--
-- Self-healing membership (D15). An expected member missing from MISS_LIMIT
-- batches in a row that closed by time is no longer waited for, with one info
-- line, until its device sends HUE_LOAD_GROUPS or a tagged request for that
-- group again. A batch that closed for any other reason counts no miss, and
-- one with nothing left to send (every entry released or forgotten) counts
-- nothing.
--
-- Other commands win (D11): release(rid) sends that rid's open entry alone at
-- once, ahead of the untagged request the caller sends next; the batch keeps
-- the rid as heard from, so it neither waits for it nor counts it missing.
--
-- Keep loads in sync (D13): the sync flags of HUE_LOAD_GROUPS are not kept
-- here; the bridge never passes a change at one member on to the others.
--
-- Nothing is sent from inside command() except at a close. Every ctx callback
-- runs pcall-wrapped (a raise is logged and read as nil), a close runs
-- pcall-wrapped from the caller or from the batch's timer, and a timer acts
-- only for the batch that armed it (its token), so a timer whose Cancel came
-- too late, or one from before stop_all(), sends nothing. Nothing is
-- persisted: the devices send HUE_LOAD_GROUPS after every hello (E9, E19).
--
--   local lg = load_groups.new(ctx)
--   lg:memberships(device_id, groups_wire)  HUE_LOAD_GROUPS: replaces that device's groups ("none" clears them)
--   lg:forget_device(device_id)             HUE_GOODBYE: its groups and its open entries go, unsent (E7)
--   lg:command(op, params[, kind])          op "set" (HUE_SET) or "dim" (HUE_DIM), params as received with
--                                           params.group; true when taken into a batch (the caller sends
--                                           nothing more), false when it is no load group request (send as
--                                           today). `kind` ("light", or "zone"/"group" for a zone or room
--                                           light), when the caller knows it, saves the lookup below.
--   lg:release(rid)                         D11: that rid's open entry alone, now; true when one was sent
--   lg:stop_all()                           teardown: timers cancelled, open batches dropped, nothing sent
--
-- ctx (light_set is required; a missing or raising hook reads as nil, and a
-- nil idle or token answer refuses the cover, so its lamps go alone):
--   light_set(rid, fields)                  limits + the light queue's set(); fields as the HUE_SET and
--                                           HUE_DIM handlers map them, `paced` added (§6.8)
--   zone_set(params)                        zone_lights:set(params); true when queued
--   zone_dim(params)                        zone_lights:dim(params)
--   group_set(grouped_light_rid, fields)    the driver's group_hooks.group_set; true when queued
--   zone_lights(zone_rid)                   grouped_light_rid, { light_rid, ... } of a zone light's Hue
--                                           group; nil when the rid is no zone or room
--   covers()                                { { grouped_light, label, lights = { rid, ... } }, ... }: every
--                                           Hue room and zone in the lights' cache
--   rid_of(device_id)                       rid, kind ("group" or "zone" for a zone or room light) of a
--                                           linked device whose entry is not gone; nil otherwise
--   light_idle(rid), group_idle(rid)        the light and the group queue's idle(rid)
--   group_token()                           the group queue's token_ready()
--   set_timer(ms, fn)                       a one-shot timer with :Cancel() (default C4:SetTimer)
--   now()                                   a millisecond clock (default C4:GetTime)
--   log                                     common.log or a stand-in (default common.log)
--
-- How the entry's kind is found when the caller does not say: the kind
-- ctx.rid_of gives for the member device linked to that rid, else "zone"
-- when ctx.zone_lights knows the rid, else "light".

local default_log = require("common.log")
local num = require("common.num")

local load_groups = {}
load_groups.__index = load_groups

-- Tunables -------------------------------------------------------------------
-- Each rests on an assumption of the contract (§2.2, A1 to A10) or a choice
-- the house checks H0 to H8 (§8.2) confirm or correct. After the house
-- round, a change of batching is a change of these lines only.
load_groups.BATCH_MS = 150      -- #435 D7, A9: the longest a batch waits for its members (tuned at H2)
load_groups.MISS_LIMIT = 3      -- #435 D15, A8: timed-out batches in a row missed, then not waited for
load_groups.PER_LIGHT_MAX = 10  -- #435 D9: lamps per batch that keep their urgency (group_hold's too)
load_groups.COVER = true        -- #435 D8, owner's §10 Q1: whole Hue rooms and zones as one request (H3)
load_groups.COVER_MIN = 2       -- #435 D8 b: the fewest lights a Hue room or zone needs to be a cover
-- The most load groups one HUE_LOAD_GROUPS is taken with; the rest are
-- dropped with a warning (security review 2026-11-13 D-3, #488). A light
-- learns at most 32 (src/hue_light/light/load_group.lua).
load_groups.GROUPS_MAX = 256

-- [verified: API 34_timer/_1-SetTimer] as bridge/group_hold.lua.
local function c4_timer(ms, fn)
	return C4:SetTimer(ms, fn)
end

-- [verified: API 34_timer/_2-GetTime] milliseconds, as bridge/commands.lua.
local function c4_time()
	return C4:GetTime()
end

local function default_now()
	local ok, ms = pcall(c4_time)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

local DEFAULTS = { set_timer = c4_timer, now = default_now }

local DIRECTIONS = { up = true, down = true, stop = true }

-- How the info line (D16) names the dims of a batch.
local DIM_WORDS = { up = "dim up", down = "dim down", stop = "stop" }

local CLOSE_TEXT = {
	complete = "every member sent",
	time = "time",          -- written as "after <BATCH_MS> ms"
	second = "a second request",
	untimed = "no timer",
}

local function short(rid)
	return tostring(rid):sub(1, 8)
end

local function plural(n, word)
	return n .. " " .. word .. (n == 1 and "" or "s")
end

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end

local function cancel(timer)
	if timer then
		pcall(function() timer:Cancel() end)
	end
end

-- t[key], created empty when missing.
local function sub(t, key)
	local inner = t[key]
	if not inner then
		inner = {}
		t[key] = inner
	end
	return inner
end

local function round(n, decimals)
	local scale = 10 ^ decimals
	return math.floor(n * scale + 0.5) / scale
end

local function key_part(n, decimals)
	if n == nil then
		return "-"
	end
	return string.format("%." .. decimals .. "f", round(n, decimals))
end

-- A positive integer device id, or nil.
local function device_key(value)
	local n = num.finite(value)
	if n and n > 0 and n == math.floor(n) then
		return n
	end
	return nil
end

local function kind_of(kind)
	if kind == "zone" or kind == "group" then
		return "zone"
	end
	if kind == "light" then
		return "light"
	end
	return nil
end

-- Take `rid`'s entry out of a batch; the entry, or nil.
local function remove_entry(batch, rid)
	for i, entry in ipairs(batch.entries) do
		if entry.rid == rid then
			table.remove(batch.entries, i)
			return entry
		end
	end
	return nil
end

-- Pure helpers (exported for the spec) -----------------------------------------

-- A GROUP ID as one spelling: "1234" for "1234", " 01234 " or 1234; nil for
-- anything that is not a positive integer (§6.4's rule for the device's keys).
function load_groups.group_id(value)
	if type(value) ~= "string" and type(value) ~= "number" then
		return nil
	end
	local digits = tostring(value):match("^%s*(%d+)%s*$")
	if not digits then
		return nil
	end
	digits = digits:gsub("^0+", "")
	if digits == "" then
		return nil
	end
	return digits
end

-- HUE_LOAD_GROUPS' groups (§6.3), "1234:1,5678:0" or "none", as a set of
-- GROUP IDs, and how many more distinct ids the wire named than the
-- GROUPS_MAX kept (#488): the first GROUPS_MAX are kept, the rest dropped.
-- The sync flags are dropped (D13); a bad item is skipped.
function load_groups.parse_groups(wire)
	local out, kept, dropped, seen = {}, 0, 0, {}
	if type(wire) == "number" then
		wire = tostring(wire)
	end
	if type(wire) ~= "string" then
		return out, 0
	end
	for item in wire:gmatch("[^,]+") do
		local id = load_groups.group_id(item:match("^([^:]*)"))
		if id and not seen[id] then
			seen[id] = true
			if kept < load_groups.GROUPS_MAX then
				out[id] = true
				kept = kept + 1
			else
				dropped = dropped + 1
			end
		end
	end
	return out, dropped
end

-- HUE_SET params -> the light queue's fields, exactly as the driver's HUE_SET
-- handler maps them (`urgent` included; #421 D12). The zone lights' own
-- mapping (zone_lights:set) takes booleans for `on` too, and so does this.
-- Numbers that are not finite are left out (#486; the queue drops them too).
function load_groups.set_fields(params)
	local fields = {
		brightness = num.finite(params.brightness),
		x = num.finite(params.x),
		y = num.finite(params.y),
		mirek = num.finite(params.mirek),
		rate = num.finite(params.rate),
		urgent = (params.urgent == "true" or params.urgent == true) or nil,
	}
	if params.on == "true" or params.on == true then
		fields.on = true
	elseif params.on == "false" or params.on == false then
		fields.on = false
	end
	return fields
end

-- HUE_DIM params -> the light queue's fields, as the driver's HUE_DIM handler
-- maps them; nil for an unknown direction.
function load_groups.dim_fields(params)
	if not DIRECTIONS[params.direction] then
		return nil
	end
	return { dim = params.direction, rate = num.finite(params.duration), level = num.finite(params.level) }
end

-- D8: a set entry's class. The fields commands.body puts into a PUT, rounded
-- as it rounds them (brightness 2 decimals, xy 4, mirek and the duration
-- whole); `urgent` and the queue's own fields are no part of it.
function load_groups.class_key(fields)
	local on = "-"
	if fields.on == true then
		on = "on"
	elseif fields.on == false then
		on = "off"
	end
	return table.concat({ on, key_part(fields.brightness, 2), key_part(fields.x, 4), key_part(fields.y, 4),
		key_part(fields.mirek, 0), key_part(fields.rate, 0) }, " ")
end

-- Whether a class sets anything a grouped_light request could carry (a lone
-- rate does not; the queue sends nothing for it either).
local function settable(fields)
	return fields.on ~= nil or fields.brightness ~= nil or fields.mirek ~= nil
		or (fields.x ~= nil and fields.y ~= nil)
end

-- The module ------------------------------------------------------------------

function load_groups.new(ctx)
	ctx = ctx or {}
	assert(type(ctx.light_set) == "function", "load_groups.new: ctx.light_set is required")
	return setmetatable({
		ctx = ctx,
		log = ctx.log or default_log,
		groups_of = {},  -- device id -> { [group id] = true }, from its HUE_LOAD_GROUPS
		members = {},    -- group id -> { [device id] = true }
		misses = {},     -- group id -> { [device id] = timed-out batches in a row it missed } (D15)
		dropped = {},    -- group id -> { [device id] = true }: no longer waited for (D15)
		rids = {},       -- device id -> the rid it last resolved to (forget_device after a goodbye)
		open = {},       -- group id -> its open batch
		order = {},      -- group id -> { [rid] = position } in its last hold start (D9)
		tokens = 0,      -- the last token given to a batch
	}, load_groups)
end

local function results(self, name, ok, ...)
	if not ok then
		self.log.error("load groups: ctx.%s raised: %s", name, tostring((...)))
		return nil
	end
	return ...
end

-- ctx[name](...) pcall-wrapped: all its results, or nil (logged) when it
-- raised; nil as well for a hook the ctx does not have.
function load_groups:call(name, ...)
	local fn = self.ctx[name] or DEFAULTS[name]
	if type(fn) ~= "function" then
		return nil
	end
	return results(self, name, pcall(fn, ...))
end

function load_groups:now()
	local ms = tonumber(self:call("now"))
	return ms or 0
end

local function debug_on(log)
	return type(log.enabled) ~= "function" or log.enabled("debug")
end

local function info_on(log)
	return type(log.enabled) ~= "function" or log.enabled("info")
end

-- A device's rid and kind ("light" or "zone"), when linked and not gone.
function load_groups:resolve(id)
	local rid, kind = self:call("rid_of", id)
	if type(rid) ~= "string" or rid == "" then
		return nil
	end
	self.rids[id] = rid
	return rid, kind_of(kind) or "light"
end

-- Memberships (D6, D15) -------------------------------------------------------

-- D15: heard from device `id` in group `gid` (its HUE_LOAD_GROUPS, or a
-- tagged request): its misses start again and it is waited for again.
function load_groups:heard(gid, id)
	local misses = self.misses[gid]
	if misses then
		misses[id] = nil
	end
	local dropped = self.dropped[gid]
	if dropped and dropped[id] then
		dropped[id] = nil
		self.log.info("load group %s: device %d is waited for again", gid, id)
	end
end

function load_groups:leave(gid, id)
	local members = self.members[gid]
	if members then
		members[id] = nil
		if next(members) == nil then
			self.members[gid] = nil
		end
	end
	if self.misses[gid] then
		self.misses[gid][id] = nil
	end
	if self.dropped[gid] then
		self.dropped[gid][id] = nil
	end
end

-- HUE_LOAD_GROUPS { device_id, groups }: that device's groups become exactly
-- these ("none" or nothing clears them). False for a message without a
-- device id.
function load_groups:memberships(device_id, wire)
	local id = device_key(device_id)
	if not id then
		self.log.warn("load groups: HUE_LOAD_GROUPS without a device id ignored")
		return false
	end
	local groups, dropped = load_groups.parse_groups(wire)
	if dropped > 0 then
		self.log.warn("load groups: device %d named %d load groups; the first %d are kept, %d dropped", id,
			load_groups.GROUPS_MAX + dropped, load_groups.GROUPS_MAX, dropped)
	end
	local old = self.groups_of[id] or {}
	local touched = {}
	for gid in pairs(old) do
		touched[gid] = true
		if not groups[gid] then
			self:leave(gid, id)
		end
	end
	local list = {}
	for gid in pairs(groups) do
		touched[gid] = true
		sub(self.members, gid)[id] = true
		self:heard(gid, id)
		list[#list + 1] = gid
	end
	self.groups_of[id] = next(groups) and groups or nil
	local rid = self:resolve(id)
	if debug_on(self.log) then
		table.sort(list)
		self.log.debug("load groups: device %d (%s) in %s", id, rid and short(rid) or "not linked",
			#list > 0 and table.concat(list, ", ") or "none")
	end
	self:refresh_open(touched)
	return true
end

-- HUE_GOODBYE: the device leaves every group, and its open entries go
-- unsent (E7: a deleted device commands nothing).
function load_groups:forget_device(device_id)
	local id = device_key(device_id)
	if not id then
		return false
	end
	local rid = self.rids[id] or (self:resolve(id))
	local touched = {}
	for gid in pairs(self.groups_of[id] or {}) do
		self:leave(gid, id)
		touched[gid] = true
	end
	self.groups_of[id], self.rids[id] = nil, nil
	if rid then
		for gid, batch in pairs(self.open) do
			if remove_entry(batch, rid) then
				batch.seen[rid] = nil
				touched[gid] = true
			end
		end
	end
	self:refresh_open(touched)
	return true
end

-- Batches (D7) ----------------------------------------------------------------

-- The expected members of an open batch, again from the memberships: rid ->
-- device id for those waited for, `standby` for those D15 stopped waiting
-- for (a tagged request from one brings it back), and every member rid's kind.
function load_groups:refresh(batch)
	local expected, standby, kinds, count = {}, {}, {}, 0
	local dropped = self.dropped[batch.group] or {}
	for id in pairs(self.members[batch.group] or {}) do
		local rid, kind = self:resolve(id)
		if rid then
			kinds[rid] = kind
			if dropped[id] then
				standby[rid] = id
			elseif not expected[rid] then
				expected[rid] = id
				count = count + 1
			end
		end
	end
	batch.expected, batch.standby, batch.kinds, batch.expected_count = expected, standby, kinds, count
end

-- Membership changed for these groups: their open batches look again, and
-- one that now has every member closes.
function load_groups:refresh_open(gids)
	local batches = {}
	for gid in pairs(gids) do
		if self.open[gid] then
			batches[#batches + 1] = self.open[gid]
		end
	end
	table.sort(batches, function(a, b) return a.token < b.token end)
	for _, batch in ipairs(batches) do
		self:refresh(batch)
		self:check(batch)
	end
end

function load_groups:open_batch(gid)
	self.tokens = self.tokens + 1
	local token = self.tokens
	local batch = { group = gid, token = token, entries = {}, seen = {}, seq = 0 }
	self:refresh(batch)
	self.open[gid] = batch
	batch.timer = self:call("set_timer", load_groups.BATCH_MS, function()
		local current = self.open[gid]
		if not current or current.token ~= token then
			return -- closed (every member, a second request, stop_all) after this timer was armed
		end
		current.timer = nil
		self:safe_close(current, "time")
	end)
	if not batch.timer then
		-- No timer, no wait: the batch closes with its first request rather
		-- than holding it for good.
		self.log.error("load group %s: no timer for the batch; sending at once", gid)
		batch.untimed = true
	end
	return batch
end

function load_groups:add(batch, entry)
	batch.seq = batch.seq + 1
	entry.seq = batch.seq
	batch.entries[#batch.entries + 1] = entry
	batch.seen[entry.rid] = true
	local id = batch.standby[entry.rid]
	if id then
		-- D15: a tagged request brings a member back.
		batch.standby[entry.rid] = nil
		batch.expected[entry.rid] = id
		batch.expected_count = batch.expected_count + 1
		self:heard(batch.group, id)
	end
end

-- Close the batch when every expected member has sent (a group with no
-- known member waits for its timer).
function load_groups:check(batch)
	if self.open[batch.group] ~= batch then
		return
	end
	if batch.untimed then
		return self:safe_close(batch, "untimed")
	end
	if batch.expected_count == 0 then
		return
	end
	for rid in pairs(batch.expected) do
		if not batch.seen[rid] then
			return
		end
	end
	self:safe_close(batch, "complete")
end

-- A tagged HUE_SET (op "set") or HUE_DIM (op "dim"). See the header.
function load_groups:command(op, params, kind)
	if (op ~= "set" and op ~= "dim") or type(params) ~= "table" then
		return false
	end
	local gid = load_groups.group_id(params.group)
	local rid = params.rid
	if not gid or type(rid) ~= "string" or rid == "" then
		return false
	end
	local fields
	if op == "set" then
		fields = load_groups.set_fields(params)
	else
		fields = load_groups.dim_fields(params)
		if not fields then
			return false -- the caller's own path warns about the direction
		end
	end
	local batch = self.open[gid]
	if batch and batch.seen[rid] then
		self:safe_close(batch, "second", rid)
		batch = nil
	end
	batch = batch or self:open_batch(gid)
	local entry = { rid = rid, op = op, fields = fields, params = params, at = self:now() }
	entry.kind = kind_of(kind) or batch.kinds[rid]
	if not entry.kind then
		entry.kind = self:call("zone_lights", rid) and "zone" or "light"
	end
	self:add(batch, entry)
	self:check(batch)
	return true
end

-- D11: send `rid`'s open entry alone now, from every open batch (the older
-- batch first), ahead of the untagged request the caller sends next.
function load_groups:release(rid)
	if type(rid) ~= "string" or rid == "" then
		return false
	end
	local batches = {}
	for _, batch in pairs(self.open) do
		batches[#batches + 1] = batch
	end
	table.sort(batches, function(a, b) return a.token < b.token end)
	local sent = false
	for _, batch in ipairs(batches) do
		local entry = remove_entry(batch, rid)
		if entry then
			self.log.debug("load group %s: %s sent alone, ahead of a command of its own (D11)", batch.group,
				short(rid))
			self:send_alone(entry, nil)
			sent = true
		end
	end
	return sent
end

-- Teardown: every timer cancelled, every open batch dropped unsent (the
-- queues are being stopped with this call). The memberships stay.
function load_groups:stop_all()
	local open = self.open
	self.open = {}
	for _, batch in pairs(open) do
		cancel(batch.timer)
		batch.timer = nil
	end
end

-- Closing -----------------------------------------------------------------------

function load_groups:safe_close(batch, why, rid)
	local ok, err = pcall(self.close, self, batch, why, rid)
	if not ok then
		self.log.error("load group %s: closing the batch failed: %s", tostring(batch.group), tostring(err))
	end
end

function load_groups:close(batch, why, rid)
	if self.open[batch.group] == batch then
		self.open[batch.group] = nil
	end
	cancel(batch.timer)
	batch.timer = nil
	if #batch.entries == 0 then
		self.log.debug("load group %s: closed with nothing left to send", batch.group)
		return
	end
	self:count_misses(batch, why == "time")
	self:log_close(batch, why, rid)
	self:send_batch(batch)
end

-- D15 at a close: a member heard from starts again; at a close by time, a
-- member not heard from counts a miss, and the MISS_LIMIT-th in a row stops
-- the waiting for it.
function load_groups:count_misses(batch, timed)
	local gid = batch.group
	local misses = sub(self.misses, gid)
	for rid, id in pairs(batch.expected) do
		if batch.seen[rid] then
			misses[id] = nil
		elseif timed then
			local n = (misses[id] or 0) + 1
			if n >= load_groups.MISS_LIMIT then
				misses[id] = nil
				sub(self.dropped, gid)[id] = true
				self.log.info("load group %s: device %d (%s) missed %d batches in a row; not waited for until it is "
					.. "heard from again (#435 D15)", gid, id, short(rid), n)
			else
				misses[id] = n
			end
		end
	end
end

-- D16 at debug: why the batch closed and when each request arrived (H2 sets
-- BATCH_MS from these), with the members still missing.
function load_groups:log_close(batch, why, rid)
	if not debug_on(self.log) then
		return
	end
	local text = CLOSE_TEXT[why] or tostring(why)
	if why == "time" then
		text = "after " .. load_groups.BATCH_MS .. " ms"
	elseif why == "second" and rid then
		text = "a second request for " .. short(rid)
	end
	local first = batch.entries[1].at
	local arrivals = {}
	for _, entry in ipairs(batch.entries) do
		arrivals[#arrivals + 1] = string.format("%s +%d ms", short(entry.rid), entry.at - first)
	end
	local missing = {}
	for member_rid, id in pairs(batch.expected) do
		if not batch.seen[member_rid] then
			missing[#missing + 1] = string.format("device %d", id)
		end
	end
	table.sort(missing)
	self.log.debug("load group %s: closed (%s): %s; %s waited for%s", batch.group, text, table.concat(arrivals, ", "),
		plural(batch.expected_count, "member"), #missing > 0 and (", missing " .. table.concat(missing, ", ")) or "")
end

-- ctx.covers(), checked and in D8's order: the most lights first, then by
-- label, then by grouped_light. Each light once per cover.
function load_groups:read_covers()
	local out = {}
	local list = self:call("covers")
	if type(list) ~= "table" then
		return out
	end
	for _, cover in ipairs(list) do
		if type(cover) == "table" and type(cover.grouped_light) == "string" and cover.grouped_light ~= ""
			and type(cover.lights) == "table" then
			local lights, seen = {}, {}
			for _, rid in ipairs(cover.lights) do
				if type(rid) == "string" and rid ~= "" and not seen[rid] then
					seen[rid] = true
					lights[#lights + 1] = rid
				end
			end
			out[#out + 1] = { grouped_light = cover.grouped_light, lights = lights,
				label = type(cover.label) == "string" and cover.label or short(cover.grouped_light) }
		end
	end
	table.sort(out, function(a, b)
		if #a.lights ~= #b.lights then
			return #a.lights > #b.lights
		end
		if a.label ~= b.label then
			return a.label < b.label
		end
		return a.grouped_light < b.grouped_light
	end)
	return out
end

-- Why a cover cannot be used now (D8), or nil when it can.
function load_groups:cover_refusal(cover)
	if self:call("group_idle", cover.grouped_light) ~= true then
		return "its grouped_light is busy"
	end
	for _, rid in ipairs(cover.lights) do
		if self:call("light_idle", rid) ~= true then
			return "light " .. short(rid) .. " is busy"
		end
	end
	if self:call("group_token") ~= true then
		return "no group token"
	end
	return nil
end

local function any_urgent(entries)
	for _, entry in ipairs(entries) do
		if entry.fields.urgent then
			return true
		end
	end
	return false
end

-- The grouped_light fields of a cover: the class's fields (identical within
-- it), urgent when any of its entries was (§6.7).
local function cover_fields(entries)
	local first = entries[1].fields
	return { on = first.on, brightness = first.brightness, x = first.x, y = first.y, mirek = first.mirek,
		rate = first.rate, urgent = any_urgent(entries) or nil }
end

-- D8 for one class: its zone light members with their folded lamps into
-- plan.zones, its covers into plan.covers, the rest into plan.alone. The
-- cover arithmetic goes to the debug log.
function load_groups:plan_class(batch, class, plan)
	local lamps, zones, left = {}, {}, 0
	for _, entry in ipairs(class.entries) do
		if entry.kind == "zone" then
			zones[#zones + 1] = entry
		else
			lamps[entry.rid] = entry
			left = left + 1
		end
	end
	local coverable = load_groups.COVER == true and settable(class.entries[1].fields)
	local notes = {}
	-- a. A zone or room light member as today, with its own lamps folded in.
	for _, zone in ipairs(zones) do
		local folded = {}
		local grouped, lights = self:call("zone_lights", zone.rid)
		if coverable and left > 0 and type(lights) == "table" then
			for _, rid in ipairs(lights) do
				local lamp = lamps[rid]
				if lamp then
					if self:call("light_idle", rid) == true then
						folded[#folded + 1] = lamp
						lamps[rid] = nil
						left = left - 1
					else
						notes[#notes + 1] = short(rid) .. " not folded (busy)"
					end
				end
			end
		end
		plan.zones[#plan.zones + 1] = { entry = zone, folded = folded, grouped = grouped }
	end
	-- b. Whole Hue rooms and zones of the lamps left, the largest first.
	if coverable and left >= load_groups.COVER_MIN then
		plan.cover_list = plan.cover_list or self:read_covers()
		local taken = {}
		for _, cover in ipairs(plan.cover_list) do
			local whole = #cover.lights >= load_groups.COVER_MIN
			local overlap = false
			for _, rid in ipairs(cover.lights) do
				if not lamps[rid] then
					whole = false
					break
				end
				if taken[rid] then
					overlap = true
				end
			end
			if whole then
				local refused = overlap and "overlaps one taken before it" or self:cover_refusal(cover)
				if refused then
					notes[#notes + 1] = string.format("%s (%s) refused: %s", cover.label, plural(#cover.lights, "light"),
						refused)
				else
					local entries = {}
					for _, rid in ipairs(cover.lights) do
						taken[rid] = true
						entries[#entries + 1] = lamps[rid]
					end
					plan.covers[#plan.covers + 1] = { cover = cover, entries = entries }
					notes[#notes + 1] = string.format("%s (%s) taken", cover.label, plural(#cover.lights, "light"))
				end
			end
		end
		for rid in pairs(taken) do
			lamps[rid] = nil
		end
	end
	-- c. Every other lamp alone, in arrival order.
	for _, entry in ipairs(class.entries) do
		if entry.kind ~= "zone" and lamps[entry.rid] == entry then
			plan.alone[#plan.alone + 1] = entry
		end
	end
	if debug_on(self.log) then
		self.log.debug("load group %s: fields %s: %s%s%s", batch.group, class.key, plural(#class.entries, "request"),
			coverable and "" or (load_groups.COVER and " (nothing a group request carries)" or " (covers off)"),
			#notes > 0 and ("; " .. table.concat(notes, "; ")) or "")
	end
end

-- D9: a lamp request that would skip the light bucket keeps its urgency for
-- the first PER_LIGHT_MAX of the batch; the later ones are paced. A dim is
-- urgent in the light queue without a flag (commands.urgent: a hold's start
-- and every stop); a set only with `urgent`, which must go, since a request
-- carrying it clears `paced` in the queue (§6.8).
local function lamp_fields(entry, budget)
	local fields = copy(entry.fields)
	if budget and (fields.dim ~= nil or fields.urgent == true) then
		budget.used = budget.used + 1
		if budget.used > load_groups.PER_LIGHT_MAX then
			fields.urgent = nil
			fields.paced = true
			budget.paced = budget.paced + 1
		end
	end
	return fields
end

-- One entry on its own, as the caller would have sent it without a batch.
function load_groups:send_alone(entry, budget)
	if entry.kind == "zone" then
		if entry.op == "dim" then
			return self:call("zone_dim", entry.params)
		end
		return self:call("zone_set", entry.params)
	end
	return self:call("light_set", entry.rid, lamp_fields(entry, budget))
end

-- D9: the dims in arrival order, the rids of the group's last hold start in
-- that start's order first; a batch with a start remembers its order.
function load_groups:order_dims(gid, dims)
	local known = self.order[gid] or {}
	table.sort(dims, function(a, b)
		local ka, kb = known[a.rid], known[b.rid]
		if ka and kb then
			return ka < kb
		end
		if ka or kb then
			return ka ~= nil
		end
		return a.seq < b.seq
	end)
	for _, entry in ipairs(dims) do
		if entry.fields.dim == "up" or entry.fields.dim == "down" then
			local order = {}
			for i, dim in ipairs(dims) do
				order[dim.rid] = i
			end
			self.order[gid] = order
			return
		end
	end
end

-- The label of a zone light member's Hue group, for the log.
local function zone_label(plan, zone)
	for _, cover in ipairs(plan.cover_list or {}) do
		if cover.grouped_light == zone.grouped then
			return cover.label
		end
	end
	return "zone light " .. short(zone.entry.rid)
end

-- Plan and send a closed batch (D8, D9), then its info line (D16).
function load_groups:send_batch(batch)
	local entries = batch.entries
	local plan = { zones = {}, covers = {}, alone = {} }
	local classes, class_list, dims = {}, {}, {}
	for _, entry in ipairs(entries) do
		if entry.op == "set" then
			local key = load_groups.class_key(entry.fields)
			local class = classes[key]
			if not class then
				class = { key = key, entries = {} }
				classes[key] = class
				class_list[#class_list + 1] = class
			end
			class.entries[#class.entries + 1] = entry
		else
			dims[#dims + 1] = entry
		end
	end
	for _, class in ipairs(class_list) do
		self:plan_class(batch, class, plan)
	end
	local parts = {}
	if #plan.zones > 0 and not plan.cover_list and load_groups.COVER == true then
		plan.cover_list = self:read_covers() -- for the labels only
	end
	-- a. Zone and room light members, as today. A folded lamp whose zone
	-- light's request was not queued goes alone after all.
	for _, zone in ipairs(plan.zones) do
		local params = zone.entry.params
		if #zone.folded > 0 and not zone.entry.fields.urgent and any_urgent(zone.folded) then
			params = copy(params)
			params.urgent = "true"
		end
		local queued = self:call("zone_set", params) == true
		if not queued then
			for _, lamp in ipairs(zone.folded) do
				plan.alone[#plan.alone + 1] = lamp
			end
		end
		parts[#parts + 1] = zone_label(plan, zone) .. " zone light as 1 request"
			.. ((queued and #zone.folded > 0) and string.format(" (%s folded in)", plural(#zone.folded, "light")) or "")
	end
	-- b. Covers: one grouped_light request each; refused by the group queue,
	-- their lamps go alone.
	for _, item in ipairs(plan.covers) do
		if self:call("group_set", item.cover.grouped_light, cover_fields(item.entries)) == true then
			parts[#parts + 1] = item.cover.label .. " as 1 request"
		else
			self.log.warn("load group %s: the group queue took nothing for %s; its lights go alone", batch.group,
				item.cover.label)
			for _, lamp in ipairs(item.entries) do
				plan.alone[#plan.alone + 1] = lamp
			end
		end
	end
	-- c. The other lamps alone, in arrival order, then the dims (D9).
	local budget = { used = 0, paced = 0 }
	table.sort(plan.alone, function(a, b) return a.seq < b.seq end)
	for _, entry in ipairs(plan.alone) do
		self:send_alone(entry, budget)
	end
	if #plan.alone > 0 then
		parts[#parts + 1] = plural(#plan.alone, "light") .. " alone"
	end
	self:order_dims(batch.group, dims)
	local dim_counts, dim_kinds = {}, {}
	for _, entry in ipairs(dims) do
		self:send_alone(entry, budget)
		local what = (entry.kind == "zone" and "zone light|" or "light|") .. entry.fields.dim
		if not dim_counts[what] then
			dim_counts[what] = 0
			dim_kinds[#dim_kinds + 1] = what
		end
		dim_counts[what] = dim_counts[what] + 1
	end
	for _, what in ipairs(dim_kinds) do
		local noun, dir = what:match("^([^|]+)|(.+)$")
		parts[#parts + 1] = plural(dim_counts[what], noun) .. " " .. DIM_WORDS[dir]
			.. (noun == "light" and " one by one" or "")
	end
	if budget.paced > 0 then
		parts[#parts + 1] = budget.paced .. " paced"
	end
	if info_on(self.log) then
		local first, last = entries[1].at, entries[1].at
		for _, entry in ipairs(entries) do
			first, last = math.min(first, entry.at), math.max(last, entry.at)
		end
		self.log.info("load group %s: %s in %d ms: %s", batch.group, plural(#entries, "light"), last - first,
			table.concat(parts, ", "))
	end
end

return load_groups
