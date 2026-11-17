-- syncbox/discovery.lua (#534, docs/hdmi-sync-stage2-design.md §3.7,
-- contracts C3): one mDNS search for _huesync._tcp.local through
-- common/mdns.lua with the rules of #490, then the identity check of each
-- address; a box is listed only once its id answered there (over the pinned
-- chain, which the identity check stands for here). The network is a
-- stand-in `net` whose sends make the LAN's responders answer; the identity
-- check is a stand-in `identity_for` answering from the LAN; timers run on
-- the fake clock (tests/helpers/fake_c4.lua, c4.advance). The box's answer
-- is [assumed] in the shape of the bridge's (docs/syncbox-api-research.md
-- §2.2: TXT name, devicetype, uniqueid, path; the first install shows it).
-- Placeholders only: box 0A1B2C3D4E5F at 10.0.2.150; other boxes in
-- 192.0.2.x and 198.51.100.x with ids put together at run time.

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

local BOX_ID = "0A1B2C3D4E5F"
local BOX_IP = "10.0.2.150"
local BINDING, GROUP, PORT = 6008, "224.0.0.251", 5353

-- Another invented id: the placeholder's first ten digits and two of its own.
local function other_id(n) return BOX_ID:sub(1, 10) .. string.format("%02X", n) end
-- An address outside the placeholders, put together from its octets.
local function dotted(...) return table.concat({ ... }, ".") end

-- DNS answers (RFC 1035 §4.1.4 compression) for _huesync._tcp.local ---------------

local TYPES = { A = 1, PTR = 12, TXT = 16, AAAA = 28, SRV = 33 }
local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end

local function packet(id, an, ar)
	local pieces, len, known = {}, 0, {}
	local function put(s) pieces[#pieces + 1] = s; len = len + #s end
	local function name(n)
		local parts = {}
		for label in n:gmatch("[^%.]+") do parts[#parts + 1] = label end
		for i = 1, #parts do
			local suffix = table.concat(parts, ".", i):lower()
			if known[suffix] then
				put(string.char(192 + math.floor(known[suffix] / 256), known[suffix] % 256))
				return
			end
			known[suffix] = len
			put(string.char(#parts[i]) .. parts[i])
		end
		put("\0")
	end
	put(u16(id) .. u16(0x8400) .. u16(1) .. u16(#an) .. u16(0) .. u16(#ar))
	name("_huesync._tcp.local")
	put(u16(12) .. u16(1))
	local function record(rec, section)
		name(rec.name)
		put(u16(TYPES[rec.type]) .. u16(section == "ar" and 0x8001 or 1) .. u16(0) .. u16(120))
		local slot = #pieces + 1
		put("\0\0")
		local start = len
		if rec.type == "PTR" then
			name(rec.target)
		elseif rec.type == "SRV" then
			put(u16(0) .. u16(0) .. u16(rec.port or 443))
			name(rec.target)
		elseif rec.type == "TXT" then
			for _, item in ipairs(rec.txt) do put(string.char(#item) .. item) end
		elseif rec.type == "A" then
			local a, b, c, d = rec.ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
			put(string.char(tonumber(a), tonumber(b), tonumber(c), tonumber(d)))
		elseif rec.type == "AAAA" then
			put(string.rep("\0", 15) .. "\1")
		end
		pieces[slot] = u16(len - start)
	end
	for _, rec in ipairs(an) do record(rec, "an") end
	for _, rec in ipairs(ar) do record(rec, "ar") end
	return table.concat(pieces)
end

-- r: { id (TXT uniqueid), name, model, ips (A records), port, txt (replaces the TXT) }
local function answer(r, query_id)
	local instance = "HueSyncBox-" .. r.id .. "._huesync._tcp.local"
	local host = r.id .. ".local"
	local ar = {
		{ name = instance, type = "SRV", port = r.port, target = host },
		{ name = instance, type = "TXT", txt = r.txt or { "name=" .. (r.name or "Sync Box"),
			"devicetype=" .. (r.model or "HSB2"), "uniqueid=" .. r.id, "path=/api" } },
		{ name = host, type = "AAAA" },
	}
	for _, ip in ipairs(r.ips or {}) do ar[#ar + 1] = { name = host, type = "A", ip = ip } end
	return packet(query_id, { { name = "_huesync._tcp.local", type = "PTR", target = instance } }, ar)
end

describe("syncbox/discovery.lua (#534)", function()
	local discovery, c4, d, lan, lines

	local function new_lan()
		return { mdns = {}, boxes = {}, hang = {}, online = true, sent = {}, calls = {}, identifies = {},
			cancels = 0 }
	end

	local function net()
		return {
			create = function(binding, address) lan.calls[#lan.calls + 1] = { "create", binding, address } end,
			connect = function(binding, port, kind)
				lan.calls[#lan.calls + 1] = { "connect", binding, port, kind }
				if lan.connect_raises then error("NetConnect refused", 0) end
				if lan.online then
					c4:SetTimer(4, function() d:status_changed(binding, port, "ONLINE") end)
				end
			end,
			send = function(binding, port, data)
				if lan.send_raises then error("no route", 0) end
				lan.calls[#lan.calls + 1] = { "send", binding, port }
				lan.sent[#lan.sent + 1] = { at = c4.now_ms, data = data }
				local qid = data:byte(1) * 256 + data:byte(2)
				for _, r in ipairs(lan.mdns) do
					c4:SetTimer(1, function()
						local bytes = r.garbage and "\0\1garbage" or answer(r, r.qid or qid)
						d:received(binding, port, bytes, r.from)
					end)
				end
			end,
			disconnect = function(binding, port) lan.calls[#lan.calls + 1] = { "disconnect", binding, port } end,
		}
	end

	-- The identity check as syncbox/identity.lua answers it (§3.3).
	local function identity_for(address, cb)
		lan.identifies[#lan.identifies + 1] = { address = address, at = c4.now_ms }
		local handle = { Cancel = function() lan.cancels = lan.cancels + 1 end }
		local box = lan.boxes[address]
		if lan.hang[address] then
			return handle
		end
		c4:SetTimer(50, function()
			if not box then
				return cb({ ok = false, reason = "unreachable", detail = "no answer" })
			end
			local model = box.model or "HSB2"
			local device = { id = box.id, name = box.name, model = model, firmware = "2.5.4", api_level = 14,
				device_type = box.device_type or model }
			if model == "HSC001" then
				return cb({ ok = false, reason = "camera", device = device })
			end
			cb({ ok = box.reason == nil or box.reason == "unknown_model", reason = box.reason or "ok", device = device })
		end)
		return handle
	end

	local function load(extra)
		package.loaded["syncbox.discovery"] = nil
		discovery = require("syncbox.discovery")
		local deps = {
			identity_for = identity_for,
			log = log,
			net = net(),
			timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end,
			now = function() return c4:GetTime() end,
		}
		for k, v in pairs(extra or {}) do deps[k] = v end
		d = discovery.new(deps)
		return d
	end

	-- A box on the LAN: answers mDNS at `ips` and the identity check at each.
	local function box(id, ips, extra)
		local r = { id = id, ips = ips, name = "Sync Box " .. id:sub(-4), model = "HSB2" }
		for k, v in pairs(extra or {}) do r[k] = v end
		lan.mdns[#lan.mdns + 1] = r
		for _, ip in ipairs(ips) do
			lan.boxes[ip] = lan.boxes[ip] or { id = r.identity_id or id, name = r.name, model = r.model,
				reason = r.reason }
		end
		return r
	end

	local function search(want, ms)
		local answers = {}
		d:search(function(list, detail) answers[#answers + 1] = { list = list, detail = detail } end, want)
		c4.advance(ms or 200000)
		return answers
	end

	local function calls(kind)
		local out = {}
		for _, call in ipairs(lan.calls) do
			if call[1] == kind then out[#out + 1] = call end
		end
		return out
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
		lan = new_lan()
		load()
	end)

	after_each(function()
		log.set_debug(false)
		log.sink = print
	end)

	describe("a search", function()
		it("finds a box by mDNS and lists it once its id answered there", function()
			box(BOX_ID, { BOX_IP }, { name = "Living Room Box" })
			assert.is_false(d:busy())
			local answers = search()
			assert.equal(1, #answers)
			assert.same({ { id = BOX_ID, name = "Living Room Box", model = "HSB2", address = BOX_IP,
				device_type = "HSB2", firmware = "2.5.4", api_level = 14 } }, answers[1].list)
			assert.equal("1 Hue sync box found", answers[1].detail.text)
			assert.equal(1, answers[1].detail.checked)
			assert.is_false(d:busy())
			-- The bridge's pattern: create once, connect UDP 5353 on 224.0.0.251, the
			-- query once ONLINE and once more, then disconnect.
			assert.same({ "create", BINDING, GROUP }, calls("create")[1])
			assert.same({ "connect", BINDING, PORT, "UDP" }, calls("connect")[1])
			assert.equal(2, #lan.sent)
			assert.equal(discovery.REPEAT_MS, lan.sent[2].at - lan.sent[1].at)
			local last = lan.calls[#lan.calls]
			assert.same({ "disconnect", BINDING, PORT }, last)
			assert.equal(1, #lan.identifies)
			assert.equal(BOX_IP, lan.identifies[1].address)
		end)

		it("is busy while it runs and answers from a timer, never inside the call", function()
			box(BOX_ID, { BOX_IP })
			local got
			d:search(function(list) got = list end)
			assert.is_true(d:busy())
			assert.is_nil(got)
			c4.advance(200000)
			assert.equal(1, #got)
		end)

		it("sends the query after ONLINE_WAIT_MS when ONLINE never comes", function()
			lan.online = false
			box(BOX_ID, { BOX_IP })
			local answers = search()
			assert.equal(1, #answers[1].list)
			assert.equal(c4.now_ms - 200000 + discovery.ONLINE_WAIT_MS, lan.sent[1].at)
		end)

		it("creates the binding once per run of the Lua", function()
			box(BOX_ID, { BOX_IP })
			search()
			search()
			assert.equal(1, #calls("create"))
			assert.equal(2, #calls("connect"))
		end)

		it("joins a search that runs, and both callers get the same answer", function()
			box(BOX_ID, { BOX_IP })
			local a, b
			d:search(function(list) a = list end)
			c4.advance(100)
			d:search(function(list) b = list end)
			c4.advance(200000)
			assert.same(a, b)
			assert.equal(1, #calls("connect"))
			assert.equal(1, #lan.identifies)
		end)

		it("sorts by name and lists at most 8", function()
			for i = 1, 10 do
				box(other_id(i), { dotted(192, 0, 2, 100 + i) }, { name = string.format("Box %02d", 11 - i) })
			end
			local answers = search()
			local list = answers[1].list
			assert.equal(discovery.MAX_LIST, #list)
			for i = 1, #list do
				assert.equal(string.format("Box %02d", i), list[i].name)
			end
			assert.equal("10 Hue sync boxes found (8 listed)", answers[1].detail.text)
		end)

		it("keeps the wanted box in the list, and checks it first", function()
			for i = 1, 10 do
				box(other_id(i), { dotted(192, 0, 2, 100 + i) }, { name = string.format("Box %02d", i) })
			end
			box(BOX_ID, { BOX_IP }, { name = "Zebra" })
			local answers = search(BOX_ID:lower())
			local list = answers[1].list
			assert.equal(discovery.MAX_LIST, #list)
			assert.equal("Zebra", list[#list].name)
			assert.equal(BOX_IP, lan.identifies[1].address)
		end)

		it("names a box by its answer, else its TXT name, else its short id", function()
			box(BOX_ID, { BOX_IP }, { name = "" })
			lan.boxes[BOX_IP].name = nil
			local answers = search()
			assert.equal("Hue Sync Box #4E5F", answers[1].list[1].name)
			lan = new_lan()
			load()
			box(BOX_ID, { BOX_IP }, { name = "From TXT" })
			lan.boxes[BOX_IP].name = nil
			answers = search()
			assert.equal("From TXT", answers[1].list[1].name)
		end)

		it("says when nothing answered", function()
			local answers = search()
			assert.same({}, answers[1].list)
			assert.equal("no Hue sync box answered", answers[1].detail.text)
			assert.equal(0, #lan.identifies)
		end)

		it("lists a box of a model it does not know, with a warning", function()
			box(BOX_ID, { BOX_IP }, { model = "unknown", reason = "unknown_model" })
			local item = search()[1].list[1]
			assert.equal(BOX_ID, item.id)
			assert.is_string(item.warning)
		end)
	end)

	describe("what is never listed (#490, contracts C3)", function()
		it("an address whose identity check failed", function()
			box(BOX_ID, { BOX_IP })
			lan.boxes[BOX_IP] = nil
			local answers = search()
			assert.same({}, answers[1].list)
			assert.equal("no answer led to a Hue sync box", answers[1].detail.text)
			assert.equal(BOX_IP, answers[1].detail.dropped[1].address)
			assert.truthy(answers[1].detail.dropped[1].why:find("unreachable", 1, true))
		end)

		it("an address where another box answers than the one announced", function()
			box(BOX_ID, { BOX_IP }, { identity_id = other_id(1) })
			local answers = search()
			assert.same({}, answers[1].list)
			assert.truthy(answers[1].detail.dropped[1].why:find("but box " .. other_id(1), 1, true))
		end)

		it("the Hue Play Screen Sync camera (O2)", function()
			box(BOX_ID, { BOX_IP }, { model = "HSC001" })
			local answers = search()
			assert.same({}, answers[1].list)
			assert.truthy(answers[1].detail.dropped[1].why:find("camera", 1, true))
		end)

		it("an answer without a 12-digit uniqueid, never checked", function()
			box(BOX_ID, { BOX_IP }, { txt = { "name=No id", "devicetype=HSB2", "uniqueid=0A1B2C", "path=/api" } })
			local answers = search()
			assert.same({}, answers[1].list)
			assert.equal(0, #lan.identifies)
			assert.truthy(answers[1].detail.dropped[1].why:find("uniqueid", 1, true))
		end)

		it("an answer that announces another port than 443, never checked", function()
			box(BOX_ID, { BOX_IP }, { port = 8443 })
			local answers = search()
			assert.same({}, answers[1].list)
			assert.equal(0, #lan.identifies)
		end)

		it("an address on the internet, never checked", function()
			box(BOX_ID, { dotted(93, 184, 216, 34) })
			local answers = search()
			assert.same({}, answers[1].list)
			assert.equal(0, #lan.identifies)
		end)

		it("an answer to another query id", function()
			box(BOX_ID, { BOX_IP }, { qid = 7 })
			local answers = search()
			assert.same({}, answers[1].list)
			assert.equal(0, #lan.identifies)
		end)

		it("a datagram that is not mDNS, without raising", function()
			box(BOX_ID, { BOX_IP }, { garbage = true })
			local answers = search()
			assert.same({}, answers[1].list)
		end)

		it("datagrams outside a search", function()
			assert.is_true(d:received(BINDING, PORT, answer({ id = BOX_ID, ips = { BOX_IP } }, 1)))
			assert.equal(1, d.late)
			assert.is_false(d:received(6001, PORT, "x"))
			assert.is_false(d:status_changed(6001, PORT, "ONLINE"))
			assert.is_true(d:status_changed(BINDING, PORT, "OFFLINE"))
		end)
	end)

	describe("the identity stage", function()
		it("checks one address at a time, one box once even at two addresses", function()
			box(BOX_ID, { BOX_IP, dotted(198, 51, 100, 9) })
			box(other_id(1), { dotted(192, 0, 2, 20) })
			local answers = search()
			assert.equal(2, #answers[1].list)
			assert.equal(2, #lan.identifies)
			assert.is_true(lan.identifies[2].at - lan.identifies[1].at >= 50)
		end)

		it("gives an address that never answers IDENTITY_WAIT_MS, cancels it, and goes on", function()
			box(other_id(1), { dotted(192, 0, 2, 20) }, { name = "A" })
			box(BOX_ID, { BOX_IP }, { name = "B" })
			lan.hang[dotted(192, 0, 2, 20)] = true
			local answers = search()
			assert.equal(1, #answers[1].list)
			assert.equal(BOX_ID, answers[1].list[1].id)
			assert.equal(1, lan.cancels)
			assert.truthy(answers[1].detail.dropped[1].why:find("no answer within", 1, true))
		end)

		it("checks at most IDENTITY_MAX addresses per search", function()
			for i = 1, discovery.IDENTITY_MAX + 4 do
				box(other_id(i), { dotted(192, 0, 2, 100 + i) })
			end
			local answers = search()
			assert.equal(discovery.IDENTITY_MAX, #lan.identifies)
			assert.equal(4, answers[1].detail.unchecked)
		end)

		it("goes on when the identity check raises", function()
			load({ identity_for = function() error("broken", 0) end })
			box(BOX_ID, { BOX_IP })
			local answers = search()
			assert.same({}, answers[1].list)
			assert.truthy(answers[1].detail.dropped[1].why:find("could not start", 1, true))
		end)

		it("drops what the identity check answers that is not a result", function()
			load({ identity_for = function(_, cb) c4:SetTimer(5, function() cb("nonsense") end) end })
			box(BOX_ID, { BOX_IP })
			assert.same({}, search()[1].list)
		end)
	end)

	describe("failures and stopping", function()
		it("answers an empty list when the connection cannot open", function()
			lan.connect_raises = true
			local answers = search()
			assert.same({}, answers[1].list)
			assert.truthy(answers[1].detail.text:find("could not open the mDNS connection", 1, true))
			assert.is_false(d:busy())
		end)

		it("answers an empty list when the query cannot be sent", function()
			lan.send_raises = true
			local answers = search()
			assert.same({}, answers[1].list)
			assert.truthy(answers[1].detail.text:find("could not send", 1, true))
		end)

		it("stops: the binding disconnected, the check cancelled, no answer afterwards", function()
			box(BOX_ID, { BOX_IP })
			lan.hang[BOX_IP] = true
			local answers = {}
			d:search(function(list) answers[#answers + 1] = list end)
			c4.advance(10000)
			assert.equal(1, #lan.identifies)
			d:stop()
			assert.equal(1, lan.cancels)
			c4.advance(400000)
			assert.same({}, answers)
			assert.is_false(d:busy())
			d:search(function(list) answers[#answers + 1] = list end)
			c4.advance(400000)
			assert.same({}, answers)
		end)

		it("disconnects when stopped during the mDNS window", function()
			box(BOX_ID, { BOX_IP })
			d:search(function() end)
			c4.advance(100)
			d:stop()
			assert.same({ "disconnect", BINDING, PORT }, lan.calls[#lan.calls])
		end)

		it("ends any search at its cap", function()
			load({ identity_for = function() end })
			for i = 1, 6 do
				box(other_id(i), { dotted(192, 0, 2, 100 + i) })
			end
			local answers = search(nil, discovery.JOB_CAP_MS + 1000)
			assert.equal(1, #answers)
			assert.is_false(d:busy())
		end)

		it("needs identity_for", function()
			assert.has_error(function() discovery.new({}) end)
		end)
	end)

	describe("the default adapters", function()
		it("use the controller's network calls and timers", function()
			local env
			c4, env = fake.install_c4()
			package.loaded["syncbox.discovery"] = nil
			discovery = require("syncbox.discovery")
			d = discovery.new({ identity_for = identity_for, log = log })
			env.OnConnectionStatusChanged = function(...) d:status_changed(...) end
			env.ReceivedFromNetwork = function(...) d:received(...) end
			lan.boxes[BOX_IP] = { id = BOX_ID, name = "Living Room Box" }
			local got
			d:search(function(list) got = list end)
			c4.net_status(BINDING, PORT, "ONLINE")
			local sent = c4.network[BINDING].ports[PORT].sent
			assert.equal(1, #sent)
			local qid = sent[1]:byte(1) * 256 + sent[1]:byte(2)
			c4.net_receive(BINDING, PORT, answer({ id = BOX_ID, ips = { BOX_IP } }, qid))
			c4.advance(200000)
			assert.equal(1, #got)
			assert.equal(GROUP, c4.network[BINDING].address)
			assert.equal("closed", c4.network[BINDING].ports[PORT].state)
		end)
	end)

	describe("helpers", function()
		it("parse_ipv4 takes only plain dotted addresses", function()
			assert.equal(BOX_IP, discovery.parse_ipv4(" " .. BOX_IP .. " "))
			for _, bad in ipairs({ "10.0.2", "10.0.02.150", "192.0.2.256", "a.b.c.d", "10.0.2.150.1", 10, "" }) do
				assert.is_nil(discovery.parse_ipv4(bad))
			end
		end)

		it("normalise_id takes 12 hex digits, upper case", function()
			assert.equal(BOX_ID, discovery.normalise_id(BOX_ID:lower()))
			assert.is_nil(discovery.normalise_id("0A1B2C3D4E5"))
			assert.is_nil(discovery.normalise_id("0A1B2C3D4E5G"))
			assert.is_nil(discovery.normalise_id(nil))
		end)
	end)

	-- #547, docs/fakebox-design.md §7: the VM's fake box answers on 8443 and
	-- announces that port; a dev build checks and lists it at "ip:port".
	describe("a dev build's syncbox/devhooks.lua (#547)", function()
		local blocked

		before_each(function()
			blocked = package.preload["syncbox.devhooks"]
			package.preload["syncbox.devhooks"], package.loaded["syncbox.devhooks"] = nil, nil
			load()
		end)

		after_each(function()
			package.preload["syncbox.devhooks"], package.loaded["syncbox.devhooks"] = blocked, nil
		end)

		it("checks and lists a box that announces another SRV port at ip:port", function()
			local r = box(BOX_ID, { BOX_IP }, { port = 8443, name = "Fake Box" })
			lan.boxes[BOX_IP .. ":8443"], lan.boxes[BOX_IP] = lan.boxes[BOX_IP], nil
			local answers = search()
			assert.equal(1, #lan.identifies)
			assert.equal(BOX_IP .. ":8443", lan.identifies[1].address)
			assert.same({ { id = BOX_ID, name = r.name, model = "HSB2", address = BOX_IP .. ":8443",
				device_type = "HSB2", firmware = "2.5.4", api_level = 14 } }, answers[1].list)
			assert.same({}, answers[1].detail.dropped)
		end)

		-- tools/fakebox.py serves several boxes from the VM's one address, each
		-- on its own port: each is its own candidate (F2, #547).
		it("checks and lists several boxes on one address, each at its own port", function()
			local second = other_id(1)
			box(BOX_ID, { BOX_IP }, { port = 8443, name = "Fake A" })
			box(second, { BOX_IP }, { port = 8444, name = "Fake B" })
			lan.boxes[BOX_IP .. ":8443"] = { id = BOX_ID, name = "Fake A", model = "HSB2" }
			lan.boxes[BOX_IP .. ":8444"] = { id = second, name = "Fake B", model = "HSB2" }
			lan.boxes[BOX_IP] = nil
			local answers = search()
			local listed = {}
			for _, item in ipairs(answers[1].list) do listed[#listed + 1] = item.id .. "@" .. item.address end
			assert.same({ BOX_ID .. "@" .. BOX_IP .. ":8443", second .. "@" .. BOX_IP .. ":8444" }, listed)
			assert.equal(2, #lan.identifies)
		end)

		it("keeps a box on 443 at its bare address, and one id once per address", function()
			box(BOX_ID, { BOX_IP }, { port = 443 })
			local answers = search()
			assert.equal(BOX_IP, answers[1].list[1].address)
			assert.equal(1, #lan.identifies)
			assert.equal(BOX_IP, lan.identifies[1].address)
		end)

		it("still drops a port no URL can carry", function()
			box(BOX_ID, { BOX_IP }, { port = 0 })
			local answers = search()
			assert.same({}, answers[1].list)
			assert.equal(0, #lan.identifies)
			assert.equal("announced port 0", answers[1].detail.dropped[1].why)
		end)
	end)

	teardown(function()
		package.preload["syncbox.devhooks"] = nil
	end)
end)
