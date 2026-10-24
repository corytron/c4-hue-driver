local fake = require("helpers.fake_c4")
local log = require("common.log")

local CONTAINER = '[{"creationtime":"2021-10-18T17:04:55Z","data":[{"id":"e7","on":{"on":true},'
	.. '"owner":{"rid":"3f","rtype":"device"},"type":"light"}],"id":"9d","type":"update"}]'

describe("bridge.stream", function()
	local stream, c4, seen, s

	local function new_stream(overrides)
		seen = { containers = {}, status = {}, connected = 0 }
		local opts = {
			connection = function() return { ip = "192.0.2.10", key = "k" } end,
			on_container = function(c, ev) table.insert(seen.containers, { c, ev }) end,
			on_status = function(t) table.insert(seen.status, t) end,
			on_connected = function() seen.connected = seen.connected + 1 end,
		}
		for k, v in pairs(overrides or {}) do opts[k] = v end
		return stream.new(opts)
	end

	local function open_ok()
		local t = c4.last_transfer()
		t:respond_headers(200, { ["content-type"] = "text/event-stream" })
		return t
	end

	-- Fire only the short deferral timers (the 1 ms on_connected hop), leaving
	-- the watchdog and retry timers armed. Returns how many fired.
	local function fire_deferrals()
		local fired = 0
		for _, timer in ipairs(c4.active_timers()) do
			if timer.delay <= 1 then
				timer.active = false
				timer.callback(timer, 0)
				fired = fired + 1
			end
		end
		return fired
	end

	local function timer_delays()
		local delays = {}
		for _, timer in ipairs(c4.active_timers()) do
			delays[#delays + 1] = timer.delay
		end
		table.sort(delays)
		return delays
	end

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		for _, m in ipairs({ "bridge.http", "bridge.sse", "bridge.stream" }) do
			package.loaded[m] = nil
		end
		stream = require("bridge.stream")
		s = new_stream()
	end)

	it("opens the event stream with the key, Accept header and long timeout", function()
		s:start()
		local t = c4.last_transfer()
		assert.equal("https://192.0.2.10/eventstream/clip/v2", t.url)
		assert.equal("text/event-stream", t.headers.Accept)
		assert.equal("k", t.headers["hue-application-key"])
		assert.equal(stream.DEFAULT_TIMEOUT, t.options.timeout)
		assert.equal("connecting", s.state)
	end)

	it("does nothing when not paired", function()
		s = new_stream({ connection = function() return nil end })
		s:start()
		assert.equal(0, #c4.transfers)
		assert.equal("Not paired", seen.status[#seen.status])
	end)

	it("defers on_connected to a 1 ms timer instead of calling it inside OnHeaders", function()
		s:start()
		open_ok()
		assert.equal("connected", s.state)
		assert.equal(0, seen.connected, "not called from inside the headers callback")
		assert.same({ 1, stream.DEFAULT_WATCHDOG * 1000 }, timer_delays(), "1 ms deferral plus the watchdog")

		assert.equal(1, fire_deferrals())
		assert.equal(1, seen.connected)
		assert.same({ stream.DEFAULT_WATCHDOG * 1000 }, timer_delays(), "only the watchdog remains")
	end)

	it("does not arm the deferral when no on_connected handler is given", function()
		s = new_stream({ on_connected = false })
		s:start()
		open_ok()
		assert.same({ stream.DEFAULT_WATCHDOG * 1000 }, timer_delays())
	end)

	it("a stale on_connected timer does nothing after drop_transfer", function()
		s:start()
		local t = open_ok()
		local deferral = c4.active_timers()[2]
		assert.equal(1, deferral.delay)

		s:drop_transfer()
		assert.is_true(t.cancelled)
		assert.is_false(deferral.active, "deferral cancelled with the transfer")
		assert.equal(0, c4.fire_timers(), "no timers left: watchdog and deferral both cancelled")
		assert.equal(0, seen.connected)

		-- Even if the controller delivered the already-cancelled timer, the
		-- generation check keeps on_connected from firing for a dead stream.
		deferral.callback(deferral, 0)
		assert.equal(0, seen.connected)
	end)

	it("drops the on_connected deferral when the stream ends before it fires", function()
		s:start()
		local t = open_ok()
		t:done(0, nil)
		assert.equal("waiting", s.state)
		assert.same({ stream.BACKOFF_MIN * 1000 }, timer_delays(), "only the retry timer is left")
		assert.equal(0, seen.connected)
	end)

	it("delivers each container as chunks arrive and arms the watchdog", function()
		s:start()
		local t = open_ok()
		fire_deferrals()
		assert.equal("connected", s.state)
		assert.equal(1, seen.connected)
		assert.equal(1, #c4.active_timers(), "watchdog armed")

		t:chunk("id: 1:0\ndata: " .. CONTAINER:sub(1, 40))
		assert.equal(0, #seen.containers, "nothing until the event completes")
		t:chunk(CONTAINER:sub(41) .. "\n\n")

		assert.equal(1, #seen.containers)
		assert.equal("update", seen.containers[1][1].type)
		assert.equal("light", seen.containers[1][1].data[1].type)
		assert.equal("1:0", seen.containers[1][2].id)
		assert.equal(1, s.stats.containers)
		assert.truthy(seen.status[#seen.status]:find("1 containers", 1, true))
	end)

	it("counts keepalive comments without emitting containers", function()
		s:start()
		open_ok():chunk(": hi\n\n")
		assert.equal(1, s.stats.keepalives)
		assert.equal(0, #seen.containers)
	end)

	it("reconnects after the transfer ends, with growing backoff", function()
		s:start()
		local t = open_ok()
		fire_deferrals()
		t:done(28, "Operation timed out")

		assert.equal("waiting", s.state)
		assert.truthy(seen.status[#seen.status]:find("Reconnecting in 1 s", 1, true))
		assert.equal(1, c4.fire_timers())
		assert.equal(2, #c4.transfers, "a new transfer was opened")
		assert.equal("connecting", s.state)

		-- Fail again before headers: backoff doubles.
		c4.last_transfer():done(7, "Failed to connect")
		assert.truthy(seen.status[#seen.status]:find("Reconnecting in 2 s", 1, true))
	end)

	it("resets backoff once a connection is established", function()
		s:start()
		c4.last_transfer():done(7, "Failed to connect")
		c4.fire_timers()
		c4.last_transfer():done(7, "Failed to connect")
		c4.fire_timers()
		open_ok()
		assert.equal(stream.BACKOFF_MIN, s.backoff)
	end)

	it("aborts on a non-200 response and reports it", function()
		s:start()
		local t = c4.last_transfer()
		t:respond_headers(401, {})
		assert.is_true(t.cancelled)
		t:done(-1, nil)
		assert.equal("HTTP 401", s.stats.last_error)
		assert.equal("waiting", s.state)
	end)

	it("reconnects when the watchdog fires", function()
		s:start()
		local t = open_ok()
		assert.equal(1, fire_deferrals(), "on_connected delivered first")
		assert.equal(1, c4.fire_timers(), "the watchdog, and nothing else")
		assert.is_true(t.cancelled)
		assert.equal("waiting", s.state)
		assert.truthy(s.stats.last_error:find("watchdog", 1, true))
		-- A late callback from the abandoned transfer is ignored.
		t:done(0, nil)
		assert.equal("waiting", s.state)
	end)

	it("re-arms the watchdog for the rest of the period when a chunk arrived, and reconnects after that", function()
		s:start()
		local t = open_ok()
		fire_deferrals()
		assert.same({ stream.DEFAULT_WATCHDOG * 1000 }, timer_delays(), "one watchdog per connection")
		local armed = c4.calls_to("SetTimer")

		-- A chunk 100 s in: the timer is left alone (no Cancel, no SetTimer).
		c4.now_ms = c4.now_ms + 100 * 1000
		t:chunk(": hi\n\n")
		assert.equal(#armed, #c4.calls_to("SetTimer"), "a chunk does not re-create the timer")
		assert.same({ stream.DEFAULT_WATCHDOG * 1000 }, timer_delays())

		-- It fires at the end of the period: the chunk was 500 s ago, so it is
		-- re-armed for the remaining 100 s instead of reconnecting.
		c4.now_ms = c4.now_ms + (stream.DEFAULT_WATCHDOG - 100) * 1000
		assert.equal(1, c4.fire_timers())
		assert.equal("connected", s.state)
		assert.is_false(t.cancelled)
		assert.same({ 100 * 1000 }, timer_delays(), "re-armed for the remainder")

		-- Nothing more arrives: the remainder elapses and the stream reconnects.
		c4.now_ms = c4.now_ms + 100 * 1000
		assert.equal(1, c4.fire_timers())
		assert.is_true(t.cancelled)
		assert.equal("waiting", s.state)
		assert.truthy(s.stats.last_error:find("no data for " .. stream.DEFAULT_WATCHDOG .. " s", 1, true))
	end)

	it("stop() cancels the transfer and does not reconnect", function()
		s:start()
		local t = open_ok()
		fire_deferrals()
		s:stop()
		assert.is_true(t.cancelled)
		assert.equal("stopped", s.state)
		t:done(-1, nil)
		assert.equal(0, c4.fire_timers())
		assert.equal(1, #c4.transfers)
		assert.equal("Stopped", seen.status[#seen.status])
	end)

	it("stop() before the deferral fires also drops on_connected", function()
		s:start()
		open_ok()
		s:stop()
		assert.equal(0, c4.fire_timers())
		assert.equal(0, seen.connected)
	end)

	it("aborts late callbacks from an abandoned transfer by returning true", function()
		s:start()
		local t = open_ok()
		fire_deferrals()
		s:stop()
		-- Cancel() is unreliable on the controller: pretend it had no effect
		-- and the old transfer keeps delivering. The callback must return true.
		t.cancelled = false
		t:chunk("data: " .. CONTAINER .. "\n\n")
		assert.is_true(t.cancelled, "chunk callback returned true to abort")
		assert.equal(0, #seen.containers, "nothing from the dead stream is delivered")
	end)

	it("start() while connected is a no-op", function()
		s:start()
		open_ok()
		s:start()
		assert.equal(1, #c4.transfers)
	end)

	it("skips undecodable events and keeps going", function()
		s:start()
		local t = open_ok()
		t:chunk("data: not json\n\n")
		t:chunk("data: " .. CONTAINER .. "\n\n")
		assert.equal(1, #seen.containers)
		assert.equal(2, s.stats.events)
	end)
	it("opens the stream on connection.stream_ip when one is given", function()
		s = new_stream({ connection = function() return { ip = "192.0.2.10", stream_ip = "192.000.002.10", key = "k" } end })
		s:start()
		assert.equal("https://192.000.002.10/eventstream/clip/v2", c4.last_transfer().url)
		assert.equal("k", c4.last_transfer().headers["hue-application-key"])
	end)

	it("delivers the events carried by the chunk that aborts an abandoned transfer", function()
		s:start()
		local t = open_ok()
		-- A watchdog-style reconnect: the old transfer is abandoned, not ended.
		s:drop_transfer()
		s:schedule_reconnect()
		t.cancelled = false
		t:chunk("id: 9:0\ndata: " .. CONTAINER .. "\n\n")
		assert.is_true(t.cancelled, "callback returned true to abort")
		assert.equal(1, #seen.containers, "the zombie's last event still reached the owner")
		assert.equal("9:0", seen.containers[1][2].id)
	end)

	it("drops a stopped stream's late events", function()
		s:start()
		local t = open_ok()
		s:stop()
		t.cancelled = false
		t:chunk("id: 9:0\ndata: " .. CONTAINER .. "\n\n")
		assert.is_true(t.cancelled)
		assert.equal(0, #seen.containers)
	end)

	it("asks connection() again on every connect so the owner can rotate the address spelling", function()
		local spellings = { "192.000.002.10", "192.000.02.10", "192.000.2.10" }
		local calls = 0
		s = new_stream({ connection = function()
			calls = calls + 1
			return { ip = "192.0.2.10", stream_ip = spellings[calls], key = "k" }
		end })

		s:start()
		assert.equal("https://192.000.002.10/eventstream/clip/v2", c4.last_transfer().url)
		assert.equal("192.000.002.10", s.stats.address)

		-- A watchdog reconnect: the abandoned transfer stays on its spelling,
		-- the replacement must take the next one.
		open_ok()
		fire_deferrals()
		assert.equal(1, c4.fire_timers(), "the watchdog fires")
		assert.equal("waiting", s.state)
		assert.equal(1, c4.fire_timers(), "the retry timer reconnects")
		assert.equal(2, #c4.transfers)
		assert.equal("https://192.000.02.10/eventstream/clip/v2", c4.last_transfer().url)
		assert.equal("192.000.02.10", s.stats.address)

		-- A transfer that ends on its own moves on too.
		c4.last_transfer():done(28, "Operation timed out")
		assert.equal("waiting", s.state)
		assert.equal(1, c4.fire_timers(), "the retry timer reconnects")
		assert.equal(3, #c4.transfers)
		assert.equal("https://192.000.2.10/eventstream/clip/v2", c4.last_transfer().url)
		assert.equal("192.000.2.10", s.stats.address)
		assert.equal(3, calls, "connection() asked once per connect")
	end)

	it("records the dotted address when no stream_ip is given", function()
		assert.is_nil(s.stats.address, "nothing before the first connect")
		s:start()
		assert.equal("192.0.2.10", s.stats.address)
		assert.equal("https://192.0.2.10/eventstream/clip/v2", c4.last_transfer().url)
	end)
end)
