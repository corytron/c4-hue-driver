-- The fake runtime's stage 2 additions (#534, docs/hdmi-sync-stage2-design.md
-- §7, contracts C8): the fake Hue Sync Box (fake.syncbox), the hand-written
-- box fixtures (tests/fixtures/hue_syncbox.lua) and driver.xml files with more
-- than one <proxy>. The box is driven through common/https.lua configured as
-- the box's client configures it (contract §3.1), and through raw C4:url
-- transfers where a request must be one https.lua never sends. Placeholders
-- only: box 10.0.2.150, id 0A1B2C3D4E5F, token TEST-TOKEN-NOT-REAL.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local json = require("dkjson")
local F = require("fixtures.hue_syncbox")

local BOX_URL = "https://" .. F.ADDRESS .. "/api/v1"
local BOX_TLS = { ssl_verify_peer = true, ssl_verify_host = false, ssl_cabundle = "certs/hsb_ca.pem" }
local BRIDGE_IP = "10.0.2.143"

-- Whether `needle` occurs in any key or value of `value`, however deep.
local function contains(value, needle, seen)
	if type(value) == "string" then
		return value:find(needle, 1, true) ~= nil
	end
	if type(value) ~= "table" then
		return false
	end
	seen = seen or {}
	if seen[value] then return false end
	seen[value] = true
	for k, v in pairs(value) do
		if contains(k, needle, seen) or contains(v, needle, seen) then return true end
	end
	return false
end

local function keys(t)
	local out = {}
	for k in pairs(t) do out[#out + 1] = k end
	table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
	return out
end

describe("fake sync box (#534)", function()
	local https, c4

	before_each(function()
		log.sink = function() end
		https = require("common.https")
		c4 = fake.install_c4()
	end)

	-- An https instance as the box's client makes it (contract §3.1).
	local function client(extra)
		local opts = {
			ca_bundle = "certs/hsb_ca.pem",
			header_key = { name = "Authorization", prefix = "Bearer " },
			max_keyed = 1,
			timeout = 6,
			connect_timeout = 3,
			max_body = 262144,
			log_prefix = "Sync box: ",
		}
		for k, v in pairs(extra or {}) do opts[k] = v end
		return https.new(opts)
	end

	-- One request through `http`; its result, or nil while unanswered.
	local function call(http, method, path, key, body, ip)
		local result
		http.request({ ip = ip or F.ADDRESS, path = "/api/v1" .. path, method = method, key = key, body = body },
			function(r) result = r end)
		return result
	end

	-- One raw C4:url transfer: { done, code, json, err_code }, and the transfer.
	local function raw(method, url, data, options, headers)
		local got = {}
		local t = c4:url():SetOptions(options or BOX_TLS):OnDone(function(_, responses, err_code)
			local last = responses[#responses]
			got.done, got.err_code = true, err_code
			got.code = last and last.code
			got.json = last and last.body and json.decode(last.body) or nil
		end)
		if method == "GET" then
			t:Get(url, headers)
		elseif method == "POST" then
			t:Post(url, data, headers)
		end
		return got, t
	end

	describe("identity and pairing", function()
		it("answers the unkeyed GET /device at once with the identifying fields", function()
			local h = fake.syncbox()
			local r = call(client(), "GET", "/device")
			assert.is_true(r.ok)
			assert.equal(200, r.code)
			assert.equal(F.BOX_ID, r.json.uniqueId)
			assert.equal("HSB2", r.json.deviceType)
			assert.equal(14, r.json.apiLevel)
			assert.is_nil(r.json.wifi, "the unkeyed answer is the identifying part")
			assert.equal(0, #c4.transfers, "the box took it")
			local rec = h.requests[1]
			assert.equal("GET", rec.method)
			assert.equal("/api/v1/device", rec.path)
			assert.equal("/device", rec.resource)
			assert.equal(BOX_URL .. "/device", rec.url)
			assert.is_false(rec.keyed)
			assert.equal(200, rec.status)
		end)

		it("takes opts.state and opts.device as JSON text too", function()
			local h = fake.syncbox({ state = F.json(F.state.HSB1), device = F.json(F.device.HSC001),
				registrations = { [F.REGISTRATION_ID] = F.TOKEN } })
			local http = client()
			assert.equal("HSC001", call(http, "GET", "/device").json.deviceType)
			assert.equal("HSB1", call(http, "GET", "", F.TOKEN).json.device.deviceType)
			assert.equal("HSB1", call(http, "GET", "/device", F.TOKEN).json.deviceType,
				"with a token, /device is the state's")
			assert.equal("HSC001", h.device.deviceType)
		end)

		it("derives the unkeyed answer from h.state.device when no opts.device is given", function()
			local h = fake.syncbox({ state = F.state.HSB3 })
			assert.is_nil(h.device)
			h.state.device.uniqueId = "FFEEDDCCBBAA"
			local r = call(client(), "GET", "/device")
			assert.equal("FFEEDDCCBBAA", r.json.uniqueId)
			assert.equal("HSB3", r.json.deviceType)
			assert.equal(F.BOX_ID, F.state.HSB3.device.uniqueId, "the fixture is never changed")
		end)

		it("answers code 16 until the button is held, then the first registration; one per hold", function()
			local h = fake.syncbox()
			local http = client()
			local body = { appName = F.APP_NAME, instanceName = "Living Room" }
			local r = call(http, "POST", "/registrations", nil, body)
			assert.is_false(r.ok)
			assert.equal(400, r.code)
			assert.same(F.registration_pending, r.json)
			assert.equal(16, r.json.code)

			h:hold_button()
			assert.is_true(h.button_held)
			r = call(http, "POST", "/registrations", nil, body)
			assert.is_true(r.ok)
			assert.same(F.registration_ok, r.json)
			assert.is_false(h.button_held, "a success releases the button")
			assert.same({ token = F.TOKEN, appName = F.APP_NAME, instanceName = "Living Room", role = "user" },
				h.registrations[F.REGISTRATION_ID])
			assert.same(body, h.requests[2].json, "the request's body is recorded")
			assert.equal(16, call(http, "POST", "/registrations", nil, body).json.code, "the next needs a new hold")

			h:hold_button()
			r = call(http, "POST", "/registrations", nil, body)
			assert.same({ registrationId = "8", accessToken = F.TOKEN .. "-8" }, r.json)

			-- Both tokens work; the list shows both, and the Hue app's, never a token.
			assert.is_true(call(http, "GET", "", F.TOKEN).ok)
			assert.is_true(call(http, "GET", "", F.TOKEN .. "-8").ok)
			local list = call(http, "GET", "/registrations", F.TOKEN).json
			assert.same({ "1", "7", "8" }, keys(list))
			assert.equal("Living Room", list["7"].instanceName)
			assert.is_false(contains(list, F.TOKEN))
		end)

		it("h:release_button closes the window", function()
			local h = fake.syncbox({ button_held = true })
			h:release_button()
			local r = call(client(), "POST", "/registrations", nil, { appName = F.APP_NAME, instanceName = "Den" })
			assert.equal(16, r.json.code)
		end)

		it("refuses a registration body it cannot read", function()
			local h = fake.syncbox({ button_held = true })
			local got = raw("POST", BOX_URL .. "/registrations", "{not json")
			assert.equal(400, got.code)
			assert.same(F.error.invalid_json, got.json)
			got = raw("POST", BOX_URL .. "/registrations", "")
			assert.same(F.error.invalid_key, got.json)
			got = raw("POST", BOX_URL .. "/registrations", json.encode({ appName = F.APP_NAME }))
			assert.same(F.error.invalid_value, got.json)
			got = raw("POST", BOX_URL .. "/registrations", json.encode({ appName = F.APP_NAME, instanceName = 7 }))
			assert.same(F.error.invalid_value, got.json)
			assert.is_true(h.button_held, "no registration was made")
			assert.same({}, h.registrations)
		end)

		it("deletes a registration only with its own token, and its token stops working", function()
			local other = F.TOKEN .. "-9"
			local h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN, ["9"] = other } })
			local http = client()
			assert.equal(401, call(http, "DELETE", "/registrations/7", other).code, "another registration's token")
			assert.equal(401, call(http, "DELETE", "/registrations/1", F.TOKEN).code, "the Hue app's")
			assert.equal(404, call(http, "DELETE", "/registrations/42", F.TOKEN).code)
			local r = call(http, "DELETE", "/registrations/7", F.TOKEN)
			assert.is_true(r.ok)
			assert.is_nil(h.registrations["7"])
			assert.equal(401, call(http, "GET", "", F.TOKEN).code)
			assert.is_true(call(http, "GET", "", other).ok)
		end)

		it("takes registrations as tokens, tables or a list of pairing answers", function()
			local h = fake.syncbox({ registrations = { F.registration_ok,
				["3"] = { token = F.TOKEN .. "-3", instanceName = "Den", role = "admin" } } })
			assert.same({ token = F.TOKEN, appName = F.APP_NAME, instanceName = "Control4", role = "user" },
				h.registrations["7"])
			assert.same({ token = F.TOKEN .. "-3", appName = F.APP_NAME, instanceName = "Den", role = "admin" },
				h.registrations["3"])
			assert.has_error(function() fake.syncbox({ registrations = { ["5"] = {} } }) end)
		end)
	end)

	describe("the keyed API", function()
		it("refuses a keyed resource without a token, and an unknown token everywhere (401)", function()
			local h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN } })
			local http = client()
			local r = call(http, "GET", "")
			assert.equal(401, r.code)
			assert.same(F.error.unauthorized, r.json)
			assert.equal(401, call(http, "GET", "", "NOT-THE-TOKEN").code)
			assert.equal(401, call(http, "GET", "/device", "NOT-THE-TOKEN").code)
			assert.equal(401, call(http, "POST", "/registrations", "NOT-THE-TOKEN",
				{ appName = F.APP_NAME, instanceName = "Den" }).code)
			assert.is_false(h.requests[1].keyed)
			assert.is_true(h.requests[2].keyed)
			assert.is_false(h.requests[2].authorized)
			assert.is_nil(h.requests[2].registration_id)
		end)

		it("answers the whole state to a registered token, as h.state is at the time", function()
			local h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN } })
			local http = client()
			local r = call(http, "GET", "", F.TOKEN)
			assert.is_true(r.ok)
			assert.equal("video", r.json.execution.mode)
			assert.equal(0, r.json.behavior.arcBypassMode)
			assert.equal("Living Room TV", r.json.hue.groups[F.AREA.tv].name)
			assert.same({ "1", "7" }, keys(r.json.registrations))
			assert.is_true(h.requests[1].authorized)
			assert.equal("7", h.requests[1].registration_id)

			h.state.execution.mode = "powersave"
			h.state.execution.hdmiActive = false
			assert.equal("powersave", call(http, "GET", "", F.TOKEN).json.execution.mode)
			assert.equal("Apple TV", call(http, "GET", "/hdmi", F.TOKEN).json.input1.name)
			assert.equal("high", call(http, "GET", "/execution/video", F.TOKEN).json.intensity)
			assert.equal(404, call(http, "GET", "/execution/mode", F.TOKEN).code, "a value is no resource")
			assert.equal(404, call(http, "GET", "/nothing", F.TOKEN).code)
			assert.equal("video", F.state.HSB2.execution.mode, "the fixture is never changed")
		end)

		it("records a PUT and answers it without changing the state; an empty one is refused", function()
			local h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN } })
			local http = client()
			local r = call(http, "PUT", "/execution", F.TOKEN, { mode = "game" })
			assert.is_true(r.ok)
			assert.equal("video", h.state.execution.mode, "stage 2: the spec changes h.state itself")
			local put = h:requests_of("PUT", "/execution")
			assert.equal(1, #put)
			assert.same({ mode = "game" }, put[1].json)
			assert.same(F.error.invalid_key, call(http, "PUT", "/execution", F.TOKEN, {}).json)
			assert.equal(404, call(http, "PUT", "/nothing", F.TOKEN, { a = 1 }).code)
			assert.equal(404, call(http, "PUT", "", F.TOKEN, { a = 1 }).code)
			assert.equal(401, call(http, "PUT", "/execution", nil, { mode = "game" }).code)
		end)

		it("never records the token: the Authorization value is redacted", function()
			local h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN }, button_held = true })
			local http = client()
			call(http, "GET", "", F.TOKEN)
			call(http, "GET", "", "WRONG-TOKEN-VALUE")
			call(http, "POST", "/registrations", nil, { appName = F.APP_NAME, instanceName = "Den" })
			call(http, "DELETE", "/registrations/8", F.TOKEN .. "-8")
			assert.equal("Bearer <redacted>", h.requests[1].headers.Authorization)
			assert.equal("Bearer <redacted>", h.requests[2].headers.Authorization)
			assert.is_nil(h.requests[3].headers.Authorization)
			assert.equal("application/json", h.requests[3].headers["Content-Type"])
			assert.is_false(contains(h.requests, F.TOKEN))
			assert.is_false(contains(h.requests, "WRONG-TOKEN-VALUE"))
		end)

		it("answers 404 off the API", function()
			fake.syncbox()
			local got = raw("GET", "https://" .. F.ADDRESS .. "/description.xml")
			assert.equal(404, got.code)
			assert.same(F.error.not_found, got.json)
		end)

		it("h:requests_of filters by method and by path or resource", function()
			local h = fake.syncbox()
			local http = client()
			call(http, "GET", "/device")
			call(http, "GET", "")
			call(http, "POST", "/registrations", nil, { appName = F.APP_NAME, instanceName = "Den" })
			assert.equal(2, #h:requests_of("GET"))
			assert.equal(1, #h:requests_of("GET", "/device"))
			assert.equal(1, #h:requests_of("GET", "/api/v1/device"))
			assert.equal(1, #h:requests_of("GET", "/api/v1"))
			assert.equal(1, #h:requests_of("GET", ""))
			assert.equal(1, #h:requests_of(nil, "/registrations"))
			assert.equal(3, #h:requests_of())
		end)
	end)

	describe("silence and deferral", function()
		it("silence: recorded, unanswered, then curl 28 at the transfer's timeout on the fake clock", function()
			local h = fake.syncbox()
			local http = client()
			h:silence(true)
			local result
			http.request({ ip = F.ADDRESS, path = "/api/v1/device" }, function(r) result = r end)
			assert.is_nil(result)
			assert.equal(1, #h.requests)
			assert.is_nil(h.requests[1].status)
			assert.equal(0, #c4.calls_to("SetTimer"), "Director's timer, not the driver's")
			assert.is_true(c4.active_timers()[1].syncbox)
			c4.advance(5999)
			assert.is_nil(result)
			c4.advance(1)
			assert.is_false(result.ok)
			assert.equal(28, result.err_code)
			assert.equal(28, h.requests[1].err_code)

			h:silence(false)
			assert.is_true(call(http, "GET", "/device").ok)
		end)

		it("silence: h:silence() alone silences, and a cancelled transfer never ends", function()
			local h = fake.syncbox()
			h:silence()
			local got, t = raw("GET", BOX_URL .. "/device", nil, { ssl_verify_peer = false, timeout = 2 })
			t:Cancel()
			c4.advance(10000)
			assert.is_nil(got.done)
			assert.equal(1, #h.requests)
		end)

		it("defer: requests wait in h.pending and are answered in order from the state then", function()
			local h = fake.syncbox()
			local http = client()
			h:defer(true)
			local first, second
			http.request({ ip = F.ADDRESS, path = "/api/v1/device" }, function(r) first = r end)
			http.request({ ip = F.ADDRESS, path = "/api/v1/device" }, function(r) second = r end)
			assert.is_nil(first)
			assert.equal(2, #h.pending)
			h.state.device.name = "Renamed Box"
			assert.equal(1, h:answer(1))
			assert.equal("Renamed Box", first.json.name)
			assert.is_nil(second)
			h.state.device.name = "Renamed Again"
			assert.equal(1, h:answer())
			assert.equal("Renamed Again", second.json.name)
			assert.equal(0, h:answer())
			h:defer(false)
			assert.is_true(call(http, "GET", "/device").ok)
		end)
	end)

	describe("transport", function()
		it("verifies only with the box's bundle and no host check; curl 60 otherwise", function()
			local h = fake.syncbox()
			local bridge_bundle = client({ ca_bundle = "certs/hue_root_bridge.pem" })
			local r = call(bridge_bundle, "GET", "/device")
			assert.is_false(r.ok)
			assert.equal(60, r.err_code)
			assert.is_true(bridge_bundle.certificate_failure(r))
			assert.equal(60, h.requests[1].err_code)
			assert.is_nil(h.requests[1].status)

			local got = raw("GET", BOX_URL .. "/device", nil,
				{ ssl_verify_peer = true, ssl_verify_host = true, ssl_cabundle = "certs/hsb_ca.pem" })
			assert.equal(60, got.err_code, "the leaf names the box id, not the address")
			got = raw("GET", BOX_URL .. "/device", nil, { ssl_verify_peer = true })
			assert.equal(60, got.err_code, "the system's CAs do not know root-hsb")
			got = raw("GET", BOX_URL .. "/device", nil, { ssl_verify_peer = false })
			assert.equal(200, got.code)

			c4.tls_ignores_cabundle = true
			assert.is_true(call(bridge_bundle, "GET", "/device").ok)
		end)

		it("keeps the decoy rule first: the TLS self-check reads pinned (not_pinned if bundles are ignored)", function()
			local h = fake.syncbox()
			local check = require("common.tlscheck").new({ https = client(), decoy_ca = "certs/decoy.pem",
				path = "/api/v1/device" })
			local verdict
			check.run(F.ADDRESS, function(v) verdict = v end)
			assert.equal("pinned", verdict)
			assert.equal(1, #c4.decoy_transfers)
			assert.equal(0, #h.requests, "the decoy request never reached the box")

			c4.tls_ignores_cabundle = true
			check.run(F.ADDRESS, function(v) verdict = v end)
			assert.equal("not_pinned", verdict)
			assert.equal(200, h.requests[1].status)
		end)

		it("refuses anything but https on 443 (curl 7)", function()
			local h = fake.syncbox()
			assert.equal(7, raw("GET", "http://" .. F.ADDRESS .. "/api/v1/device").err_code)
			assert.equal(7, raw("GET", "https://" .. F.ADDRESS .. ":8443/api/v1/device").err_code)
			assert.equal(200, raw("GET", "https://" .. F.ADDRESS .. ":443/api/v1/device").code)
			assert.equal(3, #h.requests)
			assert.equal(7, h.requests[1].err_code)
		end)

		it("leaves transfers to other addresses to c4.transfers", function()
			local h = fake.syncbox()
			local result
			client().request({ ip = BRIDGE_IP, path = "/api/v1/device" }, function(r) result = r end)
			assert.is_nil(result)
			assert.equal(1, #c4.transfers)
			assert.equal(0, #h.requests)
			c4.transfers[1]:respond(200, '{"answered":"by the spec"}')
			assert.equal("by the spec", result.json.answered)
		end)

		it("is forgotten by a new runtime", function()
			fake.syncbox()
			local c4_2 = fake.install_c4()
			local result
			client().request({ ip = F.ADDRESS, path = "/api/v1/device" }, function(r) result = r end)
			assert.is_nil(result)
			assert.equal(1, #c4_2.transfers)
		end)

		it("moves to another address, and a second box at an address replaces the first", function()
			local h = fake.syncbox()
			local http = client()
			h:move("192.168.1.50")
			assert.equal("192.168.1.50", call(http, "GET", "/device", nil, nil, "192.168.1.50").json.ipAddress)
			assert.is_nil(call(http, "GET", "/device"))
			assert.equal(1, #c4.transfers, "nothing answers at the old address")

			local camera = fake.syncbox({ address = "192.168.1.50", device = F.device.HSC001 })
			assert.equal("HSC001", call(http, "GET", "/device", nil, nil, "192.168.1.50").json.deviceType)
			assert.equal(1, #camera.requests)
			assert.equal(1, #h.requests)
		end)

		it("works through common/https.lua's keyed queue: one keyed request in flight", function()
			local h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN } })
			local http = client()
			h:defer()
			local results = {}
			for i = 1, 3 do
				http.request({ ip = F.ADDRESS, path = "/api/v1", key = F.TOKEN }, function(r) results[i] = r end)
			end
			assert.equal(1, #h.pending, "max_keyed = 1: the rest wait in the client")
			h:answer()
			assert.is_true(results[1].ok)
			assert.equal(1, #h.pending, "the next one started when the first ended")
			h:answer()
			h:answer()
			assert.is_true(results[3].ok)
			assert.equal(3, #h.requests)
		end)
	end)
end)

describe("sync box fixtures (#534)", function()
	-- behavior's on/off flags (R1 §2.8), 0 or 1 wherever a model has them.
	local BOX_FLAGS = { "cecPowersave", "usbPowersave", "hpdInputSwitch", "arcBypassMode", "soloMode",
		"forceDoviNative" }
	local INPUT_FLAGS = { "cecInputSwitch", "linkAutoSync", "hpdInputPortSwitch" }

	local function is_flag(value)
		return value == nil or value == 0 or value == 1
	end

	it("holds one state per model, with the placeholders and 0/1 behavior flags", function()
		assert.same({ "HSB1", "HSB2", "HSB2_behind_receiver", "HSB2_second_output", "HSB3", "HSB3_standalone" },
			keys(F.state))
		for _, name in ipairs(F.models) do
			local s = F.state[name]
			assert.equal(F.BOX_ID, s.device.uniqueId, name)
			assert.equal(F.ADDRESS, s.device.ipAddress, name)
			for _, flag in ipairs(BOX_FLAGS) do
				assert.is_true(is_flag(s.behavior[flag]), name .. " " .. flag)
			end
			for n = 1, 4 do
				local input = s.behavior["input" .. n]
				assert.equal(input ~= nil, s.hdmi["input" .. n] ~= nil, name .. " input" .. n)
				for _, flag in ipairs(INPUT_FLAGS) do
					assert.is_true(is_flag(input and input[flag]), name .. " input" .. n .. " " .. flag)
				end
			end
			assert.truthy(s.hdmi[s.execution.hdmiSource], name .. ": the source is a port")
			if s.hue.operatingMode == "standalone" then
				assert.same({}, s.hue.groups)
			else
				assert.equal(F.BRIDGE_ID, s.hue.bridgeUniqueId, name)
				assert.truthy(s.hue.groups[s.execution.hueTarget], name .. ": the area is one of the groups")
			end
		end
	end)

	it("gives each model what R1 says it has", function()
		local hsb1, hsb3 = F.state.HSB1, F.state.HSB3
		-- HSB1 at API level 9: nothing of levels 10 and 14.
		assert.equal(9, hsb1.device.apiLevel)
		assert.is_nil(hsb1.hue.groupId)
		assert.is_nil(hsb1.hue.operatingMode)
		assert.is_nil(hsb1.behavior.soloMode)
		assert.is_nil(hsb1.behavior.input1.hpdInputPortSwitch)
		assert.is_nil(hsb1.registrations["1"].verified)
		assert.equal(0, hsb1.behavior.forceDoviNative)
		-- HSB3: one input, no ir, no box-wide hot-plug switching.
		assert.same({ "audioSyncSupported", "contentSpecs", "input1", "output", "videoSyncSupported" }, keys(hsb3.hdmi))
		assert.is_nil(hsb3.ir)
		assert.is_nil(hsb3.behavior.hpdInputSwitch)
		assert.equal("powersave", hsb3.execution.mode)
		assert.is_false(hsb3.execution.hdmiActive)
		-- HSB2 syncs to Living Room TV, the area it streams to.
		assert.is_true(F.state.HSB2.execution.syncActive)
		assert.is_true(F.state.HSB2.hue.groups[F.AREA.tv].active)
		assert.equal("standalone", F.state.HSB3_standalone.hue.operatingMode)
	end)

	it("makes each wiring variant differ from HSB2 in its one flag only", function()
		for name, flag in pairs({ HSB2_behind_receiver = "arcBypassMode", HSB2_second_output = "soloMode" }) do
			local variant = F.copy(F.state[name])
			assert.equal(1, variant.behavior[flag], name)
			variant.behavior[flag] = 0
			assert.same(F.state.HSB2, variant, name)
		end
		assert.equal(0, F.state.HSB2.behavior.arcBypassMode)
		assert.equal(0, F.state.HSB2.behavior.soloMode)
	end)

	it("has the unkeyed /device body for every state, and the camera's", function()
		for _, name in ipairs(F.models) do
			local d = F.device[name]
			assert.equal(F.state[name].device.deviceType, d.deviceType, name)
			assert.equal(F.BOX_ID, d.uniqueId, name)
			assert.is_nil(d.wifi, name)
			assert.is_nil(d.temperature, name)
		end
		assert.equal("HSC001", F.device.HSC001.deviceType)
	end)

	it("writes empty objects as {} in M.json and copies keep that", function()
		local text = F.json(F.state.HSB3_standalone)
		assert.truthy(text:find('"groups":{}', 1, true), text)
		assert.truthy(F.json(F.copy(F.state.HSB2)):find('"presets":{}', 1, true))
		assert.same(F.state.HSB1, json.decode(F.json(F.state.HSB1)))
	end)

	it("has the pairing answers and the error bodies of R1 §2.14", function()
		assert.same({ registrationId = "7", accessToken = "TEST-TOKEN-NOT-REAL" }, F.registration_ok)
		assert.same({ code = 16, message = "Invalid State" }, F.registration_pending)
		assert.same({ "invalid_json", "invalid_key", "invalid_state", "invalid_value", "not_found", "unauthorized" },
			keys(F.error))
		assert.same(keys(F.error), keys(F.error_status))
		for name, body in pairs(F.error) do
			assert.equal("number", type(body.code), name)
			assert.equal("string", type(body.message), name)
		end
		assert.equal(401, F.error_status.unauthorized)
	end)

	it("uses the entertainment fixture's area ids and names, in the link's id form", function()
		local E = require("fixtures.hue_entertainment")
		for key, id in pairs(F.AREA) do
			assert.equal(E.area_rids[key], id, key)
			assert.equal(E.area_names[key], F.AREA_NAMES[key], key)
			assert.truthy(id:match("^[%x%-]+$"), key)
		end
	end)
end)

describe("driver.xml with more than one <proxy> (#534)", function()
	local XML = [[<devicedata>
	<name>Test Multi Proxy</name>
	<proxies qty="3">
		<proxy proxybindingid="5001" name="Main Switch" primary="True">avswitch</proxy>
		<proxy proxybindingid="5002" name="Button A">uibutton</proxy>
		<proxy proxybindingid="5003" name="Button B">uibutton</proxy>
	</proxies>
</devicedata>]]
	local c4

	before_each(function()
		log.sink = function() end
		fake.set_driver_xml("test_multiproxy", XML)
		c4 = fake.install_c4()
	end)

	after_each(function()
		fake.set_driver_xml("test_multiproxy", nil)
	end)

	local function add()
		local id
		c4:AddDevice("test_multiproxy.c4z", 7, "Box", function(new_id) id = new_id end)
		return id
	end

	it("makes one proxy device per <proxy>, the first the main one", function()
		local id = add()
		local rec = fake.project.devices[id]
		assert.equal(3001, rec.proxy_id)
		assert.equal(5001, rec.proxy_binding)
		assert.same({ { id = 3002, binding = 5002 }, { id = 3003, binding = 5003 } }, rec.other_proxies)
		assert.same({ name = "Box", room_id = 7, c4i = "avswitch.c4i", protocol_id = id,
			driver_name = "Test Multi Proxy" }, fake.project.devices[3001])
		assert.equal("Button A", fake.project.devices[3002].name)
		assert.equal("uibutton.c4i", fake.project.devices[3003].c4i)
		assert.equal(id, fake.project.devices[3003].protocol_id)
	end)

	it("answers the bound-device lookups on every proxy binding", function()
		local id = add()
		assert.same({ [3001] = "Test Multi Proxy" }, c4:GetBoundConsumerDevices(id, 5001))
		assert.same({ [3002] = "Test Multi Proxy" }, c4:GetBoundConsumerDevices(id, 5002))
		assert.is_nil(c4:GetBoundConsumerDevices(id, 5004))
		assert.equal(id, c4:GetBoundProviderDevice(3001, 5001))
		assert.equal(id, c4:GetBoundProviderDevice(3003, 5003))
		assert.is_nil(c4:GetBoundProviderDevice(3003, 5001))
	end)

	it("lists, moves and deletes every proxy with the device", function()
		local id = add()
		assert.same({ 3001, 3002, 3003 }, keys(c4:GetDevices({ DeviceIds = tostring(id) })[id].proxies))
		assert.same({ 3002, 3003 }, keys(c4:GetDevices({ C4iNames = "uibutton.c4i" })))
		fake.add_room(9, "Den")
		fake.move_device(3002, 9)
		for _, pid in ipairs({ id, 3001, 3002, 3003 }) do
			assert.equal(9, fake.project.devices[pid].room_id, pid)
		end
		fake.delete_device(3003)
		for _, pid in ipairs({ id, 3001, 3002, 3003 }) do
			assert.is_nil(fake.project.devices[pid], pid)
		end
	end)

	it("keeps one proxy for a single-proxy driver and none for the bridge", function()
		local light
		c4:AddDevice("hue_light.c4z", 7, "Lamp", function(new_id) light = new_id end)
		assert.equal(3001, fake.project.devices[light].proxy_id)
		assert.equal(5001, fake.project.devices[light].proxy_binding)
		assert.is_nil(fake.project.devices[light].other_proxies)
		assert.is_nil(fake.project.devices[15].proxy_id, "hue_bridge's proxy is the driver itself")
	end)

	it("reads the Hue Sync Box's five proxies, the AV switch first (contracts C1.1)", function()
		local id
		c4:AddDevice("hue_syncbox.c4z", 7, "TV Sync", function(new_id) id = new_id end)
		local rec = fake.project.devices[id]
		assert.equal(5001, rec.proxy_binding)
		assert.equal("avswitch.c4i", fake.project.devices[rec.proxy_id].c4i)
		assert.equal("TV Sync", fake.project.devices[rec.proxy_id].name)
		local names, bindings = {}, {}
		for _, p in ipairs(rec.other_proxies) do
			assert.equal("uibutton.c4i", fake.project.devices[p.id].c4i)
			names[#names + 1] = fake.project.devices[p.id].name
			bindings[#bindings + 1] = p.binding
		end
		assert.same({ "Hue Sync", "Sync Brighter", "Sync Dimmer", "Sync Intensity" }, names)
		assert.same({ 5002, 5003, 5004, 5005 }, bindings)
	end)
end)
