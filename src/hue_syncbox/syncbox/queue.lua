-- One queue of writes to the Hue Play HDMI Sync Box's execution (#557,
-- docs/hdmi-sync-stage3-design.md §3, contracts C3 and C4 in
-- docs/hdmi-sync-contracts.md): everything that changes the box's power,
-- input or sync (Director's routing through syncbox/av.lua, Follow Room
-- through syncbox/follow.lua) goes through here, so the box gets one PUT
-- at a time, a burst becomes one PUT with the latest values, and a caller
-- hears that its write is done only when a read of the box shows it.
--
--   local q = queue.new{ client, poller, timer, now, log, on_done }
--   q:set(fields, tag[, cb])  merges `fields` (execution fields by the box's
--                    names, below) into the pending write, the latest value
--                    winning, and sends it COALESCE_MS later; true, or false
--                    and why for a field the queue does not take
--   q:flush()        sends the pending write now (one PUT /execution); while
--                    a PUT is in flight the next goes after its answer
--   q:observe(model) every good read (syncbox/state.lua's model): each write
--                    whose fields the read shows is done (syncbox/av.lua's
--                    a:confirm calls it; call it once per read)
--   q:clear(why)     every waiting write ends with `why` (default
--                    "cancelled"), its callback called
--   q:stop()         drops everything, no callback called, no timer left
--                    (OnDriverDestroyed); q:start() takes writes again
--   q:pending()      the writes not done yet; q:idle() none and no PUT out
--   queue.body_of(fields)  the PUT body and its "key=value" texts in the
--                    box's order (for the log, and for specs)
--
-- The fields (contracts C2, stage 3 §1: execution only):
--   hdmiActive  true (wake: passthrough from power save) | false
--   hdmiSource  "input1".."input4" (or the number 1..4)
--   mode        "video" | "game" | "music" | "passthrough" | "powersave"
--   syncActive  true | false
--   intensity   "subtle" | "moderate" | "high" | "intense": sent inside the
--               mode's object when the write names a sync mode
--               ({"video": {"intensity": "high"}}), else on its own (the
--               current or last sync mode's, SB44)
--   brightness  a whole number 0..200
--   hueTarget   an area id ("groups/<n>" from an older bridge)
-- incrementBrightness and the toggles and cycles are not taken: a burst of
-- them cannot be merged to its latest value, so a caller sends the value it
-- wants instead.
--
-- on_done(tag, ok, model, why, detail): `cb` given to q:set, else the
-- on_done given to new, called once per q:set (under pcall), `model` the
-- last read the queue saw (nil before the first):
--   ok = true    a read after the write's PUT shows every field of it
--   why = "superseded"  a later q:set changed one of its fields, or asked
--                for the opposite (below): nothing to report to anyone
--   why = "busy" the box answered code 16 (another app streams to the
--                bridge's area, behaviour SB91) for a write that starts a
--                sync; not retried: stage 4's take-over acts on it. The
--                PUT's other writes (the input, the wake) are sent again at
--                once without the sync, so the picture still switches
--   why = "not landed"  no read showed it after TRIES tries RETRY_MS apart
--                (contracts C4, from Snap One's avswitch template's input
--                retries: syncbox-control4-research.md §1.5); `detail` the
--                last failure when the box did not answer
--   why = "refused"  the box refused the PUT (HTTP 4xx: a code 10, 12, 13
--                or 15, or the token, behaviour SB10 to SB21); `detail` the
--                client's text. Not retried: the same PUT gets the same
--                answer
--   why = "not sent" the client refused it without asking the box (not
--                paired, no address); `detail` its text
--   why = "cancelled"  q:clear
--
-- The box's order (docs/syncbox-behaviour.md SB55): the fields of one PUT
-- apply hdmiActive, then hdmiSource, hueTarget, mode, syncActive, the mode
-- objects, intensity, then brightness, whatever their order in the JSON. So
-- {hdmiActive, hdmiSource, mode, syncActive} wakes the box, switches the
-- input and syncs in that mode (SB31, SB39), and a mode sent with an
-- intensity puts the intensity on the new mode (SB55). The body is a Lua
-- table that common/https.lua encodes with C4:JsonEncode (SDK
-- docs-driverworks-api 12_json/_2-JsonEncode.md), so the order of its keys
-- on the wire is the encoder's, not ours; the box applies them in its own
-- order (SB55) whatever it is. That is why the latest-wins merge below
-- must leave no pair of fields that this order would turn against the
-- caller's latest intent, and why the log line lists them in that order.
--
-- Latest wins. A q:set ends (as "superseded") every waiting write that
-- holds one of its fields with another value, or that asks for the
-- opposite in the box's terms:
--   power off (hdmiActive false, mode powersave) against a wake, a sync or
--     passthrough;
--   a wake (hdmiActive true) against power off;
--   a sync (syncActive true, a sync mode) against power off, passthrough or
--     syncActive false;
--   passthrough against power off or syncActive true;
--   syncActive false against a sync.
-- Without that, {mode: powersave} after {syncActive: true} would go out as
-- one PUT that the box applies mode first, then syncActive (SB55), and so
-- wakes and syncs (SB32) after a Room Off. syncActive false and power off
-- do not oppose each other: both leave the box not syncing (SB33).
--
-- Confirmation and retries (contracts C4). After a 2xx the poller is asked
-- for a read in 1 s (p:soon("command"), syncbox/poller.lua); a read that
-- comes after the PUT's answer and shows a write's fields ends it with
-- ok. RETRY_MS after the answer, a write the reads have not shown counts
-- one miss and the waiting writes go again; when no read came in that time
-- the queue waits for the next one (at most READ_WAIT_MS) before it
-- counts. A PUT with no answer (no status, a 5xx, the client's own "busy")
-- counts the same way at RETRY_MS. TRIES misses end a write as "not
-- landed". Each PUT carries every waiting write (the box's state is the
-- latest of them all), so a retry is the same PUT again and a write that
-- landed with the first is never undone. One PUT is in flight at a time,
-- and the client sends one request at a time (syncbox/client.lua), so a
-- read answered after the PUT's answer was sent after it.
--
-- DriverWorks calls: none directly. `client` is syncbox/client.lua's
-- (c:put(path, body, cb), cb(ok, status, decoded, err), a handle with
-- Cancel), `poller` syncbox/poller.lua's (p:soon(reason)), `timer(ms, fn)`
-- one-shot with a handle's Cancel (default C4:SetTimer, SDK
-- docs-driverworks-api 34_timer), `now()` ms (default C4:GetTime).

local num = require("common.num")

local queue = {}

queue.PATH = "/execution"
queue.COALESCE_MS = 100      -- a burst of q:set (ON, SET_INPUT video and audio) becomes one PUT
queue.RETRY_MS = 2000        -- contracts C4: tries 2 s apart
queue.TRIES = 4              -- contracts C4: 4 tries, then "not landed"
queue.READ_WAIT_MS = 3000    -- the read asked for after a 2xx, waited for at most this long
queue.PUT_GUARD_MS = 20000   -- a PUT whose answer never came is given up after this
queue.BUSY_CODE = 16         -- the box's "invalid state": another app streams (SB91)

queue.SUPERSEDED = "superseded"
queue.BUSY = "busy"
queue.NOT_LANDED = "not landed"
queue.REFUSED = "refused"
queue.NOT_SENT = "not sent"
queue.CANCELLED = "cancelled"

-- The body's keys in the order the box applies them (SB55): the mode
-- objects stand where the box applies them, between syncActive and
-- intensity.
queue.ORDER = { "hdmiActive", "hdmiSource", "hueTarget", "mode", "syncActive", "video", "game", "music",
	"intensity", "brightness" }

-- The client's own refusals that a retry cannot mend (syncbox/client.lua
-- NOT_PAIRED, NO_ADDRESS, INVALID_PATH); its "busy" (a full queue) is
-- retried.
queue.LOCAL_FATAL = { ["not paired"] = true, ["no box address"] = true, ["invalid request path"] = true }

local SYNC_MODES = { video = true, game = true, music = true }
local MODES = { video = true, game = true, music = true, passthrough = true, powersave = true }
local INTENSITIES = { subtle = true, moderate = true, high = true, intense = true }
local AREA_MAX = 64

-- Fields ---------------------------------------------------------------------------------

-- `v` as the queue keeps field `key`: true and the value, or false.
local function valid(key, v)
	if key == "hdmiActive" or key == "syncActive" then
		return type(v) == "boolean", v
	elseif key == "hdmiSource" then
		if type(v) == "number" then
			local n = num.int(v, 1, 4)
			return n ~= nil and n == v, n and ("input" .. n)
		end
		return type(v) == "string" and v:match("^input[1-4]$") ~= nil, v
	elseif key == "mode" then
		return type(v) == "string" and MODES[v] == true, v
	elseif key == "intensity" then
		return type(v) == "string" and INTENSITIES[v] == true, v
	elseif key == "brightness" then
		local n = num.int(v, 0, 200)
		return n ~= nil and n == num.finite(v), n
	elseif key == "hueTarget" then
		local ok = type(v) == "string" and #v <= AREA_MAX
			and (v:match("^[%w%-]+$") ~= nil or v:match("^groups/%d+$") ~= nil)
		return ok, v
	end
	return false
end

local function starts_sync(f)
	return f.syncActive == true or SYNC_MODES[f.mode] == true
end

local function powers_off(f)
	return f.hdmiActive == false or f.mode == "powersave"
end

-- True when the fields `b` ask for what the intent of `a` opposes (the
-- list in the header). Called both ways round.
local function opposes(a, b)
	if powers_off(a) and (b.hdmiActive == true or starts_sync(b) or b.mode == "passthrough") then
		return true
	end
	if a.hdmiActive == true and powers_off(b) then
		return true
	end
	if starts_sync(a) and (powers_off(b) or b.mode == "passthrough" or b.syncActive == false) then
		return true
	end
	if a.mode == "passthrough" and (powers_off(b) or b.syncActive == true) then
		return true
	end
	if a.syncActive == false and starts_sync(b) then
		return true
	end
	return false
end

local function conflict(a, b)
	for k, v in pairs(a) do
		if b[k] ~= nil and b[k] ~= v then
			return true
		end
	end
	return opposes(a, b) or opposes(b, a)
end

-- Whether a read shows field `key` at `v` (contracts C2's model).
local function shows(model, key, v)
	if key == "hdmiActive" then
		if v then
			return model.power == "on" and model.mode ~= "powersave"
		end
		return model.power == "powersave" or model.mode == "powersave"
	elseif key == "hdmiSource" then
		return model.input ~= nil and model.input == tonumber(v:match("%d"))
	elseif key == "mode" then
		if v == "powersave" then
			return model.mode == "powersave" or model.power == "powersave"
		end
		return model.mode == v
	elseif key == "syncActive" then
		return model.syncing == v
	elseif key == "intensity" then
		return model.intensity == v
	elseif key == "brightness" then
		return model.brightness == v
	elseif key == "hueTarget" then
		return model.area == v
	end
	return false
end

local function landed(model, fields)
	if type(model) ~= "table" then
		return false
	end
	for k, v in pairs(fields) do
		if not shows(model, k, v) then
			return false
		end
	end
	return true
end

-- The PUT body for merged `fields`, and its "key=value" texts in the box's
-- order (SB55). The intensity goes inside the mode's object when the
-- fields name a sync mode.
function queue.body_of(fields)
	local body, parts = {}, {}
	local function add(key, value, shown)
		body[key] = value
		parts[#parts + 1] = (shown or key) .. "=" .. tostring(shown and value.intensity or value)
	end
	for _, k in ipairs({ "hdmiActive", "hdmiSource", "hueTarget", "mode", "syncActive" }) do
		if fields[k] ~= nil then
			add(k, fields[k])
		end
	end
	if fields.intensity ~= nil then
		if SYNC_MODES[fields.mode] then
			add(fields.mode, { intensity = fields.intensity }, fields.mode .. ".intensity")
		else
			add("intensity", fields.intensity)
		end
	end
	if fields.brightness ~= nil then
		add("brightness", fields.brightness)
	end
	return body, parts
end

-- The queue ------------------------------------------------------------------------------

local Q = {}
Q.__index = Q

local function cancel(handle)
	if handle then
		pcall(function() handle:Cancel() end)
	end
end

function queue.new(deps)
	deps = deps or {}
	if type(deps.client) ~= "table" or type(deps.client.put) ~= "function" then
		error("queue.new: client with a put function required", 2)
	end
	local q = setmetatable({}, Q)
	q.client = deps.client
	q.poller = deps.poller
	q.log = deps.log or require("common.log")
	q.timer = deps.timer or function(ms, fn)
		return C4:SetTimer(ms, function() fn() end)
	end
	q.now = deps.now or function()
		return C4:GetTime()
	end
	q.on_done = deps.on_done
	q.entries = {}       -- the writes not done yet, in the order set
	q.round = 0          -- PUTs sent
	q.flight = nil       -- the PUT in flight
	q.timers = {}        -- coalesce, retry, wait
	q.model = nil        -- the last read seen
	q.stopped = false
	return q
end

function Q:_disarm(name)
	cancel(self.timers[name])
	self.timers[name] = nil
end

function Q:_arm(name, ms, fn)
	self:_disarm(name)
	local timer
	timer = self.timer(math.max(1, math.floor(ms)), function()
		if self.timers[name] ~= timer then
			return -- disarmed or replaced (a Cancel that did not stop it)
		end
		self.timers[name] = nil
		if self.stopped then
			return
		end
		local ok, err = pcall(fn)
		if not ok then
			self.log.warn("Sync box queue: a step failed: %s", tostring(err))
		end
	end)
	self.timers[name] = timer
end

-- Run the callbacks of ended writes, after the queue's own state is
-- settled (a callback may set again).
function Q:_report(ended)
	for _, item in ipairs(ended) do
		local e = item.entry
		local cb = e.cb or self.on_done
		if type(cb) == "function" then
			local ok, err = pcall(cb, e.tag, item.ok, self.model, item.why, item.detail)
			if not ok then
				self.log.warn("Sync box queue: a write's callback failed: %s", tostring(err))
			end
		end
	end
end

-- Take `e` out of the waiting writes; `ended` collects it for _report.
function Q:_end(e, ended, ok, why, detail)
	for i, other in ipairs(self.entries) do
		if other == e then
			table.remove(self.entries, i)
			break
		end
	end
	ended[#ended + 1] = { entry = e, ok = ok, why = why, detail = detail }
end

function Q:pending()
	return #self.entries
end

function Q:idle()
	return #self.entries == 0 and self.flight == nil
end

-- The merged fields of every waiting write (no two of them conflict).
function Q:target()
	local out = {}
	for _, e in ipairs(self.entries) do
		for k, v in pairs(e.fields) do
			out[k] = v
		end
	end
	return out
end

function Q:set(fields, tag, cb)
	if self.stopped then
		return false, "the queue is stopped"
	end
	if type(fields) ~= "table" then
		return false, "no fields"
	end
	local clean, n = {}, 0
	for k, v in pairs(fields) do
		local ok, value = valid(k, v)
		if not ok then
			self.log.warn("Sync box queue: refused %s=%s", tostring(k), tostring(v))
			return false, "the queue does not take " .. tostring(k) .. "=" .. tostring(v)
		end
		clean[k], n = value, n + 1
	end
	if n == 0 then
		return false, "no fields"
	end
	local entry = { fields = clean, tag = tag, cb = cb, misses = 0 }
	local ended = {}
	for _, e in ipairs({ unpack(self.entries) }) do
		if conflict(e.fields, clean) then
			self:_end(e, ended, false, queue.SUPERSEDED)
		end
	end
	self.entries[#self.entries + 1] = entry
	if self.flight then
		self.dirty = true
	elseif not self.timers.coalesce then
		self:_arm("coalesce", queue.COALESCE_MS, function() self:flush() end)
	end
	self:_report(ended)
	return true
end

function Q:flush()
	self:_disarm("coalesce")
	if self.stopped then
		return false
	end
	if self.flight then
		self.dirty = true
		return false
	end
	if #self.entries == 0 then
		return false
	end
	local body, parts = queue.body_of(self:target())
	self.round = self.round + 1
	self:_disarm("retry")
	self:_disarm("wait")
	self.dirty = false
	local flight = { round = self.round, entries = {} }
	for _, e in ipairs(self.entries) do
		e.round, e.ended = flight.round, false
		flight.entries[#flight.entries + 1] = e
	end
	flight.sync = starts_sync(self:target())
	self.flight = flight
	self.log.debug("Sync box queue: PUT %s %s", queue.PATH, table.concat(parts, ", "))
	flight.guard = self.timer(queue.PUT_GUARD_MS, function()
		if not flight.done then
			cancel(flight.handle)
			self:_answered(flight, false, nil, nil,
				string.format("no answer within %d s", math.floor(queue.PUT_GUARD_MS / 1000)))
		end
	end)
	local ok, handle = pcall(self.client.put, self.client, queue.PATH, body, function(fine, status, decoded, err)
		self:_answered(flight, fine, status, decoded, err)
	end)
	if not ok then
		self:_answered(flight, false, nil, nil, "the PUT could not start: " .. tostring(handle))
	elseif not flight.done then
		flight.handle = handle
	end
	return true
end

-- The writes of `flight` still waiting.
function Q:_live(flight)
	local out = {}
	for _, e in ipairs(self.entries) do
		if e.round == flight.round then
			out[#out + 1] = e
		end
	end
	return out
end

function Q:_answered(flight, ok, status, decoded, err)
	if flight.done then
		return
	end
	flight.done = true
	cancel(flight.guard)
	if self.flight == flight then
		self.flight = nil
	end
	if self.stopped then
		return
	end
	local live = self:_live(flight)
	for _, e in ipairs(live) do
		e.ended = true
	end
	local ended = {}
	status = tonumber(status)
	local code = type(decoded) == "table" and num.int(decoded.code) or nil
	if ok then
		self.last_ok, self.last_err, self.read_after = true, nil, false
		if #live > 0 then
			if self.poller and type(self.poller.soon) == "function" then
				local fine, why = pcall(self.poller.soon, self.poller, "command")
				if not fine then
					self.log.warn("Sync box queue: the poller refused a read: %s", tostring(why))
				end
			end
			self:_arm("retry", queue.RETRY_MS, function() self:_check() end)
		end
	elseif status and code == queue.BUSY_CODE then
		-- SB91: refused whole (SB56) because its result would sync while
		-- another app streams. The writes that start a sync end busy; the
		-- rest go again at once without them.
		self.log.info("Sync box queue: the box is busy (code 16, another app streams): %s", tostring(err))
		for _, e in ipairs(live) do
			if not flight.sync or starts_sync(e.fields) then
				self:_end(e, ended, false, queue.BUSY, err)
			end
		end
		if flight.sync and #self.entries > 0 then
			self.dirty = true
		end
	elseif status and status >= 400 and status < 500 then
		self.log.warn("Sync box queue: the box refused the PUT: %s", tostring(err))
		for _, e in ipairs(live) do
			self:_end(e, ended, false, queue.REFUSED, err)
		end
	elseif status == nil and err and queue.LOCAL_FATAL[err] then
		for _, e in ipairs(live) do
			self:_end(e, ended, false, queue.NOT_SENT, err)
		end
	else
		self.last_ok, self.last_err = false, err or (status and ("HTTP " .. status)) or "no answer"
		self.log.debug("Sync box queue: the PUT failed (%s); again in %d ms", tostring(self.last_err), queue.RETRY_MS)
		if #live > 0 then
			self:_arm("retry", queue.RETRY_MS, function() self:_check() end)
		end
	end
	if self.dirty and #self.entries > 0 then
		self:_arm("coalesce", queue.COALESCE_MS, function() self:flush() end)
	end
	self:_report(ended)
end

-- RETRY_MS after an answer: a write no read has shown counts a miss and
-- goes again; after a 2xx, not before a read came (READ_WAIT_MS at most).
function Q:_check()
	if self.flight or #self.entries == 0 then
		return
	end
	if self.last_ok and not self.read_after then
		if not self.timers.wait then
			self:_arm("wait", queue.READ_WAIT_MS, function() self:_miss() end)
		end
		return
	end
	self:_miss()
end

function Q:_miss()
	self:_disarm("wait")
	self:_disarm("retry")
	if self.flight then
		return
	end
	local ended = {}
	for _, e in ipairs({ unpack(self.entries) }) do
		if e.ended and e.round == self.round then
			e.misses = e.misses + 1
			if e.misses >= queue.TRIES then
				self:_end(e, ended, false, queue.NOT_LANDED, self.last_ok == false and self.last_err or nil)
			end
		end
	end
	if #ended > 0 then
		self.log.info("Sync box queue: %d write(s) not shown by the box after %d tries", #ended, queue.TRIES)
	end
	if #self.entries > 0 then
		self:flush()
	end
	self:_report(ended)
end

function Q:observe(model)
	if type(model) ~= "table" or self.stopped or model == self.model then
		return
	end
	self.model = model
	if not self.flight then
		self.read_after = true
	end
	local ended = {}
	for _, e in ipairs({ unpack(self.entries) }) do
		if e.ended and landed(model, e.fields) then
			self:_end(e, ended, true)
		end
	end
	if #self.entries == 0 then
		self:_disarm("retry")
		self:_disarm("wait")
	elseif self.timers.wait then
		-- The read the queue waited for came, and did not show everything.
		self:_miss()
	end
	self:_report(ended)
end

function Q:clear(why)
	local ended = {}
	for _, e in ipairs({ unpack(self.entries) }) do
		self:_end(e, ended, false, why or queue.CANCELLED)
	end
	self:_disarm("coalesce")
	self:_disarm("retry")
	self:_disarm("wait")
	self.dirty = false
	self:_report(ended)
end

function Q:stop()
	self.stopped = true
	self.entries = {}
	for name in pairs(self.timers) do
		self:_disarm(name)
	end
	local flight = self.flight
	if flight then
		flight.done = true
		cancel(flight.guard)
		cancel(flight.handle)
		self.flight = nil
	end
	self.dirty = false
end

function Q:start()
	self.stopped = false
end

return queue
