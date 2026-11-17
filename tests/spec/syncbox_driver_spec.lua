-- The Hue Sync Box driver (src/hue_syncbox/driver.lua and driver.xml) against
-- the fake runtime and the fake box (tests/helpers/fake_c4.lua, fake.syncbox;
-- tests/fixtures/hue_syncbox.lua), with a Hue Bridge driver standing behind
-- binding 1 as device 15 when bound. The contract is
-- docs/hdmi-sync-stage2-design.md §4 and §5 (S2), contracts C1 to C3 and C5
-- of docs/hdmi-sync-contracts.md, and the B and C rows of
-- docs/edge-cases-syncbox.md (EC). The modules each have their own spec;
-- this one drives them through the driver, as Director and the owner would.
-- Placeholders only: box 0A1B2C3D4E5F at 10.0.2.150, another id 0A1B2C3D4E60,
-- another address 192.0.2.41, bridge 001788fffe123abc, token TEST-TOKEN-NOT-REAL.

-- .busted's lpath does not name the box's tree (yet): its modules are syncbox.*.
if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

-- The release build's cases: tools/build.sh deletes syncbox/devhooks.lua
-- from every release stage (#547, docs/fakebox-design.md §7), so it is kept
-- out here, as it would be missing on the controller; the dev build's cases,
-- with it, are in the describe "a dev build's syncbox/devhooks.lua" below.
package.loaded["syncbox.devhooks"] = nil
package.preload["syncbox.devhooks"] = function()
	error("module 'syncbox.devhooks' not found (a release build)", 0)
end

local fake = require("helpers.fake_c4")
local log = require("common.log")
local F = require("fixtures.hue_syncbox")

local BOX_DEVICE = 2301
local BRIDGE = 15
local OTHER_ID = "0A1B2C3D4E60"
local MOVED_TO = "192.0.2.41"
local SHORT = "#4E5F"
local NOT_YET = "Not done: the Hue Sync buttons come in a later 2.0 beta"
local HOUR = 3600000
-- The rows a good read fills (driver.lua K.BOX_ROWS, Box ID excepted).
local BOX_ROWS = { "Sync Box", "Model", "Firmware", "Wiring", "Sync", "Inputs", "Bridge Link", "Input Switching" }

-- The store's persisted names (syncbox/store.lua's NAMES), as a box paired
-- in an earlier life left them.
local PAIRED = {
	syncbox_token = F.TOKEN,
	syncbox_registration_id = F.REGISTRATION_ID,
	syncbox_box_id = F.BOX_ID,
	syncbox_address = F.ADDRESS,
}

local lines

local function capture()
	lines = {}
	log.sink = function(line) lines[#lines + 1] = line end
end

local function logged(text)
	for _, line in ipairs(lines) do
		if line:find(text, 1, true) then return line end
	end
	return nil
end

-- opts.persist: the store before the start; opts.box: fake.syncbox's opts
-- (false: no box at all); opts.silent: the box does not answer; opts.bind:
-- bound to the bridge; opts.debug: Debug Mode On from the start;
-- opts.before_late(env, c4): just before OnDriverLateInit. Returns env, c4,
-- the box handle.
local function load_box(opts)
	opts = opts or {}
	local props = {}
	if opts.debug then props["Debug Mode"] = "On" end
	local env, c4 = fake.load_driver("hue_syncbox", props, { device_id = BOX_DEVICE })
	for k, v in pairs(opts.persist or {}) do c4.persist[k] = v end
	local box = nil
	if opts.box ~= false then
		box = fake.syncbox(opts.box or {})
		if opts.silent then box:silence(true) end
	end
	env.OnDriverInit("DIT_STARTUP")
	if opts.bind then
		c4:Bind(BRIDGE, 2, BOX_DEVICE, 1, "HUE_SYNCBOX")
	end
	if opts.before_late then opts.before_late(env, c4) end
	env.OnDriverLateInit("DIT_STARTUP")
	return env, c4, box
end

-- A box paired in an earlier life, answering with `state` (default HSB2).
local function paired(state, extra)
	local opts = { persist = PAIRED,
		box = { state = state or F.state.HSB2, registrations = { [F.REGISTRATION_ID] = F.TOKEN } } }
	for k, v in pairs(extra or {}) do opts[k] = v end
	return load_box(opts)
end

-- Stage 3's helpers ----------------------------------------------------------

-- What the driver told the AV switch proxy: the params of each notify named
-- `command`, in order.
local function notifies(c4, command)
	local out = {}
	for _, call in ipairs(c4.calls_to("SendToProxy")) do
		if call[1] == 5001 and call[2] == command then out[#out + 1] = call[3] end
	end
	return out
end

local function puts(box)
	return box:requests_of("PUT", "/execution")
end

local function ex(box)
	return box.state.execution
end

-- Composer's Set on a property row.
local function set_property(env, name, value)
	env.Properties[name] = value
	env.OnPropertyChanged(name)
end

-- A box paired in an earlier life, in power save on HDMI 1, its first reads
-- done; c4.calls emptied.
local function asleep(state, extra)
	local s = F.copy(state or F.state.HSB2)
	s.execution.mode, s.execution.syncActive, s.execution.hdmiActive = "powersave", false, false
	local env, c4, box = paired(s, extra)
	c4.advance(1000)
	c4.calls = {}
	return env, c4, box
end

-- The dev loop's reload (common/devloop.lua), as the reload spec at the end
-- runs it: OnDriverDestroyed, the driver's modules forgotten, driver.lua
-- again, both inits with DIT_UPDATING. Director's PersistData stays.
local function reload(env)
	env.OnDriverDestroyed()
	for name in pairs(package.loaded) do
		if (name:match("^syncbox%.") or name:match("^common%.")) and name ~= "common.log"
			and name ~= "common.devloop" then
			package.loaded[name] = nil
		end
	end
	local chunk = assert(loadfile("src/hue_syncbox/driver.lua"))
	setfenv(chunk, env)
	chunk()
	env.OnDriverInit("DIT_UPDATING")
	env.OnDriverLateInit("DIT_UPDATING")
end

local function action(env, name, params)
	local p = { ACTION = name }
	for k, v in pairs(params or {}) do p[k] = v end
	env.ExecuteCommand("LUA_ACTION", p)
end

local function pair(env, c4, box, address)
	action(env, "Pair Sync Box", { Box = "address", Address = address or F.ADDRESS })
	c4.advance(2000)
	box:hold_button()
	c4.advance(2000)
end

-- What the driver sent the bridge (C5): { command, params } in order. A
-- driver run from src/ has the dev loop, which forwards log lines as HUE_LOG
-- (common/devloop.lua); those are left out.
local function to_bridge(c4)
	local out = {}
	for _, m in ipairs(c4.sent) do
		if m.id == BRIDGE and m.command:find("^HUE_SYNCBOX_") then out[#out + 1] = { m.command, m.params } end
	end
	return out
end

local function keyed(box)
	local n = 0
	for _, r in ipairs(box.requests) do
		if r.keyed then n = n + 1 end
	end
	return n
end

-- An mDNS answer for _huesync._tcp.local (RFC 1035 §4.1, RFC 6763; the
-- shape syncbox_discovery_spec.lua answers with): a PTR to the box's
-- instance, its SRV on 443 (or `port`: the VM's fake box, #547), its TXT
-- (name, devicetype, uniqueid) and its A record, names written out in full.
local function mdns_answer(query_id, id, ip, port)
	local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
	local function name(n)
		local out = {}
		for label in n:gmatch("[^%.]+") do out[#out + 1] = string.char(#label) .. label end
		return table.concat(out) .. "\0"
	end
	local function record(owner, rtype, data)
		return name(owner) .. u16(rtype) .. u16(1) .. u16(0) .. u16(120) .. u16(#data) .. data
	end
	local service, instance, host = "_huesync._tcp.local", "HueSyncBox-" .. id .. "._huesync._tcp.local", id .. ".local"
	local txt = ""
	for _, item in ipairs({ "name=Living Room Sync Box", "devicetype=HSB2", "uniqueid=" .. id, "path=/api" }) do
		txt = txt .. string.char(#item) .. item
	end
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	return u16(query_id) .. u16(0x8400) .. u16(1) .. u16(1) .. u16(0) .. u16(3)
		.. name(service) .. u16(12) .. u16(1)
		.. record(service, 12, name(instance))
		.. record(instance, 33, u16(0) .. u16(0) .. u16(port or 443) .. name(host))
		.. record(instance, 16, txt)
		.. record(host, 1, string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d)))
end

-- The LAN answers every mDNS query the driver sends with `id` at `ip`
-- (its SRV on `srv_port`, 443 by default).
local function lan_answers(env, c4, id, ip, srv_port)
	local original = c4.SendToNetwork
	c4.SendToNetwork = function(self, binding, port, data)
		original(self, binding, port, data)
		local qid = data:byte(1) * 256 + data:byte(2)
		c4:SetTimer(1, function()
			env.ReceivedFromNetwork(binding, port, mdns_answer(qid, id, ip, srv_port))
		end)
	end
end

describe("Hue Sync Box driver (#534)", function()
	before_each(function()
		capture()
		log.set_debug(false)
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("driver.xml (contracts C1)", function()
		local function xml()
			local file = assert(io.open("src/hue_syncbox/driver.xml"))
			local text = file:read("*a")
			file:close()
			return (text:gsub("<!%-%-.-%-%->", ""))
		end

		local function field(body, tag)
			return body and body:match("<" .. tag .. ">(.-)</" .. tag .. ">")
		end

		local function each(body, tag)
			local out = {}
			for inner in (body or ""):gmatch("<" .. tag .. ">(.-)</" .. tag .. ">") do out[#out + 1] = inner end
			return out
		end

		it("has the basics of C1", function()
			local x = xml()
			assert.equal("Hue Sync Box", field(x, "name"))
			assert.equal("Philips Hue", field(x, "manufacturer"))
			assert.equal("Hue Play HDMI Sync Box (local API)", field(x, "model"))
			assert.equal("lua_gen", field(x, "control"))
			assert.equal("IP", field(x, "controlmethod"))
			assert.equal("3.3.0", field(x, "minimum_os_version"))
			assert.truthy(x:find('<script jit="1" file="driver.lua"/>', 1, true))
			assert.equal("www/documentation.html", x:match('<documentation file="([^"]+)"'))
			assert.equal("images/devices_sm/hue_syncbox_16.png", x:match('<small image_source="c4z">(.-)</small>'))
			assert.equal("images/devices_lg/hue_syncbox_32.png", x:match('<large image_source="c4z">(.-)</large>'))
			assert.is_nil(x:find("<combo", 1, true))
		end)

		it("declares the five proxies of C1.1, the AV switch first and primary", function()
			local proxies = {}
			for attrs, name in xml():gmatch("<proxy%s([^>]*)>(.-)</proxy>") do
				proxies[#proxies + 1] = { attrs:match('proxybindingid="(%d+)"'), attrs:match('name="([^"]+)"'), name,
					attrs:find('primary="True"', 1, true) ~= nil }
			end
			assert.same({
				{ "5001", "Hue Sync Box", "avswitch", true },
				{ "5002", "Hue Sync", "uibutton", false },
				{ "5003", "Sync Brighter", "uibutton", false },
				{ "5004", "Sync Dimmer", "uibutton", false },
				{ "5005", "Sync Intensity", "uibutton", false },
			}, proxies)
		end)

		it("has the connections of C1.2 and the proxy bindings, and no room or Power Manager binding", function()
			local connections = {}
			for attrs, body in xml():gmatch("<connection([^>]*)>(.-)</connection>") do
				connections[#connections + 1] = table.concat({ field(body, "id"), field(body, "type"),
					field(body, "connectionname"), field(body, "consumer"), field(body, "classname"),
					attrs:match('proxybindingid="(%d+)"') or "-" }, " | ")
			end
			assert.same({
				"5001 | 2 | Hue Sync Box | False | AVSWITCH | -",
				"5002 | 2 | Hue Sync | False | UIBUTTON | -",
				"5003 | 2 | Sync Brighter | False | UIBUTTON | -",
				"5004 | 2 | Sync Dimmer | False | UIBUTTON | -",
				"5005 | 2 | Sync Intensity | False | UIBUTTON | -",
				"1000 | 5 | HDMI 1 | True | HDMI | 5001",
				"1001 | 5 | HDMI 2 | True | HDMI | 5001",
				"1002 | 5 | HDMI 3 | True | HDMI | 5001",
				"1003 | 5 | HDMI 4 | True | HDMI | 5001",
				"2000 | 5 | HDMI Out | False | HDMI | 5001",
				"3000 | 6 | HDMI 1 | True | HDMI | 5001",
				"3001 | 6 | HDMI 2 | True | HDMI | 5001",
				"3002 | 6 | HDMI 3 | True | HDMI | 5001",
				"3003 | 6 | HDMI 4 | True | HDMI | 5001",
				"4000 | 6 | HDMI Out | False | HDMI | 5001",
				"1 | 1 | Hue Bridge | True | HUE_SYNCBOX | -",
			}, connections)
			-- #531: no room binding (type 7, ids 7000-7999) and no Power Manager (8000-8999).
			for _, body in ipairs(each(xml(), "connection")) do
				local id = tonumber(field(body, "id"))
				assert.is_not.equal("7", field(body, "type"))
				assert.is_false(id >= 7000 and id <= 8999, "binding " .. id)
			end
		end)

		it("has exactly the capabilities of C1.3", function()
			local caps = {}
			for name, value in field(xml(), "capabilities"):gmatch("<([%w_]+)>(.-)</%1>") do caps[name] = value end
			assert.same({
				video_consumer_count = "4", video_provider_count = "1",
				audio_consumer_count = "4", audio_provider_count = "1",
				can_switch = "True", has_discrete_input_select = "True",
				can_switch_separately = "False", requires_separate_switching = "False",
				can_upclass = "False", can_downclass = "False",
				has_discrete_volume_control = "False", has_up_down_volume_control = "False",
				has_discrete_mute_control = "False", has_toggle_mute_control = "False",
				has_discrete_bass_control = "False", has_up_down_bass_control = "False",
				has_discrete_treble_control = "False", has_up_down_treble_control = "False",
				has_discrete_balance_control = "False", has_up_down_balance_control = "False",
				has_discrete_loudness_control = "False",
				has_audio_signal_sense = "False", has_video_signal_sense = "False",
			}, caps)
		end)

		it("declares the stage 2 rows in S2 §5's order, then stage 3's settings, all read-only but the settings",
			function()
			local names, writable = {}, {}
			for _, body in ipairs(each(xml(), "property")) do
				names[#names + 1] = field(body, "name")
				if field(body, "readonly") == "false" then writable[#writable + 1] = field(body, "name") end
			end
			assert.same({ "Driver Version", "Debug Mode", "Status", "Online", "Last Action", "Last Action (2)",
				"Last Action (3)", "Last Action (4)", "Last Action (5)", "Last Action (6)", "Sync Box", "Model", "Firmware",
				"Box ID", "Box Address", "Wiring", "Sync", "Inputs", "Bridge Link", "Input Switching",
				"HDMI 1 Sync Mode", "HDMI 2 Sync Mode", "HDMI 3 Sync Mode", "HDMI 4 Sync Mode", "Follow Room",
				"Source Sync Modes", "At Room Off", "When The Source Leaves The Box" }, names)
			assert.same({ "Debug Mode", "HDMI 1 Sync Mode", "HDMI 2 Sync Mode", "HDMI 3 Sync Mode", "HDMI 4 Sync Mode",
				"Follow Room", "At Room Off", "When The Source Leaves The Box" }, writable)
		end)

		it("declares the settings of contracts C1.4 and research §7.2 with their items and defaults (S3 §5)", function()
			local props = {}
			for _, body in ipairs(each(xml(), "property")) do
				props[field(body, "name")] = { type = field(body, "type"), items = table.concat(each(body, "item"), "/"),
					default = field(body, "default") }
			end
			for n = 1, 4 do
				assert.same({ type = "LIST", items = "Automatic/Video/Game/Music/Do not sync", default = "Automatic" },
					props["HDMI " .. n .. " Sync Mode"])
			end
			assert.same({ type = "LIST", items = "Power save/Stop syncing and keep the picture", default = "Power save" },
				props["At Room Off"])
			assert.same({ type = "LIST", items = "Stop syncing and keep the picture/Power save",
				default = "Stop syncing and keep the picture" }, props["When The Source Leaves The Box"])
			assert.same({ type = "DYNAMIC_LIST", items = "" }, props["Follow Room"])
			assert.equal("STRING", props["Source Sync Modes"].type)
		end)

		it("offers Pair Sync Box, Set Source Sync Mode, Diagnostics and Forget Pairing, nothing for programming yet",
			function()
			local actions = {}
			for _, body in ipairs(each(xml(), "action")) do
				local params = {}
				for _, p in ipairs(each(body, "param")) do
					params[#params + 1] = field(p, "name") .. ":" .. field(p, "type") .. ":" .. table.concat(each(p, "item"), "/")
				end
				actions[#actions + 1] = field(body, "command") .. " (" .. table.concat(params, ", ") .. ")"
			end
			assert.same({
				"Pair Sync Box (Box:CUSTOM_SELECT:SyncBoxList:, Address:STRING:)",
				"Set Source Sync Mode (Source:CUSTOM_SELECT:SourceList:, Mode:LIST:Automatic/Video/Game/Music/Do not sync)",
				"Diagnostics (What:LIST:Check the box now/Read everything from the box now/"
					.. "Show the box's raw state in the Lua output)",
				"Forget Pairing (Confirm:LIST:No/Yes)",
			}, actions)
			local x = xml()
			assert.truthy(x:find("<commands/>", 1, true))
			assert.is_nil(x:find("<commands>", 1, true))
			assert.is_nil(x:find("<events>", 1, true))
			assert.is_nil(x:find("<conditionals>", 1, true))
		end)
	end)

	describe("a new device (S2 §5)", function()
		it("loads from Composer's driver search, unpaired and unbound, and says so", function()
			local env, c4, box = load_box()
			assert.equal("Not paired: run Pair Sync Box", env.Properties["Status"])
			assert.equal("1", env.Properties["Driver Version"])
			assert.equal("", env.Properties["Box ID"])
			assert.same({}, box.requests, "nothing goes to a box before Pair Sync Box")
			assert.same({}, c4.calls_to("SendToProxy"))
			assert.same({}, to_bridge(c4))
		end)

		it("searches the network at first load and every hour while unpaired (S2 §3.7)", function()
			local _, c4 = load_box({ box = false })
			local connects = function()
				local port = c4.network[6008] and c4.network[6008].ports[5353]
				return port and port.connects or 0
			end
			assert.equal(1, connects(), "the first search")
			c4.advance(HOUR)
			assert.equal(2, connects(), "the hourly search")
		end)

		it("lists a box the search found once its identity answered, and counts it in Status", function()
			local env, c4 = load_box({ box = false })
			local box = fake.syncbox({ state = F.state.HSB2 })
			lan_answers(env, c4, F.BOX_ID, F.ADDRESS)
			action(env, "Pair Sync Box", {})
			assert.truthy(fake.last_action(env):find("searching the network", 1, true))
			c4.advance(20000)
			assert.equal("Not paired: 1 Hue sync box found (run Pair Sync Box)", env.Properties["Status"])
			local list = fake.custom_select(env, "SyncBoxList")
			assert.same({ text = "Hue Sync Box (8K) " .. SHORT .. ", Living Room Sync Box, " .. F.ADDRESS,
				value = "box:" .. F.BOX_ID }, list[1])
			assert.same({ text = "Type an address (under Address)", value = "address" }, list[#list])
			assert.equal(0, keyed(box), "a candidate gets no token")
			-- Picked from the list, it pairs.
			action(env, "Pair Sync Box", { Box = "box:" .. F.BOX_ID })
			c4.advance(2000)
			box:hold_button()
			c4.advance(2000)
			assert.equal("Paired with Hue Sync Box (8K) " .. SHORT .. " at " .. F.ADDRESS, fake.last_action(env))
		end)
	end)

	describe("Pair Sync Box (S2 §4)", function()
		it("checks the box, counts the window down every 10 s, then pairs, fills the rows and polls", function()
			local env, c4, box = load_box({ bind = true })
			action(env, "Pair Sync Box", { Box = "address", Address = F.ADDRESS })
			assert.equal("Hold the button on the sync box for 3 seconds (2:00 left)", fake.last_action(env))
			assert.equal("Hold the button on the sync box for 3 seconds (2:00 left)", env.Properties["Status"])
			c4.advance(10000)
			assert.equal("Hold the button on the sync box for 3 seconds (1:50 left)", env.Properties["Status"])
			assert.equal("Hold the button on the sync box for 3 seconds (2:00 left)", fake.last_action(env),
				"Last Action says it once")
			box:hold_button()
			c4.advance(1000)
			assert.equal("Paired with Hue Sync Box (8K) " .. SHORT .. " at " .. F.ADDRESS, fake.last_action(env))
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
			assert.equal("Living Room Sync Box", env.Properties["Sync Box"])
			assert.equal("Hue Play HDMI Sync Box 8K (HSB2)", env.Properties["Model"])
			assert.equal("2.5.4 (API level 14)", env.Properties["Firmware"])
			assert.equal(F.BOX_ID, env.Properties["Box ID"])
			assert.equal(F.ADDRESS, env.Properties["Box Address"])
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Sync"])
			assert.equal("1 Apple TV (on), 2 PlayStation, 3 HDMI 3, 4 HDMI 4", env.Properties["Inputs"])
			assert.equal("Hue Bridge 001788fffe123abc, streaming", env.Properties["Bridge Link"])
			assert.equal("By the box: HDMI CEC; auto-sync on HDMI 1", env.Properties["Input Switching"])
			-- The registration names the device (EC B3) and the app (C2).
			local post = box:requests_of("POST", "/registrations")
			assert.equal("c4-hue", post[#post].json.appName)
			-- HELLO to the bound bridge with the box, its bridge and its area (C5).
			local sent = to_bridge(c4)
			assert.equal("HUE_SYNCBOX_HELLO", sent[#sent][1])
			assert.same({ device_id = tostring(BOX_DEVICE), box_id = F.BOX_ID, bridge_id = F.BRIDGE_ID,
				area_id = F.AREA.tv }, sent[#sent][2])
			-- Polling: a read every 5 s while the box is on.
			local reads = #box:requests_of("GET", "")
			c4.advance(5000)
			assert.equal(reads + 1, #box:requests_of("GET", ""))
			assert.equal(F.TOKEN, c4.persist.syncbox_token)
		end)

		-- The house's first start could not read the box id, the address or the
		-- registration id, the fields PersistGetValue was asked for with an
		-- explicit false [house, build 682, 2026-11-17, #547]. Here the runtime
		-- raises on any explicit encrypted flag but true, PersistSetValue's too.
		it("keeps the box id, address and registration across a restart after pairing, with no warnings (#547)", function()
			local function strict(c4)
				local get, set = c4.PersistGetValue, c4.PersistSetValue
				c4.PersistGetValue = function(self, name, ...)
					if select("#", ...) > 0 and (...) ~= true then error("PersistGetValue: bad argument #2", 2) end
					return get(self, name, ...)
				end
				c4.PersistSetValue = function(self, name, value, ...)
					if select("#", ...) > 0 and (...) ~= true then error("PersistSetValue: bad argument #3", 2) end
					return set(self, name, value, ...)
				end
			end
			local function start(persist, box_opts)
				local env, c4 = fake.load_driver("hue_syncbox", {}, { device_id = BOX_DEVICE })
				strict(c4)
				for k, v in pairs(persist) do c4.persist[k] = v end
				local box = fake.syncbox(box_opts)
				env.OnDriverInit("DIT_STARTUP")
				env.OnDriverLateInit("DIT_STARTUP")
				return env, c4, box
			end
			local env, c4, box = start({}, {})
			pair(env, c4, box)
			assert.equal("Paired with Hue Sync Box (8K) " .. SHORT .. " at " .. F.ADDRESS, fake.last_action(env))
			assert.same({ F.TOKEN, F.REGISTRATION_ID, F.BOX_ID, F.ADDRESS }, { c4.persist.syncbox_token,
				c4.persist.syncbox_registration_id, c4.persist.syncbox_box_id, c4.persist.syncbox_address })
			-- The restart: a new Lua state with what Director kept.
			local kept = {}
			for k, v in pairs(c4.persist) do kept[k] = v end
			env = start(kept, { registrations = { [F.REGISTRATION_ID] = F.TOKEN } })
			assert.equal(F.BOX_ID, env.Properties["Box ID"])
			assert.equal(F.ADDRESS, env.Properties["Box Address"])
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
			for _, line in ipairs(lines) do
				assert.is_nil(line:find("could not read the stored", 1, true), line)
				assert.is_nil(line:find("could not store", 1, true), line)
				assert.is_nil(line:find("is not usable", 1, true), line)
			end
		end)

		it("ends with the reason in words when the button is not held within 2 minutes", function()
			local env, c4, box = load_box()
			action(env, "Pair Sync Box", { Box = "address", Address = F.ADDRESS })
			c4.advance(121000)
			assert.equal("Not paired: the button on the sync box at " .. F.ADDRESS .. " was not held within 2 minutes; "
				.. "run Pair Sync Box again", fake.last_action(env))
			assert.equal("Not paired: run Pair Sync Box", env.Properties["Status"])
			assert.is_nil(c4.persist.syncbox_token)
			local posts = #box:requests_of("POST", "/registrations")
			c4.advance(10000)
			assert.equal(posts, #box:requests_of("POST", "/registrations"), "no POST after the window")
		end)

		it("refuses an address that is no IPv4 address, a camera, and nothing at the address", function()
			local env, c4 = load_box({ box = { device = F.device.HSC001 } })
			action(env, "Pair Sync Box", { Box = "address", Address = "10.0.2.150/x" })
			assert.equal("Not paired: 10.0.2.150/x is not an IPv4 address (four numbers, as 10.0.2.150)",
				fake.last_action(env))
			action(env, "Pair Sync Box", { Box = "address", Address = F.ADDRESS })
			c4.advance(1000)
			assert.equal("Not paired: " .. F.ADDRESS .. " is a Hue Play Screen Sync camera, not an HDMI sync box",
				fake.last_action(env))
			action(env, "Pair Sync Box", { Box = "address", Address = MOVED_TO })
			-- Nothing at that address: the transfer ends without an answer.
			for _, t in ipairs(c4.transfers) do t:done(7, "Couldn't connect to server") end
			c4.advance(1000)
			assert.equal("Not paired: nothing answers at " .. MOVED_TO, fake.last_action(env))
			assert.equal("Not paired: run Pair Sync Box", env.Properties["Status"])
		end)

		it("refuses host:port without syncbox/devhooks.lua, as a release build does (#547)", function()
			local env, _, box = load_box()
			for _, typed in ipairs({ F.ADDRESS .. ":8443", F.ADDRESS .. ":443" }) do
				action(env, "Pair Sync Box", { Box = "address", Address = typed })
				assert.equal("Not paired: " .. typed .. " is not an IPv4 address (four numbers, as 10.0.2.150)",
					fake.last_action(env))
			end
			assert.same({}, box.requests)
		end)

		it("refuses another box while one is paired (Forget Pairing first)", function()
			local other = F.copy(F.state.HSB2)
			other.device.uniqueId = OTHER_ID
			local env, c4 = paired()
			fake.syncbox({ address = MOVED_TO, state = other })
			action(env, "Pair Sync Box", { Box = "address", Address = MOVED_TO })
			c4.advance(1000)
			assert.equal("Not paired: " .. MOVED_TO .. " is Hue Sync Box (8K) #4E60, not the paired " .. SHORT
				.. "; Forget Pairing first to pair another box", fake.last_action(env))
			assert.equal(F.ADDRESS, env.Properties["Box Address"], "the paired box stays")
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
		end)

		it("keeps the token out of every log line, row and message, Debug Mode on", function()
			local env, c4, box = load_box({ bind = true, debug = true })
			pair(env, c4, box)
			c4.advance(30000)
			action(env, "Diagnostics", { What = "Show the box's raw state in the Lua output" })
			action(env, "Forget Pairing", { Confirm = "Yes" })
			c4.advance(30000)
			for _, line in ipairs(lines) do
				assert.is_nil(line:find(F.TOKEN, 1, true), line)
			end
			for _, call in ipairs(c4.calls_to("UpdateProperty")) do
				assert.is_nil(tostring(call[2]):find(F.TOKEN, 1, true), call[1])
			end
			for _, m in ipairs(c4.sent) do
				for k, v in pairs(m.params or {}) do
					assert.is_nil(tostring(v):find(F.TOKEN, 1, true), k)
				end
			end
		end)
	end)

	describe("Forget Pairing (S2 §4 step 4; EC C5)", function()
		it("asks for Yes first", function()
			local env, _, box = paired()
			action(env, "Forget Pairing", { Confirm = "No" })
			assert.equal("Forget Pairing: not confirmed (pick Yes under Confirm)", fake.last_action(env))
			assert.same({}, box:requests_of("DELETE"))
		end)

		it("deletes the registration, clears the rows but Box Address, stops polling and says goodbye", function()
			local env, c4, box = paired(nil, { bind = true })
			c4.advance(1000)
			action(env, "Forget Pairing", { Confirm = "Yes" })
			c4.advance(1000)
			assert.equal(1, #box:requests_of("DELETE", "/registrations/" .. F.REGISTRATION_ID))
			assert.equal("Forgot the pairing with Hue Sync Box (8K) " .. SHORT .. ": its registration on the box is removed",
				fake.last_action(env))
			assert.equal("Not paired: run Pair Sync Box", env.Properties["Status"])
			for _, name in ipairs({ "Sync Box", "Model", "Firmware", "Box ID", "Wiring", "Sync", "Inputs", "Bridge Link",
				"Input Switching", "Online" }) do
				assert.equal("", env.Properties[name], name)
			end
			assert.equal(F.ADDRESS, env.Properties["Box Address"])
			assert.is_nil(c4.persist.syncbox_token)
			assert.equal(F.ADDRESS, c4.persist.syncbox_address, "kept for the next Pair Sync Box")
			local sent = to_bridge(c4)
			assert.equal("HUE_SYNCBOX_GOODBYE", sent[#sent][1])
			assert.equal(F.BOX_ID, sent[#sent][2].box_id)
			local requests = #box.requests
			c4.advance(60000)
			assert.equal(requests, #box.requests, "no more reads")
		end)

		it("says the registration stays on the box when the box does not answer", function()
			local env, c4, box = paired()
			c4.advance(1000)
			box:silence(true)
			action(env, "Forget Pairing", { Confirm = "Yes" })
			c4.advance(30000)
			assert.equal("Forgot the pairing with Hue Sync Box (8K) " .. SHORT .. ": the box did not answer, so its "
				.. "registration stays on the box until removed in the Hue Sync app", fake.last_action(env))
			assert.equal("Not paired: run Pair Sync Box", env.Properties["Status"])
			-- A long Last Action continues on its second row, shown, the rest hidden.
			assert.truthy(env.Properties["Last Action (2)"] ~= "")
			assert.equal(0, c4.property_attribs["Last Action (2)"])
			assert.equal(1, c4.property_attribs["Last Action (3)"])
		end)
	end)

	describe("at start with a stored token (S2 §4 step 5)", function()
		it("checks the identity with the stored id, then polls, and says hello to the bridge", function()
			local env, c4, box = paired(nil, { bind = true })
			local device = box:requests_of("GET", "/device")
			assert.equal(1, #device)
			assert.is_false(device[1].keyed, "the identity check carries no token")
			assert.is_true(box.requests[2].keyed and box.requests[2].authorized)
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
			assert.equal(F.BOX_ID, env.Properties["Box ID"])
			local sent = to_bridge(c4)
			assert.equal("HUE_SYNCBOX_HELLO", sent[1][1])
			assert.equal(F.BOX_ID, sent[1][2].box_id)
		end)

		it("sends no token where another device answers, and says so (EC B12)", function()
			local other = F.copy(F.state.HSB2)
			other.device.uniqueId = OTHER_ID
			local env, c4, box = paired(other)
			c4.advance(60000)
			assert.equal("Another device answers at " .. F.ADDRESS .. " (expected " .. SHORT .. "); Pair Sync Box to find it",
				env.Properties["Status"])
			assert.equal(0, keyed(box))
			assert.truthy(logged("the token is not sent there"))
		end)

		it("follows the box to a new address the search finds, after the identity proved it (EC B11)", function()
			local env, c4, box = paired()
			-- A new DHCP lease: the box answers at another address, nothing at the old one.
			box:move(MOVED_TO)
			lan_answers(env, c4, F.BOX_ID, MOVED_TO)
			local before = #box.requests
			c4.advance(8 * 60000)
			assert.equal("Hue Sync Box (8K) " .. SHORT .. " moved to " .. MOVED_TO .. "; address updated",
				fake.last_action(env))
			assert.equal(MOVED_TO, env.Properties["Box Address"])
			assert.equal(MOVED_TO, c4.persist.syncbox_address)
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
			local after = 0
			for i = before + 1, #box.requests do
				if box.requests[i].keyed and box.requests[i].url:find(MOVED_TO, 1, true) then after = after + 1 end
			end
			assert.truthy(after > 0, "the reads go to the new address")
		end)
	end)

	describe("offline and back (C2, #428; EC B13)", function()
		it("goes offline after 5 minutes without an answer and online at the first good read", function()
			local env, c4, box = paired()
			box:silence(true)
			c4.advance(4 * 60000)
			assert.equal("Online", env.Properties["Online"], "under 5 minutes nothing shows")
			c4.advance(2 * 60000)
			assert.truthy(env.Properties["Online"]:match("^Offline since %d+:%d%d$"), env.Properties["Online"])
			assert.truthy(env.Properties["Status"]:match("^Offline since %d+:%d%d %(10%.0%.2%.150 does not answer%)$"),
				env.Properties["Status"])
			assert.truthy(c4.persist.syncbox_offline_since, "the outage is kept for a restart")
			box:silence(false)
			c4.advance(2 * 60000)
			assert.equal("Online", env.Properties["Online"])
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
			assert.is_nil(c4.persist.syncbox_offline_since)
		end)

		it("keeps an outage's time across a restart and reports it once (#428 D14)", function()
			local since = 1000000 - 10 * 60000
			local persist = { syncbox_offline_since = since }
			for k, v in pairs(PAIRED) do persist[k] = v end
			local env, c4, box = load_box({ persist = persist, debug = true, box = { state = F.state.HSB2,
				registrations = { [F.REGISTRATION_ID] = F.TOKEN } } })
			assert.equal("Online", env.Properties["Online"], "it answers at once: the outage is over")
			assert.is_nil(c4.persist.syncbox_offline_since)
			assert.truthy(logged("online: " .. F.ADDRESS .. " answers again"))
			assert.is_nil(logged("offline:"), "no second report of the outage")
			assert.truthy(#box:requests_of("GET", "") > 0)
		end)

		-- The house, dev 695: a reload while the box did not answer left Online
		-- and the box rows empty until it answered (C1.9: at start the values
		-- come from persisted ones; #428: Online is never empty while paired).
		it("shows Not reached since the start in Online and the last good read's rows while the box does not answer "
			.. "after a restart", function()
			local env, c4 = paired()
			c4.advance(1000)
			local before = {}
			for _, name in ipairs(BOX_ROWS) do before[name] = env.Properties[name] end
			assert.equal("Apple TV", before["Inputs"]:match("^1 (Apple TV)"))
			local kept = {}
			for k, v in pairs(c4.persist) do kept[k] = v end
			-- The restart, the box silent.
			local env2, c4b, box = load_box({ persist = kept, silent = true,
				box = { state = F.state.HSB2, registrations = { [F.REGISTRATION_ID] = F.TOKEN } } })
			assert.truthy(env2.Properties["Online"]:match("^Not reached since %d+:%d%d$"), env2.Properties["Online"])
			for _, name in ipairs(BOX_ROWS) do
				assert.equal(before[name], env2.Properties[name], name)
			end
			assert.truthy(env2.Properties["Status"]:match("^Checking the sync box at 10%.0%.2%.150"), env2.Properties["Status"])
			c4b.advance(60000)
			assert.truthy(env2.Properties["Online"]:match("^Not reached since %d+:%d%d$"), env2.Properties["Online"])
			assert.truthy(env2.Properties["Status"]:match("^Waiting for the sync box at 10%.0%.2%.150 %(no answer since "),
				env2.Properties["Status"])
			assert.equal(before["Sync"], env2.Properties["Sync"])
			c4b.advance(5 * 60000)
			assert.truthy(env2.Properties["Online"]:match("^Offline since %d+:%d%d$"), env2.Properties["Online"])
			assert.equal(before["Inputs"], env2.Properties["Inputs"], "the rows stay through the outage")
			box:silence(false)
			c4b.advance(2 * 60000)
			assert.equal("Online", env2.Properties["Online"])
			assert.equal(before["Sync"], env2.Properties["Sync"])
		end)

		it("never shows another box's persisted rows, and forgets them with the pairing", function()
			local env, c4 = paired()
			c4.advance(1000)
			assert.truthy(c4.persist.syncbox_rows, "the last good read's rows are kept")
			action(env, "Forget Pairing", { Confirm = "Yes" })
			c4.advance(1000)
			assert.is_nil(c4.persist.syncbox_rows)
			-- Rows kept for another box id are not shown for this one.
			local persist = { syncbox_rows = { box_id = OTHER_ID, rows = { Sync = "Game, intense", Inputs = "1 Other" } } }
			for k, v in pairs(PAIRED) do persist[k] = v end
			local env2 = load_box({ persist = persist, silent = true })
			assert.equal("", env2.Properties["Sync"])
			assert.equal("", env2.Properties["Inputs"])
			assert.equal(F.BOX_ID, env2.Properties["Box ID"])
		end)

		it("shows the stored outage at once while the box is still away after a restart", function()
			local persist = { syncbox_offline_since = 1000000 - 10 * 60000 }
			for k, v in pairs(PAIRED) do persist[k] = v end
			local env, c4 = load_box({ persist = persist, silent = true })
			assert.truthy(env.Properties["Online"]:match("^Offline since %d+:%d%d$"), "at once")
			c4.advance(60000)
			assert.truthy(env.Properties["Online"]:match("^Offline since %d+:%d%d$"), env.Properties["Online"])
			assert.truthy(env.Properties["Status"]:match("^Offline since "), env.Properties["Status"])
			assert.equal(1000000 - 10 * 60000, c4.persist.syncbox_offline_since)
		end)
	end)

	describe("a box that forgot the registration (EC B5)", function()
		it("says so after re-checking the identity, keeps the token, and asks again after 5 minutes", function()
			local env, c4, box = paired()
			box.registrations[F.REGISTRATION_ID] = nil
			c4.advance(5000)
			assert.truthy(env.Properties["Status"]:match("^The sync box refuses this pairing since %d+:%d%d: hold its button "
				.. "for 3 seconds, then run Pair Sync Box$"), env.Properties["Status"])
			assert.equal("Hue Sync Box (8K) " .. SHORT .. " at " .. F.ADDRESS .. " refuses this pairing (HTTP 401): hold "
				.. "its button for 3 seconds, then run Pair Sync Box", fake.last_action(env))
			assert.equal(F.TOKEN, c4.persist.syncbox_token)
			local reads = #box:requests_of("GET", "")
			c4.advance(60000)
			assert.equal(reads, #box:requests_of("GET", ""), "polling stopped")
			box.registrations[F.REGISTRATION_ID] = { token = F.TOKEN }
			c4.advance(5 * 60000)
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
		end)
	end)

	describe("the box's rows", function()
		it("refuses a standalone HSB3 in Status (O2)", function()
			local env = paired(F.state.HSB3_standalone)
			assert.equal("Not supported: this box runs without a Hue Bridge (standalone mode)", env.Properties["Status"])
			assert.equal("Hue Play HDMI Sync Box 4K (HSB3)", env.Properties["Model"])
			assert.equal("1 Game Console (on)", env.Properties["Inputs"])
		end)

		for name, wiring in pairs({
			HSB2 = "In line (sources \226\134\146 box \226\134\146 TV or receiver)",
			HSB2_behind_receiver = "Behind a receiver (ARC bypass on)",
			HSB2_second_output = "From a receiver's second output (solo mode)",
		}) do
			it("shows the wiring of " .. name .. " (O17, design 5.8)", function()
				local env = paired(F.state[name])
				assert.equal(wiring, env.Properties["Wiring"])
			end)
		end

		it("follows a change the box made by itself at the next read (EC B23)", function()
			local env, c4, box = paired()
			box.state.execution.mode = "passthrough"
			box.state.execution.syncActive = false
			c4.advance(5000)
			assert.equal("Off (passthrough)", env.Properties["Status"])
		end)
	end)

	describe("the proxies (S3 §5; #483 D-7)", function()
		it("logs every proxy command with every parameter, and answers a UI Button press Not done", function()
			local env, c4, box = paired(nil, { bind = true, debug = true })
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1001", OUTPUT = "2000", AUDIO = "False", VIDEO = "True",
				PREV_DEV_LIST = "1201,1301" })
			local line = logged("proxy 5001 SET_INPUT at ")
			assert.truthy(line)
			assert.truthy(line:find("AUDIO=False INPUT=1001 OUTPUT=2000 PREV_DEV_LIST=1201,1301 VIDEO=True", 1, true), line)
			assert.truthy(line:match(" at %d+ ms: "), line)
			c4.advance(20000)
			local requests, sent = #box.requests, #to_bridge(c4)
			c4.calls = {}
			for binding = 5002, 5005 do
				env.Properties["Last Action"] = ""
				env.ReceivedFromProxy(binding, "SELECT", { ["Device ID"] = "7", Menu = "watch" })
				assert.equal(NOT_YET, fake.last_action(env), binding)
			end
			assert.same({}, c4.calls_to("SendToProxy"), "no notify")
			assert.equal(requests, #box.requests, "nothing to the box")
			assert.equal(sent, #to_bridge(c4), "nothing to the bridge")
			assert.truthy(logged("proxy 5003 SELECT at "))
		end)

		it("takes each command only on its own binding, and notes the rest without a word", function()
			local env, c4, box = paired(nil, { debug = true })
			local before = #box:requests_of("PUT")
			env.Properties["Last Action"] = ""
			env.ReceivedFromProxy(5001, "SELECT", {})
			env.ReceivedFromProxy(5002, "SET_INPUT", { INPUT = "1001", OUTPUT = "2000", VIDEO = "True" })
			env.ReceivedFromProxy(5001, "GET_AUDIO_INPUTS", {})
			env.ReceivedFromProxy(5001, "BINDING_CHANGE_ACTION", { BINDING_ID = "1000", IS_BOUND = "True" })
			env.ReceivedFromProxy(5001, "SET_ROOM_BINDING_NAME", { OUTPUT = "2000", PartnerDevice = "7" })
			env.ReceivedFromProxy(5001, "CONNECT_OUTPUT", { OUTPUT = "2000", VIDEO = "True" })
			env.ReceivedFromProxy(5001, "PULSE_VOL_UP", {})
			env.ReceivedFromProxy(5001, "DO_PUSH", {})
			c4.advance(10000)
			assert.equal("", fake.last_action(env))
			assert.same({}, c4.calls_to("SendToProxy"))
			assert.equal(before, #box:requests_of("PUT"), "nothing written to the box")
			assert.truthy(logged("proxy 5002 SET_INPUT at "), "logged before it is dropped")
		end)
	end)

	-- Stage 3 (#557, docs/hdmi-sync-stage3-design.md, "S3"; contracts C4;
	-- design 5.2, 5.3, 5.8): Director's commands through syncbox/av.lua and
	-- syncbox/queue.lua to the Lua fake box, confirmed by its reads.
	describe("routing in line (S3 §1, §3; C4)", function()
		local VIDEO_2 = { INPUT = "1001", OUTPUT = "2000", AUDIO = "False", VIDEO = "True" }
		local AUDIO_2 = { INPUT = "3001", OUTPUT = "4000", AUDIO = "True", VIDEO = "False" }

		it("routes a source in line: wakes, switches and syncs, then confirms INPUT_OUTPUT_CHANGED after the read",
			function()
			local env, c4, box = asleep()
			local before = #puts(box)
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			assert.same({}, notifies(c4, "INPUT_OUTPUT_CHANGED"), "nothing before a read shows it")
			c4.advance(200)
			local sent = puts(box)
			assert.equal(before + 1, #sent, "ON and SET_INPUT in one PUT")
			local body = sent[#sent].json
			assert.is_true(body.hdmiActive)
			assert.equal("input2", body.hdmiSource)
			assert.equal("game", body.mode, "HDMI 2 is a PlayStation: Automatic is Game")
			assert.is_true(body.syncActive)
			assert.same({}, notifies(c4, "INPUT_OUTPUT_CHANGED"), "the PUT's answer is no confirmation")
			c4.advance(1500)
			assert.same({ { INPUT = 1001, OUTPUT = 2000, AUDIO = "False", VIDEO = "True" } },
				notifies(c4, "INPUT_OUTPUT_CHANGED"))
			assert.equal(1, #notifies(c4, "ON"))
			assert.same({ "input2", "game", true, true },
				{ ex(box).hdmiSource, ex(box).mode, ex(box).syncActive, ex(box).hdmiActive })
			assert.equal("Game, intense, brightness 100 % on Living Room TV", env.Properties["Status"])
			c4.advance(30000)
			assert.equal(before + 1, #puts(box), "nothing more once confirmed")
		end)

		-- Probes P1 to P4 (docs/syncbox-control4-research.md §6) have not run:
		-- the orders and shapes Director may use, each ending the same way.
		local ORDERS = {
			{ "ON, then SET_INPUT video and SET_INPUT audio", { { "ON", {} }, { "SET_INPUT", VIDEO_2 },
				{ "SET_INPUT", AUDIO_2 } }, { 1001, 3001 } },
			{ "SET_INPUT before ON", { { "SET_INPUT", VIDEO_2 }, { "ON", {} } }, { 1001 } },
			{ "SET_INPUT audio before video", { { "SET_INPUT", AUDIO_2 }, { "SET_INPUT", VIDEO_2 }, { "ON", {} } },
				{ 3001, 1001 } },
			{ "one SET_INPUT with AUDIO and VIDEO, no ON", { { "SET_INPUT", { INPUT = "1001", OUTPUT = "2000",
				AUDIO = "True", VIDEO = "True" } } }, { 1001 } },
			{ "SET_INPUT without AUDIO and VIDEO (the input's range says video)", { { "ON", {} },
				{ "SET_INPUT", { INPUT = "1001", OUTPUT = "2000" } } }, { 1001 } },
			{ "the same SET_INPUT twice", { { "ON", {} }, { "SET_INPUT", VIDEO_2 }, { "SET_INPUT", VIDEO_2 } },
				{ 1001, 1001 } },
			{ "SET_OUTPUT_INPUT from programming", { { "SET_OUTPUT_INPUT", { INPUT = "1001", OUTPUT = "2000" } } },
				{ 1001 } },
			{ "ON, a read, then SET_INPUT", { { "ON", {} }, 1500, { "SET_INPUT", VIDEO_2 } }, { 1001 } },
			{ "SET_INPUT video, a read, then SET_INPUT audio", { { "SET_INPUT", VIDEO_2 }, 1500,
				{ "SET_INPUT", AUDIO_2 } }, { 1001, 3001 } },
		}
		for _, case in ipairs(ORDERS) do
			it("ends on HDMI 2 in game sync for " .. case[1], function()
				local env, c4, box = asleep()
				for _, step in ipairs(case[2]) do
					if type(step) == "number" then
						c4.advance(step)
					else
						env.ReceivedFromProxy(5001, step[1], step[2])
					end
				end
				c4.advance(3000)
				assert.same({ "input2", "game", true }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
				local inputs = {}
				for _, p in ipairs(notifies(c4, "INPUT_OUTPUT_CHANGED")) do inputs[#inputs + 1] = p.INPUT end
				table.sort(inputs)
				local want = { unpack(case[3]) }
				table.sort(want)
				assert.same(want, inputs, "each SET_INPUT confirmed once")
				assert.equal("", fake.last_action(env), "nothing went wrong")
				c4.advance(30000)
				assert.equal("", fake.last_action(env))
			end)
		end

		it("takes the latest of two SET_INPUTs sent together, and confirms only that one", function()
			local env, c4, box = asleep()
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1000", OUTPUT = "2000", AUDIO = "False", VIDEO = "True" })
			c4.advance(3000)
			assert.same({ "input1", "video", true }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
			assert.same({ { INPUT = 1000, OUTPUT = 2000, AUDIO = "False", VIDEO = "True" } },
				notifies(c4, "INPUT_OUTPUT_CHANGED"))
			assert.equal("", fake.last_action(env), "a write a later one replaced says nothing")
		end)

		it("syncs in each input's own mode, and only switches an input set to Do not sync", function()
			local env, c4, box = asleep()
			set_property(env, "HDMI 2 Sync Mode", "Video")
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(3000)
			assert.same({ "input2", "video", true }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
			-- An audio-only route (a Listen source) on a generic input: Music.
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "3002", OUTPUT = "4000", AUDIO = "True", VIDEO = "False" })
			c4.advance(3000)
			assert.same({ "input3", "music", true }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
			-- Do not sync: the input, and the sync of the input before stops.
			set_property(env, "HDMI 1 Sync Mode", "Do not sync")
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1000", OUTPUT = "2000", AUDIO = "False", VIDEO = "True" })
			c4.advance(3000)
			assert.same({ "input1", "passthrough", false }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
			assert.equal(3, #notifies(c4, "INPUT_OUTPUT_CHANGED"))
			assert.equal("", fake.last_action(env))
		end)

		it("refuses an input the box lacks, sending nothing (HSB3)", function()
			local env, c4, box = asleep(F.state.HSB3)
			local before = #puts(box)
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(5000)
			assert.equal("Not switched: this box has 1 HDMI input", fake.last_action(env))
			assert.equal(before, #puts(box))
			assert.same({}, notifies(c4, "INPUT_OUTPUT_CHANGED"))
		end)

		it("tries an input the box did not take 4 times 2 s apart, then says it was not switched", function()
			local env, c4, box = asleep()
			box:fault("drop", { method = "PUT", path = "/execution" })
			local before = #puts(box)
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(200)
			assert.equal(before + 1, #puts(box))
			c4.advance(2000)
			assert.equal(before + 2, #puts(box), "the second try 2 s after the first")
			c4.advance(30000)
			assert.equal(before + 4, #puts(box), "4 tries in all")
			assert.truthy(logged("Not switched: the box did not change input"))
			assert.same({}, notifies(c4, "INPUT_OUTPUT_CHANGED"))
			assert.same({}, notifies(c4, "ON"))
			assert.equal("powersave", ex(box).mode, "the box as it was")
		end)

		it("confirms an input that landed at the second try", function()
			local env, c4, box = asleep()
			box:fault("drop", { method = "PUT", path = "/execution", count = 1 })
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(8000)
			assert.same({ { INPUT = 1001, OUTPUT = 2000, AUDIO = "False", VIDEO = "True" } },
				notifies(c4, "INPUT_OUTPUT_CHANGED"))
			assert.same({ "input2", "game", true }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
			assert.is_nil(logged("Not switched"))
		end)

		it("answers a route to a box that does not answer as undelivered, and never confirms it", function()
			local env, c4, box = asleep()
			box:silence(true)
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(120000)
			assert.truthy(logged("Not switched: "), "said in Last Action")
			assert.same({}, notifies(c4, "INPUT_OUTPUT_CHANGED"))
			assert.same({}, notifies(c4, "ON"))
			-- The box back: nothing replayed by itself (EC I15: not the old sequence).
			local before = #puts(box)
			box:silence(false)
			c4.advance(60000)
			assert.equal(before, #puts(box))
			assert.equal("powersave", ex(box).mode)
		end)

		it("switches the input but does not sync while another app streams (code 16, busy)", function()
			local env, c4, box = asleep()
			box:event("bridge", { state = "busy" })
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(8000)
			assert.same({ "input2", false, true }, { ex(box).hdmiSource, ex(box).syncActive, ex(box).hdmiActive })
			assert.same({ { INPUT = 1001, OUTPUT = 2000, AUDIO = "False", VIDEO = "True" } },
				notifies(c4, "INPUT_OUTPUT_CHANGED"), "the picture switched")
			assert.truthy(logged("Not syncing: another app streams to the Hue Bridge's entertainment area"))
			local refused = 0
			for _, r in ipairs(puts(box)) do
				if r.status ~= 200 then refused = refused + 1 end
			end
			assert.equal(1, refused, "a code 16 is not retried")
		end)

		it("puts the box in power save at Room Off, or keeps the picture as At Room Off says", function()
			local env, c4, box = asleep()
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(3000)
			-- P4: DISCONNECT_OUTPUT and OFF, in either order, are Room Off.
			env.ReceivedFromProxy(5001, "DISCONNECT_OUTPUT", { OUTPUT = "2000", VIDEO = "True", AUDIO = "False" })
			env.ReceivedFromProxy(5001, "OFF", {})
			assert.same({}, notifies(c4, "OFF"), "OFF only once done")
			c4.advance(3000)
			assert.equal("powersave", ex(box).mode)
			assert.equal(1, #notifies(c4, "OFF"))
			assert.equal("Power save", env.Properties["Status"])
			-- At Room Off: Stop syncing and keep the picture; OFF before DISCONNECT_OUTPUT.
			set_property(env, "At Room Off", "Stop syncing and keep the picture")
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			env.ReceivedFromProxy(5001, "ON", {})
			c4.advance(3000)
			assert.equal("game", ex(box).mode)
			env.ReceivedFromProxy(5001, "OFF", {})
			env.ReceivedFromProxy(5001, "DISCONNECT_OUTPUT", { OUTPUT = "2000" })
			c4.advance(3000)
			assert.same({ "passthrough", false, true }, { ex(box).mode, ex(box).syncActive, ex(box).hdmiActive })
			assert.equal(2, #notifies(c4, "OFF"))
			assert.equal("", fake.last_action(env))
		end)

		it("stops syncing and keeps the picture when the source leaves the box", function()
			local env, c4, box = asleep()
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(3000)
			env.ReceivedFromProxy(5001, "DISCONNECT_OUTPUT", { OUTPUT = "2000", VIDEO = "True" })
			c4.advance(3000)
			assert.same({ "passthrough", false, true }, { ex(box).mode, ex(box).syncActive, ex(box).hdmiActive })
			assert.same({}, notifies(c4, "OFF"), "the room stays on")
			-- The setting: Power save.
			set_property(env, "When The Source Leaves The Box", "Power save")
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(3000)
			env.ReceivedFromProxy(5001, "DISCONNECT_OUTPUT", { OUTPUT = "2000", VIDEO = "True" })
			c4.advance(3000)
			assert.equal("powersave", ex(box).mode)
			-- A new route within the wait cancels the leave.
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(3000)
			env.ReceivedFromProxy(5001, "DISCONNECT_OUTPUT", { OUTPUT = "2000", VIDEO = "True" })
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1000", OUTPUT = "2000", VIDEO = "True" })
			c4.advance(3000)
			assert.same({ "input1", "video", true }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
		end)

		it("never confirms a change the box made by itself (C4)", function()
			local env, c4, box = asleep()
			box:event("cec_active_source", { input = "input2" })
			c4.advance(12000)
			assert.equal("input2", ex(box).hdmiSource)
			assert.same({}, c4.calls_to("SendToProxy"))
			assert.equal("", fake.last_action(env))
		end)

		it("starts again after a restart in the middle of a route: nothing replayed, the next route works", function()
			local env, c4, box = asleep()
			box:fault("drop", { method = "PUT", path = "/execution" })
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(200)
			local tried = #puts(box)
			reload(env)
			box:fault()
			c4.advance(30000)
			assert.equal(tried, #puts(box), "the old route is not sent again by itself (EC C14)")
			assert.same({}, notifies(c4, "INPUT_OUTPUT_CHANGED"))
			assert.equal("powersave", ex(box).mode)
			env.ReceivedFromProxy(5001, "SET_INPUT", VIDEO_2)
			c4.advance(3000)
			assert.same({ "input2", "game", true }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
			assert.equal(1, #notifies(c4, "INPUT_OUTPUT_CHANGED"))
		end)
	end)

	-- The followed room and its sources (S3 §2, §4; W §1.2, §5, §7.2): the
	-- default room 7 "Living Room" of the fake project, its variables set
	-- with fake.room_variable as Director would change them.
	local ROOM = 7
	local function watch(id)
		fake.room_variable(ROOM, 1002, id)
		fake.room_variable(ROOM, 1000, id)
	end
	local function listen(id)
		fake.room_variable(ROOM, 1001, id)
		fake.room_variable(ROOM, 1000, id)
	end
	local function room_off()
		fake.room_variable(ROOM, 1000, 0)
	end

	-- Three sources; the ids a room selects are their proxies' (4002, 4012,
	-- 4022). The PS5's driver file names a console (#536: Game, guessed).
	local function add_sources()
		return {
			apple = fake.add_device(4001, { name = "Apple TV", driver = "apple_tv_ip.c4z", proxy = "dvd" }),
			ps5 = fake.add_device(4011, { name = "PS5", driver = "playstation_5_ip.c4z", proxy = "dvd" }),
			radio = fake.add_device(4021, { name = "Radio", driver = "internet_radio.c4z", proxy = "tuner" }),
		}
	end

	-- The receiver's output bound to the box's HDMI 1 (video 1000; the box's
	-- avswitch proxy is 3001), the sources to the receiver's inputs: the
	-- bindings syncbox/sources.lua walks upstream (W §3.2, §4.1 choice B).
	local BOX_PROXY = 3001
	local function connect_receiver(c4, src)
		local receiver = fake.add_device(4101, { name = "AV Receiver", driver = "receiver_ip.c4z", proxy = "receiver" })
		c4:Bind(receiver, 2000, BOX_PROXY, 1000, "HDMI")
		c4:Bind(src.apple, 2000, receiver, 1000, "HDMI")
		c4:Bind(src.ps5, 2000, receiver, 1001, "HDMI")
		c4:Bind(src.radio, 2000, receiver, 1002, "HDMI")
		return receiver
	end

	local MANAGED = { "HDMI 1 Sync Mode", "HDMI 2 Sync Mode", "HDMI 3 Sync Mode", "HDMI 4 Sync Mode", "Follow Room",
		"Source Sync Modes" }

	-- The managed rows as Composer shows them: name → true shown, false hidden.
	local function shown(c4)
		local out = {}
		for _, name in ipairs(MANAGED) do out[name] = c4.property_attribs[name] == 0 end
		return out
	end

	local IN_LINE = { ["HDMI 1 Sync Mode"] = true, ["HDMI 2 Sync Mode"] = true, ["HDMI 3 Sync Mode"] = true,
		["HDMI 4 Sync Mode"] = true, ["Follow Room"] = false, ["Source Sync Modes"] = false }
	local ROOM_DRIVEN = { ["HDMI 1 Sync Mode"] = false, ["HDMI 2 Sync Mode"] = false, ["HDMI 3 Sync Mode"] = false,
		["HDMI 4 Sync Mode"] = false, ["Follow Room"] = true, ["Source Sync Modes"] = true }

	describe("the settings rows per wiring (S3 §5; W §7.2)", function()
		it("shows only the settings of the box's wiring and switches them when the wiring changes", function()
			local env, c4, box = paired()
			c4.advance(2000)
			assert.same(IN_LINE, shown(c4))
			assert.is_nil(c4.property_attribs["At Room Off"], "never hidden")
			assert.is_nil(c4.property_attribs["When The Source Leaves The Box"], "never hidden")
			assert.is_nil(logged("wiring changed"), "the first read is no change")
			-- The Hue Sync app turns ARC bypass on: behind a receiver.
			box.state.behavior.arcBypassMode = 1
			c4.advance(5000)
			assert.same(ROOM_DRIVEN, shown(c4))
			assert.equal("The box's wiring changed to Behind a receiver (ARC bypass on): Control4 routes through the box "
				.. "and the followed room's source sets the sync mode", fake.last_action(env))
			assert.equal("behind_receiver", c4.persist.syncbox_wiring)
			-- Solo mode on: a receiver's second output, the same rows. The room
			-- followed is off (nothing selected), so At Room Off applies once (W22).
			box.state.behavior.soloMode = 1
			c4.advance(5000)
			assert.same(ROOM_DRIVEN, shown(c4))
			assert.truthy(logged("The box's wiring changed to From a receiver's second output (solo mode): the followed "
				.. "room's power and source drive the box"))
			assert.equal("The box is now on a receiver's second output; Living Room off: power save", fake.last_action(env))
			assert.equal("powersave", box.state.execution.mode)
			-- Back in line (the next read: 30 s in power save); Composer hears it
			-- again 400 ms and 1.5 s later.
			box.state.behavior.soloMode, box.state.behavior.arcBypassMode = 0, 0
			c4.calls = {}
			c4.advance(31000)
			assert.same(IN_LINE, shown(c4))
			local hides = 0
			for _, call in ipairs(c4.calls_to("SetPropertyAttribs")) do
				if call[1] == "Follow Room" and call[2] == 1 then hides = hides + 1 end
			end
			assert.truthy(hides >= 3, "at once, then 400 ms and 1.5 s later: " .. hides)
		end)

		it("shows HDMI 1 Sync Mode alone on an HSB3", function()
			local _, c4 = paired(F.state.HSB3)
			c4.advance(2000)
			assert.same({ ["HDMI 1 Sync Mode"] = true, ["HDMI 2 Sync Mode"] = false, ["HDMI 3 Sync Mode"] = false,
				["HDMI 4 Sync Mode"] = false, ["Follow Room"] = false, ["Source Sync Modes"] = false }, shown(c4))
		end)

		it("shows the last wiring's rows at a restart, before the box answers", function()
			local _, c4 = paired(F.state.HSB2_second_output)
			c4.advance(2000)
			local kept = {}
			for k, v in pairs(c4.persist) do kept[k] = v end
			local env2, c4b = load_box({ persist = kept, silent = true })
			assert.same(ROOM_DRIVEN, shown(c4b))
			assert.equal("From a receiver's second output (solo mode)", env2.Properties["Wiring"], "the persisted row")
		end)
	end)

	describe("Follow Room (S3 §2; W §5, §7.2)", function()
		it("lists this device's room first and follows it by default (#536), and keeps a pick as a room id",
			function()
			local env, c4 = paired(F.state.HSB2_second_output)
			c4.advance(2000)
			assert.equal("This device's room (Living Room),None (the box decides),Living Room",
				c4.property_lists["Follow Room"])
			assert.equal("This device's room (Living Room)", env.Properties["Follow Room"])
			assert.is_true(c4.listens(ROOM, 1000), "the device's room is followed")
			assert.truthy(env.Properties["Status"]:find("; follows Living Room", 1, true), env.Properties["Status"])
			-- A new room appears in the list at the next read.
			fake.add_room(8, "Kitchen")
			c4.advance(5000)
			assert.equal("This device's room (Living Room),None (the box decides),Kitchen,Living Room",
				c4.property_lists["Follow Room"])
			set_property(env, "Follow Room", "Kitchen")
			assert.same({ mode = "room", id = 8, name = "Kitchen" }, c4.persist.syncbox_follow_room)
			assert.is_true(c4.listens(8, 1000))
			assert.is_false(c4.listens(ROOM, 1000))
			assert.equal("Follows Kitchen (chosen; this device is in Living Room)", fake.last_action(env))
			c4.advance(2000)
			assert.truthy(env.Properties["Status"]:find("; follows Kitchen", 1, true), env.Properties["Status"])
			-- None: no room, the box on its own (W2).
			set_property(env, "Follow Room", "None (the box decides)")
			assert.is_false(c4.listens(8, 1000))
			assert.truthy(env.Properties["Status"]:find("; follows no room: the box runs on its own settings", 1, true),
				env.Properties["Status"])
		end)

		it("follows no room in line, and keeps the pick for later", function()
			local env, c4 = paired()
			c4.advance(2000)
			assert.is_false(c4.listens(ROOM, 1000))
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
			set_property(env, "Follow Room", "None (the box decides)")
			assert.equal("Follow Room: None (the box decides) (used behind a receiver and on a receiver's second output)",
				fake.last_action(env))
			assert.equal("none", c4.persist.syncbox_follow_room.mode)
		end)

		it("says a deleted followed room and follows no other room by itself (W4)", function()
			local env, c4 = paired(F.state.HSB2_second_output)
			fake.add_room(8, "Kitchen")
			c4.advance(5000)
			set_property(env, "Follow Room", "Kitchen")
			c4.advance(2000)
			fake.delete_room(8)
			c4.advance(5000)
			assert.equal("Follows a deleted room (Kitchen, room 8): pick another in Follow Room", fake.last_action(env))
			assert.truthy(env.Properties["Status"]:find("; follows a deleted room (Kitchen, room 8)", 1, true),
				env.Properties["Status"])
			assert.is_false(c4.listens(8, 1000))
			assert.is_false(c4.listens(ROOM, 1000), "never the device's room instead")
			assert.equal("Kitchen (deleted room 8)", env.Properties["Follow Room"])
		end)

		it("says a room whose variables do not answer, in Status (W16)", function()
			local env, c4 = paired(F.state.HSB2_second_output)
			fake.add_room(8, "Kitchen")
			fake.room_variables(8)[1000] = nil
			c4.advance(5000)
			set_property(env, "Follow Room", "Kitchen")
			c4.advance(2000)
			assert.truthy(env.Properties["Status"]:find("; cannot follow Kitchen: its variables do not answer", 1, true),
				env.Properties["Status"])
		end)
	end)

	describe("offers and the project's changes (W16, W20, W21; never applied by themselves)", function()
		it("registers OnPIP and follows a room again on it when its variables did not answer (W16)", function()
			local registered = {}
			local s = F.copy(F.state.HSB2_second_output)
			local env, c4 = paired(s, { before_late = function(e, c)
				e.C4SystemEvents = { OnPIP = 6, OnItemNameChanged = 13 }
				c.RegisterSystemEvent = function(_, id, device) registered[#registered + 1] = { id, device } end
			end })
			assert.same({ { 6, 0 } }, registered, "OnPIP only, for every device")
			fake.add_room(8, "Kitchen")
			fake.room_variables(8)[1000] = nil
			c4.advance(5000)
			set_property(env, "Follow Room", "Kitchen")
			c4.advance(2000)
			assert.truthy(env.Properties["Status"]:find("; cannot follow Kitchen", 1, true), env.Properties["Status"])
			fake.room_variables(8)[1000] = { name = "CURRENT_SELECTED_DEVICE", value = "0" }
			env.OnSystemEvent("<OnPIP/>")
			c4.advance(2000)
			assert.is_true(c4.listens(8, 1000))
			assert.truthy(env.Properties["Status"]:find("; follows Kitchen", 1, true), env.Properties["Status"])
		end)

		it("offers the room whose picture runs through the box behind a receiver, once, without following it (W20)",
			function()
			local env, c4 = asleep(F.state.HSB2_behind_receiver)
			local src = add_sources()
			fake.add_room(9, "Theater")
			fake.room_variable(9, 1008, "<id>" .. src.ps5 .. "</id><id>" .. BOX_PROXY .. "</id><id>4901</id>")
			c4.advance(2000)
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1000", OUTPUT = "2000", VIDEO = "True" })
			c4.advance(3000)
			assert.truthy(logged("Theater's picture runs through this box (Follow Room)"))
			assert.is_false(c4.listens(9, 1000), "offered, not followed")
			assert.is_true(c4.listens(ROOM, 1000))
			local said = 0
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1000", OUTPUT = "2000", VIDEO = "True" })
			c4.advance(3000)
			for _, line in ipairs(lines) do
				if line:find("Theater's picture runs through this box", 1, true) then said = said + 1 end
			end
			assert.equal(1, said, "said once")
		end)

		it("offers a replaced source's mode to the device that replaced it, and moves it on a click (W21)", function()
			local env, c4 = asleep(F.state.HSB2_behind_receiver)
			local src = add_sources()
			local receiver = connect_receiver(c4, src)
			env.ReceivedFromProxy(5001, "BINDING_CHANGE_ACTION", { BINDING_ID = "1000", IS_BOUND = "True" })
			action(env, "Set Source Sync Mode", { Source = "source:" .. src.apple, Mode = "Music" })
			-- The Apple TV replaced in Composer by a new device of the same name.
			fake.delete_device(4001)
			local new = fake.add_device(4301, { name = "Apple TV", driver = "apple_tv_ip.c4z", proxy = "dvd" })
			c4:Bind(new, 2000, receiver, 1000, "HDMI")
			env.OnSystemEvent("<OnPIP/>")
			assert.equal("Apple TV (device " .. new .. ") replaces a source set to Music: give it Music with Set Source "
				.. "Sync Mode", fake.last_action(env))
			assert.truthy(env.Properties["Source Sync Modes"]:find("Apple TV: Music (device gone)", 1, true),
				env.Properties["Source Sync Modes"])
			assert.truthy(env.Properties["Source Sync Modes"]:find("Apple TV: Video", 1, true), "not applied by itself")
			local list = fake.custom_select(env, "SourceList")
			assert.equal(string.format("offer:%d:%d", src.apple, new), list[1].value)
			action(env, "Set Source Sync Mode", { Source = list[1].value, Mode = "Automatic" })
			assert.equal("Source Sync Mode of Apple TV: Music (from device " .. src.apple .. ", which it replaces)",
				fake.last_action(env))
			assert.equal("Apple TV: Music; PS5: Game (guessed from its driver); Radio: Music",
				env.Properties["Source Sync Modes"])
		end)
	end)

	describe("on a receiver's second output (S3 §1; W §4.2)", function()
		it("follows the room on a receiver's second output: wakes and syncs on a source, power save at Room Off",
			function()
			local env, c4, box = asleep(F.state.HSB2_second_output)
			local src = add_sources()
			c4.advance(2000)
			assert.equal(0, #puts(box), "the room's first state is a baseline")
			watch(src.ps5)
			c4.advance(3000)
			assert.same({ "game", true, true }, { ex(box).mode, ex(box).syncActive, ex(box).hdmiActive })
			assert.equal("Living Room on PS5: syncing game", fake.last_action(env))
			assert.truthy(env.Properties["Status"]:find("; follows Living Room (watching PS5)", 1, true),
				env.Properties["Status"])
			watch(src.apple)
			c4.advance(3000)
			assert.same({ "video", true }, { ex(box).mode, ex(box).syncActive })
			listen(src.radio)
			c4.advance(3000)
			assert.same({ "music", true }, { ex(box).mode, ex(box).syncActive })
			room_off()
			c4.advance(3000)
			assert.equal("powersave", ex(box).mode, "At Room Off: Power save")
			-- Director routes nothing through the box here; a command is only logged.
			local before = #puts(box)
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1000", OUTPUT = "2000", VIDEO = "True" })
			c4.advance(5000)
			assert.equal(before, #puts(box))
			assert.same({}, c4.calls_to("SendToProxy"), "nothing to the proxy in this wiring")
		end)

		it("keeps the picture at Room Off when At Room Off says so", function()
			local env, c4, box = asleep(F.state.HSB2_second_output)
			local src = add_sources()
			set_property(env, "At Room Off", "Stop syncing and keep the picture")
			c4.advance(2000)
			watch(src.apple)
			c4.advance(3000)
			room_off()
			c4.advance(3000)
			assert.same({ "passthrough", false, true }, { ex(box).mode, ex(box).syncActive, ex(box).hdmiActive })
		end)

		it("stops syncing when the room's source does not pass the receiver (W17)", function()
			local env, c4, box = asleep(F.state.HSB2_second_output)
			local src = add_sources()
			local receiver = connect_receiver(c4, src)
			c4.advance(2000)
			fake.room_variable(ROOM, 1008, "<id>" .. src.ps5 .. "</id><id>" .. receiver .. "</id>")
			watch(src.ps5)
			c4.advance(3000)
			assert.same({ "game", true }, { ex(box).mode, ex(box).syncActive })
			-- The TV's own app: its path does not run through the receiver.
			local app = fake.add_device(4201, { name = "TV App", driver = "tv_app.c4z", proxy = "dvd" })
			fake.room_variable(ROOM, 1008, "<id>" .. app .. "</id>")
			watch(app)
			c4.advance(3000)
			assert.same({ "passthrough", false, true }, { ex(box).mode, ex(box).syncActive, ex(box).hdmiActive })
			assert.truthy(fake.last_action(env):find("which does not pass the box", 1, true), fake.last_action(env))
		end)

		it("applies the room's state once when the box answers again after an outage, not the missed ones (W23)",
			function()
			local env, c4, box = asleep(F.state.HSB2_second_output)
			local src = add_sources()
			c4.advance(2000)
			box:silence(true)
			c4.advance(6 * 60000)
			assert.truthy(env.Properties["Online"]:match("^Offline since "), env.Properties["Online"])
			local before = #puts(box)
			watch(src.ps5)
			c4.advance(3000)
			watch(src.apple)
			c4.advance(3000)
			assert.equal("Living Room on Apple TV: syncing video, once the box answers again", fake.last_action(env))
			box:silence(false)
			c4.advance(2 * 60000)
			assert.equal("Online", env.Properties["Online"])
			assert.same({ "video", true }, { ex(box).mode, ex(box).syncActive })
			assert.equal(before + 1, #puts(box), "one write: the room's state now, not the sequence")
			assert.equal("When the box answered again: Living Room on Apple TV: syncing video", fake.last_action(env))
		end)

		it("takes the last of quick source changes, and a write it replaced is no failure (W19)", function()
			local env, c4, box = asleep(F.state.HSB2_second_output)
			local src = add_sources()
			c4.advance(2000)
			box:fault("latency", { ms = 3000, method = "PUT", path = "/execution" })
			listen(src.radio)
			c4.advance(1500)
			watch(src.apple)
			box:fault()
			c4.advance(8000)
			assert.same({ "video", true }, { ex(box).mode, ex(box).syncActive })
			assert.is_nil(logged("No sound"), "the music write was replaced, not refused")
			assert.equal("Living Room on Apple TV: syncing video", fake.last_action(env))
		end)

		it("changes nothing on the box at a restart: the room's first state is a baseline (W15)", function()
			local env, c4, box = asleep(F.state.HSB2_second_output)
			local src = add_sources()
			c4.advance(2000)
			watch(src.ps5)
			c4.advance(3000)
			assert.equal("game", ex(box).mode)
			local before = #puts(box)
			reload(env)
			c4.advance(30000)
			assert.equal(before, #puts(box), "nothing sent at start (EC C14)")
			assert.is_true(c4.listens(ROOM, 1000))
			watch(src.apple)
			c4.advance(3000)
			assert.equal("video", ex(box).mode, "later changes act")
		end)
	end)

	describe("behind a receiver (S3 §1; design 5.8)", function()
		it("takes the sync mode from the followed room's source behind a receiver", function()
			local env, c4, box = asleep(F.state.HSB2_behind_receiver)
			local src = add_sources()
			c4.advance(2000)
			watch(src.ps5)
			c4.advance(3000)
			assert.equal(0, #puts(box), "the room alone does not route the box here")
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1000", OUTPUT = "2000", AUDIO = "False", VIDEO = "True" })
			c4.advance(3000)
			assert.same({ "input1", "game", true }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
			assert.same({ { INPUT = 1000, OUTPUT = 2000, AUDIO = "False", VIDEO = "True" } },
				notifies(c4, "INPUT_OUTPUT_CHANGED"))
			-- Another source through the receiver: Director may send the box
			-- nothing (W §3.1, P10); the room says it.
			watch(src.apple)
			c4.advance(3000)
			assert.same({ "input1", "video", true }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
			assert.equal(1, #notifies(c4, "INPUT_OUTPUT_CHANGED"))
		end)

		it("starts music sync for a Listen selection behind a receiver (#536)", function()
			local env, c4, box = asleep(F.state.HSB2_behind_receiver)
			local src = add_sources()
			c4.advance(2000)
			watch(src.ps5)
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1000", OUTPUT = "2000", VIDEO = "True" })
			c4.advance(3000)
			assert.equal("game", ex(box).mode)
			-- Listen: Director takes the box off the picture's path.
			env.ReceivedFromProxy(5001, "DISCONNECT_OUTPUT", { OUTPUT = "2000", VIDEO = "True" })
			listen(src.radio)
			c4.advance(4000)
			assert.same({ "music", true }, { ex(box).mode, ex(box).syncActive })
			-- A video source picked under Listen is a Music selection too (W §2.2).
			listen(src.apple)
			c4.advance(4000)
			assert.same({ "music", true }, { ex(box).mode, ex(box).syncActive })
		end)
	end)

	describe("Set Source Sync Mode (S3 §5; W §7.2)", function()
		it("keeps a source's sync mode from Set Source Sync Mode and shows it in Source Sync Modes", function()
			local env, c4, box = asleep(F.state.HSB2_behind_receiver)
			local src = add_sources()
			connect_receiver(c4, src)
			env.ReceivedFromProxy(5001, "BINDING_CHANGE_ACTION", { BINDING_ID = "1000", IS_BOUND = "True" })
			assert.equal("Apple TV: Video; PS5: Game (guessed from its driver); Radio: Music",
				env.Properties["Source Sync Modes"])
			local list = fake.custom_select(env, "SourceList")
			assert.same({ text = "Apple TV: Video", value = "source:" .. src.apple }, list[1])
			assert.same({ text = "PS5: Game (guessed from its driver)", value = "source:" .. src.ps5 }, list[2])
			action(env, "Set Source Sync Mode", { Source = "source:" .. src.apple, Mode = "Music" })
			assert.equal("Source Sync Mode of Apple TV: Music", fake.last_action(env))
			assert.equal("Apple TV: Music; PS5: Game (guessed from its driver); Radio: Music",
				env.Properties["Source Sync Modes"])
			-- It decides the mode behind the receiver.
			c4.advance(2000)
			watch(src.apple)
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1000", OUTPUT = "2000", VIDEO = "True" })
			c4.advance(3000)
			assert.same({ "music", true }, { ex(box).mode, ex(box).syncActive })
			-- Kept across a restart; Automatic removes it.
			reload(env)
			assert.equal("Apple TV: Music; PS5: Game (guessed from its driver); Radio: Music",
				env.Properties["Source Sync Modes"])
			action(env, "Set Source Sync Mode", { Source = "source:" .. src.apple, Mode = "Automatic" })
			assert.equal("Source Sync Mode of Apple TV: Automatic", fake.last_action(env))
			assert.equal("Apple TV: Video; PS5: Game (guessed from its driver); Radio: Music",
				env.Properties["Source Sync Modes"])
		end)

		it("asks for a source, and says where a mode applies in line", function()
			local env, c4 = paired()
			action(env, "Set Source Sync Mode", { Mode = "Game" })
			assert.truthy(fake.last_action(env):find("^Set Source Sync Mode: pick a source under Source"))
			local list = fake.custom_select(env, "SourceList")
			assert.equal("", list[1].value, "nothing to pick yet")
			local src = add_sources()
			c4.advance(1000)
			action(env, "Set Source Sync Mode", { Source = "source:" .. src.ps5, Mode = "Video" })
			assert.equal("Source Sync Mode of PS5: Video (used behind a receiver and on a second output; in line the "
				.. "HDMI n Sync Mode rows decide)", fake.last_action(env))
		end)
	end)

	describe("a wiring change while routed (W22)", function()
		it("hands the box from Director to the followed room when solo mode comes on, applying the room once",
			function()
			local env, c4, box = asleep()
			local src = add_sources()
			env.ReceivedFromProxy(5001, "ON", {})
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1001", OUTPUT = "2000", VIDEO = "True" })
			watch(src.apple)
			c4.advance(3000)
			assert.same({ "input2", "game", true }, { ex(box).hdmiSource, ex(box).mode, ex(box).syncActive })
			assert.is_false(c4.listens(ROOM, 1000), "in line no room is followed")
			box.state.behavior.soloMode = 1
			c4.advance(5000)
			assert.same(ROOM_DRIVEN, shown(c4))
			assert.truthy(logged("The box's wiring changed to From a receiver's second output (solo mode)"))
			assert.is_true(c4.listens(ROOM, 1000))
			assert.same({ "video", true }, { ex(box).mode, ex(box).syncActive }, "the room's Apple TV, once")
			assert.truthy(logged("Living Room on Apple TV: syncing video"))
			local before = #puts(box)
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1001", OUTPUT = "2000", VIDEO = "True" })
			c4.advance(30000)
			assert.equal(before, #puts(box), "Director's commands only logged now")
			-- And back in line: the room is let go; Director routes again.
			box.state.behavior.soloMode = 0
			c4.advance(5000)
			assert.same(IN_LINE, shown(c4))
			assert.is_false(c4.listens(ROOM, 1000))
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1001", OUTPUT = "2000", VIDEO = "True" })
			c4.advance(3000)
			assert.same({ "input2", "game" }, { ex(box).hdmiSource, ex(box).mode })
		end)
	end)

	describe("Diagnostics", function()
		it("checks the box now", function()
			local env, c4 = paired()
			action(env, "Diagnostics", { What = "Check the box now" })
			c4.advance(1000)
			assert.equal("Check the box now: Hue Sync Box (8K) " .. SHORT .. " answers at " .. F.ADDRESS
				.. " and passed the identity and TLS checks", fake.last_action(env))
		end)

		it("reads everything from the box now", function()
			local env, c4 = paired()
			action(env, "Diagnostics", { What = "Read everything from the box now" })
			c4.advance(1000)
			assert.equal("Read everything from the box now: Video, high, brightness 100 % on Living Room TV",
				fake.last_action(env))
		end)

		it("prints the raw state with every secret field redacted (R1 §2.9)", function()
			local state = F.copy(F.state.HSB2)
			state.hue.bleSecretKey = "SECRET-VALUE-ONE"
			state.hue.clientKey = "SECRET-VALUE-TWO"
			state.device.wifi.psk = "SECRET-VALUE-THREE"
			state.hue.lights = { { name = "Lamp", key = "SECRET-VALUE-FOUR", password = "SECRET-VALUE-FIVE" } }
			local env, c4 = paired(state)
			action(env, "Diagnostics", { What = "Show the box's raw state in the Lua output" })
			c4.advance(1000)
			assert.truthy(fake.last_action(env):match("^Show the box's raw state: %d+ bytes in the Lua output, secret "
				.. "fields redacted$"), fake.last_action(env))
			local dump = table.concat(lines, "\n")
			assert.truthy(dump:find("Living Room Sync Box", 1, true), "the state is printed")
			assert.truthy(dump:find("<redacted>", 1, true))
			assert.is_nil(dump:find("SECRET-VALUE", 1, true))
			assert.is_nil(dump:find(F.TOKEN, 1, true))
		end)

		it("says what to pick, and what is missing when nothing is paired", function()
			local env = load_box()
			action(env, "Diagnostics", {})
			assert.truthy(fake.last_action(env):find("^Diagnostics: pick one under What"))
			action(env, "Diagnostics", { What = "Read everything from the box now" })
			assert.equal("Read everything from the box now: not paired; run Pair Sync Box first", fake.last_action(env))
		end)
	end)

	describe("the bridge's hints (C5, #483)", function()
		it("reads the box at once on an AREA and marks a CONFIGURE that names another bridge", function()
			local env, c4, box = paired(nil, { bind = true })
			c4.advance(2500)
			local reads = #box:requests_of("GET", "")
			env.ExecuteCommand("HUE_SYNCBOX_AREA", { id = F.AREA.tv, status = "active", streamer = "this_box" })
			assert.equal(reads + 1, #box:requests_of("GET", ""))
			env.ExecuteCommand("HUE_SYNCBOX_CONFIGURE", { bridge_id = "001788fffe999999", match = "false", areas = "[]" })
			assert.equal("Hue Bridge 001788fffe123abc, streaming (not the Hue Bridge bound in Control4)",
				env.Properties["Bridge Link"])
			env.ExecuteCommand("HUE_SYNCBOX_AREA", { id = "not an id", status = "active", streamer = "this_box" })
			assert.equal(reads + 1, #box:requests_of("GET", ""), "a malformed hint is dropped")
		end)

		it("keeps working when unbound from the bridge (EC C20)", function()
			local env, c4 = paired(nil, { bind = true })
			c4:Unbind(BOX_DEVICE, 1)
			env.OnBindingChanged(1, "HUE_SYNCBOX", false, BRIDGE)
			c4.advance(5000)
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
			assert.equal("Online", env.Properties["Online"])
		end)

		it("says goodbye when Composer deletes the device", function()
			local env, c4 = paired(nil, { bind = true })
			env.OnDriverRemovedFromProject()
			local sent = to_bridge(c4)
			assert.equal("HUE_SYNCBOX_GOODBYE", sent[#sent][1])
		end)
	end)

	it("turns Debug Mode Off after 8 hours, in Last Action (#493)", function()
		local env, c4 = load_box({ box = false, debug = true })
		c4.advance(8 * HOUR + 1000)
		assert.equal("Off", env.Properties["Debug Mode"])
		assert.equal("Debug Mode turned itself Off after 8 hours", fake.last_action(env))
	end)

	-- #547, docs/fakebox-design.md §7: a dev build pairs with the VM's fake box,
	-- which serves HTTPS on 8443 and announces that port by mDNS.
	describe("a dev build's syncbox/devhooks.lua (#547)", function()
		local FAKE = F.ADDRESS .. ":8443"
		local blocked

		before_each(function()
			blocked = package.preload["syncbox.devhooks"]
			package.preload["syncbox.devhooks"], package.loaded["syncbox.devhooks"] = nil, nil
		end)

		after_each(function()
			package.preload["syncbox.devhooks"], package.loaded["syncbox.devhooks"] = blocked, nil
			package.preload["common.build_kind"], package.loaded["common.build_kind"] = nil, nil
		end)

		-- The Lua fake box answers on 443 only (tests/helpers/fake_c4.lua); here
		-- a transfer to <its address>:8443 reaches it, and every URL the driver
		-- built is kept, as it built it, in the list returned.
		local function box_on_8443(c4)
			local urls, make = {}, c4.url
			c4.url = function(self)
				local t = make(self)
				for _, method in ipairs({ "Get", "Post", "Put", "Delete" }) do
					local start = t[method]
					t[method] = function(transfer, url, ...)
						urls[#urls + 1] = tostring(url)
						return start(transfer, (tostring(url):gsub("^(https://[%d%.]+):8443/", "%1/")), ...)
					end
				end
				return t
			end
			return urls
		end

		-- load_box with the box reached on 8443 from the start.
		local function start(opts)
			opts = opts or {}
			local env, c4 = fake.load_driver("hue_syncbox", {}, { device_id = BOX_DEVICE })
			for k, v in pairs(opts.persist or {}) do c4.persist[k] = v end
			local urls = box_on_8443(c4)
			local box = fake.syncbox(opts.box or {})
			env.OnDriverInit("DIT_STARTUP")
			env.OnDriverLateInit("DIT_STARTUP")
			return env, c4, box, urls
		end

		local function all_to(urls, prefix)
			assert.truthy(#urls > 0, "requests went out")
			for _, url in ipairs(urls) do
				assert.equal(prefix, url:sub(1, #prefix), url)
			end
		end

		it("pairs with the box at host:port typed under Address, and shows and stores it with the port", function()
			local env, c4, box, urls = start()
			pair(env, c4, box, FAKE)
			assert.equal("Paired with Hue Sync Box (8K) " .. SHORT .. " at " .. FAKE, fake.last_action(env))
			assert.equal(FAKE, env.Properties["Box Address"])
			assert.equal(FAKE, c4.persist.syncbox_address)
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
			all_to(urls, "https://" .. FAKE .. "/api/v1")
			assert.truthy(#box:requests_of("GET", "") > 0, "the reads reach the box")
		end)

		it("reads the box at host:port again after a restart", function()
			local persist = {}
			for k, v in pairs(PAIRED) do persist[k] = v end
			persist.syncbox_address = FAKE
			local env, _, box, urls = start({ persist = persist,
				box = { registrations = { [F.REGISTRATION_ID] = F.TOKEN } } })
			assert.equal(FAKE, env.Properties["Box Address"])
			assert.equal("Online", env.Properties["Online"])
			all_to(urls, "https://" .. FAKE .. "/api/v1")
			assert.is_true(box.requests[#box.requests].keyed)
		end)

		it("writes the box's own port, 443, without it", function()
			local env, c4, box = start()
			pair(env, c4, box, F.ADDRESS .. ":443")
			assert.equal("Paired with Hue Sync Box (8K) " .. SHORT .. " at " .. F.ADDRESS, fake.last_action(env))
			assert.equal(F.ADDRESS, c4.persist.syncbox_address)
		end)

		it("refuses a port no URL can carry and a host a release build refuses, sending nothing", function()
			local env, _, box, urls = start()
			for _, typed in ipairs({ F.ADDRESS .. ":0", F.ADDRESS .. ":65536", F.ADDRESS .. ":08443",
				F.ADDRESS .. ":", "hsb.local:8443", "10.0.2.150/x:8443", "10.0.02.150:8443" }) do
				action(env, "Pair Sync Box", { Box = "address", Address = typed })
				assert.equal("Not paired: " .. typed .. " is not an IPv4 address (four numbers, as 10.0.2.150)",
					fake.last_action(env))
			end
			assert.same({}, urls)
			assert.same({}, box.requests)
		end)

		it("lists a box the search found on another SRV port at ip:port, and pairs from the Box list", function()
			local env, c4, box, urls = start()
			lan_answers(env, c4, F.BOX_ID, F.ADDRESS, 8443)
			action(env, "Pair Sync Box", {})
			c4.advance(20000)
			local list = fake.custom_select(env, "SyncBoxList")
			assert.same({ text = "Hue Sync Box (8K) " .. SHORT .. ", Living Room Sync Box, " .. FAKE,
				value = "box:" .. F.BOX_ID }, list[1])
			action(env, "Pair Sync Box", { Box = "box:" .. F.BOX_ID })
			c4.advance(2000)
			box:hold_button()
			c4.advance(2000)
			assert.equal("Paired with Hue Sync Box (8K) " .. SHORT .. " at " .. FAKE, fake.last_action(env))
			assert.equal(FAKE, c4.persist.syncbox_address)
			all_to(urls, "https://" .. FAKE .. "/api/v1")
		end)

		it("is not used by a release build that finds it (an earlier dev build's file), which says so once", function()
			package.preload["common.build_kind"] = function() return "release" end
			local env, _, box, urls = start()
			action(env, "Pair Sync Box", { Box = "address", Address = FAKE })
			assert.equal("Not paired: " .. FAKE .. " is not an IPv4 address (four numbers, as 10.0.2.150)",
				fake.last_action(env))
			assert.same({}, urls)
			assert.same({}, box.requests)
			local said = 0
			for _, line in ipairs(lines) do
				if line:find("found syncbox/devhooks.lua of an earlier dev build; not used", 1, true) then
					said = said + 1
				end
			end
			assert.equal(1, said)
		end)
	end)

	-- #547, docs/dev-loop.md: the bridge forwards the "syncbox" tree to the
	-- devices bound on its connection 2; the device reloads itself from it.
	describe("the dev loop's syncbox tree (#547)", function()
		local function with_apply_forwarded(stub, body)
			local devloop = require("common.devloop")
			local original = devloop.apply_forwarded
			devloop.apply_forwarded = stub
			local ok, err = pcall(body)
			devloop.apply_forwarded = original
			assert(ok, err)
		end

		it("hands a syncbox bundle to the dev loop, says the new version to the bridge, and ignores other trees",
			function()
				local env, c4 = paired(nil, { bind = true })
				local got = {}
				with_apply_forwarded(function(params)
					got[#got + 1] = params
					return true, "B7"
				end, function()
					env.ExecuteCommand("DEV_RELOAD", { tree = "light", version = "L1", bundle = "{}", mac = "x" })
					assert.same({}, got)
					c4.sent = {}
					env.ExecuteCommand("DEV_RELOAD", { tree = "syncbox", version = "B7", bundle = "{}", mac = "x" })
				end)
				assert.same({ { tree = "syncbox", version = "B7", bundle = "{}", mac = "x" } }, got)
				local logs = {}
				for _, m in ipairs(c4.sent) do
					if m.command == "HUE_LOG" then logs[#logs + 1] = m end
				end
				assert.equal(1, #logs)
				assert.equal(BRIDGE, logs[1].id)
				assert.equal("Hue Sync Box: syncbox reloaded to version B7", logs[1].params.line)
				assert.equal(F.BOX_ID, logs[1].params.rid)
			end)

		-- The reload sequence of common/devloop.lua, as tests/spec/drivers_spec.lua
		-- runs it for the bridge: OnDriverDestroyed, the driver's modules
		-- forgotten, driver.lua again, then both inits with DIT_UPDATING.
		it("comes back paired after a reload, reading the box at the poller's own pace", function()
			local env, c4, box = paired(nil, { bind = true })
			c4.advance(20000)
			local before = #box:requests_of("GET", "")
			c4.advance(20000)
			local pace = #box:requests_of("GET", "") - before
			assert.truthy(pace > 0)

			env.OnDriverDestroyed()
			for name in pairs(package.loaded) do
				if (name:match("^syncbox%.") or name:match("^common%.")) and name ~= "common.log"
					and name ~= "common.devloop" then
					package.loaded[name] = nil
				end
			end
			local chunk = assert(loadfile("src/hue_syncbox/driver.lua"))
			setfenv(chunk, env)
			chunk()
			env.OnDriverInit("DIT_UPDATING")
			env.OnDriverLateInit("DIT_UPDATING")
			assert.equal("Video, high, brightness 100 % on Living Room TV", env.Properties["Status"])
			assert.equal(F.BOX_ID, env.Properties["Box ID"])
			assert.equal("Online", env.Properties["Online"])
			c4.advance(20000)
			before = #box:requests_of("GET", "")
			c4.advance(20000)
			assert.equal(pace, #box:requests_of("GET", "") - before, "one poller: the old code's stopped")
		end)
	end)

	teardown(function()
		package.preload["syncbox.devhooks"] = nil
	end)
end)
