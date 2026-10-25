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
		t:respond_headers(500, {})
		assert.is_true(t.cancelled)
		t:done(-1, nil)
		assert.equal("HTTP 500", s.stats.last_error)
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

	-- Issue #44: the house Bridge Pro answers an unknown key with 403 (an HTML
	-- body); a reconnect would present the same key again.
	describe("key rejected (401 or 403)", function()
		local rejected, state_then

		before_each(function()
			rejected, state_then = {}, nil
			s = new_stream({ on_key_rejected = function(code)
				table.insert(rejected, code)
				state_then = s.state
			end })
		end)

		for _, code in ipairs({ 401, 403 }) do
			it("stops for good on a " .. code .. ", records it and tells the owner once", function()
				s:start()
				local t = c4.last_transfer()
				t:respond_headers(code, { ["content-type"] = "text/html" })
				assert.is_true(t.cancelled, "the callback returned true: the transfer is aborted")
				assert.equal("stopped", s.state)
				assert.is_false(s:running())
				assert.equal("key rejected (HTTP " .. code .. ")", s.stats.last_error)
				assert.equal("Stopped: key rejected (HTTP " .. code .. ")", seen.status[#seen.status])
				assert.same({ code }, rejected)
				assert.equal("stopped", state_then, "told after the stream has stopped itself")
				assert.same({}, timer_delays(), "no reconnect timer, no watchdog")

				-- What Director still delivers for the aborted transfer changes nothing.
				t.cancelled = false
				t:chunk("<html><body>unauthorized user</body></html>")
				t:done(-1, nil)
				assert.equal("stopped", s.state)
				assert.same({ code }, rejected, "once")
				assert.equal(0, c4.fire_timers())
				assert.equal(1, #c4.transfers, "no second attempt with the same key")
				assert.equal(0, s.stats.reconnects)
			end)
		end

		it("still reconnects on any other refusal", function()
			for _, code in ipairs({ 404, 500, 503 }) do
				s = new_stream({ on_key_rejected = function(c) table.insert(rejected, c) end })
				s:start()
				local t = c4.last_transfer()
				t:respond_headers(code, {})
				t:done(-1, nil)
				assert.equal("waiting", s.state, "HTTP " .. code)
				assert.equal("HTTP " .. code, s.stats.last_error)
				assert.truthy(seen.status[#seen.status]:find("Reconnecting in", 1, true))
				s:stop()
			end
			assert.same({}, rejected)
		end)

		it("connects again on start() (after the owner pairs again) and reports a new rejection", function()
			s:start()
			c4.last_transfer():respond_headers(403, {})
			s:start()
			assert.equal(2, #c4.transfers)
			assert.equal("connecting", s.state)
			c4.last_transfer():respond_headers(403, {})
			assert.same({ 403, 403 }, rejected, "once per rejection")
		end)

		it("aborts the transfer even when the owner's callback raises", function()
			s = new_stream({ on_key_rejected = function() error("boom") end })
			s:start()
			local t = c4.last_transfer()
			t:respond_headers(403, {})
			assert.is_true(t.cancelled)
			assert.equal("stopped", s.state)
		end)

		it("is not reported for an abandoned transfer", function()
			s:start()
			local t = c4.last_transfer()
			s:drop_transfer()
			s:schedule_reconnect()
			t:respond_headers(403, {})
			assert.is_true(t.cancelled)
			assert.same({}, rejected)
			assert.equal("waiting", s.state)
		end)
	end)

	-- Code analysis 2026-10-22, L1: an abandoned transfer's last chunk reaches
	-- the owner at most once.
	describe("an abandoned transfer's last chunk", function()
		local function event(id)
			return "id: " .. id .. "\ndata: " .. CONTAINER .. "\n\n"
		end

		-- A connected stream whose transfer is abandoned (as by the watchdog)
		-- and replaced; Cancel() had no effect on the old one. Returns the old
		-- transfer and the replacement (nil while waiting).
		local function abandon(connect_replacement)
			s:start()
			local old = open_ok()
			fire_deferrals()
			s:drop_transfer()
			s:schedule_reconnect()
			old.cancelled = false
			local new
			if connect_replacement then
				assert.equal(1, c4.fire_timers(), "the retry timer")
				new = c4.last_transfer()
				assert.are_not.equal(old, new)
			end
			return old, new
		end

		it("is delivered once while the stream waits, and nothing after it", function()
			local old = abandon(false)
			assert.equal("waiting", s.state)
			local statuses = #seen.status
			old:chunk(event("9:0"))
			assert.is_true(old.cancelled, "aborted")
			assert.equal(1, #seen.containers)
			assert.equal(1, s.stats.containers, "counted, since the owner got it")
			assert.equal(statuses, #seen.status, "no per-event text while not connected (it read 'Connected since nil')")

			old.cancelled = false -- Director ignored the abort
			old:chunk(event("10:0"))
			assert.is_true(old.cancelled)
			assert.equal(1, #seen.containers, "only the last chunk, once")
		end)

		it("is skipped while the replacement is connected, which carries the same events", function()
			local old, new = abandon(true)
			new:respond_headers(200, {})
			assert.equal("connected", s.state)
			local statuses = #seen.status
			old:chunk(event("9:0"))
			assert.is_true(old.cancelled)
			assert.equal(0, #seen.containers)
			assert.equal(0, s.stats.events)
			assert.equal(statuses, #seen.status)

			new:chunk(event("9:0"))
			assert.equal(1, #seen.containers, "delivered by the replacement, once")
		end)

		it("is not delivered again by the replacement when it reached the bridge first", function()
			local old, new = abandon(true)
			assert.equal("connecting", s.state)
			old:chunk(event("9:0"))
			assert.equal(1, #seen.containers, "delivered while the replacement connects")

			new:respond_headers(200, {})
			new:chunk(event("9:0") .. event("10:0"))
			assert.equal(2, #seen.containers)
			assert.equal("10:0", seen.containers[2][2].id, "9:0 skipped, 10:0 delivered")
			new:chunk(event("11:0"))
			assert.equal(3, #seen.containers)
		end)

		it("from two abandoned transfers is delivered once", function()
			s:start()
			local first = open_ok()
			s:drop_transfer()
			s:schedule_reconnect()
			c4.fire_timers() -- reconnect
			local second = open_ok()
			s:drop_transfer()
			s:schedule_reconnect()
			assert.equal("waiting", s.state)
			first.cancelled, second.cancelled = false, false
			first:chunk(event("9:0"))
			second:chunk(event("9:0"))
			assert.equal(1, #seen.containers)
			assert.is_true(second.cancelled)
		end)

		it("is dropped once the stream is stopped", function()
			local old = abandon(false)
			s:stop()
			old:chunk(event("9:0"))
			assert.equal(0, #seen.containers)
		end)
	end)

	-- Code analysis 2026-10-22, L3: the watchdog runs from the connect, and
	-- only events and keepalives count as signs of life.
	describe("watchdog from the connect", function()
		it("restarts a transfer that never answers", function()
			s:start()
			local t = c4.last_transfer()
			assert.equal("connecting", s.state)
			assert.same({ stream.DEFAULT_WATCHDOG * 1000 }, timer_delays(), "armed at connect")
			assert.equal(1, c4.fire_timers())
			assert.is_true(t.cancelled)
			assert.equal("waiting", s.state)
			assert.truthy(s.stats.last_error:find("no data for " .. stream.DEFAULT_WATCHDOG .. " s", 1, true))

			-- Headers arriving late on the abandoned transfer are refused.
			t.cancelled = false
			t:respond_headers(200, {})
			assert.is_true(t.cancelled)
			assert.equal("waiting", s.state)
		end)

		it("restarts a connected stream whose chunks carry no event and no keepalive", function()
			s:start()
			local t = open_ok()
			fire_deferrals()
			assert.same({ stream.DEFAULT_WATCHDOG * 1000 }, timer_delays(), "re-armed for a full period at the headers")
			c4.now_ms = c4.now_ms + 100 * 1000
			t:chunk("\n")                   -- a blank line: no event
			t:chunk('data: {"partial')      -- an event that never completes
			c4.now_ms = c4.now_ms + (stream.DEFAULT_WATCHDOG - 100) * 1000
			assert.equal(1, c4.fire_timers())
			assert.is_true(t.cancelled, "not fed: restarted at the end of the period")
			assert.equal("waiting", s.state)
			assert.equal(0, #seen.containers)
		end)

		it("is fed by an event", function()
			s:start()
			local t = open_ok()
			fire_deferrals()
			c4.now_ms = c4.now_ms + 100 * 1000
			t:chunk("id: 1:0\ndata: " .. CONTAINER .. "\n\n")
			c4.now_ms = c4.now_ms + (stream.DEFAULT_WATCHDOG - 100) * 1000
			assert.equal(1, c4.fire_timers())
			assert.equal("connected", s.state)
			assert.same({ 100 * 1000 }, timer_delays(), "re-armed for what remains after the event")
		end)

		it("leaves no watchdog behind when the transfer cannot start", function()
			require("bridge.http").ca = nil -- http.stream fails at once (on_done -2)
			s:start()
			assert.equal("waiting", s.state)
			assert.same({ stream.BACKOFF_MIN * 1000 }, timer_delays(), "only the retry timer")
		end)
	end)

	-- Issue #65: the reconnect counter and the first connect, in every build.
	describe("stats", function()
		it("keep the clock of the first connect across reconnects and count the reconnects", function()
			local real_date = os.date
			local clock_text = "23:11:46"
			rawset(os, "date", function(fmt, ...)
				if fmt == "%H:%M:%S" then
					return clock_text
				end
				return real_date(fmt, ...)
			end)
			finally(function() rawset(os, "date", real_date) end)

			assert.is_nil(s.stats.started)
			assert.equal(0, s.stats.reconnects)
			s:start()
			assert.is_nil(s.stats.started, "not before the stream is up")
			open_ok()
			fire_deferrals()
			assert.equal("23:11:46", s.stats.started)
			assert.equal("23:11:46", s.stats.connected_since)

			clock_text = "23:40:02"
			c4.last_transfer():done(28, "Operation timed out")
			assert.equal(1, s.stats.reconnects)
			assert.equal(1, c4.fire_timers(), "the retry timer")
			open_ok()
			assert.equal("23:40:02", s.stats.connected_since)
			assert.equal("23:11:46", s.stats.started, "kept across reconnects")

			s:stop()
			s:start()
			open_ok()
			assert.equal("23:11:46", s.stats.started, "and across a stop and a start")
			assert.equal(1, s.stats.reconnects, "a stop and a start is not a reconnect")
		end)
	end)

	-- Director runs at most four C4:url transfers at once (verified
	-- 2026-10-25); an abandoned stream transfer stays open until its next
	-- callback or its own timeout, so the watchdog opens no new transfer while
	-- an earlier abandoned one may still be open.
	describe("abandoned transfers and the watchdog", function()
		local function watchdog_reconnect()
			assert.equal(1, c4.fire_timers(), "the watchdog fires")
			assert.equal(1, c4.fire_timers(), "the retry timer reconnects")
		end

		it("does not open a third transfer while the one the last watchdog abandoned may be open", function()
			s:start()
			open_ok()
			fire_deferrals()
			watchdog_reconnect()
			assert.equal(2, #c4.transfers)
			assert.equal(1, s:open_abandoned())
			open_ok()
			fire_deferrals()
			c4.now_ms = c4.now_ms + stream.DEFAULT_WATCHDOG * 1000
			assert.equal(1, c4.fire_timers(), "the watchdog fires again")
			assert.equal(2, #c4.transfers, "no new transfer")
			assert.equal("connected", s.state, "the current transfer is kept")
			assert.same({ stream.DEFAULT_WATCHDOG * 1000 }, timer_delays(), "the watchdog is armed again")
		end)

		it("reconnects again once the abandoned transfer called back", function()
			s:start()
			local first = open_ok()
			fire_deferrals()
			watchdog_reconnect()
			open_ok()
			fire_deferrals()
			-- Its next callback aborts it (the fake keeps a cancelled transfer
			-- silent, so its end stands for that callback).
			first:done(-1, "aborted")
			assert.equal(0, s:open_abandoned())
			c4.now_ms = c4.now_ms + stream.DEFAULT_WATCHDOG * 1000
			watchdog_reconnect()
			assert.equal(3, #c4.transfers)
		end)

		it("reconnects again once the abandoned transfer's own timeout has passed", function()
			s:start()
			open_ok()
			fire_deferrals()
			watchdog_reconnect()
			open_ok()
			fire_deferrals()
			c4.now_ms = c4.now_ms + stream.DEFAULT_TIMEOUT * 1000
			assert.equal(0, s:open_abandoned())
			watchdog_reconnect()
			assert.equal(3, #c4.transfers)
		end)

		it("counts a transfer that ended on its own as closed", function()
			s:start()
			open_ok()
			fire_deferrals()
			c4.last_transfer():done(28, "Operation timed out")
			assert.equal(0, s:open_abandoned())
		end)

		it("shares the list between stream objects the driver rebuilds", function()
			local shared = {}
			s = new_stream({ abandoned = shared })
			s:start()
			open_ok()
			fire_deferrals()
			s:stop()
			assert.equal(1, #shared, "a stop abandons the open transfer too")
			local s2 = new_stream({ abandoned = shared })
			s2:start()
			open_ok()
			fire_deferrals()
			c4.now_ms = c4.now_ms + stream.DEFAULT_WATCHDOG * 1000
			assert.equal(1, c4.fire_timers(), "the new stream's watchdog")
			assert.equal(2, #c4.transfers, "it opens nothing while the first object's transfer may be open")
		end)
	end)
end)
