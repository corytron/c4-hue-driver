-- Puts the Signify CA bundle where C4:url can open it.
--
-- The first hardware run showed that a path "relative to the .c4z" in
-- ssl_cacerts fails with fopen: No such file or directory on OS 3.4.2. The
-- controller's base for such paths isn't documented, so instead the bundle
-- is embedded (bridge/ca_bundle.lua), written into the driver's sandbox
-- directory with the File API, and referenced by absolute path.

local certs = {}

certs.FILE = "hue_ca_bundle.pem"

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

function certs.path()
	return C4:GetSandboxDir() .. "/" .. certs.FILE
end

-- Ensure the sandbox copy exists and matches the embedded bundle.
-- Returns the absolute path, or nil and a reason.
function certs.install()
	local bundle = require("bridge.ca_bundle")
	local path = certs.path()
	if C4:FileExists(certs.FILE) then
		if read_all(certs.FILE) == bundle then
			return path
		end
		-- Stale or truncated: FileOpen appends, so remove it first.
		C4:FileDelete(certs.FILE)
	end
	local fh = C4:FileOpen(certs.FILE)
	if fh == -1 then
		return nil, "cannot create " .. path
	end
	local written = C4:FileWriteString(fh, bundle)
	C4:FileClose(fh)
	if written ~= #bundle then
		return nil, string.format("short write to %s (%s of %d bytes)", path, tostring(written), #bundle)
	end
	return path
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
	try("sandbox bundle exists", function() return C4:FileExists(certs.FILE) end)
	try("sandbox bundle size", function()
		local data = read_all(certs.FILE)
		return data and #data or "unreadable"
	end)
	try("embedded bundle size", function() return #require("bridge.ca_bundle") end)
	-- Whether the archive's own files are visible anywhere the docs hint at.
	try("FileExists certs/hue_root_bridge.pem", function() return C4:FileExists("certs/hue_root_bridge.pem") end)
	try("FileList", function()
		local names = C4:FileList()
		if type(names) ~= "table" then return tostring(names) end
		local out = {}
		for _, name in pairs(names) do out[#out + 1] = tostring(name) end
		table.sort(out)
		return table.concat(out, ", ")
	end)
	return lines
end

return certs
