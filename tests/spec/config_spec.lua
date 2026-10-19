local config = require("bridge.config")

describe("bridge.config.parse_ipv4", function()
	it("accepts a dotted-quad address and trims whitespace", function()
		assert.equal("192.0.2.10", config.parse_ipv4(" 192.0.2.10 "))
	end)

	it("rejects empty input", function()
		local ip, err = config.parse_ipv4("")
		assert.is_nil(ip)
		assert.equal("empty", err)
	end)

	it("rejects out-of-range octets", function()
		assert.is_nil(config.parse_ipv4("192.0.2.256"))
	end)

	it("rejects leading zeros", function()
		assert.is_nil(config.parse_ipv4("192.0.2.010"))
	end)

	it("rejects hostnames and partial addresses", function()
		assert.is_nil(config.parse_ipv4("hue-bridge.local"))
		assert.is_nil(config.parse_ipv4("192.0.2"))
	end)

	it("rejects non-strings", function()
		assert.is_nil(config.parse_ipv4(nil))
	end)
end)

describe("bridge.config.normalise_bridge_id", function()
	it("lower-cases a Bridge Pro style upper-case id", function()
		assert.equal("0017880000abcdef", config.normalise_bridge_id("0017880000ABCDEF"))
	end)

	it("rejects ids of the wrong length or with non-hex characters", function()
		assert.is_nil(config.normalise_bridge_id("0017880000abcde"))
		assert.is_nil(config.normalise_bridge_id("0017880000abcdeg"))
	end)
end)
