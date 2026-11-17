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
local NOT_YET = "Not done: routing through the box comes in a later 2.0 beta"
local HOUR = 3600000

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
-- bound to the bridge; opts.debug: Debug Mode On from the start. Returns env, c4, the box handle.
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

		it("declares the stage 2 rows in S2 §5's order, all read-only but Debug Mode", function()
			local names = {}
			for _, body in ipairs(each(xml(), "property")) do
				names[#names + 1] = field(body, "name")
				assert.equal(field(body, "name") == "Debug Mode" and "false" or "true", field(body, "readonly"),
					field(body, "name"))
			end
			assert.same({ "Driver Version", "Debug Mode", "Status", "Online", "Last Action", "Last Action (2)",
				"Last Action (3)", "Last Action (4)", "Last Action (5)", "Last Action (6)", "Sync Box", "Model", "Firmware",
				"Box ID", "Box Address", "Wiring", "Sync", "Inputs", "Bridge Link", "Input Switching" }, names)
		end)

		it("offers Pair Sync Box, Diagnostics and Forget Pairing, and nothing for programming yet", function()
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

	describe("the proxies send nothing in stage 2 (S2 §1)", function()
		it("answers ON, SET_INPUT and a UI Button press with Last Action only, logged with every parameter",
			function()
			local env, c4, box = paired(nil, { bind = true, debug = true })
			local requests, sent = #box.requests, #to_bridge(c4)
			c4.calls = {}
			env.ReceivedFromProxy(5001, "ON", {})
			assert.equal(NOT_YET, fake.last_action(env))
			env.Properties["Last Action"] = ""
			env.ReceivedFromProxy(5001, "SET_INPUT", { INPUT = "1001", OUTPUT = "2000", AUDIO = "False", VIDEO = "True",
				PREV_DEV_LIST = "1201,1301" })
			assert.equal(NOT_YET, fake.last_action(env))
			for binding = 5002, 5005 do
				env.Properties["Last Action"] = ""
				env.ReceivedFromProxy(binding, "SELECT", { ["Device ID"] = "7", Menu = "watch" })
				assert.equal(NOT_YET, fake.last_action(env), binding)
			end
			assert.same({}, c4.calls_to("SendToProxy"), "no notify")
			assert.equal(requests, #box.requests, "nothing to the box")
			assert.equal(sent, #to_bridge(c4), "nothing to the bridge")
			local line = logged("proxy 5001 SET_INPUT at ")
			assert.truthy(line)
			assert.truthy(line:find("AUDIO=False INPUT=1001 OUTPUT=2000 PREV_DEV_LIST=1201,1301 VIDEO=True", 1, true), line)
			assert.truthy(line:match(" at %d+ ms: "), line)
			assert.truthy(logged("proxy 5003 SELECT at "))
		end)

		it("takes each command only on its own binding, and notes the rest without a word", function()
			local env, c4 = paired(nil, { debug = true })
			env.Properties["Last Action"] = ""
			env.ReceivedFromProxy(5001, "SELECT", {})
			env.ReceivedFromProxy(5002, "SET_INPUT", { INPUT = "1000" })
			env.ReceivedFromProxy(5001, "GET_AUDIO_INPUTS", {})
			env.ReceivedFromProxy(5001, "BINDING_CHANGE_ACTION", { BINDING_ID = "1000", IS_BOUND = "True" })
			env.ReceivedFromProxy(5001, "DO_PUSH", {})
			assert.equal("", fake.last_action(env))
			assert.same({}, c4.calls_to("SendToProxy"))
			assert.truthy(logged("proxy 5002 SET_INPUT at "), "logged before it is dropped")
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
