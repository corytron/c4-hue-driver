-- The fake runtime's stage 2 additions (#534, docs/hdmi-sync-stage2-design.md
-- §7, contracts C8): the fake Hue Sync Box (fake.syncbox), the hand-written
-- box fixtures (tests/fixtures/hue_syncbox.lua) and driver.xml files with more
-- than one <proxy>; and since #547 (docs/fakebox-design.md §2, §4, §8) the box
-- as a state machine (tests/helpers/fake_syncbox.lua): its writes, events,
-- time, transport faults and pure handle, fake.set_url_transport, and the
-- fake's Persist calls refusing a non-boolean encrypted flag. Each rule of
-- docs/syncbox-behaviour.md is checked on its own by the scenarios
-- (tests/spec/syncbox_scenarios_spec.lua); here the box is driven through
-- common/https.lua configured as the box's client configures it (contract
-- §3.1), and through raw C4:url transfers where a request must be one
-- https.lua never sends. Placeholders only: box 10.0.2.150, id 0A1B2C3D4E5F,
-- token TEST-TOKEN-NOT-REAL.

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

	-- One raw C4:url transfer: { done, code, json, body, responses, err_code },
	-- and the transfer.
	local function raw(method, url, data, options, headers)
		local got = {}
		local t = c4:url():SetOptions(options or BOX_TLS):OnDone(function(_, responses, err_code)
			local last = responses[#responses]
			got.done, got.err_code, got.responses = true, err_code, responses
			got.code = last and last.code
			got.body = last and last.body
			got.json = last and last.body and json.decode(last.body) or nil
		end)
		if method == "GET" then
			t:Get(url, headers)
		elseif method == "POST" then
			t:Post(url, data, headers)
		elseif method == "PUT" then
			t:Put(url, data, headers)
		elseif method == "DELETE" then
			t:Delete(url, headers)
		end
		return got, t
	end

	local KEYED = { Authorization = "Bearer " .. F.TOKEN }

	-- A box paired with the placeholder token.
	local function paired(opts)
		opts = opts or {}
		opts.registrations = opts.registrations or { [F.REGISTRATION_ID] = F.TOKEN }
		return fake.syncbox(opts)
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

		it("records a PUT and applies it (SB30, SB5, SB11); a refused one changes nothing (SB20)", function()
			local h = fake.syncbox({ registrations = { [F.REGISTRATION_ID] = F.TOKEN } })
			local http = client()
			local r = call(http, "PUT", "/execution", F.TOKEN, { mode = "game" })
			assert.is_true(r.ok)
			assert.same({}, r.json)
			assert.equal("game", h.state.execution.mode)
			assert.equal("game", h.state.execution.lastSyncMode)
			assert.equal("game", h.state.hdmi.input1.lastSyncMode)
			local put = h:requests_of("PUT", "/execution")
			assert.equal(1, #put)
			assert.same({ mode = "game" }, put[1].json)
			assert.same(F.error.invalid_key, call(http, "PUT", "/execution", F.TOKEN, {}).json)
			assert.same(F.error.invalid_key, call(http, "PUT", "/execution", F.TOKEN, { colour = 1 }).json)
			assert.same(F.error.invalid_value, call(http, "PUT", "/execution", F.TOKEN,
				{ brightness = 120, mode = "ambient" }).json)
			assert.equal(100, h.state.execution.brightness, "nothing of a refused PUT applies")
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

	-- The state machine (#547, docs/syncbox-behaviour.md SBn), through the
	-- client as the driver sends; the scenarios cover each rule on its own.
	describe("the state machine through C4:url (#547)", function()
		it("applies a combined PUT in SB55's order and judges the link on its result (SB56, SB91, SB94)", function()
			local h = paired({ state = F.state.HSB3 })
			local http = client()
			local office = F.AREA.office
			assert.is_true(call(http, "PUT", "/execution", F.TOKEN, { hdmiActive = true, syncActive = true }).ok)
			assert.equal("game", h.state.execution.mode, "input1's last sync mode")
			assert.is_true(h.state.execution.hdmiActive)
			assert.equal("streaming", h.state.hue.connectionState)
			assert.is_true(h.state.hue.groups[office].active)

			assert.is_true(h:event("bridge", { state = "busy" }))
			assert.equal("passthrough", h.state.execution.mode, "another app took the bridge")
			assert.equal("other-app", h.state.hue.groups[office].owner)
			local r = call(http, "PUT", "/execution", F.TOKEN, { brightness = 50, syncActive = true })
			assert.same(F.error.invalid_state, r.json)
			assert.equal(80, h.state.execution.brightness, "judged whole: the brightness did not apply")
			assert.is_true(call(http, "PUT", "/execution", F.TOKEN, { brightness = 50, mode = "passthrough" }).ok)
			assert.equal(50, h.state.execution.brightness)

			assert.is_true(call(http, "PUT", "/hue/groups/" .. office, F.TOKEN, { active = false }).ok)
			assert.equal("connected", h.state.hue.connectionState)
			assert.is_false(h.state.hue.groups[office].active)
			assert.is_nil(h.state.hue.groups[office].owner)
			assert.is_true(call(http, "PUT", "/execution", F.TOKEN, { syncActive = true }).ok)
			assert.equal("streaming", h.state.hue.connectionState)
		end)

		it("puts the intensity of a combined PUT on its new mode, and cycles modes video, music, game (SB38, SB55)",
			function()
				local h = paired()
				local http = client()
				assert.is_true(call(http, "PUT", "/execution", F.TOKEN, { mode = "music", intensity = "subtle" }).ok)
				assert.equal("subtle", h.state.execution.music.intensity)
				assert.equal("high", h.state.execution.video.intensity)
				for _, want in ipairs({ "game", "video", "music" }) do
					call(http, "PUT", "/execution", F.TOKEN, { cycleSyncMode = "next" })
					assert.equal(want, h.state.execution.mode)
				end
				assert.same(F.error.invalid_value, call(http, "PUT", "/execution", F.TOKEN,
					{ backgroundLighting = true }).json, "music has a palette instead (SB46)")
				call(http, "PUT", "/execution", F.TOKEN, { incrementBrightness = 150 })
				assert.equal(200, h.state.execution.brightness, "held within 0 to 200 (SB43)")
			end)

		it("keeps the mode across an input change and runs a preset as part of the PUT (SB39, SB49)", function()
			local state = F.copy(F.state.HSB2)
			state.presets = { p1 = { name = "Movie", execution = { mode = "game", brightness = 150 } } }
			local h = paired({ state = state })
			local http = client()
			assert.is_true(call(http, "PUT", "/execution", F.TOKEN, { hdmiSource = "input3" }).ok)
			assert.equal("video", h.state.execution.mode)
			assert.equal("video", h.state.hdmi.input3.lastSyncMode)
			assert.equal("", h.state.hdmi.contentSpecs, "input3 has no link (SB78)")
			assert.is_true(call(http, "PUT", "/execution", F.TOKEN, { preset = "p1", brightness = 90 }).ok)
			assert.equal("game", h.state.execution.mode)
			assert.equal(90, h.state.execution.brightness, "the PUT's own field wins")
			assert.equal(c4.now_ms, h.state.presets.p1.lastUsed)
			assert.same(F.error.invalid_value, call(http, "PUT", "/execution", F.TOKEN, { preset = "p9" }).json)
		end)

		it("writes behavior, a port, the device's name and the area; refuses what the fakes leave out", function()
			local h = paired()
			local http = client()
			assert.is_true(call(http, "PUT", "/behavior", F.TOKEN, { cecPowersave = 0, input2 = { linkAutoSync = 1 } }).ok)
			assert.equal(0, h.state.behavior.cecPowersave)
			assert.equal(1, h.state.behavior.input2.linkAutoSync)
			assert.equal(15, call(http, "PUT", "/behavior", F.TOKEN, { cecPowersave = true }).json.code, "SB60")
			assert.equal(15, call(http, "PUT", "/behavior", F.TOKEN, { inactivePowersave = 10001 }).json.code)
			assert.equal(13, call(http, "PUT", "/behavior", F.TOKEN, { forceDoviNative = 0 }).json.code, "HSB1 only")
			assert.equal(13, call(http, "PUT", "/behavior", F.TOKEN, { colour = 1, cecPowersave = true }).json.code,
				"keys before values (SB21)")
			assert.equal(404, call(http, "PUT", "/behavior/input1", F.TOKEN, { cecInputSwitch = 0 }).code)

			assert.is_true(call(http, "PUT", "/hdmi/input2", F.TOKEN, { name = "PS5", type = "playstation" }).ok)
			assert.equal("PS5", h.state.hdmi.input2.name)
			assert.equal(13, call(http, "PUT", "/hdmi/input2", F.TOKEN, { status = "linked" }).json.code)
			assert.equal(15, call(http, "PUT", "/hdmi/output", F.TOKEN, { type = "toaster" }).json.code)
			assert.equal(404, call(http, "PUT", "/hdmi", F.TOKEN, { input2 = { name = "X" } }).code, "SB100")

			assert.is_true(call(http, "PUT", "/device", F.TOKEN, { name = "Cinema Box", ledMode = 2 }).ok)
			assert.equal("Cinema Box", call(http, "GET", "/device").json.name, "the unkeyed answer too")
			for _, body in ipairs({ { action = "doSoftwareRestart" }, { uniqueId = "X" }, { bluetooth = false } }) do
				assert.equal(13, call(http, "PUT", "/device", F.TOKEN, body).json.code, "SB111")
			end
			assert.equal(15, call(http, "PUT", "/device", F.TOKEN, { name = " " }).json.code)

			assert.is_true(call(http, "PUT", "/hue", F.TOKEN, { groupId = F.AREA.office }).ok)
			assert.equal(F.AREA.office, h.state.execution.hueTarget)
			assert.is_true(h.state.hue.groups[F.AREA.office].active, "the stream moved (SB48)")
			assert.is_false(h.state.hue.groups[F.AREA.tv].active)
			assert.equal(13, call(http, "PUT", "/hue", F.TOKEN, { bridgeUniqueId = F.BRIDGE_ID }).json.code, "SB96")
		end)

		it("keeps created and lastUsed of a registration and never reuses an id (SB83, SB84, SB88)", function()
			local h = fake.syncbox()
			local http = client()
			h:hold_button()
			local first = call(http, "POST", "/registrations", nil, { appName = F.APP_NAME, instanceName = "Den" })
			local created = c4.now_ms
			c4.advance(60000)
			local list = call(http, "GET", "/registrations", F.TOKEN).json
			assert.equal(created, list["7"].created)
			assert.equal(c4.now_ms, list["7"].lastUsed)
			assert.is_false(list["7"].verified, "API level 14")
			assert.equal("user", list["7"].role)
			assert.is_true(call(http, "DELETE", "/registrations/7", first.json.accessToken).ok)
			h:hold_button()
			local again = call(http, "POST", "/registrations", nil, { appName = F.APP_NAME, instanceName = "Den" })
			assert.equal("8", again.json.registrationId)
			assert.equal(F.TOKEN .. "-8", again.json.accessToken)
		end)

		it("masks a linked port as plugged in powersave in every answer, not in h.state (SB72)", function()
			local h = paired()
			local http = client()
			call(http, "PUT", "/execution", F.TOKEN, { hdmiActive = false })
			assert.equal("linked", h.state.hdmi.input1.status)
			assert.equal("plugged", call(http, "GET", "/hdmi/input1", F.TOKEN).json.status)
			assert.equal("plugged", h:view().hdmi.output.status)
			assert.equal("", h.state.hdmi.contentSpecs)
			call(http, "PUT", "/execution", F.TOKEN, { hdmiActive = true })
			assert.equal("linked", call(http, "GET", "", F.TOKEN).json.hdmi.input1.status)
			assert.equal(F.state.HSB2.hdmi.contentSpecs, h.state.hdmi.contentSpecs, "the fixture's signal (SB78)")
		end)
	end)

	describe("events (#547)", function()
		it("switches on CEC Active Source and hot plug only as the behavior flags say, then auto-syncs (SB70, SB71, SB73)",
			function()
				local h = paired()
				h:request("PUT", "/execution", KEYED, { syncActive = false })
				assert.is_false(h:event("cec_active_source", { input = "input3" }), "its cecInputSwitch is 0")
				assert.equal("input1", h.state.execution.hdmiSource)
				h.state.behavior.input2.linkAutoSync = 1
				assert.is_true(h:event("cec_active_source", { input = 2 }))
				assert.equal("input2", h.state.execution.hdmiSource)
				assert.equal("passthrough", h.state.execution.mode, "input2 reads plugged: no link yet")
				assert.is_true(h:event("signal", { input = "input2", status = "linked" }))
				assert.equal("game", h.state.execution.mode, "auto-sync in input2's last sync mode")
				assert.equal("streaming", h.state.hue.connectionState)

				assert.is_false(h:event("hotplug", { input = "input4" }), "no hot-plug switching on this box")
				assert.equal("plugged", h.state.hdmi.input4.status)
				h.state.behavior.input4.hpdInputPortSwitch = 1
				h:event("tv_standby")
				assert.is_true(h:event("hotplug", { input = "input4" }))
				assert.equal("input4", h.state.execution.hdmiSource)
				assert.equal("passthrough", h.state.execution.mode, "woken from powersave")
				assert.is_false(h:event("cec_active_source", { input = "input5" }), "an input the box lacks")
			end)

		it("ends a sync when the selected input loses its link (SB74), and empties contentSpecs (SB78)", function()
			local h = paired()
			assert.is_true(h:event("signal", { input = "input2", status = "unplugged" }))
			assert.equal("video", h.state.execution.mode, "not the selected input")
			h:event("signal", { input = "input1", status = "plugged" })
			assert.equal("passthrough", h.state.execution.mode)
			assert.equal("", h.state.hdmi.contentSpecs)
			assert.is_false(h.state.hdmi.videoSyncSupported)
			assert.equal("connected", h.state.hue.connectionState)
		end)

		it("goes to powersave on TV standby, USB power and idle time only as behavior says (SB75 to SB77)", function()
			local h = paired({ state = F.state.HSB1 })
			assert.is_false(h:event("idle", { minutes = 30 }), "input2 reads linked")
			h.state.hdmi.input2.status = "plugged"
			assert.is_false(h:event("idle", { minutes = 19 }))
			assert.is_true(h:event("idle", { minutes = 20 }))
			assert.equal("powersave", h.state.execution.mode)
			h:request("PUT", "/execution", KEYED, { hdmiActive = true })
			h.state.behavior.usbPowersave = 0
			assert.is_false(h:event("usb_power_lost"))
			assert.is_true(h:event("tv_standby"))
			local hsb3 = paired({ state = F.state.HSB3_standalone, address = "10.0.2.151" })
			assert.is_false(hsb3:event("usb_power_lost"), "HSB3 has no usbPowersave")
		end)

		it("follows the bridge link (SB90, SB92, SB93)", function()
			local h = paired()
			h:event("bridge", { state = "connected" })
			assert.equal("streaming", h.state.hue.connectionState, "a syncing box keeps streaming")
			h:event("bridge", { state = "disconnected" })
			assert.equal("passthrough", h.state.execution.mode)
			assert.equal("disconnected", h.state.hue.connectionState)
			assert.is_false(h.state.hue.groups[F.AREA.tv].active)
			local _, refused = h:request("PUT", "/execution", KEYED, { syncActive = true })
			assert.equal(16, refused.code)
			h:event("bridge", { state = "busy", group = F.AREA.office })
			assert.is_true(h.state.hue.groups[F.AREA.office].active)
			assert.equal("other-app", h.state.hue.groups[F.AREA.office].owner)
			h:event("bridge", { state = "connected" })
			assert.is_nil(h.state.hue.groups[F.AREA.office].owner)
			assert.equal(200, (h:request("PUT", "/execution", KEYED, { syncActive = true })))
			assert.has_error(function() h:event("bridge", { state = "sideways" }) end)
		end)

		it("renames, forgets a registration and moves (SB87, SB112, SB114)", function()
			local h = paired()
			local http = client()
			h:event("rename", { name = "Cinema Box" })
			assert.equal("Cinema Box", call(http, "GET", "/device").json.name)
			assert.is_true(h:event("app_deletes", { registration = "7" }))
			assert.equal(401, call(http, "GET", "", F.TOKEN).code)
			assert.is_false(h:event("app_deletes", { registration = "42" }))
			assert.is_true(h:event("app_deletes", { registration = "1" }), "the Hue app's")
			assert.is_nil(h:view().registrations["1"])
			h:event("address", { address = "192.0.2.41" })
			assert.equal("192.0.2.41", h.state.device.ipAddress)
			assert.equal("192.0.2.41", call(http, "GET", "/device", nil, nil, "192.0.2.41").json.ipAddress)
		end)

		it("reboots: nothing answers until the time has passed, then the same state (SB120)", function()
			local h = paired()
			local http = client()
			h:request("PUT", "/execution", KEYED, { brightness = 150 })
			h:hold_button()
			assert.is_true(h:event("reboot", { ms = 20000 }))
			assert.is_false(h.button_held, "the pairing window closed")
			assert.is_true(h:down())
			assert.is_nil((h:request("GET", "", KEYED)))
			local result
			http.request({ ip = F.ADDRESS, path = "/api/v1/device" }, function(x) result = x end)
			c4.advance(2999)
			assert.is_nil(result)
			c4.advance(1)
			assert.equal(28, result.err_code, "the connect timeout (3 s)")
			assert.equal("reboot", h.requests[#h.requests].fault)
			c4.advance(17000)
			assert.is_false(h:down())
			assert.equal(150, call(http, "GET", "", F.TOKEN).json.execution.brightness)
			h:event("reboot", { refuse = true })
			assert.equal(7, call(http, "GET", "/device").err_code, "connection refused")
			assert.is_false(h:event("button"), "ignored while the box restarts")
		end)

		it("updates its firmware: the version, the build and the fields of the levels it crosses (SB121, SB122)",
			function()
				local h = paired({ state = F.state.HSB1 })
				h:event("firmware", { version = "2.5.4", api_level = 14 })
				assert.is_true(h:down())
				h:event("advance", { ms = 30000 })
				local v = h:view()
				assert.equal("2.5.4", v.device.firmwareVersion)
				assert.equal(2050400, v.device.buildNumber)
				assert.equal(F.AREA.tv, v.hue.groupId)
				assert.equal(0, v.behavior.input3.hpdInputPortSwitch)
				assert.equal(0, v.behavior.soloMode)
				assert.is_nil(v.hue.operatingMode, "HSB1 has no bridge-free mode")
				assert.is_false(v.registrations["7"].verified)
				assert.is_false(v.registrations["1"].verified)
				assert.equal(14, h:value("device.apiLevel"))
			end)

		it("opens the pairing window for 5 s of the runtime's clock, which advance moves (SB82)", function()
			local h = fake.syncbox()
			local http = client()
			local body = { appName = F.APP_NAME, instanceName = "Den" }
			local fired = 0
			c4:SetTimer(3000, function() fired = fired + 1 end)
			h:event("button")
			h:event("advance", { ms = 4000 })
			assert.equal(1, fired, "the runtime's timers fire too")
			assert.is_true(call(http, "POST", "/registrations", nil, body).ok)
			h:event("button")
			h:event("advance", { ms = 6000 })
			assert.equal(16, call(http, "POST", "/registrations", nil, body).json.code)
			assert.has_error(function() h:event("earthquake") end)
		end)
	end)

	describe("faults (#547)", function()
		it("refuse, wrong_cert and drop end the transfer at once; count limits a fault", function()
			local h = paired()
			h:fault("refuse", { count = 1 })
			assert.equal(7, raw("GET", BOX_URL .. "/device").err_code)
			assert.equal(200, raw("GET", BOX_URL .. "/device").code, "used up")
			h:fault("wrong_cert")
			assert.equal(60, raw("GET", BOX_URL .. "/device").err_code)
			assert.equal(200, raw("GET", BOX_URL .. "/device", nil, { ssl_verify_peer = false }).code)
			h:fault("wrong_cert", false)
			h:fault("drop")
			assert.equal(52, raw("GET", BOX_URL .. "/device").err_code)
			h:fault("drop", { code = 56, processed = true })
			local got = raw("PUT", BOX_URL .. "/execution", json.encode({ brightness = 30 }), nil, KEYED)
			assert.equal(56, got.err_code)
			assert.is_nil(got.code)
			assert.equal(30, h.state.execution.brightness, "the box handled it before the drop")
			assert.equal("drop", h.requests[#h.requests].fault)
			h:fault()
			assert.equal(200, raw("GET", BOX_URL .. "/device").code)
		end)

		it("latency: answers later on the fake clock, one at a time; a timeout first, and the box still acts", function()
			local h = paired()
			h:fault("latency", { ms = 1000 })
			local a = raw("GET", BOX_URL .. "/device")
			local b = raw("GET", BOX_URL .. "/device")
			c4.advance(999)
			assert.is_nil(a.done)
			c4.advance(1)
			assert.equal(200, a.code)
			assert.is_nil(b.done, "the box serves one request at a time")
			c4.advance(1000)
			assert.equal(200, b.code)

			h:fault("latency", { ms = 8000 })
			local result
			client().request({ ip = F.ADDRESS, path = "/api/v1/execution", method = "PUT", key = F.TOKEN,
				body = { brightness = 40 } }, function(r) result = r end)
			c4.advance(6000)
			assert.equal(28, result.err_code)
			assert.equal(100, h.state.execution.brightness)
			c4.advance(2000)
			assert.equal(40, h.state.execution.brightness, "the box handled it at its time")
		end)

		it("other_id: another box answers at the address, with its own id and none of our tokens", function()
			local h = paired()
			local http = client()
			h:fault("other_id")
			assert.equal("0A1B2C3D4E60", call(http, "GET", "/device").json.uniqueId)
			assert.equal(401, call(http, "GET", "", F.TOKEN).code)
			assert.is_true(h.requests[#h.requests].other)
			assert.equal(F.BOX_ID, h.state.device.uniqueId, "ours is unchanged")
			assert.equal(0, #h.other.requests, "recorded at the address, on h.requests")
			h:fault("other_id", false)
			assert.equal(F.BOX_ID, call(http, "GET", "/device").json.uniqueId)
		end)

		it("5xx answers instead of the box; method and path narrow a fault", function()
			local h = paired()
			local http = client()
			h:fault("http5xx", { method = "PUT", path = "/execution" })
			assert.is_true(call(http, "GET", "", F.TOKEN).ok, "a GET is not touched")
			local r = call(http, "PUT", "/execution", F.TOKEN, { brightness = 10 })
			assert.equal(500, r.code)
			assert.equal(500, r.json.code)
			assert.equal(100, h.state.execution.brightness, "the box did not handle it")
			assert.is_true(call(http, "PUT", "/hdmi/input2", F.TOKEN, { name = "PS5" }).ok)
			h:fault("5xx", { status = 503, count = 1 })
			assert.equal(503, call(http, "GET", "/device").code)
			assert.equal(200, call(http, "GET", "/device").code)
			assert.has_error(function() h:fault("gremlins") end)
		end)

		it("redirect: a keyed request refuses it; C4:url follows an unkeyed one to the box, or ends", function()
			local h = paired()
			h:fault("redirect")
			local r = call(client(), "GET", "", F.TOKEN)
			assert.equal(302, r.code)
			assert.equal("redirect refused (HTTP 302)", r.err)
			h:fault("redirect", { count = 1 })
			local got = raw("GET", BOX_URL .. "/device")
			assert.equal(404, got.code, "followed to https://<box>/redirected, off the API")
			assert.equal("/redirected", h.requests[#h.requests].path)
			h:fault("redirect", { location = BOX_URL .. "/device", count = 1 })
			got = raw("GET", BOX_URL .. "/device")
			assert.equal(2, #got.responses)
			assert.equal(302, got.responses[1].code)
			assert.equal(200, got.code)
			assert.equal(BOX_URL .. "/device", h.requests[#h.requests].redirected_from)
			h:fault("redirect", { location = "http://" .. F.ADDRESS .. "/api/v1/device" })
			assert.equal(7, raw("GET", BOX_URL .. "/device").err_code, "plain http")
			h:fault("redirect", { location = BOX_URL .. "/device" })
			assert.equal(47, raw("GET", BOX_URL .. "/device").err_code, "a loop")
		end)

		it("truncated cuts the body (curl 18, or a short body); oversized pads it past the client's limit", function()
			local h = paired()
			local http = client()
			h:fault("truncated", { count = 1 })
			local r = call(http, "GET", "", F.TOKEN)
			assert.equal(18, r.err_code)
			h:fault("truncated", { err_code = 0, count = 1 })
			r = call(http, "GET", "", F.TOKEN)
			assert.is_true(r.ok)
			assert.is_nil(r.json, "half a JSON text")
			h:fault("oversized", { count = 1 })
			r = call(http, "GET", "", F.TOKEN)
			assert.is_false(r.ok)
			assert.truthy(r.err:find("refused", 1, true))
			h:fault("oversized", { bytes = 400000, count = 1 })
			local got = raw("GET", BOX_URL, nil, nil, KEYED)
			assert.equal(400000, #got.body)
			assert.equal("video", got.json.execution.mode, "valid JSON with a padding key")
		end)
	end)

	describe("the handle without C4:url (#547)", function()
		it("answers h:request on its own clock, M.new with no runtime", function()
			local SB = require("helpers.fake_syncbox")
			local h = SB.new({ state = F.state.HSB2 }, nil, true)
			assert.equal(0, h:now())
			h:event("button")
			local status, body = h:request("POST", "/registrations", {}, { appName = F.APP_NAME, instanceName = "Den" })
			assert.equal(200, status)
			local auth = { Authorization = "Bearer " .. body.accessToken }
			assert.equal(200, (h:request("PUT", "/api/v1/execution", auth, '{"mode":"music"}')))
			assert.equal("music", h:value("execution.mode"))
			assert.is_nil(h:value("execution.nothing.here"))
			status, body = h:request("GET", "", auth)
			assert.equal(200, status)
			body.execution.mode = "changed"
			assert.equal("music", h.state.execution.mode, "the answer is a copy")
			h:event("reboot")
			assert.is_nil((h:request("GET", "", auth)))
			h:event("advance", { seconds = 30 })
			assert.equal(30000, h:now())
			assert.equal(200, (h:request("GET", "", auth)))
			assert.is_nil(SB.at(F.ADDRESS), "hidden: not at its address")
		end)
	end)

	describe("fake.set_url_transport (#547)", function()
		after_each(function()
			fake.set_url_transport(nil)
		end)

		it("hands every transfer to the transport, the box's and the decoy's too, until cleared", function()
			local h = fake.syncbox()
			local seen = {}
			fake.set_url_transport(function(t, runtime)
				seen[#seen + 1] = { method = t.method, url = t.url, options = t.options, c4 = runtime }
				t:respond(200, '{"from":"transport"}')
			end)
			local r = call(client(), "GET", "/device")
			assert.equal("transport", r.json.from)
			assert.equal("GET", seen[1].method)
			assert.equal(BOX_URL .. "/device", seen[1].url)
			assert.equal("certs/hsb_ca.pem", seen[1].options.ssl_cabundle)
			assert.equal(c4, seen[1].c4)
			raw("GET", BOX_URL .. "/device", nil, { ssl_cabundle = "certs/decoy.pem" })
			assert.equal(2, #seen)
			assert.equal(0, #c4.decoy_transfers)
			assert.equal(0, #h.requests)
			assert.equal(0, #c4.transfers)
			fake.load_driver("hue_syncbox")
			assert.has_error(function() fake.set_url_transport("curl") end)

			fake.set_url_transport(nil)
			c4 = fake.install_c4()
			h = fake.syncbox()
			assert.equal(200, call(client(), "GET", "/device").code)
			assert.equal(1, #h.requests)
		end)
	end)
end)

describe("fake C4:PersistGetValue and PersistSetValue (#547)", function()
	-- [verified: house, build 682, 2026-11-17]: an explicit nil as the
	-- encrypted flag raises on the controller.
	it("raise on an encrypted argument that is there but not a boolean", function()
		local c4 = fake.install_c4()
		c4:PersistSetValue("a", "1")
		c4:PersistSetValue("b", "2", true)
		c4:PersistSetValue("c", "3", false)
		assert.equal("1", c4:PersistGetValue("a"))
		assert.equal("2", c4:PersistGetValue("b", true))
		assert.equal("3", c4:PersistGetValue("c", false))
		assert.has_error(function() c4:PersistGetValue("a", nil) end)
		assert.has_error(function() c4:PersistSetValue("a", "1", nil) end)
		assert.has_error(function() c4:PersistSetValue("a", "1", "yes") end)
		assert.has_error(function() c4:PersistGetValue("a", 1) end)
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
