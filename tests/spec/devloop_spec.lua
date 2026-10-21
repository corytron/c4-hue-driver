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

-- The light and scene trees' driver.lua, distinguishable from the bridge's and each other.
local LIGHT_SRC = "DEVLOOP_TEST_MARK = 'light loaded'"
local SCENE_SRC = "DEVLOOP_TEST_MARK = 'scene loaded'"

-- Modules a reload clears; the other specs' instances are saved around each test.
local function is_driver_module(name)
	return name:match("^bridge%.") or name:match("^common%.") or name:match("^light%.") or name:match("^scene%.")
end

describe("common.devloop", function()
	local devloop, c4, server, printed, real_print, saved_modules, sent
	local HOST = "devvm:8080"

	-- An idle tick's requests: every manifest, then the commands.
	local POLL = { "GET /manifest", "GET /manifest?tree=light", "GET /manifest?tree=scene", "GET /commands?after=0" }

	local function state()
		return rawget(_G, "__DEVLOOP")
	end

	local function calls()
		return rawget(_G, "DEVLOOP_TEST_CALLS")
	end

	local function json(value)
		return c4:JsonEncode(value)
	end

	-- `list` followed by the extra items.
	local function plus(list, ...)
		local out = {}
		for _, item in ipairs(list) do out[#out + 1] = item end
		for i = 1, select("#", ...) do out[#out + 1] = (select(i, ...)) end
		return out
	end

	-- The scripted dev server: what it serves and what it received.
	local function new_server()
		return {
			version = "v1",
			files = { ["driver.lua"] = DRIVER_SRC },
			light_version = "L1",
			light_files = { ["driver.lua"] = LIGHT_SRC, ["light/state.lua"] = "return {}" },
			scene_version = "S1",
			scene_files = { ["driver.lua"] = SCENE_SRC },
			trees = true,        -- false: an older server that knows no ?tree=
			scene_tree = true,   -- false: a server with a light tree only (HTTP 400 for ?tree=scene)
			commands = {},
			requests = {},       -- "METHOD /path" in order
			reports = {},        -- decoded POST /report bodies
			logs = {},           -- decoded POST /log bodies
			manifest_error = nil,
			log_error = nil,
		}
	end

	-- The tree a request names, as the server sees it: nil before trees
	-- existed (the query is ignored), "bridge" when none is named.
	local function tree_of(path)
		if not server.trees then return nil end
		return path:match("tree=(%w+)") or "bridge"
	end

	local function route(t)
		local path = t.url:match("^http://[^/]+(/.*)$")
		table.insert(server.requests, t.method .. " " .. path)
		local base = path:match("^[^?]+")
		if base == "/manifest" or base == "/bundle" then
			if base == "/manifest" and server.manifest_error then
				return t:done(server.manifest_error, "Failed to connect")
			end
			local tree = tree_of(path)
			if tree == "scene" and not server.scene_tree then
				return t:respond(400, json({ error = "unknown tree 'scene' (bridge or light)" }))
			end
			local forwarded = tree ~= nil and tree ~= "bridge"
			local version = forwarded and server[tree .. "_version"] or server.version
			if base == "/manifest" then
				return t:respond(200, json({ version = version, tree = tree, files = {}, server_time = 1 }))
			end
			local files = forwarded and server[tree .. "_files"] or server.files
			return t:respond(200, json({ version = version, tree = tree, files = files }))
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

	-- Start the loop and bring it to the server's versions.
	local function start_synced()
		devloop.start(HOST)
		serve()
		tick()
		server.requests, server.reports, server.logs, sent = {}, {}, {}, {}
	end

	-- What the bridge has bound on binding 1; tests override per case.
	local function bind_lights(devices)
		c4.GetBoundConsumerDevices = function(_, device_id, binding)
			assert.equal(15, device_id, "the bridge's own device id")
			assert.equal(1, binding)
			return devices
		end
	end

	-- What C4:GetDevices reports for a bound device: the driver file it runs.
	-- A bound device the project does not know is one GetDevices omits.
	local function project_device(id, driver_file)
		fake.project.devices[id] = { name = "Device " .. tostring(id), room_id = 7, c4i = driver_file,
			driver_name = driver_file }
	end

	-- The ids DEV_RELOAD went to for `tree`, sorted.
	local function sent_to(tree)
		local ids = {}
		for _, msg in ipairs(sent) do
			if msg.command == "DEV_RELOAD" and msg.params.tree == tree then ids[#ids + 1] = msg.device_id end
		end
		table.sort(ids)
		return ids
	end

	-- A comma-separated DeviceIds filter as a sorted list.
	local function csv_sorted(text)
		local out = {}
		for id in tostring(text):gmatch("[^,]+") do out[#out + 1] = id end
		table.sort(out)
		return out
	end

	-- How many printed lines are exactly this devloop message.
	local function times_said(msg)
		local n = 0
		for _, line in ipairs(printed) do
			if line == "devloop: " .. msg then n = n + 1 end
		end
		return n
	end

	-- The message was printed exactly once; the order among a tick's lines is incidental.
	local function assert_said(msg)
		assert.equal(1, times_said(msg), "printed once: devloop: " .. msg)
	end

	-- How many printed lines contain `text`.
	local function printed_count(text)
		local n = 0
		for _, line in ipairs(printed) do
			if line:find(text, 1, true) then n = n + 1 end
		end
		return n
	end

	before_each(function()
		c4 = fake.install_c4({ ["Status"] = "Idle", ["Debug Mode"] = "Off" })
		-- Stubbed here rather than in the fake: SendToDevice is recorded with all
		-- five arguments, and GetBoundConsumerDevices answers "nothing bound"
		-- unless a test binds lights.
		sent = {}
		c4.SendToDevice = function(_, device_id, command, params, allow_empty, log_command)
			table.insert(sent, { device_id = device_id, command = command, params = params,
				allow_empty = allow_empty, log_command = log_command, nargs = select("#", device_id, command, params,
					allow_empty, log_command) })
		end
		bind_lights(nil)
		real_print = print
		printed = {}
		rawset(_G, "print", function(...)
			local parts = {}
			for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
			table.insert(printed, table.concat(parts, "\t"))
		end)
		rawset(_G, "DEVLOOP_TEST_CALLS", {})
		-- A reload clears common.*, bridge.* and light.* modules; keep the other specs' instances.
		saved_modules = {}
		for name, mod in pairs(package.loaded) do
			if is_driver_module(name) then saved_modules[name] = mod end
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
			if is_driver_module(name) then package.loaded[name] = nil end
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
			assert.is_nil(r.light_version)
			assert.is_nil(r.scene_version)
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
		it("fetches every manifest and, at new versions, every bundle, then commands and the log", function()
			devloop.start(HOST)
			serve()
			tick()
			assert.equal("http://devvm:8080/manifest", c4.transfers[2].url)
			assert.same({ "POST /report", "GET /manifest", "GET /bundle", "POST /report",
				"GET /manifest?tree=light", "GET /bundle?tree=light",
				"GET /manifest?tree=scene", "GET /bundle?tree=scene",
				"GET /commands?after=0", "POST /log", "POST /report" }, server.requests)
			assert.same({ "startup", "reload", "heartbeat" }, events())
		end)

		it("at unchanged versions only polls the manifests and commands", function()
			start_synced()
			tick()
			assert.same(POLL, server.requests)
		end)

		it("skips a tick while the previous chain is still in flight", function()
			devloop.start(HOST)
			serve()
			c4.fire_timers()
			c4.fire_timers()
			assert.equal(2, #c4.transfers, "one manifest request, not two")
			serve()
			assert.equal("heartbeat", last_report().event)
			assert.same({ "startup", "reload", "heartbeat" }, events())
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
			assert.same({ "startup", "reload", "heartbeat" }, events())
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

	describe("forwarded trees (bridge side)", function()
		it("forwards a new light version to every bound light as DEV_RELOAD", function()
			bind_lights({ [2001] = "A", [2002] = "B" })
			devloop.start(HOST)
			serve()
			tick()
			assert.equal(2, #sent)
			table.sort(sent, function(a, b) return a.device_id < b.device_id end)
			assert.equal(2001, sent[1].device_id)
			assert.equal(2002, sent[2].device_id)
			for _, msg in ipairs(sent) do
				assert.equal("DEV_RELOAD", msg.command)
				assert.equal("light", msg.params.tree)
				assert.equal("L1", msg.params.version)
				assert.is_string(msg.params.files, "the bundle travels as JSON text")
				assert.same(server.light_files, c4:JsonDecode(msg.params.files))
				assert.is_false(msg.allow_empty, "allowEmptyValues")
				assert.is_false(msg.log_command, "logCommand: the bundle must not land in Director's log")
			end
			assert.equal("L1", devloop.light_version())
			assert.equal("L1", devloop.tree_version("light"))
			assert.equal("S1", devloop.tree_version("scene"), "the scene tree was fetched too")
			assert.equal("v1", devloop.version(), "the bridge's own version is untouched")
			assert.same({ "chunk", "init:DIT_UPDATING", "late:DIT_UPDATING" }, calls(), "the bridge did not reload again")
			assert_said("light version L1 forwarded to 2 light device(s)")
			assert_said("scene version S1: no bound scene devices")
		end)

		it("does not re-forward an unchanged version and forwards again when it changes", function()
			bind_lights({ [2001] = "A" })
			start_synced()
			tick()
			assert.same({}, sent)
			assert.same(POLL, server.requests)

			server.light_version, server.light_files["driver.lua"] = "L2", LIGHT_SRC .. " .. ' 2'"
			server.requests = {}
			tick()
			assert.equal(1, #sent)
			assert.equal("L2", sent[1].params.version)
			assert.same(server.light_files, c4:JsonDecode(sent[1].params.files))
			assert.is_false(sent[1].log_command)
			assert.equal("L2", devloop.light_version())
			assert.same({ "GET /manifest", "GET /manifest?tree=light", "GET /bundle?tree=light",
				"GET /manifest?tree=scene", "GET /commands?after=0", "POST /log", "POST /report" }, server.requests)
		end)

		it("reports light_version in the heartbeat right after a forward, and in later reports", function()
			bind_lights({ [2001] = "A" })
			start_synced()
			assert.equal("L1", devloop.light_version())
			server.light_version = "L2"
			tick()
			assert.same({ "heartbeat" }, events(), "a forward makes a heartbeat due at once")
			assert.equal("L2", last_report().light_version)
			assert.equal("S1", last_report().scene_version)
			assert.equal("v1", last_report().version)

			server.reports = {}
			server.commands = { { id = 1, type = "execute", command = "A" } }
			rawset(_G, "ExecuteCommand", function() end)
			tick()
			assert.equal("command_done", last_report().event)
			assert.equal("L2", last_report().light_version)
		end)

		it("remembers the version when no lights are bound, says so once, and catches up lights created later", function()
			devloop.start(HOST)
			serve()
			tick()
			assert.same({}, sent)
			assert.equal("L1", devloop.light_version())
			assert_said("light version L1: no bound light devices")
			assert_said("scene version S1: no bound scene devices")
			local said = #printed
			tick()
			tick()
			assert.equal(said, #printed)
			assert.equal(0, #c4.calls_to("SendToDevice"))

			-- Import Lights binds new lights while the loop runs; the version has
			-- not changed, yet every one of them must get it on the next tick.
			bind_lights({ [2001] = "A", [2002] = "B" })
			server.requests = {}
			tick()
			assert.equal(2, #sent)
			for _, msg in ipairs(sent) do
				assert.equal("DEV_RELOAD", msg.command)
				assert.equal("light", msg.params.tree)
				assert.equal("L1", msg.params.version)
				assert.same(server.light_files, c4:JsonDecode(msg.params.files))
			end
			assert_said("light version L1 forwarded to 2 newly bound light device(s)")
			assert.same(plus(POLL, "POST /log"), server.requests, "the cached bundles are used; no second fetch")
		end)

		it("forwards the current version to a light bound after the first forward, without a refetch", function()
			bind_lights({ [2001] = "A" })
			start_synced()
			bind_lights({ [2001] = "A", [2002] = "B" })
			tick()
			assert.equal(1, #sent)
			assert.equal(2002, sent[1].device_id)
			assert.equal("DEV_RELOAD", sent[1].command)
			assert.equal("L1", sent[1].params.version)
			assert.same(server.light_files, c4:JsonDecode(sent[1].params.files))
			assert.is_false(sent[1].allow_empty)
			assert.is_false(sent[1].log_command)
			assert.same(plus(POLL, "POST /log"), server.requests,
				"no GET /bundle?tree=light and no heartbeat: the version did not change")
			assert_said("light version L1 forwarded to 1 newly bound light device(s)")
			assert.same({ [2001] = "L1", [2002] = "L1" }, state().light_forwarded)
			assert.equal("L1", devloop.light_version())
		end)

		it("sends nothing while the bound set and the version are unchanged", function()
			bind_lights({ [2001] = "A", [2002] = "B" })
			start_synced()
			local said = #printed
			tick()
			tick()
			assert.same({}, sent)
			assert.equal(said, #printed)
			assert.same(plus(POLL, unpack(POLL)), server.requests)
			assert.same({ [2001] = "L1", [2002] = "L1" }, state().light_forwarded)
			assert.same({}, state().scene_forwarded)
		end)

		it("re-forwards a new version to every bound light, caught-up ones included", function()
			bind_lights({ [2001] = "A" })
			start_synced()
			bind_lights({ [2001] = "A", [2002] = "B" })
			tick()
			assert.equal(1, #sent, "2002 caught up with L1")
			sent = {}
			server.light_version, server.light_files["driver.lua"] = "L2", LIGHT_SRC .. " .. ' 2'"
			server.requests = {}
			tick()
			assert.equal(2, #sent)
			table.sort(sent, function(a, b) return a.device_id < b.device_id end)
			assert.same({ 2001, 2002 }, { sent[1].device_id, sent[2].device_id })
			for _, msg in ipairs(sent) do
				assert.equal("L2", msg.params.version)
				assert.same(server.light_files, c4:JsonDecode(msg.params.files))
			end
			assert_said("light version L2 forwarded to 2 light device(s)")
			assert.same({ [2001] = "L2", [2002] = "L2" }, state().light_forwarded)
			assert.equal("L2", devloop.light_version())
			assert.same({ "GET /manifest", "GET /manifest?tree=light", "GET /bundle?tree=light",
				"GET /manifest?tree=scene", "GET /commands?after=0", "POST /log", "POST /report" }, server.requests,
				"fetched once for the new version; a heartbeat is due at once")
		end)

		it("forgets a device that is no longer bound, and forwards again if it comes back", function()
			bind_lights({ [2001] = "A", [2002] = "B" })
			start_synced()
			assert.same({ [2001] = "L1", [2002] = "L1" }, state().light_forwarded)
			bind_lights({ [2001] = "A" })
			tick()
			assert.same({}, sent)
			assert.same({ [2001] = "L1" }, state().light_forwarded)

			bind_lights({ [2001] = "A", [2002] = "B" })
			tick()
			assert.equal(1, #sent)
			assert.equal(2002, sent[1].device_id)
			assert.equal("L1", sent[1].params.version)
			assert.same({ [2001] = "L1", [2002] = "L1" }, state().light_forwarded)

			bind_lights(nil)
			tick()
			assert.same({}, state().light_forwarded, "nothing bound: the table empties")
		end)

		it("tells light and scene devices apart by driverFileName, looked up once per new id", function()
			project_device(2001, "hue_light.c4z")
			project_device(2002, "hue_scene.c4z")
			bind_lights({ [2001] = "Hue Light", [2002] = "Hue Scene", [2003] = "C" })   -- 2003: GetDevices omits it
			devloop.start(HOST)
			serve()
			tick()
			assert.equal(3, #sent)
			assert.same({ 2001, 2003 }, sent_to("light"), "an unknown driver file counts as a light")
			assert.same({ 2002 }, sent_to("scene"))
			for _, msg in ipairs(sent) do
				assert.equal("DEV_RELOAD", msg.command)
				if msg.params.tree == "scene" then
					assert.equal("S1", msg.params.version)
					assert.same(server.scene_files, c4:JsonDecode(msg.params.files))
				else
					assert.equal("L1", msg.params.version)
					assert.same(server.light_files, c4:JsonDecode(msg.params.files))
				end
				assert.is_false(msg.allow_empty)
				assert.is_false(msg.log_command)
			end
			assert_said("light version L1 forwarded to 2 light device(s)")
			assert_said("scene version S1 forwarded to 1 scene device(s)")
			assert.same({ [2001] = "L1", [2003] = "L1" }, state().light_forwarded)
			assert.same({ [2002] = "S1" }, state().scene_forwarded)
			assert.equal("S1", devloop.tree_version("scene"))

			local lookups = c4.calls_to("GetDevices")
			assert.equal(1, #lookups, "one GetDevices for both trees")
			assert.same({ "2001", "2002", "2003" }, csv_sorted(lookups[1][1].DeviceIds))
			assert.same({ [2001] = "hue_light.c4z", [2002] = "hue_scene.c4z", [2003] = false }, state().driver_files)

			-- Cached: the next tick asks nothing and sends nothing.
			sent = {}
			tick()
			assert.same({}, sent)
			assert.equal(1, #c4.calls_to("GetDevices"))

			-- A scene device bound later is looked up alone and gets the cached scene bundle.
			project_device(2004, "hue_scene.c4z")
			bind_lights({ [2001] = "A", [2002] = "B", [2003] = "C", [2004] = "D" })
			server.requests = {}
			tick()
			assert.equal(1, #sent)
			assert.equal(2004, sent[1].device_id)
			assert.equal("scene", sent[1].params.tree)
			assert.equal("S1", sent[1].params.version)
			assert.same(server.scene_files, c4:JsonDecode(sent[1].params.files))
			lookups = c4.calls_to("GetDevices")
			assert.equal(2, #lookups)
			assert.equal("2004", lookups[2][1].DeviceIds)
			assert_said("scene version S1 forwarded to 1 newly bound scene device(s)")
			assert.same(plus(POLL, "POST /log"), server.requests, "no refetch of either bundle")
		end)

		it("sends a new scene version only to the scene devices and reports scene_version at once", function()
			project_device(2002, "hue_scene.c4z")
			bind_lights({ [2001] = "A", [2002] = "B" })
			start_synced()
			assert.equal("S1", devloop.tree_version("scene"))
			assert.same({ [2001] = "L1" }, state().light_forwarded)
			assert.same({ [2002] = "S1" }, state().scene_forwarded)

			server.scene_version, server.scene_files["driver.lua"] = "S2", SCENE_SRC .. " .. ' 2'"
			tick()
			assert.equal(1, #sent)
			assert.equal(2002, sent[1].device_id)
			assert.equal("DEV_RELOAD", sent[1].command)
			assert.equal("scene", sent[1].params.tree)
			assert.equal("S2", sent[1].params.version)
			assert.same(server.scene_files, c4:JsonDecode(sent[1].params.files))
			assert.is_false(sent[1].log_command)
			assert.equal("S2", devloop.tree_version("scene"))
			assert.equal("L1", devloop.light_version(), "the light tree is untouched")
			assert.same({ [2002] = "S2" }, state().scene_forwarded)
			assert.same({ "GET /manifest", "GET /manifest?tree=light", "GET /manifest?tree=scene",
				"GET /bundle?tree=scene", "GET /commands?after=0", "POST /log", "POST /report" }, server.requests,
				"fetched once for the new version; a heartbeat is due at once")
			assert.same({ "heartbeat" }, events())
			assert.equal("S2", last_report().scene_version)
			assert.equal("L1", last_report().light_version)
			assert.equal("v1", last_report().version)
			assert_said("scene version S2 forwarded to 1 scene device(s)")

			server.reports = {}
			server.commands = { { id = 1, type = "execute", command = "A" } }
			rawset(_G, "ExecuteCommand", function() end)
			tick()
			assert.equal("command_done", last_report().event)
			assert.equal("S2", last_report().scene_version)
		end)

		it("treats every bound device as a light when GetDevices fails", function()
			c4.GetDevices = function() error("not available") end
			bind_lights({ [2001] = "A" })
			devloop.start(HOST)
			serve()
			tick()
			assert.same({ 2001 }, sent_to("light"))
			assert.same({}, sent_to("scene"))
			assert.same({ [2001] = false }, state().driver_files)
			assert_said("light version L1 forwarded to 1 light device(s)")
			assert_said("scene version S1: no bound scene devices")
		end)

		it("skips a tree-less server instead of forwarding the bridge bundle", function()
			bind_lights({ [2001] = "A" })
			server.trees = false
			devloop.start(HOST)
			serve()
			tick()
			server.requests = {}
			tick()
			assert.same({}, sent)
			assert.is_nil(devloop.light_version())
			assert.is_nil(devloop.tree_version("scene"))
			assert.same(POLL, server.requests, "both tree manifests are still polled, so a restarted server is picked up")
			assert.equal(1, printed_count("no light tree"), "said once")
			assert.equal(1, printed_count("no scene tree"), "said once")
		end)

		it("says once when the server lacks the scene tree, keeps polling for it and picks it up later", function()
			project_device(2002, "hue_scene.c4z")
			bind_lights({ [2001] = "A", [2002] = "B" })
			server.scene_tree = false
			devloop.start(HOST)
			serve()
			tick()
			assert.same({ 2001 }, sent_to("light"))
			assert.same({}, sent_to("scene"))
			assert.equal("L1", devloop.tree_version("light"))
			assert.is_nil(devloop.tree_version("scene"))
			assert_said("server has no scene tree (HTTP 400); scene devices are not updated")

			server.requests = {}
			tick()
			assert.same(POLL, server.requests, "the scene manifest is still polled")
			assert_said("server has no scene tree (HTTP 400); scene devices are not updated")
			assert.equal(1, #sent)

			server.scene_tree = true
			server.requests = {}
			tick()
			assert.same({ 2002 }, sent_to("scene"))
			assert.equal("S1", sent[2].params.version)
			assert.same(server.scene_files, c4:JsonDecode(sent[2].params.files))
			assert.equal("S1", devloop.tree_version("scene"))
			assert.same({ "GET /manifest", "GET /manifest?tree=light", "GET /manifest?tree=scene",
				"GET /bundle?tree=scene", "GET /commands?after=0", "POST /log", "POST /report" }, server.requests)
			assert_said("scene version S1 forwarded to 1 scene device(s)")
		end)

		it("keeps the loop going when SendToDevice raises", function()
			bind_lights({ [2001] = "A", [2002] = "B" })
			c4.SendToDevice = function(_, device_id)
				if device_id == 2002 then error("device gone") end
				table.insert(sent, { device_id = device_id })
			end
			devloop.start(HOST)
			serve()
			tick()
			assert.equal(1, #sent)
			assert.equal("L1", devloop.light_version())
			assert_said("light version L1 forwarded to 1 light device(s), 1 failed")
			assert.equal("GET /commands?after=0", server.requests[9])
			assert.same({ [2001] = "L1", [2002] = "L1" }, state().light_forwarded,
				"a failed send is recorded too, so it is not retried at this version")
			tick()
			assert.equal(1, #sent)
		end)
	end)

	describe("own_tree", function()
		it("reads the forwarded tree off the driver file name", function()
			assert.equal("bridge", devloop.own_tree())
			c4.driver_file = "hue_light.c4z"
			assert.equal("light", devloop.own_tree())
			c4.driver_file = "hue_scene.c4z"
			assert.equal("scene", devloop.own_tree())
			c4.driver_file = "other.c4z"
			assert.is_nil(devloop.own_tree())
		end)
	end)

	describe("apply_forwarded (device side)", function()
		local function forwarded(version, files, tree)
			return devloop.apply_forwarded({ tree = tree, version = version, files = json(files) })
		end

		before_each(function()
			c4.driver_file = "hue_light.c4z"   -- the receiver is a light unless a spec says otherwise
		end)

		it("reloads from the forwarded bundle without start() ever being called", function()
			rawset(_G, "OnDriverDestroyed", function() table.insert(calls(), "old destroyed") end)
			package.loaded["light.x"] = { old = true }
			package.loaded["common.dispatch"] = { old = true }
			assert.is_true(forwarded("L1", { ["driver.lua"] = DRIVER_SRC }, "light"))
			assert.same({ "old destroyed", "chunk", "init:DIT_UPDATING", "late:DIT_UPDATING" }, calls())
			assert.equal("loaded", rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.is_nil(package.loaded["light.x"])
			assert.is_nil(package.loaded["common.dispatch"])
			assert.equal(devloop, package.loaded["common.devloop"], "never cleared")
			assert.equal("L1", devloop.version())
			assert.is_false(devloop.running())
			assert.equal(0, #c4.transfers, "a light never contacts the server")
			assert.equal("devloop: light reload complete: version L1", printed[#printed])
		end)

		it("serves light.* modules from the forwarded bundle", function()
			assert.is_true(forwarded("L1", {
				["driver.lua"] = "DEVLOOP_TEST_MARK = require('light.state')",
				["light/state.lua"] = "return { from_bundle = true }",
			}, "light"))
			assert.is_true(rawget(_G, "DEVLOOP_TEST_MARK").from_bundle)
			assert.equal(state().loader, package.loaders[1])
		end)

		it("skips a bundle for the other tree and leaves the running code alone", function()
			rawset(_G, "OnDriverDestroyed", function() table.insert(calls(), "destroyed") end)
			assert.is_false(forwarded("S1", { ["driver.lua"] = SCENE_SRC }, "scene"))
			assert.equal("devloop: light reload skipped: DEV_RELOAD carries the scene tree", printed[#printed])
			assert.same({}, calls(), "nothing was torn down")
			assert.is_nil(rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.is_nil(devloop.version())

			-- Its own tree is applied, named or not (an older bridge forwards without one).
			assert.is_true(forwarded("L1", { ["driver.lua"] = DRIVER_SRC }, "light"))
			assert.equal("L1", devloop.version())
			assert.is_true(forwarded("L2", { ["driver.lua"] = DRIVER_SRC }))
			assert.equal("L2", devloop.version())
			assert.equal("devloop: light reload complete: version L2", printed[#printed])
		end)

		it("on a scene device applies the scene tree and skips the light tree", function()
			c4.driver_file = "hue_scene.c4z"
			assert.is_false(forwarded("L1", { ["driver.lua"] = LIGHT_SRC }, "light"))
			assert.equal("devloop: scene reload skipped: DEV_RELOAD carries the light tree", printed[#printed])
			assert.is_nil(devloop.version())

			assert.is_true(forwarded("S1", {
				["driver.lua"] = "DEVLOOP_TEST_MARK = require('scene.x')",
				["scene/x.lua"] = "return 'scene loaded'",
			}, "scene"))
			assert.equal("scene loaded", rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.equal("S1", devloop.version())
			assert.equal("devloop: scene reload complete: version S1", printed[#printed])
		end)

		it("applies any tree when its own driver file is not a hue_*.c4z", function()
			c4.driver_file = "other.c4z"
			assert.is_true(forwarded("S1", { ["driver.lua"] = SCENE_SRC }, "scene"))
			assert.equal("scene loaded", rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.equal("devloop: device reload complete: version S1", printed[#printed])
		end)

		it("prints the failure for a broken bundle and stays usable", function()
			assert.is_false(forwarded("L2", { ["driver.lua"] = "function (" }, "light"))
			assert.truthy(printed[#printed]:find("^devloop: light reload failed: "))
			assert.truthy(printed[#printed]:find("driver.lua", 1, true))
			assert.equal("L2", devloop.version())

			assert.is_false(forwarded("L3", { ["driver.lua"] = "error('boom')" }, "light"))
			assert.truthy(printed[#printed]:find("boom", 1, true))

			assert.is_true(forwarded("L4", { ["driver.lua"] = DRIVER_SRC }, "light"))
			assert.equal("L4", devloop.version())
			assert.equal("devloop: light reload complete: version L4", printed[#printed])
		end)

		it("rejects params without a decodable files object", function()
			rawset(_G, "OnDriverDestroyed", function() table.insert(calls(), "destroyed") end)
			assert.is_false(devloop.apply_forwarded({ tree = "light", version = "L1", files = "not json" }))
			assert.truthy(printed[#printed]:find("^devloop: light reload failed: files param"))
			assert.is_false(devloop.apply_forwarded({ tree = "light", version = "L1" }))
			assert.is_false(devloop.apply_forwarded(nil))
			assert.same({}, calls(), "nothing was torn down")
			assert.is_nil(devloop.version())
		end)

		it("works as a dispatch command handler", function()
			package.loaded["common.dispatch"] = nil
			local dispatch = require("common.dispatch")
			dispatch.commands["DEV_RELOAD"] = devloop.apply_forwarded
			dispatch.execute_command("DEV_RELOAD",
				{ tree = "light", version = "L1", files = json({ ["driver.lua"] = DRIVER_SRC }) })
			assert.equal("loaded", rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.equal("L1", devloop.version())
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
			assert.same(plus(POLL, "POST /report", "POST /report", "POST /log"), server.requests)
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
			assert.same({ "startup", "reload", "heartbeat" }, events())
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
			assert.same(plus(POLL, "POST /log"), server.requests)
			assert.truthy(server.logs[1].lines[1].line:find("unreachable", 1, true))
		end)
	end)
end)
