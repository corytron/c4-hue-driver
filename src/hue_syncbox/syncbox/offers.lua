-- The Sync Box Settings offers of the Hue Sync Box driver (2.0 beta stage 4,
-- #568; docs/hdmi-sync-stage4-design.md §1.4 and §5, design
-- docs/hdmi-sync-design.md §5.4 and §5.8, contracts C1.4, C1.5 and C2 in
-- docs/hdmi-sync-contracts.md, owner's answers O4, O17 and O18): what the box
-- does by itself is shown, put on Attention while it switches inputs and
-- Control4 routes through it, and turned off or put back only by a click;
-- the box's wiring setting (in line, behind a receiver, on a receiver's
-- second output) is shown by the driver's Wiring row and changed only by a
-- click here too.
--
--   local o = offers.new{ client, poller, persist_get, persist_set,
--                         persist_delete, now, log }
--   o:observe(model)     every good read (syncbox/state.lua's model)
--   o:choices()          → { { text, value } }: the Sync Box Settings items:
--                        OFFER_LET and OFFER_RESTORE always; then each
--                        wiring the box can be set to and is not in now
--                        (OFFER_WIRING[w], in WIRINGS' order); then
--                        OFFER_WIRING_RESTORE while a wiring change of ours
--                        can be put back
--   o:choose(value, done) → true when `value` is one of them (else false,
--                        done not called); done(ok, text) once, `text` for
--                        Last Action. One PUT /behavior at most
--   o:row()              → the Input Switching row (contracts C1.4)
--   o:attention(routed)  → a text while the box switches inputs by itself
--                        and Control4 routes through it (`routed` false: nil)
--   o:record([kind])     → a copy of the recorded previous values, or nil;
--                        kind "inputs" (the default) or "wiring"
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
-- usbPowersave, inactivePowersave and hdrMode are never written: the first
-- two are no CEC behaviour and stay the box's (O18 names only CEC), the last
-- is a picture setting (edge cases §7).
--
-- The wiring (design 5.8, O17; docs/syncbox-wirings-research.md, W22): the
-- box's arcBypassMode and soloMode (SB62, SB64; soloMode from API level 14),
-- read as syncbox/state.lua does (solo mode first, then ARC bypass, else in
-- line). Each choice sets the keys the box has:
--   wiring:in_line          arcBypassMode 0, soloMode 0
--   wiring:behind_receiver  arcBypassMode 1, soloMode 0 (needs arcBypassMode)
--   wiring:second_output    soloMode 1, arcBypassMode 0 (needs soloMode)
-- offered only when the box is in another wiring and has the key it needs;
-- only the keys that differ are sent. Its Last Action says what the box now
-- does and how Control4's connections must match the cables (the manual's
-- wiring section, wirings research §7.3). It is recorded and put back as the
-- input switching is, in its own record (WIRING_KEY), by its own Restore
-- (OFFER_WIRING_RESTORE): the input switching's Restore never moves the
-- wiring, nor the wiring's the input switching. A second wiring click keeps
-- the values recorded first, so its Restore goes back to the wiring the box
-- had before Control4 first changed it.
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
-- Each record is persisted plain (no secret in it), under KEY for the input
-- switching and WIRING_KEY for the wiring: { v, box_id, at, values = {
-- ["cecPowersave"] = 1, ["input1.cecInputSwitch"] = 1, ... } } [verified:
-- SDK docs-driverworks-api 26.5_persistence/_4-PersistSetValue.md: a table
-- value, nested tables allowed]. PersistSetValue is called without
-- the encrypted argument: the flag goes only when true, and an explicit nil
-- raises on the controller (syncbox/store.lua, #547). PersistGetValue may lag
-- a write made moments before (same page), so the record is read from the
-- storage only once a run and kept in memory. One PUT of ours is out at a
-- time, whichever offer sent it.
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
offers.WIRING_KEY = "syncbox_wiring_offer"
offers.OFFER_WIRING_RESTORE = "wiring:restore"
offers.LABEL_WIRING_RESTORE = "Restore the box's wiring"
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

-- The wirings (design 5.8): the values each sets, the key it needs, and what
-- the box then does with Control4's connections.
offers.WIRING_ORDER = { "in_line", "behind_receiver", "second_output" }
offers.WIRINGS = {
	in_line = {
		name = "In line",
		values = { arcBypassMode = 0, soloMode = 0 },
		does = "Director switches it to each source's HDMI input",
		connect = "connect each source to its HDMI input on the box and the box's HDMI Out to the TV or receiver",
	},
	behind_receiver = {
		name = "Behind a receiver",
		values = { arcBypassMode = 1, soloMode = 0 },
		needs = "arcBypassMode",
		does = "every source reaches it from the receiver on HDMI 1",
		connect = "connect the receiver's HDMI output to the box's HDMI 1 and the box's HDMI Out to the TV",
	},
	second_output = {
		name = "From a receiver's second output",
		values = { soloMode = 1, arcBypassMode = 0 },
		needs = "soloMode",
		does = "it follows a room (Follow Room) and Director routes nothing through it",
		connect = "connect the receiver's second HDMI output to the box's HDMI 1 if its driver offers one, and never "
			.. "connect the box's HDMI Out",
	},
}
offers.OFFER_WIRING = {}
for _, w in ipairs(offers.WIRING_ORDER) do
	offers.OFFER_WIRING[w] = "wiring:" .. w
end
-- The wiring keys: the box's name and the model's (syncbox/state.lua).
offers.WIRING_FIELDS = { { key = "arcBypassMode", field = "arc_bypass" }, { key = "soloMode", field = "solo" } }

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

-- Per kind of record: its storage key and the keys it may hold.
local RECORDS = {
	inputs = { key = offers.KEY, known = KNOWN_KEYS, what = "input switching settings" },
	wiring = { key = offers.WIRING_KEY, known = { arcBypassMode = true, soloMode = true }, what = "wiring" },
}

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
		recs = {},       -- kind -> the record in memory (false: none)
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

-- The wiring keys the box has in `model`: { { key, on } }; nil when the read
-- carried no behavior.
function offers.wiring_settings(model)
	local b = type(model) == "table" and type(model.behavior) == "table" and model.behavior or nil
	if not b then
		return nil
	end
	local out = {}
	for _, s in ipairs(offers.WIRING_FIELDS) do
		if b[s.field] ~= nil then
			out[#out + 1] = { key = s.key, kind = s.key, on = b[s.field] == true }
		end
	end
	return out
end

local function settings_of(kind, model)
	if kind == "wiring" then
		return offers.wiring_settings(model)
	end
	return offers.settings(model)
end

-- The wiring the flags make, as syncbox/state.lua reads them.
local function wiring_of(flags)
	if flags.soloMode == 1 then
		return "second_output"
	elseif flags.arcBypassMode == 1 then
		return "behind_receiver"
	end
	return "in_line"
end

-- "ARC bypass and solo mode off", "ARC bypass on, solo mode off": what a
-- wiring sets, for the keys `have` holds.
local function flags_text(w, have)
	local v = offers.WIRINGS[w].values
	local arc, solo = have.arcBypassMode ~= nil, have.soloMode ~= nil
	if w == "in_line" then
		return arc and solo and "ARC bypass and solo mode off" or arc and "ARC bypass off" or "solo mode off"
	end
	local parts = {}
	for _, s in ipairs(w == "second_output" and { "soloMode", "arcBypassMode" } or { "arcBypassMode", "soloMode" }) do
		if have[s] ~= nil then
			parts[#parts + 1] = (s == "soloMode" and "solo mode " or "ARC bypass ") .. (v[s] == 1 and "on" or "off")
		end
	end
	return table.concat(parts, ", ")
end

local function by_key(list)
	local out = {}
	for _, s in ipairs(list or {}) do
		out[s.key] = s
	end
	return out
end

-- { [key] = 0 | 1 } of the settings `list` holds.
local function flags_of(list)
	local out = {}
	for _, s in ipairs(list or {}) do
		out[s.key] = s.on and 1 or 0
	end
	return out
end

-- "ARC bypass, solo mode": the wiring keys in words.
local function wiring_keys_text(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = key == "soloMode" and "solo mode" or "ARC bypass"
	end
	return table.concat(parts, ", ")
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
local function check_record(r, known)
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
		if known[key] and flag ~= nil and num.finite(v) == flag then
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

function offers:load(kind)
	kind = kind or "inputs"
	local r = RECORDS[kind]
	if self.recs[kind] == nil then
		local ok, value = pcall(self.persist_get, r.key)
		local rec = ok and check_record(value, r.known) or nil
		if ok and value ~= nil and rec == nil then
			self.log.warn("Sync box: the recorded %s are not usable; Restore has nothing to put back", r.what)
		end
		self.recs[kind] = rec or false
	end
	return self.recs[kind] or nil
end

function offers:save(rec, kind)
	kind = kind or "inputs"
	local r = RECORDS[kind]
	self.recs[kind] = rec or false
	local ok, err
	if rec then
		ok, err = pcall(self.persist_set, r.key, copy_record(rec))
	else
		ok, err = pcall(self.persist_delete, r.key)
	end
	if not ok then
		self.log.warn("Sync box: could not store the %s: %s", r.what, tostring(err))
	end
end

function offers:record(kind)
	return copy_record(self:load(kind))
end

-- The record of the box read last, or nil.
function offers:own_record(kind)
	local rec = self:load(kind)
	local id = type(self.model) == "table" and self.model.id or nil
	if rec and id and rec.box_id == id then
		return rec
	end
	return nil
end

-- The recorded keys whose value differs from the box's now (the box has
-- them), and the recorded keys the box lacks now.
function offers:restorable(kind)
	local rec = self:own_record(kind)
	if not rec then
		return nil
	end
	local have = by_key(settings_of(kind, self.model))
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
	local out = {
		{ text = cap(let, 240), value = offers.OFFER_LET },
		{ text = cap(restore, 240), value = offers.OFFER_RESTORE },
	}
	local have = flags_of(offers.wiring_settings(self.model))
	for _, w in ipairs(offers.WIRING_ORDER) do
		if self:wiring_changes(w) then
			out[#out + 1] = { text = cap(string.format("Set the box to %s (%s)", offers.WIRINGS[w].name,
				flags_text(w, have)), 240), value = offers.OFFER_WIRING[w] }
		end
	end
	local back = self:restorable("wiring")
	if back and #back > 0 then
		out[#out + 1] = { text = cap(string.format("%s (back to %s)", offers.LABEL_WIRING_RESTORE,
			offers.WIRINGS[self:restored_wiring(back)].name), 240), value = offers.OFFER_WIRING_RESTORE }
	end
	return out
end

-- The changes setting wiring `w` makes on the box read last ({ [key] = {
-- from, to } }), or nil and why it is not offered: not read, the key it
-- needs missing, or the box already in that wiring.
function offers:wiring_changes(w)
	local list = offers.wiring_settings(self.model)
	if not list or not (type(self.model) == "table" and self.model.id) then
		return nil, "unread"
	end
	local have, def = flags_of(list), offers.WIRINGS[w]
	if def.needs and have[def.needs] == nil then
		return nil, "lacks"
	end
	if wiring_of(have) == w then
		return nil, "same"
	end
	local changes, any = {}, false
	for key, to in pairs(def.values) do
		if have[key] ~= nil and have[key] ~= to then
			changes[key] = { from = have[key], to = to }
			any = true
		end
	end
	if not any then
		return nil, "same"
	end
	return changes
end

-- The wiring the box would have with the recorded values of `keys` put back.
function offers:restored_wiring(keys)
	local flags = flags_of(offers.wiring_settings(self.model))
	local rec = self:own_record("wiring")
	for _, key in ipairs(keys) do
		flags[key] = rec and rec.values[key] or flags[key]
	end
	return wiring_of(flags)
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
	local changes = {}
	for _, key in ipairs(on) do
		changes[key] = { from = 1, to = 0 }
	end
	local words = offers.describe(on)
	self.log.info("Sync box: Let Control4 choose inputs: turning off %s", words)
	self:change("inputs", changes, done, string.format("Sent: the box no longer does %s by itself; Control4 chooses "
		.. "its inputs (Sync Box Settings: %s puts it back)", words, offers.LABEL_RESTORE), "the Input Switching row")
end

-- Record the values `changes` replaces ({ [key] = { from, to } }; a key
-- already recorded keeps the value recorded first), then send the `to`
-- values in one PUT. Record first: an answer that never comes must not lose
-- the box's values; a refusal changed nothing (SB20), so the record is
-- rolled back.
function offers:change(kind, changes, done, sent_text, row)
	local before = self:load(kind)
	local rec = copy_record(self:own_record(kind)) or { v = offers.VERSION, box_id = self.model.id, values = {} }
	rec.at = num.int(self.now(), 0)
	local values = {}
	for key, c in pairs(changes) do
		if rec.values[key] == nil then
			rec.values[key] = c.from
		end
		values[key] = c.to
	end
	self:save(rec, kind)
	self:put(values, function(outcome, why)
		if outcome == "ok" then
			self:soon()
			return self:say(done, true, sent_text)
		end
		if outcome == "refused" or outcome == "not sent" then
			self:save(before and copy_record(before) or nil, kind)
			return self:say(done, false, string.format("Not changed: %s (%s)", outcome == "refused"
				and "the box refused the change" or "nothing was sent to the box", why))
		end
		self:soon()
		self:say(done, false, string.format("Not confirmed: the box did not answer (%s); %s shows what it does after "
			.. "the next read", why, row))
	end)
end

-- What the box does in wiring `w`, and how Control4's connections must match.
local function wiring_words(w, have)
	local def = offers.WIRINGS[w]
	return string.format("the box is now %s (%s): %s. Control4's connections must match the cables: %s", def.name,
		flags_text(w, have), def.does, def.connect)
end

function offers:set_wiring(w, done)
	local changes, why = self:wiring_changes(w)
	local def = offers.WIRINGS[w]
	if why == "unread" then
		return self:say(done, false, "Not changed: the box's settings have not been read yet; try again in a moment")
	elseif why == "lacks" then
		return self:say(done, false, string.format("Not changed: this box has no %s setting, so it cannot be set to %s",
			wiring_keys_text({ def.needs }), def.name))
	elseif why == "same" then
		return self:say(done, true, string.format("Nothing to change: the box is already %s", def.name))
	end
	local have = flags_of(offers.wiring_settings(self.model))
	self.log.info("Sync box: setting the box's wiring to %s (%s)", def.name, flags_text(w, have))
	self:change("wiring", changes, done, string.format("Sent: %s (Sync Box Settings: %s puts it back)",
		wiring_words(w, have), offers.LABEL_WIRING_RESTORE), "the Wiring row")
end

-- The texts of each Restore.
local RESTORE_TEXTS = {
	inputs = {
		none = "Nothing to restore: " .. offers.LABEL_LET .. " has not changed this box",
		same = function() return "Nothing to put back: the box already has its own input switching" end,
		done = function(_, differ) return "Restored the box's own " .. offers.describe(differ) end,
		missing = offers.describe,
	},
	wiring = {
		none = "Nothing to restore: Sync Box Settings has not changed this box's wiring",
		same = function(self)
			return string.format("Nothing to put back: the box already has its own wiring (%s)",
				offers.WIRINGS[self:restored_wiring({})].name)
		end,
		done = function(self, differ)
			local w = self:restored_wiring(differ)
			local flags = flags_of(offers.wiring_settings(self.model))
			return "Restored the box's wiring: " .. wiring_words(w, flags)
		end,
		missing = wiring_keys_text,
	},
}

function offers:restore(done, kind)
	kind = kind or "inputs"
	local texts = RESTORE_TEXTS[kind]
	local differ, missing = self:restorable(kind)
	if not differ then
		return self:say(done, false, texts.none)
	end
	local skipped = #missing > 0 and string.format(" (not on the box any more: %s)", texts.missing(missing)) or ""
	if #differ == 0 then
		self:save(nil, kind)
		return self:say(done, true, texts.same(self) .. skipped)
	end
	local rec = self:own_record(kind)
	local values = {}
	for _, key in ipairs(differ) do
		values[key] = rec.values[key]
	end
	local done_text = texts.done(self, differ) .. skipped
	self.log.info("Sync box: %s", done_text)
	self:put(values, function(outcome, why)
		if outcome == "ok" then
			self:save(nil, kind)
			self:soon()
			return self:say(done, true, done_text)
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

-- value -> the wiring it sets.
local WIRING_OF_VALUE = {}
for w, v in pairs(offers.OFFER_WIRING) do
	WIRING_OF_VALUE[v] = w
end

function offers:choose(value, done)
	local w = WIRING_OF_VALUE[value]
	if value ~= offers.OFFER_LET and value ~= offers.OFFER_RESTORE and value ~= offers.OFFER_WIRING_RESTORE
		and not w then
		return false
	end
	if self.busy then
		self:say(done, false, "Not changed: the last Sync Box Settings change is still on its way to the box")
		return true
	end
	if value == offers.OFFER_LET then
		self:let_control4(done)
	elseif value == offers.OFFER_RESTORE then
		self:restore(done, "inputs")
	elseif value == offers.OFFER_WIRING_RESTORE then
		self:restore(done, "wiring")
	else
		self:set_wiring(w, done)
	end
	return true
end

function offers:stop()
	self.gen = self.gen + 1
	self.busy = false
end

return offers
