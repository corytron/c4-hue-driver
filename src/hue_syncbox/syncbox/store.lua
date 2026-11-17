-- What pairing with a Hue Sync Box produced, in the device's persistent
-- storage (#514, docs/hdmi-sync-stage2-design.md §3.2): the token, the
-- registration id, the box id and its address.
--
--   local s = store.new{ persist_get, persist_set, persist_delete, log }
--   s:load()    → { token, registration_id, box_id, address } (any nil)
--   s:save(t)   the fields `t` holds (the others stay); true, or false and
--               the name of the field refused (nothing is written then)
--   s:clear()   all four gone (Forget Pairing)
--   s:paired()  a token and a box id are held
--   s:summary() a log-safe line: whether a token is held, never its value
--
-- The driver passes C4:PersistGetValue, C4:PersistSetValue and
-- C4:PersistDeleteValue behind functions (name[, value][, encrypted]); left
-- out, those are used. The token is stored with the encrypted flag
-- (PersistSetValue(name, value, true)) [verified: SDK
-- 26.5_persistence/_4-PersistSetValue; R5 §2.5; the bridge's
-- bridge/credentials.lua], and read back with it; the registration id, the
-- box id and the address are no secrets and are stored plain (R5 §2.5).
--
-- PersistSetValue hands the value to a database thread, so PersistGetValue
-- may not return a value written moments earlier [verified: the same SDK
-- page's usage note; docs/design.md "Storage"]. So the store keeps what it
-- loaded and saved in memory, and reads the storage only at the first load
-- of a run; clear() leaves it empty in memory too.
--
-- Every value is checked on its way in and out (R5 §3.2): the token 1 to
-- 512 printable characters without a space, the registration id a short
-- decimal number, the box id 12 hexadecimal digits (kept upper-case), the
-- address a host name or IPv4 address with an optional port. A stored value
-- that fails its check loads as nil. The token never reaches a log line.

local store = {}
store.__index = store

store.FIELDS = { "token", "registration_id", "box_id", "address" }
store.NAMES = {
	token = "syncbox_token",
	registration_id = "syncbox_registration_id",
	box_id = "syncbox_box_id",
	address = "syncbox_address",
}
store.TOKEN_MAX = 512

local check = {}

function check.token(v)
	if type(v) == "string" and #v >= 1 and #v <= store.TOKEN_MAX and not v:find("[^!-~]") then
		return v
	end
	return nil
end

-- A short decimal id; a whole number the JSON decoder gave becomes its text.
function check.registration_id(v)
	if type(v) == "number" and v >= 0 and v < 1e12 and v == math.floor(v) then
		v = string.format("%d", v)
	end
	if type(v) == "string" and #v >= 1 and #v <= 12 and not v:find("%D") then
		return v
	end
	return nil
end

function check.box_id(v)
	if type(v) == "string" and #v == 12 and not v:find("%X") then
		return v:upper()
	end
	return nil
end

function check.address(v)
	if type(v) ~= "string" or #v < 1 or #v > 253 then
		return nil
	end
	if v:match("^[%w%.%-]+$") or v:match("^[%w%.%-]+:%d+$") then
		return v
	end
	return nil
end

-- The checks, for the modules that take these values from elsewhere.
store.check = check

function store.new(deps)
	deps = deps or {}
	return setmetatable({
		get = deps.persist_get or function(name, encrypted)
			return C4:PersistGetValue(name, encrypted)
		end,
		set = deps.persist_set or function(name, value, encrypted)
			return C4:PersistSetValue(name, value, encrypted)
		end,
		delete = deps.persist_delete or function(name)
			return C4:PersistDeleteValue(name)
		end,
		log = deps.log or require("common.log"),
		memory = nil,
	}, store)
end

local function copy(t)
	local out = {}
	for _, field in ipairs(store.FIELDS) do
		out[field] = t[field]
	end
	return out
end

-- The values in memory, read from the storage the first time.
local function memory(self)
	if self.memory then
		return self.memory
	end
	local m = {}
	for _, field in ipairs(store.FIELDS) do
		local encrypted = field == "token"
		local ok, value = pcall(self.get, store.NAMES[field], encrypted or nil)
		if not ok then
			self.log.warn("Sync box: could not read the stored %s", field)
		elseif value ~= nil and value ~= "" then
			m[field] = check[field](value)
			if m[field] == nil then
				self.log.warn("Sync box: the stored %s is not usable; it is ignored", field)
			end
		end
	end
	self.memory = m
	return m
end

function store:load()
	return copy(memory(self))
end

function store:save(t)
	if type(t) ~= "table" then
		return false, "record"
	end
	local values = {}
	for _, field in ipairs(store.FIELDS) do
		if t[field] ~= nil then
			values[field] = check[field](t[field])
			if values[field] == nil then
				self.log.warn("Sync box: not stored: the %s is not usable", field)
				return false, field
			end
		end
	end
	local m = memory(self)
	for _, field in ipairs(store.FIELDS) do
		local value = values[field]
		if value ~= nil then
			m[field] = value
			local encrypted = field == "token"
			local ok = pcall(self.set, store.NAMES[field], value, encrypted or nil)
			if not ok then
				self.log.warn("Sync box: could not store the %s; it is kept for this run", field) -- never the value
			end
		end
	end
	return true
end

function store:clear()
	for _, field in ipairs(store.FIELDS) do
		local ok = pcall(self.delete, store.NAMES[field])
		if not ok then
			self.log.warn("Sync box: could not delete the stored %s", field)
		end
	end
	self.memory = {}
end

function store:paired()
	local m = memory(self)
	return m.token ~= nil and m.box_id ~= nil
end

function store:summary()
	local m = memory(self)
	return string.format("token %s, registration %s, box id %s, address %s", m.token and "present" or "absent",
		tostring(m.registration_id or "absent"), tostring(m.box_id or "absent"), tostring(m.address or "absent"))
end

return store
