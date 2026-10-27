-- Issue #317: the TLS self-check of the network connection
-- (bridge/netcheck.lua). The event stream's GET carries the application key
-- on a network connection that is told to verify the bridge against the
-- Signify roots. Before its first keyed connect of a run, unkeyed probes on
-- binding 6002: a control with the Signify roots, the decoy CA file, and
-- after a decoy that failed a second control. On OS 3.4.3 a refused
-- handshake is silent [hardware, build 414], so a silent decoy reads
-- "pinned", but only between two controls that answered. The driver
-- connects the stream on "pinned" (or on an inconclusive answer from a
-- Director version that answered pinned before), falls back to Web transfer
-- for the run on "not_pinned", and otherwise asks again after a backoff,
-- sending nothing keyed on the network connection.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local IP = "10.0.2.143"
local PROBE, STREAM, PORT = 6002, 6001, 443
local KEY = "netcheck-spec-key" -- a placeholder; it must never reach binding 6002
local BRIDGE_ID = "001788fffe123abc"
local SIGNIFY, DECOY = "certs/hue_ca_bundle.pem", "certs/decoy_ca.pem"
local GAP_MS, TIMEOUT_MS = 1500, 10000
local CONFIG = '{"name":"Hue Bridge","bridgeid":"001788FFFE123ABC","modelid":"BSB003","swversion":"1968096020",'
	.. '"apiversion":"1.68.0"}'
-- What every probe sends on ONLINE: the bridge's public config, no key.
local PROBE_REQUEST = "GET /api/0/config HTTP/1.1\r\nHost: " .. IP .. "\r\nConnection: close\r\n\r\n"
-- The bridge's answer, as a connection that completed its handshake delivers it.
local HTTP_ANSWER = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " .. #CONFIG
	.. "\r\nConnection: close\r\n\r\n" .. CONFIG
local NET_ATTENTION = "Event stream: the network connection did not verify the bridge's certificate on this "
	.. "controller; using Web transfer (#317)"
local OPEN = { "CreateNetworkConnection", "SetBindingAddress", "NetPortOptions", "NetConnect" }
local CLOSE = { "NetDisconnect", "clear" }

-- The lists one after the other, as one list.
local function seq(...)
	local out = {}
	for _, list in ipairs({ ... }) do
		for _, item in ipairs(list) do out[#out + 1] = item end
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

-- The SendToNetwork data of one binding, in order.
local function sent_on(c4, binding)
	local out = {}
	for _, args in ipairs(calls_on(c4, "SendToNetwork", binding)) do
		out[#out + 1] = args[3]
	end
	return out
end

-- The calls made for binding 6002, by name, in order; SetBindingAddress with
-- '' reads "clear".
local function probe_calls(c4)
	local names = {}
	for _, call in ipairs(c4.calls) do
		if call.args[1] == PROBE then
			names[#names + 1] = (call.name == "SetBindingAddress" and call.args[2] == "") and "clear" or call.name
		end
	end
	return names
end

-- The CACERTFILE of every NetPortOptions for binding 6002, in order.
local function ca_files(c4)
	local out = {}
	for _, args in ipairs(calls_on(c4, "NetPortOptions", PROBE)) do
		out[#out + 1] = args[4].CACERTFILE
	end
	return out
end

-- The binding was closed and its address cleared, after `before` calls of each.
local function closed_and_cleared(c4, before)
	before = before or { disconnect = 0, clear = 0 }
	local disconnects, clears = calls_on(c4, "NetDisconnect", PROBE), {}
	for _, args in ipairs(calls_on(c4, "SetBindingAddress", PROBE)) do
		if args[2] == "" then clears[#clears + 1] = args end
	end
	return #disconnects > before.disconnect and disconnects[#disconnects][2] == PORT and #clears > before.clear
end

local function counts(c4)
	local clears = 0
	for _, args in ipairs(calls_on(c4, "SetBindingAddress", PROBE)) do
		if args[2] == "" then clears = clears + 1 end
	end
	return { disconnect = #calls_on(c4, "NetDisconnect", PROBE), clear = clears }
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
	local function gap() return c4.fire_timers_of(netcheck.GAP_MS) end
	local function timeout() return c4.fire_timers_of(netcheck.TIMEOUT * 1000) end
	local function creates() return #calls_on(c4, "CreateNetworkConnection", PROBE) end

	local function run(ip)
		netcheck.run(ip or IP, function(v, d) verdicts[#verdicts + 1] = { v, d } end)
	end

	-- The open probe goes ONLINE and answers.
	local function answers(answer)
		status("ONLINE")
		receive(answer or HTTP_ANSWER)
	end

	-- What the close of a probe brings, as Director may report a disconnect
	-- of the driver's own.
	local function closed_report() status("OFFLINE") end

	-- A check at its decoy: the control answered, its close reported, the gap passed.
	local function at_decoy()
		local before = creates()
		run()
		answers()
		closed_report()
		assert.equal(1, gap())
		assert.equal(before + 2, creates())
	end

	-- A check at its confirm: the decoy failed (silent by default).
	local function at_confirm(fail)
		at_decoy()
		local before = creates()
		if fail then fail() else assert.equal(1, timeout()) end
		closed_report()
		assert.equal(1, gap())
		assert.equal(before + 1, creates())
	end

	-- The one verdict, delivered.
	local function verdict()
		deliver()
		assert.equal(1, #verdicts, "exactly one verdict")
		return verdicts[1][1], verdicts[1][2]
	end

	describe("the probes", function()
		it("start with the control: 6002 recreated, addressed, the stream's options, connected; nothing else", function()
			run()
			assert.same(OPEN, probe_calls(c4))
			assert.same({ PROBE, IP, "SSL" }, c4.calls_to("CreateNetworkConnection")[1])
			assert.same({ PROBE, IP }, c4.calls_to("SetBindingAddress")[1])
			assert.same(netstream.port_options(), port().options, "the Signify roots, the stream's own options")
			assert.same({ PROBE, PORT }, c4.calls_to("NetConnect")[1])
			assert.is_nil(c4.network[STREAM], "nothing on the stream's binding")
			assert.equal(0, #c4.transfers, "no C4:url request")
		end)

		it("send the unkeyed request once ONLINE, once per probe", function()
			run()
			assert.same({}, port().sent)
			status("ONLINE")
			status("ONLINE")
			assert.same({ PROBE_REQUEST }, port().sent)
		end)

		it("recreate 6002 for every probe and close and clear it after each: control, decoy, control", function()
			at_confirm()
			answers()
			assert.equal("pinned", verdict())
			assert.same(seq(OPEN, { "SendToNetwork" }, CLOSE, OPEN, CLOSE, OPEN, { "SendToNetwork" }, CLOSE),
				probe_calls(c4), "no NetDisconnect before a connect")
			assert.same({ SIGNIFY, DECOY, SIGNIFY }, ca_files(c4))
			assert.equal("", c4.network[PROBE].address)
			assert.equal("closed", port().state)
		end)

		it("open the next probe GAP_MS after a close, out of Director's callback", function()
			run()
			answers()
			assert.equal(1, creates(), "not inside ReceivedFromNetwork")
			assert.equal(GAP_MS, netcheck.GAP_MS)
			assert.equal(1, gap())
			assert.equal(2, creates())
		end)

		it("give the decoy the stream's options with the decoy CA file and nothing else changed", function()
			local expected = netstream.port_options()
			expected.CACERTFILE = DECOY
			assert.same(expected, netcheck.port_options())
			assert.equal(require("bridge.tlscheck").DECOY_CA, netcheck.port_options().CACERTFILE)
			-- A fresh table per call, the stream's untouched.
			netcheck.port_options().VERIFY_MODE = "none"
			assert.equal("peer", netcheck.port_options().VERIFY_MODE)
			assert.equal(SIGNIFY, netstream.port_options().CACERTFILE)
			at_decoy()
			assert.same(expected, port().options)
		end)
	end)

	describe("the control", function()
		local failures = {
			["silent for 10 s"] = { function() timeout() end, "was silent for 10 s" },
			["OFFLINE before ONLINE"] = { function() status("OFFLINE") end, "went OFFLINE before ONLINE" },
			["ONLINE, then OFFLINE"] = { function() status("ONLINE"); status("OFFLINE") end,
				"went ONLINE, then OFFLINE without an answer" },
			["ONLINE, then no answer"] = { function() status("ONLINE"); timeout() end,
				"went ONLINE, then gave no answer within 10 s" },
			["no HTTP answer"] = { function() status("ONLINE"); receive("SSH-2.0-OpenSSH_9.6\r\n") end,
				"got an answer that is no HTTP answer (21 bytes)" },
		}
		for name, case in pairs(failures) do
			it("that does not answer makes the check inconclusive, with no decoy: " .. name, function()
				run()
				case[1]()
				local v, detail = verdict()
				assert.equal("inconclusive", v)
				assert.equal("the control with the Signify roots " .. case[2], detail)
				gap()
				assert.equal(1, creates(), "no decoy probe")
				assert.same({ SIGNIFY }, ca_files(c4))
			end)
		end

		it("that cannot be opened makes it inconclusive, and the binding is still closed and cleared", function()
			c4.NetPortOptions = function() error("NetPortOptions failed") end
			run()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.truthy(detail:find("^the control with the Signify roots could not be opened: .*NetPortOptions failed"),
				detail)
			assert.is_true(closed_and_cleared(c4))
		end)

		it("that cannot send its request makes it inconclusive", function()
			run()
			c4.SendToNetwork = function() error("send failed") end
			status("ONLINE")
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.truthy(detail:find("could not send its request", 1, true), detail)
		end)

		it("counts any HTTP status as an answer", function()
			run()
			answers("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
			gap()
			assert.equal(2, creates())
			assert.same({ SIGNIFY, DECOY }, ca_files(c4))
		end)
	end)

	describe("verdicts", function()
		for _, line in ipairs({ "HTTP/1.1 200 OK", "HTTP/1.1 401 Unauthorized", "HTTP/1.0 404 Not Found",
			"HTTP/1.1 500 Internal Server Error" }) do
			it("not_pinned when the decoy gets an HTTP status line, whatever the status, with no confirm: " .. line,
				function()
					at_decoy()
					answers(line .. "\r\nContent-Length: 0\r\n\r\n")
					local v, detail = verdict()
					assert.equal("not_pinned", v)
					assert.equal("HTTP " .. line:match("(%d%d%d)") .. " with the decoy CA file", detail)
					gap()
					assert.equal(2, creates())
				end)
		end

		it("not_pinned on a status line split across reads, after blank lines", function()
			at_decoy()
			status("ONLINE")
			receive("\r\n")
			receive("HTT")
			receive("P/1.1 2")
			deliver()
			assert.same({}, verdicts, "not yet a status line")
			receive("00 OK\r\nContent-Type: application/json\r\n")
			assert.equal("not_pinned", verdict())
		end)

		it("not_pinned on a status line that has no line end yet", function()
			at_decoy()
			status("ONLINE")
			receive("HTTP/1.1 200")
			assert.equal("not_pinned", verdict())
		end)

		it("pinned when the decoy is silent for 10 s between two controls that answered", function()
			at_confirm()
			answers()
			local v, detail = verdict()
			assert.equal("pinned", v)
			assert.equal("the probe with the decoy CA file was silent for 10 s; the Signify roots answered before and "
				.. "after it", detail)
		end)

		it("pinned when the decoy goes OFFLINE before ONLINE, then the confirm answers", function()
			at_confirm(function() status("OFFLINE") end)
			answers()
			local v, detail = verdict()
			assert.equal("pinned", v)
			assert.truthy(detail:find("went OFFLINE before ONLINE", 1, true), detail)
		end)

		it("pinned when the decoy goes ONLINE, then OFFLINE without an answer, then the confirm answers", function()
			at_confirm(function() status("ONLINE"); status("OFFLINE") end)
			answers()
			local v, detail = verdict()
			assert.equal("pinned", v)
			assert.truthy(detail:find("went ONLINE, then OFFLINE without an answer", 1, true), detail)
		end)

		it("inconclusive when the confirm after a failed decoy does not answer: that failure proves nothing", function()
			at_confirm()
			timeout()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("the control after the decoy was silent for 10 s, so the decoy's failure proves nothing", detail)
		end)

		it("inconclusive when the decoy goes ONLINE and then neither answers nor closes: that is no silence", function()
			at_decoy()
			status("ONLINE")
			timeout()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("the probe with the decoy CA file went ONLINE, then gave no answer within 10 s", detail)
			gap()
			assert.equal(2, creates(), "no confirm")
		end)

		it("inconclusive when the decoy gets data that is no HTTP answer, also when OFFLINE follows", function()
			at_decoy()
			status("ONLINE")
			receive("garbage\n")
			assert.equal("inconclusive", verdict())

			verdicts = {}
			closed_report()
			at_decoy()
			status("ONLINE")
			receive("\0\1\2")
			status("OFFLINE")
			local v, detail = verdict()
			assert.equal("inconclusive", v, "data came: the handshake did not fail")
			assert.truthy(detail:find("no HTTP answer (3 bytes)", 1, true), detail)
		end)

		it("inconclusive on an oversized answer with no line end", function()
			at_decoy()
			status("ONLINE")
			receive(string.rep("x", netcheck.MAX_ANSWER + 10))
			assert.equal("inconclusive", verdict())
		end)

		it("inconclusive without a CA configuration, with nothing opened", function()
			local ca = http.ca
			http.ca = nil
			finally(function() http.ca = ca end)
			run()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("no CA configuration", detail)
			assert.same({}, probe_calls(c4))
		end)

		it("inconclusive for an address that cannot go into a request", function()
			run(IP .. "\r\nX-Injected: 1")
			assert.equal("inconclusive", verdict())
			assert.same({}, probe_calls(c4))
		end)

		it("come once, from a 1 ms timer, never inside Director's callback", function()
			at_confirm()
			answers()
			assert.same({}, verdicts, "not inside ReceivedFromNetwork")
			assert.equal(1, deliver())
			assert.equal(1, #verdicts)
			answers()
			status("OFFLINE")
			timeout()
			gap()
			deliver()
			assert.equal(1, #verdicts, "what comes after the verdict is ignored")
		end)
	end)

	describe("binding 6002", function()
		local endings = {
			pinned = function() at_confirm(); answers() end,
			not_pinned = function() at_decoy(); answers() end,
			["the control silent"] = function() run(); timeout() end,
			["the confirm silent"] = function() at_confirm(); timeout() end,
			["the decoy's answer no HTTP"] = function() at_decoy(); status("ONLINE"); receive("garbage\n") end,
		}
		for name, drive in pairs(endings) do
			it("is closed and cleared before the verdict is delivered: " .. name, function()
				drive()
				assert.is_true(closed_and_cleared(c4))
				assert.same(CLOSE, { unpack(probe_calls(c4), #probe_calls(c4) - 1) }, "the last calls")
				assert.same({}, verdicts)
				assert.equal("", c4.network[PROBE].address)
				assert.equal("closed", port().state)
				deliver()
				assert.equal(1, #verdicts)
			end)
		end

		it("is recreated on a retry: every check starts with a control of its own", function()
			run()
			timeout()
			assert.equal("inconclusive", verdict())
			verdicts = {}
			c4.now_ms = c4.now_ms + 30000
			run()
			assert.equal(2, creates())
			assert.same(seq(OPEN, CLOSE, OPEN), probe_calls(c4))
			assert.same({ SIGNIFY, SIGNIFY }, ca_files(c4))
		end)
	end)

	describe("the application key", function()
		it("never goes out on 6002: everything any probe sends is the unkeyed request", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			log.set_debug(true)
			finally(function() log.set_debug(false) end)
			at_confirm(function() status("ONLINE"); status("OFFLINE") end) -- control, decoy, confirm all online
			answers()
			deliver()
			closed_report()
			at_decoy()
			answers()
			deliver()
			assert.same({ PROBE_REQUEST, PROBE_REQUEST, PROBE_REQUEST, PROBE_REQUEST, PROBE_REQUEST },
				sent_on(c4, PROBE))
			for _, data in ipairs(sent_on(c4, PROBE)) do
				assert.is_nil(data:lower():find("hue-application-key", 1, true))
			end
			assert.equal(0, #c4.transfers)
			for _, line in ipairs(lines) do
				assert.is_nil(line:find(CONFIG, 1, true), "the answer is counted, never logged")
			end
		end)
	end)

	describe("cancel and run again", function()
		it("cancel() during a probe: closed and cleared, no verdict, later reports ignored", function()
			at_decoy()
			local before = counts(c4)
			netcheck.cancel()
			assert.is_true(closed_and_cleared(c4, before))
			status("ONLINE")
			assert.same({ PROBE_REQUEST }, port().sent, "no request after the cancel")
			timeout()
			gap()
			deliver()
			assert.same({}, verdicts)
			assert.equal(2, creates())
		end)

		it("cancel() between two probes: nothing more opens, and nothing is left to close", function()
			run()
			answers()
			local before = counts(c4)
			netcheck.cancel()
			assert.same(before, counts(c4))
			gap()
			deliver()
			assert.equal(1, creates())
			assert.same({}, verdicts)
		end)

		it("cancel() drops a verdict not yet delivered", function()
			run()
			timeout()
			netcheck.cancel()
			deliver()
			assert.same({}, verdicts)
		end)

		it("run() replaces a check in flight, which then never answers", function()
			local first = {}
			netcheck.run(IP, function(v) first[#first + 1] = v end)
			run()
			assert.is_true(closed_and_cleared(c4), "the first check's probe closed")
			closed_report()
			answers()
			closed_report()
			gap()
			timeout()
			closed_report()
			gap()
			answers()
			deliver()
			assert.same({}, first)
			assert.same({ "pinned" }, { verdicts[1] and verdicts[1][1] })
		end)

		it("claims binding 6002 only, with or without a check", function()
			assert.is_true(netcheck.on_status_changed(PROBE, PORT, "OFFLINE"))
			assert.is_true(netcheck.on_data(PROBE, "x"))
			assert.is_true(netcheck.on_status_changed("6002", PORT, "ONLINE"), "a binding id given as text")
			run()
			assert.is_false(netcheck.on_status_changed(STREAM, PORT, "OFFLINE"))
			assert.is_false(netcheck.on_data(STREAM, "HTTP/1.1 200 OK\r\n"))
			deliver()
			assert.same({}, verdicts, "the stream's reports are no verdict")
		end)
	end)

	describe("an OFFLINE a close may bring", function()
		it("is taken for the closed probe's whenever it comes: a decoy that answers after it is still not_pinned",
			function()
				run()
				answers()
				gap() -- the control's close has not reported yet
				status("ONLINE")
				status("OFFLINE") -- the control's, late: not the decoy's
				receive(HTTP_ANSWER)
				local v = verdict()
				assert.equal("not_pinned", v, "never a failed decoy, and never pinned")
			end)

		it("leaves a decoy whose own OFFLINE was taken so to its timeout: silent, pinned only after the confirm",
			function()
				run()
				answers()
				gap()
				status("OFFLINE") -- taken for the control's close
				deliver()
				assert.same({}, verdicts)
				timeout()
				closed_report()
				gap()
				answers()
				local v, detail = verdict()
				assert.equal("pinned", v)
				assert.truthy(detail:find("was silent for 10 s", 1, true), detail)
			end)

		it("is no longer owed STALE_MS after the close", function()
			run()
			answers()
			c4.now_ms = c4.now_ms + netcheck.STALE_MS
			gap()
			status("OFFLINE")
			closed_report()
			gap()
			answers()
			local v, detail = verdict()
			assert.equal("pinned", v)
			assert.truthy(detail:find("went OFFLINE before ONLINE", 1, true), detail)
		end)
	end)

	describe("remember_pinned and pinned_before", function()
		it("persist the running Director version, unencrypted, under netstream_pinned_on, apart from tlscheck's", function()
			assert.equal(c4.director_version, netcheck.remember_pinned())
			assert.equal(c4.director_version, c4.persist.netstream_pinned_on)
			assert.is_nil(c4.persist.tls_pinned_on)
			assert.same({ "netstream_pinned_on", c4.director_version, false }, c4.calls_to("PersistSetValue")[1])
		end)

		it("is false where the check never answered pinned, whatever the C4:url check answered", function()
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

	-- Answer the identity check: the newest request, for the bridge's public config.
	local function answer_identity(c4, ip)
		local t = c4.last_transfer()
		assert.truthy(t, "a request")
		assert.equal("https://" .. (ip or IP) .. "/api/0/config", t.url)
		assert.is_nil(t.headers["hue-application-key"])
		t:respond(200, CONFIG)
		return t
	end

	-- Late init and the identity check (the fake refuses the C4:url TLS
	-- check's decoy by itself): the control is opening on 6002.
	local function at_probe(env, c4)
		env.OnDriverLateInit("DIT_STARTUP")
		answer_identity(c4)
		assert.equal(1, #c4.decoy_transfers, "the C4:url TLS check passed first")
		assert.same({ PROBE, IP, "SSL" }, c4.calls_to("CreateNetworkConnection")[1])
		assert.equal("Not connected: network connection TLS check running", env.Properties["Event Stream"])
		return env, c4
	end

	-- The open probe goes ONLINE and answers; its close reports OFFLINE.
	local function probe_answers(c4, answer)
		c4.net_status(PROBE, PORT, "ONLINE")
		c4.net_receive(PROBE, PORT, answer or HTTP_ANSWER)
		c4.net_status(PROBE, PORT, "OFFLINE")
	end

	-- The open probe stays silent for 10 s; its close reports OFFLINE.
	local function probe_silent(c4)
		local fired = c4.fire_timers_of(TIMEOUT_MS)
		c4.net_status(PROBE, PORT, "OFFLINE")
		return fired
	end

	local function gap(c4) return c4.fire_timers_of(GAP_MS) end
	local function deliver(c4) return c4.fire_timers_of(1) end

	-- The check on a controller that verifies: the control answers, the decoy
	-- is silent, the control answers again.
	local function check_pinned(c4)
		probe_answers(c4)
		gap(c4)
		probe_silent(c4)
		gap(c4)
		probe_answers(c4)
	end

	-- The stream's connection was created on binding 6001.
	local function stream_created(c4)
		return #calls_on(c4, "CreateNetworkConnection", STREAM) > 0
	end

	local function warned(text)
		for _, line in ipairs(lines) do
			if line:find("[WARN]", 1, true) and line:find(text, 1, true) then return true end
		end
		return false
	end

	it("holds the stream until the check answers, and no probe carries the key", function()
		local env, c4 = at_probe(paired_bridge())
		assert.equal("Paired", env.Properties["Status"], "keyed C4:url requests are not held")
		probe_answers(c4)
		gap(c4)
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
		assert.equal(2, #calls_on(c4, "CreateNetworkConnection", PROBE), "Connect Event Stream joins the check")
		probe_silent(c4)
		gap(c4)
		assert.is_false(stream_created(c4))
		assert.same({ PROBE_REQUEST }, sent_on(c4, PROBE))
		for _, args in ipairs(c4.calls_to("SendToNetwork")) do
			assert.is_nil(args[3]:find(KEY, 1, true), "nothing sent so far carries the key")
		end
	end)

	it("pinned: 6002 closed and cleared, the version remembered, the stream on 6001 with the key", function()
		local env, c4 = at_probe(paired_bridge())
		check_pinned(c4)
		assert.is_false(stream_created(c4), "the verdict comes from a timer")
		assert.equal(1, deliver(c4))
		assert.equal(c4.director_version, c4.persist.netstream_pinned_on)
		assert.equal(3, #calls_on(c4, "CreateNetworkConnection", PROBE))
		assert.same({ STREAM, IP, "SSL" }, calls_on(c4, "CreateNetworkConnection", STREAM)[1])
		assert.equal(IP .. " (network connection, binding 6001)", env.Properties["Stream Address"])
		-- Director's reports reach the stream on 6001, the probes' only on 6002.
		c4.net_status(STREAM, PORT, "ONLINE")
		local stream_sent = sent_on(c4, STREAM)
		assert.equal(1, #stream_sent)
		assert.truthy(stream_sent[1]:find("hue-application-key: " .. KEY, 1, true), "the stream's own request")
		assert.same({ PROBE_REQUEST, PROBE_REQUEST }, sent_on(c4, PROBE), "the controls' requests only")
		assert.equal("", c4.network[PROBE].address)
		assert.equal("None", env.Properties["Attention"])
	end)

	it("not_pinned: Web transfer for this run, with the Attention item and the detail logged", function()
		local env, c4 = at_probe(paired_bridge())
		probe_answers(c4)
		gap(c4)
		probe_answers(c4) -- the decoy answers: the controller did not verify
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
		assert.is_true(warned("HTTP 200 with the decoy CA file"), "the detail is logged")

		-- For the rest of the run: no second check, still no network connection.
		env.Properties["Event Stream Transport"] = "Network connection"
		env.OnPropertyChanged("Event Stream Transport")
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
		assert.equal(2, #calls_on(c4, "CreateNetworkConnection", PROBE))
		assert.is_false(stream_created(c4))
		assert.equal(NET_ATTENTION, env.Properties["Attention"])

		-- The next run checks again: nothing of the fallback is stored.
		local env2, c42 = paired_bridge()
		at_probe(env2, c42)
		check_pinned(c42)
		deliver(c42)
		assert.is_true(stream_created(c42))
	end)

	it("inconclusive on a version never pinned: nothing keyed on 6001; 6002 recreated after a backoff", function()
		local env, c4 = at_probe(paired_bridge())
		assert.equal(1, probe_silent(c4), "the control's 10 s")
		deliver(c4)
		assert.equal("Not connected: network connection TLS check inconclusive (the control with the Signify roots was "
			.. "silent for 10 s); checking again in 30 s", env.Properties["Event Stream"])
		assert.is_false(stream_created(c4))
		assert.is_nil(c4.persist.netstream_pinned_on)

		-- 30 s later: a new check, its control on a recreated 6002.
		c4.now_ms = c4.now_ms + 30000
		assert.equal(1, c4.fire_timers_of(30000))
		assert.equal(2, #calls_on(c4, "CreateNetworkConnection", PROBE))
		assert.equal("Not connected: network connection TLS check running", env.Properties["Event Stream"])
		-- Inconclusive again (the decoy went ONLINE, then nothing): 60 s.
		probe_answers(c4)
		gap(c4)
		c4.net_status(PROBE, PORT, "ONLINE")
		c4.fire_timers_of(TIMEOUT_MS)
		deliver(c4)
		assert.truthy(env.Properties["Event Stream"]:find("checking again in 60 s", 1, true))
		assert.is_false(stream_created(c4))

		-- Then a conclusive answer lets the stream connect.
		c4.now_ms = c4.now_ms + 60000
		assert.equal(1, c4.fire_timers_of(60000))
		check_pinned(c4)
		deliver(c4)
		assert.is_true(stream_created(c4))
		assert.equal(c4.director_version, c4.persist.netstream_pinned_on)
		assert.equal(6, #calls_on(c4, "CreateNetworkConnection", PROBE))
		for _, data in ipairs(sent_on(c4, PROBE)) do
			assert.equal(PROBE_REQUEST, data)
		end
	end)

	it("inconclusive on a Director version that answered pinned before: the stream connects", function()
		local env, c4 = paired_bridge()
		c4.persist.netstream_pinned_on = c4.director_version
		at_probe(env, c4)
		probe_silent(c4)
		deliver(c4)
		assert.is_true(stream_created(c4))
		assert.is_true(warned("answered pinned before, so it passes"))
	end)

	it("inconclusive is held when only another version, or only the C4:url check, answered pinned", function()
		for _, store in ipairs({ { netstream_pinned_on = "3.3.0.100000" }, { tls_pinned_on = "3.4.2.746094" } }) do
			local env, c4 = paired_bridge()
			c4.director_version = "3.4.2.746094"
			for k, v in pairs(store) do c4.persist[k] = v end
			at_probe(env, c4)
			probe_silent(c4)
			deliver(c4)
			assert.is_false(stream_created(c4))
			assert.truthy(env.Properties["Event Stream"]:find("inconclusive", 1, true))
		end
	end)

	it("a Web transfer owner never sees a probe", function()
		local env, c4 = paired_bridge({ ["Event Stream Transport"] = "Web transfer" })
		env.OnDriverLateInit("DIT_STARTUP")
		answer_identity(c4)
		assert.truthy(c4.last_transfer().url:find("/clip/v2/resource/bridge", 1, true), "straight to the C4:url path")
		assert.equal(0, #c4.calls_to("CreateNetworkConnection"))
	end)

	it("an address change cancels the check: closed and cleared, then the new address is checked", function()
		local env, c4 = at_probe(paired_bridge())
		local before = counts(c4)
		env.Properties["Bridge IP Address"] = "192.0.2.11"
		env.OnPropertyChanged("Bridge IP Address")
		assert.is_true(closed_and_cleared(c4, before))
		c4.net_status(PROBE, PORT, "OFFLINE") -- what the cancel's close brought
		answer_identity(c4, "192.0.2.11")
		assert.same({ PROBE, "192.0.2.11", "SSL" }, calls_on(c4, "CreateNetworkConnection", PROBE)[2])
		assert.same({ PROBE, "192.0.2.11" }, calls_on(c4, "SetBindingAddress", PROBE)[3], "addressed anew")
		check_pinned(c4)
		deliver(c4)
		assert.same({ STREAM, "192.0.2.11", "SSL" }, calls_on(c4, "CreateNetworkConnection", STREAM)[1])
	end)

	it("Forget Pairing and OnDriverDestroyed close and clear a probe in flight; the check answers no one", function()
		for _, stop in ipairs({
			function(env) env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" }) end,
			function(env) env.OnDriverDestroyed() end,
		}) do
			local env, c4 = at_probe(paired_bridge())
			local before = counts(c4)
			stop(env)
			assert.is_true(closed_and_cleared(c4, before))
			c4.net_status(PROBE, PORT, "ONLINE")
			c4.net_receive(PROBE, PORT, HTTP_ANSWER)
			gap(c4)
			deliver(c4)
			assert.equal(1, #calls_on(c4, "CreateNetworkConnection", PROBE))
			assert.is_false(stream_created(c4))
			assert.is_nil(c4.persist.netstream_pinned_on)
		end
	end)

	it("switching the transport during the check starts no stream twice", function()
		local env, c4 = at_probe(paired_bridge())
		env.Properties["Event Stream Transport"] = "Web transfer"
		env.OnPropertyChanged("Event Stream Transport")
		assert.is_true(closed_and_cleared(c4), "the check for the other transport is cancelled")
		local check = c4.last_transfer()
		assert.truthy(check.url:find("/clip/v2/resource/bridge", 1, true), check.url)
		check:respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"' .. BRIDGE_ID .. '"}]}')
		c4.net_status(PROBE, PORT, "OFFLINE")
		gap(c4)
		c4.fire_timers_of(TIMEOUT_MS)
		deliver(c4)
		local streams = 0
		for _, t in ipairs(c4.transfers) do
			if t.url:find("/eventstream/clip/v2", 1, true) then streams = streams + 1 end
		end
		assert.equal(1, streams)
		assert.equal(1, #calls_on(c4, "CreateNetworkConnection", PROBE))
		assert.is_false(stream_created(c4))
	end)
end)
