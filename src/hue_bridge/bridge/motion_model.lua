-- Hue motion sensors and MotionAware areas as plain records
-- (docs/motion-design.md §4.1): the parsing half of the motion feature, as
-- hue_model.lua is the lights'. Pure Lua: no C4 calls, no I/O, no state.
-- bridge/motion.lua keeps the caches and decides what a device is told.
--
-- Shapes consumed (docs/motion-hue-research.md, HR below; every id a CLIP v2
-- resource id, see hue_model.resource_id):
--   motion, convenience_area_motion, security_area_motion
--       { id, owner{rid, rtype}, id_v1?, enabled, motion{motion_report{changed, motion},
--         motion (deprecated), motion_valid (deprecated)}, sensitivity{...} }      HR §1.3, §2.4
--   light_level   { id, owner, id_v1, enabled, light{light_level_report{changed, light_level},
--                   light_level (deprecated), light_level_valid (deprecated)} }      HR §1.4
--   temperature   { id, owner, id_v1, enabled, temperature{temperature_report{changed,
--                   temperature}, temperature, temperature_valid (deprecated)} }     HR §1.5
--   device_power  { id, owner, id_v1, power_state{battery_level, battery_state} }   HR §1.6
--   zigbee_connectivity { id, owner, status, mac_address }                          HR §1.7
--   motion_area_configuration { id, name, group{rid, rtype}, participants[{resource{rid,
--                   rtype}, status{health}}], services[{rid, rtype}], health, enabled }  HR §2.3
-- Event items carry only the blocks that changed (HR §3.1), a delete item
-- only id and type: every function here takes what it is given and leaves
-- the rest nil, so a caller merges partial readings into what it holds.
--
-- Interface (all functions of the module table; nothing keeps state):
--   time_of(iso)          seconds since 1970 (UTC, fractional) of a bridge time
--                         "2026-10-26T07:02:41.318Z"; nil when it does not parse.
--                         Bridge times are compared only with each other (EC rule 5).
--   newer(a, b)           true when bridge time a is strictly later than b (both parse)
--   lux(v)                whole lux from a raw light level: 10^((v-1)/10000) rounded,
--                         0 for v = 0 ("too dark to measure"); nil for junk
--   reading(item)         the normalised fields of one item of READING_TYPES, or nil:
--                           motion, changed, valid, enabled      (motion and the area services)
--                           lux, changed, valid, enabled         (light_level)
--                           temperature, changed, valid, enabled (temperature, °C)
--                           battery_level, battery_state         (device_power)
--                           status                               (zigbee_connectivity)
--                           enabled, health                      (motion_area_configuration)
--                         A field the item does not carry stays nil.
--   merge(cached, fresh, source)   fold a reading into the one held (EC rule 5, R6);
--                         source { event = n } or { get = n, complete = true };
--                         returns the list of field names whose value changed
--   owned(services_by_type)        owner rid → { motion = rid, light_level = rid,
--                         temperature = rid, device_power = rid, zigbee = rid,
--                         convenience = rid, security = rid, id_v1 = the motion's }
--   sensor(rid, device, owned, groups)   one sensor record (below)
--   sensors(devices, services_by_type, groups)   device rid → sensor record, one per
--                         device that owns a `motion` service
--   area(item, owned)     one area record (below), nil for an item without a resource id
--   areas(configs, services_by_type)   configuration rid → area record
--   area_motion(record, readings)   the reading an area's motion is, and the service rid
--   model_text(record)    "Hue motion sensor (SML003)"; "MotionAware area"
--   tag(record)           "#12" (a sensor's /sensors/N, else 8 characters of its rid);
--                         "#ac00" (4 characters of an area's rid)
--
-- A sensor record: { rid (the device), kind = "sensor", name, model_id, product_name,
--   id_v1, room (the Hue room rid, through `groups`), room_name (its label), motion,
--   light_level, temperature, device_power, zigbee (service rids) }.
-- An area record: { rid (the configuration), kind = "area", name, group = { rid, rtype },
--   enabled, health, participants (count), unhealthy (count), convenience, security
--   (service rids), partial (true when Hue left out the name, group or health, EC A16) }.

local hue_model = require("bridge.hue_model")

local motion_model = {}

-- The item types reading() understands, and the sensor service each feeds.
motion_model.READING_TYPES = {
	motion = true,
	light_level = true,
	temperature = true,
	device_power = true,
	zigbee_connectivity = true,
	convenience_area_motion = true,
	security_area_motion = true,
	motion_area_configuration = true,
}

-- Service type → the record field holding its rid (docs/motion-design.md §4.1).
motion_model.SERVICE_FIELDS = {
	motion = "motion",
	light_level = "light_level",
	temperature = "temperature",
	device_power = "device_power",
	zigbee_connectivity = "zigbee",
	convenience_area_motion = "convenience",
	security_area_motion = "security",
}

-- The battery states Hue documents (HR §1.6); anything else is not passed on.
motion_model.BATTERY_STATES = { normal = true, low = true, critical = true }

-- An area's health values that mean it senses nothing (HR §2.3, EC A7).
motion_model.NOT_RUNNING = { not_running = true, unrecoverable = true }

-- The value each reading type carries next to its `changed` time: the value
-- group merge() orders by that time.
local VALUE_FIELD = {
	motion = "motion",
	convenience_area_motion = "motion",
	security_area_motion = "motion",
	light_level = "lux",
	temperature = "temperature",
}

-- The fields merge() knows: the values that carry a `changed` time, and the rest.
local VALUES = { "motion", "lux", "temperature" }
local PLAIN = { "enabled", "battery_level", "battery_state", "status", "health" }

local function text(value)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function number(value)
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return nil
end

-- Bridge times ----------------------------------------------------------------

-- Days from 1970-01-01 to a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil): no os.time, whose result depends on the controller's
-- time zone, while the bridge writes UTC.
local function days_from_civil(y, m, d)
	if m <= 2 then
		y = y - 1
	end
	local era = math.floor(y / 400)
	local yoe = y - era * 400
	local mp = (m + 9) % 12
	local doy = math.floor((153 * mp + 2) / 5) + d - 1
	local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
	return era * 146097 + doe - 719468
end

function motion_model.time_of(value)
	if type(value) ~= "string" or #value > 40 then
		return nil
	end
	local y, mo, d, h, mi, s, rest = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
	if not y then
		return nil
	end
	y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
	if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 60 then
		return nil
	end
	local frac = 0
	local digits, tail = rest:match("^%.(%d+)(.*)$")
	if digits then
		frac = tonumber("0." .. digits) or 0
		rest = tail
	end
	local offset = 0
	if rest ~= "" and rest ~= "Z" then
		local sign, oh, om = rest:match("^([%+%-])(%d%d):?(%d%d)$")
		if not sign then
			return nil
		end
		offset = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "+" and 1 or -1)
	end
	return days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s + frac - offset
end

function motion_model.newer(a, b)
	local ta, tb = motion_model.time_of(a), motion_model.time_of(b)
	return ta ~= nil and tb ~= nil and ta > tb
end

-- Light level ------------------------------------------------------------------

-- 10000·log10(lux)+1 back to lux [verified: HR §1.4], whole lux as the
-- device's Light Level variable takes it. A raw value above 60001 (a million
-- lux; sunlight is about a hundred thousand) is junk, not a reading.
function motion_model.lux(v)
	v = number(v)
	if v == nil or v < 0 or v > 60001 then
		return nil
	end
	if v == 0 then
		return 0
	end
	return math.floor(10 ^ ((v - 1) / 10000) + 0.5)
end

-- Readings ----------------------------------------------------------------------

-- The report block of a value (motion_report, light_level_report,
-- temperature_report) first, the deprecated field only when the report is
-- missing (HR §1.3-§1.5: both are still sent in July 2026).
local function value_of(block, report_key, value_key, check)
	if type(block) ~= "table" then
		return nil, nil, nil
	end
	local valid = block[value_key .. "_valid"]
	if type(valid) ~= "boolean" then
		valid = nil
	end
	local report = block[report_key]
	if type(report) == "table" and check(report[value_key]) ~= nil then
		return check(report[value_key]), text(report.changed), valid
	end
	return check(block[value_key]), nil, valid
end

local function boolean(value)
	if type(value) == "boolean" then
		return value
	end
	return nil
end

function motion_model.reading(item)
	if type(item) ~= "table" or not motion_model.READING_TYPES[item.type] then
		return nil
	end
	local t = item.type
	local r = {}
	r.enabled = boolean(item.enabled)
	if VALUE_FIELD[t] == "motion" then
		-- The whole motion block arrives with every motion update (HR §3.1);
		-- on some firmware it is missing altogether (HR §1.3, §2.4).
		local block = item.motion
		if type(block) == "table" then
			r.motion, r.changed = value_of(block, "motion_report", "motion", boolean)
			if type(block.motion_valid) == "boolean" then
				r.valid = block.motion_valid
			end
		end
	elseif t == "light_level" then
		local raw
		raw, r.changed, r.valid = value_of(item.light, "light_level_report", "light_level", number)
		r.lux = motion_model.lux(raw)
		if r.lux == nil then
			r.changed = nil
		end
	elseif t == "temperature" then
		r.temperature, r.changed, r.valid = value_of(item.temperature, "temperature_report", "temperature", number)
	elseif t == "device_power" then
		local state = type(item.power_state) == "table" and item.power_state or {}
		local level = number(state.battery_level)
		if level and level >= 0 and level <= 100 then
			r.battery_level = math.floor(level + 0.5)
		end
		if motion_model.BATTERY_STATES[state.battery_state] then
			r.battery_state = state.battery_state
		end
	elseif t == "zigbee_connectivity" then
		r.status = text(item.status)
	elseif t == "motion_area_configuration" then
		r.health = text(item.health)
	end
	return r
end

-- Fold `fresh` (a reading()) into `cached` (the one held, changed in place)
-- and return the names of the fields whose value changed. `source` says where
-- `fresh` came from:
--   { event = seq }  an event-stream item, the seq'th applied (counted by the caller)
--   { get = seq }    a GET sent when `seq` events had been applied; with
--                    `complete`, the whole resource: a field it lacks is gone
--                    (A12, HR §1.3: firmware that leaves the motion block out)
-- Rules (EC rule 5 and R6): a value with its `changed` time (motion, lux,
-- temperature, with `changed` and `valid`) is replaced only by one that is
-- not older by the bridge's clock; when either side lacks a time, and for
-- every other field, an event applied after the GET was sent beats that
-- GET's value, and keeps a field the GET lacks. An event item carries only
-- what changed: what it lacks stays. `cached.seqs` remembers which event set
-- each field.
function motion_model.merge(cached, fresh, source)
	local changed = {}
	if type(cached) ~= "table" or type(fresh) ~= "table" then
		return changed
	end
	source = source or {}
	cached.seqs = cached.seqs or {}
	local seqs = cached.seqs
	local function newer_event_kept(field)
		return source.get ~= nil and seqs[field] ~= nil and seqs[field] > source.get
	end
	local function take(field, value)
		if cached[field] ~= value then
			cached[field] = value
			changed[#changed + 1] = field
		end
		if source.event ~= nil then
			seqs[field] = source.event
		end
	end

	local value_field
	for _, field in ipairs(VALUES) do
		if fresh[field] ~= nil then
			value_field = field
		end
	end
	if value_field then
		local keep
		local tf, tc = motion_model.time_of(fresh.changed), motion_model.time_of(cached.changed)
		if tf and tc and cached[value_field] ~= nil then
			keep = tf < tc
		else
			keep = newer_event_kept(value_field)
		end
		if not keep then
			take(value_field, fresh[value_field])
			take("changed", fresh.changed)
			if fresh.valid ~= nil or source.complete then
				take("valid", fresh.valid)
			end
		end
	else
		if fresh.valid ~= nil and not newer_event_kept("valid") then
			take("valid", fresh.valid)
		end
		if source.complete then
			for _, field in ipairs(VALUES) do
				if cached[field] ~= nil and not newer_event_kept(field) then
					take(field, nil)
					take("changed", nil)
					if fresh.valid == nil then
						take("valid", nil)
					end
				end
			end
		end
	end
	for _, field in ipairs(PLAIN) do
		if fresh[field] ~= nil then
			if not newer_event_kept(field) then
				take(field, fresh[field])
			end
		elseif source.complete and cached[field] ~= nil and not newer_event_kept(field) then
			take(field, nil)
		end
	end
	return changed
end

-- Records ---------------------------------------------------------------------------

-- The owner rid of a service item: a sensor service's device, an area
-- service's configuration (HR §1.2, §2.4).
local function owner_rid(item)
	return type(item.owner) == "table" and hue_model.resource_id(item.owner.rid) or nil
end

-- Service type → items, the first item per owner and type wins (a stable
-- answer should a device ever list two of one kind).
function motion_model.owned(services_by_type)
	local out = {}
	for rtype, field in pairs(motion_model.SERVICE_FIELDS) do
		for _, item in ipairs(type(services_by_type) == "table" and services_by_type[rtype] or {}) do
			local rid = type(item) == "table" and hue_model.resource_id(item.id) or nil
			local owner = rid and owner_rid(item) or nil
			if owner then
				local o = out[owner] or {}
				out[owner] = o
				if o[field] == nil then
					o[field] = rid
					if field == "motion" then
						o.id_v1 = text(item.id_v1)
					end
				end
			end
		end
	end
	return out
end

-- One sensor record for device `rid` (a hue_model.devices() record) and the
-- services it owns (an owned() entry; empty for a device whose motion
-- service is gone, EC S14). The product name is the device record's own
-- when it keeps one, else its `model` when that is not the bare model id
-- (hue_model.model_string prefers the product name).
function motion_model.sensor(rid, device, owned, groups)
	device = type(device) == "table" and device or {}
	owned = type(owned) == "table" and owned or {}
	local product = text(device.product_name)
	if not product and text(device.model) and device.model ~= device.model_id then
		product = device.model
	end
	local record = {
		rid = rid,
		kind = "sensor",
		name = text(device.name),
		model_id = text(device.model_id),
		product_name = product,
		id_v1 = owned.id_v1 or text(device.id_v1),
		motion = owned.motion,
		light_level = owned.light_level,
		temperature = owned.temperature,
		device_power = owned.device_power,
		zigbee = owned.zigbee or hue_model.resource_id(device.zigbee_rid),
	}
	if groups and groups.room_of_device then
		record.room = groups:room_of_device(rid)
		if record.room then
			record.room_name = groups:label(record.room)
		end
	end
	return record
end

-- Any device that owns a motion service is a motion sensor, whatever its
-- model id (HR §1.1: the model id only labels it). A motion service whose
-- device the cache does not hold yet (its `add` item still to come, HR §3.5)
-- makes no record.
function motion_model.sensors(devices, services_by_type, groups)
	local out = {}
	devices = type(devices) == "table" and devices or {}
	for rid, o in pairs(motion_model.owned(services_by_type)) do
		if o.motion and devices[rid] then
			out[rid] = motion_model.sensor(rid, devices[rid], o, groups)
		end
	end
	return out
end

-- The service rid of `rtype` an area configuration lists, else the one its
-- services' owner fields name (A16: a configuration served in part has no
-- `services`).
local function listed(item, rtype)
	for _, service in ipairs(type(item.services) == "table" and item.services or {}) do
		if type(service) == "table" and service.rtype == rtype then
			local rid = hue_model.resource_id(service.rid)
			if rid then
				return rid
			end
		end
	end
	return nil
end

function motion_model.area(item, owned)
	if type(item) ~= "table" then
		return nil
	end
	local rid = hue_model.resource_id(item.id)
	if not rid then
		return nil
	end
	owned = type(owned) == "table" and owned or {}
	local group
	if type(item.group) == "table" and hue_model.resource_id(item.group.rid) and text(item.group.rtype) then
		group = { rid = item.group.rid, rtype = item.group.rtype }
	end
	local participants, unhealthy
	if type(item.participants) == "table" then
		participants, unhealthy = 0, 0
		for _, p in ipairs(item.participants) do
			if type(p) == "table" then
				participants = participants + 1
				if type(p.status) == "table" and p.status.health == "unhealthy" then
					unhealthy = unhealthy + 1
				end
			end
		end
	end
	local record = {
		rid = rid,
		kind = "area",
		name = text(item.name),
		group = group,
		enabled = boolean(item.enabled),
		health = text(item.health),
		participants = participants,
		unhealthy = unhealthy,
		convenience = listed(item, "convenience_area_motion") or owned.convenience,
		security = listed(item, "security_area_motion") or owned.security,
	}
	record.partial = record.name == nil or record.group == nil or record.health == nil
	return record
end

function motion_model.areas(configs, services_by_type)
	local out = {}
	local owned = motion_model.owned(services_by_type)
	for _, item in ipairs(type(configs) == "table" and configs or {}) do
		if type(item) == "table" and (item.type == nil or item.type == "motion_area_configuration") then
			local rid = hue_model.resource_id(item.id)
			local record = rid and motion_model.area(item, owned[rid]) or nil
			if record then
				out[record.rid] = record
			end
		end
	end
	return out
end

-- An area's motion (EC rule 7 and A9, HR §2.5): the reading of whichever of
-- its two services is enabled, carries a motion value and changed last;
-- convenience before security on a tie or when neither has a time (Home
-- Assistant's order). Nothing while the configuration is paused or not
-- running: the services' values are frozen then (A6, A7). `motion_valid` is
-- not read on areas: a frozen service may keep it true (HR §2.4).
function motion_model.area_motion(record, readings)
	if type(record) ~= "table" or type(readings) ~= "table" then
		return nil
	end
	if record.enabled == false or motion_model.NOT_RUNNING[record.health] then
		return nil
	end
	local best, best_rid, best_time
	for _, key in ipairs({ "convenience", "security" }) do
		local rid = record[key]
		local r = rid and readings[rid] or nil
		if type(r) == "table" and r.enabled ~= false and r.motion ~= nil then
			local t = motion_model.time_of(r.changed)
			if best == nil or (t ~= nil and (best_time == nil or t > best_time)) then
				best, best_rid, best_time = r, rid, t
			end
		end
	end
	return best, best_rid
end

-- Labels ------------------------------------------------------------------------------

function motion_model.model_text(record)
	if type(record) ~= "table" then
		return nil
	end
	if record.kind == "area" then
		return "MotionAware area"
	end
	local product, model_id = text(record.product_name), text(record.model_id)
	if product and model_id then
		return product .. " (" .. model_id .. ")"
	end
	return product or model_id
end

function motion_model.tag(record)
	if type(record) ~= "table" then
		return "#?"
	end
	local rid = tostring(record.rid or "?")
	if record.kind == "area" then
		return "#" .. rid:sub(1, 4)
	end
	local n = type(record.id_v1) == "string" and record.id_v1:match("^/sensors/(%d+)$") or nil
	if n then
		return "#" .. n
	end
	return "#" .. rid:sub(1, 8)
end

return motion_model
