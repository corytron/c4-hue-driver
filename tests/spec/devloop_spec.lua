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

-- The dev key a dev package carries as common/devkey.lua (tools/build.sh
-- --dev), installed here through package.preload; another build's key; and
-- what the Python side computes for them (tools/tests/test_devserver.py pins
-- the same three values, so the two implementations cannot drift apart).
local TEST_KEY = string.rep("0123456789abcdef", 4)
local OTHER_KEY = string.rep("fedcba9876543210", 4)
local DOMAIN = "c4-hue-devloop/1\n"
local TEST_FINGERPRINT = "eccabde32b59a017"
local SHARED_PAYLOAD = '{"files":{"driver.lua":"return 1"},"tree":"light","version":"v1"}'
local SHARED_BUNDLE_MAC = "ca15fb64cce6d849bd18e1f8b4f4303d5f45f1ca103867d4a8b7a55c8afe81c0"

-- Modules a reload clears; the other specs' instances are saved around each test.
local function is_driver_module(name)
	return name:match("^bridge%.") or name:match("^common%.") or name:match("^light%.") or name:match("^scene%.")
end

-- A fresh common.devloop whose package carries `key` (nil: none at all).
local function load_devloop(key)
	package.loaded["common.devkey"] = nil
	package.preload["common.devkey"] = key and function() return key end or nil
	package.loaded["common.devloop"] = nil
	rawset(_G, "__DEVLOOP", nil)
	return require("common.devloop")
end

local function forget_key()
	package.preload["common.devkey"] = nil
	package.loaded["common.devkey"] = nil
end

-- How many entries of `list` contain `text`.
local function count_containing(list, text)
	local n = 0
	for _, line in ipairs(list) do
		if tostring(line):find(text, 1, true) then n = n + 1 end
	end
	return n
end

-- Whether `text` occurs in any key or string value anywhere inside `value`.
local function holds(value, text, seen)
	if type(value) == "string" then return value:find(text, 1, true) ~= nil end
	if type(value) ~= "table" then return false end
	seen = seen or {}
	if seen[value] then return false end
	seen[value] = true
	for k, v in pairs(value) do
		if holds(k, text, seen) or holds(v, text, seen) then return true end
	end
	return false
end

describe("common.devloop", function()
	local devloop, c4, server, printed, real_print, saved_modules, sent
	local HOST = "devvm:8080"

	-- An idle tick's requests: every manifest, then the commands (recorded
	-- without their nonce).
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

	-- The MAC a server holding `key` puts on `payload` under `label`.
	local function mac(key, label, payload)
		return devloop.hmac_sha256(key, DOMAIN .. label .. "\n" .. payload)
	end

	-- `list` followed by the extra items.
	local function plus(list, ...)
		local out = {}
		for _, item in ipairs(list) do out[#out + 1] = item end
		for i = 1, select("#", ...) do out[#out + 1] = (select(i, ...)) end
		return out
	end

	-- The scripted dev server: what it serves, how it signs, what it received.
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
			key = TEST_KEY,      -- what it signs with
			keys = {},           -- what = key: another key for "bridge", "light", "scene" or "commands"
			unsigned = {},       -- what = true: plain JSON there, as a server from before signing
			tamper = {},         -- what = function(payload) -> payload changed after signing
			swap = {},           -- tree = other tree: that tree's (correctly signed) bundle served instead
			echo_nonce = nil,    -- a nonce to answer with instead of the one asked for (a replay)
			all_commands = false, -- true: every queued command whatever `after` says
			commands = {},
			requests = {},       -- "METHOD /path" in order, without the nonce
			nonces = {},         -- the nonce of every GET /commands
			payloads = {},       -- tree = the last bundle payload served for it
			reports = {},        -- decoded POST /report bodies
			logs = {},           -- decoded POST /log bodies
			manifest_error = nil,
			log_error = nil,
		}
	end

	-- What the server answers for `what` ("bridge", "light", "scene" or
	-- "commands"): the envelope, or plain JSON when told to be unsigned.
	local function served(what, label, payload)
		if server.unsigned[what] then return payload end
		local body = mac(server.keys[what] or server.key, label, payload) .. "\n" .. payload
		if server.tamper[what] then
			body = body:sub(1, 65) .. server.tamper[what](payload)
		end
		return body
	end

	-- The tree a request names, as the server sees it: nil before trees
	-- existed (the query is ignored), "bridge" when none is named.
	local function tree_of(path)
		if not server.trees then return nil end
		return path:match("tree=(%w+)") or "bridge"
	end

	local function route(t)
		local path = t.url:match("^http://[^/]+(/.*)$")
		table.insert(server.requests, t.method .. " " .. (path:gsub("&nonce=%x+", "")))
		local base = path:match("^[^?]+")
		if base == "/manifest" or base == "/bundle" then
			if base == "/manifest" and server.manifest_error then
				return t:done(server.manifest_error, "Failed to connect")
			end
			local tree = tree_of(path)
			if tree == "scene" and not server.scene_tree then
				return t:respond(400, json({ error = "unknown tree 'scene' (bridge or light)" }))
			end
			local function version_of(name)
				return (name ~= nil and name ~= "bridge") and server[name .. "_version"] or server.version
			end
			if base == "/manifest" then
				return t:respond(200, json({ version = version_of(tree), tree = tree, files = {}, server_time = 1 }))
			end
			local what = tree or "bridge"
			local source = server.swap[what] or what
			local files = source ~= "bridge" and server[source .. "_files"] or server.files
			local payload = json({ version = version_of(source), tree = tree and source or nil, files = files })
			server.payloads[what] = payload
			return t:respond(200, served(what, "bundle", payload))
		elseif base == "/commands" then
			local after = tonumber(path:match("after=(%d+)"))
			local nonce = path:match("nonce=(%x+)")
			table.insert(server.nonces, nonce)
			local pending = {}
			for _, cmd in ipairs(server.commands) do
				if server.all_commands or cmd.id > after then table.insert(pending, cmd) end
			end
			return t:respond(200, served("commands", "commands",
				json({ nonce = server.echo_nonce or nonce, commands = pending })))
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

	-- A forwarded DEV_RELOAD's files, after checking that it carries the
	-- server's payload unchanged with a MAC this build's key accepts.
	local function forwarded_files(msg)
		assert.is_string(msg.params.bundle, "the signed payload travels as JSON text")
		assert.is_nil(devloop.check_signature("bundle", msg.params.bundle, msg.params.mac))
		assert.equal(mac(TEST_KEY, "bundle", msg.params.bundle), msg.params.mac)
		assert.is_nil(msg.params.files, "no unsigned form")
		local payload = c4:JsonDecode(msg.params.bundle)
		assert.equal(msg.params.tree, payload.tree)
		assert.equal(msg.params.version, payload.version)
		return payload.files
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
		return count_containing(printed, text)
	end

	-- The lines in the loop's buffer, not yet shipped.
	local function buffered()
		local out = {}
		for _, entry in ipairs(state().log) do out[#out + 1] = entry.line end
		return out
	end

	-- A fresh module instance (a Director restart), the old one stopped and
	-- its bundle loader removed.
	local function reload_module(key)
		local S = state()
		devloop.stop()
		for i = #package.loaders, 1, -1 do
			if S and package.loaders[i] == S.loader then table.remove(package.loaders, i) end
		end
		devloop = load_devloop(key)
	end

	-- Every line the server got, every report as JSON and every printed line.
	local function everything_said()
		local out = {}
		for _, line in ipairs(printed) do out[#out + 1] = line end
		for _, body in ipairs(server.logs) do
			for _, entry in ipairs(body.lines) do out[#out + 1] = entry.line end
		end
		for _, r in ipairs(server.reports) do out[#out + 1] = json(r) end
		return out
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
		devloop = load_devloop(TEST_KEY)
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
		forget_key()
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
			assert.equal("nil", r.sandbox.bit)
			assert.equal("Lua (no C4:HMAC)", r.sandbox.hmac, "the fake runtime has no C4:HMAC")
			assert.equal(TEST_FINGERPRINT, r.key_fingerprint)
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

		it("keeps the key out of the shared state, the reports and the log", function()
			start_synced()
			server.commands = { { id = 1, type = "execute", command = "A" } }
			rawset(_G, "ExecuteCommand", function() end)
			print("a line")
			tick()
			c4.now_ms = c4.now_ms + devloop.HEARTBEAT_MS
			tick()
			assert.is_false(holds(state(), TEST_KEY), "not anywhere in _G.__DEVLOOP")
			assert.is_false(holds(Properties, TEST_KEY))
			assert.equal(0, count_containing(everything_said(), TEST_KEY))
			assert.truthy(#server.reports > 0 and #server.logs > 0)
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
			assert.equal(TEST_FINGERPRINT, last_report().key_fingerprint, "every report names the key")
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

		it("keeps the key it was loaded with, whatever the bundle carries", function()
			start_synced()
			-- A bundle that brings its own common/devkey.lua (the server never
			-- serves one) cannot change what the loop verifies with.
			server.version = "v2"
			server.files["common/devkey.lua"] = "return '" .. OTHER_KEY .. "'"
			server.files["driver.lua"] = DRIVER_SRC .. "\nrequire('common.devkey')"
			tick()
			assert.equal("v2", devloop.version())
			assert.equal(TEST_FINGERPRINT, devloop.key_fingerprint())
			server.version, server.key = "v3", OTHER_KEY
			tick()
			assert.equal("v2", devloop.version(), "a bundle signed with the other key is still refused")
		end)
	end)

	describe("signed bundles (bridge side)", function()
		it("refuses an unsigned bundle with one line and a refused report, and keeps the running code", function()
			rawset(_G, "OnDriverDestroyed", function() table.insert(calls(), "destroyed") end)
			server.unsigned.bridge = true
			devloop.start(HOST)
			serve()
			tick()
			assert.same({}, calls(), "nothing torn down, nothing compiled")
			assert.is_nil(rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.is_nil(devloop.version())
			assert_said("bridge bundle v1 refused: not signed")
			assert.same({ "startup", "refused", "heartbeat" }, events())
			local r = server.reports[2]
			assert.equal("bridge", r.tree)
			assert.equal("v1", r.refused_version)
			assert.equal("not signed", r.error)
			assert.is_nil(r.version, "still the .c4z's own code")
			-- The rest of the tick goes on: the device trees and the commands.
			assert.same({ "POST /report", "GET /manifest", "GET /bundle", "POST /report",
				"GET /manifest?tree=light", "GET /bundle?tree=light",
				"GET /manifest?tree=scene", "GET /bundle?tree=scene",
				"GET /commands?after=0", "POST /log", "POST /report" }, server.requests)
		end)

		it("refuses a bundle whose file was changed after signing", function()
			start_synced()
			server.version = "v2"
			server.files["driver.lua"] = DRIVER_SRC .. "\nDEVLOOP_TEST_MARK = 'genuine'"
			server.tamper.bridge = function(payload) return (payload:gsub("genuine", "planted")) end
			tick()
			assert.equal("v1", devloop.version())
			assert.equal("loaded", rawget(_G, "DEVLOOP_TEST_MARK"))
			assert_said("bridge bundle v2 refused: signature mismatch")
			assert.equal("refused", server.reports[1].event)
		end)

		it("refuses a bundle signed with another key", function()
			start_synced()
			server.version, server.keys.bridge = "v2", OTHER_KEY
			tick()
			assert.equal("v1", devloop.version())
			assert_said("bridge bundle v2 refused: signature mismatch")
		end)

		it("refuses a correctly signed bundle of another tree", function()
			server.swap.bridge = "light"
			devloop.start(HOST)
			serve()
			tick()
			assert.is_nil(devloop.version())
			assert.is_nil(rawget(_G, "DEVLOOP_TEST_MARK"))
			assert_said("bridge bundle v1 refused: signed for the light tree")
		end)

		it("refuses a body that is not an envelope, and a MAC that is not 64 hex characters", function()
			assert.equal("not signed", devloop.check_signature("bundle", "{}", nil))
			assert.equal("not signed", devloop.check_signature("bundle", "{}", "abc"))
			assert.equal("not signed", devloop.check_signature("bundle", "{}", string.rep("g", 64)))
			assert.equal("not signed", devloop.check_signature("bundle", nil, string.rep("a", 64)))
			assert.equal("signature mismatch", devloop.check_signature("bundle", "{}", string.rep("a", 64)))
			local good = mac(TEST_KEY, "bundle", "{}")
			assert.is_nil(devloop.check_signature("bundle", "{}", good))
			assert.is_nil(devloop.check_signature("bundle", "{}", good:upper()), "hex in either case")
			assert.equal("signature mismatch", devloop.check_signature("commands", "{}", good),
				"a MAC made for one label is no good for another")
			assert.same({ "{}", good }, { devloop.split_envelope(good .. "\n{}") })
			assert.same({ "{}" }, { devloop.split_envelope("{}") })
		end)

		it("does not fetch a refused version again for a minute, then retries it silently", function()
			server.unsigned.bridge = true
			devloop.start(HOST)
			serve()
			tick()
			assert_said("bridge bundle v1 refused: not signed")
			server.requests, server.reports = {}, {}
			tick()
			assert.same(POLL, server.requests, "no GET /bundle within REFUSED_RETRY_MS, and nothing new to say")

			c4.now_ms = c4.now_ms + devloop.REFUSED_RETRY_MS
			server.requests, server.reports = {}, {}
			tick()
			assert.equal("GET /bundle", server.requests[2])
			assert.same({ "heartbeat" }, events(), "a refusal said before is not reported again")
			assert_said("bridge bundle v1 refused: not signed")

			-- Signed again (the server restarted with its key): the next retry loads it.
			server.unsigned.bridge = nil
			c4.now_ms = c4.now_ms + devloop.REFUSED_RETRY_MS
			tick()
			assert.equal("v1", devloop.version())
			assert.equal("loaded", rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.is_nil(state().refused.bridge)
		end)

		it("fetches a new version at once, even right after a refusal", function()
			start_synced()
			server.version, server.unsigned.bridge = "v2", true
			tick()
			assert_said("bridge bundle v2 refused: not signed")
			server.version, server.unsigned.bridge = "v3", nil
			server.requests = {}
			tick()
			assert.equal("GET /bundle", server.requests[2])
			assert.equal("v3", devloop.version())
		end)

		it("retries a refused version at once after a reload command", function()
			server.unsigned.bridge = true
			devloop.start(HOST)
			serve()
			tick()
			assert.is_nil(devloop.version())
			server.unsigned.bridge = nil
			server.commands = { { id = 1, type = "reload" } }
			server.reports = {}
			tick()
			assert.equal("v1", devloop.version())
			assert.same({ "reload", "command_done" }, events())
			assert.is_nil(last_report().error)
		end)

		it("never says or reports the MAC it expected", function()
			start_synced()
			server.version, server.keys.bridge = "v2", OTHER_KEY
			tick()
			c4.now_ms = c4.now_ms + devloop.HEARTBEAT_MS
			tick()
			local expected = mac(TEST_KEY, "bundle", server.payloads.bridge)
			assert.equal(64, #expected)
			assert.equal(0, count_containing(everything_said(), expected))
			assert.equal(0, count_containing(everything_said(), expected:sub(1, 16)))
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
				assert.same(server.light_files, forwarded_files(msg))
				assert.equal(server.payloads.light, msg.params.bundle, "the server's payload, unchanged")
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
			assert.same(server.light_files, forwarded_files(sent[1]))
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
				assert.same(server.light_files, forwarded_files(msg))
			end
			assert_said("light version L1 forwarded to 2 newly bound light device(s)")
			assert.same(plus(POLL, "POST /log"), server.requests, "the held bundles are used; no second fetch")
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
			assert.same(server.light_files, forwarded_files(sent[1]))
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
				assert.same(server.light_files, forwarded_files(msg))
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
					assert.same(server.scene_files, forwarded_files(msg))
				else
					assert.equal("L1", msg.params.version)
					assert.same(server.light_files, forwarded_files(msg))
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

			-- Held: the next tick asks nothing and sends nothing.
			sent = {}
			tick()
			assert.same({}, sent)
			assert.equal(1, #c4.calls_to("GetDevices"))

			-- A scene device bound later is looked up alone and gets the held scene bundle.
			project_device(2004, "hue_scene.c4z")
			bind_lights({ [2001] = "A", [2002] = "B", [2003] = "C", [2004] = "D" })
			server.requests = {}
			tick()
			assert.equal(1, #sent)
			assert.equal(2004, sent[1].device_id)
			assert.equal("scene", sent[1].params.tree)
			assert.equal("S1", sent[1].params.version)
			assert.same(server.scene_files, forwarded_files(sent[1]))
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
			assert.same(server.scene_files, forwarded_files(sent[1]))
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
			assert.same(server.scene_files, forwarded_files(sent[2]))
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

		it("forwards nothing from a light bundle that does not verify, says so once and reports it", function()
			bind_lights({ [2001] = "A" })
			server.keys.light = OTHER_KEY
			devloop.start(HOST)
			serve()
			tick()
			assert.same({}, sent)
			assert.is_nil(devloop.light_version())
			assert_said("light bundle L1 refused: signature mismatch")
			assert.equal(1, #c4.calls_to("SetTimer"))
			local refused
			for _, r in ipairs(server.reports) do
				if r.event == "refused" then refused = r end
			end
			assert.equal("light", refused.tree)
			assert.equal("L1", refused.refused_version)

			-- Within REFUSED_RETRY_MS it is not fetched again; a new, good version goes out at once.
			server.requests = {}
			tick()
			assert.same(POLL, server.requests)
			server.light_version, server.keys.light = "L2", nil
			tick()
			assert.same({ 2001 }, sent_to("light"))
			assert.equal("L2", sent[1].params.version)
			assert.same(server.light_files, forwarded_files(sent[1]))
		end)

		it("forwards nothing from an unsigned scene bundle or one signed for the light tree", function()
			project_device(2002, "hue_scene.c4z")
			bind_lights({ [2002] = "B" })
			server.unsigned.scene = true
			devloop.start(HOST)
			serve()
			tick()
			assert.same({}, sent)
			assert_said("scene bundle S1 refused: not signed")

			server.unsigned.scene, server.swap.scene = nil, "light"
			server.scene_version = "S2"
			tick()
			assert.same({}, sent)
			assert_said("scene bundle S2 refused: signed for the light tree")
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
		-- What a bridge forwards: the server's signed payload for `signed_tree`
		-- (default `tree`) and its MAC, with `tree` as the unsigned hint
		-- (none when `tree` is nil, as an older bridge sends).
		local function signed_params(version, files, tree, opts)
			opts = opts or {}
			local payload = json({ version = version, tree = opts.signed_tree or tree or "light", files = files })
			return { tree = tree, version = version, bundle = payload, mac = mac(opts.key or TEST_KEY, "bundle", payload) }
		end

		local function forwarded(version, files, tree, opts)
			return devloop.apply_forwarded(signed_params(version, files, tree, opts))
		end

		before_each(function()
			c4.driver_file = "hue_light.c4z"   -- the receiver is a light unless a spec says otherwise
		end)

		it("reloads from the forwarded bundle without start() ever being called", function()
			rawset(_G, "OnDriverDestroyed", function() table.insert(calls(), "old destroyed") end)
			package.loaded["light.x"] = { old = true }
			package.loaded["common.dispatch"] = { old = true }
			assert.same({ true, "L1" }, { forwarded("L1", { ["driver.lua"] = DRIVER_SRC }, "light") })
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
			assert.same({ false, "skipped" }, { forwarded("S1", { ["driver.lua"] = SCENE_SRC }, "scene") })
			assert.equal("devloop: light reload skipped: DEV_RELOAD carries the scene tree", printed[#printed])
			assert.same({}, calls(), "nothing was torn down")
			assert.is_nil(rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.is_nil(devloop.version())

			-- Its own tree is applied, named or not (an older bridge forwards without one).
			assert.is_true(forwarded("L1", { ["driver.lua"] = DRIVER_SRC }, "light"))
			assert.equal("L1", devloop.version())
			assert.is_true(forwarded("L2", { ["driver.lua"] = DRIVER_SRC }, nil, { signed_tree = "light" }))
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

		it("applies either device tree when its own driver file is not a hue_*.c4z", function()
			c4.driver_file = "other.c4z"
			assert.is_true(forwarded("S1", { ["driver.lua"] = SCENE_SRC }, "scene"))
			assert.equal("scene loaded", rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.equal("devloop: device reload complete: version S1", printed[#printed])
		end)

		it("prints the failure for a broken bundle and stays usable", function()
			assert.same({ false, "failed" }, { forwarded("L2", { ["driver.lua"] = "function (" }, "light") })
			assert.truthy(printed[#printed]:find("^devloop: light reload failed: "))
			assert.truthy(printed[#printed]:find("driver.lua", 1, true))
			assert.equal("L2", devloop.version())

			assert.is_false(forwarded("L3", { ["driver.lua"] = "error('boom')" }, "light"))
			assert.truthy(printed[#printed]:find("boom", 1, true))

			assert.is_true(forwarded("L4", { ["driver.lua"] = DRIVER_SRC }, "light"))
			assert.equal("L4", devloop.version())
			assert.equal("devloop: light reload complete: version L4", printed[#printed])
		end)

		it("fails cleanly on a signed payload that does not decode", function()
			rawset(_G, "OnDriverDestroyed", function() table.insert(calls(), "destroyed") end)
			local payload = "not json"
			assert.same({ false, "failed" }, { devloop.apply_forwarded({ tree = "light", version = "L1", bundle = payload,
				mac = mac(TEST_KEY, "bundle", payload) }) })
			assert.equal("devloop: light reload failed: the signed bundle does not decode", printed[#printed])
			assert.same({}, calls(), "nothing was torn down")
			assert.is_nil(devloop.version())
		end)

		it("refuses the old unsigned form, a bundle without a MAC and no params at all", function()
			rawset(_G, "OnDriverDestroyed", function() table.insert(calls(), "destroyed") end)
			assert.same({ false, "refused", "not signed" }, { devloop.apply_forwarded({ tree = "light", version = "L1",
				files = json({ ["driver.lua"] = DRIVER_SRC }) }) })
			assert.equal("devloop: light reload refused: not signed", printed[#printed])
			local unsigned = signed_params("L1", { ["driver.lua"] = DRIVER_SRC }, "light")
			unsigned.mac = nil
			assert.is_false(devloop.apply_forwarded(unsigned))
			assert.is_false(devloop.apply_forwarded(nil))
			assert.same({}, calls(), "nothing was torn down")
			assert.is_nil(devloop.version())
			assert.is_nil(rawget(_G, "DEVLOOP_TEST_MARK"))
		end)

		it("refuses a DEV_RELOAD whose bundle was changed after signing, tearing nothing down", function()
			rawset(_G, "OnDriverDestroyed", function() table.insert(calls(), "destroyed") end)
			local params = signed_params("L1", { ["driver.lua"] = DRIVER_SRC }, "light")
			params.bundle = params.bundle:gsub("loaded", "owned")
			assert.same({ false, "refused", "signature mismatch" }, { devloop.apply_forwarded(params) })
			assert.equal("devloop: light reload refused: signature mismatch", printed[#printed])
			assert.same({}, calls())
			assert.is_nil(devloop.version())
		end)

		it("refuses a bundle signed with another key, as any other driver in the project would send", function()
			assert.same({ false, "refused", "signature mismatch" },
				{ forwarded("L1", { ["driver.lua"] = DRIVER_SRC }, "light", { key = OTHER_KEY }) })
			assert.is_nil(rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.is_nil(devloop.version())
		end)

		it("goes by the signed tree, not the tree param", function()
			assert.same({ false, "refused", "signed for the scene tree" },
				{ forwarded("S1", { ["driver.lua"] = SCENE_SRC }, "light", { signed_tree = "scene" }) })
			assert.equal("devloop: light reload refused: signed for the scene tree", printed[#printed])
			assert.is_nil(rawget(_G, "DEVLOOP_TEST_MARK"))
		end)

		it("refuses the bridge's own bundle, wherever it comes from", function()
			assert.same({ false, "refused", "signed for the bridge tree" },
				{ forwarded("v1", { ["driver.lua"] = DRIVER_SRC }, "light", { signed_tree = "bridge" }) })
			c4.driver_file = "other.c4z"
			assert.is_false(forwarded("v1", { ["driver.lua"] = DRIVER_SRC }, nil, { signed_tree = "bridge" }))
			assert.is_nil(rawget(_G, "DEVLOOP_TEST_MARK"))
		end)

		it("loads at the signed version, whatever the version param says", function()
			local params = signed_params("L7", { ["driver.lua"] = DRIVER_SRC }, "light")
			params.version = "L9"
			assert.same({ true, "L7" }, { devloop.apply_forwarded(params) })
			assert.equal("L7", devloop.version())
		end)

		it("never says the MAC it expected", function()
			local params = signed_params("L1", { ["driver.lua"] = DRIVER_SRC }, "light", { key = OTHER_KEY })
			devloop.apply_forwarded(params)
			local expected = mac(TEST_KEY, "bundle", params.bundle)
			assert.equal("devloop: light reload refused: signature mismatch", printed[#printed])
			assert.equal(0, count_containing(printed, expected:sub(1, 16)))
			assert.equal(0, count_containing(buffered(), expected:sub(1, 16)))
		end)

		it("works as a dispatch command handler", function()
			package.loaded["common.dispatch"] = nil
			local dispatch = require("common.dispatch")
			dispatch.commands["DEV_RELOAD"] = devloop.apply_forwarded
			dispatch.execute_command("DEV_RELOAD", signed_params("L1", { ["driver.lua"] = DRIVER_SRC }, "light"))
			assert.equal("loaded", rawget(_G, "DEVLOOP_TEST_MARK"))
			assert.equal("L1", devloop.version())
		end)

		it("through the device's handler, a refusal is forwarded as a refusal and nothing reloads", function()
			local lines = {}
			local log = {
				debug = function() end,
				always = function(fmt, ...) lines[#lines + 1] = "always " .. string.format(fmt, ...) end,
				warn = function(fmt, ...) lines[#lines + 1] = "warn " .. string.format(fmt, ...) end,
			}
			local handler = devloop.reload_handler(log, "light")
			handler(signed_params("L1", { ["driver.lua"] = DRIVER_SRC }, "light", { key = OTHER_KEY }))
			assert.same({ "warn light reload refused (signature mismatch); see this light's Lua output" }, lines)
			assert.is_nil(rawget(_G, "DEVLOOP_TEST_MARK"))

			handler(signed_params("L2", { ["driver.lua"] = DRIVER_SRC }, "light"))
			assert.equal("always light reloaded to version L2", lines[2])
			assert.equal("loaded", rawget(_G, "DEVLOOP_TEST_MARK"))
		end)
	end)

	-- The two pieces a device driver takes from this module through
	-- common.device: its HUE_LOG sink and its DEV_RELOAD handler. The drivers'
	-- specs pin both end to end; this is the module's own contract.
	describe("forward_logs (device side)", function()
		local log, seen, bridge, rid

		-- A stand-in for the driver's common.log: only the sink matters here.
		before_each(function()
			seen = {}
			log = { sink = function(line) seen[#seen + 1] = line end }
			bridge, rid = 15, "r1"
		end)

		local function install()
			return devloop.forward_logs(log, "Hue Test", function() return bridge end, function() return rid end)
		end

		it("forwards its own non-debug lines as HUE_LOG, feeding the previous sink first", function()
			install()
			log.sink("[WARN] Hue Test: something odd")
			log.sink("Hue Test: diagnostic")
			log.sink("[DEBUG] Hue Test: noise")
			log.sink("[WARN] Hue Bridge: another driver's line")
			log.sink("plain print output")
			assert.same({ "[WARN] Hue Test: something odd", "Hue Test: diagnostic", "[DEBUG] Hue Test: noise",
				"[WARN] Hue Bridge: another driver's line", "plain print output" }, seen, "everything still reaches the sink")
			assert.same({
				{ device_id = 15, command = "HUE_LOG", params = { rid = "r1", line = "[WARN] Hue Test: something odd" },
					allow_empty = false, log_command = false, nargs = 5 },
				{ device_id = 15, command = "HUE_LOG", params = { rid = "r1", line = "Hue Test: diagnostic" },
					allow_empty = false, log_command = false, nargs = 5 },
			}, sent)
		end)

		it("omits the rid while the device has none", function()
			install()
			rid = nil
			log.sink("[WARN] Hue Test: no rid yet")
			assert.same({ line = "[WARN] Hue Test: no rid yet" }, sent[1].params)
		end)

		it("keeps the newest LOG_BUFFER lines while the bridge is unknown and sends them on flush, in order", function()
			local flush = install()
			bridge = nil
			for i = 1, devloop.LOG_BUFFER + 5 do
				log.sink(string.format("[INFO] Hue Test: line %d", i))
			end
			assert.same({}, sent, "nowhere to send yet")
			bridge = 15
			flush()
			assert.equal(devloop.LOG_BUFFER, #sent)
			assert.equal("[INFO] Hue Test: line 6", sent[1].params.line)
			assert.equal("[INFO] Hue Test: line 35", sent[#sent].params.line)
			flush()
			assert.equal(devloop.LOG_BUFFER, #sent, "the buffer is spent")
		end)

		it("says a failing send once per streak through the print captured at install, never through the sink", function()
			install()
			local later = {}
			rawset(_G, "print", function(...) later[#later + 1] = table.concat({ ... }, " ") end)
			c4.SendToDevice = function() error("Director says no") end
			log.sink("[WARN] Hue Test: one")
			log.sink("[WARN] Hue Test: two")
			assert.same({}, later, "not the print of the moment")
			assert.equal(1, #printed)
			assert.truthy(printed[1]:find("^%[WARN%] Hue Test: log forwarding to the bridge failed: .*Director says no"))
			assert.same({ "[WARN] Hue Test: one", "[WARN] Hue Test: two" }, seen, "the sink saw only the lines")

			c4.SendToDevice = function(_, device_id, command, params) table.insert(sent, { device_id = device_id,
				command = command, params = params }) end
			log.sink("[WARN] Hue Test: three")
			c4.SendToDevice = function() error("again") end
			log.sink("[WARN] Hue Test: four")
			assert.equal(2, #printed, "a new streak is said again")
		end)
	end)

	describe("reload_handler (device side)", function()
		local log, lines, got

		before_each(function()
			lines = {}
			local function keep(level)
				return function(fmt, ...) lines[#lines + 1] = level .. " " .. string.format(fmt, ...) end
			end
			log = { debug = keep("debug"), always = keep("always"), warn = keep("warn") }
			got = nil
			devloop.apply_forwarded = function(params)
				got = params
				if params.ok == true then return true, params.signed_version end
				return false, params.outcome, params.why
			end
		end)

		it("applies its own tree's bundle and logs the version always", function()
			local handler = devloop.reload_handler(log, "light")
			handler({ tree = "light", version = "L1", bundle = "{}", ok = true })
			assert.same({ tree = "light", version = "L1", bundle = "{}", ok = true }, got)
			assert.same({ "always light reloaded to version L1" }, lines)
		end)

		it("names the version it loaded, the signed one, over the version param", function()
			local handler = devloop.reload_handler(log, "light")
			handler({ tree = "light", version = "hint", bundle = "{}", ok = true, signed_version = "L3" })
			assert.same({ "always light reloaded to version L3" }, lines)
		end)

		it("takes a bundle without a tree as its own (an older bridge) and warns when the reload fails", function()
			local handler = devloop.reload_handler(log, "scene")
			handler({ version = "S2", bundle = "{}" })
			assert.equal("S2", got.version)
			assert.same({ "warn scene reload failed; see this scene's Lua output" }, lines)
			handler(nil)
			assert.same({}, got, "nil params read as none")
		end)

		it("says a refusal as a refusal, with the reason", function()
			local handler = devloop.reload_handler(log, "scene")
			handler({ tree = "scene", version = "S2", bundle = "{}", outcome = "refused", why = "not signed" })
			assert.same({ "warn scene reload refused (not signed); see this scene's Lua output" }, lines)
		end)

		it("ignores another tree's bundle at debug level without touching the dev loop", function()
			local handler = devloop.reload_handler(log, "scene")
			handler({ tree = "light", version = "L1", bundle = "{}" })
			assert.is_nil(got)
			assert.same({ "debug DEV_RELOAD for the light tree ignored" }, lines)
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

		-- Security review 2026-10-25, finding 9: the bridge's development
		-- commands are not in its dispatch table; only a signed command runs them.
		it("execute runs the bridge's signed handler of that name instead of ExecuteCommand", function()
			start_synced()
			local seen, through_entry = {}, {}
			rawset(_G, "ExecuteCommand", function(command) table.insert(through_entry, command) end)
			devloop.set_signed_commands({ Hue_Request = function(params) table.insert(seen, params) end })
			server.commands = {
				{ id = 1, type = "execute", command = "Hue Request", params = { Path = "/clip/v2/resource/light" } },
				{ id = 2, type = "execute", command = "LUA_ACTION", params = { ACTION = "Hue  Request", Method = "GET" } },
				{ id = 3, type = "execute", command = "Connection Test", params = { Target = "Bridge" } },
			}
			tick()
			assert.same({ { Path = "/clip/v2/resource/light" }, { Method = "GET" } }, seen,
				"named as common/dispatch.lua names commands; LUA_ACTION unwrapped and its ACTION dropped")
			assert.same({ "Connection Test" }, through_entry, "anything else goes to ExecuteCommand")
			assert.same({ "command_done", "command_done", "command_done" }, events())
		end)

		it("finds the signed handlers the running code set, a reload's included", function()
			start_synced()
			devloop.set_signed_commands({ Probe_Call = function() table.insert(calls(), "probe v1") end })
			server.commands = { { id = 1, type = "execute", command = "Probe Call" } }
			tick()
			server.version = "v2"
			server.files["driver.lua"] = DRIVER_SRC .. "\nrequire('common.devloop').set_signed_commands("
				.. "{ Probe_Call = function() table.insert(DEVLOOP_TEST_CALLS, 'probe v2') end })"
			server.commands = { { id = 2, type = "execute", command = "Probe Call" } }
			tick()
			local probes = {}
			for _, call in ipairs(calls()) do
				if call:find("^probe") then probes[#probes + 1] = call end
			end
			assert.same({ "probe v1", "probe v2" }, probes)
		end)

		it("reports a failing signed handler, says so and runs the next command", function()
			start_synced()
			local ran = {}
			devloop.set_signed_commands({
				Probe_Call = function() error("probe broke") end,
				Hue_Request = function() table.insert(ran, "Hue Request") end,
			})
			server.commands = { { id = 1, type = "execute", command = "Probe Call" },
				{ id = 2, type = "execute", command = "Hue Request" } }
			tick()
			assert.truthy(server.reports[1].error:find("probe broke", 1, true))
			assert.equal(1, printed_count("devloop: signed command Probe_Call failed: "))
			assert.same({ "Hue Request" }, ran)
			assert.is_nil(server.reports[2].error)
		end)

		it("runs no signed handler from a command list that does not verify", function()
			start_synced()
			local seen = {}
			devloop.set_signed_commands({ Probe_Call = function() table.insert(seen, "probe") end })
			server.unsigned.commands = true
			server.commands = { { id = 1, type = "execute", command = "Probe Call" } }
			tick()
			server.unsigned.commands = nil
			server.keys.commands = OTHER_KEY
			tick()
			assert.same({}, seen)
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

		it("asks with a fresh nonce every time", function()
			start_synced()
			tick()
			tick()
			assert.equal(3, #server.nonces)
			for i, nonce in ipairs(server.nonces) do
				assert.truthy(nonce:match("^%x+$") and #nonce == 32, "32 hex characters: " .. tostring(nonce))
				for j = 1, i - 1 do assert.is_not.equal(server.nonces[j], nonce) end
			end
			-- A reloaded module (a Director restart) starts its own series.
			local before = server.nonces[3]
			reload_module(TEST_KEY)
			start_synced()
			assert.is_not.equal(before, server.nonces[4])
		end)

		it("runs nothing from an unsigned command list, and says so once per streak", function()
			start_synced()
			local seen = {}
			rawset(_G, "ExecuteCommand", function(command) table.insert(seen, command) end)
			rawset(_G, "OnPropertyChanged", function(name) table.insert(seen, name) end)
			server.unsigned.commands = true
			server.commands = { { id = 1, type = "execute", command = "Probe Call" },
				{ id = 2, type = "set_property", name = "Dev Server", value = "elsewhere:80" } }
			tick()
			tick()
			assert.same({}, seen)
			assert.same({}, c4.calls_to("UpdateProperty"))
			assert.same({}, events())
			assert_said("commands refused: not signed")

			server.unsigned.commands = nil
			tick()
			assert.same({ "Probe Call", "Dev Server" }, seen, "signed, the same list runs")
			server.unsigned.commands = true
			server.commands[3] = { id = 3, type = "execute", command = "C" }
			tick()
			assert.equal(2, times_said("commands refused: not signed"), "a new streak is said again")
		end)

		it("runs nothing from a list signed with another key", function()
			start_synced()
			local seen = {}
			rawset(_G, "ExecuteCommand", function(command) table.insert(seen, command) end)
			server.keys.commands = OTHER_KEY
			server.commands = { { id = 1, type = "execute", command = "A" } }
			tick()
			assert.same({}, seen)
			assert_said("commands refused: signature mismatch")
		end)

		it("runs nothing from an answer to another request, so a recorded one cannot be replayed", function()
			start_synced()
			local seen = {}
			rawset(_G, "ExecuteCommand", function(command) table.insert(seen, command) end)
			server.commands = { { id = 1, type = "execute", command = "A" } }
			server.echo_nonce = server.nonces[1]   -- what the previous request asked; signed, but stale
			tick()
			assert.same({}, seen)
			assert_said("commands refused: the answer is for another request (replayed?)")
		end)

		it("skips a command whose id is not above the last one run", function()
			start_synced()
			local seen = {}
			rawset(_G, "ExecuteCommand", function(command) table.insert(seen, command) end)
			server.commands = { { id = 5, type = "execute", command = "A" } }
			tick()
			server.all_commands = true
			server.commands = { { id = 3, type = "execute", command = "old" }, { id = 5, type = "execute", command = "A" },
				{ id = 6, type = "execute", command = "B" } }
			tick()
			assert.same({ "A", "B" }, seen)
			assert.equal(6, state().last_command_id)
		end)
	end)

	-- Issue #239: devctl.py set "Dev Server" "" used to stop the loop before
	-- the command's report, so the server kept the command pending for ever.
	describe("a command that stops or moves the loop", function()
		-- The bridge's Dev Server handler (bridge/devtools.lua, after late init).
		local function dev_server_handler()
			rawset(_G, "OnPropertyChanged", function(name)
				if name ~= "Dev Server" then return end
				local host = tostring(Properties[name] or ""):match("^%s*(.-)%s*$")
				if host == "" then devloop.stop() else devloop.start(host) end
			end)
		end

		-- The transfers started for `path` ("/report", ...), as "host path event".
		local function sent_to_hosts(path)
			local out = {}
			for _, t in ipairs(c4.transfers) do
				local host, p = t.url:match("^http://([^/]+)(/[^?]*)")
				if p == path then
					local body = t.data and c4:JsonDecode(t.data) or {}
					out[#out + 1] = host .. " " .. p .. " " .. tostring(body.event)
				end
			end
			return out
		end

		it("reports an emptied Dev Server as done, then stops, leaving the rest of the list queued", function()
			start_synced()
			dev_server_handler()
			local seen = {}
			rawset(_G, "ExecuteCommand", function(command) table.insert(seen, command) end)
			server.commands = { { id = 4, type = "set_property", name = "Dev Server", value = "" },
				{ id = 5, type = "execute", command = "A" } }
			tick()
			assert.same({ "command_done" }, events())
			local r = last_report()
			assert.equal(4, r.command_id)
			assert.is_nil(r.error)
			assert.equal("", r.properties["Dev Server"], "the report shows the property as the command left it")
			assert.same(plus(POLL, "POST /report"), server.requests, "nothing after the report: no /log, no heartbeat")
			assert.is_false(devloop.running())
			assert.equal(0, #c4.active_timers())
			assert.same({}, seen, "command 5 waits on the server for the loop's next start")
			assert_said("stopped")
			assert.equal(0, tick(), "stopped: nothing polls")

			-- Composer's Set of the row starts the loop again: it asks after command 4.
			devloop.start(HOST)
			serve()
			tick()
			assert.same({ "A" }, seen)
			assert.equal(1, count_containing(server.requests, "GET /commands?after=4"))
		end)

		it("reports to the server the command came from, then moves to the new one", function()
			start_synced()
			dev_server_handler()
			c4.transfers = {}
			server.commands = { { id = 6, type = "set_property", name = "Dev Server", value = " other:9090 " } }
			tick()
			assert.same({ "devvm:8080 /report command_done", "other:9090 /report startup" }, sent_to_hosts("/report"))
			assert.is_true(devloop.running())
			assert.equal(1, #c4.active_timers())
			assert.equal("other:9090", state().host)
		end)

		it("holds a stop made through ExecuteCommand or a signed handler until the report, a failing one too", function()
			start_synced()
			devloop.set_signed_commands({ Probe_Call = function() devloop.stop(); error("probe broke") end })
			server.commands = { { id = 7, type = "execute", command = "Probe Call" } }
			tick()
			assert.same({ "command_done" }, events())
			assert.truthy(last_report().error:find("probe broke", 1, true))
			assert.is_false(devloop.running())

			devloop.set_signed_commands(nil)
			start_synced()
			rawset(_G, "ExecuteCommand", function() devloop.start("") end)
			server.commands = { { id = 8, type = "execute", command = "Stop" } }
			tick()
			assert.same({ "command_done" }, events())
			assert.equal(8, last_report().command_id)
			assert.is_false(devloop.running())
		end)

		it("goes on with the list when Dev Server is set to the host it already uses", function()
			start_synced()
			dev_server_handler()
			local seen = {}
			rawset(_G, "ExecuteCommand", function(command) table.insert(seen, command) end)
			server.commands = { { id = 9, type = "set_property", name = "Dev Server", value = HOST },
				{ id = 10, type = "execute", command = "A" } }
			tick()
			assert.same({ "command_done", "command_done" }, events())
			assert.same({ "A" }, seen)
			assert.is_true(devloop.running())
			assert.equal(1, #c4.calls_to("SetTimer"), "never restarted")
		end)

		it("ends where the command's last call leaves it: a stop and then the same host keeps the loop", function()
			start_synced()
			rawset(_G, "ExecuteCommand", function()
				devloop.stop()
				devloop.start(HOST)
			end)
			server.commands = { { id = 11, type = "execute", command = "Bounce" },
				{ id = 12, type = "execute", command = "Bounce" } }
			tick()
			assert.same({ "command_done", "command_done" }, events())
			assert.is_true(devloop.running())
			assert.equal(1, #c4.calls_to("SetTimer"), "never restarted")
		end)

		it("stops at once outside a command, as before", function()
			start_synced()
			server.commands = { { id = 13, type = "set_property", name = "Dev Server", value = "" } }
			dev_server_handler()
			tick()
			assert.is_false(devloop.running())
			assert.is_false(devloop.start(""))
			devloop.start(HOST)
			assert.is_true(devloop.running())
			devloop.stop()
			assert.is_false(devloop.running(), "the hold ended with the command")
			assert.equal(0, #c4.active_timers())
		end)

		it("reports even when the report cannot start, and still stops", function()
			start_synced()
			dev_server_handler()
			server.commands = { { id = 14, type = "set_property", name = "Dev Server", value = "" } }
			local real_url = c4.url
			c4.url = function(self)
				local t = real_url(self)
				t.Post = function() error("no transfer slot") end
				return t
			end
			tick()
			c4.url = real_url
			assert.is_false(devloop.running())
			assert.equal(1, printed_count("devloop: report command_done failed: could not start transfer: "))
			assert.equal(1, printed_count("no transfer slot"), "started while the loop still knew its server")
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

		-- Security review 2026-10-25, finding 9: the bridge's redactor keeps the
		-- application key out of every line that leaves the controller.
		it("runs every line through the bridge's redactor before it is buffered", function()
			start_synced()
			devloop.set_redactor(function(line) return (line:gsub("s3cret", "<key>")) end)
			print("key s3cret in a line")
			assert.same({ "key <key> in a line" }, buffered())
			assert.equal("key s3cret in a line", printed[#printed], "Composer's own output is left alone")
			tick()
			assert.equal("key <key> in a line", server.logs[1].lines[1].line)
		end)

		it("redacts again on the way out, so a line buffered before the key was known leaves without it", function()
			start_synced()
			local key -- what the bridge knows: nothing until its late init
			devloop.set_redactor(function(line)
				if not key then return line end
				return (line:gsub(key, "<key>"))
			end)
			print("early s3cret")
			assert.same({ "early s3cret" }, buffered())
			key = "s3cret"
			tick()
			assert.equal("early <key>", server.logs[1].lines[1].line)
			assert.same({}, buffered(), "shipped and gone")
		end)

		it("withholds a line the redactor fails on, drops one it keeps nothing of, and never raises", function()
			start_synced()
			devloop.set_redactor(function(line)
				if line:find("boom", 1, true) then error("redactor broke") end
				if line:find("drop", 1, true) then return nil end
				if line:find("number", 1, true) then return 42 end
				return line
			end)
			assert.has_no.errors(function()
				print("boom s3cret")
				print("drop this")
				print("a number")
				print("fine")
			end)
			tick()
			local shipped = {}
			for _, entry in ipairs(server.logs[1].lines) do shipped[#shipped + 1] = entry.line end
			assert.same({ devloop.WITHHELD, devloop.WITHHELD, "fine" }, shipped)
			-- The loop's own messages go through capture without print's pcall.
			devloop.set_redactor(function() error("redactor broke") end)
			assert.has_no.errors(function() devloop.stop() end)
			assert.same({ devloop.WITHHELD }, buffered(), "devloop: stopped, withheld")
		end)

		it("does not hand the redactor a line it printed itself", function()
			start_synced()
			local seen = 0
			devloop.set_redactor(function(line)
				seen = seen + 1
				print("the redactor speaks")
				return line
			end)
			print("outer")
			assert.same({ devloop.WITHHELD, "outer" }, buffered())
			assert.equal(1, seen)
		end)

		it("redacts the error text of a report", function()
			start_synced()
			devloop.set_redactor(function(line) return (line:gsub("s3cret", "<key>")) end)
			devloop.set_signed_commands({ Probe_Call = function() error("saw s3cret") end })
			server.commands = { { id = 1, type = "execute", command = "Probe Call" } }
			tick()
			assert.truthy(last_report().error:find("saw <key>", 1, true))
			for _, r in ipairs(server.reports) do assert.is_false(holds(r, "s3cret")) end
			for _, body in ipairs(server.logs) do
				for _, entry in ipairs(body.lines) do assert.is_nil(entry.line:find("s3cret", 1, true)) end
			end
			assert.truthy(#server.logs > 0)
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

	describe("without a dev key", function()
		it("starts, says once that it will refuse everything, and still reports", function()
			reload_module(nil)
			assert.is_false(devloop.has_key())
			assert.is_nil(devloop.key_fingerprint())
			devloop.start(HOST)
			assert.equal("devloop: this build has no dev key (common/devkey.lua; build with tools/build.sh --dev): "
				.. "every bundle and command will be refused", printed[2])
			serve()
			assert.equal("startup", server.reports[1].event)
			assert.is_nil(server.reports[1].key_fingerprint)
			server.commands = { { id = 1, type = "execute", command = "A" } }
			local seen = false
			rawset(_G, "ExecuteCommand", function() seen = true end)
			tick()
			assert.is_nil(devloop.version())
			assert.is_false(seen)
			assert_said("bridge bundle v1 refused: this build has no dev key")
			assert.equal(0, count_containing(server.requests, "/commands"), "nothing to verify commands with")
			c4.driver_file = "hue_light.c4z"
			assert.same({ false, "refused", "this build has no dev key" }, { devloop.apply_forwarded({ tree = "light",
				version = "L1", bundle = "{}", mac = string.rep("a", 64) }) })
		end)

		it("treats a malformed key as none and never prints it", function()
			local secret = "a-secret-that-is-not-64-hex-characters"
			reload_module(secret)
			assert.is_false(devloop.has_key())
			devloop.start(HOST)
			serve()
			assert.equal("devloop: common/devkey.lua is malformed (64 lowercase hex characters expected): "
				.. "every bundle and command will be refused", printed[2])
			assert.equal(0, count_containing(everything_said(), secret))
			reload_module(string.upper(TEST_KEY))
			assert.is_false(devloop.has_key(), "build.sh writes lowercase; anything else is not its key")
		end)
	end)

	describe("HMAC-SHA256", function()
		local function bytes(n, byte)
			return string.rep(string.char(byte), n)
		end

		-- RFC 4231, section 4: HMAC-SHA-256 of test cases 1 to 7.
		it("matches RFC 4231", function()
			local key4 = ""
			for i = 1, 25 do key4 = key4 .. string.char(i) end
			local cases = {
				{ bytes(20, 0x0b), "Hi There", "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7" },
				{ "Jefe", "what do ya want for nothing?",
					"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" },
				{ bytes(20, 0xaa), bytes(50, 0xdd), "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe" },
				{ key4, bytes(50, 0xcd), "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b" },
				{ bytes(131, 0xaa), "Test Using Larger Than Block-Size Key - Hash Key First",
					"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54" },
				{ bytes(131, 0xaa), "This is a test using a larger than block-size key and a larger than block-size data. "
					.. "The key needs to be hashed before being used by the HMAC algorithm.",
					"9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2" },
			}
			for i, case in ipairs(cases) do
				assert.equal(case[3], devloop.lua_hmac_sha256(case[1], case[2]), "case " .. i)
				assert.equal(case[3], devloop.hmac_sha256(case[1], case[2]), "case " .. i .. " through the selection")
			end
			-- Test case 5: truncated to 128 bits.
			assert.equal("a3b6167473100ee06e0c796c2955552b",
				devloop.lua_hmac_sha256(bytes(20, 0x0c), "Test With Truncation"):sub(1, 32))
		end)

		-- FIPS 180-4 examples, and lengths around the padding boundaries.
		it("hashes like SHA-256", function()
			local vectors = {
				{ "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
				{ "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
				{ "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
					"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
				{ string.rep("a", 55), "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318" },
				{ string.rep("a", 56), "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a" },
				{ string.rep("a", 63), "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34" },
				{ string.rep("a", 64), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb" },
				{ string.rep("a", 119), "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb" },
				{ string.rep("a", 1000), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3" },
			}
			for _, v in ipairs(vectors) do
				assert.equal(v[2], devloop.lua_sha256(v[1]), #v[1] .. " bytes")
			end
		end)

		it("agrees with tools/devserver.py on the shared vectors", function()
			assert.equal(SHARED_BUNDLE_MAC, devloop.hmac_sha256(TEST_KEY, DOMAIN .. "bundle\n" .. SHARED_PAYLOAD))
			assert.is_nil(devloop.check_signature("bundle", SHARED_PAYLOAD, SHARED_BUNDLE_MAC))
			assert.equal(TEST_FINGERPRINT, devloop.key_fingerprint())
		end)

		it("uses the Lua code when C4 has no HMAC", function()
			assert.equal("Lua (no C4:HMAC)", devloop.hmac_backend())
		end)

		it("uses C4:HMAC with the documented arguments once it passes the RFC 4231 self-test", function()
			local seen = {}
			c4.HMAC = function(self, digest, key, data, options)
				assert.equal(c4, self, "called as a method")
				seen[#seen + 1] = { digest = digest, key = key, data = data, options = options }
				return devloop.lua_hmac_sha256(key, data):upper()   -- the case of the hex is not documented
			end
			assert.equal("C4:HMAC", devloop.hmac_backend())
			assert.same({ digest = "SHA256", key = "Jefe", data = "what do ya want for nothing?",
				options = { return_encoding = "HEX", key_encoding = "NONE", data_encoding = "NONE" } }, seen[1])
			assert.equal(SHARED_BUNDLE_MAC, devloop.hmac_sha256(TEST_KEY, DOMAIN .. "bundle\n" .. SHARED_PAYLOAD))
			assert.equal(2, #seen)
			assert.equal(TEST_KEY, seen[2].key)
			assert.is_nil(devloop.check_signature("bundle", SHARED_PAYLOAD, SHARED_BUNDLE_MAC))
		end)

		it("keeps to the Lua code when C4:HMAC answers wrong, raises or returns an error", function()
			c4.HMAC = function() return string.rep("0", 64) end
			assert.equal("Lua (C4:HMAC failed the RFC 4231 self-test)", devloop.hmac_backend())
			assert.equal(SHARED_BUNDLE_MAC, devloop.hmac_sha256(TEST_KEY, DOMAIN .. "bundle\n" .. SHARED_PAYLOAD))

			reload_module(TEST_KEY)
			c4.HMAC = function() error("no such digest", 0) end
			assert.equal("Lua (C4:HMAC raised: no such digest)", devloop.hmac_backend())

			reload_module(TEST_KEY)
			c4.HMAC = function() return nil, "bad options" end
			assert.equal("Lua (C4:HMAC raised: bad options)", devloop.hmac_backend())
			assert.is_nil(devloop.check_signature("bundle", SHARED_PAYLOAD, SHARED_BUNDLE_MAC))
		end)

		it("switches to the Lua code for good when C4:HMAC raises on a real input, without its error text", function()
			c4.HMAC = function(_, _, key, data)
				if key ~= "Jefe" then error("refusing " .. key .. " and " .. data, 0) end
				return devloop.lua_hmac_sha256(key, data)
			end
			assert.equal("C4:HMAC", devloop.hmac_backend())
			assert.equal(SHARED_BUNDLE_MAC, devloop.hmac_sha256(TEST_KEY, DOMAIN .. "bundle\n" .. SHARED_PAYLOAD))
			assert.equal("Lua (C4:HMAC raised on a real input)", devloop.hmac_backend())
			assert.same({ "devloop: C4:HMAC failed; checking signatures in Lua from now on" }, printed)
			assert.same({ "devloop: C4:HMAC failed; checking signatures in Lua from now on" }, buffered())
		end)
	end)
end)


-- The development requests, security reviews 2026-10-24 (finding 15) and
-- 2026-10-25 (findings 9 and 10): the application key goes only to
-- spellings of the bridge's own address, on paths that keep it there, once
-- the bridge's identity is verified; the requests, probes and proxy
-- commands answer signed dev loop commands only; Probe Call keeps off the
-- credential store; the loop's redactor keeps the key out of shipped lines.
describe("bridge/devtools.lua development requests", function()
	local log = require("common.log")

	local IP = "10.0.2.143"
	local IP_PATTERN = (IP:gsub("%.", "%%."))
	local CHECK_URL = "https://10.00.02.143/clip/v2/resource/bridge"
	local IDENTITY = '{"bridgeid":"%s","modelid":"BSB003","name":"Hue","swversion":"1968096020","apiversion":"1.68.0"}'
	local BRIDGE_RESOURCE = '{"errors":[],"data":[{"id":"x","type":"bridge","bridge_id":"001788fffe123abc"}]}'
	local env, c4, lines, real_sink

	-- The identity check, answered with the paired bridge id unless told otherwise.
	local function answer_identity(bridgeid)
		local t = c4.last_transfer()
		assert(t and t.url == "https://" .. IP .. "/api/0/config",
			"expected the identity check, got " .. tostring(t and t.url))
		t:respond(200, string.format(IDENTITY, bridgeid or "001788FFFE123ABC"))
	end

	-- The identity check, then the self-check via the check spelling.
	local function answer_check()
		answer_identity()
		local t = c4.last_transfer()
		assert(t and t.url == CHECK_URL, "expected the self-check, got " .. tostring(t and t.url))
		t:respond(200, BRIDGE_RESOURCE)
	end

	-- A dev build of the bridge (common.devloop is on the test path, so
	-- bridge/devtools.lua is installed), paired, its identity checked unless
	-- `answer` is false.
	local function paired(answer)
		env, c4 = fake.load_driver("hue_bridge", { ["Bridge IP Address"] = IP })
		c4.persist.hue_app_key = "abc123"
		c4.persist.hue_bridge_id = "001788fffe123abc"
		env.OnDriverLateInit("DIT_STARTUP")
		if answer ~= false then answer_check() end
	end

	-- A Composer action, or what any driver in the project sends with
	-- C4:SendToDevice dressed as one.
	local function action(name, params)
		params = params or {}
		params.ACTION = name
		env.ExecuteCommand("LUA_ACTION", params)
	end

	-- A signed dev loop command, as tools/devctl.py run queues it: what
	-- common/devloop.lua runs once the command list verified.
	local function signed(name, params)
		return require("common.devloop").execute(name, params or {})
	end

	-- `fn()` with a release build's modules: no common.devloop, hence no
	-- bridge/devtools.lua. Returns what `fn` returns.
	local function as_release(fn)
		package.loaded["common.devloop"] = nil
		package.preload["common.devloop"] = function() error("module 'common.devloop' not found") end
		local ok, result = pcall(fn)
		package.preload["common.devloop"] = nil
		package.loaded["common.devloop"] = nil
		assert(ok, result)
		return result
	end

	-- The <command> of every action in a DEV-ONLY block of the bridge's
	-- driver.xml: what Composer itself sends to a dev build.
	local function dev_only_commands()
		local file = assert(io.open("src/hue_bridge/driver.xml"))
		local xml = file:read("*a")
		file:close()
		local names = {}
		for block in xml:gmatch("<!%-%- DEV%-ONLY BEGIN.-<!%-%- DEV%-ONLY END %-%->") do
			for command in block:gmatch("<command>(.-)</command>") do names[#names + 1] = command end
		end
		table.sort(names)
		return names
	end

	before_each(function()
		lines = {}
		real_sink = log.sink
		log.sink = function(line) lines[#lines + 1] = line end
	end)

	after_each(function()
		log.sink = real_sink
		-- The loop's state outlives a driver load (_G.__DEVLOOP): leave no
		-- handler or redactor of this spec's bridge behind.
		local loop = package.loaded["common.devloop"]
		if type(loop) == "table" and loop.set_signed_commands then
			loop.set_signed_commands(nil)
			loop.set_redactor(nil)
		end
	end)

	it("knows the spellings altaddr writes, and nothing else", function()
		local altaddr = require("bridge.altaddr")
		local devtools = require("bridge.devtools")
		local ok = { IP, "10.00.02.143", "10.000.002.143", "10.0.002.143", "10.000.2.143", "10.00.2.143" }
		for _, host in ipairs(ok) do
			assert.is_true(devtools.spells_bridge_address(host, IP), host)
		end
		for _, host in ipairs({ "192.0.2.143", "010.0.2.143", "10.0.2.0143", "10.0000.2.143", "10.0.2.143.", " 10.0.2.143",
			"10.0.2", "10.0.2.143:443", "bridge.local", "167772815", "0x0a.0.2.143", "", "10.0.2.143/x" }) do
			assert.is_false(devtools.spells_bridge_address(host, IP), host)
		end
		assert.is_false(devtools.spells_bridge_address(IP, nil), "no bridge address, no spelling of it")
		assert.is_false(devtools.spells_bridge_address(nil, IP))
		-- 10 and 143 are 8 or more: a leading zero would make curl read them as octal.
		assert.is_false(devtools.spells_bridge_address("192.0.2.010", "192.0.2.10"))
		assert.is_false(devtools.spells_bridge_address("192.0.2.11", "192.0.2.10"), "one octet off")
		assert.is_true(devtools.spells_bridge_address("192.00.002.10", "192.0.2.10"))
		-- Every spelling the driver itself uses passes.
		local mine = { altaddr.for_check(IP), altaddr.padded(IP, 3), altaddr.padded(IP, 2) }
		for _, spelling in ipairs(altaddr.stream_family(IP)) do mine[#mine + 1] = spelling end
		for _, spelling in ipairs(mine) do
			assert.is_true(devtools.spells_bridge_address(spelling, IP), spelling)
		end
	end)

	it("puts only Composer's DEV-ONLY actions and HUE_LOG into the dispatch table", function()
		local function command_names()
			paired(false)
			local names = {}
			for name in pairs(require("common.dispatch").commands) do names[name] = true end
			return names
		end
		local release = as_release(command_names)
		local dev = command_names()
		local added = {}
		for name in pairs(dev) do
			if not release[name] then added[#added + 1] = name end
		end
		table.sort(added)
		assert.same({ "Check CA Pinning", "Connection Test", "Reload Credentials" }, dev_only_commands())
		local expected = { "HUE_LOG" }
		for _, command in ipairs(dev_only_commands()) do expected[#expected + 1] = (command:gsub("%s+", "_")) end
		table.sort(expected)
		assert.same(expected, added)
	end)

	it("answers the development commands for signed dev loop commands only", function()
		paired()
		local transfers, sent, logged = #c4.transfers, #c4.sent, #lines
		for _, name in ipairs({ "Hue Request", "Probe Call", "Proxy Command", "Lights Report", "Probe Project",
			"Probe Errors", "Probe Scenes" }) do
			local params = { Method = "DELETE", Path = "/clip/v2/resource/light/x", Fn = "GetDeviceID", Light = "x",
				Command = "ON" }
			env.ExecuteCommand(name, params) -- C4:SendToDevice from any driver in the project
			action(name, params)             -- the same, dressed as a Composer action
		end
		assert.equal(transfers, #c4.transfers, "no request went out")
		assert.equal(sent, #c4.sent, "no proxy command, no probe message")
		assert.equal(logged, #lines, "no handler ran")

		-- Test Connection with a Host from anywhere but the loop is Composer's
		-- action, on the dotted address.
		action("Test Connection", { Host = "10.000.2.143" })
		assert.equal("https://" .. IP .. "/clip/v2/resource/bridge", c4.last_transfer().url)
		c4.last_transfer():respond(200, BRIDGE_RESOURCE)

		signed("Hue Request", { Method = "DELETE", Path = "/clip/v2/resource/light/x" })
		local t = c4.last_transfer()
		assert.equal("DELETE", t.method)
		assert.equal("https://" .. IP .. "/clip/v2/resource/light/x", t.url, "a signed command runs it")
	end)

	it("sends Hue Request to a spelling of the bridge address", function()
		paired()
		for _, host in ipairs({ "10.00.002.143", IP }) do
			signed("Hue Request", { Path = "/clip/v2/resource/light", Host = host })
			local t = c4.last_transfer()
			assert.equal("https://" .. host .. "/clip/v2/resource/light", t.url)
			assert.equal("abc123", t.headers["hue-application-key"])
			t:respond(200, '{"errors":[],"data":[]}')
		end
		signed("Hue Request", { Path = "/clip/v2/resource/light", Host = " " })
		assert.equal("https://" .. IP .. "/clip/v2/resource/light", c4.last_transfer().url, "the dotted address by default")
		c4.last_transfer():respond(200, '{"errors":[],"data":[]}')
		signed("Hue Request", { Path = "" })
		assert.equal("https://" .. IP .. "/clip/v2/resource/bridge", c4.last_transfer().url, "the bridge resource by default")
	end)

	it("refuses Hue Request to any other host, saying why and sending nothing", function()
		paired()
		local before = #c4.transfers
		for _, host in ipairs({ "192.0.2.7", "10.0.2.0143", "evil.example", "10.0.2.143:8443" }) do
			signed("Hue Request", { Method = "PUT", Path = "/clip/v2/resource/light/x", Body = "{}", Host = host })
			assert.equal(string.format('Hue Bridge: Hue Request: Host "%s" refused: not a spelling of the bridge address %s',
				host, IP), lines[#lines])
		end
		assert.equal(before, #c4.transfers)
	end)

	it("refuses a Hue Request Path that could leave the bridge's host, saying why and sending nothing", function()
		paired()
		local before = #c4.transfers
		for _, path in ipairs({ "@203.0.113.9/clip/v2/resource/bridge", ".example.net/clip/v2/resource/bridge",
			":8443/clip/v2/resource/bridge", "clip/v2/resource/bridge", " /clip/v2/resource/bridge",
			"/clip/v2/resource/bridge@203.0.113.9", "/clip/v2\\resource\\bridge", "/clip/v2/resource#bridge",
			"/clip/v2/resource /bridge", "/clip/v2/resource\tbridge", "/clip/v2/resource\nbridge" }) do
			signed("Hue Request", { Method = "DELETE", Path = path })
			assert.truthy(lines[#lines]:find('^Hue Bridge: Hue Request: Path ".*" refused: it must .*; nothing is sent$'),
				lines[#lines])
		end
		assert.equal(before, #c4.transfers)
		signed("Hue Request", { Path = "@203.0.113.9/clip/v2/resource/bridge" })
		assert.equal('Hue Bridge: Hue Request: Path "@203.0.113.9/clip/v2/resource/bridge" refused: it must start '
			.. 'with "/"; nothing is sent', lines[#lines])
		signed("Hue Request", { Path = "/clip/v2/resource/bridge#x" })
		assert.equal('Hue Bridge: Hue Request: Path "/clip/v2/resource/bridge#x" refused: it must hold no "@", "\\", '
			.. '"#", white space or control characters; nothing is sent', lines[#lines])
		assert.equal(before, #c4.transfers)
	end)

	it("holds Hue Request until the bridge identity is verified", function()
		paired(false)
		local before = #c4.transfers
		signed("Hue Request", { Path = "/clip/v2/resource/light" })
		assert.equal("Hue Bridge: Hue Request: bridge identity not verified yet; see Status", lines[#lines])
		assert.equal(before, #c4.transfers)
	end)

	it("fails an unknown method in http.lua, with the reason in the result line", function()
		paired()
		local before = #c4.transfers
		signed("Hue Request", { Method = "PATCH", Path = "/clip/v2/resource/light/x", Body = "{}" })
		assert.equal(before, #c4.transfers, "no transfer started")
		assert.truthy(lines[#lines]:find("^Hue Bridge: Hue Request PATCH /clip/v2/resource/light/x via " .. IP_PATTERN
			.. ": could not start transfer: .*unsupported method PATCH"), lines[#lines])
	end)

	it("refuses Probe Call on the credential store without naming it, and reads nothing", function()
		paired()
		local deleted_all = false
		c4.PersistDeleteAll = function() deleted_all = true end
		local reads, writes = #c4.calls_to("PersistGetValue"), #c4.calls_to("PersistSetValue")
		local deletes = #c4.calls_to("PersistDeleteValue")
		for _, case in ipairs({
			{ "PersistGetValue", '["hue_app_key", true]' },
			{ "PersistGetValue", '["HUE_APP_KEY", true]' },
			{ "PersistGetValue", '[" hue_app_key\\u0000tail", true]' },
			{ "PersistGetValue", '["hue_bridge_id"]' },
			{ "PersistSetValue", '["hue_app_key", "0000", true]' },
			{ "PersistSetValue", '["hue_bridge_ip", "203.0.113.9"]' },
			{ "PersistDeleteValue", '["hue_app_key"]' },
			{ "PersistDeleteAll", "" },
			{ "PersistGetValue", "[]" },
		}) do
			signed("Probe Call", { Fn = case[1], Args = case[2] })
			local line = lines[#lines]
			assert.truthy(line:find("^Hue Bridge: Probe Call: C4%." .. case[1] .. " refused: .*; nothing was called$"), line)
			assert.is_nil(line:lower():find("hue_", 1, true), "no store name in the line: " .. line)
		end
		assert.equal(reads, #c4.calls_to("PersistGetValue"), "nothing read, not even to learn the names")
		assert.equal(writes, #c4.calls_to("PersistSetValue"))
		assert.equal(deletes, #c4.calls_to("PersistDeleteValue"))
		assert.is_false(deleted_all)
		assert.equal("abc123", c4.persist.hue_app_key)
		assert.equal(c4, rawget(_G, "C4"), "the real C4 is back")
		for _, line in ipairs(lines) do assert.is_nil(line:find("abc123", 1, true), line) end

		-- Any other entry is probed like anything else.
		signed("Probe Call", { Fn = "PersistGetValue", Args = '["hue_lights"]' })
		assert.truthy(lines[#lines]:find('^Hue Bridge: C4:PersistGetValue%(%["hue_lights"%]%) 1/1: '), lines[#lines])
		assert.equal(reads + 1, #c4.calls_to("PersistGetValue"))
	end)

	it("refuses every Persist call when the credential store's names cannot be read", function()
		paired()
		local credentials = require("bridge.credentials")
		local load = credentials.load
		credentials.load = function() return {} end -- asks the store for nothing
		local ok, err = pcall(signed, "Probe Call", { Fn = "PersistGetValue", Args = '["hue_lights"]' })
		credentials.load = load
		assert(ok, err)
		assert.equal("Hue Bridge: Probe Call: C4.PersistGetValue refused: the credential store's names could not be "
			.. "read; nothing was called", lines[#lines])
	end)

	it("gives the dev loop a redactor that replaces the application key the driver holds", function()
		paired()
		local devloop = require("common.devloop")
		assert.equal("got <key>, then <key> again", devloop.redacted("got abc123, then abc123 again"))
		assert.equal("nothing to hide", devloop.redacted("nothing to hide"))
	end)

	it("holds Connection Test against the bridge until the bridge identity is verified", function()
		paired(false)
		local before, status = #c4.transfers, env.Properties["Status"]
		action("Connection Test", { Target = "Bridge" })
		assert.equal("Hue Bridge: Connection Test: bridge identity not verified yet; nothing is sent (see Status)",
			lines[#lines])
		assert.equal(before, #c4.transfers)
		assert.equal(status, env.Properties["Status"], "Status keeps what the identity check says")

		-- A different bridge at the address: still nothing, and Status says why.
		answer_identity("001788FFFE456DEF")
		before = #c4.transfers
		action("Connection Test", { Target = "Bridge" })
		assert.equal(before, #c4.transfers)
		assert.truthy(env.Properties["Status"]:find("reports ID 001788fffe456def", 1, true), env.Properties["Status"])
	end)

	it("holds Test Connection with a Host until the bridge identity is verified", function()
		paired(false)
		local before = #c4.transfers
		signed("Test Connection", { Host = "10.000.2.143" })
		assert.equal("Hue Bridge: Test Connection: bridge identity not verified yet; see Status", lines[#lines])
		assert.equal(before, #c4.transfers, "nothing sent, not even a second identity check")
	end)

	it("refuses Test Connection to another host and runs it on a spelling of the bridge address", function()
		paired()
		local before = #c4.transfers
		signed("Test Connection", { Host = "192.0.2.7" })
		assert.equal(before, #c4.transfers)
		assert.equal("Test Connection refused: Host is not a spelling of the bridge address", env.Properties["Status"])
		assert.equal('Hue Bridge: Test Connection: Host "192.0.2.7" refused: not a spelling of the bridge address ' .. IP,
			lines[#lines])

		signed("Test Connection", { Host = "10.000.2.143" })
		local t = c4.last_transfer()
		assert.equal("https://10.000.2.143/clip/v2/resource/bridge", t.url)
		assert.equal("abc123", t.headers["hue-application-key"])
		t:respond(200, BRIDGE_RESOURCE)
		assert.truthy(env.Properties["Status"]:find("^Test OK: HTTP 200 via 10.000.2.143"))
	end)

	it("prints a device's HUE_LOG message as one line, whatever it holds", function()
		paired()
		env.ExecuteCommand("HUE_LOG", { rid = "rid-1\nx", line = "[INFO] Hue Light: one\nHue Bridge: Test OK\r\tforged" })
		assert.equal("Hue Bridge: [rid-1 x] [INFO] Hue Light: one Hue Bridge: Test OK  forged", lines[#lines])
	end)

	it("leaves the development commands out when the running loop predates signed commands", function()
		package.loaded["common.devloop"] = nil
		-- An older common/devloop.lua, the one module a reload never replaces.
		package.preload["common.devloop"] = function() return { start = function() end, stop = function() end } end
		local ok, err = pcall(function()
			paired()
			local dispatch = require("common.dispatch")
			assert.is_function(dispatch.commands["Connection_Test"])
			assert.is_function(dispatch.commands["HUE_LOG"])
			assert.is_nil(dispatch.commands["Hue_Request"])
			assert.equal(1, count_containing(lines, "the running common/devloop.lua predates signed commands"))
		end)
		package.preload["common.devloop"] = nil
		package.loaded["common.devloop"] = nil
		assert(ok, err)
	end)
end)
