-- Finds a way of handing the Signify CA bundle to C4:url that the controller
-- accepts, by trying candidates against the unauthenticated /api/0/config.
--
-- Hardware runs on OS 3.4.2 so far:
--   ssl_cacerts {"certs/x.pem"} (relative to the .c4z)  -> Lua error at Get():
--       "Error loading certificate: fopen: No such file or directory"
--   ssl_cabundle GetSandboxDir().."/f"   -> curl error 77 (CA cert unreadable)
--   ssl_cabundle "SANDBOX:/f"            -> curl error 77: aliases are not
--       resolved for ssl_cabundle; the string goes straight to curl
--   ssl_cacerts {"SANDBOX:/f"}           -> Director logs a LUA_ERROR
--       asynchronously and never calls OnDone: aliases are not resolved
--       here either, and the failure is invisible to the driver
-- So each candidate has a guard timer: if no callback arrives in time the
-- candidate is marked "no callback" and the probe moves on.
--
-- The last candidate disables verification; it is never chosen, only
-- reported, to show whether TLS works at all.

local log = require("common.log")
local http = require("bridge.http")
local certs = require("bridge.certs")

local probe = {}

probe.TIMEOUT = 10          -- seconds, per request
probe.GUARD_EXTRA = 5       -- seconds beyond TIMEOUT before giving up on a callback

local function device_id()
	local ok, id = pcall(function() return C4:GetDeviceID() end)
	return ok and tostring(id) or "?"
end

-- Ordered list of { name, ca }. `ca` is an http CA description.
function probe.candidates()
	local f = certs.FILE
	local sandbox = certs.sandbox_path()
	local c4z = certs.c4z_path()
	local lua_sandbox = "/lua/sandbox/" .. device_id() .. "/" .. f
	return {
		{ name = "cacerts GetSandboxDir", ca = { mode = "cacerts", paths = { sandbox } } },
		{ name = "cacerts relative name", ca = { mode = "cacerts", paths = { f } } },
		{ name = "cabundle C4Z dir", ca = { mode = "cabundle", path = c4z } },
		{ name = "cacerts C4Z dir", ca = { mode = "cacerts", paths = { c4z } } },
		{ name = "cabundle /lua/sandbox", ca = { mode = "cabundle", path = lua_sandbox } },
		{ name = "cacerts /lua/sandbox", ca = { mode = "cacerts", paths = { lua_sandbox } } },
		{ name = "cabundle relative name", ca = { mode = "cabundle", path = f } },
		{ name = "cabundle GetSandboxDir", ca = { mode = "cabundle", path = sandbox } },
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

return probe
