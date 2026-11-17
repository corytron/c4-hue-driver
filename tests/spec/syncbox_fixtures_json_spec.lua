-- tests/fixtures/hue_syncbox.json is the export of tests/fixtures/hue_syncbox.lua
-- (tools/fakebox/export_fixtures.lua), so the Python fake box reads exactly the
-- states the Lua specs use (docs/fakebox-design.md §2, #547). The Python test of
-- the same name skips where lua5.1 has no dkjson (CI's tooling job); this one runs
-- in the Lua job, which has it.

describe("the fake box's JSON fixtures (#547)", function()
	it("equal the export of the Lua fixtures", function()
		local pipe = assert(io.popen("lua5.1 tools/fakebox/export_fixtures.lua"))
		local exported = pipe:read("*a")
		assert.is_true(pipe:close() ~= nil)
		local file = assert(io.open("tests/fixtures/hue_syncbox.json", "rb"))
		local stored = file:read("*a")
		file:close()
		assert.is_true(#exported > 1000)
		assert.are.equal(stored, exported, "run: lua5.1 tools/fakebox/export_fixtures.lua > tests/fixtures/hue_syncbox.json")
	end)
end)
