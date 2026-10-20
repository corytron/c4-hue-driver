-- Driver-level tests: each driver loads against the fake runtime and its
-- entry points behave as Composer would see them.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local CONFIG = '{"name":"Hue Bridge","swversion":"1968096020","bridgeid":"001788FFFE25B8F8","modelid":"BSB002"}'
local SANDBOX_ALIAS = "SANDBOX:/hue_ca_bundle.pem"

local function quiet()
	log.sink = function() end
end

-- Answer the CA probe that a paired-with-IP bridge driver runs: every
-- candidate fails except `winner` (a candidate index), which gets the config.
local function answer_probe(c4, winner)
	local candidates = require("bridge.ca_probe").candidates()
	local first = #c4.transfers
	assert(first >= 1, "no probe request in flight")
	for i = 1, #candidates do
		local t = c4.transfers[first + i - 1]
		assert(t and t.url:find("/api/0/config", 1, true), "expected probe request " .. i)
		if i == (winner or 1) then
			t:respond(200, CONFIG)
		else
			t:done(77, "Problem with the SSL CA cert (path? access rights?)")
		end
	end
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
		assert.equal(0, #c4.transfers, "no probe without an IP")
	end)

	it("writes the CA bundle into the sandbox at startup", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal(require("bridge.ca_bundle"), c4.files["hue_ca_bundle.pem"])
	end)

	it("reports a certificate install failure instead of connecting", function()
		local env, c4 = paired_driver()
		c4.FileOpen = function() return -1 end
		env.OnDriverLateInit("DIT_STARTUP")
		assert.truthy(env.Properties["Status"]:find("^Certificate install failed"))
		assert.equal(0, #c4.transfers)
	end)

	it("probes CA configurations before opening the stream, then uses the winner", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		assert.truthy(env.Properties["Status"]:find("^Probing"))
		assert.equal("probing", env.Properties["CA Mode"])

		answer_probe(c4, 2) -- "cacerts SANDBOX alias"
		assert.equal("Paired", env.Properties["Status"])
		assert.equal("ssl_cacerts={" .. SANDBOX_ALIAS .. "}", env.Properties["CA Mode"])

		local s = c4.last_transfer()
		assert.truthy(s.url:find("/eventstream/clip/v2", 1, true))
		assert.same({ SANDBOX_ALIAS }, s.options.ssl_cacerts)
		assert.is_nil(s.options.ssl_cabundle)
		assert.equal("Connecting", env.Properties["Event Stream"])
	end)

	it("never adopts the insecure candidate", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		local n = #require("bridge.ca_probe").candidates()
		answer_probe(c4, n) -- only the unverified handshake works
		assert.truthy(env.Properties["Status"]:find("^No CA configuration works"))
		assert.truthy(env.Properties["CA Mode"]:find("unverified handshake works", 1, true))
		assert.equal(n, #c4.transfers, "no stream opened")
	end)

	it("Diagnose Certificates prints facts whatever the debug level", function()
		local lines = {}
		log.sink = function(line) table.insert(lines, line) end
		local env = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
		env.OnDriverLateInit("DIT_STARTUP")
		lines = {}
		env.ExecuteCommand("LUA_ACTION", { ACTION = "Diagnose Certificates" })
		local text = table.concat(lines, "\n")
		assert.truthy(text:find("GetSandboxDir: /control4/drivers/lua/sandbox/15", 1, true))
		assert.truthy(text:find("http CA: none", 1, true))
		assert.truthy(env.Properties["Status"]:find("^Diagnostics written"))
	end)

	it("asks for pairing once a valid IP is entered", function()
		local env = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
		env.OnDriverLateInit("DIT_STARTUP")
		env.Properties["Bridge IP Address"] = "192.0.2.10"
		env.OnPropertyChanged("Bridge IP Address")
		-- Not paired, so no probe runs yet; it runs when Pair Bridge is used.
		assert.truthy(env.Properties["Status"]:find("^Probing") or env.Properties["Status"]:find("^Not paired"))
	end)

	it("ignores an invalid IP", function()
		local env = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "not-an-ip" })
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal("Enter the bridge IP address", env.Properties["Status"])
	end)

	it("pairs from the Composer action after probing, and starts the stream", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		env.OnDriverLateInit("DIT_STARTUP")
		-- Unpaired but with an IP: the probe runs at startup.
		answer_probe(c4, 1)
		local n = #c4.transfers
		assert.truthy(env.Properties["Status"]:find("^Not paired"))
		assert.equal("Not paired", env.Properties["Event Stream"])

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		c4.transfers[n + 1]:respond(200, CONFIG)
		assert.equal("BSB002", env.Properties["Bridge Model"])

		c4.transfers[n + 2]:respond(200, '[{"error":{"type":101,"description":"link button not pressed"}}]')
		assert.truthy(env.Properties["Status"]:find("link button", 1, true))
		assert.equal(n + 2, #c4.transfers, "no stream while unpaired")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Pair Bridge" })
		c4.transfers[n + 3]:respond(200, CONFIG)
		c4.transfers[n + 4]:respond(200, '[{"success":{"username":"abc123","clientkey":"00"}}]')

		assert.equal("Paired", env.Properties["Status"])
		assert.equal("001788fffe25b8f8", env.Properties["Bridge ID"])
		local s = c4.transfers[n + 5]
		assert.truthy(s.url:find("/eventstream/clip/v2", 1, true))
		assert.equal("abc123", s.headers["hue-application-key"])
		assert.equal(SANDBOX_ALIAS, s.options.ssl_cabundle)
		assert.equal(3600, s.options.timeout)
	end)

	it("counts events and honours the Stream Timeout property", function()
		local env, c4 = paired_driver({ ["Stream Timeout (s)"] = "600" })
		env.OnDriverLateInit("DIT_STARTUP")
		answer_probe(c4, 1)
		local s = c4.last_transfer()
		assert.equal(600, s.options.timeout)

		s:respond_headers(200, {})
		s:chunk('id: 1:0\ndata: [{"type":"update","id":"x","creationtime":"t","data":[{"type":"light","id":"l"}]}]\n\n')
		assert.equal("1", env.Properties["Events Received"])
		assert.truthy(env.Properties["Last Event"]:match("^%d%d:%d%d:%d%d$"))
	end)

	it("Test Connection flags a rejected key", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_probe(c4, 1)

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
		local t = c4.last_transfer()
		assert.equal("https://192.0.2.10/clip/v2/resource/bridge", t.url)
		t:respond(403, '{"errors":[{"description":"unauthorized"}]}')
		assert.truthy(env.Properties["Status"]:find("key rejected", 1, true))
	end)

	it("Test Connection reports a bridge ID mismatch", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_probe(c4, 1)

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
		c4.last_transfer():respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"001788fffe000000"}]}')
		assert.truthy(env.Properties["Status"]:find("expected 001788fffe25b8f8", 1, true))
	end)

	it("Forget Pairing stops the stream and clears the key", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_probe(c4, 1)
		local s = c4.last_transfer()

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" })
		assert.is_true(s.cancelled)
		assert.is_nil(c4.persist.hue_app_key)
		assert.truthy(env.Properties["Status"]:find("^Not paired"))
		assert.equal("Stopped", env.Properties["Event Stream"])
	end)

	it("restarts the stream when the IP changes, without probing again", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_probe(c4, 1)
		local first = c4.last_transfer()

		env.Properties["Bridge IP Address"] = "192.0.2.11"
		env.OnPropertyChanged("Bridge IP Address")
		assert.is_true(first.cancelled)
		assert.equal("https://192.0.2.11/eventstream/clip/v2", c4.last_transfer().url)
		assert.equal("192.0.2.11", c4.persist.hue_bridge_ip)
	end)

	it("Probe CA Paths re-runs the probe and reopens the stream with the result", function()
		local env, c4 = paired_driver()
		env.OnDriverLateInit("DIT_STARTUP")
		answer_probe(c4, 1)
		local first = c4.last_transfer()

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Probe CA Paths" })
		assert.equal("probing", env.Properties["CA Mode"])
		answer_probe(c4, 3) -- "cacerts C4Z alias"
		assert.is_true(first.cancelled)
		local s = c4.last_transfer()
		assert.truthy(s.url:find("/eventstream", 1, true))
		assert.same({ "C4Z:/certs/hue_root_bridge.pem", "C4Z:/certs/hue_root_ca_01.pem" }, s.options.ssl_cacerts)
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
