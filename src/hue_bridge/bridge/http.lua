-- HTTPS client for the Hue bridge, built on C4:url().
--
-- Every request verifies the bridge certificate against the Signify roots
-- bundled in certs/. Hostname verification is off because the certificate's
-- CN is the bridge ID, not the IP; the bridge ID is checked at the
-- application layer instead (see bridge/pairing.lua and docs/design.md).

local log = require("common.log")

local http = {}

-- Paths are relative to the .c4z root, as the ssl_cacerts option requires.
http.CA_CERTS = { "certs/hue_root_bridge.pem", "certs/hue_root_ca_01.pem" }

http.DEFAULT_TIMEOUT = 15
http.CONNECT_TIMEOUT = 5

-- Shared TLS and timing options for every transfer.
function http.options(overrides)
	local opts = {
		fail_on_error = false,
		timeout = http.DEFAULT_TIMEOUT,
		connect_timeout = http.CONNECT_TIMEOUT,
		ssl_verify_peer = true,
		ssl_verify_host = false,
		ssl_cacerts = http.CA_CERTS,
	}
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

-- One request/response exchange. `req` has:
--   ip, path, method ("GET"|"POST"|"PUT"|"DELETE"), key (optional),
--   body (table, JSON-encoded, optional), timeout (optional).
-- `callback(result)` receives { ok, code, body, json, err }:
--   ok    true when the transfer completed and the status is 2xx
--   code  HTTP status, or nil when no response arrived
--   json  decoded body when it parsed, else nil
--   err   a human-readable reason when ok is false
-- Returns the C4LuaUrl transfer so callers can Cancel() it.
function http.request(req, callback)
	local url = http.url(req.ip, req.path)
	local data = req.body and C4:JsonEncode(req.body) or nil
	local headers = headers_for(req.key, data and { ["Content-Type"] = "application/json" } or nil)
	local method = req.method or "GET"

	log.debug("%s %s", method, url)

	local transfer = C4:url()
		:SetOptions(http.options({ timeout = req.timeout }))
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
	return transfer
end

-- A long-lived GET whose body is handed over chunk by chunk.
-- `handlers`:
--   on_headers(code, headers)  once per response; return true to abort
--   on_chunk(data)             each body chunk
--   on_done(err_code, err_msg, code)  when the transfer ends for any reason
-- Returns the transfer so the caller can Cancel() it.
function http.stream(req, handlers)
	local url = http.url(req.ip, req.path)
	local headers = headers_for(req.key, req.headers)
	local last_code

	log.debug("STREAM %s (timeout %s s)", url, tostring(req.timeout))

	return C4:url()
		:SetOptions(http.options({ timeout = req.timeout }))
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
		:Get(url, headers)
end

return http
