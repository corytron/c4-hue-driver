local fake = require("helpers.fake_c4")
local log = require("common.log")

local CONFIG = '{"bridgeid":"001788FFFE25B8F8","modelid":"BSB002"}'

describe("bridge.ca_probe", function()
	local probe, http, c4

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		for _, m in ipairs({ "bridge.http", "bridge.certs", "bridge.ca_probe" }) do
			package.loaded[m] = nil
		end
		http = require("bridge.http")
		probe = require("bridge.ca_probe")
	end)

	it("prefers the bundle shipped in the archive, then the sandbox forms, insecure last", function()
		local c = probe.candidates()
		assert.equal(4, #c)
		assert.same({ mode = "cabundle", path = "certs/hue_ca_bundle.pem" }, c[1].ca)
		assert.same({ mode = "cabundle", path = "hue_ca_bundle.pem" }, c[2].ca)
		assert.same({ mode = "cacerts", paths = { "/control4/drivers/lua/sandbox/15/hue_ca_bundle.pem" } }, c[3].ca)
		assert.equal("insecure", c[4].ca.mode)
	end)

	it("runs candidates one at a time and picks the first verifying success", function()
		local results, done, progress = {}, nil, {}
		probe.run("192.0.2.10", {
			on_candidate = function(i, n, name) table.insert(progress, { i, n, name }) end,
			on_result = function(name, ok) table.insert(results, { name, ok }) end,
			on_done = function(winner, insecure_ok) done = { winner, insecure_ok } end,
		})
		local n = #probe.candidates()
		for i = 1, n do
			assert.equal(i, #c4.transfers, "one request in flight at a time")
			local t = c4.transfers[i]
			assert.equal("https://192.0.2.10/api/0/config", t.url)
			assert.equal(10, t.options.timeout)
			if i == 2 or i == 3 or i == n then
				t:respond(200, CONFIG)
			else
				t:done(77, "Problem with the SSL CA cert (path? access rights?)")
			end
		end
		assert.equal(n, #results)
		assert.same({ 1, n, "cabundle certs/ in archive" }, progress[1])
		assert.is_false(results[1][2])
		assert.is_true(results[2][2])
		assert.same({ mode = "cabundle", path = "hue_ca_bundle.pem" }, done[1])
		assert.is_true(done[2])
		assert.equal(0, #c4.active_timers(), "no guard timer left armed")
	end)

	it("skips a candidate whose transfer never calls back", function()
		local results, done = {}, nil
		probe.run("192.0.2.10", {
			on_result = function(name, ok, detail) table.insert(results, { name, ok, detail }) end,
			on_done = function(w, i) done = { w, i } end,
		})
		local silent = c4.transfers[1]
		assert.equal(1, #c4.active_timers(), "guard timer armed")
		c4.fire_timers()
		assert.is_true(silent.cancelled)
		assert.is_false(results[1][2])
		assert.truthy(results[1][3]:find("no callback", 1, true))
		assert.equal(2, #c4.transfers, "moved on to candidate 2")

		silent:done(0, nil) -- late callback from the silent transfer changes nothing
		assert.equal(2, #c4.transfers)

		for i = 2, #probe.candidates() do
			c4.transfers[i]:respond(200, CONFIG)
		end
		assert.equal("hue_ca_bundle.pem", done[1].path)
	end)

	it("reports no winner when only the insecure handshake works", function()
		local done
		probe.run("192.0.2.10", { on_done = function(w, i) done = { w, i } end })
		for i = 1, #probe.candidates() do
			local t = c4.transfers[i]
			if t.options.ssl_verify_peer == false then
				t:respond(200, CONFIG)
			else
				t:done(77, "Problem with the SSL CA cert")
			end
		end
		assert.is_nil(done[1])
		assert.is_true(done[2])
	end)

	it("cancel() stops the probe silently", function()
		local called = false
		local handle = probe.run("192.0.2.10", {
			on_result = function() called = true end,
			on_done = function() called = true end,
		})
		handle:cancel()
		assert.is_true(c4.transfers[1].cancelled)
		assert.equal(0, #c4.active_timers())
		c4.transfers[1]:done(-1, nil)
		c4.fire_timers()
		assert.is_false(called)
		assert.equal(1, #c4.transfers)
	end)

	it("does not touch http.ca itself", function()
		probe.run("192.0.2.10", { on_done = function() end })
		for i = 1, #probe.candidates() do
			c4.transfers[i]:respond(200, CONFIG)
		end
		assert.is_nil(http.ca)
	end)

	describe("pinning_check", function()
		local ca = { mode = "cabundle", path = "certs/hue_ca_bundle.pem" }

		it("reports pinned when the public site is rejected with our bundle", function()
			local verdict
			probe.pinning_check(ca, function(v) verdict = v end)
			local control = c4.transfers[1]
			assert.equal("https://example.com/", control.url)
			assert.is_true(control.options.ssl_verify_host)
			assert.is_nil(control.options.ssl_cabundle)
			control:respond(200, "<html>")

			local pinned = c4.transfers[2]
			assert.equal("certs/hue_ca_bundle.pem", pinned.options.ssl_cabundle)
			assert.is_true(pinned.options.ssl_verify_host, "hostname checking on for a real hostname")
			pinned:done(60, "SSL certificate problem: unable to get local issuer certificate")
			assert.equal("pinned", verdict)
		end)

		it("reports not_pinned when the public site is accepted with our bundle", function()
			local verdict
			probe.pinning_check(ca, function(v) verdict = v end)
			c4.transfers[1]:respond(200, "<html>")
			c4.transfers[2]:respond(200, "<html>")
			assert.equal("not_pinned", verdict)
		end)

		it("is inconclusive when the control request cannot reach the site", function()
			local verdict
			probe.pinning_check(ca, function(v) verdict = v end)
			c4.transfers[1]:done(6, "Could not resolve host")
			assert.equal("inconclusive", verdict)
			assert.equal(1, #c4.transfers)
		end)
	end)
end)
