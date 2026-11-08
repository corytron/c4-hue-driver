-- bridge/netgate.lua (#373; #317, docs/raw-stream-design.md §0): the gate
-- in front of the network-connection event stream, moved out of
-- hue_bridge/driver.lua. bridge/netcheck.lua is a stand-in that records
-- each probe and answers when the spec says; the fake C4 (fake.install_c4)
-- runs the backoff.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local S = 1000
local IP = "10.0.2.143"

describe("bridge/netgate.lua (#373)", function()
	local netgate, c4, gate, state, probes, cancels, pinned_before, remembered, rows, refreshes, continued

	before_each(function()
		log.sink = function() end
		c4 = fake.install_c4()
		probes, cancels, pinned_before, remembered = {}, 0, false, false
		package.loaded["bridge.netcheck"] = {
			run = function(ip, callback) probes[#probes + 1] = { ip = ip, callback = callback } end,
			cancel = function() cancels = cancels + 1 end,
			remember_pinned = function() remembered = true end,
			pinned_before = function() return pinned_before end,
			retry_delay = function(attempts) return 30 * attempts end,
		}
		package.loaded["bridge.netgate"] = nil
		netgate = require("bridge.netgate")
		rows, refreshes, continued = {}, 0, 0
		state = { ip = IP, address_gen = 1 }
		gate = netgate.new({
			state = state,
			prop = function(name, value) rows[#rows + 1] = name .. ": " .. tostring(value) end,
			refresh = function() refreshes = refreshes + 1 end,
			log = log,
		})
	end)

	after_each(function()
		for _, m in ipairs({ "bridge.netcheck", "bridge.netgate" }) do package.loaded[m] = nil end
		log.sink = print
	end)

	local function go() continued = continued + 1 end

	it("probes the bridge's address, says so, and continues once the decoy was refused", function()
		gate:run(go)
		assert.equal(1, #probes)
		assert.equal(IP, probes[1].ip)
		assert.same({ "Event Stream: Not connected: network connection TLS check running" }, rows)
		assert.equal(0, continued)
		probes[1].callback("pinned", "decoy refused")
		assert.equal("pinned", state.net_check)
		assert.is_true(remembered)
		assert.equal(1, continued)
	end)

	it("moves the stream to Web transfer, with the Attention item, when the decoy was accepted", function()
		gate:run(go)
		probes[1].callback("not_pinned", "decoy accepted")
		assert.equal("not_pinned", state.net_check)
		assert.equal(1, refreshes)
		assert.equal(1, continued, "the driver goes on, on Web transfer")
		assert.is_string(netgate.ATTENTION)
		assert.is_truthy(netgate.ATTENTION:find("using Web transfer", 1, true))
	end)

	it("accepts an inconclusive answer on a Director version that answered pinned before", function()
		pinned_before = true
		gate:run(go)
		probes[1].callback("inconclusive", "timeout")
		assert.equal("accepted", state.net_check)
		assert.equal(1, continued)
	end)

	it("holds the stream after any other inconclusive answer, and asks again after the backoff", function()
		gate:run(go)
		probes[1].callback("inconclusive", "timeout")
		assert.is_nil(state.net_check)
		assert.equal(0, continued)
		assert.equal("Event Stream: Not connected: network connection TLS check inconclusive (timeout); checking again "
			.. "in 30 s", rows[2])
		c4.advance(30 * S - 1)
		assert.equal(0, continued)
		c4.advance(1)
		assert.equal(1, continued, "the waiter re-enters choose_stream_address")
		gate:run(go)
		probes[2].callback("inconclusive", "timeout")
		assert.equal("Event Stream: Not connected: network connection TLS check inconclusive (timeout); checking again "
			.. "in 60 s", rows[4], "the backoff grows")
		c4.advance(60 * S)
		gate:run(go)
		probes[3].callback("pinned", "decoy refused")
		gate:run(go)
		probes[4].callback("inconclusive", "timeout")
		assert.equal("Event Stream: Not connected: network connection TLS check inconclusive (timeout); checking again "
			.. "in 30 s", rows[#rows], "a pass starts the count again")
	end)

	it("joins the probe in flight, continuing the latest waiter only", function()
		local first = 0
		gate:run(function() first = first + 1 end)
		gate:run(go)
		assert.equal(1, #probes)
		probes[1].callback("pinned", "decoy refused")
		assert.equal(0, first)
		assert.equal(1, continued)
	end)

	it("ignores an answer for an earlier address and probes the new one", function()
		gate:run(go)
		state.address_gen, state.ip = 2, "192.0.2.144"
		probes[1].callback("pinned", "decoy refused")
		assert.is_nil(state.net_check)
		assert.equal(0, continued)
		gate:run(go)
		assert.equal(2, #probes)
		assert.equal("192.0.2.144", probes[2].ip)
	end)

	it("drops the waiter, the probe and the backoff on reset, keeping the run's verdict", function()
		gate:run(go)
		probes[1].callback("inconclusive", "timeout")
		gate:reset()
		assert.equal(1, cancels)
		c4.advance(5 * 60 * S)
		assert.equal(0, continued)
		state.net_check = "pinned"
		gate:run(go)
		assert.equal(2, #probes, "a new probe at once")
		gate:reset()
		probes[2].callback("pinned", "decoy refused")
		assert.equal(0, continued, "no waiter left")
		assert.equal("pinned", state.net_check)
	end)
end)
