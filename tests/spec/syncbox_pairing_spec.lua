-- #514, stage 2 §3.4 and §4 (docs/hdmi-sync-stage2-design.md):
-- syncbox/pairing.lua, pairing with a Hue Sync Box (the identity check, the
-- 2-minute window, one POST /registrations a second, the N-9 window rule)
-- and Forget Pairing. Runs on the real client, identity and store over the
-- fake runtime. Placeholders only: box 10.0.2.150 and 198.51.100.150, id
-- 0A1B2C3D4E5F, token TEST-TOKEN-NOT-REAL.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BOX = "10.0.2.150"
local OTHER = "198.51.100.150"
local ID = "0A1B2C3D4E5F"
local OTHER_ID = "0A1B2C3D4E60"
local TOKEN = "TEST-TOKEN-NOT-REAL"

describe("syncbox/pairing.lua (#514 stage 2)", function()
	local client, identity, store, pairing, c4, c, i, s, p, lines, results, name

	local function device_body(over)
		local d = { name = "Living Room TV", deviceType = "HSB2", uniqueId = ID, apiLevel = 14,
			firmwareVersion = "2.4.1" }
		for k, v in pairs(over or {}) do d[k] = v end
		return c4:JsonEncode(d)
	end

	local function registration_body(token, id)
		return c4:JsonEncode({ registrationId = id or "7", accessToken = token or TOKEN })
	end

	local function done(outcome)
		results[#results + 1] = outcome
	end

	-- Answer the identity check's GET /device (the decoy request has failed
	-- at once in the fake: pinned).
	local function answer_identity(body)
		local t = c4.last_transfer()
		assert.truthy(t.url:find("/api/v1/device$"), "the identity check's GET /device")
		t:respond(200, body or device_body())
	end

	-- The POST /registrations in flight.
	local function registration_request()
		local t = c4.last_transfer()
		assert.equal("POST", t.method)
		assert.truthy(t.url:find("/api/v1/registrations$"))
		assert.is_nil(t.headers.Authorization)
		return t
	end

	local function posts()
		local n = 0
		for _, t in ipairs(c4.transfers) do
			if t.method == "POST" then n = n + 1 end
		end
		return n
	end

	local function waiting(t)
		t:respond(400, '{"code":16,"message":"Invalid State"}')
	end

	-- Open at `address` and get through the identity check to the first POST.
	local function open_window(address)
		p:open(address or BOX, done)
		answer_identity()
		return registration_request()
	end

	-- A whole first pairing at BOX.
	local function pair()
		local t = open_window()
		t:respond(200, registration_body())
		assert.is_true(results[#results].ok)
	end

	before_each(function()
		lines, results = {}, {}
		name = "Bedroom Sync Box"
		log.set_debug(true)
		log.sink = function(line) lines[#lines + 1] = line end
		c4 = fake.install_c4()
		for _, m in ipairs({ "common.https", "common.tlscheck", "syncbox.client", "syncbox.identity", "syncbox.store",
			"syncbox.pairing" }) do
			package.loaded[m] = nil
		end
		client = require("syncbox.client")
		identity = require("syncbox.identity")
		store = require("syncbox.store")
		pairing = require("syncbox.pairing")
		c = client.new()
		i = identity.new({ client = c })
		s = store.new()
		p = pairing.new({ client = c, identity = i, store = s, instance_name = function() return name end })
	end)

	after_each(function()
		for _, line in ipairs(lines) do
			assert.is_nil(line:find(TOKEN, 1, true), "a log line holds the token: " .. line)
		end
		log.set_debug(false)
		log.sink = print
	end)

	describe("open", function()
		it("checks the identity first, without an expected id on a first pairing", function()
			p:open(BOX, done)
			assert.is_true(p:is_open())
			assert.equal(120, p:remaining_s())
			assert.equal(1, #c4.decoy_transfers)
			assert.equal(0, posts())
			answer_identity()
			local t = registration_request()
			assert.equal("https://10.0.2.150/api/v1/registrations", t.url)
			assert.same({ appName = "c4-hue", instanceName = "Bedroom Sync Box" }, c4:JsonDecode(t.data))
		end)

		it("waits for the button with one POST a second while the box answers code 16", function()
			local t = open_window()
			c4.advance(5000)
			assert.equal(1, posts(), "never two at once: the first is still in flight")
			waiting(t)
			assert.equal(1, posts())
			c4.advance(999)
			assert.equal(1, posts())
			c4.advance(1)
			assert.equal(2, posts())
			waiting(registration_request())
			c4.advance(1000)
			assert.equal(3, posts())
			assert.equal(0, #results)
			assert.equal(113, p:remaining_s()) -- 7 s gone
		end)

		it("pairs when the button was held: stores, sets the client and trusts the box", function()
			local t = open_window()
			waiting(t)
			c4.advance(1000)
			registration_request():respond(200, registration_body())
			assert.equal(1, #results)
			local r = results[1]
			assert.is_true(r.ok)
			assert.equal(ID, r.device.id)
			assert.equal("HSB2", r.device.model)
			assert.equal(BOX, r.address)
			assert.equal("7", r.registration_id)
			assert.is_nil(r.token, "the token is not handed out")
			assert.is_false(p:is_open())
			assert.equal(0, p:remaining_s())
			assert.same({ token = TOKEN, registration_id = "7", box_id = ID, address = BOX }, s:load())
			local encrypted
			for _, args in ipairs(c4.calls_to("PersistSetValue")) do
				if args[1] == "syncbox_token" then encrypted = args[3] end
			end
			assert.is_true(encrypted)
			assert.equal(BOX, c:get_address())
			assert.is_true(c:has_token())
			assert.is_true(i:ok())
			c:get("", function() end)
			assert.equal("Bearer " .. TOKEN, c4.last_transfer().headers.Authorization)
			c4.advance(200000)
			assert.equal(1, #results)
		end)

		it("pairs when the client already used the address", function()
			c:set_address(BOX)
			pair()
			assert.is_true(i:ok())
			assert.equal(ID, i:trusted_id())
		end)

		it("ends the window after 2 minutes", function()
			local t = open_window()
			waiting(t)
			for _ = 1, 200 do
				if #results > 0 then break end
				c4.advance(1000)
				local last = c4.last_transfer()
				if last.method == "POST" and not last.answered then
					last.answered = true
					waiting(last)
				end
			end
			assert.equal(1, #results)
			assert.same({ ok = false, reason = "timeout" }, results[1])
			assert.is_false(p:is_open())
			local n = posts()
			c4.advance(10000)
			assert.equal(n, posts(), "no POST after the window")
		end)

		it("is not ended by a timer fired early", function()
			open_window()
			c4.fire_timers()
			assert.is_true(p:is_open())
			assert.equal(0, #results)
		end)

		it("keeps asking when the box does not answer, and says so at the end", function()
			local t = open_window()
			t:done(28, "Timeout was reached")
			c4.advance(1000)
			assert.equal(2, posts())
			c4.advance(125000)
			assert.equal("timeout", results[1].reason)
			assert.truthy(tostring(results[1].text):find("Timeout", 1, true))
		end)

		it("ends refused on any other error answer, its text kept", function()
			open_window():respond(400, '{"code":15,"message":"Invalid Value"}')
			assert.equal(1, #results)
			assert.is_false(results[1].ok)
			assert.equal("refused", results[1].reason)
			assert.equal("HTTP 400, box error 15: Invalid Value", results[1].text)
			assert.same({}, s:load())
			c4.advance(5000)
			assert.equal(1, posts())
		end)

		it("refuses an answer without a usable token or id, and stores and logs none of it", function()
			for _, body in ipairs({
				registration_body("TEST TOKEN NOT REAL"),
				registration_body(TOKEN, "seven"),
				c4:JsonEncode({ registrationId = "7" }),
				"[]",
			}) do
				results = {}
				open_window():respond(200, body)
				assert.equal("refused", results[1].reason, body)
			end
			assert.same({}, s:load())
			assert.is_false(c:has_token())
			for _, line in ipairs(lines) do
				assert.is_nil(line:find("TEST TOKEN NOT REAL", 1, true))
			end
		end)

		it("cuts the instance name to 32 characters, without control characters", function()
			name = "Living Room\n" .. string.rep("x", 60)
			local sent = c4:JsonDecode(open_window().data).instanceName
			assert.is_true(#sent <= 32)
			assert.is_nil(sent:find("\n", 1, true))
		end)

		it("names itself Control4 when the device's name is missing", function()
			name = nil
			assert.equal("Control4", c4:JsonDecode(open_window().data).instanceName)
		end)
	end)

	describe("the identity before the window", function()
		it("ends on a camera without asking for a registration", function()
			p:open(BOX, done)
			answer_identity(device_body({ deviceType = "HSC001" }))
			assert.equal(0, posts())
			assert.is_false(results[1].ok)
			assert.equal("identity:camera", results[1].reason)
			assert.is_false(p:is_open())
		end)

		it("expects the stored id when one is stored (another box only after Forget Pairing)", function()
			s:save({ box_id = OTHER_ID })
			p:open(BOX, done)
			answer_identity()
			assert.equal(0, posts())
			assert.equal("identity:wrong_box", results[1].reason)
			assert.equal(ID, results[1].device.id)
		end)

		it("re-pairs the stored box", function()
			s:save({ box_id = ID, registration_id = "3" })
			pair()
			assert.equal("7", s:load().registration_id)
		end)

		it("ends on an address where nothing answers", function()
			p:open(BOX, done)
			c4.last_transfer():done(7, "Couldn't connect to server")
			assert.equal("identity:unreachable", results[1].reason)
			assert.truthy(results[1].text)
		end)

		it("leaves the paired box as it was when pairing at another address fails", function()
			c:set_address(BOX)
			pair()
			p:open(OTHER, done)
			answer_identity(device_body({ uniqueId = OTHER_ID }))
			assert.equal("identity:wrong_box", results[2].reason)
			assert.equal(BOX, c:get_address())
			assert.is_true(c:has_token())
			assert.is_true(i:ok())
		end)
	end)

	describe("the window rule (N-9)", function()
		it("drops a token that arrives after close()", function()
			local t = open_window()
			p:close()
			assert.same({ ok = false, reason = "closed" }, results[1])
			t:respond(200, registration_body())
			assert.equal(1, #results)
			assert.same({}, s:load())
			assert.is_nil(c4.persist.syncbox_token)
			assert.is_false(c:has_token())
		end)

		it("drops a token that arrives after the window ran out", function()
			local t = open_window()
			c4.advance(121000)
			assert.equal("timeout", results[1].reason)
			t:respond(200, registration_body())
			assert.equal(1, #results)
			assert.is_nil(c4.persist.syncbox_token)
			assert.is_false(c:has_token())
		end)

		it("drops a token that arrives after Forget Pairing", function()
			local t = open_window()
			local forgot
			p:forget(function(r) forgot = r end)
			assert.equal("closed", results[1].reason)
			assert.same({ ok = true, deleted_on_box = false }, forgot)
			t:respond(200, registration_body())
			assert.is_nil(c4.persist.syncbox_token)
			assert.is_false(c:has_token())
		end)

		it("drops a token for the address of a window that another open() replaced", function()
			local first = open_window(OTHER)
			p:open(BOX, done)
			assert.equal("closed", results[1].reason)
			first:respond(200, registration_body("TEST-TOKEN-NOT-REAL-OTHER"))
			assert.is_false(c:has_token())
			answer_identity()
			registration_request():respond(200, registration_body())
			assert.is_true(results[2].ok)
			assert.equal(BOX, results[2].address)
			assert.equal(TOKEN, s:load().token)
			assert.equal(BOX, c:get_address())
		end)

		it("drops an identity answer that arrives after close()", function()
			p:open(BOX, done)
			p:close()
			answer_identity()
			assert.equal(0, posts())
			assert.equal(1, #results)
		end)
	end)

	describe("forget", function()
		local forgot

		local function forget()
			forgot = nil
			p:forget(function(r) forgot = r end)
		end

		before_each(function()
			c:set_address(BOX)
			pair()
		end)

		it("deletes the registration with its own token, then clears everything", function()
			forget()
			local t = c4.last_transfer()
			assert.equal("DELETE", t.method)
			assert.equal("https://10.0.2.150/api/v1/registrations/7", t.url)
			assert.equal("Bearer " .. TOKEN, t.headers.Authorization)
			assert.is_nil(forgot)
			t:respond(200, "")
			assert.same({ ok = true, deleted_on_box = true, status = 200 }, forgot)
			assert.same({}, s:load())
			assert.is_nil(c4.persist.syncbox_token)
			assert.is_false(c:has_token())
		end)

		it("clears everything when the box does not answer, and says the registration stays", function()
			forget()
			c4.last_transfer():done(28, "Timeout was reached")
			assert.same({ ok = true, deleted_on_box = false }, forgot)
			assert.same({}, s:load())
			assert.is_false(c:has_token())
		end)

		it("reads 404 and 401 as nothing of ours left on the box, other errors as left there", function()
			forget()
			c4.last_transfer():respond(404, '{"code":404,"message":"Not Found"}')
			assert.is_true(forgot.deleted_on_box)
			for _, case in ipairs({ { 401, true }, { 403, false }, { 500, false } }) do
				s:save({ token = TOKEN, registration_id = "7", box_id = ID, address = BOX })
				c:set_token(TOKEN)
				i:check(BOX, ID, function() end)
				answer_identity()
				forget()
				c4.last_transfer():respond(case[1], '{"code":1}')
				assert.equal(case[2], forgot.deleted_on_box, case[1])
				assert.equal(case[1], forgot.status)
			end
		end)

		it("sends nothing to a box whose identity is not proven, and clears all the same", function()
			c:set_address(OTHER)
			c:set_address(BOX)
			assert.is_false(i:ok())
			local n = #c4.transfers
			forget()
			assert.equal(n, #c4.transfers)
			assert.same({ ok = true, deleted_on_box = false }, forgot)
			assert.same({}, s:load())
		end)

		it("ends by itself when the DELETE's end never comes, but not on a timer fired early", function()
			forget()
			c4.fire_timers()
			assert.is_nil(forgot)
			c4.advance(pairing.FORGET_GUARD_MS)
			assert.same({ ok = true, deleted_on_box = false }, forgot)
			assert.is_false(c:has_token())
		end)

		it("sends no DELETE for a stored registration id that is not one", function()
			s.memory.registration_id = "7/../x"
			local n = #c4.transfers
			forget()
			assert.equal(n, #c4.transfers)
			assert.is_false(forgot.deleted_on_box)
		end)
	end)
end)
