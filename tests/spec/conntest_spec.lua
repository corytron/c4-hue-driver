local fake = require("helpers.fake_c4")
local log = require("common.log")

describe("bridge.conntest", function()
	local conntest, c4, lines, summary

	local target = {
		name = "diagnostic server", ip = "192.0.2.7:8443",
		stream_path = "/stream", ping_path = "/ping", ca = { mode = "insecure" },
	}

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		for _, m in ipairs({ "bridge.http", "bridge.conntest" }) do
			package.loaded[m] = nil
		end
		conntest = require("bridge.conntest")
		lines, summary = {}, nil
		conntest.run(target, function(line) table.insert(lines, line) end, function(s) summary = s end)
	end)

	it("opens the stream with the target's CA mode and waits for headers before pinging", function()
		local s = c4.transfers[1]
		assert.equal("https://192.0.2.7:8443/stream", s.url)
		assert.is_false(s.options.ssl_verify_peer)
		assert.equal(1, #c4.transfers, "no ping before the stream answers")

		c4.now_ms = c4.now_ms + 120
		s:respond_headers(200, {})
		assert.truthy(lines[2]:find("step 1 stream headers: HTTP 200 in 120 ms", 1, true))
		assert.equal(2, #c4.transfers)
		assert.equal("https://192.0.2.7:8443/ping", c4.transfers[2].url)
		assert.equal(15, c4.transfers[2].options.timeout)
	end)

	it("runs steps 2-4 in order, times each, and cancels the stream at the end", function()
		local s = c4.transfers[1]
		s:respond_headers(200, {})
		s:chunk(": hi\n\n")

		c4.now_ms = c4.now_ms + 15000
		c4.transfers[2]:done(28, "Timeout was reached")
		assert.truthy(lines[#lines]:find("step 2 GET /ping with stream open: FAIL", 1, true))
		assert.truthy(lines[#lines]:find("in 15000 ms", 1, true))

		assert.equal(4, #c4.transfers, "two concurrent pings in flight")
		c4.transfers[3]:respond(200, '{"ok":true}')
		c4.transfers[4]:done(28, "Timeout was reached")
		assert.equal(5, #c4.transfers, "control request started once both pings settled")
		assert.equal("https://example.com/", c4.transfers[5].url)
		assert.is_true(c4.transfers[5].options.ssl_verify_host)

		c4.transfers[5]:respond(200, "<html>")
		assert.is_true(s.cancelled, "stream cancelled at the end")
		assert.is_true(summary.stream_ok)
		assert.is_false(summary.ping_ok)
		assert.equal(1, summary.concurrent_ok)
		assert.is_true(summary.control_ok)
		assert.truthy(summary.lines[#summary.lines]:find("^done in"))
	end)

	it("stops after step 1 when the stream is refused", function()
		c4.transfers[1]:respond_headers(401, {})
		c4.transfers[1]:done(-1, nil)
		assert.is_false(summary.stream_ok)
		assert.equal(1, #c4.transfers)
	end)

	it("reports a stream that fails before any headers", function()
		c4.transfers[1]:done(7, "Failed to connect")
		assert.is_false(summary.stream_ok)
		assert.truthy(lines[2]:find("failed before headers: 7 Failed to connect", 1, true))
	end)

	it("sends the bridge's key and Accept header when the target has them", function()
		c4 = fake.install_c4()
		conntest.run({ name = "bridge", ip = "192.0.2.10", key = "k", stream_path = "/eventstream/clip/v2",
			ping_path = "/clip/v2/resource/bridge", headers = { Accept = "text/event-stream" },
			ca = { mode = "cabundle", path = "certs/hue_ca_bundle.pem" } }, nil, function() end)
		local s = c4.transfers[1]
		assert.equal("k", s.headers["hue-application-key"])
		assert.equal("text/event-stream", s.headers.Accept)
		assert.equal("certs/hue_ca_bundle.pem", s.options.ssl_cabundle)
		s:respond_headers(200, {})
		assert.equal("k", c4.transfers[2].headers["hue-application-key"])
	end)
end)
