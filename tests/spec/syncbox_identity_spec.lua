-- #514, stage 2 §3.3 (docs/hdmi-sync-stage2-design.md): syncbox/identity.lua,
-- the Hue Sync Box's identity before its token goes anywhere: the TLS
-- self-check with the box's decoy bundle, then the unkeyed GET
-- /api/v1/device and its uniqueId, and the client's trust that follows.
-- Runs on the real client (syncbox/client.lua) and the fake runtime's
-- transfers. Placeholders only: box 10.0.2.150 and 198.51.100.150, id
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

describe("syncbox/identity.lua (#514 stage 2)", function()
	local client, identity, c4, c, i, lines

	-- GET /device's answer: an 8K box unless `over` says otherwise (a false
	-- value leaves the field out).
	local function device_body(over)
		local d = { name = "Living Room TV", deviceType = "HSB2", uniqueId = "0a1b2c3d4e5f", apiLevel = 14,
			firmwareVersion = "2.4.1", buildNumber = 2041 }
		for k, v in pairs(over or {}) do
			if v == false then d[k] = nil else d[k] = v end
		end
		return c4:JsonEncode(d)
	end

	-- Start a check; returns a table that gets the result.
	local function check(address, expected)
		local box = { calls = 0 }
		i:check(address, expected, function(result)
			box.calls = box.calls + 1
			box.result = result
		end)
		return box
	end

	-- The GET /device transfer the check is waiting for.
	local function device_request()
		local t = c4.last_transfer()
		assert.truthy(t, "a GET /device was sent")
		assert.equal("GET", t.method)
		assert.truthy(t.url:find("/api/v1/device$"))
		assert.is_nil(t.headers.Authorization, "never with the token")
		return t
	end

	before_each(function()
		lines = {}
		log.set_debug(true)
		log.sink = function(line) lines[#lines + 1] = line end
		c4 = fake.install_c4()
		for _, m in ipairs({ "common.https", "common.tlscheck", "syncbox.client", "syncbox.identity" }) do
			package.loaded[m] = nil
		end
		client = require("syncbox.client")
		identity = require("syncbox.identity")
		c = client.new({ address = BOX })
		i = identity.new({ client = c })
	end)

	after_each(function()
		for _, line in ipairs(lines) do
			assert.is_nil(line:find(TOKEN, 1, true), "a log line holds the token: " .. line)
		end
		log.set_debug(false)
		log.sink = print
	end)

	describe("a first pairing's check (no expected id, no token)", function()
		it("runs the TLS self-check with the box's decoy, then GET /device unkeyed", function()
			local box = check(BOX)
			assert.equal(1, #c4.decoy_transfers)
			local decoy = c4.decoy_transfers[1]
			assert.equal("https://10.0.2.150/api/v1/device", decoy.url)
			assert.equal("certs/decoy.pem", decoy.options.ssl_cabundle)
			assert.is_true(decoy.options.ssl_verify_peer)
			assert.is_nil(decoy.headers.Authorization)
			local t = device_request()
			assert.equal("https://10.0.2.150/api/v1/device", t.url)
			assert.equal("certs/hsb_ca.pem", t.options.ssl_cabundle)
			t:respond(200, device_body())
			assert.equal(1, box.calls)
			assert.same({
				ok = true,
				reason = "ok",
				device = { id = ID, name = "Living Room TV", model = "HSB2", firmware = "2.4.1", api_level = 14,
					device_type = "HSB2" },
			}, box.result)
		end)

		it("remembers the Director version that answered pinned", function()
			check(BOX)
			device_request():respond(200, device_body())
			assert.equal(c4.director_version, c4.persist.tls_pinned_on)
		end)

		it("trusts the address while no token is held, so pairing may follow", function()
			check(BOX)
			device_request():respond(200, device_body())
			assert.is_true(c:is_trusted())
			assert.is_true(i:ok())
			assert.equal(ID, i:trusted_id())
		end)

		it("loses that trust when a token is set afterwards (the token's box is proven on its own)", function()
			check(BOX)
			device_request():respond(200, device_body())
			c:set_token(TOKEN)
			assert.is_false(i:ok())
		end)
	end)

	describe("models", function()
		it("refuses a Hue camera (HSC001, O2)", function()
			local box = check(BOX)
			device_request():respond(200, device_body({ deviceType = "HSC001" }))
			assert.is_false(box.result.ok)
			assert.equal("camera", box.result.reason)
			assert.equal("HSC001", box.result.device.model)
			assert.is_false(i:ok())
		end)

		it("allows a box of a model it does not know, with a warning", function()
			local box = check(BOX)
			device_request():respond(200, device_body({ deviceType = "HSB9" }))
			assert.is_true(box.result.ok)
			assert.equal("unknown_model", box.result.reason)
			assert.equal("unknown", box.result.device.model)
			assert.equal("HSB9", box.result.device.device_type)
			assert.is_true(i:ok())
			local warned = false
			for _, line in ipairs(lines) do
				if line:find("[WARN]", 1, true) and line:find("unknown_model", 1, true) then warned = true end
			end
			assert.is_true(warned)
		end)

		it("knows the three boxes", function()
			for _, model in ipairs({ "HSB1", "HSB2", "HSB3" }) do
				local box = check(BOX)
				device_request():respond(200, device_body({ deviceType = model }))
				assert.equal("ok", box.result.reason)
				assert.equal(model, box.result.device.model)
			end
		end)

		it("cuts the box's texts and checks its numbers", function()
			local box = check(BOX)
			device_request():respond(200, device_body({
				name = "Living\nRoom " .. string.rep("x", 400),
				firmwareVersion = string.rep("9", 50),
				apiLevel = 1e9,
				deviceType = "HSB2",
			}))
			local d = box.result.device
			assert.is_nil(d.name:find("\n", 1, true))
			assert.is_true(#d.name <= 256)
			assert.is_true(#d.firmware <= 32)
			assert.is_nil(d.api_level)
		end)
	end)

	describe("what is not a box", function()
		it("reads a certificate that does not chain to root-hsb as not a box", function()
			local box = check(BOX)
			device_request():done(60, "SSL peer certificate or SSH remote key was not OK")
			assert.equal("not_a_box", box.result.reason)
			assert.is_false(box.result.ok)
			assert.is_nil(box.result.device)
		end)

		it("reads an HTTP error, a body that is not JSON or one without a 12-digit id as not a box", function()
			for _, answer in ipairs({
				{ 404, '{"code":404}' },
				{ 200, "<html></html>" },
				{ 200, device_body({ uniqueId = false }) },
				{ 200, device_body({ uniqueId = "0A1B2C3D4E5" }) },
				{ 200, device_body({ uniqueId = "0A1B2C3D4E5G" }) },
				{ 200, '"0A1B2C3D4E5F"' },
			}) do
				local box = check(BOX)
				device_request():respond(answer[1], answer[2])
				assert.equal("not_a_box", box.result.reason, answer[2])
			end
			assert.is_false(i:ok())
		end)

		it("reads no answer as unreachable", function()
			local box = check(BOX)
			device_request():done(28, "Timeout was reached")
			assert.equal("unreachable", box.result.reason)
			assert.truthy(box.result.detail:find("Timeout", 1, true))
			box = check(nil)
			assert.equal("unreachable", box.result.reason)
			local sent = #c4.transfers
			box = check("10.0.2.150/x")
			assert.equal("unreachable", box.result.reason)
			assert.equal(sent, #c4.transfers, "nothing is sent to an address that would move the URL")
		end)
	end)

	describe("the expected id", function()
		before_each(function()
			c:set_token(TOKEN)
		end)

		it("is compared upper-case and grants the trust when it matches", function()
			c:get("", function() end) -- a keyed poll, waiting for the trust
			assert.equal(0, #c4.transfers)
			local box = check(BOX, "0a1b2c3d4e5f")
			device_request():respond(200, device_body())
			assert.equal("ok", box.result.reason)
			assert.is_true(i:ok())
			local poll = c4.last_transfer()
			assert.equal("https://10.0.2.150/api/v1", poll.url)
			assert.equal("Bearer " .. TOKEN, poll.headers.Authorization)
		end)

		it("refuses another box at the address and never sends it the token", function()
			c:get("", function() end)
			local box = check(BOX, OTHER_ID)
			device_request():respond(200, device_body())
			assert.is_false(box.result.ok)
			assert.equal("wrong_box", box.result.reason)
			assert.equal(ID, box.result.device.id)
			assert.truthy(box.result.detail:find(OTHER_ID, 1, true))
			assert.is_false(i:ok())
			for _, t in ipairs(c4.transfers) do
				assert.is_nil(t.headers.Authorization)
			end
		end)

		it("reads a stored id that is not an id as another box's", function()
			local box = check(BOX, "not-an-id")
			device_request():respond(200, device_body())
			assert.equal("wrong_box", box.result.reason)
		end)

		it("withdraws the trust when a check expecting it fails", function()
			check(BOX, ID)
			device_request():respond(200, device_body())
			assert.is_true(i:ok())
			check(BOX, ID)
			device_request():done(7, "Couldn't connect to server")
			assert.is_false(i:ok())
			assert.is_false(c:is_trusted())
		end)
	end)

	describe("the TLS self-check", function()
		it("stops at not_pinned: no GET /device, and it sticks to every address until reset", function()
			c4.tls_ignores_cabundle = true
			local box = check(BOX)
			local decoy = c4.last_transfer()
			assert.equal("certs/decoy.pem", decoy.options.ssl_cabundle)
			decoy:respond(200, device_body())
			assert.equal("not_pinned", box.result.reason)
			assert.is_false(box.result.ok)
			assert.equal(1, #c4.transfers, "no GET /device")
			c4.tls_ignores_cabundle = false
			box = check(OTHER)
			assert.equal("not_pinned", box.result.reason)
			assert.equal(1, #c4.transfers)
			assert.equal(0, #c4.decoy_transfers)
			i:reset()
			box = check(BOX)
			assert.equal(1, #c4.decoy_transfers)
			device_request():respond(200, device_body())
			assert.equal("ok", box.result.reason)
		end)

		it("is inconclusive on a Director version that never answered pinned, after asking the box anyway", function()
			c4.tls_ignores_cabundle = true
			c:set_token(TOKEN)
			local box = check(BOX, ID)
			c4.last_transfer():done(28, "Timeout was reached")
			device_request():respond(200, device_body())
			assert.is_false(box.result.ok)
			assert.equal("inconclusive", box.result.reason)
			assert.is_false(i:ok())
		end)

		it("reads an address with nothing on it as unreachable, not inconclusive", function()
			c4.tls_ignores_cabundle = true
			local box = check(BOX)
			c4.last_transfer():done(7, "Couldn't connect to server")
			device_request():done(7, "Couldn't connect to server")
			assert.equal("unreachable", box.result.reason)
		end)

		it("lets inconclusive pass on a Director version that answered pinned before", function()
			c4.persist.tls_pinned_on = c4.director_version
			c4.tls_ignores_cabundle = true
			c:set_token(TOKEN)
			local box = check(BOX, ID)
			c4.last_transfer():done(28, "Timeout was reached")
			device_request():respond(200, device_body())
			assert.equal("ok", box.result.reason)
			assert.is_true(i:ok())
		end)

		it("is asked once per address until reset", function()
			check(BOX)
			device_request():respond(200, device_body())
			check(BOX)
			device_request():respond(200, device_body())
			assert.equal(1, #c4.decoy_transfers)
			check(OTHER)
			assert.equal(2, #c4.decoy_transfers)
			device_request():respond(200, device_body())
			i:reset()
			check(BOX)
			assert.equal(3, #c4.decoy_transfers)
		end)

		it("waits its turn behind the request in flight (one at a time)", function()
			c:set_token(TOKEN)
			c:set_trusted(true)
			c:get("", function() end)
			check(BOX, ID)
			assert.equal(0, #c4.decoy_transfers)
			assert.equal(1, #c4.transfers)
			c4.transfers[1]:respond(200, "{}")
			assert.equal(1, #c4.decoy_transfers)
			assert.equal(2, #c4.transfers)
		end)

		it("takes a tlscheck instance the driver built", function()
			local runs = {}
			i = identity.new({ client = c, tlscheck = {
				run = function(address, cb) runs[#runs + 1] = address; cb("pinned", "test") end,
				remember_pinned = function() end,
				pinned_before = function() return false end,
			} })
			local box = check(BOX)
			device_request():respond(200, device_body())
			assert.same({ BOX }, runs)
			assert.equal("ok", box.result.reason)
		end)
	end)

	describe("the trust moves only for the client's address", function()
		before_each(function()
			c:set_token(TOKEN)
			check(BOX, ID)
			device_request():respond(200, device_body())
			assert.is_true(i:ok())
		end)

		it("is not moved by a check at another address (a discovery candidate)", function()
			local box = check(OTHER)
			device_request():respond(200, device_body({ uniqueId = OTHER_ID }))
			assert.equal("ok", box.result.reason)
			assert.is_true(i:ok())
			box = check(OTHER, ID)
			device_request():respond(200, device_body({ uniqueId = OTHER_ID }))
			assert.equal("wrong_box", box.result.reason)
			assert.is_true(i:ok())
			assert.equal(ID, i:trusted_id())
		end)

		it("is kept by a check without an expected id that finds the same box, or none", function()
			check(BOX)
			device_request():respond(200, device_body())
			assert.is_true(i:ok())
			check(BOX)
			device_request():done(28, "Timeout was reached")
			assert.is_true(i:ok())
		end)

		it("is withdrawn by a check without an expected id that finds another box", function()
			local box = check(BOX)
			device_request():respond(200, device_body({ uniqueId = OTHER_ID }))
			assert.equal("ok", box.result.reason)
			assert.is_false(i:ok())
			assert.is_false(c:is_trusted())
		end)

		it("is gone when the client's address changes", function()
			c:set_address(OTHER)
			assert.is_false(i:ok())
			c:set_address(BOX)
			assert.is_false(i:ok())
		end)

		it("is not touched by a check that ends after a reset; its caller still hears", function()
			local box = check(BOX, OTHER_ID)
			local t = device_request()
			i:reset()
			assert.is_false(i:ok())
			c:set_trusted(true) -- as if a newer check had passed meanwhile
			t:respond(200, device_body())
			assert.equal(1, box.calls)
			assert.equal("wrong_box", box.result.reason)
			assert.is_true(c:is_trusted())
		end)

		it("is checked again by recheck with the trusted id", function()
			local box = { calls = 0 }
			i:recheck(function(result) box.calls, box.result = box.calls + 1, result end)
			device_request():respond(200, device_body({ uniqueId = OTHER_ID }))
			assert.equal("wrong_box", box.result.reason)
			assert.is_false(i:ok())
			i:recheck(function(result) box.result = result end)
			device_request():respond(200, device_body())
			assert.equal("ok", box.result.reason)
			assert.is_true(i:ok())
		end)
	end)

	describe("adopt (pairing's success)", function()
		it("trusts a box that passed at its address in this generation, once the client uses that address", function()
			c:set_token(TOKEN)
			local box = check(OTHER)
			device_request():respond(200, device_body())
			local device = box.result.device
			assert.is_false(i:adopt(OTHER, device), "not the client's address yet")
			c:set_address(OTHER)
			assert.is_false(i:adopt(OTHER, { id = OTHER_ID }), "not the id that passed there")
			assert.is_true(i:adopt(OTHER, device))
			assert.is_true(i:ok())
			assert.equal(ID, i:trusted_id())
		end)

		it("trusts nothing that did not pass, or passed before a reset", function()
			c:set_token(TOKEN)
			assert.is_false(i:adopt(BOX, { id = ID }))
			check(BOX)
			device_request():respond(200, device_body())
			i:reset()
			assert.is_false(i:adopt(BOX, { id = ID }))
			assert.is_false(i:ok())
		end)
	end)
end)
