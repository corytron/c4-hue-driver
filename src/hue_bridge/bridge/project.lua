-- Project access shared by the registry-owning bridge modules (scenes.lua,
-- zone_lights.lua; lights.lua still carries its own copy): the project calls
-- of docs/import-design.md §13 with their defaults to the real C4 calls, and
-- the pcall-wrapped reads the modules make of them, every failed lookup
-- reading as "unknown". Until 2026-10-24 scenes.lua and zone_lights.lua each
-- carried a byte-identical copy (docs/reviews/slim-scenes-zones.md, row 6).
-- driver.lua always passes its own `project_calls`; the defaults serve the
-- specs and the round trips, which build the modules without a project table.

local project = {}
project.__index = project

-- Every project call `ctx.project` lacks defaults to the real C4 call;
-- `binding` is the bridge's consumer binding, for bound and unbind. Returns
-- ctx.project. [verified: hardware, docs/design.md "Project APIs"] for every
-- shape below.
function project.defaults(ctx, binding)
	ctx.project = ctx.project or {}
	local calls = ctx.project
	calls.rooms = calls.rooms or function()
		return C4:GetDevicesByC4iName("roomdevice.c4i")
	end
	calls.hierarchy = calls.hierarchy or function()
		return C4:GetProjectHierarchy()
	end
	calls.devices = calls.devices or function(filter)
		return C4:GetDevices(filter)
	end
	calls.bound = calls.bound or function()
		return C4:GetBoundConsumerDevices(C4:GetDeviceID(), binding)
	end
	calls.unbind = calls.unbind or function(device_id)
		C4:Unbind(device_id, binding)
	end
	calls.rename = calls.rename or function(id, name)
		C4:RenameDevice(id, name)
	end
	calls.display_name = calls.display_name or function(id)
		return C4:GetDeviceDisplayName(id)
	end
	return calls
end

-- A module's view of ctx.project: `prefix` ("scenes", "zone_lights") names
-- the module in the warning a failed call logs. The calls and the log are
-- read from ctx at each use.
function project.new(ctx, prefix)
	return setmetatable({ ctx = ctx, prefix = prefix }, project)
end

-- pcall(ctx.project[name], ...): true, result; or false, nil after a warning.
function project:call(name, ...)
	local ok, result = pcall(self.ctx.project[name], ...)
	if not ok then
		self.ctx.log.warn("%s: project.%s failed: %s", self.prefix, name, tostring(result))
		return false, nil
	end
	return true, result
end

-- { [room_id] = name } with numeric ids; empty when unknown.
function project:rooms()
	local _, raw = self:call("rooms")
	local out = {}
	if type(raw) == "table" then
		for id, name in pairs(raw) do
			local n = tonumber(id)
			if n and name ~= nil then
				out[n] = tostring(name)
			end
		end
	end
	return out
end

-- { [device_id] = true } of everything bound to the bridge's binding (lights,
-- scenes and group devices alike); nil when the lookup failed.
function project:bound_set()
	local ok, raw = self:call("bound")
	if not ok then
		return nil
	end
	local out = {}
	if type(raw) == "table" then
		for id in pairs(raw) do
			out[tonumber(id) or id] = true
		end
	end
	return out
end

-- The project's devices of one driver file ("hue_scene.c4z") as
-- { [device_id] = info }, or nil when the call failed or returned nothing:
-- unknown, never "deleted" (docs/scenes-design.md §5).
function project:devices_of(driver_file)
	local ok, raw = self:call("devices", { C4iNames = driver_file })
	if not ok or type(raw) ~= "table" or next(raw) == nil then
		return nil
	end
	local out = {}
	for id, info in pairs(raw) do
		out[tonumber(id) or id] = info
	end
	return out
end

-- A device's Composer name, or nil when unknown.
function project:display_name(id)
	if not id then
		return nil
	end
	local ok, name = self:call("display_name", id)
	if ok and name ~= nil and name ~= "" then
		return tostring(name)
	end
	return nil
end

return project
