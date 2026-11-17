-- The Hue Play HDMI Sync Box's state as the driver keeps it (#534,
-- docs/hdmi-sync-stage2-design.md §3.5, contracts C2 in
-- docs/hdmi-sync-contracts.md): the model built from one GET /api/v1, the
-- list of what changed since the last one, and the texts of the Composer
-- rows. Pure Lua, no C4 call, no module state.
--
--   state.from_api(raw, prev)  -> model, changes  |  nil, reason
--   state.describe(model)      -> { sync, inputs, model, firmware,
--                                   bridge_link, input_switching, wiring,
--                                   refusal }
--
-- What the box sends, from docs/syncbox-api-research.md (R1) §2: one GET
-- of /api/v1 returns every resource (device, execution, hdmi, behavior,
-- hue, ir, registrations, presets) in one answer (R1 §2.4, §2.12). The
-- field names below are R1's:
--   device     name, deviceType (HSB1, HSB2, HSB3, HSC001; aiohuesyncbox
--              writes the camera HSC1, so anything starting HSC is the
--              camera, R1 §1.2), uniqueId (12 hex digits), apiLevel,
--              firmwareVersion, buildNumber, overheating (API level 10),
--              undervolt (8K, level 14) (R1 §2.5)
--   execution  mode (powersave, passthrough, video, game, music),
--              syncActive, hdmiActive (false only in power save),
--              hdmiSource (input1 to input4), hueTarget (the area),
--              brightness (0 to 200), lastSyncMode, and per sync mode an
--              object with its intensity (subtle, moderate, high,
--              intense) (R1 §2.6)
--   hdmi       input1 (input2 to input4 on four-input boxes) and output,
--              each with name, type (26 values) and status (unplugged,
--              plugged, linked, unknown) (R1 §2.7)
--   behavior   flags as 0 or 1, never true or false (R1 §2.8):
--              inactivePowersave (minutes), cecPowersave, usbPowersave,
--              hpdInputSwitch, arcBypassMode, soloMode (level 14), and per
--              input cecInputSwitch, linkAutoSync, hpdInputPortSwitch
--   hue        bridgeUniqueId, connectionState (uninitialized,
--              disconnected, connecting, unauthorized, connected,
--              invalidgroup, streaming, busy), groups (the areas by id,
--              each with name, numLights, active), groupId (level 10),
--              operatingMode (bridge, standalone, uninitialized; level 14)
--              (R1 §2.9)
-- Fields a model lacks are absent from its answer (R1 §1.4, §1.5: HSB3
-- has input1 only, the camera no hdmi at all), and later firmware adds
-- values no library knows (R1 §2.6: aiohuesyncbox maps them to unknown).
-- So nothing here is required but the device and execution objects: a
-- field missing from the answer is missing from the model, never an error,
-- and an unknown value reads "unknown" (kept as text beside it for the rows,
-- docs/edge-cases-syncbox.md B15), never sent back.
--
-- Only the fields named here are read, each by its own name: nothing of
-- the answer is copied whole. The answer also carries what must never reach
-- a row, a log line or the model: the Bluetooth light fields of hue hold a
-- key Home Assistant hides from its diagnostics as a secret (R1 §2.9), and
-- registrations lists every app's registration. None of them is read.
--
-- Every number goes through common/num.lua and every text the box sends
-- through https.peer_text, capped (docs/syncbox-architecture-research.md
-- §3.2; security review 2026-11-13, #486, #487, #489). Ids follow fixed
-- rules: the box id 12 hex digits, upper case (R1 §1.2; the identity module
-- compares it so); the bridge id 16 hex digits, lower case, as the bridge
-- driver compares it (R1 §3); area ids letters, digits and "-" (a CLIP v2
-- entertainment_configuration id), or "groups/<n>" from an older bridge
-- (R1 §2.6), at most 64 characters and at most 64 areas kept (R5 §3.2).
--
-- The model (absent when the answer lacks it):
--   id, name, model ("HSB1" | "HSB2" | "HSB3" | "HSC001" | "unknown"),
--   device_type (the box's own deviceType text), firmware, api_level,
--   build, overheating, undervolt
--   inputs       { { n, name, type, status } }, as many as the box has
--   power        "on" | "powersave" (execution.hdmiActive)
--   mode         "video" | "music" | "game" | "passthrough" |
--                "powersave" | "unknown" (mode_raw: the box's text)
--   syncing      true | false
--   input        1 to 4 (execution.hdmiSource)
--   last_sync_mode  "video" | "music" | "game"
--   intensity    "subtle" | "moderate" | "high" | "intense" | "unknown":
--                the current sync mode's, else the last sync mode's
--   brightness   0 to 200 (100 leaves the picture as it is)
--   area, area_name  execution.hueTarget (else hue.groupId) and its name
--                in hue.groups
--   areas        { { id, name, lights, active } }, sorted by name, at most 64
--   bridge       { id, state, state_raw }
--   standalone   true | false (hue.operatingMode, API level 14)
--   behavior     { inactive_powersave, cec_powersave, usb_powersave,
--                hpd_input_switch, arc_bypass, solo, inputs = { { n,
--                cec_input_switch, link_auto_sync, hpd_input_port_switch } } }
--   wiring       "second_output" (behavior.soloMode) | "behind_receiver"
--                (behavior.arcBypassMode) | "in_line" (neither, or no
--                behavior), in that order (design 5.8, O17)
-- `changes` lists the top-level names whose value differs from `prev`
-- (tables compared by content), in the order above; with no `prev`, every
-- field the model has.

local num = require("common.num")
local https = require("common.https")

local state = {}

state.NAME_MAX = 64      -- bytes of a name kept (box, input, area)
state.SHORT_MAX = 32     -- bytes of a short text kept (firmware, a raw value)
state.ID_MAX = 64        -- characters of an area id
state.AREAS_MAX = 64     -- areas kept (R5 §3.2)
state.AREAS_READ = 256   -- entries of hue.groups looked at, at most
state.INPUTS = 4         -- hdmi.input1 to input4 (R1 §2.7)
state.ROW_MAX = https.TEXT_ROW
state.UNKNOWN = "\226\128\148" -- an em dash: nothing known

-- The order of `changes`, and of the model's fields in the header.
state.FIELDS = {
	"id", "name", "model", "device_type", "firmware", "api_level", "build", "overheating", "undervolt",
	"inputs", "power", "mode", "mode_raw", "syncing", "input", "last_sync_mode", "intensity", "brightness",
	"area", "area_name", "areas", "bridge", "standalone", "behavior", "wiring",
}

local function set(list)
	local out = {}
	for _, v in ipairs(list) do
		out[v] = true
	end
	return out
end

local MODELS = set({ "HSB1", "HSB2", "HSB3", "HSC001" })
local MODES = set({ "video", "music", "game", "passthrough", "powersave" })
local SYNC_MODES = { video = "Video", music = "Music", game = "Game" }
local INTENSITIES = set({ "subtle", "moderate", "high", "intense" })
local INPUT_STATUSES = set({ "unplugged", "plugged", "linked", "unknown" })
-- R1 §2.7, the 26 input types.
local INPUT_TYPES = set({ "generic", "video", "game", "music", "xbox", "playstation", "nintendoswitch", "phone",
	"desktop", "laptop", "appletv", "roku", "shield", "chromecast", "firetv", "diskplayer", "settopbox",
	"satellite", "avreceiver", "soundbar", "hdmiswitch", "tv", "monitor", "beamer", "speaker", "hdmisplitter" })
local CONNECTION = set({ "uninitialized", "disconnected", "connecting", "unauthorized", "connected",
	"invalidgroup", "streaming", "busy" })
local SOURCES = { input1 = 1, input2 = 2, input3 = 3, input4 = 4 }

-- Texts ------------------------------------------------------------------------

-- A text the box sent, capped and without control characters, or nil when
-- it is not a non-empty string.
local function text(v, max)
	if type(v) ~= "string" or v == "" then
		return nil
	end
	local out = https.peer_text(v, max or state.NAME_MAX)
	return out ~= "" and out or nil
end

-- A flag: R1 §2.8 sends 0 or 1, execution sends true or false; anything
-- else is unknown (nil).
local function flag(v)
	if type(v) == "boolean" then
		return v
	end
	local n = num.int(v, 0, 1)
	if n == nil or num.finite(v) ~= n then
		return nil
	end
	return n == 1
end

-- A member of `known`, "unknown" (and the raw text) for another string,
-- nil when absent.
local function enum(v, known)
	if v == nil then
		return nil
	end
	if type(v) == "string" and known[v] then
		return v
	end
	return "unknown", text(type(v) == "string" and v or tostring(v), state.SHORT_MAX)
end

local function box_id(v)
	if type(v) ~= "string" or #v ~= 12 or not v:match("^%x+$") then
		return nil
	end
	return v:upper()
end

local function bridge_id(v)
	if type(v) ~= "string" or #v ~= 16 or not v:match("^%x+$") then
		return nil
	end
	return v:lower()
end

local function area_id(v)
	if type(v) ~= "string" or v == "" or #v > state.ID_MAX then
		return nil
	end
	if v:match("^[%w%-]+$") or v:match("^groups/%d+$") then
		return v
	end
	return nil
end

local function obj(v)
	return type(v) == "table" and v or nil
end

-- The model ------------------------------------------------------------------------

local function read_device(m, d)
	m.id = box_id(d.uniqueId)
	m.name = text(d.name)
	local raw = text(d.deviceType, state.SHORT_MAX)
	m.device_type = raw
	if raw then
		local up = raw:upper()
		if MODELS[up] then
			m.model = up
		elseif up:sub(1, 3) == "HSC" then
			m.model = "HSC001" -- the camera (R1 §1.2: HSC001, or HSC1 in aiohuesyncbox)
		else
			m.model = "unknown"
		end
	else
		m.model = "unknown"
	end
	m.firmware = text(d.firmwareVersion, state.SHORT_MAX)
	m.api_level = num.int(d.apiLevel, 0, 1000)
	m.build = num.int(d.buildNumber, 0, 4294967295)
	m.overheating = flag(d.overheating)
	m.undervolt = flag(d.undervolt)
end

local function read_inputs(hdmi)
	if not hdmi then
		return nil
	end
	local list = {}
	for n = 1, state.INPUTS do
		local i = obj(hdmi["input" .. n])
		if i then
			list[#list + 1] = {
				n = n,
				name = text(i.name),
				type = (enum(i.type, INPUT_TYPES)),
				status = (enum(i.status, INPUT_STATUSES)),
			}
		end
	end
	return #list > 0 and list or nil
end

local function read_execution(m, e)
	local active = flag(e.hdmiActive)
	if active ~= nil then
		m.power = active and "on" or "powersave"
	end
	m.mode, m.mode_raw = enum(e.mode, MODES)
	m.syncing = flag(e.syncActive)
	m.input = type(e.hdmiSource) == "string" and SOURCES[e.hdmiSource] or nil
	m.last_sync_mode = type(e.lastSyncMode) == "string" and SYNC_MODES[e.lastSyncMode] and e.lastSyncMode or nil
	local which = SYNC_MODES[m.mode] and m.mode or m.last_sync_mode
	local per_mode = which and obj(e[which])
	if per_mode then
		m.intensity = (enum(per_mode.intensity, INTENSITIES))
	end
	m.brightness = num.int(e.brightness, 0, 200)
	m.area = area_id(e.hueTarget)
end

-- hue.groups: an object keyed by area id (R1 §2.9). At most AREAS_READ
-- entries are looked at, the valid ones sorted, AREAS_MAX kept.
local function read_areas(groups)
	if not groups then
		return nil
	end
	local list, seen = {}, 0
	for key, g in pairs(groups) do
		seen = seen + 1
		if seen > state.AREAS_READ then
			break
		end
		local id = area_id(key)
		if id and type(g) == "table" then
			list[#list + 1] = { id = id, name = text(g.name), lights = num.int(g.numLights, 0, 1000),
				active = flag(g.active) }
		end
	end
	table.sort(list, function(a, b)
		local an, bn = (a.name or ""):lower(), (b.name or ""):lower()
		if an ~= bn then
			return an < bn
		end
		return a.id < b.id
	end)
	while #list > state.AREAS_MAX do
		table.remove(list)
	end
	return list
end

local function read_hue(m, h)
	m.area = m.area or area_id(h.groupId)
	local groups = obj(h.groups)
	m.areas = read_areas(groups)
	if m.area and groups then
		local g = obj(groups[m.area])
		m.area_name = g and text(g.name) or nil
	end
	local st, raw = enum(h.connectionState, CONNECTION)
	m.bridge = { id = bridge_id(h.bridgeUniqueId), state = st, state_raw = raw }
	if h.operatingMode == "standalone" then
		m.standalone = true
	elseif h.operatingMode == "bridge" or h.operatingMode == "uninitialized" then
		m.standalone = false
	end
end

local function read_behavior(b)
	if not b then
		return nil
	end
	local out = {
		inactive_powersave = num.int(b.inactivePowersave, 0, 10000),
		cec_powersave = flag(b.cecPowersave),
		usb_powersave = flag(b.usbPowersave),
		hpd_input_switch = flag(b.hpdInputSwitch),
		arc_bypass = flag(b.arcBypassMode),
		solo = flag(b.soloMode),
	}
	local inputs = {}
	for n = 1, state.INPUTS do
		local i = obj(b["input" .. n])
		if i then
			inputs[#inputs + 1] = { n = n, cec_input_switch = flag(i.cecInputSwitch),
				link_auto_sync = flag(i.linkAutoSync), hpd_input_port_switch = flag(i.hpdInputPortSwitch) }
		end
	end
	out.inputs = #inputs > 0 and inputs or nil
	return out
end

-- Two values the same, tables by content (a few levels deep: the model's
-- tables hold lists of small tables).
local function same(a, b, depth)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" or depth > 4 then
		return false
	end
	for k, v in pairs(a) do
		if not same(v, b[k], depth + 1) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local ORDER = {}
for i, name in ipairs(state.FIELDS) do
	ORDER[name] = i
end

local function changes_of(m, prev)
	local out, names = {}, {}
	for k in pairs(m) do
		names[k] = true
	end
	for k in pairs(prev or {}) do
		names[k] = true
	end
	for k in pairs(names) do
		if prev == nil or not same(m[k], prev[k], 1) then
			out[#out + 1] = k
		end
	end
	table.sort(out, function(a, b)
		local ia, ib = ORDER[a] or #state.FIELDS + 1, ORDER[b] or #state.FIELDS + 1
		if ia ~= ib then
			return ia < ib
		end
		return tostring(a) < tostring(b)
	end)
	return out
end

-- The model of one GET /api/v1 answer, and what changed since `prev` (the
-- model of the last good read, or nil). nil and a reason for an answer
-- that is not the box's state. Never raises on what the box sends.
function state.from_api(raw, prev)
	if type(raw) ~= "table" then
		return nil, "not the box's state: the answer is not a JSON object"
	end
	local device, execution = obj(raw.device), obj(raw.execution)
	if not device or not execution then
		return nil, "not the box's state: no device and execution objects"
	end
	local m = {}
	read_device(m, device)
	m.inputs = read_inputs(obj(raw.hdmi))
	read_execution(m, execution)
	local hue = obj(raw.hue)
	if hue then
		read_hue(m, hue)
	end
	m.behavior = read_behavior(obj(raw.behavior))
	local b = m.behavior
	if b and b.solo then
		m.wiring = "second_output"
	elseif b and b.arc_bypass then
		m.wiring = "behind_receiver"
	else
		m.wiring = "in_line"
	end
	return m, changes_of(m, type(prev) == "table" and prev or nil)
end

-- The rows ------------------------------------------------------------------------

state.MODEL_NAMES = {
	HSB1 = "Hue Play HDMI Sync Box (HSB1)",
	HSB2 = "Hue Play HDMI Sync Box 8K (HSB2)",
	HSB3 = "Hue Play HDMI Sync Box 4K (HSB3)",
}

state.WIRING_TEXTS = {
	in_line = "In line (sources \226\134\146 box \226\134\146 TV or receiver)",
	behind_receiver = "Behind a receiver (ARC bypass on)",
	second_output = "From a receiver's second output (solo mode)",
}

-- connectionState in the Bridge Link row (R1 §2.9).
state.LINK_WORDS = {
	connected = "connected",
	streaming = "streaming",
	busy = "busy",
	invalidgroup = "invalid area",
	connecting = "connecting",
	disconnected = "disconnected",
	unauthorized = "not authorized",
	uninitialized = "not linked",
}

state.REFUSAL_STANDALONE = "Not supported: this box runs without a Hue Bridge (standalone mode)"
state.REFUSAL_CAMERA = "Not supported: the Hue Play Screen Sync camera has no HDMI"

local function in_power_save(m)
	return m.power == "powersave" or m.mode == "powersave"
end

local function sync_text(m)
	if in_power_save(m) then
		return "Power save"
	end
	if m.mode == "passthrough" then
		return "Off (passthrough)"
	end
	local parts = {}
	if SYNC_MODES[m.mode] then
		parts[1] = SYNC_MODES[m.mode]
	elseif m.mode == "unknown" then
		parts[1] = "Unknown mode" .. (m.mode_raw and (" (" .. m.mode_raw .. ")") or "")
	else
		return state.UNKNOWN
	end
	-- An unknown mode's intensity is not known: model.intensity is then the
	-- last sync mode's.
	if SYNC_MODES[m.mode] and m.intensity and m.intensity ~= "unknown" then
		parts[#parts + 1] = m.intensity
	end
	if m.brightness then
		parts[#parts + 1] = "brightness " .. m.brightness .. " %"
	end
	local out = table.concat(parts, ", ")
	if m.area_name then
		out = out .. " on " .. m.area_name
	end
	return out
end

local function inputs_text(m)
	if type(m.inputs) ~= "table" or #m.inputs == 0 then
		return state.UNKNOWN
	end
	local parts = {}
	for _, i in ipairs(m.inputs) do
		local s = i.n .. " " .. (i.name or state.UNKNOWN)
		if i.n == m.input and not in_power_save(m) then
			s = s .. " (on)"
		end
		parts[#parts + 1] = s
	end
	return table.concat(parts, ", ")
end

local function firmware_text(m)
	if m.firmware and m.api_level then
		return m.firmware .. " (API level " .. m.api_level .. ")"
	end
	if m.firmware then
		return m.firmware
	end
	if m.api_level then
		return "API level " .. m.api_level
	end
	return state.UNKNOWN
end

local function bridge_text(m)
	if m.standalone then
		return "Not linked (standalone mode)"
	end
	local b = m.bridge
	if type(b) ~= "table" then
		return "Not linked"
	end
	local word = state.LINK_WORDS[b.state]
	if not word then
		word = b.state == "unknown" and ("unknown (" .. (b.state_raw or "?") .. ")") or "state unknown"
	end
	if b.id then
		return "Hue Bridge " .. b.id .. ", " .. word
	end
	if word == "not linked" then
		return "Not linked"
	end
	return "Hue Bridge, " .. word
end

-- What the box does by itself (contracts C1.4, design 5.4): input switching
-- by HDMI CEC (any input's cecInputSwitch) or hot-plug (the box-wide
-- hpdInputSwitch, or any input's hpdInputPortSwitch), and the inputs that
-- start syncing by themselves (linkAutoSync).
local function switching_text(m)
	local b = m.behavior
	if type(b) ~= "table" then
		return state.UNKNOWN
	end
	local cec, hpd, auto = false, b.hpd_input_switch == true, {}
	for _, i in ipairs(b.inputs or {}) do
		cec = cec or i.cec_input_switch == true
		hpd = hpd or i.hpd_input_port_switch == true
		if i.link_auto_sync then
			auto[#auto + 1] = tostring(i.n)
		end
	end
	local parts = {}
	if cec and hpd then
		parts[1] = "HDMI CEC and hot-plug"
	elseif cec then
		parts[1] = "HDMI CEC"
	elseif hpd then
		parts[1] = "hot-plug"
	end
	if #auto > 0 then
		parts[#parts + 1] = "auto-sync on HDMI " .. table.concat(auto, ", ")
	end
	if #parts == 0 then
		return "None: the box neither switches inputs nor starts syncing by itself"
	end
	return "By the box: " .. table.concat(parts, "; ")
end

local function row(v)
	return https.peer_text(v, state.ROW_MAX)
end

-- The texts of the box's Composer rows (§3.5). Every key but refusal is a
-- text, the em dash where nothing is known; refusal is nil or a text.
function state.describe(model)
	local m = type(model) == "table" and model or {}
	local refusal
	if m.standalone then
		refusal = state.REFUSAL_STANDALONE
	elseif m.model == "HSC001" then
		refusal = state.REFUSAL_CAMERA
	end
	return {
		sync = row(sync_text(m)),
		inputs = row(inputs_text(m)),
		model = row(state.MODEL_NAMES[m.model] or m.device_type or state.UNKNOWN),
		firmware = row(firmware_text(m)),
		bridge_link = row(bridge_text(m)),
		input_switching = row(switching_text(m)),
		wiring = state.WIRING_TEXTS[m.wiring] or state.WIRING_TEXTS.in_line,
		refusal = refusal,
	}
end

return state
