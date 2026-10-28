-- The TLS self-check of the network connection (issue #317): evidence, on
-- the controller at hand, that a network connection verifies the bridge
-- against the CA file its port options name, and does not trust the bridge
-- without it. bridge/tlscheck.lua does the same for C4:url (issue #53).
--
-- Why: the event stream holds a network connection (bridge/netstream.lua,
-- binding 6001) with CACERTFILE = the two Signify roots and VERIFY_MODE =
-- "peer", and its GET carries the application key. That the stream connects
-- with those options [verified: hardware, build 413] shows that the file is
-- read, not that it decides: were VERIFY_MODE or CACERTFILE ignored on some
-- OS release, the key would go to any peer that answers on the bridge's
-- address.
--
-- What the house showed (OS 3.4.3, Bridge Pro, builds 414 to 416,
-- 2026-10-27) [verified: hardware]:
--  * A binding id used for the first time in the project is registered
--    (OnNetworkBindingRegistered, OnBindingEntryAdded) and behaves: with the
--    decoy CA file it stays silent, neither "ONLINE" nor "OFFLINE" (a refused
--    handshake is silent); with the Signify roots it is "ONLINE" within
--    100 ms.
--  * An id used before, then cleared, is only renamed
--    (OnBindingEntryRenamed) by CreateNetworkConnection, and then either
--    inherits the old connection (a decoy that "answered" 43 ms after
--    "ONLINE") or does nothing at all. A probe on a reused id proves nothing.
--  * A close made inside ReceivedFromNetwork took effect only when the
--    binding was next recreated.
--
-- Probe binding ids: every probe takes a fresh one, never used before in the
-- project, from a persisted counter (COUNTER_NAME), FIRST_ID (6100) up to
-- LAST_ID (6999); 6001 is the stream's, and 6002 and 6003 were used by
-- earlier builds. Each id is used once: CreateNetworkConnection, then
-- SetBindingAddress with the bridge's address, NetPortOptions, NetConnect;
-- NetDisconnect and SetBindingAddress with '' (as netstream.clear_address
-- does for 6001) when its probe is done; then never touched again. The
-- counter is written before the id is used, so no restart can hand it out
-- twice, and this run keeps its own copy too (PersistGetValue may not yet
-- return what was just written). Past LAST_ID the check answers
-- "inconclusive" ("probe binding ids exhausted", logged once per run).
--
-- That budget lasts: the check runs once per Director version. run()
-- answers "pinned" from the memory (pinned_before) on a version that
-- answered "pinned" before, without a probe; so a controller that verifies
-- spends two ids per Director version. A run that is not concluded spends
-- one or two per attempt, and the driver asks again after RETRY_MIN to
-- RETRY_MAX (30 s doubling to an hour): at most 48 a day while that lasts. A
-- controller that does not verify spends one per start (the decoy answers;
-- no control). 900 ids.
--
-- netcheck.run(ip, callback):
--  1. The decoy, first, on a fresh id: port 443, "SSL", with
--     netstream.port_options() except CACERTFILE = certs/decoy_ca.pem
--     (tlscheck.DECOY_CA: a self-signed CA that has signed nothing and
--     verifies nothing).
--  2. Only after a decoy that failed (silent, "OFFLINE", or no answer within
--     TIMEOUT), the control, on another fresh id, with the stream's own
--     options, the Signify roots. It must go "ONLINE" and answer within
--     TIMEOUT. An id never gets both CA files: each gets one probe.
-- Each probe sends, on "ONLINE", GET /api/0/config with a Host header and no
-- key (probe_request).
--
-- The verdict, callback(verdict, detail), once, from a 1 ms timer:
--   "not_pinned"    the decoy got an HTTP status line, whatever the status,
--                   QUICK_MS (150 ms) or more after its "ONLINE": the
--                   handshake succeeded without the Signify roots
--   "pinned"        the decoy got none (silent, "OFFLINE" before or after
--                   "ONLINE", or no answer within TIMEOUT) and the control
--                   then connected and answered; or, without a probe, this
--                   Director version answered "pinned" before
--   "inconclusive"  anything else: a decoy answer sooner than QUICK_MS after
--                   "ONLINE" (or before it), the control not answering,
--                   data that is no HTTP answer, a C4 call that raised, no
--                   probe binding id left, no CA configuration, an address
--                   that cannot go into a request
-- `detail` says what happened (with the timing of a decoy answer), for the
-- log and the Event Stream row. run() remembers nothing itself: the driver
-- calls remember_pinned() on "pinned" (hue_bridge/driver.lua, net_gate).
--
-- Why a silent decoy reads "pinned": on OS 3.4.3 a refused handshake is
-- silent, and silence alone could also be a connect that was never made. The
-- control, made the same way seconds later on an id as fresh as the decoy's
-- (the same address and port, the same calls, the same options but the CA
-- file), shows that it is made and answered; so the decoy failed for its CA
-- file [assumed: that a fresh id connects as another fresh id does].
--
-- The QUICK_MS rule [owner's rule, 2026-10-27; assumed]: an answer that
-- quick is taken for a reused connection or session, which skips the
-- certificate check, not for a handshake. Whether "ONLINE" comes before or
-- after the handshake is not documented; a refused decoy reported none on OS
-- 3.4.3, which suggests after, so a genuine quick answer may read
-- "inconclusive" too: the side on which nothing keyed is sent.
--
-- Timing: a probe's end is noted inside Director's callbacks and acted on
-- from a 1 ms timer (close, next probe, verdict); no binding is created less
-- than GAP_MS after the last close of a probe binding, checked against the
-- clock (C4:GetTime) whatever the timer did. At the verdict, every probe id
-- of the check still open is closed and cleared, before the verdict is
-- delivered. Reports on an id that is not the open probe's (a closed probe's)
-- are ignored: a fresh id has no earlier connection whose late "OFFLINE"
-- could be taken for its own.
--
-- What the check cannot prove:
--  (a) As tlscheck's (a): that the file replaces the system's CA store
--      rather than adding to it. The bridge's private Signify chain fails
--      against the store plus the decoy just as against the decoy alone.
--  (b) Anything against an active attacker: one who can drop or reset the
--      decoy's connection makes it read "pinned", not only "inconclusive";
--      and the first "pinned" answer of a Director version stands until the
--      next Director update (the price of a finite budget of ids). On a
--      controller that does not verify, every check the attacker leaves
--      alone reads "not_pinned" and falls back.
--
-- The driver's globals feed two entry points, for the probe ids:
--   OnConnectionStatusChanged(idBinding, nPort, strStatus)
--       -> netcheck.on_status_changed(idBinding, nPort, strStatus)
--   ReceivedFromNetwork(idBinding, nPort, strData)
--       -> netcheck.on_data(idBinding, strData)
-- Each returns true for an id from FIRST_ID to LAST_ID (handled, whatever
-- the state) and false for any other binding.
--
-- DriverWorks calls: those of bridge/netstream.lua, whose header cites the
-- SDK file of each (CreateNetworkConnection, SetBindingAddress,
-- NetPortOptions, NetConnect, SendToNetwork, NetDisconnect), and
-- C4:SetTimer and C4:GetTime as there; PersistSetValue and PersistGetValue
-- for the counter (a number [verified: SDK 26.5_persistence/_4]) and, as in
-- bridge/tlscheck.lua, for the memory (with GetVersionInfo through
-- tlscheck.director_version). None runs before OnDriverLateInit: the driver
-- checks once the identity check has passed.
--
-- The memory: remember_pinned() stores the running Director version under
-- STORE_NAME, apart from tlscheck's: each check speaks for its own API.
-- pinned_before() is true only while the running version is that same
-- non-empty string, and also trusts what remember_pinned() wrote in this run
-- (PersistGetValue may not return it yet). As in tlscheck: a version that
-- cannot be read is never remembered and never matches.

local log = require("common.log")
local netstream = require("bridge.netstream")
local tlscheck = require("bridge.tlscheck")

local netcheck = {}

netcheck.FIRST_ID = 6100     -- the probe binding ids; network bindings are 6000-6999 (SDK 32/_1)
netcheck.LAST_ID = 6999
netcheck.COUNTER_NAME = "netcheck_next_binding" -- persisted: the next probe binding id to hand out
netcheck.PORT = netstream.PORT                  -- 443
netcheck.CONNECTION_TYPE = netstream.CONNECTION_TYPE -- "SSL"
netcheck.DECOY_CA = tlscheck.DECOY_CA           -- "certs/decoy_ca.pem"
netcheck.PATH = "/api/0/config"
netcheck.TIMEOUT = 10        -- seconds per probe: the decoy's silence, the control's answer
netcheck.GAP_MS = 1500       -- at least this long from a close to the next creation
netcheck.QUICK_MS = 150      -- a decoy answer sooner than this after "ONLINE" is no handshake's
netcheck.MAX_ANSWER = 1024   -- bytes of a probe's answer kept for the verdict; a status line is far shorter
netcheck.RETRY_MIN = 30      -- seconds before the driver asks again after an inconclusive answer, doubling
netcheck.RETRY_MAX = 3600    -- an hour: every attempt spends probe binding ids
-- The persisted Director version on which the check answered "pinned".
-- "_v2" since build 417: the verdicts builds 414-416 remembered came from
-- probes on reused binding ids, which prove nothing (#317), so none counts.
netcheck.STORE_NAME = "netcheck_pinned_on_v2"

local STEPS = { "decoy", "control" }

-- The check in flight: { ip, callback, step = "decoy" | "control",
-- phase = "waiting" | "opening" | "open" | "closing" | "done", ids = { [step]
-- = id }, open = { [id] = true }, online_at, answer_after, received, timer
-- (the probe's TIMEOUT), wait_timer (the gap, or the 1 ms step after a
-- probe's end), decoy (how the decoy failed) }.
local current = nil
local delivery = nil          -- the 1 ms timer that delivers a verdict
local last_close = nil        -- ms clock of the last close of a probe binding
local next_id = nil           -- this run's copy of the counter
local exhausted_logged = false
local remembered = nil        -- what remember_pinned() wrote in this run

-- Milliseconds, as netstream: C4:GetTime, or os.time() where it is missing.
local function c4_time()
	return C4:GetTime()
end

local function now_ms()
	local ok, ms = pcall(c4_time)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

-- An address that can go into the Host header: a CR or LF would end the line.
local function header_safe(value)
	return type(value) == "string" and value ~= "" and not value:find("[%c%s]")
end

-- Every probe's request: the bridge's public configuration, and no key.
local function probe_request(ip)
	return table.concat({
		"GET " .. netcheck.PATH .. " HTTP/1.1",
		"Host: " .. ip,
		"Connection: close",
		"",
		"",
	}, "\r\n")
end

-- The status code of an HTTP status line at the start of `text` (blank
-- lines before it tolerated, as netstream's reader does), or nil.
local function status_code(text)
	local trimmed = text:gsub("^[\r\n]+", "")
	return trimmed:match("^HTTP/[%d%.]+[ \t]+(%d%d%d)")
end

-- The decoy's tPortParams: the stream's (netstream.port_options, a new table
-- per call) with the decoy as CACERTFILE; nil without a CA configuration.
-- The control's are the stream's own.
function netcheck.port_options()
	local options = netstream.port_options()
	if not options then
		return nil
	end
	options.CACERTFILE = netcheck.DECOY_CA
	return options
end

-- The delay in seconds before the driver asks again after the `attempt`-th
-- inconclusive answer in a row: RETRY_MIN, doubling up to RETRY_MAX.
function netcheck.retry_delay(attempt)
	local n = math.max(1, math.floor(tonumber(attempt) or 1))
	return math.min(netcheck.RETRY_MIN * 2 ^ (n - 1), netcheck.RETRY_MAX)
end

-- The counter as stored: a whole number from FIRST_ID up, else FIRST_ID.
local function stored_next_id()
	local ok, value = pcall(function()
		return C4:PersistGetValue(netcheck.COUNTER_NAME)
	end)
	local n = ok and tonumber(value) or nil
	if n and n == math.floor(n) and n >= netcheck.FIRST_ID then
		return n
	end
	return netcheck.FIRST_ID
end

-- A probe binding id never handed out before, or nil when none is left. The
-- counter moves on, in the store and in this run, before the id is used.
local function allocate_id()
	local id = math.max(next_id or netcheck.FIRST_ID, stored_next_id())
	next_id = id
	if id > netcheck.LAST_ID then
		return nil
	end
	next_id = id + 1
	local ok, err = pcall(function()
		C4:PersistSetValue(netcheck.COUNTER_NAME, next_id)
	end)
	if not ok then
		log.warn("network connection TLS check: could not store the next probe binding id: %s", tostring(err))
	end
	return id
end

local function cancel_timers(check)
	if check.timer then
		check.timer:Cancel()
		check.timer = nil
	end
	if check.wait_timer then
		check.wait_timer:Cancel()
		check.wait_timer = nil
	end
end

-- True while the probe's connection is opening or open.
local function connected(check)
	return check.phase == "opening" or check.phase == "open"
end

-- NetDisconnect a probe id and clear its address, each call under pcall; the
-- id is never touched again.
local function close(check, id)
	check.open[id] = nil
	last_close = now_ms()
	local ok, err = pcall(function()
		C4:NetDisconnect(id, netcheck.PORT)
	end)
	if not ok then
		log.warn("network connection TLS check: NetDisconnect of binding %d failed: %s", id, tostring(err))
	end
	ok, err = pcall(function()
		C4:SetBindingAddress(id, "")
	end)
	if not ok then
		log.warn("network connection TLS check: could not clear binding %d: %s", id, tostring(err))
	end
end

-- Close every probe id of the check still open, the decoy's first.
local function close_open(check)
	for _, step in ipairs(STEPS) do
		local id = check.ids[step]
		if id and check.open[id] then
			close(check, id)
		end
	end
end

-- The verdict: the check's probe ids closed and cleared, then the verdict
-- from a 1 ms timer. Once per check; nothing for a check cancelled or
-- replaced. Never called inside Director's callbacks (see the header).
local function finish(check, verdict, detail)
	if current ~= check then
		return
	end
	current = nil
	cancel_timers(check)
	check.phase = "done"
	close_open(check)
	log.debug("network connection TLS check: %s (%s)", verdict, detail)
	delivery = C4:SetTimer(1, function()
		delivery = nil
		check.callback(verdict, detail)
	end)
end

-- What a probe did, for the detail.
local function outcome_text(check, outcome, extra)
	if outcome == "silence" then
		return string.format("was silent for %d s", netcheck.TIMEOUT)
	elseif outcome == "no_answer" then
		return string.format("went ONLINE, then gave no answer within %d s", netcheck.TIMEOUT)
	elseif outcome == "offline" then
		return check.online_at and "went ONLINE, then OFFLINE without an answer" or "went OFFLINE before ONLINE"
	elseif outcome == "garbage" then
		return string.format("got an answer that is no HTTP answer (%s bytes)", tostring(extra))
	elseif outcome == "answered" then
		return string.format("answered HTTP %s %s", tostring(extra), check.answer_after
			and string.format("%d ms after ONLINE", check.answer_after) or "before ONLINE")
	end
	return tostring(extra) -- "error": the caller's own words
end

local open_step

-- What a probe's end means (see the header); from a 1 ms timer.
local function decide(check, outcome, extra)
	local text = outcome_text(check, outcome, extra)
	log.debug("network connection TLS check: the %s probe on binding %s %s", check.step,
		tostring(check.ids[check.step]), text)
	if check.step == "decoy" then
		if outcome == "answered" then
			if check.answer_after and check.answer_after >= netcheck.QUICK_MS then
				return finish(check, "not_pinned", "the probe with the decoy CA file " .. text)
			end
			return finish(check, "inconclusive", string.format("the probe with the decoy CA file %s: too soon for a "
				.. "handshake, taken for a reused connection or session", text))
		end
		if outcome == "silence" or outcome == "no_answer" or outcome == "offline" then
			check.decoy = text
			close(check, check.ids.decoy)
			return open_step(check, "control")
		end
		return finish(check, "inconclusive", "the probe with the decoy CA file " .. text)
	end
	if outcome == "answered" then
		return finish(check, "pinned", string.format("the probe with the decoy CA file %s; the Signify roots answered",
			check.decoy))
	end
	finish(check, "inconclusive", "the control with the Signify roots " .. text)
end

-- The probe ended: `outcome` is "answered" (`extra` the status code),
-- "silence", "no_answer", "offline", "garbage" (`extra` the byte count) or
-- "error" (`extra` what went wrong). Noted now, acted on from a 1 ms timer.
-- A no-op once the probe has ended.
local function step_ended(check, outcome, extra)
	if current ~= check or not connected(check) then
		return
	end
	if check.timer then
		check.timer:Cancel()
		check.timer = nil
	end
	check.phase = "closing"
	check.wait_timer = C4:SetTimer(1, function()
		check.wait_timer = nil
		if current == check then
			decide(check, outcome, extra)
		end
	end)
end

-- Open probe `step` (see the header) on a fresh id, GAP_MS after the last
-- close at the earliest.
open_step = function(check, step)
	local options
	if step == "decoy" then
		options = netcheck.port_options()
	else
		options = netstream.port_options()
	end
	if not options then
		return finish(check, "inconclusive", "no CA configuration")
	end
	local wait = last_close and netcheck.GAP_MS - (now_ms() - last_close) or 0
	if wait > 0 then
		check.phase = "waiting"
		check.wait_timer = C4:SetTimer(wait, function()
			check.wait_timer = nil
			if current == check then
				open_step(check, step)
			end
		end)
		return
	end
	local id = allocate_id()
	if not id then
		if not exhausted_logged then
			exhausted_logged = true
			log.warn("network connection TLS check: probe binding ids exhausted (%d to %d all used); the check "
				.. "answers inconclusive", netcheck.FIRST_ID, netcheck.LAST_ID)
		end
		return finish(check, "inconclusive", "probe binding ids exhausted")
	end
	check.ids[step] = id
	check.step, check.phase, check.online_at, check.answer_after, check.received = step, "opening", nil, nil, ""
	check.timer = C4:SetTimer(netcheck.TIMEOUT * 1000, function()
		check.timer = nil
		step_ended(check, check.online_at and "no_answer" or "silence")
	end)
	check.open[id] = true
	local ok, err = pcall(function()
		C4:CreateNetworkConnection(id, check.ip, netcheck.CONNECTION_TYPE)
		C4:SetBindingAddress(id, check.ip)
		C4:NetPortOptions(id, netcheck.PORT, netcheck.CONNECTION_TYPE, options)
		C4:NetConnect(id, netcheck.PORT)
	end)
	if not ok then
		-- A no-op when Director reported from inside a call and that decided.
		step_ended(check, "error", "could not be opened: " .. tostring(err))
	end
end

-- Run the check against the bridge at `ip`; `callback(verdict, detail)` is
-- called once, unless cancel() or another run() comes first. A check still
-- in flight is cancelled. On a Director version that answered "pinned"
-- before, the answer is "pinned" at once, without a probe (see the header).
function netcheck.run(ip, callback)
	netcheck.cancel()
	local check = { ip = ip, callback = callback, phase = "waiting", ids = {}, open = {} }
	current = check
	if not header_safe(ip) then
		return finish(check, "inconclusive", "the bridge address cannot go into a request")
	end
	if netcheck.pinned_before() then
		return finish(check, "pinned", string.format("Director %s answered pinned before; no probe",
			tostring(tlscheck.director_version())))
	end
	open_step(check, "decoy")
end

-- Drop the check in flight, and a verdict not yet delivered: no callback.
-- A probe id still open is closed and cleared.
function netcheck.cancel()
	if delivery then
		delivery:Cancel()
		delivery = nil
	end
	local check = current
	if not check then
		return
	end
	current = nil
	cancel_timers(check)
	close_open(check)
	check.phase = "done"
	log.debug("network connection TLS check cancelled")
end

local function on_online(check)
	if check.phase ~= "opening" then
		log.debug("network connection TLS check: ONLINE ignored (already online)")
		return
	end
	check.phase, check.online_at = "open", now_ms()
	local request = probe_request(check.ip)
	local ok, err = pcall(function()
		C4:SendToNetwork(check.ids[check.step], netcheck.PORT, request)
	end)
	if not ok then
		return step_ended(check, "error", "could not send its request: " .. tostring(err))
	end
	log.debug("network connection TLS check: the %s probe is online; GET %s sent, no key", check.step, netcheck.PATH)
end

-- The probe id `binding` stands for, or nil.
local function probe_id(binding)
	local id = tonumber(binding)
	if id and id == math.floor(id) and id >= netcheck.FIRST_ID and id <= netcheck.LAST_ID then
		return id
	end
	return nil
end

-- True when `check` has a probe connecting or connected on `id`.
local function probing_on(check, id)
	return check ~= nil and connected(check) and check.ids[check.step] == id
end

-- Director's OnConnectionStatusChanged, routed by the driver.
function netcheck.on_status_changed(binding, port, status)
	local id = probe_id(binding)
	if not id then
		return false
	end
	status = tostring(status):upper()
	local check = current
	if not probing_on(check, id) then
		log.debug("network connection TLS check: %s on %d, no probe open there, ignored", status, id)
	elseif status == "OFFLINE" then
		step_ended(check, check.received ~= "" and "garbage" or "offline", #check.received)
	elseif status == "ONLINE" then
		on_online(check)
	else
		log.debug("network connection TLS check: connection status %s on %d port %s ignored", status, id, tostring(port))
	end
	return true
end

-- Director's ReceivedFromNetwork, routed by the driver: a probe's answer, in
-- pieces of any size. Never logged, only counted.
function netcheck.on_data(binding, data)
	local id = probe_id(binding)
	if not id then
		return false
	end
	if type(data) ~= "string" or data == "" then
		return true
	end
	local check = current
	if not probing_on(check, id) then
		log.debug("network connection TLS check: %d byte(s) on %d, no probe open there, ignored", #data, id)
		return true
	end
	if #check.received < netcheck.MAX_ANSWER then
		check.received = check.received .. data:sub(1, netcheck.MAX_ANSWER - #check.received)
	end
	local code = status_code(check.received)
	if code then
		check.answer_after = check.online_at and (now_ms() - check.online_at) or nil
		step_ended(check, "answered", code)
	elseif check.received:gsub("^[\r\n]+", ""):find("\n", 1, true) or #check.received >= netcheck.MAX_ANSWER then
		step_ended(check, "garbage", #check.received)
	end
	return true
end

-- Remember that the running Director version answered "pinned". Returns the
-- version, or nil (and stores nothing) when it cannot be read. A store that
-- raises is logged; this run still remembers.
function netcheck.remember_pinned()
	local version = tlscheck.director_version()
	if not version then
		return nil
	end
	remembered = version
	local ok, err = pcall(function()
		C4:PersistSetValue(netcheck.STORE_NAME, version)
	end)
	if not ok then
		log.warn("network connection TLS check: could not store the Director version %s: %s", version, tostring(err))
	end
	return version
end

-- True only when the running Director version is known and equals the one
-- remembered for a "pinned" answer (in this run, or persisted by an earlier
-- one). Always a boolean.
function netcheck.pinned_before()
	local version = tlscheck.director_version()
	if not version then
		return false
	end
	if remembered == version then
		return true
	end
	local ok, value = pcall(function()
		return C4:PersistGetValue(netcheck.STORE_NAME)
	end)
	return ok and type(value) == "string" and value == version
end

return netcheck
