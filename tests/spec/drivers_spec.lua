-- Driver-level tests: each driver loads against the fake runtime and its
-- entry points behave as Composer would see them.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local CONFIG = '{"name":"Hue Bridge","swversion":"1968096020","bridgeid":"001788FFFE25B8F8","modelid":"BSB002"}'

local function quiet()
	log.sink = function() end
end

describe("Hue Bridge driver", function()
	before_each(quiet)

	it("asks for an IP address when none is set", function()
		local env = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "" })
		env.OnDriverInit("DIT_ADDING")
		env.OnDriverLateInit("DIT_ADDING")
		assert.equal("Enter the bridge IP address", env.Properties["Status"])
		assert.equal("1", env.Properties["Driver Version"])
		assert.equal("Not paired", env.Properties["Event Stream"])
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

	it("pairs from the Composer action and starts the stream", function()
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
		assert.equal(3600, s.options.timeout)
		assert.equal("Connecting", env.Properties["Event Stream"])
	end)

	it("reconnects the stream on startup when already paired", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		c4.persist.hue_app_key = "abc123"
		c4.persist.hue_bridge_id = "001788fffe25b8f8"
		env.OnDriverLateInit("DIT_STARTUP")

		assert.equal("Paired", env.Properties["Status"])
		local s = c4.last_transfer()
		assert.truthy(s.url:find("/eventstream/clip/v2", 1, true))

		s:respond_headers(200, {})
		s:chunk('id: 1:0\ndata: [{"type":"update","id":"x","creationtime":"t","data":[{"type":"light","id":"l"}]}]\n\n')
		assert.equal("1", env.Properties["Events Received"])
		assert.truthy(env.Properties["Last Event"]:match("^%d%d:%d%d:%d%d$"))
	end)

	it("honours the Stream Timeout property", function()
		local env, c4 = fake.load_driver("hue_bridge", {
			["Bridge IP Address"] = "192.0.2.10",
			["Stream Timeout (s)"] = "600",
		})
		c4.persist.hue_app_key = "abc123"
		c4.persist.hue_bridge_id = "001788fffe25b8f8"
		env.OnDriverLateInit("DIT_STARTUP")
		assert.equal(600, c4.last_transfer().options.timeout)
	end)

	it("Test Connection flags a rejected key", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		c4.persist.hue_app_key = "abc123"
		c4.persist.hue_bridge_id = "001788fffe25b8f8"
		env.OnDriverLateInit("DIT_STARTUP")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
		local t = c4.last_transfer()
		assert.equal("https://192.0.2.10/clip/v2/resource/bridge", t.url)
		t:respond(403, '{"errors":[{"description":"unauthorized"}]}')
		assert.truthy(env.Properties["Status"]:find("key rejected", 1, true))
	end)

	it("Test Connection reports a bridge ID mismatch", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		c4.persist.hue_app_key = "abc123"
		c4.persist.hue_bridge_id = "001788fffe25b8f8"
		env.OnDriverLateInit("DIT_STARTUP")

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Test Connection" })
		c4.last_transfer():respond(200, '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"001788fffe000000"}]}')
		assert.truthy(env.Properties["Status"]:find("expected 001788fffe25b8f8", 1, true))
	end)

	it("Forget Pairing stops the stream and clears the key", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		c4.persist.hue_app_key = "abc123"
		c4.persist.hue_bridge_id = "001788fffe25b8f8"
		env.OnDriverLateInit("DIT_STARTUP")
		local s = c4.last_transfer()

		env.ExecuteCommand("LUA_ACTION", { ACTION = "Forget Pairing" })
		assert.is_true(s.cancelled)
		assert.is_nil(c4.persist.hue_app_key)
		assert.truthy(env.Properties["Status"]:find("^Not paired"))
		assert.equal("Stopped", env.Properties["Event Stream"])
	end)

	it("restarts the stream when the IP changes", function()
		local env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = "192.0.2.10" })
		c4.persist.hue_app_key = "abc123"
		c4.persist.hue_bridge_id = "001788fffe25b8f8"
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
