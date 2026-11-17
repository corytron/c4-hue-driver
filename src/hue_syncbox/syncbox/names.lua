-- The Hue Sync Box's name, two-way (2.0 beta stage 4, #568;
-- docs/hdmi-sync-stage4-design.md §1.7 and §5, design docs/hdmi-sync-design.md
-- §8, owner's answer O14; edge cases B22 and C3): renaming the device in
-- Composer renames the box, and a rename in the Hue Sync app renames the
-- device, with the rules and loop guards 1.2 decided for lights, scenes and
-- motion sensors (docs/simplify-actions-design.md D6, D11, §3.1;
-- docs/simplify-research-names-sync.md §5, cases N1 to N34 cited below;
-- src/hue_bridge/bridge/names.lua). Input names are only shown (O14), never
-- written.
--
--   local n = names.new{ client, poller, display_name, rename_device,
--                        persist_get, persist_set, timer, now, log, last_action }
--   n:observe(model)       every good read (syncbox/state.lua's model): the
--                          box's name now; runs the rule at the first read of
--                          a run, when the box's name changed, and when a
--                          write waits on a read (a local GetDeviceDisplayName
--                          then, never on every read)
--   n:on_composer_rename() OnSystemEvent's OnItemNameChanged for this
--                          device's proxy: the rule runs SETTLE_MS later
--   n:check()              the rule now, on the names as they are: the
--                          driver's periodic tick calls it, for a Composer
--                          rename whose event was missed (research §3.1);
--                          nothing happens before a read
--   n:choices()            → { { text, value } }: Sync Box Settings items while
--                          the names wait for a click (held), else none
--   n:choose(value, done)  → true when `value` is one of them (else false,
--                          done not called); done(ok, text) once, for Last
--                          Action
--   n:attention()          → a text while the names wait for a click, or nil
--   n:record()             → a copy of the stored pair, or nil
--   n:stop()               timers cancelled, a write's late answer ignored
--
-- deps:
--   client          syncbox/client.lua: c:put("/device", { name }, cb),
--                   cb(ok, status, decoded, err)
--   poller          syncbox/poller.lua (optional): p:soon("command") after a
--                   write, so the read that shows it comes at once
--   display_name()  → the device's name as Composer shows it: the AV switch
--                   proxy's (C4:GetDeviceDisplayName(proxy id) [verified: API
--                   32_serial_network_device/_6-GetDeviceDisplayName.md;
--                   docs/simplify-research-names-sync.md §3.1: Composer
--                   renames the proxy, not the protocol driver])
--   rename_device(name)  C4:RenameDevice(proxy id, name) [verified: API
--                   22_miscellaneous/_32-RenameDevice.md: proxy id, refreshes
--                   the project, never from OnDriverInit]. Called only from a
--                   read, a timer or a click, never from OnDriverInit
--   persist_get(key), persist_set(key, value)  default C4:PersistGetValue and
--                   C4:PersistSetValue, the pair stored plain (no encrypted
--                   argument, as syncbox/store.lua)
--   timer(ms, fn) → handle with Cancel (default C4:SetTimer); now() → ms
--   last_action(text)  optional: what an automatic rename did, and why a
--                   pair waits
--
-- The pair (one persisted key, KEY): { v, box_id, h, c, held, why, want,
-- side, max }: h and c the names both sides last agreed on (h as the box has
-- it, c as Composer shows it); held why the pair waits for a click ("first",
-- "refused", "loop"), with the reason and the name refused (side "device"
-- when Control4 refused a RenameDevice, else the box refused); max the
-- longest name the box reported (it takes at least that many bytes). Keyed
-- by the box id: a pair of another box (a replaced box, B7) is a first look.
-- In memory only: the echo windows, the loop breaker's write times, the
-- write in flight.
--
-- The rule (research §5.1), with H the box's name now and C the device's:
--   neither changed               nothing
--   C changed (N1)                PUT /device { name = C }; the pair moves
--                                 once the box answered
--   H changed (N2, B22)           RenameDevice(H); the pair moves before the
--                                 call, so its echo compares equal (N6)
--   both changed (N3)             H agrees with C: the pair moves; else
--                                 Control4 wins: PUT C, and Last Action names
--                                 the box's name it replaced
-- No pair yet (the first read after pairing, or after this build's install;
-- N19, N20, D11): names that agree are paired silently; names that differ
-- wait, offered in Sync Box Settings ("Name the box after this device",
-- "Name this device after the box"), never synced by themselves. A Composer
-- rename before that first look sends its name (N17 + N1: a person's act).
-- A held pair syncs nothing, except that a Composer rename resolves it,
-- Control4 winning (Q8); a box rename then only changes the Sync Box row
-- (the driver's); names made to agree end the hold by themselves.
--
-- Guards:
--   - N5, N6, N7: the first read after our PUT, and the first Composer name
--     after our RenameDevice, within ECHO_MS, is that write's echo whatever
--     its text (the box or Composer may trim it): taken, never answered.
--   - N7: more than LOOP_MAX automatic writes in LOOP_WINDOW_MS hold the
--     pair ("loop"); a click is never counted.
--   - N9 for one device: a RenameDevice at most once per RENAME_GAP_MS.
--   - N4, N25, Q3: an empty name, or one longer than the box takes, is never
--     sent and never cut by itself: the pair waits ("refused") and Sync Box
--     Settings offers the name cut to the limit. The box's limit is not
--     published: BOX_MAX_BYTES is [assumed] 32 bytes of UTF-8, the limit
--     Hue's bridge enforces (docs/simplify-actions-design.md §2.3, verified on
--     the house) and the one the registration's instanceName is cut to
--     (stage 2 §3.4); a box that has reported a longer name takes at least
--     that, and the box's own refusal (code 15, SB110) is handled the same.
--   - N11: a write that got no answer changes nothing in the pair; the next
--     read finds the difference again and sends it then.
--   - A box with no name, or a device whose name cannot be read, syncs
--     nothing: a device is never renamed to nothing.
--
-- DriverWorks calls: only the defaults named above.

local https = require("common.https")
local num = require("common.num")

local names = {}
names.__index = names

names.KEY = "syncbox_name_pair"
names.VERSION = 1
names.PATH = "/device"
names.BOX_MAX_BYTES = 32          -- [assumed]; see the header
names.SEEN_MAX = 64               -- syncbox/state.lua's NAME_MAX: the longest name a read carries
names.STORE_MAX = 256             -- bytes of a name kept in the pair
names.SETTLE_MS = 1000            -- a Composer rename's events coalesce
names.RENAME_GAP_MS = 2000        -- each RenameDevice refreshes the project
names.ECHO_MS = 10000
names.LOOP_WINDOW_MS = 600000
names.LOOP_MAX = 3
names.TEXT_MAX = 400
names.REASON_MAX = 120
names.OFFER_TO_BOX = "name:to_box"
names.OFFER_CUT = "name:cut"
names.OFFER_TO_DEVICE = "name:to_device"

local HELD = { first = true, refused = true, loop = true }

-- The client's own refusals: nothing reached the box (syncbox/client.lua).
local NOT_SENT = { ["not paired"] = true, ["no box address"] = true, busy = true,
	["invalid request path"] = true }

-- A name as both sides compare it: no control characters, no blanks at the
-- ends (N24: the cleaning is idempotent, so it cannot loop).
function names.clean(s)
	if type(s) ~= "string" then
		return ""
	end
	return (s:gsub("%c", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- UTF-8 characters of `s`: its bytes that start one.
local function chars(s)
	local n = 0
	for i = 1, #s do
		local b = s:byte(i)
		if b < 0x80 or b > 0xBF then
			n = n + 1
		end
	end
	return n
end

-- The longest prefix of `s` within `max` bytes that ends before a character,
-- trailing blanks trimmed.
function names.cut(s, max)
	s = names.clean(s)
	if #s <= max then
		return s
	end
	local cut = max
	while cut > 0 do
		local b = s:byte(cut + 1)
		if not (b and b >= 0x80 and b <= 0xBF) then
			break
		end
		cut = cut - 1
	end
	return names.clean(s:sub(1, cut))
end

-- Why the box cannot hold `name` (at most `max` bytes), or nil.
function names.too_long(name, max)
	if #name <= max then
		return nil
	end
	local n = chars(name)
	if n == #name then
		return string.format("%d characters, the box takes %d", n, max)
	end
	return string.format("%d bytes, the box takes %d (accented letters count twice)", #name, max)
end

local function default_get(name)
	return C4:PersistGetValue(name)
end

local function default_set(name, value)
	return C4:PersistSetValue(name, value)
end

local function default_timer(ms, fn)
	return C4:SetTimer(ms, function() fn() end)
end

local function default_now()
	local ok, ms = pcall(C4.GetTime, C4)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

function names.new(deps)
	deps = deps or {}
	return setmetatable({
		client = deps.client,
		poller = deps.poller,
		display_name = deps.display_name or function() return nil end,
		rename_device = deps.rename_device or function() error("no rename_device given") end,
		persist_get = deps.persist_get or default_get,
		persist_set = deps.persist_set or default_set,
		timer = deps.timer or default_timer,
		now = deps.now or default_now,
		log = deps.log or require("common.log"),
		last_action = deps.last_action,
		pair = nil,          -- the stored pair (false: none)
		H = nil,             -- the box's name of the last read
		box_id = nil,        -- the box id of the last read
		ready = false,       -- a read came this run
		explicit = false,    -- a Composer rename event since the last pass
		inflight = nil,      -- the PUT out: { target, c, reason, was, click, done }
		retry = false,       -- a PUT got no answer: the next read runs the rule
		echo_h = nil,        -- ms until which a read is our PUT's echo
		echo_c = nil,        -- ms until which Composer's name is our RenameDevice's echo
		writes = {},         -- the times of automatic writes (N7)
		last_rename = nil,
		timers = {},
		gen = 0,
	}, names)
end

-- The pair -------------------------------------------------------------------------

local function text_of(v, max)
	if type(v) ~= "string" then
		return nil
	end
	return https.peer_text(v, max or names.STORE_MAX)
end

local function check_pair(p)
	if type(p) ~= "table" or p.v ~= names.VERSION then
		return nil
	end
	local id = type(p.box_id) == "string" and #p.box_id == 12 and not p.box_id:find("%X") and p.box_id:upper()
	local h, c = text_of(p.h), text_of(p.c)
	if not (id and h and c) then
		return nil
	end
	local held = HELD[p.held] and p.held or nil
	return { v = names.VERSION, box_id = id, h = h, c = c, held = held,
		why = held and text_of(p.why, names.REASON_MAX) or nil, want = held and text_of(p.want) or nil,
		side = held == "refused" and p.side == "device" and "device" or nil, max = num.int(p.max, 0, names.SEEN_MAX) }
end

local function copy_pair(p)
	if not p then
		return nil
	end
	return { v = p.v, box_id = p.box_id, h = p.h, c = p.c, held = p.held, why = p.why, want = p.want, side = p.side,
		max = p.max }
end

function names:load()
	if self.pair == nil then
		local ok, value = pcall(self.persist_get, names.KEY)
		local p = ok and check_pair(value) or nil
		if ok and value ~= nil and p == nil then
			self.log.warn("Sync box: the stored names are not usable; the next read compares the names afresh")
		end
		self.pair = p or false
	end
	return self.pair or nil
end

function names:store(p)
	self.pair = p or false
	local ok, err = pcall(self.persist_set, names.KEY, copy_pair(p))
	if not ok then
		self.log.warn("Sync box: could not store the names: %s", tostring(err))
	end
end

function names:record()
	return copy_pair(self:load())
end

-- The most bytes the box takes: BOX_MAX_BYTES, or the longest name it reported.
function names:limit()
	local p = self:load()
	local seen = p and p.box_id == self.box_id and p.max or 0
	return math.max(names.BOX_MAX_BYTES, seen or 0, self.H and #self.H or 0)
end

-- Helpers ---------------------------------------------------------------------------

function names:say(text)
	text = https.peer_text(text, names.TEXT_MAX)
	self.log.info("Sync box: %s", text)
	if self.last_action then
		local ok, err = pcall(self.last_action, text)
		if not ok then
			self.log.warn("Sync box: Last Action failed: %s", tostring(err))
		end
	end
	return text
end

function names:answer(done, ok, text)
	if done then
		local okc, err = pcall(done, ok, https.peer_text(text, names.TEXT_MAX))
		if not okc then
			self.log.warn("Sync box: the name's answer failed: %s", tostring(err))
		end
	end
end

function names:arm(key, ms, fn)
	if self.timers[key] then
		pcall(self.timers[key].Cancel, self.timers[key])
	end
	local gen = self.gen
	local ok, handle = pcall(self.timer, ms, function()
		self.timers[key] = nil
		if gen == self.gen then
			fn()
		end
	end)
	self.timers[key] = ok and handle or nil
end

function names:composer()
	local ok, name = pcall(self.display_name)
	return ok and names.clean(name) or ""
end

-- N7's loop breaker: one more automatic write would make more than LOOP_MAX
-- in LOOP_WINDOW_MS.
function names:looping()
	local now, kept = self.now(), {}
	for _, t in ipairs(self.writes) do
		if now - t < names.LOOP_WINDOW_MS then
			kept[#kept + 1] = t
		end
	end
	self.writes = kept
	return #kept >= names.LOOP_MAX
end

function names:wrote(click)
	if not click then
		self.writes[#self.writes + 1] = self.now()
	end
end

function names:seed(h, c, how)
	local p = self:load()
	local max = math.max(p and p.box_id == self.box_id and p.max or 0, #(self.H or ""))
	local new = { v = names.VERSION, box_id = self.box_id, h = h, c = c, max = math.min(max, names.SEEN_MAX) }
	if p and p.box_id == new.box_id and p.h == h and p.c == c and not p.held and p.max == new.max then
		return
	end
	self:store(new)
	self.log.debug("Sync box: names paired%s: box %q, Composer %q", how and (" (" .. how .. ")") or "", h, c)
end

local HOLD_TEXTS = {
	first = "The box is named %s and this device %s: Sync Box Settings offers either name, and a rename in "
		.. "Composer sends its name to the box",
	loop = "The names of the box (%s) and of this device (%s) keep changing; their sync is paused (Sync Box "
		.. "Settings offers either name)",
}

function names:hold(why, h, c, extra)
	extra = extra or {}
	local p = self:load()
	local max = math.max(p and p.box_id == self.box_id and p.max or 0, #(self.H or ""))
	self:store({ v = names.VERSION, box_id = self.box_id, h = h, c = c, held = why, why = extra.why,
		want = extra.want, side = extra.side, max = math.min(max, names.SEEN_MAX) })
	if why == "refused" and extra.side == "device" then
		return self:say(string.format("This device was not renamed %s (%s); Sync Box Settings offers the names",
			extra.want, extra.why or "refused"))
	elseif why == "refused" then
		return self:say(string.format("Name not sent to the box: %s (%s); Sync Box Settings offers the names",
			extra.want ~= "" and extra.want or "an empty name", extra.why or "refused"))
	end
	return self:say(string.format(HOLD_TEXTS[why], h, c))
end

-- The writes -------------------------------------------------------------------------

-- PUT /device { name = target }; opts: c (the Composer name it comes from),
-- reason ("composer", "both", "click"), was (the box's name it replaces),
-- click, done.
function names:push(target, opts)
	local H, C = self.H, self:composer()
	if target == "" then
		local text = self:hold("refused", H, C, { why = "an empty name", want = "" })
		return self:answer(opts.done, false, text)
	end
	local long = names.too_long(target, self:limit())
	if long then
		local text = self:hold("refused", H, C, { why = long, want = target })
		return self:answer(opts.done, false, text)
	end
	if not opts.click and self:looping() then
		return self:hold("loop", H, C)
	end
	if not (self.client and self.client.put) then
		return self:answer(opts.done, false, "Not sent: the box's client is not ready")
	end
	local job = { target = target, c = opts.c or target, reason = opts.reason, was = opts.was, click = opts.click,
		done = opts.done }
	self.inflight = job
	local gen = self.gen
	self.log.info("Sync box: sending the name %q to the box", target)
	local ok, err = pcall(self.client.put, self.client, names.PATH, { name = target },
		function(okp, status, decoded, perr)
			if gen ~= self.gen then
				return
			end
			self.inflight = nil
			self:landed(job, okp, status, decoded, perr)
		end)
	if not ok then
		self.inflight = nil
		self.log.warn("Sync box: the name could not be sent: %s", tostring(err))
		self:answer(job.done, false, "Not sent: the request could not be made")
	end
end

function names:landed(job, ok, status, decoded, err)
	local code = num.int(status, 100, 599)
	if ok then
		self:wrote(job.click)
		-- The box took it (SB11): its name is the one sent until a read says
		-- otherwise (within ECHO_MS, that read is the echo).
		self.H = job.target
		self.echo_h = self.now() + names.ECHO_MS
		self:seed(job.target, job.c, "sent")
		if self.poller and self.poller.soon then
			pcall(self.poller.soon, self.poller, "command")
		end
		local text
		if job.reason == "both" then
			text = string.format("Both renamed: kept the Composer name %s and sent it to the box (the box had %s)",
				job.c, tostring(job.was))
		elseif job.click then
			text = "Named the box " .. job.target
		else
			text = string.format("Name sent to the box: %s (was %s)", job.target, tostring(job.was))
		end
		self:answer(job.done, true, self:say(text))
		-- A rename that came meanwhile goes next.
		return self:arm("pass", 1, function() self:pass("after") end)
	end
	if code and code >= 400 and code < 500 then
		local msg = type(decoded) == "table" and decoded.message or nil
		local why = https.peer_text(msg ~= nil and ("the box refused it: " .. tostring(msg)) or (err or "refused"),
			names.REASON_MAX)
		local text = self:hold("refused", self.H, self:composer(), { why = why, want = job.target })
		return self:answer(job.done, false, text)
	end
	-- N11: no answer (or nothing sent). The pair is unchanged, so the next
	-- read finds the difference again.
	self.retry = true
	local why = code and ("HTTP " .. code) or https.peer_text(err or "no answer", names.REASON_MAX)
	self.log.info("Sync box: the name %q waits for the box (%s)", job.target, why)
	self:answer(job.done, false, string.format("Not confirmed: the box did not take the name %s (%s)%s", job.target,
		why, NOT_SENT[tostring(err)] and "" or "; the next read shows whether it did"))
end

-- RenameDevice(to); the pair moves before the call (N6).
function names:rename(to, h, was, click, done)
	if to == "" then
		return self:answer(done, false, "Not renamed: the box has no name")
	end
	local now = self.now()
	if not click then
		if self.last_rename and now - self.last_rename < names.RENAME_GAP_MS then
			return self:arm("pass", self.last_rename + names.RENAME_GAP_MS - now, function() self:pass("paced") end)
		end
		if self:looping() then
			return self:hold("loop", h, self:composer())
		end
	end
	local before = copy_pair(self:load())
	self:seed(h, to, "renamed")
	self.echo_c = now + names.ECHO_MS
	self.last_rename = now
	local ok, err = pcall(self.rename_device, to)
	if not ok then
		self.echo_c = nil
		self:store(before)
		local text = self:hold("refused", h, self:composer(), { want = to, side = "device",
			why = https.peer_text(err, names.REASON_MAX) })
		return self:answer(done, false, text)
	end
	self:wrote(click)
	local text = click and ("Named this device " .. to) or string.format("Name taken from the box: %s (was %s)", to,
		was)
	self:answer(done, true, self:say(text))
end

-- The rule -----------------------------------------------------------------------------

-- source: "box" (a read), "composer" (a rename event), or anything else.
function names:pass(source)
	if not self.ready or self.inflight then
		return
	end
	local H, C = self.H, self:composer()
	if not H or H == "" or C == "" then
		return
	end
	local explicit = self.explicit
	self.explicit = false
	local p = self:load()
	if not p or p.box_id ~= self.box_id then
		if names.clean(H) == C then
			return self:seed(H, C, "first look")
		end
		if explicit then
			return self:push(C, { c = C, reason = "composer", was = H })
		end
		return self:hold("first", H, C)
	end
	if #H > (p.max or 0) and #H <= names.SEEN_MAX then
		p.max = #H
		self:store(p)
	end
	if p.held then
		if names.clean(H) == C then
			return self:seed(H, C, "made to agree")
		end
		if explicit and C ~= p.c then
			-- Q8: a Composer rename resolves a held pair, Control4 winning.
			return self:push(C, { c = C, reason = "composer", was = H })
		end
		return
	end
	-- N5 to N7: the first answer from a side within the window after our own
	-- write there is its echo, whatever its text.
	local now = self.now()
	if self.echo_h and (now >= self.echo_h or source == "box") then
		local live = now < self.echo_h
		self.echo_h = nil
		if live and H ~= p.h then
			return self:seed(H, p.c, "box echo")
		end
	end
	if self.echo_c and (now >= self.echo_c or source == "composer" or C ~= p.c) then
		local live = now < self.echo_c
		self.echo_c = nil
		if live and C ~= p.c then
			return self:seed(p.h, C, "Composer echo")
		end
	end
	local c_changed, h_changed = C ~= p.c, H ~= p.h
	if not c_changed and not h_changed then
		return
	end
	if c_changed and not h_changed then
		if C == names.clean(p.h) then
			return self:seed(p.h, C)
		end
		return self:push(C, { c = C, reason = "composer", was = p.h })
	end
	local to = names.clean(H)
	if to == C then
		return self:seed(H, C)
	end
	if not c_changed then
		return self:rename(to, H, C)
	end
	-- N3: both renamed: Control4 wins.
	return self:push(C, { c = C, reason = "both", was = H })
end

-- The surface -----------------------------------------------------------------------------

function names:observe(model)
	if type(model) ~= "table" then
		return
	end
	local H = type(model.name) == "string" and model.name or nil
	local id = model.id or self.box_id
	local fresh = not self.ready or H ~= self.H or id ~= self.box_id
	self.box_id, self.H = id, H
	self.ready = self.box_id ~= nil
	-- The rule runs when the box's side changed, or something waits on a
	-- read; the Composer side has its event (and n:check()).
	if fresh or self.retry or self.echo_h or self.explicit then
		self.retry = false
		self:pass("box")
	end
end

function names:on_composer_rename()
	self.explicit = true
	self:arm("pass", names.SETTLE_MS, function() self:pass("composer") end)
end

function names:check()
	self:pass("check")
end

-- The pair waiting for a click, or nil.
function names:held()
	local p = self:load()
	if self.ready and p and p.box_id == self.box_id and p.held then
		return p
	end
	return nil
end

function names:choices()
	if not self:held() then
		return {}
	end
	local out = {}
	local C, H = self:composer(), names.clean(self.H)
	if C ~= "" then
		local limit = self:limit()
		if names.too_long(C, limit) then
			out[#out + 1] = { text = https.peer_text(string.format("Name the box after this device, cut to %d bytes "
				.. "(%s)", limit, names.cut(C, limit)), 240), value = names.OFFER_CUT }
		else
			out[#out + 1] = { text = https.peer_text(string.format("Name the box after this device (%s)", C), 240),
				value = names.OFFER_TO_BOX }
		end
	end
	if H ~= "" then
		out[#out + 1] = { text = https.peer_text(string.format("Name this device after the box (%s)", H), 240),
			value = names.OFFER_TO_DEVICE }
	end
	return out
end

function names:choose(value, done)
	if value ~= names.OFFER_TO_BOX and value ~= names.OFFER_CUT and value ~= names.OFFER_TO_DEVICE then
		return false
	end
	if self.inflight then
		self:answer(done, false, "Not changed: the last name is still on its way to the box")
		return true
	end
	if not self:held() then
		self:answer(done, false, self.ready and "Nothing to do: the box and this device keep one name"
			or "Not changed: the box has not been read yet")
		return true
	end
	local C, H = self:composer(), self.H
	if value == names.OFFER_TO_DEVICE then
		self:rename(names.clean(H), H, C, true, done)
	elseif value == names.OFFER_CUT then
		self:push(names.cut(C, self:limit()), { c = C, reason = "click", was = H, click = true, done = done })
	else
		self:push(C, { c = C, reason = "click", was = H, click = true, done = done })
	end
	return true
end

function names:attention()
	local p = self:held()
	if not p then
		return nil
	end
	local text
	if p.held == "refused" and p.side == "device" then
		text = string.format("This device was not renamed %s (%s): Sync Box Settings offers the names", p.want,
			p.why or "refused")
	elseif p.held == "refused" then
		text = string.format("The box did not take the name %s (%s): Sync Box Settings offers the names",
			p.want ~= "" and p.want or "(empty)", p.why or "refused")
	elseif p.held == "loop" then
		text = "The names of the box and of this device keep changing; their sync is paused (Sync Box Settings)"
	else
		text = string.format("The box (%s) and this device (%s) have different names: Sync Box Settings offers "
			.. "either", p.h, p.c)
	end
	return https.peer_text(text, names.TEXT_MAX)
end

function names:stop()
	self.gen = self.gen + 1
	self.inflight = nil
	for key, t in pairs(self.timers) do
		pcall(t.Cancel, t)
		self.timers[key] = nil
	end
end

return names
