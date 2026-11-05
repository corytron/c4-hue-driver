-- The feature ledger (#334): one row per capability the drivers offer up to
-- beta 8, lifted from docs/simplify-research-compat.md §4, with the paths
-- that reach each one today. tests/spec/ledger_spec.lua checks that every
-- path still resolves, so the simplification of the actions cannot drop a
-- feature without failing the suite: a change that moves a feature edits this
-- file (the new path, the old command as an alias), never the spec.
--
-- A row:
--   id          P (pairing and connection), R (rooms), L (lights), Z (zone lights),
--               N (names), S (scenes), M (motion), G (every driver), and a number
--   capability  what the owner or dealer can do, in the words of the ledger
--   gate        how it starts today (§4): "click" (an action), "auto" (the driver,
--               by itself), "prop" (a property the owner sets), "prog" (Control4
--               programming), "proxy" (the proxy's own commands), "offered" (the
--               driver proposes, a click accepts); {} for the ledger's "—"
--   paths       every way it is reached today; each must resolve (see the spec)
--
-- A path (driver defaults to "hue_bridge"):
--   { action = "<command>", params = { "<param name>", ... }, dev = true? }
--       an <action> of driver.xml by its <command> (the <name> is free to
--       change, R1); params are its parameter names in order (none if absent);
--       dev = true for a DEV-ONLY action, absent from release builds
--   { property = "<name>", type = "<STRING|LIST|DYNAMIC_LIST|RANGED_INTEGER>", items = { ... }? }
--       a <property> of the release driver.xml with that type; items, for a
--       LIST, are items that must stay (a LIST item never changes meaning, R7)
--   { command = "<name>", params = { ... } }   a programming <command> of driver.xml
--   { event = "<name>", id = N }               an <event>, its id fixed forever
--   { conditional = "<name>", id = N }         a <conditional>, answered by TestCondition
--   { proxy = "<proxy>" }                      a <proxy> the driver declares
--   { proxy_command = "<COMMAND>", binding = N? }   a ReceivedFromProxy handler
--   { connection = "<connectionname>", id = N }     a <connection>, its id fixed forever
--   { message = "<HUE_*>" }                    an inter-driver message (SendToDevice)
--   { documentation = "<file>", find = "<text>"? }  the Documentation tab's page
--   { auto = "<trigger>", proof = { spec = "<file>", test = "<text of an it()>" } }
--   { auto = "<trigger>", proof = { module = "<file>", find = "<text>" } }
--       automatic today: not re-tested here, the named spec or module proves it
--   { alias = "<old command>" }                a hidden alias listed below
--
-- No room, house or person names; addresses only 192.0.2.x, 198.51.100.x or
-- 10.0.2.143 (gitleaks).

local ledger = {}

ledger.rows = {
	-- Pairing and connection ---------------------------------------------------
	{
		id = "P1",
		capability = "Pair with the bridge at an address via the link button; fill Bridge Model, Name, Firmware",
		gate = { "click" },
		paths = {
			{ action = "Pair Bridge" },
			{ property = "Bridge IP Address", type = "STRING" },
			{ property = "Bridge ID", type = "STRING" },
			{ property = "Bridge Model", type = "STRING" },
			{ property = "Bridge Name", type = "STRING" },
			{ property = "Bridge Firmware", type = "STRING" },
		},
	},
	{
		id = "P2",
		capability = "Refuse a different bridge until the pairing is forgotten; pair the same bridge again",
		gate = { "click" },
		paths = {
			{ action = "Pair Bridge" },
			{ action = "Forget Pairing" },
		},
	},
	{
		id = "P3",
		capability = "Refuse a BSB001 bridge, a device that is not a Hue bridge, or firmware older than CLIP v2",
		gate = { "click", "auto" },
		paths = {
			{ action = "Pair Bridge" },
			{ auto = "the identity check at every start", proof = { spec = "tests/spec/drivers_spec.lua",
				test = "shows the bridge's model, name and firmware from the identity check; refuses a first-generation" } },
		},
	},
	{
		id = "P4",
		capability = "Forget the pairing (key gone, stream stopped, address and devices kept)",
		gate = { "click" },
		paths = {
			{ action = "Forget Pairing" },
		},
	},
	{
		id = "P5",
		capability = "Follow a corrected address (the stream restarts)",
		gate = { "prop" },
		paths = {
			{ property = "Bridge IP Address", type = "STRING" },
		},
	},
	{
		id = "P6",
		capability = "Identity check without the key at every start and address change, retried every 30 s",
		gate = { "auto" },
		paths = {
			{ auto = "every start and address change", proof = { spec = "tests/spec/drivers_spec.lua",
				test = "asks an unreachable bridge for its identity again every 30 s and sends nothing meanwhile" } },
		},
	},
	{
		id = "P7",
		capability = "TLS self-check and network check with remembered verdicts; nothing keyed is sent after a failure",
		gate = { "auto" },
		paths = {
			{ auto = "before the first keyed request", proof = { spec = "tests/spec/drivers_spec.lua",
				test = "keeps a failed TLS verdict through Connect Event Stream and a new pairing" } },
			{ auto = "before the network-connection stream", proof = { spec = "tests/spec/netcheck_spec.lua",
				test = "pinned: the probe ids closed and cleared, the version remembered, the stream on 6001 with the key" } },
			{ action = "Check CA Pinning", dev = true },
		},
	},
	{
		id = "P8",
		capability = "Key-rejected lock, ended by a re-pair, a new address or a 200 answer",
		gate = { "click", "prop" },
		paths = {
			{ action = "Test Connection" },
			{ action = "Pair Bridge" },
			{ property = "Bridge IP Address", type = "STRING" },
			{ auto = "a REST 401/403 locks", proof = { spec = "tests/spec/drivers_spec.lua",
				test = "confirms a REST 401/403 with one GET of the bridge resource before it locks" } },
		},
	},
	{
		id = "P9",
		capability = "A one-question health check, reported in Status",
		gate = { "click" },
		paths = {
			{ action = "Test Connection" },
			{ property = "Status", type = "STRING" },
		},
	},
	{
		id = "P10",
		capability = "Event stream at start and pairing, watchdog and reconnects; transport and timeouts adjustable",
		gate = { "auto", "prop" },
		paths = {
			{ property = "Stream Timeout (s)", type = "RANGED_INTEGER" },
			{ property = "Stream Watchdog (s)", type = "RANGED_INTEGER" },
			{ property = "Event Stream Transport", type = "LIST", items = { "Network connection", "Web transfer" } },
			{ auto = "at start and pairing", proof = { spec = "tests/spec/drivers_spec.lua",
				test = "self-checks then reconnects the stream on startup when already paired, and counts events" } },
			{ auto = "the watchdog", proof = { spec = "tests/spec/netstream_spec.lua",
				test = "reconnects when the watchdog finds no data for a whole period" } },
		},
	},
	{
		id = "P11",
		capability = "Stop and restart the feed by hand",
		gate = { "click" },
		paths = {
			{ action = "Disconnect Event Stream" },
			{ action = "Connect Event Stream" },
		},
	},
	{
		id = "P12",
		capability = "Resync of everything after every connect; rows looked at again every 5 min",
		gate = { "auto" },
		paths = {
			{ auto = "every stream connect", proof = { spec = "tests/spec/motion_roundtrip_spec.lua",
				test = "resyncs the motion devices last when the stream connects again, after the zone lights" } },
			{ auto = "every 5 min", proof = { module = "src/hue_bridge/driver.lua",
				find = "state.rows_timer = C4:SetTimer(300000" } },
		},
	},
	{
		id = "P13",
		capability = "Every list read without the stream (#324)",
		gate = { "click" },
		paths = {
			{ action = "Refresh All" },
		},
	},
	{
		id = "P14",
		capability = "Scene list read now",
		gate = { "click" },
		paths = {
			{ action = "Refresh Scenes" },
		},
	},
	{
		id = "P15",
		capability = "Developer diagnostics: stored credentials, connection experiment, public CA pinning (dev builds)",
		gate = { "click" },
		paths = {
			{ action = "Reload Credentials", dev = true },
			{ action = "Connection Test", params = { "Target" }, dev = true },
			{ action = "Check CA Pinning", dev = true },
		},
	},
	{
		id = "P16",
		capability = "Event Stream row (reconnect count), Events Received, Last Event, Stream Address",
		gate = { "auto" },
		paths = {
			{ property = "Event Stream", type = "STRING" },
			{ property = "Events Received", type = "STRING" },
			{ property = "Last Event", type = "STRING" },
			{ property = "Stream Address", type = "STRING" },
			{ auto = "every reconnect", proof = { spec = "tests/spec/drivers_spec.lua",
				test = "counts reconnects on the Event Stream row" } },
			{ auto = "every event", proof = { spec = "tests/spec/drivers_spec.lua",
				test = "writes the per-event rows at most once a second, the latest value last" } },
		},
	},

	-- Rooms ----------------------------------------------------------------------
	{
		id = "R1",
		capability = "Room Mappings row, every mapping in its drop-down",
		gate = { "auto" },
		paths = {
			{ property = "Room Mappings", type = "DYNAMIC_LIST" },
			{ auto = "every resync and mapping change", proof = { spec = "tests/spec/lights_spec.lua",
				test = "room_mappings_text shows broken mappings and groups deleted in Hue" } },
		},
	},
	{
		id = "R2",
		capability = "Map one Hue room or zone to a Control4 room, or unmap it",
		gate = { "click" },
		paths = {
			{ action = "Set Room Mapping", params = { "Hue Room", "Room" } },
		},
	},
	{
		id = "R3",
		capability = "Map by exact name, never overriding; done once by itself at the first resync",
		gate = { "click", "auto" },
		paths = {
			{ action = "Map Rooms By Name" },
			{ auto = "once, at the first resync (hue_rooms_automapped)", proof = { spec = "tests/spec/lights_spec.lua",
				test = "runs Map Rooms By Name once, at the first resync that knows the rooms, guarded by a persisted flag" } },
		},
	},
	{
		id = "R4",
		capability = "Audit lights and zone lights against their mappings; nothing moved",
		gate = { "click" },
		paths = {
			{ action = "Room Audit" },
		},
	},
	{
		id = "R5",
		capability = "New devices default to \"(mapped room)\"",
		gate = { "click" },
		paths = {
			{ action = "Add Light", params = { "Light", "Room" } },
			{ action = "Add Zone Light", params = { "Group", "Room" } },
			{ action = "Add Scene", params = { "Scene", "Room" } },
			{ action = "Add Motion Sensor", params = { "Sensor", "Room" } },
			{ action = "Add Motion Area", params = { "Area", "Room" } },
			{ action = "Import All New Lights" },
			{ action = "Import All New Motion Sensors" },
		},
	},

	-- Lights ---------------------------------------------------------------------
	{
		id = "L1",
		capability = "Add one light, in a chosen or the mapped room",
		gate = { "click" },
		paths = {
			{ action = "Add Light", params = { "Light", "Room" } },
		},
	},
	{
		id = "L2",
		capability = "Import every new light whose Hue room is mapped, and list the skipped ones",
		gate = { "click" },
		paths = {
			{ action = "Import All New Lights" },
		},
	},
	{
		id = "L3",
		capability = "A device deleted in Composer is remembered: listed as deleted, skipped by imports, Add Light "
			.. "brings it back",
		gate = { "auto", "click" },
		paths = {
			{ message = "HUE_GOODBYE" },
			{ action = "Add Light", params = { "Light", "Room" } },
			{ auto = "a delete in Composer (HUE_GOODBYE)", proof = { spec = "tests/spec/lights_spec.lua",
				test = "tombstones the entry, which Import skips and Add Light re-creates" } },
		},
	},
	{
		id = "L4",
		capability = "Point a gone or unbound light device at another light, keeping its name, room and programming",
		gate = { "click" },
		paths = {
			{ action = "Re-link Device To Light", params = { "Device", "Light" } },
		},
	},
	{
		id = "L5",
		capability = "Release a light device (it stays to be deleted; the light can be added again)",
		gate = { "click" },
		paths = {
			{ action = "Forget Light", params = { "Device" } },
			{ action = "Forget This Light", driver = "hue_light" },
			{ message = "HUE_FORGET" },
			{ message = "HUE_FORGOTTEN", driver = "hue_light" },
		},
	},
	{
		id = "L6",
		capability = "Take over bound devices the bridge does not manage: by their persisted rid (automatic) or by "
			.. "name and identity (click)",
		gate = { "auto", "click" },
		paths = {
			{ action = "Link Devices" },
			{ message = "HUE_HELLO" },
			{ auto = "a hello with a rid the registry lacks", proof = { spec = "tests/spec/lights_spec.lua",
				test = "auto-adopts exactly one bound device carrying a rid the registry lacks [Q 3]" } },
		},
	},
	{
		id = "L7",
		capability = "Lights row and list; Attention names what is new, missing, unbound, conflicting or named "
			.. "differently, with the action that fixes it",
		gate = { "auto" },
		paths = {
			{ property = "Lights", type = "DYNAMIC_LIST" },
			{ property = "Attention", type = "STRING" },
			{ auto = "every resync and event", proof = { spec = "tests/spec/lights_spec.lua",
				test = "#325: the row's one wording: imported and new always, missing, unbound and deleted only" } },
			{ auto = "every resync and event", proof = { spec = "tests/spec/lights_spec.lua",
				test = "counts the differences in Attention until adopted or accepted [Q 10]" } },
		},
	},
	{
		id = "L8",
		capability = "Light control: on/off, dimming, colour, colour temperature, Online, two-way state",
		gate = { "proxy" },
		paths = {
			{ proxy = "light_v2", driver = "hue_light" },
			{ connection = "LIGHT", id = 5001, driver = "hue_light" },
			{ connection = "Hue Bridge", id = 1, driver = "hue_light" },
			{ connection = "Hue Lights", id = 1 },
			{ proxy_command = "ON", driver = "hue_light" },
			{ proxy_command = "OFF", driver = "hue_light" },
			{ proxy_command = "TOGGLE", driver = "hue_light" },
			{ proxy_command = "SET_LEVEL", driver = "hue_light" },
			{ proxy_command = "RAMP_TO_LEVEL", driver = "hue_light" },
			{ proxy_command = "SET_BRIGHTNESS_TARGET", driver = "hue_light" },
			{ proxy_command = "SET_COLOR_TARGET", driver = "hue_light" },
			{ proxy_command = "SYNCHRONIZE", driver = "hue_light" },
			{ property = "Online", type = "STRING", driver = "hue_light" },
			{ message = "HUE_CONFIGURE", driver = "hue_light" },
			{ message = "HUE_STATE", driver = "hue_light" },
			{ message = "HUE_SET" },
			{ message = "HUE_DIM" },
			{ auto = "every stream event", proof = { spec = "tests/spec/roundtrip_spec.lua", test = "runs the whole loop" } },
			{ auto = "colour and temperature from Hue", proof = { spec = "tests/spec/light_driver_spec.lua",
				test = "maps xy colour to LIGHT_COLOR_CHANGED mode 0 and a CCT to mode 1" } },
		},
	},
	{
		id = "L9",
		capability = "Keypad Button Links, holds, LEDs and keypad settings",
		gate = { "prop" },
		paths = {
			{ proxy = "light_v2", driver = "hue_light" },
			{ connection = "Top Button Link", id = 200, driver = "hue_light" },
			{ connection = "Bottom Button Link", id = 201, driver = "hue_light" },
			{ connection = "Toggle Button Link", id = 202, driver = "hue_light" },
			{ proxy_command = "DO_PUSH", binding = 200, driver = "hue_light" },
			{ proxy_command = "DO_RELEASE", binding = 200, driver = "hue_light" },
			{ proxy_command = "DO_CLICK", binding = 202, driver = "hue_light" },
			{ proxy_command = "REQUEST_BUTTON_COLORS", binding = 201, driver = "hue_light" },
			{ proxy_command = "SET_BUTTON_COLOR", driver = "hue_light" },
			{ auto = "LEDs follow the light", proof = { spec = "tests/spec/light_driver_spec.lua",
				test = "MATCH_LED_STATE follows on/off on 200, 201 and 202, with BUTTON_INFO to the proxy" } },
		},
	},
	{
		id = "L10",
		capability = "Raise Level By, Restore Saved Level (programming)",
		gate = { "prog" },
		paths = {
			{ command = "Raise Level By", params = { "Points", "Ramp (ms)" }, driver = "hue_light" },
			{ command = "Restore Saved Level", params = { "Ramp (ms)" }, driver = "hue_light" },
		},
	},

	-- Zone lights ----------------------------------------------------------------
	{
		id = "Z1",
		capability = "A Hue zone or room as one Hue Light",
		gate = { "click" },
		paths = {
			{ action = "Add Zone Light", params = { "Group", "Room" } },
		},
	},
	{
		id = "Z2",
		capability = "Point a zone light at another zone or room",
		gate = { "click" },
		paths = {
			{ action = "Re-link Zone Light", params = { "Device", "Group" } },
		},
	},
	{
		id = "Z3",
		capability = "Release a zone light",
		gate = { "click" },
		paths = {
			{ action = "Forget Light", params = { "Device" } },
			{ action = "Forget This Light", driver = "hue_light" },
		},
	},
	{
		id = "Z4",
		capability = "Zone Lights row",
		gate = { "auto" },
		paths = {
			{ property = "Zone Lights", type = "DYNAMIC_LIST" },
			{ auto = "every resync and event", proof = { spec = "tests/spec/zone_lights_spec.lua",
				test = "#325: the row's one wording: imported and new always, missing, unbound and deleted only" } },
		},
	},

	-- Names ----------------------------------------------------------------------
	{
		id = "N1",
		capability = "Rename every differing light, scene, zone light and motion device to its Hue name",
		gate = { "click" },
		paths = {
			{ action = "Adopt Hue Names" },
		},
	},
	{
		id = "N2",
		capability = "Rename one light, zone light or scene device",
		gate = { "click" },
		paths = {
			{ action = "Adopt Hue Name", driver = "hue_light" },
			{ action = "Adopt Hue Name", driver = "hue_scene" },
			{ property = "Hue Name", type = "STRING", driver = "hue_light" },
			{ property = "Hue Scene", type = "STRING", driver = "hue_scene" },
		},
	},
	{
		id = "N3",
		capability = "Keep the Composer names; Attention stays quiet until the Hue name changes again",
		gate = { "click" },
		paths = {
			{ action = "Accept Names As They Are" },
		},
	},
	{
		id = "N4",
		capability = "A Composer rename shows in Attention at once; Hue names cleaned",
		gate = { "auto" },
		paths = {
			{ property = "Attention", type = "STRING" },
			{ auto = "OnSystemEvent OnItemNameChanged", proof = { module = "src/hue_bridge/driver.lua",
				find = "data:find(\"OnItemNameChanged\", 1, true)" } },
			{ auto = "a rename in Composer", proof = { spec = "tests/spec/roundtrip_spec.lua", test = "runs the whole loop" } },
			{ auto = "Hue names cleaned", proof = { spec = "tests/spec/owner_spec.lua",
				test = "creates a device under the display name of its Hue name; the registry keeps Hue's" } },
		},
	},

	-- Scenes ---------------------------------------------------------------------
	{
		id = "S1",
		capability = "Add one scene, ordinary or time-of-day",
		gate = { "click" },
		paths = {
			{ action = "Add Scene", params = { "Scene", "Room" } },
		},
	},
	{
		id = "S2",
		capability = "Add every scene of a room or zone",
		gate = { "click" },
		paths = {
			{ action = "Add All Scenes Of Room", params = { "Hue Room" } },
		},
	},
	{
		id = "S3",
		capability = "Point a scene device at another scene",
		gate = { "click" },
		paths = {
			{ action = "Re-link Scene", params = { "Device", "Scene" } },
		},
	},
	{
		id = "S4",
		capability = "Release a scene device; its hello is refused afterwards (hue_scene_forgotten)",
		gate = { "click" },
		paths = {
			{ action = "Forget Scene", params = { "Device" } },
			{ action = "Forget This Scene", driver = "hue_scene" },
			{ message = "HUE_SCENE_FORGET" },
			{ message = "HUE_SCENE_FORGOTTEN", driver = "hue_scene" },
		},
	},
	{
		id = "S5",
		capability = "Scenes row; scene devices deleted in Composer remembered",
		gate = { "auto" },
		paths = {
			{ property = "Scenes", type = "DYNAMIC_LIST" },
			{ message = "HUE_SCENE_GOODBYE" },
			{ auto = "a delete in Composer (HUE_SCENE_GOODBYE)", proof = { spec = "tests/spec/scenes_spec.lua",
				test = "skips and lists scenes deleted in Composer; Add Scene re-creates one" } },
		},
	},
	{
		id = "S6",
		capability = "Scene device: recall, OFF, dimmer, Recall As, On State Follows, time-of-day, keypad",
		gate = { "prop" },
		paths = {
			{ property = "Recall As", type = "LIST", items = { "As set in Hue", "Static", "Dynamic" }, driver = "hue_scene" },
			{ property = "On State Follows", type = "LIST", items = { "Room/zone lights", "This scene" },
				driver = "hue_scene" },
			{ proxy = "light_v2", driver = "hue_scene" },
			{ connection = "Hue Bridge", id = 1, driver = "hue_scene" },
			{ connection = "Top Button Link", id = 200, driver = "hue_scene" },
			{ connection = "Bottom Button Link", id = 201, driver = "hue_scene" },
			{ connection = "Toggle Button Link", id = 202, driver = "hue_scene" },
			{ proxy_command = "ON", driver = "hue_scene" },
			{ proxy_command = "OFF", driver = "hue_scene" },
			{ proxy_command = "TOGGLE", driver = "hue_scene" },
			{ proxy_command = "SET_LEVEL", driver = "hue_scene" },
			{ proxy_command = "SET_BRIGHTNESS_TARGET", driver = "hue_scene" },
			{ proxy_command = "DO_CLICK", binding = 202, driver = "hue_scene" },
			{ message = "HUE_SCENE_CONFIGURE", driver = "hue_scene" },
			{ message = "HUE_SCENE_STATE", driver = "hue_scene" },
			{ message = "HUE_SCENE_GROUP", driver = "hue_scene" },
			{ message = "HUE_SCENE_RECALL" },
			{ message = "HUE_SCENE_OFF" },
			{ message = "HUE_SCENE_DIM" },
			{ message = "HUE_SCENE_LEVEL" },
		},
	},

	-- Motion ---------------------------------------------------------------------
	{
		id = "M1",
		capability = "Add one motion sensor",
		gate = { "click" },
		paths = {
			{ action = "Add Motion Sensor", params = { "Sensor", "Room" } },
		},
	},
	{
		id = "M2",
		capability = "Add every new sensor whose room is mapped; skip likely replacements, unmapped and deleted "
			.. "ones, and list them",
		gate = { "click" },
		paths = {
			{ action = "Import All New Motion Sensors" },
		},
	},
	{
		id = "M3",
		capability = "Add a MotionAware area (Bridge Pro)",
		gate = { "click" },
		paths = {
			{ action = "Add Motion Area", params = { "Area", "Room" } },
		},
	},
	{
		id = "M4",
		capability = "Point a motion device at another sensor or area (missing, unbound, or unreachable for more "
			.. "than an hour)",
		gate = { "click" },
		paths = {
			{ action = "Re-link Motion Device", params = { "Device", "Target" } },
		},
	},
	{
		id = "M5",
		capability = "Release a motion device; its hello is refused afterwards (hue_motion_forgotten)",
		gate = { "click" },
		paths = {
			{ action = "Forget Motion Device", params = { "Device" } },
			{ message = "HUE_MOTION_FORGET" },
			{ message = "HUE_MOTION_FORGOTTEN", driver = "hue_motion" },
		},
	},
	{
		id = "M6",
		capability = "Tester diagnostics: the motion resources and ten minutes of reports, redacted",
		gate = { "click" },
		paths = {
			{ action = "Log Motion Diagnostics" },
		},
	},
	{
		id = "M7",
		capability = "Ask the bridge again for one device's details and state",
		gate = { "click" },
		paths = {
			{ action = "Refresh From Bridge", driver = "hue_motion" },
			{ message = "HUE_MOTION_HELLO" },
		},
	},
	{
		id = "M8",
		capability = "Fake motion or no motion, to test programming",
		gate = { "click" },
		paths = {
			{ action = "Test Motion", driver = "hue_motion" },
			{ action = "Test No Motion", driver = "hue_motion" },
		},
	},
	{
		id = "M9",
		capability = "Motion device: contact proxy, hold time, events, conditionals, temperature output, light "
			.. "level, battery; \"not supported\" on a v2 bridge",
		gate = { "auto", "prop", "prog" },
		paths = {
			{ proxy = "contactsingle_motionsensor", driver = "hue_motion" },
			{ connection = "Motion Sensor", id = 5001, driver = "hue_motion" },
			{ connection = "Hue Bridge", id = 1, driver = "hue_motion" },
			{ connection = "Temperature", id = 2, driver = "hue_motion" },
			{ proxy_command = "GET_STATE", driver = "hue_motion" },
			{ proxy_command = "GET_SENSOR_VALUE", driver = "hue_motion" },
			{ property = "Occupancy Hold Time (s)", type = "RANGED_INTEGER", driver = "hue_motion" },
			{ property = "Hue Motion", type = "STRING", driver = "hue_motion" },
			{ property = "Light Level", type = "STRING", driver = "hue_motion" },
			{ property = "Temperature", type = "STRING", driver = "hue_motion" },
			{ property = "Battery", type = "STRING", driver = "hue_motion" },
			{ property = "Online", type = "STRING", driver = "hue_motion" },
			{ property = "Enabled", type = "STRING", driver = "hue_motion" },
			{ event = "Light Level Changed", id = 1, driver = "hue_motion" },
			{ event = "Temperature Changed", id = 2, driver = "hue_motion" },
			{ event = "Battery Low", id = 3, driver = "hue_motion" },
			{ event = "Battery Normal", id = 4, driver = "hue_motion" },
			{ event = "Offline", id = 5, driver = "hue_motion" },
			{ event = "Online", id = 6, driver = "hue_motion" },
			{ event = "Switched Off In Hue", id = 7, driver = "hue_motion" },
			{ event = "Switched On In Hue", id = 8, driver = "hue_motion" },
			{ conditional = "BOOL_ONLINE", id = 0, driver = "hue_motion" },
			{ conditional = "BOOL_ENABLED", id = 1, driver = "hue_motion" },
			{ conditional = "BOOL_BATTERY_LOW", id = 2, driver = "hue_motion" },
			{ conditional = "NUMBER_LIGHT_LEVEL", id = 3, driver = "hue_motion" },
			{ conditional = "NUMBER_TEMPERATURE_C", id = 4, driver = "hue_motion" },
			{ conditional = "NUMBER_BATTERY_LEVEL", id = 5, driver = "hue_motion" },
			{ message = "HUE_MOTION_CONFIGURE", driver = "hue_motion" },
			{ message = "HUE_MOTION_STATE", driver = "hue_motion" },
			{ auto = "battery events from Hue", proof = { spec = "tests/spec/motion_driver_spec.lua",
				test = "fires Battery Low when Hue's battery state becomes low or critical, Battery Normal when normal again" } },
			{ auto = "a v2 bridge answers MotionAware with 503", proof = { spec = "tests/spec/motion_spec.lua",
				test = "#318: a 503 on the area types (a Hue Bridge v2) means none too" } },
		},
	},
	{
		id = "M10",
		capability = "Motion Sensors row; a low battery in Attention",
		gate = { "auto" },
		paths = {
			{ property = "Motion Sensors", type = "DYNAMIC_LIST" },
			{ property = "Attention", type = "STRING" },
			{ message = "HUE_MOTION_GOODBYE" },
			{ auto = "every resync and event", proof = { spec = "tests/spec/motion_roundtrip_spec.lua",
				test = "shows the sensors and areas in the Motion Sensors row, and a low battery in Attention" } },
		},
	},

	-- Every driver ---------------------------------------------------------------
	{
		id = "G1",
		capability = "Every action's result in Last Action, wrapped onto rows (2) to (6)",
		gate = {},
		paths = {
			{ property = "Last Action", type = "STRING" },
			{ property = "Last Action (2)", type = "STRING" },
			{ property = "Last Action (3)", type = "STRING" },
			{ property = "Last Action (4)", type = "STRING" },
			{ property = "Last Action (5)", type = "STRING" },
			{ property = "Last Action (6)", type = "STRING" },
			{ property = "Last Action", type = "STRING", driver = "hue_light" },
			{ property = "Last Action", type = "STRING", driver = "hue_scene" },
			{ property = "Last Action", type = "STRING", driver = "hue_motion" },
			{ auto = "a long result", proof = { spec = "tests/spec/drivers_spec.lua",
				test = "word-wraps a long Last Action onto its continuation rows and hides them again" } },
		},
	},
	{
		id = "G2",
		capability = "Debug Mode, Driver Version and the Documentation tab (with the changelog) on every driver",
		gate = { "prop" },
		paths = {
			{ property = "Debug Mode", type = "LIST", items = { "Off", "On" } },
			{ property = "Debug Mode", type = "LIST", items = { "Off", "On" }, driver = "hue_light" },
			{ property = "Debug Mode", type = "LIST", items = { "Off", "On" }, driver = "hue_scene" },
			{ property = "Debug Mode", type = "LIST", items = { "Off", "On" }, driver = "hue_motion" },
			{ property = "Driver Version", type = "STRING" },
			{ property = "Driver Version", type = "STRING", driver = "hue_light" },
			{ property = "Driver Version", type = "STRING", driver = "hue_scene" },
			{ property = "Driver Version", type = "STRING", driver = "hue_motion" },
			{ documentation = "www/documentation.html", find = "<!-- CHANGELOG -->" },
			{ documentation = "www/documentation.html", find = "<!-- CHANGELOG -->", driver = "hue_light" },
			{ documentation = "www/documentation.html", find = "<!-- CHANGELOG -->", driver = "hue_scene" },
			{ documentation = "www/documentation.html", find = "<!-- CHANGELOG -->", driver = "hue_motion" },
		},
	},
}

-- Commands that left driver.xml but still answer, as hidden aliases in the
-- dispatch table until 2.0 (docs/simplify-research-compat.md §5.3 R2): the
-- dev loop, tools/regress.sh, older briefs and any C4:SendToDevice caller
-- send them by name. Empty today; the simplification adds one entry per
-- command it removes, for example
--   { command = "Refresh All", target = "Diagnostics", expires = "2.0" },
--   { command = "Adopt Hue Name", driver = "hue_light", target = "Resolve Names", target_driver = "hue_bridge",
--     expires = "2.0" },
-- driver (the one that still answers the old command) defaults to "hue_bridge"; target is the
-- action that does the job now, on target_driver (default: driver).
-- The spec fails once the code's version line reaches `expires`, so removing
-- an alias is a decision, not an accident.
ledger.aliases = {}

return ledger
