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

-- A request path starts with "/". http.url puts it straight after the
-- address, so anything else moves the request to another host: "@..." makes
-- the address user info, ".example/..." or ":8443/..." extend it [security
-- review 2026-10-25, finding 10]. Release code always passes a literal
-- /clip/... or /api... path; http.request and http.stream refuse the rest as
-- an ordinary failure, http.url itself raises.
http.INVALID_PATH = "invalid request path"

local function valid_path(path)
	return type(path) == "string" and path:sub(1, 1) == "/"
end

function http.url(ip, path)
	if not valid_path(path) then
		error(http.INVALID_PATH, 2)
	end
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

local function json_decode(body)
	return C4:JsonDecode(body)
end

-- Decode a JSON body. Returns the value, or nil and an error string; never
-- raises. The SDK gives both a nil-and-message return and a raised error for
-- invalid JSON [verified: SDK 12_json/_3-JsonDecode], so the call runs under
-- pcall and a raise becomes the same nil-and-message answer [security review
-- 2026-10-25, finding 6]. OS 3.4.2 returns nil [assumed: a 403 HTML body is
-- read as HTTP 403, not as an error].
function http.decode(body)
	if body == nil or body == "" then
		return nil, "empty body"
	end
	local ok, value, err = pcall(json_decode, body)
	if not ok then
		return nil, "invalid JSON: " .. tostring(value)
	end
	if value == nil then
		return nil, "invalid JSON: " .. tostring(err)
	end
	return value
end

-- A failed request's log line: a warning, or a debug line for a request
-- that is expected to fail (req.quiet).
local function failed(method, req, err)
	if req.quiet then
		log.debug("%s %s: %s", method, tostring(req.path), err)
	else
		log.warn("%s %s: %s", method, tostring(req.path), err)
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
--   ip, path (starts with "/", see http.url), method ("GET"|"POST"|"PUT"|
--   "DELETE"), key (optional; a keyed request refuses redirects, see below),
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
-- A keyed request answered with a redirect gets { ok = false, code = <3xx>,
-- err = "redirect refused (HTTP <3xx>)" }.
-- Returns the C4LuaUrl transfer so callers can Cancel() it, or nil when the
-- transfer could not be started (the callback has then already been called).
function http.request(req, callback)
	local method = req.method or "GET"
	if not valid_path(req.path) then
		failed(method, req, http.INVALID_PATH)
		callback({ ok = false, err = http.INVALID_PATH })
		return nil
	end
	if not http.ca then
		failed(method, req, "no CA configuration")
		callback({ ok = false, err = "no CA configuration" })
		return nil
	end

	local url = http.url(req.ip, req.path)
	-- encodeArrays = true is passed, but Director's JsonEncode was seen to
	-- write Lua arrays as objects even so (docs/design.md, "C4:url
	-- transfer scheduling on OS 3.4.2"); no body the drivers send holds an array, so nothing depends on it.
	local data = req.body and C4:JsonEncode(req.body, false, true) or nil
	local headers = headers_for(req.key, data and { ["Content-Type"] = "application/json" } or nil)

	if log.enabled("debug") then
		log.debug("%s %s%s", method, url, data and (" " .. data) or "")
	end

	local transfer = C4:url()
		:SetOptions(http.options({ timeout = req.timeout }, req.tls))

	-- C4:url follows redirects by itself: OnHeaders runs once per response,
	-- "e.g. due to redirects" [verified: SDK 35_url/_9-OnHeaders], and no
	-- documented option turns that off [verified: SDK 35_url/_12-SetOption,
	-- 35_url/_13-SetOptions]. A keyed request must not go on to wherever a
	-- Location points: curl may send the hue-application-key header there
	-- too, over plain http even [assumed]. So it aborts on a 3xx (a true
	-- returned from OnHeaders aborts the transfer, same page) and reports the
	-- refusal whatever OnDone then says [security review 2026-10-25, finding
	-- 7]. Unkeyed requests (identity check, TLS self-check, pairing) follow
	-- redirects as before. OnHeaders alone leaves the body aggregated for
	-- OnDone: only an OnBodyChunk callback stops that [verified: SDK
	-- 35_url/_7-OnBodyChunk; assumed on hardware, where only the stream has
	-- used OnHeaders so far].
	local refused -- the 3xx this keyed request refused
	if req.key then
		transfer:OnHeaders(function(_, response)
			local code = type(response) == "table" and tonumber(response.code) or nil
			if code and code >= 300 and code <= 399 then
				refused = code
				return true
			end
			return false
		end)
	end

	transfer:OnDone(function(_, responses, err_code, err_msg)
		-- Guarded up to the callback: a raise here would leave the caller
		-- waiting for ever (a light's queue stays "in flight") [code
		-- analysis 2026-10-22, H2].
		local built, result = pcall(function()
			if refused then
				return { ok = false, code = refused, err = string.format("redirect refused (HTTP %d)", refused) }
			end
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
-- http.request, plus headers (extra request headers). A redirect reaches
-- on_headers like any other response (OnHeaders runs once per response,
-- SDK 35_url/_9-OnHeaders); the event stream aborts on every code but 200,
-- so it never follows one.
-- `handlers`:
--   on_headers(code, headers)  once per response; return true to abort
--   on_chunk(data)             each body chunk
--   on_done(err_code, err_msg, code)  when the transfer ends for any reason;
--                              err_code -2 means it never started
-- Returns the transfer so the caller can Cancel() it, or nil when it could
-- not be started (on_done has then already been called).
function http.stream(req, handlers)
	if not valid_path(req.path) then
		log.warn("STREAM %s: %s", tostring(req.path), http.INVALID_PATH)
		handlers.on_done(-2, http.INVALID_PATH, nil)
		return nil
	end
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
