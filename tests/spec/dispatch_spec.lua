local function fresh_dispatch()
	package.loaded["common.dispatch"] = nil
	return require("common.dispatch")
end

describe("common.dispatch", function()
	local log = require("common.log")
	local logged

	before_each(function()
		logged = {}
		log.sink = function(line) table.insert(logged, line) end
	end)

	it("routes Composer actions (LUA_ACTION) by action name", function()
		local dispatch = fresh_dispatch()
		local got
		dispatch.commands["Pair_Bridge"] = function(params) got = params end

		dispatch.execute_command("LUA_ACTION", { ACTION = "Pair Bridge", X = "1" })

		assert.same({ X = "1" }, got)
	end)

	it("passes property values to the matching handler", function()
		local dispatch = fresh_dispatch()
		local got
		dispatch.properties["Bridge_IP_Address"] = function(value) got = value end

		dispatch.property_changed("Bridge IP Address", "192.0.2.10")

		assert.equal("192.0.2.10", got)
	end)

	it("contains handler errors and logs them", function()
		local dispatch = fresh_dispatch()
		dispatch.proxy["BOOM"] = function() error("kaput") end

		assert.has_no.errors(function()
			dispatch.received_from_proxy(5001, "BOOM", {})
		end)
		assert.truthy(logged[1]:match("kaput"))
	end)

	-- #483 D-7: a driver says which binding each proxy command is taken on.
	it("drops a proxy command its driver does not take on that binding, before any handler runs", function()
		local dispatch = fresh_dispatch()
		local seen = {}
		dispatch.proxy["ON"] = function(binding) seen[#seen + 1] = binding end
		dispatch.received_from_proxy(200, "ON", {})
		assert.same({ 200 }, seen, "without a rule (the bridge) every binding is taken")
		dispatch.proxy_binding_ok = function(binding) return binding == 5001 end
		dispatch.received_from_proxy(200, "ON", {})
		dispatch.received_from_proxy("5001", "ON", {})
		assert.same({ 200, "5001" }, seen, "the rule reads the binding as a number")
	end)
end)
