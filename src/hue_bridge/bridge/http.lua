-- HTTPS client for the Hue bridge, built on C4:url().
--
-- Every request verifies the bridge certificate against the Signify roots.
-- Hostname verification is off because the certificate's CN is the bridge ID,
-- not the IP; the bridge ID is checked at the application layer instead (see
-- bridge/pairing.lua and docs/design.md). The CA bundle path is set once at
-- startup by bridge/certs.lua; until then every request fails fast.

local log = require("common.log")

local http = {}

http.DEFAULT_TIMEOUT = 15
http.CONNECT_TIMEOUT = 5

-- Absolute path of the CA bundle, see certs.install().
http.ca_bundle = nil

function http.set_ca_bundle(path)
	http.ca_bundle = path
end

-- Shared TLS and timing options for every transfer.
function http.options(overrides)
	local opts = {
		fail_on_error = false,
		timeout = http.DEFAULT_TIMEOUT,
		connect_timeout = http.CONNECT_TIMEOUT,
		ssl_verify_peer = true,
		ssl_verify_host = false,
		ssl_cabundle = http.ca_bundle,
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
--   body (table, JSON-encoded, optional), timeout (optional).
-- `callback(result)` receives { ok, code, body, json, err }:
--   ok    true when the transfer completed and the status is 2xx
--   code  HTTP status, or nil when no response arrived
--   json  decoded body when it parsed, else nil
--   err   a human-readable reason when ok is false
-- Returns the C4LuaUrl transfer so callers can Cancel() it, or nil when the
-- transfer could not be started (the callback has then already been called).
function http.request(req, callback)
	local method = req.method or "GET"
	if not http.ca_bundle then
		log.warn("%s %s: CA bundle not installed", method, req.path)
		callback({ ok = false, err = "CA bundle not installed" })
		return nil
	end

	local url = http.url(req.ip, req.path)
	local data = req.body and C4:JsonEncode(req.body) or nil
	local headers = headers_for(req.key, data and { ["Content-Type"] = "application/json" } or nil)

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
	if not http.ca_bundle then
		handlers.on_done(-2, "CA bundle not installed", nil)
		return nil
	end

	local url = http.url(req.ip, req.path)
	local headers = headers_for(req.key, req.headers)
	local last_code

	log.debug("STREAM %s (timeout %s s)", url, tostring(req.timeout))

	local transfer = C4:url()
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
