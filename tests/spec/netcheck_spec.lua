-- Issue #317: the TLS self-check of the network connection
-- (bridge/netcheck.lua). The event stream's GET carries the application key
-- on a network connection that is told to verify the bridge against the
-- Signify roots. Before its first keyed connect on a Director version,
-- unkeyed probes: the decoy CA file first, and only after a decoy that
-- failed the Signify roots, each probe on a binding id never used before
-- (6100 up, from a persisted counter). On OS 3.4.3 a refused handshake is
-- silent, and a reused binding id only inherits or ignores [hardware, builds
-- 414 to 416]. The driver connects the stream on "pinned", falls back to Web
-- transfer for the run on "not_pinned", and otherwise asks again after a
-- backoff, sending nothing keyed on the network connection.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local IP = "10.0.2.143"
local NEW_IP = "198.51.100.20"
local STREAM, PORT = 6001, 443
local KEY = "netcheck-spec-key" -- a placeholder; it must never reach a probe binding
local BRIDGE_ID = "001788fffe123abc"
local SIGNIFY, DECOY = "certs/hue_ca_bundle.pem", "certs/decoy_ca.pem"
local GAP_MS, TIMEOUT_MS = 1500, 10000
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

-- The probe binding ids created, in order (the stream's 6001 left out).
local function probe_ids(c4)
	local ids = {}
	for _, args in ipairs(c4.calls_to("CreateNetworkConnection")) do
		if args[1] ~= STREAM then ids[#ids + 1] = args[1] end
	end
	return ids
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

-- The binding's calls end with its close and clear, the only ones it got.
local function closed_once(c4, binding)
	local names, disconnects = probe_calls(c4, binding), 0
	for _, name in ipairs(names) do
		if name == "NetDisconnect" then disconnects = disconnects + 1 end
	end
	return disconnects == 1 and names[#names - 1] == "NetDisconnect" and names[#names] == "clear"
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

	local function ids() return probe_ids(c4) end
	local function current_id()
		local list = ids()
		return list[#list]
	end
	local function status(text, id) c4.net_status(id or current_id(), PORT, text) end
	local function receive(data, id) c4.net_receive(id or current_id(), PORT, data) end
	local function settle() return c4.fire_timers_of(1) end
	local function wait_gap()
		c4.now_ms = c4.now_ms + GAP_MS
		return c4.fire_timers_of(GAP_MS)
	end
	local function timeout() return c4.fire_timers_of(TIMEOUT_MS) end
	local function options_of(binding) return c4.network[binding].ports[PORT].options end

	local function run(ip)
		netcheck.run(ip or IP, function(v, d) verdicts[#verdicts + 1] = { v, d } end)
	end

	-- The open probe goes ONLINE and answers `after` ms later (300 by default).
	local function answers(after, answer)
		status("ONLINE")
		c4.now_ms = c4.now_ms + (after or 300)
		receive(answer or HTTP_ANSWER)
	end

	-- A check at its control: the decoy failed (`fail`, by default silent for
	-- 10 s), the decision, then the gap.
	local function at_control(fail)
		local before = #ids()
		run()
		assert.equal(before + 1, #ids(), "the decoy, on a fresh id")
		if fail then fail() else assert.equal(1, timeout()) end
		assert.equal(1, settle(), "the decision")
		assert.equal(before + 1, #ids(), "not before the gap")
		assert.equal(1, wait_gap())
		assert.equal(before + 2, #ids(), "the control, on another fresh id")
	end

	-- The one verdict, delivered: the decision, then the delivery.
	local function verdict()
		settle()
		settle()
		assert.equal(1, #verdicts, "exactly one verdict")
		return verdicts[1][1], verdicts[1][2]
	end

	describe("probe binding ids", function()
		it("are fresh for every probe, 6100 up: the decoy 6100, the control 6101; the counter moves on first", function()
			at_control()
			answers()
			assert.equal("pinned", verdict())
			assert.same({ 6100, 6101 }, ids())
			assert.equal(6102, c4.persist.netcheck_next_binding)
			-- Each id's counter step is stored before the id is created.
			local stored, created = {}, {}
			for i, call in ipairs(c4.calls) do
				if call.name == "PersistSetValue" and call.args[1] == "netcheck_next_binding" then
					stored[call.args[2] - 1] = i
				elseif call.name == "CreateNetworkConnection" then
					created[call.args[1]] = i
				end
			end
			assert.is_true(stored[6100] < created[6100] and stored[6101] < created[6101])
		end)

		it("are used once each: created, addressed, optioned, connected, closed, cleared, never touched again", function()
			at_control()
			answers()
			assert.equal("pinned", verdict())
			assert.same(seq(OPEN, CLOSE), probe_calls(c4, 6100), "the silent decoy")
			assert.same(seq(OPEN, { "SendToNetwork" }, CLOSE), probe_calls(c4, 6101), "the control")
			local before = #c4.calls
			status("ONLINE", 6100)
			receive(HTTP_ANSWER, 6101)
			status("OFFLINE", 6101)
			timeout()
			wait_gap()
			settle()
			assert.equal(1, #verdicts)
			for i = before + 1, #c4.calls do
				local binding = c4.calls[i].args[1]
				assert.is_true(binding ~= 6100 and binding ~= 6101, c4.calls[i].name)
			end
		end)

		it("are never reused across checks: every attempt takes new ones", function()
			at_control()
			timeout()
			assert.equal("inconclusive", verdict())
			verdicts = {}
			c4.now_ms = c4.now_ms + 30000
			at_control()
			answers()
			assert.equal("pinned", verdict())
			assert.same({ 6100, 6101, 6102, 6103 }, ids())
		end)

		it("are never reused across driver restarts: the counter survives in the store", function()
			at_control()
			timeout()
			assert.equal("inconclusive", verdict())
			-- A restart: the module afresh, the store as it was.
			package.loaded["bridge.netcheck"] = nil
			netcheck = require("bridge.netcheck")
			verdicts = {}
			c4.now_ms = c4.now_ms + 30000
			run()
			assert.equal(6102, current_id())
		end)

		it("keep their own count while the store does not yet return what was written", function()
			c4.PersistGetValue = function() return nil end
			at_control()
			assert.same({ 6100, 6101 }, ids())
		end)

		it("start at 6100 from a counter that is missing or not a whole number from 6100 up", function()
			for _, value in ipairs({ "garbage", 42, 6002, 6100.5, true }) do
				c4, env = fake.install_c4()
				package.loaded["bridge.netcheck"] = nil
				netcheck = require("bridge.netcheck")
				env.OnConnectionStatusChanged = function(b, p, st) netcheck.on_status_changed(b, p, st) end
				c4.persist.netcheck_next_binding = value
				run()
				assert.same({ 6100 }, ids(), tostring(value))
			end
			c4.persist.netcheck_next_binding = "6105"
			netcheck.cancel()
			c4.now_ms = c4.now_ms + GAP_MS
			run()
			assert.equal(6105, current_id(), "a number written as text counts")
		end)

		it("run out past 6999: inconclusive, nothing created, and said once", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			c4.persist.netcheck_next_binding = 7000
			run()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("probe binding ids exhausted", detail)
			verdicts = {}
			run()
			assert.equal("inconclusive", verdict())
			assert.same({}, ids())
			local warnings = 0
			for _, line in ipairs(lines) do
				if line:find("exhausted", 1, true) then warnings = warnings + 1 end
			end
			assert.equal(1, warnings)
		end)

		it("leave the control none when the decoy takes 6999: inconclusive", function()
			c4.persist.netcheck_next_binding = 6999
			run()
			assert.same({ 6999 }, ids())
			timeout()
			settle()
			wait_gap()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("probe binding ids exhausted", detail)
			assert.is_true(closed_once(c4, 6999))
		end)

		it("are not spent on a Director version that answered pinned before: pinned from the memory", function()
			c4.persist.netcheck_pinned_on_v2 = c4.director_version
			run()
			local v, detail = verdict()
			assert.equal("pinned", v)
			assert.equal("Director " .. c4.director_version .. " answered pinned before; no probe", detail)
			assert.same({}, ids())
			assert.is_nil(c4.persist.netcheck_next_binding)
		end)

		it("are spent again after a Director update, from where the counter stands", function()
			c4.persist.netcheck_pinned_on_v2 = "3.3.0.100000"
			c4.persist.netcheck_next_binding = 6120
			run()
			assert.same({ 6120 }, ids())
		end)
	end)

	describe("the probes", function()
		it("start with the decoy: addressed, the decoy CA file, connected; nothing else", function()
			run()
			assert.same(OPEN, probe_calls(c4, 6100))
			assert.same({ 6100, IP, "SSL" }, c4.calls_to("CreateNetworkConnection")[1])
			assert.same({ 6100, IP }, c4.calls_to("SetBindingAddress")[1])
			assert.same({ 6100, PORT }, c4.calls_to("NetConnect")[1])
			local expected = netstream.port_options()
			expected.CACERTFILE = DECOY
			assert.same(expected, options_of(6100))
			assert.is_nil(c4.network[STREAM])
			assert.equal(0, #c4.transfers, "no C4:url request")
		end)

		it("send the unkeyed request once ONLINE, once per probe", function()
			run()
			assert.same({}, sent_on(c4, 6100))
			status("ONLINE")
			status("ONLINE")
			assert.same({ PROBE_REQUEST }, sent_on(c4, 6100))
		end)

		it("open the control only after the decoy failed; no id ever gets both CA files", function()
			at_control()
			answers()
			assert.equal("pinned", verdict())
			assert.same({ DECOY }, ca_files(c4, 6100))
			assert.same({ SIGNIFY }, ca_files(c4, 6101))
			assert.same(netstream.port_options(), options_of(6101), "the stream's own options")
		end)

		it("act on a probe's end from a timer: nothing is closed inside Director's callback", function()
			run()
			answers()
			assert.same(seq(OPEN, { "SendToNetwork" }), probe_calls(c4, 6100), "nothing closed inside the callback")
			assert.equal(1, settle())
			assert.is_true(closed_once(c4, 6100))
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
			assert.same({ 6100 }, ids(), "fired with the clock not moved on: nothing created")
			c4.now_ms = closed + GAP_MS - 1
			assert.equal(1, c4.fire_timers_of(GAP_MS))
			assert.same({ 6100 }, ids(), "1 ms short")
			c4.now_ms = closed + GAP_MS
			assert.equal(1, settle())
			assert.same({ 6100, 6101 }, ids())
		end)

		it("wait 1.5 s after the last close for a new check too", function()
			run()
			netcheck.cancel()
			run()
			assert.same({ 6100 }, ids(), "not yet")
			assert.equal(1, wait_gap())
			assert.same({ 6100, 6101 }, ids())
		end)

		it("give the decoy the stream's options with the decoy CA file and nothing else changed", function()
			local expected = netstream.port_options()
			expected.CACERTFILE = DECOY
			assert.same(expected, netcheck.port_options())
			assert.equal(require("bridge.tlscheck").DECOY_CA, netcheck.port_options().CACERTFILE)
			netcheck.port_options().VERIFY_MODE = "none"
			assert.equal("peer", netcheck.port_options().VERIFY_MODE)
			assert.equal(SIGNIFY, netstream.port_options().CACERTFILE)
		end)
	end)

	describe("verdicts", function()
		it("pinned: the decoy silent for 10 s, then the Signify roots answer", function()
			at_control()
			answers()
			local v, detail = verdict()
			assert.equal("pinned", v)
			assert.equal("the probe with the decoy CA file was silent for 10 s; the Signify roots answered", detail)
		end)

		local failures = {
			["OFFLINE before ONLINE"] = { function() status("OFFLINE") end, "went OFFLINE before ONLINE" },
			["ONLINE, then OFFLINE"] = { function() status("ONLINE"); status("OFFLINE") end,
				"went ONLINE, then OFFLINE without an answer" },
			["ONLINE, then no answer"] = { function() status("ONLINE"); timeout() end,
				"went ONLINE, then gave no answer within 10 s" },
		}
		for name, case in pairs(failures) do
			it("pinned: the decoy failed (" .. name .. "), then the control answers", function()
				at_control(case[1])
				answers()
				local v, detail = verdict()
				assert.equal("pinned", v)
				assert.truthy(detail:find(case[2], 1, true), detail)
			end)
		end

		for _, line in ipairs({ "HTTP/1.1 200 OK", "HTTP/1.1 401 Unauthorized", "HTTP/1.0 404 Not Found" }) do
			it("not_pinned: the decoy answers 300 ms after ONLINE, whatever the status, and no control: " .. line,
				function()
					run()
					answers(300, line .. "\r\nContent-Length: 0\r\n\r\n")
					local v, detail = verdict()
					assert.equal("not_pinned", v)
					assert.equal("the probe with the decoy CA file answered HTTP " .. line:match("(%d%d%d)")
						.. " 300 ms after ONLINE", detail)
					wait_gap()
					assert.same({ 6100 }, ids())
				end)
		end

		it("inconclusive: the decoy answers only 40 ms after ONLINE, the timing in the detail, and no control", function()
			run()
			answers(40)
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("the probe with the decoy CA file answered HTTP 200 40 ms after ONLINE: too soon for a "
				.. "handshake, taken for a reused connection or session", detail)
			wait_gap()
			assert.same({ 6100 }, ids())
		end)

		it("draws the line at 150 ms: 149 ms is too soon, 150 ms is not", function()
			run()
			answers(149)
			assert.equal("inconclusive", verdict())
			verdicts = {}
			run()
			wait_gap()
			answers(150)
			assert.equal("not_pinned", verdict())
		end)

		it("inconclusive: a decoy answer with no ONLINE before it", function()
			run()
			receive(HTTP_ANSWER)
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.truthy(detail:find("answered HTTP 200 before ONLINE", 1, true), detail)
		end)

		local control_failures = {
			["silent for 10 s"] = { function() timeout() end, "was silent for 10 s" },
			["OFFLINE before ONLINE"] = { function() status("OFFLINE") end, "went OFFLINE before ONLINE" },
			["ONLINE, then no answer"] = { function() status("ONLINE"); timeout() end,
				"went ONLINE, then gave no answer within 10 s" },
			["no HTTP answer"] = { function() status("ONLINE"); receive("SSH-2.0-OpenSSH_9.6\r\n") end,
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
			status("ONLINE")
			receive("garbage\n")
			assert.equal("inconclusive", verdict())
			verdicts = {}
			run()
			wait_gap()
			status("ONLINE")
			receive("\0\1\2")
			status("OFFLINE")
			local v, detail = verdict()
			assert.equal("inconclusive", v, "data came: the handshake did not fail")
			assert.truthy(detail:find("no HTTP answer (3 bytes)", 1, true), detail)
		end)

		it("not_pinned on a status line split across reads, after blank lines", function()
			run()
			status("ONLINE")
			c4.now_ms = c4.now_ms + 300
			receive("\r\n")
			receive("HTT")
			receive("P/1.1 2")
			settle()
			assert.same({}, verdicts, "not yet a status line")
			receive("00 OK\r\n")
			assert.equal("not_pinned", verdict())
		end)

		it("inconclusive when a C4 call raises, and the id is still closed and cleared", function()
			c4.NetPortOptions = function() error("NetPortOptions failed") end
			run()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.truthy(detail:find("could not be opened: .*NetPortOptions failed"), detail)
			assert.is_true(closed_once(c4, 6100))
		end)

		it("inconclusive without a CA configuration, with no id spent", function()
			local ca = http.ca
			http.ca = nil
			finally(function() http.ca = ca end)
			run()
			local v, detail = verdict()
			assert.equal("inconclusive", v)
			assert.equal("no CA configuration", detail)
			assert.same({}, ids())
			assert.is_nil(c4.persist.netcheck_next_binding)
		end)

		it("inconclusive for an address that cannot go into a request", function()
			run(IP .. "\r\nX-Injected: 1")
			assert.equal("inconclusive", verdict())
			assert.same({}, ids())
		end)

		it("come once, never inside Director's callback, and nothing after counts", function()
			at_control()
			answers()
			assert.same({}, verdicts)
			settle()
			assert.same({}, verdicts)
			settle()
			assert.equal(1, #verdicts)
			answers()
			timeout()
			wait_gap()
			settle()
			settle()
			assert.equal(1, #verdicts)
		end)
	end)

	describe("after the verdict", function()
		local endings = {
			pinned = function() at_control(); answers() end,
			not_pinned = function() run(); answers(300) end,
			["inconclusive, a quick decoy"] = function() run(); answers(40) end,
			["inconclusive, the control silent"] = function() at_control(); timeout() end,
		}
		for name, drive in pairs(endings) do
			it("every probe id of the check is closed and cleared, once, before the verdict: " .. name, function()
				drive()
				settle()
				for _, id in ipairs(ids()) do
					assert.is_true(closed_once(c4, id), "binding " .. id)
					assert.equal("", c4.network[id].address)
				end
				assert.same({}, verdicts)
				settle()
				assert.equal(1, #verdicts)
			end)
		end
	end)

	describe("the application key", function()
		it("never goes out on a probe id: everything a probe sends is the unkeyed request", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			log.set_debug(true)
			finally(function() log.set_debug(false) end)
			at_control(function() status("ONLINE"); status("OFFLINE") end)
			answers()
			settle()
			settle()
			c4.now_ms = c4.now_ms + 30000
			c4.persist.netcheck_pinned_on_v2 = nil
			run()
			answers(300)
			settle()
			settle()
			assert.equal(2, #verdicts)
			local sent = {}
			for _, id in ipairs(ids()) do
				for _, data in ipairs(sent_on(c4, id)) do sent[#sent + 1] = data end
			end
			assert.same({ PROBE_REQUEST, PROBE_REQUEST, PROBE_REQUEST }, sent)
			for _, data in ipairs(sent) do
				assert.is_nil(data:lower():find("hue-application-key", 1, true))
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
			assert.is_true(closed_once(c4, 6100))
			status("ONLINE", 6100)
			assert.same({}, sent_on(c4, 6100), "no request after the cancel")
			timeout()
			settle()
			wait_gap()
			settle()
			assert.same({}, verdicts)
			assert.same({ 6100 }, ids())
		end)

		it("cancel() between a probe's end and the decision still closes its id", function()
			run()
			status("OFFLINE")
			netcheck.cancel()
			assert.is_true(closed_once(c4, 6100))
			settle()
			wait_gap()
			assert.same({ 6100 }, ids())
			assert.same({}, verdicts)
		end)

		it("cancel() during the gap: nothing more opens, and nothing is closed twice", function()
			run()
			timeout()
			settle()
			netcheck.cancel()
			assert.is_true(closed_once(c4, 6100))
			wait_gap()
			assert.same({ 6100 }, ids())
		end)

		it("cancel() drops a verdict not yet delivered", function()
			run()
			answers(300)
			settle()
			netcheck.cancel()
			settle()
			assert.same({}, verdicts)
		end)

		it("run() replaces a check in flight, which then never answers", function()
			local first = {}
			netcheck.run(IP, function(v) first[#first + 1] = v end)
			run()
			assert.is_true(closed_once(c4, 6100), "the first check's decoy closed")
			wait_gap()
			assert.same({ 6100, 6101 }, ids())
			answers(300)
			settle()
			settle()
			assert.same({}, first)
			assert.same({ "not_pinned" }, { verdicts[1] and verdicts[1][1] })
		end)

		it("claims 6100 to 6999 only, and a closed probe's reports are ignored", function()
			for _, binding in ipairs({ 6100, 6999, "6500" }) do
				assert.is_true(netcheck.on_status_changed(binding, PORT, "OFFLINE"))
				assert.is_true(netcheck.on_data(binding, "x"))
			end
			for _, binding in ipairs({ STREAM, 6002, 6003, 6099, 7000 }) do
				assert.is_false(netcheck.on_status_changed(binding, PORT, "OFFLINE"))
				assert.is_false(netcheck.on_data(binding, "HTTP/1.1 200 OK\r\n"))
			end
			run()
			timeout()
			settle()
			wait_gap()
			receive(HTTP_ANSWER, 6100) -- the closed decoy's: no answer of the control's
			status("OFFLINE", 6100)
			settle()
			settle()
			assert.same({}, verdicts)
			answers()
			assert.equal("pinned", verdict())
		end)
	end)

	describe("remember_pinned and pinned_before", function()
		it("persist the running Director version, unencrypted, under netcheck_pinned_on_v2, apart from tlscheck's", function()
			assert.equal(c4.director_version, netcheck.remember_pinned())
			assert.equal(c4.director_version, c4.persist.netcheck_pinned_on_v2)
			assert.is_nil(c4.persist.tls_pinned_on)
			assert.same({ "netcheck_pinned_on_v2", c4.director_version, false }, c4.calls_to("PersistSetValue")[1])
		end)

		it("is false where the check never answered pinned, whatever the C4:url check answered", function()
			c4.persist.tls_pinned_on = c4.director_version
			assert.is_false(netcheck.pinned_before())
		end)

		it("is true when an earlier run persisted the running version", function()
			c4.persist.netcheck_pinned_on_v2 = c4.director_version
			assert.is_true(netcheck.pinned_before())
		end)

		it("is false after a Director update, until the new version answers pinned", function()
			c4.persist.netcheck_pinned_on_v2 = "3.3.0.100000"
			assert.is_false(netcheck.pinned_before())
			netcheck.remember_pinned()
			assert.is_true(netcheck.pinned_before())
		end)

		it("is false, and remembers nothing, when the version cannot be read", function()
			c4.persist.netcheck_pinned_on_v2 = "3.4.2.746094"
			c4.director_version = nil
			assert.is_nil(netcheck.remember_pinned())
			assert.equal("3.4.2.746094", c4.persist.netcheck_pinned_on_v2, "nothing stored")
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

	it("retry_delay doubles from RETRY_MIN up to RETRY_MAX, an hour", function()
		local delays = {}
		for attempt = 1, 9 do delays[attempt] = netcheck.retry_delay(attempt) end
		assert.same({ 30, 60, 120, 240, 480, 960, 1920, 3600, 3600 }, delays)
	end)
end)

describe("Hue Bridge driver: the network connection's TLS check (#317)", function()
	local lines

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
	end)

	-- A bridge driver paired with the placeholder bridge, before late init;
	-- `store` is an earlier run's (a restart keeps the project's store).
	local function paired_bridge(props, store)
		local all = { ["Bridge IP Address"] = IP }
		for k, v in pairs(props or {}) do all[k] = v end
		local env, c4 = fake.load_driver("hue_bridge", all)
		for k, v in pairs(store or {}) do c4.persist[k] = v end
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

	local function settle(c4) return c4.fire_timers_of(1) end
	local function wait_gap(c4)
		c4.now_ms = c4.now_ms + GAP_MS
		return c4.fire_timers_of(GAP_MS)
	end
	local function current_id(c4)
		local ids = probe_ids(c4)
		return ids[#ids]
	end

	-- Late init and the identity check (the fake refuses the C4:url TLS
	-- check's decoy by itself): the decoy is opening on fresh id `id`.
	local function at_decoy(env, c4, id)
		env.OnDriverLateInit("DIT_STARTUP")
		answer_identity(c4)
		assert.equal(1, #c4.decoy_transfers, "the C4:url TLS check passed first")
		assert.equal(id or 6100, current_id(c4))
		assert.equal("Not connected: network connection TLS check running", env.Properties["Event Stream"])
		return env, c4
	end

	-- The decoy silent for 10 s, the decision, the gap: the control is opening.
	local function decoy_silent(c4)
		local decoy = current_id(c4)
		assert.equal(1, c4.fire_timers_of(TIMEOUT_MS))
		settle(c4)
		wait_gap(c4)
		assert.is_true(current_id(c4) > decoy, "the control on a fresh id")
	end

	-- The open probe goes ONLINE and answers `after` ms later.
	local function probe_answers(c4, after)
		local id = current_id(c4)
		c4.net_status(id, PORT, "ONLINE")
		c4.now_ms = c4.now_ms + (after or 300)
		c4.net_receive(id, PORT, HTTP_ANSWER)
	end

	-- The decision, then the verdict.
	local function deliver(c4)
		settle(c4)
		return settle(c4)
	end

	-- The check on a controller that verifies: the decoy silent, the control answering.
	local function check_pinned(c4)
		decoy_silent(c4)
		probe_answers(c4)
	end

	-- The stream's connection was created on binding 6001.
	local function stream_created(c4) return #calls_on(c4, "CreateNetworkConnection", STREAM) > 0 end

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
		assert.same({ 6100 }, probe_ids(c4), "Connect Event Stream joins the check")
		decoy_silent(c4)
		c4.net_status(6101, PORT, "ONLINE")
		assert.same({ PROBE_REQUEST }, sent_on(c4, 6101))
		assert.is_false(stream_created(c4))
		for _, args in ipairs(c4.calls_to("SendToNetwork")) do
			assert.is_nil(args[3]:find(KEY, 1, true), "nothing sent so far carries the key")
		end
	end)

	it("pinned: the probe ids closed and cleared, the version remembered, the stream on 6001 with the key", function()
		local env, c4 = at_decoy(paired_bridge())
		check_pinned(c4)
		assert.is_false(stream_created(c4), "the verdict comes from timers")
		deliver(c4)
		assert.equal(c4.director_version, c4.persist.netcheck_pinned_on_v2)
		assert.equal(6102, c4.persist.netcheck_next_binding)
		assert.same({ 6100, 6101 }, probe_ids(c4))
		assert.is_true(closed_once(c4, 6100) and closed_once(c4, 6101))
		assert.same({ STREAM, IP, "SSL" }, calls_on(c4, "CreateNetworkConnection", STREAM)[1])
		assert.equal(IP .. " (network connection, binding 6001)", env.Properties["Stream Address"])
		c4.net_status(STREAM, PORT, "ONLINE")
		local stream_sent = sent_on(c4, STREAM)
		assert.equal(1, #stream_sent)
		assert.truthy(stream_sent[1]:find("hue-application-key: " .. KEY, 1, true), "the stream's own request")
		assert.same({}, sent_on(c4, 6100), "the silent decoy never went online")
		assert.same({ PROBE_REQUEST }, sent_on(c4, 6101))
		assert.equal("None", env.Properties["Attention"])
	end)

	it("a restart on the same Director version spends no id; one on a new version probes with the next ids",
		function()
			local _, c4 = at_decoy(paired_bridge())
			check_pinned(c4)
			deliver(c4)

			local env2, c42 = paired_bridge(nil, c4.persist)
			env2.OnDriverLateInit("DIT_STARTUP")
			answer_identity(c42)
			deliver(c42)
			assert.same({}, probe_ids(c42), "answered from the memory")
			assert.is_true(stream_created(c42))
			assert.equal(6102, c42.persist.netcheck_next_binding, "no id spent")

			local env3, c43 = paired_bridge(nil, c42.persist)
			c43.director_version = "3.4.3.800000"
			at_decoy(env3, c43, 6102)
		end)

	it("not_pinned: Web transfer for this run, with the Attention item and the detail logged", function()
		local env, c4 = at_decoy(paired_bridge())
		probe_answers(c4, 300)
		deliver(c4)
		assert.is_true(closed_once(c4, 6100))
		answer_self_check(c4)
		assert.equal(1, web_streams(c4), "the Web transfer stream")
		assert.is_false(stream_created(c4), "never a keyed network connection")
		assert.same({ 6100 }, probe_ids(c4), "no control after a decoy that answered")
		assert.equal(NET_ATTENTION, env.Properties["Attention"])
		assert.equal("Network connection", env.Properties["Event Stream Transport"], "the owner's choice is kept")
		assert.equal("Paired", env.Properties["Status"])
		assert.is_nil(c4.persist.netcheck_pinned_on_v2)
		assert.is_true(warned("answered HTTP 200 300 ms after ONLINE"), "the detail is logged")

		-- For the rest of the run: no second check, still no network connection.
		env.Properties["Event Stream Transport"] = "Network connection"
		env.OnPropertyChanged("Event Stream Transport")
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
		wait_gap(c4)
		assert.same({ 6100 }, probe_ids(c4))
		assert.is_false(stream_created(c4))
		assert.equal(NET_ATTENTION, env.Properties["Attention"])

		-- The next run checks again, on the next id: nothing of the fallback is stored.
		local env2, c42 = paired_bridge(nil, c4.persist)
		at_decoy(env2, c42, 6101)
		check_pinned(c42)
		deliver(c42)
		assert.is_true(stream_created(c42))
	end)

	it("inconclusive: a decoy answer 40 ms after ONLINE holds the stream, the timing logged, no fallback", function()
		local env, c4 = at_decoy(paired_bridge())
		probe_answers(c4, 40)
		deliver(c4)
		assert.is_false(stream_created(c4))
		assert.equal(0, web_streams(c4))
		assert.equal("Not connected: network connection TLS check inconclusive (the probe with the decoy CA file "
			.. "answered HTTP 200 40 ms after ONLINE: too soon for a handshake, taken for a reused connection or "
			.. "session); checking again in 30 s", env.Properties["Event Stream"])
		assert.is_true(warned("40 ms after ONLINE"))
		assert.is_nil(env.Properties["Attention"]:find("Event stream", 1, true))
		assert.same({ 6100 }, probe_ids(c4))
	end)

	it("inconclusive on a version never pinned: nothing keyed; every retry on fresh ids", function()
		local env, c4 = at_decoy(paired_bridge())
		decoy_silent(c4)
		c4.fire_timers_of(TIMEOUT_MS) -- the control silent too
		deliver(c4)
		assert.equal("Not connected: network connection TLS check inconclusive (the control with the Signify roots was "
			.. "silent for 10 s); checking again in 30 s", env.Properties["Event Stream"])
		assert.is_false(stream_created(c4))
		assert.is_nil(c4.persist.netcheck_pinned_on_v2)

		c4.now_ms = c4.now_ms + 30000
		assert.equal(1, c4.fire_timers_of(30000))
		assert.equal(6102, current_id(c4), "the retry's decoy on a fresh id")
		decoy_silent(c4)
		c4.fire_timers_of(TIMEOUT_MS)
		deliver(c4)
		assert.truthy(env.Properties["Event Stream"]:find("checking again in 60 s", 1, true))

		c4.now_ms = c4.now_ms + 60000
		assert.equal(1, c4.fire_timers_of(60000))
		check_pinned(c4)
		deliver(c4)
		assert.is_true(stream_created(c4))
		assert.same({ 6100, 6101, 6102, 6103, 6104, 6105 }, probe_ids(c4))
		for _, id in ipairs(probe_ids(c4)) do
			assert.same({ id % 2 == 0 and DECOY or SIGNIFY }, ca_files(c4, id), "one probe, one CA file per id")
			assert.is_true(closed_once(c4, id))
		end
		assert.equal(c4.director_version, c4.persist.netcheck_pinned_on_v2)
	end)

	it("inconclusive is held when only another version, or only the C4:url check, answered pinned", function()
		for _, store in ipairs({ { netcheck_pinned_on_v2 = "3.3.0.100000" }, { tls_pinned_on = "3.4.2.746094" } }) do
			local env, c4 = paired_bridge(nil, store)
			c4.director_version = "3.4.2.746094"
			at_decoy(env, c4)
			probe_answers(c4, 40)
			deliver(c4)
			assert.is_false(stream_created(c4))
			assert.truthy(env.Properties["Event Stream"]:find("inconclusive", 1, true))
		end
	end)

	it("exhausted ids: inconclusive, the stream held, nothing created", function()
		local env, c4 = paired_bridge(nil, { netcheck_next_binding = 7000 })
		env.OnDriverLateInit("DIT_STARTUP")
		answer_identity(c4)
		deliver(c4)
		assert.same({}, probe_ids(c4))
		assert.is_false(stream_created(c4))
		assert.truthy(env.Properties["Event Stream"]:find("probe binding ids exhausted", 1, true))
	end)

	it("a Web transfer owner never sees a probe", function()
		local env, c4 = paired_bridge({ ["Event Stream Transport"] = "Web transfer" })
		env.OnDriverLateInit("DIT_STARTUP")
		answer_identity(c4)
		assert.truthy(c4.last_transfer().url:find("/clip/v2/resource/bridge", 1, true), "straight to the C4:url path")
		assert.equal(0, #c4.calls_to("CreateNetworkConnection"))
	end)

	it("an address change cancels the check: closed and cleared, then the new address on a fresh id", function()
		local env, c4 = at_decoy(paired_bridge())
		env.Properties["Bridge IP Address"] = NEW_IP
		env.OnPropertyChanged("Bridge IP Address")
		assert.is_true(closed_once(c4, 6100))
		answer_identity(c4, NEW_IP)
		assert.same({ 6100 }, probe_ids(c4), "1.5 s after the close at the earliest")
		wait_gap(c4)
		assert.same({ 6101, NEW_IP, "SSL" }, calls_on(c4, "CreateNetworkConnection", 6101)[1])
		check_pinned(c4)
		assert.same({ probe_request(NEW_IP) }, sent_on(c4, 6102))
		deliver(c4)
		assert.same({ STREAM, NEW_IP, "SSL" }, calls_on(c4, "CreateNetworkConnection", STREAM)[1])
	end)

	it("Forget Pairing and OnDriverDestroyed close and clear a probe in flight; the check answers no one", function()
		for _, stop in ipairs({
			function(env) env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" }) end,
			function(env) env.OnDriverDestroyed() end,
		}) do
			local env, c4 = at_decoy(paired_bridge())
			stop(env)
			assert.is_true(closed_once(c4, 6100))
			probe_answers(c4, 300)
			deliver(c4)
			wait_gap(c4)
			assert.same({ 6100 }, probe_ids(c4))
			assert.is_false(stream_created(c4))
			assert.is_nil(c4.persist.netcheck_pinned_on_v2)
		end
	end)

	it("switching the transport during the check starts no stream twice", function()
		local env, c4 = at_decoy(paired_bridge())
		env.Properties["Event Stream Transport"] = "Web transfer"
		env.OnPropertyChanged("Event Stream Transport")
		assert.is_true(closed_once(c4, 6100), "the check for the other transport is cancelled")
		answer_self_check(c4)
		c4.net_status(6100, PORT, "OFFLINE")
		c4.fire_timers_of(TIMEOUT_MS)
		deliver(c4)
		wait_gap(c4)
		assert.equal(1, web_streams(c4))
		assert.same({ 6100 }, probe_ids(c4))
		assert.is_false(stream_created(c4))
	end)
end)
