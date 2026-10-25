local fake = require("helpers.fake_c4")
local log = require("common.log")

describe("bridge.http", function()
	local http, c4

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		package.loaded["bridge.http"] = nil
		http = require("bridge.http")
	end)

	it("verifies the peer against the bundle shipped in the archive, not the hostname", function()
		http.request({ ip = "192.0.2.10", path = "/clip/v2/resource/bridge", key = "k" }, function() end)
		local t = c4.last_transfer()
		assert.is_true(t.options.ssl_verify_peer)
		assert.is_false(t.options.ssl_verify_host)
		assert.equal("certs/hue_ca_bundle.pem", t.options.ssl_cabundle)
		assert.is_nil(t.options.ssl_cacerts)
		assert.is_false(t.options.fail_on_error)
	end)

	it("fails fast when no CA configuration is set", function()
		http.ca = nil
		local got
		local t = http.request({ ip = "192.0.2.10", path = "/x" }, function(r) got = r end)
		assert.is_nil(t)
		assert.is_false(got.ok)
		assert.equal("no CA configuration", got.err)
		assert.equal(0, #c4.transfers)
	end)

	it("knows no other TLS configuration than the bundle; req.tls adjusts it and nothing else", function()
		-- No keyed request passes req.tls (bridge_request clears it); the dev
		-- diagnostics and the TLS self-check do. Given, it is applied on top
		-- of the bundle's options; ssl_cabundle = false leaves the platform's CAs.
		http.request({ ip = "example.com", path = "/", timeout = 7,
			tls = { ssl_verify_peer = true, ssl_verify_host = true, ssl_cabundle = false } }, function() end)
		local t = c4.last_transfer()
		assert.is_true(t.options.ssl_verify_peer)
		assert.is_true(t.options.ssl_verify_host)
		assert.is_nil(t.options.ssl_cabundle, "false leaves the option out")
		assert.equal(7, t.options.timeout)
		assert.is_false(t.options.fail_on_error)
		assert.is_nil(http.set_ca, "the CA modes of earlier builds are gone")
		assert.is_nil(http.describe_ca)
	end)

	-- docs/reviews/diff-review-2026-10-24.md row 6: a partial tls table used
	-- to replace the ssl options wholesale and send no ssl_verify_peer.
	it("applies tls on top of the bundle's options, so an empty table keeps the peer verified", function()
		http.request({ ip = "192.0.2.10", path = "/x", tls = {} }, function() end)
		local t = c4.last_transfer()
		assert.is_true(t.options.ssl_verify_peer)
		assert.is_false(t.options.ssl_verify_host)
		assert.equal("certs/hue_ca_bundle.pem", t.options.ssl_cabundle)

		c4.tls_ignores_cabundle = true -- keep the fake from failing the decoy request by itself
		http.request({ ip = "192.0.2.10", path = "/x", tls = { ssl_cabundle = "certs/decoy_ca.pem" } }, function() end)
		t = c4.last_transfer()
		assert.is_true(t.options.ssl_verify_peer, "only what tls names changes")
		assert.is_false(t.options.ssl_verify_host)
		assert.equal("certs/decoy_ca.pem", t.options.ssl_cabundle)

		http.request({ ip = "192.0.2.7:8443", path = "/x", tls = { ssl_verify_peer = false } }, function() end)
		assert.is_false(c4.last_transfer().options.ssl_verify_peer, "turned off only when tls says so")

		assert.same({ fail_on_error = false, timeout = 9, connect_timeout = http.CONNECT_TIMEOUT,
			ssl_verify_peer = true, ssl_verify_host = false, ssl_cabundle = "certs/hue_ca_bundle.pem" },
			http.options({ timeout = 9 }, {}), "http.options itself")
	end)

	it("tells a certificate failure from every other failure", function()
		local function result_of(drive)
			local got
			http.request({ ip = "192.0.2.10", path = "/x" }, function(r) got = r end)
			drive(c4.last_transfer())
			return got
		end
		local refused = result_of(function(t)
			t:done(60, "SSL certificate problem: unable to get local issuer certificate")
		end)
		assert.equal(60, refused.err_code)
		assert.is_true(http.certificate_failure(refused))
		assert.is_true(http.certificate_failure(result_of(function(t)
			t:done(51, "SSL peer certificate or SSH remote key was not OK") end)), "curl before 7.62")

		for _, other in ipairs({
			{ 28, "Timeout was reached" }, { 7, "Failed to connect" }, { 6, "Couldn't resolve host name" },
			{ 77, "Problem with the SSL CA cert (path? access rights?)" }, { 35, "SSL connect error" },
		}) do
			local r = result_of(function(t) t:done(other[1], other[2]) end)
			assert.equal(other[1], r.err_code)
			assert.is_false(http.certificate_failure(r), other[2])
		end
		local answered = result_of(function(t) t:respond(200, "{}") end)
		assert.is_nil(answered.err_code)
		assert.is_false(http.certificate_failure(answered), "an HTTP answer is no transfer failure")
		assert.is_false(http.certificate_failure(result_of(function(t) t:respond(403, "<html>") end)))
		assert.is_false(http.certificate_failure({ ok = false, err = "could not start transfer: x" }))
		assert.is_false(http.certificate_failure(nil))
	end)

	it("logs a quiet request's failure at debug, not as a warning", function()
		local lines = {}
		log.set_debug(false)
		log.sink = function(line) lines[#lines + 1] = line end
		http.request({ ip = "192.0.2.10", path = "/quiet", quiet = true }, function() end)
		c4.last_transfer():done(60, "SSL certificate problem")
		http.request({ ip = "192.0.2.10", path = "/loud" }, function() end)
		c4.last_transfer():done(60, "SSL certificate problem")
		assert.equal(1, #lines, "Debug Mode is off: nothing for the quiet one")
		assert.truthy(lines[1]:find("^%[WARN%]"), lines[1])
		assert.truthy(lines[1]:find("GET /loud", 1, true), lines[1])
	end)

	it("turns a Lua error raised at transfer start into a failed result", function()
		local real_url = c4.url
		c4.url = function(self)
			local t = real_url(self)
			t.Get = function() error("Error loading certificate: fopen: No such file or directory") end
			return t
		end
		local got
		local t = http.request({ ip = "192.0.2.10", path = "/x" }, function(r) got = r end)
		assert.is_nil(t)
		assert.is_false(got.ok)
		assert.truthy(got.err:find("could not start transfer", 1, true))
		assert.truthy(got.err:find("Error loading certificate", 1, true))
	end)

	it("sends the application key header and an https URL", function()
		http.request({ ip = "192.0.2.10", path = "/clip/v2/resource/light", key = "secret" }, function() end)
		local t = c4.last_transfer()
		assert.equal("GET", t.method)
		assert.equal("https://192.0.2.10/clip/v2/resource/light", t.url)
		assert.equal("secret", t.headers["hue-application-key"])
	end)

	it("encodes a POST body as JSON", function()
		http.request({ ip = "192.0.2.10", path = "/api", method = "POST", body = { devicetype = "x" } },
			function() end)
		local t = c4.last_transfer()
		assert.equal("POST", t.method)
		assert.equal("application/json", t.headers["Content-Type"])
		assert.same({ devicetype = "x" }, c4:JsonDecode(t.data))
		assert.is_nil(t.headers["hue-application-key"])
	end)

	it("reports a 2xx response with its decoded JSON", function()
		local got
		http.request({ ip = "192.0.2.10", path = "/x" }, function(r) got = r end)
		c4.last_transfer():respond(200, '{"data":[{"id":"1"}]}')
		assert.is_true(got.ok)
		assert.equal(200, got.code)
		assert.equal("1", got.json.data[1].id)
	end)

	it("reports a 4xx as not ok but still decodes the body", function()
		local got
		http.request({ ip = "192.0.2.10", path = "/x" }, function(r) got = r end)
		c4.last_transfer():respond(403, '{"errors":[{"description":"unauthorized"}]}')
		assert.is_false(got.ok)
		assert.equal("HTTP 403", got.err)
		assert.equal("unauthorized", got.json.errors[1].description)
	end)

	it("reports a transport failure with the curl error", function()
		local got
		http.request({ ip = "192.0.2.10", path = "/x" }, function(r) got = r end)
		c4.last_transfer():done(60, "SSL certificate problem")
		assert.is_false(got.ok)
		assert.is_nil(got.code)
		assert.truthy(got.err:find("SSL certificate problem", 1, true))
	end)

	it("tolerates a non-JSON body", function()
		local got
		http.request({ ip = "192.0.2.10", path = "/x" }, function(r) got = r end)
		c4.last_transfer():respond(200, "<html>")
		assert.is_true(got.ok)
		assert.is_nil(got.json)
	end)

	describe("stream", function()
		it("passes headers, chunks and completion to the handlers", function()
			local seen = { chunks = {} }
			http.stream({ ip = "192.0.2.10", path = "/eventstream/clip/v2", key = "k",
				headers = { Accept = "text/event-stream" }, timeout = 3600 }, {
				on_headers = function(code, headers) seen.code, seen.headers = code, headers end,
				on_chunk = function(data) table.insert(seen.chunks, data) end,
				on_done = function(err_code, err_msg, code) seen.done = { err_code, err_msg, code } end,
			})
			local t = c4.last_transfer()
			assert.equal("text/event-stream", t.headers.Accept)
			assert.equal("k", t.headers["hue-application-key"])
			assert.equal(3600, t.options.timeout)

			t:respond_headers(200, { ["content-type"] = "text/event-stream" })
			t:chunk("id: 1\n")
			t:chunk("data: x\n\n")
			t:done(28, "Operation timed out")

			assert.equal(200, seen.code)
			assert.same({ "id: 1\n", "data: x\n\n" }, seen.chunks)
			assert.same({ 28, "Operation timed out", 200 }, seen.done)
		end)

		it("reports a start failure through on_done with code -2", function()
			local real_url = c4.url
			c4.url = function(self)
				local t = real_url(self)
				t.Get = function() error("Error loading certificate") end
				return t
			end
			local done
			local t = http.stream({ ip = "192.0.2.10", path = "/e" }, {
				on_done = function(code, msg) done = { code, msg } end,
			})
			assert.is_nil(t)
			assert.equal(-2, done[1])
			assert.truthy(done[2]:find("Error loading certificate", 1, true))
		end)

		it("fails through on_done when no CA configuration is set", function()
			http.ca = nil
			local done
			assert.is_nil(http.stream({ ip = "192.0.2.10", path = "/e" }, {
				on_done = function(code, msg) done = { code, msg } end,
			}))
			assert.same({ -2, "no CA configuration" }, done)
		end)

		it("lets on_headers abort the transfer", function()
			http.stream({ ip = "192.0.2.10", path = "/e" }, {
				on_headers = function(code) return code ~= 200 end,
			})
			local t = c4.last_transfer()
			t:respond_headers(401, {})
			assert.is_true(t.cancelled)
		end)
	end)

	it("calls back with ok=false when Director's done carries no responses or a response without a code", function()
		local got
		http.request({ ip = "192.0.2.10", path = "/x" }, function(r) got = r end)
		local t = c4.last_transfer()
		t.callbacks.done(t, nil, 0, nil)
		assert.is_false(got.ok)
		assert.equal("no response", got.err)
		got = nil
		http.request({ ip = "192.0.2.10", path = "/y" }, function(r) got = r end)
		t = c4.last_transfer()
		t.callbacks.done(t, { { body = "x" } }, 0, nil)
		assert.is_false(got.ok)
	end)
end)
