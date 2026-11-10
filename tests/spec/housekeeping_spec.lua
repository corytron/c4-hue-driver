-- bridge/housekeeping.lua (#334): the one engine for the bridge driver's
-- background tasks, docs/simplify-actions-design.md §2.1 and
-- docs/simplify-research-scheduler.md §3.1 to §3.7 and §6. Driven by the
-- fake clock (c4.advance) with the fake's C4:SetTimer and persistence as the
-- engine's defaults, and an injected bridge (http), guards (state) and user
-- activity (user_active). The task table is the spec's own: nothing is wired
-- into driver.lua yet.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local S, MIN, HOUR, DAY = 1000, 60000, 3600000, 86400000
local T0 = 1761000000000          -- a fake C4:GetTime, ms since the epoch
local DEVICE = 2101
local BRIDGE_ID = "001788fffe123abc"
local ALL_GUARDS = { paired = true, identity_ok = true, key_ok = true, stream_up = true, not_pairing = true,
	modules_idle = true }

describe("bridge.housekeeping", function()
	local housekeeping, c4, lines, sent, waiting, hold, inflight, max_inflight, guards, user, user_quiet, reports
	local runs, results, answered, bridge_id

	-- The bridge: records every request (with the fake clock), answers it at
	-- once with 200, or keeps it in `waiting` while `hold` is set.
	local function fake_http(req, cb)
		local entry = { req = req, at = c4.now_ms }
		sent[#sent + 1] = entry
		inflight = inflight + 1
		max_inflight = math.max(max_inflight, inflight)
		entry.answer = function(result)
			inflight = inflight - 1
			cb(result or { ok = true, code = 200 })
		end
		if hold then
			waiting[#waiting + 1] = entry
		else
			entry.answer({ ok = true, code = 200 })
		end
	end

	local function answer_next(result)
		local entry = table.remove(waiting, 1)
		assert(entry, "no request waits for an answer")
		entry.answer(result)
	end

	local function new_hk(overrides)
		local ctx = {
			http = fake_http,
			log = log,
			device_id = DEVICE,
			state = function() return guards end,
			user_active = function(quiet_ms)
				user_quiet = quiet_ms
				return user
			end,
			bridge_id = function() return bridge_id end,
			on_status = function(report) reports[#reports + 1] = report end,
		}
		for k, v in pairs(overrides or {}) do ctx[k] = v end
		return housekeeping.new(ctx)
	end

	-- A task whose run makes `reads` GETs one after another and then ends
	-- with the next outcome of results[name] (true when the list is empty).
	-- Every run is recorded in `runs` with its start time and trigger.
	local function reader(name, class, fields)
		fields = fields or {}
		local reads = fields.reads or 1
		fields.reads = nil
		fields.name, fields.class = name, class
		fields.budget = fields.budget or reads
		fields.guards = fields.guards or {}
		fields.run = fields.run or function(job, done)
			runs[#runs + 1] = { name = name, at = c4.now_ms, trigger = job.trigger }
			local n = 0
			local function step()
				if n == reads then
					local outcome = table.remove(results[name] or {}, 1)
					if outcome == nil then outcome = true end
					return done(outcome, outcome and (n .. " read") or "the bridge said 503")
				end
				n = n + 1
				job.http({ path = "/clip/v2/resource/" .. name }, function(r)
					if r.ok then
						return step()
					end
					done(false, r.err)
				end)
			end
			step()
		end
		return fields
	end

	-- The runs (names) in order, or the start times of one task's runs.
	local function run_names()
		local out = {}
		for _, r in ipairs(runs) do out[#out + 1] = r.name end
		return out
	end

	local function run_times(name)
		local out = {}
		for _, r in ipairs(runs) do
			if r.name == name then out[#out + 1] = r.at end
		end
		return out
	end

	local function gaps(times)
		local out = {}
		for i = 2, #times do out[#out + 1] = times[i] - times[i - 1] end
		return out
	end

	local function caller(tag)
		return function(ok, text)
			answered[#answered + 1] = { tag = tag, ok = ok, text = text }
		end
	end

	local function answers_of(tag)
		local out = {}
		for _, a in ipairs(answered) do
			if a.tag == tag then out[#out + 1] = a end
		end
		return out
	end

	local function saw_log(text)
		for _, line in ipairs(lines) do
			if line:find(text, 1, true) then return true end
		end
		return false
	end

	local function jitter_s(name)
		return math.floor(60 * housekeeping.spread(DEVICE, name))
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
		c4.device_id = DEVICE
		c4.now_ms = T0
		package.loaded["bridge.housekeeping"] = nil
		housekeeping = require("bridge.housekeeping")
		sent, waiting, hold, inflight, max_inflight = {}, {}, false, 0, 0
		guards, user, user_quiet, reports = ALL_GUARDS, false, nil, {}
		runs, results, answered, bridge_id = {}, {}, {}, BRIDGE_ID
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("define() and the alarm", function()
		it("refuses a task it could not run as asked", function()
			local hk = new_hk()
			local function bad(fields)
				local spec = reader("x", "optional", { interval_s = 3600 })
				for k, v in pairs(fields) do spec[k] = v end
				return function() hk:define(spec) end
			end
			assert.has_error(bad({ class = "sometimes" }))
			assert.has_error(bad({ run = "not a function" }))
			assert.has_error(bad({ guards = { "sunny" } }))
			assert.has_error(bad({ triggers = { "whenever" } }))
			-- "timer" needs an interval
			assert.has_error(function() hk:define(reader("y", "optional", { triggers = { "timer" } })) end)
			-- above the hour's budget an optional task could never run
			assert.has_error(bad({ budget = housekeeping.HOUR_BUDGET + 1 }))
			assert.has_error(bad({ budget = 1.5 }))
			assert.has_error(bad({ persist = true, interval_s = 1800 })) -- persist needs an hour or more
			assert.has_error(bad({ jitter = 2 }))
			assert.has_error(function() housekeeping.new({}) end) -- http is required
			hk:define(reader("x", "optional", { interval_s = 3600 }))
			assert.has_error(function() hk:define(reader("x", "optional")) end) -- a name is defined once
			hk:define(reader("big", "essential", { budget = 500 })) -- an essential budget has no hourly cap
		end)

		it("arms nothing before start(), then one alarm, never more than an hour ahead", function()
			local hk = new_hk()
			hk:define(reader("daily", "optional", { interval_s = 86400 }))
			hk:define(reader("resync", "essential", { triggers = { "connect" } }))
			hk:poke("resync", "connect")
			assert.same({}, c4.calls_to("SetTimer"), "C4:SetTimer is not for OnDriverInit (SDK 34_timer/_1)")
			hk:mark_fresh("daily")
			hk:start("DIT_ADDING")
			assert.equal(1, #c4.active_timers())
			c4.advance(1)
			assert.same({ "resync" }, run_names())

			c4.advance(DAY + jitter_s("daily") * S)
			for _, args in ipairs(c4.calls_to("SetTimer")) do
				assert.is_true(args[1] <= HOUR, "an alarm of " .. args[1] .. " ms")
			end
			assert.equal(1, #c4.active_timers(), "one alarm while idle")
			assert.same({ "resync" }, run_names(), "the daily task is not due before its deadline")
			local deadline = T0 + DAY + math.floor(DAY * 0.1 * housekeeping.spread(DEVICE, "daily"))
			c4.advance(deadline - c4.now_ms - 1)
			assert.same({ "resync" }, run_names())
			c4.advance(1)
			assert.same({ "resync", "daily" }, run_names())
			assert.equal(deadline, runs[2].at)
		end)

		it("only issues GETs, and drops a request's quiet_ms before sending it", function()
			local hk = new_hk()
			local answers = {}
			hk:define({ name = "writer", class = "essential", triggers = { "event" }, budget = 3, guards = {},
				run = function(job, done)
					job.http({ method = "PUT", path = "/clip/v2/resource/light/x", body = { on = { on = true } } },
						function(r) answers[#answers + 1] = r end)
					job.http({ path = "/clip/v2/resource/scene", quiet_ms = 5000 }, function(r)
						answers[#answers + 1] = r
						done(true)
					end)
				end })
			hk:start("DIT_ADDING")
			hk:poke("writer", "event")
			c4.advance(1)
			assert.equal(1, #sent)
			assert.same({ method = "GET", path = "/clip/v2/resource/scene" }, sent[1].req)
			assert.equal(5000, user_quiet, "the scene GET asks the gate for 5 s without a user write")
			assert.same({ ok = false, err = "housekeeping only reads: PUT refused" }, answers[1])
			assert.is_true(answers[2].ok)
		end)
	end)

	describe("budgets", function()
		it("never exceeds a run's budget or HOUR_BUDGET optional requests in any rolling hour over 48 hours", function()
			local hk = new_hk()
			local refusals = 0
			-- Each run asks for two GETs more than its budget lets it send.
			local function greedy(name, class, fields)
				fields.name, fields.class, fields.guards = name, class, {}
				fields.run = function(job, done)
					runs[#runs + 1] = { name = name, at = c4.now_ms, trigger = job.trigger }
					local n = 0
					local function step()
						if n == fields.budget + 2 then return done(true, "read") end
						n = n + 1
						job.http({ path = "/clip/v2/resource/" .. name }, function(r)
							if not r.ok then refusals = refusals + 1 end
							step()
						end)
					end
					step()
				end
				return fields
			end
			hk:define(greedy("safety", "optional", { interval_s = 600, budget = 17 }))
			hk:define(greedy("stale", "optional", { triggers = { "event" }, debounce_s = 10, min_gap_s = 60,
				budget = 15 }))
			hk:define(greedy("identity", "optional", { interval_s = 3600, budget = 1 }))
			hk:define(greedy("resync", "essential", { triggers = { "connect" }, debounce_s = 2, budget = 17 }))
			hk:start("DIT_ADDING")

			-- A fixed pseudo-random trigger table (Park-Miller, exact in doubles).
			local seed = 20261105
			local function random(n)
				seed = (seed * 16807) % 2147483647
				return seed % n
			end
			local stop_at = c4.now_ms + 48 * HOUR
			while c4.now_ms < stop_at do
				c4.advance((1 + random(20)) * MIN + random(1000))
				local pick = random(10)
				if pick < 6 then
					hk:poke("stale", "event")
				elseif pick < 8 then
					hk:poke("resync", "connect")
				end
			end

			local optional = {}
			for _, entry in ipairs(sent) do
				if not entry.req.path:find("resync", 1, true) then optional[#optional + 1] = entry.at end
			end
			for i, at in ipairs(optional) do
				local in_window = 0
				for j = i, 1, -1 do
					if optional[j] > at - HOUR then in_window = in_window + 1 else break end
				end
				assert.is_true(in_window <= housekeeping.HOUR_BUDGET, string.format(
					"%d optional requests in the hour up to %d", in_window, at))
			end
			for _, report in ipairs(reports) do
				assert.is_true(report.requests <= report.budget, report.task .. " sent more than its budget")
			end
			assert.is_true(#optional > 1500, "the hourly budget is used, not starved: " .. #optional)
			assert.is_true(refusals > 0, "requests beyond a run's budget are refused")
			assert.is_true(#run_times("resync") > 10, "essential runs are outside the hourly budget")
			assert.equal(1, max_inflight)
		end)

		-- §4 finding 7: the driver's background reads send their GETs through
		-- bridge_request, not job.http; job.charge counts each one as job.http
		-- would, so they are not outside the hourly budget.
		it("counts job.charge's requests against the run's budget and the rolling hour, as job.http's", function()
			-- Six reads an hour (every 10 minutes), 15 requests each, budget 25,
			-- sent by another path than job.http and charged one by one: the
			-- driver's stream-down read. They all fit the hour.
			local charged, answers = {}, {}
			local function down_read(hk)
				hk:define({
					name = "down_read", class = "optional", interval_s = 600, budget = 25, guards = {},
					run = function(job, done)
						runs[#runs + 1] = { name = "down_read", at = c4.now_ms, trigger = job.trigger }
						for _ = 1, 15 do
							local refusal = job.charge()
							answers[#answers + 1] = refusal or "sent"
							if not refusal then charged[#charged + 1] = c4.now_ms end
						end
						done(true, "15 read")
					end,
				})
			end
			local hk = new_hk()
			down_read(hk)
			hk:start("DIT_ADDING")
			c4.advance(2 * HOUR)
			local reads = run_times("down_read")
			assert.is_true(#reads >= 11, "a read every ten minutes or so: " .. #reads)
			for _, gap in ipairs(gaps(reads)) do
				assert.is_true(gap <= 12 * MIN, "no read held back by the hour: " .. gap)
			end
			for _, a in ipairs(answers) do
				assert.equal("sent", a)
			end
			assert.equal(90, hk:info("down_read").hour_used, "six reads of 15 in the last hour")
			assert.equal(15, reports[#reports].requests, "the report counts the charged requests")

			-- Beside a task that reads through job.http, both together stay
			-- within the hour's budget.
			hk:stop()
			runs, charged, answers, sent, reports = {}, {}, {}, {}, {}
			local hk3 = new_hk()
			down_read(hk3)
			hk3:define(reader("other", "optional", { interval_s = 600, reads = 20, budget = 20 }))
			hk3:start("DIT_ADDING")
			c4.advance(6 * HOUR)
			local all = {}
			for _, at in ipairs(charged) do all[#all + 1] = at end
			for _, entry in ipairs(sent) do all[#all + 1] = entry.at end
			table.sort(all)
			for i, at in ipairs(all) do
				local in_window = 0
				for j = i, 1, -1 do
					if all[j] > at - HOUR then in_window = in_window + 1 else break end
				end
				assert.is_true(in_window <= housekeeping.HOUR_BUDGET, string.format(
					"%d optional requests in the hour up to %d", in_window, at))
			end
			assert.is_true(#charged > 0 and #sent > 0, "both ran")

			-- Beyond the run's budget charge refuses nothing (a person's request
			-- may share the path), but counts every request.
			hk3:stop()
			local hk2 = new_hk()
			local said = {}
			hk2:define({
				name = "greedy", class = "optional", triggers = { "event" }, budget = 3, guards = {},
				run = function(job, done)
					for _ = 1, 4 do said[#said + 1] = job.charge() or "sent" end
					done(true)
				end,
			})
			hk2:start("DIT_ADDING")
			hk2:poke("greedy", "event")
			c4.advance(1)
			assert.same({ "sent", "sent", "sent", "sent" }, said)
			assert.equal(4, hk2:info("greedy").hour_used)
		end)

		it("keeps counting a charged request in the hour after its run timed out", function()
			local hk = new_hk()
			local late
			hk:define({
				name = "slow", class = "optional", triggers = { "event" }, budget = 5, guards = {}, timeout_s = 10,
				run = function(job) late = job end, -- done never comes
			})
			hk:start("DIT_ADDING")
			hk:poke("slow", "event")
			c4.advance(11 * S)
			assert.is_nil(late.charge(), "nothing refused after the run's end")
			assert.equal(1, hk:info("slow").hour_used)
		end)
	end)

	describe("one job at a time", function()
		it("holds a second due task until the first run ends, with one request in flight", function()
			local hk = new_hk()
			hold = true
			hk:define(reader("first", "essential", { triggers = { "event" }, reads = 2 }))
			hk:define(reader("second", "essential", { triggers = { "event" } }))
			hk:define(reader("third", "optional", { interval_s = 3600 }))
			hk:start("DIT_ADDING")
			hk:poke("first", "event")
			hk:poke("second", "event")
			c4.advance(10 * S)
			assert.same({ "first" }, run_names())
			assert.equal(1, #sent)
			hk:poke("second", "event") -- triggers and state changes while the first runs
			hk:wake()
			answer_next()
			c4.advance(10 * S)
			assert.same({ "first" }, run_names(), "the first run is still reading")
			answer_next()
			c4.advance(1)
			assert.same({ "first", "second" }, run_names())
			hk:wake()
			c4.advance(MIN)
			assert.same({ "first", "second" }, run_names(), "the third waits for the second")
			answer_next()
			c4.advance(30 * S)
			assert.same({ "first", "second", "third" }, run_names())
			answer_next()
			assert.equal(1, max_inflight)
		end)

		it("queues a run's own requests: one in flight, the next after its answer", function()
			local hk = new_hk()
			hold = true
			hk:define({ name = "fan", class = "essential", triggers = { "event" }, budget = 3, guards = {},
				run = function(job, done)
					local left = 3
					for i = 1, 3 do
						job.http({ path = "/clip/v2/resource/" .. i }, function()
							left = left - 1
							if left == 0 then done(true) end
						end)
					end
				end })
			hk:start("DIT_ADDING")
			hk:poke("fan", "event")
			c4.advance(1)
			assert.equal(1, #sent)
			answer_next()
			assert.equal(2, #sent)
			answer_next()
			answer_next()
			assert.equal(3, #sent)
			assert.equal(1, max_inflight)
			assert.is_true(reports[1].ok)
		end)
	end)

	describe("start(dit): the quiet period", function()
		local function startup_hk(dit)
			local hk = new_hk()
			hk:define(reader("resync", "essential", { triggers = { "connect" }, debounce_s = 2, reads = 3 }))
			hk:define(reader("safety", "optional", { interval_s = 6 * 3600 }))
			hk:start(dit)
			return hk
		end

		it("DIT_STARTUP: the essential connect resync runs at once, no optional task before 300 s + jitter", function()
			local hk = startup_hk("DIT_STARTUP")
			hk:poke("resync", "connect")
			c4.advance(2 * S)
			assert.same({ "resync" }, run_names())
			assert.equal(T0 + 2 * S, runs[1].at)
			local quiet_end = T0 + (300 + jitter_s("startup")) * S
			c4.advance(quiet_end - c4.now_ms - 1)
			assert.same({ "resync" }, run_names(), "nothing optional in the quiet period")
			c4.advance(1)
			assert.same({ "resync", "safety" }, run_names())
			assert.equal(quiet_end, runs[2].at)
		end)

		it("DIT_UPDATING waits 60 s, DIT_ADDING nothing, and a missing DIT counts as DIT_STARTUP", function()
			local hk = startup_hk("DIT_UPDATING")
			c4.advance(60 * S - 1)
			assert.same({}, run_names())
			c4.advance(1)
			assert.same({ "safety" }, run_names())
			hk:stop()

			runs = {}
			c4.now_ms = T0 + DAY
			local base = c4.now_ms
			hk = startup_hk("DIT_ADDING")
			c4.advance(1)
			assert.same({ "safety" }, run_names())
			assert.equal(base + 1, runs[1].at)
			hk:stop()

			runs = {}
			c4.now_ms = T0 + 2 * DAY
			base = c4.now_ms
			startup_hk(nil)
			c4.advance((300 + jitter_s("startup")) * S)
			assert.same({ "safety" }, run_names())
			assert.equal(base + (300 + jitter_s("startup")) * S, runs[1].at)
			assert.is_true(saw_log("started (no DIT)"))
		end)

		it("a successful resync marks the safety net fresh (refreshes)", function()
			local hk = new_hk()
			hk:define(reader("resync", "essential", { triggers = { "connect" }, debounce_s = 2,
				refreshes = { "safety" } }))
			hk:define(reader("safety", "optional", { interval_s = 6 * 3600 }))
			hk:start("DIT_STARTUP")
			hk:poke("resync", "connect")
			c4.advance(6 * HOUR)
			assert.same({ "resync" }, run_names(), "the connect resync was the safety net's run")
			c4.advance(HOUR)
			assert.same({ "resync", "safety" }, run_names())
			local deadline = T0 + 2 * S + 6 * HOUR + math.floor(6 * HOUR * 0.1 * housekeeping.spread(DEVICE, "safety"))
			assert.equal(deadline, runs[2].at)
		end)
	end)

	describe("overdue tasks after a restart", function()
		it("go one at a time, 30 s apart, oldest deadline first", function()
			local W = math.floor(T0 / 1000)
			local function rec(age_s)
				return { at = W - age_s, ok = true, ok_at = W - age_s, runs = 4, fails = 0 }
			end
			c4.persist[housekeeping.STORE_NAME] = { v = 1, bridge_id = BRIDGE_ID, tasks = {
				six = rec(2 * 86400),      -- deadline 42 h ago
				daily = rec(3 * 86400),    -- deadline 48 h ago
				half = rec(86400),         -- deadline 12 h ago
			} }
			local hk = new_hk()
			hk:define(reader("six", "optional", { interval_s = 6 * 3600, persist = true }))
			hk:define(reader("daily", "optional", { interval_s = 86400, persist = true }))
			hk:define(reader("half", "optional", { interval_s = 12 * 3600, persist = true }))
			hk:start("DIT_STARTUP")
			c4.advance(10 * MIN)
			local quiet_end = T0 + (300 + jitter_s("startup")) * S
			assert.same({ "daily", "six", "half" }, run_names())
			assert.same({ quiet_end, quiet_end + 30 * S, quiet_end + 60 * S },
				{ runs[1].at, runs[2].at, runs[3].at })
		end)
	end)

	describe("backoff", function()
		it("doubles from 60 s, caps at min(interval, 1 h) and resets after one success", function()
			local hk = new_hk()
			results.check = { false, false, false, false, false, false, false, false, false }
			hk:define(reader("check", "optional", { interval_s = 2 * 3600 }))
			hk:start("DIT_ADDING")
			c4.advance(12 * HOUR)
			local times = run_times("check")
			assert.same({ 60 * S, 120 * S, 240 * S, 480 * S, 960 * S, 1920 * S, HOUR, HOUR, HOUR },
				{ unpack(gaps(times), 1, 9) })
			local jitter = math.floor(2 * HOUR * 0.1 * housekeeping.spread(DEVICE, "check"))
			assert.equal(2 * HOUR + jitter, gaps(times)[10], "after a success: the interval again")
			assert.equal(0, hk:info("check").fails)
			assert.is_true(saw_log("check (retry): failed: the bridge said 503; 1 request"))
		end)

		it("follows a list of delays (the key re-check: 5 min, 15 min, 1 h, then hourly) and backoff_max_s", function()
			local hk = new_hk()
			results.key = { false, false, false, false, false }
			results.resync = { false, false, false, false, false, false }
			hk:define(reader("key", "essential", { triggers = { "error" }, backoff_s = { 300, 900, 3600 } }))
			hk:define(reader("resync", "essential", { triggers = { "connect" }, backoff_max_s = 900 }))
			hk:start("DIT_ADDING")
			hk:poke("key", "error")
			hk:poke("resync", "connect")
			c4.advance(10 * HOUR)
			assert.same({ 300 * S, 900 * S, HOUR, HOUR, HOUR }, gaps(run_times("key")))
			assert.same(6, #run_times("key"), "after its success the trigger-only task rests")
			assert.same({ 60 * S, 120 * S, 240 * S, 480 * S, 900 * S, 900 * S }, gaps(run_times("resync")))
		end)

		it("lets a trigger that comes after the failed run go at its debounce", function()
			local hk = new_hk()
			results.resync = { false }
			hk:define(reader("resync", "essential", { triggers = { "connect" }, debounce_s = 2 }))
			hk:start("DIT_ADDING")
			hk:poke("resync", "connect")
			c4.advance(5 * S)
			assert.equal(1, #runs)
			hk:poke("resync", "connect") -- the stream connected again
			c4.advance(2 * S)
			assert.same({ T0 + 2 * S, T0 + 7 * S }, run_times("resync"))
			c4.advance(HOUR)
			assert.equal(2, #runs, "the success ended the retries")
		end)
	end)

	describe("coalescing", function()
		it("gives forty pokes in a burst one run and answers every caller once", function()
			local hk = new_hk()
			hk:define(reader("stale", "essential", { triggers = { "event" }, debounce_s = 2 }))
			hk:start("DIT_ADDING")
			for i = 1, 40 do
				assert.is_true(hk:poke("stale", "event", caller(i)))
				c4.advance(125)
			end
			assert.same({}, run_names(), "each poke moved the debounce")
			c4.advance(2 * S)
			assert.same({ "stale" }, run_names())
			assert.equal(T0 + 39 * 125 + 2 * S, runs[1].at)
			assert.equal(40, #answered)
			for i = 1, 40 do
				assert.same({ { tag = i, ok = true, text = "1 read" } }, answers_of(i))
			end
			c4.advance(HOUR)
			assert.equal(1, #runs)
		end)

		it("makes exactly one more run for pokes during a run, answered by that run", function()
			local hk = new_hk()
			hold = true
			hk:define(reader("resync", "essential", { triggers = { "connect", "event" }, debounce_s = 2 }))
			hk:start("DIT_ADDING")
			hk:poke("resync", "connect", caller("before"))
			c4.advance(2 * S)
			assert.equal(1, #runs)
			hk:poke("resync", "event", caller("during 1"))
			hk:poke("resync", "event", caller("during 2"))
			c4.advance(5 * S)
			assert.equal(1, #runs, "never two at once")
			answer_next()
			assert.same({ "before" }, { answered[1].tag })
			assert.equal(1, #answered, "the pokes during the run wait for the next one")
			c4.advance(S)
			assert.equal(2, #runs, "one more run")
			assert.equal("event", runs[2].trigger)
			answer_next()
			assert.equal(3, #answered)
			assert.equal(1, #answers_of("during 1"))
			assert.equal(1, #answers_of("during 2"))
			c4.advance(HOUR)
			assert.equal(2, #runs)
		end)

		it("refuses a poke for an unknown task or trigger, and answers it", function()
			local hk = new_hk()
			hk:define(reader("resync", "essential", { triggers = { "connect" } }))
			hk:start("DIT_ADDING")
			assert.is_false(hk:poke("nothing", "event", caller("a")))
			assert.is_false(hk:poke("resync", "setting", caller("b")))
			assert.same({ { tag = "a", ok = false, text = "no task nothing" },
				{ tag = "b", ok = false, text = "setting is not a trigger of resync" } }, answered)
			c4.advance(HOUR)
			assert.same({}, run_names())
		end)
	end)

	describe("user commands first", function()
		it("waits while a user command is busy, looking again every 250 ms", function()
			local hk = new_hk()
			hk:define(reader("safety", "optional", { interval_s = 6 * 3600 }))
			user = true
			hk:start("DIT_ADDING")
			c4.advance(1)
			assert.equal(1, #runs, "the run starts")
			assert.equal(0, #sent, "its GET waits for the user")
			assert.equal(1500, user_quiet, "no request within 1.5 s of a user write")
			c4.advance(3 * S)
			assert.equal(0, #sent)
			user = false
			c4.advance(250)
			assert.equal(1, #sent)
			assert.equal(T0 + 1 + 3250, sent[1].at)
		end)

		it("goes after 10 s whatever, so a long slider session cannot starve the resync", function()
			local hk = new_hk()
			hk:define(reader("resync", "essential", { triggers = { "connect" }, reads = 2 }))
			user = true
			hk:start("DIT_ADDING")
			hk:poke("resync", "connect")
			c4.advance(1 + 10 * S - 1)
			assert.equal(0, #sent)
			c4.advance(1)
			assert.equal(1, #sent)
			assert.equal(T0 + 1 + 10 * S, sent[1].at)
			c4.advance(10 * S)
			assert.equal(2, #sent, "each request waits for the gate")
		end)

		it("lets a click skip the gate, the debounce, the quiet period and the queue", function()
			local hk = new_hk()
			hk:define(reader("safety", "optional", { interval_s = 6 * 3600 }))
			hk:define(reader("refresh", "optional", { triggers = { "event" }, debounce_s = 30 }))
			user = true
			hk:start("DIT_STARTUP")
			hk:poke("refresh", "click", caller("click"))
			c4.advance(1)
			assert.same({ "refresh" }, run_names())
			assert.equal("click", runs[1].trigger)
			assert.equal(1, #sent)
			assert.same({ { tag = "click", ok = true, text = "1 read" } }, answered)
			assert.equal(0, hk:info("refresh").hour_used, "a click does not count against the hour's budget")
		end)

		it("puts a click at the front of the queue, ahead of a due essential and a due optional task", function()
			local hk = new_hk()
			hk:define(reader("safety", "optional", { interval_s = 6 * 3600 }))
			hk:define(reader("resync", "essential", { triggers = { "connect" } }))
			hk:define(reader("refresh", "optional", { triggers = { "event" } }))
			hk:start("DIT_ADDING")
			hk:poke("resync", "connect")
			hk:poke("refresh", "click")
			c4.advance(2) -- each run starts 1 ms after the one before it ends
			assert.same({ "refresh", "resync" }, run_names())
			c4.advance(30 * S)
			assert.same({ "refresh", "resync", "safety" }, run_names())
		end)
	end)

	describe("guards", function()
		it("hold a task until they hold, looked at again after 60 s or at wake()", function()
			local hk = new_hk()
			guards = { paired = true, identity_ok = true, key_ok = true, not_pairing = true, stream_up = false }
			hk:define(reader("poll", "essential", { triggers = { "event" }, guards = { "paired", "stream_up" } }))
			hk:start("DIT_ADDING")
			hk:poke("poll", "event")
			c4.advance(5 * MIN)
			assert.same({}, run_names())
			guards = ALL_GUARDS
			hk:wake()
			c4.advance(1)
			assert.same({ "poll" }, run_names())

			local held_at = c4.now_ms + 1
			hk:poke("poll", "event")
			guards = {}
			c4.advance(30 * S)
			guards = ALL_GUARDS
			c4.advance(30 * S)
			assert.equal(1, #runs)
			c4.advance(1)
			assert.equal(2, #runs)
			assert.equal(held_at + 60 * S, runs[2].at, "looked at again 60 s after it was held")
		end)

		it("with the key refused, runs only the key re-check; a click held by a guard is answered at once", function()
			local hk = new_hk()
			guards = { paired = true, identity_ok = true, key_ok = false, not_pairing = true }
			hk:define(reader("safety", "optional", { interval_s = 6 * 3600, guards = housekeeping.DEFAULT_GUARDS }))
			hk:define(reader("key", "essential", { triggers = { "error" }, guards = { "paired", "identity_ok" } }))
			hk:start("DIT_ADDING")
			hk:poke("key", "error")
			hk:poke("safety", "click", caller("click"))
			c4.advance(HOUR)
			assert.same({ "key" }, run_names())
			assert.same({ { tag = "click", ok = false, text = "not now: key_ok does not hold" } }, answered)
		end)
	end)

	describe("persistence", function()
		it("keeps the last run across a restart, so an interval task is not run again early", function()
			local hk = new_hk()
			hk:define(reader("daily", "optional", { interval_s = 86400, persist = true }))
			hk:define(reader("quick", "optional", { interval_s = 1800 }))
			hk:start("DIT_ADDING")
			c4.advance(MIN)
			assert.same({ "daily", "quick" }, run_names())
			local stored = c4.persist[housekeeping.STORE_NAME]
			assert.equal(1, stored.v)
			assert.equal(BRIDGE_ID, stored.bridge_id)
			assert.same({ "daily" }, (function()
				local names = {}
				for name in pairs(stored.tasks) do names[#names + 1] = name end
				return names
			end)(), "only tasks with persist are stored")
			assert.same({ at = math.floor((T0 + 1) / 1000 + 0.5), ok = true, ok_at = math.floor((T0 + 1) / 1000 + 0.5),
				text = "1 read", runs = 1, fails = 0 }, stored.tasks.daily)
			for _, args in ipairs(c4.calls_to("PersistSetValue")) do
				assert.equal(housekeeping.STORE_NAME, args[1], "no other store key is written")
			end

			-- Director restarts two hours later: timers gone, the store kept.
			hk:stop()
			c4.advance(2 * HOUR)
			runs = {}
			local again = new_hk()
			again:define(reader("daily", "optional", { interval_s = 86400, persist = true }))
			again:start("DIT_STARTUP")
			local deadline = T0 + 1 + DAY + math.floor(DAY * 0.1 * housekeeping.spread(DEVICE, "daily"))
			c4.advance(deadline - c4.now_ms - 2 * S)
			assert.same({}, run_names(), "not before its interval")
			c4.advance(3 * S)
			assert.same({ "daily" }, run_names())
			assert.is_true(math.abs(runs[1].at - deadline) <= S)
		end)

		it("counts a time from the future as now, discards another bridge's store, ignores an unknown shape", function()
			local W = math.floor(T0 / 1000)
			local function store(value)
				c4.persist[housekeeping.STORE_NAME] = value
				runs = {}
				local hk = new_hk()
				hk:define(reader("daily", "optional", { interval_s = 86400, persist = true }))
				hk:start("DIT_ADDING")
				return hk
			end

			local hk = store({ v = 1, bridge_id = BRIDGE_ID, tasks = { daily = { at = W + 5 * 86400, ok = true,
				ok_at = W + 5 * 86400, runs = 2, fails = 0 } } })
			c4.advance(DAY - S)
			assert.same({}, run_names(), "a clock that jumped back: the stored run counts as now, not as five days ahead")
			c4.advance(3 * HOUR)
			assert.same({ "daily" }, run_names())
			hk:stop()

			hk = store({ v = 1, bridge_id = "001788fffe456def", tasks = { daily = { at = W, ok = true, ok_at = W,
				runs = 2, fails = 0 } } })
			c4.advance(1)
			assert.same({ "daily" }, run_names(), "another bridge's last run counts for nothing")
			assert.equal(BRIDGE_ID, c4.persist[housekeeping.STORE_NAME].bridge_id)
			hk:stop()

			hk = store({ v = 7, tasks = {} })
			c4.advance(1)
			assert.same({ "daily" }, run_names())
			assert.is_true(saw_log("hue_housekeeping has an unknown shape; ignored"))
			hk:stop()
		end)

		it("keeps the stored entries of tasks this build does not define", function()
			local W = math.floor(T0 / 1000)
			local retired = { at = W - 100, ok = true, ok_at = W - 100, runs = 9, fails = 0 }
			c4.persist[housekeeping.STORE_NAME] = { v = 1, bridge_id = BRIDGE_ID, tasks = { retired = retired } }
			local hk = new_hk()
			hk:define(reader("daily", "optional", { interval_s = 86400, persist = true }))
			hk:start("DIT_ADDING")
			c4.advance(1)
			assert.same(retired, c4.persist[housekeeping.STORE_NAME].tasks.retired)
			assert.is_table(c4.persist[housekeeping.STORE_NAME].tasks.daily)
		end)
	end)

	describe("reset(generation)", function()
		it("drops a late result, answers the dropped run's callers, and clears the backoff", function()
			local hk = new_hk()
			local delivered = 0
			results.resync = { false }
			hk:define(reader("resync", "essential", { triggers = { "connect" } }))
			hk:define({ name = "slow", class = "essential", triggers = { "event" }, budget = 1, guards = {},
				run = function(job, done)
					runs[#runs + 1] = { name = "slow", at = c4.now_ms }
					job.http({ path = "/clip/v2/resource/light" }, function()
						delivered = delivered + 1
						done(true, "absorbed")
					end)
				end })
			hk:start("DIT_ADDING")
			hk:poke("resync", "connect")
			c4.advance(1)
			assert.equal(1, hk:info("resync").fails)

			hold = true
			hk:poke("slow", "event", caller("slow"))
			c4.advance(1)
			assert.equal(1, #sent - 1, "the slow GET is in flight")
			hk:reset(7)
			assert.same({ { tag = "slow", ok = false, text = "cancelled: bridge address changed" } }, answered)
			assert.equal(0, hk:info("resync").fails, "backoffs cleared")
			answer_next({ ok = true, code = 200, json = { data = {} } })
			assert.equal(0, delivered, "the late result never reaches the run")
			assert.equal(1, #reports, "no report for the dropped run")

			hold = false
			hk:poke("slow", "event")
			c4.advance(1)
			assert.equal(1, delivered, "the engine runs on after a reset")
		end)

		it("with forget, clears the last runs and the store", function()
			local hk = new_hk()
			hk:define(reader("daily", "optional", { interval_s = 86400, persist = true }))
			hk:start("DIT_ADDING")
			c4.advance(1)
			assert.equal(1, #runs)
			hk:reset(8, true)
			assert.same({ v = 1, tasks = {} }, c4.persist[housekeeping.STORE_NAME])
			c4.advance(30 * S)
			assert.equal(2, #runs, "a forgotten task is due again (after the optional tasks' 30 s gap)")
			assert.equal(T0 + 1 + 30 * S, runs[2].at)
		end)
	end)

	describe("stop()", function()
		it("cancels every timer; nothing runs or answers afterwards", function()
			local hk = new_hk()
			hk:define(reader("daily", "optional", { interval_s = 86400 }))
			hk:define(reader("resync", "essential", { triggers = { "connect" }, debounce_s = 2 }))
			hk:start("DIT_STARTUP")
			assert.equal(1, #c4.active_timers())
			hk:stop()
			assert.same({}, c4.active_timers(), "the alarm of an idle engine")
			c4.advance(DAY)
			assert.same({}, run_names())

			hk = new_hk()
			hk:define(reader("daily", "optional", { interval_s = 86400 }))
			hk:define(reader("resync", "essential", { triggers = { "connect" }, debounce_s = 2 }))
			hk:start("DIT_STARTUP")
			hold = true
			hk:poke("resync", "connect", caller("resync"))
			c4.advance(2 * S)
			assert.equal(1, #runs)
			hk:stop()
			assert.same({}, c4.active_timers())
			answer_next()
			assert.same({}, answered, "stop answers no one")
			assert.is_false(hk:poke("resync", "connect", caller("late")))
			assert.same({ { tag = "late", ok = false, text = "stopped" } }, answered)
			c4.advance(3 * DAY)
			assert.equal(1, #runs)
			assert.same({}, c4.active_timers())
		end)

		it("cancels the user gate's timer too", function()
			local hk = new_hk()
			hk:define(reader("safety", "optional", { interval_s = 6 * 3600 }))
			user = true
			hk:start("DIT_ADDING")
			c4.advance(1)
			assert.equal(1, #c4.active_timers() - 1, "the gate looks again in 250 ms (besides the run's timeout)")
			hk:stop()
			assert.same({}, c4.active_timers())
			user = false
			c4.advance(MIN)
			assert.equal(0, #sent)
		end)
	end)

	describe("jitter", function()
		it("is a fraction in [0, 1) that depends only on the device id and the name", function()
			local a = housekeeping.spread(DEVICE, "safety")
			assert.equal(a, housekeeping.spread(DEVICE, "safety"))
			assert.is_true(a >= 0 and a < 1)
			assert.are_not.equal(a, housekeeping.spread(DEVICE, "identity"))
			assert.are_not.equal(a, housekeeping.spread(DEVICE + 1, "safety"))
		end)

		it("puts a task at the same time for the same device id, and elsewhere for another", function()
			local function first_run(device)
				c4.now_ms = T0
				runs = {}
				local hk = new_hk({ device_id = device })
				hk:define(reader("safety", "optional", { interval_s = 6 * 3600 }))
				hk:mark_fresh("safety")
				hk:start("DIT_ADDING")
				c4.advance(7 * HOUR)
				hk:stop()
				return runs[1].at
			end
			local one = first_run(DEVICE)
			assert.equal(one, first_run(DEVICE))
			assert.are_not.equal(one, first_run(DEVICE + 1))
			assert.is_true(one >= T0 + 6 * HOUR and one < T0 + 6 * HOUR + 0.1 * 6 * HOUR)
		end)
	end)

	describe("timeout", function()
		it("ends a run whose done never comes, releases the lock and ignores the late done", function()
			local hk = new_hk()
			local late
			hk:define({ name = "stuck", class = "essential", triggers = { "event" }, timeout_s = 30, guards = {},
				run = function(_, done)
					runs[#runs + 1] = { name = "stuck", at = c4.now_ms }
					late = done
				end })
			hk:define(reader("next", "essential", { triggers = { "event" } }))
			hk:start("DIT_ADDING")
			hk:poke("stuck", "event", caller("stuck"))
			hk:poke("next", "event")
			c4.advance(30 * S)
			assert.same({ "stuck" }, run_names())
			c4.advance(1)
			assert.same({ { tag = "stuck", ok = false, text = "timed out after 30 s" } }, answered)
			assert.equal("stuck", reports[1].task)
			assert.is_false(reports[1].ok)
			c4.advance(1)
			assert.same({ "stuck", "next" }, run_names(), "the lock is free again")
			late(true, "too late")
			assert.equal(2, #reports, "the late done reports nothing")
			assert.equal(1, #answered)
		end)

		it("ends a run whose code raised, as a failure", function()
			local hk = new_hk()
			hk:define({ name = "buggy", class = "essential", triggers = { "event" }, guards = {},
				run = function() error("boom") end })
			hk:start("DIT_ADDING")
			hk:poke("buggy", "event")
			c4.advance(1)
			assert.is_false(reports[1].ok)
			assert.truthy(reports[1].text:find("raised: .*boom"))
		end)
	end)

	describe("reports", function()
		it("give one log line and one status per run: task, trigger, requests, result", function()
			local hk = new_hk()
			results.resync = { true, false }
			hk:define(reader("resync", "essential", { triggers = { "connect" }, reads = 3 }))
			hk:start("DIT_ADDING")
			hk:poke("resync", "connect")
			c4.advance(1)
			assert.equal(1, #reports)
			local r = reports[1]
			assert.same({ "resync", "connect", "essential", 3, 3, true, "3 read" },
				{ r.task, r.trigger, r.class, r.requests, r.budget, r.ok, r.text })
			assert.is_true(saw_log("[INFO] housekeeping: resync (connect): OK: 3 read; 3 requests, 0.0 s"))
			hk:poke("resync", "connect")
			c4.advance(1)
			assert.is_true(saw_log("[WARN] housekeeping: resync (connect): failed: the bridge said 503; 3 requests, "
				.. "0.0 s; next try in 60 s"))
		end)
	end)
end)
