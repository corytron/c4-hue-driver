-- The sync box's side of the HUE_SYNCBOX binding to the Hue Bridge driver
-- (2.0 beta stage 2, #534): docs/hdmi-sync-stage2-design.md §3.8, contracts
-- C5 of docs/hdmi-sync-contracts.md, research
-- docs/syncbox-architecture-research.md §1.5 and §3.1. The bridge's side is
-- src/hue_bridge/bridge/syncboxes.lua.
--
--   box → bridge   HUE_SYNCBOX_HELLO     { device_id, box_id, bridge_id, area_id }
--                  HUE_SYNCBOX_GOODBYE   { device_id, box_id }
--   bridge → box   HUE_SYNCBOX_CONFIGURE { bridge_id, match ("true"/"false"),
--                                          areas (a JSON list of { id, name, type,
--                                          status, lamps, rooms }) }
--                  HUE_SYNCBOX_AREA      { id, status ("active"/"inactive"),
--                                          streamer ("this_box"/"other"/"none") }
--
-- Every parameter is a string, as in every message between these drivers
-- (contracts C5). `device_id` is not in C5's table: Control4 tells a driver
-- nothing about who sent a message (SECURITY.md, "Trust boundaries", #483),
-- so the box names its own device, as the lights' and the sensors' hellos
-- do, and the bridge answers only a device Director shows bound on its
-- "Hue Sync Boxes" connection. A value this side does not hold (no box id
-- before the first identity check, no bridge or area before the first read)
-- is left out: C4:SendToDevice drops empty values anyway [verified: API
-- 32_serial_network_device/_19-SendToDevice, allowEmptyValues].
--
-- The trust rule (#483; research §3.1): a message from the bridge is only a
-- hint. received() checks every value and hands back a plain table; the
-- driver then reads the box over its pinned connection, and the box's own
-- answer is the only source of its state. A malformed message is dropped
-- with one debug line. Nothing here carries the box's token or the bridge's
-- key.
--
-- Interface (contract §3.8):
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
--   l:hello(box_id, bridge_id, area_id)  HUE_SYNCBOX_HELLO on binding 1; true when sent
--   l:update(box_id, bridge_id, area_id) the hello again only when one of the three
--                                        changed since the last one sent; true when sent
--   l:goodbye(box_id)                    HUE_SYNCBOX_GOODBYE on binding 1; true when sent
--   l:reset()                            forget the last hello (an unbind: the next
--                                        binding's hello goes out whatever it says)
--   l:received(command, params)          → a checked table, or nil:
--     { kind = "configure", bridge_id, match, areas = { { id, name, type, status,
--       lamps, rooms = { name... } }... } }
--     { kind = "area", id, status, streamer }
--   link.handles(command)                true for the two messages received() reads
--   link.box_id(v), link.bridge_id(v), link.area_id(v)   the checks, for the driver
--
-- When the driver sends the hello (contract §3.8): at late init, on binding,
-- and whenever its box's area or bridge id changes (l:update after each read).

local num = require("common.num")
local https = require("common.https")
local log = require("common.log")

local link = {}
link.__index = link

-- The box's consumer connection to the bridge (contracts C1.2).
link.BINDING = 1
link.CLASS = "HUE_SYNCBOX"

link.HELLO = "HUE_SYNCBOX_HELLO"
link.GOODBYE = "HUE_SYNCBOX_GOODBYE"
link.CONFIGURE = "HUE_SYNCBOX_CONFIGURE"
link.AREA = "HUE_SYNCBOX_AREA"

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

-- The values an area's fields may take; any other type reads "other", any
-- other status "inactive" (the bridge's hue_model rules).
local KINDS = { screen = true, monitor = true, music = true, ["3dspace"] = true, other = true }
local STATUSES = { active = true, inactive = true }
local STREAMERS = { this_box = true, other = true, none = true }

local RECEIVED = { [link.CONFIGURE] = true, [link.AREA] = true }

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
		last = nil,  -- { box_id, bridge_id, area_id } of the last hello sent
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
-- debug line (it is left out of the message).
function link:checked(what, value, check)
	if value == nil or value == "" then
		return nil
	end
	local out = check(value)
	if out == nil then
		self.log.debug("Hue Bridge link: the %s %s is left out of the hello: not an id", what,
			https.peer_text(value, 80))
	end
	return out
end

function link:hello(box_id, bridge_id, area_id)
	local params = {
		device_id = self:own_id(),
		box_id = self:checked("box id", box_id, link.box_id),
		bridge_id = self:checked("bridge id", bridge_id, link.bridge_id),
		area_id = self:checked("area id", area_id, link.area_id),
	}
	if not self:send(link.HELLO, params) then
		return false
	end
	self.last = { box_id = params.box_id, bridge_id = params.bridge_id, area_id = params.area_id }
	return true
end

-- The hello again when the box's id, its bridge or its area changed since
-- the last one sent (or none was sent); true when it went out.
function link:update(box_id, bridge_id, area_id)
	local last = self.last
	if last and last.box_id == link.box_id(box_id) and last.bridge_id == link.bridge_id(bridge_id)
		and last.area_id == link.area_id(area_id) then
		return false
	end
	return self:hello(box_id, bridge_id, area_id)
end

function link:goodbye(box_id)
	self.last = nil
	return self:send(link.GOODBYE, {
		device_id = self:own_id(),
		box_id = self:checked("box id", box_id, link.box_id),
	})
end

function link:reset()
	self.last = nil
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

-- A name a peer sent, through https.peer_text (control characters out, at
-- most TEXT_ROW bytes); nil when it is not a non-empty string.
local function name_of(value)
	if type(value) ~= "string" then
		return nil
	end
	local text = https.peer_text(value)
	return text ~= "" and text or nil
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
	return { kind = "area", id = id, status = params.status, streamer = params.streamer }
end

function link:received(command, params)
	if not RECEIVED[command] then
		return nil
	end
	if type(params) ~= "table" then
		return self:drop(command, "no parameters")
	end
	if command == link.CONFIGURE then
		return self:configure(params)
	end
	return self:area(params)
end

return link
