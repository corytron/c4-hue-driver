-- Hue Motion driver: one Control4 motion sensor per Hue motion sensor or
-- MotionAware area (docs/motion-design.md §2). The device IS the sensor: its
-- only proxy is Control4's contact proxy contactsingle_motionsensor on
-- binding 5001, and motion is OPENED, no motion CLOSED
-- (docs/motion-control4-research.md, "C4R" below, §1.3 to §1.5 and §4.1). A
-- sensor also has light level, temperature and battery, kept as rows,
-- variables, events and conditionals; its temperature also leaves on the
-- provider connection 2, class TEMPERATURE_VALUE (C4R §3.1). One driver
-- serves both kinds, "sensor" and "area", which its configuration names (D2).
--
-- It never speaks to the Hue API and never changes anything in Hue (D7): the
-- Hue Bridge driver it is bound to (consumer binding 1, class HUE_BRIDGE)
-- sends HUE_MOTION_CONFIGURE, HUE_MOTION_STATE and HUE_MOTION_FORGOTTEN, and
-- it answers with HUE_MOTION_HELLO and HUE_MOTION_GOODBYE (§3). The bridge
-- decides the Status text and whether an end is deliberate; this device
-- shows them (docs/edge-cases-motion.md, "EC" below, §6), holds Hue's "no
-- motion" for the Occupancy Hold Time, and reports to the proxy only real
-- changes, with STATE_OPENED / STATE_CLOSED for the first state after a start.

-- TestCondition is the entry point Director calls for the conditionals of
-- driver.xml [verified: FUND 10/_4].
-- luacheck: globals TestCondition

local log = require("common.log")
local dispatch = require("common.dispatch")
local device = require("common.device")

-- Binding IDs, see driver.xml: the contact proxy on 5001 and the bridge on 1
-- (common/device.lua's), the temperature output on 2.
local PROXY_BINDING = device.PROXY_BINDING
local BRIDGE_BINDING = device.BRIDGE_BINDING
local TEMPERATURE_BINDING = 2

-- Prefix of every line this driver logs.
local LOG_PREFIX = "Hue Motion"

-- The device's kinds (D2): a Hue motion sensor (the key is its Hue device)
-- or a MotionAware area (its motion_area_configuration).
local KIND_SENSOR, KIND_AREA = "sensor", "area"
local KINDS = { [KIND_SENSOR] = true, [KIND_AREA] = true }

-- Occupancy Hold Time (s): the property's range (D10, driver.xml).
local HOLD_MAX_S = 3600

-- After Test: Motion or Test: No Motion, Hue's state comes back with the next
-- reading or after this long, whichever comes first (EC R12).
local TEST_MS = 30000

-- A device that finds itself unbound at late init changes nothing while the
-- binding re-check of common/device.lua looks again (5, 15, 30 and 60 s): a
-- binding can show up late after a Director restart. One second after its
-- last look, a device still unbound treats it as an unbind (EC C11, C12).
local GIVE_UP_MS = 61000

-- Event ids of driver.xml, fixed forever (§2.4).
local EVENT = {
	LIGHT_LEVEL_CHANGED = 1,
	TEMPERATURE_CHANGED = 2,
	BATTERY_LOW = 3,
	BATTERY_NORMAL = 4,
	OFFLINE = 5,
	ONLINE = 6,
	SWITCHED_OFF = 7,
	SWITCHED_ON = 8,
}

-- Event thresholds (§2.4): the light level moved by at least max(5 lux,
-- 10 %), the temperature by at least 0.5 °C, since the event last fired.
local LUX_STEP, LUX_SHARE = 5, 0.10
local TEMPERATURE_STEP = 0.5
local EPSILON = 1e-9 -- 21.53 - 21.03 is not quite 0.5 in binary

-- The variables, added in OnDriverInit in this order: by name they get the
-- ids 1001, 1002, ... in the order added, and programming refers to those ids
-- [verified: API 36/_1], so the order is fixed forever (§2.3).
local VARIABLES = {
	{ name = "Online", type = "BOOL" },
	{ name = "Enabled", type = "BOOL" },
	{ name = "Light Level", type = "INT" },
	{ name = "Temperature C", type = "NUMBER" },
	{ name = "Temperature F", type = "NUMBER" },
	{ name = "Battery Level", type = "INT" },
	{ name = "Battery Low", type = "BOOL" },
}

-- The conditionals of driver.xml by <name> (§2.5): the variable each one
-- reads, and whether it is a BOOL or a NUMBER.
local CONDITIONALS = {
	BOOL_ONLINE = { var = "Online", bool = true },
	BOOL_ENABLED = { var = "Enabled", bool = true },
	BOOL_BATTERY_LOW = { var = "Battery Low", bool = true },
	NUMBER_LIGHT_LEVEL = { var = "Light Level" },
	NUMBER_TEMPERATURE_C = { var = "Temperature C" },
	NUMBER_BATTERY_LEVEL = { var = "Battery Level" },
}

-- The rows only a sensor has (§2.2); an area's device hides them.
local SENSOR_ROWS = { "Light Level", "Temperature", "Battery" }

-- Hue's battery states; anything else is ignored.
local BATTERY_STATES = { normal = true, low = true, critical = true }

-- The deliberate ends a HUE_MOTION_STATE can name (§3).
local ENDS = { deleted = true, off = true, paused = true, forgotten = true }

-- What a forgotten device's owner can do; Last Action says it (EC §6).
local FORGOTTEN_INSTRUCTION = "Delete this device in Composer, or bind it again and use Link Devices"

-- The device's own copy of its identity (PersistSetValue key per field), so a
-- bridge that lost its registry adopts it from its hello instead of
-- importing it a second time (docs/import-design.md §1, rule 3).
local PERSISTED = { rid = "hue_rid", name = "hue_name", kind = "hue_kind", model = "hue_model" }

-- What the proxy last got, "open" or "closed": the first state after a start
-- is compared with it (§2.7, EC R4).
local SHOWN_KEY = "motion_shown"

-- The readings, the events' baselines, Online, Enabled and the old-value
-- mark, persisted as one table (a table persists [verified: API 26.5/_4]),
-- so a restart keeps every variable at its last value (§2.3) and fires no
-- event for a value that did not change.
local VALUES_KEY = "motion_values"
local NUMBER_VALUES = { "lux", "temp_c", "battery_level", "lux_fired", "temp_fired", "offline_since" }
local BOOL_VALUES = { "online", "enabled" }

local st = {
	rid = nil,        -- Hue resource id (the sensor's device, the area's configuration); the key in every message
	kind = nil,       -- KIND_SENSOR / KIND_AREA; nil until told (taken as a sensor)
	name = nil,       -- the Hue name
	model = nil,      -- the Model row as the bridge words it
	hue_room = nil,   -- the Hue Room row as the bridge words it
	id_v1 = nil,      -- "/sensors/12" for a sensor; nil for an area
	gone = false,     -- the bridge says the sensor or area no longer exists in Hue
	forgotten = nil,  -- { name } after HUE_MOTION_FORGOTTEN, until the next configure
	has = {},         -- light_level / temperature / battery -> false when the sensor has none
}

-- pv: the persisted values (VALUES_KEY). online, enabled: nil until reported;
-- lux, temp_c (°C), battery_level, battery_state: the last readings;
-- lux_fired, temp_fired: what the Changed events last fired at;
-- offline_since: os.time() when Online last went false.
local pv = {}
local vars = {}              -- variable name -> the value it was last set to (a string)
local queued = {}            -- events to fire once the variables are set, { id, why }
local dirty = false          -- pv changed since it was last persisted

local bridge = nil           -- device id of the bound Hue Bridge driver, or nil
local give_up = nil          -- the timer after which an unbound device counts as unbound
local state_seen = false     -- a HUE_MOTION_STATE arrived since the start
local bridge_status = nil    -- the Status text the last HUE_MOTION_STATE carried; nil means fine
local ended_now = nil        -- the deliberate end the bridge's states name while it lasts (§3), or nil
local hue_motion = nil       -- Hue's own motion state (before the hold): true / false / nil unknown
local hue_changed = nil      -- the bridge's ISO 8601 time of that state's last change
local shown = nil            -- what the proxy shows: true open, false closed, nil never told
local sent_since_start = false -- a state went to the proxy since the start
local hold = nil             -- { timer } while Hue's "no motion" is held
local hold_s = 0             -- Occupancy Hold Time (s)
local test = nil             -- { timer, before } for TEST_MS after a test
local temp_out = nil         -- the temperature output: nil nothing since the start, "available", "unavailable"
local temp_at = nil          -- os.time() of the reading the output carries
local rows = {}              -- row name -> the text last written
local rows_hidden = nil      -- whether the sensor rows are hidden; nil until applied

-- The plumbing the device drivers share (common/device.lua): properties, the
-- bridge lookup, Driver Version and Debug Mode, the buffer for bridge messages
-- that arrive before late init, the binding re-check and replay, and in dev
-- builds the log forwarding. Its keypad parts are light_v2 only and stay
-- unused here: no keypad settings are taken, and the contact proxy sends none
-- of the keypad commands.
local dev = device.new({
	prefix = LOG_PREFIX,
	tree = "motion", -- the dev loop's name for this driver's source tree
	bridge = function() return bridge end,
	rid = function() return st.rid end,
	noun = "motion sensor",
	settings = {},
})
local prop, device_id, result = dev.prop, dev.device_id, dev.result
local bound_bridge, after_late_init = dev.bound_bridge, dev.after_late_init

-- The keypad LEDs follow no on state here (only a light_v2 proxy has them).
function dev.is_on()
	return nil
end

-- A string param or nil when absent or empty, and a boolean from "true"/"1"
-- and "false"/"0" (common/device.lua).
local text, to_bool = device.text, device.to_bool

-- Formatting -----------------------------------------------------------------

local function whole(v)
	return math.floor(v + 0.5)
end

local function fahrenheit(c)
	return c * 9 / 5 + 32
end

-- "21.53", "21.5", "21": at most `places` decimals, no trailing zeros.
local function decimal(v, places)
	local s = string.format("%." .. places .. "f", v)
	if s:find(".", 1, true) then
		s = s:gsub("0+$", ""):gsub("%.$", "")
	end
	if s == "-0" then
		s = "0"
	end
	return s
end

-- The controller's "14:02" for an os.time() value: the rows show the time a
-- value arrived here (EC R10).
local function clock(t)
	return os.date("%H:%M", t)
end

-- The bridge's ISO 8601 change time as the controller shows it: "14:02"
-- today, "10-25 14:02" before; nil when it cannot be read
-- [verified: API 22/_27, C4:ParseIso8601DateTime, 2.7.0, UTC epoch].
local function bridge_time(iso)
	if not iso or not C4.ParseIso8601DateTime then
		return nil
	end
	local ok, _, epoch = pcall(C4.ParseIso8601DateTime, C4, iso)
	if not ok or type(epoch) ~= "number" then
		return nil
	end
	if os.date("%Y-%m-%d", epoch) == os.date("%Y-%m-%d") then
		return os.date("%H:%M", epoch)
	end
	return os.date("%m-%d %H:%M", epoch)
end

-- Identity -------------------------------------------------------------------

local function is_area()
	return st.kind == KIND_AREA
end

-- "Hue motion sensor" / "MotionAware area": what the device stands for.
local function kind_label()
	return is_area() and "MotionAware area" or "Hue motion sensor"
end

-- A reading the device takes: a sensor's (unknown counts as present), never
-- an area's (§2.3: an area's reading variables stay 0).
local function has(what)
	return not is_area() and st.has[what] ~= false
end

-- "Hue motion sensor Hallway sensor in Hallway", "MotionAware area Home
-- motion (whole home)": the Status while all is well.
local function identity_status()
	local s = kind_label() .. " " .. (st.name or st.rid or "?")
	local room = st.hue_room
	if room then
		s = s .. (room:sub(1, 1) == "(" and " " or " in ") .. room
	end
	return s
end

local function forgotten_status()
	return string.format("Forgotten by the bridge (was %s %s)", kind_label(),
		st.forgotten.name or st.rid or "unknown")
end

-- Shown while the bridge has configured the device as deleted in Hue but
-- has not sent its own text yet (the bridge's names the day).
local function gone_status()
	return (is_area() and "Area" or "Sensor") .. " deleted in Hue; re-link or Forget"
end

-- The Status, most important first: a forgotten device says so even once
-- unbound; the bridge's text (§3: absent means fine) stands for everything
-- the bridge knows (EC §6).
local function status_text()
	if st.forgotten then
		return forgotten_status()
	elseif not bridge then
		return "Not bound to a Hue Bridge"
	elseif not st.rid then
		return "Bound; waiting for the bridge"
	elseif bridge_status then
		return bridge_status
	elseif st.gone then
		return gone_status()
	elseif not state_seen then
		return "Waiting for the bridge"
	end
	return identity_status()
end

-- Rows -----------------------------------------------------------------------

-- A row is written when its text changes.
local function row(name, value)
	value = value == nil and "" or tostring(value)
	if rows[name] == value then
		return
	end
	rows[name] = value
	prop(name, value)
end

local function refresh_status()
	row("Status", status_text())
end

-- The mark after a reading kept while the sensor is offline (unreachable,
-- deleted or forgotten in Hue, or the device unbound): "(old, 14:02)", the
-- time Online went false (EC §6). A sensor switched off in the Hue app is
-- still online, and the bridge passes on the light level and temperature
-- only while their own services report, so its rows get no mark.
local function mark()
	if pv.online ~= false or not pv.offline_since then
		return ""
	end
	return string.format(" (old, %s)", clock(pv.offline_since))
end

local function light_level_text()
	if st.has.light_level == false then
		return "Not available"
	elseif pv.lux == nil then
		return ""
	end
	local lux = whole(pv.lux)
	return (lux <= 0 and "Dark" or string.format("%d lux", lux)) .. mark()
end

local function temperature_text()
	if st.has.temperature == false then
		return "Not available"
	elseif pv.temp_c == nil then
		return ""
	end
	return string.format("%.1f °C (%.1f °F)", pv.temp_c, fahrenheit(pv.temp_c)) .. mark()
end

local function battery_text()
	if st.has.battery == false then
		return "Not available"
	end
	local level, state = pv.battery_level, pv.battery_state
	local s
	if level and state then
		s = string.format("%d %% (%s)", whole(level), state)
	elseif level then
		s = string.format("%d %%", whole(level))
	elseif state then
		s = state
	else
		return ""
	end
	return s .. mark()
end

-- "Motion since 14:02" / "No motion since 14:05" with the bridge's time of
-- the change, "Unknown" while Hue's state is not known (§2.2).
local function hue_motion_text()
	if hue_motion == nil then
		return "Unknown"
	end
	local word = hue_motion and "Motion" or "No motion"
	local at = bridge_time(hue_changed)
	return at and (word .. " since " .. at) or word
end

local function refresh_rows()
	row("Online", pv.online == nil and "" or (pv.online and "Yes" or "No"))
	local enabled = ""
	if pv.enabled == true then
		enabled = "Yes"
	elseif pv.enabled == false then
		enabled = is_area() and "Paused in the Hue app" or "Switched off in the Hue app"
	end
	row("Enabled", enabled)
	row("Hue Motion", hue_motion_text())
	row("Light Level", light_level_text())
	row("Temperature", temperature_text())
	row("Battery", battery_text())
end

local function refresh_identity()
	local kind = ""
	if st.kind == KIND_SENSOR then
		kind = "Motion sensor"
	elseif st.kind == KIND_AREA then
		kind = "MotionAware area"
	end
	row("Kind", kind)
	row("Hue Name", st.name)
	row("Hue Room", st.hue_room)
	row("Model", st.model or (is_area() and "MotionAware area" or nil))
end

-- An area's device hides the sensor rows; a sensor's (or one whose kind is
-- not known yet) shows them [verified: API 24_properties/_4,
-- SetPropertyAttribs(name, 1) hides, 0 shows; not in OnDriverInit]. Applied
-- at late init and when a configure changes the kind; looked up first and
-- protected, as the scene driver does, so a runtime without it only skips it.
local function apply_rows_visibility()
	local hide = is_area()
	if rows_hidden == hide then
		return
	end
	rows_hidden = hide
	if not C4.SetPropertyAttribs then
		return log.debug("no C4:SetPropertyAttribs here; sensor rows left as they are")
	end
	for _, name in ipairs(SENSOR_ROWS) do
		local ok, err = pcall(C4.SetPropertyAttribs, C4, name, hide and 1 or 0)
		if not ok then
			log.warn("could not %s %s: %s", hide and "hide" or "show", name, tostring(err))
		end
	end
end

-- Persisted values -----------------------------------------------------------

local function load_values()
	pv = {}
	local stored = C4:PersistGetValue(VALUES_KEY)
	if type(stored) ~= "table" then
		return
	end
	for _, field in ipairs(NUMBER_VALUES) do
		pv[field] = tonumber(stored[field])
	end
	for _, field in ipairs(BOOL_VALUES) do
		if type(stored[field]) == "boolean" then
			pv[field] = stored[field]
		end
	end
	if BATTERY_STATES[stored.battery_state] then
		pv.battery_state = stored.battery_state
	end
end

-- A copy goes to the store: the table stays this driver's to change.
local function save_values()
	local copy = {}
	for k, v in pairs(pv) do
		copy[k] = v
	end
	C4:PersistSetValue(VALUES_KEY, copy)
end

local function load_identity()
	for field, key in pairs(PERSISTED) do
		local value = C4:PersistGetValue(key)
		st[field] = (value ~= nil and value ~= "") and tostring(value) or nil
	end
	if st.kind and not KINDS[st.kind] then
		log.warn("persisted kind %q is not one this build knows; taken as a sensor", st.kind)
		st.kind = nil
	end
	local shown_value = C4:PersistGetValue(SHOWN_KEY)
	if shown_value == "open" then
		shown = true
	elseif shown_value == "closed" then
		shown = false
	else
		shown = nil
	end
end

-- An empty value would not remove a stored one [verified: API 26.5/_4], so a
-- field that went back to none is deleted.
local function save_identity()
	for field, key in pairs(PERSISTED) do
		if st[field] then
			C4:PersistSetValue(key, st[field])
		else
			C4:PersistDeleteValue(key)
		end
	end
end

-- Variables and events -------------------------------------------------------

local function bool_value(b)
	return b and "1" or "0" -- a BOOL variable takes "1" / "0" [verified: API 36/_1]
end

-- What each variable holds, from the persisted values: never an invented
-- value, so one keeps its last value when its reading is lost, and an area's
-- readings stay 0 (§2.3).
local function variable_values()
	local c = pv.temp_c
	return {
		["Online"] = bool_value(pv.online == true),
		["Enabled"] = bool_value(pv.enabled == true),
		["Light Level"] = string.format("%d", pv.lux and whole(pv.lux) or 0),
		["Temperature C"] = c and string.format("%.1f", c) or "0",
		["Temperature F"] = c and string.format("%.1f", fahrenheit(c)) or "0",
		["Battery Level"] = string.format("%d", pv.battery_level and whole(pv.battery_level) or 0),
		["Battery Low"] = bool_value(pv.battery_state == "low" or pv.battery_state == "critical"),
	}
end

-- OnDriverInit: the variables, always in the same order, each starting at its
-- persisted value; read-only, since only the driver knows the sensor. A
-- variable that already exists (the driver updated in place) keeps its value
-- and AddVariable answers false [verified: API 36/_1].
local function add_variables()
	load_values()
	local values = variable_values()
	for _, v in ipairs(VARIABLES) do
		local added, id = C4:AddVariable(v.name, values[v.name], v.type, true, false)
		vars[v.name] = values[v.name]
		log.debug("variable %s %s (%s)", v.name, added and ("added as " .. tostring(id)) or "already there",
			values[v.name])
	end
end

-- Set the variables whose value changed [verified: API 36/_7; not in
-- OnDriverInit].
local function update_variables()
	local values = variable_values()
	for _, v in ipairs(VARIABLES) do
		local value = values[v.name]
		if vars[v.name] ~= value then
			vars[v.name] = value
			C4:SetVariable(v.name, value)
		end
	end
end

-- Events wait until the variables are set, so programming that runs on one
-- reads the new value.
local function queue_event(id, why)
	queued[#queued + 1] = { id = id, why = why }
end

local function fire_events()
	local due = queued
	queued = {}
	for _, e in ipairs(due) do
		log.info("event %d: %s", e.id, e.why)
		C4:FireEventByID(e.id) -- [verified: API 7/_4; not in OnDriverInit]
	end
end

-- After every change: the store, the variables, then the events, then the rows.
local function commit()
	if dirty then
		dirty = false
		save_values()
	end
	update_variables()
	fire_events()
	refresh_rows()
	refresh_status()
end

-- The temperature output ------------------------------------------------------
-- VALUE_CHANGED with CELSIUS, FAHRENHEIT and TIMESTAMP, VALUE_UNAVAILABLE with
-- STATUS offline [verified: PP 97/_2, C4R §3.1], sent as NOTIFY on binding 2,
-- as Snap One's Temperature Display sends them on its own TEMPERATURE_VALUE
-- output [verified: C4R "TD", common/c4_notify.lua]. An area, or a sensor
-- without a temperature, never sends on it.

local function send_value_changed()
	local c = pv.temp_c
	C4:SendToProxy(TEMPERATURE_BINDING, "VALUE_CHANGED", {
		CELSIUS = decimal(c, 2),
		FAHRENHEIT = decimal(fahrenheit(c), 2),
		TIMESTAMP = string.format("%d", temp_at),
	}, "NOTIFY")
end

local function send_value_unavailable()
	C4:SendToProxy(TEMPERATURE_BINDING, "VALUE_UNAVAILABLE", { STATUS = "offline" }, "NOTIFY")
end

-- What the output says now: the last reading while it is current, that it is
-- unavailable once lost; nothing before the first reading since the start
-- (EC §6). For binding 2 becoming bound and GET_SENSOR_VALUE.
local function send_temperature()
	if not has("temperature") then
		return
	end
	if temp_out == "available" then
		send_value_changed()
	elseif temp_out == "unavailable" then
		send_value_unavailable()
	end
end

-- The reading is lost (the sensor offline, deleted, forgotten, switched off
-- or paused, or the device unbound): VALUE_UNAVAILABLE once, when there was
-- a value. The next current reading makes it available again.
local function temperature_lost()
	if not has("temperature") or pv.temp_c == nil or temp_out == "unavailable" then
		return
	end
	temp_out = "unavailable"
	log.debug("temperature output unavailable")
	send_value_unavailable()
end

-- Online and Enabled -----------------------------------------------------------
-- The events fire on a change between two known values only. Going offline
-- marks the readings kept as old and makes the temperature unavailable.

local function set_online(online)
	local was = pv.online
	if was == online then
		return
	end
	pv.online = online
	pv.offline_since = (online == false) and os.time() or nil
	dirty = true
	if online == false then
		temperature_lost()
	end
	if was == true and online == false then
		queue_event(EVENT.OFFLINE, "offline")
	elseif was == false and online == true then
		queue_event(EVENT.ONLINE, "online again")
	end
end

local function set_enabled(enabled)
	local was = pv.enabled
	if was == enabled then
		return
	end
	pv.enabled = enabled
	dirty = true
	if was == true and enabled == false then
		queue_event(EVENT.SWITCHED_OFF, is_area() and "paused in the Hue app" or "switched off in the Hue app")
	elseif was == false and enabled == true then
		queue_event(EVENT.SWITCHED_ON, is_area() and "resumed in the Hue app" or "switched on in the Hue app")
	end
end

-- Readings ---------------------------------------------------------------------

local function take_lux(raw)
	local lux = tonumber(raw)
	if not lux or lux < 0 then
		return log.warn("HUE_MOTION_STATE lux %q ignored", tostring(raw))
	elseif not has("light_level") then
		return log.debug("lux %s ignored: no light level on this %s", tostring(raw), kind_label())
	end
	pv.lux = lux
	dirty = true
	local fired = pv.lux_fired
	if fired == nil then
		pv.lux_fired = lux -- the first reading only sets the baseline
	elseif math.abs(lux - fired) >= math.max(LUX_STEP, LUX_SHARE * fired) - EPSILON then
		pv.lux_fired = lux
		queue_event(EVENT.LIGHT_LEVEL_CHANGED, string.format("light level %s -> %s lux", decimal(fired, 2),
			decimal(lux, 2)))
	end
end

-- A reading the bridge passes on while the sensor is offline is the last one
-- it had: kept and shown as old, never put on the temperature output.
local function take_temperature(raw)
	local c = tonumber(raw)
	if not c or c < -100 or c > 100 then
		return log.warn("HUE_MOTION_STATE temperature %q ignored", tostring(raw))
	elseif not has("temperature") then
		return log.debug("temperature %s ignored: no temperature on this %s", tostring(raw), kind_label())
	end
	pv.temp_c = c
	dirty = true
	local fired = pv.temp_fired
	if fired == nil then
		pv.temp_fired = c
	elseif math.abs(c - fired) >= TEMPERATURE_STEP - EPSILON then
		pv.temp_fired = c
		queue_event(EVENT.TEMPERATURE_CHANGED, string.format("temperature %s -> %s °C", decimal(fired, 2),
			decimal(c, 2)))
	end
	if pv.online ~= false then
		temp_out, temp_at = "available", os.time()
		send_value_changed()
	end
end

-- Battery Low when the state becomes low or critical (from normal or not
-- known), Battery Normal when it is normal again (§2.4).
local function take_battery(level_raw, state_raw)
	if not has("battery") then
		return log.debug("battery ignored: no battery on this %s", kind_label())
	end
	if level_raw ~= nil then
		local level = tonumber(level_raw)
		if level and level >= 0 and level <= 100 then
			pv.battery_level = level
			dirty = true
		else
			log.warn("HUE_MOTION_STATE battery_level %q ignored", tostring(level_raw))
		end
	end
	if state_raw ~= nil then
		if not BATTERY_STATES[state_raw] then
			return log.warn("HUE_MOTION_STATE battery_state %q ignored", tostring(state_raw))
		end
		local was = pv.battery_state
		pv.battery_state = state_raw
		dirty = true
		local low = state_raw ~= "normal"
		local was_low = was == "low" or was == "critical"
		if low and not was_low then
			queue_event(EVENT.BATTERY_LOW, "battery " .. state_raw)
		elseif was_low and not low then
			queue_event(EVENT.BATTERY_NORMAL, "battery normal again")
		end
	end
end

-- The proxy ---------------------------------------------------------------------
-- OPENED / CLOSED fire the stock "senses motion" / "stops sensing motion";
-- STATE_OPENED / STATE_CLOSED tell the state without an event. All four go as
-- NOTIFY with an empty table [verified: PP 112/_1 to _4, API 25/_6], never
-- before OnDriverLateInit (bridge messages wait for it, see below).

local function proxy_notify(command)
	log.debug("-> proxy %s", command)
	C4:SendToProxy(PROXY_BINDING, command, {}, "NOTIFY")
end

local function set_shown(open)
	if shown ~= open then
		shown = open
		C4:PersistSetValue(SHOWN_KEY, open and "open" or "closed")
	end
end

-- The proxy is to show `open`. The first state after a start goes as STATE_*
-- unless it differs from what the proxy last got (persisted), which goes as
-- OPENED / CLOSED so programming catches up; later only a change goes out
-- (§2.7, EC R4).
local function report(open, why)
	local command
	if not sent_since_start then
		sent_since_start = true
		if shown == nil or shown == open then
			command = open and "STATE_OPENED" or "STATE_CLOSED"
		else
			command = open and "OPENED" or "CLOSED"
		end
	elseif shown ~= open then
		command = open and "OPENED" or "CLOSED"
	end
	if command then
		log.info("%s (%s)", command, why)
		proxy_notify(command)
	end
	set_shown(open)
end

-- Occupancy hold (D10, EC R11): Hue's "no motion" keeps the sensor open for
-- hold_s seconds, new motion cancels the wait, and a hold cut by a restart
-- starts again in full at the next "no motion".

local function cancel_hold()
	if hold then
		hold.timer:Cancel()
		hold = nil
	end
end

local function start_hold()
	local h = {}
	h.timer = C4:SetTimer(hold_s * 1000, function() -- [verified: API 34/_1]
		if hold ~= h then
			return -- cancelled already: only a timer firing despite its Cancel gets here
		end
		hold = nil
		-- During a test the proxy shows the test state: its end puts Hue's back.
		if hue_motion == false and not test then
			report(false, "no motion; hold time over")
		end
	end)
	hold = h
	log.debug("no motion; holding for %d s", hold_s)
end

local function cancel_test()
	if test then
		test.timer:Cancel()
		test = nil
	end
end

-- Hue's own motion reading. "motion" opens at once and ends a hold; "no
-- motion" closes at once, or with a hold time starts the hold while the
-- proxy shows motion (a repeated "no motion" leaves a running hold alone).
-- The reading also ends a test (EC R12): what the proxy showed before the
-- test decides whether a hold applies.
local function take_motion(open, changed)
	hue_motion, hue_changed = open, changed
	local showing = shown
	if test then
		showing = test.before
		cancel_test()
	end
	if open then
		cancel_hold()
		report(true, "motion")
	elseif hold_s > 0 and (hold or showing == true) then
		if not hold then
			start_hold()
		end
		report(true, "no motion, held") -- STATE_OPENED as the first state after a start, else no change
	else
		cancel_hold()
		report(false, "no motion")
	end
end

-- A deliberate end (the sensor deleted or switched off in Hue, the area
-- paused or deleted, the device forgotten or unbound): CLOSED once if the
-- proxy shows motion, at once, never held; nothing otherwise (EC §6, §2.7).
-- Hue's own state is no longer known.
local function deliberate_end(why)
	cancel_hold()
	cancel_test()
	hue_motion, hue_changed = nil, nil
	if shown == true then
		report(false, why)
	end
end

-- Test: Motion / Test: No Motion (§2.6, EC R12): the test state goes to the
-- proxy as a change, so the stock event fires; Hue's state, with the hold,
-- comes back as a change with the next reading or after TEST_MS. With Hue's
-- state unknown (no sensor at all), what the proxy showed before the first
-- test comes back, closed if it showed nothing.
local function held_state(before)
	if hue_motion == true or hold then
		return true
	elseif hue_motion == false then
		return false
	end
	return before == true
end

local function run_test(open)
	local before = shown
	if test then
		before = test.before
	end
	cancel_test()
	log.info("test: %s", open and "OPENED" or "CLOSED")
	proxy_notify(open and "OPENED" or "CLOSED")
	sent_since_start = true
	set_shown(open)
	local t = { before = before }
	t.timer = C4:SetTimer(TEST_MS, function()
		if test ~= t then
			return
		end
		test = nil
		local target = held_state(t.before)
		if target == shown then
			return log.info("test over; the sensor already shows %s", target and "motion" or "no motion")
		end
		local command = target and "OPENED" or "CLOSED"
		log.info("test over: %s", command)
		proxy_notify(command)
		set_shown(target)
	end)
	test = t
	result(string.format("Test: %s sent; Hue's state returns within %d s", open and "motion" or "no motion",
		TEST_MS / 1000))
end

-- The bridge ---------------------------------------------------------------------
-- Every message to the bridge passes allowEmptyValues false and logCommand
-- only in Debug Mode, as the bridge's own device_send does (§3) [verified: API
-- 32_serial_network_device/_19]; protected, as common/device.lua's send.

local function to_bridge(command, params)
	if not bridge then
		return false
	end
	local ok, err = pcall(function()
		C4:SendToDevice(bridge, command, params, false, log.enabled("debug"))
	end)
	if not ok then
		log.error("%s to the bridge failed: %s", command, tostring(err))
	end
	return ok
end

-- HUE_MOTION_HELLO carries the persisted identity, so the bridge can adopt a
-- bound device its registry lacks; rid "" while unknown (§3).
local function hello_params()
	return { rid = st.rid or "", device_id = device_id(), name = st.name, kind = st.kind, model = st.model }
end

local function cancel_give_up()
	if give_up then
		give_up:Cancel()
		give_up = nil
	end
end

-- Announce ourselves; the bridge answers with HUE_MOTION_CONFIGURE and the
-- state when it knows the rid. `hint` is the device id OnBindingChanged
-- named, for when Director's lookup does not show the new binding yet.
local function hello(hint)
	bridge = bound_bridge() or tonumber(hint)
	if bridge then
		cancel_give_up()
		to_bridge("HUE_MOTION_HELLO", hello_params())
		dev.flush_log() -- dev builds: lines logged while the bridge was unknown
	end
	refresh_status()
end

-- Unbound from the bridge (an actual unbind, or still unbound after the
-- start-up re-check): a deliberate end (EC §6 "Not bound to a Hue Bridge").
-- What the bridge last said is forgotten: bound again, the device waits for
-- its next state.
local function unbound(why)
	bridge = nil
	bridge_status, state_seen, ended_now = nil, false, nil
	cancel_give_up()
	deliberate_end(why)
	set_online(false)
	commit()
end

-- Properties ----------------------------------------------------------------------

-- 0 to 3600 s (driver.xml); a changed value applies from the next "no motion"
-- (EC R11): a hold already running keeps its length.
dispatch.properties["Occupancy_Hold_Time_(s)"] = function(value)
	local n = tonumber(value)
	if not n then
		if value ~= nil and value ~= "" then
			log.warn("Occupancy Hold Time %q is not a number; using 0", tostring(value))
		end
		n = 0
	end
	n = math.max(0, math.min(HOLD_MAX_S, math.floor(n)))
	if n ~= hold_s then
		log.info("Occupancy Hold Time %d s", n)
	end
	hold_s = n
end

-- From the bridge (ExecuteCommand) --------------------------------------------------
-- Director late-inits drivers in no particular order, so the bridge's
-- messages can reach the device before its own OnDriverLateInit, where
-- UpdateProperty and SendToProxy are not yet safe; after_late_init
-- (common/device.lua) holds them until then, in order.

-- A configure carries the bridge's whole registry entry, so what it leaves
-- out is taken as none. A new rid is a re-link: the readings of the old
-- sensor stay until the new one reports, Hue's state is not known yet, and
-- a hold starts again. It also ends a forgotten state. One configured as
-- deleted in Hue is a deliberate end (EC §6).
dispatch.commands["HUE_MOTION_CONFIGURE"] = after_late_init("HUE_MOTION_CONFIGURE", function(params)
	params = params or {}
	local before_rid = st.rid
	if text(params.rid) then
		st.rid = params.rid
	end
	local kind = text(params.kind)
	if kind and KINDS[kind] then
		if st.kind and st.kind ~= kind then
			log.info("now a %s (was a %s)", kind, st.kind)
		end
		st.kind = kind
	elseif kind then
		log.warn("HUE_MOTION_CONFIGURE with unknown kind %s ignored", kind)
	end
	st.name = text(params.name) or st.name
	st.model = text(params.model)
	st.hue_room = text(params.hue_room)
	st.id_v1 = text(params.id_v1)
	st.has = {
		light_level = to_bool(params.has_light_level),
		temperature = to_bool(params.has_temperature),
		battery = to_bool(params.has_battery),
	}
	st.gone = to_bool(params.gone) == true
	st.forgotten = nil
	if before_rid and st.rid ~= before_rid then
		log.info("now linked to %s (was %s)", tostring(st.rid), before_rid)
		bridge_status, ended_now = nil, nil
		cancel_hold()
		hue_motion, hue_changed = nil, nil
	end
	log.debug("configured: %s %s %s", tostring(st.kind), tostring(st.name), tostring(st.id_v1 or st.rid))
	save_identity()
	apply_rows_visibility()
	refresh_identity()
	if st.gone and ended_now ~= "deleted" then
		ended_now = "deleted"
		deliberate_end("deleted in Hue")
		set_online(false)
	end
	commit()
end)

-- A deliberate end the bridge names (§3), as it begins: deleted or forgotten
-- take the device offline, switched off or paused disable it, and each makes
-- the temperature unavailable (EC §6).
local function end_by_bridge(ended)
	if not ENDS[ended] then
		log.warn("HUE_MOTION_STATE ended %q is not known; taken as a deliberate end", ended)
	end
	deliberate_end(ended)
	if ended == "off" or ended == "paused" then
		set_enabled(false)
	elseif ended == "deleted" or ended == "forgotten" then
		set_online(false)
	end
	temperature_lost()
end

-- Every state the bridge reports (§3); a value it leaves out is unchanged,
-- except the Status text and the end, which the bridge repeats while they
-- last and whose absence means all is well. A failure (online false:
-- unreachable, flat battery, an area not running) leaves the sensor as it is
-- (D3); a deliberate end closes it once, when it begins (EC §6). The light
-- level, temperature and battery are taken whatever the state: the bridge
-- passes on only what Hue still reports, and while the sensor is offline the
-- last values it had, shown as old.
dispatch.commands["HUE_MOTION_STATE"] = after_late_init("HUE_MOTION_STATE", function(params)
	params = params or {}
	if st.rid and params.rid and params.rid ~= st.rid then
		return log.warn("HUE_MOTION_STATE for rid %s ignored (ours is %s)", tostring(params.rid), st.rid)
	end
	log.debug("state (%s)", tostring(params.reason))
	state_seen = true
	bridge_status = text(params.status)
	local online, enabled = to_bool(params.online), to_bool(params.enabled)
	if online ~= nil then
		set_online(online)
	end
	if enabled ~= nil then
		set_enabled(enabled)
	end
	local ended = text(params.ended)
	if ended ~= ended_now then
		if ended then
			end_by_bridge(ended)
		end
		ended_now = ended
	end
	if params.motion ~= nil then
		local open = to_bool(params.motion)
		if ended then
			log.debug("motion %s ignored: %s", tostring(params.motion), ended)
		elseif open == nil then
			log.warn("HUE_MOTION_STATE motion %q ignored", tostring(params.motion))
		else
			take_motion(open, text(params.motion_changed))
		end
	end
	if params.lux ~= nil then
		take_lux(params.lux)
	end
	if params.temperature ~= nil then
		take_temperature(params.temperature)
	end
	if params.battery_level ~= nil or params.battery_state ~= nil then
		take_battery(params.battery_level, text(params.battery_state))
	end
	commit()
end)

-- The bridge ran Forget for this device: a deliberate end; the device stays,
-- the owner decides. The identity stays persisted too, so binding the device
-- again and Link Devices on the bridge can link it again.
dispatch.commands["HUE_MOTION_FORGOTTEN"] = after_late_init("HUE_MOTION_FORGOTTEN", function(params)
	params = params or {}
	if st.rid and params.rid and params.rid ~= st.rid then
		return log.warn("HUE_MOTION_FORGOTTEN for rid %s ignored (ours is %s)", tostring(params.rid), st.rid)
	end
	st.forgotten = { name = text(params.name) or st.name }
	deliberate_end("forgotten by the bridge")
	set_online(false)
	log.warn("forgotten by the bridge (was %s %s)", kind_label(), st.forgotten.name or st.rid or "unknown")
	prop("Last Action", FORGOTTEN_INSTRUCTION)
	commit()
end)

-- Composer actions (LUA_ACTION) ------------------------------------------------------
-- Every click ends in Last Action and a log line, whatever happened.

dispatch.commands["Refresh_From_Bridge"] = function()
	bridge = bound_bridge() or bridge
	if not bridge then
		refresh_status()
		return result("Not sent: not bound to a Hue Bridge")
	end
	to_bridge("HUE_MOTION_HELLO", hello_params())
	result("Asked the bridge for this device's state; its answer updates the rows")
end

dispatch.commands["Test_Motion"] = function()
	run_test(true)
end

dispatch.commands["Test_No_Motion"] = function()
	run_test(false)
end

-- From the proxies (ReceivedFromProxy) -------------------------------------------------
-- Commands without a handler are logged at debug by common.dispatch.

-- The contact proxy asks for the state: STATE_* once one is known, nothing
-- before (C4R §1.5, §4.3).
dispatch.proxy["GET_STATE"] = function()
	if not sent_since_start or shown == nil then
		return log.debug("GET_STATE before the state is known: not answered")
	end
	proxy_notify(shown and "STATE_OPENED" or "STATE_CLOSED")
end

-- A Temperature Display or a thermostat on binding 2 asks for the value.
dispatch.proxy["GET_SENSOR_VALUE"] = function()
	send_temperature()
end

-- Conditionals -------------------------------------------------------------------------
-- [verified: FUND 10/_4]: a BOOL's VALUE is the true or false text picked in
-- programming; a NUMBER's VALUE is the whole number typed and LOGIC the
-- operator. A NUMBER conditional compares whole numbers (FUND 10/_1), so the
-- current value is rounded to one; each reads the variable of its name.

local COMPARE = {
	EQUAL = function(a, b) return a == b end,
	NOT_EQUAL = function(a, b) return a ~= b end,
	LESS_THAN = function(a, b) return a < b end,
	LESS_THAN_OR_EQUAL = function(a, b) return a <= b end,
	GREATER_THAN = function(a, b) return a > b end,
	GREATER_THAN_OR_EQUAL = function(a, b) return a >= b end,
}

function TestCondition(name, params)
	local c = CONDITIONALS[name]
	if not c then
		log.debug("TestCondition %s: not one of this driver's", tostring(name))
		return false
	end
	params = params or {}
	local value = tonumber(vars[c.var]) or 0
	local result_value
	if c.bool then
		local want = to_bool(params.VALUE)
		if want == nil then
			want = params.VALUE == "True"
		end
		result_value = (value == 1) == want
		if params.LOGIC == "NOT_EQUAL" then
			result_value = not result_value
		end
	else
		local compare, target = COMPARE[params.LOGIC or "EQUAL"], tonumber(params.VALUE)
		result_value = compare ~= nil and target ~= nil and compare(whole(value), target)
	end
	log.debug("TestCondition %s %s %s: %s", name, tostring(params.LOGIC), tostring(params.VALUE),
		tostring(result_value))
	return result_value
end

-- Lifecycle ---------------------------------------------------------------------------

dispatch.install(_G)

function OnDriverInit()
	add_variables()
end

-- After a Director restart the binding to the bridge can be invisible at late
-- init although Composer shows it; while unbound the device looks again at 5,
-- 15, 30 and 60 s (common/device.lua) and greets the bridge once it is
-- visible. Until GIVE_UP_MS it changes nothing else (EC C11, C12).
function dev.on_bridge_found()
	hello()
end
local schedule_recheck, cancel_recheck = dev.schedule_recheck, dev.cancel_recheck

local function arm_give_up()
	cancel_give_up()
	give_up = C4:SetTimer(GIVE_UP_MS, function()
		give_up = nil
		if bridge then
			return
		end
		if bound_bridge() then
			return dev.on_bridge_found()
		end
		log.info("still not bound to a Hue Bridge %d s after the start", GIVE_UP_MS / 1000)
		unbound("not bound to a Hue Bridge")
	end)
end

function OnDriverLateInit()
	rows, rows_hidden = {}, nil -- Composer shows driver.xml's defaults until written again
	sent_since_start, state_seen, bridge_status = false, false, nil
	load_identity()
	load_values()
	dispatch.replay_properties(Properties)
	dev.show_driver_version(1)
	apply_rows_visibility()
	refresh_identity()
	-- The bridge first, so messages it sent before this point are applied
	-- against the right binding state; then the hello carries whatever
	-- identity they delivered.
	bridge = bound_bridge()
	dev.late_init()
	hello()
	if not bridge then
		schedule_recheck(1)
		arm_give_up()
	end
	commit()
	-- Last: a binding change Director delivered before late init acts now
	-- (common/device.lua), against the binding state read above.
	dev.replay_bindings()
end

-- Control bindings only (the proxy's is not one): the bridge's, and the
-- temperature output, which a newly bound consumer reads at once (§2.7). A
-- call before late init waits for it (common/device.lua).
OnBindingChanged = dev.binding_changed(function(idBinding, _, bound, otherDevice)
	if idBinding == TEMPERATURE_BINDING then
		if bound then
			send_temperature()
		end
		return
	end
	if idBinding ~= BRIDGE_BINDING then
		return
	end
	cancel_recheck()
	if bound then
		hello(otherDevice)
	else
		unbound("not bound to a Hue Bridge")
	end
end)

-- Composer is deleting this device: tell the bridge, so it tombstones the
-- entry (HUE_MOTION_GOODBYE, as HUE_SCENE_GOODBYE). OnDriverDestroyed follows
-- and stops the timers.
function OnDriverRemovedFromProject()
	if to_bridge("HUE_MOTION_GOODBYE", { rid = st.rid or "", device_id = device_id() }) then
		log.debug("HUE_MOTION_GOODBYE sent to bridge %d", bridge)
	end
end

function OnDriverDestroyed()
	cancel_hold()
	cancel_test()
	cancel_give_up()
	dev.cancel_timers() -- the binding re-check and the Driver Version looks
end
