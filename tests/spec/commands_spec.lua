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
				c4.now_ms = c4.now_ms + 10000
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
end)
