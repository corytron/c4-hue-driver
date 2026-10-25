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

	-- Issue #236, item 3: the driver prefixes "Pairing failed: ", so the
	-- module's own text must not carry a "Pairing ... failed" of its own.
	it("reports a key request that got no usable answer once, without a pairing prefix of its own", function()
		pairing.pair("10.0.2.143", handlers())
		c4.transfers[1]:respond(200, CONFIG)
		c4.transfers[2]:done(7, "Couldn't connect to server")
		assert.equal("error", events[2][1])
		assert.equal("No usable answer to the key request: transfer failed (7): Couldn't connect to server", events[2][2])
		assert.is_nil(events[2][2]:find("Pairing", 1, true), events[2][2])
		assert.is_nil(c4.persist.hue_app_key)
	end)

	-- Issue #236, item 1 (docs/bridge-compat-design.md, "Pairing another
	-- bridge (#236)"): the stored bridge id decides before any key is asked for.
	describe("with a stored bridge id", function()
		local PAIRED, OTHER = "001788fffe123abc", "001788fffe456def"
		local function config_of(id)
			return '{"name":"Hue","swversion":"1968096020","apiversion":"1.68.0","bridgeid":"' .. id:upper()
				.. '","modelid":"BSB003"}'
		end

		it("refuses another bridge before showing it or asking it for a key, and stores nothing", function()
			pairing.pair("10.0.2.143", handlers(), PAIRED)
			c4.transfers[1]:respond(200, config_of(OTHER))
			assert.same({ { "error", "Bridge at 10.0.2.143 reports ID 001788fffe456def, expected 001788fffe123abc; "
				.. "run Forget Pairing first to pair with another bridge" } }, events)
			assert.equal(1, #c4.transfers, "no key requested")
			assert.equal(0, #c4.calls_to("PersistSetValue"), "nothing stored")
		end)

		it("pairs the same bridge again with a new key, whatever the case of the stored id", function()
			for _, stored in ipairs({ PAIRED, PAIRED:upper() }) do
				events = {}
				local before = #c4.transfers
				pairing.pair("10.0.2.143", handlers(), stored)
				c4.transfers[before + 1]:respond(200, config_of(PAIRED))
				assert.equal("probed", events[1][1])
				c4.transfers[before + 2]:respond(200, '[{"success":{"username":"newkey"}}]')
				assert.equal("paired", events[2][1])
				assert.same({ key = "newkey", bridge_id = PAIRED, ip = "10.0.2.143", model = "BSB003" }, events[2][2])
			end
		end)

		it("pairs any bridge when no id is stored", function()
			for _, stored in ipairs({ false, "" }) do
				events = {}
				local before = #c4.transfers
				pairing.pair("10.0.2.143", handlers(), stored or nil)
				c4.transfers[before + 1]:respond(200, config_of(OTHER))
				assert.equal("probed", events[1][1])
				assert.equal(before + 2, #c4.transfers, "the key is requested")
			end
		end)

		it("leaves the refusals of the model and the firmware to a bridge it may pair", function()
			pairing.pair("10.0.2.143", handlers(), PAIRED)
			c4.transfers[1]:respond(200, '{"bridgeid":"001788FFFE123ABC","modelid":"BSB001","swversion":"1935074050"}')
			assert.equal("probed", events[1][1])
			assert.truthy(events[2][2]:find("^This is a Hue Bridge v1, round %(BSB001%)"), events[2][2])
			assert.is_nil(pairing.other_bridge("10.0.2.143", { bridge_id = PAIRED }, PAIRED))
		end)
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
	it("refuses the round first-generation bridge before asking for a key", function()
		pairing.pair("192.0.2.10", handlers())
		c4.transfers[1]:respond(200, '{"name":"Hue","swversion":"1935074050","apiversion":"1.35.0",'
			.. '"bridgeid":"001788FFFE25B8F8","modelid":"BSB001"}')
		assert.equal("probed", events[1][1])
		assert.equal("error", events[2][1])
		assert.truthy(events[2][2]:find("^This is a Hue Bridge v1, round %(BSB001%)"), events[2][2])
		assert.equal(1, #c4.transfers, "no key requested")
	end)

	it("refuses a device that is not a Hue bridge", function()
		pairing.pair("192.0.2.10", handlers())
		c4.transfers[1]:respond(200, '{"name":"Thing","swversion":"1","bridgeid":"001788FFFE25B8F8","modelid":"ACME-1"}')
		assert.equal("error", events[2][1])
		assert.equal("The device at 192.0.2.10 is not a Hue bridge (model ACME-1)", events[2][2])
		assert.equal(1, #c4.transfers)
	end)

	it("refuses firmware older than the first with the CLIP v2 API", function()
		pairing.pair("192.0.2.10", handlers())
		c4.transfers[1]:respond(200, '{"name":"Hue","swversion":"1941132080","apiversion":"1.41.0",'
			.. '"bridgeid":"001788FFFE25B8F8","modelid":"BSB002"}')
		assert.equal("error", events[2][1])
		assert.truthy(events[2][2]:find("^Bridge firmware 1941132080 is older than 1948086000"), events[2][2])
		assert.equal(1, #c4.transfers)
	end)

	it("names the address when nothing usable answers the probe", function()
		pairing.pair("192.0.2.10", handlers())
		c4.transfers[1]:respond(200, '{"hello":"world"}')
		assert.equal("error", events[1][1])
		assert.equal("No Hue bridge answered at 192.0.2.10: no bridge ID in config response", events[1][2])
	end)

	-- Code analysis 2026-10-22, L6: whatever the bridge calls the key is stored
	-- and then sent with every request, so it must be a usable string.
	describe("the key in the answer", function()
		it("must be a non-empty string", function()
			for _, body in ipairs({
				'[{"success":{"username":""}}]',
				'[{"success":{"username":42}}]',
				'[{"success":{"username":{"a":1}}}]',
				'[{"success":{"username":true}}]',
				'[{"success":{"clientkey":"00"}}]',
				'[{"success":"yes"}]',
			}) do
				local status, value = pairing.parse_response(c4:JsonDecode(body))
				assert.equal("error", status, body)
				assert.equal("the bridge answered without a usable application key", value, body)
			end
			assert.same({ "ok", "abc-123_XYZ" }, { pairing.parse_response({ { success = { username = "abc-123_XYZ" } } }) })
		end)

		it("must fit in a header: no white space, no control characters", function()
			for _, key in ipairs({ "abc 123", "abc\r\nX-Injected: 1", "abc\t", "\0abc" }) do
				local status = pairing.parse_response({ { success = { username = key } } })
				assert.equal("error", status, key)
			end
		end)

		it("fails the pairing with a clear error and stores nothing", function()
			pairing.pair("192.0.2.10", handlers())
			c4.transfers[1]:respond(200, CONFIG)
			c4.transfers[2]:respond(200, '[{"success":{"username":12345}}]')
			assert.equal("error", events[2][1])
			assert.equal("the bridge answered without a usable application key", events[2][2])
			assert.is_nil(c4.persist.hue_app_key)
			assert.equal(0, #c4.calls_to("PersistSetValue"), "nothing persisted")
		end)
	end)
end)
