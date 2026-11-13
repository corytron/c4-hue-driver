-- The feature ledger (#334, docs/simplify-research-compat.md §4 and §6.2):
-- every capability built up to beta 8 keeps a path that reaches it, so the
-- simplification of the actions (docs/simplify-actions-design.md §1.2 to
-- §1.8) cannot drop a feature without this spec failing. The data is
-- tests/fixtures/ledger.lua: a change that moves a feature edits that file
-- (the new path, the old command as an alias), not this one.
--
-- 1. Every <action> of the four driver.xml files, as a dev build and as a
--    release build (the DEV-ONLY blocks stripped, no common/devloop.lua),
--    reaches a dispatch handler through the driver's real ExecuteCommand,
--    both as Composer sends a click (LUA_ACTION) and as the dev loop,
--    tools/regress.sh or C4:SendToDevice send it (the bare command), on a
--    fresh driver that is neither paired nor bound: it raises nothing and
--    writes a row, and every CUSTOM_SELECT picker it names answers a list.
--    A driver may have no action (1.2: the Hue Light and the Hue Scene).
-- 2. sort_order is on every action or on none, and no two share one (a
--    duplicate hides an action in Composer, docs/simplify-research-composer.md);
--    the same for the programming commands, zero-based. No two actions share
--    a name or a dispatch key. The actions are 1.2's (ledger.actions,
--    docs/simplify-actions-design.md §3.3) in that order, a dev build has no
--    action a release build lacks, and the merged actions' parameters are
--    the pickers and LIST items bridge/actions.lua serves.
-- 3. Every ledger row resolves: each path (action, with the picker values
--    that reach the feature and the module method they end in, property and
--    its type, programming command, event, conditional, proxy, proxy command,
--    connection, inter-driver message, documentation page, automatic with
--    the spec or module that proves it, alias) exists and reaches its
--    handler; each gate has a path of its kind; every action belongs to a row.
-- 4. Every alias reaches a handler, stays out of driver.xml and expires: the
--    spec fails once the code's version line reaches the alias's expiry. A
--    dev alias answers in dev builds only. Every command an earlier
--    driver.xml had is an action or an alias, and bridge/actions.lua's
--    aliases are the ledger's.
-- 5. Pending: background tasks never create, rename, bind or delete a device
--    on their own over a simulated week.

local fake = require("helpers.fake_c4")
local log = require("common.log")
local LEDGER = require("fixtures.ledger")
local ACTIONS = require("bridge.actions")

local DRIVERS = { "hue_bridge", "hue_light", "hue_scene", "hue_motion" }
local IS_DRIVER = { hue_bridge = true, hue_light = true, hue_scene = true, hue_motion = true }
local FORMS = { "dev", "release" }
local DEFAULT_DRIVER = "hue_bridge"
local DEVICE_ID = { hue_bridge = 15, hue_light = 2101, hue_scene = 2101, hue_motion = 2101 }

local function read(path)
	local file = assert(io.open(path), "cannot read " .. path)
	local text = file:read("*a")
	file:close()
	return text
end

local function readable(path)
	local file = io.open(path)
	if file then file:close() end
	return file ~= nil
end

-- The dispatch key of a command (common/dispatch.lua).
local function dispatch_key(name)
	return (string.gsub(name or "", "%s+", "_"))
end

-- driver.xml ------------------------------------------------------------------

local function trim(s)
	return s and (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function field(body, tag)
	return body and trim(body:match("<" .. tag .. ">(.-)</" .. tag .. ">"))
end

local function each(body, tag)
	local out = {}
	for inner in (body or ""):gmatch("<" .. tag .. ">(.-)</" .. tag .. ">") do out[#out + 1] = inner end
	return out
end

-- The bodies of the <tag> blocks of a section, with their <params> parsed.
local function entries(xml, section, tag)
	local out = {}
	for _, body in ipairs(each(xml:match("<" .. section .. ">(.-)</" .. section .. ">"), tag)) do
		local own = body:gsub("<params>.-</params>", "")
		local entry = { name = field(own, "name"), command = field(own, "command"), type = field(own, "type"),
			sort_order = field(own, "sort_order"), id = tonumber(field(own, "id")), params = {}, items = {} }
		for _, param in ipairs(each(body:match("<params>(.-)</params>"), "param")) do
			local items = {}
			for _, item in ipairs(each(param:match("<items>(.-)</items>"), "item")) do items[#items + 1] = trim(item) end
			entry.params[#entry.params + 1] = { name = field(param, "name"), type = field(param, "type"), items = items }
		end
		for _, item in ipairs(each(own:match("<items>(.-)</items>"), "item")) do
			entry.items[#entry.items + 1] = trim(item)
		end
		out[#out + 1] = entry
	end
	return out
end

local function index(list, by)
	local out = {}
	for _, entry in ipairs(list) do
		if entry[by] then out[entry[by]] = entry end
	end
	return out
end

-- driver.xml as Composer gets it from a dev build, or from a release build
-- with the DEV-ONLY blocks stripped as tools/build.sh strips them.
local models = {}
local function model(driver, form)
	local id = driver .. "/" .. form
	if models[id] then return models[id] end
	local xml = read("src/" .. driver .. "/driver.xml")
	if form == "release" then
		xml = xml:gsub("<!%-%- DEV%-ONLY BEGIN.-<!%-%- DEV%-ONLY END %-%->", "")
	end
	xml = xml:gsub("<!%-%-.-%-%->", "")
	local m = {
		actions = entries(xml, "actions", "action"),
		commands = entries(xml, "commands", "command"),
		properties = entries(xml, "properties", "property"),
		events = entries(xml, "events", "event"),
		conditionals = entries(xml, "conditionals", "conditional"),
		connections = {},
		proxies = {},
		documentation = xml:match('<documentation%s+file="([^"]+)"'),
	}
	for _, body in ipairs(each(xml:match("<connections>(.-)</connections>"), "connection")) do
		m.connections[#m.connections + 1] = { name = field(body, "connectionname"), id = tonumber(field(body, "id")) }
	end
	for value in xml:gmatch("<proxy%s[^>]*>(.-)</proxy>") do m.proxies[trim(value)] = true end
	for value in xml:gmatch("<proxy>(.-)</proxy>") do m.proxies[trim(value)] = true end
	m.action_by_command = index(m.actions, "command")
	m.command_by_name = index(m.commands, "name")
	m.property_by_name = index(m.properties, "name")
	m.event_by_name = index(m.events, "name")
	m.conditional_by_name = index(m.conditionals, "name")
	m.connection_by_name = index(m.connections, "name")
	models[id] = m
	return m
end

local function param_names(entry)
	local names = {}
	for _, param in ipairs(entry.params) do names[#names + 1] = param.name end
	return names
end

-- The fake driver -------------------------------------------------------------

-- `fn()` with the modules of a release build: no common.devloop, hence no
-- bridge/devtools.lua (as tests/spec/devloop_spec.lua does).
local function in_form(form, fn)
	if form ~= "release" then return fn() end
	package.loaded["common.devloop"] = nil
	package.preload["common.devloop"] = function() error("module 'common.devloop' not found") end
	local ok, result = pcall(fn)
	package.preload["common.devloop"] = nil
	package.loaded["common.devloop"] = nil
	if not ok then error(result, 0) end
	return result
end

-- Every handler of a dispatch table records its name before it runs.
local function wrap(handlers, hits)
	for name, fn in pairs(handlers) do
		if type(fn) == "function" then
			handlers[name] = function(...)
				hits[#hits + 1] = name
				return fn(...)
			end
		end
	end
end

-- A driver loaded and started as Director would (OnDriverInit, then
-- OnDriverLateInit, nothing paired, nothing bound), with its dispatch
-- tables wrapped so the spec sees which handler ran.
local function fresh(driver)
	local env = fake.load_driver(driver, {}, { device_id = DEVICE_ID[driver] })
	local dispatch = package.loaded["common.dispatch"]
	fake.as(env, env.OnDriverInit, "DIT_ADDING")
	fake.as(env, env.OnDriverLateInit, "DIT_ADDING")
	local hits = { commands = {}, proxy = {} }
	wrap(dispatch.commands, hits.commands)
	wrap(dispatch.proxy, hits.proxy)
	return { env = env, hits = hits }
end

-- One call into a driver: the handler it reached (nil: the unknown-command
-- path), whether it raised, the [ERROR] lines it logged (a handler that
-- failed is logged so by common/dispatch.lua), the rows it wrote.
local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do out[k] = v end
	return out
end

local function send(driver_run, how, name, binding, params)
	local env, hits = driver_run.env, driver_run.hits
	local list = how == "proxy" and hits.proxy or hits.commands
	local from = #list + 1
	local errors = {}
	local saved = log.sink
	log.sink = function(line)
		if line:find("[ERROR]", 1, true) then errors[#errors + 1] = line end
	end
	env.C4.calls = {}
	local ok, value = pcall(fake.as, env, function()
		if how == "click" then
			local p = copy(params)
			p.ACTION = name
			return env.ExecuteCommand("LUA_ACTION", p)
		elseif how == "by_name" then
			return env.ExecuteCommand(name, copy(params))
		elseif how == "proxy" then
			return env.ReceivedFromProxy(binding or 5001, name, {})
		elseif how == "condition" then
			return env.TestCondition(name, { LOGIC = "EQUAL", VALUE = "0" })
		end
		error("unknown way to send: " .. tostring(how))
	end)
	log.sink = saved
	local rows = 0
	for _, call in ipairs(env.C4.calls) do
		if call.name == "UpdateProperty" then rows = rows + 1 end
	end
	return { reached = list[from], raised = (not ok) and tostring(value) or nil, errors = errors, rows = rows,
		value = ok and value or nil }
end

local function params_text(params)
	local keys = {}
	for k in pairs(params or {}) do keys[#keys + 1] = k end
	table.sort(keys)
	for i, k in ipairs(keys) do keys[i] = string.format("%s=%s", k, tostring(params[k])) end
	return "{" .. table.concat(keys, ", ") .. "}"
end

-- An action, clicked on a driver of its own and then sent by name to it,
-- with `params` (none: as the click on the Actions tab before any pick);
-- memoised, since the XML checks and the ledger rows ask for the same ones.
local probes = {}
local function probe_action(form, driver, command, params)
	local id = table.concat({ "action", form, driver, command, params_text(params) }, "|")
	if not probes[id] then
		probes[id] = in_form(form, function()
			local run = fresh(driver)
			local result = send(run, "click", command, nil, params)
			result.by_name = send(run, "by_name", command, nil, params)
			return result
		end)
	end
	return probes[id]
end

-- A programming command on a driver of its own (Director sends it by name).
local function probe_command(form, driver, name)
	local id = table.concat({ "command", form, driver, name }, "|")
	if not probes[id] then
		probes[id] = in_form(form, function() return send(fresh(driver), "by_name", name) end)
	end
	return probes[id]
end

-- Messages, proxy commands and conditionals only have to reach their
-- handler: they share one started driver per build and driver.
local shared_runs = {}
local function probe_shared(form, driver, how, name, binding)
	local id = table.concat({ how, form, driver, name, tostring(binding) }, "|")
	if not probes[id] then
		probes[id] = in_form(form, function()
			local run_id = form .. "/" .. driver
			shared_runs[run_id] = shared_runs[run_id] or fresh(driver)
			return send(shared_runs[run_id], how, name, binding)
		end)
	end
	return probes[id]
end

-- What is wrong with a click and a by-name send of one action, or nil.
local function action_problem(result)
	if not result.reached then return "reaches no handler when clicked (the unknown-command path)" end
	if not result.by_name.reached then return "reaches no handler when sent by name" end
	for _, r in ipairs({ result, result.by_name }) do
		if r.raised then return "raised: " .. r.raised end
		if r.errors[1] then return "logged " .. r.errors[1] end
	end
	if result.rows == 0 then return "says nothing: a click on a fresh driver wrote no row" end
	return nil
end

-- What is wrong with a bridge command that only a signed dev loop command
-- runs (#484, ledger.aliases' signed), on a fresh driver of `form` (default
-- "dev"), or nil: the bridge handed the loop a handler of that dispatch name,
-- and devloop.execute runs it without an error or an [ERROR] line.
local function signed_problem(command, form)
	return in_form(form or "dev", function()
		-- The loop's state outlives a driver load: only this load's handlers count.
		local loop = rawget(_G, "__DEVLOOP")
		if type(loop) == "table" then loop.signed_commands = nil end
		fresh("hue_bridge")
		local key = (command:gsub("%s+", "_"))
		loop = rawget(_G, "__DEVLOOP")
		if type(loop) ~= "table" or type(loop.signed_commands) ~= "table"
			or type(loop.signed_commands[key]) ~= "function" then
			return "no signed handler " .. key
		end
		local errors, saved = {}, log.sink
		log.sink = function(line)
			if line:find("[ERROR]", 1, true) then errors[#errors + 1] = line end
		end
		local ok, err = pcall(require("common.devloop").execute, command, {})
		log.sink = saved
		if not ok or err ~= nil then return "signed: " .. tostring(err) end
		return errors[1] and ("signed: logged " .. errors[1]) or nil
	end)
end

-- Versions (the alias expiry) -------------------------------------------------

local function xy(text)
	local major, minor = tostring(text or ""):match("^(%d+)%.(%d+)$")
	return major and { tonumber(major), tonumber(minor) } or nil
end

local function at_least(v, w)
	return v[1] > w[1] or (v[1] == w[1] and v[2] >= w[2])
end

-- The version line this code is built for: the newest X.Y that
-- .github/codenames.json names or CHANGELOG.md has released. An X.Y gets its
-- codename before its first build (CLAUDE.md), so an alias that expires at
-- 2.0 fails the suite as soon as 2.0 work starts, never after 2.0 shipped
-- with it. The driver.xml <version> is a build's commit count and says
-- nothing about the line.
local function version_line()
	local best
	local function consider(major, minor)
		local v = { tonumber(major), tonumber(minor) }
		if not best or not at_least(best, v) then best = v end
	end
	for major, minor in read(".github/codenames.json"):gmatch('"(%d+)%.(%d+)"%s*:') do consider(major, minor) end
	for line in read("CHANGELOG.md"):gmatch("[^\n]+") do
		local major, minor = line:match('^## (%d+)%.(%d+) "')
		if major then consider(major, minor) end
	end
	return best
end

-- Picker values (pick, via) -----------------------------------------------------

-- bridge/actions.lua over spy modules that answer the public methods the
-- real ones have, each with one thing to pick: the place to prove that a
-- picked value reaches the module method a feature lives in, whatever the
-- house's bridge holds. One device per kind; "<rid>" is the thing of the
-- prefix's kind, "<device_id>" the via module's device, "<row>" a names row.
local SPY_RID = { light = "L1", group = "G1", scene = "S1", sensor = "M1", area = "A1", ["f:scenes"] = "R1" }
local SPY_DEVICE = { lights = 1001, zone_lights = 1101, scenes = 1201, motion = 1301 }
local SPY_ROW = "row:1002:hue"

local function substitute(value, via)
	value = tostring(value)
	local prefix = value:match("^(.-):<rid>$")
	if prefix then return prefix .. ":" .. tostring(SPY_RID[prefix]) end
	if value == "dev:<device_id>" then
		return "dev:" .. tostring(SPY_DEVICE[tostring(via):match("^([%w_]+):")])
	end
	if value == "<row>" then return SPY_ROW end
	return value
end

local function spy_world()
	local w = { said = {}, called = {}, calls = {}, errors = {} }
	local function spy_list(...)
		local out = {}
		for i = 1, select("#", ...), 2 do out[#out + 1] = { text = select(i, ...), value = select(i + 1, ...) } end
		return out
	end
	local function finish(...)  -- the last argument is done(ok, text)
		local cb = select(select("#", ...), ...)
		if type(cb) == "function" then cb(true, "done") end
		return true
	end
	local function ok() return true, "done" end
	local function text() return "done" end
	local function devices(id) return function() return spy_list("device " .. id, tostring(id)) end end
	local function owner(id, more)
		local m = { picker_relink_devices = devices(id), picker_forget_devices = devices(id), relink = ok, forget = ok,
			link_devices = text, adopt_hue_names = text, accept_names = text }
		for k, v in pairs(more) do m[k] = v end
		return m
	end
	local defs = {
		lights = owner(1001, { picker_lights = function() return spy_list("Light", "L1") end,
			picker_rooms = function() return spy_list("(mapped room)", "mapped", "Office", "7") end,
			add_light = finish, import_new = finish, new_count = function() return 1 end,
			bridge_count = function() return 1 end }),
		zone_lights = owner(1101, { picker_groups = function() return spy_list("Zone", "G1") end, add = finish,
			device_ids = function() return { [1101] = true } end }),
		scenes = owner(1201, { picker_scenes = function() return spy_list("Kitchen: Relax", "S1") end,
			record_of = function() return { group_rid = "R1" } end, group_label = function() return "Kitchen" end,
			add_scene = finish, add_all_of_group = finish }),
		motion = owner(1301, { picker_sensors = function() return spy_list("Sensor", "M1") end,
			picker_areas = function() return spy_list("Area", "A1") end, new_records = function() return { {} } end,
			add = finish, import_new = finish }),
		names = { resolve = finish, resolve_rows = function()
			return spy_list("Composer names to Hue", "names:composer_to_hue", "Hue names to Composer",
				"names:hue_to_composer", "Desk: rename to Desk Lamp", SPY_ROW)
		end },
	}
	local function quiet() end
	local ctx = { last_action = function(t) w.said[#w.said + 1] = t end, can = function() return true end,
		log = { always = quiet, info = quiet, debug = quiet, warn = quiet,
			error = function(fmt, ...) w.errors[#w.errors + 1] = string.format(fmt, ...) end } }
	for key, methods in pairs(defs) do
		local m = {}
		for name, fn in pairs(methods) do
			m[name] = function(_, ...)
				w.called[key .. ":" .. name] = true
				w.calls[#w.calls + 1] = key .. ":" .. name
				return fn(...)
			end
		end
		ctx[key] = m
	end
	w.a = ACTIONS.new(ctx)
	return w
end

-- Whether a CUSTOM_SELECT list function offers `value`: a leaf or a
-- selectable folder, folders opened (each once, four deep at most).
local function offers(list_fn, value)
	local seen = {}
	local function visit(folder_value, depth)
		if seen[folder_value] or depth > 4 then return false end
		seen[folder_value] = true
		local list = list_fn(folder_value)
		for _, e in ipairs(type(list) == "table" and list or {}) do
			if e.value == value and (not e.folder or e.selectable) then return true end
			if e.folder and visit(e.value, depth + 1) then return true end
		end
		return false
	end
	return visit("", 0)
end

-- The real driver's list function, on a fresh driver of the build.
local function real_offers(form, driver, fn, value)
	return in_form(form, function()
		local run = fresh(driver)
		if type(run.env[fn]) ~= "function" then return false end
		return offers(function(f) return fake.custom_select(run.env, fn, f) end, value)
	end)
end

local function runner_of(command)
	for _, spec in ipairs(ACTIONS.ACTIONS) do
		if spec.command == command then return spec end
	end
	return nil
end

local function has_item(items, value)
	for _, item in ipairs(items or {}) do
		if item == value then return true end
	end
	return false
end

-- An action path with `pick`: each value is offered by its parameter's
-- LIST or picker; with `via`, bridge/actions.lua's runner takes it to that
-- module method; and the real driver, clicked with those values, reaches
-- its handler, raises nothing and writes a row.
local function check_picks(path, driver, action, problem)
	local params = {}
	for name, value in pairs(path.pick) do params[name] = substitute(value, path.via) end
	local by_name = {}
	for _, param in ipairs(action.params) do by_name[param.name] = param end
	for name, value in pairs(params) do
		local param = by_name[name]
		local fn = param and (param.type or ""):match("^CUSTOM_SELECT:(.+)$")
		if not param then
			problem("has no parameter %q", name)
		elseif param.type == "LIST" then
			if not has_item(param.items, value) then problem("%s: %q is not one of its LIST items", name, value) end
		elseif not fn then
			problem("%s is a %s, not a LIST or a CUSTOM_SELECT", name, tostring(param.type))
		elseif path.via then
			local method = ACTIONS.LISTS[fn]
			if not method then
				problem("%s: driver.xml names %s, a list bridge/actions.lua does not serve", name, fn)
			else
				local w = spy_world()
				if not offers(function(f) return w.a[method](w.a, f) end, value) then
					problem("%s: bridge/actions.lua's %s does not offer %q", name, method, value)
				end
			end
		elseif path.dev then
			if not real_offers("dev", driver, fn, value) then problem("%s: the dev build's %s lacks %q", name, fn, value) end
			if real_offers("release", driver, fn, value) then
				problem("%s: the release build's %s offers the dev value %q", name, fn, value)
			end
		elseif not real_offers("release", driver, fn, value) then
			problem("%s: the release build's %s does not offer %q", name, fn, value)
		end
	end
	if path.via then
		local spec = runner_of(path.action)
		if not spec then
			problem("bridge/actions.lua runs no action %q (ACTIONS)", path.action)
		else
			local w = spy_world()
			w.a[spec.runner](w.a, params)
			if not w.called[path.via] then
				problem("%s with %s does not reach %s (it called %s; Last Action %q)", spec.runner, params_text(params),
					path.via, table.concat(w.calls, ", "), tostring(w.said[#w.said]))
			end
			if #w.said == 0 then problem("%s with %s ends in no Last Action", spec.runner, params_text(params)) end
			if w.errors[1] then problem("%s raised: %s", spec.runner, w.errors[1]) end
		end
	end
	local why = action_problem(probe_action(path.dev and "dev" or "release", driver, path.action, params))
	if why then problem("clicked with %s: %s", params_text(params), why) end
end

-- The ledger ------------------------------------------------------------------

local KINDS = { "action", "property", "command", "event", "conditional", "proxy", "proxy_command", "connection",
	"message", "documentation", "auto", "alias" }

-- Each gate needs, for every group, a path of one of the group's kinds.
local GATES = {
	click = { { "action" } },
	auto = { { "auto" } },
	prop = { { "property", "proxy" } },
	prog = { { "command", "event", "conditional" } },
	proxy = { { "proxy", "proxy_command" } },
	offered = { { "auto" }, { "action" } },
}

local function kind_of(path)
	local found
	for _, kind in ipairs(KINDS) do
		if path[kind] ~= nil then
			if found then return nil end
			found = kind
		end
	end
	return found
end

local function alias_driver(alias)
	return alias.driver or DEFAULT_DRIVER
end

local function find_alias(command, driver)
	for _, alias in ipairs(LEDGER.aliases) do
		if alias.command == command and alias_driver(alias) == driver then return alias end
	end
	return nil
end

-- Checks one path against the drivers; adds what is wrong to `problems`.
local resolvers = {}

function resolvers.action(path, driver, problem)
	-- dev with pick: a value only dev builds offer, of an action both have.
	local form = (path.dev and not path.pick) and "dev" or "release"
	local action = model(driver, form).action_by_command[path.action]
	if not action then
		return problem("not the <command> of an action of the %s build", form)
	end
	if path.dev and not path.pick and model(driver, "release").action_by_command[path.action] then
		problem("marked dev, but the release build has it too")
	end
	local want, got = path.params or {}, param_names(action)
	if table.concat(want, "|") ~= table.concat(got, "|") then
		problem("parameters are {%s}, the ledger says {%s}", table.concat(got, ", "), table.concat(want, ", "))
	end
	if path.via and not path.pick then problem("names via but no pick") end
	if path.pick then
		return check_picks(path, driver, action, problem)
	end
	local why = action_problem(probe_action(form, driver, path.action))
	if why then problem("%s", why) end
end

function resolvers.property(path, driver, problem)
	local property = model(driver, path.dev and "dev" or "release").property_by_name[path.property]
	if not property then return problem("not a property of driver.xml") end
	if not path.type then return problem("the ledger names no type") end
	if property.type ~= path.type then problem("is a %s, the ledger says %s", tostring(property.type), path.type) end
	local have = {}
	for _, item in ipairs(property.items) do have[item] = true end
	for _, item in ipairs(path.items or {}) do
		if not have[item] then problem("lost its item %q", item) end
	end
end

function resolvers.command(path, driver, problem)
	local command = model(driver, "release").command_by_name[path.command]
	if not command then return problem("not a programming <command> of driver.xml") end
	local want, got = path.params or {}, param_names(command)
	if table.concat(want, "|") ~= table.concat(got, "|") then
		problem("parameters are {%s}, the ledger says {%s}", table.concat(got, ", "), table.concat(want, ", "))
	end
	local result = probe_command("release", driver, path.command)
	if not result.reached then problem("reaches no handler") end
	if result.raised then problem("raised: %s", result.raised) end
	if result.errors[1] then problem("logged %s", result.errors[1]) end
end

local function fixed_id(kind)
	return function(path, driver, problem)
		local entry = model(driver, "release")[kind .. "_by_name"][path[kind]]
		if not entry then return problem("not a <%s> of driver.xml", kind) end
		if path.id ~= nil and entry.id ~= path.id then
			problem("has the id %s, the ledger says %s", tostring(entry.id), tostring(path.id))
		end
		return entry
	end
end

resolvers.event = fixed_id("event")
resolvers.connection = fixed_id("connection")

function resolvers.conditional(path, driver, problem)
	if not fixed_id("conditional")(path, driver, problem) then return end
	local result = probe_shared("release", driver, "condition", path.conditional)
	if type(result.value) ~= "boolean" then
		problem("TestCondition answers %s, not a boolean%s", type(result.value),
			result.raised and (" (" .. result.raised .. ")") or "")
	end
end

function resolvers.proxy(path, driver, problem)
	if not model(driver, "release").proxies[path.proxy] then problem("not a <proxy> of driver.xml") end
end

function resolvers.proxy_command(path, driver, problem)
	if not probe_shared("release", driver, "proxy", path.proxy_command, path.binding).reached then
		problem("reaches no ReceivedFromProxy handler")
	end
end

function resolvers.message(path, driver, problem)
	if not probe_shared("release", driver, "by_name", path.message).reached then
		problem("reaches no ExecuteCommand handler")
	end
end

function resolvers.documentation(path, driver, problem)
	local m = model(driver, "release")
	if m.documentation ~= path.documentation then
		return problem("driver.xml documents %s", tostring(m.documentation))
	end
	local file = "src/" .. driver .. "/" .. path.documentation
	if not readable(file) then return problem("%s is missing", file) end
	if path.find and not read(file):find(path.find, 1, true) then problem("%s lacks %q", file, path.find) end
end

function resolvers.auto(path, _, problem)
	if path.waits then
		return problem("waits for %s", tostring(path.waits))
	end
	local proof = path.proof
	if type(proof) ~= "table" or not (proof.spec or proof.module) then
		return problem("names no proof (a spec and a test, or a module and its text)")
	end
	local file = proof.spec or proof.module
	if not readable(file) then return problem("its proof %s is missing", file) end
	local text = proof.spec and proof.test or proof.find
	if type(text) ~= "string" or text == "" then
		return problem("its proof names no %s in %s", proof.spec and "test" or "text", file)
	end
	if not read(file):find(text, 1, true) then problem("%s no longer has %q", file, text) end
end

function resolvers.alias(path, driver, problem)
	if not find_alias(path.alias, driver) then problem("not listed in ledger.aliases") end
end

local function resolve(path, problems)
	local kind = kind_of(path)
	local driver = path.driver or DEFAULT_DRIVER
	local label = string.format("%s %q (%s)", kind or "path", tostring(kind and path[kind]), driver)
	local function problem(fmt, ...)
		problems[#problems + 1] = label .. ": " .. string.format(fmt, ...)
	end
	if not kind then return problem("has no kind, or two: one of %s", table.concat(KINDS, ", ")) end
	if not IS_DRIVER[driver] then return problem("names no driver of src/") end
	resolvers[kind](path, driver, problem)
end

-- "P1 Pair with the bridge … [click]: Pair Bridge, Bridge IP Address, … (+3)":
-- the row as busted -o TAP or --list shows it, the paths an owner could
-- name first (actions, programming commands, properties), at most five.
local SHOWN_KINDS = { "action", "command", "alias", "property", "proxy", "event", "connection" }
local function describe_row(row)
	local parts, seen, more = {}, {}, 0
	for _, kind in ipairs(SHOWN_KINDS) do
		for _, path in ipairs(row.paths or {}) do
			local text = kind_of(path) == kind and tostring(path[kind]) or nil
			if text and not seen[text] then
				seen[text] = true
				if #parts < 5 then parts[#parts + 1] = text else more = more + 1 end
			end
		end
	end
	local gates = table.concat(row.gate or {}, "+")
	return string.format("%s %s [%s]%s%s", tostring(row.id), tostring(row.capability), gates ~= "" and gates or "-",
		#parts > 0 and (": " .. table.concat(parts, ", ")) or "", more > 0 and (" (+" .. more .. ")") or "")
end

-- The specs -------------------------------------------------------------------

describe("feature ledger (#334)", function()
	local real_sink

	before_each(function()
		real_sink = log.sink
		log.sink = function() end
	end)

	after_each(function()
		log.sink = real_sink
		-- A dev bridge hands its signed commands to the loop, whose state
		-- outlives a driver load (_G.__DEVLOOP): leave none behind.
		local loop = package.loaded["common.devloop"]
		if type(loop) == "table" and loop.set_signed_commands then
			loop.set_signed_commands(nil)
			loop.set_redactor(nil)
		end
	end)

	describe("1. every action of every driver.xml", function()
		it("tells a command no handler knows from one that has a handler (the probe's own check)", function()
			local unknown = probe_action("dev", "hue_bridge", "No Such Action")
			assert.is_nil(unknown.reached)
			assert.is_nil(unknown.by_name.reached)
			assert.equal("Pair_Bridge", probe_action("dev", "hue_bridge", "Pair Bridge").reached)
			-- The release form really is one: no bridge/devtools.lua, so no
			-- development handler (HUE_LOG is the one left in the dispatch table
			-- since #484) and no signed one.
			assert.equal("HUE_LOG", probe_action("dev", "hue_bridge", "HUE_LOG").reached)
			assert.is_nil(probe_action("release", "hue_bridge", "HUE_LOG").reached)
			assert.is_nil(signed_problem("Check CA Pinning"))
			assert.is_not_nil(signed_problem("Check CA Pinning", "release"))
			assert.is_nil(model("hue_bridge", "release").action_by_command["Check CA Pinning"])
		end)

		for _, form in ipairs(FORMS) do
			for _, driver in ipairs(DRIVERS) do
				it(driver .. ", " .. form .. " build: reaches its handler clicked and sent by name, raises nothing, "
					.. "writes a row", function()
					local problems = {}
					assert.equal(#(LEDGER.actions[driver] or {}), #model(driver, form).actions,
						"the actions parsed from src/" .. driver .. "/driver.xml")
					for _, action in ipairs(model(driver, form).actions) do
						if not action.command or action.command == "" then
							problems[#problems + 1] = tostring(action.name) .. ": no <command>"
						else
							local why = action_problem(probe_action(form, driver, action.command))
							if why then problems[#problems + 1] = action.command .. ": " .. why end
						end
					end
					assert.same({}, problems)
				end)

				it(driver .. ", " .. form .. " build: every CUSTOM_SELECT picker is a function of the driver "
					.. "and answers a list", function()
					local problems = {}
					in_form(form, function()
						local run
						for _, action in ipairs(model(driver, form).actions) do
							for _, param in ipairs(action.params) do
								local fn = (param.type or ""):match("^CUSTOM_SELECT:(.+)$")
								if fn then
									run = run or fresh(driver)
									local where = action.command .. " / " .. param.name .. " / " .. fn
									if type(run.env[fn]) ~= "function" then
										problems[#problems + 1] = where .. ": not a function of the driver"
									else
										for _, top in ipairs({ false, "" }) do
											local ok, list = pcall(fake.custom_select, run.env, fn, top or nil)
											if not ok then
												problems[#problems + 1] = where .. ": raised " .. tostring(list)
											elseif type(list) ~= "table" then
												problems[#problems + 1] = where .. ": answered a " .. type(list)
											end
										end
									end
								end
							end
						end
					end)
					assert.same({}, problems)
				end)
			end
		end
	end)

	describe("2. sort_order", function()
		-- sort_order on every entry or on none, whole numbers, no two alike;
		-- zero_based for the programming commands [verified: FUND 9/_1, as
		-- src/hue_light/driver.xml cites it].
		local function check_order(list, what, problems, zero_based)
			local with, seen, lowest = 0, {}, nil
			for _, entry in ipairs(list) do
				if entry.sort_order then
					with = with + 1
					local n = tonumber(entry.sort_order)
					local label = what .. " " .. tostring(entry.name)
					if not n or n ~= math.floor(n) then
						problems[#problems + 1] = label .. ": sort_order " .. entry.sort_order .. " is not a whole number"
					elseif seen[n] then
						problems[#problems + 1] = label .. ": sort_order " .. n .. " is " .. seen[n] .. "'s too"
					else
						seen[n] = tostring(entry.name)
						lowest = (lowest == nil or n < lowest) and n or lowest
					end
				end
			end
			if with > 0 and with < #list then
				problems[#problems + 1] = string.format("%d of %d %ss have a sort_order: all or none", with, #list, what)
			end
			if zero_based and lowest and lowest ~= 0 then
				problems[#problems + 1] = what .. "s: sort_order starts at " .. lowest .. ", not 0"
			end
		end

		for _, form in ipairs(FORMS) do
			for _, driver in ipairs(DRIVERS) do
				it(driver .. ", " .. form .. " build: on every action or none, unique; names and commands unique",
					function()
					local m, problems = model(driver, form), {}
					check_order(m.actions, "action", problems)
					check_order(m.commands, "command", problems, true)
					local names, keys = {}, {}
					for _, action in ipairs(m.actions) do
						if names[action.name] then problems[#problems + 1] = "two actions named " .. action.name end
						names[action.name] = true
						local k = dispatch_key(action.command)
						if keys[k] then
							problems[#problems + 1] = action.command .. " and " .. keys[k] .. " share the dispatch key " .. k
						end
						keys[k] = action.command
					end
					assert.same({}, problems)
				end)
			end
		end

		-- The actions as Composer lists them: by sort_order, each with its
		-- parameter names (none: nil, as the ledger writes it).
		local function in_order(driver, form)
			local list = {}
			for _, action in ipairs(model(driver, form).actions) do list[#list + 1] = action end
			table.sort(list, function(a, b) return (tonumber(a.sort_order) or 0) < (tonumber(b.sort_order) or 0) end)
			local out = {}
			for _, action in ipairs(list) do
				out[#out + 1] = { command = action.command, params = #action.params > 0 and param_names(action) or nil }
			end
			return out
		end

		for _, driver in ipairs(DRIVERS) do
			it(driver .. ": the actions are 1.2's (ledger.actions) in sort_order, and a dev build adds none", function()
				assert.same(LEDGER.actions[driver], in_order(driver, "release"))
				assert.same(in_order(driver, "release"), in_order(driver, "dev"))
			end)
		end

		it("hue_bridge: the merged actions take the pickers and LIST items bridge/actions.lua serves", function()
			local problems = {}
			local specs = {}
			for _, spec in ipairs(ACTIONS.ACTIONS) do specs[#specs + 1] = spec end
			-- Forget Pairing's confirmation is the same LIST (§3.3).
			specs[#specs + 1] = { command = "Forget Pairing", params = { { name = "Confirm", items = ACTIONS.CONFIRM_ITEMS } } }
			for _, spec in ipairs(specs) do
				local action = model("hue_bridge", "release").action_by_command[spec.command]
				if not action then
					problems[#problems + 1] = spec.command .. ": not an action of the release driver.xml"
				else
					for i, want in ipairs(spec.params) do
						local got = action.params[i] or {}
						local label = spec.command .. " / " .. want.name
						if got.name ~= want.name then
							problems[#problems + 1] = label .. ": parameter " .. i .. " is " .. tostring(got.name)
						elseif want.list and got.type ~= "CUSTOM_SELECT:" .. want.list then
							problems[#problems + 1] = label .. ": " .. tostring(got.type) .. ", not CUSTOM_SELECT:" .. want.list
						elseif want.items and (got.type ~= "LIST"
								or table.concat(got.items, "|") ~= table.concat(want.items, "|")) then
							problems[#problems + 1] = label .. ": " .. tostring(got.type) .. " {" .. table.concat(got.items, ", ")
								.. "}, not LIST {" .. table.concat(want.items, ", ") .. "}"
						end
					end
				end
			end
			assert.same({}, problems)
		end)
	end)

	describe("3. the ledger rows (tests/fixtures/ledger.lua)", function()
		it("has rows with unique ids, a capability, known gates and at least one path", function()
			local problems, seen = {}, {}
			assert.is_true(#LEDGER.rows > 0)
			for i, row in ipairs(LEDGER.rows) do
				local label = "row " .. i .. " (" .. tostring(row.id) .. ")"
				if type(row.id) ~= "string" or not row.id:match("^[A-Z]%d+$") then
					problems[#problems + 1] = label .. ": id is not a letter and a number"
				elseif seen[row.id] then
					problems[#problems + 1] = label .. ": id used twice"
				end
				seen[row.id or i] = true
				if type(row.capability) ~= "string" or row.capability == "" then
					problems[#problems + 1] = label .. ": no capability"
				end
				if type(row.gate) ~= "table" then
					problems[#problems + 1] = label .. ": gate is not a list"
				else
					for _, gate in ipairs(row.gate) do
						if not GATES[gate] then problems[#problems + 1] = label .. ": unknown gate " .. tostring(gate) end
					end
				end
				if type(row.paths) ~= "table" or #row.paths == 0 then
					problems[#problems + 1] = label .. ": no path"
				end
			end
			assert.same({}, problems)
		end)

		it("names every action of every driver.xml, DEV-ONLY ones included, in at least one row", function()
			local named = {}
			for _, row in ipairs(LEDGER.rows) do
				for _, path in ipairs(row.paths or {}) do
					if path.action then named[(path.driver or DEFAULT_DRIVER) .. "|" .. path.action] = true end
				end
			end
			local orphans = {}
			for _, driver in ipairs(DRIVERS) do
				for _, action in ipairs(model(driver, "dev").actions) do
					if not named[driver .. "|" .. tostring(action.command)] then
						orphans[#orphans + 1] = driver .. ": " .. tostring(action.command)
					end
				end
			end
			assert.same({}, orphans)
		end)

		for _, row in ipairs(LEDGER.rows) do
			it(describe_row(row), function()
				local problems, kinds = {}, {}
				for _, path in ipairs(row.paths or {}) do
					resolve(path, problems)
					local kind = kind_of(path)
					if kind then kinds[kind] = true end
				end
				for _, gate in ipairs(row.gate or {}) do
					for _, group in ipairs(GATES[gate] or {}) do
						local met = false
						for _, kind in ipairs(group) do met = met or kinds[kind] == true end
						if not met then
							problems[#problems + 1] = "gate " .. gate .. " needs a path of kind " .. table.concat(group, " or ")
						end
					end
				end
				assert.same({}, problems)
			end)
		end
	end)

	describe("4. aliases: commands that left driver.xml (ledger.aliases)", function()
		it("compares versions as numbers and knows the version line of this code", function()
			assert.is_true(at_least(xy("2.0"), xy("2.0")))
			assert.is_true(at_least(xy("2.1"), xy("2.0")))
			assert.is_true(at_least(xy("10.0"), xy("2.0")))
			assert.is_true(at_least(xy("1.10"), xy("1.9")))
			assert.is_false(at_least(xy("1.9"), xy("1.10")))
			assert.is_false(at_least(xy("1.2"), xy("2.0")))
			assert.is_nil(xy("2"))
			assert.is_nil(xy("v2.0"))
			local line = version_line()
			assert.is_table(line, "no X.Y in .github/codenames.json or CHANGELOG.md")
			assert.is_true(at_least(line, xy("1.0")))
		end)

		it("each has a command, a target, a known driver and an expiry X.Y", function()
			local problems = {}
			for i, alias in ipairs(LEDGER.aliases) do
				local label = "alias " .. i .. " (" .. tostring(alias.command) .. ")"
				for _, name in ipairs({ "command", "target" }) do
					if type(alias[name]) ~= "string" or alias[name] == "" then
						problems[#problems + 1] = label .. ": no " .. name
					end
				end
				if not xy(alias.expires) then problems[#problems + 1] = label .. ": expires is not X.Y" end
				if not IS_DRIVER[alias_driver(alias)] or not IS_DRIVER[alias.target_driver or alias_driver(alias)] then
					problems[#problems + 1] = label .. ": names no driver of src/"
				end
				if find_alias(alias.command, alias_driver(alias)) ~= alias then
					problems[#problems + 1] = label .. ": listed twice"
				end
			end
			assert.same({}, problems)
		end)

		it("keeps every command an earlier driver.xml had: still an action, or an alias", function()
			local problems = {}
			for _, driver in ipairs(DRIVERS) do
				for _, command in ipairs(LEDGER.earlier_commands[driver] or {}) do
					if not model(driver, "dev").action_by_command[command] and not find_alias(command, driver) then
						problems[#problems + 1] = driver .. ": " .. command
					end
				end
			end
			assert.same({}, problems)
		end)

		it("lists bridge/actions.lua's aliases, each with the same target", function()
			local problems = {}
			for command, alias in pairs(ACTIONS.ALIASES) do
				local listed = find_alias(command, "hue_bridge")
				if not listed then
					problems[#problems + 1] = command .. ": not in ledger.aliases"
				elseif listed.target ~= alias.target then
					problems[#problems + 1] = string.format("%s: the ledger says %s, bridge/actions.lua %s", command,
						tostring(listed.target), tostring(alias.target))
				end
			end
			assert.same({}, problems)
		end)

		for _, alias in ipairs(LEDGER.aliases) do
			local driver = alias_driver(alias)
			local target_driver = alias.target_driver or driver
			it(string.format("%s (%s) answers for %s (%s) until %s", tostring(alias.command), driver,
				tostring(alias.target), target_driver, tostring(alias.expires)), function()
				local problems = {}
				if model(driver, "dev").action_by_command[alias.command] then
					problems[#problems + 1] = "still an action of driver.xml: an alias is hidden"
				end
				if not model(target_driver, "dev").action_by_command[alias.target] then
					problems[#problems + 1] = "its target is not an action of " .. target_driver .. "'s driver.xml"
				end
				for _, form in ipairs(FORMS) do
					local result = probe_action(form, driver, alias.command)
					if alias.dev and form == "release" then
						if result.reached or result.by_name.reached then
							problems[#problems + 1] = "a dev command, but the release build answers it"
						end
					elseif alias.signed then
						-- #484: signed dev loop commands only, never any driver's ExecuteCommand.
						if result.reached or result.by_name.reached then
							problems[#problems + 1] = "a signed command, but ExecuteCommand reaches it"
						end
						local why = signed_problem(alias.command)
						if why then problems[#problems + 1] = why end
					elseif not result.reached or not result.by_name.reached then
						problems[#problems + 1] = form .. " build: reaches no handler"
					elseif result.raised or result.by_name.raised or result.errors[1] or result.by_name.errors[1] then
						problems[#problems + 1] = form .. " build: " .. tostring(action_problem(result))
					end
				end
				local line, expires = version_line(), xy(alias.expires)
				if expires and at_least(line, expires) then
					problems[#problems + 1] = string.format("expired: the code is at %d.%d and the alias was kept "
						.. "until %s; remove it (and say so in CHANGELOG.md) or move its expiry", line[1], line[2],
						alias.expires)
				end
				assert.same({}, problems)
			end)
		end
	end)

	describe("5. background tasks (bridge/housekeeping.lua, docs/simplify-actions-design.md §1.3)", function()
		pending("never create, rename, bind or delete a device on their own over a simulated week: run the engine "
			.. "on a fake clock over tests/fixtures/hue_resources.lua (new lights, name differences, unmapped rooms, "
			.. "gone and unbound devices, tombstones, forgotten devices, every setting at its default) and assert "
			.. "no AddDevice, RenameDevice, Bind or Unbind, relink or forget except on ledger rows gated auto "
			.. "(D6 two-way names, D7 re-link by MAC)")
	end)
end)
