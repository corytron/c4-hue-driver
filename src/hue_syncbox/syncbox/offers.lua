-- The Sync Box Settings offers of the Hue Sync Box driver (2.0 beta stage 4,
-- #568; docs/hdmi-sync-stage4-design.md §1.4 and §5, design
-- docs/hdmi-sync-design.md §5.4 and §5.8, contracts C1.4, C1.5 and C2 in
-- docs/hdmi-sync-contracts.md, owner's answers O4 and O18): what the box
-- does by itself is shown, put on Attention while it switches inputs and
-- Control4 routes through it, and turned off or put back only by a click.
--
--   local o = offers.new{ client, poller, persist_get, persist_set,
--                         persist_delete, now, log }
--   o:observe(model)     every good read (syncbox/state.lua's model)
--   o:choices()          → { { text, value } }: the Sync Box Settings items
--                        (OFFER_LET, then OFFER_RESTORE), always both
--   o:choose(value, done) → true when `value` is one of them (else false,
--                        done not called); done(ok, text) once, `text` for
--                        Last Action. One PUT /behavior at most
--   o:row()              → the Input Switching row (contracts C1.4)
--   o:attention(routed)  → a text while the box switches inputs by itself
--                        and Control4 routes through it (`routed` false: nil)
--   o:record()           → a copy of the recorded previous values, or nil
--   o:stop()             a PUT still out is forgotten (OnDriverDestroyed)
--
-- What the offer turns off (contracts C2's PUT /behavior; design 5.8, O18;
-- docs/syncbox-behaviour.md SB60 to SB63; docs/syncbox-api-research.md
-- §2.8), each only where the box has it and only while it is on:
--   per input  cecInputSwitch       switch to an input whose source sends
--                                   HDMI CEC "active source" (SB70)
--              hpdInputPortSwitch   switch to an input plugged in or powered
--                                   on (API level 10, SB71)
--              linkAutoSync         start syncing when an input links (SB73)
--   box-wide   hpdInputSwitch       the same hot-plug switch for every input
--                                   (HSB1 and HSB2, SB62)
--              cecPowersave         power save when the TV sends CEC standby
--                                   (SB75; O18: Control4 owns power)
-- usbPowersave, inactivePowersave, arcBypassMode, soloMode and hdrMode are
-- never written: the first two are no CEC behaviour and stay the box's (O18
-- names only CEC), the wiring is the Hue Sync app's (design 5.8), and the
-- rest is picture settings (edge cases §7).
--
-- The rules (edge cases B24, I1, rule 5: the box's own automations are
-- Hue-side automations, shown and changed only by a click that can be
-- undone, as the Hue automation audit does):
--   - Never written by itself: only o:choose writes, and only on a click.
--   - Reversible: the values a click changes are recorded before the PUT
--     goes (a lost answer must not lose them), keyed by the box's id, and
--     Restore puts back exactly those values. A second Let Control4 choose
--     inputs adds only what is on again; a value already recorded keeps the
--     one recorded first, so a second click never overwrites the box's own
--     settings with Control4's. A refused PUT changed nothing on the box
--     (SB20), so its record is rolled back; a PUT that got no answer may have
--     landed, so its record stays.
--   - Restore sends only the recorded settings the box still has (a key the
--     box lacks is refused whole with 13, SB18, SB62) and says which it
--     skipped; nothing differing means nothing sent. The record goes once
--     the box accepted the PUT, and only then.
--   - A record of another box (the box was replaced, edge cases B7) is never
--     put on this one: it is not offered, and the next Let Control4 choose
--     inputs starts a new record for this box.
--   - Attention only for input switching (CEC or hot-plug), because that
--     changes the picture behind Control4's back (I1); auto-sync and power
--     save stay on the row (B24) and in the offer (O18).
--
-- The record is persisted plain (no secret in it) under KEY: { v, box_id,
-- at, values = { ["cecPowersave"] = 1, ["input1.cecInputSwitch"] = 1, ... }
-- } [verified: SDK docs-driverworks-api 26.5_persistence/_4-PersistSetValue.md:
-- a table value, nested tables allowed]. PersistSetValue is called without
-- the encrypted argument: the flag goes only when true, and an explicit nil
-- raises on the controller (syncbox/store.lua, #547). PersistGetValue may lag
-- a write made moments before (same page), so the record is read from the
-- storage only once a run and kept in memory.
--
-- DriverWorks calls: none but the defaults of persist_get, persist_set and
-- persist_delete (C4:PersistGetValue, PersistSetValue, PersistDeleteValue)
-- and of now (C4:GetTime). `client` is syncbox/client.lua's (c:put(path,
-- body, cb), cb(ok, status, decoded, err)), `poller` syncbox/poller.lua's
-- (p:soon(reason), optional).

local num = require("common.num")
local https = require("common.https")

local offers = {}
offers.__index = offers

offers.KEY = "syncbox_input_offer"
offers.VERSION = 1
offers.PATH = "/behavior"
offers.INPUTS = 4
offers.OFFER_LET = "inputs:control4"
offers.OFFER_RESTORE = "inputs:restore"
offers.LABEL_LET = "Let Control4 choose inputs"
offers.LABEL_RESTORE = "Restore the box's input switching"
offers.UNKNOWN = "\226\128\148" -- an em dash: nothing known (as syncbox/state.lua)
offers.ROW_MAX = https.TEXT_ROW
offers.TEXT_MAX = 400          -- a Last Action text, before its wrap onto (2) to (6)
offers.REASON_MAX = 120        -- the box's own words in a refusal

-- The model's names of the settings (syncbox/state.lua's behavior) and the
-- box's. Order is the order of the texts.
offers.PER_INPUT = {
	{ key = "cecInputSwitch", field = "cec_input_switch" },
	{ key = "hpdInputPortSwitch", field = "hpd_input_port_switch" },
	{ key = "linkAutoSync", field = "link_auto_sync" },
}
offers.BOX_WIDE = {
	{ key = "hpdInputSwitch", field = "hpd_input_switch" },
	{ key = "cecPowersave", field = "cec_powersave" },
}

-- The client's own refusals: nothing reached the box (syncbox/client.lua).
local NOT_SENT = { ["not paired"] = true, ["no box address"] = true, busy = true,
	["invalid request path"] = true }

local KNOWN_KEYS = {}
for _, s in ipairs(offers.BOX_WIDE) do
	KNOWN_KEYS[s.key] = true
end
for n = 1, offers.INPUTS do
	for _, s in ipairs(offers.PER_INPUT) do
		KNOWN_KEYS["input" .. n .. "." .. s.key] = true
	end
end

local function default_get(name)
	return C4:PersistGetValue(name)
end

local function default_set(name, value)
	return C4:PersistSetValue(name, value)
end

local function default_delete(name)
	return C4:PersistDeleteValue(name)
end

local function default_now()
	local ok, ms = pcall(C4.GetTime, C4)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

function offers.new(deps)
	deps = deps or {}
	return setmetatable({
		client = deps.client,
		poller = deps.poller,
		persist_get = deps.persist_get or default_get,
		persist_set = deps.persist_set or default_set,
		persist_delete = deps.persist_delete or default_delete,
		now = deps.now or default_now,
		log = deps.log or require("common.log"),
		model = nil,
		rec = nil,       -- the record in memory (false: none)
		busy = false,    -- a PUT of ours is out
		gen = 0,         -- bumped by stop(): a late answer changes nothing
	}, offers)
end

-- The settings ---------------------------------------------------------------------

-- Every setting the box has in `model`: { { key, input, kind, on } } in the
-- texts' order; nil when the read carried no behavior.
function offers.settings(model)
	local b = type(model) == "table" and type(model.behavior) == "table" and model.behavior or nil
	if not b then
		return nil
	end
	local out = {}
	for _, s in ipairs(offers.PER_INPUT) do
		for _, i in ipairs(type(b.inputs) == "table" and b.inputs or {}) do
			local n = num.int(i.n, 1, offers.INPUTS)
			if n and i[s.field] ~= nil then
				out[#out + 1] = { key = "input" .. n .. "." .. s.key, input = n, kind = s.key, on = i[s.field] == true }
			end
		end
	end
	for _, s in ipairs(offers.BOX_WIDE) do
		if b[s.field] ~= nil then
			out[#out + 1] = { key = s.key, kind = s.key, on = b[s.field] == true }
		end
	end
	return out
end

local function by_key(list)
	local out = {}
	for _, s in ipairs(list or {}) do
		out[s.key] = s
	end
	return out
end

-- "HDMI 1, 2"
local function inputs_text(ns)
	table.sort(ns)
	local parts = {}
	for i, n in ipairs(ns) do
		parts[i] = tostring(n)
	end
	return "HDMI " .. table.concat(parts, ", ")
end

-- The settings named by `keys` (a list of box keys, "input1.cecInputSwitch"
-- or "cecPowersave") in words: "HDMI CEC switching on HDMI 1, 2; hot-plug
-- switching; auto-sync on HDMI 1; power save when the TV turns off".
function offers.describe(keys)
	local cec, port, auto, hpd, power = {}, {}, {}, false, false
	for _, key in ipairs(keys or {}) do
		local n, kind = tostring(key):match("^input(%d)%.(%a+)$")
		n = tonumber(n)
		if kind == "cecInputSwitch" then
			cec[#cec + 1] = n
		elseif kind == "hpdInputPortSwitch" then
			port[#port + 1] = n
		elseif kind == "linkAutoSync" then
			auto[#auto + 1] = n
		elseif key == "hpdInputSwitch" then
			hpd = true
		elseif key == "cecPowersave" then
			power = true
		end
	end
	local parts = {}
	if #cec > 0 then
		parts[#parts + 1] = "HDMI CEC switching on " .. inputs_text(cec)
	end
	if hpd and #port > 0 then
		parts[#parts + 1] = "hot-plug switching (all inputs, and on " .. inputs_text(port) .. ")"
	elseif hpd then
		parts[#parts + 1] = "hot-plug switching"
	elseif #port > 0 then
		parts[#parts + 1] = "hot-plug switching on " .. inputs_text(port)
	end
	if #auto > 0 then
		parts[#parts + 1] = "auto-sync on " .. inputs_text(auto)
	end
	if power then
		parts[#parts + 1] = "power save when the TV turns off"
	end
	return table.concat(parts, "; ")
end

local function keys_of(list, pred)
	local out = {}
	for _, s in ipairs(list or {}) do
		if pred(s) then
			out[#out + 1] = s.key
		end
	end
	return out
end

-- The PUT /behavior body of `values` ({ [key] = 0 | 1 }): box-wide keys at the
-- top, an input's under "inputN" (SB60: no /behavior/inputN path).
function offers.body(values)
	local body, count = {}, 0
	for key, v in pairs(values) do
		local n, kind = tostring(key):match("^(input%d)%.(%a+)$")
		if n then
			body[n] = body[n] or {}
			body[n][kind] = v
		else
			body[key] = v
		end
		count = count + 1
	end
	return body, count
end

-- The record ---------------------------------------------------------------------------

-- A stored record as it may be used, or nil (an older build, a bug, a
-- hand-edited store): the box id 12 hex digits, values 0 or 1 under known
-- keys only, at least one.
local function check_record(r)
	if type(r) ~= "table" or r.v ~= offers.VERSION then
		return nil
	end
	local id = type(r.box_id) == "string" and #r.box_id == 12 and not r.box_id:find("%X") and r.box_id:upper()
	if not id or type(r.values) ~= "table" then
		return nil
	end
	local values, any = {}, false
	for key, v in pairs(r.values) do
		local flag = num.int(v, 0, 1)
		if KNOWN_KEYS[key] and flag ~= nil and num.finite(v) == flag then
			values[key] = flag
			any = true
		end
	end
	if not any then
		return nil
	end
	return { v = offers.VERSION, box_id = id, at = num.int(r.at, 0), values = values }
end

local function copy_record(r)
	if not r then
		return nil
	end
	local values = {}
	for k, v in pairs(r.values) do
		values[k] = v
	end
	return { v = r.v, box_id = r.box_id, at = r.at, values = values }
end

function offers:load()
	if self.rec == nil then
		local ok, value = pcall(self.persist_get, offers.KEY)
		local rec = ok and check_record(value) or nil
		if ok and value ~= nil and rec == nil then
			self.log.warn("Sync box: the recorded input switching settings are not usable; Restore has nothing to "
				.. "put back")
		end
		self.rec = rec or false
	end
	return self.rec or nil
end

function offers:save(rec)
	self.rec = rec or false
	local ok, err
	if rec then
		ok, err = pcall(self.persist_set, offers.KEY, copy_record(rec))
	else
		ok, err = pcall(self.persist_delete, offers.KEY)
	end
	if not ok then
		self.log.warn("Sync box: could not store the input switching settings: %s", tostring(err))
	end
end

function offers:record()
	return copy_record(self:load())
end

-- The record of the box read last, or nil.
function offers:own_record()
	local rec = self:load()
	local id = type(self.model) == "table" and self.model.id or nil
	if rec and id and rec.box_id == id then
		return rec
	end
	return nil
end

-- The recorded keys whose value differs from the box's now (the box has
-- them), and the recorded keys the box lacks now.
function offers:restorable()
	local rec = self:own_record()
	if not rec then
		return nil
	end
	local have = by_key(offers.settings(self.model))
	local differ, missing = {}, {}
	for key, v in pairs(rec.values) do
		local s = have[key]
		if not s then
			missing[#missing + 1] = key
		elseif (s.on and 1 or 0) ~= v then
			differ[#differ + 1] = key
		end
	end
	table.sort(differ)
	table.sort(missing)
	return differ, missing
end

-- The surface -----------------------------------------------------------------------------

function offers:observe(model)
	if type(model) == "table" then
		self.model = model
	end
end

local function cap(s, max)
	return https.peer_text(s, max or offers.TEXT_MAX)
end

function offers:choices()
	local list = offers.settings(self.model)
	local let
	if not list then
		let = offers.LABEL_LET .. " (once the box has been read)"
	else
		local on = keys_of(list, function(s) return s.on end)
		let = #on > 0 and string.format("%s (turns off %s)", offers.LABEL_LET, offers.describe(on))
			or offers.LABEL_LET .. " (nothing to turn off)"
	end
	local restore
	local differ = self:restorable()
	if differ and #differ > 0 then
		restore = string.format("%s (puts back %s)", offers.LABEL_RESTORE, offers.describe(differ))
	elseif differ then
		restore = offers.LABEL_RESTORE .. " (the box has its own settings back)"
	else
		restore = offers.LABEL_RESTORE .. " (nothing recorded to put back)"
	end
	return {
		{ text = cap(let, 240), value = offers.OFFER_LET },
		{ text = cap(restore, 240), value = offers.OFFER_RESTORE },
	}
end

function offers:row()
	local list = offers.settings(self.model)
	if not list then
		return offers.UNKNOWN
	end
	local on = keys_of(list, function(s) return s.on end)
	if #on > 0 then
		return cap("By the box: " .. offers.describe(on), offers.ROW_MAX)
	end
	local differ = self:restorable()
	if differ and #differ > 0 then
		return cap("None: turned off from Control4 (Sync Box Settings can restore the box's own)", offers.ROW_MAX)
	end
	return "None: the box neither switches inputs nor starts syncing by itself"
end

-- Input switching: CEC per input, hot-plug box-wide or per input.
local SWITCHING = { cecInputSwitch = true, hpdInputPortSwitch = true, hpdInputSwitch = true }

function offers:attention(routed)
	if routed == false then
		return nil
	end
	local switching = keys_of(offers.settings(self.model), function(s) return s.on and SWITCHING[s.kind] end)
	if #switching == 0 then
		return nil
	end
	return cap(string.format("The box switches inputs by itself (%s) while Control4 routes through it: Control4 "
		.. "may show the wrong source (Sync Box Settings: %s)", offers.describe(switching), offers.LABEL_LET))
end

-- The clicks --------------------------------------------------------------------------------

-- done(ok, text), once, under pcall.
function offers:say(done, ok, text)
	if done then
		local okc, err = pcall(done, ok, cap(text))
		if not okc then
			self.log.warn("Sync box: Sync Box Settings' answer failed: %s", tostring(err))
		end
	end
end

-- The box's words in a refusal: its message, else the client's text.
local function reason_of(decoded, err)
	local msg = type(decoded) == "table" and decoded.message or nil
	return https.peer_text(msg ~= nil and msg or err or "no reason given", offers.REASON_MAX)
end

-- One PUT /behavior; then(outcome, why) with outcome "ok", "refused" (the
-- box answered 4xx: nothing changed, SB20), "not sent" (the client refused
-- it) or "unknown" (no answer or a 5xx: it may have landed).
function offers:put(values, after)
	local body = offers.body(values)
	local gen = self.gen
	self.busy = true
	local ok, err = pcall(self.client.put, self.client, offers.PATH, body, function(okp, status, decoded, perr)
		if gen ~= self.gen then
			return
		end
		self.busy = false
		local code = num.int(status, 100, 599)
		if okp then
			return after("ok")
		end
		if code and code >= 400 and code < 500 then
			return after("refused", reason_of(decoded, perr))
		end
		if code == nil and NOT_SENT[tostring(perr)] then
			return after("not sent", tostring(perr))
		end
		return after("unknown", code and ("HTTP " .. code) or https.peer_text(perr or "no answer", offers.REASON_MAX))
	end)
	if not ok then
		self.busy = false
		self.log.warn("Sync box: the input switching write could not be sent: %s", tostring(err))
		after("not sent", "the request could not be made")
	end
end

function offers:soon()
	if self.poller and self.poller.soon then
		pcall(self.poller.soon, self.poller, "command")
	end
end

function offers:let_control4(done)
	local list = offers.settings(self.model)
	local id = type(self.model) == "table" and self.model.id or nil
	if not list or not id then
		return self:say(done, false, "Not changed: the box's settings have not been read yet; try again in a moment")
	end
	local on = keys_of(list, function(s) return s.on end)
	if #on == 0 then
		return self:say(done, true, "Nothing to change: the box already leaves the inputs to Control4 (no HDMI CEC or "
			.. "hot-plug switching, no auto-sync, no power save when the TV turns off)")
	end
	-- Record first: an answer that never comes must not lose the box's values.
	local before = self:load()
	local rec = copy_record(self:own_record()) or { v = offers.VERSION, box_id = id, values = {} }
	rec.at = num.int(self.now(), 0)
	local values = {}
	for _, key in ipairs(on) do
		if rec.values[key] == nil then
			rec.values[key] = 1
		end
		values[key] = 0
	end
	self:save(rec)
	local words = offers.describe(on)
	self.log.info("Sync box: Let Control4 choose inputs: turning off %s", words)
	self:put(values, function(outcome, why)
		if outcome == "ok" then
			self:soon()
			return self:say(done, true, string.format("Sent: the box no longer does %s by itself; Control4 chooses its "
				.. "inputs (Sync Box Settings: %s puts it back)", words, offers.LABEL_RESTORE))
		end
		if outcome == "refused" or outcome == "not sent" then
			self:save(before and copy_record(before) or nil)
			return self:say(done, false, string.format("Not changed: %s (%s)", outcome == "refused"
				and "the box refused the change" or "nothing was sent to the box", why))
		end
		self:soon()
		self:say(done, false, string.format("Not confirmed: the box did not answer (%s); the Input Switching row shows "
			.. "what it does after the next read", why))
	end)
end

function offers:restore(done)
	local differ, missing = self:restorable()
	if not differ then
		return self:say(done, false, "Nothing to restore: " .. offers.LABEL_LET .. " has not changed this box")
	end
	local skipped = #missing > 0 and string.format(" (not on the box any more: %s)", offers.describe(missing)) or ""
	if #differ == 0 then
		self:save(nil)
		return self:say(done, true, "Nothing to put back: the box already has its own input switching" .. skipped)
	end
	local rec = self:own_record()
	local values = {}
	for _, key in ipairs(differ) do
		values[key] = rec.values[key]
	end
	local words = offers.describe(differ)
	self.log.info("Sync box: Restore the box's input switching: %s", words)
	self:put(values, function(outcome, why)
		if outcome == "ok" then
			self:save(nil)
			self:soon()
			return self:say(done, true, "Restored the box's own " .. words .. skipped)
		end
		if outcome == "unknown" then
			self:soon()
			return self:say(done, false, string.format("Not confirmed: the box did not answer (%s); Restore can be run "
				.. "again", why))
		end
		self:say(done, false, string.format("Not restored: %s (%s)", outcome == "refused" and "the box refused the change"
			or "nothing was sent to the box", why))
	end)
end

function offers:choose(value, done)
	if value ~= offers.OFFER_LET and value ~= offers.OFFER_RESTORE then
		return false
	end
	if self.busy then
		self:say(done, false, "Not changed: the last Sync Box Settings change is still on its way to the box")
		return true
	end
	if value == offers.OFFER_LET then
		self:let_control4(done)
	else
		self:restore(done)
	end
	return true
end

function offers:stop()
	self.gen = self.gen + 1
	self.busy = false
end

return offers
