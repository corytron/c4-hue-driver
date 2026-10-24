-- Manual check that the CA configuration pins trust to Signify: a public
-- CA-signed site must verify with the system CAs (control) and must be
-- rejected with the Hue bundle. For the Check CA Pinning action (dev builds
-- only, bridge/devtools.lua), meant for re-running after a controller OS
-- upgrade. Passed on OS 3.4.2.

local log = require("common.log")
local http = require("bridge.http")

local pinning = {}

pinning.PUBLIC_HOST = "example.com"
pinning.TIMEOUT = 10

-- The control request's TLS options: the platform's CAs, hostname checked.
pinning.TLS_SYSTEM = { ssl_verify_peer = true, ssl_verify_host = true }

-- `ca` is the bundle in use (http.ca, { path }); `callback(verdict)` gets
-- "pinned", "not_pinned" or "inconclusive".
function pinning.check(ca, callback)
	local host = pinning.PUBLIC_HOST
	local described = "ssl_cabundle=" .. tostring(ca.path)
	http.request({ ip = host, path = "/", timeout = pinning.TIMEOUT, tls = pinning.TLS_SYSTEM }, function(control)
		if not control.ok and not control.code then
			log.always("pinning check: %s unreachable with system CAs (%s); inconclusive", host, tostring(control.err))
			return callback("inconclusive")
		end
		-- The bundle with hostname checking on, since this is a real hostname.
		local pinned = { ssl_verify_peer = true, ssl_verify_host = true, ssl_cabundle = ca.path }
		http.request({ ip = host, path = "/", timeout = pinning.TIMEOUT, tls = pinned }, function(r)
			if r.code then
				log.always("pinning check: %s accepted with %s; this configuration does NOT replace the system CAs",
					host, described)
				return callback("not_pinned")
			end
			log.always("pinning check: %s rejected with %s (%s); trust is pinned to the Signify roots",
				host, described, tostring(r.err))
			callback("pinned")
		end)
	end)
end

return pinning
