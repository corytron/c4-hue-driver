-- The TLS self-check of the network connection (issue #317): evidence, on
-- the controller at hand, that a network connection verifies the bridge
-- against the CA file its port options name, and does not trust the bridge
-- without it. bridge/tlscheck.lua does the same for C4:url (issue #53).
--
-- Why: the event stream holds a network connection (bridge/netstream.lua,
-- binding 6001) with CACERTFILE = the two Signify roots and VERIFY_MODE =
-- "peer", and its GET carries the application key. That the stream works
-- with those options [verified: hardware, build 413, 2026-10-27] shows that
-- the file is read, not that it decides: were VERIFY_MODE or CACERTFILE
-- ignored on some OS release, the key would go to any peer that answers on
-- the bridge's address. So before the stream's first keyed connect of a run
-- the bridge is asked once more with the same options but a decoy CA file,
-- certs/decoy_ca.pem (tlscheck.DECOY_CA: a self-signed CA that has signed
-- nothing and verifies nothing). That handshake must fail.
--
-- netcheck.run(ip, callback):
--  1. The control: GET /api/0/config over C4:url with the Signify roots and
--     no key (http.request), the identity check's own request. It must get
--     an HTTP answer, any status: the bridge is up at this address and
--     completes a handshake verified against the Signify roots. Without
--     one, the probe is not opened and the answer is "inconclusive".
--  2. Right after it, the probe: a second dynamic binding, BINDING (6002),
--     to the same address, port 443, "SSL", with netstream.port_options()
--     except CACERTFILE = the decoy. No NetDisconnect before its NetConnect
--     (see "Stale reports"). On ONLINE it sends GET /api/0/config with a
--     Host header and no key (probe_request below).
--  3. The verdict, callback(verdict, detail), once:
--       "not_pinned"    an HTTP status line arrived on the probe, whatever
--                       the status: the handshake succeeded without the
--                       Signify roots
--       "pinned"        the probe went OFFLINE with no HTTP answer, before
--                       or after ONLINE (see below)
--       "inconclusive"  anything else: no answer to the control, no verdict
--                       TIMEOUT (10 s) after the connect, data that is no
--                       HTTP answer, a C4 call that raised, no CA
--                       configuration, an address that cannot go into a
--                       request
--     `detail` says what happened, for the log and the Event Stream row.
--  4. Binding 6002 is closed and cleared, whatever the outcome, before the
--     verdict is delivered: NetDisconnect, then SetBindingAddress with ''
--     as netstream.clear_address does for 6001. A probe that never got as
--     far as creating the connection has nothing to close.
-- run() remembers nothing itself: the driver calls remember_pinned() on
-- "pinned" (hue_bridge/driver.lua, net_gate).
--
-- Why OFFLINE reads "pinned". A network connection reports nothing but
-- "ONLINE" and "OFFLINE" [verified: SDK 32/_27-OnConnectionStatusChanged]:
-- no error code tells a failed certificate verification from a refused,
-- reset or unreachable connection, as curl's code 60 does for C4:url
-- (http.certificate_failure). Nor does "ONLINE" settle anything: whether
-- Director reports it after the TCP connect or after the TLS handshake is
-- not documented (bridge/netstream.lua header), so no verdict rests on it.
-- Application data does: only a completed handshake delivers any, so an
-- HTTP status line is the one proof that the decoy was accepted. A probe
-- that ends without one is read as refused because of the control: moments
-- earlier the same bridge, at the same address and port, answered the same
-- request over a connection verified against the Signify roots, and the
-- probe differs from that in its CA file [assumed: that Director's network
-- connection reaches the bridge as C4:url does, and that a refused
-- handshake ends in "OFFLINE" rather than in silence, which would read
-- "inconclusive" every time; docs/raw-stream-design.md §5 tests 3 and 8].
--
-- What the check cannot prove:
--  (a) As tlscheck's (a): that the file replaces the system's CA store
--      rather than adding to it. The bridge's private Signify chain fails
--      against the store plus the decoy just as against the decoy alone.
--  (b) Anything against an active attacker, and less than tlscheck: one who
--      can reset or drop the probe's connection makes it read "pinned", not
--      only "inconclusive". Hence the probe runs at every start of the
--      driver, never once per Director version: on a controller that does
--      not verify, every run the attacker leaves alone reads "not_pinned"
--      and falls back. The memory of a "pinned" answer (remember_pinned,
--      pinned_before) only lets an "inconclusive" answer pass on that same
--      Director version, as tlscheck's does.
--
-- Stale reports. Director's callbacks carry no connection identity, and an
-- "OFFLINE" taken for the probe's would read "pinned". So the probe never
-- disconnects before it connects, unlike netstream: the connection is
-- created afresh for every probe and closed after it. That close may still
-- bring an "OFFLINE" [assumed, as in netstream]. One that has not come when
-- the next probe connects, if that is within STALE_MS of the close, is
-- owed, and the first "OFFLINE" before "ONLINE" is taken for it: a probe
-- that really failed then reads "inconclusive" at the timeout, the safe
-- side. "ONLINE" clears the debt, as in netstream: what Director reports
-- about a connection it closed comes before the next one is up [assumed].
-- A predecessor's close (the driver updated while a probe ran: the driver's
-- OnDriverDestroyed cancels it) is not counted: its report comes long before
-- this run's first probe connects, which waits for the identity check, the
-- C4:url TLS check and the control [assumed].
--
-- The driver's globals feed two entry points, for BINDING only:
--   OnConnectionStatusChanged(idBinding, nPort, strStatus)
--       -> netcheck.on_status_changed(idBinding, nPort, strStatus)
--   ReceivedFromNetwork(idBinding, nPort, strData)
--       -> netcheck.on_data(idBinding, strData)
-- Each returns true when the binding is the probe's (handled, whatever the
-- state) and false for any other. The verdict comes from a 1 ms C4:SetTimer,
-- never from inside them: the driver starts the event stream from it, and
-- whether a transfer or a connection may start inside ReceivedFromNetwork
-- is not known (netstream's header, §5 test 6).
--
-- DriverWorks calls: those of bridge/netstream.lua, whose header cites the
-- SDK file of each (CreateNetworkConnection, NetPortOptions, NetConnect,
-- SendToNetwork, NetDisconnect, SetBindingAddress), and C4:SetTimer and
-- C4:GetTime as there; C4:url through bridge/http.lua; for the memory, those
-- of bridge/tlscheck.lua (GetVersionInfo through tlscheck.director_version,
-- PersistSetValue, PersistGetValue).
--
-- The memory: remember_pinned() stores the running Director version under
-- STORE_NAME, apart from tlscheck's: each check speaks for its own API.
-- pinned_before() is true only while the running version is that same
-- non-empty string, and also trusts what remember_pinned() wrote in this
-- run (PersistGetValue may not return it yet). As in tlscheck: a version
-- that cannot be read is never remembered and never matches.

local log = require("common.log")
local http = require("bridge.http")
local netstream = require("bridge.netstream")
local tlscheck = require("bridge.tlscheck")

local netcheck = {}

netcheck.BINDING = 6002                         -- the probe's own; the stream's is netstream.BINDING (6001)
netcheck.PORT = netstream.PORT                  -- 443
netcheck.CONNECTION_TYPE = netstream.CONNECTION_TYPE -- "SSL"
netcheck.DECOY_CA = tlscheck.DECOY_CA           -- "certs/decoy_ca.pem"
netcheck.PATH = "/api/0/config"
netcheck.TIMEOUT = 10        -- seconds: the control's transfer, then the probe from its connect
netcheck.STALE_MS = 5000     -- a close's "OFFLINE" not come by then never will [assumed]
netcheck.MAX_ANSWER = 1024   -- bytes of the probe's answer kept for the verdict; a status line is far shorter
netcheck.RETRY_MIN = 30      -- seconds before the driver asks again after an inconclusive answer, doubling
netcheck.RETRY_MAX = 300
-- The persisted Director version on which the probe answered "pinned".
netcheck.STORE_NAME = "netstream_pinned_on"

local current = nil       -- the probe in flight: { ip, callback, phase, created, timer, received }
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

-- The probe's request: the bridge's public configuration, and no key.
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

-- The probe's tPortParams: the stream's (netstream.port_options, a new table
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

-- Close the probe's connection and clear the binding's address; each call
-- under pcall. Counts the "OFFLINE" the close may bring (see the header).
local function close()
	owed_offline = owed_offline + 1
	closed_at = now_ms()
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

local function cancel_timer(probe)
	if probe.timer then
		probe.timer:Cancel()
		probe.timer = nil
	end
end

-- The probe's verdict: close and clear, then deliver from a 1 ms timer. Once
-- per probe; nothing for a probe cancelled or replaced.
local function finish(probe, verdict, detail)
	if current ~= probe then
		return
	end
	current = nil
	cancel_timer(probe)
	if probe.created then
		close()
	end
	log.debug("network connection TLS check: %s (%s)", verdict, detail)
	delivery = C4:SetTimer(1, function()
		delivery = nil
		probe.callback(verdict, detail)
	end)
end

-- Step 2 of the header, once the control has answered.
local function open_probe(probe)
	local options = netcheck.port_options()
	if not options then
		return finish(probe, "inconclusive", "no CA configuration")
	end
	probe.phase = "opening"
	if owed_offline > 0 and closed_at and now_ms() - closed_at >= netcheck.STALE_MS then
		owed_offline = 0 -- what the last close brought has come by now, or never will [assumed]
	end
	probe.timer = C4:SetTimer(netcheck.TIMEOUT * 1000, function()
		probe.timer = nil
		finish(probe, "inconclusive", string.format(probe.phase == "opening"
			and "no connection report within %d s" or "no answer within %d s", netcheck.TIMEOUT))
	end)
	-- Before the calls: one that raises may leave the binding half made.
	probe.created = true
	local ok, err = pcall(function()
		local binding, port, kind = netcheck.BINDING, netcheck.PORT, netcheck.CONNECTION_TYPE
		C4:CreateNetworkConnection(binding, probe.ip, kind)
		C4:NetPortOptions(binding, port, kind, options)
		C4:NetConnect(binding, port)
	end)
	if not ok then
		-- A no-op when Director reported from inside a call and that decided.
		finish(probe, "inconclusive", "could not open the probe connection: " .. tostring(err))
	end
end

-- Run the check against the bridge at `ip`; `callback(verdict, detail)` is
-- called once, unless cancel() or another run() comes first. A probe still
-- in flight is cancelled.
function netcheck.run(ip, callback)
	netcheck.cancel()
	local probe = { ip = ip, callback = callback, phase = "control", created = false, received = "" }
	current = probe
	if not header_safe(ip) then
		return finish(probe, "inconclusive", "the bridge address cannot go into a request")
	end
	if not netcheck.port_options() then
		return finish(probe, "inconclusive", "no CA configuration")
	end
	-- Quiet: the driver logs the verdict, and an unreachable bridge is
	-- already the identity check's to report.
	http.request({ ip = ip, path = netcheck.PATH, timeout = netcheck.TIMEOUT, quiet = true }, function(r)
		if current ~= probe or probe.phase ~= "control" then
			return -- cancelled or replaced meanwhile
		end
		if type(r) ~= "table" or not r.code then
			return finish(probe, "inconclusive", "no answer to the control request: " .. tostring(type(r) == "table"
				and r.err or r))
		end
		log.debug("network connection TLS check: the control request answered HTTP %s; probing with the decoy CA file",
			tostring(r.code))
		open_probe(probe)
	end)
end

-- Drop the probe in flight, and a verdict not yet delivered: no callback.
-- The connection, if it was made, is closed and its address cleared.
function netcheck.cancel()
	if delivery then
		delivery:Cancel()
		delivery = nil
	end
	local probe = current
	if not probe then
		return
	end
	current = nil
	cancel_timer(probe)
	if probe.created then
		close()
	end
	log.debug("network connection TLS check cancelled")
end

local function on_online(probe)
	if probe.phase ~= "opening" then
		log.debug("network connection TLS check: ONLINE ignored (already online)")
		return
	end
	probe.phase = "open"
	owed_offline = 0
	local request = probe_request(probe.ip)
	local ok, err = pcall(function()
		C4:SendToNetwork(netcheck.BINDING, netcheck.PORT, request)
	end)
	if not ok then
		return finish(probe, "inconclusive", "could not send the probe request: " .. tostring(err))
	end
	log.debug("network connection TLS check: online; GET %s sent, no key", netcheck.PATH)
end

local function on_offline(probe)
	if probe.phase == "opening" and owed_offline > 0 then
		owed_offline = owed_offline - 1
		log.debug("network connection TLS check: OFFLINE taken for the close of an earlier probe")
		return
	end
	if probe.received ~= "" then
		local code = status_code(probe.received)
		if code then
			return finish(probe, "not_pinned", string.format("HTTP %s with the decoy CA file", code))
		end
		return finish(probe, "inconclusive", string.format("an answer that is no HTTP answer (%d bytes), then OFFLINE",
			#probe.received))
	end
	if probe.phase == "opening" then
		finish(probe, "pinned", "no connection with the decoy CA file (OFFLINE before ONLINE)")
	else
		finish(probe, "pinned", "the connection with the decoy CA file closed without an answer (ONLINE, then OFFLINE)")
	end
end

-- Director's OnConnectionStatusChanged, routed by the driver.
function netcheck.on_status_changed(binding, port, status)
	if tonumber(binding) ~= netcheck.BINDING then
		return false
	end
	status = tostring(status):upper()
	local probe = current
	if not probe or probe.phase == "control" then
		if status == "OFFLINE" and owed_offline > 0 then
			owed_offline = owed_offline - 1 -- what a close of its own brought
		end
		log.debug("network connection TLS check: %s with no probe connection pending ignored", status)
		return true
	end
	if status == "ONLINE" then
		on_online(probe)
	elseif status == "OFFLINE" then
		on_offline(probe)
	else
		log.debug("network connection TLS check: connection status %s on port %s ignored", status, tostring(port))
	end
	return true
end

-- Director's ReceivedFromNetwork, routed by the driver: the probe's answer,
-- in pieces of any size. Never logged, only counted.
function netcheck.on_data(binding, data)
	if tonumber(binding) ~= netcheck.BINDING then
		return false
	end
	if type(data) ~= "string" or data == "" then
		return true
	end
	local probe = current
	if not probe or probe.phase == "control" then
		log.debug("network connection TLS check: %d byte(s) with no probe connection ignored", #data)
		return true
	end
	if #probe.received < netcheck.MAX_ANSWER then
		probe.received = probe.received .. data:sub(1, netcheck.MAX_ANSWER - #probe.received)
	end
	local code = status_code(probe.received)
	if code then
		finish(probe, "not_pinned", string.format("HTTP %s with the decoy CA file", code))
	elseif probe.received:gsub("^[\r\n]+", ""):find("\n", 1, true) or #probe.received >= netcheck.MAX_ANSWER then
		finish(probe, "inconclusive", string.format("an answer that is no HTTP answer (%d bytes)", #probe.received))
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
