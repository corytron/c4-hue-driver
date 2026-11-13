local sse = require("bridge.sse")

-- Two events as the Core Concepts page shows them (light on, then off).
local HUE_SAMPLE = table.concat({
	'id: 1634576695:0',
	'data: [{"creationtime":"2021-10-18T17:04:55Z","data":[{"id":"e706416a","on":{"on":true},'
		.. '"owner":{"rid":"3f4ac4e9","rtype":"device"},"type":"light"}],"id":"9de116fc","type":"update"}]',
	'',
	'id: 1634576699:0',
	'data: [{"creationtime":"2021-10-18T17:04:59Z","data":[{"id":"e706416a","on":{"on":false},'
		.. '"owner":{"rid":"3f4ac4e9","rtype":"device"},"type":"light"}],"id":"5ebb24e4","type":"update"}]',
	'',
	'', -- each event ends with a blank line, so the stream ends "\n\n"
}, "\n")

describe("bridge.sse", function()
	it("parses the Hue sample into two events with ids", function()
		local events = sse.new():feed(HUE_SAMPLE)
		assert.equal(2, #events)
		assert.equal("1634576695:0", events[1].id)
		assert.truthy(events[1].data:find('"on":{"on":true}', 1, true))
		assert.equal("1634576699:0", events[2].id)
		assert.truthy(events[2].data:find('"on":{"on":false}', 1, true))
	end)

	it("reassembles an event split across arbitrary chunk boundaries", function()
		for cut = 1, #HUE_SAMPLE - 1, 7 do
			local p = sse.new()
			local events = p:feed(HUE_SAMPLE:sub(1, cut))
			for _, ev in ipairs(p:feed(HUE_SAMPLE:sub(cut + 1))) do
				table.insert(events, ev)
			end
			assert.equal(2, #events, "cut at " .. cut)
			assert.equal("1634576699:0", events[2].id)
		end
	end)

	it("holds an incomplete event until its blank line arrives", function()
		local p = sse.new()
		assert.same({}, p:feed("id: 1\ndata: {\"a\":1}\n"))
		local events = p:feed("\n")
		assert.equal(1, #events)
		assert.equal('{"a":1}', events[1].data)
	end)

	it("joins multiple data lines with newlines", function()
		local events = sse.new():feed("data: one\ndata: two\n\n")
		assert.equal("one\ntwo", events[1].data)
	end)

	it("accepts CRLF line endings", function()
		local events = sse.new():feed("id: 7\r\ndata: x\r\n\r\n")
		assert.equal("7", events[1].id)
		assert.equal("x", events[1].data)
	end)

	it("counts comment lines as keepalives and emits nothing for them", function()
		local p = sse.new()
		assert.same({}, p:feed(": keepalive\n\n"))
		assert.equal(1, p.comments)
	end)

	it("keeps the last id when an event carries none of its own", function()
		local events = sse.new():feed("id: a\ndata: 1\n\ndata: 2\n\n")
		assert.equal("a", events[2].id)
	end)

	it("records the event type field", function()
		local events = sse.new():feed("event: ping\ndata: {}\n\n")
		assert.equal("ping", events[1].event)
	end)

	it("drops an absurdly long line instead of growing forever", function()
		local p = sse.new()
		p:feed(string.rep("x", sse.MAX_LINE + 1))
		assert.is_true(p.overflowed)
		assert.equal("", p.buffer)
	end)

	-- Security review 2026-11-13, N-1 (#489): an empty `data:` line added 0
	-- to the event's byte count and one entry to the event, so the cap never
	-- tripped and memory grew without bound. Scaled down (MAX_EVENT 4 KB)
	-- so that the spec runs in milliseconds; the arithmetic is the same.
	describe("the per-event cap (N-1, #489)", function()
		local saved

		before_each(function() saved = sse.MAX_EVENT end)
		after_each(function() sse.MAX_EVENT = saved end)

		it("counts empty data lines: twice the cap of them overflows and dispatches nothing", function()
			sse.MAX_EVENT = 4096
			local p = sse.new()
			local events = p:feed(string.rep("data:\n", 2 * 4096) .. string.rep("data\n", 16) .. "\n")
			assert.is_true(p.overflowed)
			assert.same({}, events)
			assert.is_true(#p.data < 4096, "the entries do not pile up: " .. #p.data)
		end)

		it("bounds the dispatched string by the cap, newlines included", function()
			sse.MAX_EVENT = 10
			local events = sse.new():feed("data: 1234\ndata: 1234\n\n") -- 5 + 5 counted
			assert.same({ "1234\n1234" }, { events[1].data })
			local p = sse.new()
			assert.same({}, p:feed("data: 12345\ndata: 1234\n\n")) -- 6 + 5 counted
			assert.is_true(p.overflowed)
		end)

		it("yields nothing more once it overflowed, whatever follows in the chunk or later", function()
			sse.MAX_EVENT = 8
			local p = sse.new()
			local events = p:feed("data: 0123456789\n\nid: 2\ndata: ok\n\n")
			assert.same({}, events)
			assert.same({}, p:feed("id: 3\ndata: ok\n\n"))
			assert.equal("", p.buffer)
		end)

		it("still dispatches the events completed before the overflow", function()
			sse.MAX_EVENT = 8
			local p = sse.new()
			local events = p:feed("id: 1\ndata: ok\n\ndata: 0123456789\n\n")
			assert.equal(1, #events)
			assert.equal("ok", events[1].data)
			assert.is_true(p.overflowed)
		end)
	end)
end)
