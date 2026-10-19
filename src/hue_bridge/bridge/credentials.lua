-- Persistent storage of what pairing produced. The application key is stored
-- encrypted and never surfaced in a property.

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

function credentials.save(creds)
	C4:PersistSetValue(KEY_NAME, creds.key, true)
	C4:PersistSetValue(BRIDGE_ID_NAME, creds.bridge_id)
	C4:PersistSetValue(BRIDGE_IP_NAME, creds.ip)
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
	return creds.key ~= nil and creds.key ~= "" and creds.bridge_id ~= nil
end

return credentials
