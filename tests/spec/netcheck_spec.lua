-- Issue #317: the TLS self-check of the network connection
-- (bridge/netcheck.lua). The event stream's GET carries the application key
-- on a network connection that is told to verify the bridge against the
-- Signify roots; nothing yet proved that it does. Before the stream's first
-- keyed connect of a run, a control request over C4:url, then a probe on
-- binding 6002 with a decoy CA file and no key: an HTTP answer on the probe
-- is "not_pinned", the probe going OFFLINE without one is "pinned", anything
-- else "inconclusive". The driver connects the stream on "pinned" (or on an
-- inconclusive answer from a Director version that answered pinned before),
-- falls back to Web transfer for the run on "not_pinned", and otherwise asks
-- again after a backoff, sending nothing keyed on the network connection.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local IP = "10.0.2.143"
local PROBE, STREAM, PORT = 6002, 6001, 443
local KEY = "netcheck-spec-key" -- a placeholder; it must never reach binding 6002
local BRIDGE_ID = "001788fffe123abc"
local CONFIG = '{"name":"Hue Bridge","bridgeid":"001788FFFE123ABC","modelid":"BSB003","swversion":"1968096020",'
	.. '"apiversion":"1.68.0"}'
local CONFIG_URL = "https://" .. IP .. "/api/0/config"
-- What the probe sends on ONLINE: the bridge's public configuration, no key.
local PROBE_REQUEST = "GET /api/0/config HTTP/1.1\r\nHost: " .. IP .. "\r\nConnection: close\r\n\r\n"
-- The bridge's answer, as a peer that accepted the decoy would deliver it.
local HTTP_ANSWER = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #CONFIG
	.. "\r\nConnection: close\r\n\r\n" .. CONFIG
local NET_ATTENTION = "Event stream: the network connection did not verify the bridge's certificate on this "
	.. "controller; using Web transfer (#317)"

-- The SendToNetwork data of one binding, in order.
local function sent_on(c4, binding)
	local out = {}
	for _, args in ipairs(c4.calls_to("SendToNetwork")) do
		if args[1] == binding then
			out[#out + 1] = args[3]
		end
	end
	return out
end

-- The calls of one name made for one binding, in order.
local function calls_on(c4, name, binding)
	local out = {}
	for _, args in ipairs(c4.calls_to(name)) do
		if args[1] == binding then
			out[#out + 1] = args
		end
	end
	return out
end

-- The binding was closed and its address cleared, after `before` calls of each.
local function closed_and_cleared(c4, before)
	before = before or { disconnect = 0, address = 0 }
	local disconnects = calls_on(c4, "NetDisconnect", PROBE)
	local addresses = calls_on(c4, "SetBindingAddress", PROBE)
	return #disconnects > before.disconnect and disconnects[#disconnects][2] == PORT
		and #addresses > before.address and addresses[#addresses][2] == ""
end

describe("bridge.netcheck", function()
	local netcheck, netstream, http, c4, env, verdicts

	before_each(function()
		log.sink = function() end
		c4, env = fake.install_c4()
		for _, m in ipairs({ "bridge.http", "bridge.sse", "bridge.netstream", "bridge.tlscheck", "bridge.netcheck" }) do
			package.loaded[m] = nil
		end
		netcheck = require("bridge.netcheck")
		netstream = require("bridge.netstream")
		http = require("bridge.http")
		-- The driver's globals, as hue_bridge/driver.lua routes them.
		env.OnConnectionStatusChanged = function(b, p, st) netcheck.on_status_changed(b, p, st) end
		env.ReceivedFromNetwork = function(b, _, d) netcheck.on_data(b, d) end
		verdicts = {}
	end)

	local function port() return c4.network[PROBE] and c4.network[PROBE].ports[PORT] end
	local function status(text) c4.net_status(PROBE, PORT, text) end
	local function receive(data) c4.net_receive(PROBE, PORT, data) end
	local function deliver() return c4.fire_timers_of(1) end
	local function timeout() return c4.fire_timers_of(netcheck.TIMEOUT * 1000) end

	local function run(ip)
		netcheck.run(ip or IP, function(v, d) verdicts[#verdicts + 1] = { v, d } end)
	end

	-- Answer the control request (any HTTP status opens the probe).
	local function control(code, body)
		local t = c4.last_transfer()
		assert.truthy(t, "a control request")
		assert.equal(CONFIG_URL, t.url)
		t:respond(code or 200, body or CONFIG)
		return t
	end

	-- A check whose probe connection is opening.
	local function probing()
		run()
		control()
		assert.equal("connecting", port().state)
	end

	-- The one verdict, delivered.
	local function verdict()
		deliver()
		assert.equal(1, #verdicts, "exactly one verdict")
		return verdicts[1][1], verdicts[1][2]
	end

	describe("the control request", function()
		it("asks the bridge's public config over C4:url with the Signify roots and no key, before any probe", function()
			run()
			local t = c4.last_transfer()
			assert.equal("GET", t.method)
			assert.equal(CONFIG_URL, t.url)
			assert.equal(http.CA_BUNDLE, t.options.ssl_cabundle, "the Signify roots, not the decoy")
			assert.is_true(t.options.ssl_verify_peer)
			assert.same({}, t.headers, "no key, no header at all")
			assert.equal(0, #c4.calls_to("CreateNetworkConnection"), "the probe waits for the control's answer")
		end)

		it("opens the probe on any HTTP answer", function()
			run()
			control(404, "")
			assert.same({ PROBE, IP, "SSL" }, c4.calls_to("CreateNetworkConnection")[1])
		end)

		it("is inconclusive without an answer, and then opens nothing and has nothing to close", function()
			run()
			c4.last_transfer():done(7, "Couldn't connect to server")
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.truthy(detail:find("no answer to the control request", 1, true), detail)
			assert.truthy(detail:find("(7)", 1, true), detail)
			assert.is_nil(c4.network[PROBE])
			assert.equal(0, #c4.calls_to("NetDisconnect"))
			assert.equal(0, #c4.calls_to("SetBindingAddress"))
		end)
	end)

	describe("the probe connection", function()
		it("is binding 6002, port 443, SSL, and connects without a disconnect of its own first", function()
			probing()
			local names = {}
			for _, call in ipairs(c4.calls) do
				if call.args[1] == PROBE then names[#names + 1] = call.name end
			end
			assert.same({ "CreateNetworkConnection", "NetPortOptions", "NetConnect" }, names,
				"an OFFLINE of a disconnect of its own would read pinned")
			assert.same({ PROBE, PORT, "SSL" }, { unpack(c4.calls_to("NetPortOptions")[1], 1, 3) })
			assert.same({ PROBE, PORT }, c4.calls_to("NetConnect")[1])
			assert.is_nil(c4.network[STREAM], "nothing on the stream's binding")
		end)

		it("has the stream's port options except the decoy CA file", function()
			probing()
			local expected = netstream.port_options()
			expected.CACERTFILE = "certs/decoy_ca.pem"
			assert.same(expected, port().options)
			assert.equal("peer", port().options.VERIFY_MODE)
			assert.equal(require("bridge.tlscheck").DECOY_CA, netcheck.port_options().CACERTFILE)
			-- A fresh table per call, the stream's untouched.
			netcheck.port_options().VERIFY_MODE = "none"
			assert.equal("peer", netcheck.port_options().VERIFY_MODE)
			assert.equal(http.CA_BUNDLE, netstream.port_options().CACERTFILE)
		end)

		it("sends nothing before ONLINE, then the bridge's public config request with no key", function()
			probing()
			assert.same({}, port().sent)
			status("ONLINE")
			assert.same({ PROBE_REQUEST }, port().sent)
			status("ONLINE")
			assert.same({ PROBE_REQUEST }, port().sent, "once")
		end)
	end)

	describe("verdicts", function()
		it("is not_pinned on an HTTP status line, whatever the status", function()
			for _, line in ipairs({ "HTTP/1.1 200 OK", "HTTP/1.1 401 Unauthorized", "HTTP/1.0 404 Not Found",
				"HTTP/1.1 500 Internal Server Error" }) do
				verdicts = {}
				probing()
				status("ONLINE")
				receive(line .. "\r\nContent-Length: 0\r\n\r\n")
				local v, detail = verdict()
				assert.equal("not_pinned", v)
				assert.equal("HTTP " .. line:match("(%d%d%d)") .. " with the decoy CA file", detail)
			end
		end)

		it("reads a status line split across reads, with blank lines before it", function()
			probing()
			status("ONLINE")
			receive("\r\n")
			receive("HTT")
			receive("P/1.1 2")
			deliver()
			assert.same({}, verdicts, "not yet a status line")
			receive("00 OK\r\nContent-Type: application/json\r\n")
			assert.equal("not_pinned", verdict())
		end)

		it("takes the whole answer in one read, and a status line with no line end yet", function()
			probing()
			status("ONLINE")
			receive(HTTP_ANSWER)
			assert.equal("not_pinned", verdict())

			verdicts = {}
			c4.now_ms = c4.now_ms + netcheck.STALE_MS
			probing()
			status("ONLINE")
			receive("HTTP/1.1 200")
			assert.equal("not_pinned", verdict())
		end)

		it("is pinned when the probe goes OFFLINE before ONLINE", function()
			probing()
			status("OFFLINE")
			local v, detail = verdict()
			assert.equal("pinned", v)
			assert.equal("no connection with the decoy CA file (OFFLINE before ONLINE)", detail)
		end)

		it("is pinned when the probe goes OFFLINE after ONLINE with no answer: ONLINE alone proves nothing", function()
			probing()
			status("ONLINE")
			status("OFFLINE")
			local v, detail = verdict()
			assert.equal("pinned", v)
			assert.truthy(detail:find("ONLINE, then OFFLINE", 1, true), detail)
		end)

		it("is inconclusive when nothing is reported within 10 s", function()
			probing()
			assert.equal(1, timeout())
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("no connection report within 10 s", detail)
		end)

		it("is inconclusive when ONLINE brings neither an answer nor OFFLINE within 10 s", function()
			probing()
			status("ONLINE")
			assert.equal(1, timeout())
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("no answer within 10 s", detail)
		end)

		it("is inconclusive on data that is no HTTP answer, never pinned, even when OFFLINE follows", function()
			probing()
			status("ONLINE")
			receive("SSH-2.0-OpenSSH_9.6\r\n")
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.truthy(detail:find("no HTTP answer", 1, true), detail)

			verdicts = {}
			c4.now_ms = c4.now_ms + netcheck.STALE_MS
			probing()
			status("ONLINE")
			receive("\0\1\2")
			status("OFFLINE")
			v, detail = verdict()
			assert.equal("inconclusive", v, "data came: the handshake did not fail")
			assert.truthy(detail:find("then OFFLINE", 1, true), detail)
		end)

		it("is inconclusive on an oversized answer with no line end", function()
			probing()
			status("ONLINE")
			receive(string.rep("x", netcheck.MAX_ANSWER + 10))
			assert.equal("inconclusive", verdict())
		end)

		it("is inconclusive when a C4 call raises, and still closes and clears the binding", function()
			c4.NetPortOptions = function() error("NetPortOptions failed") end
			run()
			control()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.truthy(detail:find("could not open the probe connection", 1, true), detail)
			assert.is_true(closed_and_cleared(c4))
		end)

		it("is inconclusive when the request cannot be sent", function()
			probing()
			c4.SendToNetwork = function() error("send failed") end
			status("ONLINE")
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.truthy(detail:find("could not send the probe request", 1, true), detail)
		end)

		it("is inconclusive without a CA configuration, with nothing sent or opened", function()
			local ca = http.ca
			http.ca = nil
			finally(function() http.ca = ca end)
			run()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("no CA configuration", detail)
			assert.equal(0, #c4.transfers)
			assert.equal(0, #c4.calls_to("CreateNetworkConnection"))
		end)

		it("is inconclusive for an address that cannot go into a request", function()
			run(IP .. "\r\nX-Injected: 1")
			assert.equal("inconclusive", verdict())
			assert.equal(0, #c4.transfers)
		end)

		it("comes once, from a 1 ms timer, never inside Director's callback", function()
			probing()
			status("OFFLINE")
			assert.same({}, verdicts, "not inside OnConnectionStatusChanged")
			assert.equal(1, deliver())
			assert.equal(1, #verdicts)
			status("ONLINE")
			receive(HTTP_ANSWER)
			status("OFFLINE")
			timeout()
			deliver()
			assert.equal(1, #verdicts, "what comes after the verdict is ignored")
		end)
	end)

	describe("binding 6002 afterwards", function()
		local scenarios = {
			not_pinned = function() status("ONLINE"); receive(HTTP_ANSWER) end,
			pinned = function() status("OFFLINE") end,
			["inconclusive (timeout)"] = function() timeout() end,
			["inconclusive (no HTTP)"] = function() status("ONLINE"); receive("garbage\n") end,
		}
		for name, drive in pairs(scenarios) do
			it("is closed and cleared before the verdict is delivered: " .. name, function()
				probing()
				drive()
				assert.is_true(closed_and_cleared(c4), "closed and cleared at once")
				assert.same({}, verdicts)
				assert.equal("", c4.network[PROBE].address)
				assert.equal("closed", port().state)
				deliver()
				assert.equal(1, #verdicts)
			end)
		end
	end)

	describe("the application key", function()
		it("never goes out on the probe: everything sent on 6002 is the unkeyed request", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			log.set_debug(true)
			finally(function() log.set_debug(false) end)
			for _, answer in ipairs({ HTTP_ANSWER, "HTTP/1.1 403 Forbidden\r\n\r\n" }) do
				c4.now_ms = c4.now_ms + netcheck.STALE_MS
				probing()
				status("ONLINE")
				receive(answer)
				deliver()
			end
			assert.same({ PROBE_REQUEST, PROBE_REQUEST }, sent_on(c4, PROBE))
			for _, data in ipairs(sent_on(c4, PROBE)) do
				assert.is_nil(data:lower():find("hue-application-key", 1, true))
			end
			for _, t in ipairs(c4.transfers) do
				assert.is_nil(t.headers["hue-application-key"], "nor on the control request")
			end
			for _, line in ipairs(lines) do
				assert.is_nil(line:find(CONFIG, 1, true), "the answer is counted, never logged")
			end
		end)
	end)

	describe("cancel and run again", function()
		it("cancel() drops the probe: no verdict, the binding closed and cleared, its reports ignored", function()
			probing()
			netcheck.cancel()
			assert.is_true(closed_and_cleared(c4))
			status("ONLINE")
			assert.same({}, port().sent, "no request after the cancel")
			status("OFFLINE")
			timeout()
			deliver()
			assert.same({}, verdicts)
		end)

		it("cancel() during the control: no probe connection is made", function()
			run()
			netcheck.cancel()
			control()
			deliver()
			assert.equal(0, #c4.calls_to("CreateNetworkConnection"))
			assert.equal(0, #c4.calls_to("NetDisconnect"), "nothing to close")
			assert.same({}, verdicts)
		end)

		it("cancel() drops a verdict not yet delivered", function()
			probing()
			status("OFFLINE")
			netcheck.cancel()
			deliver()
			assert.same({}, verdicts)
		end)

		it("run() replaces a probe in flight, which then never answers", function()
			local first = {}
			netcheck.run(IP, function(v) first[#first + 1] = v end)
			control()
			run()
			assert.is_true(closed_and_cleared(c4), "the first probe's connection closed")
			status("OFFLINE") -- what that close brought, while the new control runs
			control()
			status("OFFLINE")
			deliver()
			assert.same({}, first)
			assert.same({ "pinned" }, { verdicts[1] and verdicts[1][1] })
		end)

		it("claims binding 6002 only, with or without a probe", function()
			assert.is_true(netcheck.on_status_changed(PROBE, PORT, "OFFLINE"))
			assert.is_true(netcheck.on_data(PROBE, "x"))
			assert.is_true(netcheck.on_status_changed("6002", PORT, "ONLINE"), "a binding id given as text")
			probing()
			assert.is_false(netcheck.on_status_changed(STREAM, PORT, "OFFLINE"))
			assert.is_false(netcheck.on_data(STREAM, "HTTP/1.1 200 OK\r\n"))
			deliver()
			assert.same({}, verdicts, "the stream's reports are no verdict")
		end)
	end)

	describe("an OFFLINE its own close may bring", function()
		-- A probe that ended in OFFLINE was closed with NetDisconnect: the
		-- report that close may bring is owed for STALE_MS.
		local function pinned_once()
			probing()
			status("OFFLINE")
			assert.equal("pinned", verdict())
			verdicts = {}
		end

		it("is taken for the close's when the next probe follows at once: that probe ends inconclusive", function()
			pinned_once()
			probing()
			status("OFFLINE")
			deliver()
			assert.same({}, verdicts, "taken for the earlier close's")
			timeout()
			assert.equal("inconclusive", verdict(), "the safe side, never pinned")
		end)

		it("counts once the close's own report has come", function()
			pinned_once()
			status("OFFLINE") -- the close's, with no probe connection pending
			probing()
			status("OFFLINE")
			assert.equal("pinned", verdict())
		end)

		it("is no longer owed STALE_MS after the close", function()
			pinned_once()
			c4.now_ms = c4.now_ms + netcheck.STALE_MS
			probing()
			status("OFFLINE")
			assert.equal("pinned", verdict())
		end)

		it("is cleared by ONLINE: what comes after it is the probe's own", function()
			pinned_once()
			probing()
			status("ONLINE")
			status("OFFLINE")
			assert.equal("pinned", verdict())
		end)
	end)

	describe("remember_pinned and pinned_before", function()
		it("persist the running Director version, unencrypted, under netstream_pinned_on, apart from tlscheck's", function()
			assert.equal(c4.director_version, netcheck.remember_pinned())
			assert.equal(c4.director_version, c4.persist.netstream_pinned_on)
			assert.is_nil(c4.persist.tls_pinned_on)
			assert.same({ "netstream_pinned_on", c4.director_version, false }, c4.calls_to("PersistSetValue")[1])
		end)

		it("is false where the probe never answered pinned, whatever the C4:url check answered", function()
			c4.persist.tls_pinned_on = c4.director_version
			assert.is_false(netcheck.pinned_before())
		end)

		it("is true when an earlier run persisted the running version", function()
			c4.persist.netstream_pinned_on = c4.director_version
			assert.is_true(netcheck.pinned_before())
		end)

		it("is false after a Director update, until the new version answers pinned", function()
			c4.persist.netstream_pinned_on = "3.3.0.100000"
			assert.is_false(netcheck.pinned_before())
			netcheck.remember_pinned()
			assert.is_true(netcheck.pinned_before())
		end)

		it("is false, and remembers nothing, when the version cannot be read", function()
			c4.persist.netstream_pinned_on = "3.4.2.746094"
			c4.director_version = nil
			assert.is_nil(netcheck.remember_pinned())
			assert.equal("3.4.2.746094", c4.persist.netstream_pinned_on, "nothing stored")
			assert.is_false(netcheck.pinned_before())
		end)

		it("is true right after remember_pinned, before the store returns the value", function()
			c4.PersistGetValue = function() return nil end
			netcheck.remember_pinned()
			assert.is_true(netcheck.pinned_before())
		end)

		it("does not raise when the store does; the run still remembers, with a warning", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			c4.PersistSetValue = function() error("store failed") end
			assert.equal(c4.director_version, netcheck.remember_pinned())
			assert.is_true(netcheck.pinned_before())
			assert.truthy(lines[1] and lines[1]:find("could not store", 1, true))
		end)
	end)

	it("retry_delay doubles from RETRY_MIN up to RETRY_MAX", function()
		local delays = {}
		for attempt = 1, 6 do delays[attempt] = netcheck.retry_delay(attempt) end
		assert.same({ 30, 60, 120, 240, 300, 300 }, delays)
	end)
end)

describe("Hue Bridge driver: the network connection's TLS check (#317)", function()
	local lines

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
	end)

	-- A bridge driver paired with the placeholder bridge, before late init.
	local function paired_bridge(props)
		local all = { ["Bridge IP Address"] = IP }
		for k, v in pairs(props or {}) do all[k] = v end
		local env, c4 = fake.load_driver("hue_bridge", all)
		c4.persist.hue_app_key = KEY
		c4.persist.hue_bridge_id = BRIDGE_ID
		return env, c4
	end

	-- Answer the newest request for the bridge's public config: the identity
	-- check, or the probe's control request.
	local function answer_config(c4, ip)
		local t = c4.last_transfer()
		assert.truthy(t, "a request")
		assert.equal("https://" .. (ip or IP) .. "/api/0/config", t.url)
		assert.is_nil(t.headers["hue-application-key"])
		t:respond(200, CONFIG)
		return t
	end

	-- Late init, the identity check (the fake refuses the C4:url TLS check's
	-- decoy by itself) and the control request: the probe is opening.
	local function at_probe(env, c4)
		env.OnDriverLateInit("DIT_STARTUP")
		answer_config(c4) -- the identity check
		assert.equal(1, #c4.decoy_transfers, "the C4:url TLS check passed first")
		answer_config(c4) -- the probe's control request
		assert.same({ PROBE, IP, "SSL" }, c4.calls_to("CreateNetworkConnection")[1])
		return env, c4
	end

	local function probe_status(c4, text) c4.net_status(PROBE, PORT, text) end
	local function deliver(c4) return c4.fire_timers_of(1) end

	-- The stream's connection was created on binding 6001.
	local function stream_created(c4)
		return #calls_on(c4, "CreateNetworkConnection", STREAM) > 0
	end

	it("holds the stream until the probe answers, and the probe carries no key", function()
		local env, c4 = at_probe(paired_bridge())
		assert.equal("Paired", env.Properties["Status"], "keyed C4:url requests are not held")
		probe_status(c4, "ONLINE")
		assert.same({ PROBE_REQUEST }, sent_on(c4, PROBE))
		assert.is_false(stream_created(c4))
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
		assert.is_false(stream_created(c4), "Connect Event Stream joins the check in flight")
		assert.equal(1, #calls_on(c4, "CreateNetworkConnection", PROBE), "one probe")
		for _, args in ipairs(c4.calls_to("SendToNetwork")) do
			assert.is_nil(args[3]:find(KEY, 1, true), "nothing sent so far carries the key")
		end
	end)

	it("pinned: binding 6002 closed and cleared, the version remembered, the stream on 6001 with the key", function()
		local env, c4 = at_probe(paired_bridge())
		probe_status(c4, "OFFLINE")
		assert.is_true(closed_and_cleared(c4))
		assert.is_false(stream_created(c4), "the verdict comes from a timer")
		assert.equal(1, deliver(c4))
		assert.equal(c4.director_version, c4.persist.netstream_pinned_on)
		assert.same({ STREAM, IP, "SSL" }, calls_on(c4, "CreateNetworkConnection", STREAM)[1])
		assert.equal(IP .. " (network connection, binding 6001)", env.Properties["Stream Address"])
		-- Director's reports reach the stream on 6001, the probe's only on 6002.
		c4.net_status(STREAM, PORT, "ONLINE")
		local stream_sent = sent_on(c4, STREAM)
		assert.equal(1, #stream_sent)
		assert.truthy(stream_sent[1]:find("hue-application-key: " .. KEY, 1, true), "the stream's own request")
		assert.same({}, sent_on(c4, PROBE), "the probe never went online")
		assert.equal("", c4.network[PROBE].address)
		assert.equal("None", env.Properties["Attention"])
	end)

	it("not_pinned: Web transfer for this run, with the Attention item and the detail logged", function()
		local env, c4 = at_probe(paired_bridge())
		probe_status(c4, "ONLINE")
		c4.net_receive(PROBE, PORT, HTTP_ANSWER)
		assert.is_true(closed_and_cleared(c4))
		deliver(c4)
		-- The C4:url stream's path: the self-check of its own spelling, then the stream.
		local check = c4.last_transfer()
		assert.truthy(check.url:find("/clip/v2/resource/bridge", 1, true), check.url)
		check:respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"' .. BRIDGE_ID .. '"}]}')
		local streams = 0
		for _, t in ipairs(c4.transfers) do
			if t.url:find("/eventstream/clip/v2", 1, true) then streams = streams + 1 end
		end
		assert.equal(1, streams, "the Web transfer stream")
		assert.is_false(stream_created(c4), "never a keyed network connection")
		assert.equal(NET_ATTENTION, env.Properties["Attention"])
		assert.equal("Network connection", env.Properties["Event Stream Transport"], "the owner's choice is kept")
		assert.equal("Paired", env.Properties["Status"])
		assert.is_nil(c4.persist.netstream_pinned_on)
		local logged = false
		for _, line in ipairs(lines) do
			if line:find("[WARN]", 1, true) and line:find("HTTP 200 with the decoy CA file", 1, true) then
				logged = true
			end
		end
		assert.is_true(logged, "the detail is logged")

		-- For the rest of the run: no second probe, still no network connection.
		env.Properties["Event Stream Transport"] = "Network connection"
		env.OnPropertyChanged("Event Stream Transport")
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
		assert.equal(1, #calls_on(c4, "CreateNetworkConnection", PROBE))
		assert.is_false(stream_created(c4))
		assert.equal(NET_ATTENTION, env.Properties["Attention"])

		-- The next run checks again: nothing of the fallback is stored.
		local env2, c42 = paired_bridge()
		at_probe(env2, c42)
		probe_status(c42, "OFFLINE")
		deliver(c42)
		assert.is_true(stream_created(c42))
	end)

	it("inconclusive, never pinned on this Director version: nothing keyed on 6001, asked again with a backoff", function()
		local env, c4 = at_probe(paired_bridge())
		assert.equal(1, c4.fire_timers_of(10000), "the probe's timeout")
		deliver(c4)
		assert.equal("Not connected: network connection TLS check inconclusive (no connection report within 10 s); "
			.. "checking again in 30 s", env.Properties["Event Stream"])
		assert.is_false(stream_created(c4))
		assert.is_nil(c4.persist.netstream_pinned_on)

		-- 30 s later: the control and the probe again, inconclusive again, 60 s.
		c4.now_ms = c4.now_ms + 30000
		assert.equal(1, c4.fire_timers_of(30000))
		answer_config(c4)
		assert.equal(2, #calls_on(c4, "CreateNetworkConnection", PROBE))
		c4.fire_timers_of(10000)
		deliver(c4)
		assert.truthy(env.Properties["Event Stream"]:find("checking again in 60 s", 1, true))
		assert.is_false(stream_created(c4))

		-- Then a conclusive answer lets the stream connect.
		c4.now_ms = c4.now_ms + 60000
		assert.equal(1, c4.fire_timers_of(60000))
		answer_config(c4)
		probe_status(c4, "OFFLINE")
		deliver(c4)
		assert.is_true(stream_created(c4))
		assert.equal(c4.director_version, c4.persist.netstream_pinned_on)
		for _, data in ipairs(sent_on(c4, PROBE)) do
			assert.equal(PROBE_REQUEST, data)
		end
	end)

	it("inconclusive on a Director version that answered pinned before: the stream connects", function()
		local env, c4 = paired_bridge()
		c4.persist.netstream_pinned_on = c4.director_version
		at_probe(env, c4)
		c4.fire_timers_of(10000)
		deliver(c4)
		assert.is_true(stream_created(c4))
		local warned = false
		for _, line in ipairs(lines) do
			if line:find("answered pinned before, so it passes", 1, true) then warned = true end
		end
		assert.is_true(warned)
	end)

	it("inconclusive is held when only another version, or only the C4:url check, answered pinned", function()
		for _, store in ipairs({ { netstream_pinned_on = "3.3.0.100000" }, { tls_pinned_on = "3.4.2.746094" } }) do
			local env, c4 = paired_bridge()
			c4.director_version = "3.4.2.746094"
			for k, v in pairs(store) do c4.persist[k] = v end
			at_probe(env, c4)
			c4.fire_timers_of(10000)
			deliver(c4)
			assert.is_false(stream_created(c4))
			assert.truthy(env.Properties["Event Stream"]:find("inconclusive", 1, true))
		end
	end)

	it("a Web transfer owner never sees a probe", function()
		local env, c4 = paired_bridge({ ["Event Stream Transport"] = "Web transfer" })
		env.OnDriverLateInit("DIT_STARTUP")
		answer_config(c4)
		assert.truthy(c4.last_transfer().url:find("/clip/v2/resource/bridge", 1, true), "straight to the C4:url path")
		assert.equal(0, #c4.calls_to("CreateNetworkConnection"))
	end)

	it("an address change cancels the probe: closed and cleared, then the new address is probed", function()
		local env, c4 = at_probe(paired_bridge())
		local before = { disconnect = #calls_on(c4, "NetDisconnect", PROBE),
			address = #calls_on(c4, "SetBindingAddress", PROBE) }
		env.Properties["Bridge IP Address"] = "192.0.2.11"
		env.OnPropertyChanged("Bridge IP Address")
		assert.is_true(closed_and_cleared(c4, before))
		probe_status(c4, "OFFLINE") -- what the cancel's close brought
		answer_config(c4, "192.0.2.11") -- the identity check at the new address
		answer_config(c4, "192.0.2.11") -- the control
		assert.same({ PROBE, "192.0.2.11", "SSL" }, calls_on(c4, "CreateNetworkConnection", PROBE)[2])
		probe_status(c4, "OFFLINE")
		deliver(c4)
		assert.same({ STREAM, "192.0.2.11", "SSL" }, calls_on(c4, "CreateNetworkConnection", STREAM)[1])
	end)

	it("Forget Pairing and OnDriverDestroyed close and clear a probe in flight; it answers no one", function()
		for _, stop in ipairs({
			function(env) env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" }) end,
			function(env) env.OnDriverDestroyed() end,
		}) do
			local env, c4 = at_probe(paired_bridge())
			local before = { disconnect = 0, address = #calls_on(c4, "SetBindingAddress", PROBE) }
			stop(env)
			assert.is_true(closed_and_cleared(c4, before))
			probe_status(c4, "OFFLINE")
			deliver(c4)
			assert.is_false(stream_created(c4))
			assert.is_nil(c4.persist.netstream_pinned_on)
		end
	end)

	it("switching the transport while the probe runs starts no stream twice", function()
		local env, c4 = at_probe(paired_bridge())
		env.Properties["Event Stream Transport"] = "Web transfer"
		env.OnPropertyChanged("Event Stream Transport")
		assert.is_true(closed_and_cleared(c4), "the probe for the other transport is cancelled")
		local check = c4.last_transfer()
		assert.truthy(check.url:find("/clip/v2/resource/bridge", 1, true), check.url)
		check:respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"' .. BRIDGE_ID .. '"}]}')
		probe_status(c4, "OFFLINE")
		deliver(c4)
		local streams = 0
		for _, t in ipairs(c4.transfers) do
			if t.url:find("/eventstream/clip/v2", 1, true) then streams = streams + 1 end
		end
		assert.equal(1, streams)
		assert.is_false(stream_created(c4))
	end)
end)
