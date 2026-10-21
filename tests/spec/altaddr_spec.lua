local altaddr = require("bridge.altaddr")

describe("bridge.altaddr", function()
	it("zero-pads every octet below 8 and leaves the others alone", function()
		assert.equal("10.000.001.143", altaddr.padded("10.0.1.143", 3))
		assert.equal("10.00.01.143", altaddr.padded("10.0.1.143", 2))
		assert.equal("192.168.001.50", altaddr.padded("192.168.1.50", 3))
	end)

	it("never pads an octet of 8 or more, which curl would read as octal", function()
		assert.equal("10.10.000.005", altaddr.padded("10.10.0.5", 3))
		assert.equal("172.16.000.9", altaddr.padded("172.16.0.9", 3))
		assert.is_nil(altaddr.padded("10.10.10.10", 3))
		assert.is_nil(altaddr.padded("192.168.100.200", 3))
	end)

	it("gives distinct strings for the stream and the self-check", function()
		local ip = "10.0.1.143"
		assert.are_not.equal(altaddr.for_stream(ip), altaddr.for_check(ip))
		assert.are_not.equal(altaddr.for_stream(ip), ip)
		assert.are_not.equal(altaddr.for_check(ip), ip)
	end)

	it("returns nil for anything that is not a dotted quad", function()
		assert.is_nil(altaddr.padded(nil))
		assert.is_nil(altaddr.padded("hue.local"))
		assert.is_nil(altaddr.padded("10.0.1"))
	end)
end)
