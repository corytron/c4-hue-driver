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
-- What the house showed (OS 3.4.3, Bridge Pro, 2026-10-27) [verified:
-- hardware]:
--  * build 414: a probe whose CA file does not verify the bridge reports
--    nothing at all, neither "ONLINE" nor "OFFLINE" (the only two, SDK
--    32/_27): a refused handshake is silent;
--  * build 415: a probe with the decoy CA file on the binding a probe with
--    the Signify roots had just used went "ONLINE" and answered 43 ms later:
--    Director reused that connection or its TLS session, or kept the first
--    CA file of the binding. And the first probe's close, made inside
--    ReceivedFromNetwork, took effect only when the next probe recreated the
--    binding 1.5 s later.
-- Hence two bindings that never share a CA file, nothing done inside
-- Director's callbacks, and the gap between probes kept by the clock.
--
-- netcheck.run(ip, callback):
--  1. The decoy, first: binding DECOY_BINDING (6002), port 443, "SSL", with
--     netstream.port_options() except CACERTFILE = certs/decoy_ca.pem
--     (tlscheck.DECOY_CA: a self-signed CA that has signed nothing and
--     verifies nothing). Binding 6002 never gets another CA file, so no
--     connection or session of ours verified with the Signify roots exists
--     on it.
--  2. Only after a decoy that failed (silent, "OFFLINE", or no answer within
--     TIMEOUT), the control: binding CONTROL_BINDING (6003) with the
--     stream's own options, the Signify roots. It must go "ONLINE" and
--     answer within TIMEOUT. Binding 6003 never gets the decoy.
-- Each probe recreates its binding (CreateNetworkConnection, then
-- SetBindingAddress with the bridge's address, NetPortOptions, NetConnect;
-- no NetDisconnect first: its "OFFLINE" could be taken for the probe's), and
-- on "ONLINE" sends GET /api/0/config with a Host header and no key
-- (probe_request).
--
-- The verdict, callback(verdict, detail), once, from a 1 ms timer:
--   "not_pinned"    the decoy got an HTTP status line, whatever the status,
--                   QUICK_MS (150 ms) or more after its "ONLINE": the
--                   handshake succeeded without the Signify roots
--   "pinned"        the decoy got none (silent, "OFFLINE" before or after
--                   "ONLINE", or no answer within TIMEOUT) and the control
--                   then connected and answered
--   "inconclusive"  anything else: a decoy answer sooner than QUICK_MS after
--                   "ONLINE" (or before it), the control not answering,
--                   data that is no HTTP answer, a C4 call that raised, no CA
--                   configuration, an address that cannot go into a request
-- `detail` says what happened (with the timing of a decoy answer), for the
-- log and the Event Stream row. run() remembers nothing itself: the driver
-- calls remember_pinned() on "pinned" (hue_bridge/driver.lua, net_gate).
--
-- Why a silent decoy reads "pinned": on OS 3.4.3 a refused handshake is
-- silent, and silence alone could also be a connect that was never made. The
-- control, made on the same path seconds later (the same address and port,
-- the same calls, the same options but the CA file), shows that it is made
-- and answered; so the decoy failed for its CA file [assumed: that a binding
-- of the same driver connects as the other one does].
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
-- than GAP_MS after the last close of either probe binding, checked against
-- the clock (C4:GetTime) whatever the timer did. After the verdict both
-- bindings get NetDisconnect and SetBindingAddress with '' (as
-- netstream.clear_address does for 6001), before the verdict is delivered.
--
-- What the check cannot prove:
--  (a) As tlscheck's (a): that the file replaces the system's CA store
--      rather than adding to it. The bridge's private Signify chain fails
--      against the store plus the decoy just as against the decoy alone.
--  (b) Anything against an active attacker: one who can drop or reset the
--      decoy's connection makes it read "pinned", not only "inconclusive".
--      Hence the check runs at every start of the driver, never once per
--      Director version: on a controller that does not verify, every run the
--      attacker leaves alone reads "not_pinned" and falls back. The memory
--      of a "pinned" answer (remember_pinned, pinned_before) only lets an
--      "inconclusive" answer pass on that same Director version, as
--      tlscheck's does.
--
-- Stale reports. Director's callbacks carry no connection identity, and the
-- "OFFLINE" of a closed connection taken for the decoy's own would read as a
-- failed decoy. Every close of a probe binding that was connected may bring
-- one [assumed, as in netstream]: it is owed, per binding, for STALE_MS, and
-- an "OFFLINE" while one is owed is taken for it, whenever it comes, also
-- after the next probe's "ONLINE" (netstream lets "ONLINE" clear the debt;
-- here the safe side matters more). A probe's own "OFFLINE" taken so leaves
-- it to its timeout, which never makes a failure an answer. A predecessor's
-- close (the driver updated while a check ran; OnDriverDestroyed cancels it)
-- is not counted: its report comes long before this run's first probe, which
-- waits for the identity check and the C4:url TLS check [assumed].
--
-- The driver's globals feed two entry points, for the two probe bindings:
--   OnConnectionStatusChanged(idBinding, nPort, strStatus)
--       -> netcheck.on_status_changed(idBinding, nPort, strStatus)
--   ReceivedFromNetwork(idBinding, nPort, strData)
--       -> netcheck.on_data(idBinding, strData)
-- Each returns true for 6002 and 6003 (handled, whatever the state) and
-- false for any other binding.
--
-- DriverWorks calls: those of bridge/netstream.lua, whose header cites the
-- SDK file of each (CreateNetworkConnection, SetBindingAddress,
-- NetPortOptions, NetConnect, SendToNetwork, NetDisconnect), and
-- C4:SetTimer and C4:GetTime as there; for the memory, those of
-- bridge/tlscheck.lua (GetVersionInfo through tlscheck.director_version,
-- PersistSetValue, PersistGetValue). None runs before OnDriverLateInit: the
-- driver checks once the identity check has passed.
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

netcheck.DECOY_BINDING = 6002       -- only ever with the decoy CA file
netcheck.CONTROL_BINDING = 6003     -- only ever with the Signify roots; the stream's is 6001
netcheck.PORT = netstream.PORT      -- 443
netcheck.CONNECTION_TYPE = netstream.CONNECTION_TYPE -- "SSL"
netcheck.DECOY_CA = tlscheck.DECOY_CA -- "certs/decoy_ca.pem"
netcheck.PATH = "/api/0/config"
netcheck.TIMEOUT = 10        -- seconds per probe: the decoy's silence, the control's answer
netcheck.GAP_MS = 1500       -- at least this long from a close to the next creation
netcheck.QUICK_MS = 150      -- a decoy answer sooner than this after "ONLINE" is no handshake's
netcheck.STALE_MS = 5000     -- a close's "OFFLINE" not come by then never will [assumed]
netcheck.MAX_ANSWER = 1024   -- bytes of a probe's answer kept for the verdict; a status line is far shorter
netcheck.RETRY_MIN = 30      -- seconds before the driver asks again after an inconclusive answer, doubling
netcheck.RETRY_MAX = 300
-- The persisted Director version on which the check answered "pinned".
netcheck.STORE_NAME = "netstream_pinned_on"

local BINDINGS = { netcheck.DECOY_BINDING, netcheck.CONTROL_BINDING }

-- The check in flight: { ip, callback, step = "decoy" | "control",
-- phase = "waiting" | "opening" | "open" | "closing" | "done", online_at,
-- answer_after, received, timer (the probe's TIMEOUT), wait_timer (the gap,
-- or the 1 ms step after a probe's end), open = { [binding] = true },
-- decoy (how the decoy failed) }.
local current = nil
local delivery = nil      -- the 1 ms timer that delivers a verdict
local owed = {}           -- binding -> "OFFLINE" reports its closes may still bring
local closed_at = {}      -- binding -> ms clock of its last close after a connect
local last_close = nil    -- ms clock of the last close of either probe binding
local remembered = nil    -- what remember_pinned() wrote in this run

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

local function binding_of(step)
	return step == "decoy" and netcheck.DECOY_BINDING or netcheck.CONTROL_BINDING
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

-- NetDisconnect a probe binding and clear its address, each call under
-- pcall. `was_connected`: a probe connected it, so the close may bring an
-- "OFFLINE" (owed, see the header).
local function close(binding, was_connected)
	local now = now_ms()
	if was_connected then
		if closed_at[binding] and now - closed_at[binding] >= netcheck.STALE_MS then
			owed[binding] = 0
		end
		owed[binding] = (owed[binding] or 0) + 1
		closed_at[binding] = now
	end
	last_close = now
	local ok, err = pcall(function()
		C4:NetDisconnect(binding, netcheck.PORT)
	end)
	if not ok then
		log.warn("network connection TLS check: NetDisconnect of binding %d failed: %s", binding, tostring(err))
	end
	ok, err = pcall(function()
		C4:SetBindingAddress(binding, "")
	end)
	if not ok then
		log.warn("network connection TLS check: could not clear binding %d: %s", binding, tostring(err))
	end
end

-- The verdict: both probe bindings closed and cleared, then the verdict from
-- a 1 ms timer. Once per check; nothing for a check cancelled or replaced.
-- Never called inside Director's callbacks (see the header).
local function finish(check, verdict, detail)
	if current ~= check then
		return
	end
	current = nil
	cancel_timers(check)
	check.phase = "done"
	for _, binding in ipairs(BINDINGS) do
		close(binding, check.open[binding] == true)
		check.open[binding] = nil
	end
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
	log.debug("network connection TLS check: the %s probe %s", check.step, text)
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
			close(netcheck.DECOY_BINDING, true)
			check.open[netcheck.DECOY_BINDING] = nil
			return open_step(check, "control")
		end
		return finish(check, "inconclusive", "the probe with the decoy CA file " .. text)
	end
	if outcome == "answered" then
		return finish(check, "pinned", string.format("the probe with the decoy CA file %s; the Signify roots answered "
			.. "on binding %d", check.decoy, netcheck.CONTROL_BINDING))
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

-- Open probe `step` (see the header), GAP_MS after the last close at the
-- earliest: recreate its binding and connect.
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
	local binding = binding_of(step)
	check.step, check.phase, check.online_at, check.answer_after, check.received = step, "opening", nil, nil, ""
	if closed_at[binding] and now_ms() - closed_at[binding] >= netcheck.STALE_MS then
		owed[binding] = 0 -- what its last close brought has come by now, or never will [assumed]
	end
	check.timer = C4:SetTimer(netcheck.TIMEOUT * 1000, function()
		check.timer = nil
		step_ended(check, check.online_at and "no_answer" or "silence")
	end)
	check.open[binding] = true
	local ok, err = pcall(function()
		C4:CreateNetworkConnection(binding, check.ip, netcheck.CONNECTION_TYPE)
		C4:SetBindingAddress(binding, check.ip)
		C4:NetPortOptions(binding, netcheck.PORT, netcheck.CONNECTION_TYPE, options)
		C4:NetConnect(binding, netcheck.PORT)
	end)
	if not ok then
		-- A no-op when Director reported from inside a call and that decided.
		step_ended(check, "error", "could not be opened: " .. tostring(err))
	end
end

-- Run the check against the bridge at `ip`; `callback(verdict, detail)` is
-- called once, unless cancel() or another run() comes first. A check still
-- in flight is cancelled.
function netcheck.run(ip, callback)
	netcheck.cancel()
	local check = { ip = ip, callback = callback, phase = "waiting", open = {} }
	current = check
	if not header_safe(ip) then
		return finish(check, "inconclusive", "the bridge address cannot go into a request")
	end
	open_step(check, "decoy")
end

-- Drop the check in flight, and a verdict not yet delivered: no callback.
-- A probe binding it connected is closed and cleared.
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
	for _, binding in ipairs(BINDINGS) do
		if check.open[binding] then
			close(binding, true)
			check.open[binding] = nil
		end
	end
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
		C4:SendToNetwork(binding_of(check.step), netcheck.PORT, request)
	end)
	if not ok then
		return step_ended(check, "error", "could not send its request: " .. tostring(err))
	end
	log.debug("network connection TLS check: the %s probe is online; GET %s sent, no key", check.step, netcheck.PATH)
end

-- The probe binding `binding` stands for, or nil.
local function probe_binding(binding)
	local id = tonumber(binding)
	if id == netcheck.DECOY_BINDING or id == netcheck.CONTROL_BINDING then
		return id
	end
	return nil
end

-- True when `check` has a probe connecting or connected on binding `id`.
local function probing_on(check, id)
	return check ~= nil and connected(check) and binding_of(check.step) == id
end

-- Director's OnConnectionStatusChanged, routed by the driver.
function netcheck.on_status_changed(binding, port, status)
	local id = probe_binding(binding)
	if not id then
		return false
	end
	status = tostring(status):upper()
	local check = current
	if status == "OFFLINE" then
		if (owed[id] or 0) > 0 then
			owed[id] = owed[id] - 1
			log.debug("network connection TLS check: OFFLINE on %d taken for a closed connection's", id)
		elseif probing_on(check, id) then
			step_ended(check, check.received ~= "" and "garbage" or "offline", #check.received)
		else
			log.debug("network connection TLS check: OFFLINE on %d with no probe open ignored", id)
		end
	elseif status == "ONLINE" then
		if probing_on(check, id) then
			on_online(check)
		else
			log.debug("network connection TLS check: ONLINE on %d with no probe open ignored", id)
		end
	else
		log.debug("network connection TLS check: connection status %s on %d port %s ignored", status, id, tostring(port))
	end
	return true
end

-- Director's ReceivedFromNetwork, routed by the driver: a probe's answer, in
-- pieces of any size. Never logged, only counted.
function netcheck.on_data(binding, data)
	local id = probe_binding(binding)
	if not id then
		return false
	end
	if type(data) ~= "string" or data == "" then
		return true
	end
	local check = current
	if not probing_on(check, id) then
		log.debug("network connection TLS check: %d byte(s) on %d with no probe open ignored", #data, id)
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
