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

	it("delivers each container as chunks arrive and arms the watchdog", function()
		s:start()
		local t = open_ok()
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
		c4.fire_timers() -- the watchdog
		assert.is_true(t.cancelled)
		assert.equal("waiting", s.state)
		assert.truthy(s.stats.last_error:find("watchdog", 1, true))
		-- A late callback from the abandoned transfer is ignored.
		t:done(0, nil)
		assert.equal("waiting", s.state)
	end)

	it("stop() cancels the transfer and does not reconnect", function()
		s:start()
		local t = open_ok()
		s:stop()
		assert.is_true(t.cancelled)
		assert.equal("stopped", s.state)
		t:done(-1, nil)
		assert.equal(0, c4.fire_timers())
		assert.equal(1, #c4.transfers)
		assert.equal("Stopped", seen.status[#seen.status])
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
end)
