-- common/link.lua (#428, docs/offline-design.md §6.1 and §6.3): the
-- parameters of HUE_BRIDGE_LINK and the Status text a Hue device shows while
-- the bridge is offline. Times are built in the controller's local time, as
-- the module reads them.

local link = require("common.link")

-- os.time of a local wall-clock time.
local function at(year, month, day, hour, min)
	return os.time({ year = year, month = month, day = day, hour = hour, min = min, sec = 0 })
end

local NOW = at(2026, 11, 9, 18, 30)
local TODAY = at(2026, 11, 9, 14, 2)
local OTHER_DAY = at(2026, 10, 26, 14, 2)

local function offline(reason, since)
	return { state = "offline", reason = reason, since = since and string.format("%d", since) or nil }
end

describe("common.link", function()
	describe("parse (§6.1)", function()
		it("reads online", function()
			assert.same({ offline = false }, link.parse({ state = "online" }))
		end)

		it("reads offline with each of the five reasons and since in whole epoch seconds", function()
			for _, reason in ipairs({ "not_answering", "other_bridge", "key_rejected", "blocked", "not_paired" }) do
				assert.same({ offline = true, reason = reason, since = TODAY }, link.parse(offline(reason, TODAY)), reason)
			end
		end)

		it("ignores reason and since on online", function()
			assert.same({ offline = false }, link.parse({ state = "online", reason = "blocked", since = "12" }))
		end)

		it("takes an unknown or missing reason as not_answering: offline stays offline", function()
			assert.same({ offline = true, reason = "not_answering", since = TODAY },
				link.parse(offline("bridge_on_fire", TODAY)))
			assert.same({ offline = true, reason = "not_answering", since = TODAY },
				link.parse({ state = "offline", since = tostring(TODAY) }))
			assert.same({ offline = true, reason = "not_answering", since = TODAY },
				link.parse({ state = "offline", reason = 7, since = tostring(TODAY) }))
		end)

		it("drops a since that is missing, not a number, not positive or not finite", function()
			for _, since in ipairs({ "", "soon", "0", "-5", "nan", "inf", "1e300" }) do
				assert.same({ offline = true, reason = "key_rejected" },
					link.parse({ state = "offline", reason = "key_rejected", since = since }), since)
			end
			assert.same({ offline = true, reason = "key_rejected" },
				link.parse({ state = "offline", reason = "key_rejected" }))
		end)

		it("rounds a since with decimals down, and takes a number as well as its text", function()
			assert.equal(TODAY, link.parse({ state = "offline", since = tostring(TODAY) .. ".75" }).since)
			assert.equal(TODAY, link.parse({ state = "offline", since = TODAY }).since)
		end)

		it("answers nil for an unknown or missing state, and for no table", function()
			assert.is_nil(link.parse({ state = "sideways", reason = "blocked", since = "12" }))
			assert.is_nil(link.parse({ state = "OFFLINE" }))
			assert.is_nil(link.parse({}))
			assert.is_nil(link.parse(nil))
			assert.is_nil(link.parse("offline"))
		end)
	end)

	describe("clock (§6.3)", function()
		it("gives 14:02 on the day of now", function()
			assert.equal("14:02", link.clock(TODAY, NOW))
			assert.equal("00:00", link.clock(at(2026, 11, 9, 0, 0), NOW))
		end)

		it("gives 10-26 14:02 on another day, before or after", function()
			assert.equal("10-26 14:02", link.clock(OTHER_DAY, NOW))
			assert.equal("11-08 23:59", link.clock(at(2026, 11, 8, 23, 59), NOW))
			assert.equal("11-10 00:01", link.clock(at(2026, 11, 10, 0, 1), NOW))
		end)

		it("reads now from os.time when not given", function()
			local now = os.time()
			assert.equal(os.date("%H:%M", now), link.clock(now))
		end)
	end)

	describe("text (§6.3)", function()
		local TEXTS = {
			not_answering = "Hue Bridge not answering since %s",
			other_bridge = "Hue Bridge not at its address since %s",
			key_rejected = "Hue Bridge refuses the pairing since %s",
			blocked = "Hue Bridge not usable since %s (see its Status)",
			not_paired = "Hue Bridge not paired since %s",
		}

		it("words each reason with the time of today", function()
			for reason, format in pairs(TEXTS) do
				assert.equal(string.format(format, "14:02"), link.text(link.parse(offline(reason, TODAY)), NOW), reason)
			end
		end)

		it("words each reason with the day of another day, in at most 60 characters", function()
			for reason, format in pairs(TEXTS) do
				local text = link.text(link.parse(offline(reason, OTHER_DAY)), NOW)
				assert.equal(string.format(format, "10-26 14:02"), text, reason)
				assert.is_true(#text <= 60, reason .. ": " .. #text .. " characters")
			end
		end)

		it("names no time without a since", function()
			assert.equal("Hue Bridge not answering", link.text(link.parse({ state = "offline" }), NOW))
			assert.equal("Hue Bridge not usable (see its Status)",
				link.text(link.parse({ state = "offline", reason = "blocked", since = "x" }), NOW))
		end)

		it("words an unknown reason as not answering", function()
			assert.equal("Hue Bridge not answering since 14:02", link.text({ offline = true, reason = "new",
				since = TODAY }, NOW))
		end)

		it("answers nil while online, and for no link", function()
			assert.is_nil(link.text(link.parse({ state = "online" }), NOW))
			assert.is_nil(link.text(nil, NOW))
		end)

		it("follows the day at every call: the same link names its day after midnight", function()
			local l = link.parse(offline("not_answering", at(2026, 11, 9, 23, 50)))
			assert.equal("Hue Bridge not answering since 23:50", link.text(l, at(2026, 11, 9, 23, 55)))
			assert.equal("Hue Bridge not answering since 11-09 23:50", link.text(l, at(2026, 11, 10, 0, 5)))
		end)
	end)

	-- #487 D-6: every time goes through common/num.lua.
	describe("times os.date cannot take (#487)", function()
		it("drops a since past 2100, NaN or an infinity: the text names no time", function()
			for _, since in ipairs({ "4102444800", "4294967295", "nan", "inf", "1e300", "-5" }) do
				local l = link.parse({ state = "offline", since = since })
				assert.is_nil(l.since, since)
				assert.equal("Hue Bridge not answering", link.text(l, NOW), since)
			end
		end)

		it("clock reads ? for a time os.date cannot take, never raises", function()
			assert.equal("?", link.clock(1e300, NOW))
			assert.equal("?", link.clock(0 / 0, NOW))
			assert.equal(link.clock(TODAY), link.clock(TODAY, "nan"), "a bad now is the controller's clock")
		end)
	end)
end)
