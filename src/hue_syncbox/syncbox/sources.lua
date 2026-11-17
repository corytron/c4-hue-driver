-- The sources a Hue Sync Box carries, and the sync mode each calls for (2.0
-- beta stage 3, #557): docs/hdmi-sync-stage3-design.md §4, research
-- docs/syncbox-wirings-research.md §2 (a source's kind; Listen), §3.2 (the
-- bindings upstream), §5 W21 and §7.2 (the precedence, Source Sync Modes,
-- the action Set Source Sync Mode).
--
--   local s = sources.new{ get_devices, bound_provider, display_name,
--                          persist_get, persist_set, log }
--   s:describe(id)   → { id, name, proxy_kind, driver_file, room_id,
--                    protocol_id, ids } | nil, "gone" | "error"
--                    proxy_kind: the proxy's driver file without its
--                    extension, lower case ("tv", "dvd", "tuner"); nil for a
--                    combo driver. driver_file: the protocol driver's file
--                    ("sony_ps5.c4z"), lower case; the combo driver's own.
--                    ids: the id, its protocol's and its proxies' ids (a
--                    room path may name either).
--   s:upstream(box_id)  → { inputs = { [n] = description }, sources = {
--                    description with via = n }, ids = { [id] = true },
--                    first_input = n }: what feeds the box's HDMI n (video
--                    1000 + n − 1, contracts C1.2) and, behind it, what feeds
--                    that device's inputs 1000 to 1099 (research §3.2: the
--                    candidates, not the current source). `box_id` is the
--                    box's avswitch proxy id: the SDK asks for the proxy's id
--                    on a device with proxies [verified: API
--                    32_serial_network_device/_4-GetBoundProviderDevice].
--   s:mode_for(selection, wiring, input)  → mode, how. mode "video" |
--                    "game" | "music" | "none" (Do not sync), or nil when
--                    nothing is selected. The precedence (research §7.2):
--                    in line (`input` = { n, setting, type, audio_only }):
--                      HDMI n Sync Mode ("set") > an audio-only route
--                      ("route") > the box's input type ("type") > Video
--                      ("default");
--                    behind a receiver and on the second output (`selection`
--                    = the room's state { selected, kind }, or { id, kind },
--                    or an id): the source's Source Sync Mode ("set") >
--                    Listen → Music ("listen") > Game guessed from the
--                    driver's file name ("guess", GAME_GUESS) > a tuner, CD
--                    or disc changer proxy → Music ("kind") > Video
--                    ("default").
--   s:setting(id)    the stored mode of a source, or nil (Automatic)
--   s:set_mode(id, text)  the action Set Source Sync Mode: text one of
--                    SETTINGS → true, Last Action text | false, reason.
--                    Stored by device id with the name it had
--                    (PersistSetValue, a table [verified: API
--                    26.5_persistence/_4-PersistSetValue]); Automatic
--                    removes it.
--   s:saw(id)        a source seen selected in the followed room (this run)
--   s:candidates(box_id)  → { { id, name, setting, gone } } sorted by name:
--                    the sources upstream, the ones seen, the ones stored;
--                    for the action's Source list
--   s:summary(box_id)  the Source Sync Modes row: "Apple TV: Video; PS5:
--                    Game (guessed from its driver); Turntable: Music";
--                    a stored source whose device is gone reads "(device
--                    gone)" (W21)
--   s:offers(box_id)  W21: a stored source gone and exactly one present
--                    source of the same name without its own setting →
--                    { { from_id, to_id, name, mode, text } }. Offered only.
--   s:accept(from_id, to_id)  the offer taken (one click): the mode moves
--
-- Control4 has no game console proxy [verified: the proxy guide's folder
-- list, ~/c4-tools/reference/docs-driverworks-proxyprotocol/source/
-- includes/], so outside the in-line wiring Game comes from the dealer's
-- setting or from a hint in the protocol driver's file name (GAME_HINTS).
-- The display name is the dealer's text and is never used for it. The proxy
-- names tv, tuner, tunerXM, receiver, dvd and discchanger are the SDK's
-- [verified: docs-driverworks-fundamentals 8_proxies_and_proxy_types/
-- _1-SINGLEANDMULTIPROXIES]; that a proxy's driver file is "<proxy>.c4i" is
-- the house's reading for light_v2 [house: docs/design.md "Project APIs"]
-- and assumed for the others; "cdplayer" is [assumed].
--
-- GetDevices' shapes [verified: API 22_miscellaneous/_9-GetDevices examples
-- 1 to 3; house: roomId a number, the filter a string]: from a proxy id,
-- the proxy's driverFileName and a `protocol` table { [id] = {
-- driverFileName, deviceName } }; from a protocol id, its driverFileName and
-- a `proxies` table; a combo driver neither. Every value is checked: ids
-- through common/num.lua, names capped with https.peer_text (NAME_MAX), file
-- names lower case, at most FILE_MAX bytes of [%w_.-].

local num = require("common.num")
local https = require("common.https")

local sources = {}

sources.NAME_MAX = 64
sources.FILE_MAX = 64
sources.ID_MAX = 2147483647
sources.INPUTS = 4                -- HDMI 1 to 4 (contracts C1.2)
sources.VIDEO_INPUT_FIRST = 1000  -- the box's video inputs 1000 to 1003
sources.UPSTREAM_INPUTS = 100     -- a receiver's inputs walked: 1000 to 1099 (research §3.2)
sources.STORE_KEY = "syncbox_source_modes"
sources.STORE_MAX = 64            -- sources with a setting of their own
sources.SEEN_MAX = 64
sources.SUMMARY_MAX = 16          -- entries in Source Sync Modes before "and N more"
sources.PROXIES_READ = 16         -- entries of a device's proxies table looked at

-- Provisional owner answer 3 (#536, contract §2): Game guessed from a source
-- driver's file name is applied as part of Automatic and shown as a guess.
-- "offer" shows the guess without applying it. One line.
sources.GAME_GUESS = "apply"
sources.GAME_HINTS = { "xbox", "playstation", "nintendo" }   -- research §2.1
sources.MUSIC_PROXIES = { tuner = true, tunerxm = true, discchanger = true, cdplayer = true }
-- The box's input types (docs/syncbox-api-research.md §2.7; design 5.3).
sources.GAME_TYPES = { game = true, xbox = true, playstation = true, nintendoswitch = true }
sources.MUSIC_TYPES = { music = true, avreceiver = true, soundbar = true, speaker = true }

-- The action's Mode list and the HDMI n Sync Mode values (contracts C1.4).
sources.SETTINGS = { "Automatic", "Video", "Game", "Music", "Do not sync" }
local SETTING_MODE = { video = "video", game = "game", music = "music", ["do not sync"] = "none" }
sources.LABEL = { video = "Video", game = "Game", music = "Music", none = "Do not sync" }
local MODES = { video = true, game = true, music = true, none = true }

local function cap(text)
	if text == nil then
		return nil
	end
	return https.peer_text(text, sources.NAME_MAX)
end

local function check_file(v)
	if type(v) ~= "string" or #v < 1 or #v > sources.FILE_MAX then
		return nil
	end
	v = v:lower()
	if not v:match("^[%w_%.%-]+$") then
		return nil
	end
	return v
end

local function base_of(file)
	file = check_file(file)
	return file and (file:gsub("%.c4[iz]$", "")) or nil
end

-- A setting's text ("Game", "do not sync") → "game", "none"; "automatic" →
-- false; anything else nil.
local function setting_mode(text)
	if type(text) ~= "string" then
		return nil
	end
	local key = text:sub(1, 32):lower():match("^%s*(.-)%s*$")
	if key == "automatic" then
		return false
	end
	return SETTING_MODE[key]
end
sources.setting_mode = setting_mode

local S = {}
S.__index = S

function sources.new(deps)
	deps = deps or {}
	return setmetatable({
		get_devices = deps.get_devices or function(filter)
			return C4:GetDevices(filter)
		end,
		bound_provider = deps.bound_provider or function(device, binding)
			return C4:GetBoundProviderDevice(device, binding)
		end,
		display_name = deps.display_name or function(id)
			return C4:GetDeviceDisplayName(id)
		end,
		get = deps.persist_get or function(name)
			return C4:PersistGetValue(name)
		end,
		set = deps.persist_set or function(name, value)
			return C4:PersistSetValue(name, value)
		end,
		log = deps.log or require("common.log"),
		memory = nil,
		seen = {},
		seen_count = 0,
	}, S)
end

local function id_of(v)
	return num.int(v, 1, sources.ID_MAX)
end

-- Describing a device ---------------------------------------------------------------

function S:describe(id)
	id = id_of(id)
	if not id then
		return nil, "error"
	end
	local ok, t = pcall(self.get_devices, { DeviceIds = tostring(id) })
	if not ok or type(t) ~= "table" then
		return nil, "error"
	end
	local e = t[id]
	if e == nil then
		e = t[tostring(id)]
	end
	if type(e) ~= "table" then
		return nil, "gone"
	end
	local d = { id = id, ids = { [id] = true }, room_id = num.int(e.roomId, 1, sources.ID_MAX) }
	local name = e.deviceName
	if type(name) ~= "string" or name == "" then
		local got, display = pcall(self.display_name, id)
		name = got and type(display) == "string" and display or nil
	end
	d.name = cap(name) or string.format("device %d", id)
	local proxy_file, driver_file
	if type(e.protocol) == "table" then
		proxy_file = e.driverFileName
		local n = 0
		for pid, p in pairs(e.protocol) do
			n = n + 1
			if n > sources.PROXIES_READ then
				break
			end
			pid = id_of(pid)
			if pid and type(p) == "table" and (d.protocol_id == nil or pid < d.protocol_id) then
				d.protocol_id, driver_file = pid, p.driverFileName
			end
		end
		if d.protocol_id then
			d.ids[d.protocol_id] = true
		end
	elseif type(e.proxies) == "table" then
		driver_file = e.driverFileName
		local main, n = nil, 0
		for pid, p in pairs(e.proxies) do
			n = n + 1
			if n > sources.PROXIES_READ then
				break
			end
			pid = id_of(pid)
			if pid and type(p) == "table" then
				d.ids[pid] = true
				if main == nil or pid < main then
					main, proxy_file = pid, p.driverFileName
				end
			end
		end
	else
		driver_file = e.driverFileName   -- a combo driver
	end
	d.proxy_kind = proxy_file and base_of(proxy_file) or nil
	d.driver_file = check_file(driver_file)
	return d
end

-- The device bound to `binding` of `device`: a number, 0 when nothing is
-- bound [house: OS 3.4.2], or a table of id → name as the SDK's Returns says
-- [verified: API 32/_4, which shows a number in its example].
function S:provider(device, binding)
	local ok, v = pcall(self.bound_provider, device, binding)
	if not ok then
		return nil
	end
	if type(v) == "table" then
		local best
		for k in pairs(v) do
			k = id_of(k)
			if k and (best == nil or k < best) then
				best = k
			end
		end
		return best
	end
	return id_of(v)
end

function S:upstream(box_id)
	local out = { inputs = {}, sources = {}, ids = {} }
	box_id = id_of(box_id)
	if not box_id then
		return out
	end
	local seen = { [box_id] = true }
	for n = 1, sources.INPUTS do
		local p = self:provider(box_id, sources.VIDEO_INPUT_FIRST + n - 1)
		if p then
			local d = self:describe(p) or { id = p, ids = { [p] = true }, name = string.format("device %d", p) }
			out.inputs[n] = d
			out.first_input = out.first_input or n
			for x in pairs(d.ids) do
				out.ids[x] = true
			end
			seen[p] = true
			for b = sources.VIDEO_INPUT_FIRST, sources.VIDEO_INPUT_FIRST + sources.UPSTREAM_INPUTS - 1 do
				local src = self:provider(p, b)
				if src and not seen[src] then
					seen[src] = true
					local sd = self:describe(src)
					if sd then
						sd.via = n
						out.sources[#out.sources + 1] = sd
					end
				end
			end
		end
	end
	return out
end

-- The per-source settings ----------------------------------------------------------

function S:modes()
	if self.memory then
		return self.memory
	end
	local m = {}
	local ok, t = pcall(self.get, sources.STORE_KEY)
	if ok and type(t) == "table" then
		local n, kept = 0, 0
		for k, e in pairs(t) do
			n = n + 1
			if n > sources.STORE_MAX * 4 or kept >= sources.STORE_MAX then
				break
			end
			local id = id_of(k)
			if id and type(e) == "table" and MODES[e.mode] then
				m[id] = { mode = e.mode, name = type(e.name) == "string" and cap(e.name) or nil }
				kept = kept + 1
			end
		end
	elseif not ok then
		self.log.warn("Sync box: could not read the stored source sync modes")
	end
	self.memory = m
	return m
end

function S:save()
	local t = {}
	for id, e in pairs(self:modes()) do
		t[tostring(id)] = { mode = e.mode, name = e.name }
	end
	local ok = pcall(self.set, sources.STORE_KEY, t)
	if not ok then
		self.log.warn("Sync box: could not store the source sync modes; they are kept for this run")
	end
end

function S:setting(id)
	local e = self:modes()[id_of(id) or -1]
	return e and e.mode or nil
end

local function count(t)
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

function S:set_mode(id, text)
	id = id_of(id)
	if not id then
		return false, "no source"
	end
	local mode = setting_mode(text)
	if mode == nil then
		return false, "not a sync mode"
	end
	local m = self:modes()
	local d = self:describe(id)
	local name = d and d.name or (m[id] and m[id].name) or string.format("device %d", id)
	if mode then
		if not m[id] and count(m) >= sources.STORE_MAX then
			return false, "too many sources with a sync mode of their own"
		end
		m[id] = { mode = mode, name = d and d.name or (m[id] and m[id].name) or nil }
	else
		m[id] = nil
	end
	self:save()
	return true, string.format("Source Sync Mode of %s: %s", name, mode and sources.LABEL[mode] or "Automatic")
end

function S:saw(id)
	id = id_of(id)
	if not id or self.seen[id] then
		return
	end
	if self.seen_count >= sources.SEEN_MAX then
		return
	end
	self.seen[id] = true
	self.seen_count = self.seen_count + 1
end

-- The mode -------------------------------------------------------------------------

local function guessed_game(d)
	local file = d and d.driver_file
	if not file then
		return false
	end
	for _, hint in ipairs(sources.GAME_HINTS) do
		if file:find(hint, 1, true) then
			return true
		end
	end
	return false
end

local function selection_of(selection)
	if type(selection) == "table" then
		return id_of(selection.selected or selection.id), selection.kind
	end
	return id_of(selection), nil
end

function S:mode_for(selection, wiring, input)
	if wiring == "in_line" then
		input = type(input) == "table" and input or {}
		local set = setting_mode(input.setting)
		if set then
			return set, "set"
		end
		if input.audio_only then
			return "music", "route"
		end
		local kind = type(input.type) == "string" and input.type:sub(1, 32):lower() or nil
		if kind and sources.GAME_TYPES[kind] then
			return "game", "type"
		end
		if kind and sources.MUSIC_TYPES[kind] then
			return "music", "type"
		end
		return "video", "default"
	end
	local id, kind = selection_of(selection)
	if not id or kind == "off" then
		return nil, "nothing selected"
	end
	local set = self:setting(id)
	if set then
		return set, "set"
	end
	if kind == "listen" then
		return "music", "listen"
	end
	local d = self:describe(id)
	if guessed_game(d) and sources.GAME_GUESS == "apply" then
		return "game", "guess"
	end
	if d and d.proxy_kind and sources.MUSIC_PROXIES[d.proxy_kind] then
		return "music", "kind"
	end
	return "video", "default"
end

-- Lists and the row --------------------------------------------------------------------

function S:candidates(box_id)
	local m = self:modes()
	local list, by_id = {}, {}
	local function add(id, d, gone)
		if by_id[id] then
			return
		end
		local e = m[id]
		if e and d and e.name ~= d.name then
			e.name = d.name   -- renamed: the name kept is the latest
			self.renamed = true
		end
		local item = { id = id, name = d and d.name or (e and e.name) or string.format("device %d", id),
			setting = e and e.mode or nil, gone = gone or false, description = d }
		by_id[id] = item
		list[#list + 1] = item
	end
	if box_id then
		for _, d in ipairs(self:upstream(box_id).sources) do
			add(d.id, d)
		end
	end
	for id in pairs(self.seen) do
		local d = self:describe(id)
		if d then
			add(id, d)
		end
	end
	for id in pairs(m) do
		if not by_id[id] then
			local d, why = self:describe(id)
			add(id, d, d == nil and why == "gone")
		end
	end
	if self.renamed then
		self.renamed = nil
		self:save()
	end
	table.sort(list, function(a, b)
		local na, nb = a.name:lower(), b.name:lower()
		if na ~= nb then
			return na < nb
		end
		return a.id < b.id
	end)
	return list
end

function S:entry_text(item)
	local mode, how
	if item.setting then
		mode, how = item.setting, "set"
	else
		mode, how = self:mode_for({ selected = item.id, kind = "watch" }, "second_output")
	end
	local text = string.format("%s: %s", item.name, sources.LABEL[mode] or "Video")
	if item.gone then
		return text .. " (device gone)"
	end
	if how == "guess" then
		return text .. " (guessed from its driver)"
	end
	if how == "default" and guessed_game(item.description) then
		return text .. " (Game guessed from its driver)"   -- GAME_GUESS "offer"
	end
	return text
end

function S:summary(box_id)
	local list = self:candidates(box_id)
	if #list == 0 then
		return "No sources found yet"
	end
	local parts = {}
	for i, item in ipairs(list) do
		if i > sources.SUMMARY_MAX then
			parts[#parts + 1] = string.format("and %d more", #list - sources.SUMMARY_MAX)
			break
		end
		parts[#parts + 1] = self:entry_text(item)
	end
	return table.concat(parts, "; ")
end

function S:offers(box_id)
	local list = self:candidates(box_id)
	local out = {}
	for _, gone in ipairs(list) do
		if gone.gone and gone.setting then
			local match
			for _, item in ipairs(list) do
				if not item.gone and not item.setting and item.name:lower() == gone.name:lower() then
					if match then
						match = false
						break
					end
					match = item
				end
			end
			if match then
				out[#out + 1] = { from_id = gone.id, to_id = match.id, name = match.name, mode = gone.setting,
					text = string.format("%s (device %d) replaces a source set to %s: give it %s with Set Source "
						.. "Sync Mode", match.name, match.id, sources.LABEL[gone.setting], sources.LABEL[gone.setting]) }
			end
		end
	end
	return out
end

function S:accept(from_id, to_id)
	from_id, to_id = id_of(from_id), id_of(to_id)
	local m = self:modes()
	if not from_id or not to_id or not m[from_id] or m[to_id] then
		return false
	end
	local d = self:describe(to_id)
	m[to_id] = { mode = m[from_id].mode, name = d and d.name or m[from_id].name }
	m[from_id] = nil
	self:save()
	return true
end

return sources
