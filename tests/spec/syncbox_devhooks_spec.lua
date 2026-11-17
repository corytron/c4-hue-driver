-- syncbox/devhooks.lua (#547, docs/fakebox-design.md §7): what a dev build
-- of the Hue Sync Box driver takes beyond a release build, so it can pair
-- with the VM's fake box on a port other than 443. The module alone here;
-- the driver and the search with it and without it are in
-- syncbox_driver_spec.lua and syncbox_discovery_spec.lua ("a dev build's
-- syncbox/devhooks.lua"), whose other cases run as a release build, without
-- it. Placeholders only: box 10.0.2.150, the VM 192.0.2.7.

if not package.path:find("src/hue_syncbox/?.lua", 1, true) then
	package.path = "src/hue_syncbox/?.lua;" .. package.path
end

local log = require("common.log")

describe("syncbox/devhooks.lua (#547)", function()
	local devhooks, lines, saved_preload

	-- A fresh copy of the module, in a package whose common/build_kind.lua
	-- says `kind` (nil: none, a driver run from src/). Returns ok, the module
	-- or the error.
	local function load(kind)
		package.loaded["syncbox.devhooks"], package.loaded["common.build_kind"] = nil, nil
		package.preload["syncbox.devhooks"] = nil
		package.preload["common.build_kind"] = kind and function() return kind end or nil
		return pcall(require, "syncbox.devhooks")
	end

	before_each(function()
		lines = {}
		log.sink = function(line) lines[#lines + 1] = line end
		-- Another spec in this process may have kept the module out (a release build).
		saved_preload = package.preload["syncbox.devhooks"]
		local ok
		ok, devhooks = load(nil)
		assert.is_true(ok, tostring(devhooks))
	end)

	after_each(function()
		package.loaded["syncbox.devhooks"], package.loaded["common.build_kind"] = nil, nil
		package.preload["syncbox.devhooks"], package.preload["common.build_kind"] = saved_preload, nil
		log.sink = print
	end)

	describe("which builds use it", function()
		it("loads from src/ and in a dev build, saying nothing", function()
			for _, kind in ipairs({ false, "dev" }) do
				local ok, hooks = load(kind or nil)
				assert.is_true(ok, tostring(hooks))
				assert.is_function(hooks.parse_address)
			end
			assert.same({}, lines)
		end)

		it("refuses to load in a release build, says so once, and fails every later require", function()
			local ok, err = load("release")
			assert.is_false(ok)
			assert.equal("syncbox/devhooks.lua is not used in a release build", err)
			assert.equal(1, #lines)
			assert.truthy(lines[1]:find("this release build found syncbox/devhooks.lua of an earlier dev build; not used",
				1, true), lines[1])
			-- Lua 5.1 keeps it marked as failed: a second require raises without
			-- running the module again, so nothing more is said.
			assert.is_false((pcall(require, "syncbox.devhooks")))
			assert.equal(1, #lines)
		end)
	end)

	describe("parse_address (Pair Sync Box's Address)", function()
		it("takes host:port, the host as a release build checks it and the port 1 to 65535", function()
			assert.equal("10.0.2.150:8443", devhooks.parse_address("10.0.2.150:8443"))
			assert.equal("192.0.2.7:8443", devhooks.parse_address("  192.0.2.7:8443 "))
			assert.equal("10.0.2.150:1", devhooks.parse_address("10.0.2.150:1"))
			assert.equal("10.0.2.150:65535", devhooks.parse_address("10.0.2.150:65535"))
		end)

		it("leaves the box's own port, 443, out", function()
			assert.equal("10.0.2.150", devhooks.parse_address("10.0.2.150:443"))
		end)

		it("answers a plain address as discovery.parse_ipv4 does", function()
			local discovery = require("syncbox.discovery")
			for _, value in ipairs({ "10.0.2.150", " 10.0.2.150 ", "10.0.02.150", "10.0.2", "a.b.c.d", "", 7 }) do
				assert.same({ discovery.parse_ipv4(value) }, { devhooks.parse_address(value) }, tostring(value))
			end
		end)

		it("refuses a port no URL can carry and any host a release build refuses", function()
			for _, bad in ipairs({ "10.0.2.150:0", "10.0.2.150:65536", "10.0.2.150:08443", "10.0.2.150:99999999",
				"10.0.2.150:", "10.0.2.150:84a3", "10.0.2.150:-1", "10.0.2.150:8443:1", "hsb.local:8443",
				"10.0.02.150:8443", "10.0.2.150/x:8443", "user@10.0.2.150:8443", "[::1]:8443", ":8443" }) do
				local address, why = devhooks.parse_address(bad)
				assert.is_nil(address, bad)
				assert.is_string(why, bad)
			end
			assert.equal("not a port (1 to 65535)", select(2, devhooks.parse_address("10.0.2.150:0")))
		end)
	end)

	describe("srv_address (a search's candidate)", function()
		it("is ip:port for another SRV port and the bare ip for 443", function()
			assert.equal("192.0.2.7:8443", devhooks.srv_address("192.0.2.7", 8443))
			assert.equal("192.0.2.7", devhooks.srv_address("192.0.2.7", 443))
		end)

		it("is nil without a port, for one no URL can carry, or without an address", function()
			for _, port in ipairs({ 0, 65536, -1, 8443.5, "x" }) do
				assert.is_nil(devhooks.srv_address("192.0.2.7", port), tostring(port))
			end
			assert.is_nil(devhooks.srv_address("192.0.2.7", nil))
			assert.is_nil(devhooks.srv_address(nil, 8443))
			assert.is_nil(devhooks.srv_address("", 8443))
		end)
	end)

	describe("port", function()
		it("takes 1 to 65535 as a number or its digits, nothing else", function()
			assert.equal(8443, devhooks.port(8443))
			assert.equal(8443, devhooks.port("8443"))
			assert.equal(65535, devhooks.port("65535"))
			for _, bad in ipairs({ 0, "0", 65536, "08443", " 8443", "8443 ", 8443.5, -8443, {}, true }) do
				assert.is_nil(devhooks.port(bad), tostring(bad))
			end
			assert.is_nil(devhooks.port(nil))
		end)
	end)
end)
