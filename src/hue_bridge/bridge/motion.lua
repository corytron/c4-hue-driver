-- The Hue motion sensors and MotionAware areas a bridge represents as
-- Control4 motion sensors (hue_motion.c4z, one contactsingle_motionsensor
-- device per sensor or area; docs/motion-design.md §4.2): the fourth
-- registry owner on bridge/owner.lua, after the lights, the scenes and the
-- zone lights. It keeps the motion registry (bridge.registry under its own
-- keys), the caches of the bridge's sensor and area resources (the motion
-- GETs of a resync and the event stream), decides what each device is told
-- (HUE_MOTION_CONFIGURE, HUE_MOTION_STATE: the contract's §3) and gives the
-- owner-facing actions, texts and pickers. The lifecycle every registry
-- owner shares (hello, goodbye, bindings, the project reconcile, the busy
-- flags and resyncs, room resolution, creation, names, re-link, forget,
-- Link Devices) is bridge/owner.lua's; this module gives it its words,
-- options and hooks. Parsing is bridge/motion_model.lua's.
--
-- Its sources: docs/edge-cases-motion.md (EC, cited by row id below),
-- docs/motion-hue-research.md (HR) and docs/motion-control4-research.md
-- (C4R). The rules that shape everything here:
--   - Report what is known, invent nothing (EC rule 4). A device hears a
--     motion value only from a valid reading; a deliberate end (deleted,
--     switched off, paused; forgotten) carries `ended`, on which the device
--     closes its contact once; a failure (unreachable, no reading, not
--     running, the bridge away) only says so in `status` (EC §6, D3).
--   - The bridge's clock orders readings (EC rule 5, R6): the newest
--     `changed` wins, a resync GET never replaces a newer event, and no
--     device hears a motion reading older than the last one it was told.
--   - Read freely, never write (D7): no PUT, POST or DELETE anywhere here.
--     One GET at a time, through ctx.http (fetch below).
--   - One device per sensor or area (EC rule 7): a sensor's entry is keyed
--     by its Hue device rid, an area's by its motion_area_configuration rid;
--     the services under either are resolved live, so a replaced service
--     needs no re-link (S14, A9).
--
-- Where the data comes from: a sensor's device record, its room and its MAC
-- are the lights' caches (ctx.lights: `devices`, `groups`, `macs`,
-- `synced`), as the zone lights read `lights.models` (EC §0.3); the
-- coordinator runs this module's resync after the zone lights' and its
-- on_container after the lights', so those caches are current. The sensor
-- services and the areas come from this module's own GETs (RESOURCES) and
-- the stream.
--
-- Public interface (docs/motion-design.md §4.2; what driver.lua calls):
--   motion.new(ctx)                 an instance; ctx below. Raises without ctx.http.
--   m:load()                        read the registry, tombstones and forgotten marks; returns the registry
--   m:configure_all()               startup, before any GET: HUE_MOTION_CONFIGURE to every bound
--                                   entry from the persisted registry, then the early hellos; returns
--                                   the number of configurations sent
--   m:reconcile([no_save], [created])   the project side (bound set, devices present): owner.lua's;
--                                   returns { unbound, relinked, tombstoned } rid lists
--   m:resync(done)                  the GETs of RESOURCES one at a time, then reconcile and tell every
--                                   device its state; done(ok, err, sent) once, also for the callers
--                                   that waited. A failed GET is reported (ok false) and marks nothing
--                                   gone; a 404 on the area types means "no MotionAware here"
--   m:on_container(container)       one event-stream container; returns the messages sent
--   m:on_stream_state(connected)    the event stream went down (false) or came back (true): after
--                                   AWAY_GRACE_S down, every device says its motion is not current
--                                   (EC §6 "bridge away", R1). An addition to §4.2, see below
--   m:hello(params)                 HUE_MOTION_HELLO { rid, device_id, name, kind, model }; also
--                                   hello(rid, params); true when answered
--   m:goodbye(params)               HUE_MOTION_GOODBYE { rid?, device_id }: the entry becomes a
--                                   tombstone; returns it, or nil for a device not held here
--   m:forget_request(params)        HUE_MOTION_FORGET { rid?, device_id, name? }; returns ok, text
--   m:on_binding_changed(binding, class, bound, other_id)   true when an entry changed state
--   m:attention_items([items])      the Attention items appended to `items` (a new list when nil)
--   m:device_ids()                  { [device_id] = true } of every registered device
--   m:registered_rids()             every registered rid, name order
--   m:entry(rid)                    a copy of the registry entry, or nil
--   m:add(rid, room_id, done)       Add Motion Sensor / Add Motion Area: one AddDevice into room_id
--                                   (nil: the Hue room's mapping); done(ok, text) once; returns true
--                                   when the AddDevice was started
--   m:relink(device_id, rid)        Re-link Motion Device; a sensor's device takes a sensor, an
--                                   area's an area (D4); returns ok, text
--   m:forget(device_id)             Forget Motion Device; returns ok, text
--   m:link_devices([skip_ids])      Link Devices for the motion devices; returns the report text
--   m:adopt_hue_names(), m:accept_names()   the names pair; each returns its report text
--   m:picker_sensors(), m:picker_areas()    { text, value } lists of the sensors / areas not added,
--                                   re-link hints first, those deleted from Composer last; one entry
--                                   with value "" when there is nothing to pick
--   m:picker_relink_devices()       the gone, unbound and long-unreachable devices; {} when none
--   m:picker_forget_devices()       every registered device, or one placeholder entry
--   m:summary()                     the Motion Sensors row: "2 sensors and 1 area on the bridge; 1 added"
--   m:list_items()                  its drop-down: one line per sensor and area, commas made "‚"
--
-- ctx fields (all but http optional; driver.lua's module_ctx gives the rest):
--   http(req, cb)            req = { path, method = "GET" }; the driver adds address and key; cb(result)
--                            with result { ok, code, json, err } (bridge/http.lua)
--   send(id, cmd, params)    C4:SendToDevice
--   add_device, bind, persist_get, persist_set, bridge_id, now, log, project   as owner.defaults
--   lights                   the bridge.lights instance: `devices`, `groups`, `macs`, `synced`,
--                            `groups_loaded`, `reg:room_mapping()`
--   groups, devices, macs    read only when no lights instance is given (specs)
--   set_timer(ms, fn)        C4:SetTimer(ms, fn): an object with Cancel() [verified: API 34/_1]
--
-- Additions to the contract's §4.2, each for a rule it keeps: on_stream_state
-- (the §6 "bridge away" row needs to know when the stream is down; until
-- driver.lua calls it, only a resync whose GETs all fail and a failed
-- stuck-motion check say so); the persisted forgotten marks (FORGOTTEN_KEY,
-- the scenes' rule of EC C17 needs them as bridge/scenes.lua has them).
--
-- Callback rules inherited from the other modules: the GETs run from http
-- callbacks; on_container runs inside OnBodyChunk and only sends messages
-- and sets timers; every callback body is pcall-wrapped (owner.protect).
-- Persistence: the registry's mutators change memory only; the module marks
-- itself dirty and saves once per batch, except during device creation.

local motion_model = require("bridge.motion_model")
local hue_model = require("bridge.hue_model")
local registry = require("bridge.registry")
local groups = require("bridge.groups")
local util = require("bridge.util")
local project = require("bridge.project")
local owner = require("bridge.owner")

local motion = {}
motion.__index = motion
setmetatable(motion, { __index = owner })  -- the shared lifecycle (bridge/owner.lua)

motion.REGISTRY_KEY = "hue_motion"
motion.TOMBSTONES_KEY = "hue_motion_tombstones"
-- The devices Forget Motion Device let go: { ["<device id>"] = { rid, name, kind, at } }
-- (the scenes' FORGOTTEN_KEY, EC C17).
motion.FORGOTTEN_KEY = "hue_motion_forgotten"
motion.DEVICE_DRIVER = "hue_motion.c4z"
motion.BINDING = 1
motion.BINDING_CLASS = "HUE_BRIDGE"
motion.MAX_NAMED = 3
motion.EARLY_HELLOS_MAX = 200
motion.PATH = "/clip/v2/resource/"
motion.CONFIG_TYPE = "motion_area_configuration"

-- The resync's GETs, one at a time, in this order (docs/motion-design.md
-- §4.2). The three area types are the Bridge Pro's; once the first answers
-- 404 the other two are not asked (EC B5).
motion.RESOURCES = {
	{ type = "motion" },
	{ type = "light_level" },
	{ type = "temperature" },
	{ type = "device_power" },
	{ type = "zigbee_connectivity" },
	{ type = "motion_area_configuration", area = true },
	{ type = "convenience_area_motion", area = true },
	{ type = "security_area_motion", area = true },
}
local AREA_TYPES = { motion_area_configuration = true, convenience_area_motion = true, security_area_motion = true }

-- Timing (seconds). R1: a stream back within a minute changes nothing
-- visible. D5: Attention for an unreachable sensor, a degraded area or no
-- reading after an hour; EC §8 item 8: Re-link also offers a sensor
-- unreachable that long. D9: the stuck-motion check after 5 minutes of
-- motion without news, looked for every 30 s while some device shows motion
-- (so it runs within 30 s of the 5 minutes).
motion.AWAY_GRACE_S = 60
motion.ATTENTION_AFTER_S = 3600
motion.STUCK_S = 300
motion.CHECK_TICK_S = 30

-- HUE_MOTION_STATE's fields besides rid and reason (§3), in a stable order.
motion.STATE_KEYS = { "online", "enabled", "status", "ended", "motion", "motion_changed", "lux", "temperature",
	"battery_level", "battery_state" }

-- What bridge/owner.lua reads for this module: the log tag and the words its
-- shared texts take here (the contract's words: "motion sensor" / "motion
-- area"; the action names of its §4.4).
motion.TAG = "motion"
motion.WORDS = {
	held = "motion device",                                -- "its registered motion device is <rid>"
	stranger = "a device that is not a motion device",     -- a HUE_MOTION_GOODBYE not held here
	goodbye_tail = "Add Motion Sensor and Add Motion Area list it as deleted",
	add_action = "Add Motion Sensor or Add Motion Area",
	busy_job = "adding a motion device",
	busy_resync = "resyncing motion devices",
	kind = "motion device",
	unbound_kind = "unbound motion device",
	relink_or_forget = "Re-link Motion Device or Forget Motion Device",
	forget_action = "Forget Motion Device",
	name_kind = "motion device name",
	hue_names = "Hue sensor and area names",
	device_noun = "motion device",
	name_difference = "motion device name difference",
	no_forget = "(no motion devices registered)",
	callback_kind = "motion device ",
	created_noun = "motion devices",
	registered = "motion device",                          -- "device 1201 is not a registered motion device"
	relink_target = "a sensor or area",                    -- "pick a device and a sensor or area"
	requester = "motion device",                           -- "the motion device named no device"
	forget_tail = "; it is listed under Add Motion Sensor or Add Motion Area again",
	link_noun = "motion devices",                          -- "No motion devices are bound to this bridge"
	link_many = "Hue motion sensors or areas",
	link_one = "sensor's or area's",
	link_none = "Hue motion sensor or area",
	-- No no_relink placeholder: driver.lua adds its own to an empty Re-link list.
}
-- The words that differ between the two kinds (D2: one driver, two kinds).
motion.KIND_WORDS = {
	sensor = { kind = "motion sensor", fallback = "Hue motion sensor", add_action = "Add Motion Sensor",
		forget_tail = "; the Hue motion sensor is listed under Add Motion Sensor again", pick = "a sensor" },
	area = { kind = "motion area", fallback = "Hue motion area", add_action = "Add Motion Area",
		forget_tail = "; the MotionAware area is listed under Add Motion Area again", pick = "an area" },
}
motion.BUSY_FLAGS = { "adding", "resyncing" }  -- Add Motion Sensor / Area's flag first
motion.MESSAGES = { configure = "HUE_MOTION_CONFIGURE", state = "HUE_MOTION_STATE", hello = "HUE_MOTION_HELLO",
	goodbye = "HUE_MOTION_GOODBYE", forget = "HUE_MOTION_FORGET", forgotten = "HUE_MOTION_FORGOTTEN" }
-- bridge/owner.lua's options (its header lists what each keeps).
motion.OPTIONS = {
	hello_tells_unknown = true,      -- a hello's "bound-device list is unknown" is logged as such
	gone_at_hello = true,            -- a linked entry the bridge is known to lack is marked gone at its hello
	gone_after_add = true,           -- one deleted in Hue while its AddDevice was pending is marked gone
	announced_follows_entry = true,  -- R5: a deleted or re-linked entry's device is no longer "announced"
	settle_without_fetch = true,     -- a failed GET still settles: what the other GETs brought is used
}

-- The registry entry fields this module persists besides the registry's own
-- (registry.OWN_FIELDS); any other persisted field is dropped at load.
motion.ENTRY_FIELDS = { "name", "kind", "model", "model_id", "id_v1", "hue_room_rid", "hue_room", "mac_address",
	"has_light_level", "has_temperature", "has_battery", "name_dismissed" }

-- The fields a refresh clears when the record no longer supplies them
-- (owner:refresh_fields, analysis R9). The MAC and the model id stay: they
-- are the re-link hint's key and a label, and a record never loses them
-- while its device exists.
motion.REFRESH_CLEARS = { "id_v1", "hue_room_rid", "hue_room" }

-- A re-link merges the new record's fields into the old entry (owner:relink),
-- so a field the new sensor or area lacks would keep the old one's value
-- (the old Hue room on a sensor in no room): clear those instead.
function motion:relink_fields(fields)
	for _, name in ipairs(motion.REFRESH_CLEARS) do
		if fields[name] == nil then
			fields[name] = self.reg.CLEAR
		end
	end
end

-- Helpers ------------------------------------------------------------------------

local hello_text = owner.hello_text

local function kind_of(x)
	return (type(x) == "table" and x.kind == "area") and "area" or "sensor"
end

local function words_of(x)
	return motion.KIND_WORDS[kind_of(x)]
end

local function has_name(x)
	return type(x) == "table" and type(x.name) == "string" and x.name ~= ""
end

-- The Hue name of a record or entry; a sensor or area Hue gave no name goes
-- by its tag (A16: "MotionAware area #ac00").
function motion.name_of(x, rid)
	if has_name(x) then
		return x.name
	end
	local tag = motion_model.tag({ kind = kind_of(x), rid = rid or (type(x) == "table" and x.rid) or nil,
		id_v1 = type(x) == "table" and x.id_v1 or nil })
	if kind_of(x) == "area" then
		return "MotionAware area " .. tag
	end
	return "Hue motion sensor " .. tag
end
local name_of = motion.name_of

-- "14:02": a controller time of receipt as the device rows show it (R10).
local function clock_of(ts)
	ts = tonumber(ts)
	if not ts or ts < 0 or ts >= 4102444800 then
		return "?"
	end
	return os.date("%H:%M", ts)
end

-- "07:02:41 UTC": a bridge time as the log shows it (R10; never compared
-- with the controller's clock).
local function bridge_clock(iso)
	local hms = type(iso) == "string" and iso:match("T(%d%d:%d%d:%d%d)") or nil
	return hms and (hms .. " UTC") or "an unknown time"
end

-- A temperature as HUE_MOTION_STATE carries it: up to two decimals, no
-- float noise ("21.37", "14.6", "22").
local function decimal(n)
	local s = string.format("%.2f", n):gsub("0+$", ""):gsub("%.$", "")
	if s == "-0" then
		s = "0"
	end
	return s
end

local function flag(value)
	return (value == true or value == "true") and "true" or "false"
end

local function copy(t)
	local out = {}
	for k, v in pairs(t or {}) do
		out[k] = v
	end
	return out
end

-- Membership in a { [device_id] = true } set from a project call, whose ids
-- may arrive as numbers or strings.
local function in_set(set, id)
	if type(set) ~= "table" or id == nil then
		return false
	end
	return set[id] ~= nil or set[tostring(id)] ~= nil
end

-- Records in name order (case-insensitive), ties by rid.
local function sorted(records)
	local list = {}
	for _, record in pairs(records) do
		list[#list + 1] = record
	end
	table.sort(list, function(a, b)
		local an, bn = name_of(a):lower(), name_of(b):lower()
		if an ~= bn then
			return an < bn
		end
		return tostring(a.rid) < tostring(b.rid)
	end)
	return list
end

-- Construction -------------------------------------------------------------------

function motion.new(ctx)
	ctx = ctx or {}
	assert(type(ctx.http) == "function", "motion.new: ctx.http is required")
	owner.defaults(ctx, motion)  -- send, add_device, bind, persistence, log, now, the project calls
	ctx.set_timer = ctx.set_timer or function(delay_ms, fn)
		return C4:SetTimer(delay_ms, fn)
	end
	local reg = registry.new({
		persist_get = ctx.persist_get, persist_set = ctx.persist_set, now = ctx.now, log = ctx.log,
		keys = { lights = motion.REGISTRY_KEY, tombstones = motion.TOMBSTONES_KEY, rooms = false },
		fields = motion.ENTRY_FIELDS,
	})
	return setmetatable({
		ctx = ctx,
		reg = reg,
		project = project.new(ctx, "motion"),  -- the pcall-wrapped project calls
		registry = reg:entries(),   -- rid → entry, the live table (identity kept across load())
		resources = {},             -- rid → { id, type, owner_rid, id_v1 } of every sensor service, area service
		                            -- and configuration seen (memory only)
		added_seq = {},             -- rid → the event count at its `add` item: a GET sent before it keeps it
		readings = {},              -- rid → merged motion_model.reading() of that resource
		configs = {},               -- configuration rid → its item, merged from the GET and update items
		sensor_records = {},        -- device rid → motion_model sensor record (rebuild)
		area_records = {},          -- configuration rid → motion_model area record (rebuild)
		got = {},                   -- resource type → true once a GET of it has succeeded (missing means gone)
		areas_supported = nil,      -- true: the area types are served; false: they answered 404 (B5); nil: unknown
		seq = 0,                    -- event items applied so far (R6: an event after a GET was sent beats it)
		sent = {},                  -- rid → the state its device was last told { field = string }
		news_at = {},               -- rid → ctx.now() of the last motion news (the stuck check, D9)
		since = {},                 -- rid → { unreachable, no_reading, degraded } ctx.now() stamps (D5)
		stale_before = {},          -- rid → the motion time a deliberate end left (S7, A6: the *next* reading counts)
		away_since = nil,           -- ctx.now() since when the bridge does not answer (EC §6, R1)
		away_pending = nil,         -- when the stream went down, during the grace
		away_timer = nil,
		check_timer = nil,          -- the stuck-motion tick, armed only while some device shows motion
		checking = false,
		queue = {},                 -- GETs waiting (one at a time)
		in_flight = false,
		last_configure = {},        -- rid → signature of the last HUE_MOTION_CONFIGURE sent
		announced = {},             -- device_id → { rid, name, kind, model } from HUE_MOTION_HELLO (strings or nil)
		announced_new = {},         -- rid → true once a new sensor or area was logged (S1, A1)
		conflicts = {},             -- rid → { holder = device_id, claimant = device_id }
		forgotten = {},             -- device_id → { rid, name, kind, at }: devices Forget let go (FORGOTTEN_KEY)
		forgotten_dirty = false,
		early_hellos = {},          -- hellos received before load(), answered after configure_all()
		loaded = false,
		synced = false,             -- a resync has settled
		dirty = false,
		configured_once = false,
		adding = false,
		resyncing = false,
		resync_pending = nil,
		device_info_logged = false,
	}, motion)
end

-- Registry and forgotten marks ------------------------------------------------------------

function motion:load()
	self.reg:load()
	for rid, entry in pairs(self.registry) do
		if entry.kind ~= "sensor" and entry.kind ~= "area" then
			entry.kind = nil
		end
		for _, field in ipairs({ "has_light_level", "has_temperature", "has_battery" }) do
			entry[field] = entry[field] == true or entry[field] == "true"
		end
		self.ctx.log.debug("motion: loaded %s %s (device %s, %s)", words_of(entry).kind,
			util.sanitise(name_of(entry, rid)), tostring(entry.device_id), tostring(rid))
	end
	self:load_forgotten()
	self.loaded = true
	self.dirty = false
	return self.registry
end

-- FORGOTTEN_KEY, keyed by the device id as a string there and by number in
-- memory (bridge/scenes.lua's load_forgotten).
function motion:load_forgotten()
	for id in pairs(self.forgotten) do
		self.forgotten[id] = nil
	end
	self.forgotten_dirty = false
	local raw = self.ctx.persist_get(motion.FORGOTTEN_KEY)
	if type(raw) ~= "table" then
		return
	end
	for key, record in pairs(raw) do
		local id = util.positive(key)
		if id and type(record) == "table" then
			self.forgotten[id] = {
				rid = (type(record.rid) == "string" and record.rid ~= "") and record.rid or nil,
				name = type(record.name) == "string" and record.name or nil,
				kind = (record.kind == "sensor" or record.kind == "area") and record.kind or nil,
				at = tonumber(record.at),
			}
		end
	end
end

-- (owner hook) FORGOTTEN_KEY before the registry, as the scenes write theirs:
-- a crash between the two writes leaves a forgotten device marked and still
-- registered (its hello heals that), never unmarked and unregistered.
function motion:persist_extra()
	if not self.forgotten_dirty then
		return
	end
	self.forgotten_dirty = false
	local out = {}
	for id, record in pairs(self.forgotten) do
		out[tostring(id)] = { rid = record.rid, name = record.name, kind = record.kind, at = record.at }
	end
	self.ctx.persist_set(motion.FORGOTTEN_KEY, out)
end

function motion:clear_forgotten(device_id)
	if device_id == nil or self.forgotten[device_id] == nil then
		return false
	end
	self.forgotten[device_id] = nil
	self.forgotten_dirty = true
	return true
end

function motion:registered_rids()
	return self.reg:rids()
end

function motion:device_ids()
	local out = {}
	for _, entry in pairs(self.registry) do
		out[entry.device_id] = true
	end
	return out
end

-- The lights' caches, read live ---------------------------------------------------------------

-- device rid → hue_model.devices() record: every device on the bridge, the
-- sensors included (lights.lua absorbs /device whole, EC §0.3).
function motion:devices()
	local l = self.ctx.lights
	return (l and l.devices) or self.ctx.devices or {}
end

-- Whether a device missing from that cache means "deleted in Hue": the
-- lights' full GET has succeeded (lights:fetched, their gone rule).
function motion:devices_loaded()
	local l = self.ctx.lights
	if l then
		return l.synced == true
	end
	return self.ctx.devices ~= nil
end

-- The rooms, zones and bridge_home: the lights' cache (replaced at every
-- resync, so read each time), else the one ctx gives.
function motion:groups()
	local l = self.ctx.lights
	if l and l.groups then
		return l.groups
	end
	if self.ctx.groups then
		return self.ctx.groups
	end
	self.empty_groups = self.empty_groups or groups.new()
	return self.empty_groups
end

function motion:groups_loaded()
	local l = self.ctx.lights
	if l then
		return l.groups_loaded == true
	end
	return self.ctx.groups ~= nil
end

-- A sensor's radio address (the lights keep every device's): S6's hint.
function motion:mac_of(device_rid)
	local l = self.ctx.lights
	local macs = (l and l.macs) or self.ctx.macs or {}
	return device_rid ~= nil and macs[device_rid] or nil
end

-- Resources and records ------------------------------------------------------------------------

-- Keep the identity of a reading resource: its type, its owner (a sensor
-- service's device, an area service's configuration; a configuration owns
-- itself) and id_v1. nil for a service item without an owner: an update for
-- a resource never seen cannot be placed (the next resync brings it).
function motion:keep_resource(item, rtype, rid)
	local res = self.resources[rid]
	local owner_rid
	if rtype == motion.CONFIG_TYPE then
		owner_rid = rid
	elseif type(item.owner) == "table" then
		owner_rid = hue_model.resource_id(item.owner.rid)
	end
	if not res then
		if not owner_rid then
			return nil
		end
		res = { id = rid, type = rtype }
		self.resources[rid] = res
	end
	if owner_rid then
		res.owner_rid = owner_rid
		res.owner = { rid = owner_rid }
	end
	if type(item.id_v1) == "string" and item.id_v1 ~= "" then
		res.id_v1 = item.id_v1
	end
	return res
end

function motion:drop_resource(rid)
	self.resources[rid], self.readings[rid], self.configs[rid], self.added_seq[rid] = nil, nil, nil, nil
end

-- A configuration item merged into the one held: an `add` (or a GET) is
-- complete, an update carries the blocks that changed (HR §3.1).
function motion:keep_config(rid, item, complete)
	local held = self.configs[rid]
	if complete or not held then
		held = {}
		self.configs[rid] = held
	end
	for k, v in pairs(item) do
		held[k] = v
	end
	held.id, held.type = rid, motion.CONFIG_TYPE
end

-- The kept resources as motion_model takes them: type → items, rid order.
function motion:services_by_type()
	local out = {}
	for _, res in pairs(self.resources) do
		local list = out[res.type] or {}
		out[res.type] = list
		list[#list + 1] = res
	end
	for _, list in pairs(out) do
		table.sort(list, function(a, b)
			return a.id < b.id
		end)
	end
	return out
end

-- The sensor and area records, from the lights' device cache and the kept
-- resources. A registered sensor whose device stays while its motion
-- service is gone keeps a record without one: that is a failure ("no
-- motion reading"), never "gone", since an entry is gone only when its
-- device is (EC S14). An area's enabled and health are the merged
-- readings', so an event that arrived after a GET was sent keeps its value (R6).
function motion:rebuild()
	local by_type = self:services_by_type()
	local devices, cache = self:devices(), self:groups()
	local sensors = motion_model.sensors(devices, by_type, cache)
	local owned = motion_model.owned(by_type)
	for rid, entry in pairs(self.registry) do
		if entry.kind ~= "area" and not sensors[rid] and devices[rid] then
			sensors[rid] = motion_model.sensor(rid, devices[rid], owned[rid], cache)
		end
	end
	self.sensor_records = sensors
	local configs = {}
	for rid, item in pairs(self.configs) do
		local view = copy(item)
		local r = self.readings[rid]
		if r then
			if r.enabled ~= nil then
				view.enabled = r.enabled
			end
			if r.health ~= nil then
				view.health = r.health
			end
		end
		configs[#configs + 1] = view
	end
	self.area_records = motion_model.areas(configs, by_type)
end

-- (owner hook) The record of a rid: a sensor (device rid) or an area
-- (configuration rid), or nil.
function motion:record_of(rid)
	if rid == nil then
		return nil
	end
	return self.sensor_records[rid] or self.area_records[rid]
end

-- The sensors and areas a device could be added for: a sensor needs its
-- motion service.
function motion.addable(_self, record)
	return record ~= nil and (record.kind == "area" or record.motion ~= nil)
end

-- Labels ---------------------------------------------------------------------------------------

-- The Hue room of a record as the texts show it: a sensor's room label; an
-- area's room, "Upstairs (zone)", or "(whole home)" (A15); nil when not known.
function motion:room_label_of(record)
	if record.kind ~= "area" then
		return record.room_name
	end
	local group = record.group
	if not group then
		return nil
	end
	if group.rtype == "bridge_home" then
		return "(whole home)"
	end
	local cached = self:groups():group(group.rid)
	if cached then
		return hue_model.group_label(cached.name, cached.type)
	end
	return nil
end

-- "Hallway sensor [Hallway] #12" (S1); "Kitchen motion area (MotionAware)
-- [Kitchen] #ac00" (A11): the pickers' and the texts' label of a record. An
-- unnamed one's name already holds its tag ("MotionAware area #ac00", A16).
function motion:label_of(record)
	local parts = { util.sanitise(name_of(record)) }
	if record.kind == "area" and has_name(record) then
		parts[#parts + 1] = "(MotionAware)"
	end
	local room = self:room_label_of(record)
	if room then
		parts[#parts + 1] = "[" .. util.sanitise(room) .. "]"
	end
	if has_name(record) then
		parts[#parts + 1] = motion_model.tag(record)
	end
	return table.concat(parts, " ")
end

-- (owner hooks) An entry by its plain Hue name: "Hallway sensor".
function motion.entry_label(_self, rid, entry)
	return util.sanitise(name_of(entry, rid))
end

function motion.entry_name(_self, rid, entry)
	return util.sanitise(name_of(entry, rid))
end

function motion.adopted_label(_self, rid, entry)
	return util.sanitise(name_of(entry, rid))
end

function motion.add_label(_self, record)
	return util.sanitise(name_of(record))
end

function motion:record_label(record)
	return self:label_of(record)
end

function motion:relinked_label(record)
	return self:label_of(record)
end

-- "motion sensor Hallway sensor" (C5).
function motion:conflict_label(rid)
	local entry, record = self.registry[rid], self:record_of(rid)
	local x = entry or record
	if not x then
		return "motion device " .. tostring(rid)
	end
	return words_of(x).kind .. " " .. util.sanitise(name_of(x, rid))
end

-- "Hallway sensor (motion sensor, device 1201, gone since 10-24)": the
-- device pickers' text of an entry.
function motion.device_text(_self, rid, entry, rest)
	return string.format("%s (%s, device %d%s)", util.sanitise(name_of(entry, rid)), words_of(entry).kind,
		entry.device_id, rest or "")
end

-- Composer name at creation: the sensor's or area's Hue name (raw:
-- owner:new_device_name makes it a display name).
function motion.creation_name(_self, record)
	return name_of(record)
end

-- The expected Composer name of an entry (its rid gives an unnamed area its label).
function motion.expected_name(_self, rid, entry)
	return name_of(entry, rid)
end

function motion:new_device_name(record)
	local name = util.display_name(self:creation_name(record))
	if name == "" then
		return words_of(record).fallback
	end
	return name
end

-- Registry fields ---------------------------------------------------------------------------------

-- (owner hook) The registry fields a record supplies.
function motion:fields_of(record)
	if type(record) ~= "table" then
		return {}
	end
	local fields = {
		name = record.name,
		kind = record.kind,
		model = motion_model.model_text(record),
		model_id = record.model_id,
		id_v1 = record.id_v1,
	}
	if record.kind == "area" then
		fields.hue_room_rid = record.group and record.group.rid or nil
		fields.hue_room = self:room_label_of(record)
		fields.has_light_level, fields.has_temperature, fields.has_battery = false, false, false
	else
		fields.hue_room_rid = record.room
		fields.hue_room = record.room_name
		fields.mac_address = self:mac_of(record.rid)
		fields.has_light_level = record.light_level ~= nil
		fields.has_temperature = record.temperature ~= nil
		fields.has_battery = record.device_power ~= nil
	end
	return fields
end

-- "Kitchen (deleted in Hue)": the room an area remembers once the room or
-- zone left the bridge (A8).
local function deleted_label(label)
	if type(label) ~= "string" or label == "" then
		return nil
	end
	if label:find(" (deleted in Hue)", 1, true) then
		return label
	end
	return label .. " (deleted in Hue)"
end

-- The identity fields of one entry from its record: name (Hue's, the
-- Composer device keeps its own), model, room, id_v1, MAC, services. True
-- when something changed (the caller marks).
function motion:refresh_entry(rid)
	local entry, record = self.registry[rid], self:record_of(rid)
	if not entry or not record then
		return false
	end
	local changed = false
	if record.name ~= nil and entry.name ~= record.name then
		self.ctx.log.info("motion: %s was renamed to %s in Hue (Composer name unchanged)", tostring(entry.name),
			tostring(record.name))
		entry.name = record.name
		changed = true
	end
	local fields = self:fields_of(record)
	fields.name = nil
	if fields.mac_address == nil then
		fields.mac_address = entry.mac_address
	end
	if fields.model_id == nil then
		fields.model_id = entry.model_id
	end
	if record.kind ~= "area" and fields.id_v1 == nil then
		fields.id_v1 = entry.id_v1  -- read from the motion service, which may be gone (S14)
	end
	if record.kind == "area" and fields.hue_room == nil then
		if record.group and record.group.rtype ~= "bridge_home" and self:groups_loaded() then
			fields.hue_room = deleted_label(entry.hue_room)
		elseif record.group == nil then
			-- A16: a configuration served in part keeps what a full one gave.
			fields.hue_room_rid, fields.hue_room = entry.hue_room_rid, entry.hue_room
		else
			fields.hue_room = entry.hue_room
		end
	end
	if self:refresh_fields(rid, fields, motion.REFRESH_CLEARS) then
		changed = true
	end
	return changed
end

function motion:refresh_registry()
	for _, rid in ipairs(self.reg:rids()) do
		if self:refresh_entry(rid) then
			self:mark()
		end
	end
end

-- HUE_MOTION_CONFIGURE ------------------------------------------------------------------------------

-- (owner hook) rid, kind, name, model, hue_room, id_v1, gone, has_light_level,
-- has_temperature, has_battery (§3), every value a string; a value Hue never
-- gave is left out. The names are display names (security review 2026-10-25
-- finding 8); the registry keeps Hue's own.
function motion.configure_params(_self, rid, entry)
	return {
		rid = rid,
		kind = (entry.kind == "sensor" or entry.kind == "area") and entry.kind or nil,
		name = owner.shown(name_of(entry, rid)),
		model = owner.shown(entry.model),
		hue_room = owner.shown(entry.hue_room),
		id_v1 = (type(entry.id_v1) == "string" and entry.id_v1 ~= "") and entry.id_v1 or nil,
		gone = entry.state == "gone" and "true" or "false",
		has_light_level = flag(entry.has_light_level),
		has_temperature = flag(entry.has_temperature),
		has_battery = flag(entry.has_battery),
	}
end

-- What the device is told (EC §6) ----------------------------------------------------------------------

-- A condition's stamp (ctx.now() when first seen), cleared when it ends.
function motion:stamp(rid, condition, on)
	local s = self.since[rid]
	if not s then
		s = {}
		self.since[rid] = s
	end
	if on then
		s[condition] = s[condition] or self.ctx.now()
	else
		s[condition] = nil
	end
	return s[condition]
end

-- S7, A6: after a deliberate end only the *next* reading counts. A motion
-- the sensor or area showed when it was switched off or paused, still held
-- when it comes back, is not reported: it is from before. A "no motion"
-- from before is harmless (the device closed its contact at the end).
function motion:mark_stale(rid, reading)
	if reading and reading.changed and self.stale_before[rid] == nil then
		self.stale_before[rid] = reading.changed
	end
end

function motion:is_stale(rid, reading)
	local before = self.stale_before[rid]
	if not before then
		return false
	end
	if motion_model.newer(reading.changed, before) then
		self.stale_before[rid] = nil
		return false
	end
	return reading.motion == true
end

function motion:away_text()
	return string.format("Bridge not answering since %s; motion not current", clock_of(self.away_since))
end

-- The reading of a sensor's service `field`, or nil.
function motion:service_reading(record, field)
	local rid = record and record[field] or nil
	return rid and self.readings[rid] or nil
end

-- A sensor's state as its device should show it (EC §6, in order: the
-- deliberate ends, the bridge away, the failures, then the reading).
function motion:sensor_state(rid, entry)
	if entry.state == "gone" then
		return { online = "false", ended = "deleted",
			status = string.format("Sensor deleted in Hue since %s; re-link or Forget", util.short_date_of(entry.gone_since)) }
	end
	local record = self.sensor_records[rid]
	local out = {}
	local m, z = self:service_reading(record, "motion"), self:service_reading(record, "zigbee")
	local ll, t, p = self:service_reading(record, "light_level"), self:service_reading(record, "temperature"),
		self:service_reading(record, "device_power")
	-- S13: without a Zigbee reading Online is unknown, never false.
	if z and z.status then
		out.online = z.status == "connected" and "true" or "false"
	end
	if m and m.enabled ~= nil then
		out.enabled = tostring(m.enabled)
	end
	-- The rows keep their last values whatever the motion's state; a reading
	-- switched off in Hue, or flagged invalid, is not passed on (EC §6).
	if ll and ll.enabled ~= false and ll.valid ~= false and ll.lux ~= nil then
		out.lux = tostring(ll.lux)
	end
	if t and t.enabled ~= false and t.valid ~= false and t.temperature ~= nil then
		out.temperature = decimal(t.temperature)
	end
	if p and p.battery_level ~= nil then
		out.battery_level = tostring(p.battery_level)
	end
	if p and p.battery_state ~= nil then
		out.battery_state = p.battery_state
	end
	local unreachable = z ~= nil and z.status ~= nil and z.status ~= "connected"
	local unreachable_since = self:stamp(rid, "unreachable", unreachable)
	if m and m.enabled == false then
		self:mark_stale(rid, m)
		self:stamp(rid, "no_reading", false)
		out.ended, out.status = "off", "Switched off in the Hue app; no motion is reported"
		return out
	end
	if self.away_since then
		out.status = self:away_text()
		return out
	end
	if unreachable then
		self:stamp(rid, "no_reading", false)
		out.status = string.format("Not reachable since %s; motion not current", clock_of(unreachable_since))
		return out
	end
	local usable = m ~= nil and m.motion ~= nil and m.valid ~= false and not self:is_stale(rid, m)
	self:stamp(rid, "no_reading", not usable)
	if not usable then
		out.status = "No motion reading from Hue yet"
		return out
	end
	out.motion, out.motion_changed = tostring(m.motion), m.changed
	return out
end

-- The services' reading of an area ignoring its pause and health: what it
-- showed when it was paused (S7's rule, A6).
function motion:frozen_reading(record)
	local view = copy(record)
	view.enabled, view.health = true, nil
	return (motion_model.area_motion(view, self.readings))
end

-- An area's state as its device should show it (EC §6 and A3-A16).
function motion:area_state(rid, entry)
	if entry.state == "gone" then
		return { online = "false", ended = "deleted",
			status = string.format("Area deleted in Hue since %s; re-link or Forget", util.short_date_of(entry.gone_since)) }
	end
	if self.areas_supported == false then
		-- B5: an area entry on a bridge that serves no areas. Not gone (only a
		-- successful GET that lacks it says that), and no deliberate end.
		return { online = "false", status = "This bridge offers no MotionAware areas; re-link or Forget" }
	end
	local record = self.area_records[rid]
	local out = {}
	if not record then
		return out
	end
	if record.enabled ~= nil then
		out.enabled = tostring(record.enabled)
	end
	if record.enabled == false then
		self:mark_stale(rid, self:frozen_reading(record))
		self:stamp(rid, "no_reading", false)
		self:stamp(rid, "degraded", false)
		out.ended, out.status = "paused", "Paused in the Hue app; no motion is reported"
		return out
	end
	if self.away_since then
		out.status = self:away_text()
		return out
	end
	if motion_model.NOT_RUNNING[record.health] then
		self:stamp(rid, "no_reading", false)
		self:stamp(rid, "degraded", false)
		out.online, out.status = "false", "Area not running in Hue; save it again in the Hue app"
		return out
	end
	out.online = "true"
	local degraded = record.health == "degraded" or record.health == "recovering"
	self:stamp(rid, "degraded", degraded)
	local r = motion_model.area_motion(record, self.readings)
	local usable = r ~= nil and not self:is_stale(rid, r)
	self:stamp(rid, "no_reading", not usable)
	if not usable then
		out.status = "No motion reading from Hue yet"
		return out
	end
	out.motion, out.motion_changed = tostring(r.motion), r.changed
	if record.health == "degraded" then
		-- A5: the candidates' lights are not resolved (no candidate GET), so
		-- the count stands in for "Desk Lamp".
		if record.participants and record.unhealthy and record.unhealthy > 0 then
			out.status = string.format("Area degraded: %d of its %d lights not responding", record.unhealthy,
				record.participants)
		else
			out.status = "Area degraded in Hue; check that its lights are powered"
		end
	elseif record.health == "recovering" then
		out.status = "Area recovering in Hue"
	elseif record.partial then
		out.status = "Hue reports this area only in part; update the bridge"  -- A16
	end
	return out
end

-- The full state of an entry now: { field = string } of STATE_KEYS.
function motion:current(rid)
	local entry = self.registry[rid]
	if not entry then
		return {}
	end
	if entry.kind == "area" then
		return self:area_state(rid, entry)
	end
	return self:sensor_state(rid, entry)
end

-- (owner hook) Whether the bridge knows enough to tell an entry its state.
-- Before that the device shows "Waiting for the bridge" and leaves the
-- proxy's GET_STATE unanswered (EC §6 first row, C12).
function motion:state_known(rid)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	if entry.state == "gone" then
		return true
	end
	if entry.kind == "area" then
		return self.areas_supported == false or self.area_records[rid] ~= nil
	end
	local record = self.sensor_records[rid]
	if not record then
		return false
	end
	return self.got.motion == true or (record.motion ~= nil and self.readings[record.motion] ~= nil)
end

-- The fields of `cur` that a device holding `last` must hear: the values
-- that changed, a motion with its time (a new report counts, an older one
-- never goes: EC rule 5), and always the current status and end, whose
-- absence means "fine" and "not ended" (§3). Returns fields, true; nil,
-- false when nothing changed (a status cleared alone is a change).
local function diff(cur, last)
	local older = cur.motion ~= nil and motion_model.newer(last.motion_changed, cur.motion_changed)
	local fields, any = {}, false
	for _, key in ipairs(motion.STATE_KEYS) do
		if key == "motion" or key == "motion_changed" then
			if not older and cur.motion ~= nil and cur[key] ~= last[key] then
				any = true
			end
		elseif key == "status" or key == "ended" then
			if cur[key] ~= last[key] then
				any = true
			end
		elseif cur[key] ~= nil and cur[key] ~= last[key] then
			any = true
			fields[key] = cur[key]
		end
	end
	if not any then
		return nil, false
	end
	if not older and cur.motion ~= nil and (cur.motion ~= last.motion or cur.motion_changed ~= last.motion_changed) then
		fields.motion, fields.motion_changed = cur.motion, cur.motion_changed
	end
	fields.status, fields.ended = cur.status, cur.ended
	return fields, true
end

-- (owner hook) HUE_MOTION_STATE: the full state when `fields` is nil (a
-- resync, a hello, an add, a re-link), else rid + reason + `fields`.
-- Records what the device now holds: a field left out keeps its value
-- there, except status and ended (§3). A motion older than the one the
-- device holds is never sent (EC rule 5).
function motion:send_state(rid, reason, fields)
	local entry = self.registry[rid]
	if not entry then
		return false
	end
	local last = self.sent[rid]
	local params
	if fields then
		params = copy(fields)
	else
		params = self:current(rid)
		if last and params.motion ~= nil and motion_model.newer(last.motion_changed, params.motion_changed) then
			params.motion, params.motion_changed = last.motion, last.motion_changed
		end
	end
	-- What a message leaves out the device keeps (EC §6: Online, Enabled and
	-- the readings stay when not known), except status and ended.
	local held = last and copy(last) or {}
	for _, key in ipairs(motion.STATE_KEYS) do
		if params[key] ~= nil or key == "status" or key == "ended" then
			held[key] = params[key]
		end
	end
	self.sent[rid] = held
	params.rid, params.reason = rid, reason or "event"
	self:tell(entry.device_id, motion.MESSAGES.state, params)
	if held.motion == "true" then
		self.news_at[rid] = self.news_at[rid] or self.ctx.now()
		self:arm_check()
	end
	return true
end

-- (owner hook) An entry whose sensor or area left the bridge: CONFIGURE (gone
-- "true") and the deliberate end (S5, A3: CLOSED once on the device).
function motion:announce_gone(rid, reason)
	if not self.registry[rid] then
		return false
	end
	self:send_configure(rid)
	return self:send_state(rid, reason or "event")
end

-- An entry after something it shows may have changed: back on the bridge
-- (told in full), gone (told so), else a changed CONFIGURE and the fields
-- of its state that changed. Returns the number of messages sent.
function motion:refresh(rid, reason)
	local entry = self.registry[rid]
	if not entry or entry.state == "unbound" then
		return 0
	end
	local record = self:record_of(rid)
	if record and entry.state == "gone" then
		if self.reg:set_state(rid, "linked") then
			self:mark()
			self.ctx.log.always("motion: %s (device %d) is back on the bridge", self:entry_label(rid, entry), entry.device_id)
		end
		if self:refresh_entry(rid) then
			self:mark()
		end
		return self:push(rid, reason, true) and 1 or 0
	end
	if not record and entry.state == "linked" and self:known_missing(rid) then
		return self:mark_missing(rid, reason) and 1 or 0
	end
	local sent = 0
	if self:refresh_entry(rid) then
		self:mark()
	end
	if self:configure_changed(rid) and self:send_configure(rid) then
		sent = sent + 1
	end
	if not self:state_known(rid) then
		return sent
	end
	local cur = self:current(rid)
	local last = self.sent[rid]
	if last then
		local fields, any = diff(cur, last)
		if any and self:send_state(rid, reason, fields) then
			sent = sent + 1
		end
	elseif next(cur) ~= nil and self:send_state(rid, reason) then
		sent = sent + 1
	end
	return sent
end

function motion:refresh_all(reason)
	local sent = 0
	for _, rid in ipairs(self.reg:rids()) do
		sent = sent + self:refresh(rid, reason)
	end
	self:flush()
	return sent
end

-- (owner hook) What a deleted, forgotten or re-linked entry leaves behind
-- besides its configuration signature.
function motion:forget_sent(rid)
	self.sent[rid], self.news_at[rid], self.since[rid], self.stale_before[rid] = nil, nil, nil, nil
end

-- The bridge away (EC §6, R1) ---------------------------------------------------------------

-- Every bound device says its motion is not current; contacts, Online and
-- Enabled stay as they are. `quiet`: the caller's fan-out tells them.
function motion:set_away(since, quiet)
	if self.away_since then
		return
	end
	self.away_since = since or self.ctx.now()
	self.ctx.log.warn("motion: the bridge has not answered since %s; the motion devices say their motion is not current",
		clock_of(self.away_since))
	if not quiet then
		self:refresh_all("event")
	end
end

-- The bridge answers again. `quiet`: the resync that follows tells every
-- device its state (on_stream_state(true) runs just before it).
function motion:clear_away(quiet)
	if self.away_timer then
		pcall(self.away_timer.Cancel, self.away_timer)
		self.away_timer = nil
	end
	self.away_pending = nil
	if not self.away_since then
		return
	end
	self.away_since = nil
	self.ctx.log.info("motion: the bridge answers again")
	if not quiet then
		self:refresh_all("event")
	end
end

function motion:on_stream_state(connected)
	if connected == true or connected == "true" then
		return self:clear_away(true)
	end
	if self.away_since or self.away_timer then
		return
	end
	self.away_pending = self.ctx.now()
	self.away_timer = self.ctx.set_timer(motion.AWAY_GRACE_S * 1000, function()
		self.away_timer = nil
		self:protect("bridge away", self.set_away, self, self.away_pending)
	end)
end

-- GETs, one at a time -------------------------------------------------------------------------

-- Queue a GET of `path`; cb(result) runs when it is answered (pcall-wrapped),
-- and the next queued GET starts then. A synchronous answer (the driver
-- refuses at once while the bridge's identity is unverified) works the same.
function motion:fetch(path, cb)
	self.queue[#self.queue + 1] = { path = path, cb = cb }
	self:pump()
end

function motion:pump()
	if self.in_flight then
		return
	end
	local job = table.remove(self.queue, 1)
	if not job then
		return
	end
	self.in_flight = true
	local answered = false
	local function answer(r)
		if answered then
			return
		end
		answered = true
		self.in_flight = false
		self:protect("GET " .. job.path, job.cb, type(r) == "table" and r or { ok = false, err = "no result" })
		self:pump()
	end
	local ok, err = pcall(self.ctx.http, { path = job.path, method = "GET" }, answer)
	if not ok then
		answer({ ok = false, err = tostring(err) })
	end
end

-- Resync ---------------------------------------------------------------------------------------

-- (owner hook) The GETs of RESOURCES, one at a time. cb(res) with res[type]
-- = the data array of each, res.since[type] = the event count when it was
-- sent (R6), res.unsupported when the area types answered 404 (EC B5). When
-- a GET failed, what the others brought is absorbed here and cb(nil, err)
-- reports the failure; the owner's resync settles all the same
-- (OPTIONS.settle_without_fetch), so a failed GET never marks anything gone.
-- When every GET failed the bridge is not answering (EC §6).
function motion:fetch_all(cb)
	local res, errors, answered, i = { since = {} }, {}, false, 0
	local step

	local function finish()
		if #errors == 0 then
			return cb(res)
		end
		local err = table.concat(errors, "; ")
		self.ctx.log.warn("motion: %s; nothing is marked gone", err)
		if answered then
			self:protect("absorb", self.absorb, self, res)
		else
			self:set_away(self.ctx.now(), true)  -- the settle that follows tells every device
		end
		cb(nil, err)
	end

	step = function()
		i = i + 1
		local spec = motion.RESOURCES[i]
		if not spec then
			return finish()
		end
		if spec.area and res.unsupported then
			return step()
		end
		local path = motion.PATH .. spec.type
		res.since[spec.type] = self.seq
		self:fetch(path, function(r)
			local data = r.ok and type(r.json) == "table" and r.json.data or nil
			if type(data) == "table" then
				res[spec.type] = data
				answered = true
			elseif spec.type == motion.CONFIG_TYPE and r.code == 404 then
				-- Not "every area was deleted" (EC B5): this bridge serves none.
				res.unsupported = true
				answered = true
			else
				if r.code ~= nil then
					answered = true
				end
				errors[#errors + 1] = string.format("GET %s: %s", path, tostring(r.err or "malformed response"))
			end
			step()
		end)
	end
	step()
end

-- The items of one GET: kept and merged (a reading older than the one held,
-- or one an event changed after the GET was sent, stays: EC rule 5, R6);
-- resources of that type the GET lacks are dropped, unless their `add` item
-- arrived after it was sent.
function motion:absorb_type(rtype, items, since)
	local seen = {}
	for _, item in ipairs(items) do
		local rid = type(item) == "table" and hue_model.resource_id(item.id) or nil
		if rid and (item.type == nil or item.type == rtype) then
			seen[rid] = true
			if self:keep_resource(item, rtype, rid) then
				if rtype == motion.CONFIG_TYPE then
					self:keep_config(rid, item, true)
				end
				local reading = motion_model.reading(item.type and item or setmetatable({ type = rtype }, { __index = item }))
				local held = self.readings[rid] or {}
				self.readings[rid] = held
				motion_model.merge(held, reading, { get = since, complete = true })
			end
		end
	end
	for rid, res in pairs(self.resources) do
		if res.type == rtype and not seen[rid] and (self.added_seq[rid] or -1) <= since then
			self:drop_resource(rid)
		end
	end
	self.got[rtype] = true
end

-- (owner hook) A fetch result into the caches, then the records.
function motion:absorb(res)
	for _, spec in ipairs(motion.RESOURCES) do
		local items = res[spec.type]
		if type(items) == "table" then
			self:absorb_type(spec.type, items, res.since and res.since[spec.type] or 0)
		end
	end
	if res.unsupported then
		if self.areas_supported ~= false then
			self.ctx.log.info("motion: this bridge offers no MotionAware areas (GET %s%s answered 404)", motion.PATH,
				motion.CONFIG_TYPE)
		end
		self.areas_supported = false
		for rtype in pairs(AREA_TYPES) do
			self.got[rtype] = nil
		end
		for rid, r in pairs(self.resources) do
			if AREA_TYPES[r.type] then
				self:drop_resource(rid)
			end
		end
	elseif type(res[motion.CONFIG_TYPE]) == "table" then
		self.areas_supported = true
	end
	self:rebuild()
end

-- Gone and back for every entry against the records (S5, A3: only a
-- successful GET, or a delete item, says gone; A16, B5: never a partial
-- shape or an unsupported type). The fan-out after it tells the devices.
function motion:reconcile_records()
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		if entry.state ~= "unbound" then
			if self:record_of(rid) then
				if entry.state == "gone" and self.reg:set_state(rid, "linked") then
					self:mark()
					self.ctx.log.always("motion: %s (device %d) is back on the bridge", self:entry_label(rid, entry),
						entry.device_id)
				end
			elseif entry.state == "linked" and self:known_missing(rid) and self.reg:set_state(rid, "gone") then
				self:mark()
				self.ctx.log.warn("motion: %s (device %d) is no longer on the bridge; marked gone (%s)",
					self:entry_label(rid, entry), entry.device_id, motion.WORDS.relink_or_forget)
			end
		end
	end
end

-- The motion reading an entry's state would use: its sensor's motion, or
-- its area's (nil when there is none).
function motion:motion_reading(rid)
	local entry = self.registry[rid]
	if not entry then
		return nil
	end
	if entry.kind == "area" then
		local record = self.area_records[rid]
		return record and motion_model.area_motion(record, self.readings) or nil
	end
	return self:service_reading(self.sensor_records[rid], "motion")
end

-- R1, R2: what changed while the stream was down is logged with the
-- bridge's time; an episode that began and ended unseen is logged only,
-- never replayed (D8).
function motion:log_missed()
	for _, rid in ipairs(self.reg:rids("linked")) do
		local last, r = self.sent[rid], self:motion_reading(rid)
		if last and last.motion ~= nil and r and r.motion ~= nil
			and motion_model.newer(r.changed, last.motion_changed) then
			local label = self:entry_label(rid, self.registry[rid])
			if tostring(r.motion) ~= last.motion then
				self.ctx.log.info("motion: %s: %s since %s (missed while the stream was down)", label,
					r.motion and "motion" or "no motion", bridge_clock(r.changed))
			else
				self.ctx.log.info("motion: %s: %s at %s (bridge time) was missed while the stream was down", label,
					r.motion and "a pause in the motion" or "a motion", bridge_clock(r.changed))
			end
		end
	end
end

-- (owner hook) After a resync's GETs (or their failure): the project side,
-- the records, gone and back, the registry's identity fields, the logs of
-- what was missed and of what is new, then every bound device in full.
function motion:settle(reason, with_configure)
	self.synced = true
	self:reconcile(true)
	self:rebuild()
	self:reconcile_records()
	self:refresh_registry()
	self:log_missed()
	self:announce_new_all()
	local sent = self:fanout(reason, with_configure)
	self:flush()
	return sent
end

-- CONFIGURE (first time or changed) and the full STATE to every bound entry,
-- gone ones included: a restarted device learns its end that way (R4 does
-- the rest on the device).
function motion:fanout(reason, with_configure)
	local sent = 0
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		if entry.state ~= "unbound" and self:push(rid, reason, with_configure) then
			sent = sent + 1
		end
	end
	self.configured_once = true
	return sent
end

-- Events -----------------------------------------------------------------------------------------

-- One reading item: its resource kept, its reading merged (an event, the
-- seq'th: R6), a configuration's blocks merged. Returns the rid of the
-- registry key it concerns (the sensor's device, the area's configuration)
-- and whether the records must be rebuilt.
function motion:on_resource_item(item, kind)
	local rid = hue_model.resource_id(item.id)
	if not rid then
		return nil, false
	end
	local rtype = item.type
	local res = self.resources[rid]
	if kind == "delete" then
		if not res then
			return nil, false
		end
		local owner_rid = res.owner_rid
		self:drop_resource(rid)
		return owner_rid, true
	end
	if kind ~= "add" and kind ~= "update" then
		return nil, false
	end
	if rtype == motion.CONFIG_TYPE and not res and kind == "update" then
		return nil, false  -- an update for an area the resync has not brought yet: the next resync does
	end
	local structure = res == nil or kind == "add"
	res = self:keep_resource(item, rtype, rid)
	if not res then
		return nil, false
	end
	self.seq = self.seq + 1
	if kind == "add" then
		self.added_seq[rid] = self.seq
	end
	if rtype == motion.CONFIG_TYPE then
		self:keep_config(rid, item, kind == "add")
		structure = true
	end
	local reading = motion_model.reading(item)
	local held = self.readings[rid] or {}
	self.readings[rid] = held
	motion_model.merge(held, reading, { event = self.seq })
	if reading and reading.motion ~= nil then
		self.news_at[res.owner_rid] = self.ctx.now()
	end
	return res.owner_rid, structure
end

-- One event-stream container, run after the lights' on_container (their
-- device, MAC and group caches are current). Sensor and area items update
-- the caches; device items (a sensor added, renamed or deleted) and group
-- items (rooms renamed or moved) rebuild the records. Only the entries an
-- item concerns are checked, every entry when the groups changed. A delete
-- item of a registered device or configuration marks it gone at once (S5,
-- A3, as Q 11 for lights). Any container also proves the bridge answers
-- (R1). Runs inside OnBodyChunk: no transfers are started here.
function motion:on_container(container)
	if type(container) ~= "table" or type(container.data) ~= "table" then
		return 0
	end
	-- The status cleared with whatever this container changes, one message
	-- per device.
	local was_away = self.away_since ~= nil
	if was_away or self.away_timer then
		self:clear_away(true)
	end
	local kind = container.type
	local touched, deleted, rebuild, all = {}, {}, false, was_away
	for _, item in ipairs(container.data) do
		if type(item) == "table" and item.id ~= nil then
			local t = item.type
			if motion_model.READING_TYPES[t] then
				local key, structure = self:on_resource_item(item, kind)
				if key then
					touched[key] = true
				end
				rebuild = rebuild or structure
				if kind == "delete" and t == motion.CONFIG_TYPE then
					deleted[item.id] = true
				end
			elseif t == "device" then
				if kind == "delete" then
					deleted[item.id] = true
				end
				if kind ~= "update" or self.registry[item.id] or self.sensor_records[item.id] then
					touched[item.id] = true
					rebuild = true
				end
			elseif t == "room" or t == "zone" or t == "bridge_home" then
				rebuild, all = true, true
			end
		end
	end
	if not all and next(touched) == nil then
		return 0
	end
	if rebuild then
		self:rebuild()
	end
	local sent = 0
	for rid in pairs(deleted) do
		local entry = self.registry[rid]
		if entry and entry.state == "linked" and self:mark_missing(rid, "event") then
			sent = sent + 1
		end
	end
	local rids = {}
	if all then
		rids = self.reg:rids()
	else
		for rid in pairs(touched) do
			if self.registry[rid] then
				rids[#rids + 1] = rid
			end
		end
		table.sort(rids)
	end
	for _, rid in ipairs(rids) do
		if not deleted[rid] then
			sent = sent + self:refresh(rid, "event")
		end
	end
	if kind == "add" then
		self:announce_new_all()
	end
	self:flush()
	return sent
end

-- The stuck-motion check (D9, R3) --------------------------------------------------------------

-- Whether some bound device shows motion (the bridge's last word to it).
function motion:any_motion()
	for rid, held in pairs(self.sent) do
		local entry = self.registry[rid]
		if entry and entry.state == "linked" and held.motion == "true" then
			return true
		end
	end
	return false
end

-- The tick runs only while some device shows motion: armed when one starts
-- to, dropped at the first tick that finds none.
function motion:arm_check()
	if self.check_timer then
		return
	end
	local ok, timer = pcall(self.ctx.set_timer, motion.CHECK_TICK_S * 1000, function()
		self.check_timer = nil
		self:protect("stuck-motion check", self.check_tick, self)
	end)
	if ok then
		self.check_timer = timer
	else
		self.ctx.log.warn("motion: the stuck-motion check could not be armed: %s", tostring(timer))
	end
end

function motion:check_tick()
	if not self:any_motion() then
		return
	end
	if not (self.resyncing or self.checking) then
		local now, due = self.ctx.now(), {}
		for _, rid in ipairs(self.reg:rids("linked")) do
			local held = self.sent[rid]
			if held and held.motion == "true" then
				local at = self.news_at[rid]
				if not at then
					self.news_at[rid] = now
				elseif now - at >= motion.STUCK_S then
					due[#due + 1] = rid
				end
			end
		end
		if #due > 0 then
			self:run_checks(due)
		end
	end
	self:arm_check()
end

-- The GETs that verify one entry's motion: its sensor's motion resource, or
-- its area's configuration and two services.
function motion:check_paths(rid)
	local entry, out = self.registry[rid], {}
	if entry.kind == "area" then
		local record = self.area_records[rid]
		if record and self.areas_supported ~= false then
			out[#out + 1] = { type = motion.CONFIG_TYPE, rid = rid }
			for _, field in ipairs({ "convenience", "security" }) do
				if record[field] then
					out[#out + 1] = { type = field == "convenience" and "convenience_area_motion" or "security_area_motion",
						rid = record[field] }
				end
			end
		end
	else
		local record = self.sensor_records[rid]
		if record and record.motion then
			out[#out + 1] = { type = "motion", rid = record.motion }
		end
	end
	return out
end

-- One bounded GET per resource of the entries due, one at a time; the
-- answers are applied by rule 5, the entries told what changed (reason
-- "check"), and their next check is 5 minutes away. A GET with no answer at
-- all says the bridge is away; any answer that it is not.
function motion:run_checks(rids)
	local jobs = {}
	for _, rid in ipairs(rids) do
		for _, job in ipairs(self:check_paths(rid)) do
			job.key = rid
			jobs[#jobs + 1] = job
		end
	end
	if #jobs == 0 then
		local now = self.ctx.now()
		for _, rid in ipairs(rids) do
			self.news_at[rid] = now
		end
		return
	end
	self.checking = true
	local i, results = 0, {}
	local function step()
		i = i + 1
		local job = jobs[i]
		if not job then
			return self:protect("checks done", self.checks_done, self, rids, results)
		end
		local since = self.seq
		self.ctx.log.debug("motion: no news about %s for %d s while it shows motion; asking the bridge",
			self:entry_label(job.key, self.registry[job.key] or {}), motion.STUCK_S)
		self:fetch(motion.PATH .. job.type .. "/" .. job.rid, function(r)
			results[#results + 1] = { job = job, r = r, since = since }
			step()
		end)
	end
	step()
end

function motion:checks_done(rids, results)
	self.checking = false
	local answered, unanswered = false, false
	for _, res in ipairs(results) do
		local r = res.r
		local data = r.ok and type(r.json) == "table" and r.json.data or nil
		if type(data) == "table" then
			answered = true
			for _, item in ipairs(data) do
				local rid = type(item) == "table" and hue_model.resource_id(item.id) or nil
				if rid == res.job.rid and self:keep_resource(item, res.job.type, rid) then
					if res.job.type == motion.CONFIG_TYPE then
						self:keep_config(rid, item, true)
					end
					local held = self.readings[rid] or {}
					self.readings[rid] = held
					local view = item.type and item or setmetatable({ type = res.job.type }, { __index = item })
					motion_model.merge(held, motion_model.reading(view), { get = res.since, complete = true })
				end
			end
		elseif r.code ~= nil then
			answered = true
			self.ctx.log.debug("motion: check GET %s/%s: %s", res.job.type, res.job.rid, tostring(r.err))
		else
			unanswered = true
		end
	end
	if answered then
		self:clear_away()
	elseif unanswered then
		self:set_away(self.ctx.now())
	end
	self:rebuild()
	local now = self.ctx.now()
	for _, rid in ipairs(rids) do
		self.news_at[rid] = now
		self:refresh(rid, "check")
	end
	self:flush()
end

-- Hello, adoption, goodbye, forget (bridge/owner.lua's, with these hooks) --------------------------

-- HUE_MOTION_HELLO { rid ("" when unknown), device_id, name, kind, model };
-- also hello(rid, params), the form owner.configure_all replays.
function motion:hello(a, b)
	local params
	if type(a) == "table" then
		params = a
	else
		params = b or {}
		if params.rid == nil then
			params.rid = a
		end
	end
	return owner.hello(self, params.rid, params)
end

function motion.announcement(_self, rid, params)
	return { rid = rid, name = hello_text(params.name), kind = hello_text(params.kind), model = hello_text(params.model) }
end

-- D4 at the adoption: a device announcing the other kind than the record of
-- its rid is not adopted (rids are unique across types, so it is not
-- this sensor's or this area's device).
function motion:adoptable_hello(params)
	local kind = hello_text(params.kind)
	if kind ~= nil and kind ~= "sensor" and kind ~= "area" then
		return false
	end
	local record = self:record_of(params.rid)
	return kind == nil or record == nil or record.kind == kind
end

function motion.hello_fields(_self, fields, hello)
	fields.name = fields.name or hello_text(hello.name)
	if fields.kind == nil and (hello.kind == "sensor" or hello.kind == "area") then
		fields.kind = hello.kind
	end
	fields.model = fields.model or hello_text(hello.model)
end

-- The "gone" rule: a sensor is gone when the lights' fetched device cache
-- lacks its device (S5, S14); an area when a successful configuration GET
-- lacks it (A3; never on a bridge without the type, B5).
function motion:fetched(rid)
	local entry = self.registry[rid]
	local kind = entry and entry.kind or (self.area_records[rid] and "area") or "sensor"
	if kind == "area" then
		return self.got[motion.CONFIG_TYPE] == true
	end
	return self:devices_loaded()
end

-- (owner) Known to be missing, read from the caches themselves rather than
-- the records: those are rebuilt by this module's resync, which runs after
-- the lights' (at a start, a hello in between would otherwise read a sensor
-- as deleted and end its motion, which only a deletion may do: EC §6).
function motion:known_missing(rid)
	if not self:fetched(rid) then
		return false
	end
	local entry = self.registry[rid]
	if (entry and entry.kind == "area") or (not entry and self.configs[rid] ~= nil) then
		return self.configs[rid] == nil
	end
	return self:devices()[rid] == nil
end

-- A registered device is never a forgotten one.
function motion:registered(device_id)
	self:clear_forgotten(device_id)
end

-- EC C17 (the scenes' rule, #47 F8): a device Forget let go is told
-- HUE_MOTION_FORGOTTEN again and never adopted; Link Devices brings it back.
function motion:refuse_hello(device_id, rid)
	local remembered = self.forgotten[device_id]
	if not remembered then
		return false
	end
	if self.reg:by_device(device_id) then
		self:clear_forgotten(device_id)  -- registered after all: the mark is stale
		self:flush()
		return false
	end
	rid = rid or remembered.rid
	self.ctx.send(device_id, motion.MESSAGES.forgotten, { rid = rid, name = owner.shown(remembered.name) })
	self.ctx.log.info("motion: device %d said hello for %s, but Forget let it go on %s; told so, not adopted (Link "
		.. "Devices links it again)", device_id, tostring(rid), util.date_of(remembered.at))
	return true
end

function motion:goodbye_unregistered(device_id)
	if self:clear_forgotten(device_id) then
		self:flush()
	end
end

-- Conflicts and forgotten marks whose devices left the project go after the
-- project-side reconcile (the scenes' rule: a deleted claimant sends no goodbye).
function motion:reconcile_done(present)
	if not present then
		return
	end
	for rid, c in pairs(self.conflicts) do
		if not (in_set(present, c.holder) and in_set(present, c.claimant)) then
			self.conflicts[rid] = nil
		end
	end
	for id in pairs(self.forgotten) do
		if not in_set(present, id) then
			self:clear_forgotten(id)
		end
	end
end

-- Forget: remembered (C17); the device hears the deliberate end first
-- (CLOSED once, EC §6 "Forgotten"), then HUE_MOTION_FORGOTTEN (owner.forget).
function motion:forgot(rid, entry, device_id, told)
	self.forgotten[device_id] = { rid = rid, name = told ~= nil and tostring(told) or nil, kind = entry.kind,
		at = self.ctx.now() }
	self.forgotten_dirty = true
	local name = owner.shown(name_of(entry, rid))
	self.ctx.send(device_id, motion.MESSAGES.state, { rid = rid, reason = "event", online = "false", ended = "forgotten",
		status = string.format("Forgotten by the bridge (was %s %s)", words_of(entry).fallback, name or "?") })
end

-- Forget's text names the kind's own add action (C17).
function motion:forget(device_id)
	local id = util.positive(device_id)
	local _, entry = self.reg:by_device(id)
	if not entry then
		return owner.forget(self, device_id)
	end
	self.WORDS = setmetatable({ forget_tail = words_of(entry).forget_tail }, { __index = motion.WORDS })
	local ok, done, text = pcall(owner.forget, self, device_id)
	self.WORDS = nil
	if not ok then
		error(done, 0)
	end
	return done, text
end

-- Re-link (D4: a sensor's device takes a sensor, an area's an area; EC S4,
-- S6, A13). The device keeps its proxy, programming and name.
function motion:relink(device_id, new_rid)
	local busy = self:busy_text()
	if busy then
		return false, busy
	end
	local id = util.positive(device_id)
	local _, entry = self.reg:by_device(id)
	local record = self:record_of(new_rid)
	if entry and record and entry.kind and record.kind ~= entry.kind then
		return false, string.format("Not re-linked: device %d is a %s; pick %s", id, words_of(entry).kind,
			words_of(entry).pick)
	end
	if record and not self:addable(record) then
		return false, string.format("Not re-linked: %s has no motion service on the bridge", self:label_of(record))
	end
	return owner.relink(self, device_id, new_rid)
end

function motion.relink_refusal(_self, _device_id, new_rid)
	return string.format("Not re-linked: motion sensor or area %s is not on the bridge (connect the event stream and "
		.. "try again)", tostring(new_rid))
end

-- Link Devices -------------------------------------------------------------------------------

-- The bound hue_motion devices the registry lacks (the project's, or those
-- that said hello or were forgotten when the project lookup is unavailable),
-- minus `skip_ids` (a set or a list). Returns the ids and how many there are.
function motion:link_candidates(bound, skip_ids)
	local skip = {}
	for k, v in pairs(skip_ids or {}) do
		if type(k) == "number" and v ~= true and tonumber(v) then
			skip[tonumber(v)] = true
		elseif v then
			skip[tonumber(k) or k] = true
		end
	end
	local present = self.project:devices_of(motion.DEVICE_DRIVER)
	local ids, total = {}, 0
	for id in pairs(bound) do
		local n = util.positive(id)
		if n and not skip[n] then
			local mine = (present and present[n] ~= nil)
				or (not present and (self.announced[n] ~= nil or self.forgotten[n] ~= nil))
			if mine then
				total = total + 1
				if not self.reg:by_device(n) then
					ids[#ids + 1] = n
				end
			end
		end
	end
	return ids, total
end

-- A forgotten device is a candidate like any other, by the rid it had.
function motion:link_hello(id)
	return self.announced[id] or self.forgotten[id] or {}
end

function motion:linked_label(rid, entry)
	local record = self:record_of(rid)
	return record and self:label_of(record) or self:entry_label(rid, entry),
		record and "" or (entry.state == "gone" and " (not on the bridge: marked gone)" or "")
end

-- The sensors and areas not added whose Hue name is wanted (S11, A11: two
-- with one name are both returned, and Link Devices then refuses).
function motion:unimported_named(wanted)
	local out = {}
	for _, records in ipairs({ self.sensor_records, self.area_records }) do
		for _, record in ipairs(sorted(records)) do
			if not self.registry[record.rid] and self:addable(record) and wanted[util.name_key(name_of(record))] then
				out[#out + 1] = record
			end
		end
	end
	return out
end

-- Add Motion Sensor / Add Motion Area --------------------------------------------------------------

-- (owner hook) The room an add goes to: the mapping of a sensor's Hue room,
-- of an area's room or zone. A whole-home area and a sensor in no room
-- need a room picked (A15, S1).
function motion:room_group_of(record)
	if record.kind == "area" then
		local group = record.group
		if not group then
			return nil, "Hue names no room or zone for it"
		end
		if group.rtype == "bridge_home" then
			return nil, "the whole home has no mapped room"
		end
		return group.rid, self:room_label_of(record) or group.rid
	end
	if not record.room then
		return nil, "no Hue room"
	end
	return record.room, record.room_name or record.room
end

-- One AddDevice of hue_motion.c4z for the sensor or area `rid` into
-- `room_id` (nil, "" or "mapped": its Hue room's mapping). Refuses a rid
-- already added (C15), one not on the bridge and a missing room (C1).
-- done(ok, text) once; true when the AddDevice was started.
function motion:add(rid, room_id, done)
	done = done or function() end
	if room_id == "mapped" or room_id == "" then
		room_id = nil
	end
	local busy = self:busy_text()
	if busy then
		done(false, busy)
		return false
	end
	if type(rid) ~= "string" or rid == "" then
		done(false, "Not added: pick a motion sensor or area first")
		return false
	end
	local entry = self.registry[rid]
	if entry then
		done(false, string.format("Not added: %s is already imported (device %d)", self:entry_label(rid, entry),
			entry.device_id))
		return false
	end
	local record = self:record_of(rid)
	if not self:addable(record) then
		done(false, string.format("Not added: motion sensor or area %s is not on the bridge (connect the event stream and "
			.. "try again)", tostring(rid)))
		return false
	end
	local room_name
	room_id, room_name = self:room_for_add(record, room_id, self.project:rooms())
	if not room_id then
		done(false, room_name)
		return false
	end
	self.adding, self.adding_since = true, os.time()
	local label = util.sanitise(name_of(record))
	self:create({ { record = record, room_id = room_id, room_name = room_name } }, function(created, _, err)
		self.adding = false
		self:reconcile(true, owner.created_set(created))
		self:flush()
		local text
		if created[1] then
			text = string.format("Added %s to %s (device %d)", label, room_name, created[1].device_id)
		elseif err then
			text = "Not added: " .. err
		else
			text = string.format("Not added: AddDevice failed for %s (see the Lua output)", label)
		end
		self.ctx.log.always("motion: %s", text)
		self:protect("add done", done, created[1] ~= nil, text)
		self:run_pending_resync()
	end)
	return true
end

-- New on the bridge, and re-link hints (S1, S4, S6, A1, A13) -------------------------------------------

-- The sensors and areas of `kind` not added and not deleted from Composer.
function motion:new_records(kind)
	local out, tombs = {}, self.reg:tombstones()
	for _, record in ipairs(sorted(kind == "area" and self.area_records or self.sensor_records)) do
		if not self.registry[record.rid] and tombs[record.rid] == nil and self:addable(record) then
			out[#out + 1] = record
		end
	end
	return out
end

-- Whether a linked sensor has been unreachable for an hour (S9; EC §8 item 8).
function motion:long_unreachable(rid)
	local s = self.since[rid]
	return s ~= nil and s.unreachable ~= nil and self.ctx.now() - s.unreachable >= motion.ATTENTION_AFTER_S
end

-- The entry a new record may replace, and why: a sensor whose entry is gone
-- or unreachable for an hour with the same radio (S6), else the same name in
-- the same Hue room (S4: default names repeat, S11); an area whose gone
-- entry has its name and room or zone (A13). rid, entry, "mac" | "name" or nil.
function motion:relink_hint(record)
	local by_mac, by_name
	local mac = record.kind ~= "area" and self:mac_of(record.rid) or nil
	local room = record.kind == "area" and (record.group and record.group.rid) or record.room
	for _, rid in ipairs(self.reg:rids()) do
		local entry = self.registry[rid]
		local source = entry.state == "gone" or (entry.state == "linked" and record.kind ~= "area"
			and self:long_unreachable(rid))
		if source and kind_of(entry) == kind_of(record) then
			if mac and entry.mac_address == mac then
				by_mac = by_mac or rid
			elseif record.name ~= nil and entry.name == record.name and entry.hue_room_rid == room then
				by_name = by_name or rid
			end
		end
	end
	local rid = by_mac or by_name
	if rid then
		return rid, self.registry[rid], by_mac and "mac" or "name"
	end
	return nil
end

function motion:hint_text(record)
	local rid, entry, why = self:relink_hint(record)
	if not rid then
		return nil
	end
	return string.format(" (%s %s, device %d; re-link?)", why == "mac" and "same radio as" or "looks like",
		self:entry_label(rid, entry), entry.device_id)
end

-- Log each new sensor and area once per run (S1, A1), with its hint.
function motion:announce_new_all()
	for _, kind in ipairs({ "sensor", "area" }) do
		for _, record in ipairs(self:new_records(kind)) do
			if not self.announced_new[record.rid] then
				self.announced_new[record.rid] = true
				self.ctx.log.always("motion: new %s %s on the bridge; use %s%s", words_of(record).kind,
					self:label_of(record), words_of(record).add_action, self:hint_text(record) or "")
			end
		end
	end
end

-- Attention (D5, D6; EC §8 item 11) -------------------------------------------------------------------

local function named(names)
	return util.some(names, motion.MAX_NAMED)
end

-- In this order: new on the bridge, missing from it, unbound, two claimants,
-- names; then the batteries (at once), unreachable sensors (after an hour),
-- switched off and paused (D6), not running (at once), degraded and without
-- a reading (after an hour), area devices on a bridge without MotionAware.
function motion:attention_items(items)
	items = items or {}
	local words = motion.WORDS

	for _, kind in ipairs({ "sensor", "area" }) do
		local names = {}
		for _, record in ipairs(self:new_records(kind)) do
			names[#names + 1] = self:label_of(record) .. (self:hint_text(record) or "")
		end
		if #names > 0 then
			local w = motion.KIND_WORDS[kind]
			items[#items + 1] = string.format("%s on the bridge: %s (%s)", util.plural(#names, "new " .. w.kind),
				named(names), w.add_action)
		end
	end

	for _, kind in ipairs({ "sensor", "area" }) do
		local names = {}
		for _, rid in ipairs(self.reg:rids("gone")) do
			local entry = self.registry[rid]
			if kind_of(entry) == kind then
				names[#names + 1] = string.format("%s (device %d, since %s)", self:entry_label(rid, entry), entry.device_id,
					util.date_of(entry.gone_since))
			end
		end
		if #names > 0 then
			items[#items + 1] = string.format("%s missing from the bridge: %s (%s)", util.plural(#names,
				motion.KIND_WORDS[kind].kind), named(names), words.relink_or_forget)
		end
	end

	local unbound = {}
	for _, rid in ipairs(self.reg:rids("unbound")) do
		local entry = self.registry[rid]
		unbound[#unbound + 1] = string.format("%s (device %d)", self:entry_label(rid, entry), entry.device_id)
	end
	if #unbound > 0 then
		items[#items + 1] = string.format("%s: %s (bind it to this bridge in Composer, or %s)", util.plural(#unbound,
			words.unbound_kind), named(unbound), words.forget_action)
	end

	local conflict_rids = {}
	for rid in pairs(self.conflicts) do
		conflict_rids[#conflict_rids + 1] = rid
	end
	table.sort(conflict_rids)
	for _, rid in ipairs(conflict_rids) do
		local c = self.conflicts[rid]
		items[#items + 1] = string.format("2 devices claim Hue %s: %d and %d (%s on one of them)", self:conflict_label(rid),
			c.holder, c.claimant, words.forget_action)
	end

	local diffs = self:name_differences()
	if #diffs > 0 then
		local names = {}
		for _, d in ipairs(diffs) do
			names[#names + 1] = string.format("%s is %s in Hue", d.current, d.expected)
		end
		items[#items + 1] = string.format("%d %s%s differ%s from the Composer names: %s (Adopt Hue Names or Accept Names "
			.. "As They Are)", #diffs, words.name_kind, #diffs == 1 and "" or "s", #diffs == 1 and "s" or "", named(names))
	end

	local now = self.ctx.now()
	local function long(rid, condition)
		local s = self.since[rid]
		return s ~= nil and s[condition] ~= nil and now - s[condition] >= motion.ATTENTION_AFTER_S
	end
	local low, critical, unreachable, off, paused, not_running, degraded, no_reading, unsupported =
		{}, {}, {}, {}, {}, {}, {}, {}, {}
	for _, rid in ipairs(self.reg:rids("linked")) do
		local entry = self.registry[rid]
		local label = self:entry_label(rid, entry)
		if entry.kind == "area" then
			local record = self.area_records[rid]
			if self.areas_supported == false then
				unsupported[#unsupported + 1] = label
			elseif record and record.enabled == false then
				paused[#paused + 1] = label
			elseif record and motion_model.NOT_RUNNING[record.health] then
				not_running[#not_running + 1] = label
			elseif long(rid, "degraded") then
				degraded[#degraded + 1] = label
			end
			if long(rid, "no_reading") then
				no_reading[#no_reading + 1] = label
			end
		else
			local record = self.sensor_records[rid]
			local m, p = self:service_reading(record, "motion"), self:service_reading(record, "device_power")
			if p and (p.battery_state == "low" or p.battery_state == "critical") then
				local list = p.battery_state == "low" and low or critical
				list[#list + 1] = label .. (p.battery_level and string.format(" %d %%", p.battery_level) or "")
			end
			if m and m.enabled == false then
				off[#off + 1] = label
			elseif long(rid, "unreachable") then
				local held = self.sent[rid]
				unreachable[#unreachable + 1] = label .. ((held and held.motion == "true") and " (still showing motion)" or "")
			elseif long(rid, "no_reading") then
				no_reading[#no_reading + 1] = label
			end
		end
	end
	local function add(list, fmt, ...)
		if #list > 0 then
			items[#items + 1] = string.format(fmt, #list, ...)
		end
	end
	local function s(list)
		return #list == 1 and "" or "s"
	end
	add(low, "%d motion sensor batter%s low: %s", #low == 1 and "y" or "ies", named(low))
	add(critical, "%d motion sensor batter%s critical: %s", #critical == 1 and "y" or "ies", named(critical))
	add(unreachable, "%d motion sensor%s not reachable for more than 1 h: %s", s(unreachable), named(unreachable))
	add(off, "%d motion sensor%s switched off in the Hue app: %s", s(off), named(off))
	add(paused, "%d motion area%s paused in the Hue app: %s", s(paused), named(paused))
	add(not_running, "%d motion area%s not running: %s (open it in the Hue app and save it again)", s(not_running),
		named(not_running))
	add(degraded, "%d motion area%s degraded for more than 1 h: %s (power its lights)", s(degraded), named(degraded))
	add(no_reading, "%d motion device%s without a motion reading from Hue for more than 1 h: %s", s(no_reading),
		named(no_reading))
	add(unsupported, "%d motion area device%s on a bridge without MotionAware: %s (%s)", s(unsupported),
		named(unsupported), words.relink_or_forget)
	return items
end

-- Pickers: { text, value } lists, value a string -----------------------------------------------------

-- Add Motion Sensor's Sensor (and, with the areas, Re-link's target): the
-- sensors not added, hinted ones first ("Hallway sensor [Hallway] #31
-- (looks like Hallway sensor, device 1201; re-link?)"), then by name, those
-- deleted from Composer last.
function motion:picker_sensors()
	return self:picker("sensor")
end

-- Add Motion Area's Area: "Kitchen motion area (MotionAware) [Kitchen] #ac00".
function motion:picker_areas()
	return self:picker("area")
end

function motion:picker(kind)
	if kind == "area" and self.areas_supported == false then
		return util.empty_list("(this bridge offers no MotionAware areas)")
	end
	local fetched = kind == "area" and self.got[motion.CONFIG_TYPE] or (self.got.motion and self:devices_loaded())
	local records = kind == "area" and self.area_records or self.sensor_records
	if not fetched and next(records) == nil then
		return util.empty_list(kind == "area" and "(no MotionAware areas fetched yet; connect the event stream)"
			or "(no motion sensors fetched yet; connect the event stream)")
	end
	local hinted, plain, deleted, any = {}, {}, {}, false
	local tombs = self.reg:tombstones()
	for _, record in ipairs(sorted(records)) do
		if self:addable(record) then
			any = true
			if not self.registry[record.rid] then
				local text = self:label_of(record)
				local tomb = tombs[record.rid]
				local hint = self:hint_text(record)
				if tomb then
					deleted[#deleted + 1] = { text = string.format("%s (deleted from Composer %s)", text,
						util.date_of(tomb.deleted_at)), value = record.rid }
				elseif hint then
					hinted[#hinted + 1] = { text = text .. hint, value = record.rid }
				else
					plain[#plain + 1] = { text = text, value = record.rid }
				end
			end
		end
	end
	for _, item in ipairs(plain) do
		hinted[#hinted + 1] = item
	end
	for _, item in ipairs(deleted) do
		hinted[#hinted + 1] = item
	end
	if #hinted == 0 then
		if kind == "area" then
			return util.empty_list(any and "(every MotionAware area on the bridge is added)"
				or "(no MotionAware areas on the bridge)")
		end
		return util.empty_list(any and "(every motion sensor on the bridge is added)" or "(no motion sensors on the bridge)")
	end
	return hinted
end

-- Re-link's Device: the gone and unbound entries (owner.lua's), then the
-- linked sensors unreachable for an hour (EC §8 item 8: a dead sensor
-- usually stays in the Hue app). {} when there are none.
function motion:picker_relink_devices()
	local list = owner.picker_relink_devices(self)
	for _, rid in ipairs(self.reg:rids("linked")) do
		local entry = self.registry[rid]
		if entry.kind ~= "area" and self:long_unreachable(rid) then
			list[#list + 1] = { text = self:device_text(rid, entry, string.format(", not reachable since %s",
				util.short_date_of(self.since[rid].unreachable))), value = tostring(entry.device_id) }
		end
	end
	return list
end

-- Texts ------------------------------------------------------------------------------------------

-- The Motion Sensors row: "2 sensors and 1 area on the bridge; 1 added",
-- with ", n missing" / ", n unbound" / ", n deleted" when not zero, and
-- "; MotionAware not supported by this bridge" without the area types;
-- "<n> added" before the sensors are fetched.
function motion:summary()
	if not (self.got.motion and self:devices_loaded()) then
		return string.format("%d added", self:count())
	end
	local sensors, areas = 0, 0
	for _, record in pairs(self.sensor_records) do
		if record.motion then
			sensors = sensors + 1
		end
	end
	for _ in pairs(self.area_records) do
		areas = areas + 1
	end
	local text
	if self.areas_supported == false then
		text = string.format("%s on the bridge; %d added", util.plural(sensors, "sensor"), self:count())
	elseif self.got[motion.CONFIG_TYPE] then
		text = string.format("%s and %s on the bridge; %d added", util.plural(sensors, "sensor"), util.plural(areas, "area"),
			self:count())
	else
		text = string.format("%s and ? areas on the bridge; %d added", util.plural(sensors, "sensor"), self:count())
	end
	local c = self.reg:counts()
	if c.gone > 0 then
		text = text .. string.format(", %d missing", c.gone)
	end
	if c.unbound > 0 then
		text = text .. string.format(", %d unbound", c.unbound)
	end
	if c.tombstones > 0 then
		text = text .. string.format(", %d deleted", c.tombstones)
	end
	if self.areas_supported == false then
		text = text .. "; MotionAware not supported by this bridge"
	end
	return text
end

local function entry_suffix(entry)
	if entry.state == "gone" then
		return string.format(" (missing; device %d)", entry.device_id)
	elseif entry.state == "unbound" then
		return string.format(" (unbound; device %d)", entry.device_id)
	end
	return string.format(" → device %d", entry.device_id)
end

-- The Motion Sensors drop-down: every sensor then every area on the bridge
-- as the pickers label them, with " → device N" when added, " (unbound;
-- device N)", " (deleted from Composer <date>)"; then the registered ones
-- the bridge lacks, "(missing; device N)". Commas become "‚" (U+201A): the
-- list is comma-delimited.
function motion:list_items()
	local out, listed = {}, {}
	local tombs = self.reg:tombstones()
	for _, records in ipairs({ self.sensor_records, self.area_records }) do
		for _, record in ipairs(sorted(records)) do
			local entry = self.registry[record.rid]
			if entry or self:addable(record) then
				listed[record.rid] = true
				local text = self:label_of(record)
				if entry then
					text = text .. entry_suffix(entry)
				elseif tombs[record.rid] then
					text = text .. string.format(" (deleted from Composer %s)", util.date_of(tombs[record.rid].deleted_at))
				end
				out[#out + 1] = text
			end
		end
	end
	for _, rid in ipairs(self.reg:rids()) do
		if not listed[rid] then
			local entry = self.registry[rid]
			out[#out + 1] = string.format("%s (%s)%s", self:entry_label(rid, entry), words_of(entry).kind,
				entry_suffix(entry))
		end
	end
	for i, text in ipairs(out) do
		out[i] = (text:gsub(",", "‚"))
	end
	return out
end

return motion
