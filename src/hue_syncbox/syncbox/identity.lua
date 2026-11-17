-- The Hue Sync Box's identity, proven before its token goes anywhere (#514,
-- docs/hdmi-sync-stage2-design.md §3.3; contracts C3; R5 §2.2, §2.3, §3.4):
-- the TLS self-check at the address, then the unkeyed GET /api/v1/device,
-- whose uniqueId is the box id. The bridge's rule (bridge/identity.lua,
-- docs/design.md "TLS self-check in release builds"), for the box.
--
--   local i = identity.new{ client, tlscheck, log }
--   i:check(address, expected_id, cb)   cb(result) once
--   i:ok()        true only after a passing check at the client's current
--                 address, for its current token
--   i:reset()     an address change: the trust, the TLS answers and the
--                 checks in flight are forgotten
--   i:recheck(cb) the check again at the client's address, expecting the id
--                 trusted there (or last expected): a 401 (N-6) or an outage
--   i:adopt(address, device)
--                 pairing's success (syncbox/pairing.lua): the client now
--                 uses `address` and the token that box just issued; the
--                 trust is given only when a check at `address` passed with
--                 that id in this generation
--   i:trusted_id()  the id trusted at the client's address, or nil
--
-- result = { ok, reason, device, detail }:
--   reason     ok             the box answered over the pinned chain, with
--                              the expected id when one was given
--              unknown_model  the same, but its deviceType is none this
--                              driver knows: allowed with a warning, ok true
--              not_pinned     the controller accepted the box with the decoy
--                              bundle (common/tlscheck.lua): nothing keyed
--              inconclusive   the TLS check failed some other way on a
--                              Director version that never answered pinned
--              unreachable    no answer at the address
--              not_a_box      an answer, but not a box's: a certificate that
--                              does not chain to root-hsb, an HTTP error, or
--                              no 12-digit uniqueId
--              wrong_box      a box, but another id than expected_id
--              camera         a Hue camera (HSC001, O2): not supported
--   device     { id, name, model, firmware, api_level, device_type } when
--              the box answered with an id (wrong_box and camera too, for
--              Status; rows are written only when ok, N-4): id upper-case;
--              model HSB1, HSB2, HSB3, HSC001 or "unknown"; device_type the
--              raw deviceType, cut
--   detail     a short text for Status and the log (never the token)
--
-- The order (§3.3): the TLS self-check first, then GET /device. On
-- not_pinned nothing more is sent. On inconclusive, GET /device still runs
-- (unkeyed: nothing secret goes), so an address with nothing on it reads
-- unreachable and another device reads as what it is; a passing answer is
-- then inconclusive, unless this Director version answered pinned before
-- (tlscheck.pinned_before(): pinning is a property of the OS, the bridge's
-- rule). A pinned answer is remembered per address and its Director version
-- stored (tlscheck.remember_pinned()); not_pinned sticks to every address
-- until reset(), as on the bridge (security review 2026-10-25, finding 2).
--
-- The trust (client:set_trusted) changes only for a check at the client's
-- current address, and only in the generation it started in:
--   - a pass with an expected id grants it (the id matched);
--   - a pass without one grants it only while the client holds no token
--     (pairing a first box: nothing to give away; a token set afterwards
--     drops it again, syncbox/client.lua), else it never grants;
--   - a failure with an expected id, or while no token is held, withdraws
--     it; without an expected id while a token is held (a discovery check,
--     say) only another id proven at the address withdraws it.
-- So a discovery candidate at another address never moves the trust.
--
-- The check does not retry: the driver decides when to ask again (at
-- start, at an address change, after an outage, R5 §3.4).
--
-- The id is the certificate's common name too, but no DriverWorks API
-- compares a certificate's name with an expected id (R5 §2.2), so it is
-- compared here, from the answer that came over the pinned chain. Residual
-- risk, as on the bridge (#491; R5 §3.4): a host holding a root-hsb leaf
-- and its key could answer with the paired id.

local num = require("common.num")

local identity = {}
identity.__index = identity

identity.PATH = "/device"                 -- after /api/v1 (client.lua)
identity.TLS_PATH = "/api/v1/device"      -- the decoy request's, unkeyed
identity.DECOY_CA = "certs/decoy.pem"
identity.TLS_TIMEOUT = 6
identity.STORE_NAME = "tls_pinned_on"     -- the box device's own storage (R5 §2.3)
identity.MODELS = { HSB1 = true, HSB2 = true, HSB3 = true }
identity.CAMERA = "HSC001"
identity.MAX_ADDRESSES = 16               -- remembered TLS answers and passes per generation

-- A box id: 12 hexadecimal digits, upper-case (R5 §3.2); else nil.
function identity.normalise_id(v)
	if type(v) == "string" and #v == 12 and not v:find("%X") then
		return v:upper()
	end
	return nil
end

-- The box's TLS self-check (common/tlscheck.lua) through `c`'s queue, so the
-- decoy request is one of the box's one-at-a-time requests.
function identity.tlscheck_for(c, log)
	return require("common.tlscheck").new({
		https = c:tls_transport(),
		decoy_ca = identity.DECOY_CA,
		path = identity.TLS_PATH,
		timeout = identity.TLS_TIMEOUT,
		store_name = identity.STORE_NAME,
		label = "Sync box TLS check",
		log = log,
	})
end

function identity.new(deps)
	deps = deps or {}
	assert(type(deps.client) == "table", "identity.new: client required")
	local log = deps.log or require("common.log")
	return setmetatable({
		client = deps.client,
		tlscheck = deps.tlscheck or identity.tlscheck_for(deps.client, deps.log),
		log = log,
		gen = 1,
		trusted = nil,       -- { address, id }: the client's trust, as this module granted it
		last_expected = nil, -- the id the last check at the client's address expected
		passed = {},         -- address -> id, every pass of this generation
		pinned = {},         -- address -> true: the TLS check answered pinned there
		not_pinned = nil,    -- the detail of a not_pinned answer in this generation
	}, identity)
end

local function count(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

-- Remember `value` under `address` in `t`, at most MAX_ADDRESSES entries.
local function remember(t, address, value)
	if t[address] == nil and count(t) >= identity.MAX_ADDRESSES then
		for k in pairs(t) do
			t[k] = nil
		end
	end
	t[address] = value
end

function identity:trusted_id()
	local t = self.trusted
	if t and t.address == self.client:get_address() and self.client:is_trusted() then
		return t.id
	end
	return nil
end

function identity:ok()
	return self:trusted_id() ~= nil
end

local function grant(self, address, id)
	self.trusted = { address = address, id = id }
	self.client:set_trusted(true)
end

local function withdraw(self)
	self.trusted = nil
	self.client:set_trusted(false)
end

function identity:reset()
	self.gen = self.gen + 1
	self.trusted = nil
	self.passed = {}
	self.pinned = {}
	self.not_pinned = nil
	self.client:set_trusted(false)
end

-- The trust after a check (see the header).
local function apply(self, address, expected, result)
	if address ~= self.client:get_address() then
		return
	end
	local has_token = self.client:has_token()
	local id = result.device and result.device.id or nil
	if result.ok then
		if expected or not has_token then
			return grant(self, address, id)
		end
		if self.trusted and self.trusted.id ~= id then
			return withdraw(self)
		end
		return
	end
	if expected or not has_token then
		return withdraw(self)
	end
	if id and self.trusted and self.trusted.id ~= id then
		return withdraw(self)
	end
end

-- The device from GET /device's answer (R1 §2.5): every value checked,
-- every text cut (R5 §3.2).
local function device_of(self, body)
	local id = identity.normalise_id(body.uniqueId)
	if not id then
		return nil
	end
	local c = self.client
	local raw = type(body.deviceType) == "string" and body.deviceType or nil
	local model = "unknown"
	if raw and (identity.MODELS[raw] or raw == identity.CAMERA) then
		model = raw
	end
	local firmware = body.firmwareVersion
	return {
		id = id,
		name = type(body.name) == "string" and c:peer_text(body.name) or nil,
		model = model,
		firmware = (type(firmware) == "string" or type(firmware) == "number") and c:peer_text(firmware, 32) or nil,
		api_level = num.int(body.apiLevel, 0, 1000),
		device_type = raw and c:peer_text(raw, 32) or nil,
	}
end

-- The result from GET /device's answer.
local function classify(self, expected, ok, status, decoded, err, err_code)
	local c = self.client
	if status == nil then
		if c:certificate_failure(err_code) then
			return { ok = false, reason = "not_a_box",
				detail = "its certificate does not chain to the Hue sync box root" }
		end
		return { ok = false, reason = "unreachable", detail = c:peer_text(err or "no answer", 128) }
	end
	if not ok or type(decoded) ~= "table" then
		return { ok = false, reason = "not_a_box", detail = c:peer_text(err or "not a sync box's answer", 128) }
	end
	local device = device_of(self, decoded)
	if not device then
		return { ok = false, reason = "not_a_box", detail = "no box id in the answer" }
	end
	if expected and device.id ~= expected then
		return { ok = false, reason = "wrong_box", device = device,
			detail = string.format("reports ID %s, expected %s", device.id, expected) }
	end
	if device.model == identity.CAMERA then
		return { ok = false, reason = "camera", device = device, detail = "a Hue camera (HSC001), not a sync box" }
	end
	if device.model == "unknown" then
		return { ok = true, reason = "unknown_model", device = device,
			detail = "model " .. tostring(device.device_type or "not reported") .. " is not one this driver knows" }
	end
	return { ok = true, reason = "ok", device = device }
end

-- The TLS self-check at `address`, or what this generation knows of it.
-- done(verdict, detail).
local function tls(self, gen, address, done)
	if self.not_pinned then
		return done("not_pinned", self.not_pinned)
	end
	if self.pinned[address] then
		return done("pinned", "pinned before at this address")
	end
	self.tlscheck.run(address, function(verdict, detail)
		detail = self.client:peer_text(detail or verdict, 128)
		if verdict == "pinned" then
			self.tlscheck.remember_pinned()
			if gen == self.gen then
				remember(self.pinned, address, true)
			end
		elseif verdict == "not_pinned" and gen == self.gen then
			self.not_pinned = detail
		end
		done(verdict, detail)
	end)
end

-- One log line for a check at the client's address (warn) or elsewhere
-- (debug: discovery's candidates).
local function report(self, address, result)
	local here = address == self.client:get_address()
	local level = (result.reason == "ok" or not here) and "debug" or "warn"
	if result.reason == "unknown_model" and here then
		level = "warn"
	end
	self.log[level]("Sync box: identity at %s: %s%s", tostring(address), result.reason,
		result.detail and (" (" .. result.detail .. ")") or "")
end

function identity:check(address, expected_id, cb)
	cb = cb or function() end
	local gen = self.gen
	local expected = nil
	if expected_id ~= nil and expected_id ~= "" then
		-- An id no box can report when the stored one is not an id at all.
		expected = identity.normalise_id(expected_id) or "(invalid)"
	end
	if address == self.client:get_address() then
		self.last_expected = expected or self.last_expected
	end
	local function finish(result)
		if gen == self.gen then
			if result.ok then
				remember(self.passed, address, result.device.id)
			end
			apply(self, address, expected, result)
		end
		report(self, address, result)
		cb(result)
	end
	if type(address) ~= "string" or address == "" then
		return finish({ ok = false, reason = "unreachable", detail = "no address" })
	end
	tls(self, gen, address, function(verdict, detail)
		if verdict == "not_pinned" then
			return finish({ ok = false, reason = "not_pinned",
				detail = "the controller accepted the box with the decoy bundle (" .. tostring(detail) .. ")" })
		end
		local doubtful = verdict == "inconclusive" and not self.tlscheck.pinned_before()
		if verdict == "inconclusive" and not doubtful then
			self.log.warn("Sync box: TLS check inconclusive (%s); this Director version answered pinned before, so it "
				.. "passes", tostring(detail))
		end
		self.client:get(identity.PATH, function(ok, status, decoded, err, err_code)
			local result = classify(self, expected, ok, status, decoded, err, err_code)
			if doubtful and result.ok then
				result = { ok = false, reason = "inconclusive", device = result.device,
					detail = "TLS check inconclusive: " .. tostring(detail) }
			end
			finish(result)
		end, { unkeyed = true, address = address, quiet = true })
	end)
end

function identity:recheck(cb)
	local address = self.client:get_address()
	local expected = self:trusted_id() or (self.trusted and self.trusted.id) or self.last_expected
	return self:check(address, expected, cb)
end

function identity:adopt(address, device)
	local id = device and identity.normalise_id(device.id)
	if not id or address ~= self.client:get_address() or self.passed[address] ~= id then
		return false
	end
	grant(self, address, id)
	return true
end

return identity
