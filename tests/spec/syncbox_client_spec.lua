-- #514, stage 2 §3.1 (docs/hdmi-sync-stage2-design.md): syncbox/client.lua,
-- the Hue Sync Box's API client: common/https.lua configured for the box,
-- one request in flight and a short queue, keyed requests only to a trusted
-- box, and the token in no log line or error text. Placeholders only: box
-- 10.0.2.150 and 198.51.100.150, token TEST-TOKEN-NOT-REAL.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BOX = "10.0.2.150"
local OTHER = "198.51.100.150"
local TOKEN = "TEST-TOKEN-NOT-REAL"

describe("syncbox/client.lua (#514 stage 2)", function()
	local client, c4, c, lines, answers

	-- A callback that records its arguments in `answers`.
	local function recorder(tag)
		return function(ok, status, decoded, err, err_code)
			answers[#answers + 1] = { tag = tag, ok = ok, status = status, decoded = decoded, err = err,
				err_code = err_code }
		end
	end

	local function no_token_anywhere()
		for _, line in ipairs(lines) do
			assert.is_nil(line:find(TOKEN, 1, true), "a log line holds the token: " .. line)
		end
		for _, a in ipairs(answers) do
			assert.is_nil(tostring(a.err):find(TOKEN, 1, true), "an err holds the token")
		end
	end

	before_each(function()
		lines, answers = {}, {}
		log.set_debug(true)
		log.sink = function(line) lines[#lines + 1] = line end
		c4 = fake.install_c4()
		for _, m in ipairs({ "common.https", "syncbox.client" }) do package.loaded[m] = nil end
		client = require("syncbox.client")
		c = client.new({ address = BOX, token = TOKEN })
	end)

	after_each(function()
		no_token_anywhere()
		log.set_debug(false)
		log.sink = print
	end)

	describe("the https instance (§3.1)", function()
		it("pins the box's root, sends the token as a Bearer header and uses the box's timeouts", function()
			c:set_trusted(true)
			c:get("", recorder("state"))
			local t = c4.last_transfer()
			assert.equal("GET", t.method)
			assert.equal("https://10.0.2.150/api/v1", t.url)
			assert.equal("Bearer " .. TOKEN, t.headers.Authorization)
			assert.equal("certs/hsb_ca.pem", t.options.ssl_cabundle)
			assert.is_true(t.options.ssl_verify_peer)
			assert.is_false(t.options.ssl_verify_host)
			assert.equal(6, t.options.timeout)
			assert.equal(3, t.options.connect_timeout)
			assert.equal(1, c.https.MAX_KEYED)
			assert.equal(262144, c.https.MAX_BODY)
			assert.equal("Sync box: ", c.https.LOG_PREFIX)
		end)

		it("ships the box root and a decoy that differs from it", function()
			local function read(path)
				local f = assert(io.open(path, "rb"))
				local data = f:read("*a")
				f:close()
				return data
			end
			local ca, decoy = read("src/hue_syncbox/" .. client.CA_BUNDLE), read("src/hue_syncbox/certs/decoy.pem")
			local function count(pem)
				local n = 0
				for _ in pem:gmatch("BEGIN CERTIFICATE") do n = n + 1 end
				return n
			end
			assert.equal(1, count(ca), "root-hsb only (R5 §2.2: one bundle per product)")
			assert.equal(1, count(decoy))
			assert.are_not.equal(ca, decoy)
			assert.are_not.equal(read("src/hue_bridge/certs/hue_ca_bundle.pem"), ca)
		end)

		it("hands a decoded 2xx answer to the callback", function()
			c:set_trusted(true)
			c:get("/device", recorder("device"))
			c4.last_transfer():respond(200, '{"name":"Living Room TV"}')
			assert.same({ tag = "device", ok = true, status = 200, decoded = { name = "Living Room TV" } }, answers[1])
		end)
	end)

	describe("keyed and unkeyed requests", function()
		it("waits with a keyed request until the client is trusted", function()
			c:get("", recorder("state"))
			assert.equal(0, #c4.transfers)
			assert.equal(1, c:pending())
			c:set_trusted(true)
			assert.equal(1, #c4.transfers)
			assert.equal("Bearer " .. TOKEN, c4.transfers[1].headers.Authorization)
		end)

		it("lets an unkeyed request go past a keyed one waiting for the trust, with no token", function()
			c:get("", recorder("state"))
			c:get("/device", recorder("device"), { unkeyed = true })
			assert.equal(1, #c4.transfers)
			local t = c4.transfers[1]
			assert.equal("https://10.0.2.150/api/v1/device", t.url)
			assert.is_nil(t.headers.Authorization)
			t:respond(200, '{"uniqueId":"0A1B2C3D4E5F"}')
			assert.equal("device", answers[1].tag)
			assert.equal(1, #c4.transfers, "the keyed one still waits")
		end)

		it("takes the options as get's and delete's fourth argument too", function()
			c:get("/device", recorder("device"), nil, { unkeyed = true })
			assert.is_nil(c4.last_transfer().headers.Authorization)
			c4.last_transfer():respond(200, "{}")
			c:delete("/registrations/7", recorder("delete"), nil, { unkeyed = true })
			assert.equal("DELETE", c4.last_transfer().method)
			assert.is_nil(c4.last_transfer().headers.Authorization)
		end)

		it("sends an unkeyed request to its own address without moving the client", function()
			c:post("/registrations", { appName = "c4-hue", instanceName = "Bedroom" }, recorder("post"),
				{ unkeyed = true, address = OTHER })
			local t = c4.last_transfer()
			assert.equal("POST", t.method)
			assert.equal("https://198.51.100.150/api/v1/registrations", t.url)
			assert.same({ appName = "c4-hue", instanceName = "Bedroom" }, c4:JsonDecode(t.data))
			assert.is_nil(t.headers.Authorization)
			assert.equal(BOX, c:get_address())
		end)

		it("refuses a keyed request to another address than the client's", function()
			c:set_trusted(true)
			c:get("", recorder("state"), { address = OTHER })
			assert.equal(0, #c4.transfers)
			assert.is_false(answers[1].ok)
			assert.is_nil(answers[1].status)
		end)

		it("answers a keyed request at once with 'not paired' while no token is held", function()
			c = client.new({ address = BOX })
			c:set_trusted(true)
			c:get("", recorder("state"))
			assert.equal(0, #c4.transfers)
			assert.same({ tag = "state", ok = false, err = "not paired" }, answers[1])
		end)

		it("answers at once with 'no box address' while no address is set", function()
			c = client.new({ token = TOKEN })
			c:get("/device", recorder("device"), { unkeyed = true })
			assert.equal("no box address", answers[1].err)
			assert.equal(0, #c4.transfers)
		end)

		it("refuses every path that is not a literal after /api/v1", function()
			c:set_trusted(true)
			for _, path in ipairs({ "@198.51.100.150/x", "device", "/../x", "/device?x=1", "/a b", "/x#y", 7, false }) do
				c:get(path, recorder(tostring(path)))
			end
			assert.equal(0, #c4.transfers)
			for _, a in ipairs(answers) do
				assert.equal("invalid request path", a.err)
			end
		end)
	end)

	describe("the trust", function()
		it("is dropped by a new address and kept by the same one", function()
			c:set_trusted(true)
			c:set_address(BOX)
			assert.is_true(c:is_trusted())
			c:set_address(OTHER)
			assert.is_false(c:is_trusted())
			assert.equal(OTHER, c:get_address())
		end)

		it("is dropped by a new token and kept by the same one", function()
			c:set_trusted(true)
			c:set_token(TOKEN)
			assert.is_true(c:is_trusted())
			c:set_token("TEST-TOKEN-NOT-REAL-2")
			assert.is_false(c:is_trusted())
		end)

		it("cannot be given without an address", function()
			c:set_address(nil)
			c:set_trusted(true)
			assert.is_false(c:is_trusted())
		end)

		it("answers every waiting keyed request with 'not paired' when the token is cleared", function()
			c:get("", recorder("state"))
			c:get("/device", recorder("device"), { unkeyed = true })
			c:get("/hdmi", recorder("hdmi"))
			c:set_token(nil)
			assert.equal(2, #answers)
			assert.same({ "state", "hdmi" }, { answers[1].tag, answers[2].tag })
			assert.equal("not paired", answers[1].err)
			assert.is_false(c:has_token())
			c4.transfers[1]:respond(200, "{}")
			assert.equal("device", answers[3].tag)
		end)

		it("refuses an address that would move the URL elsewhere", function()
			for _, bad in ipairs({ "10.0.2.150/x", "user@10.0.2.150", "10.0.2.150?", "", "a b", 7 }) do
				assert.is_false(c:set_address(bad))
				assert.is_nil(c:get_address())
			end
			assert.is_true(c:set_address("10.0.2.150:443"))
			assert.is_true(c:set_address("hsb-0A1B2C3D4E5F.local"))
		end)

		it("refuses a token that cannot travel as a header, without logging it", function()
			assert.is_false(c:set_token("TEST TOKEN"))
			assert.is_false(c:has_token())
			assert.is_false(c:set_token("TEST-TOKEN\nNOT-REAL"))
			assert.is_false(c:set_token(string.rep("A", 513)))
			assert.is_false(c:set_token(""))
			assert.is_true(c:set_token(TOKEN))
			for _, line in ipairs(lines) do
				assert.is_nil(line:find("TEST TOKEN", 1, true))
			end
		end)
	end)

	describe("one request in flight", function()
		it("sends the rest first in, first out, each after the one before ended", function()
			c:set_trusted(true)
			c:get("", recorder("a"))
			c:get("/device", recorder("b"), { unkeyed = true })
			c:put("/execution", { syncActive = true }, recorder("c"))
			assert.equal(1, #c4.transfers)
			c4.transfers[1]:respond(200, "{}")
			assert.equal(2, #c4.transfers)
			assert.equal("https://10.0.2.150/api/v1/device", c4.transfers[2].url)
			c4.transfers[2]:done(28, "Timeout was reached")
			assert.equal(3, #c4.transfers)
			assert.equal("PUT", c4.transfers[3].method)
			c4.transfers[3]:respond(200, "[]")
			assert.same({ "a", "b", "c" }, { answers[1].tag, answers[2].tag, answers[3].tag })
			assert.is_nil(answers[2].status)
			assert.equal(28, answers[2].err_code)
		end)

		it("keeps at most 8 waiting: the next is answered 'busy' at once", function()
			c:set_trusted(true)
			for i = 1, 9 do
				c:get("", recorder(i))
			end
			assert.equal(1, #c4.transfers)
			assert.equal(9, c:pending())
			c:get("", recorder("tenth"))
			assert.same({ tag = "tenth", ok = false, err = "busy" }, answers[1])
			assert.equal(9, c:pending())
			c4.transfers[1]:respond(200, "{}")
			c:get("", recorder("again"))
			assert.equal(9, c:pending())
			assert.equal(2, #answers)
		end)

		it("goes on when a callback raises", function()
			c:set_trusted(true)
			c:get("", function() error("boom") end)
			c:get("/device", recorder("next"))
			c4.transfers[1]:respond(200, "{}")
			assert.equal(2, #c4.transfers)
			c4.transfers[2]:respond(200, "{}")
			assert.equal("next", answers[1].tag)
		end)

		it("drops a request through its handle: waiting, never sent; in flight, its place freed", function()
			c:set_trusted(true)
			local first = c:get("", recorder("first"))
			local second = c:get("/device", recorder("second"))
			c:get("/hdmi", recorder("third"))
			second:Cancel()
			first:Cancel()
			assert.is_true(c4.transfers[1].cancelled)
			-- The third is the client's now; common/https.lua's own keyed slot
			-- (max_keyed 1) holds it until the cancelled transfer has ended.
			assert.equal(1, c:pending())
			assert.equal(1, #c4.transfers)
			c4.transfers[1]:respond(200, "{}") -- a late end of the cancelled one: no answer for it
			assert.equal(2, #c4.transfers)
			assert.equal("https://10.0.2.150/api/v1/hdmi", c4.transfers[2].url)
			c4.transfers[2]:respond(200, "{}")
			assert.equal(1, #answers)
			assert.equal("third", answers[1].tag)
		end)

		it("sends an unkeyed request at once after an in-flight one was dropped", function()
			local first = c:get("/device", recorder("first"), { unkeyed = true })
			c:get("/device", recorder("second"), { unkeyed = true })
			first:Cancel()
			assert.equal(2, #c4.transfers)
			c4.transfers[2]:respond(200, "{}")
			c4.transfers[1]:respond(200, "{}")
			assert.equal(1, #answers)
			assert.equal("second", answers[1].tag)
		end)

		it("frees the place of a request whose end never came, at its deadline", function()
			c:set_trusted(true)
			c:get("", recorder("lost"))
			c:get("/device", recorder("next"))
			c4.fire_timers() -- early: the clock has not moved, nothing is freed
			assert.equal(1, #c4.transfers)
			assert.equal(0, #answers)
			c4.advance((6 + client.SLOT_GRACE_S) * 1000)
			assert.equal("lost", answers[1].tag)
			assert.equal("no end reported", answers[1].err)
			assert.equal(2, #c4.transfers)
			c4.transfers[1]:respond(200, "{}") -- the lost end, late: ignored
			assert.equal(1, #answers)
		end)

		it("cancel_all drops every request without calling back", function()
			c:set_trusted(true)
			c:get("", recorder("a"))
			c:get("", recorder("b"))
			c:cancel_all()
			assert.equal(0, c:pending())
			c4.transfers[1]:respond(200, "{}")
			assert.equal(0, #answers)
			assert.equal(1, #c4.transfers)
		end)
	end)

	describe("answers", function()
		before_each(function()
			c:set_trusted(true)
		end)

		it("hands an error answer's body over, with the box's code and message in err", function()
			c:post("/registrations", { appName = "c4-hue" }, recorder("post"), { unkeyed = true })
			c4.last_transfer():respond(400, '{"code":16,"message":"Invalid State"}')
			local a = answers[1]
			assert.is_false(a.ok)
			assert.equal(400, a.status)
			assert.equal(16, a.decoded.code)
			assert.equal("HTTP 400, box error 16: Invalid State", a.err)
		end)

		it("is not ok on a 2xx whose body is not JSON, except an empty one to a PUT or DELETE", function()
			c:get("", recorder("get"))
			c4.last_transfer():respond(200, "<html>")
			c:delete("/registrations/7", recorder("delete"))
			c4.last_transfer():respond(200, "")
			c:get("/device", recorder("empty"))
			c4.last_transfer():respond(204, "")
			assert.is_false(answers[1].ok)
			assert.is_true(answers[2].ok)
			assert.is_nil(answers[2].decoded)
			assert.is_false(answers[3].ok)
		end)

		it("refuses a body over 256 KB before decoding it", function()
			c:get("", recorder("big"))
			c4.last_transfer():respond(200, '"' .. string.rep("x", 262144) .. '"')
			assert.is_false(answers[1].ok)
			assert.equal(200, answers[1].status)
			assert.is_nil(answers[1].decoded)
			assert.truthy(answers[1].err:find("refused", 1, true))
		end)

		it("never follows a redirect with the token", function()
			c:get("", recorder("state"))
			local t = c4.last_transfer()
			t:redirect(302, "http://203.0.113.9/steal")
			assert.is_true(t.aborted)
			assert.is_false(answers[1].ok)
			assert.equal(302, answers[1].status)
			assert.equal("redirect refused (HTTP 302)", answers[1].err)
		end)

		it("cuts the token out of an error text, and logs it nowhere even at debug", function()
			c:get("", recorder("state"))
			c4.last_transfer():respond(401, '{"code":2,"message":"Invalid Token ' .. TOKEN .. '"}')
			assert.equal("HTTP 401, box error 2: Invalid Token <token>", answers[1].err)
			c:put("/execution", { mode = "video" }, recorder("put"))
			c4.last_transfer():done(35, "TLS handshake failed for " .. TOKEN)
			assert.is_nil(answers[2].err:find(TOKEN, 1, true))
			assert.is_true(#lines > 0, "debug lines were written")
			-- no_token_anywhere() runs after each test
		end)

		it("passes curl's code on, and tells a certificate failure from the rest", function()
			c:get("/device", recorder("device"), { unkeyed = true })
			c4.last_transfer():done(60, "SSL peer certificate or SSH remote key was not OK")
			assert.equal(60, answers[1].err_code)
			assert.is_true(c:certificate_failure(answers[1].err_code))
			assert.is_false(c:certificate_failure(28))
			assert.is_false(c:certificate_failure(nil))
		end)
	end)

	describe("the TLS self-check's transport", function()
		it("sends the decoy request through the queue, unkeyed, with its own bundle", function()
			c:set_trusted(true)
			c:get("", recorder("state"))
			local transport = c:tls_transport()
			local result
			transport.request({ ip = BOX, path = "/api/v1/device", tls = { ssl_cabundle = "certs/decoy.pem" },
				quiet = true, key = "must-not-go" }, function(r) result = r end)
			assert.equal(0, #c4.decoy_transfers, "waits behind the request in flight")
			c4.transfers[1]:respond(200, "{}")
			assert.equal(1, #c4.decoy_transfers)
			local decoy = c4.decoy_transfers[1]
			assert.equal("https://10.0.2.150/api/v1/device", decoy.url)
			assert.equal("certs/decoy.pem", decoy.options.ssl_cabundle)
			assert.is_nil(decoy.headers.Authorization)
			assert.is_true(transport.certificate_failure(result))
			assert.equal(0, c:pending())
		end)

		it("refuses an address that would move the decoy request elsewhere", function()
			local result
			c:tls_transport().request({ ip = "10.0.2.150/x", path = "/api/v1/device",
				tls = { ssl_cabundle = "certs/decoy.pem" } }, function(r) result = r end)
			assert.same({ ok = false, err = "invalid address" }, result)
			assert.equal(0, #c4.decoy_transfers)
			assert.equal(0, #c4.transfers)
		end)
	end)
end)
