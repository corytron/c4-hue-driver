-- bridge/bridges_found.lua (#373; owner's answer D5, discovery research
-- §2.4): the Bridges Found row, moved out of hue_bridge/driver.lua. The
-- searches are a stand-in discovery object that records each find_all /
-- find_subnet and answers when the spec says; the row goes through a real
-- bridge/rows.lua over the fake C4 (fake.install_c4), timers on its clock.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local discovery = require("bridge.discovery")

local PAIRED_ID = "001788fffe123abc"
local OTHER_ID = "001788fffe456def"
local IP = "10.0.2.143"

describe("bridge/bridges_found.lua (#373)", function()
	local bridges_found, rows, c4, env, state, finder, found, said, refreshed, addresses, pairs_run, lines

	local function item(id, ip, fields)
		local it = { id = id, ip = ip, model = "BSB003", name = "Hue Bridge Pro", how = "mdns" }
		for k, v in pairs(fields or {}) do it[k] = v end
		return it
	end

	local function paired() return state.creds ~= nil and state.creds.key ~= nil end

	-- The drop-down's entries after the summary.
	local function entries()
		local list = {}
		for entry in (c4.property_lists["Bridges Found"] .. ","):gmatch("([^,]*),") do list[#list + 1] = entry end
		table.remove(list, 1)
		return list
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4, env = fake.install_c4()
		package.loaded["bridge.rows"] = nil
		package.loaded["bridge.bridges_found"] = nil
		rows = require("bridge.rows")
		bridges_found = require("bridge.bridges_found")
		said, refreshed, addresses, pairs_run = {}, 0, {}, 0
		finder = { calls = {}, nets = { "10.0.2" } }
		function finder:find_all(done) self.calls[#self.calls + 1] = { kind = "all", done = done } end
		function finder:find_subnet(done, around)
			self.calls[#self.calls + 1] = { kind = "subnet", done = done, around = around }
		end
		function finder:subnet_nets() return self.nets end
		state = { ip = nil, creds = nil, discovery = finder, address_gen = 1 }
		found = bridges_found.new({
			state = state,
			paired = paired,
			rows = rows.new(),
			last_action = function(text) said[#said + 1] = text end,
			refresh = function() refreshed = refreshed + 1 end,
			set_address = function(ip)
				addresses[#addresses + 1] = ip
				state.ip = ip
			end,
			pair = function() pairs_run = pairs_run + 1 end,
			log = log,
		})
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("the row", function()
		it("offers a search, and the sweep of the networks once a search found nothing", function()
			found:show()
			assert.equal("No Hue bridge answered: type its address in Bridge IP Address", env.Properties["Bridges Found"])
			assert.same({ "Search again", "Search every address of 10.0.2.x (about 2 minutes)" }, entries())
		end)

		it("offers no sweep before late init (no discovery yet)", function()
			state.discovery = nil
			found:show()
			assert.same({ "Search again" }, entries())
		end)

		it("lists the bridges heard, the paired one first, and counts them", function()
			found.items = { item(OTHER_ID, "192.0.2.150"), item(PAIRED_ID, IP) }
			found:show()
			assert.equal("2 Hue bridges found: pick one and click Set to pair", env.Properties["Bridges Found"])
			state.creds = { bridge_id = PAIRED_ID }
			found:show()
			assert.same({ discovery.item_label(found.items[2], PAIRED_ID), discovery.item_label(found.items[1], PAIRED_ID),
				"Search again" }, entries())
			found.items = { item(OTHER_ID, "192.0.2.150") }
			found:show()
			assert.equal("1 Hue bridge found: pick one and click Set to pair", env.Properties["Bridges Found"])
		end)

		it("names the paired bridge's model and address, the stored model when none was reported", function()
			state.ip, state.creds = IP, { bridge_id = PAIRED_ID, key = "<key>", model = "BSB002" }
			found:show()
			assert.equal("Paired with Hue Bridge v2‚ square (BSB002) at " .. IP, env.Properties["Bridges Found"])
			state.bridge_model = "BSB003"
			found:show()
			assert.equal("Paired with Hue Bridge Pro (BSB003) at " .. IP, env.Properties["Bridges Found"])
			state.bridge_model, state.creds.model = "", nil
			found:show()
			assert.equal("Paired with the bridge at " .. IP, env.Properties["Bridges Found"])
		end)

		it("says a search runs while it runs", function()
			found:search(false)
			assert.equal("Looking for Hue bridges on the network...", env.Properties["Bridges Found"])
			assert.same({ "Search again" }, entries(), "no sweep offered while searching")
		end)
	end)

	describe("searches", function()
		it("writes an automatic search's result to the row and the log, and refreshes Attention", function()
			found:search(false)
			assert.equal("all", finder.calls[1].kind)
			finder.calls[1].done({ item(PAIRED_ID, IP) }, { text = "1 bridge answered" })
			assert.equal("1 Hue bridge found: pick one and click Set to pair", env.Properties["Bridges Found"])
			assert.same({}, said)
			assert.equal(1, refreshed)
			assert.is_truthy(table.concat(lines, "\n"):find("Bridges Found (automatic search): 1 bridge answered", 1, true))
		end)

		it("reports a search the owner asked for in Last Action", function()
			found:search(true, true)
			assert.equal("subnet", finder.calls[1].kind)
			finder.calls[1].done({}, { text = "nothing answered" })
			assert.same({ "Bridges Found: nothing answered" }, said)
			assert.equal(0, refreshed)
		end)

		it("takes an answer that is not a list as nothing found", function()
			found:search(false)
			finder.calls[1].done(nil, nil)
			assert.same({}, found.items)
			assert.equal(1, refreshed)
		end)

		it("searches the sweep around Bridge IP Address", function()
			state.ip = IP
			found:search(true)
			assert.equal(IP, finder.calls[1].around)
		end)

		it("searches nothing before late init", function()
			state.discovery = nil
			found:search(false)
			assert.is_nil(env.Properties["Bridges Found"])
		end)
	end)

	describe("the first-load searches", function()
		it("searches at 3 s, 1 min and 5 min, then every 15 min until paired", function()
			found:schedule()
			local at = {}
			local start = c4.now_ms
			finder.find_all = function(_, done)
				at[#at + 1] = c4.now_ms - start
				done({}, nil)
			end
			c4.advance(3000 + 60000 + 300000 + 2 * 900000)
			assert.same({ 3000, 63000, 363000, 1263000, 2163000 }, at)
			state.creds = { bridge_id = PAIRED_ID, key = "<key>" }
			c4.advance(900000)
			assert.equal(5, #at, "the timer that comes due once paired only redraws")
			assert.equal(0, #c4.active_timers())
		end)

		it("does not start while paired, and ends when a pairing succeeds", function()
			state.creds = { bridge_id = PAIRED_ID, key = "<key>" }
			found:schedule()
			assert.equal(0, #c4.active_timers())
			state.creds = nil
			found:schedule()
			assert.equal(1, #c4.active_timers())
			state.ip, state.creds = IP, { bridge_id = PAIRED_ID, key = "<key>" }
			found:paired()
			assert.equal(0, #c4.active_timers())
			assert.equal("Paired with the bridge at " .. IP, env.Properties["Bridges Found"])
		end)

		it("starts again from the first after Forget Pairing, and stops on stop()", function()
			found:schedule(4)
			assert.equal(900000, c4.active_timers()[1].delay)
			found:restart()
			local active = c4.active_timers()
			assert.equal(1, #active)
			assert.equal(3000, active[1].delay)
			found:stop()
			assert.equal(0, #c4.active_timers())
		end)
	end)

	describe("offer and heard_elsewhere", function()
		before_each(function()
			state.ip, state.creds, state.last_good_ip = IP, { bridge_id = PAIRED_ID, key = "<key>" }, "192.0.2.140"
		end)

		it("searches once per address typed by hand", function()
			found:offer()
			found:offer()
			assert.equal(1, #finder.calls)
			assert.equal(1, state.offer_gen)
			state.address_gen = 2
			found:offer()
			assert.equal(2, #finder.calls)
		end)

		it("does not search at the address the bridge last answered at, nor unpaired", function()
			state.last_good_ip = IP
			found:offer()
			state.last_good_ip, state.creds = "192.0.2.140", nil
			found:offer()
			assert.equal(0, #finder.calls)
		end)

		it("tells where the last search heard the paired bridge, when not at Bridge IP Address", function()
			assert.is_nil(found:heard_elsewhere())
			found.items = { item(OTHER_ID, "192.0.2.150"), item(PAIRED_ID, IP) }
			assert.is_nil(found:heard_elsewhere(), "heard where it is expected")
			found.items = { item(OTHER_ID, "192.0.2.150"), item(PAIRED_ID, "192.0.2.151") }
			assert.equal("192.0.2.151", found:heard_elsewhere())
			state.creds = nil
			assert.is_nil(found:heard_elsewhere())
		end)
	end)

	describe("a pick", function()
		local function pick_label(it)
			found.items = { it }
			found:show()
			return discovery.item_label(it, state.creds and state.creds.bridge_id)
		end

		it("sets the address and runs Pair Bridge on a driver not paired, expecting the picked bridge", function()
			local label = pick_label(item(PAIRED_ID, IP))
			local seen_pick_id
			found.ctx.pair = function()
				pairs_run = pairs_run + 1
				seen_pick_id = state.pick_id
			end
			found:on_pick(label)
			assert.same({ IP }, addresses)
			assert.equal(1, pairs_run)
			assert.equal(PAIRED_ID, seen_pick_id, "Pair Bridge sees the picked id")
			assert.is_nil(state.pick_id, "for that one call only")
			assert.same({ "Bridge IP Address set to " .. IP .. ": press the link button on the Hue bridge" }, said)
		end)

		it("points a window already open at the picked bridge instead of opening another", function()
			state.pair_until = c4.now_ms + 60000
			found:on_pick(pick_label(item(PAIRED_ID, IP)))
			assert.equal(0, pairs_run)
			assert.equal(PAIRED_ID, state.pair_expected_id)
		end)

		it("refuses a first-generation bridge", function()
			found:on_pick(pick_label(item("0017880000abcdef", "192.0.2.9", { model = "BSB001", supported = false })))
			assert.same({}, addresses)
			assert.same({ "Hue Bridge v1, round (BSB001) at 192.0.2.9 is a first-generation bridge without the CLIP v2 "
				.. "API: this driver cannot use it" }, said)
		end)

		describe("while paired", function()
			before_each(function()
				state.ip, state.creds = "192.0.2.140", { bridge_id = PAIRED_ID, key = "<key>" }
			end)

			it("moves Bridge IP Address to where the paired bridge answers", function()
				found:on_pick(pick_label(item(PAIRED_ID, IP)))
				assert.same({ IP }, addresses)
				assert.equal(0, pairs_run)
				assert.same({ "Bridge IP Address set to " .. IP .. ", where the paired bridge answers" }, said)
			end)

			it("changes nothing for the address it is at already", function()
				state.ip = IP
				found:on_pick(pick_label(item(PAIRED_ID, IP)))
				assert.same({}, addresses)
				assert.same({ "Already paired with this bridge at " .. IP }, said)
			end)

			it("refuses another bridge, naming one that replaces the paired bridge", function()
				found:on_pick(pick_label(item(OTHER_ID, "192.0.2.150")))
				found:on_pick(pick_label(item(OTHER_ID, "192.0.2.150", { replaces = PAIRED_ID })))
				assert.same({}, addresses)
				assert.same({
					"Not changed: Hue Bridge Pro (BSB003) at 192.0.2.150 is another bridge; to pair it instead, run Forget "
						.. "Pairing first",
					"Hue Bridge Pro (BSB003) at 192.0.2.150 replaces the paired bridge: run Forget Pairing, then pick it "
						.. "here again",
				}, said)
			end)
		end)

		it("runs the searches the row offers, and snaps the row back to its summary", function()
			found:show()
			local sent = #c4.calls_to("UpdatePropertyList")
			found:on_pick("Search again")
			assert.equal("all", finder.calls[1].kind)
			finder.calls[1].done({}, { text = "nothing answered" })
			assert.same({ "Bridges Found: nothing answered" }, said)
			found:on_pick("Search every address of 10.0.2.x (about 2 minutes)")
			assert.equal("subnet", finder.calls[2].kind)
			assert.is_true(#c4.calls_to("UpdatePropertyList") > sent)
		end)

		it("ignores the summary and a label no longer listed", function()
			found:show()
			local sent = #c4.calls_to("UpdatePropertyList")
			found:on_pick("No Hue bridge answered: type its address in Bridge IP Address")
			found:on_pick("Hue Bridge Pro - 192.0.2.200 - 123ABC")
			assert.equal(sent, #c4.calls_to("UpdatePropertyList"))
			assert.same({}, finder.calls)
		end)
	end)
end)
