local fake = require("helpers.fake_c4")

local function read_file(path)
	local f = assert(io.open(path, "rb"))
	local data = f:read("*a")
	f:close()
	return data
end

describe("bridge.ca_bundle", function()
	it("is the concatenation of the committed PEM files", function()
		package.loaded["bridge.ca_bundle"] = nil
		local bundle = require("bridge.ca_bundle")
		local expected = read_file("src/hue_bridge/certs/hue_root_bridge.pem")
			.. read_file("src/hue_bridge/certs/hue_root_ca_01.pem")
		assert.equal(expected, bundle, "run tools/gen_ca_bundle.sh")
	end)

	it("holds exactly two certificates", function()
		local bundle = require("bridge.ca_bundle")
		local n = 0
		for _ in bundle:gmatch("BEGIN CERTIFICATE") do n = n + 1 end
		assert.equal(2, n)
	end)
end)

describe("bridge.certs", function()
	local certs, c4, bundle

	before_each(function()
		c4 = fake.install_c4()
		package.loaded["bridge.certs"] = nil
		certs = require("bridge.certs")
		bundle = require("bridge.ca_bundle")
	end)

	it("writes the bundle into the sandbox and returns its absolute path", function()
		local path, err = certs.install()
		assert.is_nil(err)
		assert.equal("/control4/drivers/lua/sandbox/15/hue_ca_bundle.pem", path)
		assert.equal(bundle, c4.files["hue_ca_bundle.pem"])
	end)

	it("leaves a matching file alone", function()
		certs.install()
		c4.calls = {}
		certs.install()
		assert.same({}, c4.calls_to("FileWriteString"))
		assert.same({}, c4.calls_to("FileDelete"))
	end)

	it("replaces a stale or truncated file instead of appending to it", function()
		c4.files["hue_ca_bundle.pem"] = "-----BEGIN CERTIFICATE-----\nold"
		certs.install()
		assert.equal(1, #c4.calls_to("FileDelete"))
		assert.equal(bundle, c4.files["hue_ca_bundle.pem"])
	end)

	it("reports a failure to create the file", function()
		c4.FileOpen = function() return -1 end
		local path, err = certs.install()
		assert.is_nil(path)
		assert.truthy(err:find("cannot create", 1, true))
	end)

	it("diagnose() reports the directories and the sandbox copy", function()
		certs.install()
		local text = table.concat(certs.diagnose(), "\n")
		assert.truthy(text:find("GetSandboxDir: /control4/drivers/lua/sandbox/15", 1, true))
		assert.truthy(text:find("GetDriverFileName: hue_bridge.c4z", 1, true))
		assert.truthy(text:find("sandbox bundle exists: true", 1, true))
		assert.truthy(text:find("sandbox bundle size: " .. #bundle, 1, true))
	end)
end)
