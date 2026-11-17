-- The Hue Sync Box driver end to end (#547, docs/fakebox-design.md §6): the
-- real src/hue_syncbox/driver.lua in the fake runtime (tests/helpers/
-- fake_c4.lua), its C4:url over real HTTPS through curl
-- (tests/helpers/real_url.lua) to the Python fake box (tools/fakebox.py),
-- walking the owner's flows. One line per check ("PASS ...", "FAIL ...",
-- "SKIP ..."), a summary, exit 1 on any failure. Not a busted spec: it
-- needs curl and the fake running. Run it through tools/e2e_syncbox.sh,
-- which starts the fake and sets the environment:
--
--   E2E_ARCHIVE     a directory standing for the extracted .c4z: its
--                   certs/hsb_ca.pem is the repository's bundle plus the
--                   fake's CA, certs/decoy.pem the repository's decoy
--   E2E_ADDRESS     the address the driver is given (default the
--                   placeholder 10.0.2.150); the transport routes it to the
--                   fake on the loopback interface, so the release code's
--                   port-443 URLs reach a fake on another port, and nothing
--                   leaves the VM
--   E2E_MAIN        MODEL:ID:PORT of the box the flows pair with (HSB2)
--   E2E_OTHER       MODEL:ID:PORT of another box (another id), for "a wrong
--                   box at the address"
--   E2E_MODELS      MODEL:ID:PORT,... more boxes, each paired, read and
--                   forgotten (HSB1, HSB3, HSB3_standalone)
--   E2E_ROUTING     NAME=MODEL:ID:PORT,... the boxes of the suites that have
--                   one of their own: the routing suites (#557), inline
--                   (HSB2), receiver (HSB2_behind_receiver), second
--                   (HSB2_second_output), onein (HSB3, in line) and faults
--                   (HSB2, in line); and stage 4's (#568), programming,
--                   buttons, periods, offers, area and takeover (each HSB2,
--                   in line)
--   E2E_FAKEBOX     the command that drives the fake: "<it> button --box ID"
--                   (tools/fakebox.py --state-dir <the run's>)
--   E2E_FAKE_TIME_SCALE  the fake's --time-scale (its clock against the
--                   wall's: a restart's 30 s, the button's window)
--   E2E_TIME_SCALE  real seconds per fake second for curl's timeouts
--                   (default 0.25: the driver's 6 s become 1.5 s)
--   E2E_ONLY        comma-separated suites to run (default all, in this
--                   order: pinning, flows, faults, devhooks, models,
--                   routing-inline, routing-onein, routing-receiver,
--                   routing-second, routing-faults, programming, buttons,
--                   periods, offers, area-name, takeover; "routing" names
--                   the five routing ones, "stage4" the six of stage 4).
--                   tools/e2e_syncbox.sh runs the routing suites each in a
--                   process of its own, beside the others: no two suites
--                   that run at once share a box
--   E2E_TRACE       1: every exchange of the transport on stdout
--   E2E_LOG         a file for the driver's log lines (default none)
--
-- Placeholders only (CLAUDE.md): box ids 0A1B2C3D4E5F and neighbours, the
-- address 10.0.2.150; the fake's tokens are random and never printed.

package.path = "src/?.lua;src/hue_syncbox/?.lua;tests/?.lua;" .. package.path

local fake = require("helpers.fake_c4")
local real_url = require("helpers.real_url")
local log = require("common.log")
local json = require("dkjson")

-- Configuration ----------------------------------------------------------------------

local function env(name, default)
	local v = os.getenv(name)
	if v == nil or v == "" then
		return default
	end
	return v
end

local function parse_box(text)
	if not text then
		return nil
	end
	local model, id, port = text:match("^([%w_%-]+):(%x+):(%d+)$")
	assert(model, "a box is MODEL:ID:PORT, not " .. text)
	-- model: the fixture's name (HSB3_standalone); code: the model the box
	-- reports (HSB3).
	return { model = model, code = model:match("^(HS[BC]%d+)") or model, id = id:upper(), port = tonumber(port),
		target = "127.0.0.1:" .. port }
end

local CFG = {
	archive = env("E2E_ARCHIVE"),
	address = env("E2E_ADDRESS", "10.0.2.150"),
	main = parse_box(env("E2E_MAIN")),
	other = parse_box(env("E2E_OTHER")),
	models = {},
	fakebox = env("E2E_FAKEBOX", "python3 -I tools/fakebox.py"),
	fake_scale = tonumber(env("E2E_FAKE_TIME_SCALE", "1")),
	scale = tonumber(env("E2E_TIME_SCALE", "0.25")),
	trace = env("E2E_TRACE") == "1",
	only = env("E2E_ONLY"),
	log_file = env("E2E_LOG"),
}
for item in (env("E2E_MODELS", "")):gmatch("[^,%s]+") do
	CFG.models[#CFG.models + 1] = parse_box(item)
end
CFG.routing = {}
for name, spec in (env("E2E_ROUTING", "")):gmatch("([%w_]+)=([^,%s]+)") do
	CFG.routing[name] = parse_box(spec)
end
assert(CFG.archive, "E2E_ARCHIVE is not set: run tools/e2e_syncbox.sh")
assert(CFG.main or next(CFG.routing), "neither E2E_MAIN nor E2E_ROUTING is set: run tools/e2e_syncbox.sh")

local BOX_DEVICE = 2301
local MINUTE = 60000
local HOUR = 60 * MINUTE

-- Checks -----------------------------------------------------------------------------------

local counts = { pass = 0, fail = 0, skip = 0 }
local suite_name = "-"
local log_lines = {}
local log_out = CFG.log_file and assert(io.open(CFG.log_file, "w")) or nil

log.sink = function(line)
	log_lines[#log_lines + 1] = line
	if log_out then
		log_out:write(line, "\n")
		log_out:flush()
	end
end

local function say(fmt, ...)
	io.stdout:write(string.format(fmt, ...), "\n")
	io.stdout:flush()
end

local function check(name, ok, detail)
	if ok then
		counts.pass = counts.pass + 1
		say("PASS %s: %s", suite_name, name)
	else
		counts.fail = counts.fail + 1
		say("FAIL %s: %s%s", suite_name, name, detail and (" (" .. tostring(detail) .. ")") or "")
	end
	return ok
end

local function skip(name, why)
	counts.skip = counts.skip + 1
	say("SKIP %s: %s (%s)", suite_name, name, why)
end

local function eq(name, expected, actual)
	return check(name, expected == actual, string.format("expected %q, got %q", tostring(expected), tostring(actual)))
end

local function starts(name, prefix, actual)
	actual = tostring(actual)
	return check(name, actual:sub(1, #prefix) == prefix, string.format("expected %q..., got %q", prefix, actual))
end

-- The fake box (tools/fakebox.py) ---------------------------------------------------------

local function q(s)
	return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'"
end

-- Run the fake's command line; returns its output and whether it exited 0.
local function fakebox(args)
	local p = assert(io.popen(CFG.fakebox .. " " .. args .. " 2>&1; echo \"E2E-EXIT $?\""))
	local out = p:read("*a")
	p:close()
	local code = tonumber(out:match("E2E%-EXIT (%d+)%s*$"))
	out = out:gsub("E2E%-EXIT %d+%s*$", "")
	return out, code == 0
end

local fb = {}

function fb.run(box, sub, rest)
	local out, ok = fakebox(sub .. " --box " .. box.id .. (rest and (" " .. rest) or ""))
	if not ok then
		error(string.format("tools/fakebox.py %s --box %s %s failed: %s", sub, box.id, rest or "", out), 0)
	end
	return out
end

-- The button held, its window open for 6 s of real time (the box's own 5 s
-- of its clock would be 0.5 s at --time-scale 10, less than a busy VM may
-- take between this command and the driver's next POST).
function fb.button(box)
	return fb.run(box, "button", "--window " .. string.format("%g", 6 * CFG.fake_scale))
end

-- An event of docs/fakebox-design.md §4, its arguments as name=value.
function fb.event(box, name, args)
	local parts = { q(name) }
	for k, v in pairs(args or {}) do
		parts[#parts + 1] = q(k .. "=" .. tostring(v))
	end
	return fb.run(box, "event", table.concat(parts, " "))
end

-- A fault of the server (tools/fakebox/server.py FAULT_KINDS), its
-- parameters as name=value; fb.clear ends it.
function fb.fault(box, kind, params)
	local parts = { q(kind) }
	for k, v in pairs(params or {}) do
		parts[#parts + 1] = q(k .. "=" .. tostring(v))
	end
	return fb.run(box, "fault", table.concat(parts, " "))
end

function fb.clear(box, kind)
	return fb.run(box, "fault", "clear" .. (kind and (" " .. q(kind)) or ""))
end

-- The fake's request log of the box (tools/fakebox.py log --json): one
-- entry a request, and one a failed TLS handshake (method "TLS").
function fb.log(box)
	local out = fb.run(box, "log", "-n 5000 --json")
	local entries = {}
	for line in out:gmatch("[^\n]+") do
		local entry = json.decode(line)
		if type(entry) == "table" then
			entries[#entries + 1] = entry
		end
	end
	return entries
end

-- The HTTP requests (not TLS failures) among the log's entries after the
-- first `n`.
function fb.http_after(box, n)
	local out = {}
	local entries = fb.log(box)
	for i = n + 1, #entries do
		if entries[i].method ~= "TLS" then
			out[#out + 1] = entries[i]
		end
	end
	return out, #entries
end

-- The box's whole GET /api/v1 document now, decoded (the control API's
-- answer is { state = <document>, status, faults }).
function fb.state(box)
	local out = fb.run(box, "state")
	local doc = json.decode(out:match("^%s*(%b{})") or out)
	assert(type(doc) == "table", "tools/fakebox.py state gave no JSON object: " .. out:sub(1, 200))
	if type(doc.state) == "table" and type(doc.state.device) == "table" then
		return doc.state
	end
	return doc
end

-- The transport and the driver ---------------------------------------------------------------

local function new_transport(opts)
	opts = opts or {}
	local routes = {}
	if opts.route ~= false then
		routes[CFG.address] = (opts.box or CFG.main).target
	end
	return real_url.new({
		archive_dir = opts.archive or CFG.archive,
		routes = routes,
		time_scale = CFG.scale,
		trace = CFG.trace and function(line) say("  url: %s", line) end or nil,
	})
end

-- A Director start of the box device: the runtime, the transport plugged
-- in, the store as persisted (opts.persist), then OnDriverInit and
-- OnDriverLateInit. opts.lan(c4, env): installed before late init (the
-- first search runs there). opts.project(c4, env): the Control4 project as
-- Director has it at the start (rooms, sources, bindings, the rooms'
-- variables), before OnDriverInit.
local function start_driver(T, opts)
	opts = opts or {}
	local denv, c4 = fake.load_driver("hue_syncbox", {}, { device_id = BOX_DEVICE })
	local how = T:install(fake, c4)
	for k, v in pairs(opts.persist or {}) do
		c4.persist[k] = v
	end
	if opts.lan then
		opts.lan(c4, denv)
	end
	if opts.project then
		opts.project(c4, denv)
	end
	denv.OnDriverInit("DIT_STARTUP")
	denv.OnDriverLateInit("DIT_STARTUP")
	return denv, c4, how
end

local function action(denv, name, params)
	local p = { ACTION = name }
	for k, v in pairs(params or {}) do
		p[k] = v
	end
	denv.ExecuteCommand("LUA_ACTION", p)
end

local function P(denv, name)
	return denv.Properties[name]
end

-- Advance the fake clock in steps until pred() holds (true) or max_ms has
-- passed (false).
local function until_(c4, pred, max_ms, step_ms)
	step_ms = step_ms or 1000
	local waited = 0
	while not pred() do
		if waited >= max_ms then
			return false
		end
		c4.advance(step_ms)
		waited = waited + step_ms
	end
	return true
end

local function short(id)
	return "#" .. id:sub(-4):upper()
end

local MODEL_SHORT = { HSB2 = " (8K)", HSB3 = " (4K)" }

local function label(box)
	return "Hue Sync Box" .. (MODEL_SHORT[box.code] or "") .. " " .. short(box.id)
end

-- The transfers of the history after `n` with this method and path whose
-- callbacks the driver has had (settled, tests/helpers/real_url.lua): what
-- the driver knows of them is what the checks read.
local function sent(T, n, method, path)
	local out = {}
	for _, h in ipairs(T:since(n)) do
		if h.settled and (method == nil or h.method == method) and (path == nil or h.path == path) then
			out[#out + 1] = h
		end
	end
	return out
end

-- The rows the driver should show for the fake's state now, by the
-- driver's own describe (the check is that real HTTPS, the fake and the
-- driver agree), else nil and why.
local function expected_rows(box)
	local state = require("syncbox.state")
	local model, why = state.from_api(fb.state(box))
	if not model then
		return nil, why
	end
	return state.describe(model), model
end

local ROWS = { { "Sync", "sync" }, { "Inputs", "inputs" }, { "Model", "model" }, { "Firmware", "firmware" },
	{ "Wiring", "wiring" }, { "Bridge Link", "bridge_link" } }

-- Status as stage 4 writes it: the box's text (describe's refusal or sync),
-- then what needs a person, each after "; " (the room followed, the area,
-- Attention: S4 §1.4, §1.5, §1.7). Whether `status` is that for `d`.
local function status_is(status, d)
	local base = d.refusal or d.sync
	status = tostring(status)
	return status == base or status:sub(1, #base + 2) == base .. "; "
end

-- Input Switching as stage 4 writes it (syncbox/offers.lua's row, or its
-- Attention while Control4 routes through the box): whether `row` agrees
-- with describe's text for the same box (the box switches by itself, or not).
local function switching_is(row, d)
	row = tostring(row)
	local none = tostring(d.input_switching):find("^None") ~= nil
	if none then
		return row:find("^None") ~= nil
	end
	return row:find("^By the box: ") ~= nil or row:find("^Attention: ") ~= nil
end

-- The rows against the fake's state. The fake's clock runs on by itself
-- (a bridge passing through connecting, say), so a state read a moment after
-- the driver's last read may be newer: the driver gets up to three more
-- reads' time (31 s of its clock each) to catch up before a row counts as
-- wrong. `c4` nil: no catching up.
local function rows_follow(denv, box, what, c4)
	local d, model, wrong
	for attempt = 1, c4 and 4 or 1 do
		d, model = expected_rows(box)
		if not d then
			break
		end
		wrong = nil
		for _, r in ipairs(ROWS) do
			if P(denv, r[1]) ~= d[r[2]] then
				wrong = r[1]
			end
		end
		if not status_is(P(denv, "Status"), d) or P(denv, "Sync Box") ~= model.name then
			wrong = "Status"
		end
		if not switching_is(P(denv, "Input Switching"), d) then
			wrong = "Input Switching"
		end
		if not wrong or attempt == 4 then
			break
		end
		c4.advance(31000)
	end
	if not check(what .. ": the fake's state reads as a box state", d ~= nil, model) then
		return
	end
	for _, r in ipairs(ROWS) do
		eq(what .. ": " .. r[1], d[r[2]], P(denv, r[1]))
	end
	check(what .. ": Status", status_is(P(denv, "Status"), d), string.format("expected %q (then notes), got %q",
		tostring(d.refusal or d.sync), tostring(P(denv, "Status"))))
	check(what .. ": Input Switching", switching_is(P(denv, "Input Switching"), d), string.format(
		"expected a row agreeing with %q, got %q", tostring(d.input_switching), tostring(P(denv, "Input Switching"))))
	eq(what .. ": Sync Box", model.name, P(denv, "Sync Box"))
end

-- No log line and no row holds the token.
local function token_kept(denv, c4, what)
	local token = c4.persist.syncbox_token
	if type(token) ~= "string" or token == "" then
		return
	end
	local leaked
	for _, line in ipairs(log_lines) do
		if line:find(token, 1, true) then
			leaked = line
			break
		end
	end
	for name, value in pairs(denv.Properties) do
		if type(value) == "string" and value:find(token, 1, true) then
			leaked = name
		end
	end
	check(what .. ": the token is in no log line and no row", leaked == nil, leaked)
end

-- A Director restart of the device: its store kept, a new runtime.
local function restart(T, denv, c4)
	local persist = {}
	for k, v in pairs(c4.persist) do
		persist[k] = v
	end
	denv.OnDriverDestroyed()
	return start_driver(T, { persist = persist })
end

-- Real time passing (the fake's own clock is the wall's, times its scale).
local function real_sleep(seconds)
	os.execute("sleep " .. string.format("%.2f", seconds))
end

-- The fake's restart (30 s of its clock, model.REBOOT_MS) in real seconds.
local RESTART_S = 30 / CFG.fake_scale

-- The LAN of a start_driver: every mDNS query the driver sends is answered
-- with tools/fakebox/mdns.py's answer for `box` announcing SRV `srv_port`
-- and the address the transport routes (no network: the loopback interface
-- takes no multicast here, and the house LAN must not see a fake box), from
-- the driver's own query bytes. Returns the lan function and a counter of
-- the datagrams handed over.
local function lan_for(box, srv_port)
	local count = 0
	local function lan(c4, denv)
		local original = c4.SendToNetwork
		c4.SendToNetwork = function(self, binding, port, data)
			original(self, binding, port, data)
			local hex = (data:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
			local p = io.popen(string.format("python3 -I tools/fakebox/mdns.py answer --box %s --address %s %s 2>&1",
				q(box.code .. ":" .. box.id .. ":" .. srv_port .. ":Living Room Sync Box"), q(CFG.address), q(hex)))
			local out = p:read("*a")
			p:close()
			for line in out:gmatch("[^\n]+") do
				local bytes = line:match("^%x+$") and line:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
				if bytes then
					count = count + 1
					c4:SetTimer(1, function()
						denv.ReceivedFromNetwork(binding, port, bytes)
					end)
				end
			end
		end
	end
	return lan, function() return count end
end

-- The latest Last Action written after the m-th call of the runtime that
-- matches `pattern` (its first row), else nil. A text the driver writes a
-- moment later can replace the one a check is after (stage 4: right after
-- pairing, the two-way name's first look says why the names wait, when the
-- device is still named "Hue Sync Box"), so the checks read what was said,
-- not only what is shown last.
local function said(c4, m, pattern)
	local found
	for i = (m or 0) + 1, #c4.calls do
		local call = c4.calls[i]
		if call.name == "UpdateProperty" and call.args[1] == "Last Action" and tostring(call.args[2]):find(pattern) then
			found = tostring(call.args[2])
		end
	end
	return found
end

-- Pair Sync Box at `address`, the button pressed on the fake once the
-- window is open. Returns whether the driver says it paired. `what`: the
-- checks' prefix.
local function pair(denv, c4, box, address, T, what)
	what = what and (what .. ": ") or ""
	local n = #T.history
	action(denv, "Pair Sync Box", { Box = "address", Address = address })
	local open = until_(c4, function()
		return #sent(T, n, "POST", "/api/v1/registrations") > 0
	end, 20000)
	check(what .. "the window opens after the identity and TLS checks (a POST /registrations goes out)", open,
		fake.last_action(denv))
	if not open then
		return false
	end
	local waiting = sent(T, n, "POST", "/api/v1/registrations")[1]
	eq(what .. "before the button the box answers the POST with HTTP 400", 400, waiting.status)
	starts(what .. "Status counts the window down", "Hold the button on the sync box for 3 seconds", P(denv, "Status"))
	local m = #c4.calls
	fb.button(box)
	local paired = until_(c4, function()
		return said(c4, m, "^Paired with") ~= nil
	end, 10000)
	check(what .. "paired once the button was pressed", paired, fake.last_action(denv))
	return paired and said(c4, m, "^Paired with") or false
end

-- Suites ----------------------------------------------------------------------------------------

local suites = {}
local order = {}

local function suite(name, fn)
	suites[name] = fn
	order[#order + 1] = name
end

-- Stage 4's suites (#568), each with a box of its own.
local S4_SUITES = { programming = true, buttons = true, periods = true, offers = true, ["area-name"] = true,
	takeover = true }

local function wanted(name)
	if not CFG.only then
		return true
	end
	for item in CFG.only:gmatch("[^,%s]+") do
		if item == name or (item == "routing" and name:find("^routing%-")) or (item == "stage4" and S4_SUITES[name]) then
			return true
		end
	end
	return false
end

-- The repository's bundle alone does not trust the fake: its certificate is
-- refused with curl 60, the driver says the address is no sync box, and
-- nothing more is sent (§6, the negative).
suite("pinning", function()
	local T = new_transport({ archive = "src/hue_syncbox" })
	local tls = { ssl_verify_peer = true, ssl_verify_host = false, ssl_cabundle = "certs/hsb_ca.pem",
		timeout = 6, connect_timeout = 3, fail_on_error = false }
	local hop = T:perform("GET", "https://" .. CFG.address .. "/api/v1/device", nil, {}, tls)
	eq("curl refuses the fake's certificate with only the repository's hsb_ca.pem (curl 60)", 60, hop.exit)
	check("refused for its chain, not its name", tostring(hop.detail):find("verify result", 1, true) ~= nil
		and not tostring(hop.detail):find("does not match", 1, true), hop.detail)
	local good = new_transport()
	local ok = good:perform("GET", "https://" .. CFG.address .. "/api/v1/device", nil, {}, tls)
	eq("with the fake's CA in the bundle the same request is answered (HTTP 200)", 200,
		ok.responses[1] and ok.responses[1].code)
	good:close()

	local _, mark = fb.http_after(CFG.main, 0)
	local denv, c4 = start_driver(T)
	action(denv, "Pair Sync Box", { Box = "address", Address = CFG.address })
	until_(c4, function()
		return fake.last_action(denv):find("^Not paired") ~= nil
	end, 30000)
	eq("the driver says so", "Not paired: " .. CFG.address .. " is not a Hue sync box", fake.last_action(denv))
	local device = sent(T, 0, "GET", "/api/v1/device")
	check("its GET /device ended with curl 60 and no HTTP status", #device > 0 and device[#device].err_code == 60
		and device[#device].status == nil, device[#device] and device[#device].err_code)
	eq("no registration was asked for", 0, #sent(T, 0, "POST", "/api/v1/registrations"))
	eq("Status", "Not paired: run Pair Sync Box", P(denv, "Status"))
	eq("the fake logged no HTTP request from the driver (TLS refused every connection)", 0,
		#fb.http_after(CFG.main, mark))
	T:close()
end)

-- The owner's flows with the HSB2 (§6), in order: add the device, the
-- search, Pair Sync Box from its list, the rows, polling, the box changed
-- in the house, a Director restart, silence and back (the 5-minute rule),
-- the box rebooting, a firmware update, a certificate from another CA,
-- another box behind the address at a restart, a wrong box at the address
-- while paired, the app deleting the registration (401), pairing again,
-- Forget Pairing.
suite("flows", function()
	local box = CFG.main
	local T = new_transport()
	local lan, answered = lan_for(box, 443)

	-- Add the device.
	local _, mark = fb.http_after(box, 0)
	local denv, c4, how = start_driver(T, { lan = lan })
	say("  (transport: %s)", how)
	eq("a new device is not paired", "", P(denv, "Box ID"))
	eq("a new device says so", "Not paired: run Pair Sync Box", P(denv, "Status"))

	-- The search at first load finds the fake (mDNS answer, identity over HTTPS).
	until_(c4, function()
		return P(denv, "Status") ~= "Not paired: run Pair Sync Box"
	end, 30000)
	check("the search's queries got the fake's mDNS answer", answered() > 0, "no answer from mdns.py answer")
	eq("the search finds the box (Status)", "Not paired: 1 Hue sync box found (run Pair Sync Box)", P(denv, "Status"))
	local list = fake.custom_select(denv, "SyncBoxList")
	eq("the Box list names it", label(box) .. ", Living Room Sync Box, " .. CFG.address, list[1] and list[1].text)
	-- Before Pair Sync Box only the search's identity check went out: GET
	-- /api/v1/device (and its TLS self-check's decoy), never with a token.
	local only_identity = #sent(T, 0) > 0
	for _, h in ipairs(sent(T, 0)) do
		only_identity = only_identity and h.method == "GET" and h.path == "/api/v1/device"
	end
	check("before Pair Sync Box only the identity check's GET /api/v1/device went out", only_identity)
	local keyed = 0
	for _, entry in ipairs(fb.http_after(box, mark)) do
		keyed = keyed + (entry.keyed and 1 or 0)
	end
	eq("the fake saw no request with a token from the candidate's check", 0, keyed)

	-- Pair Sync Box, from the list.
	local n = #T.history
	action(denv, "Pair Sync Box", { Box = "box:" .. box.id })
	local open = until_(c4, function()
		return #sent(T, n, "POST", "/api/v1/registrations") > 0
	end, 20000)
	check("Pair Sync Box from the list opens the window", open, fake.last_action(denv))
	local decoy = sent(T, n, "GET", "/api/v1/device")
	local pinned = false
	for _, h in ipairs(decoy) do
		pinned = pinned or h.err_code == 60
	end
	check("the TLS self-check's decoy request is refused (curl 60)", pinned)
	local m = #c4.calls
	fb.button(box)
	local paired = until_(c4, function()
		return said(c4, m, "^Paired with") ~= nil
	end, 10000)
	eq("paired once the button was pressed", "Paired with " .. label(box) .. " at " .. CFG.address,
		said(c4, m, "^Paired with") or fake.last_action(denv))
	if not paired then
		return
	end
	check("the token is stored", type(c4.persist.syncbox_token) == "string" and c4.persist.syncbox_token ~= "")
	token_kept(denv, c4, "after pairing")

	-- The rows (S2 §5), against the Lua spec's texts for the same fixture.
	c4.advance(1000)
	starts("Status", "Video, high, brightness 100 % on Living Room TV", P(denv, "Status"))
	eq("Online", "Online", P(denv, "Online"))
	eq("Sync Box", "Living Room Sync Box", P(denv, "Sync Box"))
	eq("Model", "Hue Play HDMI Sync Box 8K (HSB2)", P(denv, "Model"))
	eq("Firmware", "2.5.4 (API level 14)", P(denv, "Firmware"))
	eq("Box ID", box.id, P(denv, "Box ID"))
	eq("Box Address", CFG.address, P(denv, "Box Address"))
	eq("Inputs", "1 Apple TV (on), 2 PlayStation, 3 HDMI 3, 4 HDMI 4", P(denv, "Inputs"))
	eq("Bridge Link", "Hue Bridge 001788fffe123abc, streaming", P(denv, "Bridge Link"))
	check("Input Switching names the box's own HDMI CEC switching and auto-sync (stage 4: offers.lua's row)",
		tostring(P(denv, "Input Switching")):find("HDMI CEC switching on HDMI 1, 2", 1, true) ~= nil,
		P(denv, "Input Switching"))
	-- Stage 4 (#568): in line Control4 routes through the box, which switches
	-- inputs by itself (on Attention, design 5.4), and the new device is still
	-- named "Hue Sync Box" while the box is "Living Room Sync Box" (the names
	-- wait for a click, 1.2's D11).
	starts("Input Switching on Attention while Control4 routes through a box that switches by itself",
		"Attention: The box switches inputs by itself", P(denv, "Input Switching"))
	check("Status ends with the Attention notes: the input switching and the names",
		tostring(P(denv, "Status")):find("; Attention: the box switches inputs by itself", 1, true) ~= nil
		and tostring(P(denv, "Status")):find("have different names", 1, true) ~= nil, P(denv, "Status"))
	rows_follow(denv, box, "rows", c4)

	-- Polling: a read every 5 s while the box is on.
	n = #T.history
	c4.advance(30000)
	local reads = sent(T, n, "GET", "/api/v1")
	check("polling: about one read every 5 s (6 in 30 s)", #reads >= 5 and #reads <= 7, #reads .. " reads")
	local good = true
	for _, h in ipairs(reads) do
		good = good and h.status == 200
	end
	check("every read answered HTTP 200", good)

	-- The box changed in the house, the rows following.
	-- Each event, and whether a row must show it (a signal on an input that
	-- is not the active one shows in no row of stage 2).
	local events = {
		{ "rename", { name = "Den Sync Box" }, "renamed in the Hue Sync app", true },
		{ "cec_active_source", { input = 2 }, "a source's CEC Active Source on input 2", true },
		{ "signal", { input = 3, status = "linked" }, "a signal on input 3", false },
		{ "bridge", { state = "busy" }, "the bridge busy (another app streams)", true },
		{ "bridge", { state = "streaming" }, "the bridge streaming again", true },
		{ "tv_standby", {}, "the TV's CEC standby", true },
	}
	for _, e in ipairs(events) do
		local before = P(denv, "Sync") .. "|" .. P(denv, "Inputs") .. "|" .. P(denv, "Sync Box") .. "|"
			.. P(denv, "Bridge Link")
		local ok, err = pcall(fb.event, box, e[1], e[2])
		if check(e[3] .. ": the fake takes the event", ok, err) then
			c4.advance(31000) -- one read at most 30 s on (power save) after the event
			local after = P(denv, "Sync") .. "|" .. P(denv, "Inputs") .. "|" .. P(denv, "Sync Box") .. "|"
				.. P(denv, "Bridge Link")
			if e[4] then
				check(e[3] .. ": a row changed", before ~= after, after)
			end
			rows_follow(denv, box, e[3], c4)
		end
	end
	local ok, err = pcall(fb.event, box, "hotplug", { input = 1 })
	if check("a source powering on (hot-plug on input 1): the fake takes the event", ok, err) then
		c4.advance(31000)
		rows_follow(denv, box, "hot-plug on input 1", c4)
	end

	-- A Director restart: the pairing kept, the identity checked, the reads go on.
	n = #T.history
	denv, c4 = restart(T, denv, c4)
	local back = until_(c4, function()
		return P(denv, "Online") == "Online" and P(denv, "Sync") ~= ""
	end, 20000)
	check("after a restart the box is read again without pairing", back, P(denv, "Status"))
	local first = T:since(n)[1]
	eq("the first request after the restart is unkeyed (the identity check)", "/api/v1/device",
		first and first.path)
	rows_follow(denv, box, "after the restart", c4)

	-- Silence: offline after 5 minutes without an answer, not before.
	fb.fault(box, "silence")
	n = #T.history
	c4.advance(4 * MINUTE + 50000)
	eq("silent for 4:50: still Online", "Online", P(denv, "Online"))
	local timeouts = true
	for _, h in ipairs(sent(T, n, "GET", "/api/v1")) do
		timeouts = timeouts and h.status == nil and h.err_code ~= nil
	end
	check("every read during the silence got no answer", timeouts)
	local offline = until_(c4, function()
		return tostring(P(denv, "Online")):find("^Offline since") ~= nil
	end, 3 * MINUTE, 5000)
	check("offline within 8 minutes of silence (the 5-minute rule; reads every 60 s by then)", offline,
		P(denv, "Online"))
	starts("Status says offline", "Offline since", P(denv, "Status"))

	-- Back online.
	fb.clear(box, "silence")
	local online = until_(c4, function()
		return P(denv, "Online") == "Online"
	end, 2 * MINUTE, 5000)
	check("back online once the box answers again", online, P(denv, "Online"))
	rows_follow(denv, box, "back online", c4)

	-- Until a read after the n-th transfer is answered again: the fake
	-- clock 5 s on and a quarter of a real second, in turn, for at most the
	-- fake's restart and 10 s more of real time (well under the driver's 5
	-- minutes of its own clock).
	local function answered_again(since)
		local rounds = math.ceil((RESTART_S + 10) / 0.25)
		for _ = 1, rounds do
			local got = sent(T, since, "GET", "/api/v1")
			if #got > 0 and got[#got].status == 200 then
				return true
			end
			c4.advance(5000)
			real_sleep(0.25)
		end
		return false
	end
	-- Whether a read after the n-th transfer got no answer, within 40 s of
	-- the fake clock (a read every 5 s, or 30 s in power save, delivered up
	-- to its 6 s timeout after it starts).
	local function missed_one(since)
		return until_(c4, function()
			for _, h in ipairs(sent(T, since, "GET", "/api/v1")) do
				if h.status == nil then
					return true
				end
			end
			return false
		end, 40000)
	end

	-- The box reboots: nothing answers while it restarts (30 s of its clock),
	-- then it reads on; no outage.
	ok, err = pcall(fb.event, box, "reboot")
	if check("a reboot of the box: the fake takes the event", ok, err) then
		n = #T.history
		check("during the reboot a read gets no answer", missed_one(n))
		check("after the reboot the reads are answered again", answered_again(n))
		eq("a reboot is no outage", "Online", P(denv, "Online"))
		rows_follow(denv, box, "after the reboot", c4)
	end

	-- A firmware update: a restart, then the new version in the rows.
	ok, err = pcall(fb.event, box, "firmware", { version = "2.6.0" })
	if check("a firmware update: the fake takes the event", ok, err) then
		n = #T.history
		missed_one(n)
		check("after the update the reads are answered again", answered_again(n))
		starts("the Firmware row shows the new version", "2.6.0", P(denv, "Firmware"))
		rows_follow(denv, box, "after the firmware update", c4)
	end

	-- A certificate from another CA at the address: TLS refuses it, so
	-- nothing, the token included, reaches the HTTP layer there.
	ok, err = pcall(fb.fault, box, "wrong_cert")
	if check("a certificate from another CA: the fake takes the fault", ok, err) then
		n = #T.history
		local _, logged = fb.http_after(box, 0)
		-- At least two reads (one every 5 s, or 30 s in power save).
		until_(c4, function()
			return #sent(T, n) >= 2
		end, 2 * MINUTE)
		local all = sent(T, n)
		local refused = #all > 0
		local reached = 0
		for _, h in ipairs(all) do
			refused = refused and h.err_code == 60
			reached = reached + (h.status and 1 or 0)
		end
		check("every request refused by TLS (curl 60)", refused, #all .. " requests")
		eq("no HTTP answer came from it", 0, reached)
		eq("the fake logged no HTTP request meanwhile (the token never reached it)", 0, #fb.http_after(box, logged))
		fb.clear(box, "wrong_cert")
		check("the right certificate back: the reads are answered again", answered_again(n))
	end

	-- Another box behind the address at a restart (EC B12): the identity
	-- check finds the other id, and no keyed request goes there.
	ok, err = pcall(fb.fault, box, "other_id")
	if check("another box behind the address: the fake takes the fault", ok, err) then
		n = #T.history
		denv, c4 = restart(T, denv, c4)
		local found = until_(c4, function()
			return tostring(P(denv, "Status")):find("^Another device answers") ~= nil
		end, MINUTE)
		check("after a restart the identity check finds another box there", found, P(denv, "Status"))
		c4.advance(5 * MINUTE)
		eq("no keyed request went to it", 0, #sent(T, n, "GET", "/api/v1"))
		fb.clear(box, "other_id")
		local again = until_(c4, function()
			local d = expected_rows(box)
			return d ~= nil and status_is(P(denv, "Status"), d)
		end, HOUR + 2 * MINUTE, MINUTE)
		check("the paired box back: read again within the hour", again, P(denv, "Status"))
	end

	-- A wrong box at the address: another id answers there.
	if CFG.other then
		T:route(CFG.address, CFG.other.target)
		local other = until_(c4, function()
			return tostring(P(denv, "Status")):find("^Another device answers") ~= nil
		end, 2 * MINUTE)
		eq("a wrong box at the address", "Another device answers at " .. CFG.address .. " (expected " .. short(box.id)
			.. "); Pair Sync Box to find it", P(denv, "Status"))
		if other then
			n = #T.history
			c4.advance(10 * MINUTE)
			eq("no keyed read goes to the wrong box", 0, #sent(T, n, "GET", "/api/v1"))
		end
		T:route(CFG.address, box.target)
		local again = until_(c4, function()
			local d = expected_rows(box)
			return d ~= nil and status_is(P(denv, "Status"), d)
		end, HOUR + 2 * MINUTE, MINUTE)
		check("the right box back at the address: read again within the hour", again, P(denv, "Status"))
	else
		skip("a wrong box at the address", "E2E_OTHER not set")
	end

	-- The registration deleted in the Hue Sync app: the box answers 401.
	local reg = c4.persist.syncbox_registration_id
	ok, err = pcall(fb.event, box, "app_deletes", { registration = reg })
	if check("the app deletes the registration: the fake takes the event", ok, err) then
		local refused = until_(c4, function()
			return tostring(P(denv, "Status")):find("refuses this pairing") ~= nil
		end, MINUTE)
		check("a 401 after app_deletes: Status says the box refuses the pairing", refused, P(denv, "Status"))
		eq("Last Action says so", label(box) .. " at " .. CFG.address .. " refuses this pairing (HTTP 401): hold its "
			.. "button for 3 seconds, then run Pair Sync Box", fake.last_action(denv))
		local reads401 = sent(T, 0, "GET", "/api/v1")
		eq("the read that was refused got HTTP 401", 401, reads401[#reads401] and reads401[#reads401].status)
		check("the token is kept (EC B5)", c4.persist.syncbox_token ~= nil)
	end

	-- Pairing again, then Forget Pairing.
	if pair(denv, c4, box, CFG.address, T, "pairing again") then
		c4.advance(6000)
		eq("paired again: Online", "Online", P(denv, "Online"))
		token_kept(denv, c4, "after pairing again")
		reg = c4.persist.syncbox_registration_id
		action(denv, "Forget Pairing", { Confirm = "Yes" })
		local forgot = until_(c4, function()
			return fake.last_action(denv):find("^Forgot") ~= nil
		end, 30000)
		eq("Forget Pairing removes the registration on the box", "Forgot the pairing with " .. label(box)
			.. ": its registration on the box is removed", fake.last_action(denv))
		if forgot then
			local deletes = sent(T, 0, "DELETE", "/api/v1/registrations/" .. tostring(reg))
			eq("its DELETE was answered HTTP 200", 200, deletes[#deletes] and deletes[#deletes].status)
			local regs = fb.state(box).registrations or {}
			check("the fake no longer lists the registration", regs[tostring(reg)] == nil)
			check("the token is gone from the store", c4.persist.syncbox_token == nil)
			eq("Box ID cleared", "", P(denv, "Box ID"))
			eq("Box Address kept", CFG.address, P(denv, "Box Address"))
			starts("Status", "Not paired", P(denv, "Status"))
			n = #T.history
			c4.advance(5 * MINUTE)
			eq("nothing keyed goes out after Forget Pairing", 0, #sent(T, n, "GET", "/api/v1"))
		end
	end
	T:close()
end)

-- The server's faults of docs/fakebox-design.md §2, each for one request,
-- against a paired driver: what the transport delivers (curl's code, the
-- status) and that the driver reads on afterwards without an outage.
suite("faults", function()
	local box = CFG.main
	local T = new_transport()
	local denv, c4 = start_driver(T)
	if not pair(denv, c4, box, CFG.address, T, "pair") then
		return T:close()
	end
	c4.advance(6000)
	local cases = {
		-- kind, params, what the faulted read must show, its check's words
		{ "5xx", {}, function(h) return h.status == 500 end, "answered HTTP 500" },
		{ "drop", {}, function(h) return h.status == nil and h.err_code == 52 end, "no answer (curl 52)" },
		{ "truncated", {}, function(h) return h.err_code == 18 end, "a body cut short (curl 18)" },
		{ "oversized", {}, function(h) return h.status == 200 end, "a body over 256 KB, refused by the driver" },
		{ "redirect", {}, function(h) return h.status == 302 and h.aborted == true and not h.redirects end,
			"a redirect, refused by the keyed request (aborted, not followed)" },
		{ "latency", { ms = 400 }, function(h) return h.status == 200 end, "answered 400 ms late" },
		{ "refuse", {}, function(h) return h.status == nil and h.err_code == 7 end, "the port closed (curl 7)" },
	}
	for _, case in ipairs(cases) do
		local kind = case[1]
		local n = #T.history
		local ok, err = pcall(fb.run, box, "fault", q(kind) .. " --count 1 --method GET"
			.. (case[2].ms and (" ms=" .. case[2].ms) or ""))
		if check(kind .. ": the fake takes the fault", ok, err) then
			if kind == "refuse" then
				real_sleep(0.3) -- the server closes its port within 50 ms of the fault
			end
			-- A read every 30 s in power save (the flows leave the box
			-- there), delivered up to its 6 s timeout after it starts.
			local hit = until_(c4, function()
				return #sent(T, n, "GET", "/api/v1") > 0
			end, 40000)
			local first = sent(T, n, "GET", "/api/v1")[1]
			local seen = {}
			for _, h in ipairs(T:since(n)) do
				seen[#seen + 1] = string.format("%s %s %s/%s%s", h.method, tostring(h.path), tostring(h.status),
					tostring(h.err_code), h.settled and "" or " (not delivered)")
			end
			check(kind .. ": the next read is " .. case[4], hit and case[3](first),
				first and string.format("status %s, curl %s, aborted %s", tostring(first.status),
					tostring(first.err_code), tostring(first.aborted))
					or ("no read delivered; the transfers since the fault: " .. table.concat(seen, ", ")))
			-- refuse lasts until cleared, whatever the count; the port opens
			-- again within 50 ms.
			pcall(fb.clear, box, kind)
			if kind == "refuse" then
				real_sleep(0.3)
			end
			local again = until_(c4, function()
				local got = sent(T, n, "GET", "/api/v1")
				return #got > 1 and got[#got].status == 200
			end, 2 * MINUTE)
			check(kind .. ": the reads go on", again)
			eq(kind .. ": no outage", "Online", P(denv, "Online"))
		end
	end
	rows_follow(denv, box, "after the faults", c4)
	token_kept(denv, c4, "after the faults")
	action(denv, "Forget Pairing", { Confirm = "Yes" })
	until_(c4, function()
		return fake.last_action(denv):find("^Forgot") ~= nil
	end, 30000)
	starts("forgotten", "Forgot the pairing with", fake.last_action(denv))
	T:close()
end)

-- A development build (syncbox/devhooks.lua, F6) takes "host:port" under
-- Address: the fake on its own port, no route.
suite("devhooks", function()
	local hooks_ok = pcall(require, "syncbox.devhooks")
	if not hooks_ok then
		return skip("Pair Sync Box at host:port", "src/hue_syncbox/syncbox/devhooks.lua is not there")
	end
	local box = CFG.main
	local function forget(denv, c4, what)
		action(denv, "Forget Pairing", { Confirm = "Yes" })
		until_(c4, function()
			return fake.last_action(denv):find("^Forgot") ~= nil
		end, 30000)
		starts(what .. ": forgotten", "Forgot the pairing with " .. label(box) .. ": its registration on the box is "
			.. "removed", fake.last_action(denv))
	end

	-- Typed: the fake's own address and port, no route.
	local T = new_transport({ route = false })
	local denv, c4 = start_driver(T)
	local address = "127.0.0.1:" .. box.port
	local paired_text = pair(denv, c4, box, address, T, "host:port")
	if paired_text then
		eq("paired at host:port", "Paired with " .. label(box) .. " at " .. address, paired_text)
		c4.advance(6000)
		eq("Box Address shows the port", address, P(denv, "Box Address"))
		rows_follow(denv, box, "at host:port", c4)
		forget(denv, c4, "host:port")
	elseif fake.last_action(denv):find("not an IPv4 address", 1, true) then
		skip("Pair Sync Box at host:port", "the driver does not call syncbox/devhooks.lua yet")
	end
	T:close()

	-- Found: the mDNS answer announces the fake's port, the search lists
	-- the box at address:port and Pair Sync Box takes it from the list.
	T = new_transport()
	local lan, answered = lan_for(box, box.port)
	denv, c4 = start_driver(T, { lan = lan })
	local found = until_(c4, function()
		return P(denv, "Status") == "Not paired: 1 Hue sync box found (run Pair Sync Box)"
	end, 30000)
	check("the search's queries got the fake's mDNS answer", answered() > 0)
	check("the search lists a box announcing another port", found, P(denv, "Status"))
	local srv = CFG.address .. ":" .. box.port
	local list = fake.custom_select(denv, "SyncBoxList")
	-- The list names the box as its GET /device does (the flows suite may
	-- have renamed it), not as the mDNS TXT does.
	eq("the Box list names it at address:port", label(box) .. ", " .. tostring(fb.state(box).device.name) .. ", "
		.. srv, list[1] and list[1].text)
	if found then
		local n = #T.history
		action(denv, "Pair Sync Box", { Box = "box:" .. box.id })
		until_(c4, function()
			return #sent(T, n, "POST", "/api/v1/registrations") > 0
		end, 20000)
		local m = #c4.calls
		fb.button(box)
		local paired = until_(c4, function()
			return said(c4, m, "^Paired with") ~= nil
		end, 10000)
		eq("paired from the list at address:port", "Paired with " .. label(box) .. " at " .. srv,
			said(c4, m, "^Paired with") or fake.last_action(denv))
		if paired then
			c4.advance(6000)
			eq("found at address:port: Online", "Online", P(denv, "Online"))
			forget(denv, c4, "address:port")
		end
	end
	T:close()
end)

-- Every other model: paired, its rows, a read, forgotten.
suite("models", function()
	if #CFG.models == 0 then
		return skip("other models", "E2E_MODELS not set")
	end
	for _, box in ipairs(CFG.models) do
		local T = new_transport({ box = box })
		local denv, c4 = start_driver(T)
		local what = box.model
		local paired_text = pair(denv, c4, box, CFG.address, T, what)
		if paired_text then
			eq(what .. ": paired", "Paired with " .. label(box) .. " at " .. CFG.address, paired_text)
			c4.advance(31000)
			eq(what .. ": Online", "Online", P(denv, "Online"))
			check(what .. ": the Model row names it", tostring(P(denv, "Model")):find("(" .. box.code .. ")", 1, true)
				~= nil, P(denv, "Model"))
			rows_follow(denv, box, what, c4)
			action(denv, "Forget Pairing", { Confirm = "Yes" })
			until_(c4, function()
				return fake.last_action(denv):find("^Forgot") ~= nil
			end, 30000)
			eq(what .. ": forgotten", "Forgot the pairing with " .. label(box) .. ": its registration on the box is removed",
				fake.last_action(denv))
		end
		T:close()
	end
end)

-- Routing (#557) --------------------------------------------------------------------------------
--
-- docs/hdmi-sync-stage3-design.md §3 to §6 and contracts C4: Director's
-- avswitch commands replayed into the box driver (ReceivedFromProxy on 5001,
-- in Control4's shapes: ON, SET_INPUT with INPUT, OUTPUT, AUDIO and VIDEO as
-- text, OFF, DISCONNECT_OUTPUT), the followed room's variables changed
-- through the fake runtime, each wiring against a box of its own in the
-- Python fake; after each step the box's state is read back from the fake's
-- control API. What Director sends in each wiring, and how a room's
-- variables read, are [assumed] until probes P8 to P11 (contract §7).

local AV = 5001
local ROOM = 7 -- the fake project's default room, where the box device sits
-- The room's variables (docs/syncbox-wirings-research.md §1.2).
local RV = { selected = 1000, audio = 1001, video = 1002, audio_path = 1007, video_path = 1008,
	video_audio_path = 1009, power = 1010 }
-- The fields a stage 3 PUT may carry (contract §1: execution only; the box
-- applies them in its own order whatever their order in the JSON, behaviour
-- SB55, which the encoder decides).
local PUT_FIELDS = { hdmiActive = true, hdmiSource = true, mode = true, syncActive = true, video = true, game = true,
	music = true, intensity = true, brightness = true }
local SYNC_MODES = { video = true, game = true, music = true }

-- Why one PUT's fields contradict each other (a power save with a wake or a
-- sync, a sync with a stop), else nil: the queue's latest-wins merge must
-- never send such a pair, which SB55's order would turn against the latest
-- intent (a Room Off after a route waking and syncing the box).
local function conflict(body)
	local power_off = body.hdmiActive == false or body.mode == "powersave"
	local wake = body.hdmiActive == true or body.syncActive == true or body.mode == "passthrough"
		or SYNC_MODES[body.mode] ~= nil
	local sync = body.syncActive == true or SYNC_MODES[body.mode] ~= nil
	local no_sync = body.syncActive == false or body.mode == "passthrough" or body.mode == "powersave"
	if power_off and wake then
		return "a power save with a wake"
	elseif sync and no_sync then
		return "a sync with a stop"
	end
	return nil
end

-- The project of the routing suites: a receiver, a video source, a console,
-- a tuner and the TV, each a protocol device and its proxy in the box's room
-- (fake.add_device; ids clear of the runtime's own 2301 and the proxies from
-- 3001). The file and proxy names stand for real drivers' [assumed]: the
-- console's driver file carries the "playstation" hint (research §2.1), the
-- tuner's proxy is a tuner.
local SRC = {
	receiver = { id = 401, proxy = 501, name = "AV Receiver", file = "generic_av_receiver.c4z", kind = "receiver" },
	appletv = { id = 402, proxy = 502, name = "Apple TV", file = "apple_tv_ip.c4z", kind = "media_player" },
	ps5 = { id = 403, proxy = 503, name = "PS5", file = "sony_playstation_5.c4z", kind = "dvd" },
	tuner = { id = 404, proxy = 504, name = "FM Tuner", file = "generic_tuner.c4z", kind = "tuner" },
	tv = { id = 405, proxy = 505, name = "TV", file = "generic_tv.c4z", kind = "tv" },
}
local SRC_ORDER = { "receiver", "appletv", "ps5", "tuner", "tv" }

local function box_proxy()
	local rec = fake.project.devices[BOX_DEVICE]
	return rec and rec.proxy_id
end

-- The sources (and, with `receiver_on`, the receiver's HDMI output bound to
-- the box's HDMI 1, video and audio: behind a receiver its main output, on a
-- second output its second, research §4.1 choice B).
local function routing_project(receiver_on)
	return function(c4)
		assert(type(fake.add_device) == "function", "fake.add_device is not in tests/helpers/fake_c4.lua (agent B)")
		for _, key in ipairs(SRC_ORDER) do
			local s = SRC[key]
			fake.add_device(s.id, { name = s.name, driver = s.file, proxy = s.kind, proxy_id = s.proxy, room_id = ROOM })
		end
		if receiver_on then
			for _, pair_ in ipairs({ { 1000, receiver_on }, { 3000, receiver_on + 2000 } }) do
				table.insert(c4.bindings, { provider = SRC.receiver.proxy, provider_binding = pair_[2],
					consumer = box_proxy(), consumer_binding = pair_[1], class = "HDMI" })
			end
		end
	end
end

-- A room's path variable: one <id> per device on the path [verified: the
-- common library reads 1007 that way, research §1.2; 1008 assumed alike].
local function path_of(ids)
	local parts = {}
	for _, id in ipairs(ids) do
		parts[#parts + 1] = "<id>" .. tostring(id) .. "</id>"
	end
	return #parts > 0 and ("<path>" .. table.concat(parts) .. "</path>") or ""
end

-- The room's variables for a selection, as research §2.2 expects them
-- [assumed: P8]. kind "watch" (a picture over `path`), "listen" (sound
-- only) or "off".
local function selection(kind, src, path)
	local id = src and tostring(src.proxy) or "0"
	if kind == "off" then
		return { { RV.selected, "0" }, { RV.video, "0" }, { RV.audio, "0" }, { RV.video_path, "" },
			{ RV.video_audio_path, "" }, { RV.audio_path, "" }, { RV.power, "0" } }
	elseif kind == "listen" then
		return { { RV.power, "1" }, { RV.selected, id }, { RV.audio, id }, { RV.video, "0" }, { RV.video_path, "" },
			{ RV.video_audio_path, "" }, { RV.audio_path, path_of(path) } }
	end
	return { { RV.power, "1" }, { RV.selected, id }, { RV.video, id }, { RV.audio, id },
		{ RV.video_path, path_of(path) }, { RV.video_audio_path, path_of(path) }, { RV.audio_path, "" } }
end

-- Set the followed room's variables, as Director changes them (agent B's
-- fake.room_variable calls the driver's OnWatchedVariableChanged).
local function room_set(vars)
	assert(type(fake.room_variable) == "function",
		"fake.room_variable is not in tests/helpers/fake_c4.lua (contract §4, agent B)")
	for _, v in ipairs(vars) do
		fake.room_variable(ROOM, v[1], v[2])
	end
end

local function director(denv, command, params)
	denv.ReceivedFromProxy(AV, command, params or {})
end

local function video_input(n)
	return { INPUT = tostring(999 + n), OUTPUT = "2000", AUDIO = "False", VIDEO = "True" }
end

local function audio_input(n)
	return { INPUT = tostring(2999 + n), OUTPUT = "4000", AUDIO = "True", VIDEO = "False" }
end

local DISCONNECT = { OUTPUT = "2000", AUDIO = "True", VIDEO = "True", CLASS = "HDMI" }

-- The notifies to the AV proxy after the m-th call of the runtime.
local function notifies(c4, m)
	local out = {}
	for i = (m or 0) + 1, #c4.calls do
		local call = c4.calls[i]
		if call.name == "SendToProxy" and tonumber(call.args[1]) == AV then
			out[#out + 1] = { command = call.args[2], params = call.args[3] or {} }
		end
	end
	return out
end

local function notified(c4, m, command, input)
	local n = 0
	for _, x in ipairs(notifies(c4, m)) do
		if x.command == command and (input == nil or tostring(x.params.INPUT) == tostring(input)) then
			n = n + 1
		end
	end
	return n
end

-- The top-level keys of a JSON object's text, in their order.
local function top_keys(text)
	local keys, depth, i = {}, 0, 1
	text = tostring(text or "")
	while i <= #text do
		local ch = text:sub(i, i)
		if ch == '"' then
			local j = i + 1
			while j <= #text and text:sub(j, j) ~= '"' do
				j = j + (text:sub(j, j) == "\\" and 2 or 1)
			end
			if depth == 1 and text:sub(j + 1):match("^%s*:") then
				keys[#keys + 1] = text:sub(i + 1, j - 1)
			end
			i = j + 1
		else
			if ch == "{" or ch == "[" then
				depth = depth + 1
			elseif ch == "}" or ch == "]" then
				depth = depth - 1
			end
			i = i + 1
		end
	end
	return keys
end

-- The settled PUTs after the n-th transfer, and every write of any kind.
local function writes(T, n)
	local puts, other = {}, {}
	for _, h in ipairs(sent(T, n)) do
		if h.method == "PUT" and h.path == "/api/v1/execution" then
			puts[#puts + 1] = h
		elseif h.method ~= "GET" then
			other[#other + 1] = h
		end
	end
	return puts, other
end

-- The fields of the PUTs after n, merged (latest wins); the number of PUTs
-- and their bodies; the first body with a field stage 3 does not write, and
-- the first with a contradicting pair (each with why), or nil.
local function put_fields(T, n)
	local merged, bodies, bad_field, bad_pair = {}, {}, nil, nil
	local puts = writes(T, n)
	for _, h in ipairs(puts) do
		local body = json.decode(h.data or "")
		bodies[#bodies + 1] = h.data
		if type(body) == "table" then
			for k, v in pairs(body) do
				merged[k] = v
			end
		end
		for _, k in ipairs(top_keys(h.data)) do
			if not PUT_FIELDS[k] then
				bad_field = bad_field or ("the field " .. k .. ": " .. tostring(h.data))
			end
		end
		if type(body) ~= "table" then
			bad_field = bad_field or ("not a JSON object: " .. tostring(h.data))
		else
			local why = conflict(body)
			bad_pair = bad_pair or (why and (why .. ": " .. tostring(h.data)))
		end
	end
	return merged, #puts, table.concat(bodies, " "), bad_field, bad_pair
end

local function lookup_path(doc, path)
	for part in tostring(path):gmatch("[^%.]+") do
		if type(doc) ~= "table" then
			return nil
		end
		doc = doc[part]
	end
	return doc
end

-- The box as the fake has it now: each { dotted path, value } of `want`.
local function box_is(what, box, want)
	local doc = fb.state(box)
	for _, w in ipairs(want) do
		eq(what .. ": the box's " .. w[1], w[2], lookup_path(doc, w[1]))
	end
	return doc
end

-- One step of a routing suite: act(), then the fake clock on until done()
-- holds (else max_ms), then a second more for the read that follows.
local function step(c4, act, done, max_ms)
	act()
	local ok = until_(c4, done or function() return false end, max_ms or 10000, 250)
	c4.advance(1000)
	return ok
end

local function set_property(denv, name, value)
	denv.Properties[name] = value
	denv.OnPropertyChanged(name)
end

local function hidden(c4, name)
	return c4.property_attribs[name] == 1
end

local ROUTE_MAX = 15000 -- a route, its read and the confirmation, on the fake clock

-- Pair a routing suite's box, its project and the wiring row checked.
local function routing_start(box, project, wiring_key, what)
	local T = new_transport({ box = box })
	local denv, c4 = start_driver(T, { project = project })
	if not pair(denv, c4, box, CFG.address, T, what) then
		T:close()
		return nil
	end
	c4.advance(6000)
	local texts = require("syncbox.state").WIRING_TEXTS
	eq(what .. ": the Wiring row", texts[wiring_key], P(denv, "Wiring"))
	return T, denv, c4
end

-- Nothing but PUT /execution written since n (contract §1: no behavior,
-- hue, device or hdmi write in stage 3), every PUT with stage 3's fields
-- only and none contradicting another.
local function only_execution(what, T, n)
	local _, _, _, bad_field, bad_pair = put_fields(T, n)
	local _, other = writes(T, n)
	local names = {}
	for _, h in ipairs(other) do
		names[#names + 1] = h.method .. " " .. tostring(h.path)
	end
	check(what .. ": no write but PUT /execution (stage 3 writes execution only)", #other == 0,
		table.concat(names, ", "))
	check(what .. ": every PUT carries only stage 3's fields (hdmiActive, hdmiSource, mode, syncActive, a mode's "
		.. "intensity, brightness)", bad_field == nil, bad_field)
	check(what .. ": no PUT pairs a power save with a wake, or a sync with a stop", bad_pair == nil, bad_pair)
end

-- In line (design 5.2, 5.3; contracts C4): Director routes through the box.
suite("routing-inline", function()
	local box = CFG.routing.inline
	if not box then
		return skip("routing in line", "E2E_ROUTING has no inline box")
	end
	local T, denv, c4 = routing_start(box, routing_project(nil), "in_line", "in line")
	if not T then
		return
	end
	local first = #T.history
	for n = 1, 4 do
		check("in line: HDMI " .. n .. " Sync Mode is shown", not hidden(c4, "HDMI " .. n .. " Sync Mode"))
	end
	check("in line: Follow Room is hidden", hidden(c4, "Follow Room"))
	check("in line: Source Sync Modes is hidden", hidden(c4, "Source Sync Modes"))
	check("in line: At Room Off is shown", not hidden(c4, "At Room Off"))
	check("in line: When The Source Leaves The Box is shown", not hidden(c4, "When The Source Leaves The Box"))

	-- Room Off: power save (At Room Off's default), OFF once the box reads it.
	local m, n = #c4.calls, #T.history
	step(c4, function() director(denv, "OFF") end, function() return notified(c4, m, "OFF") > 0 end, ROUTE_MAX)
	eq("Room Off: OFF to the proxy once the box is in power save", 1, notified(c4, m, "OFF"))
	box_is("Room Off", box, { { "execution.mode", "powersave" }, { "execution.hdmiActive", false } })
	local fields = put_fields(T, n)
	eq("Room Off: the PUT asks for power save", "powersave", fields.mode)

	-- Watch the PlayStation on HDMI 2: ON, then SET_INPUT for its picture and
	-- for its sound (one source, two paths: research §1.4); one wake, one
	-- switch, a game sync (Automatic: the input's type), each path confirmed.
	m, n = #c4.calls, #T.history
	step(c4, function()
		director(denv, "ON")
		director(denv, "SET_INPUT", video_input(2))
		director(denv, "SET_INPUT", audio_input(2))
	end, function()
		return notified(c4, m, "INPUT_OUTPUT_CHANGED", 1001) > 0 and notified(c4, m, "INPUT_OUTPUT_CHANGED", 3001) > 0
	end, ROUTE_MAX)
	box_is("Watch HDMI 2", box, { { "execution.hdmiActive", true }, { "execution.hdmiSource", "input2" },
		{ "execution.mode", "game" }, { "execution.syncActive", true } })
	eq("Watch HDMI 2: ON to the proxy once the box is awake", 1, notified(c4, m, "ON"))
	eq("Watch HDMI 2: INPUT_OUTPUT_CHANGED for the picture's path, once", 1,
		notified(c4, m, "INPUT_OUTPUT_CHANGED", 1001))
	eq("Watch HDMI 2: INPUT_OUTPUT_CHANGED for the sound's path, once", 1,
		notified(c4, m, "INPUT_OUTPUT_CHANGED", 3001))
	local ioc
	for _, x in ipairs(notifies(c4, m)) do
		if x.command == "INPUT_OUTPUT_CHANGED" and tostring(x.params.INPUT) == "1001" then
			ioc = x.params
		end
	end
	check("Watch HDMI 2: the notify carries INPUT, OUTPUT, AUDIO and VIDEO as sent", ioc ~= nil
		and tostring(ioc.OUTPUT) == "2000" and tostring(ioc.VIDEO):lower() == "true"
		and tostring(ioc.AUDIO):lower() == "false", ioc and json.encode(ioc))
	local merged, count, bodies = put_fields(T, n)
	fields = merged
	check("Watch HDMI 2: wake, input and sync in at most two PUTs (ON's wake may go first)", count >= 1
		and count <= 2, count .. " PUTs: " .. bodies)
	check("Watch HDMI 2: the PUTs wake the box, name input2 and start a game sync", fields.hdmiActive == true
		and fields.hdmiSource == "input2" and fields.syncActive == true and (fields.mode == "game"
		or fields.mode == nil), bodies)

	-- Another source while syncing: the Apple TV on HDMI 1, no OFF between.
	m = #c4.calls
	step(c4, function()
		director(denv, "SET_INPUT", video_input(1))
	end, function() return notified(c4, m, "INPUT_OUTPUT_CHANGED", 1000) > 0 end, ROUTE_MAX)
	box_is("Watch HDMI 1", box, { { "execution.hdmiSource", "input1" }, { "execution.mode", "video" } })
	eq("Watch HDMI 1: INPUT_OUTPUT_CHANGED once", 1, notified(c4, m, "INPUT_OUTPUT_CHANGED", 1000))
	eq("Watch HDMI 1: no ON again (the box was on)", 0, notified(c4, m, "ON"))

	-- Listen on HDMI 2: an audio-only route is Music, though the input's type
	-- is a console (contracts C1.4: HDMI n Sync Mode Automatic).
	m = #c4.calls
	step(c4, function()
		director(denv, "SET_INPUT", audio_input(2))
	end, function() return notified(c4, m, "INPUT_OUTPUT_CHANGED", 3001) > 0 end, ROUTE_MAX)
	box_is("Listen on HDMI 2", box, { { "execution.hdmiSource", "input2" }, { "execution.mode", "music" } })

	-- HDMI 3 Sync Mode set by the dealer wins over the input's type.
	set_property(denv, "HDMI 3 Sync Mode", "Game")
	m = #c4.calls
	step(c4, function()
		director(denv, "SET_INPUT", video_input(3))
	end, function() return notified(c4, m, "INPUT_OUTPUT_CHANGED", 1002) > 0 end, ROUTE_MAX)
	box_is("HDMI 3 Sync Mode Game", box, { { "execution.hdmiSource", "input3" }, { "execution.mode", "game" } })
	set_property(denv, "HDMI 3 Sync Mode", "Automatic")

	-- Do not sync on HDMI 1, routed while the box syncs on HDMI 3: the input
	-- changes and the box stops syncing (a box keeps syncing over an input
	-- change it is only told the input of, behaviour SB39).
	set_property(denv, "HDMI 1 Sync Mode", "Do not sync")
	m, n = #c4.calls, #T.history
	step(c4, function()
		director(denv, "SET_INPUT", video_input(1))
	end, function() return notified(c4, m, "INPUT_OUTPUT_CHANGED", 1000) > 0 end, ROUTE_MAX)
	fields = put_fields(T, n)
	bodies = select(3, put_fields(T, n))
	box_is("Do not sync on HDMI 1", box, { { "execution.hdmiSource", "input1" },
		{ "execution.syncActive", false }, { "execution.mode", "passthrough" } })
	check("Do not sync on HDMI 1: no PUT asks for a sync", fields.syncActive ~= true and fields.mode ~= "video"
		and fields.mode ~= "game" and fields.mode ~= "music", bodies)
	set_property(denv, "HDMI 1 Sync Mode", "Automatic")

	-- The source leaves the box with the room on (DISCONNECT_OUTPUT without
	-- OFF): When The Source Leaves The Box's default, passthrough.
	m = #c4.calls
	step(c4, function()
		director(denv, "SET_INPUT", video_input(1))
	end, function() return notified(c4, m, "INPUT_OUTPUT_CHANGED", 1000) > 0 end, ROUTE_MAX)
	box_is("Watch HDMI 1 again", box, { { "execution.mode", "video" } })
	n = #T.history
	step(c4, function() director(denv, "DISCONNECT_OUTPUT", DISCONNECT) end, function()
		return #writes(T, n) > 0
	end, ROUTE_MAX)
	c4.advance(3000)
	box_is("DISCONNECT_OUTPUT", box, { { "execution.mode", "passthrough" }, { "execution.hdmiActive", true } })

	-- At Room Off "Stop syncing and keep the picture".
	set_property(denv, "At Room Off", "Stop syncing and keep the picture")
	m = #c4.calls
	step(c4, function()
		director(denv, "SET_INPUT", video_input(1))
	end, function() return notified(c4, m, "INPUT_OUTPUT_CHANGED", 1000) > 0 end, ROUTE_MAX)
	m = #c4.calls
	step(c4, function() director(denv, "OFF") end, function() return notified(c4, m, "OFF") > 0 end, ROUTE_MAX)
	box_is("At Room Off: keep the picture", box, { { "execution.mode", "passthrough" },
		{ "execution.hdmiActive", true } })
	eq("At Room Off: keep the picture: OFF to the proxy", 1, notified(c4, m, "OFF"))
	set_property(denv, "At Room Off", "Power save")

	-- A change the box makes by itself (a source's CEC Active Source on HDMI
	-- 2) shows in the rows and never as a notify that would move the room.
	m = #c4.calls
	local ok, err = pcall(fb.event, box, "cec_active_source", { input = 2 })
	if check("the box switches by itself: the fake takes the event", ok, err) then
		c4.advance(12000)
		box_is("the box switched by itself", box, { { "execution.hdmiSource", "input2" } })
		eq("the box switched by itself: no INPUT_OUTPUT_CHANGED", 0, notified(c4, m, "INPUT_OUTPUT_CHANGED"))
		check("the box switched by itself: the Inputs row shows it", tostring(P(denv, "Inputs")):find("2 [^,]*%(on%)")
			~= nil, P(denv, "Inputs"))
	end

	-- Room Off again: power save.
	m = #c4.calls
	step(c4, function() director(denv, "OFF") end, function() return notified(c4, m, "OFF") > 0 end, ROUTE_MAX)
	box_is("Room Off at the end", box, { { "execution.mode", "powersave" } })
	only_execution("in line", T, first)
	token_kept(denv, c4, "in line")
	T:close()
end)

-- A one-input box in line (contracts C4: an input it lacks is refused).
suite("routing-onein", function()
	local box = CFG.routing.onein
	if not box then
		return skip("routing on a one-input box", "E2E_ROUTING has no onein box")
	end
	local T, denv, c4 = routing_start(box, routing_project(nil), "in_line", "one input")
	if not T then
		return
	end
	check("one input: HDMI 1 Sync Mode is shown", not hidden(c4, "HDMI 1 Sync Mode"))
	for n = 2, 4 do
		check("one input: HDMI " .. n .. " Sync Mode is hidden", hidden(c4, "HDMI " .. n .. " Sync Mode"))
	end
	local m, n = #c4.calls, #T.history
	step(c4, function()
		director(denv, "ON")
		director(denv, "SET_INPUT", video_input(2))
	end, function() return fake.last_action(denv):find("^Not switched") ~= nil end, ROUTE_MAX)
	eq("HDMI 2 on a one-input box: refused", "Not switched: this box has 1 HDMI input", fake.last_action(denv))
	local fields = put_fields(T, n)
	check("HDMI 2 on a one-input box: no PUT names input2", fields.hdmiSource ~= "input2")
	eq("HDMI 2 on a one-input box: no INPUT_OUTPUT_CHANGED", 0, notified(c4, m, "INPUT_OUTPUT_CHANGED"))
	m = #c4.calls
	step(c4, function()
		director(denv, "SET_INPUT", video_input(1))
	end, function() return notified(c4, m, "INPUT_OUTPUT_CHANGED", 1000) > 0 end, ROUTE_MAX)
	box_is("HDMI 1 on a one-input box", box, { { "execution.hdmiActive", true }, { "execution.hdmiSource", "input1" },
		{ "execution.mode", "game" } })
	m = #c4.calls
	step(c4, function() director(denv, "OFF") end, function() return notified(c4, m, "OFF") > 0 end, ROUTE_MAX)
	box_is("Room Off on a one-input box", box, { { "execution.mode", "powersave" } })
	T:close()
end)

-- Behind a receiver (design 5.8): Director routes through the box, always
-- HDMI 1; the sync mode comes from the followed room's source.
suite("routing-receiver", function()
	local box = CFG.routing.receiver
	if not box then
		return skip("routing behind a receiver", "E2E_ROUTING has no receiver box")
	end
	local T, denv, c4 = routing_start(box, routing_project(2000), "behind_receiver", "behind a receiver")
	if not T then
		return
	end
	local first = #T.history
	for n = 1, 4 do
		check("behind a receiver: HDMI " .. n .. " Sync Mode is hidden", hidden(c4, "HDMI " .. n .. " Sync Mode"))
	end
	check("behind a receiver: Follow Room is shown", not hidden(c4, "Follow Room"))
	check("behind a receiver: Source Sync Modes is shown", not hidden(c4, "Source Sync Modes"))
	local through = { SRC.receiver.proxy, box_proxy(), SRC.tv.proxy }

	local m = #c4.calls
	step(c4, function()
		room_set(selection("off"))
		director(denv, "OFF")
	end, function() return notified(c4, m, "OFF") > 0 end, ROUTE_MAX)
	box_is("behind a receiver: Room Off", box, { { "execution.mode", "powersave" } })

	-- Watch the Apple TV: the room names it, Director routes HDMI 1.
	m = #c4.calls
	step(c4, function()
		room_set(selection("watch", SRC.appletv, { SRC.appletv.proxy, through[1], through[2], through[3] }))
		director(denv, "ON")
		director(denv, "SET_INPUT", video_input(1))
	end, function() return notified(c4, m, "INPUT_OUTPUT_CHANGED", 1000) > 0 end, ROUTE_MAX)
	box_is("behind a receiver: Watch the Apple TV", box, { { "execution.hdmiActive", true },
		{ "execution.hdmiSource", "input1" }, { "execution.mode", "video" } })
	eq("behind a receiver: Watch the Apple TV: INPUT_OUTPUT_CHANGED once", 1,
		notified(c4, m, "INPUT_OUTPUT_CHANGED", 1000))

	-- Watch the PS5: the box's input stays HDMI 1, so Director may send it
	-- nothing [assumed: P10]; the room's variables alone change the mode.
	m = #c4.calls
	step(c4, function()
		room_set(selection("watch", SRC.ps5, { SRC.ps5.proxy, through[1], through[2], through[3] }))
	end, nil, 6000)
	box_is("behind a receiver: Watch the PS5 (room only)", box, { { "execution.hdmiSource", "input1" },
		{ "execution.mode", "game" } })
	check("behind a receiver: Source Sync Modes shows the PS5 as a guess", tostring(P(denv, "Source Sync Modes"))
		:find("PS5: Game (guessed from its driver)", 1, true) ~= nil, P(denv, "Source Sync Modes"))
	eq("behind a receiver: Watch the PS5: no notify", 0, #notifies(c4, m))

	-- The same with Director sending HDMI 1 again.
	m = #c4.calls
	step(c4, function()
		director(denv, "SET_INPUT", video_input(1))
	end, function() return notified(c4, m, "INPUT_OUTPUT_CHANGED", 1000) > 0 end, ROUTE_MAX)
	box_is("behind a receiver: HDMI 1 again for the PS5", box, { { "execution.mode", "game" } })

	-- Set Source Sync Mode: the Apple TV syncs to music from now on; the
	-- Source as the driver's own list (SourceList) offers it.
	local source_value
	for _, item in ipairs(type(denv.SourceList) == "function" and denv.SourceList() or {}) do
		if tostring(item.text):find("^Apple TV") then
			source_value = item.value
		end
	end
	check("Set Source Sync Mode: the Source list offers the Apple TV", source_value ~= nil,
		json.encode(type(denv.SourceList) == "function" and denv.SourceList() or {}))
	action(denv, "Set Source Sync Mode", { Source = source_value or "", Mode = "Music" })
	c4.advance(1000)
	check("Set Source Sync Mode: Source Sync Modes shows the Apple TV's", tostring(P(denv, "Source Sync Modes"))
		:find("Apple TV: Music", 1, true) ~= nil, P(denv, "Source Sync Modes") .. " / " .. fake.last_action(denv))
	step(c4, function()
		room_set(selection("watch", SRC.appletv, { SRC.appletv.proxy, through[1], through[2], through[3] }))
	end, nil, 6000)
	box_is("behind a receiver: the Apple TV set to Music", box, { { "execution.mode", "music" } })

	-- Listen to the tuner: Director takes the box off the picture's path;
	-- music sync anyway (#536, the provisional answer).
	step(c4, function()
		room_set(selection("listen", SRC.tuner, { SRC.tuner.proxy, through[1] }))
		director(denv, "DISCONNECT_OUTPUT", DISCONNECT)
	end, nil, 6000)
	box_is("behind a receiver: Listen to the tuner", box, { { "execution.hdmiActive", true },
		{ "execution.mode", "music" } })

	-- A source that does not pass the box (the TV's own app).
	step(c4, function()
		room_set(selection("watch", SRC.tv, { SRC.tv.proxy }))
		director(denv, "DISCONNECT_OUTPUT", DISCONNECT)
	end, nil, 6000)
	box_is("behind a receiver: the TV's own app", box, { { "execution.mode", "passthrough" },
		{ "execution.hdmiActive", true } })

	-- Room Off.
	m = #c4.calls
	step(c4, function()
		room_set(selection("off"))
		director(denv, "OFF")
	end, function() return notified(c4, m, "OFF") > 0 end, ROUTE_MAX)
	box_is("behind a receiver: Room Off at the end", box, { { "execution.mode", "powersave" } })
	only_execution("behind a receiver", T, first)
	T:close()
end)

-- From a receiver's second output (design 5.8; research §4.2): Director
-- never routes through the box; Follow Room (this device's room by default)
-- drives wake, sync, mode and power save.
suite("routing-second", function()
	local box = CFG.routing.second
	if not box then
		return skip("routing on a second output", "E2E_ROUTING has no second box")
	end
	local project = routing_project(2001)
	local via = { SRC.receiver.proxy, SRC.tv.proxy }
	local function watch(src)
		return selection("watch", src, { src.proxy, via[1], via[2] })
	end
	-- The room watches the Apple TV at the start, as the box (its fixture)
	-- syncs video: the baseline.
	local T, denv, c4 = routing_start(box, function(c4)
		project(c4)
		room_set(watch(SRC.appletv))
	end, "second_output", "second output")
	if not T then
		return
	end
	local first = #T.history
	for n = 1, 4 do
		check("second output: HDMI " .. n .. " Sync Mode is hidden", hidden(c4, "HDMI " .. n .. " Sync Mode"))
	end
	check("second output: Follow Room is shown", not hidden(c4, "Follow Room"))
	check("second output: Source Sync Modes is shown", not hidden(c4, "Source Sync Modes"))
	starts("second output: Follow Room follows this device's room", "This device's room", P(denv, "Follow Room"))

	-- Director's commands are only logged on a second output.
	local m, n = #c4.calls, #T.history
	step(c4, function()
		director(denv, "ON")
		director(denv, "SET_INPUT", video_input(2))
	end, nil, 5000)
	eq("second output: Director's commands write nothing", 0, #writes(T, n))
	eq("second output: Director's commands are not confirmed", 0, notified(c4, m, "INPUT_OUTPUT_CHANGED"))

	local function room_step(what, vars, want)
		local before = #T.history
		step(c4, function() room_set(vars) end, function() return #writes(T, before) > 0 end, 8000)
		c4.advance(3000)
		box_is(what, box, want)
	end
	room_step("second output: Room Off", selection("off"), { { "execution.mode", "powersave" } })
	room_step("second output: Watch the Apple TV", watch(SRC.appletv), { { "execution.hdmiActive", true },
		{ "execution.mode", "video" } })
	room_step("second output: Watch the PS5", watch(SRC.ps5), { { "execution.mode", "game" } })
	room_step("second output: Listen to the tuner", selection("listen", SRC.tuner, { SRC.tuner.proxy, via[1] }),
		{ { "execution.mode", "music" } })
	room_step("second output: the TV's own app (the receiver is not on the path)",
		selection("watch", SRC.tv, { SRC.tv.proxy }), { { "execution.mode", "passthrough" },
			{ "execution.hdmiActive", true } })

	set_property(denv, "When The Source Leaves The Box", "Power save")
	room_step("second output: the Apple TV again", watch(SRC.appletv), { { "execution.mode", "video" } })
	room_step("second output: the TV's own app, When The Source Leaves The Box Power save",
		selection("watch", SRC.tv, { SRC.tv.proxy }), { { "execution.mode", "powersave" } })
	set_property(denv, "When The Source Leaves The Box", "Stop syncing and keep the picture")

	set_property(denv, "At Room Off", "Stop syncing and keep the picture")
	room_step("second output: the Apple TV once more", watch(SRC.appletv), { { "execution.mode", "video" } })
	room_step("second output: Room Off, At Room Off keep the picture", selection("off"),
		{ { "execution.mode", "passthrough" }, { "execution.hdmiActive", true } })
	set_property(denv, "At Room Off", "Power save")

	-- Zapping: three sources within half a second; the last one wins.
	n = #T.history
	room_set(watch(SRC.appletv))
	c4.advance(200)
	room_set(watch(SRC.ps5))
	c4.advance(200)
	room_set(watch(SRC.appletv))
	c4.advance(8000)
	local _, count, bodies = put_fields(T, n)
	box_is("second output: zapping", box, { { "execution.mode", "video" } })
	check("second output: zapping: the settle leaves one write (at most two)", count >= 1 and count <= 2,
		count .. " PUTs: " .. bodies)
	only_execution("second output", T, first)

	-- A Director restart, the room turned on while the driver was away: the
	-- first values are a baseline, nothing goes to the box (research W15).
	room_step("second output: Room Off before the restart", selection("off"), { { "execution.mode", "powersave" } })
	n = #T.history
	local persist = {}
	for k, v in pairs(c4.persist) do
		persist[k] = v
	end
	denv.OnDriverDestroyed()
	denv, c4 = start_driver(T, { persist = persist, project = function(c4_)
		project(c4_)
		room_set(watch(SRC.appletv))
	end })
	c4.advance(15000)
	eq("second output: after a restart the room's state is a baseline: no write", 0, #writes(T, n))
	box_is("second output: after a restart", box, { { "execution.mode", "powersave" } })
	room_step("second output: a change after the restart acts", watch(SRC.ps5), { { "execution.mode", "game" } })
	T:close()
end)

-- Retries and the undelivered answer (contracts C4: a write that does not
-- land is retried every 2 s, 4 tries, then answered as undelivered; code 16
-- is reported as busy and not retried), on an in-line box.
suite("routing-faults", function()
	local box = CFG.routing.faults
	if not box then
		return skip("routing under faults", "E2E_ROUTING has no faults box")
	end
	local T, denv, c4 = routing_start(box, routing_project(nil), "in_line", "faults")
	if not T then
		return
	end
	local function put_fault(kind, rest)
		return pcall(fb.run, box, "fault", q(kind) .. " --method PUT --path /execution" .. (rest and (" " .. rest) or ""))
	end
	local input = 1
	local function route_through(kind, rest, what)
		input = input == 1 and 2 or 1
		local ok, err = put_fault(kind, rest)
		if not check(what .. ": the fake takes the fault", ok, err) then
			return
		end
		local m, n = #c4.calls, #T.history
		step(c4, function()
			director(denv, "SET_INPUT", video_input(input))
		end, function() return notified(c4, m, "INPUT_OUTPUT_CHANGED", 999 + input) > 0 end, 30000)
		pcall(fb.clear, box, kind)
		c4.advance(3000)
		box_is(what, box, { { "execution.hdmiSource", "input" .. input } })
		eq(what .. ": INPUT_OUTPUT_CHANGED once", 1, notified(c4, m, "INPUT_OUTPUT_CHANGED", 999 + input))
		local puts = writes(T, n)
		return puts
	end

	local puts = route_through("latency", "ms=400 --count 1", "a PUT answered 400 ms late")
	check("a PUT answered late: one PUT", puts and #puts == 1, puts and #puts)
	puts = route_through("silence", "--count 1", "a PUT without an answer")
	check("a PUT without an answer: tried again (2 PUTs or more)", puts and #puts >= 2, puts and #puts)
	puts = route_through("drop", "--count 1", "a PUT whose connection drops")
	check("a dropped PUT: tried again", puts and #puts >= 2, puts and #puts)
	puts = route_through("5xx", "--count 1", "a PUT answered HTTP 500 (the box did it)")
	check("a PUT answered HTTP 500: confirmed by the read", puts and #puts >= 1, puts and #puts)

	-- The undelivered answer: no PUT lands for 4 tries.
	local ok, err = put_fault("silence")
	if check("the box takes no write: the fake takes the fault", ok, err) then
		input = input == 1 and 2 or 1
		local m, n = #c4.calls, #T.history
		step(c4, function()
			director(denv, "SET_INPUT", video_input(input))
		end, function() return fake.last_action(denv):find("^Not switched") ~= nil end, 60000)
		pcall(fb.clear, box, "silence")
		eq("undelivered: Last Action", "Not switched: the box did not change input", fake.last_action(denv))
		eq("undelivered: no INPUT_OUTPUT_CHANGED", 0, notified(c4, m, "INPUT_OUTPUT_CHANGED"))
		local tries = #writes(T, n)
		eq("undelivered: 4 tries", 4, tries)
		c4.advance(5000)
		box_is("undelivered", box, { { "execution.hdmiSource", "input" .. (input == 1 and 2 or 1) } })
		input = input == 1 and 2 or 1
	end

	-- Code 16: another app streams to the area; reported, not retried.
	ok, err = pcall(fb.event, box, "bridge", { state = "busy" })
	if check("another app streams: the fake takes the event", ok, err) then
		c4.advance(6000)
		input = input == 1 and 2 or 1
		local m, n = #c4.calls, #T.history
		step(c4, function()
			director(denv, "SET_INPUT", video_input(input))
		end, function() return #writes(T, n) > 0 end, ROUTE_MAX)
		c4.advance(12000)
		local refused = 0
		for _, h in ipairs(writes(T, n)) do
			refused = refused + (h.status == 400 and 1 or 0)
		end
		eq("another app streams: the refused sync is not tried again", 1, refused)
		check("another app streams: Last Action names the other app", fake.last_action(denv)
			:find("another app streams", 1, true) ~= nil, fake.last_action(denv))
		local area = "hue.groups.6a7b8c9d-0000-4000-8000-0000000ea001"
		box_is("another app streams", box, { { "execution.hdmiSource", "input" .. input },
			{ "execution.syncActive", false }, { "hue.connectionState", "busy" }, { area .. ".owner", "other-app" } })
		eq("another app streams: the input is still confirmed (INPUT_OUTPUT_CHANGED once)", 1,
			notified(c4, m, "INPUT_OUTPUT_CHANGED", 999 + input))
		pcall(fb.event, box, "bridge", { state = "connected" })
	end

	-- Afterwards a route lands again at once.
	puts = route_through("latency", "ms=1 --count 1", "after the faults")
	check("after the faults: one PUT", puts and #puts == 1, puts and #puts)
	T:close()
end)

-- Stage 4 (#568) ---------------------------------------------------------------------------------
--
-- docs/hdmi-sync-stage4-design.md §1 and §8; contracts C1.4 to C1.9 and C5.
-- Each suite pairs a box of its own in the Python fake (E2E_ROUTING names it)
-- and drives the driver as Director would: programming commands through
-- ExecuteCommand under their <name>, the UI Buttons' SELECT on 5002 to 5005,
-- conditionals through TestCondition, the period rows and the Entertainment
-- Area through OnPropertyChanged, Sync Box Settings as a LUA_ACTION. What the
-- box ends up with is read back from the fake's control API; what Control4
-- sees from the fake runtime (c4.variables, c4.events_fired, the calls).
-- The Hue Bridge's side of C5 is played here (bridge_peer): no bridge driver
-- runs, so no request leaves for a Hue bridge.

local S4 = {}

S4.EVENTS = { sync_started = 1, sync_stopped = 2, mode = 3, intensity = 4, brightness = 5, input = 6, area = 7,
	taken_over = 8, powered_on = 9, power_save = 10, online = 11, offline = 12 }
S4.VARIABLES = { "SYNC_ACTIVE", "SYNC_MODE", "INTENSITY", "BRIGHTNESS", "HDMI_INPUT", "HDMI_INPUT_NAME",
	"ENTERTAINMENT_AREA", "POWER", "ONLINE" }
S4.BUTTONS = { hue_sync = 5002, brighter = 5003, dimmer = 5004, intensity = 5005 }
S4.BRIDGE = 300 -- the Hue Bridge device id standing in on binding 1 (C1.2)
S4.AREA = { tv = "6a7b8c9d-0000-4000-8000-0000000ea001", office = "6a7b8c9d-0000-4000-8000-0000000ea002" }
S4.ICONS_DIR = "src/hue_syncbox/www/icons/"

-- The epoch ms of a local clock time on 2026-11-17 (the run's time zone:
-- tools/e2e_syncbox.sh runs the harness with TZ=UTC).
function S4.at(hour, min)
	return os.time({ year = 2026, month = 11, day = 17, hour = hour, min = min, sec = 0 }) * 1000
end

function S4.command(denv, name, params)
	denv.ExecuteCommand(name, params or {})
end

function S4.var(c4, name)
	local v = c4.variables[name]
	return v and v.value
end

-- The intensity of the mode the box is in (or last synced in) in a state
-- document.
function S4.intensity(doc)
	local ex = type(doc) == "table" and doc.execution or {}
	local mode = (ex.mode == "video" or ex.mode == "game" or ex.mode == "music") and ex.mode or ex.lastSyncMode
	return type(ex[mode]) == "table" and ex[mode].intensity or nil
end

-- A property's list as Composer has it (C4:UpdatePropertyList takes the
-- items comma-separated; a table is taken as it is).
function S4.list(c4, name)
	local list = c4.property_lists[name]
	if type(list) == "table" then
		return list
	end
	local out = {}
	for item in tostring(list or ""):gmatch("[^,]+") do
		out[#out + 1] = item
	end
	return out
end

-- How many times event `id` fired after the n-th one.
function S4.fired(c4, n, id)
	local count = 0
	for i = n + 1, #c4.events_fired do
		if c4.events_fired[i] == id then
			count = count + 1
		end
	end
	return count
end

function S4.events_text(c4, n)
	local out = {}
	for i = n + 1, #c4.events_fired do
		out[#out + 1] = tostring(c4.events_fired[i])
	end
	return #out > 0 and table.concat(out, ",") or "none"
end

-- Whether, after the m-th call, the variable `name` was set before the first
-- FireEventByID(id) (C1.9: a variable is set before the event that reports
-- its change).
function S4.set_before(c4, m, name, id)
	local set_at, fired_at
	for i = m + 1, #c4.calls do
		local call = c4.calls[i]
		if call.name == "SetVariable" and call.args[1] == name and not set_at then
			set_at = i
		elseif call.name == "FireEventByID" and tonumber(call.args[1]) == id and not fired_at then
			fired_at = i
		end
	end
	return set_at ~= nil and fired_at ~= nil and set_at < fired_at, string.format("SetVariable %s at %s, event %d at %s",
		name, tostring(set_at), id, tostring(fired_at))
end

-- The ICON_CHANGED notifies to `binding` after the m-th call, in order.
function S4.icons(c4, m, binding)
	local out = {}
	for i = m + 1, #c4.calls do
		local call = c4.calls[i]
		if call.name == "SendToProxy" and tonumber(call.args[1]) == binding and call.args[2] == "ICON_CHANGED" then
			out[#out + 1] = call.args[3] or {}
		end
	end
	return out
end

function S4.last_icon(c4, m, binding)
	local list = S4.icons(c4, m, binding)
	return list[#list] and list[#list].icon
end

-- A UI Button press as Navigator sends it (UIB 107/_1: the room and the menu).
function S4.press(denv, binding)
	denv.ReceivedFromProxy(binding, "SELECT", { ROOM_ID = tostring(ROOM), MENU = "watch" })
end

-- The fake clock on until pred() holds, a read's time at a time; false after
-- max_ms.
function S4.until_read(c4, pred, max_ms)
	return until_(c4, pred, max_ms or 20000, 500)
end

-- The PUT bodies to `path` after the n-th transfer that the box answered,
-- decoded.
function S4.puts(T, n, path)
	local out = {}
	for _, h in ipairs(sent(T, n, "PUT", "/api/v1" .. path)) do
		out[#out + 1] = { status = h.status, body = json.decode(h.data or "") or {}, data = h.data }
	end
	return out
end

-- Every write after the n-th transfer that is not on `allowed` paths.
function S4.other_writes(T, n, allowed)
	local out = {}
	for _, h in ipairs(sent(T, n)) do
		if h.method ~= "GET" and not allowed[h.path] then
			out[#out + 1] = h.method .. " " .. tostring(h.path)
		end
	end
	return out
end

-- The project of a stage 4 suite, as Director has it at every start: the
-- clock at opts.clock, the project's location opts.location, an Apple TV in
-- the box's room bound to its HDMI 1 (in line: Control4 routes through the
-- box) unless opts.unbound, the box's AV proxy named opts.name (default the
-- fixture's box name, so the two-way name starts in agreement), the
-- properties in opts.properties, then opts.project.
function S4.project(opts)
	return function(c4_, denv_)
		if opts.clock then
			c4_.now_ms = opts.clock
		end
		for k, v in pairs(opts.location or {}) do
			c4_.project_properties[k] = v
		end
		for k, v in pairs(opts.properties or {}) do
			denv_.Properties[k] = v
		end
		if type(fake.add_device) == "function" then
			local s = SRC.appletv
			fake.add_device(s.id, { name = s.name, driver = s.file, proxy = s.kind, proxy_id = s.proxy, room_id = ROOM })
			if not opts.unbound then
				table.insert(c4_.bindings, { provider = s.proxy, provider_binding = 2000, consumer = box_proxy(),
					consumer_binding = 1000, class = "HDMI" })
			end
		end
		local proxy = fake.project.devices[box_proxy() or -1]
		if proxy then
			proxy.name = opts.name or "Living Room Sync Box"
		end
		if opts.project then
			opts.project(c4_, denv_)
		end
	end
end

-- Pair a stage 4 suite's box in that project.
function S4.start(box, what, opts)
	opts = opts or {}
	local T = new_transport({ box = box })
	local denv, c4 = start_driver(T, { project = S4.project(opts) })
	if not pair(denv, c4, box, CFG.address, T, what) then
		T:close()
		return nil
	end
	c4.advance(6000)
	return T, denv, c4
end

-- A Director restart of a stage 4 suite's device: the store and the property
-- values kept, the project as before (opts as S4.start's), the clock on from
-- where it was (opts.clock overrides), the AV proxy's name as it was.
function S4.restart(T, denv, c4, opts)
	opts = opts or {}
	local persist, props = {}, {}
	for k, v in pairs(c4.persist) do
		persist[k] = v
	end
	for k, v in pairs(denv.Properties) do
		props[k] = v
	end
	local proxy = fake.project.devices[box_proxy() or -1]
	local again = {}
	for k, v in pairs(opts) do
		again[k] = v
	end
	again.clock = opts.clock or c4.now_ms
	again.name = proxy and proxy.name or opts.name
	again.properties = props
	denv.OnDriverDestroyed()
	return start_driver(T, { persist = persist, project = S4.project(again) })
end

-- The Hue Bridge's side of C5 for one suite: the bridge device S4.BRIDGE bound
-- on the box's binding 1 (class HUE_SYNCBOX), every SendToDevice to it kept,
-- and STOP_AREA answered as `answer(params)` says (nil: no answer), the answer
-- delivered a moment later through ExecuteCommand, as Director delivers a
-- SendToDevice.
function S4.bridge_peer(answer)
	local peer = { sent = {}, answer = answer }
	function peer.project(c4)
		table.insert(c4.bindings, { provider = S4.BRIDGE, provider_binding = 2, consumer = BOX_DEVICE,
			consumer_binding = 1, class = "HUE_SYNCBOX" })
	end
	-- Installed once the driver runs (the runtime's SendToDevice is wrapped).
	function peer.attach(c4, denv)
		local original = c4.SendToDevice
		c4.SendToDevice = function(self, id, command, params, ...)
			if tonumber(id) == S4.BRIDGE then
				local copy = {}
				for k, v in pairs(params or {}) do
					copy[k] = tostring(v)
				end
				peer.sent[#peer.sent + 1] = { command = command, params = copy }
				if command == "HUE_SYNCBOX_STOP_AREA" and peer.answer then
					local reply = peer.answer(copy)
					if reply then
						c4:SetTimer(50, function()
							denv.ExecuteCommand("HUE_SYNCBOX_STOPPED", reply)
						end)
					end
				end
				return
			end
			return original(self, id, command, params, ...)
		end
	end
	function peer.count(command, n)
		local c = 0
		for i = (n or 0) + 1, #peer.sent do
			if peer.sent[i].command == command then
				c = c + 1
			end
		end
		return c
	end
	function peer.last(command)
		for i = #peer.sent, 1, -1 do
			if peer.sent[i].command == command then
				return peer.sent[i].params
			end
		end
		return nil
	end
	return peer
end

-- Programming (C1.6 to C1.9): the variables in their order and as the box
-- reads, no event for a baseline, each command's write and its events (each
-- variable set first), Apply Sync Settings as one PUT, the conditionals, the
-- HDMI input changed by the box itself, Offline and Online, and a restart
-- that fires nothing.
suite("programming", function()
	local box = CFG.routing.programming
	if not box then
		return skip("programming", "E2E_ROUTING has no programming box")
	end
	local T, denv, c4 = S4.start(box, "programming", { clock = S4.at(12, 0) })
	if not T then
		return
	end
	-- C1.9: the nine variables, added in OnDriverInit in this order, ids 1001
	-- to 1009 on a new device.
	eq("the nine variables, in C1.9's order", table.concat(S4.VARIABLES, ","),
		table.concat(c4.variable_names or {}, ","))
	for i, name in ipairs(S4.VARIABLES) do
		local v = c4.variables[name] or {}
		eq(name .. ": id " .. (1000 + i), 1000 + i, v.id)
		check(name .. ": read-only", v.read_only == true, tostring(v.read_only))
	end
	-- The first reads are a baseline: the values as the box reads, no event.
	S4.until_read(c4, function() return S4.var(c4, "SYNC_MODE") == "video" end)
	local want = { SYNC_ACTIVE = "1", SYNC_MODE = "video", INTENSITY = "high", BRIGHTNESS = "100", HDMI_INPUT = "1",
		HDMI_INPUT_NAME = "Apple TV", ENTERTAINMENT_AREA = "Living Room TV", POWER = "on", ONLINE = "1" }
	for _, name in ipairs(S4.VARIABLES) do
		eq("baseline " .. name, want[name], S4.var(c4, name))
	end
	eq("no event for the first reads (a baseline, C1.9)", "none", S4.events_text(c4, 0))

	-- Each command: its write, the box's state, the variable and its event.
	local function run(what, name, params, state, var_checks, events, max_ms)
		local n, m, e = #T.history, #c4.calls, #c4.events_fired
		S4.command(denv, name, params)
		local landed = S4.until_read(c4, function()
			local doc = fb.state(box)
			for _, s in ipairs(state) do
				if lookup_path(doc, s[1]) ~= s[2] then
					return false
				end
			end
			for _, v in ipairs(var_checks or {}) do
				if S4.var(c4, v[1]) ~= v[2] then
					return false
				end
			end
			return true
		end, max_ms)
		check(what .. ": the box shows it", landed, fake.last_action(denv))
		box_is(what, box, state)
		for _, v in ipairs(var_checks or {}) do
			eq(what .. ": " .. v[1], v[2], S4.var(c4, v[1]))
		end
		for _, ev in ipairs(events or {}) do
			check(what .. ": event " .. ev[2] .. " fired", S4.fired(c4, e, ev[2]) >= 1, S4.events_text(c4, e))
			if ev[1] then
				local ok, why = S4.set_before(c4, m, ev[1], ev[2])
				check(what .. ": " .. ev[1] .. " set before event " .. ev[2], ok, why)
			end
		end
		local _, other = writes(T, n)
		local names = {}
		for _, h in ipairs(other) do
			names[#names + 1] = h.method .. " " .. tostring(h.path)
		end
		check(what .. ": only PUT /execution written", #other == 0, table.concat(names, ", "))
		return n, e
	end

	run("Stop Sync", "Stop Sync", {}, { { "execution.mode", "passthrough" }, { "execution.hdmiActive", true } },
		{ { "SYNC_ACTIVE", "0" }, { "SYNC_MODE", "off" } }, { { "SYNC_ACTIVE", 2 }, { "SYNC_MODE", 3 } })
	starts("Stop Sync: Last Action", "Sync stopped", fake.last_action(denv))
	-- At noon the period is Day: High and 100 % (contracts C1.4's defaults).
	run("Start Sync", "Start Sync", {}, { { "execution.mode", "video" }, { "execution.syncActive", true },
		{ "execution.video.intensity", "high" }, { "execution.brightness", 100 } },
		{ { "SYNC_ACTIVE", "1" }, { "SYNC_MODE", "video" } }, { { "SYNC_ACTIVE", 1 }, { "SYNC_MODE", 3 } })
	starts("Start Sync: Last Action", "Syncing", fake.last_action(denv))
	run("Set Sync Mode Game", "Set Sync Mode", { Mode = "Game" }, { { "execution.mode", "game" } },
		{ { "SYNC_MODE", "game" } }, { { "SYNC_MODE", 3 } })
	run("Set Intensity Intense", "Set Intensity", { Intensity = "Intense" }, { { "execution.game.intensity", "intense" } },
		{ { "INTENSITY", "intense" } }, { { "INTENSITY", 4 } })
	run("Next Intensity wraps to Subtle", "Next Intensity", {}, { { "execution.game.intensity", "subtle" } },
		{ { "INTENSITY", "subtle" } }, { { "INTENSITY", 4 } })
	run("Set Brightness 150", "Set Brightness", { Brightness = "150" }, { { "execution.brightness", 150 } },
		{ { "BRIGHTNESS", "150" } }, { { "BRIGHTNESS", 5 } })
	run("Adjust Brightness -30", "Adjust Brightness", { Step = "-30" }, { { "execution.brightness", 120 } },
		{ { "BRIGHTNESS", "120" } }, { { "BRIGHTNESS", 5 } })
	run("Adjust Brightness +200 stops at 200", "Adjust Brightness", { Step = "200" }, { { "execution.brightness", 200 } },
		{ { "BRIGHTNESS", "200" } }, { { "BRIGHTNESS", 5 } })

	-- Apply Sync Settings: every field in one PUT, the area from the
	-- command's own list (GetCommandParamList, OS 3.3.0).
	local list = type(denv.GetCommandParamList) == "function" and denv.GetCommandParamList("Apply Sync Settings", "Area")
		or {}
	local office
	for _, item in ipairs(list) do
		local text = type(item) == "table" and (item.text or item.value) or item
		if tostring(text):find("Office", 1, true) then
			office = type(item) == "table" and (item.value or item.text) or item
		end
	end
	check("Apply Sync Settings: its Area list offers the box's areas", office ~= nil, json.encode(list))
	local n = run("Apply Sync Settings", "Apply Sync Settings", { Mode = "Video", Intensity = "Moderate",
		Brightness = "80 %", Area = office or "Office", Start = "Start" }, { { "execution.mode", "video" },
		{ "execution.video.intensity", "moderate" }, { "execution.brightness", 80 },
		{ "execution.hueTarget", S4.AREA.office } }, { { "SYNC_MODE", "video" }, { "INTENSITY", "moderate" },
		{ "BRIGHTNESS", "80" }, { "ENTERTAINMENT_AREA", "Office" } }, { { "SYNC_MODE", 3 }, { "INTENSITY", 4 },
		{ "BRIGHTNESS", 5 }, { "ENTERTAINMENT_AREA", 7 } })
	local puts = S4.puts(T, n, "/execution")
	eq("Apply Sync Settings: one PUT", 1, #puts)
	local body = puts[1] and puts[1].body or {}
	check("Apply Sync Settings: the PUT carries mode, the mode's intensity, brightness and area together",
		body.mode == "video" and type(body.video) == "table" and body.video.intensity == "moderate"
		and body.brightness == 80 and body.hueTarget == S4.AREA.office, puts[1] and puts[1].data)
	starts("Apply Sync Settings: Last Action", "Sync settings applied", fake.last_action(denv))
	S4.command(denv, "Apply Sync Settings", { Mode = "Leave", Intensity = "Leave", Brightness = "Leave",
		Area = "Leave", Start = "Leave" })
	c4.advance(2000)
	eq("Apply Sync Settings with every field Leave: nothing to do", "Apply Sync Settings not done: every field is Leave",
		fake.last_action(denv))

	-- Set Entertainment Area back to Living Room TV, from its own list.
	local tv
	for _, item in ipairs(type(denv.GetCommandParamList) == "function"
		and denv.GetCommandParamList("Set Entertainment Area", "Area") or {}) do
		local text = type(item) == "table" and (item.text or item.value) or item
		if tostring(text):find("Living Room TV", 1, true) then
			tv = type(item) == "table" and (item.value or item.text) or item
		end
	end
	run("Set Entertainment Area", "Set Entertainment Area", { Area = tv or "Living Room TV" },
		{ { "execution.hueTarget", S4.AREA.tv } }, { { "ENTERTAINMENT_AREA", "Living Room TV" } },
		{ { "ENTERTAINMENT_AREA", 7 } })

	-- Select HDMI Input: the box switches, the room does not follow.
	local m = #c4.calls
	run("Select HDMI Input HDMI 2", "Select HDMI Input", { Input = "HDMI 2" }, { { "execution.hdmiSource", "input2" } },
		{ { "HDMI_INPUT", "2" }, { "HDMI_INPUT_NAME", "PlayStation" } }, { { "HDMI_INPUT", 6 } })
	check("Select HDMI Input: Last Action says the room does not follow", tostring(fake.last_action(denv))
		:find("does not follow", 1, true) ~= nil, fake.last_action(denv))
	eq("Select HDMI Input: no INPUT_OUTPUT_CHANGED to the AV proxy", 0, notified(c4, m, "INPUT_OUTPUT_CHANGED"))

	-- The box switching by itself (CEC Active Source on HDMI 1): HDMI Input
	-- Changed from any cause.
	local e = #c4.events_fired
	local ok, err = pcall(fb.event, box, "cec_active_source", { input = 1 })
	if check("the box switches by itself: the fake takes the event", ok, err) then
		S4.until_read(c4, function() return S4.var(c4, "HDMI_INPUT") == "1" end)
		eq("the box switched by itself: HDMI_INPUT", "1", S4.var(c4, "HDMI_INPUT"))
		eq("the box switched by itself: HDMI Input Changed fired", 1, S4.fired(c4, e, S4.EVENTS.input))
	end

	-- The conditionals (C1.8), against the box now (video, moderate, 80 %, HDMI 1).
	local function cond(name, params)
		return type(denv.TestCondition) == "function" and denv.TestCondition(name, params) == true
	end
	check("Sync Active is True", cond("BOOL_SYNC_ACTIVE", { VALUE = "True" }))
	check("Sync Active is not False", not cond("BOOL_SYNC_ACTIVE", { VALUE = "False" }))
	check("Sync Mode is Video", cond("LIST_SYNC_MODE", { VALUE = "Video", LOGIC = "EQUAL" }))
	check("Sync Mode is not Game", cond("LIST_SYNC_MODE", { VALUE = "Game", LOGIC = "NOT_EQUAL" }))
	check("Intensity is Moderate", cond("LIST_INTENSITY", { VALUE = "Moderate", LOGIC = "EQUAL" }))
	check("Intensity is below High", cond("LIST_INTENSITY", { VALUE = "High", LOGIC = "LESS_THAN" }))
	check("HDMI Input is HDMI 1", cond("LIST_HDMI_INPUT", { VALUE = "HDMI 1", LOGIC = "EQUAL" }))
	check("Brightness is above 50", cond("NUMBER_BRIGHTNESS", { VALUE = "50", LOGIC = "GREATER_THAN" }))
	check("Brightness is not 100", not cond("NUMBER_BRIGHTNESS", { VALUE = "100", LOGIC = "EQUAL" }))
	check("Powered On is True", cond("BOOL_POWERED_ON", { VALUE = "True" }))
	check("Online is True", cond("BOOL_ONLINE", { VALUE = "True" }))

	-- Power Save and Wake.
	run("Power Save", "Power Save", {}, { { "execution.mode", "powersave" }, { "execution.hdmiActive", false } },
		{ { "POWER", "powersave" }, { "SYNC_ACTIVE", "0" } }, { { "POWER", 10 }, { "SYNC_ACTIVE", 2 } })
	check("in power save Powered On is False", cond("BOOL_POWERED_ON", { VALUE = "False" }))
	run("Wake", "Wake", {}, { { "execution.hdmiActive", true }, { "execution.mode", "passthrough" } },
		{ { "POWER", "on" } }, { { "POWER", 9 } })
	run("Toggle Sync starts", "Toggle Sync", {}, { { "execution.syncActive", true } }, { { "SYNC_ACTIVE", "1" } },
		{ { "SYNC_ACTIVE", 1 } })
	run("Toggle Sync stops", "Toggle Sync", {}, { { "execution.syncActive", false }, { "execution.mode", "passthrough" } },
		{ { "SYNC_ACTIVE", "0" } }, { { "SYNC_ACTIVE", 2 } })

	-- A bad parameter is refused before anything is sent.
	n = #T.history
	S4.command(denv, "Set Brightness", { Brightness = "250" })
	c4.advance(2000)
	eq("Set Brightness 250: nothing written", 0, #writes(T, n))
	check("Set Brightness 250: Last Action says why", tostring(fake.last_action(denv)):find("not done", 1, true) ~= nil,
		fake.last_action(denv))

	-- Offline after 5 minutes of silence, then Online (C1.7 ids 12 and 11,
	-- ONLINE set first).
	m, e = #c4.calls, #c4.events_fired
	fb.fault(box, "silence")
	local offline = until_(c4, function() return S4.var(c4, "ONLINE") == "0" end, 9 * MINUTE, 5000)
	check("silence: ONLINE 0 after the 5-minute rule", offline, P(denv, "Online"))
	eq("silence: Offline fired once", 1, S4.fired(c4, e, S4.EVENTS.offline))
	local fine, why = S4.set_before(c4, m, "ONLINE", S4.EVENTS.offline)
	check("silence: ONLINE set before Offline", fine, why)
	check("Online is False while offline", cond("BOOL_ONLINE", { VALUE = "False" }))
	m, e = #c4.calls, #c4.events_fired
	fb.clear(box, "silence")
	local back = until_(c4, function() return S4.var(c4, "ONLINE") == "1" end, 2 * MINUTE, 5000)
	check("back: ONLINE 1", back, P(denv, "Online"))
	eq("back: Online fired once", 1, S4.fired(c4, e, S4.EVENTS.online))
	fine, why = S4.set_before(c4, m, "ONLINE", S4.EVENTS.online)
	check("back: ONLINE set before Online", fine, why)

	-- A Director restart: the variables kept, no event for a value that did
	-- not change (design 5.5).
	local before = {}
	for _, name in ipairs(S4.VARIABLES) do
		before[name] = S4.var(c4, name)
	end
	n = #T.history
	denv, c4 = S4.restart(T, denv, c4, { })
	S4.until_read(c4, function() return P(denv, "Online") == "Online" end, 30000)
	c4.advance(15000)
	eq("after a restart: no event fires for values that did not change", "none", S4.events_text(c4, 0))
	for _, name in ipairs(S4.VARIABLES) do
		eq("after a restart: " .. name .. " as before", before[name], S4.var(c4, name))
	end
	eq("after a restart: nothing written", 0, #writes(T, n) + #select(2, writes(T, n)))
	token_kept(denv, c4, "programming")
	T:close()
end)

-- The four UI Buttons (design 5.6; C1.1): Hue Sync toggles and its icon
-- follows, Sync Brighter and Sync Dimmer step 10 points (quick presses add
-- up), Sync Intensity steps and its icon shows the level; every icon state
-- the driver sends is one driver.xml declares and make_icons.py drew.
suite("buttons", function()
	local box = CFG.routing.buttons
	if not box then
		return skip("buttons", "E2E_ROUTING has no buttons box")
	end
	local T, denv, c4 = S4.start(box, "buttons", { clock = S4.at(12, 0) })
	if not T then
		return
	end
	local xml = assert(io.open("src/hue_syncbox/driver.xml")):read("*a")
	local function declared(binding, id)
		local block = xml:match('<navigator_display_option proxybindingid="' .. binding
			.. '">(.-)</navigator_display_option>')
		if not block then
			return false, "no navigator_display_option for " .. binding
		end
		if not block:find('<state id="' .. id .. '">', 1, true) then
			return false, "no state " .. id
		end
		for _, size in ipairs({ 300, 90, 70 }) do
			local path = S4.ICONS_DIR .. id .. "_" .. size .. ".png"
			local f = io.open(path, "rb")
			if not f then
				return false, path .. " missing"
			end
			f:close()
			if not block:find("controller://driver/hue_syncbox/icons/" .. id .. "_" .. size .. ".png", 1, true) then
				return false, "the state does not name " .. path
			end
		end
		return true
	end
	-- At start (late init, then the first reads) the icons show the box.
	S4.until_read(c4, function() return S4.last_icon(c4, 0, S4.BUTTONS.intensity) ~= nil end)
	eq("Hue Sync's icon: on (the box syncs)", "sync_on", S4.last_icon(c4, 0, S4.BUTTONS.hue_sync))
	eq("Sync Intensity's icon: high", "intensity_high", S4.last_icon(c4, 0, S4.BUTTONS.intensity))
	local first = S4.icons(c4, 0, S4.BUTTONS.hue_sync)[1] or {}
	check("ICON_CHANGED carries an icon_description", type(first.icon_description) == "string"
		and first.icon_description ~= "", json.encode(first))
	for _, id in ipairs({ "sync_on", "sync_off" }) do
		local ok, why = declared(5002, id)
		check("Hue Sync's state " .. id .. " is declared with its three icons", ok, why)
	end
	for _, level in ipairs({ "subtle", "moderate", "high", "intense" }) do
		local ok, why = declared(5005, "intensity_" .. level)
		check("Sync Intensity's state intensity_" .. level .. " is declared with its three icons", ok, why)
	end

	-- Hue Sync: off, then on again; the icon follows the reads.
	local m = #c4.calls
	S4.press(denv, S4.BUTTONS.hue_sync)
	S4.until_read(c4, function() return S4.last_icon(c4, m, S4.BUTTONS.hue_sync) == "sync_off" end)
	box_is("Hue Sync pressed while syncing", box, { { "execution.mode", "passthrough" },
		{ "execution.hdmiActive", true } })
	eq("Hue Sync pressed while syncing: icon sync_off", "sync_off", S4.last_icon(c4, m, S4.BUTTONS.hue_sync))
	m = #c4.calls
	S4.press(denv, S4.BUTTONS.hue_sync)
	S4.until_read(c4, function() return S4.last_icon(c4, m, S4.BUTTONS.hue_sync) == "sync_on" end)
	box_is("Hue Sync pressed again", box, { { "execution.mode", "video" }, { "execution.syncActive", true },
		{ "execution.video.intensity", "high" }, { "execution.brightness", 100 } })
	eq("Hue Sync pressed again: icon sync_on", "sync_on", S4.last_icon(c4, m, S4.BUTTONS.hue_sync))

	-- Sync Brighter and Sync Dimmer: 10 points a press.
	S4.press(denv, S4.BUTTONS.brighter)
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.brightness") == 110 end)
	box_is("Sync Brighter", box, { { "execution.brightness", 110 } })
	S4.press(denv, S4.BUTTONS.dimmer)
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.brightness") == 100 end)
	box_is("Sync Dimmer", box, { { "execution.brightness", 100 } })
	-- Three quick presses add up, in few PUTs, never as the box's increment.
	local n = #T.history
	S4.press(denv, S4.BUTTONS.brighter)
	S4.press(denv, S4.BUTTONS.brighter)
	S4.press(denv, S4.BUTTONS.brighter)
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.brightness") == 130 end)
	box_is("three quick presses of Sync Brighter", box, { { "execution.brightness", 130 } })
	local puts = S4.puts(T, n, "/execution")
	local increments = 0
	for _, p in ipairs(puts) do
		increments = increments + (p.body.incrementBrightness ~= nil and 1 or 0)
	end
	check("three quick presses: at most three PUTs", #puts >= 1 and #puts <= 3, #puts .. " PUTs")
	eq("three quick presses: no incrementBrightness (a resend must change nothing more, SB57)", 0, increments)
	-- At the top, Sync Brighter stops at 200.
	S4.command(denv, "Set Brightness", { Brightness = "195" })
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.brightness") == 195 end)
	S4.press(denv, S4.BUTTONS.brighter)
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.brightness") == 200 end)
	box_is("Sync Brighter at 195 stops at 200", box, { { "execution.brightness", 200 } })

	-- Sync Intensity: High -> Intense -> Subtle; the icon follows.
	for _, step_ in ipairs({ { "intense", "intensity_intense" }, { "subtle", "intensity_subtle" },
		{ "moderate", "intensity_moderate" } }) do
		m = #c4.calls
		S4.press(denv, S4.BUTTONS.intensity)
		S4.until_read(c4, function() return S4.last_icon(c4, m, S4.BUTTONS.intensity) == step_[2] end)
		box_is("Sync Intensity to " .. step_[1], box, { { "execution.video.intensity", step_[1] } })
		eq("Sync Intensity to " .. step_[1] .. ": its icon", step_[2], S4.last_icon(c4, m, S4.BUTTONS.intensity))
	end

	-- Pressed while the box does not sync: the change is what the next sync
	-- starts with (the sync's stop ended the earlier holds, design 5.3).
	m = #c4.calls
	S4.press(denv, S4.BUTTONS.hue_sync)
	S4.until_read(c4, function() return S4.var(c4, "SYNC_ACTIVE") == "0" end)
	S4.press(denv, S4.BUTTONS.dimmer)
	S4.until_read(c4, function() return S4.var(c4, "BRIGHTNESS") == "190" end)
	box_is("Sync Dimmer while not syncing", box, { { "execution.mode", "passthrough" }, { "execution.brightness", 190 } })
	S4.press(denv, S4.BUTTONS.hue_sync)
	S4.until_read(c4, function() return S4.var(c4, "SYNC_ACTIVE") == "1" end)
	box_is("then Hue Sync: the Day's intensity, the brightness set by hand", box, { { "execution.syncActive", true },
		{ "execution.video.intensity", "high" }, { "execution.brightness", 190 } })

	-- A SELECT on a binding that is no button, and another proxy command on a
	-- button, write nothing (#483 D-7).
	n = #T.history
	denv.ReceivedFromProxy(5001, "SELECT", {})
	denv.ReceivedFromProxy(5006, "SELECT", {})
	denv.ReceivedFromProxy(5003, "ON", {})
	c4.advance(3000)
	eq("SELECT on 5001 or 5006, ON on 5003: nothing written", 0, #writes(T, n))

	-- A restart: the icons sent again at late init from the kept state.
	local _
	_, c4 = S4.restart(T, denv, c4)
	S4.until_read(c4, function() return S4.last_icon(c4, 0, S4.BUTTONS.intensity) ~= nil end, 30000)
	eq("after a restart: Hue Sync's icon", "sync_on", S4.last_icon(c4, 0, S4.BUTTONS.hue_sync))
	eq("after a restart: Sync Intensity's icon", "intensity_high", S4.last_icon(c4, 0, S4.BUTTONS.intensity))
	T:close()
end)

-- The periods (design 5.3; C1.4), on the driver's fake clock from 21:55 UTC
-- on 2026-11-17 with the project at a placeholder location on the prime
-- meridian (sunset about 16:00 UTC, Evening from about 15:00): the period's
-- values at a sync start, the Night's at 22:00, a hold by hand that outlives
-- the next boundaries until the sync stops, a setting changed in Composer,
-- and a boundary passed while the driver was down that is not applied.
suite("periods", function()
	local box = CFG.routing.periods
	if not box then
		return skip("periods", "E2E_ROUTING has no periods box")
	end
	local T, denv, c4 = S4.start(box, "periods", { clock = S4.at(21, 55),
		location = { Latitude = "51.48", Longitude = "0.0" } })
	if not T then
		return
	end
	starts("Periods row: Evening until 22:00", "Evening until 22:00", P(denv, "Periods"))
	check("Periods row: the sunset from the project's location", tostring(P(denv, "Periods"))
		:find("from the project's location", 1, true) ~= nil, P(denv, "Periods"))
	-- A sync start in the Evening: Moderate and 100 %.
	S4.command(denv, "Stop Sync", {})
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.mode") == "passthrough" end)
	S4.command(denv, "Start Sync", {})
	S4.until_read(c4, function()
		return S4.var(c4, "SYNC_ACTIVE") == "1" and S4.var(c4, "INTENSITY") == "moderate"
	end)
	box_is("Start Sync in the Evening", box, { { "execution.video.intensity", "moderate" },
		{ "execution.brightness", 100 } })
	-- 22:00: the Night's Subtle and 70 % while it syncs, one write.
	local n, e = #T.history, #c4.events_fired
	until_(c4, function() return lookup_path(fb.state(box), "execution.brightness") == 70 end, 8 * MINUTE, 5000)
	box_is("at 22:00", box, { { "execution.video.intensity", "subtle" }, { "execution.brightness", 70 } })
	starts("at 22:00: Last Action", "Night: intensity subtle, brightness 70 %", fake.last_action(denv))
	starts("at 22:00: Periods row", "Night until 07:00", P(denv, "Periods"))
	check("at 22:00: Intensity Changed and Brightness Changed fired", S4.fired(c4, e, S4.EVENTS.intensity) == 1
		and S4.fired(c4, e, S4.EVENTS.brightness) == 1, S4.events_text(c4, e))
	local puts = S4.puts(T, n, "/execution")
	eq("at 22:00: one PUT", 1, #puts)
	-- A hold by hand: Sync Brighter, then a setting that makes it Evening
	-- again (Night Starts 22:30) and the boundary at 22:30 keep 80 %.
	S4.press(denv, S4.BUTTONS.brighter)
	S4.until_read(c4, function() return S4.var(c4, "BRIGHTNESS") == "80" end)
	S4.until_read(c4, function() return tostring(P(denv, "Periods")):find("set by hand", 1, true) ~= nil end, 10000)
	check("Sync Brighter: the Periods row says the brightness is held", tostring(P(denv, "Periods"))
		:find("brightness set by hand", 1, true) ~= nil, P(denv, "Periods"))
	set_property(denv, "Night Starts", "22:30")
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.video.intensity") == "moderate" end)
	box_is("Night Starts 22:30 at about 22:05: Evening again, the brightness held", box,
		{ { "execution.video.intensity", "moderate" }, { "execution.brightness", 80 } })
	until_(c4, function() return lookup_path(fb.state(box), "execution.video.intensity") == "subtle" end, 30 * MINUTE,
		10000)
	box_is("at 22:30: the Night's intensity, the brightness still held", box,
		{ { "execution.video.intensity", "subtle" }, { "execution.brightness", 80 } })
	-- A bad setting is refused, the default used, and Last Action says so.
	set_property(denv, "Day Starts", "7 o'clock")
	c4.advance(1000)
	check("Day Starts \"7 o'clock\": Last Action says why", tostring(fake.last_action(denv))
		:find("Day Starts", 1, true) ~= nil, fake.last_action(denv))
	set_property(denv, "Day Starts", "07:00")
	-- The sync stops (a read shows it): the hold ends; the next start takes the
	-- Night's 70 %.
	S4.command(denv, "Stop Sync", {})
	S4.until_read(c4, function() return S4.var(c4, "SYNC_ACTIVE") == "0" end)
	check("the sync stopped: the Periods row holds nothing", tostring(P(denv, "Periods")):find("set by hand", 1, true)
		== nil, P(denv, "Periods"))
	S4.command(denv, "Start Sync", {})
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.brightness") == 70 end)
	box_is("after a stop, a start takes the Night's values again", box, { { "execution.video.intensity", "subtle" },
		{ "execution.brightness", 70 } })
	-- A hold, then the source changes (Control4 routes HDMI 2): released.
	S4.press(denv, S4.BUTTONS.dimmer)
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.brightness") == 60 end)
	director(denv, "SET_INPUT", video_input(2))
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.hdmiSource") == "input2" end)
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.brightness") == 70 end)
	box_is("a new source ends the hold: the Night's brightness", box, { { "execution.brightness", 70 } })
	-- Down across a boundary: Night Starts back to 22:00 is no change now, so
	-- make the next boundary 23:10; the driver is down from 23:05 to 23:20 and
	-- sends nothing for it at start.
	set_property(denv, "Night Starts", "23:10")
	S4.until_read(c4, function() return S4.intensity(fb.state(box)) == "moderate" end)
	eq("Night Starts 23:10: Evening again, Moderate", "moderate", S4.intensity(fb.state(box)))
	-- 23:05 now; down until 23:20.
	until_(c4, function() return c4.now_ms >= S4.at(23, 5) end, HOUR, 30000)
	n = #T.history
	denv, c4 = S4.restart(T, denv, c4, { clock = S4.at(23, 20), location = { Latitude = "51.48", Longitude = "0.0" } })
	c4.advance(20000)
	local _, other = writes(T, n)
	eq("down across 23:10: nothing written at start (no catch-up)", 0, #writes(T, n) + #other)
	starts("after the restart: Periods row", "Night until 07:00", P(denv, "Periods"))
	T:close()
end)

-- Sync Box Settings (design 5.4, O4, O18): Attention while Control4 routes
-- through a box that switches inputs by itself; Let Control4 choose inputs
-- turns off exactly what was on, in one PUT /behavior, and the box no longer
-- switches by itself; Restore puts back exactly that; nothing by itself.
suite("offers", function()
	local box = CFG.routing.offers
	if not box then
		return skip("offers", "E2E_ROUTING has no offers box")
	end
	local T, denv, c4 = S4.start(box, "offers", { clock = S4.at(12, 0) })
	if not T then
		return
	end
	local first = #T.history
	-- The box device has no Attention row of its own: the Input Switching row
	-- and Status carry it (S4 §7: "Input Switching on Attention").
	local function attention_shown()
		return (tostring(P(denv, "Status")) .. " | " .. tostring(P(denv, "Input Switching"))):find("Attention: ", 1, true)
			~= nil
	end
	S4.until_read(c4, attention_shown)
	check("routed through a box that switches by itself: on Attention", attention_shown(),
		tostring(P(denv, "Status")) .. " | " .. tostring(P(denv, "Input Switching")))
	check("the Input Switching row says what the box does", tostring(P(denv, "Input Switching"))
		:find("HDMI CEC switching on HDMI 1, 2", 1, true) ~= nil, P(denv, "Input Switching"))
	local list = type(denv.SyncBoxSettingsList) == "function" and denv.SyncBoxSettingsList() or {}
	local let, restore
	for _, item in ipairs(list) do
		if tostring(item.text):find("^Let Control4 choose inputs") then
			let = item.value
		elseif tostring(item.text):find("^Restore the box's input switching") then
			restore = item.value
		end
	end
	check("Sync Box Settings offers Let Control4 choose inputs and Restore", let ~= nil and restore ~= nil,
		json.encode(list))
	c4.advance(2 * MINUTE)
	eq("never written by itself: no PUT /behavior in two minutes of reads", 0, #S4.puts(T, first, "/behavior"))

	local n = #T.history
	action(denv, "Sync Box Settings", { What = let or "" })
	S4.until_read(c4, function() return #S4.puts(T, n, "/behavior") > 0 end)
	c4.advance(3000)
	local puts = S4.puts(T, n, "/behavior")
	eq("Let Control4 choose inputs: one PUT /behavior", 1, #puts)
	local body = puts[1] and puts[1].body or {}
	check("Let Control4 choose inputs: only what was on, turned off", body.cecPowersave == 0
		and type(body.input1) == "table" and body.input1.cecInputSwitch == 0 and body.input1.linkAutoSync == 0
		and type(body.input2) == "table" and body.input2.cecInputSwitch == 0 and body.input3 == nil
		and body.arcBypassMode == nil and body.soloMode == nil and body.usbPowersave == nil
		and body.inactivePowersave == nil and body.hpdInputSwitch == nil, puts[1] and puts[1].data)
	box_is("Let Control4 choose inputs", box, { { "behavior.cecPowersave", 0 }, { "behavior.input1.cecInputSwitch", 0 },
		{ "behavior.input1.linkAutoSync", 0 }, { "behavior.input2.cecInputSwitch", 0 }, { "behavior.inactivePowersave", 20 },
		{ "execution.mode", "video" } })
	starts("Let Control4 choose inputs: Last Action", "Sent: the box no longer does", fake.last_action(denv))
	S4.until_read(c4, function() return tostring(P(denv, "Input Switching")):find("^None") ~= nil end)
	starts("Let Control4 choose inputs: the row", "None: turned off from Control4", P(denv, "Input Switching"))
	check("Let Control4 choose inputs: no longer on Attention", not attention_shown(), P(denv, "Status"))
	local ok, err = pcall(fb.event, box, "cec_active_source", { input = 2 })
	if check("a source's CEC Active Source afterwards: the fake takes the event", ok, err) then
		c4.advance(6000)
		box_is("the box no longer switches by itself", box, { { "execution.hdmiSource", "input1" } })
	end

	-- Changed in the Hue app since: input2's CEC switching on again. A second
	-- click turns off only that, and the first record is kept.
	fb.run(box, "set", "behavior.input2.cecInputSwitch 1")
	c4.advance(6000)
	n = #T.history
	action(denv, "Sync Box Settings", { What = let or "" })
	S4.until_read(c4, function() return #S4.puts(T, n, "/behavior") > 0 end)
	c4.advance(3000)
	puts = S4.puts(T, n, "/behavior")
	body = puts[1] and puts[1].body or {}
	check("a second Let Control4 choose inputs: only input2's switching", #puts == 1 and type(body.input2) == "table"
		and body.input2.cecInputSwitch == 0 and body.input1 == nil and body.cecPowersave == nil, puts[1] and puts[1].data)

	-- Restore: exactly the first values.
	n = #T.history
	action(denv, "Sync Box Settings", { What = restore or "" })
	S4.until_read(c4, function() return #S4.puts(T, n, "/behavior") > 0 end)
	c4.advance(3000)
	box_is("Restore the box's input switching", box, { { "behavior.cecPowersave", 1 },
		{ "behavior.input1.cecInputSwitch", 1 }, { "behavior.input1.linkAutoSync", 1 },
		{ "behavior.input2.cecInputSwitch", 1 }, { "behavior.input3.cecInputSwitch", 0 } })
	starts("Restore: Last Action", "Restored the box's own", fake.last_action(denv))
	ok, err = pcall(fb.event, box, "cec_active_source", { input = 2 })
	if check("after Restore a CEC Active Source: the fake takes the event", ok, err) then
		S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.hdmiSource") == "input2" end)
		box_is("after Restore the box switches by itself again", box, { { "execution.hdmiSource", "input2" } })
	end
	n = #T.history
	action(denv, "Sync Box Settings", { What = restore or "" })
	c4.advance(3000)
	starts("Restore again: nothing to restore", "Nothing to restore", fake.last_action(denv))
	eq("Restore again: no PUT", 0, #S4.puts(T, n, "/behavior"))

	-- The wiring (design 5.8; offers.lua's wiring choices): Behind a receiver
	-- by a click, only the key that differs, Last Action saying how the
	-- connections must match; Restore the box's wiring puts it back; the
	-- input switching untouched by either.
	local function pick(prefix)
		for _, item in ipairs(type(denv.SyncBoxSettingsList) == "function" and denv.SyncBoxSettingsList() or {}) do
			if tostring(item.text):find(prefix, 1, true) == 1 then
				return item.value, item.text
			end
		end
		return nil
	end
	local behind, behind_text = pick("Set the box to Behind a receiver")
	eq("Sync Box Settings offers Behind a receiver, with its flags", "Set the box to Behind a receiver (ARC bypass on, "
		.. "solo mode off)", behind_text)
	check("Sync Box Settings does not offer the wiring the box is in", pick("Set the box to In line") == nil)
	n = #T.history
	local m = #c4.calls
	action(denv, "Sync Box Settings", { What = behind or "" })
	S4.until_read(c4, function() return P(denv, "Wiring") == require("syncbox.state").WIRING_TEXTS.behind_receiver end)
	puts = S4.puts(T, n, "/behavior")
	check("Behind a receiver: one PUT /behavior with arcBypassMode 1 only", #puts == 1 and puts[1].body.arcBypassMode == 1
		and next(puts[1].body, next(puts[1].body)) == nil, puts[1] and puts[1].data)
	box_is("Behind a receiver", box, { { "behavior.arcBypassMode", 1 }, { "behavior.soloMode", 0 },
		{ "behavior.input1.cecInputSwitch", 1 } })
	-- The text continues on Last Action (2) and on: the whole of it is in the
	-- driver's log line.
	local whole
	for _, line in ipairs(log_lines) do
		if line:find("Sent: the box is now Behind a receiver", 1, true) then
			whole = line
		end
	end
	check("Behind a receiver: Last Action says so", said(c4, m, "^Sent: the box is now Behind a receiver") ~= nil,
		fake.last_action(denv))
	check("Behind a receiver: and how the connections must match", whole ~= nil and whole:find("connect the "
		.. "receiver's HDMI output to the box's HDMI 1 and the box's HDMI Out to the TV", 1, true) ~= nil, whole)
	check("Restore the box's wiring is offered", pick("Restore the box's wiring") ~= nil)
	n, m = #T.history, #c4.calls
	action(denv, "Sync Box Settings", { What = pick("Restore the box's wiring") or "" })
	S4.until_read(c4, function() return P(denv, "Wiring") == require("syncbox.state").WIRING_TEXTS.in_line end)
	box_is("Restore the box's wiring", box, { { "behavior.arcBypassMode", 0 }, { "behavior.soloMode", 0 },
		{ "behavior.input1.cecInputSwitch", 1 } })
	check("Restore the box's wiring: Last Action", said(c4, m, "^Restored the box's wiring") ~= nil,
		fake.last_action(denv))
	eq("Restore the box's wiring: one PUT /behavior", 1, #S4.puts(T, n, "/behavior"))

	local other = S4.other_writes(T, first, { ["/api/v1/execution"] = true, ["/api/v1/behavior"] = true })
	check("offers: no write but PUT /behavior and /execution", #other == 0, table.concat(other, ", "))
	T:close()
end)

-- The entertainment area (C1.4, C1.6; design 8) and the name both ways
-- (O14; 1.2's D6).
suite("area-name", function()
	local box = CFG.routing.area
	if not box then
		return skip("area and name", "E2E_ROUTING has no area box")
	end
	local T, denv, c4 = S4.start(box, "area and name", { clock = S4.at(12, 0) })
	if not T then
		return
	end
	local first = #T.history
	-- The list and the value.
	S4.until_read(c4, function() return P(denv, "Entertainment Area") == "Living Room TV" end)
	eq("Entertainment Area shows the box's area", "Living Room TV", P(denv, "Entertainment Area"))
	local list = S4.list(c4, "Entertainment Area")
	local text = table.concat(list, "|")
	check("Entertainment Area lists the box's areas", text:find("Living Room TV", 1, true) ~= nil
		and text:find("Office", 1, true) ~= nil, text)
	-- A pick writes hueTarget, once.
	local n, e = #T.history, #c4.events_fired
	set_property(denv, "Entertainment Area", "Office")
	S4.until_read(c4, function() return S4.var(c4, "ENTERTAINMENT_AREA") == "Office" end)
	box_is("Entertainment Area Office", box, { { "execution.hueTarget", S4.AREA.office } })
	eq("Entertainment Area Office: Last Action", "Entertainment area set to Office", fake.last_action(denv))
	eq("Entertainment Area Office: one PUT", 1, #S4.puts(T, n, "/execution"))
	eq("Entertainment Area Changed fired", 1, S4.fired(c4, e, S4.EVENTS.area))
	-- Renamed in the Hue app: followed by id, nothing written.
	n = #T.history
	fb.run(box, "set", "hue.groups." .. S4.AREA.office .. ".name " .. q('"Study"'))
	S4.until_read(c4, function() return S4.var(c4, "ENTERTAINMENT_AREA") == "Study" end)
	eq("the area renamed in Hue: the row follows", "Study", P(denv, "Entertainment Area"))
	eq("the area renamed in Hue: nothing written", 0, #writes(T, n))
	-- Deleted in Hue and made again under the same name with a new id: said,
	-- offered once, never applied by itself; picking it re-points.
	local successor = "6a7b8c9d-0000-4000-8000-0000000ea0f3"
	n = #T.history
	fb.run(box, "set", "hue.groups." .. successor .. " " .. q('{"active": false, "name": "Study", "numLights": 3}'))
	fb.run(box, "set", "hue.groups." .. S4.AREA.office .. " --unset")
	fb.run(box, "set", "hue.connectionState invalidgroup")
	S4.until_read(c4, function() return tostring(fake.last_action(denv)):find("Study", 1, true) ~= nil end, 30000)
	check("the area deleted in Hue: Last Action names it", tostring(fake.last_action(denv)):find("Study", 1, true) ~= nil,
		fake.last_action(denv))
	c4.advance(MINUTE)
	box_is("the area deleted in Hue: never replaced by itself", box, { { "execution.hueTarget", S4.AREA.office } })
	eq("the area deleted in Hue: nothing written", 0, #writes(T, n))
	list = S4.list(c4, "Entertainment Area")
	local offered
	for _, item in ipairs(list) do
		if item:find("Study", 1, true) and item ~= P(denv, "Entertainment Area") then
			offered = item
		end
	end
	check("the successor is in the list", offered ~= nil, table.concat(list, "|") .. " / now " .. tostring(P(denv,
		"Entertainment Area")))
	set_property(denv, "Entertainment Area", offered or "Study")
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.hueTarget") == successor end)
	box_is("picking the successor", box, { { "execution.hueTarget", successor } })

	-- The name: renamed in the Hue Sync app -> the device follows.
	local proxy = box_proxy()
	local r = #(c4.renamed or {})
	n = #T.history
	local ok, err = pcall(fb.event, box, "rename", { name = "Den Sync Box" })
	if check("renamed in the Hue Sync app: the fake takes the event", ok, err) then
		S4.until_read(c4, function() return #(c4.renamed or {}) > r end, 30000)
		local last = (c4.renamed or {})[#(c4.renamed or {})] or {}
		eq("renamed in the Hue Sync app: RenameDevice of the AV proxy", proxy, last.id)
		eq("renamed in the Hue Sync app: the new name", "Den Sync Box", last.name)
		c4.advance(10000)
		eq("renamed in the Hue Sync app: its echo writes nothing back", 0, #S4.puts(T, n, "/device"))
	end
	-- Renamed in Composer -> the box follows.
	n = #T.history
	fake.project.devices[proxy].name = "Theater Sync Box"
	if type(denv.OnSystemEvent) == "function" then
		-- The payload is not documented; the bridge reads the event's name and
		-- an iditem from it (src/hue_bridge/driver.lua, OnSystemEvent).
		denv.OnSystemEvent(string.format("<OnItemNameChanged><iditem>%d</iditem><name>Theater Sync Box</name>"
			.. "</OnItemNameChanged>", proxy))
	end
	S4.until_read(c4, function() return lookup_path(fb.state(box), "device.name") == "Theater Sync Box" end, 30000)
	c4.advance(2000) -- the PUT's answer delivered
	box_is("renamed in Composer: the box follows", box, { { "device.name", "Theater Sync Box" } })
	local puts = S4.puts(T, n, "/device")
	eq("renamed in Composer: one PUT /device", 1, #puts)
	check("renamed in Composer: the PUT names only the name", puts[1] ~= nil and puts[1].body.name == "Theater Sync Box"
		and next(puts[1].body, next(puts[1].body)) == nil, puts[1] and puts[1].data)
	r = #(c4.renamed or {})
	c4.advance(15000)
	eq("renamed in Composer: no rename of the device comes back", r, #(c4.renamed or {}))
	local other = S4.other_writes(T, first, { ["/api/v1/execution"] = true, ["/api/v1/device"] = true })
	check("area and name: no write but PUT /execution and /device", #other == 0, table.concat(other, ", "))
	T:close()
end)

-- Take-over (O12; C5 STOP_AREA; research W10): a sync start refused with
-- code 16 while another app streams to the area asks the bridge to stop
-- it; once the bridge did, the box starts its own and Sync Taken Over fires;
-- when the stream is another box of this project, nothing is taken; with no
-- bridge bound, Last Action says the box is busy.
suite("takeover", function()
	local box = CFG.routing.takeover
	if not box then
		return skip("take-over", "E2E_ROUTING has no takeover box")
	end
	local mode = "stop"
	local peer
	peer = S4.bridge_peer(function(params)
		if mode == "stop" then
			-- The bridge stops the other app's stream on the area with its own
			-- key (C6): the fake's other app goes (SB93), then STOPPED.
			pcall(fb.event, box, "bridge", { state = "connected" })
			return { area_id = params.area_id, ok = "true", reason = "stopped" }
		elseif mode == "another_box" then
			return { area_id = params.area_id, ok = "false", reason = "another_box", by = "Den Sync Box" }
		end
		return nil
	end)
	local T, denv, c4 = S4.start(box, "take-over", { clock = S4.at(12, 0), project = peer.project })
	if not T then
		return
	end
	peer.attach(c4, denv)
	c4.advance(6000)
	local hello = peer.last("HUE_SYNCBOX_HELLO") or {}
	-- The hello went before attach; the next read's STATE or hello comes after.
	S4.command(denv, "Stop Sync", {})
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.mode") == "passthrough" end)
	c4.advance(6000)
	local state_msg = peer.last("HUE_SYNCBOX_STATE") or peer.last("HUE_SYNCBOX_HELLO") or hello
	eq("the bridge hears the box no longer syncs (syncing false)", "false", state_msg.syncing)

	-- Another app streams to the box's area; Start Sync is refused with 16;
	-- the bridge is asked to stop the area's stream; the box syncs; Sync Taken
	-- Over fires after the variables.
	fb.event(box, "bridge", { state = "busy" })
	c4.advance(6000)
	local n, m, e = #T.history, #c4.calls, #c4.events_fired
	local asked = peer.count("HUE_SYNCBOX_STOP_AREA")
	S4.command(denv, "Start Sync", {})
	local taken = until_(c4, function() return S4.fired(c4, e, S4.EVENTS.taken_over) > 0 end, 30000, 500)
	local refused = 0
	for _, p in ipairs(S4.puts(T, n, "/execution")) do
		refused = refused + (p.status == 400 and 1 or 0)
	end
	eq("another app streams: the first sync start was refused (HTTP 400, code 16)", 1, refused)
	eq("STOP_AREA sent to the bridge once", asked + 1, peer.count("HUE_SYNCBOX_STOP_AREA"))
	local stop = peer.last("HUE_SYNCBOX_STOP_AREA") or {}
	eq("STOP_AREA names the box's area", S4.AREA.tv, stop.area_id)
	eq("STOP_AREA names the box", box.id, tostring(stop.box_id or ""):upper())
	check("Sync Taken Over fired", taken, S4.events_text(c4, e))
	box_is("taken over", box, { { "execution.syncActive", true }, { "hue.connectionState", "streaming" },
		{ "hue.groups." .. S4.AREA.tv .. ".active", true } })
	check("taken over: the area no longer the other app's", lookup_path(fb.state(box), "hue.groups." .. S4.AREA.tv
		.. ".owner") == nil)
	starts("taken over: Last Action", "Sync taken over:", fake.last_action(denv))
	local fine, why = S4.set_before(c4, m, "SYNC_ACTIVE", S4.EVENTS.taken_over)
	check("taken over: SYNC_ACTIVE set before Sync Taken Over", fine, why)
	eq("taken over: Sync Started fired too", 1, S4.fired(c4, e, S4.EVENTS.sync_started))
	eq("taken over: Sync Taken Over fired once", 1, S4.fired(c4, e, S4.EVENTS.taken_over))

	-- W10: the stream is another box of this project. Nothing is taken.
	S4.command(denv, "Stop Sync", {})
	S4.until_read(c4, function() return lookup_path(fb.state(box), "execution.syncActive") == false end)
	fb.event(box, "bridge", { state = "busy" })
	c4.advance(6000)
	mode = "another_box"
	n, e = #T.history, #c4.events_fired
	S4.command(denv, "Start Sync", {})
	S4.until_read(c4, function() return tostring(fake.last_action(denv)):find("Den Sync Box", 1, true) ~= nil end, 30000)
	starts("another box of this project streams: Last Action", "Not syncing: Den Sync Box syncs to",
		fake.last_action(denv))
	c4.advance(20000)
	eq("another box streams: one sync start, refused, never again", 1, #S4.puts(T, n, "/execution"))
	eq("another box streams: no Sync Taken Over", 0, S4.fired(c4, e, S4.EVENTS.taken_over))
	box_is("another box streams: nothing taken", box, { { "execution.syncActive", false },
		{ "hue.groups." .. S4.AREA.tv .. ".owner", "other-app" } })

	-- No bridge bound: the box is busy, said so; nothing is asked.
	for i = #c4.bindings, 1, -1 do
		if c4.bindings[i].consumer == BOX_DEVICE and c4.bindings[i].consumer_binding == 1 then
			table.remove(c4.bindings, i)
		end
	end
	if type(denv.OnBindingChanged) == "function" then
		denv.OnBindingChanged(1, "HUE_SYNCBOX", false, S4.BRIDGE)
	end
	c4.advance(2000)
	asked = peer.count("HUE_SYNCBOX_STOP_AREA")
	S4.command(denv, "Start Sync", {})
	S4.until_read(c4, function() return tostring(fake.last_action(denv)):find("busy", 1, true) ~= nil end, 30000)
	starts("no bridge bound: Last Action says the box is busy", "Not syncing:", fake.last_action(denv))
	check("no bridge bound: the busy reason", tostring(fake.last_action(denv)):find("busy", 1, true) ~= nil,
		fake.last_action(denv))
	eq("no bridge bound: no STOP_AREA", asked, peer.count("HUE_SYNCBOX_STOP_AREA"))
	pcall(fb.event, box, "bridge", { state = "connected" })
	T:close()
end)

-- Run ------------------------------------------------------------------------------------------

for _, name in ipairs(order) do
	if wanted(name) then
		suite_name = name
		local ok, err = pcall(suites[name])
		if not ok then
			check("ran to its end", false, err)
			say("  last log lines:")
			for i = math.max(1, #log_lines - 15), #log_lines do
				say("    %s", log_lines[i])
			end
		end
	end
end

-- F3's hook outlives a harness run: the fake runtime's own handling again.
if type(fake.set_url_transport) == "function" then
	fake.set_url_transport(nil)
end
if log_out then
	log_out:close()
end
say("e2e: %d passed, %d failed, %d skipped", counts.pass, counts.fail, counts.skip)
os.exit(counts.fail > 0 and 1 or 0)
