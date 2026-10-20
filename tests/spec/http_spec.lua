local fake = require("helpers.fake_c4")
local log = require("common.log")

describe("bridge.http", function()
	local http, c4

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		package.loaded["bridge.http"] = nil
		http = require("bridge.http")
		http.set_ca_bundle("/control4/drivers/lua/sandbox/15/hue_ca_bundle.pem")
	end)

	it("verifies the peer against the installed Signify bundle, not the hostname", function()
		http.request({ ip = "192.0.2.10", path = "/clip/v2/resource/bridge", key = "k" }, function() end)
		local t = c4.last_transfer()
		assert.is_true(t.options.ssl_verify_peer)
		assert.is_false(t.options.ssl_verify_host)
		assert.equal("/control4/drivers/lua/sandbox/15/hue_ca_bundle.pem", t.options.ssl_cabundle)
		assert.is_nil(t.options.ssl_cacerts)
		assert.is_false(t.options.fail_on_error)
	end)

	it("fails fast when no CA configuration is set", function()
		http.set_ca_bundle(nil)
		local got
		local t = http.request({ ip = "192.0.2.10", path = "/x" }, function(r) got = r end)
		assert.is_nil(t)
		assert.is_false(got.ok)
		assert.equal("no CA configuration", got.err)
		assert.equal(0, #c4.transfers)
	end)

	it("supports ssl_cacerts and insecure CA descriptions", function()
		http.request({ ip = "192.0.2.10", path = "/x", ca = { mode = "cacerts", paths = { "a.pem", "b.pem" } } },
			function() end)
		local t = c4.last_transfer()
		assert.same({ "a.pem", "b.pem" }, t.options.ssl_cacerts)
		assert.is_nil(t.options.ssl_cabundle)
		assert.is_true(t.options.ssl_verify_peer)

		http.request({ ip = "192.0.2.10", path = "/x", ca = { mode = "insecure" } }, function() end)
		t = c4.last_transfer()
		assert.is_false(t.options.ssl_verify_peer)
		assert.is_nil(t.options.ssl_cabundle)
		assert.is_nil(t.options.ssl_cacerts)
	end)

	it("system mode uses the platform CAs with hostname checking on", function()
		http.request({ ip = "example.com", path = "/", ca = { mode = "system" } }, function() end)
		local t = c4.last_transfer()
		assert.is_true(t.options.ssl_verify_peer)
		assert.is_true(t.options.ssl_verify_host)
		assert.is_nil(t.options.ssl_cabundle)
		assert.is_nil(t.options.ssl_cacerts)
	end)

	it("verify_host can be switched on for any description", function()
		http.request({ ip = "example.com", path = "/", ca = { mode = "cabundle", path = "b.pem", verify_host = true } },
			function() end)
		local t = c4.last_transfer()
		assert.is_true(t.options.ssl_verify_host)
		assert.equal("b.pem", t.options.ssl_cabundle)
	end)

	it("describes CA configurations for logging", function()
		assert.equal("ssl_cabundle=/x/b.pem", http.describe_ca({ mode = "cabundle", path = "/x/b.pem" }))
		assert.equal("ssl_cacerts={a,b}", http.describe_ca({ mode = "cacerts", paths = { "a", "b" } }))
		assert.equal("INSECURE (no verification)", http.describe_ca({ mode = "insecure" }))
		assert.equal("system CAs", http.describe_ca({ mode = "system" }))
		http.set_ca(nil)
		assert.equal("none", http.describe_ca())
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
			http.set_ca(nil)
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
end)
