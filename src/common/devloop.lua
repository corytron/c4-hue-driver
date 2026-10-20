-- Dev loop: lets the development VM push Lua into the running driver and run
-- actions against it without Composer (docs/dev-loop.md). Dev builds only;
-- release builds do not contain this file.
--
-- One repeating timer polls a plain-HTTP server. Each tick is a chain of
-- C4:url transfers, each started from the previous one's OnDone:
--   GET /manifest -> (GET /bundle, reload, POST /report) ->
--   GET /commands -> (run each, POST /report command_done) ->
--   POST /log -> (POST /report heartbeat)
-- so no transfer ever starts inside OnHeaders or OnBodyChunk, which Director
-- fails with curl error 2. A tick that fires while the previous chain is
-- still in flight is skipped.
--
-- State lives in _G.__DEVLOOP so a reload of the rest of the driver cannot
-- lose the timer or the log buffer; package.loaded["common.devloop"] is the
-- one driver module a reload never clears.
--
-- Public API:
--   devloop.start(host_port)  idempotent for the same host; a different host
--                             restarts; an empty host stops
--   devloop.stop()
--   devloop.running()         -> bool
--   devloop.version()         -> version of the code last loaded, or nil
--                                while the .c4z's own code is running

local devloop = {}

devloop.INTERVAL_MS = 3000
devloop.HEARTBEAT_MS = 30000
devloop.MAX_LOG_LINES = 500
devloop.STUCK_TICKS = 10      -- ticks before an unfinished chain is abandoned

-- Shared state, created once per Lua state and reused across reloads.
local S = rawget(_G, "__DEVLOOP")
if not S then
	S = {
		host = nil,              -- "host:port" while running
		timer = nil,             -- the repeating C4LuaTimer
		gen = 0,                 -- bumped by start/stop; stale callbacks compare it
		busy = false,            -- a tick's chain is in flight
		busy_ticks = 0,
		unreachable = false,     -- server down; said once per transition
		version = nil,           -- version last loaded, or attempted and failed
		bundle = nil,            -- files of the last bundle fetched
		last_command_id = 0,
		last_report_ms = 0,
		log = {},                -- { t = ms, line = string }, oldest first
		original_print = nil,
		wrapper = nil,           -- our print replacement, so we recognise it
		shadow = {},             -- values the driver set through C4:UpdateProperty
		wrapped_c4 = nil,        -- the C4 table whose UpdateProperty we wrapped
		original_update = nil,
		loader = nil,            -- our package.loaders entry
	}
	rawset(_G, "__DEVLOOP", S)
end

local compile = rawget(_G, "loadstring") or rawget(_G, "load")

-- Milliseconds since the epoch, as the server expects for log lines.
local function now_ms()
	local ok, t = pcall(function() return C4:GetTime() end)
	return ok and type(t) == "number" and t or os.time() * 1000
end

-- Log capture -------------------------------------------------------------

local function capture(line)
	local log = S.log
	log[#log + 1] = { t = now_ms(), line = line }
	if #log > devloop.MAX_LOG_LINES then table.remove(log, 1) end
end

-- The loop's own messages: the original print so Composer shows them, and
-- the buffer so the server does too.
local function say(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	local line = "devloop: " .. (ok and msg or tostring(fmt))
	local out = S.original_print or rawget(_G, "print")
	if out then pcall(out, line) end
	capture(line)
end

-- Every callback body runs through this, so one failure cannot stop the loop.
local function guarded(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then say("error: %s", tostring(err)) end
	return ok
end

-- Wrapped once; a reloaded common.log picks the wrapper up as its sink
-- because it reads the global print when it loads.
local function wrap_print()
	local current = rawget(_G, "print")
	if current == S.wrapper then return end
	S.original_print = current
	S.wrapper = function(...)
		if S.original_print then S.original_print(...) end
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		pcall(capture, table.concat(parts, "\t"))
	end
	rawset(_G, "print", S.wrapper)
end

local function unwrap_print()
	if S.wrapper and rawget(_G, "print") == S.wrapper then rawset(_G, "print", S.original_print) end
	S.wrapper = nil
end

-- Properties snapshot -----------------------------------------------------

local function unwrap_update_property()
	if type(S.wrapped_c4) == "table" then S.wrapped_c4.UpdateProperty = S.original_update end
	S.wrapped_c4, S.original_update = nil, nil
end

-- Only possible when C4 is a Lua table (userdata on the controller, as far
-- as we know; the startup report says which).
local function wrap_update_property()
	local c4 = rawget(_G, "C4")
	if type(c4) ~= "table" or S.wrapped_c4 == c4 then return end
	unwrap_update_property()
	S.wrapped_c4, S.original_update = c4, c4.UpdateProperty
	c4.UpdateProperty = function(self, name, value, ...)
		S.shadow[tostring(name)] = value
		if S.original_update then return S.original_update(self, name, value, ...) end
	end
end

-- A copy of Properties with the shadowed values on top: Properties may lag
-- behind what the driver set through C4:UpdateProperty.
local function snapshot()
	local out = {}
	local props = rawget(_G, "Properties")
	if type(props) == "table" then
		for k, v in pairs(props) do out[tostring(k)] = v end
	end
	for k, v in pairs(S.shadow) do out[k] = v end
	return out
end

local function sandbox_facts()
	local jit = rawget(_G, "jit")
	local ok, driver_version = pcall(function() return C4:GetDriverConfigInfo("version") end)
	return {
		_VERSION = tostring(_VERSION),
		jit = type(jit),
		["jit.version"] = type(jit) == "table" and tostring(jit.version) or nil,
		loadstring = type(rawget(_G, "loadstring")),
		load = type(rawget(_G, "load")),
		setfenv = type(rawget(_G, "setfenv")),
		package = type(package),
		["package.loaders"] = type(package) == "table" and type(package.loaders) or "nil",
		C4 = type(rawget(_G, "C4")),
		driver_version = ok and tostring(driver_version) or nil,
	}
end

-- HTTP ----------------------------------------------------------------------

-- One exchange with the dev server. `callback(result)` runs exactly once with
-- { ok, code, body, json, err }, never sees a raised error, and is dropped if
-- the loop was stopped or restarted meanwhile.
local function request(method, path, body, callback)
	local gen = S.gen
	local function finish(result)
		if gen == S.gen then guarded(callback, result) end
	end
	local ok, err = pcall(function()
		local url = "http://" .. S.host .. path
		local data = body and C4:JsonEncode(body) or nil
		local headers = data and { ["Content-Type"] = "application/json" } or {}
		local transfer = C4:url()
			:SetOptions({ fail_on_error = false, timeout = 10, connect_timeout = 3 })
			:OnDone(function(_, responses, err_code, err_msg)
				local result = { ok = false }
				local response = responses and responses[#responses]
				if err_code ~= 0 then
					result.err = string.format("transfer failed (%s): %s", tostring(err_code), tostring(err_msg))
				elseif not response then
					result.err = "no response"
				else
					result.code, result.body = response.code, response.body
					result.ok = response.code >= 200 and response.code < 300
					if not result.ok then
						result.err = "HTTP " .. tostring(response.code)
					elseif response.body and response.body ~= "" then
						local decoded, value = pcall(function() return C4:JsonDecode(response.body) end)
						result.json = decoded and value or nil
					end
				end
				finish(result)
			end)
		-- Get/Post can raise at start (bridge/http.lua saw it with CA files).
		if method == "POST" then transfer:Post(url, data or "", headers) else transfer:Get(url, headers) end
	end)
	if not ok then finish({ ok = false, err = "could not start transfer: " .. tostring(err) }) end
end

local function report(event, extra, callback)
	local body = { version = S.version, event = event, properties = snapshot() }
	for k, v in pairs(extra or {}) do body[k] = v end
	S.last_report_ms = now_ms()
	request("POST", "/report", body, function(r)
		if not r.ok then say("report %s failed: %s", event, tostring(r.err)) end
		if callback then callback(r) end
	end)
end

-- Reload ----------------------------------------------------------------------

-- A package.loaders entry serving `a.b` from the bundle's "a/b.lua". Modules
-- the bundle lacks fall through to the normal loaders, i.e. the .c4z. The
-- previous entry is removed first so repeated reloads do not stack loaders.
local function install_loader(files)
	local loaders = type(package) == "table" and package.loaders
	if type(loaders) ~= "table" then
		error("package.loaders is " .. type(loaders) .. "; cannot serve modules from the bundle")
	end
	local function loader(name)
		local path = (string.gsub(name, "%.", "/")) .. ".lua"
		if type(files[path]) ~= "string" then return "\n\tno file '" .. path .. "' in the dev bundle" end
		local chunk, err = compile(files[path], "=" .. path)
		return chunk or ("\n\t" .. tostring(err))
	end
	for i = #loaders, 1, -1 do
		if loaders[i] == S.loader then table.remove(loaders, i) end
	end
	table.insert(loaders, 1, loader)
	S.loader = loader
end

-- Tear the running driver down and bring `files` up in its place. Returns
-- nil on success or the error text; the second value is a warning when
-- OnDriverDestroyed failed but the new code is running anyway (stopping
-- there would leave the old code in place, with every retry hitting the
-- same teardown bug).
local function reload(files, version)
	local warning
	local destroy = rawget(_G, "OnDriverDestroyed")
	if type(destroy) == "function" then
		local ok, err = pcall(destroy)
		if not ok then
			warning = "OnDriverDestroyed failed: " .. tostring(err)
			say("%s", warning)
		end
	end
	for name in pairs(package.loaded) do
		if name ~= "common.devloop" and (name:match("^bridge%.") or name:match("^common%.")) then
			package.loaded[name] = nil
		end
	end
	-- Recorded before anything can fail: a failed version is not retried
	-- until the server has a different one.
	S.version, S.bundle = version, files
	local ok, err = pcall(install_loader, files)
	if not ok then return tostring(err) end
	if type(files["driver.lua"]) ~= "string" then return "bundle has no driver.lua" end
	local chunk, cerr = compile(files["driver.lua"], "=driver.lua")
	if not chunk then return tostring(cerr) end
	ok, err = pcall(chunk)
	if not ok then return "driver.lua: " .. tostring(err) end
	for _, entry in ipairs({ "OnDriverInit", "OnDriverLateInit" }) do
		local fn = rawget(_G, entry)
		if type(fn) == "function" then
			ok, err = pcall(fn, "DIT_UPDATING")
			if not ok then return entry .. " failed: " .. tostring(err) end
		end
	end
	return nil, warning
end

-- Reload, report the outcome, then `done(err)`.
local function apply_bundle(files, version, done)
	local count = 0
	for _ in pairs(files) do count = count + 1 end
	say("reloading to version %s (%d files)", tostring(version), count)
	local err, warning = reload(files, version)
	if err then
		say("reload failed: %s", err)
		report("reload_failed", { error = err }, function() done(err) end)
	else
		say("reload complete: version %s", tostring(version))
		report("reload", { error = warning }, function() done(nil) end)
	end
end

-- `callback(files, version, err)`
local function fetch_bundle(callback)
	request("GET", "/bundle", nil, function(r)
		local j = r.json
		if not r.ok or type(j) ~= "table" or type(j.files) ~= "table" then
			return callback(nil, nil, "bundle: " .. tostring(r.err or "malformed response"))
		end
		callback(j.files, tostring(j.version))
	end)
end

-- Tick chain ------------------------------------------------------------------

local function end_tick()
	if now_ms() - S.last_report_ms < devloop.HEARTBEAT_MS then
		S.busy = false
		return
	end
	report("heartbeat", nil, function() S.busy = false end)
end

-- Lines stay in the buffer until the server accepts them (the cap still
-- applies meanwhile), so a failed POST loses nothing.
local function step_log()
	if #S.log == 0 then return end_tick() end
	local sent = {}
	for _, entry in ipairs(S.log) do sent[entry] = true end
	request("POST", "/log", { version = S.version, lines = S.log }, function(r)
		if r.ok then
			local rest = {}
			for _, entry in ipairs(S.log) do
				if not sent[entry] then rest[#rest + 1] = entry end
			end
			S.log = rest
		end
		end_tick()
	end)
end

local function run_command(cmd, done)
	local started = now_ms()
	local function complete(err)
		S.last_command_id = math.max(S.last_command_id, tonumber(cmd.id) or 0)
		report("command_done", { command_id = cmd.id, error = err, elapsed_ms = now_ms() - started }, done)
	end
	-- Entry points are looked up at call time: a reload replaces them.
	if cmd.type == "execute" then
		local fn = rawget(_G, "ExecuteCommand")
		if type(fn) ~= "function" then return complete("no ExecuteCommand") end
		local ok, err = pcall(fn, cmd.command, cmd.params or {})
		complete(not ok and tostring(err) or nil)
	elseif cmd.type == "set_property" then
		local name = tostring(cmd.name)
		local value = cmd.value == nil and "" or tostring(cmd.value)
		local ok, err = pcall(function()
			C4:UpdateProperty(name, value)
			-- Director updates Properties before OnPropertyChanged; do the same.
			local props = rawget(_G, "Properties")
			if type(props) == "table" then props[name] = value end
			local fn = rawget(_G, "OnPropertyChanged")
			if type(fn) == "function" then fn(name) end
		end)
		complete(not ok and tostring(err) or nil)
	elseif cmd.type == "reload" then
		if S.bundle then return apply_bundle(S.bundle, S.version, complete) end
		fetch_bundle(function(files, version, err)
			if not files then return complete(err) end
			apply_bundle(files, version, complete)
		end)
	else
		complete("unknown command type " .. tostring(cmd.type))
	end
end

local function run_queue(commands, index)
	local cmd = commands[index]
	if type(cmd) ~= "table" then return step_log() end
	run_command(cmd, function() run_queue(commands, index + 1) end)
end

local function step_commands()
	request("GET", "/commands?after=" .. tostring(S.last_command_id), nil, function(r)
		local list = r.ok and type(r.json) == "table" and r.json.commands
		if type(list) ~= "table" then return step_log() end
		run_queue(list, 1)
	end)
end

local function step_manifest()
	request("GET", "/manifest", nil, function(r)
		local j = r.json
		if not r.ok or type(j) ~= "table" or j.version == nil then
			if not S.unreachable then
				say("server %s unreachable: %s", S.host, tostring(r.err or "malformed manifest"))
				S.unreachable = true
			end
			S.busy = false
			return
		end
		if S.unreachable then
			say("server %s reachable again", S.host)
			S.unreachable = false
		end
		if tostring(j.version) == S.version then return step_commands() end
		fetch_bundle(function(files, version, err)
			if not files then
				say("%s", err)
				return step_commands()
			end
			apply_bundle(files, version, step_commands)
		end)
	end)
end

local function tick()
	if S.busy then
		S.busy_ticks = S.busy_ticks + 1
		if S.busy_ticks < devloop.STUCK_TICKS then return end
		say("previous tick still in flight after %d ticks; abandoning it", S.busy_ticks)
		S.gen = S.gen + 1 -- its callbacks are dropped from here on
	end
	S.busy, S.busy_ticks = true, 0
	step_manifest()
end

-- Public API ------------------------------------------------------------------

function devloop.stop()
	if S.timer then
		pcall(function() S.timer:Cancel() end)
		S.timer = nil
	end
	S.gen = S.gen + 1
	S.busy = false
	if S.host then
		say("stopped")
		S.host = nil
	end
	unwrap_print()
	unwrap_update_property()
end

-- Returns true when the loop is running afterwards.
function devloop.start(host_port)
	host_port = tostring(host_port or ""):match("^%s*(.-)%s*$")
	if host_port == "" then
		devloop.stop()
		return false
	end
	if S.timer and S.host == host_port then return true end
	devloop.stop()
	S.host = host_port
	S.gen = S.gen + 1
	S.busy, S.busy_ticks, S.unreachable = false, 0, false
	wrap_print()
	wrap_update_property()
	S.timer = C4:SetTimer(devloop.INTERVAL_MS, function() guarded(tick) end, true)
	say("started against http://%s", host_port)
	-- The startup report is the first chain, so the first tick waits for it.
	S.busy = true
	report("startup", { sandbox = sandbox_facts() }, function() S.busy = false end)
	return true
end

function devloop.running()
	return S.timer ~= nil
end

function devloop.version()
	return S.version
end

return devloop
