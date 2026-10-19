-- Minimal stand-in for the DriverWorks runtime. Implements only the C4 calls
-- the drivers actually make, and records them so specs can assert on them.
-- Add a method here when a driver starts using a new documented API.

local fake = {}

local function new_c4(env)
	local c4 = {
		calls = {},
		config_info = { version = "1" },
	}

	local function record(name, ...)
		table.insert(c4.calls, { name = name, args = { ... } })
	end

	function c4:UpdateProperty(name, value)
		record("UpdateProperty", name, value)
		env.Properties[name] = value
	end

	function c4:GetDriverConfigInfo(tag)
		record("GetDriverConfigInfo", tag)
		return c4.config_info[tag]
	end

	function c4:SendToProxy(binding, command, params)
		record("SendToProxy", binding, command, params)
	end

	-- Every recorded call with the given name, in order.
	function c4.calls_to(name)
		local out = {}
		for _, call in ipairs(c4.calls) do
			if call.name == name then
				table.insert(out, call.args)
			end
		end
		return out
	end

	return c4
end

local DRIVER_MODULE_PREFIXES = { "common%.", "bridge%.", "light%." }

-- Drop cached driver modules so each load starts clean. common.log is kept so
-- a spec can silence or capture its sink before loading a driver.
local function forget_driver_modules()
	for name in pairs(package.loaded) do
		for _, prefix in ipairs(DRIVER_MODULE_PREFIXES) do
			if name ~= "common.log" and name:match("^" .. prefix) then
				package.loaded[name] = nil
			end
		end
	end
end

-- Property names and defaults declared in a driver.xml, as Director would
-- present them in Properties.
function fake.declared_properties(driver)
	local file = assert(io.open("src/" .. driver .. "/driver.xml"))
	local xml = file:read("*a")
	file:close()
	local props = {}
	for body in xml:gmatch("<property>(.-)</property>") do
		local name = body:match("<name>(.-)</name>")
		props[name] = body:match("<default>(.-)</default>") or ""
	end
	return props
end

-- Load a driver.lua into a fresh environment, the way Director would.
-- `driver` is "hue_bridge" or "hue_light"; `properties` overrides the
-- defaults from driver.xml. Returns the environment (driver globals) and
-- the fake C4.
function fake.load_driver(driver, properties)
	forget_driver_modules()

	local env = setmetatable({}, { __index = _G })
	env.Properties = fake.declared_properties(driver)
	for k, v in pairs(properties or {}) do
		assert(env.Properties[k], "property not declared in driver.xml: " .. k)
		env.Properties[k] = v
	end
	env.C4 = new_c4(env)
	env._G = env

	-- Modules loaded with require() resolve globals through the real _G, so
	-- point C4 and Properties there too, as on the controller.
	rawset(_G, "C4", env.C4)
	rawset(_G, "Properties", env.Properties)

	local chunk = assert(loadfile("src/" .. driver .. "/driver.lua"))
	setfenv(chunk, env)
	chunk()

	return env, env.C4
end

return fake
