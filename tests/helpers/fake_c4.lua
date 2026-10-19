-- Minimal stand-in for the DriverWorks runtime. Implements only the C4 calls
-- the drivers actually make, and records them so specs can assert on them.
-- Add a method here when a driver starts using a new documented API.

local json = require("dkjson")

local fake = {}

-- A C4LuaUrl look-alike: records the request, and lets a spec drive the
-- response through respond_headers()/chunk()/done(), or respond() for the
-- common one-shot case.
local function new_transfer(c4)
	local t = {
		options = {},
		callbacks = {},
		cancelled = false,
		started = false,
	}

	local function setter(name)
		return function(self, fn)
			self.callbacks[name] = fn
			return self
		end
	end
	t.OnDone = setter("done")
	t.OnHeaders = setter("headers")
	t.OnBody = setter("body")
	t.OnBodyChunk = setter("chunk")

	function t:SetOption(name, value)
		self.options[name] = value
		return self
	end

	function t:SetOptions(opts)
		for k, v in pairs(opts) do
			self.options[k] = v
		end
		return self
	end

	local function start(self, method, url, data, headers)
		assert(not self.started, "transfer already started")
		self.started = true
		self.method, self.url, self.data, self.headers = method, url, data, headers or {}
		table.insert(c4.transfers, self)
		return self
	end
	function t:Get(url, headers) return start(self, "GET", url, nil, headers) end
	function t:Post(url, data, headers) return start(self, "POST", url, data, headers) end
	function t:Put(url, data, headers) return start(self, "PUT", url, data, headers) end
	function t:Delete(url, headers) return start(self, "DELETE", url, nil, headers) end
	function t:Custom(url, method, data, headers) return start(self, method, url, data, headers) end

	function t:Cancel()
		self.cancelled = true
		return self
	end

	function t:TicketId()
		return self.started and 1 or 0
	end

	-- Spec-side drivers of the response.
	t.responses = {}

	function t:respond_headers(code, headers)
		local response = { code = code, headers = headers or {} }
		table.insert(self.responses, response)
		if self.callbacks.headers then
			local abort = self.callbacks.headers(self, response)
			if abort then self.cancelled = true end
		end
		return response
	end

	function t:chunk(data)
		assert(#self.responses > 0, "respond_headers() before chunk()")
		if self.callbacks.chunk and not self.cancelled then
			local abort = self.callbacks.chunk(self, self.responses[#self.responses], data)
			if abort then self.cancelled = true end
		end
	end

	function t:done(err_code, err_msg)
		if self.callbacks.done then
			self.callbacks.done(self, self.responses, err_code or 0, err_msg)
		end
	end

	-- Complete the transfer with one response. Mirrors the controller: with no
	-- OnBodyChunk callback the body is aggregated into response.body.
	function t:respond(code, body, headers)
		local response = self:respond_headers(code, headers)
		if self.callbacks.chunk then
			self:chunk(body or "")
		else
			response.body = body or ""
			if self.callbacks.body then
				self.callbacks.body(self, response)
			end
		end
		self:done(0, nil)
	end

	return t
end

local function new_c4(env)
	local c4 = {
		calls = {},
		config_info = { version = "1" },
		transfers = {},
		timers = {},
		persist = {},
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

	function c4:url()
		return new_transfer(c4)
	end

	function c4:SetTimer(delay_ms, callback, repeating)
		assert(delay_ms > 0, "timer delay must be > 0")
		local timer = { delay = delay_ms, callback = callback, repeating = repeating or false, active = true }
		function timer:Cancel()
			self.active = false
		end
		table.insert(c4.timers, timer)
		record("SetTimer", delay_ms, repeating or false)
		return timer
	end

	function c4:PersistSetValue(name, value, encrypted)
		record("PersistSetValue", name, value, encrypted or false)
		c4.persist[name] = value
	end

	function c4:PersistGetValue(name, encrypted)
		record("PersistGetValue", name, encrypted or false)
		return c4.persist[name]
	end

	function c4:PersistDeleteValue(name)
		record("PersistDeleteValue", name)
		c4.persist[name] = nil
	end

	function c4:JsonEncode(value)
		return json.encode(value)
	end

	function c4:JsonDecode(text)
		local value, _, err = json.decode(text)
		if err then
			return nil, err
		end
		return value
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

	-- The most recent transfer started, or nil.
	function c4.last_transfer()
		return c4.transfers[#c4.transfers]
	end

	-- Fire every active timer once, as if its delay had elapsed. Non-repeating
	-- timers are retired; repeating ones stay armed.
	function c4.fire_timers()
		local due = {}
		for _, timer in ipairs(c4.timers) do
			if timer.active then table.insert(due, timer) end
		end
		for _, timer in ipairs(due) do
			if not timer.repeating then timer.active = false end
			timer.callback(timer, 0)
		end
		return #due
	end

	function c4.active_timers()
		local out = {}
		for _, timer in ipairs(c4.timers) do
			if timer.active then table.insert(out, timer) end
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

-- A fake C4 for module-level specs that don't load a whole driver. Also
-- installs it as the global C4 so the module under test can see it.
function fake.install_c4(properties)
	local env = { Properties = properties or {} }
	env.C4 = new_c4(env)
	rawset(_G, "C4", env.C4)
	rawset(_G, "Properties", env.Properties)
	return env.C4, env
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
