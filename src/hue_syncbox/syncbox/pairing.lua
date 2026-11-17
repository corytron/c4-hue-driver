-- Pairing with a Hue Sync Box, and Forget Pairing (#514,
-- docs/hdmi-sync-stage2-design.md §3.4 and §4; contracts C2, C3).
--
--   local p = pairing.new{ client, identity, store, timer, now, log, instance_name }
--   p:open(address, done)   identity, then the 2-minute button window
--   p:close()               the window closed (done{ ok = false, reason = "closed" })
--   p:is_open()             from open() until its done was called
--   p:remaining_s()         seconds left in the window (WINDOW_S while the
--                           identity check runs; 0 when closed)
--   p:forget(done)          Forget Pairing
--
-- The box (R1 §2.3): POST /api/v1/registrations {appName, instanceName},
-- without a token, answers 400 with code 16 ("Invalid State") until its
-- button is held for about 3 seconds, then {registrationId, accessToken}.
-- Home Assistant repeats the POST once a second until it succeeds [verified:
-- R1 §2.3], and so does the window here, one request at a time (the client's
-- queue). Starting that loop the moment a box is found "seems to get stuck"
-- (R1 §2.3), so the loop runs only on the owner's Pair Sync Box.
--
-- open(address, done): the identity check at `address` first (syncbox/
-- identity.lua): no expected id on a first pairing, the stored box id when
-- one is stored (re-pairing the same box; another one only after Forget
-- Pairing, as on the bridge, #236). Then the window: WINDOW_S seconds, a POST
-- every RETRY_MS while the box answers code 16. A POST that got no answer
-- (a timeout) is sent again while the window is open; another error answer
-- ends it, `refused`, its text kept. done is called once per open():
--   done{ ok = true, device, address, registration_id }
--   done{ ok = false, reason, text, device }
--     reason  timeout             the window ran out (text: the last
--                                 transfer error, if the box stopped answering)
--             closed              p:close(), p:forget() or another open()
--             refused             any other error answer, its text kept
--             identity:<reason>   the identity check's (identity.lua)
-- On success, in this order: store:save{ token, registration_id, box_id,
-- address }, client:set_address(address), client:set_token(token),
-- identity:adopt(address, device) (the trust for that box at that address).
-- The client's address and token stay as they were until then, so a failed
-- pairing at another address leaves the paired box as it was (Box Address is
-- the address in use, contracts C1.4).
--
-- The window rule (security review 2026-11-13, N-9, #490; R5 §2.5; the
-- bridge's bridge/pair_window.lua): a token that arrives after the window
-- closed (its timeout, p:close(), Forget Pairing, another open()), or for
-- another address than the one opened, is discarded: not stored, not handed
-- to the client, not logged. Neither is the registration answer, ever.
--
-- forget(done): any open window closes first (N-9). Then, while the client
-- holds the token and identity:ok() (the token goes only to the proven box),
-- DELETE /api/v1/registrations/<id> with the token [verified: R1 §2.3, only
-- that registration's own token may delete it]; then, whatever the answer,
-- store:clear() and client:set_token(nil). done{ ok = true, deleted_on_box,
-- status }: deleted_on_box is true when the box answered 2xx, or 404 or 401
-- (no such registration, or the token unknown: either way none of ours is
-- left there); false when the box did not answer, answered otherwise, or was
-- not asked (no token, not proven). The driver's Last Action then says the
-- registration stays on the box until removed in the Hue Sync app (§3.4).
--
-- Timers: deps.timer(ms, fn) → a handle with Cancel() (default C4:SetTimer),
-- deps.now() → ms (default C4:GetTime). The window's end and Forget's guard
-- re-read the clock when they fire, so a timer fired early (the fake
-- runtime's fire_timers) re-arms for the rest instead of ending anything.

local num = require("common.num")

local pairing = {}
pairing.__index = pairing

pairing.WINDOW_S = 120
pairing.RETRY_MS = 1000
pairing.APP_NAME = "c4-hue"
pairing.INSTANCE_MAX = 32             -- instanceName's limit (§3.4)
pairing.INSTANCE_DEFAULT = "Control4"
pairing.WAIT_CODE = 16                -- "Invalid State": the button is not held yet (R1 §2.3, §2.14)
pairing.FORGET_GUARD_MS = 20000       -- Forget ends by then whatever the box does
pairing.PATH = "/registrations"

local function noop() end

local function default_timer(ms, fn)
	return C4:SetTimer(ms, fn)
end

local function default_now()
	return C4:GetTime()
end

function pairing.new(deps)
	deps = deps or {}
	assert(type(deps.client) == "table", "pairing.new: client required")
	assert(type(deps.identity) == "table", "pairing.new: identity required")
	assert(type(deps.store) == "table", "pairing.new: store required")
	return setmetatable({
		client = deps.client,
		identity = deps.identity,
		store = deps.store,
		timer = deps.timer or default_timer,
		now = deps.now or default_now,
		log = deps.log or require("common.log"),
		instance_name = deps.instance_name,
		window = nil,
	}, pairing)
end

local function cancel(t)
	if t then
		pcall(function() t:Cancel() end)
	end
end

-- The registration's instanceName: the Control4 device's name, cut to
-- INSTANCE_MAX bytes (on a UTF-8 boundary) and without control characters.
function pairing:instance()
	local name
	if self.instance_name then
		local ok, value = pcall(self.instance_name)
		name = ok and value or nil
	end
	if type(name) ~= "string" then
		name = nil
	else
		name = self.client:peer_text(name, pairing.INSTANCE_MAX)
	end
	if not name or name:match("^%s*$") then
		return pairing.INSTANCE_DEFAULT
	end
	return name
end

-- A token the box issued that can travel as a header (client.lua's rule).
local function usable_token(t)
	return type(t) == "string" and #t >= 1 and #t <= 512 and not t:find("[^!-~]")
end

-- The registration id: a short decimal number; a whole number becomes its text.
local function registration_id(v)
	if type(v) == "number" and v >= 0 and v < 1e12 and v == math.floor(v) then
		v = string.format("%d", v)
	end
	if type(v) == "string" and #v >= 1 and #v <= 12 and not v:find("%D") then
		return v
	end
	return nil
end

-- The window ends: its timers go, and it is no longer this pairing's.
local function end_window(self, window)
	cancel(window.timer)
	cancel(window.retry)
	window.timer, window.retry = nil, nil
	if self.window == window then
		self.window = nil
	end
end

local function finish(self, window, outcome)
	if window.finished then
		return
	end
	window.finished = true
	end_window(self, window)
	window.done(outcome)
end

function pairing:is_open()
	return self.window ~= nil
end

function pairing:remaining_s()
	local window = self.window
	if not window then
		return 0
	end
	if not window.until_ms then
		return pairing.WINDOW_S
	end
	return math.max(0, math.ceil((window.until_ms - self.now()) / 1000))
end

function pairing:close()
	local window = self.window
	if window then
		finish(self, window, { ok = false, reason = "closed" })
	end
end

local attempt -- below

-- The next POST in RETRY_MS, or the end of the window.
local function again(self, window)
	if self:remaining_s() <= 0 then
		return finish(self, window, { ok = false, reason = "timeout", text = window.last_error })
	end
	window.retry = self.timer(pairing.RETRY_MS, function()
		window.retry = nil
		if self.window == window then
			attempt(self, window)
		end
	end)
end

-- The window's end, re-armed when it fires early (see the header).
local function arm_end(self, window)
	local left = (window.until_ms or 0) - self.now()
	window.timer = self.timer(math.max(1, left), function()
		window.timer = nil
		if self.window ~= window then
			return
		end
		if window.until_ms - self.now() > 0 then
			return arm_end(self, window)
		end
		finish(self, window, { ok = false, reason = "timeout", text = window.last_error })
	end)
end

-- The box issued a registration while `window` is open.
local function registered(self, window, sent_to, decoded)
	local token = type(decoded) == "table" and decoded.accessToken or nil
	local id = type(decoded) == "table" and registration_id(decoded.registrationId) or nil
	if not usable_token(token) or not id then
		-- Neither the answer nor any part of it is logged (R5 §2.5).
		return finish(self, window, { ok = false, reason = "refused",
			text = "the box answered without a usable registration" })
	end
	if sent_to ~= window.address then
		-- For another address than the one opened (N-9): dropped unstored.
		self.log.info("Sync box pairing: a registration for another address was dropped")
		return finish(self, window, { ok = false, reason = "closed" })
	end
	local device, address = window.device, window.address
	window.finished = true
	end_window(self, window)
	self.store:save({ token = token, registration_id = id, box_id = device.id, address = address })
	self.client:set_address(address)
	self.client:set_token(token)
	self.identity:adopt(address, device)
	self.log.info("Sync box: paired with %s (%s) at %s", tostring(device.id), tostring(device.model), address)
	window.done({ ok = true, device = device, address = address, registration_id = id })
end

attempt = function(self, window)
	local address = window.address
	self.client:post(pairing.PATH, { appName = pairing.APP_NAME, instanceName = self:instance() },
		function(ok, status, decoded, err)
			if self.window ~= window or window.finished then
				-- The window closed meanwhile (N-9): whatever came is
				-- dropped, a token unstored and unread.
				self.log.debug("Sync box pairing: an answer after the window closed was dropped")
				return
			end
			if ok then
				return registered(self, window, address, decoded)
			end
			if status and type(decoded) == "table" and num.int(decoded.code) == pairing.WAIT_CODE then
				window.last_error = nil
				return again(self, window)
			end
			if status then
				return finish(self, window, { ok = false, reason = "refused", text = err })
			end
			window.last_error = err
			again(self, window)
		end, { unkeyed = true, address = address, quiet = true })
end

function pairing:open(address, done)
	self:close() -- an earlier window ends first: its done reads "closed"
	local window = { address = address, done = done or noop }
	self.window = window
	local stored = self.store:load() or {}
	self.identity:check(address, stored.box_id, function(result)
		if self.window ~= window or window.finished then
			return -- closed while the identity was checked
		end
		if not result.ok then
			return finish(self, window, { ok = false, reason = "identity:" .. tostring(result.reason),
				text = result.detail, device = result.device })
		end
		window.device = result.device
		window.until_ms = self.now() + pairing.WINDOW_S * 1000
		arm_end(self, window)
		attempt(self, window)
	end)
end

function pairing:forget(done)
	done = done or noop
	self:close() -- a registration in flight is dropped unstored (N-9)
	local stored = self.store:load() or {}
	local id = registration_id(stored.registration_id)
	local finished, guard = false, nil
	local function complete(deleted, status)
		if finished then
			return
		end
		finished = true
		cancel(guard)
		self.store:clear()
		self.client:set_token(nil)
		done({ ok = true, deleted_on_box = deleted, status = status })
	end
	if not id or not self.client:has_token() or not self.identity:ok() then
		return complete(false, nil)
	end
	local deadline = self.now() + pairing.FORGET_GUARD_MS
	local function arm()
		guard = self.timer(math.max(1, deadline - self.now()), function()
			guard = nil
			if finished then
				return
			end
			if deadline - self.now() > 0 then
				return arm()
			end
			self.log.warn("Sync box: Forget Pairing: no answer from the box in %d s", pairing.FORGET_GUARD_MS / 1000)
			complete(false, nil)
		end)
	end
	arm()
	self.client:delete(pairing.PATH .. "/" .. id, function(_, status)
		local deleted = status ~= nil and ((status >= 200 and status < 300) or status == 404 or status == 401)
		complete(deleted, status)
	end)
end

return pairing
