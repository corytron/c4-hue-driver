local fake = require("helpers.fake_c4")
local log = require("common.log")

-- The event stream over a network connection (docs/raw-stream-design.md §0,
-- #317). Director's side is played through the fake: c4.net_status and
-- c4.net_receive reach the stream through env.OnConnectionStatusChanged and
-- env.ReceivedFromNetwork, routed to the current stream object the way the
-- driver's globals are.

local BINDING, PORT = 6001, 443
local IP = "10.0.2.143"
local KEY = "netstream-spec-key" -- a placeholder; it must never reach a log line

-- stream_spec.lua's container, and the two events of sse_spec.lua (the
-- Core Concepts page's light on, then off).
local CONTAINER = '[{"creationtime":"2021-10-18T17:04:55Z","data":[{"id":"e7","on":{"on":true},'
	.. '"owner":{"rid":"3f","rtype":"device"},"type":"light"}],"id":"9d","type":"update"}]'
local ON = '[{"creationtime":"2021-10-18T17:04:55Z","data":[{"id":"e706416a","on":{"on":true},'
	.. '"owner":{"rid":"3f4ac4e9","rtype":"device"},"type":"light"}],"id":"9de116fc","type":"update"}]'
local OFF = '[{"creationtime":"2021-10-18T17:04:59Z","data":[{"id":"e706416a","on":{"on":false},'
	.. '"owner":{"rid":"3f4ac4e9","rtype":"device"},"type":"light"}],"id":"5ebb24e4","type":"update"}]'

-- One complete SSE event carrying CONTAINER.
local function event_text(id)
	return "id: " .. id .. "\ndata: " .. CONTAINER .. "\n\n"
end

-- One chunk of a chunked body (RFC 9112 §7.1), its size in `fmt` ("%x").
local function chunk(data, fmt)
	return string.format(fmt or "%x", #data) .. "\r\n" .. data .. "\r\n"
end

local LAST_CHUNK = "0\r\n\r\n"

local HEAD_200 = table.concat({
	"HTTP/1.1 200 OK",
	"Content-Type: text/event-stream",
	"Transfer-Encoding: chunked",
	"Connection: keep-alive",
	"", "",
}, "\r\n")

-- A bridge answer in the shape the spike recorded (status line, headers,
-- Transfer-Encoding: chunked, SSE text in the chunks): a comment, an event
-- in a chunk of its own, an event split over two chunks, and the second of
-- those carrying the next event too, its size in upper-case hex.
local EV1 = "id: 1634576695:0\ndata: " .. ON .. "\n\n"
local EV2 = "id: 1634576699:0\ndata: " .. OFF .. "\n\n"
local EV3 = event_text("1634576700:0")
local RECORDED = HEAD_200 .. chunk(": hi\n\n") .. chunk(EV1) .. chunk(EV2:sub(1, 40))
	.. chunk(EV2:sub(41) .. EV3, "%X")
local RECORDED_EVENTS = { "1634576695:0", "1634576699:0", "1634576700:0" }
local RECORDED_CONTAINERS = { "9de116fc", "5ebb24e4", "9d" }

-- The request of contract §0.4.
local REQUEST = "GET /eventstream/clip/v2 HTTP/1.1\r\nHost: " .. IP .. "\r\nhue-application-key: " .. KEY
	.. "\r\nAccept: text/event-stream\r\nConnection: keep-alive\r\n\r\n"

local NET_CALLS = { CreateNetworkConnection = true, NetPortOptions = true, NetConnect = true,
	NetDisconnect = true, SendToNetwork = true, SetBindingAddress = true }

describe("bridge.netstream", function()
	local netstream, http, c4, env, seen, s

	local function new_stream(overrides)
		seen = { containers = {}, status = {}, connected = 0, rejected = {} }
		local opts = {
			connection = function() return { ip = IP, key = KEY } end,
			on_container = function(c, ev) table.insert(seen.containers, { c, ev }) end,
			on_status = function(t) table.insert(seen.status, t) end,
			on_connected = function() seen.connected = seen.connected + 1 end,
			on_key_rejected = function(code) table.insert(seen.rejected, code) end,
		}
		for k, v in pairs(overrides or {}) do opts[k] = v end
		return netstream.new(opts)
	end

	-- A fresh runtime whose network callbacks reach the current `s`.
	local function setup()
		log.sink = function() end
		c4, env = fake.install_c4()
		for _, m in ipairs({ "bridge.http", "bridge.sse", "bridge.netstream" }) do
			package.loaded[m] = nil
		end
		netstream = require("bridge.netstream")
		http = require("bridge.http")
		env.OnConnectionStatusChanged = function(b, p, st) s:on_status_changed(b, p, st) end
		env.ReceivedFromNetwork = function(b, _, d) s:on_data(b, d) end
		s = new_stream()
	end

	before_each(setup)

	local function port() return c4.network[BINDING] and c4.network[BINDING].ports[PORT] end
	local function sent() return port() and port().sent or {} end
	local function online() c4.net_status(BINDING, PORT, "ONLINE") end
	local function offline() c4.net_status(BINDING, PORT, "OFFLINE") end
	local function receive(data) c4.net_receive(BINDING, PORT, data) end
	local function count(name) return #c4.calls_to(name) end
	local function last_status() return seen.status[#seen.status] end

	-- The network calls made so far, by name, in order.
	local function net_calls()
		local names = {}
		for _, call in ipairs(c4.calls) do
			if NET_CALLS[call.name] then names[#names + 1] = call.name end
		end
		return names
	end

	local function timer_delays()
		local delays = {}
		for _, timer in ipairs(c4.active_timers()) do
			delays[#delays + 1] = timer.delay
		end
		table.sort(delays)
		return delays
	end

	-- Fire the active timers armed for `delay` ms. Returns how many fired.
	local function fire(delay)
		local fired = 0
		for _, timer in ipairs(c4.active_timers()) do
			if timer.delay == delay then
				timer.active = false
				timer.callback(timer, 0)
				fired = fired + 1
			end
		end
		return fired
	end

	-- Fire the stream's pending retry, whatever its backoff.
	local function retry()
		local timer = assert(s.retry_timer, "a retry is pending")
		assert.is_true(timer.active)
		timer.active = false
		timer.callback(timer, 0)
	end

	local function watchdog_ms() return netstream.DEFAULT_WATCHDOG * 1000 end
	local function connect_ms() return netstream.CONNECT_TIMEOUT * 1000 end

	-- Start, go ONLINE and answer with `head` (a 200 by default).
	local function connect_ok(head)
		s:start()
		online()
		receive(head or HEAD_200)
	end

	local function delivered_ids()
		local events, containers = {}, {}
		for _, d in ipairs(seen.containers) do
			events[#events + 1] = d[2].id
			containers[#containers + 1] = d[1].id
		end
		return events, containers
	end

	describe("connecting", function()
		it("creates the connection, sets its port options and connects, sending nothing before ONLINE", function()
			s:start()
			assert.same({ "CreateNetworkConnection", "NetPortOptions", "NetDisconnect", "NetConnect" }, net_calls())
			assert.same({ BINDING, IP, "SSL" }, c4.calls_to("CreateNetworkConnection")[1])
			local options_call = c4.calls_to("NetPortOptions")[1]
			assert.same({ BINDING, PORT, "SSL" }, { options_call[1], options_call[2], options_call[3] })
			assert.same({ BINDING, PORT }, c4.calls_to("NetConnect")[1])
			assert.equal("connecting", s.state)
			assert.equal("Connecting", last_status())
			assert.equal(IP, s.stats.address)
			assert.same({}, sent(), "nothing before ONLINE")
			assert.same({ connect_ms(), watchdog_ms() }, timer_delays(), "the connect timer and the watchdog")
		end)

		it("sends the contract's request once ONLINE", function()
			s:start()
			online()
			assert.same({ REQUEST }, sent())
			assert.equal("connecting", s.state, "connected only once the answer says 200")
			assert.same({ connect_ms(), watchdog_ms() }, timer_delays(), "the connect timer waits for the answer now")
		end)

		it("sets exactly the port options of the contract: the Signify roots, peer verification", function()
			s:start()
			assert.same({
				CACERTFILE = http.CA_BUNDLE,
				VERIFY_MODE = "peer",
				KEEP_ALIVE = true,
				AUTO_CONNECT = false,
				MONITOR_CONNECTION = false,
				KEEP_CONNECTION = false,
				DELIMITER = "",
				SUPPRESS_CONNECTION_EVENTS = true,
			}, port().options)
			assert.equal("certs/hue_ca_bundle.pem", port().options.CACERTFILE)
			-- A fresh table per call: a caller cannot turn verification off for the next one.
			netstream.port_options().VERIFY_MODE = "none"
			assert.equal("peer", netstream.port_options().VERIFY_MODE)
		end)

		it("is connected on a 200, and defers on_connected to a 1 ms timer", function()
			connect_ok()
			assert.equal("connected", s.state)
			assert.truthy(last_status():find("^Connected since %d%d:%d%d:%d%d$"), last_status())
			assert.equal(0, seen.connected, "not called from inside ReceivedFromNetwork")
			assert.same({ 1, watchdog_ms() }, timer_delays(), "the deferral and the watchdog; no connect timer")
			assert.equal(1, fire(1))
			assert.equal(1, seen.connected)
			assert.same({ watchdog_ms() }, timer_delays())
		end)

		it("does not arm the deferral when no on_connected handler is given", function()
			s = new_stream({ on_connected = false })
			connect_ok()
			assert.same({ watchdog_ms() }, timer_delays())
		end)

		it("does nothing when not paired", function()
			s = new_stream({ connection = function() return nil end })
			s:start()
			assert.same({}, net_calls())
			assert.equal("stopped", s.state)
			assert.equal("Not paired", last_status())
		end)

		it("shows the reason connection() gives when the stream may not connect, and stops", function()
			s = new_stream({ connection = function() return nil, "Not connected: key rejected" end })
			s:start()
			assert.same({}, net_calls())
			assert.equal("stopped", s.state)
			assert.equal("Not connected: key rejected", last_status())
			assert.same({}, timer_delays())
		end)

		it("refuses an address or a key that would break a request line", function()
			s = new_stream({ connection = function() return { ip = IP .. "\r\nX-Injected: 1", key = KEY } end })
			s:start()
			assert.equal("Not connected: invalid bridge address", last_status())
			s = new_stream({ connection = function() return { ip = IP, key = "abc\r\nX-Injected: 1" } end })
			s:start()
			assert.equal("Not connected: invalid application key", last_status())
			assert.equal("stopped", s.state)
			assert.same({}, net_calls())
			assert.same({}, timer_delays())
		end)

		it("never connects without a CA configuration", function()
			http.ca = nil
			assert.is_nil(netstream.port_options())
			s:start()
			assert.equal(0, count("NetConnect"))
			assert.equal("waiting", s.state)
			assert.equal("Disconnected: no CA configuration. Reconnecting in 1 s", last_status())
			assert.same({ 1000 }, timer_delays(), "only the retry timer")
		end)

		it("takes a C4 call that raises for a failed connect", function()
			c4.CreateNetworkConnection = function() error("no such binding type") end
			s:start()
			assert.equal("waiting", s.state)
			assert.truthy(s.stats.last_error:find("^could not open the network connection: .*no such binding type"))
			assert.same({ 1000 }, timer_delays())
		end)

		it("copes with Director reporting from inside NetConnect", function()
			local real = c4.NetConnect
			c4.NetConnect = function(c, ...) real(c, ...) online() end
			s:start()
			assert.same({ REQUEST }, sent())
			assert.same({ connect_ms(), watchdog_ms() }, timer_delays(), "one timer for the answer, one watchdog")
			receive(HEAD_200)
			assert.equal("connected", s.state)
			offline()
			c4.NetConnect = function(c, ...) real(c, ...) offline() end
			retry()
			assert.equal("could not connect (OFFLINE)", s.stats.last_error)
			assert.same({ 2000 }, timer_delays(), "the retry only: no connect timer left behind")
		end)

		it("start() while connecting or connected changes nothing", function()
			s:start()
			s:start()
			online()
			receive(HEAD_200)
			s:start()
			assert.equal(1, count("NetConnect"))
			assert.equal(1, #sent())
			assert.equal("connected", s.state)
		end)
	end)

	describe("the answer, split anywhere", function()
		-- Run the recorded answer through a new stream in `pieces`; returns
		-- what the owner saw.
		local function run(pieces)
			setup()
			s:start()
			online()
			for _, piece in ipairs(pieces) do
				receive(piece)
			end
			local events, containers = delivered_ids()
			return { state = s.state, events = events, containers = containers, keepalives = s.stats.keepalives,
				count = s.stats.events, reconnects = s.stats.reconnects, error = s.stats.last_error }
		end

		local WHOLE = { state = "connected", events = RECORDED_EVENTS, containers = RECORDED_CONTAINERS,
			keepalives = 1, count = 3, reconnects = 0 }

		it("decodes the recorded answer fed whole", function()
			assert.same(WHOLE, run({ RECORDED }))
			assert.equal("update", seen.containers[1][1].type)
			assert.equal("light", seen.containers[1][1].data[1].type)
			assert.is_true(seen.containers[1][1].data[1].on.on)
			assert.is_false(seen.containers[2][1].data[1].on.on)
		end)

		it("decodes the recorded answer split at every position", function()
			for cut = 1, #RECORDED - 1 do
				local got = run({ RECORDED:sub(1, cut), RECORDED:sub(cut + 1) })
				assert.same(WHOLE, got, "cut after byte " .. cut)
			end
		end)

		it("decodes the recorded answer fed one byte at a time", function()
			local pieces = {}
			for i = 1, #RECORDED do pieces[i] = RECORDED:sub(i, i) end
			assert.same(WHOLE, run(pieces))
		end)

		it("takes the head split across calls, and connects once it is complete", function()
			s:start()
			online()
			receive("HTTP/1.1 200 OK\r\nTransfer-Enc")
			assert.equal("connecting", s.state)
			receive("oding: chunked\r\n\r")
			assert.equal("connecting", s.state)
			receive("\n" .. chunk(event_text("1:0")))
			assert.equal("connected", s.state)
			assert.equal(1, #seen.containers)
		end)

		it("takes a chunk-size line split between calls, CR and LF apart too", function()
			connect_ok()
			local body = chunk(event_text("1:0"))
			local size_end = body:find("\r\n", 1, true)
			assert.truthy(size_end > 2, "a size of two hex digits at least")
			receive(body:sub(1, 1))
			receive(body:sub(2, size_end)) -- the rest of the size and its CR
			assert.equal(0, #seen.containers)
			receive(body:sub(size_end + 1, -3)) -- the LF and the data
			assert.equal(1, #seen.containers)
			receive("\r")
			receive("\n" .. chunk(event_text("2:0")))
			assert.equal(2, #seen.containers)
			assert.equal("connected", s.state)
		end)

		it("takes several chunks in one call", function()
			connect_ok()
			receive(chunk(event_text("1:0")) .. chunk(event_text("2:0")) .. chunk(": hi\n\n") .. chunk(event_text("3:0")))
			assert.same({ "1:0", "2:0", "3:0" }, (delivered_ids()))
			assert.equal(1, s.stats.keepalives)
		end)

		it("takes the head and the first chunks in one call", function()
			s:start()
			online()
			receive(HEAD_200 .. chunk(event_text("1:0")) .. chunk(event_text("2:0")))
			assert.equal("connected", s.state)
			assert.equal(2, #seen.containers)
		end)

		it("reads chunk extensions, upper-case sizes and trailers, and reconnects at the end of the body", function()
			connect_ok()
			local data = event_text("1:0")
			receive(string.format("%X;name=value\r\n", #data) .. data .. "\r\n")
			assert.equal(1, #seen.containers)
			receive("0\r\nX-Trailer: 1\r\n")
			assert.equal("connected", s.state, "not over before the blank line")
			receive("\r\n")
			assert.equal("waiting", s.state)
			assert.equal("server closed the stream (HTTP 200)", s.stats.last_error)
			assert.equal("Disconnected: server closed the stream (HTTP 200). Reconnecting in 1 s", last_status())
			assert.equal(2, count("NetDisconnect"), "the one before the connect, and this one")
		end)

		it("reads a body with Content-Length to its length, then reconnects", function()
			local body = event_text("1:0") .. event_text("2:0")
			s:start()
			online()
			receive("HTTP/1.1 200 OK\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body:sub(1, 50))
			assert.equal("connected", s.state)
			receive(body:sub(51))
			assert.equal(2, #seen.containers)
			assert.equal("waiting", s.state)
			assert.equal("server closed the stream (HTTP 200)", s.stats.last_error)
		end)

		it("reads a body with neither chunks nor a length to the end of the connection", function()
			s:start()
			online()
			receive("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" .. event_text("1:0"):sub(1, 30))
			assert.equal("connected", s.state)
			receive(event_text("1:0"):sub(31) .. event_text("2:0"))
			assert.equal(2, #seen.containers)
			assert.equal("connected", s.state)
			local disconnects = count("NetDisconnect")
			offline()
			assert.equal("waiting", s.state)
			assert.equal("server closed the stream (HTTP 200)", s.stats.last_error)
			assert.equal(disconnects, count("NetDisconnect"), "Director closed it: nothing to disconnect")
		end)

		it("skips an interim 100 Continue", function()
			s:start()
			online()
			receive("HTTP/1.1 100 Continue\r\n\r\n")
			assert.equal("connecting", s.state)
			receive(HEAD_200)
			assert.equal("connected", s.state)
		end)

		it("reads LF-only lines and folded headers", function()
			s:start()
			online()
			receive("HTTP/1.1 200 OK\nTransfer-Encoding:\n chunked\n\n" .. chunk(event_text("1:0")))
			assert.equal("connected", s.state)
			assert.equal(1, #seen.containers)
		end)
	end)

	-- Issue #44, as in stream.lua: the house Bridge Pro answers an unknown key
	-- with 403 and an HTML body.
	describe("key rejected (401 or 403)", function()
		for _, code in ipairs({ 401, 403 }) do
			it("stops for good on a " .. code .. ", records it and tells the owner once", function()
				local state_then
				s = new_stream({ on_key_rejected = function(c)
					table.insert(seen.rejected, c)
					state_then = s.state
				end })
				s:start()
				online()
				local html = "<html><body>unauthorized user</body></html>"
				receive(string.format("HTTP/1.1 %d Forbidden\r\nContent-Type: text/html\r\nContent-Length: %d\r\n\r\n%s",
					code, #html, html))
				assert.equal("stopped", s.state)
				assert.is_false(s:running())
				assert.equal("key rejected (HTTP " .. code .. ")", s.stats.last_error)
				assert.equal("Stopped: key rejected (HTTP " .. code .. ")", last_status())
				assert.same({ code }, seen.rejected)
				assert.equal("stopped", state_then, "told after the stream has stopped itself")
				assert.equal(2, count("NetDisconnect"), "the connection is closed")
				assert.same({}, timer_delays(), "no reconnect timer, no watchdog")

				-- What Director still delivers for it changes nothing.
				receive("more")
				offline()
				online()
				assert.equal("stopped", s.state)
				assert.same({ code }, seen.rejected, "once")
				assert.equal(1, count("NetConnect"), "no second attempt with the same key")
				assert.equal(1, #sent())
				assert.equal(0, s.stats.reconnects)
			end)
		end

		it("connects again on start() and reports a new rejection", function()
			s:start()
			online()
			receive("HTTP/1.1 403 Forbidden\r\n\r\n")
			s:start()
			assert.equal(2, count("CreateNetworkConnection"), "created afresh")
			assert.equal("connecting", s.state)
			online()
			receive("HTTP/1.1 403 Forbidden\r\n\r\n")
			assert.same({ 403, 403 }, seen.rejected, "once per rejection")
		end)

		it("stays stopped when the owner's callback raises", function()
			s = new_stream({ on_key_rejected = function() error("boom") end })
			s:start()
			online()
			receive("HTTP/1.1 401 Unauthorized\r\n\r\n")
			assert.equal("stopped", s.state)
			assert.same({}, timer_delays())
		end)
	end)

	describe("reconnecting", function()
		it("reconnects after another status, with a backoff that doubles and resets on a 200", function()
			connect_ok("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n")
			assert.equal("waiting", s.state)
			assert.equal("HTTP 500", s.stats.last_error)
			assert.equal("Disconnected: HTTP 500. Reconnecting in 1 s", last_status())
			assert.equal(2, count("NetDisconnect"))
			assert.same({ 1000 }, timer_delays())
			assert.equal(0, seen.connected)
			offline() -- what Director says about the connection the stream closed

			assert.equal(1, fire(1000))
			assert.equal(2, count("NetConnect"))
			assert.equal(1, count("CreateNetworkConnection"), "the connection is reused within a run")
			online()
			assert.equal(2, #sent())
			receive("HTTP/1.1 503 Service Unavailable\r\n\r\n")
			assert.equal("Disconnected: HTTP 503. Reconnecting in 2 s", last_status())

			assert.equal(1, fire(2000))
			online()
			receive(HEAD_200)
			assert.equal("connected", s.state)
			assert.equal(netstream.BACKOFF_MIN, s.backoff)
		end)

		it("reconnects after OFFLINE, without a disconnect of its own", function()
			connect_ok()
			fire(1)
			local disconnects = count("NetDisconnect")
			offline()
			assert.equal("waiting", s.state)
			assert.equal("connection closed (OFFLINE)", s.stats.last_error)
			assert.equal("Disconnected: connection closed (OFFLINE). Reconnecting in 1 s", last_status())
			assert.equal(disconnects, count("NetDisconnect"))
			assert.same({ 1000 }, timer_delays())
			assert.equal(1, s.stats.reconnects)

			assert.equal(1, fire(1000))
			assert.equal(2, count("NetConnect"))
			online()
			assert.same({ REQUEST, REQUEST }, sent())
			receive(HEAD_200)
			assert.equal(1, fire(1))
			assert.equal(2, seen.connected, "a resync after every connect")
		end)

		it("takes an OFFLINE while connecting for a failed connect, with growing backoff", function()
			connect_ok()
			offline() -- a drop: 1 s
			fire(1000)
			offline() -- the connect fails at once
			assert.equal("could not connect (OFFLINE)", s.stats.last_error)
			assert.equal("Disconnected: could not connect (OFFLINE). Reconnecting in 2 s", last_status())
			fire(2000)
			offline()
			assert.equal("Disconnected: could not connect (OFFLINE). Reconnecting in 4 s", last_status())
		end)

		it("takes an OFFLINE after ONLINE and before the answer for a closed connection", function()
			s:start()
			online()
			offline()
			assert.equal("connection closed before an answer", s.stats.last_error)
			assert.equal("waiting", s.state)
		end)

		it("counts a connect without ONLINE within 10 s as failed", function()
			s:start()
			assert.equal(1, fire(connect_ms()))
			assert.equal("waiting", s.state)
			assert.equal("no connection within 10 s", s.stats.last_error)
			assert.equal("Disconnected: no connection within 10 s. Reconnecting in 1 s", last_status())
			assert.equal(2, count("NetDisconnect"), "the pending connect is disconnected")
			assert.same({ 1000 }, timer_delays(), "the watchdog went with the connection")
			assert.equal(1, fire(1000))
			assert.equal(2, count("NetConnect"))
			online()
			assert.equal(1, #sent())
		end)

		it("counts an answer that has not come 10 s after ONLINE as failed", function()
			s:start()
			online()
			receive("HTTP/1.1 200 OK\r\n") -- half a head
			assert.equal(1, fire(connect_ms()))
			assert.equal("no answer within 10 s", s.stats.last_error)
			assert.equal("waiting", s.state)
		end)

		it("reconnects when the watchdog finds no data for a whole period", function()
			connect_ok()
			assert.equal(1, fire(1))
			assert.same({ watchdog_ms() }, timer_delays())
			assert.equal(1, fire(watchdog_ms()))
			assert.equal("waiting", s.state)
			assert.equal("watchdog: no data for " .. netstream.DEFAULT_WATCHDOG .. " s", s.stats.last_error)
			assert.equal(2, count("NetDisconnect"))
			-- What Director still reports about that connection is ignored.
			receive(chunk(event_text("9:0")))
			offline()
			assert.equal("waiting", s.state)
			assert.equal(0, #seen.containers)
			assert.equal(1, fire(1000))
			assert.equal(2, count("NetConnect"))
		end)

		it("re-arms the watchdog for the rest of the period when an event or keepalive came", function()
			connect_ok()
			fire(1)
			local armed = count("SetTimer")
			c4.now_ms = c4.now_ms + 100 * 1000
			receive(chunk(": hi\n\n"))
			assert.equal(armed, count("SetTimer"), "data does not re-create the timer")
			c4.now_ms = c4.now_ms + (netstream.DEFAULT_WATCHDOG - 100) * 1000
			assert.equal(1, fire(watchdog_ms()))
			assert.equal("connected", s.state)
			assert.same({ 100 * 1000 }, timer_delays(), "re-armed for the remainder")
			c4.now_ms = c4.now_ms + 100 * 1000
			assert.equal(1, fire(100 * 1000))
			assert.equal("waiting", s.state)
		end)

		it("is not fed by bytes that make no event or keepalive", function()
			connect_ok()
			fire(1)
			receive(chunk("\n") .. chunk('data: {"partial'))
			assert.equal(1, fire(watchdog_ms()))
			assert.equal("waiting", s.state)
		end)

		it("watches from the connect: a connection that never answers is restarted too", function()
			s:start()
			online()
			-- The connect timer is the one that ends it first.
			assert.same({ connect_ms(), watchdog_ms() }, timer_delays())
			assert.equal(1, fire(watchdog_ms()))
			assert.equal("waiting", s.state)
			assert.same({ 1000 }, timer_delays())
		end)
	end)

	describe("stopping", function()
		it("stop() while connecting disconnects, leaves no timer, and ignores what Director reports later", function()
			s:start()
			s:stop()
			assert.equal("stopped", s.state)
			assert.equal("Stopped", last_status())
			assert.equal(2, count("NetDisconnect"), "the pending connect is disconnected")
			assert.same({}, timer_delays())
			online()
			offline()
			receive(HEAD_200)
			assert.same({}, sent(), "no request for a stopped stream")
			assert.equal("stopped", s.state)
			assert.equal(0, seen.connected)
		end)

		it("stop() while connected disconnects and drops on_connected", function()
			connect_ok()
			s:stop()
			assert.equal(2, count("NetDisconnect"))
			assert.same({}, timer_delays(), "no deferral, no watchdog")
			assert.is_nil(s.stats.connected_since)
			receive(chunk(event_text("1:0")))
			assert.equal(0, #seen.containers)
		end)

		it("a stale on_connected timer does nothing", function()
			connect_ok()
			local deferral
			for _, timer in ipairs(c4.active_timers()) do
				if timer.delay == 1 then deferral = timer end
			end
			s:stop()
			assert.is_false(deferral.active)
			deferral.callback(deferral, 0) -- delivered all the same
			assert.equal(0, seen.connected)
		end)

		it("stop() while waiting leaves no retry timer and makes no call", function()
			connect_ok()
			offline()
			local calls = #net_calls()
			s:stop()
			assert.same({}, timer_delays())
			assert.equal(calls, #net_calls(), "nothing to disconnect")
		end)
	end)

	-- Director's callbacks carry no connection identity (see the header).
	describe("reports about other connections", function()
		it("ignores other bindings", function()
			s:start()
			s:on_status_changed(6002, PORT, "ONLINE")
			assert.same({}, sent())
			online()
			s:on_data(6002, HEAD_200)
			assert.equal("connecting", s.state)
			receive(HEAD_200)
			assert.equal("connected", s.state)
			s:on_status_changed(6002, PORT, "OFFLINE")
			s:on_data(6002, chunk(event_text("1:0")))
			assert.equal("connected", s.state)
			assert.equal(0, #seen.containers)
		end)

		it("ignores data and ONLINE while no connect is pending", function()
			receive(HEAD_200)
			online()
			assert.equal("stopped", s.state)
			s:start()
			receive(HEAD_200) -- before ONLINE
			assert.equal("connecting", s.state)
			online()
			online()
			assert.equal(1, #sent(), "the request goes out once")
		end)

		it("skips the OFFLINE its own disconnect brings, even while the next connect is pending", function()
			connect_ok()
			s:stop()
			s:start()
			offline() -- the connection stop() closed
			offline() -- the disconnect before the new connect
			assert.equal("connecting", s.state)
			online()
			assert.equal(2, #sent())
			receive(HEAD_200)
			assert.equal("connected", s.state)
		end)

		it("skips the OFFLINE of its predecessor's connection on a new object", function()
			connect_ok()
			s:stop()
			s = new_stream() -- the driver's restart_stream
			s:start()
			offline()
			assert.equal("connecting", s.state)
			online()
			receive(HEAD_200)
			assert.equal("connected", s.state)
		end)

		it("catches a failed first connect with the connect timer when its OFFLINE was taken for a leftover", function()
			s:start()
			offline()
			offline()
			assert.equal("connecting", s.state)
			assert.equal(1, fire(connect_ms()))
			assert.equal("waiting", s.state)
		end)
	end)

	describe("the address", function()
		it("moves the connection with SetBindingAddress when the address changes between connects", function()
			local ip = IP
			s = new_stream({ connection = function() return { ip = ip, key = KEY } end })
			connect_ok()
			offline()
			ip = "192.0.2.10"
			assert.equal(1, fire(1000))
			assert.same({ BINDING, "192.0.2.10" }, c4.calls_to("SetBindingAddress")[1])
			local names = net_calls()
			assert.same({ "SetBindingAddress", "NetPortOptions", "NetConnect" }, { names[#names - 2], names[#names - 1],
				names[#names] }, "the address moves before the connect")
			assert.equal(1, count("CreateNetworkConnection"))
			assert.equal("192.0.2.10", c4.network[BINDING].address)
			assert.equal("192.0.2.10", s.stats.address)
			online()
			assert.truthy(sent()[2]:find("\r\nHost: 192.0.2.10\r\n", 1, true))

			-- The same address again: no move.
			offline()
			fire(1000)
			assert.equal(1, count("SetBindingAddress"))
		end)

		it("creates the connection afresh on every start", function()
			local ip = IP
			s = new_stream({ connection = function() return { ip = ip, key = KEY } end })
			connect_ok()
			s:stop()
			ip = "192.0.2.10"
			s:start()
			assert.equal(2, count("CreateNetworkConnection"))
			assert.same({ BINDING, "192.0.2.10", "SSL" }, c4.calls_to("CreateNetworkConnection")[2])
			assert.equal(0, count("SetBindingAddress"))
		end)

		it("uses the dotted address: stream_ip does not apply", function()
			s = new_stream({ connection = function() return { ip = IP, stream_ip = "10.000.002.143", key = KEY } end })
			s:start()
			online()
			assert.equal(IP, c4.calls_to("CreateNetworkConnection")[1][2])
			assert.same({ REQUEST }, sent())
		end)

		it("clears the binding's address for Forget Pairing", function()
			assert.is_true(netstream.clear_address())
			assert.same({ BINDING, "" }, c4.calls_to("SetBindingAddress")[1])
		end)
	end)

	describe("malformed or oversized answers", function()
		it("reconnects on a malformed status line", function()
			s:start()
			online()
			receive("SSH-2.0-OpenSSH\r\n")
			assert.equal("malformed answer: status line", s.stats.last_error)
			assert.equal("waiting", s.state)
		end)

		it("reconnects on a malformed chunk size and keeps the backoff until an event is delivered", function()
			connect_ok()
			receive("zz\r\n")
			assert.equal("malformed answer: chunk size", s.stats.last_error)
			assert.equal("Disconnected: malformed answer: chunk size. Reconnecting in 1 s", last_status())
			fire(1000)
			online()
			receive(HEAD_200)
			assert.equal(2, s.backoff, "the 200 did not reset it")
			receive(chunk(event_text("1:0")))
			assert.equal(netstream.BACKOFF_MIN, s.backoff, "an event delivered normally does")
		end)

		it("reconnects on a chunk longer than its size", function()
			connect_ok()
			receive("2\r\nabc\r\n")
			assert.equal("malformed answer: chunk longer than its size", s.stats.last_error)
		end)

		it("does not count a 200 it cannot decode as connected", function()
			s:start()
			online()
			receive("HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n")
			assert.equal("waiting", s.state)
			assert.equal("malformed answer: unsupported transfer coding", s.stats.last_error)
			assert.same({ 1000 }, timer_delays(), "no on_connected deferral")
			for _, text in ipairs(seen.status) do
				assert.is_nil(text:find("^Connected"), text)
			end
		end)

		it("does not hold more than a line's worth of head", function()
			s:start()
			online()
			receive("HTTP/1.1 200 OK\r\nX-Big: " .. string.rep("x", netstream.MAX_LINE))
			assert.equal("oversized answer head", s.stats.last_error)
			assert.equal("waiting", s.state)
		end)

		it("does not hold more than a line's worth of chunk size", function()
			connect_ok()
			receive(string.rep("0", netstream.MAX_LINE + 1))
			assert.equal("oversized line in stream", s.stats.last_error)
		end)

		it("reconnects on an oversized SSE line, as stream.lua does", function()
			connect_ok()
			receive(chunk(string.rep("x", require("bridge.sse").MAX_LINE + 1)))
			assert.equal("oversized line in stream", s.stats.last_error)
			assert.equal("waiting", s.state)
			assert.is_true(s.hold_backoff)
		end)
	end)

	-- Security review 2026-10-25, finding 6, as in stream.lua.
	describe("an event the owner cannot handle", function()
		local lines

		before_each(function()
			lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
		end)

		it("costs that event only: the rest of the read is delivered, with one warning", function()
			s = new_stream({ on_container = function(c, ev)
				if ev.id ~= "3:0" then error("owner bug") end
				table.insert(seen.containers, { c, ev })
			end })
			connect_ok()
			receive(chunk(event_text("1:0")) .. chunk(event_text("2:0") .. event_text("3:0")))
			assert.equal(1, #seen.containers)
			assert.equal("3:0", seen.containers[1][2].id)
			assert.equal("connected", s.state)
			local warned = {}
			for _, line in ipairs(lines) do
				if line:find("^%[WARN%]") then warned[#warned + 1] = line end
			end
			assert.equal(1, #warned, "one warning per read")
			assert.truthy(warned[1]:find("2 of 3 event(s)", 1, true), warned[1])
		end)

		it("ends the read once an owner callback has stopped the stream", function()
			s = new_stream({ on_container = function(c, ev)
				table.insert(seen.containers, { c, ev })
				s:stop()
			end })
			connect_ok()
			receive(chunk(event_text("1:0")) .. chunk(event_text("2:0")) .. LAST_CHUNK)
			assert.equal(1, #seen.containers, "nothing after the stop")
			assert.equal("stopped", s.state)
			assert.equal("Stopped", last_status(), "the end of the body after it is not read")
			assert.same({}, timer_delays())
		end)

		it("skips containers that are not objects and events that do not decode", function()
			connect_ok()
			receive(chunk("data: not json\n\n") .. chunk('id: 2:0\ndata: [1, {"type":"update","id":"9e"}]\n\n'))
			assert.equal(1, #seen.containers)
			assert.equal(2, s.stats.events)
			assert.equal(1, s.stats.containers)
			assert.truthy(last_status():find("^Connected since .*, 1 containers, last "), last_status())
		end)
	end)

	-- Issue #65, as in stream.lua: the reconnect counter and the first connect.
	describe("stats", function()
		it("has stream.lua's fields, the clock of the first connect kept across reconnects", function()
			local real_date = os.date
			local clock_text = "23:11:46"
			rawset(os, "date", function(fmt, ...)
				if fmt == "%H:%M:%S" then return clock_text end
				return real_date(fmt, ...)
			end)
			finally(function() rawset(os, "date", real_date) end)

			assert.same({ containers = 0, events = 0, keepalives = 0, reconnects = 0 }, s.stats)
			s:start()
			assert.is_nil(s.stats.started, "not before the stream is up")
			assert.equal(IP, s.stats.address)
			online()
			receive(RECORDED)
			assert.same({ containers = 3, events = 3, keepalives = 1, reconnects = 0, last_event = "23:11:46",
				connected_since = "23:11:46", started = "23:11:46", address = IP }, s.stats)

			clock_text = "23:40:02"
			offline()
			assert.same({ containers = 3, events = 3, keepalives = 1, reconnects = 1, last_event = "23:11:46",
				started = "23:11:46", address = IP, last_error = "connection closed (OFFLINE)" }, s.stats)
			fire(1000)
			online()
			receive(HEAD_200)
			assert.equal("23:40:02", s.stats.connected_since)
			assert.equal("23:11:46", s.stats.started, "kept across reconnects")

			s:stop()
			s:start()
			online()
			receive(HEAD_200)
			assert.equal("23:11:46", s.stats.started, "and across a stop and a start")
			assert.equal(1, s.stats.reconnects, "a stop and a start is not a reconnect")
		end)
	end)

	describe("the application key", function()
		it("never appears in a log line or a status text, Debug Mode on", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			log.set_debug(true)
			finally(function() log.set_debug(false) end)

			connect_ok()
			fire(1)
			receive(RECORDED:sub(#HEAD_200 + 1))
			offline()
			retry()
			online()
			receive("HTTP/1.1 500 Internal Server Error\r\n\r\n")
			retry()
			online()
			receive("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")
			retry()
			-- A send that fails with an error quoting what it was given.
			local real_send = c4.SendToNetwork
			c4.SendToNetwork = function(_, _, _, data) error("could not send " .. data) end
			online()
			c4.SendToNetwork = real_send
			assert.truthy(s.stats.last_error:find("could not send the request: ", 1, true), s.stats.last_error)
			assert.truthy(s.stats.last_error:find("<key>", 1, true), "the key replaced")
			retry()
			assert.equal(1, fire(connect_ms()), "no ONLINE: the connect timer")
			retry()
			online()
			receive("HTTP/1.1 403 Forbidden\r\n\r\n")
			assert.equal("stopped", s.state)

			assert.truthy(#lines > 20, "the scenario logged")
			for _, line in ipairs(lines) do
				assert.is_nil(line:find(KEY, 1, true), line)
			end
			for _, text in ipairs(seen.status) do
				assert.is_nil(text:find(KEY, 1, true), text)
			end
			assert.is_nil(tostring(s.stats.last_error):find(KEY, 1, true))
		end)
	end)
end)
