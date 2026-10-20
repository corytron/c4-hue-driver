-- Finds a way of handing the Signify CA bundle to C4:url that the controller
-- accepts, by trying candidates against the unauthenticated /api/0/config.
--
-- Two hardware runs on OS 3.4.2 have shown:
--   ssl_cacerts = {"certs/x.pem"} (relative to the .c4z)   -> Lua error at
--       Get(): "Error loading certificate: fopen: No such file or directory"
--   ssl_cabundle = GetSandboxDir().."/hue_ca_bundle.pem"   -> curl error 77
--       "Problem with the SSL CA cert (path? access rights?)"
-- The DriverWorks file APIs resolve paths through aliases ("SANDBOX:/f",
-- "C4Z:/f"), so those forms are tried first. The last candidate disables
-- verification; it is never chosen, only reported, to show whether TLS
-- works at all.

local log = require("common.log")
local http = require("bridge.http")
local certs = require("bridge.certs")

local probe = {}

probe.TIMEOUT = 10

local function driver_name()
	local ok, file = pcall(function() return C4:GetDriverFileName() end)
	if ok and type(file) == "string" then
		return (file:gsub("%.c4z$", ""))
	end
	return "hue_bridge"
end

local function device_id()
	local ok, id = pcall(function() return C4:GetDeviceID() end)
	return ok and tostring(id) or "?"
end

local function c4z_pems(prefix)
	return { prefix .. "certs/hue_root_bridge.pem", prefix .. "certs/hue_root_ca_01.pem" }
end

-- Ordered list of { name, ca }. `ca` is an http CA description.
function probe.candidates()
	local f = certs.FILE
	local sandbox = C4:GetSandboxDir() .. "/" .. f
	local c4z_abs = C4:GetC4zDir() .. "/" .. driver_name() .. "/"
	local lua_sandbox = "/lua/sandbox/" .. device_id() .. "/" .. f
	return {
		{ name = "cabundle SANDBOX alias", ca = { mode = "cabundle", path = "SANDBOX:/" .. f } },
		{ name = "cacerts SANDBOX alias", ca = { mode = "cacerts", paths = { "SANDBOX:/" .. f } } },
		{ name = "cacerts C4Z alias", ca = { mode = "cacerts", paths = c4z_pems("C4Z:/") } },
		{ name = "cabundle relative", ca = { mode = "cabundle", path = f } },
		{ name = "cacerts relative", ca = { mode = "cacerts", paths = { f } } },
		{ name = "cabundle GetSandboxDir", ca = { mode = "cabundle", path = sandbox } },
		{ name = "cacerts GetSandboxDir", ca = { mode = "cacerts", paths = { sandbox } } },
		{ name = "cabundle /lua/sandbox", ca = { mode = "cabundle", path = lua_sandbox } },
		{ name = "cacerts GetC4zDir", ca = { mode = "cacerts", paths = c4z_pems(c4z_abs) } },
		{ name = "insecure (diagnostic only)", ca = { mode = "insecure" } },
	}
end

-- Try every candidate in turn. `handlers`:
--   on_result(name, ok, detail)   per candidate
--   on_done(winner, insecure_ok)  winner is the first verifying CA that
--                                 worked (nil if none); insecure_ok says
--                                 whether the unverified handshake worked
function probe.run(ip, handlers)
	local candidates = probe.candidates()
	local winner, insecure_ok = nil, false
	local index = 0

	local function next_candidate()
		index = index + 1
		local candidate = candidates[index]
		if not candidate then
			log.always("CA probe finished: %s", winner and http.describe_ca(winner) or "no verifying candidate worked")
			return handlers.on_done(winner, insecure_ok)
		end
		http.request({ ip = ip, path = "/api/0/config", timeout = probe.TIMEOUT, ca = candidate.ca }, function(r)
			local detail = r.ok and ("HTTP " .. tostring(r.code)) or tostring(r.err)
			log.always("CA probe %-28s %s  [%s]", candidate.name, r.ok and "OK  " or "FAIL", detail)
			if handlers.on_result then
				handlers.on_result(candidate.name, r.ok, detail)
			end
			if r.ok then
				if candidate.ca.mode == "insecure" then
					insecure_ok = true
				elseif not winner then
					winner = candidate.ca
				end
			end
			next_candidate()
		end)
	end

	log.always("CA probe: trying %d candidates against %s", #candidates, ip)
	next_candidate()
end

return probe
