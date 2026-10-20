local fake = require("helpers.fake_c4")
local log = require("common.log")

describe("bridge.pinning", function()
	local pinning, c4
	local ca = { mode = "cabundle", path = "certs/hue_ca_bundle.pem" }

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		for _, m in ipairs({ "bridge.http", "bridge.pinning" }) do
			package.loaded[m] = nil
		end
		pinning = require("bridge.pinning")
	end)

	it("reports pinned when the public site is rejected with our bundle", function()
		local verdict
		pinning.check(ca, function(v) verdict = v end)
		local control = c4.transfers[1]
		assert.equal("https://example.com/", control.url)
		assert.is_true(control.options.ssl_verify_host)
		assert.is_nil(control.options.ssl_cabundle)
		control:respond(200, "<html>")

		local pinned = c4.transfers[2]
		assert.equal("certs/hue_ca_bundle.pem", pinned.options.ssl_cabundle)
		assert.is_true(pinned.options.ssl_verify_host, "hostname checking on for a real hostname")
		pinned:done(60, "SSL peer certificate or SSH remote key was not OK")
		assert.equal("pinned", verdict)
	end)

	it("reports not_pinned when the public site is accepted with our bundle", function()
		local verdict
		pinning.check(ca, function(v) verdict = v end)
		c4.transfers[1]:respond(200, "<html>")
		c4.transfers[2]:respond(200, "<html>")
		assert.equal("not_pinned", verdict)
	end)

	it("is inconclusive when the control request cannot reach the site", function()
		local verdict
		pinning.check(ca, function(v) verdict = v end)
		c4.transfers[1]:done(6, "Could not resolve host")
		assert.equal("inconclusive", verdict)
		assert.equal(1, #c4.transfers)
	end)
end)
