-- The TLS self-check (issue #53): proof, on the controller at hand, that
-- C4:url verifies the bridge against the CA bundle this driver names, not
-- against something else.
--
-- Every bridge request pins trust to the two Signify roots by naming them as
-- ssl_cabundle (bridge/http.lua). That rests on how Director treats the
-- option: on OS 3.4.2 it reads the file from the extracted archive and uses
-- it instead of the system's bundle [verified: hardware, docs/design.md
-- "Certificates"]. Another OS release might ignore the option, and what then
-- takes its place decides whether that fails closed or open. So, once the
-- bridge has passed the (unkeyed) identity check, it is asked once more with
-- the same TLS options but a decoy bundle, certs/decoy_ca.pem: a self-signed
-- CA made for this check and nothing else, whose private key was destroyed
-- when it was made, so it has signed nothing and verifies nothing. That
-- request must fail certificate verification. If the bridge answers it, the
-- configured bundle is not what decides, and pinning is not in effect.
--
-- tlscheck.run(ip, callback) calls callback(verdict, detail) once:
--   "pinned"        the decoy request failed certificate verification
--   "not_pinned"    it got an HTTP answer, whatever the status: the TLS
--                   handshake succeeded without the Signify roots
--   "inconclusive"  it failed for another reason (a timeout, a refused
--                   connection, a name that does not resolve, the decoy
--                   unreadable, a transfer that never started): nothing is
--                   learnt, and the driver asks again at its next identity check
-- `detail` is the HTTP status or the transfer's error, for the log.
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

local http = require("bridge.http")

local tlscheck = {}

-- Path inside the archive, in the same relative form as http.CA_BUNDLE.
tlscheck.DECOY_CA = "certs/decoy_ca.pem"
tlscheck.PATH = "/api/0/config"
tlscheck.TIMEOUT = 10

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

return tlscheck
