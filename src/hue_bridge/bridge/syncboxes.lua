-- The Hue Sync Box devices bound on the bridge's "Hue Sync Boxes" connection
-- (id 2, class HUE_SYNCBOX), and what the bridge tells them (2.0 beta stage
-- 2, #534): docs/hdmi-sync-stage2-design.md §6, contracts C5 and C6 of
-- docs/hdmi-sync-contracts.md, research docs/syncbox-architecture-research.md
-- §1.5, §3.1 and §4.2. The box's side is src/hue_syncbox/syncbox/link.lua.
-- Stage 4 (#568, docs/hdmi-sync-stage4-design.md §1.6 and §6) adds each
-- box's sync state and the take-over (O12, design §7.3) with research W10's
-- guard (docs/syncbox-wirings-research.md §5).
--
--   box → bridge   HUE_SYNCBOX_HELLO     { device_id, box_id, bridge_id, area_id, syncing }
--                  HUE_SYNCBOX_STATE     { device_id, box_id, bridge_id, area_id, syncing }
--                                          the box's sync state (after a change, and
--                                          after each AREA); a hello when the bridge
--                                          does not know the box as it says it is
--                  HUE_SYNCBOX_STOP_AREA { device_id, box_id, bridge_id, area_id }
--                                          stop the stream on area_id (O12)
--                  HUE_SYNCBOX_GOODBYE   { device_id, box_id }
--   bridge → box   HUE_SYNCBOX_CONFIGURE { bridge_id, match, areas }   the answer to a
--                                          hello, and to every box after each resync
--                  HUE_SYNCBOX_AREA      { id, status, streamer }      a stream starts or
--                                          stops on any area
--                  HUE_SYNCBOX_STOPPED   { area_id, ok, reason, by, detail }   the answer
--                                          to a STOP_AREA (reasons below)
--                  HUE_SYNCBOX_ASK_HELLO { }   a device bound on connection 2 the bridge
--                                          has no hello from: say hello (with the sync
--                                          state); the box answers with HELLO
--
-- Every parameter is a string (contracts C5). `areas` is a JSON list, written
-- here as a real array (C4:JsonEncode writes Lua arrays as objects with string
-- keys [verified: docs/design.md, "C4:url transfer scheduling on OS 3.4.2"]),
-- of { id, name, type, status, lamps, rooms }: `type` the area's
-- configuration type, `lamps` the number of its lamps, `rooms` the Control4
-- rooms its lamps are mapped to (design §6.1: derived, shown, never stored).
--
-- The trust rules (#483; SECURITY.md "Trust boundaries"; research §3.1):
-- Control4 tells a driver nothing about who sent a message, so a box names
-- its own device id, and the bridge answers only a device Director reports
-- bound on connection 2: the device's OnBindingChanged (Director's own
-- word, [verified: API 9/_12]) or the bound devices' lookup
-- (C4:GetBoundConsumerDevices [verified: API 32/_3]). A hello from any other
-- device waits, unanswered, until one of them shows it bound. Every value is
-- checked; a malformed message is dropped with one debug line. What a box is
-- told is only what it could read from its own box anyway (area names, lamp
-- counts, status), never the bridge's key. A box's hello or STATE only
-- names the box that streams to an area in the lamps' Status, which a forged
-- one could make wrong until the next word of the real box: neither writes
-- to Hue. STOP_AREA is the one message that does, and only as below: a
-- forged one can stop no more than a bound box could ask for (an existing
-- area, never one a box of this project says it syncs to), and every one is
-- logged with its sender (contracts C5).
--
-- The take-over (O12; contracts C5 STOP_AREA; research W10). A box refused
-- with code 16 (another app streams) asks the bridge to stop the stream on
-- an area. The bridge answers only a device Director shows bound on
-- connection 2 (any other is logged and not answered), and stops a stream
-- with its own key, which never travels, through the request path every
-- other write takes (deps.http: the driver's bridge_request, PUT
-- entertainment_configuration/<id> { action = "stop" }, research §2.1 and
-- check T6) only when:
--   - the box's bridge (the message's, else its hello's) is this one, and
--     this bridge is paired; else STOPPED "not_linked";
--   - the area exists on this bridge (its id taken from the bridge's own
--     list, never the message's text); else "no_area";
--   - no other bound box of this bridge that names the area (or that syncs
--     without naming one) reports itself syncing; else "another_box", with
--     `by` its Composer name (W10: two boxes of this project never take a
--     stream from each other). While such a box has not said it syncs, its
--     word may be on its way (both boxes started on one room's selection, or
--     a stream started on its area since it last spoke: on_stream then
--     forgets its "not syncing"), so the bridge waits TAKE_OVER_GRACE_S and
--     asks again before it writes.
-- Then "stopped" (the PUT answered 2xx), or "failed" with `detail` (the
-- request's error), or "busy" while MAX_STOPS areas wait already. Requests
-- for one area are answered together; a requester unbound meanwhile is not
-- answered. The bridge's model of the area's status does not decide: a stop
-- of an area that streams no more changes nothing, and a stale model must
-- not hold a take-over up.
--
-- Asking for hellos (#568): this driver keeps its boxes in memory only, so
-- after it restarts alone (a driver update that reaches the bridge after the
-- boxes) it knows none of them until each says hello again. At each resync
-- (configure_all) and when a device is bound on connection 2 it sends
-- ASK_HELLO to every device Director shows bound there that it has no hello
-- (nor a waiting one) from: once per device per run of this driver, again
-- after an unbind and a new binding, again after a send that raised. The
-- ask carries nothing, and the box's answer is the hello it sends anyway.
--
-- The label (contracts C7): the box of this bridge naming the area that
-- reports itself syncing; else the one whose sync state is unknown (an older
-- box, or a stream that started on its area since its last word); never a
-- box that reports itself not syncing; none when two are equally likely.
--
-- Interface (contract §6):
--   s = syncboxes.new(deps)
--   s:hello(params)            HUE_SYNCBOX_HELLO: record the box and answer CONFIGURE;
--                              true when answered
--   s:goodbye(params)          HUE_SYNCBOX_GOODBYE: forget the box; true when forgotten
--   s:binding_changed(binding, class, bound, other_id)
--                              OnBindingChanged; true when it was connection 2 (the
--                              caller then has nothing else to do with it). A device
--                              bound without a hello waiting is asked for one
--   s:configure_all()          after each resync: CONFIGURE to every bound box (and a
--                              waiting hello answered once its device shows bound), then
--                              ASK_HELLO to every bound device without a hello not asked
--                              yet; returns the number told CONFIGURE
--   s:on_stream(area, started) an area started or stopped streaming (the entertainment
--                              module's on_stream): AREA to every bound box; returns
--                              the number told
--   s:state(params)            HUE_SYNCBOX_STATE: the box's sync state; true when taken
--                              (as a hello when the box is unknown or names another box
--                              or bridge: answered as one)
--   s:stop_area(params)        HUE_SYNCBOX_STOP_AREA: the take-over above; true when the
--                              stop goes ahead (now or after the grace), false when it was
--                              refused (and answered) or ignored
--   s:stop()                   every take-over waiting is cancelled, unanswered
--                              (OnDriverDestroyed)
--   s:label_for(area_id)       the Composer name of the bound box of this bridge that
--                              streams to that area (the label rule above), else nil
--   s:boxes(), s:count(), s:areas_json()   for the specs and Diagnostics
--   syncboxes.stopped_text(area_name, box_names)   the bridge's Last Action after a stop
--
-- deps (send required; the rest optional):
--   send(device_id, command, params)   one message to a device (the driver's device_send)
--   bridge_id()                this bridge's id, or nil while unpaired
--   areas()                    the entertainment areas (bridge/entertainment.lua areas():
--                              { id, name, kind, status, lamps = { rid... }, streaming })
--   lights                     the bridge.lights instance, or a function returning it, for
--                              the rooms: its models, hue_room_of, room_mapping, project
--   rooms_for(lamps)           instead of `lights`: the Control4 room names of these lamps
--   bound()                    the devices bound on connection 2, as
--                              C4:GetBoundConsumerDevices answers ({ [id] = name }, or nil)
--   display_name(device_id)    the box device's Composer name
--   on_labels_changed(rids)    who streams to these lamps changed (a box said hello, left,
--                              moved to another area or said it syncs or not, while the
--                              area streams): their devices' stream label and the
--                              Entertainment Areas row
--   http(req, cb)              the take-over's PUT: req = { method, path, body }; the driver
--                              adds the address and the key (bridge_request); cb(result)
--                              with result.ok, result.err, result.code. Without it every
--                              take-over is answered "failed"
--   set_timer(delay_ms, fn)    C4:SetTimer(delay_ms, fn) [verified: API 34/_1], an object
--                              with Cancel(); the default calls C4:SetTimer
--   on_stopped(text)           optional: the bridge's Last Action after a stop
--   log                        common.log look-alike
--
-- on_stream sends SendToDevice messages and calls on_labels_changed only (no
-- timer, no transfer), which is safe inside a C4:url callback (driver.lua's
-- on_container), so it runs straight from the event stream. The take-over's
-- PUT starts from stop_area (ExecuteCommand) or from its timer, never from a
-- transfer's callback; the PUT's own callback only sends STOPPED and hands
-- on_stopped its Last Action.

local hue_model = require("bridge.hue_model")
local util = require("bridge.util")
local num = require("common.num")
local log = require("common.log")

local syncboxes = {}
syncboxes.__index = syncboxes

-- The bridge's provider connection (contracts C6; design §4.2).
syncboxes.BINDING = 2
syncboxes.CLASS = "HUE_SYNCBOX"

syncboxes.HELLO = "HUE_SYNCBOX_HELLO"
syncboxes.GOODBYE = "HUE_SYNCBOX_GOODBYE"
syncboxes.CONFIGURE = "HUE_SYNCBOX_CONFIGURE"
syncboxes.AREA = "HUE_SYNCBOX_AREA"
syncboxes.STATE = "HUE_SYNCBOX_STATE"
syncboxes.STOP_AREA = "HUE_SYNCBOX_STOP_AREA"
syncboxes.STOPPED = "HUE_SYNCBOX_STOPPED"
syncboxes.ASK_HELLO = "HUE_SYNCBOX_ASK_HELLO"

-- Bounds: boxes kept (a house has a few; a hello beyond is refused with a
-- warning), hellos waiting for their binding, areas and rooms per area told
-- (research §3.2), the box id's length, a Control4 device id's range.
syncboxes.MAX_BOXES = 16
syncboxes.MAX_PENDING = 8
syncboxes.MAX_AREAS = 64
syncboxes.MAX_ROOMS = 32
syncboxes.BOX_ID_LEN = 12
syncboxes.ID_MAX = 64
syncboxes.DEVICE_ID_MAX = 2147483647

-- A box whose Composer name cannot be read (the proxy's default name, C1.1).
syncboxes.FALLBACK_NAME = "Hue Sync Box"

-- The take-over: seconds the bridge waits for the word of the other boxes
-- naming the area (a box reads itself 1 s after its own command and at once
-- on the bridge's AREA hint, then says whether it syncs: contracts C2's
-- cadence), the areas whose stop may wait at once, the most bytes of a
-- STOPPED's detail, and the CLIP v2 resource a stop is PUT to (research §2.1).
syncboxes.TAKE_OVER_GRACE_S = 3
syncboxes.MAX_STOPS = 4
syncboxes.DETAIL_MAX = 120
syncboxes.AREA_PATH = "/clip/v2/resource/entertainment_configuration/"

-- Why a take-over was refused, as the log lines say it.
local REFUSED = {
	not_linked = "its box is not linked to this bridge, or this bridge is not paired",
	no_area = "this bridge has no such area",
	another_box = "a sync box of this project syncs to it (W10)",
	busy = "too many stops wait already",
}

-- Checks ------------------------------------------------------------------------------

-- A Control4 device id: a whole number within 1..DEVICE_ID_MAX, else nil.
function syncboxes.device_id(v)
	local n = num.within(v, 1, syncboxes.DEVICE_ID_MAX)
	if n == nil or n ~= math.floor(n) then
		return nil
	end
	return n
end

-- The box id upper-cased when `v` is 12 hex digits (research §3.2), else nil.
function syncboxes.box_id(v)
	if type(v) == "string" and #v == syncboxes.BOX_ID_LEN and v:find("^%x+$") then
		return v:upper()
	end
	return nil
end

-- A Hue bridge id lower-cased when `v` is hex digits only (the box's
-- hue.bridgeUniqueId and the bridge's id compare in lower case,
-- docs/syncbox-api-research.md §6 item 10), at most ID_MAX, else nil.
function syncboxes.bridge_id(v)
	if type(v) == "string" and #v <= syncboxes.ID_MAX and v:find("^%x+$") then
		return v:lower()
	end
	return nil
end

-- An entertainment area id lower-cased when `v` is hex digits and "-" only (a
-- CLIP v2 entertainment_configuration id is a UUID, and the box's hueTarget
-- names one with a CLIP v2 bridge, docs/syncbox-api-research.md §2.6), at
-- most ID_MAX, else nil.
function syncboxes.area_id(v)
	if type(v) == "string" and #v <= syncboxes.ID_MAX and v:find("^[%x%-]+$") then
		return v:lower()
	end
	return nil
end

-- JSON ---------------------------------------------------------------------------------

-- A JSON string: `"` and `\` escaped, every control character as \u00XX;
-- UTF-8 passes as it is.
local function json_string(s)
	local escaped = s:gsub('[%c"\\]', function(c)
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		end
		return string.format("\\u%04x", c:byte())
	end)
	return '"' .. escaped .. '"'
end

local function json_list(items)
	return "[" .. table.concat(items, ",") .. "]"
end

-- One area of CONFIGURE's list, its fields in a fixed order.
local function json_area(area)
	local rooms = {}
	for i, room in ipairs(area.rooms) do
		rooms[i] = json_string(room)
	end
	return string.format('{"id":%s,"name":%s,"type":%s,"status":%s,"lamps":%d,"rooms":%s}',
		json_string(area.id), json_string(area.name), json_string(area.type), json_string(area.status),
		area.lamps, json_list(rooms))
end

-- The module ---------------------------------------------------------------------------

function syncboxes.new(deps)
	deps = deps or {}
	assert(type(deps.send) == "function", "syncboxes.new: deps.send is required")
	return setmetatable({
		deps = deps,
		log = deps.log or log,
		by_device = {},   -- device id -> { device_id, box_id, bridge_id, area_id, syncing, name }
		pending = {},     -- device id -> a checked hello waiting for its binding
		bound_ids = {},   -- device id -> true (bound) / false (unbound), as OnBindingChanged said
		owners = {},      -- area id -> device id (or false: several), the labels last seen
		stops = {},       -- area id -> a take-over { area_id, devices = { [id] = true }, timer }
		asked = {},       -- device id -> true: asked for a hello (ASK_HELLO) in this run
	}, syncboxes)
end

-- deps[name](...) under pcall: the value, or nil after a warning.
function syncboxes:call(name, ...)
	local fn = self.deps[name]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, value = pcall(fn, ...)
	if not ok then
		self.log.warn("syncboxes: %s failed: %s", name, util.echo(value, util.LOG_MAX))
		return nil
	end
	return value
end

local function sorted_ids(map)
	local out = {}
	for id in pairs(map) do
		out[#out + 1] = id
	end
	table.sort(out)
	return out
end

-- How a box reads in log lines: "#3ABC (device 1234)", the last 4 digits of its id.
local function tag(box)
	return string.format("%s (device %d)", box.box_id and ("#" .. box.box_id:sub(-4)) or "unpaired box",
		box.device_id)
end

-- This bridge's id, lower-cased, or nil.
function syncboxes:own_bridge_id()
	return syncboxes.bridge_id(self:call("bridge_id"))
end

-- True when the box's own bridge is this one.
function syncboxes:matches(box, own)
	own = own or self:own_bridge_id()
	return own ~= nil and box.bridge_id == own
end

-- The devices bound on connection 2 as a set, or nil when unknown (the
-- lookup answered nil, which OS 3.4.2 does with nothing bound [verified:
-- bridge/project.lua], or raised).
function syncboxes:bound_set()
	local raw = self:call("bound")
	if type(raw) ~= "table" then
		return nil
	end
	local out = {}
	for id in pairs(raw) do
		local n = syncboxes.device_id(id)
		if n then
			out[n] = true
		end
	end
	return out
end

-- true, false, or nil (unknown): OnBindingChanged's word first, then the lookup.
function syncboxes:is_bound(device_id, set)
	local flag = self.bound_ids[device_id]
	if flag ~= nil then
		return flag
	end
	set = set or self:bound_set()
	if set == nil then
		return nil
	end
	return set[device_id] == true
end

-- The Composer name of a box device: deps.display_name (the driver reads its
-- proxy's name), else the name kept at its hello, else FALLBACK_NAME;
-- through util.display_name.
function syncboxes:name_of(box)
	local name = util.display_name(self:call("display_name", box.device_id))
	if name ~= "" then
		box.name = name
		return name
	end
	return box.name or syncboxes.FALLBACK_NAME
end

-- Rooms -------------------------------------------------------------------------------

function syncboxes:lights_module()
	local lights = self.deps.lights
	if type(lights) == "function" then
		local ok, value = pcall(lights)
		lights = ok and value or nil
	end
	return type(lights) == "table" and lights or nil
end

-- The Control4 room of one lamp through its Hue room's mapping (the lights'
-- registry): the room's current name from `c4_rooms`; the mapping's kept name
-- while the project's rooms are unknown; nil when the lamp is in no mapped
-- room or its Control4 room is gone.
local function room_of_lamp(lights, rid, c4_rooms)
	local model = type(lights.models) == "table" and lights.models[rid] or nil
	if type(model) ~= "table" then
		return nil
	end
	local group = lights:hue_room_of(model)
	local mapping = group and lights:room_mapping(group) or nil
	local room_id = type(mapping) == "table" and mapping.c4_room_id or nil
	if room_id == nil then
		return nil
	end
	if next(c4_rooms) == nil then
		return mapping.c4_room_name
	end
	return c4_rooms[room_id]
end

-- The Control4 rooms of `lamps`, by name, each once, at most MAX_ROOMS.
function syncboxes:rooms_of(lamps)
	local raw
	if type(self.deps.rooms_for) == "function" then
		raw = self:call("rooms_for", lamps)
	else
		local lights = self:lights_module()
		if lights then
			local ok, value = pcall(function()
				local c4_rooms = type(lights.project) == "table" and lights.project:rooms() or {}
				local out = {}
				for _, rid in ipairs(lamps) do
					out[#out + 1] = room_of_lamp(lights, rid, c4_rooms)
				end
				return out
			end)
			if ok then
				raw = value
			else
				self.log.warn("syncboxes: the rooms of an area: %s", util.echo(value, util.LOG_MAX))
			end
		end
	end
	local seen, out = {}, {}
	for _, room in pairs(type(raw) == "table" and raw or {}) do
		local name = util.display_name(room)
		if name ~= "" and not seen[name] then
			seen[name] = true
			out[#out + 1] = name
		end
	end
	table.sort(out, function(a, b)
		local ka, kb = util.norm(a), util.norm(b)
		if ka ~= kb then
			return ka < kb
		end
		return a < b
	end)
	while #out > syncboxes.MAX_ROOMS do
		out[#out] = nil
	end
	return out
end

-- The areas ------------------------------------------------------------------------------

-- The entertainment areas, as the bridge has them (sorted by name), each
-- checked: its id a resource id, a name.
function syncboxes:area_list()
	local raw = self:call("areas")
	local out = {}
	for _, area in ipairs(type(raw) == "table" and raw or {}) do
		if type(area) == "table" and hue_model.resource_id(area.id) and type(area.name) == "string" then
			out[#out + 1] = area
		end
	end
	return out
end

-- CONFIGURE's `areas`: the JSON list of { id, name, type, status, lamps, rooms }.
function syncboxes:areas_json()
	local items = {}
	for _, area in ipairs(self:area_list()) do
		if #items >= syncboxes.MAX_AREAS then
			break
		end
		local lamps = type(area.lamps) == "table" and area.lamps or {}
		items[#items + 1] = json_area({
			id = area.id,
			name = util.display_name(area.name),
			type = type(area.kind) == "string" and area.kind or "other",
			status = area.status == "active" and "active" or "inactive",
			lamps = #lamps,
			rooms = self:rooms_of(lamps),
		})
	end
	return json_list(items)
end

-- Labels -----------------------------------------------------------------------------------

-- Area id -> the device id of the box of this bridge that streams to it (the
-- label rule of the header: the one naming it that reports itself syncing,
-- else the one naming it whose sync state is unknown), or false when two are
-- equally likely. A box that reports itself not syncing labels nothing.
function syncboxes:label_owners()
	local own, syncing, unknown = self:own_bridge_id(), {}, {}
	for _, id in ipairs(sorted_ids(self.by_device)) do
		local box = self.by_device[id]
		if box.area_id and box.syncing ~= false and self:matches(box, own) then
			local list = box.syncing == true and syncing or unknown
			list[box.area_id] = list[box.area_id] == nil and id or false
		end
	end
	for area_id, id in pairs(syncing) do
		unknown[area_id] = id
	end
	return unknown
end

function syncboxes:label_for(area_id)
	local id = syncboxes.area_id(area_id)
	local owner = id and self:label_owners()[id]
	if not owner then
		return nil
	end
	return self:name_of(self.by_device[owner])
end

-- After any change: the areas whose box changed and that stream now hand
-- their lamps to on_labels_changed once (sorted, each once).
function syncboxes:check_labels()
	local before, after = self.owners, self:label_owners()
	self.owners = after
	local changed = {}
	for id, owner in pairs(before) do
		if after[id] ~= owner then
			changed[id] = true
		end
	end
	for id, owner in pairs(after) do
		if before[id] ~= owner then
			changed[id] = true
		end
	end
	if next(changed) == nil or type(self.deps.on_labels_changed) ~= "function" then
		return
	end
	local seen, rids = {}, {}
	for _, area in ipairs(self:area_list()) do
		if changed[area.id] and area.status == "active" then
			for _, rid in ipairs(type(area.lamps) == "table" and area.lamps or {}) do
				if not seen[rid] then
					seen[rid] = true
					rids[#rids + 1] = rid
				end
			end
		end
	end
	if #rids > 0 then
		table.sort(rids)
		self:call("on_labels_changed", rids)
	end
end

-- Messages to the boxes -----------------------------------------------------------------------

function syncboxes:send(device_id, command, params)
	local ok, err = pcall(self.deps.send, device_id, command, params)
	if not ok then
		self.log.warn("syncboxes: %s to device %d failed: %s", command, device_id, util.echo(err, util.LOG_MAX))
	end
	return ok
end

-- CONFIGURE to one box; `areas` is the list's JSON when the caller built it already.
function syncboxes:configure(box, areas)
	local own = self:own_bridge_id()
	return self:send(box.device_id, syncboxes.CONFIGURE, {
		bridge_id = own,
		match = self:matches(box, own) and "true" or "false",
		areas = areas or self:areas_json(),
	})
end

-- Hello and goodbye ------------------------------------------------------------------------------

-- nil and one debug line naming why a box's message was dropped.
function syncboxes:drop(command, params, why)
	self.log.debug("syncboxes: %s from device %s dropped: %s", command, util.echo(params.device_id, 40), why)
	return nil
end

-- A box message's values, checked (`command` names it in the debug line):
-- { device_id, box_id, bridge_id, area_id, syncing }, or nil (malformed). An
-- id left out is nil; an id given that is not one makes the message
-- malformed. `syncing` is true or false ("true", "false"), nil when left out;
-- any other value makes it malformed too.
function syncboxes:checked_hello(params, command)
	command = command or syncboxes.HELLO
	local device_id = syncboxes.device_id(params.device_id)
	if not device_id then
		return self:drop(command, params, "no device id")
	end
	local out = { device_id = device_id }
	for _, field in ipairs({ { "box_id", syncboxes.box_id }, { "bridge_id", syncboxes.bridge_id },
		{ "area_id", syncboxes.area_id } }) do
		local name, check = field[1], field[2]
		local value = params[name]
		if value ~= nil and value ~= "" then
			out[name] = check(value)
			if out[name] == nil then
				return self:drop(command, params, "its " .. name .. " is not one")
			end
		end
	end
	local syncing = params.syncing
	if syncing == "true" or syncing == "false" then
		out.syncing = syncing == "true"
	elseif syncing ~= nil and syncing ~= "" then
		return self:drop(command, params, "its sync state is neither true nor false")
	end
	return out
end

function syncboxes:count()
	return #sorted_ids(self.by_device)
end

-- Record a checked hello of a bound device and answer it (unless `later`:
-- configure_all answers every box in one go).
function syncboxes:accept(hello, later)
	local id = hello.device_id
	self.pending[id] = nil
	if not self.by_device[id] and self:count() >= syncboxes.MAX_BOXES then
		self.log.warn("syncboxes: device %d said hello, but %d sync boxes are bound already; not answered", id,
			syncboxes.MAX_BOXES)
		return false
	end
	local old = self.by_device[id]
	local box = { device_id = id, box_id = hello.box_id, bridge_id = hello.bridge_id, area_id = hello.area_id,
		syncing = hello.syncing, name = old and old.name or nil }
	self.by_device[id] = box
	local name = self:name_of(box)
	self.log.debug("syncboxes: hello from %s %s: bridge %s%s, area %s, %s", util.echo(name, 80), tag(box),
		tostring(box.bridge_id or "none"), self:matches(box) and " (this one)" or "", tostring(box.area_id or "none"),
		box.syncing == nil and "sync state unknown" or (box.syncing and "syncing" or "not syncing"))
	if not old then
		self.log.info("syncboxes: %s %s is linked", util.echo(name, 80), tag(box))
	end
	if not later then
		self:configure(box)
		self:check_labels()
	end
	return true
end

-- A checked hello (or a STATE that stands for one): recorded and answered
-- when its device shows bound, else kept waiting for its binding.
function syncboxes:greet(hello, command)
	local id = hello.device_id
	if self:is_bound(id) == true then
		return self:accept(hello)
	end
	if self.pending[id] or #sorted_ids(self.pending) < syncboxes.MAX_PENDING then
		self.pending[id] = hello
	end
	self.log.debug("syncboxes: %s from device %d not answered: not bound on Hue Sync Boxes (yet)", command, id)
	return false
end

function syncboxes:hello(params)
	params = type(params) == "table" and params or {}
	local hello = self:checked_hello(params, syncboxes.HELLO)
	if not hello then
		return false
	end
	return self:greet(hello, syncboxes.HELLO)
end

-- A box's sync state. A box the bridge knows as it says it is takes the new
-- area and state quietly; any other (unknown since this driver started, or
-- naming another box or bridge than its hello) is greeted as a hello, which
-- the box's whole view the STATE carries stands for.
function syncboxes:state(params)
	params = type(params) == "table" and params or {}
	local state = self:checked_hello(params, syncboxes.STATE)
	if not state then
		return false
	end
	if state.syncing == nil then
		return self:drop(syncboxes.STATE, params, "no sync state") or false
	end
	local box = self.by_device[state.device_id]
	if not box or box.box_id ~= state.box_id or box.bridge_id ~= state.bridge_id then
		return self:greet(state, syncboxes.STATE)
	end
	box.area_id, box.syncing = state.area_id, state.syncing
	self.log.debug("syncboxes: %s %s %s, area %s", util.echo(self:name_of(box), 80), tag(box),
		state.syncing and "syncs" or "does not sync", tostring(box.area_id or "none"))
	self:check_labels()
	return true
end

-- Forget a box; `why` for the log line.
function syncboxes:forget(device_id, why)
	local box = self.by_device[device_id]
	self.pending[device_id] = nil
	if not box then
		return false
	end
	self.by_device[device_id] = nil
	self.log.info("syncboxes: %s forgotten (%s)", tag(box), why)
	self:check_labels()
	return true
end

function syncboxes:goodbye(params)
	params = type(params) == "table" and params or {}
	local id = syncboxes.device_id(params.device_id)
	if not id then
		return self:drop(syncboxes.GOODBYE, params, "no device id") or false
	end
	local box = self.by_device[id]
	if not box then
		self.pending[id] = nil
		self.log.debug("syncboxes: %s from device %d: no such box", syncboxes.GOODBYE, id)
		return false
	end
	local said = params.box_id
	if said ~= nil and said ~= "" and syncboxes.box_id(said) ~= box.box_id then
		return self:drop(syncboxes.GOODBYE, params, "it names another box than the device's hello") or false
	end
	return self:forget(id, "goodbye")
end

-- Bindings ---------------------------------------------------------------------------------------

function syncboxes:binding_changed(binding, class, bound, other_id)
	if tonumber(binding) ~= syncboxes.BINDING then
		return false
	end
	if class ~= nil and class ~= syncboxes.CLASS then
		return false
	end
	local id = syncboxes.device_id(other_id)
	if not id then
		return true
	end
	if bound == true or bound == "true" then
		self.bound_ids[id] = true
		self.log.debug("syncboxes: device %d bound on Hue Sync Boxes", id)
		local hello = self.pending[id]
		if hello then
			self:accept(hello)
		else
			self:ask_hello(id)
		end
	elseif bound == false or bound == "false" then
		self.bound_ids[id] = false
		self.asked[id] = nil
		self:forget(id, "unbound")
	end
	return true
end

-- Asking for hellos ---------------------------------------------------------------------------------

-- ASK_HELLO to a bound device without a hello (nor a waiting one) that was not
-- asked yet in this run; true when it went out. A send that raised is asked
-- again at the next chance.
function syncboxes:ask_hello(device_id)
	if self.by_device[device_id] or self.pending[device_id] or self.asked[device_id] then
		return false
	end
	self.asked[device_id] = true
	self.log.debug("syncboxes: device %d is bound on Hue Sync Boxes without a hello: asking for one", device_id)
	if not self:send(device_id, syncboxes.ASK_HELLO, {}) then
		self.asked[device_id] = nil
		return false
	end
	return true
end

-- Every device bound on connection 2 (the lookup's `set`, and OnBindingChanged's
-- word over it) without a hello: asked, at most MAX_BOXES a call. Returns how many.
function syncboxes:ask_unknown(set)
	local ids = {}
	for id in pairs(set or {}) do
		if self.bound_ids[id] ~= false then
			ids[id] = true
		end
	end
	for id, flag in pairs(self.bound_ids) do
		if flag == true then
			ids[id] = true
		end
	end
	local asked = 0
	for _, id in ipairs(sorted_ids(ids)) do
		if asked >= syncboxes.MAX_BOXES then
			break
		end
		if self:ask_hello(id) then
			asked = asked + 1
		end
	end
	return asked
end

-- After a resync ----------------------------------------------------------------------------------

function syncboxes:configure_all()
	local set = self:bound_set()
	for _, id in ipairs(sorted_ids(self.pending)) do
		local is = self:is_bound(id, set)
		if is == true then
			self:accept(self.pending[id], true)
		elseif is == false then
			self.pending[id] = nil  -- Director says it is not bound: a forged or stale hello
		end
	end
	if set then
		for _, id in ipairs(sorted_ids(self.by_device)) do
			if not set[id] and self.bound_ids[id] ~= true then
				self:forget(id, "no longer bound")
			end
		end
	end
	local ids = sorted_ids(self.by_device)
	local areas = #ids > 0 and self:areas_json() or nil
	local told = 0
	for _, id in ipairs(ids) do
		if self:configure(self.by_device[id], areas) then
			told = told + 1
		end
	end
	self:check_labels()
	self:ask_unknown(set)
	return told
end

-- Streams ----------------------------------------------------------------------------------------

function syncboxes:on_stream(area, started)
	local area_id = type(area) == "table" and hue_model.resource_id(area.id) or nil
	if not area_id then
		return 0
	end
	local mine = area_id:lower()
	if started then
		-- A box that said it does not sync may be the one that just started:
		-- unknown until its next word (link.lua sends STATE after this AREA).
		for _, box in pairs(self.by_device) do
			if box.area_id == mine and box.syncing == false then
				box.syncing = nil
			end
		end
	end
	local told = 0
	for _, id in ipairs(sorted_ids(self.by_device)) do
		local box = self.by_device[id]
		local streamer = "none"
		if started then
			streamer = box.area_id == mine and "this_box" or "other"
		end
		if self:send(id, syncboxes.AREA, { id = area_id, status = started and "active" or "inactive",
			streamer = streamer }) then
			told = told + 1
		end
	end
	if started then
		self:check_labels()
	end
	return told
end

-- The take-over (O12, W10) ----------------------------------------------------------------------------

-- The bridge's area with this id (lower case), or nil.
function syncboxes:area_by_id(area_id)
	for _, area in ipairs(self:area_list()) do
		if area.id:lower() == area_id then
			return area
		end
	end
	return nil
end

-- The bound boxes of this bridge other than the devices in `except` that
-- may stream to `area_id`: those naming it, and one that syncs without
-- naming an area. Returns the first (by device id) that reports itself
-- syncing, or nil, and whether another of them has not said so (its sync
-- state unknown, or "not syncing" that may be older than the stream).
function syncboxes:contenders(area_id, except, own)
	own = own or self:own_bridge_id()
	local syncing, unsure = nil, false
	for _, id in ipairs(sorted_ids(self.by_device)) do
		local box = self.by_device[id]
		if not except[id] and self:matches(box, own)
			and (box.area_id == area_id or (box.area_id == nil and box.syncing == true)) then
			if box.syncing == true then
				syncing = syncing or box
			else
				unsure = true
			end
		end
	end
	return syncing, unsure
end

-- STOPPED to one box. `reason` "stopped" is ok; `by` and `detail` only when given.
function syncboxes:answer(device_id, area_id, reason, by, detail)
	self:send(device_id, syncboxes.STOPPED, {
		area_id = area_id,
		ok = reason == "stopped" and "true" or "false",
		reason = reason,
		by = by and util.echo(by, syncboxes.DETAIL_MAX) or nil,
		detail = detail and util.echo(detail, syncboxes.DETAIL_MAX) or nil,
	})
end

-- How a requester reads in log lines: its Composer name and tag.
function syncboxes:requester(device_id, box_id)
	local box = self.by_device[device_id] or { device_id = device_id, box_id = box_id }
	return util.echo(self:name_of(box), 80) .. " " .. tag(box)
end

-- A take-over refused at once: logged with the sender, answered; false.
function syncboxes:refuse(device_id, area_id, reason, by)
	self.log.info("syncboxes: %s: the stream on area %s is not stopped: %s%s", self:requester(device_id), area_id,
		REFUSED[reason], by and (" (" .. util.echo(by, 80) .. ")") or "")
	self:answer(device_id, area_id, reason, by)
	return false
end

-- The requesters of a stop still bound, sorted; those unbound since are not answered.
function syncboxes:still_bound(stop)
	local out = {}
	for _, id in ipairs(sorted_ids(stop.devices)) do
		if self:is_bound(id) == true then
			out[#out + 1] = id
		end
	end
	return out
end

-- The end of a take-over: forgotten, every requester still bound answered.
function syncboxes:finish(stop, reason, by, detail)
	if self.stops[stop.area_id] ~= stop then
		return
	end
	self.stops[stop.area_id] = nil
	if stop.timer then
		pcall(stop.timer.Cancel, stop.timer)
		stop.timer = nil
	end
	for _, id in ipairs(self:still_bound(stop)) do
		self:answer(id, stop.area_id, reason, by, detail)
	end
end

-- The PUT's answer (from the request's callback: STOPPED messages only).
function syncboxes:put_done(stop, area, r)
	if self.stops[stop.area_id] ~= stop then
		return
	end
	if type(r) == "table" and r.ok then
		local names = {}
		for _, id in ipairs(self:still_bound(stop)) do
			names[#names + 1] = util.echo(self:name_of(self.by_device[id] or { device_id = id }), 80)
		end
		self.log.info("syncboxes: the stream on %s is stopped for %s", util.echo(area.name, 80),
			#names > 0 and table.concat(names, ", ") or "no box still bound")
		if #names > 0 then
			self:call("on_stopped", syncboxes.stopped_text(area.name, names))
		end
		return self:finish(stop, "stopped")
	end
	local detail = type(r) == "table" and (r.err or (r.code and ("HTTP " .. tostring(r.code)))) or nil
	detail = util.echo(detail or "no answer", syncboxes.DETAIL_MAX)
	self.log.warn("syncboxes: stopping the stream on %s failed: %s", util.echo(area.name, 80), detail)
	self:finish(stop, "failed", nil, detail)
end

-- Check again and stop: the area still there, no other box saying it syncs
-- to it (now that the grace is over, a box that has not said so is taken at
-- its word), a requester still bound; then the PUT.
function syncboxes:run_stop(stop)
	if self.stops[stop.area_id] ~= stop then
		return
	end
	stop.timer = nil
	if #self:still_bound(stop) == 0 then
		self.stops[stop.area_id] = nil
		self.log.debug("syncboxes: the stop of area %s dropped: no box that asked is bound now", stop.area_id)
		return
	end
	local area = self:area_by_id(stop.area_id)
	if not area then
		self.log.info("syncboxes: the stream on area %s is not stopped: %s", stop.area_id, REFUSED.no_area)
		return self:finish(stop, "no_area")
	end
	local other = self:contenders(stop.area_id, stop.devices)
	if other then
		local by = self:name_of(other)
		self.log.info("syncboxes: the stream on %s is not stopped: %s (%s)", util.echo(area.name, 80),
			REFUSED.another_box, util.echo(by, 80))
		return self:finish(stop, "another_box", by)
	end
	if type(self.deps.http) ~= "function" then
		return self:put_done(stop, area, { ok = false, err = "no request path" })
	end
	local ok, err = pcall(self.deps.http, { method = "PUT", path = syncboxes.AREA_PATH .. area.id,
		body = { action = "stop" } }, function(r)
		local fine, why = pcall(self.put_done, self, stop, area, r)
		if not fine then
			self.log.error("syncboxes: the stop's answer failed: %s", util.echo(why, util.LOG_MAX))
		end
	end)
	if not ok then
		self:put_done(stop, area, { ok = false, err = err })
	end
end

-- The grace's timer, or nil (logged) when none could be set.
function syncboxes:grace_timer(stop)
	local set_timer = self.deps.set_timer or function(delay_ms, fn)
		return C4:SetTimer(delay_ms, fn)
	end
	local ok, timer = pcall(set_timer, syncboxes.TAKE_OVER_GRACE_S * 1000, function()
		local fine, why = pcall(self.run_stop, self, stop)
		if not fine then
			self.log.error("syncboxes: the stop of area %s failed: %s", stop.area_id, util.echo(why, util.LOG_MAX))
		end
	end)
	if not ok or timer == nil then
		self.log.warn("syncboxes: no timer for the take-over: %s", util.echo(ok and "none" or timer, util.LOG_MAX))
		return nil
	end
	return timer
end

function syncboxes:stop_area(params)
	params = type(params) == "table" and params or {}
	local req = self:checked_hello(params, syncboxes.STOP_AREA)
	if not req then
		return false
	end
	if not req.area_id then
		return self:drop(syncboxes.STOP_AREA, params, "no area id") or false
	end
	local id, area_id = req.device_id, req.area_id
	if self:is_bound(id) ~= true then
		self.log.warn("syncboxes: %s from device %d for area %s ignored: not bound on Hue Sync Boxes",
			syncboxes.STOP_AREA, id, area_id)
		return false
	end
	local box = self.by_device[id]
	self.log.info("syncboxes: %s asks to stop the stream on area %s", self:requester(id, req.box_id), area_id)
	local own = self:own_bridge_id()
	if own == nil or (req.bridge_id or (box and box.bridge_id)) ~= own then
		return self:refuse(id, area_id, "not_linked")
	end
	local area = self:area_by_id(area_id)
	if not area then
		return self:refuse(id, area_id, "no_area")
	end
	local stop = self.stops[area_id]
	if stop then
		stop.devices[id] = true
		return true
	end
	if #sorted_ids(self.stops) >= syncboxes.MAX_STOPS then
		return self:refuse(id, area_id, "busy")
	end
	local other, unsure = self:contenders(area_id, { [id] = true }, own)
	if other then
		return self:refuse(id, area_id, "another_box", self:name_of(other))
	end
	stop = { area_id = area_id, devices = { [id] = true } }
	self.stops[area_id] = stop
	if unsure then
		stop.timer = self:grace_timer(stop)
		if not stop.timer then
			self:finish(stop, "failed", nil, "the bridge could not wait for the other sync boxes")
			return false
		end
		self.log.info("syncboxes: %s: waiting %d s for the other sync boxes on it to say whether they sync (W10)",
			util.echo(area.name, 80), syncboxes.TAKE_OVER_GRACE_S)
		return true
	end
	self:run_stop(stop)
	return true
end

function syncboxes:stop()
	for _, area_id in ipairs(sorted_ids(self.stops)) do
		local stop = self.stops[area_id]
		self.stops[area_id] = nil
		if stop.timer then
			pcall(stop.timer.Cancel, stop.timer)
		end
	end
end

-- The bridge's Last Action after a stop (on_stopped).
function syncboxes.stopped_text(area_name, box_names)
	return string.format("Sync stopped for %s: %s", table.concat(box_names, ", "), tostring(area_name))
end

-- For the specs and Diagnostics -------------------------------------------------------------------

-- The bound boxes, by device id, as copies.
function syncboxes:boxes()
	local out = {}
	for _, id in ipairs(sorted_ids(self.by_device)) do
		local box = self.by_device[id]
		out[#out + 1] = { device_id = id, box_id = box.box_id, bridge_id = box.bridge_id, area_id = box.area_id,
			syncing = box.syncing, name = box.name }
	end
	return out
end

return syncboxes
