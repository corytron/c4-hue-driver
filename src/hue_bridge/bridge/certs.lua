-- Where the Signify CA bundle lives on the controller.
--
-- The preferred copy ships inside the .c4z as certs/hue_ca_bundle.pem; the
-- archive is extracted to /opt/control4/var/drivers/c4z/<driver_name>/ and
-- C4:url resolves ssl_cabundle relative to that directory (OS 3.4.2, spike
-- run 4). A second copy, embedded in bridge/ca_bundle.lua, is written into
-- the sandbox at startup for the ssl_cacerts fallback, which needs an
-- absolute path.

local certs = {}

certs.FILE = "hue_ca_bundle.pem"
certs.SHIPPED = "certs/" .. certs.FILE

local function driver_name()
	local ok, file = pcall(function() return C4:GetDriverFileName() end)
	if ok and type(file) == "string" and file ~= "" then
		return (file:gsub("%.c4z$", ""))
	end
	return "hue_bridge"
end

local function join(dir, name)
	return (dir:gsub("/+$", "")) .. "/" .. name
end

function certs.sandbox_path()
	return join(C4:GetSandboxDir(), certs.FILE)
end

-- The extracted archive's directory.
function certs.c4z_dir()
	return join(C4:GetC4zDir(), driver_name())
end

local function read_all(name)
	local fh = C4:FileOpen(name)
	if fh == -1 then
		return nil
	end
	C4:FileSetPos(fh, 0)
	local size = C4:FileGetSize(fh)
	local data = ""
	if size and size > 0 then
		data = C4:FileRead(fh, size)
	end
	C4:FileClose(fh)
	return data
end

-- Switch the File API to an alias directory. Returns true on success.
local function set_dir(alias)
	local ok, err = pcall(function() return C4:FileSetDir(alias) end)
	if not ok then
		return nil, tostring(err)
	end
	return true
end

-- Earlier spike builds wrote a copy into the c4z directory; remove it so the
-- probe can tell the shipped file from a written one. Best effort.
local function remove_c4z_copy()
	if not set_dir("C4Z") then
		return false
	end
	local removed = false
	if C4:FileExists(certs.FILE) then
		C4:FileDelete(certs.FILE)
		removed = true
	end
	set_dir("SANDBOX")
	return removed
end

-- Ensure the sandbox copy exists and matches the embedded bundle.
-- Returns { sandbox = path|nil, removed_c4z = bool, errors = {...} }.
function certs.install()
	local bundle = require("bridge.ca_bundle")
	local result = { errors = {}, removed_c4z = remove_c4z_copy() }
	local path = certs.sandbox_path()

	if C4:FileExists(certs.FILE) and read_all(certs.FILE) == bundle then
		result.sandbox = path
		return result
	end
	if C4:FileExists(certs.FILE) then
		-- Stale or truncated: FileOpen appends, so remove it first.
		C4:FileDelete(certs.FILE)
	end
	local fh = C4:FileOpen(certs.FILE)
	if fh == -1 then
		result.errors[#result.errors + 1] = "cannot create " .. path
		return result
	end
	local written = C4:FileWriteString(fh, bundle)
	C4:FileClose(fh)
	if written ~= #bundle then
		result.errors[#result.errors + 1] =
			string.format("short write to %s (%s of %d bytes)", path, tostring(written), #bundle)
		return result
	end
	result.sandbox = path
	return result
end

local function list_dir()
	local names = C4:FileList()
	if type(names) ~= "table" then return tostring(names) end
	local out = {}
	for _, name in pairs(names) do out[#out + 1] = tostring(name) end
	table.sort(out)
	return #out .. " files: " .. table.concat(out, ", ")
end

-- Facts about where the controller keeps this driver's files, for the
-- Diagnose Certificates action. Returns an array of strings.
function certs.diagnose()
	local lines = {}
	local function add(fmt, ...) lines[#lines + 1] = string.format(fmt, ...) end
	local function try(label, fn)
		local ok, value = pcall(fn)
		add("%s: %s", label, ok and tostring(value) or ("error: " .. tostring(value)))
	end
	try("GetSandboxDir", function() return C4:GetSandboxDir() end)
	try("GetC4zDir", function() return C4:GetC4zDir() end)
	try("c4z directory", certs.c4z_dir)
	try("GetDriverFileName", function() return C4:GetDriverFileName() end)
	try("GetDeviceID", function() return C4:GetDeviceID() end)
	try("embedded bundle bytes", function() return #require("bridge.ca_bundle") end)
	try("SANDBOX bundle exists", function() return C4:FileExists(certs.FILE) end)
	try("SANDBOX bundle bytes", function()
		local data = read_all(certs.FILE)
		return data and #data or "unreadable"
	end)
	try("SANDBOX listing", list_dir)
	if set_dir("C4Z") then
		try("C4Z listing", list_dir)
		try("C4Z stale bundle exists", function() return C4:FileExists(certs.FILE) end)
		set_dir("SANDBOX")
	else
		add("FileSetDir(C4Z): failed")
	end
	return lines
end

return certs
