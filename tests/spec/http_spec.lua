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

	it("verifies the peer against the bundled Signify roots, not the hostname", function()
		http.request({ ip = "192.0.2.10", path = "/clip/v2/resource/bridge", key = "k" }, function() end)
		local t = c4.last_transfer()
		assert.is_true(t.options.ssl_verify_peer)
		assert.is_false(t.options.ssl_verify_host)
		assert.same({ "certs/hue_root_bridge.pem", "certs/hue_root_ca_01.pem" }, t.options.ssl_cacerts)
		assert.is_false(t.options.fail_on_error)
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
