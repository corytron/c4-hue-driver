-- Driver-level tests: each driver loads against the fake runtime and its
-- entry points behave as Composer would see them.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local CONFIG = '{"name":"Hue Bridge","swversion":"1968096020","bridgeid":"001788FFFE25B8F8","modelid":"BSB002"}'
local SHIPPED = "certs/hue_ca_bundle.pem"

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

	it("pairs from the Composer action and starts the stream with the shipped bundle", function()
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
		local s = c4.transfers[5]
		assert.truthy(s.url:find("/eventstream/clip/v2", 1, true))
		assert.equal("abc123", s.headers["hue-application-key"])
		assert.equal(SHIPPED, s.options.ssl_cabundle)
		assert.is_false(s.options.ssl_verify_host)
		assert.equal(3600, s.options.timeout)
	end)

	it("stays paired after pairing even when the store is not readable yet", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		env.OnDriverLateInit("DIT_STARTUP")
		-- The persistence thread hasn't written yet: reads return nothing.
		c4.PersistGetValue = function() return nil end

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		c4.transfers[1]:respond(200, CONFIG)
		c4.transfers[2]:respond(200, '[{"success":{"username":"abc123","clientkey":"00"}}]')

		assert.equal("Paired", env.Properties["Status"])
		assert.equal("001788fffe25b8f8", env.Properties["Bridge ID"])
		assert.truthy(c4.transfers[3].url:find("/eventstream", 1, true))
		assert.equal("abc123", c4.transfers[3].headers["hue-application-key"])
	end)

	it("reconnects the stream on startup when already paired, and counts events", function()
		local env, c4 = paired_driver({ ["Stream Timeout (s)"] = "600" })
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal("Paired", env.Properties["Status"])
		local s = c4.last_transfer()
		assert.truthy(s.url:find("/eventstream/clip/v2", 1, true))
		assert.equal(600, s.options.timeout)

		s:respond_headers(200, {})
		s:chunk('id: 1:0\ndata: [{"type":"update","id":"x","creationtime":"t","data":[{"type":"light","id":"l"}]}]\n\n')
		assert.equal("1", env.Properties["Events Received"])
		assert.truthy(env.Properties["Last Event"]:match("^%d%d:%d%d:%d%d$"))
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

	it("Test Connection flags a rejected key", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
		local t = c4.last_transfer()
		assert.equal("https://192.0.2.10/clip/v2/resource/bridge", t.url)
		t:respond(403, '{"errors":[{"description":"unauthorized"}]}')
		assert.truthy(env.Properties["Status"]:find("key rejected", 1, true))
	end)

	it("Test Connection reports a bridge ID mismatch", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
		c4.last_transfer():respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"001788fffe000000"}]}')
		assert.truthy(env.Properties["Status"]:find("expected 001788fffe25b8f8", 1, true))
	end)

	it("Check CA Pinning reports the verdict in Status", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Check CA Pinning" })
		c4.last_transfer():respond(200, "<html>")
		assert.equal(SHIPPED, c4.last_transfer().options.ssl_cabundle)
		c4.last_transfer():done(60, "SSL peer certificate or SSH remote key was not OK")
		assert.truthy(env.Properties["Status"]:find("^Pinning check passed"))
	end)

	it("Connection Test against the bridge pauses the driver's stream and restores it", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		local own = c4.last_transfer()

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connection Test", Target = "Bridge" })
		assert.is_true(own.cancelled, "driver's own stream stopped for the test")
		local test_stream = c4.last_transfer()
		assert.truthy(test_stream.url:find("/eventstream/clip/v2", 1, true))
		assert.equal("abc123", test_stream.headers["hue-application-key"])

		test_stream:respond_headers(200, {})
		c4.last_transfer():respond(200, '{"data":[]}')          -- step 2
		local n = #c4.transfers
		c4.transfers[n - 1]:respond(200, '{"data":[]}')          -- step 3a
		c4.transfers[n]:respond(200, '{"data":[]}')              -- step 3b
		c4.last_transfer():respond(200, "<html>")               -- step 4 control

		assert.truthy(env.Properties["Status"]:find(
			"Connection test (bridge): stream OK, GET with stream open OK, concurrent 2/2, control OK", 1, true))
		assert.is_true(test_stream.cancelled)
		assert.truthy(c4.last_transfer().url:find("/eventstream", 1, true), "driver's stream reopened")
		assert.is_false(c4.last_transfer().cancelled)
	end)

	it("Connection Test against the diagnostic server needs the property", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connection Test", Target = "Diagnostic Server" })
		assert.truthy(env.Properties["Status"]:find("^Set the Diagnostic Server property"))

		env.Properties["Diagnostic Server"] = " 192.0.2.7:8443 "
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Connection Test", Target = "Diagnostic Server" })
		local t = c4.last_transfer()
		assert.equal("https://192.0.2.7:8443/stream", t.url)
		assert.is_false(t.options.ssl_verify_peer, "diagnostic server is self-signed")
	end)

	it("Forget Pairing stops the stream and clears the key", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		local s = c4.last_transfer()

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" })
		assert.is_true(s.cancelled)
		assert.is_nil(c4.persist.hue_app_key)
		assert.truthy(env.Properties["Status"]:find("^Not paired"))
		assert.equal("Stopped", env.Properties["Event Stream"])
	end)

	it("restarts the stream when the IP changes", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		local first = c4.last_transfer()

		env.Properties["Bridge IP Address"] = "192.0.2.11"
		env.OnPropertyChanged("Bridge IP Address")
		assert.is_true(first.cancelled)
		assert.equal("https://192.0.2.11/eventstream/clip/v2", c4.last_transfer().url)
		assert.equal("192.0.2.11", c4.persist.hue_bridge_ip)
	end)
end)

describe("Hue Light driver", function()
	before_each(quiet)

	it("reports offline and zero brightness on SYNCHRONIZE", function()
		local env, c4 = fake.load_driver("hue_light", {})
		env.OnDriverLateInit("DIT_STARTUP")
		c4.calls = {}

		env.ReceivedFromProxy(5001, "SYNCHRONIZE", {})

		local sent = c4.calls_to("SendToProxy")
		assert.same({ 5001, "ONLINE_CHANGED", { STATE = false } }, sent[1])
		assert.same({ 5001, "LIGHT_BRIGHTNESS_CHANGED", { LIGHT_BRIGHTNESS_CURRENT = 0 } }, sent[2])
	end)

	it("does not error on unknown proxy commands", function()
		local env = fake.load_driver("hue_light", {})
		assert.has_no.errors(function()
			env.ReceivedFromProxy(5001, "SOMETHING_NEW", {})
		end)
	end)
end)
