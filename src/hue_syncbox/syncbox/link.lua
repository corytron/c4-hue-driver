-- The sync box's side of the HUE_SYNCBOX binding to the Hue Bridge driver
-- (2.0 beta stage 2, #534): docs/hdmi-sync-stage2-design.md §3.8, contracts
-- C5 of docs/hdmi-sync-contracts.md, research
-- docs/syncbox-architecture-research.md §1.5 and §3.1. The bridge's side is
-- src/hue_bridge/bridge/syncboxes.lua. Stage 4 (#568,
-- docs/hdmi-sync-stage4-design.md §1.6 and §6) adds the sync state and the
-- take-over (O12, design §7.3) with research W10's guard
-- (docs/syncbox-wirings-research.md §5: two boxes of this project never take
-- a stream from each other).
--
--   box → bridge   HUE_SYNCBOX_HELLO     { device_id, box_id, bridge_id, area_id,
--                                          syncing ("true"/"false") }
--                  HUE_SYNCBOX_STATE     { device_id, box_id, bridge_id, area_id,
--                                          syncing }: the sync state changed, or
--                                          the bridge said a stream started or
--                                          stopped (AREA)
--                  HUE_SYNCBOX_STOP_AREA { device_id, box_id, bridge_id, area_id }:
--                                          the box was refused with code 16, stop
--                                          the stream on area_id (O12)
--                  HUE_SYNCBOX_GOODBYE   { device_id, box_id }
--   bridge → box   HUE_SYNCBOX_CONFIGURE { bridge_id, match ("true"/"false"),
--                                          areas (a JSON list of { id, name, type,
--                                          status, lamps, rooms }) }
--                  HUE_SYNCBOX_AREA      { id, status ("active"/"inactive"),
--                                          streamer ("this_box"/"other"/"none") }
--                  HUE_SYNCBOX_STOPPED   { area_id, ok ("true"/"false"), reason,
--                                          by, detail }: the answer to a STOP_AREA
--                  HUE_SYNCBOX_ASK_HELLO { }: the bridge has no hello from this
--                                          device (it restarted alone); the driver
--                                          answers with l:hello(...), syncing included
--
-- STOPPED's reasons: "stopped" (ok: the bridge PUT `action: stop` on the area
-- with its own key), "another_box" (a bound box of this project reports
-- itself syncing to that area, W10; `by` is its Composer name), "no_area"
-- (the bridge has no such area), "not_linked" (the box's bridge is not that
-- bridge, or the bridge is not paired), "failed" (the bridge's request
-- failed; `detail` says why), "busy" (too many stops waiting on the bridge).
--
-- Every parameter is a string, as in every message between these drivers
-- (contracts C5). `device_id` is not in C5's table: Control4 tells a driver
-- nothing about who sent a message (SECURITY.md, "Trust boundaries", #483),
-- so the box names its own device, as the lights' and the sensors' hellos
-- do, and the bridge answers only a device Director shows bound on its
-- "Hue Sync Boxes" connection. A value this side does not hold (no box id
-- before the first identity check, no bridge, area or sync state before the
-- first read) is left out: C4:SendToDevice drops empty values anyway
-- [verified: API 32_serial_network_device/_19-SendToDevice, allowEmptyValues].
--
-- The trust rule (#483; research §3.1): a message from the bridge is only a
-- hint. received() checks every value and hands back a plain table; the
-- driver then reads the box over its pinned connection, and the box's own
-- answer is the only source of its state. A malformed message is dropped
-- with one debug line, and so is a STOPPED for an area this box did not ask
-- about. ASK_HELLO carries nothing to check: its answer is the hello the box
-- sends at every binding anyway. Nothing here carries the box's token or the bridge's key: the
-- bridge stops a stream with its own key, and STOPPED only says whether it
-- did (contracts C5).
--
-- Interface (contract §3.8; stage 4 §6):
--   l = link.new{ send, log, device_id, decode }
--     send(binding_id, command, params)  C4:SendToDevice to the device bound on
--                                        `binding_id`, through the driver; false
--                                        (or a raise) when nothing went out
--     log                                common.log look-alike (default common.log)
--     device_id()                        optional: this device's id (default
--                                        C4:GetDeviceID() [verified: API 22/_7])
--     decode(text)                       optional: JSON text → value, or nil and an
--                                        error (default common.https.decode, which
--                                        runs C4:JsonDecode under pcall)
--   l:hello(box_id, bridge_id, area_id, syncing)
--                                        HUE_SYNCBOX_HELLO on binding 1; true when sent.
--                                        `syncing` is the model's (true or false; nil
--                                        while unknown, then left out)
--   l:update(box_id, bridge_id, area_id, syncing)
--                                        after each read: the hello again when the box,
--                                        its bridge or its area changed since the last
--                                        one sent; else HUE_SYNCBOX_STATE when `syncing`
--                                        changed, or once after an AREA (the bridge
--                                        waits for every box's word after a stream
--                                        starts); true when either went out
--   l:stop_area(area_id, box_id, bridge_id)
--                                        HUE_SYNCBOX_STOP_AREA on binding 1 (O12); false,
--                                        sending nothing, when area_id is no area id;
--                                        true when sent. The answer is a STOPPED
--   l:goodbye(box_id)                    HUE_SYNCBOX_GOODBYE on binding 1; true when sent
--   l:reset()                            forget the last hello and the stops asked for
--                                        (an unbind: the next binding's hello goes out
--                                        whatever it says)
--   l:received(command, params)          → a checked table, or nil:
--     { kind = "configure", bridge_id, match, areas = { { id, name, type, status,
--       lamps, rooms = { name... } }... } }
--     { kind = "area", id, status, streamer }
--     { kind = "stopped", area_id, ok (a boolean), reason, by (or nil), detail (or nil) }
--     { kind = "ask_hello" }             whatever its parameters: answer with l:hello
--   link.handles(command)                true for the four messages received() reads
--   link.box_id(v), link.bridge_id(v), link.area_id(v)   the checks, for the driver
--
-- When the driver sends the hello (contract §3.8): at late init, on binding,
-- when the bridge asks (ASK_HELLO), and whenever its box's area or bridge id
-- changes (l:update after each read, which sends STATE instead when only the
-- sync state changed).

local num = require("common.num")
local https = require("common.https")
local log = require("common.log")

local link = {}
link.__index = link

-- The box's consumer connection to the bridge (contracts C1.2).
link.BINDING = 1
link.CLASS = "HUE_SYNCBOX"

link.HELLO = "HUE_SYNCBOX_HELLO"
link.STATE = "HUE_SYNCBOX_STATE"
link.STOP_AREA = "HUE_SYNCBOX_STOP_AREA"
link.GOODBYE = "HUE_SYNCBOX_GOODBYE"
link.CONFIGURE = "HUE_SYNCBOX_CONFIGURE"
link.AREA = "HUE_SYNCBOX_AREA"
link.STOPPED = "HUE_SYNCBOX_STOPPED"
link.ASK_HELLO = "HUE_SYNCBOX_ASK_HELLO"

-- Bounds (research §3.2): ids at most 64 characters, at most 64 areas kept,
-- the rooms of an area at most 32 (a Control4 project with more rooms under
-- one entertainment area is not a real one), a lamp count within 0..255 (an
-- entertainment area streams to at most a few dozen lamps), and the areas
-- text refused before decoding beyond 64 KB (64 areas of 32 long room names
-- stay well within it).
link.ID_MAX = 64
link.AREAS_MAX = 64
link.ROOMS_MAX = 32
link.LAMPS_MAX = 255
link.AREAS_TEXT_MAX = 65536

-- The box id: 12 hex digits, compared upper case (research §3.2).
link.BOX_ID_LEN = 12

-- The stops asked for and not yet answered that are kept (the driver asks at
-- most once per sync start; the oldest goes first), and the most bytes of a
-- STOPPED's detail and of another box's name kept.
link.ASKED_MAX = 4
link.DETAIL_MAX = 120

-- The values an area's fields may take; any other type reads "other", any
-- other status "inactive" (the bridge's hue_model rules).
local KINDS = { screen = true, monitor = true, music = true, ["3dspace"] = true, other = true }
local STATUSES = { active = true, inactive = true }
local STREAMERS = { this_box = true, other = true, none = true }

-- STOPPED's reasons when ok is false; any other reads "failed".
local REFUSALS = { another_box = true, no_area = true, not_linked = true, failed = true, busy = true }

local RECEIVED = { [link.CONFIGURE] = true, [link.AREA] = true, [link.STOPPED] = true, [link.ASK_HELLO] = true }

function link.handles(command)
	return RECEIVED[command] == true
end

-- The box id upper-cased when `v` is 12 hex digits, else nil.
function link.box_id(v)
	if type(v) == "string" and #v == link.BOX_ID_LEN and v:find("^%x+$") then
		return v:upper()
	end
	return nil
end

-- A Hue bridge id lower-cased when `v` is hex digits only (16 on every Hue
-- bridge: the box's hue.bridgeUniqueId and the bridge's own id compare in
-- lower case, docs/syncbox-api-research.md §6 item 10), at most ID_MAX, else nil.
function link.bridge_id(v)
	if type(v) == "string" and #v <= link.ID_MAX and v:find("^%x+$") then
		return v:lower()
	end
	return nil
end

-- An entertainment area id lower-cased when `v` is hex digits and "-" only
-- (a CLIP v2 entertainment_configuration id is a UUID, and the box's
-- execution.hueTarget names one with a CLIP v2 bridge,
-- docs/syncbox-api-research.md §2.6), at most ID_MAX, else nil. Such an id
-- never reaches a request path from here: the box writes only an area id it
-- reported itself (research §3.2, D-2).
function link.area_id(v)
	if type(v) == "string" and #v <= link.ID_MAX and v:find("^[%x%-]+$") then
		return v:lower()
	end
	return nil
end

-- The sync state as the messages carry it: "true" or "false"; nil while unknown.
local function syncing_text(v)
	if v == true or v == "true" then
		return "true"
	elseif v == false or v == "false" then
		return "false"
	end
	return nil
end

local function default_device_id()
	if type(C4) == "table" and type(C4.GetDeviceID) == "function" then
		return C4:GetDeviceID()
	end
	return nil
end

function link.new(deps)
	deps = deps or {}
	assert(type(deps.send) == "function", "link.new: deps.send is required")
	return setmetatable({
		send_fn = deps.send,
		log = deps.log or log,
		device_id_fn = deps.device_id or default_device_id,
		decode = deps.decode or https.decode,
		last = nil,       -- { box_id, bridge_id, area_id, syncing } of the last hello or state sent
		recheck = false,  -- an AREA came: the next update() sends STATE even when nothing changed
		asked = {},       -- the area ids of the stops asked for and not answered, oldest first
	}, link)
end

-- This device's id as a decimal string, or nil when it is unknown.
function link:own_id()
	local ok, id = pcall(self.device_id_fn)
	local n = ok and num.int(id, 1) or nil
	if n == nil then
		return nil
	end
	return string.format("%d", n)
end

-- One message on binding 1; true when the driver's send went through.
function link:send(command, params)
	local ok, sent = pcall(self.send_fn, link.BINDING, command, params)
	if not ok then
		self.log.warn("Hue Bridge link: %s failed: %s", command, https.peer_text(sent))
		return false
	end
	if sent == false then
		self.log.debug("Hue Bridge link: %s not sent (no Hue Bridge bound)", command)
		return false
	end
	return true
end

-- `value` through `check`, or nil; a value given that fails is named in one
-- debug line (it is left out of `command`).
function link:checked(command, what, value, check)
	if value == nil or value == "" then
		return nil
	end
	local out = check(value)
	if out == nil then
		self.log.debug("Hue Bridge link: the %s %s is left out of %s: not an id", what, https.peer_text(value, 80),
			command)
	end
	return out
end

-- The params every message but the goodbye starts from: this device, the
-- box, its bridge and (unless nil) an area, each checked.
function link:params(command, box_id, bridge_id, area_id)
	return {
		device_id = self:own_id(),
		box_id = self:checked(command, "box id", box_id, link.box_id),
		bridge_id = self:checked(command, "bridge id", bridge_id, link.bridge_id),
		area_id = self:checked(command, "area id", area_id, link.area_id),
	}
end

function link:hello(box_id, bridge_id, area_id, syncing)
	local params = self:params(link.HELLO, box_id, bridge_id, area_id)
	params.syncing = syncing_text(syncing)
	if not self:send(link.HELLO, params) then
		return false
	end
	self.last = { box_id = params.box_id, bridge_id = params.bridge_id, area_id = params.area_id,
		syncing = params.syncing }
	self.recheck = false
	return true
end

-- After each read: the hello again when the box's id, its bridge or its area
-- changed since the last one sent (or none was sent); else STATE when the
-- sync state is known and changed, or an AREA asked for it. True when either
-- went out.
function link:update(box_id, bridge_id, area_id, syncing)
	local last = self.last
	if not (last and last.box_id == link.box_id(box_id) and last.bridge_id == link.bridge_id(bridge_id)
		and last.area_id == link.area_id(area_id)) then
		return self:hello(box_id, bridge_id, area_id, syncing)
	end
	local text = syncing_text(syncing)
	if text == nil or (text == last.syncing and not self.recheck) then
		return false
	end
	local params = self:params(link.STATE, box_id, bridge_id, area_id)
	params.syncing = text
	if not self:send(link.STATE, params) then
		return false
	end
	last.syncing, self.recheck = text, false
	return true
end

-- Remember a stop asked for, so that only its answer is read (at most
-- ASKED_MAX; the oldest is forgotten first).
function link:ask(area_id)
	for i, id in ipairs(self.asked) do
		if id == area_id then
			table.remove(self.asked, i)
			break
		end
	end
	self.asked[#self.asked + 1] = area_id
	while #self.asked > link.ASKED_MAX do
		table.remove(self.asked, 1)
	end
end

-- True, and forgotten, when a stop of `area_id` was asked for.
function link:answered(area_id)
	for i, id in ipairs(self.asked) do
		if id == area_id then
			table.remove(self.asked, i)
			return true
		end
	end
	return false
end

-- The take-over (O12): ask the bridge to stop the stream on `area_id`.
function link:stop_area(area_id, box_id, bridge_id)
	local id = link.area_id(area_id)
	if not id then
		self.log.debug("Hue Bridge link: %s not sent: the area id %s is not one", link.STOP_AREA,
			https.peer_text(area_id, 80))
		return false
	end
	local params = self:params(link.STOP_AREA, box_id, bridge_id, nil)
	params.area_id = id
	if not self:send(link.STOP_AREA, params) then
		return false
	end
	self:ask(id)
	return true
end

function link:goodbye(box_id)
	self.last, self.recheck, self.asked = nil, false, {}
	return self:send(link.GOODBYE, {
		device_id = self:own_id(),
		box_id = self:checked(link.GOODBYE, "box id", box_id, link.box_id),
	})
end

function link:reset()
	self.last, self.recheck, self.asked = nil, false, {}
end

-- Receiving -------------------------------------------------------------------------

-- A decoded JSON list as a Lua array: a real array, or an object whose keys
-- are all whole numbers 1, 2, ... in text (C4:JsonEncode writes Lua arrays
-- as objects with string keys [verified: docs/design.md, "C4:url transfer
-- scheduling on OS 3.4.2"], so a list from a driver that encodes with it
-- arrives that way). At most `max` items, in key order, each key once. nil
-- for anything else (an object with any other key).
local function as_list(value, max)
	if type(value) ~= "table" then
		return nil
	end
	local keys = {}
	for key in pairs(value) do
		local n = type(key) == "number" and key or (type(key) == "string" and key:find("^%d+$") and tonumber(key))
		if not n or n < 1 or n ~= math.floor(n) then
			return nil
		end
		keys[#keys + 1] = n
	end
	table.sort(keys)
	local out, previous = {}, nil
	for _, n in ipairs(keys) do
		if #out >= max then
			break
		end
		if n ~= previous then
			local item = value[n]
			if item == nil then
				item = value[string.format("%d", n)]
			end
			out[#out + 1] = item
			previous = n
		end
	end
	return out
end

-- A text a peer sent, through https.peer_text (control characters out, at
-- most `max` bytes, default TEXT_ROW); nil when it is not a non-empty string.
local function text_of(value, max)
	if type(value) ~= "string" then
		return nil
	end
	local text = https.peer_text(value, max)
	return text ~= "" and text or nil
end

-- A name a peer sent (an area's, a room's): text_of at most TEXT_ROW bytes.
local function name_of(value)
	return text_of(value)
end

local function rooms_of(value)
	local out = {}
	for _, room in ipairs(as_list(value, link.ROOMS_MAX) or {}) do
		local name = name_of(room)
		if name then
			out[#out + 1] = name
		end
	end
	return out
end

-- One area of a CONFIGURE, or nil when its id or name is not one.
local function area_of(item)
	if type(item) ~= "table" then
		return nil
	end
	local id, name = link.area_id(item.id), name_of(item.name)
	if not id or not name then
		return nil
	end
	return {
		id = id,
		name = name,
		type = KINDS[item.type] and item.type or "other",
		status = STATUSES[item.status] and item.status or "inactive",
		lamps = num.int(item.lamps, 0, link.LAMPS_MAX, 0),
		rooms = rooms_of(item.rooms),
	}
end

-- nil and one debug line naming why the message was dropped.
function link:drop(command, why)
	self.log.debug("Hue Bridge link: %s dropped: %s (a bridge message is only a hint)", command, why)
	return nil
end

function link:configure(params)
	local match = params.match
	if match ~= "true" and match ~= "false" then
		return self:drop(link.CONFIGURE, "match is neither true nor false")
	end
	local bridge_id = nil
	if params.bridge_id ~= nil and params.bridge_id ~= "" then
		bridge_id = link.bridge_id(params.bridge_id)
		if not bridge_id then
			return self:drop(link.CONFIGURE, "its bridge id is not one")
		end
	elseif match == "true" then
		return self:drop(link.CONFIGURE, "a match without a bridge id")
	end
	local text = params.areas
	if text == nil or text == "" then
		text = "[]"
	elseif type(text) ~= "string" then
		return self:drop(link.CONFIGURE, "its areas are not text")
	elseif #text > link.AREAS_TEXT_MAX then
		return self:drop(link.CONFIGURE, string.format("its areas are over %d bytes", link.AREAS_TEXT_MAX))
	end
	local ok, decoded, err = pcall(self.decode, text)
	if not ok or decoded == nil then
		return self:drop(link.CONFIGURE, "its areas are not JSON: " .. https.peer_text(ok and err or decoded, 120))
	end
	local list = as_list(decoded, link.AREAS_MAX)
	if not list then
		return self:drop(link.CONFIGURE, "its areas are not a list")
	end
	local areas, skipped, seen = {}, 0, {}
	for _, item in ipairs(list) do
		local area = area_of(item)
		if area and not seen[area.id] then
			seen[area.id] = true
			areas[#areas + 1] = area
		else
			skipped = skipped + 1
		end
	end
	if skipped > 0 then
		self.log.debug("Hue Bridge link: %s: %d area(s) without an id or a name left out", link.CONFIGURE, skipped)
	end
	return { kind = "configure", bridge_id = bridge_id, match = match == "true", areas = areas }
end

-- An AREA also has the next update() send STATE: after a stream starts or
-- stops the bridge waits for every box's word before it stops a stream for
-- another (W10), and labels the lamps after the box that says it syncs.
function link:area(params)
	local id = link.area_id(params.id)
	if not id then
		return self:drop(link.AREA, "its area id is not one")
	end
	if not STATUSES[params.status] then
		return self:drop(link.AREA, "its status is neither active nor inactive")
	end
	if not STREAMERS[params.streamer] then
		return self:drop(link.AREA, "its streamer is not this_box, other or none")
	end
	self.recheck = true
	return { kind = "area", id = id, status = params.status, streamer = params.streamer }
end

-- The answer to a STOP_AREA: ok true reads "stopped" whatever reason it
-- gives; a refusal with a reason this side does not know reads "failed".
function link:stopped(params)
	local id = link.area_id(params.area_id)
	if not id then
		return self:drop(link.STOPPED, "its area id is not one")
	end
	if params.ok ~= "true" and params.ok ~= "false" then
		return self:drop(link.STOPPED, "ok is neither true nor false")
	end
	if not self:answered(id) then
		return self:drop(link.STOPPED, "this box did not ask to stop that area")
	end
	local ok = params.ok == "true"
	return {
		kind = "stopped",
		area_id = id,
		ok = ok,
		reason = ok and "stopped" or (REFUSALS[params.reason] and params.reason or "failed"),
		by = text_of(params.by, link.DETAIL_MAX),
		detail = text_of(params.detail, link.DETAIL_MAX),
	}
end

function link:received(command, params)
	if not RECEIVED[command] then
		return nil
	end
	if command == link.ASK_HELLO then
		return { kind = "ask_hello" }
	end
	if type(params) ~= "table" then
		return self:drop(command, "no parameters")
	end
	if command == link.CONFIGURE then
		return self:configure(params)
	elseif command == link.STOPPED then
		return self:stopped(params)
	end
	return self:area(params)
end

return link
