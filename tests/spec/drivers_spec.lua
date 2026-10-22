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
local ROTATING = " (own queue, rotating over 7 spellings; commands use 192.0.2.10)"

local function quiet()
	log.sink = function() end
end

local function paired_driver(extra)
	local props = { ["Bridge IP Address"] = "192.0.2.10" }
	for k, v in pairs(extra or {}) do props[k] = v end
	local env, c4 = fake.load_driver("hue_bridge", props)
	c4.persist.hue_app_key = "abc123"
	c4.persist.hue_bridge_id = "001788fffe25b8f8"
	return env, c4
end

-- Answer the startup self-check (the GET via the check spelling) so the
-- stream can open. Returns the check transfer.
local function answer_check(c4, ok)
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
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
		env.OnDriverInit("DIT_ADDING")
		env.OnDriverLateInit("DIT_ADDING")
		assert.equal("Enter the bridge IP address", env.Properties["Status"])
		assert.equal("1", env.Properties["Driver Version"])
		assert.equal("Not paired", env.Properties["Event Stream"])
		assert.equal(0, #c4.transfers)
	end)

	it("asks for pairing once a valid IP is entered", function()
		local env = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
		env.OnDriverLateInit("DIT_STARTUP")
		env.Properties["Bridge IP Address"] = "192.0.2.10"
		env.OnPropertyChanged("Bridge IP Address")
		assert.truthy(env.Properties["Status"]:find("^Not paired"))
	end)

	it("ignores an invalid IP", function()
		local env = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "not-an-ip" })
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal("Enter the bridge IP address", env.Properties["Status"])
	end)

	it("pairs from the Composer action, self-checks, then streams on the padded spelling", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal(0, #c4.transfers, "no network activity before pairing")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		c4.transfers[1]:respond(200, CONFIG)
		assert.equal("BSB002", env.Properties["Bridge Model"])

		c4.transfers[2]:respond(200, '[{"error":{"type":101,"description":"link button not pressed"}}]')
		assert.truthy(env.Properties["Status"]:find("link button", 1, true))
		assert.equal(2, #c4.transfers, "no stream while unpaired")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		c4.transfers[3]:respond(200, CONFIG)
		c4.transfers[4]:respond(200, '[{"success":{"username":"abc123","clientkey":"00"}}]')
		assert.equal("Paired", env.Properties["Status"])
		assert.equal("001788fffe25b8f8", env.Properties["Bridge ID"])

		local check = c4.transfers[5]
		assert.equal(CHECK_URL, check.url, "self-check before the stream")
		assert.equal("abc123", check.headers["hue-application-key"])
		assert.equal(5, #c4.transfers, "the stream waits for the self-check")
		answer_check(c4)

		local s = c4.transfers[6]
		assert.equal(STREAM_URL, s.url)
		assert.equal("abc123", s.headers["hue-application-key"])
		assert.equal(SHIPPED, s.options.ssl_cabundle)
		assert.is_false(s.options.ssl_verify_host)
		assert.equal(600, s.options.timeout, "driver.xml default")
		assert.equal("192.000.002.10" .. ROTATING, env.Properties["Stream Address"])
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
		assert.equal("192.000.02.10" .. ROTATING, env.Properties["Stream Address"])
		assert.equal("192.000.02.10", c4.persist.hue_stream_spelling)

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Disconnect Event Stream" })
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
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
		assert.equal("192.000.2.10" .. ROTATING, env.Properties["Stream Address"])
	end)

	it("wraps around the family and starts over when the persisted spelling is unknown", function()
		local env, c4 = paired_driver()
		c4.persist.hue_stream_spelling = "192.0.02.10" -- the family's last entry
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		assert.equal(STREAM_URL, c4.last_transfer().url)

		env, c4 = paired_driver()
		c4.persist.hue_stream_spelling = "10.0.2.143" -- from another address
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)
		assert.equal(STREAM_URL, c4.last_transfer().url)
	end)

	it("keeps a single spelling when only one octet can be padded, and says so", function()
		local env, c4 = paired_driver({ ["Bridge IP Address"] = "192.168.1.50" })
		env.OnDriverLateInit("DIT_STARTUP")
		local check = c4.last_transfer()
		assert.equal("https://192.168.01.50/clip/v2/resource/bridge", check.url)
		check:respond(200, '{"data":[{"bridge_id":"001788fffe25b8f8"}]}')
		local first = c4.last_transfer()
		assert.equal("https://192.168.001.50/eventstream/clip/v2", first.url)
		assert.equal(600, first.options.timeout, "still dual-queue: commands stay on the dotted address")
		assert.equal("192.168.001.50 (own queue, no second spelling to rotate; commands use 192.168.1.50)",
			env.Properties["Stream Address"])

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Disconnect Event Stream" })
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connect Event Stream" })
		assert.equal("https://192.168.001.50/eventstream/clip/v2", c4.last_transfer().url)
	end)

	it("stays paired after pairing even when the store is not readable yet", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		env.OnDriverLateInit("DIT_STARTUP")
		c4.PersistGetValue = function() return nil end

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		c4.transfers[1]:respond(200, CONFIG)
		c4.transfers[2]:respond(200, '[{"success":{"username":"abc123","clientkey":"00"}}]')
		assert.equal("Paired", env.Properties["Status"])
		answer_check(c4)
		assert.equal(STREAM_URL, c4.transfers[4].url)
		assert.equal("abc123", c4.transfers[4].headers["hue-application-key"])
	end)

	it("self-checks then reconnects the stream on startup when already paired, and counts events", function()
		local env, c4 = paired_driver({ ["Stream Timeout (s)"] = "900" })
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal("Paired", env.Properties["Status"])
		answer_check(c4)
		local s = c4.last_transfer()
		assert.equal(STREAM_URL, s.url)
		assert.equal(900, s.options.timeout, "configured timeout honoured in dual-queue mode")

		s:respond_headers(200, {})
		s:chunk('id: 1:0\ndata: [{"type":"update","id":"x","creationtime":"t","data":[{"type":"light","id":"l"}]}]\n\n')
		assert.equal("1", env.Properties["Events Received"])
		assert.truthy(env.Properties["Last Event"]:match("^%d%d:%d%d:%d%d$"))
	end)

	it("falls back to a shared queue with a short stream timeout when the self-check fails", function()
		local env, c4 = paired_driver({ ["Stream Timeout (s)"] = "900" })
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4, false)
		local s = c4.last_transfer()
		assert.equal(DOTTED_STREAM_URL, s.url)
		assert.equal(60, s.options.timeout, "capped so commands wait at most a minute")
		assert.truthy(env.Properties["Stream Address"]:find("^192.0.2.10 %(shared queue"))
		assert.truthy(env.Properties["Stream Address"]:find("Couldn't resolve host name", 1, true))
	end)

	it("uses a shared queue when no octet of the address can be padded", function()
		local env, c4 = paired_driver({ ["Bridge IP Address"] = "10.10.10.10" })
		env.OnDriverLateInit("DIT_STARTUP")
		local s = c4.last_transfer()
		assert.equal("https://10.10.10.10/eventstream/clip/v2", s.url, "no self-check, straight to the stream")
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
				if args[2] == true then repeating[#repeating + 1] = args[1] end
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

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection", Host = "192.00.2.10" })
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

	it("Hue Request sends an authenticated request and summarises resource lists", function()
		local lines = {}
		log.sink = function(line) table.insert(lines, line) end
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_check(c4)

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Hue Request", Method = "put",
			Path = "/clip/v2/resource/light/abc", Body = '{"metadata":{"name":"Desk"}}', Host = "192.00.002.10" })
		local t = c4.last_transfer()
		assert.equal("PUT", t.method)
		assert.equal("https://192.00.002.10/clip/v2/resource/light/abc", t.url)
		assert.equal("abc123", t.headers["hue-application-key"])
		assert.same({ metadata = { name = "Desk" } }, c4:JsonDecode(t.data))
		t:respond(200, '{"data":[{"rid":"abc","rtype":"light"}],"errors":[]}')
		assert.truthy(lines[#lines]:find("Hue Request PUT /clip/v2/resource/light/abc via 192.00.002.10: HTTP 200", 1, true))

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Hue Request", Path = "/clip/v2/resource/light" })
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
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Proxy Command", Light = "desk lamp",
				Command = "SET_BRIGHTNESS_TARGET", LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" })
			local m = c4.sent[#c4.sent]
			assert.equal(2005, m.id)
			assert.equal("SET_BRIGHTNESS_TARGET", m.command)
			assert.same({ LIGHT_BRIGHTNESS_TARGET = "50", RATE = "0" }, m.params)
			assert.equal(2005, c4.persist.hue_lights["rid-1"].proxy_id, "proxy id cached in the registry")
		end)

		it("Proxy Command reports an unknown light", function()
			local before = #c4.sent
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Proxy Command", Light = "nope" })
			assert.equal(before, #c4.sent)
			assert.truthy(lines[#lines]:find("no registered light matches", 1, true))
		end)

		it("Lights Report lists the registry and the owner-facing texts", function()
			local before = #lines
			env.ExecuteCommand("LUA_ACTION", { ACTION = "Lights Report" })
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
		local check = c4.last_transfer()
		assert.equal("https://192.00.02.11/clip/v2/resource/bridge", check.url)
		check:respond(200, '{"data":[{"bridge_id":"001788fffe25b8f8"}]}')
		assert.equal("https://192.000.002.11/eventstream/clip/v2", c4.last_transfer().url)
		assert.equal("192.0.2.11", c4.persist.hue_bridge_ip)
	end)

	describe("messages before late init", function()
		it("queues hellos and drops the rest instead of indexing missing state", function()
			local env = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
			assert.has_no.errors(function()
				env.ExecuteCommand("HUE_HELLO", { device_id = "2001" })
				env.ExecuteCommand("HUE_SET", { rid = "l1", on = "true" })
				env.ExecuteCommand("LUA_ACTION", { ACTION = "Room Audit" })
			end)
			assert.has_no.errors(function() env.OnDriverLateInit("DIT_STARTUP") end)
		end)
	end)
end)
