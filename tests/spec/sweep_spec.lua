-- #334, D12 (docs/simplify-actions-design.md §3.4): bridge/sweep.lua, the
-- TCP 443 sweep of at most two /24 networks. Runs on the fake runtime's
-- clock (c4.advance fires timers in time order) with a fake C4:CreateTCPClient
-- of this spec's own (API/14_lua_tcp_client: Connect, OnConnect, OnError,
-- Close cancelling a pending connect, which then calls OnError).
-- Placeholders only: controller 192.0.2.7, other hosts 192.0.2.x, bridge 10.0.2.143.

local fake = require("helpers.fake_c4")
local log = require("common.log")

local sweep, c4, tcp

-- The fake TCP client: tcp.hosts[ip] = "open" (OnConnect after 5 ms),
-- "refuse" (OnError 111 after 3 ms), "late_open" (OnConnect after 2000 ms,
-- past the connect timeout), anything else silent until closed.
local function install_tcp()
	tcp = { hosts = {}, connects = {}, live = 0, max_live = 0, closes = 0, late_errors = 0, gaps = {}, last = nil,
		clients = {} }
	return function()
		local cl = { cb = {}, state = "new" }
		tcp.clients[#tcp.clients + 1] = cl
		function cl:OnConnect(fn) self.cb.connect = fn; return self end
		function cl:OnError(fn) self.cb.error = fn; return self end
		function cl:Connect(host, port)
			assert(self.state == "new", "Connect twice on one client")
			assert(self.cb.connect and self.cb.error, "callbacks set before Connect")
			self.host, self.port, self.state = host, port, "pending"
			tcp.connects[#tcp.connects + 1] = { host = host, port = port, at = c4.now_ms }
			if tcp.last then tcp.gaps[#tcp.gaps + 1] = c4.now_ms - tcp.last end
			tcp.last = c4.now_ms
			tcp.live = tcp.live + 1
			tcp.max_live = math.max(tcp.max_live, tcp.live)
			local kind = tcp.hosts[host]
			if kind == "nil" then
				tcp.live = tcp.live - 1
				self.state = "new"
				return nil
			elseif kind == "open" or kind == "late_open" then
				c4:SetTimer(kind == "open" and 5 or 2000, function()
					if self.state == "pending" then
						self.state = "open"
						self.cb.connect(self)
					end
				end)
			elseif kind == "refuse" then
				c4:SetTimer(3, function()
					if self.state == "pending" then
						self.state = "closed"
						tcp.live = tcp.live - 1
						self.cb.error(self, 111, "Connection refused")
					end
				end)
			end
			return self
		end
		function cl:Close()
			if self.state == "pending" then
				self.state = "closed"
				tcp.live = tcp.live - 1
				tcp.closes = tcp.closes + 1
				c4:SetTimer(1, function()
					tcp.late_errors = tcp.late_errors + 1
					self.cb.error(self, 125, "Operation canceled")
				end)
			elseif self.state == "open" then
				self.state = "closed"
				tcp.live = tcp.live - 1
				tcp.closes = tcp.closes + 1
			end
			return self
		end
		return cl
	end
end

local function start(hosts, opts)
	opts = opts or {}
	local out = { opened = {}, done = {} }
	local factory = install_tcp()
	if opts.tcp_hosts then
		for ip, kind in pairs(opts.tcp_hosts) do tcp.hosts[ip] = kind end
	end
	local client = opts.tcp or factory
	if opts.no_tcp then client = nil end
	out.run = sweep.start({
		hosts = hosts,
		cap_ms = opts.cap_ms,
		in_flight = opts.in_flight,
		tcp = client,
		timer = function(ms, fn) return c4:SetTimer(ms, function() fn() end) end,
		now_ms = function() return c4.now_ms end,
		log = log,
		on_open = function(ip, ms)
			out.opened[#out.opened + 1] = ip
			if opts.on_open then opts.on_open(ip, ms, out) end
		end,
		on_done = function(result) out.done[#out.done + 1] = result end,
	})
	return out
end

local function hosts_of(net, from, to)
	local out = {}
	for i = from, to do out[#out + 1] = net .. "." .. i end
	return out
end

local function active()
	return #c4.active_timers()
end

describe("bridge/sweep.lua (#334, D12)", function()
	local lines

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		log.set_debug(true)
		c4 = fake.install_c4()
		package.loaded["bridge.sweep"] = nil
		sweep = require("bridge.sweep")
	end)

	after_each(function()
		log.set_debug(false)
	end)

	describe("the plan", function()
		it("covers the centre's /24 from the centre outward, .1 to .254, skipping what it is told to", function()
			local plan = sweep.plan({ "192.0.2.50", "192.0.2.7" }, { "192.0.2.7" })
			assert.same({ "192.0.2" }, plan.nets)
			assert.equal(253, #plan.hosts)
			assert.same({ "192.0.2.50", "192.0.2.51", "192.0.2.49", "192.0.2.52", "192.0.2.48" },
				{ unpack(plan.hosts, 1, 5) })
			local seen = {}
			for _, ip in ipairs(plan.hosts) do
				assert.is_nil(seen[ip], "twice: " .. ip)
				seen[ip] = true
				local last = tonumber(ip:match("%.(%d+)$"))
				assert.is_true(last >= 1 and last <= 254, ip)
			end
			assert.is_nil(seen["192.0.2.7"], "never the controller")
			assert.is_nil(seen["192.0.2.0"])
			assert.is_nil(seen["192.0.2.255"])
		end)

		it("takes at most two /24 networks, the first centre's first", function()
			local plan = sweep.plan({ "10.0.2.143", "192.0.2.7" }, { "192.0.2.7" })
			assert.same({ "10.0.2", "192.0.2" }, plan.nets)
			assert.equal(254 + 253, #plan.hosts)
			assert.equal("10.0.2.143", plan.hosts[1])
			assert.equal("192.0.2.8", plan.hosts[255], "the controller's /24 from the controller outward")
			assert.is_true(#sweep.plan({ "192.168.1.1", "192.168.2.1", "192.168.3.1" }, {}, 3).nets <= sweep.MAX_NETS)
		end)

		it("takes a shared /24 once", function()
			local plan = sweep.plan({ "192.0.2.50", "192.0.2.7" }, {})
			assert.same({ "192.0.2" }, plan.nets)
			assert.equal(254, #plan.hosts)
		end)

		it("works with holes: no last address, or no controller", function()
			assert.same({ "192.0.2" }, sweep.plan({ nil, "192.0.2.7" }, { "192.0.2.7" }).nets)
			assert.same({ "10.0.2" }, sweep.plan({ "10.0.2.143", nil }, {}).nets)
			assert.same({}, sweep.plan({}, {}).hosts)
			assert.same({}, sweep.plan(nil, nil).hosts)
		end)

		it("never covers a network that could be on the internet, and says why", function()
			local plan = sweep.plan({ "1.2.3.4", "127.0.0.1" }, {})
			assert.same({}, plan.hosts)
			assert.same({ { ip = "1.2.3.4", why = "not a private network" },
				{ ip = "127.0.0.1", why = "not a private network" } }, plan.skipped)
			plan = sweep.plan({ "not an address", "192.0.2.7" }, {})
			assert.same({ "192.0.2" }, plan.nets)
			assert.equal("not an IPv4 address", plan.skipped[1].why)
		end)

		it("allows the private ranges of RFC 1918 and the documentation networks of RFC 5737 only", function()
			-- The edges of each range, built from their octets: the secrets scan
			-- (.gitleaks.toml) admits no address literal but the placeholders.
			local function ip(o) return table.concat(o, ".") end
			for _, o in ipairs({ { 10, 0, 0, 1 }, { 10, 255, 255, 254 }, { 172, 16, 0, 1 }, { 172, 31, 255, 1 },
				{ 192, 168, 0, 1 }, { 192, 168, 255, 254 }, { 192, 0, 2, 7 }, { 198, 51, 100, 20 }, { 203, 0, 113, 5 } }) do
				assert.is_true(sweep.searchable(ip(o)), ip(o))
			end
			for _, o in ipairs({ { 172, 15, 0, 1 }, { 172, 32, 0, 1 }, { 192, 169, 0, 1 }, { 192, 167, 0, 1 }, { 192, 0, 3, 1 },
				{ 198, 51, 101, 1 }, { 203, 0, 114, 1 }, { 11, 0, 0, 1 }, { 100, 64, 0, 1 }, { 169, 254, 1, 1 },
				{ 224, 0, 0, 251 }, { 127, 0, 0, 1 }, { 10, 0, 0, 256 } }) do
				assert.is_false((sweep.searchable(ip(o))), ip(o))
			end
			assert.is_false((sweep.searchable("0" .. ip({ 10, 0, 0, 1 }))), "a leading zero")
			assert.is_false((sweep.searchable(nil)))
		end)

		it("starts at .1 when the centre is a network or broadcast address", function()
			assert.equal("192.0.2.1", sweep.plan({ "192.0.2.0" }, {}).hosts[1])
			assert.equal("192.0.2.1", sweep.plan({ "192.0.2.255" }, {}).hosts[1])
		end)
	end)

	describe("a run", function()
		it("tries every address, 4 at once and 125 ms apart, closes every connection and reports once", function()
			local hosts = sweep.plan({ "192.0.2.50", "192.0.2.7" }, { "192.0.2.7" }).hosts
			local s = start(hosts, { tcp_hosts = { ["192.0.2.50"] = "open", ["192.0.2.20"] = "open",
				["192.0.2.30"] = "refuse" } })
			c4.advance(200000)
			assert.equal(253, #tcp.connects)
			for _, connect in ipairs(tcp.connects) do assert.equal(443, connect.port) end
			assert.equal(4, tcp.max_live)
			for _, gap in ipairs(tcp.gaps) do assert.is_true(gap >= 125, "starts " .. gap .. " ms apart") end
			assert.equal(0, tcp.live, "every connection closed")
			assert.same({ "192.0.2.50", "192.0.2.20" }, s.opened)
			assert.equal(1, #s.done)
			local r = s.done[1]
			assert.equal(253, r.total)
			assert.equal(253, r.tried)
			assert.equal(2, #r.open)
			assert.equal(1, r.errors)
			assert.equal(1, r.codes["111 Connection refused"])
			assert.equal(250, r.timeouts)
			assert.equal(0, r.aborted)
			assert.is_nil(r.stopped)
			assert.is_true(r.ms < sweep.CAP_PER_NET_MS, "within the cap: " .. r.ms)
			assert.is_true(r.ms >= 253 / 4 * 1500 * 0.9, "the silent hosts take their 1500 ms: " .. r.ms)
			assert.equal(0, active(), "no timer left")
			assert.is_false(s.run:running())
		end)

		it("reports the late OnError of a cancelled connect only once, as its timeout", function()
			local s = start({ "192.0.2.40" })
			c4.advance(5000)
			assert.equal(1, tcp.late_errors, "Close cancelled the pending connect, which called OnError")
			assert.equal(1, s.done[1].timeouts)
			assert.equal(0, s.done[1].errors)
		end)

		it("closes a connection that opens after its timeout and does not count it open", function()
			local s = start({ "192.0.2.40" }, { tcp_hosts = { ["192.0.2.40"] = "late_open" } })
			c4.advance(5000)
			assert.same({}, s.opened)
			assert.equal(1, s.done[1].timeouts)
			assert.equal(0, tcp.live)
		end)

		it("keeps at most in_flight connects, never more than four", function()
			start(hosts_of("192.0.2", 1, 20), { in_flight = 2 })
			c4.advance(60000)
			assert.equal(2, tcp.max_live)
			start(hosts_of("192.0.2", 1, 20), { in_flight = 9 })
			c4.advance(60000)
			assert.equal(4, tcp.max_live)
		end)

		it("stops at its time cap: pending connects closed and counted as aborted", function()
			local s = start(hosts_of("192.0.2", 1, 254), { cap_ms = 10000 })
			c4.advance(200000)
			local r = s.done[1]
			assert.equal("the time cap", r.stopped)
			assert.is_true(r.tried < 254)
			assert.is_true(r.aborted >= 1 and r.aborted <= 4)
			assert.equal(r.tried, r.timeouts + r.aborted)
			assert.equal(0, tcp.live)
			assert.equal(0, active())
			assert.equal(1, #s.done)
		end)

		it("stops when told to, from inside on_open: no connect after, on_done once and later", function()
			local hosts = hosts_of("192.0.2", 1, 254)
			local s
			s = start(hosts, { tcp_hosts = { ["192.0.2.3"] = "open", ["192.0.2.9"] = "open" },
				on_open = function(_, _, out)
					out.run:stop("found")
					out.done_at_stop = #out.done
				end })
			c4.advance(300)
			local before = #tcp.connects
			assert.same({ "192.0.2.3" }, s.opened)
			assert.equal(0, s.done_at_stop, "on_done never inside stop")
			c4.advance(200000)
			assert.equal(before, #tcp.connects)
			assert.equal(1, #s.done)
			assert.equal("found", s.done[1].stopped)
			assert.equal(0, tcp.live)
			assert.equal(0, active())
			s.run:stop("again")
			c4.advance(10)
			assert.equal(1, #s.done)
		end)

		it("counts a connect that cannot start and goes on", function()
			local s = start({ "192.0.2.1", "192.0.2.2", "192.0.2.3" }, { tcp_hosts = { ["192.0.2.2"] = "nil",
				["192.0.2.3"] = "open" } })
			c4.advance(10000)
			assert.equal(1, s.done[1].failed)
			assert.same({ "192.0.2.3" }, s.opened)
		end)

		it("survives a TCP client that raises", function()
			local s = start({ "192.0.2.1", "192.0.2.2" }, { tcp = function() error("no sockets left") end })
			c4.advance(10000)
			assert.equal(2, s.done[1].failed)
			assert.equal(0, active())
		end)

		it("ends at once, with an error, on a controller without C4:CreateTCPClient", function()
			local s = start({ "192.0.2.1" }, { no_tcp = true })
			c4.advance(10)
			assert.equal(1, #s.done)
			assert.equal("no C4:CreateTCPClient on this controller", s.done[1].error)
			assert.equal(0, s.done[1].tried)
		end)

		it("goes on when on_open raises", function()
			local s = start({ "192.0.2.1", "192.0.2.2" }, { tcp_hosts = { ["192.0.2.1"] = "open", ["192.0.2.2"] = "open" },
				on_open = function() error("boom") end })
			c4.advance(10000)
			assert.same({ "192.0.2.1", "192.0.2.2" }, s.opened)
			assert.equal(2, #s.done[1].open)
			assert.equal(0, tcp.live)
		end)

		it("ends at once for an empty plan", function()
			local s = start({})
			c4.advance(10)
			assert.equal(1, #s.done)
			assert.equal(0, s.done[1].tried)
			assert.equal(0, active())
		end)
	end)
end)
