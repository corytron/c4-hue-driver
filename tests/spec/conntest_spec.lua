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
		assert.equal("step 1b deferring 1 ms before step 2", lines[3])
		assert.equal(1, #c4.transfers, "step 2 is not started from inside OnHeaders")
		local timers = c4.active_timers()
		assert.equal(1, #timers)
		assert.equal(1, timers[1].delay, "a 1 ms hop out of the headers callback")

		assert.equal(1, c4.fire_timers())
		assert.equal(2, #c4.transfers)
		assert.equal("https://192.0.2.7:8443/ping", c4.transfers[2].url)
		assert.equal(15, c4.transfers[2].options.timeout)
	end)

	it("runs steps 2-4 in order, times each, and aborts the stream at the end", function()
		local s = c4.transfers[1]
		s:respond_headers(200, {})
		s:chunk(": hi\n\n")
		assert.truthy(lines[#lines]:find("stream chunk 6 bytes", 1, true))
		c4.fire_timers() -- the 1 ms deferral starts step 2

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
		assert.is_true(s.cancelled, "Cancel() still requested at the end")
		assert.is_true(summary.stream_ok)
		assert.is_false(summary.ping_ok)
		assert.equal(1, summary.concurrent_ok)
		assert.is_true(summary.control_ok)
		assert.truthy(summary.lines[#summary.lines]:find("^done in"))

		-- On OS 3.4.2 Cancel() does not stop a streaming transfer, so chunks
		-- keep coming. The fake honours Cancel(); undo it to mimic the
		-- controller. The next chunk's callback must return true to abort.
		local before = #lines
		s.cancelled = false
		s:chunk(": still here\n\n")
		assert.is_true(s.cancelled, "chunk callback returned true")
		assert.equal(before + 1, #lines)
		assert.truthy(lines[#lines]:find("^stream aborted on next chunk at %d+ ms$"))

		-- Later chunks are neither logged nor accepted.
		s.cancelled = false
		s:chunk(": and again\n\n")
		assert.is_true(s.cancelled)
		assert.equal(before + 1, #lines, "no chunk logging after finish")
	end)

	it("stops after step 1 when the stream is refused", function()
		c4.transfers[1]:respond_headers(401, {})
		assert.is_true(c4.transfers[1].cancelled, "headers callback returned true to abort")
		c4.transfers[1]:done(-1, nil)
		assert.is_false(summary.stream_ok)
		assert.equal(0, c4.fire_timers(), "no deferred step 2")
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
		c4.fire_timers()
		assert.equal("k", c4.transfers[2].headers["hue-application-key"])
	end)
end)
