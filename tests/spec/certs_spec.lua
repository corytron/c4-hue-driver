local fake = require("helpers.fake_c4")

local function read_file(path)
	local f = assert(io.open(path, "rb"))
	local data = f:read("*a")
	f:close()
	return data
end

describe("CA bundle derived files", function()
	local expected = read_file("src/hue_bridge/certs/hue_root_bridge.pem")
		.. read_file("src/hue_bridge/certs/hue_root_ca_01.pem")

	it("certs/hue_ca_bundle.pem (shipped in the .c4z) is the two roots concatenated", function()
		assert.equal(expected, read_file("src/hue_bridge/certs/hue_ca_bundle.pem"), "run tools/gen_ca_bundle.sh")
	end)

	it("bridge/ca_bundle.lua (embedded) matches it", function()
		package.loaded["bridge.ca_bundle"] = nil
		assert.equal(expected, require("bridge.ca_bundle"), "run tools/gen_ca_bundle.sh")
	end)

	it("holds exactly two certificates", function()
		local n = 0
		for _ in expected:gmatch("BEGIN CERTIFICATE") do n = n + 1 end
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

	it("derives paths from the controller, tolerating a trailing slash on GetC4zDir", function()
		assert.equal("/control4/drivers/lua/sandbox/15/hue_ca_bundle.pem", certs.sandbox_path())
		c4.GetC4zDir = function() return "/opt/control4/var/drivers/c4z/" end
		assert.equal("/opt/control4/var/drivers/c4z/hue_bridge", certs.c4z_dir())
		assert.equal("certs/hue_ca_bundle.pem", certs.SHIPPED)
	end)

	it("writes the bundle into the sandbox only", function()
		local result = certs.install()
		assert.same({}, result.errors)
		assert.equal(certs.sandbox_path(), result.sandbox)
		assert.equal(bundle, c4.dirs.SANDBOX["hue_ca_bundle.pem"])
		assert.is_nil(c4.dirs.C4Z["hue_ca_bundle.pem"])
		assert.equal("SANDBOX", c4.cwd, "File API directory restored")
	end)

	it("removes the copy an earlier build left in the c4z directory", function()
		c4.dirs.C4Z["hue_ca_bundle.pem"] = bundle
		local result = certs.install()
		assert.is_true(result.removed_c4z)
		assert.is_nil(c4.dirs.C4Z["hue_ca_bundle.pem"])
		assert.equal("SANDBOX", c4.cwd)
	end)

	it("leaves a matching sandbox file alone", function()
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

	it("still installs when the C4Z alias is unavailable", function()
		c4.FileSetDir = function(_, alias)
			if alias == "C4Z" then error("not allowed") end
			return true
		end
		local result = certs.install()
		assert.equal(certs.sandbox_path(), result.sandbox)
		assert.is_false(result.removed_c4z)
	end)

	it("reports a failure to create the sandbox file", function()
		c4.FileOpen = function() return -1 end
		local result = certs.install()
		assert.is_nil(result.sandbox)
		assert.truthy(result.errors[1]:find("cannot create", 1, true))
	end)

	it("diagnose() reports both directories", function()
		certs.install()
		c4.dirs.C4Z["driver.lua"] = "--"
		local text = table.concat(certs.diagnose(), "\n")
		assert.truthy(text:find("GetSandboxDir: /control4/drivers/lua/sandbox/15", 1, true))
		assert.truthy(text:find("c4z directory: /opt/control4/var/drivers/c4z/hue_bridge", 1, true))
		assert.truthy(text:find("GetDeviceID: 15", 1, true))
		assert.truthy(text:find("SANDBOX bundle bytes: " .. #bundle, 1, true))
		assert.truthy(text:find("C4Z listing: 1 files: driver.lua", 1, true))
		assert.truthy(text:find("C4Z stale bundle exists: false", 1, true))
		assert.equal("SANDBOX", c4.cwd)
	end)
end)
