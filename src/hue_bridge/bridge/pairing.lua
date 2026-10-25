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
-- on OS 3.4.2: a devicetype body of this shape yields a key (it was
-- "control4#hue_bridge" then; the Hue format is "application#device", both
-- parts short, no spaces, and the name below says whose driver this is
-- rather than reading as Control4's own app, docs/licensing-research.md §2;
-- a key already issued keeps the name it was created with [assumed]).
-- [assumed: error type 101 for "link button not pressed" is from memory of
-- the Hue docs]

local log = require("common.log")
local http = require("bridge.http")
local config = require("bridge.config")
local credentials = require("bridge.credentials")

local pairing = {}

pairing.DEVICE_TYPE = "c4-hue-driver#bridge"
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
			api_version = cfg.apiversion,
			name = cfg.name,
		})
	end)
end

-- The key the bridge issued, if it is one: a non-empty string that can travel
-- as a header value (no white space, no control characters). Anything else
-- would be stored and then sent with every request [code analysis
-- 2026-10-22, L6]. Hue keys are letters, digits and hyphens [assumed], so
-- the rule refuses no real one.
local function usable_key(value)
	return type(value) == "string" and value ~= "" and not value:find("[%s%c]")
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
	local success = first.success
	if success ~= nil then
		if type(success) == "table" and usable_key(success.username) then
			return "ok", success.username
		end
		return "error", "the bridge answered without a usable application key"
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

-- Why a probed bridge cannot be paired, or nil when it can.
function pairing.refusal(ip, info)
	local model = tostring(info.model or "")
	if not config.model_supported(model) then
		if model == "BSB001" then
			return "This is a Hue Bridge v1, round (BSB001): it has no CLIP v2 API; this driver needs a Hue Bridge v2 "
				.. "(square) or a Hue Bridge Pro"
		end
		return string.format("The device at %s is not a Hue bridge (model %s)", ip, model ~= "" and model or "unknown")
	end
	if config.firmware_check(info.sw_version) == "old" then
		return string.format("Bridge firmware %s is older than %d, the first with the CLIP v2 API; update the bridge "
			.. "in the Hue app, then pair again", tostring(info.sw_version), config.MIN_FIRMWARE)
	end
	return nil
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
			return handlers.on_error(string.format("No Hue bridge answered at %s: %s", ip, tostring(err)))
		end
		if handlers.on_probed then
			handlers.on_probed(info)
		end
		-- The generation and the firmware, before any key is asked for
		-- (docs/bridge-compat-design.md Decision 2).
		local refusal = pairing.refusal(ip, info)
		if refusal then
			log.warn("pairing refused: %s", refusal)
			return handlers.on_error(refusal)
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
