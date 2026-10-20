-- Finds a way of handing the Signify CA bundle to C4:url that the controller
-- accepts, by trying candidates against the unauthenticated /api/0/config.
--
-- Established on OS 3.4.2 (run 4 of the spike):
--   ssl_cabundle  is prefixed with the driver's c4z directory
--                 (/opt/control4/var/drivers/c4z/<name>/), so a relative
--                 path works and an absolute path fails with curl error 77.
--                 It REPLACES the system CA bundle: trust is pinned to Signify.
--   ssl_cacerts   is opened by Director itself: absolute paths work, relative
--                 ones fail with an asynchronous LUA_ERROR and no callback.
--                 It ADDS to the system CA bundle, so it pins nothing.
--   The .c4z is extracted on disk, so files shipped in it are reachable.
-- The preferred answer is therefore the bundle shipped inside the archive,
-- referenced relative to it. The remaining candidates are kept as fallbacks
-- and as a check that the base directory really is the c4z directory.
--
-- Each candidate has a guard timer because a failing ssl_cacerts load never
-- calls back. The last candidate disables verification; it is never chosen,
-- only reported, to show whether TLS works at all.

local log = require("common.log")
local http = require("bridge.http")
local certs = require("bridge.certs")

local probe = {}

probe.TIMEOUT = 10          -- seconds, per request
probe.GUARD_EXTRA = 5       -- seconds beyond TIMEOUT before giving up on a callback

-- A public site with an ordinary CA-signed certificate, for the pinning check.
probe.PUBLIC_HOST = "example.com"

-- Ordered list of { name, ca }. `ca` is an http CA description.
function probe.candidates()
	return {
		-- Shipped in the archive; only exists in the c4z directory.
		{ name = "cabundle certs/ in archive", ca = { mode = "cabundle", path = certs.SHIPPED } },
		-- Written to the sandbox at startup; only exists there.
		{ name = "cabundle sandbox relative", ca = { mode = "cabundle", path = certs.FILE } },
		-- Known to work (run 4) but adds to the system CAs instead of replacing them.
		{ name = "cacerts sandbox absolute", ca = { mode = "cacerts", paths = { certs.sandbox_path() } } },
		{ name = "insecure (diagnostic only)", ca = { mode = "insecure" } },
	}
end

-- Try every candidate in turn. `handlers`:
--   on_candidate(index, count, name)  a candidate is about to be tried
--   on_result(name, ok, detail)       per candidate
--   on_done(winner, insecure_ok)      winner is the first verifying CA that
--                                     worked (nil if none); insecure_ok says
--                                     whether the unverified handshake worked
-- Returns a handle with :cancel(); after cancel no handler is called.
function probe.run(ip, handlers)
	local candidates = probe.candidates()
	local winner, insecure_ok = nil, false
	local index = 0
	local handle = { cancelled = false, transfer = nil, guard = nil }

	local function clear_guard()
		if handle.guard then
			handle.guard:Cancel()
			handle.guard = nil
		end
	end

	function handle:cancel()
		self.cancelled = true
		clear_guard()
		if self.transfer then
			self.transfer:Cancel()
			self.transfer = nil
		end
	end

	local function next_candidate()
		if handle.cancelled then return end
		index = index + 1
		local candidate = candidates[index]
		if not candidate then
			log.always("CA probe finished: %s", winner and http.describe_ca(winner) or "no verifying candidate worked")
			return handlers.on_done(winner, insecure_ok)
		end
		if handlers.on_candidate then
			handlers.on_candidate(index, #candidates, candidate.name)
		end

		local settled = false
		local function settle(ok, detail)
			if settled or handle.cancelled then return end
			settled = true
			clear_guard()
			handle.transfer = nil
			log.always("CA probe %-26s %s  [%s]", candidate.name, ok and "OK  " or "FAIL", detail)
			if handlers.on_result then
				handlers.on_result(candidate.name, ok, detail)
			end
			if ok then
				if candidate.ca.mode == "insecure" then
					insecure_ok = true
				elseif not winner then
					winner = candidate.ca
				end
			end
			next_candidate()
		end

		handle.guard = C4:SetTimer((probe.TIMEOUT + probe.GUARD_EXTRA) * 1000, function()
			local t = handle.transfer
			handle.transfer = nil
			if t then t:Cancel() end
			settle(false, "no callback: Director probably logged a LUA_ERROR for this path")
		end)

		handle.transfer = http.request({ ip = ip, path = "/api/0/config", timeout = probe.TIMEOUT, ca = candidate.ca },
			function(r)
				settle(r.ok, r.ok and ("HTTP " .. tostring(r.code)) or tostring(r.err))
			end)
	end

	log.always("CA probe: trying %d candidates against %s", #candidates, ip)
	next_candidate()
	return handle
end

-- Does the chosen CA configuration pin trust to Signify? Two requests to a
-- public site: one with the system CAs (control: should succeed when the
-- controller has internet access), one with `ca` and hostname checking on
-- (should FAIL if the bundle replaces the system CAs). Results are logged;
-- `callback(verdict)` gets one of "pinned", "not_pinned", "inconclusive".
function probe.pinning_check(ca, callback)
	local host = probe.PUBLIC_HOST
	http.request({ ip = host, path = "/", timeout = probe.TIMEOUT, ca = { mode = "system" } }, function(control)
		if not control.ok and not control.code then
			log.always("pinning check: %s unreachable with system CAs (%s); inconclusive", host, tostring(control.err))
			return callback("inconclusive")
		end
		local pinned = { mode = ca.mode, path = ca.path, paths = ca.paths, verify_host = true }
		http.request({ ip = host, path = "/", timeout = probe.TIMEOUT, ca = pinned }, function(r)
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

return probe
