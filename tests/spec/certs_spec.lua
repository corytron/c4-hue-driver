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

	it("derives the sandbox and C4Z paths from the controller", function()
		assert.equal("/control4/drivers/lua/sandbox/15/hue_ca_bundle.pem", certs.sandbox_path())
		assert.equal("/opt/control4/var/drivers/c4z/hue_bridge/hue_ca_bundle.pem", certs.c4z_path())
	end)

	it("writes the bundle into both the sandbox and the C4Z directory", function()
		local result = certs.install()
		assert.same({}, result.errors)
		assert.equal(certs.sandbox_path(), result.sandbox)
		assert.equal(certs.c4z_path(), result.c4z)
		assert.equal(bundle, c4.dirs.SANDBOX["hue_ca_bundle.pem"])
		assert.equal(bundle, c4.dirs.C4Z["hue_ca_bundle.pem"])
		assert.equal("SANDBOX", c4.cwd, "File API directory restored")
	end)

	it("leaves matching files alone", function()
		certs.install()
		c4.calls = {}
		certs.install()
		assert.same({}, c4.calls_to("FileWriteString"))
		assert.same({}, c4.calls_to("FileDelete"))
	end)

	it("replaces a stale or truncated file instead of appending to it", function()
		c4.dirs.SANDBOX["hue_ca_bundle.pem"] = "-----BEGIN CERTIFICATE-----\nold"
		certs.install()
		assert.equal(1, #c4.calls_to("FileDelete"))
		assert.equal(bundle, c4.dirs.SANDBOX["hue_ca_bundle.pem"])
	end)

	it("still succeeds for the sandbox when the C4Z directory is unavailable", function()
		c4.FileSetDir = function(_, alias)
			if alias == "C4Z" then error("not allowed") end
			return true
		end
		local result = certs.install()
		assert.equal(certs.sandbox_path(), result.sandbox)
		assert.is_nil(result.c4z)
		assert.truthy(result.errors[1]:find("FileSetDir%(C4Z%)"))
	end)

	it("reports a failure to create the sandbox file", function()
		c4.FileOpen = function() return -1 end
		local result = certs.install()
		assert.is_nil(result.sandbox)
		assert.truthy(result.errors[1]:find("cannot create", 1, true))
	end)

	it("diagnose() reports both directories", function()
		certs.install()
		local text = table.concat(certs.diagnose(), "\n")
		assert.truthy(text:find("GetSandboxDir: /control4/drivers/lua/sandbox/15", 1, true))
		assert.truthy(text:find("GetDeviceID: 15", 1, true))
		assert.truthy(text:find("SANDBOX bundle exists: true", 1, true))
		assert.truthy(text:find("SANDBOX bundle bytes: " .. #bundle, 1, true))
		assert.truthy(text:find("C4Z bundle exists: true", 1, true))
		assert.truthy(text:find("C4Z listing: 1 files: hue_ca_bundle.pem", 1, true))
		assert.equal("SANDBOX", c4.cwd)
	end)
end)
