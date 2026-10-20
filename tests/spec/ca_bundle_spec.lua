-- The bundle C4:url reads must stay in step with the two root PEMs.

local function read_file(path)
	local f = assert(io.open(path, "rb"))
	local data = f:read("*a")
	f:close()
	return data
end

describe("certs/hue_ca_bundle.pem", function()
	local bundle = read_file("src/hue_bridge/certs/hue_ca_bundle.pem")

	it("is the two Signify roots concatenated", function()
		local expected = read_file("src/hue_bridge/certs/hue_root_bridge.pem")
			.. read_file("src/hue_bridge/certs/hue_root_ca_01.pem")
		assert.equal(expected, bundle, "run tools/gen_ca_bundle.sh")
	end)

	it("holds exactly two certificates", function()
		local n = 0
		for _ in bundle:gmatch("BEGIN CERTIFICATE") do n = n + 1 end
		assert.equal(2, n)
	end)

	it("is the path the HTTP client uses", function()
		package.loaded["bridge.http"] = nil
		assert.equal("certs/hue_ca_bundle.pem", require("bridge.http").CA_BUNDLE)
	end)
end)
