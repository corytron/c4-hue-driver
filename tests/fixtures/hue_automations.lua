-- Hue behaviour scripts and instances for the automation audit specs
-- (docs/hue-automation-audit-design.md §7, §8): one small bridge in the
-- shapes of docs/hue-automations-research.md (HAR) §1.3, §1.4, §1.8 and the
-- house's MotionAware instance (contract H3, H4). Every resource id is
-- invented and coded by type as the motion fixtures are (1b light, de
-- device, 40 room or home, 20 zone, 5e scene, bb button, ad
-- relative_rotary, a0 motion, 11 light_level, ac motion_area_configuration,
-- ca convenience_area_motion, ec entertainment_configuration, 7c recipe,
-- b1 behavior_instance, 5c an invented behavior_script, e0 event
-- container). The script ids of HAR §2 are public (the same on every
-- bridge) and quoted as they are; the scripts whose ids no public dump
-- shows (motion sensor, contact sensor, smoke alarm, a custom behaviour)
-- get invented 5c ids. No bridge id or address appears.
--
-- Items are authored as Lua tables. Every accessor returns a fresh copy
-- that went through JSON (dkjson), so a spec can change it freely and reads
-- what a decoded GET body or event item holds.
--
-- The bridge:
--   Rooms   Bedroom (Bedroom Lamp, Bedroom Ceiling, Bedside), Hallway (Hall Lamp),
--           Kitchen (Kitchen 1, Kitchen 2, Kitchen 3), Living Room (Living Lamp, Desk Lamp),
--           Outdoor (Porch Light, Garage)
--   Zone    Downstairs (Hall Lamp, Kitchen 1, Living Lamp)
--   Home    bridge_home: every light
--   Scenes  Bedroom Bright (Bedroom), Kitchen Bright, Kitchen Relax, Kitchen Night (Kitchen),
--           Living Evening, Welcome (Living Room), Porch On (Outdoor),
--           Downstairs Bright (Downstairs), Hall Bright (Hallway)
--   Devices one per light (the light's device id ends like its light id), plus the
--           dimmer switch, the tap dial and the motion sensor (no light service)
--   TV area an entertainment_configuration with TV Strip (in no room)
--
-- Instances (A.instance(key); A.ids.instances[key]; the name is A.names[key]):
--   wake_up              Wake Weekdays: Basic wake up routine, `when`, Bedroom with two
--                        of its lights, migrated from v1 (HAR §1.8)
--   go_to_sleep          Bedtime: Basic go to sleep routine with no `when` (a person starts it)
--   schedule             Evening lights: Schedule, `when_extended`, Living Room, recalls Living Evening
--   vacation             Vacation lights: Schedule on Outdoor, disabled in Hue (status disabled)
--   timer                Hall timer: Timers, `duration`, Hallway, recalls a recipe; timer_state
--   coming_home          Coming home: Coming home, Living Room, recalls Welcome, nighttime only
--   mimic_started        Away lights: PM (mimic presence), Bedroom and Living Room, pm_state started
--   mimic_stopped        the same instance (same id), pm_state stopped
--   dimmer               Bedroom dimmer: Hue Accessories (67d9…), a dimmer switch on the
--                        Downstairs zone: button 1 recalls Downstairs Bright, buttons 2 to 4
--                        do nothing (one `recall` and three `do_nothing`)
--   tap_dial             Kitchen tap dial: Tap Switch, button1..button4 and rotary, each with
--                        its own `where`: Kitchen, and Hallway for button 3 (all off)
--   motionaware_before   Kitchen motion area: Hue Accessories (67d9…, as on the house, H2),
--                        `source` the area's motion_area_configuration, three time slots
--                        recalling the three Kitchen scenes, all off on no motion (H3)
--   motionaware_after    the same instance (same id) after the owner's Do nothing: one slot,
--                        `do_nothing` on motion and on no motion, scenes gone from dependees (H4)
--   motion_sensor        Hallway sensor: Motion Sensor, `source` the sensor's device, the
--                        motion and light_level services, Hallway, recalls Hall Bright
--   streaming            TV area after streaming: Light state after streaming (entertainment)
--   natural_light        Natural light: Natural Light (empty category), Living Room
--   smoke_alarm          Smoke alarm lights: Smoke alarm automation, Bedroom and Hallway
--   unknown              Evening routine: a script no GET has listed (A.ids.scripts.custom);
--                        A.script("custom") is what reading it later returns
--
-- Scripts (A.script(key); A.ids.scripts[key]): wake_up, go_to_sleep, schedule, timers,
-- coming_home, leaving_home, mimic, natural_light, streaming, tap_switch,
-- hue_accessories, motion_sensor, contact_sensor, smoke_alarm; and custom, which
-- A.SCRIPTS (the default GET) leaves out.

local json = require("dkjson")

local A = {}

local function id(prefix, n)
	return prefix .. "000000-0000-4000-8000-0000000000" .. n
end

local function ref(rid, rtype)
	return { rid = rid, rtype = rtype }
end

local function dep(rid, rtype, level)
	return { type = "ResourceDependee", level = level or "critical", target = ref(rid, rtype) }
end

local function at(hour, minute)
	return { hour = hour, minute = minute }
end

-- Only the decoded value: json.decode also returns the position it stopped at.
local function copy(value)
	local decoded = json.decode(json.encode(value))
	return decoded
end

-- Lights, their names, and their devices (de + the light's number).
local LIGHT_KEYS = {
	bedroom_lamp = "01", bedroom_ceiling = "02", bedside = "03", hall_lamp = "04", porch = "05",
	garage = "06", kitchen1 = "07", kitchen2 = "08", kitchen3 = "09", living_lamp = "0a",
	desk_lamp = "0b", tv_strip = "0c",
}
local LIGHT_NAMES = {
	bedroom_lamp = "Bedroom Lamp", bedroom_ceiling = "Bedroom Ceiling", bedside = "Bedside",
	hall_lamp = "Hall Lamp", porch = "Porch Light", garage = "Garage", kitchen1 = "Kitchen 1",
	kitchen2 = "Kitchen 2", kitchen3 = "Kitchen 3", living_lamp = "Living Lamp", desk_lamp = "Desk Lamp",
	tv_strip = "TV Strip",
}

local ids = {
	lights = {}, devices = {},
	rooms = { bedroom = id("40", "01"), hallway = id("40", "02"), kitchen = id("40", "03"),
		living = id("40", "04"), outdoor = id("40", "05") },
	zones = { downstairs = id("20", "01") },
	home = id("40", "f0"),
	scenes = { bedroom_bright = id("5e", "01"), kitchen_bright = id("5e", "02"), kitchen_relax = id("5e", "03"),
		kitchen_night = id("5e", "04"), living_evening = id("5e", "05"), welcome = id("5e", "06"),
		porch_on = id("5e", "07"), downstairs_bright = id("5e", "08"), hall_bright = id("5e", "09") },
	recipes = { energize = id("7c", "01") },
	buttons = { dimmer1 = id("bb", "01"), dimmer2 = id("bb", "02"), dimmer3 = id("bb", "03"),
		dimmer4 = id("bb", "04"), tap1 = id("bb", "11"), tap2 = id("bb", "12"), tap3 = id("bb", "13"),
		tap4 = id("bb", "14") },
	rotary = id("ad", "01"),
	motion = id("a0", "41"),
	light_level = id("11", "41"),
	area = id("ac", "01"),
	convenience = id("ca", "01"),
	entertainment = id("ec", "01"),
	scripts = {
		-- Public ids (HAR §2): the same script on every bridge.
		wake_up = "ff8957e3-2eb9-4699-a0c8-ad2cb3ede704",
		go_to_sleep = "7e571ac6-f363-42e1-809a-4cbf6523ed72",
		schedule = "7238c707-8693-4f19-9095-ccdc1444d228",
		timers = "e73bc72d-96b1-46f8-aa57-729861f80c78",
		coming_home = "fd60fcd1-4809-4813-b510-4a18856a595c",
		leaving_home = "0194752a-2d53-4f92-8209-dfdc52745af3",
		mimic = "db06cabc-c752-4904-9e8f-4ebe98feaa1a",
		natural_light = "a4260b49-0c69-4926-a29c-417f4a38a352",
		streaming = "7719b841-6b3d-448d-a0e7-601ae9edb6a2",
		tap_switch = "f306f634-acdb-4dd6-bdf5-48dd626d667e",
		hue_accessories = "67d9395b-4403-42cc-b5f0-740b699d67c6",
		-- Invented: no public dump shows these ids.
		motion_sensor = id("5c", "01"),
		contact_sensor = id("5c", "02"),
		smoke_alarm = id("5c", "03"),
		custom = id("5c", "f1"),
	},
	instances = {
		wake_up = id("b1", "01"), dimmer = id("b1", "02"), schedule = id("b1", "03"), timer = id("b1", "04"),
		coming_home = id("b1", "05"), mimic = id("b1", "06"), tap_dial = id("b1", "07"),
		motionaware = id("b1", "08"), motion_sensor = id("b1", "09"), streaming = id("b1", "0a"),
		unknown = id("b1", "0b"), smoke_alarm = id("b1", "0c"), go_to_sleep = id("b1", "0d"),
		vacation = id("b1", "0e"), natural_light = id("b1", "0f"),
	},
	switch_devices = { dimmer = id("de", "31"), tap_dial = id("de", "32"), motion_sensor = id("de", "41") },
}
for key, n in pairs(LIGHT_KEYS) do
	ids.lights[key] = id("1b", n)
	ids.devices[key] = id("de", n)
end
-- Instance keys with two states share their instance's id.
ids.instances.mimic_started = ids.instances.mimic
ids.instances.mimic_stopped = ids.instances.mimic
ids.instances.motionaware_before = ids.instances.motionaware
ids.instances.motionaware_after = ids.instances.motionaware
A.ids = ids

local L, R, S = ids.lights, ids.rooms, ids.scenes

-- What the bridge's rooms, zones and scenes hold, for a spec's fake
-- `expand` and `light_name` (contract §6.1, D4).
A.topology = {
	members = {
		[R.bedroom] = { L.bedroom_lamp, L.bedroom_ceiling, L.bedside },
		[R.hallway] = { L.hall_lamp },
		[R.kitchen] = { L.kitchen1, L.kitchen2, L.kitchen3 },
		[R.living] = { L.living_lamp, L.desk_lamp },
		[R.outdoor] = { L.porch, L.garage },
		[ids.zones.downstairs] = { L.hall_lamp, L.kitchen1, L.living_lamp },
	},
	group_rtype = {
		[R.bedroom] = "room", [R.hallway] = "room", [R.kitchen] = "room", [R.living] = "room",
		[R.outdoor] = "room", [ids.zones.downstairs] = "zone", [ids.home] = "bridge_home",
	},
	scene_group = {
		[S.bedroom_bright] = ref(R.bedroom, "room"),
		[S.kitchen_bright] = ref(R.kitchen, "room"),
		[S.kitchen_relax] = ref(R.kitchen, "room"),
		[S.kitchen_night] = ref(R.kitchen, "room"),
		[S.living_evening] = ref(R.living, "room"),
		[S.welcome] = ref(R.living, "room"),
		[S.porch_on] = ref(R.outdoor, "room"),
		[S.downstairs_bright] = ref(ids.zones.downstairs, "zone"),
		[S.hall_bright] = ref(R.hallway, "room"),
	},
	device_lights = {},
	light_names = {},
	-- The lights of the TV area: an entertainment_configuration is neither a
	-- trigger nor a target (D4), so an expand that follows D4 never uses this.
	entertainment_lights = { [ids.entertainment] = { L.tv_strip } },
}
A.topology.members[ids.home] = {}
for key, rid in pairs(L) do
	A.topology.device_lights[ids.devices[key]] = { rid }
	A.topology.light_names[rid] = LIGHT_NAMES[key]
	table.insert(A.topology.members[ids.home], rid)
end
table.sort(A.topology.members[ids.home])
A.light_names = LIGHT_NAMES

-- Scripts ----------------------------------------------------------------

local function script(key, name, category, description, extra)
	local item = {
		id = ids.scripts[key], type = "behavior_script",
		metadata = { name = name, category = category },
		description = description,
		configuration_schema = { ["$ref"] = key .. "_config.json#" },
		version = "0.0.1",
	}
	for k, v in pairs(extra or {}) do
		item[k] = v
	end
	return item
end

local SCRIPTS = {
	wake_up = script("wake_up", "Basic wake up routine", "automation", "Get your body in the mood to wake up"),
	go_to_sleep = script("go_to_sleep", "Basic go to sleep routine", "automation", "Get ready for nice sleep"),
	schedule = script("schedule", "Schedule", "automation", "Schedule lights at given times"),
	timers = script("timers", "Timers", "automation", "Countdown Timer"),
	coming_home = script("coming_home", "Coming home", "automation", "Automatically turn your lights on"),
	leaving_home = script("leaving_home", "Leaving home", "automation", "Automatically turn your lights off"),
	mimic = script("mimic", "PM", "automation", "Presence mimicking", { max_number_instances = 1 }),
	natural_light = script("natural_light", "Natural Light", "", "Natural light during the day"),
	streaming = script("streaming", "Light state after streaming", "entertainment",
		"State of lights after an entertainment session"),
	tap_switch = script("tap_switch", "Tap Switch", "accessory", "Tap Switch script"),
	hue_accessories = script("hue_accessories", "Hue Accessories", "accessory", "Accessory behaviours"),
	motion_sensor = script("motion_sensor", "Motion Sensor", "accessory", "Motion sensor behaviour"),
	contact_sensor = script("contact_sensor", "Contact Sensor", "accessory", "Contact sensor behaviour"),
	smoke_alarm = script("smoke_alarm", "Smoke alarm automation", "automation", "Lights on when an alarm sounds",
		{ max_number_instances = 1 }),
	custom = script("custom", "Custom behavior", "other", "A behaviour made in the app"),
}

-- The scripts of a full GET, in the order the bridge serves them (custom left out).
A.SCRIPTS = {
	"wake_up", "go_to_sleep", "schedule", "timers", "coming_home", "leaving_home", "mimic", "natural_light",
	"streaming", "tap_switch", "hue_accessories", "motion_sensor", "contact_sensor", "smoke_alarm",
}

-- Instances --------------------------------------------------------------

local function instance(key, script_key, name, configuration, dependees, extra)
	local item = {
		id = ids.instances[key], type = "behavior_instance",
		script_id = ids.scripts[script_key],
		metadata = { name = name },
		enabled = true, status = "running", last_error = "",
		configuration = configuration,
		dependees = dependees,
	}
	for k, v in pairs(extra or {}) do
		item[k] = v
	end
	return item
end

local WEEKDAYS = { "monday", "tuesday", "wednesday", "thursday", "friday" }
local EVERY_DAY = { "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday" }

local function recall(scene_rid)
	return { action = { recall = ref(scene_rid, "scene") } }
end

local function slot(hour, minute, on_motion, after_minutes, on_no_motion)
	return {
		start_time = at(hour, minute),
		on_motion = { recall_single = { on_motion } },
		on_no_motion = { after = { minutes = after_minutes }, recall_single = { on_no_motion } },
	}
end

local INSTANCES = {}

INSTANCES.wake_up = instance("wake_up", "wake_up", "Wake Weekdays", {
	fade_in_duration = { seconds = 600 },
	when = { recurrence_days = WEEKDAYS, time_point = { type = "time", time = at(6, 30) } },
	where = { { group = ref(R.bedroom, "room"),
		items = { ref(L.bedroom_lamp, "light"), ref(L.bedside, "light") } } },
}, {
	dep(R.bedroom, "room"), dep(L.bedroom_lamp, "light"), dep(L.bedside, "light"),
}, { migrated_from = "/resourcelinks/12" })

INSTANCES.go_to_sleep = instance("go_to_sleep", "go_to_sleep", "Bedtime", {
	fade_out_duration = { seconds = 900 },
	style = "basic",
	where = { { group = ref(R.bedroom, "room") } },
}, { dep(R.bedroom, "room") })

INSTANCES.schedule = instance("schedule", "schedule", "Evening lights", {
	when_extended = { recurrence_days = EVERY_DAY, start_at = { time_point = { type = "time", time = at(19, 0) } } },
	what = { { group = ref(R.living, "room"), recall = ref(S.living_evening, "scene") } },
	where = { { group = ref(R.living, "room") } },
}, { dep(R.living, "room"), dep(S.living_evening, "scene") })

INSTANCES.vacation = instance("vacation", "schedule", "Vacation lights", {
	when_extended = { recurrence_days = EVERY_DAY, start_at = { time_point = { type = "time", time = at(20, 15) } } },
	what = { { group = ref(R.outdoor, "room"), recall = ref(S.porch_on, "scene") } },
	where = { { group = ref(R.outdoor, "room") } },
}, { dep(R.outdoor, "room"), dep(S.porch_on, "scene") }, { enabled = false, status = "disabled" })

INSTANCES.timer = instance("timer", "timers", "Hall timer", {
	duration = { seconds = 900 },
	what = { { group = ref(R.hallway, "room"), recall = ref(ids.recipes.energize, "recipe") } },
	where = { { group = ref(R.hallway, "room") } },
}, { dep(R.hallway, "room") }, { state = { timer_state = "stopped" } })

INSTANCES.coming_home = instance("coming_home", "coming_home", "Coming home", {
	what = { { group = ref(R.living, "room"), recall = ref(S.welcome, "scene") } },
	when_constrained = { type = "nighttime" },
	where = { { group = ref(R.living, "room") } },
}, { dep(R.living, "room"), dep(S.welcome, "scene") })

local function mimic(key, pm_state)
	return instance(key, "mimic", "Away lights", {
		where = { { group = ref(R.bedroom, "room") }, { group = ref(R.living, "room") } },
	}, { dep(R.bedroom, "room"), dep(R.living, "room") }, { state = { pm_state = pm_state } })
end
INSTANCES.mimic_started = mimic("mimic_started", "started")
INSTANCES.mimic_stopped = mimic("mimic_stopped", "stopped")

local B = ids.buttons
INSTANCES.dimmer = instance("dimmer", "hue_accessories", "Bedroom dimmer", {
	device = ref(ids.switch_devices.dimmer, "device"),
	model_id = "RWL022",
	where = { { group = ref(ids.zones.downstairs, "zone") } },
	buttons = {
		[B.dimmer1] = { on_short_release = { time_based_extended = {
			slots = { { start_time = at(7, 0), actions = { recall(S.downstairs_bright) } } },
			with_off = { enabled = false },
		} } },
		[B.dimmer2] = { on_repeat = { action = "do_nothing" } },
		[B.dimmer3] = { on_repeat = { action = "do_nothing" } },
		[B.dimmer4] = { on_short_release = { action = "do_nothing" } },
	},
}, {
	dep(ids.switch_devices.dimmer, "device"), dep(ids.zones.downstairs, "zone"),
	dep(S.downstairs_bright, "scene"), dep(B.dimmer1, "button"), dep(B.dimmer2, "button"),
	dep(B.dimmer3, "button"), dep(B.dimmer4, "button"),
}, { state = { model_id = "RWL022", source_type = "device" } })

INSTANCES.tap_dial = instance("tap_dial", "tap_switch", "Kitchen tap dial", {
	device = ref(ids.switch_devices.tap_dial, "device"),
	model_id = "RDM002",
	button1 = {
		on_short_release = { recall_single_extended = { actions = { recall(S.kitchen_bright) },
			with_off = { enabled = true } } },
		where = { { group = ref(R.kitchen, "room") } },
	},
	button2 = {
		on_short_release = { scene_cycle_extended = {
			slots = { { recall(S.kitchen_relax) }, { recall(S.kitchen_night) } },
			with_off = { enabled = false }, repeat_timeout = { seconds = 3 },
		} },
		where = { { group = ref(R.kitchen, "room") } },
	},
	button3 = {
		on_short_release = { action = "all_off" },
		where = { { group = ref(R.hallway, "room") } },
	},
	button4 = {
		on_long_press = { action = "do_nothing" },
		where = { { group = ref(R.kitchen, "room") } },
	},
	rotary = {
		on_dim_off = { action = "dim_down" },
		on_dim_on = { action = "dim_up" },
		where = { { group = ref(R.kitchen, "room") } },
	},
}, {
	dep(ids.switch_devices.tap_dial, "device"), dep(R.kitchen, "room"), dep(R.hallway, "room"),
	dep(S.kitchen_bright, "scene"), dep(S.kitchen_relax, "scene"), dep(S.kitchen_night, "scene"),
	dep(B.tap1, "button"), dep(B.tap2, "button"), dep(B.tap3, "button"), dep(B.tap4, "button"),
	dep(ids.rotary, "relative_rotary"),
}, { state = { model_id = "RDM002", source_type = "device" } })

-- The house's MotionAware instance (H3), and after Do nothing (H4).
local function motionaware(key, timeslots, scenes)
	local dependees = { dep(ids.area, "motion_area_configuration"), dep(R.kitchen, "room") }
	for _, rid in ipairs(scenes) do
		dependees[#dependees + 1] = dep(rid, "scene")
	end
	dependees[#dependees + 1] = dep(ids.convenience, "convenience_area_motion")
	return instance(key, "hue_accessories", "Kitchen motion area", {
		source = ref(ids.area, "motion_area_configuration"),
		motion = {
			motion_service = ref(ids.convenience, "convenience_area_motion"),
			where = { { group = ref(R.kitchen, "room") } },
			when = { timeslots = timeslots },
		},
	}, dependees)
end
INSTANCES.motionaware_before = motionaware("motionaware_before", {
	slot(7, 0, recall(S.kitchen_bright), 5, { action = "all_off" }),
	slot(18, 0, recall(S.kitchen_relax), 10, { action = "all_off" }),
	slot(23, 0, recall(S.kitchen_night), 2, { action = "all_off" }),
}, { S.kitchen_bright, S.kitchen_relax, S.kitchen_night })
INSTANCES.motionaware_after = motionaware("motionaware_after", {
	slot(0, 0, { action = "do_nothing" }, 5, { action = "do_nothing" }),
}, {})

INSTANCES.motion_sensor = instance("motion_sensor", "motion_sensor", "Hallway sensor", {
	source = ref(ids.switch_devices.motion_sensor, "device"),
	motion = {
		motion_service = ref(ids.motion, "motion"),
		where = { { group = ref(R.hallway, "room") } },
		when = { timeslots = { slot(0, 0, recall(S.hall_bright), 2, { action = "all_off" }) } },
	},
	light_level = { daylight = { daylight_sensitivity = {
		light_level_service = ref(ids.light_level, "light_level"),
		settings = { dark_threshold = 14477, offset = 7000 },
	} } },
}, {
	dep(ids.switch_devices.motion_sensor, "device"), dep(R.hallway, "room"), dep(S.hall_bright, "scene"),
	dep(ids.motion, "motion"),
})

INSTANCES.streaming = instance("streaming", "streaming", "TV area after streaming", {
	end_state = "last_state",
	where = { { group = ref(ids.entertainment, "entertainment_configuration") } },
}, { dep(ids.entertainment, "entertainment_configuration") })

INSTANCES.natural_light = instance("natural_light", "natural_light", "Natural light", {
	where = { { group = ref(R.living, "room") } },
}, { dep(R.living, "room") })

INSTANCES.smoke_alarm = instance("smoke_alarm", "smoke_alarm", "Smoke alarm lights", {
	where = { { group = ref(R.bedroom, "room") }, { group = ref(R.hallway, "room") } },
}, { dep(R.bedroom, "room"), dep(R.hallway, "room") })

INSTANCES.unknown = instance("unknown", "custom", "Evening routine", {
	style = "sunset",
	start = at(18, 30),
	where = { { group = ref(R.living, "room") } },
}, { dep(R.living, "room") })

-- The instances of a full GET (one per id: the house's MotionAware after
-- Do nothing, Mimic presence stopped).
A.INSTANCES = {
	"wake_up", "dimmer", "schedule", "timer", "coming_home", "mimic_stopped", "tap_dial",
	"motionaware_after", "motion_sensor", "streaming", "unknown", "smoke_alarm", "go_to_sleep",
	"vacation", "natural_light",
}

A.names = {}
for key, item in pairs(INSTANCES) do
	A.names[key] = item.metadata.name
end

-- Accessors --------------------------------------------------------------

-- A fresh behavior_script item.
function A.script(key)
	return copy(assert(SCRIPTS[key], "no fixture script " .. tostring(key)))
end

-- A fresh behavior_instance item.
function A.instance(key)
	return copy(assert(INSTANCES[key], "no fixture instance " .. tostring(key)))
end

-- Fresh items for a list of keys (default: A.SCRIPTS / A.INSTANCES).
function A.scripts(keys)
	local out = {}
	for i, key in ipairs(keys or A.SCRIPTS) do
		out[i] = A.script(key)
	end
	return out
end

function A.instances(keys)
	local out = {}
	for i, key in ipairs(keys or A.INSTANCES) do
		out[i] = A.instance(key)
	end
	return out
end

-- A GET response body as JSON text: { errors = {}, data = items }.
function A.body(items)
	local text = json.encode({ errors = {}, data = items })
	-- dkjson writes an empty Lua table as []: right for both lists.
	return text
end

-- The JSON text of GET /clip/v2/resource/behavior_script and
-- /behavior_instance (keys default to A.SCRIPTS / A.INSTANCES).
function A.get_scripts(keys)
	return A.body(A.scripts(keys))
end

function A.get_instances(keys)
	return A.body(A.instances(keys))
end

-- One event-stream container as on_container receives it (decoded):
-- { creationtime, id, type = "add" | "update" | "delete", data = items }.
local container_n = 0
function A.container(kind, items)
	container_n = container_n + 1
	return copy({
		creationtime = "2026-11-09T07:00:00Z",
		id = id("e0", string.format("%02x", container_n % 256)),
		type = kind,
		data = items,
	})
end

-- Update items: only what changed, as the stream sends it [assumed for
-- configuration and metadata: contract F12; HAR §1.7]. Each returns a fresh item.
A.updates = {}

-- `enabled` alone (the Hue app's switch).
function A.updates.enabled(key, enabled)
	return { id = ids.instances[key], type = "behavior_instance", enabled = enabled,
		status = enabled and "running" or "disabled" }
end

-- A new name alone.
function A.updates.name(key, name)
	return { id = ids.instances[key], type = "behavior_instance", metadata = { name = name } }
end

-- The whole configuration (and dependees) of another fixture state, as the
-- house's Do nothing save arrived (H4): A.updates.configuration("motionaware_after").
function A.updates.configuration(key)
	local item = A.instance(key)
	return { id = item.id, type = "behavior_instance", configuration = item.configuration,
		dependees = item.dependees }
end

-- Mimic presence started or stopped (its `state`).
function A.updates.pm_state(pm_state)
	return { id = ids.instances.mimic, type = "behavior_instance", state = { pm_state = pm_state } }
end

-- A delete item: id and type only.
function A.updates.delete(key)
	return { id = ids.instances[key], type = "behavior_instance" }
end

return A
