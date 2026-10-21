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
end)
