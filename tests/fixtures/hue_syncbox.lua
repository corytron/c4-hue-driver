-- Hand-written Hue Play HDMI Sync Box bodies for the box driver's specs
-- (2.0 beta stage 2, #534; docs/hdmi-sync-stage2-design.md §7, contracts C8
-- of docs/hdmi-sync-contracts.md). Written from the public field names of
-- docs/syncbox-api-research.md (R1 below) §1.2, §1.3 and §2 (2.3
-- registrations, 2.5 device, 2.6 execution, 2.7 hdmi, 2.8 behavior, 2.9 hue,
-- 2.10 ir, 2.11 presets, 2.14 error codes); never copied from Signify's or a
-- library's example bodies. The values are invented. Replaced by recordings
-- of a real box, with these placeholders swapped in, when one is available
-- (docs/syncbox-architecture-research.md §5.1).
--
-- Lua tables: the decoded bodies, what the box's client hands its callers
-- (contracts §3, cb(ok, status, decoded, err)). M.json(t) is the JSON text of
-- one, for a spec that answers a transfer itself; M.copy(t) a deep copy to
-- change. Never change a fixture in place: the specs of a file share them.
-- Empty objects carry dkjson's object mark, so M.json writes them as {} (as
-- the box does), not []. The fake box (tests/helpers/fake_c4.lua,
-- fake.syncbox) takes these tables, or their JSON text.
--
-- Placeholders only (CLAUDE.md, .gitleaks.toml): the box id 0A1B2C3D4E5F (12
-- upper-case hex digits, as uniqueId is, R1 §1.2), the box at 10.0.2.150,
-- the bridge 001788fffe123abc at 10.0.2.143, the token TEST-TOKEN-NOT-REAL
-- under registration "7". Every model uses the same box id and address.
-- Whether a real box writes the bridge id in lower case, as here, is
-- [assumed]. The entertainment areas are tests/fixtures/hue_entertainment.lua's
-- (the same ids and names), so a spec that loads the bridge and the box
-- together sees one set of areas:
--   Living Room TV   6a7b8c9d-0000-4000-8000-0000000ea001   5 lamps
--   Office           6a7b8c9d-0000-4000-8000-0000000ea002   3 lamps
--
-- M.state.<name>: the whole GET /api/v1 body (R1 §2.4: device, execution,
-- hdmi, behavior, hue, ir, registrations, presets; a resource a model lacks
-- is absent):
--   HSB1                  the original box, API level 9 (before level 10: no
--                         hue.groupId, hpdInputPortSwitch, overheating,
--                         bluetooth or registration "verified"; before 14: no
--                         soloMode or operatingMode); in passthrough on input 2
--                         (Cable Box); HSB1-only hdrMode and forceDoviNative;
--                         the box-wide hpdInputSwitch on
--   HSB2                  the 8K box, level 14, wired in line (arcBypassMode
--                         and soloMode 0); syncing video, intensity high,
--                         brightness 100, on input 1 (Apple TV) to Living Room
--                         TV, which it streams to (connectionState streaming)
--   HSB2_behind_receiver  HSB2 with behavior.arcBypassMode 1, nothing else changed
--   HSB2_second_output    HSB2 with behavior.soloMode 1, nothing else changed
--   HSB3                  the 2026 4K box, level 14, one input and no ir (R1
--                         §1.4, §1.5); with the bridge, in power save, area
--                         Office
--   HSB3_standalone       HSB3 without a bridge (hue.operatingMode
--                         standalone, R1 §1.5): no groups, empty bridge
--                         fields and hueTarget [assumed: R1 says presumably],
--                         in passthrough
-- M.models lists those names in that order.
--
-- M.device.<name>: the GET /api/v1/device body without a token (R1 §2.1:
-- name, deviceType, uniqueId, apiLevel, firmwareVersion, buildNumber,
-- wifiState, ipAddress, capabilities and a few flags; which flags is
-- [assumed]: termsAgreed and beta), one per M.state name (the variants share
-- their model's), plus HSC001, the Play Screen Sync camera (identity's
-- `camera` reason, O2).
--
-- M.registration_pending: POST /registrations before the button (HTTP 400,
-- code 16, R1 §2.3). M.registration_ok: after it (HTTP 200).
-- M.error.<name> and M.error_status.<name>: the error bodies of R1 §2.14 and
-- their HTTP status (R1 §2.1). Which of the codes 1, 2 and 3 a rejected token
-- gets, and the code of a 404, are [assumed]; R1 does not say.
--
-- behavior's flags are the numbers 0 and 1, never true or false (R1 §2.8).

local json = require("dkjson")

local M = {}

M.BOX_ID = "0A1B2C3D4E5F"
M.ADDRESS = "10.0.2.150"
M.TOKEN = "TEST-TOKEN-NOT-REAL"
M.REGISTRATION_ID = "7"
M.BRIDGE_ID = "001788fffe123abc"
M.BRIDGE_ADDRESS = "10.0.2.143"
M.APP_NAME = "c4-hue"   -- the registration's appName (contracts C2)

M.AREA = {
	tv = "6a7b8c9d-0000-4000-8000-0000000ea001",
	office = "6a7b8c9d-0000-4000-8000-0000000ea002",
}
M.AREA_NAMES = { tv = "Living Room TV", office = "Office" }

-- An empty JSON object: dkjson's mark, so json.encode writes {} (R1's bodies
-- have objects there, never lists).
local function object()
	return setmetatable({}, { __jsontype = "object" })
end

-- A deep copy, keeping dkjson's object and array marks.
local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = copy(v)
	end
	return setmetatable(out, getmetatable(value))
end

function M.copy(value)
	return copy(value)
end

-- JSON text of a fixture (or of any table): what the box would send.
function M.json(value)
	return json.encode(value)
end

-- One HDMI port (R1 §2.7): its name and type as the owner set them, its
-- status, and the mode it last synced in.
local function port(name, kind, status, last_sync_mode)
	return { name = name, type = kind, status = status, lastSyncMode = last_sync_mode }
end

-- hue.groups (R1 §2.9): the bridge's entertainment areas by id. `streaming`
-- names the one the box streams to, if any (its owner is left out: what it
-- holds is not public).
local function groups(streaming)
	local out = {}
	for _, key in ipairs({ "tv", "office" }) do
		out[M.AREA[key]] = {
			name = M.AREA_NAMES[key],
			numLights = key == "tv" and 5 or 3,
			active = key == streaming,
		}
	end
	return out
end

-- The Hue Sync app's own registration (R1 §2.3: the app holds the admin
-- role); `verified` from API level 10. Its creation and last-use times are
-- left out (their key names are [assumed]).
local function registrations(level)
	return {
		["1"] = { appName = "huesync", instanceName = "Phone", role = "admin", verified = level >= 10 or nil },
	}
end

M.state = {}

M.state.HSB1 = {
	device = {
		name = "Den Sync Box",
		deviceType = "HSB1",
		uniqueId = M.BOX_ID,
		ipAddress = M.ADDRESS,
		apiLevel = 9,
		firmwareVersion = "1.8.3",
		buildNumber = 1080300,
		wifiState = "wan",
		wifi = { ssid = "ExampleNet", strength = 3 },
		ledMode = 1,
		action = "none",
		pushlink = "idle",
		update = { autoUpdateEnabled = true, autoUpdateTime = 3 },
		capabilities = { maxIrCodes = 16, maxPresets = 16 },
		termsAgreed = true,
		beta = false,
		temperature = 41,
	},
	execution = {
		mode = "passthrough",
		syncActive = false,
		hdmiActive = true,
		hdmiSource = "input2",
		hueTarget = M.AREA.tv,
		brightness = 120,
		lastSyncMode = "music",
		video = { intensity = "moderate", backgroundLighting = true },
		game = { intensity = "high", backgroundLighting = false },
		music = { intensity = "subtle", palette = "happyCalm" },
	},
	hdmi = {
		input1 = port("Blu-ray", "diskplayer", "plugged", "video"),
		input2 = port("Cable Box", "settopbox", "linked", "video"),
		input3 = port("HDMI 3", "generic", "unplugged", "video"),
		input4 = port("HDMI 4", "generic", "unplugged", "video"),
		output = port("TV", "tv", "linked", "video"),
		contentSpecs = "1920 x 1080 @ 59940 - SDR",
		videoSyncSupported = true,
		audioSyncSupported = true,
	},
	behavior = {
		inactivePowersave = 20,
		cecPowersave = 1,
		usbPowersave = 1,
		hpdInputSwitch = 1,
		arcBypassMode = 0,
		forceDoviNative = 0,
		input1 = { cecInputSwitch = 1, linkAutoSync = 0, hdrMode = 0 },
		input2 = { cecInputSwitch = 1, linkAutoSync = 0, hdrMode = 0 },
		input3 = { cecInputSwitch = 0, linkAutoSync = 0, hdrMode = 0 },
		input4 = { cecInputSwitch = 0, linkAutoSync = 0, hdrMode = 2 },
	},
	hue = {
		bridgeUniqueId = M.BRIDGE_ID,
		bridgeIpAddress = M.BRIDGE_ADDRESS,
		connectionState = "connected",
		groups = groups(nil),
	},
	ir = { defaultCodes = true, codes = object() },
	registrations = registrations(9),
	presets = object(),
}

M.state.HSB2 = {
	device = {
		name = "Living Room Sync Box",
		deviceType = "HSB2",
		uniqueId = M.BOX_ID,
		ipAddress = M.ADDRESS,
		apiLevel = 14,
		firmwareVersion = "2.5.4",
		buildNumber = 2050400,
		wifiState = "wan",
		wifi = { ssid = "ExampleNet", strength = 4 },
		ledMode = 1,
		action = "none",
		pushlink = "idle",
		update = { autoUpdateEnabled = true, autoUpdateTime = 3 },
		capabilities = { maxIrCodes = 16, maxPresets = 16 },
		termsAgreed = true,
		beta = false,
		temperature = 44,
		overheating = false,
		bluetooth = true,
		undervolt = false,
	},
	execution = {
		mode = "video",
		syncActive = true,
		hdmiActive = true,
		hdmiSource = "input1",
		hueTarget = M.AREA.tv,
		brightness = 100,
		lastSyncMode = "video",
		video = { intensity = "high", backgroundLighting = false },
		game = { intensity = "intense", backgroundLighting = false },
		music = { intensity = "moderate", palette = "neutral" },
	},
	hdmi = {
		input1 = port("Apple TV", "appletv", "linked", "video"),
		input2 = port("PlayStation", "playstation", "plugged", "game"),
		input3 = port("HDMI 3", "generic", "unplugged", "video"),
		input4 = port("HDMI 4", "generic", "unplugged", "video"),
		output = port("TV", "tv", "linked", "video"),
		contentSpecs = "3840 x 2160 @ 60000 - HDR10",
		videoSyncSupported = true,
		audioSyncSupported = true,
	},
	behavior = {
		inactivePowersave = 20,
		cecPowersave = 1,
		usbPowersave = 0,
		hpdInputSwitch = 0,
		arcBypassMode = 0,
		soloMode = 0,
		input1 = { cecInputSwitch = 1, linkAutoSync = 1, hpdInputPortSwitch = 0 },
		input2 = { cecInputSwitch = 1, linkAutoSync = 0, hpdInputPortSwitch = 0 },
		input3 = { cecInputSwitch = 0, linkAutoSync = 0, hpdInputPortSwitch = 0 },
		input4 = { cecInputSwitch = 0, linkAutoSync = 0, hpdInputPortSwitch = 0 },
	},
	hue = {
		bridgeUniqueId = M.BRIDGE_ID,
		bridgeIpAddress = M.BRIDGE_ADDRESS,
		connectionState = "streaming",
		groups = groups("tv"),
		groupId = M.AREA.tv,
		operatingMode = "bridge",
	},
	ir = { defaultCodes = true, codes = object() },
	registrations = registrations(14),
	presets = object(),
}

M.state.HSB3 = {
	device = {
		name = "Bedroom Sync Box",
		deviceType = "HSB3",
		uniqueId = M.BOX_ID,
		ipAddress = M.ADDRESS,
		apiLevel = 14,
		firmwareVersion = "3.5.2",
		buildNumber = 3050200,
		wifiState = "wan",
		wifi = { ssid = "ExampleNet", strength = 2 },
		ledMode = 2,
		action = "none",
		pushlink = "idle",
		update = { autoUpdateEnabled = false, autoUpdateTime = 4 },
		capabilities = { maxIrCodes = 0, maxPresets = 16 },
		termsAgreed = true,
		beta = false,
		temperature = 38,
		overheating = false,
		bluetooth = true,
	},
	execution = {
		mode = "powersave",
		syncActive = false,
		hdmiActive = false,
		hdmiSource = "input1",
		hueTarget = M.AREA.office,
		brightness = 80,
		lastSyncMode = "game",
		video = { intensity = "subtle", backgroundLighting = false },
		game = { intensity = "high", backgroundLighting = true },
		music = { intensity = "intense", palette = "melancholicEnergetic" },
	},
	hdmi = {
		input1 = port("Game Console", "nintendoswitch", "plugged", "game"),
		output = port("Monitor", "monitor", "plugged", "game"),
		contentSpecs = "",
		videoSyncSupported = false,
		audioSyncSupported = false,
	},
	behavior = {
		inactivePowersave = 10,
		cecPowersave = 1,
		arcBypassMode = 0,
		soloMode = 0,
		input1 = { cecInputSwitch = 1, linkAutoSync = 1, hpdInputPortSwitch = 1 },
	},
	hue = {
		bridgeUniqueId = M.BRIDGE_ID,
		bridgeIpAddress = M.BRIDGE_ADDRESS,
		connectionState = "connected",
		groups = groups(nil),
		groupId = M.AREA.office,
		operatingMode = "bridge",
	},
	registrations = registrations(14),
	presets = object(),
}

-- The same box without a bridge: syncing one Bluetooth light (R1 §1.5). The
-- Bluetooth light list is left out: its fields include a key (R1 §2.9) and
-- their names are not public; the connection state's value is [assumed].
M.state.HSB3_standalone = copy(M.state.HSB3)
M.state.HSB3_standalone.execution.mode = "passthrough"
M.state.HSB3_standalone.execution.hdmiActive = true
M.state.HSB3_standalone.execution.hueTarget = ""
M.state.HSB3_standalone.hdmi.input1.status = "linked"
M.state.HSB3_standalone.hdmi.output.status = "linked"
M.state.HSB3_standalone.hdmi.contentSpecs = "2560 x 1440 @ 120000 - SDR"
M.state.HSB3_standalone.hdmi.videoSyncSupported = true
M.state.HSB3_standalone.hdmi.audioSyncSupported = true
M.state.HSB3_standalone.hue = {
	bridgeUniqueId = "",
	bridgeIpAddress = "",
	connectionState = "uninitialized",
	groups = object(),
	groupId = "",
	operatingMode = "standalone",
	bleConnectionState = "connected",
}

-- The two other wirings (R1 §2.8; design 5.8): one flag each.
M.state.HSB2_behind_receiver = copy(M.state.HSB2)
M.state.HSB2_behind_receiver.behavior.arcBypassMode = 1
M.state.HSB2_second_output = copy(M.state.HSB2)
M.state.HSB2_second_output.behavior.soloMode = 1

M.models = { "HSB1", "HSB2", "HSB3", "HSB3_standalone", "HSB2_behind_receiver", "HSB2_second_output" }

-- The unkeyed GET /device: the identifying part of the state's device.
local UNKEYED_DEVICE_FIELDS = { "name", "deviceType", "uniqueId", "ipAddress", "apiLevel", "firmwareVersion",
	"buildNumber", "wifiState", "capabilities", "termsAgreed", "beta" }

-- The unkeyed answer made from a state's device (the fake box's default).
function M.unkeyed_device(device)
	local out = {}
	for _, key in ipairs(UNKEYED_DEVICE_FIELDS) do
		out[key] = copy(device[key])
	end
	return out
end

M.device = {}
for _, name in ipairs(M.models) do
	M.device[name] = M.unkeyed_device(M.state[name].device)
end

-- The Play Screen Sync camera: the same API family, no HDMI (R1 §1.5).
M.device.HSC001 = {
	name = "TV Camera",
	deviceType = "HSC001",
	uniqueId = M.BOX_ID,
	ipAddress = M.ADDRESS,
	apiLevel = 14,
	firmwareVersion = "1.0.4",
	buildNumber = 1000400,
	wifiState = "wan",
	capabilities = { maxIrCodes = 0, maxPresets = 16 },
	termsAgreed = true,
	beta = false,
}

-- Error bodies (R1 §2.14) and their HTTP status (R1 §2.1).
M.error = {
	unauthorized = { code = 2, message = "Invalid Token" },   -- the code is [assumed]: one of 1, 2, 3
	invalid_json = { code = 12, message = "Invalid JSON" },
	invalid_key = { code = 13, message = "Invalid Key" },
	invalid_value = { code = 15, message = "Invalid Value" },
	invalid_state = { code = 16, message = "Invalid State" },
	not_found = { code = 10, message = "Not Found" },          -- [assumed]: the code and the text
}
M.error_status = {
	unauthorized = 401,
	invalid_json = 400,
	invalid_key = 400,
	invalid_value = 400,
	invalid_state = 400,
	not_found = 404,
}

-- Pairing (R1 §2.3).
M.registration_pending = copy(M.error.invalid_state)
M.registration_ok = { registrationId = M.REGISTRATION_ID, accessToken = M.TOKEN }

return M
