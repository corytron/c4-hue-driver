-- The TLS self-check (issue #53): evidence, on the controller at hand, that
-- C4:url consults the CA bundle this driver names when it verifies the
-- bridge, and does not trust the bridge without it.
--
-- Every bridge request pins trust to the two Signify roots by naming them as
-- ssl_cabundle (bridge/http.lua). That rests on how Director treats the
-- option: the SDK says the file is used instead of the system's bundle
-- [verified: SDK 35_url/_12-SetOption], and on OS 3.4.2 Director reads it
-- from the extracted archive and does exactly that [verified: hardware,
-- docs/design.md "Certificates"]. Another OS release might treat the option
-- otherwise, and what then takes its place decides whether that fails closed
-- or open. So, once the bridge has passed the (unkeyed) identity check, it is
-- asked once more with the same TLS options but a decoy bundle,
-- certs/decoy_ca.pem: a self-signed CA made for this check and nothing else,
-- whose private key was destroyed when it was made, so it has signed nothing
-- and verifies nothing. That request must fail certificate verification. If
-- the bridge answers it, the configured bundle is not what decides, and
-- pinning is not in effect.
--
-- What a refusal proves: the configured bundle is consulted, and the
-- bridge's chain is not trusted without it. What the check cannot prove
-- (security review 2026-10-25, finding 3):
--   (a) That the bundle replaces the system store rather than adding to it.
--       The bridge's private Signify chain fails against the store plus the
--       decoy just as against the decoy alone, so a controller that adds the
--       named file to the store (as ssl_cacerts does on OS 3.4.2) also reads
--       "pinned", while its keyed requests would accept any publicly trusted
--       certificate (hostname checking is off for the bridge). Only a peer
--       with a public-CA certificate tells the two apart: the dev build's
--       Check CA Pinning (bridge/pinning.lua), which the release checklist
--       keeps for the first start after an OS upgrade. A release that adds
--       instead of replacing would break the documented semantics [assumed:
--       none does].
--   (b) Anything against an active attacker. The decoy request is easy to
--       recognise on the wire (the first TLS handshake after the identity
--       GET), so whoever can drop it can always make the check
--       inconclusive. Pinning is a property of the OS, not of the network:
--       the driver accepts "inconclusive" only on a Director version that has
--       answered "pinned" before (remember_pinned and pinned_before, below);
--       on a new or upgraded OS nothing keyed is sent until a conclusive
--       answer (hue_bridge/driver.lua tls_gate, docs/design.md "TLS
--       self-check in release builds").
--
-- tlscheck.run(ip, callback) calls callback(verdict, detail) once:
--   "pinned"        the decoy request failed certificate verification
--   "not_pinned"    it got an HTTP answer, whatever the status: the TLS
--                   handshake succeeded without the Signify roots
--   "inconclusive"  it failed for another reason (a timeout, a refused
--                   connection, a name that does not resolve, the decoy
--                   unreadable, a transfer that never started): nothing is
--                   learnt about the bundle
-- `detail` is the HTTP status or the transfer's error, for the log. run()
-- remembers nothing itself: the driver calls remember_pinned() on "pinned".
--
-- The request is GET /api/0/config, the bridge's public configuration, and
-- it never carries the application key: the key goes only to a peer
-- verified against the Signify roots, and this one is verified against
-- nothing. How a certificate failure is told from the rest:
-- http.certificate_failure.
--
-- A request with another bundle is verified afresh rather than served from
-- a connection or TLS session the normal bundle verified. Evidence: on OS
-- 3.4.2 the Check CA Pinning action answered "pinned", so its second request
-- to example.com, sent right after a successful one with the system's CAs,
-- was refused with the Signify bundle (curl 60) [verified indirectly:
-- hardware, docs/design.md "Certificates", bridge/pinning.lua]. libcurl
-- compares the SSL settings, CA file included, before reusing either
-- [assumed: libcurl behaviour; Director's curl build is not documented].
--
-- The memory of a "pinned" answer: remember_pinned() stores the running
-- Director version, C4:GetVersionInfo().version [verified: SDK
-- 5_director_command/_2-GetVersionInfo: a string of four dotted numbers,
-- major to build; the call may be made from OnDriverInit on], under
-- STORE_NAME; pinned_before() is true only while the running version is that
-- same non-empty string. The version carries the build number, so a Director
-- update asks for a conclusive answer again [assumed: every OS update changes
-- it]. A version that cannot be read is never remembered and never matches,
-- so on such a controller "inconclusive" always blocks: the safe side. The
-- value is no secret and is stored unencrypted (the flag is optional
-- [verified: SDK 26.5_persistence/_4-PersistSetValue]). PersistGetValue may
-- not return a value written moments earlier (docs/design.md "Storage"), so
-- pinned_before() also trusts what remember_pinned() wrote in this run.

local log = require("common.log")
local http = require("bridge.http")

local tlscheck = {}

-- Path inside the archive, in the same relative form as http.CA_BUNDLE.
tlscheck.DECOY_CA = "certs/decoy_ca.pem"
tlscheck.PATH = "/api/0/config"
tlscheck.TIMEOUT = 10
-- The persisted Director version on which the check answered "pinned".
tlscheck.STORE_NAME = "tls_pinned_on"

-- What remember_pinned() wrote in this run (nil until then): the store may
-- not return it yet.
local remembered = nil

function tlscheck.run(ip, callback)
	-- On top of the bundle's options (http.options): the peer verified, the
	-- hostname not, exactly as for every bridge request; only the bundle
	-- differs. Quiet: the expected outcome is a failed transfer, and the
	-- driver logs the verdict itself.
	http.request({
		ip = ip,
		path = tlscheck.PATH,
		timeout = tlscheck.TIMEOUT,
		tls = { ssl_cabundle = tlscheck.DECOY_CA },
		quiet = true,
	}, function(r)
		if r.code then
			return callback("not_pinned", string.format("HTTP %s with the decoy bundle", tostring(r.code)))
		end
		if http.certificate_failure(r) then
			return callback("pinned", tostring(r.err))
		end
		callback("inconclusive", tostring(r.err))
	end)
end

-- A non-empty version string, trimmed; a number becomes its string; anything
-- else is nil.
local function as_version(value)
	if type(value) == "number" then
		value = tostring(value)
	end
	if type(value) ~= "string" then
		return nil
	end
	value = value:match("^%s*(.-)%s*$")
	if value == "" then
		return nil
	end
	return value
end

-- Inside the pcall: the call itself and the field read (a missing method,
-- a raise, or a result that is not a table).
local function read_version()
	local info = C4:GetVersionInfo()
	if type(info) == "table" then
		return info.version
	end
	return nil
end

-- The running Director's version as a string, or nil when it cannot be read.
function tlscheck.director_version()
	local ok, version = pcall(read_version)
	if not ok then
		return nil
	end
	return as_version(version)
end

local function store(version)
	C4:PersistSetValue(tlscheck.STORE_NAME, version)
end

local function stored()
	return C4:PersistGetValue(tlscheck.STORE_NAME)
end

-- Remember that the running Director version answered "pinned". Returns the
-- version, or nil (and stores nothing) when it cannot be read. A store that
-- raises is logged; this run still remembers.
function tlscheck.remember_pinned()
	local version = tlscheck.director_version()
	if not version then
		return nil
	end
	remembered = version
	local ok, err = pcall(store, version)
	if not ok then
		log.warn("TLS check: could not store the Director version %s: %s", version, tostring(err))
	end
	return version
end

-- True only when the running Director version is known and equals the one
-- remembered for a "pinned" answer (in this run, or persisted by an earlier
-- one). Always a boolean.
function tlscheck.pinned_before()
	local version = tlscheck.director_version()
	if not version then
		return false
	end
	if remembered == version then
		return true
	end
	local ok, value = pcall(stored)
	return ok and type(value) == "string" and value == version
end

return tlscheck
