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
end)
