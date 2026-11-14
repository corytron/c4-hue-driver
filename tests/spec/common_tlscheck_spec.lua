-- #514, stage 1 §3 (docs/hdmi-sync-stage1-design.md): common/tlscheck.lua,
-- the TLS self-check (#53) given its https instance, its decoy bundle and
-- its path. bridge/tlscheck.lua is one instance (tests/spec/tlscheck_spec.lua
-- covers it, unchanged); this spec covers another: the Hue Sync Box's shape
-- of stage 2, with its own client, path and memory. Placeholders only: sync
-- box 10.0.2.150.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local BOX_IP = "10.0.2.150"

describe("common/tlscheck.lua (#514)", function()
	local https, tlscheck, c4, client, check, lines

	local function box_check(extra)
		local opts = {
			https = client,
			decoy_ca = "certs/decoy_ca.pem",
			path = "/api/v1/device",
			timeout = 4,
			store_name = "tls_pinned_on",
			label = "Sync box TLS check",
		}
		for k, v in pairs(extra or {}) do opts[k] = v end
		return tlscheck.new(opts)
	end

	-- Run `instance` against the box; answer its request with `drive`.
	local function verdict_of(instance, drive)
		local verdict, detail, calls = nil, nil, 0
		instance.run(BOX_IP, function(v, d) verdict, detail, calls = v, d, calls + 1 end)
		if drive then drive(c4.last_transfer()) end
		assert.is_true(calls <= 1, "called back once")
		return verdict, detail
	end

	before_each(function()
		lines = {}
		log.set_debug(false)
		log.sink = function(line) lines[#lines + 1] = line end
		c4 = fake.install_c4()
		for _, m in ipairs({ "common.https", "common.tlscheck" }) do package.loaded[m] = nil end
		https = require("common.https")
		tlscheck = require("common.tlscheck")
		client = https.new({ ca_bundle = "certs/hsb_ca.pem", header_key = { name = "Authorization", prefix = "Bearer " },
			max_keyed = 1, timeout = 6, connect_timeout = 3 })
		check = box_check()
	end)

	after_each(function()
		log.sink = print
	end)

	describe("the decoy request", function()
		it("asks the configured path with the decoy bundle and the client's TLS options otherwise", function()
			c4.tls_ignores_cabundle = true
			verdict_of(check)
			local t = c4.last_transfer()
			assert.equal("GET", t.method)
			assert.equal("https://" .. BOX_IP .. "/api/v1/device", t.url)
			assert.same({ fail_on_error = false, timeout = 4, connect_timeout = 3, ssl_verify_peer = true,
				ssl_verify_host = false, ssl_cabundle = "certs/decoy_ca.pem" }, t.options)
			assert.same({}, t.headers, "never the token, nor any other header")
			assert.is_nil(t.data)
			assert.equal("certs/decoy_ca.pem", check.DECOY_CA)
			assert.equal("/api/v1/device", check.PATH)
			assert.equal(4, check.TIMEOUT)
		end)

		it("answers pinned when the decoy request fails certificate verification", function()
			local verdict, detail = verdict_of(check)
			assert.equal("pinned", verdict, "the fake fails a decoy bundle with curl 60, as OS 3.4.2 does")
			assert.truthy(detail:find("(60)", 1, true), detail)
			assert.equal("https://" .. BOX_IP .. "/api/v1/device", c4.decoy_transfers[1].url)
		end)

		it("answers not_pinned when the box answers it, and inconclusive for any other failure", function()
			c4.tls_ignores_cabundle = true
			local verdict, detail = verdict_of(check, function(t) t:respond(200, '{"name":"Hue Sync Box"}') end)
			assert.equal("not_pinned", verdict)
			assert.equal("HTTP 200 with the decoy bundle", detail)
			verdict = verdict_of(check, function(t) t:done(28, "Timeout was reached") end)
			assert.equal("inconclusive", verdict)
			assert.same({}, lines, "the expected failure is logged at debug only")
		end)

		it("uses the given client's request and certificate_failure, looked up at every run", function()
			local asked = {}
			local stand_in = {
				request = function(req, cb) asked[#asked + 1] = req; cb({ ok = false, err_code = 60, err = "x" }) end,
				certificate_failure = function() return false end,
			}
			local own = box_check({ https = stand_in })
			assert.equal("inconclusive", (verdict_of(own)), "its certificate_failure decides")
			stand_in.certificate_failure = function(r) return r.err_code == 60 end
			assert.equal("pinned", (verdict_of(own)))
			assert.equal(2, #asked)
			assert.equal("/api/v1/device", asked[1].path)
			assert.is_nil(asked[1].key)
			assert.is_true(asked[1].quiet)
			assert.equal(0, #c4.transfers + #c4.decoy_transfers, "not the bridge's client, nor any other")
		end)
	end)

	describe("the memory of a pinned answer", function()
		it("stores the Director version under the configured name", function()
			local named = box_check({ store_name = "box_tls_pinned_on" })
			assert.equal("box_tls_pinned_on", named.STORE_NAME)
			assert.equal("3.4.2.746094", named.remember_pinned())
			assert.equal("3.4.2.746094", c4.persist.box_tls_pinned_on)
			assert.is_nil(c4.persist.tls_pinned_on)
			assert.is_true(named.pinned_before())
			assert.is_false(check.pinned_before(), "another name is another memory")
		end)

		it("keeps this run's answer per instance; the store is what two instances share", function()
			local other = box_check()
			check.remember_pinned()
			c4.persist.tls_pinned_on = nil -- PersistGetValue lagging the write (docs/design.md "Storage")
			assert.is_true(check.pinned_before())
			assert.is_false(other.pinned_before(), "this run's answer is the instance's own")
			c4.persist.tls_pinned_on = "3.4.2.746094"
			assert.is_true(other.pinned_before())
			c4.director_version = "4.0.1.123456"
			assert.is_false(check.pinned_before(), "an OS update asks again")
		end)

		it("reads the Director version through the instance, so a replaced director_version counts", function()
			check.director_version = function() return "4.1.0.123456" end
			assert.equal("4.1.0.123456", check.remember_pinned())
			assert.equal("4.1.0.123456", c4.persist.tls_pinned_on)
			assert.equal("3.4.2.746094", tlscheck.director_version(), "the module's own reads C4:GetVersionInfo")
		end)

		it("logs a store that raises behind its label, and still remembers in this run", function()
			c4.PersistSetValue = function() error("database unavailable") end
			assert.equal("3.4.2.746094", check.remember_pinned())
			assert.is_true(check.pinned_before())
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("^%[WARN%] Sync box TLS check: could not store the Director version 3%.4%.2%.746094"),
				lines[1])
		end)
	end)

	it("uses the bridge's timeout, store name and label when the options leave them out", function()
		local plain = tlscheck.new({ https = client, decoy_ca = "certs/decoy_ca.pem", path = "/api/0/config" })
		assert.equal(10, plain.TIMEOUT)
		assert.equal("tls_pinned_on", plain.STORE_NAME)
		c4.PersistSetValue = function() error("no store") end
		plain.remember_pinned()
		assert.truthy(lines[1]:find("TLS check: could not store", 1, true), lines[1])
	end)

	it("refuses at new() a missing client, decoy bundle or path", function()
		for _, missing in ipairs({ "https", "decoy_ca", "path" }) do
			local opts = { https = client, decoy_ca = "certs/decoy_ca.pem", path = "/api/v1/device" }
			opts[missing] = nil
			local ok, err = pcall(tlscheck.new, opts)
			assert.is_false(ok, missing)
			assert.truthy(tostring(err):find(missing, 1, true), tostring(err))
		end
	end)
end)
