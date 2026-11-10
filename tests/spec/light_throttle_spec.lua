-- light.throttle: Hue-side level reports of a Hue Light device, at most one
-- LIGHT_BRIGHTNESS_CHANGED a second, the last one exact (#433 D12 to D15,
-- docs/light-events-design.md §6.4, §8.1).

local fake = require("helpers.fake_c4")

describe("light.throttle", function()
	local throttle, c4, level, sends, levels

	-- The driver's side, as §6.5 wires it: current() is the level the proxy
	-- should show, send() is report_brightness(), which notifies and then
	-- records what it sent.
	local function new(ms)
		return throttle.new({
			ms = ms or 1000,
			current = function() return level end,
			send = function()
				sends[#sends + 1] = { level = level, at = C4:GetTime() }
				levels:sent(level)
			end,
		})
	end

	-- What went out, as "level@ms since the start".
	local start
	local function sent()
		local out = {}
		for _, s in ipairs(sends) do out[#out + 1] = tostring(s.level) .. "@" .. tostring(s.at - start) end
		return out
	end

	-- A Hue-side report of `value`: the driver updates its cache, then asks.
	local function hue(value)
		level = value
		levels:report()
	end

	before_each(function()
		c4 = fake.install_c4()
		package.loaded["light.throttle"] = nil
		throttle = require("light.throttle")
		level, sends = nil, {}
		start = c4.now_ms
		levels = new()
	end)

	it("report sends at once when no window is open, and opens one", function()
		hue(40)
		assert.same({ "40@0" }, sent())
		assert.equal(40, levels.last)
		assert.equal(1, #c4.active_timers(), "the window")
		assert.equal(1000, c4.active_timers()[1].delay)
		c4.advance(1000)
		assert.same({ "40@0" }, sent(), "an unmarked window ends with nothing")
		assert.equal(0, #c4.active_timers())
	end)

	it("reports within the window go out once, at its end, with the latest level", function()
		hue(10)
		c4.advance(200)
		hue(20)
		c4.advance(300)
		hue(30)
		c4.advance(400)
		hue(35)
		assert.same({ "10@0" }, sent(), "nothing more inside the window")
		c4.advance(100)
		assert.same({ "10@0", "35@1000" }, sent())
		assert.equal(35, levels.last)
	end)

	it("the window's end sends nothing when the level is back to the last one sent", function()
		hue(50)
		c4.advance(300)
		hue(60)
		c4.advance(300)
		hue(50)
		c4.advance(400)
		assert.same({ "50@0" }, sent())
		assert.equal(0, #c4.active_timers(), "no new window")
		-- The next report is a leading one again.
		c4.advance(5000)
		hue(70)
		assert.same({ "50@0", "70@6000" }, sent())
	end)

	it("a trailing report opens a new window", function()
		hue(10)
		c4.advance(500)
		hue(20)
		c4.advance(500)
		assert.same({ "10@0", "20@1000" }, sent())
		assert.equal(1, #c4.active_timers(), "a new window from the trailing report")
		-- A Hue-side drag of 3.5 s, a report every 250 ms: one a second (each
		-- window's end comes before the report due at the same moment), the
		-- last level exact and at most a second late.
		for i = 1, 14 do
			c4.advance(250)
			hue(20 + i)
		end
		assert.same({ "10@0", "20@1000", "23@2000", "27@3000", "31@4000" }, sent())
		c4.advance(500)
		assert.same({ "10@0", "20@1000", "23@2000", "27@3000", "31@4000", "34@5000" }, sent())
		c4.advance(1000)
		assert.equal(6, #sends, "the last window ends with nothing to add")
		assert.equal(0, #c4.active_timers())
	end)

	it("sent records an immediate report, so the window's end does not repeat it", function()
		hue(30)
		c4.advance(400)
		-- The driver reports at once (an edge, a settled target, a resync):
		-- report_brightness() records it, and the window restarts (open()).
		level = 45
		levels:sent(45)
		levels:open()
		c4.advance(600)
		assert.same({ "30@0" }, sent(), "the first window was replaced")
		c4.advance(400)
		assert.same({ "30@0" }, sent(), "nothing to repeat at the new window's end")
		assert.equal(45, levels.last)
		assert.equal(0, #c4.active_timers())

		-- A mark in the window, then an immediate report of the same level:
		-- the window's end has nothing new.
		hue(55)
		c4.advance(300)
		hue(60)
		levels:sent(60)
		c4.advance(700)
		assert.same({ "30@0", "55@1400" }, sent())
	end)

	it("close drops the window and its trailing report", function()
		hue(10)
		c4.advance(300)
		hue(80)
		levels:close()
		assert.equal(0, #c4.active_timers(), "the timer is cancelled")
		c4.advance(5000)
		assert.same({ "10@0" }, sent(), "no stale trailing report")
		-- A timer that fires after its Cancel (the controller's race) finds
		-- its window gone.
		hue(20)
		local timer = c4.active_timers()[1]
		levels:close()
		timer.callback(timer, 0)
		assert.same({ "10@0", "20@5300" }, sent())
		-- Closing with no window open is harmless.
		levels:close()
		assert.equal(20, levels.last)
	end)

	it("edge is true for the first report and for crossings of 0", function()
		assert.is_true(levels:edge(40), "nothing sent yet")
		assert.is_true(levels:edge(0), "nothing sent yet")
		levels:sent(40)
		assert.is_false(levels:edge(41))
		assert.is_false(levels:edge(100))
		assert.is_true(levels:edge(0), "off")
		levels:sent(0)
		assert.is_false(levels:edge(0))
		assert.is_true(levels:edge(1), "on")
		assert.is_true(levels:edge(100), "on")
	end)

	it("report sends nothing for the level last sent or an unknown one, and opens no window then", function()
		levels:sent(25)
		hue(25)
		hue(nil)
		assert.same({}, sent())
		assert.equal(0, #c4.active_timers())
		-- An unknown level at the window's end is not sent either.
		hue(26)
		hue(nil)
		c4.advance(1000)
		assert.same({ "26@0" }, sent())
		assert.equal(26, levels.last)
	end)

	it("open restarts the window, so an immediate report holds the next Hue-side one back", function()
		level = 0
		levels:sent(0)
		levels:open()
		c4.advance(900)
		hue(30)
		assert.same({}, sent(), "inside the window the immediate report opened")
		c4.advance(100)
		assert.same({ "30@1000" }, sent())
		-- open() while a window is open starts it again, keeping no mark.
		hue(40)
		c4.advance(800)
		levels:open()
		c4.advance(500)
		assert.same({ "30@1000" }, sent(), "the mark went with the old window")
		c4.advance(500)
		assert.same({ "30@1000" }, sent())
		assert.equal(0, #c4.active_timers())
	end)

	it("takes its window length from ms and arms its timers on the C4 of the moment", function()
		local short = new(250)
		levels = short
		hue(10)
		assert.equal(250, c4.active_timers()[1].delay)
		c4.advance(100)
		hue(11)
		c4.advance(150)
		assert.same({ "10@0", "11@250" }, sent())

		-- Another runtime's C4 in place (as the dev loop's guard or fake.as
		-- swap it): the next window is armed there.
		local other = fake.install_c4()
		local before = #c4.calls_to("SetTimer")
		levels:close()
		level = 50
		levels:report()
		assert.equal(before, #c4.calls_to("SetTimer"))
		assert.equal(1, #other.calls_to("SetTimer"))
		assert.equal(250, other.active_timers()[1].delay)
	end)

	it("keeps each object's state apart, and defaults the window to a second", function()
		local a = levels
		local other_sends = {}
		local b = throttle.new({
			current = function() return 70 end,
			send = function() other_sends[#other_sends + 1] = 70 end,
		})
		assert.equal(1000, throttle.DEFAULT_MS)
		assert.equal(1000, b.ms)
		hue(10)
		b:report()
		assert.same({ "10@0" }, sent())
		assert.same({ 70 }, other_sends)
		assert.is_nil(b.last, "b's send() did not call sent()")
		assert.equal(10, a.last)
		b:close()
		hue(20)
		c4.advance(1000)
		assert.same({ "10@0", "20@1000" }, sent(), "closing b leaves a's window")
	end)

	it("refuses a missing current or send", function()
		assert.has_error(function() throttle.new({ send = function() end }) end,
			"throttle.new: current must be a function")
		assert.has_error(function() throttle.new({ current = function() end }) end,
			"throttle.new: send must be a function")
	end)
end)
