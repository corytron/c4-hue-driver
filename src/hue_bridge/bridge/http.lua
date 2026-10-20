-- HTTPS client for the Hue bridge, built on C4:url().
--
-- Every request verifies the bridge certificate against the Signify roots.
-- Hostname verification is off because the certificate's CN is the bridge ID,
-- not the IP; the bridge ID is checked at the application layer instead (see
-- bridge/pairing.lua and docs/design.md).
--
-- The CA bundle ships inside the .c4z as certs/hue_ca_bundle.pem and is
-- referenced relative to the archive: on OS 3.4.2, C4:url prefixes
-- ssl_cabundle with the extracted archive's directory, and the option
-- replaces the system CA bundle, so trust is pinned to the two Signify roots
-- (spike runs 4 and 5; see docs/design.md). http.ca describes the
-- configuration in use:
--   { mode = "cabundle", path = <file> }   ssl_cabundle, relative to the c4z
--   { mode = "cacerts",  paths = {...} }    ssl_cacerts; Director opens the
--                                          files (absolute paths only) and
--                                          ADDS them to the system CAs
--   { mode = "system" }                     system CAs, hostname checked; for
--                                          public hosts such as discovery
--   { mode = "insecure" }                   no verification; diagnostics only
-- Any description may carry verify_host = true to turn hostname checking on.

local log = require("common.log")

local http = {}

http.DEFAULT_TIMEOUT = 15
http.CONNECT_TIMEOUT = 5

-- Path inside the archive, see tools/gen_ca_bundle.sh.
http.CA_BUNDLE = "certs/hue_ca_bundle.pem"

http.ca = { mode = "cabundle", path = http.CA_BUNDLE }

function http.set_ca(ca)
	http.ca = ca
end

-- Convenience for the common case.
function http.set_ca_bundle(path)
	http.set_ca(path and { mode = "cabundle", path = path } or nil)
end

function http.describe_ca(ca)
	ca = ca or http.ca
	if not ca then
		return "none"
	elseif ca.mode == "cabundle" then
		return "ssl_cabundle=" .. tostring(ca.path)
	elseif ca.mode == "cacerts" then
		return "ssl_cacerts={" .. table.concat(ca.paths or {}, ",") .. "}"
	elseif ca.mode == "system" then
		return "system CAs"
	elseif ca.mode == "insecure" then
		return "INSECURE (no verification)"
	end
	return "unknown mode " .. tostring(ca.mode)
end

-- TLS options for a given CA description.
function http.ssl_options(ca)
	if ca.mode == "insecure" then
		return { ssl_verify_peer = false, ssl_verify_host = false }
	end
	local opts = { ssl_verify_peer = true, ssl_verify_host = ca.mode == "system" or ca.verify_host == true }
	if ca.mode == "cabundle" then
		opts.ssl_cabundle = ca.path
	elseif ca.mode == "cacerts" then
		opts.ssl_cacerts = ca.paths
	end
	return opts
end

-- Shared options for every transfer. `ca` defaults to http.ca.
function http.options(overrides, ca)
	local opts = {
		fail_on_error = false,
		timeout = http.DEFAULT_TIMEOUT,
		connect_timeout = http.CONNECT_TIMEOUT,
	}
	for k, v in pairs(http.ssl_options(ca or http.ca)) do
		opts[k] = v
	end
	for k, v in pairs(overrides or {}) do
		opts[k] = v
	end
	return opts
end

function http.url(ip, path)
	return "https://" .. ip .. path
end

local function headers_for(key, extra)
	local headers = {}
	if key then
		headers["hue-application-key"] = key
	end
	for k, v in pairs(extra or {}) do
		headers[k] = v
	end
	return headers
end

-- Decode a JSON body. Returns the value, or nil and an error string.
function http.decode(body)
	if body == nil or body == "" then
		return nil, "empty body"
	end
	local value, err = C4:JsonDecode(body)
	if value == nil then
		return nil, "invalid JSON: " .. tostring(err)
	end
	return value
end

-- C4:url raises a Lua error at Get()/Post() time for some problems (a CA
-- file it can't open, for one). Turn that into a normal failure.
local function start(transfer, fn)
	local ok, err = pcall(fn)
	if ok then
		return transfer
	end
	return nil, "could not start transfer: " .. tostring(err)
end

-- One request/response exchange. `req` has:
--   ip, path, method ("GET"|"POST"|"PUT"|"DELETE"), key (optional),
--   body (table, JSON-encoded, optional), timeout (optional),
--   ca (optional CA description overriding http.ca, used by the probe).
-- `callback(result)` receives { ok, code, body, json, err }:
--   ok    true when the transfer completed and the status is 2xx
--   code  HTTP status, or nil when no response arrived
--   json  decoded body when it parsed, else nil
--   err   a human-readable reason when ok is false
-- Returns the C4LuaUrl transfer so callers can Cancel() it, or nil when the
-- transfer could not be started (the callback has then already been called).
function http.request(req, callback)
	local method = req.method or "GET"
	local ca = req.ca or http.ca
	if not ca then
		log.warn("%s %s: no CA configuration", method, req.path)
		callback({ ok = false, err = "no CA configuration" })
		return nil
	end

	local url = http.url(req.ip, req.path)
	local data = req.body and C4:JsonEncode(req.body) or nil
	local headers = headers_for(req.key, data and { ["Content-Type"] = "application/json" } or nil)

	log.debug("%s %s", method, url)

	local transfer = C4:url()
		:SetOptions(http.options({ timeout = req.timeout }, ca))
		:OnDone(function(_, responses, err_code, err_msg)
			local result = {}
			local response = responses[#responses]
			if err_code ~= 0 then
				result.ok = false
				result.err = string.format("transfer failed (%d): %s", err_code, tostring(err_msg))
			elseif not response then
				result.ok = false
				result.err = "no response"
			else
				result.code = response.code
				result.body = response.body
				result.json = http.decode(response.body)
				result.ok = response.code >= 200 and response.code < 300
				if not result.ok then
					result.err = "HTTP " .. tostring(response.code)
				end
			end
			if not result.ok then
				log.warn("%s %s: %s", method, req.path, result.err)
			end
			callback(result)
		end)

	local started, err = start(transfer, function()
		if method == "GET" then
			transfer:Get(url, headers)
		elseif method == "POST" then
			transfer:Post(url, data or "", headers)
		elseif method == "PUT" then
			transfer:Put(url, data or "", headers)
		elseif method == "DELETE" then
			transfer:Delete(url, headers)
		else
			transfer:Custom(url, method, data or "", headers)
		end
	end)
	if not started then
		log.warn("%s %s: %s", method, req.path, err)
		callback({ ok = false, err = err })
	end
	return started
end

-- A long-lived GET whose body is handed over chunk by chunk.
-- `handlers`:
--   on_headers(code, headers)  once per response; return true to abort
--   on_chunk(data)             each body chunk
--   on_done(err_code, err_msg, code)  when the transfer ends for any reason;
--                              err_code -2 means it never started
-- Returns the transfer so the caller can Cancel() it, or nil when it could
-- not be started (on_done has then already been called).
function http.stream(req, handlers)
	local ca = req.ca or http.ca
	if not ca then
		handlers.on_done(-2, "no CA configuration", nil)
		return nil
	end

	local url = http.url(req.ip, req.path)
	local headers = headers_for(req.key, req.headers)
	local last_code

	log.debug("STREAM %s (timeout %s s)", url, tostring(req.timeout))

	local transfer = C4:url()
		:SetOptions(http.options({ timeout = req.timeout }, ca))
		:OnHeaders(function(_, response)
			last_code = response.code
			if handlers.on_headers then
				return handlers.on_headers(response.code, response.headers)
			end
		end)
		:OnBodyChunk(function(_, _, chunk)
			if handlers.on_chunk then
				return handlers.on_chunk(chunk)
			end
		end)
		:OnDone(function(_, _, err_code, err_msg)
			if handlers.on_done then
				handlers.on_done(err_code, err_msg, last_code)
			end
		end)

	local started, err = start(transfer, function()
		transfer:Get(url, headers)
	end)
	if not started then
		log.warn("STREAM %s: %s", req.path, err)
		handlers.on_done(-2, err, nil)
	end
	return started
end

return http
