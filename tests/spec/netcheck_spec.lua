-- Issue #317: the TLS self-check of the network connection
-- (bridge/netcheck.lua). The event stream's GET carries the application key
-- on a network connection that is told to verify the bridge against the
-- Signify roots. Before its first keyed connect of a run, unkeyed probes:
-- the decoy CA file first, on binding 6002, and only after a decoy that
-- failed the Signify roots on binding 6003; neither binding ever gets the
-- other's CA file. On OS 3.4.3 a refused handshake is silent [hardware,
-- build 414]; a decoy that shared a binding with the Signify roots answered
-- in 43 ms [build 415]. The driver connects the stream on "pinned" (or on an
-- inconclusive answer from a Director version that answered pinned before),
-- falls back to Web transfer for the run on "not_pinned", and otherwise asks
-- again after a backoff, sending nothing keyed on the network connection.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local IP = "10.0.2.143"
local NEW_IP = "198.51.100.20"
local DECOY_B, CONTROL_B, STREAM, PORT = 6002, 6003, 6001, 443
local KEY = "netcheck-spec-key" -- a placeholder; it must never reach a probe binding
local BRIDGE_ID = "001788fffe123abc"
local SIGNIFY, DECOY = "certs/hue_ca_bundle.pem", "certs/decoy_ca.pem"
local GAP_MS, TIMEOUT_MS, STALE_MS = 1500, 10000, 5000
local CONFIG = '{"name":"Hue Bridge","bridgeid":"001788FFFE123ABC","modelid":"BSB003","swversion":"1968096020",'
	.. '"apiversion":"1.68.0"}'
-- What every probe sends on ONLINE: the bridge's public config, no key.
local function probe_request(ip)
	return "GET /api/0/config HTTP/1.1\r\nHost: " .. ip .. "\r\nConnection: close\r\n\r\n"
end
local PROBE_REQUEST = probe_request(IP)
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

-- The calls made for one binding, by name, in order; SetBindingAddress with
-- '' reads "clear".
local function probe_calls(c4, binding)
	local names = {}
	for _, call in ipairs(c4.calls) do
		if call.args[1] == binding then
			names[#names + 1] = (call.name == "SetBindingAddress" and call.args[2] == "") and "clear" or call.name
		end
	end
	return names
end

-- The CACERTFILE of every NetPortOptions for one binding, in order.
local function ca_files(c4, binding)
	local out = {}
	for _, args in ipairs(calls_on(c4, "NetPortOptions", binding)) do
		out[#out + 1] = args[4].CACERTFILE
	end
	return out
end

local function counts(c4, binding)
	local names = probe_calls(c4, binding)
	local disconnects, clears = 0, 0
	for _, name in ipairs(names) do
		if name == "NetDisconnect" then disconnects = disconnects + 1 end
		if name == "clear" then clears = clears + 1 end
	end
	return { disconnect = disconnects, clear = clears }
end

-- The binding was closed and its address cleared since `before`, and those
-- are its last calls.
local function closed_and_cleared(c4, binding, before)
	before = before or { disconnect = 0, clear = 0 }
	local now, names = counts(c4, binding), probe_calls(c4, binding)
	return now.disconnect > before.disconnect and now.clear > before.clear
		and names[#names - 1] == "NetDisconnect" and names[#names] == "clear"
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

	local function status(binding, text) c4.net_status(binding, PORT, text) end
	local function receive(binding, data) c4.net_receive(binding, PORT, data) end
	local function settle() return c4.fire_timers_of(1) end
	local function wait_gap()
		c4.now_ms = c4.now_ms + GAP_MS
		return c4.fire_timers_of(GAP_MS)
	end
	local function timeout() return c4.fire_timers_of(TIMEOUT_MS) end
	local function creates(binding) return #calls_on(c4, "CreateNetworkConnection", binding) end
	local function options_of(binding) return c4.network[binding].ports[PORT].options end

	local function run(ip)
		netcheck.run(ip or IP, function(v, d) verdicts[#verdicts + 1] = { v, d } end)
	end

	-- The decoy goes ONLINE and answers `after` ms later (300 by default).
	local function decoy_answers(after, answer)
		status(DECOY_B, "ONLINE")
		c4.now_ms = c4.now_ms + (after or 300)
		receive(DECOY_B, answer or HTTP_ANSWER)
	end

	local function control_answers(answer)
		status(CONTROL_B, "ONLINE")
		receive(CONTROL_B, answer or HTTP_ANSWER)
	end

	-- A check at its control: the decoy failed (`fail`, by default silent for
	-- 10 s), its close, then the gap.
	local function at_control(fail)
		local before = creates(CONTROL_B)
		run()
		if fail then fail() else assert.equal(1, timeout()) end
		assert.equal(1, settle(), "the decision")
		assert.equal(before, creates(CONTROL_B), "not before the gap")
		assert.equal(1, wait_gap())
		assert.equal(before + 1, creates(CONTROL_B))
	end

	-- The one verdict, delivered: the decision, then the delivery.
	local function verdict()
		settle()
		settle()
		assert.equal(1, #verdicts, "exactly one verdict")
		return verdicts[1][1], verdicts[1][2]
	end

	describe("the probes", function()
		it("start with the decoy on binding 6002: recreated, addressed, the decoy CA file, connected", function()
			run()
			assert.same(OPEN, probe_calls(c4, DECOY_B))
			assert.same({ DECOY_B, IP, "SSL" }, c4.calls_to("CreateNetworkConnection")[1])
			assert.same({ DECOY_B, IP }, c4.calls_to("SetBindingAddress")[1])
			assert.same({ DECOY_B, PORT }, c4.calls_to("NetConnect")[1])
			local expected = netstream.port_options()
			expected.CACERTFILE = DECOY
			assert.same(expected, options_of(DECOY_B))
			assert.same({}, probe_calls(c4, CONTROL_B))
			assert.is_nil(c4.network[STREAM])
			assert.equal(0, #c4.transfers, "no C4:url request")
		end)

		it("send the unkeyed request once ONLINE, once per probe", function()
			run()
			assert.same({}, sent_on(c4, DECOY_B))
			status(DECOY_B, "ONLINE")
			status(DECOY_B, "ONLINE")
			assert.same({ PROBE_REQUEST }, sent_on(c4, DECOY_B))
		end)

		it("open the control on 6003 only after the decoy failed; neither binding gets the other's CA file", function()
			at_control()
			control_answers()
			assert.equal("pinned", verdict())
			assert.same({ DECOY }, ca_files(c4, DECOY_B))
			assert.same({ SIGNIFY }, ca_files(c4, CONTROL_B))
			assert.same(netstream.port_options(), options_of(CONTROL_B), "the stream's own options")
			assert.same(seq(OPEN, CLOSE, CLOSE), probe_calls(c4, DECOY_B), "closed after the decoy and after the verdict")
			assert.same(seq(OPEN, { "SendToNetwork" }, CLOSE), probe_calls(c4, CONTROL_B))
		end)

		it("act on a probe's end from a timer: nothing is closed inside Director's callback", function()
			run()
			decoy_answers()
			assert.same(seq(OPEN, { "SendToNetwork" }), probe_calls(c4, DECOY_B), "nothing closed inside the callback")
			assert.equal(1, settle())
			assert.is_true(closed_and_cleared(c4, DECOY_B))
			assert.same({}, verdicts, "the verdict comes from a timer too")
			settle()
			assert.equal(1, #verdicts)
		end)

		it("leave 1.5 s on the clock between a close and the next creation, whatever the timer does", function()
			run()
			timeout()
			settle()
			local closed = c4.now_ms
			assert.equal(1, c4.fire_timers_of(GAP_MS), "the gap timer")
			assert.equal(0, creates(CONTROL_B), "fired with the clock not moved on: nothing created")
			c4.now_ms = closed + GAP_MS - 1
			assert.equal(1, c4.fire_timers_of(GAP_MS))
			assert.equal(0, creates(CONTROL_B), "1 ms short")
			c4.now_ms = closed + GAP_MS
			assert.equal(1, settle())
			assert.equal(1, creates(CONTROL_B))
		end)

		it("wait 1.5 s after the last close for a new check too", function()
			run()
			netcheck.cancel()
			run()
			assert.equal(1, creates(DECOY_B), "not yet")
			assert.equal(1, wait_gap())
			assert.equal(2, creates(DECOY_B))
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
		end)
	end)

	describe("verdicts", function()
		it("pinned: the decoy silent for 10 s, then the Signify roots answer on 6003", function()
			at_control()
			control_answers()
			local v, detail = verdict()
			assert.equal("pinned", v)
			assert.equal("the probe with the decoy CA file was silent for 10 s; the Signify roots answered on binding 6003",
				detail)
		end)

		local failures = {
			["OFFLINE before ONLINE"] = { function() status(DECOY_B, "OFFLINE") end, "went OFFLINE before ONLINE" },
			["ONLINE, then OFFLINE"] = { function() status(DECOY_B, "ONLINE"); status(DECOY_B, "OFFLINE") end,
				"went ONLINE, then OFFLINE without an answer" },
			["ONLINE, then no answer"] = { function() status(DECOY_B, "ONLINE"); timeout() end,
				"went ONLINE, then gave no answer within 10 s" },
		}
		for name, case in pairs(failures) do
			it("pinned: the decoy failed (" .. name .. "), then the control answers", function()
				at_control(case[1])
				control_answers()
				local v, detail = verdict()
				assert.equal("pinned", v)
				assert.truthy(detail:find(case[2], 1, true), detail)
			end)
		end

		for _, line in ipairs({ "HTTP/1.1 200 OK", "HTTP/1.1 401 Unauthorized", "HTTP/1.0 404 Not Found" }) do
			it("not_pinned: the decoy answers 300 ms after ONLINE, whatever the status, and no control: " .. line,
				function()
					run()
					decoy_answers(300, line .. "\r\nContent-Length: 0\r\n\r\n")
					local v, detail = verdict()
					assert.equal("not_pinned", v)
					assert.equal("the probe with the decoy CA file answered HTTP " .. line:match("(%d%d%d)")
						.. " 300 ms after ONLINE", detail)
					wait_gap()
					assert.equal(0, creates(CONTROL_B))
				end)
		end

		it("inconclusive: the decoy answers only 40 ms after ONLINE, the timing in the detail, and no control", function()
			run()
			decoy_answers(40)
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("the probe with the decoy CA file answered HTTP 200 40 ms after ONLINE: too soon for a "
				.. "handshake, taken for a reused connection or session", detail)
			wait_gap()
			assert.equal(0, creates(CONTROL_B))
		end)

		it("draws the line at 150 ms: 149 ms is too soon, 150 ms is not", function()
			run()
			decoy_answers(149)
			assert.equal("inconclusive", verdict())
			verdicts = {}
			run()
			wait_gap()
			decoy_answers(150)
			assert.equal("not_pinned", verdict())
		end)

		it("inconclusive: a decoy answer with no ONLINE before it", function()
			run()
			receive(DECOY_B, HTTP_ANSWER)
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.truthy(detail:find("answered HTTP 200 before ONLINE", 1, true), detail)
		end)

		local control_failures = {
			["silent for 10 s"] = { function() timeout() end, "was silent for 10 s" },
			["OFFLINE before ONLINE"] = { function() status(CONTROL_B, "OFFLINE") end, "went OFFLINE before ONLINE" },
			["ONLINE, then no answer"] = { function() status(CONTROL_B, "ONLINE"); timeout() end,
				"went ONLINE, then gave no answer within 10 s" },
			["no HTTP answer"] = { function() status(CONTROL_B, "ONLINE"); receive(CONTROL_B, "SSH-2.0-OpenSSH_9.6\r\n") end,
				"got an answer that is no HTTP answer (21 bytes)" },
		}
		for name, case in pairs(control_failures) do
			it("inconclusive: the control does not answer (" .. name .. ")", function()
				at_control()
				case[1]()
				local v, detail = verdict()
				assert.equal("inconclusive", v)
				assert.equal("the control with the Signify roots " .. case[2], detail)
			end)
		end

		it("inconclusive: the decoy's answer is no HTTP answer, also when OFFLINE follows", function()
			run()
			status(DECOY_B, "ONLINE")
			receive(DECOY_B, "garbage\n")
			assert.equal("inconclusive", verdict())

			verdicts = {}
			status(DECOY_B, "OFFLINE") -- what the close after that verdict brought
			run()
			wait_gap()
			status(DECOY_B, "ONLINE")
			receive(DECOY_B, "\0\1\2")
			status(DECOY_B, "OFFLINE")
			local v, detail = verdict()
			assert.equal("inconclusive", v, "data came: the handshake did not fail")
			assert.truthy(detail:find("no HTTP answer (3 bytes)", 1, true), detail)
		end)

		it("not_pinned on a status line split across reads, after blank lines", function()
			run()
			status(DECOY_B, "ONLINE")
			c4.now_ms = c4.now_ms + 300
			receive(DECOY_B, "\r\n")
			receive(DECOY_B, "HTT")
			receive(DECOY_B, "P/1.1 2")
			settle()
			assert.same({}, verdicts, "not yet a status line")
			receive(DECOY_B, "00 OK\r\n")
			assert.equal("not_pinned", verdict())
		end)

		it("inconclusive when a C4 call raises, and the binding is still closed and cleared", function()
			c4.NetPortOptions = function() error("NetPortOptions failed") end
			run()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.truthy(detail:find("could not be opened: .*NetPortOptions failed"), detail)
			assert.is_true(closed_and_cleared(c4, DECOY_B))
		end)

		it("inconclusive without a CA configuration, with nothing opened", function()
			local ca = http.ca
			http.ca = nil
			finally(function() http.ca = ca end)
			run()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("no CA configuration", detail)
			assert.equal(0, creates(DECOY_B) + creates(CONTROL_B))
		end)

		it("inconclusive for an address that cannot go into a request", function()
			run(IP .. "\r\nX-Injected: 1")
			assert.equal("inconclusive", verdict())
			assert.equal(0, creates(DECOY_B))
		end)

		it("come once, never inside Director's callback, and nothing after counts", function()
			at_control()
			control_answers()
			assert.same({}, verdicts)
			settle()
			assert.same({}, verdicts)
			settle()
			assert.equal(1, #verdicts)
			control_answers()
			status(DECOY_B, "OFFLINE")
			timeout()
			wait_gap()
			settle()
			settle()
			assert.equal(1, #verdicts)
		end)
	end)

	describe("after the verdict", function()
		local endings = {
			pinned = function() at_control(); control_answers() end,
			not_pinned = function() run(); decoy_answers(300) end,
			["inconclusive, a quick decoy"] = function() run(); decoy_answers(40) end,
			["inconclusive, the control silent"] = function() at_control(); timeout() end,
		}
		for name, drive in pairs(endings) do
			it("both 6002 and 6003 are closed and cleared, before the verdict is delivered: " .. name, function()
				drive()
				settle()
				for _, binding in ipairs({ DECOY_B, CONTROL_B }) do
					assert.is_true(closed_and_cleared(c4, binding), "binding " .. binding)
				end
				assert.equal("", c4.network[DECOY_B].address)
				assert.same({}, verdicts)
				settle()
				assert.equal(1, #verdicts)
			end)
		end

		it("a retry starts again with the decoy on a recreated 6002, then the control on a recreated 6003", function()
			at_control()
			timeout()
			assert.equal("inconclusive", verdict())
			verdicts = {}
			c4.now_ms = c4.now_ms + 30000
			run()
			assert.equal(2, creates(DECOY_B), "the decoy first, at once: the last close is 30 s old")
			timeout()
			settle()
			wait_gap()
			assert.equal(2, creates(CONTROL_B))
			assert.same({ DECOY, DECOY }, ca_files(c4, DECOY_B))
			assert.same({ SIGNIFY, SIGNIFY }, ca_files(c4, CONTROL_B))
		end)
	end)

	describe("the application key", function()
		it("never goes out on 6002 or 6003: everything a probe sends is the unkeyed request", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			log.set_debug(true)
			finally(function() log.set_debug(false) end)
			at_control(function() status(DECOY_B, "ONLINE"); status(DECOY_B, "OFFLINE") end)
			control_answers()
			settle()
			settle()
			c4.now_ms = c4.now_ms + 30000
			run()
			decoy_answers(300)
			settle()
			settle()
			assert.equal(2, #verdicts)
			assert.same({ PROBE_REQUEST, PROBE_REQUEST }, sent_on(c4, DECOY_B))
			assert.same({ PROBE_REQUEST }, sent_on(c4, CONTROL_B))
			for _, binding in ipairs({ DECOY_B, CONTROL_B }) do
				for _, data in ipairs(sent_on(c4, binding)) do
					assert.is_nil(data:lower():find("hue-application-key", 1, true))
				end
			end
			assert.equal(0, #c4.transfers)
			for _, line in ipairs(lines) do
				assert.is_nil(line:find(CONFIG, 1, true), "the answer is counted, never logged")
			end
		end)
	end)

	describe("cancel and run again", function()
		it("cancel() during the decoy: closed and cleared, no verdict, its reports ignored", function()
			run()
			netcheck.cancel()
			assert.is_true(closed_and_cleared(c4, DECOY_B))
			status(DECOY_B, "ONLINE")
			assert.same({}, sent_on(c4, DECOY_B), "no request after the cancel")
			timeout()
			settle()
			wait_gap()
			settle()
			assert.same({}, verdicts)
			assert.equal(0, creates(CONTROL_B))
		end)

		it("cancel() between a probe's end and the decision still closes its binding", function()
			run()
			status(DECOY_B, "OFFLINE")
			netcheck.cancel()
			assert.is_true(closed_and_cleared(c4, DECOY_B))
			settle()
			wait_gap()
			assert.equal(0, creates(CONTROL_B))
			assert.same({}, verdicts)
		end)

		it("cancel() during the gap: nothing more opens, and nothing is left to close", function()
			run()
			timeout()
			settle()
			local before = counts(c4, DECOY_B)
			netcheck.cancel()
			assert.same(before, counts(c4, DECOY_B))
			assert.same({}, probe_calls(c4, CONTROL_B))
			wait_gap()
			assert.equal(0, creates(CONTROL_B))
		end)

		it("cancel() drops a verdict not yet delivered", function()
			run()
			decoy_answers(300)
			settle()
			netcheck.cancel()
			settle()
			assert.same({}, verdicts)
		end)

		it("run() replaces a check in flight, which then never answers", function()
			local first = {}
			netcheck.run(IP, function(v) first[#first + 1] = v end)
			run()
			assert.is_true(closed_and_cleared(c4, DECOY_B), "the first check's decoy closed")
			wait_gap()
			decoy_answers(300)
			settle()
			settle()
			assert.same({}, first)
			assert.same({ "not_pinned" }, { verdicts[1] and verdicts[1][1] })
		end)

		it("claims 6002 and 6003 only, with or without a check", function()
			for _, binding in ipairs({ DECOY_B, CONTROL_B, tostring(DECOY_B) }) do
				assert.is_true(netcheck.on_status_changed(binding, PORT, "OFFLINE"))
				assert.is_true(netcheck.on_data(binding, "x"))
			end
			run()
			assert.is_false(netcheck.on_status_changed(STREAM, PORT, "OFFLINE"))
			assert.is_false(netcheck.on_data(STREAM, "HTTP/1.1 200 OK\r\n"))
			status(CONTROL_B, "ONLINE")
			receive(CONTROL_B, HTTP_ANSWER)
			settle()
			settle()
			assert.same({}, verdicts, "the control binding's reports are no decoy's")
		end)
	end)

	describe("an OFFLINE a close may bring", function()
		it("is taken for the closed connection's whenever it comes: a decoy that answers after it is not_pinned",
			function()
				run()
				netcheck.cancel() -- 6002 closed: its report is owed
				run()
				wait_gap()
				status(DECOY_B, "ONLINE")
				status(DECOY_B, "OFFLINE") -- the cancelled connection's, late
				c4.now_ms = c4.now_ms + 300
				receive(DECOY_B, HTTP_ANSWER)
				assert.equal("not_pinned", verdict(), "never a failed decoy, never pinned")
			end)

		it("leaves a decoy whose own OFFLINE was taken so to its timeout", function()
			run()
			netcheck.cancel()
			run()
			wait_gap()
			status(DECOY_B, "OFFLINE")
			settle()
			assert.equal(0, creates(CONTROL_B), "taken for the earlier close's")
			timeout()
			settle()
			wait_gap()
			control_answers()
			local v, detail = verdict()
			assert.equal("pinned", v)
			assert.truthy(detail:find("was silent for 10 s", 1, true), detail)
		end)

		it("is no longer owed STALE_MS after the close", function()
			run()
			netcheck.cancel()
			c4.now_ms = c4.now_ms + STALE_MS
			run()
			status(DECOY_B, "OFFLINE")
			settle()
			wait_gap()
			control_answers()
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
	-- check's decoy by itself): the decoy is opening on 6002.
	local function at_decoy(env, c4)
		env.OnDriverLateInit("DIT_STARTUP")
		answer_identity(c4)
		assert.equal(1, #c4.decoy_transfers, "the C4:url TLS check passed first")
		assert.same({ DECOY_B, IP, "SSL" }, c4.calls_to("CreateNetworkConnection")[1])
		assert.equal("Not connected: network connection TLS check running", env.Properties["Event Stream"])
		return env, c4
	end

	local function settle(c4) return c4.fire_timers_of(1) end
	local function wait_gap(c4)
		c4.now_ms = c4.now_ms + GAP_MS
		return c4.fire_timers_of(GAP_MS)
	end

	-- The decoy silent for 10 s, its close, the gap: the control is opening on 6003.
	local function decoy_silent(c4)
		assert.equal(1, c4.fire_timers_of(TIMEOUT_MS))
		settle(c4)
		wait_gap(c4)
	end

	local function decoy_answers(c4, after)
		c4.net_status(DECOY_B, PORT, "ONLINE")
		c4.now_ms = c4.now_ms + after
		c4.net_receive(DECOY_B, PORT, HTTP_ANSWER)
	end

	local function control_answers(c4)
		c4.net_status(CONTROL_B, PORT, "ONLINE")
		c4.net_receive(CONTROL_B, PORT, HTTP_ANSWER)
	end

	-- The decision, then the verdict.
	local function deliver(c4)
		settle(c4)
		return settle(c4)
	end

	-- The check on a controller that verifies: the decoy silent, the control answering.
	local function check_pinned(c4)
		decoy_silent(c4)
		control_answers(c4)
	end

	local function creates(c4, binding) return #calls_on(c4, "CreateNetworkConnection", binding) end

	-- The stream's connection was created on binding 6001.
	local function stream_created(c4) return creates(c4, STREAM) > 0 end

	local function warned(text)
		for _, line in ipairs(lines) do
			if line:find("[WARN]", 1, true) and line:find(text, 1, true) then return true end
		end
		return false
	end

	-- The C4:url stream's path after a fallback: its address self-check, answered.
	local function answer_self_check(c4)
		local check = c4.last_transfer()
		assert.truthy(check.url:find("/clip/v2/resource/bridge", 1, true), check.url)
		check:respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"' .. BRIDGE_ID .. '"}]}')
	end

	local function web_streams(c4)
		local streams = 0
		for _, t in ipairs(c4.transfers) do
			if t.url:find("/eventstream/clip/v2", 1, true) then streams = streams + 1 end
		end
		return streams
	end

	it("holds the stream until the check answers, and no probe carries the key", function()
		local env, c4 = at_decoy(paired_bridge())
		assert.equal("Paired", env.Properties["Status"], "keyed C4:url requests are not held")
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
		assert.equal(1, creates(c4, DECOY_B), "Connect Event Stream joins the check")
		decoy_silent(c4)
		assert.equal(1, creates(c4, CONTROL_B))
		c4.net_status(CONTROL_B, PORT, "ONLINE")
		assert.same({ PROBE_REQUEST }, sent_on(c4, CONTROL_B))
		assert.is_false(stream_created(c4))
		for _, args in ipairs(c4.calls_to("SendToNetwork")) do
			assert.is_nil(args[3]:find(KEY, 1, true), "nothing sent so far carries the key")
		end
	end)

	it("pinned: both probe bindings cleared, the version remembered, the stream on 6001 with the key", function()
		local env, c4 = at_decoy(paired_bridge())
		check_pinned(c4)
		assert.is_false(stream_created(c4), "the verdict comes from timers")
		deliver(c4)
		assert.equal(c4.director_version, c4.persist.netstream_pinned_on)
		assert.same({ STREAM, IP, "SSL" }, calls_on(c4, "CreateNetworkConnection", STREAM)[1])
		assert.equal(IP .. " (network connection, binding 6001)", env.Properties["Stream Address"])
		-- Director's reports reach the stream on 6001, the probes' only on 6002 and 6003.
		c4.net_status(STREAM, PORT, "ONLINE")
		local stream_sent = sent_on(c4, STREAM)
		assert.equal(1, #stream_sent)
		assert.truthy(stream_sent[1]:find("hue-application-key: " .. KEY, 1, true), "the stream's own request")
		assert.same({}, sent_on(c4, DECOY_B), "the silent decoy never went online")
		assert.same({ PROBE_REQUEST }, sent_on(c4, CONTROL_B))
		assert.equal("", c4.network[DECOY_B].address)
		assert.equal("", c4.network[CONTROL_B].address)
		assert.equal("None", env.Properties["Attention"])
	end)

	it("not_pinned: Web transfer for this run, with the Attention item and the detail logged", function()
		local env, c4 = at_decoy(paired_bridge())
		decoy_answers(c4, 300)
		deliver(c4)
		assert.is_true(closed_and_cleared(c4, DECOY_B))
		assert.is_true(closed_and_cleared(c4, CONTROL_B))
		answer_self_check(c4)
		assert.equal(1, web_streams(c4), "the Web transfer stream")
		assert.is_false(stream_created(c4), "never a keyed network connection")
		assert.equal(0, creates(c4, CONTROL_B), "no control after a decoy that answered")
		assert.equal(NET_ATTENTION, env.Properties["Attention"])
		assert.equal("Network connection", env.Properties["Event Stream Transport"], "the owner's choice is kept")
		assert.equal("Paired", env.Properties["Status"])
		assert.is_nil(c4.persist.netstream_pinned_on)
		assert.is_true(warned("answered HTTP 200 300 ms after ONLINE"), "the detail is logged")

		-- For the rest of the run: no second check, still no network connection.
		env.Properties["Event Stream Transport"] = "Network connection"
		env.OnPropertyChanged("Event Stream Transport")
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
		wait_gap(c4)
		assert.equal(1, creates(c4, DECOY_B))
		assert.is_false(stream_created(c4))
		assert.equal(NET_ATTENTION, env.Properties["Attention"])

		-- The next run checks again: nothing of the fallback is stored.
		local env2, c42 = paired_bridge()
		at_decoy(env2, c42)
		check_pinned(c42)
		deliver(c42)
		assert.is_true(stream_created(c42))
	end)

	it("inconclusive: a decoy answer 40 ms after ONLINE holds the stream, the timing logged, no fallback", function()
		local env, c4 = at_decoy(paired_bridge())
		decoy_answers(c4, 40)
		deliver(c4)
		assert.is_false(stream_created(c4))
		assert.equal(0, web_streams(c4))
		assert.equal("Not connected: network connection TLS check inconclusive (the probe with the decoy CA file "
			.. "answered HTTP 200 40 ms after ONLINE: too soon for a handshake, taken for a reused connection or "
			.. "session); checking again in 30 s", env.Properties["Event Stream"])
		assert.is_true(warned("40 ms after ONLINE"))
		assert.is_nil(env.Properties["Attention"]:find("Event stream", 1, true))
		assert.equal(0, creates(c4, CONTROL_B))
	end)

	it("inconclusive on a version never pinned: nothing keyed; both probes recreated after a backoff", function()
		local env, c4 = at_decoy(paired_bridge())
		decoy_silent(c4)
		c4.fire_timers_of(TIMEOUT_MS) -- the control silent too
		deliver(c4)
		assert.equal("Not connected: network connection TLS check inconclusive (the control with the Signify roots was "
			.. "silent for 10 s); checking again in 30 s", env.Properties["Event Stream"])
		assert.is_false(stream_created(c4))
		assert.is_nil(c4.persist.netstream_pinned_on)

		-- 30 s later: a new check, the decoy first on a recreated 6002; inconclusive again: 60 s.
		c4.now_ms = c4.now_ms + 30000
		assert.equal(1, c4.fire_timers_of(30000))
		assert.equal(2, creates(c4, DECOY_B))
		assert.equal("Not connected: network connection TLS check running", env.Properties["Event Stream"])
		decoy_silent(c4)
		c4.fire_timers_of(TIMEOUT_MS)
		deliver(c4)
		assert.truthy(env.Properties["Event Stream"]:find("checking again in 60 s", 1, true))

		-- Then a conclusive answer lets the stream connect.
		c4.now_ms = c4.now_ms + 60000
		assert.equal(1, c4.fire_timers_of(60000))
		check_pinned(c4)
		deliver(c4)
		assert.is_true(stream_created(c4))
		assert.equal(3, creates(c4, DECOY_B))
		assert.equal(3, creates(c4, CONTROL_B))
		assert.same({ DECOY, DECOY, DECOY }, ca_files(c4, DECOY_B))
		assert.same({ SIGNIFY, SIGNIFY, SIGNIFY }, ca_files(c4, CONTROL_B))
		assert.equal(c4.director_version, c4.persist.netstream_pinned_on)
	end)

	it("inconclusive on a Director version that answered pinned before: the stream connects", function()
		local env, c4 = paired_bridge()
		c4.persist.netstream_pinned_on = c4.director_version
		at_decoy(env, c4)
		decoy_silent(c4)
		c4.fire_timers_of(TIMEOUT_MS)
		deliver(c4)
		assert.is_true(stream_created(c4))
		assert.is_true(warned("answered pinned before, so it passes"))
	end)

	it("inconclusive is held when only another version, or only the C4:url check, answered pinned", function()
		for _, store in ipairs({ { netstream_pinned_on = "3.3.0.100000" }, { tls_pinned_on = "3.4.2.746094" } }) do
			local env, c4 = paired_bridge()
			c4.director_version = "3.4.2.746094"
			for k, v in pairs(store) do c4.persist[k] = v end
			at_decoy(env, c4)
			decoy_answers(c4, 40)
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
		local env, c4 = at_decoy(paired_bridge())
		local before = counts(c4, DECOY_B)
		env.Properties["Bridge IP Address"] = NEW_IP
		env.OnPropertyChanged("Bridge IP Address")
		assert.is_true(closed_and_cleared(c4, DECOY_B, before))
		c4.net_status(DECOY_B, PORT, "OFFLINE") -- what the cancel's close brought
		answer_identity(c4, NEW_IP)
		assert.equal(1, creates(c4, DECOY_B), "1.5 s after the close at the earliest")
		wait_gap(c4)
		assert.same({ DECOY_B, NEW_IP, "SSL" }, calls_on(c4, "CreateNetworkConnection", DECOY_B)[2])
		check_pinned(c4)
		assert.same({ probe_request(NEW_IP) }, sent_on(c4, CONTROL_B))
		deliver(c4)
		assert.same({ STREAM, NEW_IP, "SSL" }, calls_on(c4, "CreateNetworkConnection", STREAM)[1])
	end)

	it("Forget Pairing and OnDriverDestroyed close and clear a probe in flight; the check answers no one", function()
		for _, stop in ipairs({
			function(env) env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" }) end,
			function(env) env.OnDriverDestroyed() end,
		}) do
			local env, c4 = at_decoy(paired_bridge())
			local before = counts(c4, DECOY_B)
			stop(env)
			assert.is_true(closed_and_cleared(c4, DECOY_B, before))
			decoy_answers(c4, 300)
			deliver(c4)
			wait_gap(c4)
			assert.equal(1, creates(c4, DECOY_B))
			assert.equal(0, creates(c4, CONTROL_B))
			assert.is_false(stream_created(c4))
			assert.is_nil(c4.persist.netstream_pinned_on)
		end
	end)

	it("switching the transport during the check starts no stream twice", function()
		local env, c4 = at_decoy(paired_bridge())
		env.Properties["Event Stream Transport"] = "Web transfer"
		env.OnPropertyChanged("Event Stream Transport")
		assert.is_true(closed_and_cleared(c4, DECOY_B), "the check for the other transport is cancelled")
		answer_self_check(c4)
		c4.net_status(DECOY_B, PORT, "OFFLINE")
		c4.fire_timers_of(TIMEOUT_MS)
		deliver(c4)
		wait_gap(c4)
		assert.equal(1, web_streams(c4))
		assert.equal(1, creates(c4, DECOY_B))
		assert.equal(0, creates(c4, CONTROL_B))
		assert.is_false(stream_created(c4))
	end)
end)
