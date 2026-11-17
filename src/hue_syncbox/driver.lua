-- Hue Sync Box driver: one Control4 device per Hue Play HDMI Sync Box, the
-- fifth driver of the package (#514; 2.0 beta stage 2, #534). The contract
-- is docs/hdmi-sync-stage2-design.md ("S2" below): §4 pairing, §5 the
-- Composer surface; docs/hdmi-sync-contracts.md ("C") C1 to C3 and C5; the
-- lifecycle cases docs/edge-cases-syncbox.md ("EC") B and C rows.
--
-- The device talks to the box itself, over the box's local HTTPS API
-- (syncbox/client.lua, pinned to the box's own root; syncbox/identity.lua
-- proves the box before its token goes anywhere), and to the Hue Bridge
-- driver only through hints (syncbox/link.lua, C5, #483). Stage 2 is
-- read-only towards the box: it registers (Pair Sync Box), unregisters
-- (Forget Pairing), reads the state every few seconds (syncbox/poller.lua)
-- and shows it in the rows (syncbox/state.lua). A proxy command (ON,
-- SET_INPUT, a UI Button press) is answered with Last Action `Not done: ...`
-- and sends nothing, to the box or to the proxy (S2 §1); every command the
-- proxies send is logged at debug with all its parameters, for the routing
-- probes of #531 (P9 to P11).
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
	-- S2 §1: what a proxy command gets until routing comes (stage 3).
	NOT_YET = "Not done: routing through the box comes in a later 2.0 beta",
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
}

-- AV switch commands that would act (C4), and the UI Buttons' one command
-- [verified: PP 8_audio_video_switch_proxy_commands/_27-OFF.md, _28-ON.md,
-- _46-SETINPUT.md, _5-DISCONNECTOUTPUT.md, _48-SETOUTPUTINPUT.md,
-- _34-PULSEINPUT.md; UIB 107_ui_button_proxy_commands/_1-SELECT.md]: each is
-- answered with K.NOT_YET. The AV switch's other commands (C4: "nothing
-- beyond noting it", "ignored") get only the debug line every command gets.
local ACTING = { ON = true, OFF = true, SET_INPUT = true, DISCONNECT_OUTPUT = true, SET_OUTPUT_INPUT = true,
	PULSE_INPUT = true }
local NOTED = { CONNECT_OUTPUT = true, GET_AUDIO_INPUTS = true, SET_ROOM_BINDING_NAME = true,
	IS_AV_OUTPUT_TO_INPUT_VALID = true }

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
	av_bound = {},       -- BINDING_CHANGE_ACTION: AV binding id -> bound
	timers = {},         -- name -> C4 timer (arm / disarm)
	refused_step = 0,    -- EC B5: the asks since the refusal
}

-- The module instances (OnDriverLateInit).
local m = {}

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
	return d.refusal or d.sync
end

local function refresh_status()
	row("Status", status_text())
end

local function refresh_online()
	if st.offline_since then
		row("Online", "Offline since " .. clock(st.offline_since))
	elseif st.online then
		row("Online", "Online")
	elseif not st.paired then
		row("Online", "")
	end
end

-- The rows of the paired box: from the last good read, else from the
-- identity check (name, model, firmware), else empty.
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
	row("Sync Box", source.name and https.peer_text(source.name) or "")
	row("Model", model_code(source) and d.model or "")
	row("Firmware", (source.firmware or source.api_level) and d.firmware or "")
	row("Box ID", st.box_id)
	row("Box Address", st.address)
	if st.model then
		row("Wiring", d.wiring)
		row("Sync", d.sync)
		row("Inputs", d.inputs)
		local link_text = d.bridge_link
		if st.link_match == false then
			link_text = link_text .. " (not the Hue Bridge bound in Control4)"
		end
		row("Bridge Link", link_text)
		row("Input Switching", d.input_switching)
	end
end

local function refresh()
	refresh_box_rows()
	refresh_online()
	refresh_status()
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
	return st.box_id, bridge_id, model.area
end

-- HELLO at late init, on binding and after pairing (C5); after a read, only
-- when the box's bridge or area changed (link:update).
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

-- Composer actions (LUA_ACTION): every click ends in Last Action. Before
-- late init the modules do not exist yet.
for command, run in pairs({ Pair_Sync_Box = actions.pair, Forget_Pairing = actions.forget,
	Diagnostics = actions.diagnostics }) do
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

-- S2 §1: nothing to the box, no notify to the proxy, Last Action says why.
local function not_yet(binding, command)
	log.debug("%s on %s: not done in this beta", command, K.UI_BUTTONS[tonumber(binding)] or "the AV switch")
	last_action(K.NOT_YET)
end

for command in pairs(ACTING) do
	dispatch.proxy[command] = function(binding)
		not_yet(binding, command)
	end
end

dispatch.proxy["SELECT"] = function(binding)
	not_yet(binding, "SELECT")
end

for command in pairs(NOTED) do
	dispatch.proxy[command] = function()
	end
end

-- C4: which AV inputs are bound, for the Inputs row of a later stage; the
-- protocol driver gets no OnBindingChanged for AV bindings (research
-- docs/syncbox-control4-research.md §1.3).
dispatch.proxy["BINDING_CHANGE_ACTION"] = function(_, params)
	local id = num.int(params.BINDING_ID, 1000, 4999)
	if not id then
		return log.debug("BINDING_CHANGE_ACTION without a binding id in range")
	end
	local bound = tostring(params.IS_BOUND):lower()
	st.av_bound[id] = bound == "true" or bound == "1"
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
			refresh_box_rows()
		elseif msg.kind == "area" then
			-- The box reads its own state at once; nothing else changes (C5).
			log.debug("area %s %s (%s): reading the box", msg.id, msg.status, msg.streamer)
			if trusted() and not st.trouble then
				m.poller:soon("bridge hint")
			end
		end
	end)
end

dispatch.commands["HUE_SYNCBOX_CONFIGURE"] = from_bridge("HUE_SYNCBOX_CONFIGURE")
dispatch.commands["HUE_SYNCBOX_AREA"] = from_bridge("HUE_SYNCBOX_AREA")

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

-- #492 (I-5, I-6): a release build locks Composer's Lua command window and
-- refuses a dev loop left behind by an earlier dev build (common/device.lua).
function OnDriverInit()
	dev.init()
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
	return creds
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
	if not st.paired then
		C4:PersistDeleteValue(K.OFFLINE_KEY)
	end
	st.bridge = dev.bound_bridge()
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
	if m.client then
		m.client:cancel_all()
	end
	dev.cancel_timers()
end
