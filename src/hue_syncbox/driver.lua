-- Hue Sync Box driver: one Control4 device per Hue Play HDMI Sync Box, the
-- fifth driver of the package (#514; 2.0 beta stage 2, #534). The contract
-- is docs/hdmi-sync-stage2-design.md ("S2" below): §4 pairing, §5 the
-- Composer surface; docs/hdmi-sync-contracts.md ("C") C1 to C3 and C5; the
-- lifecycle cases docs/edge-cases-syncbox.md ("EC") B and C rows.
--
-- The device talks to the box itself, over the box's local HTTPS API
-- (syncbox/client.lua, pinned to the box's own root; syncbox/identity.lua
-- proves the box before its token goes anywhere), and to the Hue Bridge
-- driver only through hints (syncbox/link.lua, C5, #483). Stage 2 registers
-- (Pair Sync Box), unregisters (Forget Pairing), reads the state every few
-- seconds (syncbox/poller.lua) and shows it in the rows (syncbox/state.lua).
--
-- Stage 3 (#557, docs/hdmi-sync-stage3-design.md, "S3" below; C4; design
-- 5.2, 5.3, 5.8; docs/syncbox-wirings-research.md, "W" below) routes: the
-- AV switch's commands go to syncbox/av.lua, which turns them into writes
-- through syncbox/queue.lua (one coalescing queue, confirmed by a read,
-- retried, answered as undelivered) and into the proxy's notifies; the
-- followed room's variables go to syncbox/room.lua, whose changes drive the
-- box on a receiver's second output (syncbox/follow.lua) and set the sync
-- mode behind a receiver (syncbox/sources.lua). The box's own wiring row
-- (state.wiring: in line, behind a receiver, second output) says which path
-- is live, and a change of it at run time switches the path (W §5 W22).
-- Every command the proxies send is logged at debug with all its
-- parameters first, for the routing probes of #531 (P9 to P11).
--
-- Stage 4 (#568, docs/hdmi-sync-stage4-design.md, "S4" below, §7; C1.4 to
-- C1.9) adds programming (syncbox/programming.lua: the commands, events,
-- conditionals and variables, set from every read), the four UI Buttons
-- (SELECT on 5002 to 5005 as programming's commands; Hue Sync's and Sync
-- Intensity's icons follow the box), the periods (syncbox/periods.lua: the
-- period's intensity and brightness at every sync start and at each
-- boundary while syncing, a manual change held), the offers
-- (syncbox/offers.lua: Sync Box Settings, Input Switching on Attention),
-- the Entertainment Area (syncbox/areas.lua), the box's name both ways
-- (syncbox/names.lua) and the take-over (O12): a sync start refused with
-- code 16 has the Hue Bridge stop the area's stream (C5 STOP_AREA), unless
-- another box of this project streams there (W10), then starts again.
--
-- The box's token never leaves syncbox/store.lua and syncbox/client.lua: no
-- log line, row, Last Action or message here carries it (S2 §3.1), and the
-- raw state Diagnostics prints has every secret field redacted (R1 §2.9).
--
-- The plumbing the device drivers share comes from common/device.lua, as
-- the Hue Motion Sensor uses it: Driver Version, Debug Mode with its own end
-- after 8 hours (#493), the buffer for messages before late init, the
-- binding re-check after a Director restart, the dev build's log forwarding.
-- Its light_v2 keypad handlers are dropped (below device.new).

-- DriverWorks entry points and the CUSTOM_SELECT list of driver.xml are
-- globals Director calls by name [verified: FUND 12.3_custom_select_implementation/_1-Overview.md;
-- API 25_proxy/_5-ReceivedFromProxy.md; API 32_serial_network_device/_15-ReceivedFromNetwork.md,
-- _27-OnConnectionStatusChanged.md].
-- luacheck: globals OnDriverInit OnDriverLateInit OnDriverDestroyed OnDriverRemovedFromProject
-- luacheck: globals OnBindingChanged ReceivedFromProxy ReceivedFromNetwork OnConnectionStatusChanged SyncBoxList
-- luacheck: globals OnWatchedVariableChanged OnSystemEvent SourceList
-- luacheck: globals TestCondition GetCommandParamList SyncBoxSettingsList

local log = require("common.log")
local dispatch = require("common.dispatch")
local device = require("common.device")
local num = require("common.num")
local https = require("common.https")
local clocks = require("common.link")

-- The box's own modules (S2 §3), each built in OnDriverLateInit from what
-- the driver hands it (their new(deps)).
local mod = {
	client = require("syncbox.client"),
	store = require("syncbox.store"),
	identity = require("syncbox.identity"),
	pairing = require("syncbox.pairing"),
	state = require("syncbox.state"),
	poller = require("syncbox.poller"),
	discovery = require("syncbox.discovery"),
	link = require("syncbox.link"),
	-- Stage 3 (S3 §3, §4).
	queue = require("syncbox.queue"),
	av = require("syncbox.av"),
	room = require("syncbox.room"),
	sources = require("syncbox.sources"),
	follow = require("syncbox.follow"),
	-- Stage 4 (#568, docs/hdmi-sync-stage4-design.md, "S4" below: §3 to §5).
	programming = require("syncbox.programming"),
	periods = require("syncbox.periods"),
	offers = require("syncbox.offers"),
	areas = require("syncbox.areas"),
	names = require("syncbox.names"),
}

-- Dev builds only (#547, docs/fakebox-design.md §7): syncbox/devhooks.lua
-- lets Pair Sync Box's Address take host:port, for the VM's fake box. A
-- release build does not carry it: the address is a plain IPv4 one.
do
	local ok, hooks = pcall(require, "syncbox.devhooks")
	mod.devhooks = ok and type(hooks) == "table" and hooks or nil
end

-- Constants ----------------------------------------------------------------------

local K = {
	PREFIX = "Hue Sync Box",
	-- driver.xml: the AV switch on 5001, the four UI Buttons on 5002 to 5005,
	-- the bridge's consumer connection on 1 (C1.1, C1.2).
	PROXY_AV = 5001,
	UI_BUTTONS = { [5002] = "Hue Sync", [5003] = "Sync Brighter", [5004] = "Sync Dimmer", [5005] = "Sync Intensity" },
	BRIDGE_BINDING = device.BRIDGE_BINDING,
	-- S2 §4 step 2: the countdown in Status while the button window is open.
	TICK_MS = 10000,
	WINDOW_S = mod.pairing.WINDOW_S,
	-- An identity check that found nothing, or nothing it could trust, runs
	-- again this often (the bridge's rhythm, drivers_spec P6).
	RECHECK_MS = 30000,
	-- The box offline after 5 minutes without an answer (C2, #428); the
	-- identity checks before the reads count towards it as the reads do.
	OFFLINE_MS = mod.poller.OFFLINE_AFTER_MS,
	-- A search for boxes: at first load, on Pair Sync Box with an empty
	-- list, and every hour while no box is paired, or while the paired one is
	-- away or another device answers at its address (S2 §3.7, §4; EC B11, B12).
	SEARCH_MS = mod.discovery.HOURLY_MS,
	-- EC B5: a box that refuses the registration is asked again after 5
	-- and 15 minutes and an hour, then every hour; the token is kept.
	REFUSED_MS = { 300000, 900000, 3600000 },
	-- The Box picker's entry for a typed address.
	TYPE_ADDRESS = "address",
	-- Last Action is word-wrapped onto its continuation rows (2) to (6), as
	-- the bridge's (bridge/rows.lua): Composer's value column shows about 75
	-- characters and does not wrap.
	WRAP_ROWS = 6,
	WRAP_WIDTH = 72,
	-- The raw state in the Lua output: lines of at most this many bytes.
	RAW_LINE = 900,
	-- R1 §2.9: the state carries secret keys (the Bluetooth lights' and the
	-- bridge's); any field whose name holds one of these words, in any case,
	-- prints as REDACTED.
	SECRET_WORDS = { "key", "token", "secret", "password", "clientkey", "psk" },
	REDACTED = "<redacted>",
	-- A proxy command's parameter in the debug log: at most this many bytes.
	PARAM_MAX = 200,
	-- Short names of the models, for "Hue Sync Box (8K) #4E5F" (EC B1).
	MODEL_SHORT = { HSB2 = " (8K)", HSB3 = " (4K)" },
	-- The rows the box's state fills, cleared by Forget Pairing (S2 §4 step 4,
	-- Box Address excepted).
	BOX_ROWS = { "Sync Box", "Model", "Firmware", "Box ID", "Wiring", "Sync", "Inputs", "Bridge Link",
		"Input Switching" },
	DIAGNOSTICS = { "Check the box now", "Read everything from the box now",
		"Show the box's raw state in the Lua output" },
	-- The time (ms) the box went offline, kept across a restart.
	OFFLINE_KEY = "syncbox_offline_since",
	-- Stage 3 ------------------------------------------------------------------
	-- The last wiring a read showed, kept across a restart: the right rows
	-- show at once, and only a change from a known wiring is W22's.
	WIRING_KEY = "syncbox_wiring",
	-- The settings rows (driver.xml; contracts C1.4) and their LIST items,
	-- the default first: a value Composer did not offer reads as the default.
	SYNC_MODE_ITEMS = { "Automatic", "Video", "Game", "Music", "Do not sync" },
	ROOM_OFF_ITEMS = { "Power save", "Stop syncing and keep the picture" },
	LEAVES_ITEMS = { "Stop syncing and keep the picture", "Power save" },
	ROOM_OFF = "At Room Off",
	LEAVES = "When The Source Leaves The Box",
	FOLLOW_ROOM = "Follow Room",
	SOURCE_MODES = "Source Sync Modes",
	INPUTS = 4,
	WIRING_NAMES = { in_line = true, behind_receiver = true, second_output = true },
	-- W20: the rooms' paths are read this long after a SET_INPUT, once
	-- Director has set them [assumed: P9 measures the order].
	PATH_OFFER_MS = 2000,
	-- Stage 4 ------------------------------------------------------------------
	-- The UI Buttons' icon states (driver.xml's navigator_display_option, by
	-- the button's binding): programming.lua's icon_state to the state id,
	-- and the words the List Navigator shows in its place [verified: UIB
	-- 106_ui_button_protocol_notifications/_1-ICONCHANGED.md].
	ICONS = {
		[5002] = { button = "Hue Sync", on = "sync_on", off = "sync_off" },
		[5005] = { button = "Sync Intensity", subtle = "intensity_subtle", moderate = "intensity_moderate",
			high = "intensity_high", intense = "intensity_intense" },
	},
	ICON_WORDS = { sync_on = "Hue Sync is on", sync_off = "Hue Sync is off",
		intensity_subtle = "Sync intensity Subtle", intensity_moderate = "Sync intensity Moderate",
		intensity_high = "Sync intensity High", intensity_intense = "Sync intensity Intense" },
	-- The period rows (contracts C1.4; syncbox/periods.lua's PROPERTIES).
	PERIODS = "Periods",
	-- The take-over (O12): after the bridge's STOPPED the sync start goes
	-- again at the first read that no longer shows the bridge busy, or this
	-- long after at the latest; no STOPPED within TAKE_WAIT_MS ends it (the
	-- bridge's worst case: 3 s of grace and its 15 s request timeout).
	TAKE_RETRY_MS = 3000,
	TAKE_WAIT_MS = 20000,
	TAKE_WORDS = {
		another_box = "%s syncs to %s, and two sync boxes of this project never take a stream from each other",
		no_area = "the Hue Bridge has no entertainment area %s",
		not_linked = "the box is linked to another Hue Bridge than the one bound in Control4",
		failed = "the Hue Bridge could not stop the other app's stream",
		busy = "the Hue Bridge is busy stopping other streams",
		no_bridge = "no Hue Bridge is bound in Control4 to stop the other app's stream",
		again = "the box was still busy after the Hue Bridge stopped the other app's stream",
		no_answer = "the Hue Bridge did not answer the request to stop the other app's stream",
	},
	ENTERTAINMENT_AREA = "Entertainment Area",
	-- names.lua's check for a Composer rename whose event was missed.
	NAMES_TICK_MS = 300000,
}

-- "HDMI 1 Sync Mode" ... "HDMI 4 Sync Mode".
function K.input_mode(n)
	return string.format("HDMI %d Sync Mode", n)
end

-- The AV switch's commands syncbox/av.lua takes (C4) [verified: PP
-- 8_audio_video_switch_proxy_commands/_27-OFF.md, _28-ON.md, _46-SETINPUT.md,
-- _5-DISCONNECTOUTPUT.md, _3-CONNECTOUTPUT.md, _48-SETOUTPUTINPUT.md,
-- _34-PULSEINPUT.md, _8-GETAUDIOINPUTS.md; PP 4_amplifier_proxy_commands/
-- _2-BINDING_CHANGE_ACTION.md; SET_ROOM_BINDING_NAME and
-- IS_AV_OUTPUT_TO_INPUT_VALID from Snap One's avswitch template,
-- docs/syncbox-control4-research.md §1.3]. Volume, tone and key commands
-- have no handler (C4: ignored; the capabilities say none): the debug line
-- every command gets is all. The UI Buttons' SELECT [verified: UIB
-- 107_ui_button_proxy_commands/_1-SELECT.md] is programming's (stage 4).
local AV_COMMANDS = { "ON", "OFF", "SET_INPUT", "DISCONNECT_OUTPUT", "CONNECT_OUTPUT", "SET_OUTPUT_INPUT",
	"PULSE_INPUT", "BINDING_CHANGE_ACTION", "GET_AUDIO_INPUTS", "SET_ROOM_BINDING_NAME", "IS_AV_OUTPUT_TO_INPUT_VALID" }

-- State ---------------------------------------------------------------------------

local st = {
	late = false,        -- OnDriverLateInit ran
	destroyed = false,   -- OnDriverDestroyed ran: late callbacks change nothing
	address = nil,       -- the box address in use (Box Address); kept after Forget Pairing
	box_id = nil,        -- the paired uniqueId, upper case; nil while not paired
	paired = false,      -- a token and a box id are stored
	model = nil,         -- syncbox/state.lua's model of the last good read
	device = nil,        -- identity's device of the last passing check
	checking = false,    -- an identity check of the paired box runs
	check_gen = 0,       -- the generation of that check (follow starts a new one)
	trouble = nil,       -- { kind, since, other, status }: why nothing keyed goes out (see status_text)
	away_since = nil,    -- ms since the box stopped answering identity checks
	offline_since = nil, -- ms since the box counts as offline (Online row)
	online = nil,        -- true once it answered, false offline, nil not known
	found = {},          -- the last search's boxes { id, name, model, address }
	bridge = nil,        -- device id of the bound Hue Bridge driver, or nil
	link_match = nil,    -- the bridge's CONFIGURE: is the box linked to that bridge
	timers = {},         -- name -> C4 timer (arm / disarm)
	refused_step = 0,    -- EC B5: the asks since the refusal
	-- Stage 3
	wiring = nil,        -- the wiring that is live: "in_line" | "behind_receiver" | "second_output"
	followed = nil,      -- the room id syncbox/room.lua follows, or nil
	follow = nil,        -- room.lua's choice resolved: { room_id, name, how, status, trouble, offer }
	follow_said = nil,   -- the choice's trouble Last Action said last (W4, W24: once)
	follow_sent = nil,   -- Follow Room's list and value as last sent
	room_trouble = nil,  -- room.lua's on_trouble words (W16), until its next baseline
	path_offered = nil,  -- W20: the room last offered in Last Action
	source_offers = {},  -- W21: sources.lua's offers, for the Source list
	offers_said = {},    -- W21: "<from>><to>" said in Last Action
	-- Stage 4
	icons = {},          -- binding -> the icon state last sent (ICON_CHANGED)
	take = nil,          -- the take-over under way: { area, fields, tag, cb, phase }
	taken_over = nil,    -- its write landed: Sync Taken Over after the read's variables
	peer = nil,          -- W10: { area, by }, another box of this project streams there
	attention = nil,     -- the Attention last said in Last Action (offers, names)
	routed = false,      -- Control4 routes through the box (not on a second output)
	area_sent = nil,     -- Entertainment Area's list and value as last sent
	bridge_areas = nil,  -- the bridge's CONFIGURE areas (their rooms, for the list's order)
}

-- The settings rows as Composer last set them (dispatch.properties below).
local cfg = {}

-- The module instances (OnDriverLateInit).
local m = {}

-- Stage 3's routing, the wiring and Follow Room (below, after the rows).
local route, fr, vis = {}, {}, {}

-- Stage 4's parts (below, after the sources): programming and the buttons,
-- the take-over, the periods, the offers with the area and the name.
local prg, tko, per, ofr = {}, {}, {}, {}

-- The plumbing (common/device.lua) ---------------------------------------------------

local dev = device.new({
	prefix = K.PREFIX,
	tree = "syncbox", -- the dev loop's name for this driver's source tree
	bridge = function() return st.bridge end,
	rid = function() return st.box_id end,
	noun = "sync box",
	settings = {},
})

-- What device.new registered for light_v2 keypads (BUTTON_ACTION, DO_PUSH,
-- SET_ALL_LED and the rest) has no place on an AV switch or a UI Button:
-- the proxy table starts empty. HUE_BRIDGE_LINK is the Hue devices' message
-- (#428); the bridge sends a box CONFIGURE and AREA instead (C5).
for name in pairs(dispatch.proxy) do
	dispatch.proxy[name] = nil
end
dispatch.commands["HUE_BRIDGE_LINK"] = nil

-- The keypad LEDs follow no on state here.
function dev.is_on()
	return nil
end

local prop, after_late_init = dev.prop, dev.after_late_init
local text = device.text

-- Milliseconds since the epoch [verified: API 34_timer/_2-GetTime, 3.2.3],
-- else os.time(), as common/device.lua's.
local function now_ms()
	local ok, ms = pcall(C4.GetTime, C4)
	if ok and type(ms) == "number" then
		return ms
	end
	return os.time() * 1000
end

-- "21:04" today, "11-15 21:04" on another day (common/link.lua's rule).
local function clock(ms)
	return clocks.clock(math.floor((num.finite(ms) or 0) / 1000), math.floor(now_ms() / 1000))
end

-- Timers [verified: API 34_timer/_1-SetTimer; never in OnDriverInit]: one per
-- name, a new one replacing the old.
local function disarm(name)
	local t = st.timers[name]
	if t then
		st.timers[name] = nil
		pcall(t.Cancel, t)
	end
end

local function arm(name, ms, fn)
	disarm(name)
	local t
	t = C4:SetTimer(math.max(1, math.floor(ms)), function()
		if st.timers[name] == t then
			st.timers[name] = nil
		end
		if not st.destroyed then
			fn()
		end
	end)
	st.timers[name] = t
end

-- An outage, persisted (K.OFFLINE_KEY), so a restart in the middle of one
-- keeps its time and the poller does not report it a second time
-- (syncbox/poller.lua start's offline_since; #428 D14, as the motion
-- driver's). The first good read or passing check ends it.
local function set_offline(since_ms)
	if st.offline_since then
		return
	end
	st.offline_since, st.online = since_ms, false
	C4:PersistSetValue(K.OFFLINE_KEY, since_ms)
	log.warn("offline: %s has not answered since %s", tostring(st.address), clock(since_ms))
	prg.online(false) -- ONLINE, then the Offline event (C1.7, C1.9)
end

-- No outage any more (an answer, or Forget Pairing); true when there was one.
local function clear_offline()
	if not st.offline_since then
		return false
	end
	st.offline_since = nil
	C4:PersistDeleteValue(K.OFFLINE_KEY)
	return true
end

local function set_online()
	st.online = true
	if clear_offline() then
		log.info("online: %s answers again", tostring(st.address))
		prg.online(true) -- ONLINE, then the Online event (C1.7, C1.9)
	end
end

-- The persisted outage, when it is a time os.date takes (#487), else nil.
local function stored_offline()
	local ms = num.finite((C4:PersistGetValue(K.OFFLINE_KEY)))
	if ms and num.timestamp(ms / 1000) then
		return ms
	end
	return nil
end

-- The paired box proven at the client's address (syncbox/identity.lua: a
-- passing check with the stored id, for the current token).
local function trusted()
	return m.identity ~= nil and m.identity:ok()
end

-- Rows ----------------------------------------------------------------------------

-- A row is written when its text changes (late init starts over: Composer
-- shows driver.xml's defaults until written again).
local rows = {}

local function row(name, value)
	value = value == nil and "" or tostring(value)
	if rows[name] == value then
		return
	end
	rows[name] = value
	prop(name, value)
end

-- Last Action, word-wrapped onto "Last Action (2)" ... "(6)", the unused
-- ones hidden [verified: API 24_properties/_4-SetPropertyAttribs.md, 1 hides,
-- 0 shows; not in OnDriverInit]. Composer dropped a visibility change sent
-- in the same burst as the texts on the house (bridge/rows.lua), so it goes
-- 400 ms after them and once more at 1.5 s. A text longer than the six rows
-- is logged whole and the last row says so.
local wrap = { shown = {} }

function wrap.lines(s)
	local lines, line = {}, ""
	for word in s:gmatch("%S+") do
		while #word > K.WRAP_WIDTH do
			if line ~= "" then
				lines[#lines + 1] = line
				line = ""
			end
			lines[#lines + 1] = word:sub(1, K.WRAP_WIDTH)
			word = word:sub(K.WRAP_WIDTH + 1)
		end
		if line == "" then
			line = word
		elseif #line + 1 + #word <= K.WRAP_WIDTH then
			line = line .. " " .. word
		else
			lines[#lines + 1] = line
			line = word
		end
	end
	if line ~= "" then
		lines[#lines + 1] = line
	end
	return lines
end

function wrap.name(i)
	return i == 1 and "Last Action" or string.format("Last Action (%d)", i)
end

function wrap.assert_rows()
	if not C4.SetPropertyAttribs then
		return
	end
	for i = 2, K.WRAP_ROWS do
		pcall(C4.SetPropertyAttribs, C4, wrap.name(i), wrap.shown[i] and 0 or 1)
	end
	-- The wiring's settings rows ride on the same re-assertion (stage 3).
	vis.apply()
end

function wrap.assert_soon()
	arm("wrap", 400, function()
		wrap.assert_rows()
		arm("wrap", 1500, wrap.assert_rows)
	end)
end

function wrap.show(s)
	local lines = wrap.lines(s)
	if #lines > K.WRAP_ROWS then
		lines[K.WRAP_ROWS] = lines[K.WRAP_ROWS]:sub(1, K.WRAP_WIDTH - 16) .. " … (Lua output)"
	end
	for i = 1, K.WRAP_ROWS do
		rows[wrap.name(i)] = lines[i] or ""
		prop(wrap.name(i), lines[i] or "")
		wrap.shown[i] = lines[i] ~= nil
	end
	wrap.assert_soon()
end

-- Late init: continuation rows that still hold text from before the restart
-- stay shown, the empty ones are hidden.
function wrap.settle()
	for i = 2, K.WRAP_ROWS do
		local value = Properties and Properties[wrap.name(i)]
		wrap.shown[i] = value ~= nil and value ~= ""
	end
	wrap.assert_rows()
	wrap.assert_soon()
end

-- Every action and every outcome the owner should read ends here: Last
-- Action and the Lua output, whole (as common/device.lua's dev.result).
-- Debug Mode's own end (#493) comes through here too.
local function last_action(s)
	s = tostring(s == nil and "" or s)
	log.always("%s", s)
	wrap.show(s)
end
dev.result = last_action

-- Names -----------------------------------------------------------------------------

-- "#4E5F": "#" and the last four characters of the box id, as the manual
-- writes it (EC B1).
local function short_id(id)
	return id and ("#" .. tostring(id):sub(-4):upper()) or ""
end

-- The model code the box reports: the state's, else the identity check's.
local function model_code(d)
	if type(d) ~= "table" then
		return nil
	end
	return d.model or d.device_type
end

-- "Hue Sync Box (8K) #4E5F".
local function box_label(id, code)
	local s = "Hue Sync Box" .. (K.MODEL_SHORT[code] or "")
	if id then
		s = s .. " " .. short_id(id)
	end
	return s
end

local function paired_label()
	return box_label(st.box_id, model_code(st.model) or model_code(st.device))
end

-- Status and the box rows --------------------------------------------------------------

-- The Status row, most important first (S2 §5; EC B5, B12, B13).
local function status_text()
	if m.pairing and m.pairing:is_open() then
		local left = num.int(m.pairing:remaining_s(), 0, K.WINDOW_S, 0)
		return string.format("Hold the button on the sync box for 3 seconds (%d:%02d left)", math.floor(left / 60),
			left % 60)
	end
	if not st.paired then
		local n = #st.found
		if n == 0 then
			return "Not paired: run Pair Sync Box"
		end
		return string.format("Not paired: %d Hue sync box%s found (run Pair Sync Box)", n, n == 1 and "" or "es")
	end
	local t = st.trouble or {}
	local where = st.address or "its address"
	if t.kind == "other_device" then
		return string.format("Another device answers at %s (expected %s); Pair Sync Box to find it", where,
			short_id(st.box_id))
	elseif t.kind == "refused" then
		return string.format("The sync box refuses this pairing since %s: hold its button for 3 seconds, then run "
			.. "Pair Sync Box", clock(t.since))
	elseif st.offline_since then
		return string.format("Offline since %s (%s does not answer)", clock(st.offline_since), where)
	elseif t.kind == "not_pinned" then
		return string.format("TLS check failed at %s: nothing is sent to the box", where)
	elseif t.kind == "unreachable" then
		return string.format("Waiting for the sync box at %s (no answer since %s)", where,
			clock(st.away_since or now_ms()))
	elseif not trusted() then
		return string.format("Checking the sync box at %s before anything is sent", where)
	elseif not st.model then
		return "Waiting for the sync box"
	end
	local d = m.state.describe(st.model)
	if d.refusal then
		return d.refusal
	end
	-- Behind a receiver and on a second output, the room it follows (W1,
	-- W2, W4, W16); in line nothing more. Stage 4: an area gone in Hue,
	-- invalid or not chosen (areas.lua, design 8), and what waits for a
	-- person (ofr.attention_note).
	local words = d.sync
	for _, note in ipairs({ fr.note() or false, ofr.area_note() or false, ofr.attention_note() or false }) do
		if note then
			words = words .. "; " .. note
		end
	end
	return words
end

local function refresh_status()
	row("Status", status_text())
end

-- Online is never empty while paired (#428, as the bridge's): "Not reached
-- since <time>" from the start of the wait until the first answer, then
-- "Online", and "Offline since <time>" once the 5-minute rule fired.
local function refresh_online()
	if st.offline_since then
		row("Online", "Offline since " .. clock(st.offline_since))
	elseif st.online then
		row("Online", "Online")
	elseif not st.paired then
		row("Online", "")
	else
		row("Online", "Not reached since " .. clock(st.away_since or st.waiting_since or now_ms()))
	end
end

-- The box rows of the last good read, persisted with the box id they belong
-- to (contracts C1.9: at start the values come from persisted ones), so a
-- start while the box does not answer shows them, and Status says it waits.
-- Written only when a text changed; nothing secret is among them.
local saved = { key = "syncbox_rows", sig = nil, rows = nil }

function saved.load()
	local ok, v = pcall(C4.PersistGetValue, C4, saved.key)
	if not (ok and type(v) == "table" and type(v.rows) == "table" and v.box_id == st.box_id) then
		return nil
	end
	local out = {}
	for _, name in ipairs(K.BOX_ROWS) do
		out[name] = type(v.rows[name]) == "string" and https.peer_text(v.rows[name]) or nil
	end
	return out
end

function saved.store(texts)
	local parts = { tostring(st.box_id) }
	for _, name in ipairs(K.BOX_ROWS) do
		parts[#parts + 1] = texts[name] or ""
	end
	local sig = table.concat(parts, "\n")
	if sig ~= saved.sig then
		saved.sig = sig
		C4:PersistSetValue(saved.key, { box_id = st.box_id, rows = texts })
	end
end

function saved.forget()
	saved.sig, saved.rows = nil, nil
	C4:PersistDeleteValue(saved.key)
end

-- The rows of the paired box: from the last good read, else from the rows
-- persisted at the last good read before the start (with the identity
-- check's name, model and firmware over them when it passed), else empty.
local function refresh_box_rows()
	if not st.paired then
		for _, name in ipairs(K.BOX_ROWS) do
			row(name, "")
		end
		row("Box Address", st.address)
		return
	end
	local source = st.model or st.device or {}
	local d = m.state.describe(source)
	local texts = {}
	if st.model then
		local link_text = d.bridge_link
		if st.link_match == false then
			link_text = link_text .. " (not the Hue Bridge bound in Control4)"
		end
		-- Input Switching: the offers' row, with Attention while Control4
		-- routes through a box that switches inputs by itself (S4 §1.4).
		texts = { Wiring = d.wiring, Sync = d.sync, Inputs = d.inputs, ["Bridge Link"] = link_text,
			["Input Switching"] = ofr.switching_row(d.input_switching) }
	else
		for name, value in pairs(saved.rows or {}) do
			texts[name] = value
		end
	end
	if source.name then
		texts["Sync Box"] = https.peer_text(source.name)
	end
	if model_code(source) then
		texts["Model"] = d.model
	end
	if source.firmware or source.api_level then
		texts["Firmware"] = d.firmware
	end
	texts["Box ID"] = st.box_id
	for _, name in ipairs(K.BOX_ROWS) do
		row(name, texts[name] or "")
	end
	row("Box Address", st.address)
	if st.model then
		saved.rows = texts
		saved.store(texts)
	end
end

local function refresh()
	refresh_box_rows()
	refresh_online()
	refresh_status()
end

-- Stage 3's modules are called through this: a method the module has, its
-- result; else nil (a module built without one, or not built yet).
local function call(module, method, ...)
	if module and type(module[method]) == "function" then
		return module[method](module, ...)
	end
	return nil
end

-- The settings rows (stage 3) ------------------------------------------------------------
-- The LIST rows av.lua and follow.lua read by name (S3 §3; contracts C1.4):
-- the value Composer set, else the row's default (a value no item matches,
-- or none yet). Composer calls OnPropertyChanged on a Set [verified: API
-- 24_properties/_3-OnPropertyChanged.md]; late init replays every row.

local LISTS = { [K.ROOM_OFF] = K.ROOM_OFF_ITEMS, [K.LEAVES] = K.LEAVES_ITEMS }
for n = 1, K.INPUTS do
	LISTS[K.input_mode(n)] = K.SYNC_MODE_ITEMS
end

function route.setting(name)
	local items, value = LISTS[name], cfg[name]
	if not items then
		return value
	end
	for _, item in ipairs(items) do
		if item == value then
			return value
		end
	end
	return items[1]
end

for name in pairs(LISTS) do
	dispatch.properties[(name:gsub("%s+", "_"))] = function(value)
		local before = route.setting(name)
		cfg[name] = text(value)
		if st.late and route.setting(name) ~= before then
			log.info("%s: %s", name, route.setting(name))
		end
	end
end

-- Which rows the wiring shows (S3 §5; W §7.2) ------------------------------------------
-- In line the HDMI n Sync Mode rows (as many as the box has inputs: one on
-- an HSB3, contracts C1.4); behind a receiver and on a second output Follow
-- Room and Source Sync Modes. At Room Off and When The Source Leaves The Box
-- apply in every wiring and are never hidden. Hidden with
-- C4:SetPropertyAttribs(name, 1), shown with 0 [verified: API
-- 24_properties/_4-SetPropertyAttribs.md: not in OnDriverInit], at once and
-- again with the Last Action rows' re-assertion (wrap.assert_soon), since
-- Composer dropped a visibility change sent in a burst of texts.

vis.MANAGED = { K.input_mode(1), K.input_mode(2), K.input_mode(3), K.input_mode(4), K.FOLLOW_ROOM, K.SOURCE_MODES }
vis.shown = nil -- name -> true for the shown ones, as last applied

function vis.wanted()
	local wiring, shown = route.wiring(), {}
	if wiring == "in_line" then
		local inputs = st.model and type(st.model.inputs) == "table" and #st.model.inputs or 0
		for n = 1, (inputs > 0 and math.min(inputs, K.INPUTS) or K.INPUTS) do
			shown[K.input_mode(n)] = true
		end
	else
		shown[K.FOLLOW_ROOM], shown[K.SOURCE_MODES] = true, true
	end
	return shown
end

function vis.apply()
	if not (vis.shown and C4.SetPropertyAttribs) then
		return
	end
	for _, name in ipairs(vis.MANAGED) do
		pcall(C4.SetPropertyAttribs, C4, name, vis.shown[name] and 0 or 1)
	end
end

-- Applied when the set changed (or `force`, at late init).
function vis.update(force)
	local want = vis.wanted()
	local same = vis.shown ~= nil
	for _, name in ipairs(vis.MANAGED) do
		same = same and (vis.shown[name] == want[name])
	end
	if same and not force then
		return
	end
	vis.shown = want
	vis.apply()
	wrap.assert_soon()
end

-- Follow Room (W §5, §7.2; S3 §2) -------------------------------------------------------
-- syncbox/room.lua's choice keeps the pick (a room id with the name it had,
-- never a name alone; this device's room by default, #536) and resolves it
-- per the lifecycle cases W1 to W7 and W24; its watcher follows the room.
-- This part shows the drop-down [verified: FUND 15_composerpro_interface_into_the_sdk/
-- _2-DYNAMICLISTPROPERTIES.md: the items are not persisted, the driver
-- rebuilds them, and a pick arrives in OnPropertyChanged; API
-- 24_properties/_6-UpdatePropertyList.md], follows the room the choice names
-- while the wiring needs one (behind a receiver and on a second output, S3
-- §1) and says which in Status.

-- This device's room [verified: API 22_miscellaneous/_33-RoomGetId.md, not
-- in OnDriverInit].
function fr.own_room()
	local ok, id = pcall(C4.RoomGetId, C4)
	return ok and num.int(id, 1) or nil
end

-- The drop-down and its value (as the bridge's rows: the list, then the
-- row, since the list's value alone did not move the row after a pick).
-- Sent only when it changed.
function fr.list()
	if not (st.late and m.choice) then
		return
	end
	local ok, items, value = pcall(m.choice.items, m.choice)
	if not ok or type(items) ~= "table" then
		return log.warn("Follow Room: the list could not be built: %s", tostring(items))
	end
	local joined = table.concat(items, ",")
	value = tostring(value or "")
	if joined .. "\n" .. value == st.follow_sent then
		return
	end
	st.follow_sent = joined .. "\n" .. value
	pcall(C4.UpdatePropertyList, C4, K.FOLLOW_ROOM, joined, value)
	rows[K.FOLLOW_ROOM] = value
	prop(K.FOLLOW_ROOM, value)
end

-- Follow the room the choice names now when the wiring needs one and a box
-- is paired; stop following otherwise. What the choice says (moved, gone,
-- renamed at start) goes to Status, and once to Last Action. A room that
-- cannot be followed (W16) is room.lua's to retry, every hour. `catch_up`:
-- the room's first state is applied once (a pick, W22), not a baseline.
function fr.apply(catch_up)
	if not (m.room and m.choice) then
		return
	end
	if not (st.paired and route.wiring() ~= "in_line") then
		st.follow, st.room_trouble = nil, nil
		if st.followed then
			st.followed = nil
			call(m.follow, "set_room", nil)
			m.room:stop()
		end
		return
	end
	local ok, r = pcall(m.choice.resolve, m.choice)
	if not ok or type(r) ~= "table" then
		return log.warn("Follow Room: the choice could not be resolved: %s", tostring(r))
	end
	st.follow = r
	if r.last_action then
		last_action(r.last_action)
	end
	if (r.how == "gone" or r.how == "mismatch") and r.trouble ~= st.follow_said then
		st.follow_said = r.trouble
		last_action(r.trouble .. (r.offer and ("; " .. r.offer.text) or ""))
	end
	local wanted = r.room_id
	if wanted == st.followed and not catch_up then
		return
	end
	st.followed, st.room_trouble = wanted, nil
	-- follow.lua's next baseline is a baseline, or (a dealer's pick, a change
	-- to the second output: W22) applied once.
	call(m.follow, "set_room", wanted, r.name, catch_up and { catch_up = true } or nil)
	if not wanted then
		m.room:stop()
		return
	end
	local followed, why = m.room:follow(wanted, r.name)
	log.info("following room %s (%s)%s", tostring(wanted), tostring(r.name),
		followed and "" or (": " .. tostring(why)))
end

-- room.lua's on_trouble (W16): Status says so until the room answers.
function fr.trouble(words)
	st.room_trouble = type(words) == "string" and words or "the followed room does not answer"
	refresh_status()
end

-- What Status adds behind a receiver and on a second output (W1, W2, W4,
-- W6, W16, W24); nothing in line.
function fr.note()
	if route.wiring() == "in_line" or not st.paired then
		return nil
	end
	local r = st.follow or {}
	local words = st.room_trouble or r.trouble
	if not words and st.followed then
		local ok, said = pcall(call, m.follow, "status")
		words = ok and type(said) == "string" and said or nil
	end
	words = words or r.status
	if not words then
		return nil
	end
	if r.how == "none" and not st.room_trouble and route.wiring() ~= "second_output" then
		words = words .. ": every source syncs as video"
	elseif r.how == "none" and not words:find("own settings", 1, true) then
		words = words .. ": the box runs on its own settings"
	end
	return words:sub(1, 1):lower() .. words:sub(2)
end

-- A pick in the drop-down (OnPropertyChanged). Late init's replay of the
-- row changes nothing: the stored choice holds.
dispatch.properties["Follow_Room"] = function(value)
	if not (st.late and m.choice) then
		return
	end
	value = text(value) or ""
	if value == rows[K.FOLLOW_ROOM] then
		return
	end
	local ok, why = m.choice:choose(value)
	st.follow_sent, st.follow_said = nil, nil
	fr.list()
	if not ok then
		return last_action(string.format("Follow Room: %s is %s; pick again", https.peer_text(value, 64),
			tostring(why or "not in the list any more")))
	end
	fr.apply(true)
	refresh_status()
	local r = st.follow or {}
	last_action(r.status or ("Follow Room: " .. value .. " (used behind a receiver and on a receiver's second "
		.. "output)"))
end

-- On every read behind a receiver and on a second output: this device moved
-- (W6), the followed room deleted (W4) or renamed (W3); the list follows.
-- In line the row is hidden and no room is followed: nothing to look at.
function fr.check()
	if route.wiring() == "in_line" then
		return
	end
	fr.apply()
	fr.list()
end

-- The wiring and the routes (S3 §1, §5; C4; W §7.2) -------------------------------------

-- The wiring that is live: the last read's, else the persisted one, else
-- in line (the box's default, and the rows a new device shows).
function route.wiring()
	return st.wiring or "in_line"
end

-- The box's model now (av.lua's state_now).
function route.model()
	return st.model
end

-- The AV switch's notifies, logged at debug (common/device.lua's notify).
function route.notify(command, params)
	dev.notify(command, params)
end

-- The queue's outcome of a write queued without a callback of its own
-- (queue.lua's on_done(tag, ok, model, why, detail)): follow.lua's tags are
-- its own (follow.owns); av.lua gives every write its own callback. A write
-- a later one replaced, or one a wiring change or Forget Pairing dropped,
-- did not fail: follow.lua hears only what landed or failed, so neither is
-- applied again at the next contact (W23) nor read as "no sound" (W18).
local ENDED_QUIETLY = { superseded = true, cancelled = true }

function route.on_done(tag, ok, model, why)
	if st.destroyed then
		return
	end
	if ok ~= true and ENDED_QUIETLY[why] then
		log.debug("a write ended: %s", tostring(why))
	elseif mod.follow.owns(tag) then
		call(m.follow, "done", tag, ok, model, why)
	else
		log.debug("a write ended (%s): %s", tostring(ok), tostring(why))
	end
	refresh_status()
end

-- Follow Room's wiring: on a second output it drives the box; behind a
-- receiver av.lua takes the room's changes (S3 §3: the mode from the
-- room's source, a Listen selection), so follow.lua only keeps the room's
-- state there, as in line; nil before any wiring is known.
function route.follow_wiring()
	if st.wiring == "second_output" then
		return "second_output"
	end
	return st.wiring and "in_line" or nil
end

-- Every good read: a new wiring switches the path first, then av.lua hands
-- the read to the queue (q:observe, once per read), whose writes the read
-- shows end, and the proxy hears what they confirm.
function route.on_read(model)
	if model.wiring and model.wiring ~= st.wiring then
		route.set_wiring(model.wiring)
	end
	call(m.av, "confirm", model)
	fr.check()
	call(m.follow, "wiring_changed", st.wiring)
	vis.update()
end

-- W22: the box's wiring changed (soloMode or arcBypassMode, set in the Hue
-- Sync app). The writes the old path queued and not sent are dropped
-- (their callbacks hear "cancelled" and say nothing), the room is followed
-- or no more, and on a change to the second output follow.lua applies the
-- room's state once, said in Last Action: at once when the room was
-- followed already (f:wiring_changed), else with the new room's first
-- state. A first read after an install, with no wiring known before, is no
-- change.
function route.set_wiring(wiring)
	local from = st.wiring
	st.wiring = wiring
	C4:PersistSetValue(K.WIRING_KEY, wiring)
	if from then
		tko.cancel(nil, "cancelled")
		call(m.queue, "clear")
		call(m.av, "reset")
		local words = { in_line = "Control4 routes through the box and each input sets its sync mode",
			behind_receiver = "Control4 routes through the box and the followed room's source sets the sync mode",
			second_output = "the followed room's power and source drive the box" }
		last_action(string.format("The box's wiring changed to %s: %s", m.state.describe({ wiring = wiring }).wiring,
			words[wiring] or "nothing routes through it"))
	end
	fr.apply(from ~= nil and wiring == "second_output" and not st.followed)
	vis.update()
	ofr.check_routed()
	refresh_status()
end

-- The followed room (syncbox/room.lua): its first state after following
-- starts is a baseline, never a command (W15; C1.9); later changes act. On
-- a second output follow.lua decides; behind a receiver av.lua takes a new
-- source for the box on the path; in line nothing (I15, W20 later).
function route.room_baseline(state)
	if st.destroyed then
		return
	end
	st.room_trouble = nil -- the room answers (W16 over)
	route.saw(state)
	call(m.follow, "baseline", state)
	route.sources_row()
	refresh_status()
end

function route.room_change(state, prev)
	if st.destroyed then
		return
	end
	route.saw(state)
	-- S4 §1.3: the room's new source ends a manual hold before the writes
	-- it brings take the period's settings.
	per.source_changed(state, prev)
	call(m.follow, "changed", state, prev)
	if route.wiring() == "behind_receiver" then
		call(m.av, "room_changed", state, prev)
	end
	route.sources_row()
	refresh_status()
end

-- The AV switch's proxy (5001): av.lua decides, by the wiring. A binding
-- change may change what is upstream of the box (follow.lua caches it).
function route.received(command, params)
	if not m.av then
		return
	end
	m.av:received(command, params or {})
	if command == "BINDING_CHANGE_ACTION" then
		call(m.follow, "refresh")
		route.sources_row()
	elseif (command == "SET_INPUT" or command == "SET_OUTPUT_INPUT") and route.wiring() == "behind_receiver" then
		-- W20: once Director has set the rooms' paths.
		arm("path_offer", K.PATH_OFFER_MS, route.path_offer)
	end
	refresh_status()
end

-- W20 (offered, never set by itself): behind a receiver, Director routes
-- through the box but the followed room's picture path does not name it,
-- while exactly one other room's does (a box placed in a rack room). That
-- room is offered in Last Action, once per room; picking it in Follow Room
-- is the click. In line Follow Room is not used in stage 3 (S3 §5: the row
-- is hidden there), so nothing is offered. room.lua reads each room's
-- CURRENT_VIDEO_PATH (1008) with C4:GetDeviceVariable [verified: API
-- 36_variable/_5-GetDeviceVariable.md]; that the path names the box's own
-- ids is [assumed: probe P9].
function route.path_offer()
	if route.wiring() ~= "behind_receiver" or not st.paired then
		return
	end
	local ids = { [C4:GetDeviceID()] = true }
	for _, id in ipairs({ route.proxy_id() }) do
		ids[id] = true
	end
	local ok, offer = pcall(mod.room.path_offer, {
		box_ids = ids,
		rooms = C4:GetDevicesByC4iName("roomdevice.c4i"),
		followed = st.followed,
	})
	if not ok then
		return log.warn("the rooms' paths could not be read: %s", tostring(offer))
	end
	if type(offer) == "table" and offer.text and offer.id ~= st.path_offered then
		st.path_offered = offer.id
		last_action(offer.text)
	end
end

-- Forget Pairing: nothing waits for the forgotten box, no room is followed,
-- and the next box's first read is no wiring change (W22).
function route.forget()
	tko.cancel(nil, "cancelled")
	call(m.queue, "clear")
	call(m.av, "reset")
	st.wiring = nil
	C4:PersistDeleteValue(K.WIRING_KEY)
	fr.apply()
	vis.update()
end

-- The sources (S3 §4; W §7.2) ---------------------------------------------------------
-- The AV switch proxy's id: the consumer on binding 5001 (common/device.lua).
function route.proxy_id()
	local ok, id = pcall(dev.proxy_id)
	return ok and id or nil
end

-- Source Sync Modes (read-only): each source's mode, as sources.lua words
-- it, for the sources upstream of the box, those seen in the followed room
-- and those with a mode of their own.
function route.sources_row()
	if not m.sources then
		return
	end
	local ok, value = pcall(m.sources.summary, m.sources, route.proxy_id())
	if not ok then
		return log.warn("Source Sync Modes could not be built: %s", tostring(value))
	end
	row(K.SOURCE_MODES, type(value) == "string" and value or "")
	route.source_offers()
end

-- W21 (offered): a source with a mode of its own was deleted or replaced in
-- Composer, and exactly one present source has its name. Last Action says
-- so once per pair; the Source list of Set Source Sync Mode carries the
-- offer, so one click moves the mode. Never applied by itself.
function route.source_offers()
	local ok, offers = pcall(m.sources.offers, m.sources, route.proxy_id())
	st.source_offers = ok and type(offers) == "table" and offers or {}
	for _, offer in ipairs(st.source_offers) do
		local key = tostring(offer.from_id) .. ">" .. tostring(offer.to_id)
		if not st.offers_said[key] then
			st.offers_said[key] = true
			last_action(tostring(offer.text))
		end
	end
end

-- A source the followed room selected is one the action offers (W §7.2).
function route.saw(state)
	if type(state) == "table" and (state.kind == "watch" or state.kind == "listen") then
		call(m.sources, "saw", state.selected)
	end
end

-- The bridge (C5, through syncbox/link.lua) ----------------------------------------------

-- What syncbox/link.lua sends with: C4:SendToDevice to the device bound on
-- binding 1, logged by Director only in Debug Mode (#493 D-8,
-- common/device.lua's dev.send_to); false when nothing is bound. A raise
-- is the link's to log.
local function send_to_bridge(binding_id, command, params)
	if binding_id ~= K.BRIDGE_BINDING or not st.bridge then
		return false
	end
	dev.send_to(st.bridge, command, params)
	return true
end

-- The ids the hello carries: the paired box, and its bridge and area from
-- the last good read.
local function link_ids()
	local model = st.model or {}
	local bridge_id = type(model.bridge) == "table" and model.bridge.id or nil
	return st.box_id, bridge_id, model.area, model.syncing
end

-- HELLO at late init, on binding and after pairing (C5); after a read, only
-- when the box's bridge or area changed (link:update), else STATE when its
-- sync state changed or the bridge's AREA asked for it (S4 §6: the bridge
-- knows which bound box streams, W10).
local function hello(force)
	if not (m.link and st.bridge and st.box_id) then
		return
	end
	if force then
		m.link:hello(link_ids())
	else
		m.link:update(link_ids())
	end
end

-- Searching ------------------------------------------------------------------------

local follow -- below: the paired box found at another address

-- One search (syncbox/discovery.lua), whose list feeds the Box picker and,
-- when the paired box answers at another address while it is away, the
-- follow-up (EC B11). `done(list)` is optional.
local function search(why, done)
	if not m.discovery then
		return false
	end
	log.debug("searching for Hue sync boxes (%s)", why)
	m.discovery:search(function(list)
		if st.destroyed then
			return
		end
		st.found = type(list) == "table" and list or {}
		if st.paired and st.box_id and (st.trouble or st.offline_since or not trusted()) then
			for _, item in ipairs(st.found) do
				if item.id == st.box_id and item.address and item.address ~= st.address then
					follow(item.address)
					break
				end
			end
		end
		refresh_status()
		if done then
			done(st.found)
		end
	end, st.paired and st.box_id or nil)
	return true
end

-- Every hour: while no box is paired, while the paired box is away, or
-- while another device answers at its address (S2 §3.7; EC B11, B12).
local function arm_search()
	arm("search", K.SEARCH_MS, function()
		if not st.paired or st.trouble or st.offline_since then
			search("hourly")
		end
		arm_search()
	end)
end

-- The identity check and polling -----------------------------------------------------

local start_checks -- below

-- The poller started, told of an outage the driver already reports, so the
-- first good read ends it (syncbox/poller.lua, start's offline_since).
local function start_polling()
	m.poller:start({ offline_since = st.offline_since })
end

-- What an identity check that failed means for the paired box (S2 §4 step 5;
-- EC B12, B13): another device (or no sync box) at the address gets no
-- token; the search looks for the box, and the address is checked again
-- every hour. Anything else is tried again every RECHECK_MS and counts
-- towards offline.
local function identity_failed(result)
	local reason = result.reason
	m.poller:stop()
	if reason == "wrong_box" or reason == "not_a_box" or reason == "camera" then
		local other = type(result.device) == "table" and result.device.id or nil
		if not (st.trouble and st.trouble.kind == "other_device") then
			st.trouble = { kind = "other_device", since = now_ms(), other = other }
			log.warn("another device answers at %s (%s, expected %s): the token is not sent there",
				tostring(st.address), other and short_id(other) or reason, short_id(st.box_id))
		end
		search("another device at the address")
		arm("recheck", K.SEARCH_MS, start_checks)
		return
	end
	local now = now_ms()
	if reason == "unreachable" then
		st.away_since = st.away_since or now
		st.trouble = { kind = "unreachable", since = st.away_since }
		if now - st.away_since >= K.OFFLINE_MS and not st.offline_since then
			set_offline(st.away_since)
			search("the box does not answer")
		end
	else
		st.trouble = { kind = reason or "inconclusive", since = now }
	end
	arm("recheck", K.RECHECK_MS, start_checks)
end

-- The box answered over the pinned chain with its id: online, and the reads
-- start, unless it refuses the token (EC B5: its own asks restart them).
local function identity_passed(result)
	st.device = type(result.device) == "table" and result.device or st.device
	st.away_since = nil
	set_online()
	if st.trouble and st.trouble.kind ~= "refused" then
		st.trouble = nil
	end
	if not st.trouble then
		start_polling()
	end
end

-- The identity check at the stored address with the stored id, then
-- polling (S2 §4 step 5). Nothing keyed goes out before it passed.
function start_checks()
	disarm("recheck")
	if not (st.paired and st.address and m.identity) or st.checking then
		return
	end
	st.check_gen = st.check_gen + 1
	local gen, address = st.check_gen, st.address
	st.checking = true
	m.identity:check(address, st.box_id, function(result)
		if gen ~= st.check_gen then
			return -- an address followed meanwhile (follow): a newer check runs
		end
		st.checking = false
		if st.destroyed or address ~= st.address or not st.paired then
			return
		end
		result = type(result) == "table" and result or { ok = false, reason = "inconclusive" }
		if result.ok then
			log.debug("identity of %s at %s confirmed", short_id(st.box_id), address)
			identity_passed(result)
		else
			identity_failed(result)
		end
		refresh()
	end)
	refresh_status()
end

-- EC B11: the paired box answered the search at another address; the
-- identity check there proves it before anything keyed goes out (R5 §3.4).
function follow(address)
	local before = st.address
	log.info("%s answers at %s (was %s): following it", short_id(st.box_id), address, tostring(before))
	m.poller:stop()
	m.store:save({ address = address })
	st.address, st.trouble, st.checking = address, nil, false
	st.check_gen = st.check_gen + 1 -- the check at the old address, if one runs, no longer counts
	m.client:set_address(address)
	m.identity:reset()
	start_checks()
	last_action(string.format("%s moved to %s; address updated", paired_label(), address))
end

-- Stage 4: programming and the UI Buttons (S4 §3, §7; C1.6 to C1.9) ------------------------
-- syncbox/programming.lua owns the commands, the variables, their events
-- and the conditionals; the driver hands it every read and every press.

-- Made in OnDriverInit, where its nine variables are added (C1.9); the parts
-- late init builds (the take-over's view of the queue, the periods, the
-- areas) are handed over as functions. PersistData without the encrypted
-- flag (#547).
function prg.build()
	m.programming = mod.programming.new({
		queue = function() return m.tq end,
		model_now = route.model,
		periods = function() return m.periods end,
		period = per.settings,
		areas = ofr.programming_areas,
		last_action = last_action,
		changed = function() prg.icons() end,
		log = log,
		persist_get = function(name) return C4:PersistGetValue(name) end,
		persist_set = function(name, value) return C4:PersistSetValue(name, value) end,
	})
	m.programming:init()
end

-- ONLINE and the Online and Offline events (C1.7, C1.9): the box answers
-- again, or the 5-minute rule fired.
function prg.online(flag)
	if not st.late then
		return
	end
	local ok, err = pcall(call, m.programming, "online", flag)
	if not ok then
		log.error("programming: ONLINE failed: %s", tostring(err))
	end
end

-- The UI Buttons' icons (S4 §1.2): Hue Sync on or off, Sync Intensity the
-- intensity now, from programming's variables (persisted, so a start shows
-- the last state before the box answers). ICON_CHANGED to the button's
-- binding with a state of driver.xml's navigator_display_option [verified:
-- UIB 106_ui_button_protocol_notifications/_1-ICONCHANGED.md; API
-- 25_proxy/_6-SendToProxy.md: not in OnDriverInit, a NOTIFY for a binding of
-- 1000 or more]; sent when it changes, and at every late init (`force`).
function prg.icons(force)
	if not (st.late and m.programming) then
		return
	end
	for binding, spec in pairs(K.ICONS) do
		local state = call(m.programming, "icon_state", spec.button)
		local id = state and spec[state]
		if id and (force or st.icons[binding] ~= id) then
			st.icons[binding] = id
			log.debug("-> %s ICON_CHANGED %s", spec.button, id)
			C4:SendToProxy(binding, "ICON_CHANGED", { icon = id, icon_description = K.ICON_WORDS[id] })
		end
	end
end

-- A press on 5002 to 5005 (C1.1; design 5.6): programming's button, whose
-- outcome Last Action says once the queue answers.
function prg.select(binding)
	local name = K.UI_BUTTONS[binding]
	if not (name and m.programming) then
		return
	end
	log.info("%s pressed", name)
	local ok, why = m.programming:button(name)
	if not ok then
		log.debug("%s: %s", name, tostring(why))
	end
end

-- Every good read (poll.on_state, after the routing): the variables, then
-- their events (C1.9: set before the event); Sync Taken Over once the
-- take-over's write landed; the icons, the offers, the area and the name.
function prg.on_read(model, before)
	call(m.programming, "observe", model, before, "read")
	local taken = st.taken_over
	st.taken_over = nil
	if taken then
		call(m.programming, "observe", model, nil, "takeover")
	end
	prg.icons()
	tko.on_read(model)
	per.row()
	ofr.on_read(model, before)
end

-- Programming's commands (C1.6), sent by Director by name; one that comes
-- before late init waits for it, in order (common/device.lua).
for _, name in ipairs(mod.programming.COMMANDS) do
	local handler = after_late_init(name, function(params)
		m.programming:command(name, params)
	end)
	dispatch.commands[(name:gsub("%s+", "_"))] = function(params)
		handler(type(params) == "table" and params or {})
	end
end

-- The conditionals (C1.8) [verified: FUND 10_conditionals/
-- _4-USINGTHETESTCONDITIONFUNCTION.md: a boolean, from the <name>].
function TestCondition(name, params)
	if not m.programming then
		return false
	end
	local ok, result = pcall(m.programming.test, m.programming, name, params)
	if not ok then
		log.error("TestCondition %s failed: %s", tostring(name), tostring(result))
		return false
	end
	return result == true
end

-- The DYNAMIC_LIST parameters of the commands (Set Entertainment Area's
-- and Apply Sync Settings' Area) [verified: FUND 9_commands/_1-COMMANDS.md,
-- GetCommandParamList, OS 3.3.0].
function GetCommandParamList(commandName, paramName)
	if not m.programming then
		return {}
	end
	local ok, list = pcall(m.programming.param_list, m.programming, commandName, paramName)
	if not ok or type(list) ~= "table" then
		log.warn("GetCommandParamList %s/%s: %s", tostring(commandName), tostring(paramName), tostring(list))
		return {}
	end
	return list
end

-- The take-over (S4 §1.6; O12; design 7.3; C5 STOP_AREA) -----------------------------------
-- Every writer's q:set goes through here. A write that starts a sync and
-- ends busy (code 16: another app streams to the box's area, SB91) is held
-- while the Hue Bridge is asked to stop that stream (link:stop_area); once
-- it answers that it did, the same write goes again, at the first read that
-- no longer shows the box busy or TAKE_RETRY_MS later, and when it lands
-- Sync Taken Over fires (after the read's variables) and Last Action says
-- whose sync it replaced. The bridge refuses when another box of this
-- project streams there (W10): Last Action names that box, nothing is
-- taken, and Follow Room sends no sync start while it does
-- (tko.peer_syncing). One take-over at a time; a newer write ends it (the
-- box does what was asked last); a retry that is busy again ends it. The
-- writer hears its write's outcome once: ok when the take-over landed it,
-- "cancelled" when Last Action already said why not (its own words would
-- only repeat "busy"), "busy" when no bridge could be asked.

local function starts_sync(fields)
	return fields.syncActive == true or fields.mode == "video" or fields.mode == "game" or fields.mode == "music"
end

-- The queue as every writer sees it: q:set through tko.set, the rest the
-- queue's own.
function tko.wrap(q)
	return setmetatable({
		set = function(_, fields, tag, cb)
			return tko.set(q, fields, tag, cb)
		end,
	}, {
		__index = function(_, key)
			local v = q[key]
			if type(v) == "function" then
				return function(_, ...)
					return v(q, ...)
				end
			end
			return v
		end,
	})
end

function tko.set(q, fields, tag, cb)
	if st.take and st.take.phase ~= "retrying" then
		tko.cancel(st.take, "superseded")
	end
	if type(fields) == "table" then
		fields = per.fill(fields, tag)
	end
	local original = cb or q.on_done
	return q:set(fields, tag, function(t, ok, model, why, detail)
		if ok ~= true and why == "busy" and type(fields) == "table" and starts_sync(fields) then
			return tko.busy(fields, t, original, model, detail)
		end
		if type(original) == "function" then
			return original(t, ok, model, why, detail)
		end
	end)
end

-- A writer's callback, once (a retry that lands after the take-over was
-- ended answers nobody), under pcall.
local function answer(t, ok, model, why, detail)
	local cb = t.cb
	t.cb = nil
	if type(cb) == "function" then
		local fine, err = pcall(cb, t.tag, ok, model, why, detail)
		if not fine then
			log.warn("take-over: a writer's callback failed: %s", tostring(err))
		end
	end
end

-- The area a write syncs to: its own hueTarget, else the box's.
local function area_label(id)
	for _, a in ipairs(st.model and type(st.model.areas) == "table" and st.model.areas or {}) do
		if a.id == id and a.name then
			return https.peer_text(a.name, 64)
		end
	end
	return "the box's entertainment area"
end

function tko.busy(fields, tag, cb, model, detail)
	local t = { fields = fields, tag = tag, cb = cb }
	model = model or st.model or {}
	t.area = fields.hueTarget or model.area
	if st.take and st.take.area == t.area and st.take.phase ~= "retrying" then
		-- A second sync start busy on the same area while the bridge is asked:
		-- the later one is what the box is to do.
		answer(st.take, false, model, "superseded")
		st.take.fields, st.take.tag, st.take.cb = fields, tag, cb
		return
	end
	local _, bridge_id = link_ids()
	if not (t.area and st.bridge and m.link and m.link:stop_area(t.area, st.box_id, bridge_id)) then
		log.info("take-over: %s", K.TAKE_WORDS.no_bridge)
		return answer(t, false, model, "busy", detail)
	end
	tko.cancel(st.take, "superseded")
	t.phase = "asking"
	st.take = t
	log.info("take-over: the box is busy; the Hue Bridge is asked to stop the stream on %s (O12)", area_label(t.area))
	arm("take", K.TAKE_WAIT_MS, function()
		tko.finish(t, K.TAKE_WORDS.no_answer)
	end)
end

-- The take-over ends without a sync: Last Action says why (`words`), the
-- writer hears "cancelled".
function tko.finish(t, words)
	if st.take ~= t then
		return
	end
	st.take = nil
	disarm("take")
	last_action("Not syncing: " .. words)
	answer(t, false, st.model, "cancelled")
end

-- A newer write, a wiring change or Forget Pairing: the writer hears `why`.
function tko.cancel(t, why)
	t = t or st.take
	if not t or st.take ~= t then
		return
	end
	st.take = nil
	disarm("take")
	log.debug("take-over ended: %s", tostring(why))
	answer(t, false, st.model, why or "cancelled")
end

-- The bridge's STOPPED (link.lua's { area_id, ok, reason, by, detail }).
function tko.stopped(msg)
	local t = st.take
	if not (t and t.phase == "asking" and msg.area_id == t.area) then
		return log.debug("STOPPED for %s: no take-over asked it", tostring(msg.area_id))
	end
	if msg.ok then
		t.phase = "waiting"
		log.info("take-over: the Hue Bridge stopped the stream on %s", area_label(t.area))
		arm("take", K.TAKE_RETRY_MS, tko.retry)
		if trusted() and not st.trouble then
			m.poller:soon("take-over")
		end
		return
	end
	local words
	if msg.reason == "another_box" then
		st.peer = { area = t.area, by = msg.by or "another sync box" }
		words = string.format(K.TAKE_WORDS.another_box, st.peer.by, area_label(t.area))
	elseif msg.reason == "no_area" then
		words = string.format(K.TAKE_WORDS.no_area, area_label(t.area))
	else
		words = K.TAKE_WORDS[msg.reason] or K.TAKE_WORDS.failed
		if msg.detail and msg.reason == "failed" then
			words = words .. " (" .. msg.detail .. ")"
		end
	end
	tko.finish(t, words)
end

-- The write again, once.
function tko.retry()
	local t = st.take
	if not (t and t.phase == "waiting") then
		return
	end
	t.phase = "retrying"
	disarm("take")
	local ok, err = pcall(m.queue.set, m.queue, t.fields, t.tag, function(_, fine, model, why, detail)
		if st.take ~= t then
			return answer(t, fine, model, why, detail) -- ended meanwhile: its writer has heard already
		end
		st.take = nil
		if fine == true then
			st.taken_over = t -- Sync Taken Over after the read's variables (prg.on_read)
			answer(t, true, model, why, detail)
			last_action(string.format("Sync taken over: %s took %s over from another app's sync", paired_label(),
				area_label(t.area)))
		elseif why == "busy" then
			tko.finish_retry(t, model)
		else
			answer(t, fine, model, why, detail)
		end
	end)
	if not ok then
		st.take = nil
		log.warn("take-over: the write could not go again: %s", tostring(err))
		answer(t, false, st.model, "not sent", tostring(err))
	end
end

function tko.finish_retry(t, model)
	last_action("Not syncing: " .. K.TAKE_WORDS.again)
	answer(t, false, model, "cancelled")
end

-- Every read: a box no longer busy after the bridge's STOPPED gets the write
-- at once; another box of this project that no longer streams is no peer.
function tko.on_read(model)
	local state = type(model.bridge) == "table" and model.bridge.state or nil
	if st.take and st.take.phase == "waiting" and state ~= "busy" then
		tko.retry()
	end
	if st.peer and state ~= "busy" then
		st.peer = nil
	end
end

-- Follow Room's guard (follow.lua's peer_syncing): the other box's name
-- while it streams to this box's area (W10).
function tko.peer_syncing()
	local area = st.model and st.model.area
	return st.peer and st.peer.area == area and st.peer.by or nil
end

-- The periods (S4 §1.3, §4; design 5.3; C1.4) ----------------------------------------------
-- syncbox/periods.lua knows Day, Evening and Night, their settings and the
-- holds; the driver hands it the rows and applies a boundary while the box
-- syncs. The settings rows are read at every use (periods.from_properties).

local PERIOD_ROWS = { "Day Starts", "Evening Starts", "Night Starts", "Day Intensity", "Evening Intensity",
	"Night Intensity", "Day Brightness", "Evening Brightness", "Night Brightness" }

function per.props()
	local out = {}
	for _, name in ipairs(PERIOD_ROWS) do
		out[name] = cfg[name]
	end
	return out
end

function per.build(timer)
	m.periods = mod.periods.new({
		timer = timer, now = now_ms, log = log,
		settings = function()
			return (mod.periods.from_properties(per.props()))
		end,
		on_boundary = per.boundary,
		persist_get = function(name) return C4:PersistGetValue(name) end,
		persist_set = function(name, value) return C4:PersistSetValue(name, value) end,
	})
end

-- The period's settings for a sync in `mode` (programming's `period`), the
-- held fields left out; nil before late init.
function per.settings(mode)
	if not m.periods then
		return nil
	end
	local ok, s = pcall(m.periods.settings_for, m.periods, nil, mode)
	if not ok then
		log.warn("periods: %s", tostring(s))
		return nil
	end
	return s
end

-- av.lua's `period(n, mode)`: a route that syncs HDMI n. Another input, or
-- a box that does not sync, is a new source: a manual hold ends first
-- (design 5.3).
function per.av_settings(n, mode)
	local model = st.model
	if not (model and model.syncing and model.input == n) then
		per.release("source")
	end
	return per.settings(mode)
end

-- Follow Room's sync starts (second output) take the period's settings
-- here, as av.lua's and programming.lua's do in their own writes.
function per.fill(fields, tag)
	if not (starts_sync(fields) and mod.follow.owns(tag)) or fields.intensity or fields.brightness then
		return fields
	end
	local s = per.settings(fields.mode or (st.model and st.model.mode)) or {}
	if s.intensity == nil and s.brightness == nil then
		return fields
	end
	local out = {}
	for k, v in pairs(fields) do
		out[k] = v
	end
	out.intensity, out.brightness = s.intensity, s.brightness
	return out
end

function per.release(reason)
	if m.periods then
		local ok, err = pcall(m.periods.release, m.periods, reason)
		if not ok then
			log.warn("periods: the release failed: %s", tostring(err))
		end
	end
end

-- The followed room chose another source (behind a receiver, a second
-- output): a manual hold ends before the writes the change brings.
function per.source_changed(state, prev)
	if type(state) == "table" and type(prev) == "table"
		and (state.selected ~= prev.selected or state.kind ~= prev.kind) then
		per.release("source")
	end
end

-- A boundary while running (periods.lua's on_boundary): the new period's
-- settings while the box syncs, what differs from the box and is not held.
function per.boundary(period, _, why)
	per.row()
	local model = st.model
	if not (st.paired and m.tq and model and model.syncing) then
		return
	end
	local ok, fields = pcall(m.periods.settings_for, m.periods, period, model.mode)
	if not ok or type(fields) ~= "table" then
		return log.warn("periods: the settings of %s: %s", tostring(period), tostring(fields))
	end
	if fields.intensity == model.intensity then
		fields.intensity = nil
	end
	if fields.brightness == model.brightness then
		fields.brightness = nil
	end
	if next(fields) == nil then
		return log.debug("periods: %s (%s): nothing to change", tostring(period), tostring(why))
	end
	local label = mod.periods.LABELS[period] or tostring(period)
	local parts = {}
	if fields.intensity then
		parts[#parts + 1] = "intensity " .. fields.intensity
	end
	if fields.brightness then
		parts[#parts + 1] = string.format("brightness %d %%", fields.brightness)
	end
	m.tq:set(fields, { kind = "period", period = period }, function(_, landed, _, reason)
		if landed == true then
			last_action(string.format("%s: %s", label, table.concat(parts, ", ")))
		elseif reason ~= "superseded" and reason ~= "cancelled" then
			last_action(string.format("%s: the period's settings did not reach the box (%s)", label,
				tostring(reason)))
		end
	end)
end

-- The Periods row: the period now and until when, a hold, where the sunset
-- comes from (or that a clock time stands in for it, S4 §2).
function per.row()
	if not (st.late and m.periods) then
		return
	end
	local ok, now_text = pcall(m.periods.describe, m.periods)
	local fine, source = pcall(function() return (m.periods.sunset.source(now_ms())) end)
	if not ok then
		return log.warn("periods: %s", tostring(now_text))
	end
	row(K.PERIODS, fine and type(source) == "string" and (now_text .. ". " .. source) or now_text)
end

-- A period row set in Composer: what it refused, in Last Action; the
-- boundaries armed again (periods.lua's refresh).
for _, name in ipairs(PERIOD_ROWS) do
	dispatch.properties[(name:gsub("%s+", "_"))] = function(value)
		local before = cfg[name]
		cfg[name] = text(value)
		if not (st.late and m.periods) or before == cfg[name] then
			return
		end
		local _, problems = mod.periods.from_properties(per.props())
		for _, p in ipairs(problems or {}) do
			if p.property == name then
				last_action(p.text)
			end
		end
		log.info("%s: %s", name, tostring(cfg[name]))
		pcall(m.periods.refresh, m.periods)
		per.row()
	end
end

-- The offers, the area and the name (S4 §1.4, §1.5, §1.7; §5) ------------------------------
-- syncbox/offers.lua (the box's own input switching and CEC behaviours),
-- syncbox/areas.lua (Entertainment Area) and syncbox/names.lua (the box's
-- name both ways): each sees every good read and writes only on a click or
-- by the rules its header gives.

function ofr.build(timer)
	local persist_get = function(name) return C4:PersistGetValue(name) end
	local persist_set = function(name, value) return C4:PersistSetValue(name, value) end
	m.offers = mod.offers.new({ client = m.client, poller = m.poller, now = now_ms, log = log,
		persist_get = persist_get, persist_set = persist_set,
		persist_delete = function(name) return C4:PersistDeleteValue(name) end,
	})
	m.areas = mod.areas.new({ queue = m.tq, log = log, persist_get = persist_get, persist_set = persist_set })
	-- The device's Composer name is the AV switch proxy's: Composer renames
	-- the proxy [verified: API 32_serial_network_device/_6-GetDeviceDisplayName.md;
	-- API 22_miscellaneous/_32-RenameDevice.md: the proxy's id, never from
	-- OnDriverInit; docs/simplify-research-names-sync.md §3.1].
	m.names = mod.names.new({ client = m.client, poller = m.poller, timer = timer, now = now_ms, log = log,
		persist_get = persist_get, persist_set = persist_set, last_action = ofr.names_said,
		display_name = function()
			local id = route.proxy_id()
			local ok, name = pcall(C4.GetDeviceDisplayName, C4, id)
			return id and ok and type(name) == "string" and name or nil
		end,
		rename_device = function(name)
			local id = route.proxy_id()
			if id then
				C4:RenameDevice(id, name)
			end
		end,
	})
end

-- What names.lua says: in Last Action, but for its first look (names that
-- differ at the first read after pairing or after this build's install),
-- which no person's act caused: Status carries it as Attention, so Pair
-- Sync Box's own result stays in Last Action (S2 §4).
function ofr.names_said(words)
	local held = m.names and call(m.names, "held")
	if type(held) == "table" and held.held == "first" then
		return log.info("%s", words)
	end
	last_action(words)
end

-- Control4 routes through the box in line and behind a receiver; on a
-- receiver's second output it does not (design 5.8). Attention follows it.
function ofr.check_routed()
	local routed = st.paired and route.wiring() ~= "second_output" or false
	if routed ~= st.routed then
		st.routed = routed
		refresh_box_rows()
		ofr.attention()
	end
end

-- The Input Switching row (S4 §7: "Input Switching on Attention"): the
-- offers' Attention while Control4 routes through a box that switches
-- inputs by itself, else what the box does by itself (offers.lua's row;
-- before it is built, the state's text). Status points at it.
function ofr.switching_row(fallback)
	if not m.offers then
		return fallback
	end
	local attention = call(m.offers, "attention", st.routed)
	if attention then
		return "Attention: " .. attention
	end
	return call(m.offers, "row") or fallback
end

-- What waits for a person (the offers' input switching while Control4
-- routes through the box, the names' click): the box driver has no
-- Attention row of its own, so Status ends with it (the input switching's
-- in short: its whole text is Input Switching's), and the log has it once
-- when it starts. Last Action stays the actions' and the outcomes'.
function ofr.attention_text()
	local texts = {}
	for _, t in ipairs({ m.offers and call(m.offers, "attention", st.routed) or false,
		m.names and call(m.names, "attention") or false }) do
		if t then
			texts[#texts + 1] = t
		end
	end
	return #texts > 0 and table.concat(texts, "; ") or nil
end

function ofr.attention_note()
	local parts = {}
	if m.offers and call(m.offers, "attention", st.routed) then
		parts[#parts + 1] = "the box switches inputs by itself (see Input Switching)"
	end
	local names = m.names and call(m.names, "attention") or nil
	if names then
		parts[#parts + 1] = names
	end
	return #parts > 0 and ("Attention: " .. table.concat(parts, "; ")) or nil
end

function ofr.attention()
	local attention = ofr.attention_text()
	if attention and attention ~= st.attention then
		log.warn("Attention: %s", attention)
	end
	st.attention = attention
end

-- The Entertainment Area drop-down: the box's areas by name, those whose
-- lamps sit in this device's room first (the bridge's CONFIGURE says which:
-- design 6.1, offered first, never chosen), and the box's area now; sent
-- when it changed (as Follow Room's).
function ofr.area_list()
	if not (st.late and m.areas) then
		return
	end
	local first = {}
	local ok_room, room = pcall(C4.GetDeviceDisplayName, C4, fr.own_room())
	for _, a in ipairs(st.bridge_areas or {}) do
		for _, name in ipairs(type(a.rooms) == "table" and a.rooms or {}) do
			if ok_room and name == room then
				first[a.id] = true
			end
		end
	end
	local ok, items, value = pcall(m.areas.items, m.areas, first)
	if not ok or type(items) ~= "table" then
		return log.warn("Entertainment Area: the list could not be built: %s", tostring(items))
	end
	local joined = table.concat(items, ",")
	value = tostring(value or "")
	if joined .. "\n" .. value == st.area_sent then
		return
	end
	st.area_sent = joined .. "\n" .. value
	pcall(C4.UpdatePropertyList, C4, K.ENTERTAINMENT_AREA, joined, value)
	rows[K.ENTERTAINMENT_AREA] = value
	prop(K.ENTERTAINMENT_AREA, value)
end

-- A pick in Entertainment Area: one hueTarget write (areas.lua), its outcome
-- in Last Action. Late init's replay of the row changes nothing.
dispatch.properties["Entertainment_Area"] = function(value)
	if not (st.late and m.areas) then
		return
	end
	value = text(value) or ""
	if value == rows[K.ENTERTAINMENT_AREA] then
		return
	end
	if not st.paired then
		st.area_sent = nil
		ofr.area_list()
		return last_action("Entertainment Area: not paired; run Pair Sync Box first")
	end
	local ok, why = m.areas:choose(value, function(_, words)
		last_action(words)
		st.area_sent = nil
		ofr.area_list()
	end)
	if not ok then
		st.area_sent = nil
		ofr.area_list()
		last_action(tostring(why or "Entertainment Area: not set"))
	end
end

-- What Status adds about the area while it is not a usable one (gone in
-- Hue, invalid, none chosen): areas.lua's words; nil otherwise.
function ofr.area_note()
	if not (st.paired and m.areas and st.model) then
		return nil
	end
	local ok, a = pcall(m.areas.status, m.areas)
	if ok and type(a) == "table" and (a.how == "gone" or a.how == "invalid" or a.how == "none") then
		return a.text
	end
	return nil
end

-- Programming's view of the areas (programming.lua's `areas`): C1.6's Area
-- is a DYNAMIC_LIST of the box's area names (GetCommandParamList), so a
-- value is a name; areas.lua resolves ids (it follows the re-points of a
-- gone area). A name one of the box's areas has now resolves to its id; any
-- other value goes to areas.lua as it is (an id from an older line).
ofr.programming_areas = {}

function ofr.programming_areas.names()
	local out, seen = {}, {}
	for _, a in ipairs(st.model and type(st.model.areas) == "table" and st.model.areas or {}) do
		if a.name and not seen[a.name] then
			seen[a.name] = true
			out[#out + 1] = a.name
		end
	end
	return out
end

function ofr.programming_areas.resolve(_, value)
	if not m.areas then
		return nil, "the areas are not read yet"
	end
	local found
	for _, a in ipairs(st.model and type(st.model.areas) == "table" and st.model.areas or {}) do
		if a.name == value then
			if found then
				return nil, string.format("two entertainment areas are named %s; rename one in the Hue app",
					https.peer_text(tostring(value), 64))
			end
			found = a.id
		end
	end
	return m.areas:resolve(found or value)
end

function ofr.on_read(model)
	call(m.offers, "observe", model)
	local said = call(m.areas, "observe", model)
	if said then
		last_action(said)
	end
	call(m.names, "observe", model)
	ofr.check_routed()
	ofr.attention()
	ofr.area_list()
end

-- Sync Box Settings (C1.5; design 5.4, 5.8): offers.lua's choices, then
-- names.lua's while the names wait for a click; one write at most, its
-- outcome in Last Action.
function ofr.settings(params)
	local value = text(params.What)
	if not st.paired then
		return last_action("Sync Box Settings: not paired; run Pair Sync Box first")
	end
	if not value then
		return last_action(string.format("Sync Box Settings: pick one under What (%s; %s)", mod.offers.LABEL_LET,
			mod.offers.LABEL_RESTORE))
	end
	local function done(_, words)
		last_action(words)
		refresh_box_rows()
		ofr.attention()
	end
	if m.offers:choose(value, done) or m.names:choose(value, done) then
		return
	end
	last_action("Sync Box Settings: that choice is not offered any more; open the What list again")
end

-- The What picker [verified: FUND 12.3_custom_select_implementation/
-- _2-CUSTOMSELECTLIST.md]: offers.lua's choices with what each does now,
-- then names.lua's.
function SyncBoxSettingsList()
	if not (st.late and m.offers) then
		return { { text = "(not ready yet; open the list again)", value = "" } }
	end
	local list = {}
	for _, module in ipairs({ m.offers, m.names }) do
		local ok, items = pcall(module.choices, module)
		if ok and type(items) == "table" then
			for _, item in ipairs(items) do
				list[#list + 1] = item
			end
		elseif not ok then
			log.warn("the Sync Box Settings list could not be built: %s", tostring(items))
		end
	end
	if #list == 0 then
		list[1] = { text = "(nothing to offer; see the Lua output)", value = "" }
	end
	return list
end

-- A rename in Composer (OnItemNameChanged) and the 5-minute tick for one
-- whose event was missed (names.lua's on_composer_rename and check).
function ofr.renamed()
	call(m.names, "on_composer_rename")
end

function ofr.tick()
	arm("names", K.NAMES_TICK_MS, function()
		if st.paired then
			call(m.names, "check")
		end
		ofr.tick()
	end)
end

-- Late init: the periods armed (no timer in OnDriverInit), the icons and
-- rows from what was kept, Control4's routing looked up.
function prg.start()
	st.icons, st.take, st.taken_over, st.peer, st.attention = {}, nil, nil, nil, nil
	if m.periods then
		local ok, err = pcall(m.periods.start, m.periods)
		if not ok then
			log.error("periods: start failed: %s", tostring(err))
		end
	end
	st.area_sent, st.routed = nil, false
	per.row()
	if st.paired then
		prg.icons(true) -- a box never paired has no state to show yet
	end
	ofr.check_routed()
	ofr.area_list()
	ofr.tick()
end

-- OnDriverDestroyed: no timer, no callback.
function prg.stop()
	st.take = nil
	for _, module in ipairs({ m.periods, m.offers, m.names }) do
		pcall(call, module, "stop")
	end
end

-- The poller's callbacks (S2 §3.6) -------------------------------------------------------

local poll = {}

-- A good read: the model, the rows, the hello when the box's bridge or
-- area changed (C5), and the firmware in the log when it changed (EC B14).
function poll.on_state(model, changes)
	if st.destroyed or type(model) ~= "table" then
		return
	end
	local before = st.model
	st.model, st.away_since = model, nil
	-- A good read ends an outage whoever noticed it (the poller, or the
	-- identity checks before it ran).
	set_online()
	if st.trouble and st.trouble.kind == "refused" then
		st.trouble, st.refused_step = nil, 0
		disarm("refused")
		log.info("the box accepts the registration again")
	end
	if before and before.firmware ~= model.firmware then
		log.info("%s firmware %s to %s", paired_label(), tostring(before.firmware), tostring(model.firmware))
	end
	if log.enabled("debug") and type(changes) == "table" and #changes > 0 then
		log.debug("state: %s changed", table.concat(changes, ", "))
	end
	hello(false)
	-- Stage 3: the queue's writes, the proxy's confirmations, the wiring.
	local ok, err = pcall(route.on_read, model)
	if not ok then
		log.error("routing after a read failed: %s", tostring(err))
	end
	-- Stage 4: the variables and their events, the take-over, the offers,
	-- the area and the name.
	ok, err = pcall(prg.on_read, model, before)
	if not ok then
		log.error("programming after a read failed: %s", tostring(err))
	end
	refresh()
end

function poll.on_offline(since_ms)
	if st.destroyed then
		return
	end
	set_offline(num.finite(since_ms) or now_ms())
	refresh()
	search("the box does not answer")
end

function poll.on_online()
	if st.destroyed then
		return
	end
	st.away_since = nil
	set_online()
	refresh()
	-- W23: what the followed room asked for while the box was away is
	-- applied once now if the box differs, never the missed sequence.
	local ok, err = pcall(call, m.follow, "contact")
	if not ok then
		log.error("Follow Room after the outage failed: %s", tostring(err))
	end
end

-- EC B5: the box refuses the token (401 or 403). The poller stopped; the
-- token stays (a restore or the Hue Sync app may bring it back); the box is
-- asked again after 5 and 15 minutes and an hour, then every hour: each ask
-- is the poller started again, whose next refusal arms the next ask and
-- whose first good read ends it (poll.on_state).
local function arm_refused()
	st.refused_step = st.refused_step + 1
	local ms = K.REFUSED_MS[st.refused_step] or K.REFUSED_MS[#K.REFUSED_MS]
	arm("refused", ms, function()
		if st.paired and trusted() and st.trouble and st.trouble.kind == "refused" then
			log.info("asking the box again whether it accepts the registration")
			start_polling()
		end
	end)
end

local function refused(status)
	if not (st.trouble and st.trouble.kind == "refused") then
		st.trouble, st.refused_step = { kind = "refused", since = now_ms(), status = status }, 0
		last_action(string.format("%s at %s refuses this pairing (HTTP %s): hold its button for 3 seconds, then run "
			.. "Pair Sync Box", paired_label(), tostring(st.address), tostring(status)))
	end
	if not st.timers.refused then
		arm_refused()
	end
	refresh()
end

-- A refusal is believed only from the proven box: the identity is checked
-- again first (R5 §3.4; the bridge's #490 N-6), and another device there is
-- EC B12, not a forgotten registration.
function poll.on_refused(status)
	if st.destroyed then
		return
	end
	m.poller:stop()
	if not (st.paired and st.address) then
		return
	end
	local address = st.address
	m.identity:check(address, st.box_id, function(result)
		if st.destroyed or address ~= st.address or not st.paired then
			return
		end
		if type(result) == "table" and result.ok then
			refused(status)
		else
			identity_failed(type(result) == "table" and result or { reason = "inconclusive" })
			refresh()
		end
	end)
end

-- Pairing (S2 §4) ------------------------------------------------------------------

-- A pairing or check that failed, in words (S2 §3.4, §4 step 3).
local function failure_words(result, address)
	local reason = tostring(result.reason or "unknown")
	local detail = result.text or result.detail
	local id = type(result.device) == "table" and result.device.id or nil
	local words = {
		timeout = string.format("the button on the sync box at %s was not held within 2 minutes; run Pair Sync Box "
			.. "again", address),
		closed = "the pairing window was closed",
		refused = string.format("the sync box at %s refused the registration%s", address,
			detail and (" (" .. https.peer_text(detail, 120) .. ")") or ""),
		["identity:unreachable"] = string.format("nothing answers at %s", address),
		["identity:not_a_box"] = string.format("%s is not a Hue sync box", address),
		["identity:camera"] = string.format("%s is a Hue Play Screen Sync camera, not an HDMI sync box", address),
		["identity:wrong_box"] = string.format("%s is %s, not the paired %s; Forget Pairing first to pair another box",
			address, id and box_label(id, model_code(result.device)) or "another box", short_id(st.box_id)),
		["identity:not_pinned"] = string.format("the TLS check at %s failed (the controller did not verify the box's "
			.. "certificate); nothing was sent", address),
		["identity:inconclusive"] = string.format("the TLS check at %s was inconclusive; try again", address),
	}
	return words[reason] or reason
end

-- The window's end, whatever ended it.
local function pairing_done(address, result)
	disarm("tick")
	if st.destroyed then
		return
	end
	result = type(result) == "table" and result or { ok = false, reason = "unknown" }
	if not result.ok then
		last_action("Not paired: " .. failure_words(result, address))
		-- A box paired before stays paired, its client and token untouched
		-- (syncbox/pairing.lua): its reads go on, or its checks start again.
		if st.paired then
			if trusted() and not st.trouble then
				start_polling()
			else
				start_checks()
			end
		end
		refresh()
		return
	end
	local creds = m.store:load()
	local d = type(result.device) == "table" and result.device or {}
	st.paired, st.box_id = true, creds.box_id or d.id
	st.address = result.address or creds.address or address
	st.device, st.model, st.trouble = d, nil, nil
	st.away_since, st.refused_step = nil, 0
	set_online()
	disarm("refused")
	disarm("recheck")
	m.link:reset()
	start_polling()
	last_action(string.format("Paired with %s at %s", box_label(st.box_id, model_code(d)), st.address))
	hello(true)
	refresh()
end

-- Status counts down every TICK_MS while the window is open.
local function tick()
	refresh_status()
	if m.pairing and m.pairing:is_open() then
		arm("tick", K.TICK_MS, tick)
	end
end

local function open_window(address)
	m.poller:stop()
	disarm("recheck")
	last_action(string.format("Hold the button on the sync box for 3 seconds (%d:%02d left)",
		math.floor(K.WINDOW_S / 60), K.WINDOW_S % 60))
	m.pairing:open(address, function(result)
		pairing_done(address, result)
	end)
	if m.pairing:is_open() then
		arm("tick", K.TICK_MS, tick)
	end
	refresh_status()
end

-- The Box picker (SyncBoxList): "box:<id>" for a found box, K.TYPE_ADDRESS
-- for the address typed under Address.
local function found_by_value(value)
	local id = type(value) == "string" and value:match("^box:(%x+)$") or nil
	for _, item in ipairs(st.found) do
		if id and item.id == id:upper() then
			return item
		end
	end
	return nil
end

local actions = {}

-- Pair Sync Box (S2 §4 steps 1 to 3; C1.5): a found box, or the address
-- typed (else the Box Address row's), then the identity and the window.
function actions.pair(params)
	if m.pairing:is_open() then
		return last_action(status_text())
	end
	local choice, typed = text(params.Box), text(params.Address)
	local address
	if choice and choice ~= K.TYPE_ADDRESS then
		local item = found_by_value(choice)
		if not item then
			search("Pair Sync Box")
			return last_action("Not paired: that box is no longer in the list; searching again, then run Pair Sync Box")
		end
		address = item.address
	elseif typed then
		address = (mod.devhooks and mod.devhooks.parse_address or mod.discovery.parse_ipv4)(typed)
		if not address then
			return last_action(string.format("Not paired: %s is not an IPv4 address (four numbers, as 10.0.2.150)",
				https.peer_text(typed, 64)))
		end
	elseif choice == K.TYPE_ADDRESS then
		if not st.address then
			return last_action("Not paired: type the box's address under Address (four numbers, as 10.0.2.150)")
		end
		address = st.address -- the Box Address row: the box paired before, or forgotten last
	elseif #st.found == 0 then
		search("Pair Sync Box")
		return last_action("Not paired: no box chosen; searching the network for Hue sync boxes, then pick one under "
			.. "Box or type its address under Address")
	else
		return last_action(string.format("Not paired: pick a box under Box (%d found) or type its address under "
			.. "Address", #st.found))
	end
	open_window(address)
end

-- Forget Pairing (S2 §4 step 4; EC C5): the registration deleted on the
-- box when it answers, the token gone, the rows cleared but Box Address,
-- the reads stopped, GOODBYE to the bridge. The device stays.
function actions.forget(params)
	if text(params.Confirm) ~= "Yes" then
		return last_action("Forget Pairing: not confirmed (pick Yes under Confirm)")
	end
	if not st.paired then
		if m.pairing:is_open() then
			m.pairing:close()
		end
		refresh()
		return last_action("Not paired: nothing to forget")
	end
	local label, address = paired_label(), st.address
	m.poller:stop()
	disarm("recheck")
	disarm("refused")
	if st.bridge then
		m.link:goodbye(st.box_id)
	end
	st.paired, st.box_id, st.model, st.device = false, nil, nil, nil
	st.trouble, st.away_since, st.online = nil, nil, nil
	clear_offline()
	saved.forget()
	route.forget()
	last_action(string.format("Forgetting the pairing with %s at %s", label, tostring(address)))
	m.pairing:forget(function(result)
		result = type(result) == "table" and result or {}
		-- Box Address stays, for the next Pair Sync Box (S2 §4 step 4).
		if address and not st.paired then
			m.store:save({ address = address })
		end
		if result.deleted_on_box then
			last_action(string.format("Forgot the pairing with %s: its registration on the box is removed", label))
		else
			last_action(string.format("Forgot the pairing with %s: the box did not answer, so its registration stays "
				.. "on the box until removed in the Hue Sync app", label))
		end
		refresh()
	end)
	refresh()
	arm_search()
end

-- Diagnostics (C1.5: as the bridge's) ----------------------------------------------------------

-- A copy of the state without the value of any field whose name holds a
-- secret word (K.SECRET_WORDS; R1 §2.9), at any depth: the Lua output must
-- never print a key.
local function redacted(v, depth)
	if type(v) ~= "table" or depth > 16 then
		return type(v) == "table" and K.REDACTED or v
	end
	local out = {}
	for k, item in pairs(v) do
		local secret = false
		if type(k) == "string" then
			local name = k:lower()
			for _, word in ipairs(K.SECRET_WORDS) do
				secret = secret or name:find(word, 1, true) ~= nil
			end
		end
		out[k] = secret and K.REDACTED or redacted(item, depth + 1)
	end
	return out
end

-- A read of the whole state outside the poller's rhythm (Diagnostics):
-- `done(model, decoded)` on a good one, else Last Action says why.
local function read_now(what, done)
	if not st.paired then
		return last_action(what .. ": not paired; run Pair Sync Box first")
	elseif not trusted() then
		return last_action(string.format("%s: not read; %s", what, status_text()))
	end
	last_action(string.format("%s: reading %s at %s", what, paired_label(), tostring(st.address)))
	m.client:get("", function(ok, status, decoded, err)
		if st.destroyed then
			return
		end
		if status == 401 or status == 403 then
			return poll.on_refused(status)
		elseif not ok then
			return last_action(string.format("%s: the box did not answer as expected (%s)", what,
				https.peer_text(err or ("HTTP " .. tostring(status)), 120)))
		end
		local model, reason = m.state.from_api(decoded, st.model)
		if not model then
			return last_action(string.format("%s: %s", what, https.peer_text(reason, 120)))
		end
		poll.on_state(model, {})
		done(model, decoded)
	end)
end

local diagnose = {}

-- The identity check at Box Address, with the paired id when paired.
diagnose["Check the box now"] = function()
	if not st.address then
		return last_action("Check the box now: no box to check; run Pair Sync Box first")
	end
	local address, expected = st.address, st.paired and st.box_id or nil
	last_action(string.format("Check the box now: checking %s", address))
	m.identity:check(address, expected, function(result)
		if st.destroyed then
			return
		end
		result = type(result) == "table" and result or { ok = false, reason = "inconclusive" }
		local d = type(result.device) == "table" and result.device or {}
		local mine = st.paired and address == st.address
		if result.ok then
			if mine then
				identity_passed(result)
				m.poller:soon("diagnostics")
			end
			last_action(string.format("Check the box now: %s answers at %s and passed the identity and TLS checks%s",
				box_label(d.id, model_code(d)), address,
				result.reason == "unknown_model" and " (a model this driver does not know)" or ""))
		else
			if mine then
				identity_failed(result)
			end
			last_action("Check the box now: " .. failure_words({ reason = "identity:" .. tostring(result.reason),
				device = d }, address))
		end
		refresh()
	end)
end

diagnose["Read everything from the box now"] = function()
	read_now("Read everything from the box now", function(model)
		last_action("Read everything from the box now: " .. m.state.describe(model).sync)
	end)
end

diagnose["Show the box's raw state in the Lua output"] = function()
	read_now("Show the box's raw state", function(_, decoded)
		local ok, json = pcall(C4.JsonEncode, C4, redacted(decoded, 0)) -- [verified: API 12_json/_2-JsonEncode]
		json = ok and type(json) == "string" and json or "(the state could not be encoded)"
		log.always("raw state of %s, secret fields redacted (%d bytes):", paired_label(), #json)
		for i = 1, #json, K.RAW_LINE do
			log.always("%s", json:sub(i, i + K.RAW_LINE - 1))
		end
		last_action(string.format("Show the box's raw state: %d bytes in the Lua output, secret fields redacted",
			#json))
	end)
end

function actions.diagnostics(params)
	local what = text(params.What)
	local run = what and diagnose[what]
	if not run then
		return last_action("Diagnostics: pick one under What (" .. table.concat(K.DIAGNOSTICS, "; ") .. ")")
	end
	run()
end

-- Set Source Sync Mode (S3 §5; W §7.2): one source's mode behind a receiver
-- and on a second output, kept by syncbox/sources.lua by device id with the
-- name it had. In line it is kept as well and says where it applies.
function actions.source_mode(params)
	-- W21's offer, picked from the Source list: the mode moves to the device
	-- that replaced the one it was set for (Mode is not used).
	local from, to = tostring(params.Source or ""):match("^offer:(%d+):(%d+)$")
	if from then
		local ok, moved = pcall(m.sources.accept, m.sources, from, to)
		st.offers_said = {}
		route.sources_row()
		if not (ok and moved) then
			return last_action("Set Source Sync Mode: that offer is gone; open the Source list again")
		end
		local d = call(m.sources, "describe", to)
		local name = type(d) == "table" and d.name or ("device " .. to)
		local mode = mod.sources.LABEL[call(m.sources, "setting", to) or ""] or "Automatic"
		return last_action(string.format("Source Sync Mode of %s: %s (from device %s, which it replaces)",
			https.peer_text(name, 64), mode, from))
	end
	local id = type(params.Source) == "string" and num.int(params.Source:match("^source:(%d+)$"), 1) or nil
	local mode = text(params.Mode)
	local known = false
	for _, item in ipairs(K.SYNC_MODE_ITEMS) do
		known = known or item == mode
	end
	if not id then
		return last_action("Set Source Sync Mode: pick a source under Source (the sources connected to the box and "
			.. "those seen in the followed room)")
	elseif not known then
		return last_action("Set Source Sync Mode: pick a mode under Mode (" .. table.concat(K.SYNC_MODE_ITEMS, ", ")
			.. ")")
	end
	local ok, done, words = pcall(m.sources.set_mode, m.sources, id, mode)
	if not (ok and done) then
		log.warn("Set Source Sync Mode for %d: %s", id, tostring(ok and words or done))
		return last_action(string.format("Set Source Sync Mode: not set (%s)", https.peer_text(tostring(ok and words
			or "an error, see the Lua output"), 80)))
	end
	route.sources_row()
	local where = route.wiring() == "in_line"
		and " (used behind a receiver and on a second output; in line the HDMI n Sync Mode rows decide)" or ""
	last_action(tostring(words) .. where)
end

-- Composer actions (LUA_ACTION): every click ends in Last Action. Before
-- late init the modules do not exist yet.
for command, run in pairs({ Pair_Sync_Box = actions.pair, Forget_Pairing = actions.forget,
	Diagnostics = actions.diagnostics, Set_Source_Sync_Mode = actions.source_mode,
	Sync_Box_Settings = ofr.settings }) do
	dispatch.commands[command] = function(params)
		if not st.late then
			return last_action("Not done: the driver is still starting; try again in a moment")
		end
		run(params or {})
	end
end

-- The Box picker [verified: FUND 12.3_custom_select_implementation/_1-Overview.md:
-- a table of { text, value }]. Opened with an empty list, it starts a search
-- (S2 §4 step 1); before late init it says so.
function SyncBoxList()
	if not st.late then
		return { { text = "(not ready yet; open the list again)", value = "" } }
	end
	local list = {}
	for _, item in ipairs(st.found) do
		local label = box_label(item.id, item.model)
		if item.name then
			label = label .. ", " .. https.peer_text(item.name, 64)
		end
		list[#list + 1] = { text = label .. ", " .. tostring(item.address), value = "box:" .. tostring(item.id) }
	end
	if #list == 0 then
		local busy = m.discovery:busy() or search("the Box list was opened")
		list[1] = { text = busy and "(searching the network; open the list again in a few seconds)"
			or "(no Hue sync box found on the network)", value = "" }
	end
	list[#list + 1] = { text = "Type an address (under Address)", value = K.TYPE_ADDRESS }
	return list
end

-- The Source picker of Set Source Sync Mode [verified: FUND
-- 12.3_custom_select_implementation/_2-CUSTOMSELECTLIST.md]: the sources
-- upstream of the box and those seen in the followed room, each with its
-- mode now; "source:<device id>".
function SourceList()
	if not st.late then
		return { { text = "(not ready yet; open the list again)", value = "" } }
	end
	local list = {}
	local ok, err = pcall(function()
		for _, offer in ipairs(m.sources:offers(route.proxy_id())) do
			list[#list + 1] = { text = https.peer_text("Offer: " .. tostring(offer.text), 160),
				value = string.format("offer:%d:%d", offer.from_id, offer.to_id) }
		end
		for _, item in ipairs(m.sources:candidates(route.proxy_id())) do
			list[#list + 1] = { text = https.peer_text(m.sources:entry_text(item), 96), value = "source:" .. item.id }
		end
	end)
	if not ok then
		log.warn("the Source list could not be built: %s", tostring(err))
	end
	if #list == 0 then
		list[1] = { text = "(no source found: connect the receiver to HDMI 1, or pick the room in Follow Room)",
			value = "" }
	end
	return list
end

-- The proxies (ReceivedFromProxy) ------------------------------------------------------
-- #483 D-7: the AV switch's commands are taken on 5001 only, SELECT on the
-- UI Buttons' 5002 to 5005 only [verified: API 25_proxy/_5-ReceivedFromProxy:
-- the binding of the proxy that sent it]; dispatch drops the rest first.
dispatch.proxy_binding_ok = function(binding, command)
	if command == "SELECT" then
		return K.UI_BUTTONS[binding] ~= nil
	end
	return binding == K.PROXY_AV
end

-- A UI Button press (S4 §1.2, design 5.6): the button's command through
-- programming (Hue Sync toggles sync, Sync Brighter and Sync Dimmer step
-- the brightness by 10 points, Sync Intensity steps the intensity), whose
-- outcome ends in Last Action; the icons follow the next read. One that
-- comes before late init waits for it (common/device.lua).
local select_button = after_late_init("SELECT", function(params)
	prg.select(params.binding)
end)
dispatch.proxy["SELECT"] = function(binding, params)
	local p = {}
	for k, v in pairs(type(params) == "table" and params or {}) do
		p[k] = v
	end
	p.binding = tonumber(binding)
	select_button(p)
end

-- The AV switch's commands go to syncbox/av.lua (C4). One that comes before
-- late init (Director starts the proxy first: GET_AUDIO_INPUTS,
-- BINDING_CHANGE_ACTION) waits for it, in order, as the bridge's messages
-- do (common/device.lua), since nothing can be sent to the proxy or the box
-- before then [verified: API 22_miscellaneous/_25.2-SafeUsageTable.md].
for _, command in ipairs(AV_COMMANDS) do
	local handler = after_late_init(command, function(params)
		route.received(command, params)
	end)
	dispatch.proxy[command] = function(_, params)
		handler(params)
	end
end

-- From the bridge (ExecuteCommand; C5, every one a hint, #483) -------------------------------

local function from_bridge(command)
	return after_late_init(command, function(params)
		local msg = m.link:received(command, params)
		if not msg then
			return
		end
		if msg.kind == "configure" then
			if st.link_match ~= msg.match then
				log.info("the Hue Bridge says this box is %slinked to it", msg.match and "" or "not ")
			end
			st.link_match = msg.match
			st.bridge_areas = msg.areas
			refresh_box_rows()
			ofr.area_list()
		elseif msg.kind == "area" then
			-- The box reads its own state at once; nothing else changes (C5).
			log.debug("area %s %s (%s): reading the box", msg.id, msg.status, msg.streamer)
			if trusted() and not st.trouble then
				m.poller:soon("bridge hint")
			end
		elseif msg.kind == "stopped" then
			-- The answer to the take-over's STOP_AREA (S4 §6).
			tko.stopped(msg)
		elseif msg.kind == "ask_hello" then
			-- The bridge does not know this box (it restarted): hello again.
			hello(true)
		end
	end)
end

-- The bridge's messages link.lua reads (C5; stage 4 adds STOPPED, and the
-- bridge's request for a hello after its restart when link.lua names one).
for _, name in ipairs({ "CONFIGURE", "AREA", "STOPPED", "ASK_HELLO" }) do
	local command = mod.link[name]
	if type(command) == "string" then
		dispatch.commands[command] = from_bridge(command)
	end
end

-- Discovery's network connection (UDP mDNS) ----------------------------------------------
-- syncbox/discovery.lua owns its binding (6008); whatever it does not take
-- is not this driver's either.

function ReceivedFromNetwork(idBinding, nPort, strData, from)
	if m.discovery and m.discovery:received(idBinding, nPort, strData, from) then
		return
	end
	log.debug("ReceivedFromNetwork on binding %s: not ours", tostring(idBinding))
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	if m.discovery and m.discovery:status_changed(idBinding, nPort, strStatus) then
		return
	end
	log.debug("OnConnectionStatusChanged on binding %s: not ours", tostring(idBinding))
end

-- Lifecycle -----------------------------------------------------------------------

dispatch.install(_G)

-- Every command the proxies send, logged at debug with every parameter as
-- it came (PREV_DEV_LIST included), each value capped, and the time: the
-- stage 2 beta is the logger of the routing probes P9 to P11 (#531). Then
-- the dispatch, which takes it on its binding or drops it.
local dispatch_proxy = ReceivedFromProxy
function ReceivedFromProxy(idBinding, strCommand, tParams)
	if log.enabled("debug") then
		local parts = {}
		for k, v in pairs(type(tParams) == "table" and tParams or {}) do
			parts[#parts + 1] = https.peer_text(k, 64) .. "=" .. https.peer_text(v, K.PARAM_MAX)
		end
		table.sort(parts)
		log.debug("proxy %s %s at %d ms: %s", tostring(idBinding), https.peer_text(strCommand, 64), now_ms(),
			#parts > 0 and table.concat(parts, " ") or "(no parameters)")
	end
	return dispatch_proxy(idBinding, strCommand, tParams)
end

-- The followed room's variables [verified: API 36_variable/_9-OnWatchedVariableChanged.md:
-- (idDevice, idVariable, strValue), for the listeners syncbox/room.lua sets
-- with C4:RegisterVariableListener, _10-RegisterVariableListener.md].
-- room.lua checks every value (W §7.4); one for no room it follows is its
-- to drop. Before late init there is no room module and no listener.
function OnWatchedVariableChanged(idDevice, idVariable, strValue)
	if not m.room or st.destroyed then
		return
	end
	local ok, err = pcall(m.room.on_variable, m.room, idDevice, idVariable, strValue)
	if not ok then
		log.error("OnWatchedVariableChanged %s/%s failed: %s", https.peer_text(idDevice, 16),
			https.peer_text(idVariable, 16), tostring(err))
	end
end

-- #492 (I-5, I-6): a release build locks Composer's Lua command window and
-- refuses a dev loop left behind by an earlier dev build (common/device.lua).
function OnDriverInit()
	dev.init()
	-- C1.9: the nine variables, in their order, in OnDriverInit.
	prg.build()
end

-- The modules, built once per start with what they need from the driver
-- (S2 §3). The identity module makes its own TLS self-check through the
-- client's queue (syncbox/identity.lua). The search checks candidates with
-- a client and an identity of its own, so a candidate never touches the
-- paired box's address or trust (S2 §3.7).
local function build()
	local timer = function(ms, fn) return C4:SetTimer(math.max(1, math.floor(ms)), fn) end
	m.state, m.link = mod.state, mod.link.new({ send = send_to_bridge, log = log })
	-- The encrypted flag only when true: the house's first start could not
	-- read the box id, address or registration id, the fields asked for with
	-- an explicit false, while the token (true) read fine [house, build 682,
	-- 2026-11-17, #547]; the bridge calls both with the name (and value)
	-- alone (bridge/credentials.lua), and so does this for every other field.
	m.store = mod.store.new({
		persist_get = function(name, encrypted)
			if encrypted then
				return C4:PersistGetValue(name, true)
			end
			return C4:PersistGetValue(name)
		end,
		persist_set = function(name, value, encrypted)
			if encrypted then
				return C4:PersistSetValue(name, value, true)
			end
			return C4:PersistSetValue(name, value)
		end,
		persist_delete = function(name) return C4:PersistDeleteValue(name) end,
		log = log,
	})
	local creds = m.store:load()
	m.client = mod.client.new({ address = creds.address, token = creds.token, log = log, timer = timer, now = now_ms })
	m.identity = mod.identity.new({ client = m.client, log = log })
	m.pairing = mod.pairing.new({ client = m.client, identity = m.identity, store = m.store, timer = timer,
		now = now_ms, log = log, instance_name = function()
			-- The device's Composer name [verified: API 32_serial_network_device/
			-- _6-GetDeviceDisplayName.md], so the owner finds the registration in
			-- the Hue Sync app (EC B3); syncbox/pairing.lua cuts it to 32 bytes.
			local ok, name = pcall(C4.GetDeviceDisplayName, C4)
			return ok and type(name) == "string" and name ~= "" and name or ("Control4 device " .. dev.device_id())
		end })
	m.poller = mod.poller.new({ client = m.client, timer = timer, now = now_ms, log = log,
		on_state = poll.on_state, on_offline = poll.on_offline, on_online = poll.on_online,
		on_refused = poll.on_refused })
	local probe = mod.identity.new({ client = mod.client.new({ log = log, timer = timer, now = now_ms }), log = log })
	m.discovery = mod.discovery.new({ timer = timer, now = now_ms, log = log, identity_for = function(address, cb)
		return probe:check(address, nil, cb)
	end })
	route.build(timer)
	-- Stage 4 (S4 §4, §5).
	per.build(timer)
	ofr.build(timer)
	return creds
end

-- Stage 3's modules (S3 §3, §4; W §7.4), each given the C4 calls it makes,
-- so its spec can stand in for them. Every room and source call is one of
-- the SDK's [verified: API 36_variable/_10-RegisterVariableListener.md,
-- _11-UnregisterVariableListener.md, _10.5-UnRegisterAllVariableListeners.md
-- (3.3.0), _5-GetDeviceVariable.md; API 22_miscellaneous/_12-GetDeviceVariables.md,
-- _9-GetDevices.md (the filter value a string, docs/design.md "Project APIs");
-- API 32_serial_network_device/_4-GetBoundProviderDevice.md,
-- _6-GetDeviceDisplayName.md]. PersistData without the encrypted flag
-- (#547: only an explicit true is passed, and nothing here is secret).
function route.build(timer)
	m.queue = mod.queue.new({ client = m.client, poller = m.poller, timer = timer, now = now_ms, log = log,
		on_done = route.on_done })
	-- Every writer (av.lua, follow.lua, programming.lua, the periods) goes
	-- through the take-over's view of the queue (S4 §1.6, below).
	m.tq = tko.wrap(m.queue)
	m.sources = mod.sources.new({
		get_devices = function(filter) return C4:GetDevices(filter) end,
		display_name = function(id) return C4:GetDeviceDisplayName(id) end,
		bound_provider = function(id, binding) return C4:GetBoundProviderDevice(id, binding) end,
		persist_get = function(name) return C4:PersistGetValue(name) end,
		persist_set = function(name, value) return C4:PersistSetValue(name, value) end,
		log = log,
	})
	m.room = mod.room.new({
		register = function(device_id, variable) return C4:RegisterVariableListener(device_id, variable) end,
		unregister = function(device_id, variable) return C4:UnregisterVariableListener(device_id, variable) end,
		unregister_all = function() return C4:UnregisterAllVariableListeners() end,
		get_variable = function(device_id, variable) return C4:GetDeviceVariable(device_id, variable) end,
		get_variables = function(device_id) return C4:GetDeviceVariables(device_id) end,
		timer = timer, now = now_ms, log = log,
		on_baseline = route.room_baseline, on_change = route.room_change, on_trouble = fr.trouble,
	})
	-- Follow Room's choice, kept in PersistData (room.lua's FOLLOW_KEY), the
	-- rooms by id from C4:GetDevicesByC4iName("roomdevice.c4i") [house: OS
	-- 3.4.2, docs/design.md "Project APIs"].
	m.choice = mod.room.choice({
		rooms = function() return C4:GetDevicesByC4iName("roomdevice.c4i") end,
		own_room = fr.own_room,
		persist_get = function(name) return C4:PersistGetValue(name) end,
		persist_set = function(name, value) return C4:PersistSetValue(name, value) end,
		log = log,
	})
	m.av = mod.av.new({ queue = m.tq, state_now = route.model, wiring_now = route.wiring, sources = m.sources,
		room = m.room, notify = route.notify, last_action = last_action, properties = route.setting, timer = timer,
		now = now_ms, log = log, period = per.av_settings })
	m.follow = mod.follow.new({
		queue = m.tq, sources = m.sources, box_id = route.proxy_id, wiring = route.follow_wiring,
		model = route.model, log = log, peer_syncing = tko.peer_syncing,
		online = function() return st.online ~= false and not st.offline_since end,
		settings = function()
			return { at_room_off = route.setting(K.ROOM_OFF), source_leaves = route.setting(K.LEAVES) }
		end,
		own_name = function()
			local ok, name = pcall(C4.GetDeviceDisplayName, C4)
			return ok and type(name) == "string" and name ~= "" and https.peer_text(name, 64) or paired_label()
		end,
		-- The box driver has no Attention row (contracts C1.4): Last Action
		-- and a warning in the log say it.
		notify = function(kind, words)
			if kind == "attention" then
				log.warn("%s", words)
			end
			last_action(words)
		end,
	})
end

-- Late init, once the pairing is known: the wiring the last read showed,
-- the rows it shows, and the room followed (its first state a baseline:
-- nothing is sent to the box at start, W15, EC C14).
function route.start()
	local ok, wiring = pcall(C4.PersistGetValue, C4, K.WIRING_KEY)
	st.wiring = ok and K.WIRING_NAMES[wiring] and wiring or nil
	st.followed, st.follow, st.follow_sent, st.follow_said, st.room_trouble = nil, nil, nil, nil, nil
	vis.shown = nil
	fr.list()
	local started, err = pcall(fr.apply)
	if not started then
		log.error("following the room at start failed: %s", tostring(err))
	end
	vis.update(true)
	route.sources_row()
	route.register_pip()
end

-- OnPIP, Director's "Refresh Navigator" event, fires when bindings, device
-- names or media change [verified: API 7_event/_1-RegisteringforSystemEvents.md,
-- _5.5-RegisterSystemEvent.md: C4:RegisterSystemEvent(C4SystemEvents["OnPIP"], 0);
-- _4.2-OnSystemEvent.md]. Stage 4 registers OnItemNameChanged too, a
-- rename in Composer (API 7/_1; the bridge's driver.lua reads its name in
-- the event's data [hardware 2026-10-22]), for the box's name both ways
-- (S4 §1.7). A runtime without the table (the specs) goes without them, as
-- the bridge does.
function route.register_pip()
	if type(C4SystemEvents) ~= "table" or type(C4.RegisterSystemEvent) ~= "function" then
		return log.debug("system events unavailable in this runtime")
	end
	for _, name in ipairs({ "OnPIP", "OnItemNameChanged" }) do
		local id = C4SystemEvents[name]
		local ok, err = pcall(C4.RegisterSystemEvent, C4, id, 0)
		if not (id and ok) then
			log.warn("RegisterSystemEvent %s: %s", name, tostring(id and err or "no such event"))
		end
	end
end

-- The project changed: a room whose variables did not answer is tried again
-- (W16), what is upstream of the box read again, the rooms and sources
-- listed again (W3, W21).
function OnSystemEvent(data)
	if not st.late or st.destroyed then
		return
	end
	if type(data) == "string" and data:find("OnItemNameChanged", 1, true) then
		log.debug("OnSystemEvent (OnItemNameChanged): %s", https.peer_text(data, 200))
		return ofr.renamed()
	end
	log.debug("OnSystemEvent (OnPIP): %s", https.peer_text(tostring(data), 200))
	call(m.room, "retry")
	call(m.follow, "refresh")
	st.follow_sent = nil
	fr.check()
	fr.list()
	route.sources_row()
end

-- After a Director restart the binding to the bridge can be invisible at late
-- init (common/device.lua re-checks at 5, 15, 30 and 60 s); found, it is greeted.
function dev.on_bridge_found()
	st.bridge = dev.bound_bridge()
	if st.bridge then
		m.link:reset()
		hello(true)
	end
end

function OnDriverLateInit()
	rows = {}
	st.destroyed = false
	dispatch.replay_properties(Properties)
	dev.show_driver_version(1)
	wrap.settle()
	local creds = build()
	st.late = true
	st.paired = creds.token ~= nil and creds.box_id ~= nil
	st.box_id = st.paired and creds.box_id or nil
	st.address = creds.address
	-- An outage that began before the restart goes on from its own time.
	st.offline_since = st.paired and stored_offline() or nil
	st.online = st.offline_since and false or nil
	-- Until the first answer: Online reads "Not reached since" this start,
	-- and the box rows show what the last good read before it showed.
	st.waiting_since = now_ms()
	saved.rows = st.paired and saved.load() or nil
	if not st.paired then
		C4:PersistDeleteValue(K.OFFLINE_KEY)
	end
	st.bridge = dev.bound_bridge()
	route.start()
	prg.start()
	dev.late_init()
	-- EC C14: nothing is sent to the box at start but the identity check and,
	-- once it passed, the reads.
	if st.paired then
		start_checks()
	else
		search("first load")
	end
	arm_search()
	hello(true)
	if not st.bridge then
		dev.schedule_recheck(1)
	end
	refresh()
	dev.replay_bindings()
end

-- The bridge's connection (binding 1); the AV and proxy bindings bring no
-- OnBindingChanged. A call before late init waits for it (common/device.lua).
OnBindingChanged = dev.binding_changed(function(idBinding, _, bound, otherDevice)
	if tonumber(idBinding) ~= K.BRIDGE_BINDING then
		return
	end
	dev.cancel_recheck()
	m.link:reset()
	if bound then
		st.bridge = dev.bound_bridge() or tonumber(otherDevice)
		hello(true)
	else
		-- EC C20: the box keeps working from its own API; nothing goes offline.
		st.bridge, st.link_match = nil, nil
		refresh_box_rows()
	end
end)

-- Composer is deleting the device: the bridge forgets it (C5 GOODBYE). The
-- registration stays on the box, named after the device (EC C4).
function OnDriverRemovedFromProject()
	if m.link and st.bridge then
		m.link:goodbye(st.box_id)
	end
end

function OnDriverDestroyed()
	st.destroyed = true
	for name in pairs(st.timers) do
		disarm(name)
	end
	if m.poller then
		m.poller:stop()
	end
	if m.discovery then
		m.discovery:stop()
	end
	-- Stage 3: no write waits, no room is listened to; stage 4: no period
	-- timer, no take-over, no offer's PUT heard.
	for _, module in ipairs({ m.queue, m.av, m.follow, m.room }) do
		pcall(call, module, "stop")
	end
	prg.stop()
	if m.client then
		m.client:cancel_all()
	end
	dev.cancel_timers()
end
