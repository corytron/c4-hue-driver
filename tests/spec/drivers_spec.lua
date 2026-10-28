-- Driver-level tests: each driver loads against the fake runtime and its
-- entry points behave as Composer would see them.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local CONFIG = '{"name":"Hue Bridge","swversion":"1968096020","bridgeid":"001788FFFE25B8F8","modelid":"BSB002"}'
local SHIPPED = "certs/hue_ca_bundle.pem"
-- For a bridge at 192.0.2.10: the self-check and the stream each use their
-- own spelling of the address so they get their own C4:url queues. The
-- stream rotates over a family of seven spellings (altaddr.stream_family),
-- one per connection, starting from the first after a fresh pairing.
local CHECK_URL = "https://192.00.02.10/clip/v2/resource/bridge"
local STREAM_URL = "https://192.000.002.10/eventstream/clip/v2"
local STREAM_URL_2 = "https://192.000.02.10/eventstream/clip/v2"
local STREAM_URL_3 = "https://192.000.2.10/eventstream/clip/v2"
local DOTTED_STREAM_URL = "https://192.0.2.10/eventstream/clip/v2"
local function rotating(spelling, index)
	return string.format("%s (own queue, spelling %d of 7)", spelling, index)
end

local function quiet()
	log.sink = function() end
end

-- A signed dev loop command, as tools/devctl.py run queues it: the
-- development handlers answer nothing else (docs/dev-loop.md).
local function signed(command, params)
	return require("common.devloop").execute(command, params)
end

local function paired_driver(extra)
	-- The C4:url stream (Web transfer); the network-connection stream has its own specs.
	local props = { ["Event Stream Transport"] = "Web transfer", ["Bridge IP Address"] = "192.0.2.10" }
	for k, v in pairs(extra or {}) do props[k] = v end
	local env, c4 = fake.load_driver("hue_bridge", props)
	c4.persist.hue_app_key = "abc123"
	c4.persist.hue_bridge_id = "001788fffe25b8f8"
	return env, c4
end

-- The identity check that precedes every keyed request: GET /api/0/config
-- without a key, answered with the paired bridge id unless told otherwise.
local function answer_identity(c4, bridgeid)
	local t = c4.last_transfer()
	if t and t.url:find("/api/0/config", 1, true) and not t.answered_identity then
		t.answered_identity = true
		assert.is_nil(t.headers["hue-application-key"], "the identity check carries no key")
		t:respond(200, '{"bridgeid":"' .. (bridgeid or "001788FFFE25B8F8") .. '","modelid":"BSB003","name":"Hue",'
			.. '"swversion":"1968096020","apiversion":"1.68.0"}')
	end
	return t
end

-- Answer the startup self-check (the GET via the check spelling) so the
-- stream can open. Returns the check transfer.
local function answer_check(c4, ok)
	answer_identity(c4)
	local t = c4.last_transfer()
	assert(t and t.url == CHECK_URL, "expected the self-check request, got " .. tostring(t and t.url))
	if ok == false then
		t:done(6, "Couldn't resolve host name")
	else
		t:respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"001788fffe25b8f8"}]}')
	end
	return t
end

describe("Hue Bridge driver", function()
	before_each(quiet)

	it("asks for an IP address when none is set", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
			["Bridge IP Address"] = "" })
		env.OnDriverInit("DIT_ADDING")
		env.OnDriverLateInit("DIT_ADDING")
		assert.equal("Enter the bridge IP address", env.Properties["Status"])
		assert.equal("1", env.Properties["Driver Version"])
		assert.equal("Not paired", env.Properties["Event Stream"])
		assert.equal(0, #c4.transfers)
	end)

	it("asks for pairing once a valid IP is entered", function()
		local env = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
			["Bridge IP Address"] = "" })
		env.OnDriverLateInit("DIT_STARTUP")
		env.Properties["Bridge IP Address"] = "192.0.2.10"
		env.OnPropertyChanged("Bridge IP Address")
		assert.truthy(env.Properties["Status"]:find("^Not paired"))
	end)

	it("ignores an invalid IP", function()
		local env = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
			["Bridge IP Address"] = "not-an-ip" })
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal("Enter the bridge IP address", env.Properties["Status"])
	end)

	it("#317: streams on a network connection by default, with no address spelling or self-check", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		assert.equal("Network connection", env.Properties["Event Stream Transport"], "driver.xml default")
		env.OnDriverLateInit("DIT_STARTUP")
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		c4.transfers[1]:respond(200, CONFIG)
		c4.transfers[2]:respond(200, '[{"success":{"username":"abc123","clientkey":"00"}}]')
		answer_identity(c4)
		assert.equal("Paired", env.Properties["Status"])
		-- The network connection's TLS check comes first (bridge/netcheck.lua):
		-- the decoy CA file on fresh binding 6100 gets silence for 10 s (a
		-- refused handshake, OS 3.4.3); 1.5 s after its close the Signify roots
		-- answer on fresh binding 6101. Each step and the verdict run from timers.
		c4.fire_timers_of(10000)
		c4.fire_timers_of(1)
		c4.now_ms = c4.now_ms + 1500
		c4.fire_timers_of(1500)
		c4.net_status(6101, 443, "ONLINE")
		c4.net_receive(6101, 443, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
		c4.fire_timers_of(1)
		c4.fire_timers_of(1)
		for _, t in ipairs(c4.transfers) do
			assert.is_nil(t.url:find("/eventstream/", 1, true), "no C4:url stream: " .. t.url)
			assert.is_nil(t.url:find("192.00", 1, true), "no padded self-check: " .. t.url)
		end
		local created = c4.calls_to("CreateNetworkConnection")
		assert.equal(3, #created, "the decoy, the control, then the stream")
		assert.same({ 6100, "192.0.2.10", "SSL" }, { created[1][1], created[1][2], created[1][3] })
		assert.same({ 6101, "192.0.2.10", "SSL" }, { created[2][1], created[2][2], created[2][3] })
		assert.same({ 6001, "192.0.2.10", "SSL" }, { created[3][1], created[3][2], created[3][3] })
		assert.equal(3, #c4.calls_to("NetConnect"))
		assert.equal("192.0.2.10 (network connection, binding 6001)", env.Properties["Stream Address"])

		-- Forget Pairing leaves no address on the binding.
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" })
		local addr = c4.calls_to("SetBindingAddress")
		assert.same({ 6001, "" }, { addr[#addr][1], addr[#addr][2] })
	end)

	it("pairs from the Composer action, self-checks, then streams on the padded spelling", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
			["Bridge IP Address"] = "192.0.2.10" })
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal(0, #c4.transfers, "no network activity before pairing")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		c4.transfers[1]:respond(200, CONFIG)
		assert.equal("Hue Bridge v2, square (BSB002)", env.Properties["Bridge Model"])

		c4.transfers[2]:respond(200, '[{"error":{"type":101,"description":"link button not pressed"}}]')
		assert.truthy(env.Properties["Status"]:find("link button", 1, true))
		assert.equal(2, #c4.transfers, "no stream while unpaired")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		c4.transfers[3]:respond(200, CONFIG)
		c4.transfers[4]:respond(200, '[{"success":{"username":"abc123","clientkey":"00"}}]')
		-- Not "Paired" before the identity check has passed (#236).
		assert.equal("Checking the bridge at 192.0.2.10 before anything is sent", env.Properties["Status"])
		assert.equal("001788fffe25b8f8", env.Properties["Bridge ID"])

		answer_identity(c4)
		assert.equal("Paired", env.Properties["Status"])
		local check = c4.transfers[6]
		assert.equal(CHECK_URL, check.url, "self-check before the stream")
		assert.equal("abc123", check.headers["hue-application-key"])
		assert.equal(6, #c4.transfers, "the stream waits for the self-check")
		answer_check(c4)

		local s = c4.transfers[7]
		assert.equal(STREAM_URL, s.url)
		assert.equal("abc123", s.headers["hue-application-key"])
		assert.equal(SHIPPED, s.options.ssl_cabundle)
		assert.is_false(s.options.ssl_verify_host)
		assert.equal(3600, s.options.timeout, "driver.xml default")
		assert.equal(rotating("192.000.002.10", 1), env.Properties["Stream Address"])
		assert.equal("192.000.002.10", c4.persist.hue_stream_spelling, "the spelling in use is persisted")
	end)

	it("moves the stream to the next spelling on every reconnect so it never queues behind the old one", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		local first = c4.last_transfer()
		assert.equal(STREAM_URL, first.url)

		-- A restart (here: a timeout change) abandons the first transfer, which
		-- Cancel() does not end, so the second one takes the next spelling.
		env.Properties["Stream Timeout (s)"] = "900"
		env.OnPropertyChanged("Stream Timeout (s)")
		assert.is_true(first.cancelled)
		local second = c4.last_transfer()
		assert.equal(STREAM_URL_2, second.url)
		assert.equal("abc123", second.headers["hue-application-key"])
		assert.equal(rotating("192.000.02.10", 2), env.Properties["Stream Address"])
		assert.equal("192.000.02.10", c4.persist.hue_stream_spelling)

		-- At most two stream transfers are open at once (stream.MAX_ABANDONED):
		-- with the first still open, Disconnect and Connect abandon the second
		-- and the third waits for one of them to close (security review
		-- 2026-10-25, finding 5). The spelling moves on only for a transfer
		-- that opens.
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Disconnect Event Stream" })
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
		assert.equal(second, c4.last_transfer(), "no third transfer while two may be open")
		assert.equal("Waiting for an earlier stream transfer to close", env.Properties["Event Stream"])
		assert.equal("192.000.02.10", c4.persist.hue_stream_spelling, "the spelling waits too")
		-- The first one's next callback aborts it (the fake keeps a cancelled
		-- transfer silent, so its end stands for that callback); the retry
		-- then opens the third on the next spelling.
		first:done(-1, nil)
		c4.fire_timers()
		assert.equal(STREAM_URL_3, c4.last_transfer().url)
		local checks = 0
		for _, t in ipairs(c4.transfers) do
			if t.url == CHECK_URL then checks = checks + 1 end
		end
		assert.equal(1, checks, "no second self-check: the family is kept")
	end)

	it("a reloaded driver skips the spelling its predecessor's transfer still holds", function()
		local env, c4 = paired_driver()
		c4.persist.hue_stream_spelling = "192.000.02.10"
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		assert.equal(STREAM_URL_3, c4.last_transfer().url)
		assert.equal(rotating("192.000.2.10", 3), env.Properties["Stream Address"])
	end)

	it("wraps around the family and starts over when the persisted spelling is unknown", function()
		local env, c4 = paired_driver()
		c4.persist.hue_stream_spelling = "192.0.02.10" -- the family's last entry
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		assert.equal(STREAM_URL, c4.last_transfer().url)

		env, c4 = paired_driver()
		c4.persist.hue_stream_spelling = "10.000.002.143" -- from another address
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		assert.equal(STREAM_URL, c4.last_transfer().url)
	end)

	it("keeps a single spelling when only one octet can be padded, and says so", function()
		local env, c4 = paired_driver({ ["Bridge IP Address"] = "198.51.100.7" })
		env.OnDriverLateInit("DIT_STARTUP")
		answer_identity(c4)
		local check = c4.last_transfer()
		assert.equal("https://198.51.100.07/clip/v2/resource/bridge", check.url)
		check:respond(200, '{"data":[{"bridge_id":"001788fffe25b8f8"}]}')
		local first = c4.last_transfer()
		assert.equal("https://198.51.100.007/eventstream/clip/v2", first.url)
		assert.equal(3600, first.options.timeout, "still dual-queue: commands stay on the dotted address")
		assert.equal("198.51.100.007 (own queue, the only spelling)", env.Properties["Stream Address"])

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Disconnect Event Stream" })
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
		assert.equal("https://198.51.100.007/eventstream/clip/v2", c4.last_transfer().url)
	end)

	it("stays paired after pairing even when the store is not readable yet", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
			["Bridge IP Address"] = "192.0.2.10" })
		env.OnDriverLateInit("DIT_STARTUP")
		c4.PersistGetValue = function() return nil end

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		c4.transfers[1]:respond(200, CONFIG)
		c4.transfers[2]:respond(200, '[{"success":{"username":"abc123","clientkey":"00"}}]')
		assert.equal("Checking the bridge at 192.0.2.10 before anything is sent", env.Properties["Status"])
		answer_check(c4)
		assert.equal("Paired", env.Properties["Status"])
		assert.equal(STREAM_URL, c4.transfers[5].url)
		assert.equal("abc123", c4.transfers[4].headers["hue-application-key"])
	end)

	it("self-checks then reconnects the stream on startup when already paired, and counts events", function()
		local env, c4 = paired_driver({ ["Stream Timeout (s)"] = "900" })
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal("Checking the bridge at 192.0.2.10 before anything is sent", env.Properties["Status"])
		answer_check(c4)
		assert.equal("Paired", env.Properties["Status"])
		local s = c4.last_transfer()
		assert.equal(STREAM_URL, s.url)
		assert.equal(900, s.options.timeout, "configured timeout honoured in dual-queue mode")

		s:respond_headers(200, {})
		s:chunk('id: 1:0\ndata: [{"type":"update","id":"x","creationtime":"t","data":[{"type":"light","id":"l"}]}]\n\n')
		assert.equal("1", env.Properties["Events Received"])
		assert.truthy(env.Properties["Last Event"]:match("^%d%d:%d%d:%d%d$"))
	end)

	it("writes the per-event rows at most once a second, the latest value last", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		local s = c4.last_transfer()
		s:respond_headers(200, {})
		local function event(n)
			s:chunk("id: " .. n .. ':0\ndata: [{"type":"update","id":"x","creationtime":"t",'
				.. '"data":[{"type":"light","id":"l"}]}]\n\n')
		end
		local function writes(name)
			local n = 0
			for _, args in ipairs(c4.calls_to("UpdateProperty")) do
				if args[1] == name then n = n + 1 end
			end
			return n
		end

		-- The first event of a burst lands at once, the rest wait for the timer.
		event(1)
		local first = writes("Events Received")
		assert.equal("1", env.Properties["Events Received"])
		assert.truthy(env.Properties["Last Event"]:match("^%d%d:%d%d:%d%d$"))
		event(2)
		event(3)
		assert.equal("1", env.Properties["Events Received"])
		assert.equal(first, writes("Events Received"), "no write per event inside the second")
		assert.truthy(env.Properties["Event Stream"]:find("1 containers", 1, true))

		local fired = 0
		for _, t in ipairs(c4.active_timers()) do
			if t.delay == 1000 then
				t.active = false
				t.callback(t, 0)
				fired = fired + 1
			end
		end
		assert.equal(1, fired, "one coalescing timer for the three rows")
		assert.equal("3", env.Properties["Events Received"])
		assert.equal(first + 1, writes("Events Received"), "one write for the whole burst")
		assert.truthy(env.Properties["Event Stream"]:find("3 containers", 1, true))

		-- A state change is never held back, and a value still waiting never
		-- overwrites it; the count still lands.
		event(4)
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Disconnect Event Stream" })
		assert.equal("Stopped", env.Properties["Event Stream"])
		c4.fire_timers()
		assert.equal("Stopped", env.Properties["Event Stream"])
		assert.equal("4", env.Properties["Events Received"])
	end)

	it("falls back to a shared queue with a short stream timeout when the self-check fails", function()
		local env, c4 = paired_driver({ ["Stream Timeout (s)"] = "900" })
		env.OnDriverLateInit("DIT_STARTUP")
		local logged = {}
		log.sink = function(...)
			for _, a in ipairs({ ... }) do
				logged[#logged + 1] = tostring(a)
			end
		end
		answer_check(c4, false)
		local s = c4.last_transfer()
		assert.equal(DOTTED_STREAM_URL, s.url)
		assert.equal(60, s.options.timeout, "capped so commands wait at most a minute")
		assert.equal("192.0.2.10 (shared queue with commands: self-check failed)", env.Properties["Stream Address"],
			"short enough for Composer's column; the detail goes to the log")
		assert.truthy(table.concat(logged, "\n"):find("Couldn't resolve host name", 1, true))
	end)

	it("uses a shared queue when no octet of the address can be padded", function()
		local env, c4 = paired_driver({ ["Bridge IP Address"] = "198.51.100.10" })
		env.OnDriverLateInit("DIT_STARTUP")
		answer_identity(c4)
		local s = c4.last_transfer()
		assert.equal("https://198.51.100.10/eventstream/clip/v2", s.url, "no self-check, straight to the stream")
		assert.equal(60, s.options.timeout)
		assert.truthy(env.Properties["Stream Address"]:find("no octet below 8", 1, true))
	end)

	it("starts the dev loop from the Dev Server property and stops it when cleared", function()
		local devloop = require("common.devloop")
		local env, c4 = paired_driver({ ["Dev Server"] = " 192.0.2.7:8080 " })
		local real_print = _G.print
		_G.print = function() end -- the loop's own messages bypass log.sink
		local ok, err = pcall(function()
			env.OnDriverLateInit("DIT_STARTUP")
			assert.is_true(devloop.running())
			local repeating = {}
			for _, args in ipairs(c4.calls_to("SetTimer")) do
				-- The bridge's five-minute row refresh (docs/motion-design.md D5) repeats too.
				if args[2] == true and args[1] ~= 300000 then repeating[#repeating + 1] = args[1] end
			end
			assert.same({ 3000 }, repeating, "one repeating poll timer")
			local startup
			for _, t in ipairs(c4.transfers) do
				if t.url == "http://192.0.2.7:8080/report" then startup = t end
			end
			assert.truthy(startup, "startup report posted to the dev server")
			assert.equal("startup", c4:JsonDecode(startup.data).event)

			env.Properties["Dev Server"] = ""
			env.OnPropertyChanged("Dev Server")
			assert.is_false(devloop.running())
		end)
		devloop.stop()
		_G.print = real_print
		assert(ok, err)
	end)

	it("a release build (no common.devloop) carries none of the development handlers", function()
		-- Under busted the dev loop module is always on the path; a release
		-- .c4z has neither it nor bridge/devtools.lua (tools/build.sh), and
		-- then driver.lua must register no dev handler and no Host override.
		package.loaded["common.devloop"] = nil
		package.preload["common.devloop"] = function() error("module 'common.devloop' not found") end
		local ok, err = pcall(function()
			local env, c4 = paired_driver({ ["Dev Server"] = "192.0.2.7:8080" })
			env.OnDriverLateInit("DIT_STARTUP")
			assert.is_nil(package.loaded["bridge.devtools"], "devtools not loaded without the dev loop")
			answer_check(c4)
			local transfers = #c4.transfers
			for _, action in ipairs({ "Hue Request", "Connection Test", "Check CA Pinning", "Reload Credentials",
				"Proxy Command", "Lights Report", "Probe Project" }) do
				env.ExecuteCommand("LUA_ACTION", { ACTION = action, Path = "/clip/v2/resource/light", Target = "Bridge" })
			end
			env.ExecuteCommand("HUE_LOG", { rid = "x", line = "hello" })
			env.Properties["Dev Server"] = ""
			env.OnPropertyChanged("Dev Server")
			assert.equal(transfers, #c4.transfers, "no dev action started a transfer")
			assert.equal("Paired", env.Properties["Status"])

			-- Test Connection stays, on the dotted address whatever Host says.
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection", Host = "192.00.2.10" })
			assert.equal("https://192.0.2.10/clip/v2/resource/bridge", c4.last_transfer().url)
		end)
		package.preload["common.devloop"] = nil
		package.loaded["common.devloop"] = nil
		assert(ok, err)
	end)

	it("leaves the dev loop alone when Dev Server is empty", function()
		local devloop = require("common.devloop")
		local env = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		assert.is_false(devloop.running())
	end)

	it("Reload Credentials reports whether the store can be read back", function()
		local lines = {}
		log.sink = function(line) table.insert(lines, line) end
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Reload Credentials" })
		assert.equal("Stored credentials readable and match memory", env.Properties["Status"])
		local text = table.concat(lines, "\n")
		assert.truthy(text:find("key present (6 chars)", 1, true))
		assert.is_nil(text:find("abc123", 1, true), "the key itself is never logged")

		c4.PersistGetValue = function() return nil end
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Reload Credentials" })
		assert.truthy(env.Properties["Status"]:find("NOT readable", 1, true))
	end)

	it("Test Connection uses the dotted address and flags a rejected key", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
		local t = c4.last_transfer()
		assert.equal("https://192.0.2.10/clip/v2/resource/bridge", t.url)
		t:respond(403, '{"errors":[{"description":"unauthorized"}]}')
		assert.truthy(env.Properties["Status"]:find("key rejected", 1, true))
	end)

	it("Test Connection can target an alternative spelling of the bridge address", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)

		signed("Test Connection", { Host = "192.00.2.10" })
		local t = c4.last_transfer()
		assert.equal("https://192.00.2.10/clip/v2/resource/bridge", t.url)
		assert.equal("abc123", t.headers["hue-application-key"])
		t:respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"001788fffe25b8f8"}]}')
		assert.truthy(env.Properties["Status"]:find("^Test OK: HTTP 200 via 192.00.2.10"))
	end)

	it("Test Connection reports a bridge ID mismatch", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
		c4.last_transfer():respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"001788fffe000000"}]}')
		assert.truthy(env.Properties["Status"]:find("expected 001788fffe25b8f8", 1, true))
	end)

	it("Check CA Pinning reports the verdict in Status", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Check CA Pinning" })
		c4.last_transfer():respond(200, "<html>")
		assert.equal(SHIPPED, c4.last_transfer().options.ssl_cabundle)
		c4.last_transfer():done(60, "SSL peer certificate or SSH remote key was not OK")
		assert.truthy(env.Properties["Status"]:find("^Pinning check passed"))
	end)

	-- Issue #239: it used to read "example.com unreachable" for every inconclusive answer.
	it("Check CA Pinning names the transfer's error in Status when the answer is inconclusive", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Check CA Pinning" })
		c4.last_transfer():respond(200, "<html>")
		c4.last_transfer():done(28, "Timeout was reached")
		assert.equal("Pinning check inconclusive: example.com failed with the bundle for a reason other than its "
			.. "certificate (transfer failed (28): Timeout was reached)", env.Properties["Status"])
	end)

	it("Connection Test against the bridge pauses the driver's stream and restores it", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		local own = c4.last_transfer()
		assert.equal(STREAM_URL, own.url)

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connection Test", Target = "Bridge" })
		assert.is_true(own.cancelled, "driver's own stream stopped for the test")
		local test_stream = c4.last_transfer()
		assert.equal(DOTTED_STREAM_URL, test_stream.url, "the experiment deliberately shares the command queue")
		assert.equal("abc123", test_stream.headers["hue-application-key"])

		test_stream:respond_headers(200, {})
		c4.fire_timers()                                         -- conntest's 1 ms hop out of OnHeaders
		c4.last_transfer():respond(200, '{"data":[]}')          -- step 2
		local n = #c4.transfers
		c4.transfers[n - 1]:respond(200, '{"data":[]}')          -- step 3a
		c4.transfers[n]:respond(200, '{"data":[]}')              -- step 3b
		c4.last_transfer():respond(200, "<html>")               -- step 4 control

		assert.truthy(env.Properties["Status"]:find(
			"Connection test (bridge): stream OK, GET with stream open OK, concurrent 2/2, control OK", 1, true))
		assert.is_true(test_stream.cancelled)
		-- Reopened on the family's next spelling: the stopped stream's transfer
		-- may still be alive on the first one.
		assert.equal(STREAM_URL_2, c4.last_transfer().url, "driver's stream reopened on its own, next spelling")
		assert.is_false(c4.last_transfer().cancelled)
	end)

	it("Connection Test against the diagnostic server needs the property", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connection Test", Target = "Diagnostic Server" })
		assert.truthy(env.Properties["Status"]:find("^Set the Diagnostic Server property"))

		env.Properties["Diagnostic Server"] = " 192.0.2.7:8443 "
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connection Test", Target = "Diagnostic Server" })
		local t = c4.last_transfer()
		assert.equal("https://192.0.2.7:8443/stream", t.url)
		assert.is_false(t.options.ssl_verify_peer, "diagnostic server is self-signed")
	end)

	it("brings the feed back by itself when an invalid address is corrected while paired", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		local stream_t = c4.last_transfer()
		assert.equal(DOTTED_STREAM_URL:gsub("192%.0%.2%.10", "192.000.002.10"), stream_t.url)

		env.Properties["Bridge IP Address"] = "not an address"
		env.OnPropertyChanged("Bridge IP Address")
		assert.is_true(stream_t.cancelled, "the feed stops while the address is invalid")
		local n = #c4.transfers

		env.Properties["Bridge IP Address"] = "192.0.2.10"
		env.OnPropertyChanged("Bridge IP Address")
		answer_check(c4)
		assert.is_true(#c4.transfers > n, "a new transfer after the self-check")
		assert.truthy(c4.last_transfer().url:find("/eventstream/clip/v2", 1, true), "the feed is back without a click")
	end)

	it("sends nothing with the key to a bridge whose id is not the paired one", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		local t = c4.last_transfer()
		assert.equal("https://192.0.2.10/api/0/config", t.url)
		assert.is_nil(t.headers["hue-application-key"])
		local n = #c4.transfers
		answer_identity(c4, "AABBCCDDEEFF0011")
		assert.equal(n, #c4.transfers, "no self-check, no stream")
		assert.equal("Bridge at 192.0.2.10 reports ID aabbccddeeff0011, expected 001788fffe25b8f8; nothing is sent "
			.. "until the address is corrected", env.Properties["Status"])
		env.ExecuteCommand("HUE_SET", { rid = "l1", on = "true" })
		c4.fire_timers()
		assert.equal(n, #c4.transfers, "a command is refused before the identity is verified")

		-- A corrected address is checked afresh.
		env.Properties["Bridge IP Address"] = "192.0.2.12"
		env.OnPropertyChanged("Bridge IP Address")
		assert.equal("https://192.0.2.12/api/0/config", c4.last_transfer().url)
		answer_identity(c4)
		local check = c4.last_transfer()
		assert.equal("https://192.00.02.12/clip/v2/resource/bridge", check.url)
		check:respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"001788fffe25b8f8"}]}')
		assert.truthy(c4.last_transfer().url:find("/eventstream/clip/v2", 1, true))
	end)

	it("asks an unreachable bridge for its identity again every 30 s and sends nothing meanwhile", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		local t = c4.last_transfer()
		t:done(6, "Couldn't resolve host name")
		assert.truthy(env.Properties["Status"]:find("^Bridge at 192.0.2.10 not reachable"), env.Properties["Status"])
		local n = #c4.transfers
		local retry
		for _, timer in ipairs(c4.active_timers()) do
			if timer.delay == 30000 then retry = timer end
		end
		assert.is_not_nil(retry, "the 30 s retry timer")
		retry.active = false
		retry.callback(retry, 0)
		assert.equal(n + 1, #c4.transfers)
		assert.equal("https://192.0.2.10/api/0/config", c4.last_transfer().url)
		answer_check(c4)
		assert.equal("Paired", env.Properties["Status"])
		assert.truthy(c4.last_transfer().url:find("/eventstream/clip/v2", 1, true))
	end)

	it("word-wraps a long Last Action onto its continuation rows and hides them again", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal(1, c4.property_attribs["Last Action (2)"], "continuation rows start hidden")
		answer_check(c4)
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Link Devices" })
		local text = fake.last_action(env)
		assert.truthy(text:find(" | Scenes: ", 1, true), text)
		assert.is_true(#env.Properties["Last Action"] <= 72)
		c4.fire_timers() -- the rows' visibility goes out as a batch after the texts
		assert.equal(0, c4.property_attribs["Last Action (2)"])
		assert.equal(1, c4.property_attribs["Last Action (5)"])
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Add Zone Light", Group = "", Room = "" })
		assert.equal("Not added: pick a zone or room first", env.Properties["Last Action"])
		assert.equal("", env.Properties["Last Action (2)"], "a short text clears the rows")
		c4.fire_timers() -- the rows' visibility goes out as a batch after the texts
		assert.equal(1, c4.property_attribs["Last Action (2)"])
	end)

	it("shows the bridge's model, name and firmware from the identity check; refuses a first-generation bridge", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_identity(c4)
		assert.equal("Hue Bridge Pro (BSB003)", env.Properties["Bridge Model"])
		assert.equal("Hue", env.Properties["Bridge Name"])
		assert.equal("1968096020 (API 1.68.0)", env.Properties["Bridge Firmware"])

		local env2, c42 = paired_driver()
		env2.OnDriverLateInit("DIT_STARTUP")
		local n = #c42.transfers
		c42.last_transfer():respond(200, '{"bridgeid":"001788FFFE25B8F8","modelid":"BSB001","name":"Old",'
			.. '"swversion":"1935074050"}')
		assert.equal("Bridge at 192.0.2.10 is a Hue Bridge v1, round (BSB001): no CLIP v2 API; nothing is sent",
			env2.Properties["Status"])
		assert.equal("Hue Bridge v1, round (BSB001)", env2.Properties["Bridge Model"])
		assert.equal(n, #c42.transfers, "nothing sent to a first-generation bridge")
	end)

	it("Hue Request sends an authenticated request and summarises resource lists", function()
		local lines = {}
		log.sink = function(line) table.insert(lines, line) end
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)

		signed("Hue Request", { Method = "put",
			Path = "/clip/v2/resource/light/abc", Body = '{"metadata":{"name":"Desk"}}', Host = "192.00.002.10" })
		local t = c4.last_transfer()
		assert.equal("PUT", t.method)
		assert.equal("https://192.00.002.10/clip/v2/resource/light/abc", t.url)
		assert.equal("abc123", t.headers["hue-application-key"])
		assert.same({ metadata = { name = "Desk" } }, c4:JsonDecode(t.data))
		t:respond(200, '{"data":[{"rid":"abc","rtype":"light"}],"errors":[]}')
		assert.truthy(lines[#lines]:find("Hue Request PUT /clip/v2/resource/light/abc via 192.00.002.10: HTTP 200", 1, true))

		signed("Hue Request", { Path = "/clip/v2/resource/light" })
		c4.last_transfer():respond(200, '{"data":[{"id":"l1","type":"light","metadata":{"name":"Desk"}},'
			.. '{"id":"l2","type":"light","metadata":{"name":"Hall"}}],"errors":[]}')
		assert.truthy(lines[#lines]:find("2 items: l1=Desk; l2=Hall", 1, true))
	end)

	describe("dev actions for the light path", function()
		local env, c4, lines

		before_each(function()
			lines = {}
			log.sink = function(line) table.insert(lines, line) end
			env, c4 = paired_driver()
			-- A registered light whose light_v2 proxy (2005) consumes the protocol
			-- driver's (2004) binding 5001, as Director wires a proxy driver.
			c4.persist.hue_lights = { ["rid-1"] = { device_id = 2004, name = "Desk Lamp", model = "Hue color lamp",
				caps = { has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 0.2 } } }
			c4:Bind(2004, 5001, 2005, 5001, "LIGHT_V2")
			env.OnDriverLateInit("DIT_STARTUP")
			answer_check(c4)
		end)

		it("prints HUE_LOG lines with the light's name", function()
			env.ExecuteCommand("HUE_LOG", { rid = "rid-1", line = "[INFO] Hue Light: hello" })
			assert.truthy(lines[#lines]:find("[Desk Lamp] [INFO] Hue Light: hello", 1, true))
		end)

		it("Proxy Command sends a light_v2 command to the light's proxy by name", function()
			signed("Proxy Command", { Light = "desk lamp",
				Command = "SET_BRIGHTNESS_TARGET", LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" })
			local m = c4.sent[#c4.sent]
			assert.equal(2005, m.id)
			assert.equal("SET_BRIGHTNESS_TARGET", m.command)
			assert.same({ LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" }, m.params)
			assert.equal(2005, c4.persist.hue_lights["rid-1"].proxy_id, "proxy id cached in the registry")
		end)

		it("Proxy Command reports an unknown light", function()
			local before = #c4.sent
			signed("Proxy Command", { Light = "nope" })
			assert.equal(before, #c4.sent)
			assert.truthy(lines[#lines]:find("no registered light, zone light or scene matches", 1, true))
		end)

		it("Lights Report lists the registry and the owner-facing texts", function()
			local before = #lines
			signed("Lights Report", {})
			local text = table.concat(lines, "\n", before + 1)
			assert.truthy(text:find("Lights Report: 1 registered", 1, true))
			assert.truthy(text:find("Attention: ", 1, true))
			assert.truthy(text:find("Desk Lamp: device 2004", 1, true))
		end)
	end)

	it("Forget Pairing stops the stream and clears the key", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		local s = c4.last_transfer()

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" })
		assert.is_true(s.cancelled)
		assert.is_nil(c4.persist.hue_app_key)
		assert.truthy(env.Properties["Status"]:find("^Not paired"))
		assert.equal("Stopped", env.Properties["Event Stream"])
		assert.equal("", env.Properties["Stream Address"])
	end)

	it("re-checks and restarts the stream when the IP changes", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		local first = c4.last_transfer()

		env.Properties["Bridge IP Address"] = "192.0.2.11"
		env.OnPropertyChanged("Bridge IP Address")
		assert.is_true(first.cancelled)
		answer_identity(c4)
		local check = c4.last_transfer()
		assert.equal("https://192.00.02.11/clip/v2/resource/bridge", check.url)
		check:respond(200, '{"data":[{"bridge_id":"001788fffe25b8f8"}]}')
		assert.equal("https://192.000.002.11/eventstream/clip/v2", c4.last_transfer().url)
		assert.equal("192.0.2.11", c4.persist.hue_bridge_ip)
	end)

	describe("review leftovers (docs/review-leftovers-design.md)", function()
		local KEY_STATUS = "Key rejected by the bridge (HTTP 403): re-pair with Pair Bridge"

		it("stops the stream for good on a 403 and says the key was rejected; Pair Bridge clears it", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			answer_check(c4)
			local s = c4.last_transfer()
			assert.equal(STREAM_URL, s.url)
			s:respond(403, "<html>unauthorized</html>")
			assert.equal(KEY_STATUS, env.Properties["Status"])
			assert.equal("Stopped: key rejected (HTTP 403)", env.Properties["Event Stream"])
			local count = #c4.transfers
			c4.fire_timers()
			c4.fire_timers()
			assert.equal(count, #c4.transfers, "no reconnect with a rejected key")

			env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
			c4.last_transfer():respond(200, CONFIG)
			c4.last_transfer():respond(200, '[{"success":{"username":"newkey","clientkey":"00"}}]')
			answer_check(c4)
			assert.equal("Paired", env.Properties["Status"])
			assert.truthy(c4.last_transfer().url:find("/eventstream/clip/v2", 1, true), "the stream starts again")
		end)

		it("treats a keyed request answered 403 as a rejected key and starts no stream", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			answer_identity(c4)
			local check = c4.last_transfer()
			assert.equal(CHECK_URL, check.url)
			check:respond(403, "<html>unauthorized</html>")
			assert.equal(KEY_STATUS, env.Properties["Status"])
			assert.equal(check, c4.last_transfer(), "no stream on a rejected key")
		end)

		it("checks TLS with a decoy bundle and no key before the first keyed request", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			answer_check(c4)
			assert.equal(1, #c4.decoy_transfers)
			local decoy = c4.decoy_transfers[1]
			assert.equal("https://192.0.2.10/api/0/config", decoy.url)
			assert.equal("certs/decoy_ca.pem", decoy.options.ssl_cabundle)
			assert.is_true(decoy.options.ssl_verify_peer)
			assert.is_nil(decoy.headers["hue-application-key"], "the decoy request never carries the key")
			assert.equal("Paired", env.Properties["Status"])

			-- A new address is checked again.
			env.Properties["Bridge IP Address"] = "192.0.2.11"
			env.OnPropertyChanged("Bridge IP Address")
			answer_identity(c4)
			assert.equal(2, #c4.decoy_transfers)
		end)

		it("sends nothing keyed when the controller accepts the bridge with the decoy bundle", function()
			local env, c4 = paired_driver()
			c4.tls_ignores_cabundle = true
			env.OnDriverLateInit("DIT_STARTUP")
			answer_identity(c4)
			local decoy = c4.last_transfer()
			assert.equal("certs/decoy_ca.pem", decoy.options.ssl_cabundle)
			decoy:respond(200, CONFIG)
			assert.equal("TLS check failed: nothing is sent (see Attention)", env.Properties["Status"])
			assert.truthy(env.Properties["Attention"]:find("^TLS check failed: the controller accepted the bridge"))
			assert.equal(decoy, c4.last_transfer(), "no self-check and no stream")
			for _, t in ipairs(c4.transfers) do
				assert.is_nil(t.headers["hue-application-key"], "no request carried the key")
			end
		end)

		it("ignores the stream address check of an earlier bridge address", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			answer_identity(c4)
			local old_check = c4.last_transfer()
			assert.equal(CHECK_URL, old_check.url)
			env.Properties["Bridge IP Address"] = "192.0.2.11"
			env.OnPropertyChanged("Bridge IP Address")
			local new_identity = c4.last_transfer()
			assert.equal("https://192.0.2.11/api/0/config", new_identity.url)
			old_check:respond(200, '{"data":[{"bridge_id":"001788fffe25b8f8"}]}')
			assert.equal(new_identity, c4.last_transfer(), "the late answer starts no stream")
		end)

		it("counts reconnects on the Event Stream row", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			answer_check(c4)
			local s = c4.last_transfer()
			s:respond_headers(200, {})
			assert.truthy(env.Properties["Event Stream"]:match("^Connected since %d%d:%d%d:%d%d$"))
			s:done(7, "Couldn't connect to server")
			c4.fire_timers()
			local s2 = c4.last_transfer()
			assert.are_not.equal(s, s2)
			s2:respond_headers(200, {})
			assert.truthy(env.Properties["Event Stream"]:match(
				"^Connected since %d%d:%d%d:%d%d %(1 reconnect since %d%d%-%d%d %d%d:%d%d%)$"),
				env.Properties["Event Stream"])
		end)

		it("writes an unchanged Attention once and reconciles once per burst of binding changes", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			answer_check(c4)
			local function writes()
				local n = 0
				for _, args in ipairs(c4.calls_to("UpdateProperty")) do
					if args[1] == "Attention" then n = n + 1 end
				end
				return n
			end
			local reconciles = 0
			local bound = c4.GetBoundConsumerDevices
			c4.GetBoundConsumerDevices = function(self, ...)
				reconciles = reconciles + 1
				return bound(self, ...)
			end
			local before = writes()
			env.OnBindingChanged(1, "HUE_BRIDGE", true, 3001, 1)
			c4.fire_timers()
			local one = reconciles
			assert.is_true(one > 0)
			reconciles = 0
			env.OnBindingChanged(1, "HUE_BRIDGE", true, 3002, 1)
			env.OnBindingChanged(1, "HUE_BRIDGE", true, 3003, 1)
			env.OnBindingChanged(1, "HUE_BRIDGE", true, 3004, 1)
			c4.fire_timers()
			assert.equal(one, reconciles, "three binding changes, one reconcile")
			assert.equal(before, writes(), "the same Attention text is not written again")
		end)

		it("asks Director to log device messages only in Debug Mode", function()
			local env, c4 = paired_driver()
			c4.persist.hue_lights = { ["rid-1"] = { device_id = 2004, name = "Desk Lamp", model = "Hue color lamp",
				caps = { has_color = true, has_cct = true, mirek_min = 153, mirek_max = 500, min_dim = 0.2 } } }
			c4:Bind(2004, 5001, 2005, 5001, "LIGHT_V2")
			env.OnDriverLateInit("DIT_STARTUP")
			answer_check(c4)
			c4.sent = {}
			env.ExecuteCommand("HUE_HELLO", { rid = "rid-1", device_id = "2004" })
			assert.is_true(#c4.sent > 0)
			for _, m in ipairs(c4.sent) do
				assert.is_false(m.log_command, m.command)
			end
			env.Properties["Debug Mode"] = "On"
			env.OnPropertyChanged("Debug Mode")
			c4.sent = {}
			env.ExecuteCommand("HUE_HELLO", { rid = "rid-1", device_id = "2004" })
			assert.is_true(#c4.sent > 0)
			assert.is_true(c4.sent[1].log_command)
		end)

		it("strips control characters from list rows", function()
			local env, c4 = paired_driver()
			c4.persist.hue_lights = { ["rid-1"] = { device_id = 2004, name = "Desk\tLamp\n", model = "Hue color lamp",
				caps = {} } }
			c4:Bind(2004, 5001, 2005, 5001, "LIGHT_V2")
			env.OnDriverLateInit("DIT_STARTUP")
			for item in tostring(c4.property_lists["Lights"] or ""):gmatch("[^,]+") do
				assert.is_nil(item:find("%c"), item)
			end
		end)
	end)

	describe("security fixes (docs/security-fixes-design.md)", function()
		local KEY_STATUS = "Key rejected by the bridge (HTTP 403): re-pair with Pair Bridge"
		local TEST_URL = "https://192.0.2.10/clip/v2/resource/bridge"
		local BRIDGE_OK = '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"001788fffe25b8f8"}]}'

		local function keyed(c4, from)
			local found = {}
			for i = from or 1, #c4.transfers do
				local t = c4.transfers[i]
				if t.headers and t.headers["hue-application-key"] then
					found[#found + 1] = t
				end
			end
			return found
		end

		local function last_to(c4, url)
			for i = #c4.transfers, 1, -1 do
				if c4.transfers[i].url == url then
					return c4.transfers[i]
				end
			end
		end

		-- Paired, TLS answered by a controller that ignores the decoy bundle,
		-- so the decoy request lands in c4.transfers for the spec to answer.
		local function at_decoy()
			local env, c4 = paired_driver()
			c4.tls_ignores_cabundle = true
			env.OnDriverLateInit("DIT_STARTUP")
			answer_identity(c4)
			local decoy = c4.last_transfer()
			assert.equal("certs/decoy_ca.pem", decoy.options.ssl_cabundle)
			return env, c4, decoy
		end

		it("Test Connection waits for the identity check and reports a different bridge without the key", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			local identity = c4.last_transfer()
			assert.truthy(identity.url:find("/api/0/config", 1, true))
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
			assert.equal("Testing: checking the bridge identity first", env.Properties["Status"])
			assert.equal(identity, c4.last_transfer(), "the test joins the identity check in flight")
			answer_identity(c4, "001788FFFE456DEF")
			assert.equal("Bridge at 192.0.2.10 reports ID 001788fffe456def, expected 001788fffe25b8f8; nothing is sent "
				.. "until the address is corrected", env.Properties["Status"])
			assert.same({}, keyed(c4), "no request carried the key")
		end)

		it("Test Connection sends the key once the identity check passes, and the stream's start is kept", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
			answer_identity(c4)
			local test = last_to(c4, TEST_URL)
			assert.is_truthy(test, "the keyed test GET after the identity check")
			test:respond(200, BRIDGE_OK)
			assert.truthy(env.Properties["Status"]:find("^Test OK: HTTP 200 via 192.0.2.10"))
			local check = last_to(c4, CHECK_URL)
			assert.is_truthy(check, "the stream's pending start survived the test")
			check:respond(200, BRIDGE_OK)
			assert.equal(STREAM_URL, c4.last_transfer().url)
		end)

		it("Test Connection is refused after a failed TLS check, and nothing carries the key", function()
			local env, c4, decoy = at_decoy()
			decoy:respond(200, CONFIG)
			assert.equal("TLS check failed: nothing is sent (see Attention)", env.Properties["Status"])
			local count = #c4.transfers
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
			assert.equal("Test refused: TLS check failed; nothing is sent (see Attention)", env.Properties["Status"])
			assert.equal(count, #c4.transfers)
			assert.same({}, keyed(c4))
		end)

		it("keeps a failed TLS verdict through Connect Event Stream and a new pairing", function()
			local env, c4, decoy = at_decoy()
			decoy:respond(200, CONFIG)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
			assert.equal("Not connected: TLS check failed", env.Properties["Event Stream"])
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
			c4.last_transfer():respond(200, CONFIG)
			c4.last_transfer():respond(200, '[{"success":{"username":"newkey","clientkey":"00"}}]')
			c4.fire_timers()
			assert.same({}, keyed(c4), "the verdict holds until the next start or address change")
			assert.equal("TLS check failed: nothing is sent (see Attention)", env.Properties["Status"])
		end)

		it("blocks on an inconclusive TLS check until a conclusive one on a Director version never seen pinned", function()
			local env, c4, decoy = at_decoy()
			decoy:done(28, "Timeout was reached")
			assert.equal("TLS check inconclusive (transfer failed (28): Timeout was reached): nothing is sent; checking "
				.. "again in 30 s", env.Properties["Status"])
			assert.same({}, keyed(c4))
			assert.is_nil(c4.persist.tls_pinned_on)

			c4.fire_timers()
			answer_identity(c4)
			local again = c4.last_transfer()
			assert.equal("certs/decoy_ca.pem", again.options.ssl_cabundle, "asked again after 30 s")
			again:done(60, "SSL peer certificate or SSH remote key was not OK")
			assert.equal(c4.director_version, c4.persist.tls_pinned_on, "pinned is remembered for this version")
			assert.equal(CHECK_URL, c4.last_transfer().url, "then the keyed self-check")
			assert.equal("Paired", env.Properties["Status"])
		end)

		it("lets an inconclusive TLS check pass on a Director version that answered pinned before", function()
			local env, c4 = paired_driver()
			c4.tls_ignores_cabundle = true
			c4.persist.tls_pinned_on = c4.director_version
			env.OnDriverLateInit("DIT_STARTUP")
			answer_identity(c4)
			c4.last_transfer():done(28, "Timeout was reached")
			assert.equal(CHECK_URL, c4.last_transfer().url)

			local env2, c42 = paired_driver()
			c42.tls_ignores_cabundle = true
			c42.persist.tls_pinned_on = "3.3.0.100000"
			env2.OnDriverLateInit("DIT_STARTUP")
			answer_identity(c42)
			c42.last_transfer():done(28, "Timeout was reached")
			assert.same({}, keyed(c42), "another version (an upgraded OS) proves nothing")
		end)

		it("#324: Refresh All reads every module from the bridge with the stream not connected", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			answer_check(c4)
			c4.last_transfer():done(28, "Timeout was reached") -- the stream never connects
			local before = #c4.transfers
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Refresh All" })
			local paths = {}
			for _ = 1, 30 do
				local t = c4.transfers[#c4.transfers]
				if #c4.transfers == before or t.answered then break end
				paths[#paths + 1] = t.url:match("/clip/v2/resource/([%w_]+)") or t.url
				t:respond(200, '{"errors":[],"data":[]}')
				t.answered = true
			end
			assert.truthy(#paths >= 4, "one GET at a time through the chain: " .. table.concat(paths, ", "))
			assert.equal("light", paths[1], "the lights first")
			assert.truthy(table.concat(paths, ","):find("motion", 1, true), "the motion module last")
			assert.truthy(env.Properties["Last Action"]:find("^Refreshed from the bridge: Lights: "),
				env.Properties["Last Action"])
		end)

		it("confirms a REST 401/403 with one GET of the bridge resource before it locks", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			answer_check(c4)
			local stream_t = c4.last_transfer()
			stream_t:respond_headers(200, {})
			local before = #c4.transfers
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Refresh Scenes" })
			local refused = c4.transfers[before + 1]
			assert.is_truthy(refused, "a keyed module request")
			refused:respond(403, "<html>forbidden</html>")
			local confirm = c4.last_transfer()
			assert.equal(TEST_URL, confirm.url, "one keyed GET of the bridge resource decides")
			assert.are_not.equal(KEY_STATUS, env.Properties["Status"], "not locked by one refusal")
			confirm:respond(200, BRIDGE_OK)
			assert.are_not.equal(KEY_STATUS, env.Properties["Status"])
			assert.is_false(stream_t.cancelled == true, "the stream keeps running")

			before = #c4.transfers
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Refresh Scenes" })
			c4.transfers[before + 1]:respond(403, "<html>forbidden</html>")
			c4.last_transfer():respond(403, "<html>forbidden</html>")
			assert.equal(KEY_STATUS, env.Properties["Status"], "the bridge resource refused too: locked")
		end)

		it("a Test Connection that shows the key works clears the lock and starts the stream again", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			answer_check(c4)
			c4.last_transfer():respond(403, "<html>unauthorized</html>")
			assert.equal(KEY_STATUS, env.Properties["Status"])
			local count = #c4.transfers
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
			assert.equal("Not connected: key rejected", env.Properties["Event Stream"])
			assert.equal(count, #c4.transfers, "Connect Event Stream presents no rejected key")

			env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
			local test = c4.last_transfer()
			assert.equal(TEST_URL, test.url, "the test may send the key while locked")
			test:respond(200, BRIDGE_OK)
			assert.truthy(env.Properties["Status"]:find("^Test OK"))
			assert.truthy(c4.last_transfer().url:find("/eventstream/clip/v2", 1, true), "the stream starts again")
		end)

		it("shows the bridge name without control characters", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			c4.last_transfer():respond(200, '{"bridgeid":"001788FFFE25B8F8","modelid":"BSB003","name":"Hue\\nBridge",'
				.. '"swversion":"1968096020","apiversion":"1.68.0"}')
			assert.equal("HueBridge", env.Properties["Bridge Name"])
		end)

		it("drops a Test Connection that waited for the identity check of an earlier address", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
			env.Properties["Bridge IP Address"] = "192.0.2.11"
			env.OnPropertyChanged("Bridge IP Address")
			answer_identity(c4)
			assert.is_nil(last_to(c4, TEST_URL), "no test to the old address")
			assert.is_nil(last_to(c4, "https://192.0.2.11/clip/v2/resource/bridge"), "nor to the new one")
		end)
	end)

	-- Issue #236: pairing another bridge (docs/bridge-compat-design.md,
	-- "Pairing another bridge (#236)"), Status while nothing is sent, the
	-- pairing failure's prefix, the feed after a rejected key and a new
	-- address, the Event Stream row after a restart, and a light imported
	-- under its Hue device's other name. The paired bridge 001788fffe123abc
	-- answers at 10.0.2.143; 001788fffe456def is another bridge.
	describe("pairing and Status (#236)", function()
		local IP, PAIRED, OTHER = "10.0.2.143", "001788fffe123abc", "001788fffe456def"
		local CHECKING = "Checking the bridge at 10.0.2.143 before anything is sent"
		local WAITING = "Not connected: bridge identity not verified yet"
		local REFUSED = "Pairing failed: Bridge at 10.0.2.143 reports ID 001788fffe456def, expected 001788fffe123abc; "
			.. "run Forget Pairing first to pair with another bridge"
		local OTHER_AT_IP = "Bridge at 10.0.2.143 reports ID 001788fffe456def, expected 001788fffe123abc; nothing is "
			.. "sent until the address is corrected"

		local function config_of(id, name)
			return '{"bridgeid":"' .. id:upper() .. '","modelid":"BSB003","name":"' .. (name or "Hue")
				.. '","swversion":"1968096020","apiversion":"1.68.0"}'
		end

		-- Paired with PAIRED at IP; `props` adds or overrides properties.
		local function house(props)
			local all = { ["Event Stream Transport"] = "Web transfer", ["Bridge IP Address"] = IP }
			for k, v in pairs(props or {}) do all[k] = v end
			local env, c4 = fake.load_driver("hue_bridge", all)
			c4.persist.hue_app_key = "abc123"
			c4.persist.hue_bridge_id = PAIRED
			return env, c4
		end

		-- Answer the newest transfer, which must be a request for `path`.
		local function answer(c4, path, code, body)
			local t = c4.last_transfer()
			assert(t and t.url:find(path, 1, true), "expected a request for " .. path .. ", got " .. tostring(t and t.url))
			t:respond(code, body)
			return t
		end

		-- The unkeyed GET /api/0/config of the identity check or of a pairing,
		-- answered by bridge `id` (default the paired one).
		local function identity(c4, id, name)
			local t = answer(c4, "/api/0/config", 200, config_of(id or PAIRED, name))
			assert.is_nil(t.headers["hue-application-key"])
			return t
		end

		-- The stream address self-check after a passed identity check.
		local function self_check(c4)
			return answer(c4, "/clip/v2/resource/bridge", 200, '{"errors":[],"data":[{"id":"x","type":"bridge",'
				.. '"bridge_id":"' .. PAIRED .. '"}]}')
		end

		local function streaming(c4)
			local t = c4.last_transfer()
			return t ~= nil and t.url:find("/eventstream/clip/v2", 1, true) ~= nil and not t.cancelled
		end

		local function set_address(env, value)
			env.Properties["Bridge IP Address"] = value
			env.OnPropertyChanged("Bridge IP Address")
		end

		local function pair(env)
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		end

		describe("Pair Bridge with another bridge (item 1)", function()
			it("is refused until Forget Pairing, before anything is shown or asked for", function()
				local env, c4 = house()
				env.OnDriverLateInit("DIT_STARTUP")
				identity(c4)
				self_check(c4)
				local s = c4.last_transfer()
				assert.is_true(streaming(c4))

				-- A replacement bridge now answers at the address.
				pair(env)
				local n = #c4.transfers
				identity(c4, OTHER, "Replacement")
				assert.equal(REFUSED, env.Properties["Status"])
				assert.equal(n, #c4.transfers, "no key requested")
				assert.same({ "abc123", PAIRED }, { c4.persist.hue_app_key, c4.persist.hue_bridge_id }, "nothing stored")
				assert.equal(PAIRED, env.Properties["Bridge ID"])
				assert.equal("Hue", env.Properties["Bridge Name"], "the rows are not rewritten")
				assert.is_false(s.cancelled, "the stream is left alone")

				-- After Forget Pairing it pairs, and every later check expects it.
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" })
				pair(env)
				identity(c4, OTHER, "Replacement")
				answer(c4, "/api", 200, '[{"success":{"username":"otherkey"}}]')
				assert.same({ "otherkey", OTHER }, { c4.persist.hue_app_key, c4.persist.hue_bridge_id })
				assert.equal(CHECKING, env.Properties["Status"])
				assert.equal(WAITING, env.Properties["Event Stream"])
				identity(c4, OTHER, "Replacement")
				assert.equal("Paired", env.Properties["Status"])
				assert.equal(OTHER, env.Properties["Bridge ID"])
				assert.equal("Replacement", env.Properties["Bridge Name"])
			end)

			it("lets Forget Pairing overtake the checks: no error, blank rows, the next bridge checked afresh", function()
				local env, c4 = house()
				env.OnDriverLateInit("DIT_STARTUP")
				local check = c4.last_transfer()
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" })
				assert.has_no.errors(function() check:respond(200, config_of(OTHER, "Replacement")) end)
				assert.equal("Not paired: press the link button, then run Pair Bridge", env.Properties["Status"])
				assert.equal("", env.Properties["Bridge Name"])

				-- A TLS check of the paired bridge that ends after Forget Pairing
				-- proves nothing for the bridge paired next: it is checked afresh.
				env, c4 = house()
				c4.tls_ignores_cabundle = true
				env.OnDriverLateInit("DIT_STARTUP")
				identity(c4)
				local decoy = c4.last_transfer()
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" })
				decoy:done(60, "SSL peer certificate or SSH remote key was not OK")  -- pinned
				pair(env)
				identity(c4, OTHER)
				answer(c4, "/api", 200, '[{"success":{"username":"otherkey"}}]')
				assert.equal(CHECKING, env.Properties["Status"])
				identity(c4, OTHER)
				assert.equal("Paired", env.Properties["Status"])
			end)

			it("is refused after an address change, and while the key is gone but the id is stored", function()
				local env, c4 = house()
				env.OnDriverLateInit("DIT_STARTUP")
				identity(c4)
				self_check(c4)
				set_address(env, "192.0.2.144")
				identity(c4, OTHER)
				assert.equal("Bridge at 192.0.2.144 reports ID 001788fffe456def, expected 001788fffe123abc; nothing is "
					.. "sent until the address is corrected", env.Properties["Status"])
				local n = #c4.transfers
				pair(env)
				identity(c4, OTHER)
				assert.equal("Pairing failed: Bridge at 192.0.2.144 reports ID 001788fffe456def, expected "
					.. "001788fffe123abc; run Forget Pairing first to pair with another bridge", env.Properties["Status"])
				assert.equal(n + 1, #c4.transfers, "the probe only")
				assert.equal(PAIRED, c4.persist.hue_bridge_id)

				-- The key unreadable after a restore, the id still stored.
				env, c4 = house()
				c4.persist.hue_app_key = nil
				env.OnDriverLateInit("DIT_STARTUP")
				assert.equal("Not paired: press the link button, then run Pair Bridge", env.Properties["Status"])
				pair(env)
				identity(c4, OTHER)
				assert.equal(REFUSED, env.Properties["Status"])
				assert.equal(1, #c4.transfers, "the probe only")
			end)

			it("pairs the paired bridge again with a new key, at a new address too", function()
				local env, c4 = house()
				env.OnDriverLateInit("DIT_STARTUP")
				identity(c4)
				-- The bridge moved to another address before the stream started.
				set_address(env, "192.0.2.144")
				identity(c4)
				self_check(c4)
				assert.is_true(streaming(c4))
				pair(env)
				identity(c4)
				answer(c4, "/api", 200, '[{"success":{"username":"newkey"}}]')
				assert.same({ "newkey", PAIRED, "192.0.2.144" }, { c4.persist.hue_app_key, c4.persist.hue_bridge_id,
					c4.persist.hue_bridge_ip })
				assert.equal("Paired", env.Properties["Status"], "the identity check had passed at this address")
				self_check(c4)
				assert.is_true(streaming(c4))
				assert.equal("newkey", c4.last_transfer().headers["hue-application-key"])
			end)
		end)

		describe("Status (item 2)", function()
			it("keeps the identity check's text when the same address is set again", function()
				local env, c4 = house()
				env.OnDriverLateInit("DIT_STARTUP")
				assert.equal(CHECKING, env.Properties["Status"])
				identity(c4, OTHER)
				assert.equal(OTHER_AT_IP, env.Properties["Status"])
				set_address(env, IP)
				assert.equal(OTHER_AT_IP, env.Properties["Status"])
				env.ExecuteCommand("HUE_SET", { rid = "l1", on = "true" })
				c4.fire_timers()
				for _, t in ipairs(c4.transfers) do
					assert.is_nil(t.headers["hue-application-key"], "nothing is sent")
				end
			end)

			it("keeps the texts of an unreachable bridge and of an inconclusive TLS check until the check passes",
				function()
					local env, c4 = house()
					env.OnDriverLateInit("DIT_STARTUP")
					c4.last_transfer():done(7, "Couldn't connect to server")
					local text = "Bridge at 10.0.2.143 not reachable (transfer failed (7): Couldn't connect to server); "
						.. "checking again in 30 s"
					assert.equal(text, env.Properties["Status"])
					set_address(env, IP)
					assert.equal(text, env.Properties["Status"])
					for _, timer in ipairs(c4.active_timers()) do
						if timer.delay == 30000 then
							timer.active = false
							timer.callback(timer, 0)
						end
					end
					identity(c4)
					assert.equal("Paired", env.Properties["Status"])
					set_address(env, IP)
					assert.equal("Paired", env.Properties["Status"], "the normal state once the check has passed")

					env, c4 = house()
					c4.tls_ignores_cabundle = true
					env.OnDriverLateInit("DIT_STARTUP")
					identity(c4)
					c4.last_transfer():done(28, "Timeout was reached")  -- the decoy request
					text = "TLS check inconclusive (transfer failed (28): Timeout was reached): nothing is sent; checking "
						.. "again in 30 s"
					assert.equal(text, env.Properties["Status"])
					set_address(env, IP)
					assert.equal(text, env.Properties["Status"])
				end)

			it("reads Checking, not Paired, after an address change until the new address passes", function()
				local env, c4 = house()
				env.OnDriverLateInit("DIT_STARTUP")
				identity(c4)
				self_check(c4)
				assert.equal("Paired", env.Properties["Status"])
				set_address(env, "192.0.2.144")
				assert.equal("Checking the bridge at 192.0.2.144 before anything is sent", env.Properties["Status"])
				identity(c4)
				assert.equal("Paired", env.Properties["Status"])
			end)
		end)

		it("a key request without an answer reads Pairing failed once (item 3)", function()
			local env, c4 = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
				["Bridge IP Address"] = IP })
			env.OnDriverLateInit("DIT_STARTUP")
			pair(env)
			identity(c4)
			c4.last_transfer():done(7, "Couldn't connect to server")
			assert.equal("Pairing failed: No usable answer to the key request: transfer failed (7): Couldn't connect to "
				.. "server", env.Properties["Status"])
		end)

		it("a new address after a rejected key brings the feed back once the identity check passes (item 4)", function()
			local env, c4 = house()
			env.OnDriverLateInit("DIT_STARTUP")
			identity(c4)
			self_check(c4)
			c4.last_transfer():respond(403, "<html>unauthorized</html>")
			assert.equal("Stopped: key rejected (HTTP 403)", env.Properties["Event Stream"])

			set_address(env, "192.0.2.144")
			assert.equal("Checking the bridge at 192.0.2.144 before anything is sent", env.Properties["Status"])
			assert.equal(WAITING, env.Properties["Event Stream"])
			identity(c4)
			self_check(c4)
			assert.is_true(streaming(c4), "the feed is back without a click")
			assert.equal("https://192.000.002.144/eventstream/clip/v2", c4.last_transfer().url)
			assert.equal("Paired", env.Properties["Status"])

			-- A feed the owner disconnected stays off at a new address.
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Disconnect Event Stream" })
			set_address(env, "192.0.2.145")
			identity(c4)
			self_check(c4)
			assert.is_false(streaming(c4))
			assert.equal("Stopped", env.Properties["Event Stream"])
		end)

		it("a new address while the feed is about to start brings it up there (item 4)", function()
			local env, c4 = house()
			env.OnDriverLateInit("DIT_STARTUP")
			identity(c4)
			-- The address check before the first stream has not answered yet.
			assert.truthy(c4.last_transfer().url:find("/clip/v2/resource/bridge", 1, true))
			set_address(env, "192.0.2.144")
			identity(c4)
			self_check(c4)
			assert.is_true(streaming(c4))
			assert.equal("https://192.000.002.144/eventstream/clip/v2", c4.last_transfer().url)
		end)

		it("late init writes a true Event Stream text while the identity or TLS check is pending or failing (item 5)",
			function()
				-- Director keeps the row's value across a restart.
				local BEFORE = "Connected since 14:03:12, 128 containers, last 14:40:01"
				local env, c4 = house({ ["Event Stream"] = BEFORE })
				env.OnDriverLateInit("DIT_STARTUP")
				assert.equal(WAITING, env.Properties["Event Stream"], "the check is pending")
				identity(c4, OTHER)
				assert.equal(WAITING, env.Properties["Event Stream"], "the check failed")

				env, c4 = house({ ["Event Stream"] = BEFORE })
				c4.tls_ignores_cabundle = true
				env.OnDriverLateInit("DIT_STARTUP")
				identity(c4)
				identity(c4)  -- the decoy request, which this controller accepts
				assert.equal("TLS check failed: nothing is sent (see Attention)", env.Properties["Status"])
				assert.equal("Not connected: TLS check failed", env.Properties["Event Stream"])

				env, c4 = house({ ["Event Stream"] = BEFORE })
				env.OnDriverLateInit("DIT_STARTUP")
				identity(c4)
				self_check(c4)
				assert.equal("Connecting", env.Properties["Event Stream"], "the stream's own texts once it starts")
			end)

		it("does not report a light imported under its Hue device's other name after a restart (item 6)", function()
			local env, c4 = house()
			local id
			c4:AddDevice("hue_light.c4z", nil, "Desk Lamp", function(device_id) id = device_id end)
			c4:Bind(c4.device_id, 1, id, 1, "HUE_BRIDGE")
			-- Created under the Hue device's name; the light itself is called otherwise in Hue.
			c4.persist.hue_lights = { ["rid-1"] = { device_id = id, name = "Hue color lamp 1", device_name = "Desk Lamp",
				device_rid = "dev-1", model = "Hue color lamp", caps = {} } }
			env.OnDriverLateInit("DIT_STARTUP")
			assert.equal("None", env.Properties["Attention"])
			-- Composer renames both halves [verified: hardware]; the fake one id at a time.
			c4:RenameDevice(id, "Reading Lamp")
			c4:RenameDevice(fake.project.devices[id].proxy_id, "Reading Lamp")
			env.OnSystemEvent("OnItemNameChanged")
			assert.truthy(env.Properties["Attention"]:find("Reading Lamp is ", 1, true), env.Properties["Attention"])
		end)
	end)

	describe("messages before late init", function()
		it("queues hellos and drops the rest instead of indexing missing state", function()
			local env = fake.load_driver("hue_bridge", { ["Event Stream Transport"] = "Web transfer",
				["Bridge IP Address"] = "" })
			assert.has_no.errors(function()
				env.ExecuteCommand("HUE_HELLO", { device_id = "2001" })
				env.ExecuteCommand("HUE_SET", { rid = "l1", on = "true" })
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Room Audit" })
			end)
			assert.has_no.errors(function() env.OnDriverLateInit("DIT_STARTUP") end)
		end)
	end)
	describe("zone lights wiring (docs/zone-light-design.md §8)", function()
		it("answers the zone pickers, refuses an empty Add Zone Light, and keeps a group hello out of the lights", function()
			local env, c4 = paired_driver()
			env.OnDriverLateInit("DIT_STARTUP")
			assert.same({ { text = "(no zones or rooms on the bridge)", value = "" } }, env.ZoneGroupList())
			assert.same({ { text = "(no zone light device is gone or unbound)", value = "" } }, env.RelinkZoneLightList())
			assert.equal("0 imported", env.Properties["Zone Lights"])
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Add Zone Light", Group = "", Room = "" })
			assert.equal("Not added: pick a zone or room first", fake.last_action(env))
			c4.sent = {}
			env.ExecuteCommand("HUE_HELLO", { rid = "7d6c5b4a-0000-4000-8000-00000000z001", device_id = "77",
				name = "Downstairs", kind = "group" })
			assert.equal(0, #c4.sent, "an unknown, unbound zone light is neither adopted as a light nor answered")
			assert.equal("0 imported", env.Properties["Lights"])
		end)
	end)
end)

-- The Hue Motion device's driver.xml (docs/motion-design.md §2.1 to §2.6):
-- what Composer reads from the file. Its behaviour is motion_driver_spec.
describe("Hue Motion driver (driver.xml)", function()
	before_each(quiet)

	-- The file without its comments, which quote element names.
	local function motion_xml()
		local file = assert(io.open("src/hue_motion/driver.xml"))
		local xml = file:read("*a")
		file:close()
		return (xml:gsub("<!%-%-.-%-%->", ""))
	end

	local function field(body, tag)
		return body:match("<" .. tag .. ">(.-)</" .. tag .. ">")
	end

	local function each(xml, tag)
		local out = {}
		for body in xml:gmatch("<" .. tag .. ">(.-)</" .. tag .. ">") do
			out[#out + 1] = body
		end
		return out
	end

	it("is the motion sensor itself: one contact proxy on 5001 and no capabilities", function()
		local xml = motion_xml()
		local proxies = {}
		for attrs, name in xml:gmatch("<proxy%s([^>]*)>(.-)</proxy>") do
			proxies[#proxies + 1] = { attrs = attrs, name = name }
		end
		assert.equal(1, #proxies)
		assert.equal("contactsingle_motionsensor", proxies[1].name)
		assert.truthy(proxies[1].attrs:find('proxybindingid="5001"', 1, true))
		assert.truthy(proxies[1].attrs:find('name="Hue Motion Sensor"', 1, true))
		assert.is_nil(xml:find("<capabilities", 1, true))
		assert.is_nil(xml:find("<combo", 1, true))
		assert.equal("Hue Motion Sensor", field(xml, "name"))
		assert.equal("Philips Hue", field(xml, "manufacturer"))
		assert.equal("3.3.0", field(xml, "minimum_os_version"))
		assert.equal("Sensors", field(field(xml, "composer_categories"), "category"))
		assert.equal("www/documentation.html", xml:match('<documentation file="([^"]+)"'))
	end)

	it("connects the proxy, the bridge and the temperature output", function()
		local connections = {}
		for _, body in ipairs(each(motion_xml(), "connection")) do
			connections[#connections + 1] = { id = field(body, "id"), type = field(body, "type"),
				consumer = field(body, "consumer"), class = field(body, "classname"), name = field(body, "connectionname") }
		end
		assert.same({
			{ id = "5001", type = "2", consumer = "False", class = "CONTACT_SENSOR", name = "Motion Sensor" },
			{ id = "1", type = "1", consumer = "True", class = "HUE_BRIDGE", name = "Hue Bridge" },
			{ id = "2", type = "1", consumer = "False", class = "TEMPERATURE_VALUE", name = "Temperature" },
		}, connections)
	end)

	it("shows the stock motion sensor icons", function()
		local xml = motion_xml()
		assert.equal("devices_sm/contactsingle_motionsensor_close.gif", field(xml, "small"))
		assert.equal("devices_lg/contactsingle_motionsensor_close.gif", field(xml, "large"))
		assert.is_nil(xml:match("<small[^>]*image_source"), "Composer's own images, not the package's")
		local states = {}
		for _, body in ipairs(each(field(xml, "states"), "state")) do
			states[#states + 1] = { field(body, "id"), field(body, "small"), field(body, "large") }
		end
		assert.same({
			{ "1", "devices_sm\\contactsingle_motionsensor_open.gif", "devices_lg\\contactsingle_motionsensor_open.gif" },
			{ "2", "devices_sm\\contactsingle_motionsensor_close.gif", "devices_lg\\contactsingle_motionsensor_close.gif" },
		}, states)
	end)

	it("declares the rows of §2.2 in that order, the hold time from 0 to 3600 s", function()
		local names, hold = {}, nil
		for _, body in ipairs(each(motion_xml(), "property")) do
			names[#names + 1] = field(body, "name")
			if field(body, "name") == "Occupancy Hold Time (s)" then hold = body end
		end
		assert.same({ "Driver Version", "Status", "Online", "Enabled", "Kind", "Hue Name", "Hue Room", "Model",
			"Hue Motion", "Light Level", "Temperature", "Battery", "Occupancy Hold Time (s)", "Last Action",
			"Debug Mode" }, names)
		assert.equal("RANGED_INTEGER", field(hold, "type"))
		assert.same({ "0", "3600", "0", "false" },
			{ field(hold, "minimum"), field(hold, "maximum"), field(hold, "default"), field(hold, "readonly") })
	end)

	it("has the events of §2.4 with their fixed ids, each naming NAME", function()
		local events = {}
		for _, body in ipairs(each(motion_xml(), "event")) do
			assert.truthy(field(body, "description"):find("NAME", 1, true), field(body, "name"))
			events[#events + 1] = field(body, "id") .. " " .. field(body, "name")
		end
		assert.same({ "1 Light Level Changed", "2 Temperature Changed", "3 Battery Low", "4 Battery Normal",
			"5 Offline", "6 Online", "7 Switched Off In Hue", "8 Switched On In Hue" }, events)
	end)

	it("has the conditionals of §2.5, which TestCondition answers", function()
		local env = fake.load_driver("hue_motion", {}, { device_id = 2101 })
		local conditionals = {}
		for _, body in ipairs(each(motion_xml(), "conditional")) do
			local name = field(body, "name")
			assert.truthy(field(body, "description"):find("NAME", 1, true), name)
			assert.equal("boolean", type(env.TestCondition(name, { LOGIC = "EQUAL", VALUE = "0" })), name)
			local range = field(body, "minimum") and (" " .. field(body, "minimum") .. ".." .. field(body, "maximum")) or ""
			conditionals[#conditionals + 1] = field(body, "id") .. " " .. field(body, "type") .. " " .. name .. range
		end
		assert.same({ "0 BOOL BOOL_ONLINE", "1 BOOL BOOL_ENABLED", "2 BOOL BOOL_BATTERY_LOW",
			"3 NUMBER NUMBER_LIGHT_LEVEL 0..100000", "4 NUMBER NUMBER_TEMPERATURE_C -40..60",
			"5 NUMBER NUMBER_BATTERY_LEVEL 0..100" }, conditionals)
	end)

	it("offers the actions of §2.6, each with a handler", function()
		local env, c4 = fake.load_driver("hue_motion", {}, { device_id = 2101 })
		env.OnDriverInit("DIT_ADDING")
		env.OnDriverLateInit("DIT_ADDING")
		local actions = {}
		for _, body in ipairs(each(motion_xml(), "action")) do
			actions[#actions + 1] = field(body, "name")
			c4.calls = {}
			env.ExecuteCommand("LUA_ACTION", { ACTION = field(body, "command") })
			assert.equal(1, #c4.calls_to("UpdateProperty"), field(body, "name") .. " writes Last Action")
		end
		assert.same({ "Refresh From Bridge", "Test: Motion", "Test: No Motion" }, actions)
	end)

	it("loads from Composer's driver search, unbound, and says so", function()
		local env, c4 = fake.load_driver("hue_motion", {}, { device_id = 2101 })
		assert.has_no.errors(function()
			env.OnDriverInit("DIT_ADDING")
			env.OnDriverLateInit("DIT_ADDING")
		end)
		assert.equal("Not bound to a Hue Bridge", env.Properties["Status"])
		assert.equal("1", env.Properties["Driver Version"])
		assert.same({}, c4.calls_to("SendToProxy"), "nothing to the proxy before a state is known")
	end)
end)
