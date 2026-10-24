local fake = require("helpers.fake_c4")
local log = require("common.log")

local CONFIG = '{"name":"Hue Bridge","swversion":"1968096020","apiversion":"1.68.0",'
	.. '"bridgeid":"001788FFFE25B8F8","modelid":"BSB002"}'

describe("bridge.pairing", function()
	local pairing, credentials, c4, events

	local function handlers()
		return {
			on_probed = function(info) table.insert(events, { "probed", info }) end,
			on_link_button = function(info) table.insert(events, { "link_button", info }) end,
			on_paired = function(creds) table.insert(events, { "paired", creds }) end,
			on_error = function(msg) table.insert(events, { "error", msg }) end,
		}
	end

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		for _, m in ipairs({ "bridge.http", "bridge.config", "bridge.credentials", "bridge.pairing" }) do
			package.loaded[m] = nil
		end
		pairing = require("bridge.pairing")
		credentials = require("bridge.credentials")
		events = {}
	end)

	it("probes the config endpoint without a key and lower-cases the bridge ID", function()
		pairing.pair("192.0.2.10", handlers())
		local probe = c4.transfers[1]
		assert.equal("https://192.0.2.10/api/0/config", probe.url)
		assert.is_nil(probe.headers["hue-application-key"])

		probe:respond(200, CONFIG)
		assert.equal("probed", events[1][1])
		assert.equal("001788fffe25b8f8", events[1][2].bridge_id)
		assert.equal("BSB002", events[1][2].model)
	end)

	it("reports an unreachable bridge and sends nothing else", function()
		pairing.pair("192.0.2.10", handlers())
		c4.transfers[1]:done(60, "SSL certificate problem: unable to get local issuer certificate")
		assert.equal("error", events[1][1])
		assert.truthy(events[1][2]:find("SSL certificate problem", 1, true))
		assert.equal(1, #c4.transfers)
	end)

	it("asks for the link button on error 101 and stores nothing", function()
		pairing.pair("192.0.2.10", handlers())
		c4.transfers[1]:respond(200, CONFIG)
		local post = c4.transfers[2]
		assert.equal("POST", post.method)
		assert.equal("https://192.0.2.10/api", post.url)
		-- "application#device": the driver's own name, not Control4's (docs/licensing-research.md §2).
		assert.same({ devicetype = "c4-hue-driver#bridge", generateclientkey = true }, c4:JsonDecode(post.data))

		post:respond(200, '[{"error":{"type":101,"address":"","description":"link button not pressed"}}]')
		assert.equal("link_button", events[2][1])
		assert.is_nil(c4.persist.hue_app_key)
	end)

	it("stores the key encrypted on success", function()
		pairing.pair("192.0.2.10", handlers())
		c4.transfers[1]:respond(200, CONFIG)
		c4.transfers[2]:respond(200, '[{"success":{"username":"abc123","clientkey":"DEADBEEF"}}]')

		assert.equal("paired", events[2][1])
		assert.equal("abc123", events[2][2].key)
		assert.equal("001788fffe25b8f8", events[2][2].bridge_id)

		local set = c4.calls_to("PersistSetValue")
		local saw_key
		for _, args in ipairs(set) do
			if args[1] == "hue_app_key" then
				saw_key = true
				assert.equal("abc123", args[2])
				assert.is_true(args[3], "key must be stored encrypted")
			end
		end
		assert.is_true(saw_key)

		local creds = credentials.load()
		assert.is_true(credentials.paired(creds))
		assert.equal("192.0.2.10", creds.ip)
	end)

	it("surfaces other bridge errors", function()
		pairing.pair("192.0.2.10", handlers())
		c4.transfers[1]:respond(200, CONFIG)
		c4.transfers[2]:respond(200, '[{"error":{"type":7,"description":"invalid value"}}]')
		assert.equal("error", events[2][1])
		assert.truthy(events[2][2]:find("invalid value", 1, true))
		-- the driver prefixes "Pairing failed: " itself; the module must not
		assert.is_nil(events[2][2]:find("Pairing failed", 1, true), events[2][2])
	end)

	it("rejects a config response without a valid bridge ID", function()
		pairing.pair("192.0.2.10", handlers())
		c4.transfers[1]:respond(200, '{"name":"Not a bridge"}')
		assert.equal("error", events[1][1])
	end)

	it("summarises credentials without the key", function()
		local text = credentials.summary({ key = "secret", bridge_id = "001788fffe25b8f8", ip = "192.0.2.10" })
		assert.equal("key present (6 chars), bridge id 001788fffe25b8f8, ip 192.0.2.10", text)
		assert.equal("key absent, bridge id absent, ip absent", credentials.summary({}))
		assert.equal("none", credentials.summary(nil))
	end)

	it("clears stored credentials", function()
		credentials.save({ key = "k", bridge_id = "001788fffe25b8f8", ip = "192.0.2.10" })
		credentials.clear()
		assert.is_false(credentials.paired(credentials.load()))
	end)
end)
