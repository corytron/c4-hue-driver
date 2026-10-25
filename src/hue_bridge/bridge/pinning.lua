-- Manual check that the CA configuration pins trust to Signify: a public
-- CA-signed site must verify with the system CAs (control) and must be
-- rejected with the Hue bundle. For the Check CA Pinning action (dev builds
-- only, bridge/devtools.lua), meant for re-running after a controller OS
-- upgrade. Passed on OS 3.4.2. Release builds run their own check against
-- the bridge itself (bridge/tlscheck.lua).
--
-- Only a certificate-verification failure of the second request reads as
-- "pinned" (http.certificate_failure: curl 60, or 51 on an older curl); a
-- timeout, a refused connection, a name that does not resolve or a transfer
-- that never started says nothing about the bundle and is "inconclusive"
-- [code analysis 2026-10-22, L5]. That a refused certificate gives 60 is
-- verified on OS 3.4.2 (docs/design.md "Certificates"); the other codes are
-- curl's documented ones [assumed].

local log = require("common.log")
local http = require("bridge.http")

local pinning = {}

pinning.PUBLIC_HOST = "example.com"
pinning.TIMEOUT = 10

-- The control request's TLS options, on top of the bundle's (http.options):
-- the platform's CAs (no ssl_cabundle), the hostname checked.
pinning.TLS_SYSTEM = { ssl_verify_peer = true, ssl_verify_host = true, ssl_cabundle = false }

-- `ca` is the bundle in use (http.ca, { path }); `callback(verdict, detail)`
-- gets "pinned", "not_pinned" or "inconclusive" and the reason.
function pinning.check(ca, callback)
	local host = pinning.PUBLIC_HOST
	local described = "ssl_cabundle=" .. tostring(ca.path)
	http.request({ ip = host, path = "/", timeout = pinning.TIMEOUT, tls = pinning.TLS_SYSTEM }, function(control)
		if not control.ok and not control.code then
			log.always("pinning check: %s unreachable with system CAs (%s); inconclusive", host, tostring(control.err))
			return callback("inconclusive", tostring(control.err))
		end
		-- The bundle with hostname checking on, since this is a real hostname.
		local pinned = { ssl_verify_peer = true, ssl_verify_host = true, ssl_cabundle = ca.path }
		http.request({ ip = host, path = "/", timeout = pinning.TIMEOUT, tls = pinned }, function(r)
			if r.code then
				log.always("pinning check: %s accepted with %s; this configuration does NOT replace the system CAs",
					host, described)
				return callback("not_pinned", "HTTP " .. tostring(r.code))
			end
			if not http.certificate_failure(r) then
				log.always("pinning check: %s failed with %s for a reason other than its certificate (%s); "
					.. "inconclusive", host, described, tostring(r.err))
				return callback("inconclusive", tostring(r.err))
			end
			log.always("pinning check: %s rejected with %s (%s); trust is pinned to the Signify roots",
				host, described, tostring(r.err))
			callback("pinned", tostring(r.err))
		end)
	end)
end

return pinning
