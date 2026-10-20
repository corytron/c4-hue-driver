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

	it("tries Director-side loading of the sandbox copy first and the insecure handshake last", function()
		local c = probe.candidates()
		assert.equal("cacerts", c[1].ca.mode)
		assert.same({ "/control4/drivers/lua/sandbox/15/hue_ca_bundle.pem" }, c[1].ca.paths)
		assert.equal("insecure", c[#c].ca.mode)
		for _, candidate in ipairs(c) do
			assert.truthy(candidate.name)
			-- Alias forms are known not to work; make sure none crept back in.
			local p = candidate.ca.path or (candidate.ca.paths or {})[1] or ""
			assert.is_nil(p:find("^%u+:/"), candidate.name)
		end
	end)

	it("includes the C4Z directory and /lua/sandbox forms", function()
		local seen = {}
		for _, candidate in ipairs(probe.candidates()) do
			seen[candidate.name] = candidate.ca
		end
		assert.equal("/opt/control4/var/drivers/c4z/hue_bridge/hue_ca_bundle.pem", seen["cabundle C4Z dir"].path)
		assert.equal("/lua/sandbox/15/hue_ca_bundle.pem", seen["cabundle /lua/sandbox"].path)
		assert.same({ "hue_ca_bundle.pem" }, seen["cacerts relative name"].paths)
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
			if i == 3 or i == 4 or i == n then
				t:respond(200, CONFIG)
			else
				t:done(77, "Problem with the SSL CA cert (path? access rights?)")
			end
		end
		assert.equal(n, #results)
		assert.equal(n, #progress)
		assert.same({ 1, n, "cacerts GetSandboxDir" }, progress[1])
		assert.is_false(results[1][2])
		assert.is_true(results[3][2])
		assert.equal("cabundle", done[1].mode)
		assert.equal("/opt/control4/var/drivers/c4z/hue_bridge/hue_ca_bundle.pem", done[1].path)
		assert.is_true(done[2])
		assert.equal(0, #c4.active_timers(), "no guard timer left armed")
	end)

	it("skips a candidate whose transfer never calls back", function()
		local results, done = {}, nil
		probe.run("192.0.2.10", {
			on_result = function(name, ok, detail) table.insert(results, { name, ok, detail }) end,
			on_done = function(w, i) done = { w, i } end,
		})
		-- Candidate 1 goes silent: Director logged a LUA_ERROR and OnDone never fires.
		local silent = c4.transfers[1]
		assert.equal(1, #c4.active_timers(), "guard timer armed")
		c4.fire_timers()
		assert.is_true(silent.cancelled)
		assert.is_false(results[1][2])
		assert.truthy(results[1][3]:find("no callback", 1, true))
		assert.equal(2, #c4.transfers, "moved on to candidate 2")

		-- A late callback from the silent transfer changes nothing.
		silent:done(0, nil)
		assert.equal(2, #c4.transfers)

		local n = #probe.candidates()
		for i = 2, n do
			c4.transfers[i]:respond(200, CONFIG)
		end
		assert.equal("cacerts", done[1].mode)
		assert.same({ "hue_ca_bundle.pem" }, done[1].paths)
	end)

	it("reports no winner when only the insecure handshake works", function()
		local done
		probe.run("192.0.2.10", { on_done = function(w, i) done = { w, i } end })
		local n = #probe.candidates()
		for i = 1, n do
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
end)
