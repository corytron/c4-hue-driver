-- The Hue automation audit and its remedy (#280, docs/hue-automation-audit-design.md,
-- cited below as "the contract"; its decisions D1-D24, its lifecycle rows
-- H1-H29, C1-C13 and R1-R10). The owner of the audit: it keeps the caches of
-- the bridge's behavior_script and behavior_instance resources (the GETs of
-- a full resync and the event stream), works out which Hue automations act
-- on lights Control4 controls, and gives the Hue Automations row, the
-- Attention items, the Hue Automations action's picker and its runner.
-- Parsing and classifying one resource is bridge/automation_model.lua's.
--
-- The rules that shape everything here:
--   - The audit reads by itself; the remedy only follows a click (D1). The
--     only write ever sent is PUT behavior_instance/<rid> {"enabled": false}
--     or {"enabled": true}, and only from run() (D2). resync, on_container,
--     evaluate and load never write to the bridge.
--   - Write-ahead (D13): the record entry is persisted as "pending" (or
--     "restoring") before the PUT and confirmed by a GET after it. A PUT with
--     no answer stays pending and is resolved by the next read, never by
--     sending again.
--   - Never fight (D14): an automation Control4 disabled that is enabled
--     again outside Control4 becomes "on again", is listed on Attention and
--     offered; the driver never disables it again, and never enables
--     anything by itself.
--   - A refusal is remembered per firmware (D12); a new firmware clears it.
--   - One request at a time (the queue below), every callback body
--     pcall-wrapped (protect).
--
-- Public interface (the contract §6.1):
--   local a = automations.new(ctx)
--   a:load()                     the persisted record; malformed parts dropped with a log line
--   a:resync(done, tier)         tier "quick": done(true, nil, 0) at once; else GET behavior_instance,
--                                then behavior_script when needed (D18); done(ok, err, 0)
--   a:on_container(container)    behavior_instance / behavior_script items; true when rows change
--   a:evaluate()                 D3-D8, D10 against ctx.control4(); returns the view
--   a:summary(), a:list_items(), a:attention_items()
--   a:picker(folder)             -> list, back (a CUSTOM_SELECT function's answer)
--   a:run(params)                the action (params.Automation); ends in ctx.last_action
--   a:forget_pairing_text(), a:removal_text()   C8's and C9's sentences, or nil
--
-- ctx (the contract §6.1; driver.lua's module_ctx plus these):
--   http(req, cb)        bridge_request: req { method, path, body (table) }; cb({ ok, code, json, err })
--   log, now             common.log; os.time
--   persist_get(key), persist_set(key, value)
--   bridge_id()          the paired bridge's id ("001788fffe123abc") or nil; a string is taken as is,
--                        anything else (module_ctx's numeric device id) is ignored
--   firmware()           the Bridge Firmware text or nil
--   paired()             connection() and not key-rejected
--   control4()           { lights = { [light_rid] = "Composer name" }, via = { [light_rid] = "device name" } }
--   expand(rid, rtype)   -> { light_rid, ... } (D4, from the lights' and zone lights' caches)
--   light_name(rid)      the Hue name of a light
--   motion_device(rid)   the Composer name of the Hue Motion device of an area or sensor, or nil
--   last_action(text), changed()   changed: rows and Attention need a refresh
--   busy()               the busy text of another job, or nil
--   wrote()              sets state.last_write_ms (R10)
--   set_timer(ms, fn)    optional, C4:SetTimer: a script GET wanted by a stream item starts from a
--                        timer, never inside the stream's callback; without it, at the next full resync

local util = require("bridge.util")
local model = require("bridge.automation_model")

local automations = {}
automations.__index = automations

automations.KEY = "hue_automations"
automations.PATH = "/clip/v2/resource/"
automations.PENDING_ATTENTION_S = 600   -- R4: a change not confirmed goes on Attention after 10 minutes
automations.MAX_NAMED = 3
automations.SUMMARY_MAX = 75
automations.SCRIPT_DELAY_MS = 200
automations.CLICK_MAX_S = 120          -- a click whose answer never came (a raised callback) stops blocking
automations.TOP = "f:top"
automations.COVERAGE = "Not seen here: other apps' v1 rules, Hue Labs, Alexa, Google, Apple Home routines"
automations.NOT_READ = "(not read yet; Diagnostics ▸ Read everything from the bridge now)"
automations.NOTHING = "(no Hue automations to act on)"
automations.NOT_PAIRED = "(not paired)"
automations.NOT_ANSWERING = "the Hue bridge is not answering; nothing was changed."

-- The folder values and the names their refusal texts use.
automations.FOLDERS = {
	["f:off"] = "Disable in Hue",
	["f:on"] = "Restore",
	["f:on:other"] = "Disabled outside Control4",
	["f:keep"] = "Keep on the Hue side",
	["f:unkeep"] = "Stop keeping",
	["f:top"] = "Back to all folders",
}

local ENTRY_STATES = { pending = true, disabled = true, restoring = true, on_again = true }

-- The row's groups, in drop-down order (the contract §6.3), with the words a line starts with.
local GROUPS = {
	{ key = "conflict", label = "On Control4 lights" },
	{ key = "on_again", label = "On again outside Control4" },
	{ key = "pending", label = "Not confirmed" },
	{ key = "disabled", label = "Disabled by Control4" },
	{ key = "kept", label = "Kept" },
	{ key = "shared", label = "Shared (a person starts it)" },
	{ key = "inert", label = "Does nothing" },
	{ key = "unknown_lights", label = "Can't tell which lights" },
	{ key = "safety", label = "Safety lighting (kept)" },
	{ key = "outside", label = "Disabled outside Control4" },
	{ key = "elsewhere", label = "Elsewhere" },
	{ key = "unclassified", label = "Not classified yet" },
}

-- Plumbing -------------------------------------------------------------------------------------

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = copy(v)
	end
	return out
end

local function str(value)
	return type(value) == "string" and value ~= "" and value or nil
end

local function as_set(value)
	local set = {}
	if type(value) ~= "table" then
		return set
	end
	for k, v in pairs(value) do
		if type(k) == "number" and type(v) == "string" then
			set[v] = true
		elseif type(k) == "string" and v then
			set[k] = true
		end
	end
	return set
end

local TRIGGERS = as_set(model.trigger_rtypes)
local TARGETS = as_set(model.target_rtypes)

local function count_of(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

local function by_name(a, b)
	local an, bn = util.norm(a.name), util.norm(b.name)
	if an ~= bn then
		return an < bn
	end
	return tostring(a.rid) < tostring(b.rid)
end

-- "…3abc" for a bridge id.
local function short_id(id)
	id = tostring(id or "")
	return "…" .. id:sub(-4)
end

-- "A", "A and B", "A, B and C", "A, B, C and 2 more".
local function and_list(names, max)
	max = max or automations.MAX_NAMED
	local n = #names
	if n == 0 then
		return ""
	elseif n == 1 then
		return names[1]
	end
	if n <= max then
		local head = {}
		for i = 1, n - 1 do
			head[i] = names[i]
		end
		return table.concat(head, ", ") .. " and " .. names[n]
	end
	local head = {}
	for i = 1, max do
		head[i] = names[i]
	end
	return table.concat(head, ", ") .. string.format(" and %d more", n - max)
end

-- Three names, then "+N".
local function lights_text(names)
	if #names <= automations.MAX_NAMED then
		return table.concat(names, ", ")
	end
	local head = {}
	for i = 1, automations.MAX_NAMED do
		head[i] = names[i]
	end
	return table.concat(head, ", ") .. string.format(" +%d", #names - automations.MAX_NAMED)
end

local function empty_record(bridge_id)
	return { v = 1, bridge_id = bridge_id, entries = {}, kept = {}, refused = {}, other = {} }
end

function automations.new(ctx)
	assert(type(ctx) == "table" and type(ctx.http) == "function", "automations.new: ctx.http is required")
	return setmetatable({
		ctx = ctx,
		log = ctx.log or require("common.log"),
		rec = empty_record(nil),
		instances = {},       -- rid -> the model's instance
		scripts = {},         -- rid -> the model's script
		scripts_read = false, -- a behavior_script GET answered in this run
		scripts_fw = nil,     -- the firmware it was read under
		script_misses = {},   -- script rids the last script GET did not list: unknown scripts (H20)
		script_timer = nil,
		read_at = nil,        -- os.time() of the last successful instance GET
		read_failed = false,  -- the last instance GET failed (the row's "as of")
		seq = 0,              -- stream containers seen, for the GET race (added after it was sent)
		added_seq = {},
		deleted = {},         -- names dropped by D23 in this run (the row's line 13)
		logged = {},          -- rid -> true once its conflict was logged (H1: logged once)
		queue = {},
		in_flight = false,
		inflight = {},        -- rid -> true while a click's PUT and read-back run
		writing = false,      -- os.time() a click started, while it runs
		resync_waiters = nil,
		view = nil,
	}, automations)
end

function automations:protect(what, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		self.log.error("automations: %s failed: %s", what, tostring(err))
	end
	return ok, err
end

function automations:now()
	return self.ctx.now and self.ctx.now() or os.time()
end

local function call_ctx(self, name, ...)
	local fn = self.ctx[name]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, value = pcall(fn, ...)
	if not ok then
		self.log.warn("automations: ctx.%s failed: %s", name, tostring(value))
		return nil
	end
	return value
end

function automations:bridge_id()
	local id = self.ctx.bridge_id
	if type(id) == "function" then
		id = call_ctx(self, "bridge_id")
	end
	return str(id)
end

function automations:firmware()
	local fw = self.ctx.firmware
	if type(fw) == "function" then
		fw = call_ctx(self, "firmware")
	end
	return fw ~= nil and tostring(fw) ~= "" and tostring(fw) or nil
end

function automations:paired()
	if type(self.ctx.paired) ~= "function" then
		return true
	end
	return call_ctx(self, "paired") == true
end

function automations:say(text)
	call_ctx(self, "last_action", text)
	return text
end

function automations:changed()
	self.view = nil
	call_ctx(self, "changed")
end

function automations:save()
	local ok, err = pcall(self.ctx.persist_set, automations.KEY, copy(self.rec))
	if not ok then
		self.log.error("automations: saving the record failed: %s", tostring(err))
	end
end

-- One request at a time; cb(result) runs pcall-wrapped when it is answered,
-- and the next queued request starts then. A synchronous answer (the driver
-- refuses at once while unpaired) works the same.
function automations:request(method, path, body, cb)
	self.queue[#self.queue + 1] = { method = method, path = path, body = body, cb = cb }
	self:pump()
end

function automations:pump()
	if self.in_flight then
		return
	end
	local job = table.remove(self.queue, 1)
	if not job then
		return
	end
	self.in_flight = true
	local answered = false
	local function answer(r)
		if answered then
			return
		end
		answered = true
		self.in_flight = false
		self:protect(job.method .. " " .. job.path, job.cb, type(r) == "table" and r or { ok = false, err = "no result" })
		self:pump()
	end
	local ok, err = pcall(self.ctx.http, { method = job.method, path = job.path, body = job.body }, answer)
	if not ok then
		answer({ ok = false, err = tostring(err) })
	end
end

local function data_of(r)
	return r.ok and type(r.json) == "table" and type(r.json.data) == "table" and r.json.data or nil
end

-- The record ------------------------------------------------------------------------------------

local function valid_entry(rid, e)
	if type(rid) ~= "string" or type(e) ~= "table" or not ENTRY_STATES[e.state] then
		return nil
	end
	local lights = {}
	for _, name in ipairs(type(e.lights) == "table" and e.lights or {}) do
		if type(name) == "string" then
			lights[#lights + 1] = name
		end
	end
	return {
		state = e.state,
		name = str(e.name) or rid,
		kind = str(e.kind) or "automation",
		script_rid = str(e.script_rid),
		lights = lights,
		sig = str(e.sig),
		at = tonumber(e.at),
		on_again_at = tonumber(e.on_again_at),
	}
end

local function valid_entries(raw, dropped)
	local out = {}
	if raw ~= nil and type(raw) ~= "table" then
		dropped[1] = dropped[1] + 1
		return out
	end
	for rid, e in pairs(raw or {}) do
		local entry = valid_entry(rid, e)
		if entry then
			out[rid] = entry
		else
			dropped[1] = dropped[1] + 1
		end
	end
	return out
end

local function valid_kept(raw, dropped)
	local out = {}
	if raw ~= nil and type(raw) ~= "table" then
		dropped[1] = dropped[1] + 1
		return out
	end
	for rid, k in pairs(raw or {}) do
		if type(rid) == "string" and type(k) == "table" then
			local lights = {}
			for light, on in pairs(type(k.lights) == "table" and k.lights or {}) do
				if type(light) == "string" and on then
					lights[light] = true
				end
			end
			out[rid] = { name = str(k.name) or rid, at = tonumber(k.at), lights = lights }
		else
			dropped[1] = dropped[1] + 1
		end
	end
	return out
end

-- a:load(): the record of the contract §6.6; a part that is not as written
-- there is dropped with one log line (L83). A record of another bridge is set
-- aside (D24) once the paired bridge is known.
function automations:load()
	local ok, raw = pcall(self.ctx.persist_get, automations.KEY)
	if not ok then
		self.log.error("automations: reading the record failed: %s", tostring(raw))
		raw = nil
	end
	if raw == nil then
		self.rec = empty_record(nil)
		self:check_bridge()
		return self.rec
	end
	if type(raw) ~= "table" or raw.v ~= 1 then
		self.log.warn("automations: the stored record is malformed; dropped")
		self.rec = empty_record(nil)
		self:check_bridge()
		return self.rec
	end
	local dropped = { 0 }
	local rec = empty_record(str(raw.bridge_id))
	rec.entries = valid_entries(raw.entries, dropped)
	rec.kept = valid_kept(raw.kept, dropped)
	for rid, fw in pairs(type(raw.refused) == "table" and raw.refused or {}) do
		if type(rid) == "string" and (type(fw) == "string" or type(fw) == "number") then
			rec.refused[rid] = tostring(fw)
		else
			dropped[1] = dropped[1] + 1
		end
	end
	for id, other in pairs(type(raw.other) == "table" and raw.other or {}) do
		if type(id) == "string" and type(other) == "table" then
			local entries = valid_entries(other.entries, dropped)
			if next(entries) then
				rec.other[id] = { entries = entries }
			end
		else
			dropped[1] = dropped[1] + 1
		end
	end
	if dropped[1] > 0 then
		self.log.warn("automations: %d malformed parts of the stored record dropped", dropped[1])
	end
	self.rec = rec
	self:check_bridge()
	return rec
end

-- D24: a record kept for another bridge is set aside, never acted on. When
-- the paired bridge's own record was set aside earlier (paired back), it is
-- taken back.
function automations:check_bridge()
	local id = self:bridge_id()
	local rec = self.rec
	if not id or rec.bridge_id == id then
		return false
	end
	if rec.bridge_id == nil then
		rec.bridge_id = id
		return false
	end
	local old = rec.bridge_id
	if next(rec.entries) then
		rec.other[old] = { entries = rec.entries }
		self.log.always("Hue automations: the record of bridge %s (%s) is set aside: this driver is paired with "
			.. "another bridge now", short_id(old), util.plural(count_of(rec.entries), "automation"))
	end
	local back = rec.other[id]
	rec.other[id] = nil
	rec.entries = back and back.entries or {}
	rec.kept, rec.refused, rec.bridge_id = {}, {}, id
	self:save()
	self.view = nil
	return true
end

-- The refusal mark of `rid`, when it holds on this firmware (D12).
function automations:refused(rid)
	local fw = self.rec.refused[rid]
	if fw == nil then
		return false
	end
	local current = self:firmware()
	return current == nil or fw == current
end

-- D12: a new firmware clears the marks made under another.
function automations:clear_refusals()
	local current = self:firmware()
	if not current then
		return false
	end
	local cleared = false
	for rid, fw in pairs(self.rec.refused) do
		if fw ~= current then
			self.rec.refused[rid] = nil
			cleared = true
		end
	end
	if cleared then
		self.log.info("automations: bridge firmware %s: the Hue app only marks of the earlier firmware cleared", current)
	end
	return cleared
end

-- An entry whose instance is gone from the bridge (D23): dropped, with one
-- log.always line, and listed on the row for the rest of this run.
function automations:drop_deleted(rid, how)
	local changed = false
	local entry = self.rec.entries[rid]
	if entry then
		self.rec.entries[rid] = nil
		self.deleted[#self.deleted + 1] = entry.name
		self.log.always("Hue automation %s, which Control4 disabled, was deleted in Hue (%s); Control4 forgot its record",
			entry.name, how)
		changed = true
	end
	if self.rec.kept[rid] then
		self.rec.kept[rid] = nil
		changed = true
	end
	if self.rec.refused[rid] then
		self.rec.refused[rid] = nil
		changed = true
	end
	return changed
end

-- The C4 lights an instance acts on now (rid set), for a keep.
function automations:c4_set(rid)
	local view = self:current_view()
	local v = view.by_rid[rid]
	local set = {}
	for _, light in ipairs(v and v.c4 or {}) do
		set[light] = true
	end
	return set, v
end

-- D10, D15: keep `rid` with the Control4 lights it acts on now (and those of
-- an earlier keep). Returns the view line it was kept from.
function automations:keep(rid, name)
	local set, v = self:c4_set(rid)
	local old = self.rec.kept[rid]
	for light in pairs(old and old.lights or {}) do
		set[light] = true
	end
	self.rec.kept[rid] = { name = name or (v and v.name) or rid, at = self:now(), lights = set }
	return v
end

-- A read of one instance (a full GET, a stream item with `enabled`, a click's
-- GET) against its entry (D13, D14). An entry whose click is still in flight
-- waits for the click. True when the record changed (saved here).
function automations:reconcile_entry(rid, inst)
	local entry = self.rec.entries[rid]
	if not entry or self.inflight[rid] or type(inst) ~= "table" or inst.enabled == nil then
		return false
	end
	local on = inst.enabled == true
	local changed = false
	if entry.state == "disabled" and on then
		-- D14: on again outside Control4; never disabled again by itself.
		entry.state, entry.on_again_at = "on_again", self:now()
		self.log.always("Hue automation %s, which Control4 disabled, was turned on again outside Control4",
			tostring(inst.name or entry.name))
		changed = true
	elseif entry.state == "on_again" and not on then
		entry.state, entry.on_again_at = "disabled", nil
		changed = true
	elseif entry.state == "pending" then
		if on then
			self.rec.entries[rid] = nil
			self.log.warn("automations: the disable of %s sent earlier did not take effect (the bridge shows it on); "
				.. "Control4 forgot it", entry.name)
		else
			entry.state = "disabled"
			self.log.info("automations: the disable of %s is confirmed", entry.name)
		end
		changed = true
	elseif entry.state == "restoring" then
		if on then
			self.rec.entries[rid] = nil
			self.view = nil
			if #self:kept_lights_after(rid) > 0 then
				self:keep(rid, inst.name)
			end
			self.log.info("automations: the restore of %s is confirmed", entry.name)
		else
			entry.state = "disabled"
		end
		changed = true
	end
	if changed then
		self.view = nil
		self:save()
	end
	return changed
end

-- Reads ------------------------------------------------------------------------------------------

local function new_instance(item)
	local ok, inst = pcall(model.instance, item)
	if ok and type(inst) == "table" and str(inst.rid) then
		return inst
	end
	return nil
end

local function new_script(item)
	local ok, s = pcall(model.script, item)
	if ok and type(s) == "table" and str(s.rid) then
		return s
	end
	return nil
end

-- True when an instance's script is known, or known to be unknown (H20).
function automations:classified(inst)
	local sid = inst.script_rid
	return sid == nil or self.scripts[sid] ~= nil or self.script_misses[sid] == true
end

function automations:scripts_wanted()
	if not self.scripts_read then
		return true
	end
	local fw = self:firmware()
	if fw and fw ~= self.scripts_fw then
		return true
	end
	for _, inst in pairs(self.instances) do
		if not self:classified(inst) then
			return true
		end
	end
	return false
end

-- GET behavior_script; done(ok, err).
function automations:read_scripts(done)
	local fw = self:firmware()
	self:request("GET", automations.PATH .. "behavior_script", nil, function(r)
		local data = data_of(r)
		if not data then
			local err = "GET behavior_script: " .. tostring(r.err or "malformed response")
			self.log.warn("automations: %s", err)
			return done(false, err)
		end
		local scripts = {}
		for _, item in ipairs(data) do
			if type(item) == "table" and (item.type == nil or item.type == "behavior_script") then
				local s = new_script(item)
				if s then
					scripts[s.rid] = s
				end
			end
		end
		self.scripts, self.scripts_read, self.scripts_fw = scripts, true, fw
		self.script_misses = {}
		for _, inst in pairs(self.instances) do
			if inst.script_rid and not scripts[inst.script_rid] then
				self.script_misses[inst.script_rid] = true
			end
		end
		self.view = nil
		done(true)
	end)
end

-- A successful GET behavior_instance: the cache replaced (an instance whose
-- `add` arrived after the GET was sent stays), entries reconciled, entries of
-- instances it lacks dropped (D23).
function automations:absorb_all(data, since)
	local fresh = {}
	for _, item in ipairs(data) do
		if type(item) == "table" and (item.type == nil or item.type == "behavior_instance") then
			local inst = new_instance(item)
			if inst then
				fresh[inst.rid] = inst
			end
		end
	end
	for rid, inst in pairs(self.instances) do
		if not fresh[rid] and (self.added_seq[rid] or -1) > since then
			fresh[rid] = inst
		end
	end
	self.instances = fresh
	self.read_at, self.read_failed = self:now(), false
	local changed = false
	for rid in pairs(copy(self.rec.entries)) do
		if not fresh[rid] then
			changed = self:drop_deleted(rid, "not listed by the bridge") or changed
		end
	end
	for rid in pairs(copy(self.rec.kept)) do
		if not fresh[rid] then
			changed = self:drop_deleted(rid, "not listed by the bridge") or changed
		end
	end
	for rid in pairs(copy(self.rec.refused)) do
		if not fresh[rid] then
			self.rec.refused[rid] = nil
			changed = true
		end
	end
	self.view = nil
	if changed then
		self:save()
	end
	for rid, inst in pairs(fresh) do
		self:reconcile_entry(rid, inst)
	end
end

function automations:resync_done(ok, err)
	local waiters = self.resync_waiters or {}
	self.resync_waiters = nil
	self.view = nil
	for _, done in ipairs(waiters) do
		self:protect("resync done", done, ok, err, 0)
	end
end

-- a:resync(done, tier): the GETs of D18, one at a time. A failed GET marks
-- nothing (D23, H26): the row says "as of" the last good read.
function automations:resync(done, tier)
	done = type(done) == "function" and done or function() end
	if tier == "quick" then
		self:protect("resync done", done, true, nil, 0)
		return
	end
	if self.resync_waiters then
		self.resync_waiters[#self.resync_waiters + 1] = done
		return
	end
	self.resync_waiters = { done }
	self:check_bridge()
	if self:clear_refusals() then
		self:save()
	end
	local since = self.seq
	self:request("GET", automations.PATH .. "behavior_instance", nil, function(r)
		local data = data_of(r)
		if not data then
			self.read_failed = true
			local err = "GET behavior_instance: " .. tostring(r.err or "malformed response")
			self.log.warn("automations: %s; nothing is marked deleted", err)
			return self:resync_done(false, err)
		end
		self:absorb_all(data, since)
		if not self:scripts_wanted() then
			return self:resync_done(true)
		end
		self:read_scripts(function(ok, err)
			self:resync_done(ok, err)
		end)
	end)
end

-- A stream item named a script not read yet: one script GET, from a timer
-- (never inside the stream's callback).
function automations:want_script(script_rid)
	if not script_rid or self.scripts[script_rid] or self.script_misses[script_rid] or self.script_timer then
		return
	end
	if type(self.ctx.set_timer) ~= "function" then
		self.log.debug("automations: script %s not read yet; the next full read reads it", tostring(script_rid))
		return
	end
	local ok, timer = pcall(self.ctx.set_timer, automations.SCRIPT_DELAY_MS, function()
		self:protect("script read", function()
			self.script_timer = nil
			if self.resync_waiters then
				return -- the resync reads them when it needs them
			end
			self:read_scripts(function()
				self:changed()
			end)
		end)
	end)
	self.script_timer = ok and (timer or true) or nil
end

function automations:on_instance_item(kind, item)
	local rid = item.id
	if kind == "delete" then
		local had = self.instances[rid] ~= nil
		self.instances[rid] = nil
		local changed = self:drop_deleted(rid, "a delete event")
		if changed then
			self:save()
		end
		return had or changed
	end
	local inst = self.instances[rid]
	if kind == "add" or not inst then
		if kind ~= "add" and not self.read_at then
			return false -- an update before the first read: the read brings it whole
		end
		inst = new_instance(item)
		if not inst then
			return false
		end
		self.instances[rid] = inst
		self.added_seq[rid] = self.seq
		self:want_script(inst.script_rid)
		self:reconcile_entry(rid, inst)
		return true
	end
	local name, sig = inst.name, inst.sig
	local ok, changed = pcall(model.update, inst, item)
	if not ok then
		self.log.warn("automations: update of %s: %s", tostring(rid), tostring(changed))
		changed = false
	end
	changed = changed or inst.name ~= name or inst.sig ~= sig
	if item.script_id ~= nil then
		self:want_script(inst.script_rid)
	end
	if item.enabled ~= nil and self:reconcile_entry(rid, inst) then
		changed = true
	end
	return changed and true or false
end

function automations:on_script_item(kind, item)
	local rid = item.id
	if kind == "delete" then
		local had = self.scripts[rid] ~= nil
		self.scripts[rid] = nil
		return had
	end
	local s = new_script(item)
	if not s then
		return false
	end
	local held = self.scripts[rid]
	if kind ~= "add" and held then
		if type(item.metadata) == "table" then
			held.name = s.name or held.name
			if item.metadata.category ~= nil then
				held.category = s.category
			end
		end
		if item.version ~= nil then
			held.version = s.version
		end
	else
		self.scripts[rid] = s
	end
	self.script_misses[rid] = nil
	return true
end

-- a:on_container(container): the behaviour items of one stream container.
-- Reads only; true when the row or Attention may change.
function automations:on_container(container)
	if type(container) ~= "table" or type(container.data) ~= "table" then
		return false
	end
	self.seq = self.seq + 1
	local ok, changed = pcall(function()
		local any = false
		for _, item in ipairs(container.data) do
			if type(item) == "table" and type(item.id) == "string" then
				if item.type == "behavior_instance" then
					any = self:on_instance_item(container.type, item) or any
				elseif item.type == "behavior_script" then
					any = self:on_script_item(container.type, item) or any
				end
			end
		end
		return any
	end)
	if not ok then
		self.log.error("automations: on_container failed: %s", tostring(changed))
		return false
	end
	if changed then
		self.view = nil
	end
	return changed
end

-- Evaluation (D3-D8, D10) -------------------------------------------------------------------------

function automations:control4()
	local c4 = call_ctx(self, "control4")
	c4 = type(c4) == "table" and c4 or {}
	local lights = type(c4.lights) == "table" and c4.lights or {}
	local via = type(c4.via) == "table" and c4.via or {}
	return { lights = lights, via = via }
end

function automations:expand(rid, rtype)
	if rtype == "light" then
		return { rid }
	end
	local lights = call_ctx(self, "expand", rid, rtype)
	return type(lights) == "table" and lights or {}
end

function automations:hue_name(rid)
	local name = call_ctx(self, "light_name", rid)
	return str(name) or tostring(rid)
end

-- D4: the lights an instance acts on, without the script's schema. found is
-- false when no reference is a target (can't tell which lights).
function automations:targets(inst)
	local lights, found = {}, false
	for _, ref in ipairs(type(inst.refs) == "table" and inst.refs or {}) do
		local rtype = type(ref) == "table" and ref.rtype or nil
		if rtype and not TRIGGERS[rtype] and TARGETS[rtype] and str(ref.rid) then
			local got = self:expand(ref.rid, rtype)
			-- A device with no light service is a trigger (a switch, a sensor).
			if rtype ~= "device" or #got > 0 then
				found = true
			end
			for _, light in ipairs(got) do
				if type(light) == "string" then
					lights[light] = true
				end
			end
		end
	end
	return lights, found
end

-- The Control4 lights (sorted by their names) and the others of a light set.
function automations:split(lights, c4)
	local mine, others = {}, {}
	for light in pairs(lights) do
		if c4.lights[light] ~= nil or c4.via[light] ~= nil then
			mine[#mine + 1] = { rid = light, name = str(c4.lights[light]) or self:hue_name(light) }
		else
			others[#others + 1] = { rid = light, name = self:hue_name(light) }
		end
	end
	table.sort(mine, by_name)
	table.sort(others, by_name)
	local c4_rids, c4_names, other_names = {}, {}, {}
	for i, l in ipairs(mine) do
		c4_rids[i], c4_names[i] = l.rid, l.name
	end
	for i, l in ipairs(others) do
		other_names[i] = l.name
	end
	return c4_rids, c4_names, other_names
end

local function model_call(fn, ...)
	local ok, value = pcall(fn, ...)
	if ok then
		return value
	end
	return nil
end

-- The Composer name of the Hue Motion device next to an area's or a sensor's automation (C4).
function automations:motion_device_of(inst)
	if type(self.ctx.motion_device) ~= "function" then
		return nil
	end
	for _, ref in ipairs(type(inst.refs) == "table" and inst.refs or {}) do
		if type(ref) == "table" and ref.where == "configuration"
				and (ref.rtype == "motion_area_configuration" or ref.rtype == "device") then
			local name = str(call_ctx(self, "motion_device", ref.rid))
			if name then
				return name
			end
		end
	end
	return nil
end

local ENTRY_GROUP = { pending = "pending", restoring = "pending", disabled = "disabled", on_again = "on_again" }

-- One instance (and its entry) classified for the row, Attention and the picker.
function automations:classify(rid, inst, c4)
	local entry = self.rec.entries[rid]
	local v = { rid = rid, inst = inst, entry = entry, name = str(inst.name) or (entry and entry.name) or rid }
	local known = self:classified(inst)
	local script = inst.script_rid and self.scripts[inst.script_rid] or nil
	v.kind = known and str(model_call(model.kind, inst, script)) or (entry and entry.kind) or "automation"
	local lights, found = self:targets(inst)
	v.c4, v.c4_names, v.other_names = self:split(lights, c4)
	v.found = found
	v.fires = known and model_call(model.fires, inst, script) or nil
	v.remedy = known and model_call(model.remedy, inst, script) or "steps"
	v.refused = self:refused(rid)
	if v.refused then
		v.remedy = "steps"
	end
	v.inert = model_call(model.inert, inst) == true
	v.device = self:motion_device_of(inst)
	if entry then
		v.group = ENTRY_GROUP[entry.state]
		return v
	end
	if not known then
		v.group = "unclassified"
	elseif v.fires == "none" then
		v.group = "entertainment"
	elseif v.fires == "safety" then
		v.group = "safety"
	elseif inst.enabled ~= true then
		v.group = "outside"
	elseif v.inert then
		v.group = "inert"
	elseif not found then
		v.group = "unknown_lights"
	elseif #v.c4 == 0 then
		v.group = "elsewhere"
	else
		local kept = self.rec.kept[rid]
		if kept then
			v.new_names = {}
			for i, light in ipairs(v.c4) do
				if not kept.lights[light] then
					v.new_names[#v.new_names + 1] = v.c4_names[i]
				end
			end
		end
		if kept and #v.new_names == 0 then
			v.group = "kept"
		elseif v.fires == "own" then
			v.group = "conflict"
		else
			v.group = "shared"
		end
	end
	return v
end

-- An entry whose instance is not in the cache (before the first read).
function automations.classify_entry(_self, rid, entry)
	return {
		rid = rid, entry = entry, name = entry.name, kind = entry.kind, group = ENTRY_GROUP[entry.state],
		c4 = {}, c4_names = entry.lights, other_names = {}, found = true, remedy = "steps", detached = true,
	}
end

-- a:evaluate(): every instance against ctx.control4() (D19: computed, never stored).
function automations:evaluate()
	self:check_bridge()
	local c4 = self:control4()
	local view = { by_rid = {}, groups = {}, entertainment = 0, on_bridge = 0 }
	for _, g in ipairs(GROUPS) do
		view.groups[g.key] = {}
	end
	local function add(v)
		view.by_rid[v.rid] = v
		if v.group == "entertainment" then
			view.entertainment = view.entertainment + 1
		elseif view.groups[v.group] then
			local list = view.groups[v.group]
			list[#list + 1] = v
		end
	end
	for rid, inst in pairs(self.instances) do
		view.on_bridge = view.on_bridge + 1
		local ok, v = pcall(self.classify, self, rid, inst, c4)
		if not ok then
			self.log.warn("automations: classifying %s failed: %s", tostring(rid), tostring(v))
			v = { rid = rid, inst = inst, name = str(inst.name) or rid, kind = "automation", group = "unclassified",
				c4 = {}, c4_names = {}, other_names = {}, remedy = "steps" }
		end
		add(v)
	end
	for rid, entry in pairs(self.rec.entries) do
		if not self.instances[rid] then
			add(self:classify_entry(rid, entry))
		end
	end
	for _, list in pairs(view.groups) do
		table.sort(list, by_name)
	end
	for _, v in ipairs(view.groups.conflict) do
		if not self.logged[v.rid] then
			self.logged[v.rid] = true
			self.log.always("Hue automation %s (%s) acts by itself on Control4 lights: %s", v.name, v.kind,
				util.some(v.c4_names, automations.MAX_NAMED))
		end
	end
	self.view = view
	return view
end

function automations:current_view()
	return self.view or self:evaluate()
end

-- The Control4 lights `rid` acts on now, for D15 (none when it does nothing).
function automations:kept_lights_after(rid)
	local v = self:current_view().by_rid[rid]
	if not v or v.inert or not v.inst or v.inst.enabled ~= true then
		return {}
	end
	return v.c4_names
end

-- The row (the contract §6.3) -----------------------------------------------------------------------

function automations:counts()
	local view = self:current_view()
	local g = view.groups
	local n = { bridge = view.on_bridge, disabled = 0, on_again = 0, unconfirmed = 0, kept = count_of(self.rec.kept) }
	n.c4 = #g.conflict + #g.shared + #g.kept
	for _, e in pairs(self.rec.entries) do
		if e.state == "disabled" then
			n.disabled = n.disabled + 1
		elseif e.state == "on_again" then
			n.on_again = n.on_again + 1
			n.c4 = n.c4 + 1
		else
			n.unconfirmed = n.unconfirmed + 1
		end
	end
	return n
end

local SUMMARY_WORDS = {
	{ c4 = "on Control4 lights", disabled = "disabled by Control4", unconfirmed = "not confirmed", as_of = " (as of %s)" },
	{ c4 = "on C4 lights", disabled = "off by C4", unconfirmed = "unconfirmed", as_of = " (as of %s)" },
	{ c4 = "on C4", disabled = "off", unconfirmed = "unconfirmed", as_of = " (%s)" },
}

-- a:summary(): "12 on bridge, 3 on Control4 lights, 2 disabled by Control4, 1 kept"; shorter words when
-- every count is shown and the full words would pass Composer's 75 characters.
function automations:summary()
	if not self:paired() then
		return "Not paired"
	end
	if not self.read_at then
		return "Not read yet"
	end
	local n = self:counts()
	local text
	for _, w in ipairs(SUMMARY_WORDS) do
		text = string.format("%d on bridge, %d %s, %d %s", n.bridge, n.c4, w.c4, n.disabled, w.disabled)
		if n.on_again > 0 then
			text = text .. string.format(", %d on again", n.on_again)
		end
		if n.unconfirmed > 0 then
			text = text .. string.format(", %d %s", n.unconfirmed, w.unconfirmed)
		end
		if n.kept > 0 then
			text = text .. string.format(", %d kept", n.kept)
		end
		if self.read_failed then
			text = text .. string.format(w.as_of, os.date("%H:%M", self.read_at))
		end
		if #text <= automations.SUMMARY_MAX then
			return text
		end
	end
	return text
end

-- The lights part of a line: Control4 lights by Composer name, then the others by Hue name.
local function line_lights(v)
	local names = {}
	for _, name in ipairs(v.c4_names or {}) do
		names[#names + 1] = name
	end
	for _, name in ipairs(v.other_names or {}) do
		names[#names + 1] = name
	end
	if #names == 0 then
		return ""
	end
	return " on " .. lights_text(names)
end

local function device_suffix(v)
	return v.device and string.format(" (Control4 device: %s)", v.device) or ""
end

function automations.line(_self, key, label, v)
	local head = string.format("%s: %s (%s)", label, v.name, v.kind)
	if key == "conflict" then
		local text
		if v.new_names then
			text = head .. string.format(" (kept; now also %s)", lights_text(v.new_names))
		else
			text = head .. line_lights(v)
		end
		return text .. (v.remedy == "steps" and " (Hue app only)" or "") .. device_suffix(v)
	elseif key == "disabled" then
		local text = string.format("%s %s: %s (%s)%s", label, util.short_date_of(v.entry.at), v.name, v.kind,
			line_lights(v))
		if not v.detached and #v.c4 == 0 then
			text = text .. "; no longer on Control4 lights"
		elseif v.inst and v.entry.sig and v.inst.sig ~= v.entry.sig then
			text = text .. "; changed in Hue since"
		end
		return text
	elseif key == "inert" then
		if v.kind == "MotionAware" then
			return string.format("%s: %s (MotionAware), Control4 decides", label, v.name) .. device_suffix(v)
		end
		return head .. device_suffix(v)
	elseif key == "unknown_lights" or key == "unclassified" then
		return head
	elseif key == "safety" then
		return string.format("%s: %s", label, v.name)
	end
	return head .. line_lights(v) .. device_suffix(v)
end

-- a:list_items(): the drop-down, one line per instance in the order of the contract §6.3.
function automations:list_items()
	local items = {}
	if not self:paired() and not self.read_at then
		return { automations.COVERAGE }
	end
	local view = self:current_view()
	for _, g in ipairs(GROUPS) do
		for _, v in ipairs(view.groups[g.key]) do
			items[#items + 1] = self:line(g.key, g.label, v)
		end
	end
	for _, name in ipairs(self.deleted) do
		items[#items + 1] = "Deleted in Hue since Control4 disabled it: " .. name
	end
	local others = {}
	for id in pairs(self.rec.other) do
		others[#others + 1] = id
	end
	table.sort(others)
	for _, id in ipairs(others) do
		items[#items + 1] = string.format("Bridge %s: %s Control4 disabled there", short_id(id),
			util.plural(count_of(self.rec.other[id].entries), "automation"))
	end
	if view.entertainment > 0 then
		items[#items + 1] = string.format("Not audited: %d entertainment %s", view.entertainment,
			view.entertainment == 1 and "setting" or "settings")
	end
	items[#items + 1] = automations.COVERAGE
	return items
end

-- Attention (the contract §6.4) ---------------------------------------------------------------------

local function names_of(list)
	local names = {}
	for i, v in ipairs(list) do
		names[i] = v.name
	end
	return names
end

function automations:attention_items()
	local items = {}
	if not self:paired() then
		return items
	end
	local view = self:current_view()
	local g = view.groups
	if #g.conflict > 0 then
		local n = #g.conflict
		items[#items + 1] = string.format("%s %s on Control4 lights: %s (Hue Automations)",
			util.plural(n, "Hue automation"), n == 1 and "acts" or "act", util.some(names_of(g.conflict), automations.MAX_NAMED))
	end
	if #g.on_again > 0 then
		local n = #g.on_again
		items[#items + 1] = string.format("%s Control4 disabled %s on again: %s (turned on outside Control4; "
			.. "Hue Automations)", util.plural(n, "Hue automation"), n == 1 and "is" or "are",
			util.some(names_of(g.on_again), automations.MAX_NAMED))
	end
	local late = {}
	local now = self:now()
	for _, v in ipairs(g.pending) do
		if v.entry and v.entry.at and now - v.entry.at >= automations.PENDING_ATTENTION_S then
			late[#late + 1] = v
		end
	end
	if #late > 0 then
		items[#items + 1] = string.format("%s not confirmed: %s (Hue Automations)",
			util.plural(#late, "Hue automation change"), util.some(names_of(late), automations.MAX_NAMED))
	end
	return items
end

-- C8, C9 ------------------------------------------------------------------------------------------

function automations:still_disabled()
	local names = {}
	for _, e in pairs(self.rec.entries) do
		if e.state ~= "on_again" then
			names[#names + 1] = e.name
		end
	end
	table.sort(names, function(a, b) return util.norm(a) < util.norm(b) end)
	return names
end

function automations:forget_pairing_text()
	local names = self:still_disabled()
	if #names == 0 then
		return nil
	end
	local one = #names == 1
	return string.format("Control4 still has %s disabled on this bridge: %s; pair again to restore %s, or turn %s on "
		.. "in the Hue app", util.plural(#names, "Hue automation"), util.some(names, automations.MAX_NAMED),
		one and "it" or "them", one and "it" or "them")
end

function automations:removal_text()
	local names = self:still_disabled()
	if #names == 0 then
		return nil
	end
	local one = #names == 1
	return string.format("The Hue Bridge driver was removed while Control4 had %s disabled on the bridge: %s. %s "
		.. "off; turn %s on in the Hue app", util.plural(#names, "Hue automation"), util.some(names, automations.MAX_NAMED),
		one and "It stays" or "They stay", one and "it" or "them")
end

-- The picker (the contract §6.2) --------------------------------------------------------------------

local function row(text, value)
	return { text = util.sanitise(text), value = value or "" }
end

local function folder(text, value)
	return { text = util.sanitise(text), value = value, folder = true }
end

-- The short lights part of a picker line: the first Control4 light, then +N.
local function picker_lights(v)
	local names = v.c4_names or {}
	if #names == 0 then
		return ""
	end
	return " on " .. names[1] .. (#names > 1 and string.format(" +%d", #names - 1) or "")
end

local DISABLE_GROUPS = { conflict = true, on_again = true, unknown_lights = true }

-- The lines of the Disable folder: conflicts, on again, can't tell, and the
-- Hue app only ones (conflicts and shared switches) last.
function automations:disable_lines()
	local g = self:current_view().groups
	local first, last = {}, {}
	for _, key in ipairs({ "conflict", "on_again", "unknown_lights", "shared" }) do
		for _, v in ipairs(g[key]) do
			if v.inst and v.inst.enabled == true then
				if v.remedy == "steps" then
					last[#last + 1] = v
				elseif key ~= "shared" then
					first[#first + 1] = v
				end
			end
		end
	end
	for _, v in ipairs(last) do
		first[#first + 1] = v
	end
	return first
end

function automations.disable_text(_self, v)
	local text = string.format("%s (%s)%s", v.name, v.kind, picker_lights(v))
	if #(v.other_names or {}) > 0 and #(v.c4_names or {}) > 0 then
		text = text .. string.format("; also %s outside Control4", util.plural(#v.other_names, "light"))
	end
	if v.group == "unknown_lights" then
		text = text .. " (can't tell which lights)"
	elseif v.group == "on_again" then
		text = text .. " (on again outside Control4)"
	end
	if v.remedy == "steps" then
		text = text .. " (Hue app only)"
	end
	return text
end

-- What `off:all` covers: class Disable conflicts and on again entries (R5).
function automations:bulk_disable()
	local list = {}
	for _, v in ipairs(self:disable_lines()) do
		if v.remedy == "disable" and (v.group == "conflict" or v.group == "on_again") then
			list[#list + 1] = v
		end
	end
	return list
end

function automations:restore_lines()
	local g = self:current_view().groups
	local list = {}
	for _, key in ipairs({ "on_again", "pending", "disabled" }) do
		for _, v in ipairs(g[key]) do
			list[#list + 1] = v
		end
	end
	table.sort(list, by_name)
	return list
end

function automations:other_lines()
	local list = {}
	for _, v in ipairs(self:current_view().groups.outside) do
		if v.remedy == "disable" then
			list[#list + 1] = v
		end
	end
	return list
end

function automations:keep_lines()
	local g = self:current_view().groups
	local list = {}
	for _, key in ipairs({ "conflict", "on_again", "shared" }) do
		for _, v in ipairs(g[key]) do
			if v.inst then
				list[#list + 1] = v
			end
		end
	end
	return list
end

function automations:unkeep_lines()
	local list = {}
	for rid, k in pairs(self.rec.kept) do
		local inst = self.instances[rid]
		list[#list + 1] = { rid = rid, name = inst and str(inst.name) or k.name, at = k.at }
	end
	table.sort(list, by_name)
	return list
end

function automations.restore_text(_self, v)
	local e = v.entry
	if e.state == "on_again" then
		return string.format("%s (on again outside Control4: forgets the record)", v.name)
	elseif e.state == "pending" or e.state == "restoring" then
		return string.format("%s (not confirmed since %s)", v.name, util.short_date_of(e.at))
	end
	local text = string.format("%s (disabled %s", v.name, util.short_date_of(e.at))
	if not v.detached and #v.c4 == 0 then
		text = text .. "; no longer on Control4 lights"
	elseif v.inst and e.sig and v.inst.sig ~= e.sig then
		text = text .. "; changed in Hue since"
	end
	return text .. ")"
end

function automations:top_list()
	if not self:paired() then
		return { row(automations.NOT_PAIRED) }
	end
	if not self.read_at then
		return { row(automations.NOT_READ) }
	end
	local list = {}
	local off = self:disable_lines()
	if #off > 0 then
		local on_c4 = 0
		for _, v in ipairs(off) do
			if #v.c4 > 0 then
				on_c4 = on_c4 + 1
			end
		end
		list[#list + 1] = folder(on_c4 > 0 and string.format("Disable in Hue (%d on Control4 lights)", on_c4)
			or string.format("Disable in Hue (%d can't tell which lights)", #off), "f:off")
	end
	local restore, other = self:restore_lines(), self:other_lines()
	if #restore + #other + count_of(self.rec.other) > 0 then
		list[#list + 1] = folder(string.format("Restore (%d disabled by Control4)", #restore), "f:on")
	end
	local keep = self:keep_lines()
	if #keep > 0 then
		list[#list + 1] = folder(string.format("Keep on the Hue side (%d)", #keep), "f:keep")
	end
	local unkeep = self:unkeep_lines()
	if #unkeep > 0 then
		list[#list + 1] = folder(string.format("Stop keeping (%d)", #unkeep), "f:unkeep")
	end
	if #list == 0 then
		list[1] = row(automations.NOTHING)
	end
	return list
end

function automations:folder_list(key)
	if key == "f:off" then
		local list, bulk = {}, self:bulk_disable()
		if #bulk > 1 then
			list[1] = row(string.format("Every one Control4 can disable (%d)", #bulk), "off:all")
		end
		for _, v in ipairs(self:disable_lines()) do
			list[#list + 1] = row(self:disable_text(v), "off:" .. v.rid)
		end
		return list, ""
	elseif key == "f:on" then
		local list, restore = {}, self:restore_lines()
		if #restore > 1 then
			list[1] = row(string.format("Everything Control4 disabled (%d)", #restore), "on:all")
		end
		for _, v in ipairs(restore) do
			list[#list + 1] = row(self:restore_text(v), "on:" .. v.rid)
		end
		local other = self:other_lines()
		if #other > 0 then
			list[#list + 1] = folder(string.format("Disabled outside Control4 (%d)", #other), "f:on:other")
		end
		local ids = {}
		for id in pairs(self.rec.other) do
			ids[#ids + 1] = id
		end
		table.sort(ids)
		for _, id in ipairs(ids) do
			list[#list + 1] = row(string.format("Forget the record of bridge %s (%s)", short_id(id),
				util.plural(count_of(self.rec.other[id].entries), "automation")), "forget:" .. id)
		end
		return list, ""
	elseif key == "f:on:other" then
		local list = {}
		for _, v in ipairs(self:other_lines()) do
			list[#list + 1] = row(string.format("%s (%s; not disabled by Control4)", v.name, v.kind), "other:" .. v.rid)
		end
		return list, "f:on"
	elseif key == "f:keep" then
		local list, keep = {}, self:keep_lines()
		local shared = self:current_view().groups.shared
		if #shared > 1 then
			list[1] = row(string.format("Every Hue switch and timer listed (%d)", #shared), "keep:shared")
		end
		for _, v in ipairs(keep) do
			list[#list + 1] = row(string.format("%s (%s)%s", v.name, v.kind, picker_lights(v)), "keep:" .. v.rid)
		end
		return list, ""
	elseif key == "f:unkeep" then
		local list = {}
		for _, k in ipairs(self:unkeep_lines()) do
			list[#list + 1] = row(string.format("%s (kept %s)", k.name, util.short_date_of(k.at)), "unkeep:" .. k.rid)
		end
		return list, ""
	end
	return nil
end

-- a:picker(folder) -> list, back. A list inside a folder starts with a
-- labelled Back row (as bridge/actions.lua's, docs/simplify-actions-design.md
-- §4 finding 14); a folder whose list would be empty is left out.
function automations:picker(folder_value)
	self.view = nil
	local key = type(folder_value) == "string" and folder_value or ""
	if key ~= "" and key ~= automations.TOP and self:paired() and self.read_at then
		local list, back = self:folder_list(key)
		if list and #list > 0 then
			local label = back == "f:on" and folder("Back to Restore", "f:on")
				or folder("Back to all folders", automations.TOP)
			table.insert(list, 1, label)
			return list, back
		end
	end
	return self:top_list(), nil
end

-- The action (the contract §6.2, §6.5, R1-R10) ------------------------------------------------------

function automations.steps_text(_self, v)
	local name, kind = v.name, v.kind
	if kind == "MotionAware" then
		return string.format("%s is a MotionAware set-up the bridge does not let other apps switch off. In the Hue app "
			.. "open the area's automation, keep one time slot for the whole day, set On motion to Do nothing and When "
			.. "motion stops to Do nothing, and save. Do not switch the area off or remove its automation: the area "
			.. "would stop reporting motion to Control4.", name)
	elseif kind == "motion sensor" or kind == "contact sensor" then
		return string.format("%s's behaviour is a sensor set-up. In the Hue app open the sensor, set every time slot to "
			.. "Do nothing on motion and when motion stops, and save. Leave the sensor on: Control4 reads its motion.", name)
	elseif kind == "Hue switch" then
		return string.format("%s is a Hue switch. To stop it moving Control4 lights, open it in the Hue app and point "
			.. "its buttons elsewhere, or reset it and set it up in another app. Or keep it (Hue Automations ▸ Keep on "
			.. "the Hue side).", name)
	elseif kind == "mimic presence" then
		return string.format("%s is started and stopped in the Hue app: Automations, %s, stop.", name, name)
	elseif v.refused then
		return string.format("Not disabled: %s: the bridge refused this on its current firmware before (Hue app only); "
			.. "nothing was changed. In the Hue app: Automations, %s, switch it off.", name, name)
	end
	return string.format("%s is a kind of Hue automation this driver does not switch off. Change or switch it off in "
		.. "the Hue app, where it is listed under its room.", name)
end

-- The words of a refusal: the HTTP status, and the bridge's description when it is plain (R3).
local function refusal_words(r)
	local words = string.format("HTTP %s", tostring(r.code))
	local errors = type(r.json) == "table" and r.json.errors or nil
	local first = type(errors) == "table" and errors[1] or nil
	local description = type(first) == "table" and first.description or nil
	if type(description) == "string" and #description <= 80 and description:match("^[%w][%w %.,:'_/%-]*$") then
		words = words .. ": " .. description
	end
	return words
end

local function first_item(r)
	local data = data_of(r)
	return data and type(data[1]) == "table" and data[1] or nil
end

-- What a non-2xx answer means for a click: "deleted", "key", "busy", "refused" or "unknown".
local function answer_kind(r)
	local code = r.code
	if code == 404 then
		return "deleted"
	elseif code == 401 or code == 403 then
		return "key"
	elseif code == 429 then
		return "busy"
	elseif type(code) == "number" and code >= 400 and code < 500 then
		return "refused"
	end
	return "unknown"
end

-- A click's fresh GET of one instance; then(inst) with the cache updated, or
-- fail(kind, r) with kind "deleted", "key" or "unknown".
function automations:fresh(rid, then_fn, fail)
	self:request("GET", automations.PATH .. "behavior_instance/" .. rid, nil, function(r)
		local item = first_item(r)
		local inst = item and new_instance(item)
		if inst then
			self.instances[rid] = inst
			self:reconcile_entry(rid, inst)
			self.view = nil
			return then_fn(inst)
		end
		local kind = r.ok and "unknown" or answer_kind(r)
		if kind == "deleted" then
			self.instances[rid] = nil
			if self:drop_deleted(rid, "the bridge answered 404") then
				self:save()
			end
			self.view = nil
		end
		fail(kind, r)
	end)
end

function automations:put(rid, enabled, cb)
	call_ctx(self, "wrote")
	self:request("PUT", automations.PATH .. "behavior_instance/" .. rid, { enabled = enabled }, cb)
end

-- "Hall timer (was Hallway timer)" (H5).
local function name_was(name, old)
	if old and old ~= name then
		return string.format("%s (was %s)", name, old)
	end
	return name
end

local FAIL_TEXT = {
	deleted = { "%s %s: it is no longer on the bridge; nothing was changed.", "no longer on the bridge" },
	key = { "%s: the bridge rejected the key; nothing was changed.", "the bridge rejected the key" },
	unknown = { "%s: " .. automations.NOT_ANSWERING, "the bridge is not answering" },
	busy = { "%s: the bridge is busy (HTTP 429); nothing was changed; try again in a moment.", "the bridge is busy" },
}

-- A failed click's result: verb "Not disabled" / "Not restored" / "Not turned on".
local function failed(verb, kind, name)
	local t = FAIL_TEXT[kind] or FAIL_TEXT.unknown
	local text = kind == "deleted" and string.format(t[1], verb, name) or string.format(t[1], verb)
	return { ok = false, text = text, reason = t[2], stop = kind == "unknown" or kind == "key", name = name }
end

-- R1-R4 for one instance; done(result) with result { ok, name, text, reason, stop }.
function automations:disable_one(rid, done)
	local v = self:current_view().by_rid[rid]
	if not v or not v.inst then
		return done({ ok = false, name = v and v.name or rid, reason = "no longer on the bridge",
			text = "Not disabled: that Hue automation is not on the bridge now; nothing was changed." })
	end
	local function precheck(view_line)
		local name = view_line.name
		if view_line.group == "unclassified" then
			return { ok = false, name = name, reason = "not classified yet",
				text = string.format("Not disabled: %s is not classified yet; nothing was changed; try again in a moment.",
					name) }
		end
		if view_line.remedy == "steps" then
			return { ok = false, name = name, reason = "Hue app only; open it again for the steps", steps = true,
				text = self:steps_text(view_line) }
		end
		if not DISABLE_GROUPS[view_line.group] then
			return { ok = false, name = name, reason = "no longer acts by itself on Control4 lights",
				text = string.format("Not disabled: %s no longer acts by itself on Control4 lights; nothing was changed.",
					name) }
		end
		return nil
	end
	local early = precheck(v)
	if early then
		return done(early)
	end
	self:fresh(rid, function(inst)
		local now_v = self:current_view().by_rid[rid] or v
		local name = now_v.name
		if inst.enabled ~= true then
			return done({ ok = false, name = name, reason = "already disabled",
				text = string.format("Not disabled: %s is already disabled in Hue; nothing was changed.", name) })
		end
		local refuse = precheck(now_v)
		if refuse then
			return done(refuse)
		end
		-- D13: the entry is persisted before the PUT.
		self.rec.entries[rid] = { state = "pending", name = name, kind = now_v.kind, script_rid = inst.script_rid,
			lights = copy(now_v.c4_names), sig = inst.sig, at = self:now() }
		self.inflight[rid] = true
		self:save()
		self:put(rid, false, function(r)
			self:disable_answered(rid, now_v, r, done)
		end)
	end, function(kind)
		done(failed("Not disabled", kind, v.name))
	end)
end

function automations:disable_answered(rid, v, r, done)
	local name = v.name
	local entry = self.rec.entries[rid]
	if not r.ok then
		local kind = answer_kind(r)
		if kind == "unknown" then
			-- R4: no answer; the entry stays pending for the next read.
			self.inflight[rid] = nil
			return done({ ok = false, name = name, reason = "not confirmed", stop = true,
				text = string.format("Disable of %s not confirmed; Control4 checks again when the bridge answers.", name) })
		end
		self.rec.entries[rid] = nil
		self.inflight[rid] = nil
		if kind == "refused" then
			-- R3, D12.
			self.rec.refused[rid] = self:firmware() or "?"
			self:save()
			self.view = nil
			local words = refusal_words(r)
			return done({ ok = false, name = name, reason = "refused (" .. words .. ")",
				text = string.format("Not disabled: %s: the bridge refused (%s); nothing was changed. In the Hue app: "
					.. "Automations, %s, switch it off.", name, words, name) })
		end
		self:save()
		if kind == "deleted" then
			self.instances[rid] = nil
			self.view = nil
		end
		return done(failed("Not disabled", kind, name))
	end
	self:request("GET", automations.PATH .. "behavior_instance/" .. rid, nil, function(back)
		self.inflight[rid] = nil
		local item = first_item(back)
		local inst = item and new_instance(item)
		if not inst then
			if back.code == 404 then
				self.instances[rid] = nil
				self.rec.entries[rid] = nil
				self:save()
				self.view = nil
				return done(failed("Not disabled", "deleted", name))
			end
			return done({ ok = false, name = name, reason = "not confirmed", stop = true,
				text = string.format("Disable of %s not confirmed; Control4 checks again when the bridge answers.", name) })
		end
		self.instances[rid] = inst
		self.view = nil
		if inst.enabled == false then
			entry = self.rec.entries[rid] or entry
			entry.state = "disabled"
			self.rec.entries[rid] = entry
			self:save()
			local text = string.format("Disabled in Hue: %s. It stays on the bridge and shows as off in the Hue app; Hue "
				.. "Automations ▸ Restore turns it on again.", name)
			if #(v.other_names or {}) > 0 then
				-- H12: what else stops following it.
				text = text .. string.format(" It also controlled %s, which Control4 does not control: they no longer "
					.. "follow it either.", and_list(v.other_names))
			end
			return done({ ok = true, name = name, text = text })
		end
		-- R2: accepted, not applied.
		self.rec.entries[rid] = nil
		self.rec.refused[rid] = self:firmware() or "?"
		self:save()
		done({ ok = false, name = name, reason = "accepted but not applied (Hue app only)",
			text = string.format("Not disabled: %s: the bridge accepted the change but did not apply it; nothing was "
				.. "changed. In the Hue app: Automations, %s, switch it off.", name, name) })
	end)
end

-- " It acts on Bedroom Lamp and 2 more Control4 lights, so it is now kept (…)" (D15), or "".
local function kept_sentence(names)
	if #names == 0 then
		return ""
	end
	local lights = #names == 1 and string.format("%s, a Control4 light", names[1])
		or string.format("%s and %d more Control4 lights", names[1], #names - 1)
	return string.format(" It acts on %s, so it is now kept (Hue Automations ▸ Stop keeping lists it again).", lights)
end

-- The R7 sentence: what changed in Hue while Control4 had it off.
function automations.changed_sentence(_self, entry, inst, now_names)
	local parts = {}
	if inst.name and entry.name and inst.name ~= entry.name then
		parts[#parts + 1] = "its name"
	end
	local before, after = table.concat(entry.lights or {}, "\n"), table.concat(now_names or {}, "\n")
	if before ~= after then
		parts[#parts + 1] = "its lights"
	end
	if #parts == 0 and entry.sig and inst.sig and entry.sig ~= inst.sig then
		parts[1] = "its settings"
	end
	if #parts == 0 then
		return ""
	end
	return string.format(" It changed in Hue while it was off (%s); it is on as it is now.", table.concat(parts, " and "))
end

-- After a successful turn-on: kept when it still acts on Control4 lights (D15).
function automations:keep_after_on(rid, name)
	self.view = nil
	local names = self:kept_lights_after(rid)
	if #names > 0 then
		self:keep(rid, name)
		self.view = nil
	end
	return names
end

-- R6, R7 for one entry; done(result).
function automations:restore_one(rid, done)
	local entry = self.rec.entries[rid]
	if not entry then
		return done({ ok = false, name = rid, reason = "no record",
			text = "Nothing to restore: Control4 has no record of that Hue automation." })
	end
	local old = copy(entry)
	self:fresh(rid, function(inst)
		local name = str(inst.name) or old.name
		local shown = name_was(name, old.name)
		entry = self.rec.entries[rid]
		if inst.enabled == true then
			self.rec.entries[rid] = nil
			local names = self:keep_after_on(rid, name)
			self:save()
			return done({ ok = true, name = name, already = true,
				text = string.format("%s is already on in Hue; Control4 forgot its record.%s", shown, kept_sentence(names)) })
		end
		entry = entry or old
		entry.state = "restoring"
		self.rec.entries[rid] = entry
		self.inflight[rid] = true
		self:save()
		self:put(rid, true, function(r)
			self:restore_answered(rid, old, r, done)
		end)
	end, function(kind)
		if kind == "deleted" then
			return done({ ok = false, name = old.name, reason = "deleted in Hue",
				text = string.format("Nothing to restore: %s is no longer on the bridge; Control4 forgot its record.",
					old.name) })
		end
		done(failed("Not restored", kind, old.name))
	end)
end

function automations:back_to_disabled(rid)
	local entry = self.rec.entries[rid]
	if entry then
		entry.state = "disabled"
	end
	self.inflight[rid] = nil
	self:save()
	self.view = nil
end

function automations:restore_answered(rid, old, r, done)
	local name = old.name
	if not r.ok then
		local kind = answer_kind(r)
		if kind == "unknown" then
			self.inflight[rid] = nil
			return done({ ok = false, name = name, reason = "not confirmed", stop = true,
				text = string.format("Restore of %s not confirmed; Control4 checks again when the bridge answers.", name) })
		elseif kind == "deleted" then
			self.inflight[rid] = nil
			self.instances[rid] = nil
			self.rec.entries[rid] = nil
			self:save()
			self.view = nil
			return done({ ok = false, name = name, reason = "deleted in Hue",
				text = string.format("Nothing to restore: %s is no longer on the bridge; Control4 forgot its record.", name) })
		end
		self:back_to_disabled(rid)
		if kind == "refused" then
			local words = refusal_words(r)
			return done({ ok = false, name = name, reason = "refused (" .. words .. ")",
				text = string.format("Not restored: %s: the bridge refused (%s); it stays disabled. In the Hue app: "
					.. "Automations, %s, switch it on.", name, words, name) })
		end
		return done(failed("Not restored", kind, name))
	end
	self:request("GET", automations.PATH .. "behavior_instance/" .. rid, nil, function(back)
		self.inflight[rid] = nil
		local item = first_item(back)
		local inst = item and new_instance(item)
		if not inst then
			return done({ ok = false, name = name, reason = "not confirmed", stop = true,
				text = string.format("Restore of %s not confirmed; Control4 checks again when the bridge answers.", name) })
		end
		self.instances[rid] = inst
		self.view = nil
		local now_name = str(inst.name) or name
		if inst.enabled == true then
			self.rec.entries[rid] = nil
			local names = self:keep_after_on(rid, now_name)
			local current = self:current_view().by_rid[rid]
			self:save()
			local text = string.format("Turned on again in Hue: %s (disabled by Control4 since %s).",
				name_was(now_name, old.name), util.short_date_of(old.at))
			text = text .. self:changed_sentence(old, inst, current and current.c4_names or names)
			return done({ ok = true, name = now_name, text = text .. kept_sentence(names), kept = #names > 0 })
		end
		self:back_to_disabled(rid)
		done({ ok = false, name = now_name, reason = "accepted but not applied",
			text = string.format("Not restored: %s: the bridge accepted the change but did not apply it; it stays disabled. "
				.. "In the Hue app: Automations, %s, switch it on.", now_name, now_name) })
	end)
end

-- D16: turn on an automation disabled outside Control4 (no entry needed).
function automations:turn_on_other(rid, done)
	local v = self:current_view().by_rid[rid]
	if not v or not v.inst or v.group ~= "outside" or v.remedy ~= "disable" then
		return done({ ok = false, text = "Not turned on: that is not a Hue automation disabled outside Control4 that "
			.. "Control4 can turn on; nothing was changed." })
	end
	local name = v.name
	self:fresh(rid, function(inst)
		if inst.enabled == true then
			return done({ ok = false, text = string.format("Not turned on: %s is already on in Hue; nothing was changed.",
				name) })
		end
		self:put(rid, true, function(r)
			if not r.ok then
				local kind = answer_kind(r)
				if kind == "refused" then
					return done({ ok = false, text = string.format("Not turned on: %s: the bridge refused (%s); it stays "
						.. "disabled. In the Hue app: Automations, %s, switch it on.", name, refusal_words(r), name) })
				end
				return done(failed("Not turned on", kind, name))
			end
			self:request("GET", automations.PATH .. "behavior_instance/" .. rid, nil, function(back)
				local item = first_item(back)
				local now_inst = item and new_instance(item)
				if not now_inst then
					return done({ ok = false, text = string.format("Turning on %s not confirmed; the row shows it once the "
						.. "bridge answers.", name) })
				end
				self.instances[rid] = now_inst
				self.view = nil
				if now_inst.enabled ~= true then
					return done({ ok = false, text = string.format("Not turned on: %s: the bridge accepted the change but did "
						.. "not apply it; it stays disabled. In the Hue app: Automations, %s, switch it on.", name, name) })
				end
				local names = self:keep_after_on(rid, name)
				self:save()
				done({ ok = true, text = string.format("Turned on again in Hue: %s (it was not disabled by Control4).%s",
					name, kept_sentence(names)) })
			end)
		end)
	end, function(kind)
		done(failed("Not turned on", kind, name))
	end)
end

-- R5 and on:all: one at a time, no rollback; a bridge that stops answering
-- ends the run, the rest reported as not tried.
function automations:each(rids, fn, done)
	local results, i = {}, 0
	local step
	step = function()
		i = i + 1
		local rid = rids[i]
		if not rid then
			return done(results)
		end
		fn(self, rid, function(result)
			results[#results + 1] = result
			if result.stop then
				for j = i + 1, #rids do
					local v = self:current_view().by_rid[rids[j]]
					results[#results + 1] = { ok = false, name = v and v.name or rids[j], reason = "not tried" }
				end
				return done(results)
			end
			step()
		end)
	end
	step()
end

local function bulk_text(results, verb_done, verb_not, noun_after)
	local ok_names, bad = {}, {}
	for _, r in ipairs(results) do
		if r.ok then
			ok_names[#ok_names + 1] = r.name
		else
			bad[#bad + 1] = string.format("%s (%s)", tostring(r.name), tostring(r.reason))
		end
	end
	local text = string.format("%s %d of %s", verb_done, #ok_names, util.plural(#results, "Hue automation"))
	if #ok_names > 0 then
		text = text .. ": " .. table.concat(ok_names, ", ")
	end
	text = text .. "."
	if #bad > 0 then
		text = text .. string.format(" %s: %s.", verb_not, table.concat(bad, ", "))
	end
	return text .. (noun_after or "")
end

function automations:run_disable_all(finish)
	local rids, steps = {}, {}
	for _, v in ipairs(self:bulk_disable()) do
		rids[#rids + 1] = v.rid
	end
	for _, v in ipairs(self:current_view().groups.conflict) do
		if v.remedy == "steps" then
			steps[#steps + 1] = { ok = false, name = v.name, reason = "Hue app only; open it again for the steps" }
		end
	end
	if #rids + #steps == 0 then
		return finish("Not changed: no Hue automation on Control4 lights for Control4 to disable.")
	end
	self:each(rids, automations.disable_one, function(results)
		for _, s in ipairs(steps) do
			results[#results + 1] = s
		end
		local text = bulk_text(results, "Disabled", "Not disabled",
			#rids > 0 and " Hue Automations ▸ Restore turns them on again." or nil)
		finish(text)
	end)
end

function automations:run_restore_all(finish)
	local list = self:restore_lines()
	if #list == 0 then
		return finish("Nothing to restore: Control4 has disabled no Hue automation.")
	end
	local rids = {}
	for i, v in ipairs(list) do
		rids[i] = v.rid
	end
	self:each(rids, automations.restore_one, function(results)
		local kept = {}
		for _, r in ipairs(results) do
			if r.ok and r.kept then
				kept[#kept + 1] = r.name
			end
		end
		local after = #kept > 0 and string.format(" Kept on the Hue side because they act on Control4 lights: %s "
			.. "(Hue Automations ▸ Stop keeping lists them again).", table.concat(kept, ", ")) or nil
		finish(bulk_text(results, "Turned on again", "Not restored", after))
	end)
end

function automations:run_keep(rid)
	local view = self:current_view()
	local v = view.by_rid[rid]
	if not v or not v.inst or not (v.group == "conflict" or v.group == "shared" or v.group == "on_again") then
		return "Not changed: that Hue automation is not one to keep; open the list again."
	end
	if self.rec.entries[rid] then
		self.rec.entries[rid] = nil -- H6: Keep drops the entry
	end
	self:keep(rid, v.name)
	self:save()
	self.view = nil
	return string.format("Kept %s on the Hue side: Attention no longer lists it unless it starts acting on other "
		.. "Control4 lights.", v.name)
end

function automations:run_keep_shared()
	local shared = self:current_view().groups.shared
	if #shared == 0 then
		return "Not changed: no Hue switch or timer is listed."
	end
	local names = {}
	for _, v in ipairs(shared) do
		self:keep(v.rid, v.name)
		names[#names + 1] = v.name
	end
	self:save()
	self.view = nil
	return string.format("Kept %s on the Hue side: %s. Attention does not list them unless they start acting on other "
		.. "Control4 lights.", util.plural(#names, "Hue automation"), util.some(names, automations.MAX_NAMED))
end

function automations:run_unkeep(rid)
	local k = self.rec.kept[rid]
	if not k then
		return "Not changed: that Hue automation is not kept; open the list again."
	end
	local inst = self.instances[rid]
	local name = inst and str(inst.name) or k.name
	self.rec.kept[rid] = nil
	self:save()
	self.view = nil
	return string.format("Stopped keeping %s: it is listed again while it acts on Control4 lights.", name)
end

function automations:run_forget(id)
	local other = self.rec.other[id]
	if not other then
		return "Not changed: there is no record of that bridge; open the list again."
	end
	local n = count_of(other.entries)
	self.rec.other[id] = nil
	self:save()
	self.view = nil
	self.log.always("Hue automations: the record of bridge %s (%s) forgotten", short_id(id),
		util.plural(n, "automation"))
	return string.format("Forgot the record of bridge %s (%s); nothing was changed in Hue.", short_id(id),
		util.plural(n, "automation"))
end

-- Runs the write a click names (off:, on:, other:); false when the value is none of them.
function automations:dispatch(value, finish)
	local rid = value:match("^off:(.+)$")
	if value == "off:all" then
		self:run_disable_all(finish)
	elseif rid then
		self:disable_one(rid, function(r) finish(r.text) end)
	elseif value == "on:all" then
		self:run_restore_all(finish)
	elseif value:match("^on:(.+)$") then
		self:restore_one(value:match("^on:(.+)$"), function(r) finish(r.text) end)
	elseif value:match("^other:(.+)$") then
		self:turn_on_other(value:match("^other:(.+)$"), function(r) finish(r.text) end)
	else
		return false
	end
	return true
end

local WRITES = { ["off:"] = true, ["on:"] = true, ["other:"] = true }

-- a:run(params): the Hue Automations action. Every outcome ends in Last Action.
function automations:run(params)
	local value = type(params) == "table" and params.Automation or nil
	value = value ~= nil and tostring(value) or ""
	local ok, err = pcall(self.run_value, self, value)
	if not ok then
		self.writing = false
		self.log.error("automations: Hue Automations %q failed: %s", value, tostring(err))
		self:say("Not changed: the action failed; see the Lua output")
		self:changed()
	end
end

function automations:run_value(value)
	self.log.info("automations: Hue Automations %q", value)
	self.view = nil
	if value == "" then
		local list = self:top_list()
		if #list == 1 and list[1].value == "" then
			return self:say(list[1].text)
		end
		return self:say("Not changed: pick a Hue automation in the list")
	end
	local folder_name = automations.FOLDERS[value]
	if folder_name then
		return self:say(string.format("Not changed: %s is a folder; open it and pick one inside", folder_name))
	end
	local busy = str(call_ctx(self, "busy"))
	if busy then
		return self:say(busy)
	end
	if self.writing and self:now() - self.writing > automations.CLICK_MAX_S then
		self.log.warn("automations: a click of %d s ago never finished; the next one may run", self:now() - self.writing)
		self.writing = false
	end
	if self.writing then
		return self:say("Busy: changing a Hue automation; try again in a moment")
	end
	local prefix = value:match("^(%a+:)")
	if WRITES[prefix] then
		if not self:paired() then
			return self:say("Not paired; nothing was changed.")
		end
		self.writing = self:now()
		local answered = false
		local function finish(text)
			if answered then
				return
			end
			answered = true
			self.writing = false
			self:say(text)
			self:changed()
		end
		if not self:dispatch(value, finish) then
			finish(string.format("Not changed: %q is not a choice of this list; open it again", value))
		end
		return
	end
	local text
	local rid = value:match("^keep:(.+)$")
	if value == "keep:shared" then
		text = self:run_keep_shared()
	elseif rid then
		text = self:run_keep(rid)
	else
		rid = value:match("^unkeep:(.+)$")
		local id = value:match("^forget:(.+)$")
		if rid then
			text = self:run_unkeep(rid)
		elseif id then
			text = self:run_forget(id)
		else
			text = string.format("Not changed: %q is not a choice of this list; open it again", value)
		end
	end
	self:say(text)
	self:changed()
end

return automations
