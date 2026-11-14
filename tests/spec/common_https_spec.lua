-- #514, stage 1 §3 (docs/hdmi-sync-stage1-design.md): common/https.lua, the
-- HTTPS core the Hue bridge and the Hue Sync Box share. bridge/http.lua is
-- one instance (tests/spec/http_spec.lua covers it, unchanged); this spec
-- covers what the parameters change: another auth header, another bundle,
-- other caps, timeouts and log prefix, and instances that keep apart.
-- Placeholders only: bridge 10.0.2.143, sync box 10.0.2.150.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BOX_IP = "10.0.2.150"
local BRIDGE_IP = "10.0.2.143"

local function read_file(path)
	local f = assert(io.open(path, "rb"))
	local data = f:read("*a")
	f:close()
	return data
end

describe("common/https.lua (#514)", function()
	local https, c4, box, lines

	-- An instance configured the way the box driver will (stage 2), with
	-- small caps so the spec can reach them.
	local function box_client(extra)
		local opts = {
			ca_bundle = "certs/hsb_ca.pem",
			header_key = { name = "Authorization", prefix = "Bearer " },
			max_keyed = 1,
			timeout = 6,
			connect_timeout = 3,
			slot_grace_s = 2,
			text_row = 64,
			text_log = 500,
			max_body = 64,
			log_prefix = "Sync Box: ",
		}
		for k, v in pairs(extra or {}) do opts[k] = v end
		return https.new(opts)
	end

	before_each(function()
		lines = {}
		log.set_debug(false)
		log.sink = function(line) lines[#lines + 1] = line end
		c4 = fake.install_c4()
		package.loaded["common.https"] = nil
		https = require("common.https")
		box = box_client()
	end)

	after_each(function()
		log.sink = print
		log.set_debug(false)
	end)

	describe("the auth header", function()
		it("sends the key under the configured header, behind its prefix, and nothing under the bridge's", function()
			box.request({ ip = BOX_IP, path = "/api/v1", key = "<token>" }, function() end)
			local t = c4.last_transfer()
			assert.equal("https://" .. BOX_IP .. "/api/v1", t.url)
			assert.equal("Bearer <token>", t.headers.Authorization)
			assert.is_nil(t.headers["hue-application-key"])
			assert.equal("Authorization", box.AUTH_HEADER)
			assert.equal("Bearer ", box.AUTH_PREFIX)
		end)

		it("sends the key as it is when header_key is a plain header name (the bridge's shape)", function()
			local bridge = https.new({ ca_bundle = "certs/hue_ca_bundle.pem", header_key = "hue-application-key" })
			bridge.request({ ip = BRIDGE_IP, path = "/clip/v2/resource/light", key = "<key>" }, function() end)
			local t = c4.last_transfer()
			assert.same({ ["hue-application-key"] = "<key>" }, t.headers)
			assert.is_nil(bridge.AUTH_PREFIX)
		end)

		it("sends no header at all on an unkeyed request, and a body's Content-Type only", function()
			box.request({ ip = BOX_IP, path = "/api/v1/device" }, function() end)
			assert.same({}, c4.last_transfer().headers)
			box.request({ ip = BOX_IP, path = "/api/v1/registrations", method = "POST", body = { appName = "x" } },
				function() end)
			assert.same({ ["Content-Type"] = "application/json" }, c4.last_transfer().headers)
		end)

		it("carries the key on a stream under the same header, beside the stream's own headers", function()
			box.stream({ ip = BOX_IP, path = "/events", key = "<token>", headers = { Accept = "text/event-stream" } },
				{ on_done = function() end })
			local t = c4.last_transfer()
			assert.same({ Authorization = "Bearer <token>", Accept = "text/event-stream" }, t.headers)
		end)

		it("refuses at new() a missing header_key, a name that is no header name and a prefix with a control character",
			function()
				for _, bad in ipairs({ false, "", "two words", "x\r\nInjected: 1", { prefix = "Bearer " },
					{ name = "Authorization", prefix = "Bearer\n" }, { name = "Authorization", prefix = 5 } }) do
					local ok, err = pcall(https.new, { ca_bundle = "certs/hsb_ca.pem", header_key = bad or nil })
					assert.is_false(ok, tostring(bad))
					assert.truthy(tostring(err):find("header_key", 1, true), tostring(err))
				end
			end)

		-- Security review 2026-10-25, finding 7, for the box's token: C4:url
		-- follows a redirect by itself, and curl may send the header along.
		it("refuses a redirect on a keyed request, so the token never follows a Location", function()
			local got
			box.request({ ip = BOX_IP, path = "/api/v1", key = "<token>" }, function(r) got = r end)
			local t = c4.last_transfer()
			t:redirect(302, "http://203.0.113.9/api/v1")
			assert.is_true(t.aborted)
			assert.same({ ok = false, code = 302, err = "redirect refused (HTTP 302)" }, got)
		end)
	end)

	describe("the CA bundle and the timeouts", function()
		it("verifies the peer against its own bundle, not the hostname, with its own timeouts", function()
			box.request({ ip = BOX_IP, path = "/api/v1", key = "<token>" }, function() end)
			local t = c4.last_transfer()
			assert.same({ fail_on_error = false, timeout = 6, connect_timeout = 3, ssl_verify_peer = true,
				ssl_verify_host = false, ssl_cabundle = "certs/hsb_ca.pem" }, t.options)
			assert.equal("certs/hsb_ca.pem", box.CA_BUNDLE)
			assert.same({ path = "certs/hsb_ca.pem" }, box.ca)
			box.request({ ip = BOX_IP, path = "/api/v1", timeout = 2 }, function() end)
			assert.equal(2, c4.last_transfer().options.timeout, "a request's own timeout wins")
		end)

		it("applies req.tls on top of its bundle's options, as the bridge's client does", function()
			c4.tls_ignores_cabundle = true
			box.request({ ip = BOX_IP, path = "/api/v1/device", tls = { ssl_cabundle = "certs/decoy_ca.pem" } },
				function() end)
			local t = c4.last_transfer()
			assert.equal("certs/decoy_ca.pem", t.options.ssl_cabundle)
			assert.is_true(t.options.ssl_verify_peer)
			assert.is_false(t.options.ssl_verify_host)
			assert.is_nil(box.options({}, { ssl_cabundle = false }).ssl_cabundle, "false leaves the platform's CAs")
		end)

		it("fails every request and stream closed without a bundle", function()
			local bare = https.new({ header_key = "x-key" })
			assert.is_nil(bare.ca)
			local got, done
			assert.is_nil(bare.request({ ip = BOX_IP, path = "/api/v1" }, function(r) got = r end))
			assert.same({ ok = false, err = "no CA configuration" }, got)
			assert.is_nil(bare.stream({ ip = BOX_IP, path = "/e" }, { on_done = function(code, msg) done = { code, msg } end }))
			assert.same({ -2, "no CA configuration" }, done)
			assert.equal(0, #c4.transfers)
		end)

		it("uses the bridge's defaults when the options leave them out", function()
			local plain = https.new({ ca_bundle = "certs/x.pem", header_key = "x-key" })
			assert.equal(15, plain.DEFAULT_TIMEOUT)
			assert.equal(5, plain.CONNECT_TIMEOUT)
			assert.equal(3, plain.MAX_KEYED)
			assert.equal(10, plain.SLOT_GRACE_S)
			assert.equal(256, plain.TEXT_ROW)
			assert.equal(2000, plain.TEXT_LOG)
			assert.is_nil(plain.MAX_BODY)
			assert.equal("", plain.LOG_PREFIX)
		end)
	end)

	describe("the keyed queue (N-8, #489) with its own cap", function()
		local function keyed(client, path, got)
			return client.request({ ip = BOX_IP, key = "<token>", method = "PUT", path = path, body = { mode = "video" } },
				function(r) got[#got + 1] = path .. "=" .. tostring(r.ok) end)
		end

		it("holds max_keyed requests in flight and starts the next one per answer", function()
			local got = {}
			keyed(box, "/api/v1/execution/1", got)
			keyed(box, "/api/v1/execution/2", got)
			assert.equal(1, #c4.transfers)
			box.request({ ip = BOX_IP, path = "/api/v1/device" }, function() end)
			assert.equal(2, #c4.transfers, "an unkeyed request is not queued")
			c4.transfers[1]:respond(200, "{}")
			assert.equal(3, #c4.transfers)
			assert.equal("https://" .. BOX_IP .. "/api/v1/execution/2", c4.transfers[3].url)
			c4.transfers[3]:respond(200, "{}")
			assert.same({ "/api/v1/execution/1=true", "/api/v1/execution/2=true" }, got)
		end)

		it("frees a lost answer's slot its own timeout and slot_grace_s later", function()
			local got = {}
			keyed(box, "/a", got)
			keyed(box, "/b", got)
			assert.equal(1, #c4.transfers)
			c4.advance((6 + 2) * 1000 - 1)
			assert.equal(1, #c4.transfers)
			c4.advance(1)
			assert.equal(2, #c4.transfers)
			assert.truthy(lines[#lines]:find("Sync Box: PUT /a: no end reported 2 s after its timeout", 1, true),
				lines[#lines])
		end)

		it("reads MAX_KEYED at every request, so a caller can change it", function()
			local got = {}
			box.MAX_KEYED = 2
			keyed(box, "/a", got)
			keyed(box, "/b", got)
			assert.equal(2, #c4.transfers)
		end)

		it("counts each instance's requests apart from another's", function()
			local bridge = https.new({ ca_bundle = "certs/hue_ca_bundle.pem", header_key = "hue-application-key" })
			local got = {}
			for i = 1, 3 do
				bridge.request({ ip = BRIDGE_IP, key = "<key>", path = "/clip/v2/resource/light/" .. i }, function() end)
			end
			keyed(box, "/api/v1/execution", got)
			assert.equal(4, #c4.transfers, "the bridge's three do not hold the box's slot")
			keyed(box, "/api/v1/execution/2", got)
			assert.equal(4, #c4.transfers, "the box's own cap still holds")
			box.ca = nil
			bridge.request({ ip = BRIDGE_IP, path = "/api/0/config" }, function() end)
			assert.equal(5, #c4.transfers, "a field changed on one instance leaves the other alone")
		end)
	end)

	describe("max_body", function()
		it("refuses a longer body before decoding it, and keeps the status", function()
			local decoded = 0
			local decode = c4.JsonDecode
			c4.JsonDecode = function(self, text)
				decoded = decoded + 1
				return decode(self, text)
			end
			local got
			box.request({ ip = BOX_IP, path = "/api/v1" }, function(r) got = r end)
			c4.last_transfer():respond(200, '{"a":"' .. string.rep("x", 60) .. '"}')
			assert.is_false(got.ok)
			assert.equal(200, got.code)
			assert.equal("response of 68 bytes refused (over 64)", got.err)
			assert.is_nil(got.body)
			assert.is_nil(got.json)
			assert.equal(0, decoded, "never decoded")

			box.request({ ip = BOX_IP, path = "/api/v1" }, function(r) got = r end)
			c4.last_transfer():respond(200, '{"a":"' .. string.rep("x", 56) .. '"}')
			assert.is_true(got.ok, "64 bytes pass")
			assert.equal(56, #got.json.a)
			assert.equal(1, decoded)
		end)

		it("caps nothing when it is not set, the bridge's case", function()
			local plain = https.new({ ca_bundle = "certs/x.pem", header_key = "x-key" })
			local got
			plain.request({ ip = BRIDGE_IP, path = "/clip/v2/resource/light" }, function(r) got = r end)
			c4.last_transfer():respond(200, '{"a":"' .. string.rep("x", 100000) .. '"}')
			assert.is_true(got.ok)
		end)
	end)

	describe("the log prefix and the peer text caps", function()
		it("puts log_prefix in front of every line of the instance, a % in it included", function()
			local odd = box_client({ log_prefix = "100% box: " })
			odd.request({ ip = BOX_IP, path = "api/v1" }, function() end)
			box.request({ ip = BOX_IP, path = "/api/v1" }, function() end)
			c4.last_transfer():done(7, "Connection refused")
			assert.same({ "[WARN] 100% box: GET api/v1: invalid request path",
				"[WARN] Sync Box: GET /api/v1: transfer failed (7): Connection refused" }, lines)
		end)

		it("logs an expected failure (req.quiet) at debug only", function()
			box.request({ ip = BOX_IP, path = "/api/v1/device", quiet = true }, function() end)
			c4.last_transfer():done(28, "Timeout was reached")
			assert.same({}, lines)
		end)

		it("cuts peer text at the instance's text_row; the module's own function at 256", function()
			local long = string.rep("abcdefghij", 100)
			assert.equal(64, #box.peer_text(long))
			assert.equal(64, box.TEXT_ROW)
			assert.equal(500, box.TEXT_LOG)
			assert.equal(500, #box.peer_text(long, box.TEXT_LOG))
			assert.equal(256, #https.peer_text(long))
			assert.equal("a[2Jb", box.peer_text("a\r\n\27[2Jb"))
		end)
	end)

	describe("the rules every instance keeps", function()
		it("refuses a path that does not start with /, in url, request and stream", function()
			for _, path in ipairs({ "@203.0.113.9/api/v1", ".attacker.example/api", ":8443/api/v1", "api/v1", "" }) do
				assert.is_false((pcall(box.url, BOX_IP, path)), path)
				local got
				assert.is_nil(box.request({ ip = BOX_IP, path = path, key = "<token>" }, function(r) got = r end))
				assert.same({ ok = false, err = "invalid request path" }, got)
				local done
				assert.is_nil(box.stream({ ip = BOX_IP, path = path }, { on_done = function(code) done = code end }))
				assert.equal(-2, done)
			end
			assert.equal(0, #c4.transfers)
		end)

		it("tells a certificate failure from every other failure, by its own list", function()
			local function result_of(err_code)
				local got
				box.request({ ip = BOX_IP, path = "/api/v1/device" }, function(r) got = r end)
				c4.last_transfer():done(err_code, "x")
				return got
			end
			assert.is_true(box.certificate_failure(result_of(60)))
			assert.is_true(box.certificate_failure(result_of(51)))
			assert.is_false(box.certificate_failure(result_of(28)))
			assert.is_true(https.certificate_failure(result_of(60)), "the module's own list")
			box.CERTIFICATE_ERRORS[28] = true
			assert.is_true(box.certificate_failure(result_of(28)), "read at every call")
			assert.is_false(https.certificate_failure(result_of(28)), "another instance's list is its own")
		end)

		it("decodes JSON without raising", function()
			assert.same({ a = 1 }, box.decode('{"a":1}'))
			local value, err = box.decode("<html>")
			assert.is_nil(value)
			assert.truthy(err:find("invalid JSON", 1, true))
			assert.equal(https.decode, box.decode)
		end)
	end)

	it("requires no bridge module, so it can ship in every package (tools/build.sh copies src/common)", function()
		for _, name in ipairs({ "https", "tlscheck", "mdns" }) do
			local source = read_file("src/common/" .. name .. ".lua")
			assert.is_nil(source:find("require%s*%(?%s*[\"']bridge%."), name)
		end
		package.loaded["common.https"] = nil
		package.preload["bridge.http"] = function() error("common/https.lua loaded bridge.http") end
		local ok, err = pcall(function() return require("common.https").new({ header_key = "x-key" }) end)
		package.preload["bridge.http"] = nil
		assert.is_true(ok, tostring(err))
	end)
end)
