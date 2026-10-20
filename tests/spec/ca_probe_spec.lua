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

	it("tries alias forms first and the insecure handshake last", function()
		local c = probe.candidates()
		assert.equal("SANDBOX:/hue_ca_bundle.pem", c[1].ca.path)
		assert.same({ "C4Z:/certs/hue_root_bridge.pem", "C4Z:/certs/hue_root_ca_01.pem" }, c[3].ca.paths)
		assert.equal("insecure", c[#c].ca.mode)
		for _, candidate in ipairs(c) do
			assert.truthy(candidate.name)
		end
	end)

	it("uses the device id and sandbox dir in absolute candidates", function()
		local seen = {}
		for _, candidate in ipairs(probe.candidates()) do
			seen[candidate.name] = candidate.ca
		end
		assert.equal("/lua/sandbox/15/hue_ca_bundle.pem", seen["cabundle /lua/sandbox"].path)
		assert.equal("/control4/drivers/lua/sandbox/15/hue_ca_bundle.pem", seen["cabundle GetSandboxDir"].path)
		assert.equal("/opt/control4/var/drivers/c4z/hue_bridge/certs/hue_root_bridge.pem",
			seen["cacerts GetC4zDir"].paths[1])
	end)

	it("runs candidates one at a time and picks the first verifying success", function()
		local results, done = {}, nil
		probe.run("192.0.2.10", {
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
		assert.is_false(results[1][2])
		assert.is_true(results[2][2])
		assert.equal("cacerts", done[1].mode)
		assert.same({ "SANDBOX:/hue_ca_bundle.pem" }, done[1].paths)
		assert.is_true(done[2])
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

	it("does not touch http.ca itself", function()
		probe.run("192.0.2.10", { on_done = function() end })
		for i = 1, #probe.candidates() do
			c4.transfers[i]:respond(200, CONFIG)
		end
		assert.is_nil(http.ca)
	end)
end)
