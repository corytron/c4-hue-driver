-- Link-button pairing with a Hue bridge.
--
-- 1. GET /api/0/config (unauthenticated) to learn the bridge ID and model.
--    This also proves the TLS chain verifies before any secret is sent.
-- 2. POST /api {"devicetype": ..., "generateclientkey": true}. Until the
--    link button has been pressed the bridge answers with error type 101.
-- 3. Store the key, bridge ID and IP.
--
-- The POST goes to the v1-era /api endpoint because key creation is the one
-- operation CLIP v2 does not offer. Verified against a Bridge Pro (BSB003)
-- on OS 3.4.2: the devicetype body below yields a key. [assumed: error type
-- 101 for "link button not pressed" is from memory of the Hue docs]

local log = require("common.log")
local http = require("bridge.http")
local config = require("bridge.config")
local credentials = require("bridge.credentials")

local pairing = {}

pairing.DEVICE_TYPE = "control4#hue_bridge"
pairing.LINK_BUTTON_ERROR = 101

-- Read the bridge's public config. callback(info|nil, err).
-- info = { bridge_id (lower-case), model, sw_version, name }
function pairing.probe(ip, callback)
	return http.request({ ip = ip, path = "/api/0/config" }, function(r)
		if not r.ok then
			return callback(nil, r.err)
		end
		local cfg = r.json or {}
		local id = config.normalise_bridge_id(cfg.bridgeid)
		if not id then
			return callback(nil, "no bridge ID in config response")
		end
		callback({
			bridge_id = id,
			model = cfg.modelid,
			sw_version = cfg.swversion,
			name = cfg.name,
		})
	end)
end

-- Interpret the array the /api endpoint returns. Returns one of:
--   "ok", key          on success
--   "link_button"      when the button hasn't been pressed
--   "error", message   otherwise
function pairing.parse_response(json)
	if type(json) ~= "table" then
		return "error", "unexpected response"
	end
	local first = json[1]
	if type(first) ~= "table" then
		return "error", "empty response"
	end
	if first.success and first.success.username then
		return "ok", first.success.username
	end
	local err = first.error
	if type(err) == "table" then
		if err.type == pairing.LINK_BUTTON_ERROR then
			return "link_button"
		end
		return "error", string.format("bridge error %s: %s", tostring(err.type), tostring(err.description))
	end
	return "error", "unexpected response"
end

-- Run the whole flow. `handlers`:
--   on_probed(info)        bridge answered the config request
--   on_link_button(info)   press the button and try again
--   on_paired(creds)       key stored; creds = { key, bridge_id, ip, model }
--   on_error(message)
function pairing.pair(ip, handlers)
	pairing.probe(ip, function(info, err)
		if not info then
			log.warn("pairing: config probe failed: %s", err)
			return handlers.on_error("Bridge not reachable: " .. err)
		end
		if handlers.on_probed then
			handlers.on_probed(info)
		end
		http.request({
			ip = ip,
			path = "/api",
			method = "POST",
			body = { devicetype = pairing.DEVICE_TYPE, generateclientkey = true },
		}, function(r)
			if not r.ok and not r.json then
				return handlers.on_error("Pairing request failed: " .. tostring(r.err))
			end
			local status, value = pairing.parse_response(r.json)
			if status == "link_button" then
				return handlers.on_link_button(info)
			elseif status ~= "ok" then
				return handlers.on_error(value)
			end
			local creds = { key = value, bridge_id = info.bridge_id, ip = ip, model = info.model }
			credentials.save(creds)
			log.info("paired with bridge %s (%s)", info.bridge_id, tostring(info.model))
			handlers.on_paired(creds)
		end)
	end)
end

return pairing
