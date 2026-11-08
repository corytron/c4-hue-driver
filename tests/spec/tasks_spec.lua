-- bridge/tasks.lua (#373; docs/simplify-actions-design.md §1.3, §3.1, §4
-- finding 7): the bridge driver's background tasks, moved out of
-- hue_bridge/driver.lua. The engine is the real bridge/housekeeping.lua
-- (its own spec covers scheduling); here each task's definition, its guards
-- and what its run does, against stand-ins for the driver's callbacks. The
-- fake C4 (fake.install_c4) for the clock, the user gate's timer and the
-- engine's store.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local S, MIN, HOUR = 1000, 60000, 3600000
local T0 = 1761000000000
local PAIRED_ID = "001788fffe123abc"
local IP = "10.0.2.143"

describe("bridge/tasks.lua (#373)", function()
	local tasks, housekeeping, c4, hk, state, lines, user, refusal, conn, resyncs, rechecks, said, addresses, moves

	-- Runs one task's run(job, done) and returns what done got, or nil while it waits.
	local function run(name, job)
		local result
		hk.tasks[name].run(job or {}, function(ok, text) result = { ok = ok, text = text } end)
		return result
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
		c4.now_ms = T0
		package.loaded["bridge.tasks"] = nil
		tasks = require("bridge.tasks")
		housekeeping = require("bridge.housekeeping")
		user, refusal, conn, resyncs, rechecks, said, addresses, moves = false, nil, { ip = IP }, {}, {}, {}, {}, {}
		state = {
			ip = IP, address_gen = 1, creds = { bridge_id = PAIRED_ID, key = "<key>" }, identity_ok = true,
			stream_connected = true,
			away = {
				moved = function(_, from, to, text) moves[#moves + 1] = { from = from, to = to, text = text } end,
				find_missed = function() moves[#moves + 1] = "missed" end,
			},
		}
		hk = tasks.new({
			state = state,
			http = function() error("the tasks send nothing through job.http") end,
			log = log,
			user_active = function() return user end,
			connection = function() return conn end,
			keyed_refusal = function() return refusal end,
			resync_all = function(done, tier) resyncs[#resyncs + 1] = { done = done, tier = tier, charge = state.charge } end,
			recheck_key = function(done) rechecks[#rechecks + 1] = done end,
			last_action = function(text) said[#said + 1] = text end,
			set_address = function(ip) addresses[#addresses + 1] = ip end,
			now_ms = function() return c4.now_ms end,
		})
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("the definitions", function()
		it("defines the six tasks, in order, with their classes and triggers", function()
			local names = {}
			for _, t in ipairs(hk.order) do names[#names + 1] = t.name .. " " .. t.class end
			assert.same({ "resync essential", "safety_quick optional", "safety_full optional",
				"stream_down_read optional", "key_recheck essential", "find_bridge essential" }, names)
			assert.same({ connect = true, click = true, error = true }, hk.tasks.resync.trigger_set)
			assert.same({ timer = true }, hk.tasks.safety_quick.trigger_set)
			assert.same({ error = true }, hk.tasks.key_recheck.trigger_set)
			assert.same({ error = true }, hk.tasks.find_bridge.trigger_set)
		end)

		it("schedules the reads and budgets them against the hour", function()
			assert.equal(6 * HOUR, hk.tasks.safety_quick.interval_ms)
			assert.equal(24 * HOUR, hk.tasks.safety_full.interval_ms)
			assert.equal(10 * MIN, hk.tasks.stream_down_read.interval_ms)
			for _, name in ipairs({ "safety_quick", "safety_full", "stream_down_read" }) do
				assert.equal(tasks.READ_BUDGET, hk.tasks[name].budget, name)
			end
			assert.is_true(hk.tasks.safety_quick.persist)
			assert.is_true(hk.tasks.safety_full.persist)
			assert.is_false(hk.tasks.stream_down_read.persist)
			assert.is_nil(hk.tasks.resync.interval_ms)
		end)

		it("retries and spaces the essential tasks as the contract says", function()
			assert.equal(2 * S, hk.tasks.resync.debounce_ms)
			assert.equal(900 * S, hk.tasks.resync.backoff_max_ms)
			assert.equal(300 * S, hk.tasks.key_recheck.debounce_ms)
			assert.same({ 900, 3600 }, hk.tasks.key_recheck.backoff)
			assert.equal(5 * S, hk.tasks.find_bridge.debounce_ms)
			assert.equal(300 * S, hk.tasks.find_bridge.min_gap_ms)
			assert.equal(360 * S, hk.tasks.find_bridge.timeout_ms)
		end)

		it("guards each task", function()
			assert.same(tasks.SAFETY_GUARDS, hk.tasks.safety_quick.guards)
			assert.same(tasks.SAFETY_GUARDS, hk.tasks.safety_full.guards)
			assert.same({ "paired", "identity_ok", "key_ok", "not_pairing", "modules_idle" },
				hk.tasks.stream_down_read.guards)
			assert.same({ "paired", "identity_ok", "not_pairing" }, hk.tasks.key_recheck.guards)
			assert.same({ "paired", "not_pairing" }, hk.tasks.find_bridge.guards)
		end)
	end)

	describe("the guards and the reports", function()
		it("reads the guards from the driver's state", function()
			assert.same({ paired = true, identity_ok = true, key_ok = true, stream_up = true, not_pairing = true,
				modules_idle = true }, hk.ctx.state())
			conn, state.identity_ok, state.stream_connected, state.pairing_active = nil, nil, false, true
			state.key_rejected = 403
			assert.same({ paired = false, identity_ok = false, key_ok = false, stream_up = false, not_pairing = false,
				modules_idle = true }, hk.ctx.state())
			state.key_rejected, refusal = nil, "TLS check failed"
			assert.is_false(hk.ctx.state().key_ok)
		end)

		it("is not idle while a module resyncs or holds its first busy flag", function()
			state.lights, state.scenes, state.zone_lights = { resyncing = true }, {}, {}
			assert.is_false(hk.ctx.state().modules_idle)
			state.lights = { resyncing = false }
			state.motion = { BUSY_FLAGS = { "importing", "relinking" }, importing = true }
			assert.is_false(hk.ctx.state().modules_idle)
			state.motion.importing, state.motion.relinking = false, true
			assert.is_true(hk.ctx.state().modules_idle, "only the first flag counts")
		end)

		it("names the paired bridge for the store", function()
			assert.equal(PAIRED_ID, hk.ctx.bridge_id())
			state.creds = nil
			assert.is_nil(hk.ctx.bridge_id())
		end)

		it("logs every run: a success in Debug Mode, a failure as info", function()
			hk.ctx.on_status({ task = "resync", trigger = "connect", ok = true, ms = 812, text = "full resync" })
			hk.ctx.on_status({ task = "find_bridge", trigger = "error", ok = false, ms = 3000 })
			assert.same({ "[DEBUG] background resync (connect): OK in 812 ms: full resync",
				"[INFO] background find_bridge (error): failed in 3000 ms" }, lines)
		end)
	end)

	describe("the resync", function()
		it("runs the tier asked for, then counts as the safety reads", function()
			state.resync_tier = "full"
			assert.is_nil(run("resync"))
			assert.is_nil(state.resync_tier, "taken")
			assert.equal("full", resyncs[1].tier)
			assert.is_nil(resyncs[1].charge, "the essential resync is outside the hourly budget")
			local result
			hk.tasks.resync.run({}, function(ok, text) result = { ok = ok, text = text } end)
			resyncs[2].done({})
			assert.same({ ok = true, text = "full resync" }, result, "full by default")
			assert.equal(T0, hk:info("safety_quick").last_ok_ms)
			assert.equal(T0, hk:info("safety_full").last_ok_ms)
		end)

		it("marks only the quick read fresh after a quick resync", function()
			state.resync_tier = "quick"
			local result
			hk.tasks.resync.run({}, function(ok, text) result = { ok = ok, text = text } end)
			resyncs[1].done({})
			assert.same({ ok = true, text = "quick resync" }, result)
			assert.equal(T0, hk:info("safety_quick").last_ok_ms)
			assert.is_nil(hk:info("safety_full").last_ok_ms)
		end)

		it("keeps the tier for the retry after a failure, a full one winning", function()
			state.resync_tier = "quick"
			local result
			hk.tasks.resync.run({}, function(ok, text) result = { ok = ok, text = text } end)
			resyncs[1].done({ "light: timeout", "scene: HTTP 503" })
			assert.same({ ok = false, text = "light: timeout; scene: HTTP 503" }, result)
			assert.equal("quick", state.resync_tier)
			state.resync_tier = "full"
			hk.tasks.safety_quick.run({}, function() end)
			resyncs[2].done({ "motion: timeout" })
			assert.equal("full", state.resync_tier)
		end)

		it("charges every GET of an optional read to its job, until the chain ends", function()
			local charge = function() end
			run("safety_full", { charge = charge })
			assert.equal(charge, resyncs[1].charge)
			assert.equal("full", resyncs[1].tier)
			resyncs[1].done({})
			assert.is_nil(state.charge)
			run("safety_quick", { charge = charge })
			state.charge = "another job's"
			resyncs[2].done({})
			assert.equal("another job's", state.charge, "only its own charge is taken back")
		end)

		it("waits for the user first, at most 10 s", function()
			user = true
			run("resync")
			assert.same({}, resyncs)
			c4.advance(2 * S)
			assert.same({}, resyncs)
			user = false
			c4.advance(250)
			assert.equal(1, #resyncs)
			user = true
			run("resync")
			c4.advance(housekeeping.GATE_MAX_MS - 1)
			assert.equal(1, #resyncs)
			c4.advance(1)
			assert.equal(2, #resyncs, "a long slider session cannot starve the resync")
		end)
	end)

	describe("the read while the stream is down", function()
		it("reads only once the stream has been down 5 minutes", function()
			assert.same({ ok = true, text = "the event stream is connected" }, run("stream_down_read"))
			state.stream_connected, state.stream_down_ms = false, nil
			assert.same({ ok = true, text = "the event stream is connected" }, run("stream_down_read"))
			state.stream_down_ms = T0 - 5 * MIN + 1
			assert.same({ ok = true, text = "the event stream is down for less than 5 minutes" }, run("stream_down_read"))
			state.stream_down_ms = T0 - 5 * MIN
			assert.is_nil(run("stream_down_read"))
			assert.equal("quick", resyncs[1].tier)
		end)
	end)

	describe("the key re-check", function()
		it("passes the check's answer on, and says so in Last Action when it lifted the lock", function()
			local result
			hk.tasks.key_recheck.run({}, function(ok, text) result = { ok = ok, text = text } end)
			rechecks[1](false, "the bridge still refuses the key (HTTP 403)")
			assert.same({ ok = false, text = "the bridge still refuses the key (HTTP 403)" }, result)
			assert.same({}, said)
			hk.tasks.key_recheck.run({}, function(ok, text) result = { ok = ok, text = text } end)
			rechecks[2](true, "the bridge accepts the key again", true)
			assert.same({ ok = true, text = "the bridge accepts the key again" }, result)
			assert.same({ "The bridge accepts the application key again: event stream restarting" }, said)
		end)
	end)

	describe("the follow-up search", function()
		local finds

		before_each(function()
			finds = {}
			state.identity_ok = false
			state.discovery = {
				find_paired = function(_, bridge_id, last_ip, done)
					finds[#finds + 1] = { bridge_id = bridge_id, last_ip = last_ip, done = done }
				end,
			}
		end)

		it("has nothing to look for without discovery or a paired id, and never while the bridge answers", function()
			local discovery = state.discovery
			state.discovery = nil
			assert.same({ ok = true, text = "nothing to look for" }, run("find_bridge"))
			state.discovery, state.creds = discovery, { key = "<key>" }
			assert.same({ ok = true, text = "nothing to look for" }, run("find_bridge"))
			state.creds, state.identity_ok = { bridge_id = PAIRED_ID }, true
			assert.same({ ok = true, text = "the bridge answers at its address" }, run("find_bridge"))
			assert.same({}, finds)
		end)

		it("looks from where the bridge last answered, and follows it to its new address", function()
			state.last_good_ip = "192.0.2.140"
			local result
			hk.tasks.find_bridge.run({}, function(ok, text) result = { ok = ok, text = text } end)
			assert.equal(PAIRED_ID, finds[1].bridge_id)
			assert.equal("192.0.2.140", finds[1].last_ip)
			finds[1].done("192.0.2.150", "mdns", { text = "found by mDNS" })
			local text = "The bridge moved from " .. IP .. " to 192.0.2.150 (found by mDNS): Bridge IP Address updated; "
				.. "reserve its address in the router"
			assert.same({ { from = IP, to = "192.0.2.150", text = text } }, moves)
			assert.same({ "192.0.2.150" }, addresses)
			assert.same({ text }, said)
			assert.same({ ok = true, text = "found by mDNS" }, result)
		end)

		it("looks from Bridge IP Address without a last good one, and keeps an unchanged address", function()
			local result
			hk.tasks.find_bridge.run({}, function(ok, text) result = { ok = ok, text = text } end)
			assert.equal(IP, finds[1].last_ip)
			finds[1].done(IP, "mdns", nil)
			assert.same({}, addresses)
			assert.same({ ok = true, text = "mdns" }, result)
		end)

		it("notes a search that found it nowhere, for Attention's \"missing\"", function()
			local results = {}
			for _, how in ipairs({ "not_found", "limited", "busy" }) do
				hk.tasks.find_bridge.run({}, function(ok, text) results[#results + 1] = { ok = ok, text = text } end)
				finds[#finds].done(nil, how, { text = how .. " text" })
			end
			assert.same({ "missed", "missed" }, moves, "not for a search that did not run")
			assert.same({ { ok = false, text = "not_found text" }, { ok = false, text = "limited text" },
				{ ok = false, text = "busy text" } }, results)
		end)

		it("drops an answer for an earlier address", function()
			local result
			hk.tasks.find_bridge.run({}, function(ok, text) result = { ok = ok, text = text } end)
			state.address_gen = 2
			finds[1].done("192.0.2.150", "mdns", { text = "found by mDNS" })
			assert.same({ ok = true, text = "the address changed meanwhile" }, result)
			assert.same({}, addresses)
			assert.same({}, moves)
		end)
	end)

	describe("after_user", function()
		it("runs at once while nobody is busy", function()
			local ran = false
			tasks.after_user(function() return false end, function() ran = true end)
			assert.is_true(ran)
		end)

		it("looks again every 250 ms", function()
			local busy, ran = true, false
			tasks.after_user(function() return busy end, function() ran = true end)
			c4.advance(housekeeping.GATE_POLL_MS)
			assert.is_false(ran)
			busy = false
			c4.advance(housekeeping.GATE_POLL_MS - 1)
			assert.is_false(ran)
			c4.advance(1)
			assert.is_true(ran)
		end)
	end)
end)
