-- Runs every scenario of tests/fixtures/syncbox_scenarios.json against the
-- Lua fake sync box (fake.syncbox, tests/helpers/fake_syncbox.lua) (#547;
-- docs/fakebox-design.md §4; the rules and the file's format are
-- docs/syncbox-behaviour.md, §14 for the format). The Python model runs the
-- same file (tools/tests/test_fakebox_scenarios.py): the two fakes keep one
-- behaviour. A scenario the fake fails fails here, with every mismatch of
-- the step named; nothing is skipped.
--
-- Requests go the way the drivers' go: C4:url transfers to the box's address
-- with the box client's TLS options, answered by the fake's transport. Events
-- go to h:event(name, args). The state checks read h:snapshot(), the whole
-- state as GET /api/v1 answers it, which counts as no request. Placeholders
-- only: box 10.0.2.150, id 0A1B2C3D4E5F, token TEST-TOKEN-NOT-REAL.

local fake = require("helpers.fake_c4")
local json = require("dkjson")
local F = require("fixtures.hue_syncbox")

local SCENARIOS = "tests/fixtures/syncbox_scenarios.json"
local WRONG_TOKEN = "WRONG-TOKEN-NOT-REAL"
local BOX_TLS = { ssl_verify_peer = true, ssl_verify_host = false, ssl_cabundle = "certs/hsb_ca.pem", timeout = 5,
	connect_timeout = 3 }
local EVENTS = {
	button = true, cec_active_source = true, hotplug = true, signal = true, tv_standby = true,
	usb_power_lost = true, idle = true, bridge = true, rename = true, app_deletes = true, firmware = true,
	reboot = true, advance = true, address = true,
}

local function read_scenarios()
	local file = assert(io.open(SCENARIOS, "rb"), "cannot open " .. SCENARIOS)
	local text = file:read("*a")
	file:close()
	local decoded, _, err = json.decode(text)
	assert(type(decoded) == "table", SCENARIOS .. " is not JSON: " .. tostring(err))
	return decoded
end

-- A deep copy that keeps dkjson's object and array marks.
local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = copy(v)
	end
	return setmetatable(out, getmetatable(value))
end

local function split(path)
	local parts = {}
	for part in tostring(path):gmatch("[^%.]+") do
		parts[#parts + 1] = part
	end
	return parts
end

-- The value at a dotted path, and whether the path exists.
local function lookup(node, path)
	for _, part in ipairs(split(path)) do
		if type(node) ~= "table" then
			return nil, false
		end
		local nxt = node[part]
		if nxt == nil and tonumber(part) then
			nxt = node[tonumber(part)]
		end
		if nxt == nil then
			return nil, false
		end
		node = nxt
	end
	return node, true
end

local function set_path(node, path, value)
	local parts = split(path)
	for i = 1, #parts - 1 do
		local part = parts[i]
		if type(node[part]) ~= "table" then
			node[part] = setmetatable({}, { __jsontype = "object" })
		end
		node = node[part]
	end
	node[parts[#parts]] = value
end

local function same(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not same(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function show(value)
	if type(value) == "table" then
		return json.encode(value)
	end
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local function sorted_keys(t)
	local out = {}
	for k in pairs(t or {}) do
		out[#out + 1] = k
	end
	table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
	return out
end

-- The whole state as GET /api/v1 answers it, without a request.
local function view(h)
	if type(h.snapshot) == "function" then
		return h:snapshot()
	end
	if type(h.view) == "function" then
		return h:view()
	end
	error("fake.syncbox has neither h:snapshot() nor h:view() (docs/syncbox-behaviour.md §12)")
end

-- One scenario's run: the runtime, the box and what the steps saved.
local Run = {}
Run.__index = Run

local function new_run(scenario)
	local c4 = fake.install_c4()
	local state = copy(assert(F.state[scenario.model], "no fixture " .. tostring(scenario.model)))
	for _, path in ipairs(sorted_keys(scenario.given)) do
		set_path(state, path, copy(scenario.given[path]))
	end
	local h = fake.syncbox({ state = state })
	return setmetatable({ c4 = c4, h = h, address = F.ADDRESS, tokens = {}, ids = {},
		paired = scenario.setup == "paired", id = scenario.id }, Run)
end

function Run:token_for(step)
	local name = step.token
	if name == nil then
		name = self.paired and "t" or "none"
	end
	if name == "none" then
		return nil
	elseif name == "wrong" then
		return WRONG_TOKEN
	end
	return assert(self.tokens[name], "no token saved as " .. tostring(name))
end

function Run:expand(path)
	return (tostring(path or ""):gsub("{([%w_]+)}", function(name)
		return assert(self.ids[name], "no registration saved as " .. name)
	end))
end

-- A request through C4:url: status (nil: no answer) and the decoded body.
function Run:request(step)
	local method = step["do"]
	local url = "https://" .. self.address .. "/api/v1" .. self:expand(step.path)
	local headers = {}
	local token = self:token_for(step)
	if token then
		headers.Authorization = "Bearer " .. token
	end
	local data
	if step.raw ~= nil then
		data = step.raw
	elseif step.body ~= nil then
		data = json.encode(step.body)
	end
	if data then
		headers["Content-Type"] = "application/json"
	end
	local got = {}
	local t = self.c4:url():SetOptions(copy(BOX_TLS)):OnDone(function(_, responses, err_code)
		got.done = true
		got.err_code = err_code
		local last = responses and responses[#responses]
		got.code = last and last.code
		got.text = last and last.body
	end)
	if method == "GET" then
		t:Get(url, headers)
	elseif method == "POST" then
		t:Post(url, data or "", headers)
	elseif method == "PUT" then
		t:Put(url, data or "", headers)
	elseif method == "DELETE" then
		t:Delete(url, headers)
	else
		error("unknown method " .. tostring(method))
	end
	if not got.done then
		t:Cancel()
		return nil, nil
	end
	if got.code == nil or (got.err_code ~= nil and got.err_code ~= 0 and not got.text) then
		return nil, nil
	end
	local body = got.text and got.text ~= "" and json.decode(got.text) or nil
	return got.code, body
end

function Run:event(step)
	assert(EVENTS[step.event], "unknown event " .. tostring(step.event))
	local args = {}
	for k, v in pairs(step) do
		if k ~= "event" and k ~= "expect" then
			args[k] = v
		end
	end
	assert(type(self.h.event) == "function", "fake.syncbox has no h:event (docs/fakebox-design.md §8, F3)")
	if step.event == "advance" then
		local before = self.c4.now_ms
		self.h:event("advance", args)
		if self.c4.now_ms == before then
			self.c4.advance(args.ms)
		end
	else
		self.h:event(step.event, args)
	end
	if step.event == "address" then
		self.address = args.address
	end
end

-- Every mismatch of one step against its expect, as text lines.
local function mismatches(expect, status, body, before, after)
	local out = {}
	local function add(fmt, ...)
		out[#out + 1] = string.format(fmt, ...)
	end
	if expect.no_answer then
		if status ~= nil then
			add("expected no answer, got HTTP %s %s", tostring(status), show(body))
		end
	elseif expect.status ~= nil and status ~= expect.status then
		add("status: expected %s, got %s %s", tostring(expect.status), tostring(status), show(body))
	end
	if expect.code ~= nil then
		local code = type(body) == "table" and body.code or nil
		if code ~= expect.code then
			add("code: expected %s, got %s", tostring(expect.code), show(code))
		end
	end
	for _, key in ipairs(expect.has or {}) do
		if type(body) ~= "table" or body[key] == nil then
			add("body has no %s", key)
		end
	end
	for _, path in ipairs(sorted_keys(expect.body)) do
		local value = lookup(body, path)
		if not same(value, expect.body[path]) then
			add("body %s: expected %s, got %s", path, show(expect.body[path]), show(value))
		end
	end
	for _, path in ipairs(expect.body_absent or {}) do
		local _, found = lookup(body, path)
		if found then
			add("body %s should be absent", path)
		end
	end
	if expect.body_exact ~= nil and not same(body, expect.body_exact) then
		add("body: expected exactly %s, got %s", show(expect.body_exact), show(body))
	end
	for _, path in ipairs(sorted_keys(expect.state)) do
		local value = lookup(after, path)
		if not same(value, expect.state[path]) then
			add("state %s: expected %s, got %s", path, show(expect.state[path]), show(value))
		end
	end
	for _, path in ipairs(expect.absent or {}) do
		local value, found = lookup(after, path)
		if found then
			add("state %s should be absent, is %s", path, show(value))
		end
	end
	for _, path in ipairs(expect.present or {}) do
		local _, found = lookup(after, path)
		if not found then
			add("state %s should be present", path)
		end
	end
	for _, path in ipairs(expect.changed or {}) do
		local a = lookup(before, path)
		local b = lookup(after, path)
		if same(a, b) then
			add("state %s should have changed, still %s", path, show(b))
		end
	end
	return out
end

local function describe_step(step)
	if step.event then
		local args = {}
		for _, k in ipairs(sorted_keys(step)) do
			if k ~= "event" and k ~= "expect" then
				args[#args + 1] = k .. "=" .. show(step[k])
			end
		end
		return "event " .. step.event .. (#args > 0 and (" " .. table.concat(args, " ")) or "")
	end
	local text = step["do"] .. " " .. tostring(step.path)
	if step.body ~= nil then
		text = text .. " " .. json.encode(step.body)
	elseif step.raw ~= nil then
		text = text .. " raw " .. show(step.raw)
	end
	return text
end

function Run:step(n, step)
	local expect = step.expect
	local before = expect and expect.changed and view(self.h) or nil
	local status, body
	if step.event then
		self:event(step)
	else
		status, body = self:request(step)
		if expect == nil then
			-- A request without expect prepares the next steps: it must succeed.
			expect = { status = 200 }
		end
		if step.save_token and status == 200 and type(body) == "table" then
			self.tokens[step.save_token] = body.accessToken
			self.ids[step.save_token] = body.registrationId
		end
	end
	if expect == nil then
		return
	end
	local needs_state = expect.state or expect.absent or expect.present or expect.changed
	local after = needs_state and view(self.h) or nil
	local found = mismatches(expect, status, body, before, after)
	if #found > 0 then
		error(string.format("%s step %d (%s):\n  %s", self.id, n, describe_step(step), table.concat(found, "\n  ")), 0)
	end
end

function Run:setup()
	self:step(0, { event = "button" })
	self:step(0, { ["do"] = "POST", path = "/registrations", token = "none",
		body = { appName = F.APP_NAME, instanceName = "Scenario" }, save_token = "t",
		expect = { status = 200, has = { "registrationId", "accessToken" } } })
end

local function run(scenario)
	local r = new_run(scenario)
	if scenario.setup == "paired" then
		r:setup()
	end
	for n, step in ipairs(scenario.steps) do
		r:step(n, step)
	end
end

local file = read_scenarios()

describe("sync box scenarios (#547) against the Lua fake", function()
	it("the file is version 1 with at least 120 scenarios, unique ids, known models and events", function()
		assert.equal(1, file.version)
		assert.is_true(#file.scenarios >= 120, "only " .. #file.scenarios .. " scenarios")
		local ids = {}
		for _, s in ipairs(file.scenarios) do
			assert.is_nil(ids[s.id], "duplicate id " .. tostring(s.id))
			ids[s.id] = true
			assert.is_truthy(F.state[s.model], s.id .. ": no fixture " .. tostring(s.model))
			assert.is_true(type(s.rules) == "table" and #s.rules > 0, s.id .. ": no rules")
			for _, step in ipairs(s.steps) do
				assert.is_true((step["do"] ~= nil) ~= (step.event ~= nil), s.id .. ": a step is a request or an event")
				if step.event then
					assert.is_truthy(EVENTS[step.event], s.id .. ": unknown event " .. tostring(step.event))
				end
			end
		end
	end)

	for _, scenario in ipairs(file.scenarios) do
		it(scenario.id .. ": " .. tostring(scenario.title) .. " (" .. table.concat(scenario.rules, ", ") .. ")",
			function()
				run(scenario)
			end)
	end
end)
