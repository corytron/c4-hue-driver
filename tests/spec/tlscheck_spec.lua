-- Issue #53: the release build's own pinning check. A request to the bridge
-- with a decoy CA bundle must fail certificate verification; an HTTP answer
-- means the configured bundle does not decide. Security review 2026-10-25,
-- finding 3: the Director version on which the check answered pinned is
-- remembered, so the driver can accept an inconclusive answer on that version
-- only.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local function read_file(path)
	local f = assert(io.open(path, "rb"))
	local data = f:read("*a")
	f:close()
	return data
end

describe("bridge.tlscheck", function()
	local tlscheck, http, c4

	-- Run the check against the bridge and answer its request with `drive`.
	-- Returns the verdict, the detail and the transfer.
	local function check(drive)
		local verdict, detail, calls = nil, nil, 0
		tlscheck.run("10.0.2.143", function(v, d)
			verdict, detail, calls = v, d, calls + 1
		end)
		local t = c4.last_transfer()
		if drive then
			drive(t)
		end
		assert.is_true(calls <= 1, "called back once")
		return verdict, detail, t
	end

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		-- The fake fails a decoy-bundle request by itself (as OS 3.4.2 would);
		-- this spec answers the request itself, with every possible outcome.
		c4.tls_ignores_cabundle = true
		for _, m in ipairs({ "bridge.http", "bridge.tlscheck" }) do
			package.loaded[m] = nil
		end
		http = require("bridge.http")
		tlscheck = require("bridge.tlscheck")
	end)

	it("answers pinned on the fake runtime's model of OS 3.4.2, which honours the bundle", function()
		c4.tls_ignores_cabundle = false
		local verdict, detail
		tlscheck.run("10.0.2.143", function(v, d) verdict, detail = v, d end)
		assert.equal("pinned", verdict)
		assert.truthy(detail:find("(60)", 1, true), detail)
		assert.equal(1, #c4.decoy_transfers)
		assert.equal("https://10.0.2.143/api/0/config", c4.decoy_transfers[1].url)
	end)

	it("asks the bridge's public config with the decoy bundle and the bridge's TLS options otherwise", function()
		local _, _, t = check()
		assert.equal("GET", t.method)
		assert.equal("https://10.0.2.143/api/0/config", t.url)
		assert.equal("certs/decoy_ca.pem", t.options.ssl_cabundle)
		assert.is_true(t.options.ssl_verify_peer, "the peer is verified, against the decoy")
		assert.is_false(t.options.ssl_verify_host, "as for every bridge request (the CN is the bridge id)")
		assert.is_false(t.options.fail_on_error)
		assert.equal(tlscheck.TIMEOUT, t.options.timeout)
	end)

	it("never sends the application key", function()
		local _, _, t = check()
		assert.is_nil(t.headers["hue-application-key"])
		assert.same({}, t.headers, "no header at all")
		assert.is_nil(t.data, "no body either")
	end)

	it("names the decoy in the same relative form as the Signify bundle", function()
		assert.equal("certs/decoy_ca.pem", tlscheck.DECOY_CA)
		assert.equal(http.CA_BUNDLE:match("^(certs/)"), tlscheck.DECOY_CA:match("^(certs/)"))
		assert.is_nil(tlscheck.DECOY_CA:find("^/"), "relative to the archive, never absolute (curl 77 on OS 3.4.2)")
	end)

	it("reports pinned when the decoy request fails certificate verification", function()
		local verdict, detail = check(function(t)
			t:done(60, "SSL certificate problem: unable to get local issuer certificate")
		end)
		assert.equal("pinned", verdict)
		assert.truthy(detail:find("unable to get local issuer certificate", 1, true), detail)

		verdict = check(function(t) t:done(51, "SSL peer certificate or SSH remote key was not OK") end)
		assert.equal("pinned", verdict, "curl before 7.62")
	end)

	it("reports not_pinned when the bridge answers the decoy request, whatever the status", function()
		for _, code in ipairs({ 200, 403, 404, 500 }) do
			local verdict, detail = check(function(t) t:respond(code, '{"name":"Hue"}') end)
			assert.equal("not_pinned", verdict, code)
			assert.equal("HTTP " .. code .. " with the decoy bundle", detail)
		end
	end)

	it("is inconclusive for a timeout, a refused connection, a name that does not resolve or any other failure", function()
		for _, failure in ipairs({
			{ 28, "Timeout was reached" },
			{ 7, "Failed to connect to 10.0.2.143 port 443: Connection refused" },
			{ 6, "Couldn't resolve host name" },
			{ 77, "Problem with the SSL CA cert (path? access rights?)" },
			{ 35, "SSL connect error" },
			{ -1, "aborted" },
		}) do
			local verdict, detail = check(function(t) t:done(failure[1], failure[2]) end)
			assert.equal("inconclusive", verdict, failure[2])
			assert.truthy(detail:find(failure[2], 1, true), detail)
		end
	end)

	it("is inconclusive when the request cannot start or there is no CA configuration", function()
		local real_url = c4.url
		c4.url = function(self)
			local t = real_url(self)
			t.Get = function() error("Error loading certificate: fopen: No such file or directory") end
			return t
		end
		local verdict, detail = check()
		assert.equal("inconclusive", verdict)
		assert.truthy(detail:find("could not start transfer", 1, true), detail)

		c4.url = real_url
		http.ca = nil
		verdict = check()
		assert.equal("inconclusive", verdict)
	end)

	it("logs the expected failure at debug only", function()
		local lines = {}
		log.set_debug(false)
		log.sink = function(line) lines[#lines + 1] = line end
		check(function(t) t:done(60, "SSL certificate problem: unable to get local issuer certificate") end)
		assert.same({}, lines)
	end)

	it("remembers nothing by itself, whatever the verdict: the driver calls remember_pinned", function()
		check(function(t) t:done(60, "SSL certificate problem: unable to get local issuer certificate") end)
		check(function(t) t:respond(200, "{}") end)
		check(function(t) t:done(28, "Timeout was reached") end)
		assert.same({}, c4.persist)
	end)

	-- The calls the fake recorded under `name` (c4.calls), in order.
	local function calls_named(name)
		local out = {}
		for _, call in ipairs(c4.calls) do
			if call.name == name then out[#out + 1] = call end
		end
		return out
	end

	describe("director_version", function()
		it("is C4:GetVersionInfo().version as a string", function()
			assert.equal("3.4.2.746094", tlscheck.director_version())
			c4.director_version = "4.0.1.123456"
			assert.equal("4.0.1.123456", tlscheck.director_version(), "read afresh at every call")
			assert.equal(2, #calls_named("GetVersionInfo"))
		end)

		it("turns a number into a string and trims white space", function()
			c4.director_version = 3.4
			assert.equal("3.4", tlscheck.director_version())
			c4.director_version = " 3.4.2.746094\n"
			assert.equal("3.4.2.746094", tlscheck.director_version())
		end)

		it("is nil when the controller answers nothing, raises or lacks the call", function()
			c4.director_version = nil
			assert.is_nil(tlscheck.director_version(), "GetVersionInfo answered nil")

			c4.GetVersionInfo = function() error("GetVersionInfo failed") end
			assert.is_nil(tlscheck.director_version(), "a raise stays inside")

			c4.GetVersionInfo = nil
			assert.is_nil(tlscheck.director_version(), "no such call")

			rawset(_G, "C4", nil)
			assert.is_nil(tlscheck.director_version(), "no C4 at all")
		end)

		it("is nil for an odd answer: not a table, no version, an empty or non-text version", function()
			for _, answer in ipairs({ "3.4.2.746094", 3, true, {}, { buildtype = "RELEASE" }, { version = "" },
				{ version = "   " }, { version = true }, { version = { "3.4.2" } } }) do
				c4.GetVersionInfo = function() return answer end
				assert.is_nil(tlscheck.director_version())
			end
		end)
	end)

	describe("remember_pinned", function()
		it("persists the running version, unencrypted, under tls_pinned_on", function()
			assert.equal("tls_pinned_on", tlscheck.STORE_NAME)
			assert.equal("3.4.2.746094", tlscheck.remember_pinned())
			assert.equal("3.4.2.746094", c4.persist.tls_pinned_on)
			local writes = calls_named("PersistSetValue")
			assert.equal(1, #writes)
			assert.same({ "tls_pinned_on", "3.4.2.746094", false }, writes[1].args, "no secret: not encrypted")
		end)

		it("replaces the version an earlier OS answered on", function()
			c4.persist.tls_pinned_on = "3.4.2.700000"
			tlscheck.remember_pinned()
			assert.equal("3.4.2.746094", c4.persist.tls_pinned_on)
		end)

		it("stores nothing when the version cannot be read", function()
			c4.director_version = nil
			assert.is_nil(tlscheck.remember_pinned())
			c4.GetVersionInfo = function() error("GetVersionInfo failed") end
			assert.is_nil(tlscheck.remember_pinned())
			assert.same({}, c4.persist)
			assert.same({}, calls_named("PersistSetValue"))
			assert.is_false(tlscheck.pinned_before())
		end)

		it("does not raise when the store does; the run still remembers, with a warning", function()
			local lines = {}
			log.sink = function(line) lines[#lines + 1] = line end
			c4.PersistSetValue = function() error("database unavailable") end
			local version
			assert.has_no.errors(function() version = tlscheck.remember_pinned() end)
			assert.equal("3.4.2.746094", version)
			assert.is_true(tlscheck.pinned_before())
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("could not store the Director version 3.4.2.746094", 1, true), lines[1])
		end)
	end)

	describe("pinned_before", function()
		it("is false on a controller where the check never answered pinned", function()
			assert.is_false(tlscheck.pinned_before())
		end)

		it("is true when an earlier run persisted the running version", function()
			c4.persist.tls_pinned_on = "3.4.2.746094"
			assert.is_true(tlscheck.pinned_before())
			local reads = calls_named("PersistGetValue")
			assert.equal(1, #reads)
			assert.same({ "tls_pinned_on", false }, reads[1].args)
		end)

		it("is false after a Director update, until the new version answers pinned", function()
			c4.persist.tls_pinned_on = "3.4.2.746094"
			c4.director_version = "4.0.0.100001"
			assert.is_false(tlscheck.pinned_before())
			tlscheck.remember_pinned()
			assert.is_true(tlscheck.pinned_before())
			c4.director_version = "3.4.2.746094"
			assert.is_false(tlscheck.pinned_before(), "going back is another version again")
		end)

		it("is false when the running version cannot be read, whatever is stored", function()
			c4.persist.tls_pinned_on = "3.4.2.746094"
			c4.director_version = nil
			assert.is_false(tlscheck.pinned_before())
			c4.GetVersionInfo = function() return { version = "" } end
			assert.is_false(tlscheck.pinned_before())
			c4.GetVersionInfo = function() error("GetVersionInfo failed") end
			assert.is_false(tlscheck.pinned_before())
		end)

		it("is false for a stored value that is empty, not text, or unreadable", function()
			for _, value in ipairs({ "", " ", true, 3.4, { "3.4.2.746094" } }) do
				c4.persist.tls_pinned_on = value
				assert.is_false(tlscheck.pinned_before(), tostring(value))
			end
			c4.persist.tls_pinned_on = "3.4.2.746094"
			c4.PersistGetValue = function() error("database unavailable") end
			assert.is_false(tlscheck.pinned_before())
		end)

		it("is true right after remember_pinned, before the store returns the value", function()
			tlscheck.remember_pinned()
			c4.persist.tls_pinned_on = nil -- PersistGetValue lagging the write (docs/design.md "Storage")
			assert.is_true(tlscheck.pinned_before())
		end)

		it("forgets this run's answer at the next start: only the store carries it over", function()
			tlscheck.remember_pinned()
			c4.persist.tls_pinned_on = nil
			package.loaded["bridge.tlscheck"] = nil
			tlscheck = require("bridge.tlscheck")
			assert.is_false(tlscheck.pinned_before())
			c4.persist.tls_pinned_on = "3.4.2.746094"
			assert.is_true(tlscheck.pinned_before())
		end)
	end)

	describe("the decoy bundle", function()
		local pem = read_file("src/hue_bridge/" .. "certs/decoy_ca.pem")

		it("is one certificate and no private key", function()
			local n = 0
			for _ in pem:gmatch("%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-") do n = n + 1 end
			assert.equal(1, n)
			assert.is_nil(pem:find("PRIVATE KEY", 1, true))
			assert.is_nil(pem:find("BEGIN [%u ]*KEY"))
		end)

		it("is none of the Signify roots", function()
			local body = pem:match("%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-(.-)%-%-%-%-%-END")
			assert.is_not_nil(body)
			for _, path in ipairs({ "src/hue_bridge/certs/hue_ca_bundle.pem", "src/hue_bridge/certs/hue_root_bridge.pem",
				"src/hue_bridge/certs/hue_root_ca_01.pem" }) do
				assert.is_nil(read_file(path):find(body, 1, true), path)
			end
		end)

		it("sits where the check names it, inside the bridge driver's tree that tools/build.sh packages", function()
			assert.equal(pem, read_file("src/hue_bridge/" .. tlscheck.DECOY_CA))
		end)
	end)
end)
