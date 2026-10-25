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
-- (spike runs 4 and 5; see docs/design.md). http.ca is the bundle in use,
-- { path = <file inside the archive> }; nil fails every request.
--
-- That is the only TLS configuration this module knows. A request may adjust
-- it through req.tls, applied on top of it (http.options): the development
-- diagnostics (bridge/conntest.lua and bridge/pinning.lua, dev builds only)
-- for their other targets, and the TLS self-check (bridge/tlscheck.lua),
-- which swaps the bundle for a decoy. No keyed request does: bridge_request
-- in hue_bridge/driver.lua clears req.tls.

local log = require("common.log")

local http = {}

http.DEFAULT_TIMEOUT = 15
http.CONNECT_TIMEOUT = 5

-- Path inside the archive, see tools/gen_ca_bundle.sh.
http.CA_BUNDLE = "certs/hue_ca_bundle.pem"

http.ca = { path = http.CA_BUNDLE }

-- TLS options of every transfer: the peer verified against the bundle, the
-- hostname not (see the header).
local function ssl_options()
	return { ssl_verify_peer = true, ssl_verify_host = false, ssl_cabundle = http.ca.path }
end

-- Shared options for every transfer. `tls` (see the header) is applied on
-- top of the bundle's ssl_* options, so whatever it does not name stays as
-- every bridge request has it: ssl_verify_peer in particular stays true
-- unless `tls` itself sets it false (docs/reviews/diff-review-2026-10-24.md
-- row 6; a partial table used to leave it out altogether). An ssl_cabundle
-- of false leaves the option out, which puts the platform's own CA bundle in
-- charge [verified: SDK 35_url/_12-SetOption, ssl_cabundle is used "instead
-- of the system's"].
function http.options(overrides, tls)
	local opts = {
		fail_on_error = false,
		timeout = http.DEFAULT_TIMEOUT,
		connect_timeout = http.CONNECT_TIMEOUT,
	}
	for k, v in pairs(ssl_options()) do
		opts[k] = v
	end
	for k, v in pairs(tls or {}) do
		opts[k] = v
	end
	if opts.ssl_cabundle == false then
		opts.ssl_cabundle = nil
	end
	for k, v in pairs(overrides or {}) do
		opts[k] = v
	end
	return opts
end

-- curl's codes for a peer certificate that did not verify against the CA
-- bundle: 60 (CURLE_PEER_FAILED_VERIFICATION since curl 7.62, CURLE_SSL_CACERT
-- before it) and 51 (CURLE_PEER_FAILED_VERIFICATION before 7.62). Director
-- hands curl's code to OnDone as errCode: on OS 3.4.2 a public site refused
-- with the Signify bundle gave 60, an unreadable bundle path 77, a GET stuck
-- behind the stream 28 and an unresolvable spelling 6 [verified: hardware,
-- docs/design.md "Certificates" and "C4:url transfer scheduling"]. The SDK
-- itself promises only "a number with an error code" [verified: SDK
-- 35_url/_8-OnDone]. 51 is from curl's documentation and has not been seen on
-- a controller [assumed].
http.CERTIFICATE_ERRORS = { [51] = true, [60] = true }

-- True when `result` (an http.request result) is a transfer that failed
-- because the peer's certificate did not verify: no HTTP status, and curl's
-- code says so. Anything else is not: a timeout (28), a refused or
-- unreachable host (7), a name that does not resolve (6), a CA file that
-- cannot be read (77), a TLS handshake that failed some other way (35), a
-- transfer that never started (no code at all) [curl's codes: assumed from
-- curl's documentation where the list above does not say verified].
function http.certificate_failure(result)
	return type(result) == "table" and result.code == nil
		and http.CERTIFICATE_ERRORS[tonumber(result.err_code)] == true
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

-- A failed request's log line: a warning, or a debug line for a request
-- that is expected to fail (req.quiet).
local function failed(method, req, err)
	if req.quiet then
		log.debug("%s %s: %s", method, req.path, err)
	else
		log.warn("%s %s: %s", method, req.path, err)
	end
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
--   tls (optional ssl_* options on top of the bundle's, see http.options;
--   dev diagnostics and the TLS self-check only),
--   quiet (optional: a failure is logged at debug, not warn; for a request
--   expected to fail, the TLS self-check's).
-- `callback(result)` receives { ok, code, body, json, err, err_code }:
--   ok        true when the transfer completed and the status is 2xx
--   code      HTTP status, or nil when no response arrived
--   json      decoded body when it parsed, else nil
--   err       a human-readable reason when ok is false
--   err_code  the transfer's error code (curl's, see http.CERTIFICATE_ERRORS)
--             when it failed without a response; nil otherwise
-- Returns the C4LuaUrl transfer so callers can Cancel() it, or nil when the
-- transfer could not be started (the callback has then already been called).
function http.request(req, callback)
	local method = req.method or "GET"
	if not http.ca then
		failed(method, req, "no CA configuration")
		callback({ ok = false, err = "no CA configuration" })
		return nil
	end

	local url = http.url(req.ip, req.path)
	-- encodeArrays = true: Director's JsonEncode writes Lua arrays as objects
	-- by default; Hue bodies with arrays (e.g. children lists) need real ones.
	local data = req.body and C4:JsonEncode(req.body, false, true) or nil
	local headers = headers_for(req.key, data and { ["Content-Type"] = "application/json" } or nil)

	if log.enabled("debug") then
		log.debug("%s %s%s", method, url, data and (" " .. data) or "")
	end

	local transfer = C4:url()
		:SetOptions(http.options({ timeout = req.timeout }, req.tls))
		:OnDone(function(_, responses, err_code, err_msg)
			-- Guarded up to the callback: a raise here would leave the caller
			-- waiting for ever (a light's queue stays "in flight") [code
			-- analysis 2026-10-22, H2].
			local built, result = pcall(function()
				local result = {}
				local response = type(responses) == "table" and responses[#responses] or nil
				if err_code ~= 0 then
					result.ok = false
					result.err_code = err_code
					result.err = string.format("transfer failed (%s): %s", tostring(err_code), tostring(err_msg))
				elseif type(response) ~= "table" or type(response.code) ~= "number" then
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
				return result
			end)
			if not built then
				result = { ok = false, err = "done handler: " .. tostring(result) }
			end
			if not result.ok then
				failed(method, req, result.err)
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
			error("unsupported method " .. tostring(method))
		end
	end)
	if not started then
		failed(method, req, err)
		callback({ ok = false, err = err })
	end
	return started
end

-- A long-lived GET whose body is handed over chunk by chunk. `req` as for
-- http.request, plus headers (extra request headers).
-- `handlers`:
--   on_headers(code, headers)  once per response; return true to abort
--   on_chunk(data)             each body chunk
--   on_done(err_code, err_msg, code)  when the transfer ends for any reason;
--                              err_code -2 means it never started
-- Returns the transfer so the caller can Cancel() it, or nil when it could
-- not be started (on_done has then already been called).
function http.stream(req, handlers)
	if not http.ca then
		handlers.on_done(-2, "no CA configuration", nil)
		return nil
	end

	local url = http.url(req.ip, req.path)
	local headers = headers_for(req.key, req.headers)
	local last_code

	if log.enabled("debug") then
		log.debug("STREAM %s (timeout %s s)", url, tostring(req.timeout))
	end

	local transfer = C4:url()
		:SetOptions(http.options({ timeout = req.timeout }, req.tls))
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
