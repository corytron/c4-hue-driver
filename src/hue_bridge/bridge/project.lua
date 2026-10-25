-- Project access shared by the registry-owning bridge modules (lights.lua,
-- scenes.lua, zone_lights.lua): the project calls of docs/import-design.md
-- §13 with their defaults to the real C4 calls, and the pcall-wrapped reads
-- the modules make of them, every failed lookup reading as "unknown". Until
-- 2026-10-24 scenes.lua and zone_lights.lua each carried a byte-identical
-- copy (docs/reviews/slim-scenes-zones.md, row 6), and lights.lua its own
-- until 2026-10-25 (docs/reviews/diff-review-2026-10-24.md, row 10).
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
-- scenes and group devices alike); an empty table answered means nothing is
-- bound. nil, "failed" when the lookup raised; nil, "unknown" when it
-- answered anything but a table, once. On OS 3.4.2 GetBoundConsumerDevices
-- answers nil for a binding with nothing bound [verified: hardware
-- 2026-10-25, the house bridge's empty bindings 2 and 77; API 32/_3 says
-- the same], but a single nil read as "nothing bound" would let one
-- transient nil at startup mark every entry unbound (code analysis
-- 2026-10-22 item 14, issue #48). So a nil is "unknown" until a second
-- lookup at least NIL_CONFIRM_S seconds after the first nil also answers
-- nil: then it is "nothing bound" ({}). Any table answered resets that. The
-- memory lives on ctx.project, which the three modules share in the driver,
-- so one module's lookup confirms another's. Actions that only add (Link
-- Devices, a hello's adoption) may take "unknown" as nothing bound: they
-- find nothing to adopt either way.
project.NIL_CONFIRM_S = 5

function project:bound_set()
	local calls = self.ctx.project
	local ok, raw = self:call("bound")
	if not ok then
		return nil, "failed"
	end
	if type(raw) ~= "table" then
		local now = (rawget(calls, "clock") or os.time)()
		local since = rawget(calls, "bound_nil_since")
		if since and now - since >= project.NIL_CONFIRM_S then
			return {}
		end
		if not since then
			calls.bound_nil_since = now
		end
		return nil, "unknown"
	end
	calls.bound_nil_since = nil
	local out = {}
	for id in pairs(raw) do
		out[tonumber(id) or id] = true
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
