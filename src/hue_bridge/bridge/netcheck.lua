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
-- What the house showed (build 414, OS 3.4.3, Bridge Pro, 2026-10-27)
-- [verified: hardware]: a connection whose CA file does not verify the
-- bridge reports nothing at all, neither "ONLINE" nor "OFFLINE" (the only
-- two, SDK 32/_27): a refused handshake is silent. And Director logged
-- OnNetworkBindingRegistered for binding 6002 once, at the first probe,
-- although every probe called CreateNetworkConnection: after the address
-- had been cleared, the later probes may have run on a binding Director had
-- dropped. So silence alone cannot tell a refusal from a connect that was
-- never made.
--
-- netcheck.run(ip, callback): up to three probes on binding 6002, one after
-- the other, each sending the same unkeyed request:
--   1. control  with the Signify roots (netstream.port_options()). It must
--               go "ONLINE" and answer with an HTTP status line within
--               TIMEOUT (10 s); otherwise "inconclusive": the path itself
--               does not work, so nothing can be learnt.
--   2. decoy    the same options with CACERTFILE = certs/decoy_ca.pem
--               (tlscheck.DECOY_CA: a self-signed CA that has signed nothing
--               and verifies nothing).
--   3. confirm  the control again, only after a decoy that failed (silent
--               for TIMEOUT, or "OFFLINE" without an answer).
-- Every probe recreates the binding: CreateNetworkConnection, then
-- SetBindingAddress with the bridge's address, NetPortOptions, NetConnect.
-- No NetDisconnect before the connect: its "OFFLINE" could be taken for the
-- probe's. On "ONLINE" a probe sends GET /api/0/config with a Host header and
-- no key (probe_request). After every probe the binding is closed and
-- cleared (NetDisconnect, then SetBindingAddress with '', as
-- netstream.clear_address does for 6001), and the next one opens GAP_MS
-- later.
--
-- The verdict, callback(verdict, detail), once, from a 1 ms timer:
--   "not_pinned"    the decoy got an HTTP status line, whatever the status:
--                   the handshake succeeded without the Signify roots
--   "pinned"        the decoy got none (silent for TIMEOUT, or "OFFLINE"
--                   before or after "ONLINE"), and the controls before and
--                   after it both connected and answered
--   "inconclusive"  anything else: a control that did not answer, a decoy
--                   that went "ONLINE" and then neither answered nor closed
--                   within TIMEOUT, data that is no HTTP answer, a C4 call
--                   that raised, no CA configuration, an address that cannot
--                   go into a request
-- `detail` says which probe did what, for the log and the Event Stream row.
-- run() remembers nothing itself: the driver calls remember_pinned() on
-- "pinned" (hue_bridge/driver.lua, net_gate).
--
-- Why a silent decoy reads "pinned". The decoy differs from the controls in
-- its CA file and in nothing else: the same binding, recreated by the same
-- calls, the same address, port, options and request. The control before it
-- shows that the path connects and answers seconds earlier. The control
-- after it was closed, cleared, recreated and connected exactly as the decoy
-- was, from the same state, so its answer shows that the decoy's connect was
-- made too [assumed: that what held for the probe after the decoy held for
-- the decoy]. A decoy that then stays silent was refused for its CA file.
-- Only an HTTP status line proves that the decoy's handshake succeeded;
-- whether "ONLINE" comes before or after the handshake is not documented
-- (on OS 3.4.3 a refused decoy reported none), so a decoy that went "ONLINE"
-- and then nothing is not counted as silent.
--
-- Re-addressing [assumed]: SetBindingAddress is the documented call that
-- gives an existing connection its address (SDK 32/_16), and it comes after
-- every CreateNetworkConnection so that a binding a clear dropped gets its
-- address back. Whether it does, on a given OS, is what the controls find
-- out: if not, a probe after a clear never answers, the check reads
-- "inconclusive", and nothing keyed goes out on the network connection.
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
-- "OFFLINE" of a closed probe taken for the decoy's would read as a failed
-- decoy. Every close may bring one [assumed, as in netstream]: it is owed for
-- STALE_MS, and an "OFFLINE" while one is owed is taken for it, whenever it
-- comes, also after the next probe's "ONLINE" (netstream lets "ONLINE" clear
-- the debt; here the safe side matters more). A probe's own "OFFLINE" taken
-- so leaves the probe to its timeout, which never makes a failure an answer:
-- a decoy then reads silent (and needs the confirm), a decoy that went
-- "ONLINE" reads inconclusive. A predecessor's close (the driver updated
-- while a check ran; OnDriverDestroyed cancels it) is not counted: its
-- report comes long before this run's first probe, which waits for the
-- identity check and the C4:url TLS check [assumed].
--
-- The driver's globals feed two entry points, for BINDING only:
--   OnConnectionStatusChanged(idBinding, nPort, strStatus)
--       -> netcheck.on_status_changed(idBinding, nPort, strStatus)
--   ReceivedFromNetwork(idBinding, nPort, strData)
--       -> netcheck.on_data(idBinding, strData)
-- Each returns true when the binding is the probes' (handled, whatever the
-- state) and false for any other. Neither the next probe nor the verdict
-- starts inside them (timers of GAP_MS and 1 ms): the driver starts the
-- event stream from the verdict, and whether a transfer or a connection may
-- start inside ReceivedFromNetwork is not known (netstream's header, §5
-- test 6).
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

netcheck.BINDING = 6002                         -- the probes' own; the stream's is netstream.BINDING (6001)
netcheck.PORT = netstream.PORT                  -- 443
netcheck.CONNECTION_TYPE = netstream.CONNECTION_TYPE -- "SSL"
netcheck.DECOY_CA = tlscheck.DECOY_CA           -- "certs/decoy_ca.pem"
netcheck.PATH = "/api/0/config"
netcheck.TIMEOUT = 10        -- seconds per probe: a control's answer, the decoy's silence
netcheck.GAP_MS = 1500       -- from a probe's close to the next probe [assumed: the closed one has wound down]
netcheck.STALE_MS = 5000     -- a close's "OFFLINE" not come by then never will [assumed]
netcheck.MAX_ANSWER = 1024   -- bytes of a probe's answer kept for the verdict; a status line is far shorter
netcheck.RETRY_MIN = 30      -- seconds before the driver asks again after an inconclusive answer, doubling
netcheck.RETRY_MAX = 300
-- The persisted Director version on which the check answered "pinned".
netcheck.STORE_NAME = "netstream_pinned_on"

-- The check in flight: { ip, callback, step = "control" | "decoy" | "confirm",
-- phase = "opening" | "open" | "gap" | "done", online, received, timer,
-- gap_timer, decoy (how the decoy failed) }.
local current = nil
local delivery = nil      -- the 1 ms timer that delivers a verdict
local owed_offline = 0    -- "OFFLINE" reports the probes' own closes may still bring
local closed_at = nil     -- ms clock of the last close
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

-- The decoy's tPortParams: the stream's (netstream.port_options, a new table
-- per call) with the decoy as CACERTFILE; nil without a CA configuration.
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
	if check.gap_timer then
		check.gap_timer:Cancel()
		check.gap_timer = nil
	end
end

-- True while a probe's connection is opening or open.
local function connected(check)
	return check.phase == "opening" or check.phase == "open"
end

-- Close the probe's connection and clear the binding's address, each call
-- under pcall, and owe the "OFFLINE" the close may bring (see the header).
local function close()
	local now = now_ms()
	if closed_at and now - closed_at >= netcheck.STALE_MS then
		owed_offline = 0
	end
	owed_offline = owed_offline + 1
	closed_at = now
	local ok, err = pcall(function()
		C4:NetDisconnect(netcheck.BINDING, netcheck.PORT)
	end)
	if not ok then
		log.warn("network connection TLS check: NetDisconnect failed: %s", tostring(err))
	end
	ok, err = pcall(function()
		C4:SetBindingAddress(netcheck.BINDING, "")
	end)
	if not ok then
		log.warn("network connection TLS check: could not clear the probe binding's address: %s", tostring(err))
	end
end

-- The verdict: close and clear a probe still open, then deliver from a 1 ms
-- timer. Once per check; nothing for a check cancelled or replaced.
local function finish(check, verdict, detail)
	if current ~= check then
		return
	end
	current = nil
	cancel_timers(check)
	if connected(check) then
		close()
	end
	check.phase = "done"
	log.debug("network connection TLS check: %s (%s)", verdict, detail)
	delivery = C4:SetTimer(1, function()
		delivery = nil
		check.callback(verdict, detail)
	end)
end

-- What a probe did, for the detail: `outcome` and `extra` as for step_ended.
local function outcome_text(check, outcome, extra)
	if outcome == "silence" then
		return string.format("was silent for %d s", netcheck.TIMEOUT)
	elseif outcome == "no_answer" then
		return string.format("went ONLINE, then gave no answer within %d s", netcheck.TIMEOUT)
	elseif outcome == "offline" then
		return check.online and "went ONLINE, then OFFLINE without an answer" or "went OFFLINE before ONLINE"
	elseif outcome == "garbage" then
		return string.format("got an answer that is no HTTP answer (%s bytes)", tostring(extra))
	end
	return tostring(extra) -- "error": the caller's own words
end

local open_step

-- The next probe, GAP_MS after this one's close.
local function next_step(check, step)
	check.gap_timer = C4:SetTimer(netcheck.GAP_MS, function()
		check.gap_timer = nil
		if current == check then
			open_step(check, step)
		end
	end)
end

-- The open probe ended: `outcome` is "answered" (`extra` the status code),
-- "silence", "no_answer", "offline", "garbage" (`extra` the byte count) or
-- "error" (`extra` what went wrong). Close and clear, then the next probe or
-- the verdict (see the header). A no-op once the probe has ended.
local function step_ended(check, outcome, extra)
	if current ~= check or not connected(check) then
		return
	end
	cancel_timers(check)
	close()
	check.phase = "gap"
	local step = check.step
	log.debug("network connection TLS check: the %s probe ended: %s", step, outcome)
	if step == "control" then
		if outcome == "answered" then
			return next_step(check, "decoy")
		end
		return finish(check, "inconclusive", "the control with the Signify roots " .. outcome_text(check, outcome, extra))
	elseif step == "decoy" then
		if outcome == "answered" then
			return finish(check, "not_pinned", string.format("HTTP %s with the decoy CA file", tostring(extra)))
		end
		if outcome == "silence" or outcome == "offline" then
			check.decoy = outcome_text(check, outcome, extra)
			return next_step(check, "confirm")
		end
		return finish(check, "inconclusive", "the probe with the decoy CA file " .. outcome_text(check, outcome, extra))
	end
	if outcome == "answered" then
		return finish(check, "pinned", string.format("the probe with the decoy CA file %s; the Signify roots answered "
			.. "before and after it", check.decoy))
	end
	finish(check, "inconclusive", string.format("the control after the decoy %s, so the decoy's failure proves nothing",
		outcome_text(check, outcome, extra)))
end

-- Open probe `step` (see the header): recreate the binding and connect.
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
	check.step, check.phase, check.online, check.received = step, "opening", false, ""
	if closed_at and now_ms() - closed_at >= netcheck.STALE_MS then
		owed_offline = 0 -- what the last close brought has come by now, or never will [assumed]
	end
	check.timer = C4:SetTimer(netcheck.TIMEOUT * 1000, function()
		check.timer = nil
		step_ended(check, check.online and "no_answer" or "silence")
	end)
	local ok, err = pcall(function()
		local binding, port, kind = netcheck.BINDING, netcheck.PORT, netcheck.CONNECTION_TYPE
		C4:CreateNetworkConnection(binding, check.ip, kind)
		C4:SetBindingAddress(binding, check.ip)
		C4:NetPortOptions(binding, port, kind, options)
		C4:NetConnect(binding, port)
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
	local check = { ip = ip, callback = callback, phase = "gap" }
	current = check
	if not header_safe(ip) then
		return finish(check, "inconclusive", "the bridge address cannot go into a request")
	end
	open_step(check, "control")
end

-- Drop the check in flight, and a verdict not yet delivered: no callback. A
-- probe still open is closed and its address cleared.
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
	if connected(check) then
		close()
	end
	check.phase = "done"
	log.debug("network connection TLS check cancelled")
end

local function on_online(check)
	if check.phase ~= "opening" then
		log.debug("network connection TLS check: ONLINE ignored (already online)")
		return
	end
	check.phase, check.online = "open", true
	local request = probe_request(check.ip)
	local ok, err = pcall(function()
		C4:SendToNetwork(netcheck.BINDING, netcheck.PORT, request)
	end)
	if not ok then
		return step_ended(check, "error", "could not send its request: " .. tostring(err))
	end
	log.debug("network connection TLS check: the %s probe is online; GET %s sent, no key", check.step, netcheck.PATH)
end

-- Director's OnConnectionStatusChanged, routed by the driver.
function netcheck.on_status_changed(binding, port, status)
	if tonumber(binding) ~= netcheck.BINDING then
		return false
	end
	status = tostring(status):upper()
	local check = current
	if status == "OFFLINE" then
		if owed_offline > 0 then
			owed_offline = owed_offline - 1
			log.debug("network connection TLS check: OFFLINE taken for a closed probe's")
		elseif check and connected(check) then
			step_ended(check, check.received ~= "" and "garbage" or "offline", #check.received)
		else
			log.debug("network connection TLS check: OFFLINE with no probe open ignored")
		end
	elseif status == "ONLINE" then
		if check and connected(check) then
			on_online(check)
		else
			log.debug("network connection TLS check: ONLINE with no probe open ignored")
		end
	else
		log.debug("network connection TLS check: connection status %s on port %s ignored", status, tostring(port))
	end
	return true
end

-- Director's ReceivedFromNetwork, routed by the driver: a probe's answer, in
-- pieces of any size. Never logged, only counted.
function netcheck.on_data(binding, data)
	if tonumber(binding) ~= netcheck.BINDING then
		return false
	end
	if type(data) ~= "string" or data == "" then
		return true
	end
	local check = current
	if not (check and connected(check)) then
		log.debug("network connection TLS check: %d byte(s) with no probe open ignored", #data)
		return true
	end
	if #check.received < netcheck.MAX_ANSWER then
		check.received = check.received .. data:sub(1, netcheck.MAX_ANSWER - #check.received)
	end
	local code = status_code(check.received)
	if code then
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
