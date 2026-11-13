local fake = require("helpers.fake_c4")
local log = require("common.log")

describe("bridge.commands", function()
	local commands, c4, q, sends, lines

	-- Records every PUT the queue asks for; a spec completes one by calling
	-- sends[n].done(result).
	local function fake_send(rid, body, done)
		table.insert(sends, { rid = rid, body = body, done = done })
	end

	local function timer_delays()
		local delays = {}
		for _, timer in ipairs(c4.active_timers()) do
			delays[#delays + 1] = timer.delay
		end
		table.sort(delays)
		return delays
	end

	-- set() and let the debounce fire.
	local function set_now(rid, fields)
		q:set(rid, fields)
		c4.fire_timers()
	end

	local function last_line()
		return lines[#lines] or ""
	end

	before_each(function()
		lines = {}
		log.sink = function(line) table.insert(lines, line) end
		c4 = fake.install_c4()
		package.loaded["bridge.commands"] = nil
		commands = require("bridge.commands")
		sends = {}
		q = commands.new({ send = fake_send })
	end)

	describe("body()", function()
		it("clamps brightness to [min_dim, 100] and rounds to 2 decimals", function()
			local limits = { min_dim = 0.2, mirek_min = 153, mirek_max = 500 }
			assert.same({ brightness = 0.2 }, commands.body({ brightness = 0.1 }, limits).dimming)
			assert.same({ brightness = 100 }, commands.body({ brightness = 150 }, limits).dimming)
			assert.same({ brightness = 33.33 }, commands.body({ brightness = 33.3333 }, limits).dimming)
			assert.same({ brightness = 1 }, commands.body({ brightness = 0.5 }).dimming, "default min_dim is 1")
		end)

		it("clamps mirek to the light's range as an integer", function()
			local limits = { min_dim = 1, mirek_min = 200, mirek_max = 454 }
			assert.same({ mirek = 200 }, commands.body({ mirek = 153 }, limits).color_temperature)
			assert.same({ mirek = 454 }, commands.body({ mirek = 600 }, limits).color_temperature)
			assert.same({ mirek = 301 }, commands.body({ mirek = 300.6 }, limits).color_temperature)
			assert.same({ mirek = 153 }, commands.body({ mirek = 100 }).color_temperature, "default range 153..500")
			assert.same({ mirek = 500 }, commands.body({ mirek = 900 }).color_temperature)
		end)

		it("sends xy clamped to [0, 1] with 4 decimals, and only with both coordinates", function()
			assert.same({ xy = { x = 0.3127, y = 1 } }, commands.body({ x = 0.31271, y = 1.2 }).color)
			assert.is_nil(commands.body({ x = 0.3 }).color, "half a colour is not sent")
		end)

		it("never puts xy and mirek in the same body", function()
			local body = commands.body({ x = 0.3, y = 0.3, mirek = 300 })
			assert.is_not_nil(body.color)
			assert.is_nil(body.color_temperature)
		end)

		it("turns brightness 0 into on:false without dimming", function()
			assert.same({ on = { on = false } }, commands.body({ brightness = 0, on = true }))
		end)

		it("adds dynamics only when rate > 0 and there is something to apply it to", function()
			assert.same({ on = { on = true } }, commands.body({ on = true, rate = 0 }))
			assert.same({ on = { on = true }, dynamics = { duration = 400 } }, commands.body({ on = true, rate = 400 }))
			assert.same({}, commands.body({ rate = 400 }), "a lone rate is nothing to send")
		end)

		-- Security review 2026-11-13 C-3 (#486): Lua 5.1's tonumber reads "nan"
		-- and "inf", and NaN fails every comparison of clamp().
		it("leaves out every number that is not finite, and caps the duration at 100 minutes", function()
			local nan, inf = 0 / 0, math.huge
			assert.same({}, commands.body({ brightness = nan, x = nan, y = 0.3, mirek = inf, rate = inf }))
			assert.same({ on = { on = true } }, commands.body({ on = true, brightness = nan, rate = nan }))
			assert.same({ dimming = { brightness = 50 }, dynamics = { duration = 6000000 } },
				commands.body({ brightness = 50, rate = 1e15 }))
			assert.same({ dimming_delta = { action = "up", brightness_delta = 100 } },
				commands.body({ dim = "up", delta = nan, rate = -inf }))
			assert.same({ mirek = 153 }, commands.body({ mirek = 100 }, { mirek_min = nan, mirek_max = inf })
				.color_temperature, "limits that are not finite are Hue's 153..500")
		end)
	end)

	-- Security review 2026-11-13 C-3 (#486).
	describe("numbers that are not finite", function()
		it("are dropped by set(), never kept or sent; a rate is clamped to 0..RATE_MAX", function()
			set_now("r", { on = true, brightness = "nan", x = "inf", y = "-inf", mirek = "nan", rate = "1e400" })
			assert.equal(1, #sends)
			assert.same({ on = { on = true } }, sends[1].body)
			sends[1].done({ ok = true, code = 200 })

			set_now("r", { brightness = "1e300", rate = "1e15" })
			assert.same({ dimming = { brightness = 100 }, on = { on = true }, dynamics = { duration = 6000000 } },
				sends[2].body)
			sends[2].done({ ok = true, code = 200 })

			set_now("r", { dim = "up", rate = "inf", level = "nan", delta = "nan" })
			assert.same({ dimming_delta = { action = "up", brightness_delta = 100 } }, sends[3].body)
			assert.equal(6000000, commands.RATE_MAX)
		end)

		it("leave a tap's stop on an unsent ramp without a level", function()
			q:set("r", { brightness = 40, on = true, rate = 2000 })
			q:set("r", { dim = "stop", level = "nan" })
			c4.fire_timers()
			assert.equal(0, #sends, "nothing to send: the stop has no level")
		end)
	end)

	describe("set()", function()
		it("arms one 80 ms timer per rid and re-arms it on another set", function()
			q:set("a", { brightness = 50 })
			assert.same({ commands.DEBOUNCE_MS }, timer_delays())
			local first = c4.active_timers()[1]
			q:set("a", { x = 0.3, y = 0.3 })
			assert.is_false(first.active, "the earlier timer was cancelled")
			assert.same({ commands.DEBOUNCE_MS }, timer_delays())
			q:set("b", { on = true })
			assert.same({ commands.DEBOUNCE_MS, commands.DEBOUNCE_MS }, timer_delays(), "one per rid")
			assert.equal(0, #sends, "nothing sent before the debounce fires")
		end)

		it("coalesces changes made before the timer fires into one PUT", function()
			q:set("a", { brightness = 50 })
			q:set("a", { x = 0.4, y = 0.4, rate = 200 })
			assert.equal(0, #sends)
			c4.fire_timers()
			assert.equal(1, #sends)
			assert.equal("a", sends[1].rid)
			assert.same({
				on = { on = true },
				dimming = { brightness = 50 },
				color = { xy = { x = 0.4, y = 0.4 } },
				dynamics = { duration = 200 },
			}, sends[1].body)
			assert.equal(1, q:stats().coalesced)
			assert.is_nil(q:pending("a"), "flushed")
		end)

		it("keeps only the latest colour mode", function()
			q:set("a", { mirek = 300 })
			q:set("a", { x = 0.3, y = 0.3 })
			assert.same({ x = 0.3, y = 0.3 }, q:pending("a"))
			q:set("a", { mirek = 250 })
			assert.same({ mirek = 250 }, q:pending("a"))
		end)

		it("derives on from brightness unless on is set explicitly afterwards", function()
			q:set("a", { brightness = 40 })
			assert.same({ brightness = 40, on = true }, q:pending("a"))
			q:set("a", { on = false })
			assert.same({ brightness = 40, on = false }, q:pending("a"))
			q:set("a", { brightness = 0 })
			assert.same({ brightness = 0, on = false }, q:pending("a"))
			c4.fire_timers()
			assert.same({ on = { on = false } }, sends[1].body, "to zero is off, no dimming")

			q:set("a", { brightness = 0 })
			q:set("a", { on = true })
			assert.same({ on = true }, q:pending("a"), "turning on after a zero forgets the zero")
		end)

		it("accepts the string forms the SendToDevice path delivers", function()
			q:set("a", { on = "true", brightness = "55.5", mirek = "370", rate = "100", x = "junk" })
			assert.same({ on = true, brightness = 55.5, mirek = 370, rate = 100 }, q:pending("a"))
		end)

		it("sends a change made while a PUT is in flight after that PUT returns", function()
			set_now("a", { brightness = 50 })
			assert.equal(1, #sends)
			q:set("a", { brightness = 60 })
			c4.fire_timers()
			assert.equal(1, #sends, "one PUT in flight per light")
			assert.same({ brightness = 60, on = true }, q:pending("a"))

			sends[1].done({ ok = true, code = 200 })
			assert.equal(2, #sends)
			assert.same({ on = { on = true }, dimming = { brightness = 60 } }, sends[2].body)
			assert.is_nil(q:pending("a"))
		end)

		it("ignores a done() delivered twice", function()
			set_now("a", { brightness = 50 })
			q:set("a", { brightness = 60 })
			sends[1].done({ ok = true, code = 200 })
			assert.equal(2, #sends)
			sends[1].done({ ok = true, code = 200 })
			assert.equal(2, #sends, "the stale done() did not flush anything")
		end)

		it("skips a flush that has nothing the bridge could act on", function()
			set_now("a", { rate = 300 })
			assert.equal(0, #sends)
			assert.equal(0, q:stats().sent)
		end)
	end)

	describe("limits()", function()
		it("applies the light's limits to its bodies and defaults for unknown lights", function()
			q:limits("a", { min_dim = 0.2, mirek_min = 200, mirek_max = 400 })
			set_now("a", { brightness = 0.1 })
			assert.same({ brightness = 0.2 }, sends[1].body.dimming)
			sends[1].done({ ok = true, code = 200 })
			set_now("a", { mirek = 500 })
			assert.same({ mirek = 400 }, sends[2].body.color_temperature)
			set_now("b", { brightness = 0.1, mirek = 500 })
			assert.same({ brightness = 1 }, sends[3].body.dimming)
			assert.same({ mirek = 500 }, sends[3].body.color_temperature)
		end)
	end)

	describe("token bucket", function()
		it("sends a burst of 10 at once and queues the rest until tokens refill", function()
			for i = 1, 12 do
				q:set("light" .. i, { on = true })
			end
			c4.fire_timers()
			assert.equal(10, #sends)
			assert.same({ 100, 100 }, timer_delays(), "two lights wait for the next token")

			c4.fire_timers()
			assert.equal(10, #sends, "no time has passed, still no token")
			assert.same({ 100, 100 }, timer_delays())

			c4.now_ms = c4.now_ms + 100
			c4.fire_timers()
			assert.equal(11, #sends, "one token after 100 ms")
			assert.same({ 100 }, timer_delays())

			c4.now_ms = c4.now_ms + 100
			c4.fire_timers()
			assert.equal(12, #sends)
			assert.same({}, timer_delays())
		end)

		it("does not let a set() during a token wait shorten the wait", function()
			for i = 1, 11 do
				q:set("light" .. i, { on = true })
			end
			c4.fire_timers()
			assert.same({ 100 }, timer_delays())
			q:set("light11", { brightness = 30 })
			assert.same({ 100 }, timer_delays())
			c4.now_ms = c4.now_ms + 100
			c4.fire_timers()
			assert.equal(11, #sends)
			assert.same({ on = { on = true }, dimming = { brightness = 30 } }, sends[11].body)
		end)

		it("refills to the burst size at most", function()
			c4.now_ms = c4.now_ms + 60000
			for i = 1, 11 do
				q:set("light" .. i, { on = true })
			end
			c4.fire_timers()
			assert.equal(10, #sends)
		end)

		it("uses opts.now when given", function()
			local t = 0
			q = commands.new({ send = fake_send, now = function() return t end })
			for i = 1, 11 do
				q:set("light" .. i, { on = true })
			end
			c4.fire_timers()
			assert.equal(10, #sends)
			t = 100
			c4.fire_timers()
			assert.equal(11, #sends)
		end)
	end)

	describe("results", function()
		it("retries a 429 with the same body after 500 then 1000 ms, and resets after a success", function()
			set_now("a", { brightness = 50 })
			local body = sends[1].body
			sends[1].done({ ok = false, code = 429, err = "HTTP 429" })
			assert.same({ 500 }, timer_delays())
			assert.truthy(last_line():find("retrying in 500 ms", 1, true), last_line())

			c4.fire_timers()
			assert.equal(2, #sends)
			assert.same(body, sends[2].body)
			sends[2].done({ ok = false, code = 429, err = "HTTP 429" })
			assert.same({ 1000 }, timer_delays())

			c4.fire_timers()
			assert.equal(3, #sends)
			assert.same(body, sends[3].body)
			sends[3].done({ ok = true, code = 200 })
			assert.same({}, timer_delays())
			assert.equal(2, q:stats().retried)

			set_now("a", { brightness = 60 })
			sends[4].done({ ok = false, code = 503, err = "HTTP 503" })
			assert.same({ 500 }, timer_delays(), "backoff starts over after a success")
		end)

		it("caps the backoff at 8 s", function()
			set_now("a", { on = true })
			local delays = {}
			for i = 1, 6 do
				sends[i].done({ ok = false, code = 500, err = "HTTP 500" })
				delays[i] = timer_delays()[1]
				-- Each retry when its delay is up: 23.5 s in all, inside MAX_AGE_S.
				c4.now_ms = c4.now_ms + delays[i]
				c4.fire_timers()
			end
			assert.same({ 500, 1000, 2000, 4000, 8000, 8000 }, delays)
		end)

		it("retries a transport error (no status code) with backoff", function()
			set_now("a", { on = true })
			sends[1].done({ ok = false, err = "transfer failed (7): Failed to connect" })
			assert.same({ 500 }, timer_delays())
			assert.equal(1, q:stats().retried)
		end)

		it("lets a set() during the backoff replace the body, keeping the wait", function()
			set_now("a", { brightness = 50 })
			sends[1].done({ ok = false, code = 429, err = "HTTP 429" })
			q:set("a", { brightness = 70 })
			assert.same({ 500 }, timer_delays(), "the retry timer is not shortened to the debounce")
			c4.fire_timers()
			assert.equal(2, #sends)
			assert.same({ on = { on = true }, dimming = { brightness = 70 } }, sends[2].body)
			assert.equal(1, q:stats().coalesced)
		end)

		it("folds the failed fields under newer ones with the colour-mode rule", function()
			set_now("a", { mirek = 300, brightness = 50 })
			sends[1].done({ ok = false, code = 503, err = "HTTP 503" })
			q:set("a", { x = 0.2, y = 0.6 })
			c4.fire_timers()
			assert.same({
				on = { on = true },
				dimming = { brightness = 50 },
				color = { xy = { x = 0.2, y = 0.6 } },
			}, sends[2].body, "brightness survives the retry, mirek gives way to xy")
		end)

		it("drops the state on another 4xx, logs once and keeps serving the light", function()
			set_now("a", { on = true })
			sends[1].done({ ok = false, code = 404, err = "HTTP 404" })
			assert.same({}, timer_delays(), "no retry")
			assert.equal(1, q:stats().dropped)
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("HTTP 404", 1, true))
			assert.truthy(lines[1]:find("dropping", 1, true))

			set_now("a", { brightness = 20 })
			assert.equal(2, #sends)
		end)

		it("still sends what arrived during a PUT that was dropped", function()
			set_now("a", { on = true })
			q:set("a", { brightness = 20 })
			sends[1].done({ ok = false, code = 400, err = "HTTP 400" })
			assert.equal(2, #sends)
			assert.same({ on = { on = true }, dimming = { brightness = 20 } }, sends[2].body)
		end)

		it("counts sent, retried, dropped and coalesced", function()
			q:set("a", { on = true })
			q:set("a", { brightness = 10 })
			c4.fire_timers()
			sends[1].done({ ok = false, code = 429, err = "HTTP 429" })
			c4.fire_timers()
			sends[2].done({ ok = true, code = 200 })
			set_now("b", { on = true })
			sends[3].done({ ok = false, code = 404, err = "HTTP 404" })
			assert.same({ sent = 3, retried = 1, dropped = 1, coalesced = 1 }, q:stats())
			local stats = q:stats()
			stats.sent = 99
			assert.equal(3, q:stats().sent, "stats() returns a copy")
		end)
	end)

	describe("stop()", function()
		it("cancels every timer and drops pending state", function()
			q:set("a", { on = true })
			q:set("b", { on = true })
			q:stop()
			assert.same({}, timer_delays())
			assert.equal(0, c4.fire_timers())
			assert.equal(0, #sends)
			assert.is_nil(q:pending("a"))
		end)

		it("ignores a late done() and works again afterwards", function()
			set_now("a", { on = true })
			q:set("a", { brightness = 40 })
			q:stop()
			sends[1].done({ ok = true, code = 200 })
			assert.equal(1, #sends, "the stopped generation's done() flushed nothing")

			set_now("a", { brightness = 70 })
			assert.equal(2, #sends)
			assert.same({ on = { on = true }, dimming = { brightness = 70 } }, sends[2].body)
		end)

		it("keeps a stale timer from flushing", function()
			q:set("a", { on = true })
			local timer = c4.active_timers()[1]
			q:stop()
			q:set("a", { brightness = 30 })
			timer.callback(timer, 0) -- as if the controller delivered the cancelled timer
			assert.equal(0, #sends, "only the new generation's timer may flush")
			c4.fire_timers()
			assert.equal(1, #sends)
		end)
	end)

	describe("robustness", function()
		it("survives a send that raises and keeps serving later sets", function()
			local raise = true
			q = commands.new({ send = function(rid, body, done)
				if raise then error("boom") end
				fake_send(rid, body, done)
			end })
			set_now("a", { on = true })
			assert.equal(0, #sends)
			assert.equal(1, q:stats().dropped)
			assert.truthy(last_line():find("raised", 1, true), last_line())
			assert.is_nil(q:pending("a"))

			raise = false
			set_now("a", { brightness = 50 })
			assert.equal(1, #sends)
			assert.same({ on = { on = true }, dimming = { brightness = 50 } }, sends[1].body)
			assert.equal(1, q:stats().sent)
		end)

		it("survives a done() with no result table", function()
			set_now("a", { on = true })
			sends[1].done(nil)
			assert.same({ 500 }, timer_delays(), "treated as a transport failure")
		end)

		it("pending() returns a copy", function()
			assert.is_nil(q:pending("a"))
			q:set("a", { brightness = 50 })
			local p = q:pending("a")
			p.brightness = 1
			assert.same({ brightness = 50, on = true }, q:pending("a"))
		end)
	end)

	-- The background tasks' user gate (bridge/housekeeping.lua,
	-- docs/simplify-research-scheduler.md §3.4): busy while any rid has work
	-- for the bridge, waiting or in flight.
	describe("busy()", function()
		it("is busy from the first set() until the PUT's done()", function()
			assert.is_false(q:busy(), "a new queue is idle")
			q:set("a", { brightness = 40 })
			assert.is_true(q:busy(), "waiting for the debounce")
			c4.fire_timers()
			assert.equal(1, #sends)
			assert.is_nil(q:pending("a"))
			assert.is_true(q:busy(), "the PUT is in flight")
			sends[1].done({ ok = true, code = 200 })
			assert.is_false(q:busy())
		end)

		it("is busy while a change waits behind a PUT in flight, and while a retry or a token wait is armed", function()
			set_now("a", { brightness = 40 })
			q:set("a", { brightness = 60 })
			sends[1].done({ ok = false, code = 503, err = "HTTP 503" })
			assert.same({ 500 }, timer_delays(), "a retry is armed")
			assert.is_true(q:busy(), "the retry")
			c4.fire_timers()
			sends[2].done({ ok = true, code = 200 })
			assert.is_false(q:busy())

			q = commands.new({ send = fake_send, rate_per_sec = 1, burst = 1 })
			set_now("b", { on = true })
			sends[3].done({ ok = true, code = 200 })
			set_now("c", { on = true })
			assert.equal(3, #sends, "the bucket is empty")
			assert.same({ 1000 }, timer_delays(), "a token wait is armed")
			assert.is_true(q:busy(), "the token wait")
		end)

		it("is busy when any one rid has work", function()
			set_now("a", { on = true })
			sends[1].done({ ok = true, code = 200 })
			q:set("b", { on = false })
			assert.is_true(q:busy())
		end)

		it("is idle after stop(), after a final error drops the state, and after a set() that sends nothing", function()
			set_now("a", { on = true })
			q:set("b", { on = true })
			assert.equal(1, #sends)
			q:stop()
			assert.is_false(q:busy(), "stop() forgets pending and in-flight state")

			set_now("a", { on = true })
			sends[2].done({ ok = false, err = "key rejected" })
			assert.is_false(q:busy(), "a final error drops the state")

			set_now("a", { rate = 500 }) -- a lone rate: no body, no PUT
			assert.equal(2, #sends)
			assert.is_false(q:busy())
		end)
	end)

	describe("relative dim (keypad holds)", function()
		it("sends dimming_delta up with the ramp as dynamics, and a bare stop", function()
			set_now("a", { dim = "up", rate = 3000 })
			assert.same({ dimming_delta = { action = "up", brightness_delta = 100 }, dynamics = { duration = 3000 } },
				sends[1].body)
			sends[1].done({ ok = true, code = 200 })
			set_now("a", { dim = "stop", level = 62 })
			assert.same({ dimming_delta = { action = "stop" } }, sends[2].body)
		end)

		it("moves by a given delta for a scene slider, clamped to 0-100", function()
			set_now("g", { dim = "down", delta = 12.345, rate = 500 })
			assert.same({ dimming_delta = { action = "down", brightness_delta = 12.35 }, dynamics = { duration = 500 } },
				sends[1].body)
			sends[1].done({ ok = true, code = 200 })
			set_now("g", { dim = "up", delta = 250 })
			assert.same({ dimming_delta = { action = "up", brightness_delta = 100 } }, sends[2].body)
		end)

		it("lets a dim replace a pending brightness and a brightness replace a pending dim", function()
			q:set("a", { brightness = 40 })
			q:set("a", { dim = "down", rate = 2000 })
			c4.fire_timers()
			assert.same({ dimming_delta = { action = "down", brightness_delta = 100 }, dynamics = { duration = 2000 } },
				sends[1].body)
			sends[1].done({ ok = true, code = 200 })
			q:set("a", { dim = "stop" })
			q:set("a", { brightness = 70 })
			c4.fire_timers()
			assert.same({ on = { on = true }, dimming = { brightness = 70 } }, sends[2].body)
		end)

		it("writes the stop's own level when the bridge refuses the stop", function()
			set_now("a", { dim = "up", rate = 4000 })
			sends[1].done({ ok = true, code = 200 })
			set_now("a", { dim = "stop", level = 55 })
			sends[2].done({ ok = false, code = 400, err = "HTTP 400" })
			assert.equal(3, #sends)
			assert.same({ on = { on = true }, dimming = { brightness = 55 } }, sends[3].body)
			assert.truthy(table.concat(lines, "\n"):find("refused the dim stop; setting 55 %", 1, true))
		end)

		it("estimates from the start level and the elapsed share when the stop carries none", function()
			local t = 0
			q = commands.new({ send = fake_send, now = function() return t end,
				level_of = function() return 20 end })
			set_now("g", { dim = "up", rate = 4000 })
			sends[1].done({ ok = true, code = 200 })
			t = 2000 -- half the ramp: 20 + 50
			set_now("g", { dim = "stop" })
			sends[2].done({ ok = false, code = 400, err = "HTTP 400" })
			assert.same({ on = { on = true }, dimming = { brightness = 70 } }, sends[3].body)
		end)

		it("does nothing more for a refused stop with no level and no start level", function()
			set_now("a", { dim = "down", rate = 1000 })
			sends[1].done({ ok = true, code = 200 })
			set_now("a", { dim = "stop" })
			sends[2].done({ ok = false, code = 400, err = "HTTP 400" })
			assert.equal(2, #sends)
		end)
	end)

	-- docs/zone-light-design.md Decision 9: the grouped_light queue runs at one
	-- PUT a second with a burst of three; the light queue keeps the defaults.
	describe("pacing options", function()
		local function group_queue()
			return commands.new({ send = fake_send, rate_per_sec = 1, burst = 3 })
		end

		-- set(), fire the debounce, and complete the PUT it produced (if any).
		local function send_and_complete(queue, rid, fields)
			queue:set(rid, fields)
			c4.fire_timers()
			if sends[#sends] and not sends[#sends].completed then
				sends[#sends].completed = true
				sends[#sends].done({ ok = true, code = 200 })
			end
		end

		-- Three absolute levels on one rid empty a 1/s, burst-3 bucket; the
		-- fourth is left waiting for a token.
		local function drain_with_drag(queue, rid)
			send_and_complete(queue, rid, { brightness = 10 })
			send_and_complete(queue, rid, { brightness = 20 })
			send_and_complete(queue, rid, { brightness = 30 })
			assert.equal(3, #sends)
			queue:set(rid, { brightness = 40 })
			c4.fire_timers()
			assert.equal(3, #sends, "the bucket is empty")
			assert.same({ 1000 }, timer_delays(), "the fourth level waits a second for a token")
		end

		it("defaults to the module constants, so the light queue is unchanged", function()
			assert.equal(commands.RATE_PER_SEC, q.rate)
			assert.equal(commands.BURST, q.burst)
			assert.equal(10, q.rate)
			assert.equal(10, q.burst)
			assert.equal(10, q.tokens)
		end)

		it("refuses a rate of zero or a burst below one", function()
			assert.has_error(function() commands.new({ send = fake_send, rate_per_sec = 0 }) end)
			assert.has_error(function() commands.new({ send = fake_send, burst = 0 }) end)
		end)

		it("at 1/s with burst 3 sends three at once and the fourth a second later", function()
			q = group_queue()
			for i = 1, 4 do
				q:set("group" .. i, { on = true })
			end
			c4.fire_timers()
			assert.equal(3, #sends)
			assert.same({ 1000 }, timer_delays())
			c4.now_ms = c4.now_ms + 500
			c4.fire_timers()
			assert.equal(3, #sends, "half a token after 500 ms")
			assert.same({ 500 }, timer_delays())
			c4.now_ms = c4.now_ms + 500
			c4.fire_timers()
			assert.equal(4, #sends)
			assert.same({}, timer_delays())
		end)

		it("spaces a slider drag to one PUT a second, the latest level winning", function()
			q = group_queue()
			drain_with_drag(q, "g")
			q:set("g", { brightness = 50 })
			q:set("g", { brightness = 60 })
			assert.same({ 1000 }, timer_delays(), "levels arriving during the wait do not shorten it")
			c4.fire_timers()
			assert.equal(3, #sends, "no time has passed")

			c4.now_ms = c4.now_ms + 1000
			c4.fire_timers()
			assert.equal(4, #sends)
			assert.same({ on = { on = true }, dimming = { brightness = 60 } }, sends[4].body, "the latest level wins")
			assert.equal(2, q:stats().coalesced)
			sends[4].done({ ok = true, code = 200 })

			q:set("g", { brightness = 70 })
			c4.fire_timers()
			assert.equal(4, #sends, "the token just refilled was spent on the 60")
			assert.same({ 1000 }, timer_delays())
			c4.now_ms = c4.now_ms + 1000
			c4.fire_timers()
			assert.equal(5, #sends)
			assert.same({ on = { on = true }, dimming = { brightness = 70 } }, sends[5].body)
		end)

		it("sends the first request after an idle period at once", function()
			q = group_queue()
			drain_with_drag(q, "g")
			c4.now_ms = c4.now_ms + 1000
			c4.fire_timers()
			assert.equal(4, #sends, "the waiting level went out at the refill")
			sends[4].done({ ok = true, code = 200 })
			c4.now_ms = c4.now_ms + 1000
			q:set("g", { brightness = 80 })
			c4.fire_timers()
			assert.equal(5, #sends, "a second of quiet earned a token")
			assert.same({}, timer_delays())
			sends[5].done({ ok = true, code = 200 })
			c4.now_ms = c4.now_ms + 60000
			for i = 1, 3 do
				q:set("zone" .. i, { on = true })
			end
			c4.fire_timers()
			assert.equal(8, #sends, "a full bucket after a long idle: the whole burst goes at once")
		end)

		it("lets a hold's start and stop through at once while a drag waits, and a tap after the hold", function()
			q = group_queue()
			drain_with_drag(q, "a")
			-- 200 ms later a keypad hold starts on another group.
			c4.now_ms = c4.now_ms + 200
			q:set("g", { dim = "up", rate = 3000 })
			c4.fire_timers()
			assert.equal(4, #sends, "the hold's start did not wait for a token")
			assert.equal("g", sends[4].rid)
			assert.same({ dimming_delta = { action = "up", brightness_delta = 100 }, dynamics = { duration = 3000 } },
				sends[4].body)
			assert.same({ 800 }, timer_delays(), "the drag's level still waits for the token it was promised")
			sends[4].done({ ok = true, code = 200 })

			-- The drag's last level goes out at the refill, a second after its previous PUT.
			c4.now_ms = c4.now_ms + 800
			c4.fire_timers()
			assert.equal(5, #sends)
			assert.equal("a", sends[5].rid)
			assert.same({ on = { on = true }, dimming = { brightness = 40 } }, sends[5].body)
			sends[5].done({ ok = true, code = 200 })

			-- The hold is released 2 s after it started: the stop goes at once.
			c4.now_ms = c4.now_ms + 1200
			q:set("g", { dim = "stop", level = 55 })
			c4.fire_timers()
			assert.equal(6, #sends)
			assert.same({ dimming_delta = { action = "stop" } }, sends[6].body)
			sends[6].done({ ok = true, code = 200 })

			-- A tap right after the hold: the hold took no tokens, so the one
			-- the bucket earned since the drag's last PUT is there for the tap.
			c4.now_ms = c4.now_ms + 200
			q:set("g", { on = true, brightness = 100 })
			c4.fire_timers()
			assert.equal(7, #sends, "the tap did not queue behind the drag")
			assert.same({ on = { on = true }, dimming = { brightness = 100 } }, sends[7].body)
			assert.same({}, timer_delays())
		end)

		it("lets a hold on the dragged group itself replace the waiting level and go out at once", function()
			q = group_queue()
			drain_with_drag(q, "g")
			q:set("g", { dim = "down", rate = 2500 })
			assert.same({ commands.DEBOUNCE_MS }, timer_delays(), "the token wait gave way to the debounce")
			c4.fire_timers()
			assert.equal(4, #sends)
			assert.same({ dimming_delta = { action = "down", brightness_delta = 100 }, dynamics = { duration = 2500 } },
				sends[4].body)
			assert.is_nil(q:pending("g"), "the hold superseded the drag's last level")
			sends[4].done({ ok = true, code = 200 })
			q:set("g", { dim = "stop" })
			c4.fire_timers()
			assert.equal(5, #sends)
			assert.same({ dimming_delta = { action = "stop" } }, sends[5].body)
		end)

		it("paces a scene slider's relative moves like a drag, but never its hold or stop", function()
			q = group_queue()
			send_and_complete(q, "s", { dim = "up", delta = 10, rate = 400 })
			send_and_complete(q, "s", { dim = "up", delta = 10, rate = 400 })
			send_and_complete(q, "s", { dim = "down", delta = 5, rate = 400 })
			assert.equal(3, #sends)
			q:set("s", { dim = "down", delta = 7, rate = 400 })
			c4.fire_timers()
			assert.equal(3, #sends, "a fourth relative move waits like any drag")
			assert.same({ 1000 }, timer_delays())
			q:set("s", { dim = "up", delta = 100, rate = 3000 })
			c4.fire_timers()
			assert.equal(4, #sends, "a whole-range dim is a hold: at once")
			assert.same({ dimming_delta = { action = "up", brightness_delta = 100 }, dynamics = { duration = 3000 } },
				sends[4].body)
			sends[4].done({ ok = true, code = 200 })
			q:set("s", { dim = "stop" })
			c4.fire_timers()
			assert.equal(5, #sends, "a stop is at once")
		end)

		it("keeps a retry's backoff even for a stop (the bridge was refusing)", function()
			q = group_queue()
			set_now("g", { brightness = 50 })
			sends[1].done({ ok = false, code = 429, err = "HTTP 429" })
			assert.same({ 500 }, timer_delays())
			q:set("g", { dim = "stop", level = 50 })
			assert.same({ 500 }, timer_delays(), "the retry timer is not shortened")
			c4.fire_timers()
			assert.equal(2, #sends)
			assert.same({ dimming_delta = { action = "stop" } }, sends[2].body, "the stop replaced the failed level")
		end)

		it("urgent() names a hold's start and stop, not a scene slider's move or a level", function()
			assert.is_true(commands.urgent({ dim = "stop" }))
			assert.is_true(commands.urgent({ dim = "up" }))
			assert.is_true(commands.urgent({ dim = "down", delta = 100 }))
			assert.is_false(commands.urgent({ dim = "up", delta = 12.5 }))
			assert.is_false(commands.urgent({ brightness = 100, on = true }))
			assert.is_false(commands.urgent(nil))
		end)
	end)

	-- Issue #43: "not paired" and "key rejected" are never retried; any other
	-- retriable failure is retried for at most commands.MAX_AGE_S from the
	-- pending state's last update, then dropped with one warning. The light
	-- queue and the grouped_light queue (driver.lua new_group_queue: one PUT a
	-- second, a burst of three) follow the same rules.
	describe("retry limits", function()
		local function warnings()
			local out = {}
			for _, line in ipairs(lines) do
				if line:find("^%[WARN%]") then out[#out + 1] = line end
			end
			return out
		end

		before_each(function()
			log.set_debug(false)
		end)

		it("exports a 30 s age limit", function()
			assert.equal(30, commands.MAX_AGE_S)
		end)

		for _, kind in ipairs({
			{ name = "light queue", opts = {}, label = "light" },
			{ name = "group queue", opts = { rate_per_sec = 1, burst = 3, label = "grouped_light" }, label = "grouped_light" },
		}) do
			describe(kind.name, function()
				before_each(function()
					local opts = { send = fake_send }
					for k, v in pairs(kind.opts) do opts[k] = v end
					q = commands.new(opts)
				end)

				it("does not retry 'not paired' and drops what arrived meanwhile", function()
					set_now("g", { brightness = 50 })
					q:set("g", { brightness = 60 }) -- arrives while the PUT is in flight
					sends[1].done({ ok = false, err = "not paired" })
					assert.same({}, timer_delays(), "no retry, no debounce left")
					assert.is_nil(q:pending("g"), "the newer state is dropped too")
					c4.now_ms = c4.now_ms + 60000
					c4.fire_timers()
					assert.equal(1, #sends)
					assert.equal(1, q:stats().dropped)
					assert.equal(0, q:stats().retried)
					local warned = warnings()
					assert.equal(1, #warned)
					assert.truthy(warned[1]:find(kind.label .. " g: not paired", 1, true), warned[1])
				end)

				it("does not retry 'key rejected', and warns once per rid and condition", function()
					set_now("g", { on = true })
					sends[1].done({ ok = false, err = "key rejected", code = 403 })
					assert.same({}, timer_delays())
					set_now("g", { on = false })
					sends[2].done({ ok = false, err = "key rejected", code = 403 })
					assert.same({}, timer_delays())
					assert.equal(2, q:stats().dropped)
					assert.equal(1, #warnings(), "a slider dragged meanwhile does not warn at every step")
					assert.truthy(warnings()[1]:find("key rejected", 1, true))

					-- Once commands go through again, the next refusal warns again
					-- (a second apart, so the group queue's bucket has a token).
					c4.now_ms = c4.now_ms + 1000
					set_now("g", { on = true })
					sends[3].done({ ok = true, code = 200 })
					c4.now_ms = c4.now_ms + 1000
					set_now("g", { on = false })
					sends[4].done({ ok = false, err = "key rejected", code = 403 })
					assert.equal(2, #warnings())
				end)

				it("writes no fallback level for a dim stop whose key was refused", function()
					set_now("g", { dim = "up", rate = 3000 })
					sends[1].done({ ok = true, code = 200 })
					set_now("g", { dim = "stop", level = 40 })
					sends[2].done({ ok = false, err = "key rejected", code = 401 })
					assert.equal(2, #sends, "nothing could go through")
					assert.same({}, timer_delays())
				end)

				it("retries another failure only within 30 s of the last update, then drops it once", function()
					set_now("g", { brightness = 50 })
					local body = sends[1].body
					sends[1].done({ ok = false, err = "transfer failed (28): Timeout was reached" })
					assert.same({ 500 }, timer_delays(), "retried while young")
					c4.now_ms = c4.now_ms + 500
					c4.fire_timers()
					assert.equal(2, #sends)
					assert.same(body, sends[2].body)

					-- The bridge stays away; 29.5 s after the update the next retry
					-- (1 s later) would go out after the limit.
					c4.now_ms = c4.now_ms + 29000
					sends[2].done({ ok = false, err = "transfer failed (7): Failed to connect" })
					assert.same({}, timer_delays(), "no retry beyond the limit")
					assert.is_nil(q:pending("g"))
					assert.equal(1, q:stats().dropped)
					local warned = warnings()
					local last = warned[#warned]
					assert.truthy(last:find(kind.label .. " g: transfer failed (7): Failed to connect", 1, true), last)
					assert.truthy(last:find("last changed 30 s ago", 1, true), last)
					assert.equal(1, #warned - 1, "one retry warning before it, one drop warning")

					-- Nothing stale is sent when the bridge returns; a new change is.
					c4.now_ms = c4.now_ms + 60000
					c4.fire_timers()
					assert.equal(2, #sends)
					set_now("g", { brightness = 70 })
					assert.equal(3, #sends)
					assert.same({ on = { on = true }, dimming = { brightness = 70 } }, sends[3].body)
				end)

				it("counts the 30 s from the latest change, not from the first one or the first failure", function()
					set_now("g", { brightness = 50 })
					sends[1].done({ ok = false, code = 503, err = "HTTP 503" })
					c4.now_ms = c4.now_ms + 25000
					q:set("g", { brightness = 80 }) -- the owner moves the slider again, into the retry state
					assert.same({ 500 }, timer_delays(), "the retry timer is kept")
					c4.fire_timers()
					assert.equal(2, #sends)
					assert.same({ on = { on = true }, dimming = { brightness = 80 } }, sends[2].body)
					sends[2].done({ ok = false, code = 503, err = "HTTP 503" })
					assert.same({ 1000 }, timer_delays(), "young again: retried")

					-- 31 s after the first change, 6 s after the latest: still retried.
					c4.now_ms = c4.now_ms + 6000
					c4.fire_timers()
					assert.equal(3, #sends)
					sends[3].done({ ok = false, code = 503, err = "HTTP 503" })
					assert.same({ 2000 }, timer_delays())
					assert.equal(0, q:stats().dropped)
				end)
			end)
		end
	end)

	-- #421 (docs/tap-stop-design.md §4.3): a keypad tap's start and a tap stop
	-- sent as a level arrive marked urgent (D12), and a stop that finds its
	-- ramp's start still waiting in the queue turns both into the stop's level
	-- (D13). The light queue and the grouped_light queue (driver.lua
	-- new_group_queue) are the same code, and both are run.
	describe("tap starts and stops (#421)", function()
		local OK = { ok = true, code = 200 }

		local function logged(text)
			for _, line in ipairs(lines) do
				if line:find(text, 1, true) then return true end
			end
			return false
		end

		before_each(function()
			log.set_debug(true)
		end)

		after_each(function()
			log.set_debug(false)
		end)

		it("urgent() names a state marked urgent", function()
			assert.is_true(commands.urgent({ on = true, brightness = 100, rate = 3000, urgent = true }))
			assert.is_false(commands.urgent({ on = true, brightness = 100, rate = 3000 }))
		end)

		it("never puts urgent in a body", function()
			assert.same({ on = { on = true }, dimming = { brightness = 100 }, dynamics = { duration = 3000 } },
				commands.body({ on = true, brightness = 100, rate = 3000, urgent = true }))
			assert.same({ on = { on = true }, dimming = { brightness = 42 } },
				commands.body({ on = true, brightness = 42, rate = 0, urgent = true }))
		end)

		for _, kind in ipairs({
			{ name = "light queue", opts = {} },
			{ name = "group queue", opts = { rate_per_sec = 1, burst = 3, label = "grouped_light" } },
		}) do
			describe(kind.name, function()
				before_each(function()
					local opts = { send = fake_send }
					for k, v in pairs(kind.opts) do opts[k] = v end
					q = commands.new(opts)
				end)

				local function complete_all()
					for _, s in ipairs(sends) do
						if not s.completed then
							s.completed = true
							s.done(OK)
						end
					end
				end

				local function last_to(rid)
					for i = #sends, 1, -1 do
						if sends[i].rid == rid then return sends[i] end
					end
				end

				-- A drag empties the bucket: one level on each of `burst` rids,
				-- then one more that waits for a token.
				local function drain()
					for i = 1, q.burst do
						q:set("d" .. i, { brightness = 10 * i })
					end
					c4.fire_timers()
					complete_all()
					assert.equal(q.burst, #sends)
					q:set("drag", { brightness = 40 })
					c4.fire_timers()
					assert.equal(q.burst, #sends, "the bucket is empty")
					assert.same({ math.ceil(1000 / q.rate) }, timer_delays(), "the drag's level waits for a token")
				end

				it("sends an urgent start at once past an empty bucket and takes no token (D12)", function()
					drain()
					q:set("t", { on = true, brightness = 100, rate = 3000, urgent = true })
					c4.fire_timers()
					assert.equal(q.burst + 1, #sends, "the tap's start did not wait")
					assert.equal("t", sends[#sends].rid)
					assert.same({ on = { on = true }, dimming = { brightness = 100 }, dynamics = { duration = 3000 } },
						sends[#sends].body, "no urgent in the PUT")
					assert.equal(0, q.tokens, "no token taken")
					assert.same({ math.ceil(1000 / q.rate) }, timer_delays(), "the drag still waits for its token")
				end)

				it("lets an urgent set on a state waiting for a token send it at once (D12)", function()
					drain()
					q:set("drag", { on = true, brightness = 100, rate = 3000, urgent = true })
					assert.same({ commands.DEBOUNCE_MS }, timer_delays(), "the token wait gave way to the debounce")
					c4.fire_timers()
					assert.equal(q.burst + 1, #sends)
					assert.same({ on = { on = true }, dimming = { brightness = 100 }, dynamics = { duration = 3000 } },
						sends[#sends].body)
					assert.same({}, timer_delays())
				end)

				it("keeps urgent through a merge until the PUT is sent (D12)", function()
					q:set("t", { on = true, brightness = 100, rate = 3000, urgent = true })
					q:set("t", { x = 0.3, y = 0.4 })
					assert.is_true(q:pending("t").urgent, "a later part without urgent keeps it")
					q:set("u", { brightness = 50 })
					q:set("u", { mirek = 300, urgent = "true" })
					assert.is_true(q:pending("u").urgent, "a later urgent part makes the state urgent, string form too")
					assert.is_true(commands.urgent(q:pending("u")))
					c4.fire_timers()
					assert.equal(2, #sends)
					assert.same({ on = { on = true }, dimming = { brightness = 100 }, color = { xy = { x = 0.3, y = 0.4 } },
						dynamics = { duration = 3000 } }, last_to("t").body)
					assert.same({ on = { on = true }, dimming = { brightness = 50 }, color_temperature = { mirek = 300 } },
						last_to("u").body)
					complete_all()
					q:set("t", { brightness = 20 })
					assert.is_nil(q:pending("t").urgent, "the next state starts without it")
				end)

				it("turns a stop with a level on an unsent ramp into that level, rate 0, urgent (D13)", function()
					q:set("t", { on = true, brightness = 100, rate = 3000, urgent = true })
					q:set("t", { dim = "stop", level = 42 })
					assert.same({ on = true, brightness = 42, rate = 0, urgent = true }, q:pending("t"))
					c4.fire_timers()
					assert.equal(1, #sends, "one PUT: the start never went out")
					assert.same({ on = { on = true }, dimming = { brightness = 42 } }, sends[1].body,
						"an absolute level, no duration, no dimming_delta")
					assert.is_true(logged("a stop replaced a start not yet sent; setting 42 % at once (#421 D13)"))
					complete_all()

					q:set("o", { brightness = 0, rate = 2000, urgent = true })
					q:set("o", { dim = "stop", level = 30 })
					assert.same({ on = true, brightness = 30, rate = 0, urgent = true }, q:pending("o"),
						"a ramp to off stopped above 0 stays on")
					q:set("f", { on = true, rate = 1500 })
					q:set("f", { dim = "stop", level = 0, rate = 700 })
					assert.same({ on = false, brightness = 0, rate = 0, urgent = true }, q:pending("f"),
						"a level of 0 is off, and the stop's own rate is ignored")
				end)

				it("sends at once a stop that replaced a start waiting for a token (D13)", function()
					drain()
					q:set("r", { on = true, brightness = 80, rate = 4000 }) -- a timed target from programming
					c4.fire_timers()
					assert.equal(q.burst, #sends, "the start waits for a token like any level")
					q:set("r", { dim = "stop", level = 55 })
					c4.fire_timers()
					assert.equal(q.burst + 1, #sends)
					assert.same({ on = { on = true }, dimming = { brightness = 55 } }, last_to("r").body)
					assert.is_nil(q:pending("r"))
				end)

				it("drops an unsent ramp for a stop without a level, and sends nothing for it (D13)", function()
					q:set("t", { on = true, brightness = 100, rate = 3000, urgent = true })
					q:set("t", { dim = "stop" })
					assert.same({ urgent = true }, q:pending("t"))
					q:set("o", { on = false, rate = 2000 })
					q:set("o", { dim = "stop" })
					c4.fire_timers()
					assert.equal(0, #sends)
					assert.is_nil(q:pending("t"))
					assert.is_false(q:busy())
					assert.is_true(logged("a stop replaced a start not yet sent; setting nothing at once"))
				end)

				it("keeps a colour pending beside the unsent ramp (D13)", function()
					q:set("c", { brightness = 80, x = 0.3, y = 0.4, rate = 3000, urgent = true })
					q:set("c", { dim = "stop", level = 50 })
					c4.fire_timers()
					assert.same({ on = { on = true }, dimming = { brightness = 50 }, color = { xy = { x = 0.3, y = 0.4 } } },
						sends[1].body)
					complete_all()
					q:set("m", { on = true, mirek = 300, rate = 3000, urgent = true })
					q:set("m", { dim = "stop" })
					c4.fire_timers()
					assert.equal(2, #sends)
					assert.same({ color_temperature = { mirek = 300 } }, sends[2].body,
						"without a level only the colour goes")
				end)

				it("keeps a stop that comes after the start went out a dimming_delta stop, with its level fallback",
					function()
						set_now("t", { on = true, brightness = 100, rate = 3000, urgent = true })
						assert.equal(1, #sends)
						-- In flight: the stop waits behind the start's PUT.
						q:set("t", { dim = "stop", level = 37 })
						assert.same({ dim = "stop", level = 37 }, q:pending("t"))
						c4.fire_timers()
						assert.equal(1, #sends, "one PUT in flight per resource")
						sends[1].done(OK)
						assert.equal(2, #sends)
						assert.same({ dimming_delta = { action = "stop" } }, sends[2].body)
						-- Hue refuses the stop: its level goes instead.
						sends[2].done({ ok = false, code = 400, err = "HTTP 400" })
						assert.equal(3, #sends)
						assert.same({ on = { on = true }, dimming = { brightness = 37 } }, sends[3].body)
						sends[3].done(OK)

						-- Done: the next tap's start has been answered when its stop comes.
						set_now("t", { brightness = 0, rate = 2000, urgent = true })
						sends[4].done(OK)
						set_now("t", { dim = "stop", level = 12 })
						assert.equal(5, #sends)
						assert.same({ dimming_delta = { action = "stop" } }, sends[5].body)
						assert.is_false(logged("#421 D13"))
					end)

				it("turns a stop that waited behind a start that failed into its level for the retry (D13)", function()
					set_now("t", { on = true, brightness = 100, rate = 3000, urgent = true })
					q:set("t", { dim = "stop", level = 64 })
					c4.fire_timers()
					sends[1].done({ ok = false, code = 503, err = "HTTP 503" })
					assert.same({ on = true, brightness = 64, rate = 0, urgent = true }, q:pending("t"))
					assert.same({ commands.BACKOFF_MS }, timer_delays(), "the retry's backoff is kept")
					c4.fire_timers()
					assert.equal(2, #sends)
					assert.same({ on = { on = true }, dimming = { brightness = 64 } }, sends[2].body)
				end)

				it("leaves a stop on a pending hold start or an instant level as it was", function()
					q:set("h", { dim = "up", rate = 5000 })
					q:set("h", { dim = "stop", level = 20 })
					q:set("i", { brightness = 60 })
					q:set("i", { dim = "stop", level = 20 })
					c4.fire_timers()
					assert.same({ dimming_delta = { action = "stop" } }, last_to("h").body)
					assert.same({ dimming_delta = { action = "stop" } }, last_to("i").body)
				end)
			end)
		end
	end)

	-- #428 D8 (docs/offline-design.md §6.6): every PUT that fails is reported
	-- through on_undelivered, once per failed attempt, after the queue has
	-- settled its own state; never for an ok answer. Both queues are the same
	-- code (driver.lua new_queue, new_group_queue), and both are run.
	describe("on_undelivered (#428 D8)", function()
		local OK = { ok = true, code = 200 }
		local told

		for _, kind in ipairs({
			{ name = "light queue", opts = {} },
			{ name = "group queue", opts = { rate_per_sec = 1, burst = 3, label = "grouped_light" } },
		}) do
			describe(kind.name, function()
				before_each(function()
					told = {}
					local opts = { send = fake_send, on_undelivered = function(rid, err)
						told[#told + 1] = { rid = rid, err = err, pending = q:pending(rid), timers = timer_delays() }
					end }
					for k, v in pairs(kind.opts) do opts[k] = v end
					q = commands.new(opts)
				end)

				it("is never called for an ok answer", function()
					set_now("a", { brightness = 50 })
					sends[1].done(OK)
					assert.same({}, told)
				end)

				it("is called at each failed attempt that is retried, with the state folded back first", function()
					set_now("a", { brightness = 50 })
					sends[1].done({ ok = false, err = "bridge identity not verified yet" })
					assert.equal(1, #told)
					assert.equal("a", told[1].rid)
					assert.equal("bridge identity not verified yet", told[1].err)
					assert.same({ brightness = 50, on = true }, told[1].pending, "the retry's state is in place")
					assert.same({ commands.BACKOFF_MS }, told[1].timers, "and its timer armed")
					c4.now_ms = c4.now_ms + commands.BACKOFF_MS
					c4.fire_timers()
					sends[2].done({ ok = false, code = 503, err = "HTTP 503" })
					assert.equal(2, #told, "the second failure is answered too")
					assert.equal("HTTP 503", told[2].err)
					c4.now_ms = c4.now_ms + 2 * commands.BACKOFF_MS
					c4.fire_timers()
					sends[3].done({ ok = false, code = 429, err = "HTTP 429" })
					assert.equal(3, #told)
					c4.now_ms = c4.now_ms + 4 * commands.BACKOFF_MS
					c4.fire_timers()
					sends[4].done(OK)
					assert.equal(3, #told, "the retry that lands is not")
				end)

				it("is called once at the drop at the age limit, with nothing left pending", function()
					set_now("a", { brightness = 50 })
					sends[1].done({ ok = false, err = "transfer failed (28): Timeout was reached" })
					c4.now_ms = c4.now_ms + 30000
					c4.fire_timers()
					sends[2].done({ ok = false, err = "transfer failed (7): Failed to connect" })
					assert.equal(2, #told, "the retry and the drop")
					assert.equal("transfer failed (7): Failed to connect", told[2].err)
					assert.is_nil(told[2].pending, "dropped before the owner hears")
					assert.same({}, told[2].timers)
				end)

				for _, err in ipairs({ "not paired", "key rejected", "TLS check failed" }) do
					it("is called once for the final refusal '" .. err .. "', every time it comes", function()
						set_now("a", { on = true })
						sends[1].done({ ok = false, err = err, code = err == "key rejected" and 403 or nil })
						assert.equal(1, #told)
						assert.equal(err, told[1].err)
						assert.is_nil(told[1].pending)
						c4.now_ms = c4.now_ms + 1000
						set_now("a", { on = false })
						sends[2].done({ ok = false, err = err })
						assert.equal(2, #told, "warned once, but each refused command is answered")
					end)
				end

				it("is called once for another 4xx", function()
					set_now("a", { brightness = 50 })
					sends[1].done({ ok = false, code = 404, err = "HTTP 404" })
					assert.equal(1, #told)
					assert.equal("HTTP 404", told[1].err)
					assert.same({}, timer_delays(), "no retry")
				end)

				it("is called before a change that arrived during the failed PUT goes out", function()
					set_now("a", { brightness = 50 })
					q:set("a", { brightness = 60 })
					sends[1].done({ ok = false, code = 400, err = "HTTP 400" })
					assert.equal(1, #told)
					assert.same({ brightness = 60, on = true }, told[1].pending, "the newer change was still waiting")
					assert.equal(2, #sends, "and goes out after")
					assert.same({ on = { on = true }, dimming = { brightness = 60 } }, sends[2].body)
				end)

				it("is called for a refused dim stop, and its level fallback still goes out", function()
					set_now("a", { dim = "up", rate = 3000 })
					sends[1].done(OK)
					c4.now_ms = c4.now_ms + 1000
					set_now("a", { dim = "stop", level = 40 })
					sends[2].done({ ok = false, code = 400, err = "HTTP 400" })
					assert.equal(1, #told)
					assert.equal(3, #sends)
					assert.same({ on = { on = true }, dimming = { brightness = 40 } }, sends[3].body)
				end)

				it("is called when a stop that waited behind a failed tap start becomes its level (D13)", function()
					set_now("t", { on = true, brightness = 100, rate = 3000, urgent = true })
					q:set("t", { dim = "stop", level = 64 })
					c4.fire_timers()
					sends[1].done({ ok = false, code = 503, err = "HTTP 503" })
					assert.equal(1, #told)
					assert.same({ on = true, brightness = 64, rate = 0, urgent = true }, told[1].pending,
						"the D13 merge is unchanged")
					c4.fire_timers()
					assert.same({ on = { on = true }, dimming = { brightness = 64 } }, sends[2].body)
				end)

				it("is called when a send raises", function()
					q = commands.new({ send = function() error("boom") end, on_undelivered = function(rid, err)
						told[#told + 1] = { rid = rid, err = err }
					end })
					set_now("a", { on = true })
					assert.equal(1, #told)
					assert.equal("a", told[1].rid)
					assert.truthy(told[1].err:find("boom", 1, true), told[1].err)
				end)

				it("is not called again when a send answered through done() before it raised", function()
					q = commands.new({ send = function(_, _, done)
						done({ ok = false, code = 400, err = "HTTP 400" })
						error("boom")
					end, on_undelivered = function(rid, err)
						told[#told + 1] = { rid = rid, err = err }
					end })
					set_now("a", { on = true })
					assert.equal(1, #told)
					assert.equal("HTTP 400", told[1].err)
				end)

				it("is not called for a late done() after stop()", function()
					set_now("a", { on = true })
					q:stop()
					sends[1].done({ ok = false, code = 503, err = "HTTP 503" })
					assert.same({}, told)
				end)

				it("does not break the queue when the callback raises", function()
					local calls = 0
					local opts = { send = fake_send, on_undelivered = function()
						calls = calls + 1
						error("callback boom")
					end }
					for k, v in pairs(kind.opts) do opts[k] = v end
					q = commands.new(opts)
					set_now("a", { brightness = 50 })
					sends[1].done({ ok = false, code = 503, err = "HTTP 503" })
					assert.equal(1, calls)
					assert.truthy(last_line():find("on_undelivered for a failed: ", 1, true), last_line())
					assert.same({ commands.BACKOFF_MS }, timer_delays(), "the retry is still armed")
					c4.now_ms = c4.now_ms + commands.BACKOFF_MS
					c4.fire_timers()
					assert.equal(2, #sends)
					sends[2].done(OK)
					c4.now_ms = c4.now_ms + 1000
					set_now("b", { on = true })
					assert.equal(3, #sends, "later sets are served")
				end)

				it("is optional: a queue without it behaves as before", function()
					q = commands.new({ send = fake_send })
					set_now("a", { brightness = 50 })
					sends[1].done({ ok = false, code = 404, err = "HTTP 404" })
					assert.is_nil(q:pending("a"))
				end)
			end)
		end
	end)

	-- #435 (docs/load-groups-design.md §6.8): what bridge/load_groups.lua reads
	-- and sets. idle(rid) and token_ready() let a load group's batch send a
	-- whole Hue room or zone as one grouped_light request only when nothing
	-- older could land after it (D8); `paced` makes a light dim past the
	-- batch's tenth lamp take the bucket's tokens instead of jumping it (D9,
	-- D10). The light queue and the grouped_light queue are the same code,
	-- and both are run.
	describe("load groups (#435)", function()
		local OK = { ok = true, code = 200 }

		it("urgent() is false for a paced state, a hold's start and stop and an urgent state included (D9)", function()
			assert.is_false(commands.urgent({ dim = "up", rate = 3000, paced = true }))
			assert.is_false(commands.urgent({ dim = "down", delta = 100, rate = 3000, paced = true }))
			assert.is_false(commands.urgent({ dim = "stop", level = 40, paced = true }))
			assert.is_false(commands.urgent({ on = true, brightness = 55, rate = 0, urgent = true, paced = true }))
			assert.is_true(commands.urgent({ dim = "up", rate = 3000 }), "without paced a hold is urgent as before")
			assert.is_true(commands.urgent({ dim = "stop", paced = false }), "only paced = true paces")
		end)

		it("never puts paced in a body", function()
			assert.same({ dimming_delta = { action = "up", brightness_delta = 100 }, dynamics = { duration = 3000 } },
				commands.body({ dim = "up", rate = 3000, paced = true }))
			assert.same({ dimming_delta = { action = "stop" } }, commands.body({ dim = "stop", level = 40, paced = true }))
			assert.same({ on = { on = true }, dimming = { brightness = 55 } },
				commands.body({ on = true, brightness = 55, rate = 0, urgent = true, paced = true }))
		end)

		-- D9 over 25 lamps on the light queue: the first ten holds are urgent,
		-- the other fifteen are paced. With a full bucket ten of those go at
		-- once on its tokens and five follow one per 100 ms; the stops leave
		-- in the same order and at the same spacing, so every lamp ramps for
		-- exactly as long as the button was held.
		it("paces a load group's hold past the tenth lamp through the bucket, stops in the order of the starts (D9)",
			function()
				local at = {}
				q = commands.new({ send = function(rid, body, done)
					table.insert(sends, { rid = rid, body = body, done = done, at = c4.now_ms })
				end })
				local function hold(fields_of)
					for i = 1, 25 do
						local fields = fields_of(i)
						if i > 10 then fields.paced = true end
						q:set("l" .. i, fields)
					end
				end
				local t0 = c4.now_ms
				hold(function() return { dim = "up", rate = 5000 } end)
				c4.advance(commands.DEBOUNCE_MS)
				assert.equal(20, #sends, "ten urgent starts and ten on the bucket's tokens")
				assert.equal(0, q.tokens)
				c4.advance(500)
				assert.equal(25, #sends, "the last five one per 100 ms")
				for i, s in ipairs(sends) do
					assert.equal("l" .. i, s.rid, "starts in arrival order")
					assert.same({ dimming_delta = { action = "up", brightness_delta = 100 }, dynamics = { duration = 5000 } },
						s.body, "no paced in the PUT")
					local expected = t0 + commands.DEBOUNCE_MS + (i > 20 and 100 * (i - 20) or 0)
					assert.equal(expected, s.at, "start of l" .. i)
					at[s.rid] = s.at
					s.done(OK)
				end

				-- The release, 2 s after the starts went out: the bucket is full again.
				c4.now_ms = t0 + 2000
				hold(function(i) return { dim = "stop", level = 40 + i } end)
				c4.advance(commands.DEBOUNCE_MS)
				assert.equal(45, #sends)
				c4.advance(500)
				assert.equal(50, #sends)
				for i = 26, 50 do
					local s = sends[i]
					assert.equal("l" .. (i - 25), s.rid, "stops in the order of the starts")
					assert.same({ dimming_delta = { action = "stop" } }, s.body)
					assert.equal(2000, s.at - at[s.rid], "l" .. (i - 25) .. " ramped as long as the button was held")
				end
				assert.same({}, timer_delays())
			end)

		for _, kind in ipairs({
			{ name = "light queue", opts = {} },
			{ name = "group queue", opts = { rate_per_sec = 1, burst = 3, label = "grouped_light" } },
		}) do
			describe(kind.name, function()
				local period -- ms the bucket takes to earn one token

				before_each(function()
					local opts = { send = fake_send }
					for k, v in pairs(kind.opts) do opts[k] = v end
					q = commands.new(opts)
					period = math.ceil(1000 / q.rate)
				end)

				local function complete_all()
					for _, s in ipairs(sends) do
						if not s.completed then
							s.completed = true
							s.done(OK)
						end
					end
				end

				-- One level on each of `burst` rids, all answered: the bucket is
				-- empty and nothing is armed.
				local function empty_bucket()
					for i = 1, q.burst do
						q:set("d" .. i, { brightness = 10 * i })
					end
					c4.fire_timers()
					complete_all()
					assert.equal(q.burst, #sends)
					assert.equal(0, q.tokens)
					assert.same({}, timer_delays())
				end

				describe("idle()", function()
					it("is true for a rid the queue has never seen, and once its PUT has returned", function()
						assert.is_true(q:idle("never"))
						set_now("a", { brightness = 50 })
						sends[1].done(OK)
						assert.is_true(q:idle("a"))
					end)

					it("is false while a state waits for its debounce or a token, and while its PUT is in flight", function()
						q:set("a", { brightness = 50 })
						assert.is_false(q:idle("a"), "pending, debounce armed")
						c4.fire_timers()
						assert.is_nil(q:pending("a"))
						assert.is_false(q:idle("a"), "in flight")
						sends[1].done(OK)
						assert.is_true(q:idle("a"))

						sends = {}
						q = commands.new({ send = fake_send, rate_per_sec = q.rate, burst = q.burst })
						empty_bucket()
						q:set("w", { brightness = 40 })
						c4.fire_timers()
						assert.same({ period }, timer_delays(), "waiting for a token")
						assert.is_false(q:idle("w"))
						assert.is_true(q:idle("d1"), "a rid whose PUT returned is idle meanwhile")
						c4.advance(period)
						assert.is_false(q:idle("w"), "sent, in flight")
						complete_all()
						assert.is_true(q:idle("w"))
					end)

					it("is false while a change waits behind a PUT in flight, until that change's PUT returns", function()
						set_now("a", { brightness = 50 })
						q:set("a", { brightness = 60 })
						c4.fire_timers()
						assert.same({}, timer_delays(), "the debounce fired; the change waits for the PUT")
						assert.is_false(q:idle("a"))
						sends[1].done(OK)
						assert.equal(2, #sends)
						assert.is_false(q:idle("a"), "the change is in flight now")
						sends[2].done(OK)
						assert.is_true(q:idle("a"))
					end)

					it("is false while a retry's backoff is armed, and true once the retry lands", function()
						set_now("a", { brightness = 50 })
						sends[1].done({ ok = false, code = 503, err = "HTTP 503" })
						assert.same({ commands.BACKOFF_MS }, timer_delays())
						assert.is_false(q:idle("a"))
						c4.advance(commands.BACKOFF_MS)
						assert.equal(2, #sends)
						assert.is_false(q:idle("a"))
						sends[2].done(OK)
						assert.is_true(q:idle("a"))
					end)

					it("is true after stop(), after a final refusal drops the state, and after a flush that sends nothing",
						function()
							q:set("e", { rate = 400 })
							c4.fire_timers()
							assert.equal(0, #sends)
							assert.is_true(q:idle("e"), "a lone rate is nothing to send")

							set_now("c", { on = true })
							q:set("c", { brightness = 30 })
							sends[#sends].done({ ok = false, err = "key rejected", code = 403 })
							assert.is_true(q:idle("c"), "the change that arrived meanwhile went too")

							q:set("a", { brightness = 50 })
							set_now("b", { on = true })
							q:stop()
							assert.is_true(q:idle("a"))
							assert.is_true(q:idle("b"))
						end)

					it("looks at one rid only", function()
						set_now("a", { brightness = 50 })
						q:set("b", { brightness = 20 })
						assert.is_false(q:idle("a"))
						assert.is_false(q:idle("b"))
						assert.is_true(q:idle("c"))
					end)
				end)

				describe("token_ready()", function()
					it("is true on a full bucket and takes no token", function()
						for _ = 1, 5 do
							assert.is_true(q:token_ready())
						end
						assert.equal(q.burst, q.tokens)
						for i = 1, q.burst do
							q:set("g" .. i, { on = true })
						end
						c4.fire_timers()
						assert.equal(q.burst, #sends, "the whole burst still goes at once")
						assert.is_false(q:token_ready())
					end)

					it("is false on an empty bucket until a whole token has refilled, and refills without taking it",
						function()
							empty_bucket()
							assert.is_false(q:token_ready())
							c4.now_ms = c4.now_ms + period / 2
							assert.is_false(q:token_ready())
							assert.equal(0.5, q.tokens, "half a token credited")
							c4.now_ms = c4.now_ms + period / 2
							assert.is_true(q:token_ready())
							assert.is_true(q:token_ready())
							assert.equal(1, q.tokens, "asking twice took nothing")
							q:set("x", { brightness = 5 })
							c4.fire_timers()
							assert.equal(q.burst + 1, #sends, "the token it saw is there for the next level")
							assert.equal(0, q.tokens)
							assert.is_false(q:token_ready())
						end)

					it("does not count urgent requests, which take no token", function()
						empty_bucket()
						q:set("t", { on = true, brightness = 100, rate = 3000, urgent = true })
						q:set("h", { dim = "up", rate = 3000 })
						c4.fire_timers()
						assert.equal(q.burst + 2, #sends, "the tap and the hold went at once")
						assert.is_false(q:token_ready())
						assert.equal(0, q.tokens)
					end)

					it("leaves a token wait as it was", function()
						empty_bucket()
						q:set("w", { brightness = 40 })
						c4.fire_timers()
						assert.same({ period }, timer_delays())
						assert.is_false(q:token_ready())
						assert.same({ period }, timer_delays())
						c4.advance(period)
						assert.equal(q.burst + 1, #sends, "the level went out at the refill")
					end)
				end)

				describe("paced", function()
					it("sends a paced dim past an empty bucket only when a token is free, and takes it (D9)", function()
						empty_bucket()
						q:set("p", { dim = "up", rate = 3000, paced = true })
						assert.is_true(q:pending("p").paced)
						c4.fire_timers()
						assert.equal(q.burst, #sends, "a paced hold waits like a drag")
						assert.same({ period }, timer_delays())
						c4.advance(period - 1)
						assert.equal(q.burst, #sends)
						c4.advance(1)
						assert.equal(q.burst + 1, #sends)
						assert.same({ dimming_delta = { action = "up", brightness_delta = 100 }, dynamics = { duration = 3000 } },
							sends[#sends].body, "no paced in the PUT")
						assert.equal(0, q.tokens, "it took the token")

						complete_all()
						q:set("p", { dim = "stop", level = 30, paced = true })
						c4.fire_timers()
						assert.equal(q.burst + 1, #sends, "a paced stop waits its turn too")
						c4.advance(period)
						assert.same({ dimming_delta = { action = "stop" } }, sends[#sends].body)
					end)

					it("goes at once while the bucket has a token, as any request then does", function()
						set_now("p", { dim = "down", rate = 2000, paced = true })
						assert.equal(1, #sends)
						assert.equal(q.burst - 1, q.tokens, "but it took a token")
					end)

					it("keeps a token wait when a paced hold replaces the waiting state (D9)", function()
						empty_bucket()
						q:set("g", { brightness = 40 })
						c4.fire_timers()
						assert.same({ period }, timer_delays())
						q:set("g", { dim = "down", rate = 2500, paced = true })
						assert.same({ period }, timer_delays(), "not the debounce an unpaced hold would arm")
						c4.advance(period)
						assert.equal(q.burst + 1, #sends)
						assert.same({ dimming_delta = { action = "down", brightness_delta = 100 }, dynamics = { duration = 2500 } },
							sends[#sends].body, "the hold superseded the waiting level")
					end)

					it("is cleared by fields with urgent, also when they carry both, and the state goes at once", function()
						empty_bucket()
						q:set("p", { dim = "up", rate = 3000, paced = true })
						c4.fire_timers()
						assert.same({ period }, timer_delays())
						q:set("p", { on = true, brightness = 100, rate = 3000, urgent = true })
						assert.is_nil(q:pending("p").paced)
						assert.same({ commands.DEBOUNCE_MS }, timer_delays(), "the token wait gave way to the debounce")
						c4.fire_timers()
						assert.equal(q.burst + 1, #sends)
						assert.same({ on = { on = true }, dimming = { brightness = 100 }, dynamics = { duration = 3000 } },
							sends[#sends].body)

						q:set("b", { dim = "up", rate = 3000, paced = true, urgent = true })
						assert.is_nil(q:pending("b").paced, "urgent wins over paced in the same fields")
						c4.fire_timers()
						assert.equal(q.burst + 2, #sends)
						assert.equal(0, q.tokens)
					end)

					it("follows the newest fields: unpaced ones clear it, paced ones set it over an urgent state", function()
						empty_bucket()
						q:set("p", { dim = "up", rate = 3000, paced = true })
						q:set("p", { dim = "stop", level = 20 })
						assert.is_nil(q:pending("p").paced)
						c4.fire_timers()
						assert.equal(q.burst + 1, #sends, "an unpaced stop is urgent again")

						q:set("t", { on = true, brightness = 100, rate = 3000, urgent = true })
						q:set("t", { dim = "up", rate = 3000, paced = true })
						assert.same({ dim = "up", rate = 3000, urgent = true, paced = true }, q:pending("t"))
						assert.is_false(commands.urgent(q:pending("t")), "paced beats the urgent the replaced tap left")
						c4.fire_timers()
						assert.equal(q.burst + 1, #sends)
						assert.same({ period }, timer_delays())
					end)

					it("accepts the string form", function()
						q:set("p", { dim = "up", rate = "3000", paced = "true" })
						assert.same({ dim = "up", rate = 3000, paced = true }, q:pending("p"))
						q:set("p", { dim = "up", paced = "false" })
						assert.is_nil(q:pending("p").paced)
					end)

					it("keeps a paced stop that replaced an unsent ramp paced: its level waits its turn (#421 D13)", function()
						empty_bucket()
						q:set("r", { on = true, brightness = 80, rate = 4000 })
						c4.fire_timers()
						assert.same({ period }, timer_delays())
						q:set("r", { dim = "stop", level = 55, paced = true })
						assert.same({ on = true, brightness = 55, rate = 0, urgent = true, paced = true }, q:pending("r"))
						assert.same({ period }, timer_delays(), "still waiting")
						c4.advance(period)
						assert.equal(q.burst + 1, #sends)
						assert.same({ on = { on = true }, dimming = { brightness = 55 } }, sends[#sends].body)
					end)

					it("retries a failed paced state paced, unless a newer unpaced request came meanwhile", function()
						-- Each rid's start goes out on its own debounce, and each
						-- fails while the next request for it waits behind it.
						local function fail_with(rid, start, newer)
							q:set(rid, start)
							c4.fire_timers_of(commands.DEBOUNCE_MS)
							local put = sends[#sends]
							assert.equal(rid, put.rid)
							if newer then
								q:set(rid, newer)
								c4.fire_timers_of(commands.DEBOUNCE_MS)
							end
							put.done({ ok = false, code = 503, err = "HTTP 503" })
							return q:pending(rid)
						end

						assert.same({ dim = "up", rate = 3000, paced = true }, fail_with("p", { dim = "up", rate = 3000, paced = true }),
							"the failed state is the newest: still paced")
						assert.same({ commands.BACKOFF_MS }, timer_delays())

						local n = fail_with("n", { dim = "up", rate = 3000, paced = true }, { dim = "stop", level = 25 })
						assert.same({ dim = "stop", level = 25, rate = 3000 }, n, "the unpaced stop that came during the PUT decides")
						assert.is_true(commands.urgent(n))

						local m = fail_with("m", { dim = "up", rate = 3000 }, { dim = "stop", level = 35, paced = true })
						assert.same({ dim = "stop", level = 35, rate = 3000, paced = true }, m, "and a paced one that came meanwhile too")
					end)
				end)
			end)
		end
	end)
end)
