-- Puts the Signify CA bundle where C4:url might be able to open it.
--
-- Hardware runs on OS 3.4.2 showed that neither a path "relative to the
-- .c4z" nor the absolute sandbox path works for C4:url's CA options (see
-- bridge/ca_probe.lua). So the bundle is embedded (bridge/ca_bundle.lua) and
-- written with the File API into both places a driver may write to: its
-- sandbox directory and its C4Z directory (…/drivers/c4z/<driver_name>/,
-- reachable through the "C4Z" alias of C4:FileSetDir). The probe then finds
-- out which path C4:url accepts.

local certs = {}

certs.FILE = "hue_ca_bundle.pem"

local function driver_name()
	local ok, file = pcall(function() return C4:GetDriverFileName() end)
	if ok and type(file) == "string" and file ~= "" then
		return (file:gsub("%.c4z$", ""))
	end
	return "hue_bridge"
end

function certs.sandbox_path()
	return C4:GetSandboxDir() .. "/" .. certs.FILE
end

function certs.c4z_path()
	return C4:GetC4zDir() .. "/" .. driver_name() .. "/" .. certs.FILE
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

-- Write `bundle` as certs.FILE in the File API's current directory unless an
-- identical file is already there. Returns true, or nil and a reason.
local function write_here(bundle, where)
	if C4:FileExists(certs.FILE) then
		if read_all(certs.FILE) == bundle then
			return true
		end
		-- Stale or truncated: FileOpen appends, so remove it first.
		C4:FileDelete(certs.FILE)
	end
	local fh = C4:FileOpen(certs.FILE)
	if fh == -1 then
		return nil, "cannot create " .. where
	end
	local written = C4:FileWriteString(fh, bundle)
	C4:FileClose(fh)
	if written ~= #bundle then
		return nil, string.format("short write to %s (%s of %d bytes)", where, tostring(written), #bundle)
	end
	return true
end

-- Switch the File API to an alias directory. Returns true on success.
local function set_dir(alias)
	local ok, err = pcall(function() return C4:FileSetDir(alias) end)
	if not ok then
		return nil, tostring(err)
	end
	return true
end

-- Ensure copies of the bundle exist in the sandbox and, if possible, the C4Z
-- directory. Returns a table { sandbox = path|nil, c4z = path|nil,
-- errors = {..} }; `sandbox` nil means nothing usable was written.
function certs.install()
	local bundle = require("bridge.ca_bundle")
	local result = { errors = {} }

	local ok, err = write_here(bundle, certs.sandbox_path())
	if ok then
		result.sandbox = certs.sandbox_path()
	else
		result.errors[#result.errors + 1] = err
	end

	-- Best effort: the C4Z alias needs OS 3.3.0+ and a writable directory.
	local switched, serr = set_dir("C4Z")
	if switched then
		ok, err = write_here(bundle, certs.c4z_path())
		if ok then
			result.c4z = certs.c4z_path()
		else
			result.errors[#result.errors + 1] = "C4Z: " .. err
		end
		set_dir("SANDBOX")
	else
		result.errors[#result.errors + 1] = "FileSetDir(C4Z): " .. serr
	end
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
	try("GetDriverFileName", function() return C4:GetDriverFileName() end)
	try("GetDeviceID", function() return C4:GetDeviceID() end)
	try("embedded bundle bytes", function() return #require("bridge.ca_bundle") end)
	try("SANDBOX bundle exists", function() return C4:FileExists(certs.FILE) end)
	try("SANDBOX bundle bytes", function()
		local data = read_all(certs.FILE)
		return data and #data or "unreadable"
	end)
	try("SANDBOX listing", list_dir)
	try("FileExists(abs sandbox path)", function() return C4:FileExists(certs.sandbox_path()) end)
	if set_dir("C4Z") then
		try("C4Z bundle exists", function() return C4:FileExists(certs.FILE) end)
		try("C4Z listing", list_dir)
		try("C4Z certs/ pem exists", function() return C4:FileExists("certs/hue_root_bridge.pem") end)
		set_dir("SANDBOX")
	else
		add("FileSetDir(C4Z): failed")
	end
	return lines
end

return certs
