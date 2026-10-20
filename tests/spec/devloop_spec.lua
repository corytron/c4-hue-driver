local fake = require("helpers.fake_c4")

-- Globals a bundle's driver.lua or a test defines; cleared after each test.
local DRIVER_GLOBALS = { "OnDriverInit", "OnDriverLateInit", "OnDriverDestroyed", "ExecuteCommand",
	"OnPropertyChanged", "DEVLOOP_TEST_MARK", "DEVLOOP_TEST_CALLS" }

-- A driver.lua that records its entry points in DEVLOOP_TEST_CALLS.
local DRIVER_SRC = [[
DEVLOOP_TEST_MARK = "loaded"
table.insert(DEVLOOP_TEST_CALLS, "chunk")
function OnDriverInit(reason) table.insert(DEVLOOP_TEST_CALLS, "init:" .. tostring(reason)) end
function OnDriverLateInit(reason) table.insert(DEVLOOP_TEST_CALLS, "late:" .. tostring(reason)) end
function OnDriverDestroyed() table.insert(DEVLOOP_TEST_CALLS, "destroyed") end
]]

describe("common.devloop", function()
	local devloop, c4, server, printed, real_print, saved_modules
	local HOST = "devvm:8080"

	local function state()
		return rawget(_G, "__DEVLOOP")
	end

	local function calls()
		return rawget(_G, "DEVLOOP_TEST_CALLS")
	end

	local function json(value)
		return c4:JsonEncode(value)
	end

	-- The scripted dev server: what it serves and what it received.
	local function new_server()
		return {
			version = "v1",
			files = { ["driver.lua"] = DRIVER_SRC },
			commands = {},
			requests = {},   -- "METHOD /path" in order
			reports = {},    -- decoded POST /report bodies
			logs = {},       -- decoded POST /log bodies
			manifest_error = nil,
			log_error = nil,
		}
	end

	local function route(t)
		local path = t.url:match("^http://[^/]+(/.*)$")
		table.insert(server.requests, t.method .. " " .. path)
		local base = path:match("^[^?]+")
		if base == "/manifest" then
			if server.manifest_error then
				return t:done(server.manifest_error, "Failed to connect")
			end
			return t:respond(200, json({ version = server.version, files = {}, server_time = 1 }))
		elseif base == "/bundle" then
			return t:respond(200, json({ version = server.version, files = server.files }))
		elseif base == "/commands" then
			local after = tonumber(path:match("after=(%d+)"))
			local pending = {}
			for _, cmd in ipairs(server.commands) do
				if cmd.id > after then table.insert(pending, cmd) end
			end
			return t:respond(200, json({ commands = pending }))
		elseif base == "/report" then
			table.insert(server.reports, c4:JsonDecode(t.data))
			return t:respond(204, "")
		elseif base == "/log" then
			if server.log_error then
				return t:done(server.log_error, "Failed to connect")
			end
			table.insert(server.logs, c4:JsonDecode(t.data))
			return t:respond(204, "")
		end
		t:respond(404, "unknown")
	end

	-- Answer every unanswered transfer, including those the answers start,
	-- until the chain is idle. Returns how many were answered.
	local function serve()
		local n = 0
		while true do
			local pending
			for _, t in ipairs(c4.transfers) do
				if not t.served then pending = t; break end
			end
			if not pending then return n end
			pending.served = true
			route(pending)
			n = n + 1
		end
	end

	local function tick()
		c4.fire_timers()
		return serve()
	end

	local function events()
		local out = {}
		for _, r in ipairs(server.reports) do out[#out + 1] = r.event end
		return out
	end

	local function last_report()
		return server.reports[#server.reports]
	end

	-- Start the loop and bring it to the server's version.
	local function start_synced()
		devloop.start(HOST)
		serve()
		tick()
		server.requests, server.reports, server.logs = {}, {}, {}
	end

	before_each(function()
		c4 = fake.install_c4({ ["Status"] = "Idle", ["Debug Mode"] = "Off" })
		real_print = print
		printed = {}
		rawset(_G, "print", function(...)
			local parts = {}
			for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
			table.insert(printed, table.concat(parts, "\t"))
		end)
		rawset(_G, "DEVLOOP_TEST_CALLS", {})
		-- A reload clears common.* and bridge.* modules; keep the other specs' instances.
		saved_modules = {}
		for name, mod in pairs(package.loaded) do
			if name:match("^bridge%.") or name:match("^common%.") then saved_modules[name] = mod end
		end
		package.loaded["common.devloop"] = nil
		rawset(_G, "__DEVLOOP", nil)
		devloop = require("common.devloop")
		server = new_server()
	end)

	after_each(function()
		local S = state()
		devloop.stop()
		for i = #package.loaders, 1, -1 do
			if package.loaders[i] == S.loader then table.remove(package.loaders, i) end
		end
		rawset(_G, "print", real_print)
		for _, name in ipairs(DRIVER_GLOBALS) do rawset(_G, name, nil) end
		for name in pairs(package.loaded) do
			if name:match("^bridge%.") or name:match("^common%.") then package.loaded[name] = nil end
		end
		for name, mod in pairs(saved_modules) do package.loaded[name] = mod end
	end)

	describe("start", function()
		it("arms one repeating 3000 ms timer and posts the startup report at once", function()
			assert.is_true(devloop.start(HOST))
			assert.same({ { 3000, true } }, c4.calls_to("SetTimer"))
			assert.is_true(devloop.running())
			assert.equal(1, serve())
			assert.same({ "POST /report" }, server.requests)
			local r = server.reports[1]
			assert.equal("startup", r.event)
			assert.is_nil(r.version)
			assert.equal("Idle", r.properties.Status)
			assert.equal("Lua 5.1", r.sandbox._VERSION)
			assert.equal("function", r.sandbox.loadstring)
			assert.equal("function", r.sandbox.setfenv)
			assert.equal("table", r.sandbox.package)
			assert.equal("table", r.sandbox["package.loaders"])
			assert.equal("table", r.sandbox.C4)
			assert.equal("1", r.sandbox.driver_version)
			assert.equal("nil", r.sandbox.jit)
		end)

		it("is a no-op for the same host and restarts for a different one", function()
			devloop.start(HOST)
			devloop.start(HOST)
			assert.equal(1, #c4.calls_to("SetTimer"))
			assert.equal(1, #c4.transfers)

			devloop.start("other:9090")
			assert.equal(2, #c4.calls_to("SetTimer"))
			assert.equal(1, #c4.active_timers())
			assert.equal("http://other:9090/report", c4.last_transfer().url)
		end)

		it("with an empty host stops the loop", function()
			devloop.start(HOST)
			assert.is_false(devloop.start(""))
			assert.is_false(devloop.running())
			assert.equal(0, #c4.active_timers())
		end)

		it("sends plain HTTP with short timeouts and never reads persistent storage", function()
			devloop.start(HOST)
			local t = c4.last_transfer()
			assert.is_false(t.options.fail_on_error)
			assert.equal(10, t.options.timeout)
			assert.equal(3, t.options.connect_timeout)
			assert.equal("application/json", t.headers["Content-Type"])
			serve()
			tick()
			assert.equal(0, #c4.calls_to("PersistGetValue"))
		end)
	end)

	describe("tick", function()
		it("fetches the manifest and, at a new version, the bundle, then commands and the log", function()
			devloop.start(HOST)
			serve()
			tick()
			assert.equal("http://devvm:8080/manifest", c4.transfers[2].url)
			assert.same({ "POST /report", "GET /manifest", "GET /bundle", "POST /report",
				"GET /commands?after=0", "POST /log" }, server.requests)
			assert.same({ "startup", "reload" }, events())
		end)

		it("at an unchanged version only polls the manifest and commands", function()
			start_synced()
			tick()
			assert.same({ "GET /manifest", "GET /commands?after=0" }, server.requests)
		end)

		it("skips a tick while the previous chain is still in flight", function()
			devloop.start(HOST)
			serve()
			c4.fire_timers()
			c4.fire_timers()
			assert.equal(2, #c4.transfers, "one manifest request, not two")
			serve()
			assert.equal("reload", last_report().event)
		end)

		it("abandons a chain stuck for STUCK_TICKS ticks and starts a new one", function()
			devloop.start(HOST)
			serve()
			for _ = 1, devloop.STUCK_TICKS + 1 do c4.fire_timers() end
			assert.equal(3, #c4.transfers)
			-- The stale manifest reply is ignored; the fresh one drives the chain.
			c4.transfers[2].served = true
			route(c4.transfers[2])
			assert.equal(3, #c4.transfers)
			serve()
			assert.equal("reload", last_report().event)
		end)

		it("posts a heartbeat when idle for 30 s, not sooner", function()
			start_synced()
			tick()
			assert.same({}, events())
			c4.now_ms = c4.now_ms + devloop.HEARTBEAT_MS
			tick()
			assert.same({ "heartbeat" }, events())
			assert.equal("Idle", last_report().properties.Status)
			assert.equal("v1", last_report().version)
			tick()
			assert.same({ "heartbeat" }, events())
		end)
	end)

	describe("reload", function()
		it("runs the sequence in order and reports the new version", function()
			rawset(_G, "OnDriverDestroyed", function() table.insert(calls(), "old destroyed") end)
			package.loaded["bridge.x"] = { old = true }
			devloop.start(HOST)
			serve()
			tick()
			assert.same({ "old destroyed", "chunk", "init:DIT_UPDATING", "late:DIT_UPDATING" }, calls())
			assert.is_nil(package.loaded["bridge.x"])
			assert.equal("loaded", rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.equal("v1", devloop.version())
			local r = server.reports[2]
			assert.equal("reload", r.event)
			assert.equal("v1", r.version)
			assert.is_nil(r.error)
		end)

		it("serves modules from the bundle and falls through for the rest", function()
			server.files["bridge/x.lua"] = "return { from_bundle = true }"
			server.files["driver.lua"] = DRIVER_SRC .. "\nDEVLOOP_TEST_MARK = require('bridge.x')"
			devloop.start(HOST)
			serve()
			tick()
			assert.is_true(rawget(_G, "DEVLOOP_TEST_MARK").from_bundle)
			assert.is_true(require("bridge.x").from_bundle)
			assert.is_function(require("common.log").always, "not in the bundle: loaded from disk")
			assert.equal(state().loader, package.loaders[1])
		end)

		it("replaces its loader on the next reload instead of stacking", function()
			start_synced()
			local count = #package.loaders
			server.version = "v2"
			tick()
			assert.equal("v2", devloop.version())
			assert.equal(count, #package.loaders)
			assert.equal(state().loader, package.loaders[1])
		end)

		it("reports reload_failed on a syntax error, keeps polling and recovers", function()
			start_synced()
			server.version, server.files["driver.lua"] = "v2", "function ("
			tick()
			assert.same({ "reload_failed" }, events())
			assert.truthy(last_report().error:find("driver.lua", 1, true))
			assert.equal("v2", devloop.version())
			assert.equal(1, #c4.active_timers())

			-- The same broken version is not retried; a new one is.
			server.reports = {}
			tick()
			assert.same({}, events())
			server.version, server.files["driver.lua"] = "v3", DRIVER_SRC
			tick()
			assert.same({ "reload" }, events())
			assert.equal("v3", devloop.version())
		end)

		it("reports reload_failed when an entry point raises", function()
			start_synced()
			server.version = "v2"
			server.files["driver.lua"] = DRIVER_SRC .. "\nfunction OnDriverLateInit() error('boom') end"
			tick()
			assert.equal("reload_failed", last_report().event)
			assert.truthy(last_report().error:find("OnDriverLateInit failed", 1, true))
			assert.truthy(last_report().error:find("boom", 1, true))
		end)

		it("still loads the new code when OnDriverDestroyed raises, and says so", function()
			start_synced()
			rawset(_G, "OnDriverDestroyed", function() error("stuck") end)
			server.version = "v2"
			tick()
			assert.equal("reload", last_report().event)
			assert.truthy(last_report().error:find("OnDriverDestroyed failed", 1, true))
			assert.equal("v2", devloop.version())
		end)

		it("captures output from a freshly required common.log", function()
			start_synced()
			local log = require("common.log")
			log.always("from the new log")
			tick()
			assert.equal("from the new log", server.logs[1].lines[1].line)
		end)
	end)

	describe("commands", function()
		it("execute goes through ExecuteCommand and reports command_done", function()
			start_synced()
			local seen
			rawset(_G, "ExecuteCommand", function(command, params) seen = { command, params } end)
			server.commands = { { id = 7, type = "execute", command = "Connection Test", params = { Target = "Bridge" } } }
			tick()
			assert.same({ "Connection Test", { Target = "Bridge" } }, seen)
			local r = last_report()
			assert.equal("command_done", r.event)
			assert.equal(7, r.command_id)
			assert.equal("Idle", r.properties.Status)
			assert.is_number(r.elapsed_ms)
			assert.is_nil(r.error)
		end)

		it("set_property updates the property and calls OnPropertyChanged", function()
			start_synced()
			local seen
			rawset(_G, "OnPropertyChanged", function(name) seen = { name, Properties[name] } end)
			server.commands = { { id = 8, type = "set_property", name = "Stream Timeout (s)", value = "60" } }
			tick()
			assert.same({ "Stream Timeout (s)", "60" }, seen)
			assert.same({ { "Stream Timeout (s)", "60" } }, c4.calls_to("UpdateProperty"))
			assert.equal("60", last_report().properties["Stream Timeout (s)"])
			assert.equal(8, last_report().command_id)
		end)

		it("reload re-runs the sequence on the current bundle", function()
			start_synced()
			server.commands = { { id = 9, type = "reload" } }
			tick()
			assert.same({ "chunk", "init:DIT_UPDATING", "late:DIT_UPDATING",
				"destroyed", "chunk", "init:DIT_UPDATING", "late:DIT_UPDATING" }, calls())
			assert.same({ "reload", "command_done" }, events())
			assert.equal(9, last_report().command_id)
			assert.same({ "GET /manifest", "GET /commands?after=0", "POST /report", "POST /report", "POST /log" },
				server.requests)
		end)

		it("runs commands in order and advances the after= cursor", function()
			start_synced()
			local seen = {}
			rawset(_G, "ExecuteCommand", function(command) table.insert(seen, command) end)
			server.commands = { { id = 3, type = "execute", command = "A" }, { id = 5, type = "execute", command = "B" } }
			tick()
			assert.same({ "A", "B" }, seen)
			assert.same({ "command_done", "command_done" }, events())
			tick()
			assert.equal("GET /commands?after=5", server.requests[#server.requests])
			assert.same({ "A", "B" }, seen, "not re-run")
		end)

		it("reports a failing command instead of dying", function()
			start_synced()
			rawset(_G, "ExecuteCommand", function() error("nope") end)
			server.commands = { { id = 4, type = "execute", command = "A" }, { id = 6, type = "bogus" } }
			tick()
			assert.truthy(server.reports[1].error:find("nope", 1, true))
			assert.truthy(server.reports[2].error:find("unknown command type", 1, true))
			assert.equal(6, state().last_command_id)
		end)
	end)

	describe("log capture", function()
		it("buffers print() and ships it with POST /log", function()
			start_synced()
			c4.now_ms = 1234567
			print("hello", 42)
			tick()
			local body = server.logs[1]
			assert.equal("v1", body.version)
			assert.same({ { t = 1234567, line = "hello\t42" } }, body.lines)
			assert.equal("hello\t42", printed[#printed], "the original print still runs")
			tick()
			assert.equal(1, #server.logs, "nothing new to ship")
		end)

		it("keeps the newest 500 lines", function()
			start_synced()
			for i = 1, 600 do print("line " .. i) end
			tick()
			local lines = server.logs[1].lines
			assert.equal(500, #lines)
			assert.equal("line 101", lines[1].line)
			assert.equal("line 600", lines[500].line)
		end)

		it("keeps lines the server did not accept", function()
			start_synced()
			server.log_error = 7
			print("first")
			tick()
			assert.equal(0, #server.logs)
			server.log_error = nil
			print("second")
			tick()
			assert.equal("first", server.logs[1].lines[1].line)
			assert.equal("second", server.logs[1].lines[2].line)
		end)

		it("sends its own messages through the original print, prefixed, and buffers them", function()
			devloop.start(HOST)
			assert.equal("devloop: started against http://devvm:8080", printed[1])
			serve()
			tick()
			assert.equal("devloop: started against http://devvm:8080", server.logs[1].lines[1].line)
			assert.truthy(server.logs[1].lines[2].line:find("^devloop: reloading to version v1"))
		end)

		it("snapshots shadowed property values even when Properties lags", function()
			start_synced()
			C4:UpdateProperty("Status", "Paired")
			Properties["Status"] = nil
			server.commands = { { id = 1, type = "execute", command = "A" } }
			tick()
			assert.equal("Paired", last_report().properties.Status)
		end)
	end)

	describe("stop", function()
		it("cancels the timer, restores print and ignores late replies", function()
			local quiet = print
			devloop.start(HOST)
			assert.is_not.equal(quiet, print)
			devloop.stop()
			assert.equal(quiet, print)
			assert.is_false(devloop.running())
			assert.equal(0, #c4.active_timers())
			assert.equal(0, c4.fire_timers())
			serve() -- the startup report's reply arrives after stop()
			assert.equal(1, #c4.transfers)
			assert.is_nil(state().wrapped_c4, "C4.UpdateProperty unwrapped")
		end)
	end)

	describe("failures", function()
		it("survive a manifest transfer error and resume", function()
			devloop.start(HOST)
			serve()
			server.manifest_error = 7
			tick()
			tick()
			assert.same({ "POST /report", "GET /manifest", "GET /manifest" }, server.requests)
			assert.equal(1, #c4.active_timers())
			assert.equal(2, #printed, "the startup line, then unreachable said once")
			server.manifest_error = nil
			tick()
			assert.equal("reload", last_report().event)
		end)

		it("survive Get() raising at transfer start", function()
			start_synced()
			local real_url = c4.url
			c4.url = function(self)
				local t = real_url(self)
				t.Get = function() error("Error loading certificate") end
				return t
			end
			tick()
			assert.is_false(state().busy)
			c4.url = real_url
			tick()
			assert.same({ "GET /manifest", "GET /commands?after=0", "POST /log" }, server.requests)
			assert.truthy(server.logs[1].lines[1].line:find("unreachable", 1, true))
		end)
	end)
end)
