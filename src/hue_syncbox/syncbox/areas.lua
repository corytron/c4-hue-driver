-- The Hue Sync Box's entertainment area (2.0 beta stage 4, #568;
-- docs/hdmi-sync-stage4-design.md §1.5 and §5, design docs/hdmi-sync-design.md
-- §6.1 and §8, contracts C1.4 and C1.6 in docs/hdmi-sync-contracts.md, owner's
-- answer O3; edge cases E1 to E4, E7, B17, B20, C19 and §6 in
-- docs/edge-cases-syncbox.md): the area belongs to the box that drives it,
-- picked from the areas the box lists, stored by id with its name, and
-- re-pointable in one place when Hue makes it again under a new id.
--
--   local a = areas.new{ queue, persist_get, persist_set, log }
--   a:observe(model)    every good read (syncbox/state.lua's model) → a text
--                       to say once in Last Action, or nil: the box syncs to
--                       an area deleted in Hue (E3), or that area's same-name
--                       successor is on the bridge (E4)
--   a:items([first])    → labels, value: the Entertainment Area DYNAMIC_LIST
--                       (the box's areas by name, commas made "‚" as the
--                       bridge's lists do) and the label of the box's area
--                       now; `first` (optional) a set of area ids listed
--                       first, the areas whose lamps sit in the box's room
--                       (design 6.1: offered first, never chosen silently)
--   a:choose(label, done)  the dealer picked `label` in Entertainment Area:
--                       true, or false and why (done not called). One
--                       hueTarget write through the queue
--   a:list()            → { { text, value } } for CUSTOM_SELECT: Set
--                       Entertainment Area and Apply Sync Settings' Area
--                       (contracts C1.6); value "area:<id>"
--   a:resolve(value)    → id, name: the area a programming value names now
--                       (re-points followed), or nil and a Last Action text
--   a:set(value, done)  the command: a:resolve, then the same write as choose;
--                       true, or false and the text (done not called)
--   a:status()          → { how, id, name, text, offer }: how "ok",
--                       "invalid" (listed, but the box reads invalidgroup),
--                       "gone" (deleted in Hue), "none" (no area chosen on the
--                       box), "standalone" (no bridge, B20), "unknown" (not
--                       read yet); text for Status; offer { id, name, text }
--                       while a gone area's successor is listed
--   a:record()          → a copy of the stored record
--
-- done(ok, text): once, under pcall, when the queue ends the write; `text`
-- for Last Action. A write a later one superseded ends without a call (the
-- queue's "superseded": nothing to report, syncbox/queue.lua).
--
-- The rules:
--   - The box's answer is the truth (edge cases rule 7): the record follows
--     the area the box reads, whoever set it (Control4, the Hue Sync app,
--     B23) and whatever it is now called (E2). Nothing here writes on a read.
--   - Keyed by id (E2). A gone area keeps its id and the name it had, so the
--     row and the texts still name it (E3, C19), and no other area is ever
--     chosen for it, even when only one is left (E3).
--   - The same-name successor (E4): the one listed area, other than the gone
--     one, with the name the gone one had (two with that name: none). It is
--     said once (the record keeps which successor was said, across a
--     restart) and listed in the drop-down; never applied by itself.
--   - One place re-points everything (§6 option A, design 8): picking a
--     listed area re-points every gone area of the same name to it, so the
--     programming lines that named the old id (K7: a line keeps the value it
--     was written with) resolve to the new one from then on. Said in the
--     pick's Last Action. A pick of an area with another name re-points
--     nothing.
--   - An area programming names that is gone and not re-pointed is not set
--     (C19): a:resolve answers the text, with the successor's offer when
--     there is one.
--   - Standalone (B20, owner's answer O2): no area can be picked.
--
-- The record (persisted plain under KEY, written only when it changed,
-- never on every read): { v, id, name, said_gone, said_offer, known = { {
-- id, name } }, repoint = { [old id] = new id } }; `known` the areas the box
-- listed or pointed at (at most KNOWN_MAX, the oldest dropped first),
-- `repoint` at most REPOINT_MAX entries [verified: SDK docs-driverworks-api
-- 26.5_persistence/_4-PersistSetValue.md: tables persist; no encrypted
-- argument, as syncbox/store.lua]. Area ids follow syncbox/state.lua's rule
-- (letters, digits and "-", or "groups/<n>"; at most 64 characters), names
-- its NAME_MAX.
--
-- DriverWorks calls: only the defaults of persist_get and persist_set
-- (C4:PersistGetValue, C4:PersistSetValue). `queue` is syncbox/queue.lua's:
-- q:set({ hueTarget = id }, tag, cb), cb(tag, ok, model, why, detail).

local https = require("common.https")

local areas = {}
areas.__index = areas

areas.KEY = "syncbox_area"
areas.VERSION = 1
areas.ID_MAX = 64
areas.NAME_MAX = 64
areas.KNOWN_MAX = 64
areas.REPOINT_MAX = 32
areas.HOPS_MAX = 8
areas.TEXT_MAX = 400
areas.VALUE_PREFIX = "area:"
areas.TAG = "area"
areas.UNKNOWN = "\226\128\148" -- an em dash
areas.LABEL_STANDALONE = "Standalone: lights paired to the box"
areas.DELETED = "deleted in Hue"

local function default_get(name)
	return C4:PersistGetValue(name)
end

local function default_set(name, value)
	return C4:PersistSetValue(name, value)
end

local function area_id(v)
	if type(v) ~= "string" or v == "" or #v > areas.ID_MAX then
		return nil
	end
	if v:match("^[%w%-]+$") or v:match("^groups/%d+$") then
		return v
	end
	return nil
end

local function name_of(v)
	if type(v) ~= "string" or v == "" then
		return nil
	end
	local s = https.peer_text(v, areas.NAME_MAX)
	return s ~= "" and s or nil
end

-- A label of the drop-down: no control characters, no comma (the list is
-- one comma-separated text, API 24_properties/_6-UpdatePropertyList.md).
local function list_text(text)
	return (tostring(text):gsub("%c", ""):gsub(",", "\226\128\154"))
end

-- "#a001": the last four characters of an id; "#3" for "groups/3".
local function short(id)
	local n = tostring(id):match("^groups/(%d+)$")
	return "#" .. (n or tostring(id):sub(-4))
end

function areas.new(deps)
	deps = deps or {}
	return setmetatable({
		queue = deps.queue,
		persist_get = deps.persist_get or default_get,
		persist_set = deps.persist_set or default_set,
		log = deps.log or require("common.log"),
		model = nil,
		rec = nil,
		by_label = nil,
	}, areas)
end

-- The record -------------------------------------------------------------------------

local function check_record(r)
	if type(r) ~= "table" or r.v ~= areas.VERSION then
		return nil
	end
	local out = { v = areas.VERSION, id = area_id(r.id), name = name_of(r.name), said_gone = area_id(r.said_gone),
		said_offer = area_id(r.said_offer), known = {}, repoint = {} }
	local seen = {}
	for _, k in ipairs(type(r.known) == "table" and r.known or {}) do
		local id = type(k) == "table" and area_id(k.id) or nil
		if id and not seen[id] and #out.known < areas.KNOWN_MAX then
			seen[id] = true
			out.known[#out.known + 1] = { id = id, name = name_of(k.name) }
		end
	end
	local n = 0
	for old, new in pairs(type(r.repoint) == "table" and r.repoint or {}) do
		old, new = area_id(old), area_id(new)
		if old and new and old ~= new and n < areas.REPOINT_MAX then
			out.repoint[old] = new
			n = n + 1
		end
	end
	return out
end

local function copy_record(r)
	local known, repoint = {}, {}
	for i, k in ipairs(r.known) do
		known[i] = { id = k.id, name = k.name }
	end
	for old, new in pairs(r.repoint) do
		repoint[old] = new
	end
	return { v = r.v, id = r.id, name = r.name, said_gone = r.said_gone, said_offer = r.said_offer, known = known,
		repoint = repoint }
end

function areas:load()
	if not self.rec then
		local ok, value = pcall(self.persist_get, areas.KEY)
		local rec = ok and check_record(value) or nil
		if ok and value ~= nil and rec == nil then
			self.log.warn("Sync box: the stored entertainment area is not usable; the box's own is shown")
		end
		self.rec = rec or { v = areas.VERSION, known = {}, repoint = {} }
	end
	return self.rec
end

function areas:save()
	local ok, err = pcall(self.persist_set, areas.KEY, copy_record(self.rec))
	if not ok then
		self.log.warn("Sync box: could not store the entertainment area: %s", tostring(err))
	end
end

function areas:record()
	return copy_record(self:load())
end

-- The name a known area had, or nil.
function areas:known_name(id)
	for _, k in ipairs(self:load().known) do
		if k.id == id then
			return k.name
		end
	end
	return nil
end

-- Remember `id` with `name`; true when that changed the record.
function areas:remember(id, name)
	local known = self:load().known
	for _, k in ipairs(known) do
		if k.id == id then
			if name and k.name ~= name then
				k.name = name
				return true
			end
			return false
		end
	end
	known[#known + 1] = { id = id, name = name }
	while #known > areas.KNOWN_MAX do
		table.remove(known, 1)
	end
	return true
end

-- The box's areas now ---------------------------------------------------------------------

-- id -> area of the last read, or nil when the read carried no hue object.
function areas:listed()
	local m = self.model
	if type(m) ~= "table" or type(m.areas) ~= "table" then
		return nil
	end
	local out = {}
	for _, a in ipairs(m.areas) do
		if area_id(a.id) then
			out[a.id] = a
		end
	end
	return out
end

-- The one listed area other than `except` named `name`, or nil (none, or
-- more than one: a name match is offered only when it is unambiguous).
function areas:successor(name, except)
	local list = self:listed()
	if not (list and name) then
		return nil
	end
	local found
	for id, a in pairs(list) do
		if id ~= except and name_of(a.name) == name then
			if found then
				return nil
			end
			found = id
		end
	end
	return found
end

function areas:status()
	local m, rec = self.model, self:load()
	if type(m) ~= "table" then
		return { how = "unknown", text = areas.UNKNOWN }
	end
	if m.standalone then
		return { how = "standalone", text = areas.LABEL_STANDALONE }
	end
	local list = self:listed()
	if not list then
		return { how = "unknown", text = areas.UNKNOWN }
	end
	local id = m.area
	if not id then
		return { how = "none", text = "No entertainment area: pick one in Entertainment Area" }
	end
	local a = list[id]
	if a then
		local name = name_of(a.name) or ("Area " .. short(id))
		if type(m.bridge) == "table" and m.bridge.state == "invalidgroup" then
			return { how = "invalid", id = id, name = name, text = string.format("The box cannot sync to %s (invalid "
				.. "area): pick it again in Entertainment Area", name) }
		end
		return { how = "ok", id = id, name = name, text = name }
	end
	local name = (rec.id == id and rec.name) or self:known_name(id)
	local label = name or "an area"
	local st = { how = "gone", id = id, name = name, text = string.format("Entertainment area %s (%s): pick another "
		.. "in Entertainment Area", areas.DELETED, label) }
	local next_id = self:successor(name, id)
	if next_id then
		st.offer = { id = next_id, name = name, text = string.format("%s is on the bridge again (made anew in Hue): "
			.. "pick it in Entertainment Area", name) }
	end
	return st
end

function areas:observe(model)
	if type(model) ~= "table" then
		return nil
	end
	self.model = model
	self.by_label = nil
	local rec = self:load()
	local changed = false
	for id, a in pairs(self:listed() or {}) do
		changed = self:remember(id, name_of(a.name)) or changed
	end
	local st = self:status()
	local say
	if st.how == "ok" or st.how == "invalid" then
		if rec.id ~= st.id or rec.name ~= st.name or rec.said_gone or rec.said_offer then
			rec.id, rec.name, rec.said_gone, rec.said_offer = st.id, st.name, nil, nil
			changed = true
		end
	elseif st.how == "gone" then
		if rec.id ~= st.id then
			rec.id, rec.name = st.id, st.name
			changed = true
		end
		if rec.said_gone ~= st.id then
			rec.said_gone = st.id
			changed = true
			say = string.format("The box syncs to an entertainment area %s (%s): pick another in Entertainment Area",
				areas.DELETED, st.name or "its name is not known")
		end
		if st.offer and rec.said_offer ~= st.offer.id then
			rec.said_offer = st.offer.id
			changed = true
			say = say and (say .. "; " .. st.offer.text) or st.offer.text
		end
	end
	if changed then
		self:save()
	end
	return say and https.peer_text(say, areas.TEXT_MAX) or nil
end

-- The drop-down and the programming list ----------------------------------------------------------

-- The listed areas sorted: `first` ones first, then by name, then by id.
function areas:sorted(first)
	local out = {}
	for _, a in pairs(self:listed() or {}) do
		out[#out + 1] = a
	end
	first = type(first) == "table" and first or {}
	table.sort(out, function(x, y)
		local fx, fy = first[x.id] and 0 or 1, first[y.id] and 0 or 1
		if fx ~= fy then
			return fx < fy
		end
		local nx, ny = (name_of(x.name) or ""):lower(), (name_of(y.name) or ""):lower()
		if nx ~= ny then
			return nx < ny
		end
		return x.id < y.id
	end)
	return out
end

-- Label per listed id: the name, and "(#a001)" where two share a name.
function areas:labels()
	local count, labels = {}, {}
	local list = self:listed() or {}
	for id, a in pairs(list) do
		local l = list_text(name_of(a.name) or ("Area " .. short(id)))
		labels[id] = l
		count[l] = (count[l] or 0) + 1
	end
	for id, l in pairs(labels) do
		if count[l] > 1 then
			labels[id] = string.format("%s (%s)", l, short(id))
		end
	end
	-- Still alike (ids ending alike): the whole id.
	local seen = {}
	for id, l in pairs(labels) do
		if seen[l] then
			labels[id] = string.format("%s (%s)", list_text(name_of(list[id].name) or "Area"), id)
			labels[seen[l]] = string.format("%s (%s)", list_text(name_of(list[seen[l]].name) or "Area"), seen[l])
		end
		seen[l] = id
	end
	return labels
end

function areas:items(first)
	local st = self:status()
	if st.how == "standalone" then
		self.by_label = {}
		return { areas.LABEL_STANDALONE }, areas.LABEL_STANDALONE
	end
	local labels = self:labels()
	local items, by_label = {}, {}
	for _, a in ipairs(self:sorted(first)) do
		items[#items + 1] = labels[a.id]
		by_label[labels[a.id]] = a.id
	end
	self.by_label = by_label
	local value = ""
	if st.how == "ok" or st.how == "invalid" then
		value = labels[st.id] or ""
	elseif st.how == "gone" then
		value = list_text(string.format("%s (%s)", st.name or "An area", areas.DELETED))
	end
	return items, value
end

function areas:list()
	local st = self:status()
	if st.how == "unknown" then
		return { { text = "(the box has not been read yet; open the list again)", value = "" } }
	end
	if st.how == "standalone" then
		return { { text = "(" .. areas.LABEL_STANDALONE .. ": no entertainment areas)", value = "" } }
	end
	local labels, out = self:labels(), {}
	for _, a in ipairs(self:sorted()) do
		out[#out + 1] = { text = labels[a.id], value = areas.VALUE_PREFIX .. a.id }
	end
	if #out == 0 then
		out[1] = { text = "(the box lists no entertainment areas)", value = "" }
	end
	return out
end

-- The writes --------------------------------------------------------------------------------------

-- Every gone known area named `name` re-points to `id` (the dealer picked
-- the one listed area of that name); how many it re-pointed. An area
-- re-pointed before and gone since needs nothing: a:resolve follows the
-- chain (A to B, then B to C). At most REPOINT_MAX are kept.
function areas:repoint_to(id, name)
	local list = self:listed() or {}
	if not name or self:successor(name, nil) ~= id then
		return 0
	end
	local rec, n, count = self:load(), 0, 0
	for _ in pairs(rec.repoint) do
		count = count + 1
	end
	for _, k in ipairs(rec.known) do
		if k.id ~= id and k.name == name and not list[k.id] and rec.repoint[k.id] ~= id then
			if rec.repoint[k.id] == nil and count >= areas.REPOINT_MAX then
				self.log.warn("Sync box: too many re-pointed entertainment areas; %s is not re-pointed", k.id)
			else
				count = count + (rec.repoint[k.id] == nil and 1 or 0)
				rec.repoint[k.id] = id
				n = n + 1
			end
		end
	end
	return n
end

function areas:write(id, name, done, repointed)
	if not (self.queue and self.queue.set) then
		return false, "Not set: the box's writes are not ready yet"
	end
	local label = name or ("area " .. short(id))
	local okq, ok, why = pcall(self.queue.set, self.queue, { hueTarget = id }, areas.TAG,
		function(_, landed, _, reason, detail)
			if reason == "superseded" or not done then
				return
			end
			local text
			if landed then
				text = "Entertainment area set to " .. label
				if repointed > 0 then
					text = text .. string.format("; programming that named the deleted %s uses it now", label)
				end
			elseif reason == "refused" then
				text = string.format("Not set: the box refused the entertainment area %s (%s)", label,
					https.peer_text(detail or "no reason given", 120))
			elseif reason == "not landed" then
				text = string.format("Not set: the box did not take the entertainment area %s", label)
			elseif reason == "busy" then
				text = string.format("Not set: the box is busy (%s)", label)
			else
				text = string.format("Not set: %s (%s)", https.peer_text(detail or reason or "no answer", 120), label)
			end
			local okc, err = pcall(done, landed == true, https.peer_text(text, areas.TEXT_MAX))
			if not okc then
				self.log.warn("Sync box: the entertainment area's answer failed: %s", tostring(err))
			end
		end)
	if not okq or not ok then
		return false, "Not set: the entertainment area could not be sent (" .. tostring(okq and why or ok) .. ")"
	end
	self.log.info("Sync box: entertainment area %s (%s) requested", label, id)
	return true
end

-- A pick: the dealer's click in Entertainment Area.
function areas:choose(label, done)
	local st = self:status()
	if st.how == "standalone" then
		return false, "Not set: this box runs without a Hue Bridge (standalone mode)"
	end
	if not self.by_label then
		self:items()
	end
	local id = type(label) == "string" and self.by_label[label] or nil
	if not id then
		return false, string.format("Not set: %s is not an entertainment area of this box",
			https.peer_text(tostring(label or ""), areas.NAME_MAX))
	end
	local a = (self:listed() or {})[id]
	local name = a and name_of(a.name) or nil
	local n = self:repoint_to(id, name)
	if n > 0 then
		self:save()
		self.log.info("Sync box: %d deleted area(s) named %s re-pointed to %s", n, tostring(name), id)
	end
	return self:write(id, name, done, n)
end

-- The area a programming value names now: "area:<id>" or a bare id.
function areas:resolve(value)
	local id = type(value) == "string" and area_id((value:gsub("^" .. areas.VALUE_PREFIX, ""))) or nil
	if not id then
		return nil, "Not set: no entertainment area was chosen in this programming line"
	end
	if type(self.model) == "table" and self.model.standalone then
		return nil, "Not set: this box runs without a Hue Bridge (standalone mode)"
	end
	local rec = self:load()
	local first = id
	for _ = 1, areas.HOPS_MAX do
		local next_id = rec.repoint[id]
		if not next_id or next_id == id then
			break
		end
		id = next_id
	end
	local list = self:listed()
	if not list then
		-- Not read yet: the box judges the id (SB48 refuses an unknown one).
		return id, self:known_name(id)
	end
	if list[id] then
		return id, name_of(list[id].name) or self:known_name(id)
	end
	local name = self:known_name(id) or self:known_name(first)
	local text = string.format("Not set: the entertainment area %s was %s", name or "this programming names",
		areas.DELETED)
	local next_id = self:successor(name, id)
	if next_id then
		text = text .. string.format("; %s is on the bridge again: pick it in Entertainment Area to re-point this "
			.. "programming", name)
	end
	return nil, text
end

-- The command (Set Entertainment Area).
function areas:set(value, done)
	local id, name = self:resolve(value)
	if not id then
		return false, name
	end
	return self:write(id, name, done, 0)
end

return areas
