-- The fake Hue Play HDMI Sync Box of the fake runtime (#534; a state machine
-- since #547). tests/helpers/fake_c4.lua requires it and keeps
-- fake.syncbox(opts) as the way in; M.new(opts) makes a box without a
-- runtime (on its own clock), for a runner that needs no C4:url.
--
-- What the box does is docs/syncbox-behaviour.md: rules SB1 to SB122, cited
-- below by number, each with its public source or marked [assumed] there.
-- The Python model (tools/fakebox/model.py) keeps the same rules, and both
-- fakes pass every scenario of tests/fixtures/syncbox_scenarios.json. The
-- contract is docs/fakebox-design.md (§2 the model, §4 the events); the
-- stage 2 handle (docs/hdmi-sync-stage2-design.md §7, contracts C8) is kept
-- as it was. R1 is docs/syncbox-api-research.md, R5
-- docs/syncbox-architecture-research.md.
--
--   local h = fake.syncbox(opts)
--     opts.address        "10.0.2.150" by default (F.ADDRESS)
--     opts.state          the GET /api/v1 body: a fixture (table) or its JSON
--                         text; F.state.HSB2 by default. Copied into h.state,
--                         the box's own: every answer is made from h.state as
--                         it is then, every write and event changes it, and a
--                         spec may change it too (as the Hue Sync app would).
--     opts.device         the GET /api/v1/device body without a token (table
--                         or text), copied into h.device. Without it h.device
--                         is nil and that answer is F.unkeyed_device(
--                         h.state.device), the identifying fields, at the time.
--     opts.button_held    false by default (h.button_held)
--     opts.registrations  the registrations the box knows, none by default:
--                         { ["7"] = "TEST-TOKEN-NOT-REAL" }, { ["7"] = { token,
--                         appName, instanceName, role } } or a list of pairing
--                         answers ({ F.registration_ok }). Kept as
--                         h.registrations[id] = { token, appName, instanceName, role }.
--
-- Requests (paths after https://<address>/api/v1; SB1 to SB21). A refusal is
-- F.error's body with its status: 2 (401) without a known token, 10 (404) a
-- path or method the box does not take, 12 a body that is not a JSON object,
-- 13 an empty body or a key the resource does not take, 15 a bad value, 16
-- the box's state; checked in that order, and a refused request changes
-- nothing (SB20, SB21). A write that succeeds answers 200 {} (SB11).
--   GET    /device                 without a token: h.device (above); with one,
--                                  h.state.device (SB12, SB14)
--   POST   /registrations          {appName, instanceName}: 16 until the
--                                  button (SB80 to SB83); the first id is "7"
--                                  with TEST-TOKEN-NOT-REAL, then one more than
--                                  the highest id listed or issued, with
--                                  TEST-TOKEN-NOT-REAL-<id>; one per press
--   DELETE /registrations/<id>     with its own token (SB86)
--   GET    "" and any object inside the state (SB1, SB2); registrations
--          list h.state's and h.registrations' with created, lastUsed and,
--          from API level 10, verified; never a token (SB8, SB84, SB88)
--   PUT    /execution              every field and command, in SB55's order,
--                                  judged whole (SB30 to SB56, SB91, SB97)
--   PUT    /behavior               box-wide settings and inputN objects (SB60
--                                  to SB64; no /behavior/inputN path)
--   PUT    /hdmi/<port>            name and type (SB100)
--   PUT    /device                 name and ledMode only (SB110, SB111)
--   PUT    /hue                    groupId only (SB95, SB96)
--   PUT    /hue/groups/<id>        {active: false} (SB94)
--   anything else                  404 (SB15; IR, presets beyond running one
--                                  and a bridge change are left out, §15)
--
-- What the box does by itself: h:event(name, args), args by name as the
-- scenarios write them (docs/syncbox-behaviour.md §12). It returns true when
-- the box acted, false when its state, a behavior flag or a port it lacks
-- made it ignore the event. An input is "input1".."input4", or 1..4.
--   button {[ms | window (s)]} the pairing window: 5000 ms (SB82); ignored
--                              while the box restarts. h:hold_button() holds
--                              the button without an end
--   cec_active_source {input}  SB70, then auto-sync (SB73)
--   hotplug {input}            SB71, then auto-sync (SB73)
--   signal {input, status}     input may be "output" too (SB72, SB73, SB74,
--                              SB78)
--   tv_standby, usb_power_lost SB75, SB76
--   idle {minutes}             SB77: one look, no timer (§12)
--   bridge {state[, group]}    SB90, SB92, SB93 (group: the other app's area,
--                              by default the box's)
--   rename {name}              SB112
--   app_deletes {registration} SB87 (an id; or {token = ...})
--   firmware {version, api_level[, build][, ms]}  SB121, SB122
--   reboot {[ms][, refuse]}    SB120: 30000 ms by default. Through C4:url a
--                              request then ends with curl 28 at its connect
--                              timeout (curl 7 at once with refuse)
--   advance {ms}               the clock moves: c4.advance(ms) on the box's
--                              runtime (its timers fire too), or the box's own
--   address {address}          SB114; the box then answers there (h:move)
--   operating_mode {mode}      bridge, standalone or uninitialized, on a box
--                              with hue.operatingMode; a sync stops [assumed;
--                              not in the scenarios]
-- Time arguments also take seconds (as the Python model's), for ms.
--
-- Faults of the transport (outside the scenarios, ST4), through
-- h:fault(name, args): args a table (or true) sets one, false clears it,
-- h:fault() clears all. In args: count (only the next count requests it
-- touches), method and path (only requests of that method, whose path after
-- /api/v1 starts with path). Names and defaults are the Python server's
-- (tools/fakebox/server.py):
--   refuse     connection refused: curl 7 at once
--   silence    see h:silence: curl 28 at the transfer's timeout
--   wrong_cert another CA's leaf: curl 60 whatever bundle verifies the box,
--              unless verification is off
--   drop       {code = 52 | 56, processed}: the connection closes with no
--              answer (curl 52 by default); with processed the box handled
--              the request first
--   latency    {ms = 1000}: the answer comes ms later on the fake clock, one
--              request at a time as a real box (ST2); a transfer whose
--              timeout comes first ends with curl 28, and the box still
--              handles the request at its time
--   other_id   {id = "0A1B2C3D4E60", state, registrations}: another box at the
--              address (its own state, by default a copy of this one's with
--              that uniqueId, and none of our registrations); h.other is it
--   5xx        {status = 500, code = 500, body}: that answer, the request not
--              handled [assumed body]; "http5xx" is the same fault
--   redirect   {status = 302, location = "https://<address>/redirected"}: a
--              3xx; C4:url follows it unless OnHeaders aborts [verified: SDK
--              35_url/_9-OnHeaders]: a fake box at the location answers on the
--              same transfer, anything else ends with curl 7, a sixth hop with
--              curl 47 [assumed]
--   truncated  {bytes, err_code = 18}: the body cut to bytes (half by default),
--              OnDone with err_code (0: a short body and no error)
--   oversized  {bytes = 300000}: the answer padded with a "padding" key to bytes
--
-- Before them, the transport: not https, or a port but 443: curl 7 (ST1);
-- the chain verifies with an ssl_cabundle ending in hsb_ca.pem and
-- ssl_verify_host false (the leaf names the box id, not the address, R5
-- §2.2), or with ssl_verify_peer false; otherwise curl 60. While
-- c4.tls_ignores_cabundle is set (an OS that ignores the bundle), every
-- request gets through, the decoy request included, which the box then
-- answers. In order: the scheme and port, refuse, a restart, silence, the
-- chain, wrong_cert, drop, h:defer, latency, the box (or other_id's), then
-- 5xx, redirect, truncated and oversized on its answer. Without a fault an
-- answer comes at once, inside Get()/Post()/Put()/Delete().
--
-- Time: the box runs on the clock of the runtime current at fake.syncbox
-- (c4.now_ms), or its own (M.new without one, from 0). The end of a restart
-- and of the button window are worked out lazily, at every request, event
-- and h:view(). Nothing of the box sits in c4.timers but the transport's own
-- timers of silence, latency and restarts (syncbox = true, no SetTimer call
-- recorded).
--
-- The handle:
--   h.state, h.device, h.registrations, h.button_held   as above
--   h.requests  every request to the box, in order: { method, url, path (the
--               URL's path, "/api/v1/device"), resource (after /api/v1:
--               "/device", "" for /api/v1, nil off the API), headers (a copy,
--               the Authorization value's token replaced by "<redacted>"),
--               body (the text sent), json (its decoding when a table, else
--               nil), keyed (an Authorization header was sent), authorized
--               (its token is registered), registration_id (whose), status
--               (the HTTP status answered; nil while none), err_code (curl's
--               code when it ended without an answer), fault (the fault or
--               "reboot" that touched it), other (other_id's box answered) }
--   h:requests_of(method, path)  those of a method and a path (the URL's path
--               or the resource); nil matches any
--   h:hold_button([ms]), h:release_button()  the link button (h.button_held):
--               held until a registration or the release, or for ms
--   h:silence(on)  on (true, the default): requests are recorded and not
--               answered; each ends with curl 28 when its timeout option
--               (seconds) has passed on the fake clock (c4.advance or
--               c4.fire_timers fire it). false: the box answers again
--   h:defer(on), h:answer(n)  on (true, the default): requests wait in
--               h.pending until h:answer(n) answers the first n (all by
--               default), in order, from h.state as it is then; it returns
--               how many (a transfer the driver cancelled is skipped)
--   h:move(address)  the box answers at another address (the ipAddress of
--               h.state.device and h.device follow)
--   h:event(name, args), h:fault(name, args)   above
--   h:request(method, path, headers, body)  the box's answer to one request
--               without a transfer or faults (the Python model's
--               box.request): path after /api/v1 ("" the whole state) or the
--               full path; headers a table; body a table (sent as JSON) or
--               text. Returns status, the body (a table) and the record (in
--               h.requests too); nil, nil, record while the box restarts
--   h:view()    a copy of the whole state as GET /api/v1 answers it (SB72's
--               masking, registrations without tokens), not a request (§12);
--               h:snapshot() is the same
--   h:value(path)  a value of the view by a dotted path ("execution.mode",
--               "hue.groups.<id>.active"); nil when absent
--   h:down()    whether the box is restarting
--   h:tick()    brings the box up to its clock; h:now() the clock (ms)
--
-- Boxes belong to the harness run: fake.install_c4 and fake.load_driver
-- forget them (M.reset), so make a box after the last of those. A second box
-- at an address replaces the first.

local json = require("dkjson")

local M = {}

M.PAIRING_WINDOW_MS = 5000     -- SB82
M.REBOOT_MS = 30000            -- SB120
M.DEFAULT_SPECS = "1920 x 1080 @ 60000 - SDR"   -- SB78
M.OTHER_APP = "other-app"      -- SB92's owner of another app's stream
M.OTHER_ID = "0A1B2C3D4E60"    -- other_id's box (a placeholder, CLAUDE.md)
M.OVERSIZED_BYTES = 300000     -- over the box client's 256 KB (max_body)
M.LATENCY_MS = 1000
M.MAX_HOPS = 5                 -- redirects C4:url follows [assumed: curl 47 after]

local boxes = {}   -- address -> handle; M.reset empties it

local fixtures
local function F()
	fixtures = fixtures or require("fixtures.hue_syncbox")
	return fixtures
end

-- Small helpers ---------------------------------------------------------------

local U = {}

function U.set(list)
	local out = {}
	for _, v in ipairs(list) do out[v] = true end
	return out
end

-- An empty JSON object, as dkjson writes it ({} rather than []).
function U.object()
	return setmetatable({}, { __jsontype = "object" })
end

-- A deep copy, keeping dkjson's object and array marks.
function U.copy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = U.copy(v)
	end
	return setmetatable(out, getmetatable(value))
end

-- Makes `into` hold exactly what `from` holds, in place (a spec may keep a
-- reference to h.state or to one of its tables).
function U.restore(into, from)
	for k in pairs(into) do
		if from[k] == nil then into[k] = nil end
	end
	for k, v in pairs(from) do
		if type(v) == "table" and type(into[k]) == "table" then
			U.restore(into[k], v)
			setmetatable(into[k], getmetatable(v))
		else
			into[k] = v
		end
	end
end

-- A body given as a table (copied) or as JSON text (decoded).
function U.body_table(value, what)
	if type(value) == "string" then
		local decoded, _, err = json.decode(value)
		assert(type(decoded) == "table", "fake.syncbox: " .. what .. " is not a JSON object: " .. tostring(err))
		return decoded
	end
	assert(type(value) == "table", "fake.syncbox: " .. what .. " should be a table or JSON text")
	return U.copy(value)
end

-- scheme, host, port (or nil) and path of a URL; nil for something else.
function U.parse_url(url)
	local scheme, rest = tostring(url):match("^(%a[%w+.%-]*)://(.*)$")
	if not scheme then
		return nil
	end
	local authority, path = rest:match("^([^/?#]*)([^?#]*)")
	authority = authority:match("^.*@(.*)$") or authority
	local host, port = authority:match("^(.-):(%d*)$")
	return scheme:lower(), host or authority, tonumber(port), path ~= "" and path or "/"
end

-- The path after /api/v1 ("" for /api/v1 itself), nil off the API.
function U.resource_of(path)
	if path == "/api/v1" then
		return ""
	end
	return path:match("^/api/v1(/.*)$")
end

function U.auth_header(headers)
	for name, value in pairs(headers or {}) do
		if type(name) == "string" and name:lower() == "authorization" then
			return name, tostring(value)
		end
	end
	return nil
end

function U.segments(resource)
	local out = {}
	for segment in (resource or ""):gmatch("[^/]+") do
		out[#out + 1] = segment
	end
	return out
end

function U.integer(v, lo, hi)
	return type(v) == "number" and v == math.floor(v) and v >= lo and v <= hi
end

function U.text(v)
	return type(v) == "string" and v:match("%S") ~= nil
end

-- The item after (or before) `current` in a list, wrapping; an unknown
-- current counts as the first item.
function U.cycle(list, current, direction)
	local here = 1
	for i, v in ipairs(list) do
		if v == current then here = i end
	end
	local step = direction == "previous" and -1 or 1
	return list[((here - 1 + step) % #list) + 1]
end

function U.error(name)
	local fx = F()
	return fx.error_status[name], U.copy(fx.error[name])
end

-- A refusal: raised inside a request (refuse), turned into its answer by
-- A.answer.
local Refusal = {}

local function refuse(name)
	error(setmetatable({ name = name }, Refusal), 0)
end

-- The values the box knows (R1 §2.6, §2.7, §2.9).
local V = {
	MODES = U.set({ "powersave", "passthrough", "video", "game", "music" }),
	SYNC = U.set({ "video", "game", "music" }),
	SYNC_ORDER = { "video", "music", "game" },   -- cycleSyncMode's order (SB38)
	OBJECTS = { "video", "game", "music" },
	INTENSITIES = { "subtle", "moderate", "high", "intense" },
	PALETTES = U.set({ "happyEnergetic", "happyCalm", "melancholicCalm", "melancholicEnergetic", "neutral" }),
	DIRECTIONS = U.set({ "next", "previous" }),
	PORT_TYPES = U.set({ "generic", "video", "game", "music", "xbox", "playstation", "nintendoswitch", "phone",
		"desktop", "laptop", "appletv", "roku", "shield", "chromecast", "firetv", "diskplayer", "settopbox",
		"satellite", "avreceiver", "soundbar", "hdmiswitch", "tv", "monitor", "beamer", "speaker", "hdmisplitter" }),
	PORT_STATUSES = U.set({ "unplugged", "plugged", "linked", "unknown" }),
	LINK_STATES = U.set({ "uninitialized", "disconnected", "connecting", "unauthorized", "connected",
		"invalidgroup", "streaming", "busy" }),
	OPERATING_MODES = U.set({ "bridge", "standalone", "uninitialized" }),
	-- behavior's ranges (SB60, SB61, SB62; hpdOutputEnableMs and any other
	-- [assumed]).
	BEHAVIOR_RANGES = {
		inactivePowersave = { 0, 10000 }, hdrMode = { 0, 2 }, hpdOutputEnableMs = { 0, 60000 },
		cecPowersave = { 0, 1 }, usbPowersave = { 0, 1 }, hpdInputSwitch = { 0, 1 }, arcBypassMode = { 0, 1 },
		soloMode = { 0, 1 }, forceDoviNative = { 0, 1 }, cecInputSwitch = { 0, 1 }, linkAutoSync = { 0, 1 },
		hpdInputPortSwitch = { 0, 1 },
	},
}
V.INTENSITY_SET = U.set(V.INTENSITIES)

-- The box's rules ----------------------------------------------------------------

local R = {}
local T = {}   -- the clock (below)

function R.exec(box)
	local e = box.state.execution
	if type(e) ~= "table" then
		e = {}
		box.state.execution = e
	end
	return e
end

function R.syncing(box)
	return V.SYNC[R.exec(box).mode] ~= nil
end

function R.port(box, name)
	local hdmi = box.state.hdmi
	return type(hdmi) == "table" and type(name) == "string" and type(hdmi[name]) == "table" and hdmi[name] or nil
end

-- "inputN" when the box has that input (not the output), else nil.
function R.input(box, name)
	return type(name) == "string" and name:match("^input%d+$") and R.port(box, name) and name or nil
end

-- The box's inputs, in order.
function R.inputs(box)
	local out = {}
	for n = 1, 9 do
		if R.port(box, "input" .. n) then out[#out + 1] = "input" .. n end
	end
	return out
end

function R.groups(box)
	local hue = box.state.hue
	return type(hue) == "table" and type(hue.groups) == "table" and hue.groups or {}
end

-- The key of hue.groups a hueTarget names: the key, or groups/<key> (SB48).
function R.area_key(box, target)
	if type(target) ~= "string" then return nil end
	local groups = R.groups(box)
	if groups[target] ~= nil then return target end
	local key = target:match("^groups/(.+)$")
	return key and groups[key] ~= nil and key or nil
end

function R.standalone(box)
	local hue = box.state.hue
	return type(hue) == "table" and hue.operatingMode == "standalone"
end

-- The status a port reads: a linked port reads plugged in powersave (SB72).
function R.reads(box, name)
	local port = R.port(box, name)
	if not port then return nil end
	if port.status == "linked" and R.exec(box).mode == "powersave" then return "plugged" end
	return port.status
end

-- The selected input when it and the output both read linked (SB73), else nil.
function R.linked_pair(box)
	local input = R.input(box, R.exec(box).hdmiSource)
	if input and R.reads(box, input) == "linked" and (not R.port(box, "output") or R.reads(box, "output") == "linked") then
		return input
	end
	return nil
end

-- The mode syncActive true starts: the selected input's lastSyncMode (SB32),
-- else the box's, else video [assumed].
function R.resume_mode(box)
	local e = R.exec(box)
	local port = R.port(box, e.hdmiSource)
	if port and V.SYNC[port.lastSyncMode] then return port.lastSyncMode end
	if V.SYNC[e.lastSyncMode] then return e.lastSyncMode end
	return "video"
end

-- The mode intensity and its kin change: the current sync mode, else
-- lastSyncMode (SB44), else video [assumed].
function R.settings_mode(box)
	local e = R.exec(box)
	if V.SYNC[e.mode] then return e.mode end
	return V.SYNC[e.lastSyncMode] and e.lastSyncMode or "video"
end

-- Whether the link takes a stream: connected or streaming, or standalone
-- (SB91, SB97).
function R.link_ok(box)
	local hue = box.state.hue
	if type(hue) ~= "table" or R.standalone(box) then
		return true
	end
	return hue.connectionState == "connected" or hue.connectionState == "streaming"
end

-- The bridge side, from the execution and another app's stream (box.foreign):
-- the box's area active while it syncs, streaming, connected again after
-- (SB6); the other app's area active with its owner (SB92); every other area
-- inactive (SB93). A standalone box stays out of hue (SB97). Put off while a
-- PUT applies (box.batch), so the whole PUT is judged on the link as it was.
function R.stream(box)
	local hue = box.state.hue
	if box.batch or type(hue) ~= "table" or R.standalone(box) then
		return
	end
	local e = R.exec(box)
	local syncing = V.SYNC[e.mode] ~= nil
	local mine = syncing and R.area_key(box, e.hueTarget) or nil
	for id, group in pairs(R.groups(box)) do
		if type(group) == "table" then
			local other = box.foreign ~= nil and id == box.foreign
			group.active = id == mine or other
			group.owner = other and M.OTHER_APP or nil
		end
	end
	if syncing then
		hue.connectionState = "streaming"
	elseif hue.connectionState == "streaming" then
		hue.connectionState = box.foreign and "busy" or "connected"
	end
end

-- hdmi.contentSpecs and the two flags from the selected input's link (SB78):
-- the fixture's signal while it reads linked, "" and false otherwise. Only
-- the fields the box has.
function R.refresh_signal(box)
	local hdmi = box.state.hdmi
	if type(hdmi) ~= "table" then return end
	local linked = R.reads(box, R.exec(box).hdmiSource) == "linked"
	local signal = box.signal
	if hdmi.contentSpecs ~= nil then hdmi.contentSpecs = linked and signal.specs or "" end
	if hdmi.videoSyncSupported ~= nil then hdmi.videoSyncSupported = linked and signal.video end
	if hdmi.audioSyncSupported ~= nil then hdmi.audioSyncSupported = linked and signal.audio end
end

-- The one way the mode changes: the fields that go with it follow (SB3 to
-- SB6, SB78).
function R.set_mode(box, mode)
	local e = R.exec(box)
	e.mode = mode
	e.syncActive = V.SYNC[mode] ~= nil
	if e.hdmiActive ~= nil or type(box.state.hdmi) == "table" then
		e.hdmiActive = mode ~= "powersave"
	end
	if V.SYNC[mode] then
		e.lastSyncMode = mode
		local port = R.port(box, e.hdmiSource)
		if port then port.lastSyncMode = mode end
	end
	R.refresh_signal(box)
	R.stream(box)
end

function R.stop_sync(box)
	if R.syncing(box) then R.set_mode(box, "passthrough") end
end

function R.power_on(box)
	if R.exec(box).mode == "powersave" then R.set_mode(box, "passthrough") end
end

function R.powersave(box)
	if R.exec(box).mode ~= "powersave" then R.set_mode(box, "powersave") end
end

-- The selected input; a syncing box keeps its mode, which becomes the new
-- input's lastSyncMode (SB39).
function R.switch_input(box, name)
	local e = R.exec(box)
	if e.hdmiSource == name then return end
	e.hdmiSource = name
	local port = R.port(box, name)
	if port and V.SYNC[e.mode] then port.lastSyncMode = e.mode end
	R.refresh_signal(box)
end

-- hueTarget as sent, groupId the key (SB7, SB48); an invalidgroup link
-- becomes connected (SB98); a running stream moves.
function R.set_area(box, target)
	R.exec(box).hueTarget = target
	local hue = box.state.hue
	if type(hue) == "table" then
		if hue.groupId ~= nil then hue.groupId = R.area_key(box, target) end
		if hue.connectionState == "invalidgroup" then hue.connectionState = "connected" end
	end
	R.stream(box)
end

-- Runs an event's change, then auto-sync (SB73): when the selected input and
-- the output read linked after it and did not for that input before, a box
-- in passthrough whose input has linkAutoSync 1 syncs in the input's
-- lastSyncMode, when the link takes a stream [assumed: silently not else].
function R.with_autosync(box, change)
	local before = R.linked_pair(box)
	local acted = change()
	local after = R.linked_pair(box)
	if after and after ~= before and R.exec(box).mode == "passthrough" then
		local b = box.state.behavior
		local flags = type(b) == "table" and type(b[after]) == "table" and b[after] or {}
		if flags.linkAutoSync == 1 and R.link_ok(box) then
			R.set_mode(box, R.resume_mode(box))
			acted = true
		end
	end
	return acted
end

-- Checks of request bodies (SB21: keys, then values) ------------------------------

local C = {}

function C.value(ok)
	if not ok then refuse("invalid_value") end
end

local EXEC_RULES = {
	mode = { "enum", V.MODES },
	syncActive = { "bool" },
	hdmiActive = { "bool" },
	hdmiSource = { "input" },
	hueTarget = { "area" },
	brightness = { "int", 0, 200 },
	incrementBrightness = { "int", -200, 200 },
	toggleSyncActive = { "bool" },
	toggleHdmiActive = { "bool" },
	cycleSyncMode = { "enum", V.DIRECTIONS },
	cycleHdmiSource = { "enum", V.DIRECTIONS },
	cycleIntensity = { "enum", V.DIRECTIONS },
	toggleSyncMode = { "enum", V.SYNC },
	intensity = { "enum", V.INTENSITY_SET },
	backgroundLighting = { "bool" },
	toggleBackgroundLighting = { "bool" },
	preset = { "preset" },
	video = { "object" },
	game = { "object" },
	music = { "object" },
}
-- Fields a box without HDMI (the camera, R1 §1.5) lacks [assumed: 13].
local EXEC_HDMI = U.set({ "hdmiActive", "hdmiSource", "toggleHdmiActive", "cycleHdmiSource" })
local MODE_OBJECT_RULES = {
	video = { intensity = { "enum", V.INTENSITY_SET }, backgroundLighting = { "bool" } },
	game = { intensity = { "enum", V.INTENSITY_SET }, backgroundLighting = { "bool" } },
	music = { intensity = { "enum", V.INTENSITY_SET }, palette = { "enum", V.PALETTES } },
}

-- 15 unless the value is right for its rule. A standalone box's area is
-- judged later, with 16 (SB97).
function C.rule(box, rule, value, key)
	local kind = rule[1]
	if kind == "bool" then
		C.value(type(value) == "boolean")
	elseif kind == "int" then
		C.value(U.integer(value, rule[2], rule[3]))
	elseif kind == "enum" then
		C.value(type(value) == "string" and rule[2][value] == true)
	elseif kind == "input" then
		C.value(R.input(box, value) ~= nil)
	elseif kind == "area" then
		C.value(R.standalone(box) or R.area_key(box, value) ~= nil)
	elseif kind == "preset" then
		local presets = box.state.presets
		C.value(type(value) == "string" and type(presets) == "table" and type(presets[value]) == "table")
	elseif kind == "object" then
		C.value(type(value) == "table" and next(value) ~= nil)
		local inner = MODE_OBJECT_RULES[key]
		for name, v in pairs(value) do
			C.rule(box, inner[name], v, name)
		end
	end
end

-- 13 for a key PUT /execution does not take, inside the mode objects too
-- (SB18, SB47).
function C.execution_keys(box, body)
	for key, value in pairs(body) do
		if EXEC_RULES[key] == nil or (EXEC_HDMI[key] and type(box.state.hdmi) ~= "table") then
			refuse("invalid_key")
		end
		if MODE_OBJECT_RULES[key] and type(value) == "table" then
			for name in pairs(value) do
				if not MODE_OBJECT_RULES[key][name] then refuse("invalid_key") end
			end
		end
	end
end

function C.execution_values(box, body)
	for key, value in pairs(body) do
		C.rule(box, EXEC_RULES[key], value, key)
	end
end

-- Writes ----------------------------------------------------------------------------

local W = {}

-- PUT /execution (SB30 to SB56): the whole PUT checked (keys, values, the
-- preset's stored change merged in as if sent with it, the PUT's own fields
-- winning, SB49), then applied in SB55's order, then judged on its result:
-- a sync mode the link cannot take is 16 (SB56, SB91).
function W.execution(box, body)
	C.execution_keys(box, body)
	C.execution_values(box, body)
	local preset
	if body.preset ~= nil then
		preset = box.state.presets[body.preset]
		local stored = type(preset.execution) == "table" and preset.execution or {}
		C.execution_keys(box, stored)
		if stored.preset ~= nil then refuse("invalid_value") end   -- a preset runs no preset (R1 §2.11)
		C.execution_values(box, stored)
		local merged = U.copy(stored)
		for k, v in pairs(body) do
			if k ~= "preset" then merged[k] = v end
		end
		body = merged
	end
	if R.standalone(box) and body.hueTarget ~= nil then
		refuse("invalid_state")   -- SB97
	end
	box.batch = true
	W.apply_execution(box, body)
	box.batch = nil
	if R.syncing(box) and not R.link_ok(box) then
		refuse("invalid_state")
	end
	R.stream(box)
	if preset then preset.lastUsed = T.now(box) end
end

-- SB55's order, steps 2 to 9 (the preset, step 1, is merged in).
function W.apply_execution(box, body)
	local e = R.exec(box)
	-- 2. power (SB34, SB35, SB36)
	if body.hdmiActive == true then
		R.power_on(box)
	elseif body.hdmiActive == false then
		R.powersave(box)
	end
	if body.toggleHdmiActive == true then
		if e.mode == "powersave" then R.power_on(box) else R.powersave(box) end
	end
	-- 3. input (SB39 to SB41)
	if body.hdmiSource ~= nil then R.switch_input(box, body.hdmiSource) end
	if body.cycleHdmiSource ~= nil then
		R.switch_input(box, U.cycle(R.inputs(box), e.hdmiSource, body.cycleHdmiSource))
	end
	-- 4. area (SB48)
	if body.hueTarget ~= nil then R.set_area(box, body.hueTarget) end
	-- 5. mode, toggleSyncMode, cycleSyncMode (SB30, SB31, SB37, SB38)
	if body.mode == "powersave" then
		R.powersave(box)
	elseif body.mode == "passthrough" then
		if e.mode == "powersave" then R.power_on(box) else R.stop_sync(box) end
	elseif body.mode ~= nil then
		R.set_mode(box, body.mode)
	end
	if body.toggleSyncMode ~= nil then
		if e.mode == body.toggleSyncMode then R.stop_sync(box) else R.set_mode(box, body.toggleSyncMode) end
	end
	if body.cycleSyncMode ~= nil then
		R.set_mode(box, U.cycle(V.SYNC_ORDER, R.settings_mode(box), body.cycleSyncMode))
	end
	-- 6. syncActive, toggleSyncActive (SB32, SB33, SB36)
	local sync = body.syncActive
	if body.toggleSyncActive == true then sync = not R.syncing(box) end
	if sync == true and not R.syncing(box) then
		R.set_mode(box, R.resume_mode(box))
	elseif sync == false then
		R.stop_sync(box)
	end
	-- 7. to 9.
	W.mode_settings(box, body)
	if body.brightness ~= nil then e.brightness = body.brightness end
	if body.incrementBrightness ~= nil then
		local current = U.integer(e.brightness, -math.huge, math.huge) and e.brightness or 100
		e.brightness = math.max(0, math.min(200, current + body.incrementBrightness))
	end
end

-- Steps 7 and 8: the mode objects (SB47; a palette goes in music's), then
-- intensity, cycleIntensity, backgroundLighting and its toggle on the
-- settings mode (SB44 to SB46).
function W.mode_settings(box, body)
	local e = R.exec(box)
	for _, name in ipairs(V.OBJECTS) do
		if body[name] ~= nil then
			if type(e[name]) ~= "table" then e[name] = {} end
			for k, v in pairs(body[name]) do e[name][k] = v end
		end
	end
	local mode = R.settings_mode(box)
	if type(e[mode]) ~= "table" then e[mode] = {} end
	local settings = e[mode]
	if body.intensity ~= nil then settings.intensity = body.intensity end
	if body.cycleIntensity ~= nil then
		settings.intensity = U.cycle(V.INTENSITIES, settings.intensity, body.cycleIntensity)
	end
	if body.backgroundLighting ~= nil or body.toggleBackgroundLighting == true then
		if mode == "music" then refuse("invalid_value") end   -- SB46
		if body.backgroundLighting ~= nil then settings.backgroundLighting = body.backgroundLighting end
		if body.toggleBackgroundLighting == true then settings.backgroundLighting = not settings.backgroundLighting end
	end
end

function W.behavior_value(key, value)
	local range = V.BEHAVIOR_RANGES[key] or { 0, 1000000 }
	C.value(U.integer(value, range[1], range[2]))
end

-- 13 for a key `target` (box-wide behavior or an input's) does not hold as a
-- setting.
function W.behavior_keys(target, body)
	for key in pairs(body) do
		if target[key] == nil or type(target[key]) == "table" then refuse("invalid_key") end
	end
end

-- PUT /behavior: box-wide settings and inputN objects (SB60 to SB64).
function W.behavior(box, body)
	local b = box.state.behavior
	local function is_input(key)
		return type(key) == "string" and key:match("^input%d+$") and type(b[key]) == "table"
	end
	for key, value in pairs(body) do
		if is_input(key) then
			if type(value) == "table" then W.behavior_keys(b[key], value) end
		elseif b[key] == nil or type(b[key]) == "table" then
			refuse("invalid_key")
		end
	end
	for key, value in pairs(body) do
		if is_input(key) then
			C.value(type(value) == "table" and next(value) ~= nil)
			for name, v in pairs(value) do W.behavior_value(name, v) end
		else
			W.behavior_value(key, value)
		end
	end
	for key, value in pairs(body) do
		if is_input(key) then
			for name, v in pairs(value) do b[key][name] = v end
		else
			b[key] = value
		end
	end
end

-- PUT /hdmi/<port>: name and type (SB100).
function W.hdmi(box, body, name)
	for key in pairs(body) do
		if key ~= "name" and key ~= "type" then refuse("invalid_key") end
	end
	if body.name ~= nil then C.value(U.text(body.name)) end
	if body.type ~= nil then C.value(V.PORT_TYPES[body.type] == true) end
	for key, value in pairs(body) do box.state.hdmi[name][key] = value end
end

-- PUT /device: name and ledMode (SB110, SB111).
function W.device(box, body)
	for key in pairs(body) do
		if key ~= "name" and key ~= "ledMode" then refuse("invalid_key") end
	end
	if body.name ~= nil then C.value(U.text(body.name)) end
	if body.ledMode ~= nil then C.value(U.integer(body.ledMode, 0, 2)) end
	for key, value in pairs(body) do box.state.device[key] = value end
	if body.name ~= nil and type(box.device) == "table" then box.device.name = body.name end
end

-- PUT /hue: groupId from level 10 (SB95); the bridge's keys are refused by
-- the fakes (SB96); 16 on a standalone box (SB97).
function W.hue(box, body)
	local hue = box.state.hue
	for key in pairs(body) do
		if key ~= "groupId" or hue.groupId == nil then refuse("invalid_key") end
	end
	C.rule(box, { "area" }, body.groupId)
	if R.standalone(box) then refuse("invalid_state") end
	R.set_area(box, body.groupId)
end

-- PUT /hue/groups/<id> {active: false} stops whoever streams there (SB94).
function W.hue_group(box, body, id)
	for key in pairs(body) do
		if key ~= "active" then refuse("invalid_key") end
	end
	C.value(body.active == false)
	if R.syncing(box) and R.area_key(box, R.exec(box).hueTarget) == id then
		R.stop_sync(box)
	elseif box.foreign == id then
		box.foreign = nil
		box.state.hue.connectionState = "connected"
		R.stream(box)
	end
end

-- The handler of a write: fn(box, body, arg) and its arg; nil: 404 (SB15).
function W.route(box, method, segments)
	if method ~= "PUT" then return nil end
	local s, top, sub = box.state, segments[1], segments[2]
	local n = #segments
	local function has(t, key) return type(t) == "table" and type(key) == "string" and type(t[key]) == "table" end
	if top == "execution" and n == 1 and type(s.execution) == "table" then
		return W.execution
	elseif top == "behavior" and n == 1 and type(s.behavior) == "table" then
		return W.behavior
	elseif top == "hdmi" and n == 2 and (sub == "output" or sub:match("^input%d+$")) and has(s.hdmi, sub) then
		return W.hdmi, sub
	elseif top == "device" and n == 1 and type(s.device) == "table" then
		return W.device
	elseif top == "hue" and n == 1 and type(s.hue) == "table" then
		return W.hue
	elseif top == "hue" and n == 3 and sub == "groups" and has(R.groups(box), segments[3]) then
		return W.hue_group, segments[3]
	end
	return nil
end

-- Registrations ----------------------------------------------------------------------

local REG = {}

-- The registrations as GET lists them (SB84): h.state's, then
-- h.registrations' with created, lastUsed and, from API level 10, verified;
-- never a token (SB8).
function REG.public(box)
	local out = U.object()
	for id, r in pairs(type(box.state.registrations) == "table" and box.state.registrations or {}) do
		out[id] = r
	end
	local d = box.state.device
	local level = type(d) == "table" and tonumber(d.apiLevel) or 0
	for id, r in pairs(box.registrations) do
		local times = box.reg_times[id] or {}
		out[id] = { appName = r.appName, instanceName = r.instanceName, role = r.role, created = times.created,
			lastUsed = times.lastUsed }
		if level >= 10 then out[id].verified = r.verified == true end
	end
	return out
end

-- The registration whose token this is, or nil.
function REG.owner(box, token)
	if token == nil then
		return nil
	end
	for id, r in pairs(box.registrations) do
		if r.token == token then
			return id
		end
	end
	return nil
end

-- The request's JSON object: not JSON or not an object: 12 (SB16); no body,
-- a blank or an empty one: 13 (SB17). An empty [] counts as empty too: a Lua
-- client's encoder writes an empty table so (dkjson does) [assumed].
function REG.json_body(rec)
	if rec.body == nil or tostring(rec.body):match("^%s*$") then
		refuse("invalid_key")
	end
	local body = rec.json
	if type(body) ~= "table" then
		refuse("invalid_json")
	end
	if next(body) == nil then
		refuse("invalid_key")
	end
	if (getmetatable(body) or {}).__jsontype == "array" then
		refuse("invalid_json")
	end
	return body
end

-- The next registration id: "7" first, then one more than the highest id
-- the box has listed or issued (SB83).
function REG.next_id(box)
	local highest = tonumber(F().REGISTRATION_ID) - 1
	local function see(id)
		local n = tonumber(id)
		if n and n > highest then highest = n end
	end
	for id in pairs(type(box.state.registrations) == "table" and box.state.registrations or {}) do see(id) end
	for id in pairs(box.registrations) do see(id) end
	see(box.highest_issued)
	return tostring(math.floor(highest) + 1)
end

-- POST /registrations (SB80 to SB83).
function REG.register(box, rec)
	local body = REG.json_body(rec)
	for key in pairs(body) do
		if key ~= "appName" and key ~= "instanceName" then refuse("invalid_key") end
	end
	C.value(U.text(body.appName) and U.text(body.instanceName))
	if not box.button_held then
		refuse("invalid_state")
	end
	local fx = F()
	local id = REG.next_id(box)
	local token = id == fx.REGISTRATION_ID and fx.TOKEN or (fx.TOKEN .. "-" .. id)
	if REG.owner(box, token) then token = fx.TOKEN .. "-" .. id end
	box.registrations[id] = { token = token, appName = body.appName, instanceName = body.instanceName, role = "user" }
	box.reg_times[id] = { created = T.now(box), lastUsed = T.now(box) }
	box.highest_issued = id
	box.button_held, box.button_until = false, nil
	return 200, { registrationId = id, accessToken = token }
end

-- DELETE /registrations/<id> with its own token (SB86).
function REG.unregister(box, rec, id)
	if not box.registrations[id] then
		local listed = type(box.state.registrations) == "table" and box.state.registrations[id]
		refuse(listed and "unauthorized" or "not_found")
	end
	if rec.registration_id ~= id then
		refuse("unauthorized")
	end
	box.registrations[id] = nil
	box.reg_times[id] = nil
	return 200, U.object()
end

-- Time ------------------------------------------------------------------------------

function T.now(box)
	if box.c4 and type(box.c4.now_ms) == "number" then
		return box.c4.now_ms
	end
	return box.own_ms
end

-- The end of a restart and of the button window, when the clock has passed
-- them.
function T.tick(box)
	local now = T.now(box)
	if box.down_until and now >= box.down_until then
		box.down_until, box.down_refuses = nil, nil
	end
	if box.button_until and now >= box.button_until then
		box.button_held, box.button_until = false, nil
	end
end

-- The answer to a request --------------------------------------------------------------

local A = {}

-- keyed, authorized and registration_id of a request, from its headers.
function A.authorize(box, rec, headers)
	local name, value = U.auth_header(headers)
	rec.keyed = name ~= nil
	local token = value and value:match("^%s*[Bb][Ee][Aa][Rr][Ee][Rr]%s+(%S+)%s*$")
	rec.registration_id = name and REG.owner(box, token) or nil
	rec.authorized = rec.registration_id ~= nil
end

function A.record(box, method, url, path, headers, body)
	local rec = { method = method, url = url, path = path, resource = U.resource_of(path), headers = {},
		body = body }
	local auth = U.auth_header(headers)
	for name, value in pairs(headers or {}) do
		-- The scheme ("Bearer ") stays; the token never reaches a record.
		rec.headers[name] = name == auth and ((tostring(value):match("^(%S+%s+)%S") or "") .. "<redacted>") or value
	end
	if type(body) == "string" and body ~= "" then
		local decoded = json.decode(body)
		rec.json = type(decoded) == "table" and decoded or nil
	end
	A.authorize(box, rec, headers)
	box.requests[#box.requests + 1] = rec
	return rec
end

-- The state as GET /api/v1 shows it: SB72's masking in powersave, the
-- registrations without tokens. Shares the state's tables but hdmi's.
function A.view(box)
	local view = {}
	for k, v in pairs(box.state) do
		view[k] = v
	end
	view.registrations = REG.public(box)
	local hdmi = box.state.hdmi
	if type(hdmi) == "table" and R.exec(box).mode == "powersave" then
		view.hdmi = {}
		for name, port in pairs(hdmi) do
			if type(port) == "table" and port.status == "linked" then
				local masked = {}
				for k, v in pairs(port) do masked[k] = v end
				masked.status = "plugged"
				view.hdmi[name] = masked
			else
				view.hdmi[name] = port
			end
		end
	end
	return view
end

function A.get(box, segments)
	local node = A.view(box)
	for _, segment in ipairs(segments) do
		if type(node) ~= "table" then
			refuse("not_found")
		end
		node = node[segment]
	end
	if type(node) ~= "table" then
		refuse("not_found")
	end
	return 200, node
end

-- A write, whole or not at all: the state and the box's own fields come back
-- as they were when it is refused (SB20).
local WRITE_FIELDS = { "foreign", "batch", "down_until", "down_refuses", "button_held", "button_until" }

function A.write(box, rec, handler, arg)
	local body = REG.json_body(rec)
	local saved, saved_box = U.copy(box.state), {}
	for _, k in ipairs(WRITE_FIELDS) do saved_box[k] = box[k] end
	local ok, result = pcall(handler, box, body, arg)
	if ok then
		return 200, U.object()
	end
	U.restore(box.state, saved)
	for _, k in ipairs(WRITE_FIELDS) do box[k] = saved_box[k] end
	error(result, 0)
end

-- The status and body (a table) the box answers to a recorded request.
function A.route(box, rec)
	local method, resource = rec.method, rec.resource
	if resource == nil then
		refuse("not_found")
	end
	if rec.keyed and not rec.authorized then
		refuse("unauthorized")
	end
	if rec.authorized and box.reg_times[rec.registration_id] then
		box.reg_times[rec.registration_id].lastUsed = T.now(box)   -- SB88
	end
	if method == "GET" and resource == "/device" and not rec.keyed then
		return 200, box.device or F().unkeyed_device(box.state.device or {})
	end
	if method == "POST" and resource == "/registrations" then
		return REG.register(box, rec)
	end
	if not rec.authorized then
		refuse("unauthorized")
	end
	local segments = U.segments(resource)
	if method == "GET" then
		return A.get(box, segments)
	elseif method == "DELETE" and #segments == 2 and segments[1] == "registrations" then
		return REG.unregister(box, rec, segments[2])
	end
	local handler, arg = W.route(box, method, segments)
	if handler then
		return A.write(box, rec, handler, arg)
	end
	refuse("not_found")
end

function A.answer(box, rec)
	local ok, status, body = pcall(A.route, box, rec)
	if ok then
		return status, body
	end
	if getmetatable(status) == Refusal then
		return U.error(status.name)
	end
	error(status, 0)
end

-- The box's answer, as the box is now (its time brought up to date first).
function A.respond_now(box, rec)
	T.tick(box)
	local status, body = A.answer(box, rec)
	rec.status = status
	return status, body
end

-- Events ---------------------------------------------------------------------------------

local E = {}

local function ms_of(args, default)
	if args.ms ~= nil then return tonumber(args.ms) end
	if args.seconds ~= nil then return tonumber(args.seconds) * 1000 end
	return default
end

-- "inputN" (or "output" where allowed) from inputN, N or "N"; nil when the
-- box lacks that port.
local function port_of(box, value, allow_output)
	local name = type(value) == "number" and ("input" .. value) or tostring(value)
	if name:match("^%d+$") then name = "input" .. name end
	if allow_output and name == "output" then
		return R.port(box, name) and name or nil
	end
	return R.input(box, name)
end

local function input_flags(box, input)
	local b = box.state.behavior
	return type(b) == "table" and type(b[input]) == "table" and b[input] or {}
end

function E.button(box, args)
	if box.down_until then
		return false
	end
	box.button_held = true
	local window = args.window ~= nil and tonumber(args.window) * 1000 or ms_of(args, M.PAIRING_WINDOW_MS)
	box.button_until = T.now(box) + window
	return true
end

-- A switch by itself (CEC, hot plug): wakes the box, selects the input
-- keeping the mode (SB70, SB71).
local function auto_switch(box, input)
	R.power_on(box)
	R.switch_input(box, input)
	return true
end

function E.cec_active_source(box, args)
	local input = port_of(box, args.input)
	if not input or input_flags(box, input).cecInputSwitch ~= 1 then
		return false
	end
	return R.with_autosync(box, function() return auto_switch(box, input) end)
end

function E.hotplug(box, args)
	local input = port_of(box, args.input)
	if not input then
		return false
	end
	return R.with_autosync(box, function()
		local port = R.port(box, input)
		if port.status ~= "plugged" and port.status ~= "linked" then
			port.status = "plugged"
			R.refresh_signal(box)
		end
		local b = box.state.behavior
		if (type(b) == "table" and b.hpdInputSwitch == 1) or input_flags(box, input).hpdInputPortSwitch == 1 then
			return auto_switch(box, input)
		end
		return false
	end)
end

function E.signal(box, args)
	assert(V.PORT_STATUSES[args.status], "h:event signal: status is one of unplugged, plugged, linked, unknown")
	local name = port_of(box, args.input, true)
	if not name then
		return false
	end
	return R.with_autosync(box, function()
		R.port(box, name).status = args.status
		R.refresh_signal(box)
		if name == R.exec(box).hdmiSource and args.status ~= "linked" then
			R.stop_sync(box)   -- SB74
		end
		return true
	end)
end

local function powersave_if(box, flag)
	local b = box.state.behavior
	if type(b) ~= "table" or b[flag] ~= 1 then
		return false
	end
	R.powersave(box)
	return true
end

function E.tv_standby(box)
	return powersave_if(box, "cecPowersave")
end

function E.usb_power_lost(box)
	return powersave_if(box, "usbPowersave")
end

-- SB77: one look at the idle minutes, no timer (§12).
function E.idle(box, args)
	local b = box.state.behavior
	local limit = type(b) == "table" and b.inactivePowersave or 0
	if R.exec(box).mode ~= "passthrough" or not U.integer(limit, 1, math.huge)
		or limit > (tonumber(args.minutes) or 0) then
		return false
	end
	local any_linked = false
	for _, input in ipairs(R.inputs(box)) do
		if R.reads(box, input) == "linked" then any_linked = true end
	end
	local output_linked = not R.port(box, "output") or R.reads(box, "output") == "linked"
	if any_linked and output_linked then
		return false
	end
	R.powersave(box)
	return true
end

-- SB90, SB92, SB93.
function E.bridge(box, args)
	local state = args.state
	assert(V.LINK_STATES[state], "h:event bridge: state is one of R1 §2.9's connection states")
	local hue = box.state.hue
	assert(type(hue) == "table", "h:event bridge: the box has no hue resource")
	local standalone = R.standalone(box)
	if state ~= "connected" and not standalone then
		R.stop_sync(box)
	end
	box.foreign = state == "busy" and (R.area_key(box, args.group) or R.area_key(box, R.exec(box).hueTarget)) or nil
	R.stream(box)
	hue.connectionState = (state == "connected" and R.syncing(box) and not standalone) and "streaming" or state
	return true
end

function E.rename(box, args)
	assert(type(args.name) == "string", "h:event rename: a name")
	box.state.device.name = args.name
	if type(box.device) == "table" then box.device.name = args.name end
	return true
end

function E.app_deletes(box, args)
	local id = args.registration or args.id
	if id == nil and args.token then id = REG.owner(box, args.token) end
	id = id ~= nil and tostring(id) or nil
	if id and box.registrations[id] then
		box.registrations[id] = nil
		box.reg_times[id] = nil
		return true
	end
	local listed = box.state.registrations
	if id and type(listed) == "table" and listed[id] ~= nil then
		listed[id] = nil
		return true
	end
	return false
end

-- The fields of an API level that a box crossing it gains (SB122).
local function level_fields(box, from, to)
	local s = box.state
	local d, hue, b = s.device, s.hue, s.behavior
	local model = type(d) == "table" and d.deviceType or ""
	if from < 10 and to >= 10 then
		if type(hue) == "table" and hue.groupId == nil then
			hue.groupId = R.area_key(box, R.exec(box).hueTarget) or R.exec(box).hueTarget or ""
		end
		if d.overheating == nil then d.overheating = false end
		if d.bluetooth == nil then d.bluetooth = true end
		for key, flags in pairs(type(b) == "table" and b or {}) do
			if tostring(key):match("^input%d+$") and type(flags) == "table" and flags.hpdInputPortSwitch == nil then
				flags.hpdInputPortSwitch = 0
			end
		end
		for _, r in pairs(type(s.registrations) == "table" and s.registrations or {}) do
			if type(r) == "table" and r.verified == nil then r.verified = false end
		end
	end
	if from < 14 and to >= 14 then
		if type(b) == "table" and b.soloMode == nil then b.soloMode = 0 end
		if (model == "HSB2" or model == "HSB3") and type(hue) == "table" and hue.operatingMode == nil then
			hue.operatingMode = "bridge"
		end
	end
end

-- SB121: the version, build and level, then a restart.
function E.firmware(box, args)
	local d = box.state.device
	assert(type(args.version) == "string", "h:event firmware: a version")
	d.firmwareVersion = args.version
	local a, b, c = args.version:match("^(%d+)%.(%d+)%.(%d+)")
	d.buildNumber = tonumber(args.build)
		or (a and (tonumber(a) * 1000000 + tonumber(b) * 10000 + tonumber(c) * 100)) or d.buildNumber
	if args.api_level ~= nil then
		local from = tonumber(d.apiLevel) or 0
		local to = tonumber(args.api_level)
		d.apiLevel = math.max(from, to)   -- a level never falls in the fakes
		level_fields(box, from, d.apiLevel)
	end
	if type(box.device) == "table" then
		box.device.firmwareVersion, box.device.buildNumber, box.device.apiLevel =
			d.firmwareVersion, d.buildNumber, d.apiLevel
	end
	return E.reboot(box, args)
end

-- SB120: nothing answers for a while, then the same state; the pairing
-- window closed.
function E.reboot(box, args)
	box.down_until = T.now(box) + ms_of(args, M.REBOOT_MS)
	box.down_refuses = args.refuse == true
	box.button_held, box.button_until = false, nil
	return true
end

function E.advance(box, args)
	local ms = ms_of(args, 0)
	if box.c4 and type(box.c4.advance) == "function" then
		box.c4.advance(ms)
	else
		box.own_ms = box.own_ms + ms
	end
	return true
end

function E.address(box, args)
	box:move(args.address)
	return true
end

function E.operating_mode(box, args)
	assert(V.OPERATING_MODES[args.mode], "h:event operating_mode: bridge, standalone or uninitialized")
	local hue = box.state.hue
	assert(type(hue) == "table" and hue.operatingMode ~= nil, "h:event operating_mode: the box has none")
	R.stop_sync(box)
	hue.operatingMode = args.mode
	return true
end

-- The transport --------------------------------------------------------------------------

local NET = {}

-- A timer of Director's (the transfer's runtime), not the driver's: no
-- SetTimer call is recorded.
function NET.timer(c4, ms, fn)
	ms = math.max(1, math.floor(ms))
	local timer = { delay = ms, repeating = false, active = true, armed_at = c4.now_ms, due = c4.now_ms + ms,
		syncbox = true }
	function timer:Cancel()
		self.active = false
	end
	timer.callback = fn
	table.insert(c4.timers, timer)
	return timer
end

-- Ends the transfer without an answer (once).
function NET.fail(t, rec, code, message)
	if t.cancelled or rec.ended then return end
	rec.ended = true
	rec.err_code = code
	if rec.timeout_timer then rec.timeout_timer:Cancel() end
	t:done(code, message)
end

-- curl 28 once the transfer's timeout (or connect timeout) has passed on the
-- fake clock.
function NET.time_out(c4, t, rec, connect)
	local s = tonumber(t.options.timeout) or 15
	if connect and tonumber(t.options.connect_timeout) then
		s = math.min(s, tonumber(t.options.connect_timeout))
	end
	rec.timeout_timer = NET.timer(c4, s * 1000, function()
		rec.timeout_timer = nil
		NET.fail(t, rec, 28, "Timeout was reached")
	end)
end

-- Whether the box's chain verifies with these transfer options.
function NET.tls_accepts(c4, options)
	if c4.tls_ignores_cabundle or options.ssl_verify_peer == false then
		return true
	end
	return type(options.ssl_cabundle) == "string" and options.ssl_cabundle:find("hsb_ca%.pem$") ~= nil
		and options.ssl_verify_host == false
end

-- A fault's args when it applies to this request, counting one use; nil
-- otherwise.
function NET.take(box, name, rec)
	local f = box.faults[name]
	if not f or (f.method and f.method ~= rec.method)
		or (f.path and not (rec.resource and rec.resource:sub(1, #f.path) == f.path)) then
		return nil
	end
	if f.count then
		f.count = f.count - 1
		if f.count <= 0 then box.faults[name] = nil end
	end
	rec.fault = name
	return f
end

-- The box that answers at the address: this one, or other_id's.
function NET.answering(box, rec)
	local f = NET.take(box, "other_id", rec)
	if not f then
		return box
	end
	if not box.other then
		local state = f.state and U.body_table(f.state, "other_id state") or U.copy(box.state)
		state.device = state.device or {}
		state.device.uniqueId = f.id or M.OTHER_ID
		state.device.ipAddress = box.address
		box.other = M.new({ address = box.address, state = state, registrations = f.registrations or {} },
			box.c4, true)
	end
	rec.other = true
	return box.other
end

-- The answer, with the answer faults, on the transfer.
function NET.deliver(box, c4, t, rec, hops)
	if t.cancelled or rec.ended then return end
	if rec.timeout_timer then rec.timeout_timer:Cancel() end
	T.tick(box)
	if box.down_until then
		-- The box went down while the request waited.
		return NET.fail(t, rec, 52, "Server returned nothing (no headers, no data)")
	end
	rec.ended = true
	local headers = { ["Content-Type"] = "application/json" }
	local f = NET.take(box, "5xx", rec)
	if f then
		rec.status = f.status or 500
		local body = f.body or { code = f.code or rec.status, message = "Internal Server Error" }   -- [assumed]
		return t:respond(rec.status, type(body) == "string" and body or json.encode(body), headers)
	end
	f = NET.take(box, "redirect", rec)
	if f then
		rec.status = f.status or 302
		local location = f.location or ("https://" .. box.address .. "/redirected")
		t:respond_headers(rec.status, { Location = location })
		if t.aborted then
			return t:done(-1, nil)
		end
		return NET.follow(c4, t, rec, location, (hops or 0) + 1)
	end
	local target = NET.answering(box, rec)
	if target ~= box then
		A.authorize(target, rec, t.headers)
	end
	local status, body = A.respond_now(target, rec)
	local text = json.encode(body)
	f = NET.take(box, "truncated", rec)
	if f then
		local response = t:respond_headers(status, headers)
		local cut = text:sub(1, tonumber(f.bytes) or math.floor(#text / 2))
		if not t.aborted then
			if t.callbacks.chunk then t:chunk(cut) else response.body = cut end
		end
		return t:done(t.aborted and -1 or (f.err_code or 18), "Transferred a partial file")
	end
	f = NET.take(box, "oversized", rec)
	if f and type(body) == "table" then
		local bytes = tonumber(f.bytes) or M.OVERSIZED_BYTES
		local padded = U.copy(body)
		padded.padding = ""
		local short = bytes - #json.encode(padded)
		if short > 0 then padded.padding = ("x"):rep(short) end
		text = json.encode(padded)
	end
	t:respond(status, text, headers)
end

-- C4:url follows a redirect by itself [verified: SDK 35_url/_9-OnHeaders]: a
-- fake box at the location answers on the same transfer.
function NET.follow(c4, t, from, location, hops)
	if hops > M.MAX_HOPS then
		from.err_code = 47
		return t:done(47, "Number of redirects hit maximum amount")
	end
	local scheme, host, port, path = U.parse_url(location)
	local box = host and boxes[host]
	if not box then
		from.err_code = 7
		return t:done(7, "Couldn't connect to server")
	end
	local status, method = from.status, t.method
	if status == 303 or (method == "POST" and (status == 301 or status == 302)) then
		method = "GET"   -- as curl does
	end
	local rec = A.record(box, method, location, path, t.headers, method == t.method and t.data or nil)
	rec.redirected_from = from.url
	return NET.route(box, c4, t, rec, scheme, port, hops)
end

-- The transport's checks and faults before the box (see the header's order).
function NET.route(box, c4, t, rec, scheme, port, hops)
	if scheme ~= "https" or (port ~= nil and port ~= 443) or NET.take(box, "refuse", rec) then
		return NET.fail(t, rec, 7, "Couldn't connect to server")
	end
	T.tick(box)
	if box.down_until then
		rec.fault = "reboot"
		if box.down_refuses then
			return NET.fail(t, rec, 7, "Couldn't connect to server")
		end
		return NET.time_out(c4, t, rec, true)
	end
	if NET.take(box, "silence", rec) then
		return NET.time_out(c4, t, rec, false)
	end
	if not NET.tls_accepts(c4, t.options) then
		return NET.fail(t, rec, 60, "SSL peer certificate or SSH remote key was not OK")
	end
	if not (c4.tls_ignores_cabundle or t.options.ssl_verify_peer == false) and NET.take(box, "wrong_cert", rec) then
		return NET.fail(t, rec, 60, "SSL peer certificate or SSH remote key was not OK")
	end
	local drop = NET.take(box, "drop", rec)
	if drop then
		if drop.processed then A.respond_now(NET.answering(box, rec), rec) end
		rec.fault = "drop"
		local code = drop.code or 52
		return NET.fail(t, rec, code, code == 52 and "Server returned nothing (no headers, no data)"
			or "Failure when receiving data from the peer")
	end
	if box.deferred then
		box.pending[#box.pending + 1] = { transfer = t, request = rec, c4 = c4 }
		return
	end
	local latency = NET.take(box, "latency", rec)
	if latency then
		local now = c4.now_ms
		local due = math.max(now, box.busy_until or now) + (tonumber(latency.ms) or M.LATENCY_MS)
		box.busy_until = due
		NET.time_out(c4, t, rec, false)
		NET.timer(c4, math.max(1, due - now), function()
			if t.cancelled then return end
			if rec.ended then
				-- The client gave up; the box still handles the request.
				A.respond_now(NET.answering(box, rec), rec)
				return
			end
			NET.deliver(box, c4, t, rec, hops)
		end)
		return
	end
	return NET.deliver(box, c4, t, rec, hops)
end

-- A started transfer to a box's address: the box takes it (true), or nil.
function M.route(c4, t)
	local scheme, host, port, path = U.parse_url(t.url)
	local box = host and boxes[host]
	if not box then
		return nil
	end
	local rec = A.record(box, t.method, t.url, path, t.headers, t.data)
	NET.route(box, c4, t, rec, scheme, port, 0)
	return true
end

-- The handle ------------------------------------------------------------------------------

local Box = {}
Box.__index = Box

function Box:hold_button(ms)
	self.button_held = true
	self.button_until = ms and (T.now(self) + ms) or nil
end

function Box:release_button()
	self.button_held, self.button_until = false, nil
end

function Box:silence(on)
	self:fault("silence", on ~= false)
end

function Box:defer(on)
	self.deferred = on ~= false
end

function Box:answer(n)
	local answered = 0
	local count = math.min(tonumber(n) or #self.pending, #self.pending)
	for _ = 1, count do
		local p = table.remove(self.pending, 1)
		if not p.transfer.cancelled then
			NET.deliver(self, p.c4, p.transfer, p.request, 0)
			answered = answered + 1
		end
	end
	return answered
end

function Box:move(address)
	assert(type(address) == "string" and address ~= "", "h:move: an address")
	if boxes[self.address] == self then
		boxes[self.address] = nil
	end
	self.address = address
	boxes[address] = self
	if type(self.state.device) == "table" then self.state.device.ipAddress = address end
	if type(self.device) == "table" then self.device.ipAddress = address end
end

function Box:requests_of(method, path)
	local out = {}
	for _, r in ipairs(self.requests) do
		if (method == nil or r.method == method) and (path == nil or r.path == path or r.resource == path) then
			out[#out + 1] = r
		end
	end
	return out
end

function Box:event(name, args)
	local fn = E[name]
	assert(fn, "h:event: unknown event " .. tostring(name))
	args = args or {}
	T.tick(self)
	local acted = fn(self, args)
	T.tick(self)
	return acted
end

local FAULTS = U.set({ "refuse", "silence", "latency", "5xx", "drop", "truncated", "oversized", "redirect",
	"wrong_cert", "other_id" })

function Box:fault(name, args)
	if name == nil or name == "none" then
		self.faults, self.silent, self.other = {}, false, nil
		return
	end
	if name == "http5xx" then name = "5xx" end
	assert(FAULTS[name], "h:fault: unknown fault " .. tostring(name))
	if args == false then
		self.faults[name] = nil
	else
		local f = {}
		for k, v in pairs(type(args) == "table" and args or {}) do f[k] = v end
		self.faults[name] = f
	end
	if name == "silence" then self.silent = self.faults.silence ~= nil end
	if name == "other_id" then self.other = nil end
end

function Box:request(method, path, headers, body)
	path = tostring(path or "")
	if path:sub(1, 7) ~= "/api/v1" then path = "/api/v1" .. path end
	if type(body) == "table" then body = json.encode(body) end
	local rec = A.record(self, method, "https://" .. self.address .. path, path, headers or {}, body)
	rec.ended = true
	T.tick(self)
	if self.down_until then
		rec.fault = "reboot"
		return nil, nil, rec
	end
	local status, answer = A.respond_now(self, rec)
	return status, U.copy(answer), rec
end

function Box:view()
	T.tick(self)
	return U.copy(A.view(self))
end
Box.snapshot = Box.view

function Box:value(path)
	local node = self:view()
	for part in tostring(path):gmatch("[^%.]+") do
		if type(node) ~= "table" then return nil end
		node = node[part]
	end
	return node
end

function Box:down()
	T.tick(self)
	return self.down_until ~= nil
end

function Box:tick()
	T.tick(self)
end

function Box:now()
	return T.now(self)
end

-- One of opts.registrations (see the header) into h.registrations.
local function add_registration(box, key, value)
	local fx = F()
	local id, r
	if type(value) == "table" then
		id = value.registrationId or value.id or key
		r = { token = value.token or value.accessToken, appName = value.appName, instanceName = value.instanceName,
			role = value.role }
	else
		id, r = key, { token = value }
	end
	id = tostring(id)
	assert(type(r.token) == "string" and r.token ~= "", "fake.syncbox: registration " .. id .. " has no token")
	box.registrations[id] = { token = r.token, appName = r.appName or fx.APP_NAME,
		instanceName = r.instanceName or "Control4", role = r.role or "user" }
	box.reg_times[id] = { created = T.now(box), lastUsed = T.now(box) }
end

-- A fake box (see the header): c4 the runtime whose clock it runs on (nil:
-- its own clock, from 0); hidden: not reachable at its address (other_id's
-- box).
function M.new(opts, c4, hidden)
	opts = opts or {}
	local fx = F()
	local box = setmetatable({
		address = opts.address or fx.ADDRESS,
		state = U.body_table(opts.state or fx.state.HSB2, "opts.state"),
		device = opts.device ~= nil and U.body_table(opts.device, "opts.device") or nil,
		button_held = opts.button_held == true,
		registrations = {},
		reg_times = {},
		requests = {},
		pending = {},
		silent = false,
		deferred = false,
		faults = {},
		c4 = c4,
		own_ms = 0,
	}, Box)
	assert(type(box.address) == "string" and box.address ~= "", "fake.syncbox: opts.address should be text")
	for key, value in pairs(opts.registrations or {}) do
		add_registration(box, key, value)
	end
	-- The signal a link shows (SB78): the fixture's, or the default.
	local hdmi = box.state.hdmi
	if type(hdmi) == "table" and U.text(hdmi.contentSpecs) then
		box.signal = { specs = hdmi.contentSpecs, video = hdmi.videoSyncSupported ~= false,
			audio = hdmi.audioSyncSupported ~= false }
	else
		box.signal = { specs = M.DEFAULT_SPECS, video = true, audio = true }
	end
	-- A link that reads busy at the start: another app streams to the area
	-- that reads active.
	local hue = box.state.hue
	if type(hue) == "table" and hue.connectionState == "busy" then
		for id, group in pairs(R.groups(box)) do
			if type(group) == "table" and group.active then box.foreign = id end
		end
	end
	if not hidden then
		boxes[box.address] = box
	end
	return box
end

M.events = E

-- The box at an address, or nil.
function M.at(address)
	return boxes[address]
end

-- A new harness run: no box.
function M.reset()
	boxes = {}
end

return M
