-- Two-way names between Composer and the Hue bridge (#334, owner's answers
-- D6 and D11): a rename in Composer renames the light, scene, motion sensor
-- or MotionAware area on the bridge, a rename in Hue renames the Control4
-- device, and the two never drift. Rooms and zone lights stay out (their Hue
-- thing is a room or zone; Resolve Names lists their differences).
--
-- Contract: docs/simplify-actions-design.md §3.1 and §3.4; the rules are
-- docs/simplify-research-names-sync.md §5 (cases N1 to N34 cited below), as
-- the house's dev build amended them (§2.3: Hue takes 32 bytes of UTF-8; a
-- duplicate scene name in a room is accepted; an area takes a name).
--
--   local n = names.new(ctx)
--   n:migrate(build)                    at late init: the first run of 1.2 (N19)
--   n:pass(kind)                        after each module's successful resync
--   n:on_hue_name(kind, rid)            a module took a new Hue name from an event
--   n:on_composer_rename(proxy_id)      OnSystemEvent OnItemNameChanged
--   n:relinked(kind, old_rid, new_rid)  -> a text for the re-link's Last Action, or nil (N16)
--   n:forgotten(kind, rid)              forgotten, deleted in Composer, tombstoned
--   n:resolve_rows() -> { { text, value } }   Resolve Names' list
--   n:resolve(value, done)              done(ok, text) once its writes are answered
--   n:attention() -> { text }           what needs a person
--   n:added(kind, rid, hue_name)        a device created for it (N17: the pair starts fresh)
--   n:adopt_all(kind), names.accept_text()  the hidden aliases of Adopt Hue Names and Accept Names
--   names.put_via(registries, request)  a put_name built on a bridge request function
--
-- ctx (names.lua makes no HTTP and no C4 call of its own):
--   persist_get(key), persist_set(key, value)   the store (or store = { get, set })
--   registries = { light = lights, scene = scenes, motion = motion [, zone_light = zone_lights] }
--   put_name(kind, rid, name, done(ok, err, code))   the bridge write; code 400 = Hue refused it
--   rename_device(proxy_id, name)        C4:RenameDevice, never from OnDriverInit
--   display_name(id) -> name             C4:GetDeviceDisplayName (the proxy's: what Composer shows)
--   proxy_of(device_id) -> id|nil        optional: the proxy of an entry that has none
--                                        (C4:GetBoundConsumerDevices(device_id, 5001))
--   user_active(quiet_ms) -> bool        optional: a person's command is queued or was sent lately
--   bridge_ready() -> bool               optional: paired, identity checked, key accepted
--   last_action(text), attention_changed()   optional
--   set_timer(ms, fn) -> { Cancel }      required; now_ms() required; wall() seconds (default now_ms()/1000)
--   log                                  common.log or a stand-in
--
-- What a registry module gives (bridge/owner.lua's defaults, the modules' own):
--   registry[rid], reg:rids("linked"), conflicts, resyncing / importing,
--   hue_name(rid, entry) -> the raw Hue name the Composer name follows,
--   name_form(rid, entry) -> { prefix = "<Zone> " | nil, smart = bool },
--   name_requests(rid, name) -> the PUTs that write it, remember_proxy(rid, id),
--   entry_label(rid, entry).
--
-- The state (one new persisted key, compat research R3: no registry changes shape):
--   hue_name_pairs = { v = 1, seeded_build = <build>, pairs = { ["light:<rid>"] = {
--     h, c,          the last names both sides agreed on (h raw as Hue has it, c a display name)
--     pre, post,     the owner's affix around f(h) (N30), zp the zone prefix at agreement
--     push, push_c, push_at   a name waiting for the bridge (N11), the Composer name it came from
--     held, why, want         why the pair waits for Resolve Names: "first" | "refused" | "bulk"
--                             | "loop" | "shared"; Hue's reason; the name it refused
--     fresh,         created by AddDevice: the first look seeds whatever Composer shows (N17)
--     at } } }       wall seconds of the last agreement
-- In memory only: readiness per kind (a module's first resync of this run),
-- the echo windows (N5 to N7), the loop breaker's write times, the queues.
--
-- The rule (research §5.1) per linked entry with a pair, H the Hue name now
-- and C the Composer name now:
--   neither changed                      nothing (a waiting push is sent again)
--   Composer changed                     PUT g(C); the pair moves once Hue answers (N1)
--   Hue changed                          RenameDevice f(H); the pair moves before the call (N2)
--   both changed                         C agrees with f(H): the pair moves; else PUT g(C) (N3)
-- A held pair syncs nothing, except that a Composer rename of it (an event,
-- a person's act) resolves it: Control4 wins (Q8). No pair: names that agree
-- in form are paired silently, the rest held "first" (N19, N20, D11).
--
-- Pacing (research §5.4): a PUT at most once a second, never within 1.5 s
-- of a person's command; a RenameDevice at most once per 2 s; more than 5
-- changes found in one pass are held (N10); more than 10 Hue renames in a
-- minute hold the rest (N9); more than 3 automatic writes for one device in
-- 10 minutes hold it (N7). Every public entry only queues: the writes start
-- from timers, never inside an event container's OnBodyChunk.

local util = require("bridge.util")
local hue_model = require("bridge.hue_model")
local default_log = require("common.log")

local names = {}
names.__index = names

names.KEY = "hue_name_pairs"
names.VERSION = 1
names.KINDS = { "light", "scene", "motion" }
names.HUE_MAX_BYTES = 32          -- Hue refuses 33 characters and 32 two-byte ones (§2.3)
names.BULK_MAX = 5                -- N10, Q5
names.PUT_GAP_MS = 1000           -- research §5.4
names.USER_QUIET_MS = 1500
names.RENAME_GAP_MS = 2000        -- each RenameDevice refreshes the project (E3)
names.ECHO_MS = 10000             -- N7: the first answer within it is the echo
names.LOOP_WINDOW_MS = 600000
names.LOOP_MAX = 3
names.BURST_WINDOW_MS = 60000     -- N9
names.BURST_MAX = 10
names.WAIT_ATTENTION_S = 600      -- N11: Attention after 10 minutes
names.SETTLE_MS = 1000            -- a device and its light's update coalesce per entry
names.RETRY_MS = 500
names.PUT_TIMEOUT_MS = 30000
names.LINES_MS = 2000             -- Last Action lines of a burst are joined
names.MAX_NAMED = 3

local display = util.display_name

-- "1 name differs", "2 names differ": a count with its word, the second
-- form for anything but one (util.plural adds an "s" only).
local function counted(n, one, many)
	return string.format("%d %s", n, n == 1 and one or (many or (one .. "s")))
end

-- Helpers ------------------------------------------------------------------------

local function key_of(kind, rid)
	return kind .. ":" .. rid
end

local function split(key)
	local kind, rid = tostring(key):match("^([%a_]+):(.+)$")
	return kind, rid
end

local function starts(s, prefix)
	return prefix ~= nil and prefix ~= "" and s:sub(1, #prefix) == prefix
end

local function ends(s, suffix)
	return suffix ~= nil and suffix ~= "" and #s >= #suffix and s:sub(-#suffix) == suffix
end

local function alnum(ch)
	return ch ~= nil and ch ~= "" and ch:find("^[%w]") ~= nil
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
-- trailing blanks trimmed: "cut to 32 in Hue" (N4).
function names.cut(s, max)
	max = max or names.HUE_MAX_BYTES
	s = tostring(s or "")
	if #s <= max then
		return display(s)
	end
	local cut = max
	while cut > 0 do
		local b = s:byte(cut + 1)
		if not (b and b >= 0x80 and b <= 0xBF) then
			break
		end
		cut = cut - 1
	end
	return display(s:sub(1, cut))
end

-- Why Hue cannot hold `name`, checked before any request (N25), or nil.
function names.too_long(name)
	if #name <= names.HUE_MAX_BYTES then
		return nil
	end
	local n = chars(name)
	if n == #name then
		return string.format("%d characters, Hue takes %d", n, names.HUE_MAX_BYTES)
	end
	return string.format("%d bytes, Hue takes %d (accented letters count twice)", #name, names.HUE_MAX_BYTES)
end

-- Hue's own words for a refused write: the first error description of the
-- answer, else the transfer's error.
function names.hue_error(result)
	local errors = type(result) == "table" and type(result.json) == "table" and result.json.errors or nil
	if type(errors) == "table" and type(errors[1]) == "table" and errors[1].description ~= nil then
		return tostring(errors[1].description)
	end
	if type(result) == "table" then
		return tostring(result.err or (result.code and ("HTTP " .. tostring(result.code))) or "no answer")
	end
	return "no answer"
end

-- A put_name for ctx: the module's name_requests(rid, name) sent one after
-- another through request(req, cb(result)) (bridge_request: { ok, code,
-- json, err }). The first request decides (a single-light lamp's device
-- name); a later one that fails (the lamp's own light name) is logged only.
function names.put_via(registries, request, log)
	log = log or default_log
	return function(kind, rid, name, done)
		local reg = registries[kind]
		local reqs = reg and reg.name_requests and reg:name_requests(rid, name) or nil
		if type(reqs) ~= "table" or #reqs == 0 then
			return done(false, "no way to write this name on the bridge")
		end
		local i = 0
		local step
		step = function(result)
			if i > 0 and not (type(result) == "table" and result.ok) then
				if i == 1 then
					return done(false, names.hue_error(result), type(result) == "table" and result.code or nil)
				end
				log.warn("names: %s %s answered %s; the name itself was taken", tostring(reqs[i].method),
					tostring(reqs[i].path), names.hue_error(result))
			end
			i = i + 1
			if not reqs[i] then
				return done(true)
			end
			request(reqs[i], step)
		end
		step(nil)
	end
end

-- Construction and the store -------------------------------------------------------

function names.new(ctx)
	ctx = ctx or {}
	assert(type(ctx.registries) == "table", "names.new: ctx.registries is required")
	assert(type(ctx.set_timer) == "function", "names.new: ctx.set_timer is required")
	assert(type(ctx.now_ms) == "function", "names.new: ctx.now_ms is required")
	local store = ctx.store or {}
	local get = store.get or ctx.persist_get
	local set = store.set or ctx.persist_set
	assert(type(get) == "function" and type(set) == "function", "names.new: the store is required")
	ctx.log = ctx.log or default_log
	ctx.wall = ctx.wall or function()
		return math.floor(ctx.now_ms() / 1000)
	end
	local self = setmetatable({
		ctx = ctx, get = get, set = set, log = ctx.log,
		registries = ctx.registries,
		pairs = {},
		seeded_build = nil,
		migrating = nil,        -- { build, done = { [kind] = true } } during the first run of 1.2
		ready = {},             -- kind → true after its first pass of this run (§3.3)
		echo_h = {},            -- key → ms until which a Hue answer is our PUT's echo (N5, N7)
		echo_c = {},            -- key → ms until which a Composer answer is our RenameDevice's (N6, N7)
		writes = {},            -- key → { ms } of automatic writes (N7)
		renames_at = {},        -- ms of Hue-to-Composer renames (N9)
		explicit = {},          -- key → true: a Composer rename seen before its kind was ready
		pending = {},           -- key → "composer" | "hue": waiting for the settle timer
		push_keys = {}, push_job = {}, push_busy = nil,
		rename_keys = {}, rename_job = {},
		last_push_ms = nil, last_rename_ms = nil,
		lines = {},
	}, names)
	self:load()
	return self
end

function names:load()
	local ok, raw = pcall(self.get, names.KEY)
	self.pairs = {}
	if ok and type(raw) == "table" then
		self.seeded_build = raw.seeded_build
		for key, pair in pairs(type(raw.pairs) == "table" and raw.pairs or {}) do
			if type(key) == "string" and split(key) and type(pair) == "table" then
				self.pairs[key] = pair
			end
		end
	elseif ok and raw ~= nil then
		self.log.warn("names: %s is a %s, not a table; starting empty", names.KEY, type(raw))
	end
end

function names:save()
	self.set(names.KEY, { v = names.VERSION, seeded_build = self.seeded_build, pairs = self.pairs })
end

function names:protect(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		self.log.error("names: %s failed: %s", what, tostring(err))
	end
	return ok
end

function names:timer(ms, fn)
	return self.ctx.set_timer(math.max(1, math.floor(ms)), function()
		self:protect("timer", fn)
	end)
end

function names:changed()
	if self.ctx.attention_changed then
		self:protect("attention_changed", self.ctx.attention_changed)
	end
end

-- A Last Action line; the lines of a burst are joined (§5.5).
function names:line(text)
	self.log.always("names: %s", text)
	self.lines[#self.lines + 1] = text
	if self.lines_timer then
		pcall(self.lines_timer.Cancel, self.lines_timer)
	end
	self.lines_timer = self:timer(names.LINES_MS, function()
		self.lines_timer = nil
		self:flush_lines()
	end)
end

function names:flush_lines()
	local lines = self.lines
	self.lines = {}
	if #lines == 0 or not self.ctx.last_action then
		return
	end
	local text = table.concat(lines, "; ", 1, math.min(#lines, names.MAX_NAMED))
	if #lines > names.MAX_NAMED then
		text = text .. string.format("; +%d more (see the Lua output)", #lines - names.MAX_NAMED)
	end
	self:protect("last_action", self.ctx.last_action, text)
end

-- Entries, names and forms ----------------------------------------------------------

function names:entry(kind, rid)
	local reg = self.registries[kind]
	return reg, reg and rid and reg.registry[rid] or nil
end

-- The proxy Composer shows and renames (API 22_miscellaneous/_32-RenameDevice):
-- the entry's, else ctx.proxy_of fills it once (an adopted device, E5).
function names:proxy(reg, rid, entry)
	if entry.proxy_id then
		return entry.proxy_id
	end
	if self.ctx.proxy_of and entry.device_id then
		local ok, id = pcall(self.ctx.proxy_of, entry.device_id)
		id = ok and util.positive(id) or nil
		if id then
			if reg.remember_proxy then
				reg:remember_proxy(rid, id)
			else
				entry.proxy_id = id
			end
			return id
		end
	end
	return nil
end

-- What Composer shows for id, as a display name; nil when unknown.
function names:composer(id)
	local ok, name = pcall(self.ctx.display_name, id)
	if not ok or name == nil then
		return nil
	end
	local text = display(name)
	return text ~= "" and text or nil
end

-- The Composer name an entry goes by in texts.
function names:label(kind, rid)
	local reg, entry = self:entry(kind, rid)
	if not entry then
		return tostring(rid)
	end
	local id = entry.proxy_id or entry.device_id
	return util.sanitise(self:composer(id) or (reg.entry_label and reg:entry_label(rid, entry)) or rid)
end

function names.form(reg, rid, entry)
	local form = reg.name_form and reg:name_form(rid, entry) or nil
	return type(form) == "table" and form or {}
end

-- The Hue name's core in the Composer form: the zone prefix, a time-based
-- scene's base name (research §5.2).
local function core(h, form)
	local base = h
	if form.smart then
		base = hue_model.base_name(tostring(h)) or h
	end
	return display((form.prefix or "") .. tostring(base or ""))
end

-- f: the Composer name a Hue name maps to, with the pair's affix.
function names.f(h, pair, form)
	local text = core(h, form)
	if pair and (pair.pre or pair.post) then
		text = display((pair.pre or "") .. text .. (pair.post or ""))
	end
	return text
end

-- g: the Hue name a Composer name maps to. The affix comes off while the
-- name still carries it (else it is dropped, N30); then the zone prefix the
-- pair agreed on, or the zone's current one (N23).
function names.g(c, pair, form)
	local s = display(c)
	if pair and (pair.pre or pair.post) then
		local pre, post = pair.pre or "", pair.post or ""
		if #s > #pre + #post and (pre == "" or starts(s, pre)) and (post == "" or ends(s, post)) then
			s = display(s:sub(#pre + 1, #s - #post))
		end
	end
	local prefixes = {}
	if pair and pair.zp then
		prefixes[#prefixes + 1] = pair.zp
	end
	if form.prefix then
		prefixes[#prefixes + 1] = form.prefix
	end
	for _, prefix in ipairs(prefixes) do
		if starts(s, prefix) and #s > #prefix then
			s = display(s:sub(#prefix + 1))
			break
		end
	end
	return s
end

-- Whether Composer name `c` agrees with Hue name `h` in form, and the
-- owner's affix it carries (N30): c = pre .. f(h) .. post, each part ending
-- or starting at a word boundary. Returns agree, pre, post.
function names.related(c, h, form)
	local f0 = core(h, form)
	if f0 == "" then
		return false
	end
	if c == f0 or names.g(c, nil, form) == display(h) then
		return true
	end
	local i = c:find(f0, 1, true)
	if not i then
		return false
	end
	local pre, post = c:sub(1, i - 1), c:sub(i + #f0)
	if (pre ~= "" and alnum(pre:sub(-1))) or (post ~= "" and alnum(post:sub(1, 1))) then
		return false
	end
	return true, pre ~= "" and pre or nil, post ~= "" and post or nil
end

-- Name sources shared by two linked entries (N15): a light and a sensor on
-- one Hue device, or two devices claiming one rid.
function names:shared_keys()
	local by_source, out = {}, {}
	for _, kind in ipairs(names.KINDS) do
		local reg = self.registries[kind]
		if reg then
			for _, rid in ipairs(reg.reg:rids("linked")) do
				local entry = reg.registry[rid]
				local source = reg.name_source and reg:name_source(rid, entry) or key_of(kind, rid)
				local key = key_of(kind, rid)
				if by_source[source] then
					out[key], out[by_source[source]] = true, true
				else
					by_source[source] = key
				end
				if reg.conflicts and reg.conflicts[rid] then
					out[key] = true
				end
			end
		end
	end
	return out
end

-- The rule -----------------------------------------------------------------------------

-- What the rule does for one entry now, without doing it: nil (nothing), or
-- { op = "seed" | "hold" | "push" | "rename", ... }. `mode` is "pass",
-- "composer" (an OnItemNameChanged) or "hue" (an event's new name).
function names:judge(kind, rid, mode, shared)
	local reg, entry = self:entry(kind, rid)
	if not entry or entry.state ~= "linked" then
		return nil  -- N13, N14: the pass decides once it is linked again
	end
	local key = key_of(kind, rid)
	local pair = self.pairs[key]
	if shared and shared[key] then
		if not (pair and pair.held == "shared") then
			return { op = "hold", key = key, why = "shared" }
		end
		return nil
	end
	if self.rename_job[key] and mode ~= "composer" then
		return nil
	end
	if self.push_job[key] and mode == "pass" then
		return nil
	end
	local id = self:proxy(reg, rid, entry)
	if not id then
		self.log.debug("names: %s has no proxy id yet; not synced", key)
		return nil
	end
	local C = self:composer(id)
	local H = reg:hue_name(rid, entry)
	if C == nil or H == nil or display(H) == "" then
		return nil
	end
	H = tostring(H)
	local form = names.form(reg, rid, entry)
	local explicit = mode == "composer" or self.explicit[key]
	local now = self.ctx.now_ms()

	if not pair or pair.c == nil then
		local agree, pre, post = names.related(C, H, form)
		if pair and pair.fresh then
			-- A Composer rename before the first look (imported, then renamed at
			-- once, as dealers do): a person's act, sent to Hue (N1), not taken
			-- as the agreed name. Any other first look seeds what Composer shows.
			if explicit and not agree then
				return { op = "push", key = key, target = names.g(C, nil, form), c = C, was = H, reason = "composer" }
			end
			return { op = "seed", key = key, h = H, c = C, pre = pre, post = post, zp = form.prefix }
		end
		if agree and entry.name_dismissed == nil then
			return { op = "seed", key = key, h = H, c = C, pre = pre, post = post, zp = form.prefix }
		end
		if explicit then
			return { op = "push", key = key, target = names.g(C, nil, form), c = C, was = H, reason = "composer" }
		end
		return { op = "hold", key = key, why = "first", h = H, c = C }
	end
	if pair.held then
		if pair.held == "shared" then
			return nil
		end
		if explicit then
			return { op = "push", key = key, target = names.g(C, pair, form), c = C, was = H, reason = "composer" }
		end
		local agree, pre, post = names.related(C, H, form)
		if agree and pair.held ~= "refused" then
			-- Someone made the two agree (in Hue, or Composer without an event):
			-- nothing is left for Resolve Names.
			return { op = "seed", key = key, h = H, c = C, pre = pre, post = post, zp = form.prefix }
		end
		return nil
	end
	-- N5 to N7: the first answer from a side within the window after our own
	-- write there is its echo, whatever its text; the window ends with it.
	for _, w in ipairs({ { self.echo_h, "composer" }, { self.echo_c, "hue" } }) do
		local until_ms = w[1][key]
		if until_ms and now >= until_ms then
			w[1][key], until_ms = nil, nil
		end
		if until_ms and mode ~= w[2] then
			w[1][key] = nil
			if w[1] == self.echo_h and H ~= pair.h then
				return { op = "seed", key = key, h = H, c = pair.c, echo = "hue" }
			elseif w[1] == self.echo_c and C ~= pair.c then
				return { op = "seed", key = key, h = pair.h, c = C, echo = "composer" }
			end
		end
	end
	local c_changed = C ~= pair.c
	local h_changed = H ~= pair.h and H ~= pair.push
	if not c_changed and not h_changed then
		if pair.push then
			return { op = "seed", key = key, h = pair.h, c = C }  -- renamed back while waiting: nothing to send
		end
		return nil
	end
	if c_changed and not h_changed then
		local target = names.g(C, pair, form)
		if target == display(pair.h) then
			return { op = "seed", key = key, h = pair.h, c = C }
		end
		return { op = "push", key = key, target = target, c = C, was = pair.h, reason = "composer" }
	end
	local to = names.f(H, pair, form)
	if to == C then
		return { op = "seed", key = key, h = H, c = C }
	end
	if not c_changed then
		return { op = "rename", key = key, to = to, h = H, was = C, id = id }
	end
	return { op = "push", key = key, target = names.g(C, pair, form), c = C, was = H, reason = "both" }
end

-- N7's loop breaker: true when one more automatic write for `key` would make
-- more than LOOP_MAX in LOOP_WINDOW_MS (the write is then not made).
function names:looping(key)
	local now, kept = self.ctx.now_ms(), {}
	for _, t in ipairs(self.writes[key] or {}) do
		if now - t < names.LOOP_WINDOW_MS then
			kept[#kept + 1] = t
		end
	end
	self.writes[key] = kept
	return #kept >= names.LOOP_MAX
end

function names:wrote(key)
	local list = self.writes[key] or {}
	list[#list + 1] = self.ctx.now_ms()
	self.writes[key] = list
end

function names:hold(key, why, extra)
	local pair = self.pairs[key] or {}
	self.pairs[key] = pair
	pair.held = why
	pair.fresh = nil
	for k, v in pairs(extra or {}) do
		pair[k] = v
	end
	if pair.held ~= "refused" then
		pair.why, pair.want = nil, nil
	end
	self:drop_jobs(key)
	self.log.info("names: %s held (%s%s)", key, why, pair.why and (": " .. pair.why) or "")
end

function names:drop_jobs(key)
	self.push_job[key], self.rename_job[key] = nil, nil
end

-- Carry out one decision. `click` marks a person's own act (Resolve Names,
-- a re-link): it is not counted by the loop breaker or the burst guard.
function names:apply(d, click)
	local key = d.key
	if d.op == "seed" then
		local pair = self.pairs[key] or {}
		self.pairs[key] = pair
		local same_form = pair.c ~= nil
		pair.h, pair.c = d.h, d.c
		if not same_form or d.pre or d.post then
			pair.pre, pair.post = d.pre, d.post
		end
		if d.zp ~= nil or not same_form then
			pair.zp = d.zp
		end
		pair.held, pair.why, pair.want, pair.fresh = nil, nil, nil, nil
		pair.push, pair.push_c, pair.push_at = nil, nil, nil
		pair.at = self.ctx.wall()
		self.explicit[key] = nil
		self.log.debug("names: %s paired%s: Hue %q, Composer %q", key, d.echo and (" (" .. d.echo .. " echo)") or "",
			tostring(d.h), tostring(d.c))
	elseif d.op == "hold" then
		self:hold(key, d.why, { h = d.h, c = d.c })
	elseif d.op == "push" then
		self:queue_push(key, d.target, d.c, d.was, d.reason, click)
	elseif d.op == "rename" then
		if not click then
			local now, kept = self.ctx.now_ms(), {}
			for _, t in ipairs(self.renames_at) do
				if now - t < names.BURST_WINDOW_MS then
					kept[#kept + 1] = t
				end
			end
			self.renames_at = kept
			if #kept >= names.BURST_MAX then
				return self:hold(key, "bulk")
			end
			if self:looping(key) then
				return self:hold(key, "loop")
			end
			self.renames_at[#self.renames_at + 1] = now
		end
		self.explicit[key] = nil
		if not self.rename_job[key] then
			self.rename_keys[#self.rename_keys + 1] = key
		end
		self.rename_job[key] = { to = d.to, h = d.h, was = d.was, click = click, on_done = d.on_done }
		self:kick()
	end
end

-- Queue a PUT of `target` for `key` (the latest per device wins, N8).
function names:queue_push(key, target, c, was, reason, click, on_done)
	local pair = self.pairs[key] or {}
	self.pairs[key] = pair
	self.explicit[key] = nil
	if target == nil or target == "" then
		self:hold(key, "refused", { why = "nothing of the Composer name is left for Hue", want = "" })
		return false
	end
	local long = names.too_long(target)
	if long then
		self:hold(key, "refused", { why = long, want = target })
		return false
	end
	if not click and reason ~= "waiting" and self:looping(key) then
		self:hold(key, "loop")
		return false
	end
	pair.push, pair.push_c = target, c
	pair.push_at = pair.push_at or self.ctx.wall()
	if not self.push_job[key] then
		self.push_keys[#self.push_keys + 1] = key
	end
	self.push_job[key] = { target = target, c = c, was = was, reason = reason, click = click, on_done = on_done }
	self:kick()
	return true
end

-- The queues -----------------------------------------------------------------------------

function names:kick(delay)
	if self.pump_timer then
		return
	end
	self.pump_timer = self:timer(delay or 1, function()
		self.pump_timer = nil
		self:pump()
	end)
end

local function next_key(list, jobs)
	while #list > 0 do
		local key = table.remove(list, 1)
		if jobs[key] then
			return key
		end
	end
	return nil
end

function names:pump()
	local now = self.ctx.now_ms()
	local wait = nil
	local function later(ms)
		wait = wait and math.min(wait, ms) or ms
	end
	if #self.rename_keys > 0 then
		local due = (self.last_rename_ms or -math.huge) + names.RENAME_GAP_MS
		if now >= due then
			local key = next_key(self.rename_keys, self.rename_job)
			if key then
				local job = self.rename_job[key]
				self.rename_job[key] = nil
				self.last_rename_ms = now
				self:run_rename(key, job)
			end
			if #self.rename_keys > 0 then
				later(names.RENAME_GAP_MS)
			end
		else
			later(due - now)
		end
	end
	if #self.push_keys > 0 and not self.push_busy then
		local due = (self.last_push_ms or -math.huge) + names.PUT_GAP_MS
		if now < due then
			later(due - now)
		elseif self.ctx.user_active and self.ctx.user_active(names.USER_QUIET_MS) then
			later(names.RETRY_MS)
		elseif self.ctx.bridge_ready and not self.ctx.bridge_ready() then
			-- N11: the names wait in their pairs; the next successful resync's pass sends them.
			for _, key in ipairs(self.push_keys) do
				local job = self.push_job[key]
				if job and job.on_done then
					job.on_done(false, "the bridge is not available; it is sent after the next resync")
				end
				self.push_job[key] = nil
			end
			self.push_keys = {}
			self:save()
			self:changed()
		else
			local key = next_key(self.push_keys, self.push_job)
			if key then
				local job = self.push_job[key]
				self.push_job[key] = nil
				self.last_push_ms = now
				self:run_push(key, job)
			end
		end
	end
	if wait then
		self:kick(wait)
	end
end

function names:run_rename(key, job)
	local kind, rid = split(key)
	local reg, entry = self:entry(kind, rid)
	local id = entry and entry.state == "linked" and self:proxy(reg, rid, entry) or nil
	if not id then
		if job.on_done then
			job.on_done(false, "the device is not linked")
		end
		return
	end
	local pair = self.pairs[key] or {}
	self.pairs[key] = pair
	-- N6: the pair is set before the call, so its echo compares equal.
	pair.h, pair.c, pair.at = job.h, job.to, self.ctx.wall()
	pair.held, pair.why, pair.want, pair.fresh = nil, nil, nil, nil
	pair.push, pair.push_c, pair.push_at = nil, nil, nil
	self.echo_c[key] = self.ctx.now_ms() + names.ECHO_MS
	if not job.click then
		self:wrote(key)
	end
	self:save()
	local ok, err = pcall(self.ctx.rename_device, id, job.to)
	if ok then
		self:line(string.format("Name taken from Hue: %s (device %d, was %s)", job.to, entry.device_id,
			tostring(job.was)))
	else
		self.log.warn("names: RenameDevice %d failed: %s", id, tostring(err))
	end
	self:changed()
	if job.on_done then
		job.on_done(ok, ok and string.format("%s (device %d)", job.to, entry.device_id) or tostring(err))
	end
end

function names:run_push(key, job)
	local kind, rid = split(key)
	self.push_busy = key
	local answered = false
	local guard
	local function answer(ok, err, code)
		if answered then
			return
		end
		answered = true
		if guard then
			pcall(guard.Cancel, guard)
		end
		self.push_busy = nil
		self:protect("PUT answer", self.pushed, self, key, job, ok, err, code)
		self:kick()
	end
	guard = self:timer(names.PUT_TIMEOUT_MS, function()
		answer(false, "no answer from the bridge")
	end)
	if not job.click then
		self:wrote(key)
	end
	local ok, err = pcall(self.ctx.put_name, kind, rid, job.target, function(...)
		answer(...)
	end)
	if not ok then
		answer(false, tostring(err))
	end
end

-- The bridge answered a name PUT.
function names:pushed(key, job, ok, err, code)
	local pair = self.pairs[key]
	local label = job.c
	local done = job.on_done or function() end
	if not pair then
		return done(false, "forgotten meanwhile")  -- forgotten while the PUT was out
	end
	if ok then
		pair.h, pair.c, pair.at = job.target, job.c, self.ctx.wall()
		pair.held, pair.why, pair.want, pair.fresh = nil, nil, nil, nil
		if pair.push == job.target then
			pair.push, pair.push_c, pair.push_at = nil, nil, nil
		end
		self.echo_h[key] = self.ctx.now_ms() + names.ECHO_MS
		if job.reason == "both" then
			self:line(string.format("Both renamed: kept the Composer name %s and sent it to Hue (Hue had %s)", label,
				tostring(job.was)))
		elseif job.reason == "relink" then
			self:line(string.format("Name sent to Hue after the re-link: %s (was %s in Hue)", job.target,
				tostring(job.was)))
		else
			self:line(string.format("Name sent to Hue: %s (was %s in Hue)", job.target, tostring(job.was)))
		end
		done(true, job.target)
	elseif tonumber(code) == 400 then
		self:hold(key, "refused", { why = "Hue: " .. tostring(err), want = job.target })
		pair.push, pair.push_c, pair.push_at = nil, nil, nil
		self.log.warn("names: Hue refused the name %q for %s: %s", job.target, key, tostring(err))
		done(false, string.format("Hue refused %s: %s", job.target, tostring(err)))
	else
		-- N11: offline, key refused, a busy bridge: the name waits in the pair.
		self.log.warn("names: the name %q for %s waits for the bridge: %s", job.target, key, tostring(err))
		done(false, string.format("%s waits for the bridge (%s)", job.target, tostring(err)))
	end
	self:save()
	self:changed()
end

-- Live events ------------------------------------------------------------------------------

function names:settle_soon(key, mode)
	if self.pending[key] ~= "composer" then
		self.pending[key] = mode
	end
	if self.settle_timer then
		return
	end
	self.settle_timer = self:timer(names.SETTLE_MS, function()
		self.settle_timer = nil
		local pending = self.pending
		self.pending = {}
		local shared = self:shared_keys()
		local keys = {}
		for k in pairs(pending) do
			keys[#keys + 1] = k
		end
		table.sort(keys)  -- one order, whatever the table's
		for _, k in ipairs(keys) do
			local m = pending[k]
			local kind, rid = split(k)
			if m == "composer" and self.rename_job[k] then
				self.rename_job[k] = nil  -- the person's rename wins over the one from Hue
			end
			local d = self:judge(kind, rid, m, shared)
			if d then
				self:apply(d)
			end
		end
		self:save()
		self:changed()
	end)
end

-- A module took a new Hue name from the stream. The name is read again from
-- the module (a lamp's device and light names arrive apart and coalesce);
-- before the module's first resync of this run, and while it resyncs, the
-- pass decides instead (§3.3; the bulk guard must see a restore whole).
function names:on_hue_name(kind, rid)
	local reg = self.registries[kind]
	if not reg or not rid or not self.ready[kind] or reg.resyncing or reg.importing then
		return false
	end
	self:settle_soon(key_of(kind, rid), "hue")
	return true
end

-- The entry a proxy id stands for (lights, scenes, motion), or nil.
function names:find(id)
	id = util.positive(id)
	if not id then
		return nil
	end
	for _, kind in ipairs(names.KINDS) do
		local reg = self.registries[kind]
		if reg then
			for rid, entry in pairs(reg.registry) do
				if entry.proxy_id == id or (entry.proxy_id == nil and entry.device_id == id) then
					return kind, rid
				end
			end
		end
	end
	return nil
end

-- OnItemNameChanged with the renamed item's id (the proxy's, verified on OS
-- 3.4.2: docs/design.md). Anything that is not a light, scene or motion
-- device of this bridge is ignored (N34); zone lights only refresh the rows.
function names:on_composer_rename(id)
	local kind, rid = self:find(id)
	if not kind then
		self:changed()
		return false
	end
	local key = key_of(kind, rid)
	self.explicit[key] = true
	if not self.ready[kind] then
		return false  -- the pass after the first resync decides, as an explicit rename
	end
	self:settle_soon(key, "composer")
	return true
end

-- The pass (§3.3 step 2) -------------------------------------------------------------------

function names:pass(kind)
	local reg = self.registries[kind]
	if not reg then
		return 0
	end
	self.ready[kind] = true
	local shared = self:shared_keys()
	local decisions, active = {}, 0
	for _, rid in ipairs(reg.reg:rids("linked")) do
		local d = self:judge(kind, rid, "pass", shared)
		if d then
			decisions[#decisions + 1] = d
			local pair = self.pairs[d.key]
			local waiting = d.op == "push" and pair and pair.push ~= nil and pair.push == d.target
			if (d.op == "push" or d.op == "rename") and not waiting and not self.explicit[d.key] then
				active = active + 1
			end
		end
	end
	local bulk = active > names.BULK_MAX
	for _, d in ipairs(decisions) do
		local pair = self.pairs[d.key]
		local waiting = d.op == "push" and pair and pair.push == d.target
		if bulk and (d.op == "push" or d.op == "rename") and not waiting and not self.explicit[d.key] then
			self:hold(d.key, "bulk")
		else
			if waiting then
				d.reason = "waiting"
			end
			self:apply(d)
		end
	end
	if bulk then
		self.log.always("names: %d %s names changed while the driver was not watching; held for Resolve Names", active,
			kind)
	end
	self.log.debug("names: pass of the %s names: %d decisions%s", kind, #decisions, bulk and " (held, N10)" or "")
	if self.migrating then
		self.migrating.done[kind] = true
		self:finish_migration()
	end
	self:save()
	self:changed()
	return #decisions
end

-- Migration (N19, N20, D11; compat research R4) -------------------------------------------

-- At late init. Without seeded_build this is the first run of two-way names
-- (an update from 1.1, or an empty store): the first pass of each kind pairs
-- the names that agree and holds the rest for Resolve Names. True when it starts.
function names:migrate(build)
	if self.seeded_build ~= nil then
		return false
	end
	self.migrating = { build = build, done = {} }
	self.log.always("names: first run with two-way names (build %s): names that agree are paired, the others wait "
		.. "for Resolve Names", tostring(build))
	return true
end

function names:finish_migration()
	for _, kind in ipairs(names.KINDS) do
		if self.registries[kind] and not self.migrating.done[kind] then
			return false
		end
	end
	self.seeded_build = self.migrating.build or true
	self.migrating = nil
	local held = self:held_keys("first")
	local text
	if #held == 0 then
		text = "Names: every Composer name agrees with Hue; renames now sync both ways"
	else
		text = string.format("Names: %s between Composer and Hue (Resolve Names: \"Composer names to Hue\" sends "
			.. "the Composer names); other renames now sync both ways", counted(#held, "name differs", "names differ"))
	end
	self.log.always("names: %s", text)
	if self.ctx.last_action then
		self:protect("last_action", self.ctx.last_action, text)
	end
	return true
end

-- Re-link and forget -------------------------------------------------------------------------

-- N16: the pair moves to the new rid and the Hue thing takes the Composer
-- name (Q6). Returns a text for the re-link's Last Action, or nil.
function names:relinked(kind, old_rid, new_rid)
	local old, new = key_of(kind, old_rid), key_of(kind, new_rid)
	local pair = self.pairs[old]
	self.pairs[old] = nil
	self:drop_jobs(old)
	self.echo_h[old], self.echo_c[old], self.explicit[old], self.writes[old] = nil, nil, nil, nil
	local reg, entry = self:entry(kind, new_rid)
	if not entry then
		self:save()
		return nil
	end
	pair = pair or {}
	pair.held, pair.why, pair.want, pair.fresh, pair.push, pair.push_c, pair.push_at = nil, nil, nil, nil, nil, nil, nil
	self.pairs[new] = pair
	local id = self:proxy(reg, new_rid, entry)
	local C = id and self:composer(id) or nil
	local H = reg:hue_name(new_rid, entry)
	if not C then
		pair.c = nil  -- read at the next pass
		pair.h = H
		self:save()
		return nil
	end
	local form = names.form(reg, new_rid, entry)
	local target = names.g(C, pair.c and pair or nil, form)
	local text
	if H ~= nil and display(H) == target then
		self:apply({ op = "seed", key = new, h = H, c = C, pre = pair.pre, post = pair.post, zp = form.prefix }, true)
	elseif self:queue_push(new, target, C, H, "relink", true) then
		text = string.format("; Hue gets the Composer name %s", target)
	else
		local held = self.pairs[new]
		text = string.format("; Hue cannot take the name %s (%s): Resolve Names", target, tostring(held and held.why))
	end
	self:save()
	self:changed()
	return text
end

function names:forgotten(kind, rid)
	local key = key_of(kind, rid)
	self.pairs[key] = nil
	self:drop_jobs(key)
	self.echo_h[key], self.echo_c[key], self.explicit[key], self.writes[key], self.pending[key] = nil, nil, nil, nil, nil
	self:save()
	self:changed()
end

-- A device AddDevice created: its first look pairs whatever Composer shows (N17).
function names:added(kind, rid, hue_name)
	local key = key_of(kind, rid)
	self.pairs[key] = { h = hue_name, fresh = true, at = self.ctx.wall() }
	self:save()
end

-- Resolve Names ------------------------------------------------------------------------------

function names:held_keys(why)
	local out = {}
	for key, pair in pairs(self.pairs) do
		if pair.held and (why == nil or pair.held == why) then
			local kind, rid = split(key)
			local _, entry = self:entry(kind, rid)
			if entry then
				out[#out + 1] = key
			end
		end
	end
	table.sort(out, function(a, b)
		local la, lb = self:label(split(a)):lower(), self:label(split(b)):lower()
		if la ~= lb then
			return la < lb
		end
		return a < b
	end)
	return out
end

-- The names of a held pair now: C, H, f(H), g(C), the entry. nil when unreadable.
function names:now(key)
	local kind, rid = split(key)
	local reg, entry = self:entry(kind, rid)
	if not entry or entry.state ~= "linked" then
		return nil
	end
	local id = self:proxy(reg, rid, entry)
	local C = id and self:composer(id) or nil
	local H = reg:hue_name(rid, entry)
	if not C or H == nil then
		return nil
	end
	local pair = self.pairs[key]
	local form = names.form(reg, rid, entry)
	local affix = pair and pair.c and pair or nil
	return { C = C, H = tostring(H), fH = names.f(H, affix, form), gC = names.g(C, affix, form), entry = entry,
		id = id, form = form }
end

function names:actionable()
	local out = {}
	for _, key in ipairs(self:held_keys()) do
		if self.pairs[key].held ~= "shared" and self:now(key) then
			out[#out + 1] = key
		end
	end
	return out
end

-- Resolve Names' rows: "Composer names to Hue (all N)" first (D11), "Hue
-- names to Composer (all N)", two rows per held device (three for one Hue
-- refused: "cut to 32 in Hue"), then the zone lights' differences (they
-- never sync, D11). One explanatory row with value "" when nothing waits.
function names:resolve_rows()
	local rows, keys = {}, self:actionable()
	local s = util.sanitise
	if #keys > 0 then
		rows[#rows + 1] = { text = string.format("Composer names to Hue (all %d)", #keys), value = "names:composer_to_hue" }
		rows[#rows + 1] = { text = string.format("Hue names to Composer (all %d)", #keys), value = "names:hue_to_composer" }
		for _, key in ipairs(keys) do
			local n, pair = self:now(key), self.pairs[key]
			rows[#rows + 1] = { text = s(string.format("%s: send it to Hue (Hue has %s)", n.C, display(n.H))),
				value = "c2h:" .. key }
			rows[#rows + 1] = { text = s(string.format("%s: rename it to %s from Hue", n.C, n.fH)), value = "h2c:" .. key }
			if pair.held == "refused" then
				rows[#rows + 1] = { text = s(string.format("%s: cut to %s in Hue", n.C, names.cut(n.gC))),
					value = "cut:" .. key }
			end
		end
	end
	local zl = self.registries.zone_light
	local diffs = zl and zl.name_differences and zl:name_differences() or {}
	if #diffs > 0 then
		rows[#rows + 1] = { text = string.format("Zone lights: rename to the Hue names (all %d)", #diffs),
			value = "zl:adopt" }
		rows[#rows + 1] = { text = string.format("Zone lights: keep the Composer names (all %d)", #diffs),
			value = "zl:keep" }
	end
	if #rows == 0 then
		rows[1] = { text = "(no names to resolve: Composer and Hue agree)", value = "" }
	end
	return rows
end

-- The bulk values (bridge/actions.lua and the Adopt Hue Names alias send
-- them) and their short spellings.
local BULK = { ["names:composer_to_hue"] = "c2h:all", ["names:hue_to_composer"] = "h2c:all" }

-- Carry out one row of Resolve Names: "names:composer_to_hue",
-- "names:hue_to_composer", "c2h:<kind>:<rid>", "h2c:<kind>:<rid>",
-- "cut:<kind>:<rid>", "zl:adopt", "zl:keep". done(ok, text) once every
-- write it started is answered (the renames run at the paced rate).
function names:resolve(value, done)
	done = done or function() end
	value = tostring(value or "")
	value = BULK[value] or value
	local what, rest = value:match("^(%a+2?%a*):(.+)$")
	if what == "zl" then
		local zl = self.registries.zone_light
		if not zl then
			return done(false, "Not resolved: no zone lights")
		end
		if rest == "adopt" then
			return done(true, zl:adopt_hue_names())
		elseif rest == "keep" then
			return done(true, zl:accept_names())
		end
	end
	if what ~= "c2h" and what ~= "h2c" and what ~= "cut" then
		return done(false, "Not resolved: pick a row of Names first")
	end
	local keys
	if rest == "all" and what ~= "cut" then
		keys = self:actionable()
	else
		keys = { rest }
	end
	if #keys == 0 then
		return done(true, "No names wait for Resolve Names")
	end
	local waiting, oks, fails = 0, {}, {}
	local started = false
	local function finish()
		if waiting > 0 or not started then
			return
		end
		local parts = {}
		if #oks > 0 then
			parts[#parts + 1] = string.format("%s %s: %s", what == "h2c" and "Renamed from Hue" or "Sent to Hue",
				counted(#oks, "name"), table.concat(oks, ", "))
		end
		if #fails > 0 then
			parts[#parts + 1] = string.format("not done %d: %s", #fails, table.concat(fails, "; "))
		end
		local text = table.concat(parts, "; ")
		self.log.always("names: Resolve Names: %s", text)
		done(#fails == 0, text)
	end
	for _, key in ipairs(keys) do
		local n = self:now(key)
		if not n then
			fails[#fails + 1] = string.format("%s: not linked, or its names cannot be read", key)
		else
			waiting = waiting + 1
			local function on_done(ok, text)
				waiting = waiting - 1
				if ok then
					oks[#oks + 1] = tostring(text)
				else
					fails[#fails + 1] = tostring(text)
				end
				finish()
			end
			if what == "h2c" then
				self:apply({ op = "rename", key = key, to = n.fH, h = n.H, was = n.C, on_done = on_done }, true)
			else
				local target = what == "cut" and names.cut(n.gC) or n.gC
				if not self:queue_push(key, target, n.C, n.H, "click", true, on_done) then
					local pair = self.pairs[key]
					on_done(false, string.format("%s: %s", n.C, tostring(pair and pair.why)))
				end
			end
		end
	end
	started = true
	self:save()
	self:changed()
	finish()
end

-- Attention (§5.5): each item ends in what settles it --------------------------------------

function names:attention()
	local items, s = {}, util.sanitise
	local now = self.ctx.wall()
	local waiting, refused, loop, bulk, first, shared = {}, {}, {}, {}, {}, {}
	local keys = {}
	for key in pairs(self.pairs) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local pair = self.pairs[key]
		local kind, rid = split(key)
		local _, entry = self:entry(kind, rid)
		if entry then
			if pair.push and not pair.held and now - (tonumber(pair.push_at) or now) >= names.WAIT_ATTENTION_S then
				waiting[#waiting + 1] = s(pair.push_c or pair.push)
			elseif pair.held == "refused" then
				refused[#refused + 1] = string.format("%s (%s)", self:label(kind, rid), tostring(pair.why))
			elseif pair.held == "loop" then
				loop[#loop + 1] = self:label(kind, rid)
			elseif pair.held == "bulk" then
				bulk[#bulk + 1] = self:label(kind, rid)
			elseif pair.held == "first" then
				first[#first + 1] = self:label(kind, rid)
			elseif pair.held == "shared" then
				shared[#shared + 1] = self:label(kind, rid)
			end
		end
	end
	local some = function(list)
		return util.some(list, names.MAX_NAMED)
	end
	if #waiting > 0 then
		items[#items + 1] = string.format("%s for the bridge: %s", counted(#waiting, "rename waits", "renames wait"),
			some(waiting))
	end
	if #refused > 0 then
		items[#items + 1] = string.format("%s Hue refused: %s (Resolve Names)", counted(#refused, "name"),
			some(refused))
	end
	if #loop > 0 then
		items[#items + 1] = string.format("Names of %s keep changing; their sync is paused (Resolve Names)", some(loop))
	end
	if #bulk > 0 then
		items[#items + 1] = string.format("%s while the driver was not watching (Resolve Names)",
			counted(#bulk, "name changed", "names changed"))
	end
	if #shared > 0 then
		items[#items + 1] = string.format("%s one Hue name and do not sync: %s (Forget Device on one)",
			counted(#shared, "device shares", "devices share"), some(shared))
	end
	if #first > 0 then
		items[#items + 1] = string.format("%s between Composer and Hue (Resolve Names)",
			counted(#first, "name differs", "names differ"))
	end
	return items
end

-- The hidden aliases (names-sync §6) ------------------------------------------------------

-- Adopt Hue Names for one kind: its held pairs take their Hue names, at the
-- paced rate. Returns the report text at once.
function names:adopt_all(kind)
	local keys = {}
	for _, key in ipairs(self:actionable()) do
		if split(key) == kind then
			keys[#keys + 1] = key
		end
	end
	if #keys == 0 then
		return string.format("No %s names wait for Resolve Names; the others sync by themselves", kind)
	end
	local listed = {}
	for _, key in ipairs(keys) do
		local n = self:now(key)
		self:apply({ op = "rename", key = key, to = n.fH, h = n.H, was = n.C }, true)
		listed[#listed + 1] = string.format("%s → %s", n.C, n.fH)
	end
	self:save()
	self:changed()
	return string.format("Renaming %s to the Hue names (one every %d s): %s", counted(#keys, kind .. " device"),
		names.RENAME_GAP_MS / 1000, util.some(listed, names.MAX_NAMED))
end

function names.accept_text()
	return "Names now sync both ways by themselves; Resolve Names lists the ones that cannot"
end

return names
