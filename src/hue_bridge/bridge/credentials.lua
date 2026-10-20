-- Persistent storage of what pairing produced. The application key is stored
-- encrypted and never surfaced in a property.
--
-- PersistSetValue hands values to a database thread, so PersistGetValue may
-- not return a value written moments earlier (documented, and seen on OS
-- 3.4.2). Callers therefore keep the table that save() returns in memory and
-- only load() at startup.

local credentials = {}

local KEY_NAME = "hue_app_key"
local BRIDGE_ID_NAME = "hue_bridge_id"
local BRIDGE_IP_NAME = "hue_bridge_ip"

function credentials.load()
	return {
		key = C4:PersistGetValue(KEY_NAME, true),
		bridge_id = C4:PersistGetValue(BRIDGE_ID_NAME),
		ip = C4:PersistGetValue(BRIDGE_IP_NAME),
	}
end

-- Returns the same table so the caller can keep using it without a load().
function credentials.save(creds)
	C4:PersistSetValue(KEY_NAME, creds.key, true)
	C4:PersistSetValue(BRIDGE_ID_NAME, creds.bridge_id)
	C4:PersistSetValue(BRIDGE_IP_NAME, creds.ip)
	return creds
end

function credentials.save_ip(ip)
	C4:PersistSetValue(BRIDGE_IP_NAME, ip)
end

function credentials.clear()
	C4:PersistDeleteValue(KEY_NAME)
	C4:PersistDeleteValue(BRIDGE_ID_NAME)
	C4:PersistDeleteValue(BRIDGE_IP_NAME)
end

function credentials.paired(creds)
	return creds ~= nil and creds.key ~= nil and creds.key ~= "" and creds.bridge_id ~= nil
end

-- A log-safe description: presence and length of the key, never its value.
function credentials.summary(creds)
	if not creds then
		return "none"
	end
	local key = creds.key
	return string.format("key %s, bridge id %s, ip %s",
		(key and key ~= "") and ("present (" .. #tostring(key) .. " chars)") or "absent",
		tostring(creds.bridge_id or "absent"),
		tostring(creds.ip or "absent"))
end

return credentials
