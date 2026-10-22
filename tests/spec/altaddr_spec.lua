local altaddr = require("bridge.altaddr")

describe("bridge.altaddr", function()
	it("zero-pads every octet below 8 and leaves the others alone", function()
		assert.equal("10.0.2.143", altaddr.padded("10.0.2.143", 3))
		assert.equal("10.0.2.143", altaddr.padded("10.0.2.143", 2))
		assert.equal("192.168.001.50", altaddr.padded("192.168.1.50", 3))
	end)

	it("never pads an octet of 8 or more, which curl would read as octal", function()
		assert.equal("10.10.000.005", altaddr.padded("10.10.0.5", 3))
		assert.equal("172.16.000.9", altaddr.padded("172.16.0.9", 3))
		assert.is_nil(altaddr.padded("10.10.10.10", 3))
		assert.is_nil(altaddr.padded("192.168.100.200", 3))
	end)

	it("gives distinct strings for the stream and the self-check", function()
		local ip = "10.0.2.143"
		assert.are_not.equal(altaddr.for_stream(ip), altaddr.for_check(ip))
		assert.are_not.equal(altaddr.for_stream(ip), ip)
		assert.are_not.equal(altaddr.for_check(ip), ip)
	end)

	it("returns nil for anything that is not a dotted quad", function()
		assert.is_nil(altaddr.padded(nil))
		assert.is_nil(altaddr.padded("hue.local"))
		assert.is_nil(altaddr.padded("10.0.1"))
	end)

	it("lists the stream family widest first, last paddable octet turning fastest", function()
		assert.same({
			"192.000.002.10",
			"192.000.02.10",
			"192.000.2.10",
			"192.00.002.10",
			"192.00.2.10",
			"192.0.002.10",
			"192.0.02.10",
		}, altaddr.stream_family("192.0.2.10"))
	end)

	it("starts the family at for_stream and keeps the command and self-check spellings out of it", function()
		for _, ip in ipairs({ "192.0.2.10", "1.2.3.4" }) do
			local family = altaddr.stream_family(ip)
			assert.equal(altaddr.for_stream(ip), family[1])
			for _, spelling in ipairs(family) do
				assert.are_not.equal(ip, spelling)
				assert.are_not.equal(altaddr.for_check(ip), spelling)
			end
		end
	end)

	it("gives a one-entry family when only one octet can be padded", function()
		assert.same({ "192.168.001.50" }, altaddr.stream_family("192.168.1.50"))
	end)

	it("caps the family at FAMILY_MAX distinct spellings of the same address", function()
		assert.equal(8, altaddr.FAMILY_MAX)
		local family = altaddr.stream_family("1.2.3.4")
		assert.equal(altaddr.FAMILY_MAX, #family)
		local seen = {}
		for _, spelling in ipairs(family) do
			assert.is_nil(seen[spelling], spelling .. " listed twice")
			seen[spelling] = true
			local values = {}
			for octet in spelling:gmatch("[^.]+") do
				values[#values + 1] = tonumber(octet)
			end
			assert.same({ 1, 2, 3, 4 }, values)
		end
	end)

	it("has no family for an address with nothing to pad or that is not a dotted quad", function()
		assert.is_nil(altaddr.stream_family("10.10.10.10"))
		assert.is_nil(altaddr.stream_family("hue.local"))
		assert.is_nil(altaddr.stream_family("10.0.1"))
		assert.is_nil(altaddr.stream_family(nil))
	end)
end)
