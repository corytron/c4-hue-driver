-- Manual check that the CA configuration pins trust to Signify: a public
-- CA-signed site must verify with the system CAs (control) and must be
-- rejected with the Hue bundle. For the Check CA Pinning action, meant for
-- re-running after a controller OS upgrade. Passed on OS 3.4.2.

local log = require("common.log")
local http = require("bridge.http")

local pinning = {}

pinning.PUBLIC_HOST = "example.com"
pinning.TIMEOUT = 10

-- `callback(verdict)` gets "pinned", "not_pinned" or "inconclusive".
function pinning.check(ca, callback)
	local host = pinning.PUBLIC_HOST
	http.request({ ip = host, path = "/", timeout = pinning.TIMEOUT, ca = { mode = "system" } }, function(control)
		if not control.ok and not control.code then
			log.always("pinning check: %s unreachable with system CAs (%s); inconclusive", host, tostring(control.err))
			return callback("inconclusive")
		end
		local pinned = { mode = ca.mode, path = ca.path, paths = ca.paths, verify_host = true }
		http.request({ ip = host, path = "/", timeout = pinning.TIMEOUT, ca = pinned }, function(r)
			if r.code then
				log.always("pinning check: %s accepted with %s; this configuration does NOT replace the system CAs",
					host, http.describe_ca(ca))
				return callback("not_pinned")
			end
			log.always("pinning check: %s rejected with %s (%s); trust is pinned to the Signify roots",
				host, http.describe_ca(ca), tostring(r.err))
			callback("pinned")
		end)
	end)
end

return pinning
