-- bridge/rows.lua (#373): the bridge driver's owner-facing Composer rows,
-- moved out of hue_bridge/driver.lua. A plain row, a row the stream
-- rewrites per event (one write a second), a list row (summary on the row,
-- items in the drop-down, a pick snaps back) and a text word-wrapped onto
-- continuation rows whose unused rows are hidden. Driven by the fake C4
-- (fake.install_c4) and its clock (c4.advance).

local fake = require("helpers.fake_c4")

describe("bridge/rows.lua (#373)", function()
	local rows, c4, env, r

	-- The values written to one row, in order.
	local function writes(name)
		local out = {}
		for _, args in ipairs(c4.calls_to("UpdateProperty")) do
			if args[1] == name then out[#out + 1] = args[2] end
		end
		return out
	end

	before_each(function()
		c4, env = fake.install_c4()
		package.loaded["bridge.rows"] = nil
		rows = require("bridge.rows")
		r = rows.new()
	end)

	describe("prop and prop_soon", function()
		it("writes a plain row at once, nil as an empty text and numbers as text", function()
			r:prop("Status", "Paired")
			r:prop("Last Event", nil)
			r:prop("Events Received", 0)
			assert.equal("Paired", env.Properties["Status"])
			assert.equal("", env.Properties["Last Event"])
			assert.equal("0", env.Properties["Events Received"])
		end)

		it("writes a burst's first value at once and its latest a second later", function()
			r:prop_soon("Events Received", 1)
			r:prop_soon("Events Received", 2)
			r:prop_soon("Events Received", 3)
			assert.same({ "1" }, writes("Events Received"))
			c4.advance(999)
			assert.same({ "1" }, writes("Events Received"))
			c4.advance(1)
			assert.same({ "1", "3" }, writes("Events Received"))
			-- The timer stayed armed for the next second; nothing came, so it ends.
			c4.advance(1000)
			assert.same({ "1", "3" }, writes("Events Received"))
			assert.equal(0, #c4.active_timers())
			-- A new burst starts with a value at once again.
			r:prop_soon("Events Received", 4)
			assert.same({ "1", "3", "4" }, writes("Events Received"))
		end)

		it("keeps one write a second per row while values keep coming", function()
			for i = 1, 25 do
				r:prop_soon("Last Event", "event " .. i)
				c4.advance(100)
			end
			c4.advance(1000)
			local seen = writes("Last Event")
			assert.equal("event 1", seen[1])
			assert.equal("event 25", seen[#seen], "the final value always lands")
			assert.is_true(#seen <= 4, "about one write a second: " .. #seen)
		end)

		it("coalesces each row on its own", function()
			r:prop_soon("Events Received", 1)
			r:prop_soon("Last Event", "a")
			r:prop_soon("Last Event", "b")
			assert.same({ "1" }, writes("Events Received"))
			assert.same({ "a" }, writes("Last Event"))
			c4.advance(1000)
			assert.same({ "1" }, writes("Events Received"), "nothing new waited for this row")
			assert.same({ "a", "b" }, writes("Last Event"))
		end)

		it("lets a direct prop win over a value still waiting", function()
			r:prop_soon("Event Stream", "Connected since 14:02, 1 containers")
			r:prop_soon("Event Stream", "Connected since 14:02, 2 containers")
			r:prop("Event Stream", "Stopped")
			c4.advance(2000)
			assert.same({ "Connected since 14:02, 1 containers", "Stopped" }, writes("Event Stream"))
			assert.equal("Stopped", env.Properties["Event Stream"])
		end)

		it("cancels the timer on stop, so a waiting value never lands", function()
			r:prop_soon("Events Received", 1)
			r:prop_soon("Events Received", 2)
			r:stop()
			c4.advance(5000)
			assert.same({ "1" }, writes("Events Received"))
			assert.equal(0, #c4.active_timers())
		end)
	end)

	describe("list rows", function()
		it("puts the summary on the row and every item on a line of the drop-down", function()
			r:list("Lights", "3 lights on bridge, 2 imported", { "Desk Lamp, Office", "Porch" })
			assert.equal("3 lights on bridge‚ 2 imported", env.Properties["Lights"])
			assert.equal("3 lights on bridge‚ 2 imported,Desk Lamp‚ Office,Porch", c4.property_lists["Lights"])
			local call = c4.calls_to("UpdatePropertyList")[1]
			assert.same({ "Lights", "3 lights on bridge‚ 2 imported,Desk Lamp‚ Office,Porch",
				"3 lights on bridge‚ 2 imported" }, call)
		end)

		it("drops control characters and takes a missing summary as empty", function()
			r:list("Scenes", nil, { "a\nb", 7 })
			assert.equal("", env.Properties["Scenes"])
			assert.equal(",ab,7", c4.property_lists["Scenes"])
			assert.equal("ab", rows.commaless("a\tb"))
			assert.equal("x‚ y", rows.commaless("x, y"))
		end)

		it("sends a list only when it changed", function()
			r:list("Scenes", "2 scenes", { "A", "B" })
			r:list("Scenes", "2 scenes", { "A", "B" })
			assert.equal(1, #c4.calls_to("UpdatePropertyList"))
			r:list("Scenes", "2 scenes", { "A", "C" })
			assert.equal(2, #c4.calls_to("UpdatePropertyList"))
		end)

		it("tells a pick that moved the row off its summary, and sends the list again", function()
			r:list("Room Mappings", "2 Hue rooms", { "Garage → Garage" })
			assert.is_false(r:list_moved("Room Mappings", "2 Hue rooms"), "the summary itself")
			assert.is_false(r:list_moved("Zone Lights", "anything"), "a row never listed")
			assert.is_true(r:list_moved("Room Mappings", "Garage → Garage"))
			r:list("Room Mappings", "2 Hue rooms", { "Garage → Garage" })
			assert.equal(2, #c4.calls_to("UpdatePropertyList"))
			assert.equal("2 Hue rooms", env.Properties["Room Mappings"])
		end)

		it("sends the list again after list_reset", function()
			r:list("Bridges Found", "1 Hue bridge found", { "Search again" })
			r:list_reset("Bridges Found")
			r:list("Bridges Found", "1 Hue bridge found", { "Search again" })
			assert.equal(2, #c4.calls_to("UpdatePropertyList"))
		end)
	end)

	describe("wrap", function()
		it("wraps at word boundaries within the width", function()
			assert.same({ "one two", "three" }, rows.wrap("one two three", 8))
			assert.same({}, rows.wrap("", 10))
			assert.same({ "a b" }, rows.wrap("  a   b  ", 10))
		end)

		it("cuts a word longer than the width", function()
			assert.same({ "x", "abcde", "fghij", "k y" }, rows.wrap("x abcdefghijk y", 5))
		end)
	end)

	describe("wrapped rows", function()
		local function attribs(name)
			return c4.property_attribs[name]
		end

		it("writes the text onto the rows and asserts the visibility at 400 ms and 1.5 s later", function()
			local w = r:wrapped("Last Action")
			w:show(string.rep("word ", 30))
			assert.equal(string.rep("word ", 14):sub(1, -2), env.Properties["Last Action"])
			assert.equal(string.rep("word ", 14):sub(1, -2), env.Properties["Last Action (2)"])
			assert.equal("word word", env.Properties["Last Action (3)"])
			assert.equal("", env.Properties["Last Action (4)"])
			assert.equal(0, #c4.calls_to("SetPropertyAttribs"), "never in the same burst as the texts")
			c4.advance(400)
			assert.equal(5, #c4.calls_to("SetPropertyAttribs"))
			assert.equal(0, attribs("Last Action (2)"))
			assert.equal(0, attribs("Last Action (3)"))
			assert.equal(1, attribs("Last Action (4)"))
			assert.equal(1, attribs("Last Action (6)"))
			c4.advance(1500)
			assert.equal(10, #c4.calls_to("SetPropertyAttribs"))
			c4.advance(10000)
			assert.equal(10, #c4.calls_to("SetPropertyAttribs"))
		end)

		it("restarts the visibility timer for a new text", function()
			local w = r:wrapped("Last Action")
			w:show("first")
			c4.advance(300)
			w:show("second")
			c4.advance(300)
			assert.equal(0, #c4.calls_to("SetPropertyAttribs"))
			c4.advance(100)
			assert.equal(5, #c4.calls_to("SetPropertyAttribs"))
		end)

		it("shows `empty` on the first row for an empty text", function()
			local w = r:wrapped("Attention", { empty = "None" })
			w:show("")
			assert.equal("None", env.Properties["Attention"])
			assert.equal("", env.Properties["Attention (2)"])
			assert.equal("", r:wrapped("Last Action").empty)
		end)

		it("ends the last row with a pointer to the Lua output when the text needs more rows", function()
			local overflow = {}
			local w = r:wrapped("Attention", { rows = 2, width = 20, on_overflow = function(text)
				overflow[#overflow + 1] = text
			end })
			local text = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
			w:show(text)
			assert.same({ text }, overflow)
			assert.equal("alpha beta gamma", env.Properties["Attention"])
			assert.equal("delt … (Lua output)", env.Properties["Attention (2)"])
			-- Without on_overflow the rows are cut the same way.
			local quiet = r:wrapped("Last Action", { rows = 2, width = 20 })
			quiet:show(text)
			assert.equal("delt … (Lua output)", env.Properties["Last Action (2)"])
		end)

		it("goes through prop, so a value prop_soon holds back for the row does not land later", function()
			local w = r:wrapped("Attention")
			r:prop_soon("Attention", "old 1")
			r:prop_soon("Attention", "old 2")
			w:show("new")
			c4.advance(2000)
			assert.equal("new", env.Properties["Attention"])
		end)

		it("settles the rows at late init from the texts they still hold", function()
			local w = r:wrapped("Last Action")
			w:settle({ ["Last Action (2)"] = "kept from before", ["Last Action (3)"] = "" })
			assert.equal(0, attribs("Last Action (2)"))
			assert.equal(1, attribs("Last Action (3)"))
			assert.equal(1, attribs("Last Action (6)"))
			assert.equal(5, #c4.calls_to("SetPropertyAttribs"), "at once")
			c4.advance(400)
			assert.equal(10, #c4.calls_to("SetPropertyAttribs"), "and again 400 ms later")
			c4.advance(1500)
			assert.equal(15, #c4.calls_to("SetPropertyAttribs"), "and 1.5 s after that")
			w:settle(nil)
			assert.equal(1, attribs("Last Action (2)"), "no property table: every continuation row hidden")
		end)

		it("cancels its visibility timer", function()
			local w = r:wrapped("Attention")
			w:show("text")
			w:cancel()
			c4.advance(5000)
			assert.equal(0, #c4.calls_to("SetPropertyAttribs"))
		end)

		it("leaves the rows alone without SetPropertyAttribs", function()
			c4.SetPropertyAttribs = nil
			local w = r:wrapped("Attention")
			w:show("text")
			c4.advance(5000)
			assert.equal("text", env.Properties["Attention"])
		end)
	end)

	it("caps an item at ROW_MAX bytes without cutting a UTF-8 character (#489, C-4)", function()
		local long = string.rep("a", 252) .. "é" .. string.rep("b", 600)
		local out = rows.commaless(long)
		assert.is_true(#out <= rows.ROW_MAX)
		assert.equal("...", out:sub(-3))
		assert.is_nil(out:find("\195...$"))
		assert.equal("short‚ one", rows.commaless("short, one"))
	end)
end)
