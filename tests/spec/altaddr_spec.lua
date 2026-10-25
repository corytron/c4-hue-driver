local altaddr = require("bridge.altaddr")

-- Example addresses: the bridge placeholder 10.0.2.143 and RFC 5737
-- documentation addresses (192.0.2.0/24, 198.51.100.0/24), whose zero-padded
-- spellings the repository's secrets check allows.
describe("bridge.altaddr", function()
	it("zero-pads every octet below 8 and leaves the others alone", function()
		assert.equal("10.000.002.143", altaddr.padded("10.0.2.143", 3))
		assert.equal("10.00.02.143", altaddr.padded("10.0.2.143", 2))
		assert.equal("198.51.100.005", altaddr.padded("198.51.100.5", 3))
	end)

	it("never pads an octet of 8 or more, which curl would read as octal", function()
		assert.equal("198.51.100.007", altaddr.padded("198.51.100.7", 3))
		assert.equal("192.000.002.8", altaddr.padded("192.0.2.8", 3))
		assert.is_nil(altaddr.padded("198.51.100.8", 3))
		assert.is_nil(altaddr.padded("198.51.100.10", 3))
		assert.is_nil(altaddr.padded("198.51.100.200", 3))
	end)

	it("gives distinct strings for the stream and the self-check", function()
		local ip = "10.0.2.143"
		assert.are_not.equal(altaddr.padded(ip, 3), altaddr.for_check(ip))
		assert.are_not.equal(altaddr.padded(ip, 3), ip)
		assert.are_not.equal(altaddr.for_check(ip), ip)
	end)

	it("returns nil for anything that is not a dotted quad", function()
		assert.is_nil(altaddr.padded(nil))
		assert.is_nil(altaddr.padded("hue.local"))
		assert.is_nil(altaddr.padded("192.0.2"))
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

	it("starts the family at the all-3-digit spelling and keeps the command and self-check spellings out of it", function()
		for _, ip in ipairs({ "192.0.2.10", "192.0.2.5" }) do
			local family = altaddr.stream_family(ip)
			assert.equal(altaddr.padded(ip, 3), family[1])
			for _, spelling in ipairs(family) do
				assert.are_not.equal(ip, spelling)
				assert.are_not.equal(altaddr.for_check(ip), spelling)
			end
		end
	end)

	it("gives a one-entry family when only one octet can be padded", function()
		assert.same({ "198.51.100.005" }, altaddr.stream_family("198.51.100.5"))
	end)

	it("caps the family at FAMILY_MAX distinct spellings of the same address", function()
		assert.equal(8, altaddr.FAMILY_MAX)
		-- Three paddable octets give 3^3 - 2 = 25 spellings before the cap.
		local family = altaddr.stream_family("192.0.2.5")
		assert.equal(altaddr.FAMILY_MAX, #family)
		local seen = {}
		for _, spelling in ipairs(family) do
			assert.is_nil(seen[spelling], spelling .. " listed twice")
			seen[spelling] = true
			local values = {}
			for octet in spelling:gmatch("[^.]+") do
				values[#values + 1] = tonumber(octet)
			end
			assert.same({ 192, 0, 2, 5 }, values)
		end
	end)

	it("has no family for an address with nothing to pad or that is not a dotted quad", function()
		assert.is_nil(altaddr.stream_family("198.51.100.10"))
		assert.is_nil(altaddr.stream_family("198.51.100.8"))
		assert.is_nil(altaddr.stream_family("hue.local"))
		assert.is_nil(altaddr.stream_family("192.0.2"))
		assert.is_nil(altaddr.stream_family(nil))
	end)
end)
