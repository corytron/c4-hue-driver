local fake = require("helpers.fake_c4")
local log = require("common.log")

describe("bridge.pinning", function()
	local pinning, c4
	local ca = { path = "certs/hue_ca_bundle.pem" }

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

	-- Code analysis 2026-10-22, L5: only a certificate-verification failure of
	-- the second request proves the bundle decides.
	it("is inconclusive when the second request fails for a reason other than its certificate", function()
		for _, failure in ipairs({
			{ 28, "Timeout was reached" },
			{ 7, "Failed to connect to example.com port 443: Connection refused" },
			{ 6, "Couldn't resolve host name" },
			{ 77, "Problem with the SSL CA cert (path? access rights?)" },
			{ 35, "SSL connect error" },
		}) do
			local verdict, detail
			pinning.check(ca, function(v, d) verdict, detail = v, d end)
			c4.last_transfer():respond(200, "<html>")
			c4.last_transfer():done(failure[1], failure[2])
			assert.equal("inconclusive", verdict, failure[2])
			assert.truthy(detail:find(failure[2], 1, true), detail)
		end
	end)

	it("is inconclusive when the second request cannot even start", function()
		local verdict
		local real_url = c4.url
		local calls = 0
		c4.url = function(self)
			local t = real_url(self)
			calls = calls + 1
			if calls == 2 then
				t.Get = function() error("Error loading certificate: fopen: No such file or directory") end
			end
			return t
		end
		pinning.check(ca, function(v) verdict = v end)
		c4.transfers[1]:respond(200, "<html>")
		assert.equal("inconclusive", verdict)
	end)

	it("reports pinned for curl's older code for a refused peer certificate", function()
		local verdict
		pinning.check(ca, function(v) verdict = v end)
		c4.transfers[1]:respond(200, "<html>")
		c4.transfers[2]:done(51, "SSL peer certificate or SSH remote key was not OK")
		assert.equal("pinned", verdict)
	end)

	-- Issue #239: an inconclusive answer names the request that failed and the
	-- transfer's error; it used to read "example.com unreachable" whatever happened.
	describe("status", function()
		local function check()
			local result = {}
			pinning.check(ca, function(v, d) result.verdict, result.detail = v, d end)
			return result
		end

		it("names the transfer's error when the site cannot be reached with the system CAs", function()
			local result = check()
			c4.transfers[1]:done(6, "Could not resolve host: example.com")
			assert.equal("inconclusive", result.verdict)
			assert.equal("Pinning check inconclusive: example.com unreachable with the system CAs "
				.. "(transfer failed (6): Could not resolve host: example.com)", pinning.status(result.verdict, result.detail))
		end)

		it("names the transfer's error when the request with the bundle fails otherwise, without 'unreachable'", function()
			for _, failure in ipairs({
				{ 28, "Timeout was reached" },
				{ 7, "Failed to connect to example.com port 443: Connection refused" },
				{ 77, "Problem with the SSL CA cert (path? access rights?)" },
			}) do
				local result = check()
				c4.last_transfer():respond(200, "<html>")
				c4.last_transfer():done(failure[1], failure[2])
				local status = pinning.status(result.verdict, result.detail)
				assert.equal("Pinning check inconclusive: example.com failed with the bundle for a reason other than "
					.. "its certificate (transfer failed (" .. failure[1] .. "): " .. failure[2] .. ")", status)
				assert.is_nil(status:find("unreachable", 1, true), status)
			end
		end)

		it("names a request with the bundle that could not even start", function()
			local real_url = c4.url
			local calls = 0
			c4.url = function(self)
				local t = real_url(self)
				calls = calls + 1
				if calls == 2 then
					t.Get = function() error("Error loading certificate: fopen: No such file or directory", 0) end
				end
				return t
			end
			local result = check()
			c4.transfers[1]:respond(200, "<html>")
			assert.equal("Pinning check inconclusive: example.com failed with the bundle for a reason other than its "
				.. "certificate (could not start transfer: Error loading certificate: fopen: No such file or directory)",
				pinning.status(result.verdict, result.detail))
		end)

		it("keeps the texts of the conclusive answers", function()
			local result = check()
			c4.transfers[1]:respond(200, "<html>")
			c4.transfers[2]:done(60, "SSL peer certificate or SSH remote key was not OK")
			assert.equal("Pinning check passed: only Signify-signed certificates are trusted",
				pinning.status(result.verdict, result.detail))
			assert.equal("Pinning check FAILED: public CAs are trusted too; see Lua output",
				pinning.status("not_pinned", "HTTP 200"))
			assert.equal("Pinning check inconclusive: no reason given", pinning.status("inconclusive"))
			assert.equal("something else", pinning.status("something else"))
		end)
	end)

	it("keeps the peer verified on both requests (tls is applied on top of the bundle's options)", function()
		pinning.check(ca, function() end)
		local control = c4.transfers[1]
		assert.is_true(control.options.ssl_verify_peer)
		assert.is_nil(control.options.ssl_cabundle, "the platform's CAs for the control")
		control:respond(200, "<html>")
		assert.is_true(c4.transfers[2].options.ssl_verify_peer)
	end)
end)
